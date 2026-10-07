// The VM's USB devices (OmacVMUSB), without a VM, a device or Xcode:
//   cd app/app && swift run usb-tests          the checks; exit 0 when all pass
//   cd app/app && swift run usb-tests --list   this Mac's devices and what a VM may have
//   cd app/app && swift run usb-tests --qmp QEMU   also against a real QEMU (no VM disk,
//                                              no device of this Mac: an emulated one)
// CI runs the checks on every pull request. --list only reads the IORegistry.
import Foundation
import OmacVMUSB

if CommandLine.arguments.contains("--list") {
    for d in USBScan.devices() {
        let a: String
        switch d.availability {
        case .free: a = "free: a VM can have it"
        case .usedByMac(let why): a = why
        case .notOffered(let why): a = "not offered: \(why)"
        }
        let ifs = d.interfaces.map { "\($0.number):\(String(format: "%02x", $0.interfaceClass))\($0.users.isEmpty ? "" : "[\($0.users.joined(separator: ","))]")" }
        print("\(d.id) \(d.name) (class \(String(format: "%02x", d.deviceClass))) -> \(a)")
        print("    interfaces \(ifs.joined(separator: " "))\(d.drivers.isEmpty ? "" : "; device drivers \(d.drivers.joined(separator: ","))")")
    }
    exit(0)
}

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias I = USBDevice.Interface
func dev(_ v: UInt16, _ p: UInt16, _ name: String, cls: Int = 0, drivers: [String] = [], _ ifs: [I]) -> USBDevice {
    USBDevice(id: USBDeviceID(vendor: v, product: p), name: name, deviceClass: cls, drivers: drivers, interfaces: ifs)
}

// Devices as the IORegistry showed them on the Mac mini (2026-10-06).
let scarlett = dev(0x1235, 0x8219, "Scarlett 2i2 4th Gen", cls: 0xef, [
    I(number: 0, interfaceClass: 1, users: ["AppleUSBAudioControlNub", "usbaudiod"]),
    I(number: 1, interfaceClass: 1, users: ["usbaudiod"]),
    I(number: 2, interfaceClass: 1, users: ["usbaudiod"]),
    I(number: 3, interfaceClass: 0xfe, users: []),
])
expect(scarlett.availability == .usedByMac("macOS uses it for sound"),
       "an audio interface stays with the Mac, also when one interface is free")
let iphone = dev(0x05ac, 0x12a8, "iPhone", drivers: ["AppleUSBHostiOSDevice"], [
    I(number: 0, interfaceClass: 6, users: ["ptpcamerad"]),
    I(number: 1, interfaceClass: 0xff, users: ["usbmuxd"]),
])
expect(iphone.availability == .usedByMac("macOS uses it (iPhone, iPad or photo import)"), "an iPhone stays with the Mac")
let cam = dev(0x03e7, 0xf63d, "Opal C1", cls: 0xef, [
    I(number: 0, interfaceClass: 0xff, users: []),
    I(number: 1, interfaceClass: 0x0e, users: ["UVCAssistant"]),
])
expect(cam.availability == .usedByMac("macOS uses it as a camera"), "a webcam stays with the Mac")
let hub = dev(0x05e3, 0x0610, "USB2.0 Hub", cls: 9, [I(number: 0, interfaceClass: 9, users: [])])
expect(hub.availability == .notOffered("a USB hub"), "a hub is never offered")
let billboard = dev(0x0b05, 0x1c55, "DMC Device", [
    I(number: 0, interfaceClass: 0x11, users: ["AppleUSBHostBillboardDevice"]),
    I(number: 1, interfaceClass: 0xff, users: []),
])
expect(billboard.availability == .notOffered("a USB-C adapter's info device"),
       "a USB-C billboard is never offered, also with a vendor interface next to it")
let billboardOnly = dev(0x0b05, 0x1c56, "Adapter", [I(number: 0, interfaceClass: 0x11, users: [])])
expect(billboardOnly.availability == .notOffered("a USB-C adapter's info device"), "a billboard-only device is never offered")

