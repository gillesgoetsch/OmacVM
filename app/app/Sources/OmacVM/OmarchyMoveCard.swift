import AppKit
import OmacVMWindow
import SwiftUI

/// "Move to Omarchy 4.5": the VM folder's files and app/scripts/move-vm.sh
/// (rules in OmacVMWindow/OmarchyMove.swift).
enum MoveFiles {
    static func journalURL(_ c: VMConfig) -> URL { c.folder.appendingPathComponent(OmarchyMove.journalName) }
    static func backupURL(_ c: VMConfig) -> URL { c.folder.appendingPathComponent(OmarchyMove.backupName) }
    static func stopURL(_ c: VMConfig) -> URL { c.folder.appendingPathComponent(OmarchyMove.journalName + ".stop") }

    static func journal(_ c: VMConfig) -> OmarchyMove.Journal? {
        (try? String(contentsOf: journalURL(c), encoding: .utf8)).flatMap(OmarchyMove.Journal.parse)
    }

    static func record(_ c: VMConfig) -> String? {
        try? String(contentsOf: c.folder.appendingPathComponent(OmarchyMove.recordName), encoding: .utf8)
    }

    static func backupExists(_ c: VMConfig) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(c).appendingPathComponent("disk.img").path)
    }

    /// The journal's process runs (a move of another window or app copy):
    /// its pid is alive and the Mac has not restarted since (a pid from
    /// before a restart belongs to another process now).
    static func alive(_ j: OmarchyMove.Journal) -> Bool {
        guard j.pid > 1, j.pid != getpid(), kill(j.pid, 0) == 0 else { return false }
        guard let b = j.other.first(where: { $0.0 == "boot" })?.1, !b.isEmpty else { return true }
        return b == bootTime
    }

    /// kern.boottime's seconds, as move-vm.sh writes them.
    static let bootTime: String = {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return "" }
        return String(tv.tv_sec)
    }()

    static func card(_ c: VMConfig) -> OmarchyMove.Card {
        let j = journal(c)
        return OmarchyMove.card(recordText: record(c), journal: j, backupExists: backupExists(c), alive: j.map(alive) ?? false)
    }

    /// A move not over yet (running, failed, interrupted): Start, Update VM,
    /// disk changes, Storage moves and Delete VM wait for Resume or Undo.
    static func openWhy(_ c: VMConfig) -> String? {
        guard let j = journal(c), j.open else { return nil }
        return "\(c.name) is in the middle of its move to Omarchy 4.5: Resume or Undo it first (at the top of its settings)."
    }

    /// The Mac's checks before a move (step 1 says the same: move-vm.sh plan).
    static func problem(_ c: VMConfig) -> String? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        let allocated = Int64((try? c.disk.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        let apfs = (try? c.folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning
        return OmarchyMove.problem(apfs: apfs, freeBytes: VMDisk.info(c)?.freeBytes, allocated: allocated,
                                   diskJobPending: VMDisk.jobs(c).contains(.grow), resizePending: VMDisk.resize(c) != nil,
                                   otherCopy: Paths.startProblem(c.folder))
    }

    static func need(_ c: VMConfig) -> Int64 {
        let allocated = Int64((try? c.disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        return OmarchyMove.need(allocated: allocated)
    }

    /// move-vm.sh undo, delete-backup or keep (seconds: renames and a delete),
    /// off the main thread. The error line on failure.
    static func run(_ command: String, _ c: VMConfig) async -> String? {
        let script = Paths.scripts.appendingPathComponent("move-vm.sh")
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, c.folder.path, command]
            p.environment = TestIdentity.environment()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return "Could not run move-vm.sh: \(error.localizedDescription)" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data.prefix(8192), as: UTF8.self)
            let logURL = c.folder.appendingPathComponent("logs/move-4.5-actions.log")
            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data("\(Date()) \(command): exit \(p.terminationStatus)\n\(text)".utf8)); try? h.close()
            }
            guard p.terminationStatus != 0 else { return nil }
            let err = text.split(separator: "\n").last { $0.hasPrefix("ERROR:") }.map { String($0.dropFirst(6)) }
            return (err ?? text.split(separator: "\n").last.map(String.init) ?? "move-vm.sh \(command) failed")
                .trimmingCharacters(in: .whitespaces)
        }.value
    }
}

