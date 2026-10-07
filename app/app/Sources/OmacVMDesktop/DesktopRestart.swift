import Foundation

/// The way back after "Later" on the "desktop stopped drawing" window.
///
/// The app (GPUMemory.swift) writes `logs/desktop-lost` when the user picks
/// Later. While it is there, QEMU's app menu shows "Restart the Desktop…"
/// (omacvm-cocoa-restart-desktop.patch: OMACVM_DESKTOP_LOST names the file).
/// A click posts a distributed notification under `requestName`
/// (OMACVM_DESKTOP_RESTART_REQUEST), as "Features…" does, and the app shows
/// the window again. Apart from the UI so it can be tested without a VM:
/// `swift run desktop-tests`.
public struct DesktopRestart: Sendable {
    /// Written by the app on Later; QEMU only checks that it is a plain file.
    public let lost: URL
    /// The notification QEMU's menu item posts: this app's id and process id,
    /// so a second running app (another VM) does not get it.
    public let requestName: String

    public init(logs: URL, bundleID: String?, pid: Int32) {
        lost = logs.appendingPathComponent("desktop-lost")
        requestName = "\(bundleID ?? "org.omacvm.app").desktop-restart.\(pid)"
    }

    public var isLost: Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: lost.path, isDirectory: &dir) && !dir.boolValue
    }

    /// Later: the menu item shows from now on.
    @discardableResult
    public func markLost(_ why: String) -> Bool {
        (try? Data("\(why)\n".utf8).write(to: lost, options: .atomic)) != nil
    }

    /// The desktop is restarting, or the VM starts or stops: no menu item.
    public func clear() {
        try? FileManager.default.removeItem(at: lost)
    }

    /// A click on the menu item counts only while the desktop is lost (a
    /// notification from before, or posted by something else, does nothing).
    public func takesRequest() -> Bool { isLost }
}
