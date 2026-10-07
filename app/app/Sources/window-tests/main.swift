// The VM window's rules (OmacVMWindow), without a VM or the app:
//   cd app/app && swift run window-tests
// Custom resources, the disk's size (slider bounds, smaller in steps), "omacvm in Terminal", the window's
// height, the keyboard note. Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMWindow

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// MARK: Custom resources: the CLI's limits (src/cmd/resources.sh)

let m4 = ResourceLimits(macCores: 16, macMemoryGB: 128)
expect(m4.cpus == 1...16 && m4.memoryGB == 4...112, "128 GB Mac: 1-16 CPUs, 4-112 GB (macOS keeps an eighth)")
expect(m4.safeMemoryGB == 96, "128 GB Mac: safe up to 96 GB (Best tier)")
expect(m4.warning(memoryGB: 96) == nil && m4.warning(memoryGB: 97) != nil, "warns only above the safe limit")
expect(m4.problem(cpus: 16, memoryGB: 112) == nil && m4.problem(cpus: 16, memoryGB: 128) != nil, "up to 112 GB (with a warning), never all of the Mac's")
expect(m4.problem(cpus: 17, memoryGB: 8) != nil && m4.problem(cpus: 0, memoryGB: 8) != nil, "CPUs outside 1-16 refused")
expect(m4.problem(cpus: 4, memoryGB: 3) != nil && m4.problem(cpus: 4, memoryGB: 113) != nil, "memory outside 4-112 refused")
let air = ResourceLimits(macCores: 8, macMemoryGB: 8)
expect(air.safeMemoryGB == 4 && air.memoryGB == 4...6, "8 GB Mac: 4-6 GB, safe 4")
expect(air.warning(memoryGB: 6) != nil, "8 GB Mac: 6 GB warns")
expect(m4.clamp(cpus: 40, memoryGB: 1) == (16, 4), "odd vm.env values land inside the steppers")
expect(CommandLineInstall.placeProblem(appCLI: "/private/var/folders/x/AppTranslocation/ABC/d/OmacVM.app" + CommandLineInstall.appSuffix, readOnlyVolume: false) != nil, "no link to a translocated app")
expect(CommandLineInstall.placeProblem(appCLI: "/Volumes/OmacVM/OmacVM.app" + CommandLineInstall.appSuffix, readOnlyVolume: true) != nil, "no link into the disk image")
expect(CommandLineInstall.placeProblem(appCLI: "/Applications/OmacVM.app" + CommandLineInstall.appSuffix, readOnlyVolume: false) == nil, "Applications is fine")
let mini = ResourceLimits(macCores: 10, macMemoryGB: 16)
expect(mini.memoryGB == 4...14 && ResourceLimits(macCores: 12, macMemoryGB: 64).memoryGB == 4...56, "16 GB Mac: up to 14 GB; 64 GB Mac: up to 56 GB")
expect(mini.safeMemoryGB == 8, "16 GB Mac: safe up to 8 GB")

// MARK: Disk

expect(DiskSize.text(64 * DiskSize.gib) == "64 GB" && DiskSize.text(DiskSize.gib * 3 / 2) == "1.5 GB"
       && DiskSize.text(320 * 1_048_576) == "320 MB", "sizes as text")
let gb = DiskSize.gib
let efiEnd: Int64 = 4_196_352 * 512   // where Omarchy's root partition starts (2 GB EFI before it)

