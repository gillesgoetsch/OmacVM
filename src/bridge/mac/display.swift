// Display side: the built-in display's brightness, Night Shift and True Tone
// (CoreBrightness, private), pushed as the "display" feed and settable from the
// VM. Plus the Wi-Fi password for QR sharing (System keychain, on request only).
import AppKit
import CoreWLAN
import Security

// ---- Night Shift (CBBlueLightClient) ----
enum NightShift {
  // CoreBrightness' StatusData; C layout, 40 bytes.
  struct Status {
    var active: ObjCBool = false, enabled: ObjCBool = false, sunSchedulePermitted: ObjCBool = false
    var mode: Int32 = 0                              // 0 off, 1 sunset to sunrise, 2 custom
    var fromHour: Int32 = 0, fromMinute: Int32 = 0, toHour: Int32 = 0, toMinute: Int32 = 0
    var disableFlags: UInt64 = 0
    var available: ObjCBool = false
  }
  private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
  private typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Bool
  private typealias GetFloat = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
  private typealias SetStrength = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
  private typealias SetBlock = @convention(c) (AnyObject, Selector, @escaping @convention(block) (UnsafeRawPointer?) -> Void) -> Void

  private static let client: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
          let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
    let c = cls.init()
    return ["getBlueLightStatus:", "setEnabled:", "getStrength:", "setStrength:commit:"]
      .allSatisfy { c.responds(to: NSSelectorFromString($0)) } ? c : nil
  }()

  private static func call<T>(_ name: String, as: T.Type) -> (NSObject, Selector, T)? {
    guard let c = client else { return nil }
    let sel = NSSelectorFromString(name)
    return (c, sel, unsafeBitCast(c.method(for: sel), to: T.self))
  }

  static func status() -> Status? {
    guard let (c, sel, f) = call("getBlueLightStatus:", as: GetStatus.self) else { return nil }
    var s = Status()
    return withUnsafeMutablePointer(to: &s) { f(c, sel, UnsafeMutableRawPointer($0)) } ? s : nil
  }

  static func strength() -> Float? {
    guard let (c, sel, f) = call("getStrength:", as: GetFloat.self) else { return nil }
    var v: Float = 0
    return f(c, sel, &v) ? v : nil
  }

  static func setEnabled(_ on: Bool) -> Bool {
    guard let (c, sel, f) = call("setEnabled:", as: SetBool.self) else { return false }
    return f(c, sel, on)
  }

  static func setStrength(_ v: Float) -> Bool {
    guard let (c, sel, f) = call("setStrength:commit:", as: SetStrength.self) else { return false }
    return f(c, sel, max(0, min(1, v)), true)
  }

  /// Called on every Night Shift change (toggle, schedule, strength) made anywhere.
  static func onChange(_ handler: @escaping () -> Void) {
    guard let c = client, c.responds(to: NSSelectorFromString("setStatusNotificationBlock:")),
          let (_, sel, f) = call("setStatusNotificationBlock:", as: SetBlock.self) else { return }
    f(c, sel) { _ in handler() }
  }
}

// ---- True Tone (CBTrueToneClient) ----
enum TrueTone {
  private typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
  private typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Bool
  private static let client: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
          let cls = NSClassFromString("CBTrueToneClient") as? NSObject.Type else { return nil }
    let c = cls.init()
    return ["supported", "available", "enabled", "setEnabled:"].allSatisfy { c.responds(to: NSSelectorFromString($0)) } ? c : nil
  }()

  private static func read(_ name: String) -> Bool? {
    guard let c = client else { return nil }
    let sel = NSSelectorFromString(name)
    return unsafeBitCast(c.method(for: sel), to: GetBool.self)(c, sel)
  }

  static var supported: Bool { read("supported") ?? false }
  static var available: Bool { read("available") ?? false }
  static var enabled: Bool? { read("enabled") }

  static func setEnabled(_ on: Bool) -> Bool {
    guard let c = client else { return false }
    let sel = NSSelectorFromString("setEnabled:")
    return unsafeBitCast(c.method(for: sel), to: SetBool.self)(c, sel, on)
  }
}

