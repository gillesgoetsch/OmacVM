// Offline tests of external-model.swift: steps, DDC/CI packets, which display.
// Built and run by ../../test.sh (no display, no permissions).
import CoreGraphics
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failed += 1; print("FAIL (line \(line)): \(what)") }
}

// ---- steps: 32 by default (macOS: 16), Option finer, on the grid, clamped ----
let n = BrightnessStep.defaultSteps
check(n == 32, "32 steps by default (user 2026-10-06: 16 too rough)")
check(BrightnessStep.steps(nil) == 32 && BrightnessStep.steps(16) == 16, "config: unset = 32, 16 = macOS's")
check(BrightnessStep.steps(0) == 8 && BrightnessStep.steps(-5) == 8 && BrightnessStep.steps(1000) == 100, "config clamps to 8...100")
check(BrightnessStep.fine(32) == 64 && BrightnessStep.fine(16) == 64 && BrightnessStep.fine(48) == 96 && BrightnessStep.fine(100) == 100,
      "Option: at least macOS's quarter steps (64), twice the normal ones, at most 100")
check(BrightnessStep.next(0.5, up: true, steps: n) == 17.0 / 32, "0.5 up = 17/32")
check(BrightnessStep.next(0.5, up: false, steps: n) == 15.0 / 32, "0.5 down = 15/32")
check(BrightnessStep.next(0.35, up: true, steps: n) == 12.0 / 32, "off the grid: snaps (0.35 -> 11/32) then steps")
check(BrightnessStep.next(1, up: true, steps: n) == 1, "top stays 1")
check(BrightnessStep.next(0, up: false, steps: n) == 0, "bottom stays 0")
check(BrightnessStep.next(0.5, up: true, steps: 16) == 9.0 / 16, "16 (macOS's) still works: 0.5 up = 9/16")
check(BrightnessStep.next(0.5, up: true, steps: BrightnessStep.fine(n)) == 33.0 / 64, "fine: 1/64")
var v = 0.0
for _ in 0..<32 { v = BrightnessStep.next(v, up: true, steps: n) }
check(v == 1, "32 steps from 0 reach 1")
// Every press moves the monitor's raw value (until it is at its end), also on a coarse monitor.
for m in [100, 50, 10, 255] {
  for steps in [n, BrightnessStep.fine(n), 100] {
    var x = BrightnessStep.level(m / 3, max: m), moved = true, presses = 0
    while x < 1 && presses < 200 {
      let to = BrightnessStep.next(x, up: true, steps: steps, max: m)
      if BrightnessStep.raw(to, max: m) == BrightnessStep.raw(x, max: m), BrightnessStep.raw(x, max: m) < m { moved = false }
      x = to; presses += 1
    }
    check(moved && x == 1, "max \(m), \(steps) steps: every press up moves the raw value, ends at the top")
    while x > 0 && presses < 400 {
      let to = BrightnessStep.next(x, up: false, steps: steps, max: m)
      if BrightnessStep.raw(to, max: m) == BrightnessStep.raw(x, max: m), BrightnessStep.raw(x, max: m) > 0 { moved = false }
      x = to; presses += 1
    }
    check(moved && x == 0, "max \(m), \(steps) steps: every press down moves the raw value, ends at 0")
  }
}
// Max 100, 32 steps: the popup shows each step as its own percent (3-4 points apart).
var pcts: [Int] = [], w = 0.0
for _ in 0..<32 { w = BrightnessStep.next(w, up: true, steps: n, max: 100); pcts.append(BrightnessStep.percent(w)) }
check(Set(pcts).count == 32 && zip(pcts, pcts.dropFirst()).allSatisfy { (3...4).contains($1 - $0) }, "32 percents, 3-4 apart: \(pcts)")

// ---- ramp: a key's jump of more than two steps goes out in parts, at most two steps a write ----
check(Ramp.limit(max: 100, steps: 32) == 6 && Ramp.limit(max: 10, steps: 32) == 1 && Ramp.limit(max: 65535, steps: 32) == 4096,
      "ramp limit: two steps of raw")
