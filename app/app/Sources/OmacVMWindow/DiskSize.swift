import Foundation

/// The VM's disk in the window: its size (disk.img, a sparse raw file), what
/// it takes on the Mac, and Change… (a slider for the size).
///
/// Larger (VM off): disk.img gets longer, vm.env's DISK_GB follows, and at
/// the VM's next start the app has the guest grow the root partition and its
/// file system to the new end (`growScript`, the same steps as the prebuilt
/// VM's first boot), through the guest agent.
///
/// Smaller (VM off): the smallest size comes from what btrfs holds (`Need`,
/// read from the guest or from disk.img's superblock). The app keeps an APFS
/// clone of disk.img, starts the VM, has the guest shrink btrfs
/// (`shrinkScript`), shuts it down, writes the smaller partition table and
/// cuts disk.img (DiskImage.cut), starts it again and checks the file system
/// (`checkScript`). The clone goes once the check passes; until then the
/// disk can go back to it. Each step is in the VM folder's disk-resize file
/// (`Resize`).
///
/// Space Omarchy frees goes back to the Mac by itself: btrfs mounts with
/// discard=async, fstrim.timer runs weekly, and QEMU punches the freed
/// blocks out of disk.img (discard=unmap; docs/adr/0039).
public enum DiskSize {
    public static let gib: Int64 = 1 << 30
    /// The largest disk the window offers (4 TB).
    public static let maxGB = 4096

    /// Sizes for the Mac's text: "64 GB", "1.5 GB", "320 MB".
    public static func text(_ bytes: Int64) -> String {
        let gb = Double(bytes) / Double(gib)
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(max(0, Int((Double(bytes) / 1_048_576).rounded()))) MB"
    }

    // MARK: The size slider

    /// disk.img's length in whole GB (nearest).
    public static func wholeGB(_ bytes: Int64) -> Int { Int((bytes + gib / 2) / gib) }

    /// The smallest disk OmacVM makes: the prebuilt image's and the setup's.
    public static let floorGB = 64
    /// What the Mac keeps free should the disk fill up (the slider's top).
    public static let macReserve: Int64 = 10 * gib

    /// What Omarchy's file system holds: from the guest while the VM runs
    /// (`usageScript`), else from disk.img's superblock (DiskImage).
    public struct Need: Equatable {
        /// btrfs chunks on the disk: data, metadata (twice), system.
        public var allocated: Int64
        /// What files and metadata use (the line under the slider).
        public var used: Int64
        /// Where the root partition starts (the EFI partition is before it).
        public var rootStart: Int64
        public init(allocated: Int64, used: Int64, rootStart: Int64) {
            self.allocated = allocated; self.used = used; self.rootStart = rootStart
        }
    }

    /// Room btrfs keeps on top of what it holds: 10 %, 5 GB at least.
    public static func margin(_ allocated: Int64) -> Int64 { max(allocated / 10, 5 * gib) }

    /// The least btrfs may be shrunk to.
    public static func fsNeed(_ n: Need) -> Int64 { n.allocated + margin(n.allocated) }

    /// The slider's ends and one plain line on why the bottom is where it is.
    public struct Bounds: Equatable {
        public var minGB: Int
        public var maxGB: Int
        public var why: String
        public init(minGB: Int, maxGB: Int, why: String) { self.minGB = minGB; self.maxGB = maxGB; self.why = why }
    }

