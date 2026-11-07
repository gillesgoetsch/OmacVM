// Print "notch" if this Mac's built-in display has a camera notch, else "none".
// build.sh offers Omanotch (Omarchy's bar beside the notch) only where it fits.
// With the argument "builtin" (src/lib/notch.sh's notch_mac_state, #716): "notch"
// (a notch now), "off" (no built-in display online in CoreGraphics: a MacBook
// with its lid closed, a Mac without one) or "none" (the built-in display on
// without a notch now: below the notch, or mirrored), as the app's Mac.notch.
import AppKit
let builtin = NSScreen.screens.first { s in
  (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
}
if CommandLine.arguments.dropFirst().first == "builtin" {
  if let b = builtin, b.auxiliaryTopLeftArea != nil, b.safeAreaInsets.top > 0 {
    print("notch")
  } else {
    var n: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    let online = CGGetOnlineDisplayList(32, &ids, &n) == .success
    print(online && !ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) != 0 } ? "off" : "none")
  }
} else {
  print(builtin?.auxiliaryTopLeftArea != nil ? "notch" : "none")
}
