//! A throwaway window for the acceptance suite, so the suite does not need a
//! terminal emulator on `PATH`.
//!
//! Gates 3 and 5 need a second window to click, focus and type into. That used to
//! be `kitty --class scratchsink -e cat`, which worked but made the suite depend
//! on a specific terminal being installed, configured, and able to run a command
//! line -- for a window whose only job is to display text and change pixels when
//! typed at. Anyone without kitty could not run the tests at all, and a terminal
//! also brings its own configuration into the picture: one of the suite's earlier
//! revisions failed for two runs because kitty had been resized and was swallowing
//! the click point.
//!
//! This is that window, in about a hundred lines, with no opinions. It is a
//! `[[bin]]` target rather than a mode of the main binary because it is test-only
//! and has no business in a shipped executable.

use gtk4 as gtk;
use gtk4::prelude::*;

/// The application ID, which is what Hyprland reports as the window class and
/// therefore what the suite selects on. Matches `SINK_CLASS` in `gates.sh`.
///
/// GTK 4 has no `set_wmclass` -- it went with the X11-only API -- so the class is
/// whatever the application ID says it is. A flat `scratchsink` would not do:
/// GApplication requires a dotted name of at least two elements.
const SINK_CLASS: &str = "dev.maxii.HyprScratchSink";

fn main() {
    let app = gtk::Application::builder()
        .application_id(SINK_CLASS)
        .build();

    app.connect_activate(|app| {
        // A big, opaque, high-contrast surface. Opaque on purpose: gate 5 proves
        // keystrokes reached this window by screenshotting it and counting
        // changed pixels, and a translucent window would report the blurred,
        // moving desktop underneath instead.
        let view = gtk::TextView::new();
        view.set_monospace(true);
        view.set_cursor_visible(true);
        view.set_wrap_mode(gtk::WrapMode::Word);
        view.set_margin_start(12);
        view.set_margin_end(12);
        view.set_margin_top(12);
        view.set_margin_bottom(12);

        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title(SINK_CLASS)
            .default_width(700)
            .default_height(400)
            .child(&view)
            .build();
        // The suite floats, pins and moves this window, and a selector that
        // matches nothing does not fail -- it acts on the focused window, which
        // during the suite is the notepad under test. So the class has to be
        // right the first time, which is why it comes from the application ID.
        window.present();
    });

    let _hold = app.hold();
    app.run();
}
