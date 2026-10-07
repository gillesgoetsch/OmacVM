// What macOS's Spaces show, for the full-screen Space check
// (src/tests/fullscreen-space-vm.sh). Private SkyLight calls, read only,
// except `left`, which does what OmacVM Gestures does for the escape combo:
// macOS's "Move left a space" shortcut, marked as Gestures marks it, on the
// display under the pointer (the pointer goes there and back).
//   spaces state DISPLAY PID   current Space of DISPLAY: id, type (4 = full
//                              screen), PID's windows on it, other apps' windows on it
//   spaces watch DISPLAY SECS  the display's current Space every 50 ms, on change
//   spaces left DISPLAY        the escape combo's move (Ctrl+Left, marked)
import ColorSync
import CoreGraphics
import Foundation

typealias ConnFn = @convention(c) () -> Int32
typealias DisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias WindowSpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
func sym<T>(_ n: String, _ t: T.Type) -> T { unsafeBitCast(dlsym(h, n)!, to: t) }
let cid = sym("SLSMainConnectionID", ConnFn.self)()
let displaySpaces = sym("SLSCopyManagedDisplaySpaces", DisplaySpacesFn.self)
let windowSpaces = sym("SLSCopySpacesForWindows", WindowSpacesFn.self)

func uuid(_ d: CGDirectDisplayID) -> String {
    guard let u = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue() else { return "" }
    return CFUUIDCreateString(nil, u) as String
}

/// The display's current Space: (id, type), (0, -1) if unknown.
func current(_ d: CGDirectDisplayID) -> (UInt64, Int) {
    let want = uuid(d)
    guard let list = displaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return (0, -1) }
    for e in list where (e["Display Identifier"] as? String)?.caseInsensitiveCompare(want) == .orderedSame {
        if let c = e["Current Space"] as? [String: Any] {
            return ((c["id64"] as? NSNumber)?.uint64Value ?? 0, (c["type"] as? NSNumber)?.intValue ?? -1)
        }
    }
    return (0, -1)
}

func spacesOf(_ w: CGWindowID) -> [UInt64] {
    guard let r = windowSpaces(cid, 7, [NSNumber(value: w)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
    return r.map { $0.uint64Value }
}

let a = CommandLine.arguments
guard a.count >= 3, let d = CGDirectDisplayID(a[2]) else {
    print("usage: spaces state DISPLAY PID | watch DISPLAY SECS | left DISPLAY"); exit(2)
}
switch a[1] {
case "state":
    let pid = Int(a.count > 3 ? a[3] : "0") ?? 0
    let (space, type) = current(d)
    var mine = 0, others: [String] = []
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let n = w[kCGWindowNumber as String] as? Int, spacesOf(CGWindowID(n)).contains(space) else { continue }
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        if (w[kCGWindowOwnerPID as String] as? Int) == pid { mine += 1 }
        else if alpha > 0 { others.append("\(w[kCGWindowOwnerName as String] ?? "?")#\(n)") }
    }
    print("space=\(space) type=\(type) vm_windows=\(mine) others=\(others.count) \(others.joined(separator: ","))")
case "watch":
    let end = Date().addingTimeInterval(Double(a.count > 3 ? a[3] : "3") ?? 3)
    var last: UInt64 = 1
    let t0 = Date()
    while Date() < end {
        let (s, t) = current(d)
        if s != last { print(String(format: "%.2f", Date().timeIntervalSince(t0)), "space=\(s) type=\(t)"); last = s }
        fflush(stdout)
        usleep(50_000)
    }
case "left":
    // As OmacVM Gestures posts it: macOS's default "Move left a space"
    // (Ctrl+Left; arrows carry fn + keypad), at the HID tap, marked so
    // OmacVM's QEMU lets it through to macOS.
    let marker: Int64 = 0x0BAC0E5C
    let back = CGEvent(source: nil)?.location ?? .zero
    let b = CGDisplayBounds(d)
    CGWarpMouseCursorPosition(CGPoint(x: b.midX, y: b.midY))
    usleep(80_000)
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: 123, keyDown: down) else { exit(1) }
        e.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
        usleep(20_000)
    }
    usleep(80_000)
    CGWarpMouseCursorPosition(back)
    CGAssociateMouseAndMouseCursorPosition(1)
    print("posted Ctrl+Left on display \(d)")
default:
    print("unknown command \(a[1])"); exit(2)
}
