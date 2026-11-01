import AppKit
import OmacVMDesktop
import OmacVMFeatures
import OmacVMWindow
import SwiftUI

/// The VM window before Start (docs/design/settings-3.1): the header with
/// the VM and Start, the update banner, and the VM's settings in five
/// sections with the sidebar. Every row reads and writes the same setting as
/// before 3.1 (AGENTS.md, "Settings"), so an update keeps every choice; what
/// `omacvm` or the control centre changed shows when the window comes back
/// to the front.
struct ReadyView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updater = Updater.shared
    /// The window pictures (--render-vm-window): this keyboard note and this
    /// "omacvm in Terminal" state instead of the Mac's, and more.
    var preview: RenderVMWindow.Preview? = nil
    @State private var sheet: ReadySheet?
    /// The VM to delete runs (or omacvm works on it): asked once, when the sheet opens.
    @State private var deleteBusy = false

    enum ReadySheet: Identifiable {
        case delete(VMConfig), whatsNew
        var id: String {
            switch self {
            case .delete(let c): return "delete-" + c.folder.path
            case .whatsNew: return "whats-new"
            }
        }
    }

    private var running: Bool { preview?.running ?? state.vmRunning() }
    /// Is this Mac set up for the VM (MacSetup): the window pictures' own.
    private var macSetup: MacSetup? { preview?.macSetup ?? state.macSetup }

    var body: some View {
        WindowShell(nav: SettingsNav.items) {
            header
        } notices: {
            UpdateBanner(updater: updater, running: running) { sheet = .whatsNew }
            notices
        } content: {
            SettingsSections(state: state, preview: preview, running: running) { vm in
                deleteBusy = preview?.running ?? !Storage.busyFolders([vm.folder]).isEmpty
                sheet = .delete(vm)
            }
        }
        .environment(\.spyStart, preview?.section)
        .sheet(item: $sheet) { s in
            switch s {
            case .delete(let vm):
                DeleteSheet(vm: vm, size: state.storage.vms.first { $0.folder.path == vm.folder.path }?.size,
                            running: deleteBusy) { delete in
                    sheet = nil
                    if delete { state.storage.trash(vm) }
                }
            case .whatsNew:
                WhatsNewSheet(updater: updater, running: running) { sheet = nil }
            }
        }
        .onAppear { if let s = preview?.sheet { sheet = s } }
        // `omacvm`, the control centre or another window may have changed a
        // setting meanwhile: read them again (every row follows state.tick).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.reloadSettings()
            // Back from System Settings, or a helper installed meanwhile.
            if preview == nil { state.refreshMacSetup() }
        }
        .onAppear { if preview == nil { state.refreshMacSetup() } }
        .onChange(of: state.config.folder) { _, _ in if preview == nil { state.refreshMacSetup() } }
        .task {
            while !Task.isCancelled && preview == nil {
                try? await Task.sleep(for: .seconds(3))
                // Only while the window shows (not while a VM runs and it is put away).
                if NSApp.windows.contains(where: { $0.isVisible && $0.contentViewController is NSHostingController<RootView> }) {
                    state.reloadSettings()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        WindowHeader(title: state.config.name,
                     pill: running ? StatusPill(text: "Running", dot: Look.green) : StatusPill(text: "Stopped"),
                     facts: "\(state.config.cpus) CPUs · \(state.config.memoryMB / 1024) GB memory · \(state.config.diskGB) GB disk"
                         + (state.config.user.isEmpty ? "" : " · user \(state.config.user)"),
                     factsInfo: factsInfo) {
            AppIconButton()
        } trailing: {
            let app = preview?.appVersion ?? OmacVMVersion.app
            let behind = app.map { OmacVMVersion.vmIsBehind(state.config.guestVersion, app: $0) } ?? false
            // Also when this Mac's helpers are not set up for the VM (a VM
            // copied at the same version had no Update VM anywhere).
            if behind || macSetup?.wantsUpdateVM == true {
                Button {
                    state.updateVM()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Look.orange).frame(width: 6, height: 6)
                        Text("Update VM")
                    }
                }
                .help(behind
                      ? "OmacVM in this VM is \(state.config.guestVersion.map { "\($0)" } ?? "from an older app"); this app has \(app ?? ""). Update VM starts the VM without a window, updates OmacVM in it and its helpers on the Mac (a few minutes) and shuts it down. Your files and settings in Omarchy stay."
                      : "\(macSetup?.title(vm: state.config.name) ?? ""). Update VM starts the VM without a window, sets up its helpers on this Mac and gives the VM this Mac's token (a few minutes), then shuts it down. Your files and settings in Omarchy stay.")
                .disabled(state.storage.moving != nil || state.config.filesProblem != nil || running)
                .layoutProbe("update-vm")
            }
            Button(running ? "Show" : "Start") {
                if running { state.showVM() } else { state.startVM() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!running && (state.storage.moving != nil || state.config.filesProblem != nil))
            .layoutProbe("start")
        }
    }

    /// The VM's memory and its graphics memory side by side: the VM's RAM is
    /// fixed, its graphics come from the Mac on top, as needed (GPUMemory).
    private var factsInfo: String {
        "Set when the VM was made. CPUs and memory change under General, the disk under Storage. "
            + "\(GPUMemory.lastRun(GPUMemory.read(for: state.config)))\n\n\(GPUMemory.explanation)"
    }

    // MARK: Notices under the header

    @ViewBuilder private var notices: some View {
        // While an update waits for the VM, the banner says so already.
        if let n = updater.notice, !(updater.staged != nil && updater.installWhenIdle) {
            MessageStrip(text: n) { updater.notice = nil }
        }
        if let m = state.message {
            MessageStrip(text: m, error: !state.messageIsInfo) { state.message = nil }
        }
        if let p = state.config.filesProblem {
            MessageStrip(text: p, error: true)
        }
        // This Mac is not set up for the VM (a folder copied from another
        // Mac, a helper not allowed): said here as long as it is so, with
        // what fixes it. Later in the question before a start does not hide it.
        if let s = macSetup, s.needsAction, state.config.filesProblem == nil {
            NoticeStrip(text: s.notice(vm: state.config.name), info: s.info(vm: state.config.name), action: s.button,
                        disabled: s.fix == .updateVM && (running || state.storage.moving != nil)) {
                state.fixMacSetup(s)
            }
        }
    }
}

