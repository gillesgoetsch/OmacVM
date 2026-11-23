// Tests of logo-model.swift and logo.swift, built and run by src/tests/logo-light.sh.
//   logo-test                     the modes, the curves and the player against a made-up logo and
//                                 corebrightnessd, and LogoLight's switches (no lit logo needed)
//   logo-test live [WORDS SECS]... this Mac's logo through the Bridge's own LogoLight: each mode for
//                                 its seconds (e.g. "on 50" 8 off 8), then no VM runs, so the logo
//                                 goes back to auto. SIGTERM stops it as launchd stops the Bridge.
//   logo-test state               the logo and corebrightnessd now (reads only)
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { print("ok   \(what)") } else { failed += 1; print("FAIL \(what) (line \(line))") }
}
func log(_ s: String) { print("log: \(s)") }

/// A made-up logo: the PWM's readback and corebrightnessd, which fades the
/// logo out on a blank (over its fade), writes its own level for the room's
/// light, and switches the logo off while the display sleeps.
final class FakeLogo: LogoHardware {
  var on = true, high = 200
  var factor = 1.0, level = 200
  var blankedAt: Double?, blankFade = 0.0
  var t = 0.0
  var writes: [(t: Double, tick: Int)] = [], darks = 0, handBacks = 0, resets = 0
  private let lock = NSLock()   // LogoLight's queue blanks while the test reads
  private var blankList: [(on: Bool, fade: Double)] = []
  var blanks: [(on: Bool, fade: Double)] { lock.lock(); defer { lock.unlock() }; return blankList }
  func readback() -> (on: Bool, high: Int) { (on, high) }
  func write(_ tick: Int) -> Bool { writes.append((t, tick)); on = true; high = tick; return true }
  func dark() { darks += 1; on = false; high = 0 }
  func macOS() -> (factor: Double, tick: Int) { (blankedAt == nil ? factor : 0, level) }
  func handBack() { handBacks += 1; let f = macOS().factor; on = f > 0; high = on ? level : 0 }
  func blank(_ b: Bool, fade: Double) {
    lock.lock(); blankList.append((b, fade)); lock.unlock()
    if b { blankedAt = t; blankFade = fade } else { blankedAt = nil; if factor > 0 { on = true; high = level } }
  }
  func resetFade() { resets += 1 }
  func note(_ event: String, _ fields: [String: Any]) {}
  func advance(_ now: Double) { t = now; if let b = blankedAt, t >= b + blankFade { on = false; high = 0 } }
  /// corebrightnessd's own write: the room's light changed.
  func macOSWrites(_ tick: Int) { level = tick; if blankedAt == nil && factor > 0 { on = true; high = tick } }
  func sleep() { factor = 0; on = false; high = 0 }
  /// A wake: the display is lit again, also in corebrightnessd's blank state.
  func wake() { factor = 1; blankedAt = nil; on = true; high = level }
  func writes(from a: Double, to b: Double) -> [Int] { writes.filter { $0.t >= a && $0.t < b }.map(\.tick) }
}

/// Frames from `from` to `to` toward `want`, at the times the player asks for
/// (every 0.1 s while it asks for none), with `events` at their times.
@discardableResult
func run(_ p: inout LogoPlayer, _ hw: FakeLogo, _ from: Double, _ to: Double, _ want: LogoMode,
         _ events: [(Double, () -> Void)] = []) -> [Double?] {
  var t = from, pending = events.sorted { $0.0 < $1.0 }, asked: [Double?] = []
  while t < to {
    while let e = pending.first, e.0 <= t { e.1(); pending.removeFirst() }
    hw.advance(t)
    let next = p.frame(t, want: want, hw: hw)
    asked.append(next)
    t += next ?? 0.1
  }
  return asked
}

func nondecreasing(_ a: [Int]) -> Bool { zip(a, a.dropFirst()).allSatisfy { $0 <= $1 } }
func nonincreasing(_ a: [Int]) -> Bool { zip(a, a.dropFirst()).allSatisfy { $0 >= $1 } }

