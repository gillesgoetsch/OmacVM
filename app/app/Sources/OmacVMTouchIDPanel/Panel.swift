// Touch ID's panel (docs/adr/0041-touch-id.md): a 280 pt square in the VM's
// Omarchy theme with the fingerprint glyph and Apple's embedded Touch ID
// view, shown by QEMU (the VM window's process: macOS reads the finger only
// for the app in front). All of it runs on the main thread.
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import OmacVMAuth
import QuartzCore

extension PanelRGB {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum PanelFonts {
    /// JetBrains Mono from the app (Contents/Resources/fonts; OFL 1.1), once.
    static let registered: Bool = {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let p = info.dli_fname else { return false }
        // .../Contents/Resources/runtime/lib/OmacVMTouchIDPanel.dylib -> .../Contents/Resources/fonts
        let fonts = URL(fileURLWithPath: String(cString: p)).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fonts")
        var any = false
        for f in ["JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf"] {
            let u = fonts.appendingPathComponent(f) as CFURL
            if CTFontManagerRegisterFontsForURL(u, .process, nil) { any = true }
        }
        return any
    }()

    static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
        _ = registered
        return NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
}

enum PanelMetrics {
    static let side: CGFloat = 280
    static let padding: CGFloat = 20
    static let gap: CGFloat = 7
    static let glyph = CGSize(width: 64, height: 70)
    static let button: CGFloat = 40
}

/// The glyph: five ridges, the check, and their animations.
final class PanelGlyphView: NSView {
    private let ridges = CALayer()
    private var paths: [CAShapeLayer] = []
    private let check = CAShapeLayer()
    private let theme: PanelTheme
    private let reduceMotion: Bool

    init(theme: PanelTheme, reduceMotion: Bool) {
        self.theme = theme
        self.reduceMotion = reduceMotion
        super.init(frame: CGRect(origin: .zero, size: PanelMetrics.glyph))
        wantsLayer = true
        layer?.backgroundColor = theme.background.cg   // covers Apple's view beneath it
        var t = PanelGlyph.transform(into: PanelMetrics.glyph)
        let width = PanelGlyph.strokeWidth * t.a
        ridges.frame = bounds
        layer?.addSublayer(ridges)
        for d in PanelGlyph.ridges {
            guard let p = PanelGlyph.path(d)?.copy(using: &t) else { continue }
            let s = CAShapeLayer()
            s.frame = bounds
            s.path = p
            s.fillColor = nil
            s.lineWidth = width
            s.lineCap = .round
            s.lineJoin = .round
            s.strokeColor = theme.foreground.cg
            paths.append(s)
            ridges.addSublayer(s)
        }
        if let p = PanelGlyph.path(PanelGlyph.check)?.copy(using: &t) {
            check.frame = bounds
            check.path = p
            check.fillColor = nil
            check.lineWidth = width * 34 / 30
            check.lineCap = .round
            check.lineJoin = .round
            check.strokeColor = theme.success.cg
            check.strokeEnd = 0
            layer?.addSublayer(check)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { PanelMetrics.glyph }

    func show(_ look: PanelLook) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ridges.removeAllAnimations()
        for s in paths + [check] { s.removeAllAnimations() }
        switch look {
        case .idle:
            ridges.opacity = 1
            check.strokeEnd = 0
            for s in paths { s.strokeColor = theme.foreground.cg }
            if !reduceMotion {
                let a = CAKeyframeAnimation(keyPath: "opacity")
                a.values = [1, 0.72, 1]
                a.duration = 2.6
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ridges.add(a, forKey: "breathe")
            }
        case .done:
            // The end at once: the yes is already with the VM.
            ridges.opacity = 0
            check.strokeEnd = 1
        case .refused:
            for (i, s) in paths.enumerated() {
                s.strokeColor = theme.error.cg
                guard !reduceMotion else { continue }
                let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
                let d = 14 * PanelGlyph.transform(into: PanelMetrics.glyph).a * (i % 2 == 0 ? -1 : 1)
                a.values = [0, d, 0]
                a.keyTimes = [0, 0.4, 1]
                a.duration = 0.32
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                s.add(a, forKey: "jolt")
            }
        }
        CATransaction.commit()
    }
}

/// The panel's content: title, who asks, the command, the glyph over
/// Apple's view, the state line, Cancel; framed as Omarchy frames its own
/// prompt (the theme's border and rounding; the error colour on a refusal).
final class PanelView: NSView {
    let glyph: PanelGlyphView
    private let message = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()            // the border's shape (and its colour when it has one)
    private let gradient = CAGradientLayer()     // Hyprland's two colours, through `ring`
    private let theme: PanelTheme
    private let reduceMotion: Bool
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)

