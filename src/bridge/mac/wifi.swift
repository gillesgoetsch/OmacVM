// Wi-Fi side: CoreWLAN state, scans and events, plus the Location Services
// permission that macOS requires before it reveals SSIDs/BSSIDs.
import AppKit
import CoreLocation
import CoreWLAN
import SystemConfiguration

func securityName(_ s: CWSecurity) -> String {
  switch s {
  case .none: "open"
  case .WEP: "wep"
  case .dynamicWEP: "dynamic-wep"
  case .wpaPersonal: "wpa-personal"
  case .wpaPersonalMixed: "wpa-wpa2-personal"
  case .wpa2Personal: "wpa2-personal"
  case .personal: "personal"
  case .wpaEnterprise: "wpa-enterprise"
  case .wpaEnterpriseMixed: "wpa-wpa2-enterprise"
  case .wpa2Enterprise: "wpa2-enterprise"
  case .enterprise: "enterprise"
  case .wpa3Personal: "wpa3-personal"
  case .wpa3Enterprise: "wpa3-enterprise"
  case .wpa3Transition: "wpa2-wpa3-personal"
  case .OWE: "owe"
  case .oweTransition: "owe-transition"
  default: "unknown"
  }
}
// A scanned network can support several modes; report the strongest.
let scanSecurityOrder: [CWSecurity] = [.wpa3Enterprise, .wpa3Transition, .wpa3Personal, .wpa2Enterprise,
  .wpaEnterpriseMixed, .wpaEnterprise, .enterprise, .wpaPersonalMixed, .wpa2Personal, .wpaPersonal, .personal,
  .oweTransition, .OWE, .dynamicWEP, .WEP, .none]

func bandName(_ b: CWChannelBand) -> String? {
  switch b {
  case .band2GHz: "2.4GHz"
  case .band5GHz: "5GHz"
  case .band6GHz: "6GHz"
  default: nil
  }
}

func widthMHz(_ w: CWChannelWidth) -> Int? {
  switch w {
  case .width20MHz: 20
  case .width40MHz: 40
  case .width80MHz: 80
  case .width160MHz: 160
  default: nil
  }
}

func channelInfo(_ c: CWChannel?) -> Any {
  guard let c else { return NSNull() }
  return ["number": c.channelNumber, "band": nn(bandName(c.channelBand)), "width_mhz": nn(widthMHz(c.channelWidth))]
}

let phyNames = [1: "802.11a", 2: "802.11b", 3: "802.11g", 4: "802.11n", 5: "802.11ac", 6: "802.11ax", 7: "802.11be"]

// 0..100 from RSSI: -90 dBm and below = 0, -30 dBm and above = 100.
func quality(_ rssi: Int) -> Int { max(0, min(100, (rssi + 90) * 100 / 60)) }

/// The Wi-Fi state without the signal's jitter: the bar's icon level (the
/// guest's wifiIconFor: one of five) instead of the exact figures.
func coarseWiFi(_ s: [String: Any]) -> [String: Any] {
  var c = s
  for k in ["rssi", "noise", "snr", "tx_rate_mbps"] { c[k] = nil }
  if let q = s["quality"] as? Int { c["quality"] = max(0, min(4, (q + 19) / 20 - 1)) }
  return c
}

func describeWiFi(_ old: [String: Any], _ s: [String: Any]) -> String? {
  let keys = ["power", "connected", "ssid", "bssid", "location_authorized", "channel"]
  guard keys.contains(where: { !same(old[$0], s[$0]) }) else { return nil }   // RSSI-only changes stay quiet
  let ch = (s["channel"] as? [String: Any]).map { "\($0["number"]!)/\($0["band"]!)" } ?? "-"
  return "power=\(s["power"]!) connected=\(s["connected"]!) ssid=\(s["ssid"]!) ch=\(ch) rssi=\(s["rssi"]!)"
}

