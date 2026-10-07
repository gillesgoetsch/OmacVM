import Foundation

/// The Mac's proxy at a VM's start (#122), as src/lib/proxy.sh reads it for a
/// build: the app's environment first (http_proxy, https_proxy, all_proxy,
/// either case), else macOS's network settings (the dictionary
/// CFNetworkCopySystemProxySettings returns, which scutil --proxy prints).
/// A proxy on the Mac's own 127.0.0.1 gets its port through to the VM on
/// QEMU's user network (patched libslirp: the VM's 10.0.2.2:PORT is the Mac's
/// 127.0.0.1:PORT), so a VM built behind it keeps working. A proxy elsewhere
/// needs nothing from the app. PAC files and WPAD are not read: `note` says so.
public struct MacProxy: Equatable {
    public struct Entry: Equatable {
        public let kind: String   // "http", "https", "socks"
        public let host: String
        public let port: Int
        public init(kind: String, host: String, port: Int) { self.kind = kind; self.host = host; self.port = port }
        public var loopback: Bool { MacProxy.isLoopback(host) }
    }

    public var entries: [Entry] = []
    /// A setting that was found and is not used (PAC, WPAD), or nil.
    public var note: String?
    /// "environment", "settings", or "" without a proxy.
    public var source = ""

    public init(settings: [String: Any], environment: [String: String] = [:]) {
        let env = { (k: String) -> String? in
            let v = environment[k] ?? environment[k.uppercased()]
            return (v?.isEmpty ?? true) ? nil : v
        }
        let fromEnv: [(String, String?)] = [("http", env("http_proxy")), ("https", env("https_proxy")), ("socks", env("all_proxy"))]
        if fromEnv.contains(where: { $0.1 != nil }) {
            source = "environment"
            for (kind, value) in fromEnv {
                guard let value else { continue }
                if let e = MacProxy.parse(url: value, kind: kind) { entries.append(e) } else {
                    note = "\(kind == "socks" ? "all" : kind)_proxy is not a proxy address OmacVM can use"
                }
            }
            return
        }
        func int(_ k: String) -> Int? {
            if let n = settings[k] as? NSNumber { return n.intValue }
            if let s = settings[k] as? String { return Int(s) }
            return nil
        }
        for (kind, key) in [("http", "HTTP"), ("https", "HTTPS"), ("socks", "SOCKS")] {
            guard int("\(key)Enable") == 1, let host = settings["\(key)Proxy"] as? String, !host.isEmpty else { continue }
            let port = int("\(key)Port") ?? 0
            if (1...65535).contains(port) { entries.append(Entry(kind: kind, host: host, port: port)) }
        }
        if !entries.isEmpty { source = "settings" }
        if int("ProxyAutoConfigEnable") == 1 {
            note = "macOS uses a proxy auto-config (PAC) file, which OmacVM does not read"
        } else if int("ProxyAutoDiscoveryEnable") == 1 && entries.isEmpty {
            note = "macOS finds its proxy automatically (WPAD), which OmacVM does not"
        }
    }

    /// The Mac's settings now.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> MacProxy {
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        return MacProxy(settings: settings, environment: environment)
    }

    /// scheme://[user:password@]host[:port][/] -> host and port (1080 when
    /// none, as curl); nil for anything else.
    static func parse(url: String, kind: String) -> Entry? {
        var rest = Substring(url)
        if let r = rest.range(of: "://") { rest = rest[r.upperBound...] }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        var host: Substring, port: Substring = ""
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[...close]
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = after.dropFirst() } else if !after.isEmpty { return nil }
        } else if let colon = rest.firstIndex(of: ":") {
            host = rest[..<colon]; port = rest[rest.index(after: colon)...]
            if port.contains(":") { return nil }
        } else {
            host = rest
        }
        let p = port.isEmpty ? 1080 : Int(port) ?? 0
        guard !host.isEmpty, host != "[]", (1...65535).contains(p) else { return nil }
        return Entry(kind: kind, host: String(host), port: p)
    }

    static func isLoopback(_ host: String) -> Bool {
        host.hasPrefix("127.") || ["localhost", "::1", "[::1]", "0.0.0.0"].contains(host.lowercased())
    }

    /// Ports of the proxies on the Mac's 127.0.0.1, each once.
    public var loopbackPorts: [Int] {
        var seen: [Int] = []
        for e in entries where e.loopback && !seen.contains(e.port) { seen.append(e.port) }
        return seen
    }

    /// OMACVM_SLIRP_HOST_PORTS with the proxy's ports added (a port already
    /// listed, also as "PORT>OTHER", is not added again).
    public func addingPorts(to list: String) -> String {
        let listed = Set(list.split(separator: ",").compactMap { Int($0.split(separator: ">").first ?? "") })
        let extra = loopbackPorts.filter { !listed.contains($0) }.map(String.init)
        return ([list].filter { !$0.isEmpty } + extra).joined(separator: ",")
    }

    /// For qemu.log: "none", or "http 127.0.0.1:7890 (to the VM as 10.0.2.2:7890), ...".
    /// `fastNetwork`: the VM is on vmnet, where the Mac's 127.0.0.1 is out of reach.
    public func record(fastNetwork: Bool) -> String {
        var parts = entries.map { e -> String in
            "\(e.kind) \(e.host):\(e.port)" + (e.loopback ? (fastNetwork ? " (not reachable on the fast network)" : " (to the VM as 10.0.2.2:\(e.port))") : "")
        }
        if parts.isEmpty { parts = ["none"] }
        return parts.joined(separator: ", ") + (source.isEmpty ? "" : " from the \(source == "settings" ? "network settings" : "environment")")
            + (note.map { "; \($0)" } ?? "")
    }
}