    static var boxFont: NSFont { PanelFonts.mono(13) }

    /// The command or action fits the box's two lines whole.
    static func boxFits(_ s: String) -> Bool {
        let font = boxFont
        let r = (s as NSString).boundingRect(with: CGSize(width: PanelMetrics.side - 2 * PanelMetrics.padding, height: 1000),
                                             options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return r.height <= font.boundingRectForFont.height * 2 + 2
    }

    init(prompt: TouchIDPanelPrompt, theme: PanelTheme, authView: NSView?, reduceMotion: Bool) {
        self.theme = theme
        self.reduceMotion = reduceMotion
        glyph = PanelGlyphView(theme: theme, reduceMotion: reduceMotion)
        super.init(frame: CGRect(x: 0, y: 0, width: PanelMetrics.side, height: PanelMetrics.side))
        wantsLayer = true
        layer?.backgroundColor = theme.background.cg
        layer?.cornerRadius = theme.radius
        layer?.masksToBounds = true
        appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
        frameBorder()

        let inner = PanelMetrics.side - 2 * PanelMetrics.padding
        func label(_ s: String, _ font: NSFont, _ color: PanelRGB, lines: Int = 1) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = font
            l.textColor = color.ns
            l.alignment = .center
            l.maximumNumberOfLines = lines
            l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byCharWrapping
            l.preferredMaxLayoutWidth = inner
            return l
        }
        let title = label(prompt.title, PanelFonts.mono(14, bold: true), theme.foreground)
        let line = label(prompt.line, PanelFonts.mono(12), theme.dim)
        var views: [NSView] = [title, line]
        if let box = prompt.box {
            // Whole (PanelController.show sends a longer one to macOS's dialog).
            views.append(label(panelFit(box, fits: PanelView.boxFits), PanelView.boxFont, theme.accent, lines: 2))
        }
        // Apple's view under the glyph: it drives the LAContext; the glyph is what shows.
        let well = NSView(frame: CGRect(origin: .zero, size: PanelMetrics.glyph))
        well.translatesAutoresizingMaskIntoConstraints = false
        if let a = authView {
            a.frame = CGRect(x: (PanelMetrics.glyph.width - 64) / 2, y: (PanelMetrics.glyph.height - 64) / 2, width: 64, height: 64)
            well.addSubview(a)
        }
        glyph.frame = well.bounds
        well.addSubview(glyph)
        NSLayoutConstraint.activate([well.widthAnchor.constraint(equalToConstant: PanelMetrics.glyph.width),
                                     well.heightAnchor.constraint(equalToConstant: PanelMetrics.glyph.height)])
        views.append(well)
        message.font = PanelFonts.mono(12)
        message.textColor = theme.dim.ns
        message.alignment = .center
        views.append(message)

        // An Omarchy control: a faint fill, the text colour's border.
        cancel.isBordered = false
        cancel.wantsLayer = true
        cancel.layer?.backgroundColor = theme.controlFill.cg
        cancel.layer?.borderColor = theme.controlBorder.cg
        cancel.layer?.borderWidth = 1
        cancel.layer?.cornerRadius = theme.radius / 2
        cancel.attributedTitle = NSAttributedString(string: "Cancel", attributes: [
            .font: PanelFonts.mono(13, bold: true), .foregroundColor: theme.foreground.ns])
        cancel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([cancel.widthAnchor.constraint(equalToConstant: inner),
                                     cancel.heightAnchor.constraint(equalToConstant: PanelMetrics.button)])
        views.append(cancel)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = PanelMetrics.gap
        stack.setCustomSpacing(PanelMetrics.gap + 3, after: well)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     stack.widthAnchor.constraint(equalToConstant: inner)])
        show(.idle)
    }

    required init?(coder: NSCoder) { nil }

    /// The border over everything, inside the card's rounded edge.
    private func frameBorder() {
        guard let l = layer else { return }
        let w = PanelTheme.borderWidth, r = max(CGFloat(theme.radius) - w / 2, 0)
        let shape = CGPath(roundedRect: bounds.insetBy(dx: w / 2, dy: w / 2), cornerWidth: r, cornerHeight: r, transform: nil)
        ring.frame = bounds
        ring.path = shape
        ring.fillColor = nil
        ring.lineWidth = w
        ring.strokeColor = theme.border[0].cg
        ring.zPosition = 10
        if theme.border.count == 2 {
            gradient.frame = bounds
            gradient.colors = theme.border.map(\.cg)
            (gradient.startPoint, gradient.endPoint) = panelGradientEnds(angle: theme.borderAngle)
            gradient.mask = ring
            gradient.zPosition = 10
            l.addSublayer(gradient)
        } else {
            l.addSublayer(ring)
        }
    }

    func show(_ look: PanelLook, lockout: Bool = false) {
        glyph.show(look)
        switch look {
        case .idle: message.stringValue = "Touch ID or Esc"; message.textColor = theme.dim.ns
        case .done: message.stringValue = "Done"; message.textColor = theme.success.ns
        case .refused:
            message.stringValue = lockout ? "Touch ID is locked" : "Not recognized"
            message.textColor = theme.error.ns
            // Omarchy's prompt turns its border the error colour.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if gradient.superlayer != nil { gradient.removeFromSuperlayer(); gradient.mask = nil; layer?.addSublayer(ring) }
            ring.strokeColor = theme.error.cg
            CATransaction.commit()
            if !reduceMotion, let l = layer {
                let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
                a.values = [0, -8, 7, -5, 3, 0]
                a.duration = 0.42
                a.timingFunction = CAMediaTimingFunction(controlPoints: 0.36, 0.07, 0.19, 0.97)
                l.add(a, forKey: "shake")
            }
        }
    }

    /// The panel as a PNG, drawn off screen (tests, docs): in a window that
    /// is never ordered in.
    func png(scale: CGFloat = 2) -> Data? {
        let host = window == nil ? NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: true) : nil
        if let host { host.contentView = self }
        defer { if host != nil { removeFromSuperview() } }
        layoutSubtreeIfNeeded()
        display()
        CATransaction.flush()
        guard let l = layer, let ctx = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        l.render(in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

/// Borderless, key while it is up (QEMU is the app in front), over a
/// full-screen VM on its own Space.
final class PanelWindow: NSPanel {
    var onCancel: (() -> Void)?

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: 28)   // over Omanotch's strip (27)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Flat like Omarchy's prompt; on macOS 26 a borderless window's shadow
        // also draws a light rim inside its edge (omacvm-cocoa-borderless-no-rim.patch).
        hasShadow = false
        backgroundColor = .clear
        animationBehavior = .none   // up and gone at once: no fade to wait for
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let marker = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            if panelKey(keyCode: event.keyCode, command: event.modifierFlags.contains(.command), marker: marker) == .cancel {
                onCancel?()
            }
            return   // no other key does anything
        }
        if event.type == .keyUp || event.type == .flagsChanged { return }
        super.sendEvent(event)
    }
}