/// The move under the header (docs/design/settings-3.1's strips): the offer
/// on every Omarchy 4.0 VM (it stays until the VM is moved; no ×), what
/// blocks it, a stopped move with Resume and Undo, and after a move Undo and
/// Delete the old backup. While the move runs the window shows its progress
/// (BuildView, MoveStepList).
struct OmarchyMoveCard: View {
    @ObservedObject var state: AppState
    var running: Bool
    /// The window pictures: this state, this check and this backup size.
    var preview: Preview? = nil

    struct Preview {
        var card: OmarchyMove.Card
        var problem: String? = nil
        var backup: (bytes: Int64, exact: Bool)? = nil
        var sheet: Sheet? = nil
    }

    enum Sheet: String, Identifiable {
        case move, undo, delete, keep
        var id: String { rawValue }
    }

    @State private var sheet: Sheet?
    @State private var busy = false

    /// What the card shows, read from the VM folder each time the window
    /// draws it (state.tick: the window back in front, every few seconds,
    /// after each action). A few small files: no waiting.
    private struct Now {
        var card = OmarchyMove.Card.hidden
        var problem: String?
        var backup: (bytes: Int64, exact: Bool)?
    }

    private var now: Now {
        if let p = preview { return Now(card: p.card, problem: p.problem, backup: p.backup) }
        _ = state.tick
        let c = state.config
        var n = Now(card: MoveFiles.card(c))
        switch n.card {
        case .offer, .failed, .interrupted: n.problem = MoveFiles.problem(c)
        case .done: n.backup = OmarchyMove.backupBytes(MoveFiles.backupURL(c))
        default: break
        }
        return n
    }

    var body: some View {
        let n = now
        let card = n.card, problem = n.problem, backup = n.backup
        VStack(spacing: 0) {
            switch card {
            case .hidden:
                EmptyView()
            case .offer:
                strip(icon: "arrow.up.circle.fill", tint: .accentColor, background: Look.banner, line: Look.bannerLine,
                      title: "Omarchy 4.5 is available for this VM",
                      text: problem ?? "Moves Omarchy to its official ARM packages, about 20-40 minutes. A backup of the disk is kept, so you can undo it.",
                      textIsError: problem != nil) {
                    Button("Move to Omarchy 4.5…") { sheet = .move }
                        .buttonStyle(.borderedProminent)
                        .disabled(problem != nil || busy || state.storage.moving != nil)
                        .layoutProbe("move-start")
                }
            case .running(let step):
                strip(icon: "arrow.triangle.2.circlepath", tint: Look.orange, background: Look.header, line: Look.hairline,
                      title: "Moving to Omarchy 4.5: step \(step) of \(OmarchyMove.steps.count)",
                      text: "\(OmarchyMove.stepTitle(step)). Another OmacVM window runs this move; it shows the progress.",
                      textIsError: false) { EmptyView() }
            case .failed(let step, let reason, let resumable), .interrupted(let step, let reason, let resumable):
                let stopped = { if case .interrupted = card { return true } else { return false } }()
                strip(icon: "exclamationmark.triangle.fill", tint: Look.red, background: Look.red.opacity(0.08), line: Look.hairline,
                      title: (stopped ? "The move to Omarchy 4.5 was interrupted" : "The move to Omarchy 4.5 stopped")
                          + " at step \(step) of \(OmarchyMove.steps.count)",
                      text: stoppedText(reason: reason, interrupted: stopped, resumable: resumable, problem: problem),
                      textIsError: false) {
                    Button("Keep This Disk…") { sheet = .keep }
                        .disabled(busy || running)
                        .layoutProbe("move-keep")
                    Button("Undo…") { sheet = .undo }
                        .disabled(busy || running)
                        .layoutProbe("move-undo")
                    if resumable {
                        Button("Resume") { state.moveVM(resume: true) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || running || problem != nil)
                            .layoutProbe("move-resume")
                    }
                }
            case .done(let since, let kept):
                strip(icon: kept ? "externaldrive.fill" : "checkmark.circle.fill", tint: kept ? Color.secondary : Look.green,
                      background: Look.header, line: Look.hairline,
                      title: kept ? "You kept this disk after the move stopped"
                                  : "On Omarchy 4.5" + (OmarchyMove.dateText(since).isEmpty ? "" : " since \(OmarchyMove.dateText(since))"),
                      text: "The disk from before the move is kept" + (backup.map { ", \(OmarchyMove.sizeText($0)) on this drive" } ?? "")
                          + ". Undo puts it back; delete it when all is well.",
                      textIsError: false) {
                    Button("Undo Move…") { sheet = .undo }
                        .disabled(busy || running)
                        .layoutProbe("move-undo")
                    Button("Delete the Old Backup…") { sheet = .delete }
                        .disabled(busy || running)
                        .layoutProbe("move-delete")
                }
            }
        }
        .onAppear { if let s = preview?.sheet, sheet == nil { sheet = s } }
        .sheet(item: $sheet) { s in
            switch s {
            case .move:
                MoveConfirmSheet(vm: state.config.name, running: running, need: preview == nil ? MoveFiles.need(state.config) : 31 * DiskSize.gib,
                                 free: preview == nil ? VMDisk.info(state.config)?.freeBytes : 212 * DiskSize.gib) { go in
                    sheet = nil
                    if go { state.moveVM(resume: false) }
                }
            case .undo:
                MoveUndoSheet(vm: state.config.name, afterMove: { if case .done(_, false) = now.card { return true } else { return false } }(),
                              since: backupDate) { go in
                    sheet = nil
                    if go { act("undo", done: "\(state.config.name) is back on the disk from before the move.") }
                }
            case .delete:
                MoveDeleteSheet(size: now.backup.map(OmarchyMove.sizeText)) { go in
                    sheet = nil
                    if go { act("delete-backup", done: "The old backup is deleted.") }
                }
            case .keep:
                MoveKeepSheet(vm: state.config.name) { go in
                    sheet = nil
                    if go { act("keep", done: nil) }
                }
            }
        }
    }