// The slider's bottom: btrfs' chunks + 10 % (5 GB at least), after the EFI partition.
expect(DiskSize.margin(13 * gb) == 5 * gb && DiskSize.margin(100 * gb) == 10 * gb, "margin: 10 %, 5 GB at least")
let bench = DiskSize.Need(allocated: 13 * gb, used: 9 * gb + gb * 3 / 10, rootStart: efiEnd)
let b128 = DiskSize.bounds(currentGB: 128, need: bench, freeBytes: 500 * gb)
expect(b128.minGB == 64 && b128.why.contains("64 GB") && b128.why.contains("9.3 GB"), "little used: 64 GB, the smallest disk (\(b128.why))")
expect(b128.maxGB == 128 + 490, "top: free space + size now - 10 GB (\(b128.maxGB))")
let full = DiskSize.Need(allocated: 100 * gb, used: 96 * gb, rootStart: efiEnd)
let b256 = DiskSize.bounds(currentGB: 256, need: full, freeBytes: 50 * gb)
// 2 GB EFI + 100 + 10 + 2 MiB -> 113 GB (rounded up)
expect(b256.minGB == 113 && b256.why.contains("113 GB") && b256.why.contains("96 GB"), "much used: what it needs, rounded up (\(b256.why))")
expect(DiskSize.bounds(currentGB: 110, need: full, freeBytes: 50 * gb).minGB == 110, "needs more than it has: only larger")
expect(DiskSize.bounds(currentGB: 64, need: bench, freeBytes: 50 * gb).minGB == 64, "64 GB: only larger")
expect(DiskSize.bounds(currentGB: 48, need: bench, freeBytes: 50 * gb).minGB == 48, "an older smaller disk: never pushed up")
let unknown = DiskSize.bounds(currentGB: 128, need: nil, unknownWhy: "no btrfs", freeBytes: 50 * gb)
expect(unknown.minGB == 128 && unknown.why.contains("no btrfs"), "nothing known: only larger, and why")
expect(DiskSize.bounds(currentGB: 128, need: bench, freeBytes: 4 * gb).maxGB == 128, "Mac nearly full: not larger")
expect(DiskSize.bounds(currentGB: 128, need: bench, freeBytes: 100_000 * gb).maxGB == DiskSize.maxGB, "4 TB at most")
expect(DiskSize.bounds(currentGB: 128, need: bench, freeBytes: nil).maxGB == DiskSize.maxGB, "free space unknown: 4 TB")
expect(DiskSize.bounds(currentGB: 5000, need: bench, freeBytes: 0).maxGB == 5000, "top never below the size now")

// Slider and number field: whole GB inside the ends.
expect(DiskSize.snap(96.4, b128) == 96 && DiskSize.snap(96.5, b128) == 97, "slider: nearest GB")
expect(DiskSize.snap(10, b128) == 64 && DiskSize.snap(9999, b128) == 618 && DiskSize.snap(.nan, b128) == 64, "slider: kept inside")
expect(DiskSize.parseGB("96") == 96 && DiskSize.parseGB(" 96 GB ") == 96 && DiskSize.parseGB("96gb") == 96
       && DiskSize.parseGB("96,6") == 97, "number field: 96, 96 GB, 96,6")
expect(DiskSize.parseGB("abc") == nil && DiskSize.parseGB("-3") == nil && DiskSize.parseGB("") == nil, "number field: no size")
expect(DiskSize.changeProblem(currentGB: 128, newGB: 96, bounds: b128, vmRunning: false) == nil, "smaller within the bounds")
expect(DiskSize.changeProblem(currentGB: 128, newGB: 200, bounds: b128, vmRunning: false) == nil, "larger within the bounds")
expect(DiskSize.changeProblem(currentGB: 128, newGB: 200, bounds: b128, vmRunning: true) != nil, "never while the VM runs")
expect(DiskSize.changeProblem(currentGB: 128, newGB: 63, bounds: b128, vmRunning: false) != nil
       && DiskSize.changeProblem(currentGB: 128, newGB: 619, bounds: b128, vmRunning: false) != nil, "outside the bounds refused")

expect(DiskSize.parseJobs("compact\ngrow\ngrow\njunk\n") == [.grow, .compact], "jobs: known ones once, grow first")
expect(DiskSize.parseJobs("") == [], "no jobs")
expect(DiskSize.jobsText([.compact, .grow]) == "grow\ncompact\n", "jobs written grow first")

let g = DiskSize.gib
expect(DiskSize.grew("fs=\(126 * g) disk=\(128 * g)\n"), "fs at the disk's end (minus EFI): grown")
expect(!DiskSize.grew("fs=\(62 * g) disk=\(128 * g)"), "fs still at the old size: not grown")
expect(!DiskSize.grew("root is xfs"), "no numbers: not grown")
expect(DiskSize.growScript.contains("sed 's/\\[.*//'") && DiskSize.growScript.contains("btrfs filesystem resize max /"),
       "grow script as the prebuilt first boot (src/prebuilt/guest/omacvm-firstboot)")
expect(!DiskSize.growScript.contains("--shrink") && !DiskSize.growScript.contains("mkfs"), "grow script never shrinks or formats")

let out = Data("fs=1 disk=2\n".utf8).base64EncodedString()
let st = DiskSize.parseExecStatus("{\"return\": {\"exitcode\": 0, \"out-data\": \"\(out)\", \"exited\": true}}")
expect(st == DiskSize.ExecStatus(exited: true, exitCode: 0, output: "fs=1 disk=2\n"), "guest-exec-status parsed")
expect(DiskSize.parseExecStatus("{\"return\": {\"exited\": false}}")?.exited == false, "still running")
expect(DiskSize.parseExecStatus("{\"error\": {\"class\": \"GenericError\"}}") == nil, "an error is no status")
expect(DiskSize.parseExecPid("{\"return\": {\"pid\": 812}}") == 812, "guest-exec pid parsed")

