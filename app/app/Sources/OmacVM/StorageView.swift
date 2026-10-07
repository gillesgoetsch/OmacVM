import AppKit
import SwiftUI

/// The VMs folder, each VM's size and place, moves between folders and the
/// downloaded images. Shared by the setup, the settings and the start-up offers.
@MainActor
final class StorageModel: ObservableObject {
    struct Entry: Identifiable {
        var id: String { folder.path }
        var config: VMConfig
        var name: String { config.name }
        var folder: URL { config.folder }
        var size: Int64?
        /// In the hidden folder of 2.9 and older.
        var legacy: Bool
    }

    struct Moving {
        var name: String
        var phase: String
        var done: Int64
        var total: Int64
    }

    @Published var root = Paths.vmsRoot
    @Published var free: Int64?
    @Published var vms: [Entry] = []
    @Published var downloads: Int64?
    /// The downloads folders with something in them (for the Remove alert).
    @Published var downloadFolders: [URL] = []
    /// One line per VMs folder on a drive that is not connected.
    @Published var disconnected: [String] = []
    @Published var moving: Moving?
    @Published var note: String?
    @Published var noteIsError = false

    /// A VM runs or this app builds one: the start-up offers wait then.
    var appBusy: () -> Bool = { false }
    /// This app builds a VM (its downloads are in use).
    var building: () -> Bool = { false }
    /// A VM moved or was deleted: the app reloads the one it shows.
    var onMoved: () -> Void = {}
    private var mover: FolderMover?
    private var refreshRun = 0

