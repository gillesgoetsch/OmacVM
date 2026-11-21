// TouchProbe: what a Mac's touch display (the MacBook Pro with the touch screen,
// macOS 27; or a Sidecar iPad on iPadOS 27) delivers to an AppKit view built like
// QEMU's QemuCocoaView, and the OmacVM touch rules on it (#843). Guided steps:
//   A  a plain view that overrides the mouse methods, as QemuCocoaView: what
//      AppKit's mouse emulation makes of a tap, a scroll, a hold-drag, a long
//      press, a pinch, two fingers
//   B  the raw direct touches (a gesture recognizer that only logs)
//   C  AppKit's own recognizers (click, pan, press, magnify): do they take the
//      touch from the emulation?
//   D  the cursor detached, as OmacVM's full-screen corner guard does it
//   E  full screen: taps and swipes at the screen's edges
//   F  the fix: ui/omacvm-touch.h (omacvm-cocoa-touch-logic.patch), compiled in
//      (build.sh), driven as ui/cocoa.m drives it; the guest's actions drawn
// Every event is logged to ~/Library/Logs/touch-probe-<date>-<time>.tsv, a new
// file each run; analyze.py summarizes a log. Observes only: nothing is posted
// or changed. "Skip to the fix" (or the F key) jumps to step F.
import AppKit
import CoreGraphics

// MARK: - logging

let t0 = Date()
var curMode = "-"
var curStep = "-"

final class LogFile {
    static let shared = LogFile()
    let fh: FileHandle?
    let path: String
    init() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/touch-probe-\(f.string(from: Date())).tsv")
        FileManager.default.createFile(atPath: path, contents: nil)
        fh = FileHandle(forWritingAtPath: path)
    }
    func write(_ s: String) { fh?.write((s + "\n").data(using: .utf8)!) }
}

func n(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
func pt(_ p: NSPoint) -> String { "\(n(p.x)),\(n(p.y))" }

func log(_ src: String, _ what: String, _ detail: String = "") {
    let ms = String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)
    let cursor = NSEvent.mouseLocation
    let cg = CGEvent(source: nil)?.location ?? .zero
    LogFile.shared.write("\(ms)\t\(curMode)\t\(curStep)\t\(src)\t\(what)\tcursor=\(pt(cursor))\tcg=\(pt(cg))\tbuttons=\(NSEvent.pressedMouseButtons)\t\(detail)")
}

let mouseTypes: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                          .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
                                          .rightMouseDragged, .otherMouseDragged]

func cgFields(_ c: CGEvent?) -> String {
    guard let c = c else { return "cg=nil" }
    return "cgtype=\(c.type.rawValue) cgsub=\(c.getIntegerValueField(.mouseEventSubtype))" +
        " cgpid=\(c.getIntegerValueField(.eventSourceUnixProcessID))" +
        " cgstate=\(c.getIntegerValueField(.eventSourceStateID))" +
        " cgdelta=\(c.getIntegerValueField(.mouseEventDeltaX)),\(c.getIntegerValueField(.mouseEventDeltaY))" +
        " cgpress=\(String(format: "%.2f", c.getDoubleValueField(.mouseEventPressure)))" +
        " cgclick=\(c.getIntegerValueField(.mouseEventClickState))" +
        " cgnum=\(c.getIntegerValueField(.mouseEventNumber))" +
        " cgloc=\(pt(c.location))"
}

