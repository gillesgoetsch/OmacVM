import SwiftUI

/// The pictures of the VM window (docs/design/settings-3.1/final.html):
/// how a VM starts, what the escape combo takes back to macOS, the swipe out
/// to macOS, the Mission Control overview. Drawn in the design's coordinates
/// and scaled; Omarchy is drawn in Rosé Pine Dawn's colours, macOS's desktop
/// in its own, in light and dark.
private struct Sketch {
    var ctx: GraphicsContext
    let k: CGFloat

    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0, fill: Color? = nil,
              stroke: Color? = nil, line: CGFloat = 1, dash: [CGFloat] = []) {
        let path = Path(roundedRect: r(x, y, w, h), cornerRadius: radius * k)
        if let fill { ctx.fill(path, with: .color(fill)) }
        if let stroke {
            ctx.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: line * k, dash: dash.map { $0 * k }))
        }
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat, _ fill: Color) {
        ctx.fill(Path(ellipseIn: r(cx - radius, cy - radius, 2 * radius, 2 * radius)), with: .color(fill))
    }

    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, _ color: Color, anchor: UnitPoint = .bottom) {
        ctx.draw(Text(s).font(.system(size: size * k)).foregroundStyle(color), at: CGPoint(x: x * k, y: y * k), anchor: anchor)
    }

    func clipped(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, _ draw: (Sketch) -> Void) {
        var c = ctx
        c.clip(to: Path(roundedRect: r(x, y, w, h), cornerRadius: radius * k))
        draw(Sketch(ctx: c, k: k))
    }

    func line(_ points: [(CGFloat, CGFloat)], _ color: Color, width: CGFloat) {
        var p = Path()
        for (i, pt) in points.enumerated() {
            let q = CGPoint(x: pt.0 * k, y: pt.1 * k)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width * k, lineCap: .round, lineJoin: .round))
    }

    func curve(_ from: (CGFloat, CGFloat), _ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat),
               _ color: Color, width: CGFloat) {
        var p = Path()
        p.move(to: CGPoint(x: from.0 * k, y: from.1 * k))
        p.addCurve(to: CGPoint(x: to.0 * k, y: to.1 * k), control1: CGPoint(x: c1.0 * k, y: c1.1 * k),
                   control2: CGPoint(x: c2.0 * k, y: c2.1 * k))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width * k, lineCap: .round))
    }
}

/// Rosé Pine Dawn (Omarchy) and macOS's desktop.
private enum Ink {
    static let desk = Color(rgb: 0xD8E3F0), menu = Color(rgb: 0xF7F7F8), menuItem = Color(rgb: 0xB9B9BF)
    static let base = Color(rgb: 0xE9E0D6), bar = Color(rgb: 0xFAF4ED), titleBar = Color(rgb: 0xF2ECE4)
    static let surface = Color(rgb: 0xFFFAF3), border = Color(rgb: 0xDCD3C9), rose = Color(rgb: 0xD7827E)
    static let pine = Color(rgb: 0x286983), muted = Color(rgb: 0xB5AFB8), gold = Color(rgb: 0xEA9D34)
    static let iris = Color(rgb: 0x907AA9), text = Color(rgb: 0x575279), dot = Color(rgb: 0xD5CCC2)
    static let subtle = Color(rgb: 0x9893A5), notch = Color(rgb: 0x0F0F10), stand = Color(rgb: 0x8E8E93)
    static let accent = Color(rgb: 0x0A84FF)
}

/// How a VM starts: in a window on the desktop, or full screen (with the
/// notch drawn on a Mac that has one).
struct StartInPicture: View {
    enum Kind { case window, fullScreen, fullScreenNotch }
    let kind: Kind
    var notch = true

    var body: some View {
        Canvas { ctx, size in
            let s = Sketch(ctx: ctx, k: size.width / 160)
            s.clipped(0, 0, 160, 98, radius: 8) { s in
                switch kind {
                case .window: window(s)
                case .fullScreen, .fullScreenNotch: full(s)
                }
            }
            s.rect(0.5, 0.5, 159, 97, radius: 8, stroke: Look.pictureLine)
        }
        .frame(width: 150, height: 91.9)
        .accessibilityHidden(true)
    }

