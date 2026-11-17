import Foundation
import OmacVMFeatures
import SwiftUI

/// Fewer animations (feature fewer-animations: experimental, off by default;
/// docs/features.md) in the VM window's Display: one switch, the same feature
/// as in the control centre, `omacvm enable/disable fewer-animations` and
/// Omarchy's own animations toggle. The same paths as MissionControlRow: while
/// the VM runs it runs this app's omacvm for the VM, which switches it at once
/// (Hyprland reads its config again); while it is stopped it writes the record
/// and a pending file, and the app sets it up at the next start (FeatureStart).
/// Off and greyed out with the reason on an Omarchy below 4.5.
struct FewerAnimationsRow: View {
    @ObservedObject var state: AppState
    @State private var record: String?
    @State private var pending: String?
    @State private var omarchy: String?
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        let running = state.vmRunning()
        let row = FewerAnimations.row(record: record, pending: pending, omarchy: omarchy,
                                      running: running, busy: busy, cli: TerminalCommand.available)
        let n = note ?? row.note
        SettingRow(title: "Fewer animations", badge: "experimental", subtitle: n ?? FewerAnimations.subtitle,
                   subtitleIsError: n?.hasPrefix("Could not") == true, info: FewerAnimations.info, probe: FewerAnimations.feature) {
            if busy { ProgressView().controlSize(.small) }
            RowSwitch(title: "Fewer animations", isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
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
        pending = try? String(contentsOf: f.appendingPathComponent(FewerAnimations.switchState.pendingFile), encoding: .utf8)
        omarchy = try? String(contentsOf: f.appendingPathComponent("omarchy"), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running { run(value) } else { write(value) }
    }

    /// The VM is stopped: the record and the pending file, for its next start.
    private func write(_ value: Bool) {
        let f = state.config.folder
        let next = FewerAnimations.switchState.switchStopped(record: record, pending: pending, on: value)
        let pendingURL = f.appendingPathComponent(FewerAnimations.switchState.pendingFile)
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

    /// `omacvm enable|disable fewer-animations` for this VM, off the main thread.
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = MacIMERow.run([value ? "enable" : "disable", FewerAnimations.feature, "--vm", c.name, "--vm-type", "app", "--yes"])
            if err == nil { try? FileManager.default.removeItem(at: c.folder.appendingPathComponent(FewerAnimations.switchState.pendingFile)) }
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
            }
        }
    }
}
