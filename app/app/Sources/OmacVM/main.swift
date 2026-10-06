import AppKit
import OmacVMUpdate
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
        // Test builds: pictures of the update UI (RenderUpdateUI.swift).
        if let i = args.firstIndex(of: "--render-update-ui"), i + 1 < args.count,
           TestHooks.allowed(bundleID: Bundle.main.bundleIdentifier) {
            buildMenu()
            RenderUpdateUI.run(into: URL(fileURLWithPath: args[i + 1]))
        }
        // Started by update-swap.sh after an update: check that this build
        // works (else the previous version goes back), then start as usual.
        if let i = args.firstIndex(of: "--update-check"), i + 1 < args.count {
            Updater.launchCheck(token: args[i + 1])
            // The update went in after the user quit or shut the VM down:
            // no window now. The next launch reads the result and says so.
            if args.contains("--update-quiet") {
                Updater.shared.log("started after the update (quiet: no window), quitting")
                exit(0)
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
            if args.contains("--update-now") {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.updateRequest, object: nil, userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
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
        DistributedNotificationCenter.default().addObserver(
            forName: Self.updateRequest, object: nil, queue: .main) { _ in
            // From `--update-now` of a second launcher: this one stays open.
            Task { @MainActor in await Updater.shared.runScripted(quitWhenDone: false) }
        }
        // Before any VM start reads the Graphics setting.
        Settings.migrateVenusSwitch()
        // The control centre's Mac jobs run this app's omacvm when there is no checkout.
        ControlCLI.refresh()
        state.startVM = { [weak self] in self?.startVM() }
        state.storage.appBusy = { [weak self] in
            guard let self else { return false }
            return self.runner?.isRunning == true || self.state.screen == .building || Self.qemuApp != nil
        }
        state.storage.building = { [weak self] in self?.state.screen == .building }
        // Half copies from a move cut short by a quit (no move runs yet), and
        // Time Machine leaves VM folders out (those from before 3.0 too).
        DispatchQueue.global(qos: .utility).async {
            for u in Storage.removeStaleMoves(in: Paths.vmsRoots) {
                FileHandle.standardError.write(Data("storage: removed the half copy \(u.path)\n".utf8))
            }
            for vm in VMConfig.all() { Storage.excludeFromBackup(vm.folder) }
        }
        Updater.shared.busyReason = { [weak self] in
            guard let self else { return nil }
            if self.runner?.isRunning == true { return "The VM runs" }
            if self.state.screen == .building { return "A VM is being built" }
            if self.quitting { return "Quitting" }
            return nil
        }
        let starting = state.config.isReady && args.contains("--start")
        Updater.shared.start(pending: args.contains("--update-now") || args.contains("--update-check") ? .leave
                             : starting ? .waitUntilIdle : .installNow)
        buildMenu()
        // Scripted update: --update-now (no window; update.log says what happened).
        if args.contains("--update-now") {
            Task { await Updater.shared.runScripted(quitWhenDone: true) }
            return
        }
        if starting {
            startVM()
        } else {
            showWindow()
        }
    }

    /// Per bundle id: a test build (build-app.sh --id) does not take the
    /// installed app's start requests.
    static let startRequest = Notification.Name("\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").start")
    static let updateRequest = Notification.Name("\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").update-now")
    /// The VM's window belongs to QEMU's process: the one from this app
    /// (another copy of OmacVM may run a VM of its own).
    static var qemuApp: NSRunningApplication? {
        let mine = Running.realPath(Bundle.main.bundleURL) + "/"
        return NSWorkspace.shared.runningApplications.first {
            guard let p = $0.executableURL.map(Running.realPath) else { return false }
            return p.hasPrefix(mine) && p.hasSuffix("/runtime/bin/OmacVM")
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
        if state.storage.moving != nil {
            // A copy to another drive stops at once; its half copy is deleted
            // (at the next launch if that takes longer than the 10 s wait) and
            // the VM stays where it was.
            state.storage.cancelMove()
            func wait(_ tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    if self?.state.storage.moving == nil || tries == 0 {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } else {
                        wait(tries - 1)
                    }
                }
            }
            wait(50)
            return .terminateLater
        }
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
        // Tests: the app and its VM stay out of sight (QEMU reads the same).
        if ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] != nil { return }
        defer { offerMoves() }
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
        if state.storage.moving != nil {
            state.message = "A VM is being moved; start once that is done."
            showWindow()
            return
        }
        if let p = state.config.filesProblem {
            state.message = p
            showWindow()
            return
        }
        let r = Runner(config: state.config)
        r.onExit = { [weak self, weak r] status in
            guard let self else { return }
            let fellBack = r?.venusFallback
            self.runner = nil
            // Vulkan showed nothing (Runner.watchVenusStart): from now on
            // OpenGL until Vulkan is chosen again; start once more on it.
            // The plan then has no Venus, so no second watch and no loop.
            if let why = fellBack {
                let folder = self.state.config.folder
                Graphics.recordFallback(why, folder: folder)
                // The next start empties qemu.log: keep this one's.
                let logs = folder.appendingPathComponent("logs")
                try? FileManager.default.removeItem(at: logs.appendingPathComponent("qemu-vulkan-fallback.log"))
                try? FileManager.default.copyItem(at: logs.appendingPathComponent("qemu.log"),
                                                  to: logs.appendingPathComponent("qemu-vulkan-fallback.log"))
                if !self.quitting {
                    self.startVM()
                    if self.runner != nil {
                        self.state.message = "\(Graphics.didNotStart) (\(why)). Choose Vulkan again in Graphics to try once more."
                    }
                    return
                }
            }
            if self.quitting {
                self.quitting = false
                // An update asked for while the VM ran goes in now, quietly:
                // the user is quitting.
                if Updater.shared.installWhenIdle { Updater.shared.install(quit: false, quiet: true) }
                NSApp.reply(toApplicationShouldTerminate: true)
            } else if status == 0 {
                // Shut down from the guest: the app quits, so no window
                // after the update either.
                if Updater.shared.installWhenIdle { Updater.shared.install(quiet: true) }
                NSApp.terminate(nil)
            } else {
                self.state.message = "The VM stopped unexpectedly (QEMU exit \(status)). Log: \(self.state.config.folder.path)/logs/qemu.log"
                // A waiting update goes in after a crash too (if a QEMU of
                // this app still runs, it keeps waiting).
                if Updater.shared.installWhenIdle { Updater.shared.install() }
                self.showWindow()
            }
        }
        let wasActive = NSApp.isActive
        do {
            try r.start()
            runner = r
            state.message = nil
            window?.orderOut(nil)
            // QEMU's window carries the app's name and icon in the Dock.
            NSApp.setActivationPolicy(.accessory)
            if let pid = r.process?.processIdentifier { handFocus(to: pid, wasActive: wasActive) }
        } catch {
            state.message = "Could not start the VM: \(error.localizedDescription)"
            showWindow()
        }
    }

    // MARK: Offers made once (3.0)

    /// The app in /Applications: offer ~/Applications. VMs in 2.9's hidden
    /// folder: offer the visible VMs folder. Each asked once, never while a VM
    /// runs or builds (then it waits for the next time the window opens).
    private var offering = false
    private func offerMoves() {
        guard !offering, state.screen != .install, !state.storage.appBusy() else { return }
        offering = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.offering = false }
            if self.offerAppMove() { return }
            self.offerLegacyMove()
        }
    }

    /// True when the app moved and a new copy opens.
    private func offerAppMove() -> Bool {
        let d = UserDefaults.standard
        let app = Bundle.main.bundleURL.standardizedFileURL
        let home = Installer.defaultFolder
        guard !d.bool(forKey: "offeredAppMove"),
              ProcessInfo.processInfo.environment["OMACVM_RESOURCES"] == nil,
              app.deletingLastPathComponent().path == "/Applications" else { return false }
        d.set(true, forKey: "offeredAppMove")
        let target = home.appendingPathComponent(app.lastPathComponent)
        guard FileManager.default.isWritableFile(atPath: "/Applications"),
              !FileManager.default.fileExists(atPath: target.path),
              Storage.sameVolume(app, home) else { return false }
        let alert = NSAlert()
        alert.messageText = "Move \(Product.name) to your own Applications folder?"
        alert.informativeText = "\(Product.name) now lives in ~/Applications: updates then never need an administrator. Your VMs stay where they are. \(Product.name) opens again from there."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Keep It Here")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let new = try AppMover.move(app, into: home)
            Installer.markInstalled(new)
            let ls = Process()
            ls.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            ls.arguments = ["-f", new.path]
            try? ls.run()
            ls.waitUntilExit()
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["--installed-by", String(ProcessInfo.processInfo.processIdentifier)]
            NSWorkspace.shared.openApplication(at: new, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.state.message = "Moved to \(new.path), but it did not open: \(error.localizedDescription)"
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
            return true
        } catch {
            state.message = "\(Product.name) stays in /Applications: \(error.localizedDescription)"
            return false
        }
    }

    private func offerLegacyMove() {
        let d = UserDefaults.standard
        let vms = state.storage.legacyVMs
        guard !d.bool(forKey: "offeredLegacyMove"), !vms.isEmpty,
              Paths.vmsRoot.standardizedFileURL.path != Paths.legacyVMsRoot.standardizedFileURL.path,
              VolumeCheck.problem(with: Paths.vmsRoot) == nil else { return }
        d.set(true, forKey: "offeredLegacyMove")
        let target = StorageModel.short(Paths.vmsRoot)
        let alert = NSAlert()
        alert.messageText = vms.count == 1 ? "Move \(vms[0].name) to \(target)?" : "Move your \(vms.count) VMs to \(target)?"
        alert.informativeText = "\(Product.name) now keeps VMs in a folder you can see, one folder per VM. "
            + "Yours are in a hidden folder (~/Library/Application Support/OmacVM/VMs) and keep working there. "
            + (Storage.sameVolume(Paths.legacyVMsRoot, Paths.vmsRoot) ? "Same drive: it takes a moment." : "They are copied, checked and then deleted there.")
            + " You can also move them later, under Storage in this window."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { state.storage.moveLegacy() }
    }

    /// The keyboard goes with the VM's window, wherever it opened: once QEMU
    /// shows it, this launcher (in front when Start was clicked) hands its
    /// activation over (macOS lets only the app in front do that).
    private func handFocus(to pid: pid_t, wasActive: Bool) {
        Task { @MainActor in
            for _ in 0..<75 {   // QEMU's window comes within a few seconds
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
                guard Runner.hasWindow(pid) else { continue }
                if app.isActive { return }
                if wasActive { NSApp.yieldActivation(to: app) }
                app.activate(from: .current, options: [])
                return
            }
        }
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.delegate = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        let back = appMenu.addItem(withTitle: "Go Back…", action: #selector(goBack(_:)), keyEquivalent: "")
        back.tag = Self.goBackTag
        appMenu.addItem(.separator())
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

// MARK: - updates (Updater.swift)

extension AppDelegate: NSMenuDelegate {
    static let goBackTag = 7301

    /// "Go Back to OmacVM 2.7.0…" only while that older version is kept.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.item(withTag: Self.goBackTag) else { return }
        let prev = Updater.shared.previousVersion
        item.isHidden = prev == nil
        item.title = Self.goBackTitle(prev ?? "")
    }

    static func goBackTitle(_ version: String) -> String { "Go Back to \(Product.name) \(version)…" }

    @objc func checkForUpdates(_ sender: Any?) {
        let u = Updater.shared
        Task { @MainActor in
            let outcome = await u.check(manual: true)
            let alert = Self.checkAlert(outcome, current: u.currentVersion, busy: u.busyNow)
            if alert.runModal() == .alertFirstButtonReturn, case .ready = outcome { u.install() }
        }
    }

    /// What Check for Updates… says. busy: why the app cannot be replaced
    /// right now (a VM runs from it): the update then waits for it.
    static func checkAlert(_ outcome: Updater.Outcome, current: String, busy: String?) -> NSAlert {
        let alert = NSAlert()
        switch outcome {
        case .ready(let v):
            alert.messageText = "\(Product.name) \(v) is ready to install"
            if let busy {
                alert.informativeText = "You have \(current). \(busy), so \(v) goes in once it has shut down. Your VMs are not changed."
                alert.addButton(withTitle: "Update After Shutdown")
            } else {
                alert.informativeText = "You have \(current). \(Product.name) restarts with the new version; your VMs are not changed. If it does not start, \(current) comes back by itself."
                alert.addButton(withTitle: "Update and Relaunch")
            }
            alert.addButton(withTitle: "Later")
        case .upToDate:
            alert.messageText = "\(Product.name) is up to date"
            alert.informativeText = "\(current) is the newest version."
        case .skipped(let v):
            alert.messageText = "\(Product.name) \(v) is skipped"
        case .needsMacOS(let v, let m):
            alert.messageText = "\(Product.name) \(v) needs macOS \(m)"
            alert.informativeText = "This Mac stays on \(current). Update macOS to get \(v)."
        case .failed(let why):
            alert.messageText = "Could not check for updates"
            // The reasons are log lines ("no connection to ..."): as a sentence.
            alert.informativeText = why.prefix(1).uppercased() + why.dropFirst() + (why.hasSuffix(".") ? "" : ".")
        }
        return alert
    }

    @objc func goBack(_ sender: Any?) {
        let u = Updater.shared
        guard let prev = u.previousVersion else { return }
        if Self.goBackAlert(prev, current: u.currentVersion).runModal() == .alertFirstButtonReturn { u.goBack() }
        // The ready window shows the notice itself (UpdateSection).
        if let n = u.notice, state.screen != .ready { state.message = n }
    }

    static func goBackAlert(_ prev: String, current: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Go back to \(Product.name) \(prev)?"
        alert.informativeText = "\(Product.name) restarts as \(prev). \(current) is skipped until a later version comes out. Your VMs are not changed."
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

// `OmacVM --vms-folder`: print where the VMs are and quit (no window), for
// `omacvm check` and the tests.
if CommandLine.arguments.dropFirst().first == "--vms-folder" {
    print(Paths.vmsRoot.path)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