func describe(_ e: NSEvent, _ view: NSView?) -> String {
    var s = "type=\(e.type.rawValue)"
    let loc = view.map { $0.convert(e.locationInWindow, from: nil) } ?? e.locationInWindow
    if mouseTypes.contains(e.type) {
        s += " sub=\(e.subtype.rawValue) btn=\(e.buttonNumber) clicks=\(e.clickCount)" +
            " pressure=\(String(format: "%.2f", e.pressure)) delta=\(n(e.deltaX)),\(n(e.deltaY)) loc=\(pt(loc))"
    } else if e.type == .scrollWheel {
        s += " scroll=\(n(e.scrollingDeltaX)),\(n(e.scrollingDeltaY)) precise=\(e.hasPreciseScrollingDeltas)" +
            " phase=\(e.phase.rawValue) momentum=\(e.momentumPhase.rawValue) inverted=\(e.isDirectionInvertedFromDevice)" +
            " delta=\(n(e.deltaX)),\(n(e.deltaY)) loc=\(pt(loc))"
    } else if e.type == .magnify {
        s += " mag=\(String(format: "%.4f", e.magnification)) phase=\(e.phase.rawValue) loc=\(pt(loc))"
    } else if e.type == .rotate {
        s += " rot=\(String(format: "%.3f", e.rotation)) phase=\(e.phase.rawValue) loc=\(pt(loc))"
    } else if e.type == .swipe {
        s += " delta=\(n(e.deltaX)),\(n(e.deltaY))"
    } else if e.type == .pressure {
        s += " pressure=\(String(format: "%.2f", e.pressure)) stage=\(e.stage)"
    } else if e.type == .mouseEntered || e.type == .mouseExited {
        s += " loc=\(pt(loc))"
    }
    return s + " " + cgFields(e.cgEvent)
}

// MARK: - the probe view (QEMU-like: overrides every mouse method)

final class ProbeView: NSView {
    var marks: [(NSPoint, NSColor)] = []
    var stripes = false
    var offset = NSPoint.zero          // accumulated scroll (mode F)
    var path: [NSPoint] = []           // the current drag (mode F)
    var rings: [NSPoint] = []          // right clicks (mode F)
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true                 // views no longer clip by default (macOS 14+)
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    func mark(_ p: NSPoint, _ c: NSColor) {
        marks.append((p, c)); if marks.count > 40 { marks.removeFirst() }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).setClip()
        if stripes {
            let h = bounds.height, step: CGFloat = 60
            var y = offset.y.truncatingRemainder(dividingBy: step); if y < 0 { y += step }
            y -= step
            var i = Int((-offset.y / step).rounded(.down))
            while y < h {
                (i % 2 == 0 ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: step).fill()
                let label = "row \(i)" as NSString
                label.draw(at: NSPoint(x: 12 + offset.x.truncatingRemainder(dividingBy: 200), y: y + 20), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
                y += step; i -= 1
            }
        }
        if path.count > 1 {
            NSColor.systemOrange.setStroke()
            let b = NSBezierPath(); b.lineWidth = 4; b.move(to: path[0]); path.dropFirst().forEach { b.line(to: $0) }; b.stroke()
        }
        for r in rings {
            NSColor.systemPurple.setStroke()
            let b = NSBezierPath(ovalIn: NSRect(x: r.x - 18, y: r.y - 18, width: 36, height: 36)); b.lineWidth = 4; b.stroke()
        }
        for (p, c) in marks { c.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)).fill() }
    }
    private func ev(_ name: String, _ e: NSEvent) {
        log("view", name, describe(e, self))
        if mouseTypes.contains(e.type), e.type != .mouseMoved { mark(convert(e.locationInWindow, from: nil), .systemRed) }
    }
    override func mouseDown(with e: NSEvent) { ev("mouseDown", e) }
    override func mouseDragged(with e: NSEvent) { ev("mouseDragged", e) }
    override func mouseUp(with e: NSEvent) { ev("mouseUp", e) }
    override func rightMouseDown(with e: NSEvent) { ev("rightMouseDown", e) }
    override func rightMouseDragged(with e: NSEvent) { ev("rightMouseDragged", e) }
    override func rightMouseUp(with e: NSEvent) { ev("rightMouseUp", e) }
    override func otherMouseDown(with e: NSEvent) { ev("otherMouseDown", e) }
    override func otherMouseDragged(with e: NSEvent) { ev("otherMouseDragged", e) }
    override func otherMouseUp(with e: NSEvent) { ev("otherMouseUp", e) }
    override func mouseMoved(with e: NSEvent) { ev("mouseMoved", e) }
    override func mouseEntered(with e: NSEvent) { ev("mouseEntered", e) }
    override func mouseExited(with e: NSEvent) { ev("mouseExited", e) }
    override func scrollWheel(with e: NSEvent) { ev("scrollWheel", e) }
    override func magnify(with e: NSEvent) { ev("magnify", e) }
    override func rotate(with e: NSEvent) { ev("rotate", e) }
    override func smartMagnify(with e: NSEvent) { ev("smartMagnify", e) }
    override func swipe(with e: NSEvent) { ev("swipe", e) }
    override func pressureChange(with e: NSEvent) { ev("pressureChange", e) }
    override func beginGesture(with e: NSEvent) { ev("beginGesture", e) }
    override func endGesture(with e: NSEvent) { ev("endGesture", e) }
    override func touchesBegan(with e: NSEvent) { ev("touchesBegan(responder)", e) }
    override func touchesMoved(with e: NSEvent) { ev("touchesMoved(responder)", e) }
    override func touchesEnded(with e: NSEvent) { ev("touchesEnded(responder)", e) }
    override func touchesCancelled(with e: NSEvent) { ev("touchesCancelled(responder)", e) }
    override func menu(for event: NSEvent) -> NSMenu? { log("view", "menuForEvent", describe(event, self)); return nil }
}

