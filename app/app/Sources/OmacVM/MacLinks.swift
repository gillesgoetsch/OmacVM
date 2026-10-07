import Foundation

/// What of the Mac one VM may use, from its features: `omacvm apply` writes
/// them into the VM's folder (`features`: "bridge=on gestures=off ...").
/// A feature that is off gets nothing from the Mac: its port on the Mac's
/// 127.0.0.1 stays closed to this VM (patched libslirp) and the app does not
/// serve its virtio port. No file (a VM set up before this): everything, as
/// before. The fast network (vmnet) reaches the Mac directly: there only the
/// VM side keeps a feature that is off away from the Mac.
struct MacLinks: Equatable {
    var omanotch = true   // Omanotch, 127.0.0.1:47811
    var gestures = true   // OmacVM Gestures, 127.0.0.1:47830
    var bridge = true     // OmacVM Bridge, 127.0.0.1:47831
    var battery = true    // the app's battery port
    var camera = true     // the app's camera port
    /// Touch ID (org.omacvm.auth): off unless the file says touch-id=on
    /// (a feature that is off by default; VMs set up before it never had it).
    /// Only then does the VM get the port at all.
    var touchID = false

    init() {}

    /// From the file's text; a feature it does not name stays on.
    init(features text: String) {
        var on: [String: Bool] = [:]
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { on[String(kv[0])] = kv[1] == "on" }
        }
        omanotch = on["omanotch"] ?? true
        gestures = on["gestures"] ?? true
        bridge = on["bridge"] ?? true
        battery = on["battery"] ?? true
        camera = on["camera"] ?? true
        touchID = on["touch-id"] ?? false
    }

    static func load(folder: URL) -> MacLinks {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("features"), encoding: .utf8) else {
            return MacLinks()
        }
        return MacLinks(features: text)
    }

    /// OMACVM_SLIRP_HOST_PORTS: empty means none.
    var hostPorts: String { hostPorts(test: TestIdentity.isOn) }

    /// The test identity's VMs reach its own Gestures and Bridge (47930,
    /// 47931) on the usual guest ports, and never the installed helpers.
    /// Omanotch goes to 47911, where only a test Omanotch listens (its
    /// `port` setting; src/omanotch/README.md), never the installed one.
    func hostPorts(test: Bool) -> String {
        let ports = test
            ? [(omanotch, "47811>47911"), (gestures, "47830>47930"), (bridge, "47831>47931")]
            : [(omanotch, "47811"), (gestures, "47830"), (bridge, "47831")]
        return ports.filter { $0.0 }.map { $0.1 }.joined(separator: ",")
    }

    /// For qemu.log, which omacvm check reads: "Omanotch on, Gestures off, ...".
    var record: String {
        [("Omanotch", omanotch), ("Gestures", gestures), ("Bridge", bridge), ("battery", battery), ("camera", camera),
         ("Touch ID", touchID)]
            .map { "\($0.0) \($0.1 ? "on" : "off")" }.joined(separator: ", ")
    }
}

/// OmacVM's test identity ("OmacVM Test", app/scripts/build-app.sh
/// --test-identity): its own Gestures and Bridge in Contents/Helpers, on
/// their own ports and folders. A test VM never reaches the installed helpers.
enum TestIdentity {
    static let isOn = isTest(Bundle.main.bundleIdentifier)
    /// org.omacvm.app.test, and a lane's copy of it re-signed as
    /// org.omacvm.app.test.<lane>: such a copy counted as the release app
    /// before, so it used the installed helpers' ports and the user's files.
    static func isTest(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == "org.omacvm.app.test" || id.hasPrefix("org.omacvm.app.test.")
    }
    /// The Bridge's folder (token, relay key, relay socket).
    static let bridgeFolder = isOn ? "omacvm-test-bridge" : "omacvm-bridge"
    /// For the scripts the app runs: their Mac side starts the test helpers
    /// and keeps away from the installed ones (src/mac/install.sh).
    static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var e = base
        if isOn { e["OMACVM_TEST_IDENTITY"] = "1" }
        return e
    }
}
