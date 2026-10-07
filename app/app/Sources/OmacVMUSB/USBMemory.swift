import Foundation

/// What to do when a device is plugged in while the VM runs.
public enum USBPlan: String, Codable, CaseIterable, Sendable {
    /// Ask each time (the default: also every device the app does not know).
    case ask
    /// Give it to the VM without asking.
    case omarchy
    /// Keep it on the Mac without asking.
    case mac
}

/// The devices the user said "Always do this for this device" for (or set in
/// the list): `usb.json` in the VM's folder. An answer for this plug-in only
/// is never written here (USBSession keeps it until the device is unplugged
/// or the VM stops).
public struct USBMemory: Equatable, Sendable {
    public static let fileName = "usb.json"
    /// The 3.0.1 to 3.0.3 file after its devices moved here.
    public static let oldFileRenamed = "usb.before-3.0.4"
    public static let maxDevices = 32

    public struct Device: Equatable, Codable, Sendable {
        public var vendor: String
        public var product: String
        /// "" for a device without one: then it matches any device of that id.
        public var serial: String
        public var name: String
        public var maker: String
        public var choice: USBPlan
        /// When it was remembered ("2026-10-07").
        public var since: String

        public init(vendor: String, product: String, serial: String = "", name: String, maker: String = "",
                    choice: USBPlan, since: String = "") {
            self.vendor = vendor
            self.product = product
            self.serial = serial
            self.name = name
            self.maker = maker
            self.choice = choice
            self.since = since
        }

        public var id: USBDeviceID? { USBDeviceID(text: "\(vendor):\(product)") }

        /// Unique within the list: the id and the serial.
        public var key: String { "\(vendor):\(product)/\(serial)" }

        public var displayName: String { name.isEmpty ? "USB device" : name }
    }

    public var devices: [Device]

    public init(devices: [Device] = []) { self.devices = devices }

    /// The remembered entry for a plugged-in device: the one with its serial
    /// number, else one without a serial (two identical boards can each have
    /// their own choice, a device without a serial has one for all of them).
    public func entry(for d: USBDevice) -> Device? {
        let v = String(format: "%04x", d.id.vendor), p = String(format: "%04x", d.id.product)
        let same = devices.filter { $0.vendor == v && $0.product == p }
        if !d.serial.isEmpty, let e = same.first(where: { $0.serial == d.serial }) { return e }
        return same.first { $0.serial.isEmpty }
    }

    public func plan(for d: USBDevice) -> USBPlan { entry(for: d)?.choice ?? .ask }

    /// Remembers a device's choice: its entry changes, or a new one comes
    /// first (the oldest goes past maxDevices).
    public mutating func remember(_ d: USBDevice, _ choice: USBPlan, today: String = USBMemory.today()) {
        let name = USBChoice.clean(d.name), maker = USBChoice.clean(d.maker)
        if let e = entry(for: d), let i = devices.firstIndex(of: e) {
            devices[i].choice = choice
            if !name.isEmpty { devices[i].name = name }
            if !maker.isEmpty { devices[i].maker = maker }
            return
        }
        devices.insert(Device(vendor: String(format: "%04x", d.id.vendor), product: String(format: "%04x", d.id.product),
                              serial: USBChoice.clean(d.serial), name: name, maker: maker, choice: choice, since: today),
                       at: 0)
        if devices.count > Self.maxDevices { devices.removeLast(devices.count - Self.maxDevices) }
    }

    public mutating func set(key: String, _ choice: USBPlan) {
        if let i = devices.firstIndex(where: { $0.key == key }) { devices[i].choice = choice }
    }

    public mutating func forget(key: String) {
        devices.removeAll { $0.key == key }
    }

    public static func today(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: The file

    private struct File: Codable {
        var version: Int
        var devices: [Device]
    }

    /// From the file's bytes: nil when it is no such file. Entries with a
    /// wrong id are dropped, names cleaned, at most maxDevices, each device
    /// once.
    public static func decode(_ data: Data) -> USBMemory? {
        guard let f = try? JSONDecoder().decode(File.self, from: data), f.version == 1 else { return nil }
        var out: [Device] = []
        for var d in f.devices {
            d.vendor = d.vendor.lowercased()
            d.product = d.product.lowercased()
            guard d.id != nil, !out.contains(where: { $0.key == d.key }) else { continue }
            d.serial = USBChoice.clean(d.serial)
            d.name = USBChoice.clean(d.name)
            d.maker = USBChoice.clean(d.maker)
            d.since = String(USBChoice.clean(d.since).prefix(10))
            out.append(d)
            if out.count == maxDevices { break }
        }
        return USBMemory(devices: out)
    }

    public func encode() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(File(version: 1, devices: devices))) ?? Data()
    }

    /// The VM's remembered devices. Moves the 3.0.1 to 3.0.3 `usb` file in
    /// first (USBMemory.migrate); a file that cannot be read is put aside as
    /// usb.json.bad and counts as empty (log says so).
    public static func load(folder: URL, log: (String) -> Void = { _ in }) -> USBMemory {
        migrate(folder: folder, log: log)
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return USBMemory() }
        if let m = decode(data) { return m }
        let bad = folder.appendingPathComponent(fileName + ".bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        log("OmacVM: USB: \(fileName) could not be read: put aside as \(fileName).bad, no device remembered")
        return USBMemory()
    }

    /// Written whole (atomic), readable only by the user.
    public func save(folder: URL) throws {
        let url = folder.appendingPathComponent(Self.fileName)
        try encode().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 3.0.1 to 3.0.3 gave each device in `usb` to the VM whenever it was
    /// plugged in. Those devices become "Connect to Omarchy" (nothing changes
    /// for them, and the list now shows them, to change or forget), the
    /// switch is written on (a VM with devices and no switch file was on),
    /// and `usb` is renamed usb.before-3.0.4. Only when there is no usb.json yet.
    public static func migrate(folder: URL, log: (String) -> Void = { _ in }) {
        let fm = FileManager.default
        let old = folder.appendingPathComponent(USBChoice.fileName)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: folder.appendingPathComponent(fileName).path) else {
            return
        }
        let entries = USBChoice.load(folder: folder)
        if !entries.isEmpty {
            let wasOn = USBSwitch.isOn(folder: folder)
            let m = USBMemory(devices: entries.map {
                Device(vendor: String(format: "%04x", $0.id.vendor), product: String(format: "%04x", $0.id.product),
                       name: $0.name, choice: .omarchy, since: today())
            })
            guard (try? m.save(folder: folder)) != nil else { return }
            if wasOn { try? USBSwitch.set(true, folder: folder) }
            log("OmacVM: USB: \(entries.count) device(s) from the usb file now connect to the VM when plugged in (list: Devices…)")
        }
        let renamed = folder.appendingPathComponent(oldFileRenamed)
        try? fm.removeItem(at: renamed)
        try? fm.moveItem(at: old, to: renamed)
    }

    /// For qemu.log's start line: "0483:3748 ST-Link V2: VM, 1d50:6089 HackRF One: Mac".
    public var record: String {
        devices.map { d in
            "\(d.vendor):\(d.product)\(d.name.isEmpty ? "" : " \(d.name)"): \(d.choice == .omarchy ? "VM" : d.choice == .mac ? "Mac" : "ask")"
        }.joined(separator: ", ")
    }
}
