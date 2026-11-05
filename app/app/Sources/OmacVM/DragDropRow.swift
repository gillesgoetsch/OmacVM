import Foundation
import OmacVMFeatures
import SwiftUI

/// Drag and drop of files from the Mac into the VM (feature drag-drop:
/// experimental, off by default; docs/drag-and-drop.md) in the VM window's
/// Sharing & Devices: one switch, the same feature as in the control centre
/// and `omacvm enable/disable drag-drop`. The same paths as MacIMERow: while
/// the VM runs it runs this app's omacvm for the VM (its omacvm-drop service
/// and share mount) and the port and share come with the next start; while
/// it is stopped it writes the record and a pending file, and the app sets
/// up the VM's part at the next start (FeatureStart).
struct DragDropRow: View {
    @ObservedObject var state: AppState
    @State private var record: String?
    @State private var pending: String?
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        let running = state.vmRunning()
        let row = DragDrop.row(record: record, pending: pending, running: running, busy: busy, cli: TerminalCommand.available)
        let n = note ?? row.note
        SettingRow(title: "Drag and drop files", subtitle: n,
                   subtitleIsError: n?.hasPrefix("Could not") == true, info: DragDrop.info, probe: "drag-drop") {
            if busy { ProgressView().controlSize(.small) }
            RowSwitch(title: "Drag and drop files", isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
                      enabled: row.enabled)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in note = nil; refresh() }
        .onChange(of: state.tick) { _, _ in if !busy { refresh() } }
        .onChange(of: running) { _, _ in note = nil; refresh() }
        .onReceive(NotificationCenter.default.publisher(for: FeatureStart.done)) { _ in refresh() }
    }

    private func refresh() {
        let f = state.config.folder
        record = try? String(contentsOf: f.appendingPathComponent("features"), encoding: .utf8)
        pending = try? String(contentsOf: f.appendingPathComponent(DragDrop.switchState.pendingFile), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running { run(value) } else { write(value) }
    }

    /// The VM is stopped: the record and the pending file, for its next start.
    private func write(_ value: Bool) {
        let f = state.config.folder
        let next = DragDrop.switchState.switchStopped(record: record, pending: pending, on: value)
        let pendingURL = f.appendingPathComponent(DragDrop.switchState.pendingFile)
        do {
            try next.record.write(to: f.appendingPathComponent("features"), atomically: true, encoding: .utf8)
            if let p = next.pending { try p.write(to: pendingURL, atomically: true, encoding: .utf8) }
            else if FileManager.default.fileExists(atPath: pendingURL.path) { try FileManager.default.removeItem(at: pendingURL) }
            note = nil
        } catch {
            note = "Could not switch: \(error.localizedDescription)"
        }
        refresh()
    }

    /// `omacvm enable|disable drag-drop` for this VM, off the main thread.
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = MacIMERow.run([value ? "enable" : "disable", DragDrop.feature, "--vm", c.name, "--vm-type", "app", "--yes"])
            if err == nil { try? FileManager.default.removeItem(at: c.folder.appendingPathComponent(DragDrop.switchState.pendingFile)) }
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
                else { note = "Restart the VM to use it." }
            }
        }
    }
}
