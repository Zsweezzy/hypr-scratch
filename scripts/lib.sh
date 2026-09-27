# Shared setup for the test scripts. Sourced, never executed.
#
# Kept in one file because the three scripts disagreeing about which binary they
# are testing is exactly the failure mode this repository exists to rule out: a
# suite that silently exercises last week's build and reports a clean run.

# Resolves a command to a full path, or exits with a useful message.
#
# The lookup order is deliberate. An explicit override wins, then a copy already
# on `PATH` -- so an install done with `sudo install` or `cargo install` is
# tested the way a user would actually run it -- and only then the conventional
# per-user prefix, which is where this repository's `install.sh` puts things and
# where `cargo install --path .` lands by default. That last fallback is the one
# that used to be hardcoded, and it is why the suite could report a clean pass
# against a binary the user had replaced.
require_command() {
    local variable=$1 name=$2
    local resolved=${!variable:-}
    if [ -z "$resolved" ]; then
        resolved=$(command -v "$name" 2>/dev/null)
    fi
    if [ -z "$resolved" ] && [ -x "$HOME/.local/bin/$name" ]; then
        resolved=$HOME/.local/bin/$name
    fi
    if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
        echo "Cannot find an executable '$name'." >&2
        echo "  Build it:   cargo build --release" >&2
        echo "  Or install: ./install.sh" >&2
        echo "  Or point at one: $variable=/path/to/$name $0" >&2
        exit 2
    fi
    printf -v "$variable" '%s' "$resolved"
    export "$variable"
}

# The notepad's window class, exported for the Python helpers embedded in the
# scripts. Matched by *equality*, never by substring: `'HyprScratch' in class`
# also matches a class that merely starts with it, which is exactly what the test
# sink's does, and a substring match that lands on the wrong window does not
# error -- it reports the other window's size, position and pinned state as if
# they were the notepad's, and the run fails in a way that looks like a
# regression in the app.
export NOTEPAD_CLASS=dev.maxii.HyprScratch

# Builds the test-only sink if it is not already there.
#
# The sink exists so the suite does not need a terminal emulator installed,
# configured, and willing to run a command line. Its window class is the
# application ID, because GTK 4 dropped `set_wmclass`; keep the two in step.
#
# The name is short on purpose. Linux truncates `comm` to 15 characters, so a
# longer one stops matching `pkill -x` and the suite leaks a sink per run without
# saying so. Two sinks make a class selector ambiguous, and an ambiguous selector
# does not error -- the `pin` and `move` dispatches act on nothing, still report
# ok, and every gate after that measures a desktop nobody set up.
SINK_CLASS=dev.maxii.HyprScratchSink
SINK_BIN=$HERE/../target/debug/hypr-sink
require_sink() {
    if [ ! -x "$SINK_BIN" ]; then
        echo "Building the test sink (first run only)..."
        (cd "$HERE/.." && cargo build --quiet --bin hypr-sink) || {
            echo "Could not build the test sink." >&2
            exit 2
        }
    fi
}

# The user's Hyprland config, for the two checks that have to read it: the
# window rule (blur on/off) and its `rounding`, which has to match the app's CSS
# `border-radius`. Neither is derivable from the running session.
#
# This was a hardcoded `~/.config/hypr/hyprland.lua` for most of this
# repository's life, which meant the harness only ran on the machine it was
# written on: a different layout, or a plain `.conf` instead of Lua, and the
# script either edited the wrong thing or found nothing and carried on.
HYPRLAND_CONFIG=${HYPR_SCRATCH_HYPRLAND_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua}
export HYPRLAND_CONFIG

require_hyprland_config() {
    if [ ! -f "$HYPRLAND_CONFIG" ]; then
        echo "Cannot find a Hyprland config at $HYPRLAND_CONFIG." >&2
        echo "  The blur and corner gates read your window rule out of it." >&2
        echo "  Point at it: HYPR_SCRATCH_HYPRLAND_CONFIG=/path/to/hyprland.conf $0" >&2
        exit 2
    fi
}

# Marks the notepad's window rule inside that config. Both spellings are
# recognised because both are real: `hl.window_rule({...})` is a Lua config, and
# `windowrulev2 = ...` is a plain one. The sink's class starts with the notepad's
# as a substring, which is why a rule for the sink must not be picked up here --
# the marker is the exact rule *name* or the notepad class on its own.
RULE_MARKERS=("hypr-scratch-overlay" "$NOTEPAD_CLASS")
