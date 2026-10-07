import Foundation
import IOKit

// USB devices for a VM (docs/usb.md): off by default, per VM, a device at a
// time. QEMU takes a device through libusb, and on macOS libusb can only take
// an interface no macOS driver or app uses: taking one from macOS needs the
// com.apple.vm.device-access entitlement (Apple grants it per developer team;
// OmacVM has not got it) or root. So the app offers only devices nothing on
// the Mac uses (debug probes, SDR sticks, logic analysers, phones in
// fastboot/ADB, ...), and says why the others (keyboards, security keys,
// storage, serial adapters, audio, cameras) stay with the Mac.

/// A device's vendor and product: what the VM's setting stores and what QEMU
/// matches, so a device goes to the VM whenever it is plugged in.
public struct USBDeviceID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var vendor: UInt16
    public var product: UInt16

    public init(vendor: UInt16, product: UInt16) {
        self.vendor = vendor
        self.product = product
    }

    /// "0483:3748" (as lsusb writes it).
    public init?(text: String) {
        let p = text.split(separator: ":")
        guard p.count == 2, p[0].count == 4, p[1].count == 4,
              let v = UInt16(p[0], radix: 16), let d = UInt16(p[1], radix: 16) else { return nil }
        vendor = v
        product = d
    }

    public var description: String { String(format: "%04x:%04x", vendor, product) }

    public static func < (a: USBDeviceID, b: USBDeviceID) -> Bool {
        (a.vendor, a.product) < (b.vendor, b.product)
    }
}

/// One device the Mac sees, read from the IORegistry (nothing is opened).
public struct USBDevice: Equatable, Sendable {
    public struct Interface: Equatable, Sendable {
        public var number: Int
        public var interfaceClass: Int
        /// What on the Mac has it: driver class names, or the names of the
        /// apps and services that opened it (usbmuxd, usbaudiod, ...).
        public var users: [String]

        public init(number: Int, interfaceClass: Int, users: [String]) {
            self.number = number
            self.interfaceClass = interfaceClass
            self.users = users
        }
    }

    public var id: USBDeviceID
    public var name: String
    public var deviceClass: Int
    /// Drivers on the device itself (not its interfaces), other than the
    /// ones that never keep it from a VM (the composite driver, apps that only
    /// read it, like a browser's WebUSB list).
    public var drivers: [String]
    public var interfaces: [Interface]

    public init(id: USBDeviceID, name: String, deviceClass: Int, drivers: [String] = [], interfaces: [Interface]) {
        self.id = id
        self.name = name
        self.deviceClass = deviceClass
        self.drivers = drivers
        self.interfaces = interfaces
    }

    public enum Availability: Equatable, Sendable {
        /// Nothing on the Mac uses it: a VM can have it.
        case free
        /// macOS uses it (why, in a few words): it stays with the Mac.
        case usedByMac(String)
        /// Never offered (a hub, a USB-C adapter's info device).
        case notOffered(String)
    }

    public var availability: Availability {
        if deviceClass == 0x09 || interfaces.contains(where: { $0.interfaceClass == 0x09 }) {
            return .notOffered("a USB hub")
        }
        // Billboard: a USB-C adapter or display tells macOS which modes it has;
        // nothing for a VM (macOS's billboard driver holds it, also when the
        // device has a vendor interface next to it).
        if deviceClass == 0x11 || interfaces.contains(where: { $0.interfaceClass == 0x11 }) {
            return .notOffered("a USB-C adapter's info device")
        }
        let users = drivers + interfaces.flatMap(\.users)
        if let u = users.first { return .usedByMac(USBDevice.reason(u)) }
        return .free
    }

    /// Which part of macOS has it, in a few words.
    public static func reason(_ user: String) -> String {
        let u = user.lowercased()
        func has(_ words: String...) -> Bool { words.contains { u.contains($0) } }
        if has("usbmuxd", "ptpcamerad", "iosdevice") { return "macOS uses it (iPhone, iPad or photo import)" }
        if has("hid") { return "macOS uses it as a keyboard, mouse or security key" }
        if has("audio") { return "macOS uses it for sound" }
        if has("massstorage", "scsi", "uas", "storage") { return "macOS uses it as a disk" }
        if has("cdc", "serial", "ftdi", "slcom", "chcom", "plcom", "acm") { return "macOS uses it as a serial port" }
        if has("uvc", "video", "camera") { return "macOS uses it as a camera" }
        if has("ncm", "ecm", "ethernet", "network") { return "macOS uses it as a network adapter" }
        if has("bluetooth") { return "macOS uses it for Bluetooth" }
        if has("smartcard", "ccid") { return "macOS uses it as a smart card reader" }
        return "in use on the Mac (\(user))"
    }

    /// Device-level children that never keep a device from a VM: the
    /// composite driver (it only sets the configuration) and user clients of
    /// apps that only look at the device (a browser's WebUSB list). An app
    /// that uses a device opens its interfaces, and that counts.
    public static func ignoredDeviceChild(className: String) -> Bool {
        className == "AppleUSBHostCompositeDevice" || className == "IOUSBHostInterface"
            || className.hasSuffix("DeviceUserClient") || className.hasSuffix("DeviceUserClientV2")
    }
}

/// The VM's USB devices: the file `usb` in its folder, one device a line,
/// "0483:3748 ST-Link V2". No file, or no device: no USB controller at all
/// (the VM is as before).
public enum USBChoice {
    /// QEMU's xHCI controller has four ports of each speed.
    public static let maxDevices = 4
    public static let fileName = "usb"

