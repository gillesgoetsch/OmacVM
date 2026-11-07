// The features a new OmacVM.app VM starts with (OmacVMFeatures), the
// hidden keyboard sharing switch (ShareKeyboardTests.swift) and whether this
// Mac is set up for a VM (MacSetupTests.swift), without a VM:
//   cd app/app && swift run features-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMFeatures

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
func parse(_ s: String) -> [String: String] {
    Dictionary(uniqueKeysWithValues: s.split(separator: " ").map { kv in
        let p = kv.split(separator: "=", maxSplits: 1)
        return (String(p[0]), p.count > 1 ? String(p[1]) : "")
    })
}

// Omanotch: on with a notch, off without one (a Mac mini, an M1 Air).
let notch = parse(NewVMFeatures.string(hasBattery: true, hasNotch: true))
let noNotch = parse(NewVMFeatures.string(hasBattery: false, hasNotch: false))
expect(notch["omanotch"] == "on", "a Mac with a notch: omanotch=on")
expect(noNotch["omanotch"] == "off", "a Mac without a notch: omanotch=off")
expect(notch["battery"] == "on" && noNotch["battery"] == "off", "battery follows the Mac")

// Nothing else changes with the notch.
var a = notch, b = parse(NewVMFeatures.string(hasBattery: true, hasNotch: false))
a["omanotch"] = nil; b["omanotch"] = nil
expect(a == b, "the notch changes only omanotch")

// The same string as before 3.0.0 apart from omanotch (vm.env, apply), and
// idle-lock=on now no-idle-lock=off (3.0.1: the same screensaver and lock).
expect(NewVMFeatures.string(hasBattery: false, hasNotch: false)
       == "bridge=on wallpaper=on gestures=on scroll-momentum=on omanotch=off mac-clock=on camera=on battery=off external-brightness=on chromium-video=on no-idle-lock=off autologin=off thp-kernel=off",
       "the rest as before")
expect(noNotch["no-idle-lock"] == "off" && noNotch["idle-lock"] == nil,
       "Omarchy's screensaver and lock as it comes, under the new name only")

// The setup screen's switches.
let off = parse(NewVMFeatures.string(bridge: false, gestures: false, autologin: true, hasBattery: true, hasNotch: true))
expect(off["bridge"] == "off" && off["wallpaper"] == "off" && off["external-brightness"] == "off", "Bridge off: wallpaper and brightness off too")
expect(off["gestures"] == "off" && off["scroll-momentum"] == "off", "Gestures off: scroll momentum off too")
expect(off["autologin"] == "on" && off["omanotch"] == "on", "autologin on; omanotch still follows the notch")

// Every key is a feature `omacvm apply` knows (src/features.tsv).
let tsv = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../src/features.tsv").standardizedFileURL
if let text = try? String(contentsOf: tsv, encoding: .utf8) {
    let known = Set(text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        .compactMap { $0.split(separator: "\t").first.map(String.init) })
    let unknown = notch.keys.filter { !known.contains($0) }.sorted()
    expect(unknown.isEmpty, "every key is in src/features.tsv\(unknown.isEmpty ? "" : ": not \(unknown)")")
} else {
    expect(false, "src/features.tsv readable at \(tsv.path)")
}

// The Mac's input methods (mac-ime): off unless the record says on; a new VM
// never starts with it; its port is the one QEMU's window code serves.
expect(!MacIME.isOn(features: nil) && !MacIME.isOn(features: "") &&
       !MacIME.isOn(features: "bridge=on mac-ime=off") && !MacIME.isOn(features: "mac-ime=onn") &&
       !MacIME.isOn(features: "xmac-ime=on"), "mac-ime: off without the record's mac-ime=on")
expect(MacIME.isOn(features: "bridge=on mac-ime=on vulkan=off\n") && MacIME.isOn(features: "mac-ime=on"),
       "mac-ime: on with the record's mac-ime=on")