    /// Bottom: what btrfs needs (`fsNeed`) after the partitions before it,
    /// rounded up to a whole GB, never below `floorGB` nor above the disk's
    /// size now. No `need` (unknown): only larger. Top: the Mac's free space
    /// on the VMs folder's drive plus the size now, less `macReserve`.
    public static func bounds(currentGB: Int, need: Need?, unknownWhy: String = "", freeBytes: Int64?) -> Bounds {
        var top = maxGB
        if let free = freeBytes { top = min(maxGB, currentGB + Int(max(0, free - macReserve) / gib)) }
        top = max(top, currentGB)
        guard let n = need else {
            return Bounds(minGB: currentGB, maxGB: top, why: "Only larger for now: \(unknownWhy)")
        }
        // The partition table's backup and MiB rounding take under 2 MiB at the end.
        let bytes = n.rootStart + fsNeed(n) + 2 * (1 << 20)
        let needGB = Int((bytes + gib - 1) / gib)
        let uses = "Omarchy uses \(text(n.used))"
        if currentGB <= floorGB {
            return Bounds(minGB: currentGB, maxGB: top, why: "Only larger: \(floorGB) GB is the smallest disk. \(uses).")
        }
        if needGB > currentGB {
            return Bounds(minGB: currentGB, maxGB: top, why: "Only larger: \(uses) and needs \(needGB) GB with room to spare.")
        }
        if needGB <= floorGB {
            return Bounds(minGB: floorGB, maxGB: top, why: "At least \(floorGB) GB, the smallest disk. \(uses).")
        }
        return Bounds(minGB: needGB, maxGB: top,
                      why: "At least \(needGB) GB: \(uses), plus its metadata and \(text(margin(n.allocated))) spare.")
    }

    /// A slider position as a whole GB inside the bounds.
    public static func snap(_ value: Double, _ b: Bounds) -> Int {
        guard value.isFinite else { return b.minGB }
        return min(b.maxGB, max(b.minGB, Int(value.rounded())))
    }

    /// The number field: "96", "96 GB", "96gb", "96.4" (rounded); nil when it is no size.
    public static func parseGB(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("gb") { t = String(t.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        guard let v = Double(t.replacingOccurrences(of: ",", with: ".")), v.isFinite, v >= 0, v < 1_000_000 else { return nil }
        return Int(v.rounded())
    }

    /// Why Apply cannot make the disk `newGB`, or nil.
    public static func changeProblem(currentGB: Int, newGB: Int, bounds b: Bounds, vmRunning: Bool) -> String? {
        if vmRunning { return "Shut the VM down first." }
        if newGB < b.minGB { return "\(b.minGB) GB at least." }
        if newGB > b.maxGB { return "\(b.maxGB) GB at most: the Mac keeps \(text(macReserve)) free." }
        return nil
    }

    // MARK: Jobs for the VM's next start

    /// compact: from 3.0.1-3.0.4's Compact button (an fstrim); still run
    /// when a VM folder has it.
    public enum Job: String, CaseIterable {
        case grow, compact
    }

    /// The file `disk-jobs` in the VM folder: one job per line.
    public static func parseJobs(_ text: String) -> [Job] {
        var out: [Job] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let j = Job(rawValue: line.trimmingCharacters(in: .whitespaces)), !out.contains(j) { out.append(j) }
        }
        return Job.allCases.filter(out.contains)   // grow before compact
    }

    public static func jobsText(_ jobs: [Job]) -> String {
        Job.allCases.filter(jobs.contains).map { $0.rawValue + "\n" }.joined()
    }

    /// Run as root in the guest (/bin/sh -c) by the guest agent. Grows the
    /// root partition to the disk's end, then its file system; prints
    /// "fs=BYTES disk=BYTES" for `grew`.
    public static let growScript = """
        part=$(findmnt -no SOURCE / | sed 's/\\[.*//')
        fs=$(findmnt -no FSTYPE /)
        disk=/dev/$(lsblk -no PKNAME "$part" | head -1)
        n=$(cat "/sys/class/block/$(basename "$part")/partition") || exit 3
        [ -b "$disk" ] || exit 3
        sfdisk --relocate gpt-bak-std "$disk" >/dev/null 2>&1
        echo ", +" | sfdisk --force --no-reread --no-tell-kernel -N "$n" "$disk" >/dev/null 2>&1
        partx -u -n "$n" "$disk" 2>/dev/null
        case $fs in
          btrfs) btrfs filesystem resize max / >/dev/null || exit 4 ;;
          ext4) resize2fs "$part" >/dev/null 2>&1 || exit 4 ;;
          *) echo "root is $fs"; exit 5 ;;
        esac
        echo "fs=$(df -B1 --output=size / | tail -1 | tr -d ' ') disk=$(blockdev --getsize64 "$disk")"
        """

    /// Frees the blocks no file uses, on every file system that can.
    public static let compactScript = "fstrim -av"

    /// The grow worked: the file system reaches the disk's end, give or take
    /// the EFI partition (2 GB) and btrfs's own rounding.
    public static func grew(_ output: String) -> Bool {
        let v = numbers(output)
        guard let fs = v["fs"], let disk = v["disk"], disk > 0 else { return false }
        return fs >= disk - 3 * gib
    }

    /// "key=NUMBER" words of a script's output.
    public static func numbers(_ output: String) -> [String: Int64] {
        var v: [String: Int64] = [:]
        for word in output.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let n = Int64(kv[1]) { v[String(kv[0])] = n }
        }
        return v
    }

