// Offline tests of keys-model.swift (when the media-key tap is created again)
// and wifi-model.swift (a steady Wi-Fi state). No permissions, no Wi-Fi.
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failed += 1; print("     (line \(line))") }
}

// ---- TapRearm ----
var r = TapRearm()
check(!r.front(nil), "tap: no OmacVM in front, nothing to do")
check(r.front(600), "tap: an OmacVM VM comes to the front: again")
check(!r.front(600) && !r.front(600), "tap: not again while it stays in front (checked every 2 s)")
check(r.front(700), "tap: straight to a second VM (another QEMU): again")
check(!r.front(nil) && r.front(700), "tap: the same VM after another app: again")
check(!r.front(nil) && r.front(800), "tap: OmacVM.app restarted (a new pid): again")
check(r.failed() && !r.failed() && !r.failed(), "tap: a failed re-creation is logged once")
r.worked()
check(r.failed(), "tap: ... and again after one worked")

// ---- WiFiSteady ----
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: Double) -> Date { t0 + s }
func wifi(_ connected: Bool, ssid: String? = "Office", rssi: Int = -60, power: Bool = true, location: Bool = true) -> [String: Any] {
  ["connected": connected, "power": power, "ssid": connected ? (ssid as Any) : NSNull(),
   "rssi": connected ? rssi : NSNull() as Any, "location_authorized": location, "wired": true]
}
func connected(_ s: [String: Any]) -> Bool { s["connected"] as? Bool == true }

var w = WiFiSteady()
check(!connected(w.take(wifi(false), link: false, event: nil, now: at(0)).state), "wifi: not connected from the start is reported")
var r1 = w.take(wifi(true), link: true, event: nil, now: at(1))
check(connected(r1.state) && !r1.held, "wifi: connected")
// The Mac mini's flicker: a lone bad read at a tick, link still up, then fine.
r1 = w.take(wifi(false), link: true, event: nil, now: at(6))
check(connected(r1.state) && r1.held && r1.state["ssid"] as? String == "Office", "wifi: a bad read while the link is up keeps the last state")
r1 = w.take(wifi(true, rssi: -62), link: true, event: nil, now: at(11))
check(connected(r1.state) && !r1.held && r1.state["rssi"] as? Int == -62, "wifi: the next good read goes through")
// Ticks every 5 s: bad, good, bad, good (link up): never a change.
var flips = 0, last = true
for k in 0..<12 {
  let s = w.take(wifi(k % 2 == 1), link: true, event: nil, now: at(20 + Double(k) * 5)).state
  if connected(s) != last { flips += 1; last = connected(s) }
}
check(flips == 0, "wifi: alternating good and bad reads report no change (\(flips) flips)")
// Link state not known (no SCDynamicStore answer): held for WiFiSteady.hold, then believed.
r1 = w.take(wifi(false), link: nil, event: nil, now: at(100))
check(connected(r1.state) && r1.held, "wifi: a lone bad read without a link state is held")
r1 = w.take(wifi(true), link: nil, event: nil, now: at(105))
check(connected(r1.state) && !r1.held, "wifi: ... and the hold ends with a good read")
_ = w.take(wifi(false), link: false, event: nil, now: at(200))
r1 = w.take(wifi(false), link: false, event: nil, now: at(205))
check(connected(r1.state) && r1.held, "wifi: no event: still held after 5 s")
r1 = w.take(wifi(false), link: false, event: nil, now: at(210))
check(!connected(r1.state) && !r1.held, "wifi: no event: believed after \(Int(WiFiSteady.hold)) s")
// A real disconnect: CoreWLAN's event comes with it, so it is shown at once.
_ = w.take(wifi(true), link: true, event: at(209), now: at(300))
r1 = w.take(wifi(false), link: false, event: at(400), now: at(400.3))
check(!connected(r1.state) && !r1.held, "wifi: a disconnect with a CoreWLAN event is shown at once")
_ = w.take(wifi(true), link: true, event: at(400), now: at(500))
r1 = w.take(wifi(false), link: false, event: at(499), now: at(500.5))
check(!connected(r1.state), "wifi: an event just before the drop counts too")
_ = w.take(wifi(true), link: true, event: at(500), now: at(600))
r1 = w.take(wifi(false), link: false, event: at(560), now: at(605))
check(connected(r1.state) && r1.held, "wifi: an old event does not count")
// Wi-Fi switched off: the power event says so.
_ = w.take(wifi(true), link: true, event: at(500), now: at(700))
r1 = w.take(wifi(false, power: false), link: false, event: at(710), now: at(710.3))
check(!connected(r1.state) && r1.state["power"] as? Bool == false, "wifi: power off is shown at once")
// While held, the fields that are no part of the link come from the newest read.
_ = w.take(wifi(true), link: true, event: nil, now: at(800))
r1 = w.take(wifi(false, location: false), link: true, event: nil, now: at(805))
check(connected(r1.state) && r1.state["location_authorized"] as? Bool == false, "wifi: Location Services from the newest read while held")

