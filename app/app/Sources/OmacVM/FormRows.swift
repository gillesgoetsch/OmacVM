import AppKit
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
        .popover(isPresented: $shown, arrowEdge: .bottom) { InfoText(text: text) }
    }
}

/// What an (i)'s popover shows. The window pictures draw the same view
/// (RenderVMWindow: popover-2-resources).
struct InfoText: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 320, alignment: .leading)
            .padding(14)
    }
}
