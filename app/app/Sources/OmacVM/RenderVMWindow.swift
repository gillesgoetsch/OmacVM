import AppKit
import OmacVMUSB
import OmacVMUpdate
import OmacVMWindow
import SwiftUI
import OmacVMFeatures

/// --render-vm-window DIR (test builds and `swift build`, never the released
/// app): draws the VM window before Start for a made-up VM in a temporary
/// folder, light and dark, into DIR/*.png, writes each window's height into
/// DIR/heights.txt and exits 1 when the usual state or the keyboard warning
/// is taller than a 13-inch MacBook shows (WindowFit), or when a part of a
/// window is closer than its 20 pt inset to a side or its buttons at the end of a
/// row do not end on one line (WindowLayout). CI runs it.
@MainActor
enum RenderVMWindow {
    /// What the pictures show instead of this Mac's answers.
    struct Preview {
        var keyNote: KeyNote?
        var terminal: CommandLineInstall.State?
        /// The app's OmacVM: "OmacVM in this VM" and Update VM when the VM's is older.
        var appVersion: String? = nil
        /// Draw the window as on a Mac with a notch (the notch area switch).
        var notch = false
    }

    static func allowed(bundleID: String?) -> Bool {
        bundleID == nil || TestHooks.allowed(bundleID: bundleID)
    }

    static func run(into dir: URL) -> Never {
        NSApp.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omacvm-render-\(getpid())")
        let folder = tmp.appendingPathComponent("Omarchy")
        guard let config = makeVM(folder) else {
            print("could not make the VM folder in \(tmp.path)")
            exit(1)
        }
        LayoutProbe.on = true
        let state = AppState(watchDrives: false)
        state.storage.shownRoot = tmp
        state.storage.refresh()
        state.config = config
        state.screen = .ready
        state.message = nil
        let u = Updater.shared
        let terminal = CommandLineInstall.State.available(target: "/usr/local/bin/omacvm", needsAdmin: true)
        let titleBar = Double(FitScrollScreen.titleBar)
        var lines: [String] = []
        var failed = false

        func sides(_ name: String, trailing: [String]) {
            let p = WindowLayout.problems(LayoutProbe.boxes(), width: Double(lastWidth), trailing: trailing)
            lines.append("\(name): sides " + (p.isEmpty ? "ok" : "WRONG: " + p.joined(separator: "; ")))
            // The frames: on a failure, or always with OMACVM_RENDER_BOXES=1.
            if !p.isEmpty || ProcessInfo.processInfo.environment["OMACVM_RENDER_BOXES"] != nil {
                lines.append("  width \(Int(lastWidth)): " + LayoutProbe.boxes().map { "\($0.name) \(Int($0.minX.rounded()))-\(Int($0.maxX.rounded()))" }.joined(separator: ", "))
            }
            if !p.isEmpty { failed = true }
        }

        func picture(_ name: String, _ preview: Preview, mustFit: Bool) {
            let h = draw(name, into: dir) { RootView(state: state, scrolls: false, preview: preview) }
            sides(name, trailing: ["folder-change", "update-vm", "start"])
            let window = WindowFit.windowHeight(content: h, titleBar: titleBar)
            let fits = WindowFit.fitsSmallScreen(content: h, titleBar: titleBar)
            lines.append("\(name): window \(Int(window.rounded())) pt (content \(Int(h.rounded())) + title bar \(Int(titleBar)))"
                         + (mustFit ? (fits ? ", fits" : ", TOO TALL (\(Int(WindowFit.smallScreenHeight)) at most)") : ""))
            if mustFit && !fits { failed = true }
        }

        // The usual state: everything at its default, no update waiting.
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil)
        // As on a MacBook Air 13": its notch adds the notch area switch.
        picture("vm-window-1-usual", Preview(keyNote: KeyNote.none, terminal: terminal, notch: true), mustFit: true)
        picture("vm-window-2-keyboard", Preview(keyNote: .needsUser, terminal: terminal, notch: true), mustFit: true)

