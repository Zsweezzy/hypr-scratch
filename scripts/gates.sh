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
#     bar resized mid-session, the reserved top moved, the test sink grew from
#     y=159 to y=36 and swallowed the click point; and one gate captured one
#     monitor while clicking a point derived from another, which passed only
#     while the sink happened to be on the other workspace.
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
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_command SCRATCH_BIN hypr-scratch
require_sink
SINK_X=1980
SINK_Y=880
# Where to click the sink, filled in by `sink_up` from the window's real
# geometry rather than written down here. The placement above is a *request* to
# the compositor, and the window that comes back can be a different size, so a
# fixed point is a guess about a window that may not be there. Left empty on
# purpose, so a `click_sink` reached without a `sink_up` clicks nothing and says
# so, instead of clicking a coordinate and reporting whatever lay under it.
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
# An empty object is what Hyprland reports when *nothing* holds the focus, which
# is a real state this desktop passes through -- not an error, and not a window
# that stole anything. Reading it as a missing key raised a KeyError, and twelve
# of those tracebacks scrolled past before the gate that cared about them, which
# is the noise that teaches people to ignore a suite's output.
print(d.get('class') or '(none)')"; }
field() { hyprctl clients -j 2>/dev/null | python3 -c "
import json, os, sys
want = os.environ['NOTEPAD_CLASS']
for c in json.load(sys.stdin):
    if c['class'] == want:
        print(c.get('$1')); break"; }
check() {
    # An empty value never satisfies a non-empty expectation. Without this,
    # "both are empty" reports PASS, which is how the centre check came back
    # green while the notepad was not even open -- two failures that cancelled
    # out into a pass.
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
#
# The note's contents, and whether it holds a given marker.
note() { cat "$WORK"/v.md 2>/dev/null; }
note_says() {  # $1 = the marker to look for
    case $(note) in *"$1"*) return 0 ;; *) return 1 ;; esac
}

