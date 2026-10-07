import Foundation
import OmacVMBuildProgress

/// Runs scripts/create-vm.sh (or prebuilt-vm.sh: the VM from a prebuilt image)
/// and turns its output into progress for the UI. Both take the same vm.env
/// and password and print the same STEP, ==> and progress lines
/// (OmacVMBuildProgress: downloads and packages, checked there).
@MainActor
final class Creator: ObservableObject {
    @Published var step = 0
    @Published var steps = 6
    @Published var title = ""
    @Published var detail = ""
    @Published var failed: String?
    @Published var warning: String?
    @Published var finished = false
    /// What runs right now (a download or a package), nil between them.
    @Published private(set) var activity: ProgressUpdate?
    /// The download's speed (bytes/s, smoothed) and seconds left, when known.
    @Published private(set) var speed: Double?
    @Published private(set) var secondsLeft: Double?
    @Published private(set) var stepStarted = Date()
    @Published private(set) var buildStarted = Date()
    /// The last output from the build: a line, or a write to one of its logs.
    @Published private(set) var lastOutput = Date()
    /// The newest log's last lines and its name (logs/ of the VM), for Show details.
    @Published private(set) var logTail: [String] = []
    @Published private(set) var logName = ""
    private(set) var route = StepTimes.Route.build
    private var rate = ByteRate()
    private var activityAt = Date()
    private var ticker: Timer?
    private var logsDir: URL?
    private var stepSeconds: [Int: Double] = [:]
    private var process: Process?
    private var buffer = ""
    private var run = 0
    private var reader: FileHandle?
    private var exitStatus: Int32?
    private var logURL: URL?

    /// What runs: a new VM (create-vm.sh, prebuilt-vm.sh) or an existing VM's
    /// OmacVM brought up to this app's (update-vm.sh).
    enum Job { case build, update }
    @Published private(set) var job = Job.build

    func start(config: VMConfig, password: String, prebuilt: Bool = false, graphics: GraphicsChoice = .auto) {
        reset(.build, folder: config.folder, route: prebuilt ? .prebuilt : .build)
        do {
            try config.write()
            // Read by omacvm apply at the end of the build (the VM's Venus driver).
            try Graphics.write(graphics, folder: config.folder)
        } catch {
            failed = "Could not write the VM settings: \(error.localizedDescription)"
            return
        }
        launch(script: prebuilt ? "prebuilt-vm.sh" : "create-vm.sh", folder: config.folder,
               log: "create.log", input: password + "\n")
    }

    /// An existing VM (made by an older app): started without a window,
    /// OmacVM applied as at the end of a build, shut down. The VM's
    /// settings stay as they are.
    func update(config: VMConfig) {
        reset(.update, folder: config.folder, route: .build)
        launch(script: "update-vm.sh", folder: config.folder, log: "update.log", input: nil)
    }

    /// The log of the last build or update.
    var log: URL? { logURL }

    private func reset(_ j: Job, folder: URL, route r: StepTimes.Route) {
        job = j
        failed = nil; warning = nil; finished = false; step = 0
        activity = nil; speed = nil; secondsLeft = nil; logTail = []; logName = ""
        rate.reset(); stepSeconds = [:]
        route = r
        buildStarted = Date(); stepStarted = buildStarted; lastOutput = buildStarted
        logsDir = folder.appendingPathComponent("logs")
        reader?.readabilityHandler = nil
        reader = nil; run += 1; buffer = ""; exitStatus = nil
        title = "Preparing"
    }

