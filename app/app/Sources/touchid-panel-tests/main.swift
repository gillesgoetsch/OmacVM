// Touch ID's panel (OmacVMTouchIDPanel) without a window on screen, an
// LAContext or a finger: the theme, the glyph, the words that fit, the keys,
// how an evaluation ends, where it goes, and the panel drawn off screen.
//   cd app/app && swift run touchid-panel-tests [<png dir>]
//   swift run touchid-panel-tests --live OUT.json | --show OUT.txt   (a real screen, Live.swift)
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

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live" { runLive(CommandLine.arguments[2]) }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--show" { runShow(CommandLine.arguments[2]) }
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--place" { runPlace(Array(CommandLine.arguments.dropFirst())) }

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// MARK: Theme

let t = PanelTheme(["background": "#eff1f5", "foreground": "#4c4f69", "accent": "#1e66f5", "success": "#40a02b"])
expect(t.background == PanelRGB(hex: "#eff1f5") && t.accent == PanelRGB(hex: "#1e66f5") && t.success == PanelRGB(hex: "#40a02b"), "theme: the colours sent")
expect(t.error == t.foreground, "theme: no error colour -> the text colour")
expect(t.border == [t.accent] && t.radius == 0, "theme: no border -> the accent (Omarchy's prompt without Hyprland's), square")
expect(!t.dark && PanelTheme.tokyoNight.dark, "theme: light or dark from the background")
expect(PanelTheme(["foreground": "#ffffff", "accent": "#ff0000"]) == .tokyoNight, "theme: text without its background -> Tokyo Night")
expect(PanelTheme(["background": "#000", "foreground": "#ffffff"]) == .tokyoNight, "theme: a bad colour -> Tokyo Night")
let fl = ["background": "#fffcf0", "foreground": "#100f0f", "accent": "#205ea6", "error": "#d14d41", "success": "#879a39"]
let g = PanelTheme(fl, border: ["#798186", "#cacccc"], borderAngle: 45, radius: 8)
expect(g.border == [PanelRGB(hex: "#798186")!, PanelRGB(hex: "#cacccc")!] && g.borderAngle == 45 && g.radius == 8,
       "theme: Hyprland's gradient border and rounding")
expect(PanelTheme(fl, border: ["#798186", "#cacccc", "#000000"]).border == [PanelRGB(hex: "#205ea6")!], "theme: three border colours -> the accent")
expect(PanelTheme(fl, border: ["#798186"], borderAngle: 45).borderAngle == 0, "theme: one border colour has no angle")
expect(PanelTheme(fl, radius: 40).radius == 12 && PanelTheme(fl, radius: -3).radius == 0, "theme: rounding 0...12")
let (g0, g1) = panelGradientEnds(angle: 45), (h0, h1) = panelGradientEnds(angle: 0)
expect(g0.x < 0.5 && g0.y > 0.5 && g1.x > 0.5 && g1.y < 0.5, "theme: a 45 deg gradient runs from the top left to the bottom right (Hyprland's y is down)")
expect(h0.x < h1.x && abs(h0.y - h1.y) < 1e-9, "theme: 0 deg runs left to right")
let ctl = PanelTheme.tokyoNight
expect(ctl.controlFill == ctl.background.mix(ctl.foreground, 0.04) && ctl.controlBorder == ctl.background.mix(ctl.foreground, 0.4),
       "theme: Cancel is an Omarchy control (text colour at 4 % and 40 %)")

// The Bridge's 103 -> the app -> the panel: the frame goes along whole or not at all.
let wire: [String: Any] = ["title": "Touch ID in Omarchy", "line": "Unlock 1Password", "timeout": 30,
                           "theme": ["background": "#fffcf0", "foreground": "#100f0f", "border": ["#798186", "#cacccc"],
                                     "border_angle": 45, "radius": 6, "muted": "#b7b5ac"]]
if let p = TouchIDPanelPrompt.parse(wire), let again = (try? JSONSerialization.jsonObject(with: p.showLine.dropLast()) as? [String: Any])?["prompt"],
   let q = TouchIDPanelPrompt.parse(again as Any) {
    expect(p.border == ["#798186", "#cacccc"] && p.borderAngle == 45 && p.radius == 6 && p.colors["muted"] == nil, "wire: border, angle, rounding")
    expect(q == p, "wire: the app's show line carries the same prompt to the panel")
} else { expect(false, "wire: parsed") }
func wired(_ theme: [String: Any]) -> TouchIDPanelPrompt? {
    TouchIDPanelPrompt.parse(["title": "T", "line": "L", "timeout": 30, "theme": theme] as [String: Any])
}
expect(wired(["border": ["#798186", "#CACCCC"]])?.border == [], "wire: a border with a bad colour is dropped whole")
expect(wired(["border": ["#798186", "#cacccc"], "border_angle": 400])?.borderAngle == 0, "wire: an angle out of range -> 0")
expect(wired(["radius": true])?.radius == 0 && wired(["radius": 99])?.radius == 12, "wire: rounding a number, at most 12")
expect(wired([:]).map { $0.border.isEmpty && $0.radius == 0 } == true, "wire: an older Bridge (no frame) -> the defaults")

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
expect(panelLinger(.done, reduceMotion: false) > 0 && panelLinger(.done, reduceMotion: false) <= 0.12,
       "end: a yes shows its check for at most 120 ms (the answer went before)")
