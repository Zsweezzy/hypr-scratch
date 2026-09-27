//! Minimal client for Hyprland's command socket.
//!
//! The notepad is an ordinary toplevel now, which is what makes dismissal work
//! at all: the compositor tracks it as a normal focusable window, so it loses
//! focus when the user looks at something else, and clicks reach the windows
//! underneath instead of being swallowed by a layer surface's keyboard grab.
//! Hyprland's window rules then make that plain window behave like an overlay
//! -- undecorated, always on top, centered.
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
/// `class` is the notepad's window class, and both dispatches name it
/// explicitly. An untargeted dispatch acts on whichever window happens to be
/// focused, and the placement runs a beat after the notepad maps -- before it is
/// reliably the active window -- so leaving it untargeted was enough to shuffle
/// whatever the user was actually working in.
///
/// Naming it explicitly is not sufficient on its own, and this is worth being
/// precise about: a selector that matches nothing is *not* an error. Hyprland
/// falls back to the focused window, so a typo here relocates the user's
/// editor instead of quietly doing nothing. The class is used rather than the
/// title for that reason -- it is fixed at launch from the application ID, it
/// is what the `hypr-scratch-overlay` rule matches, and a title is only as
/// reliable as the string handed to `set_title`.
///
/// Builds the two placement commands, or `None` if a value is not safe to
/// interpolate.
///
/// Pure and separate from the sending so the strings can be asserted on. That
/// matters more than it looks: a wrong command is not a crash, it is a dispatch
/// that matches nothing, which Hyprland answers by acting on the *focused*
/// window. Both bugs this function could plausibly have -- addressing the window
/// by title, and rejecting the dots in the class -- produced a well-formed
/// command that quietly did the wrong thing, and neither was caught by a build,
/// a test run, or a clean `hyprctl reload`.
fn commands_for(class: &str, monitor: &str) -> Option<[String; 2]> {
    if !is_plain(class) || !is_plain(monitor) {
        return None;
    }
    Some([
        format!(r#"hl.dsp.window.move({{ window = "class:{class}", monitor = "{monitor}" }})"#),
        format!(r#"hl.dsp.window.center({{ window = "class:{class}" }})"#),
    ])
}

/// Sent as two commands because the rules only centre at map time: without the
/// follow-up, a window that was opened on one monitor and then moved keeps the
/// position it was mapped at, which is not the middle of the new one.
pub fn move_and_center(class: &str, monitor: &str) {
    let Some(commands) = commands_for(class, monitor) else {
        return;
    };
    for command in commands {
        dispatch(&command);
    }
}

/// Sends one command, ignoring both the reply and any failure.
///
/// Fire and forget, silently. This is a cosmetic placement nudge, and a
/// compositor that is not listening is not worth an error dialog over a
/// scratchpad -- nor is a window that ends up centred on the wrong monitor,
/// which is what the Hyprland rule already gets right.
fn dispatch(command: &str) {
    let Ok(mut stream) = connect() else {
        return;
    };
    // Terminated with a newline, then closed by dropping the stream. The
    // terminator is belt and braces: closing alone is enough for the current
    // compositor, but a line-oriented reader would otherwise block until the
    // timeout and then discard the command.
    if stream.write_all(command.as_bytes()).is_err() {
        return;
    }
    let _ = stream.write_all(b"\n");
    let _ = stream.flush();
}

/// Whether a value is safe to interpolate into the Lua above.
///
/// Both values are fixed by this program rather than supplied by the user, so
/// this is belt and braces: the socket carries Lua that Hyprland evaluates, and
/// a stray quote would be code execution in the compositor.
///
/// `.` is allowed because the window class is `dev.maxii.HyprScratch` and
/// nothing else. Excluding it does not fail loudly -- `move_and_center` returns
/// early and the notepad is simply never placed, so it opens wherever the rule
/// mapped it. Every character that could end the string or start a new Lua
/// expression is still excluded.
fn is_plain(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

/// How long a `hyprctl` query may take before it is killed and ignored.
pub const QUERY_TIMEOUT: Duration = Duration::from_millis(500);

/// Runs `hyprctl` with `arguments` and returns its standard output.
///
/// A query has to be a real subprocess, unlike `dispatch`. The command socket
/// carries Lua that Hyprland evaluates and always answers `ok`, so there is no
/// way to read a value back over it; `hyprctl` is the only channel that reports
/// anything.
///
/// The wait is bounded and the output is drained on its own thread. Both details
/// are load-bearing: this runs on *every click* in the session, so a `hyprctl`
/// that never returns would leave a stuck process behind per click and they
/// would accumulate. And draining concurrently is what stops a large
/// `clients -j` -- which is well past the 64K pipe buffer on a busy desktop --
/// from filling the pipe, blocking the child, and deadlocking against a `try_wait`
/// loop that never gets to see the exit.
pub fn query(arguments: &[&str]) -> Option<String> {
    use std::io::Read;

    let mut child = std::process::Command::new("hyprctl")
        .args(arguments)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    let drained = child.stdout.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut buffer = Vec::new();
            let _ = pipe.read_to_end(&mut buffer);
            buffer
        })
    });

    let deadline = std::time::Instant::now() + QUERY_TIMEOUT;
    let finished = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if std::time::Instant::now() >= deadline => break None,
            Ok(None) => std::thread::sleep(Duration::from_millis(4)),
            Err(_) => break None,
        }
    };
    if finished.is_none() {
        let _ = child.kill();
    }
    // Reap it either way, so a killed child does not become a zombie.
    let _ = child.wait();

    if !finished?.success() {
        return None;
    }
    String::from_utf8(drained?.join().ok()?).ok()
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
    use super::{commands_for, is_plain};

    #[test]
    fn accepts_the_values_the_notepad_actually_sends() {
        // The real window class, and a monitor connector, as GTK and GDK report
        // them. The class is the one that matters: it contains dots, and a
        // filter that rejected them would make `move_and_center` a silent
        // no-op rather than a visible failure.
        assert!(is_plain(crate::ui::WINDOW_CLASS));
        for value in ["DP-1", "HDMI-A-1", "eDP-1", "DP_2", "hypr-scratch"] {
            assert!(is_plain(value), "{value} should be accepted");
        }
    }

    #[test]
    fn the_placement_commands_name_the_window_by_class() {
        let class = crate::ui::WINDOW_CLASS;
        let [move_command, center_command] =
            commands_for(class, "DP-1").expect("the real values are plain");
        // `class:` and not `title:`. Both reach the window, but the class is
        // fixed at launch from the application ID, whereas a title is only as
        // reliable as the string handed to `set_title`.
        assert_eq!(
            move_command,
            r#"hl.dsp.window.move({ window = "class:dev.maxii.HyprScratch", monitor = "DP-1" })"#
        );
        assert_eq!(
            center_command,
            r#"hl.dsp.window.center({ window = "class:dev.maxii.HyprScratch" })"#
        );
    }

    #[test]
    fn centring_is_sent_after_moving() {
        // Order is load-bearing. The rules only centre at map time, so without a
        // follow-up centre the window keeps the position it was mapped at.
        let commands = commands_for("dev.maxii.HyprScratch", "DP-2").unwrap();
        assert!(commands[0].contains("window.move"));
        assert!(commands[1].contains("window.center"));
    }

    #[test]
    fn an_unusable_value_produces_no_command_at_all() {
        // Not a partially-built command and not a broken one. A dispatch that
        // names no window falls back to the focused window, so sending nothing
        // is strictly better than sending something malformed.
        for (class, monitor) in [
            ("", "DP-1"),
            ("dev.maxii.HyprScratch", ""),
            ("dev.maxii.HyprScratch\"", "DP-1"),
            ("dev.maxii.HyprScratch", "DP-1\" } or 1"),
        ] {
            assert!(
                commands_for(class, monitor).is_none(),
                "{class:?} on {monitor:?} should produce nothing"
            );
        }
    }

    #[test]
    fn rejects_anything_that_could_escape_the_lua_string() {
        // These reach a Lua interpreter running inside the compositor. A dot is
        // allowed, so what matters is that nothing which can terminate the
        // string, start a new expression, or smuggle a separator through is.
        for hostile in [
            "",
            "DP-1\"",
            "a\" ); os.execute(\"id",
            "DP-1'",
            "DP 1",
            "DP-1\n",
            "dev.maxii.HyprScratch\"",
            "a.b\"c",
            "a b.c",
            "a}b",
            "a=b",
        ] {
            assert!(!is_plain(hostile), "{hostile:?} should be rejected");
        }
    }
}
