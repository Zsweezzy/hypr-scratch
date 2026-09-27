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

const TOGGLE_MESSAGE: &[u8] = b"toggle\n";

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
    pub fn spawn_toggle_listener(self, toggle_requested: Arc<AtomicBool>) -> JoinHandle<()> {
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
                if read_toggle_message(&mut stream).unwrap_or(false) {
                    toggle_requested.store(true, Ordering::SeqCst);
                }
            }
            let _ = fs::remove_file(&path);
            drop(_lock);
        })
    }
}

fn read_toggle_message(reader: &mut impl Read) -> io::Result<bool> {
    let mut message = [0_u8; TOGGLE_MESSAGE.len()];
    reader.read_exact(&mut message)?;
    Ok(message == TOGGLE_MESSAGE)
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

fn socket_path() -> io::Result<PathBuf> {
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let uid = unsafe { libc::getuid() };
    Ok(runtime_dir.join(format!("hypr-scratch-{uid}.sock")))
}

#[cfg(test)]
mod tests {
    use super::{AcquiredInstance, TOGGLE_MESSAGE, acquire_instance_at, read_toggle_message};
    use std::fs;
    use std::io::{self, Read, Write};
    use std::os::unix::net::UnixStream;
    use std::thread;

    #[test]
    fn reads_fragmented_toggle_messages() {
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

        let mut reader = Fragmented {
            bytes: TOGGLE_MESSAGE,
            position: 0,
        };
        assert!(read_toggle_message(&mut reader).expect("fragmented message should be read"));
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
