import Foundation
import IOKit

/// A touch display on this Mac (the MacBook Pro with the touch screen,
/// macOS 27; #843): a HID device whose DeviceUsagePairs say touch screen
/// (Digitizer page 0x0D, usage 0x04; a trackpad's say touch pad, 0x0D/0x05).
///
/// With one, the VM gets a touch screen (QEMU's virtio-multitouch) for a
/// pinch: QEMU's window sends a pinch's two fingers to it, and the VM's apps
/// zoom between them, as macOS does (omacvm-cocoa-touch.patch). Without one
/// the VM is as before: a VM with a touch screen tells its apps so (Chromium
/// reports 10 touch points to web pages), and nothing would ever touch it.
/// OMACVM_TOUCH_SCREEN=1 or 0 in the app's environment decides it whatever
/// the Mac has (a Sidecar iPad's touches come the same way; tests).
///
/// The rules on their own (Foundation and IOKit only):
/// src/tests/app-touch-display.sh compiles and tests them without the app.
enum TouchDisplay {
    static let page = 0x0D
    static let usage = 0x04
    static let device = "virtio-multitouch-pci,romfile="

    /// A HID device's DeviceUsagePairs: is one of them a touch screen?
    static func isTouchScreen(usagePairs: Any?) -> Bool {
        guard let pairs = usagePairs as? [Any] else { return false }
        return pairs.contains { p in
            guard let d = p as? [String: Any] else { return false }
            return (d["DeviceUsagePage"] as? NSNumber)?.intValue == page && (d["DeviceUsage"] as? NSNumber)?.intValue == usage
        }
    }

    /// OMACVM_TOUCH_SCREEN: "1" is with, "0" without, anything else the Mac's own.
    static func forced(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool? {
        switch env["OMACVM_TOUCH_SCREEN"] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    /// A touch display connected now.
    static func connected() -> Bool {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            let pairs = IORegistryEntryCreateCFProperty(s, "DeviceUsagePairs" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            if isTouchScreen(usagePairs: pairs) { return true }
        }
        return false
    }

    /// Does the VM get a touch screen at this start?
    static func wanted(forced: Bool? = TouchDisplay.forced(), connected: () -> Bool = TouchDisplay.connected) -> Bool {
        forced ?? connected()
    }

    /// QEMU's arguments for it.
    static func arguments(on: Bool) -> [String] {
        on ? ["-device", device] : []
    }

    /// This start's qemu.log record.
    static func record(on: Bool, forced: Bool? = TouchDisplay.forced()) -> String {
        switch (on, forced) {
        case (true, nil): return "on (this Mac has a touch display: a pinch's two fingers go to it)"
        case (false, nil): return "off (no touch display on this Mac)"
        case (true, _): return "on (OMACVM_TOUCH_SCREEN=1)"
        case (false, _): return "off (OMACVM_TOUCH_SCREEN=0)"
        }
    }
}
