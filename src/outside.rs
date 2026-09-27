//! Deciding whether a click landed outside the notepad.
//!
//! This exists as a mode of the notepad's own binary rather than as a shell
//! script, and that is a deliberate trade. It started as
//! `hypr-scratch-outside-click.sh` and needed three things from the user's
//! `PATH`: `socat` to connect to the socket, and `jq` to read the rectangle out
//! of `hyprctl clients -j`. That is three ways for a click handler to silently do
//! nothing on somebody else's machine, and one of them had already happened --
//! `printf > "$socket"` opens a socket path `O_WRONLY` and gets `ENXIO`, so the
//! original script exited 0 having achieved nothing at all.
//!
//! Here the only external program involved is `hyprctl`, which is a given when
//! running under Hyprland, and the socket write is code this program already had.
//! A user who installs the binary and pastes two binds has a working
//! click-away, with nothing else to install and no script to keep in sync.
//!
//! # Why the compositor has to be involved at all
//!
//! GTK 4 removed the client-side pointer grab API outright -- `gdk::Seat` in
//! gdk4 0.11.5 has no `grab` method -- so a window that is not already grabbing
//! never hears about clicks outside itself. The notepad cannot take a grab to
//! find out, because a grab is exactly what it gave up: while one is held,
//! Hyprland will not move focus off the notepad, so focus-away dismissal stops
//! working *and* clicks on the windows underneath are swallowed. There is no
//! arrangement that observes both.
//!
//! `EventControllerMotion` does report the pointer crossing the notepad's edges,
//! but only on a *transition*, and the notepad is opened by a keybind -- so the
//! pointer is usually somewhere else already and never enters. Clicking the
//! desktop background then produces no event of any kind.

use serde_json::Value;

use crate::hypr;
use crate::ipc::{self, Command};
use crate::ui::WINDOW_CLASS;

/// An axis-aligned rectangle in the layout's logical coordinates, as `hyprctl`
/// reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    /// Whether a point is inside, with the edges counted as inside.
    ///
    /// Inclusive on purpose, and asymmetrically so: a click on the very edge of
    /// the notepad is a click *on the notepad*, and dismissing the window
    /// because the pointer happened to land on its border would make the
    /// notepad impossible to click along its edges. The one-pixel-outside cases
    /// are one pixel outside, not a rounding artefact of an inclusive test.
    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.left && x <= self.right && y >= self.top && y <= self.bottom
    }
}

/// Whether a click at `point` should dismiss the notepad.
///
/// `rect` is `None` when the notepad is not among the compositor's windows, which
/// is the normal state while the process is alive but the window is hidden. There
/// is then nothing to dismiss, and a `dismiss` would be a message telling the
/// notepad to hide a window that is not there.
pub fn should_dismiss(point: (i32, i32), rect: Option<Rect>) -> bool {
    match rect {
        None => false,
        Some(rect) => !rect.contains(point.0, point.1),
    }
}

/// Handles one compositor-reported click. Bound to bare LMB and RMB in
/// `hyprland.lua` with `non_consuming`, so the click still reaches whatever was
/// underneath: dismissing the notepad and focusing something else should be one
/// gesture, not two.
///
/// Must never kill the notepad. It has unsaved text and is expected to still be
/// there for the next hotkey, so this only ever sends a message. The notepad
/// flushes and hides when it receives it.
pub fn handle_click() {
    // Cheapest question first. This runs on every click in the session and the
    // overwhelmingly common case is that the notepad is closed, so that case
    // costs one `stat` and no subprocesses at all.
    if !ipc::is_running() {
        return;
    }

    let Some(point) = cursor_position() else {
        return;
    };
    if should_dismiss(point, notepad_rect()) {
        ipc::send(Command::Dismiss);
    }
}

/// Where the pointer is, as the compositor sees it.
///
/// `hyprctl cursorpos` prints two plain numbers, so this needs no JSON and is the
/// cheapest of the two queries.
fn cursor_position() -> Option<(i32, i32)> {
    let output = hypr::query(&["cursorpos"])?;
    let (x, y) = output.trim().split_once(',')?;
    Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
}

