// The on-screen primitives of src/tests/e2e/onscreen.sh: windows through
// Accessibility on one process (its pid, never "the app named ..."), real
// pointer and click events at the HID level, and the Mac's cursor.
//   cursor                   visible=0|1 empty=0|1|? at X,Y (empty: the image shown has no pixel)
//   bg-show                  as a background helper that shows the cursor (window server property
//                            SetsCursorInBackground, then CGDisplayShowCursor), as OmacVM Gestures did
//                            over full-screen VMs up to 3.1.24; prints the cursor after it
//   can-capture              yes when this process may take pictures of the screen (Screen Recording)
//   win PID                  PID's biggest standard window: X Y W H full=0|1 (points, top left)
//   screen X Y               the visible frame of the display with X,Y: X Y W H (points, top left)
//   full PID on|off          AXFullScreen of that window (as its green button and View > Exit Full Screen)
//   close PID                presses that window's close button
//   zoom PID                 presses its zoom button (the green one of a window without full screen)
//   front PID                PID's app to the front (no input events): front | not front
//   frontpid                 the pid of the app in front
//   quit PID                 asks PID's app to quit (as Command-Q)
//   hide PID, unhide PID     PID's app out of sight and back (as Command-H; no input events): hidden |
//                            shown, exit 1 when it did not take
//   texts PID                the static texts of PID's windows, one a line
//   dump PID                 every element of PID's windows: role, subrole, names, frame
//   hit X Y                  the element at X,Y: pid, role, subrole, names
//   ours PID X Y             exit 0 when the element at X,Y is PID's (no other window over it)
//   find PID ROLE LABEL      enabled=0|1 value=V frame=X Y W H of the first ROLE named LABEL (title,
//                            description, identifier, value, or a static text inside it)
//   click PID ROLE LABEL     a real click at its centre
//   press PID ROLE LABEL     its Accessibility press action (as VoiceOver or Switch Control press it)
//   move X1 Y1 X2 Y2 N MS    N+1 pointer moves from X1,Y1 to X2,Y2, MS ms apart
//   menu PID TITLE           Accessibility's press on PID's menu item TITLE (its menu bar, read without
//                            opening a menu: as VoiceOver presses it; no input events)
//   post NAME [OBJECT]       a distributed notification NAME (with the string OBJECT)
//   space                    the id of the Space shown on the active display
//   onscreen PID             PID's windows on screen now (CGWindowList, no pictures): N, then
//                            "layer L X Y W H" per window
//   windows PID              all of PID's windows, also those not on screen (CGWindowList): "on=0|1 layer L
//                            X Y W H alpha A" per window
//   appstate PID             active=0|1 hidden=0|1 policy=regular|accessory|prohibited front=PID
//   key PID CODE             a key press (virtual key CODE: 36 Return, 53 Escape), only while PID is in
//                            front (exit 3 otherwise: nothing sent)
//   ask-keys PID BUTTON [OTHER]
//                            the question's first second: waits up to 5 s for PID's AXButton BUTTON,
//                            then while PID is in front Return at 0.15 s and Escape at 0.3 s (the
//                            question must stay), at 0.4 s PID's and OTHER's windows on screen and the
//                            Space, Return at 0.65 s (it must go): key=value words with the times;
//                            exit 3 when PID was not in front (no key sent then)
// A click goes out only when PID is in front and the element under the point is PID's (exit 3
// otherwise: nothing pressed). Exit 0 done, 1 not found / refused, 2 usage, 3 not ours / not front.
// xcrun swiftc -O onscreen-tool.swift -o onscreen-tool
import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
func usage() -> Never { FileHandle.standardError.write("usage: see the head of onscreen-tool.swift\n".data(using: .utf8)!); exit(2) }
func say(_ s: String) { print(s); fflush(stdout) }

// MARK: The cursor

@_silgen_name("CGCursorIsVisible") func CGCursorIsVisibleShim() -> boolean_t

