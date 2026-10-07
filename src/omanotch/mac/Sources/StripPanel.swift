import AppKit
import QuartzCore

/// Borderless panel over the notch strip. It never becomes key or main, so the
/// VM keeps keyboard focus when the strip is clicked.
final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Parallels and UTM keep an invisible window over the strip at level 26 and the
        // menu bar sits at 24, so the panel must be at 27 or above.
        level = NSWindow.Level(27)
        // Belongs to the Space it is first shown on (the VM's full-screen
        // Space), so it slides in and out with the VM when switching Spaces.
        // .moveToActiveSpace: when (re)shown it joins the Space that is active
        // then, even if the VM's full-screen Space was recreated meanwhile.
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle, .fullScreenDisallowsTiling]
    }
}

/// Input from the strip, in bar coordinates (logical guest px == macOS points).
protocol StripInputDelegate: AnyObject {
    func stripClicked(x: CGFloat, y: CGFloat, button: Int)
    func stripScrolled(x: CGFloat, y: CGFloat, steps: Int)
    /// `exit`: where the pointer left the strip ("down" into the built-in
    /// display, "up" towards the display above) and at which x, if known.
    func stripHoverChanged(_ inside: Bool, exit: (direction: String, x: CGFloat)?)
}

/// Draws the mirrored bar and turns mouse events into bar coordinates.
final class StripView: NSView {
    weak var input: StripInputDelegate?
    private let barLayer = CALayer()
    /// Size of the bar image in guest logical px (the NOTCH output's size).
    private var barHeight: CGFloat = 26
    private var barWidth: CGFloat = 0
    /// Guest logical px per strip point: 1 when the guest display matches the
    /// Mac point for point (Parallels "Retina", UTM "Retina Mode" + resize to
    /// window), anything else when it does not. The image is always drawn
    /// across the full strip width and input is converted with this.
    private(set) var guestPerPoint: CGFloat = 1
    /// Called when guestPerPoint changes.
    var onGuestScaleChange: (() -> Void)?
    /// Guest logical px per point as drawn: guestPerPoint, or more when the
    /// bar is taller than the strip allows (then it is fitted, not cut off).
    private var drawScale: CGFloat = 1
    /// Where the drawn image sits inside the strip, in points.
    private var drawTop: CGFloat = 0
    private var drawLeft: CGFloat = 0
    private var imagePixelWidth: CGFloat = 0
    /// Clickable rectangles in bar coordinates, reported by the guest.
    var targets: [CGRect] = []
    /// The guest's cursors, so the strip shows the same cursor as the VM.
    var arrowCursor: NSCursor = .arrow
    var pointerCursor: NSCursor = .pointingHand
    private(set) var isHovered = false
    private var scrollAccumulator: CGFloat = 0
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        barLayer.contentsGravity = .resize
        barLayer.magnificationFilter = .nearest
        barLayer.minificationFilter = .linear
        barLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(barLayer)
        lockLayer.backgroundColor = NSColor.black.cgColor
        lockLayer.isHidden = true
        lockLayer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(lockLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    var hasImage: Bool { barLayer.contents != nil }

    /// The guest's session is locked: a plain black strip, no input. (The
    /// guest sends no frames meanwhile: its lock screen covers every output,
    /// the hidden one too, password field included.)
    private let lockLayer = CALayer()
    var locked = false {
        didSet {
            guard locked != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lockLayer.isHidden = !locked
            CATransaction.commit()
            if locked { arrowCursor.set() }
        }
    }

    /// Shows a new bar image. `scale` is the guest output scale.
    func show(image: CGImage, scale: CGFloat, background: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barWidth = CGFloat(image.width) / scale
        barHeight = CGFloat(image.height) / scale
        barLayer.contents = image
        barLayer.contentsScale = scale
        imagePixelWidth = CGFloat(image.width)
        if let background { layer?.backgroundColor = background }
        layoutBar()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutBar()
        CATransaction.commit()
    }

    private func layoutBar() {
        let k = barWidth > 0 && bounds.width > 0 ? barWidth / bounds.width : 1
        if abs(k - guestPerPoint) > 0.001 {
            guestPerPoint = k
            DispatchQueue.main.async { [weak self] in self?.onGuestScaleChange?() }
        }
        let place = StripLayout.place(barWidth: barWidth, barHeight: barHeight,
                                      width: bounds.width, height: bounds.height)
        drawScale = place.scale
        drawLeft = place.left
        drawTop = place.top
        let w = barWidth > 0 ? barWidth / drawScale : bounds.width
        let h = barHeight / drawScale
        // Layer geometry is bottom-left based even in a flipped view.
        barLayer.frame = CGRect(x: drawLeft, y: bounds.height - drawTop - h, width: w, height: h)
        lockLayer.frame = bounds
        // Pixel-exact when the guest renders at the Mac's backing scale,
        // smooth when the image has to be resampled.
        let backing = window?.backingScaleFactor ?? 2
        let exact = w > 0 && abs(imagePixelWidth / w - backing) < 0.01
        barLayer.magnificationFilter = exact ? .nearest : .linear
        barLayer.minificationFilter = exact ? .nearest : .trilinear
    }

    // MARK: input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited,
                                                          .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Pointer position in bar coordinates (guest logical px).
    private func barPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let y = min(max((p.y - drawTop) * drawScale, 0.5), barHeight - 0.5)
        return CGPoint(x: (p.x - drawLeft) * drawScale, y: y)
    }

