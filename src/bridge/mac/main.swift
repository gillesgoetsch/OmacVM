// omacvm-bridge (Mac side): exposes this Mac's Wi-Fi and audio state to the
// Omarchy VM in Parallels, which only sees a virtual Ethernet NIC and a virtual
// sound card. Wi-Fi is read-only (stage 1); audio can be controlled (stage 1b);
// media keys go to the VM's own popup while it is full screen (stage 1c).
//
// HTTP/1.1 on port 47831 of the Mac's address on each VM network (10.211.55.2
// for Parallels, 192.168.64.1 for UTM, .1 of VMware Fusion's NAT network; never 0.0.0.0). Every request needs "Authorization: Bearer <token>",
// except the one the VM makes first, to check it talks to the Bridge before it sends the token:
//   GET  /proof?nonce=N    {"proof": HMAC-SHA256(token, "omacvm-bridge mac <addr> N")}, N 32 hex digits,
//                          <addr> the Mac address the request came in on
//   GET  /state            Wi-Fi state
//   GET  /scan[?cached=1]  nearby networks, one entry per SSID; cached=1 = the
//                          system's scan cache (instant, no radio scan)
//   GET  /audio            default output/input (volume, mute) + all devices
//   POST /audio/volume     {"volume": 0..1} or {"delta": -1..1}  [+ "scope": "input"]
//   POST /audio/mute       {"muted": true|false|"toggle"}        [+ "scope": "input"]
//   POST /audio/output     {"uid": "<device UID>"}
//   POST /audio/input      {"uid": "<device UID>"}
//   GET  /display          built-in display brightness, Night Shift, True Tone
//   POST /display/brightness   {"brightness": 0..1} or {"delta": -1..1}
//   POST /display/night-shift  {"enabled": true|false|"toggle", "strength": 0..1}
//   POST /display/true-tone    {"enabled": true|false|"toggle"}
//   GET  /wifi/password[?ssid=]  saved password + QR string (macOS asks first)
//   GET  /bluetooth        Bluetooth power and paired devices (kind, connected, battery)
//   POST /bluetooth/power      {"enabled": true|false|"toggle"}
//   POST /bluetooth/connect    {"address": "AA:BB:CC:DD:EE:FF"}   (also /disconnect, /forget)
//   POST /bluetooth/settings   opens the Mac's Bluetooth settings (pairing)
//   POST /wallpaper        image body: the Mac's wallpaper (and lock-screen background)
//   GET  /battery          the Mac's battery (battery.swift), for UTM and VMware Fusion VMs
//   GET  /camera           the connection then carries the Mac's camera (camera.swift): the VM
//                          sends {"type":"start"|"stop"} lines, the Bridge 1280x720 NV12 frames
//                          while started (macOS asks for the camera permission the first time)
//   GET  /camera/status    {"permission", "camera", "on", "readers", "connections"}
//                          (both camera paths: 403 from 127.0.0.1 and the Mac's own addresses)
//   GET  /events           Server-Sent Events: "wifi", "audio", "display", "bluetooth" and "battery" on every change
//                          (RSSI is re-read every 5 s), "scan" when new scan
//                          results exist, "osd" on volume/mute/brightness/keyboard
//                          light changes (keys.swift), ": ping" every 15 s
// Token: ~/Library/Application Support/omacvm-bridge/token (created on first run).
// SSIDs/BSSIDs are only readable once Location Services is granted to the app.
import AppKit
import Foundation
import Security

setvbuf(stdout, nil, _IOLBF, 0)

let env = ProcessInfo.processInfo.environment
// The Mac's address on each VM network: Parallels' shared network, UTM's
// shared network (vmnet) and VMware Fusion's NAT network (vmnet8, when Fusion
// is installed), and for OmacVM.app 127.0.0.1 (its VMs reach it as 10.0.2.2)
// and 192.168.77.1 (its fast network, src/net/mac). One listener per
// address; never 0.0.0.0.
let listenAddrs = (env["OMACVM_BRIDGE_ADDRS"] ?? (["10.211.55.2", "192.168.64.1"] + [fusionHost()].compactMap { $0 } + ["127.0.0.1", "192.168.77.1"])
  .joined(separator: ",")).split(separator: ",").map(String.init)

/// Fusion picks its NAT subnet at install time; the Mac is .1 there (the guests' gateway is .2).
/// The first VNET_8_HOSTONLY_SUBNET line, and only a private address (as fusion_host in src/lib/mac.sh).
func fusionHost() -> String? {
  guard let s = try? String(contentsOfFile: "/Library/Preferences/VMware Fusion/networking", encoding: .utf8) else { return nil }
  for line in s.split(separator: "\n") {
    let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard f.count >= 3, f[0] == "answer", f[1] == "VNET_8_HOSTONLY_SUBNET" else { continue }
    let o = f[2].split(separator: ".").compactMap { UInt8($0) }
    guard o.count == 4, o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) else { return nil }
    let host = "\(o[0]).\(o[1]).\(o[2]).1"
    return ["10.211.55.2", "192.168.64.1", "192.168.77.1"].contains(host) ? nil : host
  }
  return nil
}
let listenPort = UInt16(env["OMACVM_BRIDGE_PORT"] ?? "") ?? 47831
let tickSeconds = 5.0        // RSSI refresh + listener check
let pingSeconds = 15.0       // SSE keepalive when nothing changed
let minorSeconds = 30.0      // Wi-Fi signal jitter alone: sent at most this often
let recentScanSeconds = 10.0 // GET /scan reuses an active scan this young; scan-cache push throttle
let maxClients = 64     // dead connections are only noticed on the next write

let logFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
let isoFormat = ISO8601DateFormatter()

func log(_ s: String) { print("\(logFormat.string(from: Date())) omacvm-bridge: \(s)") }

// ---- token ----
let supportDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/omacvm-bridge").path
let tokenPath = supportDir + "/token"

func loadToken() -> String {
  if let s = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count >= 32 { return t }
  }
  var bytes = [UInt8](repeating: 0, count: 32)
  guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("no randomness") }
  let t = bytes.map { String(format: "%02x", $0) }.joined()
  try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
  guard FileManager.default.createFile(atPath: tokenPath, contents: Data((t + "\n").utf8),
                                       attributes: [.posixPermissions: 0o600]) else { fatalError("cannot write \(tokenPath)") }
  log("created token \(tokenPath)")
  return t
}
let token = Array(loadToken().utf8)

// ---- JSON helpers ----
func nn(_ v: Any?) -> Any { v ?? NSNull() }

func jsonData(_ obj: Any) -> Data {
  (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
}

func jsonString(_ obj: Any) -> String { String(decoding: jsonData(obj), as: UTF8.self) }

func same(_ a: Any?, _ b: Any?) -> Bool { jsonData([nn(a)]) == jsonData([nn(b)]) }

// ---- main ----
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let config = Config()

let location = Location()
let wifi = WiFi()
let audio = Audio()
let bluetooth = BluetoothBridge()
let hub = Hub([
  Feed(event: "wifi", delay: 0.3, read: { wifi.state(locationOK: location.authorized) }, describe: describeWiFi,
       coarse: coarseWiFi),
  Feed(event: "audio", delay: 0.05, read: { audio.state() }, describe: describeAudio),
  Feed(event: "display", delay: 0.1, read: { displayState() }, describe: describeDisplay),
  Feed(event: "bluetooth", delay: 0.3, read: { bluetooth.state() }, describe: describeBluetooth),
  Feed(event: "battery", delay: 0.3, read: { batteryState() }, describe: describeBattery, coarse: coarseBattery),
])
let scanner = Scanner(wifi: wifi, hub: hub, location: location)
let servers = listenAddrs.map { addr in Server(addr: addr) { fd, peer in handle(fd, peer: peer) } }
let osdEvents = OSDEvents()
let camera = CameraHub { log("camera: \($0)") }
let mediaKeys = MediaKeys()
let menuBar = MenuBar()

log("starting (pid \(getpid()), token \(tokenPath))")
location.onChange = { hub.changed("wifi", why: "location") }
wifi.onEvent = { why in why == "scan-cache" ? scanner.cacheUpdated() : hub.changed("wifi", why: why) }
audio.onChange = { why in hub.changed("audio", why: why); osdEvents.audioChanged() }
NightShift.onChange { hub.changed("display", why: "night-shift") }
bluetooth.onChange = { why in hub.changed("bluetooth", why: why) }
watchPowerSources { hub.changed("battery", why: "power") }
wifi.start()
audio.start()
location.start()
bluetooth.start()
hub.start()
osdEvents.start()   // before the listeners: it hooks into the hub
servers.forEach { $0.check() }
mediaKeys.start()
if config.menuBarIcon { menuBar.show() }
log("config \(config.path): capture_keys=\(config.captureKeys) menu_bar_icon=\(config.menuBarIcon) keyboard_low_steps=\(config.keyboardLowSteps)")
// A Mac mini, iMac or Studio has no keyboard light: Shift + brightness stays macOS's.
log("keyboard light: \(KeyboardLight.get() != nil ? "found" : "none on this Mac")")
let listenerTimer = DispatchSource.makeTimerSource(queue: .main)
listenerTimer.schedule(deadline: .now() + tickSeconds, repeating: tickSeconds, leeway: .seconds(1))
listenerTimer.setEventHandler { servers.forEach { $0.check() } }
listenerTimer.resume()

let ws = NSWorkspace.shared.notificationCenter
ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in log("system going to sleep") }
ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
  log("system woke up: re-subscribing to CoreWLAN, re-binding listener")
  wifi.subscribe()
  servers.forEach { $0.check(rebind: true) }
  for delay in [2.0, 10.0] {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      hub.changed("wifi", why: "wake"); hub.changed("audio", why: "wake"); hub.changed("bluetooth", why: "wake")
      hub.changed("battery", why: "wake")
    }
  }
}

app.run()