/// 1: the image the window server shows has no pixel, 0: it has some, -1: unknown.
func emptyImage() -> Int {
    guard let c = NSCursor.currentSystem,
          let cg = c.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return -1 }
    let w = cg.width, h = cg.height
    guard w > 0, h > 0, w <= 1024, h <= 1024 else { return -1 }
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ok = buf.withUnsafeMutableBytes { p -> Bool in
        guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return -1 }
    for i in stride(from: 3, to: buf.count, by: 4) where buf[i] != 0 { return 0 }
    return 1
}

func cursorState() -> String {
    let p = CGEvent(source: nil)?.location ?? .zero
    let e = emptyImage()
    return "visible=\(CGCursorIsVisibleShim() != 0 ? 1 : 0) empty=\(e < 0 ? "?" : String(e)) at \(Int(p.x)),\(Int(p.y))"
}

// MARK: Accessibility

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ n: String) -> String {
    guard let v = attr(e, n) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func fmt(_ r: CGRect) -> String { String(format: "%.0f %.0f %.0f %.0f", r.minX, r.minY, r.width, r.height) }

func app(_ pid: pid_t) -> AXUIElement {
    guard AXIsProcessTrusted() else { say("no Accessibility for this process"); exit(3) }
    return AXUIElementCreateApplication(pid)
}
func windows(_ pid: pid_t) -> [AXUIElement] { (attr(app(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
/// The biggest standard window (in full screen AppKit adds a thin toolbar window, listed first).
func mainWindow(_ pid: pid_t) -> AXUIElement? {
    let all = windows(pid)
    let std = all.filter { str($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
    return (std.isEmpty ? all : std).max { a, b in
        let fa = frame(a) ?? .zero, fb = frame(b) ?? .zero
        return fa.width * fa.height < fb.width * fb.height
    }
}
func walk(_ e: AXUIElement, _ out: inout [AXUIElement], _ depth: Int = 0) {
    guard depth < 40, out.count < 4000 else { return }
    out.append(e)
    for c in kids(e) { walk(c, &out, depth + 1) }
}
func elements(_ pid: pid_t) -> [AXUIElement] {
    var out: [AXUIElement] = []
    for w in windows(pid) { walk(w, &out) }
    return out
}
func names(_ e: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute].map { str(e, $0) }.filter { !$0.isEmpty }
}
func find(_ pid: pid_t, _ role: String, _ label: String) -> AXUIElement? {
    let els = elements(pid).filter { str($0, kAXRoleAttribute) == role }
    if let e = els.first(where: { names($0).contains(label) }) { return e }
    // A button whose label is a view of its own (an icon and a text).
    return els.first { e in
        var inner: [AXUIElement] = []
        walk(e, &inner)
        return inner.contains { str($0, kAXRoleAttribute) == kAXStaticTextRole as String && names($0).contains(label) }
    }
}

func front(_ pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

// MARK: Events

func post(_ t: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let src = CGEventSource(stateID: .hidSystemState)
    guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left) else { return }
    if t != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
    e.post(tap: .cghidEventTap)
}
/// Exit 3 unless PID is in front and the element at P is PID's.
func ensureOurs(_ pid: pid_t, _ p: CGPoint) {
    // Something else came to the front meanwhile (a system prompt that just appeared): once more.
    if !front(pid) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        for _ in 0..<10 where !front(pid) { usleep(100_000) }
    }
    guard front(pid) else { say("NOT FRONT (front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))"); exit(3) }
    var hit: AXUIElement?
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit)
    var hp: pid_t = 0
    if let hit { AXUIElementGetPid(hit, &hp) }
    guard hp == pid else { say("NOT OURS UNDER THE POINT (pid \(hp))"); exit(3) }
}
func click(_ p: CGPoint, count: Int) {
    post(.mouseMoved, p)
    usleep(150_000)
    // One source for the whole click: the window server counts a double-click from it as from a mouse.
    let src = CGEventSource(stateID: .hidSystemState)
    for n in 1...count {
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            e.post(tap: .cghidEventTap)
            usleep(t == .leftMouseDown ? 40_000 : 70_000)
        }
    }
}

/// A key press and release at the HID level (only after a front check by the caller).
func key(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

/// PID's windows on screen (no names: those need Screen Recording).
func onScreen(_ pid: pid_t) -> [(layer: Int, frame: CGRect)] {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.compactMap { w in
        guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        return ((w[kCGWindowLayer as String] as? Int) ?? 0, r)
    }
}

func menuItem(_ pid: pid_t, _ title: String) -> AXUIElement? {
    guard let bar = attr(app(pid), kAXMenuBarAttribute) else { return nil }
    var all: [AXUIElement] = []
    walk(bar as! AXUIElement, &all)
    return all.first { str($0, kAXRoleAttribute) == kAXMenuItemRole as String && str($0, kAXTitleAttribute) == title }
}

/// The app in front now (Accessibility asks the window server each time: NSWorkspace's answer is not
/// updated in a process that does not run its run loop).
func frontNow() -> pid_t {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &v) == .success,
          let a = v else { return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
    var p: pid_t = 0
    AXUIElementGetPid(a as! AXUIElement, &p)
    return p
}

/// The id of the Space on screen (SkyLight; 0 when it cannot be read).
func activeSpace() -> UInt64 {
    typealias Conn = @convention(c) () -> Int32
    typealias Active = @convention(c) (Int32) -> UInt64
    guard let c = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
          let a = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSGetActiveSpace") else { return 0 }
    return unsafeBitCast(a, to: Active.self)(unsafeBitCast(c, to: Conn.self)())
}

// MARK: Commands

guard args.count >= 2 else { usage() }
func pidArg() -> pid_t { guard args.count >= 3, let p = pid_t(args[2]) else { usage() }; return p }
func num(_ i: Int) -> Double { guard args.count > i, let v = Double(args[i]) else { usage() }; return v }

switch args[1] {
case "cursor":
    say(cursorState())
case "bg-show":
    typealias Conn = @convention(c) () -> Int32
    typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    guard let c = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_CGSDefaultConnection"),
          let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetConnectionProperty") else { say("bg: no CGS"); exit(1) }
    let conn = unsafeBitCast(c, to: Conn.self)(), set = unsafeBitCast(s, to: SetProp.self)
    guard set(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0 else { say("bg: SetsCursorInBackground refused"); exit(1) }
    CGDisplayShowCursor(CGMainDisplayID())
    usleep(400_000)
    say("bg show: " + cursorState())
case "can-capture":
    say(CGPreflightScreenCaptureAccess() ? "yes" : "no")
case "win":
    guard let w = mainWindow(pidArg()), let f = frame(w) else { say("none"); exit(1) }
    say("\(fmt(f)) full=\(((attr(w, "AXFullScreen") as? Bool) ?? false) ? 1 : 0)")
case "screen":
    let p = CGPoint(x: num(2), y: num(3))
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    guard let s = NSScreen.screens.first(where: {
        let f = $0.frame
        return CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height).contains(p)
    }) else { say("none"); exit(1) }
    let v = s.visibleFrame
    say(fmt(CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)))
case "full":
    guard args.count >= 4, let w = mainWindow(pidArg()) else { say("no window"); exit(1) }
    let r = AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, (args[3] == "on" ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    say(r == .success ? "full \(args[3])" : "full \(args[3]) refused: \(r.rawValue)")
    exit(r == .success ? 0 : 1)
case "close":
    guard let w = mainWindow(pidArg()), let b = attr(w, kAXCloseButtonAttribute) else { say("no close button"); exit(1) }
    let r = AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
    say(r == .success ? "closed" : "close refused: \(r.rawValue)")
    exit(r == .success ? 0 : 1)
case "zoom":
    guard let w = mainWindow(pidArg()), let b = attr(w, kAXZoomButtonAttribute) else { say("no zoom button"); exit(1) }
    let r = AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
    say(r == .success ? "zoomed" : "zoom refused: \(r.rawValue)")
    exit(r == .success ? 0 : 1)
case "front":
    let pid = pidArg()
    let ok = NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
    for _ in 0..<20 where !front(pid) { usleep(100_000) }
    say(ok && front(pid) ? "front" : "not front")
case "frontpid":
    say("\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
case "quit":
    let ok = NSRunningApplication(processIdentifier: pidArg())?.terminate() ?? false
    say(ok ? "asked to quit" : "not asked")
    exit(ok ? 0 : 1)
case "hide", "unhide":
    // AppKit's hide first; Accessibility's AXHidden when that did not take.
    let pid = pidArg(), want = args[1] == "hide"
    guard let a = NSRunningApplication(processIdentifier: pid) else { say("no app \(pid)"); exit(1) }
    _ = want ? a.hide() : a.unhide()
    for _ in 0..<10 where a.isHidden != want { usleep(100_000) }
    if a.isHidden != want, AXIsProcessTrusted() {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXHidden" as CFString, (want ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        for _ in 0..<10 where a.isHidden != want { usleep(100_000) }
    }
    say(a.isHidden ? "hidden" : "shown")
    exit(a.isHidden == want ? 0 : 1)
case "texts":
    for e in elements(pidArg()) where str(e, kAXRoleAttribute) == kAXStaticTextRole as String {
        let v = str(e, kAXValueAttribute)
        if !v.isEmpty { say(v) }
    }
case "dump":
    for w in windows(pidArg()) {
        var out: [AXUIElement] = []
        walk(w, &out)
        for e in out {
            say([str(e, kAXRoleAttribute), str(e, kAXSubroleAttribute), names(e).joined(separator: " / "),
                 frame(e).map(fmt) ?? ""].joined(separator: " | "))
        }
    }
case "ours":
    var hit: AXUIElement?
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(num(3)), Float(num(4)), &hit)
    var hp: pid_t = 0
    if let hit { AXUIElementGetPid(hit, &hp) }
    say(hp == pidArg() ? "ours" : "pid \(hp)")
    exit(hp == pidArg() ? 0 : 1)
case "hit":
    var hit: AXUIElement?
    AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(num(2)), Float(num(3)), &hit)
    guard let hit else { say("nothing"); exit(1) }
    var hp: pid_t = 0
    AXUIElementGetPid(hit, &hp)
    say("pid \(hp) | \(str(hit, kAXRoleAttribute)) | \(str(hit, kAXSubroleAttribute)) | \(names(hit).joined(separator: " / "))")
case "find", "click", "press":
    let pid = pidArg()
    guard args.count >= 5, let e = find(pid, args[3], args[4]) else { say("NOT FOUND"); exit(1) }
    let en = (attr(e, kAXEnabledAttribute) as? Bool) ?? true
    guard var f = frame(e) else { say("NO FRAME"); exit(1) }
    if args[1] == "find" { say("enabled=\(en ? 1 : 0) value=\(str(e, kAXValueAttribute)) frame=\(fmt(f))"); exit(0) }
    guard en else { say("DISABLED"); exit(1) }
    if args[1] == "press" {
        let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
        say(r == .success ? "pressed" : "press refused: \(r.rawValue)")
        exit(r == .success ? 0 : 1)
    }
    // Scrolled out of the window: brought into view first, as a person scrolls.
    if let w = mainWindow(pid), let wf = frame(w), !wf.contains(CGPoint(x: f.midX, y: f.midY)) {
        AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        usleep(500_000)
        f = frame(e) ?? f
    }
    let p = CGPoint(x: f.midX, y: f.midY)
    ensureOurs(pid, p)
    click(p, count: 1)
    say("clicked at \(Int(p.x)),\(Int(p.y))")
case "move":
    let a = CGPoint(x: num(2), y: num(3)), b = CGPoint(x: num(4), y: num(5))
    let n = max(0, Int(num(6))), ms = num(7)
    for i in 0...n {
        let t = n == 0 ? 1 : Double(i) / Double(n)
        post(.mouseMoved, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(useconds_t(ms * 1000))
    }
    say("moved to \(Int(b.x)),\(Int(b.y))")
case "menu":
    let pid = pidArg()
    guard args.count >= 4 else { usage() }
    guard let item = menuItem(pid, args[3]) else { say("NOT FOUND"); exit(1) }
    let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
    say(r == .success ? "pressed" : "press refused: \(r.rawValue)")
    exit(r == .success ? 0 : 1)
case "post":
    guard args.count >= 3 else { usage() }
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(args[2]), object: args.count >= 4 ? args[3] : nil,
                                                                 userInfo: nil, deliverImmediately: true)
    usleep(200_000)
    say("posted")
case "space":
    say("\(activeSpace())")
case "onscreen":
    let ws = onScreen(pidArg())
    say("\(ws.count)")
    for w in ws { say("layer \(w.layer) \(fmt(w.frame))") }
case "windows":
    let pid = pidArg()
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid {
        let r = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
        say("on=\((w[kCGWindowIsOnscreen as String] as? Bool) == true ? 1 : 0) layer \((w[kCGWindowLayer as String] as? Int) ?? 0) \(fmt(r)) alpha \((w[kCGWindowAlpha as String] as? Double) ?? 0)")
    }
case "appstate":
    let pid = pidArg()
    guard let a = NSRunningApplication(processIdentifier: pid) else { say("no app \(pid)"); exit(1) }
    let pol = a.activationPolicy == .regular ? "regular" : a.activationPolicy == .accessory ? "accessory" : "prohibited"
    say("active=\(a.isActive ? 1 : 0) hidden=\(a.isHidden ? 1 : 0) policy=\(pol) front=\(frontNow())")
case "key":
    let pid = pidArg()
    guard args.count >= 4, let code = CGKeyCode(args[3]) else { usage() }
    let f = frontNow()
    guard f == pid else { say("NOT FRONT (front pid \(f))"); exit(3) }
    key(code)
    say("sent \(code)")
case "ask-keys":
    let pid = pidArg()
    guard args.count >= 4 else { usage() }
    let label = args[3]
    func up() -> Bool { find(pid, kAXButtonRole as String, label) != nil }
    let start = Date()
    while !up() {
        if Date().timeIntervalSince(start) > 5 { say("question=none"); exit(1) }
        usleep(20_000)
    }
    let t0 = Date()
    func at(_ s: Double) { let w = s - Date().timeIntervalSince(t0); if w > 0 { usleep(useconds_t(w * 1_000_000)) } }
    func now() -> String { String(format: "%.2f", Date().timeIntervalSince(t0)) }
    var out = ["found=" + String(format: "%.2f", t0.timeIntervalSince(start))]
    var sent: [String] = []
    for (s, code, name) in [(0.15, CGKeyCode(36), "Return"), (0.30, CGKeyCode(53), "Escape")] {
        at(s)
        let f = frontNow()
        guard f == pid else { say((out + ["front=\(f)", "sent=\(sent.joined(separator: ","))"]).joined(separator: " ")); exit(3) }
        key(code); sent.append("\(name)@\(now())")
    }
    // Where it is, while it waits: PID's windows on screen (the highest layer), OTHER's, the Space.
    at(0.40)
    let mine = onScreen(pid)
    out.append("alert=\(mine.count)@layer\(mine.map(\.layer).max() ?? 0)")
    if args.count >= 5, let other = pid_t(args[4]) { out.append("vm=\(onScreen(other).count)") }
    out.append("space=\(activeSpace())")
    at(0.45)
    let early = up()
    out.append("early=\(early ? "stays" : "answered@" + now())")
    at(0.65)
    let f = frontNow()
    guard f == pid else { say((out + ["front=\(f)", "sent=\(sent.joined(separator: ","))"]).joined(separator: " ")); exit(3) }
    key(36); sent.append("Return@\(now())")
    var late = "stays"
    for _ in 0..<75 { if !up() { late = "answered@" + now(); break }; usleep(20_000) }
    out += ["front=\(pid)", "late=\(late)", "sent=\(sent.joined(separator: ","))"]
    say(out.joined(separator: " "))
    exit(early && late != "stays" ? 0 : 1)
default:
    usage()
}