    private func window(_ s: Sketch) {
        s.rect(0, 0, 160, 98, fill: Ink.desk)
        s.rect(0, 0, 160, 10, fill: Ink.menu)
        s.circle(8, 5, 1.4, Ink.stand)
        s.rect(14, 3.8, 16, 2.4, radius: 1.2, fill: Ink.menuItem)
        s.rect(138, 3.8, 14, 2.4, radius: 1.2, fill: Ink.menuItem)
        s.rect(60, 89, 40, 5, radius: 2.5, fill: .white.opacity(0.85))
        s.clipped(40, 22, 80, 58, radius: 4) { s in
            s.rect(40, 22, 80, 58, fill: Ink.base)
            s.rect(40, 22, 80, 10, fill: Ink.titleBar)
            s.circle(46.5, 27, 1.6, Color(rgb: 0xFF5F57))
            s.circle(51.5, 27, 1.6, Color(rgb: 0xFEBC2E))
            s.circle(56.5, 27, 1.6, Color(rgb: 0x28C840))
            s.rect(40, 32, 80, 5, fill: Ink.bar)
            s.rect(43, 33.2, 2.6, 2.6, radius: 0.8, fill: Ink.rose)
            s.rect(47, 33.2, 2.6, 2.6, radius: 0.8, fill: Ink.dot)
            s.rect(51, 33.2, 2.6, 2.6, radius: 0.8, fill: Ink.dot)
            s.rect(76, 33.6, 9, 1.8, radius: 0.9, fill: Ink.text)
            s.rect(44, 41, 44, 35, radius: 2, fill: Ink.surface, stroke: Ink.rose)
            s.rect(92, 41, 24, 16, radius: 2, fill: Ink.surface, stroke: Ink.border)
            s.rect(92, 60, 24, 16, radius: 2, fill: Ink.surface, stroke: Ink.border)
            s.rect(48, 46, 18, 2.2, radius: 1.1, fill: Ink.pine)
            s.rect(48, 51, 28, 2.2, radius: 1.1, fill: Ink.muted)
            s.rect(48, 56, 22, 2.2, radius: 1.1, fill: Ink.muted)
            s.rect(48, 61, 14, 2.2, radius: 1.1, fill: Ink.gold)
        }
        s.rect(40, 22, 80, 58, radius: 4, stroke: .black.opacity(0.3), line: 0.7)
    }

