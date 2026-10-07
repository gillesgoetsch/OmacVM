import AppKit
import Foundation
import OmacVMDesktop

/// The VM's graphics memory on the Mac: textures and buffers its apps draw
/// with. It comes from the Mac's memory as the VM needs it, on top of the VM's
/// own memory. QEMU writes it to logs/gpu-memory (virgl-darwin-memory-pressure.patch):
/// in use now, the peak since the VM started, macOS's memory pressure, how many
/// allocations were refused and which GPU context was lost last.
struct GPUMemory: Equatable {
    var inUseMB = 0
    var peakMB = 0
    var budgetMB = 0
    var pressure = "normal"
    var refused = 0
    var lost = 0
    var lostLast = ""
    /// The last eight lost contexts, oldest first.
    var lostRecent: [String] = []

    static func file(for config: VMConfig) -> URL {
        config.folder.appendingPathComponent("logs/gpu-memory")
    }

    static func read(for config: VMConfig) -> GPUMemory? {
        guard let text = try? String(contentsOf: file(for: config), encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> GPUMemory? {
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
            case "pressure": m.pressure = kv[1]
            case "refused": m.refused = n
            case "lost": m.lost = n
            case "lost_last": m.lostLast = kv[1]
            case "lost_recent": m.lostRecent = kv[1].split(separator: ",").map(String.init)
            default: break
            }
        }
        return seen ? m : nil
    }

    static func gb(_ mb: Int) -> String {
        mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
    }

    /// Why a context was lost, for the alert. A refusal with macOS's pressure
    /// normal and the graphics in use at the budget came from the budget (all
    /// graphics together at three quarters of the Mac), not from macOS running
    /// short: on an 8 GB Mac a browser with big WebGL pages gets there while
    /// macOS still says normal (Air M2, 2026-10-06). In use, not the peak: the
    /// peak counts from the VM's start, so after one hit every later loss
    /// would blame the budget.
    var lostReason: String {
        if refused == 0 && pressure == "normal" { return "Its graphics on the Mac failed." }
        if pressure == "normal" && budgetMB > 0 && inUseMB + 512 >= budgetMB {
            return "Its graphics reached the most one VM may use on this Mac (\(GPUMemory.gb(budgetMB)))."
        }
        return "macOS ran short of memory for its graphics."
    }

    /// "Graphics memory: 1.6 GB (peak 2.6 GB)"
    var line: String { "Graphics memory: \(GPUMemory.gb(inUseMB)) (peak \(GPUMemory.gb(peakMB)))" }

    static let explanation = """
        VM memory is the Mac memory the VM gets as its RAM (set above). Graphics memory \
        is extra: the textures and buffers the VM's desktop and apps draw with, taken \
        from the Mac's memory as they need it (a 5K desktop with a browser: about 2 GB). \
        New ones are refused when macOS itself runs short, or when all of them together \
        reach three quarters of the Mac's memory.
        """
}

/// While a VM runs: follows its graphics memory and macOS's memory pressure.
/// - When macOS warns that memory is short, the VM is asked to drop its file
///   cache (at most every 10 minutes): Linux then reports the pages free and
///   the Mac gets them back (virtio-balloon free page reporting).
/// - When the desktop's GPU context is lost (the VM would stay black), the
///   desktop session starts again by itself, or a window says so and offers
///   to restart it (DesktopRecovery says which). After Later, QEMU's app menu
///   has "Restart the Desktop…", which shows the window again (DesktopRestart).
@MainActor
final class GPUMemoryWatch {
    private let config: VMConfig
    private let log: (String) -> Void
    private var timer: Timer?
    private var pressure: DispatchSourceMemoryPressure?
    private var lastTrim = Date.distantPast
    private var trimming = false
    private var lostSeen = 0
    private var alert: NSAlert?
    private var lastDesktopRestart: Date?
    private var lastShellRestart: Date?
    private let restart: DesktopRestart
    private var restartObserver: NSObjectProtocol?
    /// What the window said when the user picked Later: it says the same when
    /// it comes again from the menu (by then the numbers have changed).
    private var laterWith: (m: GPUMemory, again: Bool)?
    /// After stop() nothing writes desktop-lost again (a window the stop
    /// closed, a restart answered late).
    private var stopped = false

