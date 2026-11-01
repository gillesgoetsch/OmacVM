import Foundation

/// Ghostty on the Mac's GPU (experimental, off by default; ADR 0064's
/// amendment). Ghostty needs OpenGL 4.3 and the VM's GPU gives 4.1, so the
/// VM's EGL vendor library starts Ghostty alone on Mesa's CPU renderer. With
/// this switch on, a start that has Vulkan on KosmicKrisp tells the VM so
/// (SMBIOS omacvm.glzink=1, host.env OMACVM_GLZINK=1), and the library starts
/// Ghostty on Zink over Venus with OpenGL 4.3 instead. Only KosmicKrisp: on
/// MoltenVK Zink does not start (the VM falls back to the CPU by itself), and
/// only KosmicKrisp was measured. Read at each start, like HDR: a restart
/// inside the VM keeps that start's answer.
public enum GhosttyGPU {
    /// The Vulkan driver the runtime loads at this start (Graphics.vulkanDriverKind).
    public enum Driver: Equatable {
        case kosmicKrisp, moltenVK
        /// A driver VK_DRIVER_FILES / VK_ICD_FILENAMES names: not measured.
        case listed
    }

    public static let smbios = "omacvm.glzink=1"
    /// qemu.log's line for this start, written only while the switch is on.
    public static let logTag = "OmacVM: Ghostty on the Mac's GPU: "

    /// The answer at a start of the VM: the switch, GPU safe mode, whether
    /// this start has Venus (Graphics), and its Vulkan driver.
    public static func start(switchOn: Bool, safeMode: Bool, venus: Bool, driver: Driver) -> (on: Bool, why: String) {
        if !switchOn { return (false, "switch off") }
        if safeMode { return (false, "GPU safe mode") }
        if !venus { return (false, "Graphics is OpenGL at this start") }
        switch driver {
        case .kosmicKrisp: return (true, "Zink over Venus on KosmicKrisp")
        case .moltenVK: return (false, "MoltenVK: needs KosmicKrisp (macOS 26 and newer)")
        case .listed: return (false, "the Vulkan driver VK_DRIVER_FILES names")
        }
    }

    /// The line for qemu.log.
    public static func record(_ s: (on: Bool, why: String)) -> String {
        "\(logTag)\(s.on ? "on" : "off") (\(s.why))"
    }

    /// This start's answer from the head of qemu.log: on, off with why (the
    /// switch was on), or nil (no line: the switch was off).
    public static func startAnswer(_ log: String) -> (on: Bool, why: String)? {
        guard let line = log.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(logTag) }) else { return nil }
        let rest = line.dropFirst(logTag.count)
        var why = ""
        if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
            why = String(rest[rest.index(after: open)..<close])
        }
        if rest.hasPrefix("on") { return (true, why) }
        if rest.hasPrefix("off") { return why == "switch off" ? nil : (false, why) }
        return nil
    }

    /// The row's subtitle without a note.
    public static let usual = "Ghostty draws on the Mac's GPU instead of the VM's CPU. Needs Graphics Vulkan on macOS 26 and newer."

    /// The row's subtitle, and whether it is a note (the row shows it in
    /// orange): the running VM's own start first, as the HDR row does; else
    /// what this Mac allows.
    /// - switchOn: the switch now; safeMode: Settings.gpuSafeMode.
    /// - macDriver: the Vulkan driver a start on this Mac gets.
    /// - running: this VM runs now; log: the head of its logs/qemu.log.
    public static func subtitle(switchOn: Bool, safeMode: Bool, macDriver: Driver, running: Bool, log: String?) -> (text: String, isNote: Bool) {
        if let n = note(switchOn: switchOn && !safeMode, running: running, log: log) { return (n, true) }
        if safeMode { return ("Off while GPU safe mode is on.", false) }
        if macDriver != .kosmicKrisp { return ("Not on this Mac: needs macOS 26 (KosmicKrisp); Ghostty draws on the VM's CPU.", false) }
        return (usual, false)
    }

    /// The note about the running VM; nil: no note.
    public static func note(switchOn: Bool, running: Bool, log: String?) -> String? {
        guard running, let log else { return nil }
        switch (switchOn, startAnswer(log)) {
        case (false, .some(let s)) where s.on:
            return "This VM still asks for Ghostty on the Mac's GPU. That ends when you shut the VM down and start it again."
        case (true, .none):
            return "This start of the VM keeps Ghostty on the CPU. Shut the VM down and start it again, then quit Ghostty and open it again."
        case (true, .some(let s)) where !s.on:
            return s.why.isEmpty ? "Not used at this start of the VM." : "Not used at this start of the VM: \(s.why)."
        default:
            return nil
        }
    }
}
