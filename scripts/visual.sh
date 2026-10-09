#!/usr/bin/env bash
# Visual acceptance: A/B the blur rule and check the panel corners are rounded; all coordinates read from the compositor.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# Artifacts go to a scratch dir, not the repo and not a fixed /tmp path.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-visual.XXXXXX")
export WORK
FAIL=0
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_command SCRATCH_BIN hypr-scratch
require_hyprland_config

# Every gate here shoots the screen, so refuse without grim rather than fail later with an empty capture.
if ! command -v grim >/dev/null 2>&1; then
    echo "This is the developer visual check; it needs 'grim' on PATH." >&2
    exit 2
fi

# Restore the config on the way out: this script edits it to A/B the blur rule, so a died run must not leave `no_blur`.
CONFIG_BACKUP=$WORK/hyprland.conf.orig
cp "$HYPRLAND_CONFIG" "$CONFIG_BACKUP" || {
    echo "  FAIL  could not back up $HYPRLAND_CONFIG" >&2
    exit 1
}
restore_config() {
    cp "$CONFIG_BACKUP" "$HYPRLAND_CONFIG" 2>/dev/null
    rm -rf "$WORK"
}
trap restore_config EXIT
cd "$HERE"

# The notepad's rect in physical pixels plus its monitor name; read from the session, not a hardcoded table.
physical_geom() { physical_geom_of "$NOTEPAD_CLASS"; }

