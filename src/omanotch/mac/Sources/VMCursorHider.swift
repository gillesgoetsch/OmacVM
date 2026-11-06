import AppKit

/// Hides the macOS cursor while the pointer is over a full-screen VM window
/// (not OmacVM.app's: QEMU hides it there itself).
///
/// Over its VM windows the VM app normally swaps in a transparent cursor (the
/// guest draws its own), but not every VM app does so reliably when the pointer comes
/// from another app's window, e.g. the notch strip or when crossing to another
/// display through it. The result is a macOS arrow on top of the guest cursor.
/// This hides the cursor outright over those windows and shows it everywhere
/// else. It relies on BackgroundCursor (SetsCursorInBackground).
final class VMCursorHider {
    private let vmOwners: Set<String>
    /// The VM app whose guest feeds the strip; nil while the strip is not in
    /// use. Only that app's full-screen windows hide the cursor: other VMs
    /// (say a Windows VM) draw no guest cursor of their own.
    var activeOwner: String? {
        didSet { if activeOwner != oldValue { refresh() } }
    }
    private let ownOwner: String
    private var monitor: Any?
    private var hidden = false
    /// Full-screen VM windows in CG coordinates (top-left origin), refreshed by poll.
    private var vmRects: [CGRect] = []
    private var lastCheck = CFAbsoluteTime(0)
    private var lastResult = false
    private var wasInVM = false
    private var onStrip = false
    /// Called when the pointer arrives over a full-screen VM window
    /// (CG point, that window's rect).
    var onEnterVM: ((CGPoint, CGRect) -> Void)?

    init(vmOwners: Set<String>, ownOwner: String) {
        self.vmOwners = vmOwners
        self.ownOwner = ownOwner
    }

    func start() {
        guard BackgroundCursor.enabled else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                                               .otherMouseDragged]) { [weak self] _ in
            self?.update()
        }
    }

    /// Refresh the list of full-screen VM windows (cheap; called by the poll timer).
    func refresh() {
        if let owner = activeOwner, vmOwners.contains(owner) {
            vmRects = Self.fullScreenVMWindows(vmOwners: [owner])
        } else {
            vmRects = []
        }
        if vmRects.isEmpty { setHidden(false) }
    }

    /// The pointer is over the strip panel, which shows the guest's cursor
    /// images. Showing is delayed a little so the guest (which hides its own
    /// cursor on the same event) has time to do so: no second cursor.
    func pointerOnStrip(showAfter delay: TimeInterval) {
        onStrip = true
        wasInVM = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.onStrip else { return }
            self.setHidden(false)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        setHidden(false)
    }

    private func update() {
        onStrip = false  // global events never come from the strip (our own window)
        let p = Self.cgMouseLocation()
        guard let rect = vmRects.first(where: { $0.contains(p) }) else {
            wasInVM = false
            setHidden(false)
            return
        }
        // Something else may be on top of the VM (Notification Center, a
        // popover, Spotlight): only hide when the VM window is what is under
        // the pointer. The window list is sampled at most every 100 ms.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastCheck > 0.1 {
            lastCheck = now
            lastResult = topWindowIsVM(at: p)
        }
        // OmacVM.app hides the Mac's cursor over its VM itself, at once (QEMU's
        // grab); hiding it here too only lagged behind (the 100 ms sample above,
        // the strip's 45 ms delay): no cursor for a moment at the strip's edge.
        setHidden(lastResult && activeOwner != OmacVMApp.owner)
        if lastResult && !wasInVM { onEnterVM?(p, rect) }
        wasInVM = lastResult
    }

    private func setHidden(_ h: Bool) {
        guard h != hidden else { return }
        hidden = h
        if h {
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    private func topWindowIsVM(at p: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 1000,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict), r.contains(p)
            else { continue }
            let owner = OmacVMApp.ownerName(w)
            if owner == ownOwner { return false }
            return owner == activeOwner && layer == 0
        }
        return false
    }

    static func cgMouseLocation() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Normal-layer VM windows that fill (at least 90 % of) a display's height,
    /// full width, reaching its bottom edge: the VM's full-screen windows.
    static func fullScreenVMWindows(vmOwners: Set<String>) -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let displays = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var out: [CGRect] = []
        for w in list {
            guard let owner = OmacVMApp.ownerName(w), vmOwners.contains(owner),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict)
            else { continue }
            if displays.contains(where: { d in
                r.minX == d.minX && r.width == d.width && r.maxY == d.maxY && r.height >= d.height * 0.9
            }) {
                out.append(r)
            }
        }
        return out
    }
}
