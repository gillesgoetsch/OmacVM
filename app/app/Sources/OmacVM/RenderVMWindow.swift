import AppKit
import OmacVMUSB
import OmacVMUpdate
import OmacVMWindow
import SwiftUI

/// --render-vm-window DIR (test builds and `swift build`, never the released
/// app): draws the VM window before Start for a made-up VM in a temporary
/// folder, light and dark, into DIR/*.png, writes each window's height into
/// DIR/heights.txt and exits 1 when the usual state or the keyboard warning
/// is taller than a 13-inch MacBook shows (WindowFit). CI runs it.
@MainActor
enum RenderVMWindow {
    /// What the pictures show instead of this Mac's answers.
    struct Preview {
        var keyNote: KeyNote?
        var terminal: CommandLineInstall.State?
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
        let state = AppState()
        state.config = config
        state.screen = .ready
        state.message = nil
        let u = Updater.shared
        let terminal = CommandLineInstall.State.available(target: "/usr/local/bin/omacvm", needsAdmin: true)
        let titleBar = Double(FitScrollScreen.titleBar)
        var lines: [String] = []
        var failed = false

        func picture(_ name: String, _ preview: Preview, mustFit: Bool) {
            let h = draw(name, into: dir) { RootView(state: state, scrolls: false, preview: preview) }
            let window = WindowFit.windowHeight(content: h, titleBar: titleBar)
            let fits = WindowFit.fitsSmallScreen(content: h, titleBar: titleBar)
            lines.append("\(name): window \(Int(window.rounded())) pt (content \(Int(h.rounded())) + title bar \(Int(titleBar)))"
                         + (mustFit ? (fits ? ", fits" : ", TOO TALL (\(Int(WindowFit.smallScreenHeight)) at most)") : ""))
            if mustFit && !fits { failed = true }
        }

        // The usual state: everything at its default, no update waiting.
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil)
        picture("vm-window-1-usual", Preview(keyNote: KeyNote.none, terminal: terminal), mustFit: true)
        picture("vm-window-2-keyboard", Preview(keyNote: .needsUser, terminal: terminal), mustFit: true)

        // Everything on: the lines under the switches, a disk job, a check's result.
        try? Data("on\n".utf8).write(to: folder.appendingPathComponent("fast-network"))
        try? USBSwitch.set(true, folder: folder)
        try? USBChoice.save([USBChoice.Entry(id: USBDeviceID(text: "0483:3748")!, name: "STM32 STLink")], folder: folder)
        try? MacFolder.set(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"), for: config)
        try? VMDisk.setJobs([.grow], config)
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil, outcome: .upToDate)
        picture("vm-window-3-all-on", Preview(keyNote: .allowedNextStart, terminal: .installed(at: "/usr/local/bin/omacvm")), mustFit: false)

        // An update waits: the banner above Start.
        let staged = Updater.Staged(version: "3.0.5", app: URL(fileURLWithPath: "/nonexistent.app"),
                                    notes: URL(string: "https://github.com/gillesgoetsch/omacvm/releases"), teams: [])
        u.showForRendering(staged: staged, notice: nil, enabled: true, waiting: false, previous: nil)
        picture("vm-window-4-update", Preview(keyNote: KeyNote.none, terminal: terminal), mustFit: false)

        // A short screen: the window stops at its height and the rest scrolls.
        let limit: CGFloat = 480
        u.showForRendering(staged: nil, notice: nil, enabled: true, waiting: false, previous: nil)
        let h = draw("vm-window-5-scrolls", into: dir) {
            FitScroll(limit: limit) { RootView(state: state, scrolls: false, preview: Preview(keyNote: .needsUser, terminal: terminal)) }
                .frame(width: 568)
        }
        let scrolls = h <= Double(limit) + 1
        lines.append("vm-window-5-scrolls: content \(Int(h.rounded())) pt for a limit of \(Int(limit))" + (scrolls ? ", scrolls" : ", DOES NOT STOP"))
        if !scrolls { failed = true }

        // Disk › Change…: the size slider for a 128 GB disk with 9 GB used (on a Mac with 300 GB free).
        let info = VMDisk.Info(maxBytes: 128 * DiskSize.gib, usedBytes: 11 * DiskSize.gib, freeBytes: 300 * DiskSize.gib)
        let need = DiskSize.Need(allocated: 13 * DiskSize.gib, used: 9 * DiskSize.gib, rootStart: 2 * DiskSize.gib)
        draw("vm-window-6-disk-size", into: dir) { DiskSizeSheet(state: state, info: info, done: {}, preview: need) }
        draw("vm-window-7-disk-smaller", into: dir) { DiskSizeSheet(state: state, info: info, done: {}, preview: need, previewGB: 96) }

        try? FileManager.default.removeItem(at: tmp)
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: dir.appendingPathComponent("heights.txt"), atomically: true, encoding: .utf8)
        print(text, terminator: "")
        print("rendered into \(dir.path)")
        exit(failed ? 1 : 0)
    }

    /// A VM folder as a build leaves it: vm.env, a 64 GB sparse disk.img,
    /// efi-vars.fd, the ready mark.
    private static func makeVM(_ folder: URL) -> VMConfig? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
            try "NAME='Omarchy'\nCPUS=6\nMEM_MB=12288\nDISK_GB=64\nSSH_PORT=52222\nVM_USER=omarchy\n"
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

    /// In an offscreen window that is never ordered in, light and dark (a
    /// new view each); returns the content's height.
    @discardableResult
    private static func draw<V: View>(_ name: String, into dir: URL, _ content: () -> V) -> Double {
        var height = 0.0
        for dark in [false, true] {
            let view = NSHostingView(rootView: content().background(Color(nsColor: .windowBackgroundColor)))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 400), styleMask: [.borderless],
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
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            WindowPicture.write(view, "\(name)\(dark ? "-dark" : "")", into: dir)
            w.contentView = nil
        }
        return height
    }
}