    private func launch(script: String, folder: URL, log logFile: String, input text: String?) {
        let id = run
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.scripts.appendingPathComponent(script).path, folder.path]
        // Progress lines only for the app: omacvm build runs the same scripts
        // in a terminal, where they would be noise. Downloads go to the drive
        // of the VMs folder (PrebuiltImage.environment).
        var env = PrebuiltImage.environment()
        env["OMACVM_PROGRESS"] = "1"
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        let logURL = folder.appendingPathComponent(logFile)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        self.logURL = logURL
        let log = try? FileHandle(forWritingTo: logURL)
        // The main queue keeps the output in order, and the end of the output
        // after it: a failed build's last line (its ERROR:) is read before
        // the build counts as done.
        reader = output.fileHandleForReading
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.outputEnded(id) } }
                return
            }
            log?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(text) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(id, status) } }
            // A process left behind that holds the pipe must not keep the build open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self?.outputEnded(id) } }
        }
        do {
            try p.run()
            if let text { input.fileHandleForWriting.write(Data(text.utf8)) }
            try? input.fileHandleForWriting.close()
            process = p
            startTicker()
        } catch {
            reader?.readabilityHandler = nil
            reader = nil
            failed = "Could not start the \(job == .build ? "build" : "update"): \(error.localizedDescription)"
        }
    }

    func cancel() { process?.terminate() }

    /// The script still runs (an update's ERROR: comes before its VM is shut down).
    var running: Bool { process?.isRunning == true }

    private func exited(_ id: Int, _ status: Int32) {
        guard id == run else { return }
        exitStatus = status
        settle()
    }

    private func outputEnded(_ id: Int) {
        guard id == run, let r = reader else { return }
        r.readabilityHandler = nil
        reader = nil
        if !buffer.isEmpty { handle(buffer.trimmingCharacters(in: .whitespaces)); buffer = "" }
        settle()
    }

    /// Done once the build has exited and its output is read.
    private func settle() {
        guard reader == nil, let status = exitStatus else { return }
        exitStatus = nil
        ticker?.invalidate(); ticker = nil
        if status == 0 {
            endStep()
            // Step times are kept for builds only (an update has other steps).
            if job == .build { StepTimes.remember(stepSeconds, route: route) }
            finished = true
        } else if failed == nil {
            failed = "The \(job == .build ? "build" : "update") stopped (exit \(status)). Log: \(logURL?.path ?? "")"
        }
    }

    private func consume(_ text: String) {
        buffer += text
        // curl's progress bar ends its updates with \r, the rest with \n.
        while let r = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<r]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[buffer.index(after: r)...])
            handle(line)
        }
        if buffer.count > 4096 { buffer = String(buffer.suffix(512)) }
    }

    private func handle(_ line: String) {
        if !line.isEmpty { lastOutput = Date() }
        if let u = ProgressUpdate.parse(line) {
            progress(u)
        } else if line.hasPrefix("STEP ") {
            // STEP n/N title
            endStep()
            let parts = line.dropFirst(5).split(separator: " ", maxSplits: 1)
            if let nums = parts.first?.split(separator: "/"), nums.count == 2 {
                // prebuilt-vm.sh found no image and builds it here: its steps from 1 again.
                if route == .prebuilt, let n = Int(nums[0]), n <= step { route = .build; stepSeconds = [:] }
                step = Int(nums[0]) ?? step
                steps = Int(nums[1]) ?? steps
            }
            title = parts.count > 1 ? String(parts[1]) : ""
            detail = ""
            stepStarted = Date()
            clearActivity()
        } else if line.hasPrefix("==>") {
            detail = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{1B}[1;32m", with: "")
                .replacingOccurrences(of: "\u{1B}[0m", with: "")
            // A new part begins: a finished download or package run goes.
            if activity?.complete == true { clearActivity() }
        } else if line.hasPrefix("WARN:") {
            warning = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            detail = warning ?? ""
        } else if line.hasPrefix("ERROR:") {
            failed = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if activity == nil, let pct = line.split(separator: " ").last, pct.hasSuffix("%"),
                  line.contains("#") {
            detail = "Downloading \(pct)"
        }
    }

    private func progress(_ u: ProgressUpdate) {
        let t = Date().timeIntervalSince1970
        // Another file or another package run: its own speed.
        if let a = activity, a.phase != u.phase || a.total != u.total || u.done < a.done { rate.reset() }
        if u.phase == .download && u.total > 0 {
            rate.add(u.done, at: t)
            speed = rate.bytesPerSecond
            secondsLeft = rate.secondsLeft(total: u.total)
        } else {
            speed = nil; secondsLeft = nil
        }
        activity = u
        activityAt = Date()
    }

    private func clearActivity() {
        activity = nil; speed = nil; secondsLeft = nil
        rate.reset()
    }

    private func endStep() {
        guard step > 0 else { return }
        stepSeconds[step] = Date().timeIntervalSince(stepStarted)
    }

    /// Once a second: the log's tail, the last output, a stale activity.
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        // A package that has said nothing for a minute: the run is past it
        // (hooks, the next part); the heartbeat and the details say the rest.
        if let a = activity, a.phase == .install || a.complete, Date().timeIntervalSince(activityAt) > 60 { clearActivity() }
        guard let dir = logsDir else { return }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]))?
            .filter { $0.pathExtension == "log" } ?? []
        func dated(_ u: URL) -> (URL, Date, Int)? {
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let d = v.contentModificationDate, (v.fileSize ?? 0) > 0 else { return nil }
            return (u, d, v.fileSize ?? 0)
        }
        // The step's own log (written in this step), else the build's log
        // (create.log: the steps and the Mac side's lines).
        let stepLog = files.compactMap(dated).filter { $0.1 >= stepStarted.addingTimeInterval(-2) }.max { $0.1 < $1.1 }
        let buildLog = dated(dir.deletingLastPathComponent().appendingPathComponent("create.log"))
        guard let newest = stepLog ?? buildLog else { return }
        if newest.1 > lastOutput { lastOutput = min(newest.1, Date()) }
        guard let h = try? FileHandle(forReadingFrom: newest.0) else { return }
        defer { try? h.close() }
        let size = UInt64(newest.2)
        try? h.seek(toOffset: size > 16384 ? size - 16384 : 0)
        let tail = BuildText.tail(h.readData(ofLength: 16384))
        if tail != logTail { logTail = tail }
        let name = newest.0 == buildLog?.0 ? newest.0.lastPathComponent : "logs/" + newest.0.lastPathComponent
        if name != logName { logName = name }
    }
}

