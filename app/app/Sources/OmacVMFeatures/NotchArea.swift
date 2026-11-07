import CryptoKit
import Foundation

/// How a VM uses the strip beside the notch in OmacVM.app's full screen
/// (#339). Native (the default, "Full screen, notch via Omanotch"): the window
/// sits below the camera housing and Omanotch streams the bar into the strip.
/// FullPanel ("Full screen including notch, no Omanotch needed",
/// experimental): QEMU's window covers the strip too
/// (omacvm-cocoa-fullpanel.patch) and the guest draws its own bar there,
/// split around the notch; Omanotch is off for that start. Omanotch stays the
/// shared integration for every route; FullPanel is OmacVM.app only.
public enum NotchMode: String, CaseIterable, Sendable {
    case native, fullpanel

    public var title: String {
        switch self {
        case .native: return "Full screen, notch via Omanotch"
        case .fullpanel: return StartIn.fullScreenNotch.title(hasNotch: true)
        }
    }
}

/// The VM window's "Start in" picker: one choice for two settings that only
/// make sense together. Window: the app's startFullScreen off. Full screen:
/// on, the VM's notch-mode native. Full screen including notch: on and
/// fullpanel; listed only on a Mac whose built-in display has a notch.
public enum StartIn: String, CaseIterable, Sendable {
    case window, fullScreen, fullScreenNotch

    /// The picture's name in the VM window's Start in.
    public var caption: String {
        switch self {
        case .window: return "Window"
        case .fullScreen: return "Full screen"
        case .fullScreenNotch: return "Full screen including notch"
        }
    }

    /// The grey line under the picture: how full screen treats the notch.
    public func detail(hasNotch: Bool) -> String? {
        switch self {
        case .window: return nil
        case .fullScreen: return hasNotch ? "Notch via Omanotch" : nil
        case .fullScreenNotch: return "Experimental"
        }
    }

    /// The full name, as the control centre and the docs say it.
    public func title(hasNotch: Bool) -> String {
        switch self {
        case .window: return "Window"
        case .fullScreen: return hasNotch ? "Full screen, notch via Omanotch" : "Full screen"
        case .fullScreenNotch: return "Full screen including notch, no Omanotch needed (experimental)"
        }
    }

    /// Under the pictures while including notch is chosen.
    public static let notchNote = "No Omanotch needed: the VM draws its bar beside the notch. Experimental."

    /// The choices the picker lists on this Mac.
    public static func choices(hasNotch: Bool) -> [StartIn] {
        hasNotch ? allCases : [.window, .fullScreen]
    }

    /// What the picker shows. Without a notch a FullPanel VM shows "Full
    /// screen" (it starts native there).
    public static func current(fullScreen: Bool, mode: NotchMode, hasNotch: Bool) -> StartIn {
        guard fullScreen else { return .window }
        return mode == .fullpanel && hasNotch ? .fullScreenNotch : .fullScreen
    }

    /// The app's startFullScreen for this choice.
    public var fullScreen: Bool { self != .window }

    /// The VM's notch-mode for this choice; nil: leave it (Window).
    public var mode: NotchMode? {
        switch self {
        case .window: return nil
        case .fullScreen: return .native
        case .fullScreenNotch: return .fullpanel
        }
    }
}

