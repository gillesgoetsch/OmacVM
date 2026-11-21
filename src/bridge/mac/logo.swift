// The lit Apple logo on the lid of a MacBook Pro that has one (feature
// logo-light, /logo): the Bridge plays the mode a VM asks for itself
// (logo-model.swift), on the logo's PWM, next to corebrightnessd, which owns
// the logo otherwise. IOKit for the PWM; macOS's private CoreBrightness, looked
// up at run time, for corebrightnessd's state. A Mac without either has no lit
// logo here. Foundation and IOKit only, so src/tests/logo-light.sh builds it
// without the rest of the Bridge.
import Foundation
import IOKit

// ---- the hardware: the PWM and corebrightnessd ----

/// The logo's PWM, AppleARMPWMDevice bklb-backlight, which a process of any
/// user may write, and corebrightnessd through CoreBrightness's
/// BrightnessSystemClient (its state of the logo, its blank state) and
/// PWMCalibrationManager (its nits as a duty).
final class PWMLogo: LogoHardware {
  private typealias SetProperty = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Bool
  private typealias SetKeyboard = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, UInt64) -> Bool
  private typealias Convert = @convention(c) (AnyObject, Selector, Float) -> Float
  private typealias SetFloat = @convention(c) (AnyObject, Selector, Float) -> Void
  private typealias InitCalibration = @convention(c) (AnyObject, Selector, io_service_t, AnyObject) -> Unmanaged<AnyObject>?
  private static let copySel = NSSelectorFromString("copyPropertyForKey:")
  private static let setSel = NSSelectorFromString("setProperty:forKey:")
  private static let keyboardSel = NSSelectorFromString("setProperty:withKey:keyboardID:")
  private static let convertSel = NSSelectorFromString("convertNitsToPWMPercentage:")

  private let pwm: io_service_t
  private let clientClass: NSObject.Type
  private var client: NSObject
  private let calibration: NSObject
  private let keyboards: [UInt64]
  var onNote: (String, [String: Any]) -> Void = { _, _ in }

  /// This Mac's logo, or why there is none (no bklb-backlight, or a macOS
  /// without the parts of CoreBrightness this uses).
  static func find() -> Result<PWMLogo, LogoMissing> {
    let pwm = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("bklb-backlight"))
    guard pwm != 0 else { return .failure(LogoMissing("no bklb-backlight")) }
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
          let clientClass = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
          let configClass = NSClassFromString("PWMConfiguration") as? NSObject.Type,
          let calibrationClass: AnyClass = NSClassFromString("PWMCalibrationManager") else {
      IOObjectRelease(pwm)
      return .failure(LogoMissing("this macOS's CoreBrightness has no BrightnessSystemClient or PWMCalibrationManager"))
    }
    let client = clientClass.init()
    let config = configClass.init()
    let initSel = NSSelectorFromString("initWithDevice:configuration:")
    let setters = ["setNodeName:", "setMaxNits:", "setMaxPercentage:"].map(NSSelectorFromString)
    guard client.responds(to: copySel), client.responds(to: setSel), setters.allSatisfy(config.responds(to:)),
          let initIMP = class_getMethodImplementation(calibrationClass, initSel),
          class_getInstanceMethod(calibrationClass, initSel) != nil,
          class_getInstanceMethod(calibrationClass, convertSel) != nil else {
      IOObjectRelease(pwm)
      return .failure(LogoMissing("this macOS's CoreBrightness lacks a call the logo needs"))
    }
    // The calibration corebrightnessd uses for this node: 1000 nits at most, as a percentage of the duty.
    config.perform(setters[0], with: "bklb-backlight")
    unsafeBitCast(config.method(for: setters[1]), to: SetFloat.self)(config, setters[1], 1000)
    unsafeBitCast(config.method(for: setters[2]), to: SetFloat.self)(config, setters[2], 100)
    // alloc's object goes to init, which returns its own (retained) one.
    guard let fresh = (calibrationClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let calibration = unsafeBitCast(initIMP, to: InitCalibration.self)(fresh, initSel, pwm, config)?.takeRetainedValue() as? NSObject else {
      IOObjectRelease(pwm)
      return .failure(LogoMissing("PWMCalibrationManager did not take bklb-backlight"))
    }
    // The keyboard backlight follows corebrightnessd's blank state too (blank).
    var keyboards: [UInt64] = []
    if client.responds(to: keyboardSel), let k = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
      let kc = k.init()
      let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
      if kc.responds(to: sel), let ids = kc.perform(sel)?.takeRetainedValue() as? [NSNumber] { keyboards = ids.map(\.uint64Value) }
    }
    return .success(PWMLogo(pwm: pwm, clientClass: clientClass, client: client, calibration: calibration, keyboards: keyboards))
  }

  private init(pwm: io_service_t, clientClass: NSObject.Type, client: NSObject, calibration: NSObject, keyboards: [UInt64]) {
    self.pwm = pwm; self.clientClass = clientClass; self.client = client; self.calibration = calibration; self.keyboards = keyboards
  }

  var keyboardCount: Int { keyboards.count }

  func readback() -> (on: Bool, high: Int) { (property("enabled") == 1, property("high-period")) }

  private func property(_ key: String) -> Int {
    let v = IORegistryEntryCreateCFProperty(pwm, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return (v as? NSNumber)?.intValue ?? -1   // a number, or the boolean of "enabled"
  }

  /// The driver takes a duty only with set-enabled (a CFBoolean) and set-hz in
  /// the same dictionary: one without set-enabled is refused and switches the
  /// logo off. A duty of 0 switches it off.
  private func writeRaw(_ raw: UInt64, on: Bool) -> Bool {
    let d: [String: Any] = ["set-duty-cycle": NSNumber(value: raw), "set-enabled": on ? kCFBooleanTrue! : kCFBooleanFalse!,
                            "set-hz": NSNumber(value: Int32(25000))]
    return IORegistryEntrySetCFProperties(pwm, d as CFDictionary) == KERN_SUCCESS
  }

  func write(_ tick: Int) -> Bool { writeRaw(LogoCurve.raw(ofTick: tick), on: true) }
  func dark() { _ = writeRaw(0, on: false) }

  /// corebrightnessd's final nits times its fade factor, through its own
  /// calibration of this node (it matched the readback within one tick at 201
  /// and 248 nits), as the driver's duty.
  private func macOSRaw() -> (factor: Double, raw: UInt64) {
    let st = state() ?? [:]
    let factor = (st["Factor"] as? NSNumber)?.doubleValue ?? 0
    let nits = (st["FinalNits"] as? NSNumber)?.doubleValue ?? 0
    let pct = Double(unsafeBitCast(calibration.method(for: Self.convertSel), to: Convert.self)(calibration, Self.convertSel, Float(nits * factor)))
    return (factor, UInt64((pct.isFinite ? min(100, max(0, pct)) : 0) / 100 * 4294967296))
  }

  func macOS() -> (factor: Double, tick: Int) {
    let m = macOSRaw()
    return (m.factor, Int((Double(m.raw) / 4294967296 * Double(LogoCurve.period)).rounded()))
  }

  func handBack() {
    let m = macOSRaw()
    _ = writeRaw(m.raw, on: m.factor > 0)
  }

  /// corebrightnessd's blank state for its light emitter (1 blank, 2 lit) with
  /// the length of its next fade, which it keeps until it is set back (resetFade).
  func blank(_ blank: Bool, fade: Double) {
    set(NSNumber(value: fade), "LEPWMFactorFadeDuration")
    set(NSNumber(value: Int32(blank ? 1 : 2)), "DisplayLogicalState")
    guard blank else { return }
    let f = unsafeBitCast(client.method(for: Self.keyboardSel), to: SetKeyboard.self)
    for k in keyboards { _ = f(client, Self.keyboardSel, NSNumber(value: Int32(2)), "DisplayLogicalState" as NSString, k) }
  }

  func resetFade() { set(NSNumber(value: Int32(0)), "LEPWMFactorFadeDuration") }

  func note(_ event: String, _ fields: [String: Any]) { onNote(event, fields) }

  // A client stops answering after corebrightnessd starts again: a call that gets no answer makes a new one.
  private func state() -> [String: Any]? {
    func ask() -> [String: Any]? { client.perform(Self.copySel, with: "LEPWMState")?.takeRetainedValue() as? [String: Any] }
    if let s = ask() { return s }
    client = clientClass.init()
    return ask()
  }

  private func set(_ value: NSNumber, _ key: String) {
    func call() -> Bool { unsafeBitCast(client.method(for: Self.setSel), to: SetProperty.self)(client, Self.setSel, value, key as NSString) }
    if call() { return }
    client = clientClass.init()
    _ = call()
  }
}

