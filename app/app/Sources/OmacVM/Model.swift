import AppKit
import IOKit
import Foundation
import OmacVMUpdate
import OmacVMFeatures
import OmacVMAudio
import OmacVMMedia
import OmacVMWindow

enum HelperError: LocalizedError, Equatable {
    case io(String)

    var errorDescription: String? {
        switch self {
        case .io(let detail): detail
        }
    }
}

/// Where the app keeps its things.
enum Paths {
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OmacVM")

    /// Where new VMs go: ~/OmacVM unless the user picked another folder (an
    /// external drive, say) in the setup or the settings; see VMsFolder.
    static var vmsRoot: URL {
        get {
            let custom = UserDefaults.standard.string(forKey: "vmsRoot")
            // The test identity: never a folder of the installed app (TestVMs).
            if TestIdentity.isOn {
                return TestVMs.root(custom: custom, home: VMsFolder.home, production: productionVMsRoots)
            }
            if let custom, !custom.isEmpty {
                return URL(fileURLWithPath: custom)
            }
            return defaultVMsRoot
        }
        set { UserDefaults.standard.set(newValue.standardizedFileURL.path, forKey: "vmsRoot") }
    }
    /// Decided once per launch: the VMs folder must not change under a VM
    /// that runs or is being built.
    private static let defaultVMsRoot = VMsFolder.resolve(custom: nil, home: VMsFolder.home)

    /// The installed app's (org.omacvm.app) VMs folders, read once per
    /// launch: a test build never acts on a VM in one of them (TestVMs).
    static let productionVMsRoots: [URL] = {
        let id = TestHooks.releaseID as CFString
        let custom = CFPreferencesCopyAppValue("vmsRoot" as CFString, id) as? String
        let others = CFPreferencesCopyAppValue("otherVMsRoots" as CFString, id) as? [String] ?? []
        var homes = [VMsFolder.home]
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            homes.append(URL(fileURLWithPath: String(cString: dir)))
        }
        return TestVMs.productionRoots(custom: custom, others: others, homes: homes)
    }()

    /// Why a destructive test hook must not act on this VM (nil: it may).
    static func hookProblem(_ folder: URL?) -> String? {
        TestVMs.hookProblem(folder: folder, ownRoot: UserDefaults.standard.string(forKey: "vmsRoot"),
                            production: productionVMsRoots)
    }

    /// Why this build must not start or change the VM in FOLDER (nil: it may):
    /// a test build never touches a VM of the installed app (TestVMs.startProblem).
    static func startProblem(_ folder: URL) -> String? {
        TestVMs.startProblem(folder: folder, testBuild: TestHooks.allowed(bundleID: Bundle.main.bundleIdentifier),
                             production: productionVMsRoots)
    }

    /// Up to 2.9 the VMs were in this hidden folder. The app still finds them
    /// there until they are moved (it offers that once).
    static let legacyVMsRoot = VMsFolder.home.appendingPathComponent(VMsFolder.oldPath)

    /// Folders that held VMs before the user picked another one with "New VMs
    /// Only" (or a move that did not finish): their VMs keep working.
    static var otherVMsRoots: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "otherVMsRoots") ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map { $0.standardizedFileURL.path }, forKey: "otherVMsRoots") }
    }

    /// Every folder the app looks for VMs in: where new VMs go first
    /// (app_vms_roots in src/lib/app.sh: the same list).
    static var vmsRoots: [URL] {
        var seen = Set<String>(), roots: [URL] = []
        // The test identity: no folder of the installed app, and not its old place.
        let candidates = TestIdentity.isOn
            ? [vmsRoot] + otherVMsRoots.filter { !TestVMs.isProduction($0, production: productionVMsRoots) }
            : [vmsRoot] + otherVMsRoots + [legacyVMsRoot]
        for r in candidates {
            let p = r.standardizedFileURL.path
            if seen.insert(p).inserted { roots.append(r.standardizedFileURL) }
        }
        return roots
    }

    /// Where builds download the Omarchy images to (try-omarchy, prebuilt VMs):
    /// the drive of the VMs folder (Storage.downloadsFolder).
    static var downloads: URL { Storage.downloadsFolder(vmsRoot: vmsRoot, home: VMsFolder.home) }

    /// Downloads of VMs folders the app left that could not go along
    /// (Storage.dropDownloads): kept until removed or used up.
    static var oldDownloads: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "oldDownloads") ?? []).map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue.map { $0.standardizedFileURL.path }, forKey: "oldDownloads") }
    }

    /// This one, the Mac's own, those of the other VMs folders and the old
    /// ones; Storage > Downloaded images > Remove empties them.
    static var allDownloads: [URL] {
        Storage.downloadsFolders(vmsRoots: vmsRoots, home: VMsFolder.home, old: oldDownloads)
    }

    /// The app's resources: Contents/Resources in the app, the source tree when
    /// run with `swift run` (OMACVM_RESOURCES).
    static var resources: URL {
        if let env = ProcessInfo.processInfo.environment["OMACVM_RESOURCES"] {
            return URL(fileURLWithPath: env)
        }
        return Bundle.main.resourceURL!
    }

    static var qemu: URL {
        let dev = resources.appendingPathComponent("runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return resources.appendingPathComponent("runtime/bin/OmacVM")
    }

    /// Touch ID's panel, which QEMU loads (OmacVMTouchIDPanel; nil: an app built without it).
    static var touchIDPanel: URL? {
        let url = resources.appendingPathComponent("runtime/lib/OmacVMTouchIDPanel.dylib")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var firmware: URL {
        let dev = resources.appendingPathComponent("runtime/.build/firmware/edk2-aarch64-code.fd")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        return resources.appendingPathComponent("firmware/edk2-aarch64-code.fd")
    }

    static var scripts: URL { resources.appendingPathComponent("scripts") }

    static var icon: URL? {
        let url = resources.appendingPathComponent("OmacVM.icns")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Short private folder for sockets: Unix socket paths stop at 104 bytes.
    static var runDir: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let tmp = n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        let url = URL(fileURLWithPath: tmp).appendingPathComponent("omacvm")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }
}

/// The app's display name: what the user called the app (OmacVM, Omarchy, ...).
enum Product {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "OmacVM"
    }
}

