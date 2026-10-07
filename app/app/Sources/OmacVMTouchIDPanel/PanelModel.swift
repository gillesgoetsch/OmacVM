// Touch ID's panel (docs/adr/0041-touch-id.md), the parts without a window:
// the theme's colours, the glyph's ridges, the words that fit, the keys, and
// how an evaluation ends. Panel.swift draws it; touchid-panel-tests runs this.
import CoreGraphics
import Foundation
import OmacVMAuth

/// An opaque sRGB colour.
public struct PanelRGB: Equatable {
    public let r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public init?(hex: String) {
        let s = Array(hex.utf8)
        guard s.count == 7, s[0] == 35, let v = UInt32(String(decoding: s[1...], as: UTF8.self), radix: 16) else { return nil }
        self.init(Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255)
    }
    /// `t` of the way from this colour to `o`.
    public func mix(_ o: PanelRGB, _ t: Double) -> PanelRGB {
        PanelRGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t)
    }
    public var luminance: Double {
        func f(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }
}

/// What the panel draws with: the VM's Omarchy theme as the Bridge checked
/// it (contrast, opaque colours), Tokyo Night for what it did not send.
public struct PanelTheme: Equatable {
    public var background, foreground, accent, error, success, muted: PanelRGB

    public static let tokyoNight = PanelTheme(
        background: PanelRGB(hex: "#1a1b26")!, foreground: PanelRGB(hex: "#a9b1d6")!, accent: PanelRGB(hex: "#7aa2f7")!,
        error: PanelRGB(hex: "#f7768e")!, success: PanelRGB(hex: "#9ece6a")!, muted: PanelRGB(hex: "#414868")!)

    public init(background: PanelRGB, foreground: PanelRGB, accent: PanelRGB, error: PanelRGB, success: PanelRGB, muted: PanelRGB) {
        self.background = background; self.foreground = foreground; self.accent = accent
        self.error = error; self.success = success; self.muted = muted
    }

    /// From the prompt's colours. Background and text come together or not
    /// at all (one without the other could be unreadable); the rest fall
    /// back to the text colour (muted: a mix of the two).
    public init(_ colors: [String: String]) {
        let t = PanelTheme.tokyoNight
        guard let bg = colors["background"].flatMap(PanelRGB.init(hex:)),
              let fg = colors["foreground"].flatMap(PanelRGB.init(hex:)) else { self = t; return }
        func c(_ k: String) -> PanelRGB? { colors[k].flatMap(PanelRGB.init(hex:)) }
        self.init(background: bg, foreground: fg, accent: c("accent") ?? fg, error: c("error") ?? fg,
                  success: c("success") ?? fg, muted: c("muted") ?? bg.mix(fg, 0.28))
    }

    /// Secondary text and the ridges' resting colour while they trace.
    public var dim: PanelRGB { background.mix(foreground, 0.7) }
    public var faint: PanelRGB { background.mix(foreground, 0.2) }
    public var dark: Bool { background.luminance < 0.18 }
}

// MARK: The glyph (fingerprint.svg: five strokes, round caps)

public enum PanelGlyph {
    /// The SVG's viewBox and stroke width.
    public static let viewBox = CGRect(x: 40, y: 30, width: 490, height: 540)
    public static let strokeWidth: CGFloat = 30
    /// The ridges from the core outwards (the reading traces in this order).
    public static let ridges = [
        "M285 372 C285 448 330 498 396 506",
        "M232 538 C178 490 152 440 152 384 C152 302 212 242 285 242 C358 242 414 302 414 384",
        "M136 508 C104 466 90 418 90 372 C90 262 178 182 285 182 C392 182 478 262 478 372 C478 418 452 455 416 455 "
            + "C380 455 352 428 352 392 C352 340 324 302 285 302 C246 302 214 336 214 392 C214 458 246 512 300 540",
        "M74 236 C122 163 198 120 285 120 C372 120 448 163 494 236",
        "M100 132 C155 82 220 60 285 60 C350 60 415 82 468 132",
    ]
    /// The check that draws in their place.
    public static let check = "M150 330 L250 430 L430 220"

    /// A path of M, L and C commands with absolute coordinates (all the glyph
    /// uses), in the SVG's own coordinates (y down). Nil: anything else.
    public static func path(_ d: String) -> CGPath? {
        var spaced = ""
        for ch in d { if ch.isLetter { spaced += " \(ch) " } else { spaced.append(ch) } }
        let tokens = spaced.split(separator: " ").map(String.init)
        let p = CGMutablePath()
        var i = 0
        func nums(_ n: Int) -> [CGFloat]? {
            guard i + n <= tokens.count else { return nil }
            let v = tokens[i..<i + n].compactMap { Double($0).map { CGFloat($0) } }
            i += n
            return v.count == n ? v : nil
        }
        var cmd = ""
        while i < tokens.count {
            let t = tokens[i]
            if let f = t.first, f.isLetter {
                cmd = t
                i += 1
                guard t.count == 1 else { return nil }
            }
            switch cmd {
            case "M": guard let v = nums(2) else { return nil }; p.move(to: CGPoint(x: v[0], y: v[1]))
            case "L": guard let v = nums(2), !p.isEmpty else { return nil }; p.addLine(to: CGPoint(x: v[0], y: v[1]))
            case "C":
                guard let v = nums(6), !p.isEmpty else { return nil }
                p.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
            default: return nil
            }
        }
        return p.isEmpty ? nil : p
    }

