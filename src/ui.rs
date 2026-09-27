use std::{
    cell::{Cell, RefCell},
    env,
    path::PathBuf,
    rc::Rc,
    sync::Arc,
    time::Duration,
};

use gtk4 as gtk;
use gtk4::{
    gdk,
    glib::{self, ControlFlow, Propagation},
    prelude::*,
};

use crate::{
    hypr,
    ipc::PendingCommands,
    store::{NoteStore, expand_home},
};

const PANEL_WIDTH: i32 = 640;
const PANEL_HEIGHT: i32 = 480;
const PANEL_MIN_WIDTH: i32 = 360;
const PANEL_MIN_HEIGHT: i32 = 240;
/// Window title, shown in the compositor's window list.
const WINDOW_TITLE: &str = "hypr-scratch";
/// The GTK application ID, which is what Hyprland reports as the window class.
///
/// This, not the title, is how `hypr::move_and_center` addresses the notepad. A
/// dispatch that cannot name its window does not fail: it falls back to whatever
/// is focused, which is a good way to move the window the user is actually
/// working in. The class is the stabler of the two -- it comes from the
/// application ID and is fixed at launch, whereas a title is only as good as the
/// string passed to `set_title` -- and it is what the `hypr-scratch-overlay`
/// rule already matches, so the rule and the dispatch cannot disagree about
/// which window is meant.
pub const WINDOW_CLASS: &str = "dev.maxii.HyprScratch";
const MAIN_MONITOR_ENV: &str = "HYPR_SCRATCH_MONITOR";

/// Style provider priority, deliberately above every level GTK itself uses.
///
/// `STYLE_PROVIDER_PRIORITY_APPLICATION` is 600, but `..._USER` is 800, and the
/// user stylesheet at `~/.config/gtk-4.0/gtk.css` is loaded at that level. At
/// 600 the notepad silently lost to it: the theme's `textview text` and
/// `textview border` rules painted the editor's internal nodes an opaque
/// #323449, so the surface was opaque, its rounded corners showed square edges
/// behind them, and there was nothing behind the surface for Hyprland to blur.
/// 1000 outranks the user stylesheet, which is what makes the panel frosted.
const CSS_PRIORITY: u32 = 1000;
/// How long the note must sit idle before it is written to disk.
const AUTOSAVE_DEBOUNCE: Duration = Duration::from_millis(500);
/// How long after mapping to ask Hyprland to move the notepad onto the main
/// monitor. Long enough for the window rules to have been applied.
const PLACEMENT_DELAY: Duration = Duration::from_millis(80);

/// How often the socket thread's flags are applied.
///
/// Short enough that a click feels like it did something, long enough that this
/// is not a busy loop on a machine that is otherwise idle.
const POLL_INTERVAL: Duration = Duration::from_millis(8);

pub struct UiHandle(Rc<ScratchUi>);

impl UiHandle {
    pub fn toggle(&self) {
        self.0.toggle();
    }
}

struct ScratchUi {
    window: gtk::ApplicationWindow,
    editor: gtk::TextView,
    buffer: gtk::TextBuffer,
    counts: gtk::Label,
    cursor: gtk::Label,
    store: NoteStore,
    save_timer: RefCell<Option<glib::SourceId>>,
    dirty: Cell<bool>,
    pending: Arc<PendingCommands>,
    /// Connector the notepad should open on, if one could be chosen.
    target_monitor: Option<String>,
    /// Set once the window has actually become the active toplevel, and cleared
    /// again when it is hidden. Activation is only worth reacting to after that:
    /// mapping a window and activating it are separate steps, so a window that is
    /// merely on its way up is not yet active, and treating that as "the user
    /// moved on" would make the notepad close the instant it opened.
    armed_for_focus_loss: Cell<bool>,
}

