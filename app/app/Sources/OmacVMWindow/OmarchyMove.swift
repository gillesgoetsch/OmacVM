import Darwin
import Foundation

/// "Move to Omarchy 4.5" in the VM window: the rules, apart from the UI so
/// `swift run window-tests` checks them.
///
/// app/scripts/move-vm.sh does the move (the VM off): it checks the Mac,
/// clones disk.img and the small records into the VM folder's
/// `before-omarchy-4.5/` (APFS clonefile: the copy shares every block until
/// one changes), starts the VM without a window, updates OmacVM in it, runs
/// the guest's omarchy-move.sh (work/v340/contract.md), updates OmacVM again,
/// restarts and checks the VM, and shuts it down. Its journal is the VM
/// folder's `move-4.5` file (`Journal`), so a quit, a crash or a power cut
/// leaves a state the window can offer Resume or Undo for. Undo puts the
/// backup's disk back; Delete removes the backup, only on the person's click.
public enum OmarchyMove {
    /// In the VM folder: the journal, the backup, the Omarchy record.
    public static let journalName = "move-4.5"
    public static let backupName = "before-omarchy-4.5"
    public static let recordName = "omarchy"
    /// Room for the packages the move downloads (D1), on top of the disk's
    /// allocated bytes and the reserve the disk size keeps (DiskSize.macReserve).
    public static let downloadRoom: Int64 = 4 * DiskSize.gib

    /// The steps, as move-vm.sh numbers them (STEP n/8) and the panel lists them.
    public static let steps = [
        "Check this Mac",
        "Shut down the VM",
        "Back up the disk",
        "Update OmacVM in the VM",
        "Switch Omarchy's packages",
        "Update OmacVM again",
        "Restart and check",
        "Shut down",
    ]

    // MARK: The journal (VM_DIR/move-4.5)

    public enum State: String, Equatable {
        case running, failed, interrupted, done, undone, kept
        /// The backup was deleted: the move is over for good.
        case final = "done-final"
    }

    /// key=value lines, `format=1`. Unknown keys are kept (a newer app may add
    /// some), a newer format is read as far as these keys go.
    public struct Journal: Equatable {
        public var format = 1
        public var state: State = .running
        public var step = 0
        public var pid: Int32 = 0
        public var started = ""
        public var finished = ""
        public var failedStep = 0
        public var reason = ""
        public var code = ""
        public var resumable = true
        public var commitStarted = false
        public var fromOmacVM = ""
        public var fromDiskGB = 0
        public var backupAt = ""
        public var other: [(String, String)] = []

        public init() {}

        public static func parse(_ text: String) -> Journal? {
            var j = Journal(), sawState = false
            for raw in text.split(whereSeparator: \.isNewline) {
                guard let eq = raw.firstIndex(of: "=") else { continue }
                let k = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                switch k {
                case "format": j.format = Int(v) ?? 1
                case "state":
                    guard let s = State(rawValue: v) else { return nil }
                    j.state = s; sawState = true
                case "step": j.step = Int(v) ?? 0
                case "pid": j.pid = Int32(v) ?? 0
                case "started": j.started = v
                case "finished": j.finished = v
                case "failed_step": j.failedStep = Int(v) ?? 0
                case "reason": j.reason = v
                case "code": j.code = v
                case "resumable": j.resumable = v == "1"
                case "commit_started": j.commitStarted = v == "1"
                case "from_omacvm": j.fromOmacVM = v
                case "from_disk_gb": j.fromDiskGB = Int(v) ?? 0
                case "backup_at": j.backupAt = v
                default: j.other.append((k, v))
                }
            }
            return sawState ? j : nil
        }

        public var text: String {
            var lines = ["format=\(format)", "state=\(state.rawValue)", "step=\(step)", "pid=\(pid)",
                         "started=\(started)", "finished=\(finished)", "failed_step=\(failedStep)",
                         "reason=\(reason.replacingOccurrences(of: "\n", with: " "))", "code=\(code)",
                         "resumable=\(resumable ? 1 : 0)", "commit_started=\(commitStarted ? 1 : 0)",
                         "from_omacvm=\(fromOmacVM)", "from_disk_gb=\(fromDiskGB)", "backup_at=\(backupAt)"]
            lines += other.map { "\($0.0)=\($0.1)" }
            return lines.joined(separator: "\n") + "\n"
        }

        public static func == (a: Journal, b: Journal) -> Bool { a.text == b.text }

