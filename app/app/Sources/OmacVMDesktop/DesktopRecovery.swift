import Foundation

/// What the app does when a GPU context of the VM's desktop is lost on the
/// Mac (QEMU names it in logs/gpu-memory). The VM is not told by its own
/// graphics stack, so the app tells it through the guest agent and the VM's
/// omacvm-desktop-recover acts:
/// - Hyprland lost: it draws black from then on. The desktop session starts
///   again by itself; apps open in the VM close and their unsaved work is
///   lost (the new session names them). At most once in `window`: when it
///   is lost again that soon, the app asks instead (a cause that stays, such
///   as macOS short of memory, would only repeat it).
/// - The shell lost (Omarchy's bar and launcher, Quickshell): only the shell
///   starts again, no app closes. At most once a minute.
/// - A Vulkan (Venus) context never restarts anything, whatever its name:
///   the desktop and the shell draw with GL, and a lost Venus context is one
///   app's (GPUMemoryNotice gives it a note).
/// Off: the app asks every time, as up to 3.0.0.
/// Hidden: defaults write org.omacvm.app desktopAutoRestart -bool false
///
/// The rules on their own (Foundation only): src/tests/app-desktop-recovery.sh.
public enum DesktopRecovery {
    public static let key = "desktopAutoRestart"
    public static let window: TimeInterval = 600
    public static let shellWindow: TimeInterval = 60
    /// The compositor draws the whole desktop. QEMU keeps the last part of
    /// the graphics memory for these, the shell and the lock screen (hyprlock)
    /// (its VIRGL_GPU_GUARD_DESKTOP_DEFAULT, virgl-gpu-guard-desktop-reserve.patch).
    public static let compositors: Set<String> = ["Hyprland"]
    public static let shells: Set<String> = ["quickshell"]

    public enum Action: Equatable {
        case none
        /// Restart the desktop session without asking.
        case restartDesktop
        /// Ask (the alert with "Restart the Desktop"); `again`: it was
        /// restarted shortly before.
        case ask(again: Bool)
        case restartShell
    }

    public static func enabled(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: key) as? Bool ?? true
    }

    /// `lost`: the contexts lost since the last look; `kinds`: gl or venus
    /// for each (another count, or none from an older runtime: all gl).
    /// `lastDesktop`: when the desktop was last restarted (by itself or with
    /// the button); `lastShell`: when the shell was.
    public static func action(lost: [String], kinds: [String] = [], enabled: Bool, lastDesktop: Date?,
                              lastShell: Date?, now: Date) -> Action {
        let lost = kinds.count == lost.count ? zip(lost, kinds).filter { $0.1 != "venus" }.map(\.0) : lost
        if lost.contains(where: compositors.contains) {
            guard enabled else { return .ask(again: false) }
            if let t = lastDesktop, now.timeIntervalSince(t) < window { return .ask(again: true) }
            return .restartDesktop
        }
        if enabled, lost.contains(where: shells.contains) {
            if let t = lastShell, now.timeIntervalSince(t) < shellWindow { return .none }
            return .restartShell
        }
        return .none
    }

    /// What omacvm-desktop-recover is told about the cause. `why`: what QEMU
    /// said for the desktop's context (guard, pressure, error; nil from a
    /// runtime before 3.0.5, then guessed from the pressure and refusals).
    /// A VM from before 3.0.5 takes "guard" as "graphics".
    public static func reason(why: String?, pressure: String, refused: Int) -> String {
        switch why {
        case "guard": return "guard"
        case "pressure": return "memory"
        case "error": return "graphics"
        default: return pressure == "normal" && refused == 0 ? "graphics" : "memory"
        }
    }
}