# Asserts that a marker the suite typed actually reached the note, and reports
# anything else the note is holding rather than failing on it.
#
# Containment, not equality, and the reason is not leniency. The notepad is a
# text editor: it takes every keystroke the compositor sends it, which on a live
# desktop includes the ones a person types on the physical keyboard while the
# notepad happens to be focused and in front. Instrumenting the buffer settled
# what that looks like from in here -- one run appended `!` then `"`, then
# removed them again, two backspaces deep. Insert, insert, undo, undo. A stuck
# key in a virtual device or a compositor artefact does not produce that; a
# person does. The save was faithful the whole time, and the note file held
# exactly what the buffer held.
#
# So an exact match read that as a corrupted save and failed a gate the app did
# not fail -- here `erGATE2-TYPE` failed "note written" and then "note
# persisted", two failures and one root cause, neither of them the notepad's.
# The marker arriving is the thing under test. Whatever else is in the note is
# printed in full, because silently swallowing it would hide the one situation in
# which the distinction matters: a save that is genuinely losing or mangling the
# text looks similar from out here, and the way to tell them apart is to be able
# to read what was actually written.
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
# Sends keystrokes to one named window, and refuses to send them anywhere else.
#
# `wtype` has no target: it delivers to whatever the compositor considers
# focused, full stop. The notepad and the sink are normally focused when these
# run, so it read as safe -- until a browser on the desktop took focus part-way
# through a run and the test string was delivered to it instead. The note came
# back with a partial prefix from an earlier save, gates 3, 4, 5, 6 and 10
# failed for reasons that had nothing to do with the notepad, and one of them
# passed for the wrong reason (see GATE 5).
#
# So the target is checked at the moment of the keystroke, not once at the start
# of the run. A focus thief can arrive between gates, and this is the boundary
# where that stops mattering: the suite's business is testing hypr-scratch, and
# injecting test text into whatever window the user happens to have open is a
# worse outcome than an aborted run.
#
# Fatal, not a warning, because there is no safe way to continue. A run that has
# already typed into the wrong window has no trustworthy result left to report.
type_into() {  # $1 = the class that must have the focus, $2.. = wtype arguments
    local want=$1 have
    shift
    have=$(act)
    # The sink is the one window here the suite owns outright -- it started it in
    # sink_up and it will kill it in sink_down -- so the suite may take the focus
    # back from it rather than abort. That is not a loosening of the rule below;
    # it is the rule applied honestly. The sink ends a run holding the focus
    # legitimately, because gate 5 types into it on purpose, and a later gate
    # that opens the notepad can find the sink still in front. Reading that as
    # "an unowned window has the focus" stops the run for something the suite
    # itself did.
    #
    # Nothing else is retaken. A browser, a terminal, or an empty desktop is not
    # the suite's to reach into, and those still abort.
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
# The focused window's class, sampled until two reads in a row agree.
#
# Not a nicety. A third-party window releasing focus does so asynchronously, so
# a single `hyprctl activewindow` taken right after the notepad closes can still
# name the window that *was* focused, while the compositor has already moved on.
# Capturing that as the "before" baseline makes the next click look like it
# moved focus, and the gate then reports a status bar that does not exist. This
# reads until the answer stops changing, which is what "the focus has settled"
# actually means.
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
# Never invoke the binary bare. If no instance is running, `hypr-scratch` becomes
# the primary and blocks in the GTK main loop, so a toggle meant to send "toggle"
# over the socket instead hangs the suite forever instead of failing it. That is
# not hypothetical: it is what happened when gate 9 killed the process and the
# suite had no way to tell dead from closed. Detach it, then wait for the state.
# The env var rides along harmlessly -- a secondary sends the toggle and exits
# without ever constructing a store -- but it means a recovered primary still
# uses the scratch note instead of the user's real one.
toggle() { [ "$(open)" = "$1" ] && return 0
           setsid env HYPR_SCRATCH_FILE="$WORK"/v.md "$SCRATCH_BIN" >/dev/null 2>&1 </dev/null &
           wait_state "$1" 40; }
toggle_open()  { toggle OPEN;   }
toggle_close() { toggle closed; }
alive() { pgrep -c -x hypr-scratch 2>/dev/null || true; }

reset_notepad() {
    # Retry, and poll rather than sleep. A fixed `sleep 3` and hope fails on a
    # live desktop: Steam launched mid-run here, took focus, and the notepad --
    # correctly, that is the whole point of focus-away dismissal -- closed itself
    # before the first check. That is the environment changing, not a regression,
    # so re-open rather than report a failure the app did not cause. Bounded at
    # three attempts so a genuinely broken build still fails.
    : > "$WORK"/v.md
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        pkill -x hypr-scratch 2>/dev/null
        sleep 1.2
        setsid env HYPR_SCRATCH_FILE="$WORK"/v.md "$SCRATCH_BIN" >/dev/null 2>&1 </dev/null &
        wait_state OPEN 50 || true
        # Confirm it *stays* open. Polling once and returning the instant the
        # window appears is not enough: a third party grabbing focus a moment
        # later dismisses the notepad correctly, and every check after this
        # then fails for a reason that has nothing to do with the notepad.
        sleep 0.8
        [ "$(open)" = OPEN ] && return 0
        echo "         (attempt $attempt: something took focus; retrying)"
        sink_down
    done
    return 1
}

## The sink window
#
# Gates 3 and 5 need "some other window" to click and to type into. Using a real
# desktop window for that was wrong twice over: it made the suite depend on the
# user's window layout, and typing into it was typing into whatever happened to
# be running -- in this case an AI TUI in a terminal, which both redraws on any
# input and is somewhere you should not be sending test keystrokes.
#
# So the suite owns its own target, floated, pinned and placed by the suite.
# Pinned-floating sits above every tiled window, so the click is guaranteed to
# land on the sink, and the sink displays what it is sent, which gives a large
# unambiguous pixel diff.
#
# It used to be `kitty --class scratchsink -e cat`, which worked but left the
# suite unable to run at all without a specific terminal emulator installed and
# configured -- and a terminal's own configuration is a real source of flakes: one
# revision failed twice because kitty had been resized and was swallowing the click
# point. The sink is now `src/bin/sink.rs`, built from this repository, so the only
# thing it needs is a Rust toolchain.
SINK_PID=""
# How many sink windows the compositor currently sees. Counted, not tested for
# presence, because "is there one" cannot tell the one case that matters.
sink_windows() {
    hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
print(sum(1 for c in json.load(sys.stdin) if c['class'] == '$SINK_CLASS'))" 2>/dev/null
}
# The sink's rectangle and the middle of it, in the logical coordinates the
# compositor reports and the pointer is moved in. Six separate fields rather
# than one formatted string, because `read a b <<<"1 2 3 4"` puts the
# *remainder* into b -- so a log phrase appended to the pair would quietly
# become part of the y coordinate.
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

# The sink's crop box in physical pixels: x, y, w, h, ready to hand to a
# screenshot crop. Trims the compositor's reserved top strip so the status bar's
# own repainting cannot be mistaken for the sink changing. Fails, rather than
# guessing, if the sink is not open or reports a monitor that is not there.
sink_crop_box() {
    local geom mon px py pw ph res v
    geom=$(physical_geom_of "$SINK_CLASS") || return 1
    # Exactly five fields, read by name: an extra or missing one would otherwise
    # be swallowed by the last variable and quietly shift the crop.
    read -r mon px py pw ph <<<"$geom" || return 1
    # Each field validated on its own. An earlier version joined two of them with
    # a colon and matched `*:*` to catch a missing field -- which of course also
    # matches the separator, so it rejected every rectangle the compositor
    # reported and the gate could never have passed.
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

# A point on the sink that the notepad is not covering: x, y, then the size of
# the exposed area it was taken from.
#
# The notepad is pinned above every other window, so wherever the two rectangles
# overlap, a click belongs to the notepad no matter what the sink's geometry
# says. The exposed area is the sink's rectangle minus the notepad's, and it
# splits into at most four pieces -- above, below, left of, right of. The
# largest is used, so the click lands as far from both edges as it can.
#
# Fails when there is no exposed area, or only a sliver too thin to hit
# reliably, rather than returning a point that would land on the notepad or on a
# window border. A minimum of 8 logical pixels: below that, whether the click
# reaches the sink at all is a coin toss, and a coin toss is not a measurement.
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
# The sink's float and pin flags, as "true true". Exits non-zero if it is gone.
sink_state() {
    hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
c = next((c for c in json.load(sys.stdin) if c['class'] == '$SINK_CLASS'), None)
if c is None:
    sys.exit(1)
print(str(bool(c.get('floating'))).lower(), str(bool(c.get('pinned'))).lower())" 2>/dev/null
}

# Puts the sink into a known float and pin state, instead of toggling it.
#
# `float` and `pin` are toggles, not setters. Dispatching one when the window is
# already in the wanted state turns it *off*, and the sink is created floated and
# pinned before the suite touches it -- by the notepad's own window rule, whose
# class match is the substring regex `.*HyprScratch.*`, which matches the sink's
# class too. So the suite's `pin` was unpinning the sink it had just arranged.
#
# An unpinned sink sits underneath whatever else is on that monitor. Here a
# fullscreen browser covered the whole of it, every click meant for the sink
# landed on the browser, and gates 3 and 5 reported "focus handed back: got
# firefox, want the sink". That reads as the app failing to hand focus over on a
# click, and is really the suite having clicked a different window and then
# blaming the notepad for the result.
#
# So the current state is read first and only changed when it is not already
# right. As with the placement, what matters afterwards is the state the
# compositor reports, not the dispatches that were sent.
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

# A position for the sink that puts it entirely inside the usable area of the
# monitor it is already on: x, y, w, h, all logical. Fails if it cannot fit.
#
# The requested placement was routinely out of bounds and nothing said so. A sink
# 400px tall at y=880 on a 1080px-tall usable area hangs 200px off the bottom.
# Hyprland accepts the move, and `hyprctl clients` then cheerfully reports the
# window at exactly the position that was asked for, because that is where its
# top-left corner is. The window is only half on the screen.
#
# This stayed invisible for as long as gate 5 cropped the whole monitor and never
# looked at the sink's own rectangle. Now that it does, the crop runs off the
# edge of the capture and the gate refuses to score -- correctly, and with a much
# less obvious cause than "the sink is in a stupid place".
#
# The monitor is the one the sink is actually on and the usable area has the
# reserved strips taken off it, so this holds on a different size, scale or bar.
#
# Note on the embedded Python: it lives inside a double-quoted shell string, so a
# double quote anywhere in it -- including in a comment -- ends the string early
# and hands the rest to the shell as commands. `bash -n` does not catch that,
# because the result is still valid shell; it just is not the program that was
# meant. Single quotes inside, or escape them.
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
# hyprctl reports a monitor's width and height in physical pixels but its x and y
# in logical ones, so the size has to be divided through and the origin must not.
# Integer division on purpose: a float here reaches the move dispatch as a
# fractional coordinate, which some parsers take and some do not.
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
    # Disowned, so the EXIT trap's `kill -9` does not make bash announce a killed
    # job. It prints "Killed" on stderr as the shell reaps it, which put a line
    # that reads exactly like a crash at the bottom of an otherwise clean run --
    # the kind of detail that teaches people to ignore the suite's output.
    disown 2>/dev/null || true
    local i=0
    while [ "$i" -lt 40 ]; do
        [ "$(sink_windows)" -ge 1 ] && break
        sleep 0.25; i=$((i + 1))
    done
    # Assert the precondition instead of assuming it. Every gate below that uses
    # the sink resolves it by class, and a Hyprland selector matching two windows
    # is ambiguous rather than wrong-looking: the `pin` and `move` dispatches
    # below act on nothing at all, still report ok, and the run continues
    # measuring a desktop that is not the one it set up. That is exactly what a
    # leaked sink from an earlier run did here.
    case $(sink_windows) in
        1) ;;
        0) echo "  FAIL  the sink window never appeared; is GTK working?"; return 1 ;;
        *) echo "  FAIL  $(sink_windows) sink windows are up; a leaked one is in the way"
           echo "        pkill -9 -x hypr-sink, then re-run"; return 1 ;;
    esac
    # `class = "..."`, not `class:...` -- the table is Lua, and `class:foo` is
    # a syntax error there that makes the whole dispatch a no-op while still
    # printing ok, which is a spectacularly quiet way to do nothing.
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
    # The request above is only a preference. Clamp it into the monitor's usable
    # area and ask again, so the sink is never left hanging off the bottom of the
    # screen where a screenshot of it cannot be cropped.
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
    # The placement above is a *request*, and the click below used to assume it
    # was obeyed. It is not always: a `move` onto a coordinate the compositor
    # adjusts, a window that opens at its own idea of a size, and a browser window
    # that happens to occupy the requested rectangle are all ordinary things to
    # find on a live desktop. The click then lands on whatever was underneath,
    # focus goes there, and gates 3 and 5 report "focus handed back: got firefox,
    # want the sink" -- which reads as the suite having clicked the wrong thing
    # and is not even wrong, because the sink was genuinely not there.
    #
    # So the point is read back out of the compositor after placing, rather than
    # assumed from the request. Same reasoning that took the hardcoded monitor
    # table out of the visual suite: derive it from the window that exists.
    SINK_GEOM=$(sink_geom)
    if [ -z "$SINK_GEOM" ]; then
        echo "  FAIL  the sink has no readable geometry, so no click can be placed"
        return 1
    fi
    read -r SINK_PX SINK_PY SINK_AT_X SINK_AT_Y SINK_W SINK_H <<<"$SINK_GEOM"
    # Post-condition, not another request: the sink must now actually be inside
    # the usable area. A `move` the compositor declines leaves the readback
    # unchanged, and finding that out here names the cause, where the same fact
    # discovered at the crop in gate 5 reads as a screenshot problem.
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
    # The middle of the sink is the obvious click target and it is the wrong one.
    # The notepad is 640x480, pinned above every other window, and sits in the
    # middle of the monitor; a sink placed anywhere near the middle has its centre
    # *underneath* the notepad. Clicking there hits the notepad, which -- already
    # being focused, and being the window meant to dismiss on focus loss rather
    # than on a click inside itself -- simply stays open.
    #
    # That is not a theory. It produced a run where the identical click closed the
    # notepad in one gate and missed in the next, purely on where the tiling landed
    # that second, and the second read as "the app stopped responding to clicks",
    # which is the worst thing this suite could possibly say.
    #
    # So the point is chosen inside the sink and outside the notepad, from the
    # geometry the compositor reports at this instant. A sink left with no exposed
    # area is reported as such rather than clicked at anyway.
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
    # Dispose of the sink by the PID we started, not through a Hyprland
    # selector. This is not fastidious: a selector that matches nothing does not
    # error, it falls back to the focused window, and a hard kill that lands on
    # the notepad instead of the sink destroys the very process gate 9 then
    # asserts on. It did exactly that, and reported it as "process survived:
    # got 0, want 1".
    if [ -n "$SINK_PID" ] && kill -0 "$SINK_PID" 2>/dev/null; then
        kill -9 "$SINK_PID" 2>/dev/null
    fi
    SINK_PID=""
    # Sweep strays from an earlier aborted run, matched by exact process name
    # (`-x`) rather than by a pattern over the command line. `-f` would also
    # match this script's own `python3 -c` snippets, whose arguments contain the
    # class name, and would take the suite out from under itself.
    pkill -9 -x hypr-sink 2>/dev/null
    sleep 0.4
    # Wait for the window itself, not just the process. `sink_up` used to poll
    # for the class and then move on, and a window that is on its way out still
    # matches -- so the "one sink" check passed while two were briefly up.
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
    # ydotool's absolute mode is broken on this machine, so the pointer is
    # positioned through the compositor and the button is pressed separately.
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

