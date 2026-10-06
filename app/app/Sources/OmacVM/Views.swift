import AppKit
import ApplicationServices
import Combine
import OmacVMFeatures
import SwiftUI

/// What the launcher window shows.
enum Screen: Equatable {
    case install
    case setup
    case building
    case ready
    case driveMissing
}

@MainActor
final class AppState: ObservableObject {
    @Published var screen: Screen = .setup
    @Published var config: VMConfig
    @Published var message: String?
    let creator = Creator()
    let storage = StorageModel()
    var startVM: () -> Void = {}

    init() {
        (config, screen) = Self.start()
        afterInstall = screen
        if !Installer.isInstalled { screen = .install }
        storage.onMoved = { [weak self] in self?.reload() }
        // The views read the storage through this state too (Start waits for a move).
        storageChanges = storage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    private var storageChanges: AnyCancellable?

    /// The VM to show and the screen for it: the VM the app finds, else a
    /// new one (or the note that the VMs folder's drive is not connected).
    private static func start() -> (VMConfig, Screen) {
        if let existing = VMConfig.existing() {
            return (existing, existing.isReady ? .ready : .setup)
        }
        var c = VMConfig()
        let t = Mac.tier(1)
        c.cpus = t.cpus
        c.memoryMB = t.memoryGB * 1024
        c.user = Mac.linuxUserName
        c.fullName = NSFullUserName()
        c.timeZone = Mac.timeZone
        c.language = Mac.language
        c.keyboard = Mac.keyboard
        return (c, Storage.missingDrive(for: Paths.vmsRoot) != nil ? .driveMissing : .setup)
    }

    /// Looks again (after a move, a delete, a drive plugged in). The same VM
    /// stays shown when it is still there, wherever it is now.
    func reload() {
        guard screen != .building && screen != .install else { storage.refresh(); return }
        if let c = (config.location != nil ? VMConfig.named(config.name) : nil) {
            config = c
            screen = c.isReady ? .ready : .setup
        } else {
            (config, screen) = Self.start()
        }
        storage.refresh()
    }

    /// What the window shows once the install question is answered.
    private(set) var afterInstall: Screen = .setup
    func installDone() { screen = afterInstall }
}

struct RootView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            switch state.screen {
            case .install: InstallView(onDone: { state.installDone() })
            case .setup: SetupView(state: state)
            case .building: BuildView(state: state, creator: state.creator)
            case .ready: ReadyView(state: state)
            case .driveMissing: DriveMissingView(state: state)
            }
        }
        .frame(width: 520)
        .padding(24)
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState
    @State private var password = ""
    @State private var password2 = ""
    @State private var tier = 1
    @State private var bridge = true
    @State private var gestures = true
    @State private var autologin = false
    @State private var locationProblem: String?
    @State private var prebuilt = PrebuiltImage.Lookup.checking
    @State private var usePrebuilt = true
    @State private var graphics = GraphicsChoice.auto
    @StateObject private var mouse = MagicMouseWatch()

    private var userOK: Bool {
        state.config.user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }
    private var canBuild: Bool {
        userOK && !password.isEmpty && password == password2 && VMConfig.validName(state.config.name)
            && prebuilt != .checking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Omarchy VM").font(.title2.bold())
            Text("\(Product.name) makes a new VM with Arch Linux ARM and Omarchy. It downloads one that is already built when there is one for this version (a few minutes), or builds it here (10 to 30 minutes).")
                .foregroundStyle(.secondary)
            Form {
                // Shown at once; the choice comes when the lookup is done, so
                // nothing changes under the user's hands later on.
                switch prebuilt {
                case .checking:
                    LabeledContent("How") {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("checking for a prebuilt VM…").foregroundStyle(.secondary)
                        }
                    }
                case .found(let pb):
                    Picker("How", selection: $usePrebuilt) {
                        Text("Download a prebuilt VM (\(pb.size), Omarchy \(pb.omarchy))").tag(true)
                        Text("Build it here (10 to 30 minutes)").tag(false)
                    }
                case .none:
                    LabeledContent("How") {
                        Text("Build it here (10 to 30 minutes; no prebuilt VM for this version)").foregroundStyle(.secondary)
                    }
                }
                TextField("VM name", text: $state.config.name)
                if !state.config.name.isEmpty && !VMConfig.validName(state.config.name) {
                    Text("Letters, digits, spaces, . _ and - only (64 at most).").font(.caption).foregroundStyle(.red)
                }
                TextField("User name", text: $state.config.user)
                if !state.config.user.isEmpty && !userOK {
                    Text("Lower-case letters, digits, - and _ only.").font(.caption).foregroundStyle(.red)
                }
                TextField("Full name", text: $state.config.fullName)
                SecureField("Password", text: $password)
                SecureField("Password again", text: $password2)
                if !password2.isEmpty && password != password2 {
                    Text("The passwords differ.").font(.caption).foregroundStyle(.red)
                }
                Picker("Resources", selection: $tier) {
                    ForEach(0..<4) { t in
                        let v = Mac.tier(t)
                        Text("\(Mac.tierNames[t]): \(v.cpus) CPUs, \(v.memoryGB) GB").tag(t)
                    }
                }
                Toggle("OmacVM Bridge: the Mac's Wi-Fi, Bluetooth, audio and media keys in Omarchy's bar", isOn: $bridge)
                Toggle("Trackpad gestures in full screen", isOn: $gestures)
                if gestures && mouse.connected { MagicMouseRow() }
                Toggle("Log in automatically (the Mac's own lock protects Omarchy)", isOn: $autologin)
                GraphicsPicker(choice: $graphics)
                Picker("Disk", selection: $state.config.diskGB) {
                    ForEach([64, 128, 256, 512], id: \.self) { Text("\($0) GB (grows as it fills)").tag($0) }
                }
                VMsFolderRow(storage: state.storage)
                if let n = state.storage.note, state.storage.noteIsError {
                    Text(n).font(.caption).foregroundStyle(.red)
                }
                if let p = locationProblem {
                    Text(p).font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Text("Keyboard \(state.config.keyboard), \(state.config.timeZone), \(state.config.language) (from the Mac)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Build") { build() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBuild)
            }
        }
        .task {
            if let pb = await PrebuiltImage.lookup() { prebuilt = .found(pb) } else { prebuilt = .none }
        }
    }

    private func build() {
        guard Mac.commandLineToolsInstalled else {
            locationProblem = "The build needs Xcode's Command Line Tools. macOS asks to install them now; build again when they are in."
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            p.arguments = ["--install"]
            try? p.run()
            return
        }
        if let p = VolumeCheck.problem(with: Paths.vmsRoot) {
            locationProblem = p
            return
        }
        let t = Mac.tier(tier)
        state.config.cpus = t.cpus
        state.config.memoryMB = t.memoryGB * 1024
        state.config.sshPort = Mac.freePort(from: 52222)
        state.config.hostname = "omarchy"
        // Omanotch on with a notch: full screen sits below the camera and
        // Omanotch fills the strip beside it.
        state.config.features = NewVMFeatures.string(bridge: bridge, gestures: gestures, autologin: autologin,
                                                     hasBattery: Mac.hasBattery, hasNotch: Mac.hasNotch)
        locationProblem = nil
        // A new VM goes into the VMs folder as it is now, under its name; the
        // folder is kept (a default that changes later must not hide the VM).
        Paths.vmsRoot = Paths.vmsRoot
        state.config.location = nil
        state.config.location = state.config.folder
        state.screen = .building
        var download = false
        if case .found = prebuilt { download = usePrebuilt }
        state.creator.start(config: state.config, password: password, prebuilt: download, graphics: graphics)
        password = ""; password2 = ""
    }
}

