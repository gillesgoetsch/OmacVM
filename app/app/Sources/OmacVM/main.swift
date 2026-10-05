import AppKit
import SwiftUI

/// The launcher: sets up the VM, starts it and steps aside. QEMU shows the VM
/// in its own window with the app's name and icon; when QEMU ends, so does this.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow?
    var runner: Runner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Scripted install: --install-as NAME [--into FOLDER]
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--install-as"), i + 1 < args.count {
            let folder = args.firstIndex(of: "--into").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            do {
                let app = try Installer.install(name: args[i + 1], into: folder ?? Installer.defaultFolder)
                print("installed \(app.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write("install failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        // One launcher at a time: a second one hands over to the first (a
        // start request too: `open -n ... --args --start --vm NAME`). The
        // copy that just installed this one is quitting: it does not count.
        let me = NSRunningApplication.current
        let installer = args.firstIndex(of: "--installed-by").flatMap { $0 + 1 < args.count ? pid_t(args[$0 + 1]) : nil }
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
               $0 != me && !$0.isTerminated && $0.processIdentifier != installer
           }) {
            if CommandLine.arguments.contains("--start") {
                let vm = args.firstIndex(of: "--vm").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
                DistributedNotificationCenter.default().postNotificationName(
                    Self.startRequest, object: vm, userInfo: nil, deliverImmediately: true)
            }
            (Self.qemuApp ?? other).activate()
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.startRequest, object: nil, queue: .main) { [weak self] note in
            let name = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.startRequested(name) }
        }
        state.startVM = { [weak self] in self?.startVM() }
        buildMenu()
        if state.config.isReady && CommandLine.arguments.contains("--start") {
            startVM()
        } else {
            showWindow()
        }
    }

    static let startRequest = Notification.Name("org.omacvm.app.start")
    /// The VM's window belongs to QEMU's process.
    static var qemuApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.executableURL?.path.hasSuffix("/runtime/bin/OmacVM") == true
        }
    }

    /// Another launcher (or `omacvm`) asks to start a VM.
    private func startRequested(_ name: String) {
        if runner?.isRunning == true { Self.qemuApp?.activate(); return }
        if !name.isEmpty, let c = VMConfig.named(name) { state.config = c; state.screen = c.isReady ? .ready : .setup }
        if state.config.isReady { startVM() } else { showWindow() }
    }

    private var quitting = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if runner?.isRunning == true {
            // Quit, logout and restart shut the VM down first and wait for it
            // (QEMU waits the same way); a VM that hangs is stopped after 90 s.
            quitting = true
            runner?.powerDown()
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
                guard let self, self.quitting else { return }
                self.runner?.forceStop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        if state.screen == .building {
            state.creator.cancel()
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if runner?.isRunning == true { Self.qemuApp?.activate() } else { showWindow() }
        return true
    }

    /// The VM's settings as vm.env has them now (`omacvm resources` may have
    /// changed them while the app ran).
    private func reloadConfig() {
        guard state.screen == .ready, let c = VMConfig.load(from: state.config.folder) else { return }
        if c != state.config { state.config = c }
    }

    private func showWindow() {
        reloadConfig()
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = Product.name
            w.contentViewController = NSHostingController(rootView: RootView(state: state))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func startVM() {
        reloadConfig()
        let r = Runner(config: state.config)
        r.onExit = { [weak self] status in
            guard let self else { return }
            self.runner = nil
            if self.quitting {
                self.quitting = false
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if status == 0 {
                NSApp.terminate(nil)
            } else {
                self.state.message = "The VM stopped unexpectedly (QEMU exit \(status)). Log: \(self.state.config.folder.path)/logs/qemu.log"
                self.showWindow()
            }
        }
        do {
            try r.start()
            runner = r
            state.message = nil
            window?.orderOut(nil)
            // QEMU's window carries the app's name and icon in the Dock.
            NSApp.setActivationPolicy(.accessory)
        } catch {
            state.message = "Could not start the VM: \(error.localizedDescription)"
            showWindow()
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(Product.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
