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
// What omacvm-bridge's audio does not have comes from OmacVM.app (Sound.qml):
// the AirPlay speakers of macOS's own Sound list, the modes of headphones such
// as AirPods, and the output's balance.
//
// As calm as the Sound module of the Mac's Control Center: no status line
// and no numbers beside the sliders, and one output list, the Mac's outputs
// and after a divider the AirPlay speakers.
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
  Sound { id: sound }

  // `bar` is null while there is no bar: Omarchy's bar sets it from outside,
  // and when the shell reloads a plugin in place (a widget or the bar copy
  // written, Update VM) the old bar goes before its widgets. Then Omarchy's
  // own bar colours and font, so no binding reads a property of null.
  readonly property color barFg: bar ? bar.foreground : Commons.Color.bar.text
  readonly property color barUrgent: bar ? bar.urgent : Commons.Color.bar.active
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

  // The output list: the Mac's outputs, then what only macOS's Sound list
  // offers (AirPlay speakers, or the row that says how to allow them). One
  // list for the cursor (outputStops): each row, and under the output that
  // plays each group of its modes, such as AirPods' Listening Mode.
  property var displayOutputs: []
  property var displayAirplay: []
  property var displayInputs: []
  property var outputStops: []
  // On a group of modes: the option under the cursor (h/l), pressed by Enter.
  property int optionIndex: -1

  // The output the panel last read macOS's Sound list for in this opening,
  // "" when its list may lack the modes of headphones, or null before its
  // first read (Model.listRead, Model.listAnswered).
  property var listOutput: null
  // The balance the app read for the output that plays now.
  readonly property bool showBalance: available && sound.available && !!sound.balance && !!output && output.uid === sound.output
  readonly property bool balanceAdjustable: showBalance && sound.balance.settable === true

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Single cursor model shared by keyboard and mouse. Sections:
  //   "output"  — output slider + output device list
  //   "balance" — balance slider
  //   "input"   — input slider + input device list
  // selectedIndex semantics within a section:
  //   -1            → on the slider row (h/l adjusts, m/Enter mute, Enter
  //                   centres the balance)
  //   0..N-1        → on the Nth device row (output: the Nth of outputStops,
  //                   a row or a group of modes)
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
      // Another output has another balance, or none, and its modes are read
      // only once the app names it too.
      if (root.opened && sound.available && root.output && root.output.uid !== sound.output) sound.refresh()
      root.refreshDisplayModels()
      // Headphones that play now may have modes, which only a read has.
      root.askForList()
    }
    function onBluetoothChanged() { root.refreshDisplayModels() }
  }

  Connections {
    target: sound
    function onAnswered(request) {
      root.listOutput = Model.listAnswered(root.listOutput, request, sound.output)
      // An answer may name the output from before the Bridge's last report.
      if (request !== "" && root.opened && root.output && root.output.uid !== sound.output) sound.refresh()
      root.refreshDisplayModels()
      root.askForList()
    }
    function onReadingChanged() { root.refreshDisplayModels() }
    // Also when the app is free again: onAnswered starts the read only while
    // Quickshell ends a process before the handler of its output runs, as
    // 0.3.2 does. A second ask is harmless, as Sound.read refuses while busy.
    function onBusyChanged() { root.askForList() }
  }

  function refreshDisplayModels() {
    var lists = Model.outputLists(bridge.audio, bridge.bluetooth, available && sound.available ? sound : null)
    // The cursor stays on its row or group when rows come or go above it, as
    // when a read adds the modes of AirPods, so Enter acts on what it shows.
    var was = focusSection === "output" && selectedIndex >= 0 ? outputStops[selectedIndex] : null
    var option = optionIndex
    outputStops = Model.outputStops(lists.outputs, lists.airplay)
    displayOutputs = lists.outputs
    displayAirplay = lists.airplay
    displayInputs = Model.deviceRows(bridge.audio, false)
    var at = was ? Model.stopIndex(outputStops, was) : -1
    if (at >= 0) selectedIndex = at
    clampCursor()
    var group = cursorGroup()
    if (group) optionIndex = Model.optionCursor(group, at >= 0 ? option : optionIndex, 0)
  }

  // Once per opening, as the Mac's own Sound module does when it opens, and
  // once more for headphones that begin to play (Model.listRead). The app
  // opens Control Center on the Mac for it, which takes the Mac's keyboard
  // for about a second; until it answers, the panel shows the list of the
  // last opening.
  function askForList() {
    if (!opened || !available || !sound.available || !sound.accessibility) return
    var uid = Model.listRead(listOutput, output, sound.output)
    if (uid !== null && sound.read()) listOutput = uid
  }

  function sectionCount(section) {
    if (section === "output") return outputStops.length
    if (section === "input") return displayInputs.length
    return 0
  }

  function sectionVisible(section) {
    if (section === "output") return true
    if (section === "balance") return showBalance
    if (section === "input") return displayInputs.length > 0 || hasInput
    return false
  }

  function sectionHasSlider(section) {
    if (section === "output" || section === "balance") return true
    if (section === "input") return hasInput
    return false
  }

  readonly property var visibleSections: {
    var list = []
    var all = ["output", "balance", "input"]
    for (var i = 0; i < all.length; i++) if (sectionVisible(all[i])) list.push(all[i])
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

  // The group of modes under the cursor, or null.
  function cursorGroup() {
    var stop = focusSection === "output" && selectedIndex >= 0 ? outputStops[selectedIndex] : null
    return stop ? stop.group : null
  }

  // Arriving on a group of modes, the cursor is on the option macOS selected.
  onSelectedIndexChanged: optionIndex = Model.optionCursor(cursorGroup(), -1, 0)
  onFocusSectionChanged: optionIndex = Model.optionCursor(cursorGroup(), -1, 0)

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    selectedIndex = -1
  }

  function adjustVolume(delta) {
    var group = cursorGroup()
    if (group) {
      optionIndex = Model.optionCursor(group, optionIndex, delta > 0 ? 1 : -1)
      return
    }
    if (focusSection === "output" && selectedIndex === -1) {
      setOutputVolume(outputVolume + delta)
      return
    }
    if (focusSection === "balance") {
      sound.setBalance(sound.balanceValue + delta)
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
      var stop = outputStops[selectedIndex]
      if (stop && stop.group) setMode(stop.row, stop.group, optionIndex)
      else if (stop) setDefaultOutput(stop.row)
      return
    }
    if (focusSection === "balance") { sound.setBalance(0.5); return }
    if (focusSection === "input") {
      if (selectedIndex === -1) { toggleInputMute(); return }
      var src = displayInputs[selectedIndex]
      if (src) setDefaultInput(src)
    }
  }

  onOpenedChanged: {
    if (opened) {
      listOutput = null
      // A list's answer has the state too. The state alone is asked while
      // the app is not known to answer or to be allowed, which may have
      // changed since.
      if (sound.available && sound.accessibility) askForList()
      else sound.refresh()
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

  // An output CoreAudio knows is switched by its uid. One that only macOS's
  // Sound list offers is pressed there, as a click on the Mac would: an
  // AirPlay speaker that plays stops, another one starts, also next to the
  // ones that play. The row that says how to allow AirPlay opens the Mac's
  // settings for it.
  function setDefaultOutput(row) {
    if (!row) return
    if (row.allow) { sound.allow(); return }
    if (row.picker) { sound.press(row.name); return }
    if (row.uid && !row.active) Quickshell.execDetached(["omacvm-bridge", "output", row.uid])
  }

  // macOS's own press of a mode's option, as a click in Control Center. Also
  // one the panel shows as selected: the headphones may have switched since
  // the list was read, and the app presses only what macOS has not selected.
  function setMode(row, group, index) {
    var option = group && group.options[index]
    if (option && option.enabled) sound.mode(row.name, group.title, option.title)
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
            implicitHeight: Math.max(heroIcon.implicitHeight, heroTitle.implicitHeight, powerSwitch.implicitHeight)

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

            Text {
              id: heroTitle
              text: root.available ? "Audio" : "Mac unavailable"
              color: root.barFg
              font.family: root.barFont
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
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

            PanelSectionHeader {
              text: "OUTPUT"
              foreground: root.barFg
              fontFamily: root.barFont
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

            // The output that plays has its modes under its row.
            Repeater {
              model: root.displayOutputs

              Column {
                id: outputItem
                required property var modelData
                width: panelColumn.width
                spacing: Style.space(6)

                SinkRow {
                  width: parent.width
                  device: outputItem.modelData
                  rowIndex: outputItem.modelData.stop
                }

                Repeater {
                  model: outputItem.modelData.modes || []

                  ModeGroup {
                    required property var modelData
                    width: parent.width
                    device: outputItem.modelData
                    group: modelData
                  }
                }
              }
            }

            // What only macOS's Sound list offers: AirPlay speakers.
            PanelSeparator {
              visible: root.displayAirplay.length > 0
              foreground: root.barFg
            }

            Repeater {
              model: root.displayAirplay

              SinkRow {
                required property var modelData
                width: panelColumn.width
                device: modelData
                rowIndex: modelData.stop
              }
            }

            Text {
              visible: sound.failure !== ""
              width: parent.width
              leftPadding: Style.space(6)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: Model.soundFailureText(sound.failure)
              color: root.barUrgent
              font.family: root.barFont
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ---- Balance of the output, where it has one ----
          Column {
            visible: root.showBalance
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "BALANCE"
              foreground: root.barFg
              fontFamily: root.barFont
            }

            CursorSurface {
              id: balanceSliderRow
              width: parent.width
              height: balanceSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "balance"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(balanceSliderRow)
              foreground: root.barFg
              outline: true

              // No fill: a balance is a place between left and right, not a level.
              PanelSlider {
                id: balanceSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 1
                step: 0.05
                tickCount: 3
                fillColor: "transparent"
                value: sound.balanceValue
                opacity: root.balanceAdjustable ? 1.0 : 0.5
                enabled: root.balanceAdjustable

                onMoved: function(v) { sound.setBalance(v) }
                onRightClicked: sound.setBalance(0.5)
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "balance"
                  root.selectedIndex = -1
                }
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

            PanelSectionHeader {
              text: "INPUT"
              foreground: root.barFg
              fontFamily: root.barFont
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

  // What a device row ends with: macOS's checkmark on the one that plays, and
  // a spinner while macOS connects it.
  component RowMark: Item {
    property bool active: false
    property bool busy: false
    width: Style.space(22)
    height: mark.implicitHeight
    anchors.verticalCenter: parent.verticalCenter

    Text {
      id: mark
      visible: parent.active && !parent.busy
      textFormat: Text.PlainText
      text: "󰄬"
      color: root.barFg
      font.family: root.barFont
      font.pixelSize: Style.font.title
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }

    Spinner {
      visible: parent.busy
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component Spinner: Text {
    id: spinner
    textFormat: Text.PlainText
    text: ""
    color: root.barFg
    font.family: root.barFont
    font.pixelSize: Style.font.title
    transformOrigin: Item.Center

    RotationAnimation on rotation {
      from: 0
      to: 360
      duration: Style.duration(900)
      loops: Animation.Infinite
      running: root.opened && spinner.visible && Style.duration(900) > 0
    }
  }

  // Output device row — cursor target inside the "output" section.
  component SinkRow: CursorSurface {
    id: sinkRow
    required property var device
    required property int rowIndex

    readonly property bool isActive: !!(device && device.active)
    // The press of this device is on its way: macOS connects it.
    readonly property bool isBusy: !!(device && device.picker && sound.pressing === device.name)
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
        width: parent.width - 2 * (Style.space(22) + Style.space(8))
        anchors.verticalCenter: parent.verticalCenter
      }

      RowMark {
        active: sinkRow.isActive
        busy: sinkRow.isBusy
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

  // A group of the modes of the output that plays, under its row: macOS's
  // title for it, quiet, and its options in one line, as a segmented control
  // without borders (Omarchy's Button), wrapped when they do not fit. Title
  // and options start on the edge of the row's name. The selected option has
  // the fill and the weight of the output that plays; an option macOS shows
  // but does not offer is dimmed and takes no press. One
  // cursor stop: h/l walks the options, Enter or a click presses one, as a
  // click in Control Center. The press on its way is the group's spinner, at
  // the rows' checkmarks; the selection is macOS's word.
  component ModeGroup: Item {
    id: modeGroup
    required property var device
    required property var group

    readonly property bool hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === group.stop
    readonly property bool busy: !!sound.switching && sound.switching.device === device.name && sound.switching.group === group.title
    // The rows' name edge, and an option's text on it: its fill reaches out by its padding.
    readonly property real inset: Style.space(6) + Style.space(22) + Style.space(8)
    readonly property real optionPadding: Style.space(6)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(modeGroup)
    implicitHeight: options.y + options.implicitHeight

    Text {
      id: groupTitle
      x: modeGroup.inset
      width: modeGroup.width - x - Style.space(6) - Style.space(22) - Style.space(8)
      textFormat: Text.PlainText
      text: modeGroup.group.title
      color: root.barFg
      opacity: 0.6
      font.family: root.barFont
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Spinner {
      visible: modeGroup.busy
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: groupTitle.verticalCenter
    }

    Flow {
      id: options
      x: modeGroup.inset - modeGroup.optionPadding
      y: groupTitle.implicitHeight + Style.space(2)
      width: modeGroup.width - x - Style.space(6)

      Repeater {
        model: modeGroup.group.options

        Button {
          required property var modelData
          required property int index
          text: modelData.title
          fontSize: Style.font.bodySmall
          foreground: root.barFg
          fontFamily: root.barFont
          horizontalPadding: modeGroup.optionPadding
          verticalPadding: Style.space(3)
          selected: modelData.selected && modelData.enabled
          enabled: modelData.enabled
          opacity: modelData.enabled ? 1.0 : 0.5
          hasCursor: modeGroup.hasCursor && root.optionIndex === index
          onClicked: root.setMode(modeGroup.device, modeGroup.group, index)
          onHovered: function(h) {
            if (!h) return
            root.cursorActive = true
            root.focusSection = "output"
            root.selectedIndex = modeGroup.group.stop
            root.optionIndex = index
          }
        }
      }
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
        width: parent.width - 2 * (Style.space(22) + Style.space(8))
        anchors.verticalCenter: parent.verticalCenter
      }

      RowMark { active: sourceRow.isActive }
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
