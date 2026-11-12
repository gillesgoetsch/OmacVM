// A steady Wi-Fi state, without CoreWLAN (wifi.swift reads it; test.sh's
// offline tests check this).
//
// On a Mac mini on Ethernet with Wi-Fi also connected, a read now and then
// came back without a channel or a signal (connected=false, ssid null) and
// the next one was fine again: the Bridge sent "disconnected" and "connected"
// every 5-15 s although Wi-Fi was stable. Such a read is most likely taken
// while the radio scans off its channel (macOS scans more while Wi-Fi is not
// the primary network). A real disconnect comes with a CoreWLAN event (link,
// SSID, BSSID, power) and with the system's link state going down.
import Foundation

/// Whether one read is "connected". With Location Services granted, from
/// CoreWLAN's own read (a channel and a signal). Without it (not decided yet
/// after a new Bridge, or "Don't Allow"), macOS 27's CoreWLAN gives a channel
/// with no signal and no SSID most of the time, as for an unauthorized
/// reader: then the system's link state of the interface decides (associated
/// or not), and the network's name stays hidden.
enum WiFiRead {
  static func connected(power: Bool, channel: Bool, rssi: Int, locationOK: Bool, link: Bool?) -> Bool {
    guard power else { return false }
    if !locationOK, let link { return link }
    return channel && rssi < 0
  }
}

struct WiFiSteady {
  /// A lone "not connected" without an event is believed after this long.
  static let hold: TimeInterval = 10
  /// While the system says the link is up, only bad reads for this long, with
  /// no good one between, are believed (a real drop the link state missed).
  static let linkHold: TimeInterval = 60
  /// An event this long before the drop still counts as its cause.
  static let eventSlack: TimeInterval = 2
  /// Fields that are no part of the link and always come from the newest read.
  static let fresh = ["location_authorized", "wired"]

  private(set) var good: [String: Any]?   // the last read that was connected
  private var dropSince: Date?
  private var linkBadSince: Date?          // bad reads in a row while the link was up

  /// `raw`: one read; `link`: the system's link state of the Wi-Fi interface
  /// (nil: not known); `event`: when CoreWLAN last said link, SSID, BSSID or
  /// power changed. Returns the state to report, and `held` when a "not
  /// connected" read was not believed (yet).
  /// The signal fields; a connected read without them (no Location
  /// Services) keeps the last ones known, so the bar's icon does not drop.
  static let signal = ["rssi", "noise", "snr", "quality", "channel"]

  mutating func take(_ raw: [String: Any], link: Bool?, event: Date?, now: Date) -> (state: [String: Any], held: Bool) {
    if raw["connected"] as? Bool == true {
      var r = raw
      if r["rssi"] is NSNull || r["rssi"] == nil, let good, good["rssi"] is Int {
        for k in Self.signal { r[k] = good[k] }
      }
      good = r; dropSince = nil; linkBadSince = nil
      return (r, false)
    }
    guard let good else { return (raw, false) }
    var keep = good
    for k in Self.fresh { keep[k] = raw[k] }
    if link == true {   // still associated: the read was most likely wrong
      dropSince = nil
      let since = linkBadSince ?? now
      linkBadSince = since
      guard now.timeIntervalSince(since) >= Self.linkHold else { return (keep, true) }
      self.good = nil; linkBadSince = nil
      return (raw, false)
    }
    linkBadSince = nil
    let since = dropSince ?? now
    dropSince = since
    let caused = event.map { $0 >= since - Self.eventSlack } ?? false
    if caused || now.timeIntervalSince(since) >= Self.hold {
      self.good = nil; dropSince = nil
      return (raw, false)
    }
    return (keep, true)
  }
}

/// The network's name, BSSID, security and the country code, kept between
/// reads.
///
/// macOS checks the reader's Location Services grant with locationd on every
/// CoreWLAN read of these four: 25-33 ms of locationd's CPU per read on a
/// MacBook Air M2 on Wi-Fi, for a granted reader (signal, noise, channel,
/// rate, PHY mode and power do not go there). The Bridge re-read them on
/// every 5 s signal tick while a VM listened, so locationd stayed at about
/// 2 % of a core for nothing. They only change with a CoreWLAN event (SSID,
/// BSSID, link, power, country code), which marks them stale. A change of
/// interface, connection or grant reads them again too, and so does a
/// connected read that came without a name. They are also read again once
/// they are `maxAge` old, in case macOS dropped an event (a name that was
/// right again within 5 s before); that costs one read in 5 minutes.
struct WiFiIdentity {
  struct Key: Equatable {
    var interface: String
    var connected: Bool
    var locationOK: Bool
  }

  /// Kept values are read again after this long, event or not.
  static let maxAge: TimeInterval = 300

  private var key: Key?
  private var values: [String: Any] = [:]
  private var stale = true
  private var readAt = Date.distantPast
  /// Counts invalidations, so an event that comes while a read is under way
  /// is not lost when that read is stored.
  private(set) var generation = 0

  /// A CoreWLAN event (or a wake, a new subscription): read them again.
  mutating func invalidate() { stale = true; generation += 1 }

  /// Not stale and younger than `maxAge` (a clock set back counts as old).
  private func fresh(_ now: Date) -> Bool {
    let age = now.timeIntervalSince(readAt)
    return !stale && age >= 0 && age < Self.maxAge
  }

  /// The kept values for this read, or nil: read them from CoreWLAN.
  func cached(_ k: Key, now: Date) -> [String: Any]? { fresh(now) && key == k ? values : nil }

  /// The kept network name of this interface, only from a connected read
  /// that had one; else nil, and the scan reads the name itself. A kept "not
  /// connected" can be a read taken while the radio scanned off its channel,
  /// so it never says there is no current network.
  func keptSSID(_ interface: String, now: Date) -> String? {
    guard fresh(now), let key, key.interface == interface, key.connected else { return nil }
    return values["ssid"] as? String
  }

  /// What was just read at `now`, from a read that began at `generation`
  /// `since`. A connected read with a grant but no name (taken mid-scan) is
  /// not kept, so the next read asks again; nor is one an event overtook.
  mutating func store(_ v: [String: Any], for k: Key, since: Int, now: Date) {
    key = k; values = v; readAt = now
    stale = since != generation || (k.connected && k.locationOK && (v["ssid"] == nil || v["ssid"] is NSNull))
  }
}