# Preflight: can this suite hold the focus at all?
#
# Several gates assert who owns the focus after a click, and every one of them
# is meaningless if something else is taking it. That is not hypothetical: a
# game launcher on this desktop grabs focus on a timer, and it turned three
# gates red with messages that named the notepad and the sink and neither was
# at fault. The behavioural half of those gates still passed -- the click really
# did reach the sink, the keystrokes really did land in it -- while the
# focus-ownership read reported the launcher, which is exactly the shape of
# misleading failure this suite is not supposed to produce.
#
# So the condition is tested up front, and named. Failing here is honest; letting
# it surface as eleven unrelated FAILs twenty seconds later is not.
#
# Every sample has to agree, and the sampling does not stop early. An earlier
# version broke out of the loop on the first correct reading, which made this
# check a claim that the notepad *had* the focus rather than that it can *keep*
# it -- and the window between that reading and GATE 1 is exactly where a focus
# thief arrives. It is also why the run that motivated all of this produced a
# single honest line here and eleven misleading ones below it: the verdict was
# recorded and the run continued anyway, and every gate after it was then
# measuring a desktop the suite did not control.
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
# Nothing holding the focus at all is a different problem from something taking
# it, and it is not always a broken desktop: this one passes through a state
# where `hyprctl activewindow` reports an empty object, usually just after a
# fullscreen window goes away. One directional focus is enough to leave it, so
# try that and say so, rather than reporting a focus thief that does not exist.
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
# Fatal, not a tally. A run that cannot keep the focus cannot check focus
# ownership, and `type_into` below will refuse to deliver keystrokes into it, so
# continuing would only produce a longer report of the same broken environment.
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
# Checked, because every assertion in this gate is about what the click reached.
# A sink that did not come up makes them all meaningless, and the failure they
# would otherwise produce names the notepad rather than the window that is
# missing.
if ! sink_up; then
    echo "  FAIL  there is no sink window to click"
    exit 1
