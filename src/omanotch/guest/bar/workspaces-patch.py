#!/usr/bin/env python3
"""Patch a clone of Omarchy 4.5's workspaces widget (widgets/Workspaces.qml)
for Omanotch.

usage: workspaces-patch.py <Workspaces.qml>   (patches the file in place)

Omarchy 4.5 gives every output workspaces of its own and each bar shows its
own output's. Omanotch's hidden NOTCH output is an output too, so its copy of
the bar (what the strip on the Mac shows) showed NOTCH's empty block instead of
the built-in display's, and at another width than the parked bar that takes
the strip's clicks. With this the NOTCH copy shows the workspaces of the
display the strip stands in for (the bar's notchParkedScreen); every other
copy stays Omarchy's. A widget without 4.5's per-output workspaces (Omarchy
4.0) has nothing to patch and stays as it is.
"""
import sys

MARK = "omarchy-notch-bar"
STOCK = '''  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
'''
PATCHED = '''  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    // omarchy-notch-bar: the copy on Omanotch's hidden NOTCH output shows
    // the workspaces of the display the strip stands in for.
    var stand = screen && String(screen.name).indexOf("NOTCH") === 0 && root.bar && root.bar.notchParkedScreen
      ? String(root.bar.notchParkedScreen) : ""
    var monitors = stand ? Hyprland.monitors.values : []
    for (var i = 0; i < monitors.length; i++)
      if (monitors[i] && monitors[i].name === stand) return monitors[i]
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
'''


def patch(text):
    """The widget with the patch; the same text when there is nothing to patch."""
    if PATCHED in text:
        return text
    if MARK in text:
        sys.exit("workspaces-patch: an older or changed patch is in the widget; re-clone the bar")
    if text.count(STOCK) != 1:
        return text
    return text.replace(STOCK, PATCHED)


def main():
    path = sys.argv[1]
    text = open(path).read()
    new = patch(text)
    if new == text:
        print("already patched" if PATCHED in text else "nothing to patch")
        return
    open(path, "w").write(new)
    print("patched")


if __name__ == "__main__":
    main()