    public struct Entry: Equatable, Sendable {
        public var id: USBDeviceID
        public var name: String
        public init(id: USBDeviceID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// From the file's text: lines that are not a device are skipped, a
    /// device named twice counts once, at most maxDevices. Spaces or tabs
    /// part the id from the name.
    public static func parse(_ text: String) -> [Entry] {
        var out: [Entry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#") else { continue }
            let parts = t.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first, let id = USBDeviceID(text: String(first)),
                  !out.contains(where: { $0.id == id }) else { continue }
            out.append(Entry(id: id, name: parts.count > 1 ? clean(String(parts[1])) : ""))
            if out.count == maxDevices { break }
        }
        return out
    }

    public static func format(_ entries: [Entry]) -> String {
        entries.prefix(maxDevices).map { $0.name.isEmpty ? "\($0.id)" : "\($0.id) \(clean($0.name))" }
            .joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    /// A name for the file: one line, printable, short.
    static func clean(_ s: String) -> String {
        let printable = String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
        return String(printable.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    public static func load(folder: URL) -> [Entry] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// Writes the choice; no device removes the file (USB off).
    public static func save(_ entries: [Entry], folder: URL) throws {
        let url = folder.appendingPathComponent(fileName)
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try Data(format(entries).utf8).write(to: url, options: .atomic)
    }

    /// QEMU's arguments: an xHCI controller and one usb-host per device,
    /// matched by vendor and product, so QEMU takes the device when it is
    /// plugged in (also later, while the VM runs) and gives it back when the
    /// VM stops. The guest may reset the device (QEMU's default: DFU and
    /// firmware tools need it); qemu-usb-host-busy-device.patch sends a reset
    /// only to a device QEMU really has, since on macOS it re-enumerates it.
    /// Last on the command line, so no other device moves.
    public static func arguments(_ entries: [Entry]) -> [String] {
        let list = Array(entries.prefix(maxDevices))
        guard !list.isEmpty else { return [] }
        var a = ["-device", "qemu-xhci,id=usb0"]
        for (i, e) in list.enumerated() {
            a += ["-device", String(format: "usb-host,bus=usb0.0,vendorid=0x%04x,productid=0x%04x,id=usbhost%d",
                                    e.id.vendor, e.id.product, i)]
        }
        return a
    }

    /// For qemu.log, which omacvm check reads: "off" or "0483:3748 ST-Link V2, ...".
    public static func record(_ entries: [Entry]) -> String {
        let list = entries.prefix(maxDevices)
        guard !list.isEmpty else { return "off" }
        return list.map { $0.name.isEmpty ? "\($0.id)" : "\($0.id) \($0.name)" }.joined(separator: ", ")
    }
}

/// The Mac's USB devices now, from the IORegistry. Reads properties only:
/// no device is opened, so nothing on the Mac notices.
public enum USBScan {
    public static func devices() -> [USBDevice] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }
        var out: [USBDevice] = []
        while case let dev = IOIteratorNext(iter), dev != 0 {
            defer { IOObjectRelease(dev) }
            if let d = device(dev) { out.append(d) }
        }
        return out.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    static func device(_ dev: io_registry_entry_t) -> USBDevice? {
        guard let v = int(dev, "idVendor"), let p = int(dev, "idProduct") else { return nil }
        let id = USBDeviceID(vendor: UInt16(truncatingIfNeeded: v), product: UInt16(truncatingIfNeeded: p))
        let name = string(dev, "USB Product Name") ?? string(dev, "kUSBProductString") ?? registryName(dev)
        var drivers: [String] = []
        var interfaces: [USBDevice.Interface] = []
        for child in children(dev) {
            defer { IOObjectRelease(child) }
            let cls = className(child)
            if cls == "IOUSBHostInterface" {
                var users: [String] = []
                for u in children(child) {
                    users.append(user(u))
                    IOObjectRelease(u)
                }
                interfaces.append(.init(number: int(child, "bInterfaceNumber") ?? interfaces.count,
                                        interfaceClass: int(child, "bInterfaceClass") ?? 0, users: users))
            } else if !USBDevice.ignoredDeviceChild(className: cls) {
                drivers.append(user(child))
            }
        }
        return USBDevice(id: id, name: name, deviceClass: int(dev, "bDeviceClass") ?? 0,
                         drivers: drivers, interfaces: interfaces.sorted { $0.number < $1.number })
    }

    /// An app or service that opened it (its name), else the driver's class.
    static func user(_ e: io_registry_entry_t) -> String {
        let cls = className(e)
        if cls.contains("UserClient") || cls.contains("FrameworkInterfaceClient") {
            let n = registryName(e)
            return n.split(separator: "@").first.map(String.init) ?? n
        }
        return cls
    }

    static func children(_ e: io_registry_entry_t) -> [io_registry_entry_t] {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [io_registry_entry_t] = []
        while case let c = IOIteratorNext(it), c != 0 { out.append(c) }
        return out
    }

    static func className(_ e: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(e, &buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    static func registryName(_ e: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(e, &buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    static func property(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func int(_ e: io_registry_entry_t, _ key: String) -> Int? {
        (property(e, key) as? NSNumber)?.intValue
    }

    static func string(_ e: io_registry_entry_t, _ key: String) -> String? {
        (property(e, key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
