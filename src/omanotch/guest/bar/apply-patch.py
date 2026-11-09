#!/usr/bin/env python3
"""Patch a clone of Omarchy's bar (Bar.qml) for Omanotch.

usage: apply-patch.py <Bar.qml>        (patches the file in place)

The patch is versioned. A file carrying the current version and every piece
of the patch (PIECES) only gets the older-Omarchy compatibility fix (see
COMPAT) if it is still missing; a file patched by an older version, or one
with the version line but a piece missing (another patcher's work under the
same line, #354), is restored from its unpatched backup
(<Bar.qml>.before-notchbar, kept by install.sh) and patched again. Without a
clean backup it is left as it is and the patch stops.

What the patch adds:
  * A copy of the bar on any output whose name starts with NOTCH (the hidden
    output that feeds the macOS notch helper) lays out its centre widgets
    around the camera housing.
  * While the helper reports that the notch strip is showing ("parked"), the
    bar on the built-in display (Virtual-1 by default) is parked: it stays
    mapped just past the screen edge, reserves no space and uses the same
    notch layout as the NOTCH copy. The helper's clicks are pressed on this
    parked copy, so panels open on the visible display under the strip.
  * IPC target "notchbar" for the helper, and a watchdog that unparks the bar
    when the helper stops sending heartbeats.
  * The bar is remapped when its output moves (Omarchy's own remap never
    fires on Quickshell; see notchRemap), so it does not stay behind at the
    output's old place.
  * notchcast's last word on parking (~/.local/state/omanotch/park), read at
    startup and every few seconds: a shell that (re)starts while the strip
    shows parks at once, and a lost IPC call cannot leave two bars.
  * The right bar from the first frame after login: when the strip showed at
    the end of the last session (~/.local/state/omanotch/expect), the bar
    starts parked, with the notch geometry it had then (geom), and only
    comes back if Omanotch does not confirm within a few seconds.
  * FullPanel (OmacVM.app, experimental, #339): when the app's full screen
    covers the strip itself (/run/omacvm/host.env: OMACVM_FULLPANEL, the
    camera housing in Mac points), the bar on the built-in display sits in
    the strip, as tall as it, split around the housing, and reserves it
    less 5 px of Omarchy's top window gap, all of the gap when it is under 5
    (#758: windows keep the rest of the gap below the strip, not in it; the
    whole strip while a workspace with a smaller top gap shows, such as
    Omarchy's drop-down console; a gap set with hyprctl eval alone is seen
    at the next shell start or config reload; black over full-screen
    windows). Hidden
    (Super+Shift+Space), it still reserves the strip but is see-through, so
    Omarchy's wallpaper shows there up to the top edge. Only while the app
    says that output covers the whole display in full screen
    ($XDG_RUNTIME_DIR/omacvm/displays.json); else the bar is the normal one.
    notchcast does not run in such a boot.
  * Toasts on the display with the parked bar keep only the normal gap, not
    a bar's room; with FullPanel's bar they keep the strip's height and the
    gap (barSizeFor, which Omarchy's notifications ask from about October
    2026; older ones get guest/omanotch-notifications.sh).
  * Omarchy's tray in the strip (#662): its icons take the helper's clicks
    and scrolls as their own mouse area does (they are no click targets),
    and a left click on the drawer's chevron opens or closes the drawer on
    both bars of the strip (it opens on hover, which the strip does not pass
    on); it closes when the pointer leaves the strip or the strip goes.
    Omarchy 4.5's tray grows as its drawer slides open: Skip the notch
    places it by its width with the drawer open, so the drawer opens in
    place, clear of the housing, and the tray does not move while it slides.
  * Skip the notch shows an item where it stays (#757): 4.5's lists count
    the size each item asks for (implicitWidth; its laid-out width comes
    from a polish the items force while the list is still counting, and
    QML dropped that update as a binding loop); an item whose own size
    changed takes its new place at once (only items pushed by others
    glide); an item that shows up (it had no width, as the tray before its
    first app) waits unseen until its own place has been quiet for 150 ms
    (1 s at most).
  * Omarchy 4.5's indicators (#763, #764): their hidden ones also open
    while the pointer is on the indicators' own place or where Skip the
    notch opens the hidden ones left of the housing, and stay while it is
    there, whatever their own hover says; the stretch between those two
    places (the housing and the widgets there) only keeps them open on the
    way from one to the other, it never opens them, and left of the hidden
    ones they shut. Omarchy's rule (the bar left of the centre box) counts
    only in Omarchy's own layout (they sit inside that stretch and Skip the
    notch did not move their hidden ones), and only left of the housing:
    nothing opens under the camera housing.
    Only this copy of the bar: Omarchy's own bar keeps its rule.

Omarchy's Bar.qml changed in October 2026 (upstream's notch floor from
display-cutouts.json, a bar thickness per screen, the centre's hover area):
where a step's anchor differs, both forms are known (replace_variant), so
the patch fits omarchy-mac's bar as well as upstream's.

Omarchy 4.5 (November 2026, is_45) rebuilt the bar: each bar surface spans
its screen with the strip at its edge, widgets live in a pool per surface
and are lent to the slot of their section, the lists are GridLayouts, and
the centre is three sections (centerBegin, the center box, centerEnd). The
same pieces go in there: a notch role's window is its strip, the centre
sections lie around the camera housing (centerBegin ends left of it, the
box and centerEnd start right of it, as the centre did before), and the
peek follows 4.5's own rule (left of the centre box) where the indicators
sit inside that stretch, unmoved, else their own places (step 10).
"""
import os
import sys

MARK = "omarchy-notch-bar"
VERSION = 42
VERSION_LINE = f"// omarchy-notch-bar patch v{VERSION}"


# One line each step below leaves in the file and no stock Bar.qml has. All
# of them must be there for a file with VERSION_LINE to count as patched:
# COMMON in every form, then those of Omarchy 4.0's bar (PIECES) or 4.5's
# (PIECES_45).
COMMON = [
    "  function notchRoleFor(s) {\n",                                       # 1. state and roles
    '    target: "notchbar"\n',                                              # 2. IPC and watchdog
    "    readonly property string notchRole: root.notchRoleFor(screen)\n",  # 3. parking per window
    '      top: barWindow.parked && root.position === "top" ? -barWindow.parkedSize : 0\n',
    '    implicitHeight: root.vertical ? 0 : (barWindow.notchRole === "" ? ',
    "      anchors.topMargin: barWindow.notchPadTop\n",
    "notchLayout: barWindow.notchLayout",                                    # 4. layout mode
    "    property bool notchLayout: false\n",                                # 5. around the housing
    "    WlrLayershell.layer: barWindow.notchRole === \"notch\" || ",        # 6. layer, repaint, black strip
    "    // FullPanel's bar the whole strip (its parkedSize).\n",  # 7. toasts
    "  function notchSkipPlace(width, pad, left, right, housing, beside, edge, gap, keep, prev, stick) {\n",  # 1.
    "        readonly property bool notchSkipActive: root.notchSkipOn && barWindow.notchLayout\n",  # 4.
    "    transform: Translate { x: slot.notchShift ? slot.notchShownX - (slot.notchEnd ? slot.width : 0) - slot.notchPlaceX : 0 }\n",  # 9. items
    "  function notchPeekBlockIn(item, depth) {\n",                       # 1. the indicators' hidden ones
    "    Translate { id: notchPeekMove; x: slot.notchPeekDx }\n",           # 9. open left of the housing
    "      if (parent && typeof parent.forceLayout === \"function\") parent.forceLayout()\n",  # 9. row now
    "    z: modulePointer.dragging ? 100 : (slot.notchShift && slot.notchShift.peekAt !== undefined ? -1 : 0)\n",
    "        function notchSkipKeep() {\n",                                  # 4. decisions stick
    "            notchShown: moduleListRoot.notchShown\n",                     # 8. glide on after a rebuild
    "  function notchPeekActiveIn(area) {\n",                               # 1. their width at rest
    "    function notchSettle() {\n",                                         # 9. one glide per change
    "    property bool notchHold: false\n",                                  # 8. a list made again
    "  function notchTraySpans(onNotch) {\n",                                # 1. Omarchy's tray (#662)
    "  function notchParkedX(x) {\n",                                        # 1. clicks to the item's twin
    "    function onNotchParkedChanged() { root.notchTraySet(false, \"\", \"\") }\n",  # 2. its drawer closes
    "      function notchParkEnd() {\n",                                    # 3. mapped again after the park (#727)
    "    property bool notchAppearing: false\n",                              # 9. shows up where it stays (#757)
    "      id: notchShowLimit\n",                                             # 9. ... 1 s at most
    "  function notchPanelZoneFor(size, gapsTop) {\n",                         # 1. FullPanel's zone (#758)
    "    readonly property int notchPanelZone: root.notchPanelZoneFor(notchPanelFit[0], root.notchGapsAt(screen ? screen.name : \"\", root.notchGapsSure, root.notchGapsSeen, root.notchSpecials, root.notchFlush))\n",  # 3.
    "  function notchGapsFor(output, state, specials, flush) {\n",             # 1. ... a workspace rule's gap (#758)
    "    id: notchGapRulesProc\n",                                             # 1.
    "    id: notchFlushBarFile\n",                                             # 1. ... flush-bar
    "  readonly property bool notchFlush: notchFlushBar && requestedTransparent && position === \"top\"\n",  # 1.
]
PIECES = COMMON + [
    "      when: barWindow.notchRole === \"fullpanel\" && !barWindow.parked; restoreMode: Binding.RestoreNone\n",  # 3. #758
    "        Item { id: notchLeftEdge; ",                                     # 5. around the housing
    "    property var notchBeside: [0, 0]\n",                                # 5.
    "            notchShift: root.notchShiftAt(moduleListRoot.notchShift, index)\n",  # 8. lists
]
PIECES_45 = COMMON + [
    '      height: root.vertical ? parent.height : (barWindow.notchRole === "" ? barWindow.thickness : parent.height)\n',  # 3.
    "      : barWindow.notchRole === \"fullpanel\" ? barWindow.notchPanelZone : barWindow.parkedSize\n",  # 3. #758
    "    readonly property var notchBeside: notchSections.notchBeside\n",      # 5. around the housing
    "(sections.notchLayout ? root.notchRight + Style.space(6) : ",           # 5.
    "            notchSlotIndex: moduleListRoot.keys.indexOf(modelData.key)\n",  # 8. lists
    "    readonly property real notchRest: {\n",                              # 8.
    "          : more > 0 ? [w, w + more] : w\n",                              # 8. a tray counts open
    "      ? [beginList.notchRest, centerBox.notchRest + endList.notchRest, beginList.notchPeekMore] : [0, 0]\n",  # 5. the peek's room
    "    readonly property real notchRest: boxList.notchRest\n",              # 5. the centre at rest
    "hovered && root.notchPeeksAt(barWindow, parent, point.position, ",       # 10. the peek where the indicators are
    "    function onCenterSectionRevealHeldChanged() { Qt.callLater(root.notchPeekHeldTick) }\n",  # 10. ... held open
    "    onNotchPeekPlaceChanged: if (notchPeekBlock) Qt.callLater(root.notchIndicatorTick)\n",  # 10.
]


def is_45(text):
    """Omarchy 4.5's bar: widgets in a pool per bar surface (WidgetPool)."""
    return "  component WidgetPool: Item {\n" in text


def missing_pieces(text):
    """The pieces of text's form not in it (each may appear more than once)."""
    return [p for p in (PIECES_45 if is_45(text) else PIECES) if text.count(p) < 1]


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
    """Replace the one (old, new) of variants whose old text has, exactly once.

    Omarchy's bar changed over time: each variant is one form a step's
    anchor had."""
    i = find_variant(text, [old for old, _ in variants], what)
    return text.replace(variants[i][0], variants[i][1])


# Omarchy builds up to about September 2026 declare these bar properties as
# `required`. The shell loads a cloned bar by URL and can only set them after
# creation, so such a clone fails to load (and the shell's fallback to the
# stock bar breaks too). Newer builds give them defaults; do the same here.
COMPAT = [
    ("  required property string omarchyPath\n", '  property string omarchyPath: Quickshell.env("OMARCHY_PATH")\n'),
    ("  required property var barWidgetRegistry\n", "  property var barWidgetRegistry: null\n"),
    ("  required property var barConfig\n", "  property var barConfig: ({})\n"),
]


def compat(text):
    for old, new in COMPAT:
        text = text.replace(old, new)
    return text


def centre_40(text):
    """Step 5 on Omarchy 4.0's bar: its centre (one list, or an anchor widget
    with a list before and after it) lies around the camera housing."""
    text = replace_once(text, '''    property var entries: root.layoutEntries("center")
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1''', '''    property var entries: root.layoutEntries("center")
    // omarchy-notch-bar: keep the camera housing free.
    property bool notchLayout: false
    // How wide the centre widgets beside the housing are [left of it, right
    // of it] in the horizontal bar, for Skip the notch.
    property var notchBeside: [0, 0]
    readonly property bool hasAnchor: root.entryIndex(entries, root.centerAnchor) !== -1''')
    # Omarchy's hover area above these (a HoverHandler, from about October
    # 2026 an Item up to the anchor widget) stays as it is.
    text = replace_once(text, '''        ModuleList {
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: parent
        }

        ModuleList {
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: parent
        }
''', '''        // omarchy-notch-bar: edges of the camera housing plus a small gap.
        Item { id: notchLeftEdge; x: root.notchLeft - Style.space(6); width: 0; height: parent.height }
        Item { id: notchRightEdge; x: root.notchRight + Style.space(6); width: 0; height: parent.height }
        Binding {
          target: centerRoot
          property: "notchBeside"
          value: centerRoot.hasAnchor
            ? [notchCentreBefore.width, centerAnchorModule.width + notchCentreAfter.width]
            : [0, notchCentreAll.width]
        }

        ModuleList {
          id: notchCentreAll
          visible: !centerRoot.hasAnchor
          entries: centerRoot.entries
          region: "center"
          anchors.centerIn: centerRoot.notchLayout ? undefined : parent
          anchors.left: centerRoot.notchLayout ? notchRightEdge.left : undefined
          anchors.verticalCenter: centerRoot.notchLayout ? parent.verticalCenter : undefined
        }

        ModuleList {
          id: notchCentreBefore
          visible: centerRoot.hasAnchor
          entries: root.entriesBefore(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.right: centerRoot.notchLayout ? notchLeftEdge.left : centerAnchorModule.left
          anchors.verticalCenter: centerAnchorModule.verticalCenter
        }

        ModuleSlot {
          id: centerAnchorModule
          visible: centerRoot.hasAnchor
          entry: centerRoot.anchorEntry
          region: "center"
          anchors.centerIn: centerRoot.notchLayout ? undefined : parent
          anchors.left: centerRoot.notchLayout ? notchRightEdge.left : undefined
          anchors.verticalCenter: centerRoot.notchLayout ? parent.verticalCenter : undefined
        }
''')
    # The list after the anchor widget follows it, as before.
    text = replace_once(text, '''          entries: root.entriesAfter(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.left: centerAnchorModule.right
''', '''          id: notchCentreAfter
          entries: root.entriesAfter(centerRoot.entries, root.centerAnchor)
          region: "center"
          anchors.left: centerAnchorModule.right
''')
    return text