    private func full(_ s: Sketch) {
        s.rect(0, 0, 160, 98, fill: Ink.base)
        s.rect(0, 0, 160, 9, fill: Ink.bar)
        s.rect(4, 2.5, 4, 4, radius: 1, fill: Ink.rose)
        for x in [10.0, 16, 22, 28] { s.rect(x, 2.5, 4, 4, radius: 1, fill: Ink.dot) }
        s.rect(74, 3.2, 13, 2.6, radius: 1.3, fill: Ink.text)
        for x in [147.0, 152, 157] { s.circle(x, 4.5, 1.2, Ink.subtle) }
        if notch { s.rect(66, 0, 28, 7.5, radius: 2.5, fill: Ink.notch) }
        // Omanotch's strip ends in a line; the VM's own bar does not.
        if kind == .fullScreen && notch { s.rect(0, 9, 160, 0.7, fill: .black.opacity(0.18)) }
        s.rect(6, 15, 90, 75, radius: 3, fill: Ink.surface, stroke: Ink.rose, line: 1.2)
        s.rect(100, 15, 54, 35, radius: 3, fill: Ink.surface, stroke: Ink.border)
        s.rect(100, 54, 54, 36, radius: 3, fill: Ink.surface, stroke: Ink.border)
        s.rect(12, 22, 30, 2.6, radius: 1.3, fill: Ink.pine)
        s.rect(12, 28, 52, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(12, 34, 40, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(12, 40, 58, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(12, 46, 24, 2.6, radius: 1.3, fill: Ink.gold)
        s.rect(106, 22, 24, 2.6, radius: 1.3, fill: Ink.pine)
        s.rect(106, 28, 34, 2.6, radius: 1.3, fill: Ink.muted)
        s.rect(106, 61, 30, 2.6, radius: 1.3, fill: Ink.iris)
        s.rect(106, 67, 22, 2.6, radius: 1.3, fill: Ink.muted)
    }
}

/// The escape combo: the monitor under the pointer goes to macOS, or all of them.
struct EscapePicture: View {
    let all: Bool

    var body: some View {
        Canvas { ctx, size in
            let s = Sketch(ctx: ctx, k: size.width / 170)
            s.rect(0, 0, 170, 100, radius: 8, fill: Look.panel)
            s.rect(61, 6, 48, 14, radius: 3, fill: Look.key, stroke: Ink.accent, line: 1.2)
            s.text("⌃⌥ esc", 85, 16.5, size: 7, Color.accentColor)
            monitor(s, x: 10, macOS: true, pointer: true)
            monitor(s, x: 90, macOS: all, pointer: false)
            s.rect(0.5, 0.5, 169, 99, radius: 8, stroke: Look.pictureLine)
        }
        .frame(width: 170, height: 100)
        .accessibilityHidden(true)
    }

    private func monitor(_ s: Sketch, x: CGFloat, macOS: Bool, pointer: Bool) {
        s.clipped(x, 30, 70, 44, radius: 3) { s in
            if macOS {
                s.rect(x, 30, 70, 44, fill: Ink.desk)
                s.rect(x, 30, 70, 5, fill: Ink.menu)
                s.rect(x + 23, 69, 24, 3, radius: 1.5, fill: .white.opacity(0.85))
            } else {
                s.rect(x, 30, 70, 44, fill: Ink.base)
                s.rect(x, 30, 70, 5, fill: Ink.bar)
                s.rect(x + 3, 31.2, 2.6, 2.6, radius: 0.8, fill: Ink.rose)
                s.rect(x + 7, 31.2, 2.6, 2.6, radius: 0.8, fill: Ink.dot)
                s.rect(x + 32, 31.6, 8, 1.8, radius: 0.9, fill: Ink.text)
                s.rect(x + 4, 39, 34, 31, radius: 2, fill: Ink.surface, stroke: Ink.rose)
                s.rect(x + 41, 39, 25, 14, radius: 2, fill: Ink.surface, stroke: Ink.border)
                s.rect(x + 41, 56, 25, 14, radius: 2, fill: Ink.surface, stroke: Ink.border)
                s.rect(x + 8, 44, 16, 2, radius: 1, fill: Ink.pine)
                s.rect(x + 8, 49, 22, 2, radius: 1, fill: Ink.muted)
                s.rect(x + 8, 54, 14, 2, radius: 1, fill: Ink.gold)
            }
        }
        s.rect(x, 30, 70, 44, radius: 3, stroke: Ink.stand, line: 1.4)
        s.line([(x + 35, 74), (x + 35, 79)], Ink.stand, width: 1.6)
        s.line([(x + 24, 79), (x + 46, 79)], Ink.stand, width: 1.6)
        if pointer {
            var p = Path()
            let k = s.k, px = x + 32, py: CGFloat = 46
            let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 9.2), (2.1, 7.2), (3.6, 10.4), (5.1, 9.7), (3.6, 6.5), (6.4, 6.3)]
            for (i, q) in pts.enumerated() {
                let pt = CGPoint(x: (px + q.0) * k, y: (py + q.1) * k)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            s.ctx.fill(p, with: .color(Color(rgb: 0x1D1D1F)))
            s.ctx.stroke(p, with: .color(.white), lineWidth: 0.6 * k)
        }
    }
}

/// Swipe out: past the first or the last workspace lies the macOS Space beside it.
struct SwipeOutPicture: View {
    var body: some View {
        Canvas { ctx, size in
            let s = Sketch(ctx: ctx, k: size.width / 240)
            s.rect(0, 0, 240, 64, radius: 8, fill: Look.panel)
            for x in [12.0, 192] {
                s.rect(x, 22, 36, 24, radius: 3, fill: Ink.desk)
                s.clipped(x, 22, 36, 24, radius: 3) { s in s.rect(x, 22, 36, 3.5, fill: Ink.menu) }
                s.rect(x + 12, 42, 12, 2, radius: 1, fill: .white.opacity(0.9))
                s.rect(x + 0.5, 22.5, 35, 23, radius: 3, stroke: Look.pictureLine)
            }
            for (i, x) in [56.0, 90, 124, 158].enumerated() {
                s.rect(x, 24, 28, 20, radius: 3, fill: Ink.base)
                s.clipped(x, 24, 28, 20, radius: 3) { s in s.rect(x, 24, 28, 2.5, fill: Ink.bar) }
                if i < 3 {
                    s.rect(x + 3, 29, 12, 9, radius: 1, fill: Ink.surface, stroke: Ink.border, line: 0.6)
                    s.rect(x + 17, 29, 8, 9, radius: 1, fill: Ink.surface, stroke: Ink.border, line: 0.6)
                    s.text("\(i + 1)", x + 24, 44, size: 6, Ink.text)
                }
                s.rect(x + 0.5, 24.5, 27, 19, radius: 3, stroke: i == 0 ? Ink.rose : (i == 3 ? Color(rgb: 0xC9C0B6) : Look.pictureLine),
                       line: 0.8, dash: i == 3 ? [2.4, 2] : [])
            }
            s.text("macOS", 30, 59, size: 6, .secondary)
            s.text("Omarchy", 121, 59, size: 6, .secondary)
            s.text("macOS", 210, 59, size: 6, .secondary)
            s.curve((60, 16), (54, 8), (38, 8), (30, 15), Ink.accent, width: 1.6)
            s.line([(35, 11.6), (29.8, 15.2), (34.6, 18.2)], Ink.accent, width: 1.6)
            s.curve((180, 16), (186, 8), (202, 8), (210, 15), Ink.accent, width: 1.6)
            s.line([(205, 11.6), (210.2, 15.2), (205.4, 18.2)], Ink.accent, width: 1.6)
            s.rect(0.5, 0.5, 239, 63, radius: 8, stroke: Look.pictureLine)
        }
        .frame(width: 240, height: 64)
        .accessibilityHidden(true)
    }
}

/// Mission Control: four fingers up spread the display's windows out as
/// tiles, with the workspaces in a row along the top (the Mac Mission
/// Control plugin's overview). Left the tiled screen, right the overview.
struct MissionControlPicture: View {
    var body: some View {
        Canvas { ctx, size in
            let s = Sketch(ctx: ctx, k: size.width / 240)
            s.rect(0, 0, 240, 64, radius: 8, fill: Look.panel)
            omarchy(s, x: 20, y: 7)
            s.rect(20.5, 7.5, 69, 43, radius: 3, stroke: Look.pictureLine)
            overview(s, x: 152, y: 7)
            s.rect(152.5, 7.5, 69, 43, radius: 3, stroke: Look.pictureLine)
            s.text("Omarchy", 55, 59, size: 6, .secondary)
            s.text("Mission Control", 187, 59, size: 6, .secondary)
            // Four fingers, up.
            for (x, y) in [(115.0, 42.0), (119, 40.8), (123, 40.8), (127, 42)] { s.circle(x, y, 1.5, Ink.accent) }
            s.line([(121, 36), (121, 21)], Ink.accent, width: 1.6)
            s.line([(117.2, 25.2), (121, 21), (124.8, 25.2)], Ink.accent, width: 1.6)
            s.rect(0.5, 0.5, 239, 63, radius: 8, stroke: Look.pictureLine)
        }
        .frame(width: 240, height: 64)
        .accessibilityHidden(true)
    }

    /// The tiled Omarchy screen before the gesture (EscapePicture's drawing).
    private func omarchy(_ s: Sketch, x: CGFloat, y: CGFloat) {
        s.clipped(x, y, 70, 44, radius: 3) { s in
            s.rect(x, y, 70, 44, fill: Ink.base)
            s.rect(x, y, 70, 5, fill: Ink.bar)
            s.rect(x + 3, y + 1.2, 2.6, 2.6, radius: 0.8, fill: Ink.rose)
            s.rect(x + 7, y + 1.2, 2.6, 2.6, radius: 0.8, fill: Ink.dot)
            s.rect(x + 32, y + 1.6, 8, 1.8, radius: 0.9, fill: Ink.text)
            s.rect(x + 4, y + 9, 34, 31, radius: 2, fill: Ink.surface, stroke: Ink.rose)
            s.rect(x + 41, y + 9, 25, 14, radius: 2, fill: Ink.surface, stroke: Ink.border)
            s.rect(x + 41, y + 26, 25, 14, radius: 2, fill: Ink.surface, stroke: Ink.border)
            s.rect(x + 8, y + 14, 16, 2, radius: 1, fill: Ink.pine)
            s.rect(x + 8, y + 19, 22, 2, radius: 1, fill: Ink.muted)
            s.rect(x + 8, y + 24, 14, 2, radius: 1, fill: Ink.gold)
        }
    }

    /// The plugin's overview: the workspaces as small previews along the top
    /// (the current one marked, a narrow tile for a new one), the wallpaper
    /// dimmed below, and the same three windows spread out with gaps.
    private func overview(_ s: Sketch, x: CGFloat, y: CGFloat) {
        s.clipped(x, y, 70, 44, radius: 3) { s in
            s.rect(x, y, 70, 44, fill: Ink.base)
            s.rect(x, y + 12, 70, 32, fill: .black.opacity(0.12))
            s.rect(x, y, 70, 12, fill: Ink.bar.opacity(0.9))
            s.rect(x, y + 12, 70, 0.4, fill: Ink.border)
            // Three workspace previews and the narrow tile for a new one.
            for i in 0..<3 {
                let px = x + 11.75 + CGFloat(i) * 13.5
                s.rect(px, y + 2.55, 11, 6.9, radius: 0.5, fill: Ink.base,
                       stroke: i == 0 ? Ink.rose : Ink.border, line: 0.6)
                s.rect(px + 1.4, y + 4, 4.6, 4, radius: 0.4, fill: Ink.surface)
                s.rect(px + 6.8, y + 4, 2.8, 4, radius: 0.4, fill: Ink.surface)
            }
            let plus = x + 11.75 + 3 * 13.5
            s.rect(plus, y + 2.55, 6, 6.9, radius: 0.5, fill: Ink.dot)
            s.line([(plus + 1.7, y + 6), (plus + 4.3, y + 6)], Ink.subtle, width: 0.6)
            s.line([(plus + 3, y + 4.7), (plus + 3, y + 7.3)], Ink.subtle, width: 0.6)
            // The windows, spread out: the focused one keeps its mark.
            tile(s, x + 5, y + 16, 30, 19, focus: true)
            s.rect(x + 8, y + 21, 12, 1.8, radius: 0.9, fill: Ink.pine)
            s.rect(x + 8, y + 24.5, 16, 1.8, radius: 0.9, fill: Ink.muted)
            s.rect(x + 8, y + 28, 10, 1.8, radius: 0.9, fill: Ink.gold)
            tile(s, x + 39, y + 16, 26, 11, focus: false)
            s.rect(x + 42, y + 20.5, 10, 1.6, radius: 0.8, fill: Ink.pine)
            s.rect(x + 42, y + 23.5, 14, 1.6, radius: 0.8, fill: Ink.muted)
            tile(s, x + 41, y + 30, 22, 11, focus: false)
            s.rect(x + 44, y + 34.5, 12, 1.6, radius: 0.8, fill: Ink.muted)
            s.rect(x + 44, y + 37.5, 8, 1.6, radius: 0.8, fill: Ink.gold)
        }
    }

    /// One spread-out window: a thin title bar over the body.
    private func tile(_ s: Sketch, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, focus: Bool) {
        s.clipped(x, y, w, h, radius: 1.5) { s in
            s.rect(x, y, w, h, fill: Ink.surface)
            s.rect(x, y, w, 2.4, fill: Ink.titleBar)
        }
        s.rect(x, y, w, h, radius: 1.5, stroke: focus ? Ink.rose : Ink.border, line: focus ? 0.8 : 0.6)
    }
}

/// Skip the notch, in its (i): the top of the built-in display three times.
/// Off: the tray's last icons go behind the notch. On: they continue left of
/// it, in the same order. Pointing at the notch: Omarchy's hidden indicators
/// open left of it when the right side has no room for them (the tray stays).
struct NotchSkipPicture: View {
    enum Row { case off, on, peek }
    /// The tray icons from the left, as Omarchy lays them out.
    private static let tray: [Color] = [Ink.iris, Ink.gold, Color(rgb: 0x56949F), Ink.rose, Ink.pine, Ink.gold,
                                        Color(rgb: 0xB4637A), Ink.iris, Ink.pine, Ink.rose, Color(rgb: 0x56949F), Ink.gold]
    /// How many of them no longer fit right of the notch (the fourth only half).
    private static let over = 4

    var body: some View {
        Canvas { ctx, size in
            let s = Sketch(ctx: ctx, k: size.width / 292)
            s.rect(0, 0, 292, 171, radius: 8, fill: Look.panel)
            s.text("Off", 13, 19, size: 8, .secondary, anchor: .bottomLeading)
            strip(s, y: 24, .off)
            s.text("On", 13, 72, size: 8, .secondary, anchor: .bottomLeading)
            strip(s, y: 77, .on)
            s.text("On, pointing at the notch", 13, 125, size: 8, .secondary, anchor: .bottomLeading)
            strip(s, y: 130, .peek)
            s.rect(0.5, 0.5, 291, 170, radius: 8, stroke: Look.pictureLine)
        }
        .frame(width: 292, height: 171)
        .accessibilityHidden(true)
    }

    /// One display's top: the bar (18 tall) and a little of the desktop.
    private func strip(_ s: Sketch, y: CGFloat, _ row: Row) {
        let left: CGFloat = 12, width: CGFloat = 268, notchL: CGFloat = 124, notchR: CGFloat = 168
        s.clipped(left, y, width, 30, radius: 4) { s in
            s.rect(left, y, width, 30, fill: Ink.base)
            s.rect(left, y, width, 18, fill: Ink.bar)
            s.rect(left, y + 18, width, 0.6, fill: Ink.border)
            // The menu and four workspaces.
            s.rect(18, y + 6, 6, 6, radius: 1.5, fill: Ink.rose)
            for (i, x) in [29.0, 37, 45, 53].enumerated() {
                s.rect(x, y + 6, 6, 6, radius: 1.5, fill: i == 0 ? Ink.pine : Ink.dot)
            }
            // The clock at the far right, the tray before it, 9 apart.
            s.rect(250, y + 7.6, 24, 2.8, radius: 1.4, fill: Ink.text)
            if row == .peek {
                // A tray that fits right of the notch, Omarchy's active
                // indicator before the clock, its hidden ones left of the notch.
                for (i, c) in Self.tray.prefix(7).enumerated() { s.circle(178 + CGFloat(i) * 9, y + 9, 3, c) }
                s.rect(237, y + 6.5, 5, 5, radius: 1.2, fill: Ink.subtle)
                s.rect(notchL - 36, y + 3.5, 30, 11, radius: 5.5, fill: Ink.accent.opacity(0.18))
                for i in 0..<3 {
                    s.rect(notchL - 15.5 - CGFloat(i) * 9, y + 6.5, 5, 5, radius: 1.2, stroke: Ink.text, line: 1.1)
                }
            } else {
                let n = Self.tray.count
                for (i, c) in Self.tray.enumerated() {
                    var cx = 241 - CGFloat(n - 1 - i) * 9
                    if row == .on && i < Self.over { cx = notchL - 7 - CGFloat(Self.over - 1 - i) * 9 }
                    s.circle(cx, y + 9, 3, c)
                }
            }
            // The camera housing, over what is behind it.
            s.rect(notchL, y - 6, notchR - notchL, 19, radius: 4, fill: Ink.notch)
            if row == .on {
                // Under the notch, from where they were to where they are.
                s.curve((notchR + 4, y + 21), (notchR - 8, y + 28.5), (notchL + 8, y + 28.5), (notchL - 3, y + 21),
                        Ink.accent, width: 1.4)
                s.line([(notchL + 2.4, y + 21.2), (notchL - 3.2, y + 20.8), (notchL - 1.4, y + 26)], Ink.accent, width: 1.4)
            }
        }
        s.rect(left + 0.5, y + 0.5, width - 1, 29, radius: 4, stroke: Look.pictureLine)
        if row == .peek { pointer(s, x: 144, y: y + 8) }
    }

    /// The Mac's pointer, on the notch.
    private func pointer(_ s: Sketch, x: CGFloat, y: CGFloat) {
        var p = Path()
        let k = s.k
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 9.2), (2.1, 7.2), (3.6, 10.4), (5.1, 9.7), (3.6, 6.5), (6.4, 6.3)]
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: (x + q.0) * k, y: (y + q.1) * k)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        s.ctx.fill(p, with: .color(Color(rgb: 0x1D1D1F)))
        s.ctx.stroke(p, with: .color(.white), lineWidth: 0.6 * k)
    }
}