expect(panelLinger(.done, reduceMotion: true) == 0, "end: a yes with Reduce Motion: gone at once")
expect(panelLinger(nil, reduceMotion: false) == 0, "end: a cancel: gone at once")
expect(panelLinger(.refused, reduceMotion: false) <= 0.7 && panelLinger(.refused, reduceMotion: true) <= 0.7,
       "end: not recognised: red for a short moment")
var once = PanelOnce()
expect(once.finish(.no("timeout")) && !once.finish(.yes) && once.result == .no("timeout"), "end: the first end wins")

// MARK: Place

let vis = CGRect(x: 0, y: 0, width: 1512, height: 944)
expect(panelFrame(window: CGRect(x: 100, y: 100, width: 1000, height: 700), visible: vis, size: CGSize(width: 280, height: 280))
       == CGRect(x: 460, y: 310, width: 280, height: 280), "place: centred on the VM's window")
expect(panelFrame(window: CGRect(x: -900, y: 0, width: 1000, height: 300), visible: vis, size: CGSize(width: 280, height: 280)).minX == 0,
       "place: kept on the screen")

// Two displays (Cocoa coordinates, y up): A = a laptop's 1728x1117 at 0,0 (main), B = an external 2560x1440 to
// its right (tops aligned), left or above. The VM in full screen with "Use external displays": QEMU's main window
// in full screen on A (the key window: QEMU hands the keyboard back to it), its window for B in full screen on B;
// both below the menu bar's 30 pt band, as on the mini (immersive off).
let side = CGSize(width: 280, height: 280)
let dispA = CGRect(x: 0, y: 0, width: 1728, height: 1117), visA = CGRect(x: 0, y: 0, width: 1728, height: 1087)
func within(_ r: CGRect, _ v: CGRect) -> Bool { v.contains(r) }
for (name, dispB) in [("right", CGRect(x: 1728, y: -323, width: 2560, height: 1440)),
                      ("left", CGRect(x: -2560, y: -323, width: 2560, height: 1440)),
                      ("above", CGRect(x: 0, y: 1117, width: 2560, height: 1440))] {
    let visB = CGRect(x: dispB.minX, y: dispB.minY, width: dispB.width, height: dispB.height - 30)
    let mainA = visA, headB = visB
    let screens = [dispA, dispB], visible = [visA, visB], wins = [mainA, headB]
    let today = panelFrame(window: mainA, visible: visA, size: side)
    func place(_ p: CGPoint, _ w: [CGRect] = wins) -> CGRect {
        panelPlace(pointer: p, screens: screens, visible: visible, windows: w, fallback: mainA, fallbackVisible: visA, size: side)
    }
    let onB = place(CGPoint(x: dispB.midX, y: dispB.midY))
    expect(panelHost(pointer: CGPoint(x: dispB.midX, y: dispB.midY), screens: screens, windows: wins).map { [$0.window, $0.screen] } == [1, 1]
           && onB == panelFrame(window: headB, visible: visB, size: side),
           "place (B \(name)): main window key on A, pointer on B -> centred on B (the user's LG; before 3.2.11: on A)")
    expect(place(CGPoint(x: dispA.midX, y: dispA.midY)) == today, "place (B \(name)): pointer on A -> A, as before")
    expect(within(place(CGPoint(x: dispB.midX, y: dispB.maxY - 10)), visB), "place (B \(name)): pointer in B's menu-bar band -> B")
    expect(within(place(CGPoint(x: dispB.midX, y: dispB.maxY)), visB), "place (B \(name)): pointer on B's top row (y == maxY) -> B")
    expect(place(CGPoint(x: dispB.midX, y: dispB.midY), [mainA]) == today
           && panelHost(pointer: CGPoint(x: dispB.midX, y: dispB.midY), screens: screens, windows: [mainA]) == nil,
           "place (B \(name)): only a window on A (windowed VM), pointer on B -> the key window, as before")
}
// The shared edge: x == 1728 is B's first column, 1727.5 still A's.
let edgeScreens = [dispA, CGRect(x: 1728, y: -323, width: 2560, height: 1440)]
let edgeWins = [visA, CGRect(x: 1728, y: -323, width: 2560, height: 1410)]
expect(panelHost(pointer: CGPoint(x: 1728, y: 500), screens: edgeScreens, windows: edgeWins).map { $0.screen } == 1
       && panelHost(pointer: CGPoint(x: 1727.5, y: 500), screens: edgeScreens, windows: edgeWins).map { $0.screen } == 0,
       "place: the pointer on the edge between A and B -> the display it is on")