// ---- Location Services (needed for SSID/BSSID) ----
final class Location: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private let lock = NSLock()
  private var ok = false
  var onChange: (() -> Void)?

  var authorized: Bool { lock.lock(); defer { lock.unlock() }; return ok }

  func start() { manager.delegate = self }   // delivers the current status right away

  func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
    let status = m.authorizationStatus
    lock.lock(); ok = status == .authorizedAlways; lock.unlock()   // macOS has no separate "when in use"
    switch status {
    case .notDetermined:
      log("Location Services: not decided yet, asking (macOS shows a prompt)")
      NSApp.activate(ignoringOtherApps: true)
      m.requestWhenInUseAuthorization()
    case .denied, .restricted:
      log("Location Services: DENIED - SSID/BSSID will be null. Grant in System Settings > Privacy & Security > Location Services > OmacVM Bridge")
    default:
      log("Location Services: granted")
    }
    onChange?()
  }
}

// ---- CoreWLAN ----
final class WiFi: NSObject, CWEventDelegate {
  let client = CWWiFiClient.shared()
  var onEvent: ((String) -> Void)?
  private let lock = NSLock()
  private var linkEvent: Date?        // CoreWLAN's last link, SSID, BSSID or power event
  private var identity = WiFiIdentity()   // under lock
  private var steady = WiFiSteady()   // state() only (the hub's queue)
  private var heldLogged = Date.distantPast
  private let store = SCDynamicStoreCreate(nil, "omacvm-bridge" as CFString, nil, nil)

  func start() { client.delegate = self; subscribe() }

  func subscribe() {
    forgetIdentity()   // start, wake, a new connection to CoreWLAN: events may have been missed
    try? client.stopMonitoringAllEvents()
    let events: [CWEventType] = [.powerDidChange, .ssidDidChange, .bssidDidChange, .linkDidChange,
                                 .modeDidChange, .countryCodeDidChange, .scanCacheUpdated]
    for e in events {
      do { try client.startMonitoringEvent(with: e) } catch { log("cannot monitor CoreWLAN event \(e.rawValue): \(error)") }
    }
  }

  func powerStateDidChangeForWiFiInterface(withName name: String) { linkChanged(); onEvent?("power") }
  func ssidDidChangeForWiFiInterface(withName name: String) { linkChanged(); onEvent?("ssid") }
  func bssidDidChangeForWiFiInterface(withName name: String) { linkChanged(); onEvent?("bssid") }
  func linkDidChangeForWiFiInterface(withName name: String) { linkChanged(); onEvent?("link") }
  func modeDidChangeForWiFiInterface(withName name: String) { forgetIdentity(); onEvent?("mode") }
  func countryCodeDidChangeForWiFiInterface(withName name: String) { forgetIdentity(); onEvent?("country") }
  func scanCacheUpdatedForWiFiInterface(withName name: String) { onEvent?("scan-cache") }
  func clientConnectionInterrupted() { resubscribe("interrupted") }
  func clientConnectionInvalidated() { resubscribe("invalidated") }