// What a VM can have: nothing on the Mac uses any interface.
let stlink = dev(0x0483, 0x3748, "STM32 STLink", [I(number: 0, interfaceClass: 0xff, users: [])])
expect(stlink.availability == .free, "a debug probe without a macOS driver is free")
let unconfigured = dev(0x0bda, 0x2838, "RTL2838UHIDIR", cls: 0, [])
expect(unconfigured.availability == .free, "a device macOS did not set up (no interfaces, no driver) is free")
let key = dev(0x1050, 0x0407, "YubiKey OTP+FIDO+CCID", [
    I(number: 0, interfaceClass: 3, users: ["AppleUserUSBHostHIDDevice"]),
    I(number: 1, interfaceClass: 3, users: ["AppleUserUSBHostHIDDevice"]),
    I(number: 2, interfaceClass: 0x0b, users: []),
])
expect(key.availability == .usedByMac("macOS uses it as a keyboard, mouse or security key"), "a security key stays with the Mac")
let stick = dev(0x0781, 0x5581, "Ultra", [I(number: 0, interfaceClass: 8, users: ["IOUSBMassStorageInterfaceNub"])])
expect(stick.availability == .usedByMac("macOS uses it as a disk"), "a USB stick stays with the Mac")
let ftdi = dev(0x0403, 0x6001, "FT232R USB UART", [I(number: 0, interfaceClass: 0xff, users: ["AppleUSBFTDI"])])
expect(ftdi.availability == .usedByMac("macOS uses it as a serial port"), "an FTDI serial adapter stays with the Mac")
let driverOnDevice = dev(0x1234, 0x5678, "Thing", drivers: ["SomeVendorDriver"], [I(number: 0, interfaceClass: 0xff, users: [])])
expect(driverOnDevice.availability == .usedByMac("in use on the Mac (SomeVendorDriver)"), "a driver on the device itself counts")
expect(USBDevice.ignoredDeviceChild(className: "AppleUSBHostCompositeDevice")
       && USBDevice.ignoredDeviceChild(className: "AppleUSBHostDeviceUserClient")
       && !USBDevice.ignoredDeviceChild(className: "AppleUSBHostiOSDevice"),
       "the composite driver and apps that only look (WebUSB) do not count; other device drivers do")

expect(USBDevice.reason("qemu-system-aarch64") == "a VM has it", "a device another VM's QEMU has: kept, 'a VM has it'")

// MARK: The switch and the start's arguments
expect(USBDeviceID(text: "0483:3748") == USBDeviceID(vendor: 0x0483, product: 0x3748), "an id from text")
expect(USBDeviceID(text: "483:3748") == nil && USBDeviceID(text: "zzzz:3748") == nil && USBDeviceID(text: "0483") == nil,
       "a wrong id is no id")
expect(!USBSwitch.isOn(fileText: nil, olderDevices: false), "no switch file: off")
expect(USBSwitch.isOn(fileText: nil, olderDevices: true), "no switch file, devices from 3.0.1-3.0.3: on")
expect(!USBSwitch.isOn(fileText: "off\n", olderDevices: true) && USBSwitch.isOn(fileText: "on\n", olderDevices: false),
       "the switch file decides")
expect(!USBSwitch.isOn(fileText: "yes", olderDevices: true), "anything but on: off")
expect(USBSwitch.arguments(on: false).isEmpty, "off: no USB controller, the VM is as before")
expect(USBSwitch.arguments(on: true) == ["-device", "qemu-xhci,id=usb0"],
       "on: an empty xHCI controller, no device on the command line (nothing connects by itself)")

// MARK: The 3.0.1-3.0.3 file (read for the move only)
let parsed = USBChoice.parse("# comment\n0483:3748 ST-Link V2\nnonsense\n0483:3748 again\n1d50:6089\n")
expect(parsed == [.init(id: USBDeviceID(vendor: 0x0483, product: 0x3748), name: "ST-Link V2"),
                  .init(id: USBDeviceID(vendor: 0x1d50, product: 0x6089), name: "")],
       "old file: comments and nonsense skipped, a device once")
expect(USBChoice.parse("0483:3748\tST-Link V2\n") == [.init(id: USBDeviceID(vendor: 0x0483, product: 0x3748), name: "ST-Link V2")],
       "old file: a tab parts the id from the name")
expect(USBChoice.clean("a\nb\u{7}c") == "abc" && USBChoice.clean(String(repeating: "x", count: 99)).count == 60,
       "a name is one printable line, at most 60 characters")

// MARK: Remembered devices (usb.json)
func board(_ serial: String, loc: UInt32, name: String = "STM32 STLink", maker: String = "STMicroelectronics") -> USBDevice {
    USBDevice(id: USBDeviceID(vendor: 0x0483, product: 0x3748), name: name, deviceClass: 0,
              interfaces: [I(number: 0, interfaceClass: 0xff, users: [])],
              serial: serial, maker: maker, location: loc, address: Int(loc & 0xff))
}
var mem = USBMemory()
let boardA = board("066DFF485157717867", loc: 0x0110_0000), boardB = board("0670FF4851", loc: 0x0120_0000)
mem.remember(boardA, .omarchy, today: "2026-10-07")
expect(mem.plan(for: boardA) == .omarchy && mem.plan(for: boardB) == .ask,
       "serial matching: an identical board with another serial is not the remembered one")