struct BuildView: View {
    @ObservedObject var state: AppState
    @ObservedObject var creator: Creator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Building \(state.config.name)").font(.title2.bold())
            ProgressView(value: Double(max(creator.step - 1, 0)), total: Double(creator.steps))
            Text(creator.step > 0 ? "Step \(creator.step) of \(creator.steps): \(creator.title)" : creator.title)
            Text(creator.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let error = creator.failed {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Button("Show Log") {
                        NSWorkspace.shared.open(state.config.folder.appendingPathComponent("create.log"))
                    }
                    Spacer()
                    Button("Back") { state.screen = .setup }
                }
            } else {
                Text("You can use your Mac meanwhile. Keep it awake and online.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: creator.finished) { _, done in
            if done {
                state.message = creator.warning
                state.screen = .ready
            }
        }
    }
}

struct ReadyView: View {
    @ObservedObject var state: AppState
    @State private var fullScreen = Settings.startFullScreen
    @State private var keepDockAway = Settings.keepDockAway
    @State private var escape = EscapeSetting.current()
    @StateObject private var mouse = MagicMouseWatch()
    @State private var resourcesNote: String?
    @State private var fastNetOn = false
    @State private var fastNetBusy = false
    @State private var fastNetNote: String?
    @State private var fastNetStatus = ""
    @State private var graphics = GraphicsChoice.auto
    @State private var graphicsNote: String?

