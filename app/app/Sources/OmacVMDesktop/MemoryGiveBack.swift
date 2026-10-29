import Foundation

/// When the VM gives its cold file cache back to the Mac (ADR 0059). It
/// reaches macOS only through QEMU's reclaim fix (`pagesGoBack`, ADR 0062);
/// without it the cache leaves QEMU's footprint and the Mac keeps the pages.
///
/// Linux keeps every file it read in its page cache. In a VM that is memory
/// the Mac backs but cannot drop: to macOS it is the VM's own memory, so
/// macOS compresses it and the Mac slows down, while its own file cache
/// already holds the same files (QEMU reads the disk image through it).
/// macOS's memory pressure stays "normal" while it compresses (it counts
/// every page it can still compress as available), so the warning that
/// drops the VM's cache (since 2.9) came too late or never.
///
/// Only with a QEMU that gives the pages of a free page report back to macOS
/// (`pagesGoBack`: the reclaim fix, ADR 0062, read from QEMU's binary), and
/// only until that QEMU says macOS keeps them anyway (`qemuKeeps`: a refused
/// or skipped advice; it then stops for the run). 3.2.11's QEMU keeps holding
/// what the VM gives back (Mac mini, 3 GB VM: 1345 of 1346 MB and 1721 of
/// 1721 MB still held; work/tracks/vm-memory-gap.md), and a file the VM reads
/// again then takes fresh pages: the give-back would make Activity Monitor's
/// number smaller while the Mac holds as much or more. Without it
/// "compressing" never fires and macOS's warning drops the VM's cache as in
/// 3.2.10.
///
/// The app looks every 5 s (GPUMemoryWatch) and asks the VM for its cold
/// file cache (src/memory/guest/giveback.sh: the file cache not used lately,
/// except the newest 1 GB) when macOS is compressing the VM: all three of
/// - what macOS holds of QEMU outside its resident memory (`Sample.taken`,
///   footprint less resident size: compressed pages, and graphics that count
///   in the footprint only) is at least min(2 GB, a quarter of the Mac),
/// - it grew at least min(1 GB, an eighth of the Mac) above its lowest
///   (the baseline: since the VM started, or since 60 s after the last
///   give-back; it only moves down),
/// - macOS itself compressed at least 1 GB since then. macOS counts every
///   process, so graphics that grow the footprint trigger nothing as long as
///   macOS compresses under 1 GB while they grow.
/// One 10-minute gap for every give-back (also macOS's warning, the drop it
/// always did); when the VM's agent does not answer, again in 30 s, then
/// 1, 2, 4 and 8 minutes, then every 10 minutes. A give-back for
/// "compressing" that returned under 256 MB (by the VM's own count; QEMU's
/// footprint 60 s later only when the VM's answer could not be read) doubles
/// the next gap for it (up to 2 h: what macOS compresses then is the VM's
/// own programs' memory); 1 GB or more puts it back to 10 minutes. The
/// warning's drop leaves that gap as it is. macOS's warning may follow a
/// cold-only give-back after 2 minutes. Foundation only: `swift run desktop-tests`.
public struct MemoryGiveBack: Sendable {
    public static let mib: UInt64 = 1 << 20
    public static let gib: UInt64 = 1 << 30
    public static let gap: TimeInterval = 600
    public static let retry: TimeInterval = 30
    /// Free page reporting gives the pages to the Mac within 10-20 s; the
    /// footprint is measured, and the baseline starts again, 60 s after.
    public static let settle: TimeInterval = 60
    public static let escalation: TimeInterval = 120
    public static let longestGap: TimeInterval = 7200
    public static let small = 256 * mib
    public static let large = gib
    /// Near the baseline: macOS's count starts again from there.
    static let near = 64 * mib

    public enum Trigger: String, Sendable { case compressing, warning, critical }

