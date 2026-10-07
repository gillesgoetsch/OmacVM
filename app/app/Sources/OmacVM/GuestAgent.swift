import Darwin
import Foundation

/// The QEMU guest agent in the VM (virtio-serial). Only what the launcher needs.
///
/// The launcher stays connected to the agent's port while the VM runs: with
/// nobody on the Mac side of a virtio-serial port, qemu-ga in the VM finds it
/// closed and looks again ten times a second (an idle VM's CPUs woke for it).
/// One connection, one command at a time (`lock`).
enum GuestAgent {
    private static let lock = NSLock()
    /// The longest reply read (guest-exec-status with 4 KB of output is far shorter).
    private static let maxReply = 64 * 1024
    private static var held: (path: String, fd: Int32)?

    /// Connects to the agent's socket and keeps the connection (QEMU accepts
    /// one client). Tries for a while: the socket appears a moment after QEMU
    /// starts. Off the main thread.
    static func hold(socketPath: String) {
        for _ in 0..<50 {
            lock.lock()
            if held?.path == socketPath {
                lock.unlock()
                return
            }
            if let fd = connect(socketPath) {
                held = (socketPath, fd)
                lock.unlock()
                return
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Lets go of the connection (QEMU ended).
    static func release(socketPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if let h = held, h.path == socketPath {
            close(h.fd)
            held = nil
        }
    }

    /// Asks the guest to power off. Does nothing if no agent answers.
    static func shutdown(socketPath: String) {
        _ = execute(socketPath: socketPath, "{\"execute\":\"guest-shutdown\",\"arguments\":{\"mode\":\"powerdown\"}}")
    }

    /// Sets the guest clock to the Mac's. The VM's clock stands still while
    /// the Mac sleeps; Linux would only catch up at its next time sync.
    @discardableResult
    static func setTime(socketPath: String) -> Bool {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let ns = Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
        let reply = execute(socketPath: socketPath, "{\"execute\":\"guest-set-time\",\"arguments\":{\"time\":\(ns)}}")
        return reply?.contains("\"return\"") == true
    }

    /// Starts a program in the VM as root (guest-exec) without waiting for it.
    /// Arguments are passed as they are, no shell in between.
    @discardableResult
    static func run(socketPath: String, _ path: String, _ args: [String]) -> Bool {
        start(socketPath: socketPath, path, args) == .started
    }

    enum Start { case started, refused, noAnswer }

    /// As `run`, and tells a refusal (the agent answered with an error, such
    /// as no such program in the VM) from no answer (the program may still
    /// have started). A reply that comes too late for the 2 s wait, or only
    /// in part, counts as no answer, not as a refusal.
    static func start(socketPath: String, _ path: String, _ args: [String]) -> Start {
        let body: [String: Any] = ["execute": "guest-exec", "arguments": ["path": path, "arg": args]]
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let command = String(data: json, encoding: .utf8) else { return .refused }
        guard let reply = execute(socketPath: socketPath, command) else { return .noAnswer }
        if reply.contains("\"return\"") { return .started }
        if reply.contains("\"error\"") { return .refused }
        return .noAnswer
    }

    /// What `runAndWait` saw.
    enum Outcome: Equatable {
        case noAgent                 // no agent answered (the VM is starting, or has none)
        case refused(String)         // the agent did not start it: its error, shortened
        case running                 // started (or sent), no result when the wait ended
        case exited(Int32, String)   // its exit code and the start of its output
        case badReply                // a reply that cannot be read (too long, not JSON); never sent again
    }

    /// Runs a program in the VM as root (guest-exec, its output captured) and
    /// waits up to `seconds` for it to end. The guest is untrusted: only the
    /// fields named here are read, numbers within range, at most 4 KB of output.
    /// A ping first: no answer to it means no agent, and nothing was started.
    /// The start itself is never sent twice.
    static func runAndWait(socketPath: String, _ path: String, _ args: [String], seconds: Double) -> Outcome {
        let body: [String: Any] = ["execute": "guest-exec",
                                   "arguments": ["path": path, "arg": args, "capture-output": true]]
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let command = String(data: json, encoding: .utf8) else { return .noAgent }
        guard case .line(let pong) = send(socketPath, "{\"execute\":\"guest-ping\"}"),
              object(pong)?["return"] != nil else { return .noAgent }
        let deadline = Date().addingTimeInterval(seconds)
        let started: [String: Any]
        switch send(socketPath, command, wait: seconds, resend: false) {
        case .line(let reply):
            guard let o = object(reply) else { return .badReply }
            started = o
        case .noReply: return .running      // sent: it may run, the agent is slow
        case .tooLong: return .badReply
        case .broken: return .noAgent
        }
        if let error = started["error"] as? [String: Any] {
            return .refused(String(String(describing: error["desc"] ?? "error").prefix(200)))
        }
        guard let ret = started["return"] as? [String: Any], let pid = ret["pid"] as? Int,
              pid > 0, pid <= Int(Int32.max) else { return .badReply }
        let status = "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":\(pid)}}"
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            let reply = send(socketPath, status)
            if case .tooLong = reply { return .badReply }
            guard case .line(let line) = reply,
                  let st = object(line)?["return"] as? [String: Any],
                  st["exited"] as? Bool == true else { continue }
            let code = (st["exitcode"] as? Int).map { Int32(clamping: $0) } ?? -1   // none: ended by a signal
            var out = ""
            if let b64 = st["out-data"] as? String, let data = Data(base64Encoded: String(b64.prefix(8192))) {
                out = String(decoding: data.prefix(4096), as: UTF8.self)
            }
            return .exited(code, out)
        }
        return .running
    }