check(Ramp.next(from: nil, to: 80, limit: 6) == 80, "level unknown: straight")
check(Ramp.next(from: 30, to: 33, limit: 6) == 33, "one press (3 points): one write")
check(Ramp.next(from: 30, to: 80, limit: 6) == 36 && Ramp.next(from: 80, to: 30, limit: 6) == 74, "a jump: two steps at a time, both ways")
var r = 13, rampWrites = 0
while r != 63 && rampWrites < 50 { r = Ramp.next(from: r, to: 63, limit: 6); rampWrites += 1 }
check(r == 63 && rampWrites == 9, "13 -> 63: 9 writes, ends exactly there (\(rampWrites))")
// A held key at 30 repeats a second (3.1 points each) against one write per ~60 ms: the ramp keeps up.
var target = 20.0, at = 20, t = 0.0, nextWrite = 0.0, lag = 0.0
while t < 1.0 {
  target = min(100, 20 + (t / 0.033).rounded(.down) * 100 / 32)
  if t >= nextWrite { at = Ramp.next(from: at, to: Int(target.rounded()), limit: 6); nextWrite = t + 0.06 }
  lag = max(lag, target - Double(at)); t += 0.001
}
check(lag <= 10, "held key for 1 s: the monitor stays within 10 points of the keys (\(lag))")
check(BrightnessStep.raw(0.4375, max: 100) == 44, "raw: 14/32 of 100 = 44")
check(BrightnessStep.raw(1.5, max: 100) == 100 && BrightnessStep.raw(-1, max: 100) == 0, "raw clamps")
check(BrightnessStep.level(35, max: 100) == 0.35, "level 35/100")
check(BrightnessStep.level(5, max: 0) == 0, "max 0: level 0, no division")
check(BrightnessStep.percent(0.4375) == 44, "percent rounds")

// ---- DDC/CI packets ----
check(DDCPacket.get(0x10) == [0x82, 0x01, 0x10, 0xAC], "get VCP 0x10 (checksum 0x6E^0x51^...)")
check(DDCPacket.set(0x10, 44) == [0x84, 0x03, 0x10, 0x00, 0x2C, 0x84], "set VCP 0x10 = 44 (checksum 0x84)")
check(Array(DDCPacket.set(0x10, 0x1234)[3...4]) == [0x12, 0x34], "set: big-endian value")
// A real reply (Pi-X9 over USB-C, 2026-10-05): max 100, current 35.
let reply: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x23, 0xe3]
check(DDCPacket.parse(reply, code: 0x10).map { $0 == (35, 100) } == true, "parse a real reply")
var bad = reply; bad[10] ^= 1
check(DDCPacket.parse(bad, code: 0x10) == nil, "wrong checksum refused")
var unsupported = reply; unsupported[3] = 0x01; unsupported[10] ^= 0x01
check(DDCPacket.parse(unsupported, code: 0x10) == nil, "result 'unsupported' refused")
check(DDCPacket.parse([UInt8](repeating: 0, count: 11), code: 0x10) == nil, "no answer (zeros) refused")
check(DDCPacket.parse([UInt8](repeating: 0xFF, count: 11), code: 0x10) == nil, "no answer (0xFF) refused")
check(DDCPacket.parse(Array(reply.prefix(10)), code: 0x10) == nil, "short reply refused")
check(DDCPacket.parse(reply, code: 0x12) == nil, "another VCP code refused")
var zeroMax = reply; zeroMax[7] = 0; zeroMax[10] ^= 0x64
check(DDCPacket.parse(zeroMax, code: 0x10) == nil, "max 0 refused")
var over = reply; over[9] = 0xC8; over[10] = over[0..<10].reduce(0x50, ^)
check(DDCPacket.parse(over, code: 0x10).map { $0 == (100, 100) } == true, "current above max: clamped")

// ---- which display ----
// A MacBook (1728x1117 points, notch) with a 1920x1200 display above it.
let builtin = MacDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), builtin: true)
let external = MacDisplay(id: 4, bounds: CGRect(x: -96, y: -1200, width: 1920, height: 1200), builtin: false)
let displays = [builtin, external]
let fullBuiltin = CGRect(x: 0, y: 38, width: 1728, height: 1079)   // below the notch strip
let fullExternal = CGRect(x: -96, y: -1200, width: 1920, height: 1200)
let windowOnExternal = CGRect(x: 100, y: -1000, width: 1200, height: 800)
let onExternal = CGPoint(x: 500, y: -600), onBuiltin = CGPoint(x: 500, y: 500)

