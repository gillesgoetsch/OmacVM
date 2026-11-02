// Drag and drop's Mac side (OmacVMDrop), without a VM or Xcode:
//   cd app/app && swift run drop-tests
// Names, frames from QEMU, the VM's lines, the hello's lease, staging (clone,
// copy, limits, cleanup), QEMU's arguments and their place, the peer check,
// and a whole drop through DropServer with a stand-in QEMU and VM.
// Exit 0 when all pass. CI runs it on every pull request.
import Darwin
import Foundation
import OmacVMDrop
import OmacVMFeatures

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}
typealias W = DropWire

// MARK: names
expect(W.nameOK("photo.jpg") && W.nameOK("a b #%.txt") && W.nameOK("Grüße.pdf"), "names: plain, spaces, # and %, UTF-8")
expect(!W.nameOK("") && !W.nameOK(".") && !W.nameOK(".."), "names: empty, . and .. refused")
expect(!W.nameOK("a/b") && !W.nameOK("a\nb") && !W.nameOK("a\u{0}b") && !W.nameOK("a\u{7F}"), "names: slash, newline, NUL, DEL refused")
expect(W.nameOK(String(repeating: "x", count: 255)) && !W.nameOK(String(repeating: "x", count: 256)), "names: 255 bytes ok, 256 refused")
expect(!W.nameOK(String(repeating: "é", count: 128)), "names: the limit is in bytes (128 x é = 256 bytes)")

// MARK: frames from QEMU
func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
let good: [String: Any] = ["v": 1, "drop": 3, "at": 1_700_000_000_000 as Int64, "last": true, "names": ["a.txt", "b.png"], "skipped": 1]
if case .success(let f) = W.frame(json: json(good), fds: 2) {
    expect(f == W.Frame(drop: 3, at: 1_700_000_000_000, last: true, names: ["a.txt", "b.png"], skipped: 1), "frame: read")
} else { expect(false, "frame: read") }
expect(W.frame(json: json(good), fds: 1) == .failure(.badField("names")), "frame: names and descriptors must match")
var bad = good; bad["v"] = 2
expect(W.frame(json: json(bad), fds: 2) == .failure(.badField("v")), "frame: unknown version refused")
bad = good; bad["names"] = ["ok", "../x"]
expect(W.frame(json: json(bad), fds: 2) == .failure(.badField("name")), "frame: a bad name refuses the frame")
bad = good; bad["names"] = Array(repeating: "n", count: 33)
expect(W.frame(json: json(bad), fds: 33) == .failure(.badField("names")), "frame: more than 32 descriptors per frame refused")
expect(W.frame(json: Data(repeating: 32, count: W.maxFrame + 1), fds: 0) == .failure(.tooLong), "frame: too long refused")
expect(W.frame(json: Data("[1]".utf8), fds: 0) == .failure(.notJSON), "frame: not an object refused")

// MARK: lines to QEMU
expect(W.readyLine(true) == "ready\n" && W.readyLine(false) == "wait\n", "QEMU: ready and wait lines")
expect(W.testDropLine(paths: ["/a b/c", "/d"]) == "test-drop\t/a b/c\t/d\n", "QEMU: test-drop line")
expect(W.testDropLine(paths: ["rel"]) == nil && W.testDropLine(paths: ["/a\tb"]) == nil && W.testDropLine(paths: []) == nil,
       "QEMU: test-drop refuses relative paths, tabs, nothing")

// MARK: the VM's port
let line = W.dropLine(id: "0123456789abcdef", items: [.init(name: "say \"hi\".txt", bytes: 5)], ageMS: 120)
let lo = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
expect(line.hasSuffix("\n") && !line.dropLast().contains("\n"), "VM: a drop is one line")
expect(lo["t"] as? String == "drop" && lo["id"] as? String == "0123456789abcdef" && lo["age"] as? Int == 120, "VM: drop line fields")
expect(((lo["items"] as? [[String: Any]])?.first?["name"] as? String) == "say \"hi\".txt", "VM: names escaped as JSON")
expect(W.dropLine(id: "0123456789abcdef", items: [], ageMS: -5).contains("\"age\":0"), "VM: age never negative")
expect(W.parseGuest("{\"t\":\"hello\",\"v\":1}") == .hello(version: 1), "VM: hello")
expect(W.parseGuest("{\"t\":\"bye\"}") == .bye, "VM: bye")
expect(W.parseGuest("{\"t\":\"done\",\"id\":\"0123456789abcdef\",\"to\":\"downloads\",\"why\":\"no app took it\"}")
       == .done(id: "0123456789abcdef", to: "downloads", why: "no app took it"), "VM: done")
