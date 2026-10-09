"""Print `x,y` for a point where a click will not move focus.

Used by gate 10, which has to tell the outside-click dismissal apart from
focus-away dismissal. Clicking any ordinary window changes focus, and
focus-away dismissal would close the notepad anyway, so a click on a window
proves nothing about which mechanism did it. What is needed is a click that
leaves focus exactly where it was.

Two kinds of point qualify, in order of preference:

  1. The status bar. It is a layer surface, it is on every monitor, it never
     drifts, and clicking it does not focus anything. Its rect comes from the
     compositor, so there is no hardcoded coordinate to go stale.
  2. Bare wallpaper -- a pixel covered by no client and no layer surface above
     the background. This is the case that motivated the feature (clicking the
     desktop used to leave the notepad up), so it is worth testing when one
     exists, but on a tiled desktop it is often a few pixels wide and is not
     something to build a test on.

The point is computed rather than hardcoded throughout, because the desktop
layout changes constantly -- windows open, close and resize while a suite runs
-- and a fixed coordinate is either covered by something on the day or sits so
far into a margin that it stops being a realistic place to click.
"""

import json
import subprocess
import sys
import time

# The notepad's window class. Equality, never a substring test: the acceptance
# suite also runs a window whose class starts with this one, and a substring
# match silently selects whichever of the two the compositor happens to list
# first -- reporting the sink's geometry as the notepad's.
NOTEPAD_CLASS = "dev.Zsweezzy.HyprScratch"

# The wallpaper is layer level 0. Anything above it is a surface that would
# take the click instead of the desktop.
BACKGROUND_LEVELS = {"0"}
# Inset from a surface's edge, so a rounding difference between what the
# compositor reports and where the surface really is cannot put the point on a
# neighbouring surface.
INSET = 6


def hyprctl(*what):
    """Runs hyprctl and parses the JSON, retrying, or returns None."""
    for _ in range(3):
        try:
            out = subprocess.run(
                ["hyprctl", *what, "-j"], capture_output=True, text=True, timeout=5
            ).stdout
            return json.loads(out) if out.strip() else None
        except (subprocess.SubprocessError, ValueError):
            time.sleep(0.4)
    return None


def monitor_of_point(monitors, x, y):
    for m in monitors:
        if m["x"] <= x < m["x"] + m["width"] // m["scale"] and m["y"] <= y < m[
            "y"
        ] + m["height"] // m["scale"]:
            return m
    return None


def main():
    clients = hyprctl("clients") or []
    monitors = hyprctl("monitors") or []
    layers = hyprctl("layers") or {}

    notepad = next((c for c in clients if c["class"] == NOTEPAD_CLASS), None)
    if notepad is None:
        print("no notepad window", file=sys.stderr)
        return 1
    nx, ny = notepad["at"]
    nw, nh = notepad["size"]
    notepad_rect = (nx, ny, nx + nw, ny + nh)

    monitor = monitor_of_point(monitors, nx + nw // 2, ny + nh // 2)
    if monitor is None:
        print("could not locate the notepad's monitor", file=sys.stderr)
        return 1

    # `hyprctl layers` nests one level deeper than it looks:
    # {monitor: {"levels": {level: [surface, ...]}}}. Iterating the monitor's
    # value directly yields the string "levels" and then integers, and fails
    # deep in the loop with a TypeError about strings used as dictionaries.
    surfaces = []
    for name, data in layers.items():
        if name != monitor["name"]:
            continue
        for level, entries in data.get("levels", {}).items():
            if level in BACKGROUND_LEVELS:
                continue
            surfaces.extend(entries)

    def clear_of_notepad(x, y):
        # Comfortably clear of the notepad's own edge, so a one-pixel
        # disagreement between the compositor's rect and the script's cannot
        # turn an intended outside click into an inside one.
        margin = 24
        return not (
            notepad_rect[0] - margin <= x <= notepad_rect[2] + margin
            and notepad_rect[1] - margin <= y <= notepad_rect[3] + margin
        )

    def inside(surface, x, y, inset=INSET):
        return (
            surface["x"] + inset <= x <= surface["x"] + surface["w"] - inset
            and surface["y"] + inset <= y <= surface["y"] + surface["h"] - inset
        )

    # 1. The status bar, or any other layer surface that is not the wallpaper.
    #    The notepad is placed below the bar's monitor strip, so a bar click is
    #    always outside the notepad.
    for surface in surfaces:
        x = surface["x"] + surface["w"] // 2
        y = surface["y"] + surface["h"] // 2
        if inside(surface, x, y) and clear_of_notepad(x, y):
            print(f"{x},{y}")
            return 0

    # 2. Otherwise, bare wallpaper. Sweep the whole monitor rather than the
    #    notepad's neighbourhood: one tiled window can cover everything around
    #    the notepad while leaving plenty of bare desktop further out.
    blocked = []
    for client in clients:
        (ax, ay), (cw, ch) = client["at"], client["size"]
        blocked.append((ax, ay, ax + cw, ay + ch))
    for surface in surfaces:
        blocked.append(
            (surface["x"], surface["y"], surface["x"] + surface["w"], surface["y"] + surface["h"])
        )

    left = monitor["x"] + INSET
    right = monitor["x"] + monitor["width"] // monitor["scale"] - INSET
    top = monitor["y"] + INSET
    bottom = monitor["y"] + monitor["height"] // monitor["scale"] - INSET
    cx, cy = nx + nw // 2, ny + nh // 2

    best, best_distance = None, None
    for x in range(left, right + 1, 8):
        for y in range(top, bottom + 1, 8):
            if not clear_of_notepad(x, y):
                continue
            if any(bx <= x <= bx2 and by <= y <= by2 for bx, by, bx2, by2 in blocked):
                continue
            distance = abs(x - cx) + abs(y - cy)
            if best_distance is None or distance < best_distance:
                best, best_distance = (x, y), distance
    if best is not None:
        print(f"{best[0]},{best[1]}")
        return 0

    print(
        f"no click on {monitor['name']} would leave focus alone: no bar, and "
        "every pixel is covered by a window or the wallpaper-only strip is too "
        "thin to aim at",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