    init(config: VMConfig, log: @escaping (String) -> Void) {
        self.config = config
        self.log = log
        restart = DesktopRestart(for: config)
    }

    func start() {
        stopped = false
        restart.clear()
        restartObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(restart.requestName), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartChosen() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            Task { @MainActor in self?.macOSShort(critical: event.contains(.critical)) }
        }
        source.resume()
        pressure = source
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressure?.cancel()
        pressure = nil
        stopped = true
        if let o = restartObserver { DistributedNotificationCenter.default().removeObserver(o) }
        restartObserver = nil
        restart.clear()
        if let w = alert?.window, w.isVisible { NSApp.abortModal(); w.orderOut(nil) }
    }

    private func macOSShort(critical: Bool) {
        guard !trimming, Date().timeIntervalSince(lastTrim) > 600 else { return }
        trimming = true
        let socket = config.agentSocket.path
        let level = critical ? "critical" : "warning"
        log("OmacVM: macOS memory pressure \(level): asking the VM to drop its file cache")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = GuestAgent.run(socketPath: socket, "/bin/sh", ["-c", "sync; echo 1 > /proc/sys/vm/drop_caches"])
            Task { @MainActor in self?.trimmed(ok) }
        }
    }

    /// Done once per 10 minutes when the VM did it; when its agent did not
    /// answer (still starting, busy), tried again in 30 seconds.
    private func trimmed(_ ok: Bool) {
        trimming = false
        if ok {
            lastTrim = Date()
            log("OmacVM: the VM dropped its file cache")
        } else {
            lastTrim = Date().addingTimeInterval(-600 + 30)
            log("OmacVM: the VM's agent did not answer: trying again in 30 s")
        }
    }

    private func poll() {
        guard let m = GPUMemory.read(for: config) else { return }
        // macOS tells only some processes about a warning, one at a time; QEMU
        // also looks for itself once a second and writes what it sees.
        if m.pressure != "normal" { macOSShort(critical: m.pressure == "critical") }
        if m.lost > lostSeen {
            // Several can be lost between two looks (the desktop, then a browser).
            let new = m.lostRecent.suffix(min(m.lost - lostSeen, m.lostRecent.count))
            lostSeen = m.lost
            lost(Array(new), m)
        }
    }

    private func lost(_ names: [String], _ m: GPUMemory) {
        guard alert == nil else { return }
        let now = Date()
        let action = DesktopRecovery.action(lost: names, enabled: DesktopRecovery.enabled(),
                                            lastDesktop: lastDesktopRestart, lastShell: lastShellRestart, now: now)
        switch action {
        case .none:
            return
        case .restartShell:
            lastShellRestart = now
            log("OmacVM: the VM's shell (Quickshell) lost its GPU context: restarting the shell by itself")
            guest("/usr/local/bin/omacvm-desktop-recover", ["shell"]) { _ in }
        case .restartDesktop:
            restart.clear()
            log("OmacVM: the VM's desktop (Hyprland) lost its GPU context; \(m.line), budget \(GPUMemory.gb(m.budgetMB)), pressure \(m.pressure), \(m.refused) refused")
            log("OmacVM: restarting the VM's desktop by itself: apps open in the VM close (once per 10 min, else the app asks)")
            let why = DesktopRecovery.reason(pressure: m.pressure, refused: m.refused)
            restartDesktop(why) { [weak self] result in
                guard let self, result != .started else { return }
                self.log(result == .refused
                         ? "OmacVM: the VM's agent refused to restart the desktop: asking"
                         : "OmacVM: the VM's agent did not answer in time (the restart may be under way): asking")
                self.desktopLost(m, again: false)
            }
        case .ask(let again):
            log("OmacVM: the VM's desktop (Hyprland) lost its GPU context; \(m.line), budget \(GPUMemory.gb(m.budgetMB)), pressure \(m.pressure), \(m.refused) refused")
            desktopLost(m, again: again)
        }
    }

    /// Restarts the VM's desktop session and counts it for the 10-minute
    /// rule. Counted from the start, so a second loss while the agent is
    /// asked does not restart it twice; taken back when the VM refused (no
    /// restart happened), kept when it did not answer (one may be under way).
    private func restartDesktop(_ why: String, done: @escaping @MainActor (GuestAgent.Start) -> Void) {
        let before = lastDesktopRestart
        let now = Date()
        lastDesktopRestart = now
        guest("/usr/local/bin/omacvm-desktop-recover", ["desktop", why]) { [weak self] result in
            if result == .refused, let self, self.lastDesktopRestart == now { self.lastDesktopRestart = before }
            done(result)
        }
    }

    /// Runs a program in the VM off the main thread. A VM set up before
    /// omacvm-desktop-recover (3.0.0) has no such program (the agent refuses):
    /// the login manager is restarted directly there (no note in the new
    /// session). Not when the agent did not answer: the restart may be under
    /// way, and a second one would end the new session too.
    private func guest(_ path: String, _ args: [String], done: @escaping @MainActor (GuestAgent.Start) -> Void) {
        let socket = config.agentSocket.path
        DispatchQueue.global(qos: .userInitiated).async {
            var result = GuestAgent.start(socketPath: socket, path, args)
            if result == .refused, args.first == "desktop" {
                result = GuestAgent.start(socketPath: socket, "/usr/bin/systemctl", ["restart", "sddm"])
            }
            let final = result
            Task { @MainActor in done(final) }
        }
    }

    /// The compositor is not told about a lost context: the VM's Mesa does not
    /// report resets, and Hyprland 0.56 would only stop ("Cannot continue until
    /// proper GPU reset handling is implemented") if it were. Asked when the
    /// automatic restart is off, did not work, or was done shortly before.
    private func desktopLost(_ m: GPUMemory, again: Bool) {
        guard alert == nil else { return }
        let a = NSAlert()
        a.messageText = again ? "The VM's desktop stopped drawing again" : "The VM's desktop stopped drawing"
        a.informativeText = (again ? "It was restarted a few minutes ago. " : "") + m.lostReason +
            " The VM still runs, but its screen stays black until the desktop starts again. " +
            "Restarting the desktop closes the apps open in the VM; anything not saved in them is lost."
        a.addButton(withTitle: "Restart the Desktop")
        a.addButton(withTitle: "Later")
        a.window.level = .floating
        a.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert = a
        NSApp.activate()
        let answer = a.runModal()
        alert = nil
        // The VM stopped while the window was up (stop() closed it).
        guard !stopped, answer != .abort else { return }
        guard answer == .alertFirstButtonReturn else {
            log("OmacVM: the desktop stays black for now (Later; the app menu has Restart the Desktop…)")
            laterWith = (m, again)
            restart.markLost("Hyprland lost its GPU context; Later")
            return
        }
        restart.clear()
        log("OmacVM: restarting the VM's desktop session")
        // Counts as a restart: lost again soon after, the app asks again.
        // The login manager starts again and logs the user in again (SDDM's
        // autologin), or shows its login screen.
        restartDesktop(DesktopRecovery.reason(pressure: m.pressure, refused: m.refused)) { [weak self] result in
            guard let self, result == .refused else { return }
            self.log("OmacVM: the VM's agent refused to restart the desktop")
            // Nothing restarted: the menu item stays, to try again. Not on no
            // answer: a restart may be under way.
            if !self.stopped {
                self.laterWith = (m, again)
                self.restart.markLost("Hyprland lost its GPU context; the agent refused the restart")
            }
        }
    }

    /// "Restart the Desktop…" in QEMU's app menu: the window again, as it was.
    private func restartChosen() {
        guard !stopped, alert == nil, restart.takesRequest() else { return }
        log("OmacVM: Restart the Desktop… chosen in the app menu")
        let w = laterWith ?? (GPUMemory(), false)
        desktopLost(w.m, again: w.again)
    }
}

extension DesktopRestart {
    /// This VM's file and this app's request name (the same in Runner, which
    /// hands both to QEMU, and in GPUMemoryWatch).
    init(for config: VMConfig) {
        self.init(logs: config.folder.appendingPathComponent("logs"),
                  bundleID: Bundle.main.bundleIdentifier, pid: getpid())
    }
}