struct LogoMissing: Error { let why: String; init(_ why: String) { self.why = why } }

// ---- what plays it ----

/// The logo's mode, as the last VM asked for it. One serial queue; a frame
/// timer that runs while something of ours moves (LogoPlayer says when), and
/// not at all on auto.
final class LogoLight {
  private let q = DispatchQueue(label: "omacvm-bridge.logo", qos: .userInteractive)
  private let hw: LogoHardware
  private var player = LogoPlayer()
  private var want = LogoMode.auto
  private let timer: DispatchSourceTimer
  private var activity: NSObjectProtocol?
  private var stopSignal: DispatchSourceSignal?
  private var on: Bool, stopped = false

  init(hw: LogoHardware, enabled: Bool) {
    self.hw = hw
    on = enabled
    timer = DispatchSource.makeTimerSource(queue: q)
    timer.setEventHandler { [weak self] in self?.frame() }
    timer.resume()   // one shot at a time, scheduled by frame and kick
  }

  /// The feature on this Mac (logo_light) and the mode it plays, as the VM asked for it.
  var state: (enabled: Bool, mode: LogoMode) { q.sync { (on, want) } }

  enum Outcome { case refused, kept, changed }

  /// A VM's mode. refused: the logo light is off on this Mac; kept: it plays that already.
  func set(_ mode: LogoMode) -> Outcome {
    q.sync {
      guard on, !stopped else { return .refused }
      guard mode != want else { return .kept }
      want = mode
      kick()
      return .changed
    }
  }

