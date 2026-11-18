// The Bridge's brightness-key reader (hid-keys.swift) with made-up keyboards
// in place of IOHIDManager: the real BrightnessKeys class gets key values as
// its IOKit callback hands them on. Then, read only, this Mac's own keyboards:
// their F-key maps through the same code (no key is pressed, nothing opened).
import Foundation
import IOKit.hid

func log(_ s: String) { print("log: \(s)") }

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failed += 1; print("     (line \(line))") }
}

let b = BrightnessKeys()
var got: [MediaKey] = []
var gotMods: [KeyMods] = []
b.onKey = { got.append($0); gotMods.append($1) }
// Key repeat: timers are run by hand here (macOS's delay 0.25 s, interval 0.03 s in this test).
var timers: [(after: Double, run: () -> Void)] = []
b.repeatTimes = { (0.25, 0.03) }
b.after = { timers.append(($0, $1)) }
func runTimers(_ n: Int) { for _ in 0..<n where !timers.isEmpty { timers.removeFirst().run() } }
var reads: [UInt64: Int] = [:]
let macbook: [UInt32: UInt32] = [HIDUsage.f1: 0x00FF_0005, HIDUsage.f2: 0x00FF_0004, 0x0007_0044: 0x000C_00EA]
func key(_ dev: UInt64, _ page: UInt32, _ usage: UInt32, _ down: Bool, map: [UInt32: UInt32], fnState: Bool = false, copies: [Int] = [0]) {
  let u = HIDUsage.of(page: page, usage: usage)
  guard BrightnessKeys.wanted(u) else { return }   // as the IOKit callback filters
  for c in copies { b.input(device: dev, copy: c, usage: u, pressed: down, fnState: fnState) { reads[dev, default: 0] += 1; return map } }
}
func tap(_ dev: UInt64, _ page: UInt32, _ usage: UInt32, map: [UInt32: UInt32], fnState: Bool = false) {
  key(dev, page, usage, true, map: map, fnState: fnState); key(dev, page, usage, false, map: map, fnState: fnState)
}

// The MacBook's keyboard: F1, F2, F2, then a letter, F11 (volume) and Return.
tap(1, 7, 0x3A, map: macbook); tap(1, 7, 0x3B, map: macbook); tap(1, 7, 0x3B, map: macbook)
tap(1, 7, 0x04, map: macbook); tap(1, 7, 0x44, map: macbook); tap(1, 7, 0x28, map: macbook)
check(got == [.brightnessDown, .brightnessUp, .brightnessUp], "MacBook keyboard: F1, F2, F2 -> down, up, up; A, F11, Return: nothing")
check(reads[1] == 1, "... its map is read once")
check(!BrightnessKeys.wanted(HIDUsage.of(page: 7, usage: 0x04)) && !BrightnessKeys.wanted(HIDUsage.of(page: 7, usage: 0x28)),
      "letters and Return are never looked at")