expect(MacIME.isOn(features: "mac-ime=on mac-ime=off") == false, "mac-ime: the last word counts")
expect(notch["mac-ime"] == nil && noNotch["mac-ime"] == nil, "a new VM starts without mac-ime (off by default)")
let imeArgs = MacIME.arguments(socket: "/tmp/x.ime")
expect(imeArgs == ["-chardev", "socket,id=ime0,path=/tmp/x.ime,server=on,wait=off",
                   "-device", "virtserialport,bus=vser0.0,nr=8,chardev=ime0,name=org.omacvm.ime"],
       "mac-ime: port nr 8 on vser0, after Touch ID's 7")
if let text = try? String(contentsOf: tsv, encoding: .utf8),
   let row = text.split(separator: "\n").first(where: { $0.hasPrefix("mac-ime\t") }) {
    let f = row.split(separator: "\t", omittingEmptySubsequences: false)
    expect(f.count >= 4 && f[1] == "off" && f[2] == "vm" && f[3] == "experimental,app-only",
           "mac-ime in src/features.tsv: off, vm, experimental, app-only")
} else {
    expect(false, "mac-ime in src/features.tsv")
}

// #316: the row switches while the VM is stopped: the record and a pending
// file for the next start, which runs apply for the VM's part.
let rec = "bridge=on mac-ime=off vulkan=off\n"
let s1 = MacIME.switchStopped(record: rec, pending: nil, on: true)
expect(s1.record == "bridge=on mac-ime=on vulkan=off\n" && s1.pending == "on\n", "stopped, on: record mac-ime=on, pending on")
expect(MacIME.isOn(features: s1.record), "stopped, on: the next start reads on (its port)")
let s2 = MacIME.switchStopped(record: s1.record, pending: s1.pending, on: false)
expect(s2.record == rec && s2.pending == nil, "stopped, on then off: back to the record, nothing pending")
let s3 = MacIME.switchStopped(record: "bridge=on\n", pending: nil, on: true)
expect(s3.record == "bridge=on mac-ime=on\n" && s3.pending == "on\n", "stopped, a record without mac-ime: added")
let s4 = MacIME.switchStopped(record: nil, pending: nil, on: false)
expect(s4.record == "mac-ime=off\n" && s4.pending == "off\n", "stopped, no record: one with mac-ime")
expect(MacIME.pending(nil) == nil && MacIME.pending("") == nil && MacIME.pending("onn") == nil &&
       MacIME.pending("on\n") == true && MacIME.pending("off") == false, "pending: on, off or none")
expect(MacIME.applyArguments(vm: "My VM", on: true) ==
       ["apply", "--vm", "My VM", "--vm-type", "app", "--feature", "mac-ime=on", "--yes", "--transaction"],
       "start: apply switches only mac-ime for the VM")
let stopped = MacIME.row(record: "mac-ime=off", pending: nil, running: false, busy: false, cli: true)
expect(stopped == MacIME.Row(on: false, enabled: true, note: nil), "row stopped: switchable (was greyed out, #316)")
expect(MacIME.row(record: "mac-ime=on", pending: "on", running: false, busy: false, cli: false) ==
       MacIME.Row(on: true, enabled: true, note: nil), "row stopped, pending: on, no note (the window is for the next start)")
expect(MacIME.row(record: "mac-ime=off", pending: "off", running: false, busy: false, cli: true).on == false,
       "row stopped, pending off: off")
expect(MacIME.row(record: "mac-ime=on", pending: nil, running: true, busy: false, cli: true) ==
       MacIME.Row(on: true, enabled: true, note: nil), "row running: switchable through omacvm, as before")
expect(!MacIME.row(record: nil, pending: nil, running: true, busy: false, cli: false).enabled, "row running: needs the app's omacvm")
expect(!MacIME.row(record: nil, pending: nil, running: false, busy: true, cli: true).enabled, "row busy: not switchable")

// FullPanel (#339): the VM folder's notch-mode file and what a start does.
expect(NotchArea.mode(nil) == .native && NotchArea.mode("") == .native && NotchArea.mode("native\n") == .native,
       "notch-mode: none or native is native")
expect(NotchArea.mode("fullpanel\n") == .fullpanel && NotchArea.mode(" fullpanel ") == .fullpanel,
       "notch-mode: fullpanel")
