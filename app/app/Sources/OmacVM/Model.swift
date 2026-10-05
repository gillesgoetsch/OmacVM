import AppKit
import Foundation

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

    /// The folder that holds the VM folders. The user can pick another one
    /// (an external drive, say) in the setup.
    static var vmsRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: "vmsRoot"), !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return appSupport.appendingPathComponent("VMs")
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
    // Omanotch off: its released Mac app does not listen on 127.0.0.1 yet,
    // so an app VM (10.0.2.2) never reaches it.
    var features = "bridge=on wallpaper=on gestures=on scroll-momentum=off omanotch=off mac-clock=on camera=on battery=\(Mac.hasBattery ? "on" : "off") idle-lock=on autologin=off thp-kernel=off"

    var folder: URL { Paths.vmsRoot.appendingPathComponent(name) }

    /// Like build.sh's VM names: letters, digits, space . _ -, at most 64,
    /// no "." or ".." (the folder must stay inside the VMs folder).
    static func validName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", options: .regularExpression) != nil
            && !name.contains("..")
    }

    /// The folder is a VM folder of ours: directly inside the VMs folder, with vm.env.
    var folderIsSafe: Bool {
        folder.standardizedFileURL.deletingLastPathComponent().path == Paths.vmsRoot.standardizedFileURL.path
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("vm.env").path)
    }
    var disk: URL { folder.appendingPathComponent("disk.img") }
    var efiVars: URL { folder.appendingPathComponent("efi-vars.fd") }
    var readyMarker: URL { folder.appendingPathComponent("ready") }
    var isReady: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

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

    func write() throws {
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
        let url = folder.appendingPathComponent("vm.env")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var cpusDone = false, memDone = false
        lines = lines.map { line in
            if line.hasPrefix("CPUS=") { cpusDone = true; return "CPUS=\(cpus)" }
            if line.hasPrefix("MEM_MB=") { memDone = true; return "MEM_MB=\(memoryMB)" }
            return line
        }
        if !cpusDone { lines.append("CPUS=\(cpus)") }
        if !memDone { lines.append("MEM_MB=\(memoryMB)") }
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

    static func named(_ name: String) -> VMConfig? {
        let items = (try? FileManager.default.contentsOfDirectory(at: Paths.vmsRoot, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { load(from: $0) }.first { $0.name == name || $0.folder.lastPathComponent == name }
    }

    /// The VM the app manages (one at a time): the one named with --vm NAME,
    /// else the first folder with a vm.env.
    static func existing() -> VMConfig? {
        let root = Paths.vmsRoot
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let all = items.sorted(by: { $0.path < $1.path }).compactMap { load(from: $0) }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--vm"), i + 1 < args.count {
            return all.first { $0.name == args[i + 1] || $0.folder.lastPathComponent == args[i + 1] }
        }
        return all.first
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

    /// Xcode's Command Line Tools: the build compiles OmacVM's Mac helpers.
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
    static var startFullScreen: Bool {
        get { UserDefaults.standard.object(forKey: "startFullScreen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "startFullScreen") }
    }
    /// Full screen also covers the strip beside the notch; Omarchy's bar goes
    /// there. Off by default: that full screen has no Space of its own (macOS
    /// keeps full-screen Spaces below the notch).
    static var useNotch: Bool {
        get { UserDefaults.standard.object(forKey: "useNotch") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "useNotch") }
    }
}

extension Mac {
    /// The built-in display has a camera housing.
    static var hasNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    /// A MacBook: its battery shows in Omarchy's bar.
    static let hasBattery: Bool = HostBatterySnapshot.capture().present
}
