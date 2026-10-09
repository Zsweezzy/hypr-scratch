
use serde_json::Value;

use crate::hypr;
use crate::ipc::{self, Command};
use crate::ui::WINDOW_CLASS;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    pub fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.left && x <= self.right && y >= self.top && y <= self.bottom
    }

    pub fn centre(&self) -> (i32, i32) {
        ((self.left + self.right) / 2, (self.top + self.bottom) / 2)
    }
}

pub fn should_dismiss(point: (i32, i32), rect: Option<Rect>) -> bool {
    match rect {
        None => false,
        Some(rect) => !rect.contains(point.0, point.1),
    }
}

pub fn handle_click() {
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

pub fn warp_into_notepad() {
    if !ipc::is_running() {
        return;
    }
    let Some(rect) = notepad_rect() else {
        return;
    };
    let (x, y) = rect.centre();
    hypr::move_cursor(x, y);
}

fn cursor_position() -> Option<(i32, i32)> {
    let output = hypr::query(&["cursorpos"])?;
    let (x, y) = output.trim().split_once(',')?;
    Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
}

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

    const PANEL: Rect = Rect {
        left: 100,
        top: 200,
        right: 739,
        bottom: 679,
    };

    #[test]
    fn a_click_inside_or_on_the_edge_does_not_dismiss() {
        for (x, y) in [
            (100, 200),
            (739, 679),
            (100, 679),
            (739, 200),
            (419, 439),
            (101, 201),
        ] {
            assert!(
                !should_dismiss((x, y), Some(PANEL)),
                "({x},{y}) is on the notepad, so it must not dismiss it"
            );
        }
    }

    #[test]
    fn a_click_even_one_pixel_outside_dismisses() {
        for (x, y) in [
            (99, 439),
            (740, 439),
            (419, 199),
            (419, 680),
            (0, 0),
            (99, 199),
        ] {
            assert!(
                should_dismiss((x, y), Some(PANEL)),
                "({x},{y}) is off the notepad, so it must dismiss it"
            );
        }
    }

    #[test]
    fn a_hidden_notepad_is_never_dismissed() {
        assert!(!should_dismiss((0, 0), None));
        assert!(!should_dismiss((419, 439), None));
    }

    #[test]
    fn the_panel_centre_is_the_middle_pixel() {
        assert_eq!(PANEL.centre(), (419, 439));
    }

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
        assert_eq!(super::rect_from(&json!({ "at": [10, 10] })), None);
        assert_eq!(
            super::rect_from(&json!({ "at": [10], "size": [1, 1] })),
            None
        );
        assert_eq!(super::rect_from(&json!({})), None);
    }

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
                right: 3199,
                bottom: 796,
            })
        );
    }

    const WINDOW_CLASS_FOR_TEST: &str = crate::ui::WINDOW_CLASS;
}
