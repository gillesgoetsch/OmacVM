// Tests of logo-model.swift and logo.swift, built and run by src/tests/logo-light.sh.
//   logo-test                     the modes, the curves, the breath, the player against a made-up logo
//                                 and corebrightnessd, which VM asked, the owner's end, a killed
//                                 Bridge's hold (no lit logo needed)
//   logo-test live [WORDS SECS]... this Mac's logo through the Bridge's own LogoLight: each mode for
//                                 its seconds (e.g. "on 50" 8 breathe 20 off 8), owned by a child
//                                 process; then that child ends, so the logo goes back to auto.
//                                 SIGTERM stops it as launchd stops the Bridge.
//   logo-test state               the logo and corebrightnessd now (reads only)
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { print("ok   \(what)") } else { failed += 1; print("FAIL \(what) (line \(line))") }
}
func log(_ s: String) { print("log: \(s)") }

/// A seeded uniform source in (0, 1], so every run breathes the same.
final class Seeded {
  private var s: UInt64
  init(_ seed: UInt64) { s = seed }
  func next() -> Double {
    s ^= s << 13; s ^= s >> 7; s ^= s << 17
    return Double(s >> 11 | 1) / Double(UInt64(1) << 53)
  }
}

/// A made-up logo: the PWM's readback and corebrightnessd, which fades the
/// logo out on a blank (over its fade), writes its own level for the room's
/// light, and switches the logo off while the display sleeps.
final class FakeLogo: LogoHardware {
  var on = true, high = 200
  var factor = 1.0, level = 200
  var blankedAt: Double?, blankFade = 0.0
  var t = 0.0
  var writes: [(t: Double, tick: Int)] = [], darks = 0, handBacks = 0, blanks: [(on: Bool, fade: Double)] = [], resets = 0
  var notes: [String] = []
  func readback() -> (on: Bool, high: Int) { (on, high) }
  func write(_ tick: Int) -> Bool { writes.append((t, tick)); on = true; high = tick; return true }
  func dark() { darks += 1; on = false; high = 0 }
  func macOS() -> (factor: Double, tick: Int) { (blankedAt == nil ? factor : 0, level) }
  func handBack() { handBacks += 1; let f = macOS().factor; on = f > 0; high = on ? level : 0 }
  func blank(_ b: Bool, fade: Double) {
    blanks.append((b, fade))
    if b { blankedAt = t; blankFade = fade } else { blankedAt = nil; if factor > 0 { on = true; high = level } }
  }
  func resetFade() { resets += 1 }
  func note(_ event: String, _ fields: [String: Any]) { notes.append(event) }
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
  check(parse(#"{"mode": "breathe"}"#) == .breathe(rate: 15), "breathe without a rate: breathe 15")
  check(parse(#"{"mode": "breathe", "rate": 6}"#) == .breathe(rate: 6) && parse(#"{"mode": "breathe", "rate": 30}"#) == .breathe(rate: 30),
        "breathe 6 and breathe 30")
  for bad in [#"{"mode": "on", "percent": 0}"#, #"{"mode": "on", "percent": 101}"#, #"{"mode": "on", "percent": 50.5}"#,
              #"{"mode": "on", "percent": 50.0}"#, #"{"mode": "on", "percent": true}"#, #"{"mode": "on", "percent": "50"}"#,
              #"{"mode": "breathe", "rate": 5}"#, #"{"mode": "breathe", "rate": 31}"#, #"{"mode": "on", "rate": 15}"#,
              #"{"mode": "breathe", "percent": 50}"#, #"{"mode": "auto", "percent": 50}"#, #"{"mode": "off", "rate": 15}"#,
              #"{"mode": "dim"}"#, #"{"mode": 1}"#, #"{"mode": "on", "percent": 50, "fade": 1}"#, #"{}"#, #"[]"#, #""on""#, "", "on 50"] {
    check(parse(bad) == nil, "refused: \(bad.isEmpty ? "no body" : bad)")
  }
  for m in [LogoMode.auto, .off, .on(percent: 50), .on(percent: 7), .breathe(rate: 15), .breathe(rate: 30)] {
    let back = parse(String(decoding: try! JSONSerialization.data(withJSONObject: m.json), as: UTF8.self))
    check(back == m, "\(m.words): its JSON reads back as itself")
  }
  check([LogoMode.auto, .off, .on(percent: 50), .breathe(rate: 15)].map(\.words) == ["auto", "off", "on 50", "breathe 15"],
        "words: auto, off, on 50, breathe 15")
}

func curves() {
  typealias C = LogoCurve
  check(C.tick(ofLevel: C.level(ofTick: 43)) == 43 && Int((Breath.floorDuty * 960).rounded()) == 43, "the breath's floor: 43 ticks")
  check(C.tick(ofLevel: 100) == 240, "the breath's peak (level 100): 240 ticks")
  check(C.tick(ofLevel: 400) == 768, "nothing above 80 % duty: 768 ticks")
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

func breath() {
  let r = Seeded(1)
  for rate in [6, 15, 30] {
    var b = Breath().next(at: 0, rate: rate, random: r.next)
    var ticks: [Int] = [], count = 0, last = b.start, deep = 0
    for i in 0..<(600 * 60) {
      let t = Double(i) / 60
      ticks.append(LogoCurve.tick(ofLevel: b.level(at: t, rate: rate, random: r.next)))
      if b.start != last { count += 1; last = b.start; if b.deeper { deep += 1 } }
    }
    // A deeper breath every 8 is 1.4 to 1.5 times as long: 1.06 breaths' length on average.
    let want = Double(rate) * 10 / 1.06
    check(abs(Double(count) - want) < want * 0.12, "breathe \(rate): \(count) breaths in 10 minutes (about \(Int(want)))")
    check(ticks.min()! >= 43 && ticks.min()! <= 44, "breathe \(rate): it rests at the floor, never darker (\(ticks.min()!) ticks)")
    check(ticks.max()! <= 768 && ticks.max()! >= 400, "breathe \(rate): a deep breath goes high, never above 80 % (\(ticks.max()!))")
    check(deep >= count / 14 && deep <= count / 5, "breathe \(rate): \(deep) of \(count) breaths are deeper (about 1 in 8)")
  }
}

func player() {
  let r = Seeded(2)
  let on50 = LogoCurve.onTicks(50), on80 = LogoCurve.onTicks(80)

  // auto -> on 50: waits for macOS's level to stand still, then fades from it over 3 s.
  var hw = FakeLogo(), p = LogoPlayer(random: r.next)
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

  // breathe, and the display sleeps for a minute: nothing lit by us, the breath again after the wake.
  hw = FakeLogo(); p = LogoPlayer(random: r.next)
  run(&p, hw, 0, 100, .breathe(rate: 15), [(20, { hw.sleep() }), (80, { hw.wake() })])
  check(hw.writes(from: 4, to: 20).count > 100, "breathe: writes while it breathes")
  check(hw.writes(from: 20.02, to: 80).isEmpty, "the display sleeps: no write for the whole minute")
  let wake = hw.writes(from: 80, to: 100)
  check((hw.writes.first { $0.t >= 80 }?.t ?? 0) > 81, "after the wake: back once macOS's level stood still (\(hw.writes.first { $0.t >= 80 }?.t ?? 0))")
  check(wake.count > 100, "and breathes again")

  // Our write lands just after corebrightnessd switched the logo off: the factor check switches it off.
  hw = FakeLogo(); p = LogoPlayer(random: r.next)
  run(&p, hw, 0, 10, .on(percent: 50))
  hw.factor = 0; _ = hw.write(on50)   // macOS's factor went to 0, the PWM still shows ours
  run(&p, hw, 10, 12, .on(percent: 50))
  check(hw.darks == 1 && !hw.on, "a write of ours after macOS's sleep: switched off within a second")

  // auto -> off: corebrightnessd blanks it; a wake makes it lit again, so off blanks again; off -> auto unblanks.
  hw = FakeLogo(); p = LogoPlayer(random: r.next)
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

  // breathe -> off: fades down to 1 tick, never 0, then dark and a blank with no fade of its own.
  hw = FakeLogo(); p = LogoPlayer(random: r.next)
  run(&p, hw, 0, 10, .breathe(rate: 15))
  run(&p, hw, 10, 15, .off)
  let down = hw.writes(from: 10, to: 15)
  check(nonincreasing(down) && down.last == 1 && !down.contains(0), "breathe -> off: down to 1 tick, never 0 (\(down.count) writes)")
  check(hw.darks == 1 && hw.blanks.last?.on == true && hw.blanks.last!.fade < 0.001 && !hw.on, "then dark, and corebrightnessd hears blank at once")

  // breathe -> auto: fades to macOS's level, then hands it back.
  hw = FakeLogo(); p = LogoPlayer(random: r.next)
  run(&p, hw, 0, 10, .breathe(rate: 15))
  hw.level = 180
  run(&p, hw, 10, 15, .auto)
  let toMac = hw.writes(from: 10, to: 15)
  check(abs((toMac.last ?? 0) - 180) <= 1 && hw.handBacks == 1 && p.phase == .idle, "breathe -> auto: fades to macOS's 180, then it is macOS's")

  // A killed Bridge's hold: the next one hands the logo back.
  hw = FakeLogo(); hw.blankedAt = -10; hw.on = false; hw.high = 0
  p = LogoPlayer(resuming: .blank, readback: hw.readback(), random: r.next)
  run(&p, hw, 0, 5, .auto)
  check(hw.blanks.count == 1 && !hw.blanks[0].on && hw.on, "left blank: unblanked")
  hw = FakeLogo(); hw.high = 300; hw.level = 180
  p = LogoPlayer(resuming: .written, readback: hw.readback(), random: r.next)
  run(&p, hw, 0, 5, .auto)
  check(hw.writes.first.map { abs($0.tick - 300) < 10 } == true && hw.handBacks == 1 && p.hold == nil,
        "left lit at 300: fades from there to macOS's level, then hands it back")

  // The Bridge stops.
  hw = FakeLogo(); p = LogoPlayer(random: r.next)
  run(&p, hw, 0, 10, .breathe(rate: 15))
  check(p.hold == .written, "breathing: held as written")
  p.release(hw: hw)
  check(hw.handBacks == 1 && hw.resets >= 1 && p.hold == nil && p.applied == .auto, "stop while it breathes: macOS's level at once")
  hw = FakeLogo(); p = LogoPlayer(random: r.next)
  run(&p, hw, 0, 10, .off)
  check(p.hold == .blank, "off: held as blank")
  p.release(hw: hw)
  check(hw.blanks.last.map { !$0.on && $0.fade == 0 } == true && p.hold == nil, "stop while off: unblanked with macOS's own fade")
}

func vmnet() {
  check(VMNet.leaseForm("52:54:00:0A:B0:01") == "52:54:0:a:b0:1", "a MAC as the DHCP leases write it")
  let leases = """
    {
    \tname=omarchy
    \tip_address=192.168.77.2
    \thw_address=1,52:54:0:a:b0:1
    \tlease=0x6740a2b1
    }
    {
    \tname=other
    \tip_address=192.168.77.3
    \thw_address=1,52:54:0:c:d:e
    }
    {
    \tname=omarchy
    \tip_address=192.168.77.4
    \thw_address=1,52:54:0:a:b0:1
    }
    """
  check(VMNet.leaseIP(mac: "52:54:00:0a:b0:01", leases: leases) == "192.168.77.4", "the MAC's last lease wins")
  check(VMNet.leaseIP(mac: "52:54:00:ff:ff:ff", leases: leases) == nil, "no lease: no address")
  let args = ["qemu", "-netdev", "stream,id=fast,addr.type=unix", "-device", "virtio-net-pci,netdev=user0,mac=52:54:00:11:11:11",
              "-device", "virtio-net-pci,netdev=fast,mac=52:54:00:0a:b0:01,id=n1"]
  check(VMNet.fastMAC(arguments: args) == "52:54:00:0a:b0:01", "the fast network card's MAC from QEMU's command line")
  check(VMNet.fastMAC(arguments: Array(args.prefix(5))) == nil, "QEMU's own network only: none")
}

/// A child that holds a TCP connection to our own listener: its process is the one found.
func socketOwner() {
  let l = socket(AF_INET, SOCK_STREAM, 0)
  var sin = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(l, $0, len) } }
  listen(l, 4)
  _ = withUnsafeMutablePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(l, $0, &len) } }
  let port = UInt16(bigEndian: sin.sin_port)
  let nc = Process()
  nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
  nc.arguments = ["127.0.0.1", "\(port)"]
  nc.standardInput = Pipe()
  nc.standardOutput = FileHandle.nullDevice
  try! nc.run()
  let c = accept(l, nil, nil)
  defer { nc.terminate(); close(c); close(l) }
  let isChild = { (p: pid_t) in p == nc.processIdentifier }
  check(VMProcess.of(c, isVM: isChild, arguments: { _ in nil }) == nc.processIdentifier,
        "127.0.0.1: the process that holds the other end (pid \(nc.processIdentifier))")
  check(VMProcess.of(c, isVM: { _ in false }, arguments: { _ in nil }) == nil, "no VM among this user's processes: none")
  check(VMProcess.ownProcesses().contains(getpid()), "this user's processes include this one")
}