mem.remember(boardB, .mac, today: "2026-10-07")
expect(mem.plan(for: boardA) == .omarchy && mem.plan(for: boardB) == .mac && mem.devices.count == 2,
       "two identical boards, each its own choice")
var noSerial = USBMemory()
noSerial.remember(board("", loc: 1), .omarchy)
expect(noSerial.plan(for: board("", loc: 2)) == .omarchy && noSerial.plan(for: board("ABC", loc: 3)) == .omarchy,
       "an entry without a serial is for every device of that id")
mem.remember(boardA, .ask)
expect(mem.plan(for: boardA) == .ask && mem.devices.count == 2, "remembering again changes the entry, no second one")
var full = USBMemory()
for i in 0..<40 {
    full.remember(USBDevice(id: USBDeviceID(vendor: 0x1000, product: UInt16(i)), name: "d\(i)", deviceClass: 0, interfaces: []), .mac)
}
expect(full.devices.count == USBMemory.maxDevices && full.devices.first?.product == String(format: "%04x", 39),
       "at most \(USBMemory.maxDevices) remembered, the newest first")
expect(USBMemory.decode(mem.encode()) == mem, "usb.json: written and read back the same")
let odd = #"{"version":1,"future":true,"devices":[{"vendor":"0483","product":"3748","serial":"","name":"A\u0007B","maker":"","choice":"omarchy","since":"2026-10-07","extra":1},{"vendor":"zz","product":"1","serial":"","name":"x","maker":"","choice":"mac","since":""}]}"#
let decoded = USBMemory.decode(Data(odd.utf8))
expect(decoded?.devices.count == 1 && decoded?.devices.first?.name == "AB" && decoded?.devices.first?.choice == .omarchy,
       "usb.json: unknown keys ignored, a wrong id dropped, names cleaned")