  private func resubscribe(_ why: String) {
    log("CoreWLAN connection \(why), subscribing again")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.subscribe() }
  }

  // Whether the Mac's primary connection is wired (Ethernet, Thunderbolt or USB
  // network adapters: an "en" interface that is not the Wi-Fi one), like a
  // Mac mini on a cable. VPN tunnels (utun) do not count.
  func wiredPrimary(wifiName: String?) -> Bool {
    guard let store, let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
          let primary = g["PrimaryInterface"] as? String else { return false }
    return primary.hasPrefix("en") && primary != wifiName
  }

  private func linkChanged() { lock.lock(); linkEvent = Date(); identity.invalidate(); lock.unlock() }
  /// The name, BSSID and country code are read from CoreWLAN again at the next read.
  func forgetIdentity() { lock.lock(); identity.invalidate(); lock.unlock() }

  /// Whether the system has a link on this interface (associated, for
  /// Wi-Fi). configd keeps it from the kernel's link events, so a radio scan
  /// does not change it. nil: not known.
  func linkActive(_ name: String?) -> Bool? {
    guard let name, let store,
          let d = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any]
    else { return nil }
    return d["Active"] as? Bool
  }

  /// The Wi-Fi interface: CoreWLAN's default one; with several (a second
  /// Wi-Fi adapter), the one with a link. CoreWLAN lists Wi-Fi only (a Mac
  /// mini's Ethernet en0 is never one of them; its Wi-Fi is en1).
  private func pick() -> CWInterface? {
    let all = client.interfaces() ?? []
    guard all.count > 1 else { return client.interface() ?? all.first }
    return all.first { linkActive($0.interfaceName) == true } ?? client.interface()
  }

  /// The state to report: one read, kept steady (WiFiSteady). The hub's queue.
  func state(locationOK: Bool) -> [String: Any] {
    let (raw, problem, name) = read(locationOK: locationOK)
    lock.lock(); let event = linkEvent; lock.unlock()
    let (s, held) = steady.take(raw, link: linkActive(name), event: event, now: Date())
    if held, let problem, Date().timeIntervalSince(heldLogged) >= 600 {
      heldLogged = Date()
      log("wifi: a read said not connected (\(problem)) without a Wi-Fi event\(linkActive(name) == true ? " while \(name!) has a link" : ""): kept the last state (this line at most every 10 min)")
    }
    return s
  }

  /// One read of CoreWLAN, what made it "not connected", and the interface.
  private func read(locationOK: Bool) -> ([String: Any], String?, String?) {
    let detail = ["ssid", "bssid", "rssi", "noise", "snr", "quality", "channel", "security", "secure",
                  "tx_rate_mbps", "phy_mode", "can_share"]
    var s: [String: Any] = ["location_authorized": locationOK]
    for k in detail { s[k] = NSNull() }
    guard let i = pick() else {
      s["interface"] = NSNull(); s["power"] = false; s["connected"] = false; s["country_code"] = NSNull()
      s["wired"] = wiredPrimary(wifiName: nil)
      return (s, "no Wi-Fi interface", nil)
    }
    s["wired"] = wiredPrimary(wifiName: i.interfaceName)
    let power = i.powerOn()
    let channel = power ? i.wlanChannel() : nil
    let rssi = i.rssiValue()
    let link = linkActive(i.interfaceName)
    let connected = WiFiRead.connected(power: power, channel: channel != nil, rssi: rssi, locationOK: locationOK, link: link)
    let problem = connected ? nil : !power ? "power off" : !locationOK && link == false ? "no link (without Location Services)"
      : channel == nil ? "no channel, rssi \(rssi)" : "rssi \(rssi)"
    s["interface"] = nn(i.interfaceName)
    s["power"] = power
    s["connected"] = connected
    // Name, BSSID, country code: from CoreWLAN only when they may have
    // changed (WiFiIdentity: each read costs locationd a grant check).
    let key = WiFiIdentity.Key(interface: i.interfaceName ?? "", connected: connected, locationOK: locationOK)
    lock.lock(); let kept = identity.cached(key), since = identity.generation; lock.unlock()
    let id = kept ?? {
      var v: [String: Any] = ["country_code": nn(i.countryCode())]
      if connected { v["ssid"] = nn(i.ssid()); v["bssid"] = nn(i.bssid()) }
      lock.lock(); identity.store(v, for: key, since: since); lock.unlock()
      return v
    }()
    s["country_code"] = id["country_code"] ?? NSNull()
    if connected {
      let noise = i.noiseMeasurement(), sec = i.security()
      s["ssid"] = id["ssid"] ?? NSNull(); s["bssid"] = id["bssid"] ?? NSNull()
      // Without Location Services a read may have no signal: shown as unknown.
      if rssi < 0 {
        s["rssi"] = rssi; s["noise"] = noise; s["snr"] = rssi - noise; s["quality"] = quality(rssi)
        s["channel"] = channelInfo(channel)
      }
      s["security"] = securityName(sec); s["secure"] = sec != .none
      s["can_share"] = shareableSecurity.contains(securityName(sec))   // QR sharing via /wifi/password
      s["tx_rate_mbps"] = i.transmitRate()
      s["phy_mode"] = nn(phyNames[i.activePHYMode().rawValue])
    }
    return (s, problem, i.interfaceName)
  }

  // Saved networks: readable without admin rights or Location Services.
  func knownSSIDs() -> Set<String> {
    let profiles = client.interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
    return Set(profiles.compactMap { $0.ssid })
  }

  // One entry per SSID (the strongest BSSID), current network first, then by RSSI.
  func scan(cached: Bool) throws -> [[String: Any]] {
    guard let i = client.interface() else { throw APIError(503, "no Wi-Fi interface") }
    guard i.powerOn() else { throw APIError(503, "Wi-Fi is off") }
    let found: Set<CWNetwork> = cached ? (i.cachedScanResults() ?? []) : try i.scanForNetworks(withName: nil)
    lock.lock(); let kept = identity.keptSSID(i.interfaceName ?? ""); lock.unlock()
    let known = knownSSIDs(), current = kept ?? i.ssid()
    var best: [String: CWNetwork] = [:], bands: [String: Set<String>] = [:]
    for n in found {
      guard let ssid = n.ssid, !ssid.isEmpty else { continue }   // hidden, or no Location permission
      if let b = n.wlanChannel.flatMap({ bandName($0.channelBand) }) { bands[ssid, default: []].insert(b) }
      if best[ssid].map({ n.rssiValue > $0.rssiValue }) ?? true { best[ssid] = n }
    }
    let rank = { (n: CWNetwork) in (n.ssid == current ? 1 : 0, n.rssiValue) }
    return best.values.sorted { rank($0) > rank($1) }.map { n in
      let ssid = n.ssid!
      let sec = scanSecurityOrder.first { n.supportsSecurity($0) }
      return ["ssid": ssid, "bssid": nn(n.bssid), "rssi": n.rssiValue, "noise": n.noiseMeasurement < 0 ? n.noiseMeasurement : NSNull(),
              "quality": quality(n.rssiValue), "channel": channelInfo(n.wlanChannel),
              "bands": (bands[ssid] ?? []).sorted(), "security": sec.map(securityName) ?? "unknown",
              "secure": sec.map { $0 != .none } ?? true, "known": known.contains(ssid), "current": ssid == current]
    }
  }
}

