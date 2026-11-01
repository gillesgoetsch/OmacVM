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
    /// only logs it). True: go on. `personAsked`: AskKeys.
    @MainActor static func confirmStart(_ c: VMConfig, personAsked: Bool = true) -> Bool {
        guard let warn = warning(folder: c.folder, thisMac: Mac.hardwareID) else { return true }
        FileHandle.standardError.write(Data("OmacVM: \(c.name): \(warn)\n".utf8))
        if ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] != nil { return true }
        let alert = NSAlert()
        alert.messageText = "Start \(c.name)?"
        alert.informativeText = warn + " Start it only when it runs nowhere else."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Start Anyway")
        AskKeys.take(alert.window, personAsked: personAsked)
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
    /// A line under the header: red unless messageIsInfo.
    @Published var message: String? { didSet { if message == nil { messageIsInfo = false } } }
    @Published var messageIsInfo = false
    /// The settings' rows read their setting again when this changes
    /// (reloadSettings: the window back in front, every few seconds).
    @Published var tick = 0
    let creator = Creator()
    let storage = StorageModel()
    var startVM: () -> Void = {}
    /// A start that comes by itself, not from the person just now (main.swift sets it).
    var startVMUnasked: () -> Void = {}
    /// The running VM's window to the front (main.swift sets it).
    var showVM: () -> Void = {}
    /// This app's VM runs (main.swift sets it).
    var vmRunning: () -> Bool = { false }
    /// Check for Updates (main.swift sets it): a VM with a newer OmacVM.
    var checkForUpdates: () -> Void = {}

    /// Is this Mac set up for the shown VM (MacSetup: its helpers, their
    /// permissions, its token): the notice under the header and the header's
    /// Update VM. Looked at when the window shows, comes to the front or
    /// shows another VM, and before each start; nil until known.
    @Published private(set) var macSetup: MacSetup?
    private var macSetupRun = 0
    /// Update VM was chosen in the question before a start: start the VM
    /// when it is done (BuildView), with no helper question that time (the
    /// helpers just installed have macOS's own questions open).
    var startAfterUpdate = false
    var helpersQuietOnce = false

    func refreshMacSetup() {
        guard screen == .ready else { return }
        let c = config, notch = Mac.hasNotch
        macSetupRun += 1
        let run = macSetupRun
        DispatchQueue.global(qos: .utility).async {
            let s = MacSetup.probe(c, notch: notch)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.macSetupFound(s, folder: c.folder, run: run) }
            }
        }
    }

    /// A look's answer (also the one before a start), for the VM it was about.
    func macSetupFound(_ s: MacSetup?, folder: URL, run: Int? = nil) {
        if let run, run != macSetupRun { return }
        guard folder.standardizedFileURL == config.folder.standardizedFileURL else { return }
        if s != macSetup { macSetup = s }
    }

    /// A build or Update VM ended (Creator.onEnded), with the window or
    /// without it (a hidden run). A failed one stays on its screen (Back).
    func buildEnded(ok: Bool) {
        guard ok else { startAfterUpdate = false; return }
        let updated = creator.job == .update
        // Update VM shut the VM down cleanly: no run marker to warn about.
        if updated { try? FileManager.default.removeItem(at: config.folder.appendingPathComponent(RunMarker.fileName)) }
        screen = .ready
        if updated { reload() }   // its sizes; the VM stays the one shown
        if let w = creator.warning {
            say(w)
        } else if updated, let v = config.guestVersion {
            tell("OmacVM in \(config.name) is now \(v).")
        } else {
            message = nil
        }
        // Update VM from the question before a start: that start now (not
        // after a warning: the window keeps it in view).
        if updated, startAfterUpdate {
            startAfterUpdate = false
            if creator.warning == nil {
                // Read as the start asks (askMacHelpers), and gone after it
                // either way: a start that stopped early leaves no quiet one behind.
                helpersQuietOnce = true
                startVMUnasked()
                helpersQuietOnce = false
            }
        }
    }

    /// The notice's button and the question's: what fixes it. Update VM
    /// asks about the run marker unless the start just did.
    func fixMacSetup(_ s: MacSetup, askMarker: Bool = true) {
        switch s.fix {
        case .updateVM:
            updateVM(askMarker: askMarker)
        case .updateApp:
            checkForUpdates()
        case .settings, .loginItems:
            if let u = s.settingsURL.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
        case .none:
            break
        }
    }

    /// Update VM (the header's button, the notice's, the question before a
    /// start): the VM started without a window, OmacVM and its Mac helpers
    /// brought up to this app's, shut down.
    func updateVM(askMarker: Bool = true) {
        // A test build never updates a VM of the installed app.
        if let why = Paths.startProblem(config.folder) { say(why); startAfterUpdate = false; return }
        // Not shut down cleanly, or copied while it ran: asked first.
        if askMarker, !RunMarker.confirmStart(config) { startAfterUpdate = false; return }
        message = nil
        creator.update(config: config)
        screen = .building
    }

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
        creator.onEnded = { [weak self] ok in self?.buildEnded(ok: ok) }
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

    /// An error under the header.
    func say(_ text: String) {
        message = text
        messageIsInfo = false
    }

    /// Good news under the header (in grey).
    func tell(_ text: String) {
        message = text
        messageIsInfo = true
    }

    /// The shown VM's vm.env (`omacvm resources` may have changed it) and
    /// every row's setting, read again.
    func reloadSettings() {
        guard screen == .ready, let c = VMConfig.load(from: config.folder) else { return }
        if c != config { config = c }
        tick += 1
    }
}

