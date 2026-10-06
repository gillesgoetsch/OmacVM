// Touch ID panel (ADR 0041, addendum 3.0.2): the Mac's own panel for a Touch
// ID request from the VM, drawn in the VM's Omarchy theme, laid out like
// Apple's Touch ID panel: the OmacVM icon, "Touch ID in Omarchy", who asks,
// the verified command in a mono box, Apple's embedded Touch ID view, Cancel.
// It looks like Omarchy's own polkit prompt and OSD: the theme's colours, a
// 2 pt border, Hyprland's rounding, JetBrains Mono.
//
// Only AppKit here, no Bridge state: touchid.swift (LAPanelTouchID) makes the
// LAContext and its view and runs the panel; tests/panel renders it off
// screen. Everything runs on the main thread.
import AppKit
import CoreText

// ---- fonts and colours ----

enum TouchIDPanelFonts {
  /// The bundled JetBrains Mono (OFL 1.1), for this process only. Never a
  /// font the VM names: a symbol font could hide the command.
  static func register(_ dir: String) {
    for f in ["JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf"] {
      CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: dir + "/" + f) as CFURL, .process, nil)
    }
  }
  static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
      ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
  }
}

extension ThemeRGB {
  var ns: NSColor { alpha(1) }
  func alpha(_ a: CGFloat) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
  }
}

// ---- the card ----

enum TouchIDPanelMetrics {
  static let width: CGFloat = 360
  static let pad: CGFloat = 18        // Omarchy's panel padding
  static let border: CGFloat = 2      // Omarchy's popup and polkit border
  static let icon: CGFloat = 48
  static let glyph: CGFloat = 64      // the slot for Apple's view: LAAuthenticationView at .regular is 64 pt
  static let control: CGFloat = 28    // Omarchy's control height
  static let notchRadius: CGFloat = 10
}

/// Cancel in Omarchy's control chrome (fill 4 %, border 40 %; hover 8 %, 25 %).
final class TouchIDPanelButton: NSView {
  let theme: OmarchyTheme
  let title: String
  var action: () -> Void = {}
  private var hover = false, down = false
  init(theme: OmarchyTheme, title: String) {
    self.theme = theme; self.title = title
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(title)
  }
  required init?(coder: NSCoder) { fatalError("not used") }
  override var isFlipped: Bool { true }
  override func accessibilityPerformPress() -> Bool { action(); return true }
  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
  override func mouseExited(with e: NSEvent) { hover = false; down = false; needsDisplay = true }
  override func mouseDown(with e: NSEvent) { down = true; needsDisplay = true }
  override func mouseUp(with e: NSEvent) {
    let inside = bounds.contains(convert(e.locationInWindow, from: nil))
    down = false; needsDisplay = true
    if inside { action() }
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func draw(_ dirty: NSRect) {
    let t = theme, lit = hover || down
    let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: t.radius, yRadius: t.radius)
    t.foreground.alpha(down ? 0.14 : lit ? 0.08 : 0.04).setFill(); p.fill()
    t.foreground.alpha(lit ? 0.25 : 0.4).setStroke(); p.lineWidth = 1; p.stroke()
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: TouchIDPanelFonts.mono(12), .foregroundColor: t.foreground.ns, .paragraphStyle: para]
    let s = NSAttributedString(string: title, attributes: a)
    let h = ceil(s.size().height)
    s.draw(with: NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h), options: [.usesLineFragmentOrigin])
  }
}

/// Stands in for Apple's view where no LAContext may be made (snapshots, the
/// mock run): the Touch ID symbol in Apple's red.
final class TouchIDGlyphStandIn: NSView {
  override var fittingSize: NSSize { NSSize(width: 64, height: 64) }
  override func draw(_ dirty: NSRect) {
    guard let sym = NSImage(systemSymbolName: "touchid", accessibilityDescription: "Touch ID")?
      .withSymbolConfiguration(.init(pointSize: 50, weight: .regular).applying(.init(paletteColors: [.systemPink]))) else { return }
    let s = sym.size
    sym.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
  }
}

final class TouchIDPanelView: NSView {
  let theme: OmarchyTheme, text: TouchIDPanelText, style: TouchIDPanelStyle, icon: NSImage?
  let cancel: TouchIDPanelButton
  let auth: NSView
  static let hint = "Touch ID to allow"