expect(USBMemory.decode(Data("not json".utf8)) == nil && USBMemory.decode(Data(#"{"version":2,"devices":[]}"#.utf8)) == nil,
       "usb.json: not ours, or a newer version: not read")
mem.forget(key: boardB.serial.isEmpty ? "" : "0483:3748/\(boardB.serial)")
expect(mem.devices.count == 1 && mem.plan(for: boardB) == .ask, "forget: asked again next time")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("usb-tests-\(getpid())")
func freshFolder(_ name: String) -> URL {
    let f = tmp.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: f)
    try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
    return f
}
var f = freshFolder("plain")
expect(USBMemory.load(folder: f) == USBMemory() && !USBSwitch.isOn(folder: f), "no file at all: nothing remembered, switch off")
try? mem.save(folder: f)
expect(USBMemory.load(folder: f) == mem, "saved and loaded")
let perms = (try? FileManager.default.attributesOfItem(atPath: f.appendingPathComponent("usb.json").path)[.posixPermissions] as? Int) ?? 0
expect(perms == 0o600, "usb.json is the user's only (0600)")
try? Data("garbage".utf8).write(to: f.appendingPathComponent("usb.json"))
var logged: [String] = []
expect(USBMemory.load(folder: f, log: { logged.append($0) }) == USBMemory()
       && FileManager.default.fileExists(atPath: f.appendingPathComponent("usb.json.bad").path)
       && !FileManager.default.fileExists(atPath: f.appendingPathComponent("usb.json").path) && logged.count == 1,
       "a file that cannot be read: put aside as usb.json.bad, nothing remembered, logged")

// Moving 3.0.1-3.0.3's `usb` file in.
f = freshFolder("migrate")
try? Data("0483:3748 ST-Link V2\n1d50:6089 HackRF One\n".utf8).write(to: f.appendingPathComponent("usb"))
expect(USBSwitch.isOn(folder: f), "before the move: devices and no switch file count as on")
let moved = USBMemory.load(folder: f)
expect(moved.devices.map(\.name) == ["ST-Link V2", "HackRF One"] && moved.devices.allSatisfy { $0.choice == .omarchy && $0.serial.isEmpty },
       "migration: each device becomes Connect to Omarchy (as before: it went to the VM by itself), any serial")
expect(USBSwitch.isOn(folder: f) && (try? String(contentsOf: f.appendingPathComponent("usb-enabled"), encoding: .utf8)) == "on\n",
       "migration: the switch is written on")
expect(!FileManager.default.fileExists(atPath: f.appendingPathComponent("usb").path)
       && FileManager.default.fileExists(atPath: f.appendingPathComponent("usb.before-3.0.4").path),
       "migration: usb renamed usb.before-3.0.4")
expect(USBMemory.load(folder: f) == moved, "migration runs once")
f = freshFolder("migrate-off")
try? Data("0483:3748 ST-Link V2\n".utf8).write(to: f.appendingPathComponent("usb"))
try? USBSwitch.set(false, folder: f)
_ = USBMemory.load(folder: f)
expect(!USBSwitch.isOn(folder: f) && USBMemory.load(folder: f).devices.count == 1, "migration: a switch that was off stays off")

// MARK: QMP: by bus and address, checked with info usb
expect(boardA.bus == 1 && USBQMP.qemuID(location: 0x0110_0000) == "usbh-01100000", "bus = locationID's top byte; id by place")
let args = USBQMP.attachArguments(boardA)
expect(args["driver"] as? String == "usb-host" && args["bus"] as? String == "usb0.0" && args["hostbus"] as? Int == 1
       && args["hostaddr"] as? Int == 0 && args["vendorid"] == nil && args["productid"] == nil,
       "device_add: usb-host on usb0 by hostbus+hostaddr only (QEMU opens exactly that device, never scans for more)")
let info = "  Device 0.0, Port 1, Speed 12 Mb/s, Product QEMU USB Tablet, ID: usbh-01100000\n  Device 1.2, Port 2, Speed 480 Mb/s, Product HackRF One\n"
expect(USBQMP.attachedIDs(infoUSB: info) == ["usbh-01100000"], "info usb: the ids of attached devices")
expect(USBQMP.reason(qemuError: "QMP command device_add failed: failed to open host usb device 1:5") == .busy
       && USBQMP.reason(qemuError: "failed to find host usb device 1:5") == .gone
       && USBQMP.reason(qemuError: "something else") == .failed("something else"),
       "device_add's errors in the user's terms")

final class FakeQMP: USBQMPTransport {
    var sent: [String] = []
    var attached = Set<String>()
    var addFails: String?
    var takes = true
    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
        sent.append(command)
        switch command {
        case "device_add":
            if let e = addFails { throw NSError(domain: "qmp", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
            if takes { attached.insert(arguments?["id"] as? String ?? "") }
            return [:]
        case "device_del":
            attached.remove(arguments?["id"] as? String ?? "")
            return [:]
        default:
            return ["text": attached.map { "  Device 0.1, Port 1, Speed 12 Mb/s, Product X, ID: \($0)" }.joined(separator: "\n")]
        }
    }
}
let fq = FakeQMP()
expect(USBQMP.attach(boardA, over: fq, wait: { _ in }) == .attached && fq.sent == ["device_add", "human-monitor-command"],
       "attach: device_add, then info usb lists it")
expect(USBQMP.detach(location: boardA.location, over: fq, wait: { _ in }) && fq.attached.isEmpty, "detach: device_del, then gone from info usb")
fq.takes = false
fq.sent = []
expect(USBQMP.attach(boardA, over: fq, wait: { _ in }) == .busy && fq.sent.last == "device_del" && fq.sent.filter { $0 == "human-monitor-command" }.count == 10,
       "attach that info usb never lists (3 s): removed again, busy")
final class SilentQMP: USBQMPTransport {
    var sent: [String] = []
    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
        sent.append(command)
        if command == "human-monitor-command" { throw NSError(domain: "qmp", code: 2, userInfo: [NSLocalizedDescriptionKey: "timed out"]) }
        return [:]
    }
}
let sq = SilentQMP()
expect(USBQMP.attach(boardA, over: sq, wait: { _ in }) == .failed("QEMU did not answer") && sq.sent.last == "device_del",
       "attach: info usb never answers: removed again, QEMU's failure (not \"a Mac app is using it\")")
fq.addFails = "QMP command device_add failed: failed to open host usb device 1:0"
expect(USBQMP.attach(boardA, over: fq, wait: { _ in }) == .busy, "device_add refused (macOS has it): busy")

// MARK: The session, on fakes (no device, no VM, no window)
final class FakeMachine: USBMachine {
    var log: [String] = []
    var result: USBAttachResult = .attached
    var hold = false
    var held: [() -> Void] = []
    var have = Set<UInt32>()
    func attach(_ d: USBDevice, done: @escaping (USBAttachResult) -> Void) {
        log.append("attach \(String(format: "%x", d.location))")
        let r = result
        let finish = { if r == .attached { self.have.insert(d.location) }; done(r) }
        if hold { held.append(finish) } else { finish() }
    }
    func detach(_ d: USBDevice, done: @escaping (Bool) -> Void) {
        log.append("detach \(String(format: "%x", d.location))")
        have.remove(d.location)
        done(true)
    }
    func isAttached(_ d: USBDevice, done: @escaping (Bool) -> Void) { done(have.contains(d.location)) }
}
final class FakeAsker: USBAsker {
    var asked: [USBQuestion] = []
    var open: ((USBAnswer) -> Void)?
    var cancels = 0
    var notices: [String] = []
    func ask(_ q: USBQuestion, answer: @escaping (USBAnswer) -> Void) { asked.append(q); open = answer }
    func cancel() { cancels += 1; open = nil }
    func notice(title: String, text: String) { notices.append(title + " / " + text) }
    func answer(_ connect: Bool, always: Bool = false) {
        let a = open
        open = nil
        a?(USBAnswer(connect: connect, always: always))
    }
}
final class FakeClock: USBClock {
    var timers: [(Double, () -> Void)] = []
    var now = 0.0
    func after(_ s: Double, _ run: @escaping () -> Void) { timers.append((now + s, run)) }
    func advance(_ s: Double) {
        now += s
        let due = timers.filter { $0.0 <= now }
        timers.removeAll { $0.0 <= now }
        due.forEach { $0.1() }
    }
}
struct Rig {
    let machine = FakeMachine(), asker = FakeAsker(), clock = FakeClock()
    var saved: [USBMemory] = []
    var lines: [String] = []
}
func rig(_ memory: USBMemory = USBMemory()) -> (USBSession, FakeMachine, FakeAsker, FakeClock, () -> [USBMemory], () -> [String]) {
    let m = FakeMachine(), a = FakeAsker(), c = FakeClock()
    var saved: [USBMemory] = [], lines: [String] = []
    let s = USBSession(vmName: "Omarchy", memory: memory, machine: m, asker: a, clock: c,
                       save: { saved.append($0) }, log: { lines.append($0) })
    return (s, m, a, c, { saved }, { lines })
}
let probe = board("", loc: 0x0110_0000)

// 1. Unknown device, VM in front: asked once; this time only.
do {
    let (s, m, a, _, saved, lines) = rig()
    s.plugged(probe)
    expect(a.asked.count == 1 && a.asked[0].title == "Connect “STM32 STLink” to Omarchy or keep it on the Mac?",
           "1: a free device plugged in is asked about once")
    expect(m.log.isEmpty, "1: nothing goes to the VM before the answer")
    a.answer(true)
    expect(m.log == ["attach 1100000"] && s.plugs[probe.location]?.state == .connected && saved().isEmpty,
           "1: Connect, box unchecked: connected, nothing saved")
    expect(lines().last == "OmacVM: USB: 0483:3748 STM32 STLink connected (asked, this time)", "1: the log line says it was this time")
    s.unplugged(location: probe.location)
    expect(m.log.count == 1, "1: unplugged: the VM keeps it for the grace time (a reset looks the same)")
    let (s2, m2, a2, c2, _, _) = rig()
    s2.plugged(probe); a2.answer(true); s2.unplugged(location: probe.location); c2.advance(USBSession.grace)
    expect(m2.log == ["attach 1100000", "detach 1100000"] && s2.plugs.isEmpty, "1: unplugged for good: device_del after the grace time")
    s2.plugged(probe)
    expect(a2.asked.count == 2, "1: plugged in again: asked again")
    s2.stop()
    expect(a2.cancels == 1 && s2.plugs.isEmpty, "1: VM stops: the open question closes, nothing kept")
    let (s3, _, a3, _, _, _) = rig(s2.memory)
    s3.plugged(probe)
    expect(a3.asked.count == 1, "1: next start: asked again (this time only does not carry over)")
}
// 2. The box checked: remembered.
do {
    let (s, m, a, _, saved, _) = rig()
    s.plugged(probe)
    a.answer(true, always: true)
    expect(saved().last?.plan(for: probe) == .omarchy && m.have.contains(probe.location), "2: Connect + Always: connected and saved")
    let (s2, m2, a2, _, _, lines2) = rig(saved().last!)
    s2.plugged(probe)
    expect(a2.asked.isEmpty && m2.log == ["attach 1100000"] && lines2().last?.hasSuffix("connected (remembered)") == true,
           "2: remembered Connect: connected at the next plug-in, no question")
    let (s3, m3, a3, _, saved3, _) = rig()
    s3.plugged(probe)
    a3.answer(false, always: true)
    expect(saved3().last?.plan(for: probe) == .mac && m3.log.isEmpty && s3.plugs[probe.location]?.state == .onMac(remembered: true),
           "2: Keep + Always: stays on the Mac, saved")
    let (s4, m4, a4, _, _, _) = rig(saved3().last!)
    s4.plugged(probe)
    expect(a4.asked.isEmpty && m4.log.isEmpty, "2: remembered Keep: never asked again")
    let rows = USBListRows.make(memory: saved3().last!, devices: [probe], states: nil, vmName: "Omarchy")
    expect(rows.remembered.count == 1 && rows.remembered[0].plan == .mac && rows.remembered[0].status == "Plugged in" && rows.plugged.isEmpty,
           "2: the list shows it remembered as Keep on Mac")
}
// 3. Devices macOS keeps: never asked.
do {
    let (s, m, a, _, _, _) = rig()
    for (i, d) in [scarlett, iphone, cam, hub, billboard, key, stick, ftdi].enumerated() {
        var d = d
        d.location = UInt32(0x0200_0000 + i)
        s.plugged(d)
    }
    expect(a.asked.isEmpty && m.log.isEmpty, "3: keyboard/security key, disk, audio, camera, iPhone, serial, hub, USB-C info: never asked")
    let rows = USBListRows.make(memory: USBMemory(), devices: [scarlett, iphone, key, hub], states: nil, vmName: "Omarchy")
    expect(rows.kept.map(\.why) == ["macOS uses it for sound", "macOS uses it (iPhone, iPad or photo import)",
                                    "macOS uses it as a keyboard, mouse or security key"] && rows.isEmpty,
           "3: the list shows them under Kept by macOS with why (hubs not at all)")
}
// 4. Unplugged while asking; two devices at once.
do {
    let (s, _, a, _, saved, _) = rig()
    let sdr = USBDevice(id: USBDeviceID(vendor: 0x1d50, product: 0x6089), name: "HackRF One", deviceClass: 0,
                        interfaces: [I(number: 0, interfaceClass: 0xff, users: [])], maker: "Great Scott Gadgets", location: 0x0130_0000, address: 4)
    s.inFront = false
    s.plugged(probe)
    s.plugged(sdr)
    s.inFront = true
    expect(a.asked.count == 1 && a.asked[0].detail == "STMicroelectronics · 0483:3748\n1 more device waiting",
           "4: two at once: one question, it says one more waits")
    s.unplugged(location: probe.location)
    expect(a.cancels == 1 && a.asked.count == 2 && a.asked[1].title.contains("HackRF One") && saved().isEmpty,
           "4: unplugged while asking: the question closes, nothing saved, the next one comes")
    s.unplugged(location: sdr.location)
    expect(a.cancels == 2 && s.plugs.isEmpty, "4: the second unplugged too: closed")
}
// 5. VM not in front: waits.
do {
    let (s, _, a, _, _, _) = rig()
    s.inFront = false
    s.plugged(probe)
    expect(a.asked.isEmpty && s.plugs[probe.location]?.state == .waiting, "5: VM not in front: no question, the device waits")
    s.inFront = true
    expect(a.asked.count == 1, "5: VM in front again: asked")
}
// 6. Reconnects within the grace time.
do {
    let (s, m, a, c, _, _) = rig()
    s.plugged(probe); a.answer(true)
    s.unplugged(location: probe.location)
    c.advance(1)
    var back = probe
    back.address = 9
    s.plugged(back)
    c.advance(USBSession.grace)
    expect(a.asked.count == 1 && m.log == ["attach 1100000"] && s.plugs[probe.location]?.state == .connected,
           "6: reset (gone and back at the same place, the VM still has it): no question, no device_del")
    let (s2, m2, a2, c2, _, _) = rig()
    s2.plugged(probe); a2.answer(true)
    s2.unplugged(location: probe.location)
    m2.have.removeAll()   // QEMU lost it
    s2.plugged(back)
    c2.advance(USBSession.grace)
    expect(a2.asked.count == 1 && m2.log == ["attach 1100000", "detach 1100000", "attach 1100000"] && s2.plugs[probe.location]?.state == .connected,
           "6: back within the grace time but QEMU lost it: given to the VM again without a question")
    let (s3, m3, a3, c3, _, _) = rig()
    s3.plugged(probe); a3.answer(true)
    s3.unplugged(location: probe.location)
    c3.advance(USBSession.grace)
    s3.plugged(probe)
    expect(a3.asked.count == 2 && m3.log == ["attach 1100000", "detach 1100000"], "6: back after the grace time: a new plug-in, asked")
}
// 6b. Review fixes: back and gone again; a different board back; a late result at a reused place.
do {
    let (s, m, a, c, _, _) = rig()
    s.plugged(probe); a.answer(true)
    s.unplugged(location: probe.location)
    var back = probe
    back.address = 9
    s.plugged(back)
    m.have.removeAll()
    s.unplugged(location: probe.location)
    c.advance(USBSession.grace)
    expect(s.plugs.isEmpty && m.log == ["attach 1100000", "detach 1100000"],
           "6b: back and gone again within the grace time: gone, not given to the VM again")
    let (s2, m2, a2, c2, _, _) = rig()
    let one = board("ONE", loc: 0x0110_0000), two = board("TWO", loc: 0x0110_0000)
    s2.plugged(one); a2.answer(true)
    s2.unplugged(location: one.location)
    m2.have.removeAll()
    s2.plugged(two)
    c2.advance(USBSession.grace)
    expect(a2.asked.count == 2 && a2.asked[1].location == two.location && m2.log == ["attach 1100000", "detach 1100000"]
           && s2.plugs[two.location]?.state == .asking,
           "6b: an identical board with another serial at that place: a new plug-in, asked")
    var busyBack = probe
    busyBack.interfaces = [I(number: 0, interfaceClass: 2, users: ["AppleUSBACMData"])]
    let (s3, m3, a3, c3, _, _) = rig()
    s3.plugged(probe); a3.answer(true)
    s3.unplugged(location: probe.location)
    m3.have.removeAll()
    s3.plugged(busyBack)
    c3.advance(USBSession.grace)
    expect(m3.log == ["attach 1100000", "detach 1100000"] && s3.plugs[probe.location]?.state == .kept("macOS uses it as a serial port"),
           "6b: back as a device macOS took: stays with the Mac, never given again")
    let (s4, m4, a4, _, _, _) = rig(USBMemory(devices: [.init(vendor: "0483", product: "3748", name: "STM32 STLink", choice: .omarchy)]))
    m4.hold = true
    s4.plugged(probe)
    s4.unplugged(location: probe.location)
    let sdr = USBDevice(id: USBDeviceID(vendor: 0x1d50, product: 0x6089), name: "HackRF One", deviceClass: 0,
                        interfaces: [I(number: 0, interfaceClass: 0xff, users: [])], location: probe.location, address: 7)
    s4.plugged(sdr)
    a4.answer(true)
    m4.held.forEach { $0() }
    expect(s4.plugs[sdr.location]?.state == .connected && s4.plugs[sdr.location]?.device == sdr
           && m4.log == ["attach 1100000", "detach 1100000", "attach 1100000"],
           "6b: a late answer for the device that left is not taken for the new one at that place (no device_del of it)")
}
// 7. Busy; the four-device limit.
do {
    let (s, m, a, _, _, lines) = rig()
    m.result = .busy
    s.plugged(probe); a.answer(true)
    expect(s.plugs[probe.location]?.state == .onMac(remembered: false)
           && a.notices.last == "Couldn’t connect “STM32 STLink” / A Mac app is using it. Quit that app, then unplug the device and plug it in again."
           && lines().last == "OmacVM: USB: 0483:3748 STM32 STLink not connected: in use on the Mac",
           "7: a Mac app has it: stays on the Mac, a notice says why, logged")
    let (s2, m2, a2, _, _, _) = rig()
    for i in 0..<5 {
        s2.plugged(board("S\(i)", loc: UInt32(0x0100_0000 + i)))
        a2.answer(true)
    }
    expect(m2.have.count == 4 && a2.notices.last == "Couldn’t connect “STM32 STLink” / Omarchy already has 4 USB devices. Unplug one first.",
           "7: a fifth device: not connected, the notice says the limit")
    let (s3, m3, a3, _, _, _) = rig()
    m3.hold = true
    s3.plugged(probe); a3.answer(true)
    s3.unplugged(location: probe.location)
    m3.held.forEach { $0() }
    expect(s3.plugs[probe.location]?.state == .leaving, "7: unplugged while QEMU takes it: the grace time decides")
}
// 8. The list's actions while the VM runs.
do {
    let (s, m, a, _, saved, _) = rig()
    s.plugged(probe); a.answer(false)
    var rows = USBListRows.make(memory: s.memory, devices: [probe], states: s.plugs.mapValues(\.state), vmName: "Omarchy")
    expect(rows.plugged.first?.status == "Plugged in, on the Mac" && rows.plugged.first?.canConnect == true, "8: kept this time: the list offers Connect")
    let (sa, ma, aa, _, _, _) = rig()
    sa.plugged(probe)
    let asking = USBListRows.make(memory: sa.memory, devices: [probe], states: sa.plugs.mapValues(\.state), vmName: "Omarchy")
    sa.connectNow(location: probe.location)
    expect(asking.plugged.first?.canConnect == false && ma.log.isEmpty && aa.open != nil,
           "8: while its question is open the list offers no Connect (answered in the question)")
    s.connectNow(location: probe.location)
    rows = USBListRows.make(memory: s.memory, devices: [probe], states: s.plugs.mapValues(\.state), vmName: "Omarchy")
    expect(m.have.contains(probe.location) && rows.plugged.first?.status == "Connected to Omarchy" && rows.plugged.first?.canDisconnect == true,
           "8: Connect from the list: connected")
    s.disconnectNow(location: probe.location)
    expect(m.log.last == "detach 1100000" && s.plugs[probe.location]?.state == .onMac(remembered: false), "8: Disconnect: back to the Mac now")
    s.setPlan(.omarchy, for: probe)
    expect(saved().last?.plan(for: probe) == .omarchy && m.log.count == 2, "8: a choice in the list is saved and only changes later plug-ins")
    s.forget(key: s.memory.devices[0].key)
    expect(s.memory.devices.isEmpty && saved().last?.devices.isEmpty == true, "8: Forget: gone from the list and the file")
}
// 10. The words.
do {
    let unnamed = USBDevice(id: USBDeviceID(vendor: 0x1234, product: 0xabcd), name: "", deviceClass: 0, interfaces: [], location: 5)
    let q = USBQuestion(device: unnamed, vmName: "Work", waiting: 2)
    expect(q.title == "Connect this USB device to Work or keep it on the Mac?" && q.detail == "1234:abcd\n2 more devices waiting",
           "10: a device without a name; two more waiting")
    let q2 = USBQuestion(device: probe, vmName: "Omarchy", waiting: 0)
    expect(q2.connect == "Connect to Omarchy" && q2.keep == "Keep on Mac" && q2.always == "Always do this for this device"
           && q2.text == "Omarchy can use it while it runs. The Mac gets it back when you unplug it or Omarchy shuts down.",
           "10: the buttons and the box (unchecked: this plug-in only)")
    expect(USBListRows.summary(memory: USBMemory()) == "Asks when you plug in a device."
           && USBListRows.summary(memory: mem) == "Asks when you plug in a device. 1 remembered.", "10: the line under the switch")
    let twin = USBListRows.make(memory: USBMemory(devices: [
        .init(vendor: "0483", product: "3748", serial: "066DFF485157717867", name: "STM32 STLink", maker: "STMicroelectronics", choice: .omarchy),
        .init(vendor: "0483", product: "3748", serial: "0670FF4851", name: "STM32 STLink", maker: "STMicroelectronics", choice: .mac),
    ]), devices: [boardB], states: nil, vmName: "Omarchy")
    expect(twin.remembered.map(\.detail) == ["STMicroelectronics · 0483:3748 · serial …7867", "STMicroelectronics · 0483:3748 · serial …4851"]
           && twin.remembered.map(\.status) == ["Not plugged in", "Plugged in"],
           "10: two identical boards: the serial tells them apart, each its own status")
}
do {
    let twin = board("", loc: 0x0120_0000)
    let shared = USBMemory(devices: [.init(vendor: "0483", product: "3748", name: "STM32 STLink", choice: .omarchy)])
    let rows = USBListRows.make(memory: shared, devices: [probe, twin], states: nil, vmName: "Omarchy")
    expect(rows.remembered.count == 1 && rows.plugged.count == 1 && rows.plugged[0].plan == .omarchy,
           "10: two boards without a serial: the second shows the choice they share")
}
try? FileManager.default.removeItem(at: tmp)

if let i = CommandLine.arguments.firstIndex(of: "--qmp"), i + 1 < CommandLine.arguments.count {
    qmpIntegration(qemu: CommandLine.arguments[i + 1], expect: { expect($0, $1) })
}
// The scan only reads the IORegistry; on any Mac it returns without opening anything.
_ = USBScan.devices()
expect(true, "the IORegistry scan runs")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