// Bad reads only, for a minute, while the link still says up: believed then.
_ = w.take(wifi(true), link: true, event: nil, now: at(900))
r1 = w.take(wifi(false), link: true, event: nil, now: at(905))
check(connected(r1.state) && r1.held, "wifi: link up, a bad read: held")
r1 = w.take(wifi(false), link: true, event: nil, now: at(950))
check(connected(r1.state) && r1.held, "wifi: link up, bad reads for 45 s: still held")
r1 = w.take(wifi(false), link: true, event: nil, now: at(966))
check(!connected(r1.state) && !r1.held, "wifi: link up, only bad reads for \(Int(WiFiSteady.linkHold)) s: believed")
// ... but one good read in between starts the minute again.
_ = w.take(wifi(true), link: true, event: nil, now: at(1000))
_ = w.take(wifi(false), link: true, event: nil, now: at(1005))
_ = w.take(wifi(true), link: true, event: nil, now: at(1040))
r1 = w.take(wifi(false), link: true, event: nil, now: at(1070))
check(connected(r1.state) && r1.held, "wifi: a good read between restarts the minute")

// Without Location Services (not decided after a new Bridge, or "Don't Allow"; the Mac mini on
// macOS 27): CoreWLAN reads a channel with no signal and no SSID most of the time, now and then
// a signal. The link state decides; the bar never flips while the link is up.
check(WiFiRead.connected(power: true, channel: true, rssi: 0, locationOK: false, link: true), "wifi read: no Location, link up: connected")
check(!WiFiRead.connected(power: true, channel: true, rssi: -51, locationOK: false, link: false), "wifi read: no Location, link down: not connected")
check(WiFiRead.connected(power: true, channel: true, rssi: -51, locationOK: false, link: nil), "wifi read: no Location, link not known: CoreWLAN's read")
check(!WiFiRead.connected(power: true, channel: true, rssi: 0, locationOK: true, link: true), "wifi read: with Location, CoreWLAN's read (WiFiSteady holds it)")
check(!WiFiRead.connected(power: false, channel: false, rssi: 0, locationOK: false, link: true), "wifi read: power off: not connected")
var nl = WiFiSteady(), nlFlips = 0, nlLast = false
for i in 0..<120 {   // 10 minutes of reads every 5 s, a signal in one read of six
  let rssi = i % 6 == 0 ? -51 : 0
  let c = WiFiRead.connected(power: true, channel: true, rssi: rssi, locationOK: false, link: true)
  var raw = wifi(c, ssid: nil, rssi: rssi, location: false)
  if rssi == 0 { raw["rssi"] = NSNull() }
  let s = nl.take(raw, link: true, event: nil, now: at(Double(i) * 5)).state
  if i > 0 && connected(s) != nlLast { nlFlips += 1 }
  nlLast = connected(s)
  if i == 7 { check(s["rssi"] as? Int == -51, "wifi: no Location: a read without a signal keeps the last one known") }
}
check(nlFlips == 0 && nlLast, "wifi: no Location, link up, 10 minutes of mostly empty reads: connected, 0 flips")

