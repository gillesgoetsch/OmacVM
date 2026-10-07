#!/bin/bash
# OmacVM.app while the VM sits idle, offline (no VM, no QEMU):
#  - the guest agent: one held connection serves every command, a late reply
#    is thrown away, a broken connection is replaced once;
#  - runAndWait for "Features…" (ControlCentreRoute): exit codes and what the
#    user is told, output capped, a late start reply, a reply too long (the
#    command is never sent twice);
#  - the Mac clipboard: polled fast only while the VM is the active app, at
#    once when it becomes active.
# The app's sources are compiled on their own with a small test main.
#   src/tests/app-idle.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/app/app/Sources/OmacVM
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
chmod 700 "$T"

cat > "$T/main.swift" <<'EOF'
import Darwin
import Foundation

// Model.swift has the app's HelperError; the test does not compile Model.swift.
enum HelperError: LocalizedError, Equatable {
    case io(String)
    var errorDescription: String? { if case .io(let d) = self { return d }; return nil }
}

var failed = false
func expect(_ what: String, _ ok: Bool) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failed = true }
}

/// A listening Unix socket in the test folder, served by `serve` on its own thread.
func listen(_ path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in path.utf8.enumerated() { buf[i] = b } }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    Darwin.listen(fd, 4)
    return fd
}

func readLine(_ fd: Int32) -> String? {
    var line = Data(), byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0A { return String(data: line, encoding: .utf8) }
        line.append(byte)
    }
    return nil
}

func reply(_ fd: Int32, _ s: String) { _ = (s + "\n").withCString { write(fd, $0, strlen($0)) } }

let dir = CommandLine.arguments[1]
signal(SIGPIPE, SIG_IGN)   // the fake agent writes to a client that hung up

// MARK: guest agent

do {
    let path = dir + "/qga"
    let server = listen(path)
    let lock = NSLock()
    var connections = 0
    var dropNext = false
    // Like qemu-ga behind QEMU's chardev: one client at a time, a reply per line;
    // "slow" answers after 3 s with a reply the client has stopped waiting for.
    Thread.detachNewThread {
        while true {
            let c = accept(server, nil, nil)
            if c < 0 { return }
            lock.lock(); connections += 1; lock.unlock()
            while let line = readLine(c) {
                lock.lock(); let drop = dropNext; dropNext = false; lock.unlock()
                if drop { break }
                if line.contains("slow") {
                    Thread.sleep(forTimeInterval: 3)
                    reply(c, "{\"return\":\"stale\"}")
                } else {
                    reply(c, "{\"return\":{}}")
                }
            }
            close(c)
        }
    }
    GuestAgent.hold(socketPath: path)
    expect("agent: setTime on the held connection", GuestAgent.setTime(socketPath: path))
    expect("agent: again", GuestAgent.setTime(socketPath: path))
    lock.lock(); expect("agent: one connection for both (got \(connections))", connections == 1); lock.unlock()

    let late = GuestAgent.execute(socketPath: path, "{\"execute\":\"slow\"}")
    expect("agent: no reply in 2 s gives an empty reply", late == "")
    Thread.sleep(forTimeInterval: 1.5)    // the late reply arrives meanwhile
    let fresh = GuestAgent.execute(socketPath: path, "{\"execute\":\"guest-set-time\"}")
    expect("agent: the late reply is thrown away (got \(fresh ?? "nil"))", fresh?.contains("{}") == true)

    lock.lock(); dropNext = true; lock.unlock()
    expect("agent: a dropped connection is replaced once", GuestAgent.setTime(socketPath: path))
    lock.lock(); expect("agent: two connections now (got \(connections))", connections == 2); lock.unlock()

    GuestAgent.release(socketPath: path)
    expect("agent: after release, a connection of its own", GuestAgent.setTime(socketPath: path))
    // The listening socket stays open: closed, its number goes to the next
    // section's socket and this thread, still in accept(), would take that
    // section's connections (macOS does not wake accept() on close).
}

// MARK: runAndWait (Features…)

