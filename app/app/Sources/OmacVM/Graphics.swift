import Foundation

/// The VM's graphics: OpenGL only, OpenGL plus Vulkan (Venus), or Automatic.
/// Kept per VM in the VM folder's `graphics` file (opengl, vulkan or auto;
/// none means auto), set in the app's setup and VM window, with
/// `omacvm graphics` and in the control centre. Foundation only, so
/// src/tests/graphics-setting.sh can test it on its own; src/lib/graphics.sh
/// has the same rules for the Mac side of omacvm (that test keeps them equal).
enum GraphicsChoice: String, CaseIterable {
    case auto, opengl, vulkan

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .opengl: return "OpenGL"
        case .vulkan: return "Vulkan"
        }
    }
}

/// What one start of a VM gets.
struct GraphicsPlan: Equatable {
    var choice: GraphicsChoice
    /// The Venus device (Vulkan) at this start.
    var venus: Bool
    /// Its host memory window in MB (a power of two, 256 MB or more).
    var hostmemMB: Int
    /// QEMU's high PCI window in GB on a Mac with a small VM address space
    /// (M1/M2: highmem-mmio-size, right above RAM); nil: QEMU's own.
    var highWindowGB: Int? = nil
    /// Why a Vulkan start fell back, with what happens next ("...; choose
    /// Vulkan again to try once more"); nil: no fallback.
    var fellBack: String? = nil
    /// Why, for qemu.log ("OmacVM: graphics: ...") and omacvm check.
    var why: String

    /// The next start in words, as omacvm graphics and the control centre
    /// say it: "Vulkan (driver not built yet: ...)" while a VM set to Vulkan
    /// waits for its driver.
    var summary: String {
        venus ? "OpenGL and Vulkan"
            : choice == .vulkan ? (why.hasPrefix(Graphics.didNotStart) ? why : "Vulkan (\(why))") : "OpenGL"
    }

    var record: String {
        "\(choice.rawValue) -> \(venus ? "vulkan" : "opengl") (\(fellBack.map { "\(Graphics.didNotStartOnMac): \($0)" } ?? why))"
            + (venus ? ", host memory window \(Graphics.size(mb: hostmemMB))" : "")
            + (venus && highWindowGB != nil ? ", PCI window \(highWindowGB!) GB" : "")
    }
}

enum Graphics {
    static let fileName = "graphics"
    /// Written by omacvm apply when the VM has a Venus driver that sizes GPU
    /// memory to the Mac's 16 KiB pages (Mesa 26.2.4 or newer, or OmacVM's
    /// Mesa of the vulkan feature). Automatic waits for it.
    static let readyFileName = "venus-ready"

    /// Automatic gives Vulkan at all. 3.0.2: yes, by the macOS 26+ rule below.
    /// On KosmicKrisp Vulkan on costs the OpenGL desktop nothing (A/B,
    /// 2026-10-06: Mac mini M4 glmark2, WebGL Aquarium and the GPU throughput
    /// page within 1 %; MacBook Air M2 glmark2 102 %), and Vulkan windows show
    /// through the GPU (virgl-set-type-without-egl.patch). src/lib/graphics.sh:
    /// GRAPHICS_AUTO_VULKAN, kept equal by src/tests/graphics-setting.sh.
    static let autoVulkan = true
    /// With autoVulkan: Vulkan from this macOS on, and only with KosmicKrisp
    /// in the app (Metal 4). On older macOS Venus runs on MoltenVK, which
    /// cannot carry OpenGL or WebGL (ES 2.0 only): OpenGL there.
    /// Numbers: docs/benchmarks/README.md ("Graphics: Automatic").
    static let autoVulkanFromMacOS = 26
    static let autoVulkanOnMoltenVK = false

    static func read(folder: URL) -> GraphicsChoice {
        let url = folder.appendingPathComponent(fileName)
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return .auto }
        return GraphicsChoice(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .auto
    }