def lists_40(text):
    """Step 8 on Omarchy 4.0's bar: a list is a Loader with a Row of slots."""
    text = replace_once(text, '''  component ModuleList: Loader {
    id: moduleListRoot

    property var entries: []
    property string region: ""
''', '''  component ModuleList: Loader {
    id: moduleListRoot

    property var entries: []
    property string region: ""
    // omarchy-notch-bar: Skip the notch: {items: [{x, hidden}], animate} on
    // a bar in the notch strip, null elsewhere; and the items' widths, left
    // to right (a horizontal list).
    property var notchShift: null
    readonly property var notchWidths: item && item.notchWidths ? item.notchWidths : []
    // Where each module showed last on this bar: Omarchy makes the whole list
    // again when a module comes or goes, and the new items glide on from there.
    property var notchShown: ({})
    // Making the list again takes a few rounds (the widgets come one by one),
    // and the layout passes through places that are not the end. Meanwhile
    // (until it has not changed for 150 ms) the items stay where they showed
    // and new ones wait unseen; then each glides once to its place.
    property bool notchHold: false
    onEntriesChanged: if (notchShift && notchShift.animate) { notchHold = true; notchHoldEnd.restart() }
    onNotchShiftChanged: if (notchHold) notchHoldEnd.restart()
    Timer { id: notchHoldEnd; interval: 150; onTriggered: moduleListRoot.notchHold = false }
''')
    text = replace_once(text, '''      Row {
        spacing: 0

        Repeater {
          model: moduleListRoot.entries

          ModuleSlot {
            required property var modelData
            entry: modelData
            region: moduleListRoot.region
          }
        }
      }
''', '''      Row {
        spacing: 0
        // omarchy-notch-bar: each item's width by its place in the list; the
        // right list's indicators as [now, at rest, their hidden ones].
        readonly property var notchWidths: {
          var out = []
          for (var i = 0; i < children.length; i++) {
            var c = children[i]
            if (!c || !(c.notchSlotIndex >= 0)) continue
            out[c.notchSlotIndex] = moduleListRoot.region === "right" && c.notchPeekFull > 0
              ? [c.width, c.notchPeekRest, c.notchPeekFull] : c.width
          }
          for (var j = 0; j < out.length; j++) if (out[j] === undefined) out[j] = 0
          return out
        }

        Repeater {
          model: moduleListRoot.entries

          ModuleSlot {
            required property var modelData
            required property int index
            entry: modelData
            region: moduleListRoot.region
            notchSlotIndex: index
            notchShift: root.notchShiftAt(moduleListRoot.notchShift, index)
            notchShown: moduleListRoot.notchShown
            notchHold: moduleListRoot.notchHold
          }
        }
      }
''')
    return text


def centre_45(text):
    """Step 5 on Omarchy 4.5's bar: its three centre sections lie around the
    camera housing, as the centre did on 4.0: centerBegin ends left of it, the
    center box and centerEnd start right of it, a small gap away. 4.5 has a
    notch layout of its own (centerBesideRight, from display-cutouts.json:
    the sections beside the right one), which a VM's displays never get; this
    one keeps the strip as it looked on 4.0 and leaves the right side's room
    to the right section."""
    text = replace_once(text, '''    // False where a display notch has moved the center sections beside the
    // right one.
    property bool drawn: true

    CenterGestureArea { anchors.fill: parent }

    CenterSections {
      anchors.fill: parent
      window: centerRoot.window
      pool: centerRoot.pool
      active: centerRoot.drawn
    }
''', '''    // False where a display notch has moved the center sections beside the
    // right one.
    property bool drawn: true
    // omarchy-notch-bar: keep the camera housing free, and how wide the
    // sections beside it are at rest [left of it, right of it], for Skip the
    // notch.
    property bool notchLayout: false
    readonly property var notchBeside: notchSections.notchBeside

    CenterGestureArea { anchors.fill: parent }

    CenterSections {
      id: notchSections
      anchors.fill: parent
      window: centerRoot.window
      pool: centerRoot.pool
      active: centerRoot.drawn
      notchLayout: centerRoot.notchLayout
    }
''')
    text = replace_once(text, '''    property bool besideRight: false
''', '''    property bool besideRight: false
    // omarchy-notch-bar: around the camera housing (bar coordinates: the
    // sections fill the bar). The indicators' hidden ones count at rest, and
    // a tray in the centre with its drawer open; the third number is the
    // room they open into on a peek, left of the housing (Omarchy's peek
    // widens centerBegin towards the bar's start).
    property bool notchLayout: false
    readonly property var notchBeside: notchLayout && active
      ? [beginList.notchRest, centerBox.notchRest + endList.notchRest, beginList.notchPeekMore] : [0, 0]
''')
    text = replace_once(text, '''    readonly property real extent: root.vertical ? boxList.height : boxList.width
''', '''    readonly property real extent: root.vertical ? boxList.height : boxList.width
    // omarchy-notch-bar: its width at rest for Skip the notch, a tray in it
    // counted open (its width grows while the drawer slides open).
    readonly property real notchRest: boxList.notchRest
''')
    text = replace_once(text, '''      x: root.vertical ? Math.round((sections.width - width) / 2) : centerBox.x - width
''', '''      x: root.vertical ? Math.round((sections.width - width) / 2)
        : (sections.notchLayout ? root.notchLeft - Style.space(6) - width : centerBox.x - width)
''')
    text = replace_once(text, '''      fixedEdge: sections.besideRight ? "end" : "center"
      crossSize: root.vertical ? sections.width : sections.height
      x: root.vertical ? 0 : (sections.besideRight ? beginList.width : Math.round((sections.width - width) / 2))
''', '''      fixedEdge: sections.notchLayout ? "start" : sections.besideRight ? "end" : "center"
      crossSize: root.vertical ? sections.width : sections.height
      x: root.vertical ? 0 : (sections.notchLayout ? root.notchRight + Style.space(6) : sections.besideRight ? beginList.width : Math.round((sections.width - width) / 2))
''')
    return text


def lists_45(text):
    """Step 8 on Omarchy 4.5's bar: a list is a GridLayout of slots (and a
    drag's spacers), each slot named by its widget's key."""
    text = replace_once(text, '''  component ModuleList: GridLayout {
    id: moduleListRoot

    // The widgets the list shows, by their keys (root.layoutWidgets).
    property var keys: []
    property string region: ""
''', '''  component ModuleList: GridLayout {
    id: moduleListRoot

    // The widgets the list shows, by their keys (root.layoutWidgets).
    property var keys: []
    property string region: ""
    // omarchy-notch-bar: Skip the notch: {items: [{x, hidden}], animate} on
    // a bar in the notch strip, null elsewhere; the items' widths by their
    // place in the list (Omarchy's indicators as [now, at rest, their hidden
    // ones]; Omarchy's tray as [now, with its drawer open]: it grows as the
    // drawer slides open, so where it goes is decided by that width, and it
    // opens in place and never moves from under the pointer), and the list's
    // width at rest.
    // Each by the size the slot asks for (implicitWidth, from bindings), not
    // its laid-out width: the layout sets that in its polish, which the slots
    // force (ensurePolished) while this is still being counted, and QML drops
    // such an update as a binding loop (#757).
    property var notchShift: null
    readonly property var notchWidths: {
      var out = []
      for (var i = 0; i < children.length; i++) {
        var c = children[i]
        if (!c || !(c.notchSlotIndex >= 0)) continue
        var t = c.activeItem, more = t && root.notchIsTray(t) ? Number(t.drawerExtent) - Number(t.revealExtent) : 0
        var w = c.implicitWidth
        out[c.notchSlotIndex] = c.notchPeekFull > 0 ? [w, c.notchPeekRest, c.notchPeekFull]
          : more > 0 ? [w, w + more] : w
      }
      for (var j = 0; j < out.length; j++) if (out[j] === undefined) out[j] = 0
      return out
    }
    readonly property real notchRest: {
      var w = 0
      for (var i = 0; i < notchWidths.length; i++)
        w += Array.isArray(notchWidths[i]) ? notchWidths[i][1] : notchWidths[i]
      return w
    }
    // How much wider the indicators' peek makes the list (their hidden ones).
    readonly property real notchPeekMore: {
      var w = 0
      for (var i = 0; i < notchWidths.length; i++)
        if (Array.isArray(notchWidths[i]) && notchWidths[i].length > 2) w += notchWidths[i][2]
      return w
    }
    // Where each module showed last on this bar: Omarchy makes the list's
    // slots again when a module comes or goes, and the new ones glide on from there.
    property var notchShown: ({})
    // Making the list again takes a few rounds, and the layout passes through
    // places that are not the end. Meanwhile (until it has not changed for
    // 150 ms) the items stay where they showed and new ones wait unseen; then
    // each glides once to its place.
    property bool notchHold: false
    onKeysChanged: if (notchShift && notchShift.animate) { notchHold = true; notchHoldEnd.restart() }
    onNotchShiftChanged: if (notchHold) notchHoldEnd.restart()
    Timer { id: notchHoldEnd; interval: 150; onTriggered: moduleListRoot.notchHold = false }
''')
    text = replace_once(text, '''          ModuleSlot {
            required property var modelData
            widgetKey: modelData.key
            region: moduleListRoot.region
''', '''          ModuleSlot {
            required property var modelData
            widgetKey: modelData.key
            region: moduleListRoot.region
            notchSlotIndex: moduleListRoot.keys.indexOf(modelData.key)
            notchShift: root.notchShiftAt(moduleListRoot.notchShift, notchSlotIndex)
            notchShown: moduleListRoot.notchShown
            notchHold: moduleListRoot.notchHold
''')
    return text


def peek_45(text):
    """Step 10 on Omarchy 4.5's bar: the bar's hover handler peeks where the
    indicators are (root.notchPeeksAt; point.position and the indicators'
    place both in the handler's item), from root.notchIndicatorSpans, which
    their slot refreshes after it moved and the handler when the pointer
    comes onto the bar (after step 9, in the slot's body), and from
    root.notchPeekHeld, a copy of centerSectionRevealHeld set once its change
    is done (the handler's own answer changes centerSectionRevealHeld)."""
    text = replace_once(text, '''  property bool centerSectionRevealHeld: false
''', '''  property bool centerSectionRevealHeld: false
  // omarchy-notch-bar: centerSectionRevealHeld as it was once its last change
  // was done, for the bar's hover (root.notchPeeksAt): read straight, the
  // hover's own opening would change what it reads while it is being set.
  // A Connections, so a handler of Omarchy's own on root still fits.
  property bool notchPeekHeld: false
  function notchPeekHeldTick() { notchPeekHeld = centerSectionRevealHeld }
  Connections {
    target: root
    function onCenterSectionRevealHeldChanged() { Qt.callLater(root.notchPeekHeldTick) }
  }
''')
    text = replace_once(text, '''          readonly property bool peeking: hovered && BarModel.peeksAt(point.position, barWindow.peekEdge, root.vertical)
''', '''          // omarchy-notch-bar: also over the indicators' places, never under
          // the camera housing (root.notchPeeksAt).
          readonly property bool peeking: hovered && root.notchPeeksAt(barWindow, parent, point.position, BarModel.peeksAt(point.position, barWindow.peekEdge, root.vertical), null, root.notchPeekHeld)
          onHoveredChanged: if (hovered) Qt.callLater(root.notchIndicatorTick)
''')
    text = replace_once(text, '''    onNotchPeekBlockChanged: notchPeekApply()
''', '''    onNotchPeekBlockChanged: { notchPeekApply(); Qt.callLater(root.notchIndicatorTick) }
    // The indicators' place on their bar (their row, Skip the notch's place
    // and peek): when it changes, root.notchIndicatorSpans is read again once
    // this change is done.
    readonly property string notchPeekPlace: {
      if (!notchPeekBlock) return ""
      var a = [width, notchShownX, notchPlaceX, notchShiftGone, notchAppearing, notchPeekFull,
               notchShift ? notchShift.peekAt : "", notchShift ? notchShift.peekHidden : ""]
      for (var p = slot; p && p.parent; p = p.parent) a.push(p.x)
      return a.join(" ")
    }
    onNotchPeekPlaceChanged: if (notchPeekBlock) Qt.callLater(root.notchIndicatorTick)
''')
    return text


