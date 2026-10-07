import Foundation

/// One OmacVM in the Dock. The VM's window belongs to QEMU, a plain
/// executable inside the app (Contents/Resources/runtime/bin/OmacVM). macOS
/// gave such a program an app identity of its own: a second icon in the Dock,
/// and "Keep in Dock" on it kept that bare program, which shows a blank icon
/// and starts no VM once the VM is off.
///
/// QEMU is started through a link in Contents/MacOS (build-app.sh makes it).
/// AppKit and LaunchServices take the app from the path a program was started
/// by, so QEMU counts as this app: while the VM runs, the app's own Dock icon
/// is the VM's (the launcher steps out of the Dock), a click on it brings the
/// VM to the front, and "Keep in Dock" keeps OmacVM.app. The kernel follows
/// the link: the process's path (proc_pidpath) and name (proc_name) stay
/// runtime/bin/OmacVM and "OmacVM", which Gestures, Omanotch, Bridge and the
/// self-update look at; the executable and its signature are the same file.
/// (CFProcessPath, the older way, is ignored under the hardened runtime:
/// MacBook Air, macOS 26.6.2, 2026-10-06.) Without the link (an older or a
/// development build) or with OMACVM_DOCK_SEPARATE=1, QEMU starts from its
/// own path and the Dock shows two icons as before.
enum DockIdentity {
    /// The link's name in Contents/MacOS.
    static let linkName = "OmacVM-VM"

    /// What to start for QEMU at QEMU: the link in BUNDLE when it is there
    /// and points at QEMU, else QEMU itself.
    static func launchPath(qemu: String, bundle: String, env: [String: String]) -> String {
        guard env["OMACVM_DOCK_SEPARATE"].map({ $0.isEmpty || $0 == "0" }) ?? true, bundle.hasSuffix(".app") else { return qemu }
        let link = bundle + "/Contents/MacOS/" + linkName
        guard let a = realpath(link), let b = realpath(qemu) else { return qemu }
        return a == b ? link : qemu
    }

    /// For qemu.log and omacvm check.
    static func record(launch: String, qemu: String) -> String {
        launch == qemu ? "dock: QEMU on its own" : "dock: one app (QEMU started as \(launch))"
    }

    private static func realpath(_ p: String) -> String? {
        guard let r = Darwin.realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }
}
