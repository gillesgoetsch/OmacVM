import Foundation
import OmacVMFeatures
import SwiftUI

/// Fewer animations (feature fewer-animations: experimental, off by default;
/// docs/features.md) in the VM window's Battery saver group: one switch, the
/// same feature as in the control centre and `omacvm enable/disable
/// fewer-animations`. The same paths as MissionControlRow: while the VM runs
/// it runs this app's omacvm for the VM, which switches it at once (Hyprland
/// reads its config again); while it is stopped it writes the record and a
/// pending file, and the app sets it up at the next start (FeatureStart).
/// `groupBusy`: the Battery saver switch is switching it (BatterySaverGroup).
struct FewerAnimationsRow: View {
    @ObservedObject var state: AppState
    var badge: String? = "experimental"
    var groupBusy = false
    @State private var record: String?
    @State private var pending: String?
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        let running = state.vmRunning()
        let row = FewerAnimations.row(record: record, pending: pending, running: running,
                                      busy: busy || groupBusy, cli: TerminalCommand.available)
        let n = note ?? row.note
        SettingRow(title: "Fewer animations", badge: badge, subtitle: n ?? FewerAnimations.subtitle,
                   subtitleIsError: n?.hasPrefix("Could not") == true, info: FewerAnimations.info, probe: FewerAnimations.feature) {
            if busy || groupBusy { ProgressView().controlSize(.small) }
            RowSwitch(title: "Fewer animations", isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
                      enabled: row.enabled)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in note = nil; refresh() }
        .onChange(of: state.tick) { _, _ in if !busy { refresh() } }
        .onChange(of: groupBusy) { _, _ in note = nil; refresh() }
        .onChange(of: running) { _, _ in note = nil; refresh() }
        .onReceive(NotificationCenter.default.publisher(for: FeatureStart.done)) { _ in refresh() }
    }

    private func refresh() {
        let f = state.config.folder
        record = try? String(contentsOf: f.appendingPathComponent("features"), encoding: .utf8)
        pending = try? String(contentsOf: f.appendingPathComponent(FewerAnimations.switchState.pendingFile), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running { run(value) } else { write(value) }
    }

    /// The VM is stopped: the record and the pending file, for its next start.
    private func write(_ value: Bool) {
        note = FeatureSwitch.writeStopped(FewerAnimations.switchState, folder: state.config.folder, on: value).map { "Could not switch: \($0)" }
        refresh()
    }

    /// `omacvm enable|disable fewer-animations` for this VM, off the main thread.
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = FeatureSwitch.runCLI([FewerAnimations.switchState], on: value, config: c)
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
            }
        }
    }
}