    /// Any choice made by hand tries Vulkan again after a fallback.
    static func write(_ c: GraphicsChoice, folder: URL) throws {
        try Data("\(c.rawValue)\n".utf8).write(to: folder.appendingPathComponent(fileName), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(fallbackFileName))
    }

    // MARK: Vulkan that did not start (VenusStartWatch)

    /// Written when a Vulkan start showed nothing and the app started the VM
    /// on OpenGL instead: one line, why. While it is there, every start is
    /// OpenGL; choosing a Graphics setting again (app, omacvm graphics,
    /// control centre) removes it and tries Vulkan once more.
    static let fallbackFileName = "graphics-fallback"
    /// Same text in src/lib/graphics.sh (GRAPHICS_DID_NOT_START).
    static let didNotStartOnMac = "Vulkan did not start on this Mac"
    static let didNotStart = didNotStartOnMac + ": using OpenGL"

    static func fallback(folder: URL) -> String? {
        guard let s = try? String(contentsOf: folder.appendingPathComponent(fallbackFileName), encoding: .utf8) else { return nil }
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "it showed nothing" : line
    }

    static func recordFallback(_ why: String, folder: URL) {
        try? Data("\(why)\n".utf8).write(to: folder.appendingPathComponent(fallbackFileName), options: .atomic)
    }

    /// "256 MB", "1 GB".
    static func size(mb: Int) -> String { mb >= 1024 && mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB" }

    static func driverReady(folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(readyFileName).path)
    }

    /// What Automatic picks on this Mac, without the VM (the setup's caption).
    static func autoPicksVulkan(macOSMajor: Int, kosmicKrisp: Bool) -> Bool {
        autoVulkan && ((macOSMajor >= autoVulkanFromMacOS && kosmicKrisp) || autoVulkanOnMoltenVK)
    }

    /// Why a VM set to Vulkan still starts with OpenGL: without a Venus
    /// driver for 16 KiB pages every Vulkan app would fail with
    /// ERROR_OUT_OF_HOST_MEMORY. `omacvm apply` (or `omacvm graphics` while
    /// the VM runs) builds it and writes venus-ready. Same text in omacvm.
    static let waitingForDriver = "driver not built yet: runs on OpenGL until the next apply"

    /// Up to 2.9 a hidden switch (`defaults write org.omacvm.app venus -bool
    /// true`) put Vulkan in every VM. 3.0.0 moves it once into the Graphics
    /// setting: a VM without a choice of its own (no file, or Automatic)
    /// gets Vulkan; one set to OpenGL keeps it. Returns what it changed, for
    /// the log; the caller removes the switch.
    static func migrateVenusSwitch(folders: [URL]) -> [String] {
        var out: [String] = []
        for f in folders where read(folder: f) == .auto {
            do {
                try write(.vulkan, folder: f)
                out.append("'\(f.lastPathComponent)': Graphics Vulkan (the hidden venus switch was on)")
            } catch {
                out.append("'\(f.lastPathComponent)': could not set Graphics to Vulkan: \(error.localizedDescription)")
            }
        }
        return out
    }