// ---- MediaRoute: where each media key goes ----
func route(_ k: MediaKey, _ vm: FrontVM?, volume: Bool = true, mute: Bool = true, mac: UInt32? = nil,
           external: ExternalState = .unknown, light: Bool = false) -> KeyRoute {
  MediaRoute.route(k, vm: vm, volumeSettable: volume, muteSettable: mute, macBrightness: mac, external: external, keyboardLight: light)
}
// A Mac mini M4 with ONE display, an LG UltraFine 5K (display 5, external, set
// through DisplayServices), no built-in display, no keyboard light; audio
// through a Focusrite Scarlett 2i2 (no software volume, no mute).
let uf: UInt32 = 5
let miniFull = FrontVM(omacvm: true, fullScreen: true, display: uf, builtin: false, vmKeys: true)
let miniWin = FrontVM(omacvm: true, fullScreen: false, display: uf, builtin: false, vmKeys: true)
for (vm, how) in [(miniFull, "full screen"), (miniWin, "windowed")] {
  check(route(.brightnessUp, vm, mac: uf, external: .works) == .external(uf), "mini \(how): brightness sets the UltraFine (its own control)")
  check(route(.brightnessDown, vm, mac: uf, external: .unknown) == .mac,
        "mini \(how): not looked at yet: the Bridge's own call on the same display (never dropped)")
  check(route(.brightnessUp, vm, mac: uf, external: .off) == .mac, "mini \(how): external brightness off: still the UltraFine")
  check(route(.volumeUp, vm, volume: false, mute: false) == .vm("volumeup"), "mini \(how): Scarlett, volume up: the VM's own volume")
  check(route(.volumeDown, vm, volume: false, mute: false) == .vm("volumedown"), "mini \(how): Scarlett, volume down: the VM's")
  check(route(.mute, vm, volume: false, mute: false) == .vm("audiomute"), "mini \(how): Scarlett, mute: the VM's")
  check(route(.volumeUp, vm) == .mac && route(.mute, vm) == .mac, "mini \(how): speakers with a volume: the Mac's")
  check(route(.play, vm) == .vm("audioplay") && route(.next, vm) == .vm("audionext") && route(.previous, vm) == .vm("audioprev"),
        "mini \(how): play/pause, next, previous: the VM's players")
  check(route(.fast, vm) == .vm("audionext") && route(.rewind, vm) == .vm("audioprev"), "mini \(how): an Apple keyboard's track keys too")
  check(route(.keyboardUp, vm) == .macOS(nil), "mini \(how): no keyboard light: macOS's")
}
// The UltraFine says no (asleep): to macOS with the reason, and the Bridge's own call when it reaches it.
check(route(.brightnessUp, miniWin, mac: nil, external: .no("asleep")) == .macOS("asleep"), "mini: cannot be set: to macOS, with why")
check(route(.brightnessUp, miniWin, mac: uf, external: .no("asleep")) == .mac, "mini: no DDC but DisplayServices reaches it: the Bridge's")
// No VM in front: everything stays macOS's.
for k in [MediaKey.volumeUp, .mute, .play, .brightnessUp, .keyboardUp] {
  check(route(k, nil, volume: false, mac: uf, external: .works, light: true) == .macOS(nil), "no VM in front: \(k) is macOS's")
}
// The VM takes no keys (its control socket not found): to macOS, with why.
var noKeys = miniWin; noKeys.vmKeys = false
if case .macOS(let why) = route(.volumeUp, noKeys, volume: false) { check(why != nil, "VM without a control socket: volume to macOS, with why") }
else { check(false, "VM without a control socket: volume to macOS, with why") }