fi
click_sink
wait_state closed 40
check "closed"           "$(open)" "closed"
# Settled, not instantaneous: a window that releases focus does so
# asynchronously, so a single read taken right after the click can name the
# window that was focused a moment ago and report it as where the focus landed.
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

# The evidence has to be attributable to the sink, so this crops to the sink's
# own rectangle rather than to its whole monitor.
#
# The monitor-wide crop was there for a real reason -- a stale rect silently
# compares two identical regions -- but it made the gate answer a different
# question: "did anything on this screen change?" rather than "did the keystrokes
# reach the sink?". Those are not the same, and the run that exposed it showed
# how: a browser on the same monitor held focus, the test string went into its
# address bar, the page reflowed, and this gate reported PASS with 3.8 million
# changed pixels. A gate that can pass because of a window it is not testing is
# worse than no gate, because it is believed.
#
# So the rect is read fresh, twice, and the gate refuses to score at all if the
# sink moved in between -- that is the failure the wide crop was hiding, and it
# deserves to be said out loud rather than averaged over. The reserved top strip
# comes out of the crop too, so the bar's own repainting cannot stand in for the
# sink.
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
# The notepad's corners are painted by its own CSS, not by the compositor --
# with `rounding = 0` on the window rule the surface goes square but the arc
# remains, while a control window obeys `rounding` exactly. So the CSS number is
# the radius the user sees, and nothing keeps it equal to `decoration.rounding`
# except this check. They drifted once already (20 against 10), which is
# precisely the "the layers don't have the same radii" complaint.
# Read from the stylesheet, which is `data/style.css` -- both the built-in default
# and the file the suite can point HYPR_SCRATCH_STYLE at. It used to live as a
# string in src/ui.rs, and this check silently reported "nothing" when it moved,
# which is the failure mode this suite exists to prevent: an assertion that
# stopped asserting.
CSS_R=$(sed -n 's/.*border-radius: \([0-9]*\)px;.*/\1/p' "$HERE"/../data/style.css | head -1)
if [ -z "$CSS_R" ]; then
    echo "  FAIL  no border-radius found in data/style.css"
    FAIL=1
