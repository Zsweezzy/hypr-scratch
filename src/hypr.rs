//! Minimal client for Hyprland's command socket.
//!
//! The notepad is an ordinary toplevel now, which is what finally makes
//! click-away and focus-away dismissal work: GTK updates `has-focus` normally,
//! and clicks pass through to whatever is underneath instead of being swallowed
//! by a keyboard grab. Hyprland's window rules then make that plain window
//! behave like an overlay -- undecorated, always on top, centered.
//!
//! Rules cannot do everything, though. They apply once, at map time, and they
//! cannot name a monitor, so "always open on the main display" has to be asked
//! for at runtime. That is the only thing this module does.
//!
//! What goes over the socket is Lua that Hyprland evaluates, so the one value
//! that comes from outside the program -- a monitor connector name -- is
//! checked instead of quoted and escaped. Connectors are `[A-Za-z0-9_-]`;
//! anything else is dropped rather than pasted into the script.

use std::{
    env,
    io::{self, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    time::Duration,
};

const COMMAND_TIMEOUT: Duration = Duration::from_millis(500);

/// Moves the notepad onto `monitor` and centers it there.
///
/// Both dispatches name the window explicitly. An untargeted one acts on
/// whichever window happens to be focused, and the placement runs a beat after
/// the notepad maps -- before it is reliably the active window -- so leaving it
/// untargeted was enough to shuffle whatever the user was actually working in.
///
/// Sent as two commands because the rules only centre at map time: without the
/// follow-up, a window that was opened on one monitor and then moved keeps the
/// position it was mapped at, which is not the middle of the new one.
pub fn move_and_center(title: &str, monitor: &str) {
    if !is_plain(title) || !is_plain(monitor) {
        return;
    }
    dispatch(&format!(
        "hl.dsp.window.move({{ window = \"title:{title}\", monitor = \"{monitor}\" }})"
    ));
    dispatch(&format!(
        "hl.dsp.window.center({{ window = \"title:{title}\" }})"
    ));
}

/// Sends one command, ignoring the reply. Fire and forget: this is a cosmetic
/// placement nudge, and a compositor that is not listening is not worth an
/// error dialog over a scratchpad.
fn dispatch(command: &str) -> bool {
    let Ok(mut stream) = connect() else {
        return false;
    };
    if stream.write_all(command.as_bytes()).is_err() {
        return false;
    }
    // Dropping the stream closes it, which is how Hyprland learns the command
    // is complete. There is no reply worth waiting for.
    let _ = stream.flush();
    true
}

/// Whether a value is safe to interpolate into the Lua above.
///
/// Both values are fixed by this program rather than supplied by the user, so
/// this is belt and braces: the socket carries Lua that Hyprland evaluates, and
/// a stray quote would be code execution in the compositor.
fn is_plain(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
}

fn connect() -> io::Result<UnixStream> {
    let stream = UnixStream::connect(socket_path()?)?;
    stream.set_write_timeout(Some(COMMAND_TIMEOUT))?;
    Ok(stream)
}

fn socket_path() -> io::Result<PathBuf> {
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    let signature = env::var_os("HYPRLAND_INSTANCE_SIGNATURE").ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "HYPRLAND_INSTANCE_SIGNATURE is not set",
        )
    })?;
    Ok(runtime_dir
        .join("hypr")
        .join(signature)
        .join(".socket.sock"))
}

#[cfg(test)]
mod tests {
    use super::is_plain;

    #[test]
    fn accepts_the_values_the_notepad_actually_sends() {
        // A window title and a monitor connector, as GTK and GDK report them.
        for value in ["hypr-scratch", "DP-1", "HDMI-A-1", "eDP-1", "DP_2"] {
            assert!(is_plain(value), "{value} should be accepted");
        }
    }

    #[test]
    fn rejects_anything_that_could_escape_the_lua_string() {
        // These reach a Lua interpreter running inside the compositor.
        for hostile in [
            "",
            "DP-1\"",
            "a\" ); os.execute(\"id",
            "DP-1'",
            "DP 1",
            "DP-1\n",
        ] {
            assert!(!is_plain(hostile), "{hostile:?} should be rejected");
        }
    }
}