    /// The create screen's tiers; resources set some other way show as Custom.
    private var tier: Binding<Int> {
        Binding(get: { Mac.tierIndex(cpus: state.config.cpus, memoryMB: state.config.memoryMB) ?? -1 },
                set: { setTier($0) })
    }

    private func setTier(_ t: Int) {
        guard Mac.tierNames.indices.contains(t) else { return }
        let v = Mac.tier(t)
        var c = state.config
        c.cpus = v.cpus
        c.memoryMB = v.memoryGB * 1024
        guard c != state.config else { return }
        do {
            try c.writeResources()
            state.config = c
            resourcesNote = "Applies on the next start."
        } catch {
            resourcesNote = "Could not save: \(error.localizedDescription)"
        }
    }

    /// VM memory and graphics memory side by side: the VM's RAM is fixed,
    /// its graphics come from the Mac on top, as needed (GPUMemory).
    private var graphicsMemory: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let vm = "VM memory: \(state.config.memoryMB / 1024) GB"
            let gpu = GPUMemory.read(for: state.config).map {
                "graphics memory last run: peak \(GPUMemory.gb($0.peakMB)), from the Mac on top"
            } ?? "graphics memory: from the Mac on top, as the VM needs it"
            Text("\(vm); \(gpu)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(GPUMemory.explanation)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.config.name).font(.title2.bold())
            Text("\(state.config.cpus) CPUs, \(state.config.memoryMB / 1024) GB memory, \(state.config.diskGB) GB disk, user \(state.config.user)")
                .foregroundStyle(.secondary)
            graphicsMemory
            Picker("Resources", selection: tier) {
                ForEach(0..<4) { t in
                    let v = Mac.tier(t)
                    Text("\(Mac.tierNames[t]): \(v.cpus) CPUs, \(v.memoryGB) GB").tag(t)
                }
                if Mac.tierIndex(cpus: state.config.cpus, memoryMB: state.config.memoryMB) == nil {
                    Text("Custom: \(state.config.cpus) CPUs, \(state.config.memoryMB / 1024) GB").tag(-1)
                }
            }
            if let n = resourcesNote {
                Text(n).font(.caption).foregroundStyle(n.hasPrefix("Could not") ? .red : .secondary)
            }
            Toggle("Start in full screen", isOn: $fullScreen)
                .onChange(of: fullScreen) { _, v in Settings.startFullScreen = v }
            Toggle("Keep the Dock and hot corners away in full screen", isOn: $keepDockAway)
                .onChange(of: keepDockAway) { _, v in Settings.keepDockAway = v }
            Picker("Escape combo (⌃⌥ Esc)", selection: $escape) {
                ForEach(EscapeSetting.Choice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("In a full-screen VM, Control-Option-Esc moves the monitor under the pointer (or all monitors) to the Space beside the VM's with macOS's own animation; the VM stays full screen. Pressed in macOS, it goes back into the VM. The keyboard follows the pointer's monitor.")
            .onChange(of: escape) { _, v in EscapeSetting.set(v) }
            if mouse.connected { MagicMouseRow(inForm: false) }
            keyAccess
            GraphicsPicker(choice: $graphics, plan: Runner.graphicsPlan(state.config))
                .onChange(of: graphics) { _, v in setGraphics(v) }
            // Vulkan fell back and stays off (graphics-fallback): the picker
            // already shows Vulkan, so choosing it again needs a button.
            if Graphics.fallback(folder: state.config.folder) != nil {
                Button("Try Vulkan again") {
                    do {
                        try Graphics.write(graphics, folder: state.config.folder)
                        graphicsNote = "Vulkan is tried again from the next start."
                    } catch {
                        graphicsNote = "Could not save: \(error.localizedDescription)"
                    }
                }
            }
            if let n = graphicsNote {
                Text(n).font(.caption).foregroundStyle(n.hasPrefix("Could not") ? .red : .secondary)
            }
            fastNetwork
            USBSection(folder: state.config.folder)
            Divider()
            StorageSection(storage: state.storage, selected: state.config.location == nil ? nil : state.config.folder)
            Divider()
            if let m = state.message { Text(m).foregroundStyle(.red) }
            if let p = state.config.filesProblem {
                Text(p).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            UpdateSection(updater: Updater.shared)
            HStack {
                Button("Delete…") { state.storage.delete(state.config) }
                    .disabled(state.storage.moving != nil)
                Spacer()
                Button("Start") { state.startVM() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.storage.moving != nil || state.config.filesProblem != nil)
            }
        }
        .onAppear { refreshFastNetwork(); graphics = Graphics.read(folder: state.config.folder) }
        .onChange(of: state.config) { _, c in refreshFastNetwork(); graphics = Graphics.read(folder: c.folder); graphicsNote = nil }
    }

    /// Shown only when the VM's keyboard tap is refused (KeyAccess); checked
    /// again every few seconds, so it goes once OmacVM is allowed.
    private var keyAccess: some View {
        TimelineView(.periodic(from: .now, by: 3)) { _ in
            if KeyAccess.needsUser(folder: state.config.folder) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Keyboard: OmacVM is not allowed to read it").foregroundStyle(.red)
                        Spacer()
                        Button("Allow…") { KeyAccess.request() }
                    }
                    Text(KeyAccess.missingText).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func setGraphics(_ g: GraphicsChoice) {
        let folder = state.config.folder
        guard g != Graphics.read(folder: folder) else { return }
        do {
            try Graphics.write(g, folder: folder)
            let plan = Runner.graphicsPlan(state.config)
            graphicsNote = "Applies on the next start."
            if g == .vulkan && !plan.venus {
                graphicsNote = "The VM has no Vulkan driver yet: it runs on OpenGL until `omacvm apply` (or `omacvm graphics` while the VM runs) builds it, a few minutes."
            }
        } catch {
            graphicsNote = "Could not save: \(error.localizedDescription)"
        }
    }

    /// The fast network (experimental): a button, never automatic. Turning it
    /// on installs a small system service, so macOS asks for the password once.
    private var fastNetwork: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fast network (experimental)")
                Spacer()
                if fastNetBusy { ProgressView().controlSize(.small) }
                Button(fastNetOn ? "Turn Off…" : "Turn On…") { toggleFastNetwork() }
                    .disabled(fastNetBusy)
            }
            Text(fastNetStatus).font(.caption).foregroundStyle(.secondary)
            if let n = fastNetNote { Text(n).font(.caption).foregroundStyle(.red) }
        }
    }