// MARK: Disk smaller: the guest's answers and the steps' file

expect(DiskSize.need(fromUsage: "alloc=13981712384 used=10251685888 start=2148532224\n")
       == DiskSize.Need(allocated: 13_981_712_384, used: 10_251_685_888, rootStart: 2_148_532_224), "usage read from the guest")
expect(DiskSize.need(fromUsage: "root is ext4") == nil && DiskSize.need(fromUsage: "alloc= used= start=0") == nil, "no usage: nil")
expect(DiskSize.shrank("Resize device id 1 (/dev/nvme0n1p2) from 125.99GiB to 61.98GiB\ndev=66551971840\n", fsBytes: 66_551_971_840),
       "btrfs at the planned size: shrank")
expect(!DiskSize.shrank("ERROR: unable to resize: No space left on device", fsBytes: 66_551_971_840)
       && !DiskSize.shrank("dev=135283744768", fsBytes: 66_551_971_840), "refused or still large: not shrank")
expect(DiskSize.checked("checked fs=66551971840 part=66553004032 disk=\(64 * gb)", diskBytes: 64 * gb), "check passed")
expect(!DiskSize.checked("checked fs=66551971840 part=66553004032 disk=\(128 * gb)", diskBytes: 64 * gb)
       && !DiskSize.checked("scrub: ERROR: there are uncorrectable errors", diskBytes: 64 * gb)
       && !DiskSize.checked("checked fs=2 part=1 disk=\(64 * gb)", diskBytes: 64 * gb), "check failed: old size, scrub errors, fs past its partition")
let plan64 = DiskImage.ShrinkPlan(fromBytes: 128 * gb, newBytes: 64 * gb, partitionLast: 134_217_694, fsBytes: 66_551_971_840)
let steps = DiskSize.Resize(step: .cut, fromGB: 128, toGB: 64, plan: plan64)
expect(DiskSize.Resize.parse(steps.text) == steps, "steps file: written and read back")
var failed = DiskSize.Resize(step: .failed, fromGB: 128, toGB: 64, plan: nil, note: "two\nlines")
expect(DiskSize.Resize.parse(failed.text)?.note == "two lines", "a note stays one line")
failed.step = .check
expect(DiskSize.Resize.parse(failed.text) == nil, "a disk step without its plan: ignored")
expect(DiskSize.Resize.parse("step=cut\nfrom=128\nto=64\nfrom_bytes=1\nnew_bytes=2\npart_last=3\nfs_bytes=4\n") == nil,
       "a plan that grows: ignored")
expect(DiskSize.shrinkScript(fsBytes: 66_551_971_840).contains("btrfs filesystem resize 66551971840 /")
       && !DiskSize.shrinkScript(fsBytes: 1).contains("mkfs"), "shrink script: btrfs to the planned bytes, nothing else")
expect(DiskSize.checkScript.contains("scrub start -B -r") && DiskSize.checkScript.contains("sfdisk --verify"),
       "check script: read-only scrub and the partition table")

// MARK: Disk smaller: disk.img's GPT and btrfs, on a made-up disk

expect(DiskImage.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC-32 (GPT)")
expect(DiskImage.crc32c(Array("123456789".utf8)) == 0xE306_9283, "CRC-32C (btrfs)")

func put(_ b: inout [UInt8], _ o: Int, _ v: UInt64, _ n: Int) { for i in 0..<n { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) } }
func get(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }

/// A sparse disk.img laid out as OmacVM's: protective MBR, GPT (EFI, then
/// btrfs to the last usable sector), backup GPT at the end.
func makeDisk(_ path: String, gib: Int64, fsBytes: Int64? = nil, allocated: Int64, devices: UInt64 = 1, csumType: UInt64 = 0) -> Bool {
    let sectors = gib * gb / 512
    let rootFirst: Int64 = 133_120, lastUsable = sectors - 34
    var mbr = [UInt8](repeating: 0, count: 512)
    mbr[450] = 0xEE; put(&mbr, 454, 1, 4); put(&mbr, 458, UInt64(min(sectors - 1, 0xFFFF_FFFF)), 4); mbr[510] = 0x55; mbr[511] = 0xAA
    var entries = [UInt8](repeating: 0, count: 128 * 128)
    for (i, (first, last)) in [(Int64(2048), Int64(133_119)), (rootFirst, lastUsable)].enumerated() {
        for k in 0..<16 { entries[i * 128 + k] = UInt8(0x11 * (i + 1)); entries[i * 128 + 16 + k] = UInt8(k + 1) }
        put(&entries, i * 128 + 32, UInt64(first), 8); put(&entries, i * 128 + 40, UInt64(last), 8)
    }
    func header(my: Int64, alt: Int64, at: Int64) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        h.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        put(&h, 8, 0x0001_0000, 4); put(&h, 12, 92, 4); put(&h, 24, UInt64(my), 8); put(&h, 32, UInt64(alt), 8)
        put(&h, 40, 34, 8); put(&h, 48, UInt64(lastUsable), 8); put(&h, 72, UInt64(at), 8)
        put(&h, 80, 128, 4); put(&h, 84, 128, 4); put(&h, 88, UInt64(DiskImage.crc32(entries)), 4)
        put(&h, 16, UInt64(DiskImage.crc32(Array(h[0..<92]))), 4)
        return h
    }
    var sb = [UInt8](repeating: 0, count: 4096)
    sb.replaceSubrange(0x40..<0x48, with: Array("_BHRfS_M".utf8))
    let fs = fsBytes ?? (lastUsable - rootFirst + 1) * 512
    put(&sb, 0x70, UInt64(fs), 8); put(&sb, 0x78, UInt64(allocated * 3 / 4), 8); put(&sb, 0x88, devices, 8)
    put(&sb, 0xC4, csumType, 2); put(&sb, 0xC9, 1, 8); put(&sb, 0xD1, UInt64(fs), 8); put(&sb, 0xD9, UInt64(allocated), 8)
    put(&sb, 0, UInt64(DiskImage.crc32c(Array(sb[32...]))), 4)
    guard FileManager.default.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else { return false }
    defer { try? h.close() }
    for (bytes, at) in [(mbr, Int64(0)), (header(my: 1, alt: sectors - 1, at: 2), 512), (entries, 1024),
                        (sb, rootFirst * 512 + 65_536), (entries, (sectors - 33) * 512), (header(my: sectors - 1, alt: 1, at: sectors - 33), (sectors - 1) * 512)] {
        guard (try? h.seek(toOffset: UInt64(at))) != nil, (try? h.write(contentsOf: Data(bytes))) != nil else { return false }
    }
    return (try? h.truncate(atOffset: UInt64(sectors * 512))) != nil
}

func bytes(_ path: String, _ at: Int64, _ n: Int) -> [UInt8] {
    guard let h = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? h.close() }
    try? h.seek(toOffset: UInt64(at))
    return [UInt8]((try? h.read(upToCount: n)) ?? Data())
}

