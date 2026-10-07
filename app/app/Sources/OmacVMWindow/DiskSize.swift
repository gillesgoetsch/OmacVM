import Foundation

/// The VM's disk in the window: its max size (disk.img, a sparse raw file),
/// what it takes on the Mac, Grow and Compact.
///
/// Grow (VM off): disk.img gets longer, vm.env's DISK_GB follows, and at the
/// VM's next start the app has the guest grow the root partition and its
/// file system to the new end (`growScript`, the same steps as the prebuilt
/// VM's first boot), through the guest agent.
///
/// Shrinking the max is not offered: the guest would have to shrink btrfs,
/// then the partition, then the GPT's backup at the new end before the image
/// is cut; a step cut short loses the VM. Compact gives the Mac back what the
/// VM does not use (fstrim in the guest; QEMU punches the freed blocks out of
/// disk.img, discard=unmap) and leaves the max as it is.
public enum DiskSize {
    public static let gib: Int64 = 1 << 30
    /// The largest disk the window offers (4 TB).
    public static let maxGB = 4096
    /// The steps of the Grow stepper.
    public static let stepGB = 16

    /// Sizes for the Mac's text: "64 GB", "1.5 GB", "320 MB".
    public static func text(_ bytes: Int64) -> String {
        let gb = Double(bytes) / Double(gib)
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(max(0, Int((Double(bytes) / 1_048_576).rounded()))) MB"
    }

    /// The first size Grow offers: the next step above the current one.
    public static func firstGrowGB(currentGB: Int) -> Int {
        min(maxGB, (currentGB / stepGB + 1) * stepGB)
    }

    /// Why this new size is refused, or nil.
    public static func growProblem(currentGB: Int, newGB: Int, vmRunning: Bool) -> String? {
        if vmRunning { return "Shut the VM down first." }
        if newGB <= currentGB { return "The new size must be larger than \(currentGB) GB." }
        if newGB > maxGB { return "\(maxGB) GB at most." }
        return nil
    }

    /// The disk grows as the VM fills it; when the new max is more than the
    /// Mac has free, say so (QEMU pauses the VM when the Mac's disk is full;
    /// nothing is lost, but the VM stops).
    public static func growWarning(newGB: Int, allocatedBytes: Int64, freeBytes: Int64?) -> String? {
        guard let free = freeBytes else { return nil }
        let more = Int64(newGB) * gib - allocatedBytes
        guard more > free else { return nil }
        return "The Mac has \(text(free)) free: the VM could fill it before its own disk is full."
    }

    // MARK: Jobs for the VM's next start

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
        var v: [String: Int64] = [:]
        for word in output.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let n = Int64(kv[1]) { v[String(kv[0])] = n }
        }
        guard let fs = v["fs"], let disk = v["disk"], disk > 0 else { return false }
        return fs >= disk - 3 * gib
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
