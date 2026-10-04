import Foundation
import Security

/// The fast network (feature fast-network, off by default): the VM on macOS's
/// vmnet shared network (the Mac is 192.168.64.1) through omacvm-netd, OmacVM's
/// small root daemon (src/net/mac), instead of QEMU's user network (libslirp).
/// `omacvm enable fast-network` installs the daemon and writes the VM's
/// fast-network file (its MAC address). Without the daemon, or when the daemon
/// would not take this app's QEMU, the VM gets the user network as before,
/// and the reason goes to logs/network and qemu.log (omacvm check reads it).
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
        var st = stat()
        guard FileManager.default.fileExists(atPath: daemonPlist),
              lstat(socket, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK else {
            return slirp("omacvm-netd is not installed (omacvm enable fast-network)")
        }
        guard let args = daemonArguments(), let i = args.firstIndex(of: "--requirement"), i + 1 < args.count else {
            return slirp("omacvm-netd's settings are unreadable (omacvm enable fast-network)")
        }
        let req = args[i + 1]
        // It takes VMs of the users it was installed for only.
        let me = String(getuid())
        guard args.indices.contains(where: { args[$0] == "--user" && $0 + 1 < args.count && args[$0 + 1] == me }) else {
            return slirp("omacvm-netd was installed for another user of this Mac (omacvm enable fast-network)")
        }
        guard qemuSatisfies(req) else {
            return slirp("omacvm-netd was installed for another build of the app (omacvm enable fast-network)")
        }
        return Choice(vmnet: true, mac: mac, record: "vmnet")
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
