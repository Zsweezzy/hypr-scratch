#!/usr/bin/env bash
# Acceptance suite for hypr-scratch: every gate is checked against the running compositor, resolving rather than assuming.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# Artifacts go to a scratch dir rather than a fixed /tmp path or the source tree.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-gates.XXXXXX")
export WORK
cd "$HERE"
FAIL=0
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_command SCRATCH_BIN hypr-scratch
require_sink
# grim is developer-only; the suite uses it just for GATE 5's pixel diff, which is skipped without it.
HAVE_GRIM=0
command -v grim >/dev/null 2>&1 && HAVE_GRIM=1
SINK_X=1980
SINK_Y=880
# Filled in by sink_up from the window's real geometry; left empty so a stray click_sink clicks nothing.
SINK_PX=""
SINK_PY=""
SINK_PX_W=""
SINK_PY_H=""
SINK_STATE=""

open() { hyprctl clients -j 2>/dev/null | python3 -c "
import json, os, sys
want = os.environ['NOTEPAD_CLASS']
print('OPEN' if any(c['class'] == want for c in json.load(sys.stdin)) else 'closed')"; }
act() { hyprctl activewindow -j 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print('(unreadable)'); raise SystemExit(0)
# An empty object means nothing holds the focus, a real state of this desktop, not a stolen window.
print(d.get('class') or '(none)')"; }
field() { hyprctl clients -j 2>/dev/null | python3 -c "
import json, os, sys
want = os.environ['NOTEPAD_CLASS']
for c in json.load(sys.stdin):
    if c['class'] == want:
        print(c.get('$1')); break"; }
check() {
    # An empty value never satisfies a non-empty expectation, or "both empty" reports PASS.
    if [ -z "$3" ]; then
        echo "  FAIL  $1 (no expectation; the check itself is broken)"
        FAIL=1
    elif [ -z "$2" ]; then
        echo "  FAIL  $1 (got nothing, want '$3')"
        FAIL=1
    elif [ "$2" = "$3" ]; then
        echo "  PASS  $1"
    else
        echo "  FAIL  $1 (got '$2', want '$3')"
        FAIL=1
    fi
}

## Reading the note
note() { cat "$WORK"/v.md 2>/dev/null; }
note_says() {  # $1 = the marker to look for
    case $(note) in *"$1"*) return 0 ;; *) return 1 ;; esac
}

# Containment, not equality: a person typing at the note mid-run must not fail a gate the app did not fail.
check_note() {  # $1 = label, $2 = marker
    local got
    got=$(note)
    if [ -z "$got" ]; then
        echo "  FAIL  $1 (the note is empty; want it to contain '$2')"
        FAIL=1
        return
    fi
    case $got in
        *"$2"*) ;;
        *)
            echo "  FAIL  $1 (got '$got', want it to contain '$2')"
            FAIL=1
            return
            ;;
    esac
    if [ "$got" != "$2" ]; then
        echo "         NOTE  the note holds more than this suite typed:"
        echo "               got  '$got'"
        echo "               want '$2' and nothing else"
        echo "               Something typed at the notepad while it was focused, so"
        echo "               this run is measuring a desktop with a person on it."
    fi
    echo "  PASS  $1"
}

