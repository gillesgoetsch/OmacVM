// The features a new OmacVM.app VM starts with (OmacVMFeatures), without a VM:
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
       MacIME.Row(on: true, enabled: true, note: "From the next start."), "row stopped, pending: on, from the next start")
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
let fp = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: air, guestReady: true)
expect(fp.fullPanel && fp.record.hasPrefix("fullpanel (Omanotch off"), "start: FullPanel, full screen, notch: FullPanel")
expect(NotchArea.start(mode: .native, fullScreen: true, notch: air, guestReady: true) == NotchStart(fullPanel: false, record: "native"),
       "start: native: native")
let windowed = NotchArea.start(mode: .fullpanel, fullScreen: false, notch: air, guestReady: true)
expect(!windowed.fullPanel && windowed.record.hasPrefix("native (") && windowed.record.contains("full screen"),
       "start: FullPanel windowed: native, says why")
let fpNoNotch = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: nil, guestReady: true)
expect(!fpNoNotch.fullPanel && fpNoNotch.record.contains("no notch"), "start: FullPanel on a Mac without a notch (lid closed): native")
let bad = NotchArea.start(mode: .fullpanel, fullScreen: true,
                          notch: NotchGeometry(left: 640, right: 830, strip: 4, width: 1470, height: 956), guestReady: true)
expect(!bad.fullPanel, "start: FullPanel with odd numbers: native")
let notReady = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: air, guestReady: false)
expect(!notReady.fullPanel && notReady.record.contains("not ready"), "start: FullPanel, VM not ready (older VM or Omanotch off): native")
let readyDir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ready-\(getpid())")
try? FileManager.default.createDirectory(at: readyDir, withIntermediateDirectories: true)
expect(!NotchArea.guestReady(folder: readyDir, features: "omanotch=on"), "ready: no file: not ready")
FileManager.default.createFile(atPath: readyDir.appendingPathComponent(NotchArea.readyFileName).path, contents: Data())
expect(NotchArea.guestReady(folder: readyDir, features: "bridge=on omanotch=on") && NotchArea.guestReady(folder: readyDir, features: nil),
       "ready: file and Omanotch on (or not named): ready")
expect(!NotchArea.guestReady(folder: readyDir, features: "bridge=on omanotch=off\n"), "ready: Omanotch off: not ready")
try? FileManager.default.removeItem(at: readyDir)
expect(NotchArea.disabledReason(fullScreen: true) == nil && NotchArea.disabledReason(fullScreen: false) != nil,
       "the switch: disabled only while Start in full screen is off")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
