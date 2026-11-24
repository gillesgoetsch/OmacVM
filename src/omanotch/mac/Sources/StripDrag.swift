import CoreGraphics
import Foundation

/// A left press on the strip (#849): what goes to the guest's bar copy, so
/// Omarchy's drag-to-reorder works there as in the VM's own bar. The press
/// says where it started ("press"), moves go as "drag" at most one per
/// `interval` (each runs a `qs ipc` process in the VM; the last one always
/// goes), and the release ends it ("release"): the bar settles a drag, or
/// clicks there when the button came up without one, as Omarchy's bar does.
/// Points are clamped to the bar, so a drag from the strip only reorders:
/// dragging a widget off the bar to remove it stays in the VM's own bar.
/// Right and middle clicks stay one "click" on the press.
struct StripDrag {
    enum Send: Equatable {
        case press(CGFloat, CGFloat)
        case drag(CGFloat, CGFloat)
        case release(CGFloat, CGFloat)
    }

    var interval: TimeInterval = 0.03
    private(set) var held = false
    private var lastSent: TimeInterval = -.infinity
    private var pending: CGPoint?

    /// The bar's size in bar px (points outside are clamped to it).
    var size = CGSize(width: 0, height: 26)

    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), max(size.width - 1, 0)), y: min(max(p.y, 0), max(size.height - 1, 0)))
    }

    mutating func down(_ p: CGPoint) -> Send {
        held = true
        pending = nil
        lastSent = -.infinity
        let q = clamp(p)
        return .press(q.x, q.y)
    }

    /// A move with the button held, at time `now` (s): a drag to send, or nil
    /// (kept for the next one or the release).
    mutating func moved(_ p: CGPoint, now: TimeInterval) -> Send? {
        guard held else { return nil }
        let q = clamp(p)
        if now - lastSent < interval { pending = q; return nil }
        lastSent = now
        pending = nil
        return .drag(q.x, q.y)
    }

    /// The button came up: a move not sent yet first, then the release.
    mutating func up(_ p: CGPoint) -> [Send] {
        guard held else { return [] }
        held = false
        let q = clamp(p)
        var out: [Send] = []
        if let m = pending, m != q { out.append(.drag(m.x, m.y)) }
        pending = nil
        out.append(.release(q.x, q.y))
        return out
    }

    /// The strip went away or locked while held: the guest lets the drag go
    /// where it is (a release there, no click: the point is off the bar).
    mutating func cancel() -> Send? {
        guard held else { return nil }
        held = false
        pending = nil
        return .release(-1, -1)
    }

    /// The line for notchcast.
    static func line(_ s: Send) -> String {
        switch s {
        case let .press(x, y): return String(format: "press %.1f %.1f", x, y)
        case let .drag(x, y): return String(format: "drag %.1f %.1f", x, y)
        case let .release(x, y): return String(format: "release %.1f %.1f", x, y)
        }
    }
}
