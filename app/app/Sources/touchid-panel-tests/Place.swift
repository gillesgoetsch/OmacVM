// touchid-panel-tests --place OUT.jsonl [options]: where the real
// PanelController puts the panel, with a plain window standing in for QEMU's
// (same class traits as QemuWindow) and a stand-in evaluator (no
// LocalAuthentication). One row per run, appended to OUT.jsonl. A test Mac's
// screen only (needs a GUI session), never CI.
//   --vm-display ID    the VM window's display (default: the main display)
//   --full             the VM window in macOS full screen (its own Space)
//   --head ID          a second VM window (QEMU's window for another display) there
//   --head-full        that window in full screen too
//   --key vm|head|none which of ours is key when the panel shows (default vm)
//   --pointer ID       the Mac's pointer in the middle of that display when the panel shows (a warp, no event)
//   --row NAME         a name for the row
// After the panel closed: which window is key and each display's current Space ("after").
import AppKit
import Foundation
@testable import OmacVMTouchIDPanel
import OmacVMAuth

final class StandInVMWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class StandInHeadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private typealias CGSConnection = Int32
private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let cgsMain = unsafeBitCast(dlsym(sky, "CGSMainConnectionID"), to: (@convention(c) () -> CGSConnection).self)
private let cgsSpacesForWindows = unsafeBitCast(dlsym(sky, "CGSCopySpacesForWindows"),
                                                to: (@convention(c) (CGSConnection, Int32, CFArray) -> Unmanaged<CFArray>?).self)
private let cgsManagedSpaces = unsafeBitCast(dlsym(sky, "CGSCopyManagedDisplaySpaces"),
                                             to: (@convention(c) (CGSConnection) -> Unmanaged<CFArray>?).self)

func displayID(_ s: NSScreen?) -> UInt32 {
    (s?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

func displayUUID(_ id: UInt32) -> String {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
    return CFUUIDCreateString(nil, u) as String
}

func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }

/// The displays a rectangle in CG (top-left) coordinates lies on.
func cgDisplays(_ r: CGRect) -> [UInt32] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8), n: UInt32 = 0
    CGGetDisplaysWithRect(r, 8, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

/// Space ids per display (CGSCopyManagedDisplaySpaces): current and all.
func spacesByDisplay() -> [[String: Any]] {
    guard let a = cgsManagedSpaces(cgsMain())?.takeRetainedValue() as? [[String: Any]] else { return [] }
    return a.map { d in
        let cur = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] ?? (d["Current Space"] as? [String: Any])?["id64"] ?? NSNull()
        let all = (d["Spaces"] as? [[String: Any]] ?? []).map { ($0["ManagedSpaceID"] ?? $0["id64"] ?? NSNull()) }
        return ["display": d["Display Identifier"] ?? NSNull(), "current": cur, "spaces": all]
    }
}

func spaces(of w: NSWindow) -> [Any] {
    guard let a = cgsSpacesForWindows(cgsMain(), 0x7, [NSNumber(value: w.windowNumber)] as CFArray)?.takeRetainedValue() as? [Any] else { return [] }
    return a
}

func describe(_ w: NSWindow?) -> Any {
    guard let w else { return NSNull() }
    let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]] ?? []
    var cg = CGRect.null
    if let b = list.first?[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) { cg = r }
    return ["class": String(describing: type(of: w)), "title": w.title, "number": w.windowNumber,
            "frame": rect(w.frame), "screen": displayID(w.screen), "screen_uuid": displayUUID(displayID(w.screen)), "visible": w.isVisible,
            "on_active_space": w.isOnActiveSpace, "full_screen": w.styleMask.contains(.fullScreen),
            "key": w.isKeyWindow, "main": w.isMainWindow, "level": w.level.rawValue, "scale": Double(w.backingScaleFactor),
            "cg_bounds": cg.isNull ? NSNull() : rect(cg) as Any, "cg_displays": cg.isNull ? [] : cgDisplays(cg),
            "on_screen": (list.first?[kCGWindowIsOnscreen as String] as? Bool) ?? false,
            "spaces": spaces(of: w)]
}

