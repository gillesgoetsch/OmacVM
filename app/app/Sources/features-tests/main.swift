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

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