        /// Not over yet: Start, Update VM and disk changes wait for Resume or Undo.
        public var open: Bool { state == .running || state == .failed || state == .interrupted }

        /// A key move-vm.sh keeps beside the known ones (the last one wins).
        public func value(_ key: String) -> String? { other.last { $0.0 == key }?.1 }

        /// The move's QEMU (its VM runs without a window), while it runs.
        public var qemuPid: Int32 { Int32(value("qemu_pid") ?? "") ?? 0 }
        /// move-vm.sh settle, while it shuts down a VM a killed move left running.
        public var settlePid: Int32 { Int32(value("settle_pid") ?? "") ?? 0 }
        /// kern.boottime's seconds when the pids were written ("" in older journals).
        public var boot: String { value("boot") ?? "" }
        /// The VM stopped while the Mac's last word from its guest was "inside
        /// the package switch": not known yet whether the move can go on.
        /// Resume boots the VM and asks it first (move-vm.sh, step 4).
        public var askGuest: Bool { value("ask_guest") == "1" }
    }

    // MARK: The Omarchy record (VM_DIR/omarchy, written by apply)

    /// `<version> <lane> <channel>` from the guest's `omarchy-move.sh record`,
    /// e.g. "4.5.0 aarch64 stable", "4.0.3rc4 omarchy-mac rc", or "none".
    public struct Record: Equatable {
        public var version: String
        public var lane: String
        public var channel: String

        public init(version: String, lane: String, channel: String) {
            self.version = version; self.lane = lane; self.channel = channel
        }

        public static func parse(_ text: String) -> Record? {
            let f = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let v = f.first, v != "none", v.count <= 40,
                  v.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+".contains($0)) }) else { return nil }
            return Record(version: v, lane: f.count > 1 ? f[1] : "", channel: f.count > 2 ? f[2] : "")
        }

        /// Omarchy 4.5 or newer (5.x too).
        public var isMoved: Bool {
            let n = version.split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
            guard let major = n.first else { return false }
            return major > 4 || (major == 4 && (n.count > 1 ? n[1] : 0) >= 5)
        }
    }

    // MARK: What the card shows

    public enum Card: Equatable {
        case hidden
        /// The offer (the Mac's checks decide whether its button is on: `problem`).
        case offer
        case running(step: Int)
        /// The move's VM shuts down at a safe point: after a Stop and Quit, or
        /// left running by a move whose script is gone (an app crash; settle).
        /// Resume and Undo come once it is off.
        case stopping(step: Int)
        case failed(step: Int, reason: String, resumable: Bool)
        case interrupted(step: Int, reason: String, resumable: Bool)
        /// Moved (or kept after a stop); the backup is still there.
        case done(since: String, kept: Bool)
    }

    /// recordText: the `omarchy` file (nil: none yet, every VM before
    /// 3.4.0's first Update VM: shown, the guest's preflight decides, D4).
    /// alive: the journal's pid still runs (a move in another window).
    /// stopping: its VM shuts down at a safe point (`stopping(...)`).
    public static func card(recordText: String?, journal: Journal?, backupExists: Bool, alive: Bool,
                            stopping: Bool = false) -> Card {
        if let j = journal {
            if j.open && stopping { return .stopping(step: max(j.step, 1)) }
            switch j.state {
            case .running:
                if alive { return .running(step: j.step) }
                return .interrupted(step: j.step, reason: j.reason, resumable: resumableAfterStop(j))
            case .failed:
                return .failed(step: j.failedStep > 0 ? j.failedStep : j.step, reason: j.reason, resumable: j.resumable || j.askGuest)
            case .interrupted:
                return .interrupted(step: j.step, reason: j.reason, resumable: resumableAfterStop(j))
            case .done, .kept:
                // The backup gone by hand: nothing left to undo or delete.
                if backupExists { return .done(since: j.finished, kept: j.state == .kept) }
                return .hidden
            case .final:
                return .hidden
            case .undone:
                break
            }
        }
        guard let t = recordText else { return .offer }
        guard let r = Record.parse(t) else { return .hidden }   // "none": no Omarchy package
        return r.isMoved ? .hidden : .offer
    }

    /// The move's VM is on its way down: the script runs and was asked to
    /// stop (Stop and Quit, or the app gone: move-vm.sh asks itself), or
    /// settle shuts down a VM a killed script left running.
    public static func stopping(_ j: Journal, scriptAlive: Bool, stopAsked: Bool, settleAlive: Bool) -> Bool {
        j.open && ((scriptAlive && stopAsked) || settleAlive)
    }

