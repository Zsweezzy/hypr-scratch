#!/usr/bin/env bash
# Stress the open/close cycle.
#
# The dismissal is driven by `is-active`, so the thing that can go wrong is a
# transition being missed or double-counted: the notepad closing itself the
# instant it opens, or refusing to reopen. Both show up as a wrong state after a
# fixed settle time, so the state is sampled rather than assumed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# Artifacts go to a scratch dir, not the repo and not a fixed /tmp path: the
# harness used to hardcode /tmp/opencode, which meant it only worked from one
# machine's leftovers and would have written into the source tree once it moved.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-gates.XXXXXX")
export WORK
trap 'rm -rf "$WORK"' EXIT
cd "$HERE"
open() { hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
print('OPEN' if any('HyprScratch' in c['class'] for c in json.load(sys.stdin)) else 'closed')"; }
act() { hyprctl activewindow -j 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["class"])'; }

N=${1:-12}
STUCK_OPEN=0; FAILED_FOCUS=0; REOPEN_FAIL=0

pkill -x hypr-scratch 2>/dev/null
sleep 1.5
: > "$WORK"/v.md
setsid env HYPR_SCRATCH_FILE="$WORK"/v.md ~/.local/bin/hypr-scratch >/dev/null 2>&1 </dev/null &
sleep 3
# Start from a known-closed state.
[ "$(open)" = "OPEN" ] && { ~/.local/bin/hypr-scratch; sleep 1.5; }

for i in $(seq 1 "$N"); do
    ~/.local/bin/hypr-scratch
    sleep 2.2
    s=$(open)
    if [ "$s" != "OPEN" ]; then
        echo "  cycle $i: FAILED to open (or closed itself)"
        REOPEN_FAIL=$((REOPEN_FAIL + 1))
        [ "$(open)" = "closed" ] || STUCK_OPEN=$((STUCK_OPEN + 1))
    elif [ "$(act)" != "dev.maxii.HyprScratch" ]; then
        echo "  cycle $i: open but not focused (active=$(act))"
        FAILED_FOCUS=$((FAILED_FOCUS + 1))
    fi
    ~/.local/bin/hypr-scratch   # close again
    sleep 1.5
    if [ "$(open)" = "OPEN" ]; then
        echo "  cycle $i: FAILED to close"
        STUCK_OPEN=$((STUCK_OPEN + 1))
    fi
done

echo "  cycles: $N  reopen-failures: $REOPEN_FAIL  focus-failures: $FAILED_FOCUS  stuck: $STUCK_OPEN"
[ "$REOPEN_FAIL" = 0 ] && [ "$FAILED_FOCUS" = 0 ] && [ "$STUCK_OPEN" = 0 ] \
    && echo "  PASS  every cycle opened, focused, and closed" \
    || echo "  FAIL  unstable"