    private func updateCursor(_ event: NSEvent) {
        guard !locked else { arrowCursor.set(); return }
        let p = barPoint(event)
        if targets.contains(where: { $0.contains(p) }) {
            pointerCursor.set()
        } else {
            arrowCursor.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        input?.stripHoverChanged(true, exit: nil)
        updateCursor(event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        let p = convert(event.locationInWindow, from: nil)  // flipped: y grows downwards
        let direction = p.y >= bounds.height / 2 ? "down" : "up"
        input?.stripHoverChanged(false, exit: (direction, min(max(p.x, 0), bounds.width - 1) * guestPerPoint))
        // (guestPerPoint, not drawScale: that x is a position on the VM display.)
        // Leaving into a VM window: show nothing, like the VM app does there
        // (the guest draws its own cursor). Parallels does not reliably reset
        // the cursor when the pointer comes from another app's window, which
        // would leave a macOS arrow on top of the guest cursor.
        // Down: the strip is only shown right on top of the VM's full-screen
        // window (StripDetector), so that is where the pointer is now. The
        // window list is not asked: in macOS's full screen its (hidden) menu
        // bar window covers the strip and, with the 2-point slack, the first
        // row below it, so the test said "not the VM" and a macOS arrow stayed
        // over the guest's own cursor until the VM app reset it.
        // (Only straight down out of the strip's bottom edge: sideways may be
        // another display that shows macOS.)
        let straightDown = p.y >= bounds.height - 1 && p.x >= 0 && p.x < bounds.width
        if straightDown, activeOwner != nil {
            BackgroundCursor.transparent.set()
        } else if let screenPoint = window?.convertPoint(toScreen: event.locationInWindow),
           let owner = activeOwner, StripView.isOverVMWindow(screenPoint, vmOwners: [owner]) {
            BackgroundCursor.transparent.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Owner names of the VM windows (set by the controller).
    var vmOwners: Set<String> = ["Parallels Desktop", "UTM", "VMware Fusion", OmacVMApp.owner]
    /// The VM app whose guest feeds the strip (it draws its own cursor).
    var activeOwner: String?

    /// Whether a point just outside the strip (Cocoa screen coordinates) lies
    /// on a normal-layer window of the VM app.
    static func isOverVMWindow(_ cocoaPoint: NSPoint, vmOwners: Set<String>) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let cg = CGPoint(x: cocoaPoint.x, y: primary.frame.maxY - cocoaPoint.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 1000,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict), r.insetBy(dx: 0, dy: -2).contains(cg)
            else { continue }
            if (w[kCGWindowAlpha as String] as? Double ?? 1) == 0 { continue }
            if w[kCGWindowOwnerName as String] as? String == "Omanotch" { continue }
            return vmOwners.contains(OmacVMApp.ownerName(w) ?? "") && layer == 0
        }
        return false
    }

    /// Called when the panel hides while the pointer may still be over it.
    func resetHover() {
        guard isHovered else { return }
        isHovered = false
        input?.stripHoverChanged(false, exit: nil)
    }

    override func mouseDown(with event: NSEvent) { click(event, button: 1) }
    override func rightMouseDown(with event: NSEvent) { click(event, button: 2) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { click(event, button: 3) }
    }

    private func click(_ event: NSEvent, button: Int) {
        guard !locked else { return }
        let p = barPoint(event)
        input?.stripClicked(x: p.x, y: p.y, button: button)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !locked else { return }
        // Convert to physical wheel direction (positive = away from the user),
        // which is what Qt's angleDelta uses, regardless of natural scrolling.
        var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dy = -dy }
        if event.phase == .began || event.phase == .mayBegin { scrollAccumulator = 0 }
        let stepSize: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 1
        scrollAccumulator += dy
        let steps = Int((scrollAccumulator / stepSize).rounded(.towardZero))
        if steps != 0 {
            scrollAccumulator -= CGFloat(steps) * stepSize
            let p = barPoint(event)
            input?.stripScrolled(x: p.x, y: p.y, steps: steps)
        }
    }
}
