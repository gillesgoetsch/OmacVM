import Foundation
import OmacVMFeatures
import SwiftUI

/// Prefer VP9 on YouTube (feature youtube-vp9: experimental, off by default;
/// docs/video-decode.md) in the VM window's General: one switch, the same
/// feature as in the control centre and `omacvm enable/disable youtube-vp9`.
/// The same paths as DragDropRow: while the VM runs it runs this app's
/// omacvm for the VM, which sets it up at once (the browsers take it at their
/// next start); while it is stopped it writes the record and a pending file,
/// and the app sets it up at the next start (FeatureStart). SettingsSections
/// shows it only where YouTubeVP9.shown says (a Mac without AV1 decoding, or
/// the switch on), in the Battery saver group. `groupBusy`: the Battery saver
/// switch is switching it (BatterySaverGroup).
struct YouTubeVP9Row: View {
    @ObservedObject var state: AppState
    var badge: String? = "experimental"
    var groupBusy = false
    @State private var record: String?
    @State private var pending: String?
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        let running = state.vmRunning()
        let row = YouTubeVP9.row(record: record, pending: pending, running: running, busy: busy || groupBusy, cli: TerminalCommand.available)
        let n = note ?? row.note
        SettingRow(title: "Prefer VP9 on YouTube", badge: badge, subtitle: n,
                   subtitleIsError: n?.hasPrefix("Could not") == true, info: YouTubeVP9.info, probe: YouTubeVP9.feature) {
            if busy || groupBusy { ProgressView().controlSize(.small) }
            RowSwitch(title: "Prefer VP9 on YouTube", isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
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
        pending = try? String(contentsOf: f.appendingPathComponent(YouTubeVP9.switchState.pendingFile), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running { run(value) } else { write(value) }
    }

    /// The VM is stopped: the record and the pending file, for its next start.
    private func write(_ value: Bool) {
        note = FeatureSwitch.writeStopped(YouTubeVP9.switchState, folder: state.config.folder, on: value).map { "Could not switch: \($0)" }
        refresh()
    }

    /// `omacvm enable|disable youtube-vp9` for this VM, off the main thread.
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = FeatureSwitch.runCLI([YouTubeVP9.switchState], on: value, config: c)
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
                else { note = value ? "On: restart Chrome or Chromium to use it." : "Off: restart Chrome or Chromium." }
            }
        }
    }
}