    /// The Venus host memory window, from the VM's memory plan (one memory
    /// pool on Apple Silicon): what this Mac has beyond the VM's own memory and
    /// macOS's reserve (4 GB up to 16 GB, 6 GB up to 36 GB, 8 GB above), as a
    /// power of two between 1 and 32 GB. It is address space for mapping Vulkan
    /// memory into the VM; what Vulkan really allocates counts against the
    /// GPU memory budget (gpu-robust's budget patch).
    ///
    /// The window is a 64-bit PCI memory BAR of its own size and alignment.
    /// QEMU's virt machine has a 512 GB PCI window above 512 GB only when the
    /// Mac gives VMs a 40-bit address space or more (M3 and newer; QEMU drops
    /// it without a word on smaller ones). M1 and M2 give 36 bits: there the
    /// app asks for a smaller window right above RAM (highWindowGB, our QEMU
    /// patch qemu-virt-small-high-window) and the BAR takes at most half of
    /// it. Without that window every BAR shares the 751 MB window below 1 GB
    /// (0x10000000-0x3efeffff), where a 512 MB or 1 GB BAR never fits, and
    /// the firmware then maps no PCI device at all (no boot disk, no picture:
    /// the Air hang of 2026-10-06); 256 MB fits there, so that is the most.
    /// `ipaBits`: the Mac's VM address space (Mac.vmAddressBits; nil unknown).
    /// `smallHighWindow`: the app's QEMU has that patch (qemuTakesSmallHighWindow).
    static func hostmemMB(macMemoryGB: Int, vmMemoryGB: Int, ipaBits: Int?, smallHighWindow: Bool = true) -> Int {
        if let b = ipaBits, b < highPCIWindowBits {
            guard smallHighWindow, let w = highWindowGB(vmMemoryGB: vmMemoryGB, ipaBits: b) else { return lowWindowHostmemMB }
            return min(usualHostmemMB(macMemoryGB: macMemoryGB, vmMemoryGB: vmMemoryGB), w * 1024 / 2)
        }
        return usualHostmemMB(macMemoryGB: macMemoryGB, vmMemoryGB: vmMemoryGB)
    }

    static func usualHostmemMB(macMemoryGB: Int, vmMemoryGB: Int) -> Int {
        let reserve = macMemoryGB <= 16 ? 4 : macMemoryGB <= 36 ? 6 : 8
        let free = min(max(macMemoryGB - vmMemoryGB - reserve, 1), 32)
        var p = 1
        while p * 2 <= free { p *= 2 }
        return p * 1024
    }

    /// QEMU virt's high PCI window ends at 1 TB (40 bits).
    static let highPCIWindowBits = 40
    static let lowWindowHostmemMB = 256
    static let smallHighWindowMaxGB = 16

    /// The high PCI window for a Mac under 40 bits, in GB: the largest power
    /// of two up to 16 GB that fits the address space. QEMU puts it on its
    /// own size's boundary after RAM (from 1 GB) and the other high regions
    /// (under 512 MB), so it starts at vmMemoryGB + 3 GB at the latest.
    /// M2 Air, 4 GB VM: 16 GB at 16-32 GB. nil: none fits (or not needed).
    static func highWindowGB(vmMemoryGB: Int, ipaBits: Int?) -> Int? {
        guard let b = ipaBits, b < highPCIWindowBits, b > 30 else { return nil }
        let top = 1 << (b - 30), start = vmMemoryGB + 3
        var w = smallHighWindowMaxGB
        while w >= 1 {
            if (start + w - 1) / w * w + w <= top { return w }
            w /= 2
        }
        return nil
    }

    /// QEMU's error for a too small highmem-mmio-size with our patch
    /// (qemu-virt-small-high-window.patch); prepare-qemu-gpu-runtime.sh
    /// checks the runtime for it too.
    static let smallHighWindowMarker = "highmem-mmio-size cannot be smaller than 1 GiB"

    /// This QEMU takes a small highmem-mmio-size: its binary has the patch's
    /// text. An unpatched QEMU refuses any size under 512 GB and does not start.
    /// Tens of MB: call it off the main thread (RuntimeQEMU).
    static func qemuTakesSmallHighWindow(binary: URL) -> Bool {
        guard let d = try? Data(contentsOf: binary, options: .alwaysMapped) else { return false }
        let marker = Array(smallHighWindowMarker.utf8)
        return d.withUnsafeBytes { b in
            marker.withUnsafeBytes { m in
                guard let bp = b.baseAddress, let mp = m.baseAddress else { return false }
                return memmem(bp, b.count, mp, m.count) != nil
            }
        }
    }

