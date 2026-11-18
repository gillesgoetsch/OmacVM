import Foundation
import OmacVMFeatures
import SwiftUI

/// Battery saver (OmacVMFeatures/BatterySaver.swift has the rules): the seven
/// battery-saving switches as they stand for this VM on this Mac, and the top
/// switch's writes. It keeps nothing of its own: it reads each switch where
/// its own row reads it (the app's keys, the VM's record and pending file) and
/// writes through the same paths (Settings, FeatureSwitch), so a child row,
/// `omacvm`, the control centre and this switch never disagree.
@MainActor
enum BatterySaverModel {
    /// The switches now. `decodesAV1`/`hdrDisplay`: the window pictures' own Mac.
    static func items(folder f: URL, running: Bool, decodesAV1: Bool = Mac.decodesAV1,
                      hdrDisplay: Bool = Mac.hasHDRDisplay, groupBusy: Bool = false) -> [BatterySaver.Item] {
        let record = try? String(contentsOf: f.appendingPathComponent("features"), encoding: .utf8)
        let vp9Pending = try? String(contentsOf: f.appendingPathComponent(YouTubeVP9.switchState.pendingFile), encoding: .utf8)
        let animPending = try? String(contentsOf: f.appendingPathComponent(FewerAnimations.switchState.pendingFile), encoding: .utf8)
        let cli = TerminalCommand.available
        let anim = FewerAnimations.row(record: record, pending: animPending, running: running, busy: groupBusy, cli: cli)
        let vp9 = YouTubeVP9.row(record: record, pending: vp9Pending, running: running, busy: groupBusy, cli: cli)
        let safe = Settings.gpuSafeMode
        return [
            .init(.vcpuClockSaver, enabled: !safe, on: Settings.vcpuClockSaver),
            .init(.pauseWhileHidden, on: Settings.pauseWhileHidden),
            .init(.fewerAnimations, enabled: anim.enabled, on: anim.on),
            .init(.hdrFullScreenOnly, shown: hdrDisplay, enabled: Settings.hdr && !safe, on: Settings.hdrFullScreenOnly),
            .init(.youtubeVP9, shown: YouTubeVP9.shown(decodesAV1: decodesAV1, record: record, pending: vp9Pending),
                  enabled: vp9.enabled, on: vp9.on),
            .init(.pointerPlane, enabled: !Settings.macPointer, on: Settings.pointerPlane),
            .init(.presentTiles, enabled: !safe, on: Settings.presentTiles),
        ]
    }

    /// The app's keys of `changes`, at once (QEMU watches those that work at once).
    static func writeAppKeys(_ changes: [BatterySaver.Child], on: Bool) {
        for c in changes {
            switch c {
            case .vcpuClockSaver: Settings.vcpuClockSaver = on
            case .pauseWhileHidden: Settings.pauseWhileHidden = on
            case .hdrFullScreenOnly: Settings.hdrFullScreenOnly = on
            case .pointerPlane: Settings.pointerPlane = on
            case .presentTiles: Settings.presentTiles = on
            case .fewerAnimations, .youtubeVP9: break
            }
        }
    }

    /// The VM features of `changes`, as PendingSwitch values.
    nonisolated static func vmSwitches(_ changes: [BatterySaver.Child]) -> [PendingSwitch] {
        changes.compactMap { c in
            switch c {
            case .fewerAnimations: return FewerAnimations.switchState
            case .youtubeVP9: return YouTubeVP9.switchState
            default: return nil
            }
        }
    }

    /// The VM is stopped: each VM feature's record and pending file. nil, or what went wrong.
    static func writeStopped(_ switches: [PendingSwitch], folder: URL, on: Bool) -> String? {
        switches.lazy.compactMap { FeatureSwitch.writeStopped($0, folder: folder, on: on) }.first
    }
}

/// The Battery saver card (after Display): the top switch with its own (i)
/// and a disclosure chevron, and the seven rows under it when open, each the
/// same row as before (its title, line, (i) and switch), indented, without
/// its own "experimental" (the top row has it once; each (i) still says it).
/// The open/closed state is window chrome, kept app-wide in one key, not a
/// setting (no settings row, not in --settings-dump).
struct BatterySaverGroup: View {
    @ObservedObject var state: AppState
    var preview: RenderVMWindow.Preview?
    var running: Bool
    @AppStorage(BatterySaverGroup.expandedKey) private var expanded = false
    @State private var items: [BatterySaver.Item] = []
    @State private var busy = false
    @State private var note: String?

    nonisolated static let expandedKey = "batterySaverExpanded"
    /// The children's extra indent: their titles line up under the top row's.
    static let indent: CGFloat = 18

    private var open: Bool { preview?.batterySaverOpen ?? expanded }
    private var decodesAV1: Bool { preview?.decodesAV1 ?? Mac.decodesAV1 }
    private var hdrDisplay: Bool { preview?.hdr ?? Mac.hasHDRDisplay }