// A MacBook Pro (built-in 1, notch) with an external Pi-X9 (2, DDC/CI).
let builtinFull = FrontVM(omacvm: true, fullScreen: true, display: 1, builtin: true, vmKeys: true)
let builtinWin = FrontVM(omacvm: true, fullScreen: false, display: 1, builtin: true, vmKeys: true)
let extFull = FrontVM(omacvm: true, fullScreen: true, display: 2, builtin: false, vmKeys: true)
check(route(.brightnessUp, builtinFull, mac: 1) == .mac, "MacBook full screen: the built-in's brightness, by the Bridge (no macOS popup)")
check(route(.brightnessUp, builtinWin, mac: 1) == .mac, "MacBook windowed on the built-in: the Bridge sets it (macOS's shortcuts are off while the VM has the keyboard)")
check(route(.brightnessUp, extFull, mac: 1, external: .works) == .external(2), "MacBook, VM on the Pi-X9: DDC/CI")
check(route(.brightnessUp, extFull, mac: 1, external: .no("no DDC")) == .macOS("no DDC"), "MacBook, Pi-X9 without DDC: macOS, with why")
check(route(.brightnessUp, extFull, mac: 1, external: .off) != .mac, "MacBook: the built-in is never set for a VM on the external")
check(route(.keyboardUp, builtinFull, light: true) == .mac, "MacBook: Shift+brightness, the keyboard light")
check(route(.volumeUp, builtinWin) == .mac, "MacBook windowed: volume, the Mac's (with the VM's popup)")
// Parallels, UTM, Fusion: full screen only, and no keys typed into them.
let parFull = FrontVM(omacvm: false, fullScreen: true, display: 1, builtin: true, vmKeys: false)
let parWin = FrontVM(omacvm: false, fullScreen: false, display: 1, builtin: true, vmKeys: false)
check(route(.volumeUp, parFull) == .mac && route(.volumeUp, parWin) == .macOS(nil), "Parallels: the Mac's volume in full screen only")
check(route(.play, parFull) == .macOS(nil), "Parallels: play stays as it was (its own)")
// Command + a volume key (Cmd+F10/F11/F12 on Apple keyboards): Omarchy's
// screenshot keys (Super + mute/volume down/volume up), whatever the output.
func cmd(_ k: MediaKey, _ vm: FrontVM?, volume: Bool = true, mute: Bool = true) -> KeyRoute {
  MediaRoute.route(k, vm: vm, volumeSettable: volume, muteSettable: mute, macBrightness: 1, external: .unknown,
                   keyboardLight: true, command: true)
}
for (vm, how) in [(builtinFull, "MacBook full screen"), (builtinWin, "MacBook windowed"), (miniFull, "mini full screen")] {
  check(cmd(.volumeDown, vm) == .vm("volumedown") && cmd(.mute, vm) == .vm("audiomute") && cmd(.volumeUp, vm) == .vm("volumeup"),
        "\(how): Command + mute/volume down/up go to the VM (Super + the key), not the Mac's volume")
  check(cmd(.volumeDown, vm, volume: false, mute: false) == .vm("volumedown"), "\(how): Command + volume down, output without a volume: the VM's too")
}
check(cmd(.volumeDown, noKeys) == .mac, "Command + volume, VM without a control socket: the Mac's volume as before")
check(cmd(.volumeDown, parFull) == .mac && cmd(.volumeDown, parWin) == .macOS(nil), "Command + volume on Parallels: as without Command")
check(cmd(.volumeDown, nil) == .macOS(nil), "Command + volume, no VM in front: macOS's")
check(cmd(.brightnessUp, builtinFull) == .mac && cmd(.play, builtinFull) == .vm("audioplay"),
      "Command + brightness / play: unchanged")

var once = OnceLog()
check(once.first("a") && !once.first("a") && once.first("b"), "a reason is logged once")

// ---- brightness keys read from the keyboard (HIDBrightness, HIDKeyboards, BrightnessOnce) ----
// The MacBook Pro M4 Max's own keyboard map (ioreg, FnFunctionUsageMap).
let macbookMap = HIDBrightness.fnMap("0x0007003a,0x00ff0005,0x0007003b,0x00ff0004,0x0007003c,0xff010010,0x0007003d,0x000c0221,"
  + "0x0007003e,0x000c00cf,0x0007003f,0x0001009b,0x00070040,0x000c00b4,0x00070041,0x000c00cd,0x00070042,0x000c00b3,"
  + "0x00070043,0x000c00e2,0x00070044,0x000c00ea,0x00070045,0x000c00e9")