  /// No VM of ours runs any more: the logo is macOS's again.
  func vmsGone() {
    q.sync {
      guard want != .auto else { return }
      log("logo light: no VM runs: \(want.words) -> auto")
      want = .auto
      kick()
    }
  }

  /// The feature on this Mac (logo_light in the Bridge's config.json): off
  /// gives the logo back to macOS.
  func setEnabled(_ enabled: Bool) {
    q.sync {
      on = enabled
      guard !enabled, want != .auto else { return }
      log("logo light: off on this Mac: \(want.words) -> auto")
      want = .auto
      kick()
    }
  }

  /// The Bridge stops (SIGTERM from launchd, Quit, or a logout): the logo is
  /// macOS's at once.
  func stop() {
    q.sync {
      guard !stopped else { return }
      stopped = true
      want = .auto
      player.release(hw: hw)
      log("logo light: the Bridge stops: the logo is macOS's")
    }
  }

  /// launchd stops the Bridge with SIGTERM: the logo goes back to macOS first,
  /// then the Bridge ends by that signal as it would without this.
  func stopOnSIGTERM() {
    signal(SIGTERM, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInteractive))
    s.setEventHandler { [weak self] in
      self?.stop()
      signal(SIGTERM, SIG_DFL)
      kill(getpid(), SIGTERM)
    }
    s.resume()
    stopSignal = s
  }

  private func kick() { timer.schedule(deadline: .now(), leeway: .milliseconds(1)) }

  private func frame() {
    guard !stopped else { return }
    let next = player.frame(ProcessInfo.processInfo.systemUptime, want: want, hw: hw)
    // While a mode plays: a napping Bridge would stutter the fades and the
    // breath, and see a wake late (off lit after it for seconds).
    if next != nil && activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                       reason: "the Mac's logo light")
    } else if next == nil, let a = activity {
      ProcessInfo.processInfo.endActivity(a)
      activity = nil
    }
    if let next { timer.schedule(deadline: .now() + next, leeway: .milliseconds(next < 0.05 ? 1 : 10)) }
  }
}