/// The camera housing of the built-in display, in macOS points: what the
/// guest's bar needs to split around it (the same numbers Omanotch's helper
/// sends notchcast: left and right edge of the housing from the display's left
/// edge, the strip's height, the display's width), plus the display's height,
/// so the guest can tell a picture that really covers the strip.
public struct NotchGeometry: Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var strip: Double
    public var width: Double
    public var height: Double

    public init(left: Double, right: Double, strip: Double, width: Double, height: Double) {
        self.left = left; self.right = right; self.strip = strip; self.width = width; self.height = height
    }

    /// The strip's height as Omanotch sees it: the menu bar's height beside
    /// the notch (`menuBar`: the display's top minus its visible frame's top),
    /// at least a little more than the camera housing (`safeTop`) when the
    /// menu bar hides itself.
    public static func strip(menuBar: Double, safeTop: Double) -> Double {
        max(menuBar, safeTop + 1.5)
    }

    /// Numbers a notched MacBook can have (anything else: no FullPanel).
    public var valid: Bool {
        [left, right, strip, width, height].allSatisfy { $0.isFinite } &&
            left > 0 && right > left && right < width && right - left < width / 3 &&
            strip >= 10 && strip <= 100 && width >= 800 && height > strip * 5
    }

    /// "LxRxHxWxD", one decimal, no spaces (NotchArea.geometry(text:) reads it back).
    public var text: String {
        [left, right, strip, width, height].map { String(format: "%.1f", $0) }.joined(separator: "x")
    }

    /// The SMBIOS OEM string for the guest ("omacvm.fullpanel=L x R x H x W x D",
    /// one decimal, no spaces); omacvm-app-host puts it into
    /// /run/omacvm/host.env as OMACVM_FULLPANEL=..., which the bar and
    /// notchcast read.
    public var smbios: String { "omacvm.fullpanel=" + text }

    /// The panel's size for QEMU (OMACVM_FULLPANEL_PANEL, "WxD" in points): a
    /// full screen entered on another display takes the strip later only on
    /// a display of this size (omacvm-cocoa-fullpanel-late-arm.patch).
    public var panel: String { String(format: "%.1fx%.1f", width, height) }
}

/// This Mac's built-in display and its notch for one start (#716).
public enum MacNotch: Equatable, Sendable {
    /// The built-in display has a notch now: as measured.
    case now(NotchGeometry)
    /// The built-in display is off (the lid closed, external displays only):
    /// its notch as last measured on this Mac (NotchHousing).
    case remembered(NotchGeometry)
    /// No notch to use: a Mac without one, the built-in display on at a
    /// resolution below the notch or mirrored, or off with nothing remembered.
    case none

    /// live: measured now; builtinOff: no built-in display online
    /// (CoreGraphics); remembered: this Mac's NotchHousing value. A built-in
    /// display that is on never takes the remembered notch.
    public static func of(live: NotchGeometry?, builtinOff: Bool, remembered: NotchGeometry?) -> MacNotch {
        if let g = live, g.valid { return .now(g) }
        if builtinOff, let g = remembered, g.valid { return .remembered(g) }
        return .none
    }

    /// The notch a start may use, either way.
    public var geometry: NotchGeometry? {
        switch self {
        case .now(let g), .remembered(let g): return g
        case .none: return nil
        }
    }

    /// The word src/lib/notch.sh uses for it (notch_mac_state).
    public var word: String {
        switch self {
        case .now: return "notch"
        case .remembered: return "remembered"
        case .none: return "none"
        }
    }
}

/// The built-in display's notch as last measured on this Mac, for a start
/// with the lid closed (#716). Kept in the app's settings (`builtinNotch`,
/// org.omacvm.app; the test identity's own domain) as "<mac> LxRxHxWxD":
/// <mac> is this Mac's key (NotchHousing.macKey), so a settings file moved to
/// another Mac, or a VM folder copied there, never uses this Mac's notch.
/// Written whenever the app measures a notch (its launch, a display change,
/// a VM start); `defaults delete org.omacvm.app builtinNotch` forgets it.
public enum NotchHousing {
    public static let key = "builtinNotch"