/// What reads the finger for one request, on the main thread:
/// LocalAuthentication with Apple's embedded Touch ID view (the dylib always
/// uses this one), or touchid-panel-tests' stand-in that ends on cue.
protocol PanelEvaluator: AnyObject {
    /// Nil when it can ask now; else why not (.lockout or .notAvailable).
    func unavailable() -> PanelLAEnd?
    /// The view that drives the evaluation (it sits under the glyph).
    var view: NSView? { get }
    /// Starts it; `done` comes once, on the main thread.
    func evaluate(reason: String, _ done: @escaping (PanelLAEnd) -> Void)
    /// Ends it (closes Apple's view); a `done` after this is ignored.
    func invalidate()
}

/// LocalAuthentication: a fresh context per request, biometrics only.
final class LAPanelEvaluator: PanelEvaluator {
    private let context = LAContext()
    private lazy var authView = LAAuthenticationView(context: context, controlSize: .regular)

    init() {
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedFallbackTitle = ""
    }

    func unavailable() -> PanelLAEnd? {
        var e: NSError?
        guard !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) else { return nil }
        return (e as? LAError)?.code == .biometryLockout ? .lockout : .notAvailable
    }

    var view: NSView? { authView }

    func evaluate(reason: String, _ done: @escaping (PanelLAEnd) -> Void) {
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, err in
            let end: PanelLAEnd
            if ok { end = .yes } else {
                switch (err as? LAError)?.code {
                case .userCancel?, .appCancel?, .systemCancel?, .userFallback?: end = .cancelled
                case .authenticationFailed?: end = .failed
                case .biometryLockout?: end = .lockout
                case .biometryNotAvailable?, .biometryNotEnrolled?, .passcodeNotSet?: end = .notAvailable
                default: end = .other
                }
            }
            DispatchQueue.main.async { done(end) }
        }
    }

    func invalidate() { context.invalidate() }
}