  init(theme: OmarchyTheme, text: TouchIDPanelText, style: TouchIDPanelStyle, icon: NSImage?, auth: NSView) {
    self.theme = theme; self.text = text; self.style = style; self.icon = icon; self.auth = auth
    cancel = TouchIDPanelButton(theme: theme, title: "Cancel")
    super.init(frame: .zero)
    setFrameSize(NSSize(width: TouchIDPanelMetrics.width, height: layout(place: false)))
    addSubview(auth)
    addSubview(cancel)
    _ = layout(place: true)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(spoken)
  }
  /// What VoiceOver reads, and announces when the panel shows.
  var spoken: String { [text.title, text.line, text.box].compactMap { $0 }.joined(separator: ": ") + ". " + Self.hint }
  /// System setting Increase Contrast: the second lines in the full text colour.
  private let more = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
  required init?(coder: NSCoder) { fatalError("not used") }
  override var isFlipped: Bool { true }

  private static func para(_ align: NSTextAlignment, chars: Bool = false) -> NSMutableParagraphStyle {
    let p = NSMutableParagraphStyle(); p.alignment = align
    p.lineBreakMode = chars ? .byCharWrapping : .byWordWrapping
    return p
  }
  private var inner: CGFloat { TouchIDPanelMetrics.width - 2 * TouchIDPanelMetrics.pad - 2 * TouchIDPanelMetrics.border }
  private var titleAttr: [NSAttributedString.Key: Any] {
    [.font: TouchIDPanelFonts.mono(14, bold: true), .foregroundColor: theme.foreground.ns, .paragraphStyle: Self.para(.center)]
  }
  private var lineAttr: [NSAttributedString.Key: Any] {
    [.font: TouchIDPanelFonts.mono(12), .foregroundColor: theme.softText(0.78, increaseContrast: more).ns, .paragraphStyle: Self.para(.center)]
  }
  private var boxAttr: [NSAttributedString.Key: Any] {
    [.font: TouchIDPanelFonts.mono(12), .foregroundColor: theme.foreground.ns, .paragraphStyle: Self.para(.left, chars: true)]
  }
  private var hintAttr: [NSAttributedString.Key: Any] {
    [.font: TouchIDPanelFonts.mono(11), .foregroundColor: theme.softText(0.66, increaseContrast: more).ns, .paragraphStyle: Self.para(.center)]
  }
  private func h(_ s: String, _ a: [NSAttributedString.Key: Any], _ w: CGFloat) -> CGFloat {
    ceil(NSAttributedString(string: s, attributes: a).boundingRect(with: NSSize(width: w, height: 2000),
                                                                    options: [.usesLineFragmentOrigin]).height)
  }