    func refresh() {
        root = Paths.vmsRoot
        disconnected = Paths.vmsRoots.compactMap { r in
            Storage.missingDrive(for: r).map { "\($0) is not connected: its VMs (\(r.path)) are back once it is." }
        }
        let legacy = Paths.vmsRoot.standardizedFileURL.path == Paths.legacyVMsRoot.path ? "" : Paths.legacyVMsRoot.path
        vms = VMConfig.all().map {
            Entry(config: $0, size: nil,
                  legacy: $0.folder.deletingLastPathComponent().path == legacy)
        }
        refreshRun += 1
        let run = refreshRun, folders = vms.map(\.folder), root = root
        let dlFolders = Paths.allDownloads, old = Paths.oldDownloads
        DispatchQueue.global(qos: .utility).async {
            let free = Storage.freeBytes(at: root)
            let sizes = folders.map { Storage.allocatedSize(of: $0) }
            let dlSizes = dlFolders.map { Storage.downloadsSize($0) }
            let gone = Set(old.map(\.path)).subtracting(Storage.oldDownloadsKept(old).map(\.path))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !gone.isEmpty { Paths.oldDownloads = Paths.oldDownloads.filter { !gone.contains($0.path) } }
                    guard run == self.refreshRun else { return }
                    self.free = Storage.missingDrive(for: root) == nil ? free : nil
                    for (i, s) in sizes.enumerated() where i < self.vms.count { self.vms[i].size = s }
                    self.downloads = dlSizes.reduce(0, +)
                    self.downloadFolders = zip(dlFolders, dlSizes).filter { $0.1 > 0 }.map(\.0)
                }
            }
        }
    }

    private func say(_ text: String, error: Bool = false) {
        note = text
        noteIsError = error
    }

    nonisolated static func short(_ url: URL) -> String { Storage.short(url) }

    // MARK: The VMs folder

    /// Asks for a new VMs folder. With VMs elsewhere: move them, keep them
    /// where they are (new VMs only), or cancel.
    func changeRoot() {
        guard moving == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Storage.existingAncestor(root)
        panel.prompt = "Use This Folder"
        panel.message = "Where VMs go, one folder per VM. An external drive works too (APFS or Mac OS Extended)."
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        if let p = VolumeCheck.problem(with: url) { say(p, error: true); return }
        guard url.path != root.standardizedFileURL.path else { return }
        if Paths.vmsRoots.contains(where: { url.path.hasPrefix($0.path + "/") }) {
            say("That folder is inside a VMs folder; pick one outside it.", error: true)
            return
        }
        let elsewhere = VMConfig.all().filter { $0.folder.deletingLastPathComponent().path != url.path }
        if elsewhere.isEmpty {
            setRoot(url)
            say("New VMs go to \(Self.short(url)).")
            return
        }
        let alert = NSAlert()
        let n = elsewhere.count == 1 ? "\(elsewhere[0].name)" : "your \(elsewhere.count) VMs"
        alert.messageText = "Move \(n) to \(Self.short(url))?"
        alert.informativeText = Storage.sameVolume(elsewhere[0].folder, url)
            ? "Same drive: it takes a moment. Or keep the VMs where they are; only new VMs go to the new folder."
            : "To another drive the VMs are copied, checked and then deleted here; that takes a while. Or keep them where they are; only new VMs go to the new folder."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "New VMs Only")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: move(elsewhere, to: url, setRoot: true)
        case .alertSecondButtonReturn:
            setRoot(url)
            say("New VMs go to \(Self.short(url)); the others stay where they are.")
        default: break
        }
    }

    /// New VMs go to NEW; folders that still hold VMs (or whose drive is not
    /// connected) are still searched.
    private func setRoot(_ new: URL) {
        let old = Paths.vmsRoots
        Paths.vmsRoot = new
        let legacy = Paths.legacyVMsRoot.path
        Paths.otherVMsRoots = old.filter { r in
            r.path != new.standardizedFileURL.path && r.path != legacy
                && (Storage.missingDrive(for: r) != nil || VMsFolder.hasVMs(r, fm: .default))
        }
        // A folder left without VMs: its downloads go along on the same
        // drive, else they stay listed there (off the main thread: ps, drives).
        let kept = Set(Paths.vmsRoots.map(\.path))
        let left = old.filter { !kept.contains($0.path) }, to = Paths.downloads
        refresh()
        guard !left.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let lines = Storage.processLines()
            let stay = left.compactMap { Storage.dropDownloads(ofRoot: $0, to: to, lines: lines) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let known = Set(Paths.oldDownloads.map(\.path))
                    Paths.oldDownloads += stay.filter { !known.contains($0.path) }
                    self.refresh()
                }
            }
        }
    }

    /// The VMs in 2.9's hidden folder (none while that is the VMs folder:
    /// ~/OmacVM is taken by something else).
    var legacyVMs: [VMConfig] {
        let legacy = Paths.legacyVMsRoot.path
        guard Paths.vmsRoot.standardizedFileURL.path != legacy else { return [] }
        return VMConfig.all().filter { $0.folder.deletingLastPathComponent().path == legacy }
    }

    func moveLegacy() { move(legacyVMs, to: Paths.vmsRoot, setRoot: false) }

    /// Moves the VMs that are not in use (running, being built, or omacvm
    /// working on them); those stay where they are and keep working there.
    func move(_ all: [VMConfig], to target: URL, setRoot: Bool) {
        guard moving == nil, !all.isEmpty else { return }
        let busy = Set(Storage.busyFolders(all.map(\.folder)).map(\.path))
        let list = all.filter { !busy.contains($0.folder.path) }
        let stayed = all.filter { busy.contains($0.folder.path) }.map(\.name)
        let inUse = stayed.isEmpty ? "" : " In use, so not moved: \(stayed.joined(separator: ", ")); shut down and move later."
        guard !list.isEmpty else {
            if setRoot { self.setRoot(target) }
            say((setRoot ? "New VMs go to \(Self.short(target))." : "Nothing moved.") + inUse, error: true)
            return
        }
        let mover = FolderMover()
        self.mover = mover
        moving = Moving(name: list[0].name, phase: "Moving", done: 0, total: 0)
        var last = Date.distantPast
        mover.progress = { phase, done, total in
            // At most ten updates a second reach the window.
            let now = Date()
            guard now.timeIntervalSince(last) > 0.1 || done == total else { return }
            last = now
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.moving?.phase = phase
                    self.moving?.done = done
                    self.moving?.total = total
                }
            }
        }
        let jobs = list.map { ($0.name, $0.folder) }
        DispatchQueue.global(qos: .userInitiated).async {
            var moved = 0
            var failure: String?
            for (name, folder) in jobs {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.moving = Moving(name: name, phase: "Moving", done: 0, total: 0) }
                }
                // Checked again for each VM: one may have started meanwhile.
                if !Storage.busyFolders([folder]).isEmpty {
                    failure = "\(name) started meanwhile; it stays where it is."
                    break
                }
                do {
                    let new = try mover.move(folder, into: target)
                    Storage.excludeFromBackup(new)
                    moved += 1
                } catch StorageError.cancelled {
                    failure = "Cancelled: \(name) stays where it was."
                    break
                } catch {
                    failure = "\(name) was not moved: \(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.mover = nil
                    self.moving = nil
                    if setRoot { self.setRoot(target) } else { self.setRoot(Paths.vmsRoot) }
                    let done = moved == 0 ? "" : "Moved \(moved == 1 ? "1 VM" : "\(moved) VMs") to \(Self.short(target))."
                    if let failure {
                        self.say(done + " " + failure + inUse, error: true)
                    } else {
                        self.say(done + inUse, error: !inUse.isEmpty)
                    }
                    self.onMoved()
                }
            }
        }
    }

    func cancelMove() { mover?.cancel() }

    // MARK: Deleting a VM

    /// Moves a VM's folder to the Trash after a plain confirmation. A VM in
    /// use (running, or omacvm working on it) is not deleted.
    func delete(_ vm: VMConfig) {
        guard moving == nil else { return }
        guard Storage.busyFolders([vm.folder]).isEmpty else {
            say("\(vm.name) is in use: shut it down first, then delete it.", error: true)
            return
        }
        guard deleteAlert(vm).runModal() == .alertSecondButtonReturn else { return }
        guard vm.folderIsSafe else {
            say("Not deleted: \(vm.folder.path) is not a VM folder of this app.", error: true)
            return
        }
        do {
            try FileManager.default.trashItem(at: vm.folder, resultingItemURL: nil)
            say("\(vm.name) is in the Trash.")
        } catch {
            say("Could not delete \(vm.name): \(error.localizedDescription)", error: true)
        }
        onMoved()
    }

    func deleteAlert(_ vm: VMConfig) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Delete \(vm.name)?"
        let size = vms.first { $0.folder.path == vm.folder.path }?.size.map { " (\(Storage.format($0)))" } ?? ""
        alert.informativeText = "The VM's disk\(size) and everything in Omarchy goes to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }

    // MARK: Downloaded images

    /// Empties the app's caches of Omarchy images (Paths.allDownloads). Never
    /// the Mac's Downloads folder.
    func removeImages() {
        let lines = Storage.processLines()
        if building() || Paths.allDownloads.contains(where: { Storage.downloadsInUse($0, lines: lines) }) {
            say("A VM is being set up from these images; remove them once it is done.", error: true)
            return
        }
        let size = Storage.format(downloads ?? 0)
        guard removeImagesAlert().runModal() == .alertFirstButtonReturn else { return }
        let folders = Paths.allDownloads, old = Set(Paths.oldDownloads.map(\.path))
        DispatchQueue.global(qos: .utility).async {
            var failure: String?
            for f in folders where Storage.missingDrive(for: f) == nil {
                do {
                    try Storage.clearDownloads(f)
                    if old.contains(f.path) { Storage.removeIfEmpty(f) }
                } catch { failure = failure ?? error.localizedDescription }
            }
            let failed = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failed { self.say("Could not remove all downloaded images: \(failed)", error: true) }
                    else { self.say("Downloaded images removed (\(size)).") }
                    self.refresh()
                }
            }
        }
    }

    func removeImagesAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Remove the downloaded images (\(Storage.format(downloads ?? 0)))?"
        alert.informativeText = "These are the Omarchy images \(Product.name) downloaded to set up VMs, in \((downloadFolders.isEmpty ? [Paths.downloads] : downloadFolders).map { Self.short($0) }.joined(separator: " and ")). Your VMs keep everything; a new VM downloads them again.\n\nYour Mac's Downloads folder is not touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// What the downloaded images are (the row's tooltip).
    static let imagesHelp = "Omarchy images the app downloaded to set up VMs. Your VMs keep everything; a new VM downloads them again. Not your Mac's Downloads folder."
}

