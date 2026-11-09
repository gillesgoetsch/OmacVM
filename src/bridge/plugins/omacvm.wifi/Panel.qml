// Derived from Omarchy's omarchy.network widget.
// Copyright (c) David Heinemeier Hansson. MIT License, see LICENSE.
//
// Shows the Mac's Wi-Fi (via the omacvm-bridge helper) instead of the VM's own
// NetworkManager devices: the VM only ever sees a virtual Ethernet
// link. Layout, components and keyboard model follow the native widget; the
// parts that need a local radio (band pinning, DNS, QR sharing, forget) are
// left out, and join/power stay disabled until the helper implements them.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
// Qt 6.12's QtQuick has a Color of its own, which hides Omarchy's (#376).
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.network"
  ipcTarget: "omarchy.network"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the toggleNetwork method below.
  manageIpc: false

  function close() {
    root.controller.hide()
  }

  Bridge { id: bridge }

  // `bar` is null while there is no bar: Omarchy's bar sets it from outside,
  // and when the shell reloads a plugin in place (a widget or the bar copy
  // written, Update VM) the old bar goes before its widgets. Then Omarchy's
  // own bar colours and font, so no binding reads a property of null.
  readonly property color barFg: bar ? bar.foreground : Commons.Color.bar.text
  readonly property string barFont: bar ? bar.fontFamily : Style.font.family
  readonly property color barUrgent: bar ? bar.urgent : Commons.Color.bar.active

  readonly property bool available: bridge.available
  readonly property var wifi: bridge.wifi || ({})
  readonly property string kind: Model.kindFor(bridge.available, bridge.wifi)
  readonly property int signalStrength: kind === "wifi" ? (parseInt(wifi.quality, 10) || 0) : -1
  // The Mac on a cable (a Mac mini on Ethernet): the bar shows Omarchy's wired
  // icon, as Omarchy's own widget does when Ethernet is up; the panel keeps
  // the Mac's Wi-Fi below it.
  readonly property bool wired: available && wifi.wired === true
  readonly property string icon: wired ? "󰈀" : Model.connectionIcon(kind, signalStrength)
  readonly property bool locationOff: available && wifi.location_authorized === false
  readonly property string ssid: wifi.ssid || ""

  property var wifiNetworks: []
  property bool scanning: false

  property int connectionPhraseIndex: 0
  readonly property var connectionPhrases: [
    "Wiring bits",
    "Handling packets",
    "Sorting frames",
    "Hauling bytes",
    "Routing crumbs",
    "Counting collisions",
    "Bending light",
  ]
  readonly property string connectionPhrase: connectionPhrases[connectionPhraseIndex % connectionPhrases.length]

  // Index into `wifiNetworks` for keyboard navigation. -1 = no selection.
  property int selectedIndex: -1
  property bool cursorActive: false

  // Keyboard focus zone: header actions ⇄ Wi-Fi networks.
  property string focusSection: "wifi"  // "header" | "wifi"
  property int headerIndex: 0
  // The helper answers 501 for power and join, so the switch is shown for
  // parity but cannot be flipped from here yet.
  readonly property bool powerSupported: false
  readonly property bool joinSupported: false
  readonly property bool canRunSpeedTest: kind === "wifi"
  // Share the Mac's network as a QR code (omacvm.wifiqr, Omarchy's card;
  // OmacVM's omarchy-network-qr feeds it the Mac's network). Personal,
  // WEP, open and OWE networks only, as the bridge reports in can_share.
  readonly property bool canShareWifi: kind === "wifi" && wifi.can_share === true
  readonly property int qrHeaderIndex: canShareWifi ? 0 : -1
  readonly property int speedHeaderIndex: canRunSpeedTest ? (canShareWifi ? 1 : 0) : -1
  readonly property int toggleHeaderIndex: (canShareWifi ? 1 : 0) + (canRunSpeedTest ? 1 : 0)
  readonly property int headerActionCount: (canShareWifi ? 1 : 0) + (canRunSpeedTest ? 1 : 0) + 1
  readonly property bool qrHeaderHasCursor: cursorActive && focusSection === "header" && headerIndex === qrHeaderIndex
  readonly property bool speedHeaderHasCursor: cursorActive && focusSection === "header" && headerIndex === speedHeaderIndex
  readonly property bool toggleHeaderHasCursor: cursorActive && focusSection === "header" && headerIndex === toggleHeaderIndex
  readonly property string toggleHint: "Turn Wi-Fi " + (wifi.power === false ? "on" : "off") + " on the Mac (not supported yet)"

  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Commons.Color.accent) : "transparent"

  onHeaderActionCountChanged: clampHeaderIndex()

  function clampHeaderIndex() {
    var max = Math.max(0, headerActionCount - 1)
    if (headerIndex > max) headerIndex = max
    if (headerIndex < 0) headerIndex = 0
  }

  function selectHeaderByDelta(delta) {
    headerIndex = Math.max(0, Math.min(headerActionCount - 1, headerIndex + delta))
  }

  function toggleNetwork() {
    // Not implemented by the helper yet (501).
  }

  IpcHandler {
    target: "omacvm.wifi"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleNetwork() { root.toggleNetwork() }
    function speedTest() { root.summonSpeedTest() }
    function showQr() { root.summonWifiQr() }
  }

  function activateHeader() {
    if (headerIndex === qrHeaderIndex) summonWifiQr()
    else if (headerIndex === speedHeaderIndex) summonSpeedTest()
    else if (headerIndex === toggleHeaderIndex) toggleNetwork()
  }

  function setHeaderCursor(index) {
    cursorActive = true
    focusSection = "header"
    headerIndex = index
  }

  onOpenedChanged: {
    if (opened) {
      syncWifiNetworks()
      refresh(true)
      selectedIndex = wifiNetworks.length > 0 ? 0 : -1
      focusSection = wifiNetworks.length > 0 ? "wifi" : "header"
      headerIndex = 0
      cursorActive = false
    }
  }

  onWifiNetworksChanged: {
    if (wifiNetworks.length === 0) {
      selectedIndex = -1
      if (focusSection === "wifi") focusSection = "header"
    } else if (selectedIndex >= wifiNetworks.length) {
      selectedIndex = wifiNetworks.length - 1
    } else if (selectedIndex < 0 && opened) {
      selectedIndex = 0
    }
  }

  Connections {
    target: bridge
    function onScanChanged() { root.syncWifiNetworks() }
  }

  function selectByDelta(delta) {
    if (wifiNetworks.length === 0) { selectedIndex = -1; return }
    if (selectedIndex < 0) selectedIndex = delta > 0 ? 0 : wifiNetworks.length - 1
    else selectedIndex = Math.max(0, Math.min(wifiNetworks.length - 1, selectedIndex + delta))
  }

  function syncWifiNetworks() {
    wifiNetworks = Model.wifiRows(bridge.scan)
  }

  function wifiSectionTitle(index) {
    return Model.wifiSectionTitle(wifiNetworks, index)
  }

  function wifiIconFor(strength) {
    return Model.wifiIconFor(strength)
  }

  function copyToClipboard(value) {
    if (!value || !root.bar) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
  }

  // The cached list opens instantly; a fresh scan follows when asked for
  // (panel open, or `r`). Scan results also arrive on the event stream.
  function refresh(scanWifi) {
    if (!available) return
    if (!cachedScanProc.running && wifiNetworks.length === 0) cachedScanProc.running = true
    if (scanWifi && !scanProc.running) {
      scanning = true
      scanProc.running = true
    }
  }

  function applyScan(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      return
    }
    if (parsed && Array.isArray(parsed.networks)) bridge.scan = parsed
  }

  // The share card is omacvm.wifiqr, a clone of Omarchy's wifiqr card. Interface
  // "mac" tells omarchy-network-qr/-password to read the Mac's network through
  // the bridge; macOS asks for approval before it hands out the password.
  function summonWifiQr() {
    controller.hide()
    bar.shell.summon("omacvm.wifiqr", JSON.stringify({ iface: "mac", ssid: ssid || "" }))
  }

  // The speed test is its own panel plugin (omarchy.speedtest). It measures
  // the VM's link, which runs over this Wi-Fi.
  function summonSpeedTest() {
    controller.hide()
    var connection = ssid || "Wi-Fi"
    bar.shell.summon("omarchy.speedtest", JSON.stringify({ connection: connection }))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: cachedScanProc
    command: ["omacvm-bridge", "scan", "--cached"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text)
    }
  }

  Process {
    id: scanProc
    command: ["omacvm-bridge", "scan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text)
    }
    onExited: root.scanning = false
  }

  Timer {
    id: connectionPhraseTimer
    interval: 2800
    running: root.opened && root.kind === "wifi"
    repeat: true
    onTriggered: connectionPhraseSwap.restart()
  }

  SequentialAnimation {
    id: connectionPhraseSwap
    PropertyAnimation {
      target: heroMeta; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.connectionPhraseIndex = (root.connectionPhraseIndex + 1) % root.connectionPhrases.length
    }
    PropertyAnimation {
      target: heroMeta; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  onKindChanged: {
    if (kind !== "wifi") {
      connectionPhraseSwap.stop()
      heroMeta.opacity = 1.0
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    opacity: root.available ? 1.0 : 0.5

    onPressed: function(b) {
      if (root.opened) root.close()
      else root.open()
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
        if (!root.cursorActive) {
          root.cursorActive = true
          if (dy >= 0) return
        }
        if (dy !== 0) {
          if (root.focusSection === "header") {
            if (dy > 0 && root.wifiNetworks.length > 0) {
              root.focusSection = "wifi"
              if (root.selectedIndex < 0) root.selectedIndex = 0
            }
          } else {
            // k from the top row escapes back up to the header actions
            // rather than wrapping around to the bottom of the list.
            if (dy < 0 && root.selectedIndex <= 0) {
              root.focusSection = "header"
              root.headerIndex = 0
            }
            else root.selectByDelta(dy)
          }
        }
        if (dx !== 0 && root.focusSection === "header") root.selectHeaderByDelta(dx)
      }
      onActivateRequested: {
        if (root.cursorActive && root.focusSection === "header") root.activateHeader()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh(true)
      }

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero: network icon · SSID + state · actions ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

        Text {
          id: heroIcon
          textFormat: Text.PlainText
          text: root.icon
          color: root.barFg
          font.family: root.barFont
          font.pixelSize: Style.font.display
          opacity: root.available ? 1.0 : 0.5
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        RowLayout {
          id: heroActions
          spacing: Style.space(8)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter

          Button {
            id: qrAction
            visible: root.canShareWifi
            iconText: "󰐲"
            tooltipText: "Show QR code"
            foreground: root.barFg
            fontFamily: root.barFont
            iconSize: Style.font.subtitle * 1.5
            horizontalPadding: Style.space(5)
            verticalPadding: Style.space(2)
            hasCursor: root.qrHeaderHasCursor
            Layout.alignment: Qt.AlignVCenter
            onHovered: function(on) { if (on) root.setHeaderCursor(root.qrHeaderIndex) }
            onClicked: root.summonWifiQr()
          }

          Button {
            id: speedAction
            visible: root.canRunSpeedTest
            iconText: "󰓅"
            tooltipText: "Run a speed test"
            foreground: root.barFg
            fontFamily: root.barFont
            iconSize: Style.font.subtitle * 1.5
            horizontalPadding: Style.space(5)
            verticalPadding: Style.space(2)
            hasCursor: root.speedHeaderHasCursor
            Layout.alignment: Qt.AlignVCenter
            onHovered: function(on) { if (on) root.setHeaderCursor(root.speedHeaderIndex) }
            onClicked: root.summonSpeedTest()
          }

          ToggleSwitch {
            id: powerSwitch
            visible: root.available
            checked: root.wifi.power !== false
            interactive: root.powerSupported
            opacity: root.powerSupported ? 1.0 : 0.5
            hasCursor: root.toggleHeaderHasCursor
            foreground: root.barFg
            Layout.alignment: Qt.AlignVCenter
            onHovered: function(on) { if (on) root.setHeaderCursor(root.toggleHeaderIndex) }
            onToggled: root.toggleNetwork()

            // The switch's own MouseArea is off while it can't act, so hover
            // still has to place the panel cursor here.
            HoverHandler {
              id: powerHover
              onHoveredChanged: if (hovered) root.setHeaderCursor(root.toggleHeaderIndex)
            }

            PanelToolTip {
              visible: powerHover.hovered || root.toggleHeaderHasCursor
              text: root.toggleHint
              fontFamily: root.barFont
            }
          }
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.rightMargin: heroActions.width > 0 ? heroActions.width + Style.space(12) : 0
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            id: heroSsid
            textFormat: Text.PlainText
            width: parent.width

            readonly property string title: {
              if (root.kind === "unavailable") return "Mac unavailable"
              if (root.wired && root.kind !== "wifi") return "Ethernet"
              if (root.kind === "off") return "Wi-Fi off"
              if (root.kind === "disconnected") return "Wi-Fi"
              return root.ssid || "Wi-Fi"
            }
            readonly property string detail: root.kind === "wifi" && root.wifi.channel
              ? Model.bandLabel(root.wifi.channel.band) : ""

            text: heroSsid.detail !== "" ? heroSsid.title + " (" + heroSsid.detail + ")" : heroSsid.title
            color: root.barFg
            font.family: root.barFont
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            id: heroMeta
            textFormat: Text.PlainText
            width: parent.width
            text: {
              if (root.kind === "unavailable") return "WAITING FOR THE MAC"
              if (root.wired && root.kind !== "wifi") return "THE MAC IS ON A CABLE" + (root.kind === "off" ? " · WI-FI OFF" : "")
              if (root.kind === "off") return "TURNED OFF ON THE MAC"
              if (root.kind === "disconnected") return "NOT CONNECTED"
              return root.connectionPhrase.toUpperCase()
            }
            color: Qt.darker(root.barFg, 1.4)
            font.family: root.barFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
          }
        }
      }

      // Location Services gates the network name on macOS.
      Text {
        visible: root.locationOff
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "Location Services is off for omacvm-bridge on the Mac, so network names are hidden. Turn it on in System Settings → Privacy & Security → Location Services."
        color: root.barUrgent
        font.family: root.barFont
        font.pixelSize: Style.font.bodySmall
      }

      // Connection details from the Mac's radio.
      Column {
        visible: root.kind === "wifi"
        width: parent.width
        spacing: Style.spacing.labelGap

        GridLayout {
          width: parent.width
          columns: 4
          columnSpacing: Style.space(20)
          rowSpacing: Style.spacing.labelGap

          InfoLabel { text: "Signal" }
          DetailValue { text: Model.formatDbm(root.wifi.rssi) }
          InfoLabel { text: "Noise" }
          DetailValue { text: Model.formatDbm(root.wifi.noise) }

          InfoLabel { text: "Quality" }
          DetailValue { text: root.signalStrength >= 0 ? root.signalStrength + "%" : "--" }
          InfoLabel { text: "Tx Rate" }
          DetailValue { text: Model.formatRate(root.wifi.tx_rate_mbps) }

          InfoLabel { text: "Channel" }
          DetailValue { text: Model.formatChannel(root.wifi.channel) }
          InfoLabel { text: "Standard" }
          DetailValue { text: root.wifi.phy_mode || "--" }

          InfoLabel { text: "Security" }
          DetailValue { text: Model.securityLabel(root.wifi.security) }
          InfoLabel { text: "BSSID" }
          DetailValue {
            text: root.wifi.bssid || "--"
            copyable: !!root.wifi.bssid
            tooltipText: "Copy BSSID"
          }
        }
      }

      PanelSeparator {
        visible: root.available
        foreground: root.barFg
      }

      PanelSectionHeader {
        visible: root.available && root.scanning
        text: "SCANNING WI-FI…"
        foreground: root.barFg
        fontFamily: root.barFont
      }

      // Scrollable network list — cap the height so a busy neighbourhood
      // doesn't push the popup off-screen.
      ListView {
        id: networkList
        visible: root.available
        width: parent.width
        height: Math.min(contentHeight, Style.space(240))
        spacing: Style.space(4)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: root.available ? root.wifiNetworks : []
        currentIndex: root.selectedIndex
        onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

        delegate: Item {
          required property var modelData
          required property int index
          readonly property string sectionTitle: root.wifiSectionTitle(index)
          width: ListView.view.width
          height: delegateColumn.implicitHeight

          Column {
            id: delegateColumn
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              visible: sectionTitle !== ""
              text: sectionTitle
              foreground: root.barFg
              fontFamily: root.barFont
              height: visible ? implicitHeight : 0
            }

            NetworkRow {
              width: parent.width
              net: modelData
              index: parent.parent.index
            }
          }
        }
      }
    }
    }
  }

  // A single Wi-Fi network entry, as in the native widget. Joining from the
  // VM is not implemented by the helper yet, so a row is informational.
  component NetworkRow: CursorSurface {
    id: row
    required property var net
    required property int index

    readonly property bool isConnected: !!(net && net.connected)
    readonly property bool isSelected: root.focusSection === "wifi" && root.selectedIndex === index

    hasCursor: root.cursorActive && isSelected
    current: isConnected
    foreground: root.barFg
    fill: root.hoverFill
    currentFill: root.selectedFill

    readonly property string statusText: isConnected ? "Connected" : ""
    readonly property color statusColor: isConnected ? root.barFg : Qt.darker(root.barFg, 1.5)

    implicitHeight: rowBody.implicitHeight

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: root.joinSupported ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.focusSection = "wifi"; root.selectedIndex = row.index }
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !row.isConnected && !root.joinSupported
      text: "Join networks on the Mac for now"
      fontFamily: root.barFont
    }

    Item {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(networkIcon.implicitHeight, networkInfo.implicitHeight, lockIndicator.implicitHeight) + Style.spacing.rowPaddingX

      Text {
        id: networkIcon
        textFormat: Text.PlainText
        text: row.net ? root.wifiIconFor(row.net.signal) : ""
        color: row.statusColor
        font.family: root.barFont
        font.pixelSize: Style.font.title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: lockIndicator
        textFormat: Text.PlainText
        visible: !!(row.net && row.net.locked)
        width: Style.space(22)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignHCenter
        text: "󰌾"
        color: Qt.darker(root.barFg, 1.4)
        font.family: root.barFont
        font.pixelSize: Style.font.subtitle
      }

      Column {
        id: networkInfo
        spacing: Style.space(1)
        anchors.left: networkIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: lockIndicator.visible ? lockIndicator.left : parent.right
        anchors.rightMargin: lockIndicator.visible ? Style.space(8) : 0
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: row.net ? (row.net.ssid || "Hidden") : ""
          color: root.barFg
          font.family: root.barFont
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          text: row.statusText
          visible: row.statusText !== ""
          height: visible ? implicitHeight : 0
          color: row.statusColor
          font.family: root.barFont
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }
  }

  component DetailValue: InfoValue {
    property bool copyable: false
    property string tooltipText: "Copy to clipboard"

    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight

    MouseArea {
      id: valueMouse
      anchors.fill: parent
      enabled: copyable && parent.text !== ""
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.copyToClipboard(parent.text)
    }

    PanelToolTip {
      visible: valueMouse.enabled && valueMouse.containsMouse
      text: tooltipText
      fontFamily: root.barFont
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.barFg
    opacity: 0.6
    font.family: root.barFont
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.barFg
    font.family: root.barFont
    font.pixelSize: Style.font.bodySmall
  }
}
