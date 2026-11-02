import Foundation

/// QEMU's arguments and environment for drag and drop (feature drag-drop on
/// only; off: none of it, so the VM starts exactly as before).
public enum DropPlan {
    public static let portName = "org.omacvm.drop"
    /// After org.omacvm.media (9) on vser0: a port moves no PCI device.
    public static let portNumber = 10
    /// The 9p share's tag; the VM mounts it read-only at /run/omacvm/drop.
    public static let tag = "omacvm-drop"
    /// The VM folder's staging folder (the share's root).
    public static let folderName = "drop"
    /// QEMU's window code takes drops only with this set (omacvm-cocoa-drop.patch).
    public static let socketVariable = "OMACVM_DROP_SOCKET"
    /// Tests: QEMU and DropServer take "test-drop" lines (DropWire.testDropLine).
    public static let testVariable = "OMACVM_DROP_TEST"
    /// The VM sees the files as its desktop user's (qemu-9p-guest-owner.patch).
    public static let guestUID = 1000

    /// The port (`socket` already quoted for QEMU's option syntax).
    public static func portArguments(socket: String) -> [String] {
        ["-chardev", "socket,id=drop0,path=\(socket),server=on,wait=off",
         "-device", "virtserialport,bus=vser0.0,nr=\(portNumber),chardev=drop0,name=\(portName)"]
    }

    /// The read-only share of the staging folder. A PCI device: it goes after
    /// every other one (the Mac folder too), so turning drag and drop on or
    /// off moves no other device (the network card keeps its name).
    public static func shareArguments(folder: String) -> [String] {
        let q = folder.replacingOccurrences(of: ",", with: ",,")
        return ["-fsdev", "local,id=dropfs,path=\(q),security_model=none,readonly=on,multidevs=remap,guest_owner_uid=\(guestUID),guest_owner_gid=\(guestUID)",
                "-device", "virtio-9p-pci,fsdev=dropfs,mount_tag=\(tag)"]
    }

    /// Runner's last step: with the switch on, the port and the share after
    /// every other argument (the share is the last PCI device); off: the
    /// arguments as they are.
    public static func finish(arguments a: [String], on: Bool, folder: String, portSocket: String) -> [String] {
        on ? a + portArguments(socket: portSocket) + shareArguments(folder: folder) : a
    }

    /// The record for qemu.log (omacvm check reads "drag and drop: on").
    public static func record(on: Bool) -> String {
        on ? "on (waiting for the VM)" : "off"
    }
}

/// QEMU's pid for DropServer's peer check, set once QEMU runs; read from its threads.
public final class DropPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    public init() {}
    public func set(_ p: pid_t?) { lock.lock(); pid = p; lock.unlock() }
    public var value: pid_t? { lock.lock(); defer { lock.unlock() }; return pid }
}