do {
    let path = dir + "/qga-exec"
    let server = listen(path)
    final class Seen: @unchecked Sendable {   // under `lock`
        var silent = false
        var log: [String] = []     // what the agent got: "ping", "exec CASE", "status CASE"
        var cases: [Int: String] = [:]
    }
    let lock = NSLock()
    let seen = Seen()
    // A fake qemu-ga for guest-ping, guest-exec and guest-exec-status. The case
    // is the shell command in the request: "case-NAME".
    Thread.detachNewThread {
        while true {
            let c = accept(server, nil, nil)
            if c < 0 { return }
            while let line = readLine(c) {
                lock.lock(); let quiet = seen.silent; lock.unlock()
                if quiet { continue }
                let name = line.range(of: "case-[a-z0-9]+", options: .regularExpression).map { String(line[$0]) } ?? ""
                if line.contains("guest-ping") {
                    lock.lock(); seen.log.append("ping"); lock.unlock()
                    reply(c, "{\"return\":{}}")
                } else if line.contains("guest-exec-status") {
                    let pid = Int(line.range(of: "[0-9]+", options: .regularExpression).map { String(line[$0]) } ?? "") ?? 0
                    lock.lock(); let cs = seen.cases[pid] ?? ""; seen.log.append("status \(cs)"); lock.unlock()
                    if cs == "case-bigstatus" {
                        reply(c, "{\"return\":{\"exited\":true,\"exitcode\":0,\"out-data\":\"" + String(repeating: "A", count: 70_000) + "\"}}")
                        continue
                    }
                    let code = Int(cs.dropFirst(9)) ?? 0     // case-exit3 -> 3
                    let out = cs == "case-bigout" ? String(repeating: "a", count: 10_000)
                                                  : "first line\nthe \u{1B}[31mreason\u{07}\n"
                    let b64 = Data(out.utf8).base64EncodedString()
                    reply(c, "{\"return\":{\"exited\":true,\"exitcode\":\(code),\"out-data\":\"\(b64)\"}}")
                } else if line.contains("guest-exec") {
                    lock.lock(); seen.log.append("exec \(name)"); let pid = 100 + seen.cases.count; seen.cases[pid] = name; lock.unlock()
                    if name == "case-bigreply" {
                        reply(c, "{\"return\":{\"pid\":\(pid),\"x\":\"" + String(repeating: "B", count: 70_000) + "\"}}")
                        continue
                    }
                    if name == "case-late" { Thread.sleep(forTimeInterval: 3) }   // qemu-ga busy
                    reply(c, "{\"return\":{\"pid\":\(pid)}}")
                } else {
                    reply(c, "{\"return\":{}}")
                }
            }
            close(c)
        }
    }
    GuestAgent.hold(socketPath: path)
    func run(_ name: String) -> GuestAgent.Outcome {
        GuestAgent.runAndWait(socketPath: path, "/bin/sh", ["-c", name], seconds: 12)
    }
    func took() -> [String] {
        lock.lock(); defer { seen.log = []; lock.unlock() }
        return seen.log
    }
    func problem(_ o: GuestAgent.Outcome) -> String {
        ControlCentreRoute.problem(o, vmName: "Test VM").map { $0.0 + " | " + $0.1 } ?? "nil"
    }

    var o = run("case-exit0")
    expect("exec: exit 0 (got \(o))", o == .exited(0, "first line\nthe \u{1B}[31mreason\u{07}\n"))
    expect("exec: exit 0 says nothing", ControlCentreRoute.problem(o, vmName: "Test VM") == nil)
    let first = took()
    expect("exec: a ping, one start, one status (got \(first))", first == ["ping", "exec case-exit0", "status case-exit0"])
    o = run("case-exit3")
    expect("exec: exit 3 asks to log in (got \(problem(o)))", problem(o).hasPrefix("Log in to the VM first"))
    o = run("case-exit5")
    expect("exec: exit 5 gives the enable command (got \(problem(o)))",
           problem(o).contains("omacvm enable control-centre --vm \"Test VM\""))
    o = run("case-exit64")
    expect("exec: exit 64 is an older OmacVM (got \(problem(o)))", problem(o).hasPrefix("This VM has an older OmacVM"))
    o = run("case-exit1")
    expect("exec: exit 1 gives the VM's last line, cleaned (got \(problem(o)))",
           problem(o).contains("The VM says: the [31mreason."))
    expect("line: one line, printable, 200 at most",
           ControlCentreRoute.line("a\n" + String(repeating: "x\u{0}", count: 300)) == String(repeating: "x", count: 200))
    _ = took()

    o = run("case-bigout")
    if case .exited(0, let out) = o { expect("exec: output capped at 4 KB (got \(out.utf8.count))", out.utf8.count == 4096) }
    else { expect("exec: big output still exits 0 (got \(o))", false) }
    _ = took()

    o = run("case-late")
    expect("exec: a start reply after 3 s still counts (got \(o))", o == .exited(0, "first line\nthe \u{1B}[31mreason\u{07}\n"))
    let late = took()
    expect("exec: the late start was sent once (got \(late))", late == ["ping", "exec case-late", "status case-late"])

    o = run("case-bigreply")
    expect("exec: a start reply too long is a bad reply (got \(o))", o == .badReply)
    expect("exec: bad reply tells the user (got \(problem(o)))", problem(o).contains("could not be read"))
    lock.lock(); let bigExecs = seen.cases.values.filter { $0 == "case-bigreply" }.count; lock.unlock()
    expect("exec: and the start was not sent again (got \(bigExecs))", bigExecs == 1)
    expect("exec: the agent works after it", GuestAgent.setTime(socketPath: path))
    _ = took()

    o = run("case-bigstatus")
    let asked = took()
    expect("exec: a status reply too long ends the wait at once (got \(o))", o == .badReply)
    expect("exec: one start, one status (got \(asked))", asked == ["ping", "exec case-bigstatus", "status case-bigstatus"])
    expect("exec: the agent works after it", GuestAgent.setTime(socketPath: path))

    lock.lock(); seen.silent = true; lock.unlock()
    let t0 = Date()
    o = run("case-exit0")
    expect("exec: no answer to the ping is no agent (got \(o))", o == .noAgent)
    expect("exec: within the ping's 2 s (took \(Date().timeIntervalSince(t0)))", Date().timeIntervalSince(t0) < 3)
    let unanswered = took()
    expect("exec: nothing was started (got \(unanswered))", unanswered.isEmpty)
    expect("exec: no agent says so (got \(problem(o)))", problem(o).hasPrefix("The VM does not answer yet"))
    lock.lock(); seen.silent = false; lock.unlock()
    GuestAgent.release(socketPath: path)
    // The socket stays open, as above.
}