// fn + F1 with the special keys on top: F1 (nothing for the Bridge).
got = []
key(1, 0xFF, 0x03, true, map: macbook); tap(1, 7, 0x3A, map: macbook); key(1, 0xFF, 0x03, false, map: macbook)
check(got.isEmpty, "fn + F1: plain F1")
// Magic Keyboard (USB/Bluetooth, no map: Apple's default), standard F-keys on.
got = []
tap(2, 7, 0x3B, map: HIDBrightness.appleDefault, fnState: true)
key(2, 0xFF01, 0x03, true, map: HIDBrightness.appleDefault, fnState: true)
tap(2, 7, 0x3B, map: HIDBrightness.appleDefault, fnState: true)
key(2, 0xFF01, 0x03, false, map: HIDBrightness.appleDefault, fnState: true)
check(got == [.brightnessUp], "Magic Keyboard, standard F-keys: F2 is F2, fn + F2 is brightness up")
// The Mac mini's Magic Keyboard: Bluetooth, vendor 0x004C, no FnFunctionUsageMap (read on the mini with ioreg).
got = []
let btMap = HIDBrightness.map(published: nil, vendor: 0x004C)
tap(4, 7, 0x3A, map: btMap); tap(4, 7, 0x3B, map: btMap); tap(4, 7, 0x3B, map: btMap)
check(got == [.brightnessDown, .brightnessUp, .brightnessUp], "Bluetooth Magic Keyboard (0x004C, no map): F1, F2, F2 -> down, up, up")
got = []
key(4, 0xFF, 0x03, true, map: btMap); tap(4, 7, 0x3A, map: btMap); key(4, 0xFF, 0x03, false, map: btMap)
tap(4, 0x0C, 0x6F, map: btMap)
check(got == [.brightnessUp], "... fn + F1 is F1; its consumer brightness up still acts")
got = []
tap(4, 7, 0x3A, map: btMap, fnState: true)
key(4, 0xFF, 0x03, true, map: btMap, fnState: true); tap(4, 7, 0x3A, map: btMap, fnState: true); key(4, 0xFF, 0x03, false, map: btMap, fnState: true)
check(got == [.brightnessDown], "... standard F-keys on: F1 is F1, fn + F1 is brightness down")
// Held keys repeat at macOS's speed until released (HID sends no repeats).
timers = []; got = []
key(4, 7, 0x3B, true, map: btMap)
check(got == [.brightnessUp] && timers.first?.after == 0.25, "held F2: one step at once, the repeat after macOS's delay")
runTimers(9)
check(got.count == 10 && got.allSatisfy { $0 == .brightnessUp } && timers.first?.after == 0.03, "held F2: 9 repeats at macOS's interval (\(got.count) steps)")
key(4, 7, 0x3B, false, map: btMap)
runTimers(5)
check(got.count == 10 && timers.isEmpty, "released: the repeats stop")
timers = []; got = []
key(4, 7, 0x3A, true, map: btMap); runTimers(2)
key(4, 7, 0x3B, true, map: btMap); runTimers(3)
check(got == [.brightnessDown, .brightnessDown, .brightnessDown, .brightnessUp, .brightnessUp, .brightnessUp] && timers.count == 1,
      "F1 held then F2: F1's repeats stop, F2 repeats (\(got))")
key(4, 7, 0x3A, false, map: btMap); runTimers(1)
check(got.count == 7, "releasing F1 (not the held key) does not stop F2")
key(4, 7, 0x3B, false, map: btMap); runTimers(3)
check(timers.isEmpty, "... releasing F2 does")
timers = []; got = []
key(4, 7, 0x3B, true, map: btMap); runTimers(500)
check(got.count == 1 + BrightnessKeys.maxRepeats && timers.isEmpty, "a release that never comes: the repeats stop after \(BrightnessKeys.maxRepeats)")
key(4, 7, 0x3B, false, map: btMap)
timers = []; got = []
tap(4, 7, 0x04, map: btMap)
check(got.isEmpty && timers.isEmpty, "a letter: nothing, no repeat")
timers = []
// A PC keyboard's own brightness keys (consumer page).
got = []
tap(3, 0x0C, 0x70, map: [:]); tap(3, 0x0C, 0x6F, map: [:]); tap(3, 7, 0x3A, map: [:])
check(got == [.brightnessDown, .brightnessUp], "PC keyboard: its brightness keys act, its F1 is F1")

