import AppKit
import ApplicationServices
import SwiftUI

/// What the launcher window shows.
enum Screen: Equatable {
    case install
    case setup
    case building
    case ready
}

@MainActor
final class AppState: ObservableObject {
    @Published var screen: Screen = .setup
    @Published var config: VMConfig
    @Published var message: String?
    let creator = Creator()
    var startVM: () -> Void = {}

    init() {
        if let existing = VMConfig.existing() {
            config = existing
            screen = existing.isReady ? .ready : .setup
        } else {
            screen = .setup
            var c = VMConfig()
            let t = Mac.tier(1)
            c.cpus = t.cpus
            c.memoryMB = t.memoryGB * 1024
            c.user = Mac.linuxUserName
            c.fullName = NSFullUserName()
            c.timeZone = Mac.timeZone
            c.language = Mac.language
            c.keyboard = Mac.keyboard
            config = c
        }
        afterInstall = screen
        if !Installer.isInstalled { screen = .install }
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
    @State private var location = Paths.vmsRoot.path
    @State private var locationProblem: String?

    private var userOK: Bool {
        state.config.user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }
    private var canBuild: Bool {
        userOK && !password.isEmpty && password == password2 && VMConfig.validName(state.config.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Omarchy VM").font(.title2.bold())
            Text("\(Product.name) installs Arch Linux ARM and Omarchy into a new VM. It takes 10 to 30 minutes and downloads a few GB.")
                .foregroundStyle(.secondary)
            Form {
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
                        Text("\(["Low", "Balanced", "High", "Best"][t]): \(v.cpus) CPUs, \(v.memoryGB) GB").tag(t)
                    }
                }
                Toggle("OmacVM Bridge: the Mac's Wi-Fi, Bluetooth, audio and media keys in Omarchy's bar", isOn: $bridge)
                Toggle("Trackpad gestures in full screen", isOn: $gestures)
                Toggle("Log in automatically (the Mac's own lock protects Omarchy)", isOn: $autologin)
                Picker("Disk", selection: $state.config.diskGB) {
                    ForEach([64, 128, 256, 512], id: \.self) { Text("\($0) GB (grows as it fills)").tag($0) }
                }
                HStack {
                    Text("Location")
                    Spacer()
                    Text(location).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Change…") { chooseLocation() }
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
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Where the VM's disk goes. An external drive works too (APFS)."
        if panel.runModal() == .OK, let url = panel.url {
            if let problem = VolumeCheck.problem(with: url) {
                locationProblem = problem
                return
            }
            locationProblem = nil
            UserDefaults.standard.set(url.path, forKey: "vmsRoot")
            location = url.path
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
        let on = { (b: Bool) in b ? "on" : "off" }
        // Omanotch off for now: see VMConfig.features.
        state.config.features = "bridge=\(on(bridge)) wallpaper=\(on(bridge)) gestures=\(on(gestures)) scroll-momentum=off omanotch=off mac-clock=on camera=on battery=\(on(Mac.hasBattery)) idle-lock=on autologin=\(on(autologin)) thp-kernel=off"
        state.screen = .building
        state.creator.start(config: state.config, password: password)
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

extension ReadyView {
    /// Moves the VM's folder to the Trash after a plain confirmation.
    func deleteVM() {
        let alert = NSAlert()
        alert.messageText = "Delete \(state.config.name)?"
        alert.informativeText = "The VM's disk and everything in Omarchy goes to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons[1].hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard state.config.folderIsSafe else {
            state.message = "Not deleted: \(state.config.folder.path) is not a VM folder of this app."
            return
        }
        do {
            try FileManager.default.trashItem(at: state.config.folder, resultingItemURL: nil)
            let fresh = AppState()
            state.config = fresh.config
            state.screen = fresh.config.isReady ? .ready : .setup
        } catch {
            state.message = "Could not delete: \(error.localizedDescription)"
        }
    }
}

struct ReadyView: View {
    @ObservedObject var state: AppState
    @State private var fullScreen = Settings.startFullScreen
    @State private var notch = Settings.useNotch

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.config.name).font(.title2.bold())
            Text("\(state.config.cpus) CPUs, \(state.config.memoryMB / 1024) GB memory, \(state.config.diskGB) GB disk, user \(state.config.user)")
                .foregroundStyle(.secondary)
            Toggle("Start in full screen", isOn: $fullScreen)
                .onChange(of: fullScreen) { _, v in Settings.startFullScreen = v }
            if Mac.hasNotch {
                Toggle("Full screen covers the notch strip (Omarchy's bar goes there; no Space of its own)", isOn: $notch)
                    .onChange(of: notch) { _, v in Settings.useNotch = v }
            }
            if let m = state.message { Text(m).foregroundStyle(.red) }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([state.config.folder]) }
                Button("Delete…") { deleteVM() }
                Spacer()
                Button("Start") { state.startVM() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