expect(NotchArea.mode("FullPanel") == .native && NotchArea.mode("on") == .native, "notch-mode: anything else is native")
let fpDir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-\(getpid())")
try? FileManager.default.createDirectory(at: fpDir, withIntermediateDirectories: true)
try? NotchArea.write(.fullpanel, folder: fpDir)
expect(NotchArea.read(folder: fpDir) == .fullpanel, "write fullpanel, read fullpanel")
try? NotchArea.write(.native, folder: fpDir)
expect(NotchArea.read(folder: fpDir) == .native &&
       !FileManager.default.fileExists(atPath: fpDir.appendingPathComponent(NotchArea.fileName).path),
       "native removes the file")
try? FileManager.default.removeItem(at: fpDir)
// Made-up notches with the sizes macOS reports (points): Air 13", Pro 16".
let air = NotchGeometry(left: 640.5, right: 829.5, strip: 37, width: 1470, height: 956)
let pro16 = NotchGeometry(left: 765, right: 963, strip: 43, width: 1728, height: 1117)
expect(air.valid && pro16.valid, "notch geometry: an Air and a 16-inch Pro are valid")
expect(!NotchGeometry(left: 0, right: 100, strip: 37, width: 1470, height: 956).valid, "geometry: housing at the edge: invalid")
expect(!NotchGeometry(left: 700, right: 600, strip: 37, width: 1470, height: 956).valid, "geometry: right before left: invalid")
expect(!NotchGeometry(left: 100, right: 1400, strip: 37, width: 1470, height: 956).valid, "geometry: housing a third of the width: invalid")
expect(!NotchGeometry(left: 640, right: 830, strip: 4, width: 1470, height: 956).valid, "geometry: no strip: invalid")
expect(!NotchGeometry(left: 640, right: 830, strip: .nan, width: 1470, height: 956).valid, "geometry: NaN: invalid")
expect(NotchGeometry.strip(menuBar: 37, safeTop: 32) == 37, "strip: the menu bar's height")
expect(NotchGeometry.strip(menuBar: 0, safeTop: 32) == 33.5, "strip: menu bar hidden: the housing and a little")
expect(air.smbios == "omacvm.fullpanel=640.5x829.5x37.0x1470.0x956.0", "SMBIOS string: digits, dots and x only")
let allowed = Set("0123456789.x")
expect(pro16.smbios.split(separator: "=")[1].allSatisfy { allowed.contains($0) }, "SMBIOS value passes omacvm-app-host's filter")
let fp = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: .now(air), guestReady: true)
expect(fp.fullPanel && fp.record.hasPrefix("fullpanel (Omanotch off") && fp.geometry == air,
       "start: FullPanel, full screen, notch: FullPanel with that notch")
expect(NotchArea.start(mode: .native, fullScreen: true, notch: .now(air), guestReady: true) == NotchStart(fullPanel: false, record: "native"),
       "start: native: native")
let windowed = NotchArea.start(mode: .fullpanel, fullScreen: false, notch: .now(air), guestReady: true)
expect(!windowed.fullPanel && windowed.record.hasPrefix("native (") && windowed.record.contains("in a window") && windowed.geometry == nil,
       "start: FullPanel windowed: native, says why")
let fpNoNotch = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: .none, guestReady: true)
expect(!fpNoNotch.fullPanel && fpNoNotch.record.contains("no notch") && fpNoNotch.geometry == nil,
       "start: FullPanel without a notch (none now, nothing remembered): native")
let bad = NotchArea.start(mode: .fullpanel, fullScreen: true,
                          notch: .now(NotchGeometry(left: 640, right: 830, strip: 4, width: 1470, height: 956)), guestReady: true)
expect(!bad.fullPanel, "start: FullPanel with odd numbers: native")
// #716: the lid closed (the built-in display off), the notch remembered for this Mac: FullPanel with it.
let lidClosed = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: .remembered(pro16), guestReady: true)
expect(lidClosed.fullPanel && lidClosed.record.hasPrefix("fullpanel (Omanotch off for this start; the built-in display is off") &&
       lidClosed.geometry == pro16 && lidClosed.record.contains("notch 765.0-963.0, strip 43.0 of 1728x1117 points"),
       "start: FullPanel, the lid closed, the notch remembered: FullPanel with it (#716)")
