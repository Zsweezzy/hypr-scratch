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

# A window's rectangle in *physical* pixels on its own monitor: the monitor's
# name, then x, y, width, height, ready to hand to a screenshot crop.
#
# Logical and physical coordinates are not interchangeable here. `hyprctl`
# reports `at` and `size` in logical pixels, and `grim -o` captures in physical
# ones, so a crop built from the values the compositor just printed lands in the
# wrong place on any scaled monitor -- and, worse, lands in *some* valid place,
# so it silently measures a patch of wallpaper instead of the window.
#
# Shared by both scripts that crop a window. The monitor is looked up by the id
# the client reports, and a missing monitor is fatal rather than a fallback: a
# guess here is how a run ends up reporting a confident zero.
physical_geom_of() {  # $1 = window class -> "name px py pw ph", or exits
    python3 -c "
import json, os, subprocess, sys
want = sys.argv[1]
win = next((c for c in json.loads(subprocess.run(
        ['hyprctl', 'clients', '-j'], capture_output=True, text=True).stdout)
    if c['class'] == want), None)
if win is None:
    sys.exit(f'no window of class {want} is open')
mons = json.loads(subprocess.run(
    ['hyprctl', 'monitors', '-j'], capture_output=True, text=True).stdout)
mon = next((m for m in mons if m['id'] == win['monitor']), None)
if mon is None:
    sys.exit(f'no monitor with id {win[\"monitor\"]}')
sc = float(mon['scale'])
x, y = win['at']
w, h = win['size']
px, py = round((x - mon['x']) * sc), round((y - mon['y']) * sc)
print(mon['name'], px, py, round(w * sc), round(h * sc))" "$1"; }

# A monitor's reserved-height at the top, in physical pixels.
#
# The status bar lives in the reserved area and repaints itself constantly -- a
# clock ticks, a workspace indicator breathes. Any pixel diff taken across a
# window that overlaps it picks up that churn and attributes it to whatever was
# being tested. Read from the compositor rather than assumed, so it is right on a
# machine with no bar, a taller one, or a different scale.
reserved_top_px() {  # $1 = monitor name
    python3 -c "
import json, subprocess, sys
name = sys.argv[1]
mon = next((m for m in json.loads(subprocess.run(
        ['hyprctl', 'monitors', '-j'], capture_output=True, text=True).stdout)
    if m['name'] == name), None)
if mon is None:
    sys.exit(f'no monitor named {name}')
# reserved is [left, top, right, bottom] -- the top edge is index 1. Index 0 is
# the left one, which is 0 on a monitor with no left-hand bar, so reading the
# wrong slot returns a confident 0 and silently disables the trim instead of
# failing. That is the entire reason this is a checked lookup.
res = mon.get('reserved') or []
if len(res) != 4:
    sys.exit(f'monitor {name} has a {len(res)}-entry reserved field, expected 4')
print(round(int(res[1]) * float(mon['scale'])))" "$1"; }

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

# The corner radius the notepad's own window rule states, in either dialect.
# Prints it, or exits with a reason.
#
# This replaces a one-line sed that could only ever match one of the two
# spellings, and it was the wrong one. Hyprland's syntax is `rounding 10`, space
# separated; the pattern required a comma after `rounding`, so it matched nothing
# in any real plain `.conf` -- including the spelling this repository's own
# example ships. For anyone not using a Lua config the gate could not pass, and
# reported "no rounding found for the notepad", which reads as the user's config
# being at fault when the config was fine and the check was not. The same gate had
# already been bitten in this path once, by `windowrulev2?`.
#
# Both spellings are accepted here: `rounding = 10` inside a Lua
# `hl.window_rule({...})` and `rounding 10` in a plain rule. The notepad's class
# has to appear in the same rule, so a rule belonging to some other window cannot
# be read as its own -- this repository's test sink is the standing example, and
# its class begins with the notepad's.
rule_rounding() {
    python3 -c "
import re, sys
path, cls = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding='utf-8', errors='replace') as fh:
        text = fh.read()
except OSError as exc:
    sys.exit('cannot read ' + path + ': ' + str(exc.strno))

def class_patterns(rule):
    # Every way a class can be written across the two dialects and the quoting
    # styles: class:foo unquoted (plain .conf), class = \"foo\", class = 'foo',
    # and class = [[foo]]. All four are real; missing one means a whole dialect
    # reports \"no rule found\" on a config that has the rule in front of it.
    out = []
    out += re.findall(r'class\s*:\s*([^,\n]+)', rule)
    out += re.findall(r'class\s*[:=]\s*\"([^\"]*)\"', rule)
    out += re.findall(r\"class\s*[:=]\s*'([^']*)'\", rule)
    out += re.findall(r'class\s*[:=]\s*\[\[(.*?)\]\]', rule, re.S)
    return [p.strip() for p in out]

def covers(rule):
    # Does this rule's class pattern actually match the notepad's class? Asking
    # the regex is the only honest test. Testing whether the class *text* merely
    # appears inside the rule looks equivalent and is not: this repository's test
    # sink is called dev.maxii.HyprScratchSink, so its class contains the
    # notepad's as a substring, and a containment test reads the sink's radius as
    # the notepad's. The same reasoning rejects a rule for the sink outright,
    # since ^(dev\.maxii\.HyprScratchSink)\$ does not match dev.maxii.HyprScratch.
    for pat in class_patterns(rule):
        try:
            if re.search(pat, cls):
                return True
        except re.error:
            # Not a regex Python can read. Fall back to a literal test on the
            # unescaped text, which errs towards refusing rather than matching.
            if cls in pat.replace(chr(92), ''):
                return True
    return False

number = re.compile(r'rounding\s*[=,:\s]\s*(\d+)')
rules = [m.group(0) for m in
         re.finditer(r'hl\.window_rule\s*\(\s*\{.*?\n?\}?\s*\)', text, re.S)]
rules += re.findall(r'^[ \t]*windowrule(?:v2)?[ \t]*=.*\$', text, re.M)
for rule in rules:
    if not covers(rule):
        continue
    found = number.search(rule)
    if found:
        print(found.group(1))
        break
else:
    sys.exit('no window rule matching ' + cls + ' states a rounding in ' + path)
" "$HYPRLAND_CONFIG" "$NOTEPAD_CLASS"; }
