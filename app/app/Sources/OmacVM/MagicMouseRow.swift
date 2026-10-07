import SwiftUI

/// Whether a Magic Mouse is connected, looked for every few seconds while a
/// window shows it, so one connected or switched off later shows or hides
/// the row.
@MainActor
final class MagicMouseWatch: ObservableObject {
    @Published private(set) var connected = MagicMouse.connected()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let c = MagicMouse.connected()
        if c != connected { connected = c }
    }
}

/// "Magic Mouse swipe: [4 fingers]" (MouseSwipeSetting), in the setup and the
/// VM window; they show it only while MagicMouseWatch sees a Magic Mouse.
struct MagicMouseRow: View {
    /// In the setup's form: label and control as one row, so the form keeps
    /// its label column. The VM window: the picker with the hint below, as
    /// its other rows.
    var inForm = true
    @State private var fingers = MouseSwipeSetting.current()

    private var picker: some View {
        Picker("Magic Mouse swipe", selection: $fingers) {
            ForEach(MouseSwipeSetting.choices, id: \.self) { Text("\($0) fingers").tag($0) }
        }
        .onChange(of: fingers) { _, v in MouseSwipeSetting.set(v) }
    }

    private var hint: some View {
        Text(MouseSwipeSetting.hint)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        if inForm {
            LabeledContent("Magic Mouse swipe") {
                VStack(alignment: .leading, spacing: 4) { picker.labelsHidden(); hint }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) { picker; hint }
        }
    }
}