/// One request at a time: shows the panel, evaluates, answers once.
final class PanelController: NSObject {
    var willShow: () -> Void = {}
    var didClose: () -> Void = {}
    private var window: PanelWindow?
    private var view: PanelView?
    private var evaluator: PanelEvaluator?
    private let makeEvaluator: () -> PanelEvaluator
    private var once = PanelOnce()
    private var reply: ((TouchIDPanelResult) -> Void)?
    private var began = Date()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previousKey: NSWindow?
    private var generation = 0   // which panel a delayed close belongs to
    private var released = false // its input went back to the VM
    private var reduce = false   // Reduce Motion, as it was when it showed

    var busy: Bool { window != nil }

    private let reduceMotion: () -> Bool

    init(evaluator: @escaping () -> PanelEvaluator = { LAPanelEvaluator() },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        makeEvaluator = evaluator
        self.reduceMotion = reduceMotion
    }

    /// The VM's window: QEMU's key or main window, else its biggest visible one.
    private func vmWindow() -> NSWindow? {
        if let w = NSApp.keyWindow, !(w is PanelWindow), w.isVisible { return w }
        if let w = NSApp.mainWindow, w.isVisible { return w }
        return NSApp.windows.filter { $0.isVisible && !($0 is PanelWindow) && $0.isOnActiveSpace }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The panel's frame: over the VM window QEMU shows on the display under
    /// the Mac's pointer, where the person works (with "Use external
    /// displays" the key window is always the main window, on the display
    /// the VM started on); else over `vm` on its screen, as before.
    private func placement(_ vm: NSWindow, screen: NSScreen, size: CGSize) -> CGRect {
        let screens = NSScreen.screens
        let hosts = ([vm] + NSApp.windows.filter { $0 !== vm }).filter { w in
            panelCanHost(PanelWindowFacts(frame: w.frame, visible: w.isVisible && w.occlusionState.contains(.visible),
                                          shownSpace: w.isOnActiveSpace, isPanel: w is NSPanel, alpha: Double(w.alphaValue)), size: size)
        }
        return panelPlace(pointer: NSEvent.mouseLocation, screens: screens.map(\.frame), visible: screens.map(\.visibleFrame),
                          windows: hosts.map(\.frame), fallback: vm.frame, fallbackVisible: screen.visibleFrame, size: size)
    }

    func show(_ prompt: TouchIDPanelPrompt, reply: @escaping (TouchIDPanelResult) -> Void) {
        if busy {
            // The last one is only playing its end: it goes now. Else the app
            // sends one at a time, so this cannot be one of its own.
            guard once.result != nil else { return reply(.no("cancelled")) }
            close()
        }
        guard NSApp.isActive else { return reply(.no("not-front")) }
        // A command the box would show only cut: macOS's dialog shows it whole.
        guard panelShowsWhole(prompt.box, fits: PanelView.boxFits) else { return reply(.error) }
        guard let vm = vmWindow(), let screen = vm.screen ?? NSScreen.main else { return reply(.error) }
        let c = makeEvaluator()
        if let why = c.unavailable() { return reply(why == .lockout ? .no("lockout") : .no("no-touch-id")) }
        // Nothing below can fail (didClose always follows). QEMU lets go of the
        // pointer first: the Mac's pointer is then where the guest's is.
        willShow()
        once = PanelOnce()
        generation += 1
        self.reply = reply
        evaluator = c
        let theme = PanelTheme(prompt)
        reduce = reduceMotion()
        released = false
        let size = CGSize(width: PanelMetrics.side, height: PanelMetrics.side)
        let frame = placement(vm, screen: screen, size: size)
        let v = PanelView(prompt: prompt, theme: theme, authView: c.view, reduceMotion: reduce)
        let w = PanelWindow(frame: frame)
        w.contentView = v
        w.onCancel = { [weak self] in self?.finish(.no("cancelled"), look: nil) }
        v.cancel.target = self
        v.cancel.action = #selector(cancelClicked)
        window = w
        view = v
        previousKey = vm   // the keyboard's window, also when the panel shows on another display
        w.makeKeyAndOrderFront(nil)
        began = Date()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.finish(.no("not-front"), look: nil)
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                                             object: nil, queue: .main) { [weak self] _ in
            self?.finish(.no("locked"), look: nil)
        })
        let t = Timer(timeInterval: TimeInterval(prompt.timeout), repeats: false) { [weak self] _ in
            self?.finish(.no("timeout"), look: nil)
        }
        RunLoop.main.add(t, forMode: .common)   // also while a menu or a drag tracks
        timer = t
        let reason = prompt.box.map { "\(prompt.line): \($0)" } ?? prompt.line
        c.evaluate(reason: reason) { [weak self, weak c] end in
            guard let self, let c, c === self.evaluator else { return }
            self.ended(end)
        }
    }

    @objc private func cancelClicked() { finish(.no("cancelled"), look: nil) }

    /// The app gave up (the VM's client went away) or closed the connection.
    func cancel() { finish(.no("cancelled"), look: nil) }

    private func ended(_ e: PanelLAEnd) {
        let (result, look) = panelEnd(e, after: Date().timeIntervalSince(began))
        finish(result, look: look, lockout: e == .lockout)
    }

    /// Answers once and gives the person's input back to the VM at once;
    /// then the end shows for its short linger (panelLinger) and the panel
    /// goes. Nothing waits for the linger: the answer and the input are
    /// already the VM's.
    private func finish(_ r: TouchIDPanelResult, look: PanelLook?, lockout: Bool = false) {
        guard window != nil, once.finish(r) else { return }
        timer?.invalidate(); timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o); DistributedNotificationCenter.default().removeObserver(o) }
        observers = []
        evaluator?.invalidate()
        evaluator = nil
        reply?(r)
        reply = nil
        release()
        let linger = panelLinger(look, reduceMotion: reduce)
        guard let look, linger > 0, let v = view else { return close() }
        v.show(look, lockout: lockout)
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
            if let self, self.generation == g { self.close() }
        }
    }

    /// The VM's window gets the keyboard back and QEMU its input (didClose);
    /// the panel, if it still shows its end, takes no clicks. Only while that
    /// window's Space shows (QEMU's handKeyBack rule): else macOS would switch
    /// its display back to it.
    private func release() {
        guard let w = window, !released else { return }
        released = true
        w.ignoresMouseEvents = true
        didClose()
        if NSApp.isActive, let k = previousKey, k.isVisible, k.isOnActiveSpace { k.makeKey() }
        previousKey = nil
    }

    private func close() {
        guard let w = window else { return }
        release()
        w.orderOut(nil)
        window = nil
        view = nil
    }
}