    /// From the viewBox (y down) into a box of `size` (y up, centred).
    public static func transform(into size: CGSize) -> CGAffineTransform {
        let s = min(size.width / viewBox.width, size.height / viewBox.height)
        let dx = (size.width - viewBox.width * s) / 2, dy = (size.height - viewBox.height * s) / 2
        return CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: dx - viewBox.minX * s, ty: size.height - dy + viewBox.minY * s)
    }
}

// MARK: Words

/// The command in at most `lines` lines of `width`: whole when it fits, else
/// its start and its end around "…" (both ends of a command matter).
/// `fits` measures a candidate.
public func panelFit(_ text: String, fits: (String) -> Bool) -> String {
    if fits(text) { return text }
    let c = Array(text)
    var lo = 0, hi = c.count   // characters kept in all
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if fits(panelCut(c, keep: mid)) { lo = mid } else { hi = mid - 1 }
    }
    return panelCut(c, keep: lo)
}

/// The panel shows a request only when its box fits whole: a command cut
/// in the middle could hide what runs ("pacman -Syu …noconfirm" with a
/// --hookdir in the gap). Else "error": the Bridge shows macOS's dialog,
/// which shows the whole command (at most 120 characters, ADR 0041).
public func panelShowsWhole(_ box: String?, fits: (String) -> Bool) -> Bool {
    box.map(fits) ?? true
}

func panelCut(_ c: [Character], keep: Int) -> String {
    guard keep < c.count else { return String(c) }
    let head = (keep + 1) / 2, tail = keep - head
    return String(c[0..<head]) + "…" + String(c[(c.count - tail)...])
}

// MARK: Keys

public enum PanelKey: Equatable { case cancel, ignore }

/// The marker OmacVM's Mac helpers put on keys they post (kCGEventSourceUserData).
public let panelKeyMarker: Int64 = 0x0BAC0E5C

/// Esc and Cmd-. cancel; nothing else does anything (Return least of all:
/// only a finger says yes). Keys with OmacVM's marker are ignored: a VM can
/// cause those.
public func panelKey(keyCode: UInt16, command: Bool, marker: Int64) -> PanelKey {
    if marker == panelKeyMarker { return .ignore }
    if keyCode == 53 { return .cancel }              // Esc
    if keyCode == 47 && command { return .cancel }   // Cmd-.
    return .ignore
}

// MARK: How it ends

/// The panel's states (the Ridge design): idle (a slow breath), reading
/// (the ridges trace from the core outwards), done (green, the ridges fade
/// from the outside in, a check draws), refused (red, the ridges jolt, the
/// panel shakes).
public enum PanelLook: Equatable { case idle, reading, done, refused }

/// LocalAuthentication's end, as the panel cares.
public enum PanelLAEnd: Equatable { case yes, cancelled, failed, lockout, notAvailable, other }

/// The answer and the last look for an evaluation's end. `fast`: it ended
/// within half a second with an error that says nothing about a finger, so
/// the embedded view did not work: the Mac's own dialog instead (.error).
public func panelEnd(_ e: PanelLAEnd, after: TimeInterval) -> (TouchIDPanelResult, PanelLook?) {
    switch e {
    case .yes: return (.yes, .done)
    case .cancelled: return (.no("cancelled"), nil)
    case .failed: return (.no("failed"), .refused)
    case .lockout: return (.no("lockout"), .refused)
    case .notAvailable: return (.no("no-touch-id"), nil)
    case .other: return after < 0.5 ? (.error, nil) : (.no("failed"), .refused)
    }
}

/// The first end wins: a Cancel after the timeout, or the evaluation's reply
/// after an invalidate, changes nothing.
public struct PanelOnce {
    public private(set) var result: TouchIDPanelResult?
    public init() {}
    public mutating func finish(_ r: TouchIDPanelResult) -> Bool {
        guard result == nil else { return false }
        result = r
        return true
    }
}

/// The panel's place: centred on the VM's window, inside the screen's
/// visible area (Cocoa coordinates).
public func panelFrame(window: CGRect, visible: CGRect, size: CGSize) -> CGRect {
    var x = (window.midX - size.width / 2).rounded(), y = (window.midY - size.height / 2).rounded()
    x = min(max(x, visible.minX), visible.maxX - size.width)
    y = min(max(y, visible.minY), visible.maxY - size.height)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}
