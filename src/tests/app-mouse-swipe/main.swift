// Draws OmacVM.app's "Magic Mouse swipe" row with and without a Magic Mouse
// (MagicMouse.override), alone and in the setup and VM windows, to PNGs
// (light and dark), without a window on screen: src/tests/app-mouse-swipe.sh.
import AppKit
import SwiftUI

@MainActor
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.0)) }

@MainActor
func draw<V: View>(_ root: V, _ name: String, _ out: URL, width: CGFloat? = nil) -> CGSize {
    var size = CGSize.zero
    for (suffix, look) in [("", NSAppearance.Name.aqua), ("-dark", NSAppearance.Name.darkAqua)] {
        let view = NSHostingView(rootView: root.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: look)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 200), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: look)
        w.contentView = view
        view.setFrameSize(view.fittingSize)
        settle()
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        size = view.bounds.size
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)\(suffix).png"))
        }
    }
    print("drawn \(name) \(Int(size.width))x\(Int(size.height))")
    return size
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    var fail = false
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "ok  " : "FAIL") \(what)"); if !ok { fail = true } }

    // The watch follows the mouse coming and going.
    MagicMouse.override = false
    let watch = MagicMouseWatch()
    MagicMouse.override = true
    RunLoop.main.run(until: Date().addingTimeInterval(3.5))
    check(watch.connected, "watch: a Magic Mouse connected later shows within 3 s")
    MagicMouse.override = false
    RunLoop.main.run(until: Date().addingTimeInterval(3.5))
    check(!watch.connected, "watch: switched off: gone within 3 s")
    let row = draw(MagicMouseRow(inForm: false).padding(8), "row", out, width: 520)
    check(row.height >= 50, "row: picker and hint drawn (\(Int(row.height)) pt)")

    var readyWith: CGFloat = 0, setupWith: CGFloat = 0
    let state = AppState()
    state.storage.refresh(); settle()
    for (mouse, tag) in [(true, "mouse"), (false, "no-mouse")] {
        MagicMouse.override = mouse
        state.screen = .ready
        let r = draw(RootView(state: state), "ready-\(tag)", out)
        state.screen = .setup
        let s = draw(RootView(state: state), "setup-\(tag)", out)
        print("sizes \(tag): ready \(Int(r.height)), setup \(Int(s.height))")
        if mouse { readyWith = r.height; setupWith = s.height } else {
            check(readyWith > r.height + 40, "VM window: the row shows with a Magic Mouse (\(Int(readyWith)) pt), not without (\(Int(r.height)) pt)")
            check(setupWith > s.height + 40, "setup: the row shows with a Magic Mouse (\(Int(setupWith)) pt), not without (\(Int(s.height)) pt)")
        }
    }
    exit(fail ? 1 : 0)
}
