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

/// "Magic Mouse swipe: [4 fingers]" (MouseSwipeSetting), a row in the setup's
/// and the VM window's forms; they show it only while MagicMouseWatch sees a
/// Magic Mouse.
struct MagicMouseRow: View {
    @State private var fingers = MouseSwipeSetting.current()

    var body: some View {
        LabeledContent("Magic Mouse swipe") {
            HStack(spacing: 8) {
                Picker("Magic Mouse swipe", selection: $fingers) {
                    ForEach(MouseSwipeSetting.choices, id: \.self) { Text("\($0) fingers").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: fingers) { _, v in MouseSwipeSetting.set(v) }
                InfoButton(topic: "the Magic Mouse swipe", text: MouseSwipeSetting.hint)
            }
        }
    }
}