expect(!NotchArea.start(mode: .fullpanel, fullScreen: true, notch: .remembered(NotchGeometry(left: 640, right: 830, strip: 4, width: 1470, height: 956)),
                        guestReady: true).fullPanel, "start: a remembered notch with odd numbers: native")
expect(!NotchArea.start(mode: .native, fullScreen: true, notch: .remembered(pro16), guestReady: true).fullPanel &&
       !NotchArea.start(mode: .fullpanel, fullScreen: false, notch: .remembered(pro16), guestReady: true).fullPanel &&
       !NotchArea.start(mode: .fullpanel, fullScreen: true, notch: .remembered(pro16), guestReady: false).fullPanel,
       "start: remembered, but native, windowed or the VM not ready: native")
// Which notch a start may use (Mac.notch): the live one; the remembered one only with the built-in display off.
expect(MacNotch.of(live: air, builtinOff: false, remembered: pro16) == .now(air), "Mac notch: measured now wins")
expect(MacNotch.of(live: nil, builtinOff: true, remembered: pro16) == .remembered(pro16), "Mac notch: lid closed: remembered")
expect(MacNotch.of(live: nil, builtinOff: false, remembered: pro16) == .none,
       "Mac notch: built-in on below the notch or mirrored: none, the remembered notch not used")
expect(MacNotch.of(live: nil, builtinOff: true, remembered: nil) == .none, "Mac notch: lid closed, nothing remembered: none")
expect(MacNotch.of(live: NotchGeometry(left: 640, right: 830, strip: 4, width: 1470, height: 956), builtinOff: true, remembered: pro16) == .remembered(pro16),
       "Mac notch: odd live numbers are none")
expect(MacNotch.now(air).word == "notch" && MacNotch.remembered(air).word == "remembered" && MacNotch.none.word == "none",
       "Mac notch: the command line's words")
expect(air.panel == "1470.0x956.0" && pro16.text == "765.0x963.0x43.0x1728.0x1117.0", "notch: panel and text")
// The remembered notch: this Mac's only (a hash of its hardware UUID), one a MacBook can have.
let macA = NotchHousing.macKey(hardwareID: "00000000-0000-0000-0000-000000000716")
let macB = NotchHousing.macKey(hardwareID: "00000000-0000-0000-0000-000000000717")
expect(macA.count == 16 && macA.allSatisfy { "0123456789abcdef".contains($0) } && macA != macB && !macA.contains("0716"),
       "remembered: the Mac's key is 16 hex digits of a hash, not the UUID")
expect(NotchHousing.remembered(NotchHousing.entry(pro16, mac: macA), mac: macA) == pro16, "remembered: written and read back")
expect(NotchHousing.remembered(NotchHousing.entry(pro16, mac: macA), mac: macB) == nil, "remembered: another Mac's: none")
expect(NotchHousing.remembered(nil, mac: macA) == nil && NotchHousing.remembered("", mac: macA) == nil &&
       NotchHousing.remembered(macA, mac: macA) == nil && NotchHousing.remembered("\(macA) 765x963x43x1728", mac: macA) == nil &&
       NotchHousing.remembered("\(macA)  765x963x43x1728x1117", mac: macA) == nil &&
       NotchHousing.remembered("\(macA) 765x963x43x1728x1117 x", mac: macA) == nil &&
       NotchHousing.remembered("\(macA) 765x963x4x1728x1117", mac: macA) == nil &&
       NotchHousing.remembered(" 765x963x43x1728x1117", mac: "") == nil,
       "remembered: malformed, impossible or no key: none")
let notReady = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: .now(air), guestReady: false)
expect(!notReady.fullPanel && notReady.record.contains("not ready"), "start: FullPanel, VM not ready (older VM or Omanotch off): native")
let readyDir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ready-\(getpid())")
try? FileManager.default.createDirectory(at: readyDir, withIntermediateDirectories: true)
expect(!NotchArea.guestReady(folder: readyDir, features: "omanotch=on"), "ready: no file: not ready")
FileManager.default.createFile(atPath: readyDir.appendingPathComponent(NotchArea.readyFileName).path, contents: Data())
expect(NotchArea.guestReady(folder: readyDir, features: "bridge=on omanotch=on") && NotchArea.guestReady(folder: readyDir, features: nil),
       "ready: file and Omanotch on (or not named): ready")
