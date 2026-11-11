import Foundation
import OmacVMFeatures
import SwiftUI

/// Mission Control in the VM (feature mission-control: off by default;
/// docs/features.md) in the VM window's Input: one switch, the same
/// feature as in the control centre and `omacvm enable/disable
/// mission-control`. The same paths as DragDropRow: while the VM runs it runs
/// this app's omacvm for the VM, which switches it at once; while it is
/// stopped it writes the record and a pending file, and the app sets it up
/// at the next start (FeatureStart). Off and greyed out with the reason on
/// an Omarchy below 4.5 and with Trackpad gestures off. Its picture
/// (MissionControlPicture) shows what it does, as Swipe out to macOS's row.
struct MissionControlRow: View {
    @ObservedObject var state: AppState
    /// This VM has trackpad gestures off: nothing to swipe with there.
    var gesturesOff = false
    @State private var record: String?
    @State private var pending: String?
    @State private var omarchy: String?
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        let running = state.vmRunning()
        let row = MissionControl.row(record: record, pending: pending, omarchy: omarchy, gesturesOff: gesturesOff,
                                     running: running, busy: busy, cli: TerminalCommand.available)
        let n = note ?? row.note
        SettingRow(title: "Mission Control", subtitle: n ?? MissionControl.subtitle,
                   subtitleIsError: n?.hasPrefix("Could not") == true, info: MissionControl.info, probe: "mission-control") {
            MissionControlPicture()
            if busy { ProgressView().controlSize(.small) }
            RowSwitch(title: "Mission Control", isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
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
        pending = try? String(contentsOf: f.appendingPathComponent(MissionControl.switchState.pendingFile), encoding: .utf8)
        omarchy = try? String(contentsOf: f.appendingPathComponent("omarchy"), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running { run(value) } else { write(value) }
    }

    /// The VM is stopped: the record and the pending file, for its next start.
    private func write(_ value: Bool) {
        let f = state.config.folder
        let next = MissionControl.switchState.switchStopped(record: record, pending: pending, on: value)
        let pendingURL = f.appendingPathComponent(MissionControl.switchState.pendingFile)
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

    /// `omacvm enable|disable mission-control` for this VM, off the main thread.
    /// Off also shows windows it left hidden and restarts a shell that hangs
    /// with it on screen (the VM step's repair).
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = MacIMERow.run([value ? "enable" : "disable", MissionControl.feature, "--vm", c.name, "--vm-type", "app", "--yes"])
            if err == nil { try? FileManager.default.removeItem(at: c.folder.appendingPathComponent(MissionControl.switchState.pendingFile)) }
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
            }
        }
    }
}