func hhmm(_ h: Int32, _ m: Int32) -> String { String(format: "%02d:%02d", h, m) }

func displayState() -> [String: Any] {
  var night: Any = NSNull()
  if let s = NightShift.status() {
    let modes: [Int32: String] = [0: "off", 1: "sunset-to-sunrise", 2: "custom"]
    night = ["available": s.available.boolValue, "enabled": s.enabled.boolValue,
             "strength": nn(NightShift.strength().map { jsonVolume($0) }),
             "schedule": ["mode": modes[s.mode] ?? "unknown", "from": hhmm(s.fromHour, s.fromMinute),
                          "to": hhmm(s.toHour, s.toMinute)]]
  }
  let tt: [String: Any] = ["supported": TrueTone.supported, "available": TrueTone.available,
                           "enabled": nn(TrueTone.enabled)]
  return ["brightness": nn(Brightness.get().map { jsonVolume($0) }), "night_shift": night, "true_tone": tt]
}

func describeDisplay(_ old: [String: Any], _ s: [String: Any]) -> String? {
  func on(_ d: [String: Any], _ k: String) -> Any? { (d[k] as? [String: Any])?["enabled"] }
  guard !same(on(old, "night_shift"), on(s, "night_shift")) || !same(on(old, "true_tone"), on(s, "true_tone"))
  else { return nil }   // brightness and strength changes stay quiet
  return "night_shift=\(on(s, "night_shift") ?? "-") true_tone=\(on(s, "true_tone") ?? "-")"
}

/// "toggle" or a Bool from a JSON body; nil when the key is missing.
func boolOrToggle(_ v: Any?, current: Bool) throws -> Bool? {
  switch v {
  case nil: return nil
  case let b as Bool: return b
  case let s as String where s == "toggle": return !current
  default: throw APIError(400, "\"enabled\" must be true, false or \"toggle\"")
  }
}

/// POST /display/*: applies the change, returns a log line.
func displayControl(_ path: String, _ body: [String: Any]) throws -> String {
  switch path {
  case "/display/brightness":
    guard let now = Brightness.get() else { throw APIError(409, "no display whose brightness macOS sets (lid closed?)") }
    let absolute = (body["brightness"] as? NSNumber)?.floatValue, delta = (body["delta"] as? NSNumber)?.floatValue
    guard absolute != nil || delta != nil else { throw APIError(400, "send {\"brightness\": 0..1} or {\"delta\": -1..1}") }
    let target = max(0, min(1, absolute ?? (now + (delta ?? 0))))
    guard Brightness.set(target) else { throw APIError(500, "setting the brightness failed") }
    osdEvents.brightnessSet(source: "api")
    return "brightness \(target)"
  case "/display/night-shift":
    guard let s = NightShift.status(), s.available.boolValue else { throw APIError(409, "Night Shift is not available on this Mac") }
    let enable = try boolOrToggle(body["enabled"], current: s.enabled.boolValue)
    let strength = (body["strength"] as? NSNumber)?.floatValue
    guard enable != nil || strength != nil else { throw APIError(400, "send {\"enabled\": true|false|\"toggle\"} and/or {\"strength\": 0..1}") }
    if let strength, !NightShift.setStrength(strength) { throw APIError(500, "setting the Night Shift strength failed") }
    if let enable, !NightShift.setEnabled(enable) { throw APIError(500, "switching Night Shift failed") }
    return "night shift" + (enable.map { " enabled=\($0)" } ?? "") + (strength.map { " strength=\($0)" } ?? "")
  case "/display/true-tone":
    guard TrueTone.supported, TrueTone.available, let now = TrueTone.enabled else {
      throw APIError(409, "True Tone is not available on this display")
    }
    guard let enable = try boolOrToggle(body["enabled"], current: now) else { throw APIError(400, "send {\"enabled\": true|false|\"toggle\"}") }
    guard TrueTone.setEnabled(enable) else { throw APIError(500, "switching True Tone failed") }
    return "true tone enabled=\(enable)"
  default:
    throw APIError(404, "not found")
  }
}

