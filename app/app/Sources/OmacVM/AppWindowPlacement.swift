import AppKit

extension NSWindow {
    /// The app's own window: centred on the built-in display, else the main
    /// one (WindowPlacement.appScreen). Not NSWindow.center(): that picks the
    /// active menu bar's display (the external one, often) and sits above the
    /// middle. The app sets no frame autosave name and no restoration, so
    /// nothing brings back an old place on another display.
    /// Main thread. src/tests/app-window-real.sh runs it on real displays.
    func centreOnAppScreen() {
        func id(_ s: NSScreen) -> UInt32? {
            s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        let screens = NSScreen.screens.compactMap { s in id(s).map { WindowPlacement.Screen(id: $0, frame: s.visibleFrame) } }
        let builtIn = screens.first { CGDisplayIsBuiltin($0.id) != 0 }?.id
        guard let s = WindowPlacement.appScreen(screens: screens, builtIn: builtIn, main: NSScreen.main.flatMap(id)) else { return }
        // SwiftUI sizes the window from its content: lay it out first.
        contentView?.layoutSubtreeIfNeeded()
        var size = frame.size
        if size.width < 1 || size.height < 1, let v = contentView {
            size = frameRect(forContentRect: NSRect(origin: .zero, size: v.fittingSize)).size
        }
        setFrameOrigin(WindowPlacement.centred(size, in: s.frame))
    }
}

/// Keeps the app's window centred while SwiftUI sizes it (AppKit grows it
/// from the top left corner, so a taller screen would hang below the middle),
/// until the user moves it. Main thread.
@MainActor
final class CentredWindow {
    private weak var window: NSWindow?
    private var placed: CGPoint?   // top left corner after the last placement
    private var observers: [NSObjectProtocol] = []
    /// Not yet placed, or closed / taken off screen by the app since: the next
    /// open centres it again. Not set by hiding the app (Cmd-H) or by another
    /// Space, so a window the user moved stays where it is then.
    private(set) var needsPlace = true

    init(_ w: NSWindow) {
        window = w
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resized() }
        })
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.taken() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Centred on the built-in display, else the main one.
    func place() {
        guard let w = window else { return }
        w.centreOnAppScreen()
        placed = Self.topLeft(w)
        needsPlace = false
    }

    /// Closed, or ordered out by the app (a VM started): centre it again on
    /// the next open.
    func taken() {
        needsPlace = true
        placed = nil
    }

    private func resized() {
        guard let w = window, let p = placed else { return }
        // Moved by the user (or grown from another corner): leave it there.
        if Self.topLeft(w) != p { placed = nil; return }
        guard w.isVisible else { return }
        // On the display it is on: a display added since (lid opened, a
        // monitor plugged in) does not pull an open window across.
        if let s = w.screen {
            w.setFrameOrigin(WindowPlacement.centred(w.frame.size, in: s.visibleFrame))
            placed = Self.topLeft(w)
        } else {
            place()
        }
    }

    private static func topLeft(_ w: NSWindow) -> CGPoint { CGPoint(x: w.frame.minX, y: w.frame.maxY) }
}
