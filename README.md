# Hypr Scratch

A floating iced-glass scratchpad notepad for Hyprland. One persistent note,
always one keystroke away, saved as plain text. GTK 4, Rust, one binary.

## TL;DR

```sh
./install.sh        # build and install to ~/.local/bin
```

Add these binds to your Hyprland config, then reload:

```ini
bind = SUPER,N,exec,$HOME/.local/bin/hypr-scratch
bind = ,mouse:272,exec,$HOME/.local/bin/hypr-scratch --outside-click,non_consuming
bind = ,mouse:273,exec,$HOME/.local/bin/hypr-scratch --outside-click,non_consuming
```

```sh
hyprctl reload
```

Then press `SUPER + N`.

## Install

`./install.sh` builds the release binary, installs it to
`~/.local/bin/hypr-scratch`, and writes a starting stylesheet to
`~/.config/hypr-scratch/style.css` if you do not already have one. Set `PREFIX`
to change the install location and `DESTDIR` to stage a package under a
packaging root.

```sh
./install.sh
PREFIX=/usr ./install.sh
DESTDIR=/tmp/pkg PREFIX=/usr ./install.sh
```

`cargo install --path .` builds and installs via cargo instead, if you would
rather cargo own the binary.

## Hyprland setup

The three binds above are the whole setup. Use absolute paths: binds run with a
minimal environment and `~/.local/bin` is not always on `PATH`. The two mouse
binds are bare LMB and RMB; `non_consuming` lets the click both dismiss the
notepad and reach whatever is underneath it.

The overlay look (floating, centred, pinned, borderless, rounded, blurred,
always on top) comes from a window rule in
[examples/hyprland.lua](examples/hyprland.lua). It is optional: without it the
notepad still opens and works, but as an ordinary tiled window rather than an
overlay. The file also has the equivalent plain `.conf` snippet in a comment.

The rule matches `dev.Zsweezzy.HyprScratch`, the GTK application ID. Anchor it at
both ends (`^dev\.Zsweezzy\.HyprScratch$`), because Hyprland matches against the
whole class and a loose pattern will also match other windows. Keep the rule's
`rounding` equal to the `border-radius` in the stylesheet; the app paints its
own corners.

## Configuration

Colours and opacity come from a stylesheet, layered on top of the built-in
default, so a file that sets only the panel colour keeps everything else
working.

```
$XDG_CONFIG_HOME/hypr-scratch/style.css    (default ~/.config/hypr-scratch/style.css)
```

`HYPR_SCRATCH_STYLE=/path/to/style.css` overrides that path.
`hypr-scratch --print-config` prints the note, stylesheet, and socket paths this
build would use. No configuration is required to run; with no stylesheet the
built-in default is used. A stylesheet that will not parse is reported on stderr
with a line number.

## Controls

- `SUPER + N` — toggle the notepad (from the bind above).
- `Esc` — hide.
- `Ctrl + S` — save now.
- `Tab` — insert a tab when there is no selection.

Clicking outside the notepad, clicking another window, or moving focus away
dismisses it.

## Notes

The note is a plain text file at `~/Documents/scratchpad.md`. Set
`HYPR_SCRATCH_FILE` to use a different path (`~` is expanded).

Saves are debounced 500 ms after the last keystroke, and forced when the notepad
hides or closes. Each save writes a sibling `.tmp` file and renames it over the
note, so an interrupted write cannot truncate the existing note.

A persistent instance owns a per-user Unix socket, so `SUPER + N` toggles the
running notepad instead of starting a second copy. Start it at login with
`hypr-scratch --background` so the toggle only has to reveal it.
`HYPR_SCRATCH_MONITOR` names the monitor connector to open on; without it the
largest physical display is used.

## Testing

The suites in `scripts/` need a live Hyprland session:

```sh
./scripts/gates.sh    # behavioural gates
./scripts/visual.sh   # blur and corners
./scripts/stress.sh   # repeated open/close cycles
```

They need `hyprctl`, `grim`, `wtype`, and `ydotool` on `PATH`, and they move the
pointer and inject input, so run them when you are not using the mouse.

## License

MIT — see [LICENSE](LICENSE). Third-party notices are in [NOTICE](NOTICE):
GTK 4 is dynamically linked under LGPL-2.1, and the default palette is
Tokyonight Night (MIT).