check(macbookMap.count == 12 && macbookMap[HIDUsage.f1] == 0x00FF_0005 && macbookMap[HIDUsage.f2] == 0x00FF_0004,
      "hid: the MacBook's FnFunctionUsageMap: F1 -> top-case brightness down, F2 -> up (12 keys)")
check(HIDBrightness.fnMap(nil).isEmpty && HIDBrightness.fnMap("").isEmpty && HIDBrightness.fnMap("0x0007003a").isEmpty,
      "hid: no map, an empty one, an odd one: nothing")
check(HIDBrightness.fnMap("zz,0x00ff0005,0x0007003b,0x00ff0004") == [HIDUsage.f2: 0x00FF_0004], "hid: a pair that does not parse is left out")
check(HIDBrightness.key(0x000C_006F) == .brightnessUp && HIDBrightness.key(0x000C_0070) == .brightnessDown,
      "hid: consumer page 0x6F/0x70 are brightness up/down")
check(HIDBrightness.key(0x00FF_0004) == .brightnessUp && HIDBrightness.key(0xFF01_0021) == .brightnessDown,
      "hid: Apple's top-case and keyboard pages too")
check(HIDBrightness.key(HIDUsage.f1) == nil && HIDBrightness.key(0x000C_00E9) == nil, "hid: F1 itself and volume up are not")
var kb = HIDKeyboards()
func hid(_ d: UInt64, _ u: UInt32, _ p: Bool, _ m: [UInt32: UInt32] = macbookMap, fnState: Bool = false) -> MediaKey? {
  kb.value(device: d, usage: u, pressed: p, map: m, fnState: fnState)
}
// MacBook / Magic Keyboard, macOS's default (special keys on top).
check(hid(1, HIDUsage.f1, true) == .brightnessDown && hid(1, HIDUsage.f1, false) == nil, "hid: F1 pressed: brightness down; released: nothing")
check(hid(1, HIDUsage.f2, true) == .brightnessUp, "hid: F2: brightness up")
check(hid(1, 0x0007_003C, true) == nil && hid(1, 0x0007_0044, true) == nil, "hid: F3 (Mission Control), F11 (volume): not brightness")
_ = hid(1, 0x00FF_0003, true)
check(hid(1, HIDUsage.f1, true) == nil, "hid: fn + F1: plain F1, no brightness")
_ = hid(1, 0x00FF_0003, false)
check(hid(1, HIDUsage.f1, true) == .brightnessDown, "hid: fn released: F1 is brightness again")
// "Use F1, F2, etc. keys as standard function keys".
check(hid(1, HIDUsage.f1, true, fnState: true) == nil, "hid: standard F-keys: F1 is F1")
_ = hid(1, 0xFF01_0003, true)
check(hid(1, HIDUsage.f2, true, fnState: true) == .brightnessUp, "hid: standard F-keys: fn (Apple keyboard page) + F2 is brightness up")
_ = hid(1, 0xFF01_0003, false)
// fn from another interface of the keyboard than F1.
_ = hid(7, 0x00FF_0003, true)
check(hid(8, HIDUsage.f1, true) == nil, "hid: fn on one interface, F1 on another: still fn + F1")
_ = hid(7, 0x00FF_0003, false)
// A Magic Keyboard without the property: Apple's default map.
check(hid(2, HIDUsage.f2, true, HIDBrightness.appleDefault) == .brightnessUp, "hid: Apple keyboard with no map: F2 is brightness up")
// A Bluetooth Magic Keyboard (the Mac mini's: vendor 0x004C, no FnFunctionUsageMap): Apple's default map.
check(HIDBrightness.map(published: nil, vendor: 0x004C) == HIDBrightness.appleDefault
      && HIDBrightness.map(published: nil, vendor: 0x05AC) == HIDBrightness.appleDefault,
      "hid: Apple keyboard without a map, Bluetooth (0x004C) or USB (0x05AC): F1/F2 brightness")
