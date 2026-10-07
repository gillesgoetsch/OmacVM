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

/// The glyph: five ridges and their traces, the check, and the animations.
final class PanelGlyphView: NSView {
    private let ridges = CALayer()
    private var paths: [CAShapeLayer] = [], traces: [CAShapeLayer] = []
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
            for trace in [false, true] {
                let s = CAShapeLayer()
                s.frame = bounds
                s.path = p
                s.fillColor = nil
                s.lineWidth = width
                s.lineCap = .round
                s.lineJoin = .round
                s.strokeColor = theme.foreground.cg
                if trace { s.strokeEnd = 0; traces.append(s) } else { paths.append(s) }
                ridges.addSublayer(s)
            }
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
        for s in paths + traces + [check] { s.removeAllAnimations() }
        let now = CACurrentMediaTime()
        switch look {
        case .idle:
            for s in paths { s.strokeColor = theme.foreground.cg; s.opacity = 1 }
            if !reduceMotion {
                let a = CAKeyframeAnimation(keyPath: "opacity")
                a.values = [1, 0.72, 1]
                a.duration = 2.6
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ridges.add(a, forKey: "breathe")
            }
        case .reading:
            for s in paths { s.strokeColor = theme.faint.cg }
            for (i, s) in traces.enumerated() {
                s.strokeColor = theme.accent.cg
                if reduceMotion { s.strokeEnd = 1; continue }
                let a = CABasicAnimation(keyPath: "strokeEnd")
                a.fromValue = 0
                a.toValue = 1
                a.beginTime = now + Double(i) * 0.06
                a.duration = 0.45
                a.fillMode = .both
                a.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.2, 1)
                s.strokeEnd = 1
                s.add(a, forKey: "trace")
            }
        case .done:
            let n = paths.count
            for (i, s) in (paths + traces).enumerated() {
                s.strokeColor = theme.success.cg
                let ring = i % n   // 0 = the core
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0
                a.beginTime = now + (reduceMotion ? 0.2 : Double(n - 1 - ring) * 0.045 + 0.18)
                a.duration = reduceMotion ? 0.3 : 0.3
                a.fillMode = .both
                s.opacity = 0
                s.add(a, forKey: "fade")
            }
            let c: CABasicAnimation
            if reduceMotion {
                check.strokeEnd = 1
                c = CABasicAnimation(keyPath: "opacity")
            } else {
                c = CABasicAnimation(keyPath: "strokeEnd")
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.2, 1)
            }
            c.fromValue = 0
            c.toValue = 1
            c.beginTime = now + 0.45
            c.duration = 0.42
            c.fillMode = .both
            check.strokeEnd = 1
            check.add(c, forKey: "draw")
        case .refused:
            for (i, s) in (paths + traces).enumerated() {
                s.strokeColor = theme.error.cg
                guard !reduceMotion else { continue }
                let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
                let d = 14 * PanelGlyph.transform(into: PanelMetrics.glyph).a * ((i % paths.count) % 2 == 0 ? -1 : 1)
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
/// Apple's view, the state line, Cancel.
final class PanelView: NSView {
    let glyph: PanelGlyphView
    private let message = NSTextField(labelWithString: "")
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
        layer?.borderColor = theme.muted.cg
        layer?.borderWidth = 1
        appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)

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
        let title = label(prompt.title, .systemFont(ofSize: 15, weight: .semibold), theme.foreground)
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

        cancel.isBordered = false
        cancel.wantsLayer = true
        cancel.layer?.backgroundColor = theme.background.cg
        cancel.layer?.borderColor = theme.muted.cg
        cancel.layer?.borderWidth = 1
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

    func show(_ look: PanelLook, lockout: Bool = false) {
        glyph.show(look)
        switch look {
        case .idle: message.stringValue = "Touch ID or Esc"; message.textColor = theme.dim.ns
        case .reading: message.stringValue = "Reading…"; message.textColor = theme.dim.ns
        case .done: message.stringValue = "Done"; message.textColor = theme.success.ns
        case .refused:
            message.stringValue = lockout ? "Touch ID is locked" : "Not recognized"
            message.textColor = theme.error.ns
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
        hasShadow = true
        backgroundColor = .clear
        animationBehavior = .utilityWindow
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

/// One request at a time: shows the panel, evaluates, answers once.
final class PanelController: NSObject {
    var willShow: () -> Void = {}
    var didClose: () -> Void = {}
    private var window: PanelWindow?
    private var view: PanelView?
    private var context: LAContext?
    private var once = PanelOnce()
    private var reply: ((TouchIDPanelResult) -> Void)?
    private var began = Date()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previousKey: NSWindow?
    private var generation = 0   // which panel a delayed close belongs to

    var busy: Bool { window != nil }

    /// The VM's window: QEMU's key or main window, else its biggest visible one.
    private func vmWindow() -> NSWindow? {
        if let w = NSApp.keyWindow, !(w is PanelWindow), w.isVisible { return w }
        if let w = NSApp.mainWindow, w.isVisible { return w }
        return NSApp.windows.filter { $0.isVisible && !($0 is PanelWindow) && $0.isOnActiveSpace }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
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
        let c = LAContext()
        var e: NSError?
        guard c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e) else {
            let code = (e as? LAError)?.code
            return reply(code == .biometryLockout ? .no("lockout") : .no("no-touch-id"))
        }
        c.touchIDAuthenticationAllowableReuseDuration = 0
        c.localizedFallbackTitle = ""
        once = PanelOnce()
        generation += 1
        self.reply = reply
        context = c
        let theme = PanelTheme(prompt.colors)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let size = CGSize(width: PanelMetrics.side, height: PanelMetrics.side)
        let frame = panelFrame(window: vm.frame, visible: screen.visibleFrame, size: size)
        let auth = LAAuthenticationView(context: c, controlSize: .regular)
        let v = PanelView(prompt: prompt, theme: theme, authView: auth, reduceMotion: reduce)
        let w = PanelWindow(frame: frame)
        w.contentView = v
        w.onCancel = { [weak self] in self?.finish(.no("cancelled"), look: nil) }
        v.cancel.target = self
        v.cancel.action = #selector(cancelClicked)
        window = w
        view = v
        previousKey = vm
        willShow()
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
        c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, err in
            DispatchQueue.main.async { [weak self, weak c] in
                guard let self, let c, c === self.context else { return }
                self.ended(ok, err)
            }
        }
    }

    @objc private func cancelClicked() { finish(.no("cancelled"), look: nil) }

    /// The app gave up (the VM's client went away) or closed the connection.
    func cancel() { finish(.no("cancelled"), look: nil) }

    private func ended(_ ok: Bool, _ err: Error?) {
        let e: PanelLAEnd
        if ok { e = .yes } else {
            switch (err as? LAError)?.code {
            case .userCancel?, .appCancel?, .systemCancel?, .userFallback?: e = .cancelled
            case .authenticationFailed?: e = .failed
            case .biometryLockout?: e = .lockout
            case .biometryNotAvailable?, .biometryNotEnrolled?, .passcodeNotSet?: e = .notAvailable
            default: e = .other
            }
        }
        let (result, look) = panelEnd(e, after: Date().timeIntervalSince(began))
        finish(result, look: look, lockout: e == .lockout)
    }

    /// Answers once; then the last look plays and the panel closes.
    private func finish(_ r: TouchIDPanelResult, look: PanelLook?, lockout: Bool = false) {
        guard window != nil, once.finish(r) else { return }
        timer?.invalidate(); timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o); DistributedNotificationCenter.default().removeObserver(o) }
        observers = []
        context?.invalidate()
        context = nil
        reply?(r)
        reply = nil
        guard let look, let v = view else { return close() }
        let g = generation
        let closeLater = { (after: TimeInterval) in
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                if let self, self.generation == g { self.close() }
            }
        }
        if look == .done {
            v.show(.reading)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { v.show(.done) }
            closeLater(1.6)
        } else {
            v.show(look, lockout: lockout)
            closeLater(1.0)
        }
    }

    private func close() {
        guard let w = window else { return }
        w.orderOut(nil)
        window = nil
        view = nil
        didClose()
        if NSApp.isActive, let k = previousKey, k.isVisible { k.makeKey() }
        previousKey = nil
    }
}
