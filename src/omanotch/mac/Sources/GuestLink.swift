import Darwin
import Foundation
import Network

/// A host-side address of a VM network: the Mac's end of the network the
/// guest is on (Parallels: 10.211.55.2 on a vnic/bridge interface, UTM's
/// shared network: 192.168.64.1 on bridge100).
struct VMInterface: Hashable {
    let name: String
    let address: UInt32  // host byte order
    let netmask: UInt32

    var addressString: String {
        "\(address >> 24).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
    }

    /// A peer in this network, other than the Mac's own address. On the
    /// loopback (OmacVM.app's VMs) the peer is the Mac's 127.0.0.1 itself.
    func contains(_ ip: UInt32) -> Bool {
        if self == Self.omacvmApp { return ip == address }
        return ip & netmask == address & netmask && ip != address
    }

    /// OmacVM.app's VMs reach the Mac's 127.0.0.1 (QEMU's user network).
    static let omacvmApp = VMInterface(name: "lo0", address: 0x7F00_0001, netmask: 0xFF00_0000)

    /// The Mac's address on OmacVM.app's fast network (vmnet through
    /// omacvm-netd, src/net/mac): 192.168.77.1 on a bridgeN.
    static let omacvmFastAddress: UInt32 = 0xC0A8_4D01

    /// A network of OmacVM.app's VMs: the loopback or its fast network. Its
    /// guests prove the Bridge's token and are told apart by their VM name.
    var isOmacVMApp: Bool { self == Self.omacvmApp || address == Self.omacvmFastAddress }

    static func parse(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    /// "a.b.c.d/nn" → (network, mask).
    static func parseSubnet(_ s: String) -> (UInt32, UInt32)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let net = parse(String(parts[0])), let bits = Int(parts[1]), (0 ... 32).contains(bits)
        else { return nil }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
        return (net & mask, mask)
    }

    /// IPv4 addresses of the interfaces whose names start with one of the
    /// prefixes and whose network is one of `subnets` (VM shared networks;
    /// this keeps out Internet Sharing and Thunderbolt bridges), or the
    /// interface that carries `onlyAddress`.
    static func scan(prefixes: [String], subnets: [(UInt32, UInt32)], onlyAddress: UInt32?) -> [VMInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let wanted = onlyAddress
        var out: [VMInterface] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = ifa.ifa_netmask,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if let wanted {
                if addr == wanted { out.append(VMInterface(name: name, address: addr, netmask: mask)) }
            } else if prefixes.contains(where: { name.hasPrefix($0) }),
                      subnets.contains(where: { addr & $0.1 == $0.0 }) {
                out.append(VMInterface(name: name, address: addr, netmask: mask))
            }
        }
        return out
    }
}

/// TCP server the guests' `notchcast` connect to. Several guests (VMs) may be
/// connected at once; the controller decides which one the strip serves. A
/// new connection from a connected guest's address replaces the old one (a
/// restarted notchcast or rebooted VM). On 127.0.0.1 all of OmacVM.app's VMs
/// share one address, so there each connection is a guest of its own, once it
/// has proved it knows the Bridge's token (GuestAuth); until then it is kept
/// apart and takes no guest's slot. One that says the name of a connected
/// guest replaces that one. The app's fast network (192.168.77.1 on a
/// bridgeN) is handled the same way, and a VM the app moves from one to the
/// other replaces itself by its name.
///
/// It listens only on the Mac's side of VM shared networks (never on Wi-Fi,
/// Ethernet, Internet Sharing or Thunderbolt bridges) and accepts a connection
/// only from an address inside that network. The interfaces come and go with
/// the VM apps, so they are re-scanned every few seconds.
final class GuestLink {
    /// Messages from guest `id`.
    var onMessages: ((Int, [GuestMessage]) -> Void)?
    /// Guest `id` connected (true; also when a new connection from its
    /// address took over: a new session) or went away (false).
    var onConnectionChange: ((Int, Bool) -> Void)?

