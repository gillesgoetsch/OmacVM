import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Per-monitor workspaces (see ~/.config/hypr/monitor_workspaces.lua): the
// main display (Virtual-1, the VM window) owns workspace IDs 1..10,
// Virtual-2 11..20, Virtual-3 21..30 and so on. Each bar shows only its own
// monitor's range and labels it 1..0, so the offset never shows. Omanotch's hidden NOTCH*
// output stands in for Virtual-1. Keep laptop/offset in sync with the Lua file.
BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  readonly property string laptop: "Virtual-1"
  readonly property int offset: 10

  // QsWindow is not attached yet while the widget is created; guard it so the
  // bindings below re-evaluate once it is, instead of failing for good.
  readonly property var barScreen: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null
  readonly property bool laptopBar: !barScreen || barScreen.name === laptop || barScreen.name.indexOf("NOTCH") === 0
  readonly property var monitor: laptopBar ? laptopMonitor() : Hyprland.monitorFor(barScreen)
  readonly property int base: laptopBar ? 0 : offsetOf(barScreen.name)

  // Virtual-N: (N-1) * offset; another external name counts as the second.
  function offsetOf(name) {
    var m = /^Virtual-(\d+)$/.exec(String(name || ""))
    var n = m ? parseInt(m[1], 10) : 2
    return (n >= 2 ? n - 1 : 1) * root.offset
  }

  function laptopMonitor() {
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].name === root.laptop) return values[i]
    }

    return null
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var n = values[i].id - root.base
      if (n > 0 && n <= 10 && ids.indexOf(n) === -1) ids.push(n)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        required property int modelData

        readonly property int workspaceId: modelData + root.base
        readonly property var workspace: root.workspaceById(workspaceId)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        // The workspace this monitor shows, whether or not it has focus.
        readonly property bool focused: root.monitor !== null && root.monitor.activeWorkspace !== null && root.monitor.activeWorkspace.id === workspaceId

        bar: root.bar
        text: focused ? "󱓻" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(workspaceId) }
      }
    }
  }
}
