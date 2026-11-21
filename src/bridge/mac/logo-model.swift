// The lit Apple logo on the lid of a MacBook Pro that has one (feature
// logo-light): the modes a VM asks for (LogoMode), the curves (LogoCurve), and
// what plays a mode frame by frame next to macOS's own driver of the logo,
// corebrightnessd (LogoPlayer). Plain logic: the hardware and corebrightnessd
// come in as LogoHardware, so src/tests/logo-light.sh tests all of it on a
// made-up logo. logo.swift has the real one.
import Foundation

/// A mode as a VM asks for it. The guest's `omacvm-logo` says it in words,
/// /logo in JSON.
enum LogoMode: Equatable {
  case auto                 // macOS lights the logo, as without OmacVM
  case off                  // dark, through macOS's own state for a blank display
  case on(percent: Int)     // steady, at a perceived brightness (LogoCurve.onTicks)

  static let percents = 1...100, defaultPercent = 50   // 50: about macOS's own level in a lit room

  /// The words that set it again: auto, off, on 50.
  var words: String {
    switch self {
    case .auto: return "auto"
    case .off: return "off"
    case .on(let p): return "on \(p)"
    }
  }

  var json: [String: Any] {
    switch self {
    case .auto: return ["mode": "auto"]
    case .off: return ["mode": "off"]
    case .on(let p): return ["mode": "on", "percent": p]
    }
  }

  /// The Bridge writes the logo itself (on); auto and off leave the writes to
  /// corebrightnessd.
  var plays: Bool { if case .on = self { return true }; return false }

  /// POST /logo's body from the VM: {"mode": "auto"}, {"mode": "off"} or
  /// {"mode": "on", "percent": 1-100}, percent left out for 50. Only these
  /// words, a whole number in range, and no other key.
  static func parse(_ body: Data) -> Result<LogoMode, PolicyError> {
    let o: [String: Any]
    do {
      guard let x = try strictObject(body, allowed: ["mode", "percent"]) else {
        return .failure(PolicyError(400, "mode", "send {\"mode\": \"auto\"|\"off\"|\"on\"}"))
      }
      o = x
    } catch let e as PolicyError { return .failure(e) } catch { return .failure(PolicyError(400, "bad-json", "\(error)")) }
    switch o["mode"] as? String ?? "" {
    case "auto" where o.count == 1: return .success(.auto)
    case "off" where o.count == 1: return .success(.off)
    case "auto", "off": return .failure(PolicyError(400, "mode", "auto and off take no percent"))
    case "on":
      guard let v = o["percent"] else { return .success(.on(percent: defaultPercent)) }
      guard let p = strictInt(v, in: percents) else {
        return .failure(PolicyError(400, "percent", "percent: a whole number, \(percents.lowerBound) to \(percents.upperBound)"))
      }
      return .success(.on(percent: p))
    default:
      return .failure(PolicyError(400, "mode", "mode: auto, off or on"))
    }
  }
}

/// The logo's PWM and the eye. Measured on a MacBook Pro Mac17,13 (M5 Pro,
/// macOS 27.2): one white LED, `AppleARMPWMDevice` bklb-backlight, a 25 kHz
/// carrier from a 24 MHz clock, so a period of 960 ticks; the IORegistry's
/// high-period is the duty in ticks.
enum LogoCurve {
  static let period = 960
  /// The brightest macOS drives this logo: 1000 nits, about 80 % duty.
  static let maxDuty = 0.8
  /// Seconds of every change: into a mode, between modes, out of one.
  static let fade = 3.0

  /// CIE 1976 lightness L* of a luminance relative to a white, and back. The
  /// eye sees L* steps as even, and the LED's luminance follows its duty.
  static func lightness(_ y: Double) -> Double { 116 * cbrt(y) - 16 }
  static func luminance(_ l: Double) -> Double { pow((l + 16) / 116, 3) }

  /// The scale every fade moves on: L* of a duty, maxDuty as 100. A straight
  /// line in it looks even.
  static func level(ofTick t: Int) -> Double { lightness(Double(t) / Double(period) / maxDuty) }
  static func tick(ofLevel l: Double) -> Int { Int((min(luminance(l), 1) * maxDuty * Double(period)).rounded()) }