    /// The first 16 hex digits of the SHA-256 of the Mac's IOPlatformUUID (the
    /// UUID itself is not stored); src/lib/notch.sh's notch_mac_key says the same.
    public static func macKey(hardwareID: String) -> String {
        SHA256.hash(data: Data(hardwareID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The value to keep for this Mac's notch.
    public static func entry(_ g: NotchGeometry, mac: String) -> String {
        "\(mac) \(g.text)"
    }

    /// The remembered notch when it is this Mac's and one a MacBook can have; else nil.
    public static func remembered(_ stored: String?, mac: String) -> NotchGeometry? {
        guard let parts = stored?.split(separator: " ", omittingEmptySubsequences: false), parts.count == 2,
              !mac.isEmpty, parts[0] == mac else { return nil }
        return NotchArea.geometry(text: String(parts[1]))
    }
}

/// What one start does with the strip.
public struct NotchStart: Equatable, Sendable {
    /// QEMU gets OMACVM_FULLPANEL=1, the guest the geometry, Omanotch nothing.
    public var fullPanel: Bool
    /// For qemu.log ("OmacVM: notch area: ..."), which omacvm check and
    /// `omacvm notch` read: starts with "fullpanel" or "native".
    public var record: String
    /// The notch a FullPanel start gives the guest (SMBIOS) and QEMU (its
    /// panel's size); nil for a native start.
    public var geometry: NotchGeometry?

    public init(fullPanel: Bool, record: String, geometry: NotchGeometry? = nil) {
        self.fullPanel = fullPanel; self.record = record; self.geometry = geometry
    }
}

public enum NotchArea {
    /// The VM folder's file: "fullpanel"; none (or anything else) is native.
    public static let fileName = "notch-mode"
    /// The qemu.log line's start.
    public static let logPrefix = "OmacVM: notch area: "
    /// Written by `omacvm apply` when the VM's side can do it: Omanotch's
    /// bar with the FullPanel mode and notchcast that stays off for such a
    /// start (feature omanotch on). Without it a start stays native: an
    /// older VM would put its bar under the camera housing.
    public static let readyFileName = "fullpanel-ready"

    public static func guestReady(folder: URL, features: String?) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(readyFileName).path) &&
            !(features ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).contains("omanotch=off")
    }

    public static func mode(_ text: String?) -> NotchMode {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) == NotchMode.fullpanel.rawValue ? .fullpanel : .native
    }

    public static func read(folder: URL) -> NotchMode {
        mode(try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8))
    }

    /// Native removes the file (none is native), FullPanel writes it.
    public static func write(_ m: NotchMode, folder: URL) throws {
        let url = folder.appendingPathComponent(fileName)
        switch m {
        case .fullpanel:
            try "fullpanel\n".write(to: url, atomically: true, encoding: .utf8)
        case .native:
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// A notch as text ("LxRxHxWxD" in points, as the SMBIOS string): the
    /// remembered one (NotchHousing), or a made-up one for tests on a Mac
    /// without one (the app's OMACVM_TEST_NOTCH_GEOMETRY, test builds only);
    /// nil when malformed or not a notch a MacBook can have.
    public static func geometry(text: String?) -> NotchGeometry? {
        guard let parts = text?.split(separator: "x", omittingEmptySubsequences: false).map({ Double($0) }), parts.count == 5,
              let l = parts[0], let r = parts[1], let h = parts[2], let w = parts[3], let d = parts[4] else { return nil }
        let g = NotchGeometry(left: l, right: r, strip: h, width: w, height: d)
        return g.valid ? g : nil
    }

    /// macOS keeps the menu bar in full screen ("Automatically hide and show
    /// the menu bar: never", NSGlobalDomain AppleMenuBarVisibleInFullscreen;
    /// #356). With Keep the Dock away on, QEMU's immersive full screen hides it
    /// anyway; without, a FullPanel start goes below it.
    public static func menuBarAlwaysShown(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: "AppleMenuBarVisibleInFullscreen") as? Bool ?? false
    }

    /// What the VM window says under the switch while FullPanel is set but
    /// the VM's side is not ready (guestReady); nil: nothing to say.
    public static let notReady = "Including notch needs Omanotch on in the VM and an update first (Update VM); until then it starts with the notch via Omanotch."

    /// One start: FullPanel only with the setting on, a full-screen start, a
    /// notch (the built-in display's now, or with that display off its notch
    /// as last measured on this Mac, #716) and the VM's side ready; else
    /// native, and the record says why. Native also means Omanotch as the
    /// VM's features say (on by default with a notch).
    public static func start(mode: NotchMode, fullScreen: Bool, notch: MacNotch, guestReady: Bool) -> NotchStart {
        guard mode == .fullpanel else { return NotchStart(fullPanel: false, record: "native") }
        guard guestReady else {
            return NotchStart(fullPanel: false, record: "native (including notch is set, but the VM is not ready for it: Omanotch on, then Update VM or omacvm apply)")
        }
        guard fullScreen else {
            return NotchStart(fullPanel: false, record: "native (including notch is set, but the app starts VMs in a window)")
        }
        switch notch {
        case .now(let g) where g.valid:
            return NotchStart(fullPanel: true, record: String(format: "fullpanel (Omanotch off for this start; notch %.1f-%.1f, strip %.1f of %.0fx%.0f points)",
                                                             g.left, g.right, g.strip, g.width, g.height), geometry: g)
        case .remembered(let g) where g.valid:
            return NotchStart(fullPanel: true, record: String(format: "fullpanel (Omanotch off for this start; the built-in display is off, its notch as last seen: notch %.1f-%.1f, strip %.1f of %.0fx%.0f points)",
                                                             g.left, g.right, g.strip, g.width, g.height), geometry: g)
        default:
            return NotchStart(fullPanel: false, record: "native (including notch is set, but this Mac's built-in display has no notch now)")
        }
    }
}

