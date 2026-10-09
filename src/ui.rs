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
    outside,
    store::{NoteStore, expand_home},
};

const PANEL_WIDTH: i32 = 640;
const PANEL_HEIGHT: i32 = 480;
const PANEL_MIN_WIDTH: i32 = 360;
const PANEL_MIN_HEIGHT: i32 = 240;
const WINDOW_TITLE: &str = "hypr-scratch";
/// GTK app ID; Hyprland reports it as the window class.
pub const WINDOW_CLASS: &str = "dev.Zsweezzy.HyprScratch";
const MAIN_MONITOR_ENV: &str = "HYPR_SCRATCH_MONITOR";

const CSS_PRIORITY: u32 = 1000;
const AUTOSAVE_DEBOUNCE: Duration = Duration::from_millis(500);
const PLACEMENT_DELAY: Duration = Duration::from_millis(80);

/// Deliberately longer than `PLACEMENT_DELAY`: the warp reads the placed rectangle back.
const CURSOR_WARP_DELAY: Duration = Duration::from_millis(160);

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
    target_monitor: Option<String>,
    armed_for_focus_loss: Cell<bool>,
}

pub fn create_window(
    app: &gtk::Application,
    pending: Arc<PendingCommands>,
    start_visible: bool,
) -> UiHandle {
    if let Some(settings) = gtk::Settings::default() {
        settings.set_gtk_theme_name(Some("Adwaita-dark"));
    }

    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title(WINDOW_TITLE)
        .default_width(PANEL_WIDTH)
        .default_height(PANEL_HEIGHT)
        .build();
    window.set_decorated(false);
    window.set_resizable(true);
    window.add_css_class("scratch-window");
    configure_overlay_window(&window);
    install_css();

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

    {
        let signal_ui = ui.clone();
        ui.buffer.connect_changed(move |_| {
            signal_ui.update_counts();
            signal_ui.dirty.set(true);
            signal_ui.schedule_save();
        });
    }

    {
        let signal_ui = ui.clone();
        ui.buffer
            .connect_mark_set(move |_, _, _| signal_ui.update_cursor());
    }

    install_shortcuts(&ui);
    install_close_flush(&ui);
    install_focus_dismissal(&ui);
    install_placement(&ui);
    install_cursor_warp(&ui);

    {
        let ui = ui.clone();
        glib::timeout_add_local(POLL_INTERVAL, move || {
            let toggle = ui.pending.take_toggle();
            let dismiss = ui.pending.take_dismiss();
            if toggle {
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

fn configure_overlay_window(window: &gtk::ApplicationWindow) {
    window.set_deletable(false);
}

fn on_focus_change(armed: bool, is_active: bool, is_visible: bool) -> (bool, bool) {
    if is_active {
        (true, false)
    } else {
        (false, armed && is_visible)
    }
}

/// Uses `is-active`, not `has-focus`: Wayland GTK never sets `has-focus` on a toplevel.
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

fn on_outside_click(is_visible: bool) -> bool {
    is_visible
}

/// Deliberately after map; a selector matching nothing moves the focused window instead.
fn install_placement(ui: &Rc<ScratchUi>) {
    let signal_ui = ui.clone();
    ui.window.connect_map(move |_| {
        let target = signal_ui.target_monitor.clone();
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

/// Runs after placement: `CURSOR_WARP_DELAY` must outlast `PLACEMENT_DELAY` so the warp reads the final rectangle.
fn install_cursor_warp(ui: &Rc<ScratchUi>) {
    let signal_ui = ui.clone();
    ui.window.connect_map(move |_| {
        let window = signal_ui.window.clone();
        glib::timeout_add_local(CURSOR_WARP_DELAY, move || {
            if window.is_visible() {
                outside::warp_into_notepad();
            }
            ControlFlow::Break
        });
    });
}

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

/// Flush and hide, then Stop: `Proceed` would destroy the window and brick the process.
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
        self.armed_for_focus_loss.set(false);
        self.window.present();
        self.editor.grab_focus();
        if self.window.is_active() {
            self.armed_for_focus_loss.set(true);
        }
    }

    fn hide(&self) {
        self.flush();
        self.armed_for_focus_loss.set(false);
        self.window.hide();
    }

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

const STYLE_ENV: &str = "HYPR_SCRATCH_STYLE";

const DEFAULT_CSS: &str = include_str!("../data/style.css");

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

fn user_css() -> Result<Option<(String, String)>, (PathBuf, std::io::Error)> {
    if let Some(raw) = env::var_os(STYLE_ENV).filter(|value| !value.is_empty()) {
        let path = expand_home(raw.to_string_lossy().into_owned());
        let css = std::fs::read_to_string(&path).map_err(|error| (path.clone(), error))?;
        if css.trim().is_empty() {
            return Err((path, std::io::Error::other("the file is empty")));
        }
        return Ok(Some((css, path.display().to_string())));
    }

    let path = style_path();
    match std::fs::read_to_string(&path) {
        Ok(css) if css.trim().is_empty() => Err((path, std::io::Error::other("the file is empty"))),
        Ok(css) => Ok(Some((css, path.display().to_string()))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err((path, error)),
    }
}

fn provider_for(css: &str, source: &str) -> gtk::CssProvider {
    let provider = gtk::CssProvider::new();
    let (text, source) = (css.to_owned(), source.to_owned());
    provider.connect_parsing_error(move |_, section, error| {
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

    #[test]
    fn the_dismissal_decision_over_every_combination() {
        let cases = [
            ((false, false, false), (false, false)),
            ((true, false, false), (false, false)),
            ((true, false, true), (false, true)),
            ((false, true, true), (true, false)),
            ((true, true, true), (true, false)),
            ((false, true, false), (true, false)),
            ((true, true, false), (true, false)),
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
