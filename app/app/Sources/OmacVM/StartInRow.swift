import AppKit
import OmacVMFeatures
import SwiftUI

/// "Start in" in the VM window: Window, Full screen (notch via Omanotch) or,
/// on a Mac whose built-in display has a notch now, Full screen including
/// notch (FullPanel, #339). One picker for two settings: the app's
/// startFullScreen (every VM) and this VM's notch-mode (StartIn). The same
/// notch-mode as `omacvm notch` / `omacvm fullscreen` and the control
/// centre's Full screen row; from the VM's next start.
struct StartInRow: View {
    let folder: URL
    @Binding var fullScreen: Bool
    /// The window pictures (--render-vm-window): as on a Mac with or without a notch.
    let previewNotch: Bool?
    @State private var mode: NotchMode
    @State private var hasNotch: Bool
    @State private var ready: Bool
    @State private var note: String?

    init(folder: URL, fullScreen: Binding<Bool>, previewNotch: Bool? = nil) {
        self.folder = folder
        _fullScreen = fullScreen
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

    private var choice: Binding<StartIn> {
        Binding(get: { StartIn.current(fullScreen: fullScreen, mode: mode, hasNotch: hasNotch) },
                set: { set($0) })
    }

    var body: some View {
        Group {
            LabeledContent("Start in") {
                HStack(spacing: 8) {
                    // The menu lists the whole titles; the closed button the
                    // short one (the full title does not fit the form's column).
                    Picker(selection: choice) {
                        ForEach(StartIn.choices(hasNotch: hasNotch), id: \.self) {
                            Text($0.title(hasNotch: hasNotch)).tag($0)
                        }
                    } label: {
                        Text("Start in")
                    } currentValueLabel: {
                        Text(choice.wrappedValue.shortTitle(hasNotch: hasNotch))
                    }
                    .labelsHidden()
                    InfoButton(topic: "Start in", text: StartIn.info(hasNotch: hasNotch))
                }
            }
            if choice.wrappedValue == .fullScreenNotch && !ready {
                RowNote(NotchArea.notReady)
            } else if let n = note {
                RowNote(n, error: n.hasPrefix("Could not"))
            } else if choice.wrappedValue == .fullScreenNotch {
                RowNote(StartIn.notchNote)
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

    private func set(_ c: StartIn) {
        let before = StartIn.current(fullScreen: fullScreen, mode: mode, hasNotch: hasNotch)
        guard c != before else { return }
        if let m = c.mode, m != mode {
            do {
                try NotchArea.write(m, folder: folder)
                mode = m
            } catch {
                note = "Could not save: \(error.localizedDescription)"
                return
            }
        }
        fullScreen = c.fullScreen
        Settings.startFullScreen = c.fullScreen
        note = "Applies on the next start."
    }
}