  /// The height; with `place`, Apple's view and Cancel go to their places too.
  private func layout(place: Bool) -> CGFloat {
    let m = TouchIDPanelMetrics.self
    var y = m.border + m.pad
    if style == .window { y += m.icon + 12 }
    y += h(text.title, titleAttr, inner) + 6
    y += h(text.line, lineAttr, inner)
    if let b = text.box { y += 10 + h(b, boxAttr, inner - 20) + 14 }
    y += 14
    if place {
      // Apple's view at its own size (it pins its width and height: 16, 32, 64 or 128 pt by its
      // control size), centred in the slot; it draws at that size whatever frame it gets.
      var s = auth.fittingSize
      if s.width <= 0 || s.height <= 0 || s.width > m.glyph || s.height > m.glyph { s = NSSize(width: m.glyph, height: m.glyph) }
      auth.frame = NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: y + (m.glyph - s.height) / 2, width: s.width, height: s.height)
    }
    y += m.glyph + 6 + h(Self.hint, hintAttr, inner) + 16
    if place { cancel.frame = NSRect(x: m.border + m.pad, y: y, width: inner, height: m.control) }
    y += m.control + m.pad + m.border
    return ceil(y)
  }

  /// The card's outline: rounded, or for the notch square on top.
  func outline() -> CGPath {
    let b = TouchIDPanelMetrics.border
    let card = bounds.insetBy(dx: b / 2, dy: b / 2)
    guard style == .notch else {
      let r = min(theme.radius, card.width / 2, card.height / 2)
      return CGPath(roundedRect: card, cornerWidth: r, cornerHeight: r, transform: nil)
    }
    // Flipped view: the top is minY. Square top (open into the strip), rounded bottom.
    let r = max(theme.radius, TouchIDPanelMetrics.notchRadius)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: card.minX, y: bounds.minY))
    p.addLine(to: CGPoint(x: card.minX, y: card.maxY - r))
    p.addArc(tangent1End: CGPoint(x: card.minX, y: card.maxY), tangent2End: CGPoint(x: card.minX + r, y: card.maxY), radius: r)
    p.addLine(to: CGPoint(x: card.maxX - r, y: card.maxY))
    p.addArc(tangent1End: CGPoint(x: card.maxX, y: card.maxY), tangent2End: CGPoint(x: card.maxX, y: card.maxY - r), radius: r)
    p.addLine(to: CGPoint(x: card.maxX, y: bounds.minY))
    return p
  }

  override func draw(_ dirty: NSRect) {
    let t = theme, m = TouchIDPanelMetrics.self
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    // Opaque card, the border inside the bounds (Omarchy's BorderSurface).
    let path = outline()
    ctx.saveGState()
    ctx.addPath(path); ctx.setFillColor(t.background.ns.cgColor); ctx.fillPath()
    ctx.addPath(path); ctx.setLineWidth(m.border)
    if t.border.count == 2, let g = NSGradient(starting: t.border[0].ns, ending: t.border[1].ns) {
      ctx.replacePathWithStrokedPath(); ctx.clip()
      g.draw(in: bounds, angle: -t.borderAngle)
    } else {
      ctx.setStrokeColor((t.border.first ?? t.accent).ns.cgColor); ctx.strokePath()
    }
    ctx.restoreGState()
    var y = m.border + m.pad
    let x0 = m.border + m.pad
    if style == .window {
      if let icon {
        icon.draw(in: NSRect(x: (bounds.width - m.icon) / 2, y: y, width: m.icon, height: m.icon),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
      y += m.icon + 12
    }
    func put(_ s: String, _ a: [NSAttributedString.Key: Any], x: CGFloat, w: CGFloat) {
      let hh = h(s, a, w)
      NSAttributedString(string: s, attributes: a).draw(with: NSRect(x: x, y: y, width: w, height: hh), options: [.usesLineFragmentOrigin])
      y += hh
    }
    put(text.title, titleAttr, x: x0, w: inner); y += 6
    put(text.line, lineAttr, x: x0, w: inner)
    if let box = text.box {
      y += 10
      let bh = h(box, boxAttr, inner - 20) + 14
      let bp = NSBezierPath(roundedRect: NSRect(x: x0, y: y, width: inner, height: bh), xRadius: t.radius, yRadius: t.radius)
      t.boxFill.ns.setFill(); bp.fill()
      t.foreground.alpha(more ? 0.5 : 0.18).setStroke(); bp.lineWidth = 1; bp.stroke()
      // The command never draws outside its box (stacked combining marks
      // would otherwise reach up over the title or down over the hint).
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: NSRect(x: x0, y: y, width: inner, height: bh)).addClip()
      y += 7
      put(box, boxAttr, x: x0 + 10, w: inner - 20)
      y += 7
      NSGraphicsContext.restoreGraphicsState()
    }
    y += 14 + m.glyph + 6
    put(Self.hint, hintAttr, x: x0, w: inner)
  }

  /// The panel drawn off screen (snapshots), at 2x.
  func png(scale: CGFloat = 2) -> Data? {
    guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    rep.size = bounds.size
    let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)
    guard let big else { return nil }
    big.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: big)
    displayIgnoringOpacity(bounds, in: NSGraphicsContext.current!)
    NSGraphicsContext.restoreGraphicsState()
    return big.representation(using: .png, properties: [:])
  }
}

// ---- the window ----

/// Borderless, non-activating, above the VM's full-screen strip windows
/// (Parallels' and UTM's 26, Omanotch's 27). It may become key without
/// activating the Bridge, so Esc and Cmd-. reach it and typing does not go on
/// into the VM while it is up.
final class TouchIDPanelWindow: NSPanel {
  static let level = NSWindow.Level(rawValue: 28)
  var onCancel: () -> Void = {}
  /// Events with this marker in eventSourceUserData come from OmacVM itself
  /// (Gestures' hotkeys, the Bridge's reposted keys): a VM can cause them, so
  /// they do nothing here.
  var marker: Int64 = 0

