
use gtk4 as gtk;
use gtk4::prelude::*;

/// The application ID (the window class the suite selects on); GApplication requires a dotted name.
const SINK_CLASS: &str = "dev.Zsweezzy.HyprScratchSink";

fn main() {
    let app = gtk::Application::builder()
        .application_id(SINK_CLASS)
        .build();

    app.connect_activate(|app| {
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
        // A selector matching nothing acts on the focused window, so the class must be right the first time.
        window.present();
    });

    let _hold = app.hold();
    app.run();
}