    private var backupDate: String {
        preview != nil ? "5 November 2026" : OmarchyMove.dateText(MoveFiles.journal(state.config)?.backupAt ?? "")
    }

    private func stoppedText(reason: String, interrupted: Bool, resumable: Bool, problem: String?) -> String {
        var s = reason.isEmpty
            ? (interrupted ? "OmacVM quit or the Mac turned off during the move." : "The move did not finish.")
            : reason
        if !s.hasSuffix(".") { s += "." }
        // The script's reasons often say the next step already.
        if !s.contains("Undo") && !s.contains("Resume") {
            s += resumable ? " Resume goes on from there; Undo brings back the disk from before."
                           : " It cannot go on from there: Undo brings back the disk from before."
        }
        if let p = problem, resumable { s += " " + p }
        return s
    }

    @ViewBuilder
    private func strip<Buttons: View>(icon: String, tint: Color, background: Color, line: Color, title: String, text: String,
                                      textIsError: Bool, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if icon.hasSuffix(".fill") {
                    Image(systemName: icon).foregroundStyle(.white, tint)
                } else {
                    Image(systemName: icon).foregroundStyle(tint)
                }
            }
            .font(.system(size: 22))
            .frame(width: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(textIsError ? Look.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .layoutProbe("move-text")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { buttons() }.fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(background, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .layoutProbe("move-card")
    }

    private func act(_ command: String, done: String?) {
        guard preview == nil else { return }
        busy = true
        let c = state.config
        Task {
            let err = await MoveFiles.run(command, c)
            busy = false
            if let err { state.say(err) } else if let done { state.tell(done) }
            if let fresh = VMConfig.load(from: c.folder), fresh.folder == state.config.folder { state.config = fresh }
            state.tick += 1
            state.storage.refresh()
        }
    }
}

/// The step list of a running move (BuildView, job .move): done, now, next.
struct MoveStepList: View {
    let step: Int
    let failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(OmarchyMove.steps.enumerated()), id: \.offset) { i, title in
                let n = i + 1
                HStack(spacing: 8) {
                    Group {
                        if n < step {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Look.green)
                        } else if n == step {
                            if failed {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Look.red)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(n == step ? .semibold : .regular)
                        .foregroundStyle(n > step ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title): \(n < step ? "done" : n == step ? (failed ? "stopped" : "now") : "next")")
            }
        }
        .layoutProbe("move-steps")
    }
}

// MARK: Sheets

struct MoveConfirmSheet: View {
    let vm: String
    let running: Bool
    let need: Int64
    let free: Int64?
    var done: (Bool) -> Void

