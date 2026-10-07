// Touch ID's panel (OmacVMTouchIDPanel) without a window on screen, an
// LAContext or a finger: the theme, the glyph, the words that fit, the keys,
// how an evaluation ends, where it goes, and the panel drawn off screen.
//   cd app/app && swift run touchid-panel-tests [<png dir>]
// Exit 0 when all pass. CI runs it on every pull request.
import AppKit
import Foundation
import OmacVMAuth
@testable import OmacVMTouchIDPanel

// The bundled font from the source tree (the app has it in Contents/Resources/fonts).
let fontDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../fonts").standardized
for f in ["JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf"] {
    CTFontManagerRegisterFontsForURL(fontDir.appendingPathComponent(f) as CFURL, .process, nil)
}

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// MARK: Theme

let t = PanelTheme(["background": "#eff1f5", "foreground": "#4c4f69", "accent": "#1e66f5", "success": "#40a02b"])
expect(t.background == PanelRGB(hex: "#eff1f5") && t.accent == PanelRGB(hex: "#1e66f5") && t.success == PanelRGB(hex: "#40a02b"), "theme: the colours sent")
expect(t.error == t.foreground, "theme: no error colour -> the text colour")
expect(t.muted == t.background.mix(t.foreground, 0.28), "theme: no muted colour -> a mix of background and text")
expect(!t.dark && PanelTheme.tokyoNight.dark, "theme: light or dark from the background")
expect(PanelTheme(["foreground": "#ffffff", "accent": "#ff0000"]) == .tokyoNight, "theme: text without its background -> Tokyo Night")
expect(PanelTheme(["background": "#000", "foreground": "#ffffff"]) == .tokyoNight, "theme: a bad colour -> Tokyo Night")
let tn = PanelTheme.tokyoNight
expect(abs(tn.faint.r - PanelRGB(hex: "#3b4261")!.r) < 0.03, "theme: faint ridges close to the design's #3b4261")

// MARK: Glyph

for (i, d) in PanelGlyph.ridges.enumerated() {
    let p = PanelGlyph.path(d)
    let b = p?.boundingBoxOfPath ?? .null
    expect(p != nil && PanelGlyph.viewBox.insetBy(dx: -1, dy: -1).contains(b), "glyph: ridge \(i) parses inside the viewBox")
}
expect(PanelGlyph.ridges.count == 5, "glyph: five strokes")
expect(PanelGlyph.path(PanelGlyph.check) != nil, "glyph: the check parses")
expect(PanelGlyph.path("M1 2 Q3 4 5 6") == nil && PanelGlyph.path("C1 2 3 4 5 6") == nil && PanelGlyph.path("M1") == nil,
       "glyph: unknown commands, a curve without a start, missing numbers: none")
let core = PanelGlyph.path(PanelGlyph.ridges[0])!.boundingBoxOfPath, outer = PanelGlyph.path(PanelGlyph.ridges[4])!.boundingBoxOfPath
expect(core.width * core.height < outer.width * outer.height && outer.minY < core.minY, "glyph: ridges from the core outwards")
var tr = PanelGlyph.transform(into: CGSize(width: 64, height: 70))
let fitted = PanelGlyph.path(PanelGlyph.ridges[3])!.copy(using: &tr)!.boundingBoxOfPath
expect(CGRect(x: 0, y: 0, width: 64, height: 70).insetBy(dx: -0.5, dy: -0.5).contains(fitted) && fitted.midY > 35, "glyph: fits its 64x70 slot, upright (top ridges up)")

// MARK: Words

let fits = { (s: String) in s.count <= 20 }
expect(panelFit("pacman -Syu", fits: fits) == "pacman -Syu", "words: a short command whole")
let long = "rm -rf /home/vincent/.cache/something-long; reboot"
let cut = panelFit(long, fits: fits)
expect(cut.count <= 20 && cut.contains("…") && cut.hasPrefix("rm -rf") && cut.hasSuffix("reboot"), "words: a long one keeps its start and its end (\(cut))")