is_open() { hyprctl clients -j 2>/dev/null | python3 -c "
import json, os, sys
want = os.environ['NOTEPAD_CLASS']
print('yes' if any(c['class'] == want for c in json.load(sys.stdin)) else 'no')"; }

open_notepad() {
    # Poll and retry; a fixed sleep is how a run ends up measuring a window that is not there.
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        pkill -x hypr-scratch 2>/dev/null
        sleep 1.2
        : > "$WORK"/v.md
        setsid env HYPR_SCRATCH_FILE="$WORK"/v.md "$SCRATCH_BIN" >/dev/null 2>&1 </dev/null &
        local i=0
        while [ "$i" -lt 50 ]; do
            [ "$(is_open)" = yes ] && return 0
            sleep 0.1; i=$((i + 1))
        done
        echo "         (attempt $attempt: the notepad would not stay open)"
    done
    echo "  FAIL  the notepad is not open; every measurement below is meaningless"
    exit 1
}

set_blur() {  # $1 = true (blur on) | false (blur off)
    # 2>&1 so the reason lands in $out; otherwise a failure prints an empty reason.
    local out
    out=$(python3 - "$HYPRLAND_CONFIG" "$1" 2>&1 <<'PY'
import re
import sys

cfg, on = sys.argv[1], sys.argv[2] == 'true'
want = not on          # no_blur is the negation of "blur on"
# Which rule is the notepad's; backslashes stripped, and the trailing (?!\w) keeps the test sink out.
MARKER = re.compile(r'(?<!\w)(?:dev\.Zsweezzy\.)?HyprScratch(?!\w)|hypr-scratch-overlay')
# `windowrule(?:v2)?` as a group; written `windowrulev2?` it matched no spelling for plain configs.
RULE = re.compile(r'windowrule(?:v2)?\s*=|window_rule\s*\(')
NO_BLUR = re.compile(r'no_blur\s*=\s*(?:true|false)')
PLAIN = re.compile(r'^(\s*windowrule(?:v2)?\s*=\s*)(.*?)\s*$')


def set_lua(line):
    """The Lua form: `no_blur = <bool>` is already the whole setting, so this is
    a plain substitution and is idempotent however many times it runs."""
    return NO_BLUR.sub('no_blur = ' + str(want).lower(), line)


def set_plain(line, allow_add):
    """The plain form: `windowrulev2 = float, no_blur, class:...` lists its
    keywords, so this is an add or a remove rather than an assignment.

    `allow_add` is False for every rule but the first, because a config that
    spreads one window's keywords over four `windowrulev2` lines should not
    collect a second `no_blur` on each of the other three. Blur is off if *any*
    matching rule says so, so one is enough -- and one is also what makes
    turning blur back on restore the file it was taken from.

    A rule whose only keyword was `no_blur` is left as a bare `class:` match
    while blur is off, which Hyprland treats as a rule with nothing to apply
    rather than as an error, and which gets the keyword back on the next call.
    """
    head, body = PLAIN.match(line).groups()
    if want and not allow_add:
        return line
    if not want:
        # Surgical removal, not a rebuild from split(','), which normalises spacing and grows a keyword per pass.
        out = re.sub(r'no_blur\s*,\s*', '', body, count=1)
        if out == body:
            out = re.sub(r'\s*,\s*no_blur\s*$', '', body, count=1)
        if out == body:
            return line
        return head + out
    if re.search(r'\bno_blur\b', body):
        return line
    return head + 'no_blur, ' + body


src = open(cfg).read()
lines = src.split('\n')
found = 0
hits = 0
added = False
i = 0
while i < len(lines):
    if not RULE.search(lines[i]):
        i += 1
        continue
    depth = lines[i].count('{') - lines[i].count('}')
    start = i
    i += 1
    while i < len(lines) and depth > 0:
        depth += lines[i].count('{') - lines[i].count('}')
        i += 1
    block = '\n'.join(lines[start:i]).replace('\\', '')
    if not MARKER.search(block):
        continue
    found += 1
    for j in range(start, i):
        if PLAIN.match(lines[j]):
            new = set_plain(lines[j], allow_add=not added)
            if want and new != lines[j]:
                added = True
        else:
            new = set_lua(lines[j])
        if new != lines[j]:
            lines[j] = new
            hits += 1

# Count `found`, not `hits`: the first call legitimately changes nothing.
if found == 0:
    sys.exit(f'no hypr-scratch window rule in {cfg}, so there is nothing to toggle')
# A spread-out plain config does not come back byte-identical; reported rather than hidden.
open(cfg, 'w').write('\n'.join(lines))
print(f'{found} rule(s), {hits} line(s) changed')
PY
    ) || { echo "  FAIL  could not set the blur rule: $out"; exit 1; }
    echo "         blur $([ "$1" = true ] && echo on || echo off): $out"
    # luac is a nicety: `command -v luac && ... || fail` would fall into the fail branch without it.
    if command -v luac >/dev/null; then
        luac -p "$HYPRLAND_CONFIG" || {
            echo "  FAIL  the edit left a Lua syntax error in $HYPRLAND_CONFIG"
            exit 1
        }
    fi
    # The authoritative check: if the compositor still loads the config, the edit was survivable.
    if ! hyprctl reload >/dev/null 2>&1; then
        echo "  FAIL  $HYPRLAND_CONFIG does not load; the edit broke it"
        exit 1
    fi
    sleep 1
}

shoot() {  # $1 = output name
    local geom; geom=$(physical_geom)
    # Without this, empty fields yield a degenerate box and a confidently-zero diff.
    if [ -z "$geom" ]; then
        echo "  FAIL  no geometry for the notepad; is it open?"
        exit 1
    fi
    printf '%s\n' "$geom" > "$WORK"/.geom
    local out; out=$(awk '{print $1}' "$WORK"/.geom)
    grim -o "$out" "$1"
}

stats() { python3 - "$1" <<'PY'
import sys
import os
from PIL import Image
WORK = os.environ["WORK"]
px, py, pw, ph = (int(v) for v in open(os.path.join(WORK, '.geom')).read().split()[-4:])
im = Image.open(sys.argv[1]).convert('RGB')
panel = im.crop((px, py, px + pw, py + ph))
data = list(panel.get_flattened_data())
n = len(data)
mean = tuple(sum(p[i] for p in data) // n for i in range(3))
var = sum(sum((p[i] - mean[i]) ** 2 for i in range(3)) for p in data) / n
print(f"{mean[0]},{mean[1]},{mean[2]} {var ** 0.5:.2f}")
PY
}

echo "GATE 8  the panel is translucent enough for the compositor to frost it"
# A/B with a null control: two shots in the same state give the noise floor to compare against.
panel_diff() { python3 -c "
import os, sys
from PIL import Image, ImageChops
work = os.environ['WORK']
px, py, pw, ph = (int(v) for v in open(os.path.join(work, '.geom')).read().split()[-4:])
box = (px, py, px + pw, py + ph)
a = Image.open(sys.argv[1]).convert('RGB').crop(box)
b = Image.open(sys.argv[2]).convert('RGB').crop(box)
v = list(ImageChops.difference(a, b).get_flattened_data())
if not v:
    raise SystemExit('empty crop: the geometry or the capture was wrong, not the blur')
n = sum(1 for p in v if max(p) > 8)
print(f'{n} {sum(sum(p) for p in v) / len(v):.2f}')" "$1" "$2"; }

set_blur true;  open_notepad
shoot "$WORK"/blur_a.png; sleep 1; shoot "$WORK"/blur_b.png
set_blur false; open_notepad
shoot "$WORK"/blur_off.png; sleep 1; shoot "$WORK"/blur_c.png
set_blur true

NULL=$(panel_diff "$WORK"/blur_a.png "$WORK"/blur_b.png 2>&1)
OFFNULL=$(panel_diff "$WORK"/blur_off.png "$WORK"/blur_c.png 2>&1)
EFFECT=$(panel_diff "$WORK"/blur_a.png "$WORK"/blur_off.png 2>&1)
echo "  interior mean/stddev, blur on : $(stats "$WORK"/blur_a.png 2>&1)"
echo "  interior mean/stddev, blur off: $(stats "$WORK"/blur_off.png 2>&1)"
echo "  noise floor, blur on  vs on  : $NULL"
echo "  noise floor, blur off vs off : $OFFNULL"
echo "  blur on vs off (the effect)   : $EFFECT"
# An empty result means the measurement failed, not that blur is broken; say so rather than reporting zero.
if [ -z "$NULL" ] || ! printf '%s' "$NULL" | grep -qE '^[0-9]+ '; then
    echo "  FAIL  could not measure the panel: $NULL"
    FAIL=1
else
    read -r E_CNT E_MEAN <<<"$EFFECT"
    read -r N_CNT N_MEAN <<<"$NULL"
    if [ "$E_CNT" -gt $(( N_CNT * 3 + 500 )) ] && awk "BEGIN{exit !($E_MEAN > $N_MEAN * 2 + 0.5)}"; then
        echo "  PASS  blur measurably changes the panel, well above the noise floor"
    else
        echo "  FAIL  blur is not reaching the panel"; FAIL=1
    fi
fi

set_blur true; open_notepad; shoot "$WORK"/final.png

echo "GATE 9  the corners are rounded, not square"
python3 - <<'PY'
import os
import sys
from PIL import Image
WORK = os.environ['WORK']
px, py, pw, ph = (int(v) for v in open(os.path.join(WORK, '.geom')).read().split()[-4:])
im = Image.open(os.path.join(WORK, "final.png")).convert('RGB')
# Sample a short way along each edge; a rounded corner shows backdrop, a square one shows panel fill.
interior = im.getpixel((px + pw // 2, py + ph // 2))
def spread(points):
    vals = [im.getpixel((px + dx, py + dy)) for dx, dy in points]
    return max(sum(abs(a - b) for a, b in zip(v, interior)) for v in vals)
# 6px in from each corner: inside the arc, still on the border's curve.
near = 6
corners = {
    'top-left':     [(near, near), (near + 4, near), (near, near + 4)],
    'top-right':    [(pw - 1 - near, near), (pw - 5 - near, near), (pw - 1 - near, near + 4)],
    'bottom-left':  [(near, ph - 1 - near), (near + 4, ph - 1 - near), (near, ph - 5 - near)],
    'bottom-right': [(pw - 1 - near, ph - 1 - near), (pw - 5 - near, ph - 1 - near), (pw - 1 - near, ph - 5 - near)],
}
bad = 0
for name, pts in corners.items():
    d = spread(pts)
    print(f"  {name:13s} max channel-diff from interior = {d}")
    if d > 90:
        bad += 1
sys.exit(1 if bad else 0)
PY
[ $? = 0 ] && echo "  PASS  all four corners follow the rounded path" || { echo "  FAIL  a corner is filled square"; FAIL=1; }

echo
[ "$FAIL" = 0 ] && echo "ALL VISUAL GATES PASSED" || echo "SOME VISUAL GATES FAILED"
exit "$FAIL"
