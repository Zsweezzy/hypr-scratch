use std::{
    env, fs,
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{OpenOptionsExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

/// The bytes each command puts on the wire.
///
/// Both are sent by this program now. `toggle` comes from the hotkey invoking the
/// binary again; `dismiss` comes from the same binary's `--outside-click` mode,
/// which the compositor calls on every click. Neither is ever sent by the app to
/// itself.
const TOGGLE_MESSAGE: &[u8] = b"toggle\n";
const DISMISS_MESSAGE: &[u8] = b"dismiss\n";

/// The longest line accepted off the socket before the connection is given up on.
const MAX_COMMAND_LEN: usize = 64;

/// Something the notepad was asked to do.
///
/// `Toggle` comes from the hotkey, which runs the binary again and finds this
/// process through the socket.
///
/// `Dismiss` comes from `--outside-click`, which the compositor calls on every
/// mouse press and which sends `dismiss\n` only after establishing that the
/// click landed outside this window's rectangle.
///
/// The two are deliberately distinct rather than one command with an argument: a
/// click inside the notepad and a hotkey press are the same event as far as the
/// compositor is concerned, and only the geometry check tells them apart.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Toggle,
    Dismiss,
}

impl Command {
    fn message(self) -> &'static [u8] {
        match self {
            Self::Toggle => TOGGLE_MESSAGE,
            Self::Dismiss => DISMISS_MESSAGE,
        }
    }
}

/// Asks the running instance to do something, if there is one.
///
/// This is how both senders reach the notepad, and it is the reason the
/// click-away feature needs no `socat` and no shell script: connecting to a Unix
/// socket is something this program can already do, and the version that used to
/// delegate it to a shell script could not, because `printf > "$socket"` opens
/// the path `O_WRONLY` and a Unix socket refuses that with `ENXIO`. The only way
/// in is `connect(2)`.
///
/// Reports whether the message went out. Every failure is quiet by design: this
/// runs on every click in the session, and a notepad that is not running is the
/// overwhelmingly common case, not an error.
pub fn send(command: Command) -> bool {
    // Checked before connecting, so the common case costs one `stat` and no
    // socket machinery. A stale socket left by a `SIGKILL`ed instance still
    // passes this, and the connect below then fails, which is the right answer.
    if !is_running() {
        return false;
    }
    let Ok(mut stream) = socket_path().and_then(UnixStream::connect) else {
        return false;
    };
    let _ = stream.set_write_timeout(Some(SEND_TIMEOUT));
    stream.write_all(command.message()).is_ok()
}

/// Whether an instance is listening.
///
/// Deliberately only a `stat` on the socket path, with no connection: this is on
/// the hot path of every click, and a notepad that has crashed without cleaning up
/// would otherwise cost a failed connect on every click for the rest of the
/// session.
pub fn is_running() -> bool {
    socket_path().is_ok_and(|path| path.exists())
}

const SEND_TIMEOUT: Duration = Duration::from_millis(200);

/// Commands that have arrived but not yet been applied by the GTK main loop.
///
/// Two atomics rather than a channel. The GTK side has to poll either way, and
/// every channel type here would mean a dependency for what is two bits of
/// state. The listener thread only ever sets; the main loop only ever takes.
#[derive(Default)]
pub struct PendingCommands {
    toggle: AtomicBool,
    dismiss: AtomicBool,
}

impl PendingCommands {
    fn request(&self, command: Command) {
        match command {
            Command::Toggle => self.toggle.store(true, Ordering::SeqCst),
            Command::Dismiss => self.dismiss.store(true, Ordering::SeqCst),
        }
    }

    pub fn take_toggle(&self) -> bool {
        self.toggle.swap(false, Ordering::SeqCst)
    }

    pub fn take_dismiss(&self) -> bool {
        self.dismiss.swap(false, Ordering::SeqCst)
    }
}

pub enum AcquiredInstance {
    Primary(PrimaryInstance),
    Secondary,
}

pub struct PrimaryInstance {
    listener: UnixListener,
    path: PathBuf,
    _lock: fs::File,
}

impl PrimaryInstance {
    pub fn spawn_listener(self, pending: Arc<PendingCommands>) -> JoinHandle<()> {
        let Self {
            listener,
            path,
            _lock,
        } = self;
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else {
                    continue;
                };
                let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
                if let Ok(Some(command)) = read_command(&mut stream) {
                    pending.request(command);
                }
            }
            let _ = fs::remove_file(&path);
            drop(_lock);
        })
    }
}

