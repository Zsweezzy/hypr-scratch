#!/usr/bin/env python3
"""Print where Hyprland will centre the notepad, and where it actually is, as
`expected|actual|note`.

Two traps this exists to avoid:

* `hyprctl monitors` reports x/y in global *logical* space but width/height in
  *physical* pixels, while `hyprctl clients` reports at/size in logical. Mixing
  them puts the expectation a whole scale factor out. Everything below is
  divided by the monitor's scale to be in one space.
* The expected centre is derived, never hardcoded. Hyprland centres a floating
  window inside the monitor's *usable* area, and the reserved top changes
  whenever the status bar grows or shrinks. A baked-in expectation goes stale
  silently and then reads as a placement bug.
"""
import json
import subprocess


def hyprctl(*args):
    return json.loads(subprocess.run(["hyprctl", *args, "-j"],
                                     capture_output=True, text=True).stdout)


target = next(c for c in hyprctl("clients") if "HyprScratch" in c["class"])
monitor = {m["id"]: m for m in hyprctl("monitors")}[target["monitor"]]
scale = monitor["scale"]
width, height = monitor["width"] // scale, monitor["height"] // scale
reserved = monitor.get("reserved", [0, 0, 0, 0])  # already logical

x, y = target["at"]
w, h = target["size"]
expected_x = monitor["x"] + (width - w) // 2
expected_y = monitor["y"] + reserved[1] + (height - reserved[1] - reserved[3] - h) // 2

print(f"[{expected_x}, {expected_y}]"
      f"|[{x}, {y}]"
      f"|{monitor['name']} scale {scale}, usable y {reserved[1]}..{height - reserved[3]}")