    /// A move whose script is gone (an app crash, a logout) while its QEMU
    /// runs on without a window: the window has it shut down (move-vm.sh
    /// settle) before it offers Resume or Undo. Never while a settle runs.
    public static func needsSettle(_ j: Journal, scriptAlive: Bool, qemuAlive: Bool, settleAlive: Bool) -> Bool {
        j.open && !scriptAlive && qemuAlive && !settleAlive
    }

    /// A move that stopped: it goes on unless the guest's package switch had
    /// started and the guest itself said it cannot (a half transaction is
    /// not resumed). Without the guest's last word (the Mac lost power, the
    /// app was killed: the journal still says running; or ask_guest) Resume
    /// is offered: it boots the VM and asks the guest before anything else.
    static func resumableAfterStop(_ j: Journal) -> Bool {
        !j.commitStarted || j.resumable || j.askGuest || j.state == .running
    }

    // MARK: The Mac's checks (step 1)

    /// What the Mac needs free: the disk's allocated bytes (the backup shares
    /// them, but the move rewrites most of the system: worst case, D1), the
    /// reserve the disk keeps, and the downloads.
    public static func need(allocated: Int64) -> Int64 { allocated + DiskSize.macReserve + downloadRoom }

    /// Why the move cannot start now, with its fix; nil: it can.
    /// apfs: the VMs folder's volume makes clones (nil: unknown, treated as yes).
    public static func problem(apfs: Bool?, freeBytes: Int64?, allocated: Int64, diskJobPending: Bool,
                               resizePending: Bool, otherCopy: String?) -> String? {
        if let o = otherCopy { return o }
        if apfs == false {
            return "The backup needs the VM on a Mac-formatted (APFS) drive. Move the VM in Storage & Updates first."
        }
        if resizePending { return "A change of the disk's size is not finished. Start the VM once (or go back) first." }
        if diskJobPending { return "Omarchy grows into the disk's new size at the next start. Start the VM once first." }
        let n = need(allocated: allocated)
        if let f = freeBytes, f < n {
            return "Not enough free space: the move needs \(DiskSize.text(n)) free on this drive, it has \(DiskSize.text(f))."
        }
        return nil
    }

    // MARK: Sizes

    /// The bytes only this file holds: an APFS clone shares its blocks with
    /// the file it came from until either changes (ATTR_CMNEXT_PRIVATESIZE).
    /// Deleting it frees this much (checked on the Mac mini: 300 MiB rewritten
    /// in a 1 GiB clone pair, private 314572800 on both, rm freed 307068 KB).
    /// nil where the volume does not say.
    public static func privateBytes(_ path: String) -> Int64? {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buf = [UInt8](repeating: 0, count: 16)
        let r = buf.withUnsafeMutableBytes { getattrlist(path, &al, $0.baseAddress, 16, UInt32(FSOPT_ATTR_CMN_EXTENDED)) }
        guard r == 0 else { return nil }
        let len = buf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard len >= 12 else { return nil }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    /// What deleting the backup folder frees: each file's private bytes
    /// (its allocated size where the volume does not say). exact false: a
    /// file without that answer was counted at its allocated size ("up to").
    public static func backupBytes(_ folder: URL) -> (bytes: Int64, exact: Bool)? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        var total: Int64 = 0, exact = true
        for n in names {
            let p = folder.appendingPathComponent(n).path
            if let b = privateBytes(p) {
                total += b
            } else {
                let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? 0)
                exact = false
            }
        }
        return (total, exact)
    }

    /// "about 12 GB", "up to 30 GB"; below 50 MB: "less than 50 MB".
    public static func sizeText(_ b: (bytes: Int64, exact: Bool)) -> String {
        if b.bytes < 50 << 20 { return "less than 50 MB" }
        return (b.exact ? "about " : "up to ") + DiskSize.text(b.bytes)
    }

    // MARK: Words

    /// "6 November 2026" from the journal's ISO time; "" when unreadable.
    public static func dateText(_ iso: String, locale: Locale = .current) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return "" }
        let out = DateFormatter()
        out.locale = locale
        out.dateStyle = .long
        out.timeStyle = .none
        return out.string(from: d)
    }

    public static func stepTitle(_ n: Int) -> String {
        (1...steps.count).contains(n) ? steps[n - 1] : "Preparing"
    }
}
