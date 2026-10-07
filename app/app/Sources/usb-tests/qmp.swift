import Darwin
import Foundation
import OmacVMUSB

// `usb-tests --qmp QEMU`: the QMP side against a real QEMU (OmacVM's
// runtime), with no VM disk (the CPUs never start: -S) and no device of this
// Mac (HVF, as the app: its runtime has no TCG). A device that does not exist must fail as "unplugged"; the add, the
// check with info usb and the removal run with QEMU's emulated tablet in
// place of usb-host (same id, same bus), so nothing of the Mac is opened.

/// A small blocking QMP client: one line a message.
final class TestQMP: USBQMPTransport {
    private let fd: Int32
    private var buffer = Data()
    /// device_add of usb-host becomes an emulated usb-tablet (same id and bus).
    var emulate = false

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in path.utf8CString.withUnsafeBytes { p.copyMemory(from: $0) } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, read() != nil, (try? execute("qmp_capabilities", nil)) != nil else {
            Darwin.close(fd)
            return nil
        }
    }

    deinit { Darwin.close(fd) }

    private func read() -> [String: Any]? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
        var args = arguments
        if emulate, command == "device_add", args?["driver"] as? String == "usb-host" {
            args = ["driver": "usb-tablet", "id": args?["id"] ?? "", "bus": args?["bus"] ?? ""]
        }
        var req: [String: Any] = ["execute": command]
        if let args { req["arguments"] = args }
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0a)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        while let r = read() {
            if r["event"] != nil { continue }
            if let e = r["error"] as? [String: Any] {
                throw NSError(domain: "qmp", code: 1, userInfo: [NSLocalizedDescriptionKey: "QMP command \(command) failed: \(e["desc"] as? String ?? "?")"])
            }
            if let t = r["return"] as? String { return ["text": t] }
            return r["return"] as? [String: Any] ?? [:]
        }
        throw NSError(domain: "qmp", code: 2, userInfo: [NSLocalizedDescriptionKey: "QEMU closed the socket"])
    }
}

/// USBMachine over a real QMP socket, synchronous (the app's runs on a queue).
final class TestQMPMachine: USBMachine {
    let qmp: TestQMP
    init(_ qmp: TestQMP) { self.qmp = qmp }
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) { done(USBQMP.attach(d, over: qmp)) }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) { done(USBQMP.detach(location: d.location, over: qmp)) }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) {
        done((try? USBQMP.attached(over: qmp))?.contains(USBQMP.qemuID(location: d.location)) ?? false)
    }
}

func qmpIntegration(qemu: String, expect: (Bool, String) -> Void) {
    // A socket path has at most 103 bytes: a long TMPDIR gives way to /tmp.
    var base = FileManager.default.temporaryDirectory
    if base.path.utf8.count > 60 { base = URL(fileURLWithPath: "/tmp") }
    let dir = base.appendingPathComponent("usb-qmp-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("qmp").path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: qemu)
    p.arguments = ["-machine", "virt", "-accel", "hvf", "-cpu", "host", "-m", "128", "-nodefaults", "-S",
                   "-display", "none", "-serial", "none", "-monitor", "none",
                   "-qmp", "unix:\(sock),server=on,wait=off"] + USBSwitch.arguments(on: true)
    let errPipe = Pipe()
    p.standardOutput = FileHandle.nullDevice
    p.standardError = errPipe
    do { try p.run() } catch {
        expect(false, "qmp: QEMU starts (\(error.localizedDescription))")
        return
    }
    defer { p.terminate(); p.waitUntilExit() }
    var client: TestQMP?
    for _ in 0..<50 where client == nil {
        Thread.sleep(forTimeInterval: 0.1)
        client = TestQMP(path: sock)
    }
    guard let q = client else {
        if !p.isRunning {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            print("QEMU: \(err.prefix(600))")
        }
        expect(false, "qmp: QEMU's control socket answers")
        return
    }
    expect(true, "qmp: QEMU runs with the switch's arguments (an empty xHCI controller) and answers")
    expect(((try? USBQMP.attached(over: q)) ?? ["?"]).isEmpty, "qmp: no device on the controller at the start")
    // A device that is not there (bus 255, address 127): nothing of this Mac is opened.
    let ghost = USBDevice(id: USBDeviceID(vendor: 0x0483, product: 0x3748), name: "ghost", deviceClass: 0, interfaces: [],
                          location: 0xff00_0000, address: 127)
    let r = USBQMP.attach(ghost, over: q)
    expect(r == .gone, "qmp: usb-host by bus and address for a device that is not there: refused at once (\(r))")
    q.emulate = true
    let d = USBDevice(id: USBDeviceID(vendor: 0x0627, product: 0x0001), name: "QEMU USB Tablet", deviceClass: 0,
                      interfaces: [.init(number: 0, interfaceClass: 3, users: [])], location: 0x0110_0000, address: 5)
    expect(USBQMP.attach(d, over: q) == .attached, "qmp: device_add, and info usb lists it by its id (usbh-01100000)")
    expect(USBQMP.detach(location: d.location, over: q), "qmp: device_del, and info usb no longer lists it")
    // The session end to end over QMP: ask, connect, unplug, grace, removed.
    final class Clock: USBClock {
        var timers: [() -> Void] = []
        func after(_ s: Double, _ run: @escaping () -> Void) { timers.append(run) }
    }
    final class Asker: USBAsker {
        var open: ((USBAnswer) -> Void)?
        func ask(_ q: USBQuestion, answer: @escaping (USBAnswer) -> Void) { open = answer }
        func cancel() { open = nil }
        func notice(title: String, text: String) {}
    }
    let clock = Clock(), asker = Asker()
    var free = d
    free.interfaces = [.init(number: 0, interfaceClass: 0xff, users: [])]
    let s = USBSession(vmName: "Omarchy", memory: USBMemory(), machine: TestQMPMachine(q), asker: asker, clock: clock,
                       save: { _ in }, log: { _ in })
    s.plugged(free)
    asker.open?(USBAnswer(connect: true, always: false))
    let ids = (try? USBQMP.attached(over: q)) ?? []
    expect(s.plugs[free.location]?.state == .connected && ids == ["usbh-01100000"], "qmp: session: Connect puts it on the VM's bus")
    s.unplugged(location: free.location)
    clock.timers.forEach { $0() }
    expect(((try? USBQMP.attached(over: q)) ?? ["?"]).isEmpty && s.plugs.isEmpty, "qmp: session: unplugged: removed from the VM")
}
