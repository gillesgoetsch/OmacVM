import Foundation

/// The VM's graphics memory on the Mac: textures and buffers its apps draw
/// with. It comes from the Mac's memory as the VM needs it, on top of the VM's
/// own memory. QEMU writes it to logs/gpu-memory (virgl-darwin-memory-pressure.patch
/// and virgl-gpu-guard-desktop-reserve.patch): in use now, the peak since the VM
/// started, the budget and the part of it kept for the VM's desktop, macOS's
/// memory pressure, how many allocations were refused and which GPU contexts
/// were lost, and why. Foundation only: `swift run desktop-tests`.
public struct GPUMemory: Equatable {
    public var inUseMB = 0
    public var peakMB = 0
    public var budgetMB = 0
    /// How far apps may go; the rest of the budget is kept for the desktop
    /// (Hyprland, the shell). 0 from a runtime without the reserve.
    public var appsMB = 0
    public var reserveMB = 0
    public var pressure = "normal"
    public var refused = 0
    public var lost = 0
    public var lostLast = ""
    /// The last eight lost contexts, oldest first, and why each was lost:
    /// guard (the budget, or an app past its share), pressure (macOS short of
    /// memory) or error (anything else). Empty from an older runtime.
    public var lostRecent: [String] = []
    public var lostRecentWhy: [String] = []

    public init() {}

    public static func parse(_ text: String) -> GPUMemory? {
        var m = GPUMemory()
        var seen = false
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let n = Int(kv[1]) ?? 0
            switch kv[0] {
            case "in_use_mb": m.inUseMB = n; seen = true
            case "peak_mb": m.peakMB = n
            case "budget_mb": m.budgetMB = n
            case "apps_mb": m.appsMB = n
            case "reserve_mb": m.reserveMB = n
            case "pressure": m.pressure = kv[1]
            case "refused": m.refused = n
            case "lost": m.lost = n
            case "lost_last": m.lostLast = kv[1]
            case "lost_recent": m.lostRecent = kv[1].split(separator: ",").map(String.init)
            case "lost_recent_why": m.lostRecentWhy = kv[1].split(separator: ",").map(String.init)
            default: break
            }
        }
        return seen ? m : nil
    }

    public static func gb(_ mb: Int) -> String {
        mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
    }

    /// Why the last of `names` to be lost was lost (guard, pressure, error),
    /// nil when QEMU did not say (a runtime from before 3.0.5).
    public func why(of names: Set<String>) -> String? {
        guard lostRecentWhy.count == lostRecent.count,
              let i = lostRecent.lastIndex(where: names.contains) else { return nil }
        return lostRecentWhy[i]
    }

    /// Why the desktop (Hyprland) lost its context, for the alert. QEMU says
    /// why; from an older runtime it is guessed: a refusal with macOS's
    /// pressure normal and the graphics in use at the budget came from the
    /// budget (on an 8 GB Mac a browser with big WebGL pages gets there while
    /// macOS still says normal: Air M2, 2026-10-06). In use, not the peak: the
    /// peak counts from the VM's start.
    public var lostReason: String {
        switch why(of: DesktopRecovery.compositors) {
        case "guard": return budgetReason
        case "pressure": return "macOS ran short of memory for its graphics."
        case "error": return "Its graphics on the Mac failed."
        default: break
        }
        if refused == 0 && pressure == "normal" { return "Its graphics on the Mac failed." }
        if pressure == "normal" && budgetMB > 0 && inUseMB + 512 >= budgetMB { return budgetReason }
        return "macOS ran short of memory for its graphics."
    }

    private var budgetReason: String {
        let most = "Its graphics reached the most one VM may use on this Mac (\(GPUMemory.gb(budgetMB))"
        return reserveMB > 0 ? most + ", even with the \(GPUMemory.gb(reserveMB)) kept for the desktop)." : most + ")."
    }

    /// "Graphics memory: 1.6 GB (peak 2.6 GB)"
    public var line: String { "Graphics memory: \(GPUMemory.gb(inUseMB)) (peak \(GPUMemory.gb(peakMB)))" }

    public static let explanation = """
        VM memory is the Mac memory the VM gets as its RAM (set above). What Linux frees \
        goes back to the Mac and leaves QEMU's footprint, the number Activity Monitor \
        shows for the VM. While macOS compresses the VM, the VM gives back the file cache \
        it has not used lately; when macOS warns that memory is short, it drops its whole \
        file cache. Graphics memory is extra: the textures and buffers the VM's \
        desktop and apps draw with, taken from the Mac's memory as they need it (a 5K \
        desktop with a browser: about 2 GB). \
        New ones for apps are refused when macOS itself runs short, or when all of them \
        together reach three quarters of the Mac's memory less a part kept for the \
        desktop itself, so an app that takes too much stops, not the desktop.
        """
}

/// An app in the VM (not the desktop or the shell) lost its GPU context
/// because the VM's graphics memory was full or macOS was short of memory:
/// the VM says so, so the app's black window or reload has a reason.
public enum GPUMemoryNotice {
    /// Once a minute per app at most (a browser's GPU process can be lost
    /// again as it comes back).
    public static let window: TimeInterval = 60

    /// Of the contexts lost since the last look (names, and why with the same
    /// count, else none are told), the apps to tell about: guard or pressure,
    /// not the desktop or the shell, each once.
    public static func apps(lost: [String], why: [String], lastTold: [String: Date], now: Date) -> [(name: String, why: String)] {
        guard lost.count == why.count else { return [] }
        var out: [(name: String, why: String)] = []
        for (name, w) in zip(lost, why) where w == "guard" || w == "pressure" {
            if DesktopRecovery.compositors.contains(name) || DesktopRecovery.shells.contains(name) { continue }
            if out.contains(where: { $0.name == name }) { continue }
            if let t = lastTold[name], now.timeIntervalSince(t) < window { continue }
            out.append((name, w))
        }
        return out
    }
}