    /// One look at QEMU and macOS. Bytes; time in seconds.
    public struct Sample: Equatable, Sendable {
        public var time: TimeInterval
        /// QEMU's footprint: what Activity Monitor shows for the VM.
        public var footprint: UInt64
        public var resident: UInt64
        /// What macOS compressed since it started (vm_statistics64.compressions
        /// times the page size), every process.
        public var compressed: UInt64
        public init(time: TimeInterval, footprint: UInt64, resident: UInt64, compressed: UInt64) {
            self.time = time
            self.footprint = footprint
            self.resident = resident
            self.compressed = compressed
        }
        public var taken: UInt64 { footprint > resident ? footprint - resident : 0 }
    }

    public let ram: UInt64
    public var minTaken: UInt64 { min(2 * Self.gib, ram / 4) }
    public var minGrowth: UInt64 { min(Self.gib, ram / 8) }
    public static let minCompressed = gib

    public private(set) var baseline: (taken: UInt64, compressed: UInt64)?
    private var baselineFrom: TimeInterval = -.infinity
    public private(set) var last: (time: TimeInterval, trigger: Trigger, coldOnly: Bool)?
    private var previous: (time: TimeInterval, trigger: Trigger, coldOnly: Bool)?
    private var retryAt: TimeInterval?
    /// The VM's agent did not answer this many times in a row (0 once it answers).
    public private(set) var misses = 0
    /// The gap for "compressing" is 10 minutes times this.
    public private(set) var backoff: Double = 1
    /// No more give-backs for "compressing" in this run (the VM's balloon does
    /// not report free pages, or the app has no script). The warning's drop stays.
    public private(set) var off = false
    /// This QEMU gives the pages of a free page report back to macOS
    /// (`qemuGivesPagesBack`). false: "compressing" never fires.
    public var pagesGoBack: Bool

    public init(ram: UInt64, pagesGoBack: Bool = false) {
        self.ram = ram
        self.pagesGoBack = pagesGoBack
    }

    /// The text the reclaim fix puts into QEMU's binary (the worker's first
    /// qemu.log line, qemu-hvf-free-page-reclaim-reusable.patch);
    /// prepare-qemu-gpu-runtime.sh checks that a runtime with the fix has it.
    public static let reclaimMarker = "OmacVM: free page reclaim gives the pages back to macOS"

    /// Whether the QEMU at `binary` gives given-back pages back to macOS: its
    /// binary has `reclaimMarker` and the fix's own switch is not off
    /// (`OMACVM_RECLAIM_REUSABLE=0`; QEMU gets the app's environment). A
    /// binary that cannot be read: no. Tens of MB: call it off the main thread.
    public static func qemuGivesPagesBack(binary: URL, environment: [String: String]) -> Bool {
        if environment["OMACVM_RECLAIM_REUSABLE"] == "0" { return false }
        guard let d = try? Data(contentsOf: binary, options: .alwaysMapped) else { return false }
        let marker = Array(reclaimMarker.utf8)
        return d.withUnsafeBytes { b in
            marker.withUnsafeBytes { m in
                guard let bp = b.baseAddress, let mp = m.baseAddress else { return false }
                return memmem(bp, b.count, mp, m.count) != nil
            }
        }
    }

