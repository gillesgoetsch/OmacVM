import AppKit
import OmacVMDesktop
import OmacVMFeatures
import OmacVMUpdate
import OmacVMWindow
import SwiftUI

// The rows of the VM window's sections (SettingsView.swift). Each reads and
// writes the setting it had before 3.1; state.tick (the window back in
// front, every few seconds) has them read it again.

// MARK: General

/// Resources: the create screen's tiers as one segmented row, the VM's CPUs
/// and memory as bars against the Mac's; Custom opens − / + for each, within
/// `omacvm resources`' limits (ResourceLimits). Written to vm.env at once,
/// as `omacvm resources` writes it.
struct ResourcesRow: View {
    @ObservedObject var state: AppState
    @State private var customOpen = false
    @State private var error: String?
    private let limits = ResourceLimits.mac
    private static let custom = 4

    private var tier: Int? { Mac.tierIndex(cpus: state.config.cpus, memoryMB: state.config.memoryMB) }
    private var memoryGB: Int { state.config.memoryMB / 1024 }

    private var selection: Binding<Int> {
        Binding(get: { customOpen ? Self.custom : tier ?? Self.custom },
                set: { t in
                    if t == Self.custom {
                        customOpen = true
                    } else {
                        customOpen = false
                        let v = Mac.tier(t)
                        set(cpus: v.cpus, memoryGB: v.memoryGB)
                    }
                })
    }