let imgDir = FileManager.default.temporaryDirectory.appendingPathComponent("omacvm-disk-tests-\(getpid())")
try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
let img = imgDir.appendingPathComponent("disk.img").path
if makeDisk(img, gib: 128, allocated: 13 * gb), case .success(let l) = DiskImage.read(img) {
    expect(l.imageBytes == 128 * gb && l.root.first == 133_120 && l.root.last == 128 * gb / 512 - 34, "made-up disk read: GPT")
    expect(l.fs.deviceAllocated == 13 * gb && l.fs.devices == 1 && l.fs.deviceBytes == l.root.bytes, "made-up disk read: btrfs")
    let need = DiskSize.Need(allocated: l.fs.deviceAllocated, used: l.fs.bytesUsed, rootStart: l.root.first * 512)
    let bounds = DiskSize.bounds(currentGB: 128, need: need, freeBytes: 500 * gb)
    // The slider's bottom can always be planned; one GB under a need-bound bottom cannot.
    if case .success(let p) = DiskImage.planShrink(l, targetGB: bounds.minGB, needBytes: DiskSize.fsNeed(need)) {
        expect(p.newBytes == 64 * gb && p.partitionLast == 64 * gb / 512 - 34 && p.fsBytes % (1 << 20) == 0
               && p.fsBytes <= (p.partitionLast - l.root.first + 1) * 512, "plan: 64 GB, partition to the last usable sector, btrfs in MiB")
        // Not yet shrunk by the guest: the cut refuses and writes nothing.
        let before = bytes(img, 0, 34 * 512)
        var refused = false
        do { try DiskImage.cut(img, plan: p) } catch let e as DiskImage.Problem { refused = !DiskImage.wrote(e) } catch {}
        expect(refused && bytes(img, 0, 34 * 512) == before && DiskImage.read(img).map(\.imageBytes) == .success(128 * gb),
               "cut before btrfs shrank: refused, nothing written")
        // The guest shrank btrfs: the superblock says so.
        _ = makeDisk(img, gib: 128, fsBytes: p.fsBytes, allocated: 13 * gb)
        do {
            try DiskImage.cut(img, plan: p)
            if case .success(let a) = DiskImage.read(img) {
                expect(a.imageBytes == 64 * gb && a.root.last == p.partitionLast && a.gpt.lastUsable == p.partitionLast
                       && a.fs.deviceBytes == p.fsBytes && a.gpt.partitions.count == 2 && a.gpt.partitions[0].last == 133_119,
                       "cut: 64 GB, root partition to the new end, EFI untouched, btrfs intact")
                expect(DiskImage.isCut(a, plan: p) && !DiskImage.isCut(l, plan: p), "cut already: seen as cut (and before: not)")
            } else {
                expect(false, "cut: the disk reads back")
            }
            let end = 64 * gb / 512
            let backup = bytes(img, (end - 1) * 512, 512), backupEntries = bytes(img, (end - 33) * 512, 128 * 128)
            let primary = bytes(img, 512, 512), mbr = bytes(img, 0, 512)
            let parsed = DiskImage.parseGPT(header: backup, entries: backupEntries)
            expect(parsed != nil && get(backup, 24, 8) == UInt64(end - 1) && get(backup, 32, 8) == 1 && get(backup, 72, 8) == UInt64(end - 33)
                   && parsed?.partitions == DiskImage.parseGPT(header: primary, entries: bytes(img, 1024, 128 * 128))?.partitions,
                   "cut: backup GPT valid at the new end, same partitions")
            expect(get(primary, 32, 8) == UInt64(end - 1) && get(mbr, 458, 4) == UInt64(end - 1) && mbr[450] == 0xEE,
                   "cut: primary points at the new backup, protective MBR resized")
            expect(backup[92..<512].allSatisfy { $0 == 0 } && primary[92..<512].allSatisfy { $0 == 0 }, "cut: rest of the header sectors zero")
        } catch {
            expect(false, "cut after the guest shrank btrfs: \(error)")
        }
        // A cut stopped by a power cut after the new backup GPT: with the
        // primary GPT new (not truncated yet), or only its entries new. The
        // next try finishes it; a damaged disk without that backup is refused.
        for (what, primaryHeader) in [("primary GPT new", true), ("only the primary entries new", false)] {
            _ = makeDisk(img, gib: 128, fsBytes: p.fsBytes, allocated: 13 * gb)
            guard case .success(let s) = DiskImage.read(img), let t = DiskImage.shrunkTables(s.gpt, plan: p),
                  let h = FileHandle(forWritingAtPath: img) else { expect(false, "stopped cut: set up"); continue }
            let pad = { (b: [UInt8]) in b + [UInt8](repeating: 0, count: 512 - b.count) }
            var parts: [([UInt8], Int64)] = [(t.entries, t.backupEntriesLBA * 512), (pad(t.backup), p.newBytes - 512), (t.entries, 1024)]
            if primaryHeader { parts.append((pad(t.primary), 512)) }
            for (b, at) in parts { try? h.seek(toOffset: UInt64(at)); try? h.write(contentsOf: Data(b)) }
            try? h.close()
            let stuck = (try? DiskImage.read(img).get()) == nil
            var done = false
            if (try? DiskImage.cut(img, plan: p)) != nil, case .success(let a) = DiskImage.read(img) { done = DiskImage.isCut(a, plan: p) }
            expect(stuck && done, "cut stopped (\(what)): finished at the next try")
        }
        _ = makeDisk(img, gib: 128, fsBytes: p.fsBytes, allocated: 13 * gb)
        if let h = FileHandle(forWritingAtPath: img) { try? h.seek(toOffset: 1024 + 40); try? h.write(contentsOf: Data([9])); try? h.close() }
        var refusedDamaged = false
        do { try DiskImage.cut(img, plan: p) } catch let e as DiskImage.Problem { refusedDamaged = !DiskImage.wrote(e) } catch {}
        let length = ((try? FileManager.default.attributesOfItem(atPath: img))?[.size] as? NSNumber)?.int64Value
        expect(refusedDamaged && length == 128 * gb, "cut of a damaged GPT without a new backup: refused")
    } else {
        expect(false, "plan at the slider's bottom")
    }
    // Refusals: below what btrfs needs, not smaller, a damaged or odd disk.
    _ = makeDisk(img, gib: 256, allocated: 100 * gb)
    if case .success(let big) = DiskImage.read(img) {
        let n = DiskSize.Need(allocated: 100 * gb, used: 75 * gb, rootStart: big.root.first * 512)
        let bmin = DiskSize.bounds(currentGB: 256, need: n, freeBytes: 0).minGB
        expect(bmin == 111, "made-up full disk: bottom 111 GB (\(bmin))")
        let ok = DiskImage.planShrink(big, targetGB: bmin, needBytes: DiskSize.fsNeed(n))
        let under = DiskImage.planShrink(big, targetGB: bmin - 1, needBytes: DiskSize.fsNeed(n))
        expect((try? ok.get()) != nil && (try? under.get()) == nil, "plan: the bottom works, a GB under it is refused")
        expect((try? DiskImage.planShrink(big, targetGB: 256, needBytes: 0).get()) == nil, "plan: the same size is no shrink")
    }
    _ = makeDisk(img, gib: 128, allocated: 13 * gb, devices: 2)
    expect((try? DiskImage.read(img).get()) == nil, "btrfs on two devices: refused")
    _ = makeDisk(img, gib: 128, allocated: 13 * gb, csumType: 1)
    expect((try? DiskImage.read(img).get()) == nil, "btrfs with another checksum: refused")
    _ = makeDisk(img, gib: 128, allocated: 13 * gb)
    if let h = FileHandle(forWritingAtPath: img) { try? h.seek(toOffset: 1024 + 40); try? h.write(contentsOf: Data([9])); try? h.close() }
    expect((try? DiskImage.read(img).get()) == nil, "GPT entries changed behind the checksum: refused")
    _ = makeDisk(img, gib: 128, allocated: 13 * gb)
    if let h = FileHandle(forWritingAtPath: img) { try? h.truncate(atOffset: UInt64(130 * gb)); try? h.close() }
    expect((try? DiskImage.read(img).get()) == nil, "backup GPT not at the end (grown without the guest): refused")
} else {
    expect(false, "made-up disk")
}
try? FileManager.default.removeItem(at: imgDir)

