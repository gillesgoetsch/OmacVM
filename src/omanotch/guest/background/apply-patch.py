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
edge: the retired VM apps) or right below it (OmacVM.app puts NOTCH right
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
display, and on a QEMU that limits a buffer's memory entries (OmacVM.app
before 2.8.0) such an upload in fragmented memory failed and the shell lost its
GPU context: black displays without bar. At the display's size this stays under
that limit (16384 entries) up to about 4K (3840x2160: ~8100 pages); 5K
(~14400 pages) is close to it and 6K (~19900) can still be refused there.

The theme switch's reveal (a band that widens from the middle) runs on every
output at once. Omarchy starts it on the first output whose new image is
decoded, and an output whose image is ready a moment later sat it out: its
picture only changed when the reveal ended. With the NOTCH output there are
always two (the strip and the built-in display), so the display often skipped
the animation. The patch lets a late output join the running reveal.

Omarchy's Background.qml changed in October 2026: it decodes the wallpaper
at the display's size itself (decodeWidth/decodeHeight, from the image's own
size), draws stills through BackgroundMedia and can be suspended. Where a
step's anchor differs, both forms are known: on the newer one the patch only
makes that decode size the canvas's (strip and display together).

The patch is versioned like the bar patch; an older version, or a file with
the version line but a piece of the patch missing (PIECES, #354), is restored
from <Background.qml>.before-notchbar (kept by install.sh) and patched again.
Without a clean backup it is left as it is and the patch stops.
"""
import os
import sys

MARK = "omarchy-notch-bar"
VERSION = 8
VERSION_LINE = f"// omarchy-notch-bar background patch v{VERSION}"


# One line each step below leaves in the file and no stock Background.qml has.
# All of them must be there for a file with VERSION_LINE to count as patched.
# A tuple: one of its lines, for a step that differs between Omarchy's forms.
DECODED = "      readonly property int decodeWidth: sized ? Math.ceil(notchCanvas.width * "  # 5., newer form
PIECES = [
    "  function notchPeerOf(s) {\n",                                             # 1. pairing helpers
    "      WlrLayershell.layer: root.notchIsStrip(panel.modelData) ? WlrLayer.Overlay : WlrLayer.Background\n",  # 2.
    " && !notchRemap.remapping\n",                                                # 3. remap
    "        id: notchCanvas\n",                                                  # 4. shared canvas, 5. decode size
    ("        id: base\n        anchors.fill: notchCanvas\n        sourceSize: panel.notchImageSize\n        retainWhileLoading: true\n",
     "        id: base\n        anchors.fill: notchCanvas\n        path: "),
    ("        id: oldFrame\n        anchors.fill: notchCanvas\n        sourceSize: panel.notchImageSize\n        retainWhileLoading: true\n",
     DECODED),
    "        id: incomingLayer\n        anchors.fill: notchCanvas\n",
    "        id: revealMask\n        anchors.fill: notchCanvas\n",
    ("      readonly property size notchImageSize: ", DECODED),
    ("          id: incomingFrame\n          anchors.fill: parent\n          sourceSize: panel.notchImageSize\n",
     "      readonly property int decodeHeight: sized ? Math.ceil(notchCanvas.height * "),
    "      // omarchy-notch-bar: a late output joins a running reveal.\n",        # 6. late outputs
]


def missing_pieces(text):
    """The PIECES not in text (each may appear more than once)."""
    return [p for p in PIECES if not any(text.count(q) for q in (p if isinstance(p, tuple) else (p,)))]


def replace_once(text, old, new):
    count = text.count(old)
    if count != 1:
        sys.exit(f"apply-patch: expected exactly one match, found {count}:\n{old}")
    return text.replace(old, new)


def find_variant(text, olds, what):
    """The index of the one form in olds that text has, exactly once."""
    found = [i for i, old in enumerate(olds) if text.count(old) == 1]
    if len(found) != 1 or any(text.count(old) > 1 for old in olds):
        sys.exit(f"apply-patch: could not find {what} (Omarchy changed it?)")
    return found[0]


def replace_variant(text, variants, what):
    """Replace the one (old, new) of variants whose old text has, exactly once."""
    i = find_variant(text, [old for old, _ in variants], what)
    return text.replace(variants[i][0], variants[i][1])


def main():
    path = sys.argv[1]
    text = open(path).read()
    if VERSION_LINE in text and not missing_pieces(text):
        print(f"already patched (v{VERSION})")
        return
    if MARK in text:
        backup = path + ".before-notchbar"
        if not os.path.exists(backup) or MARK in open(backup).read():
            sys.exit(f"apply-patch: {path} carries an incomplete or older patch and no clean backup exists; "
                     "re-clone the background (omarchy plugin clone omarchy.background) and run install.sh again")
        # Patch the clean copy in memory; the file is only written once the
        # whole patch applied, so a failure leaves the old patch in place.
        text = open(backup).read()
        print("replacing an incomplete or older patch")

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
    #    Omarchy's own condition stays (from about October 2026 also
    #    suspended), with the remap added.
    stock_visible = ["!remapGuard.remapping", "!remapGuard.remapping && !root.suspended"]
    text = replace_variant(text, [(f"      visible: {v}\n", """      // omarchy-notch-bar: notchRemap, see below.
      visible: VISIBLE && !notchRemap.remapping

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
""".replace("VISIBLE", v)) for v in stock_visible], "the wallpaper's visible line")

    # 4. The shared canvas: the strip on top, the built-in display below it.
    #    The wallpaper is an Image, from about October 2026 Omarchy's
    #    BackgroundMedia (stills; a video is another program's layer).
    text = replace_variant(text, [(f'''      {kind} {{
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

      KIND {
        id: base
        anchors.fill: notchCanvas
'''.replace("KIND", kind)) for kind in ("Image", "BackgroundMedia")], "the wallpaper's image")
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
    #    0x0, which would mean the image's own size. Omarchy from about
    #    October 2026 does that itself, at the display's size: there it
    #    becomes the canvas's.
    stock_decode = '''      readonly property int decodeWidth: sized ? Math.ceil(width * screen.devicePixelRatio) : 0
      readonly property int decodeHeight: sized ? Math.ceil(height * screen.devicePixelRatio) : 0
'''
    if text.count(stock_decode) == 1:
        text = text.replace(stock_decode, "      // omarchy-notch-bar: the canvas's size (strip and display together).\n" +
                            stock_decode.replace("(width *", "(notchCanvas.width *").replace("(height *", "(notchCanvas.height *"))
    else:
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

    # 6. An output whose new image is ready while the reveal runs joins it
    #    (see the docstring): only a finished reveal is too late.
    if text.count("root.revealProgress !== 0 || maskReady") != 2:
        sys.exit("apply-patch: expected the reveal check twice in maybeStartReveal")
    text = text.replace("root.revealProgress !== 0 || maskReady", "root.revealProgress >= 1 || maskReady")
    text = replace_once(text, "      function maybeStartReveal() {\n",
                        "      // omarchy-notch-bar: a late output joins a running reveal.\n"
                        "      function maybeStartReveal() {\n")

    open(path, "w").write(text)
    print(f"patched (v{VERSION})")


if __name__ == "__main__":
    main()