// ---- The MacBook Air's keyboard as macOS 27 gives it: two IOHIDDevice copies (keyboard 1/6 and consumer control 12/1) ----
let air: [Int] = [11, 12]   // every value comes once from each copy
let shiftL: UInt32 = 0xE1, shiftR: UInt32 = 0xE5, optL: UInt32 = 0xE2
timers = []; got = []; gotMods = []
key(20, 7, 0x3A, true, map: macbook, copies: air); key(20, 7, 0x3A, false, map: macbook, copies: air)
check(got == [.brightnessDown] && timers.count == 1, "Air keyboard given twice: F1 is one press, one step (was two: \(got.count))")
check(reads[20] == 1, "... its map is read once")
key(20, 7, 0x3A, true, map: macbook, copies: [12]); key(20, 7, 0x3A, false, map: macbook, copies: [12])
check(got.count == 1, "... a value from the second copy alone is not read")
timers = []; got = []; gotMods = []
// Shift + F1, Shift + F2 (Shift read from the keyboard, not from macOS's session).
key(20, 7, shiftL, true, map: macbook, copies: air)
key(20, 7, 0x3A, true, map: macbook, copies: air); key(20, 7, 0x3A, false, map: macbook, copies: air)
key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air)
key(20, 7, shiftL, false, map: macbook, copies: air)
check(got == [.brightnessDown, .brightnessUp] && gotMods == [KeyMods(shift: true), KeyMods(shift: true)],
      "Shift + F1, Shift + F2: down and up, each read with Shift (\(gotMods))")
check(got.map { BrightnessCombo.key($0, KeyMods(shift: true)).key } == [.keyboardDown, .keyboardUp], "... = keyboard light down, up")
timers = []; got = []; gotMods = []
key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air)
check(gotMods == [KeyMods()], "Shift let go: F2 alone is the display again")
// Key up order: the brightness key let go before Shift, and after.
timers = []; got = []; gotMods = []
key(20, 7, shiftR, true, map: macbook, copies: air); key(20, 7, 0x3B, true, map: macbook, copies: air)
key(20, 7, shiftR, false, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air)   // Shift up first
key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air)
check(gotMods == [KeyMods(shift: true), KeyMods()], "Shift up before F2 up: that press was Shift's, the next plain F2 is not")
timers = []; got = []; gotMods = []
// A held Shift + F2, Shift let go mid-hold: every repeat stays on the keyboard light.
key(20, 7, shiftL, true, map: macbook, copies: air); key(20, 7, 0x3B, true, map: macbook, copies: air)
runTimers(3)
key(20, 7, shiftL, false, map: macbook, copies: air)
runTimers(10)
key(20, 7, 0x3B, false, map: macbook, copies: air); runTimers(5)
check(got.count == 14 && gotMods.allSatisfy { $0 == KeyMods(shift: true) },
      "held Shift + F2, Shift let go after 3 repeats: all 14 steps with Shift (\(gotMods.filter { !$0.shift }.count) without)")
check(timers.isEmpty, "... F2 let go: the repeats stop")
// A plain held F1, Shift pressed mid-hold: the display to the end.
timers = []; got = []; gotMods = []
key(20, 7, 0x3A, true, map: macbook, copies: air); runTimers(2)
key(20, 7, shiftL, true, map: macbook, copies: air); runTimers(4)
key(20, 7, 0x3A, false, map: macbook, copies: air); key(20, 7, shiftL, false, map: macbook, copies: air)
check(got.count == 7 && gotMods.allSatisfy { $0 == KeyMods() }, "held F1, Shift pressed mid-hold: all 7 steps on the display")
// Option: small steps; Shift + Option: the display's small steps.
timers = []; got = []; gotMods = []
key(20, 7, optL, true, map: macbook, copies: air); key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air)
key(20, 7, shiftL, true, map: macbook, copies: air); key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air)
key(20, 7, shiftL, false, map: macbook, copies: air); key(20, 7, optL, false, map: macbook, copies: air)
check(gotMods == [KeyMods(option: true), KeyMods(shift: true, option: true)], "Option + F2, Shift + Option + F2: read with them")
// Shift on the Air, F1 on a Magic Keyboard (and the other way): any keyboard's Shift counts.
timers = []; got = []; gotMods = []
key(20, 7, shiftL, true, map: macbook, copies: air); tap(4, 7, 0x3A, map: btMap); key(20, 7, shiftL, false, map: macbook, copies: air)
key(4, 7, shiftL, true, map: btMap); key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air); key(4, 7, shiftL, false, map: btMap)
check(gotMods == [KeyMods(shift: true), KeyMods(shift: true)], "Shift on one keyboard, the brightness key on another: Shift")
// A keyboard that goes away with Shift held (Bluetooth off): its Shift is not held any more.
timers = []; got = []; gotMods = []
key(4, 7, shiftL, true, map: btMap); key(4, 7, 0x3B, true, map: btMap)
b.removed(device: 4); runTimers(5)
check(got.count == 1 && timers.isEmpty, "a keyboard gone mid-hold: its repeats stop")
key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air)
check(gotMods.last == KeyMods(), "... and its Shift is not held for the next press")
// Fast presses: 30 quick Shift + F2 taps (no repeats), each one step with Shift.
timers = []; got = []; gotMods = []
key(20, 7, shiftL, true, map: macbook, copies: air)
for _ in 0..<30 { key(20, 7, 0x3B, true, map: macbook, copies: air); key(20, 7, 0x3B, false, map: macbook, copies: air) }
key(20, 7, shiftL, false, map: macbook, copies: air)
check(got.count == 30 && gotMods.allSatisfy { $0.shift }, "30 quick Shift + F2: 30 steps, all with Shift (\(got.count))")
timers = []