    /// What the switch says, worked out off the main thread (the service
    /// check verifies QEMU's code signature, which reads the whole binary).
    nonisolated private static func fastNetworkStatus(_ c: VMConfig) -> (Bool, String) {
        guard FastNetwork.isOn(c) else {
            return (false, "Off: QEMU's own network. On: macOS's VM network (as Parallels and UTM), faster to and from the Mac; macOS asks for your password once.")
        }
        if let why = FastNetwork.serviceProblem() { return (true, "On, but \(why): Turn Off, then On again.") }
        return (true, FastNetwork.lastRecord(c) == "vmnet" ? "On." : "On from the VM's next start.")
    }

    private func refreshFastNetwork() {
        let c = state.config
        fastNetOn = FastNetwork.isOn(c)
        Task.detached {
            let (on, text) = Self.fastNetworkStatus(c)
            await MainActor.run {
                fastNetOn = on
                fastNetStatus = text
            }
        }
    }

    private func toggleFastNetwork() {
        let c = state.config, on = !fastNetOn
        fastNetBusy = true
        fastNetNote = nil
        Task.detached {
            let err = on ? FastNetwork.turnOn(c) : FastNetwork.turnOff(c)
            let (now, text) = Self.fastNetworkStatus(c)
            await MainActor.run {
                fastNetBusy = false
                fastNetNote = err
                fastNetOn = now
                fastNetStatus = text
            }
        }
    }
}