    /// The plan for one start. `forced`: the vulkan feature (the VM's
    /// `vulkan` file: OmacVM's Mesa for WebGPU and OpenCL, which apply only
    /// writes once that Mesa is in the VM), which keeps Venus on whatever the
    /// choice.
    /// `fallback`: why the last Vulkan start fell back (graphics-fallback);
    /// it keeps this start on OpenGL. `fallbackOnce`: why this start's
    /// Vulkan try just fell back; OpenGL for this start only.
    /// `smallHighWindow`: the app's QEMU takes a small high PCI window.
    static func plan(choice: GraphicsChoice, macOSMajor: Int, kosmicKrisp: Bool, driverReady: Bool,
                     forced: Bool, macMemoryGB: Int, vmMemoryGB: Int, ipaBits: Int? = nil,
                     smallHighWindow: Bool = true, fallback: String? = nil, fallbackOnce: String? = nil) -> GraphicsPlan {
        let mem = hostmemMB(macMemoryGB: macMemoryGB, vmMemoryGB: vmMemoryGB, ipaBits: ipaBits, smallHighWindow: smallHighWindow)
        let window = smallHighWindow ? highWindowGB(vmMemoryGB: vmMemoryGB, ipaBits: ipaBits) : nil
        let driver = macOSMajor >= 26 && kosmicKrisp ? "KosmicKrisp" : "MoltenVK"
        func p(_ venus: Bool, _ why: String) -> GraphicsPlan {
            if venus, let f = fallback ?? fallbackOnce {
                let next = "\(f); " + (fallback != nil ? "choose Vulkan again to try once more" : "the next start tries Vulkan again")
                return GraphicsPlan(choice: choice, venus: false, hostmemMB: mem, fellBack: next,
                                    why: "\(didNotStart) (\(next))")
            }
            return GraphicsPlan(choice: choice, venus: venus, hostmemMB: mem,
                                highWindowGB: venus ? window : nil, why: why)
        }
        if forced { return p(true, "WebGPU and GPU compute (vulkan feature) need Vulkan, \(driver)") }
        switch choice {
        case .opengl: return p(false, "chosen")
        case .vulkan:
            guard driverReady else { return p(false, waitingForDriver) }
            return p(true, "chosen, \(driver)")
        case .auto:
            guard autoVulkan else { return p(false, "Automatic is OpenGL on every Mac in this version; Vulkan is your choice") }
            guard autoPicksVulkan(macOSMajor: macOSMajor, kosmicKrisp: kosmicKrisp) else {
                return p(false, kosmicKrisp || macOSMajor >= autoVulkanFromMacOS
                         ? "macOS \(macOSMajor) without KosmicKrisp in this app: MoltenVK, OpenGL stays"
                         : "macOS \(macOSMajor): MoltenVK, OpenGL stays")
            }
            guard driverReady else { return p(false, "the VM has no Venus driver for 16 KiB pages yet: omacvm apply") }
            return p(true, "macOS \(macOSMajor), \(driver)")
        }
    }
}

/// Watches the first minutes of a start with Vulkan (Runner.watchVenusStart),
/// so a Vulkan start that shows nothing never leaves a stuck VM: the app
/// stops it and starts the VM on OpenGL, once. Polled every few seconds
/// with what QMP and the VM's logs say. Time the VM is paused (the Mac's
/// sleep) does not count.
///
/// Before the firmware has mapped the PCI devices nothing but Venus's BAR
/// layout can stop a start, and that repeats on every start on this Mac:
/// that fallback is kept (graphics-fallback). Anything later (no picture)
/// is for this start only; the next start tries Vulkan again.
///
/// No picture after the firmware ran falls back only on a Mac under 40
/// address bits (M1/M2: the small PCI window is new there). On M3 and newer
/// Vulkan's layout is the one that always worked, and a guest that is only
/// slow to draw (fsck, a VM on an external drive) must not get the power
/// button: there it is only logged.
struct VenusStartWatch {
    /// The firmware maps the PCI devices within a few seconds of QEMU's
    /// start; none mapped this long after QMP first answered means it found
    /// none. Counted from that answer, so a slow start of QEMU is no hang.
    static let firmwareSeconds = 25.0
    /// QEMU's monitor silent this long after the firmware ran: logged, not
    /// taken as Vulkan's fault (any main-loop stall looks the same).
    static let silentSeconds = 30.0
    /// After this the start counts as fine and the watch ends.
    static let watchSeconds = 180.0