func modes() {
  func parse(_ s: String) -> LogoMode? { if case .success(let m) = LogoMode.parse(Data(s.utf8)) { return m }; return nil }
  check(parse(#"{"mode": "auto"}"#) == .auto && parse(#"{"mode": "off"}"#) == .off, "auto and off")
  check(parse(#"{"mode": "on"}"#) == .on(percent: 50), "on without a percent: on 50")
  check(parse(#"{"mode": "on", "percent": 1}"#) == .on(percent: 1) && parse(#"{"mode": "on", "percent": 100}"#) == .on(percent: 100),
        "on 1 and on 100")
  for bad in [#"{"mode": "on", "percent": 0}"#, #"{"mode": "on", "percent": 101}"#, #"{"mode": "on", "percent": 50.5}"#,
              #"{"mode": "on", "percent": 50.0}"#, #"{"mode": "on", "percent": true}"#, #"{"mode": "on", "percent": "50"}"#,
              #"{"mode": "auto", "percent": 50}"#, #"{"mode": "off", "percent": 50}"#, #"{"mode": "dim"}"#, #"{"mode": 1}"#,
              #"{"mode": "on", "percent": 50, "fade": 1}"#, #"{}"#, #"[]"#, #""on""#, "", "on 50"] {
    check(parse(bad) == nil, "refused: \(bad.isEmpty ? "no body" : bad)")
  }
  for m in [LogoMode.auto, .off, .on(percent: 50), .on(percent: 7)] {
    let back = parse(String(decoding: try! JSONSerialization.data(withJSONObject: m.json), as: UTF8.self))
    check(back == m, "\(m.words): its JSON reads back as itself")
  }
  check([LogoMode.auto, .off, .on(percent: 50)].map(\.words) == ["auto", "off", "on 50"], "words: auto, off, on 50")
}

func curves() {
  typealias C = LogoCurve
  check(C.tick(ofLevel: 100) == 768 && C.tick(ofLevel: 400) == 768, "level 100 is 80 % duty, and nothing goes above it")
  check(C.level(ofTick: 0) == -16 && C.tick(ofLevel: -16) == 0, "level and tick of dark")
  var round = true
  for t in 0...768 where C.tick(ofLevel: C.level(ofTick: t)) != t { round = false }
  check(round, "every tick to a level and back is the same tick")
  var raws = true
  for t in 0...960 where Int((C.raw(ofTick: t) * 960) >> 32) != t { raws = false }
  check(raws, "every tick's duty reads back as that tick")
  let on = (1...100).map(C.onTicks)
  check(on.allSatisfy { $0 >= 1 }, "every on level lights the logo (at least 1 tick)")
  check(nondecreasing(on), "on levels never go down")
  check(C.onTicks(100) == 768, "on 100: 80 % duty, the brightest macOS drives it (\(C.onTicks(100)))")
  check(C.onTicks(50) == 141, "on 50: about 15 % duty (\(C.onTicks(50)) ticks)")
  check(C.onTicks(8) == 7 && C.onTicks(9) == 8, "on 8 and 9 meet at the standard's knee (\(C.onTicks(8)), \(C.onTicks(9)))")
  check(C.ease(0) == 0 && abs(C.ease(1) - 1) < 1e-12 && abs(C.ease(0.5) - 0.5) < 1e-12, "ease: 0, 0.5, 1")
}

func player() {
  let on50 = LogoCurve.onTicks(50), on80 = LogoCurve.onTicks(80)

  // auto -> on 50: waits for macOS's level to stand still, then fades from it over 3 s.
  var hw = FakeLogo(), p = LogoPlayer()
  check(p.frame(0, want: .auto, hw: hw) == nil, "auto: no frames at all")
  hw.high = 201; hw.level = 201
  run(&p, hw, 0, 10, .on(percent: 50))
  let first = hw.writes.first?.t ?? -1, last = hw.writes.last?.t ?? -1
  check(first > 1 && first < 1.3, "on 50: starts once macOS's level stood still for 1 s (\(first))")
  check(last - first > 2.5 && last - first <= 3.05, "on 50: fades for 3 s, its last steps near the end (\(last - first))")
  check(nonincreasing(hw.writes.map(\.tick)) && hw.writes.last?.tick == on50, "on 50: from 201 down to \(on50), every write a step down")
  check(hw.writes(from: last + 0.01, to: 10).isEmpty && hw.high == on50, "on 50: steady after its fade, no writes")
  check(p.frame(10, want: .on(percent: 50), hw: hw) == LogoPlayer.slowFrame, "on, steady: a frame every 0.1 s")

  // on 50 -> on 80, from where it is.
  run(&p, hw, 10, 15, .on(percent: 80))
  let up = hw.writes(from: 10, to: 15)
  check(nondecreasing(up) && up.last == on80 && (hw.writes.last!.t - 10) < 3.05, "on 80: fades up from \(on50) to \(on80) within 3 s")

  // corebrightnessd writes its own level (the room's light): on yields, then fades back from it.
  run(&p, hw, 15, 25, .on(percent: 80), [(16, { hw.macOSWrites(300) })])
  let back = hw.writes(from: 16, to: 25)
  check(hw.writes(from: 16, to: 17).isEmpty, "macOS writes 300: nothing of ours for the next second")
  check(back.first.map { abs($0 - 300) < 15 } == true && back.last == on80 && nondecreasing(back),
        "then a fade from 300 back up to \(on80) (\(back.first ?? -1) ...)")

  // on, and the display sleeps for a minute: nothing lit by us, on again after the wake.
  hw = FakeLogo(); p = LogoPlayer()
  run(&p, hw, 0, 100, .on(percent: 80), [(20, { hw.sleep() }), (80, { hw.wake() })])
  check(hw.writes(from: 20, to: 80).isEmpty, "the display sleeps: no write for the whole minute")
  let wake = hw.writes(from: 80, to: 100)
  check((hw.writes.first { $0.t >= 80 }?.t ?? 0) > 81, "after the wake: back once macOS's level stood still (\(hw.writes.first { $0.t >= 80 }?.t ?? 0))")
  check(wake.last == on80 && hw.high == on80, "and fades to on 80 again")

  // Our write lands just after corebrightnessd switched the logo off: the factor check switches it off.
  hw = FakeLogo(); p = LogoPlayer()
  run(&p, hw, 0, 10, .on(percent: 50))
  hw.factor = 0; _ = hw.write(on50)   // macOS's factor went to 0, the PWM still shows ours
  run(&p, hw, 10, 12, .on(percent: 50))
  check(hw.darks == 1 && !hw.on, "a write of ours after macOS's sleep: switched off within a second")

  // The PWM switched on but shows no high period: nothing to fade from, so on waits and writes nothing.
  hw = FakeLogo(); p = LogoPlayer()
  hw.high = -1
  run(&p, hw, 0, 10, .on(percent: 50))
  check(hw.writes.isEmpty && p.phase == .waiting, "no high period on the PWM: on waits, no write (\(hw.writes.first?.tick ?? 0))")

  // auto -> off: corebrightnessd blanks it; a wake makes it lit again, so off blanks again; off -> auto unblanks.
  hw = FakeLogo(); p = LogoPlayer()
  run(&p, hw, 0, 10, .off)
  check(hw.blanks.count == 1 && hw.blanks[0].on && hw.blanks[0].fade == 3 && !hw.on, "off: one blank with a 3 s fade, dark after it")
  check(hw.writes.isEmpty, "off: no write of ours")
  check(hw.resets == 1, "off: corebrightnessd's fade length set back after the fade")
  run(&p, hw, 10, 20, .off, [(11, { hw.sleep() }), (15, { hw.wake() })])
  check(hw.blanks.count == 2 && hw.blanks[1].on, "a wake while off: blanked again")
  run(&p, hw, 20, 25, .auto)
  check(hw.blanks.count == 3 && !hw.blanks[2].on && hw.blanks[2].fade == 3 && hw.on, "off -> auto: unblanked with a 3 s fade")
  let asked = run(&p, hw, 25, 30, .auto)
  check(asked.last! == nil, "auto again: no frames")

  // on -> off: fades down to 1 tick, never 0, then dark and a blank with no fade of its own.
  hw = FakeLogo(); p = LogoPlayer()
  run(&p, hw, 0, 10, .on(percent: 80))
  run(&p, hw, 10, 15, .off)
  let down = hw.writes(from: 10, to: 15)
  check(nonincreasing(down) && down.last == 1 && !down.contains(0), "on -> off: down to 1 tick, never 0 (\(down.count) writes)")
  check(hw.darks == 1 && hw.blanks.last?.on == true && hw.blanks.last!.fade < 0.001 && !hw.on, "then dark, and corebrightnessd hears blank at once")

  // on -> auto: fades to macOS's level, then hands it back.
  hw = FakeLogo(); p = LogoPlayer()
  run(&p, hw, 0, 10, .on(percent: 80))
  hw.level = 180
  run(&p, hw, 10, 15, .auto)
  let toMac = hw.writes(from: 10, to: 15)
  check(abs((toMac.last ?? 0) - 180) <= 1 && hw.handBacks == 1 && p.phase == .idle, "on -> auto: fades to macOS's 180, then it is macOS's")

  // The Bridge stops.
  hw = FakeLogo(); p = LogoPlayer()
  run(&p, hw, 0, 10, .on(percent: 80))
  p.release(hw: hw)
  check(hw.handBacks == 1 && hw.resets >= 1 && p.applied == .auto, "stop while on: macOS's level at once")
  hw = FakeLogo(); p = LogoPlayer()
  run(&p, hw, 0, 10, .off)
  p.release(hw: hw)
  check(hw.blanks.last.map { !$0.on && $0.fade == 0 } == true, "stop while off: unblanked with macOS's own fade")
}

/// True once `cond` holds, false after `seconds` (a busy CI Mac may take a while).
func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while !cond() { if Date() > end { return false }; usleep(20_000) }
  return true
}

/// LogoLight with a made-up logo: its mode, no VM left, the switch in the config, the stop.
func light() {
  let hw = FakeLogo()
  let light = LogoLight(hw: hw, enabled: true)
  check(light.set(.off) == .changed, "a VM sets off")
  check(light.set(.off) == .kept, "the same again: kept, nothing to do")
  check(light.state.mode == .off, "it plays off")
  check(waitUntil(10) { hw.blanks.first?.on == true }, "the logo is blanked")
  light.vmsGone()
  check(light.state.mode == .auto, "no VM runs: auto")
  check(waitUntil(10) { hw.blanks.last?.on == false }, "the logo is macOS's again")
  light.setEnabled(false)
  check(light.set(.off) == .refused && light.state.mode == .auto && !light.state.enabled, "off on this Mac: refused")
  light.setEnabled(true)
  check(light.set(.on(percent: 50)) == .changed, "on again on this Mac: a VM sets on 50")
  light.stop()
  check(light.state.mode == .auto && light.set(.off) == .refused, "the Bridge stops: auto, and nothing more")
  check(LogoLight(hw: FakeLogo(), enabled: false).set(.off) == .refused, "a Bridge started with the logo light off refuses at once")
}

func live(_ steps: [String]) {
  setvbuf(stdout, nil, _IOLBF, 0)
  let found = PWMLogo.find()
  guard case .success(let hw) = found else {
    if case .failure(let e) = found { print("no logo to play on this Mac: \(e)") }
    exit(3)
  }
  let start = ProcessInfo.processInfo.systemUptime
  func stamp() -> String { String(format: "%8.3f", ProcessInfo.processInfo.systemUptime - start) }
  hw.onNote = { e, f in print("\(stamp()) \(e) \(f.isEmpty ? "" : "\(f)")") }
  print("\(stamp()) keyboards \(hw.keyboardCount), readback \(hw.readback()), macOS \(hw.macOS())")
  // Every step is checked before the logo is touched: WORDS as omacvm-logo takes them, SECONDS a number.
  let plan: [(mode: LogoMode, seconds: Double)] = stride(from: 0, to: steps.count, by: 2).map { i in
    let w = steps[i].split(separator: " ").map(String.init)
    var o: [String: Any] = ["mode": w.first ?? ""]
    if w.count == 2, let n = Int(w[1]) { o["percent"] = n }
    guard w.count == o.count, i + 1 < steps.count, let s = Double(steps[i + 1]),
          case .success(let m) = LogoMode.parse(try! JSONSerialization.data(withJSONObject: o)) else {
      print("not a step: \(steps[i]) \(i + 1 < steps.count ? steps[i + 1] : "(no seconds)")"); exit(2)
    }
    return (m, s)
  }
  let light = LogoLight(hw: hw, enabled: true)
  light.stopOnSIGTERM()
  for step in plan {
    print("\(stamp()) set \(step.mode.words) for \(step.seconds) s")
    _ = light.set(step.mode)
    Thread.sleep(forTimeInterval: step.seconds)
  }
  print("\(stamp()) no VM runs")
  light.vmsGone()
  Thread.sleep(forTimeInterval: LogoCurve.fade + 1.5)
  check(light.state.mode == .auto, "no VM runs: auto")
  print("\(stamp()) readback \(hw.readback()), macOS \(hw.macOS())")
}

switch CommandLine.arguments.dropFirst().first {
case "live": live(Array(CommandLine.arguments.dropFirst(2)))
case "state":
  guard case .success(let hw) = PWMLogo.find() else { print("no lit logo on this Mac"); exit(3) }
  print("readback \(hw.readback()) macOS \(hw.macOS()) keyboards \(hw.keyboardCount)")
  exit(0)
default:
  modes(); curves(); player(); light()
}
if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