/// Reads one newline-terminated command, or `None` if the line is not one.
///
/// Line-oriented rather than a fixed-length read so a second command can be
/// added without the reader caring how long it is. That matters more than it
/// looks: a fixed `read_exact` of `toggle\n`'s length would read the first 7
/// bytes of `dismiss\n` as `dismiss`, not `toggle`, compare unequal and throw
/// the message away -- and an unmatched command is silent, so the feature would
/// simply never fire. Existing senders are unaffected, since `toggle\n` still
/// parses to the same command.
fn read_command(reader: &mut impl Read) -> io::Result<Option<Command>> {
    let mut line = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        match reader.read(&mut byte) {
            Ok(0) => break,
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) => {
                if line.len() == MAX_COMMAND_LEN {
                    // Never a real command. Stop reading rather than buffer a
                    // peer that is not going to send a newline.
                    return Ok(None);
                }
                line.push(byte[0]);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }

    Ok(match line.as_slice() {
        b"toggle" => Some(Command::Toggle),
        b"dismiss" => Some(Command::Dismiss),
        _ => None,
    })
}

pub fn acquire_instance() -> io::Result<AcquiredInstance> {
    acquire_instance_at(&socket_path()?)
}

fn acquire_instance_at(path: &Path) -> io::Result<AcquiredInstance> {
    let lock_path = lock_path_for(path);
    let lock = open_lock_file(&lock_path)?;

    for _ in 0..100 {
        match try_lock(&lock) {
            Ok(()) => {
                // A legacy primary may predate the lock file. Give it a
                // chance to receive the toggle before replacing a stale path.
                if try_toggle_existing(path)? {
                    return Ok(AcquiredInstance::Secondary);
                }
                remove_socket_if_present(path)?;
                let listener = UnixListener::bind(path)?;
                fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
                return Ok(AcquiredInstance::Primary(PrimaryInstance {
                    listener,
                    path: path.to_owned(),
                    _lock: lock,
                }));
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if try_toggle_existing(path)? {
                    return Ok(AcquiredInstance::Secondary);
                }
                // The lock owner may be between opening the lock and binding
                // its socket. Retry briefly instead of stealing its endpoint.
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(error),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::TimedOut,
        "could not acquire scratchpad instance socket",
    ))
}

fn lock_path_for(path: &Path) -> PathBuf {
    let mut lock_path = path.as_os_str().to_os_string();
    lock_path.push(".lock");
    PathBuf::from(lock_path)
}

fn open_lock_file(path: &Path) -> io::Result<fs::File> {
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(lock)
}

fn try_lock(lock: &fs::File) -> io::Result<()> {
    let result = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn try_toggle_existing(path: &Path) -> io::Result<bool> {
    match UnixStream::connect(path) {
        Ok(mut stream) => {
            stream.write_all(TOGGLE_MESSAGE)?;
            Ok(true)
        }
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            Ok(false)
        }
        Err(error) => Err(error),
    }
}

fn remove_socket_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

pub fn socket_path() -> io::Result<PathBuf> {
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let uid = unsafe { libc::getuid() };
    Ok(runtime_dir.join(format!("hypr-scratch-{uid}.sock")))
}

#[cfg(test)]
mod tests {
    use super::{
        AcquiredInstance, Command, DISMISS_MESSAGE, MAX_COMMAND_LEN, PendingCommands,
        TOGGLE_MESSAGE, acquire_instance_at, read_command,
    };
    use std::fs;
    use std::io::{self, Cursor, Read, Write};
    use std::os::unix::net::UnixStream;
    use std::thread;

    /// Each command must raise its own flag and no other.
    ///
    /// The two are a pair of independent booleans read by two separate branches
    /// of the GTK poll, so a mix-up is invisible: a click that opened the
    /// notepad instead of closing it, or a hotkey that closed it. Nothing fails,
    /// nothing is logged, and the feature just does not work.
    #[test]
    fn each_command_raises_only_its_own_flag() {
        for (command, toggle, dismiss) in [
            (Command::Toggle, true, false),
            (Command::Dismiss, false, true),
        ] {
            let pending = PendingCommands::default();
            pending.request(command);

            assert_eq!(pending.take_toggle(), toggle, "{command:?} raised toggle");
            assert_eq!(
                pending.take_dismiss(),
                dismiss,
                "{command:?} raised dismiss"
            );
            // Taking must consume, or a flag would re-fire on every poll.
            assert!(!pending.take_toggle(), "{command:?} was consumed");
            assert!(!pending.take_dismiss(), "{command:?} was consumed");
        }
    }

    /// The whole path a `dismiss` takes, over a real socket.
    ///
    /// The listener thread loops forever, so this drives the same three steps it
    /// performs per connection rather than the loop itself: read the line, parse
    /// it, raise the flag. Reading from a real `UnixStream` rather than a
    /// `Cursor` is the point -- a socket is free to hand over a partial line, and
    /// the byte-at-a-time loop has to cope with that.
    #[test]
    fn a_dismiss_written_to_a_socket_ends_up_as_a_pending_command() {
        let pending = PendingCommands::default();
        let (mut sender, mut receiver) = UnixStream::pair().expect("socket pair should be created");

        let writer = thread::spawn(move || {
            sender
                .write_all(DISMISS_MESSAGE)
                .expect("message should write");
            sender
                .shutdown(std::net::Shutdown::Write)
                .expect("sender should close its side");
        });

        let Some(command) = read_command(&mut receiver).expect("the socket should read") else {
            panic!("dismiss should have been recognised");
        };
        writer.join().expect("writer should finish");
        pending.request(command);

        assert!(pending.take_dismiss());
        assert!(!pending.take_toggle());
    }

    /// Feeds a message one byte per read.
    ///
    /// A socket is not obliged to hand over a whole write in one read, so a
    /// reader that assumes it does is wrong in a way that only shows up when
    /// the timing is unlucky.
    struct Fragmented<'a> {
        bytes: &'a [u8],
        position: usize,
    }

    impl Read for Fragmented<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if self.position == self.bytes.len() {
                return Ok(0);
            }
            buffer[0] = self.bytes[self.position];
            self.position += 1;
            Ok(1)
        }
    }

    #[test]
    fn reads_fragmented_toggle_messages() {
        let mut reader = Fragmented {
            bytes: TOGGLE_MESSAGE,
            position: 0,
        };
        assert_eq!(
            read_command(&mut reader).expect("fragmented message should be read"),
            Some(Command::Toggle)
        );
    }

    /// Both messages the senders can write, asserted against the exact bytes on
    /// the wire.
    ///
    /// `dismiss` is the one worth having. It is a byte longer than `toggle`, so
    /// a reader that stopped at a fixed length would take the first 7 bytes of
    /// `dismiss\n`, fail to match, and drop it -- silently, since an unmatched
    /// command is not an error. The notepad would then simply never dismiss on a
    /// click, with nothing in any log to say why.
    #[test]
    fn every_message_a_sender_writes_parses_to_its_own_command() {
        for (message, want) in [
            (TOGGLE_MESSAGE, Command::Toggle),
            (DISMISS_MESSAGE, Command::Dismiss),
        ] {
            let mut reader = Cursor::new(message);
            assert_eq!(
                read_command(&mut reader).expect("message should read"),
                Some(want),
                "{:?}",
                String::from_utf8_lossy(message)
            );
        }
    }

    #[test]
    fn unknown_and_unterminated_lines_are_ignored_rather_than_guessed_at() {
        for message in [
            &b"nonsense\n"[..],
            // A peer that connects and says nothing must not be read as a
            // command.
            b"",
            // Long enough to set the cap off, with no terminator anywhere.
            &[b'x'; MAX_COMMAND_LEN + 1],
        ] {
            let mut reader = Cursor::new(message);
            assert_eq!(
                read_command(&mut reader).expect("reading should not fail"),
                None,
                "{:?}",
                String::from_utf8_lossy(message)
            );
        }
    }

    #[test]
    fn lock_prevents_a_second_instance_from_replacing_the_socket() {
        let directory =
            std::env::temp_dir().join(format!("hypr-scratch-ipc-test-{}", std::process::id()));
        fs::create_dir_all(&directory).expect("test directory should be created");
        let socket = directory.join("scratch.sock");
        let first = acquire_instance_at(&socket).expect("first instance should acquire the socket");
        let second =
            acquire_instance_at(&socket).expect("second instance should reach the primary");

        assert!(matches!(second, AcquiredInstance::Secondary));
        assert!(
            socket.exists(),
            "a live primary socket must not be unlinked"
        );

        drop(first);
        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn toggle_message_is_small_and_unambiguous() {
        let (mut sender, mut receiver) = UnixStream::pair().expect("socket pair should be created");
        let writer = thread::spawn(move || {
            sender
                .write_all(TOGGLE_MESSAGE)
                .expect("message should write");
        });
        let mut message = [0_u8; 16];
        let bytes_read = receiver.read(&mut message).expect("message should read");
        writer.join().expect("writer should finish");
        assert_eq!(&message[..bytes_read], TOGGLE_MESSAGE);
    }
}