// MARK: omacvm in Terminal

let home = "/Users/u"
let app = "/Users/u/Applications/OmacVM.app/Contents/Resources/omacvm/omacvm"
func plan(_ path: String, _ fs: [String: CommandLineInstall.Entry]) -> CommandLineInstall.State {
    CommandLineInstall.state(path: path, home: home, appCLI: app, entry: { fs[$0] ?? .none }, resolve: { p in
        if p == app { return app }
        if case .link(let to)? = fs[p] { return to == app ? app : to }
        return nil
    })
}
let sysPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
expect(plan(sysPath, [:]) == .available(target: "/usr/local/bin/omacvm", needsAdmin: true),
       "nothing yet, no ~/.local/bin on PATH: /usr/local/bin with the password")
expect(plan("/Users/u/.local/bin:" + sysPath, [:]) == .available(target: "/Users/u/.local/bin/omacvm", needsAdmin: false),
       "~/.local/bin on PATH: there, no password")
expect(plan(sysPath, ["/usr/local/bin/omacvm": .link(to: app)]) == .installed(at: "/usr/local/bin/omacvm"),
       "a link to this app: Installed")
expect(plan("/Users/u/.local/bin:" + sysPath, ["/Users/u/.local/bin/omacvm": .link(to: "/Users/u/.omacvm/omacvm")])
       == .other(at: "/Users/u/.local/bin/omacvm"), "a checkout's omacvm (install.sh) is kept")
expect(plan(sysPath, ["/usr/local/bin/omacvm": .other]) == .other(at: "/usr/local/bin/omacvm"), "a plain file is kept")
expect(plan(sysPath, ["/usr/local/bin/omacvm": .link(to: "/Applications/OmacVM.app/Contents/Resources/omacvm/omacvm")])
       == .available(target: "/usr/local/bin/omacvm", needsAdmin: true), "a link to an older OmacVM app: renewed")
expect(plan("/Users/u/.local/bin:" + sysPath, ["/usr/local/bin/omacvm": .link(to: app)]) == .installed(at: "/usr/local/bin/omacvm"),
       "installed further down the PATH still counts")
