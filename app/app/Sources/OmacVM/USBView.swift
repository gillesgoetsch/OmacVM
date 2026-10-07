import Combine
import OmacVMUSB
import SwiftUI

/// The VM's USB devices (docs/usb.md) in the VM window's form: a switch, off
/// by default. On: the VM gets a USB controller at its start, and while it
/// runs the app asks for each device plugged in (USBSession). Devices… opens
/// the list of remembered devices.
struct USBRow: View {
    let folder: URL
    @State private var on = false
    @State private var memory = USBMemory()
    @State private var note: String?
    @State private var showDevices = false

    static let explanation = "When it’s on and you plug in a device while the VM runs, OmacVM asks whether to connect it to the VM or keep it on the Mac. Your answer counts for that plug-in only, unless you check “Always do this for this device”. Devices… lists the remembered ones, to change or forget. macOS lets a VM have only devices it doesn’t use itself: debug probes, SDR sticks, logic analysers, phones in fastboot. Keyboards, security keys, USB disks, serial adapters, audio and cameras stay with the Mac and are never asked about."

    var body: some View {
        SwitchRow("USB devices (experimental)", isOn: Binding(get: { on }, set: { setOn($0) })) {
            if on {
                Button("Devices…") { showDevices = true }
                    .accessibilityLabel("USB devices list")
            }
            InfoButton(topic: "USB devices", text: Self.explanation)
        }
        .sheet(isPresented: $showDevices, onDismiss: refresh) {
            USBDeviceList(source: .before(folder), vmName: VMConfig.load(from: folder)?.name ?? "the VM") { showDevices = false }
        }
        .onAppear(perform: refresh)
        .onChange(of: folder) { _, _ in note = nil; refresh() }
        if on { RowNote(USBListRows.summary(memory: memory)) }
        if let n = note { RowNote(n, error: true) }
    }

    private func setOn(_ value: Bool) {
        do {
            try USBSwitch.set(value, folder: folder)
            note = nil
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        // Moves a 3.0.1-3.0.3 `usb` file in first (it decides the switch).
        memory = USBMemory.load(folder: folder)
        on = USBSwitch.isOn(folder: folder)
    }
}

/// The remembered devices before the VM starts: usb.json, and the devices
/// plugged in now (USBWatch, live). Changes are saved at once.
@MainActor
final class USBListBefore: ObservableObject {
    let folder: URL
    let vmName: String
    @Published private(set) var rows = USBListRows()
    private var memory = USBMemory()
    private var devices: [UInt32: USBDevice] = [:]
    private let watch = USBWatch()
    private let preview: [USBDevice]?
    @Published var error: String?

    /// preview: these devices instead of the Mac's (the window pictures).
    init(folder: URL, vmName: String, preview: [USBDevice]? = nil) {
        self.folder = folder
        self.vmName = vmName
        self.preview = preview
    }

    func start() {
        memory = USBMemory.load(folder: folder)
        if let preview {
            for d in preview { devices[d.location] = d }
        } else {
            watch.onPlug = { [weak self] d in self?.devices[d.location] = d; self?.refresh() }
            watch.onUnplug = { [weak self] loc in self?.devices[loc] = nil; self?.refresh() }
            watch.start()
        }
        refresh()
    }

    func stop() { watch.stop() }

    func setPlan(_ plan: USBPlan, row: USBListRows.Row) {
        if let key = row.key { memory.set(key: key, plan) } else if let d = row.device { memory.remember(d, plan) }
        save()
    }

    func forget(_ row: USBListRows.Row) {
        guard let key = row.key else { return }
        memory.forget(key: key)
        save()
    }

    private func save() {
        do {
            try memory.save(folder: folder)
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        rows = USBListRows.make(memory: memory, devices: devices.values.sorted { $0.location < $1.location },
                                states: nil, vmName: vmName)
    }
}

/// "USB Devices": the remembered devices (what happens when each is plugged
/// in: Ask Each Time, Connect to Omarchy, Keep on Mac; Forget), the devices
/// plugged in now that a VM can have, and the ones macOS keeps (why). While
/// the VM runs, also Connect and Disconnect, now. A choice here changes only
/// later plug-ins.
struct USBDeviceList: View {
    enum Source {
        case before(URL)
        case running(USBRun)
        /// Fixed rows (the window pictures of the list while a VM runs).
        case picture(USBListRows, running: Bool)
    }