  init(frame: NSRect, view: TouchIDPanelView) {
    super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    level = Self.level
    collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle, .transient]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = view.style == .window
    isMovable = false
    isMovableByWindowBackground = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    appearance = NSAppearance(named: view.theme.dark ? .darkAqua : .aqua)
    contentView = view
    setAccessibilitySubrole(.dialog)
    setAccessibilityTitle(view.text.title)
  }
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  private func marked(_ e: NSEvent) -> Bool {
    marker != 0 && e.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
  }
  override func sendEvent(_ e: NSEvent) {
    if marked(e) { return }
    super.sendEvent(e)
  }
  override func keyDown(with e: NSEvent) {
    if touchIDPanelKey(keyCode: e.keyCode, command: e.modifierFlags.contains(.command), marked: marked(e)) == .cancel { onCancel() }
  }
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    if touchIDPanelKey(keyCode: e.keyCode, command: e.modifierFlags.contains(.command), marked: marked(e)) == .cancel { onCancel() }
    return true   // nothing else: no menu shortcut reaches past the panel
  }
  override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// One panel on screen. Main thread only.
final class TouchIDPanel {
  let window: TouchIDPanelWindow
  let view: TouchIDPanelView
  let placement: TouchIDPanelPlacement
  private var closed = false

  init(view: TouchIDPanelView, placement: TouchIDPanelPlacement, marker: Int64, onCancel: @escaping () -> Void) {
    self.view = view; self.placement = placement
    window = TouchIDPanelWindow(frame: placement.frame, view: view)
    window.marker = marker
    window.onCancel = onCancel
    view.cancel.action = onCancel
  }

  func show() {
    if placement.style == .notch && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      // Slides down from the strip.
      var from = placement.frame
      from.origin.y += min(24, from.height)
      window.setFrame(from, display: false)
      window.alphaValue = 0
      window.orderFrontRegardless()
      window.makeKey()
      NSAnimationContext.runAnimationGroup { c in
        c.duration = 0.18
        c.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().setFrame(placement.frame, display: true)
        window.animator().alphaValue = 1
      }
    } else {
      window.orderFrontRegardless()
      window.makeKey()
    }
    // The Bridge never becomes the active app, so VoiceOver would not move
    // to the panel by itself: say what it asks.
    NSAccessibility.post(element: window, notification: .announcementRequested,
                         userInfo: [.announcement: view.spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
  }

  func close() {
    guard !closed else { return }
    closed = true
    window.orderOut(nil)
    window.close()
  }
}

// ---- where the VM's window is ----

/// The Mac's screens as the placement needs them.
func touchIDPanelScreens() -> [TouchIDPanelScreen] {
  NSScreen.screens.map { s in
    var mid: CGFloat?
    if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea, s.safeAreaInsets.top > 0 { mid = (l.maxX + r.minX) / 2 }
    return TouchIDPanelScreen(frame: s.frame, visible: s.visibleFrame, safeTop: s.safeAreaInsets.top, notchMidX: mid)
  }
}

/// The app's frontmost normal window on screen (layer 0), in Cocoa
/// coordinates. Bounds, owner and layer only: no Screen Recording needed.
func touchIDFrontWindow(pid: pid_t) -> CGRect? {
  guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
        let main = NSScreen.screens.first else { return nil }
  for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
          (w[kCGWindowLayer as String] as? Int) == 0,
          ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
          let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
          r.width >= touchIDPanelMinWindow.width, r.height >= touchIDPanelMinWindow.height else { continue }
    return touchIDCocoaRect(r, mainHeight: main.frame.height)
  }
  return nil
}

/// The panel's size in a style (its height follows the words).
func touchIDPanelSize(theme: OmarchyTheme, text: TouchIDPanelText, icon: NSImage?) -> (TouchIDPanelStyle) -> CGSize {
  { style in TouchIDPanelView(theme: theme, text: text, style: style, icon: icon, auth: NSView()).frame.size }
}

// ---- one request through the panel ----

