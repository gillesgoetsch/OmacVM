import Foundation
import OmacVMFeatures
import SwiftUI

/// The Apple logo's light (feature logo-light, opt-in) in the VM window's
/// Display section: one switch, the same feature as `omacvm enable/disable
/// logo-light`. The same paths as YouTubeVP9Row: while the VM runs this app's
/// omacvm for the VM, while it is stopped the record and a pending file for
/// the next start (FeatureStart). SettingsSections shows it only where
/// LogoLight.shown says (a Mac with a lit logo, or the switch on).
struct LogoLightRow: View {
    @ObservedObject var state: AppState
    @State private var record: String?
    @State private var pending: String?
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        let running = state.vmRunning()
        let row = LogoLight.row(record: record, pending: pending, running: running, busy: busy, cli: TerminalCommand.available)
        let n = note ?? row.note ?? LogoLight.subtitle
        SettingRow(title: "The Apple logo's light", subtitle: n, subtitleIsError: n.hasPrefix("Could not"),
                   info: LogoLight.info, probe: LogoLight.feature) {
            if busy { ProgressView().controlSize(.small) }
            RowSwitch(title: "The Apple logo's light", isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
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
        pending = try? String(contentsOf: f.appendingPathComponent(LogoLight.switchState.pendingFile), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running {
            let c = state.config
            busy = true
            note = nil
            Task.detached {
                let err = FeatureSwitch.runCLI([LogoLight.switchState], on: value, config: c)
                await MainActor.run {
                    busy = false
                    refresh()
                    if let err { note = "Could not switch: \(err)" }
                    else { note = value ? "On: omacvm-logo in the VM sets the logo." : "Off: the logo is macOS's." }
                }
            }
        } else {
            note = FeatureSwitch.writeStopped(LogoLight.switchState, folder: state.config.folder, on: value).map { "Could not switch: \($0)" }
            refresh()
        }
    }
}

/// Touch display (Settings.touchDisplay, TouchDisplay, #843): experimental,
/// off by default; read by each start of the VM. SettingsSections shows it
/// only where TouchDisplay.shown says (a Mac with a touch display, or on).
struct TouchDisplayRow: View {
    var tick = 0
    @State private var on = Settings.touchDisplay

    var body: some View {
        SettingRow(title: "Touch display", badge: "experimental",
                   subtitle: "Taps, scrolling, drags and pinch on the Mac's touch display go to the VM.",
                   info: TouchDisplay.info, probe: "touch-display") {
            RowSwitch(title: "Touch display", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != Settings.touchDisplay { Settings.touchDisplay = v } }
        .onChange(of: tick) { _, _ in on = Settings.touchDisplay }
    }
}
