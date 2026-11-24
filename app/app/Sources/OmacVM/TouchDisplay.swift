import Foundation
import IOKit

/// A touch display on this Mac (the MacBook Pro with the touch screen,
/// macOS 27; #843): a HID device whose DeviceUsagePairs say touch screen
/// (Digitizer page 0x0D, usage 0x04; a trackpad's say touch pad, 0x0D/0x05).
///
/// Experimental and off by default: the settings row "Touch display"
/// (Settings.touchDisplay), shown only on a Mac with one. With it on and a
/// touch display, QEMU's window takes direct touches (OMACVM_TOUCH=1: taps,
/// scrolling, drags, right clicks; omacvm-cocoa-touch.patch) and the VM gets
/// a touch screen (QEMU's virtio-multitouch) for a pinch, whose two fingers
/// the VM's apps zoom between, as macOS does. Off, or without one, the VM is
/// as before: no recognizer, no device (a VM with a touch screen tells its
/// apps so: Chromium reports 10 touch points to web pages).
/// OMACVM_TOUCH_SCREEN=1 or 0 in the app's environment decides it whatever
/// the switch and the Mac say (a Sidecar iPad's touches come the same way; tests).
///
/// The rules on their own (Foundation and IOKit only):
/// src/tests/app-touch-display.sh compiles and tests them without the app.
enum TouchDisplay {
    static let page = 0x0D
    static let usage = 0x04
    static let device = "virtio-multitouch-pci,romfile="
    /// The switch (UserDefaults; Settings.touchDisplay).
    static let key = "touchDisplay"

    /// The row's (i) text.
    static let info = "Experimental. Use the Mac's touch display in the VM: a tap is a click, a touch that moves scrolls (with a flick it coasts), a touch held and then moved drags, one held and lifted is a right click, and a two-finger pinch zooms in apps that know touch screens (Chromium, Firefox, GTK apps). Off: the touch display works as macOS's mouse emulation gives it, as before. Shown only on a Mac with a touch display. Counts from the next start of the VM."

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

    /// Does the VM get a touch screen at this start? The switch and a touch
    /// display, or OMACVM_TOUCH_SCREEN. The display is asked only with the switch on.
    static func wanted(setting: Bool, forced: Bool? = TouchDisplay.forced(), connected: () -> Bool = TouchDisplay.connected) -> Bool {
        forced ?? (setting && connected())
    }

    /// The settings row shows on a Mac with a touch display, and while the
    /// switch is on (so it can be switched off).
    static func shown(setting: Bool, connected: () -> Bool = TouchDisplay.connected) -> Bool {
        setting || connected()
    }

    /// QEMU's arguments for it.
    static func arguments(on: Bool) -> [String] {
        on ? ["-device", device] : []
    }

    /// QEMU's window takes direct touches only with it (OMACVM_TOUCH in its environment).
    static func environment(on: Bool) -> String { on ? "1" : "0" }

    /// This start's qemu.log record.
    static func record(on: Bool, setting: Bool, forced: Bool? = TouchDisplay.forced()) -> String {
        switch (on, forced) {
        case (true, nil): return "on (Touch display, experimental: taps, scrolling and a pinch's two fingers go to the VM)"
        case (false, nil): return setting ? "off (no touch display on this Mac)" : "off (the Touch display switch is off)"
        case (true, _): return "on (OMACVM_TOUCH_SCREEN=1)"
        case (false, _): return "off (OMACVM_TOUCH_SCREEN=0)"
        }
    }
}