def main():
    path = sys.argv[1]
    text = open(path).read()
    if VERSION_LINE in text and not missing_pieces(text):
        fixed = compat(text)
        if fixed != text:
            open(path, "w").write(fixed)
            print(f"patched (v{VERSION}, older-Omarchy compatibility)")
        else:
            print(f"already patched (v{VERSION})")
        return
    if MARK in text:
        backup = path + ".before-notchbar"
        if not os.path.exists(backup) or MARK in open(backup).read():
            sys.exit(f"apply-patch: {path} carries an incomplete or older patch and no clean backup exists; "
                     "re-clone the bar (omarchy plugin clone omarchy.bar) and run install.sh again")
        # Patch the clean copy in memory; the file is only written once the
        # whole patch applied, so a failure leaves the old patch in place.
        text = open(backup).read()
        print("replacing an incomplete or older patch")

    text = compat(text)
    form45 = is_45(text)

    # How far Omarchy parks a hidden bar: its configured size, from about
    # October 2026 its thickness on that screen (a notch floor can make it
    # taller), on 4.5 its window's length (the window spans the screen).
    # Ordinary bars keep that; the notch roles get parkedSize.
    SIZES = ("root.barSize", "barWindow.thickness", "barWindow.parkDistance")
    stock_margins = [
        '''      top: root.barHidden && root.position === "top" ? -{0} : 0
      bottom: root.barHidden && root.position === "bottom" ? -{0} : 0
      left: root.barHidden && root.position === "left" ? -{0} : 0
      right: root.barHidden && root.position === "right" ? -{0} : 0'''.format(size)
        for size in SIZES]
    stock_size = SIZES[find_variant(text, stock_margins, "the bar's margins")]

    # 1. State and role helpers (the version line marks the patch).
    text = replace_once(text, '  property string home: Quickshell.env("HOME")\n', '''  property string home: Quickshell.env("HOME")

  // --- omarchy-notch-bar ------------------------------------------------
  {VERSION_LINE}
  // A hidden output named NOTCH* renders this bar for the macOS notch helper.
  // While the helper shows the strip, the bar on notchParkedScreen is parked
  // (mapped off-screen, no exclusive zone) and takes the helper's clicks, so
  // panels open on the visible display right under the notch strip.
  property bool notchParked: false
  property string notchParkedScreen: "Virtual-1"
  // Camera housing in bar coordinates (logical px == macOS points).
  property real notchLeft: 918
  property real notchRight: 1138
  // Height of the black strip on the Mac (points). The NOTCH copy of the bar
  // is this tall with its content centred, so the strip has no padding the
  // helper would have to fill, and the wallpaper can show through when the
  // bar is hidden. 0 until the helper reports it.
  property real notchHeight: 0
  // Omanotch's flush setting: the NOTCH copy of the bar is only this tall
  // (the camera housing's height) and the wallpaper shows in the rest of the
  // strip below it. 0: the bar fills the strip.
  property real notchBarHeight: 0
  property real notchLastBeat: 0
  // Bumped by the helper's capture program: repaints every bar surface once,
  // so a new capture session gets a frame without waiting for a change.
  property int notchPokeSerial: 0
  // True while a window on the built-in display's active workspace is in
  // real fullscreen (a video, Super+F; not "maximized" or tiled fullscreen).
  // The strip then goes black, as macOS does over full-screen video.
  property bool notchFullscreen: false
  property bool notchFullscreenRecheck: false
  // The NOTCH copy's height and top padding [height, pad] (logical px).
  // The strip shows NOTCH's bottom `strip` px: notchcast rounds NOTCH up to
  // whole pixels at fractional scales and the Mac cuts those extra rows off
  // at the top. So the bar (`size` tall) is centred in that bottom part, or
  // in its top `flush` px when the bar is only the camera housing's height,
  // and the padding is snapped to whole pixels of the output (`scale`).
  function notchBox(outH, strip, flush, size, scale) {
    var full = Math.max(size, Math.round(strip), outH)
    var cut = strip > 0 && strip < full ? full - strip : 0
    var region = flush > 0 ? Math.max(size, Math.min(flush, full - cut)) : full - cut
    var s = scale > 0 ? scale : 1
    var pad = Math.round((cut + (region - size) / 2) * s) / s
    return [flush > 0 ? Math.ceil(cut + region) : full, pad]
  }
  function notchWorkspaceId() {
    var ms = Hyprland.monitors.values
    for (var i = 0; i < ms.length; i++)
      if (ms[i].name === notchParkedScreen && ms[i].activeWorkspace) return ms[i].activeWorkspace.id
    return null
  }
  function notchCheckFullscreen() {
    if (notchFullscreenProc.running) notchFullscreenRecheck = true
    else notchFullscreenProc.running = true
  }
  Process {
    id: notchFullscreenProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      onStreamFinished: {
        var ws = root.notchWorkspaceId(), fs = false
        try {
          var clients = JSON.parse(text)
          for (var i = 0; i < clients.length; i++) {
            var c = clients[i]
            // fullscreen is Hyprland's mode bitmask: 1 maximized, 2 fullscreen.
            if (c.workspace && c.workspace.id === ws && (c.fullscreen & 2)) fs = true
          }
        } catch (e) {}
        root.notchFullscreen = fs
      }
    }
    onExited: if (root.notchFullscreenRecheck) {
      root.notchFullscreenRecheck = false
      running = true
    }
  }
  Timer {
    id: notchFullscreenDebounce
    interval: 50
    running: true  // initial check
    onTriggered: root.notchCheckFullscreen()
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = String(event.name)
      if (n === "fullscreen" || n.indexOf("workspace") === 0 || n.indexOf("focusedmon") === 0 ||
          n === "openwindow" || n === "closewindow" || n.indexOf("movewindow") === 0 ||
          n.indexOf("monitor") === 0)
        notchFullscreenDebounce.restart()
    }
  }
  // FullPanel's bar reserves its strip less 5 px of Omarchy's top window
  // gap (all of the gap when it is under 5; #758): windows sit up to 5 px
  // closer under the notch, and never in the strip (zone + gap >= the
  // strip). The gap is the smallest top gap a window on the bar's output can
  // have now (notchGapsFor): general:gaps_out, and the gaps_out of each
  // workspace rule that sets one. A rule for a special workspace counts
  // while that workspace shows on the output: Omarchy's drop-down console
  // (4.5, special:qconsole) and 4.0's scratchpad have top 0, so the whole
  // strip then. Any other rule (a normal workspace, a selector such as
  // w[tv1]) counts always. Under a transparent top bar with omarchy-mac's
  // flush-bar plugin, which sets that edge's gap to 0, the whole strip at
  // once.
  // Read from Hyprland at start, after a config reload and after the bar's
  // look changes, soon and once more later: a smaller gap counts from the
  // first read, a larger one only from the later read (after a reload
  // Hyprland has its default first, and a script such as flush-bar sets
  // its own value after it). Until read: the whole strip. A gap changed
  // with hyprctl eval or keyword alone sends no event: the bar sees it at
  // its next start (a config reload sets the configured gap again).
  property var notchGapsSure: ({ top: 0, rules: null })  // the last later read
  property var notchGapsSeen: ({ top: 0, rules: null })  // the last read
  // Output name -> the special workspace shown on it ("" none).
  property var notchSpecials: ({})
  property int notchSpecialSerial: 0
  property bool notchFlushBar: false
  // requestedTransparent: the bar's setting, as flush-bar sees it (the bar
  // turns transparent itself only after it picked a text colour).
  readonly property bool notchFlush: notchFlushBar && requestedTransparent && position === "top"
  property var notchGapsPass: null
  property int notchGapsQueued: 0  // a read asked while one runs: 1 soon, 2 later
  // hyprctl -j getoption general:gaps_out -> its top, -1 if unreadable.
  function notchGapsParse(text) {
    try {
      var o = JSON.parse(String(text))
      var parts = String(o.css || o.custom || "").match(/-?[0-9]+(?:\\.[0-9]+)?/g) || []
      var n = parts.length > 0 ? Number(parts[0]) : Number(o.int)
      return isFinite(n) && n >= 0 ? Math.floor(n) : -1
    } catch (e) {
      return -1
    }
  }
  // hyprctl -j workspacerules -> [{name, top}] of the rules that set
  // gaps_out (top first, as CSS), null if unreadable.
  function notchGapRulesParse(text) {
    try {
      var list = JSON.parse(String(text)), out = []
      if (!Array.isArray(list)) return null
      for (var i = 0; i < list.length; i++) {
        var r = list[i] || {}, g = r.gapsOut
        if (g === undefined || g === null) continue
        var top = Number(Array.isArray(g) ? g[0] : typeof g === "object" ? g.top : g)
        if (isFinite(top)) out.push({ name: String(r.workspaceString || ""), top: Math.max(0, Math.floor(top)) })
      }
      return out
    } catch (e) {
      return null
    }
  }
  // hyprctl -j monitors -> {output: the special workspace shown on it, or
  // ""}, null if unreadable (by name: Hyprland 0.57 gives no id for none).
  function notchSpecialsParse(text) {
    try {
      var list = JSON.parse(String(text)), out = {}
      if (!Array.isArray(list)) return null
      for (var i = 0; i < list.length; i++) {
        var s = list[i].specialWorkspace
        out[String(list[i].name)] = s && s.name ? String(s.name) : ""
      }
      return out
    } catch (e) {
      return null
    }
  }
  // Hyprland's activespecial event ("NAME,OUTPUT", NAME empty when it hides)
  // -> the map with that output's entry changed.
  function notchSpecialEvent(specials, data) {
    var s = String(data), i = s.lastIndexOf(","), out = {}
    for (var k in specials) out[k] = specials[k]
    if (i >= 0) out[s.slice(i + 1)] = s.slice(0, i)
    return out
  }
  function notchGapsFor(output, state, specials, flush) {
    if (flush) return 0
    var g = state.top, shown = specials[output] || "", rules = state.rules
    if (rules === null) return shown !== "" ? 0 : g
    for (var i = 0; i < rules.length; i++) {
      if (rules[i].name.indexOf("special:") !== 0 || rules[i].name === shown) g = Math.min(g, rules[i].top)
    }
    return g
  }
  function notchGapsAt(output, sure, seen, specials, flush) {
    return Math.min(notchGapsFor(output, sure, specials, flush), notchGapsFor(output, seen, specials, flush))
  }
  function notchPanelZoneFor(size, gapsTop) {
    return Math.max(0, size - Math.min(5, Math.max(0, gapsTop)))
  }
  // A read's result -> [sure, seen]: a later read sets both; an unreadable
  // gap keeps the last one seen.
  function notchGapsMerge(sure, seen, pass) {
    var now = { top: pass.top >= 0 ? pass.top : seen.top, rules: pass.rules }
    return [pass.late ? now : sure, now]
  }
  function notchReadGaps(late) {
    if (notchGapsPass !== null) {
      notchGapsQueued = Math.max(notchGapsQueued, late ? 2 : 1)
      return
    }
    notchGapsPass = { late: late, top: -1, rules: null, specials: null, serial: notchSpecialSerial, left: 3 }
    notchGapsGuard.restart()
    notchGapsProc.running = true
    notchGapRulesProc.running = true
    notchSpecialsProc.running = true
  }
  function notchGapsGot(key, value) {
    var p = notchGapsPass
    if (p === null) return
    p[key] = value
    if (--p.left <= 0) notchGapsCommit()
  }
  function notchGapsCommit() {
    var p = notchGapsPass
    if (p === null) return
    notchGapsPass = null
    notchGapsGuard.stop()
    if (p.specials !== null && p.serial === notchSpecialSerial) notchSpecials = p.specials
    var m = notchGapsMerge(notchGapsSure, notchGapsSeen, p)
    notchGapsSure = m[0]
    notchGapsSeen = m[1]
    if (notchGapsQueued > 0) notchGapsRetry.restart()
  }
  function notchGapsCheck(later) {
    notchReadGaps(false)
    notchGapsSoon.restart()
    notchGapsLate.interval = later
    notchGapsLate.restart()
  }
  Process {
    id: notchGapsProc
    command: ["hyprctl", "-j", "getoption", "general:gaps_out"]
    stdout: StdioCollector { onStreamFinished: root.notchGapsGot("top", root.notchGapsParse(text)) }
  }
  Process {
    id: notchGapRulesProc
    command: ["hyprctl", "-j", "workspacerules"]
    stdout: StdioCollector { onStreamFinished: root.notchGapsGot("rules", root.notchGapRulesParse(text)) }
  }
  Process {
    id: notchSpecialsProc
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector { onStreamFinished: root.notchGapsGot("specials", root.notchSpecialsParse(text)) }
  }
  // A read at once (a smaller gap then counts within a frame or two) and
  // again 200 ms on: Hyprland's options can settle a moment after its
  // reload event (Style.qml waits 200 ms). The later read: at start after
  // flush-bar's last startup pass (6 x 0.5 s), else 1.5 s on.
  Timer { id: notchGapsSoon; interval: 200; running: true; onTriggered: root.notchReadGaps(false) }
  Timer { id: notchGapsLate; interval: 3500; running: true; onTriggered: root.notchReadGaps(true) }
  // A read whose hyprctl never answers ends with what it has.
  Timer { id: notchGapsGuard; interval: 2000; onTriggered: root.notchGapsCommit() }
  Timer {
    id: notchGapsRetry
    interval: 50
    onTriggered: {
      var late = root.notchGapsQueued > 1
      root.notchGapsQueued = 0
      root.notchReadGaps(late)
    }
  }
  FileView {
    id: notchFlushBarFile
    path: (root.omarchyPath || "/usr/share/omarchy") + "/shell/plugins/flush-bar/manifest.json"
    printErrors: false
    onLoaded: root.notchFlushBar = true
    onLoadFailed: root.notchFlushBar = false
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = String(event.name)
      if (n === "configreloaded") root.notchGapsCheck(1500)
      else if (n === "activespecial") {
        root.notchSpecialSerial++
        root.notchSpecials = root.notchSpecialEvent(root.notchSpecials, event.data)
      }
    }
  }
  Connections {
    target: root
    function onRequestedTransparentChanged() { root.notchGapsCheck(1500) }
    function onPositionChanged() { root.notchGapsCheck(1500) }
  }
  // FullPanel (OmacVM.app): the camera housing from host.env, in Mac points
  // [left, right, strip, width, height]; [] when this boot is not one.
  property var notchPanel: []
  // The built-in display's output covers the whole display in full screen
  // (displays.json): the bar on it sits in the strip.
  property bool notchPanelOn: false
  property string notchPanelScreen: "Virtual-1"
  // host.env's OMACVM_FULLPANEL=LxRxHxWxD -> the five numbers, [] if none or odd
  // (the same limits as the app's NotchGeometry.valid).
  function notchPanelParse(text) {
    var m = String(text).match(/^OMACVM_FULLPANEL=([0-9.]+)x([0-9.]+)x([0-9.]+)x([0-9.]+)x([0-9.]+)$/m)
    if (!m) return []
    var g = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4]), Number(m[5])]
    if (!g.every(isFinite) || !(g[0] > 0 && g[1] > g[0] && g[1] < g[3] && g[1] - g[0] < g[3] / 3 &&
        g[2] >= 10 && g[2] <= 100 && g[3] >= 800 && g[4] > g[2] * 5)) return []
    return g
  }
  // From the app's layout message (displays.json) and the geometry: the
  // built-in display's output, and whether it covers the strip now (full
  // screen, at least the display's height less half the strip: the app's
  // clean size cuts a few rows at the bottom, below the notch it would be a
  // whole strip shorter).
  function notchPanelState(layoutText, g) {
    var out = { on: false, screen: "" }
    if (!g || g.length !== 5) return out
    try {
      var m = JSON.parse(String(layoutText))
      if (!m || typeof m.builtin !== "string" || !/^Virtual-[0-9]+$/.test(m.builtin)) return out
      out.screen = m.builtin
      if (m.fullscreen !== true || !Array.isArray(m.layout)) return out
      for (var i = 0; i < m.layout.length; i++) {
        var o = m.layout[i]
        if (o && o.output === m.builtin && Number(o.height) >= g[4] - g[2] / 2 &&
            Number(o.width) >= g[3] - 1) out.on = true
      }
    } catch (e) {}
    return out
  }
  // The housing and the strip in the output's logical pixels (the guest's
  // scale need not be the Mac's): [left, right, strip].
  function notchPanelBox(g, logicalWidth) {
    var k = logicalWidth > 0 ? logicalWidth / g[3] : 0
    return [g[0] * k, g[1] * k, g[2] * k]
  }
  function notchRoleFor(s) {
    // Only a bar along the top edge can live in the notch strip.
    if (position !== "top") return ""
    var n = s && s.name ? String(s.name) : ""
    if (n.indexOf("NOTCH") === 0) return "notch"
    if (notchPanelOn && n === notchPanelScreen) return "fullpanel"
    if (notchParked && n === notchParkedScreen) return "parked"
    return ""
  }
  // Omanotch's pointer over the strip (#308). The guest's pointer is not on
  // this bar then, so its hover handlers see nothing. Omanotch says where the
  // pointer is (x in bar px, -1: it left the strip), and the bar does what
  // its own hover handlers do: the auto-hidden indicators show while the
  // pointer is on the bar's free space and stay until it leaves the bar.
  property bool notchHovering: false
  // Omarchy 4.5 peeks while the pointer is on the bar left of where its
  // centre box starts (the bar window's peekEdge), over widgets too; the
  // strip does the same on the parked bar (notchPeeksAt).
  property bool notchPeeking: false
  function notchParkedWindow() {
    var ps = typeof notchBarVariants !== "undefined" ? notchBarVariants.instances : []
    for (var i = 0; i < ps.length; i++)
      if (ps[i] && ps[i].screen && String(ps[i].screen.name) === notchParkedScreen) return ps[i]
    return null
  }
  function notchPeekEdge() {
    var w = notchParkedWindow()
    return w && w.peekEdge !== undefined ? Number(w.peekEdge) : -1
  }
  // Omarchy 4.5's indicator peek opens over the bar left of the centre box,
  // where its own layout keeps the indicators (centerBegin). Where they sit
  // right of that edge (the right list, as a layout moved from 4.0 keeps
  // them), it opened far from them and shut on the way there, and their own
  // hover let go of them as they widened under the pointer (#763, #764). So
  // the peek also opens over their own place and over the place Skip the
  // notch opens their hidden ones at (left of the housing); the stretch
  // between those two (the housing and the widgets there) only keeps an open
  // peek open, on the way from one to the other, and left of the hidden ones
  // it shuts. Omarchy's rule counts only in Omarchy's own layout (they sit
  // inside its stretch and Skip the notch did not move their hidden ones),
  // and only left of the housing on a bar in the notch strip: nothing opens
  // under the housing (the pointer cannot be seen there) or in the gap
  // between it and the centre box. With their hidden ones moved left of the
  // housing, the left half (the workspaces) opened them from far away.
  // The bar's hover reads where they are only from notchIndicatorSpans, which
  // their slot refreshes once a move is done (their row, Skip the notch, a
  // tray's drawer pushing them, the peek's own opening): read straight from
  // the items, the peek's own opening changed what it read while it was being
  // set (QML: "Binding loop detected for property peeking").
  property var notchIndicatorSpans: ({})
  function notchIndicatorTick() {
    var now = notchIndicatorSpansNow()
    if (JSON.stringify(now) !== JSON.stringify(notchIndicatorSpans)) notchIndicatorSpans = now
  }
  // The indicators' places on each bar window, by screen name, in the
  // window's content coordinates: [start, end] of their own place, then
  // [start, end] of where their hidden ones open when Skip the notch moved
  // them left of the housing (peekAt; else their own place again), or null
  // where Skip the notch hides their hidden ones. With none of theirs showing
  // (nothing active), their own place is where the hidden ones open. A slot
  // still waiting unseen to show (notchAppearing) has no place yet.
  function notchIndicatorSpansNow() {
    var out = {}
    for (var i = 0; i < moduleSlots.length; i++) {
      var s = moduleSlots[i]
      if (!s || !s.notchPeekBlock || s.visible === false || s.notchShiftGone === true || s.notchAppearing === true) continue
      var w = slotWindow(s), n = w && w.screen && w.contentItem ? String(w.screen.name) : ""
      if (!n || out.hasOwnProperty(n)) continue
      var sh = s.notchShift, x = s.mapToItem(w.contentItem, 0, 0).x, f = Number(s.notchPeekFull) || 0
      if (sh && sh.peekHidden) { out[n] = null; continue }
      var own = s.width > 0 ? [x, x + s.width]
        : !(f > 0) ? null
        : s.fixedEdge === "start" ? [x, x + f] : s.fixedEdge === "end" ? [x - f, x] : [x - f / 2, x + f / 2]
      // peekAt is on the bar; the slot shows at notchShownX less its width.
      var at = sh && sh.peekAt !== undefined ? sh.peekAt + x - (s.notchShownX - (s.notchEnd ? s.width : 0)) : NaN
      out[n] = !isNaN(at) ? (own || [x, x]).concat([at, at + f]) : own ? own.concat(own) : null
    }
    return out
  }
  // On bar window win in item into's coordinates (the content's when null).
  function notchIndicatorSpan(win, into, spans) {
    var n = win && win.screen ? String(win.screen.name) : "", sp = (spans || notchIndicatorSpans)[n]
    if (!sp) return null
    var o = into && win.contentItem ? into.mapToItem(win.contentItem, 0, 0).x : 0
    return [sp[0] - o, sp[1] - o, sp[2] - o, sp[3] - o]
  }
  // The peek at pos (into's coordinates) on bar window win; stock: Omarchy's
  // own answer there; spans: notchIndicatorSpans unless given; held: the
  // peek is open now (the stretch between their places keeps it open).
  function notchPeeksAt(win, into, pos, stock, spans, held) {
    if (!pos || root.vertical || !win) return stock
    var x = Number(pos.x), sp = notchIndicatorSpan(win, into, spans)
    if (!sp) return stock
    if ((x >= sp[0] && x < sp[1]) || (x >= sp[2] && x < sp[3])) return true
    var a = Math.min(sp[0], sp[2]), b = Math.max(sp[1], sp[3])
    if (held === true && x >= a && x < b) return true
    if (win.notchLayout && x >= notchLeft) return false
    // Not Omarchy's own layout: their own place right of the centre box, or
    // their hidden ones moved (sp[2..3] is their own place again when not).
    if (sp[2] !== sp[0] || sp[0] >= Number(win.peekEdge)) return false
    return stock
  }
  function notchHover(x) {
    // Leaving the strip closes a tray's drawer, as leaving the drawer does.
    if (x < 0) root.notchTraySet(false, "", "")
    var older = typeof root.setCenterSectionHovered === "function"
    var stock = typeof root.setBarHovered === "function"
    if (x < 0 || root.barHidden || root.notchFullscreen) {
      if (root.notchPeeking) { root.notchPeeking = false; root.setBarHovered(false) }
      if (!root.notchHovering) return "off"
      root.notchHovering = false
      if (older && stock) { root.setCenterSectionHovered(false); root.setBarHovered(false) }
      return "off"
    }
    if (!stock) return "unsupported"
    if (!older) {
      var edge = root.notchPeekEdge()
      if (!(edge >= 0)) return "unsupported"
      root.notchHovering = true
      // On the parked copy, at the place of the item the strip shows at x.
      var px = root.notchParkedX(x)
      if (isNaN(px)) px = x
      var peek = root.notchPeeksAt(root.notchParkedWindow(), null, { x: px }, px < edge, root.notchIndicatorSpansNow(),
                                   root.notchPeeking)
      if (peek !== root.notchPeeking) { root.notchPeeking = peek; root.setBarHovered(peek) }
      return root.notchTargetAt(x, 0) ? "widget" : "free"
    }
    if (!root.notchHovering) { root.notchHovering = true; root.setBarHovered(true) }
    var t = root.notchTargetAt(x, 0)
    root.setCenterSectionHovered(!t)
    return t ? "widget" : "free"
  }
  // The strip shows NOTCH's copy and presses the parked one. Each copy's
  // widgets keep their own state (Omarchy's update icon asks at its start,
  // then every 6 hours), so for a while one copy can show an item the other
  // does not, and the items after it sit elsewhere. A strip x goes to the
  // same place in the parked copy's twin of the item shown there (same
  // section, id and count); NaN when the parked copy does not show it.
  function notchShownSlots(onNotch) {
    var out = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var s = moduleSlots[i]
      if (!s || !(s.width > 0) || s.visible === false || s.notchShiftGone === true) continue
      var w = slotWindow(s), n = w && w.screen && w.contentItem ? String(w.screen.name) : ""
      if (onNotch ? n.indexOf("NOTCH") !== 0 : n !== notchParkedScreen) continue
      out.push([s, s.mapToItem(w.contentItem, 0, 0).x])
    }
    out.sort(function(a, b) { return a[1] - b[1] })
    return out
  }
  function notchParkedX(x) {
    var shown = notchShownSlots(true), at = -1
    for (var i = 0; i < shown.length; i++)
      if (x >= shown[i][1] && x < shown[i][1] + shown[i][0].width) at = i
    if (at < 0) return x
    var s = shown[at][0], n = 0
    for (var j = 0; j < at; j++)
      if (shown[j][0].region === s.region && shown[j][0].moduleName === s.moduleName) n++
    var parked = notchShownSlots(false)
    for (var k = 0; k < parked.length; k++) {
      var p = parked[k][0]
      if (p.region !== s.region || p.moduleName !== s.moduleName) continue
      if (n-- === 0) return x - shown[at][1] + parked[k][1]
    }
    return NaN
  }
  function notchTargetAt(x, y) {
    x = notchParkedX(x)
    if (isNaN(x)) return null
    for (var i = clickTargets.length - 1; i >= 0; i--) {
      var t = clickTargets[i]
      // Not enabled: hidden by Skip the notch (both sides full).
      if (!moduleTargetClickable(t) || t.enabled === false) continue
      var w = targetWindow(t)
      if (!w || !w.screen || String(w.screen.name) !== notchParkedScreen) continue
      // x only: the bar is a single row, and the parked copy is 1 px tall.
      var s = notchSpan(t, w)
      if (s && x >= s[0] && x < s[0] + s[1]) return t
    }
    // Omarchy's tray icons are no click targets (#662).
    var icons = notchTraySpans(false)
    for (var j = 0; j < icons.length; j++)
      if (x >= icons[j][1][0] && x < icons[j][1][0] + icons[j][1][1]) return notchTrayTarget(icons[j][0])
    return null
  }
  function notchTargetRects() {
    var out = []
    for (var i = 0; i < clickTargets.length; i++) {
      var t = clickTargets[i]
      if (!moduleTargetClickable(t) || t.enabled === false) continue
      var w = targetWindow(t)
      if (!w || !w.screen || String(w.screen.name).indexOf("NOTCH") !== 0) continue
      var s = notchSpan(t, w)
      if (s) out.push([Math.round(s[0]), Math.round(s[2]), Math.round(s[1]), Math.round(t.height)])
    }
    var icons = notchTraySpans(true)
    for (var j = 0; j < icons.length; j++)
      out.push([Math.round(icons[j][1][0]), Math.round(icons[j][1][2]), Math.round(icons[j][1][1]),
                Math.round(icons[j][0].height)])
    return out
  }
  // Omarchy's tray (#662). Its icons are plain items with a mouse area of
  // their own, not click targets, and its drawer opens on hover, which the
  // strip does not pass on. So the strip finds the icons by their shape and
  // presses them as their mouse area does, and a left click on the drawer's
  // chevron opens or closes the drawer on both bars of the strip (the parked
  // one takes the clicks, NOTCH shows it). A tray: `expanded`, its drawer's
  // items and openTrayMenu; an icon: displayMenu and a tray item that can
  // activate. A clone of the tray has the same shape.
  function notchIsTray(item) {
    return !!item && typeof item.expanded === "boolean" && item.drawerItems !== undefined &&
      typeof item.openTrayMenu === "function"
  }
  function notchTrayOf(item, depth) {
    for (var p = item, i = 0; p && i <= depth; p = p.parent, i++)
      if (notchIsTray(p)) return p
    return null
  }
  function notchIsTrayIcon(item) {
    return !!item && typeof item.displayMenu === "function" && !!item.modelData &&
      typeof item.modelData.activate === "function"
  }
  function notchTrayIconsIn(item, depth, out) {
    var kids = item && depth <= 8 ? item.children || [] : []
    for (var i = 0; i < kids.length; i++) {
      if (notchIsTrayIcon(kids[i])) out.push(kids[i])
      else notchTrayIconsIn(kids[i], depth + 1, out)
    }
    return out
  }
  // How far the drawer still slides (600 ms): the strip asks for its targets
  // meanwhile, and a click then means where the icons end up. Leftwards,
  // or rightwards for Omarchy 4.5's tray at the start of the bar.
  function notchTrayDx(tray) {
    var e = Number(tray.drawerExtent), r = Number(tray.revealProgress)
    if (!(e > 0) || !isFinite(r)) return 0
    return (tray.fixedAtStart === true ? 1 : -1) * e * ((tray.expanded ? 1 : 0) - r)
  }
  // The drawer's chevron (4.5's points the other way at the bar's start).
  function notchIsChevron(t) {
    return !!t && (t.text === "\\uf053" || t.text === "\\uf054")
  }
  // Where an item shows on window w: [x, width, y], x only. For the tray's
  // chevron and its drawer's icons where the slide ends, cut to the drawer
  // (a closed drawer's icons: null).
  function notchSpan(t, w) {
    var p = t.mapToItem(w.contentItem, 0, 0)
    var chevron = notchIsChevron(t)
    var tray = chevron || notchIsTrayIcon(t) ? notchTrayOf(t, 8) : null
    if (!tray) return [p.x, t.width, p.y]
    var a = p.x, b = p.x + t.width, clips = []
    for (var c = t.parent; c && c !== tray; c = c.parent) if (c.clip === true) clips.push(c)
    if (chevron || clips.length) {
      var dx = notchTrayDx(tray)
      a += dx
      b += dx
    }
    for (var i = 0; i < clips.length; i++) {
      var q = clips[i].mapToItem(w.contentItem, 0, 0)
      a = Math.max(a, q.x)
      b = Math.min(b, q.x + clips[i].width)
    }
    return b - a >= 1 ? [a, b - a, p.y] : null
  }
  // The tray icons that show on the strip's bars: the parked one (false) or
  // NOTCH (true), as [icon, span].
  function notchTraySpans(onNotch) {
    var out = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var s = moduleSlots[i], tray = s ? s.activeItem : null
      if (!notchIsTray(tray) || s.enabled === false || tray.visible === false) continue
      var w = slotWindow(s), n = w && w.screen && w.contentItem ? String(w.screen.name) : ""
      if (onNotch ? n.indexOf("NOTCH") !== 0 : n !== notchParkedScreen) continue
      var icons = notchTrayIconsIn(tray, 0, [])
      for (var j = 0; j < icons.length; j++) {
        var it = icons[j]
        if (it.visible !== true || !(it.width > 0) || it.enabled === false) continue
        var sp = notchSpan(it, w)
        if (sp) out.push([it, sp])
      }
    }
    return out
  }
  // A tray icon as a click target: the buttons and the wheel as its own mouse
  // area takes them.
  function notchTrayTarget(it) {
    return {
      trayIcon: it,
      triggerPress: function(button) {
        var at = { x: it.width / 2, y: it.height / 2 }
        if (button === Qt.RightButton) it.displayMenu(at)
        else if (button === Qt.MiddleButton) it.modelData.secondaryActivate()
        else if (it.modelData.onlyMenu) it.displayMenu(at)
        else it.modelData.activate()
      },
      wheelMoved: function(delta) { it.modelData.scroll(delta, false) }
    }
  }
  // The drawer of the trays on the strip's two bars, open or closed: the
  // module `name` in `region`, or every tray there (name ""). Not saved: a
  // bar out of the strip has its own hover again.
  function notchTraySet(open, name, region) {
    for (var i = 0; i < moduleSlots.length; i++) {
      var s = moduleSlots[i], tray = s ? s.activeItem : null
      if (!notchIsTray(tray) || tray.expanded === open) continue
      if (name && (s.moduleName !== name || s.region !== region)) continue
      var w = slotWindow(s), n = w && w.screen ? String(w.screen.name) : ""
      if (n === notchParkedScreen || n.indexOf("NOTCH") === 0) tray.expanded = open
    }
  }
  // A left click on a tray's chevron: its drawer opens or closes. False for
  // any other target.
  function notchTrayToggle(t) {
    var tray = notchIsChevron(t) ? notchTrayOf(t, 4) : null
    if (!tray) return false
    var open = !tray.expanded
    for (var i = 0; i < moduleSlots.length; i++)
      if (moduleSlots[i] && moduleSlots[i].activeItem === tray)
        notchTraySet(open, moduleSlots[i].moduleName, moduleSlots[i].region)
    tray.expanded = open
    return true
  }
  // Skip the notch (OmacVM.app's setting for a VM, off by default): on a bar
  // in the notch strip, items that no longer fit on their side of the camera
  // housing continue on its other side (notchSkipPlace). The app says it at
  // the start (host.env: OMACVM_NOTCHSKIP=1) and, when it is switched while
  // the VM runs, in /run/omacvm/notch-skip ("1" or "0"), which then wins.
  property bool notchSkipOn: false
  property bool notchSkipBoot: false
  // Where the items of the left and right lists go on a bar in the notch
  // strip. In: the bar's width, Omarchy's margin at the screen edges (pad),
  // each list's items left to right, each a width or [width now, width at
  // rest, peek] (Omarchy's indicators: at rest without their hidden ones,
  // peek the width those take when they show on hover), the housing [left,
  // right], the width of the centre widgets beside it [before, after, and
  // on Omarchy 4.5 the room its indicators' peek opens into left of the
  // housing, which the right side's overflow keeps clear of: the peek opens
  // over what lies there and takes its hover]
  // (`edge` from it), the gap a jumped item keeps to the housing (or those
  // widgets) and the room it keeps from the other side's own items.
  // Everything is decided at rest, so a peek moves nothing across the notch:
  // an item stays on its side while it does not reach under the housing;
  // past that it jumps over and continues on the other side in the same
  // order, and hides only when that side is full too (then the rest of them
  // as well). The first item from each screen edge (the menu, the clock at
  // the far right) always stays. Items sit where Omarchy aligns them: left
  // ones at their start, right ones at their end.
  // The indicators' peek (right list): where they are, as Omarchy shows it,
  // when the right side has room for it; else the hidden ones open left of
  // the housing (or left of what jumped there), `gap` from it, and hide only
  // when the left side is full too.
  // A width that goes up and down a little (a stats readout) must not move
  // items back and forth: what the last layout decided (prev, its `state`)
  // stays until it is off by `stick` (an item comes back to its side, or
  // shows again, only with that much room to spare).
  // Out: per item {x: shift from Omarchy's place, hidden, n: that place on
  // the bar}, for the indicators also peekAt (where their hidden ones start
  // on the bar; none: in place) and peekHidden; how many items jumped and
  // hid; `state` for the next call; null when the housing is not on the bar.
  function notchSkipPlace(width, pad, left, right, housing, beside, edge, gap, keep, prev, stick) {
    var W = Number(width), nl = Number(housing[0]), nr = Number(housing[1])
    if (!(W > 0 && nl > 0 && nr > nl && nr < W)) return null
    var before = beside && beside[0] > 0 ? beside[0] : 0, after = beside && beside[1] > 0 ? beside[1] : 0
    var peekL = beside && beside[2] > 0 ? beside[2] : 0
    // Where each side ends: the housing, or the centre widgets beside it.
    var wallL = before > 0 ? nl - edge - before : nl
    var wallR = after > 0 ? nr + edge + after : nr
    function sizes(e) {
      var a = Array.isArray(e) ? e : [e]
      var w = Math.max(0, Number(a[0]) || 0)
      var r = a.length > 1 ? Math.max(0, Number(a[1]) || 0) : w
      return { w: w, r: r, p: a.length > 2 ? Math.max(0, Number(a[2]) || 0) : 0 }
    }
    // n: Omarchy's place (its rows, at today's widths); b: the item's place at rest.
    var L = [], R = [], out = { left: [], right: [], jumped: 0, hidden: 0 }
    var i, s, x = pad, b = pad, pi = -1
    for (i = 0; i < left.length; i++) {
      s = sizes(left[i])
      L.push({ n: x, w: s.w, r: s.r, b: b })
      x += s.w
      b += s.r
    }
    x = W - pad
    b = W - pad
    for (i = right.length - 1; i >= 0; i--) {
      s = sizes(right[i])
      x -= s.w
      b -= s.r
      R[i] = { n: x, w: s.w, r: s.r, p: s.p, b: b }
      if (s.p > 0 && pi < 0) pi = i
    }
    // The last layout's decisions, while the lists are the same.
    var st = prev && prev.nL === L.length && prev.nR === R.length ? prev : null
    var more = Math.max(0, Number(stick) || 0)
    // What stays on its own side: not under the housing at rest.
    var keptL = L.length, keptR = 0
    for (i = 1; i < L.length; i++)
      if (L[i].b + L[i].r > wallL - (st && i >= st.keptL ? more : 0)) { keptL = i; break }
    for (i = R.length - 2; i >= 0; i--)
      if (R[i].b < wallR + (st && i < st.keptR ? more : 0)) { keptR = i + 1; break }
    var endL = keptL > 0 ? L[keptL - 1].b + L[keptL - 1].r : pad
    var startR = keptR < R.length ? R[keptR].b : W - pad
    // The indicators' peek in place: the right side has room for it.
    var inPlace = pi >= keptR && startR - R[pi].p >= wallR + (st && st.inPlace === false ? more : 0)
    // The left side's overflow: right of the housing, up to `keep` before
    // the right side's own items.
    var at = wallR + gap, full = false, fullL = L.length, fullR = -1
    for (i = keptL; i < L.length; i++) {
      if (!full && at + L[i].r <= startR - keep - (st && i >= st.fullL ? more : 0)) {
        L[i].b = at
        at += L[i].r
        if (L[i].w > 0) out.jumped++
      } else {
        if (!full) fullL = i
        full = true
        L[i].hide = true
        if (L[i].w > 0) out.hidden++
      }
    }
    // The right side's overflow: left of the housing (and of the room the
    // indicators' peek opens into there), down to `keep` after the left
    // side's own items.
    at = wallL - peekL - gap
    full = false
    for (i = keptR - 1; i >= 0; i--) {
      if (!full && at - R[i].r >= endL + keep + (st && i <= st.fullR ? more : 0)) {
        at -= R[i].r
        R[i].b = at
        if (R[i].w > 0) out.jumped++
      } else {
        if (!full) fullR = i
        full = true
        R[i].hide = true
        if (R[i].w > 0) out.hidden++
      }
    }
    for (i = 0; i < L.length; i++) {
      var lx = L[i].hide ? wallL - gap - L[i].w : L[i].b
      out.left.push({ x: lx - L[i].n, hidden: !!L[i].hide, n: L[i].n })
    }
    for (i = 0; i < R.length; i++) {
      // In place: Omarchy's own places for the right side's items.
      var rx = R[i].hide ? wallR + gap : inPlace && i >= keptR ? R[i].n : R[i].b + R[i].r - R[i].w
      out.right.push({ x: rx - R[i].n, hidden: !!R[i].hide, n: R[i].n })
    }
    // Else the hidden indicators open left of the housing, after what
    // jumped there; they hide when the left side has no room for them.
    if (pi >= 0 && !inPlace && !R[pi].hide) {
      out.right[pi].peekAt = at - R[pi].p
      out.right[pi].peekHidden = at - R[pi].p < endL + keep
    } else if (pi >= 0 && R[pi].hide) {
      out.right[pi].peekHidden = true
    }
    out.state = { nL: L.length, nR: R.length, keptL: keptL, keptR: keptR, fullL: fullL, fullR: fullR,
                  inPlace: pi >= 0 ? inPlace : null }
    return out
  }
  // Omarchy's indicators show their hidden ones when they peek (hover):
  // that block (an IndicatorBlock "inactive" in a clipping item of the
  // horizontal row, in both shells), or null.
  function notchPeekBlockIn(item, depth) {
    if (!item || depth > 8) return null
    if (item.indicatorBlock === "inactive" && item.horizontal === true) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = notchPeekBlockIn(kids[i], depth + 1)
      if (found) return found
    }
    return null
  }
  // The indicators' block of the ones that show: the hidden ones' area's
  // sibling in their row (Omarchy's ActiveIndicatorBlock), or null.
  function notchPeekActiveIn(area) {
    var kids = area && area.parent ? area.parent.children || [] : []
    for (var i = 0; i < kids.length; i++)
      if (kids[i] !== area && kids[i].indicatorModel !== undefined) return kids[i]
    return null
  }
  // One item's part of a list's layout ({items, animate}; null: none).
  function notchShiftAt(list, i) {
    var s = list && list.items ? list.items[i] : null
    return s ? { x: s.x, hidden: s.hidden === true, n: s.n, peekAt: s.peekAt, peekHidden: s.peekHidden === true,
                 animate: list.animate === true } : null
  }
  // --- end omarchy-notch-bar --------------------------------------------
'''.replace("{VERSION_LINE}", VERSION_LINE))

    # 2. IPC target and watchdog, next to the existing omarchy.bar handler.
    text = replace_once(text, '''  Variants {
    model: Quickshell.screens

    delegate: Component {
      BarPanel {''', '''  // omarchy-notch-bar: control surface for the macOS notch helper.
  IpcHandler {
    target: "notchbar"

    function setParked(on: bool): string {
      root.notchLastBeat = Date.now()
      root.notchBootPark = false
      root.notchParked = on
      return root.notchParked ? "parked" : "unparked"
    }
    function setParkedScreen(name: string): string {
      root.notchParkedScreen = name
      return root.notchParkedScreen
    }
    function setNotch(left: real, right: real): string {
      root.notchLeft = left
      root.notchRight = right
      return left + "," + right
    }
    function setNotchHeight(height: real): string {
      root.notchHeight = height > 0 && height < 200 ? height : 0
      return String(root.notchHeight)
    }
    function setNotchBarHeight(height: real): string {
      root.notchBarHeight = height > 0 && height < 200 ? height : 0
      return String(root.notchBarHeight)
    }
    function poke(): string {
      root.notchPokeSerial++
      return String(root.notchPokeSerial)
    }
    function heartbeat(): string {
      root.notchLastBeat = Date.now()
      root.notchBootPark = false
      return root.notchParked ? "parked" : "unparked"
    }
    // Omanotch saw the VM full screen on the built-in display when it
    // connected: the strip is coming. Parked now, as with the boot hint, so
    // the display shows no bar of its own in the meantime (after a windowed
    // session the hint said "0").
    function bootPark(name: string): string {
      if (root.notchParked && !root.notchBootPark) return "parked"
      root.notchBootParkOn(name)
      return "boot-parked"
    }
    function click(x: real, y: real, button: int): string {
      // bar-off or fullscreen: nothing is shown in the strip
      if (root.barHidden || root.notchFullscreen) return "miss"
      var t = root.notchTargetAt(x, y)
      if (!t) return "miss"
      // The tray's drawer opens on hover only; from the strip a left click
      // on its chevron does it (#662). Right and middle stay Omarchy's.
      if (button !== 2 && button !== 3 && root.notchTrayToggle(t)) return "ok"
      t.triggerPress(button === 3 ? Qt.MiddleButton : button === 2 ? Qt.RightButton : Qt.LeftButton)
      return "ok"
    }
    function wheel(x: real, y: real, delta: int): string {
      if (root.barHidden || root.notchFullscreen) return "miss"
      var t = root.notchTargetAt(x, y)
      if (!t || typeof t.wheelMoved !== "function") return "miss"
      t.wheelMoved(delta)
      return "ok"
    }
    function hover(x: real): string {
      return root.notchHover(x)
    }
    function targets(): string {
      return JSON.stringify(root.barHidden || root.notchFullscreen ? [] : root.notchTargetRects())
    }
    // What a click at x would press: [screen, item id], or "miss" (rows, logs).
    function pick(x: real): string {
      var t = root.barHidden || root.notchFullscreen ? null : root.notchTargetAt(x, 0)
      if (!t) return "miss"
      for (var i = 0; i < root.moduleSlots.length; i++) {
        var s = root.moduleSlots[i]
        for (var p = t; s && p; p = p.parent) {
          if (p !== s && p !== s.activeItem) continue
          var w = root.slotWindow(s)
          return JSON.stringify([w && w.screen ? String(w.screen.name) : "", String(s.moduleName)])
        }
      }
      return JSON.stringify(["", ""])
    }
    function state(): string {
      return JSON.stringify({ parked: root.notchParked, screen: root.notchParkedScreen,
                              fullpanel: root.notchPanel.length ? (root.notchPanelOn ? "strip" : "waiting") : "off",
                              notch: [root.notchLeft, root.notchRight], notchHeight: root.notchHeight, notchBarHeight: root.notchBarHeight, barSize: root.barSize,
                              beatAgeMs: root.notchLastBeat ? Date.now() - root.notchLastBeat : -1, skip: root.notchSkipOn,
                              bars: notchBarVariants.instances.map(function(p) {
                                return [p.screen ? String(p.screen.name) : "", p.notchRole, p.parked, p.parkedSize, p.height,
                                        p.notchSkip ? [p.notchSkip.jumped, p.notchSkip.hidden] : null]
                              }) })
    }
    // Omarchy's indicators' hidden ones on each bar: [screen, x, width, shown].
    function peek(): string {
      var out = []
      for (var i = 0; i < root.moduleSlots.length; i++) {
        var s = root.moduleSlots[i], b = s ? s.notchPeekBlock : null
        var w = s ? root.slotWindow(s) : null
        if (!b || !b.parent || !w || !w.screen || !w.contentItem) continue
        var p = b.parent.mapToItem(w.contentItem, 0, 0)
        out.push([String(w.screen.name), Math.round(p.x * 10) / 10, Math.round(b.parent.width * 10) / 10,
                  b.parent.width > 0 && b.parent.opacity > 0])
      }
      return JSON.stringify(out)
    }
    // Each bar item as it shows: [screen, region, id, x, width, hidden].
    function items(): string {
      var out = []
      for (var i = 0; i < root.moduleSlots.length; i++) {
        var s = root.moduleSlots[i]
        var w = s ? root.slotWindow(s) : null
        if (!s || !w || !w.screen || !w.contentItem || !(s.width > 0)) continue
        var p = s.mapToItem(w.contentItem, 0, 0)
        out.push([String(w.screen.name), s.region, s.moduleName, Math.round(p.x * 10) / 10,
                  Math.round(s.width * 10) / 10, s.notchShiftGone === true])
      }
      return JSON.stringify(out)
    }
    // Each tray's drawer: [screen, id, open, how far it has slid (0-1)].
    function trays(): string {
      var out = []
      for (var i = 0; i < root.moduleSlots.length; i++) {
        var s = root.moduleSlots[i], w = s ? root.slotWindow(s) : null
        if (!s || !root.notchIsTray(s.activeItem) || !w || !w.screen) continue
        out.push([String(w.screen.name), s.moduleName, s.activeItem.expanded,
                  Math.round(Number(s.activeItem.revealProgress) * 100) / 100])
      }
      return JSON.stringify(out)
    }
  }

  // Heartbeat and state go through two small files in
  // ~/.local/state/omanotch, so the steady state costs no process at all:
  // notchcast writes `beat` (a millisecond timestamp) every few seconds, the
  // bar writes `bar-state` whenever its parking or size changes. (An IPC call
  // starts a `qs` process each time.)
  readonly property string notchStateDir: home + "/.local/state/omanotch"
  readonly property real notchStartedAt: Date.now()
  // blockAllReads: text() right after reload() waits for the new content
  // (with blockLoading alone it returns the previous load's text).
  FileView {
    id: notchBeatFile
    path: root.notchStateDir + "/beat"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: notchStateFile
    path: root.notchStateDir + "/bar-state"
    printErrors: false
  }
  function notchWriteState() {
    if (!notchStateFile.path) return  // still being created; the timer below writes it
    notchStateFile.setText(JSON.stringify({ parked: notchParked, barSize: barSize, started: notchStartedAt,
                                            fullpanel: notchPanel.length ? (notchPanelOn ? "strip" : "waiting") : "off" }) + "\n")
  }
  onNotchParkedChanged: notchWriteState()
  // A tray's drawer opened from the strip closes when the strip goes (the
  // bar comes back with its own hover), and when the strip shows no bar.
  Connections {
    target: root
    function onNotchParkedChanged() { root.notchTraySet(false, "", "") }
    function onBarHiddenChanged() { if (root.barHidden) root.notchTraySet(false, "", "") }
    function onNotchFullscreenChanged() { if (root.notchFullscreen) root.notchTraySet(false, "", "") }
  }
  onNotchPanelOnChanged: notchWriteState()
  onBarSizeChanged: notchWriteState()
  Timer {
    interval: 500
    running: true
    onTriggered: root.notchWriteState()
  }

  // notchcast's last word on parking: "1 <output>" or "0" (notchcast writes
  // it before its IPC calls). Followed only while notchcast beats, so a file
  // left behind by a notchcast that died changes nothing.
  FileView {
    id: notchParkFile
    path: root.notchStateDir + "/park"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  function notchFollowParkFile() {
    notchBeatFile.reload()
    var beat = parseFloat(String(notchBeatFile.text()).trim())
    if (!(beat > 0) || Date.now() - beat > 15000) return
    notchParkFile.reload()
    var p = String(notchParkFile.text()).trim().split(/\\s+/)
    // "w <output>": notchcast is connected and waits for Omanotch's word
    // (often since before this shell started). Keeps a boot-parked bar
    // parked up to 15 s after that beat (the strip's first frame can take a
    // few seconds); changes nothing else.
    if (p[0] === "w") {
      if (notchBootPark && beat > notchLastBeat) {
        notchLastBeat = beat
        notchArmExpiry()
      }
      return
    }
    if (beat > notchLastBeat) notchLastBeat = beat
    notchBootPark = false
    if (p[0] === "1" && p.length === 2 && /^[A-Za-z0-9_.-]+$/.test(p[1])) {
      if (notchParkedScreen !== p[1]) notchParkedScreen = p[1]
      if (!notchParked) notchParked = true
    } else if (p[0] === "0" && p.length === 1 && notchParked) {
      notchParked = false
    }
  }

  // notchcast's word on the strip that outlives a reboot: "1 <output>" when
  // it showed at the end of the last session, "0" when it was hidden or
  // Omanotch went away. With "1" the shell starts parked, so the first frame
  // after login already has the bar in the strip only (no bar on the display
  // that then disappears, no windows that jump). If Omanotch does not confirm
  // within notchBootGraceMs (windowed now, or Omanotch not running), the bar
  // comes back and the file says "0", so the next start does not guess again.
  // The notch geometry of the last session (geom, "left right strip bar")
  // lays out the NOTCH copy right from its first frame.
  readonly property real notchBootGraceMs: 8000
  property bool notchBootPark: false
  // OmacVM.app with external displays: the built-in display may be another
  // output than in the last session; this file names it (when it is there yet).
  FileView {
    id: notchBuiltinFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omacvm/builtin"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  function notchBootParkOn(name) {
    notchBuiltinFile.reload()
    var b = String(notchBuiltinFile.text()).trim()
    if (/^Virtual-[0-9]+$/.test(b)) name = b
    if (!/^[A-Za-z0-9_.-]+$/.test(name)) return
    notchParkedScreen = name
    notchLastBeat = Date.now() - 15000 + notchBootGraceMs
    notchBootPark = true
    notchParked = true
    notchArmExpiry()
  }
  // Brings a guessed bar back on time when nothing confirms the guess (the
  // 3 s timer alone would make it up to 3 s later).
  Timer {
    id: notchBootExpiry
    onTriggered: root.notchWatchdog()
  }
  function notchArmExpiry() {
    notchBootExpiry.interval = Math.max(50, notchLastBeat + 15000 - Date.now() + 50)
    notchBootExpiry.restart()
  }
  FileView {
    id: notchExpectFile
    path: root.notchStateDir + "/expect"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: notchGeomFile
    path: root.notchStateDir + "/geom"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  // FullPanel: what the app said at this start (fixed for the boot) and its
  // layout message (each display change).
  FileView {
    id: notchHostEnvFile
    path: "/run/omacvm/host.env"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: notchLayoutFile
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/omacvm/displays.json"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  function notchPanelUpdate() {
    if (!notchPanel.length) return
    notchLayoutFile.reload()
    var st = notchPanelState(notchLayoutFile.text(), notchPanel)
    if (st.screen && st.screen !== notchPanelScreen) notchPanelScreen = st.screen
    var on = false
    var ss = Quickshell.screens
    for (var i = 0; st.on && i < ss.length; i++) {
      if (String(ss[i].name) !== notchPanelScreen) continue
      var b = notchPanelBox(notchPanel, ss[i].width)
      if (b[1] > b[0] && b[2] > 0) {
        if (notchLeft !== b[0]) notchLeft = b[0]
        if (notchRight !== b[1]) notchRight = b[1]
        if (notchHeight !== b[2]) notchHeight = b[2]
        // Fullscreen windows on it paint the strip black (notchWorkspaceId).
        if (notchParkedScreen !== notchPanelScreen) notchParkedScreen = notchPanelScreen
        on = true
      }
    }
    if (on !== notchPanelOn) notchPanelOn = on
  }
  // Skip the notch: the app's word at this start, and while the VM runs.
  FileView {
    id: notchSkipFile
    path: "/run/omacvm/notch-skip"
    blockLoading: true
    blockAllReads: true
    printErrors: false
  }
  function notchSkipUpdate() {
    notchSkipFile.reload()
    var t = String(notchSkipFile.text()).trim()
    var on = t === "1" ? true : t === "0" ? false : notchSkipBoot
    if (on !== notchSkipOn) notchSkipOn = on
  }
  function notchBoot() {
    notchSkipBoot = /^OMACVM_NOTCHSKIP=1$/m.test(String(notchHostEnvFile.text()))
    notchPanel = notchPanelParse(notchHostEnvFile.text())
    if (notchPanel.length) {
      notchPanelUpdate()
      return
    }
    var g = String(notchGeomFile.text()).trim().split(/\\s+/).map(Number)
    if (g.length === 4 && g.every(isFinite) && g[0] > 0 && g[1] > g[0]) {
      notchLeft = g[0]
      notchRight = g[1]
      notchHeight = g[2] > 0 && g[2] < 200 ? g[2] : 0
      notchBarHeight = g[3] > 0 && g[3] < 200 ? g[3] : 0
    }
    // The hint first, then notchcast's word if it has one already (a fresh
    // beat: notchcast removes a beat it did not write itself when it starts).
    var e = String(notchExpectFile.text()).trim().split(/\\s+/)
    if (e[0] === "1" && e.length === 2 && /^[A-Za-z0-9_.-]+$/.test(e[1])) notchBootParkOn(e[1])
    notchFollowParkFile()
  }
  property bool notchBooted: false
  function notchWatchdog() {
    if (notchParked && Date.now() - notchLastBeat > 15000) {
      notchParked = false
      if (notchBootPark) {
        notchBootPark = false
        notchExpectFile.setText("0\\n")
      }
    }
  }

  // Follows the park file (at once when the shell starts: a restarted shell
  // must not wait for the next IPC call), and unparks when the helper goes
  // quiet, so the built-in display never ends up without a bar. notchcast
  // beats every 4 s and unparks by itself when the helper or the service
  // stops; the watchdog only catches a notchcast that died. Two tiny file
  // reads every 3 s, no process.
  Timer {
    interval: 3000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (!root.notchBooted) {
        root.notchBooted = true
        root.notchBoot()
      } else if (root.notchPanel.length) {
        root.notchPanelUpdate()
      } else {
        root.notchFollowParkFile()
      }
      root.notchWatchdog()
      root.notchSkipUpdate()
    }
  }

  Variants {
    id: notchBarVariants
    model: Quickshell.screens

    delegate: Component {
      BarPanel {''')

    # 3. Parking per window instead of only through the global bar-off flag.
    #    Omarchy's own visible condition stays (from about October 2026 a top
    #    bar also waits for its notch floor), with the remap below added.
    #    Omarchy 4.5 reserves an explicit zone (its window spans the screen):
    #    a notch role reserves its own window, FullPanel's bar its strip less
    #    5 px of the top window gap (notchPanelZone, #758).
    #    FullPanel's bar reserves less than its window (#758): on 4.0 that
    #    role alone takes an explicit zone, the others keep Auto.
    auto = ("    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto\n",
            """    // omarchy-notch-bar: FullPanel's bar reserves an explicit zone (its strip
    // less 5 px of the top window gap, notchPanelZone), the other roles Auto.
    exclusionMode: barWindow.parked ? ExclusionMode.Ignore
      : barWindow.notchRole === "fullpanel" ? ExclusionMode.Normal : ExclusionMode.Auto
    // Only in that role: setting exclusiveZone switches Quickshell to Normal.
    Binding {
      target: barWindow; property: "exclusiveZone"; value: barWindow.notchPanelZone
      when: barWindow.notchRole === "fullpanel" && !barWindow.parked; restoreMode: Binding.RestoreNone
    }
""")
    zone = ('''    // An explicit zone instead of Auto: the reserved area stays the strip's
    // thickness though the window spans its screen.
    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Normal
    exclusiveZone: thickness
''', '''    // An explicit zone instead of Auto: the reserved area stays the strip's
    // thickness though the window spans its screen. omarchy-notch-bar: a
    // notch role's window is its strip; FullPanel's bar reserves its strip
    // less 5 px of the top window gap (notchPanelZone).
    exclusionMode: barWindow.parked ? ExclusionMode.Ignore : ExclusionMode.Normal
    exclusiveZone: barWindow.notchRole === "" ? thickness
      : barWindow.notchRole === "fullpanel" ? barWindow.notchPanelZone : barWindow.parkedSize
''')
    cutout = "!remapGuard.remapping && (cutoutWaitOver || !cutoutPending)"
    stock_visible = [("!remapGuard.remapping", auto), (cutout, auto), (cutout, zone)]
    text = replace_variant(text, [(f'''    visible: {v}
{ex[0]}''', '''    // omarchy-notch-bar: notchRemap, see below.
    visible: VISIBLE && !notchRemap.remapping
    // omarchy-notch-bar: role of this copy ("notch", "parked" or "").
    readonly property string notchRole: root.notchRoleFor(screen)
    // Over fullscreen the NOTCH copy stays mapped, even with the bar off, to
    // paint the strip black. FullPanel's bar too.
    readonly property bool notchBlack: (notchRole === "notch" || notchRole === "fullpanel") && root.notchFullscreen
    // FullPanel's bar while the bar is hidden: it stays in the strip, so the
    // windows never go under the notch, but shows nothing, so the wallpaper
    // (Omarchy's background, over the whole output) shows up to the top edge.
    readonly property bool notchClear: notchRole === "fullpanel" && root.barHidden && !root.notchFullscreen
    readonly property bool parked: (root.barHidden && !notchBlack && !notchClear) || notchRole === "parked"
    Binding { target: barWindow; property: "color"; value: "transparent"; when: barWindow.notchClear }
    readonly property bool notchLayout: notchRole !== ""
    // Skip the notch on this bar (its horizontal bar sets it): see
    // root.notchSkipPlace; null when off or not in the notch strip.
    property var notchSkip: null
    // The parked copy is 1 px tall: panels open at its height + gap, so they
    // appear right below the notch strip instead of a bar height lower.
    // The NOTCH copy fills the whole NOTCH output (nothing may show below the
    // bar) and centres its content in the part the strip shows (notchBox).
    // Flush (notchBarHeight): only the camera housing's height, the wallpaper
    // below it; over fullscreen the whole strip again, to paint it black.
    readonly property var notchFit: root.notchBox(screen ? Math.ceil(screen.height) : 0, root.notchHeight,
                                                  notchBlack ? 0 : root.notchBarHeight, root.barSize,
                                                  screen ? screen.devicePixelRatio : 1)
    // FullPanel: the bar is the strip's height, its content centred, so its
    // exclusive zone keeps the strip beside the notch free of windows.
    readonly property var notchPanelFit: root.notchBox(0, root.notchHeight, 0, root.barSize,
                                                       screen ? screen.devicePixelRatio : 1)
    readonly property int parkedSize: notchRole === "parked" ? 1
      : notchRole === "notch" ? notchFit[0] : notchRole === "fullpanel" ? notchPanelFit[0] : STOCK_SIZE
    // FullPanel's zone: the strip less 5 px of the top window gap (all of it
    // when the gap is under 5; #758), see root.notchGapsFor; the same in
    // every role, so it is never written while the role changes.
    readonly property int notchPanelZone: root.notchPanelZoneFor(notchPanelFit[0], root.notchGapsAt(screen ? screen.name : "", root.notchGapsSure, root.notchGapsSeen, root.notchSpecials, root.notchFlush))
    readonly property real notchPadTop: notchRole === "notch" ? notchFit[1] : notchRole === "fullpanel" ? notchPanelFit[1] : 0
    readonly property real notchPadBottom: notchRole === "notch" || notchRole === "fullpanel"
      ? parkedSize - root.barSize - notchPadTop : 0
EXCLUSION
    // omarchy-notch-bar: Hyprland leaves a mapped layer surface at its old
    // place when its output moves (the bar is then on no screen at all).
    // Omarchy's ScreenMoveRemap is meant to remap it, but it waits for
    // xChanged/yChanged, which Quickshell's screens do not have (they only
    // have geometryChanged), so it never fires. This does the same on
    // geometryChanged, when the output's position really changed.
    Item {
      id: notchRemap
      visible: false
      property bool remapping: false
      property real lastX: NaN
      property real lastY: NaN
      function note() {
        var s = barWindow.screen
        if (!s || (s.x === lastX && s.y === lastY)) return
        var moved = !isNaN(lastX)
        lastX = s.x
        lastY = s.y
        if (moved) notchRemapSettle.restart()
      }
      // When the notch park ends (the role leaves "parked"), unmap for a
      // moment too (#727). The parked copy is 1 px tall and off screen. Qt
      // sends its new size and margin only with its next frame, and that
      // frame waits for the compositor's answer to the last one, which comes
      // only when the display is drawn again for something else; on a 4.0 VM
      // the bar could stay hidden that way. A new map does not wait. Only
      // the end of the notch park: Omarchy's own bar toggle and the NOTCH or
      // FullPanel bars keep their fast path (margins only).
      property string roleWas: ""
      function notchParkEnd() {
        if (roleWas === "parked" && barWindow.notchRole !== "parked") remapping = true
        roleWas = barWindow.notchRole
      }
      Component.onCompleted: { note(); notchParkEnd() }
      Connections {
        target: barWindow.screen
        function onGeometryChanged() { notchRemap.note(); root.notchPanelUpdate() }
      }
      Connections {
        target: barWindow
        function onNotchRoleChanged() { notchRemap.notchParkEnd() }
      }
      // Let a layout change settle, then unmap for a moment (long enough
      // that the compositor sees the unmap before the new map).
      Timer { id: notchRemapSettle; interval: 200; onTriggered: notchRemap.remapping = true }
      Timer { interval: 100; running: notchRemap.remapping; onTriggered: notchRemap.remapping = false }
    }
'''.replace("VISIBLE", v).replace("STOCK_SIZE", stock_size).replace("EXCLUSION", ex[1]))
                                  for v, ex in stock_visible], "the bar's visible line")
    text = replace_once(text, stock_margins[SIZES.index(stock_size)], '''      top: barWindow.parked && root.position === "top" ? -barWindow.parkedSize : 0
      bottom: barWindow.parked && root.position === "bottom" ? -barWindow.parkedSize : 0
      left: barWindow.parked && root.position === "left" ? -barWindow.parkedSize : 0
      right: barWindow.parked && root.position === "right" ? -barWindow.parkedSize : 0''')

    # Omarchy raises the bar to the camera cutout on Apple notched panels:
    # omarchy-mac on Apple Silicon hosts (notchFloor), upstream from about
    # October 2026 where display-cutouts.json describes one (thickness).
    # Older versions use the bar size alone. Ordinary bars keep Omarchy's
    # height, the notch roles get parkedSize.
    stock_heights = [
        ("root.barSize", "Math.max(root.barSize, notchFloor)"),
        ("root.barSize", "root.barSize"),
        ("thickness", "thickness"),
        ("(screen ? screen.width : thickness)", "(screen ? screen.height : thickness)"),
    ]
    text = replace_variant(text, [
        (f"    implicitWidth: root.vertical ? {width} : 0\n    implicitHeight: root.vertical ? 0 : {height}\n",
         f"    implicitWidth: root.vertical ? {width} : 0\n"
         f"    implicitHeight: root.vertical ? 0 : (barWindow.notchRole === \"\" ? {height} : barWindow.parkedSize)\n")
        for width, height in stock_heights], "the bar's implicitHeight line")

    # The bar's content: in its window (4.0), or in the strip along the edge
    # of a window that spans the screen (4.5), where a notch role's strip is
    # its whole window.
    text = replace_variant(text, [('''    Loader {
      anchors.fill: parent
      sourceComponent: root.vertical ? verticalBar : horizontalBar
''', '''    Loader {
      anchors.fill: parent
      anchors.topMargin: barWindow.notchPadTop
      anchors.bottomMargin: barWindow.notchPadBottom
      visible: !barWindow.notchClear
      sourceComponent: root.vertical ? verticalBar : horizontalBar
'''), ('''      height: root.vertical ? parent.height : barWindow.thickness

      Rectangle {
        anchors.fill: parent
        color: root.transparent ? "transparent" : (root.glassy ? root.glassBackground : root.background)
      }

      Loader {
        anchors.fill: parent
        sourceComponent: root.vertical ? verticalBar : horizontalBar
''', '''      // omarchy-notch-bar: a notch role's window is its strip (parkedSize).
      height: root.vertical ? parent.height : (barWindow.notchRole === "" ? barWindow.thickness : parent.height)

      Rectangle {
        anchors.fill: parent
        visible: !barWindow.notchClear
        color: root.transparent ? "transparent" : (root.glassy ? root.glassBackground : root.background)
      }

      Loader {
        anchors.fill: parent
        anchors.topMargin: barWindow.notchPadTop
        anchors.bottomMargin: barWindow.notchPadBottom
        visible: !barWindow.notchClear
        sourceComponent: root.vertical ? verticalBar : horizontalBar
''')], "the bar's content")

    # 4. Pass the layout mode to the horizontal centre section (from about
    #    October 2026 Omarchy also gives it its entries there), and Skip the
    #    notch's layout of this window's left and right lists.
    skip_bar = '''        id: notchSkipBar
        anchors.fill: parent
        // omarchy-notch-bar: Skip the notch (root.notchSkipPlace), for this
        // window only and only while it is a bar in the notch strip. Items
        // slide once the layout has settled (not at login or when parking).
        readonly property bool notchSkipActive: root.notchSkipOn && barWindow.notchLayout
        property bool notchSkipSettled: false
        onNotchSkipActiveChanged: notchSkipSettled = false
        Timer {
          interval: 1500
          running: notchSkipBar.notchSkipActive && !notchSkipBar.notchSkipSettled
          onTriggered: notchSkipBar.notchSkipSettled = true
        }
        readonly property var notchSkip: notchSkipActive
          ? root.notchSkipPlace(width, Style.space(8), notchLeftList.notchWidths, rightModules.notchWidths,
                                [root.notchLeft, root.notchRight], notchCentre.notchBeside,
                                Style.space(6), Style.space(8), Style.space(24), notchSkipPrev, Style.space(12))
          : null
        // The decisions it made last (see notchSkipPlace's `stick`), kept
        // only when they change and once this round of changes is over (not
        // inside the layout's own binding), so it settles after one more round.
        property var notchSkipPrev: null
        property string notchSkipPrevKey: ""
        readonly property bool notchSkipPlaceOk: true
        onNotchSkipChanged: Qt.callLater(notchSkipKeep)
        function notchSkipKeep() {
          if (typeof notchSkipPlaceOk === "undefined") return   // the bar went away meanwhile
          var st = notchSkip ? notchSkip.state : null
          var key = st ? JSON.stringify(st) : ""
          if (key === notchSkipPrevKey) return
          notchSkipPrevKey = key
          notchSkipPrev = st
        }
        Binding { target: barWindow; property: "notchSkip"; value: notchSkipBar.notchSkip }
'''
    skip_left = '''        LeftModules {
          id: notchLeftList
          notchShift: notchSkipBar.notchSkip ? { items: notchSkipBar.notchSkip.left, animate: notchSkipBar.notchSkipSettled } : null
          anchors.left: parent.left'''
    text = replace_variant(text, [('''      Item {
        anchors.fill: parent

        CenterModules { anchors.fill: parent }

        LeftModules {
          anchors.left: parent.left''', '''      Item {
''' + skip_bar + '''
        CenterModules { id: notchCentre; anchors.fill: parent; notchLayout: barWindow.notchLayout }

''' + skip_left), ('''      Item {
        anchors.fill: parent

        CenterModules {
          anchors.fill: parent
          entries: barWindow.centerBesideRight ? [] : root.layoutEntries("center")
        }

        LeftModules {
          anchors.left: parent.left''', '''      Item {
''' + skip_bar + '''
        CenterModules {
          id: notchCentre
          anchors.fill: parent
          notchLayout: barWindow.notchLayout
          entries: barWindow.centerBesideRight ? [] : root.layoutEntries("center")
        }

''' + skip_left), ('''      Item {
        anchors.fill: parent

        WidgetPool { id: horizontalPool }

        CenterModules {
          anchors.fill: parent
          window: barWindow
          pool: horizontalPool
          drawn: !barWindow.centerBesideRight
        }

        LeftModules {
          window: barWindow
          pool: horizontalPool
          anchors.left: parent.left''', '''      Item {
''' + skip_bar + '''
        WidgetPool { id: horizontalPool }

        CenterModules {
          id: notchCentre
          anchors.fill: parent
          window: barWindow
          pool: horizontalPool
          drawn: !barWindow.centerBesideRight
          notchLayout: barWindow.notchLayout
        }

        LeftModules {
          id: notchLeftList
          notchShift: notchSkipBar.notchSkip ? { items: notchSkipBar.notchSkip.left, animate: notchSkipBar.notchSkipSettled } : null
          window: barWindow
          pool: horizontalPool
          anchors.left: parent.left''')], "the horizontal bar's centre section")
    skip_right = '''          notchShift: notchSkipBar.notchSkip ? { items: notchSkipBar.notchSkip.right, animate: notchSkipBar.notchSkipSettled } : null
'''
    text = replace_variant(text, [('''        RightModules {
          anchors.right: parent.right
''', '''        RightModules {
          id: rightModules
''' + skip_right + '''          anchors.right: parent.right
'''), ('''        RightModules {
          id: rightModules
          anchors.right: parent.right
''', '''        RightModules {
          id: rightModules
''' + skip_right + '''          anchors.right: parent.right
'''), ('''        RightModules {
          window: barWindow
          pool: horizontalPool
          id: rightModules
          anchors.right: parent.right
''', '''        RightModules {
          window: barWindow
          pool: horizontalPool
          id: rightModules
''' + skip_right + '''          anchors.right: parent.right
''')], "the horizontal bar's right section")

    # 5. Centre widgets around the camera housing in notch layout.
    if form45:
        text = centre_45(text)
    else:
        text = centre_40(text)

    # 6. One-pixel repaint trigger (pixel value unchanged) for notchcast.
    text = replace_once(text, '''    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top
''', '''    WlrLayershell.namespace: "omarchy-bar"
    // omarchy-notch-bar: on the NOTCH output the bar sits on the overlay
    // layer, above Omarchy's notification popups (overlay too; notchbar.lua
    // orders them), which would otherwise show their top edge in the strip.
    // FullPanel's bar likewise: above full-screen windows, to paint the strip black.
    WlrLayershell.layer: barWindow.notchRole === "notch" || barWindow.notchRole === "fullpanel" ? WlrLayer.Overlay : WlrLayer.Top

    // omarchy-notch-bar: repaint trigger, see notchPokeSerial.
    Rectangle {
      x: 0; y: 0; width: 1; height: 1; z: -1
      visible: !barWindow.notchClear
      // The bar's own colour where it is opaque; on a see-through bar
      // (transparent, or glassy from about October 2026) a second layer of
      // it would show.
      color: barWindow.color.a < 1 ? "transparent" : barWindow.color
      opacity: root.notchPokeSerial % 2 ? 0.999 : 1
    }
    // omarchy-notch-bar: black strip over fullscreen windows. FullPanel's
    // strip (black, or the wallpaper while the bar is hidden) takes the
    // clicks, which would otherwise reach nothing there.
    Rectangle {
      anchors.fill: parent
      z: 1000
      visible: barWindow.notchBlack || barWindow.notchClear
      color: barWindow.notchBlack ? "black" : "transparent"
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; enabled: barWindow.notchRole === "fullpanel" }
    }
''')

    # 7. Toasts on the display whose bar is parked in the notch strip keep
    #    only the normal gap; under FullPanel's bar, which is as tall as the
    #    strip (parkedSize), the strip's height and the gap, not the bar's
    #    size and the gap (that put them into the bar). Omarchy's
    #    notifications ask the bar how much room it takes on a screen
    #    (barSizeFor) from about October 2026; a bar from before has no such
    #    function, so it gets one (an older notification service reads
    #    barSize: guest/omanotch-notifications.sh).
    room = '''    // omarchy-notch-bar: a bar parked in the notch strip takes no room here,
    // FullPanel's bar the whole strip (its parkedSize).
    // No room is the smallest number above 0, which is 0 in any sum: Omarchy
    // 4.5 takes 0 for no answer and clears the default bar size instead.
    if (root.notchParked && String(screenName) === root.notchParkedScreen) return Number.MIN_VALUE
    if (root.notchRoleFor({ name: String(screenName) }) === "fullpanel")
      return root.notchBox(0, root.notchHeight, 0, root.barSize, 1)[0]
'''
    stock_room = "  function barSizeFor(screenName) {\n"
    if text.count(stock_room) == 1:
        text = text.replace(stock_room, stock_room + room)
    else:
        text = replace_once(text, "  // --- end omarchy-notch-bar --------------------------------------------\n", '''  // The room the bar takes on a screen, for Omarchy's notifications.
''' + stock_room + room + '''    return root.barSize
  }
  // --- end omarchy-notch-bar --------------------------------------------
''')

    # 8. Skip the notch, the lists: a list takes its items' places from the
    #    bar (notchShift) and, laid out in a row, says how wide its items are.
    text = lists_45(text) if form45 else lists_40(text)

    # 9. Skip the notch, each item: moved by a transform (what it draws, its
    #    hover, clicks, popups and Omanotch's click map all follow it), and
    #    see-through without input when hidden. Not invisible: an item's
    #    width depends on its own visible, which would loop.
    slot_heads = ['''  component ModuleSlot: Item {
    id: slot

    required property var entry
    property string region: ""
''', '''  component ModuleSlot: Item {
    id: slot

    property string widgetKey: ""
    property string region: ""
''']
    slot_body = '''    // omarchy-notch-bar: Skip the notch: {x, hidden, n, animate} for this
    // item on a bar in the notch strip; null elsewhere (Omarchy's place).
    property int notchSlotIndex: -1
    property var notchShift: null
    property bool notchShiftGone: false
    // Omarchy's indicators: the block of their hidden ones (they show on
    // hover), its whole width and how much of it shows now; none for every
    // other widget. Where the layout opens it elsewhere (peekAt, left of the
    // housing), it moves by a transform of its own, set on Omarchy's item;
    // with no room there it stays hidden (see-through, no input).
    readonly property var notchPeekBlock: activeItem && activeItem.revealInactiveIndicators !== undefined
      ? root.notchPeekBlockIn(activeItem, 0) : null
    readonly property real notchPeekFull: notchPeekBlock ? notchPeekBlock.implicitWidth : 0
    readonly property real notchPeekShown: notchPeekBlock && notchPeekBlock.parent ? notchPeekBlock.parent.width : 0
    // Their width at rest: the block of the ones that show (the other child of
    // their row). It does not change on a peek, so every step of one sees the
    // same decisions (the slot's width and the hidden ones' area change one
    // after the other, which once moved the weather and glided it back).
    readonly property var notchPeekActive: notchPeekBlock && notchPeekBlock.parent
      ? root.notchPeekActiveIn(notchPeekBlock.parent) : null
    readonly property real notchPeekRest: notchPeekActive ? notchPeekActive.implicitWidth : implicitWidth - notchPeekShown
    property real notchPeekOffset: 0
    // Its own size at the last place (the size it asks for, which its list
    // counts; a tray's also with its drawer open): a move it caused itself
    // is at once, only moves of items pushed by others glide.
    property real notchLastWidth: 0
    readonly property real notchOpenExtent: activeItem && root.notchIsTray(activeItem) ? Number(activeItem.drawerExtent) || 0 : 0
    property real notchLastOpen: 0
    // When it last changed: the layout settles its decisions one round later
    // (notchSkipKeep), and that move is still its own (100 ms). Any other
    // move of this item in those 100 ms is at once too.
    property real notchOwnAt: 0
    // An item that shows up (its widget had no width, as Omarchy's tray before
    // its first app) waits unseen at its place until that place has been
    // quiet for 150 ms, then shows there: apps that register one by one give
    // one showing, where the tray stays. Only its own place counts (other
    // items changing size do not), and it shows after 1 s at the latest.
    // Never on a drag (the widget keeps its width) or the indicators' peek or
    // a drawer's slide (they never start from no width).
    readonly property real notchContentWidth: NOTCH_CONTENT_WIDTH
    property real notchLastContent: 0
    property bool notchAppearing: false
    property real notchAppearEdge: 0
    property bool notchAppearGone: false
    Timer {
      id: notchShowEnd
      interval: 150
      onTriggered: slot.notchShowNow()
    }
    Timer {
      id: notchShowLimit
      interval: 1000
      onTriggered: slot.notchShowNow()
    }
    function notchShowNow() {
      if (!notchAppearing) return
      notchShowEnd.stop()
      notchShowLimit.stop()
      notchFade.enabled = true
      notchAppearing = false
      // While Omarchy makes the list again, onNotchHoldChanged places it.
      if (!notchHold) notchSettle()
    }
    readonly property real notchPeekDx: notchShift && notchShift.peekAt !== undefined
      ? notchShift.peekAt - (notchShownX - (notchEnd ? width : 0) + notchPeekOffset) : 0
    Translate { id: notchPeekMove; x: slot.notchPeekDx }
    function notchPeekApply() {
      var area = notchPeekBlock ? notchPeekBlock.parent : null
      if (!area || !area.parent) return
      var s = notchShift, gone = !!(s && s.peekHidden)
      notchPeekOffset = area.parent.mapToItem(slot, area.x, 0).x
      area.transform = s && s.peekAt !== undefined ? [notchPeekMove] : []
      area.opacity = gone ? 0 : 1
      area.enabled = !gone
    }
    onNotchPeekBlockChanged: notchPeekApply()
    // Where the item shows on the bar (notchShownX, its kept edge) and
    // Omarchy's place for it (n), both in bar coordinates from the layout: a
    // new place glides from where the item showed, also while Omarchy's row
    // moves under it. Omarchy's own moves stay instant.
    property real notchShownX: 0
    property real notchPlaceX: 0
    property real notchShiftX: 0
    property bool notchPlaced: false
    property var notchShown: null
    property bool notchHold: false
    property bool notchNew: false
    onNotchHoldChanged: if (!notchHold) {
      if (notchNew) {
        notchFade.enabled = true
        notchNew = false
      }
      notchSettle()
    }
    // The edge an item keeps when its own width changes, as Omarchy aligns
    // it: a right side's item its end (it grows to the left), others their
    // start. notchShownX is that edge on the bar.
    readonly property bool notchEnd: region === "right"
    function notchEdge(s) { return s.n + s.x + (notchEnd ? width : 0) }
    transform: Translate { x: slot.notchShift ? slot.notchShownX - (slot.notchEnd ? slot.width : 0) - slot.notchPlaceX : 0 }
    opacity: slot.notchShiftGone || slot.notchNew || slot.notchAppearing ? 0 : 1
    enabled: !slot.notchShiftGone && !slot.notchAppearing
    Behavior on notchShownX {
      id: notchSlide
      enabled: false
      NumberAnimation { id: notchSlideRun; duration: 220; easing.type: Easing.OutCubic }
    }
    Behavior on opacity {
      id: notchFade
      enabled: false
      NumberAnimation { duration: 160 }
    }
    onNotchShiftChanged: {
      // Omarchy's row places its items once per frame. A bar that draws no
      // frame now (the parked copy, 1 px tall) would keep the old places
      // under the new shift until it does: place them now.
      if (parent && typeof parent.forceLayout === "function") parent.forceLayout()
      // Omarchy 4.5's GridLayout: its polish places them.
      else if (parent && typeof parent.ensurePolished === "function") parent.ensurePolished()
      var s = notchShift
      var gone = !!(s && s.hidden), animate = !!(s && s.animate)
      // Its own size changed (the indicators' peek, a tray's new app, a
      // widget that grew): it takes its new place at once, as its own row
      // moves inside it at once.
      if (notchPlaced && (implicitWidth !== notchLastWidth || notchOpenExtent !== notchLastOpen)) notchOwnAt = Date.now()
      var own = Date.now() - notchOwnAt < 100
      var appeared = notchPlaced && notchLastContent <= 0 && notchContentWidth > 0
      notchLastWidth = implicitWidth
      notchLastOpen = notchOpenExtent
      notchLastContent = notchContentWidth
      var placed = notchPlaced
      notchPlaced = !!s
      notchFade.enabled = placed && animate
      if (!s) {
        if (notchShiftGone) notchShiftGone = false
        notchSlide.enabled = false
        notchShiftX = 0
        notchPlaceX = 0
        notchShownX = 0
        notchPeekApply()
        return
      }
      // Only our own moves glide (an item in Omarchy's place before and after
      // moves as Omarchy moves it), and only once this round of changes is
      // over: while Omarchy makes its list again (a module came or went) the
      // layout passes through places that are not the end. Until then the
      // item stays where it shows. A slot Omarchy made again starts where
      // this module showed last (else at its place at once, not from the
      // bar's edge).
      // A glide on its way keeps going and takes the new end then.
      var was = !placed && notchShown ? notchShown[moduleName] : undefined
      if (notchHold && animate) {
        // Omarchy is making the list again: stay where this module showed
        // (a new one waits unseen); onNotchHoldChanged moves it once.
        notchSlide.enabled = notchSlideRun.running
        if (!placed) {
          notchShownX = was !== undefined ? was.x : notchEdge(s)
          notchNew = was === undefined
        }
        notchPlaceX = s.n
        notchShiftX = s.x
        notchPeekApply()
        return
      }
      if (gone !== notchShiftGone) notchShiftGone = gone
      if (notchAppearing || (appeared && animate)) {
        // It showed up: unseen at its place until that is quiet (notchShowEnd),
        // at most 1 s (notchShowLimit). Only a change of its own place (its
        // kept edge, or hidden) starts the 150 ms again.
        var edge = notchEdge(s)
        notchFade.enabled = false
        if (!notchAppearing) {
          notchAppearing = true
          notchShowLimit.restart()
          notchShowEnd.restart()
        } else if (Math.abs(edge - notchAppearEdge) > 0.01 || gone !== notchAppearGone) notchShowEnd.restart()
        notchAppearEdge = edge
        notchAppearGone = gone
        notchSlide.enabled = false
        notchPlaceX = s.n
        notchShiftX = s.x
        notchShownX = notchEdge(s)
        notchPeekApply()
        return
      }
      var ours = s.x !== 0 || (placed ? notchShiftX !== 0 : !!(was && was.ours))
      var glide = animate && ours && !own, running = notchSlideRun.running
      if (!running) notchSlide.enabled = false
      notchPlaceX = s.n
      if (!placed) notchShownX = glide && was !== undefined ? was.x : notchEdge(s)
      notchShiftX = s.x
      if (!glide && !running) notchShownX = notchEdge(s)
      Qt.callLater(notchSettle)
      notchPeekApply()
    }
    // The end of a round of changes: glide to the place the layout ended on
    // (one move), and remember it for a slot Omarchy makes again.
    function notchSettle() {
      // Qt.callLater may run it after Omarchy took the slot away (its
      // functions are gone then).
      if (typeof notchEdge !== "function") return
      var s = notchShift
      if (!s) return
      if (!!s.hidden !== notchShiftGone) notchShiftGone = !!s.hidden
      var to = notchEdge(s)
      if (Math.abs(notchShownX - to) > 0.01) {
        notchSlide.enabled = !!s.animate && Date.now() - notchOwnAt >= 100
        notchShownX = to
      }
      if (notchShown) notchShown[moduleName] = { x: to, ours: s.x !== 0 || s.hidden === true }
    }
'''
    # The widget's own width: 4.5's slot has it apart from the length it asks
    # for (which a drag or a removal changes); 4.0's slot is its widget's.
    slot_body = slot_body.replace("NOTCH_CONTENT_WIDTH", "widgetWidth" if form45 else "implicitWidth")
    text = replace_variant(text, [(h, h + slot_body) for h in slot_heads], "the module slot")
    text = replace_once(text, '''    z: modulePointer.dragging ? 100 : 0
''', '''    // omarchy-notch-bar: while the indicators' hidden ones open elsewhere,
    // their slot (which Omarchy's row still makes room for, under the
    // neighbours we keep in place) lies under those neighbours: the tray's
    // expander and the weather keep their own hover and clicks.
    z: modulePointer.dragging ? 100 : (slot.notchShift && slot.notchShift.peekAt !== undefined ? -1 : 0)
''')

    # 10. Omarchy 4.5's indicator peek where the indicators are (#763, #764).
    if form45:
        text = peek_45(text)

    open(path, "w").write(text)
    print("patched")


if __name__ == "__main__":
    main()
