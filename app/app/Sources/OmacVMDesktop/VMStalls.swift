import Foundation

/// When the VM stood still this run (ADR 0060): QEMU's logs/vm-stalls, which
/// the stall note writes (qemu-hvf-vcpu-stall-note.patch). A vCPU stands
/// still when its thread is blocked in macOS's kernel ("memory" when the Mac
/// was paging then: a page fault waiting while macOS makes memory free;
/// "kernel" when it was not) or gets no Mac core ("cpu"); QEMU's main loop
/// holds the VM with the BQL (main_*), and its graphics thread stands still
/// in a call to the Mac (gpu_*: a video decoder starting, a Metal submit).
/// QEMU writes all zeros at its start and the totals after each stall.
///
/// The app reads it in its 5 s look (GPUMemoryWatch) and, after a stall of
/// 10 s or more for memory (never "kernel"), puts a note in the VM: at most once per 30
/// minutes, through the guest agent (omacvm-desktop-recover stall; a VM
/// from before has no such note and nothing else happens). omacvm check
/// reads it for its "VM stalls" line. The text is QEMU's, so it is read as
/// untrusted: numbers clamped, causes from a list. Foundation only:
/// `swift run desktop-tests`.
public struct VMStalls: Equatable, Sendable {
    public static let noteAfterMs = 10_000
    public static let noteGap: TimeInterval = 30 * 60
    /// Larger numbers (or longer than 12 digits) are not QEMU's: 0.
    public static let most = 1 << 40

    /// vCPU episodes of 1 s or more, the longest and the last.
    public var stalls = 0
    public var longestMs = 0
    public var longestCause = ""        // "memory", "kernel", "cpu" or ""
    public var lastMs = 0
    public var lastCause = ""
    public var lastAt = 0               // seconds since 1970
    public var lastVMMB = 0             // QEMU's footprint then
    public var lastFreeMB = 0           // the Mac's free memory then
    /// QEMU's graphics thread: stalls of 2 s or more in a call to the Mac.
    public var gpuStalls = 0
    public var gpuLongestMs = 0
    /// QEMU's main loop: stalls of 2 s or more with the BQL (the VM waited).
    public var mainStalls = 0
    public var mainLongestMs = 0

    public init() {}

    /// nil: not the stall note's file (an older QEMU writes none).
    public static func parse(_ text: String) -> VMStalls? {
        var s = VMStalls()
        var seen = false
        for line in text.prefix(4096).split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            let n = value.count <= 12 ? min(max(Int(value) ?? 0, 0), most) : 0
            let cause = ["memory", "kernel", "cpu"].contains(value) ? value : ""
            switch key {
            case "stalls": s.stalls = n; seen = true
            case "longest_ms": s.longestMs = n
            case "longest_cause": s.longestCause = cause
            case "last_ms": s.lastMs = n
            case "last_cause": s.lastCause = cause
            case "last_at": s.lastAt = n
            case "last_vm_mb": s.lastVMMB = n
            case "last_free_mb": s.lastFreeMB = n
            case "gpu_stalls": s.gpuStalls = n
            case "gpu_longest_ms": s.gpuLongestMs = n
            case "main_stalls": s.mainStalls = n
            case "main_longest_ms": s.mainLongestMs = n
            default: break
            }
        }
        return seen ? s : nil
    }

    /// The VM gets a note now: a stall it has not heard of (more than SEEN),
    /// for memory (QEMU saw the Mac paging then; "kernel" is not enough), 10 s
    /// or more, and none told in the last 30 minutes.
    public static func noteDue(_ s: VMStalls, seen: Int, lastNote: Date?, now: Date) -> Bool {
        guard s.stalls > seen, s.lastCause == "memory", s.lastMs >= noteAfterMs else { return false }
        guard let last = lastNote else { return true }
        return now.timeIntervalSince(last) >= noteGap
    }

    /// The note's arguments for omacvm-desktop-recover stall: seconds, the
    /// VM's GB on the Mac then, the Mac's GB (the VM words the note).
    public static func noteArguments(_ s: VMStalls, macBytes: UInt64) -> [String] {
        let secs = max(1, (s.lastMs + 500) / 1000)
        let vm = (s.lastVMMB + 512) / 1024
        return ["stall", "\(secs)", "\(vm)", "\(macBytes >> 30)"]
    }
}
