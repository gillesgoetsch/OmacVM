import AppKit
import SwiftUI

struct BridgedNetworkRow: View {
    @ObservedObject var state: AppState
    @State private var selected = ""
    @State private var interfaces: [String] = []
    @State private var busy = false
    @State private var error: String?
    @State private var configurationError: String?

    var body: some View {
        SettingRow(title: "Network", badge: "experimental",
                   subtitle: configurationError ?? error ?? (selected.isEmpty
                       ? "Shared networking. Bridged gives the VM its own LAN address."
                       : "Bridged on \(selected). Changes apply at the next VM start."),
                   subtitleIsError: configurationError != nil || error != nil,
                   info: "Bridged exposes the VM directly to the selected LAN. The VM keeps its firewall and a separate private link to the Mac. Initial setup needs the VM running; macOS asks for permission to install the network service. Shared keeps the existing Fast network choice.",
                   probe: "bridged-network") {
            if busy { ProgressView().controlSize(.small) }
            if !selected.isEmpty { Button("Repair…") { configure(selected, force: true) }.disabled(busy) }
            Picker("Network", selection: Binding(
                get: { configurationError == nil ? selected : "invalid" },
                set: { configure($0) })) {
                if configurationError != nil { Text("Invalid configuration").tag("invalid") }
                Text("Shared").tag("")
                ForEach(interfaces, id: \.self) { name in Text("Bridged: \(name)").tag(name) }
                if !selected.isEmpty && !interfaces.contains(selected) {
                    Text("\(selected) (unavailable)").tag(selected)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(busy)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in
            guard !busy else { return }
            loadSelection(state.config)
        }
    }

    private func loadSelection(_ c: VMConfig) {
        do {
            selected = try BridgedNetwork.load(c)?.interface ?? ""
            configurationError = nil
        } catch {
            selected = ""
            configurationError = error.localizedDescription
        }
    }

    private func refresh() {
        let c = state.config
        loadSelection(c)
        Task.detached {
            let result = BridgedNetwork.interfaces()
            await MainActor.run {
                guard state.config.folder == c.folder else { return }
                interfaces = result.names
                error = result.error
            }
        }
    }

    private func configure(_ interface: String, force: Bool = false) {
        guard interface != "invalid",
              interface != selected || force || configurationError != nil else { return }
        if !interface.isEmpty && !force {
            let alert = NSAlert()
            alert.messageText = "Connect this VM directly to the LAN?"
            alert.informativeText = "The VM will get its own address on \(interface) and be reachable from that network, subject to its firewall. A private management link to the Mac stays separate. The change applies at the next start."
            alert.addButton(withTitle: "Use Bridged Network")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let c = state.config
        busy = true
        error = nil
        Task.detached {
            let failure = BridgedNetwork.set(c, interface: interface.isEmpty ? nil : interface)
            await MainActor.run {
                busy = false
                guard state.config.folder == c.folder else { return }
                error = failure
                loadSelection(c)
            }
        }
    }
}
