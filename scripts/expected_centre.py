#!/usr/bin/env python3
"""Print where Hyprland will centre the notepad and where it actually is, as `expected|actual|note`."""
import json
import subprocess

# The notepad's window class, matched by equality; the sink's class starts with this one.
NOTEPAD_CLASS = "dev.Zsweezzy.HyprScratch"


def hyprctl(*args):
    return json.loads(subprocess.run(["hyprctl", *args, "-j"],
                                     capture_output=True, text=True).stdout)


target = next(c for c in hyprctl("clients") if c["class"] == NOTEPAD_CLASS)
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
