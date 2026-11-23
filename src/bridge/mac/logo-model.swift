// The lit Apple logo on the lid of a MacBook Pro that has one (feature
// logo-light): the modes a VM asks for (LogoMode), the curves (LogoCurve), the
// breath (Breath), and what plays a mode frame by frame next to macOS's own
// driver of the logo, corebrightnessd (LogoPlayer). Plain logic: the hardware
// and corebrightnessd come in as LogoHardware, so src/tests/logo-light.sh tests
// all of it on a made-up logo. logo.swift has the real one.
import Foundation

/// A mode as a VM asks for it. The guest's `omacvm-logo` says it in words,
/// /logo in JSON.
enum LogoMode: Equatable {
  case auto                 // macOS lights the logo, as without OmacVM
  case off                  // dark, through macOS's own state for a blank display
  case on(percent: Int)     // steady, at a perceived brightness (LogoCurve.onTicks)
  case breathe(rate: Int)   // breaths a minute (Breath)

  static let percents = 1...100, defaultPercent = 50   // 50: about macOS's own level in a lit room
  static let rates = 6...30, defaultRate = 15

  /// The words that set it again: auto, off, on 50, breathe 15.
  var words: String {
    switch self {
    case .auto: return "auto"
    case .off: return "off"
    case .on(let p): return "on \(p)"
    case .breathe(let r): return "breathe \(r)"
    }
  }

  var json: [String: Any] {
    switch self {
    case .auto: return ["mode": "auto"]
    case .off: return ["mode": "off"]
    case .on(let p): return ["mode": "on", "percent": p]
    case .breathe(let r): return ["mode": "breathe", "rate": r]
    }
  }

  /// The Bridge writes the logo itself (on, breathe); auto and off leave the
  /// writes to corebrightnessd.
  var plays: Bool {
    switch self {
    case .on, .breathe: return true
    case .auto, .off: return false
    }
  }

