import Foundation

/// disk.img read and cut on the Mac while the VM is off: its GPT and the
/// btrfs superblock of Omarchy's root partition (the last one). What the
/// file system holds gives the smallest size the disk can take; the cut is
/// the last step of making it smaller, after the guest shrank btrfs
/// (DiskSize.shrinkScript).
///
/// Anything that does not look exactly like the layout OmacVM makes (GPT
/// with its backup at the end, btrfs on one device as the last partition,
/// crc32c checksums) is refused with a reason, never guessed at.
public enum DiskImage {
    public static let sector: Int64 = 512
    /// btrfs' primary superblock sits 64 KiB into its device.
    static let superblockOffset: Int64 = 65_536
    static let superblockSize = 4096

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case layout(String)
        /// The cut had started writing: the disk may be half done.
        case written(String)
        public var description: String {
            switch self {
            case .unreadable(let s), .layout(let s), .written(let s): return s
            }
        }
    }

    /// Whether the cut had already written when it stopped.
    public static func wrote(_ p: Problem) -> Bool {
        if case .written = p { return true }
        return false
    }

    // MARK: GPT

    public struct Partition: Equatable {
        public var index: Int          // 0-based slot in the entry array
        public var first: Int64        // LBA
        public var last: Int64         // LBA, inclusive
        public var bytes: Int64 { (last - first + 1) * sector }
    }

    public struct GPT: Equatable {
        public var header: [UInt8]     // the header's 92 bytes (as on disk)
        public var entries: [UInt8]    // the whole entry array
        public var alternate: Int64
        public var firstUsable: Int64
        public var lastUsable: Int64
        public var entriesLBA: Int64
        public var entryCount: Int
        public var entrySize: Int
        public var partitions: [Partition]

        /// Sectors the entry array takes (32 for the usual 128 x 128 bytes).
        public var entrySectors: Int64 { (Int64(entryCount * entrySize) + sector - 1) / sector }
        /// The partition that ends last: Omarchy's root.
        public var last: Partition? { partitions.max { $0.last < $1.last } }
    }

    /// The primary GPT from its header sector and entry array; nil when the
    /// signature or a checksum is wrong.
    public static func parseGPT(header h: [UInt8], entries: [UInt8]) -> GPT? {
        guard h.count >= 92, Array(h[0..<8]) == Array("EFI PART".utf8) else { return nil }
        let size = Int(le32(h, 12))
        guard size >= 92, size <= h.count else { return nil }
        var zeroed = Array(h[0..<size])
        zeroed.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        guard crc32(zeroed) == le32(h, 16) else { return nil }
        let count = Int(le32(h, 80)), esize = Int(le32(h, 84))
        guard esize >= 128, esize % 8 == 0, count > 0, count <= 1024, count * esize <= entries.count else { return nil }
        let array = Array(entries[0..<(count * esize)])
        guard crc32(array) == le32(h, 88) else { return nil }
        var parts: [Partition] = []
        for i in 0..<count {
            let e = i * esize
            if array[e..<(e + 16)].allSatisfy({ $0 == 0 }) { continue }
            parts.append(Partition(index: i, first: Int64(le64(array, e + 32)), last: Int64(le64(array, e + 40))))
        }
        return GPT(header: Array(h[0..<size]), entries: array, alternate: Int64(le64(h, 32)),
                   firstUsable: Int64(le64(h, 40)), lastUsable: Int64(le64(h, 48)), entriesLBA: Int64(le64(h, 72)),
                   entryCount: count, entrySize: esize, partitions: parts)
    }

    // MARK: btrfs

    public struct Btrfs: Equatable {
        public var totalBytes: Int64       // the file system's size
        public var bytesUsed: Int64        // what its files and metadata use
        public var devices: Int64
        public var deviceBytes: Int64      // this device's size for btrfs
        public var deviceAllocated: Int64  // chunks allocated on it (data, metadata twice, system)
        public init(totalBytes: Int64, bytesUsed: Int64, devices: Int64, deviceBytes: Int64, deviceAllocated: Int64) {
            self.totalBytes = totalBytes; self.bytesUsed = bytesUsed; self.devices = devices
            self.deviceBytes = deviceBytes; self.deviceAllocated = deviceAllocated
        }
    }

    /// The superblock (4 KiB at 64 KiB into the partition); nil when it is
    /// not btrfs, or its checksum is not a matching crc32c.
    public static func parseBtrfs(_ s: [UInt8]) -> Btrfs? {
        guard s.count >= superblockSize, Array(s[0x40..<0x48]) == Array("_BHRfS_M".utf8) else { return nil }
        // csum_type 0 = crc32c over everything after the 32-byte checksum field.
        guard le16(s, 0xC4) == 0, crc32c(Array(s[32..<superblockSize])) == le32(s, 0) else { return nil }
        let b = Btrfs(totalBytes: Int64(le64(s, 0x70)), bytesUsed: Int64(le64(s, 0x78)), devices: Int64(le64(s, 0x88)),
                      deviceBytes: Int64(le64(s, 0xC9 + 8)), deviceAllocated: Int64(le64(s, 0xC9 + 16)))
        guard b.totalBytes > 0, b.bytesUsed >= 0, b.deviceAllocated >= 0, b.deviceBytes > 0 else { return nil }
        return b
    }

    // MARK: Reading an image

    public struct Layout: Equatable {
        public var imageBytes: Int64
        public var gpt: GPT
        public var root: Partition
        public var fs: Btrfs
    }

    /// GPT and btrfs of disk.img at `path`, checked against OmacVM's layout.
    public static func read(_ path: String) -> Result<Layout, Problem> {
        guard let h = FileHandle(forReadingAtPath: path) else { return .failure(.unreadable("Cannot read disk.img.")) }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd(), end > 0 else { return .failure(.unreadable("Cannot read disk.img.")) }
        let size = Int64(end)
        guard let header = read(h, at: sector, count: Int(sector)),
              let gptHead = parseHeaderOnly(header),
              let entries = read(h, at: gptHead.entriesLBA * sector, count: gptHead.arrayBytes),
              let gpt = parseGPT(header: header, entries: entries) else {
            return .failure(.layout("The disk has no partition table OmacVM can read."))
        }
        if let p = checkLayout(gpt, imageBytes: size) { return .failure(.layout(p)) }
        guard let root = gpt.last else { return .failure(.layout("The disk has no partitions.")) }
        guard let sb = read(h, at: root.first * sector + superblockOffset, count: superblockSize),
              let fs = parseBtrfs(sb) else {
            return .failure(.layout("Omarchy's partition is not a btrfs file system OmacVM can read."))
        }
        if fs.devices != 1 { return .failure(.layout("Omarchy's file system spans \(fs.devices) disks.")) }
        if fs.deviceBytes > root.bytes { return .failure(.layout("Omarchy's file system is larger than its partition.")) }
        return .success(Layout(imageBytes: size, gpt: gpt, root: root, fs: fs))
    }

    /// The GPT as OmacVM makes it: the entry array right after the header,
    /// the backup at the disk's last sector, the root partition last.
    static func checkLayout(_ g: GPT, imageBytes: Int64) -> String? {
        let sectors = imageBytes / sector
        if imageBytes % sector != 0 { return "disk.img's length is not whole sectors." }
        if g.entriesLBA != 2 { return "The partition table is not laid out as OmacVM makes it." }
        if g.alternate != sectors - 1 { return "The partition table's backup is not at the disk's end." }
        if g.lastUsable >= sectors - 1 - g.entrySectors { return "The partition table claims more than the disk." }
        guard let root = g.last else { return "The disk has no partitions." }
        if root.last > g.lastUsable || root.first >= root.last { return "Omarchy's partition is outside the disk." }
        for p in g.partitions where p != root && p.last >= root.first { return "Another partition overlaps Omarchy's." }
        return nil
    }

    private struct HeaderOnly { var entriesLBA: Int64; var arrayBytes: Int }
    private static func parseHeaderOnly(_ h: [UInt8]) -> HeaderOnly? {
        guard h.count >= 92, Array(h[0..<8]) == Array("EFI PART".utf8) else { return nil }
        let count = Int(le32(h, 80)), esize = Int(le32(h, 84))
        guard esize >= 128, esize <= 4096, count > 0, count <= 1024 else { return nil }
        let lba = Int64(le64(h, 72))
        guard lba >= 2, lba < 1 << 40 else { return nil }
        return HeaderOnly(entriesLBA: lba, arrayBytes: count * esize)
    }

    private static func read(_ h: FileHandle, at offset: Int64, count: Int) -> [UInt8]? {
        guard offset >= 0, (try? h.seek(toOffset: UInt64(offset))) != nil,
              let d = try? h.read(upToCount: count), d.count == count else { return nil }
        return [UInt8](d)
    }

    // MARK: Making it smaller

    /// The new sizes for a disk of `targetGB`: disk.img's length, the root
    /// partition's last sector (the last usable one) and btrfs' size (the
    /// partition rounded down to MiB).
    public struct ShrinkPlan: Equatable {
        public var fromBytes: Int64
        public var newBytes: Int64
        public var partitionLast: Int64
        public var fsBytes: Int64
        public init(fromBytes: Int64, newBytes: Int64, partitionLast: Int64, fsBytes: Int64) {
            self.fromBytes = fromBytes; self.newBytes = newBytes; self.partitionLast = partitionLast; self.fsBytes = fsBytes
        }
        /// Saved in the VM folder's disk-resize file between the steps.
        public var fields: [String: String] {
            ["from_bytes": "\(fromBytes)", "new_bytes": "\(newBytes)", "part_last": "\(partitionLast)", "fs_bytes": "\(fsBytes)"]
        }
        public init?(fields f: [String: String]) {
            guard let a = f["from_bytes"].flatMap(Int64.init), let b = f["new_bytes"].flatMap(Int64.init),
                  let c = f["part_last"].flatMap(Int64.init), let d = f["fs_bytes"].flatMap(Int64.init),
                  b > 0, b < a, c > 0, d > 0 else { return nil }
            self.init(fromBytes: a, newBytes: b, partitionLast: c, fsBytes: d)
        }
    }

    /// The plan, or why this size cannot be done. `needBytes` is the most the
    /// file system may need (DiskSize.need); btrfs must keep at least that.
    public static func planShrink(_ l: Layout, targetGB: Int, needBytes: Int64) -> Result<ShrinkPlan, Problem> {
        let newBytes = Int64(targetGB) * DiskSize.gib
        guard newBytes < l.imageBytes else { return .failure(.layout("\(targetGB) GB is not smaller than the disk.")) }
        let sectors = newBytes / sector
        let lastUsable = sectors - 2 - l.gpt.entrySectors
        let first = l.root.first
        guard lastUsable > first else { return .failure(.layout("\(targetGB) GB leaves no room for Omarchy's partition.")) }
        let partBytes = (lastUsable - first + 1) * sector
        let fsBytes = partBytes / (1 << 20) * (1 << 20)
        guard fsBytes >= needBytes else {
            return .failure(.layout("Omarchy needs \(DiskSize.text(needBytes)) for its file system; \(targetGB) GB leaves \(DiskSize.text(fsBytes))."))
        }
        guard fsBytes < l.fs.deviceBytes else { return .failure(.layout("The file system is already that small.")) }
        return .success(ShrinkPlan(fromBytes: l.imageBytes, newBytes: newBytes, partitionLast: lastUsable, fsBytes: fsBytes))
    }

    /// disk.img is cut as `plan` says already (a start that stopped before
    /// it saved the step).
    public static func isCut(_ l: Layout, plan: ShrinkPlan) -> Bool {
        l.imageBytes == plan.newBytes && l.root.last == plan.partitionLast && l.fs.deviceBytes <= plan.fsBytes
    }

    /// The new primary header, entry array and backup header for `plan` (pure:
    /// tested without a disk).
    public static func shrunkTables(_ g: GPT, plan: ShrinkPlan) -> (primary: [UInt8], entries: [UInt8], backup: [UInt8], backupEntriesLBA: Int64)? {
        guard let root = g.last else { return nil }
        let sectors = plan.newBytes / sector
        var entries = g.entries
        put64(&entries, root.index * g.entrySize + 40, UInt64(plan.partitionLast))
        let entriesCRC = crc32(entries)
        let backupEntriesLBA = sectors - 1 - g.entrySectors
        func header(my: Int64, alternate: Int64, entriesAt: Int64) -> [UInt8] {
            var h = g.header
            put64(&h, 24, UInt64(my))
            put64(&h, 32, UInt64(alternate))
            put64(&h, 48, UInt64(plan.partitionLast))
            put64(&h, 72, UInt64(entriesAt))
            put32(&h, 88, entriesCRC)
            put32(&h, 16, 0)
            put32(&h, 16, crc32(h))
            return h
        }
        return (header(my: 1, alternate: sectors - 1, entriesAt: 2), entries,
                header(my: sectors - 1, alternate: 1, entriesAt: backupEntriesLBA), backupEntriesLBA)
    }

    /// The protective MBR's size for a disk of `sectors` (sector 0, entry 0).
    static func protectiveMBR(_ mbr: [UInt8], sectors: Int64) -> [UInt8]? {
        guard mbr.count == 512, mbr[510] == 0x55, mbr[511] == 0xAA, mbr[446 + 4] == 0xEE else { return nil }
        var m = mbr
        put32(&m, 446 + 12, UInt32(min(sectors - 1, Int64(UInt32.max))))
        return m
    }

    /// The last step of making the disk smaller, the VM off and btrfs already
    /// shrunk by the guest: checks the superblock again, writes the backup
    /// GPT at the new end, then the primary one, then cuts disk.img. Throws
    /// before anything is written when the disk is not as planned.
    public static func cut(_ path: String, plan: ShrinkPlan) throws {
        let layout: Layout
        switch read(path) {
        case .success(let l): layout = l
        case .failure(let p):
            // A cut that stopped part way: finished from its new backup GPT.
            guard let l = startedCut(path, plan: plan) else { throw p }
            layout = l
        }
        guard layout.imageBytes == plan.fromBytes else { throw Problem.layout("disk.img changed size since the plan.") }
        guard layout.fs.deviceBytes <= plan.fsBytes else {
            throw Problem.layout("Omarchy's file system is still \(DiskSize.text(layout.fs.deviceBytes)): it was not made smaller.")
        }
        guard layout.root.first * sector + layout.fs.deviceBytes <= (plan.partitionLast + 1) * sector,
              let t = shrunkTables(layout.gpt, plan: plan) else {
            throw Problem.layout("The new partition would cut into Omarchy's file system.")
        }
        guard let h = FileHandle(forUpdatingAtPath: path) else { throw Problem.unreadable("Cannot open disk.img to write.") }
        defer { try? h.close() }
        guard let mbr = read(h, at: 0, count: 512) else { throw Problem.unreadable("Cannot read disk.img.") }
        let newMBR = protectiveMBR(mbr, sectors: plan.newBytes / sector)
        // Backup first: it lands past the shrunk file system, inside the old
        // partition, where nothing reads it until the cut.
        do {
            try write(h, padded(t.entries), at: t.backupEntriesLBA * sector)
            try write(h, padded(t.backup), at: plan.newBytes - sector)
            try flush(h)
            try write(h, padded(t.entries), at: 2 * sector)
            try write(h, padded(t.primary), at: sector)
            if let m = newMBR { try write(h, m, at: 0) }
            try flush(h)
            try h.truncate(atOffset: UInt64(plan.newBytes))
            try flush(h)
        } catch {
            throw Problem.written("Writing disk.img failed: \(error.localizedDescription)")
        }
        // Read back as the guest's kernel will.
        guard case .success(let l) = read(path), l.imageBytes == plan.newBytes, l.root.last == plan.partitionLast,
              l.fs.deviceBytes == layout.fs.deviceBytes else {
            throw Problem.written("disk.img does not read back as written.")
        }
    }

    /// A cut that stopped (power cut, crash) after it wrote the new backup
    /// GPT and before the truncate: disk.img has its old length, the primary
    /// GPT is old, half new (entries only) or new, so `read` refuses it. The
    /// backup at the new end is whole (written and flushed first) and has the
    /// same disk GUID as the primary header: the layout from it. nil when
    /// the disk is not in that state.
    static func startedCut(_ path: String, plan: ShrinkPlan) -> Layout? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let newSectors = plan.newBytes / sector
        guard let end = try? h.seekToEnd(), Int64(end) == plan.fromBytes, newSectors > 2,
              let header = read(h, at: plan.newBytes - sector, count: Int(sector)),
              let head = parseHeaderOnly(header),
              le64(header, 24) == UInt64(newSectors - 1), le64(header, 32) == 1,
              le64(header, 48) == UInt64(plan.partitionLast),
              let entries = read(h, at: head.entriesLBA * sector, count: head.arrayBytes),
              let g = parseGPT(header: header, entries: entries),
              g.entriesLBA == newSectors - 1 - g.entrySectors,
              let root = g.last, root.last == plan.partitionLast, root.first < root.last,
              let primary = read(h, at: sector, count: Int(sector)),
              Array(primary[0..<8]) == Array("EFI PART".utf8), primary[56..<72] == header[56..<72],
              let sb = read(h, at: root.first * sector + superblockOffset, count: superblockSize),
              let fs = parseBtrfs(sb), fs.devices == 1 else { return nil }
        return Layout(imageBytes: plan.fromBytes, gpt: g, root: root, fs: fs)
    }

    /// fsync, then the drive's own cache too (F_FULLFSYNC): the backup GPT is
    /// on the disk before the primary one changes, even after a power cut.
    private static func flush(_ h: FileHandle) throws {
        try h.synchronize()
        #if canImport(Darwin)
        _ = fcntl(h.fileDescriptor, F_FULLFSYNC)
        #endif
    }

    /// Whole sectors: the rest of a header's sector is zero.
    static func padded(_ b: [UInt8]) -> [UInt8] {
        let n = (Int64(b.count) + sector - 1) / sector * sector
        return b + [UInt8](repeating: 0, count: Int(n) - b.count)
    }

    private static func write(_ h: FileHandle, _ bytes: [UInt8], at offset: Int64) throws {
        try h.seek(toOffset: UInt64(offset))
        try h.write(contentsOf: Data(bytes))
    }

    // MARK: Bytes

    static func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
    static func le64(_ b: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * $1) } }
    static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    static func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) { for i in 0..<8 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }

    private static func table(_ poly: UInt32) -> [UInt32] {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? poly ^ (c >> 1) : c >> 1 }
            return c
        }
    }
    private static let crcTable = table(0xEDB8_8320)
    private static let crcCTable = table(0x82F6_3B78)
    private static func crc(_ bytes: [UInt8], _ t: [UInt32]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
    /// zlib's CRC-32 (GPT).
    public static func crc32(_ bytes: [UInt8]) -> UInt32 { crc(bytes, crcTable) }
    /// CRC-32C, Castagnoli (btrfs).
    public static func crc32c(_ bytes: [UInt8]) -> UInt32 { crc(bytes, crcCTable) }
}
