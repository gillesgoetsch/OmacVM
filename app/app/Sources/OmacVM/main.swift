import AppKit
import OmacVMUpdate
import OmacVMFeatures
import OmacVMWindow
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
            // A test build hands a start or a restart only to its own copy: an
            // older copy may start another VM for a name it does not find.
            if args.contains("--start") || args.contains("--update-restart"),
               let why = TestVMs.handOverProblem(testBuild: TestHooks.allowed(bundleID: id),
                                                 mine: Bundle.main.bundleURL, other: other.bundleURL) {
                FileHandle.standardError.write(Data("OmacVM: \(why)\n".utf8))
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
                let vm = VMPick.requested(args) ?? ""
                // --vm without a name: no request (an empty one would start the VM shown there).
                if VMPick.requested(args) == "" {
                    FileHandle.standardError.write(Data("OmacVM: \(VMPick.unknownText("", roots: []))\n".utf8))
                    NSApp.terminate(nil)
                    return
                }
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
                forName: Self.restartRequest, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Only a VM in this test build's own VMs folder (TestVMs.hookProblem).
                    if let c = self?.runner?.config, let why = Paths.hookProblem(c.location) {
                        FileHandle.standardError.write(Data("OmacVM: --update-restart refused: \(why)\n".utf8))
                        return
                    }
                    Task { @MainActor in await Updater.shared.restartFromMac() }
                }
            }
        }
        if TestIdentity.isOn, let why = TestVMs.refusedSetting(custom: UserDefaults.standard.string(forKey: "vmsRoot"),
                                                               production: Paths.productionVMsRoots) {
            FileHandle.standardError.write(Data("OmacVM: \(why); VMs folder \(Paths.vmsRoot.path)\n".utf8))
        }
        // --vm NAME that no VM has: no start, no test hook, the window says so.
        let unknownVM = VMConfig.unknownRequested
        if let n = unknownVM {
            FileHandle.standardError.write(Data("OmacVM: \(VMPick.unknownText(n, roots: Paths.vmsRoots))\n".utf8))
        }
        // The icon's look (the header's easter egg) in the Dock.
        AppIcon.apply()
        // Test builds: pictures of the running app's windows on request.
        TestSnapshots.start()
        // Before any VM start reads the Graphics setting.
        Settings.migrateVenusSwitch()
        Settings.removeRetiredSwitches()
        // The control centre's Mac jobs run this app's omacvm when there is no checkout.
        ControlCLI.refresh()
        state.startVM = { [weak self] in self?.startVM() }
        state.checkForUpdates = { [weak self] in self?.checkForUpdates(nil) }
        state.showVM = { Self.qemuApp?.activate() }
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
        let starting = again != nil || (unknownVM == nil && state.config.isReady && args.contains("--start"))
        Updater.shared.start(pending: args.contains("--update-now") || args.contains("--update-check") ? .leave
                             : starting ? .waitUntilIdle : .installNow)
        buildMenu()
        // Scripted update: --update-now (no window; update.log says what happened).
        if args.contains("--update-now") {
            Task { await Updater.shared.runScripted(quitWhenDone: true) }
            return
        }
        // Test builds (the disk size check on a test Mac): Apply in Disk ›
        // Change… for this size, before --start.
        // Only on a VM in the VMs folder this test build was given, never on
        // one of the installed app's (TestVMs.hookProblem).
        if let v = TestHooks.value("OMACVM_TEST_DISK_GB", bundleID: Bundle.main.bundleIdentifier), let gb = Int(v) {
            if let why = unknownVM.map({ VMPick.unknownText($0, roots: Paths.vmsRoots) }) ?? Paths.hookProblem(state.config.location) {
                FileHandle.standardError.write(Data("OmacVM: OMACVM_TEST_DISK_GB refused: \(why)\n".utf8))
            } else {
                let result: String
                do { result = "\(try VMDisk.change(state.config, to: gb))" } catch { result = "refused: \(error.localizedDescription)" }
                try? "disk to \(gb) GB: \(result)\n".write(to: state.config.folder.appendingPathComponent("logs/test-disk-change"),
                                                         atomically: true, encoding: .utf8)
                reloadConfig()
            }
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
        if !name.isEmpty {
            // A name no VM has starts nothing (never the VM shown now).
            guard let c = VMConfig.named(name) else {
                let why = VMPick.unknownText(name, roots: Paths.vmsRoots)
                FileHandle.standardError.write(Data("OmacVM: start request: \(why)\n".utf8))
                state.message = why
                showWindow()
                return
            }
            state.config = c
            state.screen = c.isReady ? .ready : .setup
        }
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
        // Back from .accessory (a VM ran): macOS drew the bundle's icon again.
        AppIcon.apply()
        if window == nil {
            let w = Self.makeWindow(RootView(state: state))
            window = w
            centring = CentredWindow(w, followsResize: false)
        }
        // Each time it opens (first open, after closing it, after the VM): as
        // tall as the screen it opens on shows, at most 800 pt
        // (WindowSize.defaultHeight), centred on the built-in display. Left where the user put it (and as tall) while it stays
        // open, sits in the Dock, or the app was hidden (Cmd-H).
        if let w = window, let c = centring, c.needsPlace, !w.isMiniaturized {
            w.setContentSize(NSSize(width: WindowSize.width, height: Self.defaultHeight))
            c.place()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The app's window (docs/design/settings-3.1): 800 pt wide, only the
    /// height changes; the header sits under a transparent title bar, and an
    /// empty unified toolbar gives the window's buttons the header's height.
    static func makeWindow<V: View>(_ root: V) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WindowSize.width, height: defaultHeight),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = Product.name
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        let bar = NSToolbar(identifier: "OmacVM.window")
        bar.allowsUserCustomization = false
        w.toolbar = bar
        w.toolbarStyle = .unified
        w.collectionBehavior.insert(.fullScreenNone)
        w.contentMinSize = NSSize(width: WindowSize.width, height: WindowSize.minHeight)
        w.contentMaxSize = NSSize(width: WindowSize.width, height: 100_000)
        w.delegate = FixedWidthWindow.shared
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: WindowSize.width, height: defaultHeight))
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        return w
    }

    /// Keeps the app's window 800 pt wide; only its height changes. Its
    /// minimum and maximum width hold a drag on its side, but macOS's Fill (a
    /// double-click on the title bar, the default since macOS 15) and window
    /// tiling ignore them: the window went as wide as the screen while its
    /// content stayed 800 pt. Main thread.
    @MainActor
    final class FixedWidthWindow: NSObject, NSWindowDelegate {
        static let shared = FixedWidthWindow()

        func windowDidResize(_ note: Notification) {
            guard let w = note.object as? NSWindow, abs(w.frame.width - WindowSize.width) > 0.5 else { return }
            let fixed = WindowSize.fixedWidth(x: w.frame.origin.x, width: w.frame.width)
            var f = w.frame
            f.origin.x = fixed.x
            f.size.width = fixed.width
            w.setFrame(f, display: true)
        }
    }

    /// The window's height on the screen it opens on.
    static var defaultHeight: CGFloat {
        CGFloat(WindowSize.defaultHeight(visible: Double(NSWindow.appScreen?.frame.height ?? CGFloat(WindowSize.smallScreenVisible))))
    }

    /// How far a start got: `.ask` asks about the run marker and this Mac's
    /// helpers (askMacHelpers); `.helpersChecked`: done, the fast network's
    /// service next (askFastNetwork); `.decided(why)`: checked, and why this
    /// start goes on QEMU's user network although the fast network is on (nil:
    /// as FastNetwork.choose says). Each step that waits (a look off the main
    /// thread, a question) calls startVM again, so the checks below run again
    /// after it: meanwhile a build, a move or another start may have begun.
    enum NetworkStart { case ask, helpersChecked, decided(String?) }

    private func startVM(openGLOnce: String? = nil, network: NetworkStart = .ask) {
        // A build or an update runs the VM without a window: a second QEMU on
        // its disk (a start from the Dock or `omacvm start`) would corrupt it.
        if state.screen == .building {
            showWindow()
            return
        }
        // This app runs the VM already, or a start is on its way: that one goes on.
        if let r = runner {
            if r.isRunning { Self.qemuApp?.activate() }
            return
        }
        if case .ask = network, askingHelpers || askingFastNetwork { return }
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
        // A test build never starts a VM of the installed app.
        if let why = Paths.startProblem(state.config.folder) {
            FileHandle.standardError.write(Data("OmacVM: \(why)\n".utf8))
            state.message = why
            showWindow()
            return
        }
        // Another app on this Mac (another copy of this one) runs this VM: a
        // second QEMU on its disk would damage it.
        if runner == nil, VMOpen.qemuRuns(state.config.folder, lines: Storage.processLines()) {
            state.message = "\(state.config.name) runs in another app on this Mac. Shut it down there first, then start it here."
            showWindow()
            return
        }
        // Not shut down cleanly, or copied while it ran (RunMarker): asked
        // first, once per start (.decided: the same start, continued).
        if case .ask = network {
            guard RunMarker.confirmStart(state.config) else {
                showWindow()
                return
            }
            // This Mac's helpers for the VM (a VM copied from another Mac):
            // said once per start, Update VM offered.
            askMacHelpers { [weak self] go in
                if go { self?.startVM(openGLOnce: openGLOnce, network: .helpersChecked) }
            }
            return
        }
        // The fast network on, and its service not for this app (after an app
        // update): asked first, never a start that cannot work.
        guard case .decided(let userNetwork) = network else {
            if FastNetwork.isOn(state.config) && !BridgedNetwork.isOn(state.config) {
                askFastNetwork { [weak self] why in self?.startVM(openGLOnce: openGLOnce, network: .decided(why)) }
            } else {
                startVM(openGLOnce: openGLOnce, network: .decided(nil))
            }
            return
        }
        // A smaller disk: the guest shrank btrfs at the last start; cut
        // disk.img before QEMU opens it (VMDisk, DiskImage.cut).
        if VMDisk.resize(state.config)?.step == .cut {
            VMDisk.cutIfDue(state.config)
            reloadConfig()
        }
        // A VM from a bigger Mac starts at the Best tier here; vm.env stays.
        let r = Runner(config: state.config.forThisMac)
        r.sizeNote = state.config.startSizeNote
        r.openGLOnce = openGLOnce
        r.userNetwork = userNetwork
        r.helpersNote = helpersNote
        helpersNote = nil
        r.onExit = { [weak self, weak r] status in
            guard let self else { return }
            let fellBack = r?.venusFallback, driveGone = r?.driveGone, diskLocked = r?.diskLocked == true
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
                            ? "\(Graphics.didNotStart) (\(fb.why)). \"Try Vulkan Again\" under Graphics tries it once more."
                            : "\(Graphics.didNotStart) for this start (\(fb.why)). The next start tries Vulkan again."
                        self.tellFallback(fb.keep
                            ? "\(fb.why). \(Product.name) started the VM again on OpenGL and keeps OpenGL until you click \"Try Vulkan Again\" under Graphics."
                            : "\(fb.why). \(Product.name) started the VM again on OpenGL for this start; the next start tries Vulkan again.")
                    }
                    return
                }
            }
            // The guest shrank btrfs and shut down for the cut: start again
            // (startVM cuts first, then the guest checks the disk).
            if !self.quitting, VMDisk.resize(self.state.config)?.step == .cut {
                self.startVM()
                return
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
            } else if diskLocked {
                // Another app or Mac has the VM's disk open: QEMU did not start.
                self.state.message = VMOpen.diskLockedText(self.state.config.name)
                self.showWindow()
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
        // Set before the start: r.start() waits on small helper processes,
        // which runs the main loop, so a QEMU that ends at once (its disk
        // locked elsewhere) has its exit handled before start() returns, and
        // that says why in the window.
        state.message = nil
        runner = r
        do {
            try r.start()
            if let pid = r.process?.processIdentifier { handFocus(to: pid, wasActive: wasActive) }
        } catch {
            runner = nil
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

    /// Before a start: is this Mac set up for the VM (MacSetup, the same
    /// answer as omacvm check's "Mac setup")? A VM folder copied from another
    /// Mac has none of the helpers its features need and the other Mac's
    /// token, and nothing said so (2026-10-20). Said once per start with what
    /// fixes it: Update VM (it installs the helpers, which then ask macOS for
    /// their permissions; the VM starts when it is done), Check for Updates
    /// (a VM with a newer OmacVM), the System Settings pane; or Later (not
    /// asked again for this problem and app version). Nothing is installed
    /// without the person. `done(true)`: the start goes on.
    /// On from the look until its answer is handled (startVM's guard).
    private var askingHelpers = false
    /// For qemu.log ("OmacVM: Mac helpers: ..."): what the look said and what was asked.
    private var helpersNote: String?
    private func askMacHelpers(_ done: @escaping (Bool) -> Void) {
        askingHelpers = true
        helpersNote = nil
        let c = state.config
        let notch = Mac.hasNotch
        // The start right after Update VM from this question: the helpers it
        // installed have macOS's own questions open now. Only the log line.
        let quiet = state.helpersQuietOnce
        state.helpersQuietOnce = false
        let hidden = ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] != nil
        // Test builds answer without the question: update (the fix) or later.
        let hook = TestHooks.value("OMACVM_TEST_HELPERS_ANSWER", bundleID: Bundle.main.bundleIdentifier)
        DispatchQueue.global(qos: .userInitiated).async {
            var s = MacSetup.probe(c, notch: notch)
            // Not set up: looked at once more 2 s later, as omacvm update or a
            // control centre job may be installing a helper right now.
            if let first = s, first.verdict == .setup, !quiet, !MacSetupLater.isQuiet(first, folder: c.folder) {
                Thread.sleep(forTimeInterval: 2)
                s = MacSetup.probe(c, notch: notch) ?? first
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state.macSetupFound(s, folder: c.folder)
                    // askingHelpers stays on until the answer is handled: a
                    // second start meanwhile (omacvm start, --start) neither
                    // looks nor asks again.
                    @MainActor func end(_ go: Bool) {
                        self.askingHelpers = false
                        done(go)
                    }
                    // While it looked or asked, Update VM (the window's), a
                    // move or another start may have begun, or the window
                    // shows another VM now: this start stops there, and never
                    // runs a second update.
                    @MainActor func overtaken() -> Bool {
                        let why = self.state.config.folder.standardizedFileURL != c.folder.standardizedFileURL ? "another VM shown"
                            : self.state.screen == .building ? "a build or Update VM runs"
                            : self.runner != nil ? "another start is on its way"
                            : self.state.storage.moving != nil ? "a VM is being moved" : nil
                        guard let why else { return false }
                        FileHandle.standardError.write(Data("OmacVM: Mac helpers: start stopped (\(why))\n".utf8))
                        end(false)
                        if self.runner == nil { self.showWindow() }
                        return true
                    }
                    if overtaken() { return }
                    guard let s else {
                        self.helpersNote = "not known (src/mac/install.sh --status gave no answer)"
                        end(true)
                        return
                    }
                    @MainActor func go(_ asked: String?) {
                        self.helpersNote = s.record + (asked.map { "; asked: \($0)" } ?? "")
                        end(true)
                    }
                    guard s.needsAction else { MacSetupLater.clear(folder: c.folder); go(nil); return }
                    if quiet { go("no (the start after Update VM)"); return }
                    if MacSetupLater.isQuiet(s, folder: c.folder) { go("remembered (Later)"); return }
                    let answer: MacSetup.Answer
                    if let hook {
                        answer = hook == "later" ? .later : .fix
                    } else if hidden {
                        go("no (no window to ask in)"); return
                    } else {
                        answer = s.ask(vm: c.name)
                        if overtaken() { return }
                    }
                    if answer == .later {
                        MacSetupLater.remember(s, folder: c.folder)
                        go("later")
                        return
                    }
                    FileHandle.standardError.write(Data("OmacVM: Mac helpers: \(s.record); asked: \(hook ?? "fix")\n".utf8))
                    // Off only now: the fix below begins before anything else can.
                    end(false)
                    if case .updateVM = s.fix { self.state.startAfterUpdate = true }
                    // A test build's hook opens no System Settings pane.
                    if hook == nil || s.fix == .updateVM || s.fix == .updateApp { self.state.fixMacSetup(s, askMarker: false) }
                    self.showWindow()
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

// `OmacVM --key-access`: print macOS's current answer for "control the
// computer" (1 or 0) and quit. macOS answers CGPreflightPostEventAccess once
// per process and keeps that answer, so a grant given while the app runs only
// shows in a new process: KeyAccess.fresh asks through this one.
if CommandLine.arguments.dropFirst().first == "--key-access" {
    print(CGPreflightPostEventAccess() ? "1" : "0")
    exit(0)
}

// `OmacVM --vms-folder`: print where the VMs are and quit (no window), for
// `omacvm check` and the tests.
if CommandLine.arguments.dropFirst().first == "--vms-folder" {
    print(Paths.vmsRoot.path)
    exit(0)
}

// `OmacVM --settings-dump`: the VM window's settings as JSON (SettingsDump.swift).
if CommandLine.arguments.dropFirst().first == SettingsDump.flag {
    MainActor.assumeIsolated { SettingsDump.main() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