// ---- Wi-Fi password for QR sharing ----
let shareableSecurity: Set<String> = ["open", "wep", "wpa-personal", "wpa-wpa2-personal", "wpa2-personal", "personal",
                                      "wpa3-personal", "wpa2-wpa3-personal", "owe", "owe-transition"]

/// WIFI:T:<type>;S:<ssid>;P:<password>;H:true;;  with \ ; , : " escaped.
func wifiQR(ssid: String, security: String, password: String, hidden: Bool) -> String {
  func esc(_ s: String) -> String { s.reduce(into: "") { r, c in if "\\;,:\"".contains(c) { r += "\\" }; r.append(c) } }
  let type = switch security {
  case "open", "owe", "owe-transition": "nopass"
  case "wep": "WEP"
  case "wpa3-personal": "SAE"
  default: "WPA"
  }
  return "WIFI:T:\(type);S:\(esc(ssid));" + (type == "nopass" ? "" : "P:\(esc(password));") + (hidden ? "H:true;" : "") + ";"
}

private let passwordQueue = DispatchQueue(label: "omacvm-bridge.password")   // one prompt at a time

/// The saved password of a network, read from the System keychain. macOS asks
/// for an administrator's approval each time; nothing is cached or logged.
func wifiPassword(ssid wanted: String?, peer: String) throws -> [String: Any] {
  guard let i = wifi.client.interface() else { throw APIError(503, "no Wi-Fi interface") }
  let current = i.ssid()
  guard let ssid = wanted ?? current else { throw APIError(409, "not connected to a Wi-Fi network") }

  // Security: the saved profile, else the scan cache, else the current link.
  let profiles = i.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
  let cached = (i.cachedScanResults() ?? []).filter { $0.ssid == ssid }
  var security: String
  if let p = profiles.first(where: { $0.ssid == ssid }) {
    security = securityName(p.security)
  } else if let n = cached.max(by: { $0.rssiValue < $1.rssiValue }) {
    security = scanSecurityOrder.first { n.supportsSecurity($0) }.map(securityName) ?? "unknown"
  } else if ssid == current {
    security = securityName(i.security())
  } else {
    throw APIError(404, "\(ssid) is not a saved or nearby network")
  }
  if security == "unknown", ssid == current { security = securityName(i.security()) }
  guard shareableSecurity.contains(security) else {
    throw APIError(409, security.contains("enterprise") || security == "dynamic-wep"
                   ? "\(ssid) uses 802.1X (enterprise) sign-in, which a QR code cannot share" : "\(ssid): \(security) cannot be shared")
  }
  // Hidden (best effort): we are on it, but it does not broadcast its name.
  let hidden = ssid == current && cached.isEmpty && !(i.cachedScanResults() ?? []).isEmpty

  var password = ""
  if !["open", "owe", "owe-transition"].contains(security) {
    let sem = DispatchSemaphore(value: 0)
    var status: OSStatus = errSecInternalError
    var data: CFTypeRef?
    passwordQueue.async {
      let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "AirPort",
                                    kSecAttrAccount: ssid, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
      status = SecItemCopyMatching(query as CFDictionary, &data)
      sem.signal()
    }
    guard sem.wait(timeout: .now() + 60) == .success else {
      log("Wi-Fi password for \(ssid) requested by \(peer): no answer to the macOS prompt within 60 s")
      throw APIError(408, "no answer to the macOS prompt")
    }
    switch status {
    case errSecSuccess:
      password = (data as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
      log("Wi-Fi password for \(ssid) requested by \(peer): denied")
      throw APIError(403, "denied")
    case errSecItemNotFound:
      throw APIError(404, "no saved password for \(ssid) on this Mac")
    default:
      throw APIError(500, "keychain error \(status)")
    }
  }
  log("Wi-Fi password for \(ssid) requested by \(peer): granted")
  return ["ssid": ssid, "security": security, "password": password, "hidden": hidden,
          "qr": wifiQR(ssid: ssid, security: security, password: password, hidden: hidden)]
}
