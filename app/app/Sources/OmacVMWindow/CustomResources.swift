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

    /// Why these values are refused (the CLI's wording), or nil.
    public func problem(cpus c: Int, memoryGB m: Int) -> String? {
        if !cpus.contains(c) { return "CPUs: 1 to \(cpus.upperBound)." }
        if !memoryGB.contains(m) { return "Memory: 4 to \(memoryGB.upperBound) GB." }
        return nil
    }

    /// Shown under the steppers when the memory leaves the Mac too little.
    public func warning(memoryGB m: Int) -> String? {
        guard m > safeMemoryGB else { return nil }
        return "More than \(safeMemoryGB) GB leaves macOS and the graphics too little memory: the Mac can slow down or swap."
    }

    /// A value read from vm.env kept inside the steppers' range.
    public func clamp(cpus c: Int, memoryGB m: Int) -> (cpus: Int, memoryGB: Int) {
        (min(max(c, cpus.lowerBound), cpus.upperBound), min(max(m, memoryGB.lowerBound), memoryGB.upperBound))
    }
}
