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
        let free = (try? c.folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
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

    /// Makes disk.img `newGB` long (the VM is off; checked by the caller and
    /// by DiskSize.growProblem). Only ever longer: the bytes the VM has stay
    /// where they are. vm.env's DISK_GB follows, and the guest grows its
    /// partition and file system at the next start.
    static func grow(_ c: VMConfig, to newGB: Int) throws {
        let newBytes = Int64(newGB) * DiskSize.gib
        guard let now = info(c) else { throw HelperError.io("No disk.img in \(c.folder.path).") }
        guard newBytes > now.maxBytes else { throw HelperError.io("The disk is already \(DiskSize.text(now.maxBytes)).") }
        // A QEMU this app does not know (started by hand, another copy of
        // the app) has it open: QEMU takes no file lock on macOS.
        if !Mac.run("/usr/sbin/lsof", ["-t", "--", c.disk.path]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HelperError.io("disk.img is in use (the VM runs?): shut the VM down first.")
        }
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

    static func compact(_ c: VMConfig) throws {
        try setJobs(jobs(c) + [.compact], c)
    }

    // MARK: At the VM's start

    /// Runs the disk jobs once the guest agent answers (off the main thread;
    /// gives up when QEMU ends). A job that worked is removed; one that did
    /// not stays for the next start, and qemu.log and logs/disk say why.
    static func runJobs(config c: VMConfig, agentPath: String, running: @escaping () -> Bool) {
        let jobs = jobs(c)
        guard !jobs.isEmpty else { return }
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
                let detail = result.map { "exit \($0.exitCode): \($0.output.trimmingCharacters(in: .whitespacesAndNewlines))" }
                    ?? "the guest agent did not answer"
                log(c, "disk \(job.rawValue): \(ok ? "done" : "failed, tried again at the next start") (\(detail))")
                if ok { try? setJobs(Self.jobs(c).filter { $0 != job }, c) }
            }
        }
    }

    /// guest-exec of /bin/sh -c SCRIPT, then its status until it ends (ten minutes at most).
    private static func exec(agentPath: String, script: String, running: () -> Bool) -> DiskSize.ExecStatus? {
        let body: [String: Any] = ["execute": "guest-exec",
                                   "arguments": ["path": "/bin/sh", "arg": ["-c", script], "capture-output": true]]
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let reply = GuestAgent.execute(socketPath: agentPath, String(decoding: json, as: UTF8.self)),
              let pid = DiskSize.parseExecPid(reply) else { return nil }
        let deadline = Date().addingTimeInterval(600)
        while running(), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            guard let r = GuestAgent.execute(socketPath: agentPath, "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":\(pid)}}"),
                  let st = DiskSize.parseExecStatus(r) else { continue }
            if st.exited { return st }
        }
        return nil
    }

    private static func log(_ c: VMConfig, _ line: String) {
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

/// Disk in the VM window: used / max, Grow… and Compact….
struct DiskSection: View {
    @ObservedObject var state: AppState
    @State private var info: VMDisk.Info?
    @State private var jobs: [DiskSize.Job] = []
    @State private var growing = false
    @State private var newGB = 0
    @State private var note: String?

    private var currentGB: Int { Int((info?.maxBytes ?? 0) / DiskSize.gib) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let i = info {
                    Text("Disk: \(DiskSize.text(i.usedBytes)) used on the Mac of \(DiskSize.text(i.maxBytes)) max")
                } else {
                    Text("Disk: no disk.img").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Grow…") {
                    newGB = DiskSize.firstGrowGB(currentGB: currentGB)
                    growing = true
                }
                .disabled(info == nil || state.vmRunning() || state.storage.moving != nil)
                Button("Compact…") { compact() }
                    .disabled(info == nil || jobs.contains(.compact))
                    .help("Gives the Mac back the space the VM no longer uses. The max size stays.")
            }
            if !jobs.isEmpty {
                Text(jobs.map { $0 == .grow ? "Omarchy grows into the new size at the next start." : "Free space goes back to the Mac at the next start." }
                    .joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
            } else if state.vmRunning() {
                Text("Grow: shut the VM down first.").font(.caption).foregroundStyle(.secondary)
            }
            if let n = note { Text(n).font(.caption).foregroundStyle(.red) }
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in refresh() }
        .sheet(isPresented: $growing) { growSheet }
    }

    private var growSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grow the Disk").font(.title3.bold())
            Text("The disk takes space on the Mac only as Omarchy fills it. Omarchy grows into the new size at the next start. A disk cannot be made smaller again.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Stepper("New max: \(newGB) GB (now \(currentGB) GB)", value: $newGB,
                    in: min(currentGB + 1, DiskSize.maxGB)...DiskSize.maxGB, step: DiskSize.stepGB)
            if let w = DiskSize.growWarning(newGB: newGB, allocatedBytes: info?.usedBytes ?? 0, freeBytes: info?.freeBytes) {
                Text(w).font(.caption).foregroundStyle(.orange)
            }
            if let p = DiskSize.growProblem(currentGB: currentGB, newGB: newGB, vmRunning: state.vmRunning()) {
                Text(p).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { growing = false }.keyboardShortcut(.cancelAction)
                Button("Grow") { grow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(DiskSize.growProblem(currentGB: currentGB, newGB: newGB, vmRunning: state.vmRunning()) != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func refresh() {
        info = VMDisk.info(state.config)
        jobs = VMDisk.jobs(state.config)
    }

    private func grow() {
        growing = false
        // Checked again: the VM may have started meanwhile.
        if let p = DiskSize.growProblem(currentGB: currentGB, newGB: newGB, vmRunning: state.vmRunning()) {
            note = p
            return
        }
        do {
            try VMDisk.grow(state.config, to: newGB)
            note = nil
            if let c = VMConfig.load(from: state.config.folder) { state.config = c }
        } catch {
            note = "Could not grow: \(error.localizedDescription)"
        }
        refresh()
    }

    private func compact() {
        let alert = NSAlert()
        alert.messageText = "Compact the disk?"
        alert.informativeText = "At the VM's next start Omarchy tells the Mac which space it no longer uses, and disk.img gives it back. Nothing in the VM changes, and the max size stays \(currentGB) GB."
        alert.addButton(withTitle: "Compact")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try VMDisk.compact(state.config)
            note = nil
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
        refresh()
    }
}
