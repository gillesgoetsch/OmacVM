import Foundation

/// The Custom resources choice in the VM window: the same limits as
/// `omacvm resources` (src/cmd/resources.sh) for CPUs (1 up to the Mac's) and
/// from 4 GB memory, but the window never gives the VM all of the Mac's
/// memory: macOS keeps max(2 GB, an eighth), or the Mac swaps itself to a
/// stop. Above what the Best tier gives (the Mac keeps max(8 GB, a quarter)
/// for macOS and the GPU) it warns but allows.
public struct ResourceLimits: Equatable {
    public let macCores: Int
    public let macMemoryGB: Int

    public init(macCores: Int, macMemoryGB: Int) {
        self.macCores = macCores
        self.macMemoryGB = macMemoryGB
    }

    public var cpus: ClosedRange<Int> { 1...max(1, macCores) }
    public var memoryGB: ClosedRange<Int> { 4...max(4, macMemoryGB - max(2, macMemoryGB / 8)) }

    /// The most memory that leaves the Mac enough: the Best tier's.
    public var safeMemoryGB: Int { max(macMemoryGB - max(macMemoryGB / 4, 8), 4) }

    /// 2 GB above the Best tier, at most the steppers' top: the memory the
    /// window pictures draw the warning with (RenderVMWindow). nil when the
    /// steppers end at Best.
    public var aboveBestGB: Int? {
        let m = min(safeMemoryGB + 2, memoryGB.upperBound)
        return m > safeMemoryGB ? m : nil
    }

    /// Why these values are refused (the CLI's wording), or nil.
    public func problem(cpus c: Int, memoryGB m: Int) -> String? {
        if !cpus.contains(c) { return "CPUs: 1 to \(cpus.upperBound)." }
        if !memoryGB.contains(m) { return "Memory: 4 to \(memoryGB.upperBound) GB." }
        return nil
    }

    /// Shown under the steppers when the memory leaves the Mac too little:
    /// above the Best tier. The VM's graphics come on top of its memory;
    /// `graphicsPeakMB` is the last run's peak (logs/gpu-memory), nil before
    /// a first run. Only says so: the setting stays the person's.
    /// `omacvm resources` and `omacvm check` say the same (mem_warning in
    /// src/lib/setup.sh).
    public func warning(memoryGB m: Int, graphicsPeakMB: Int? = nil) -> String? {
        guard m > safeMemoryGB else { return nil }
        let peak = graphicsPeakMB.flatMap { $0 > 0 ? " (peak \(Self.gb($0)) last run)" : nil } ?? ""
        return "\(m) GB and the VM's graphics on top\(peak) leave macOS too little of this Mac's \(macMemoryGB) GB: "
            + "the Mac can slow down or swap, and apps in the VM can lose their graphics. \(safeMemoryGB) GB is this Mac's Best tier."
    }

    /// "4.5 GB", "800 MB" (as GPUMemory.gb).
    static func gb(_ mb: Int) -> String {
        mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
    }

    /// What a VM starts with on this Mac: vm.env's CPUs and memory, but a
    /// value this Mac does not allow (a VM copied from a bigger Mac) is
    /// BEST's (the Best tier), for this start only. vm.env stays as it is, so
    /// the VM has its full size again on the bigger Mac. nil: as vm.env says.
    public func startSize(cpus c: Int, memoryMB m: Int, best: (cpus: Int, memoryGB: Int)) -> (cpus: Int, memoryMB: Int)? {
        let tooMany = c > cpus.upperBound, tooMuch = m > memoryGB.upperBound * 1024
        guard tooMany || tooMuch else { return nil }
        return (tooMany ? best.cpus : c, tooMuch ? best.memoryGB * 1024 : m)
    }

    /// The window's note for startSize.
    public func startSizeText(cpus c: Int, memoryMB m: Int, start: (cpus: Int, memoryMB: Int)) -> String {
        "More than this Mac allows (\(c) CPUs, \(m / 1024) GB): it starts with \(start.cpus) CPUs and \(start.memoryMB / 1024) GB here. Its settings keep \(c) CPUs and \(m / 1024) GB for the Mac it came from."
    }

    /// A value read from vm.env kept inside the steppers' range.
    public func clamp(cpus c: Int, memoryGB m: Int) -> (cpus: Int, memoryGB: Int) {
        (min(max(c, cpus.lowerBound), cpus.upperBound), min(max(m, memoryGB.lowerBound), memoryGB.upperBound))
    }
}
