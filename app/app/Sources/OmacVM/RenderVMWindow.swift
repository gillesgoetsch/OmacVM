import AppKit
import OmacVMUSB
import OmacVMUpdate
import OmacVMIcon
import OmacVMWindow
import SwiftUI
import OmacVMFeatures

/// --render-vm-window DIR (test builds and `swift build`, never the released
/// app): draws the app's window (header, window buttons, sidebar, settings)
/// for made-up VMs in a temporary folder, light and dark, into DIR/*.png: at
/// the height it opens with on a 13-inch MacBook Air (WindowSize), scrolled to
/// each section, each state and sheet; and the whole page of settings at
/// once. Writes DIR/heights.txt and exits 1 when something does not fit that
/// window (a sheet taller than it, a part outside the window's sides) or the
/// controls at the end of the rows are not on one line (WindowLayout). CI
/// runs it.
@MainActor
enum RenderVMWindow {
    /// What the pictures show instead of this Mac's answers.
    struct Preview {
        var keyNote: KeyNote?
        var terminal: CommandLineInstall.State?
        /// The app's OmacVM: Update VM when the VM's is older.
        var appVersion: String? = nil
        /// As on a Mac with a notch (Start in has "including notch").
        var notch = false
        var running: Bool? = nil
        /// Scrolled to this section.
        var section: String? = nil
        var sheet: ReadyView.ReadySheet? = nil
        var magicMouse: Bool? = false
        /// A display that can show HDR (the HDR row).
        var hdr: Bool? = false
        /// A display with headroom above 2x (the extra brightness row).
        var extraBrightness: Bool? = false
        /// macOS keeps the menu bar in full screen (#356).
        var menuBar: Bool? = false
        /// Disk › Change… open: what Omarchy needs, the size chosen.
        var disk: (need: DiskSize.Need, gb: Int)? = nil
        /// Skip the notch's (i) open.
        var notchSkipInfo: Bool? = nil
        /// This Mac not set up for the VM (the notice, the header's Update VM).
        var macSetup: MacSetup? = nil
    }

    static func allowed(bundleID: String?) -> Bool {
        bundleID == nil || TestHooks.allowed(bundleID: bundleID)
    }

    /// The window's height on a 13-inch MacBook Air.
    nonisolated static let smallHeight = WindowSize.defaultHeight(visible: WindowSize.smallScreenVisible)

    private static var lines: [String] = []
    private static var failed = false

    static func run(into dir: URL) -> Never {
        dirURL = dir
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omacvm-render-\(getpid())")
        let folder = tmp.appendingPathComponent("Omarchy")
        guard let config = makeVM(folder) else {
            print("could not make the VM folder in \(tmp.path)")
            exit(1)
        }
        // The settings the pictures change are this run's own, put back after.
        let saved = SavedDefaults()
        LayoutProbe.on = true
        let state = AppState(watchDrives: false)
        state.storage.shownRoot = tmp
        state.storage.refresh()
        state.config = config
        state.screen = .ready
        state.message = nil
        let u = Updater.shared
        let terminal = CommandLineInstall.State.installed(at: "/usr/local/bin/omacvm")
        let usual = Preview(keyNote: KeyNote.none, terminal: terminal, notch: true)

        // The usual state at its defaults, no update waiting: each section
        // as the window shows it on a 13-inch MacBook Air (with a notch).
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil, outcome: .upToDate)
        for (i, s) in SettingsNav.items.enumerated() {
            var p = usual
            p.section = s.id
            window("window-\(i + 1)-\(s.id)", state, p)
        }
        // Scrolled to the very bottom by hand: the last section is marked
        // (the sidebar follows the scroll down to the end).
        var end = usual
        end.section = SpyScroll<EmptyView>.end
        window("window-16-scrolled-to-end", state, end)
        // The whole page: as a Mac with a notch and as one without (the
        // Mac mini: Window and Full screen only).
        page("page-1-notch", state, usual)
        var noNotch = usual
        noNotch.notch = false
        page("page-2-no-notch", state, noNotch)