expect(W.parseGuest("{\"t\":\"done\",\"id\":\"0123456789abcdef\",\"to\":\"/etc\"}") == nil, "VM: unknown place refused")
expect(W.parseGuest("{\"t\":\"done\",\"id\":\"../../x\",\"to\":\"app\"}") == nil, "VM: bad id refused")
expect(W.parseGuest("{\"t\":\"done\",\"id\":\"0123456789ABCDEF\",\"to\":\"app\"}") == nil, "VM: id in lower-case hex only")
if case .done(_, _, let why)? = W.parseGuest("{\"t\":\"done\",\"id\":\"0123456789abcdef\",\"to\":\"failed\",\"why\":\"\(String(repeating: "w", count: 500))\\n\\u001b[2J\"}") {
    expect(why.count == W.maxWhy && !why.contains("\n") && !why.contains("\u{1B}"), "VM: why cut short, no control characters")
} else { expect(false, "VM: long why still read") }
expect(W.parseGuest("not json") == nil && W.parseGuest("{\"t\":\"hello\"}") == nil && W.parseGuest("{\"t\":\"x\"}") == nil, "VM: garbage ignored")
expect(W.parseGuest("{\"t\":\"hello\",\"v\":1,\"x\":\"" + String(repeating: "a", count: 5000) + "\"}") == nil, "VM: over 4 KB ignored")
expect(W.idOK(W.newID()) && W.newID() != W.newID(), "ids: 16 hex digits, new each time")

// MARK: the hello's lease
let now = Date()
expect(!W.ready(lastHello: nil, now: now, folderOK: true), "ready: no hello yet: wait")
expect(W.ready(lastHello: now.addingTimeInterval(-10), now: now, folderOK: true), "ready: hello 10 s ago")
expect(!W.ready(lastHello: now.addingTimeInterval(-46), now: now, folderOK: true), "ready: hello 46 s ago: wait")
expect(!W.ready(lastHello: now, now: now, folderOK: false), "ready: no drop folder: wait")

// MARK: QEMU's arguments
let port = DropPlan.portArguments(socket: "/run/x.drop")
expect(port == ["-chardev", "socket,id=drop0,path=/run/x.drop,server=on,wait=off",
                "-device", "virtserialport,bus=vser0.0,nr=10,chardev=drop0,name=org.omacvm.drop"], "args: port nr 10 org.omacvm.drop")
let share = DropPlan.shareArguments(folder: "/Users/me/OmacVM/My,VM/drop")
expect(share[1] == "local,id=dropfs,path=/Users/me/OmacVM/My,,VM/drop,security_model=none,readonly=on,multidevs=remap,guest_owner_uid=1000,guest_owner_gid=1000",
       "args: read-only share, comma written twice")
expect(share[3] == "virtio-9p-pci,fsdev=dropfs,mount_tag=omacvm-drop", "args: tag omacvm-drop")
let base = ["-device", "virtio-net-pci,netdev=net0", "-device", "virtio-9p-pci,fsdev=macfs,mount_tag=omacvm-mac"]
let on = DropPlan.finish(arguments: base, on: true, folder: "/v/drop", portSocket: "/r/p")
let offArgs = DropPlan.finish(arguments: base, on: false, folder: "/v/drop", portSocket: "/r/p")
expect(offArgs == base, "args: off: nothing added")
expect(Array(on.prefix(base.count)) == base, "args: on: every other argument as before")
expect(on.suffix(2) == ["-device", "virtio-9p-pci,fsdev=dropfs,mount_tag=omacvm-drop"], "args: the drop share is the very last device (after the Mac folder)")
expect(on.filter { $0.hasPrefix("virtio-9p-pci") || $0.hasPrefix("virtio-net") || $0.hasPrefix("pcie") }.last == "virtio-9p-pci,fsdev=dropfs,mount_tag=omacvm-drop",
       "args: no PCI device after the drop share")