/// The VMs folder with its free space and a Change button (setup and settings).
struct VMsFolderRow: View {
    @ObservedObject var storage: StorageModel

    var body: some View {
        LabeledContent("VMs folder") {
            HStack {
                Spacer()
                Text(StorageModel.short(storage.root)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                if let free = storage.free {
                    Text("\(Storage.format(free)) free").foregroundStyle(.secondary)
                }
                Button("Change…") { storage.changeRoot() }
                    .disabled(storage.moving != nil)
            }
        }
        .onAppear { storage.refresh() }
    }
}

/// One VM's size with Show in Finder.
struct VMSizeRow: View {
    let vm: StorageModel.Entry

    var body: some View {
        Text(vm.size.map { Storage.format($0) } ?? "…").foregroundStyle(.secondary)
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([vm.folder])
        } label: { Image(systemName: "folder") }
            .help("Show in Finder")
    }
}

/// Settings: the VMs folder, the shown VM's size (All VMs… lists every one),
/// moves, downloaded images.
struct StorageSection: View {
    @ObservedObject var storage: StorageModel
    /// The VM the window shows.
    var selected: URL?
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage").font(.headline)
            VMsFolderRow(storage: storage)
            ForEach(storage.disconnected, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let vm = storage.vms.first(where: { $0.folder.path == selected?.path }) {
                    Text(vm.name)
                    Spacer()
                    VMSizeRow(vm: vm)
                } else {
                    Spacer()
                }
                Button("All VMs…") { showAll = true }
                    .disabled(storage.vms.isEmpty)
            }
            if !storage.legacyVMs.isEmpty && storage.moving == nil {
                HStack {
                    Text("2.9 and older kept VMs hidden in ~/Library.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Move to \(StorageModel.short(storage.root))") { storage.moveLegacy() }
                }
            }
            if let m = storage.moving {
                VStack(alignment: .leading, spacing: 4) {
                    if m.total > 0 {
                        ProgressView(value: Double(m.done), total: Double(m.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(m.total > 0
                             ? "\(m.phase) \(m.name): \(Storage.format(m.done)) of \(Storage.format(m.total))"
                             : "Moving \(m.name)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { storage.cancelMove() }
                    }
                }
            }
            HStack {
                Text("Downloaded images")
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Spacer()
                Text(storage.downloads.map { Storage.format($0) } ?? "…").foregroundStyle(.secondary)
                Button("Remove…") { storage.removeImages() }
                    .disabled(storage.moving != nil || (storage.downloads ?? 0) == 0)
            }
            .help(StorageModel.imagesHelp)
            if let n = storage.note {
                Text(n).font(.caption).foregroundStyle(storage.noteIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showAll) {
            AllVMsView(storage: storage, selected: selected) { showAll = false }
        }
    }
}

/// Every VM with its size, Show in Finder and Delete.
struct AllVMsView: View {
    @ObservedObject var storage: StorageModel
    var selected: URL?
    var done: () -> Void

    /// Nil while a size is still counted.
    private var total: Int64? {
        let sizes = storage.vms.compactMap(\.size)
        return sizes.count == storage.vms.count ? sizes.reduce(0, +) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All VMs").font(.headline)
            ForEach(storage.vms) { vm in
                HStack {
                    Text(vm.name)
                    if vm.folder.path == selected?.path {
                        Text("this one").font(.caption).foregroundStyle(.secondary)
                    }
                    if vm.legacy {
                        Text("in the old hidden folder").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VMSizeRow(vm: vm)
                    Button {
                        storage.delete(vm.config)
                    } label: { Image(systemName: "trash") }
                        .help("Delete…")
                        .disabled(storage.moving != nil)
                }
            }
            if storage.vms.isEmpty {
                Text("No VMs.").foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Total").foregroundStyle(.secondary)
                Spacer()
                Text(total.map { Storage.format($0) } ?? "…").foregroundStyle(.secondary)
            }
            if let n = storage.note {
                Text(n).font(.caption).foregroundStyle(storage.noteIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The VMs folder is on a drive that is not connected, and no VM is found.
struct DriveMissingView: View {
    @ObservedObject var state: AppState

    private var drive: (name: String, root: URL)? {
        Storage.missingDrive(for: Paths.vmsRoot).map { ($0, Paths.vmsRoot) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(drive?.name ?? "The drive") is not connected").font(.title2.bold())
            Text("Your VMs are in \(drive?.root.path ?? "a folder on it"). Connect the drive, then click Try Again.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Use Another Folder…") {
                    state.storage.changeRoot()
                    state.reload()
                }
                Spacer()
                Button("Try Again") { state.reload() }
                    .keyboardShortcut(.defaultAction)
            }
            if let n = state.storage.note {
                Text(n).font(.caption).foregroundStyle(state.storage.noteIsError ? .red : .secondary)
            }
        }
    }
}
