#!/usr/bin/env bash
# Visual acceptance for hypr-scratch, run against the compositor rather than the
# app: A/B the blur rule, and check the panel corners are actually rounded.
#
# The coordinate trap: `hyprctl clients` reports x/y in global *logical* space
# and w/h in *logical* too, but `grim` captures *physical* pixels. On a scale-2
# monitor whose logical origin is x=1920, a panel at logical (2560,317) 640x480
# is physical ((2560-1920)*2, 317*2) = (1280,634) 1280x960. Every monitor's
# origin, size and scale is read from the compositor rather than tabulated, since
# a table is a guess about somebody else's desk.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# Artifacts go to a scratch dir, not the repo and not a fixed /tmp path: the
# harness used to hardcode /tmp/opencode, which meant it only worked from one
# machine's leftovers and would have written into the source tree once it moved.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-visual.XXXXXX")
export WORK
FAIL=0
# shellcheck source=lib.sh
. "$HERE/lib.sh"
require_command SCRATCH_BIN hypr-scratch
require_hyprland_config

# Developer-only visual check: every gate here shoots the screen, so unlike
# `gates.sh` there is nothing that survives without a screenshot tool. Refuse
# rather than fail later with an empty capture.
if ! command -v grim >/dev/null 2>&1; then
    echo "This is the developer visual check; it needs 'grim' on PATH." >&2
    exit 2
fi

# Restore the config on the way out, whatever happened. This script edits the
# user's Hyprland config to A/B the blur rule, and a run that dies between
# "rewrite" and "rewrite back" would otherwise leave `no_blur = true` behind --
# a silently blurrier desktop that has nothing to do with a regression.
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

# The notepad's rect in PHYSICAL pixels, plus the name of the monitor it is on.
#
# The conversion is the whole reason this function exists, and it is arithmetic
# with three inputs, any of which differs per machine: the monitor's logical
# origin, its scale, and whether it is the one whose pixels `grim` will capture.
# A hardcoded table of monitors got two of those right only by coincidence, and
# silently measured a cropped region of nothing whenever the desktop disagreed.
#
# It used to be a `case` on the monitor id naming three specific outputs with
# their offsets baked in, which is a description of one desk, not of Hyprland.
# Everything is read from the session instead. `scale` is a float on some
# monitors, so the result is rounded to whole pixels: `grim` captures integers
# and `Image.getpixel` takes integers, and rounding is the honest way to say
# "approximately here" rather than truncating toward zero and being off by one
# at a fractional origin.
physical_geom() { physical_geom_of "$NOTEPAD_CLASS"; }