/// One VM: a folder with vm.env, disk.img, efi-vars.fd and logs/.
struct VMConfig: Equatable {
    var name = "Omarchy"
    var cpus = 4
    var memoryMB = 8192
    var diskGB = 64
    var sshPort = 52222
    var user = ""
    var fullName = ""
    var hostname = "omarchy"
    var timeZone = "UTC"
    var language = "en_US.UTF-8"
    var keyboard = "us"
    // A new VM gets its own from the setup screen (SetupView). This one is
    // for a vm.env without FEATURES: no screens asked here (VMConfig is
    // also made off the main thread), so Omanotch only with a notch then.
    var features = NewVMFeatures.string(hasBattery: Mac.hasBattery, hasNotch: false)

    /// The folder of a VM that exists (it may be in an older VMs folder);
    /// nil for a new one, which goes into the VMs folder under its name.
    var location: URL?
    var folder: URL { location ?? Paths.vmsRoot.appendingPathComponent(name) }

    /// Like build.sh's VM names: letters, digits, space . _ -, at most 64,
    /// no "." or ".." (the folder must stay inside the VMs folder).
    static func validName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", options: .regularExpression) != nil
            && !name.contains("..")
    }

    /// The folder is a VM folder of ours: directly inside one of the VMs folders, with vm.env.
    var folderIsSafe: Bool {
        let parent = folder.standardizedFileURL.deletingLastPathComponent().path
        return Paths.vmsRoots.contains { $0.path == parent }
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("vm.env").path)
    }

    /// Why this built VM cannot start because of its files: the drive is not
    /// connected, the folder is gone, or files in it are (moved or deleted in
    /// the Finder). Nil when all is there.
    var filesProblem: String? {
        guard let folder = location else { return nil }
        if let drive = Storage.missingDrive(for: folder) { return Storage.driveGoneText(drive) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else {
            return "\(name)'s folder is gone: \(Storage.short(folder)). Put it back there, or into the VMs folder."
        }
        let missing = ["vm.env", "disk.img", "efi-vars.fd"].filter {
            !fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        guard isReady, !missing.isEmpty else { return nil }
        return "Missing in \(Storage.short(folder)): \(missing.joined(separator: ", ")). Put the files back, then start again."
    }
    var disk: URL { folder.appendingPathComponent("disk.img") }
    var efiVars: URL { folder.appendingPathComponent("efi-vars.fd") }
    var readyMarker: URL { folder.appendingPathComponent("ready") }
    var isReady: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

    /// The OmacVM the VM got at its last apply (omacvm apply writes it from
    /// 3.0.1 on); nil for a VM last set up by an older app.
    var guestVersion: String? {
        guard let s = try? String(contentsOf: folder.appendingPathComponent("omacvm-version"), encoding: .utf8) else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return Version(v) == nil ? nil : v
    }

    /// Same id as scripts/vm-common.sh: the first 8 hex digits of SHA-1 of the folder path.
    var id: String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output
        try? p.run()
        input.fileHandleForWriting.write(folder.path.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        let s = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "00000000"
        return String(s.prefix(8))
    }
    var qmpSocket: URL { Paths.runDir.appendingPathComponent("\(id).qmp") }
    var agentSocket: URL { Paths.runDir.appendingPathComponent("\(id).qga") }
    var clipboardSocket: URL { Paths.runDir.appendingPathComponent("\(id).clip") }
    var batterySocket: URL { Paths.runDir.appendingPathComponent("\(id).batt") }
    var cameraSocket: URL { Paths.runDir.appendingPathComponent("\(id).cam") }
    var displaySocket: URL { Paths.runDir.appendingPathComponent("\(id).disp") }
    var controlSocket: URL { Paths.runDir.appendingPathComponent("\(id).ctl") }
    var authSocket: URL { Paths.runDir.appendingPathComponent("\(id).auth") }
    var imeSocket: URL { Paths.runDir.appendingPathComponent("\(id).ime") }
    var touchIDPanelSocket: URL { Paths.runDir.appendingPathComponent("\(id).tid") }
    var mediaSocket: URL { Paths.runDir.appendingPathComponent("\(id).media") }

    func write() throws {
        try VMsFolder.prepare(folder.deletingLastPathComponent(), home: VMsFolder.home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let text = """
        NAME=\(q(name))
        CPUS=\(cpus)
        MEM_MB=\(memoryMB)
        DISK_GB=\(diskGB)
        SSH_PORT=\(sshPort)
        VM_USER=\(q(user))
        VM_FULLNAME=\(q(fullName))
        VM_HOSTNAME=\(q(hostname))
        VM_TZ=\(q(timeZone))
        VM_LANG=\(q(language))
        KEYBOARD=\(q(keyboard))
        FEATURES=\(q(features))

        """
        try text.write(to: folder.appendingPathComponent("vm.env"), atomically: true, encoding: .utf8)
    }

    /// Only CPUS and MEM_MB in vm.env, every other line as it was (`omacvm
    /// resources` changes the same two). The VM reads them at its next start.
    func writeResources() throws {
        try writeEnv(["CPUS": "\(cpus)", "MEM_MB": "\(memoryMB)"])
    }

    /// These KEY=value lines in vm.env, every other line as it was (numbers
    /// only: no quoting).
    func writeEnv(_ values: [String: String]) throws {
        let url = folder.appendingPathComponent("vm.env")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var done = Set<String>()
        lines = lines.map { line in
            for (k, v) in values where line.hasPrefix(k + "=") { done.insert(k); return "\(k)=\(v)" }
            return line
        }
        for (k, v) in values.sorted(by: { $0.key < $1.key }) where !done.contains(k) { lines.append("\(k)=\(v)") }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func load(from folder: URL) -> VMConfig? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("vm.env"), encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            var v = String(line[line.index(after: eq)...])
            if v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2 {
                v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            }
            values[String(line[..<eq])] = v
        }
        var c = VMConfig()
        c.location = folder.standardizedFileURL
        c.name = values["NAME"] ?? folder.lastPathComponent
        c.cpus = Int(values["CPUS"] ?? "") ?? c.cpus
        c.memoryMB = Int(values["MEM_MB"] ?? "") ?? c.memoryMB
        c.diskGB = Int(values["DISK_GB"] ?? "") ?? c.diskGB
        c.sshPort = Int(values["SSH_PORT"] ?? "") ?? c.sshPort
        c.user = values["VM_USER"] ?? ""
        c.fullName = values["VM_FULLNAME"] ?? ""
        c.hostname = values["VM_HOSTNAME"] ?? c.hostname
        c.timeZone = values["VM_TZ"] ?? c.timeZone
        c.language = values["VM_LANG"] ?? c.language
        c.keyboard = values["KEYBOARD"] ?? c.keyboard
        c.features = values["FEATURES"] ?? c.features
        return c
    }

    /// Every VM in the VMs folders: the current folder's first, each folder by name.
    static func all(roots: [URL] = Paths.vmsRoots) -> [VMConfig] {
        roots.flatMap { root -> [VMConfig] in
            let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return items.sorted(by: { $0.path < $1.path }).compactMap { load(from: $0) }
        }
    }

    static func named(_ name: String) -> VMConfig? {
        all().first { $0.name == name || $0.folder.lastPathComponent == name }
    }

    /// The VM the app manages (one at a time): the one named with --vm NAME,
    /// else the first folder with a vm.env. A name no VM has gives nil (the
    /// caller says so: VMPick.unknownText), never another VM.
    static func existing() -> VMConfig? {
        let all = all()
        switch VMPick.choose(requested: VMPick.requested(CommandLine.arguments),
                             vms: all.map { ($0.name, $0.folder.lastPathComponent) }) {
        case .vm(let i): return all[i]
        case .new, .unknown: return nil
        }
    }

    /// The name given with --vm when no VM has it.
    static var unknownRequested: String? {
        let all = all()
        if case .unknown(let n) = VMPick.choose(requested: VMPick.requested(CommandLine.arguments),
                                                vms: all.map { ($0.name, $0.folder.lastPathComponent) }) {
            return n
        }
        return nil
    }
}

/// What this Mac has, for the defaults.
enum Mac {
    static func sysctlInt(_ name: String) -> Int {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) != 0 { return 0 }
        return Int(value)
    }
    static var memoryGB: Int { sysctlInt("hw.memsize") / 1_073_741_824 }
    /// The address space macOS gives a VM, in bits (M1/M2: 36, M4: 40-42;
    /// nil when macOS does not say). The smaller of the two page sizes' values,
    /// as QEMU may use either. Graphics.hostmemMB needs it.
    static var vmAddressBits: Int? {
        let sizes = ["kern.hv.ipa_size_16k", "kern.hv.ipa_size_4k"].map(sysctlInt).filter { $0 > 0 }
        guard let s = sizes.min() else { return nil }
        return Int.bitWidth - 1 - s.leadingZeroBitCount
    }
    static var performanceCores: Int { max(2, sysctlInt("hw.perflevel0.physicalcpu")) }
    static var efficiencyCores: Int { sysctlInt("hw.perflevel1.physicalcpu") }
    static var cores: Int { max(2, sysctlInt("hw.ncpu")) }

    static let tierNames = ["Low", "Balanced", "High", "Best"]

    /// The tier these resources are, if any (the lowest when tiers coincide).
    static func tierIndex(cpus: Int, memoryMB: Int) -> Int? {
        (0..<4).first { tier($0).cpus == cpus && tier($0).memoryGB * 1024 == memoryMB }
    }

    /// Like `omacvm build`'s tiers: 0 low, 1 balanced, 2 high, 3 best.
    /// Best leaves macOS and the GPU max(8 GB, a quarter).
    static func tier(_ t: Int) -> (cpus: Int, memoryGB: Int) {
        let m = memoryGB
        let reserve = max(m / 4, 8)
        let best = max(m - reserve, 4)
        var cpus: Int, mem: Int
        switch t {
        case 0: cpus = max(performanceCores / 2, 2); mem = max(m / 4, 4)
        case 2: cpus = performanceCores + efficiencyCores / 2; mem = (m / 2 + best) / 2
        case 3: cpus = cores; mem = best
        default: cpus = performanceCores; mem = m / 2
        }
        return (cpus, max(4, min(mem, best)))
    }

    static var timeZone: String { TimeZone.current.identifier }

    /// What the build's scripts need on the Mac: a python3, and Swift for
    /// Mac helpers built from source. The app carries both ready made
    /// (build-app.sh: Resources/python, Helpers, Resources/tools), so only a
    /// copy without them (a development run) needs Xcode's Command Line Tools.
    /// Never runs /usr/bin/python3: on a Mac without the tools it asks to
    /// install them.
    static var buildToolsReady: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.resources.appendingPathComponent("python/bin/python3").path)
            || commandLineToolsInstalled
    }

    /// Xcode's Command Line Tools (xcode-select -p first, which never asks
    /// macOS to install them).
    static var commandLineToolsInstalled: Bool {
        func ok(_ tool: String, _ args: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        return ok("/usr/bin/xcode-select", ["-p"]) && ok("/usr/bin/xcrun", ["-f", "swiftc"])
    }

    /// Same rule as omacvm build: English unless the second preferred language says otherwise.
    static var language: String {
        let langs = Locale.preferredLanguages
        let lang = langs.count > 1 ? langs[1] : (langs.first ?? "en")
        if lang.hasPrefix("en") { return "en_US.UTF-8" }
        let parts = lang.split(separator: "-")
        if parts.count >= 2 { return "\(parts[0])_\(parts[parts.count - 1]).UTF-8" }
        let region = Locale.current.region?.identifier ?? "US"
        return "\(lang)_\(region).UTF-8"
    }

    /// The Linux keyboard layout matching the Mac's (omacvm's mac-layout.sh).
    static var keyboard: String {
        let script = Paths.resources.appendingPathComponent(omacvmSrc + "/keyboard/mac-layout.sh")
        let out = run("/bin/bash", [script.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "us" : out
    }

    /// OmacVM's VM side: a copy in the app, the repo's own src/ in the source tree.
    static var omacvmSrc: String {
        FileManager.default.fileExists(atPath: Paths.resources.appendingPathComponent("omacvm/src").path)
            ? "omacvm/src" : "../src"
    }

    static var linuxUserName: String {
        let raw = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let ascii = raw.unicodeScalars.filter { $0.isASCII }.map(String.init).joined()
        return ascii.isEmpty || ascii.first!.isNumber ? "user" : String(ascii.prefix(32))
    }

    static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// A free TCP port on 127.0.0.1, starting at `from`.
    static func freePort(from: Int) -> Int {
        for port in from..<(from + 200) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if ok { return port }
        }
        return from
    }
}

/// The launcher's own preferences.
enum Settings {
    /// The fence and frame path of 2.6.0 (fences polled every 1 ms, frames
    /// drawn by a CAOpenGLLayer on QEMU's 30 ms refresh), if the faster one
    /// ever misbehaves on a Mac. Everything else of the GPU stays as it is.
    /// Hidden: defaults write org.omacvm.app gpuSafeMode -bool true
    static var gpuSafeMode: Bool { UserDefaults.standard.bool(forKey: "gpuSafeMode") }
    /// QEMU's sound timing as up to 2.9.1 (main loop at the default QoS, the
    /// HDA catching up after a stall), if the new one ever misbehaves.
    /// Hidden: defaults write org.omacvm.app audioClassic -bool true
    static var audioClassic: Bool { UserDefaults.standard.bool(forKey: "audioClassic") }
    /// The sound card's DMA and the mixer on a real-time thread of their own
    /// (3.1.16), not in QEMU's main loop with the VM's GPU; AudioPath says
    /// whether by default. The VM window's switch (SoundThreadRow) or
    /// defaults write org.omacvm.app audioThread -bool true (or false);
    /// audioMainLoop -bool true keeps 3.1.14's path whatever the default, and
    /// audioClassic (2.9.1's timing) implies it. The switch writes the choice
    /// and drops audioMainLoop: the person chose.
    static var audioThread: Bool {
        get {
            let d = UserDefaults.standard
            if audioClassic || d.bool(forKey: "audioMainLoop") { return false }
            return d.object(forKey: "audioThread") as? Bool ?? AudioPath.threadByDefault
        }
        set {
            UserDefaults.standard.removeObject(forKey: "audioMainLoop")
            UserDefaults.standard.set(newValue, forKey: "audioThread")
        }
    }
    /// The VM's GPU work without QEMU's big lock (ADR 0046): virgl's
    /// commands that touch only the GPU run without the BQL, so the VM's
    /// CPUs and the window do not wait while an app opens or a page draws.
    /// On by default (3.1.18 to 3.1.25: off, experimental). The VM window's
    /// switch (GPUOffMainLoopRow) or
    /// defaults write org.omacvm.app gpuOffMainLoop -bool false;
    /// gpuMainLoop -bool true keeps the old path whatever the default, and
    /// GPU safe mode always does. The switch writes the choice and drops
    /// gpuMainLoop: the person chose.
    static var gpuOffMainLoop: Bool {
        get {
            let d = UserDefaults.standard
            if gpuSafeMode || d.bool(forKey: "gpuMainLoop") { return false }
            return d.object(forKey: "gpuOffMainLoop") as? Bool ?? true
        }
        set {
            UserDefaults.standard.removeObject(forKey: "gpuMainLoop")
            UserDefaults.standard.set(newValue, forKey: "gpuOffMainLoop")
        }
    }
    /// Vulkan windows without a copy (ADR 0047): a Vulkan app's frames are
    /// written into IOSurface memory that macOS OpenGL reads, instead of
    /// being copied by QEMU's main loop. KosmicKrisp (macOS 26 and newer)
    /// only; QEMU's virglrenderer decides and logs it (MoltenVK: the copy).
    /// On by default (3.1.24 and 3.1.25: off, experimental). The VM
    /// window's switch (VKWindowsNoCopyRow) or
    /// defaults write org.omacvm.app vkWindowsNoCopy -bool false;
    /// vkWindowsCopy -bool true keeps the copy whatever the default, and
    /// GPU safe mode always does. Read at each start of the VM.
    static var vkWindowsNoCopy: Bool {
        get {
            let d = UserDefaults.standard
            if gpuSafeMode || d.bool(forKey: "vkWindowsCopy") { return false }
            return d.object(forKey: "vkWindowsNoCopy") as? Bool ?? true
        }
        set {
            UserDefaults.standard.removeObject(forKey: "vkWindowsCopy")
            UserDefaults.standard.set(newValue, forKey: "vkWindowsNoCopy")
        }
    }
    /// Added to the sound delay the app tells the VM (AudioLatencyWatch), in
    /// ms, -500 ... 500: negative when the sound comes early in the VM's
    /// videos, positive when it still comes late (a device that under-reports).
    /// Hidden: defaults write org.omacvm.app audioDelayExtraMs -int -20
    static var audioDelayExtraMs: Int { min(max(UserDefaults.standard.integer(forKey: "audioDelayExtraMs"), -500), 500) }
    /// Seconds the firmware waits for a key (its boot manager) before it boots.
    /// 0, the default: it boots at once (the boot logo covers the firmware, so
    /// the wait only cost time: 5 s on every start up to 3.0.0).
    /// Hidden: defaults write org.omacvm.app firmwareWait -int 5 (the old wait)
    static var firmwareWait: Int { min(max(UserDefaults.standard.integer(forKey: "firmwareWait"), 0), 60) }
    /// Switches that are gone: their stored keys are removed once at launch,
    /// so nothing reads them and a later switch can take the name.
    /// vsyncLock: Frames in step with the Mac (experimental, 3.2.3 to 3.2.6),
    /// removed in 3.2.7: no gain worth its cost (ADR 0057). A VM it was on for
    /// draws as with it off; a downgrade to 3.2.6 reads it as off.
    @MainActor static func removeRetiredSwitches() {
        let d = UserDefaults.standard
        guard d.object(forKey: "vsyncLock") != nil else { return }
        d.removeObject(forKey: "vsyncLock")
        let l = "settings: Frames in step with the Mac was removed in 3.2.7; the VM draws as with it off"
        Updater.shared.log(l)
        FileHandle.standardError.write(Data("\(l)\n".utf8))
    }
    /// The hidden Vulkan switch up to 2.9 (`venus`): moved once into each
    /// VM's Graphics setting at the first 3.0.0 launch, then removed
    /// (Graphics.migrateVenusSwitch).
    @MainActor static func migrateVenusSwitch() {
        let d = UserDefaults.standard
        guard d.object(forKey: "venus") != nil else { return }
        let on = d.bool(forKey: "venus")
        let lines = on ? Graphics.migrateVenusSwitch(folders: VMConfig.all().map(\.folder)) : []
        d.removeObject(forKey: "venus")
        for l in ["the hidden venus switch was \(on ? "on" : "off"): moved into the VMs' Graphics setting and removed"] + lines {
            Updater.shared.log("graphics: \(l)")
            FileHandle.standardError.write(Data("graphics: \(l)\n".utf8))
        }
    }
    /// HDR and 10-bit colour (experimental, off by default): the VM's main
    /// window runs at 10 bits, and QEMU shows the HDR the guest sends with
    /// the Mac's EDR on a display that can show it. The VM loads its 10-bit
    /// virtio-gpu driver for it (built by Update VM). Other displays' windows
    /// stay 8-bit SDR. The VM window's switch (HDRRow) or
    /// defaults write org.omacvm.app hdr -bool true (the key it had while it
    /// was hidden). Read at each start of the VM (hdrStart).
    static var hdr: Bool {
        get { UserDefaults.standard.bool(forKey: "hdr") }
        set { UserDefaults.standard.set(newValue, forKey: "hdr") }
    }
    /// HDR for one start of the VM: the switch on, a display that can show
    /// HDR, and QEMU's IOSurface present (GPU safe mode's CAOpenGLLayer, or
    /// OMACVM_GL_PRESENT=layer in the app's environment, is 8-bit and
    /// untagged). Runner takes the guest's SMBIOS, QEMU's environment and
    /// the qemu.log line from this one answer; why says why not (or what
    /// it gets). Main thread (NSScreen).
    @MainActor static func hdrStart() -> (on: Bool, why: String) {
        if !hdr { return (false, "switch off") }
        if !Mac.hasHDRDisplay { return (false, "no display can show HDR") }
        if gpuSafeMode { return (false, "GPU safe mode") }
        if ProcessInfo.processInfo.environment["OMACVM_GL_PRESENT"] == "layer" {
            return (false, "OMACVM_GL_PRESENT=layer: frames in a CAOpenGLLayer")
        }
        return (true, "10-bit, HDR where the window's display can show it")
    }
    /// Extra brightness (experimental, off by default, ADR 0050): the VM's
    /// main window up to twice as bright as the Mac's white on an XDR
    /// display. QEMU reads this key itself while the VM runs (it runs as the
    /// app), so a change counts at once. The VM window's switch
    /// (ExtraBrightnessRow) or defaults write org.omacvm.app extraBrightness -bool true
    static var extraBrightness: Bool {
        get { UserDefaults.standard.bool(forKey: ExtraBrightness.key) }
        set { UserDefaults.standard.set(newValue, forKey: ExtraBrightness.key) }
    }
    /// Pause drawing while hidden (experimental, off by default): while the
    /// VM's main window cannot be seen the guest turns that display off and
    /// stops drawing. QEMU reads this key itself while the VM runs (it runs
    /// as the app), so a change counts at once. PauseWhileHiddenRow or
    /// defaults write org.omacvm.app pauseWhileHidden -bool true
    static var pauseWhileHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "pauseWhileHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "pauseWhileHidden") }
    }
    /// AirPods and media controls (docs/adr/0058): while something plays in
    /// the VM, the launcher is the Mac's Now Playing app, so AirPods, Control
    /// Center and the play keys go to the VM's player (MediaSession). On by
    /// default; off by default for the test identity, so a test VM that plays
    /// never takes the person's AirPods (a kit turns it on for its rows). The
    /// launcher watches the key: a change counts at once in a running VM.
    /// MediaControlsRow or defaults write org.omacvm.app mediaControls -bool false
    static var mediaControls: Bool {
        get { UserDefaults.standard.object(forKey: MediaControls.key) as? Bool ?? mediaControlsDefault(bundleID: Bundle.main.bundleIdentifier) }
        set { UserDefaults.standard.set(newValue, forKey: MediaControls.key) }
    }
    static func mediaControlsDefault(bundleID: String?) -> Bool {
        MediaControls.defaultOn(testIdentity: TestIdentity.isTest(bundleID))
    }
    /// Extra brightness at a start of the VM (ExtraBrightness.start): QEMU's
    /// OMACVM_EXTRA_BRIGHT (for a QEMU not started as the app) and the
    /// qemu.log line. Main thread (NSScreen).
    @MainActor static func extraBrightnessStart() -> (on: Bool, why: String) {
        ExtraBrightness.start(on: extraBrightness, display: Mac.hasExtraBrightnessDisplay, gpuSafeMode: gpuSafeMode,
                              layerPresent: ProcessInfo.processInfo.environment["OMACVM_GL_PRESENT"] == "layer")
    }
    /// macOS's own shortcuts (screenshots, Mission Control, Spotlight,
    /// Cmd+Tab ...) stay with macOS even while the VM has the keyboard: the
    /// default since RC11. Off (experimental): they all go to the VM while it
    /// has the keyboard (only the escape combo is macOS's); on the Mac mini
    /// that switch was not always handed back (macOS's brightness keys stopped
    /// working in macOS), so it waits for a fix.
    /// Hidden: defaults write org.omacvm.app macShortcuts -bool false
    static var macShortcuts: Bool { UserDefaults.standard.object(forKey: "macShortcuts") as? Bool ?? true }
    /// The globe (fn) key pressed on its own goes to the VM while it has the
    /// keyboard (Omarchy's emoji picker there), not to macOS's Emoji & Symbols
    /// (omacvm-cocoa-globe-key.patch). Off: macOS keeps it.
    /// Hidden: defaults write org.omacvm.app globeKeyToVM -bool false
    static var globeKeyToVM: Bool { UserDefaults.standard.object(forKey: "globeKeyToVM") as? Bool ?? true }
    /// The VM's window takes the pointer without a click (after a start, a
    /// guest reboot, or the window becoming key with the pointer on it).
    /// Off: QEMU's own way, on entering the window or a click.
    /// Hidden: defaults write org.omacvm.app pointerStart -bool false
    static var pointerStart: Bool { UserDefaults.standard.object(forKey: "pointerStart") as? Bool ?? true }
    /// Keyboard sharing apps (Synergy, Deskflow, Barrier, Input Leap, #350):
    /// OmacVM's event taps go at the end of macOS's chain, so the sharing app
    /// sees the keys first (QEMU's from the VM's next start, OMACVM_KEYS_LAST;
    /// Gestures and the Bridge read it too). Off by default. The VM window's
    /// switch (ShareKeyboardRow) or defaults write org.omacvm.app shareKeyboard -bool true
    static var shareKeyboard: Bool {
        get { ShareKeyboard.isOn(.standard) }
        set { UserDefaults.standard.set(newValue, forKey: ShareKeyboard.key) }
    }
    static var startFullScreen: Bool {
        get { UserDefaults.standard.object(forKey: "startFullScreen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "startFullScreen") }
    }
    /// Full screen hides the Dock and the menu bar on every display and keeps
    /// the Mac's cursor off the screen corners and the Dock's edge, so neither
    /// the Dock nor a hot corner comes up from inside the VM (QEMU's
    /// immersive=on). Off: macOS's own full screen.
    static var keepDockAway: Bool {
        get { UserDefaults.standard.object(forKey: "keepDockAway") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepDockAway") }
    }
    /// Pointer on its own layer (experimental, off by default): the VM loads
    /// its virtio-gpu driver with the cursor plane shown (SMBIOS
    /// omacvm.pointerplane=2, module option cursor_plane=1) and Hyprland puts
    /// the pointer there; QEMU shows that image over each display's window. A pointer
    /// move then no longer redraws the VM's screen (same picture, less GPU).
    /// Not with macPointer (that needs the hotspot this plane does not get).
    /// The VM window's switch (PointerPlaneRow) or
    /// defaults write org.omacvm.app pointerPlane -bool true. Read at each start.
    static var pointerPlane: Bool {
        get { UserDefaults.standard.bool(forKey: "pointerPlane") }
        set { UserDefaults.standard.set(newValue, forKey: "pointerPlane") }
    }
    /// Draw only what changed (experimental, off by default): QEMU's tiled
    /// present (OMACVM_GL_PRESENT_TILES=1, ADR 0055): a frame that changed in
    /// a few 256x256 tiles goes to WindowServer as those tiles only. The VM
    /// then loads OmacVM's virtio-gpu driver for its Linux 7.4 damage fix
    /// (SMBIOS omacvm.damage=1), so it says what changed; with the switch off
    /// the stock driver loads as before. Not in GPU safe mode. The VM window's
    /// switch (PresentTilesRow) or defaults write org.omacvm.app presentTiles
    /// -bool true. Read at each start (presentTilesStart).
    static var presentTiles: Bool {
        get { UserDefaults.standard.bool(forKey: "presentTiles") }
        set { UserDefaults.standard.set(newValue, forKey: "presentTiles") }
    }
    /// Draw only what changed for one start of the VM: the switch on and
    /// QEMU's IOSurface present (GPU safe mode's CAOpenGLLayer, or
    /// OMACVM_GL_PRESENT=layer, shows whole frames only). Runner takes QEMU's
    /// environment, the guest's SMBIOS and the qemu.log line from this one
    /// answer; why says why not.
    static func presentTilesStart() -> (on: Bool, why: String) {
        if !presentTiles { return (false, "switch off") }
        if gpuSafeMode { return (false, "GPU safe mode") }
        if ProcessInfo.processInfo.environment["OMACVM_GL_PRESENT"] == "layer" {
            return (false, "OMACVM_GL_PRESENT=layer: frames in a CAOpenGLLayer")
        }
        return (true, "the VM's driver says what changed, QEMU shows it in tiles")
    }
    /// Ghostty on the Mac's GPU (experimental, off by default; ADR 0064's
    /// amendment): a start with Vulkan on KosmicKrisp tells the VM (SMBIOS
    /// omacvm.glzink=1) and its EGL vendor library starts Ghostty on Zink
    /// over Venus with OpenGL 4.3 instead of Mesa's CPU renderer. The VM
    /// window's switch (GhosttyGPURow) or defaults write org.omacvm.app
    /// ghosttyGPU -bool true. Read at each start (ghosttyGPUStart).
    static var ghosttyGPU: Bool {
        get { UserDefaults.standard.bool(forKey: "ghosttyGPU") }
        set { UserDefaults.standard.set(newValue, forKey: "ghosttyGPU") }
    }
    /// Ghostty on the Mac's GPU for one start: the switch, GPU safe mode, and
    /// this start's graphics (Venus) and Vulkan driver (GhosttyGPU.start).
    /// Runner takes the guest's SMBIOS and the qemu.log line from this answer.
    static func ghosttyGPUStart(venus: Bool, driver: VulkanDriverKind) -> (on: Bool, why: String) {
        GhosttyGPU.start(switchOn: ghosttyGPU, safeMode: gpuSafeMode, venus: venus, driver: GhosttyGPU.Driver(driver))
    }
    /// Experimental, off by default, no switch in the window yet: the VM
    /// puts its pointer on virtio-gpu's cursor plane and the Mac's own cursor
    /// shows it (QEMU's OMACVM_HW_CURSOR, the guest's omacvm.hwcursor), so it
    /// moves without waiting for a guest frame and does not flicker between
    /// the VM, Omanotch and other displays. Hyprland 0.56 in Omarchy does not
    /// use the cursor plane yet (docs/routes/app.md), so it changes nothing
    /// there today. From the VM's next start.
    /// Hidden: defaults write org.omacvm.app macPointer -bool true
    static var macPointer: Bool { UserDefaults.standard.bool(forKey: "macPointer") }
}

extension GhosttyGPU.Driver {
    init(_ k: VulkanDriverKind) {
        switch k {
        case .kosmicKrisp: self = .kosmicKrisp
        case .moltenVK: self = .moltenVK
        case .listed: self = .listed
        }
    }
}

extension Mac {
    /// The built-in display has a camera notch. Asked at run time from the
    /// display itself (no model list); false with the lid closed, on a Mac
    /// without a notch, or at a resolution that ends below the notch.
    /// Main thread (NSScreen).
    static var hasNotch: Bool {
        NSScreen.screens.contains { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) != 0 else { return false }
            return s.auxiliaryTopLeftArea != nil && s.safeAreaInsets.top > 0
        }
    }

    /// The built-in display's camera housing in points, for FullPanel
    /// (NotchArea): nil without a notch now (lid closed, a Mac without one,
    /// a resolution below the notch). Main thread (NSScreen).
    static var notchGeometry: NotchGeometry? {
        guard let s = NSScreen.screens.first(where: { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }), let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 else { return nil }
        let f = s.frame
        let g = NotchGeometry(left: Double(l.maxX - f.minX), right: Double(r.minX - f.minX),
                              strip: NotchGeometry.strip(menuBar: Double(max(0, f.maxY - s.visibleFrame.maxY)),
                                                         safeTop: Double(s.safeAreaInsets.top)),
                              width: Double(f.width), height: Double(f.height))
        return g.valid ? g : nil
    }

    /// A display that can show HDR (EDR headroom above SDR white: the XDR
    /// panel of a MacBook Pro, a Pro Display XDR, an HDR external). Macs
    /// without one (MacBook Air, SDR monitors) keep the 8-bit SDR path.
    /// Test builds: OMACVM_TEST_EDR ("potential,headroom", QEMU's stand-in
    /// for the window's display) decides instead, so a hidden test VM on an
    /// SDR Mac can start with HDR.
    static var hasHDRDisplay: Bool {
        if let t = TestHooks.value("OMACVM_TEST_EDR", bundleID: Bundle.main.bundleIdentifier),
           let p = Double(t.split(separator: ",").first ?? "") {
            return p > 1
        }
        return NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }

    /// A display with EDR headroom above 2x (an XDR panel, an HDR monitor):
    /// extra brightness's row. A MacBook Air reports 2 and has none. Test
    /// builds: QEMU's made-up display (OMACVM_TEST_EDR=potential,headroom)
    /// counts here too, so the VM's switch can be tested on any Mac.
    static var hasExtraBrightnessDisplay: Bool {
        if let v = TestHooks.value("OMACVM_TEST_EDR", bundleID: Bundle.main.bundleIdentifier),
           let p = v.split(separator: ",").first.flatMap({ Double($0) }) {
            return ExtraBrightness.available(potentials: [p])
        }
        return ExtraBrightness.available(potentials: NSScreen.screens.map {
            Double($0.maximumPotentialExtendedDynamicRangeColorComponentValue)
        })
    }

    /// A MacBook: its battery shows in Omarchy's bar.
    static let hasBattery: Bool = HostBatterySnapshot.capture().present

    /// This Mac's hardware UUID (IOPlatformUUID), for RunMarker.
    static let hardwareID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let v = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return v ?? "unknown"
    }()

    /// The Mac's name as Sharing shows it.
    static var computerName: String { Host.current().localizedName ?? "another Mac" }
}

/// OmacVM's own version (src/VERSION in the app) and the VM's, for Update VM.
enum OmacVMVersion {
    static var app: String? {
        let url = Paths.resources.appendingPathComponent(Mac.omacvmSrc + "/VERSION")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return Version(v) == nil ? nil : v
    }

    /// The VM has an older OmacVM than the app (none recorded counts as older).
    static func vmIsBehind(_ vm: String?, app: String) -> Bool {
        guard let a = Version(app) else { return false }
        guard let v = vm.flatMap(Version.init) else { return true }
        return v < a
    }
}
