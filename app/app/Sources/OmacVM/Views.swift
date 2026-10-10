import AppKit
import ApplicationServices
import Combine
import OmacVMFeatures
import OmacVMWindow
import SwiftUI
import OmacVMBuildProgress
import OmacVMDesktop

extension RunMarker {
    /// Before a start or Update VM: the VM was not shut down cleanly or was
    /// copied while it ran. Asks Cancel / Start Anyway (a hidden test run
    /// only logs it). True: go on.
    @MainActor static func confirmStart(_ c: VMConfig) -> Bool {
        guard let warn = warning(folder: c.folder, thisMac: Mac.hardwareID) else { return true }
        FileHandle.standardError.write(Data("OmacVM: \(c.name): \(warn)\n".utf8))
        if ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] != nil { return true }
        let alert = NSAlert()
        alert.messageText = "Start \(c.name)?"
        alert.informativeText = warn + " Start it only when it runs nowhere else."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Start Anyway")
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// What the launcher window shows.
enum Screen: Equatable {
    case install
    case setup
    case building
    case ready
    case driveMissing
    /// The drive with the shown VM went away (UnavailableView).
    case unavailable
}

@MainActor
final class AppState: ObservableObject {
    @Published var screen: Screen = .setup
    @Published var config: VMConfig
    @Published var message: String?
    let creator = Creator()
    let storage = StorageModel()
    var startVM: () -> Void = {}
    /// This app's VM runs (main.swift sets it).
    var vmRunning: () -> Bool = { false }