/// A prebuilt VM the app can download instead of building one
/// (scripts/prebuilt-vm.sh --lookup: the newest image for this version).
struct PrebuiltImage: Equatable {
    let release: String
    let bytes: Int64
    let omarchy: String

    var size: String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// Where the setup screen's lookup is.
    enum Lookup: Equatable {
        case checking
        case found(PrebuiltImage)
        case none
    }

    /// For the build scripts: the test identity, and the downloads on the
    /// drive of the VMs folder (vm-common.sh CACHE). Never into a folder of a
    /// drive that is not connected: that would be the Mac's own disk. The
    /// other downloads folders: a live system there moves over (live_reuse).
    static func environment() -> [String: String] {
        var e = TestIdentity.environment()
        e["OMACVM_CACHE"] = nil
        e["OMACVM_VMS_ROOT"] = nil
        let here = Paths.downloads
        if Storage.missingDrive(for: Paths.vmsRoot) == nil { e["OMACVM_CACHE"] = here.path }
        e["OMACVM_LIVE_FROM"] = Paths.allDownloads
            .filter { $0.path != here.standardizedFileURL.path && Storage.missingDrive(for: $0) == nil }
            .map(\.path).joined(separator: "\n")
        return e
    }

    /// Off the main thread; nil when there is none, no connection, or no
    /// answer within 20 seconds (then the VM is built here).
    static func lookup() async -> PrebuiltImage? {
        let script = Paths.scripts.appendingPathComponent("prebuilt-vm.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return await Task.detached(priority: .utility) { () -> PrebuiltImage? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, "--lookup"]
            p.environment = environment()
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(20)
            while p.isRunning {
                if Date() > deadline { p.terminate(); return nil }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            // TAG BYTES OMARCHY_VERSION IMAGE_VERSION
            let f = String(decoding: data.prefix(1024), as: UTF8.self).split(whereSeparator: \.isWhitespace)
            guard f.count >= 3, let bytes = Int64(f[1]), bytes > 0,
                  f[2].count <= 80, f[2].allSatisfy({ $0.isASCII && !$0.isWhitespace && $0.asciiValue! >= 0x21 })
            else { return nil }
            return PrebuiltImage(release: String(f[0]), bytes: bytes, omarchy: String(f[2]))
        }.value
    }
}