pub fn create_window(
    app: &gtk::Application,
    pending: Arc<PendingCommands>,
    start_visible: bool,
) -> UiHandle {
    // Pin the theme through GtkSettings rather than the environment: on Wayland
    // GTK4 reads `gtk-theme` from the xdg-desktop-portal, and that wins over
    // GTK_THEME. Tokyonight-Dark-Moon ships
    // `textview text { background-color: #323449; }`, and that inner node is
    // what the text view actually draws, so the panel came out opaque -- which
    // leaked a square edge past the rounded corners and left the compositor
    // nothing to blur. Setting this before any widget exists keeps that rule
    // from ever being loaded. Every colour the app uses is in `install_css`, so
    // nothing is lost.
    if let Some(settings) = gtk::Settings::default() {
        settings.set_gtk_theme_name(Some("Adwaita-dark"));
    }

    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title(WINDOW_TITLE)
        .default_width(PANEL_WIDTH)
        .default_height(PANEL_HEIGHT)
        .build();
    // Undecorated is set before anything else can map the window, or the
    // notepad flashes a titlebar on the way up.
    window.set_decorated(false);
    window.set_resizable(true);
    window.add_css_class("scratch-window");
    configure_overlay_window(&window);
    install_css();

    // Window rules centre the notepad on whichever monitor it opens on, so
    // getting it onto the main display -- and re-centred once it is there --
    // has to be asked of the compositor at runtime. See `hypr::move_and_center`.
    let target_monitor =
        select_main_monitor().and_then(|monitor| monitor.connector().map(String::from));

    let store = NoteStore::from_env();
    let contents = match store.load() {
        Ok(contents) => contents,
        Err(error) => {
            eprintln!(
                "hypr-scratch: could not read {}: {error}",
                store.path().display()
            );
            String::new()
        }
    };

    let (counts, cursor, footer) = build_footer();
    let (view, scroller) = build_editor();
    scroller.set_vexpand(true);

    let panel = gtk::Box::new(gtk::Orientation::Vertical, 0);
    panel.set_size_request(PANEL_MIN_WIDTH, PANEL_MIN_HEIGHT);
    panel.append(&scroller);
    panel.append(&footer);
    panel.add_css_class("scratch-panel");

    window.set_child(Some(&panel));

    let buffer = view.buffer();
    buffer.set_text(&contents);

    let ui = Rc::new(ScratchUi {
        window,
        editor: view,
        buffer,
        counts,
        cursor,
        store,
        save_timer: RefCell::new(None),
        dirty: Cell::new(false),
        pending,
        target_monitor,
        armed_for_focus_loss: Cell::new(false),
    });

    // Every keystroke refreshes the footer and restarts the autosave debounce.
    {
        let signal_ui = ui.clone();
        ui.buffer.connect_changed(move |_| {
            signal_ui.update_counts();
            signal_ui.dirty.set(true);
            signal_ui.schedule_save();
        });
    }

    // Cursor moves do not change the text, so they only move the position
    // readout. Insertions and deletions also fire this, which is harmless.
    {
        let signal_ui = ui.clone();
        ui.buffer
            .connect_mark_set(move |_, _, _| signal_ui.update_cursor());
    }

    install_shortcuts(&ui);
    install_close_flush(&ui);
    install_focus_dismissal(&ui);
    install_placement(&ui);

    // The socket thread only sets flags; the GTK main loop applies them.
    {
        let ui = ui.clone();
        glib::timeout_add_local(POLL_INTERVAL, move || {
            // Both flags are taken every pass, whatever is done with them.
            // Leaving one set for a later pass would strand it: a `dismiss`
            // read alongside a `toggle` would sit in the queue and then fire
            // against the window that toggle had just opened, closing the
            // notepad the user had only just asked for.
            let toggle = ui.pending.take_toggle();
            let dismiss = ui.pending.take_dismiss();
            if toggle {
                // An explicit request outranks an incidental click that landed
                // in the same few milliseconds.
                ui.toggle();
            } else if dismiss && on_outside_click(ui.window.is_visible()) {
                ui.hide();
            }
            ControlFlow::Continue
        });
    }

    ui.update_counts();
    ui.update_cursor();

    if start_visible {
        ui.show();
    } else {
        ui.window.hide();
    }

    UiHandle(ui)
}