// MARK: - raw direct-touch logger (never recognizes; fails when the touches end)

final class TouchLogger: NSGestureRecognizer {
    var last = NSPoint.zero
    private func dump(_ phase: String, _ e: NSEvent) {
        let touches = e.touches(matching: .any, in: view)
        var parts: [String] = []
        for t in touches {
            let id = ObjectIdentifier(t.identity as AnyObject).hashValue & 0xffff
            var d = "id=\(String(format: "%04x", id)) ttype=\(t.type.rawValue) tphase=\(t.phase.rawValue)"
            if t.type == .direct, let v = view { let p = t.location(in: v); last = p; d += " tloc=\(pt(p))" }
            else { d += " norm=\(n(t.normalizedPosition.x)),\(n(t.normalizedPosition.y))" }
            parts.append(d)
        }
        log("logger", phase, "n=\(touches.count) [\(parts.joined(separator: "; "))] " + cgFields(e.cgEvent))
        if curMode != "F", let v = view as? ProbeView { v.mark(last, .systemBlue) }
    }
    override func touchesBegan(with e: NSEvent) { dump("touchesBegan", e) }
    override func touchesMoved(with e: NSEvent) { dump("touchesMoved", e) }
    override func touchesEnded(with e: NSEvent) {
        dump("touchesEnded", e)
        if e.touches(matching: .touching, in: view).isEmpty { state = .failed }
    }
    override func touchesCancelled(with e: NSEvent) { dump("touchesCancelled", e); state = .failed }
    override func mouseDown(with e: NSEvent) { log("logger", "mouseDown(gr)", describe(e, view)); state = .failed }
    override func rightMouseDown(with e: NSEvent) { state = .failed }
    override func otherMouseDown(with e: NSEvent) { state = .failed }
    override func location(in view: NSView?) -> NSPoint {
        guard let v = view, let mine = self.view else { return last }
        return v.convert(last, from: mine)
    }
    override func reset() { super.reset(); last = .zero }
}


// MARK: - the fix: OmacVM's touch rules (ui/omacvm-touch.h), driven as ui/cocoa.m does

// As ui/cocoa.m's OmacVMTouchRecognizer: direct touches only, begun at
// touch-down (AppKit's emulation never runs), the fingers' centre and their
// own movement (each finger against its last place) to the rules, with the
// events' times. What the rules decide goes to `act`.
final class TouchInput: NSGestureRecognizer {
    var rules = OmacVMTouch()
    var fingers: [Int: NSPoint] = [:]
    var first: Int?                      // of two fingers, the one the rules get first
    var centre = NSPoint.zero
    var act: ((OmacVMTouchAction) -> Void)?

