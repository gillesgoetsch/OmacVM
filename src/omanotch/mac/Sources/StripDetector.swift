import AppKit

/// Where the notch strip is, when the VM is full screen on the built-in display.
struct StripGeometry: Equatable {
    /// Panel frame in Cocoa screen coordinates (origin bottom-left).
    var frame: NSRect
    /// Camera housing, as x offsets from the left edge of the display.
    var notchLeft: CGFloat
    var notchRight: CGFloat
    /// The camera housing's height (the display's top safe-area inset), in
    /// points; a little less than the strip (the menu bar's height).
    var notchHeight: CGFloat
    /// The VM's full-screen window on the built-in display.
    var windowID: CGWindowID
    /// App that owns it ("Parallels Desktop", "UTM").
    var owner: String
}

/// Finds the notch strip above a full-screen VM window using public APIs only.
///
/// The VM counts as full screen on the built-in display when a normal-layer
/// window of the VM app spans the display's full width, reaches its bottom
/// edge and covers at least 90 % of its height. The strip is the gap between
/// the top of the display and the top of that window (the menu bar height:
/// 43 pt on a 16-inch MacBook Pro at "More Space", less on smaller models).
enum StripDetector {
    static func builtinScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(n.uint32Value) != 0
        }
    }

    /// `onScreenOnly: false` also finds the VM's full-screen window while its
    /// Space is not the active one.
    static func detect(vmOwners: Set<String>, onScreenOnly: Bool = true) -> StripGeometry? {
        guard let screen = builtinScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        let display = CGDisplayBounds(number.uint32Value)  // top-left origin
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements]
                                                       : [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard let owner = OmacVMApp.ownerName(w), vmOwners.contains(owner),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict)
            else { continue }
            guard r.minX == display.minX, r.width == display.width, r.maxY == display.maxY,
                  r.height >= display.height * 0.9, r.minY > display.minY
            else { continue }
            let height = r.minY - display.minY
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                               width: screen.frame.width, height: height)
            return StripGeometry(frame: frame,
                                 notchLeft: left.maxX - screen.frame.minX,
                                 notchRight: right.minX - screen.frame.minX,
                                 notchHeight: screen.safeAreaInsets.top,
                                 windowID: CGWindowID((w[kCGWindowNumber as String] as? Int) ?? 0),
                                 owner: owner)
        }
        return nil
    }

    /// Whether the window is still the VM's full-screen window on the built-in
    /// display below a strip of `stripHeight`, wherever its Space currently is.
    /// Only its size is compared: the origin moves while a Space slides in or
    /// out. (A window that grew into the notch area no longer leaves a strip.)
    static func stillFullScreen(_ id: CGWindowID, stripHeight: CGFloat) -> Bool {
        guard let screen = builtinScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict)
        else { return false }
        let display = CGDisplayBounds(number.uint32Value)
        return abs(r.width - display.width) < 1 && abs(r.height - (display.height - stripHeight)) <= 1
    }
}