check(DisplayPick.covers(fullBuiltin, builtin.bounds), "full screen below the notch covers the built-in")
check(!DisplayPick.covers(fullBuiltin, external.bounds), "...not the external")
check(DisplayPick.covers(fullExternal, external.bounds), "full screen on the external")
check(!DisplayPick.covers(windowOnExternal, external.bounds), "a window is not full screen")
check(DisplayPick.home(windowOnExternal, displays) == external, "a window's home display")
check(DisplayPick.home(CGRect(x: 5000, y: 5000, width: 10, height: 10), displays) == nil, "off every display: none")

// Full screen on both (Parallels' "all displays", OmacVM.app with external displays): the pointer decides.
let both = [fullBuiltin, fullExternal]
check(DisplayPick.focused(windows: both, displays: displays, pointer: onExternal, windowed: false).map { $0.display == external && $0.fullScreen } == true,
      "full screen on both, pointer on the external: the external")
check(DisplayPick.focused(windows: both, displays: displays, pointer: onBuiltin, windowed: false)?.display == builtin,
      "full screen on both, pointer on the built-in: the built-in")
// Full screen on the external only, pointer elsewhere: still the external.
check(DisplayPick.focused(windows: [fullExternal], displays: displays, pointer: onBuiltin, windowed: false)?.display == external,
      "full screen on the external, pointer on the built-in: the external")
// A window (not full screen): only for OmacVM.app (windowed) or a guest request.
check(DisplayPick.focused(windows: [windowOnExternal], displays: displays, pointer: onExternal, windowed: false) == nil,
      "Parallels/UTM/Fusion windowed: nothing (as before)")
check(DisplayPick.focused(windows: [windowOnExternal], displays: displays, pointer: onBuiltin, windowed: true).map { $0.display == external && !$0.fullScreen } == true,
      "OmacVM.app windowed on the external: the external")
check(DisplayPick.focused(windows: [], displays: displays, pointer: onExternal, windowed: true) == nil, "no window: nothing")

// A guest output's box (OmacVM.app's layout: the outputs' top-left corner at 0,0).
// The built-in's output is its view below the notch; the layout of the two:
let boxExternal = CGRect(x: 0, y: 0, width: 1920, height: 1200)
let boxBuiltin = CGRect(x: 96, y: 1238, width: 1728, height: 1079)
check(DisplayPick.forBox(boxExternal, windows: both, displays: displays) == external, "box of the external output")
check(DisplayPick.forBox(boxBuiltin, windows: both, displays: displays) == builtin, "box of the built-in output")
// Windowed: one window, the box is the window's size at 0,0.
check(DisplayPick.forBox(CGRect(x: 0, y: 0, width: 1200, height: 800), windows: [windowOnExternal], displays: displays) == external,
      "windowed: the window's display")
check(DisplayPick.forBox(boxExternal, windows: [], displays: displays) == nil, "no OmacVM.app window: nothing")
// Another VM's window on a third display: the size tells (a window: + its title bar).
let third = MacDisplay(id: 44, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080), builtin: false)
let ds3 = displays + [third]
let mine = CGRect(x: 103, y: -1135, width: 1840, height: 1095), other = CGRect(x: -1880, y: 60, width: 1440, height: 838)
check(DisplayPick.forBox(CGRect(x: 0, y: 0, width: 1840, height: 1067), windows: [mine, other], displays: ds3) == external,
      "windowed, another VM elsewhere: the window of this size")
check(DisplayPick.forBox(CGRect(x: 0, y: 0, width: 1440, height: 810), windows: [mine, other], displays: ds3) == third,
      "...and the other one's")
check(DisplayPick.forBox(boxExternal, windows: both + [other], displays: ds3) == external, "full screen on two, another VM on a third")
check(DisplayPick.forBox(boxBuiltin, windows: both + [other], displays: ds3) == builtin, "...the built-in's output too")
// External to the right of the built-in, tops aligned.
let right = MacDisplay(id: 5, bounds: CGRect(x: 1728, y: 0, width: 2560, height: 1440), builtin: false)
let ds2 = [builtin, right]
check(DisplayPick.forBox(CGRect(x: 1728, y: 0, width: 2560, height: 1440), windows: [fullBuiltin, right.bounds], displays: ds2) == right,
      "box of an external on the right")
check(DisplayPick.forBox(CGRect(x: 0, y: 38, width: 1728, height: 1079), windows: [fullBuiltin, right.bounds], displays: ds2) == builtin,
      "box of the built-in beside it")