/// Makes an ordinary toplevel behave like a scratchpad.
///
/// The notepad used to be a layer surface, which is a dead end for a text
/// editor that has to give the keyboard back: an exclusive layer surface takes
/// a grab, and while it is held Hyprland will not move focus off it, so clicks
/// on the windows underneath are swallowed and no keybind focus change is
/// delivered. `OnDemand` is no escape -- the surface never gains the keyboard at
/// all, not even when clicked. As a normal window it gets real focus semantics,
/// so both dismissals work, and clicks reach whatever is underneath.
///
/// The rest of the overlay behaviour -- always on top, floating so it is never
/// tiled, centred, and blurred -- now has to come from the
/// `hypr-scratch-overlay` rule in `hyprland.lua`, matched on the window class.
/// That class is the GTK application ID verbatim, `dev.maxii.HyprScratch`, and
/// not the `hypr-scratch` the layer-surface namespace used to be. GTK4 removed
/// the window hints that would do it from the client side (`set_keep_above`,
/// `set_skip_taskbar_hint`, `set_skip_pager_hint` and `set_type_hint` no longer
/// exist on `GtkWindow`), so those rules are not a nicety: without them the
/// notepad opens tiled, snapped to the layout, and listed for every switcher.
/// The one overlay hint GTK4 still lets the client set.
///
/// The name is historical: there is nothing to configure here. Everything that
/// made this window an overlay -- always on top, floating, centred, unpinned
/// from the layout, blurred -- comes from the `hypr-scratch-overlay` rule
/// described above, and `set_deletable(false)` is what is left.
///
/// It is worth being precise about what it does, because the obvious reading is
/// wrong. It suppresses the *client-side* destroy affordance; it does not stop
/// a close request arriving from the compositor. `install_close_flush` is what
/// handles that, and the two are not interchangeable.
fn configure_overlay_window(window: &gtk::ApplicationWindow) {
    window.set_deletable(false);
}

/// The dismissal decision, as a pure function: `(armed_after, dismiss)`.
///
/// Split out from the GTK signal because the interesting cases are the ones
/// that must *not* dismiss, and those are impossible to provoke through a real
/// compositor. Every one of the eight combinations is a test below.
fn on_focus_change(armed: bool, is_active: bool, is_visible: bool) -> (bool, bool) {
    if is_active {
        // The compositor has really given us the keyboard. From here on, losing
        // it means the user moved on, rather than that the window is still on
        // its way up and has not been activated yet.
        (true, false)
    } else {
        // Disarm on the way past whether or not we act, so a hidden window
        // cannot be dismissed a second time and `show` has to re-arm.
        (false, armed && is_visible)
    }
}

/// Closes the notepad when the user focuses another window, which is what
/// clicking another window does.
///
/// This is the whole reason the notepad is a normal window. A layer surface has
/// to take a keyboard grab to receive the keyboard, and while the grab is held
/// Hyprland will not move focus off it, so there is nothing to observe: clicks
/// underneath went nowhere, focus keybinds went nowhere, and no compositor event
/// was emitted. A real toplevel gets honest focus semantics, so the compositor
/// is free to take the activation away -- and then this fires.
///
/// It is worth being precise that this is a *focus* check, and that it alone
/// cannot cover every click. Clicking the desktop background, or a window
/// marked `nofocus`, moves no focus, so on its own this path leaves the notepad
/// up. `on_outside_click` covers the rest, from the other direction.
///
/// The property to watch is `is-active`, not `has-focus`. On Wayland GTK never
/// sets `has-focus` on a toplevel at all: it stays `false` for the window's
/// entire life while the window is visibly up and receiving every keystroke, so
/// a dismissal built on it compiles, installs, and never runs. `is-active` does
/// track the compositor's view.
fn install_focus_dismissal(ui: &Rc<ScratchUi>) {
    let signal_ui = ui.clone();
    ui.window.connect_is_active_notify(move |window| {
        let (armed, dismiss) = on_focus_change(
            signal_ui.armed_for_focus_loss.get(),
            window.is_active(),
            window.is_visible(),
        );
        signal_ui.armed_for_focus_loss.set(armed);
        if dismiss {
            signal_ui.hide();
        }
    });
}