    var body: some View {
        let now = items.isEmpty ? read() : items
        let shown = Set(now.filter(\.shown).map(\.child))
        Card {
            BatterySaverTopRow(items: now, open: open, busy: busy, note: note,
                               toggleOpen: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } },
                               flip: flip)
            if open {
                Group {
                    VCPUClockSaverRow(tick: state.tick, badge: nil)
                    PauseWhileHiddenRow(tick: state.tick, badge: nil)
                    FewerAnimationsRow(state: state, badge: nil, groupBusy: busy)
                    if shown.contains(.hdrFullScreenOnly) { HDRFullScreenOnlyRow(tick: state.tick, badge: nil) }
                    if shown.contains(.youtubeVP9) { YouTubeVP9Row(state: state, badge: nil, groupBusy: busy) }
                    PointerPlaneRow(tick: state.tick, badge: nil)
                    PresentTilesRow(tick: state.tick, badge: nil)
                }
                .padding(.leading, Self.indent)
            }
        }
        .layoutProbe("battery-saver")
        .onAppear { items = read() }
        .onChange(of: state.tick) { _, _ in if !busy { items = read() } }
        .onChange(of: state.config) { _, _ in note = nil; items = read() }
        .onChange(of: running) { _, _ in items = read() }
        .onReceive(NotificationCenter.default.publisher(for: FeatureStart.done)) { _ in items = read() }
    }

    private func read() -> [BatterySaver.Item] {
        BatterySaverModel.items(folder: state.config.folder, running: running, decodesAV1: decodesAV1,
                                hdrDisplay: hdrDisplay, groupBusy: busy)
    }

    /// The top switch: each switch below through its own path; the app's
    /// keys at once, then the VM's features (one omacvm run while the VM runs).
    private func flip(_ on: Bool) {
        let changes = BatterySaver.changes(read(), to: on)
        note = nil
        BatterySaverModel.writeAppKeys(changes, on: on)
        let switches = BatterySaverModel.vmSwitches(changes)
        if switches.isEmpty || preview != nil { done(nil); return }
        if !running {
            done(BatterySaverModel.writeStopped(switches, folder: state.config.folder, on: on))
            return
        }
        let c = state.config
        busy = true
        Task.detached {
            let err = FeatureSwitch.runCLI(switches, on: on, config: c)
            await MainActor.run { busy = false; done(err) }
        }
    }

    private func done(_ err: String?) {
        if let err { note = "Could not switch: \(err)" }
        items = read()
        state.reloadSettings()   // every child row reads its switch again
    }
}

/// The top row: chevron, "Battery saver (experimental) (i)", the line under
/// it, and the switch. The chevron and the title open and close the group;
/// the switch only switches.
struct BatterySaverTopRow: View {
    let items: [BatterySaver.Item]
    let open: Bool
    let busy: Bool
    let note: String?
    let toggleOpen: () -> Void
    let flip: (Bool) -> Void

    var body: some View {
        let on = BatterySaver.isOn(items)
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: toggleOpen) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12, height: 17)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Hide the battery saver switches" : "Show the battery saver switches")
                .accessibilityRepresentation {
                    DisclosureGroup("Battery saver switches", isExpanded: Binding(get: { open }, set: { if $0 != open { toggleOpen() } })) {
                        EmptyView()
                    }
                }
                .layoutProbe("battery-saver-disclosure")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(BatterySaver.title).onTapGesture(perform: toggleOpen)
                        Text("(experimental)").font(.subheadline).foregroundStyle(.secondary).onTapGesture(perform: toggleOpen)
                        InfoButton(topic: BatterySaver.title, text: BatterySaver.info)
                    }
                    Text(note ?? BatterySaver.subtitle(items))
                        .font(.subheadline)
                        .foregroundStyle(note != nil ? Look.red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                RowSwitch(title: BatterySaver.title, isOn: Binding(get: { on }, set: { v in if v != on { flip(v) } }), enabled: !busy)
                    .accessibilityHint(BatterySaver.accessibilityHint(items))
            }
            .fixedSize()
            .layoutProbe("trailing-battery-saver")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// `OmacVM --battery-saver on|off|status --vm NAME`: the top switch of the
/// Battery saver group without a window, for the e2e rows: the same reads and
/// writes as the switch (BatterySaverModel), then the group's state as JSON.
/// The VM runs (its QEMU or an omacvm job uses its folder): its features
/// through one `omacvm enable|disable`; stopped: its record and pending files.
@MainActor
enum BatterySaverCLI {
    nonisolated static let flag = "--battery-saver"

    static func main(_ args: [String]) -> Never {
        let usage = "usage: OmacVM --battery-saver on|off|status --vm NAME"
        guard let action = args.first, ["on", "off", "status"].contains(action),
              let i = args.firstIndex(of: "--vm"), i + 1 < args.count else {
            FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(2)
        }
        let name = args[i + 1]
        guard let c = VMConfig.all().first(where: { $0.name == name }) else {
            FileHandle.standardError.write(Data("OmacVM --battery-saver: no VM named \(name)\n".utf8)); exit(2)
        }
        let running = !Storage.busyFolders([c.folder]).isEmpty
        var err: String?
        if action != "status" {
            let on = action == "on"
            let changes = BatterySaver.changes(BatterySaverModel.items(folder: c.folder, running: running), to: on)
            BatterySaverModel.writeAppKeys(changes, on: on)
            let switches = BatterySaverModel.vmSwitches(changes)
            err = running ? FeatureSwitch.runCLI(switches, on: on, config: c)
                          : BatterySaverModel.writeStopped(switches, folder: c.folder, on: on)
            print("battery saver \(action): \(changes.map(\.rawValue).joined(separator: " ")) (\(running ? "running" : "stopped"))")
        }
        let items = BatterySaverModel.items(folder: c.folder, running: running)
        let out: [String: Any] = [
            "on": BatterySaver.isOn(items),
            "subtitle": BatterySaver.subtitle(items),
            "accessibilityHint": BatterySaver.accessibilityHint(items),
            "running": running,
            "items": items.map { ["name": $0.child.rawValue, "shown": $0.shown, "enabled": $0.enabled, "on": $0.on] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        if let err {
            FileHandle.standardError.write(Data("OmacVM --battery-saver: could not switch: \(err)\n".utf8)); exit(1)
        }
        exit(0)
    }
}
