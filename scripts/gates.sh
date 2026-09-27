#!/usr/bin/env bash
# Acceptance suite for hypr-scratch. Every gate is checked against the running
# compositor rather than against the app's own idea of itself, because the whole
# point of moving off a layer surface is that the compositor's view is what
# matters.
#
# Two rules learned the hard way here, both of which produced *false failures*
# while the app was behaving correctly:
#
#   * Resolve, never assume. Earlier revisions hardcoded the coordinate they
#     clicked and the window they expected to be behind the notepad. The status
#     bar resized mid-session, the reserved top moved, kitty grew from y=159 to
#     y=36 and swallowed the click point; and one gate captured HDMI-A-1 while
#     clicking a point derived from DP-1, which passed only while kitty happened
#     to be on the other workspace.
#
#   * Poll for state, never sleep and assume. Wayland deactivation is
#     asynchronous relative to gtk_window_hide(), so a hide/show pair can
#     straddle a compositor round trip and a fixed sleep samples the window
#     mid-transition. 15/15 clean stress cycles say the behaviour is fine; the
#     sampling was the problem.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# Artifacts go to a scratch dir rather than a fixed /tmp path or the source
# tree, so the suite can live in the repo without writing into it.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-gates.XXXXXX")
export WORK
cd "$HERE"
FAIL=0

SINK_CLASS=scratchsink
SINK_X=1980
SINK_Y=880
# A point well inside the sink, chosen when the suite places it.
SINK_PX=2400
SINK_PY=1000

open() { hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
print('OPEN' if any('HyprScratch' in c['class'] for c in json.load(sys.stdin)) else 'closed')"; }
act() { hyprctl activewindow -j 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["class"])'; }
field() { hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if 'HyprScratch' in c['class']:
        print(c.get('$1')); break"; }
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got '$2', want '$3')"; FAIL=1; fi; }

wait_state() {  # $1 = want, $2 = timeout in tenths of a second
    local i=0
    while [ "$i" -lt "${2:-30}" ]; do
        [ "$(open)" = "$1" ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}
toggle_open()  { [ "$(open)" = OPEN ]   || { hypr-scratch; wait_state OPEN 40; }; }
toggle_close() { [ "$(open)" = closed ] || { hypr-scratch; wait_state closed 40; }; }

reset_notepad() {
    pkill -x hypr-scratch 2>/dev/null
    sleep 1.5
    : > "$WORK"/v.md
    setsid env HYPR_SCRATCH_FILE="$WORK"/v.md ~/.local/bin/hypr-scratch >/dev/null 2>&1 </dev/null &
    sleep 3
}

## The sink window
#
# Gates 3 and 5 need "some other window" to click and to type into. Using a real
# desktop window for that was wrong twice over: it made the suite depend on the
# user's window layout, and typing into it was typing into whatever happened to
# be running -- in this case an AI TUI in kitty, which both redraws on any
# input and is somewhere you should not be sending test keystrokes.
#
# So the suite owns its own target: a `cat` in its own kitty, floated, pinned
# and placed by the suite. Pinned-floating sits above every tiled window, so the
# click is guaranteed to land on the sink, and the sink echoes what it is sent,
# which gives a large unambiguous pixel diff.
sink_up() {
    sink_down
    setsid kitty --class "$SINK_CLASS" -e sh -c 'cat > /dev/null' >/dev/null 2>&1 </dev/null &
    local i=0
    while [ "$i" -lt 40 ]; do
        hyprctl clients -j 2>/dev/null | grep -q "\"$SINK_CLASS\"" && break
        sleep 0.25; i=$((i + 1))
    done
    # `class = "..."`, not `class:...` -- the table is Lua, and `class:foo` is
    # a syntax error there that makes the whole dispatch a no-op while still
    # printing ok, which is a spectacularly quiet way to do nothing.
    local sel="class = \"$SINK_CLASS\""
    hyprctl dispatch "hl.dsp.window.float({ $sel })" >/dev/null 2>&1
    hyprctl dispatch "hl.dsp.window.pin({ $sel })" >/dev/null 2>&1
    hyprctl dispatch "hl.dsp.window.move({ $sel, x = $SINK_X, y = $SINK_Y })" >/dev/null 2>&1
    sleep 0.6
}
sink_down() {
    hyprctl dispatch "hl.dsp.window.close({ class = \"$SINK_CLASS\" })" >/dev/null 2>&1
}
click_sink() {
    hyprctl dispatch "hl.dsp.cursor.move({ x = $SINK_PX, y = $SINK_PY })" >/dev/null 2>&1
    sleep 0.3
    ydotool click 0xC0 >/dev/null 2>&1
}
monitor_at() {  # $1 = logical x -> the monitor's name
    hyprctl monitors -j 2>/dev/null | python3 -c "
import json, sys
x = int(sys.argv[1])
for m in json.load(sys.stdin):
    if m['x'] <= x < m['x'] + m['width'] // m['scale']:
        print(m['name']); break" "$1"
}

trap 'sink_down; rm -rf "$WORK"' EXIT

echo "GATE 1  opens as a floating, pinned, centred overlay"
reset_notepad
check "visible"            "$(open)"    "OPEN"
check "floating"           "$(field floating)" "True"
check "pinned above all"   "$(field pinned)"   "True"
check "size"               "$(field size)" "[640, 480]"
check "takes focus"        "$(act)"     "dev.maxii.HyprScratch"

CENTRE=$(python3 expected_centre.py 2>/dev/null)
WANT=${CENTRE%%|*}; REST=${CENTRE#*|}; GOT=${REST%%|*}; NOTE=${REST#*|}
echo "         expected $WANT, got $GOT  ($NOTE)"
check "exact centre"       "$GOT" "$WANT"

echo "GATE 2  typing lands in the note, and does not dismiss"
wtype "GATE2-TYPE"
for _ in $(seq 1 40); do [ "$(cat "$WORK"/v.md)" = "GATE2-TYPE" ] && break; sleep 0.1; done
check "note written"  "$(cat "$WORK"/v.md)"  "GATE2-TYPE"
check "still open"    "$(open)"      "OPEN"

echo "GATE 3  clicking another window closes it"
sink_up
echo "         clicking the sink at $SINK_PX,$SINK_PY"
click_sink
wait_state closed 40
check "closed"           "$(open)" "closed"
check "focus handed back" "$(act)"  "$SINK_CLASS"

echo "GATE 4  moving focus with a keybind closes it"
toggle_open
check "reopened" "$(open)" "OPEN"
hyprctl dispatch 'hl.dsp.focus({ direction = "left" })' >/dev/null 2>&1
wait_state closed 40
check "closed"   "$(open)" "closed"

echo "GATE 5  the keyboard really goes back to the window behind"
toggle_open
check "reopened" "$(open)" "OPEN"
click_sink
wait_state closed 40
check "notepad closed"   "$(open)" "closed"
check "sink focused"     "$(act)"  "$SINK_CLASS"
# Diff the whole of the sink's monitor, not a window-sized crop: the tiling can
# reflow between reading the geometry and taking the shot, and a stale crop
# silently compares two identical regions. Skip the top strip, where the status
# bar ticks.
MON=$(monitor_at "$SINK_PX")
grim -o "$MON" "$WORK"/before.png 2>/dev/null
wtype "AFTER-CLOSE"
sleep 2
grim -o "$MON" "$WORK"/after.png 2>/dev/null
CHANGED=$(python3 -c "
import os
from PIL import Image, ImageChops
work = os.environ['WORK']
a = Image.open(os.path.join(work, 'before.png')).convert('RGB')
b = Image.open(os.path.join(work, 'after.png')).convert('RGB')
box = (0, 100, a.width, a.height)
a, b = a.crop(box), b.crop(box)
print(sum(1 for p in ImageChops.difference(a, b).get_flattened_data() if max(p) > 12))" 2>/dev/null)
if [ "${CHANGED:-0}" -gt 200 ]; then
    echo "  PASS  typed text appeared in the sink on $MON ($CHANGED px changed)"
else
    echo "  FAIL  the sink did not receive the keystrokes (${CHANGED:-0} px)"; FAIL=1
fi

echo "GATE 6  Esc closes it"
toggle_open
check "reopened"  "$(open)" "OPEN"
check "has focus" "$(act)"  "dev.maxii.HyprScratch"
wtype -k "Escape" 2>/dev/null
wait_state closed 40
check "closed"    "$(open)" "closed"

echo "GATE 7  the note is saved when the notepad closes"
check "note persisted" "$(cat "$WORK"/v.md)" "GATE2-TYPE"

echo "GATE 8  the notepad's corner radius matches the rest of the desktop"
# The notepad's corners are painted by its own CSS, not by the compositor --
# with `rounding = 0` on the window rule the surface goes square but the arc
# remains, while a control window obeys `rounding` exactly. So the CSS number is
# the radius the user sees, and nothing keeps it equal to `decoration.rounding`
# except this check. They drifted once already (20 against 10), which is
# precisely the "the layers don't have the same radii" complaint.
CSS_R=$(sed -n 's/.*border-radius: \([0-9]*\)px;.*/\1/p' "$HERE"/../src/ui.rs | head -1)
GLOBAL_R=$(hyprctl getoption decoration:rounding 2>/dev/null | head -1 | sed 's/int: //')
RULE_R=$(sed -n '/name = "hypr-scratch-overlay"/,/^})/p' \
         "$HOME/.config/hypr/hyprland.lua" | sed -n 's/.*rounding = \([0-9]*\).*/\1/p')
check "CSS radius == decoration.rounding" "$CSS_R" "$GLOBAL_R"
check "window rule restates it"           "$RULE_R" "$GLOBAL_R"

echo "GATE 9  a window-manager close is a dismissal, not a quit"
# This is the one that used to brick the notepad. Returning Proceed from
# close_request ran GTK's default handler, which *destroys* the window; the
# process outlives it, so the next toggle called present() on a dead widget and
# the notepad stopped working until it was restarted -- silently. Reachable from
# outside, because the class is documented: closewindow or killactive on
# dev.maxii.HyprScratch is enough.
toggle_open
check "open"       "$(open)" "OPEN"
hyprctl dispatch 'hl.dsp.window.close({ class = "dev.maxii.HyprScratch" })' >/dev/null 2>&1
wait_state closed 40
check "closed"     "$(open)" "closed"
# The real test: not merely closed, but still alive.
toggle_open
check "reopens after a WM close" "$(open)" "OPEN"
check "still takes focus"        "$(act)"  "dev.maxii.HyprScratch"
toggle_close
check "closes again"             "$(open)" "closed"

echo
[ "$FAIL" = 0 ] && echo "ALL GATES PASSED" || echo "SOME GATES FAILED"
exit "$FAIL"
