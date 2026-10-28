import Foundation

/// When the VM gives its cold file cache back to the Mac (ADR 0059).
///
/// Linux keeps every file it read in its page cache. In a VM that is memory
/// the Mac backs but cannot drop: to macOS it is the VM's own memory, so
/// macOS compresses it and the Mac slows down, while its own file cache
/// already holds the same files (QEMU reads the disk image through it).
/// macOS's memory pressure stays "normal" while it compresses (it counts
/// every page it can still compress as available), so the warning that
/// drops the VM's cache (since 2.9) came too late or never.
///
/// The app looks every 5 s (GPUMemoryWatch) and asks the VM for its cold
/// file cache (src/memory/guest/giveback.sh) when macOS is compressing the
/// VM: all three of
/// - what macOS holds of QEMU outside its resident memory (`Sample.taken`,
///   footprint less resident size: compressed pages, and graphics that count
///   in the footprint only) is at least min(2 GB, a quarter of the Mac),
/// - it grew at least min(1 GB, an eighth of the Mac) above its lowest
///   (the baseline: since the VM started, or since 60 s after the last
///   give-back; it only moves down),
/// - macOS itself compressed at least 1 GB since then (graphics that grow
///   on a Mac with room do not count).
/// One 10-minute gap for every give-back (also macOS's warning, the drop it
/// always did); 30 s when the VM's agent did not answer. A give-back for
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
    /// The gap for "compressing" is 10 minutes times this.
    public private(set) var backoff: Double = 1
    /// No more give-backs for "compressing" in this run (the VM's balloon does
    /// not report free pages, or the app has no script). The warning's drop stays.
    public private(set) var off = false

    public init(ram: UInt64) { self.ram = ram }

    /// Every look: true when the VM should give back now because macOS is
    /// compressing it.
    public mutating func compressing(_ s: Sample) -> Bool {
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

    /// The VM's agent did not answer: as if it had not started; again in 30 s.
    public mutating func noAnswer(at t: TimeInterval) {
        last = previous
        retryAt = t + Self.retry
    }

    /// The VM answered (nil: no answer that could be read). It dropped its
    /// whole cache when its kernel had no cold-only way: not cold-only then.
    public mutating func answered(_ r: Result?) {
        if r?.act == "drop", let l = last { last = (l.time, l.trigger, false) }
        if r?.act == "norep" { off = true }
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

            """
        }
    }
}
