import Foundation

/// Battery saver (the VM window's group of the experimental switches that
/// save battery; docs/design/battery-saver.md): one switch at the top for the
/// seven below it, each of which still switches alone. The group keeps no
/// setting of its own: its position is what the switches below say, and
/// flipping it writes each of them through that switch's own path (the
/// app's keys, or the VM's record for Prefer VP9 on YouTube and Fewer
/// animations). The rules, apart from the UI so they are tested without a
/// window: `swift run features-tests`.
public enum BatterySaver {
    /// The switches in the group, in the window's order: the ones that work
    /// at once first, the ones that count from the next start of the VM last.
    public enum Child: String, CaseIterable, Sendable {
        case vcpuClockSaver, pauseWhileHidden, fewerAnimations, hdrFullScreenOnly, youtubeVP9, pointerPlane, presentTiles

        public var title: String {
            switch self {
            case .vcpuClockSaver: return "VM CPU clock saver"
            case .pauseWhileHidden: return "Pause drawing while hidden"
            case .fewerAnimations: return "Fewer animations"
            case .hdrFullScreenOnly: return "HDR only in full screen"
            case .youtubeVP9: return "Prefer VP9 on YouTube"
            case .pointerPlane: return "Pointer on its own layer"
            case .presentTiles: return "Draw only what changed"
            }
        }

        /// A switch of the VM's record (its features file), not an app key.
        public var isVMFeature: Bool { self == .fewerAnimations || self == .youtubeVP9 }
    }

    /// One switch as the window shows it now: shown on this Mac, switchable
    /// (not greyed out with a reason), on.
    public struct Item: Equatable, Sendable {
        public let child: Child
        public let shown: Bool
        public let enabled: Bool
        public let on: Bool
        public init(_ child: Child, shown: Bool = true, enabled: Bool = true, on: Bool) {
            self.child = child; self.shown = shown; self.enabled = enabled; self.on = on
        }
    }

    /// The switch at the top is on while any shown switch below is on.
    public static func isOn(_ items: [Item]) -> Bool { items.contains { $0.shown && $0.on } }

    /// On, of shown (a greyed-out one counts; a hidden one does not).
    public static func count(_ items: [Item]) -> (on: Int, of: Int) {
        let shown = items.filter(\.shown)
        return (shown.filter(\.on).count, shown.count)
    }

    /// What flipping the top switch writes: on, every shown, switchable one
    /// that is off (never one greyed out for a need, such as HDR off: that
    /// need is never turned on for it); off, every shown one that is on,
    /// a greyed-out one too (as its own switch would, the key goes off).
    public static func changes(_ items: [Item], to on: Bool) -> [Child] {
        items.filter { $0.shown && (on ? ($0.enabled && !$0.on) : $0.on) }.map(\.child)
    }

    public static let title = "Battery saver"
    public static let offText = "Less battery use with the switches below, together or one by one."
    public static let allOnText = "On. Some switches count from the next start of the VM."

    /// The grey line under the top switch.
    public static func subtitle(_ items: [Item]) -> String {
        let (on, of) = count(items)
        if on == 0 { return offText }
        if on == of { return allOnText }
        return "\(on) of \(of) on."
    }

    /// What VoiceOver adds after the top switch's own on or off (its hint):
    /// the switch has no mixed look, so it says how many are on.
    public static func accessibilityHint(_ items: [Item]) -> String {
        let (on, of) = count(items)
        return "\(on) of \(of) on"
    }

    /// The top switch's (i).
    public static let info = "Experimental. One place for the switches that save battery. The switch at the top turns them all on or off together; each one below can also be switched alone, and its (i) says what it does, what it saved in measurements and what it trades. Switches this Mac cannot use are not shown. A switch that needs something first (HDR and 10-bit colour on) stays off and says what it needs, and the top switch never turns those needs on for it. VM CPU clock saver, Pause drawing while hidden, Fewer animations and HDR only in full screen work at once in a running VM; Prefer VP9 on YouTube counts when Chrome or Chromium next starts; Pointer on its own layer and Draw only what changed count from the next start of the VM. GPU safe mode turns some of them off; their lines say so."
}