// Boxes from the guest are untrusted.
check(DisplayPick.validBox(boxExternal), "a normal box")
check(!DisplayPick.validBox(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)), "NaN refused")
check(!DisplayPick.validBox(CGRect(x: 0, y: 0, width: 0, height: 10)), "zero width refused")
check(!DisplayPick.validBox(CGRect(x: 1e9, y: 0, width: 10, height: 10)), "far away refused")
check(!DisplayPick.validBox(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)), "infinite refused")

// ---- when to look at a display again (the key path, the VM's requests and omacvm check alike) ----
let t0 = Date(timeIntervalSince1970: 1_000_000)
check(ProbeRule.due(works: nil, probedAt: .distantPast, now: t0, retry: 60), "never looked: look")
check(!ProbeRule.due(works: true, probedAt: t0, now: t0.addingTimeInterval(3600), retry: 60), "settable: not asked again")
check(!ProbeRule.due(works: false, probedAt: t0, now: t0.addingTimeInterval(30), retry: 60), "nothing found 30 s ago: not yet")
check(ProbeRule.due(works: false, probedAt: t0, now: t0.addingTimeInterval(61), retry: 60), "nothing found over a minute ago: again")

// ---- write pace: 50 ms for anything, 250 ms between writes the VM asked for ----
check(WritePace.delay(sinceTransfer: 1, sinceWrite: 1, fromVM: false) == 0, "idle: at once")
check(abs(WritePace.delay(sinceTransfer: 0.01, sinceWrite: 0.01, fromVM: false) - 0.04) < 1e-9, "key: 50 ms after the last transfer")
check(abs(WritePace.delay(sinceTransfer: 0.1, sinceWrite: 0.1, fromVM: true) - 0.15) < 1e-9, "VM: 250 ms after the last write")
check(abs(WritePace.delay(sinceTransfer: 0.01, sinceWrite: 2, fromVM: true) - 0.04) < 1e-9, "VM after a long pause: only the 50 ms gap")
// A VM posting 16 times a second for 2 s: writes at most every 250 ms (coalesced to the latest level).
var clock = 0.0, lastW = -10.0, writes = 0, nextFlush: Double? = nil
for i in 0..<32 {
  let now = Double(i) / 16
  while let f = nextFlush, f <= now { clock = f; lastW = clock; writes += 1; nextFlush = nil }
  if nextFlush == nil { nextFlush = now + WritePace.delay(sinceTransfer: now - lastW, sinceWrite: now - lastW, fromVM: true) }
}
check(writes <= 9, "VM at 16 requests/s for 2 s: \(writes) writes, at most 9")

// ---- why not settable: the HDMI port is named when a display does not answer ----
check(NotSettable.noAnswer.contains("HDMI") && NotSettable.noAnswer.contains("USB-C"),
      "no answer names the HDMI port too (M1/M2 Mac mini: AV service there, no DDC)")
check(NotSettable.noService.contains("HDMI"), "no AV service names the HDMI port")

// ---- how a display is set: macOS's own control first ----
func pick(builtin: Bool = false, virtual: Bool = false, can: Bool = false, reads: Bool = false,
          service: Bool = false, ioav: Bool = true) -> MethodPick.Choice {
  MethodPick.choose(builtin: builtin, virtual: virtual, nativeCan: can, nativeReads: reads, hasService: service, ioav: ioav)
}
// LG UltraFine 5K on a Mac mini (macOS 27, 2026-10-04): DisplayServicesCanChangeBrightness
// true and a level read back, over Thunderbolt (an AV service may be there, DDC/CI is not).
check(pick(can: true, reads: true, service: true) == .native, "LG UltraFine / Studio Display: macOS's control, not DDC/CI")
check(pick(can: true, reads: true) == .native, "...also without an AV service")
check(pick(can: true, reads: false, service: true) == .ddc, "macOS's control does not read: DDC/CI")
check(pick(service: true) == .ddc, "a third-party monitor (Pi-X9): DDC/CI")
check(pick(builtin: true, can: true, reads: true) == .builtin, "the built-in display is never ours")
check(pick(virtual: true, can: true, reads: true, service: true) == .virtual, "virtual / AirPlay: never")
check(pick() == .noService && pick(ioav: false) == .noIOAV, "nothing: why")

