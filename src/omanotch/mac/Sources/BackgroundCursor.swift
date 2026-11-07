import AppKit

/// Cursor control for an app that is never frontmost.
///
/// macOS normally ignores cursor changes from background apps. The window
/// server connection property "SetsCursorInBackground" lifts that; it is not
/// public API but has been stable for many macOS releases and is used by
/// common utilities. If it is unavailable, cursor changes simply do nothing.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static let enabled: Bool = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let c = dlsym(handle, "_CGSDefaultConnection"), let s = dlsym(handle, "CGSSetConnectionProperty") else {
            Log.info("background cursor control unavailable")
            return false
        }
        let cid = unsafeBitCast(c, to: DefaultConnection.self)()
        let err = unsafeBitCast(s, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        if err != 0 { Log.info("SetsCursorInBackground failed: \(err)") }
        return err == 0
    }()

    /// Fully transparent cursor: what a VM app shows over its VM windows,
    /// where the guest draws its own cursor.
    static let transparent: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()
}