fi
GLOBAL_R=$(hyprctl getoption decoration:rounding 2>/dev/null | head -1 | sed 's/int: //')
# The rule's own `rounding`, out of whatever config this user has. Both spellings
# are accepted, and both are handled in lib.sh's rule_rounding -- an empty result
# is not a pass, because a rule that restates nothing leaves the window's corners
# decided by which of the two numbers the compositor happens to apply, which is
# the mismatch this gate exists to catch.
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
# This is the one that used to brick the notepad. Returning Proceed from
# close_request ran GTK's default handler, which *destroys* the window; the
# process outlives it, so the next toggle called present() on a dead widget and
# the notepad stopped working until it was restarted -- silently. Reachable from
# outside, because the class is documented: closewindow or killactive on
# dev.maxii.HyprScratch is enough.
#
# The notepad is focused when this runs, and cannot be made open-but-unfocused:
# focus loss is itself a dismissal, so the two states are exclusive. That does
# not weaken the test. A misrouted dispatch falls back to the focused window, and
# the focused window is the notepad, so either way the compositor sends
# xdg_toplevel.close to the notepad and the code path under test is the same.
toggle_open
check "open"      "$(open)" "OPEN"
check "is focused" "$(act)" "$NOTEPAD_CLASS"
# Address rather than a class selector, and checked for emptiness: `closewindow`
# on a class is a whole-class regex match against the full GTK application id, so
# `class = "hypr-scratch"` silently matches nothing, matches the *focused* window
# instead, and still reports ok.
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
# The outside click cannot be detected from inside the app. GTK4 removed the
# client-side pointer grab API, so a window that is not grabbing never hears
# about clicks outside itself -- and the notepad must not grab, because a held
# grab stops Hyprland moving focus off it, which would break focus-away
# dismissal and swallow clicks on other windows. The compositor reports it
# instead: `hypr-scratch --outside-click`, bound to bare LMB/RMB with
# non_consuming so the click still reaches whatever was underneath.
#
# The wiring is checked first and separately, because all of it is invisible from
# the app: a bind that did not register, or one that was not non-consuming, would
# leave the app perfectly healthy and the feature simply dead.
#
# The bind descriptions are matched loosely, on "notepad" and "outside click".
# A Lua config's dispatchers are opaque to `hyprctl binds` -- they report
# `__lua` and a table index, not the command -- so the description is the only
# thing observable from out here, and matching it exactly would tie the suite to
# one particular user's wording.
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