check(HIDBrightness.map(published: nil, vendor: 0x046D).isEmpty && HIDBrightness.map(published: nil, vendor: nil).isEmpty,
      "hid: another vendor's keyboard (Logitech) or no vendor, no map: none")
check(HIDBrightness.map(published: "0x0007003a,0x000c0070", vendor: 0x046D) == [HIDUsage.f1: 0x000C_0070],
      "hid: a published map wins, any vendor")
let bt = HIDBrightness.map(published: nil, vendor: 0x004C)
check(hid(9, HIDUsage.f1, true, bt) == .brightnessDown && hid(9, HIDUsage.f2, true, bt) == .brightnessUp,
      "hid: Bluetooth Magic Keyboard: F1 down, F2 up")
_ = hid(9, 0x00FF_0003, true, bt)
check(hid(9, HIDUsage.f1, true, bt) == nil, "hid: Bluetooth Magic Keyboard: fn + F1 is F1")
check(hid(9, HIDUsage.f1, true, bt, fnState: true) == .brightnessDown, "hid: ... with standard F-keys on: fn + F1 is brightness down")
_ = hid(9, 0x00FF_0003, false, bt)
check(hid(9, HIDUsage.f2, true, bt, fnState: true) == nil, "hid: ... standard F-keys, no fn: F2 is F2")
// A PC keyboard: no map, its own consumer-page brightness keys; its F1 stays F1.
check(hid(3, HIDUsage.f1, true, [:]) == nil, "hid: another keyboard's F1 is F1")
check(hid(3, 0x000C_0070, true, [:]) == .brightnessDown && hid(3, 0x000C_0070, false, [:]) == nil,
      "hid: its brightness key (consumer page) pressed: down; released: nothing")
// One press seen by both paths: the first acts, the copy is dropped.
var once2 = BrightnessOnce()
check(once2.take(.keyboard, .brightnessUp, at: 10) && !once2.take(.tap, .brightnessUp, at: 10.05),
      "hid: keyboard first, the tap's copy 50 ms later: once")
check(once2.take(.tap, .brightnessUp, at: 11) && !once2.take(.keyboard, .brightnessUp, at: 11.02), "hid: tap first: once too")
check(once2.take(.keyboard, .brightnessUp, at: 12) && once2.take(.keyboard, .brightnessUp, at: 12.1) && once2.take(.keyboard, .brightnessUp, at: 12.2),
      "hid: quick presses from the keyboard alone (macOS 27: no tap event): each acts")
check(once2.take(.keyboard, .brightnessUp, at: 13) && once2.take(.tap, .brightnessDown, at: 13.05), "hid: another key: acts")
check(once2.take(.keyboard, .brightnessUp, at: 14) && once2.take(.tap, .brightnessUp, at: 14.5), "hid: the tap 0.5 s later: a new press")
check(BrightnessOnce.macOSDidIt(before: 0.5, after: 0.5625) && !BrightnessOnce.macOSDidIt(before: 0.5, after: 0.5)
      && !BrightnessOnce.macOSDidIt(before: nil, after: 0.6) && !BrightnessOnce.macOSDidIt(before: 0.5, after: nil),
      "hid: macOS stepped it already (1/16): not again; unchanged or unreadable (DDC): the Bridge steps")
// RC11 check finding 1: quick presses lost every other step. Press 2 read "before" while press 1's step was
// still waiting; its check saw press 1's change as macOS's. The Bridge's own steps do not count as macOS's.
var own = OwnSteps()
check(own.macOSDidIt(1, pressAt: 20, before: 0.5, after: 0.5625), "hid: no step of the Bridge's: a change is macOS's (not stepped again)")
own.stepped(1, at: 20.25)   // press 1 (20.0) acts
check(!own.macOSDidIt(1, pressAt: 20.1, before: 0.5, after: 0.5625), "hid: quick press 2 (0.1 s later): press 1's step is not macOS's: it steps")
own.stepped(1, at: 20.35)
check(!own.macOSDidIt(1, pressAt: 20.2, before: 0.5625, after: 0.625) && !own.macOSDidIt(1, pressAt: 20.4, before: 0.625, after: 0.6875),
      "hid: 5 quick presses: each steps")
