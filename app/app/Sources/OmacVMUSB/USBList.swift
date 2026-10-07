import Foundation

/// The rows of the USB Devices list (USBDeviceList in the app), from the
/// remembered devices, the devices plugged in now and, while the VM runs,
/// what the session did with each.
public struct USBListRows: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        /// The remembered entry's key, else "plug-<location>".
        public var id: String
        public var name: String
        /// "STMicroelectronics · 0483:3748"
        public var detail: String
        public var status: String
        public var plan: USBPlan
        /// Remembered: its key in USBMemory.
        public var key: String?
        /// Plugged in now (and free): the device.
        public var device: USBDevice?
        public var canConnect: Bool
        public var canDisconnect: Bool
    }

    public var remembered: [Row] = []
    /// Free devices plugged in now that are not remembered.
    public var plugged: [Row] = []
    /// Devices macOS keeps: name and why.
    public var kept: [Kept] = []

    public struct Kept: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var why: String
    }

    public init() {}

    public var isEmpty: Bool { remembered.isEmpty && plugged.isEmpty }

    /// `states`: the session's (nil before the VM runs).
    public static func make(memory: USBMemory, devices: [USBDevice], states: [UInt32: USBSession.State]?,
                            vmName: String) -> USBListRows {
        var out = USBListRows()
        let running = states != nil
        var used = Set<UInt32>()
        func detail(maker: String, id: String, serial: String, sharedID: Bool) -> String {
            var p: [String] = []
            if !maker.isEmpty { p.append(maker) }
            p.append(id)
            if sharedID && !serial.isEmpty { p.append("serial …\(serial.suffix(4))") }
            return p.joined(separator: " · ")
        }
        func status(_ d: USBDevice?) -> (String, Bool, Bool) {
            guard let d else { return ("Not plugged in", false, false) }
            guard let states else { return ("Plugged in", false, false) }
            switch states[d.location] {
            case .connected?: return ("Connected to \(vmName)", false, true)
            case .connecting?: return ("Connecting…", false, false)
            // Asking: answered in the question (Connect here would race it).
            case .asking?: return ("Plugged in, waiting for your answer", false, false)
            case .waiting?: return ("Plugged in, waiting for your answer", true, false)
            case .leaving?: return ("Reconnecting…", false, false)
            default: return ("Plugged in, on the Mac", true, false)
            }
        }
        let free = devices.filter { $0.availability == .free }
        for e in memory.devices {
            // The plugged-in device this entry is for (USBMemory.entry picks the entry per device).
            let d = free.first { !used.contains($0.location) && memory.entry(for: $0) == e }
            if let d { used.insert(d.location) }
            let shared = memory.devices.filter { $0.vendor == e.vendor && $0.product == e.product }.count > 1
            let (s, c, dis) = status(d)
            out.remembered.append(Row(id: e.key, name: e.displayName,
                                      detail: detail(maker: e.maker, id: "\(e.vendor):\(e.product)", serial: e.serial, sharedID: shared),
                                      status: s, plan: e.choice, key: e.key, device: d,
                                      canConnect: running && c, canDisconnect: running && dis))
        }
        for d in free where !used.contains(d.location) {
            let (s, c, dis) = status(d)
            out.plugged.append(Row(id: "plug-\(String(format: "%08x", d.location))", name: d.displayName,
                                   detail: detail(maker: d.maker, id: d.id.description, serial: d.serial, sharedID: false),
                                   // A device without a serial shares its twin's entry (USBMemory.entry).
                                   status: s, plan: memory.entry(for: d)?.choice ?? .ask, key: nil, device: d,
                                   canConnect: running && c, canDisconnect: running && dis))
        }
        for d in devices {
            if case .usedByMac(let why) = d.availability {
                out.kept.append(Kept(id: "kept-\(String(format: "%08x", d.location))-\(d.id)", name: d.displayName, why: why))
            }
        }
        return out
    }

    /// The line under the switch in the VM window.
    public static func summary(memory: USBMemory) -> String {
        let n = memory.devices.count
        return "Asks when you plug in a device." + (n == 0 ? "" : n == 1 ? " 1 remembered." : " \(n) remembered.")
    }
}