    private static func object(_ reply: String?) -> [String: Any]? {
        guard let reply, let data = reply.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Sends one command and waits up to two seconds for its one-line reply:
    /// "" when none came in time, nil when the connection broke or the reply
    /// was too long.
    static func execute(socketPath: String, _ command: String) -> String? {
        switch send(socketPath, command) {
        case .line(let reply): return reply
        case .noReply: return ""
        case .tooLong, .broken: return nil
        }
    }

    /// What one command got back.
    private enum Reply {
        case line(String)
        case noReply              // none within the wait; the connection stays
        case tooLong              // longer than `maxReply`: not sent again
        case broken(sent: Bool)   // the connection broke, before or after the command went out
    }

    /// Sends one command and waits up to `wait` seconds for its reply. On the
    /// held connection when there is one, else on a connection of its own.
    /// A broken held connection is replaced once and the command sent again,
    /// unless it went out already and `resend` is false. After a reply too
    /// long the held connection is replaced too (the rest of that reply would
    /// come in on it), but the command is not sent again.
    private static func send(_ socketPath: String, _ command: String,
                             wait: Double = 2, resend: Bool = true) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        if let h = held, h.path == socketPath {
            let reply = exchange(h.fd, command, wait: wait)
            switch reply {
            case .line, .noReply:
                return reply
            case .tooLong:
                close(h.fd)
                held = connect(socketPath).map { (path: socketPath, fd: $0) }
                return reply
            case .broken(let sent):
                close(h.fd)
                held = nil
                guard let fd = connect(socketPath) else { return reply }
                held = (socketPath, fd)
                return sent && !resend ? reply : exchange(fd, command, wait: wait)
            }
        }
        guard let fd = connect(socketPath) else { return .broken(sent: false) }
        defer { close(fd) }
        return exchange(fd, command, wait: wait)
    }

    private static func connect(_ socketPath: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// One command, one reply line, within `wait` seconds. A late reply to an
    /// earlier command (it timed out) is thrown away first.
    private static func exchange(_ fd: Int32, _ command: String, wait: Double) -> Reply {
        var chunk = [UInt8](repeating: 0, count: 4096)
        var stale = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Darwin.poll(&stale, 1, 0) > 0, stale.revents & Int16(POLLIN) != 0 {
            if read(fd, &chunk, chunk.count) <= 0 { return .broken(sent: false) }
            stale.revents = 0
        }
        let line = command + "\n"
        guard line.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return .broken(sent: false) }
        let deadline = Date().addingTimeInterval(wait)
        var reply = Data()
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return .broken(sent: true) }
            if n < 0 {
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { return .broken(sent: true) }
                if Date() < deadline { continue }   // reads time out after 2 s (SO_RCVTIMEO)
                return .noReply
            }
            reply.append(contentsOf: chunk[0..<n])
            if reply.count > maxReply { return .tooLong }
        }
        return .line(String(data: reply, encoding: .utf8) ?? "")
    }
}