    var body: some View {
        SheetFrame(title: "Move \(vm) to Omarchy 4.5?", width: 470) {
            VStack(alignment: .leading, spacing: 10) {
                point("externaldrive.badge.checkmark", "A backup of the disk comes first. Until you delete it, Undo puts \(vm) back as it is now.")
                point("arrow.up.circle", "Omarchy moves to 4.5 on its official ARM packages. The VM runs without a window, restarts once and shuts down. About 20-40 minutes; keep the Mac awake and online.")
                point("doc.on.doc", "Your files, apps and settings in Omarchy stay.")
                point("internaldrive", "Needs up to \(DiskSize.text(need)) free on this drive" + (free.map { " (it has \(DiskSize.text($0)))." } ?? "."))
                if running {
                    Text("\(vm) runs: it shuts down first.").font(.subheadline).foregroundStyle(Look.orange)
                }
            }
            .layoutProbe("move-confirm-text")
        } buttons: {
            Button("Cancel") { done(false) }
                .keyboardShortcut(.cancelAction)
            Button(running ? "Shut Down and Move" : "Move to Omarchy 4.5") { done(true) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .layoutProbe("move-confirm")
        }
        .onExitCommand { done(false) }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Undo: after a finished move it costs what was saved in the VM since (D2).
struct MoveUndoSheet: View {
    let vm: String
    let afterMove: Bool
    let since: String
    var done: (Bool) -> Void

    var body: some View {
        DestructiveSheet(symbol: "arrow.uturn.backward.circle", title: afterMove ? "Undo the move to Omarchy 4.5?" : "Undo the move?",
                         text: afterMove
                            ? "\(vm) goes back to the disk from before the move\(since.isEmpty ? "" : " (\(since))"), on Omarchy 4.0. Everything saved in \(vm) since then is lost: files, apps and settings. The Omarchy 4.5 disk is deleted."
                            : "\(vm) goes back to the disk from before the move. The partly moved disk is deleted.",
                         action: "Undo Move", probe: "move-undo-confirm", done: done)
    }
}

struct MoveDeleteSheet: View {
    let size: String?
    var done: (Bool) -> Void

    var body: some View {
        DestructiveSheet(symbol: "trash", title: "Delete the old backup?",
                         text: "It frees \(size ?? "its space") on this drive. Undo will no longer be possible.",
                         action: "Delete", probe: "move-delete-confirm", done: done)
    }
}

struct MoveKeepSheet: View {
    let vm: String
    var done: (Bool) -> Void

    var body: some View {
        DestructiveSheet(symbol: "externaldrive", title: "Keep this disk as it is?",
                         text: "\(vm) starts as the move left it, partly moved. The backup stays, so Undo is still possible until you delete it.",
                         action: "Keep This Disk", probe: "move-keep-confirm", done: done, red: false)
    }
}

/// A question with Cancel as the default and the action in red (DeleteSheet's look).
struct DestructiveSheet: View {
    let symbol: String
    let title: String
    let text: String
    let action: String
    let probe: String
    var done: (Bool) -> Void
    var red = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(red ? Look.red : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { done(false) }
                    .keyboardShortcut(.defaultAction)
                Button { done(true) } label: { Text(action).foregroundStyle(red ? Look.red : Color.primary) }
                    .layoutProbe(probe)
            }
        }
        .padding(16)
        .frame(width: 430)
        .background(Look.window, ignoresSafeAreaEdges: [])
        .onExitCommand { done(false) }
    }
}

/// Storage & Updates: the backup from before the move, while it is kept.
struct MoveBackupRow: View {
    @ObservedObject var state: AppState
    var preview: (bytes: Int64, exact: Bool)? = nil

    /// Read each time the window draws it (state.tick), like the card.
    private var size: (bytes: Int64, exact: Bool)?? {
        if let p = preview { return .some(p) }
        _ = state.tick
        guard MoveFiles.backupExists(state.config) else { return nil }
        return .some(OmarchyMove.backupBytes(MoveFiles.backupURL(state.config)))
    }

    var body: some View {
        if let s = size {
            SettingRow(title: "Omarchy 4.0 backup",
                       subtitle: "The disk from before the move to Omarchy 4.5" + (s.map { ", \(OmarchyMove.sizeText($0)) on this drive." } ?? "."),
                       info: "Kept until you delete it at the top of these settings (Delete the Old Backup…), never on its own. "
                           + "Undo Move puts it back. A VM with this backup moves to another drive only after it is deleted or undone: a copy would take its full size.",
                       probe: "move-backup") {
                EmptyView()
            }
        }
    }
}