// ---- stress: 1000 presses on the Air's keyboard (both copies), through the Bridge's rule to the keyboard light ----
// A made-up Mac: the display's level and the keyboard light with every step (KeyboardSteps, the low ones on).
// Each brightness key the reader hands over goes where the Bridge sends it with the VM in front (BrightnessCombo).
var light: Float = 0, display: Float = 0.5, displayMoves = 0, lightMoves = 0
b.onKey = { k, m in
  let (to, _) = BrightnessCombo.key(k, m)
  switch to {
  case .keyboardUp, .keyboardDown:
    var now = light
    light = KeyboardSteps.settle(from: light, up: to == .keyboardUp, low: true, set: { now = $0; return true }, lit: { now > 0 }) ?? light
    lightMoves += 1
  default: display += to == .brightnessUp ? 1 / 32 : -1 / 32; displayMoves += 1
  }
}
var seed: UInt64 = 0x5EED
func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
var presses = 0, shiftPresses = 0, wrong = 0, stuck = 0
let ladder: [Float] = [0] + KeyboardSteps.low + (1...16).map { Float($0) / 16 }
while presses < 1000 {
  let up = rnd(2) == 0, usage: UInt32 = up ? 0x3B : 0x3A
  let withShift = rnd(5) != 0   // mostly Shift combos, some plain presses between
  let (d0, l0) = (displayMoves, light)
  if withShift { key(20, 7, rnd(2) == 0 ? shiftL : shiftR, true, map: macbook, copies: air) }
  key(20, 7, usage, true, map: macbook, copies: air)
  let repeats = rnd(4) == 0 ? 1 + rnd(8) : 0   // a quarter of them held for some repeats
  let shiftOffAt = withShift && rnd(3) == 0 ? rnd(repeats + 1) : -1   // Shift let go mid-press
  for i in 0..<repeats {
    if i == shiftOffAt { key(20, 7, shiftL, false, map: macbook, copies: air); key(20, 7, shiftR, false, map: macbook, copies: air) }
    runTimers(1)
  }
  let shiftFirst = rnd(2) == 0   // key up order
  if withShift && shiftFirst { key(20, 7, shiftL, false, map: macbook, copies: air); key(20, 7, shiftR, false, map: macbook, copies: air) }
  key(20, 7, usage, false, map: macbook, copies: air)
  if withShift && !shiftFirst { key(20, 7, shiftL, false, map: macbook, copies: air); key(20, 7, shiftR, false, map: macbook, copies: air) }
  runTimers(3)   // nothing may run after the key up
  timers = []
  presses += 1 + repeats
  if withShift {
    shiftPresses += 1 + repeats
    if displayMoves != d0 { wrong += 1 }   // the display moved on a Shift combo
    // The light moved one step per press and repeat, or stood at its end.
    var want = l0
    for _ in 0...repeats { want = KeyboardSteps.next(want, up: up, low: true) }
    if light != want { stuck += 1 }
  } else if light != l0 { wrong += 1 }   // a plain press moved the keyboard light
}
check(wrong == 0, "stress: \(presses) presses (\(shiftPresses) with Shift): the display never moved on a Shift combo, the light never on a plain press (\(wrong) wrong)")
check(stuck == 0, "stress: the keyboard light followed every Shift press and repeat, through the low steps and off (\(stuck) off)")
check(ladder.contains(light), "stress: the light ends on one of its steps (\(light))")
b.onKey = { got.append($0); gotMods.append($1) }