/// Skip the notch (off by default): on the bar beside the notch, items that
/// do not fit on their side continue on its other side (Omanotch's bar
/// patch, `notchSkipPlace`), in either full screen. The VM folder's
/// `notch-skip` file ("on"; none is off), the same as `omacvm notch --skip`
/// and the control centre's row. The VM gets it at each start (SMBIOS
/// omacvm.notchskip=1 -> host.env OMACVM_NOTCHSKIP=1) and, while it runs, as
/// soon as the file changes (NotchSkipLive: /run/omacvm/notch-skip through
/// the guest agent), which the bar reads every 3 s.
public enum NotchSkip {
    public static let fileName = "notch-skip"
    /// Written by `omacvm apply` when the VM's Omanotch bar can do it.
    public static let readyFileName = "notch-skip-ready"
    /// For QEMU's -smbios type=11 (only when on).
    public static let smbios = "omacvm.notchskip=1"

    public static func on(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines) == "on"
    }

    public static func read(folder: URL) -> Bool {
        on(try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8))
    }

    /// On writes the file, off removes it.
    public static func write(_ on: Bool, folder: URL) throws {
        let url = folder.appendingPathComponent(fileName)
        if on {
            try "on\n".write(to: url, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The VM's bar can do it: apply's marker, and Omanotch not off.
    public static func guestReady(folder: URL, features: String?) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(readyFileName).path) &&
            !(features ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).contains("omanotch=off")
    }

    /// What tells a running VM (root, through the guest agent): a fixed
    /// command, written in one step so the bar never reads half a file.
    public static func guestCommand(_ on: Bool) -> (path: String, args: [String]) {
        let f = "/run/omacvm/notch-skip"
        return ("/bin/sh", ["-c", "mkdir -p /run/omacvm && printf \(on ? 1 : 0) > \(f).new && mv -f \(f).new \(f)"])
    }

    /// The VM window's line under the row when it is on but the VM's bar
    /// cannot do it yet.
    public static let notReady = "Needs Omanotch on in the VM and an update first (Update VM)."
}

/// While a VM runs: when to tell it the setting again. It got the file's
/// value at the start; a change goes to it at the next look, and, while the
/// value differs from the start's, again now and then (a reboot inside the VM
/// loses /run, and QEMU's SMBIOS still says the start's value).
public struct NotchSkipLive: Sendable {
    public let atStart: Bool
    public private(set) var told: Bool?
    private var toldAt: Date?
    public static let again: TimeInterval = 30

    public init(atStart: Bool) { self.atStart = atStart }

    public func due(_ now: Bool, at date: Date) -> Bool {
        if now != (told ?? atStart) { return true }
        if now != atStart, let t = toldAt, date.timeIntervalSince(t) >= Self.again { return true }
        return false
    }

    public mutating func sent(_ value: Bool, at date: Date) {
        told = value
        toldAt = date
    }
}