    private func touching(_ e: NSEvent) -> [Int: NSPoint] {
        guard let v = view else { return [:] }
        var m: [Int: NSPoint] = [:]
        for t in e.touches(matching: .touching, in: v) where t.type == .direct {
            m[(t.identity as! NSObject).hash] = t.location(in: v)
        }
        return m
    }
    private func centreOf(_ m: [Int: NSPoint]) -> NSPoint {
        guard !m.isEmpty else { return centre }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in m.values { x += p.x; y += p.y }
        return NSPoint(x: x / CGFloat(m.count), y: y / CGFloat(m.count))
    }
    private func send(_ o: OmacVMTouchActions) {
        let n = Int(o.n)
        withUnsafeBytes(of: o.a) { raw in
            let acts = raw.bindMemory(to: OmacVMTouchAction.self)
            for i in 0..<n { act?(acts[i]) }
        }
    }
    // Exactly two fingers touch: both to the rules (a pinch), the same one first every time.
    private func two(_ now: [Int: NSPoint]) {
        guard now.count == 2 else { return }
        if first == nil || now[first!] == nil { first = now.keys.first }
        guard let f = first, let a = now[f], let b = now.first(where: { $0.key != f })?.value else { return }
        var o = OmacVMTouchActions()
        omacvm_touch_two(&rules, Double(a.x), Double(a.y), Double(b.x), Double(b.y), &o)
        send(o)
    }
    override func touchesBegan(with e: NSEvent) {
        let now = touching(e)
        guard !now.isEmpty else { return }
        centre = centreOf(now)
        if state == .possible { state = .began }
        var o = OmacVMTouchActions()
        omacvm_touch_begin(&rules, e.timestamp, Double(centre.x), Double(centre.y), Int32(now.count), &o)
        fingers = now
        send(o)
        two(now)
    }
    override func touchesMoved(with e: NSEvent) {
        let now = touching(e)
        guard !now.isEmpty else { return }
        var dx: CGFloat = 0, dy: CGFloat = 0, n: CGFloat = 0
        for (k, p) in now { if let q = fingers[k] { dx += p.x - q.x; dy += p.y - q.y; n += 1 } }
        centre = centreOf(now)
        fingers = now
        var o = OmacVMTouchActions()
        omacvm_touch_move(&rules, e.timestamp, Double(centre.x), Double(centre.y),
                          n > 0 ? Double(dx / n) : 0, n > 0 ? Double(dy / n) : 0, &o)
        send(o)
        two(now)
        state = .changed
    }
    override func touchesEnded(with e: NSEvent) {
        let now = touching(e)
        var o = OmacVMTouchActions()
        omacvm_touch_lift(&rules, e.timestamp, Int32(now.count), &o)
        fingers = now
        send(o)
        if now.isEmpty { first = nil; state = .ended }
    }
    override func touchesCancelled(with e: NSEvent) {
        var o = OmacVMTouchActions()
        omacvm_touch_cancel(&rules, &o)
        fingers = [:]
        first = nil
        send(o)
        state = .cancelled
    }
    override func mouseDown(with e: NSEvent) { state = .failed }
    override func rightMouseDown(with e: NSEvent) { state = .failed }
    override func otherMouseDown(with e: NSEvent) { state = .failed }
    override func location(in v: NSView?) -> NSPoint {
        guard let v = v, let mine = view else { return centre }
        return v.convert(centre, from: mine)
    }
    override func reset() { super.reset(); fingers = [:]; first = nil }
}

// MARK: - controller

struct Step { let mode: String; let title: String; let text: String }

