// Derived from Omarchy's omarchy.bluetooth widget.
// Copyright (c) David Heinemeier Hansson. MIT License, see LICENSE.
//
// Shows the Mac's Bluetooth (via the omacvm-bridge helper) instead of BlueZ:
// the VM has no Bluetooth of its own. Layout, components, phrases and the
// keyboard model follow the native widget: connected devices on top, paired
// ones below, Enter connects or disconnects, x forgets, b switches Bluetooth.
// Discovery is the one part left to the Mac: pairing a new device needs
// macOS's own dialog, so the last row opens the Mac's Bluetooth settings.
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
// Qt 6.12's QtQuick has a Color of its own, which hides Omarchy's (#376).
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.bluetooth"
  ipcTarget: "omarchy.bluetooth"
  // manageIpc: false so this panel can own the IpcHandler below (its own
  // target: a clone keeping the stock target would be ignored).
  manageIpc: false

  // `bar` is null while there is no bar: Omarchy's bar sets it from outside,
  // and when the shell reloads a plugin in place (a widget or the bar copy
  // written, Update VM) the old bar goes before its widgets. Then Omarchy's
  // own bar colours and font, so no binding reads a property of null.
  readonly property color barFg: bar ? bar.foreground : Commons.Color.bar.text
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
  readonly property color barUrgent: bar ? bar.urgent : Commons.Color.bar.active

  // ---- the Mac's Bluetooth (omacvm-bridge events) ----
  property bool available: false
  property var bt: null
  property string currentEvent: ""
  property real lastSeen: 0

  readonly property string kind: Model.kindFor(available, bt)
  readonly property bool btOn: kind === "on"
  readonly property bool granted: !!bt && bt.permission === "granted"
  readonly property bool powerSettable: !!bt && bt.power_settable === true
  readonly property bool forgetSupported: !!bt && bt.forget_supported === true

  readonly property var deviceGroups: Model.deviceLists(btOn ? bt : null)
  readonly property var connectedDevices: deviceGroups.connected
  readonly property var knownDevices: deviceGroups.known

  readonly property string icon: Model.iconFor(kind, connectedDevices.length)

  // Address -> "connecting" | "disconnecting" | "forgetting", while the Mac
  // catches up; address -> a short failure text, shown for a few seconds.
  property var pendingActions: ({})
  property var failures: ({})

  property int phraseIndex: 0
  readonly property var activePhrases: [
    "Untangling wires",
    "Streaming vikings",
    "Pairing mysteries",
    "Herding headsets",
    "Taming radios",
    "Summoning speakers",
    "Wrangling codecs",
    "Polishing packets"
  ]
  readonly property bool rotatingPhrases: btOn
  readonly property string heroStatusText: {
    if (kind === "unavailable") return "Waiting for the Mac"
    if (kind === "off") return "Turned off on the Mac"
    return activePhrases[phraseIndex % activePhrases.length]
  }

  // One cursor for keyboard and mouse, as in the native widget. Sections:
  //   "header"    — the hero on/off switch
  //   "connected" — connected devices; Enter disconnects
  //   "known"     — paired devices; Enter connects
  //   "pair"      — the "pair a new device" row; Enter opens the Mac's settings
  property string focusSection: "connected"
  property int selectedIndex: 0
  property bool actionFocused: false
  property bool cursorActive: false
  property string focusedDeviceAddress: ""

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property bool pairHasCursor: cursorActive && focusSection === "pair"
  readonly property string toggleHint: {
    if (!powerSettable) return "Bluetooth settings on the Mac"
    return btOn ? "Turn Bluetooth off on the Mac" : "Turn Bluetooth on on the Mac"
  }

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"

  function sectionCount(section) {
    if (section === "connected") return (connectedDevices || []).length
    if (section === "known") return (knownDevices || []).length
    if (section === "pair") return available ? 1 : 0
    return 0
  }

  readonly property var visibleSections: {
    var sections = []
    if (connectedDevices.length > 0) sections.push("connected")
    if (knownDevices.length > 0) sections.push("known")
    if (available) sections.push("pair")
    return sections
  }

  function devicesForSection(section) {
    if (section === "connected") return connectedDevices || []
    if (section === "known") return knownDevices || []
    return []
  }

  function deviceAt(section, index) {
    var list = devicesForSection(section)
    return index >= 0 && index < list.length ? list[index] : null
  }

  // ---- event stream ----
  // SplitParser hands the blank line that ends an SSE event over as a leading
  // "\n" on the next field, so trim before matching.
  function handleLine(raw) {
    var line = String(raw).replace(/^\s+|\r$/g, "")
    if (line.indexOf(":") === 0) { lastSeen = Date.now(); return }
    if (line.indexOf("event:") === 0) { currentEvent = line.substring(6).trim(); return }
    if (line.indexOf("data:") !== 0) return
    lastSeen = Date.now()
    if (currentEvent !== "bluetooth") return
    try {
      bt = JSON.parse(line.substring(5))
      available = true
    } catch (e) {
    }
  }

  function reconnect() {
    available = false
    if (stream.running) stream.running = false
    if (!restart.running) restart.start()
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

  // ---- actions: one at a time (the Mac runs them in order anyway) ----
  property var actionQueue: []
  property var runningAction: null

  function runAction(args, address, pending) {
    if (address) {
      pendingActions = Model.withEntry(pendingActions, address, pending)
      failures = Model.withEntry(failures, address, "")
      pendingTimeout.restart()
    }
    actionQueue = actionQueue.concat([{ args: args, address: address || "" }])
    nextAction()
  }

  function nextAction() {
    if (actionProc.running || actionQueue.length === 0) return
    runningAction = actionQueue[0]
    actionQueue = actionQueue.slice(1)
    actionProc.command = ["omacvm-bridge", "bluetooth"].concat(runningAction.args)
    actionProc.running = true
  }

  function actionFinished(code) {
    var a = runningAction
    runningAction = null
    if (a && a.address) {
      pendingActions = Model.withEntry(pendingActions, a.address, "")
      if (code !== 0) {
        failures = Model.withEntry(failures, a.address, a.args[0] === "connect" ? "Not in range?" : "Didn't work")
        failureTimeout.restart()
      }
    }
    nextAction()
  }

  Process {
    id: actionProc
    onExited: function(code) { root.actionFinished(code) }
  }

  Timer {
    id: pendingTimeout
    interval: 20000
    onTriggered: root.pendingActions = ({})
  }

  Timer {
    id: failureTimeout
    interval: 4000
    onTriggered: root.failures = ({})
  }

  function pendingAction(address) {
    return address && pendingActions[address] ? pendingActions[address] : ""
  }

  function failureText(address) {
    return address && failures[address] ? failures[address] : ""
  }

  function connectDevice(dev) {
    if (!dev || dev.connected || !granted) return
    runAction(["connect", dev.address], dev.address, "connecting")
  }

  function disconnectDevice(dev) {
    if (!dev || !dev.connected || !granted) return
    runAction(["disconnect", dev.address], dev.address, "disconnecting")
  }

  function forgetDevice(dev) {
    if (!dev || !forgetSupported) return
    runAction(["forget", dev.address], dev.address, "forgetting")
  }

  // A direction rather than a toggle, as in the native widget: a second click
  // before the Mac reports back would otherwise undo the first.
  function toggleBluetooth() {
    if (!available) return
    if (!powerSettable) { openMacSettings(); return }
    runAction(["power", btOn ? "off" : "on"], "", "")
  }

  // Pairing needs macOS's own dialog: the Mac's Bluetooth settings come up on
  // the Mac's screen, next to the full-screen VM.
  function openMacSettings() {
    if (!available) return
    controller.hide()
    runAction(["settings"], "", "")
  }

  // ---- cursor (as in the native widget) ----
  function moveCursor(delta) {
    var sections = visibleSections || []
    if (focusSection === "header") {
      if (delta > 0 && sections.length > 0) { focusSection = sections[0]; selectedIndex = 0; actionFocused = false }
      return
    }
    if (sections.length === 0) { focusSection = "header"; actionFocused = false; return }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = 0; actionFocused = false; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1
    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; actionFocused = false; return }
      if (sIdx < sections.length - 1) { focusSection = sections[sIdx + 1]; selectedIndex = 0; actionFocused = false }
    } else {
      if (idx > 0) { selectedIndex = idx - 1; actionFocused = false; return }
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        selectedIndex = sectionCount(focusSection) - 1
        actionFocused = false
      } else {
        focusSection = "header"; actionFocused = false
      }
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    actionFocused = false
  }

  function moveCursorH(delta) {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection !== "known" && focusSection !== "connected") return
    if (!forgetSupported || !deviceAt(focusSection, selectedIndex)) return
    actionFocused = delta > 0
  }

  function activateCursor() {
    if (focusSection === "header") { toggleBluetooth(); return }
    if (focusSection === "pair") { openMacSettings(); return }
    if (actionFocused) { deleteSelected(); return }
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev) return
    if (dev.connected) disconnectDevice(dev)
    else connectDevice(dev)
  }

  function deleteSelected() {
    if (focusSection !== "known" && focusSection !== "connected") return
    forgetDevice(deviceAt(focusSection, selectedIndex))
  }

  function updateFocusedAddress() {
    var d = deviceAt(focusSection, selectedIndex)
    focusedDeviceAddress = d ? d.address : ""
  }

  // Devices move between sections as they connect: follow the address.
  function reselectFocusedDevice() {
    if (focusedDeviceAddress !== "") {
      var sections = ["connected", "known"]
      for (var s = 0; s < sections.length; s++) {
        var list = devicesForSection(sections[s])
        for (var i = 0; i < list.length; i++) {
          if (list[i].address === focusedDeviceAddress) {
            focusSection = sections[s]
            selectedIndex = i
            return
          }
        }
      }
    }
    clampCursor()
  }

  function clampCursor() {
    if (focusSection === "header") return
    var sections = visibleSections || []
    if (sections.length === 0) { focusSection = "header"; selectedIndex = 0; return }
    if (sections.indexOf(focusSection) < 0) { focusSection = sections[0]; selectedIndex = 0; return }
    var count = sectionCount(focusSection)
    if (selectedIndex > count - 1) selectedIndex = Math.max(0, count - 1)
    if (selectedIndex < 0) selectedIndex = 0
  }

  onSelectedIndexChanged: updateFocusedAddress()
  onFocusSectionChanged: updateFocusedAddress()
  onConnectedDevicesChanged: reselectFocusedDevice()
  onKnownDevicesChanged: reselectFocusedDevice()
  onVisibleSectionsChanged: clampCursor()

  onOpenedChanged: {
    if (opened) {
      if (connectedDevices.length > 0) { focusSection = "connected"; selectedIndex = 0 }
      else if (knownDevices.length > 0) { focusSection = "known"; selectedIndex = 0 }
      else { focusSection = "header" }
      actionFocused = false
      cursorActive = false
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  onRotatingPhrasesChanged: {
    if (!rotatingPhrases) {
      phraseSwap.stop()
      heroStatus.opacity = 1.0
    }
  }

  IpcHandler {
    target: "omacvm.bluetooth"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleBluetooth() { root.toggleBluetooth() }
    function settings() { root.openMacSettings() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    opacity: root.available ? 1.0 : 0.5
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleBluetooth()
      else root.toggle()
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.cursorActive) root.deleteSelected()
      onTextKey: function(t) {
        if (t === "b" || t === "B") root.toggleBluetooth()
        else if (t === "p" || t === "P") root.openMacSettings()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: Bluetooth icon · status · switch ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.barFg
            font.family: root.barFont
            font.pixelSize: Style.font.display
            opacity: root.btOn ? 1.0 : 0.5
          }

          ToggleSwitch {
            id: powerSwitch
            visible: root.available
            checked: root.btOn
            hasCursor: root.headerHasCursor
            foreground: root.barFg
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onHovered: function(on) { if (on) root.setHeaderCursor() }
            onToggled: root.toggleBluetooth()

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
            anchors.rightMargin: powerSwitch.visible ? powerSwitch.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Bluetooth"
              color: root.barFg
              font.family: root.barFont
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
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

        // The Mac's Bluetooth permission gates connecting from here.
        Text {
          visible: root.available && root.bt && root.bt.permission !== "granted"
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "To connect devices from here, allow Bluetooth for OmacVM Bridge on the Mac: System Settings → Privacy & Security → Bluetooth."
          color: root.barUrgent
          font.family: root.barFont
          font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator {
          foreground: root.barFg
        }

        Column {
          id: connectedList
          visible: root.connectedDevices.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CONNECTED"
            foreground: root.barFg
            fontFamily: root.barFont
          }

          Repeater {
            model: root.connectedDevices
            DeviceRow {
              required property var modelData
              required property int index
              width: connectedList.width
              dev: modelData
              rowIndex: index
              sectionName: "connected"
            }
          }
        }

        PanelSeparator {
          visible: root.connectedDevices.length > 0 && root.knownDevices.length > 0
          foreground: root.barFg
        }

        // Paired devices: a ListView owns the viewport, so a long list scrolls
        // and the cursor row stays visible.
        PanelSectionHeader {
          visible: root.knownDevices.length > 0
          text: "PAIRED"
          foreground: root.barFg
          fontFamily: root.barFont
        }

        ListView {
          id: deviceListView
          visible: root.knownDevices.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(320))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.knownDevices
          currentIndex: root.focusSection === "known" ? root.selectedIndex : -1
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: DeviceRow {
            required property var modelData
            required property int index
            width: ListView.view.width
            dev: modelData
            rowIndex: index
            sectionName: "known"
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.connectedDevices.length === 0 && root.knownDevices.length === 0
          text: root.kind === "unavailable" ? "Waiting for OmacVM Bridge on the Mac"
              : root.kind === "off" ? "Turn Bluetooth on to use your devices"
              : "No devices paired with the Mac yet"
          color: Qt.darker(root.barFg, 1.5)
          font.family: root.barFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          width: parent.width
        }

        PanelSeparator {
          visible: root.available
          foreground: root.barFg
        }

        // Pairing: macOS's own dialog, in the Mac's Bluetooth settings.
        CursorSurface {
          id: pairRow
          visible: root.available
          width: parent.width
          hasCursor: root.pairHasCursor
          foreground: root.barFg
          fill: root.hoverFill
          implicitHeight: pairContent.implicitHeight + Style.spacing.rowPaddingX

          MouseArea {
            id: pairMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) {
              root.cursorActive = true
              root.focusSection = "pair"
              root.selectedIndex = 0
              root.actionFocused = false
            }
            onClicked: root.openMacSettings()
          }

          PanelToolTip {
            visible: pairMouse.containsMouse
            text: "Opens Bluetooth settings on the Mac"
            fontFamily: root.barFont
          }

          Item {
            id: pairContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            implicitHeight: Math.max(pairIcon.implicitHeight, pairInfo.implicitHeight)

            Text {
              id: pairIcon
              textFormat: Text.PlainText
              text: "󰐕"
              color: Qt.darker(root.barFg, 1.5)
              font.family: root.barFont
              font.pixelSize: Style.font.heading
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: pairInfo
              spacing: Style.space(1)
              anchors.left: pairIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              Text {
                textFormat: Text.PlainText
                text: "Pair a new device…"
                color: root.barFg
                font.family: root.barFont
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                textFormat: Text.PlainText
                text: "On the Mac"
                color: Qt.darker(root.barFg, 1.5)
                font.family: root.barFont
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }
        }
      }
    }
  }

  // Two-line device row: name, then live status (battery once connected).
  component DeviceRow: CursorSurface {
    id: row
    required property var dev
    required property int rowIndex
    required property string sectionName

    readonly property bool isConnected: !!dev && dev.connected
    readonly property string action: root.pendingAction(dev ? dev.address : "")
    readonly property string failure: root.failureText(dev ? dev.address : "")
    readonly property string actionTooltip: {
      if (!dev || !root.granted) return ""
      return isConnected ? "Disconnect" : "Connect"
    }

    readonly property bool rowSelected: root.cursorActive && root.focusSection === sectionName && root.selectedIndex === rowIndex
    readonly property bool showForgetButton: root.forgetSupported && (rowMouse.containsMouse || rowSelected)

    hasCursor: rowSelected && !root.actionFocused
    current: isConnected
    foreground: root.barFg
    fill: root.hoverFill
    currentFill: root.selectedFill

    readonly property string statusText: {
      if (!dev) return ""
      if (failure !== "") return failure
      if (action === "forgetting") return "Forgetting…"
      if (action === "disconnecting") return "Disconnecting…"
      if (action === "connecting") return "Connecting…"
      if (isConnected) return Model.batteryText(dev.battery)
      return ""
    }

    readonly property color statusColor: {
      if (failure !== "") return root.barUrgent
      if (isConnected || action !== "") return root.barFg
      return Qt.darker(root.barFg, 1.5)
    }

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: root.granted ? Qt.PointingHandCursor : Qt.ArrowCursor

      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = row.sectionName
        root.selectedIndex = row.rowIndex
        root.actionFocused = false
      }

      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) {
          if (row.isConnected) root.disconnectDevice(row.dev)
          else root.forgetDevice(row.dev)
          return
        }
        if (row.isConnected) root.disconnectDevice(row.dev)
        else root.connectDevice(row.dev)
      }
    }

    PanelToolTip {
      visible: row.actionTooltip !== "" && rowMouse.containsMouse && !root.actionFocused
      text: row.actionTooltip
      fontFamily: root.barFont
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(deviceIcon.implicitHeight, info.implicitHeight, forgetBtn.implicitHeight)

      Text {
        id: deviceIcon
        textFormat: Text.PlainText
        text: row.isConnected ? "󰂱" : "󰂯"
        color: row.statusColor
        font.family: root.barFont
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: deviceIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: forgetBtn.visible ? forgetBtn.left : parent.right
        anchors.rightMargin: forgetBtn.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: row.dev ? row.dev.name : "Device"
          color: root.barFg
          font.family: root.barFont
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          visible: row.statusText !== ""
          text: row.statusText
          color: row.statusColor
          font.family: root.barFont
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      PanelActionButton {
        id: forgetBtn
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showForgetButton
        iconText: "󰅙"
        tooltipText: "Forget on the Mac"
        foreground: root.barFg
        hoverColor: root.barFg
        fontFamily: root.barFont
        hasCursor: row.rowSelected && root.actionFocused
        onHovered: function(isHovered) {
          if (!isHovered) {
            if (rowMouse.containsMouse) root.actionFocused = false
            return
          }
          root.cursorActive = true
          root.focusSection = row.sectionName
          root.selectedIndex = row.rowIndex
          root.actionFocused = true
        }
        onClicked: root.forgetDevice(row.dev)
      }
    }
  }
}