    struct Poll: Equatable {
        /// QMP answered (false: no answer within its timeout).
        var answered: Bool
        var paused = false
        /// "info pci" shows a mapped BAR (nil: not asked or no answer).
        var pciMapped: Bool?
        /// The VM's console log has something. It is hvc0 (virtconsole; QEMU
        /// runs with -serial none), so only Linux writes there, never the
        /// firmware: output means the firmware is long done. Counts only
        /// when QMP answered: QEMU empties the file when it opens it, and
        /// before that it still holds the last boot's text.
        var consoleOutput = false
        /// qemu.log has the window's "no picture from the guest" line: not
        /// even the firmware drew in 90 s of the guest's running time (any
        /// picture counts, so a slow fsck or disk does not).
        var noPicture = false
    }

    enum Verdict: Equatable {
        case wait, fine
        /// Something for qemu.log; the watch goes on.
        case note(String)
        /// Stop this start and start on OpenGL. graceful: the guest's kernel
        /// may run, so shut it down first; else stopping at once is safe (or
        /// the only way: QEMU does not answer). keep: OpenGL from now on
        /// (graphics-fallback), else for the next start only.
        case fallBack(why: String, graceful: Bool, keep: Bool)
    }

    /// The Mac gives VMs under 40 address bits (M1/M2).
    let smallAddressSpace: Bool

    init(smallAddressSpace: Bool = false) { self.smallAddressSpace = smallAddressSpace }

    private(set) var ran = 0.0
    /// Time since QMP first answered (the firmware rule's clock).
    private(set) var sinceAnswer = 0.0
    private(set) var silent = 0.0
    private(set) var answeredOnce = false
    private(set) var firmwareSeen = false
    private(set) var stallNoted = false
    private(set) var done = false

    /// The Mac woke up: a monitor kept busy by the sleep handling is no hang.
    mutating func woke() { silent = 0 }

    mutating func poll(_ p: Poll, seconds dt: Double) -> Verdict {
        if done { return .fine }
        let wasAnswered = answeredOnce
        if p.answered {
            answeredOnce = true
            silent = 0
            if p.paused { return .wait }
        } else if wasAnswered {
            // Silence counts only after QMP answered once: a monitor this
            // app cannot reach at all is no hang.
            silent += dt
        }
        ran += dt
        if wasAnswered { sinceAnswer += dt }
        if p.answered && (p.pciMapped == true || p.consoleOutput) { firmwareSeen = true }
        if !firmwareSeen && sinceAnswer >= Self.firmwareSeconds {
            done = true
            let why = p.answered
                ? "the firmware found no devices in \(Int(Self.firmwareSeconds)) s: no boot disk, no picture"
                : "QEMU stopped answering before the firmware found its devices"
            return .fallBack(why: why, graceful: false, keep: true)
        }
        if firmwareSeen && !stallNoted && silent >= Self.silentSeconds {
            stallNoted = true
            return .note("QEMU did not answer for \(Int(Self.silentSeconds)) s after the firmware ran: no fallback for that")
        }
        if p.noPicture {
            done = true
            if firmwareSeen && !smallAddressSpace {
                return .note("no picture from the VM after 90 s, but the firmware ran: no fallback for that")
            }
            return .fallBack(why: "no picture from the VM after 90 s", graceful: firmwareSeen, keep: false)
        }
        if ran >= Self.watchSeconds {
            done = true
            return .fine
        }
        return .wait
    }

    /// "info pci": some device has a memory or I/O BAR the firmware mapped
    /// ("memory at 0x...", "I/O at 0x..."); unmapped ones say "(not mapped)".
    static func pciMapped(_ infoPCI: String) -> Bool {
        infoPCI.contains("memory at 0x") || infoPCI.contains("I/O at 0x")
    }
}
