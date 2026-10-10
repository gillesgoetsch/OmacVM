import AppKit
import OmacVMFeatures
import SwiftUI

/// FullPanel (NotchArea, #339) in the VM window, right below "Start in full
/// screen": one switch per VM, from the VM's next start. Only on a Mac whose
/// built-in display has a notch now (asked again when displays change);
/// greyed out with a short reason while "Start in full screen" is off. The
/// same setting as `omacvm notch` and the control centre's notch row.
struct NotchAreaRow: View {
    let folder: URL
    let fullScreen: Bool
    /// The window pictures (--render-vm-window): as on a Mac with or without a notch.
    let previewNotch: Bool?
    @State private var mode: NotchMode
    @State private var hasNotch: Bool
    @State private var ready: Bool
    @State private var note: String?

    init(folder: URL, fullScreen: Bool, previewNotch: Bool? = nil) {
        self.folder = folder
        self.fullScreen = fullScreen
        self.previewNotch = previewNotch
        _mode = State(initialValue: NotchArea.read(folder: folder))
        _hasNotch = State(initialValue: previewNotch ?? Mac.hasNotch)
        _ready = State(initialValue: Self.ready(folder))
    }

    private static func ready(_ folder: URL) -> Bool {
        NotchArea.guestReady(folder: folder, features: try? String(
            contentsOf: folder.appendingPathComponent("features"), encoding: .utf8))
    }

    private func refresh(_ f: URL) {
        mode = NotchArea.read(folder: f)
        ready = Self.ready(f)
    }

    static let info = "Experimental. In full screen on the MacBook's own display, the VM also uses the strip beside the camera housing: Omarchy's bar sits there, split around the notch, and the windows get the rest. Omanotch is not needed for it and stays off while it is on; external displays stay as they are. It uses private macOS interfaces and falls back to the normal full screen when they are not there. Applies from the VM's next start."

    var body: some View {
        Group {
            if hasNotch {
                SwitchRow("Use the notch area (experimental)",
                          isOn: Binding(get: { mode == .fullpanel }, set: { set($0 ? .fullpanel : .native) }),
                          enabled: NotchArea.disabledReason(fullScreen: fullScreen) == nil) {
                    InfoButton(topic: "the notch area", text: Self.info)
                }
                if let why = NotchArea.disabledReason(fullScreen: fullScreen) {
                    RowNote(why)
                } else if mode == .fullpanel && !ready {
                    RowNote(NotchArea.notReady)
                } else if let n = note {
                    RowNote(n, error: n.hasPrefix("Could not"))
                }
            }
        }
        .onAppear { refresh(folder); hasNotch = previewNotch ?? Mac.hasNotch }
        .onChange(of: folder) { _, f in refresh(f); note = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotch = previewNotch ?? Mac.hasNotch
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // `omacvm notch`, the control centre or Update VM may have changed it meanwhile.
            refresh(folder)
        }
    }

    private func set(_ m: NotchMode) {
        guard m != mode else { return }
        do {
            try NotchArea.write(m, folder: folder)
            mode = m
            note = "Applies on the next start."
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }
}