  /// POST /logo's body from the VM: {"mode": "auto"}, {"mode": "off"},
  /// {"mode": "on", "percent": 1-100} or {"mode": "breathe", "rate": 6-30};
  /// percent and rate may be left out (the defaults). Only these words, whole
  /// numbers in range, and no other key.
  static func parse(_ body: Data) -> Result<LogoMode, PolicyError> {
    let o: [String: Any]
    do {
      guard let x = try strictObject(body, allowed: ["mode", "percent", "rate"]) else {
        return .failure(PolicyError(400, "mode", "send {\"mode\": \"auto\"|\"off\"|\"on\"|\"breathe\"}"))
      }
      o = x
    } catch let e as PolicyError { return .failure(e) } catch { return .failure(PolicyError(400, "bad-json", "\(error)")) }
    switch o["mode"] as? String ?? "" {
    case "auto" where o.count == 1: return .success(.auto)
    case "off" where o.count == 1: return .success(.off)
    case "auto", "off": return .failure(PolicyError(400, "mode", "auto and off take no percent or rate"))
    case "on" where o["rate"] == nil:
      guard let v = o["percent"] else { return .success(.on(percent: defaultPercent)) }
      guard let p = strictInt(v, in: percents) else {
        return .failure(PolicyError(400, "percent", "percent: a whole number, \(percents.lowerBound) to \(percents.upperBound)"))
      }
      return .success(.on(percent: p))
    case "breathe" where o["percent"] == nil:
      guard let v = o["rate"] else { return .success(.breathe(rate: defaultRate)) }
      guard let r = strictInt(v, in: rates) else {
        return .failure(PolicyError(400, "rate", "rate: breaths a minute, a whole number, \(rates.lowerBound) to \(rates.upperBound)"))
      }
      return .success(.breathe(rate: r))
    case "on", "breathe": return .failure(PolicyError(400, "mode", "on takes a percent, breathe a rate"))
    default:
      return .failure(PolicyError(400, "mode", "mode: auto, off, on or breathe"))
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

  /// The scale every fade and the breath move on: L* of a duty, maxDuty as
  /// 100. A straight line in it looks even.
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

/// One breath of `breathe`: when it starts, how long it breathes in and out,
/// how deep, and the slow noise it hands the next one. The numbers were
/// picked by eye on the lid: a breath with the shape of a lung's volume, a
/// soft turn at the top and a fall that slows into a long tail, whose length,
/// depth and split of in and out wander from breath to breath, with a deeper,
/// longer one now and then. A perfect loop looked mechanical whatever its curve.
struct Breath {
  static let inhaleShare = 0.35  // of a breath: in quicker than out
  static let tail = 2.0          // the exhale slows into a long tail, 1 - (1 - u)^2, instead of a flat rest
  static let floorDuty = 0.045   // the bottom, which reads as resting, not as near dark
  static let peakDuty = 0.25     // the top of a breath of depth 1, near macOS's own 17 to 21 % in a lit room
  static let vary = 2.0          // at 1, one standard deviation is 10 % of a breath's length, 12 % of its depth
                                 // and 8 % of its inhale share; the noise is cut at two
  static let drift = 0.4         // how much of a breath's noise the next one keeps, so the breath wanders
  static let sigh = 8.0          // breaths between deeper, longer ones, on average: 1.35 deep, 1.4 in, 1.5 out
  static let floor = LogoCurve.lightness(floorDuty / LogoCurve.maxDuty), peak = LogoCurve.lightness(peakDuty / LogoCurve.maxDuty)

  private(set) var start = 0.0, inhale = 0.0, exhale = 0.0, depth = 1.0, deeper = false
  private var nLen = 0.0, nDepth = 0.0, nShare = 0.0

  /// The breath after this one, starting at `start`. `random`: uniform in (0, 1].
  func next(at start: Double, rate: Int, random: () -> Double) -> Breath {
    func gauss() -> Double { sqrt(-2 * log(random())) * cos(2 * Double.pi * random()) }
    func clip(_ n: Double) -> Double { max(-2, min(2, n)) }
    var b = self
    let fresh = (1 - Self.drift * Self.drift).squareRoot()
    b.nLen = Self.drift * nLen + fresh * gauss()
    b.nDepth = Self.drift * nDepth + fresh * gauss()
    b.nShare = Self.drift * nShare + fresh * gauss()
    let length = 60 / Double(rate) * (1 + 0.10 * Self.vary * clip(b.nLen))
    let share = Self.inhaleShare * (1 + 0.08 * Self.vary * clip(b.nShare))
    b.depth = 1 + 0.12 * Self.vary * clip(b.nDepth)
    b.inhale = length * share
    b.exhale = length - b.inhale
    b.deeper = random() <= 1 / Self.sigh
    if b.deeper { b.depth *= 1.35; b.inhale *= 1.4; b.exhale *= 1.5 }
    b.start = start
    return b
  }

  /// Its level (LogoCurve.level) at `t`, going on to the next breath when this
  /// one is over: in (1 - cos)/2, out (1 + cos(pi f))/2, both still at their ends.
  mutating func level(at t: Double, rate: Int, random: () -> Double) -> Double {
    while t >= start + inhale + exhale { self = next(at: start + inhale + exhale, rate: rate, random: random) }
    let x = t - start
    let v = x < inhale ? (1 - cos(Double.pi * x / inhale)) / 2
      : (1 + cos(Double.pi * (1 - pow(1 - (x - inhale) / exhale, Self.tail)))) / 2
    return Self.floor + (Self.peak - Self.floor) * depth * v
  }
}

/// The logo's PWM and corebrightnessd, as LogoPlayer uses them (logo.swift:
/// the real ones; the tests: a made-up logo).
protocol LogoHardware: AnyObject {
  /// The PWM as the IORegistry shows it: switched on, and its high period in ticks (-1: it shows none).
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
/// or the lid is closed. So on and breathe yield to every write that is not
/// theirs and fade back in from the level the logo has once it stood still for
/// a second, and never light the logo while corebrightnessd's factor is below
/// 1. off is corebrightnessd's own blank state, which holds the logo dark
/// through its changes. Every change fades over LogoCurve.fade.
struct LogoPlayer {
  enum Phase: Equatable {
    case idle        // corebrightnessd writes the logo (auto, off, or a playing mode while the display sleeps)
    case waiting     // on or breathe waits for corebrightnessd's level to stand still and the display to be lit
    case playing     // on or breathe writes the logo
    case fadingOut   // fades toward off or toward corebrightnessd's level
  }
  static let frame = 1.0 / 60   // a write a frame at most, as corebrightnessd's own fades (about 120 Hz) need no more
  static let slowFrame = 0.1    // while nothing of ours moves: macOS's writes are seen within it
  static let still = 1.0        // seconds macOS's level stands still before a mode fades back in

  private(set) var applied = LogoMode.auto
  private(set) var phase = Phase.idle
  private var blanked = false
  private let random: () -> Double
  private var breath = Breath()
  private var written: Int?   // our last write, while it is ours
  private var high = -1, changedAt = 0.0, blankAt = -Double.infinity, factorAt = -Double.infinity
  private var resetFadeAt: Double?
  private var fadeAt = 0.0, from = 0.0, to = 0.0, out = 0.0

  init(random: @escaping () -> Double = { Double.random(in: Double.leastNonzeroMagnitude...1) }) { self.random = random }

  /// One frame at `t` (seconds, monotonic) toward `want`. Returns the seconds
  /// to the next frame, nil when nothing is due until the mode changes.
  mutating func frame(_ t: Double, want: LogoMode, hw: LogoHardware) -> Double? {
    if let r = resetFadeAt, t >= r { hw.resetFade(); resetFadeAt = nil }
    let rb = hw.readback()
    if rb.high != high { high = rb.high; changedAt = t }
    // A PWM that shows no high period gives no level to fade from: not lit.
    var lit = rb.on && rb.high >= 0

    if want != applied {
      hw.note("mode", ["mode": want.words, "was": applied.words])
      if phase == .playing || phase == .fadingOut {
        // From the level on the lid, to the new mode's.
        from = written.map(LogoCurve.level(ofTick:)) ?? out
        if want.plays {
          phase = .playing
          if case .on(let p) = want { to = LogoCurve.level(ofTick: LogoCurve.onTicks(p)) }
          if case .breathe(let r) = want { breath = breath.next(at: t, rate: r, random: random) }
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
      if case .breathe(let r) = applied { breath = breath.next(at: t, rate: r, random: random) }
      fadeAt = t
      from = LogoCurve.level(ofTick: rb.high)
      hw.note("fade-in", ["high": rb.high])
    }

    if phase == .playing || phase == .fadingOut {
      let w = LogoCurve.ease(min(1, (t - fadeAt) / LogoCurve.fade))
      var goal = to
      if phase == .playing, case .breathe(let r) = applied { goal = breath.level(at: t, rate: r, random: random) }
      out = from + (goal - from) * w
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
    case .playing:
      if case .on = applied, t - fadeAt >= LogoCurve.fade { return Self.slowFrame }   // steady
      return Self.frame
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