// MARK: the switch
expect(!DragDrop.isOn(features: nil) && !DragDrop.isOn(features: "bridge=on") && DragDrop.isOn(features: "drag-drop=on"), "switch: off unless the record says on")
expect(DragDrop.row(record: "drag-drop=on", pending: nil, running: false, busy: false, cli: true) == .init(on: true, enabled: true, note: nil), "switch: row stopped")
expect(DragDrop.row(record: "drag-drop=off", pending: "on\n", running: true, busy: false, cli: true).note == "Being set up in the VM for this start.", "switch: row pending")
expect(DragDrop.switchState.pendingFile == "drag-drop-pending", "switch: pending file")

// MARK: the peer check
expect(DropServer.peerAllowed(peer: 42, expected: 42), "peer: the VM's QEMU")
expect(!DropServer.peerAllowed(peer: 43, expected: 42) && !DropServer.peerAllowed(peer: 42, expected: nil) && !DropServer.peerAllowed(peer: nil, expected: 42),
       "peer: another process, or QEMU not started yet: refused")

// MARK: staging
func sh(_ s: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", s]
    let o = Pipe(); p.standardOutput = o; try! p.run(); p.waitUntilExit()
    return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
let tmp = sh("mktemp -d /tmp/drop-tests.XXXXXX")
defer { _ = sh("rm -rf '\(tmp)'") }
let src = tmp + "/src", root = tmp + "/vm/drop"
_ = sh("mkdir -p '\(src)/dir' '\(tmp)/vm' && head -c 300000 /dev/urandom > '\(src)/big.bin' && printf hello > '\(src)/a.txt' && chmod 600 '\(src)/a.txt' && printf '#!/bin/sh\\n' > '\(src)/run.sh' && chmod 700 '\(src)/run.sh'")
func fd(_ name: String) -> Int32 { open(src + "/" + name, O_RDONLY | O_NOFOLLOW) }
func sum(_ p: String) -> String { sh("shasum -a 256 '\(p)' | cut -c1-64") }
let stage = DropStage(root: root)
expect(stage.reset(), "stage: folder made")
var st = stat(); lstat(root, &st)
expect((st.st_mode & 0o777) == 0o700, "stage: folder only for this user")
var r = stage.stage([("big.bin", fd("big.bin")), ("a.txt", fd("a.txt")), ("run.sh", fd("run.sh"))], id: "00000000000000a1")
expect(r.items.map(\.name) == ["big.bin", "a.txt", "run.sh"] && r.skipped == 0, "stage: three files")
expect(r.cloned == 3 && r.copied == 0, "stage: cloned on the same volume (APFS)")
expect(sum(root + "/00000000000000a1/big.bin") == sum(src + "/big.bin"), "stage: content the same (sha256)")
expect(r.items.first?.bytes == 300000, "stage: sizes")
lstat(root + "/00000000000000a1/a.txt", &st)
expect((st.st_mode & 0o777) == 0o644, "stage: readable in the VM (0644), whatever the original's mode")
lstat(root + "/00000000000000a1/run.sh", &st)
expect((st.st_mode & 0o111) != 0, "stage: executable bits kept")
lstat(src + "/a.txt", &st)
expect((st.st_mode & 0o777) == 0o600, "stage: the original untouched")
stage.forceCopy = true
r = stage.stage([("big.bin", fd("big.bin"))], id: "00000000000000a2")
expect(r.copied == 1 && r.cloned == 0 && sum(root + "/00000000000000a2/big.bin") == sum(src + "/big.bin"), "stage: copy (another volume) the same")
stage.freeOverride = DropStage.keepFree + 100
r = stage.stage([("big.bin", fd("big.bin"))], id: "00000000000000a3")
expect(r.items.isEmpty && r.skipped == 1 && r.why?.contains("10 GB") == true, "stage: no copy that would leave less than 10 GB")
expect(access(root + "/00000000000000a3", F_OK) != 0, "stage: an empty drop leaves no folder")
stage.forceCopy = false; stage.freeOverride = nil
r = stage.stage([("dir", open(src + "/dir", O_RDONLY)), ("a.txt", fd("a.txt")), ("a.txt", fd("a.txt"))], id: "00000000000000a4")
expect(r.items.map(\.name) == ["a.txt", "a (2).txt"] && r.skipped == 1, "stage: a folder skipped, a second name numbered")
r = stage.stage([("x/y", fd("a.txt"))], id: "00000000000000a5")
expect(r.items.isEmpty && r.skipped == 1, "stage: a bad name skipped")
func openFDs() -> Int { (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
let fdsBefore = openFDs()
var many = [(name: String, fd: Int32)]()
for i in 0..<257 { many.append(("f\(i)", fd("a.txt"))) }
r = stage.stage(many, id: "00000000000000a6")
expect(r.items.count == 256 && r.skipped == 1, "stage: at most 256 per drop")
expect(openFDs() == fdsBefore, "stage: every descriptor closed")
r = stage.stage([("a.txt", fd("a.txt"))], id: "../../etc")
expect(r.items.isEmpty, "stage: a bad id stages nothing")
stage.removeDrop("00000000000000a1")
expect(access(root + "/00000000000000a1", F_OK) != 0 && access(root + "/00000000000000a2", F_OK) == 0, "stage: one drop removed, the others kept")
_ = sh("rm -rf '\(root)' && ln -s '\(src)' '\(root)'")
expect(stage.reset(), "stage: a link where the folder was is replaced")
expect(access(src + "/a.txt", F_OK) == 0, "stage: the link's target untouched")
stage.remove()
expect(access(root, F_OK) != 0, "stage: removed at VM stop")

// MARK: a whole drop through DropServer: a stand-in QEMU (this process) and VM
let run = tmp + "/run"
mkdir(run, 0o700)
let listen = run + "/t.drop", portPath = run + "/t.dropp"
func unixListen(_ p: String) -> Int32 {
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: Array(p.utf8)) }
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    Darwin.listen(s, 1); return s
}
func unixConnect(_ p: String) -> Int32 {
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: Array(p.utf8)) }
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    var one: Int32 = 1; setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    return ok == 0 ? s : -1
}
/// One line, or "" after `secs`.
func readLine(_ fd: Int32, _ secs: Int32 = 5) -> String {
    var out = [UInt8]()
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while poll(&p, 1, secs * 1000) > 0 {
        var b: UInt8 = 0
        guard read(fd, &b, 1) == 1 else { break }
        if b == 10 { return String(decoding: out, as: UTF8.self) }
        out.append(b)
    }
    return ""
}
func sendFrame(_ s: Int32, _ o: [String: Any], _ fds: [Int32]) -> Bool {
    let j = json(o)
    var bytes = [UInt8(j.count >> 24 & 255), UInt8(j.count >> 16 & 255), UInt8(j.count >> 8 & 255), UInt8(j.count & 255)] + [UInt8](j)
    let clen = MemoryLayout<cmsghdr>.size + 4 * fds.count
    let cbuf = UnsafeMutableRawPointer.allocate(byteCount: max(clen, 16) + 8, alignment: 8)
    defer { cbuf.deallocate() }
    var h = cmsghdr(cmsg_len: socklen_t(clen), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
    cbuf.storeBytes(of: h, as: cmsghdr.self)
    for (i, f) in fds.enumerated() { cbuf.storeBytes(of: f, toByteOffset: MemoryLayout<cmsghdr>.size + 4 * i, as: Int32.self) }
    _ = h
    return bytes.withUnsafeMutableBytes { bp -> Bool in
        var iov = iovec(iov_base: bp.baseAddress, iov_len: bp.count)
        var m = msghdr()
        return withUnsafeMutablePointer(to: &iov) { ip in
            m.msg_iov = ip; m.msg_iovlen = 1
            if !fds.isEmpty { m.msg_control = cbuf; m.msg_controllen = socklen_t(clen) }
            return sendmsg(s, &m, 0) == bp.count
        }
    }
}

let vmListen = unixListen(portPath)   // QEMU's chardev for the port, as the VM's side
var logs = [String]()
let logLock = NSLock()
var expected: pid_t? = getpid()
let server = DropServer(listenPath: listen, portPath: portPath, stage: DropStage(root: tmp + "/vm2-drop"),
                        qemuPID: { expected }, test: true) { l in logLock.lock(); logs.append(l); logLock.unlock() }
try! server.start()
let q = unixConnect(listen)
expect(q >= 0, "server: QEMU connects")
expect(readLine(q) == "wait", "server: wait until the VM's omacvm-drop says hello (hello gating)")
let vm = accept(vmListen, nil, nil)
expect(readLine(vm) == "{\"t\":\"hello\",\"v\":1}", "server: says hello to the VM")
expect(server.testDrop(paths: ["/x"]) , "server: test-drop goes to QEMU in test mode")
expect(readLine(q) == "test-drop\t/x", "server: QEMU got the test-drop line")
_ = write(vm, "{\"t\":\"hello\",\"v\":1}\n", 20)
expect(readLine(q) == "ready", "server: ready once the VM said hello")
// A drop: two files in two frames.
let at = Int64(Date().timeIntervalSince1970 * 1000)
expect(sendFrame(q, ["v": 1, "drop": 1, "at": at, "last": false, "names": ["big.bin"]], [fd("big.bin")]), "server: frame 1 sent")
expect(sendFrame(q, ["v": 1, "drop": 1, "at": at, "last": true, "names": ["a.txt"], "skipped": 1], [fd("a.txt")]), "server: frame 2 sent")
let dl = readLine(vm)
let d = (try? JSONSerialization.jsonObject(with: Data(dl.utf8))) as? [String: Any]
let id = d?["id"] as? String ?? ""
let names = (d?["items"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
expect(d?["t"] as? String == "drop" && names == ["big.bin", "a.txt"], "server: the VM got one drop line with both files")
expect(sum(tmp + "/vm2-drop/\(id)/big.bin") == sum(src + "/big.bin"), "server: staged content the same (sha256)")
_ = write(vm, "{\"t\":\"done\",\"id\":\"\(id)\",\"to\":\"downloads\"}\n", 64)
usleep(300_000)
expect(access(tmp + "/vm2-drop/\(id)", F_OK) != 0, "server: staging removed once the VM put the files in Downloads")
logLock.lock(); let joined = logs.joined(separator: "\n"); logLock.unlock()
expect(joined.contains("drop: 2 files") && joined.contains("1 skipped") && joined.contains("Downloads"), "server: qemu.log lines")
expect(!joined.contains("big.bin") && !joined.contains("a.txt"), "server: never a name in qemu.log")
_ = write(vm, "{\"t\":\"bye\"}\n", 12)
expect(readLine(q) == "wait", "server: wait again after the VM's bye")
// Another process (a stand-in pid): refused before anything is read.
expected = getpid() + 100000
close(q)
let q2 = unixConnect(listen)
expect(readLine(q2, 2) == "", "server: a connection from another pid gets nothing")
usleep(200_000)
logLock.lock(); let refused = logs.contains { $0.contains("refused a connection") }; logLock.unlock()
expect(refused, "server: refusal logged")
server.stop()
expect(access(tmp + "/vm2-drop", F_OK) != 0 || { usleep(300_000); return access(tmp + "/vm2-drop", F_OK) != 0 }(), "server: staging gone at stop")
close(q2); close(vm); close(vmListen)

print(failures == 0 ? "drop-tests: all passed" : "drop-tests: \(failures) failed")
exit(failures == 0 ? 0 : 1)