func runPlace(_ args: [String]) -> Never {
    var out = "", vmDisplay: UInt32?, full = false, head: UInt32?, headFull = false, key = "vm", row = "row", pointer: UInt32?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--place": out = args[i + 1]; i += 1
        case "--vm-display": vmDisplay = UInt32(args[i + 1]); i += 1
        case "--full": full = true
        case "--head": head = UInt32(args[i + 1]); i += 1
        case "--head-full": headFull = true
        case "--key": key = args[i + 1]; i += 1
        case "--row": row = args[i + 1]; i += 1
        case "--pointer": pointer = UInt32(args[i + 1]); i += 1
        default: FileHandle.standardError.write(Data("place: unknown \(args[i])\n".utf8)); exit(2)
        }
        i += 1
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    func screen(_ id: UInt32?) -> NSScreen {
        guard let id else { return NSScreen.screens[0] }
        return NSScreen.screens.first { displayID($0) == id } ?? NSScreen.screens[0]
    }
    func standIn(_ cls: NSWindow.Type, on s: NSScreen, title: String) -> NSWindow {
        let size = CGSize(width: min(960, s.visibleFrame.width - 120), height: min(640, s.visibleFrame.height - 120))
        let f = CGRect(x: s.visibleFrame.midX - size.width / 2, y: s.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        let w = cls.init(contentRect: f, styleMask: [.titled, .miniaturizable, .closable], backing: .buffered, defer: false)
        w.collectionBehavior = [.fullScreenPrimary]
        w.title = title
        w.isReleasedWhenClosed = false
        w.setFrame(f, display: false)
        return w
    }
    let vmScreen = screen(vmDisplay)
    let vm = standIn(StandInVMWindow.self, on: vmScreen, title: "touchid-place VM (\(row))")
    var hw: NSWindow?
    if let head { hw = standIn(StandInHeadWindow.self, on: screen(head), title: "touchid-place head (\(row))") }
    var log: [String: Any] = ["row": row, "argv": args]
    var steps: [() -> Void] = []
    func next(after: Double = 0.4) {
        guard !steps.isEmpty else { return }
        let s = steps.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { s() }
    }
    var fullWait = 0
    func waitFull(_ w: NSWindow, _ then: @escaping () -> Void) {
        if w.styleMask.contains(.fullScreen) || fullWait > 40 { fullWait = 0; DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { then() }; return }
        fullWait += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitFull(w, then) }
    }
    steps.append {
        hw?.orderFront(nil)
        vm.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        next()
    }
    if full { steps.append { vm.toggleFullScreen(nil); waitFull(vm) { next() } } }
    if headFull, let hw { steps.append { hw.toggleFullScreen(nil); waitFull(hw) { next() } } }
    steps.append {
        if !app.isActive { app.activate(ignoringOtherApps: true) }
        switch key {
        case "head": hw?.makeKey()
        case "none":
            let tmp = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
            tmp.makeKeyAndOrderFront(nil); tmp.orderOut(nil)
        default: vm.makeKey()
        }
        next(after: 0.8)
    }
    let controller = PanelController(evaluator: { CueEvaluator(.cancelled, after: 3.0) })
    steps.append {
        if let pointer {
            let b = CGDisplayBounds(pointer)
            CGWarpMouseCursorPosition(CGPoint(x: b.midX, y: b.midY))
        }
        log["before"] = ["active": app.isActive, "key_window": describe(app.keyWindow), "main_window": describe(app.mainWindow),
                         "ns_main_screen": displayID(NSScreen.main), "pointer": [NSEvent.mouseLocation.x, NSEvent.mouseLocation.y],
                         "pointer_screen": displayID(NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }), "screens": NSScreen.screens.map { ["id": displayID($0), "frame": rect($0.frame), "visible": rect($0.visibleFrame)] },
                         "spaces": spacesByDisplay()]
        var answer: String?
        controller.show(TouchIDPanelPrompt(title: "Touch ID in Omarchy", line: "sudo in pts/1 wants to run", box: "pacman -Syu", timeout: 30, colors: [:])) { r in
            answer = "\(r)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let panel = app.windows.first { $0 is PanelWindow }
            log["shown"] = ["answer_so_far": answer ?? NSNull(), "panel": describe(panel), "vm": describe(vm), "head": describe(hw),
                            "key_window": describe(app.keyWindow), "spaces": spacesByDisplay(), "ns_main_screen": displayID(NSScreen.main)]
            controller.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                log["after"] = ["answer": answer ?? NSNull(), "key_window": describe(app.keyWindow), "spaces": spacesByDisplay(),
                                "panel_on_screen": app.windows.contains { $0 is PanelWindow && $0.isVisible }]
                if let d = try? JSONSerialization.data(withJSONObject: log, options: [.sortedKeys]), let h = FileHandle(forWritingAtPath: out) ?? {
                    FileManager.default.createFile(atPath: out, contents: nil); return FileHandle(forWritingAtPath: out) }() {
                    h.seekToEndOfFile(); h.write(d); h.write(Data("\n".utf8)); h.closeFile()
                }
                let p = log["shown"] as? [String: Any]
                let pd = (p?["panel"] as? [String: Any])
                let ak = (log["after"] as? [String: Any])?["key_window"] as? [String: Any]
                print("place \(row): panel screen \(pd?["screen"] ?? "none") cg_displays \(pd?["cg_displays"] ?? "-") on_screen \(pd?["on_screen"] ?? "-") key \(pd?["key"] ?? "-"); vm screen \((p?["vm"] as? [String: Any])?["screen"] ?? "-"); after: key \(ak?["title"] ?? "none")")
                // Leave full screen before quitting so the Space goes cleanly.
                for w in [vm, hw].compactMap({ $0 }) where w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { exit(0) }
            }
        }
    }
    next(after: 0.5)
    app.run()
    exit(1)
}
