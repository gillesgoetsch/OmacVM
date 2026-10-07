#!/usr/bin/env python3
"""Patch a clone of Omarchy's background plugin (Background.qml) for Omanotch.

usage: apply-patch.py <Background.qml>        (patches the file in place)

Omarchy draws the wallpaper separately on every output, cropped to that
output. On the hidden NOTCH output (the strip beside the camera) that is a
thin, heavily zoomed slice of the middle of the image, which shows whenever
the bar is hidden (Super+Shift+Space). The patch lays the wallpaper out once
over the notch strip and the built-in display together, the way macOS lays out
a full-screen app that uses the notch area: the strip shows the top rows and
the built-in display the rest, so the image runs through behind the bar.

The built-in display is the output with the NOTCH output's x and width that
sits either at the NOTCH output's own place (it overlaps the display's top
edge: Parallels, UTM, Fusion) or right below it (OmacVM.app puts NOTCH right
above the display, where the strip is on the Mac; notchcast/notch-place.h).
v5 only knew the first place, so under OmacVM.app every output drew its own
copy again: the display's centred for itself, the strip a zoomed crop of the
image's middle. Without a NOTCH output every screen draws the wallpaper
exactly as before.

The patch also remaps the wallpaper when its output moves: Hyprland leaves a
mapped layer surface at the output's old place (the display then shows only
Hyprland's own dark grey), and Omarchy's ScreenMoveRemap, meant for that,
waits for xChanged/yChanged, which Quickshell's screens do not have (only
geometryChanged), so it never fires.

The wallpaper is also decoded at the size it is shown at (the display's pixels),
not at the image's own: Omarchy's 6016x3384 images made an 81 MB texture per
display, and on a QEMU that limits a buffer's memory entries (UTM's; OmacVM.app
before 2.8.0) such an upload in fragmented memory failed and the shell lost its
GPU context: black displays without bar. At the display's size this stays under
that limit (16384 entries) up to about 4K (3840x2160: ~8100 pages); 5K
(~14400 pages) is close to it and 6K (~19900) can still be refused there.

The patch is versioned like the bar patch; an older version is restored from
<Background.qml>.before-notchbar (kept by install.sh) and patched again.
"""
import os
import sys

MARK = "omarchy-notch-bar"
VERSION = 6
VERSION_LINE = f"// omarchy-notch-bar background patch v{VERSION}"


def replace_once(text, old, new):
    count = text.count(old)
    if count != 1:
        sys.exit(f"apply-patch: expected exactly one match, found {count}:\n{old}")
    return text.replace(old, new)