/// The notepad's rectangle, or `None` if it is not currently a window.
///
/// The only place this needs JSON. Unknown fields are ignored and the numbers are
/// taken by name, so a Hyprland release that adds keys does not break it, and one
/// that renames `at` degrades to "not present" -- which means clicks stop
/// dismissing, loudly, instead of dismissing on every click, which would be
/// unusable and so would be noticed.
fn notepad_rect() -> Option<Rect> {
    let clients = hypr::query(&["clients", "-j"])?;
    let parsed: Value = serde_json::from_str(&clients).ok()?;

    parsed
        .as_array()?
        .iter()
        .find(|client| client.get("class").and_then(Value::as_str) == Some(WINDOW_CLASS))
        .filter(|client| {
            !client
                .get("hidden")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .and_then(rect_from)
}

/// Reads the rectangle out of one client object.
///
/// Takes `at` and `size` as the two-element arrays `hyprctl` emits, and rejects
/// anything that is not a positive size, so a malformed entry cannot produce a
/// rectangle that swallows every click on the desktop.
fn rect_from(client: &Value) -> Option<Rect> {
    let pair = |key: &str| -> Option<[i32; 2]> {
        let values = client.get(key)?.as_array()?;
        Some([
            values.first()?.as_i64()? as i32,
            values.get(1)?.as_i64()? as i32,
        ])
    };
    let [x, y] = pair("at")?;
    let [width, height] = pair("size")?;
    if width <= 0 || height <= 0 {
        return None;
    }
    Some(Rect {
        left: x,
        top: y,
        right: x.saturating_add(width - 1),
        bottom: y.saturating_add(height - 1),
    })
}

#[cfg(test)]
mod tests {
    use super::{Rect, should_dismiss};

    /// A 640x480 panel at the top left, the shape the notepad actually has.
    const PANEL: Rect = Rect {
        left: 100,
        top: 200,
        right: 739,
        bottom: 679,
    };

    #[test]
    fn a_click_inside_or_on_the_edge_does_not_dismiss() {
        for (x, y) in [
            (100, 200), // the exact top-left corner
            (739, 679), // the exact bottom-right corner
            (100, 679), // the other two corners
            (739, 200),
            (419, 439), // the middle
            (101, 201), // one pixel in from a corner
        ] {
            assert!(
                !should_dismiss((x, y), Some(PANEL)),
                "({x},{y}) is on the notepad, so it must not dismiss it"
            );
        }
    }

    /// The distinction the whole feature rests on, tested one pixel at a time so
    /// a `<` quietly becoming `<=` cannot pass by accident on the far side.
    #[test]
    fn a_click_even_one_pixel_outside_dismisses() {
        for (x, y) in [
            (99, 439),  // one left of the panel
            (740, 439), // one right
            (419, 199), // one above
            (419, 680), // one below
            (0, 0),     // a far corner of the desktop
            (99, 199),  // diagonally outside a corner
        ] {
            assert!(
                should_dismiss((x, y), Some(PANEL)),
                "({x},{y}) is off the notepad, so it must dismiss it"
            );
        }
    }

    /// A hidden notepad has nothing to dismiss, and telling it to hide would be
    /// a message about a window that is not there.
    #[test]
    fn a_hidden_notepad_is_never_dismissed() {
        assert!(!should_dismiss((0, 0), None));
        assert!(!should_dismiss((419, 439), None));
    }

    /// Zero is not a border case to be handled at the call site; it is a reason to
    /// refuse to build a rectangle at all, because a zero-sized one at the origin
    /// contains nothing and would dismiss every click in the session.
    #[test]
    fn a_degenerate_rectangle_is_not_built() {
        use serde_json::json;
        assert_eq!(
            super::rect_from(&json!({ "at": [10, 10], "size": [0, 480] })),
            None
        );
        assert_eq!(
            super::rect_from(&json!({ "at": [10, 10], "size": [640, -1] })),
            None
        );
        // Missing keys and wrong types are refused rather than defaulted.
        assert_eq!(super::rect_from(&json!({ "at": [10, 10] })), None);
        assert_eq!(
            super::rect_from(&json!({ "at": [10], "size": [1, 1] })),
            None
        );
        assert_eq!(super::rect_from(&json!({})), None);
    }

    /// The rectangle the notepad's own client entry should produce, checked
    /// against a real `hyprctl clients -j` entry so the field names and the
    /// off-by-one in the far edges are pinned to what the compositor says.
    #[test]
    fn a_real_client_entry_becomes_the_right_rectangle() {
        use serde_json::json;
        let client = json!({
            "at": [2560, 317],
            "size": [640, 480],
            "class": WINDOW_CLASS_FOR_TEST,
            "workspace": {"name": "1", "id": 1},
            "floating": true,
            "hidden": false,
        });
        assert_eq!(
            super::rect_from(&client),
            Some(Rect {
                left: 2560,
                top: 317,
                // `size` is a width, so the last covered pixel is at +639, not
                // +640. Getting this wrong by one makes the right and bottom
                // edges one pixel too generous.
                right: 3199,
                bottom: 796,
            })
        );
    }

    const WINDOW_CLASS_FOR_TEST: &str = crate::ui::WINDOW_CLASS;
}
