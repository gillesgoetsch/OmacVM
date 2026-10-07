import Darwin
import Foundation
import OmacVMWindow
import SwiftUI

/// The VM's disk on the Mac: disk.img's length (the max), what it takes, and
/// the Mac's free space where it is. Rules in OmacVMWindow/DiskSize.swift.
enum VMDisk {
    struct Info: Equatable {
        var maxBytes: Int64
        var usedBytes: Int64
        var freeBytes: Int64?
    }

    static func info(_ c: VMConfig) -> Info? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        guard let v = try? c.disk.resourceValues(forKeys: keys), let size = v.fileSize else { return nil }
        let vol = try? c.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        var free = vol?.volumeAvailableCapacityForImportantUsage
        // Some drives answer 0 or nothing for "important usage": their plain free space then.
        if (free ?? 0) <= 0, let plain = vol?.volumeAvailableCapacity { free = Int64(plain) }
        return Info(maxBytes: Int64(size), usedBytes: Int64(v.totalFileAllocatedSize ?? 0), freeBytes: free)
    }

    static func jobsFile(_ c: VMConfig) -> URL { c.folder.appendingPathComponent("disk-jobs") }

    static func jobs(_ c: VMConfig) -> [DiskSize.Job] {
        DiskSize.parseJobs((try? String(contentsOf: jobsFile(c), encoding: .utf8)) ?? "")
    }

    static func setJobs(_ jobs: [DiskSize.Job], _ c: VMConfig) throws {
        if jobs.isEmpty {
            try? FileManager.default.removeItem(at: jobsFile(c))
        } else {
            try DiskSize.jobsText(jobs).write(to: jobsFile(c), atomically: true, encoding: .utf8)
        }
    }

    /// Makes disk.img `newGB` long (the VM is off; checked by the caller:
    /// DiskSize.changeProblem). Only ever longer: the bytes the VM has stay
    /// where they are. vm.env's DISK_GB follows, and the guest grows its
    /// partition and file system at the next start.
    static func grow(_ c: VMConfig, to newGB: Int) throws {
        let newBytes = Int64(newGB) * DiskSize.gib
        guard let now = info(c) else { throw HelperError.io("No disk.img in \(c.folder.path).") }
        guard newBytes > now.maxBytes else { throw HelperError.io("The disk is already \(DiskSize.text(now.maxBytes)).") }
        // A QEMU this app does not know (started by hand, another copy of
        // the app) has it open: QEMU takes no file lock on macOS.
        if inUse(c) { throw HelperError.io("disk.img is in use (the VM runs?): shut the VM down first.") }
        // The job first: a power cut after the truncate still has the guest
        // grow into the new end (a grow job on an unchanged disk does nothing).
        let hadGrow = jobs(c).contains(.grow)
        try setJobs(jobs(c) + [.grow], c)
        guard truncate(c.disk.path, off_t(newBytes)) == 0 else {
            let why = String(cString: strerror(errno))
            if !hadGrow, (info(c)?.maxBytes ?? 0) < newBytes { try? setJobs(jobs(c).filter { $0 != .grow }, c) }
            throw HelperError.io("Could not grow disk.img: \(why).")
        }
        try c.writeEnv(["DISK_GB": "\(newGB)"])
    }

    // MARK: Smaller

    static func resizeFile(_ c: VMConfig) -> URL { c.folder.appendingPathComponent("disk-resize") }
    /// disk.img as it was before a smaller size, until the check passes (an APFS clone).
    static func clone(_ c: VMConfig) -> URL { c.folder.appendingPathComponent("disk-before-resize.img") }

    static func resize(_ c: VMConfig) -> DiskSize.Resize? {
        DiskSize.Resize.parse((try? String(contentsOf: resizeFile(c), encoding: .utf8)) ?? "")
    }

    static func setResize(_ r: DiskSize.Resize?, _ c: VMConfig) throws {
        if let r {
            try r.text.write(to: resizeFile(c), atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: resizeFile(c))
        }
    }

    /// Why the disk can only get larger before its size is read: a grow not
    /// done yet (the partition table is not at the new end), or a drive
    /// without APFS clones (the copy kept while it shrinks). nil: it can.
    static func smallerBlocked(_ c: VMConfig) -> String? {
        if jobs(c).contains(.grow) { return "Omarchy grows into the last change at the next start first." }
        if (try? c.folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == false {
            return "making it smaller needs the VM on a Mac-formatted (APFS) drive."
        }
        return nil
    }

    /// What btrfs holds, read from disk.img (the VM off; its last shutdown's numbers).
    static func need(_ c: VMConfig) -> Result<DiskSize.Need, DiskImage.Problem> {
        DiskImage.read(c.disk.path).map {
            DiskSize.Need(allocated: $0.fs.deviceAllocated, used: $0.fs.bytesUsed, rootStart: $0.root.first * DiskImage.sector)
        }
    }

    /// The same from the guest while the VM runs; nil when it does not answer.
    static func liveNeed(_ c: VMConfig) -> DiskSize.Need? {
        exec(agentPath: c.agentSocket.path, script: DiskSize.usageScript, seconds: 20, running: { true })
            .flatMap { $0.exitCode == 0 ? DiskSize.need(fromUsage: $0.output) : nil }
    }

    enum Change { case larger, smaller }

    /// Apply in Disk › Change… (the VM off), checked against the slider's
    /// bounds again. Larger: done here. Smaller: a clone of disk.img and the
    /// plan; the VM's next start does the rest.
    static func change(_ c: VMConfig, to newGB: Int) throws -> Change {
        guard let now = info(c) else { throw HelperError.io("No disk.img in \(c.folder.path).") }
        guard resize(c) == nil else { throw HelperError.io("The last change of the disk is not finished.") }
        let currentGB = DiskSize.wholeGB(now.maxBytes)
        guard newGB != currentGB else { throw HelperError.io("The disk is already \(currentGB) GB.") }
        var known: DiskSize.Need?, why = smallerBlocked(c) ?? ""
        if why.isEmpty {
            switch need(c) {
            case .success(let n): known = n
            case .failure(let p): why = p.description
            }
        }
        let bounds = DiskSize.bounds(currentGB: currentGB, need: known, unknownWhy: why, freeBytes: now.freeBytes)
        if let p = DiskSize.changeProblem(currentGB: currentGB, newGB: newGB, bounds: bounds, vmRunning: inUse(c)) {
            throw HelperError.io(p)
        }
        if newGB > currentGB {
            try grow(c, to: newGB)
            return .larger
        }
        try startShrink(c, to: newGB, info: now)
        return .smaller
    }

    private static func inUse(_ c: VMConfig) -> Bool {
        !Mac.run("/usr/sbin/lsof", ["-t", "--", c.disk.path]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func startShrink(_ c: VMConfig, to newGB: Int, info now: Info) throws {
        if inUse(c) { throw HelperError.io("disk.img is in use (the VM runs?): shut the VM down first.") }
        let layout: DiskImage.Layout
        switch DiskImage.read(c.disk.path) {
        case .success(let l): layout = l
        case .failure(let p): throw HelperError.io(p.description)
        }
        let need = DiskSize.Need(allocated: layout.fs.deviceAllocated, used: layout.fs.bytesUsed,
                                 rootStart: layout.root.first * DiskImage.sector)
        let plan: DiskImage.ShrinkPlan
        switch DiskImage.planShrink(layout, targetGB: newGB, needBytes: DiskSize.fsNeed(need)) {
        case .success(let p): plan = p
        case .failure(let p): throw HelperError.io(p.description)
        }
        // While btrfs moves its blocks, the clone keeps the old ones: up to
        // what it holds, on the Mac.
        if let free = now.freeBytes, free < need.allocated + DiskSize.macReserve {
            throw HelperError.io("The Mac needs \(DiskSize.text(need.allocated + DiskSize.macReserve)) free to keep a copy of the disk while it shrinks.")
        }
        try? FileManager.default.removeItem(at: clone(c))
        guard clonefile(c.disk.path, clone(c).path, 0) == 0 else {
            let why = String(cString: strerror(errno))
            throw HelperError.io("Could not copy disk.img first (\(why)). Making it smaller needs a Mac-formatted (APFS) drive.")
        }
        let fromGB = DiskSize.wholeGB(now.maxBytes)
        do {
            try setResize(DiskSize.Resize(step: .shrink, fromGB: fromGB, toGB: newGB, plan: plan), c)
        } catch {
            try? FileManager.default.removeItem(at: clone(c))
            throw error
        }
    }

    /// Before QEMU starts: when the guest shrank btrfs at the last start,
    /// cut disk.img now. A cut that stops before writing leaves the disk as
    /// it is and has the guest grow btrfs back; one that stops later brings
    /// the clone back.
    static func cutIfDue(_ c: VMConfig) {
        guard var r = resize(c), r.step == .cut, let plan = r.plan else { return }
        if inUse(c) { return }
        do {
            // Cut already, and stopped before the step was saved: only the record.
            if case .success(let l) = DiskImage.read(c.disk.path), DiskImage.isCut(l, plan: plan) {
                log(c, "disk smaller: disk.img was cut already")
            } else {
                try DiskImage.cut(c.disk.path, plan: plan)
                log(c, "disk smaller: disk.img cut to \(r.toGB) GB; checked at this start")
            }
            try? c.writeEnv(["DISK_GB": "\(r.toGB)"])
            r.step = .check
            try? setResize(r, c)
        } catch let p as DiskImage.Problem where !DiskImage.wrote(p) {
            if case .success = DiskImage.read(c.disk.path) {
                // The disk reads as before: btrfs grows back, the copy goes.
                try? setJobs(jobs(c) + [.grow], c)
                try? FileManager.default.removeItem(at: clone(c))
                fail(c, r, "Could not make the disk smaller: \(p). Nothing changed.")
            } else {
                // Not as OmacVM left it: the copy stays for Go Back.
                fail(c, r, "Could not make the disk smaller: \(p). The copy from before is kept.")
            }
        } catch {
            let back = restore(c, r)
            fail(c, r, "Could not make the disk smaller: \(error.localizedDescription). " + (back ? "The disk is back as it was before." : "The copy from before is \(clone(c).lastPathComponent)."))
        }
    }

    /// The clone back in place of disk.img (the VM off), with its size.
    @discardableResult
    static func restore(_ c: VMConfig, _ r: DiskSize.Resize) -> Bool {
        guard FileManager.default.fileExists(atPath: clone(c).path), !inUse(c),
              rename(clone(c).path, c.disk.path) == 0 else { return false }
        try? c.writeEnv(["DISK_GB": "\(r.fromGB)"])
        log(c, "disk smaller: the disk from before is back (\(r.fromGB) GB)")
        return true
    }

    /// Disk › Go back after a failed step: the disk from before the change.
    static func goBack(_ c: VMConfig) throws {
        guard let r = resize(c) else { return }
        if inUse(c) { throw HelperError.io("disk.img is in use (the VM runs?): shut the VM down first.") }
        guard restore(c, r) else { throw HelperError.io("Could not bring back \(clone(c).lastPathComponent).") }
        try setResize(nil, c)
    }

    /// Disk › Keep (after a failed step) or Cancel (before the VM started):
    /// the disk stays as it is, the clone goes.
    static func dropResize(_ c: VMConfig) {
        // btrfs shrunk but the disk not cut: it grows back into its partition at the next start.
        if case .success(let l) = DiskImage.read(c.disk.path), l.fs.deviceBytes + 64 * (1 << 20) < l.root.bytes {
            try? setJobs(jobs(c) + [.grow], c)
        }
        try? FileManager.default.removeItem(at: clone(c))
        try? setResize(nil, c)
    }

    private static func fail(_ c: VMConfig, _ r: DiskSize.Resize, _ note: String) {
        var f = r
        f.step = .failed
        f.note = note
        try? setResize(f, c)
        log(c, "disk smaller: \(note)")
    }

    // MARK: At the VM's start

    /// Runs the disk jobs and the next step of a smaller size once the guest
    /// agent answers (off the main thread; gives up when QEMU ends). A job
    /// that worked is removed; one that did not stays for the next start,
    /// and qemu.log and logs/disk say why.
    static func runJobs(config c: VMConfig, agentPath: String, running: @escaping () -> Bool) {
        let jobs = jobs(c)
        let step = resize(c)?.step
        guard !jobs.isEmpty || step == .shrink || step == .check else { return }
        Thread.detachNewThread {
            // The guest agent starts with Omarchy: up to ten minutes.
            let deadline = Date().addingTimeInterval(600)
            while running(), Date() < deadline {
                if GuestAgent.execute(socketPath: agentPath, "{\"execute\":\"guest-ping\"}")?.contains("\"return\"") == true { break }
                Thread.sleep(forTimeInterval: 5)
            }
            // logs/disk: this start's results, one line per job.
            try? Data().write(to: c.folder.appendingPathComponent("logs/disk"))
            for job in jobs {
                guard running() else { return }
                let script = job == .grow ? DiskSize.growScript : DiskSize.compactScript
                let result = exec(agentPath: agentPath, script: script, running: running)
                let ok = result.map { job == .grow ? $0.exitCode == 0 && DiskSize.grew($0.output) : $0.exitCode == 0 } ?? false
                log(c, "disk \(job.rawValue): \(ok ? "done" : "failed, tried again at the next start") (\(detail(result)))")
                if ok { try? setJobs(Self.jobs(c).filter { $0 != job }, c) }
            }
            guard running() else { return }
            runResizeStep(c, agentPath: agentPath, running: running)
        }
    }

    private static func detail(_ r: DiskSize.ExecStatus?) -> String {
        r.map { "exit \($0.exitCode): \($0.output.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? "the guest agent did not answer"
    }

    /// shrink: btrfs smaller, then the VM shuts down (the app cuts disk.img
    /// and starts it again: main.swift). check: the cut disk read through.
    private static func runResizeStep(_ c: VMConfig, agentPath: String, running: @escaping () -> Bool) {
        guard let r = resize(c), let plan = r.plan else { return }
        switch r.step {
        case .shrink:
            log(c, "disk smaller: btrfs to \(DiskSize.text(plan.fsBytes)) for a \(r.toGB) GB disk")
            let result = exec(agentPath: agentPath, script: DiskSize.shrinkScript(fsBytes: plan.fsBytes), seconds: 3600, running: running)
            guard let result else {
                // QEMU ended or the agent went away: tried again at the next start.
                log(c, "disk smaller: no answer from the guest (\(detail(result))), tried again at the next start")
                return
            }
            if result.exitCode == 0, DiskSize.shrank(result.output, fsBytes: plan.fsBytes) {
                var next = r
                next.step = .cut
                try? setResize(next, c)
                log(c, "disk smaller: btrfs shrank (\(detail(result))); the VM shuts down for the cut")
                GuestAgent.shutdown(socketPath: agentPath)
                return
            }
            // btrfs refused (too full, a second device): grown back to its
            // partition, nothing else was touched.
            let back = exec(agentPath: agentPath, script: DiskSize.unshrinkScript, running: running)
            let note = "Could not make the disk smaller: \(detail(result))."
            if back?.exitCode == 0 {
                try? FileManager.default.removeItem(at: clone(c))
                fail(c, r, note + " Nothing changed.")
            } else {
                fail(c, r, note + " The copy from before is kept.")
            }
        case .check:
            let result = exec(agentPath: agentPath, script: DiskSize.checkScript, seconds: 3600, running: running)
            guard let result else {
                // Still running after ten minutes without an answer: the cut
                // disk may not start. Go Back stays offered.
                if running() {
                    fail(c, r, "Omarchy did not answer after the disk was cut. If it does not start, Go Back brings the disk from before.")
                } else {
                    log(c, "disk smaller: the VM ended before the check, tried again at the next start")
                }
                return
            }
            if result.exitCode == 0, DiskSize.checked(result.output, diskBytes: plan.newBytes) {
                try? FileManager.default.removeItem(at: clone(c))
                try? setResize(nil, c)
                log(c, "disk smaller: done, \(r.toGB) GB (\(detail(result)))")
            } else {
                fail(c, r, "The check after making the disk smaller failed (\(detail(result))).")
            }
        case .cut, .failed:
            return
        }
    }

    /// guest-exec of /bin/sh -c SCRIPT, then its status until it ends.
    private static func exec(agentPath: String, script: String, seconds: TimeInterval = 600,
                                         running: () -> Bool) -> DiskSize.ExecStatus? {
        let body: [String: Any] = ["execute": "guest-exec",
                                   "arguments": ["path": "/bin/sh", "arg": ["-c", script], "capture-output": true]]
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let reply = GuestAgent.execute(socketPath: agentPath, String(decoding: json, as: UTF8.self)),
              let pid = DiskSize.parseExecPid(reply) else { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while running(), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            guard let r = GuestAgent.execute(socketPath: agentPath, "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":\(pid)}}"),
                  let st = DiskSize.parseExecStatus(r) else { continue }
            if st.exited { return st }
        }
        return nil
    }

    static func log(_ c: VMConfig, _ line: String) {
        let logs = c.folder.appendingPathComponent("logs")
        if let h = FileHandle(forWritingAtPath: logs.appendingPathComponent("qemu.log").path) {
            h.seekToEndOfFile()
            h.write(Data("OmacVM: \(line)\n".utf8))
            try? h.close()
        }
        if let h = FileHandle(forWritingAtPath: logs.appendingPathComponent("disk").path) {
            h.seekToEndOfFile()
            h.write(Data("\(line)\n".utf8))
            try? h.close()
        }
    }
}

/// Disk in the VM window's form: what it takes of its size, and Change….
struct DiskRow: View {
    @ObservedObject var state: AppState
    @State private var info: VMDisk.Info?
    @State private var jobs: [DiskSize.Job] = []
    @State private var resize: DiskSize.Resize?
    @State private var changing = false
    @State private var error: String?

    var body: some View {
        LabeledContent("Disk") {
            HStack(spacing: 8) {
                if let i = info {
                    Text("\(DiskSize.text(i.usedBytes)) used of \(DiskSize.text(i.maxBytes))")
                } else {
                    Text("No disk.img").foregroundStyle(.secondary)
                }
                Button("Change…") { changing = true }
                    .disabled(info == nil || resize != nil || state.storage.moving != nil)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in refresh() }
        .sheet(isPresented: $changing, onDismiss: refresh) {
            if let i = info {
                DiskSizeSheet(state: state, info: i) { changing = false }
            }
        }
        if let r = resize {
            resizeNote(r)
        } else if !jobs.isEmpty {
            RowNote(jobs.map { $0 == .grow ? "Omarchy grows into the new size at the next start." : "Free space goes back to the Mac at the next start." }
                .joined(separator: " "))
        }
        if let e = error { RowNote(e, error: true) }
    }

    @ViewBuilder
    private func resizeNote(_ r: DiskSize.Resize) -> some View {
        switch r.step {
        case .shrink:
            RowNote("Making it \(r.toGB) GB at the next start: Omarchy makes room, then the VM restarts once.")
            Button("Cancel the Change") { VMDisk.dropResize(state.config); refresh() }
                .disabled(state.vmRunning())
        case .cut, .check:
            RowNote("Making it \(r.toGB) GB: finished and checked at the next start.")
            backButtons(r)
        case .failed:
            RowNote(r.note ?? "Could not make the disk smaller.", error: true)
            if FileManager.default.fileExists(atPath: VMDisk.clone(state.config).path) {
                backButtons(r)
            } else {
                Button("OK") { VMDisk.dropResize(state.config); refresh() }
            }
        }
    }

    /// The disk from before the change (the clone), or this one as it is.
    @ViewBuilder
    private func backButtons(_ r: DiskSize.Resize) -> some View {
        HStack {
            Button("Go Back to \(r.fromGB) GB") { act { try VMDisk.goBack(state.config) } }
            Button("Keep This Disk") { VMDisk.dropResize(state.config); refresh() }
        }
        .disabled(state.vmRunning())
    }

    private func act(_ f: () throws -> Void) {
        do {
            try f()
            error = nil
            if let c = VMConfig.load(from: state.config.folder) { state.config = c }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        info = VMDisk.info(state.config)
        jobs = VMDisk.jobs(state.config)
        resize = VMDisk.resize(state.config)
    }
}

/// Behind Disk › Change…: the disk's size on a slider, from what Omarchy
/// needs to what the Mac has free (DiskSize.bounds).
struct DiskSizeSheet: View {
    @ObservedObject var state: AppState
    let info: VMDisk.Info
    var done: () -> Void
    /// The window pictures: no disk to read, and the size chosen.
    var preview: DiskSize.Need?
    var previewGB: Int?
    @State private var bounds: DiskSize.Bounds?
    @State private var newGB = 0
    @State private var field = ""
    @State private var note: String?

    private var currentGB: Int { DiskSize.wholeGB(info.maxBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disk Size").font(.title3.bold())
            if let b = bounds {
                HStack(spacing: 10) {
                    slider(b)
                    TextField("GB", text: $field)
                        .accessibilityLabel("Disk size in GB")
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .onSubmit { typed(b) }
                        .onChange(of: field) { _, v in
                            // As typed, when it is a size inside the ends.
                            if let gb = DiskSize.parseGB(v), gb >= b.minGB, gb <= b.maxGB { newGB = gb }
                        }
                    Text("GB").accessibilityHidden(true)
                }
                Text(b.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if newGB < currentGB {
                    Text("Smaller: the VM starts, Omarchy makes room, and it restarts once while the disk is cut. A copy of the disk is kept until a check passes.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if newGB > currentGB {
                    Text("Larger: Omarchy grows into it at the next start. The disk takes space on the Mac only as Omarchy fills it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let p = DiskSize.changeProblem(currentGB: currentGB, newGB: newGB, bounds: b, vmRunning: state.vmRunning()) {
                    Text(p).font(.caption).foregroundStyle(.red)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading what Omarchy uses…").foregroundStyle(.secondary)
                }
            }
            if let n = note { Text(n).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private var canApply: Bool {
        guard let b = bounds, newGB != currentGB else { return false }
        return DiskSize.changeProblem(currentGB: currentGB, newGB: newGB, bounds: b, vmRunning: state.vmRunning()) == nil
    }

    /// The slider with the size now marked under it.
    private func slider(_ b: DiskSize.Bounds) -> some View {
        let value = Binding<Double>(get: { Double(newGB) }, set: { set(DiskSize.snap($0, b)) })
        return VStack(spacing: 2) {
            Group {
                if b.maxGB > b.minGB {
                    Slider(value: value, in: Double(b.minGB)...Double(b.maxGB))
                } else {
                    Slider(value: .constant(0), in: 0...1).disabled(true)
                }
            }
            .accessibilityLabel("Disk size")
            .accessibilityValue("\(newGB) GB")
            .accessibilityHint("Now \(currentGB) GB. \(b.minGB) to \(b.maxGB) GB.")
            GeometryReader { g in
                // The knob's centre runs about 10 pt inside each end.
                let span = Double(max(1, b.maxGB - b.minGB))
                let x = 10 + (g.size.width - 20) * Double(currentGB - b.minGB) / span
                Text("now \(currentGB) GB")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(x, 30), g.size.width - 30), y: 6)
                Text("\(b.minGB)").font(.caption2).foregroundStyle(.tertiary).position(x: 10, y: 6)
                    .opacity(abs(x - 10) > 44 ? 1 : 0)
                Text("\(b.maxGB)").font(.caption2).foregroundStyle(.tertiary).position(x: g.size.width - 12, y: 6)
                    .opacity(abs(g.size.width - 10 - x) > 44 ? 1 : 0)
            }
            .frame(height: 12)
            .accessibilityHidden(true)
        }
    }

    private func set(_ gb: Int) {
        newGB = gb
        field = "\(gb)"
    }

    private func typed(_ b: DiskSize.Bounds) {
        if let gb = DiskSize.parseGB(field) {
            set(min(b.maxGB, max(b.minGB, gb)))
        } else {
            set(newGB)
        }
    }

    private func load() {
        let c = state.config
        let current = currentGB
        let free = info.freeBytes
        if let p = preview {
            bounds = DiskSize.bounds(currentGB: current, need: p, freeBytes: free)
            set(previewGB ?? current)
            return
        }
        let running = state.vmRunning()
        Task.detached {
            // Running: the guest's own numbers; off (or no answer): disk.img's.
            var why = VMDisk.smallerBlocked(c) ?? ""
            var need = running && why.isEmpty ? VMDisk.liveNeed(c) : nil
            if need == nil, why.isEmpty {
                switch VMDisk.need(c) {
                case .success(let n): need = n
                case .failure(let p): why = p.description
                }
            }
            let b = DiskSize.bounds(currentGB: current, need: need, unknownWhy: why, freeBytes: free)
            await MainActor.run {
                bounds = b
                set(current)
            }
        }
    }

    private func apply() {
        guard let b = bounds else { return }
        // A typed size outside the ends: shown as kept inside them, not applied yet.
        if DiskSize.parseGB(field) != newGB {
            typed(b)
            note = "\(b.minGB) to \(b.maxGB) GB."
            return
        }
        // Checked again: the VM may have started meanwhile.
        if let p = DiskSize.changeProblem(currentGB: currentGB, newGB: newGB, bounds: b, vmRunning: state.vmRunning()) {
            note = p
            return
        }
        if newGB < currentGB {
            let alert = NSAlert()
            alert.messageText = "Make the disk \(newGB) GB?"
            alert.informativeText = "The VM starts and Omarchy moves its files below \(newGB) GB. Then the VM restarts once while disk.img is cut, and the app checks the file system. Until that check passes, a copy of the disk from now is kept."
            alert.addButton(withTitle: "Make Smaller")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let change = try VMDisk.change(state.config, to: newGB)
            if let c = VMConfig.load(from: state.config.folder) { state.config = c }
            done()
            if change == .smaller { state.startVM() }
        } catch {
            note = error.localizedDescription
        }
    }
}