expect(panelShowsWhole(nil, fits: fits) && panelShowsWhole("pacman -Syu", fits: fits), "words: no box, or one that fits -> the panel")
expect(!panelShowsWhole(long, fits: fits), "words: a box that would be cut -> no panel (macOS's dialog shows it whole)")
let longest = "pacman -Syu --needed --noconfirm --hookdir /home/vincent/.cache/x --overwrite '*' linux linux-headers base-devel"
expect(PanelView.boxFits("pacman -Syu") && !PanelView.boxFits(longest), "words: the real box takes a short command, not \(longest.count) characters")

// MARK: Keys

expect(panelKey(keyCode: 53, command: false, marker: 0) == .cancel, "keys: Esc cancels")
expect(panelKey(keyCode: 47, command: true, marker: 0) == .cancel, "keys: Cmd-. cancels")
expect(panelKey(keyCode: 36, command: false, marker: 0) == .ignore, "keys: Return does nothing")
expect(panelKey(keyCode: 53, command: false, marker: panelKeyMarker) == .ignore, "keys: a marked Esc (OmacVM's helpers) does nothing")

// MARK: Ends

expect(panelEnd(.yes, after: 3) == (.yes, .done), "end: a finger -> yes, done")
expect(panelEnd(.cancelled, after: 1) == (.no("cancelled"), nil), "end: cancel -> no cancelled, closes at once")
expect(panelEnd(.failed, after: 4) == (.no("failed"), .refused), "end: not recognised -> no failed, refused")
expect(panelEnd(.lockout, after: 4) == (.no("lockout"), .refused), "end: lockout -> no lockout")
expect(panelEnd(.other, after: 0.1) == (.error, nil), "end: an error at once -> error (the Mac's own dialog instead)")
expect(panelEnd(.other, after: 2) == (.no("failed"), .refused), "end: an error later -> no failed (never asked twice)")
var once = PanelOnce()
expect(once.finish(.no("timeout")) && !once.finish(.yes) && once.result == .no("timeout"), "end: the first end wins")

// MARK: Place

let vis = CGRect(x: 0, y: 0, width: 1512, height: 944)
expect(panelFrame(window: CGRect(x: 100, y: 100, width: 1000, height: 700), visible: vis, size: CGSize(width: 280, height: 280))
       == CGRect(x: 460, y: 310, width: 280, height: 280), "place: centred on the VM's window")
expect(panelFrame(window: CGRect(x: -900, y: 0, width: 1000, height: 300), visible: vis, size: CGSize(width: 280, height: 280)).minX == 0,
       "place: kept on the screen")

// MARK: Drawn off screen (never on screen)

let prompt = TouchIDPanelPrompt(title: "Touch ID in Omarchy", line: "sudo in pts/1 wants to run", box: "pacman -Syu", timeout: 30, colors: [:])
let v = PanelView(prompt: prompt, theme: .tokyoNight, authView: nil, reduceMotion: true)
expect(v.frame.size == CGSize(width: 280, height: 280), "view: a 280 pt square")
let png = v.png()
expect((png?.count ?? 0) > 1000, "view: draws off screen")
if CommandLine.arguments.count > 1, let png {
    let dir = CommandLine.arguments[1]
    try? png.write(to: URL(fileURLWithPath: dir + "/panel-idle.png"))
    for (name, look) in [("done", PanelLook.done), ("refused", .refused), ("reading", .reading)] {
        let w = PanelView(prompt: prompt, theme: name == "done" ? t : .tokyoNight, authView: nil, reduceMotion: true)
        w.show(look)
        try? w.png()?.write(to: URL(fileURLWithPath: dir + "/panel-\(name).png"))
    }
    let longP = TouchIDPanelPrompt(title: "Touch ID in Omarchy (Work)", line: "sudo in pts/3 wants to run", box: long + long, timeout: 30, colors: [:])
    try? PanelView(prompt: longP, theme: .tokyoNight, authView: nil, reduceMotion: true).png()?.write(to: URL(fileURLWithPath: dir + "/panel-long.png"))
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
