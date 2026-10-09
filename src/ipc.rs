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

/// Message bytes: `toggle` from the hotkey, `dismiss` from `--outside-click`.
const TOGGLE_MESSAGE: &[u8] = b"toggle\n";
const DISMISS_MESSAGE: &[u8] = b"dismiss\n";

const MAX_COMMAND_LEN: usize = 64;

/// Distinct commands: a click inside and a hotkey press look identical to the compositor.
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

/// Quiet on failure: this runs on every click, and a notepad that is not running is the common case.
pub fn send(command: Command) -> bool {
    // Checked before connecting, so the common case costs one `stat`.
    if !is_running() {
        return false;
    }
    let Ok(mut stream) = socket_path().and_then(UnixStream::connect) else {
        return false;
    };
    let _ = stream.set_write_timeout(Some(SEND_TIMEOUT));
    stream.write_all(command.message()).is_ok()
}

/// Just a `stat`, no connection: this is on the hot path of every click.
pub fn is_running() -> bool {
    socket_path().is_ok_and(|path| path.exists())
}

const SEND_TIMEOUT: Duration = Duration::from_millis(200);

/// Two atomics, not a channel: the GTK side has to poll either way.
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

/// Line-oriented, so a longer command is not truncated to a fixed length.
fn read_command(reader: &mut impl Read) -> io::Result<Option<Command>> {
    let mut line = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        match reader.read(&mut byte) {
            Ok(0) => break,
            Ok(_) if byte[0] == b'\n' => break,
            Ok(_) => {
                if line.len() == MAX_COMMAND_LEN {
                    // Never a real command; stop rather than buffer a peer with no newline.
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
                // A legacy primary may predate the lock file; offer it the toggle first.
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
                // The lock owner may not have bound its socket yet; retry instead of stealing it.
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

    /// Each command must raise its own flag and no other; a mix-up is silent.
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

    /// The whole `dismiss` path over a real socket, which may split the line.
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

    /// Feeds a message one byte per read, as a socket is free to do.
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

    /// `dismiss` is a byte longer than `toggle`, so a fixed-length reader would drop it silently.
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
            // A peer that connects and says nothing must not be read as a command.
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
