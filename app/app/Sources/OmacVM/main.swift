import AppKit
import OmacVMUpdate
import SwiftUI

/// The launcher: sets up the VM, starts it and steps aside. QEMU shows the VM
/// in its own window with the app's name and icon; when QEMU ends, so does this.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    var window: NSWindow?
    private var centring: CentredWindow?
    var runner: Runner?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // M1/M2: read QEMU's binary for the small PCI window now, off the
        // main thread, so the window never waits for it (Runner.graphicsPlan).
        if (Mac.vmAddressBits ?? Graphics.highPCIWindowBits) < Graphics.highPCIWindowBits {
            DispatchQueue.global(qos: .utility).async { _ = RuntimeQEMU.takesSmallHighWindow }
        }
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
        // Test builds and `swift build`: pictures and heights of the VM window (RenderVMWindow.swift).
        if let i = args.firstIndex(of: "--render-vm-window"), i + 1 < args.count,
           RenderVMWindow.allowed(bundleID: Bundle.main.bundleIdentifier) {
            buildMenu()
            RenderVMWindow.run(into: URL(fileURLWithPath: args[i + 1]))
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
               // The VM's QEMU has this bundle id too (DockIdentity): it is no launcher.
               $0 != me && !$0.isTerminated && $0.processIdentifier != installer
                   && !Running.isQEMU($0.processIdentifier)
           }) {
            if args.contains("--update-now") {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.updateRequest, object: nil, userInfo: nil, deliverImmediately: true)
                NSApp.terminate(nil)
                return
            }
            // Test builds (self-update-test.sh): an update with a VM restart, as Shut Down and Update does.
            if args.contains("--update-restart"), TestHooks.allowed(bundleID: Bundle.main.bundleIdentifier) {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.restartRequest, object: nil, userInfo: nil, deliverImmediately: true)
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
        if TestHooks.allowed(bundleID: Bundle.main.bundleIdentifier) {
            DistributedNotificationCenter.default().addObserver(
                forName: Self.restartRequest, object: nil, queue: .main) { _ in
                Task { @MainActor in await Updater.shared.restartFromMac() }
            }
        }
        // Before any VM start reads the Graphics setting.
        Settings.migrateVenusSwitch()
        // The control centre's Mac jobs run this app's omacvm when there is no checkout.
        ControlCLI.refresh()
        state.startVM = { [weak self] in self?.startVM() }
        state.vmRunning = { [weak self] in self?.runner?.isRunning == true || Self.qemuApp != nil }
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
        // Update with a VM restart (Updater.swift): the launcher's VM and its controls.
        let u = Updater.shared
        u.runningVM = { [weak self] in
            guard let r = self?.runner, r.isRunning else { return nil }
            return (r.config.folder, r.config.name)
        }
        u.powerDownVM = { [weak self] in self?.runner?.powerDown() }
        u.forceStopVM = { [weak self] in self?.runner?.forceStop() }
        u.startVMAgain = { [weak self] folder in self?.startAgain(folder) }
        u.restartBlocker = { [weak self] in
            guard let self else { return nil }
            if self.state.screen == .building { return "a VM is being built" }
            if self.state.storage.moving != nil { return "a VM is being moved" }
            if self.quitting { return "it is quitting" }
            return nil
        }
        // A restart-update shut a VM down for this version (or the old one
        // came back): start it again, once.
        let again = args.contains("--update-now") ? nil : u.takeRestartVM(afterSwap: args.contains("--update-check"))
        let starting = again != nil || (state.config.isReady && args.contains("--start"))
        Updater.shared.start(pending: args.contains("--update-now") || args.contains("--update-check") ? .leave
                             : starting ? .waitUntilIdle : .installNow)
        buildMenu()
        // Scripted update: --update-now (no window; update.log says what happened).
        if args.contains("--update-now") {
            Task { await Updater.shared.runScripted(quitWhenDone: true) }
            return
        }
        if let again {
            startAgain(again)
        } else if starting {
            startVM()
        } else {
            showWindow()
        }
    }

    /// Starts the VM in this folder (after a restart-update), else the window.
    private func startAgain(_ folder: URL) {
        guard runner?.isRunning != true else { return }
        if let c = VMConfig.load(from: folder), c.isReady {
            state.config = c
            state.screen = .ready
            startVM()
        } else if let drive = Storage.missingDrive(for: folder) {
            state.message = Storage.driveGoneText(drive)
            showWindow()
        } else {
            state.message = "The VM at \(folder.path) could not be started again after the update: start it here."
            showWindow()
        }
    }

    /// Per bundle id: a test build (build-app.sh --id) does not take the
    /// installed app's start requests.
    static let startRequest = Notification.Name("\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").start")
    static let updateRequest = Notification.Name("\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").update-now")
    static let restartRequest = Notification.Name("\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").update-restart")
    /// The VM's window belongs to QEMU's process: the one from this app
    /// (another copy of OmacVM may run a VM of its own).
    /// By the kernel's path: LaunchServices reports this app's own executable
    /// for it (DockIdentity).
    static var qemuApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && Running.isQEMU($0.processIdentifier, of: Bundle.main.bundleURL)
        }
    }

    /// Another launcher (or `omacvm`) asks to start a VM.
    private func startRequested(_ name: String) {
        if runner?.isRunning == true { Self.qemuApp?.activate(); return }
        // A build or an update runs a VM without a window; the screen stays on
        // it (startVM checks the same, but only after the lines below).
        if state.screen == .building { showWindow(); return }
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
                // QEMU's exit replies (see the termination handler); forceStop
                // kills it after 5 s if SIGTERM does nothing, so the app does
                // not leave a hung QEMU behind. Quit anyway 10 s later.
                self.runner?.forceStop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.quitting else { return }
                    self.quitting = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        if state.screen == .building {
            if state.creator.job == .update {
                // Stopping the update script would leave its apply running in
                // the user's VM while the VM shuts down: quit once the script
                // has ended (it shuts the VM down itself, also after an error).
                showWindow()
                func wait() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let c = self?.state.creator, c.running else {
                            NSApp.reply(toApplicationShouldTerminate: true)
                            return
                        }
                        wait()
                    }
                }
                wait()
                return .terminateLater
            }
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
            w.isRestorable = false
            window = w
            centring = CentredWindow(w)
        }
        // Each time it opens (first open, after closing it, after the VM):
        // centred on the built-in display, and kept centred while SwiftUI
        // sizes it. Left where the user put it while it stays open, sits in
        // the Dock, or the app was hidden (Cmd-H).
        if let w = window, let c = centring, c.needsPlace, !w.isMiniaturized { c.place() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// How a start takes the network: `.ask` checks the fast network's
    /// service first (askFastNetwork); `.decided(why)`: checked, and why this
    /// start goes on QEMU's user network although the fast network is on (nil:
    /// as FastNetwork.choose says).
    enum NetworkStart { case ask, decided(String?) }

    private func startVM(openGLOnce: String? = nil, network: NetworkStart = .ask) {
        // A build or an update runs the VM without a window: a second QEMU on
        // its disk (a start from the Dock or `omacvm start`) would corrupt it.
        if state.screen == .building {
            showWindow()
            return
        }
        // Start in the window while an update with a VM restart waits: it stops.
        Updater.shared.vmStarting()
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
        // The fast network on, and its service not for this app (after an app
        // update): asked first, never a start that cannot work.
        guard case .decided(let userNetwork) = network else {
            if FastNetwork.isOn(state.config) {
                askFastNetwork { [weak self] why in self?.startVM(openGLOnce: openGLOnce, network: .decided(why)) }
            } else {
                startVM(openGLOnce: openGLOnce, network: .decided(nil))
            }
            return
        }
        let r = Runner(config: state.config)
        r.openGLOnce = openGLOnce
        r.userNetwork = userNetwork
        r.onExit = { [weak self, weak r] status in
            guard let self else { return }
            let fellBack = r?.venusFallback, driveGone = r?.driveGone
            let userNetwork = r?.userNetwork
            self.runner = nil
            // An update with a VM restart: it installs now; the new app starts the VM.
            if !self.quitting, Updater.shared.vmEndedForRestart() { return }
            // The drive with the VM's folder went away (Runner.driveLost): the
            // window shows the VM as unavailable until the drive is back
            // (AppState.drivesChanged). No quit, no OpenGL start.
            if let driveGone, !self.quitting {
                self.state.driveGone(driveGone)
                self.showWindow()
                return
            }
            // Vulkan showed nothing (Runner.watchVenusStart, or QEMU stopped
            // at once): start once more on OpenGL. keep: from now on OpenGL
            // until Vulkan is chosen again; else for that start only. The
            // plan then has no Venus, so no second watch and no loop.
            if let fb = fellBack {
                let folder = self.state.config.folder
                if fb.keep { Graphics.recordFallback(fb.why, folder: folder) }
                // The next start empties qemu.log: keep this one's.
                let logs = folder.appendingPathComponent("logs")
                try? FileManager.default.removeItem(at: logs.appendingPathComponent("qemu-vulkan-fallback.log"))
                try? FileManager.default.copyItem(at: logs.appendingPathComponent("qemu.log"),
                                                  to: logs.appendingPathComponent("qemu-vulkan-fallback.log"))
                if !self.quitting {
                    self.startVM(openGLOnce: fb.keep ? nil : fb.why, network: .decided(userNetwork))
                    if self.runner != nil {
                        self.state.message = fb.keep
                            ? "\(Graphics.didNotStart) (\(fb.why)). \"Try Vulkan again\" under Graphics tries it once more."
                            : "\(Graphics.didNotStart) for this start (\(fb.why)). The next start tries Vulkan again."
                        self.tellFallback(fb.keep
                            ? "\(fb.why). \(Product.name) started the VM again on OpenGL and keeps OpenGL until you click \"Try Vulkan again\" under Graphics."
                            : "\(fb.why). \(Product.name) started the VM again on OpenGL for this start; the next start tries Vulkan again.")
                    }
                    return
                }
            }
            if self.quitting {
                self.quitting = false
                // Quit during an update with a VM restart: no VM starts by itself later.
                Updater.shared.cancelRestart("quitting")
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
        // QEMU's window takes this app's own Dock icon (DockIdentity), so this
        // launcher steps out of the Dock first. If QEMU came up while the
        // launcher still held the icon, the Dock gave QEMU a second one beside
        // a pinned OmacVM (MacBook Air, macOS 26.6.2).
        window?.orderOut(nil)
        centring?.taken()
        NSApp.setActivationPolicy(.accessory)
        do {
            try r.start()
            runner = r
            state.message = nil
            if let pid = r.process?.processIdentifier { handFocus(to: pid, wasActive: wasActive) }
        } catch {
            state.message = "Could not start the VM: \(error.localizedDescription)"
            showWindow()
        }
    }

    /// Before a start of a VM with the fast network on: its service must
    /// serve this app. After an app update it may be from another protocol
    /// (src/net/mac/install.sh --status "old"), or missing: the person
    /// updates it now (macOS's password dialog, once) or the VM starts on
    /// QEMU's user network this time and says so. `done` gets why the start
    /// takes the user network, nil when the service is fine.
    private var askingFastNetwork = false
    private func askFastNetwork(_ done: @escaping (String?) -> Void) {
        guard !askingFastNetwork else { return }   // a second start while asking: the first one starts
        askingFastNetwork = true
        let finish: (String?) -> Void = { [weak self] why in
            self?.askingFastNetwork = false
            done(why)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = FastNetwork.statusBeforeStart()
            DispatchQueue.main.async {
                // Stopped after vmnet failures: the normal network until the Mac restarts, no question.
                if status == "stopped" { finish(FastNetwork.stoppedText); return }
                guard let need = FastNetwork.serviceNeeds(status) else { finish(nil); return }
                // Test builds answer without the question (OMACVM_TEST_FAST_NETWORK_ANSWER=update|normal);
                // a run without a window has nobody to ask.
                let hook = TestHooks.value("OMACVM_TEST_FAST_NETWORK_ANSWER", bundleID: Bundle.main.bundleIdentifier)
                let hidden = ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] != nil
                let update: Bool
                if let hook {
                    update = hook == "update"
                } else if hidden {
                    finish(FastNetwork.notUpdated("there was no window to ask in")); return
                } else {
                    let a = NSAlert()
                    a.messageText = need.title
                    a.informativeText = "\(need.why)\n\n\(need.action): macOS asks for your password once. "
                        + "Or start on the normal network (QEMU's own) this time; the fast network stays on for the next starts."
                    a.addButton(withTitle: need.button)
                    a.addButton(withTitle: "Start on Normal Network")
                    NSApp.activate()
                    update = a.runModal() == .alertFirstButtonReturn
                }
                guard update else { finish(FastNetwork.notUpdated("you chose the normal network for this start")); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let err = FastNetwork.updateService()
                    DispatchQueue.main.async {
                        guard let err else { finish(nil); return }
                        if hook == nil && !hidden {
                            let b = NSAlert()
                            b.messageText = "The fast network was not updated"
                            b.informativeText = "\(err)\n\nThe VM starts on the normal network (QEMU's own) this time."
                            b.addButton(withTitle: "Start")
                            NSApp.activate()
                            b.runModal()
                        }
                        finish(FastNetwork.notUpdated(err))
                    }
                }
            }
        }
    }

    /// The app's window is hidden while the VM runs: say why the VM just
    /// started again, then give the VM its window back.
    private func tellFallback(_ text: String) {
        if ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] != nil { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = Graphics.didNotStartOnMac
            alert.informativeText = text
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()
            Self.qemuApp?.activate()
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
            let outcome = await u.checkNow()
            // This launcher runs the VM: it can shut it down, update and start it again.
            let restart = u.runningVM() != nil
            let alert = Updater.checkAlert(outcome, current: u.currentVersion, busy: u.busyNow, restart: restart)
            guard alert.runModal() == .alertFirstButtonReturn, case .ready = outcome else { return }
            if restart { await u.restartFromMac() } else { u.install() }
        }
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

// `OmacVM --control-run CLI ...`: OmacVM Bridge runs the control centre's
// omacvm for this app's VMs through the app (ControlRun.swift). No window.
if CommandLine.arguments.dropFirst().first == ControlRun.flag {
    ControlRun.main(Array(CommandLine.arguments.dropFirst(2)), test: TestIdentity.isOn)
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
