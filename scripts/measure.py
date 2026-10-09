#!/usr/bin/env python3
"""Measure the notepad's corner radius by exact colour match, all four corners.

Luminance is not enough here. The panel fill and the blurred backdrop can sit
within a few levels of each other, so any "is this inside the window" test
built on brightness happily reports the wallpaper as panel -- which is exactly
what went wrong in earlier fits, inflating the radius to ~15 when the truth was
10. With the opaque probe in place the fill is exactly rgb(22,22,30) and the
border exactly rgb(41,46,66), so matching the actual colour removes the
ambiguity instead of tuning a threshold around it.
"""
import json
import subprocess
import sys

from PIL import Image

# The notepad's window class. Equality, never a substring test: the acceptance
# suite also runs a window whose class starts with this one, and a substring
# match silently selects whichever of the two the compositor happens to list
# first -- reporting the sink's geometry as the notepad's.
NOTEPAD_CLASS = "dev.Zsweezzy.HyprScratch"

FILL = (22, 22, 30)
BORDER = (41, 46, 66)
TOL = 6


def hy(*a):
    out = subprocess.run(["hyprctl", *a, "-j"], capture_output=True, text=True).stdout.strip()
    if not out:
        raise SystemExit(f"hyprctl {a} returned nothing")
    return json.loads(out)


def near(px, ref, tol=TOL):
    return all(abs(a - b) <= tol for a, b in zip(px, ref))


path = sys.argv[1]
mons = {m["id"]: m for m in hy("monitors")}
cl = [c for c in hy("clients") if c["class"] == NOTEPAD_CLASS]
if not cl:
    raise SystemExit("notepad not open")
c = cl[0]
m = mons[c["monitor"]]
s = m["scale"]
ox = int((c["at"][0] - m["x"]) * s)
oy = int(c["at"][1] * s)
im = Image.open(path).convert("RGB")
w, h = c["size"][0] * s, c["size"][1] * s

print(f"window logical {c['at']} {c['size']}  scale {s}  (physical {w}x{h})")
corners = {
    "top-left": (lambda x, y: (x, y)),
    "top-right": (lambda x, y: (w - 1 - x, y)),
    "bottom-left": (lambda x, y: (x, h - 1 - y)),
    "bottom-right": (lambda x, y: (w - 1 - x, h - 1 - y)),
}
radii = []
for name, at in corners.items():
    # Scan *along* each straight edge for where the stroke begins. Sampling a
    # fixed offset across the edge always finds the stroke (it runs the whole
    # length away from the corner), which measures nothing; what identifies the
    # radius is the first position along the edge where the stroke appears.
    edge_h = next((x for x in range(80)
                   if near(im.getpixel((ox + at(x, 0)[0], oy + at(x, 0)[1])), BORDER)), None)
    edge_v = next((y for y in range(80)
                   if near(im.getpixel((ox + at(0, y)[0], oy + at(0, y)[1])), BORDER)), None)
    # Diagonal crossing: for radius R (physical) the arc meets x=y at
    # t = R - R/sqrt(2), which is independent of the fill/border split.
    diag = next((t for t in range(60)
                 if near(im.getpixel((ox + at(t, t)[0], oy + at(t, t)[1])), BORDER)), None)
    r_axis = None if edge_h is None or edge_v is None else (edge_h + edge_v) / 2
    r_diag = None if diag is None else diag / (1 - 1 / 2 ** 0.5)
    r = r_axis if r_axis is not None else r_diag
    radii.append(r)
    print(f"  {name:13s} stroke begins at edge x={edge_h} y={edge_v}  diagonal t={diag}"
          f"  ->  edge {None if r_axis is None else round(r_axis / s, 1)}"
          f"  diag {None if r_diag is None else round(r_diag / s, 1)} logical")

good = [r for r in radii if r is not None]
if len(good) == 4:
    print(f"\n  all four corners: {min(good) / s:.1f}..{max(good) / s:.1f} logical"
          f"  spread {max(good) - min(good):.0f} physical px")