    var body: some View {
        // The last run's graphics: the (i) and the warning say them.
        let graphics = GPUMemory.read(for: state.config)
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                // One (i) for CPUs and memory, where SettingRow puts it.
                HStack(spacing: 6) {
                    Text("Resources")
                    InfoButton(topic: "Resources", text: GPUMemory.resourcesInfo(graphics)).layoutProbe("info-resources")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Resources", selection: selection) {
                    ForEach(0..<4) { Text(Mac.tierNames[$0]).tag($0) }
                    Text("Custom").tag(Self.custom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help((0..<4).map { "\(Mac.tierNames[$0]): \(Mac.tier($0).cpus) CPUs, \(Mac.tier($0).memoryGB) GB" }.joined(separator: "\n"))
                .layoutProbe("trailing-resources")
            }
            HStack(spacing: 12) {
                Text("CPUs").font(.subheadline).frame(width: 56, alignment: .leading)
                CPUBar(total: Mac.cores, on: state.config.cpus)
                Text("\(state.config.cpus) of \(Mac.cores)").font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CPUs: \(state.config.cpus) of \(Mac.cores)")
            HStack(spacing: 12) {
                Text("Memory").font(.subheadline).frame(width: 56, alignment: .leading)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Look.track)
                        Capsule().fill(Color.accentColor)
                            .frame(width: g.size.width * min(1, Double(memoryGB) / Double(max(1, Mac.memoryGB))))
                    }
                }
                .frame(height: 8)
                Text("\(memoryGB) of \(Mac.memoryGB) GB").font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit().frame(width: 92, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory: \(memoryGB) of \(Mac.memoryGB) GB")
            if customOpen || tier == nil {
                HStack(spacing: 24) {
                    ValueStepper(label: "CPUs", value: Binding(get: { state.config.cpus }, set: { set(cpus: $0, memoryGB: memoryGB) }),
                                 range: limits.cpus)
                    ValueStepper(label: "Memory", value: Binding(get: { memoryGB }, set: { set(cpus: state.config.cpus, memoryGB: $0) }),
                                 range: limits.memoryGB, unit: "GB", minWidth: 56)
                }
                .padding(.top, 1)
            }
            if let w = limits.warning(memoryGB: memoryGB, graphicsPeakMB: graphics?.peakMB) {
                Text(w).font(.subheadline).foregroundStyle(Look.orange).fixedSize(horizontal: false, vertical: true)
            }
            // A VM from a bigger Mac: what it starts with here (main.swift startVM).
            if let n = state.config.startSizeNote {
                Text(n).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = error { Text(e).font(.subheadline).foregroundStyle(Look.red) }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .onChange(of: state.config.folder) { _, _ in customOpen = false; error = nil }
    }

    private func set(cpus: Int, memoryGB: Int) {
        var c = state.config
        c.cpus = min(max(cpus, limits.cpus.lowerBound), limits.cpus.upperBound)
        c.memoryMB = min(max(memoryGB, limits.memoryGB.lowerBound), limits.memoryGB.upperBound) * 1024
        guard c != state.config else { return }
        do {
            try c.writeResources()
            state.config = c
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// One small block per CPU of the Mac; the VM's are in the accent colour.
struct CPUBar: View {
    let total: Int
    let on: Int

    var body: some View {
        HStack(spacing: total > 16 ? 2 : 3) {
            ForEach(0..<max(1, total), id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(i < on ? Color.accentColor : Look.track)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// Graphics (Graphics.swift): the VM folder's `graphics` file, as `omacvm
/// graphics` and the control centre set it.
struct GraphicsRow: View {
    @ObservedObject var state: AppState
    @State private var choice = GraphicsChoice.auto
    @State private var note: String?
    @State private var error: String?

    var body: some View {
        let plan = Runner.graphicsPlan(state.config)
        SettingRow(title: "Graphics", subtitle: error ?? note ?? "Next start: \(plan.summary).", subtitleIsError: error != nil,
                   info: GraphicsPicker.help, probe: "graphics") {
            // Vulkan fell back and stays off: choosing it again needs a button.
            if Graphics.fallback(folder: state.config.folder) != nil {
                Button("Try Vulkan Again") {
                    do {
                        try Graphics.write(choice, folder: state.config.folder)
                        state.tick += 1
                    } catch {
                        self.error = "Could not save: \(error.localizedDescription)"
                    }
                }
            }
            GraphicsPicker.picker($choice).labelsHidden().fixedSize()
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in note = nil; error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
        .onChange(of: choice) { _, v in write(v) }
    }

    private func refresh() {
        let g = Graphics.read(folder: state.config.folder)
        if g != choice { choice = g }
    }

    private func write(_ g: GraphicsChoice) {
        let folder = state.config.folder
        guard g != Graphics.read(folder: folder) else { return }
        do {
            try Graphics.write(g, folder: folder)
            error = nil
            let plan = Runner.graphicsPlan(state.config)
            note = g == .vulkan && !plan.venus
                ? "The VM has no Vulkan driver yet: it runs on OpenGL until `omacvm apply` (or `omacvm graphics` while the VM runs) builds it, a few minutes."
                : nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Closing the window (org.omacvm.app closeAction): what closing a running
/// VM's window does. QEMU gets it as OMACVM_CLOSE_ACTION.
struct CloseActionRow: View {
    var tick = 0
    @State private var action = Settings.closeAction

    var body: some View {
        SettingRow(title: "Closing the window", probe: "close") {
            Picker("Closing the window", selection: $action) {
                ForEach(CloseAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: action) { _, v in if v != Settings.closeAction { Settings.closeAction = v } }
        .onChange(of: tick) { _, _ in action = Settings.closeAction }
    }
}

// MARK: Display

/// Keep the Dock and hot corners away (org.omacvm.app keepDockAway, every VM).
struct KeepDockAwayRow: View {
    var tick = 0
    @State private var on = Settings.keepDockAway

    var body: some View {
        SettingRow(title: "Keep the Dock and hot corners away",
                   subtitle: "In full screen, the Dock and hot corners don’t pop up.", probe: "dock") {
            RowSwitch(title: "Keep the Dock and hot corners away", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != Settings.keepDockAway { Settings.keepDockAway = v } }
        .onChange(of: tick) { _, _ in on = Settings.keepDockAway }
    }
}

/// HDR and 10-bit colour (Settings.hdr, experimental, off by default): read
/// by each start of the VM (Settings.hdrStart). Shown only with a display
/// that can show HDR. While the VM runs with the other setting, the row says
/// so (HDRNote, from that start's line in qemu.log): a restart inside the VM
/// keeps it, which was easy to miss.
struct HDRRow: View {
    var tick = 0
    /// The VM this window shows, and whether it runs now.
    var folder: URL?
    var running = false
    @State private var on = Settings.hdr
    @State private var line = (text: HDRNote.usual, isNote: false)

    static let info = "The VM's main window shows 10-bit colour, for smoother gradients, and HDR highlights on this Mac's HDR display. White stays the Mac's white; brighter parts go as far as the display can show right now. Windows on other displays stay as before. Counts when the VM starts: shut it down and start it again; a restart inside the VM keeps the setting it started with. The VM gets its 10-bit graphics driver with Update VM (needs internet once). Few Linux apps send HDR yet: Chrome, Chromium and GStreamer do; mpv shows HDR video as SDR for now. Uses a little more memory and battery. Experimental. GPU safe mode turns it off."

    var body: some View {
        SettingRow(title: "HDR and 10-bit colour", badge: "experimental", subtitle: line.text, subtitleIsNote: line.isNote,
                   info: Self.info, probe: "hdr") {
            RowSwitch(title: "HDR and 10-bit colour", isOn: $on, enabled: !Settings.gpuSafeMode)
        }
        .onAppear(perform: refresh)
        .onChange(of: on) { _, v in
            if v != Settings.hdr { Settings.hdr = v }
            refresh()
        }
        .onChange(of: tick) { _, _ in on = Settings.hdr; refresh() }
        .onChange(of: running) { _, _ in refresh() }
        .onChange(of: folder) { _, _ in refresh() }
    }

    /// The subtitle, with the note from the running VM's qemu.log (its head:
    /// a few KB at a start, read only while it runs).
    private func refresh() {
        let log = running ? folder.flatMap { KeyAccess.lastLog(folder: $0) } : nil
        let l = HDRNote.subtitle(switchOn: Settings.hdr, safeMode: Settings.gpuSafeMode, running: running, log: log)
        if l != line { line = l }
    }
}

/// Extra brightness (Settings.extraBrightness, experimental, ADR 0050): only
/// with a display that has the headroom (Mac.hasExtraBrightnessDisplay).
/// QEMU reads the key itself, so a running VM follows the switch at once.
struct ExtraBrightnessRow: View {
    var tick = 0
    @State private var on = Settings.extraBrightness

    static let info = "Makes the VM's main window up to about twice as bright as the Mac's normal white, with the extra brightness of this Mac's XDR display. For when you need it, for example in bright light. Use with care: it uses much more battery and a little more memory, and makes the Mac warmer; macOS turns it down when the Mac gets hot. It ends by itself when the VM stops, its window is hidden or you turn this off, and works at once in a running VM. The switch keeps your setting for the next start. Only the VM's main window: the rest of the screen stays as it is, and screenshots show it at normal brightness. With HDR and 10-bit colour on, this wins while it is on: the picture gets brighter, HDR highlights do not. Off, HDR is back at once. Experimental. GPU safe mode turns it off."

    var body: some View {
        SettingRow(title: "Extra brightness", badge: "experimental",
                   subtitle: Settings.gpuSafeMode ? "Off while GPU safe mode is on." : "Up to twice as bright as normal white. Uses much more battery.",
                   info: Self.info, probe: "extra-brightness") {
            RowSwitch(title: "Extra brightness", isOn: $on, enabled: !Settings.gpuSafeMode)
        }
        .onChange(of: on) { _, v in if v != Settings.extraBrightness { Settings.extraBrightness = v } }
        .onChange(of: tick) { _, _ in on = Settings.extraBrightness }
    }
}

/// Pause drawing while hidden (Settings.pauseWhileHidden, experimental, off
/// by default): QEMU reads the key itself, so a running VM follows the
/// switch at once.
struct PauseWhileHiddenRow: View {
    var tick = 0
    @State private var on = Settings.pauseWhileHidden

    static let info = "Saves battery while you work in macOS with the VM in the background. When none of the VM's window can be seen for 2 seconds (minimised, covered by other windows, on another Space, the screen locked or asleep), the VM turns its display off and stops drawing, as macOS apps do for a window nobody sees: Linux apps get no new frames and stop drawing too. Sound, videos' sound, downloads, timers and everything else in the VM keep running. As soon as any part of the window shows again, the VM draws again; the first new picture comes a few frames later, until then you see the last one. A visible window is never touched: every frame, at the display's full rate. Only the VM's main window: in full screen on several displays, the other displays' windows keep drawing. Screen sharing or recording of the VM's screen from inside the VM keeps it drawing. Works at once in a running VM. Experimental: it switches the VM's display off and on (DPMS), as Omarchy's own screen blanking does."

    var body: some View {
        SettingRow(title: "Pause drawing while hidden", badge: "experimental",
                   subtitle: "Less battery while the VM's window cannot be seen. Sound and downloads keep running.",
                   info: Self.info, probe: "pause-while-hidden") {
            RowSwitch(title: "Pause drawing while hidden", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != Settings.pauseWhileHidden { Settings.pauseWhileHidden = v } }
        .onChange(of: tick) { _, _ in on = Settings.pauseWhileHidden }
    }
}

/// Pointer on its own layer (Settings.pointerPlane, experimental, off by
/// default): read by each start of the VM.
struct PointerPlaneRow: View {
    var tick = 0
    @State private var on = Settings.pointerPlane

    static let info = "Moving the pointer no longer redraws the VM's screen. Linux puts the pointer on a layer of its own, and the Mac shows that layer over the VM's window: the same pointer in the same place (with Extra brightness as bright as the picture), but the VM's picture is not drawn again for each move. Less GPU work and battery while you move the pointer. The pointer moves on its own, like the Mac's own pointer: while you drag something it can be a frame ahead of it. On every display the VM uses. Counts from the next start of the VM; the VM gets the driver for it with Update VM (needs internet once). Experimental."

    var body: some View {
        SettingRow(title: "Pointer on its own layer", badge: "experimental",
                   subtitle: Settings.macPointer ? "Off while macPointer is set (defaults)." : "Moving the pointer no longer redraws the VM's screen. From the next start of the VM.",
                   info: Self.info, probe: "pointer-plane") {
            RowSwitch(title: "Pointer on its own layer", isOn: $on, enabled: !Settings.macPointer)
        }
        .onChange(of: on) { _, v in if v != Settings.pointerPlane { Settings.pointerPlane = v } }
        .onChange(of: tick) { _, _ in on = Settings.pointerPlane }
    }
}

/// Draw only what changed (Settings.presentTiles, experimental, off by
/// default): QEMU's tiled present, read by each start of the VM.
struct PresentTilesRow: View {
    var tick = 0
    @State private var on = Settings.presentTiles

    static let info = "When only a small part of the VM's screen changes (the pointer, a blinking cursor, a clock, a spinner), only that part goes to macOS as new pixels, in squares of 256 x 256; macOS then redraws only those squares of the window instead of all of it. Less GPU work and battery, measured for the whole Mac: a MacBook Air M2 at 60 Hz with the pointer moving 11-17 % less power. On a MacBook Pro M1 Max with HDR at 120 Hz, macOS used less GPU time to draw the window with the pointer moving or a spinner (its power is still being measured). The same picture and the same frame rate in the tests (60 Hz 8-bit and HDR, 120 Hz HDR). Pages that scroll or play video change most of the screen and stay as before. With the switch on, the VM loads OmacVM's own build of its graphics driver, which tells the Mac what changed in each frame: Update VM builds it (needs internet once). Off, the Mac draws whole frames as before, and the VM loads the driver it would without this switch: the standard one, or OmacVM's own when HDR and 10-bit colour or Pointer on its own layer is on (that one now always says what changed, but the Mac does not use it). A window that scales the VM's picture (not shown pixel for pixel) draws whole frames as before. Counts from the next start of the VM. Experimental: it may use up to about 130 MB more memory on large displays while parts change (the squares' own pictures and what macOS keeps of them). GPU safe mode turns it off."

    var body: some View {
        SettingRow(title: "Draw only what changed", badge: "experimental",
                   subtitle: Settings.gpuSafeMode ? "Off while GPU safe mode is on." : "Small changes go to macOS as small squares, not as a whole new picture. From the next start of the VM.",
                   info: Self.info, probe: "present-tiles") {
            RowSwitch(title: "Draw only what changed", isOn: $on, enabled: !Settings.gpuSafeMode)
        }
        .onChange(of: on) { _, v in if v != Settings.presentTiles { Settings.presentTiles = v } }
        .onChange(of: tick) { _, _ in on = Settings.presentTiles }
    }
}

/// The sound on its own thread (Settings.audioThread, on by default from
/// 3.1.17): read by each start of the VM, so a change counts from the next one.
struct SoundThreadRow: View {
    var tick = 0
    @State private var on = Settings.audioThread

    static let info = "Reduces audio crackles in the VM. The VM's sound card runs on a real-time thread of its own, so the VM's graphics can no longer hold it up while apps open or pages scroll. Measured: almost no breaks while browsing or with the Mac busy (before: up to 14 in 4 minutes), and the sound about 60 ms sooner. With games or WebGL crackles can still happen as before. Off: the sound in QEMU's main loop, as up to 3.1.16. Counts from the next start of the VM."

    var body: some View {
        SettingRow(title: "Sound on its own thread",
                   subtitle: Settings.audioClassic ? "Off while audioClassic is set (defaults)." : "Fewer crackles while apps open or the Mac is busy.",
                   info: Self.info, probe: "sound-thread") {
            RowSwitch(title: "Sound on its own thread", isOn: $on, enabled: !Settings.audioClassic)
        }
        .onChange(of: on) { _, v in if v != Settings.audioThread { Settings.audioThread = v } }
        .onChange(of: tick) { _, _ in on = Settings.audioThread }
    }
}

/// AirPods and media controls (Settings.mediaControls, on by default): the
/// launcher follows the switch at once (MediaSession).
struct MediaControlsRow: View {
    var tick = 0
    @State private var on = Settings.mediaControls

    static let info = "AirPods, other Bluetooth headphones and speakers, Control Center and the keyboard's play keys play, pause and skip what plays in the VM (a video in the browser, music, mpv). While the VM plays, it is the Mac's Now Playing app, like Music or Safari, and Control Center shows what plays under this app's name. A Mac app that starts playing takes the controls, as between Mac apps; playing again in the VM takes them back. Volume stays the Mac's. Nothing changes until something plays in the VM, and after 30 minutes paused the Mac's apps have the controls again. Works at once in a running VM; the VM needs Update VM once."

    var body: some View {
        SettingRow(title: "AirPods and media controls",
                   subtitle: "AirPods, headphones and Control Center play and pause what the VM plays.",
                   info: Self.info, probe: "media-controls") {
            RowSwitch(title: "AirPods and media controls", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != Settings.mediaControls { Settings.mediaControls = v } }
        .onChange(of: tick) { _, _ in on = Settings.mediaControls }
    }
}

/// The VM's GPU work without QEMU's big lock (Settings.gpuOffMainLoop,
/// 3.1.18, on by default after 3.1.25): read by each start of the VM.
struct GPUOffMainLoopRow: View {
    var tick = 0
    @State private var on = Settings.gpuOffMainLoop

    static let info = "Fewer short freezes in the VM. While an app opens or a page draws new things, the VM's graphics held QEMU's lock for up to 100-350 ms, and the VM's CPUs, its sound and typing waited that long. With this on, graphics work that only touches the GPU runs without that lock. Measured on a Mac mini: the longest stop of the VM while Chromium windows opened 107 ms -> 1 ms, while a Vulkan app started 779 ms -> 14 ms; keys reach the screen as fast as before, and the GPU scores are the same. On by default; GPU safe mode always takes the old way. Counts from the next start of the VM."

    var body: some View {
        SettingRow(title: "Graphics without QEMU's lock",
                   subtitle: Settings.gpuSafeMode ? "Off while GPU safe mode is on." : "Fewer short freezes while apps open or pages draw.",
                   info: Self.info, probe: "gpu-off-main-loop") {
            RowSwitch(title: "Graphics without QEMU's lock", isOn: $on, enabled: !Settings.gpuSafeMode)
        }
        .onChange(of: on) { _, v in if v != Settings.gpuOffMainLoop { Settings.gpuOffMainLoop = v } }
        .onChange(of: tick) { _, _ in on = Settings.gpuOffMainLoop }
    }
}

/// Keyboard sharing apps (Settings.shareKeyboard, #350): OmacVM's key taps
/// at the end of macOS's chain; read by each start of the VM.
struct ShareKeyboardRow: View {
    var tick = 0
    @State private var on = Settings.shareKeyboard

    static let info = "Turn this on if you use one keyboard and mouse for several computers with Synergy, Deskflow, Barrier or Input Leap. Without it, a VM started after the sharing app takes the keys even while the pointer is on the other computer. With it, the sharing app sees the keys first: it keeps the ones for the other computer and the VM gets the rest. Trackpad gestures still go to the VM. Counts from the next start of the VM."

    var body: some View {
        SettingRow(title: "Keyboard sharing apps",
                   subtitle: "Synergy, Deskflow, Barrier or Input Leap get the keys first.",
                   info: Self.info, probe: "share-keyboard") {
            RowSwitch(title: "Keyboard sharing apps", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != Settings.shareKeyboard { Settings.shareKeyboard = v } }
        .onChange(of: tick) { _, _ in on = Settings.shareKeyboard }
    }
}

/// Vulkan windows without a copy (Settings.vkWindowsNoCopy, ADR 0047,
/// on by default after 3.1.25): read by each start of the VM.
struct VKWindowsNoCopyRow: View {
    var tick = 0
    @State private var on = Settings.vkWindowsNoCopy

    static let info = "Vulkan apps' windows reach the Mac's screen without a copy. QEMU copied every frame of a Vulkan window on its main loop: 2.5 ms a frame for a 1816 x 870 window on a Mac mini, while the VM's CPUs waited for it. With this on, the Vulkan driver writes each frame into memory the Mac's OpenGL can read, and the GPU puts it in place: 0.3 ms of QEMU's time a frame. Frame rates stay the same; the pictures are bit for bit the same. Only on macOS 26 and newer (KosmicKrisp); with MoltenVK the frames are copied as before. On by default; GPU safe mode always copies. Counts from the next start of the VM."

    /// Only KosmicKrisp can do it; with MoltenVK (macOS 15, or an app without
    /// KosmicKrisp) the frames are copied whatever the stored setting says.
    static var usable: Bool { Runner.vulkanDriverKind == .kosmicKrisp }

    var body: some View {
        let usable = Self.usable
        SettingRow(title: "Vulkan windows without a copy",
                   subtitle: Settings.gpuSafeMode ? "Off while GPU safe mode is on."
                       : usable ? "Less work for QEMU on each frame of a Vulkan app (macOS 26 and newer)."
                       : "Not on this Mac: needs macOS 26 (KosmicKrisp); Vulkan windows are copied.",
                   info: Self.info, probe: "vk-windows-no-copy") {
            RowSwitch(title: "Vulkan windows without a copy", isOn: usable ? $on : .constant(false),
                      enabled: usable && !Settings.gpuSafeMode)
        }
        .onChange(of: on) { _, v in if v != Settings.vkWindowsNoCopy { Settings.vkWindowsNoCopy = v } }
        .onChange(of: tick) { _, _ in on = Settings.vkWindowsNoCopy }
    }
}

/// Ghostty on the Mac's GPU (Settings.ghosttyGPU, experimental, off by
/// default; ADR 0064): read by each start of the VM. While the VM runs, the
/// row says what that start did (GhosttyGPU, from its line in qemu.log), as
/// the HDR row does: a restart inside the VM keeps it.
struct GhosttyGPURow: View {
    var tick = 0
    /// The VM this window shows, and whether it runs now.
    var folder: URL?
    var running = false
    @State private var on = Settings.ghosttyGPU
    @State private var line = (text: GhosttyGPU.usual, isNote: false)

    static let info = "Ghostty needs OpenGL 4.3, and the VM's own OpenGL stops at 4.1, so Ghostty draws on the VM's CPU (Mesa's llvmpipe). With this on, Ghostty draws on the Mac's GPU instead, through Zink over the VM's Vulkan: measured on a Mac mini M4 and a MacBook Pro M1 Max, typing showed on the screen in 25-38 ms instead of 55-62 ms, and fast output took Ghostty about a tenth of the CPU time (2-4 instead of 33-35 CPU seconds per 10 seconds) with the same picture. Only Ghostty: the programs you start in it, and every other app, keep their graphics. Needs Graphics Vulkan (or Automatic) on macOS 26 and newer (KosmicKrisp); on other Macs Ghostty stays on the CPU. Each Ghostty window takes about 150-300 MB of the Mac's graphics memory, and up to about 12 % of the Mac's GPU while text scrolls. If the Mac refuses a GPU command of Ghostty, that Ghostty stops responding: close it (the programs running in it end). Counts when the VM starts, not at a restart inside it; a Ghostty that is already open keeps its driver until you quit it. The VM gets the part that does this with Update VM. Experimental. GPU safe mode turns it off."

    /// Only KosmicKrisp: with MoltenVK (macOS 15, or an app without
    /// KosmicKrisp) Ghostty stays on the CPU whatever the stored setting says.
    static var usable: Bool { Runner.vulkanDriverKind == .kosmicKrisp }

    var body: some View {
        let usable = Self.usable
        SettingRow(title: "Ghostty on the Mac's GPU", badge: "experimental", subtitle: line.text, subtitleIsNote: line.isNote,
                   info: Self.info, probe: "ghostty-gpu") {
            RowSwitch(title: "Ghostty on the Mac's GPU", isOn: usable ? $on : .constant(false),
                      enabled: usable && !Settings.gpuSafeMode)
        }
        .onAppear(perform: refresh)
        .onChange(of: on) { _, v in
            if v != Settings.ghosttyGPU { Settings.ghosttyGPU = v }
            refresh()
        }
        .onChange(of: tick) { _, _ in on = Settings.ghosttyGPU; refresh() }
        .onChange(of: running) { _, _ in refresh() }
        .onChange(of: folder) { _, _ in refresh() }
    }

    /// The subtitle, with the note from the running VM's qemu.log (its head).
    private func refresh() {
        let log = running ? folder.flatMap { KeyAccess.lastLog(folder: $0) } : nil
        let l = GhosttyGPU.subtitle(switchOn: Settings.ghosttyGPU, safeMode: Settings.gpuSafeMode,
                                    macDriver: GhosttyGPU.Driver(Runner.vulkanDriverKind), running: running, log: log)
        if l != line { line = l }
    }
}

/// The escape combo (EscapeSetting: org.omacvm.gestures EscapeSwipe).
struct EscapeRow: View {
    var tick = 0
    @State private var choice = EscapeSetting.current()

    static let info = "In a full-screen VM, Control-Option-Esc moves the focused monitor (the one you work on in the VM; else the one under the pointer) or all monitors to the Space beside the VM's with macOS's own animation; the VM stays full screen. Pressed in macOS, it goes back into the VM. The keyboard follows the monitor that moved."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Escape combo (⌃⌥ Esc)")
                InfoButton(topic: "the escape combo", text: Self.info)
            }
            Text("Takes you back to macOS.").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 26) {
                PictureChoice(title: EscapeSetting.Choice.pointer.title, selected: choice == .pointer, width: 196) {
                    set(.pointer)
                } picture: { EscapePicture(all: false) }
                PictureChoice(title: EscapeSetting.Choice.all.title, selected: choice == .all, width: 196) {
                    set(.all)
                } picture: { EscapePicture(all: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .onChange(of: tick) { _, _ in choice = EscapeSetting.current() }
    }

    private func set(_ c: EscapeSetting.Choice) {
        choice = c
        EscapeSetting.set(c)
    }
}

// MARK: Input

/// Keyboard access: macOS's "control the computer" for OmacVM, which QEMU's
/// key tap needs (KeyAccess, KeyNote). Allowed: a green dot; not: Allow….
struct KeyboardRow: View {
    @ObservedObject var state: AppState
    /// The window pictures: this answer instead of the Mac's.
    var preview: KeyNote?
    @State private var keyNote = KeyNote.none

    static let allowedInfo = "Without this permission, ⌘ Tab, ⌘ Space and ⌘ ⇧ 4 go to macOS instead of Omarchy. macOS keeps it under Privacy & Security › Accessibility."

    var body: some View {
        SettingRow(title: "Keyboard access", subtitle: "Lets Mac shortcuts like ⌘Tab reach the VM.",
                   info: keyNote == .needsUser ? KeyAccess.missingText : Self.allowedInfo, probe: "keyboard") {
            if keyNote == .needsUser {
                HStack(spacing: 5) {
                    Circle().fill(Look.red).frame(width: 7, height: 7)
                    Text("Not allowed").font(.subheadline)
                }
                Button("Allow…") { KeyAccess.request { refreshKeyNote() } }
            } else {
                HStack(spacing: 5) {
                    Circle().fill(Look.green).frame(width: 7, height: 7)
                    Text("Allowed").font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear(perform: refreshKeyNote)
        .onChange(of: state.config.folder) { _, _ in refreshKeyNote() }
        .onChange(of: state.tick) { _, _ in refreshKeyNote() }
    }

    /// Checked again every few seconds and when OmacVM comes to the front
    /// (back from System Settings).
    private func refreshKeyNote() {
        keyNote = preview ?? KeyAccess.note(folder: state.config.folder)
        // Red: first clear an old "control the computer" entry (KeyAccess.reset).
        if keyNote == .needsUser, preview == nil {
            KeyAccess.clearOldEntryOnce { refreshKeyNote() }
        }
    }
}

/// Swipe out to macOS (org.omacvm.gestures SwipeOut, off by default): past
/// the first or the last workspace, a swipe goes on to the macOS Space beside
/// the VM. OmacVM Gestures reads it.
struct SwipeOutRow: View {
    var tick = 0
    /// This VM has trackpad gestures off: nothing to swipe with there.
    var gesturesOff = false
    @State private var on = SwipeOutSetting.current()

    var body: some View {
        SettingRow(title: "Swipe out to macOS",
                   subtitle: "Swipe past the first or last workspace to the macOS Space beside it."
                       + (gesturesOff ? " Trackpad gestures are off in this VM." : ""), probe: "swipe-out") {
            SwipeOutPicture()
            RowSwitch(title: "Swipe out to macOS", isOn: $on)
        }
        .onChange(of: on) { _, v in if v != SwipeOutSetting.current() { SwipeOutSetting.set(v) } }
        .onChange(of: tick) { _, _ in on = SwipeOutSetting.current() }
    }
}

/// A feature the VM's record (its folder's `features`) has off.
enum VMRecord {
    static func isOff(_ feature: String, folder: URL) -> Bool {
        let text = (try? String(contentsOf: folder.appendingPathComponent("features"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).contains { $0 == "\(feature)=off" }
    }
}

// MARK: Sharing & Devices

/// One folder of the Mac at ~/Mac in the VM (MacFolder, the VM folder's
/// mac-folder file), off by default. Switching it on asks for the folder.
struct MacFolderRow: View {
    @ObservedObject var state: AppState
    @State private var path: String?
    @State private var error: String?

    var body: some View {
        SettingRow(title: "Mac folder",
                   subtitle: error ?? path.map { "\(StorageModel.short(URL(fileURLWithPath: $0))) appears at ~/Mac in the VM." }
                       ?? "Share one folder of the Mac at ~/Mac in the VM.",
                   subtitleIsError: error != nil,
                   info: "The VM can read and change everything in that folder.", probe: "mac-folder") {
            if path != nil {
                Button("Choose…") { if let url = MacFolder.choose(current: path) { set(url) } }
            }
            RowSwitch(title: "Mac folder", isOn: Binding(get: { path != nil }, set: { on in
                if !on { set(nil) } else if let url = MacFolder.choose(current: path) { set(url) }
            }))
        }
        .help(path ?? "")
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        .onChange(of: state.tick) { _, _ in refresh() }
    }

    private func refresh() { path = MacFolder.path(state.config) }

    private func set(_ url: URL?) {
        do {
            try MacFolder.set(url, for: state.config)
            error = nil
        } catch {
            self.error = "Could not share: \(error.localizedDescription)"
        }
        refresh()
    }
}

/// The fast network (experimental): a switch, never automatic. Turning it
/// on installs a small system service, so macOS asks for the password once.
struct FastNetworkRow: View {
    @ObservedObject var state: AppState
    @State private var on = false
    @State private var busy = false
    @State private var error: String?
    @State private var status = ""
    /// The service needs the person (FastNetwork.serviceNeeds): its button.
    @State private var fix: String?

    static let info = "Off: QEMU's own network. On: macOS's VM network (as Parallels and UTM), faster to and from the Mac; macOS asks for your password once. The Mac reaches the VM there: OmacVM needs Local Network (Privacy & Security), as for devices on your network."

    var body: some View {
        SettingRow(title: "Fast network", badge: "experimental",
                   subtitle: error ?? (status.isEmpty ? "macOS's VM network, faster to and from the Mac." : status),
                   subtitleIsError: error != nil, info: Self.info, probe: "fast-network") {
            if busy { ProgressView().controlSize(.small) }
            if let fix, on { Button(fix) { update() }.disabled(busy) }
            RowSwitch(title: "Fast network", isOn: Binding(get: { on }, set: { v in if v != on { toggle() } }), enabled: !busy)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config.folder) { _, _ in error = nil; refresh() }
        // Every few seconds only the switch's file; the service's check (it
        // reads QEMU's whole binary) when it changed.
        .onChange(of: state.tick) { _, _ in if !busy && FastNetwork.isOn(state.config) != on { refresh() } }
    }

    /// The line under the switch, worked out off the main thread (the service
    /// check verifies QEMU's code signature, which reads the whole binary).
    /// Off says nothing: the line says what it is. The service is checked as
    /// the installer checks it (an older build of the same protocol is fine;
    /// another protocol after an app update needs an update): its button
    /// then, Update… or Install….
    nonisolated static func status(_ c: VMConfig) -> (on: Bool, text: String, fix: String?) {
        guard FastNetwork.isOn(c) else { return (false, "", nil) }
        let status = FastNetwork.serviceStatus()
        if status == "stopped" { return (true, "On, but \(FastNetwork.stoppedText); until then the VM starts on the normal network.", nil) }
        if let need = FastNetwork.serviceNeeds(status) {
            return (true, "On. \(need.why) \(need.button) fixes it and asks for your password once.", need.button)
        }
        if let why = FastNetwork.serviceProblem() { return (true, "On, but \(why): switch it off, then on again.", nil) }
        return (true, "", nil)
    }

    private func refresh() {
        let c = state.config
        on = FastNetwork.isOn(c)
        Task.detached {
            let st = Self.status(c)
            await MainActor.run { show(st) }
        }
    }

    private func show(_ st: (on: Bool, text: String, fix: String?)) {
        on = st.on
        status = st.text
        fix = st.fix
    }

    private func toggle() {
        let c = state.config, turnOn = !on
        // A VM of this app that runs on the fast network keeps it until it shuts down.
        let inUse = state.vmRunning() && FastNetwork.lastRecord(c) == "vmnet"
        busy = true
        error = nil
        Task.detached {
            let err = turnOn ? FastNetwork.turnOn(c) : FastNetwork.turnOff(c, vmnetInUse: inUse)
            let st = Self.status(c)
            await MainActor.run {
                busy = false
                error = err
                show(st)
            }
        }
    }

    /// Update… / Install…: the service for this app (macOS's password dialog).
    private func update() {
        let c = state.config
        busy = true
        error = nil
        Task.detached {
            let err = FastNetwork.updateService()
            let st = Self.status(c)
            await MainActor.run {
                busy = false
                error = err
                show(st)
            }
        }
    }
}

// MARK: Storage & Updates

/// The weekly-check switch (shared with the control centre), Check Now and
/// what the last check found.
struct UpdateRow: View {
    @ObservedObject var updater: Updater
    /// A VM runs from this app: the update waits for its shutdown.
    var running = false

    private var line: String {
        if let v = updater.downloading { return Self.downloadLine(v, updater.downloaded) }
        if updater.checking { return "Checking…" }
        if let s = updater.staged { return "\(Product.name) \(s.version) is ready to install." }
        if let o = updater.lastOutcome, let l = Updater.outcomeLine(o, current: updater.currentVersion) { return l }
        if !updater.enabled { return "Off: no checks and no messages. Check Now still works." }
        guard Version(updater.currentVersion) != nil else { return "Check Now looks for a newer version." }
        if let d = updater.lastCheckDate { return "Checked \(Self.when(d)). \(Product.name) \(updater.currentVersion) is the newest version." }
        return "You have \(Product.name) \(updater.currentVersion)."
    }

    /// "Downloading OmacVM 3.1.4… 12.3 of 34.8 MB" (nothing yet: no numbers).
    static func downloadLine(_ version: String, _ progress: (done: Int64, total: Int64)?) -> String {
        let head = "Downloading \(Product.name) \(version)…"
        guard let p = progress, p.done > 0, p.total > 0 else { return head }
        return head + String(format: " %.1f of %.1f MB", Double(min(p.done, p.total)) / 1e6, Double(p.total) / 1e6)
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        let s = f.string(from: d)
        // "Today at 14:02" -> "today at 14:02"
        return Calendar.current.isDateInToday(d) || Calendar.current.isDateInYesterday(d) ? s.prefix(1).lowercased() + s.dropFirst() : "on \(s)"
    }

    var body: some View {
        SettingRow(title: "Check for updates once a week", subtitle: line,
                   info: "Off: no checks and no messages. Check Now still works. The same switch as in the control centre in Omarchy.",
                   probe: "updates") {
            if updater.checking { ProgressView().controlSize(.small) }
            if updater.staged != nil && !updater.installWhenIdle && !updater.restarting {
                // The same button as the banner, also here.
                Button(UpdateBanner.updateTitle(running: running)) { UpdateBanner.update(updater) }
                    .layoutProbe("row-update-now")
            } else {
                Button("Check Now") { Task { await updater.checkNow() } }
                    .disabled(updater.checking || updater.restarting)
            }
            RowSwitch(title: "Check for updates once a week", isOn: Binding(get: { updater.enabled }, set: { updater.setEnabled($0) }))
        }
    }
}