/// Whether a click the compositor reported as outside should dismiss.
///
/// This cannot be decided in the client, and the reason is worth writing down
/// rather than rediscovering. GTK4 removed the client-side pointer grab API
/// outright -- `gdk::Seat` has no `grab` method at all -- so a window that is not
/// already grabbing never hears about clicks outside itself. The notepad cannot
/// take a grab to find out, because a grab is exactly what it gave up: while one
/// is held Hyprland will not move focus off the notepad, so focus-away dismissal
/// stops working and clicks on the windows underneath are swallowed. There is no
/// arrangement that observes both.
///
/// GTK can still report the pointer crossing the notepad's edges
/// (`EventControllerMotion`), but that only fires on a *transition*. Opening the
/// notepad is a keybind, so the pointer is usually somewhere else already and
/// never enters; clicking the background then produces no event of any kind. So
/// hover tracking cannot cover the case either, which is why the compositor tells
/// us instead: `hypr-scratch --outside-click`, bound to bare LMB and RMB in the
/// user's Hyprland config with `non_consuming` so the click still reaches
/// whatever was underneath, sends `Command::Dismiss` over the existing socket
/// once it has established that the click landed outside this window's rect.
///
/// The visibility check is not padding. That mode already declines to send
/// anything when it cannot find the window, so what this catches is the gap
/// between a `hide()` and the poll that would have consumed the message -- and a
/// window started with `--background`, which has never been shown and must not be
/// hidden by a click it never saw.
fn on_outside_click(is_visible: bool) -> bool {
    is_visible
}

/// Nudges the notepad onto the main monitor once it is up.
///
/// Deliberately not done during the map: the window rules have to be applied
/// first, and moving a window that the compositor has not finished creating is
/// a race. Waiting a beat is invisible next to the click that opened the
/// notepad.
///
/// The visibility re-check is not defensive padding, it is the whole point.
/// `PLACEMENT_DELAY` is long enough that the notepad can be gone before the
/// timer fires -- a double-tap of the hotkey, or `Esc` inside the delay. An
/// untargeted dispatch acts on whatever is focused, and although this one
/// *does* name the notepad, a selector that matches nothing is not an error:
/// Hyprland falls back to the focused window and moves that instead, to the
/// centre of the main monitor. The user's editor, relocated by a notepad they
/// had already dismissed.
fn install_placement(ui: &Rc<ScratchUi>) {
    let signal_ui = ui.clone();
    ui.window.connect_map(move |_| {
        let target = signal_ui.target_monitor.clone();
        // Cloned rather than reaching back through `signal_ui`, which the outer
        // closure owns and cannot lend to a `move` closure.
        let window = signal_ui.window.clone();
        glib::timeout_add_local(PLACEMENT_DELAY, move || {
            if window.is_visible()
                && let Some(target) = target.as_deref()
            {
                hypr::move_and_center(WINDOW_CLASS, target);
            }
            ControlFlow::Break
        });
    });
}

/// Picks the monitor to center on: an explicit `HYPR_SCRATCH_MONITOR`
/// connector if set, otherwise the largest physical display.
fn select_main_monitor() -> Option<gdk::Monitor> {
    let display = gdk::Display::default()?;
    let model = display.monitors();
    let monitors: Vec<_> = (0..model.n_items())
        .filter_map(|index| model.item(index)?.downcast::<gdk::Monitor>().ok())
        .collect();

    let preferred = env::var(MAIN_MONITOR_ENV)
        .ok()
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty());
    if let Some(preferred) = preferred.as_deref()
        && let Some(monitor) = monitors.iter().find(|monitor| {
            monitor
                .connector()
                .is_some_and(|connector| connector == preferred)
        })
    {
        return Some(monitor.clone());
    }

    monitors.into_iter().max_by_key(monitor_priority)
}

fn monitor_priority(monitor: &gdk::Monitor) -> (i64, i64) {
    let physical_area = i64::from(monitor.width_mm()) * i64::from(monitor.height_mm());
    let geometry = monitor.geometry();
    let logical_area = i64::from(geometry.width()) * i64::from(geometry.height());
    (physical_area, logical_area)
}

fn build_editor() -> (gtk::TextView, gtk::ScrolledWindow) {
    let view = gtk::TextView::new();
    view.set_monospace(true);
    view.set_cursor_visible(true);
    view.set_wrap_mode(gtk::WrapMode::WordChar);
    view.set_accepts_tab(false);
    view.add_css_class("scratch-editor");

    let scroller = gtk::ScrolledWindow::builder()
        .child(&view)
        .hexpand(true)
        .build();
    scroller.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Automatic);
    scroller.set_propagate_natural_width(true);
    scroller.set_propagate_natural_height(true);
    scroller.add_css_class("scratch-scroller");

    (view, scroller)
}

