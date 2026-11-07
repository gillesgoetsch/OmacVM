import QtQuick
import Quickshell
import Quickshell.Io

// Live state from the Mac helper (omacvm-bridge). One long-running
// `omacvm-bridge events` process feeds the latest wifi/audio/scan payloads; the
// client resolves OMACVM_BRIDGE_URL and the token file itself, so nothing about
// the user, home or address is hard-coded here.
//
// The helper pushes a wifi event every few seconds, so silence means the Mac
// is asleep or the VM's network is gone: the watchdog drops the stream
// and the 3 s restart picks it back up once the Mac answers again.
Item {
  id: bridge
  visible: false

  property bool available: false
  property var wifi: null
  property var audio: null
  property var scan: null

  property string currentEvent: ""
  property real lastSeen: 0

  // SplitParser drops the blank line that ends each SSE event and hands it
  // over as a leading "\n" on the next field, so trim before matching.
  function handleLine(raw) {
    var line = String(raw).replace(/^\s+|\r$/g, "")
    if (line.indexOf(":") === 0) {          // ": ping" keepalive: the Mac is there
      lastSeen = Date.now()
      return
    }
    if (line.indexOf("event:") === 0) {
      currentEvent = line.substring(6).trim()
      return
    }
    if (line.indexOf("data:") !== 0) return
    lastSeen = Date.now()
    var payload
    try {
      payload = JSON.parse(line.substring(5))
    } catch (e) {
      return
    }
    available = true
    if (currentEvent === "wifi") wifi = payload
    else if (currentEvent === "audio") audio = payload
    else if (currentEvent === "scan") scan = payload
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
    onStarted: bridge.lastSeen = Date.now()
    onExited: bridge.reconnect()
    stdout: SplitParser {
      onRead: function(line) { bridge.handleLine(line) }
    }
  }

  Timer {
    id: restart
    interval: 3000
    onTriggered: if (!stream.running) stream.running = true
  }

  Timer {
    interval: 5000
    repeat: true
    running: stream.running
    onTriggered: if (Date.now() - bridge.lastSeen > 20000) bridge.reconnect()
  }
}
