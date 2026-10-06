import AppKit
import Foundation
import OmacVMUpdate
import OmacVMFeatures

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
            if let custom = UserDefaults.standard.string(forKey: "vmsRoot"), !custom.isEmpty {
                return URL(fileURLWithPath: custom)
            }
            return defaultVMsRoot
        }
        set { UserDefaults.standard.set(newValue.standardizedFileURL.path, forKey: "vmsRoot") }
    }
    /// Decided once per launch: the VMs folder must not change under a VM
    /// that runs or is being built.
    private static let defaultVMsRoot = VMsFolder.resolve(custom: nil, home: VMsFolder.home)

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
        for r in [vmsRoot] + otherVMsRoots + [legacyVMsRoot] {
            let p = r.standardizedFileURL.path
            if seen.insert(p).inserted { roots.append(r.standardizedFileURL) }
        }
        return roots
    }

    /// The Omarchy images OmacVM.app downloaded to set up VMs (try-omarchy, prebuilt VMs); Storage > Downloaded images > Remove empties it.
    static let downloads = VMsFolder.home.appendingPathComponent("Library/Caches/omacvm")

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
        if let drive = Storage.missingDrive(for: folder) {
            return "\(drive) is not connected. \(name) is on it (\(Storage.short(folder))): connect it, then start again."
        }
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
    static func all() -> [VMConfig] {
        Paths.vmsRoots.flatMap { root -> [VMConfig] in
            let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return items.sorted(by: { $0.path < $1.path }).compactMap { load(from: $0) }
        }
    }

    static func named(_ name: String) -> VMConfig? {
        all().first { $0.name == name || $0.folder.lastPathComponent == name }
    }

    /// The VM the app manages (one at a time): the one named with --vm NAME,
    /// else the first folder with a vm.env.
    static func existing() -> VMConfig? {
        let all = all()
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
    /// The fence and frame path of 2.6.0 (fences polled every 1 ms, frames
    /// drawn by a CAOpenGLLayer on QEMU's 30 ms refresh), if the faster one
    /// ever misbehaves on a Mac. Everything else of the GPU stays as it is.
    /// Hidden: defaults write org.omacvm.app gpuSafeMode -bool true
    static var gpuSafeMode: Bool { UserDefaults.standard.bool(forKey: "gpuSafeMode") }
    /// QEMU's sound timing as up to 2.9.1 (main loop at the default QoS, the
    /// HDA catching up after a stall), if the new one ever misbehaves.
    /// Hidden: defaults write org.omacvm.app audioClassic -bool true
    static var audioClassic: Bool { UserDefaults.standard.bool(forKey: "audioClassic") }
    /// Seconds the firmware waits for a key (its boot manager) before it boots.
    /// 0, the default: it boots at once (the boot logo covers the firmware, so
    /// the wait only cost time: 5 s on every start up to 3.0.0).
    /// Hidden: defaults write org.omacvm.app firmwareWait -int 5 (the old wait)
    static var firmwareWait: Int { min(max(UserDefaults.standard.integer(forKey: "firmwareWait"), 0), 60) }
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
    /// HDR: a 10-bit guest output is shown as BT.2100 PQ with the Mac's EDR,
    /// and the guest's display sync turns HDR on once its 10-bit virtio-gpu
    /// module runs (omacvm-virtio-gpu-build in the VM, then a restart).
    /// Hidden: defaults write org.omacvm.app hdr -bool true
    static var hdr: Bool { UserDefaults.standard.bool(forKey: "hdr") }
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
    /// HDR as the VM gets it: only while a display can show it.
    static var hdrActive: Bool { hdr && Mac.hasHDRDisplay }
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

    /// A display that can show HDR (EDR headroom above SDR white: the XDR
    /// panel of a MacBook Pro, a Pro Display XDR, an HDR external). Macs
    /// without one (MacBook Air, SDR monitors) keep the 8-bit SDR path.
    static var hasHDRDisplay: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
    }

    /// A MacBook: its battery shows in Omarchy's bar.
    static let hasBattery: Bool = HostBatterySnapshot.capture().present
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