func scanBody(_ nets: [[String: Any]], source: String, at: Date, locationOK: Bool) -> [String: Any] {
  ["networks": nets, "count": nets.count, "source": source, "scanned_at": isoFormat.string(from: at),
   "location_authorized": locationOK]
}

final class Scanner {
  private let q = DispatchQueue(label: "omacvm-bridge.scan")   // one radio scan at a time
  private var last: (Date, [[String: Any]])?
  private var lastCachePush = Date.distantPast
  let wifi: WiFi, hub: Hub, location: Location
  init(wifi: WiFi, hub: Hub, location: Location) { self.wifi = wifi; self.hub = hub; self.location = location }

  func scan(cached: Bool) -> (Int, [String: Any]) {
    q.sync {
      do {
        if cached { return (200, scanBody(try wifi.scan(cached: true), source: "cache", at: Date(), locationOK: location.authorized)) }
        if let (at, nets) = last, Date().timeIntervalSince(at) < recentScanSeconds {
          return (200, scanBody(nets, source: "recent-scan", at: at, locationOK: location.authorized))
        }
        let nets = try wifi.scan(cached: false), at = Date()
        last = (at, nets)
        let body = scanBody(nets, source: "scan", at: at, locationOK: location.authorized)
        hub.send("scan", body)
        return (200, body)
      } catch let e as APIError {
        return (e.status, ["error": e.message])
      } catch {
        log("scan failed: \(error.localizedDescription)")
        return (503, ["error": error.localizedDescription])
      }
    }
  }

  // macOS refreshed its scan cache (it scans on its own now and then): push it, at most every 10 s.
  func cacheUpdated() {
    q.async { [self] in
      guard hub.hasClients, Date().timeIntervalSince(lastCachePush) >= recentScanSeconds,
            let nets = try? wifi.scan(cached: true) else { return }
      lastCachePush = Date()
      hub.send("scan", scanBody(nets, source: "cache", at: Date(), locationOK: location.authorized))
    }
  }
}