// ---- a keyboard reader that cannot open (#813): one manager, tries spaced out ----
var r = HIDOpenRetry()
var waits: [Double] = []
for i in 0..<10 { waits.append(r.failed(at: Double(i))) }
check(waits == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300], "retry waits: 2 s doubling to 5 min (\(waits))")
check(!r.due(at: 9 + 299) && r.due(at: 9 + 300), "retry: due only when its wait is over")
r.opened()
check(r.due(at: 0) && r.failed(at: 0) == 2, "retry: an open that worked starts again from 2 s")

let k = BrightnessKeys()
var made = 0, opens = 0, managers = Set<ObjectIdentifier>()
var answer: IOReturn = IOReturn(bitPattern: 0xe000_02c5)   // kIOReturnExclusiveAccess: Karabiner holds a keyboard
var access = kIOHIDAccessTypeGranted
k.access = { access }
k.makeManager = { _ in made += 1; return IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)) }
k.open = { opens += 1; managers.insert(ObjectIdentifier($0)); return answer }
var t = 0.0
while t < 3600 { k.ensure(at: t); t += 2 }   // MediaKeys.check: every 2 s for an hour
check(made == 1 && managers.count == 1, "open fails for an hour: one manager made, opened again (\(made) made)")
check(opens <= 20, "open fails for an hour, asked every 2 s: \(opens) tries, not 1800")
answer = kIOReturnSuccess
while t < 3600 + 301 { k.ensure(at: t); t += 2 }
let afterOpen = opens
while t < 7200 { k.ensure(at: t); t += 2 }
check(opens == afterOpen && made == 1, "open works at its next try, then no more tries (\(opens - afterOpen) after)")
let d = BrightnessKeys()
var dOpens = 0, dMade = 0
d.access = { kIOHIDAccessTypeDenied }
d.makeManager = { _ in dMade += 1; return IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)) }
d.open = { _ in dOpens += 1; return kIOReturnSuccess }
for i in 0..<100 { d.ensure(at: Double(i) * 2) }
check(dOpens == 0 && dMade == 0, "Input Monitoring off: no manager, no open")

// ---- this Mac's keyboards, read only ----
let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
if devices.isEmpty { print("skip this Mac: no keyboard (CI)") }
for d in devices {
  let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
  let map = BrightnessKeys.fnMap(d, IOHIDDeviceGetService(d))
  let f1 = map[HIDUsage.f1].flatMap(HIDBrightness.key), f2 = map[HIDUsage.f2].flatMap(HIDBrightness.key)
  print("this Mac: \(name): F1 -> \(f1.map { "\($0)" } ?? "-"), F2 -> \(f2.map { "\($0)" } ?? "-") (\(map.count) keys mapped)")
  if !map.isEmpty { check(f1 == .brightnessDown && f2 == .brightnessUp, "this Mac: \(name): F1/F2 are its brightness keys") }
}
print("standard function keys (fnState): \(BrightnessKeys.fnState())")
if failed > 0 { print("\(failed) failed"); exit(1) }
print("hid keys: all ok")
