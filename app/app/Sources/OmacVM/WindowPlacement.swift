import CoreGraphics

/// Where a VM's window opens: on the display the user is using, the one under
/// the pointer, else the one with the active menu bar (where the Start button
/// was clicked). With one display there is nothing to choose: QEMU's own
/// frame. QEMU puts its main window on the display it is given and keeps it
/// there (full screen goes to that display too).
///
/// The app's own window (start, options, setup) opens centred on the Mac's
/// built-in display; with the lid closed or on a Mac without one (Mac mini,
/// Studio), on the main display.
///
/// Core Graphics only: src/tests/app-escape-window.sh tests it without the app.
enum WindowPlacement {
    struct Screen: Equatable {
        let id: UInt32
        let frame: CGRect   // AppKit's coordinates, as NSScreen and NSEvent.mouseLocation give them
    }

    static func display(pointer: CGPoint, screens: [Screen], menuBar: UInt32?) -> UInt32? {
        guard screens.count > 1 else { return nil }
        if let s = screens.first(where: { $0.frame.contains(pointer) }) { return s.id }
        return screens.contains { $0.id == menuBar } ? menuBar : nil
    }

    /// The display for the app's own window: the built-in one if it is on
    /// (not with the lid closed: then macOS does not list it), else the main
    /// one (the active menu bar's), else the first. Screen frames here are the
    /// visible frames (no menu bar, no Dock).
    static func appScreen(screens: [Screen], builtIn: UInt32?, main: UInt32?) -> Screen? {
        if let s = screens.first(where: { $0.id == builtIn }) { return s }
        if let s = screens.first(where: { $0.id == main }) { return s }
        return screens.first
    }

    /// The window's origin (bottom left, AppKit) centred in `visible`; a window
    /// taller or wider than that keeps its top left corner on the display, so
    /// the title bar can always be reached.
    static func centred(_ size: CGSize, in visible: CGRect) -> CGPoint {
        let x = size.width < visible.width ? visible.midX - size.width / 2 : visible.minX
        let y = size.height < visible.height ? visible.midY - size.height / 2 : visible.maxY - size.height
        return CGPoint(x: x.rounded(), y: y.rounded())
    }
}