// MARK: clipboard poll

final class CountingPasteboard: HostPasteboardProviding {
    private let lock = NSLock()
    private var n = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return n }
    var changeCount: Int { lock.lock(); n += 1; lock.unlock(); return 1 }
    func read() -> ClipboardMessage? { nil }
    func write(_ message: ClipboardMessage) {}
}

do {
    let path = dir + "/clip"
    let server = listen(path)
    Thread.detachNewThread { _ = accept(server, nil, nil) }   // the guest side, silent
    let pb = CountingPasteboard()
    let bridge = try! NativeClipboardBridge(socketPath: path, pasteboard: pb)
    Thread.detachNewThread { try? bridge.run() }
    Thread.sleep(forTimeInterval: 0.2)
    var start = pb.reads
    Thread.sleep(forTimeInterval: 1.1)
    expect("clipboard: active VM, 4 polls a second (got \(pb.reads - start) in 1.1 s)", pb.reads - start >= 3)
    bridge.setVMActive(false)
    Thread.sleep(forTimeInterval: 0.3)
    start = pb.reads
    Thread.sleep(forTimeInterval: 2.0)
    expect("clipboard: VM in the background, no poll in 2 s (got \(pb.reads - start))", pb.reads - start == 0)
    start = pb.reads
    bridge.setVMActive(true)
    Thread.sleep(forTimeInterval: 0.1)
    expect("clipboard: one poll right when the VM becomes active (got \(pb.reads - start))", pb.reads - start >= 1)
    bridge.stop()
    close(server)
}

exit(failed ? 1 : 0)
EOF

swiftc -module-cache-path "$T/mc" -o "$T/idle" "$S/GuestAgent.swift" "$S/ControlCentreRoute.swift" "$S/NativeClipboardBridge.swift" \
  "$S/NativeBridgeSocket.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL the agent and clipboard sources do not compile on their own"; exit 1; }
"$T/idle" "$T"
