#!/usr/bin/env bash

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
    export variable
}

# The notepad's window class, matched by equality; a substring match would land on the test sink.
export NOTEPAD_CLASS=dev.Zsweezzy.HyprScratch

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

reserved_top_px() {  # $1 = monitor name
    python3 -c "
import json, subprocess, sys
name = sys.argv[1]
mon = next((m for m in json.loads(subprocess.run(
        ['hyprctl', 'monitors', '-j'], capture_output=True, text=True).stdout)
    if m['name'] == name), None)
if mon is None:
    sys.exit(f'no monitor named {name}')
res = mon.get('reserved') or []
if len(res) != 4:
    sys.exit(f'monitor {name} has a {len(res)}-entry reserved field, expected 4')
print(round(int(res[1]) * float(mon['scale'])))" "$1"; }

# Builds the test-only sink if missing; its class must stay short (comm truncates at 15 chars) or pkill -x misses it.
SINK_CLASS=dev.Zsweezzy.HyprScratchSink
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

# The user's Hyprland config for the blur and `rounding` checks; neither is derivable from the session.
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

# The corner radius in the notepad's window rule, in either dialect; the class must appear in the same rule.
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
    # Every way a class can be written across the two dialects and quoting styles.
    out = []
    out += re.findall(r'class\s*:\s*([^,\n]+)', rule)
    out += re.findall(r'class\s*[:=]\s*\"([^\"]*)\"', rule)
    out += re.findall(r\"class\s*[:=]\s*'([^']*)'\", rule)
    out += re.findall(r'class\s*[:=]\s*\[\[(.*?)\]\]', rule, re.S)
    return [p.strip() for p in out]

def covers(rule):
    # Ask the regex, not substring containment: the test sink's class contains the notepad's.
    for pat in class_patterns(rule):
        try:
            if re.search(pat, cls):
                return True
        except re.error:
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
