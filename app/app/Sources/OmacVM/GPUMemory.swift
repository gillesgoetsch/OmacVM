import AppKit
import Foundation
import OmacVMDesktop

/// Where QEMU writes the VM's graphics memory (GPUMemory, in OmacVMDesktop).
extension GPUMemory {
    static func file(for config: VMConfig) -> URL {
        config.folder.appendingPathComponent("logs/gpu-memory")
    }

    static func read(for config: VMConfig) -> GPUMemory? {
        guard let text = try? String(contentsOf: file(for: config), encoding: .utf8) else { return nil }
        return parse(text)
    }
}

/// The VM folder's logs/memory-giveback (MemoryGiveBack.Status, for omacvm check),
/// and the VM's part of it from this app's bundle.
extension MemoryGiveBack {
    static func file(for config: VMConfig) -> URL {
        config.folder.appendingPathComponent("logs/memory-giveback")
    }

    /// Where QEMU's reclaim fix says that macOS keeps the pages the VM gives
    /// back (OMACVM_RECLAIM_STATUS; qemuKeeps).
    static func reclaimFile(for config: VMConfig) -> URL {
        config.folder.appendingPathComponent("logs/memory-reclaim")
    }

    /// src/memory/guest/giveback.sh as this app carries it (build-app.sh puts
    /// OmacVM's src in the bundle), so the VM needs no update for it; comment
    /// lines left out, so the guest agent's command stays small. nil in a
    /// build without it.
    static let script: String? = {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/omacvm/src/memory/guest/giveback.sh")
        guard let data = try? Data(contentsOf: url), data.count < 16384,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") }
            .joined(separator: "\n")
    }()

    /// "900 MB", "11.6 GB" from the VM's MB.
    static func gb(mb: Int) -> String { gb(UInt64(max(mb, 0)) * mib) }

    /// This app's QEMU gives given-back pages back to macOS (the reclaim fix):
    /// read once per app run from its binary, off the main thread.
    static let thisQEMUGivesPagesBack = qemuGivesPagesBack(binary: Paths.qemu, environment: ProcessInfo.processInfo.environment)
}

/// The VM folder's logs/vm-stalls, which QEMU's stall note writes (VMStalls).
extension VMStalls {
    static func file(for config: VMConfig) -> URL {
        config.folder.appendingPathComponent("logs/vm-stalls")
    }
}

