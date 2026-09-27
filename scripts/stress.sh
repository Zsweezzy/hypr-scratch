#!/usr/bin/env bash
# Stress the open/close cycle.
#
# The dismissal is driven by `is-active`, so the thing that can go wrong is a
# transition being missed or double-counted: the notepad closing itself the
# instant it opens, or refusing to reopen. Both show up as a wrong state after a
# fixed settle time, so the state is sampled rather than assumed.
#
# It also asserts the *process* is the same one at the end as at the start. State
# checks alone cannot see a crash: if the app dies, the next toggle quietly
# starts a fresh primary, the window comes up, the state looks right, and the
# suite reports a clean run over a binary that fell over. That is not
# hypothetical here -- a `kill` dispatch aimed at a helper's own window once
# took the notepad down with it, and the state-based run could not tell.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# Artifacts go to a scratch dir, not the repo and not a fixed /tmp path: the
# harness used to hardcode /tmp/opencode, which meant it only worked from one
# machine's leftovers and would have written into the source tree once it moved.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-stress.XXXXXX")
export WORK
trap 'rm -rf "$WORK"' EXIT
cd "$HERE"
N=${1:-12}

open() { hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
print('OPEN' if any('HyprScratch' in c['class'] for c in json.load(sys.stdin)) else 'closed')"; }
act() { hyprctl activewindow -j 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["class"])'; }
pid() { pgrep -x hypr-scratch 2>/dev/null | head -1; }

# Detach every invocation. Called bare, `hypr-scratch` is a request to toggle
# *if an instance is running*; if none is, the caller becomes the primary and
# blocks in the GTK main loop, so a stress run would hang rather than fail. The
# env var rides along harmlessly -- a secondary sends the toggle and exits
# without constructing a store -- but it means a recovered primary still uses
# the scratch note rather than the user's real one.
#
# Observe only. Never toggles. This distinction is load-bearing: a toggle sent
# while a launch is still in flight lands *after* that launch has opened the
# window and closes it again. The window appears in about 0.3s, so sampling the
# state 0.05s after starting the process reads "closed", decides a toggle is
# needed, and then reliably produces a run that opens and immediately closes.
wait_for() {  # $1 = want, $2 = timeout in tenths
    local i=0
    while [ "$i" -lt "${2:-40}" ]; do
        [ "$(open)" = "$1" ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}
# Send exactly one toggle, then wait for the result. Guarded so it is a no-op
# when the state is already right, but the guard is only an optimisation: it
# cannot see a launch that is still in flight, which is what `wait_for` is for.
toggle() {  # $1 = want, $2 = timeout in tenths
    [ "$(open)" = "$1" ] && return 0
    setsid env HYPR_SCRATCH_FILE="$WORK"/v.md ~/.local/bin/hypr-scratch >/dev/null 2>&1 </dev/null &
    wait_for "$1" "$2"
}

STUCK_OPEN=0; FAILED_FOCUS=0; REOPEN_FAIL=0; DIED=0
pkill -x hypr-scratch 2>/dev/null
sleep 1.2
: > "$WORK"/v.md
setsid env HYPR_SCRATCH_FILE="$WORK"/v.md ~/.local/bin/hypr-scratch >/dev/null 2>&1 </dev/null &
# Bring it up: give the launch above time to land before deciding anything.
# Only toggle if the window genuinely never appeared.
if ! wait_for OPEN 50 && ! toggle OPEN 50; then
    echo "  FAIL  the notepad would not open to start with"
    exit 1
fi
START_PID=$(pid)

# Start from a known-closed state.
[ "$(open)" = OPEN ] && toggle closed 40

for i in $(seq 1 "$N"); do
    if ! toggle OPEN 40; then
        echo "  cycle $i: FAILED to open (or closed itself, active=$(act))"
        REOPEN_FAIL=$((REOPEN_FAIL + 1))
        [ "$(open)" = "closed" ] || STUCK_OPEN=$((STUCK_OPEN + 1))
    elif [ "$(act)" != "dev.maxii.HyprScratch" ]; then
        echo "  cycle $i: open but not focused (active=$(act))"
        FAILED_FOCUS=$((FAILED_FOCUS + 1))
    fi
    toggle closed 40
    if [ "$(open)" = "OPEN" ]; then
        echo "  cycle $i: FAILED to close"
        STUCK_OPEN=$((STUCK_OPEN + 1))
    fi
    # Catch a crash the moment it happens, rather than at the end of the run.
    if [ "$(pid)" != "$START_PID" ]; then
        echo "  cycle $i: the process changed ($START_PID -> $(pid)); it crashed"
        DIED=$((DIED + 1))
        toggle OPEN 50 || { echo "  cycle $i: and would not come back"; exit 1; }
        START_PID=$(pid)
    fi
done

echo "  cycles: $N  reopen-failures: $REOPEN_FAIL  focus-failures: $FAILED_FOCUS  stuck: $STUCK_OPEN  crashed: $DIED"
[ "$REOPEN_FAIL" = 0 ] && [ "$FAILED_FOCUS" = 0 ] && [ "$STUCK_OPEN" = 0 ] && [ "$DIED" = 0 ] \
    && echo "  PASS  every cycle opened, focused, and closed, in the same process" \
    || { echo "  FAIL  unstable"; exit 1; }
