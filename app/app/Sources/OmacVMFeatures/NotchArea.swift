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

    public func title(hasNotch: Bool) -> String {
        switch self {
        case .window: return "Window"
        case .fullScreen: return hasNotch ? "Full screen, notch via Omanotch" : "Full screen"
        case .fullScreenNotch: return "Full screen including notch, no Omanotch needed (experimental)"
        }
    }

    /// The closed picker's text (the menu has the whole title): including
    /// notch says the rest in the row's note (notchNote).
    public func shortTitle(hasNotch: Bool) -> String {
        self == .fullScreenNotch ? "Full screen including notch" : title(hasNotch: hasNotch)
    }

    /// Under the picker while including notch is chosen.
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

    /// The (i) text of the picker.
    public static func info(hasNotch: Bool) -> String {
        var t = "Window: the VM starts in a window. Full screen: the VM starts in macOS full screen."
        if hasNotch {
            t = "Window: the VM starts in a window. Full screen, notch via Omanotch: macOS full screen below the camera notch; Omanotch shows Omarchy's bar in the strip beside it.\n\nFull screen including notch, no Omanotch needed (experimental). The VM uses the whole built-in display, including the strip beside the camera notch, and draws its bar there itself. Omanotch is not needed for this. Experimental. External displays stay as they are."
        }
        return t + (hasNotch ? "\n\nWindow and full screen are for every VM; the notch choice is this VM's." : "") + " From the VM's next start."
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

    /// The SMBIOS OEM string for the guest ("omacvm.fullpanel=L x R x H x W x D",
    /// one decimal, no spaces); omacvm-app-host puts it into
    /// /run/omacvm/host.env as OMACVM_FULLPANEL=..., which the bar and
    /// notchcast read.
    public var smbios: String {
        "omacvm.fullpanel=" + [left, right, strip, width, height]
            .map { String(format: "%.1f", $0) }.joined(separator: "x")
    }
}

/// What one start does with the strip.
public struct NotchStart: Equatable, Sendable {
    /// QEMU gets OMACVM_FULLPANEL=1, the guest the geometry, Omanotch nothing.
    public var fullPanel: Bool
    /// For qemu.log ("OmacVM: notch area: ..."), which omacvm check and
    /// `omacvm notch` read: starts with "fullpanel" or "native".
    public var record: String

    public init(fullPanel: Bool, record: String) {
        self.fullPanel = fullPanel; self.record = record
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

    /// A made-up notch for tests on a Mac without one ("LxRxHxWxD" in points,
    /// as the SMBIOS string; the app's OMACVM_TEST_NOTCH_GEOMETRY, test builds
    /// only); nil when malformed or not a notch a MacBook can have.
    public static func geometry(test text: String?) -> NotchGeometry? {
        guard let parts = text?.split(separator: "x").map({ Double($0) }), parts.count == 5,
              let l = parts[0], let r = parts[1], let h = parts[2], let w = parts[3], let d = parts[4] else { return nil }
        let g = NotchGeometry(left: l, right: r, strip: h, width: w, height: d)
        return g.valid ? g : nil
    }

    /// What the VM window says under the switch while FullPanel is set but
    /// the VM's side is not ready (guestReady); nil: nothing to say.
    public static let notReady = "Including notch needs Omanotch on in the VM and an update first (Update VM); until then it starts with the notch via Omanotch."

    /// One start: FullPanel only with the setting on, a full-screen start, a
    /// notched built-in display now (its geometry valid) and the VM's side
    /// ready; else native, and the record says why. Native also means
    /// Omanotch as the VM's features say (on by default with a notch).
    public static func start(mode: NotchMode, fullScreen: Bool, notch: NotchGeometry?, guestReady: Bool) -> NotchStart {
        guard mode == .fullpanel else { return NotchStart(fullPanel: false, record: "native") }
        guard guestReady else {
            return NotchStart(fullPanel: false, record: "native (including notch is set, but the VM is not ready for it: Omanotch on, then Update VM or omacvm apply)")
        }
        guard fullScreen else {
            return NotchStart(fullPanel: false, record: "native (including notch is set, but the app starts VMs in a window)")
        }
        guard let g = notch, g.valid else {
            return NotchStart(fullPanel: false, record: "native (including notch is set, but this Mac's built-in display has no notch now)")
        }
        return NotchStart(fullPanel: true, record: String(format: "fullpanel (Omanotch off for this start; notch %.1f-%.1f, strip %.1f of %.0fx%.0f points)",
                                                         g.left, g.right, g.strip, g.width, g.height))
    }
}
