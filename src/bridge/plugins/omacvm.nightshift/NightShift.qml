// The Mac's Night Shift in Omarchy's bar, with Omarchy's own night light icon
// (lit while Night Shift is on, dimmed while off). A click opens a panel in the
// style of Omarchy's display panel: Night Shift on/off, its strength and True
// Tone, all on the Mac. Middle click switches Night Shift right away, like
// Super+Ctrl+N (which OmacVM points at the Mac too). The state comes live from
// omacvm-bridge's event stream ("display" events), so changes made on the Mac
// show here at once.
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
// Qt 6.12's QtQuick has a Color of its own, which hides Omarchy's (#376).
import qs.Commons as Commons

Panel {
  id: root
  moduleName: "omacvm.nightshift"
  ipcTarget: "omacvm.nightshift"

  // `bar` is null while there is no bar: Omarchy's bar sets it from outside,
  // and when the shell reloads a plugin in place (a widget or the bar copy
  // written, Update VM) the old bar goes before its widgets. Then Omarchy's
  // own bar colours and font, so no binding reads a property of null.
  readonly property color barFg: bar ? bar.foreground : Commons.Color.bar.text
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family

  // ---- the Mac's display state (omacvm-bridge events) ----
  property bool available: false
  property bool nightShift: false
  property real strength: 0.5          // 0..1
  property bool trueToneAvailable: false
  property bool trueTone: false
  property string schedule: ""
  property string currentEvent: ""
  property real lastSeen: 0
  property real pendingStrength: -1    // shown until the Mac echoes it back

  // keyboard cursor: 0 Night Shift, 1 strength, 2 True Tone
  property int cursor: 0
  property bool cursorActive: false
  readonly property int rowCount: trueToneAvailable ? 3 : 2

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function scheduleText(s) {
    if (!s || !s.mode || s.mode === "off") return ""
    if (s.mode === "sunset-to-sunrise") return "Sunset to sunrise"
    if (s.from && s.to) return s.from + "–" + s.to
    return ""
  }

  // SplitParser hands the blank line that ends an SSE event over as a leading
  // "\n" on the next field, so trim before matching.
  function handleLine(raw) {
    var line = String(raw).replace(/^\s+|\r$/g, "")
    if (line.indexOf(":") === 0) { lastSeen = Date.now(); return }
    if (line.indexOf("event:") === 0) { currentEvent = line.substring(6).trim(); return }
    if (line.indexOf("data:") !== 0) return
    lastSeen = Date.now()
    if (currentEvent !== "display") return
    try {
      var d = JSON.parse(line.substring(5))
      if (d && d.night_shift) {
        nightShift = !!d.night_shift.enabled
        if (typeof d.night_shift.strength === "number") strength = d.night_shift.strength
        schedule = scheduleText(d.night_shift.schedule)
        available = d.night_shift.available !== false
      }
      if (d && d.true_tone) {
        trueToneAvailable = d.true_tone.available !== false && d.true_tone.supported !== false
        trueTone = !!d.true_tone.enabled
      }
      pendingStrength = -1
    } catch (e) {
    }
  }

  function reconnect() {
    available = false
    if (stream.running) stream.running = false
    if (!restart.running) restart.start()
  }

  function bridge(args) {
    Quickshell.execDetached(["omacvm-bridge"].concat(args))
  }

  function toggleNightShift() {
    if (!available) return
    nightShift = !nightShift          // the Mac's echo confirms it
    bridge(["night-shift", nightShift ? "on" : "off"])
  }

  function setStrength(v) {
    var p = Math.max(0, Math.min(100, Math.round(v)))
    pendingStrength = p / 100
    strengthSend.restart()
  }

  function toggleTrueTone() {
    if (!trueToneAvailable) return
    trueTone = !trueTone
    bridge(["true-tone", trueTone ? "on" : "off"])
  }

  function activateCursor() {
    if (cursor === 0) toggleNightShift()
    else if (cursor === 2) toggleTrueTone()
  }

  Process {
    id: stream
    command: ["omacvm-bridge", "events"]
    running: true
    onStarted: root.lastSeen = Date.now()
    onExited: root.reconnect()
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
  }

  Timer {
    id: restart
    interval: 3000
    onTriggered: if (!stream.running) stream.running = true
  }

  // The helper pushes Wi-Fi every few seconds: silence means the Mac is asleep
  // or the VM network is gone; reconnect once it answers again.
  Timer {
    interval: 5000
    repeat: true
    running: stream.running
    onTriggered: if (Date.now() - root.lastSeen > 20000) root.reconnect()
  }

  // Slider moves go to the Mac a few times a second at most.
  Timer {
    id: strengthSend
    interval: 120
    onTriggered: if (root.pendingStrength >= 0) root.bridge(["night-shift", "strength", String(Math.round(root.pendingStrength * 100))])
  }

  readonly property real shownStrength: pendingStrength >= 0 ? pendingStrength : strength

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔎"
    active: root.nightShift
    dimmed: !root.nightShift
    opacity: root.available ? 1.0 : 0.5
    tooltipText: !root.available ? "Night Shift (the Mac does not answer)"
      : (root.nightShift ? "Night Shift on (Mac)" : "Night Shift off (Mac)")
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.toggleNightShift()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.available) return
      root.setStrength(root.shownStrength * 100 + (delta > 0 ? 5 : -5))
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.cursor = Math.max(0, Math.min(root.rowCount - 1, root.cursor + dy))
        else if (dx !== 0 && root.cursor === 1) root.setStrength(root.shownStrength * 100 + dx * 5)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        // ---------- Hero: icon · title / state ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰔎"
            color: root.barFg
            opacity: root.nightShift ? 1.0 : 0.55
            font.family: root.barFont
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Night Shift"
              color: root.barFg
              font.family: root.barFont
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: !root.available ? "THE MAC DOES NOT ANSWER"
                : ((root.nightShift ? "ON" : "OFF") + " · THE MAC'S WHOLE SCREEN")
              color: Qt.darker(root.barFg, 1.4)
              font.family: root.barFont
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator { foreground: root.barFg }

        Toggle {
          width: parent.width
          label: "Night Shift"
          description: root.schedule !== "" ? "Warmer colors on the Mac · " + root.schedule : "Warmer colors on the Mac"
          foreground: root.barFg
          fontFamily: root.barFont
          checked: root.nightShift
          enabled: root.available
          hasCursor: root.cursorActive && root.cursor === 0
          onClicked: root.toggleNightShift()
          onHovered: function(h) { if (h) { root.cursorActive = true; root.cursor = 0 } }
        }

        // ---------- Strength ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(strengthHeader.implicitHeight, strengthValue.implicitHeight)

            PanelSectionHeader {
              id: strengthHeader
              text: "STRENGTH"
              foreground: root.barFg
              fontFamily: root.barFont
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: strengthValue
              textFormat: Text.PlainText
              text: Math.round(strengthSlider.dragging ? strengthSlider.liveValue : root.shownStrength * 100) + "%"
              color: Qt.darker(root.barFg, 1.4)
              font.family: root.barFont
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          CursorSurface {
            width: parent.width
            height: strengthSlider.implicitHeight + Style.spacing.controlGap
            hasCursor: root.cursorActive && root.cursor === 1
            foreground: root.barFg
            outline: true
            opacity: root.available ? 1.0 : 0.45

            PanelSlider {
              id: strengthSlider
              bar: root.bar
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              minimum: 0
              maximum: 100
              step: 1
              integer: true
              value: root.shownStrength * 100
              onReleased: function(v) { root.setStrength(v) }
            }

            HoverHandler {
              onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursor = 1 }
            }
          }
        }

        PanelSeparator {
          visible: root.trueToneAvailable
          foreground: root.barFg
        }

        Toggle {
          visible: root.trueToneAvailable
          width: parent.width
          label: "True Tone"
          description: "The Mac's display adapts to the light around it"
          foreground: root.barFg
          fontFamily: root.barFont
          checked: root.trueTone
          hasCursor: root.cursorActive && root.cursor === 2
          onClicked: root.toggleTrueTone()
          onHovered: function(h) { if (h) { root.cursorActive = true; root.cursor = 2 } }
        }

        Item { width: parent.width; height: Style.space(2) }
      }
    }
  }
}