expect(!NotchArea.guestReady(folder: readyDir, features: "bridge=on omanotch=off\n"), "ready: Omanotch off: not ready")
try? FileManager.default.removeItem(at: readyDir)
expect(NotchArea.geometry(text: "640.5x829.5x37x1470x956") == NotchGeometry(left: 640.5, right: 829.5, strip: 37, width: 1470, height: 956),
       "geometry text: parsed")
expect(NotchArea.geometry(text: nil) == nil && NotchArea.geometry(text: "1") == nil &&
       NotchArea.geometry(text: "640x830x4x1470x956") == nil && NotchArea.geometry(text: "axbxcxdxe") == nil &&
       NotchArea.geometry(text: "640.5x829.5xx37x1470x956") == nil,
       "geometry text: malformed or impossible: none")
expect(NotchArea.geometry(text: air.text) == air, "geometry text: the text reads back")
// "Start in": one picker onto startFullScreen + the VM's notch-mode.
expect(StartIn.choices(hasNotch: true) == [.window, .fullScreen, .fullScreenNotch], "Start in: three choices with a notch")
expect(StartIn.choices(hasNotch: false) == [.window, .fullScreen], "Start in: no notch, no including-notch choice")
expect(StartIn.fullScreen.title(hasNotch: true) == "Full screen, notch via Omanotch" &&
       StartIn.fullScreen.title(hasNotch: false) == "Full screen" &&
       StartIn.fullScreenNotch.title(hasNotch: true) == "Full screen including notch, no Omanotch needed (experimental)" &&
       StartIn.window.title(hasNotch: true) == "Window", "Start in: the titles")
expect(StartIn.current(fullScreen: false, mode: .fullpanel, hasNotch: true) == .window &&
       StartIn.current(fullScreen: false, mode: .native, hasNotch: false) == .window, "Start in: window whatever the notch")
expect(StartIn.current(fullScreen: true, mode: .native, hasNotch: true) == .fullScreen, "Start in: full screen + native")
expect(StartIn.current(fullScreen: true, mode: .fullpanel, hasNotch: true) == .fullScreenNotch, "Start in: full screen + fullpanel")
expect(StartIn.current(fullScreen: true, mode: .fullpanel, hasNotch: false) == .fullScreen,
       "Start in: fullpanel on a Mac without a notch shows Full screen")
expect(!StartIn.window.fullScreen && StartIn.window.mode == nil, "Start in: Window = startFullScreen off, notch-mode kept")
expect(StartIn.fullScreen.fullScreen && StartIn.fullScreen.mode == .native, "Start in: Full screen = on + native")
expect(StartIn.fullScreenNotch.fullScreen && StartIn.fullScreenNotch.mode == .fullpanel, "Start in: including notch = on + fullpanel")
expect(StartIn.allCases.map(\.caption) == ["Window", "Full screen", "Full screen including notch"] &&
       StartIn.fullScreen.detail(hasNotch: true) == "Notch via Omanotch" && StartIn.fullScreen.detail(hasNotch: false) == nil &&
       StartIn.fullScreenNotch.detail(hasNotch: true) == "Experimental" && StartIn.window.detail(hasNotch: true) == nil &&
       StartIn.notchNote.contains("No Omanotch needed") && StartIn.notchNote.contains("Experimental"),
       "Start in: the pictures' names and lines, the rest in the note")
for c in StartIn.allCases {
    let m = c.mode ?? .fullpanel
    expect(StartIn.current(fullScreen: c.fullScreen, mode: m, hasNotch: true) == c, "Start in: \(c) round trip")
}

