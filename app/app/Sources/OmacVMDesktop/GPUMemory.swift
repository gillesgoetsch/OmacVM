import Foundation

/// The VM's graphics memory on the Mac: textures and buffers its apps draw
/// with. It comes from the Mac's memory as the VM needs it, on top of the VM's
/// own memory. QEMU writes it to logs/gpu-memory (virgl-darwin-memory-pressure.patch
/// and virgl-gpu-guard-desktop-reserve.patch): in use now, the peak since the VM
/// started, the budget and the part of it kept for the VM's desktop, macOS's
/// memory pressure, how many allocations were refused and which GPU contexts
/// were lost, why, and whether each was a GL (virgl) or a Vulkan (Venus)
/// context (virgl-venus-lost-context-count.patch). Foundation only:
/// `swift run desktop-tests`.
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
    /// memory), venus (a Vulkan context whose commands were refused on the
    /// Mac) or error (anything else). Empty from an older runtime.
    public var lostRecent: [String] = []
    public var lostRecentWhy: [String] = []
    /// gl or venus for each of `lostRecent` (3.2.17; empty before: all gl).
    public var lostRecentKind: [String] = []

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
            case "lost_recent_kind": m.lostRecentKind = kv[1].split(separator: ",").map(String.init)
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

    /// The VM's memory, its graphics and Activity Monitor's number, for every
    /// (i) that explains them: the VM header's and General's Resources row's
    /// (resourcesInfo). Measured numbers only: the 2-5 GB at 5K from the
    /// field (2.1 GB, and 4.5 GB at the peak, on a 16 GB Mac mini with
    /// Chrome), the counted-twice row from ADR 0062 (from before QEMU's sweep,
    /// ADR 0066: macOS counts what QEMU touched twice, compressed or not).
    public static let explanation = """
        VM memory is the VM's RAM: Linux sees exactly this much, and the Mac gives it \
        as the VM uses it. What Linux frees goes back to the Mac and leaves QEMU's \
        footprint, the number Activity Monitor shows for the VM. While macOS compresses \
        the VM, the VM gives back the file cache it has not used lately; when macOS warns \
        that memory is short, it drops its whole file cache. Graphics memory comes on \
        top: the textures and buffers the VM's desktop and apps draw with, taken from the \
        Mac's memory as they need it (a 5K desktop with a browser: 2 to 5 GB). \
        New ones for apps are refused when macOS itself runs short, or when all of them \
        together reach three quarters of the Mac's memory less a part kept for the \
        desktop itself, so an app that takes too much stops, not the desktop. \
        Activity Monitor can show more for the VM than both together: a page of the VM \
        that QEMU itself touched (disk, graphics, network) counts twice there until \
        QEMU's next sweep, every 5 minutes; that is no memory (a 4 GB VM after a browser \
        session, before the sweep: 5.9 GB shown, 2.1 GB of it counted twice). omacvm \
        check shows what the number is made of.
        """

    /// The last run's graphics, for the same two (i)s; nil: no run yet (or
    /// a runtime without the status file).
    public static func lastRun(_ last: GPUMemory?) -> String {
        last.map { "Graphics memory last run: peak \(gb($0.peakMB)), from the Mac on top." }
            ?? "Graphics memory comes from the Mac on top, as the VM needs it."
    }

    /// The (i) beside Resources (General): CPUs, then the VM's memory and its
    /// graphics in the header (i)'s own words.
    public static func resourcesInfo(_ last: GPUMemory?) -> String {
        "CPUs are the Mac's cores the VM may use at once. A change applies at the VM's next start. "
            + "\(lastRun(last))\n\n\(explanation)"
    }
}

/// An app in the VM (not the desktop or the shell) lost its GPU context
/// because the VM's graphics memory was full or macOS was short of memory:
/// the VM says so (omacvm-desktop-recover app; from 3.2.15 it also ends the
/// app's GPU process), so the app's black window or reload has a reason.
/// A Vulkan (Venus) context lost because the Mac refused its commands, or
/// to the guard, gets its own note (omacvm-desktop-recover venus, 3.2.17:
/// nothing is ended; a Ghostty on Zink starts on the CPU next time).
/// One per VM run (GPUMemoryWatch), looked at every 5 s.
public struct GPUMemoryNotice {
    /// Once a minute per app at most (a browser's GPU process can be lost
    /// again as it comes back). A loss inside the minute is kept, the newest
    /// per app, and told when the minute is over: dropped, an app lost again
    /// right after it came back stayed blank with nothing said.
    public static let window: TimeInterval = 60

    public struct Tell: Equatable {
        public let name: String
        /// guard, pressure or venus
        public let why: String
        /// When the loss told now was seen; nil: seen in this look.
        public let heldSince: Date?
        /// A Vulkan (Venus) context: the VM gets omacvm-desktop-recover venus.
        public var venus = false
    }

    /// The last tell per app, kept only for the minute after it.
    private var told: [String: Date] = [:]
    /// The newest loss per app told within the minute, and when it was seen.
    private var held: [String: (why: String, since: Date, venus: Bool)] = [:]

    public init() {}

    /// Apps told within the last minute (at the last look).
    public var recent: Int { told.count }
    /// Apps with a loss kept for the end of their minute.
    public var waiting: [String] { held.keys.sorted() }

    /// Every look, also with nothing new (so kept losses come out). `lost`
    /// and `why`: the contexts lost since the last look, with the same count
    /// (else none are new); `kind`: gl or venus for each (another count, or
    /// none from an older runtime: all gl). Apps lost to the guard or to
    /// pressure, and Vulkan contexts lost to the guard or refused on the Mac
    /// (venus), never the desktop or the shell, the newest per app: told
    /// now, or kept when the app was told less than a minute ago. New ones
    /// first, in their order, then kept ones whose minute is over, by name.
    public mutating func look(lost: [String], why: [String], kind: [String] = [], now: Date) -> [Tell] {
        told = told.filter { now.timeIntervalSince($0.value) < Self.window }
        var new: [(name: String, why: String, venus: Bool)] = []
        if lost.count == why.count {
            let venus = kind.count == lost.count ? kind.map { $0 == "venus" } : Array(repeating: false, count: lost.count)
            for (i, name) in lost.enumerated() {
                let w = why[i], v = venus[i]
                guard w == "guard" || (!v && w == "pressure") || (v && w == "venus") else { continue }
                if DesktopRecovery.compositors.contains(name) || DesktopRecovery.shells.contains(name) { continue }
                if let j = new.firstIndex(where: { $0.name == name }) { new[j] = (name, w, v) } else { new.append((name, w, v)) }
            }
        }
        var out: [Tell] = []
        for app in new {
            if told[app.name] != nil {
                held[app.name] = (app.why, now, app.venus)
            } else {
                held[app.name] = nil
                told[app.name] = now
                out.append(Tell(name: app.name, why: app.why, heldSince: nil, venus: app.venus))
            }
        }
        for name in held.keys.sorted() where told[name] == nil {
            let h = held.removeValue(forKey: name)!
            told[name] = now
            out.append(Tell(name: name, why: h.why, heldSince: h.since, venus: h.venus))
        }
        return out
    }

    /// The VM's desktop session was restarted: its apps were closed, so the
    /// losses kept for them are void.
    public mutating func sessionRestarted() {
        held = [:]
    }
}