/// True once `cond` holds, false after `seconds` (a busy CI Mac may take a while).
func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while !cond() { if Date() > end { return false }; usleep(20_000) }
  return true
}

/// LogoLight with a made-up logo: the VM's end gives the logo back, and the hold is on disk while it holds.
func owner() {
  let dir = NSTemporaryDirectory() + "logo-test-\(getpid())"
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  let held = dir + "/held"
  func hold() -> String? { try? String(contentsOfFile: held, encoding: .utf8) }
  let light = LogoLight(hw: FakeLogo(), holdPath: held)
  let vm = Process()
  vm.executableURL = URL(fileURLWithPath: "/bin/sleep")
  vm.arguments = ["600"]
  try! vm.run()
  defer { if vm.isRunning { vm.terminate() } }
  check(light.set(.off, owner: vm.processIdentifier) == .changed, "a VM sets off")
  check(light.set(.off, owner: vm.processIdentifier) == .kept, "the same again: kept, nothing to do")
  check(waitUntil(10) { hold() == "blank\n" }, "the hold is on disk: blank")
  check(light.state.mode == .off, "it plays off")
  vm.terminate()
  check(waitUntil(10) { light.state.mode == .auto }, "the VM ended: auto")
  check(waitUntil(10) { hold() == nil }, "nothing held: no file")
  let gone = Process()
  gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
  try! gone.run(); gone.waitUntilExit()
  _ = light.set(.on(percent: 50), owner: gone.processIdentifier)
  check(waitUntil(10) { light.state.mode == .auto }, "a VM that ended before its mode came: auto")
  light.setEnabled(false)
  check(light.set(.off, owner: getpid()) == .refused && light.state.mode == .auto && !light.state.enabled, "off on this Mac: refused")
  // A Bridge killed while off left its hold: the next one unblanks, and the hold goes.
  try? "blank\n".write(toFile: held, atomically: true, encoding: .utf8)
  let hw2 = FakeLogo()
  hw2.blankedAt = 0; hw2.on = false
  let light2 = LogoLight(hw: hw2, holdPath: held)
  check(waitUntil(10) { hold() == nil }, "a hold left on disk: the next one takes it")
  withExtendedLifetime(light2) {}
  check(hw2.blanks.first.map { !$0.on } == true, "... and gives the logo back")
}

