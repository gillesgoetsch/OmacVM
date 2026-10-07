import OmacVMUSB
import SwiftUI

/// The VM's USB devices (docs/usb.md) in the VM window's form: a switch, off
/// by default, and one line with what is on. Devices… opens the list.
/// The USB lane builds the rest here: ask on plug-in, the remembered list.
struct USBRow: View {
    let folder: URL
    @State private var on = false
    @State private var chosen: [USBChoice.Entry] = []
    @State private var note: String?
    @State private var showDevices = false

    var body: some View {
        SwitchRow("USB devices (experimental)", isOn: Binding(get: { on }, set: { setOn($0) })) {
            if on { Button("Devices…") { showDevices = true } }
            InfoButton(topic: "USB devices", text: USBDevicesSheet.explanation)
        }
        .sheet(isPresented: $showDevices, onDismiss: refresh) {
            USBDevicesSheet(folder: folder) { showDevices = false }
        }
        .onAppear(perform: refresh)
        .onChange(of: folder) { _, _ in note = nil; refresh() }
        if on { RowNote(summary) }
        if let n = note { RowNote(n, error: n.hasPrefix("Could not")) }
    }

    /// "ST-Link V2, HackRF One go to the VM" / "No device yet: Devices…"
    private var summary: String {
        guard !chosen.isEmpty else { return "No device chosen yet: Devices… lists them." }
        return chosen.map { $0.name.isEmpty ? "\($0.id)" : $0.name }.joined(separator: ", ")
            + (chosen.count == 1 ? " goes to the VM." : " go to the VM.")
    }

    private func setOn(_ value: Bool) {
        do {
            try USBSwitch.set(value, folder: folder)
            note = "Applies on the next start."
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        on = USBSwitch.isOn(folder: folder)
        chosen = USBChoice.load(folder: folder)
    }
}

/// The Mac's devices with a switch each (read from the IORegistry, nothing
/// opened); only a device nothing on the Mac uses can be switched on, the
/// others say why they stay with the Mac. A device that is on goes to the VM
/// whenever it is plugged in while the VM runs, and back to the Mac when the
/// VM stops.
struct USBDevicesSheet: View {
    let folder: URL
    var done: () -> Void
    @State private var devices: [USBDevice] = []
    @State private var chosen: [USBChoice.Entry] = []
    @State private var note: String?

    static let explanation = "A device that is on goes to the VM while it runs. macOS lets a VM have only devices it does not use itself: debug probes, SDR sticks, logic analysers, phones in fastboot. Keyboards, security keys, USB disks, serial adapters, audio and cameras stay with the Mac. If a Mac app has a device open when the VM looks for it, plug it in again once the app is done."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("USB Devices").font(.title3.bold())
            Text(Self.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows, id: \.id) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Toggle("\(row.name) (\(row.id.description))", isOn: binding(row))
                        .disabled(!row.canChoose && !row.on)
                    if let why = row.why {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if rows.isEmpty {
                Text("No device a VM can have is plugged in.").font(.caption).foregroundStyle(.secondary)
            }
            if !kept.isEmpty {
                Text("Kept by macOS: " + kept.map { $0.0 }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(kept.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
            }
            HStack {
                Button("Refresh") { refresh() }
                if let n = note {
                    Text(n).font(.caption).foregroundStyle(n.hasPrefix("Could not") ? .red : .secondary)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { refresh() }
    }

    private struct Row {
        var id: USBDeviceID
        var name: String
        var on: Bool
        var canChoose: Bool
        var why: String?
    }

    /// The devices a VM can have and the chosen ones (hubs and USB-C info
    /// devices left out), then the chosen ones that are not plugged in now.
    private var rows: [Row] {
        var out: [Row] = []
        var seen = Set<USBDeviceID>()
        for d in devices where !seen.contains(d.id) {
            let on = chosen.contains { $0.id == d.id }
            switch d.availability {
            case .notOffered(let why):
                // Plugged in, but never for a VM: shown only when the file
                // names it (switch it off), never as "not plugged in".
                seen.insert(d.id)
                guard on else { continue }
                out.append(Row(id: d.id, name: d.name, on: on, canChoose: false,
                               why: "Not for a VM (\(why)): switch it off."))
                continue
            case .free:
                out.append(Row(id: d.id, name: d.name, on: on, canChoose: true, why: nil))
            case .usedByMac(let why):
                guard on else { continue }
                out.append(Row(id: d.id, name: d.name, on: on, canChoose: false,
                               why: "\(why): the VM gets it when macOS no longer does and it is plugged in again."))
            }
            seen.insert(d.id)
        }
        for e in chosen where !seen.contains(e.id) {
            out.append(Row(id: e.id, name: e.name.isEmpty ? "USB device" : e.name, on: true, canChoose: true,
                           why: "Not plugged in: the VM gets it when it is."))
        }
        return out
    }

    /// Devices macOS uses (not chosen): their names on one line, why on hover.
    private var kept: [(String, String)] {
        devices.compactMap { d in
            guard case .usedByMac(let why) = d.availability, !chosen.contains(where: { $0.id == d.id }) else { return nil }
            return (d.name, why)
        }
    }

    private func binding(_ row: Row) -> Binding<Bool> {
        Binding(get: { chosen.contains { $0.id == row.id } }, set: { on in choose(row, on: on) })
    }

    private func choose(_ row: Row, on: Bool) {
        var c = chosen.filter { $0.id != row.id }
        if on {
            guard c.count < USBChoice.maxDevices else {
                note = "At most \(USBChoice.maxDevices) devices."
                return
            }
            c.append(USBChoice.Entry(id: row.id, name: row.name))
        }
        do {
            try USBChoice.save(c, folder: folder)
            chosen = c
            note = "Applies on the next start."
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }

    private func refresh() {
        chosen = USBChoice.load(folder: folder)
        devices = USBScan.devices()
    }
}