    let vmName: String
    var done: () -> Void
    @StateObject private var before: USBListBefore
    @ObservedObject private var running: USBRunHolder

    init(source: Source, vmName: String, preview: [USBDevice]? = nil, done: @escaping () -> Void) {
        self.vmName = vmName
        self.done = done
        switch source {
        case .before(let folder):
            _before = StateObject(wrappedValue: USBListBefore(folder: folder, vmName: vmName, preview: preview))
            _running = ObservedObject(wrappedValue: USBRunHolder(nil))
        case .running(let run):
            _before = StateObject(wrappedValue: USBListBefore(folder: run.config.folder, vmName: vmName, preview: []))
            _running = ObservedObject(wrappedValue: USBRunHolder(run))
        case .picture(let rows, let isRunning):
            _before = StateObject(wrappedValue: USBListBefore(folder: URL(fileURLWithPath: "/nonexistent"), vmName: vmName, preview: []))
            _running = ObservedObject(wrappedValue: USBRunHolder(nil))
            fixed = rows
            pictureRunning = isRunning
        }
    }

    private var fixed: USBListRows?
    private var pictureRunning = false
    private var rows: USBListRows {
        if let fixed { return fixed }
        if let r = running.run { return r.rows }
        let b: USBListBefore = before
        return b.rows
    }
    private var isRunning: Bool { running.run != nil || pictureRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if rows.isEmpty {
                    Section {
                        Text("No devices yet. When \(vmName) runs and you plug in a device it can use, \(Product.name) asks what to do.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !rows.remembered.isEmpty {
                    Section("Remembered") {
                        ForEach(rows.remembered) { row in deviceRow(row) }
                    }
                }
                if !rows.plugged.isEmpty {
                    Section("Plugged in now") {
                        ForEach(rows.plugged) { row in deviceRow(row) }
                    }
                }
                if !rows.kept.isEmpty {
                    Section {
                        DisclosureGroup("Kept by macOS (\(rows.kept.count))") {
                            ForEach(rows.kept) { k in
                                LabeledContent(k.name) {
                                    Text(k.why).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack(alignment: .firstTextBaseline) {
                if let e = before.error {
                    Text(e).font(.caption).foregroundStyle(.red)
                } else {
                    Text("A choice here applies the next time the device is plugged in.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 520)
        .frame(minHeight: 240, idealHeight: 470, maxHeight: 640)
        .onAppear { if running.run == nil && fixed == nil { before.start() } }
        .onDisappear { before.stop() }
    }

    private func planBinding(_ row: USBListRows.Row) -> Binding<USBPlan> {
        Binding(get: { row.plan }, set: { p in
            if fixed != nil { return }
            if let r = running.run { r.setPlan(p, row: row) } else { before.setPlan(p, row: row) }
        })
    }

    private func forget(_ row: USBListRows.Row) {
        if let r = running.run { r.forget(row) } else { before.forget(row) }
    }

    @ViewBuilder
    private func deviceRow(_ row: USBListRows.Row) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Picker("When “\(row.name)” is plugged in", selection: planBinding(row)) {
                    Text("Ask Each Time").tag(USBPlan.ask)
                    Text("Connect to \(vmName)").tag(USBPlan.omarchy)
                    Text("Keep on Mac").tag(USBPlan.mac)
                }
                .labelsHidden()
                .fixedSize()
                if row.canConnect && isRunning {
                    Button("Connect") { running.run?.connect(row) }
                        .accessibilityLabel("Connect \(row.name) to \(vmName)")
                }
                if row.canDisconnect && isRunning {
                    Button("Disconnect") { running.run?.disconnect(row) }
                        .accessibilityLabel("Disconnect \(row.name)")
                }
                if row.key != nil {
                    Button { forget(row) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Forget this device: asked about again next time")
                        .accessibilityLabel("Forget \(row.name)")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                Text(row.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), \(row.detail), \(row.status)")
        .contextMenu {
            if row.key != nil { Button("Forget Device") { forget(row) } }
        }
    }
}

/// The running VM's USB state for the list (nil before a start).
@MainActor
final class USBRunHolder: ObservableObject {
    let run: USBRun?
    private var sub: Any?
    init(_ run: USBRun?) {
        self.run = run
        sub = run?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