// Skip the notch (NotchSkip): its file, the SMBIOS string, the command for a
// running VM, and when that VM is told again (NotchSkipLive).
let skipDir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-skip-\(getpid())")
try? FileManager.default.createDirectory(at: skipDir, withIntermediateDirectories: true)
expect(!NotchSkip.read(folder: skipDir), "skip: no file: off (the default)")
expect(NotchSkip.on("on\n") && !NotchSkip.on("On") && !NotchSkip.on("1") && !NotchSkip.on(nil), "skip: only \"on\" is on")
try? NotchSkip.write(true, folder: skipDir)
expect(NotchSkip.read(folder: skipDir) &&
       (try? String(contentsOf: skipDir.appendingPathComponent("notch-skip"), encoding: .utf8)) == "on\n",
       "skip: on writes notch-skip, as omacvm notch --skip does")
try? NotchSkip.write(false, folder: skipDir)
expect(!FileManager.default.fileExists(atPath: skipDir.appendingPathComponent("notch-skip").path), "skip: off removes the file")
expect((try? NotchSkip.write(false, folder: skipDir)) != nil, "skip: off twice is fine")
expect(!NotchSkip.guestReady(folder: skipDir, features: nil), "skip: not ready without apply's marker")
FileManager.default.createFile(atPath: skipDir.appendingPathComponent(NotchSkip.readyFileName).path, contents: Data())
expect(NotchSkip.guestReady(folder: skipDir, features: "omanotch=on") && !NotchSkip.guestReady(folder: skipDir, features: "omanotch=off"),
       "skip: ready with the marker and Omanotch on")
try? FileManager.default.removeItem(at: skipDir)
let smbiosValue = NotchSkip.smbios.split(separator: "=")
expect(smbiosValue.count == 2 && smbiosValue[0] == "omacvm.notchskip" && smbiosValue[1] == "1",
       "skip: SMBIOS omacvm.notchskip=1 (omacvm-app-host: OMACVM_NOTCHSKIP=1)")
let cmdOn = NotchSkip.guestCommand(true), cmdOff = NotchSkip.guestCommand(false)
expect(cmdOn.path == "/bin/sh" && cmdOn.args.count == 2 && cmdOn.args[1].contains("printf 1 > /run/omacvm/notch-skip.new") &&
       cmdOff.args[1].contains("printf 0 > ") && cmdOn.args[1].hasSuffix("mv -f /run/omacvm/notch-skip.new /run/omacvm/notch-skip"),
       "skip: the running VM gets 1 or 0 in /run/omacvm/notch-skip, in one step")
let t0 = Date(timeIntervalSince1970: 1_000_000)
var live = NotchSkipLive(atStart: false)
expect(!live.due(false, at: t0), "skip live: unchanged since the start: nothing to tell")
expect(live.due(true, at: t0), "skip live: switched on: tell the VM")
live.sent(true, at: t0)
expect(!live.due(true, at: t0.addingTimeInterval(2)), "skip live: told: not again at once")
expect(live.due(true, at: t0.addingTimeInterval(NotchSkipLive.again)), "skip live: told again now and then while it differs from the start")
expect(live.due(false, at: t0.addingTimeInterval(4)), "skip live: switched back: tell the VM")
live.sent(false, at: t0.addingTimeInterval(4))
expect(!live.due(false, at: t0.addingTimeInterval(400)), "skip live: back to the start's value: no more repeats")
var liveOn = NotchSkipLive(atStart: true)
expect(!liveOn.due(true, at: t0) && liveOn.due(false, at: t0), "skip live: on at the start, switched off: tell the VM")
liveOn.sent(false, at: t0)
expect(liveOn.due(false, at: t0.addingTimeInterval(31)) && !liveOn.due(false, at: t0.addingTimeInterval(29)),
       "skip live: off while the start said on: again after 30 s (a reboot inside the VM)")

// The menu bar in full screen (#356): macOS's global preference.
if let d = UserDefaults(suiteName: "org.omacvm.test.features-menubar.\(getpid())") {
    // (Not set, the Mac's own global setting counts: not checked here.)
    d.set(false, forKey: "AppleMenuBarVisibleInFullscreen")
    expect(!NotchArea.menuBarAlwaysShown(d), "menu bar: hidden in full screen when macOS is set so")
    d.set(true, forKey: "AppleMenuBarVisibleInFullscreen")
    expect(NotchArea.menuBarAlwaysShown(d), "menu bar: always shown when macOS is set so")
    d.removePersistentDomain(forName: "org.omacvm.test.features-menubar.\(getpid())")
}

