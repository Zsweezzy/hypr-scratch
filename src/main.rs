mod hypr;
mod ipc;
mod outside;
mod store;
mod ui;

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gtk4 as gtk;
use gtk4::{gio::prelude::*, glib};

use crate::store::NOTE_PATH_ENV;

fn main() {
    // Fallback for the case where no desktop portal is answering: GTK_THEME is
    // ignored when the portal supplies `gtk-theme`, so the real pin lives in
    // `ui::create_window`, which sets it through GtkSettings instead.
    //
    // SAFETY: `main` is single-threaded at this point and no other thread has
    // been spawned, so there is no concurrent reader of the environment.
    unsafe { std::env::set_var("GTK_THEME", "Adwaita:dark") };

    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments
        .iter()
        .any(|argument| argument == "--version" || argument == "-V")
    {
        println!("hypr-scratch {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if arguments
        .iter()
        .any(|argument| argument == "--help" || argument == "-h")
    {
        println!("Usage: hypr-scratch [--toggle] [--background]");
        println!("Open or toggle the floating scratchpad notepad.");
        println!("--background starts the persistent instance without showing the notepad.");
        println!();
        println!("For the Hyprland config, not for running by hand:");
        println!("  --outside-click   Check whether a click landed outside the notepad and,");
        println!("                    if so, tell it to save and hide. Meant to be bound to");
        println!("                    bare LMB/RMB with non_consuming.");
        println!("  --print-config    Print the paths this build would use, and exit.");
        println!();
        println!(
            "Notes are saved to ~/Documents/scratchpad.md; set {NOTE_PATH_ENV} to change that."
        );
        println!(
            "Colours and opacity come from {}",
            ui::style_path().display()
        );
        return;
    }

    // Handled before anything is initialised, and in particular before GTK: this
    // runs on every click in the session, so it must not open a display
    // connection, set up a `GtkApplication`, or touch the instance socket. It
    // either finds a running notepad and sends it one line, or does nothing.
    if arguments
        .iter()
        .any(|argument| argument == "--outside-click")
    {
        outside::handle_click();
        return;
    }
    if arguments
        .iter()
        .any(|argument| argument == "--print-config")
    {
        println!("note:  {}", store::default_path().display());
        println!("style: {}", ui::style_path().display());
        println!(
            "socket: {}",
            ipc::socket_path().map_or_else(
                |error| format!("<unavailable: {error}>"),
                |path| path.display().to_string(),
            )
        );
        return;
    }
    let start_visible = !arguments
        .iter()
        .any(|argument| argument == "--background" || argument == "-b");

    let pending = Arc::new(ipc::PendingCommands::default());
    let _listener_thread = match ipc::acquire_instance() {
        Ok(ipc::AcquiredInstance::Primary(instance)) => {
            Some(instance.spawn_listener(pending.clone()))
        }
        // Another instance already owns the socket. It just received our
        // toggle, so this process has nothing left to do.
        Ok(ipc::AcquiredInstance::Secondary) => return,
        Err(error) => {
            eprintln!("could not start scratchpad instance: {error}");
            return;
        }
    };

    let app = gtk::Application::builder()
        .application_id(crate::ui::WINDOW_CLASS)
        .build();
    app.add_main_option(
        "toggle",
        glib::Char::from(b't'),
        glib::OptionFlags::NONE,
        glib::OptionArg::None,
        "Toggle the notepad (the default)",
        None,
    );
    app.add_main_option(
        "background",
        glib::Char::from(b'b'),
        glib::OptionFlags::NONE,
        glib::OptionArg::None,
        "Start the persistent instance without showing the notepad",
        None,
    );
    let ui: Rc<RefCell<Option<ui::UiHandle>>> = Rc::new(RefCell::new(None));

    app.connect_activate({
        let ui = ui.clone();
        let pending = pending.clone();
        move |app| {
            if let Some(existing) = ui.borrow().as_ref() {
                existing.toggle();
            } else {
                *ui.borrow_mut() = Some(ui::create_window(app, pending.clone(), start_visible));
            }
        }
    });

    // Keep the process alive after the notepad is hidden. The per-user Unix
    // socket forwards later invocations here, so the hotkey toggles one
    // notepad instead of starting a second copy.
    let _hold = app.hold();
    app.run();
}
