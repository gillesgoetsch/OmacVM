import AppKit
import OmacVMFeatures
import SwiftUI

/// "Start in" in the VM window: Window, Full screen (notch via Omanotch) or,
/// on a Mac whose built-in display has a notch now, Full screen including
/// notch (FullPanel, #339), as pictures. One choice for two settings: the
/// app's startFullScreen (every VM) and this VM's notch-mode (StartIn). The
/// same notch-mode as `omacvm notch` / `omacvm fullscreen` and the control
/// centre's Full screen row.
struct StartInRow: View {
    @ObservedObject var state: AppState
    /// The window pictures: as on a Mac with or without a notch, with or
    /// without macOS keeping the menu bar in full screen.
    var previewNotch: Bool?
    var previewMenuBar: Bool? = nil
    @State private var fullScreen = Settings.startFullScreen
    /// Keep the Dock away (its own row): the menu bar note follows it at once.
    @AppStorage("keepDockAway") private var keepDockAway = true
    @State private var mode = NotchMode.native
    @State private var hasNotch = false
    @State private var ready = false
    @State private var error: String?

    private var folder: URL { state.config.folder }
    private var current: StartIn { StartIn.current(fullScreen: fullScreen, mode: mode, hasNotch: hasNotch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start in").fontWeight(.semibold)
            // 12 pt between the pictures, less when the scroll bar is always
            // shown (a mouse, or System Settings): it takes 15 pt, three
            // pictures with 12 pt then need 11 pt more than the row has, and
            // the whole window slid 5 pt to the left (macOS 15 CI, 3.2.17).
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(StartIn.choices(hasNotch: hasNotch).enumerated()), id: \.element) { i, c in
                    if i > 0 { Spacer(minLength: 2).frame(maxWidth: 12) }
                    PictureChoice(title: c.caption, subtitle: c.detail(hasNotch: hasNotch), selected: c == current, width: 164) {
                        set(c)
                    } picture: {
                        StartInPicture(kind: Self.kind(c), notch: hasNotch)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            if let n = note {
                Text(n.text).font(.subheadline).foregroundStyle(n.error ? Look.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if menuBarNote {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("macOS always shows the menu bar in full screen, so the VM starts below it. Keep the Dock and hot corners away hides it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open Menu Bar Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .layoutProbe("menu-bar-settings")
                }
                .padding(.top, 8)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .onAppear { refresh() }
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotch = previewNotch ?? Mac.hasNotch
        }
    }

    static func kind(_ c: StartIn) -> StartInPicture.Kind {
        switch c {
        case .window: return .window
        case .fullScreen: return .fullScreen
        case .fullScreenNotch: return .fullScreenNotch
        }
    }

    /// Under the pictures: what keeps "including notch" from working, a
    /// failed save, or what it is.
    private var note: (text: String, error: Bool)? {
        if let error { return (error, true) }
        guard current == .fullScreenNotch else { return nil }
        if !ready { return (NotchArea.notReady, false) }
        return menuBarNote ? nil : (StartIn.notchNote, false)
    }

    /// Including notch, macOS set to keep the menu bar in full screen, and
    /// Keep the Dock away off: only then does the menu bar push the VM down
    /// (#356, tested on a MacBook Air's notch).
    private var menuBarNote: Bool {
        current == .fullScreenNotch && (previewMenuBar ?? NotchArea.menuBarAlwaysShown()) && !keepDockAway
    }

    private func refresh() {
        fullScreen = Settings.startFullScreen
        mode = NotchArea.read(folder: folder)
        hasNotch = previewNotch ?? Mac.hasNotch
        ready = NotchArea.guestReady(folder: folder, features: try? String(
            contentsOf: folder.appendingPathComponent("features"), encoding: .utf8))
    }

    private func set(_ c: StartIn) {
        guard c != current else { return }
        if let m = c.mode, m != mode {
            do {
                try NotchArea.write(m, folder: folder)
                mode = m
            } catch {
                self.error = "Could not save: \(error.localizedDescription)"
                return
            }
        }
        error = nil
        fullScreen = c.fullScreen
        Settings.startFullScreen = c.fullScreen
    }
}