    /// What the reclaim fix writes into the file OMACVM_RECLAIM_STATUS names
    /// when macOS keeps the pages the VM gives back (a refused madvise, or the
    /// pages still held after the advice): "reclaim=keeps", then "why=...".
    /// It then gives no more pages back this run. Returns the reason
    /// (printable, at most 120 characters), or nil while QEMU said nothing
    /// (no file, another text).
    public static func qemuKeeps(status text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(4)
        guard lines.first == "reclaim=keeps" else { return nil }
        let why = lines.first { $0.hasPrefix("why=") }?.dropFirst(4) ?? ""
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: why.unicodeScalars.lazy.filter { $0.value >= 0x20 && $0.value < 0x7F }.prefix(120))
        let clean = String(scalars)
        return clean.isEmpty ? "no reason given" : clean
    }

    /// QEMU says macOS keeps what the VM gives back: no give-back while macOS
    /// compresses for the rest of the run. The warning's drop stays.
    public mutating func qemuKept() { pagesGoBack = false }

    /// qemu.log's line when QEMU said so (`qemuKeeps`).
    public static func keptLine(_ why: String) -> String {
        "OmacVM: VM memory: give-back while macOS compresses: off for the rest of this run: "
            + "QEMU says macOS keeps the pages the VM gives back (\(why))"
    }

    /// qemu.log's line at each start; omacvm check's "VM memory" row reads
    /// "compresses: on" or "off" from it.
    public static func startLine(pagesGoBack: Bool) -> String {
        "OmacVM: VM memory: give-back while macOS compresses: " + (pagesGoBack
            ? "on (this QEMU gives the pages back to macOS)"
            : "off (this QEMU keeps given-back pages); macOS's memory warning still drops the VM's file cache")
    }

    /// Every look: true when the VM should give back now because macOS is
    /// compressing it. Never with a QEMU that keeps given-back pages.
    public mutating func compressing(_ s: Sample) -> Bool {
        guard pagesGoBack else { return false }
        if s.time >= baselineFrom {
            if let b = baseline, s.taken > b.taken + Self.near {
                // grown: the baseline and macOS's count stay where they were
            } else {
                baseline = (min(s.taken, baseline?.taken ?? s.taken), s.compressed)
            }
        }
        guard !off, let b = baseline else { return false }
        let byMacOS = s.compressed >= b.compressed ? s.compressed - b.compressed : 0
        guard s.taken >= minTaken, s.taken >= b.taken + minGrowth, byMacOS >= Self.minCompressed else { return false }
        return allowed(.compressing, at: s.time)
    }

    /// Whether a give-back for `trigger` may start now.
    public func allowed(_ trigger: Trigger, at t: TimeInterval) -> Bool {
        if trigger == .compressing && !pagesGoBack { return false }
        if let r = retryAt { return t >= r }
        guard let l = last else { return true }
        let since = t - l.time
        switch trigger {
        case .compressing:
            return !off && since >= min(Self.gap * backoff, Self.longestGap)
        case .warning, .critical:
            return since >= Self.gap || (l.coldOnly && since >= Self.escalation)
        }
    }

    /// A give-back starts (counted from now for the gap).
    public mutating func started(_ trigger: Trigger, at t: TimeInterval) {
        previous = last
        last = (t, trigger, trigger == .compressing)
        retryAt = nil
    }

    /// The VM's agent did not answer: as if it had not started. Again in 30 s,
    /// then twice as long each time, at most every 10 minutes (an agent that
    /// is down while macOS compresses the VM is not asked every 30 s).
    public mutating func noAnswer(at t: TimeInterval) {
        last = previous
        misses += 1
        retryAt = t + Self.retryAfter(misses: misses)
    }

    /// The wait after `misses` answers in a row that did not come: 30 s, 1, 2,
    /// 4, 8 minutes, then 10.
    public static func retryAfter(misses: Int) -> TimeInterval {
        min(retry * Double(1 << min(max(misses, 1) - 1, 10)), gap)
    }

    /// The VM answered (nil: no answer that could be read; also the warning's
    /// drop, which has none). It dropped its whole cache when its kernel had
    /// no cold-only way: not cold-only then. Returns how many times in a row
    /// before it had not answered.
    @discardableResult
    public mutating func answered(_ r: Result?) -> Int {
        let missed = misses
        misses = 0
        if r?.act == "drop", let l = last { last = (l.time, l.trigger, false) }
        if r?.act == "norep" { off = true }
        return missed
    }

    /// 60 s after the VM answered: the baseline starts again from now, and for
    /// "compressing" what came back sets the next gap. What the VM says it
    /// gave counts; QEMU's footprint only when its answer could not be read.
    /// The warning's drop (`trigger` warning or critical) leaves the gap as it is.
    public mutating func settled(_ trigger: Trigger, guest: UInt64?, footprintDrop: UInt64, at t: TimeInterval) {
        if trigger == .compressing {
            let back = guest ?? footprintDrop
            if back < Self.small {
                backoff = min(backoff * 2, Self.longestGap / Self.gap)
            } else if back >= Self.large {
                backoff = 1
            }
        }
        baseline = nil
        baselineFrom = t
    }

    /// No give-backs for "compressing" in this run.
    public mutating func stop() { off = true }

    /// The VM's answer (giveback.sh): one line of key=value, sizes in MB. The
    /// VM is untrusted: the last line only, printable characters, at most 200
    /// of them, numbers within 0 and the VM's memory, `act` letters only.
    public struct Result: Equatable, Sendable {
        public var act = ""
        public var wantMB = 0
        public var gotMB = 0
        public var cacheMB = 0
        public var cacheAfterMB = 0
        public var smallFreeMB = 0
        public var totalMB = 0
        public var reporting = false
        public var order = -1
        public var seconds = 0

        public init() {}

        public static func parse(_ text: String, maxMB: Int) -> Result? {
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            guard let lastLine = lines.last(where: { !$0.allSatisfy { $0 == " " } }) else { return nil }
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: lastLine.unicodeScalars.lazy.filter { $0.value >= 0x20 && $0.value < 0x7F }.prefix(200))
            let clean = String(scalars)
            let cap = max(0, maxMB)
            func mb(_ v: String) -> Int { min(max(Int(v) ?? 0, 0), cap) }
            var r = Result()
            var seen = false
            for field in clean.split(separator: " ") {
                let kv = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "act":
                    r.act = String(kv[1].unicodeScalars.filter { $0.value >= 0x61 && $0.value <= 0x7A }.prefix(12).map(Character.init))
                    seen = !r.act.isEmpty
                case "want_mb": r.wantMB = mb(kv[1])
                case "got_mb": r.gotMB = mb(kv[1])
                case "cache_mb": r.cacheMB = mb(kv[1])
                case "cache_after_mb": r.cacheAfterMB = mb(kv[1])
                case "small_free_mb": r.smallFreeMB = mb(kv[1])
                case "total_mb": r.totalMB = mb(kv[1])
                case "reporting": r.reporting = kv[1] == "1"
                case "order": r.order = min(max(Int(kv[1]) ?? -1, -1), 10)
                case "secs": r.seconds = min(max(Int(kv[1]) ?? 0, 0), 600)
                default: break
                }
            }
            return seen ? r : nil
        }
    }

    /// "11.9 GB", "900 MB" (bytes).
    public static func gb(_ bytes: UInt64) -> String {
        let mb = bytes / mib
        return mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(bytes) / Double(gib))
    }

    /// logs/memory-giveback: the last give-back of this run, for omacvm check.
    /// key=value lines; the app writes it whole at each give-back and removes
    /// it when the VM starts.
    public struct Status: Equatable, Sendable {
        public var count = 0
        public var at = 0               // when, seconds since 1970
        public var trigger = ""         // compressing, warning, critical, off
        public var act = ""             // the VM's answer (giveback.sh), or "drop" for the warning
        public var givenMB: Int?        // what the VM said it gave; nil for the warning's drop
        public var returnedMB = 0       // QEMU's footprint, 60 s later, less than before
        public var cacheMB = 0
        public var cacheAfterMB = 0
        public var smallFreeMB = 0
        public var footprintMB = 0
        public var footprintAfterMB = 0
        public var takenMB = 0
        public var backoff = 1
        public var off = false
        /// QEMU said macOS keeps the pages the VM gives back (`qemuKeeps`).
        public var kept = false

        public init() {}

        public var text: String {
            """
            count=\(count)
            at=\(at)
            trigger=\(trigger)
            act=\(act)
            given_mb=\(givenMB.map(String.init) ?? "")
            returned_mb=\(returnedMB)
            cache_mb=\(cacheMB)
            cache_after_mb=\(cacheAfterMB)
            small_free_mb=\(smallFreeMB)
            footprint_mb=\(footprintMB)
            footprint_after_mb=\(footprintAfterMB)
            taken_mb=\(takenMB)
            backoff=\(backoff)
            off=\(off ? 1 : 0)
            kept=\(kept ? 1 : 0)

            """
        }
    }
}