expect(plan("/opt/x/bin:" + sysPath, ["/opt/x/bin/omacvm": .other, "/usr/local/bin/omacvm": .link(to: app)])
       == .other(at: "/opt/x/bin/omacvm"), "another omacvm first on the PATH wins: kept, said")
expect(plan("relative:" + sysPath, ["relative/omacvm": .other]) == .available(target: "/usr/local/bin/omacvm", needsAdmin: true),
       "relative PATH entries ignored")
expect(CommandLineInstall.linkCommand(target: "/usr/local/bin/omacvm", appCLI: "/A B/it's/omacvm")
       == "/bin/mkdir -p '/usr/local/bin' && /bin/ln -sfn '/A B/it'\\''s/omacvm' '/usr/local/bin/omacvm'", "link command quoted")
expect(CommandLineInstall.appleScriptString("a \"b\" \\c") == "\"a \\\"b\\\" \\\\c\"", "AppleScript string quoted")

// The order of OmacVM's versions (#233), the same as src/lib/version.sh's
// version_cmp (src/tests/version-guard.sh has the shell's side).
let vc = CommandLineInstall.compareVersions
expect(vc("3.0.10", "3.0.9") == 1 && vc("3.0.9", "3.0.10") == -1, "3.0.10 is newer than 3.0.9")
expect(vc("3.0", "3.0.0") == 0 && vc("v3.0.3", "3.0.3") == 0 && vc("3.0.3+abc", "3.0.3") == 0, "3.0 = 3.0.0; v and +build ignored")
expect(vc("3.0.5-rc1", "3.0.5") == -1 && vc("3.0.5", "3.0.5-rc1") == 1, "a pre-release is older than its release")
expect(vc("3.0.5-rc9", "3.0.5-rc10") == -1 && vc("3.0.5-beta", "3.0.5-rc1") == -1, "rc9 < rc10, beta < rc")
expect(vc("3.0.0-RC14", "3.0.0-rc2") == 1 && vc("3.0.5-1", "3.0.5-rc") == -1, "labels: any case; numbers before words")
expect(vc("3.0.5-inf", "3.0.5-1") == 1, "a word is no number (inf)")
expect(vc("main", "3.0.3") == nil && vc("", "3.0.3") == nil, "no version: nil")
expect(CommandLineInstall.older("2.9.1", than: "3.0.3") && !CommandLineInstall.older("3.0.3", than: "3.0.3")
       && !CommandLineInstall.older(nil, than: "3.0.3"), "older")
expect(CommandLineInstall.olderNote(.other(at: "/opt/homebrew/bin/omacvm"), other: "2.9.1", app: "3.0.3")?.contains("OmacVM 2.9.1, older than this app (3.0.3)") == true,
       "an older omacvm first on the PATH: said")
expect(CommandLineInstall.olderNote(.other(at: "/opt/homebrew/bin/omacvm"), other: "3.0.4", app: "3.0.3") == nil
       && CommandLineInstall.olderNote(.installed(at: "/usr/local/bin/omacvm"), other: "2.9.1", app: "3.0.3") == nil,
       "a newer one, or this app's own: nothing to say")

