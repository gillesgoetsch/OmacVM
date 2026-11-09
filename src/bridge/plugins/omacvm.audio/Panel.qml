// Derived from Omarchy's omarchy.audio widget.
// Copyright (c) David Heinemeier Hansson. MIT License, see LICENSE.
//
// Controls the Mac's audio (via the omacvm-bridge helper) instead of the VM's
// PipeWire graph: in the VM the VM's own volume is just a
// pass-through, and the loudness people hear is the Mac's. Layout, components
// and keyboard model follow the native widget. The per-app list is left out:
// it describes the VM's own streams, not the Mac's.
//
// The input meter is the one exception that reads the VM side: the VM app
// feeds the Mac's current input into the VM, so PipeWire's default source
// carries exactly what apps in the VM hear. It shows once PipeWire has that
// source (pipewire-alsa/-pulse installed) and is left out otherwise.
//
// The volume popup is not shown from here: omacvm-bridge-osd already shows
// Omarchy's OSD for every volume change the helper reports.
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
// Qt 6.12's QtQuick has a Color of its own, which hides Omarchy's (#376).
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.audio"
  ipcTarget: "omarchy.audio"

  Bridge { id: bridge }

  // `bar` is null while there is no bar: Omarchy's bar sets it from outside,
  // and when the shell reloads a plugin in place (a widget or the bar copy
  // written, Update VM) the old bar goes before its widgets. Then Omarchy's
  // own bar colours and font, so no binding reads a property of null.
  readonly property color barFg: bar ? bar.foreground : Commons.Color.bar.text
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family

  readonly property bool available: bridge.available && !!bridge.audio
  readonly property var audio: bridge.audio || ({})
  readonly property var output: audio.output || null
  readonly property var input: audio.input || null

  readonly property bool hasOutput: available && !!output
  readonly property bool hasInput: available && !!input
  readonly property bool outputAdjustable: hasOutput && output.has_volume !== false && output.volume_settable !== false
  readonly property bool inputAdjustable: hasInput && input.has_volume !== false && input.volume_settable !== false
  readonly property bool outputMutable: hasOutput && output.has_mute !== false
  readonly property bool inputMutable: hasInput && input.has_mute !== false

  // Slider moves are sent to the Mac a few times a second at most; until the
  // helper echoes the change back, the panel shows the value asked for.
  property real pendingOutputVolume: -1
  property real pendingInputVolume: -1

  readonly property real outputVolume: pendingOutputVolume >= 0 ? pendingOutputVolume
    : (hasOutput ? Model.clamp01(output.volume) : 0)
  readonly property bool outputMuted: hasOutput ? !!output.muted : false
  readonly property real inputVolume: pendingInputVolume >= 0 ? pendingInputVolume
    : (hasInput ? Model.clamp01(input.volume) : 0)
  readonly property bool inputMuted: hasInput ? !!input.muted : false

  // VM-side capture of the Mac's input, for the level meter only. Never
  // adjusted from here: the Mac owns the gain.
  readonly property var meterSource: Pipewire.defaultAudioSource
  readonly property bool hasMeter: !!(meterSource && meterSource.audio)

  property var displayOutputs: []
  property var displayInputs: []

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Single cursor model shared by keyboard and mouse. Sections:
  //   "output"  — output slider + output device list
  //   "input"   — input slider + input device list
  // selectedIndex semantics within a section:
  //   -1            → on the slider row (h/l adjusts volume, m/Enter mute)
  //   0..N-1        → on the Nth device row
  property string focusSection: "output"
  property int selectedIndex: -1
  property bool cursorActive: false

  // "header" is a virtual section for the hero mute toggle.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property bool anyAudible: (hasOutput && !outputMuted) || (hasInput && !inputMuted)
  readonly property string toggleHint: anyAudible ? "Mute" : "Unmute"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"

  Connections {
    target: bridge
    function onAudioChanged() {
      if (!outputVolumeSend.running && !outputVolumeProc.running) root.pendingOutputVolume = -1
      if (!inputVolumeSend.running && !inputVolumeProc.running) root.pendingInputVolume = -1
      root.refreshDisplayModels()
    }
  }

  function refreshDisplayModels() {
    displayOutputs = Model.deviceRows(bridge.audio, true)
    displayInputs = Model.deviceRows(bridge.audio, false)
    clampCursor()
  }

  function sectionCount(section) {
    if (section === "output") return displayOutputs.length
    if (section === "input") return displayInputs.length
    return 0
  }

  function sectionVisible(section) {
    if (section === "output") return true
    if (section === "input") return displayInputs.length > 0 || hasInput
    return false
  }

  function sectionHasSlider(section) {
    if (section === "output") return true
    if (section === "input") return hasInput
    return false
  }

  readonly property var visibleSections: {
    var list = []
    if (sectionVisible("output")) list.push("output")
    if (sectionVisible("input")) list.push("input")
    return list
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    if (focusSection === "header") {
      if (delta > 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(sections[0]) ? -1 : 0 }
      return
    }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(focusSection) ? -1 : 0; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1
    var hasSlider = sectionHasSlider(focusSection)
    var floor = hasSlider ? -1 : 0

    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      }
    } else {
      if (idx > floor) { selectedIndex = idx - 1; return }
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        var prevMax = sectionCount(focusSection) - 1
        selectedIndex = prevMax >= 0 ? prevMax : (sectionHasSlider(focusSection) ? -1 : 0)
      } else {
        focusSection = "header"
      }
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    selectedIndex = -1
  }

  function adjustVolume(delta) {
    if (focusSection === "output" && selectedIndex === -1) {
      setOutputVolume(outputVolume + delta)
      return
    }
    if (focusSection === "input" && selectedIndex === -1) {
      setInputVolume(inputVolume + delta)
    }
  }

  function activateCursor() {
    if (focusSection === "header") { toggleAllMuted(); return }
    if (focusSection === "output") {
      if (selectedIndex === -1) { toggleOutputMute(); return }
      var out = displayOutputs[selectedIndex]
      if (out) setDefaultOutput(out)
      return
    }
    if (focusSection === "input") {
      if (selectedIndex === -1) { toggleInputMute(); return }
      var src = displayInputs[selectedIndex]
      if (src) setDefaultInput(src)
    }
  }

  onOpenedChanged: {
    if (opened) {
      refreshDisplayModels()
      focusSection = "output"
      selectedIndex = -1
      cursorActive = false
      Qt.callLater(resetScroll)
    }
  }

  function resetScroll() {
    if (!scrollArea) return
    var flick = scrollArea.contentItem
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var margin = 6
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= Style.space(24) || (root.focusSection === "output" && root.selectedIndex === -1)) {
      flick.contentY = 0
      return
    }
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    if (top < viewTop + margin) flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > viewBottom - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (focusSection === "header") return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = visibleSections[0]
      selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      return
    }
    var count = sectionCount(focusSection)
    var floor = sectionHasSlider(focusSection) ? -1 : 0
    if (selectedIndex > count - 1) selectedIndex = Math.max(floor, count - 1)
    if (selectedIndex < floor) selectedIndex = floor
  }

  function outputIcon(volume) {
    if (!hasOutput) return "󰖁"
    if (Model.isHeadphones(output)) return "󰋋"
    if (outputMuted) return "󰖁"
    var v = volume === undefined ? outputVolume : volume
    if (v >= 0.67) return "󰕾"
    if (v >= 0.34) return "󰖀"
    if (v > 0) return "󰕿"
    return "󰖁"
  }

  function outputVolumeName(volume, muted) {
    if (!available) return "Waiting for the Mac"
    return Model.outputVolumeName(volume, muted)
  }

  function percent(v) {
    return String(Math.round(Model.clamp01(v) * 100))
  }

  function setOutputVolume(v) {
    if (!outputAdjustable) return outputVolume
    var volume = Model.clamp01(v)
    pendingOutputVolume = volume
    outputVolumeSend.restart()
    return volume
  }

  function setInputVolume(v) {
    if (!inputAdjustable) return
    pendingInputVolume = Model.clamp01(v)
    inputVolumeSend.restart()
  }

  function toggleOutputMute() {
    if (outputMutable) Quickshell.execDetached(["omacvm-bridge", "mute", "toggle"])
  }

  function toggleInputMute() {
    if (inputMutable) Quickshell.execDetached(["omacvm-bridge", "mic-mute", "toggle"])
  }

  // The hero switch is the whole panel's on/off, so it carries both channels
  // at once. It reads as on while anything is still audible.
  function toggleAllMuted() {
    var state = anyAudible ? "on" : "off"
    if (outputMutable) Quickshell.execDetached(["omacvm-bridge", "mute", state])
    if (inputMutable) Quickshell.execDetached(["omacvm-bridge", "mic-mute", state])
  }

  function setDefaultOutput(row) {
    if (row && row.uid && !row.active) Quickshell.execDetached(["omacvm-bridge", "output", row.uid])
  }

  function setDefaultInput(row) {
    if (row && row.uid && !row.active) Quickshell.execDetached(["omacvm-bridge", "input", row.uid])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: root.meterSource ? [root.meterSource] : [] }

  PwNodePeakMonitor {
    id: inputPeakMonitor
    node: root.meterSource
    enabled: root.opened && root.hasMeter
  }

  // Coalesce slider drags: send the latest value once the previous request
  // has finished, instead of a process per pixel.
  Timer {
    id: outputVolumeSend
    interval: 60
    onTriggered: {
      if (outputVolumeProc.running) { restart(); return }
      if (root.pendingOutputVolume < 0) return
      outputVolumeProc.command = ["omacvm-bridge", "volume", root.percent(root.pendingOutputVolume)]
      outputVolumeProc.running = true
    }
  }

  Process { id: outputVolumeProc }

  Timer {
    id: inputVolumeSend
    interval: 60
    onTriggered: {
      if (inputVolumeProc.running) { restart(); return }
      if (root.pendingInputVolume < 0) return
      inputVolumeProc.command = ["omacvm-bridge", "mic-volume", root.percent(root.pendingInputVolume)]
      inputVolumeProc.running = true
    }
  }

  Process { id: inputVolumeProc }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.outputIcon()
    opacity: root.available ? 1.0 : 0.5
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAllMuted()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (!root.outputAdjustable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      var step = wheel.steps * 5
      Quickshell.execDetached(["omacvm-bridge", "volume", (step > 0 ? "+" : "") + step])
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustVolume(dx * 0.05)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "m" || t === "M") {
          if (!root.cursorActive) return
          if (root.focusSection === "input") root.toggleInputMute()
          else root.toggleOutputMute()
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: speaker icon · title/status ----------
          Item {
            id: heroItem
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.outputIcon()
              color: root.barFg
              font.family: root.barFont
              font.pixelSize: Style.font.display
              opacity: root.outputMuted || !root.available ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: powerSwitch
              visible: root.available
              checked: root.anyAudible
              hasCursor: root.headerHasCursor
              foreground: root.barFg
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) { if (on) root.setHeaderCursor() }
              onToggled: root.toggleAllMuted()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: root.barFont
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: root.available ? "Audio" : "Mac unavailable"
                color: root.barFg
                font.family: root.barFont
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: root.outputVolumeName(
                  outputSlider.dragging ? outputSlider.liveValue : root.outputVolume,
                  root.outputMuted
                ).toUpperCase()
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

          // ---- Output devices ----
          PanelSeparator {
            visible: root.available
            foreground: root.barFg
          }

          Column {
            visible: root.available
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(outputHeader.implicitHeight, outputPercent.implicitHeight)

              PanelSectionHeader {
                id: outputHeader
                text: "OUTPUT"
                foreground: root.barFg
                fontFamily: root.barFont
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: outputPercent
                textFormat: Text.PlainText
                text: root.outputAdjustable
                  ? Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100) + "%"
                  : "FIXED"
                color: Qt.darker(root.barFg, 1.4)
                font.family: root.barFont
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.outputMuted ? 0.5 : 1.0
              }
            }

            CursorSurface {
              id: outputSliderRow
              width: parent.width
              height: outputSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputSliderRow)
              foreground: root.barFg
              outline: true

              PanelSlider {
                id: outputSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.outputVolume
                opacity: root.outputMuted || !root.outputAdjustable ? 0.5 : 1.0
                enabled: root.outputAdjustable

                onMoved: function(v) { root.setOutputVolume(v) }
                onRightClicked: root.toggleOutputMute()
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "output"
                  root.selectedIndex = -1
                }
              }
            }

            Repeater {
              model: root.displayOutputs

              SinkRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                device: modelData
                rowIndex: index
              }
            }
          }

          // ---- Input ----
          PanelSeparator {
            visible: root.available && (root.displayInputs.length > 0 || root.hasInput)
            foreground: root.barFg
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.available && (root.displayInputs.length > 0 || root.hasInput)

            Item {
              width: parent.width
              implicitHeight: Math.max(microphoneHeader.implicitHeight, microphonePercent.implicitHeight)

              PanelSectionHeader {
                id: microphoneHeader
                text: "INPUT"
                foreground: root.barFg
                fontFamily: root.barFont
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: microphonePercent
                textFormat: Text.PlainText
                text: root.inputAdjustable
                  ? Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100) + "%"
                  : "FIXED"
                color: Qt.darker(root.barFg, 1.4)
                font.family: root.barFont
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.inputMuted ? 0.5 : 1.0
              }
            }

            CursorSurface {
              id: inputSliderRow
              visible: root.hasInput
              width: parent.width
              height: inputControls.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(inputSliderRow)
              foreground: root.barFg
              outline: true

              Column {
                id: inputControls
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(5)

                PanelSlider {
                  id: inputSlider
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  value: root.inputVolume
                  opacity: root.inputMuted || !root.inputAdjustable ? 0.5 : 1.0
                  enabled: root.inputAdjustable

                  onMoved: function(v) { root.setInputVolume(v) }
                  onRightClicked: root.toggleInputMute()
                }

                Rectangle {
                  visible: root.hasMeter
                  width: parent.width
                  height: Math.max(Style.space(5), Style.spacing.xs)
                  color: Util.alpha(root.barFg, 0.18)
                  opacity: root.inputMuted ? 0.35 : 1.0

                  Rectangle {
                    height: parent.height
                    width: parent.width * Math.max(0, Math.min(1, inputPeakMonitor.peak))
                    color: root.barFg
                    Behavior on width { NumberAnimation { duration: 70 } }
                  }
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "input"
                  root.selectedIndex = -1
                }
              }
            }

            Repeater {
              model: root.displayInputs

              SourceRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                device: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  // ---- Reusable inline components ----

  // Output device row — cursor target inside the "output" section.
  component SinkRow: CursorSurface {
    id: sinkRow
    required property var device
    required property int rowIndex

    readonly property bool isActive: !!(device && device.active)
    hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sinkRow)
    current: isActive
    foreground: root.barFg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sinkInner.implicitHeight + Style.spacing.xl

    Row {
      id: sinkInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.sinkGlyph(sinkRow.device)
        color: root.barFg
        font.family: root.barFont
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: sinkRow.device ? sinkRow.device.name : ""
        color: root.barFg
        font.family: root.barFont
        font.pixelSize: Style.font.body
        font.bold: sinkRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "output"
        root.selectedIndex = sinkRow.rowIndex
      }
      onClicked: root.setDefaultOutput(sinkRow.device)
    }
  }

  // Input device row — sibling of SinkRow for the "input" section.
  component SourceRow: CursorSurface {
    id: sourceRow
    required property var device
    required property int rowIndex

    readonly property bool isActive: !!(device && device.active)
    hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sourceRow)
    current: isActive
    foreground: root.barFg
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sourceInner.implicitHeight + Style.spacing.xl

    Row {
      id: sourceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.sourceGlyph(sourceRow.device)
        color: root.barFg
        font.family: root.barFont
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: sourceRow.device ? sourceRow.device.name : ""
        color: root.barFg
        font.family: root.barFont
        font.pixelSize: Style.font.body
        font.bold: sourceRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "input"
        root.selectedIndex = sourceRow.rowIndex
      }
      onClicked: root.setDefaultInput(sourceRow.device)
    }
  }
}