extension EnvironmentValues {
    /// The window pictures: the section the settings start scrolled to.
    @Entry var spyStart: String? = nil
}

/// The six sections: General, Display, Input, Output (the sound), Sharing & Devices,
/// Storage & Updates.
struct SettingsSections: View {
    @ObservedObject var state: AppState
    var preview: RenderVMWindow.Preview?
    var running: Bool
    var delete: (VMConfig) -> Void
    @StateObject private var mouse = MagicMouseWatch()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "General", first: true)
            Card {
                ResourcesRow(state: state)
                GraphicsRow(state: state)
                GPUComputeRow(state: state)
                GPUOffMainLoopRow(tick: state.tick)
                VKWindowsNoCopyRow(tick: state.tick)
                GhosttyGPURow(tick: state.tick, folder: state.config.folder, running: running)
                CloseActionRow(tick: state.tick)
            }
        }
        .spySection("general")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Display")
            Card {
                StartInRow(state: state, previewNotch: preview?.notch, previewMenuBar: preview?.menuBar)
                if preview?.notch ?? Mac.hasNotch {
                    NotchSkipRow(state: state, previewInfo: preview?.notchSkipInfo ?? false)
                }
                KeepDockAwayRow(tick: state.tick)
                if preview?.hdr ?? Mac.hasHDRDisplay {
                    HDRRow(tick: state.tick, folder: state.config.folder, running: running)
                }
                if preview?.extraBrightness ?? Mac.hasExtraBrightnessDisplay {
                    ExtraBrightnessRow(tick: state.tick)
                }
                PauseWhileHiddenRow(tick: state.tick)
                PointerPlaneRow(tick: state.tick)
                PresentTilesRow(tick: state.tick)
                EscapeRow(tick: state.tick)
                if preview?.magicMouse ?? mouse.connected {
                    MagicMouseRow(tick: state.tick, gesturesOff: VMRecord.isOff("gestures", folder: state.config.folder))
                }
            }
        }
        .spySection("display")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Input")
            Card {
                KeyboardRow(state: state, preview: preview?.keyNote)
                MacIMERow(state: state)
                SwipeOutRow(tick: state.tick, gesturesOff: VMRecord.isOff("gestures", folder: state.config.folder))
                ShareKeyboardRow(tick: state.tick)
            }
        }
        .spySection("input")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Output")
            Card {
                SoundThreadRow(tick: state.tick)
                MediaControlsRow(tick: state.tick)
            }
        }
        .spySection("output")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Sharing & Devices")
            Card {
                MacFolderRow(state: state)
                USBRow(state: state)
                FastNetworkRow(state: state)
            }
        }
        .spySection("sharing")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Storage & Updates")
            Card {
                DiskRow(state: state, preview: preview?.disk)
                StorageRows(storage: state.storage, selected: state.config.location == nil ? nil : state.config.folder,
                            open: { state.openExisting() }, delete: delete)
                CommandLineRow(preview: preview?.terminal)
                UpdateRow(updater: Updater.shared, running: running)
            }
            ForEach(state.storage.disconnected, id: \.self) { line in
                Text(line).font(.subheadline).foregroundStyle(Look.red).padding(.top, 8).padding(.horizontal, 4)
            }
            if let n = state.storage.note {
                Text(n).font(.subheadline).foregroundStyle(state.storage.noteIsError ? Look.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 8).padding(.horizontal, 4)
            }
            Button("Delete VM…") { delete(state.config) }
                .buttonStyle(.plain)
                .foregroundStyle(Look.red)
                .disabled(state.storage.moving != nil)
                .padding(.top, 14)
                .padding(.leading, 4)
                .layoutProbe("delete")
        }
        .spySection("storage")
    }
}