    // MARK: Smaller

    /// Run in the guest while the VM runs: what btrfs on / holds and where
    /// its partition starts, as "alloc=BYTES used=BYTES start=BYTES".
    public static let usageScript = """
        fs=$(findmnt -no FSTYPE /)
        [ "$fs" = btrfs ] || { echo "root is $fs"; exit 5; }
        part=$(findmnt -no SOURCE / | sed 's/\\[.*//')
        start=$(cat "/sys/class/block/$(basename "$part")/start") || exit 3
        btrfs filesystem usage -b / | awk -v s=$((start * 512)) '/Device allocated:/ {a=$3} /^ *Used:/ && !u {u=$2} END {print "alloc=" a " used=" u " start=" s}'
        """

    /// The guest's answer to `usageScript`; nil when it is not one.
    public static func need(fromUsage output: String) -> Need? {
        let v = numbers(output)
        guard let a = v["alloc"], let u = v["used"], let s = v["start"], a > 0, u >= 0, s > 0 else { return nil }
        return Need(allocated: a, used: u, rootStart: s)
    }

    /// Shrinks btrfs on / to `fsBytes` while it is mounted (btrfs moves what
    /// lies past the new end). A refused resize leaves it as it was. Prints
    /// "dev=BYTES", btrfs' size afterwards (filesystem show; device usage's
    /// "Device size" is the partition's).
    public static func shrinkScript(fsBytes: Int64) -> String {
        """
        fs=$(findmnt -no FSTYPE /)
        [ "$fs" = btrfs ] || { echo "root is $fs"; exit 5; }
        n=$(btrfs filesystem show --raw / | grep -c 'devid ')
        [ "$n" = 1 ] || { echo "devices=$n"; exit 6; }
        btrfs filesystem resize \(fsBytes) / 2>&1 || exit 4
        btrfs filesystem sync /
        sync
        echo "dev=$(btrfs filesystem show --raw / | awk '/devid/ {print $4; exit}')"
        """
    }

    /// The shrink worked: btrfs is now `fsBytes` or a little less (its sector rounding).
    public static func shrank(_ output: String, fsBytes: Int64) -> Bool {
        guard let dev = numbers(output)["dev"] else { return false }
        return dev <= fsBytes && dev > fsBytes - (1 << 20)
    }

    /// Back to the partition's full size after a step that did not finish.
    public static let unshrinkScript = "btrfs filesystem resize max / 2>&1"

    /// After the cut, at the next start: the partition table, btrfs within
    /// its partition, and every block read back against its checksum (a
    /// read-only scrub). Prints "checked fs=BYTES part=BYTES disk=BYTES".
    public static let checkScript = """
        part=$(findmnt -no SOURCE / | sed 's/\\[.*//')
        disk=/dev/$(lsblk -no PKNAME "$part" | head -1)
        [ -b "$disk" ] || exit 3
        v=$(sfdisk --verify "$disk" 2>&1) || { echo "partition table: $v"; exit 7; }
        p=$(blockdev --getsize64 "$part")
        f=$(btrfs filesystem show --raw / | awk '/devid/ {print $4; exit}')
        [ -n "$f" ] && [ "$f" -le "$p" ] || { echo "fs=$f part=$p"; exit 8; }
        s=$(btrfs scrub start -B -r / 2>&1) || { echo "scrub: $s"; exit 9; }
        case $s in *"no errors found"*) ;; *) echo "scrub: $s"; exit 9 ;; esac
        echo "checked fs=$f part=$p disk=$(blockdev --getsize64 "$disk")"
        """

