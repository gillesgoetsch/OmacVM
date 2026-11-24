import AppKit
import ApplicationServices

/// Control Center's Sound list, read and pressed through Accessibility
/// (ADR 0076). macOS has no public API for the AirPlay speakers of the Mac's
/// own sound output (AVRouting's system context and MediaPlayer's routing
/// controller need Apple's entitlements), and Control Center's list differs
/// from what Bonjour finds (a Mac that receives AirPlay is not in it). So the
/// app opens Control Center, moves its window off every display at once
/// (the window server has it on one for 12 to 34 ms, measured on macOS
/// 27.2), opens the Sound module's list, reads or presses a row, and closes
/// it. `took` is how long Control Center was open, in seconds.
///
/// While Control Center is open it has the Mac's keyboard, also off screen:
/// no key reaches the VM. So a session is as short as macOS lets it be, and
/// the app starts one only when the VM asks (SoundGuest).
///
/// Elements are found by role and identifier only: titles, descriptions and
/// the names of custom actions follow the Mac's language.
public final class SoundPicker {
    public enum Failure: Error, Equatable {
        /// OmacVM is not allowed under Accessibility.
        case notTrusted
        /// Control Center is open already (the person uses it): not touched.
        case open
        /// No Control Center, no Sound module or no list this code can read.
        case unsupported(String)
        /// macOS does not offer a device of this name now.
        case noDevice(String)
        /// The device has no such option of its modes now, or macOS shows it
        /// but does not offer it ("Not Available").
        case noOption
        /// Control Center closed while the app worked in it (a click elsewhere).
        case interrupted
        /// The VM's window was no longer in front when Control Center would open.
        case notFront
        /// macOS did not switch: the speaker did not connect, or the mode stayed.
        case unchanged
    }