// A Mac mini with only an LG UltraFine 5K (2560x1440 points): full screen and windowed.
let ultraFine = MacDisplay(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), builtin: false)
let fullUF = CGRect(x: 0, y: 0, width: 2560, height: 1440), winUF = CGRect(x: 200, y: 100, width: 1600, height: 1000)
check(DisplayPick.focused(windows: [fullUF], displays: [ultraFine], pointer: CGPoint(x: 9, y: 9), windowed: false)?.display == ultraFine,
      "mini, full screen: the UltraFine")
check(DisplayPick.focused(windows: [winUF], displays: [ultraFine], pointer: CGPoint(x: 9, y: 9), windowed: true)?.display == ultraFine,
      "mini, OmacVM.app windowed: the UltraFine")
check(DisplayPick.forBox(CGRect(x: 0, y: 0, width: 2560, height: 1440), windows: [fullUF], displays: [ultraFine]) == ultraFine,
      "mini: Omarchy's brightness for Virtual-1 reaches the UltraFine")
check(DisplayPick.forBox(CGRect(x: 0, y: 0, width: 1600, height: 972), windows: [winUF], displays: [ultraFine]) == ultraFine,
      "mini, windowed: the UltraFine")

// ---- one window list per key event: rects of one process, front to back ----
func win(_ pid: Int32, _ r: CGRect, layer: Int = 0) -> [String: Any] {
  [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowBounds as String: r.dictionaryRepresentation as NSDictionary]
}
let list = [win(7, fullExternal), win(8, fullBuiltin), win(7, CGRect(x: 0, y: 0, width: 50, height: 50)),
            win(7, windowOnExternal, layer: 3), win(7, windowOnExternal)]
check(WindowList.rects(list, pid: 7) == [fullExternal, windowOnExternal], "pid 7: layer 0, not tiny, in order")
check(WindowList.rects(list, pid: 9).isEmpty, "another pid: none")
check(DisplayPick.spansOne(WindowList.rects(list, pid: 7), displays.map(\.bounds)), "the media keys' full-screen rule from the same list")
check(!DisplayPick.spansOne([windowOnExternal], displays.map(\.bounds)), "...a window is not full screen")

// ---- which Bridge an OmacVM.app VM belongs to (test identity vs normal) ----
let rt = "/Contents/Resources/runtime/bin/OmacVM"
check(VMOwner.app(executable: "/Applications/OmacVM.app" + rt) == "/Applications/OmacVM.app", "the VM's app from its QEMU")
check(VMOwner.app(executable: "/Volumes/SD/apps/OmacVM Test.app" + rt) == "/Volumes/SD/apps/OmacVM Test.app", "...also on another drive, with a space")
check(VMOwner.app(executable: "/opt/homebrew/bin/qemu-system-aarch64") == nil, "a development build's QEMU: no app")
check(VMOwner.app(executable: "/Applications/OmacVM.app/Contents/MacOS/OmacVM") == nil, "the launcher is no VM")
check(VMOwner.ours(appID: "org.omacvm.app", testBridge: false), "normal Bridge: OmacVM.app's VM")
check(!VMOwner.ours(appID: "org.omacvm.app", testBridge: true), "test Bridge: not OmacVM.app's VM")
check(VMOwner.ours(appID: "org.omacvm.app.test", testBridge: true), "test Bridge: OmacVM Test.app's VM")
check(!VMOwner.ours(appID: "org.omacvm.app.test", testBridge: false),
      "normal Bridge: not OmacVM Test.app's VM (Air 2026-10-06: it took the keys, no OSD in the VM)")
check(VMOwner.ours(appID: "org.omacvm.app.test.fixid", testBridge: true) &&
      !VMOwner.ours(appID: "org.omacvm.app.test.fixid", testBridge: false),
      "a lane's copy (org.omacvm.app.test.<lane>): the test Bridge's, as the app's TestIdentity")
check(VMOwner.ours(appID: "org.omacvm.app.tester", testBridge: false) &&
      !VMOwner.ours(appID: "org.omacvm.app.tester", testBridge: true), "org.omacvm.app.tester: not the test app (only the dot form)")
check(VMOwner.ours(appID: "com.example.omacvm", testBridge: false), "normal Bridge: a build with another bundle id")
check(VMOwner.ours(appID: nil, testBridge: false) && VMOwner.ours(appID: nil, testBridge: true), "unknown app (development build): every Bridge's, as before")

if failed > 0 { print("\(failed) failed"); exit(1) }
print("external brightness: all offline tests passed")