/// What the app's window shows (WindowShell for every screen).
struct RootView: View {
    @ObservedObject var state: AppState
    /// The window pictures (RenderVMWindow).
    var preview: RenderVMWindow.Preview? = nil

    var body: some View {
        switch state.screen {
        case .install: InstallView(onDone: { state.installDone() })
        case .setup: SetupView(state: state)
        case .building: BuildView(state: state, creator: state.creator)
        case .ready: ReadyView(state: state, preview: preview)
        case .driveMissing: DriveMissingView(state: state)
        case .unavailable: UnavailableView(state: state)
        }
    }
}

/// A new VM: the same window as the settings, with the setup's sections.
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

    static let nav = [
        NavItem(id: "new", title: "New VM", symbol: "plus", rgb: 0x8E8E93),
        NavItem(id: "account", title: "Account", symbol: "person.fill", rgb: 0xFF9F0A),
        NavItem(id: "resources", title: "Resources", symbol: "cpu", rgb: 0x0A84FF),
        NavItem(id: "features", title: "Features", symbol: "switch.2", rgb: 0x2DB44E),
        NavItem(id: "storage", title: "Storage", symbol: "externaldrive", rgb: 0x5E5CE6),
    ]

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

    private var nameError: String? {
        if !state.config.name.isEmpty && !VMConfig.validName(state.config.name) { return "Letters, digits, spaces, . _ and - only (64 at most)." }
        if nameTaken { return "A VM named \(state.config.name) is there already: pick another name." }
        return nil
    }

    var body: some View {
        WindowShell(nav: Self.nav) {
            WindowHeader(title: "New Omarchy VM", facts: "Arch Linux ARM with Omarchy, made into a VM on this Mac.") {
                AppIconButton()
            } trailing: {
                // A VM copied here or on another drive: show it instead.
                Button("Open Existing VM…") { state.openExisting() }
                    .disabled(state.storage.moving != nil)
                    .help("Show a VM that is somewhere else (copied, or on another drive): its folder, or the folder it is in.")
                    .layoutProbe("open-existing")
                Button("Build") { build() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBuild)
                    .layoutProbe("start")
            }
        } notices: {
            if let m = state.message { MessageStrip(text: m, error: !state.messageIsInfo) { state.message = nil } }
            if let p = locationProblem { MessageStrip(text: p, error: true) { locationProblem = nil } }
            if let n = state.storage.note, state.storage.noteIsError { MessageStrip(text: n, error: true) }
        } content: {
            sections
        }
        .task {
            if let pb = await PrebuiltImage.lookup() { prebuilt = .found(pb) } else { prebuilt = .none }
        }
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "New VM", first: true)
            Card {
                how
                SettingRow(title: "VM name", subtitle: nameError, subtitleIsError: true, probe: "name") {
                    TextField("VM name", text: $state.config.name).labelsHidden().frame(width: 240)
                }
            }
        }
        .spySection("new")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Account")
            Card {
                SettingRow(title: "User name", subtitle: !state.config.user.isEmpty && !userOK ? "Lower-case letters, digits, - and _ only." : nil,
                           subtitleIsError: true, probe: "user") {
                    TextField("User name", text: $state.config.user).labelsHidden().frame(width: 240)
                }
                SettingRow(title: "Full name", probe: "full-name") {
                    TextField("Full name", text: $state.config.fullName).labelsHidden().frame(width: 240)
                }
                SettingRow(title: "Password", probe: "password") {
                    SecureField("Password", text: $password).labelsHidden().frame(width: 240)
                }
                SettingRow(title: "Password again", subtitle: !password2.isEmpty && password != password2 ? "The passwords differ." : nil,
                           subtitleIsError: true, probe: "password2") {
                    SecureField("Password again", text: $password2).labelsHidden().frame(width: 240)
                }
            }
            Text("Keyboard \(state.config.keyboard), \(state.config.timeZone), \(state.config.language), from the Mac.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 8).padding(.leading, 4)
        }
        .spySection("account")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Resources")
            Card {
                SettingRow(title: "Resources", subtitle: "\(Mac.tier(tier).cpus) CPUs and \(Mac.tier(tier).memoryGB) GB memory of this Mac's \(Mac.cores) and \(Mac.memoryGB) GB. More later in the VM's settings.",
                           probe: "resources") {
                    Picker("Resources", selection: $tier) {
                        ForEach(0..<4) { Text(Mac.tierNames[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow(title: "Graphics", info: GraphicsPicker.help, probe: "graphics") {
                    GraphicsPicker.picker($graphics).labelsHidden().fixedSize()
                }
                SettingRow(title: "Disk", subtitle: "It takes space on the Mac only as Omarchy fills it.", probe: "disk") {
                    Picker("Disk", selection: $state.config.diskGB) {
                        ForEach([64, 128, 256, 512], id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .spySection("resources")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Features")
            Card {
                SettingRow(title: "OmacVM Bridge", subtitle: "The Mac's Wi-Fi, Bluetooth, audio and media keys in Omarchy's bar.", probe: "bridge") {
                    RowSwitch(title: "OmacVM Bridge", isOn: $bridge)
                }
                SettingRow(title: "Trackpad gestures", subtitle: "Swipe between workspaces with the Mac's trackpad in full screen.", probe: "gestures") {
                    RowSwitch(title: "Trackpad gestures", isOn: $gestures)
                }
                if gestures && mouse.connected { MagicMouseRow() }
                SettingRow(title: "Log in automatically", subtitle: "The Mac's own lock protects Omarchy.", probe: "autologin") {
                    RowSwitch(title: "Log in automatically", isOn: $autologin)
                }
            }
        }
        .spySection("features")
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Storage")
            Card {
                VMsFolderRow(storage: state.storage)
                // Offered once, in the first setup; later in the VM window.
                if offerCLI { CommandLineRow() }
            }
        }
        .spySection("storage")
    }

    /// Shown at once; the choice comes when the lookup is done, so nothing
    /// changes under the user's hands later on.
    @ViewBuilder private var how: some View {
        switch prebuilt {
        case .checking:
            SettingRow(title: "How", subtitle: "Looking for a VM already built for this version…", probe: "how") {
                ProgressView().controlSize(.small)
            }
        case .found(let pb):
            SettingRow(title: "How", subtitle: usePrebuilt ? "Download it ready made (\(pb.size), Omarchy \(pb.omarchy)): a few minutes."
                                                         : "Build it here from Arch Linux ARM and Omarchy: 10 to 30 minutes.", probe: "how") {
                Picker("How", selection: $usePrebuilt) {
                    Text("Download").tag(true)
                    Text("Build Here").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        case .none:
            SettingRow(title: "How", subtitle: "Built here from Arch Linux ARM and Omarchy: 10 to 30 minutes (no ready made VM for this version).", probe: "how")
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

/// Copies a command for the VM's terminal; says "Copied" for 2 s.
struct CopyCommandButton: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
        .help("The command to run once in a terminal in the VM")
        .layoutProbe("copy-command")
    }
}

struct BuildView: View {
    @ObservedObject var state: AppState
    @ObservedObject var creator: Creator
    @State private var showDetails = false

    var body: some View {
        WindowShell {
            WindowHeader(title: creator.job == .build ? "Building \(state.config.name)" : "Updating OmacVM in \(state.config.name)",
                         pill: creator.failed == nil ? StatusPill(text: creator.job == .build ? "Building" : "Updating", dot: Look.orange)
                             : StatusPill(text: "Stopped", dot: Look.red),
                         facts: creator.step > 0 ? "Step \(creator.step) of \(creator.steps): \(creator.title)" : creator.title) {
                AppIconButton()
            } trailing: {
                if creator.failed != nil {
                    if let cmd = creator.manualKeyCommand {
                        CopyCommandButton(command: cmd)
                        InfoButton(topic: "SSH access", text: SSHRepair.info)
                    }
                    Button("Show Log") {
                        NSWorkspace.shared.open(creator.log ?? state.config.folder.appendingPathComponent("create.log"))
                    }
                    Button("Back") {
                        state.startAfterUpdate = false
                        state.screen = creator.job == .build ? .setup : .ready
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .layoutProbe("start")
                }
            }
        } notices: {
            if let error = creator.failed { MessageStrip(text: error, error: true) }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: creator.job == .build ? "Build" : "Update", first: true)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: Double(max(creator.step - 1, 0)), total: Double(creator.steps))
                        if let q = creator.kernelQuestion, creator.failed == nil {
                            KernelQuestionView(question: q, vm: state.config.name, creator: creator)
                        } else if creator.failed == nil {
                            BuildNowView(creator: creator)
                        } else {
                            Text(creator.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                }
                if creator.failed == nil {
                    Text("You can use your Mac meanwhile. Keep it awake and online.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.top, 8).padding(.leading, 4)
                }
                DisclosureGroup(isExpanded: $showDetails) {
                    BuildLogView(creator: creator)
                } label: {
                    Text("Details").font(.subheadline)
                }
                .padding(.top, 14)
                .padding(.leading, 2)
            }
        }
    }
}

/// Update VM's question before a kernel build: Arch Linux ARM has a newer
/// kernel than the VM's memory-optimized one. Later (the default) keeps it.
struct KernelQuestionView: View {
    let question: Creator.KernelQuestion
    let vm: String
    @ObservedObject var creator: Creator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Build the new memory-optimized kernel?").font(.headline)
            Text("Arch Linux ARM has kernel \(question.latest), \(vm) has \(question.have). Building it takes about \(question.low)-\(question.high) minutes on the VM's \(question.cpus) CPUs. Later keeps the current kernel; the next Update VM asks again, and omacvm update --kernel builds it any time.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Build Now") { creator.answerKernel(build: true) }
                    .layoutProbe("kernel-build")
                Button("Later") { creator.answerKernel(build: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .layoutProbe("kernel-later")
            }
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

/// The Graphics choice (Graphics.swift), in the setup and the VM window.
enum GraphicsPicker {
    static var autoText: String {
        let lib = Paths.qemu.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/libvulkan_kosmickrisp.dylib")
        let kk = FileManager.default.fileExists(atPath: lib.path)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return Graphics.autoPicksVulkan(macOSMajor: major, kosmicKrisp: kk) ? "Vulkan on this Mac" : "OpenGL on this Mac"
    }

    static let help = "OpenGL: the VM's apps and browsers draw with OpenGL on the Mac's GPU. Vulkan: the same, plus Vulkan apps on the Mac's GPU (KosmicKrisp on macOS 26 and newer, MoltenVK before); Vulkan windows reach the screen by a copy on the Mac. Automatic: Vulkan on macOS 26 and newer (KosmicKrisp), OpenGL before."

    static func picker(_ choice: Binding<GraphicsChoice>) -> some View {
        Picker("Graphics", selection: choice) {
            Text("Automatic (\(autoText))").tag(GraphicsChoice.auto)
            Text("OpenGL").tag(GraphicsChoice.opengl)
            Text("Vulkan (experimental)").tag(GraphicsChoice.vulkan)
        }
    }
}