        // Everything on: the lines under the switches, a disk job, a check's result.
        try? Data("on\n".utf8).write(to: folder.appendingPathComponent("fast-network"))
        try? USBSwitch.set(true, folder: folder)
        try? USBMemory(devices: [.init(vendor: "0483", product: "3748", name: "STM32 STLink", maker: "STMicroelectronics",
                                       choice: .omarchy, since: "2026-10-07")]).save(folder: folder)
        try? MacFolder.set(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"), for: config)
        try? VMDisk.setJobs([.grow], config)
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil, outcome: .upToDate)
        try? NotchArea.write(.fullpanel, folder: folder)
        picture("vm-window-3-all-on", Preview(keyNote: .allowedNextStart, terminal: .installed(at: "/usr/local/bin/omacvm"), notch: true), mustFit: false)
        try? NotchArea.write(.native, folder: folder)

        // An update waits: the banner above Start.
        let staged = Updater.Staged(version: "3.0.5", app: URL(fileURLWithPath: "/nonexistent.app"),
                                    notes: URL(string: "https://github.com/gillesgoetsch/omacvm/releases"), teams: [])
        u.showForRendering(staged: staged, notice: nil, enabled: true, waiting: false, previous: nil)
        picture("vm-window-4-update", Preview(keyNote: KeyNote.none, terminal: terminal), mustFit: false)