/// The self-update in the window: a ready update (never while update checks
/// are off), what the last update did, and the weekly-check switch, shared
/// with the control centre.
struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            let banner = updater.enabled && updater.staged != nil
            if banner, let s = updater.staged {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(Product.name) \(s.version) is ready", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                    Text(updater.installWhenIdle
                         ? "You have \(updater.currentVersion). It goes in once the VM has shut down; your VMs are not changed."
                         : "You have \(updater.currentVersion). \(Product.name) restarts with the new version; your VMs are not changed.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let n = s.notes { Button("What's New") { NSWorkspace.shared.open(n) } }
                        Button("Skip This Version") { updater.skip() }
                        Spacer()
                        if !updater.installWhenIdle { Button("Update and Relaunch") { updater.install() } }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            // While it waits for the VM the banner says so already.
            if let n = updater.notice, !(banner && updater.installWhenIdle) {
                Label(n, systemImage: "info.circle")
                    .font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Check for updates once a week", isOn: Binding(get: { updater.enabled }, set: { updater.setEnabled($0) }))
            Text("Off: no checks and no messages. The same switch as in OmacVM's control centre in Omarchy. \(Product.name) › Check for Updates… still works.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }
}

/// The Graphics choice (Graphics.swift), in the setup and the VM window.
struct GraphicsPicker: View {
    @Binding var choice: GraphicsChoice
    /// The VM's plan now (the VM window); the setup has none yet.
    var plan: GraphicsPlan? = nil

    private var autoText: String {
        let lib = Paths.qemu.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/libvulkan_kosmickrisp.dylib")
        let kk = FileManager.default.fileExists(atPath: lib.path)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return Graphics.autoPicksVulkan(macOSMajor: major, kosmicKrisp: kk) ? "Vulkan on this Mac" : "OpenGL on this Mac"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Graphics", selection: $choice) {
                Text("Automatic (\(autoText))").tag(GraphicsChoice.auto)
                Text("OpenGL").tag(GraphicsChoice.opengl)
                Text("Vulkan (experimental)").tag(GraphicsChoice.vulkan)
            }
            .help("OpenGL: the VM's apps and browsers draw with OpenGL on the Mac's GPU. Vulkan: the same, plus Vulkan apps on the Mac's GPU (KosmicKrisp on macOS 26 and newer, MoltenVK before); Vulkan windows are copied through the CPU. Automatic: OpenGL on every Mac in this version.")
            if let p = plan {
                Text(p.choice == .vulkan && !p.venus ? "Next start: \(p.summary)." : "Next start: \(p.summary) (\(p.why)).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
