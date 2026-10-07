import Foundation
import IOKit

/// "Magic Mouse swipe": a two-finger sideways swipe on a Magic Mouse is this
/// many fingers on the VM's trackpad, 3 or 4 (4 by default: Omarchy switches
/// workspaces with 4). OmacVM Gestures reads it from its own settings domain
/// at the start of each swipe, so a change counts at once; `defaults write
/// org.omacvm.gestures MouseSwipeFingers -int 3` sets it too.
///
/// The rules on their own (Foundation and IOKit only):
/// src/tests/app-mouse-swipe.sh compiles and tests them without the app.
enum MouseSwipeSetting {
    static let key = "MouseSwipeFingers"
    static let choices = [3, 4]
    static let hint = "What a two-finger swipe on the mouse does in the VM: the same as this many fingers on a trackpad. Omarchy switches workspaces with 4."

    /// What Gestures does with a stored value: 3 (number or text) is 3,
    /// anything else (not set, 5, "three", 3.5) is 4.
    static func fingers(stored: Any?) -> Int {
        if let s = stored as? String { return s == "3" ? 3 : 4 }
        if let n = stored as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID() { return n.doubleValue == 3 ? 3 : 4 }
        return 4
    }

    static func current(_ d: UserDefaults? = UserDefaults(suiteName: EscapeSetting.appDomain)) -> Int {
        fingers(stored: d?.object(forKey: key))
    }

    static func set(_ n: Int, _ d: UserDefaults? = UserDefaults(suiteName: EscapeSetting.appDomain)) {
        d?.set(n == 3 ? 3 : 4, forKey: key)
    }
}

/// A Magic Mouse connected now (Bluetooth or USB), found as Gestures finds
/// it: Apple's multitouch family 112, or an Apple product id 0x030d (Magic
/// Mouse), 0x0269 (Magic Mouse 2), 0x0323 (Magic Mouse, USB-C).
enum MagicMouse {
    static let products: Set<Int> = [0x030d, 0x0269, 0x0323]
    static let family = 112
    /// Apple's vendor ids: Bluetooth (0x004c) and USB (0x05ac).
    static let vendors: Set<Int> = [0x004c, 0x05ac]

    /// Tests set it to draw the window with or without a mouse.
    nonisolated(unsafe) static var override: Bool?

    static func isMagicMouse(vendor: Int?, product: Int?, family: Int?) -> Bool {
        if family == Self.family { return true }
        guard let p = product, products.contains(p), let v = vendor else { return false }
        return vendors.contains(v)
    }

    static func connected() -> Bool {
        if let o = override { return o }
        for cls in ["AppleMultitouchDevice", "IOHIDDevice"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            while true {
                let s = IOIteratorNext(it)
                if s == 0 { break }
                defer { IOObjectRelease(s) }
                func num(_ k: String) -> Int? {
                    (IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                }
                if isMagicMouse(vendor: num("VendorID"), product: num("ProductID"), family: num("Family ID")) { return true }
            }
        }
        return false
    }
}