    /// watchDrives false: the window pictures, which must not switch to a
    /// VM of this Mac when a drive comes or goes meanwhile.
    init(watchDrives: Bool = true) {
        (config, screen) = Self.start()
        // --vm NAME that no VM has: said here, and nothing is started (main.swift).
        if let n = VMConfig.unknownRequested {
            message = VMPick.unknownText(n, roots: Paths.vmsRoots)
        }
        afterInstall = screen
        if !Installer.isInstalled { screen = .install }
        storage.onMoved = { [weak self] in self?.reload() }
        // A drive plugged in or gone: the VMs on it come and go.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] where watchDrives {
            driveObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.drivesChanged() }
            })
        }
        // The views read the storage through this state too (Start waits for a move).
        storageChanges = storage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    private var storageChanges: AnyCancellable?
    private var driveObservers: [NSObjectProtocol] = []

    /// The drive with the shown VM's folder went away (while it ran, or
    /// since): its name. The window shows the VM as unavailable until the
    /// drive is back.
    @Published private(set) var goneDrive: String?

    /// "Show <VM>" on the unavailable screen: another VM, here now.
    func showOther(_ c: VMConfig) {
        goneDrive = nil
        message = nil
        config = c
        screen = c.isReady ? .ready : .setup
    }

    /// "Open Existing VM…" (setup and settings): a VM from the Finder, shown
    /// at once. Not while this app's VM runs.
    func openExisting() {
        if vmRunning() {
            message = "Shut down \(config.name) first, then open another VM."
            return
        }
        if let c = storage.openExisting() {
            showOther(c)
            storage.refresh()
        }
    }

    /// The VM's drive went away while it ran (main.swift, Runner.driveLost).
    /// The drive may be back already (a USB link that reset): its mount came
    /// while QEMU was still being stopped, when drivesChanged leaves the
    /// running VM alone, so look again now, in the same folder. Back: ready,
    /// and it says why the VM stopped.
    func driveGone(_ drive: String) {
        storage.refresh()
        if Storage.missingDrive(for: config.folder) == nil, let c = VMConfig.load(from: config.folder) {
            goneDrive = nil
            config = c
            screen = c.isReady ? .ready : .setup
            message = "\(c.name) was stopped: its drive (\(drive)) went away while it ran. The drive is back: start the VM again."
            FileHandle.standardError.write(Data("drive: \(c.name) ready again: \(drive) went away and is back\n".utf8))
            return
        }
        message = nil
        goneDrive = drive
        screen = .unavailable
        FileHandle.standardError.write(Data("drive: \(config.name) unavailable: \(drive) is gone\n".utf8))
    }

    /// A drive was mounted or unmounted. Not while a VM runs (its Runner
    /// watches its own drive), builds or is set up (the form keeps what was typed).
    func drivesChanged() {
        let was = screen
        switch screen {
        case .ready, .driveMissing, .unavailable:
            if vmRunning() { storage.refresh() } else { reload() }
        case .install, .setup, .building:
            storage.refresh()
        }
        if screen != was {
            FileHandle.standardError.write(Data("drive: the window shows \(screen) now (was \(was)): \(config.name)\n".utf8))
        }
    }

    /// The VM to show and the screen for it: the VM the app finds, else a
    /// new one (or the note that the VMs folder's drive is not connected).
    private static func start() -> (VMConfig, Screen) {
        if let existing = VMConfig.existing() {
            return (existing, existing.isReady ? .ready : .setup)
        }
        var c = VMConfig()
        // Never the folder of a VM that is there (one --vm did not name, say).
        c.name = VMPick.freeName(root: Paths.vmsRoot, taken: VMConfig.all().map(\.name))
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
            goneDrive = nil
        } else if let drive = config.location.flatMap({ Storage.missingDrive(for: $0) })
                    ?? (screen == .unavailable && !FileManager.default.fileExists(atPath: config.folder.path) ? goneDrive : nil) {
            // Its drive is not back yet: still shown, as unavailable.
            goneDrive = drive
            screen = .unavailable
        } else {
            goneDrive = nil
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
    /// False: the whole content, never scrolling (the window pictures).
    var scrolls = true
    /// The window pictures (RenderVMWindow).
    var preview: RenderVMWindow.Preview? = nil

    var body: some View {
        if scrolls {
            FitScroll { content }.frame(width: WindowLayout.width)
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            switch state.screen {
            case .install: InstallView(onDone: { state.installDone() })
            case .setup: SetupView(state: state)
            case .building: BuildView(state: state, creator: state.creator)
            case .ready: ReadyView(state: state, preview: preview)
            case .driveMissing: DriveMissingView(state: state)
            case .unavailable: UnavailableView(state: state)
            }
        }
        // One inset on every side for every screen (WindowLayout).
        .frame(width: WindowLayout.contentWidth)
        .padding(WindowLayout.inset)
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
    @State private var offerCLI = !UserDefaults.standard.bool(forKey: "offeredCLI")

    private var userOK: Bool {
        state.config.user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }
    private var canBuild: Bool {
        userOK && !password.isEmpty && password == password2 && VMConfig.validName(state.config.name)
            && !nameTaken && prebuilt != .checking
    }
    /// A VM (or a folder) of that name is there: a build would take over its disk.
    /// The shown VM's own folder (a build that did not finish, built again) is not taken.
    private var nameTaken: Bool {
        let folder = Paths.vmsRoot.appendingPathComponent(state.config.name).standardizedFileURL.path
        if let own = state.config.location?.standardizedFileURL.path, own.caseInsensitiveCompare(folder) == .orderedSame {
            return false
        }
        return VMPick.freeName(state.config.name, root: Paths.vmsRoot, taken: VMConfig.all().map(\.name)) != state.config.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Omarchy VM").font(.title2.bold())
                Spacer()
                // A VM copied here or on another drive: show it instead.
                Button("Open Existing VM…") { state.openExisting() }
                    .disabled(state.storage.moving != nil)
                    .help("Show a VM that is somewhere else (copied, or on another drive): its folder, or the folder it is in.")
                    .layoutProbe("open-existing")
            }
            Text("\(Product.name) makes a new VM with Arch Linux ARM and Omarchy. It downloads one that is already built when there is one for this version (a few minutes), or builds it here (10 to 30 minutes).")
                .foregroundStyle(.secondary)
                .layoutProbe("header")
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
                } else if nameTaken {
                    Text("A VM named \(state.config.name) is there already: pick another name.").font(.caption).foregroundStyle(.red)
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
                // Two lines: on one, the form grows past the window's sides.
                Toggle(isOn: $bridge) {
                    Text("OmacVM Bridge: the Mac's Wi-Fi, Bluetooth, audio and media keys in Omarchy's bar")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: RowNote.width + 40, alignment: .leading)
                }
                .layoutProbe("bridge")
                Toggle("Trackpad gestures in full screen", isOn: $gestures)
                if gestures && mouse.connected { MagicMouseRow() }
                Toggle("Log in automatically (the Mac's own lock protects Omarchy)", isOn: $autologin)
                GraphicsPicker(choice: $graphics)
                Picker("Disk", selection: $state.config.diskGB) {
                    ForEach([64, 128, 256, 512], id: \.self) { Text("\($0) GB (grows as it fills)").tag($0) }
                }
                VMsFolderRow(storage: state.storage)
                // Offered once, in the first setup; later in the VM window.
                if offerCLI { CommandLineRow() }
                if let n = state.storage.note, state.storage.noteIsError {
                    Text(n).font(.caption).foregroundStyle(.red)
                }
                if let p = locationProblem {
                    Text(p).font(.caption).foregroundStyle(.red)
                }
            }
            .layoutProbe("form")
            if let m = state.message { Text(m).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Keyboard \(state.config.keyboard), \(state.config.timeZone), \(state.config.language) (from the Mac)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Build") { build() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBuild)
                    .layoutProbe("start")
            }
            .layoutProbe("buttons")
        }
        .task {
            if let pb = await PrebuiltImage.lookup() { prebuilt = .found(pb) } else { prebuilt = .none }
        }
    }

    private func build() {
        guard Mac.buildToolsReady else {
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
        UserDefaults.standard.set(true, forKey: "offeredCLI")
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
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(creator.job == .build ? "Building \(state.config.name)" : "Updating OmacVM in \(state.config.name)")
                .font(.title2.bold())
            ProgressView(value: Double(max(creator.step - 1, 0)), total: Double(creator.steps))
            Text(creator.step > 0 ? "Step \(creator.step) of \(creator.steps): \(creator.title)" : creator.title)
            if creator.failed == nil {
                BuildNowView(creator: creator)
            } else {
                Text(creator.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            DisclosureGroup(isExpanded: $showDetails) {
                BuildLogView(creator: creator)
            } label: {
                Text("Show details").font(.caption)
            }
            if let error = creator.failed {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Button("Show Log") {
                        NSWorkspace.shared.open(creator.log ?? state.config.folder.appendingPathComponent("create.log"))
                    }
                    Spacer()
                    Button("Back") { state.screen = creator.job == .build ? .setup : .ready }
                }
            } else {
                Text("You can use your Mac meanwhile. Keep it awake and online.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: creator.finished) { _, done in
            guard done else { return }
            let updated = creator.job == .update
            // Update VM shut the VM down cleanly: no run marker to warn about.
            if updated { try? FileManager.default.removeItem(at: state.config.folder.appendingPathComponent(RunMarker.fileName)) }
            state.screen = .ready
            if updated { state.reload() }   // its sizes; the VM stays the one shown
            state.message = creator.warning
                ?? (updated ? state.config.guestVersion.map { "OmacVM in \(state.config.name) is now \($0)." } : nil)
        }
    }
}

/// What the build does right now: the current part, a download's bar with
/// speed and time left (or the package count), the step's time, and a
/// heartbeat so a quiet part does not look frozen.
struct BuildNowView: View {
    @ObservedObject var creator: Creator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                if let a = creator.activity {
                    Text(a.text).lineLimit(1).truncationMode(.middle)
                    if let f = a.fraction { ProgressView(value: f).controlSize(.small) }
                    if let line = downloadLine(a) {
                        Text(line).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if !creator.detail.isEmpty {
                    Text(creator.detail.prefix(1).uppercased() + creator.detail.dropFirst()).lineLimit(2)
                }
                if creator.step > 0 {
                    Text(stepTime(at: ctx.date)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(BuildText.heartbeat(quietFor: ctx.date.timeIntervalSince(creator.lastOutput)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            // Room for the tallest case (a download): the window keeps its
            // height as lines come and go.
            .frame(minHeight: 116, alignment: .topLeading)
        }
    }

    /// "412 MB of 1.4 GB, 11.2 MB/s, about 2 min left"
    private func downloadLine(_ a: ProgressUpdate) -> String? {
        guard a.total > 0 else { return nil }
        var parts = ["\(BuildText.bytes(a.done)) of \(BuildText.bytes(a.total))"]
        if a.complete { return parts[0] }
        if let s = creator.speed { parts.append(BuildText.speed(s)) }
        parts.append(creator.secondsLeft.map(BuildText.left) ?? "measuring speed")
        return parts.joined(separator: ", ")
    }

    /// "This step: 3 min 10 s so far, usually 15-40 min on this Mac (last time 22 min). Build: 9 min."
    private func stepTime(at now: Date) -> String {
        var s = "This step: \(BuildText.duration(now.timeIntervalSince(creator.stepStarted))) so far"
        // An update has its own steps: no build times for them.
        guard creator.job == .build else {
            return s + ". Whole update: \(BuildText.duration(now.timeIntervalSince(creator.buildStarted)))."
        }
        if let last = StepTimes.last(route: creator.route, step: creator.step) {
            s += ", last time \(BuildText.duration(last)) on this Mac"
        } else if let u = StepTimes.usual(route: creator.route, step: creator.step, performanceCores: Mac.performanceCores) {
            s += ", \(StepTimes.usualText(u)) on a Mac like this"
        }
        return s + ". Whole build: \(BuildText.duration(now.timeIntervalSince(creator.buildStarted)))."
    }
}

/// The last lines of the build's newest log, as they come.
struct BuildLogView: View {
    @ObservedObject var creator: Creator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(creator.logName.isEmpty ? "No log yet." : creator.logName)
                .font(.caption).foregroundStyle(.secondary)
            // The newest line stays in view.
            ScrollView {
                Text(creator.logTail.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, 4)
    }
}

/// The VM window before Start: a header, the settings as a two-column form
/// (switches for what is on or off; each long explanation behind an (i)),
/// then Delete… and Start. Fits a 13-inch MacBook whole (WindowFit).
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
    /// The service needs the person (FastNetwork.serviceNeeds): its button.
    @State private var fastNetFix: String?
    @State private var graphics = GraphicsChoice.auto
    @State private var graphicsNote: String?
    @State private var macFolder: String?
    @State private var macFolderNote: String?
    @State private var customResources = false
    /// What the window says about the keyboard (KeyNote).
    @State private var keyNote = KeyNote.none
    /// The window pictures (--render-vm-window): this keyboard note and this
    /// "omacvm in Terminal" state instead of the Mac's.
    var preview: RenderVMWindow.Preview? = nil

    /// The create screen's tiers; resources set some other way show as
    /// Custom (-1); Custom… (-2) opens the steppers.
    private var tier: Binding<Int> {
        Binding(get: { Mac.tierIndex(cpus: state.config.cpus, memoryMB: state.config.memoryMB) ?? -1 },
                set: { if $0 == -2 { customResources = true } else { setTier($0) } })
    }

    private func setTier(_ t: Int) {
        guard Mac.tierNames.indices.contains(t) else { return }
        let v = Mac.tier(t)
        setResources(cpus: v.cpus, memoryGB: v.memoryGB)
    }

    private func setResources(cpus: Int, memoryGB: Int) {
        var c = state.config
        c.cpus = cpus
        c.memoryMB = memoryGB * 1024
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
    private var memoryText: String {
        let vm = "VM memory: \(state.config.memoryMB / 1024) GB"
        let gpu = GPUMemory.read(for: state.config).map {
            "graphics memory last run: peak \(GPUMemory.gb($0.peakMB)), from the Mac on top"
        } ?? "graphics memory: from the Mac on top, as the VM needs it"
        return "\(vm); \(gpu).\n\n\(GPUMemory.explanation)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.config.name).font(.title2.bold())
                HStack(spacing: 4) {
                    Text("\(state.config.cpus) CPUs, \(state.config.memoryMB / 1024) GB memory, \(state.config.diskGB) GB disk, user \(state.config.user)")
                        .foregroundStyle(.secondary)
                    InfoButton(topic: "memory", text: memoryText)
                }
            }
            .layoutProbe("header")
            Form {
                Section { vmRows }
                Section {
                    StartInRow(folder: state.config.folder, fullScreen: $fullScreen, previewNotch: preview?.notch)
                    SwitchRow("Keep the Dock and hot corners away", isOn: $keepDockAway) {
                        InfoButton(topic: "the Dock and hot corners", text: "In full screen, neither the Dock nor a hot corner comes up from inside the VM, and the menu bar stays hidden on every display. Off: macOS's own full screen.")
                    }
                    .onChange(of: keepDockAway) { _, v in Settings.keepDockAway = v }
                }
                Section {
                    fastNetwork
                    MacIMERow(state: state)
                    USBRow(folder: state.config.folder)
                    macFolderRows
                }
                Section {
                    DiskRow(state: state)
                    CommandLineRow(preview: preview?.terminal)
                    StorageRows(storage: state.storage, selected: state.config.location == nil ? nil : state.config.folder,
                                open: { state.openExisting() })
                }
                Section { UpdateRow(updater: Updater.shared) }
            }
            .formStyle(.columns)
            .layoutProbe("form")
            if let m = state.message {
                Text(m).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).layoutProbe("message")
            }
            if let p = state.config.filesProblem {
                Text(p).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let app = preview?.appVersion ?? OmacVMVersion.app, OmacVMVersion.vmIsBehind(state.config.guestVersion, app: app) {
                guestUpdate(app: app)
            }
            UpdateBanner(updater: Updater.shared)
            HStack {
                Button("Delete…") { state.storage.delete(state.config) }
                    .disabled(state.storage.moving != nil)
                    .layoutProbe("delete")
                Spacer()
                Button("Start") { state.startVM() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.storage.moving != nil || state.config.filesProblem != nil)
                    .layoutProbe("start")
            }
        }
        .onAppear {
            refreshFastNetwork(); graphics = Graphics.read(folder: state.config.folder)
            macFolder = MacFolder.path(state.config)
            refreshKeyNote()
        }
        .onChange(of: state.config) { _, c in
            refreshFastNetwork(); graphics = Graphics.read(folder: c.folder); graphicsNote = nil
            macFolder = MacFolder.path(c); macFolderNote = nil
            refreshKeyNote()
        }
        // Every 3 s while the window shows. A task, not a Timer publisher
        // kept in this struct: each redraw of the window (a storage change,
        // a move's progress) makes a new publisher and starts its 3 s again,
        // so it would never fire.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                refreshKeyNote()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshKeyNote()
        }
    }

    /// Resources, Graphics, the escape combo, the Magic Mouse and the keyboard.
    @ViewBuilder private var vmRows: some View {
        Picker("Resources", selection: tier) {
            ForEach(0..<4) { t in
                let v = Mac.tier(t)
                Text("\(Mac.tierNames[t]): \(v.cpus) CPUs, \(v.memoryGB) GB").tag(t)
            }
            if Mac.tierIndex(cpus: state.config.cpus, memoryMB: state.config.memoryMB) == nil {
                Text("Custom: \(state.config.cpus) CPUs, \(state.config.memoryMB / 1024) GB").tag(-1)
            }
            Divider()
            Text("Custom…").tag(-2)
        }
        .fixedSize()
        .sheet(isPresented: $customResources) {
            CustomResourcesSheet(cpus: state.config.cpus, memoryMB: state.config.memoryMB,
                                 onSave: { setResources(cpus: $0, memoryGB: $1); customResources = false },
                                 onCancel: { customResources = false })
        }
        if let n = resourcesNote { RowNote(n, error: n.hasPrefix("Could not")) }
        // A VM from a bigger Mac: what it starts with here (main.swift startVM).
        if let n = state.config.startSizeNote { RowNote(n) }
        GraphicsPicker(choice: $graphics, plan: Runner.graphicsPlan(state.config))
            .onChange(of: graphics) { _, v in setGraphics(v) }
        // Vulkan fell back and stays off (graphics-fallback): the picker
        // already shows Vulkan, so choosing it again needs a button.
        if Graphics.fallback(folder: state.config.folder) != nil {
            LabeledContent("") {
                Button("Try Vulkan again") {
                    do {
                        try Graphics.write(graphics, folder: state.config.folder)
                        graphicsNote = "Vulkan is tried again from the next start."
                    } catch {
                        graphicsNote = "Could not save: \(error.localizedDescription)"
                    }
                }
            }
        }
        if let n = graphicsNote { RowNote(n, error: n.hasPrefix("Could not")) }
        LabeledContent("Escape combo (⌃⌥ Esc)") {
            HStack(spacing: 8) {
                Picker("Escape combo (⌃⌥ Esc)", selection: $escape) {
                    ForEach(EscapeSetting.Choice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: escape) { _, v in EscapeSetting.set(v) }
                InfoButton(topic: "the escape combo", text: "In a full-screen VM, Control-Option-Esc moves the monitor under the pointer (or all monitors) to the Space beside the VM's with macOS's own animation; the VM stays full screen. Pressed in macOS, it goes back into the VM. The keyboard follows the pointer's monitor.")
            }
        }
        if mouse.connected { MagicMouseRow() }
        keyAccess
    }

    /// One folder of the Mac at ~/Mac in the VM (MacFolder), off by default.
    /// Switching it on asks for the folder.
    @ViewBuilder private var macFolderRows: some View {
        SwitchRow("Mac folder", isOn: Binding(get: { macFolder != nil }, set: { on in
            if !on { setMacFolder(nil) } else if let url = MacFolder.choose(current: macFolder) { setMacFolder(url) }
        })) {
            if macFolder != nil {
                Button("Choose…") {
                    if let url = MacFolder.choose(current: macFolder) { setMacFolder(url) }
                }
            }
            InfoButton(topic: "the Mac folder", text: "One folder of the Mac at ~/Mac in the VM. The VM can read and change everything in it. Applies on the next start.")
        }
        if let p = macFolder {
            Text("\(StorageModel.short(URL(fileURLWithPath: p))) at ~/Mac in the VM")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: RowNote.width, alignment: .leading)
                .help(p)
        }
        if let n = macFolderNote { RowNote(n, error: n.hasPrefix("Could not")) }
    }

    private func setMacFolder(_ url: URL?) {
        do {
            try MacFolder.set(url, for: state.config)
            macFolder = MacFolder.path(state.config)
            macFolderNote = "Applies on the next start."
        } catch {
            macFolderNote = "Could not share: \(error.localizedDescription)"
        }
    }

    /// A VM made by an older app keeps its OmacVM when the app is replaced:
    /// offer to bring it up to this app's (the control centre in Omarchy only
    /// exists from 3.0.0 on, so an older VM cannot ask for it itself).
    private func guestUpdate(app: String) -> some View {
        HStack(spacing: 6) {
            Text("OmacVM in this VM: \(state.config.guestVersion ?? "from an older app")")
            InfoButton(topic: "Update VM", text: "This app has OmacVM \(app). Update VM starts the VM without a window, updates OmacVM in it and its helpers on the Mac (a few minutes) and shuts it down. Your files and settings in Omarchy stay.")
            Spacer()
            Button("Update VM") {
                // A test build never updates a VM of the installed app.
                if let why = Paths.startProblem(state.config.folder) { state.message = why; return }
                // Not shut down cleanly, or copied while it ran: asked first.
                guard RunMarker.confirmStart(state.config) else { return }
                state.message = nil
                state.creator.update(config: state.config)
                state.screen = .building
            }
            .disabled(state.storage.moving != nil || state.config.filesProblem != nil)
            .layoutProbe("update-vm")
        }
        .layoutProbe("version-row")
    }

    /// Shown when the VM's keyboard tap is refused (KeyAccess); checked
    /// again every few seconds and when OmacVM comes to the front (back from
    /// System Settings). Allowed since the VM's last start: a grey line.
    @ViewBuilder private var keyAccess: some View {
        if keyNote == .needsUser {
            LabeledContent("Keyboard") {
                HStack(spacing: 8) {
                    Text("Not allowed").foregroundStyle(.red)
                    Button("Allow…") { KeyAccess.request { refreshKeyNote() } }
                    InfoButton(topic: "the keyboard", text: KeyAccess.missingText)
                }
            }
        } else if keyNote == .allowedNextStart {
            LabeledContent("Keyboard") {
                Text(KeyNote.allowedText).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: RowNote.width, alignment: .leading)
            }
        }
    }

    private func refreshKeyNote() {
        keyNote = preview?.keyNote ?? KeyAccess.note(folder: state.config.folder)
        // Red: first clear an old "control the computer" entry (KeyAccess.reset).
        if keyNote == .needsUser, preview == nil {
            KeyAccess.clearOldEntryOnce { refreshKeyNote() }
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

    /// The fast network (experimental): a switch, never automatic. Turning it
    /// on installs a small system service, so macOS asks for the password once.
    @ViewBuilder private var fastNetwork: some View {
        SwitchRow("Fast network (experimental)",
                  isOn: Binding(get: { fastNetOn }, set: { on in if on != fastNetOn { toggleFastNetwork() } }),
                  enabled: !fastNetBusy) {
            if fastNetBusy { ProgressView().controlSize(.small) }
            if let fix = fastNetFix, fastNetOn {
                Button(fix) { updateFastNetwork() }.disabled(fastNetBusy)
            }
            InfoButton(topic: "the fast network", text: Self.fastNetworkInfo)
        }
        if !fastNetStatus.isEmpty { RowNote(fastNetStatus) }
        if let n = fastNetNote { RowNote(n, error: true) }
    }

    static let fastNetworkInfo = "Off: QEMU's own network. On: macOS's VM network (as Parallels and UTM), faster to and from the Mac; macOS asks for your password once."

    /// The line under the switch, worked out off the main thread (the service
    /// check verifies QEMU's code signature, which reads the whole binary).
    /// Off says nothing: the (i) explains. The service is checked as the installer checks it (an older build of
    /// the same protocol is fine; another protocol after an app update needs
    /// an update): its button then, Update… or Install…
    nonisolated private static func fastNetworkStatus(_ c: VMConfig) -> (on: Bool, text: String, fix: String?) {
        guard FastNetwork.isOn(c) else {
            return (false, "", nil)
        }
        let status = FastNetwork.serviceStatus()
        if status == "stopped" { return (true, "On, but \(FastNetwork.stoppedText); until then the VM starts on the normal network.", nil) }
        if let need = FastNetwork.serviceNeeds(status) {
            return (true, "On. \(need.why) \(need.button) fixes it (macOS asks for your password once); until then the VM starts on the normal network.", need.button)
        }
        if let why = FastNetwork.serviceProblem() { return (true, "On, but \(why): switch it off, then on again.", nil) }
        return (true, FastNetwork.lastRecord(c) == "vmnet" ? "" : "On from the VM's next start.", nil)
    }

    private func refreshFastNetwork() {
        let c = state.config
        fastNetOn = FastNetwork.isOn(c)
        Task.detached {
            let st = Self.fastNetworkStatus(c)
            await MainActor.run {
                fastNetOn = st.on
                fastNetStatus = st.text
                fastNetFix = st.fix
            }
        }
    }

    private func toggleFastNetwork() {
        let c = state.config, on = !fastNetOn
        // A VM of this app that runs on the fast network keeps it until it shuts down.
        let inUse = state.vmRunning() && FastNetwork.lastRecord(c) == "vmnet"
        fastNetBusy = true
        fastNetNote = nil
        Task.detached {
            let err = on ? FastNetwork.turnOn(c) : FastNetwork.turnOff(c, vmnetInUse: inUse)
            let st = Self.fastNetworkStatus(c)
            await MainActor.run {
                fastNetBusy = false
                fastNetNote = err
                fastNetOn = st.on
                fastNetStatus = st.text
                fastNetFix = st.fix
            }
        }
    }

    /// Update… / Install…: the service for this app (macOS's password dialog).
    private func updateFastNetwork() {
        let c = state.config
        fastNetBusy = true
        fastNetNote = nil
        Task.detached {
            let err = FastNetwork.updateService()
            let st = Self.fastNetworkStatus(c)
            await MainActor.run {
                fastNetBusy = false
                fastNetNote = err
                fastNetOn = st.on
                fastNetStatus = st.text
                fastNetFix = st.fix
            }
        }
    }
}

extension KeyAccess {
    /// What the window says (KeyNote): the red note, nothing, or "allowed,
    /// takes effect at the next start" when the refusal is from a start
    /// before OmacVM was allowed. (Here, not in KeyAccess.swift, which
    /// src/tests/app-key-access.sh compiles on its own.)
    static func note(folder: URL) -> KeyNote {
        KeyNote.decide(allowedNow: allowed || fresh(), lastLog: lastLog(folder: folder))
    }

    /// macOS's answer now: this process keeps its first answer (a grant
    /// given in System Settings while OmacVM runs did not show until OmacVM
    /// was quit), a new process gets the current one. Only asked while this
    /// process says no; about 50 ms, at most 2 s.
    static func fresh() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--key-access"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}

/// The weekly-check switch (shared with the control centre), Check Now and
/// what the last check found: a row of the VM window's form.
struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        SwitchRow("Check for updates once a week", isOn: Binding(get: { updater.enabled }, set: { updater.setEnabled($0) })) {
            Button("Check Now") { Task { await updater.checkNow() } }
                .disabled(updater.checking || updater.restarting)
            InfoButton(topic: "update checks", text: "Off: no checks and no messages. Check Now still works. The same switch as in the control centre in Omarchy.")
            if updater.checking {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        }
        if !updater.checking, let o = updater.lastOutcome, let line = Updater.outcomeLine(o, current: updater.currentVersion) {
            Text(line)
                .font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: RowNote.width, alignment: .leading)
        }
    }
}

/// The self-update below the form: a ready update (never while update checks
/// are off) and what the last update did.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        // Weekly checks on, or a check by hand in this session.
        let banner = updater.staged != nil && (updater.enabled || updater.lastOutcome != nil)
        if banner, let s = updater.staged {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(Product.name) \(s.version) is ready", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Text(bannerText)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let n = s.notes { Button("What's New") { NSWorkspace.shared.open(n) } }
                    Button("Skip This Version") { updater.skip() }.disabled(updater.restarting)
                    Spacer()
                    if !updater.installWhenIdle && !updater.restarting {
                        Button("Update to \(s.version)…") { update(s.version) }.keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .layoutProbe("update-banner")
        }
        // While it waits for the VM the banner says so already.
        if let n = updater.notice, !(banner && updater.installWhenIdle) {
            Label(n, systemImage: "info.circle")
                .font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bannerText: String {
        if updater.restarting { return "The VM shuts down for the update; it starts again with the new version." }
        if updater.installWhenIdle {
            return "You have \(updater.currentVersion). It goes in once the VM has shut down; your VMs are not changed."
        }
        if updater.runningVM() != nil {
            return "You have \(updater.currentVersion). Your VM shuts down cleanly, \(Product.name) updates and restarts, then starts the VM again."
        }
        return "You have \(updater.currentVersion). \(Product.name) restarts with the new version; your VMs are not changed."
    }

    /// One confirm, then the update: with a VM restart when this launcher runs the VM.
    private func update(_ version: String) {
        let current = updater.currentVersion
        if updater.runningVM() != nil {
            guard Updater.restartAlert(version, current: current).runModal() == .alertFirstButtonReturn else { return }
            Task { await updater.restartFromMac() }
            return
        }
        let alert = Updater.checkAlert(.ready(version), current: current, busy: updater.busyNow)
        if alert.runModal() == .alertFirstButtonReturn { updater.install() }
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

    static let help = "OpenGL: the VM's apps and browsers draw with OpenGL on the Mac's GPU. Vulkan: the same, plus Vulkan apps on the Mac's GPU (KosmicKrisp on macOS 26 and newer, MoltenVK before); Vulkan windows reach the screen by a copy on the Mac. Automatic: Vulkan on macOS 26 and newer (KosmicKrisp), OpenGL before."

    private var picker: some View {
        Picker("Graphics", selection: $choice) {
            Text("Automatic (\(autoText))").tag(GraphicsChoice.auto)
            Text("OpenGL").tag(GraphicsChoice.opengl)
            Text("Vulkan (experimental)").tag(GraphicsChoice.vulkan)
        }
    }

    /// "Next start: OpenGL (why)", as the window said it before the (i).
    static func nextStart(_ p: GraphicsPlan) -> String {
        p.choice == .vulkan && !p.venus ? "Next start: \(p.summary)" : "Next start: \(p.summary) (\(p.why))"
    }

    /// In the setup the picker alone; in the VM window with the (i) and a
    /// line for the next start (two rows of the form).
    var body: some View {
        if let p = plan {
            LabeledContent("Graphics") {
                HStack(spacing: 8) {
                    picker.labelsHidden().fixedSize()
                    InfoButton(topic: "graphics", text: "\(Self.nextStart(p)).\n\n\(Self.help)")
                }
            }
            RowNote("Next start: \(p.summary)")
        } else {
            picker.help(Self.help)
        }
    }
}
