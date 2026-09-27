# Hypr Scratch

A floating iced-glass scratchpad notepad for Hyprland. One persistent note,
always one keystroke away, saved as plain text.

## Build

```sh
cargo build --release
```

The binary is written to `target/release/hypr-scratch`.

## Install

```sh
install -Dm755 target/release/hypr-scratch ~/.local/bin/hypr-scratch
```

## Controls

- `SUPER + N`: toggle the notepad
- `Esc`: hide
- `Ctrl + S`: save now
- `Tab`: insert a tab (only with no selection; with a selection it moves focus)

It also closes itself when you click another window or move focus with a
keybind. Both of those are really the same thing — it closes when it loses
focus. See [Dismissing the notepad](#dismissing-the-notepad).

## Notes

The note is a plain `.md` file at `~/Documents/scratchpad.md`. Set
`HYPR_SCRATCH_FILE` to use a different path. Because it is a normal file, it is
greppable, scriptable, and git-friendly — there is no database and no lock-in.

Saves are debounced 500ms after the last keystroke, and forced when the notepad
is hidden or closed. Each save writes a sibling `.tmp` file and then renames it
over the note, so an interrupted write cannot truncate the existing note.

## Dismissing the notepad

All four routes work: the hotkey, `Esc`, clicking another window, and moving
focus with a keybind.

Worth being precise about how the last two work, because it is narrower than
"click away and it goes away". There is no pointer or grab check anywhere in the
code. Dismissal is one thing — `is-active` went false — so *clicking another
window* dismisses the notepad only because that click gives the other window
focus. A click that does not move focus leaves the notepad up. Clicking the
desktop background does exactly that under Hyprland's default configuration, and
so does clicking any window with `nofocus`. If you want the notepad to vanish on
those, it needs a real pointer check, which is not implemented.

The property watched is `GtkWindow`'s **`is-active`**, never `has-focus`.

A fifth route exists that is not a feature: the window manager can ask the
notepad to close, via `closewindow` or `killactive` on the published class
`dev.maxii.HyprScratch`. That is handled as a *dismissal* — flush, hide, stop the
request — because letting it through runs GTK's default handler, which destroys
the `ApplicationWindow`. The process then outlives the widget, `ScratchUi` keeps
a handle to a destroyed window, and the next hotkey calls `present()` on it: the
notepad is bricked until it is restarted, with nothing printed anywhere. Gate 9
of `scripts/gates.sh` covers it, and notably the real assertion is not "it
closed" but "it still opens afterwards".

That distinction is the whole ballgame. On Wayland, `has-focus` is never set on
a GTK toplevel — it stays `false` for the window's whole life even while the
window is visibly up and receiving every keystroke — so a dismissal built on it
is dead code that looks like it works. `is-active` does track the compositor's
view, and it is armed only after the window has actually become active, so the
activation that comes with opening is not mistaken for the user moving on.

The notepad is a plain toplevel rather than a layer surface, and that is what
makes the last two work at all. A layer surface has to take a keyboard grab to
receive the keyboard — `KeyboardMode::OnDemand` never obtained the keyboard at
all on this Hyprland, even when clicked, so the notepad opened inert — and
while an exclusive grab is held Hyprland refuses to move focus off the surface.
A click on a window underneath did nothing, a focus keybind did nothing, and no
compositor event was emitted to notice it by. As an ordinary window it gets
honest focus semantics and clicks reach whatever is underneath.

The cost is that the overlay look is now the compositor's job. GTK 4 removed
the client-side window hints (`set_keep_above`, `set_skip_taskbar_hint`,
`set_skip_pager_hint`, `set_type_hint` no longer exist on `GtkWindow`), so
without the window rule below the notepad opens tiled, snapped into the layout,
and listed in the switchers. Only `set_decorated(false)` is still the app's job.

## Window rules

Everything visual lives in `~/.config/hypr/hyprland.lua`:

```lua
hl.window_rule({
	name = "hypr-scratch-overlay",
	match = { class = ".*HyprScratch.*" },
	float = true,
	center = true,
	pin = true,
	border_size = 0,
	no_shadow = true,
	no_anim = true,
	no_blur = false,
	rounding = 10,
	suppress_event = "maximize fullscreen",
})
```

Every key above is checked against Hyprland's own list of window-rule effects
(`src/desktop/rule/windowRule/WindowRuleEffectContainer.cpp`). Two keys that
earlier revisions of this file used are not on that list, and both were silently
doing nothing:

- **`no_border` does not exist.** The list has `border_size`, which is the real
  spelling. Nothing warns about an unknown key — the rule is accepted and the
  rest of it still applies — so a typo here is invisible.
- **`suppress_event` takes a space-separated string, not a list.** A table is
  valid Lua, so `luac -p` accepts it, and Hyprland then ignores the value.
  `luac -p` cannot catch this class of mistake: it only checks that the file
  parses, not that the keys mean anything.

Two more details are easy to get wrong, and both fail silently.

The class is the GTK application ID verbatim — GTK puts it on the toplevel as
the Wayland app id and Hyprland reports that as the class. It is *not*
`hypr-scratch`, which is what the layer-surface namespace used to be.

And Hyprland matches a rule against the **whole** class, not a substring of it,
so the `.*` on both ends is load-bearing. A bare `"HyprScratch"` matches nothing,
and the symptom is not an error but a notepad that opens tiled, unfocused, and
apparently broken.

The app's own dispatches use the class too — `class:dev.maxii.HyprScratch`, exact,
no wildcards — rather than the window title. The title also works today, but it
is only as reliable as the string handed to `set_title`, whereas the class comes
from the application ID and is fixed at launch. Using the same string in both
places also means the rule and the dispatch cannot drift apart.

### The corner radius is the app's, not the compositor's

`border-radius` in the app's CSS and `decoration.rounding` in the Hyprland
config have to be the same number, and the app's is the one you actually see.
The compositor's `rounding` does not clip this window: with `rounding = 0` on
the rule the surface goes square but the arc is still there, while a control
window obeys the same key exactly (0 → square, 15 → 15.0 logical, circle fit
rms 0.9px). The notepad's arc is painted by GTK.

That is worth stating plainly because nothing enforces it. The two numbers lived
apart for a while — CSS said `20px`, `decoration.rounding` said `10` — and the
notepad ended up with corners twice as round as every other window on the
desktop. Gate 8 of the acceptance suite now compares the two numbers directly,
because the only thing standing between them is that check.

Measured after the fix, on DP-1 (scale 2), with the panel temporarily made
opaque so the border stroke is unambiguous against the blurred backdrop: all
four corners 10 logical px, by two independent methods — the arc's crossing of
the corner diagonal gives 10.2, and the stroke begins 18 physical px along each
edge, which is 20 physical px of geometry less the 2px stroke width.

`center` centres the notepad on the monitor it happens to open on. The app then
corrects that to the main display at runtime, which rules cannot express — see
below.

### Placing it on the main monitor

Window rules cannot name a monitor, so `src/hypr.rs` sends two dispatches to
Hyprland's command socket shortly after the notepad maps: move it to the target
monitor, then centre it again. Both name the window explicitly, by title. An
untargeted dispatch acts on whichever window is focused, and the placement runs
before the notepad is reliably the active window — leaving it untargeted was
enough to shuffle whatever the user was actually working in.

Values interpolated into those dispatches are checked rather than escaped: the
socket carries Lua that Hyprland evaluates, so a stray quote would be code
execution in the compositor. The title and the connector both pass a
`[A-Za-z0-9_-]` check, with tests covering the cases that would break out of
the string.

Set `HYPR_SCRATCH_MONITOR` to override which monitor counts as the main one.
Otherwise the largest physical display wins.

## Iced background

The panel is `rgba(22, 22, 30, 0.72)` in GTK, so the frost comes from the
compositor rather than from the app: `no_blur = false` in the rule above turns
blur on for this window. Blur size, passes, and vibrancy come from the global
`decoration.blur` block and are shared with every other window, so the rule can
only ask for blur on or off, not tune it. GTK 4.22 has no `GtkBackdrop`, so the
app cannot blur its own backdrop in-process — the compositor is the only option.

### The app must let the compositor through

The frost only appears if the panel itself is translucent. Two things had to be
right, and both were about *which* GTK node was being painted.

The first is a priority trap. `~/.config/gtk-4.0/gtk.css` is a 238 KB user
stylesheet — a copy of Tokyonight with the theme's own `gtk-dark.css`
symlinked in — and GTK loads it at `GTK_STYLE_PROVIDER_USER` priority (800).
The app's overrides were registered with `STYLE_PROVIDER_PRIORITY_APPLICATION`, whose value is **600**, i.e. *below* the
user sheet, so they silently lost.
Registering at priority `1000` fixes it. `STYLE_PROVIDER_PRIORITY_APPLICATION`
is a poor name: the constant is the priority the *app* gets by default, not a
high one.

The second is that the visible surface is not the widget you style. In a GTK 4
`TextView` the pixels come from internal `text` and `border` child nodes, and
the user sheet paints both:

```css
textview text   { background-color: #323449; }
textview border { background-color: #323449; }
```

So the overrides have to target those nodes, not `textview`:

```css
textview.scratch-editor text,
textview.scratch-editor border {
  background-color: transparent;
}
```

Painting the view opaque did two things at once: it hid the blur (nothing behind
the panel for the compositor to sample), and it leaked the square `text` node
past the panel's rounded corners, which is what the "another layer behind it
which is still not round" turned out to be.

`GTK_THEME` is ignored on Wayland because the xdg portal supplies `gtk-theme`,
so the theme is pinned in code with `gtk::Settings::set_gtk_theme_name` instead;
the `env` fallback in `main.rs` only covers running without a portal.

### Verifying a change

The acceptance suite lives in `scripts/`, and needs a running Hyprland session —
every gate is checked against the compositor, not against the app:

```sh
./scripts/gates.sh    # nine behavioural gates
./scripts/visual.sh   # blur and corners, each against a null control
./scripts/stress.sh   # repeated open/close cycles
```

`stress.sh` also asserts the process is the *same one* at the end as at the
start. State checks alone cannot see a crash: if the app dies, the next toggle
quietly starts a fresh primary, the window comes up, the state looks right, and
the suite reports a clean run over a binary that fell over.

Artifacts go to a `mktemp -d` scratch dir, so running the suites does not write
into the source tree.

The suite needs a live Hyprland session and these on `PATH`: `hyprctl`, `grim`,
`wtype`, `ydotool`, and `kitty` (used only to spawn the sink window — any
terminal would do, it just has to echo what it is sent). It moves the pointer and
clicks, so it will fight you for the mouse; run it when you are not.

Five rules are baked into the suite, all of them learned the hard way, and the
first four produced *false results* while the app was behaving correctly:

- **Never assume the desktop's layout.** Earlier revisions hardcoded both the
  coordinate they clicked and the window they expected to be behind the
  notepad. The status bar resized mid-session, the reserved top moved, kitty
  grew from y=159 to y=36 and swallowed the click point — and one gate captured
  `HDMI-A-1` while clicking a point derived from `DP-1`, which passed only while
  kitty happened to be on the other workspace. Gates 3 and 5 now use a sink
  window the suite owns: a `cat` in its own kitty, floated, pinned and placed, so
  the click is guaranteed to land on it and it echoes what it is sent. That also
  stopped the suite typing test keystrokes into whatever the user happened to
  have open — in this case an AI TUI, which is both a bad place to send test
  input and a poor diff target.
- **Poll for state, never sleep and assume.** Wayland deactivation is
  asynchronous relative to `gtk_window_hide()`, so a hide/show pair can straddle
  a compositor round trip. A fixed 2.5s sleep occasionally samples the window
  mid-transition and reports a failure that does not exist. `stress.sh` always
  sampled rather than assumed; `gates.sh` did not, and that was the flake.
- **Never let the suite block.** `hypr-scratch` called bare is a request to
  toggle *if an instance is already running*. If none is, the caller becomes the
  primary and blocks in the GTK main loop forever. When gate 9 killed the process
  and the suite could not tell "dead" from "closed", the next toggle hung the run
  instead of failing it. Every toggle is detached and then polled for.
- **Tear down by PID, never by a Hyprland selector.** See below.
- **A third party taking focus is not a regression.** Steam launched mid-run
  during this work, took focus, and the notepad closed itself — correctly, since
  focus-away dismissal is the feature. `reset_notepad` re-opens up to three times
  and reports the retries rather than passing or failing on someone else's
  window.
- **Observe before deciding to act.** A toggle sent while a launch is still in
  flight lands *after* that launch has opened the window, and closes it again.
  The window appears in about 0.3s, so sampling the state 0.05s after starting
  the process reads "closed", concludes a toggle is needed, and produces a run
  that opens and immediately closes every time. So the launch is waited on
  first, and a toggle is only sent if the window genuinely never appeared.

### A selector that matches nothing does not fail

This is the sharpest edge in the whole thing, and it bites in both directions.

A dispatcher selector that matches no window is not an error. The dispatch falls
back to the **focused** window, and reports `ok`. The same is true of a selector
that is silently wrong in some other way, which makes the failure very hard to
see coming:

- `hl.dsp.window.float({ class:foo })` — `class:foo` is not Lua. The dispatch is
  a syntax error, does nothing, and still prints `ok`. Inside these tables the
  key must be assigned: `class = "foo"`.
- `hl.dsp.window.close({ class = "hypr-scratch" })` — class matching is a
  whole-class regex against the full GTK application id, so this matches nothing,
  falls back to the focused window, and closes that instead.
- `hl.dsp.window.kill({ address = "0x…" })` on an address that is already gone —
  falls back to the focused window and `SIGKILL`s it. This is how a helper written
  to clean up its own `scratchsink` windows killed the notepad process instead,
  and the suite then reported `process survived (got '0', want '1')`.

That last one is why `sink_down` kills the PID it recorded at spawn time. A PID
cannot be misrouted to some other window.

Two more things about these dispatchers, both of which read as bugs:

- `hl.dsp.window.close` is a genuine close request — it closes the notepad while
  it is *unfocused*, by address, and the process survives. It is not the
  fallback in disguise.
- `hl.dsp.window.kill` is a hard `SIGKILL` of the client process. It bypasses GTK
  entirely, so the notepad's `close_request` handler never runs. Use `close` to
  test dismissal; `kill` only to dispose of a throwaway window.
- kitty declines close requests, so a close-based teardown of the sink leaves the
  window up and they accumulate, one per run. That is a kitty behaviour, not a
  Hyprland one.

### Measuring things

`hyprctl clients` reports positions in *global logical* space; `grim` captures
*physical* pixels. A panel at logical `2560,317` on a scale-2 output starting at
logical x=1920 is at physical `(1280, 634)`, not `(2560, 317)`. Comparing the
wrong box is an easy way to get a false "blur does nothing" reading.

A blur change needs a fresh window, so restart the notepad rather than toggling
it. A/B screenshots settle it, but only against a null control: two shots in the
same state give the noise floor, and a difference only a little above that is
not evidence. The measured numbers for the current build are 80 changed pixels
at a mean absolute difference of 0.02 for the null, against roughly 60,000 px at
7 for blur on versus off.

For the corners, `scripts/measure.py` fits a circle to one and reports the radius
in logical px. Take the radius from a control window too, because the question
is always whether the two agree. Two traps, both of which produce a confident
wrong number:

- **Luminance cannot separate the panel from the backdrop.** The panel is 0.72
  alpha over a blurred desktop, so a "is this pixel inside the window" test
  built on brightness reports wallpaper as panel. A circle fit against that
  reported 22.8 logical when the truth was 10. Match the actual colour instead,
  and make the panel opaque temporarily so the border stroke (`rgb(41,46,66)`)
  is unambiguous against the fill (`rgb(22,22,30)`).
- **Cache no geometry across a capture.** The reserved top moves when the status
  bar resizes — it went 42 → 156 → 34 during this work — so a screenshot
  measured against a position read a moment later is offset by tens of pixels
  and profiles as flat. Read `hyprctl` geometry fresh for every shot.

## Single instance

A persistent hidden instance owns a per-user Unix socket, so `SUPER + N` toggles
the running notepad instead of starting a second copy. Start it at login with
`--background` so the toggle only has to reveal it. A second invocation sends
`toggle` and exits, so a stale binary on `PATH` can look like a no-op — rebuild
*and* reinstall before testing.

The GTK application ID is `dev.maxii.HyprScratch` and the window title is
`hypr-scratch`, which is what the dispatches in `src/hypr.rs` address it by.
