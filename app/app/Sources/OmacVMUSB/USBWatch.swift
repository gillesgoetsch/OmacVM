import Foundation
import IOKit

/// The Mac's USB devices coming and going, from IOKit's notifications on
/// the main run loop: the devices there at `start`, then each one plugged
/// in, once macOS has set it up (its drivers matched: IOServiceWaitQuiet, at
/// most 2 s, so a USB stick is seen as a disk, not as free), and each one
/// unplugged, by its place (locationID). Reads the IORegistry only, opens no
/// device. Main thread.
public final class USBWatch {
    public var onPlug: (USBDevice) -> Void = { _ in }
    public var onUnplug: (UInt32) -> Void = { _ in }

    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    /// IORegistry entry id -> locationID (a removed entry can no longer be read).
    private var places: [UInt64: UInt32] = [:]
    /// Being read (settling), and those of them that left meanwhile.
    private var settling = Set<UInt64>()
    private var leftEarly = Set<UInt64>()
    private let settle = DispatchQueue(label: "org.omacvm.usb-watch", qos: .utility, attributes: .concurrent)
    private var running = false

    public init() {}

    public func start() {
        guard !running, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        running = true
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { ref, it in
            guard let ref else { return }
            Unmanaged<USBWatch>.fromOpaque(ref).takeUnretainedValue().arrived(it)
        }, me, &added)
        IOServiceAddMatchingNotification(p, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { ref, it in
            guard let ref else { return }
            Unmanaged<USBWatch>.fromOpaque(ref).takeUnretainedValue().left(it)
        }, me, &removed)
        // Arms the notifications and reports the devices there now (set up already: no wait).
        arrived(added, initial: true)
        left(removed)
    }

    public func stop() {
        guard running else { return }
        running = false
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let p = port {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
            IONotificationPortDestroy(p)
        }
        port = nil
        places.removeAll()
        settling.removeAll()
        leftEarly.removeAll()
    }

    private func arrived(_ it: io_iterator_t, initial: Bool = false) {
        while case let dev = IOIteratorNext(it), dev != 0 {
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(dev, &entry)
            settling.insert(entry)
            // Read off the main thread: waiting for macOS's drivers takes up to 2 s.
            settle.async { [weak self] in
                if !initial {
                    var wait = mach_timespec_t(tv_sec: 2, tv_nsec: 0)
                    _ = IOServiceWaitQuiet(dev, &wait)
                    // Apps that use a device (usbmuxd, usbaudiod) open it a moment after the drivers.
                    Thread.sleep(forTimeInterval: 0.5)
                }
                let d = USBScan.device(dev)
                IOObjectRelease(dev)
                DispatchQueue.main.async {
                    guard let self, self.running else { return }
                    self.settling.remove(entry)
                    // Gone before it was set up: never reported.
                    if self.leftEarly.remove(entry) != nil { return }
                    guard let d else { return }
                    self.places[entry] = d.location
                    self.onPlug(d)
                }
            }
        }
    }

    private func left(_ it: io_iterator_t) {
        while case let dev = IOIteratorNext(it), dev != 0 {
            var entry: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(dev, &entry)
            IOObjectRelease(dev)
            if settling.contains(entry) {
                leftEarly.insert(entry)
            } else if let loc = places.removeValue(forKey: entry) {
                onUnplug(loc)
            }
        }
    }
}
