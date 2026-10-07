import AppKit
import OmacVMUpdate
import SwiftUI

/// --render-update-ui DIR (test builds only): draws the self-update's parts
/// of the UI into PNGs, light and dark, without showing a window: the ready
/// window in each update state, the app menu and the alerts. Run the test
/// build's binary directly; it draws, writes DIR/*.png and quits.
/// The texts are the app's own (the same functions the app calls).
@MainActor
enum RenderUpdateUI {
    static func run(into dir: URL) -> Never {
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = Updater.shared
        let current = u.currentVersion
        let next = "3.0.2"
        let notes = URL(string: "https://github.com/gillesgoetsch/omacvm/releases/tag/v\(next)")
        let staged = Updater.Staged(version: next, app: URL(fileURLWithPath: "/nonexistent.app"), notes: notes, teams: [])
        let state = AppState()
        var c = VMConfig()
        c.user = "omarchy"
        state.config = c
        state.screen = .ready

        let windows: [(String, Updater.Staged?, String?, Bool, Bool)] = [
            ("window-1-ready", staged, nil, true, false),
            ("window-2-waiting", staged, Updater.waitingNotice("A VM runs from \(Product.name)", version: next), true, true),
            ("window-3-updated", nil, Updater.resultNotice(["installed", "2.9.0", current], current: current, previous: "2.9.0"), true, false),
            ("window-4-rolled-back", nil, Updater.resultNotice(["rolled-back", next, "QEMU does not start (status 1)"],
                                                              current: current, previous: nil), true, false),
            ("window-5-went-back", nil, Updater.resultNotice(["went-back", next], current: current, previous: nil), true, false),
            ("window-6-aborted", nil, Updater.resultNotice(["aborted", "a", "VM runs from \(Product.name).app: the update waits until it is shut down"],
                                                          current: current, previous: nil), true, false),
            ("window-7-checks-off", staged, nil, false, false),
            ("window-8-cannot-update", nil, "\(Product.name) cannot update itself here: /Applications/\(Product.name).app is not writable for you (installed by another user or an administrator). Reinstall it as you to get updates.",
             true, false),
        ]
        for (name, s, notice, enabled, waiting) in windows {
            u.showForRendering(staged: s, notice: notice, enabled: enabled, waiting: waiting, previous: "2.9.0")
            draw(name, into: dir) { RootView(state: state) }
        }
        // Check Now: while it checks, and the results it leaves under the switch.
        let checks: [(String, Updater.Outcome?, Bool, Bool)] = [
            ("window-9-checking", nil, true, false),
            ("window-10-up-to-date", .upToDate, false, false),
            ("window-11-check-failed", .failed("no connection to the update feed (The Internet connection appears to be offline.)"), false, false),
            ("window-12-needs-macos", .needsMacOS(next, "26.0"), true, false),
            ("window-13-ready-checks-off", .ready(next), false, false),
        ]
        for (name, outcome, checking, _) in checks {
            let ready: Updater.Staged? = { if case .ready = outcome { return staged } else { return nil } }()
            u.showForRendering(staged: ready, notice: nil, enabled: name.hasSuffix("checking") || name.contains("macos"),
                               waiting: false, previous: nil, outcome: outcome, checking: checking)
            draw(name, into: dir) { RootView(state: state) }
        }
        // A VM runs from this launcher: Update shuts it down and starts it again.
        u.runningVM = { (URL(fileURLWithPath: "/nonexistent"), "Omarchy") }
        u.showForRendering(staged: staged, notice: nil, enabled: true, waiting: false, previous: nil)
        draw("window-14-ready-vm-runs", into: dir) { RootView(state: state) }
        u.runningVM = { nil }

        // The app menu as the menu bar shows it (the app delegate built it).
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: "2.9.0")
        if let menu = NSApp.mainMenu?.items.first?.submenu {
            menu.delegate?.menuNeedsUpdate?(menu)
            draw("menu-app", into: dir) { MenuPicture(items: menu.items) }
        }

        // A new alert per picture: an alert's view does not draw twice.
        let alerts: [(String, () -> NSAlert)] = [
            ("alert-1-ready", { Updater.checkAlert(.ready(next), current: current, busy: nil) }),
            ("alert-2-ready-vm-runs", { Updater.checkAlert(.ready(next), current: current, busy: "A VM runs from \(Product.name)") }),
            ("alert-3-up-to-date", { Updater.checkAlert(.upToDate, current: current, busy: nil) }),
            ("alert-4-needs-macos", { Updater.checkAlert(.needsMacOS(next, "26.0"), current: current, busy: nil) }),
            ("alert-5-failed", { Updater.checkAlert(.failed("no connection to the update feed (The Internet connection appears to be offline.)"),
                                                        current: current, busy: nil) }),
            ("alert-6-go-back", { AppDelegate.goBackAlert("2.9.0", current: current) }),
            ("alert-7-restart-vm", { Updater.checkAlert(.ready(next), current: current, busy: "The VM runs", restart: true) }),
            ("alert-8-shutdown-timeout", { Updater.shutdownTimeoutAlert() }),
        ]
        for (name, make) in alerts {
            for dark in [false, true] {
                let a = make()
                a.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                a.layout()
                if let v = a.window.contentView { write(v, "\(name)\(dark ? "-dark" : "")", into: dir) }
            }
        }
        print("rendered into \(dir.path)")
        exit(0)
    }

    /// In an offscreen window that is never ordered in, light and dark
    /// (a new view each: a hosting view does not draw again after a move).
    private static func draw<V: View>(_ name: String, into dir: URL, _ content: () -> V) {
        for dark in [false, true] {
            let view = NSHostingView(rootView: content().background(Color(nsColor: .windowBackgroundColor)))
            let size = view.fittingSize
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            // SwiftUI draws on the next pass of the run loop.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            write(view, "\(name)\(dark ? "-dark" : "")", into: dir)
            w.contentView = nil
        }
    }

    /// On the window background of the view's appearance (an alert's
    /// background is see-through when drawn on its own).
    private static func write(_ view: NSView, _ name: String, into dir: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let out else { return }
        out.size = rep.size   // before the context: it draws in points
        guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// The menu's items as the menu bar draws them: titles, separators, key
/// equivalents, hidden items left out, disabled ones grey.
private struct MenuPicture: View {
    let items: [NSMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Product.name).bold().padding(.horizontal, 12).padding(.vertical, 4)
            Divider().padding(.vertical, 4)
            ForEach(Array(items.enumerated()).filter { !$0.element.isHidden }, id: \.offset) { _, item in
                if item.isSeparatorItem {
                    Divider().padding(.vertical, 4)
                } else {
                    HStack {
                        Text(item.title).foregroundStyle(item.isEnabled ? .primary : .secondary)
                        Spacer(minLength: 24)
                        if !item.keyEquivalent.isEmpty { Text("⌘\(item.keyEquivalent.uppercased())").foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