fn build_footer() -> (gtk::Label, gtk::Label, gtk::Box) {
    let counts = gtk::Label::new(Some(""));
    counts.set_xalign(0.0);
    counts.set_hexpand(true);
    counts.add_css_class("scratch-footer");

    let cursor = gtk::Label::new(Some(""));
    cursor.set_xalign(1.0);
    cursor.add_css_class("scratch-footer");

    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    footer.append(&counts);
    footer.append(&cursor);
    footer.add_css_class("scratch-footer-bar");

    (counts, cursor, footer)
}

fn install_shortcuts(ui: &Rc<ScratchUi>) {
    let controller = gtk::EventControllerKey::new();
    let owner = ui.clone();
    controller.connect_key_pressed(move |_, keyval, _keycode, state| {
        let primary = state.contains(gtk::gdk::ModifierType::CONTROL_MASK);
        match keyval {
            gdk::Key::Escape => {
                owner.hide();
                Propagation::Stop
            }
            gdk::Key::s if primary => {
                owner.flush();
                Propagation::Stop
            }
            // Insert a tab only when nothing is selected. With a selection,
            // default focus movement is far less destructive than replacing
            // a multi-line selection with a single tab character.
            gdk::Key::Tab if !primary && !owner.buffer.has_selection() => {
                let buffer = &owner.buffer;
                let mark = buffer.get_insert();
                let mut cursor = buffer.iter_at_mark(&mark);
                buffer.insert(&mut cursor, "\t");
                owner.editor.grab_focus();
                Propagation::Stop
            }
            _ => Propagation::Proceed,
        }
    });
    ui.window.add_controller(controller);
}

/// Handles a close request from the window manager as a dismissal, not a quit.
///
/// `Propagation::Proceed` here would run GTK's default handler and *destroy*
/// the `ApplicationWindow`. That is unrecoverable: the process outlives the
/// widget, `ScratchUi` keeps a handle to a destroyed window, and the next
/// `show()` calls `present()` on it -- the notepad is bricked until the process
/// restarts, with no error anywhere. It is reachable from outside, because the
/// window class is documented (`dev.maxii.HyprScratch`): `hyprctl dispatch
/// closewindow` or `killactive` aimed at it is enough.
///
/// `set_deletable(false)` does not help here. It only suppresses the client-side
/// destroy affordance; it does not stop a close request arriving from the
/// compositor, which is the route that actually matters.
///
/// So: flush, hide, and stop the request. Every dismissal path ends up in the
/// same place, and the window stays alive to be shown again.
fn install_close_flush(ui: &Rc<ScratchUi>) {
    let owner = ui.clone();
    ui.window.connect_close_request(move |_| {
        owner.flush();
        owner.hide();
        Propagation::Stop
    });
}

impl ScratchUi {
    fn toggle(&self) {
        if self.window.is_visible() {
            self.hide();
        } else {
            self.show();
        }
    }

    fn show(&self) {
        // Disarmed first. Presenting the window focuses it, and that activation
        // transition must not be mistaken for the user having moved on before
        // the notepad ever appeared.
        self.armed_for_focus_loss.set(false);
        self.window.present();
        self.editor.grab_focus();
        // Armed only if the window is *already* active, which is the case the
        // notify handler cannot cover. It arms as a side effect of `is-active`
        // changing, so if the window is already active when `show()` runs, no
        // transition occurs and no notify ever fires -- leaving the flag false
        // and the next genuine focus loss swallowed. Reachable because Wayland
        // deactivation is asynchronous relative to `gtk_window_hide()`, so a
        // hide/show pair inside one compositor round trip never reports the
        // intermediate state. The failure is the worst kind: focus-away
        // dismissal silently stops working for that cycle, with nothing to see.
        if self.window.is_active() {
            self.armed_for_focus_loss.set(true);
        }
    }

    fn hide(&self) {
        // Flush before unmapping: the common way to dismiss the notepad is the
        // same hotkey that opened it, which can happen well inside the
        // debounce window.
        self.flush();
        // Disarmed before hiding, because unmapping takes the focus away and
        // that must not be read as the user moving on.
        self.armed_for_focus_loss.set(false);
        self.window.hide();
    }

    /// Restarts the debounce timer. Uses an explicit `&Rc<Self>` receiver
    /// because the timer callback needs to own a strong reference.
    fn schedule_save(self: &Rc<Self>) {
        if let Some(id) = self.save_timer.borrow_mut().take() {
            id.remove();
        }
        let owner = self.clone();
        let id = glib::timeout_add_local(AUTOSAVE_DEBOUNCE, move || {
            owner.save_timer.borrow_mut().take();
            owner.flush();
            ControlFlow::Break
        });
        *self.save_timer.borrow_mut() = Some(id);
    }

