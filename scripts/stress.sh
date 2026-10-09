#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-stress.XXXXXX")
export WORK
trap 'rm -rf "$WORK"' EXIT
cd "$HERE"
. "$HERE/lib.sh"
require_command SCRATCH_BIN hypr-scratch
N=${1:-12}

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
print(d.get('class') or '(none)')"; }
pid() { pgrep -x hypr-scratch 2>/dev/null | head -1; }

wait_for() {  # $1 = want, $2 = timeout in tenths
    local i=0
    while [ "$i" -lt "${2:-40}" ]; do
        [ "$(open)" = "$1" ] && return 0
        sleep 0.1; i=$((i + 1))
    done
    return 1
}
toggle() {  # $1 = want, $2 = timeout in tenths
    [ "$(open)" = "$1" ] && return 0
    setsid env HYPR_SCRATCH_FILE="$WORK"/v.md "$SCRATCH_BIN" >/dev/null 2>&1 </dev/null &
    wait_for "$1" "$2"
}

STUCK_OPEN=0; FAILED_FOCUS=0; REOPEN_FAIL=0; DIED=0
pkill -x hypr-scratch 2>/dev/null
sleep 1.2
: > "$WORK"/v.md
setsid env HYPR_SCRATCH_FILE="$WORK"/v.md "$SCRATCH_BIN" >/dev/null 2>&1 </dev/null &
if ! wait_for OPEN 50 && ! toggle OPEN 50; then
    echo "  FAIL  the notepad would not open to start with"
    exit 1
fi
START_PID=$(pid)

[ "$(open)" = OPEN ] && toggle closed 40

for i in $(seq 1 "$N"); do
    if ! toggle OPEN 40; then
        echo "  cycle $i: FAILED to open (or closed itself, active=$(act))"
        REOPEN_FAIL=$((REOPEN_FAIL + 1))
        [ "$(open)" = "closed" ] || STUCK_OPEN=$((STUCK_OPEN + 1))
    elif [ "$(act)" != "$NOTEPAD_CLASS" ]; then
        echo "  cycle $i: open but not focused (active=$(act))"
        FAILED_FOCUS=$((FAILED_FOCUS + 1))
    fi
    toggle closed 40
    if [ "$(open)" = "OPEN" ]; then
        echo "  cycle $i: FAILED to close"
        STUCK_OPEN=$((STUCK_OPEN + 1))
    fi
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
