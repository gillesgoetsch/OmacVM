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
/// cold-only give-back after 2 minutes.
///
/// When the VM is quiet (`idle`): every 15 minutes while macOS's pressure is
/// normal, QEMU used at most a fifth of a core over the last minute, QEMU has
/// under min(2 GB, a quarter of the Mac) outside its resident memory (what
/// macOS compressed of it, and graphics) and no give-back ran in the last 10
/// minutes, the VM gives back its cold file cache above the newest min(2 GB,
/// a quarter of the VM) and compacts its free memory (giveback.sh idle).
/// It counts as cold-only (the warning may follow after 2 minutes); an idle
/// step the agent did not answer is tried again 15 minutes later, never
/// sooner, and never delays the warning's drop. One that brought back under
/// 256 MB, or after which the VM read back half of what the last one gave
/// (its refaults), doubles the gap, up to 2 hours; 1 GB or more puts it back
/// to 15 minutes. After the warning's drop, once the pressure is normal
/// again and the VM is quiet, one compaction-only call (giveback.sh
/// compact): compaction moves pages in use, so never while macOS is short of
/// memory or the VM busy.
/// Foundation only: `swift run desktop-tests`.
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
    /// The idle give-back: every 15 minutes at most (times `idleBackoff`).
    public static let idleGap: TimeInterval = 900
    /// Quiet: QEMU used at most this much of one core over the last minute
    /// (all its threads: the vCPUs, graphics, disk, display). Idle VMs used
    /// 4-10 % (a hidden 4 GB VM on the M1 Max: 9.5 %), a video 31-60 %.
    public static let quietCPU = 0.20
    public static let quietWindow: TimeInterval = 60

    public enum Trigger: String, Sendable { case compressing, warning, critical, idle }

    /// One look at QEMU and macOS. Bytes; time in seconds.
    public struct Sample: Equatable, Sendable {
        public var time: TimeInterval
        /// QEMU's footprint: what Activity Monitor shows for the VM.
        public var footprint: UInt64
        public var resident: UInt64
        /// What macOS compressed since it started (vm_statistics64.compressions
        /// times the page size), every process.
        public var compressed: UInt64
        /// QEMU's CPU time since it started (all threads), nanoseconds.
        public var cpu: UInt64
        /// macOS's memory pressure is normal (not warn or critical).
        public var normal: Bool
        public init(time: TimeInterval, footprint: UInt64, resident: UInt64, compressed: UInt64,
                    cpu: UInt64 = 0, normal: Bool = true) {
            self.time = time
            self.footprint = footprint
            self.resident = resident
            self.compressed = compressed
            self.cpu = cpu
            self.normal = normal
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
    /// (`qemuGivesPagesBack`). false: "compressing" and "idle" never fire.
    public var pagesGoBack: Bool
    /// The idle give-back is on (OMACVM_GIVEBACK_IDLE=0 turns it off, for tests).
    public var idleOn: Bool
    /// The gap for "idle" is 15 minutes times this.
    public private(set) var idleBackoff: Double = 1
    /// The idle agent did not answer this many times in a row.
    public private(set) var idleMisses = 0
    private var idleNext: TimeInterval?
    /// The VM's refaults (MB, since it started) and what it gave at the last idle step.
    private var idleRefault: (rf: Int, got: Int)?
    /// QEMU's CPU time over the last minute (`seen`).
    private var cpuSeen: [(time: TimeInterval, cpu: UInt64)] = []
    /// The compaction-only call after the warning's drop is due (`compactAfterDrop`).
    public private(set) var compactDue = false

    public init(ram: UInt64, pagesGoBack: Bool = false, idle: Bool = true) {
        self.ram = ram
        self.pagesGoBack = pagesGoBack
        self.idleOn = idle
    }

    /// OMACVM_GIVEBACK_IDLE=0 turns the idle give-back off (tests that measure without it).
    public static func idleOn(environment: [String: String]) -> Bool {
        environment["OMACVM_GIVEBACK_IDLE"] != "0"
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

    /// qemu.log's line about the idle give-back, once its QEMU is known.
    public static func idleLine(on: Bool, pagesGoBack: Bool) -> String {
        "OmacVM: VM memory: idle give-back: " + (!on ? "off (OMACVM_GIVEBACK_IDLE=0)"
            : pagesGoBack ? "on (at most every 15 minutes while the VM is quiet and macOS's pressure normal)"
            : "off (this QEMU keeps given-back pages)")
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

    /// Every look, before `compressing` and `idle`, also while a give-back
    /// runs: QEMU's CPU time, for "quiet".
    public mutating func seen(_ s: Sample) {
        cpuSeen.append((s.time, s.cpu))
        while cpuSeen.count > 1 && s.time - cpuSeen[1].time >= Self.quietWindow { cpuSeen.removeFirst() }
        if idleNext == nil { idleNext = s.time + Self.idleGap }
    }

    /// QEMU used at most `quietCPU` of a core over the last minute (a whole
    /// minute of looks; CPU time that went back counts as busy).
    public var quiet: Bool {
        guard let first = cpuSeen.first, let last = cpuSeen.last, last.time - first.time >= Self.quietWindow,
              last.cpu >= first.cpu else { return false }
        return Double(last.cpu - first.cpu) / 1e9 <= Self.quietCPU * (last.time - first.time)
    }

    /// The compressing rule's first part holds: QEMU has at least `minTaken`
    /// outside its resident memory (what macOS compressed of it, and graphics).
    /// No idle give-back then: it compacts, and moving pages makes macOS
    /// decompress them; and the give-back while macOS compresses has its own
    /// back-off. Graphics count too: a 5K desktop with a browser open on a
    /// small Mac waits until the browser closes.
    public func compressingHolds(_ s: Sample) -> Bool { s.taken >= minTaken }

    /// Every look after `compressing` said no: true when the VM should give
    /// back now because it is quiet (`seen` first).
    public func idle(_ s: Sample) -> Bool {
        guard idleOn, pagesGoBack, !off, s.normal, quiet, !compressingHolds(s),
              let n = idleNext, s.time >= n else { return false }
        return allowed(.idle, at: s.time)
    }

    /// Whether a give-back for `trigger` may start now. A retry of
    /// "compressing" or the warning that is due goes before "idle".
    public func allowed(_ trigger: Trigger, at t: TimeInterval) -> Bool {
        if (trigger == .compressing || trigger == .idle) && !pagesGoBack { return false }
        if trigger == .idle && !idleOn { return false }
        if let r = retryAt { return trigger != .idle && t >= r }
        guard let l = last else { return true }
        let since = t - l.time
        switch trigger {
        case .compressing:
            return !off && since >= min(Self.gap * backoff, Self.longestGap)
        case .idle:
            return !off && since >= Self.gap
        case .warning, .critical:
            return since >= Self.gap || (l.coldOnly && since >= Self.escalation)
        }
    }

    /// A give-back starts (counted from now for the gap). "compressing" and
    /// "idle" take cold cache only.
    public mutating func started(_ trigger: Trigger, at t: TimeInterval) {
        previous = last
        last = (t, trigger, trigger == .compressing || trigger == .idle)
        retryAt = nil
        if trigger == .idle { compactDue = false }
    }

    /// The VM's agent did not answer an idle give-back: as if it had not
    /// started, and again in 15 minutes (never sooner: no `retryAt`, so the
    /// warning's drop is not held up).
    public mutating func idleNoAnswer(at t: TimeInterval) {
        last = previous
        idleMisses += 1
        idleNext = t + Self.idleGap
    }

    /// The VM answered an idle give-back (nil: no answer that could be read;
    /// it may have run, so it counts). busy or locked: nothing ran, again in
    /// 15 minutes. Otherwise what it brought back (cache and compacted
    /// memory, by the VM's own count) and its refaults set the next gap.
    /// Returns how many times in a row before it had not answered.
    @discardableResult
    public mutating func idleAnswered(_ r: Result?, at t: TimeInterval) -> Int {
        let missed = idleMisses
        idleMisses = 0
        guard let r else {
            idleNext = t + min(Self.idleGap * idleBackoff, Self.longestGap)
            return missed
        }
        switch r.act {
        case "norep":
            off = true
        case "busy", "locked":
            last = previous
            idleNext = t + Self.idleGap
        default:
            let back = r.gotMB + r.compactedMB
            var longer = back < Int(Self.small / Self.mib)
            if let p = idleRefault, let rf = r.refaultMB, p.got > 0, rf >= p.rf, rf - p.rf >= p.got / 2 { longer = true }
            if longer {
                idleBackoff = min(idleBackoff * 2, Self.longestGap / Self.idleGap)
            } else if back >= Int(Self.large / Self.mib) {
                idleBackoff = 1
            }
            if let rf = r.refaultMB { idleRefault = (rf, r.gotMB) }
            idleNext = t + min(Self.idleGap * idleBackoff, Self.longestGap)
        }
        return missed
    }

    /// The warning's drop was done: one compaction-only call is due once the
    /// pressure is normal again (only where given-back pages reach the Mac).
    public mutating func dropped() {
        if pagesGoBack && !off { compactDue = true }
    }

    /// Every look: true once, when the compaction-only call after the
    /// warning's drop should go now: macOS's pressure normal again and the VM
    /// quiet (compaction moves pages in use: on the M1 Max with a video
    /// playing, the VM's waits of 10 ms or more went from 12 to about 50 in
    /// 150 s). An idle give-back before then compacts too.
    public mutating func compactAfterDrop(_ s: Sample) -> Bool {
        guard compactDue, s.normal, quiet else { return false }
        compactDue = false
        return true
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
    /// The warning's drop (`trigger` warning or critical) and "idle" (its own
    /// gap: `idleAnswered`) leave that gap as it is.
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
    /// of them, numbers within 0 and the VM's memory (refaults: 0 to 2^31),
    /// `act` and `compaction` letters only.
    public struct Result: Equatable, Sendable {
        public var act = ""
        public var wantMB = 0
        public var gotMB = 0
        public var cacheMB = 0
        public var cacheAfterMB = 0
        /// Free memory in blocks too small for free page reporting, before
        /// and after the compaction step.
        public var smallFreeMB = 0
        public var smallAfterMB = 0
        /// The compaction step: ran, cap (stopped at its time cap), or why it
        /// did not run (small, busy, nopsi, no, time, fail, skip).
        public var compaction = ""
        public var compactionMS = 0
        /// File pages the VM read again after it had let them go, since it started (MB).
        public var refaultMB: Int?
        public var reporting = false
        public var order = -1
        public var seconds = 0

        public init() {}

        /// What the compaction step made reportable: the small free blocks it joined.
        public var compactedMB: Int {
            compaction == "ran" || compaction == "cap" ? max(0, smallFreeMB - smallAfterMB) : 0
        }

        public static func parse(_ text: String, maxMB: Int) -> Result? {
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            guard let lastLine = lines.last(where: { !$0.allSatisfy { $0 == " " } }) else { return nil }
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: lastLine.unicodeScalars.lazy.filter { $0.value >= 0x20 && $0.value < 0x7F }.prefix(200))
            let clean = String(scalars)
            let cap = max(0, maxMB)
            func mb(_ v: String) -> Int { min(max(Int(v) ?? 0, 0), cap) }
            func letters(_ v: String) -> String {
                String(v.unicodeScalars.filter { $0.value >= 0x61 && $0.value <= 0x7A }.prefix(12).map(Character.init))
            }
            var r = Result()
            var seen = false
            for field in clean.split(separator: " ") {
                let kv = field.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "act":
                    r.act = letters(kv[1])
                    seen = !r.act.isEmpty
                case "want": r.wantMB = mb(kv[1])
                case "got": r.gotMB = mb(kv[1])
                case "cache": r.cacheMB = mb(kv[1])
                case "cache_to": r.cacheAfterMB = mb(kv[1])
                case "small": r.smallFreeMB = mb(kv[1])
                case "small_to": r.smallAfterMB = mb(kv[1])
                case "cpt": r.compaction = letters(kv[1])
                case "cpt_ms": r.compactionMS = min(max(Int(kv[1]) ?? 0, 0), 600_000)
                case "rf": r.refaultMB = Int(kv[1]).map { min(max($0, 0), Int(Int32.max)) }
                case "rep": r.reporting = kv[1] == "1"
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

    /// qemu.log's words for the compaction step of an answer.
    public static func compactionWords(_ r: Result) -> String {
        func g(_ mb: Int) -> String { gb(UInt64(max(mb, 0)) * mib) }
        let secs = String(format: "%.1f s", Double(r.compactionMS) / 1000)
        switch r.compaction {
        case "ran", "cap":
            return "compacted its free memory: \(g(r.smallFreeMB)) -> \(g(r.smallAfterMB)) in blocks too small to give back ("
                + secs + (r.compaction == "cap" ? ", stopped at its time cap)" : ")")
        case "small": return "\(g(r.smallFreeMB)) free in blocks too small to give back"
        case "busy": return "no compaction (the VM was waiting for memory)"
        case "nopsi": return "no compaction (its kernel has no memory pressure numbers)"
        case "no": return "no compaction (its kernel or tools cannot)"
        case "time": return "no compaction (no time left)"
        case "fail": return "no compaction (its kernel refused)"
        default: return "\(g(r.smallFreeMB)) free in blocks too small to give back"
        }
    }

    /// logs/memory-giveback: the last give-back of this run, for omacvm check.
    /// key=value lines; the app writes it whole at each give-back and removes
    /// it when the VM starts.
    public struct Status: Equatable, Sendable {
        public var count = 0
        public var at = 0               // when, seconds since 1970
        public var trigger = ""         // compressing, warning, critical, off (never idle: its own lines)
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
        /// Idle give-backs this run (not in `count`), what they brought back
        /// by the VM's own count (cache and compacted memory), the last one.
        public var idle = 0
        public var idleMB = 0
        public var idleAt = 0

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
            idle=\(idle)
            idle_mb=\(idleMB)
            idle_at=\(idleAt)

            """
        }
    }
}