shareKeyboardTests()
macSetupTests()

// WebGPU and GPU compute (gpu-compute): on by default, also for a record without the word.
expect(GPUCompute.isOn(features: nil) && GPUCompute.isOn(features: "bridge=on vulkan=off\n"), "gpu-compute: on without the word")
expect(!GPUCompute.isOn(features: "bridge=on gpu-compute=off vulkan=off") && GPUCompute.isOn(features: "gpu-compute=on"),
       "gpu-compute: the record's word")
expect(GPUCompute.isOn(features: "gpu-compute=off gpu-compute=on") && GPUCompute.isOn(features: "xgpu-compute=off"),
       "gpu-compute: the last word counts, only its own")
let gcStopped = GPUCompute.row(record: "gpu-compute=on", pending: nil, running: false, vulkan: true, busy: false, cli: true)
expect(gcStopped == GPUCompute.Row(on: true, enabled: true, note: nil), "gpu-compute row: stopped VM: switched for the next start")
let gcOn = GPUCompute.row(record: nil, pending: nil, running: true, vulkan: true, busy: false, cli: true)
expect(gcOn == GPUCompute.Row(on: true, enabled: true, note: nil), "gpu-compute row: running with Vulkan: on, switchable")
let gcGL = GPUCompute.row(record: "gpu-compute=off", pending: nil, running: true, vulkan: false, busy: false, cli: true)
expect(!gcGL.on && gcGL.enabled && gcGL.note?.contains("OpenGL") == true, "gpu-compute row: OpenGL says it needs Vulkan")
expect(!GPUCompute.row(record: nil, pending: nil, running: true, vulkan: true, busy: true, cli: true).enabled &&
       !GPUCompute.row(record: nil, pending: nil, running: true, vulkan: true, busy: false, cli: false).enabled, "gpu-compute row: busy or no CLI: not switchable")
// Switched while stopped (the window hides while a VM it started runs): record + pending, set up at the next start.
let gs1 = GPUCompute.switchState.switchStopped(record: "bridge=on vulkan=off\n", pending: nil, on: false)
expect(!GPUCompute.isOn(features: gs1.record) && gs1.pending == "off\n", "gpu-compute stopped, off: the record says off, pending off")
let gs2 = GPUCompute.switchState.switchStopped(record: gs1.record, pending: gs1.pending, on: true)
expect(GPUCompute.isOn(features: gs2.record) && gs2.pending == nil, "gpu-compute switched back before a start: no pending left")
expect(GPUCompute.row(record: gs1.record, pending: gs1.pending, running: true, vulkan: true, busy: false, cli: true).note == "Being set up in the VM for this start.",
       "gpu-compute row: a pending choice while the start sets it up")
expect(GPUCompute.pendingFile == "gpu-compute-pending" && MacIME.pendingFile == "mac-ime-pending", "pending files keep their names")
expect(GPUCompute.switchState.applyArguments(vm: "V", on: false) == ["apply", "--vm", "V", "--vm-type", "app", "--feature", "gpu-compute=off", "--yes", "--transaction"],
       "gpu-compute at the start: apply's switch of it alone")
let gdir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-\(getpid())")
try? FileManager.default.createDirectory(at: gdir, withIntermediateDirectories: true)
try? "bridge=on gpu-compute=on\n".write(to: gdir.appendingPathComponent("features"), atomically: true, encoding: .utf8)
try? "off\n".write(to: gdir.appendingPathComponent(GPUCompute.pendingFile), atomically: true, encoding: .utf8)
expect(GPUCompute.switchState.prepareStart(folder: gdir) == false &&
       !GPUCompute.isOn(features: try? String(contentsOf: gdir.appendingPathComponent("features"), encoding: .utf8)),
       "gpu-compute prepareStart: the pending off, the record follows")
try? FileManager.default.removeItem(at: gdir)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