def main():
    path = sys.argv[1]
    text = open(path).read()
    if VERSION_LINE in text:
        print(f"already patched (v{VERSION})")
        return
    if MARK in text:
        backup = path + ".before-notchbar"
        if not os.path.exists(backup) or MARK in open(backup).read():
            sys.exit(f"apply-patch: {path} carries an older patch and no clean backup exists; "
                     "re-clone the background (omarchy plugin clone omarchy.background) and run install.sh again")
        # Patch the clean copy in memory; the file is only written once the
        # whole patch applied, so a failure leaves the old patch in place.
        text = open(backup).read()
        print("replacing an older patch version")

    # 1. Helpers that pair the NOTCH output with the built-in display.
    text = replace_once(text, '  function imageUrl(path) {\n', f'''  // --- omarchy-notch-bar ------------------------------------------------
  {VERSION_LINE}
  // The wallpaper spans the NOTCH strip and the built-in display as one
  // image; see notchCanvas below.
  function notchIsStrip(s) {{
    return !!s && String(s.name || "").indexOf("NOTCH") === 0
  }}
  // The built-in display under the strip: same x and width, at the strip's
  // own place (over its top edge) or right below it (strip above it). One
  // logical px of slack for fractional scales.
  function notchUnder(strip, o) {{
    if (Math.abs(o.x - strip.x) > 1 || Math.abs(o.width - strip.width) > 1) return false
    return Math.abs(o.y - strip.y) <= 1 || Math.abs(o.y - (strip.y + strip.height)) <= 1
  }}
  function notchPeerOf(s) {{
    if (!s) return null
    var screens = Quickshell.screens
    var strip = notchIsStrip(s)
    for (var i = 0; i < screens.length; i++) {{
      var o = screens[i]
      if (o === s || notchIsStrip(o) === strip) continue
      if (strip ? notchUnder(s, o) : notchUnder(o, s)) return o
    }}
    return null
  }}
  // --- end omarchy-notch-bar --------------------------------------------

  function imageUrl(path) {{
''')

    # 2. On the strip the wallpaper sits on the overlay layer (ordered below the
    #    bar, above notification popups by notchbar.lua): with the bar hidden
    #    it covers the popups' top edge, which would otherwise show in the strip.
    text = replace_once(text, "      WlrLayershell.layer: WlrLayer.Background\n",
                        "      WlrLayershell.layer: root.notchIsStrip(panel.modelData) ? WlrLayer.Overlay : WlrLayer.Background\n")

    # 3. A remap that fires when the output moves (see the docstring).
    text = replace_once(text, "      visible: !remapGuard.remapping\n", """      // omarchy-notch-bar: notchRemap, see below.
      visible: !remapGuard.remapping && !notchRemap.remapping

      // omarchy-notch-bar: remaps the wallpaper when its output really moved
      // (Quickshell's screens only signal geometryChanged, so Omarchy's
      // ScreenMoveRemap never fires). Without it the wallpaper stays at the
      // output's old place and the display shows Hyprland's dark grey.
      Item {
        id: notchRemap
        visible: false
        property bool remapping: false
        property real lastX: NaN
        property real lastY: NaN
        function note() {
          var s = panel.screen
          if (!s || (s.x === lastX && s.y === lastY)) return
          var moved = !isNaN(lastX)
          lastX = s.x
          lastY = s.y
          if (moved) notchRemapSettle.restart()
        }
        Component.onCompleted: note()
        Connections {
          target: panel.screen
          function onGeometryChanged() { notchRemap.note() }
        }
        Timer { id: notchRemapSettle; interval: 200; onTriggered: notchRemap.remapping = true }
        Timer { interval: 100; running: notchRemap.remapping; onTriggered: notchRemap.remapping = false }
      }
""")

    # 4. The shared canvas: the strip on top, the built-in display below it.
    text = replace_once(text, '''      Image {
        id: base
        anchors.fill: parent
''', '''      // omarchy-notch-bar: strip + built-in display as one area. On the
      // strip the canvas extends below the surface, on the built-in display
      // above it; the surface clips the rest.
      Item {
        id: notchCanvas
        readonly property var peer: root.notchPeerOf(panel.modelData)
        readonly property bool strip: root.notchIsStrip(panel.modelData)
        x: 0
        y: peer && !strip ? -peer.height : 0
        width: parent.width
        height: parent.height + (peer ? peer.height : 0)
      }

      Image {
        id: base
        anchors.fill: notchCanvas
''')
    text = replace_once(text, '''        id: oldFrame
        anchors.fill: parent
''', '''        id: oldFrame
        anchors.fill: notchCanvas
''')
    text = replace_once(text, '''        id: incomingLayer
        anchors.fill: parent
''', '''        id: incomingLayer
        anchors.fill: notchCanvas
''')
    text = replace_once(text, '''        id: revealMask
        anchors.fill: parent
''', '''        id: revealMask
        anchors.fill: notchCanvas
''')

    # 5. Decode the image at the size it is shown at (see the docstring); never
    #    0x0, which would mean the image's own size.
    text = replace_once(text, "      property bool maskReady: false\n", """      property bool maskReady: false
      // omarchy-notch-bar: the wallpaper at the size it is shown at.
      readonly property real notchDpr: panel.modelData && panel.modelData.devicePixelRatio > 0
                                       ? panel.modelData.devicePixelRatio : 1
      // In 64 px steps, so small size changes do not decode the image again.
      readonly property size notchImageSize: Qt.size(Math.max(64, Math.ceil(notchCanvas.width * notchDpr / 64) * 64),
                                                     Math.max(64, Math.ceil(notchCanvas.height * notchDpr / 64) * 64))
""")
    # The shown image stays while a new size decodes (no grey flash).
    for image in ("base", "oldFrame"):
        text = replace_once(text, f"        id: {image}\n        anchors.fill: notchCanvas\n",
                            f"        id: {image}\n        anchors.fill: notchCanvas\n"
                            "        sourceSize: panel.notchImageSize\n"
                            "        retainWhileLoading: true\n")
    text = replace_once(text, "          id: incomingFrame\n          anchors.fill: parent\n",
                        "          id: incomingFrame\n          anchors.fill: parent\n"
                        "          sourceSize: panel.notchImageSize\n")

    open(path, "w").write(text)
    print(f"patched (v{VERSION})")


if __name__ == "__main__":
    main()