    fn flush(&self) {
        if let Some(id) = self.save_timer.borrow_mut().take() {
            id.remove();
        }
        if !self.dirty.get() {
            return;
        }
        let start = self.buffer.start_iter();
        let end = self.buffer.end_iter();
        let text = self.buffer.text(&start, &end, false);
        match self.store.save(&text) {
            Ok(()) => self.dirty.set(false),
            Err(error) => eprintln!(
                "hypr-scratch: could not save {}: {error}",
                self.store.path().display()
            ),
        }
    }

    fn update_counts(&self) {
        let start = self.buffer.start_iter();
        let end = self.buffer.end_iter();
        let text = self.buffer.text(&start, &end, false);
        let words = text.split_whitespace().count();
        let chars = text.chars().count();
        let lines = self.buffer.line_count().max(0) as usize;
        self.counts.set_text(&format!(
            "{words} {} · {chars} {} · {lines} {}",
            plural(words, "word", "words"),
            plural(chars, "char", "chars"),
            plural(lines, "line", "lines"),
        ));
    }

    fn update_cursor(&self) {
        let mark = self.buffer.get_insert();
        let iter = self.buffer.iter_at_mark(&mark);
        self.cursor.set_text(&format!(
            "Ln {}, Col {}",
            iter.line() + 1,
            iter.line_offset() + 1
        ));
    }
}

fn plural<'a>(count: usize, singular: &'a str, plural: &'a str) -> &'a str {
    if count == 1 { singular } else { plural }
}

/// Overrides the compiled-in stylesheet.
const STYLE_ENV: &str = "HYPR_SCRATCH_STYLE";

/// The built-in stylesheet, compiled in so the notepad looks right with no config
/// file at all. Also shipped as `data/style.css`, so the file a user copies and
/// the one built into the binary cannot drift apart.
const DEFAULT_CSS: &str = include_str!("../data/style.css");

/// Where a user stylesheet is looked for.
///
/// `$XDG_CONFIG_HOME/hypr-scratch/style.css`, per the XDG base directory spec,
/// with the documented `$HOME/.config` fallback for the `XDG_CONFIG_HOME` that is
/// unset in some sessions. `HYPR_SCRATCH_STYLE` overrides both, which is what the
/// test suite uses to point at a stylesheet it controls.
pub fn style_path() -> PathBuf {
    if let Some(raw) = env::var_os(STYLE_ENV).filter(|value| !value.is_empty()) {
        return expand_home(raw.to_string_lossy().into_owned());
    }
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    let config_home = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".config"));
    config_home.join("hypr-scratch").join("style.css")
}

fn install_css() {
    // The default goes on first and the user's file second, at the *same*
    // priority, so the cascade resolves in the user's favour for anything they
    // mention while everything they did not mention keeps working. Loading only
    // the user's file would mean a one-line config that changes the panel colour
    // and silently drops the transparency rules, the fonts and the corner radius
    // along with it -- an unstyled square box, with no error anywhere.
    let mut providers = vec![provider_for(DEFAULT_CSS, "the built-in stylesheet")];

    match user_css() {
        Ok(Some((css, source))) => providers.push(provider_for(&css, &source)),
        Ok(None) => {}
        Err((path, error)) => {
            eprintln!("hypr-scratch: ignoring {}: {error}", path.display());
        }
    }

    let Some(display) = gtk::gdk::Display::default() else {
        return;
    };
    for provider in providers {
        gtk::style_context_add_provider_for_display(&display, &provider, CSS_PRIORITY);
    }
}