is_open() { hyprctl clients -j 2>/dev/null | python3 -c "
import json, os, sys
want = os.environ['NOTEPAD_CLASS']
print('yes' if any(c['class'] == want for c in json.load(sys.stdin)) else 'no')"; }

open_notepad() {
    # Poll, and retry. A fixed `sleep 3` and hope is how a run ends up measuring
    # a window that is not there: Steam took focus during development, the
    # notepad correctly dismissed itself, and every measurement below then ran
    # against an empty crop and reported a confident zero.
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
    # 2>&1 so the reason lands in $out. Without it a failure prints the message
    # to the terminal and "FAIL" with nothing after it, which is the same
    # unreadable empty-reason failure the gate had one revision earlier.
    local out
    out=$(python3 - "$HYPRLAND_CONFIG" "$1" 2>&1 <<'PY'
import re
import sys

cfg, on = sys.argv[1], sys.argv[2] == 'true'
want = not on          # no_blur is the negation of "blur on"
# Which rule is the notepad's. Backslashes are stripped before matching, because
# a plain config spells the class as a regex -- `class:^(dev\.Zsweezzy\.HyprScratch)$`
# -- and comparing that against the literal class finds nothing. The trailing
# `(?!\\w)` is what keeps the *test sink*, whose class is the notepad's plus
# "Sink", from being read as the notepad: a rule that turns blur off for the
# sink says nothing about the panel being measured.
MARKER = re.compile(r'(?<!\w)(?:dev\.Zsweezzy\.)?HyprScratch(?!\w)|hypr-scratch-overlay')
# Both a Lua config's `hl.window_rule({...})` and a plain `windowrulev2 = ...`
# open a rule. The Lua form spans lines, so a rule is collected by brace
# balance rather than by line, and the marker may be on any line of it.
#
# The `v2` is a group, not a suffix. Written as `windowrulev2?` the pattern asks
# for a literal "windowrulev" with an optional "2", which matches no spelling of
# the directive at all -- and because a redundant `windowrule\s*=` alternative was
# hiding that in RULE, only PLAIN was broken, only for plain configs, and only as
# a silent no-op. The Lua path worked, the suite went green, and the one thing it
# could not do was edit a plain config. That is the exact shape of bug this
# repository keeps a test for.
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
        # Remove one occurrence, taking whichever comma went with it. The edit is
        # surgical rather than a rebuild from split(','): rebuilding normalises
        # the spacing, so a cycle would leave a config that differs from the
        # original and grows a keyword per pass.
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

# `found`, not `hits`. The first thing this script does is ask for the state the
# config is already in -- "turn blur on" when the rule already says
# `no_blur = false` -- and that legitimately changes nothing. Counting edits as
# proof the rule exists makes the first call fail on a perfectly correct config,
# which is how the blur gate spent one run reporting an empty reason and blaming
# a rule it had in fact found and correctly left alone.
if found == 0:
    sys.exit(f'no hypr-scratch window rule in {cfg}, so there is nothing to toggle')
# A plain config whose keywords are spread over several windowrulev2 lines does
# not come back byte-identical -- the keyword is re-added to the first rule
# rather than to whichever line it was on. That is reported rather than hidden,
# because "the config you were measuring with is not the one you had" is the
# sort of thing that invalidates the number printed below. The trap on the way
# out restores the original from the backup taken before the first edit, so this
# is a note about the measurement, not a risk to the file.
open(cfg, 'w').write('\n'.join(lines))
print(f'{found} rule(s), {hits} line(s) changed')
PY
    ) || { echo "  FAIL  could not set the blur rule: $out"; exit 1; }
    echo "         blur $([ "$1" = true ] && echo on || echo off): $out"
    # `luac` is a nicety, not a requirement. Written as
    # `command -v luac && luac -p ... || fail`, a machine without it fails the
    # `&&` chain and falls into the `||` branch, so the gate reported a Lua
    # syntax error in a config it had never tried to parse -- on every desktop
    # without the Lua toolchain, which is every plain `.conf` one. It only means
    # anything for a Lua config in the first place.
    if command -v luac >/dev/null; then
        luac -p "$HYPRLAND_CONFIG" || {
            echo "  FAIL  the edit left a Lua syntax error in $HYPRLAND_CONFIG"
            exit 1
        }
    fi
    # The authoritative check, and the one that covers a plain config as well: if
    # the compositor still loads the config afterwards, the edit was survivable.
    # A config that fails to reload leaves the notepad unruled and the blur
    # measurement meaningless, so that is checked rather than assumed.
    if ! hyprctl reload >/dev/null 2>&1; then
        echo "  FAIL  $HYPRLAND_CONFIG does not load; the edit broke it"
        exit 1
    fi
    sleep 1
}

shoot() {  # $1 = output name
    local geom; geom=$(physical_geom)
    # Without this the `read` below quietly yields five empty fields, the
    # arithmetic below quietly yields a degenerate box, and the crop is silently
    # empty -- so the diff is empty and the gate reports a confident zero.
    if [ -z "$geom" ]; then
        echo "  FAIL  no geometry for the notepad; is it open?"
        exit 1
    fi
    # $PX $PY $PW $PH land in the scratch dir for python
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
# A/B with a null control. Two shots in the same state give the noise floor, so
# the blur-off comparison has something to be compared against: a difference
# that is only a little larger than the noise floor is not evidence of blur.
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
# An empty result means the measurement failed, which is a different problem
# from the blur not working. Say so, rather than comparing empty strings and
# reporting a confident zero.
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
# Sample a short way along each edge. A rounded corner shows the backdrop here
# (low contrast against the panel); a square one would show panel fill, which
# differs from the interior by the panel's own alpha over whatever is behind.
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