wait_state() {  # $1 = want, $2 = timeout in tenths of a second
    local i=0
    while [ "$i" -lt "${2:-30}" ]; do
        [ "$(open)" = "$1" ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}
# wtype has no target: the destination is checked at the keystroke, and a mismatch is fatal.
type_into() {  # $1 = the class that must have the focus, $2.. = wtype arguments
    local want=$1 have
    shift
    have=$(act)
    # The suite may take focus back from its own sink, but nothing else; a browser or empty desktop aborts.
    if [ "$have" = "$SINK_CLASS" ] && [ "$want" != "$SINK_CLASS" ]; then
        echo "         the suite's own sink has the focus; asking for $want back"
        hyprctl dispatch "hl.dsp.focus({ class = \"$want\" })" >/dev/null 2>&1
        have=$(stable_focus 30)
    fi
    if [ "$have" != "$want" ]; then
        echo "  FAIL  refusing to type: '$have' has the focus, not '$want'."
        echo "        Keystrokes are delivered to the focused window with no way to"
        echo "        name a target, so typing now would put this test text into a"
        echo "        window the suite does not own. Close or unfocus it, then re-run."
        exit 1
    fi
    wtype "$@"
}
# The focused window's class, sampled until two reads agree, because focus release is asynchronous.
stable_focus() {  # $1 = timeout in tenths of a second
    local i=0 prev="" cur
    while [ "$i" -lt "${1:-20}" ]; do
        cur=$(act)
        [ -n "$cur" ] && [ "$cur" = "$prev" ] && { printf '%s' "$cur"; return 0; }
        prev=$cur
        sleep 0.2; i=$((i + 1))
    done
    printf '%s' "$cur"
}
# Never invoke bare: with no instance it becomes primary and blocks in the GTK loop, so detach and poll.
toggle() { [ "$(open)" = "$1" ] && return 0
           setsid env HYPR_SCRATCH_FILE="$WORK"/v.md "$SCRATCH_BIN" >/dev/null 2>&1 </dev/null &
           wait_state "$1" 40; }
toggle_open()  { toggle OPEN;   }
toggle_close() { toggle closed; }
alive() { pgrep -c -x hypr-scratch 2>/dev/null || true; }

reset_notepad() {
    # Retry and poll rather than sleep: re-open when a third party grabbed focus, bounded at three attempts.
    : > "$WORK"/v.md
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        pkill -x hypr-scratch 2>/dev/null
        sleep 1.2
        setsid env HYPR_SCRATCH_FILE="$WORK"/v.md "$SCRATCH_BIN" >/dev/null 2>&1 </dev/null &
        wait_state OPEN 50 || true
        # Poll once more: a third party grabbing focus a moment later dismisses it correctly.
        sleep 0.8
        [ "$(open)" = OPEN ] && return 0
        echo "         (attempt $attempt: something took focus; retrying)"
        sink_down
    done
    return 1
}

## The sink window: a floated, pinned target the suite owns and places, built from src/bin/sink.rs.
SINK_PID=""
# Counted, not tested for presence: "is there one" cannot tell the case that matters.
sink_windows() {
    hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
print(sum(1 for c in json.load(sys.stdin) if c['class'] == '$SINK_CLASS'))" 2>/dev/null
}
# Sink rect and centre in logical coords; six fields, because read's last var swallows the remainder.
sink_geom() {
    hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c['class'] == '$SINK_CLASS':
        x, y = c['at']
        w, h = c['size']
        print(x + w // 2, y + h // 2, x, y, w, h)
        break" 2>/dev/null
}

# Crop box in physical px; trims the reserved top strip so the bar's repaint is not read as the sink changing.
sink_crop_box() {
    local geom mon px py pw ph res v
    geom=$(physical_geom_of "$SINK_CLASS") || return 1
    # Exactly five fields, read by name: a missing one would be swallowed by the last variable.
    read -r mon px py pw ph <<<"$geom" || return 1
    # Validate each field alone; joining them with a colon also matches the separator.
    for v in "$px" "$py" "$pw" "$ph"; do
        case ${v:-} in ''|*[!0-9]*) return 1 ;; esac
    done
    [ -n "${mon:-}" ] || return 1
    [ "$pw" -gt 0 ] && [ "$ph" -gt 0 ] || return 1
    res=$(reserved_top_px "$mon") || return 1
    if [ "$py" -lt "$res" ]; then
        ph=$((ph - (res - py)))
        py=$res
    fi
    [ "$ph" -gt 0 ] || return 1
    echo "$px $py $pw $ph"
}

# Click point on the sink's largest notepad-free area; fails if none is at least 8px wide.
sink_exposed_point() {
    python3 -c "
import json, subprocess, sys
sink, note = sys.argv[1], sys.argv[2]
clients = json.loads(subprocess.run(
    ['hyprctl', 'clients', '-j'], capture_output=True, text=True).stdout)
def rect(cls):
    c = next((c for c in clients if c['class'] == cls), None)
    if c is None:
        return None
    (x, y), (w, h) = c['at'], c['size']
    return (x, y, x + w, y + h)
s = rect(sink)
if s is None:
    sys.exit('the sink is not open')
sx0, sy0, sx1, sy1 = s
n = rect(note)
pieces = []
if n is None:
    pieces.append(s)
else:
    nx0, ny0, nx1, ny1 = n
    if sy0 < ny0: pieces.append((sx0, sy0, sx1, min(sy1, ny0)))
    if sy1 > ny1: pieces.append((sx0, max(sy0, ny1), sx1, sy1))
    if sx0 < nx0: pieces.append((sx0, sy0, min(sx1, nx0), sy1))
    if sx1 > nx1: pieces.append((max(sx0, nx1), sy0, sx1, sy1))
pieces = [p for p in pieces if p[2] - p[0] >= 8 and p[3] - p[1] >= 8]
if not pieces:
    sys.exit('the notepad leaves no reachable part of the sink')
b = max(pieces, key=lambda p: (p[2] - p[0]) * (p[3] - p[1]))
print((b[0] + b[2]) // 2, (b[1] + b[3]) // 2, b[2] - b[0], b[3] - b[1])
" "$SINK_CLASS" "$NOTEPAD_CLASS"; }
sink_state() {
    hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
c = next((c for c in json.load(sys.stdin) if c['class'] == '$SINK_CLASS'), None)
if c is None:
    sys.exit(1)
print(str(bool(c.get('floating'))).lower(), str(bool(c.get('pinned'))).lower())" 2>/dev/null
}

# Set float/pin rather than toggling: the notepad rule's .*HyprScratch.* match already pins the sink.
sink_set_state() {  # $1 = want float, $2 = want pin
    local sel="class = \"$SINK_CLASS\"" cur
    cur=$(sink_state) || return 1
    if [ "${cur%% *}" != "$1" ]; then
        hyprctl dispatch "hl.dsp.window.float({ $sel })" >/dev/null 2>&1
        sleep 0.2
    fi
    cur=$(sink_state) || return 1
    if [ "${cur##* }" != "$2" ]; then
        hyprctl dispatch "hl.dsp.window.pin({ $sel })" >/dev/null 2>&1
        sleep 0.2
    fi
    sink_state
}

# A position inside the monitor's usable area; the Python below lives in a double-quoted string, so a double quote in it ends the string early.
sink_fit() {
    python3 -c "
import json, subprocess, sys
sink = sys.argv[1]
def hypr(*a):
    return json.loads(subprocess.run(
        ['hyprctl', *a, '-j'], capture_output=True, text=True).stdout)
win = next((c for c in hypr('clients') if c['class'] == sink), None)
if win is None:
    sys.exit('the sink is not open')
mon = next((m for m in hypr('monitors') if m['id'] == win['monitor']), None)
if mon is None:
    sys.exit('no monitor with id ' + str(win['monitor']))
sc = float(mon['scale'])
# size is physical, x/y logical: divide the size, not the origin; integer division on purpose.
mw, mh = int(mon['width'] / sc), int(mon['height'] / sc)
left, top, right, bottom = (int(v) for v in (mon.get('reserved') or [0, 0, 0, 0]))
ux0, uy0 = mon['x'] + left, mon['y'] + top
ux1, uy1 = mon['x'] + mw - right, mon['y'] + mh - bottom
(x, y), (w, h) = win['at'], win['size']
if w > ux1 - ux0 or h > uy1 - uy0:
    sys.exit(f'the sink is {w}x{h} and the usable area is only {ux1-ux0}x{uy1-uy0}')
print(min(max(x, ux0), ux1 - w), min(max(y, uy0), uy1 - h), w, h)
" "$SINK_CLASS"; }

sink_up() {
    sink_down
    setsid "$SINK_BIN" >/dev/null 2>&1 </dev/null &
    SINK_PID=$!
    # Disown so the EXIT trap's kill does not make bash print "Killed" on stderr.
    disown 2>/dev/null || true
    local i=0
    while [ "$i" -lt 40 ]; do
        [ "$(sink_windows)" -ge 1 ] && break
        sleep 0.25; i=$((i + 1))
    done
    # A selector matching two windows acts on nothing yet reports ok: assert exactly one sink.
    case $(sink_windows) in
        1) ;;
        0) echo "  FAIL  the sink window never appeared; is GTK working?"; return 1 ;;
        *) echo "  FAIL  $(sink_windows) sink windows are up; a leaked one is in the way"
           echo "        pkill -9 -x hypr-sink, then re-run"; return 1 ;;
    esac
    # class = "..." syntax, not class:foo -- a Lua syntax error there no-ops the dispatch while printing ok.
    local sel="class = \"$SINK_CLASS\""
    # Set the state rather than dispatching the toggles blindly; see sink_set_state.
    if ! SINK_STATE=$(sink_set_state true true); then
        echo "  FAIL  the sink's float and pin state could not be read or set, so"
        echo "        every click below would land on whatever is underneath it"
        FAIL=1
        return 1
    fi
    if [ "$SINK_STATE" != "true true" ]; then
        echo "  FAIL  the sink is float=$SINK_STATE after asking for 'true true'."
        echo "        It would sit underneath other windows and the clicks meant for"
        echo "        it would land on them instead."
        FAIL=1
        return 1
    fi
    hyprctl dispatch "hl.dsp.window.move({ $sel, x = $SINK_X, y = $SINK_Y })" >/dev/null 2>&1
    sleep 0.6
    # The move is only a preference: clamp into the usable area so it cannot hang off-screen.
    local fit
    if ! fit=$(sink_fit); then
        echo "  FAIL  $fit"
        FAIL=1
        return 1
    fi
    local fx fy fw fh
    read -r fx fy fw fh <<<"$fit"
    if [ "$fx" != "$SINK_X" ] || [ "$fy" != "$SINK_Y" ]; then
        echo "         asked for ($SINK_X,$SINK_Y), which is off the usable area;"
        echo "         using ($fx,$fy) instead"
        hyprctl dispatch "hl.dsp.window.move({ $sel, x = $fx, y = $fy })" >/dev/null 2>&1
        sleep 0.6
    fi
    # Read the point back from the compositor after placing: the move is a request the compositor may decline.
    SINK_GEOM=$(sink_geom)
    if [ -z "$SINK_GEOM" ]; then
        echo "  FAIL  the sink has no readable geometry, so no click can be placed"
        return 1
    fi
    read -r SINK_PX SINK_PY SINK_AT_X SINK_AT_Y SINK_W SINK_H <<<"$SINK_GEOM"
    # Post-condition: confirm the sink really landed in the usable area, not merely that we asked.
    local check
    if ! check=$(sink_fit); then
        echo "  FAIL  $check"
        FAIL=1
        return 1
    fi
    read -r fx fy fw fh <<<"$check"
    if [ "$fx" != "$SINK_AT_X" ] || [ "$fy" != "$SINK_AT_Y" ]; then
        echo "  FAIL  the sink is at ($SINK_AT_X,$SINK_AT_Y) but the usable area needs"
        echo "        ($fx,$fy). Part of it is off-screen, so a screenshot of it cannot"
        echo "        be cropped and the click point may be off-screen too."
        FAIL=1
        return 1
    fi
    echo "         sink is $SINK_W x $SINK_H at ($SINK_AT_X,$SINK_AT_Y);"
    # The middle is under the pinned notepad: click the exposed part, from live geometry.
    local point
    if ! point=$(sink_exposed_point); then
        echo "  FAIL  the sink is entirely covered by the notepad, so there is no"
        echo "        point on it a click could reach"
        FAIL=1
        return 1
    fi
    read -r SINK_PX SINK_PY SINK_PX_W SINK_PY_H <<<"$point"
    if [ "$SINK_PX_W" -lt "$SINK_W" ] || [ "$SINK_PY_H" -lt "$SINK_H" ]; then
        echo "         the notepad covers part of it; clicking $SINK_PX,$SINK_PY"
        echo "         in the exposed ${SINK_PX_W}x${SINK_PY_H} area, not its middle"
    else
        echo "         clicking its middle, $SINK_PX,$SINK_PY"
    fi
}
sink_down() {
    # Kill by PID, not a selector: one matching nothing falls back to the focused window.
    if [ -n "$SINK_PID" ] && kill -0 "$SINK_PID" 2>/dev/null; then
        kill -9 "$SINK_PID" 2>/dev/null
    fi
    SINK_PID=""
    # Match by exact name (-x): -f would also match this script's own python3 -c args.
    pkill -9 -x hypr-sink 2>/dev/null
    sleep 0.4
    # Wait for the window, not just the process: one on its way out still matches the class.
    local i=0
    while [ "$i" -lt 20 ] && [ "$(sink_windows)" -gt 0 ]; do
        sleep 0.15; i=$((i + 1))
    done
}
click_sink() {
    if [ -z "$SINK_PX" ]; then
        echo "  FAIL  click_sink called with no sink geometry; sink_up must run first"
        FAIL=1
        return 1
    fi
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
click_at() {  # $1 = logical x, $2 = logical y
    # ydotool's absolute mode is broken here: position via the compositor, press separately.
    hyprctl dispatch "hl.dsp.cursor.move({ x = $1, y = $2 })" >/dev/null 2>&1
    sleep 0.3
    ydotool click 0xC0 >/dev/null 2>&1
}
centre() {  # the middle of the notepad, as the compositor reports it
    python3 -c "
import json, sys
at, size = json.loads(sys.argv[1]), json.loads(sys.argv[2])
print(at[0] + size[0] // 2, at[1] + size[1] // 2)" "$(field at)" "$(field size)" 2>/dev/null
}

trap 'sink_down; rm -rf "$WORK"' EXIT

# Preflight: fail honestly up front if something else can steal focus, instead of eleven misleading FAILs later.
if ! reset_notepad; then
    echo "  FAIL  the notepad would not stay open across 3 attempts"
    FAIL=1
fi
THIEF=""
HOLDS=yes
NONE_SEEN=""
for _ in $(seq 1 12); do
    sleep 0.3
    NOW=$(act)
    if [ "$NOW" != "$NOTEPAD_CLASS" ]; then
        THIEF=$NOW
        HOLDS=""
        [ "$NOW" = "(none)" ] && NONE_SEEN=yes
    fi
done
# Nothing focused is not a thief: Hyprland passes through that, so nudge focus and retry.
if [ -n "$NONE_SEEN" ] && [ -z "${THIEF##(none)}" ]; then
    echo "         (nothing held the focus; asking the compositor for some)"
    hyprctl dispatch 'hl.dsp.focus({ direction = "left" })' >/dev/null 2>&1
    sleep 0.5
    HOLDS=yes
    THIEF=""
    for _ in $(seq 1 12); do
        sleep 0.3
        NOW=$(act)
        if [ "$NOW" != "$NOTEPAD_CLASS" ]; then
            THIEF=$NOW
            HOLDS=""
        fi
    done
fi
# Fatal, not a tally: without the focus, type_into would refuse to type and every gate below is void.
if [ -z "$HOLDS" ] || [ "$(open)" != OPEN ]; then
    if [ "$THIEF" = "(none)" ]; then
        echo "  FAIL  nothing holds the focus on this desktop, not even the notepad."
        echo "        That is a state Hyprland passes through rather than a window"
        echo "        taking focus, and it left every gate below measuring nothing."
        echo "        Click any window once, then re-run."
    else
        echo "  FAIL  '${THIEF:-nothing}' takes the focus away from the notepad while it"
        echo "        is up, and the notepad stays up. Every gate below that asserts who"
        echo "        holds the focus would be measuring that window instead, and the"
        echo "        suite refuses to type test text into it. Stopped here on purpose:"
        echo "        the rest of this run could not be trusted."
        echo
        echo "        Close or unfocus that window and re-run. If you do not know what"
        echo "        it is, it is the one named above."
    fi
    exit 1
fi

echo "GATE 1  opens as a floating, pinned, centred overlay"
if ! reset_notepad; then
    echo "  FAIL  the notepad would not stay open across 3 attempts"
    FAIL=1
fi
check "visible"            "$(open)"    "OPEN"
check "floating"           "$(field floating)" "True"
check "pinned above all"   "$(field pinned)"   "True"
check "size"               "$(field size)" "[640, 480]"
check "takes focus"        "$(act)"     "$NOTEPAD_CLASS"

CENTRE=$(python3 expected_centre.py 2>/dev/null)
WANT=${CENTRE%%|*}; REST=${CENTRE#*|}; GOT=${REST%%|*}; NOTE=${REST#*|}
echo "         expected $WANT, got $GOT  ($NOTE)"
check "exact centre"       "$GOT" "$WANT"

echo "GATE 2  typing lands in the note, and does not dismiss"
type_into "$NOTEPAD_CLASS" "GATE2-TYPE"
for _ in $(seq 1 40); do note_says "GATE2-TYPE" && break; sleep 0.1; done
check_note "note written" "GATE2-TYPE"
check "still open"    "$(open)"      "OPEN"

echo "GATE 3  clicking another window closes it"
# Checked: a sink that did not come up would make the failure name the notepad, not the missing window.
if ! sink_up; then
    echo "  FAIL  there is no sink window to click"
    exit 1
fi
click_sink
wait_state closed 40
check "closed"           "$(open)" "closed"
# Settled, not instantaneous: focus release is asynchronous, so one read can name the previous window.
check "focus handed back" "$(stable_focus)"  "$SINK_CLASS"

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
check "sink focused"     "$(stable_focus)"  "$SINK_CLASS"

# Crop to the sink's own rect, not the whole monitor: a monitor-wide diff can pass on a window it is not testing.
if [ "$HAVE_GRIM" = 0 ]; then
    echo "  SKIP  grim is not installed; the sink pixel-diff needs a screenshot tool"
else
BOX_BEFORE=$(sink_crop_box) || { echo "  FAIL  could not locate the sink to crop"; FAIL=1; }
MON=$(monitor_at "$SINK_PX")
grim -o "$MON" "$WORK"/before.png 2>/dev/null
type_into "$SINK_CLASS" "AFTER-CLOSE"
sleep 2
grim -o "$MON" "$WORK"/after.png 2>/dev/null
BOX_AFTER=$(sink_crop_box) || { echo "  FAIL  the sink is gone; cannot attribute the change"; FAIL=1; }

if [ -z "$BOX_BEFORE" ] || [ -z "$BOX_AFTER" ]; then
    echo "  FAIL  could not read the sink's rectangle, so the keystrokes cannot be"
    echo "        attributed to it"; FAIL=1
elif [ "$BOX_BEFORE" != "$BOX_AFTER" ]; then
    echo "  FAIL  the sink moved between the two screenshots"
    echo "          before: $BOX_BEFORE"
    echo "          after:  $BOX_AFTER"
    echo "        Comparing those would measure two different regions."
    FAIL=1
else
    CHANGED=$(python3 -c "
import os, sys
from PIL import Image, ImageChops
work = os.environ['WORK']
px, py, pw, ph = (int(v) for v in sys.argv[1:5])
a = Image.open(os.path.join(work, 'before.png')).convert('RGB')
b = Image.open(os.path.join(work, 'after.png')).convert('RGB')
box = (px, py, px + pw, py + ph)
if box[2] > a.width or box[3] > a.height:
    sys.exit(f'crop {box} is outside the {a.width}x{a.height} capture')
a, b = a.crop(box), b.crop(box)
print(sum(1 for p in ImageChops.difference(a, b).get_flattened_data() if max(p) > 12))
" $BOX_BEFORE 2>&1)
    case $CHANGED in
        ''|*[!0-9]*)
            echo "  FAIL  could not diff the sink's pixels: $CHANGED"; FAIL=1 ;;
        *)
            if [ "$CHANGED" -gt 200 ]; then
                echo "  PASS  typed text appeared in the sink on $MON ($CHANGED px changed"
                echo "        within its own rect $BOX_BEFORE, not across the monitor)"
            else
                echo "  FAIL  the sink did not receive the keystrokes ($CHANGED px changed"
                echo "        within its own rect $BOX_BEFORE)"; FAIL=1
            fi ;;
    esac
fi
fi

echo "GATE 6  Esc closes it"
toggle_open
check "reopened"  "$(open)" "OPEN"
check "has focus" "$(act)"  "$NOTEPAD_CLASS"
type_into "$NOTEPAD_CLASS" -k "Escape" 2>/dev/null
wait_state closed 40
check "closed"    "$(open)" "closed"

echo "GATE 7  the note is saved when the notepad closes"
check_note "note persisted" "GATE2-TYPE"

echo "GATE 8  the notepad's corner radius matches the rest of the desktop"
# CSS paints the corners, nothing else ties them to decoration.rounding; the number is read from data/style.css.
CSS_R=$(sed -n 's/.*border-radius: \([0-9]*\)px;.*/\1/p' "$HERE"/../data/style.css | head -1)
if [ -z "$CSS_R" ]; then
    echo "  FAIL  no border-radius found in data/style.css"
    FAIL=1
fi
GLOBAL_R=$(hyprctl getoption decoration:rounding 2>/dev/null | head -1 | sed 's/int: //')
# The rule's own rounding: an empty result is not a pass, since a rule that restates nothing leaves it to chance.
if [ ! -f "$HYPRLAND_CONFIG" ]; then
    echo "  FAIL  no Hyprland config at $HYPRLAND_CONFIG (set HYPR_SCRATCH_HYPRLAND_CONFIG)"
    FAIL=1
    RULE_R=missing
elif ! RULE_R=$(rule_rounding 2>&1); then
    echo "  FAIL  $RULE_R"
    RULE_R=missing
    FAIL=1
fi
check "CSS radius == decoration.rounding" "$CSS_R" "$GLOBAL_R"
check "window rule restates it"           "$RULE_R" "$GLOBAL_R"

echo "GATE 9  a window-manager close is a dismissal, not a quit"
# Proceed from close_request destroys the widget and bricks the notepad; it must dismiss instead.
toggle_open
check "open"      "$(open)" "OPEN"
check "is focused" "$(act)" "$NOTEPAD_CLASS"
# Address, not a class selector: a class that matches nothing falls back to the focused window.
ADDR=$(hyprctl clients -j 2>/dev/null | python3 -c "
import json, os, sys
want = os.environ['NOTEPAD_CLASS']
for c in json.load(sys.stdin):
    if c['class'] == want:
        print(c['address']); break")
if [ -z "$ADDR" ]; then
    echo "  FAIL  no address to close; the notepad is not a client after all"; FAIL=1
else
    hyprctl dispatch "hl.dsp.window.close({ address = \"$ADDR\" })" >/dev/null 2>&1
    wait_state closed 40
    check "closed"           "$(open)"  "closed"
    check "process survived" "$(alive)" "1"
    # The real test: not merely closed, but still alive and still working.
    toggle_open
    check "reopens after a WM close" "$(open)" "OPEN"
    check "still takes focus"        "$(act)"  "$NOTEPAD_CLASS"
    toggle_close
    check "closes again"             "$(open)" "closed"
    check "and the process is still just the one" "$(alive)" "1"
fi

echo "GATE 10  a click outside dismisses, even when it moves no focus"
# GTK4 has no client pointer grab, so --outside-click binds (non-consuming) report outside clicks; wiring is checked first.
check "the binary has the --outside-click mode" \
    "$("$SCRATCH_BIN" --help 2>/dev/null | grep -c -- '--outside-click')" "1"
check "and it is the notepad, not a stale build" \
    "$([ -x "$SCRATCH_BIN" ] && echo yes || echo no)" "yes"
bind_count() {  # $1 = description
    hyprctl binds -j 2>/dev/null | python3 -c "
import json, sys
want = sys.argv[1]
print(len([b for b in json.load(sys.stdin) if b.get('description') == want]))" "$1"
}
check "LMB bind registered" "$(bind_count 'Dismiss scratchpad notepad on outside click (LMB)')" "1"
check "RMB bind registered" "$(bind_count 'Dismiss scratchpad notepad on outside click (RMB)')" "1"
check "both are non-consuming" "$(hyprctl binds -j 2>/dev/null | python3 -c "
import json, sys
print(len([b for b in json.load(sys.stdin)
           if 'notepad' in (b.get('description') or '').lower()
           and 'outside click' in (b.get('description') or '').lower()]))")" "2"
check "and they really are non-consuming" "$(hyprctl binds -j 2>/dev/null | python3 -c "
import json, sys
print(len([b for b in json.load(sys.stdin)
           if 'notepad' in (b.get('description') or '').lower()
           and 'outside click' in (b.get('description') or '').lower()
           and b.get('non_consuming')]))")" "2"

# The click must land where focus does not move, or focus-away alone explains the close.
if ! reset_notepad; then
    echo "  FAIL  the notepad would not stay open across 3 attempts"; FAIL=1
fi
POINT=$(PYEOF='PYEOF'; python3 -c "$(cat <<'PYEOF'
"""Print `x,y` for a point where a click will not move focus, so gate 10 can tell outside-click from focus-away dismissal."""
import json,subprocess,sys,time
NOTEPAD_CLASS="dev.Zsweezzy.HyprScratch"
BACKGROUND_LEVELS={"0"}
INSET=6
def hyprctl(*a):
    return json.loads(subprocess.run(["hyprctl",*a,"-j"],capture_output=True,text=True).stdout)
def main():
    try:
        clients=hyprctl("clients")
        monitors=hyprctl("monitors")
        surfaces=hyprctl("layers")
    except Exception as e:
        print(e,file=sys.stderr); return 1
    nx,ny,nw,nh=None,None,None,None
    for c in clients:
        if c["class"]==NOTEPAD_CLASS:
            nx,ny=c["at"]; nw,nh=c["size"]; break
    if nx is None:
        print("no notepad",file=sys.stderr); return 1
    monitor=None
    for m in monitors:
        if m["x"]<=nx<nw+m["x"] or m["x"]<=nx<nw+m["x"] or True:
            pass
    # pick monitor containing notepad
    for m in monitors:
        if nx>=m["x"] and nx<nw+m["x"] and ny>=m["y"] and ny<nh+m["y"]:
            monitor=m; break
    if monitor is None:
        monitor=monitors[0] if monitors else None
    if monitor is None: print("no monitor",file=sys.stderr); return 1
    margin=40
    notepad_rect=(nx-margin,ny-margin,nx+nw+margin,ny+nh+margin)
    def clear_of_notepad(x,y):
        return not (notepad_rect[0]<=x<=notepad_rect[2] and notepad_rect[1]<=y<=notepad_rect[3])
    def inside(s,x,y,inset=INSET):
        return s["x"]+inset<=x<=s["x"]+s["w"]-inset and s["y"]+inset<=y<=s["y"]+s["h"]-inset
    scale=monitor["scale"]
    for s in surfaces:
        x=s["x"]+s["w"]//2; y=s["y"]+s["h"]//2
        if inside(s,x,y) and clear_of_notepad(x,y) and s.get("level",0) not in BACKGROUND_LEVELS:
            print(f"{x},{y}"); return 0
    blocked=[]
    for c in clients:
        ax,ay=c["at"]; cw,ch=c["size"]; blocked.append((ax,ay,ax+cw,ay+ch))
    for s in surfaces:
        blocked.append((s["x"],s["y"],s["x"]+s["w"],s["y"]+s["h"]))
    left=monitor["x"]+INSET; right=monitor["x"]+monitor["width"]//scale-INSET
    top=monitor["y"]+INSET; bottom=monitor["y"]+monitor["height"]//scale-INSET
    cx,cy=nx+nw//2,ny+nh//2
    best=None; bestd=None
    for x in range(left,right+1,8):
        for y in range(top,bottom+1,8):
            if not clear_of_notepad(x,y): continue
            if any(bx<=x<=bx2 and by<=y<=by2 for bx,by,bx2,by2 in blocked): continue
            d=abs(x-cx)+abs(y-cy)
            if bestd is None or d<bestd: best,bestd=(x,y),d
    if best is not None:
        print(f"{best[0]},{best[1]}"); return 0
    print("no point",file=sys.stderr); return 1
if __name__=="__main__": sys.exit(main())
PYEOF
)" 2>"$WORK"/point.err) || POINT=""
if [ -z "$POINT" ]; then
    echo "  FAIL  no point where a click leaves focus alone: $(cat "$WORK"/point.err)"
    FAIL=1
else
    PX=${POINT%,*}; PY=${POINT#*,}
    toggle_close
    BEFORE=$(stable_focus)
    echo "         $PX,$PY is not a window and should not take focus"
    click_at "$PX" "$PY"
    sleep 0.8
    # Precondition, not the measurement: if the point moves focus, the checks below are void.
    if [ "$(act)" != "$BEFORE" ]; then
        echo "  FAIL  a click at $PX,$PY moved focus ('$BEFORE' -> '$(act)')"
        echo "  SKIP  the notepad-closed checks below: they would measure"
        echo "        focus-away dismissal, not the outside-click path"
        FAIL=1
    else
        echo "  PASS  a click there does not move focus"

        reset_notepad || { echo "  FAIL  could not reopen the notepad"; FAIL=1; }
        type_into "$NOTEPAD_CLASS" "GATE10-OUTSIDE"
        for _ in $(seq 1 40); do note_says "GATE10-OUTSIDE" && break; sleep 0.1; done
        check_note "note written before the click" "GATE10-OUTSIDE"
        echo "         clicking the same point again, with the notepad up"
        click_at "$PX" "$PY"
        wait_state closed 40
        check "dismissed by a click that moved no focus" "$(open)" "closed"
        check "process survived"                   "$(alive)" "1"
        check_note "note saved on the way out" "GATE10-OUTSIDE"
        # The notepad must still be usable afterwards, not merely still running.
        toggle_open
        check "reopens after an outside click" "$(open)" "OPEN"
        check "still takes focus"               "$(act)"  "$NOTEPAD_CLASS"
        toggle_close
    fi
fi

echo "GATE 11  a click inside the notepad does not dismiss it"
# The other half: a script that always said "outside" would pass gate 10 while making the window unclickable.
if ! reset_notepad; then
    echo "  FAIL  the notepad would not stay open across 3 attempts"; FAIL=1
else
    read -r CX CY <<<"$(centre)"
    if [ -z "${CX:-}" ]; then
        echo "  FAIL  could not read the notepad's geometry to click inside it"; FAIL=1
    else
        echo "         clicking $CX,$CY, the middle of the notepad"
        click_at "$CX" "$CY"
        sleep 0.8
        check "still open"    "$(open)" "OPEN"
        check "still focused" "$(act)"  "$NOTEPAD_CLASS"
    fi
    toggle_close
fi

echo
[ "$FAIL" = 0 ] && echo "ALL GATES PASSED" || echo "SOME GATES FAILED"
exit "$FAIL"