  /// on's percent as ticks: L* on that scale, with the standard's straight
  /// part below L* 8 (a cube root there would give the dimmest steps too
  /// much). on 50 is about 15 % duty, near the 17 to 21 % macOS gives it in a
  /// lit room.
  static func onTicks(_ percent: Int) -> Int {
    let l = Double(percent)
    let y = l > 8 ? luminance(l) : l / 903.3
    return max(1, Int((maxDuty * y * Double(period)).rounded()))
  }

  /// The driver's duty for `tick` ticks: duty × 2^32, rounded up, so that the
  /// readback shows that tick.
  static func raw(ofTick t: Int) -> UInt64 { (UInt64(t) << 32 + UInt64(period) - 1) / UInt64(period) }

  /// 0 to 1, with no slope at either end, so no fade has an edge.
  static func ease(_ u: Double) -> Double { (1 - cos(Double.pi * u)) / 2 }
}

/// The logo's PWM and corebrightnessd, as LogoPlayer uses them (logo.swift:
/// the real ones; the tests: a made-up logo).
protocol LogoHardware: AnyObject {
  /// The PWM as the IORegistry shows it: switched on, and its high period in ticks.
  func readback() -> (on: Bool, high: Int)
  /// One plain duty write of `tick` ticks, switched on, as corebrightnessd's own. False: refused.
  func write(_ tick: Int) -> Bool
  /// Duty 0, switched off.
  func dark()
  /// corebrightnessd's fade factor (0 while the display sleeps or the lid is
  /// closed, 1 while lit) and the level it wants now, in ticks.
  func macOS() -> (factor: Double, tick: Int)
  /// The level corebrightnessd wants now, written as its own write would be.
  func handBack()
  /// corebrightnessd hears that the display is blank (true) or lit, and fades
  /// the logo out or back in over `fade` seconds; after a blank every keyboard
  /// hears that the display is lit, so its backlight stays as it was.
  func blank(_ blank: Bool, fade: Double)
  /// corebrightnessd's fades take their own length again.
  func resetFade()
  func note(_ event: String, _ fields: [String: Any])
}

/// Plays a mode on the logo, one frame at a time, next to corebrightnessd,
/// which owns the logo otherwise. corebrightnessd writes its own level
/// whenever the room's light or the display's brightness changes, in bursts of
/// 1 to 7 s at about 120 Hz, and fades the logo out while the display sleeps
/// or the lid is closed. So on yields to every write that is not its own and
/// fades back in from the level the logo has once it stood still for a
/// second, and never lights the logo while corebrightnessd's factor is below
/// 1. off is corebrightnessd's own blank state, which holds the logo dark
/// through its changes. Every change fades over LogoCurve.fade.
struct LogoPlayer {
  enum Phase: Equatable {
    case idle        // corebrightnessd writes the logo (auto, off, or on while the display sleeps)
    case waiting     // on waits for corebrightnessd's level to stand still and the display to be lit
    case playing     // on writes the logo
    case fadingOut   // fades toward off or toward corebrightnessd's level
  }
  static let frame = 1.0 / 60   // a write a frame at most, as corebrightnessd's own fades (about 120 Hz) need no more
  static let slowFrame = 0.1    // while nothing of ours moves: macOS's writes are seen within it
  static let still = 1.0        // seconds macOS's level stands still before a mode fades back in

  private(set) var applied = LogoMode.auto
  private(set) var phase = Phase.idle
  private var blanked = false
  private var written: Int?   // our last write, while it is ours
  private var high = -1, changedAt = 0.0, blankAt = -Double.infinity, factorAt = -Double.infinity
  private var resetFadeAt: Double?
  private var fadeAt = 0.0, from = 0.0, to = 0.0, out = 0.0

