import Darwin
import Foundation

/// This app's side of drag and drop while one VM runs (feature drag-drop on):
///
/// - listens on QEMU's drop socket (OMACVM_DROP_SOCKET, in the app's private
///   run folder); only the VM's own QEMU may connect (its pid, LOCAL_PEERPID);
///   tells it "ready" or "wait"; takes the frames of a drop with their
///   descriptors (DropWire.Frame);
/// - stages each drop on its own serial queue (DropStage: clone or copy, off
///   the main thread, stopped when the VM stops);
/// - talks to the VM's omacvm-drop on the port org.omacvm.drop: its hello
///   (every 15 s) makes QEMU take drops; a drop line goes out per drop; the
///   VM's answer is checked, logged (never names), and a drop that went into
///   Downloads or failed loses its staging at once.
///
/// Threads: one accepts QEMU and reads its frames, one keeps the VM's port
/// (reconnected while the VM runs), one checks the hello's lease every 5 s;
/// the state below is under `lock`. Nothing here runs on the main thread.
public final class DropServer: @unchecked Sendable {
    private let listenPath: String
    private let portPath: String
    private let stage: DropStage
    private let qemuPID: () -> pid_t?
    private let test: Bool
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "org.omacvm.drop.stage", qos: .utility)

    private let lock = NSLock()
    private var running = false
    private var listenFD: Int32 = -1
    private var qemuFD: Int32 = -1
    private var portFD: Int32 = -1
    private var lastHello: Date?
    private var toldQEMU: Bool?
    private var folderOK = false
    /// Drops sent to the VM and not answered yet: id -> when sent.
    private var waiting: [String: Date] = [:]
    private var refusedPeers = 0
    private var badLines = 0

    public init(listenPath: String, portPath: String, stage: DropStage, qemuPID: @escaping () -> pid_t?,
                test: Bool = false, log: @escaping (String) -> Void) {
        self.listenPath = listenPath
        self.portPath = portPath
        self.stage = stage
        self.qemuPID = qemuPID
        self.test = test
        self.log = log
    }

    // MARK: start, stop

    /// The listening socket and the staging folder, before QEMU starts (it
    /// connects at its start, and again every second until it can).
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        folderOK = stage.reset()
        listenFD = try Self.listen(listenPath)
        running = true
        let me = self
        Thread.detachNewThread { me.acceptLoop() }
        Thread.detachNewThread { me.portLoop() }
        Thread.detachNewThread { me.leaseLoop() }
    }

    /// The VM stopped: sockets closed, a copy that runs stopped, staging gone
    /// (on the staging queue, after the drop in hand; `wait`: return once it
    /// is gone, for a process that ends right after).
    public func stop(wait: Bool = false) {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        for fd in [listenFD, qemuFD, portFD] where fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        listenFD = -1; qemuFD = -1; portFD = -1
        lock.unlock()
        unlink(listenPath)
        stage.cancel()
        if wait { queue.sync { stage.remove() } } else { queue.async { [stage] in stage.remove() } }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Tests only (OMACVM_DROP_TEST=1 here and in QEMU): QEMU drops these
    /// paths through the code its window uses after the pasteboard.
    @discardableResult
    public func testDrop(paths: [String]) -> Bool {
        guard test, let line = DropWire.testDropLine(paths: paths) else { return false }
        lock.lock(); let fd = qemuFD; lock.unlock()
        return fd >= 0 && Self.writeAll(fd, line)
    }

    /// Tests only: hold each drop this long before the VM hears of it (a
    /// slow copy from another volume), so the VM's late-drop rule shows.
    public var testDelay: TimeInterval = 0

    /// For tests and omacvm check: whether QEMU was last told "ready".
    public var readyNow: Bool { lock.lock(); defer { lock.unlock() }; return toldQEMU == true }

    // MARK: QEMU

    private func acceptLoop() {
        while isRunning {
            lock.lock(); let l = listenFD; lock.unlock()
            guard l >= 0 else { return }
            // poll first: a close from stop() does not wake a blocked accept on macOS.
            var pfd = pollfd(fd: l, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 1000) > 0 else { continue }
            guard isRunning else { return }
            let fd = accept(l, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let peer = Self.peerPID(fd)
            // QEMU connects at its start, which can be before the app has its
            // pid (Process.run returns, then the pid is set): wait for it.
            let expected = expectedPID()
            guard Self.peerAllowed(peer: peer, expected: expected) else {
                close(fd)
                lock.lock(); refusedPeers += 1; let n = refusedPeers; lock.unlock()
                // Every refusal, but a process that keeps trying fills no log.
                if n <= 20 || n % 100 == 0 {
                    log("OmacVM: drag and drop: \(Self.refusal(peer: peer, expected: expected))\(n > 1 ? " (\(n) refused so far)" : "")")
                }
                continue
            }
            lock.lock()
            if qemuFD >= 0 { close(qemuFD) }
            qemuFD = fd
            toldQEMU = nil
            lock.unlock()
            updateReady()
            read(qemu: fd)
            lock.lock(); if qemuFD == fd { qemuFD = -1 }; lock.unlock()
            close(fd)
        }
    }

    /// LOCAL_PEERPID of a connected unix socket.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return nil }
        return pid
    }

    /// How long a connection waits for QEMU's pid to be known.
    static let pidWait: TimeInterval = 5

    /// QEMU's pid, waited for up to pidWait while the server runs; nil: not known.
    private func expectedPID() -> pid_t? {
        let until = Date().addingTimeInterval(Self.pidWait)
        while true {
            if let p = qemuPID() { return p }
            guard isRunning, Date() < until else { return nil }
            usleep(20_000)
        }
    }

    /// The qemu.log line for a refused connection: what was refused and why.
    public static func refusal(peer: pid_t?, expected: pid_t?) -> String {
        let who = peer.map { "pid \($0)" } ?? "a process whose pid could not be read"
        guard let e = expected else {
            return "refused a connection from \(who): this VM's QEMU pid was not known after \(Int(pidWait)) s"
        }
        return "refused a connection from \(who): not this VM's QEMU (pid \(e))"
    }

    /// Only the VM's own QEMU (its pid known, the same).
    public static func peerAllowed(peer: pid_t?, expected: pid_t?) -> Bool {
        guard let p = peer, let e = expected, p > 0 else { return false }
        return p == e
    }

    /// Frames until QEMU closes: a drop's frames are gathered, then staged.
    private func read(qemu fd: Int32) {
        var bytes = [UInt8]()
        var fds = [Int32]()
        var current: (drop: Int, at: Int64, files: [(name: String, fd: Int32)], skipped: Int)?
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 65536, alignment: 16)
        defer { buf.deallocate(); for f in fds { close(f) }; current?.files.forEach { close($0.fd) } }
        let cmsgSpace = Int(Self.cmsgSpace(MemoryLayout<Int32>.size * 64))
        let cbuf = UnsafeMutableRawPointer.allocate(byteCount: cmsgSpace, alignment: 16)
        defer { cbuf.deallocate() }
        while true {
            var iov = iovec(iov_base: buf, iov_len: 65536)
            var msg = msghdr()
            let n: Int = withUnsafeMutablePointer(to: &iov) { iovp in
                msg.msg_iov = iovp
                msg.msg_iovlen = 1
                msg.msg_control = cbuf
                msg.msg_controllen = socklen_t(cmsgSpace)
                return recvmsg(fd, &msg, 0)
            }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            fds += Self.descriptors(msg)
            bytes += UnsafeRawBufferPointer(start: buf, count: n)
            if (msg.msg_flags & MSG_CTRUNC) != 0 {
                log("OmacVM: drop: QEMU sent more descriptors than fit: this drop is dropped")
                return
            }
            while bytes.count >= 4 {
                let len = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
                guard len <= DropWire.maxFrame else { log("OmacVM: drop: a frame from QEMU is too long"); return }
                guard bytes.count >= 4 + len else { break }
                let json = Data(bytes[4..<(4 + len)])
                bytes.removeFirst(4 + len)
                // The frame's names tell how many descriptors are its own.
                let count = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["names"].flatMap { ($0 as? [Any])?.count } ?? -1
                guard count >= 0, count <= fds.count else { log("OmacVM: drop: a frame from QEMU without its files"); return }
                let mine = Array(fds.prefix(count))
                fds.removeFirst(count)
                switch DropWire.frame(json: json, fds: mine.count) {
                case .failure(let e):
                    mine.forEach { close($0) }
                    log("OmacVM: drop: a frame from QEMU refused (\(e))")
                    return
                case .success(let f):
                    if let c = current, c.drop != f.drop { c.files.forEach { close($0.fd) }; current = nil }
                    var c = current ?? (f.drop, f.at, [], 0)
                    for (name, d) in zip(f.names, mine) {
                        if c.files.count < DropWire.maxItems { c.files.append((name, d)) } else { close(d); c.skipped += 1 }
                    }
                    c.skipped += f.skipped
                    if f.last {
                        current = nil
                        let files = c.files, at = c.at, skipped = c.skipped
                        queue.async { [weak self] in self?.deliver(files: files, at: at, skippedAtQEMU: skipped) }
                    } else {
                        current = c
                    }
                }
            }
        }
    }

    private static func cmsgSpace(_ len: Int) -> Int {
        let a = MemoryLayout<UInt32>.size
        func align(_ n: Int) -> Int { (n + a - 1) & ~(a - 1) }
        return align(MemoryLayout<cmsghdr>.size) + align(len)
    }

    /// The SCM_RIGHTS descriptors of one recvmsg, in order.
    private static func descriptors(_ msg: msghdr) -> [Int32] {
        var out = [Int32]()
        guard let base = msg.msg_control, msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) else { return out }
        var off = 0
        let total = Int(msg.msg_controllen)
        let a = MemoryLayout<UInt32>.size
        while off + MemoryLayout<cmsghdr>.size <= total {
            let h = base.load(fromByteOffset: off, as: cmsghdr.self)
            let len = Int(h.cmsg_len)
            guard len >= MemoryLayout<cmsghdr>.size, off + len <= total else { break }
            if h.cmsg_level == SOL_SOCKET, h.cmsg_type == SCM_RIGHTS {
                let dataOff = off + ((MemoryLayout<cmsghdr>.size + a - 1) & ~(a - 1))
                let count = (off + len - dataOff) / MemoryLayout<Int32>.size
                for i in 0..<max(0, count) {
                    let d = base.load(fromByteOffset: dataOff + i * 4, as: Int32.self)
                    _ = fcntl(d, F_SETFD, FD_CLOEXEC)
                    out.append(d)
                }
            }
            off += (len + a - 1) & ~(a - 1)
        }
        return out
    }

    /// One drop: staged, then the VM is told (or, not ready now, dropped again).
    private func deliver(files: [(name: String, fd: Int32)], at: Int64, skippedAtQEMU: Int) {
        guard isRunning else { files.forEach { close($0.fd) }; return }
        let start = Date()
        let r = stage.stage(files)
        if test, testDelay > 0 { Thread.sleep(forTimeInterval: testDelay) }
        let bytes = r.items.reduce(Int64(0)) { $0 + $1.bytes }
        let mb = String(format: "%.1f", Double(bytes) / 1_048_576)
        let how = r.copied == 0 ? "cloned" : (r.cloned == 0 ? "copied" : "\(r.cloned) cloned, \(r.copied) copied")
        let skipped = r.skipped + skippedAtQEMU
        let took = String(format: "%.2f", Date().timeIntervalSince(start))
        guard !r.items.isEmpty else {
            log("OmacVM: drop: nothing to give the VM (\(skipped) skipped\(r.why.map { ": \($0)" } ?? ""))")
            return
        }
        let age = Int64(Date().timeIntervalSince1970 * 1000) - at
        let line = DropWire.dropLine(id: r.id, items: r.items, ageMS: age)
        lock.lock()
        let fd = portFD
        let ready = DropWire.ready(lastHello: lastHello, now: Date(), folderOK: folderOK)
        if fd >= 0, ready { waiting[r.id] = Date() }
        lock.unlock()
        guard fd >= 0, ready, Self.writeAll(fd, line) else {
            lock.lock(); waiting[r.id] = nil; lock.unlock()
            stage.removeDrop(r.id)
            log("OmacVM: drop: \(r.items.count) file\(r.items.count == 1 ? "" : "s") not given to the VM: its omacvm-drop does not answer")
            return
        }
        log("OmacVM: drop: \(r.items.count) file\(r.items.count == 1 ? "" : "s"), \(mb) MB, \(how) in \(took) s, \(age) ms after the drop\(skipped > 0 ? ", \(skipped) skipped" : "")\(r.why.map { " (\($0))" } ?? "")")
    }

    // MARK: the VM's port

    private func portLoop() {
        while isRunning {
            if let fd = Self.connect(portPath) {
                lock.lock()
                if !running { lock.unlock(); close(fd); return }
                portFD = fd
                lock.unlock()
                // A hello first: the VM's agent answers with its own, which makes QEMU ready.
                _ = Self.writeAll(fd, DropWire.hello)
                readLines(fd) { [weak self] in self?.received($0, fd: fd) }
                lock.lock()
                if portFD == fd { portFD = -1; close(fd) }
                lastHello = nil
                lock.unlock()
                updateReady()
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func received(_ line: String, fd: Int32) {
        switch DropWire.parseGuest(line) {
        case .hello?:
            lock.lock(); let first = lastHello == nil; lastHello = Date(); lock.unlock()
            if first { _ = Self.writeAll(fd, DropWire.hello) }
            updateReady()
        case .bye?:
            lock.lock(); lastHello = nil; lock.unlock()
            updateReady()
        case let .done(id, to, why)?:
            lock.lock(); let sent = waiting.removeValue(forKey: id); lock.unlock()
            guard let sent else { countBad(); return }
            let secs = String(format: "%.1f", Date().timeIntervalSince(sent))
            let place = to == "app" ? "the app under the pointer" : (to == "downloads" ? "Downloads" : "nowhere (failed)")
            log("OmacVM: drop: in the VM: \(place) after \(secs) s\(why.isEmpty ? "" : " (\(why))")")
            // Only an app may still read them (an upload, an editor): the rest goes now.
            if to != "app" { queue.async { [stage] in stage.removeDrop(id) } }
        case nil:
            countBad()
        }
    }

    private func countBad() {
        lock.lock(); badLines += 1; let n = badLines; lock.unlock()
        if n == 1 || n == 100 { log("OmacVM: drop: the VM sent a line that is not ours (ignored; \(n) so far)") }
    }

    /// Lines of at most DropWire.maxLine; a longer one is skipped to its end.
    private func readLines(_ fd: Int32, _ each: (String) -> Void) {
        var pending = [UInt8]()
        var skipping = false
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            for b in buf[0..<n] {
                if b == 10 {
                    if !skipping { each(String(decoding: pending, as: UTF8.self)) }
                    pending.removeAll(keepingCapacity: true)
                    skipping = false
                } else if !skipping {
                    pending.append(b)
                    if pending.count > 4096 { pending.removeAll(); skipping = true; countBad() }
                }
            }
        }
    }

    // MARK: ready

    private func leaseLoop() {
        while isRunning {
            Thread.sleep(forTimeInterval: 5)
            updateReady()
        }
    }

    /// Tells QEMU when the answer changes (and once after it connects).
    private func updateReady() {
        lock.lock()
        let ready = DropWire.ready(lastHello: lastHello, now: Date(), folderOK: folderOK)
        let fd = qemuFD
        let changed = toldQEMU != ready
        if fd >= 0, changed { toldQEMU = ready }
        lock.unlock()
        guard fd >= 0, changed else { return }
        _ = Self.writeAll(fd, DropWire.readyLine(ready))
        log("OmacVM: drag and drop: \(ready ? "ready (the VM's omacvm-drop answered)" : "waiting for the VM")")
    }

    // MARK: sockets

    static func writeAll(_ fd: Int32, _ s: String) -> Bool {
        var b = Array(s.utf8)
        var off = 0
        while off < b.count {
            let w = b.withUnsafeMutableBytes { Darwin.write(fd, $0.baseAddress! + off, $0.count - off) }
            if w < 0 { if errno == EINTR { continue }; return false }
            off += w
        }
        return true
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var a = sockaddr_un()
        let p = Array(path.utf8)
        guard p.count < MemoryLayout.size(ofValue: a.sun_path) else { return nil }
        a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { $0.initializeMemory(as: UInt8.self, repeating: 0); $0.copyBytes(from: p) }
        return a
    }

    /// QEMU's drop socket: ours, in a folder only we can enter, mode 0600.
    static func listen(_ path: String) throws -> Int32 {
        let parent = (path as NSString).deletingLastPathComponent
        var st = stat()
        guard lstat(parent, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: parent])
        }
        guard var a = address(path) else { throw CocoaError(.fileWriteInvalidFileName) }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 2) == 0 else { close(fd); throw POSIXError(.EIO) }
        return fd
    }

    /// The VM's port: QEMU's chardev socket, ours and private (as NativeBridgeSocket.connectSecure).
    static func connect(_ path: String) -> Int32? {
        var st = stat()
        let parent = (path as NSString).deletingLastPathComponent
        var pst = stat()
        guard lstat(parent, &pst) == 0, pst.st_uid == getuid(), (pst.st_mode & 0o077) == 0,
              lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid(),
              var a = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(fd); return nil }
        return fd
    }
}