let steps: [Step] = [
    Step(mode: "A", title: "A1 · plain view (like QEMU)", text: "Tap the grey box 5 times, at different spots. Short, light taps."),
    Step(mode: "A", title: "A2 · plain view", text: "Touch and immediately drag up, as if scrolling a web page. Do it 3 times."),
    Step(mode: "A", title: "A3 · plain view", text: "Touch, hold still about half a second, then drag sideways. Do it 2 times."),
    Step(mode: "A", title: "A4 · plain view", text: "Touch and hold still about 2 seconds, then lift. Do it 2 times."),
    Step(mode: "A", title: "A5 · plain view", text: "Pinch with two fingers: zoom in, then out."),
    Step(mode: "A", title: "A6 · plain view", text: "Drag up with two fingers. Do it 2 times."),
    Step(mode: "B", title: "B1 · raw touch logger", text: "Tap the grey box 3 times."),
    Step(mode: "B", title: "B2 · raw touch logger", text: "Touch and immediately drag up. Do it 2 times."),
    Step(mode: "B", title: "B3 · raw touch logger", text: "Pinch with two fingers: in, then out."),
    Step(mode: "C", title: "C1 · touch recognizers (the fix)", text: "Tap the grey box 5 times, at different spots."),
    Step(mode: "C", title: "C2 · touch recognizers", text: "Touch and immediately drag up, as if scrolling. Do it 3 times."),
    Step(mode: "C", title: "C3 · touch recognizers", text: "Touch, hold still about half a second, then drag sideways. Do it 2 times."),
    Step(mode: "C", title: "C4 · touch recognizers", text: "Touch and hold still about 2 seconds, then lift. Do it 2 times."),
    Step(mode: "C", title: "C5 · touch recognizers", text: "Pinch with two fingers: in, then out."),
    Step(mode: "D", title: "D1 · cursor detached (like OmacVM's full-screen guard)", text: "Tap 5 times, at spots far apart in the grey box."),
    Step(mode: "D", title: "D2 · cursor detached", text: "Touch, hold half a second, then drag sideways. Once."),
    Step(mode: "E", title: "E1 · full screen", text: "Tap near the middle of the top edge of the screen (not a corner) twice, then near the middle of the bottom edge twice."),
    Step(mode: "E", title: "E2 · full screen", text: "Swipe in from the left edge toward the middle, then from the right edge. Once each."),
    Step(mode: "E", title: "E3 · full screen", text: "Swipe down from the top edge, then up from the bottom edge. Once each."),
    Step(mode: "F", title: "F1 · the fix: taps", text: "Tap 5 times at different spots. A green dot should appear exactly where you tap."),
    Step(mode: "F", title: "F2 · the fix: scrolling", text: "Scroll the stripes with one finger: slow drags, then a few quick flicks up and down. They should follow your finger and coast after a flick."),
    Step(mode: "F", title: "F3 · the fix: hold, then drag", text: "Touch, hold still until the status says HOLDING (about a third of a second), then drag, whenever you like. An orange line should follow: a drag (select text, move a window)."),
    Step(mode: "F", title: "F4 · the fix: long press", text: "Touch and hold still until the status says LIFT = RIGHT CLICK (about 0.6 s), then lift. A purple ring should appear. Do it twice."),
    Step(mode: "F", title: "F5 · the fix: two fingers", text: "Touch with two fingers and move them together: nothing should scroll or click, as on macOS. Then pinch out and in: PINCH and its zoom show once the fingers' spread changes (in the VM the two fingers go to its touch screen, and its apps zoom between them)."),
    Step(mode: "F", title: "F6 · the fix: double tap", text: "Double-tap quickly in one spot, 3 times, as you would to select a word."),
    Step(mode: "F", title: "F7 · the fix: anything goes", text: "Play: tap, scroll, flick, hold-drag, long press. Note anything that feels wrong, then tap Next."),
    Step(mode: "-", title: "Done, thank you", text: "Press Q or tap Quit. The log is in ~/Library/Logs/."),
]

final class Controller: NSObject, NSApplicationDelegate, NSGestureRecognizerDelegate, NSWindowDelegate {
    var window: NSWindow!
    var probe: ProbeView!
    let titleLabel = NSTextField(labelWithString: "")
    let textLabel = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(labelWithString: "")
    var index = 0
    var mode = ""
    var detached = false
    var tap: CFMachPort?
    var pan: NSPanGestureRecognizer?
    var magnify: NSMagnificationGestureRecognizer?
    var logger: TouchLogger?