    private final class Guest {
        let id: Int
        let peer: UInt32
        let iface: VMInterface
        var connection: NWConnection
        let stream = GuestStream()
        var isConnected = false
        /// Its "vmname" as sent (OmacVM.app's VMs only).
        var vmName: String?
        let since = Date()

        init(id: Int, peer: UInt32, iface: VMInterface, connection: NWConnection) {
            self.id = id
            self.peer = peer
            self.iface = iface
            self.connection = connection
        }
    }

    /// A connection on 127.0.0.1 (or the fast network) that has not proved the token yet.
    private final class Pending {
        let peer: UInt32
        let iface: VMInterface
        let connection: NWConnection
        var buffer = Data()
        /// The Mac address it came in on and the nonces, after "challenge".
        var addr = "", guestNonce = "", macNonce = ""

        init(peer: UInt32, iface: VMInterface, connection: NWConnection) {
            self.peer = peer
            self.iface = iface
            self.connection = connection
        }
    }

    static let maxGuests = 8
    static let maxPending = 16

    private let port: UInt16
    private let prefixes: [String]
    private let subnets: [(UInt32, UInt32)]
    private let onlyAddress: UInt32?
    private let listenNowhere: Bool
    /// Also serve OmacVM.app's VMs on 127.0.0.1 (defaults key omacvmApp).
    private let omacvmApp = UserDefaults.standard.object(forKey: "omacvmApp") as? Bool ?? true
    private let queue = DispatchQueue.main
    private var listeners: [VMInterface: NWListener] = [:]
    private var scanTimer: Timer?
    private var guests: [Int: Guest] = [:]
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var lastRefusal = ("", Date.distantPast)
    /// Guest ids grow with each new guest, so they give the connection order.
    private var nextID = 1

    /// `onlyAddress`: listen on this one address instead of scanning.
    init(port: UInt16, interfacePrefixes: [String], subnets: [String], onlyAddress: String?) {
        self.port = port
        self.prefixes = interfacePrefixes
        self.subnets = subnets.compactMap { VMInterface.parseSubnet($0.trimmingCharacters(in: .whitespaces)) }
        let raw = onlyAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.onlyAddress = raw.isEmpty ? nil : VMInterface.parse(raw)
        self.listenNowhere = !raw.isEmpty && self.onlyAddress == nil
        if listenNowhere { Log.info("listenHost '\(raw)' is not an IPv4 address: not listening") }
    }

    /// The connected guests, first connected first.
    var connectedIDs: [Int] { guests.values.filter(\.isConnected).map(\.id).sorted() }

    func isConnected(_ id: Int) -> Bool { guests[id]?.isConnected == true }

    /// Guest `id` runs in OmacVM.app (came in on 127.0.0.1 or on its fast network).
    func viaOmacVMApp(_ id: Int) -> Bool { guests[id]?.iface.isOmacVMApp == true }

    /// The bar image as last sent by guest `id`.
    func stream(for id: Int) -> GuestStream? { guests[id]?.stream }

