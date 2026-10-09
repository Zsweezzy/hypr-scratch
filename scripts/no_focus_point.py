"""Print `x,y` for a point where a click will not move focus, so gate 10 can tell outside-click from focus-away dismissal."""

import json
import subprocess
import sys
import time

# The notepad's window class, matched by equality; the sink's class starts with this one.
NOTEPAD_CLASS = "dev.Zsweezzy.HyprScratch"

# The wallpaper is layer level 0; anything above it would take the click.
BACKGROUND_LEVELS = {"0"}
# Inset from a surface's edge so a rounding difference cannot put the point on a neighbour.
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

    # `hyprctl layers` nests {monitor: {"levels": {level: [surface, ...]}}}.
    surfaces = []
    for name, data in layers.items():
        if name != monitor["name"]:
            continue
        for level, entries in data.get("levels", {}).items():
            if level in BACKGROUND_LEVELS:
                continue
            surfaces.extend(entries)

    def clear_of_notepad(x, y):
        # Comfortably clear of the notepad's edge, so a one-pixel disagreement cannot turn an outside click inside.
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

    # 1. A layer surface that is not the wallpaper; a bar click is always outside the notepad.
    for surface in surfaces:
        x = surface["x"] + surface["w"] // 2
        y = surface["y"] + surface["h"] // 2
        if inside(surface, x, y) and clear_of_notepad(x, y):
            print(f"{x},{y}")
            return 0

    # 2. Otherwise bare wallpaper; sweep the whole monitor since one window can cover the notepad's neighbourhood.
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