/// While a VM runs: follows its graphics memory and macOS's memory pressure.
/// - When macOS warns that memory is short, the VM drops its whole file
///   cache. When macOS compresses the VM (MemoryGiveBack says when), the VM
///   gives back its cold file cache (src/memory/guest/giveback.sh, from this
///   app's bundle), but only with a QEMU that gives the pages back to macOS
///   (MemoryGiveBack.pagesGoBack; one qemu.log line at the start says which),
///   and only until that QEMU says macOS keeps the pages anyway (its file
///   logs/memory-reclaim, looked at every 5 s: off for the rest of the run).
///   One per 10 minutes at most: Linux then reports the pages free (virtio-balloon
///   free page reporting), and they leave QEMU's footprint. qemu.log has two
///   lines per give-back, logs/memory-giveback the last one (omacvm check).
/// - When the desktop's GPU context is lost (the VM would stay black), the
///   desktop session starts again by itself, or a window says so and offers
///   to restart it (DesktopRecovery says which). After Later, QEMU's app menu
///   has "Restart the Desktop…", which shows the window again (DesktopRestart).
/// - When an app in the VM lost its GPU context because the graphics memory
///   was full (past the apps' share; the rest is kept for the desktop) or
///   macOS was short of memory, the VM shows a note that says so
///   (GPUMemoryNotice; omacvm-desktop-recover app). Once a minute per app at
///   most: a loss inside the minute is told when it is over (the newest),
///   not dropped; a desktop restart voids it. A Vulkan (Venus) context lost
///   the same way, or because the Mac refused its commands, gets
///   omacvm-desktop-recover venus (3.2.17): a note, nothing ended, and a
///   Ghostty on Zink starts on the CPU next time; a VM without it says so
///   once in qemu.log (Update VM).
/// - When the VM stood still 10 s or more because macOS ran out of free
///   memory (QEMU's logs/vm-stalls), the VM shows a note that says so, at
///   most once per 30 minutes (VMStalls; omacvm-desktop-recover stall).
@MainActor
final class GPUMemoryWatch {
    private let config: VMConfig
    private let qemuPID: pid_t
    private let log: (String) -> Void
    private var timer: Timer?
    private var pressure: DispatchSourceMemoryPressure?
    private var giveBack = MemoryGiveBack(ram: ProcessInfo.processInfo.physicalMemory)
    /// A give-back (or the warning's drop) is under way: no second one.
    private var givingBack = false
    /// After the VM answered: QEMU's footprint is looked at 60 s later.
    private var settling: Settling?
    private var status = MemoryGiveBack.Status()
    /// The last 5 s look: QEMU's footprint before the warning's drop.
    private var lastSample: MemoryGiveBack.Sample?
    private var lostSeen = 0
    private var alert: NSAlert?
    private var lastDesktopRestart: Date?
    private var lastShellRestart: Date?
    private var notice = GPUMemoryNotice()
    /// The stalls already seen in logs/vm-stalls, and the last note about one.
    private var stallsSeen = 0
    private var stallNoteAt: Date?
    private let restart: DesktopRestart
    private var restartObserver: NSObjectProtocol?
    /// What the window said when the user picked Later: it says the same when
    /// it comes again from the menu (by then the numbers have changed).
    private var laterWith: (m: GPUMemory, again: Bool)?
    /// After stop() nothing writes desktop-lost again (a window the stop
    /// closed, a restart answered late).
    private var stopped = false

    private struct Settling {
        var due: TimeInterval
        var trigger: MemoryGiveBack.Trigger
        var result: MemoryGiveBack.Result?
        var before: MemoryGiveBack.Sample?
    }

    init(config: VMConfig, qemuPID: pid_t, log: @escaping (String) -> Void) {
        self.config = config
        self.qemuPID = qemuPID
        self.log = log
        restart = DesktopRestart(for: config)
    }