var held = OwnSteps(); var stepsDone = 0; var level: Float = 0.5
// A held key at 30 ms repeats (KeyRepeat 2): each act 0.25 s after its press, every one steps.
var pending: [(at: Double, before: Float)] = []
for i in 0..<20 {
  let t = 30 + Double(i) * 0.03
  while let p = pending.first, p.at + 0.25 <= t {
    pending.removeFirst()
    if !held.macOSDidIt(1, pressAt: p.at, before: p.before, after: level) { held.stepped(1, at: p.at + 0.25); level += 1 / 16; stepsDone += 1 }
  }
  pending.append((t, level))
}
for p in pending where !held.macOSDidIt(1, pressAt: p.at, before: p.before, after: level) { held.stepped(1, at: p.at + 0.25); level += 1 / 16; stepsDone += 1 }
check(stepsDone == 20, "hid: a held key's 20 repeats: 20 steps (\(stepsDone))")
check(own.macOSDidIt(2, pressAt: 20.2, before: 0.5, after: 0.5625), "hid: another display: its own check (macOS's change counts)")
check(own.macOSDidIt(1, pressAt: 25, before: 0.5, after: 0.5625), "hid: a press 4 s after the last step: the check is back")

// ---- QEMU's control socket ----
check(QMPKeys.socketPath(["-name", "Omarchy", "-qmp", "unix:/Users/a/Library/Caches/OmacVM/run/x.qmp,server=on,wait=off"])
      == "/Users/a/Library/Caches/OmacVM/run/x.qmp", "QMP: the socket from the command line")
check(QMPKeys.socketPath(["-qmp", "unix:/tmp/a,,b.qmp,server=on"]) == "/tmp/a,b.qmp", "QMP: a doubled comma is a comma")
check(QMPKeys.socketPath(["-qmp", "tcp:127.0.0.1:4444"]) == nil && QMPKeys.socketPath(["-qmp"]) == nil && QMPKeys.socketPath([]) == nil,
      "QMP: no Unix socket, nothing")
check(QMPKeys.socketPath(["-qmp", "unix:/" + String(repeating: "x", count: 200)]) == nil, "QMP: too long for a socket address")
check(QMPKeys.commands("volumeup").count == 3 && QMPKeys.commands("volumeup")[1].contains(#""down":true"#)
      && QMPKeys.commands("volumeup")[2].contains(#""down":false"#), "QMP: capabilities, down, up")
check(QMPKeys.kind(#"{"QMP": {"version": {}}}"#) == "greeting" && QMPKeys.kind(#"{"return": {}}"#) == "ok"
      && QMPKeys.kind(#"{"error": {"class": "x"}}"#) == "error" && QMPKeys.kind(#"{"event": "RESUME"}"#) == nil
      && QMPKeys.kind("garbage") == nil, "QMP: replies told apart (events skipped)")
func procargs(_ args: [String], exe: String = "/x/OmacVM") -> [UInt8] {
  var b: [UInt8] = [UInt8(args.count), 0, 0, 0] + Array(exe.utf8) + [0, 0, 0]
  for a in args { b += Array(a.utf8) + [0] }
  return b + Array("HOME=/Users/a".utf8) + [0]
}
check(ProcArgs.parse(procargs(["OmacVM", "-qmp", "unix:/s"])) == ["OmacVM", "-qmp", "unix:/s"], "procargs: argv, no environment")
check(ProcArgs.parse([]) == nil && ProcArgs.parse([2, 0, 0, 0, 65, 0, 66]) == nil && ProcArgs.parse([0, 0, 0, 0]) == nil,
      "procargs: short, cut off or empty: nothing")

if failed > 0 { print("\(failed) failed"); exit(1) }
print("models: all ok")