        // Long names: a VMs folder deep in a long path, a VM name of 62
        // characters, a message and an older OmacVM in the VM (Update VM).
        let longRoot = tmp.appendingPathComponent("A folder with a rather long name for the VMs of this Mac/and-one-more-level-light-test/vms")
        let longFolder = longRoot.appendingPathComponent("OmacVM Test with a very long VM name to check the window sides")
        if let long = makeVM(longFolder, name: longFolder.lastPathComponent) {
            try? Data("3.0.5\n".utf8).write(to: longFolder.appendingPathComponent("omacvm-version"))
            state.storage.shownRoot = longRoot
            state.storage.refresh()
            state.config = long
            state.message = "OmacVM in \(long.name) is now 3.0.5."
            u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil)
            picture("vm-window-8-long-names", Preview(keyNote: .needsUser, terminal: terminal, appVersion: "3.0.7"), mustFit: false)
            // The new VM's form with the same VMs folder.
            state.message = nil
            state.screen = .setup
            draw("setup-1-long-names", into: dir) { RootView(state: state, scrolls: false) }
            sides("setup-1-long-names", trailing: ["folder-change", "start"])
            state.screen = .ready
            state.config = config
            state.storage.shownRoot = tmp
            state.storage.refresh()
        } else {
            lines.append("vm-window-8-long-names: could not make the VM folder")
            failed = true
        }
        // The VMs folder of the window of 2026-10-08 (a test identity's, in
        // the home folder; not read: no such folder).
        state.storage.shownRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OmacVM-render-none/work/night-test/vms")
        state.storage.refresh()
        try? Data("3.0.5\n".utf8).write(to: folder.appendingPathComponent("omacvm-version"))
        picture("vm-window-9-home-folder", Preview(keyNote: KeyNote.none, terminal: terminal, appVersion: "3.0.6"), mustFit: false)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("omacvm-version"))
        state.storage.shownRoot = tmp
        state.storage.refresh()

        // All VMs… with long names.
        let all = StorageModel()
        all.vms = [("Omarchy", 41), ("OmacVM Test with a very long VM name to check the window sides", 23), ("Bench", 9)].compactMap { n, gb in
            var c = VMConfig()
            c.name = n
            c.location = longRoot.appendingPathComponent(n)
            return StorageModel.Entry(config: c, size: Int64(gb) * DiskSize.gib, legacy: false)
        }
        draw("all-vms-long-names", into: dir) { AllVMsView(storage: all, selected: all.vms.first?.folder) {} }
        sides("all-vms-long-names", trailing: ["all-vms-row", "all-vms-done"])

        // A short screen: the window stops at its height and the rest scrolls.
        let limit: CGFloat = 480
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil)
        let h = draw("vm-window-5-scrolls", into: dir) {
            FitScroll(limit: limit) { RootView(state: state, scrolls: false, preview: Preview(keyNote: .needsUser, terminal: terminal)) }
                .frame(width: WindowLayout.width)
        }
        let scrolls = h <= Double(limit) + 1
        lines.append("vm-window-5-scrolls: content \(Int(h.rounded())) pt for a limit of \(Int(limit))" + (scrolls ? ", scrolls" : ", DOES NOT STOP"))
        if !scrolls { failed = true }

        // Disk › Change…: the size slider for a 128 GB disk with 9 GB used (on a Mac with 300 GB free).
        let info = VMDisk.Info(maxBytes: 128 * DiskSize.gib, usedBytes: 11 * DiskSize.gib, freeBytes: 300 * DiskSize.gib)
        let need = DiskSize.Need(allocated: 13 * DiskSize.gib, used: 9 * DiskSize.gib, rootStart: 2 * DiskSize.gib)
        draw("vm-window-6-disk-size", into: dir) { DiskSizeSheet(state: state, info: info, done: {}, preview: need) }
        draw("vm-window-7-disk-smaller", into: dir) { DiskSizeSheet(state: state, info: info, done: {}, preview: need, previewGB: 96) }
        // USB devices: the list before a start and while the VM runs, and the question.
        usbPictures(folder: folder, into: dir, lines: &lines)

        try? FileManager.default.removeItem(at: tmp)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("heights.txt"), atomically: true, encoding: .utf8)
        print(text, terminator: "")
        print("rendered into \(dir.path)")
        exit(failed ? 1 : 0)
    }

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

    private static func usbPictures(folder: URL, into dir: URL, lines: inout [String]) {
        let memory = USBMemory(devices: [
            .init(vendor: "0483", product: "3748", name: "STM32 STLink", maker: "STMicroelectronics", choice: .omarchy, since: "2026-10-07"),
            .init(vendor: "1d50", product: "6089", name: "HackRF One", maker: "Great Scott Gadgets", choice: .mac, since: "2026-10-07"),
        ])
        let before = USBListRows.make(memory: memory, devices: usbDevices, states: nil, vmName: "Omarchy")
        let h1 = draw("usb-list-1-before-start", into: dir) {
            USBDeviceList(source: .picture(before, running: false), vmName: "Omarchy") {}
        }
        let running = USBListRows.make(memory: memory, devices: usbDevices,
                                       states: [0x0110_0000: .connected, 0x0120_0000: .onMac(remembered: false)], vmName: "Omarchy")
        let h2 = draw("usb-list-2-running", into: dir) {
            USBDeviceList(source: .picture(running, running: true), vmName: "Omarchy") {}
        }
        let h3 = draw("usb-list-3-empty", into: dir) {
            USBDeviceList(source: .picture(USBListRows(), running: false), vmName: "Omarchy") {}
        }
        lines.append("usb-list: before start \(Int(h1.rounded())) pt, running \(Int(h2.rounded())) pt, empty \(Int(h3.rounded())) pt")
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
            try "NAME='\(name)'\nCPUS=6\nMEM_MB=12288\nDISK_GB=64\nSSH_PORT=52222\nVM_USER=omarchy\n"
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

    /// The width of the last picture drawn.
    private static var lastWidth: CGFloat = 0

    /// In an offscreen window that is never ordered in, light and dark (a
    /// new view each); returns the content's height. LayoutProbe then has
    /// the frames of the dark one.
    @discardableResult
    private static func draw<V: View>(_ name: String, into dir: URL, _ content: () -> V) -> Double {
        var height = 0.0
        for dark in [false, true] {
            LayoutProbe.frames = [:]
            let view = NSHostingView(rootView: content().background(Color(nsColor: .windowBackgroundColor)))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WindowLayout.width, height: 400), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = view
            // SwiftUI settles on the next passes of the run loop (FitScroll
            // learns its content's height there).
            for _ in 0..<3 {
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            }
            height = Double(view.fittingSize.height)
            lastWidth = view.fittingSize.width
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            WindowPicture.write(view, "\(name)\(dark ? "-dark" : "")", into: dir)
            w.contentView = nil
        }
        return height
    }
}