    func applicationDidFinishLaunching(_ note: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        log("app", "start", "bundle=\(Bundle.main.bundleIdentifier ?? "-") NSIsTouchNative=\(info["NSIsTouchNative"] ?? "unset") category=\(info["LSApplicationCategoryType"] ?? "-") os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        for (i, s) in NSScreen.screens.enumerated() {
            var touch = "?"
            // NSScreen.touchCapabilities (macOS 27), read without needing its SDK.
            if s.responds(to: NSSelectorFromString("touchCapabilities")),
               let v = s.value(forKey: "touchCapabilities") as? NSNumber { touch = "touchCapabilities=\(v.uintValue)" }
            log("app", "screen\(i)", "frame=\(pt(s.frame.origin)) \(n(s.frame.width))x\(n(s.frame.height)) scale=\(s.backingScaleFactor) touch=\(touch) name=\(s.localizedName)")
        }

        let frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TouchProbe (\(Bundle.main.bundleIdentifier ?? "-"))"
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        let content = NSView(frame: frame)
        window.contentView = content

        titleLabel.font = .boldSystemFont(ofSize: 22)
        textLabel.font = .systemFont(ofSize: 18)
        let back = NSButton(title: "◀︎ Back", target: self, action: #selector(back(_:)))
        let next = NSButton(title: "Next ▶︎", target: self, action: #selector(next(_:)))
        let quit = NSButton(title: "Quit", target: self, action: #selector(quit(_:)))
        let skip = NSButton(title: "Skip to the fix (F)", target: self, action: #selector(skipToFix(_:)))
        next.keyEquivalent = "\r"
        status.font = .boldSystemFont(ofSize: 26)
        status.alignment = .right
        for v in [titleLabel, textLabel, status, back, next, quit, skip] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        probe = ProbeView(frame: .zero)
        probe.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(probe)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            textLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            textLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            textLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            probe.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 12),
            probe.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            probe.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            probe.bottomAnchor.constraint(equalTo: next.topAnchor, constant: -12),
            next.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            next.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            back.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            back.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -12),
            quit.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            quit.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            skip.centerYAnchor.constraint(equalTo: next.centerYAnchor),
            skip.leadingAnchor.constraint(equalTo: quit.trailingAnchor, constant: 12),
            next.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            back.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(probe)
        NSApp.activate(ignoringOtherApps: true)

        // Everything that reaches this app's event queue.
        NSEvent.addLocalMonitorForEvents(matching: .any) { e in
            if e.type == .keyDown {
                switch e.charactersIgnoringModifiers ?? "" {
                case "q": NSApp.terminate(nil); return nil
                case "f": self.skipToFix(nil); return nil
                case String(UnicodeScalar(NSRightArrowFunctionKey)!): self.go(self.index + 1); return nil
                case String(UnicodeScalar(NSLeftArrowFunctionKey)!): self.go(self.index - 1); return nil
                default: break
                }
            }
            let inProbe = self.probe.hitTest(self.probe.superview!.convert(e.locationInWindow, from: nil)) === self.probe
            log("monitor", inProbe ? "probe" : "elsewhere", describe(e, self.probe))
            return e
        }
        startTap()
        go(CommandLine.arguments.contains("--fix") ? firstFix : 0)
    }

    var firstFix: Int { steps.firstIndex { $0.mode == "F" } ?? 0 }
    @objc func skipToFix(_ sender: Any?) { go(firstFix) }

    // A listen-only session event tap: do emulated events pass through the HID/session stream?
    func startTap() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                    .rightMouseDragged, .mouseMoved, .scrollWheel, .otherMouseDown, .otherMouseUp]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        mask |= CGEventMask(1) << 29   // NSEventTypeGesture
        mask |= CGEventMask(1) << 30   // magnify
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            if NSApp.isActive { log("tap", "cgtype\(type.rawValue)", cgFields(event)) }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        if let tap = tap {
            let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            log("app", "tap", "listening")
        } else {
            log("app", "tap", "unavailable (no permission?)")
        }
    }