# Now the behaviour, and this is the part that needs the isolation. A click on
# any ordinary window moves focus, and focus-away dismissal would close the
# notepad anyway -- so "clicked a thing and the notepad closed" is consistent
# with the new path never having run at all. The click has to go somewhere that
# demonstrably does not take focus, or the gate proves nothing.
#
# The point is found while the notepad is up, because the helper needs its
# monitor and its rect, and neither is knowable once it is closed. The point
# itself stays valid afterwards: it is chosen clear of the notepad's edges
# precisely so that closing the notepad cannot invalidate it.
if ! reset_notepad; then
    echo "  FAIL  the notepad would not stay open across 3 attempts"; FAIL=1
fi
POINT=$(python3 no_focus_point.py 2>"$WORK"/point.err) || POINT=""
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
    # This is a *precondition*, not the thing being measured. If it fails then a
    # click there did move focus, so the notepad closing is explained by
    # focus-away and says nothing about the outside-click path -- and the
    # assertions below would be reporting PASS for a mechanism they never
    # exercised. So it is a hard stop, not a warning: the gate fails and the
    # dependent checks are declared unrun rather than run and believed.
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
# The other half of the geometry test. Without it, a script that always answered
# "outside" would pass gate 10 perfectly while making the notepad impossible to
# click in -- which is worse than not having the feature, because the text
# selection and the context menu both go through clicks inside the window.
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
