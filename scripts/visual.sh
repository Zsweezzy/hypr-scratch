#!/usr/bin/env bash
# Visual acceptance for hypr-scratch, run against the compositor rather than the
# app: A/B the blur rule, and check the panel corners are actually rounded.
#
# The coordinate trap: `hyprctl clients` reports x/y in global *logical* space
# and w/h in *logical* too, but `grim` captures *physical* pixels. DP-1 has
# scale 2, so the panel at logical (2560,317) 640x480 is physical
# ((2560-1920)*2, 317*2) = (1280,634) 1280x960.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# Artifacts go to a scratch dir, not the repo and not a fixed /tmp path: the
# harness used to hardcode /tmp/opencode, which meant it only worked from one
# machine's leftovers and would have written into the source tree once it moved.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/hypr-scratch-visual.XXXXXX")
export WORK
trap 'rm -rf "$WORK"' EXIT
cd "$HERE"
FAIL=0

logical_geom() { hyprctl clients -j 2>/dev/null | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if 'HyprScratch' in c['class']:
        print(*c['at'], *c['size'], c['monitor']); break"; }

is_open() { hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
print('yes' if any('HyprScratch' in c['class'] for c in json.load(sys.stdin)) else 'no')"; }

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
        setsid env HYPR_SCRATCH_FILE="$WORK"/v.md ~/.local/bin/hypr-scratch >/dev/null 2>&1 </dev/null &
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
    python3 - ~/.config/hypr/hyprland.lua "$1" <<'PY'
import re, sys
cfg, on = sys.argv[1], sys.argv[2] == 'true'
s = open(cfg).read()
s = re.sub(r'(hl\.window_rule\(\{\n\tname = "hypr-scratch-overlay".*?)\tno_blur = (?:true|false),',
           r'\1\tno_blur = ' + ('true' if not on else 'false') + ',', s, flags=re.S)
open(cfg, 'w').write(s)
PY
    luac -p ~/.config/hypr/hyprland.lua || { echo "  LUA ERROR"; exit 1; }
    hyprctl reload >/dev/null 2>&1
    sleep 1
}

shoot() {  # $1 = output name
    local geom; geom=$(logical_geom)
    # Without this the `read` below quietly yields five empty fields, the
    # arithmetic below quietly yields a degenerate box, and the crop is silently
    # empty -- so the diff is empty and the gate reports a confident zero.
    if [ -z "$geom" ]; then
        echo "  FAIL  no geometry for the notepad; is it open?"
        exit 1
    fi
    read -r x y w h mon <<<"$geom"
    case "$mon" in
        0) OUT=DP-1; OX=1920; SC=2 ;;
        1) OUT=DP-2; OX=3840; SC=1 ;;
        *) OUT=HDMI-A-1; OX=0; SC=1 ;;
    esac
    PX=$(( (x - OX) * SC )); PY=$(( y * SC ))
    PW=$(( w * SC ));     PH=$(( h * SC ))
    # $PX $PY $PW $PH land in the scratch dir for python
    printf '%s %s %s %s\n' "$PX" "$PY" "$PW" "$PH" > "$WORK"/.geom
    grim -o "$OUT" "$1"
}

stats() { python3 - "$1" <<'PY'
import sys
import os
from PIL import Image
WORK = os.environ["WORK"]
px, py, pw, ph = (int(v) for v in open(os.path.join(WORK, '.geom')).read().split())
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
px, py, pw, ph = (int(v) for v in open(os.path.join(work, '.geom')).read().split())
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
px, py, pw, ph = (int(v) for v in open(os.path.join(WORK, '.geom')).read().split())
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