/// The user's stylesheet and where it came from, or `Ok(None)` if there isn't one.
///
/// `Err` carries the path as well as the reason, because "could not read your
/// config" without saying which config is a useless error message.
fn user_css() -> Result<Option<(String, String)>, (PathBuf, std::io::Error)> {
    // An explicit path is a request, so a problem with it is worth reporting even
    // though a problem with the default location is merely "not configured".
    if let Some(raw) = env::var_os(STYLE_ENV).filter(|value| !value.is_empty()) {
        let path = expand_home(raw.to_string_lossy().into_owned());
        let css = std::fs::read_to_string(&path).map_err(|error| (path.clone(), error))?;
        if css.trim().is_empty() {
            return Err((path, std::io::Error::other("the file is empty")));
        }
        return Ok(Some((css, path.display().to_string())));
    }

    let path = style_path();
    // A missing file is the normal case, not a problem to report.
    match std::fs::read_to_string(&path) {
        Ok(css) if css.trim().is_empty() => Err((path, std::io::Error::other("the file is empty"))),
        Ok(css) => Ok(Some((css, path.display().to_string()))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err((path, error)),
    }
}

/// Builds a provider that complains loudly on stderr if the CSS does not parse.
///
/// GTK treats a malformed stylesheet as a warning and carries on, which shows up
/// as a blank or unstyled notepad -- a bad way to learn about a typo. Since a
/// broken config is otherwise entirely silent, the error is worth a line.
fn provider_for(css: &str, source: &str) -> gtk::CssProvider {
    let provider = gtk::CssProvider::new();
    let (text, source) = (css.to_owned(), source.to_owned());
    provider.connect_parsing_error(move |_, section, error| {
        // `CssLocation` only offers a character offset, so the line number has to
        // be counted out of the source. A char count, not a byte count, because
        // that is what `chars()` reports -- getting this wrong would report a
        // plausible wrong line for any stylesheet with a non-ASCII comment in it.
        let offset = section.start_location().chars();
        let line = text.chars().take(offset).filter(|c| *c == '\n').count() + 1;
        eprintln!("hypr-scratch: {source} line {line}: {error}");
    });
    provider.load_from_data(css);
    provider
}

#[cfg(test)]
mod tests {
    use super::{on_focus_change, on_outside_click};

    /// A reported outside click dismisses an open notepad and nothing else.
    ///
    /// The case that must not dismiss is the same one `on_focus_change` has to
    /// handle: a window that is not up. There is no way to provoke it through a
    /// real compositor, because the script declines to send anything while the
    /// window is missing -- so without a test here, changing the guard to
    /// something that ignores visibility would look fine and would hide a
    /// `--background` instance on the first click of the session.
    #[test]
    fn an_outside_click_dismisses_only_a_window_that_is_up() {
        assert!(
            on_outside_click(true),
            "a visible notepad is dismissed by a click outside it"
        );
        assert!(
            !on_outside_click(false),
            "a hidden notepad has nothing to dismiss"
        );
    }

    /// Every combination, because the cases that must *not* dismiss are the
    /// whole point of the arming and cannot be provoked through a compositor.
    #[test]
    fn the_dismissal_decision_over_every_combination() {
        // (armed, is_active, is_visible) -> (armed_after, dismiss)
        let cases = [
            // Not yet activated, and not visible either: this is the state the
            // window passes through on its way up. It must not dismiss, or the
            // notepad closes itself the instant it opens.
            ((false, false, false), (false, false)),
            // Armed, inactive, but already hidden -- a hide() that raced the
            // notification. Must not dismiss again.
            ((true, false, false), (false, false)),
            // The one case that dismisses: the user moved on.
            ((true, false, true), (false, true)),
            // Gained activation. Arms, never dismisses.
            ((false, true, true), (true, false)),
            ((true, true, true), (true, false)),
            ((false, true, false), (true, false)),
            ((true, true, false), (true, false)),
            // Never armed, and never active: nothing to dismiss.
            ((false, false, true), (false, false)),
        ];
        for (input, want) in cases {
            assert_eq!(
                on_focus_change(input.0, input.1, input.2),
                want,
                "{input:?}"
            );
        }
    }

    #[test]
    fn arming_is_cleared_by_losing_it_and_set_by_gaining_it() {
        // The cycle a hide/show pair depends on: arm on activation, disarm on
        // the loss that dismisses, so a second loss while hidden is a no-op and
        // the next show has to arm again.
        let (armed, dismiss) = on_focus_change(false, true, true);
        assert!(armed && !dismiss, "gaining activation arms");

        let (armed, dismiss) = on_focus_change(armed, false, true);
        assert!(
            !armed && dismiss,
            "losing it while up dismisses and disarms"
        );

        let (armed, dismiss) = on_focus_change(armed, false, true);
        assert!(!armed && !dismiss, "a second loss does not dismiss again");
    }
}