/// What became of a request in the panel.
enum TouchIDPanelResult: Equatable {
  case done(TouchIDOutcome)                    // answered, cancelled, timed out, ...
  case ended(TouchIDLAEnd, after: TimeInterval) // the evaluation ended by itself: the caller maps it (fast errors: the alert)
  case noWindow                                // no VM window on a screen: the alert
}

/// Shows the panel, runs the evaluation, closes the panel once, whatever
/// ends it first: the evaluation's own end, Cancel/Esc/Cmd-., the timeout,
/// the VM's client going away, the Mac locking or another app in front.
/// The parts that touch LocalAuthentication come in as closures, so the
/// same flow runs with a mock (tests/panel: never on screen, no LAContext).
/// `run` is called off the main thread; the closures marked main run there.
final class TouchIDPanelFlow {
  let theme: OmarchyTheme, text: TouchIDPanelText, icon: NSImage?, marker: Int64
  /// False: the panel is built but never ordered on screen (the mock run).
  var present = true
  var poll: TimeInterval = 0.25
  /// Main: where the panel goes for its size, nil when the VM's window is not on a screen.
  var place: (_ size: (TouchIDPanelStyle) -> CGSize) -> TouchIDPanelPlacement? = { _ in nil }
  /// Main: Apple's view for the request's LAContext (or a stand-in).
  var authView: () -> NSView = { TouchIDGlyphStandIn() }
  /// Starts the evaluation (once the panel shows); calls back once, on any thread.
  var start: (@escaping (TouchIDLAEnd) -> Void) -> Void = { _ in }
  /// Ends the evaluation early (LAContext.invalidate); its callback follows.
  var stop: () -> Void = {}
  /// Asked at each poll: a reason to close (locked, not-front), or nil.
  var interrupt: () -> TouchIDNo? = { nil }
  /// Main: the panel while it is up (tests press its Cancel through it).
  private(set) var panel: TouchIDPanel?

  private let lock = NSLock()
  private var cancelled = false, stopped = false

  init(theme: OmarchyTheme, text: TouchIDPanelText, icon: NSImage?, marker: Int64) {
    self.theme = theme; self.text = text; self.icon = icon; self.marker = marker
  }

  /// Cancel, Esc, Cmd-.: from the panel, on the main thread. Stops the
  /// evaluation at once, and wins over a finger that lands after it.
  func cancel() {
    lock.lock(); cancelled = true; lock.unlock()
    stopOnce()
  }
  private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  private func stopOnce() {
    lock.lock(); let first = !stopped; stopped = true; lock.unlock()
    if first { stop() }
  }

  func run(timeout: Double, gone: @escaping () -> Bool) -> TouchIDPanelResult {
    let shown: Bool = DispatchQueue.main.sync {
      let size = touchIDPanelSize(theme: theme, text: text, icon: icon)
      guard let pl = place(size) else { return false }
      let view = TouchIDPanelView(theme: theme, text: text, style: pl.style, icon: icon, auth: authView())
      let p = TouchIDPanel(view: view, placement: pl, marker: marker) { [weak self] in self?.cancel() }
      panel = p
      if present { p.show() }
      return true
    }
    guard shown else { return .noWindow }
    defer { DispatchQueue.main.sync { panel?.close(); panel = nil } }

    let done = DispatchSemaphore(value: 0)
    var end = TouchIDLAEnd.other
    let began = Date()
    start { e in self.lock.lock(); end = e; self.lock.unlock(); done.signal() }
    let deadline = began.addingTimeInterval(timeout)
    while done.wait(timeout: .now() + poll) == .timedOut {
      let why: TouchIDNo? = isCancelled ? .cancelled : Date() >= deadline ? .timeout : gone() ? .cancelled : interrupt()
      guard let why else { continue }
      stopOnce()   // closes Apple's view; its callback comes with a cancel
      _ = done.wait(timeout: .now() + 2)
      return .done(.no(why))
    }
    // Cancel pressed: no, even when a finger matched in the same moment (or
    // the evaluation failed because Cancel came before it started).
    if isCancelled { return .done(.no(.cancelled)) }
    lock.lock(); defer { lock.unlock() }
    return .ended(end, after: Date().timeIntervalSince(began))
  }
}