    public static var trusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS, which then lists OmacVM under Accessibility (switched
    /// off), and opens that list. Only the person turns it on.
    public static func askAccess() {
        DispatchQueue.main.async {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static let controlCenter = "com.apple.controlcenter"
    /// macOS 26 and later keep the menu bar's extras in this process.
    static let menuBarAgent = "com.apple.MenuBarAgent"
    static let menuExtra = "com.apple.menuextra.controlcenter"
    static let soundToggle = "controlcenter-airplay"
    /// How long macOS may take to connect a speaker.
    static let connectLimit = 15.0
    /// How long macOS may take to select a mode (AirPods: 0.5 s).
    static let modeLimit = 5.0

    public init() {}

    // MARK: Sessions
    // `front`: the VM's window is the app in front, asked again right before
    // Control Center opens.

    /// The list as Control Center shows it now, with the modes of the device
    /// that plays.
    public func read(front: () -> Bool) throws -> (elements: [SoundElement], took: Double) {
        try session(front: front) { details in try details.settledWithModes() }
    }

    /// What the Sound module shows once its list is open, unchecked, for
    /// `OmacVM --sound tree` (SoundWindow.shown).
    func tree() throws -> [SoundElement] {
        try session(front: { true }) { details in try details.shown() }.elements
    }

    /// Presses the device's row as a click in Control Center does, and waits
    /// until macOS is done with it: the row's checkmark changed (macOS takes
    /// the old output's checkmark away first and sets the new one once the
    /// speaker is connected), or macOS gave up and the list is as before,
    /// which is `unchanged`.
    public func press(_ name: String, front: () -> Bool) throws -> (elements: [SoundElement], took: Double) {
        try session(front: front) { details in
            let before = SoundList.rows(try details.settled())
            guard before.contains(where: { $0.name == name }) else { throw Failure.noDevice(name) }
            try details.press { $0.firstIndex { $0.identifier == SoundList.rowPrefix + name && $0.role == SoundList.rowRole } }
            var moved = false
            let after = try details.wait(limit: Self.connectLimit) { now in
                let rows = SoundList.rows(now)
                if SoundList.playing(rows) != SoundList.playing(before) { moved = true }
                return SoundList.pressDone(name, before: before, now: rows, moved: moved)
            }
            guard SoundList.switched(name, before: before, now: SoundList.rows(after)) else { throw Failure.unchanged }
            return after
        }
    }

    /// Presses an option of a device's modes, found by its device, its
    /// group's title and its own title as the list has them now, and waits
    /// until macOS has selected it. Control Center rebuilds the list on the
    /// press, so every element is found again after it. An option that is
    /// selected already is not pressed: a press can also take a checkmark
    /// away, as on a device's row.
    public func mode(device: String, group: String, option: String, front: () -> Bool) throws -> (elements: [SoundElement], took: Double) {
        try session(front: front) { details in
            let before = try details.settledWithModes()
            let rows = SoundList.rows(before)
            guard rows.contains(where: { $0.name == device }) else { throw Failure.noDevice(device) }
            guard let now = SoundList.option(rows, device: device, group: group, option: option), now.enabled else { throw Failure.noOption }
            if now.selected { return before }
            try details.press { SoundList.optionIndex($0, device: device, group: group, option: option) }
            func selected(_ list: [SoundElement]) -> Bool {
                SoundList.option(SoundList.rows(list), device: device, group: group, option: option)?.selected == true
            }
            let after = try details.wait(limit: Self.modeLimit, selected)
            guard selected(after) else { throw Failure.unchanged }
            return after
        }
    }

    private func session(front: () -> Bool, _ work: (Details) throws -> [SoundElement]) throws -> (elements: [SoundElement], took: Double) {
        guard Self.trusted else { throw Failure.notTrusted }
        guard let cc = NSRunningApplication.runningApplications(withBundleIdentifier: Self.controlCenter).first else {
            throw Failure.unsupported("Control Center is not running")
        }
        let app = AXUIElementCreateApplication(cc.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        guard let open = AX.windows(app) else { throw Failure.unsupported("Control Center does not answer") }
        guard open.isEmpty else { throw Failure.open }
        guard let extra = Self.extra(app) else { throw Failure.unsupported("no Control Center in the menu bar") }
        let away = Self.offScreen()
        // Control Center takes the keyboard of the app in front: never another app's.
        guard front() else { throw Failure.notFront }
        let start = ProcessInfo.processInfo.systemUptime
        guard AXUIElementPerformAction(extra, kAXPressAction as CFString) == .success else {
            throw Failure.unsupported("Control Center did not open")
        }
        // From here Control Center is open, or opening: it is closed on every way out.
        var home: CFTypeRef?
        defer { Self.close(app, extra, home: home) }
        guard let window = AX.wait(2, { AX.windows(app)?.first }) else { throw Failure.unsupported("Control Center did not open") }
        home = AX.attr(window, kAXPositionAttribute)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, away)
        let details = Details(app: app, window: window, away: away)
        guard let toggle = AX.wait(2, { AX.find(window, identifier: Self.soundToggle) }) else {
            throw AX.windows(app)?.isEmpty == true ? Failure.interrupted : Failure.unsupported("no Sound module in Control Center")
        }
        // The module's list is behind the one custom action of its button
        // ("show details" in English). With another number of them this is
        // not the Control Center this code knows: nothing is performed.
        let custom = AX.actions(toggle).filter { $0.hasPrefix("Name:") }
        guard custom.count == 1, AXUIElementPerformAction(toggle, custom[0] as CFString) == .success else {
            throw Failure.unsupported("the Sound module has no list")
        }
        let elements = try work(details)
        Self.close(app, extra, home: home)
        return (elements, ProcessInfo.processInfo.systemUptime - start)
    }

    /// Control Center's item in the menu bar: its own on macOS 15, the menu
    /// bar agent's from macOS 26.
    private static func extra(_ app: AXUIElement) -> AXUIElement? {
        var bars = [AX.element(app, "AXExtrasMenuBar")]
        if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgent).first {
            let a = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(a, 2)
            bars.append(AX.element(a, "AXExtrasMenuBar"))
        }
        for case let bar? in bars {
            if let e = AX.find(bar, identifier: menuExtra) { return e }
        }
        return nil
    }

    /// A place outside every display, so nothing of the window shows there.
    /// macOS puts it back at the menu bar at its next opening.
    private static func offScreen() -> AXValue {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let all = ids.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
        var point = CGPoint(x: (all.isNull ? 0 : all.minX) - 4000, y: (all.isNull ? 0 : all.minY) - 4000)
        return AXValueCreate(.cgPoint, &point)!
    }

    /// A press of the menu bar item goes one page back (the list, then the
    /// modules), then closes Control Center. Done only once Control Center
    /// says it has no window: no answer is not that, and is asked again. A
    /// window that is still open keeps the Mac's keyboard, so it goes back
    /// where macOS showed it (`home`), for the person to see and close.
    private static func close(_ app: AXUIElement, _ extra: AXUIElement, home: CFTypeRef?) {
        for _ in 0..<6 {
            guard let windows = AX.windows(app) else { usleep(300_000); continue }
            guard let window = windows.first else { return }
            let list = AX.find(window, identifier: SoundList.title) != nil
            AXUIElementPerformAction(extra, kAXPressAction as CFString)
            _ = AX.wait(1.5) { () -> Bool? in
                guard let w = AX.windows(app) else { return nil }
                guard let first = w.first else { return true }
                return (AX.find(first, identifier: SoundList.title) != nil) != list ? true : nil
            }
        }
        if let home, let window = AX.windows(app)?.first {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, home)
        }
    }

    /// The open list, read and pressed through Accessibility.
    final class Details: SoundWindow {
        let app: AXUIElement
        private var window: AXUIElement
        private let away: AXValue
        init(app: AXUIElement, window: AXUIElement, away: AXValue) { self.app = app; self.window = window; self.away = away }

        private func scan() throws -> [(SoundElement, AXUIElement)] {
            // A click anywhere closes Control Center: its elements then answer nothing.
            guard let now = AX.windows(app)?.first else { throw Failure.interrupted }
            // The window is asked for each time: 2 s after a press of a mode
            // the one that opened answered nothing once (macOS 27.2.1).
            // Another one goes off screen too.
            if !CFEqual(now, window) {
                window = now
                AXUIElementSetAttributeValue(now, kAXPositionAttribute as CFString, away)
            }
            var out: [(SoundElement, AXUIElement)] = []
            AX.walk(now, 0) { e, depth in
                out.append((SoundElement(depth: depth, role: AX.string(e, kAXRoleAttribute), subrole: AX.string(e, kAXSubroleAttribute),
                                         identifier: AX.string(e, kAXIdentifierAttribute), description: AX.string(e, kAXDescriptionAttribute),
                                         value: AX.string(e, kAXValueAttribute), enabled: AX.string(e, kAXEnabledAttribute) != "0"), e))
            }
            return out
        }

        func read() throws -> [SoundElement] { try scan().map(\.0) }

        func press(_ find: ([SoundElement]) -> Int?) throws {
            let now = try scan()
            guard let i = find(now.map(\.0)), AXUIElementPerformAction(now[i].1, kAXPressAction as CFString) == .success else {
                throw Failure.interrupted
            }
        }
    }
}

/// Control Center's window with the Sound module's list open. SoundPicker
/// reads and presses it through Accessibility; sound-tests plays recorded
/// lists through it.
public protocol SoundWindow: AnyObject {
    /// The window's elements now, in order.
    func read() throws -> [SoundElement]
    /// Presses the element that `find` points to in the list as it is now:
    /// an element of an earlier read may be gone, as the list is rebuilt
    /// after a press.
    func press(_ find: ([SoundElement]) -> Int?) throws
}

extension SoundWindow {
    /// The list once it stands: two reads in a row agree, with the
    /// list's title and a device in them.
    func settled() throws -> [SoundElement] {
        let end = ProcessInfo.processInfo.systemUptime + 3
        var last: [SoundElement] = []
        while ProcessInfo.processInfo.systemUptime < end {
            let now = try read()
            if SoundList.isList(now), now == last { return now }
            last = now
            usleep(60_000)
        }
        throw SoundPicker.Failure.unsupported("the Sound module shows no list of devices that stands")
    }