// A window over both displays (windowed, dragged across): the panel on its part on the pointer's display.
let spanning = CGRect(x: 1200, y: 200, width: 1400, height: 800)
let spanB = panelPlace(pointer: CGPoint(x: 2400, y: 500), screens: edgeScreens, visible: [visA, edgeWins[1]], windows: [spanning],
                       fallback: spanning, fallbackVisible: visA, size: side)
expect(within(spanB, edgeWins[1]) && spanB.midX == (1728 + spanning.maxX) / 2, "place: a window across A and B, pointer on B -> its part on B")
expect(panelArea(window: spanning, screen: 1, screens: edgeScreens) == CGRect(x: 1728, y: 200, width: 872, height: 800),
       "place: the part of a window on the pointer's display")
// One display: the same frame as before wherever the pointer is (over another app, the menu bar, the VM window).
let one = [vis], winOne = CGRect(x: 100, y: 100, width: 1000, height: 700), offEdge = CGRect(x: -300, y: 100, width: 1000, height: 700)
for p in [CGPoint(x: 1400, y: 900), CGPoint(x: 400, y: 400), CGPoint(x: 700, y: 944)] {
    for w in [winOne, offEdge] {
        expect(panelPlace(pointer: p, screens: one, visible: one, windows: [w], fallback: w, fallbackVisible: vis, size: side)
               == panelFrame(window: w, visible: vis, size: side), "place: one display, pointer at \(p) -> the same frame as before")
    }
}
expect(panelHost(pointer: CGPoint(x: -5000, y: -5000), screens: edgeScreens, windows: edgeWins) == nil, "place: pointer on no display -> as before")
expect(panelHost(pointer: CGPoint(x: 100, y: 100), screens: edgeScreens, windows: []) == nil, "place: no VM window shows -> as before")
// Which windows may host it.
let big = CGRect(x: 0, y: 0, width: 1728, height: 1087)
expect(panelCanHost(PanelWindowFacts(frame: big), size: side), "host: a VM window on screen")
expect(!panelCanHost(PanelWindowFacts(frame: CGRect(x: 0, y: 1055, width: 1728, height: 32), alpha: 0), size: side),
       "host: not the full-screen title-bar strip (alpha 0)")
expect(!panelCanHost(PanelWindowFacts(frame: big, alpha: 0), size: side), "host: not a window still at alpha 0")
expect(!panelCanHost(PanelWindowFacts(frame: CGRect(x: 0, y: 1087, width: 1728, height: 30)), size: side), "host: not a 30 pt menu-bar window")
expect(!panelCanHost(PanelWindowFacts(frame: big, isPanel: true), size: side), "host: not a panel (the Touch ID panel, an alert, About)")
expect(!panelCanHost(PanelWindowFacts(frame: big, shownSpace: false), size: side), "host: not a window on a Space not shown")
expect(!panelCanHost(PanelWindowFacts(frame: big, visible: false), size: side), "host: not a hidden or covered window")

// MARK: Drawn off screen (never on screen)

let prompt = TouchIDPanelPrompt(title: "Touch ID in Omarchy", line: "sudo in pts/1 wants to run", box: "pacman -Syu", timeout: 30, colors: [:])
let v = PanelView(prompt: prompt, theme: .tokyoNight, authView: nil, reduceMotion: true)
expect(v.frame.size == CGSize(width: 280, height: 280), "view: a 280 pt square")
let png = v.png()
expect((png?.count ?? 0) > 1000, "view: draws off screen")
if CommandLine.arguments.count > 1, let png {
    let dir = CommandLine.arguments[1]
    try? png.write(to: URL(fileURLWithPath: dir + "/panel-idle.png"))
    let flexoki = PanelTheme(fl, border: ["#205ea6"])
    for (name, theme, look) in [("idle-flexoki-light", flexoki, PanelLook.idle), ("done-flexoki-light", flexoki, .done),
                                ("refused-flexoki-light", flexoki, .refused), ("done", PanelTheme.tokyoNight, .done),
                                ("refused", .tokyoNight, .refused), ("idle-gradient-rounded", g, .idle)] {
        let w = PanelView(prompt: prompt, theme: theme, authView: nil, reduceMotion: true)
        w.show(look)
        try? w.png()?.write(to: URL(fileURLWithPath: dir + "/panel-\(name).png"))
    }
    let longP = TouchIDPanelPrompt(title: "Touch ID in Omarchy (Work)", line: "sudo in pts/3 wants to run", box: long + long, timeout: 30, colors: [:])
    try? PanelView(prompt: longP, theme: .tokyoNight, authView: nil, reduceMotion: true).png()?.write(to: URL(fileURLWithPath: dir + "/panel-long.png"))
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