// On a real disk: a throwaway HOME, the link made with linkCommand.
do {
    let fm = FileManager.default
    let tmp = (fm.temporaryDirectory.appendingPathComponent("window-tests-\(getpid())").path as NSString).resolvingSymlinksInPath
    try? fm.removeItem(atPath: tmp)
    let h = tmp + "/home", cli = tmp + "/A B.app/Contents/Resources/omacvm/omacvm", bin = h + "/.local/bin"
    try fm.createDirectory(atPath: (cli as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    let p = bin + ":/usr/bin:/bin"
    let s1 = CommandLineInstall.state(path: p, home: h, appCLI: cli)
    expect(s1 == .available(target: bin + "/omacvm", needsAdmin: false), "disk: ~/.local/bin offered (\(s1))")
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", CommandLineInstall.linkCommand(target: bin + "/omacvm", appCLI: cli)]
    try sh.run(); sh.waitUntilExit()
    expect(sh.terminationStatus == 0, "disk: link made (mkdir -p too)")
    expect(CommandLineInstall.state(path: p, home: h, appCLI: cli) == .installed(at: bin + "/omacvm"), "disk: Installed")
    try fm.removeItem(atPath: bin + "/omacvm")
    try fm.createSymbolicLink(atPath: bin + "/omacvm", withDestinationPath: h + "/.omacvm/omacvm")
    expect(CommandLineInstall.state(path: p, home: h, appCLI: cli) == .other(at: bin + "/omacvm"), "disk: a checkout's dangling link kept")
    try fm.removeItem(atPath: tmp)
} catch {
    expect(false, "disk test: \(error)")
}

// MARK: Disk scripts parse as shell
for (name, script) in [("grow", DiskSize.growScript), ("compact", DiskSize.compactScript), ("usage", DiskSize.usageScript),
                       ("shrink", DiskSize.shrinkScript(fsBytes: 1 << 30)), ("unshrink", DiskSize.unshrinkScript), ("check", DiskSize.checkScript)] {
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-n", "-c", script]
    try? sh.run(); sh.waitUntilExit()
    expect(sh.terminationStatus == 0, "\(name) script: sh -n")
}

// MARK: Window height (the window itself: OmacVM --render-vm-window, a CI step)

expect(WindowFit.fitsSmallScreen(content: 700, titleBar: 28) && !WindowFit.fitsSmallScreen(content: 740, titleBar: 28),
       "13-inch MacBook: 760 pt with the title bar")
expect(WindowFit.contentHeight(content: 650, visible: 860, titleBar: 28) == 650, "fits: the whole content, no scrolling")
expect(WindowFit.contentHeight(content: 900, visible: 700, titleBar: 28) == 672, "too tall: stops at the screen, the rest scrolls")
expect(WindowFit.contentHeight(content: 900, visible: 200, titleBar: 28) == WindowFit.minimumContent, "a tiny screen: a few rows stay")
expect(CommandLineInstall.shortText(.installed(at: "/x")) == "Installed"
       && CommandLineInstall.shortText(.available(target: "/x", needsAdmin: true)) == "Not installed",
       "omacvm in Terminal: short text in the row, the rest in its (i)")

// MARK: Keyboard note

// QEMU's tap is an active one: only "control the computer" (Accessibility
// (keys) in the record, CGPreflightPostEventAccess now) counts.
let refused = "OmacVM: keys: Input Monitoring NOT allowed, Accessibility (keys) NOT allowed for OmacVM\nCould not create event tap\n"
// The user's MacBook, 2026-10-07: Input Monitoring on, Accessibility off.
let refusedWithIM = "OmacVM: keys: Input Monitoring allowed, Accessibility (keys) NOT allowed for OmacVM\nCould not create event tap\n"
let refusedWithAccess = "OmacVM: keys: Input Monitoring NOT allowed, Accessibility (keys) allowed for OmacVM\nCould not create event tap\n"
let fine = "OmacVM: keys: Input Monitoring allowed, Accessibility (keys) allowed for OmacVM\n"
let fineWithoutIM = "OmacVM: keys: Input Monitoring NOT allowed, Accessibility (keys) allowed for OmacVM\n"
expect(KeyNote.decide(allowedNow: false, lastLog: nil) == .needsUser, "not allowed: the red note")
expect(KeyNote.decide(allowedNow: false, lastLog: refusedWithIM) == .needsUser,
       "Input Monitoring on, Accessibility off, tap refused: needs Accessibility")
expect(KeyNote.decide(allowedNow: true, lastLog: refusedWithIM) == .allowedNextStart,
       "Accessibility allowed after a start with Input Monitoring only: next start, not red")
expect(KeyNote.decide(allowedNow: true, lastLog: refused) == .allowedNextStart, "allowed since the last start: next start")
expect(KeyNote.decide(allowedNow: true, lastLog: refusedWithAccess) == .needsUser, "allowed at that start and still refused: red")
expect(KeyNote.decide(allowedNow: true, lastLog: "Could not create event tap\n") == .allowedNextStart, "old log without a record: next start")
expect(KeyNote.decide(allowedNow: true, lastLog: fine) == .none, "allowed and the tap worked: nothing")
expect(KeyNote.decide(allowedNow: true, lastLog: fineWithoutIM) == .none, "Accessibility alone, the tap worked: nothing")
expect(KeyNote.decide(allowedNow: false, lastLog: fine) == .needsUser, "taken away since the last start: red")
expect(KeyNote.decide(allowedNow: true, lastLog: nil) == .none, "allowed, no start yet: nothing")
expect(KeyNote.startHadAccess(refused) == false && KeyNote.startHadAccess(fine) == true
       && KeyNote.startHadAccess(refusedWithIM) == false && KeyNote.startHadAccess(refusedWithAccess) == true
       && KeyNote.startHadAccess("x") == nil, "the record read: Accessibility (keys) only")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