    /// The check passed and the guest sees the disk at `diskBytes`.
    public static func checked(_ output: String, diskBytes: Int64) -> Bool {
        let v = numbers(output)
        guard output.contains("checked"), let f = v["fs"], let p = v["part"], let d = v["disk"] else { return false }
        return f <= p && p < d && d == diskBytes
    }

    /// Where making the disk smaller stands: the VM folder's disk-resize
    /// file, "key=value" lines. No file: nothing under way.
    public struct Resize: Equatable {
        public enum Step: String {
            /// The clone is made; the guest shrinks btrfs at the next start.
            case shrink
            /// btrfs is smaller; the app cuts disk.img before the next start.
            case cut
            /// disk.img is cut; the guest checks it at the next start.
            case check
            /// Stopped: `note` says why; the clone, if any, is still there.
            case failed
        }
        public var step: Step
        public var fromGB: Int
        public var toGB: Int
        public var plan: DiskImage.ShrinkPlan?
        public var note: String?

        public init(step: Step, fromGB: Int, toGB: Int, plan: DiskImage.ShrinkPlan?, note: String? = nil) {
            self.step = step; self.fromGB = fromGB; self.toGB = toGB; self.plan = plan; self.note = note
        }

        public static func parse(_ text: String) -> Resize? {
            var f: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { f[String(kv[0])] = String(kv[1]) }
            }
            guard let step = f["step"].flatMap(Step.init(rawValue:)),
                  let from = f["from"].flatMap(Int.init), let to = f["to"].flatMap(Int.init), from > 0, to > 0 else { return nil }
            let plan = DiskImage.ShrinkPlan(fields: f)
            // The steps on the disk need their plan.
            if step == .cut || step == .check, plan == nil { return nil }
            return Resize(step: step, fromGB: from, toGB: to, plan: plan, note: f["note"])
        }

        public var text: String {
            var f = ["step": step.rawValue, "from": "\(fromGB)", "to": "\(toGB)"]
            if let p = plan { f.merge(p.fields) { a, _ in a } }
            if let n = note { f["note"] = n.split(whereSeparator: \.isNewline).joined(separator: " ") }
            return f.keys.sorted().map { "\($0)=\(f[$0]!)\n" }.joined()
        }
    }

    // MARK: The guest agent's guest-exec-status

    public struct ExecStatus: Equatable {
        public var exited: Bool
        public var exitCode: Int
        public var output: String
        public init(exited: Bool, exitCode: Int, output: String) {
            self.exited = exited; self.exitCode = exitCode; self.output = output
        }
    }

    /// One reply line of guest-exec-status; nil when it is not one.
    public static func parseExecStatus(_ reply: String) -> ExecStatus? {
        guard let data = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = obj["return"] as? [String: Any] else { return nil }
        let exited = r["exited"] as? Bool ?? false
        let code = r["exitcode"] as? Int ?? (exited ? -1 : 0)
        var out = ""
        for key in ["out-data", "err-data"] {
            if let b = r[key] as? String, let d = Data(base64Encoded: b), let s = String(data: d, encoding: .utf8) {
                out += s
            }
        }
        return ExecStatus(exited: exited, exitCode: code, output: out)
    }

    /// The pid in guest-exec's reply.
    public static func parseExecPid(_ reply: String) -> Int? {
        guard let data = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = obj["return"] as? [String: Any] else { return nil }
        return r["pid"] as? Int
    }
}
