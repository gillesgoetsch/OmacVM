import Foundation

/// One QMP command on QEMU's control socket: the reply's "return" object, or
/// an error with QEMU's own description. The app's QMPConnection does this;
/// usb-tests has a small one of its own for a real QEMU.
public protocol USBQMPTransport {
    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any]
}

/// How the app gives a plugged-in device to the VM and takes it back, over
/// QMP while QEMU runs. A device is named by where it is plugged in
/// ("usbh-<locationID>"), and QEMU opens exactly that one: by its bus and
/// address, with no vendor or product. Without those, QEMU's usb-host opens
/// the device at once (device_add fails when it cannot) and never looks for
/// it again: a device never goes to the VM unless the app adds it.
public enum USBQMP {
    /// The xHCI controller a start adds while the switch is on (USBSwitch.arguments).
    public static let controller = "usb0"

    public static func qemuID(location: UInt32) -> String { String(format: "usbh-%08x", location) }

    public static func attachArguments(_ d: USBDevice) -> [String: Any] {
        ["driver": "usb-host", "id": qemuID(location: d.location), "bus": "\(controller).0",
         "hostbus": d.bus, "hostaddr": d.address]
    }

    /// The ids "info usb" lists: a device QEMU has attached to the VM's bus
    /// (hw/usb/bus.c lists only those), e.g.
    /// "  Device 0.1, Port 1, Speed 12 Mb/s, Product STM32 STLink, ID: usbh-01100000".
    public static func attachedIDs(infoUSB text: String) -> Set<String> {
        var out = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: ", ID: ", options: .backwards) else { continue }
            let id = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { out.insert(id) }
        }
        return out
    }

    /// Why QEMU did not take it, in the user's words, from device_add's error.
    public static func reason(qemuError: String) -> USBAttachResult {
        let e = qemuError.lowercased()
        if e.contains("failed to open") || e.contains("in use") || e.contains("busy") || e.contains("access") {
            return .busy
        }
        if e.contains("failed to find") { return .gone }
        if e.contains("no free") || e.contains("no usb ports") || e.contains("port") && e.contains("free") { return .full }
        return .failed(String(qemuError.prefix(160)))
    }

    /// Adds the device; it counts as given only once "info usb" lists it
    /// (checked every 0.3 s for up to 3 s). Else it is removed again.
    public static func attach(_ d: USBDevice, over qmp: USBQMPTransport,
                              wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> USBAttachResult {
        let id = qemuID(location: d.location)
        do {
            _ = try qmp.execute("device_add", attachArguments(d))
        } catch {
            return reason(qemuError: "\(error)")
        }
        var answered = false
        for i in 0..<10 {
            if i > 0 { wait(0.3) }
            if let ids = try? attached(over: qmp) {
                answered = true
                if ids.contains(id) { return .attached }
            }
        }
        _ = try? qmp.execute("device_del", ["id": id])
        // QEMU never answered "info usb": not a Mac app's doing.
        return answered ? .busy : .failed("QEMU did not answer")
    }

    /// Takes it from the VM (the Mac gets it back when QEMU closes it).
    /// True once "info usb" no longer lists it.
    @discardableResult
    public static func detach(location: UInt32, over qmp: USBQMPTransport,
                              wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        let id = qemuID(location: location)
        _ = try? qmp.execute("device_del", ["id": id])
        for i in 0..<7 {
            if i > 0 { wait(0.3) }
            if let ids = try? attached(over: qmp), !ids.contains(id) { return true }
        }
        return false
    }

    public static func attached(over qmp: USBQMPTransport) throws -> Set<String> {
        let r = try qmp.execute("human-monitor-command", ["command-line": "info usb"])
        return attachedIDs(infoUSB: r["text"] as? String ?? "")
    }
}

public enum USBAttachResult: Equatable, Sendable {
    case attached
    /// macOS or a Mac app has it open.
    case busy
    /// It was unplugged before QEMU found it.
    case gone
    /// The VM's controller has no free port.
    case full
    /// QEMU did not answer, or said something else.
    case failed(String)
}