    /// The list as `done` wants it, or as it stands after `limit`. A read
    /// while Control Center rebuilds the list is no list and says nothing.
    func wait(limit: Double, _ done: ([SoundElement]) -> Bool) throws -> [SoundElement] {
        let end = ProcessInfo.processInfo.systemUptime + limit
        var now = try read()
        while !(SoundList.isList(now) && done(now)), ProcessInfo.processInfo.systemUptime < end {
            usleep(60_000)
            now = try read()
        }
        return SoundList.isList(now) ? now : try settled()
    }

    /// What the window shows once the list is open, for `OmacVM --sound
    /// tree`: the list as a read has it, with the modes opened, or, when no
    /// list this code reads stands there within the 3 s a read waits, the
    /// window as it is then. Nothing in it is checked: the tree is for the
    /// macOS whose list this code cannot read.
    public func shown() throws -> [SoundElement] {
        do {
            return try settledWithModes()
        } catch SoundPicker.Failure.unsupported(_) {
            return try read()
        }
    }

    /// The list once it stands, with the modes of the device that plays:
    /// its disclosure triangle is opened first when it is closed, as a
    /// click would, and Control Center keeps it open from then on.
    func settledWithModes() throws -> [SoundElement] {
        let list = try settled()
        guard SoundList.closedDisclosure(list) != nil else { return list }
        try press(SoundList.closedDisclosure)
        _ = try wait(limit: 2) { SoundList.closedDisclosure($0) == nil }
        return try settled()
    }
}

/// Accessibility's calls, as this file needs them.
enum AX {
    static func attr(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ key: String) -> String {
        switch attr(e, key) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    static func element(_ e: AXUIElement, _ key: String) -> AXUIElement? {
        guard let v = attr(e, key), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    /// Nil: the app did not answer, which says nothing about its windows.
    static func windows(_ app: AXUIElement) -> [AXUIElement]? {
        var v: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) {
        case .success: return v as? [AXUIElement] ?? []
        case .noValue: return []
        default: return nil
        }
    }

    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return names as? [String] ?? []
    }

    static func walk(_ e: AXUIElement, _ depth: Int, _ visit: (AXUIElement, Int) -> Void) {
        guard depth < 24 else { return }
        visit(e, depth)
        for c in children(e) { walk(c, depth + 1, visit) }
    }

    static func find(_ root: AXUIElement, identifier: String, depth: Int = 0) -> AXUIElement? {
        if string(root, kAXIdentifierAttribute) == identifier { return root }
        guard depth < 24 else { return nil }
        for c in children(root) {
            if let hit = find(c, identifier: identifier, depth: depth + 1) { return hit }
        }
        return nil
    }

    /// The first answer within `limit` seconds, asked every 2 ms.
    static func wait<T>(_ limit: Double, _ ask: () -> T?) -> T? {
        let end = ProcessInfo.processInfo.systemUptime + limit
        repeat {
            if let v = ask() { return v }
            usleep(2_000)
        } while ProcessInfo.processInfo.systemUptime < end
        return nil
    }
}