    private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    func start() {
        stopped = false
        restart.clear()
        try? FileManager.default.removeItem(at: MemoryGiveBack.file(for: config))
        restartObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(restart.requestName), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartChosen() }
        }
        // Every 5 s, a second either way so macOS can wake the app once for
        // this and its other timers (lost contexts are rare; pressure also
        // comes from the source below).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 1
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            Task { @MainActor in self?.macOSShort(critical: event.contains(.critical)) }
        }
        source.resume()
        pressure = source
        // "compressing" stays off until QEMU's binary is read (off the main
        // thread), and for good with a QEMU that keeps given-back pages.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let on = MemoryGiveBack.thisQEMUGivesPagesBack
            Task { @MainActor in self?.qemuRead(givesPagesBack: on) }
        }
    }

    private func qemuRead(givesPagesBack on: Bool) {
        guard !stopped else { return }
        giveBack.pagesGoBack = on
        log(MemoryGiveBack.startLine(pagesGoBack: on))
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
        let now = Self.now
        let trigger: MemoryGiveBack.Trigger = critical ? .critical : .warning
        guard !givingBack, giveBack.allowed(trigger, at: now) else { return }
        givingBack = true
        giveBack.started(trigger, at: now)
        let before = lastSample
        let socket = config.agentSocket.path
        let level = critical ? "critical" : "warning"
        if giveBack.misses == 0 { log("OmacVM: macOS memory pressure \(level): asking the VM to drop its file cache") }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = GuestAgent.run(socketPath: socket, "/bin/sh", ["-c", "sync; echo 1 > /proc/sys/vm/drop_caches"])
            Task { @MainActor in self?.trimmed(ok, trigger, before) }
        }
    }

    /// Done once per 10 minutes when the VM did it; when its agent did not
    /// answer (still starting, busy), tried again later (noAnswer).
    private func trimmed(_ ok: Bool, _ trigger: MemoryGiveBack.Trigger, _ before: MemoryGiveBack.Sample?) {
        givingBack = false
        if ok {
            answeredAgain(giveBack.answered(nil))
            log("OmacVM: the VM dropped its file cache")
            settling = Settling(due: Self.now + MemoryGiveBack.settle, trigger: trigger, result: nil, before: before)
        } else {
            noAnswer()
        }
    }

    /// The VM's agent did not answer: tried again in 30 s, then less often
    /// (MemoryGiveBack.retryAfter, at most every 10 minutes). One line in
    /// qemu.log for the first; the asks in between log nothing until it answers.
    private func noAnswer() {
        giveBack.noAnswer(at: Self.now)
        if giveBack.misses == 1 {
            log("OmacVM: the VM's agent did not answer: trying again in 30 s, then less often (at most every 10 minutes; no more lines until it answers)")
        }
    }

    private func answeredAgain(_ missed: Int) {
        if missed > 0 { log("OmacVM: the VM's agent answers again (it had not answered \(missed) times in a row)") }
    }

    /// Every 5 s (the only place QEMU's and macOS's numbers are read), before
    /// the graphics file (a QEMU that writes none still gets its memory
    /// back): the footprint after a give-back, and whether macOS is
    /// compressing the VM.
    private func lookAtMemory() {
        if giveBack.pagesGoBack { qemuKeepsPages() }
        guard let p = HostMemory.process(qemuPID), let c = HostMemory.compressed() else { return }
        let s = MemoryGiveBack.Sample(time: Self.now, footprint: p.footprint, resident: p.resident, compressed: c)
        lastSample = s
        if let w = settling, s.time >= w.due { settled(w, s) }
        guard !givingBack, giveBack.compressing(s) else { return }
        giveBackCache(s)
    }

    /// QEMU's reclaim fix found macOS keeping the pages the VM gives back (a
    /// refused or skipped advice; it stopped for the run): no give-back while
    /// macOS compresses from now on, one qemu.log line, check's row says it.
    private func qemuKeepsPages() {
        let text = try? String(contentsOf: MemoryGiveBack.reclaimFile(for: config), encoding: .utf8)
        guard let why = MemoryGiveBack.qemuKeeps(status: text) else { return }
        giveBack.qemuKept()
        status.kept = true
        writeStatus()
        log(MemoryGiveBack.keptLine(why))
    }

    /// Asks the VM for its cold file cache (giveback.sh compressing): it
    /// answers within 20 s with what it gave.
    private func giveBackCache(_ s: MemoryGiveBack.Sample) {
        guard let script = MemoryGiveBack.script else {
            giveBack.stop()
            log("OmacVM: macOS is compressing the VM, but this app has no giveback.sh in its bundle: no give-backs this run")
            return
        }
        let base = giveBack.baseline ?? (s.taken, s.compressed)
        givingBack = true
        giveBack.started(.compressing, at: s.time)
        if giveBack.misses == 0 {
            log("OmacVM: macOS is compressing the VM: QEMU has \(MemoryGiveBack.gb(s.taken)) outside its resident memory, "
                + "\(MemoryGiveBack.gb(s.taken &- base.taken)) more than at its lowest, and macOS compressed "
                + "\(MemoryGiveBack.gb(s.compressed &- base.compressed)) since; asking the VM for its cold file cache")
        }
        let socket = config.agentSocket.path
        let cap = config.memoryMB
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = GuestAgent.runAndWait(socketPath: socket, "/bin/sh", ["-c", script, "giveback", "compressing"], seconds: 30)
            Task { @MainActor in self?.gaveBack(outcome, s, cap) }
        }
    }

    private func gaveBack(_ outcome: GuestAgent.Outcome, _ before: MemoryGiveBack.Sample, _ cap: Int) {
        givingBack = false
        var result: MemoryGiveBack.Result?
        switch outcome {
        case .noAgent:
            noAnswer()
            return
        case .exited(_, let out):
            result = MemoryGiveBack.Result.parse(out, maxMB: cap)
            if result == nil { log("OmacVM: the VM's answer to the give-back could not be read") }
        case .running:
            log("OmacVM: the VM did not finish its give-back within 30 s")
        case .refused(let why):
            log("OmacVM: the VM's agent did not run the give-back (\(ControlCentreRoute.line(why)))")
        case .badReply:
            log("OmacVM: the VM's answer to the give-back could not be read")
        }
        answeredAgain(giveBack.answered(result))
        if giveBack.off {
            log("OmacVM: the VM's balloon does not report free pages, so what it frees stays on the Mac: no more give-backs this run")
            status.trigger = "off"
            status.off = true
            writeStatus()
            return
        }
        settling = Settling(due: Self.now + MemoryGiveBack.settle, trigger: .compressing, result: result, before: before)
    }

    /// 60 s after the VM answered: the second line, the status file, the next gap.
    private func settled(_ w: Settling, _ s: MemoryGiveBack.Sample) {
        settling = nil
        let before = w.before?.footprint ?? s.footprint
        let drop = before > s.footprint ? before - s.footprint : 0
        giveBack.settled(w.trigger, guest: w.result.map { UInt64($0.gotMB) * MemoryGiveBack.mib }, footprintDrop: drop, at: s.time)
        let r = w.result
        status.count += 1
        status.at = Int(Date().timeIntervalSince1970)
        status.trigger = w.trigger.rawValue
        status.act = r?.act ?? (w.trigger == .compressing ? "unknown" : "drop")
        status.givenMB = r?.gotMB
        status.returnedMB = Int(drop / MemoryGiveBack.mib)
        status.cacheMB = r?.cacheMB ?? 0
        status.cacheAfterMB = r?.cacheAfterMB ?? 0
        status.smallFreeMB = r?.smallFreeMB ?? 0
        status.footprintMB = Int(before / MemoryGiveBack.mib)
        status.footprintAfterMB = Int(s.footprint / MemoryGiveBack.mib)
        status.takenMB = Int((w.before?.taken ?? 0) / MemoryGiveBack.mib)
        status.backoff = Int(giveBack.backoff)
        writeStatus()
        var line = "QEMU's footprint \(MemoryGiveBack.gb(before)) -> \(MemoryGiveBack.gb(s.footprint)) 60 s later"
        if w.trigger == .compressing && giveBack.backoff > 1 {
            line += "; little came back: the next give-back for this in \(Int(min(MemoryGiveBack.gap * giveBack.backoff, MemoryGiveBack.longestGap) / 60)) minutes at the earliest"
        }
        let g = MemoryGiveBack.gb(mb:)
        switch (w.trigger, r?.act) {
        case (.compressing, "reclaim"?):
            log("OmacVM: the VM gave back \(g(r!.gotMB)) of cold file cache (\(g(r!.cacheMB)) -> \(g(r!.cacheAfterMB)); "
                + "\(g(r!.smallFreeMB)) free in blocks too small to give back); \(line)")
        case (.compressing, "drop"?):
            log("OmacVM: the VM dropped its whole file cache, \(g(r!.gotMB)) (its kernel has no cold-only way); \(line)")
        case (.compressing, _?):
            log("OmacVM: the VM had no cold file cache to give (\(g(r!.cacheMB)) of file cache, "
                + "\(g(r!.smallFreeMB)) free in blocks too small to give back); \(line)")
        case (.compressing, nil):
            log("OmacVM: the give-back's result is not known; \(line)")
        default:
            log("OmacVM: after the drop: \(line)")
        }
    }

    private func writeStatus() {
        try? Data(status.text.utf8).write(to: MemoryGiveBack.file(for: config), options: .atomic)
    }

    private func poll() {
        lookAtMemory()
        lookAtStalls()
        guard let m = GPUMemory.read(for: config) else { return }
        // macOS tells only some processes about a warning, one at a time; QEMU
        // also looks for itself once a second and writes what it sees.
        if m.pressure != "normal" { macOSShort(critical: m.pressure == "critical") }
        if m.lost > lostSeen {
            // Several can be lost between two looks (the desktop, then a browser).
            let count = min(m.lost - lostSeen, m.lostRecent.count)
            let new = Array(m.lostRecent.suffix(count))
            let why = m.lostRecentWhy.count == m.lostRecent.count ? Array(m.lostRecentWhy.suffix(count)) : []
            let kind = m.lostRecentKind.count == m.lostRecent.count ? Array(m.lostRecentKind.suffix(count)) : []
            lostSeen = m.lost
            tellApps(new, why, kind, m)
            lost(new, kind, m)
        } else {
            // An app's loss kept inside its minute is told when that is over.
            tellApps([], [], [], m)
        }
    }

    /// Every 5 s, before the graphics file: a new stall in QEMU's
    /// logs/vm-stalls. One of 10 s or more for memory: a note in the VM (a VM
    /// from before has no such note: one log line, nothing else happens).
    private func lookAtStalls() {
        guard let text = try? String(contentsOf: VMStalls.file(for: config), encoding: .utf8),
              let s = VMStalls.parse(text), s.stalls > stallsSeen else { return }
        defer { stallsSeen = s.stalls }
        let now = Date()
        guard VMStalls.noteDue(s, seen: stallsSeen, lastNote: stallNoteAt, now: now) else { return }
        stallNoteAt = now
        let args = VMStalls.noteArguments(s, macBytes: ProcessInfo.processInfo.physicalMemory)
        log("OmacVM: the VM stood still for \(args[1]) s, macOS out of free memory (the VM held \(args[2]) GB of "
            + "this Mac's \(args[3]) GB): a note in the VM")
        guest("/usr/local/bin/omacvm-desktop-recover", args) { [weak self] result in
            if result != .started { self?.log("OmacVM: the VM did not show the stall note (an older VM: Update VM puts it in)") }
        }
    }

    /// Apps that lost their GPU context to the memory guard or to macOS's
    /// pressure: logged, and a note in the VM (a VM from before 3.0.5 has no
    /// such note: its agent refuses, nothing else happens). Every look, also
    /// with nothing new: a loss kept inside its app's minute comes out here.
    private func tellApps(_ names: [String], _ why: [String], _ kind: [String], _ m: GPUMemory) {
        let now = Date()
        let waiting = Set(notice.waiting)
        for app in notice.look(lost: names, why: why, kind: kind, now: now) {
            let vulkan = app.venus ? " (Vulkan)" : ""
            if let since = app.heldSince {
                let cause = app.why == "guard" ? "the apps' share of graphics memory was full"
                    : app.why == "venus" ? "its Vulkan commands were refused on the Mac" : "macOS was short of memory"
                log("OmacVM: \(app.name) in the VM lost its GPU context\(vulkan) \(Int(now.timeIntervalSince(since))) s ago: "
                    + "\(cause) (told now: a minute after the last note)")
            } else {
                let cause = app.why == "guard"
                    ? "the apps' share of graphics memory was full (\(GPUMemory.gb(m.appsMB)) of \(GPUMemory.gb(m.budgetMB)); the rest is kept for the desktop)"
                    : app.why == "venus" ? "its Vulkan commands were refused on the Mac"
                    : "macOS was short of memory (pressure \(m.pressure))"
                log("OmacVM: \(app.name) in the VM lost its GPU context\(vulkan): \(cause)")
            }
            if app.venus {
                venusNote(app.name, app.why)
            } else {
                guest("/usr/local/bin/omacvm-desktop-recover", ["app", app.name, app.why]) { _ in }
            }
        }
        for name in notice.waiting where !waiting.contains(name) {
            // A desktop restart before then voids it (restartDesktop): the line says so.
            log("OmacVM: \(name) in the VM lost its GPU context again within a minute of the last note: "
                + "told when that minute is over, unless the desktop restarts before then")
        }
    }

    /// A lost Vulkan (Venus) context: omacvm-desktop-recover venus NAME WHY
    /// in the VM (a note; for ghostty also /run/omacvm/gl-zink-off: the next
    /// Ghostty starts on the CPU; nothing is ended). Its exit is waited for
    /// up to 2 s (ADR 0038's rule: no answer in time is not tried again): a
    /// VM from before 3.2.17 answers with its usage (exit 2), so the note is
    /// only in this log until Update VM; it never gets `app NAME venus`,
    /// which such a VM would take for a full graphics memory and answer by
    /// ending the app's GPU process.
    private func venusNote(_ name: String, _ why: String) {
        let socket = config.agentSocket.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = GuestAgent.runAndWait(socketPath: socket, "/usr/local/bin/omacvm-desktop-recover",
                                                ["venus", name, why], seconds: 2)
            Task { @MainActor in self?.venusNoted(name, outcome) }
        }
    }

    private func venusNoted(_ name: String, _ outcome: GuestAgent.Outcome) {
        switch outcome {
        case .exited(0, _), .running:
            return
        case .exited(2, _), .refused:
            log("OmacVM: the VM has no note for a lost Vulkan context yet (\(name)): Update VM puts it in")
        case .exited(let code, _):
            log("OmacVM: the VM's note for \(name)'s lost Vulkan context failed (exit \(code))")
        case .noAgent, .badReply:
            log("OmacVM: the VM's agent did not answer: \(name)'s lost Vulkan context is only in this log")
        }
    }

    private func lost(_ names: [String], _ kinds: [String], _ m: GPUMemory) {
        guard alert == nil else { return }
        let now = Date()
        let action = DesktopRecovery.action(lost: names, kinds: kinds, enabled: DesktopRecovery.enabled(),
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
            log("OmacVM: the VM's desktop (Hyprland) lost its GPU context (\(m.why(of: DesktopRecovery.compositors) ?? "why not known")); \(m.line), budget \(GPUMemory.gb(m.budgetMB)), pressure \(m.pressure), \(m.refused) refused")
            log("OmacVM: restarting the VM's desktop by itself: apps open in the VM close (once per 10 min, else the app asks)")
            let why = DesktopRecovery.reason(why: m.why(of: DesktopRecovery.compositors), pressure: m.pressure, refused: m.refused)
            restartDesktop(why) { [weak self] result in
                guard let self, result != .started else { return }
                self.log(result == .refused
                         ? "OmacVM: the VM's agent refused to restart the desktop: asking"
                         : "OmacVM: the VM's agent did not answer in time (the restart may be under way): asking")
                self.desktopLost(m, again: false)
            }
        case .ask(let again):
            log("OmacVM: the VM's desktop (Hyprland) lost its GPU context (\(m.why(of: DesktopRecovery.compositors) ?? "why not known")); \(m.line), budget \(GPUMemory.gb(m.budgetMB)), pressure \(m.pressure), \(m.refused) refused")
            desktopLost(m, again: again)
        }
    }

    /// Restarts the VM's desktop session and counts it for the 10-minute
    /// rule. Counted from the start, so a second loss while the agent is
    /// asked does not restart it twice; taken back when the VM refused (no
    /// restart happened), kept when it did not answer (one may be under way).
    private func restartDesktop(_ why: String, done: @escaping @MainActor (GuestAgent.Start) -> Void) {
        // The session's apps close: a loss kept for one of them is void.
        notice.sessionRestarted()
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
        restartDesktop(DesktopRecovery.reason(why: m.why(of: DesktopRecovery.compositors), pressure: m.pressure,
                                              refused: m.refused)) { [weak self] result in
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
