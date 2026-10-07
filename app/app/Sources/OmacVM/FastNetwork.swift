import Foundation
import OmacVMNet
import Security

/// The fast network (feature fast-network, off by default): the VM on macOS's
/// vmnet, shared mode, on a network of its own, 192.168.77.0/24 (the Mac is
/// 192.168.77.1), through omacvm-netd, OmacVM's small root daemon
/// (src/net/mac), instead of QEMU's user network (libslirp).
/// `omacvm enable fast-network`, or the app's Fast Network button, installs
/// the daemon and writes the VM's fast-network file (its MAC address). Without
/// the daemon, or when the daemon would not take this app's QEMU, the VM gets
/// the user network as before, and the reason goes to logs/network and
/// qemu.log (omacvm check reads it).
enum FastNetwork {
    static let socket = "/var/run/org.omacvm.netd.sock"
    static let daemonPlist = "/Library/LaunchDaemons/org.omacvm.netd.plist"
    /// The user network's MAC address, as before the fast network.
    static let defaultMAC = "52:54:00:12:34:56"

    struct Choice {
        let vmnet: Bool
        let mac: String
        /// "vmnet", or "slirp" and why (one line).
        let record: String
    }

    static func choose(for c: VMConfig) -> Choice {
        let file = c.folder.appendingPathComponent("fast-network")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return Choice(vmnet: false, mac: defaultMAC, record: "slirp off")
        }
        // mac=52:54:00:xx:xx:xx (written by omacvm enable fast-network).
        var mac = defaultMAC
        for line in text.split(separator: "\n") where line.hasPrefix("mac=") {
            let m = String(line.dropFirst(4)).lowercased()
            if m.range(of: "^52:54:00(:[0-9a-f]{2}){3}$", options: .regularExpression) != nil { mac = m }
        }
        func slirp(_ why: String) -> Choice { Choice(vmnet: false, mac: mac, record: "slirp \(why)") }
        if let why = serviceProblem() { return slirp("\(why) (omacvm enable fast-network)") }
        // A LAN or VPN on the same addresses: vmnet would refuse (and each
        // refusal costs macOS's vmnet service for good, see omacvm-netd.c).
        if let other = subnetTaken() {
            return slirp("\(subnet).0/24 is taken on this Mac (\(other)): the fast network needs it")
        }
        return Choice(vmnet: true, mac: mac, record: "vmnet")
    }

    /// What keeps omacvm-netd from taking this app's QEMU for this Mac user,
    /// nil when nothing does.
    static func serviceProblem() -> String? {
        var st = stat()
        guard FileManager.default.fileExists(atPath: daemonPlist),
              lstat(socket, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK else {
            return "omacvm-netd is not installed"
        }
        guard let args = daemonArguments(), let i = args.firstIndex(of: "--requirement"), i + 1 < args.count else {
            return "omacvm-netd's settings are unreadable"
        }
        // It takes VMs of the users it was installed for only.
        let me = String(getuid())
        guard args.indices.contains(where: { args[$0] == "--user" && $0 + 1 < args.count && args[$0 + 1] == me }) else {
            return "omacvm-netd was installed for another user of this Mac"
        }
        guard qemuSatisfies(args[i + 1]) else { return "omacvm-netd was installed for another build of the app" }
        return nil
    }

    // MARK: the app's Fast Network button

    /// The VM uses the fast network from its next start (its fast-network file).
    static func isOn(_ c: VMConfig) -> Bool {
        ((try? c.folder.appendingPathComponent("fast-network").resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    /// The network the VM took at its last start, as logs/network's first line says.
    static func lastRecord(_ c: VMConfig) -> String? {
        (try? String(contentsOf: c.folder.appendingPathComponent("logs/network"), encoding: .utf8))?
            .split(separator: "\n").first.map(String.init)
    }

    /// Turns the fast network on for VM `c`: installs the service when this
    /// app's QEMU cannot use it yet (macOS asks for an administrator's
    /// password once), then writes the VM's fast-network file. Only when the
    /// person presses the button. Blocks until done; nil when it worked, else
    /// what went wrong (nothing changed then).
    static func turnOn(_ c: VMConfig) -> String? {
        if serviceProblem() != nil, let err = runInstaller([]) { return err }
        let file = c.folder.appendingPathComponent("fast-network")
        if isOn(c) { record(c, on: true); return nil }
        let b = (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
        do { try Data("mac=52:54:00:\(b.joined(separator: ":"))\n".utf8).write(to: file) } catch {
            return "could not write \(file.path): \(error.localizedDescription)"
        }
        record(c, on: true)
        return nil
    }

    /// The VM's record of its features (its features file, which the VM's
    /// first apply writes) says what the button did. The VM's own copy
    /// follows with the next omacvm check, features or apply.
    private static func record(_ c: VMConfig, on: Bool) {
        let url = c.folder.appendingPathComponent("features")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let new = FeaturesRecord.set(text, "fast-network", on: on)
        if new != text { try? new.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Turns it off for VM `c`, and takes the service off this Mac user when
    /// no other VM of theirs has the fast network (password once). The VM
    /// moves to QEMU's user network within seconds if it runs on vmnet.
    static func turnOff(_ c: VMConfig) -> String? {
        let others = ((try? FileManager.default.contentsOfDirectory(at: Paths.vmsRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.standardizedFileURL != c.folder.standardizedFileURL }
            .compactMap { VMConfig.load(from: $0) }.filter { isOn($0) }
        if others.isEmpty, FileManager.default.fileExists(atPath: daemonPlist), let err = runInstaller(["--remove"]) {
            return err
        }
        do { try FileManager.default.removeItem(at: c.folder.appendingPathComponent("fast-network")) } catch {
            if isOn(c) { return "could not remove the VM's fast-network file: \(error.localizedDescription)" }
        }
        record(c, on: false)
        return nil
    }

    /// src/net/mac/install.sh from the app's copy of OmacVM, for this app,
    /// with macOS's password dialog. nil when it worked, else its message.
    private static func runInstaller(_ args: [String]) -> String? {
        let script = Paths.resources.appendingPathComponent("omacvm/src/net/mac/install.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return "this app has no fast network installer (\(script.path))"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + (args.isEmpty ? ["--app", Bundle.main.bundlePath] : args)
        var env = ProcessInfo.processInfo.environment
        env["OMACVM_ADMIN_PROMPT"] = "gui"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        if p.terminationStatus == 4 { return "Cancelled: nothing changed." }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").last.map(String.init) ?? "the installer failed (\(p.terminationStatus))"
    }

    /// The fast network's addresses: 192.168.77.0/24, the Mac is .1.
    static let subnet = "192.168.77"

    /// An interface other than a VM bridge (vmnet's bridgeN, where the fast
    /// network itself sits) with an address in the subnet: its name.
    private static func subnetTaken() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("bridge") { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if String(cString: host).hasPrefix(subnet + ".") { return name }
        }
        return nil
    }

    /// The daemon's arguments (its launchd plist): the code requirement it
    /// checks callers against and the users it takes.
    private static func daemonArguments() -> [String]? {
        guard let data = FileManager.default.contents(atPath: daemonPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["ProgramArguments"] as? [String]
    }

    /// The daemon would accept this app's QEMU: same check as its own, on the file.
    private static func qemuSatisfies(_ text: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(Paths.qemu as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