    func start() {
        rescan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.rescan() }
        scanTimer?.tolerance = 1   // lets macOS batch it with other wake-ups
    }

    private func rescan() {
        var now = listenNowhere ? [] : Set(VMInterface.scan(prefixes: prefixes, subnets: subnets, onlyAddress: onlyAddress))
        if !listenNowhere && onlyAddress == nil && omacvmApp {
            now.insert(VMInterface.omacvmApp)
            // OmacVM.app's fast network, while one of its VMs is on it.
            now.formUnion(VMInterface.scan(prefixes: prefixes, subnets: [], onlyAddress: VMInterface.omacvmFastAddress)
                .filter { $0.name.hasPrefix("bridge") })
        }
        for (iface, l) in listeners where !now.contains(iface) {
            Log.info("VM network gone: \(iface.name) \(iface.addressString)")
            l.cancel()
            listeners[iface] = nil
        }
        // A guest whose network is gone (VM app quit) is gone too, even if
        // its connection never closed.
        for g in guests.values where !now.contains(g.iface) {
            Log.info("dropping guest \(g.id) on \(g.iface.name): network gone")
            let c = g.connection
            c.cancel()
            drop(g, c)
        }
        for iface in now where listeners[iface] == nil {
            startListener(on: iface)
        }
    }

    private func startListener(on iface: VMInterface) {
        // Keepalive finds a guest that vanished without closing (a VM that was
        // suspended or force-stopped) within about ten seconds.
        let tcp = NWProtocolTCP.Options()
        // The strip's "cursor 0/1" lines must not wait for the guest's ACK of
        // the line before (Nagle): they hand the pointer over at the edge.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(iface.addressString),
                                                 port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: params) else {
            Log.info("listener: cannot create on \(iface.addressString):\(port)")
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c, via: iface) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready:
                Log.info("listening on \(iface.name) \(iface.addressString):\(self?.port ?? 0)")
            case .failed(let err):
                Log.info("listener on \(iface.addressString) failed: \(err)")
                l?.cancel()
                // Dropped from the table: the next scan starts it again.
                if let self, self.listeners[iface] === l { self.listeners[iface] = nil }
            default:
                break
            }
        }
        listeners[iface] = l
        l.start(queue: queue)
    }

    private func accept(_ c: NWConnection, via iface: VMInterface) {
        guard case let .hostPort(remoteHost, _) = c.endpoint,
              let ip = VMInterface.parse("\(remoteHost)".components(separatedBy: "%")[0]), iface.contains(ip)
        else {
            Log.info("rejecting connection from \(c.endpoint) on \(iface.name)")
            c.cancel()
            return
        }
        // 127.0.0.1: any VM of OmacVM.app, or any Mac program. It proves the
        // token first and replaces no one by its address. The same on the
        // app's fast network (a VM there may come from the loopback a moment
        // ago, when the app switched its network).
        if iface.isOmacVMApp {
            startPending(c, peer: ip, iface: iface)
            return
        }
        // The same address again takes over at once (a restarted notchcast or
        // rebooted VM). TCP keepalive and the network check in rescan() notice
        // a guest that vanished without closing.
        if let g = guests.values.first(where: { $0.peer == ip && $0.iface == iface }) {
            let old = g.connection
            let takeover = g.isConnected
            g.connection = c
            g.stream.reset()
            old.cancel()
            run(c, for: g, takeover: takeover)
            return
        }
        guard guests.count < Self.maxGuests else {
            Log.info("\(guests.count) guests connected already; turning away \(c.endpoint)")
            c.cancel()
            return
        }
        let g = Guest(id: nextID, peer: ip, iface: iface, connection: c)
        nextID += 1
        guests[g.id] = g
        run(c, for: g, takeover: false)
    }

    private func run(_ c: NWConnection, for g: Guest, takeover: Bool) {
        watch(c, for: g, takeover: takeover)
        c.start(queue: queue)
    }

    private func watch(_ c: NWConnection, for g: Guest, takeover: Bool) {
        c.stateUpdateHandler = { [weak self, weak c, weak g] state in
            guard let self, let c, let g, c === g.connection, self.guests[g.id] === g else { return }
            switch state {
            case .ready:
                Log.info("guest \(g.id) connected: \(c.endpoint)")
                // Taking over from an old connection is a new session too.
                if takeover && g.isConnected { self.onConnectionChange?(g.id, true) } else { self.setConnected(g, true) }
                self.receive(on: c, for: g)
            case .failed, .cancelled:
                self.drop(g, c)
            default:
                break
            }
        }
    }

    // MARK: 127.0.0.1: the token first

    /// Kept apart from the guests until it proves the token: it takes no
    /// guest's slot and replaces no one; at most `maxPending` at once.
    private func startPending(_ c: NWConnection, peer: UInt32, iface: VMInterface) {
        guard pending.count < Self.maxPending else {
            Log.info("\(pending.count) connections of OmacVM.app have not proved the token yet; turning away \(c.endpoint)")
            c.cancel()
            return
        }
        let p = Pending(peer: peer, iface: iface, connection: c)
        let key = ObjectIdentifier(c)
        pending[key] = p
        c.stateUpdateHandler = { [weak self, weak p] state in
            guard let self, let p, self.pending[key] === p else { return }
            switch state {
            case .ready: self.receivePending(p)
            case .failed, .cancelled: self.pending[key] = nil
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak p] in
            guard let self, let p, self.pending[key] === p else { return }
            self.refuse(p, "proved no token in time")
        }
    }

    private func receivePending(_ p: Pending) {
        let c = p.connection, key = ObjectIdentifier(c)
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak p] data, _, isComplete, error in
            guard let self, let p, self.pending[key] === p else { return }
            if let data { p.buffer.append(data) }
            // Short text messages only ("NTXT", u32 length, text).
            while p.buffer.count >= 8 {
                guard p.buffer.readUInt32(at: 0) == GuestStream.textMagic else { return self.refuse(p, "no challenge") }
                let len = Int(p.buffer.readUInt32(at: 4))
                guard len <= 200 else { return self.refuse(p, "no challenge") }
                guard p.buffer.count >= 8 + len else { break }
                let start = p.buffer.startIndex
                let text = String(decoding: p.buffer[start + 8 ..< start + 8 + len], as: UTF8.self)
                p.buffer.removeFirst(8 + len)
                switch self.handshake(p, text) {
                case .more: continue
                case .proved: return self.promote(p)
                case .refused(let why): return self.refuse(p, why)
                }
            }
            if isComplete || error != nil { return self.refuse(p, nil) }
            self.receivePending(p)
        }
    }

    private enum Step { case more, proved, refused(String) }

    /// One message of the handshake (GuestAuth).
    private func handshake(_ p: Pending, _ text: String) -> Step {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .refused("not the handshake") }
        if p.macNonce.isEmpty, parts[0] == "auth" {
            // notchcast from before the proof says the token itself.
            guard GuestAuth.legacyTokenMatches(String(parts[1])) else { return .refused("wrong token") }
            Log.info("a VM of OmacVM.app sent the token itself: run guest/install.sh in it again for the proof")
            return .proved
        }
        guard let token = GuestAuth.token() else { return .refused("no Bridge token on this Mac") }
        if p.macNonce.isEmpty {
            guard parts[0] == "challenge", GuestAuth.isHex(parts[1], count: 32) else { return .refused("no challenge") }
            guard let addr = localAddress(p.connection) else { return .refused("own address unknown") }
            p.addr = addr
            p.guestNonce = String(parts[1])
            p.macNonce = GuestAuth.nonce()
            let mine = GuestAuth.proof(token: token, who: "mac", addr: addr, guestNonce: p.guestNonce, macNonce: p.macNonce)
            p.connection.send(content: Data("proof \(p.macNonce) \(mine)\n".utf8), completion: .contentProcessed { _ in })
            return .more
        }
        guard parts[0] == "proof" else { return .refused("no proof") }
        let want = GuestAuth.proof(token: token, who: "vm", addr: p.addr, guestNonce: p.guestNonce, macNonce: p.macNonce)
        return GuestAuth.same(Array(want.utf8), Array(parts[1].utf8)) ? .proved : .refused("wrong proof")
    }

    /// The Mac address a connection came in on (its getsockname).
    private func localAddress(_ c: NWConnection) -> String? {
        guard case let .hostPort(host, _)? = c.currentPath?.localEndpoint else { return nil }
        let s = "\(host)".components(separatedBy: "%")[0]
        return VMInterface.parse(s) != nil ? s : nil
    }

    /// A refused VM retries every few seconds: the same reason is logged once a minute.
    private func refuse(_ p: Pending, _ why: String?) {
        if let why, why != lastRefusal.0 || Date().timeIntervalSince(lastRefusal.1) >= 60 {
            Log.info("refused a connection on \(p.iface.addressString): \(why)")
            lastRefusal = (why, Date())
        }
        pending[ObjectIdentifier(p.connection)] = nil
        p.connection.cancel()
    }

    /// Proved: a guest of its own, with what came after the proof.
    private func promote(_ p: Pending) {
        let c = p.connection
        pending[ObjectIdentifier(c)] = nil
        guard guests.count < Self.maxGuests else {
            Log.info("\(guests.count) guests connected already; turning away \(c.endpoint)")
            c.cancel()
            return
        }
        let g = Guest(id: nextID, peer: p.peer, iface: p.iface, connection: c)
        nextID += 1
        guests[g.id] = g
        watch(c, for: g, takeover: false)   // ready already: only its end counts
        Log.info("guest \(g.id) connected: \(c.endpoint)"
                 + (p.iface == VMInterface.omacvmApp ? "" : " on OmacVM.app's fast network"))
        setConnected(g, true)
        if !p.buffer.isEmpty, !deliver(p.buffer, on: c, for: g) { return }
        receive(on: c, for: g)
    }

    // MARK: guests

    /// Feeds a guest's bytes on; false when that dropped it.
    private func deliver(_ data: Data, on c: NWConnection, for g: Guest) -> Bool {
        do {
            let messages = try g.stream.feed(data)
            if g.iface.isOmacVMApp { replaceSameName(g, messages) }
            if !messages.isEmpty { onMessages?(g.id, messages) }
            return true
        } catch {
            Log.info("\(error); dropping guest \(g.id)")
            c.cancel()
            return false
        }
    }

    private func receive(on c: NWConnection, for g: Guest) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak g] data, _, isComplete, error in
            guard let self, let g, c === g.connection, self.guests[g.id] === g else { return }
            if let data, !data.isEmpty, !self.deliver(data, on: c, for: g) { return }
            if isComplete || error != nil {
                c.cancel()
                return
            }
            self.receive(on: c, for: g)
        }
    }

    /// An OmacVM.app guest that says the name of another one is that VM again
    /// (a rebooted VM whose old connection never closed, or the same VM after
    /// the app moved it between 127.0.0.1 and the fast network): the old one
    /// goes. Not when the old one connected in the last 10 s: a reboot takes
    /// longer, so that is a second VM with the same name (a copied disk), and
    /// the two would keep replacing each other.
    private func replaceSameName(_ g: Guest, _ messages: [GuestMessage]) {
        for case let .text(t) in messages where t.hasPrefix("vmname ") {
            let name = String(t.dropFirst("vmname ".count))
            g.vmName = name
            for o in guests.values where o !== g && o.iface.isOmacVMApp && o.vmName == name
                && Date().timeIntervalSince(o.since) > 10 {
                Log.info("guest \(g.id) is VM \(o.id) again; dropping \(o.id)")
                let oc = o.connection
                oc.cancel()
                drop(o, oc)
            }
        }
    }

    private func drop(_ g: Guest, _ c: NWConnection) {
        guard c === g.connection, guests[g.id] === g else { return }
        guests[g.id] = nil
        Log.info("guest \(g.id) disconnected")
        setConnected(g, false)
    }

    private func setConnected(_ g: Guest, _ v: Bool) {
        guard v != g.isConnected else { return }
        g.isConnected = v
        onConnectionChange?(g.id, v)
    }

    /// Sends one command line to guest `id` (fire and forget).
    func send(_ line: String, to id: Int?) {
        guard let id, let g = guests[id], g.isConnected else { return }
        g.connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }
}