  /// One frame at `t` (seconds, monotonic) toward `want`. Returns the seconds
  /// to the next frame, nil when nothing is due until the mode changes.
  mutating func frame(_ t: Double, want: LogoMode, hw: LogoHardware) -> Double? {
    if let r = resetFadeAt, t >= r { hw.resetFade(); resetFadeAt = nil }
    let rb = hw.readback()
    if rb.high != high { high = rb.high; changedAt = t }
    var lit = rb.on

    if want != applied {
      hw.note("mode", ["mode": want.words, "was": applied.words])
      if phase == .playing || phase == .fadingOut {
        // From the level on the lid, to the new mode's.
        from = written.map(LogoCurve.level(ofTick:)) ?? out
        if want.plays {
          phase = .playing
          if case .on(let p) = want { to = LogoCurve.level(ofTick: LogoCurve.onTicks(p)) }
        } else {
          phase = .fadingOut
          to = LogoCurve.level(ofTick: want == .off ? 0 : hw.macOS().tick)
        }
        fadeAt = t
      } else {
        // corebrightnessd has the logo: it fades it to dark or back to its level itself.
        if blanked && want != .off { blank(false, LogoCurve.fade, t, hw) }
        if want == .off && !blanked && lit { blank(true, LogoCurve.fade, t, hw) }
        phase = want.plays ? .waiting : .idle
      }
      applied = want
    }

    // While we write, a readback other than our own, a logo that went off, or
    // a factor below 1 means corebrightnessd took the logo: its fade for the
    // room's light, the display's sleep, or the lid. A write of ours can land
    // just after corebrightnessd switched the logo off, so the factor is read
    // once a second too.
    if phase == .playing || phase == .fadingOut {
      var factor = 1.0
      if t - factorAt >= 1 { factorAt = t; factor = hw.macOS().factor }
      if !lit || (written != nil && rb.high != written) || factor < 1 {
        // The display sleeps: never lit by us, and off for the rest of this frame.
        if factor < 1 { if lit && rb.high == written { hw.dark() }; lit = false }
        hw.note("yield", ["on": rb.on, "high": rb.high, "ours": written ?? -1, "factor": factor])
        // Into off while the display is lit: corebrightnessd fades it out. After
        // the display's sleep the rule for off below blanks it once it is lit
        // again, so no keyboard hears lit while the display sleeps.
        if phase == .fadingOut && applied == .off && lit { blank(true, LogoCurve.fade, t, hw) }
        phase = phase == .playing ? .waiting : .idle
        written = nil
        changedAt = t
      }
    }

    // A mode fades in once corebrightnessd's level stands still and the display is lit, from that level.
    if phase == .waiting, lit, t - changedAt > Self.still, hw.macOS().factor >= 1 {
      phase = .playing
      if case .on(let p) = applied { to = LogoCurve.level(ofTick: LogoCurve.onTicks(p)) }
      fadeAt = t
      from = LogoCurve.level(ofTick: rb.high)
      hw.note("fade-in", ["high": rb.high])
    }

    if phase == .playing || phase == .fadingOut {
      let w = LogoCurve.ease(min(1, (t - fadeAt) / LogoCurve.fade))
      out = from + (to - from) * w
      var tick = LogoCurve.tick(ofLevel: out)
      // A duty of 0 would switch the logo off under corebrightnessd: the fade to off ends on its last tick.
      if phase == .fadingOut && applied == .off { tick = max(tick, 1) }
      if tick != written && hw.write(tick) { written = tick; high = tick }
      if phase == .fadingOut && w >= 1 {
        // Faded to dark: corebrightnessd hears blank at once, as the logo is dark
        // already. Faded to its level: the logo is its own again.
        if applied == .off { hw.dark(); blank(true, 1e-9, t, hw) } else { hw.handBack() }
        hw.note("faded-out", ["to": applied.words])
        phase = .idle
        written = nil
      }
    }

    // A display that woke is lit again in corebrightnessd's state: off blanks it again.
    if applied == .off && phase == .idle && lit && rb.high > 0 && t - blankAt > LogoCurve.fade + 1.5 {
      blank(true, LogoCurve.fade, t, hw)
    }

    switch phase {
    case .playing: return t - fadeAt >= LogoCurve.fade ? Self.slowFrame : Self.frame   // steady after its fade
    case .fadingOut: return Self.frame
    case .waiting: return Self.slowFrame
    case .idle:
      if applied == .off { return Self.slowFrame }
      return resetFadeAt.map { max(0, $0 - t) }
    }
  }

  /// The Bridge stops: macOS has the logo again at once. A blank ends with
  /// corebrightnessd's own fade, so nothing of ours stays in its state.
  mutating func release(hw: LogoHardware) {
    if blanked { hw.blank(false, fade: 0); blanked = false }
    if phase == .playing || phase == .fadingOut { hw.handBack() }
    hw.resetFade()
    resetFadeAt = nil
    applied = .auto
    phase = .idle
    written = nil
  }

  private mutating func blank(_ on: Bool, _ fade: Double, _ t: Double, _ hw: LogoHardware) {
    hw.blank(on, fade: fade)
    blanked = on
    resetFadeAt = t + fade + 1
    if on { blankAt = t }
    hw.note(on ? "blank" : "unblank", ["fade": fade])
  }
}