        // Everything on: notes under the switches, a disk job, a Magic Mouse,
        // custom resources, "including notch" chosen, keyboard not allowed.
        try? Data("on\n".utf8).write(to: folder.appendingPathComponent("fast-network"))
        try? USBSwitch.set(true, folder: folder)
        try? USBMemory(devices: [.init(vendor: "0483", product: "3748", name: "STM32 STLink", maker: "STMicroelectronics",
                                       choice: .omarchy, since: "2026-10-07")]).save(folder: folder)
        try? MacFolder.set(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"), for: config)
        try? VMDisk.setJobs([.grow], config)
        try? NotchArea.write(.fullpanel, folder: folder)
        var custom = config
        custom.cpus = 3
        custom.memoryMB = 6 * 1024
        try? custom.writeResources()
        state.config = custom
        var allOn = usual
        allOn.keyNote = .needsUser
        allOn.magicMouse = true
        allOn.hdr = true
        allOn.extraBrightness = true
        page("page-3-all-on", state, allOn)
        allOn.section = "general"
        window("window-6-custom-resources", state, allOn)
        // Including notch, ready, Keep the Dock away off, and macOS keeping
        // the menu bar in full screen: the note with Open Menu Bar Settings.
        try? Data().write(to: folder.appendingPathComponent(NotchArea.readyFileName))
        Settings.keepDockAway = false
        var menuBar = usual
        menuBar.menuBar = true
        menuBar.section = "display"
        window("window-15-notch-menu-bar", state, menuBar)
        Settings.keepDockAway = true
        // Skip the notch on, the VM ready for it; then not ready yet (its line
        // says what it needs); and its (i) on its own.
        try? NotchSkip.write(true, folder: folder)
        try? Data().write(to: folder.appendingPathComponent(NotchSkip.readyFileName))
        var skip = usual
        skip.section = "display"
        window("window-17-notch-skip", state, skip)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(NotchSkip.readyFileName))
        window("window-18-notch-skip-not-ready", state, skip)
        try? NotchSkip.write(false, folder: folder)
        sheet("popover-1-notch-skip") { NotchSkipInfo() }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(NotchArea.readyFileName))
        try? NotchArea.write(.native, folder: folder)
        try? VMDisk.setJobs([], config)
        try? config.writeResources()
        state.config = config

        // Disk › Change… open: a 128 GB disk with 9 GB used, a smaller size
        // chosen; and a 64 GB one, which cannot shrink, made larger.
        var disk = usual
        disk.section = "storage"
        _ = truncate(config.disk.path, 128 << 30)
        try? config.writeEnv(["DISK_GB": "128"])
        state.config = VMConfig.load(from: folder) ?? config
        disk.disk = (DiskSize.Need(allocated: 13 * DiskSize.gib, used: 9 * DiskSize.gib, rootStart: 2 * DiskSize.gib), 96)
        window("window-7-disk-smaller", state, disk)
        _ = truncate(config.disk.path, 64 << 30)
        try? config.writeEnv(["DISK_GB": "64"])
        state.config = config
        disk.disk = (DiskSize.Need(allocated: 13 * DiskSize.gib, used: 9 * DiskSize.gib, rootStart: 2 * DiskSize.gib), 128)
        window("window-8-disk-larger", state, disk)

        // An update is ready: the banner (and its What's New from the new
        // app's own CHANGELOG), stopped and while the VM runs.
        let staged = makeStagedApp(tmp, version: "3.1.1")
        u.showForRendering(staged: staged, notice: nil, enabled: true, waiting: false, previous: nil)
        window("window-9-update", state, usual)
        var updateRow = usual
        updateRow.section = "storage"
        window("window-9c-update-row", state, updateRow)
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil, checking: true, downloading: "3.1.1",
                             downloaded: (12_300_000, 34_800_000))
        window("window-9d-update-downloading", state, updateRow)
        u.showForRendering(staged: staged, notice: nil, enabled: true, waiting: false, previous: nil)
        var runs = usual
        runs.running = true
        window("window-10-update-vm-runs", state, runs)
        u.showForRendering(staged: staged, notice: Updater.waitingNotice("A VM runs from \(Product.name)", version: "3.1.1"),
                           enabled: true, waiting: true, previous: nil)
        window("window-11-update-waits", state, runs)
        u.showForRendering(staged: Updater.Staged(version: "3.1.1", app: URL(fileURLWithPath: "/nonexistent.app"),
                                                  notes: URL(string: "https://github.com/gillesgoetsch/OmacVM/releases"), teams: []),
                           notice: nil, enabled: true, waiting: false, previous: nil)
        window("window-12-update-no-changelog", state, usual)
        // Update VM asks before it builds a newer memory-optimized kernel.
        let screen = state.screen
        state.creator.showForRendering(kernel: .init(have: "7.2.10-1", latest: "7.2.11-1", cpus: 8, low: 20, high: 30))
        state.screen = .building
        window("window-20-update-kernel-question", state, usual)
        // Update VM: SSH turned the key down and the guest agent did not answer.
        state.creator.showForRendering(keyRefused: config)
        window("window-21-update-ssh-key", state, usual)
        state.screen = screen
        u.showForRendering(staged: staged, notice: nil, enabled: true, waiting: false, previous: nil)
        sheet("sheet-1-whats-new") { WhatsNewSheet(updater: u, running: false) {} }
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil)

        // This Mac not set up for the VM: a folder copied from another Mac
        // (the notice and the header's Update VM), the same with a VM from a
        // newer OmacVM, Gestures not allowed yet, the Bridge off in Login Items.
        var notSetUp = usual
        notSetUp.macSetup = MacSetup.parse("verdict\tsetup\nfix\tupdate-vm\nwhy\tother-mac\nhelpers\tOmacVM Bridge|OmacVM Gestures\n"
            + "helper\tOmacVM Bridge\tmissing\tnot installed\nhelper\tOmacVM Gestures\tmissing\tnot installed\n")
        window("window-22-mac-setup-copied", state, notSetUp)
        notSetUp.macSetup = MacSetup.parse("verdict\tsetup\nfix\tupdate-app\nwhy\tother-mac\nhelpers\tOmacVM Gestures\nversion\t3.1.28\nvm-version\t3.2.0\n")
        window("window-23-mac-setup-newer-vm", state, notSetUp)
        notSetUp.macSetup = MacSetup.parse("verdict\tpermission\nfix\tsettings\nhelpers\tOmacVM Gestures\nmissing\tAccessibility, Input Monitoring\n"
            + "helper\tOmacVM Gestures\tpermission\trunning, but Accessibility, Input Monitoring is off\n")
        window("window-24-mac-setup-permission", state, notSetUp)
        notSetUp.macSetup = MacSetup.parse("verdict\tlogin-items\nfix\tlogin-items\nhelpers\tOmacVM Bridge\n")
        notSetUp.running = true
        window("window-25-mac-setup-login-items-vm-runs", state, notSetUp)

        // Long names: a VM name of 62 characters, a deep VMs folder, a
        // message, an older OmacVM in the VM (Update VM).
        let longRoot = tmp.appendingPathComponent("A folder with a rather long name for the VMs of this Mac/and-one-more-level-light-test/vms")
        let longFolder = longRoot.appendingPathComponent("OmacVM Test with a very long VM name to check the window sides")
        if let long = makeVM(longFolder, name: longFolder.lastPathComponent) {
            try? Data("3.0.5\n".utf8).write(to: longFolder.appendingPathComponent("omacvm-version"))
            state.storage.shownRoot = longRoot
            state.storage.refresh()
            state.config = long
            state.tell("OmacVM in \(long.name) is now 3.0.5.")
            var p = usual
            p.appVersion = "3.1.0"
            p.keyNote = .needsUser
            window("window-13-long-names", state, p)
            p.section = "storage"
            window("window-14-long-names-storage", state, p)
            state.message = nil
            // The new VM's setup with the same VMs folder.
            state.screen = .setup
            window("setup-1", state, p)
            page("setup-2-page", state, p)
            state.screen = .ready
            state.config = config
            state.storage.shownRoot = tmp
            state.storage.refresh()
        } else {
            note("window-13-long-names: could not make the VM folder", fail: true)
        }

        // The other screens.
        state.screen = .driveMissing
        window("screen-1-drive-missing", state, usual)
        state.screen = .unavailable
        window("screen-2-unavailable", state, usual)
        state.screen = .install
        window("screen-3-install", state, usual)
        state.screen = .ready

        // The sheets: Delete (typed, and while the VM runs), All VMs, USB
        // devices, the icon's looks.
        sheet("sheet-2-delete") { DeleteSheet(vm: config, size: 9 * DiskSize.gib, running: false) { _ in } }
        sheet("sheet-3-delete-vm-runs") { DeleteSheet(vm: config, size: 9 * DiskSize.gib, running: true) { _ in } }
        let all = StorageModel()
        all.shownRoot = longRoot
        all.root = longRoot
        all.vms = [("Omarchy", 41), ("OmacVM Test with a very long VM name to check the window sides", 23), ("Bench", 9)].compactMap { n, gb in
            var c = VMConfig()
            c.name = n
            c.location = longRoot.appendingPathComponent(n)
            return StorageModel.Entry(config: c, size: Int64(gb) * DiskSize.gib, legacy: n == "Bench")
        }
        sheet("sheet-4-all-vms") { AllVMsView(storage: all, selected: all.vms.first?.folder) {} }
        usbPictures(folder: folder, into: dir)
        sheet("sheet-8-icon-looks") { AppIconPicker(selected: IconTheme.all[0]) { _ in } }
        // The (i) of Ghostty on the Mac's GPU, as its popover shows it (InfoButton).
        sheet("popover-3-ghostty-gpu") {
            Text(GhosttyGPURow.info).fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading).padding(14)
        }

        // The icon in every look, for the Dock.
        for t in IconTheme.all {
            if let tiff = AppIcon.image(t, size: 128).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("icon-\(t.id).png"))
            }
        }

        saved.restore()
        try? FileManager.default.removeItem(at: tmp)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("heights.txt"), atomically: true, encoding: .utf8)
        print(text, terminator: "")
        print("rendered into \(dir.path)")
        exit(failed ? 1 : 0)
    }

    private static func note(_ s: String, fail: Bool = false) {
        lines.append(s)
        if fail { failed = true }
    }

    // MARK: Pictures

    /// The window as the app makes it (main.swift), never on screen, at the
    /// 13-inch MacBook Air's height; checks that every part is inside it and
    /// the rows' controls end on one line.
    private static func window(_ name: String, _ state: AppState, _ preview: Preview, height: Double = smallHeight) {
        picture(name, into: dirURL, height: height) { RootView(state: state, preview: preview) }
        sides(name, height: height)
    }

    /// The window with this content, light and dark (the frames of the dark one stay in LayoutProbe).
    static func picture<V: View>(_ name: String, into dir: URL, height: Double = smallHeight, _ root: () -> V) {
        for dark in [false, true] {
            LayoutProbe.frames = [:]
            let w = PictureWindow.make(root().environment(\.controlActiveState, .key))
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.setContentSize(NSSize(width: WindowSize.width, height: height))
            settle(w)
            if let frame = w.contentView?.superview { WindowPicture.write(frame, "\(name)\(dark ? "-dark" : "")", into: dir) }
            w.contentViewController = nil
        }
    }

    /// The whole page of settings at once: a window tall enough for all of it.
    private static func page(_ name: String, _ state: AppState, _ preview: Preview) {
        window(name, state, preview, height: 2600)
        // Cut at the end of the content (the window's own pictures are the
        // check; this one is for reading).
    }

    /// A sheet's content on its own, light and dark: it must fit the window
    /// below its header.
    private static func sheet<V: View>(_ name: String, _ content: () -> V) {
        var height = 0.0
        for dark in [false, true] {
            LayoutProbe.frames = [:]
            let view = NSHostingView(rootView: content().environment(\.controlActiveState, .key))
            let w = PictureWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = view
            for _ in 0..<3 {
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            }
            height = Double(view.fittingSize.height)
            WindowPicture.write(view, "\(name)\(dark ? "-dark" : "")", into: dirURL)
            w.contentView = nil
        }
        let room = smallHeight - Double(Look.headerHeight) - 16
        let fits = height <= room
        note("\(name): \(Int(height.rounded())) pt" + (fits ? ", fits" : ", TOO TALL for the window (\(Int(room)) at most)"), fail: !fits)
    }

    private static func settle(_ w: NSWindow) {
        for _ in 0..<4 {
            w.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
    }

    /// Every part inside the window's sides; the rows' controls on one line
    /// (16 pt in from the card), the header's buttons at its margin.
    private static func sides(_ name: String, height: Double) {
        // The strips under the header and the sidebar run edge to edge.
        let boxes = LayoutProbe.boxes().filter { !["update-banner", "message", "notice"].contains($0.name) && !$0.name.hasPrefix("nav-") }
        let rowEnd = WindowLayout.width - WindowLayout.contentInset - WindowLayout.rowInset
        var problems = WindowLayout.problems(boxes, width: WindowLayout.width, trailing: ["start"])
        let rows = boxes.filter { $0.name.hasPrefix("trailing-") }
        // A legacy (always shown) scroll bar takes 15 pt off every row alike.
        if let first = rows.first {
            let off = rows.filter { abs($0.maxX - first.maxX) > WindowLayout.tolerance }
            if !off.isEmpty { problems.append("row ends not on one line: " + rows.map { "\($0.name) \(Int($0.maxX.rounded()))" }.joined(separator: ", ")) }
            if first.maxX > rowEnd + WindowLayout.tolerance { problems.append("rows end at \(Int(first.maxX)), past \(Int(rowEnd))") }
        }
        if let start = boxes.first(where: { $0.name == "start" }),
           abs(start.maxX - (WindowLayout.width - WindowLayout.inset)) > WindowLayout.tolerance {
            problems.append("Start ends at \(Int(start.maxX)), not at \(Int(WindowLayout.width - WindowLayout.inset))")
        }
        note("\(name): \(Int(WindowLayout.width)) x \(Int(height)) pt, sides " + (problems.isEmpty ? "ok" : "WRONG: " + problems.joined(separator: "; ")),
             fail: !problems.isEmpty)
        if ProcessInfo.processInfo.environment["OMACVM_RENDER_BOXES"] != nil {
            lines.append("  " + boxes.map { "\($0.name) \(Int($0.minX.rounded()))-\(Int($0.maxX.rounded()))" }.joined(separator: ", "))
        }
    }

    private static var dirURL = URL(fileURLWithPath: CommandLine.arguments.last ?? ".")

    // MARK: Made-up things

    /// Made-up devices: two remembered (one plugged in), one new, two macOS keeps.
    static let usbDevices: [USBDevice] = {
        typealias I = USBDevice.Interface
        return [
            USBDevice(id: USBDeviceID(vendor: 0x0483, product: 0x3748), name: "STM32 STLink", deviceClass: 0,
                      interfaces: [I(number: 0, interfaceClass: 0xff, users: [])], maker: "STMicroelectronics",
                      location: 0x0110_0000, address: 3),
            USBDevice(id: USBDeviceID(vendor: 0x0bda, product: 0x2838), name: "RTL2838UHIDIR", deviceClass: 0,
                      interfaces: [I(number: 0, interfaceClass: 0xff, users: [])], maker: "Realtek",
                      location: 0x0120_0000, address: 4),
            USBDevice(id: USBDeviceID(vendor: 0x1050, product: 0x0407), name: "YubiKey OTP+FIDO+CCID", deviceClass: 0,
                      interfaces: [I(number: 0, interfaceClass: 3, users: ["AppleUserUSBHostHIDDevice"])],
                      location: 0x0130_0000, address: 5),
            USBDevice(id: USBDeviceID(vendor: 0x0781, product: 0x5581), name: "Ultra", deviceClass: 0,
                      interfaces: [I(number: 0, interfaceClass: 8, users: ["IOUSBMassStorageInterfaceNub"])],
                      location: 0x0140_0000, address: 6),
        ]
    }()

    private static func usbPictures(folder: URL, into dir: URL) {
        let memory = USBMemory(devices: [
            .init(vendor: "0483", product: "3748", name: "STM32 STLink", maker: "STMicroelectronics", choice: .omarchy, since: "2026-10-07"),
            .init(vendor: "1d50", product: "6089", name: "HackRF One", maker: "Great Scott Gadgets", choice: .mac, since: "2026-10-07"),
        ])
        let before = USBListRows.make(memory: memory, devices: usbDevices, states: nil, vmName: "Omarchy")
        sheet("sheet-5-usb-before-start") { USBDeviceList(source: .picture(before, running: false), vmName: "Omarchy") {} }
        let running = USBListRows.make(memory: memory, devices: usbDevices,
                                       states: [0x0110_0000: .connected, 0x0120_0000: .onMac(remembered: false)], vmName: "Omarchy")
        sheet("sheet-6-usb-running") { USBDeviceList(source: .picture(running, running: true), vmName: "Omarchy", showsTitle: false) {} }
        sheet("sheet-7-usb-empty") { USBDeviceList(source: .picture(USBListRows(), running: false), vmName: "Omarchy") {} }
        // The question, as USBAlertAsker shows it (light and dark).
        let q = USBQuestion(device: usbDevices[0], vmName: "Omarchy", waiting: 0)
        for dark in [false, true] {
            let a = USBAlertAsker.alert(q)
            a.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            a.layout()
            if let v = a.window.contentView {
                v.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                WindowPicture.write(v, "usb-ask\(dark ? "-dark" : "")", into: dir)
            }
        }
        lines.append("usb-ask: \(q.title) [\(q.connect)] [\(q.keep)] [ ] \(q.always)")
    }

    /// A VM folder as a build leaves it: vm.env, a 64 GB sparse disk.img,
    /// efi-vars.fd, the ready mark.
    private static func makeVM(_ folder: URL, name: String = "Omarchy") -> VMConfig? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
            // Balanced on this Mac: the usual choice.
            let t = Mac.tier(1)
            try "NAME='\(name)'\nCPUS=\(t.cpus)\nMEM_MB=\(t.memoryGB * 1024)\nDISK_GB=64\nSSH_PORT=52222\nVM_USER=omarchy\n"
                .write(to: folder.appendingPathComponent("vm.env"), atomically: true, encoding: .utf8)
            fm.createFile(atPath: folder.appendingPathComponent("efi-vars.fd").path, contents: Data())
            fm.createFile(atPath: folder.appendingPathComponent("ready").path, contents: Data())
            let disk = folder.appendingPathComponent("disk.img")
            fm.createFile(atPath: disk.path, contents: Data(count: 8 << 20))
            guard truncate(disk.path, 64 << 30) == 0 else { return nil }
        } catch {
            return nil
        }
        return VMConfig.load(from: folder)
    }

    /// A downloaded app as Updater stages it, with this repo's CHANGELOG.md
    /// under the new version's title.
    private static func makeStagedApp(_ tmp: URL, version: String) -> Updater.Staged {
        let app = tmp.appendingPathComponent("staged/OmacVM.app")
        let res = app.appendingPathComponent("Contents/Resources/omacvm")
        try? FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        let changelog = """
        # Changelog

        ## \(version)

        A new settings window: everything about a VM on one page.

        - OmacVM.app: **the VM's settings** in one window with a sidebar: General, Display, Input, Sharing & Devices, \
        Storage & Updates. Resources and the disk's size change in the window itself.
        - **Swipe out to macOS**: past the first or last workspace, a swipe goes on to the macOS Space beside the VM \
        (#342, by @epicoun).
        - **Closing the window** can keep the VM running or ask (#358, by @Vocllum).
        - The update banner says what is new, with `What's New` for the whole list.

        ## 3.0.18

        - Earlier things.
        """
        try? changelog.write(to: res.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
        return Updater.Staged(version: version, app: app, notes: URL(string: "https://github.com/gillesgoetsch/OmacVM/releases/tag/v\(version)"),
                              teams: [])
    }
}

/// An offscreen window that draws as the window in front would.
@MainActor
final class PictureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }

    static func make<V: View>(_ root: V) -> NSWindow {
        let w = PictureWindow(contentRect: NSRect(x: 0, y: 0, width: WindowSize.width, height: RenderVMWindow.smallHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        let bar = NSToolbar(identifier: "OmacVM.picture")
        bar.allowsUserCustomization = false
        w.toolbar = bar
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        w.contentViewController = host
        return w
    }
}

/// The app's own settings, put back as they were after the pictures.
@MainActor
private struct SavedDefaults {
    let app: [String: Any]

    init() {
        app = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
    }

    func restore() {
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.setPersistentDomain(app, forName: id) }
    }
}
