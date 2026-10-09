//! Minimal client for Hyprland's command socket.

use std::{
    env,
    io::{self, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    time::Duration,
};

const COMMAND_TIMEOUT: Duration = Duration::from_millis(500);

/// Both dispatches name the window by class: a selector matching nothing acts on the focused window.
fn commands_for(class: &str, monitor: &str) -> Option<[String; 2]> {
    if !is_plain(class) || !is_plain(monitor) {
        return None;
    }
    Some([
        format!(r#"hl.dsp.window.move({{ window = "class:{class}", monitor = "{monitor}" }})"#),
        format!(r#"hl.dsp.window.center({{ window = "class:{class}" }})"#),
    ])
}

/// Centring is sent after the move: the window rule only centres at map time.
pub fn move_and_center(class: &str, monitor: &str) {
    let Some(commands) = commands_for(class, monitor) else {
        return;
    };
    for command in commands {
        dispatch(&command);
    }
}

/// `hl.dsp.cursor.move` is the spelling proven in `scripts/gates.sh`.
fn cursor_command(x: i32, y: i32) -> String {
    format!("hl.dsp.cursor.move({{ x = {x}, y = {y} }})")
}

/// Warps the pointer into the notepad so a stray click does not dismiss it.
pub fn move_cursor(x: i32, y: i32) {
    dispatch(&cursor_command(x, y));
}

/// Fire-and-forget; failures are ignored.
fn dispatch(command: &str) {
    let Ok(mut stream) = connect() else {
        return;
    };
    // Terminated with a newline, then closed by dropping the stream.
    if stream.write_all(command.as_bytes()).is_err() {
        return;
    }
    let _ = stream.write_all(b"\n");
    let _ = stream.flush();
}

/// The socket carries Lua, so `.` is allowed only because the window class contains dots.
fn is_plain(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

pub const QUERY_TIMEOUT: Duration = Duration::from_millis(500);

/// Drains stdout on its own thread and bounds the wait: a full pipe would deadlock `hyprctl clients -j`.
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
    use super::{commands_for, cursor_command, is_plain};

    #[test]
    fn accepts_the_values_the_notepad_actually_sends() {
        // The real class contains dots; a filter rejecting them silently no-ops.
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
        // `class:`, not `title:`; the class is fixed at launch from the app ID.
        assert_eq!(
            move_command,
            r#"hl.dsp.window.move({ window = "class:dev.Zsweezzy.HyprScratch", monitor = "DP-1" })"#
        );
        assert_eq!(
            center_command,
            r#"hl.dsp.window.center({ window = "class:dev.Zsweezzy.HyprScratch" })"#
        );
    }

    #[test]
    fn centring_is_sent_after_moving() {
        // Order is load-bearing: the rules only centre at map time.
        let commands = commands_for("dev.Zsweezzy.HyprScratch", "DP-2").unwrap();
        assert!(commands[0].contains("window.move"));
        assert!(commands[1].contains("window.center"));
    }

    #[test]
    fn the_cursor_command_targets_the_notepad_centre() {
        // The exact spacing is part of the contract with Hyprland's Lua.
        assert_eq!(
            cursor_command(419, 439),
            r#"hl.dsp.cursor.move({ x = 419, y = 439 })"#
        );
    }

    #[test]
    fn an_unusable_value_produces_no_command_at_all() {
        // Sending nothing beats a malformed command: a nameless dispatch acts on the focused window.
        for (class, monitor) in [
            ("", "DP-1"),
            ("dev.Zsweezzy.HyprScratch", ""),
            ("dev.Zsweezzy.HyprScratch\"", "DP-1"),
            ("dev.Zsweezzy.HyprScratch", "DP-1\" } or 1"),
        ] {
            assert!(
                commands_for(class, monitor).is_none(),
                "{class:?} on {monitor:?} should produce nothing"
            );
        }
    }

    #[test]
    fn rejects_anything_that_could_escape_the_lua_string() {
        // These reach a Lua interpreter inside the compositor: nothing that can break out of the string may pass.
        for hostile in [
            "",
            "DP-1\"",
            "a\" ); os.execute(\"id",
            "DP-1'",
            "DP 1",
            "DP-1\n",
            "dev.Zsweezzy.HyprScratch\"",
            "a.b\"c",
            "a b.c",
            "a}b",
            "a=b",
        ] {
            assert!(!is_plain(hostile), "{hostile:?} should be rejected");
        }
    }
}