func live(_ steps: [String]) {
  setvbuf(stdout, nil, _IOLBF, 0)
  let found = PWMLogo.find()
  guard case .success(let hw) = found else {
    if case .failure(let e) = found { print("no lit logo on this Mac: \(e.why)") }
    exit(3)
  }
  let start = ProcessInfo.processInfo.systemUptime
  func stamp() -> String { String(format: "%8.3f", ProcessInfo.processInfo.systemUptime - start) }
  hw.onNote = { e, f in print("\(stamp()) \(e) \(f.isEmpty ? "" : "\(f)")") }
  print("\(stamp()) keyboards \(hw.keyboardCount), readback \(hw.readback()), macOS \(hw.macOS())")
  let light = LogoLight(hw: hw, holdPath: FileManager.default.currentDirectoryPath + "/logo-held")
  light.stopOnSIGTERM()
  let vm = Process()
  vm.executableURL = URL(fileURLWithPath: "/bin/sleep")
  vm.arguments = ["100000"]
  try! vm.run()
  var i = 0
  while i + 1 < steps.count {
    let w = steps[i].split(separator: " ").map(String.init)
    var o: [String: Any] = ["mode": w[0]]
    if w.count > 1, let n = Int(w[1]) { o[w[0] == "on" ? "percent" : "rate"] = n }
    guard case .success(let m) = LogoMode.parse(try! JSONSerialization.data(withJSONObject: o)) else { print("not a mode: \(steps[i])"); exit(2) }
    print("\(stamp()) set \(m.words) for \(steps[i + 1]) s")
    _ = light.set(m, owner: vm.processIdentifier)
    Thread.sleep(forTimeInterval: Double(steps[i + 1]) ?? 5)
    i += 2
  }
  print("\(stamp()) the owner ends")
  vm.terminate()
  Thread.sleep(forTimeInterval: LogoCurve.fade + 1.5)
  check(light.state.mode == .auto, "the owner ended: auto")
  print("\(stamp()) readback \(hw.readback()), macOS \(hw.macOS())")
}

switch CommandLine.arguments.dropFirst().first {
case "live": live(Array(CommandLine.arguments.dropFirst(2)))
case "state":
  guard case .success(let hw) = PWMLogo.find() else { print("no lit logo on this Mac"); exit(3) }
  print("readback \(hw.readback()) macOS \(hw.macOS()) keyboards \(hw.keyboardCount)")
  exit(0)
default:
  modes(); curves(); breath(); player(); vmnet(); socketOwner(); owner()
}
if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