    func setMode(_ m: String) {
        guard m != mode else { return }
        log("app", "leaveMode", mode)
        for g in probe.gestureRecognizers { probe.removeGestureRecognizer(g) }
        pan = nil; magnify = nil; logger = nil
        probe.stripes = false; fling?.invalidate(); hint?.invalidate()
        if detached { CGAssociateMouseAndMouseCursorPosition(1); detached = false }
        if mode == "E" && window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        mode = m
        curMode = m
        switch m {
        case "B":
            let l = TouchLogger(target: self, action: #selector(grAction(_:)))
            l.allowedTouchTypes = [.direct]
            l.delegate = self
            probe.addGestureRecognizer(l); logger = l
        case "C":
            let l = TouchLogger(target: self, action: #selector(grAction(_:)))
            l.allowedTouchTypes = [.direct]
            l.delegate = self
            probe.addGestureRecognizer(l); logger = l
            let p = NSPanGestureRecognizer(target: self, action: #selector(grAction(_:)))
            p.buttonMask = 0; p.allowedTouchTypes = [.direct]; p.delegate = self
            probe.addGestureRecognizer(p); pan = p
            let c = NSClickGestureRecognizer(target: self, action: #selector(grAction(_:)))
            c.buttonMask = 0; c.allowedTouchTypes = [.direct]; c.delegate = self
            probe.addGestureRecognizer(c)
            let pr = NSPressGestureRecognizer(target: self, action: #selector(grAction(_:)))
            pr.buttonMask = 0; pr.allowedTouchTypes = [.direct]; pr.minimumPressDuration = 0.5; pr.allowableMovement = 10
            pr.delegate = self
            probe.addGestureRecognizer(pr)
            let mg = NSMagnificationGestureRecognizer(target: self, action: #selector(grAction(_:)))
            mg.allowedTouchTypes = [.direct]; mg.delegate = self
            probe.addGestureRecognizer(mg); magnify = mg
        case "D":
            CGAssociateMouseAndMouseCursorPosition(0); detached = true
        case "F":
            let l = TouchLogger(target: self, action: #selector(grAction(_:)))
            l.allowedTouchTypes = [.direct]; l.delegate = self
            probe.addGestureRecognizer(l); logger = l
            let ti = TouchInput(target: self, action: #selector(tiAction(_:)))
            ti.allowedTouchTypes = [.direct]; ti.delegate = self
            ti.act = { [weak self] a in self?.fixAction(a) }
            probe.addGestureRecognizer(ti); touchInput = ti
            probe.stripes = true
        case "E":
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        default: break
        }
        log("app", "enterMode", "\(m) recognizers=\(probe.gestureRecognizers.map { String(describing: type(of: $0)) })")
    }

    func go(_ i: Int) {
        index = max(0, min(steps.count - 1, i))
        let s = steps[index]
        setMode(s.mode)
        curStep = String(s.title.prefix(2))
        titleLabel.stringValue = "\(s.title)   (\(index + 1)/\(steps.count))"
        textLabel.stringValue = s.text
        probe.marks.removeAll(); probe.path.removeAll(); probe.rings.removeAll(); probe.needsDisplay = true
        status.stringValue = ""
        log("app", "step", s.title)
    }

    var fling: Timer?
    var hint: Timer?
    weak var touchInput: TouchInput?
    var pressed = false, lastUp = (t: 0.0, p: NSPoint.zero, n: 0)
    var pinch0 = 0.0                     // a pinch's spread where it began (points)
    @objc func tiAction(_ g: NSGestureRecognizer) {
        guard let ti = g as? TouchInput else { return }
        if g.state == .began {
            // Hints only (the rules decide from the times when the next event comes).
            hint?.invalidate()
            let t = Timer(timeInterval: OMACVM_TOUCH_HOLD, repeats: false) { [weak self, weak ti] _ in
                guard let self = self, let ti = ti, ti.rules.phase == Int32(OMACVM_TOUCH_PENDING) else { return }
                self.say("HOLDING: move = drag", .systemYellow)
                let t2 = Timer(timeInterval: OMACVM_TOUCH_LONG - OMACVM_TOUCH_HOLD, repeats: false) { [weak self, weak ti] _ in
                    guard let self = self, let ti = ti, ti.rules.phase == Int32(OMACVM_TOUCH_PENDING) else { return }
                    self.say("LIFT = RIGHT CLICK, MOVE = DRAG", .systemPurple)
                }
                RunLoop.main.add(t2, forMode: .common); self.hint = t2
            }
            RunLoop.main.add(t, forMode: .common); hint = t
        }
        if g.state != .changed { log("gr", "TouchInput", "state=\(g.state.rawValue) phase=\(ti.rules.phase)") }
    }
    func say(_ w: String, _ c: NSColor) { status.stringValue = w; status.textColor = c }
    // What the guest would get, drawn: the pointer, clicks, drags, right clicks, scrolling.
    func fixAction(_ a: OmacVMTouchAction) {
        let p = NSPoint(x: a.x, y: a.y), d = NSPoint(x: a.dx, y: a.dy)
        let names = ["move", "leftDown", "leftUp", "rightDown", "rightUp", "scroll", "coast", "stopCoast",
                     "pinchBegin", "pinchMove", "pinchEnd"]
        let k = Int(a.kind)
        log("fix", k < names.count ? names[k] : "kind\(k)", "at=\(pt(p)) d=\(pt(d))")
        switch k {
        case OMACVM_TA_MOVE:
            if pressed { probe.path.append(p); probe.needsDisplay = true } else { probe.mark(p, .systemGray) }
        case OMACVM_TA_LEFT_DOWN:
            pressed = true; probe.path = [p]
        case OMACVM_TA_LEFT_UP:
            pressed = false
            if probe.path.count > 2 { say("DRAG", .systemOrange); return }
            probe.path = []
            let now = Date().timeIntervalSince1970
            let n = now - lastUp.t < 0.5 && p == lastUp.p ? lastUp.n + 1 : 1   // the rules put a double tap's second on the first
            lastUp = (now, p, n)
            probe.mark(p, .systemGreen)
            say(n == 1 ? "TAP = CLICK" : n == 2 ? "DOUBLE CLICK" : "TRIPLE CLICK", .systemGreen)
            log("fix", "clickCount", "\(n)")
        case OMACVM_TA_RIGHT_DOWN:
            probe.rings.append(p); probe.needsDisplay = true; say("RIGHT CLICK", .systemPurple)
        case OMACVM_TA_SCROLL:
            if status.stringValue != "SCROLL" { say("SCROLL", .systemBlue) }
            probe.offset.x += d.x; probe.offset.y += d.y; probe.needsDisplay = true
        case OMACVM_TA_COAST:
            fling?.invalidate()
            var vx = a.dx, vy = a.dy, last = CACurrentMediaTime()
            say("COAST", .systemTeal)
            let ft = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                let now = CACurrentMediaTime()
                var dx = 0.0, dy = 0.0
                let on = omacvm_touch_coast_step(&vx, &vy, now - last, &dx, &dy)
                last = now
                self.probe.offset.x += dx; self.probe.offset.y += dy; self.probe.needsDisplay = true
                log("fix", "coastStep", "d=\(pt(NSPoint(x: dx, y: dy)))")
                if !on { t.invalidate(); log("fix", "coastEnd") }
            }
            RunLoop.main.add(ft, forMode: .common); fling = ft
        case OMACVM_TA_STOP_COAST:
            fling?.invalidate(); say("TOUCH", .secondaryLabelColor)
        case OMACVM_TA_PINCH_BEGIN:     // the two fingers: (x, y) and (dx, dy)
            pinch0 = hypot(a.x - a.dx, a.y - a.dy); say("PINCH", .systemPink)
        case OMACVM_TA_PINCH_MOVE:
            if pinch0 > 0 { say(String(format: "PINCH ×%.2f", hypot(a.x - a.dx, a.y - a.dy) / pinch0), .systemPink) }
        case OMACVM_TA_PINCH_END:
            say("PINCH ENDED", .secondaryLabelColor)
        default: break
        }
    }

    @objc func next(_ s: Any?) { go(index + 1) }
    @objc func back(_ s: Any?) { go(index - 1) }
    @objc func quit(_ s: Any?) { NSApp.terminate(nil) }

    @objc func grAction(_ g: NSGestureRecognizer) {
        var d = "state=\(g.state.rawValue) loc=\(pt(g.location(in: probe)))"
        if let p = g as? NSPanGestureRecognizer {
            d += " translation=\(pt(p.translation(in: probe))) velocity=\(pt(p.velocity(in: probe)))"
        } else if let m = g as? NSMagnificationGestureRecognizer {
            d += " magnification=\(String(format: "%.4f", m.magnification))"
        }
        log("gr", String(describing: type(of: g)), d)
        if g.state == .began || g.state == .ended { probe.mark(g.location(in: probe), .systemGreen) }
    }

    // NSGestureRecognizerDelegate
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith o: NSGestureRecognizer) -> Bool {
        if g is TouchLogger || o is TouchLogger { return true }
        if (g === pan || g === magnify) && (o === pan || o === magnify) { return true }
        return false
    }
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        log("gr", "shouldReceive", "\(String(describing: type(of: g))) ttype=\(touch.type.rawValue)")
        return true
    }
    func gestureRecognizerShouldBegin(_ g: NSGestureRecognizer) -> Bool {
        log("gr", "shouldBegin", String(describing: type(of: g)))
        return true
    }

    func windowDidEnterFullScreen(_ n: Notification) { log("app", "didEnterFullScreen", "frame=\(pt(window.frame.origin)) \(n_(window.frame.size))") }
    func windowDidExitFullScreen(_ n: Notification) { log("app", "didExitFullScreen") }
    func n_(_ s: NSSize) -> String { "\(n(s.width))x\(n(s.height))" }

    func applicationWillTerminate(_ note: Notification) {
        if detached { CGAssociateMouseAndMouseCursorPosition(1) }
        log("app", "quit")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
