// test-usb-menu.sh's hands: the menu items of one QEMU process, through
// Accessibility on that pid only (never "the app named ..."), and the
// distributed notifications its items post. No input events, no window.
//   items PID                       every menu item title of PID's menu bar, one a line
//   press PID TITLE N NAME...       AXPress on PID's menu item TITLE, N times 0.5 s apart, while
//                                   counting each NAME's distributed notifications (until 1.5 s
//                                   after the last press): "TITLE: pressed N; NAME: COUNT; ..."
// Exit 0 done, 1 no such item (or AXPress refused), 2 usage, 3 no Accessibility for this process.
// xcrun swiftc -O usb-menu-tool.swift -o usb-menu-tool
import AppKit
import ApplicationServices

let args = CommandLine.arguments
func usage() -> Never { FileHandle.standardError.write("usage: see the head of usb-menu-tool.swift\n".data(using: .utf8)!); exit(2) }
func say(_ s: String) { print(s); fflush(stdout) }

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "" }
func role(_ e: AXUIElement) -> String { (attr(e, kAXRoleAttribute) as? String) ?? "" }

/// Every menu item under PID's menu bar (its menus are read without opening them).
func menuItems(_ pid: pid_t) -> [AXUIElement] {
    guard AXIsProcessTrusted() else { say("no Accessibility for this process"); exit(3) }
    guard let bar = attr(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return [] }
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard depth < 8, out.count < 2000 else { return }
        if role(e) == kAXMenuItemRole as String { out.append(e) }
        for c in kids(e) { walk(c, depth + 1) }
    }
    walk(bar as! AXUIElement, 0)
    return out
}

guard args.count >= 3, let pid = pid_t(args[2]) else { usage() }
switch args[1] {
case "items":
    for e in menuItems(pid) where !title(e).isEmpty { say(title(e)) }
case "press":
    guard args.count >= 6, let n = Int(args[4]), n >= 1 else { usage() }
    let names = Array(args[5...])
    var counts = [String: Int]()
    for name in names {
        counts[name] = 0
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
            counts[name, default: 0] += 1
        }
    }
    guard let item = menuItems(pid).first(where: { title($0) == args[3] }) else { say("\(args[3]): no such item"); exit(1) }
    var pressed = 0
    for i in 0..<n {
        if i > 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard r == .success else { say("\(args[3]): press refused (\(r.rawValue)) after \(pressed)"); exit(1) }
        pressed += 1
    }
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    say("\(args[3]): pressed \(pressed); " + names.map { "\($0): \(counts[$0] ?? 0)" }.joined(separator: "; "))
default:
    usage()
}
