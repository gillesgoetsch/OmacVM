import AppKit
import OmacVMWindow
import SwiftUI

/// The (i) after a row: the row's full explanation in a popover. A button,
/// so it takes keyboard focus and VoiceOver reads it as "About <topic>".
struct InfoButton: View {
    let topic: String
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(topic)")
        .help(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(14)
        }
    }
}

/// An on/off setting in the window's form: the label in the left column,
/// the switch and anything that goes with it (a spinner, a button, the (i))
/// in the right one.
struct SwitchRow<Accessory: View>: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true
    var accessory: Accessory

    init(_ title: String, isOn: Binding<Bool>, enabled: Bool = true, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        _isOn = isOn
        self.enabled = enabled
        self.accessory = accessory()
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!enabled)
                accessory
            }
        }
    }
}

extension SwitchRow where Accessory == EmptyView {
    init(_ title: String, isOn: Binding<Bool>, enabled: Bool = true) {
        self.init(title, isOn: isOn, enabled: enabled) { EmptyView() }
    }
}

/// A short grey line under a row (in the form's right column). The form
/// gives its right column no width of its own, so a long line would widen
/// the window: it wraps at the column's width instead.
struct RowNote: View {
    /// The right column of the VM window's form (520 pt less the longest label).
    static let width: CGFloat = 280

    let text: String
    var error = false

    init(_ text: String, error: Bool = false) {
        self.text = text
        self.error = error
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(error ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.width, alignment: .leading)
    }
}

/// The window's content, scrolling when the screen is too short for it: the
/// window takes the content's height, up to what the screen shows
/// (WindowFit).
struct FitScroll<Content: View>: View {
    /// A fixed limit (the window pictures); nil: the screen's.
    var limit: CGFloat?
    var content: Content
    @State private var height: CGFloat = 0
    @State private var screenLimit = FitScrollScreen.limit()

    init(limit: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.limit = limit
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: height > 0 ? min(height, limit ?? screenLimit) : nil)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screenLimit = FitScrollScreen.limit()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            screenLimit = FitScrollScreen.limit()
        }
    }
}

@MainActor
enum FitScrollScreen {
    /// The title bar of the app's window.
    static var titleBar: CGFloat {
        NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                           styleMask: [.titled, .closable, .miniaturizable]).height - 100
    }

    /// The content's height limit on the screen the window is on (else the
    /// one it opens on: the built-in display, else the main one).
    static func limit() -> CGFloat {
        let window = NSApp.windows.first { $0.contentViewController is NSHostingController<RootView> }
        let builtIn = NSScreen.screens.first { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
        let screen: NSScreen? = window?.screen ?? builtIn ?? NSScreen.main
        guard let visible = screen?.visibleFrame.height else { return .infinity }
        return CGFloat(WindowFit.contentHeight(content: .infinity, visible: visible, titleBar: titleBar))
    }
}
