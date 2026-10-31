// The VM window's rules (OmacVMWindow), without a VM or the app:
//   cd app/app && swift run window-tests
// Custom resources, the disk's size (slider bounds, smaller in steps), "omacvm in Terminal", the window's
// height, the keyboard note, the SSH repair. Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMIcon
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
// A VM copied from a bigger Mac (16 CPUs, 48 GB onto an 8 GB MacBook Air): it starts at Best.
let airBest = (cpus: 8, memoryGB: 4)
expect(air.startSize(cpus: 16, memoryMB: 48 * 1024, best: airBest)! == (8, 4096), "16 CPUs, 48 GB on an 8 GB Mac: starts at Best (8 CPUs, 4 GB)")
expect(air.startSize(cpus: 4, memoryMB: 48 * 1024, best: airBest)! == (4, 4096), "only the memory too big: the CPUs stay")
expect(air.startSize(cpus: 12, memoryMB: 4096, best: airBest)! == (8, 4096), "only the CPUs too many: the memory stays")
expect(air.startSize(cpus: 8, memoryMB: 6 * 1024, best: airBest) == nil, "within the limits (6 GB on 8 GB): as vm.env says")
expect(m4.startSize(cpus: 16, memoryMB: 48 * 1024, best: (16, 96)) == nil, "on the Mac it came from: as vm.env says")
expect(air.startSizeText(cpus: 16, memoryMB: 48 * 1024, start: (8, 4096)).contains("starts with 8 CPUs and 4 GB here"), "the note says what it starts with")
let mini = ResourceLimits(macCores: 10, macMemoryGB: 16)
expect(mini.memoryGB == 4...14 && ResourceLimits(macCores: 12, macMemoryGB: 64).memoryGB == 4...56, "16 GB Mac: up to 14 GB; 64 GB Mac: up to 56 GB")
expect(mini.safeMemoryGB == 8, "16 GB Mac: safe up to 8 GB")
// The maintainer's Mac mini (16 GB, 5K, 2026-10-30): 12 GB set, graphics peak 4619 MB, Activity Monitor 23 GB.
// The warning names the graphics on top with the last run's peak and the Best tier, and never changes the setting.
expect(mini.warning(memoryGB: 12, graphicsPeakMB: 4619) == "12 GB and the VM's graphics on top (peak 4.5 GB last run) leave macOS "
       + "too little of this Mac's 16 GB: the Mac can slow down or swap, and apps in the VM can lose their graphics. "
       + "8 GB is this Mac's Best tier.", "16 GB Mac, 12 GB: the graphics on top with the last run's peak, the Best tier")
expect(mini.warning(memoryGB: 9)?.contains("graphics on top leave macOS too little of this Mac's 16 GB") == true,
       "no run yet: no peak, still the graphics on top")
expect(mini.warning(memoryGB: 8, graphicsPeakMB: 4619) == nil, "16 GB Mac, 8 GB (Best): no warning, whatever the graphics")
expect(air.warning(memoryGB: 6, graphicsPeakMB: 800)?.contains("(peak 800 MB last run)") == true
       && air.warning(memoryGB: 6)?.hasSuffix("4 GB is this Mac's Best tier.") == true, "8 GB Mac: its own Best tier")
expect(m4.warning(memoryGB: 97, graphicsPeakMB: 0)?.contains("(peak") == false, "a peak of 0 (nothing drawn yet): not said")
// The window pictures draw the warning 2 GB above this Mac's Best tier (RenderVMWindow: window-26-memory-above-best).
let m1Max = ResourceLimits(macCores: 10, macMemoryGB: 32)
expect(air.aboveBestGB == 6 && mini.aboveBestGB == 10 && m1Max.aboveBestGB == 26 && m4.aboveBestGB == 98,
       "the pictures' memory above Best: 8 GB Mac 6, 16 GB 10, 32 GB 26, 128 GB 98")
for l in [air, mini, m1Max, m4] {
    expect(l.aboveBestGB.map { l.memoryGB.contains($0) && l.warning(memoryGB: $0) != nil } == true,
           "\(l.macMemoryGB) GB Mac: \(l.aboveBestGB ?? 0) GB is allowed and warns")
}
expect(ResourceLimits(macCores: 8, macMemoryGB: 4).aboveBestGB == nil, "steppers that end at Best: no value above it")

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

// MARK: Window size (the window itself: OmacVM --render-vm-window, a CI step)

expect(WindowSize.width == 800 && WindowSize.sidebar == 200 && WindowSize.minHeight == 500, "800 pt wide, 200 pt sidebar, 500 pt at least")
expect(WindowSize.defaultHeight(visible: WindowSize.smallScreenVisible) == 760, "13-inch MacBook Air: 760 pt (as tall as before 3.1)")
expect(WindowSize.defaultHeight(visible: 1400) == 800, "a 5K display: 800 pt at most, centred (it looked stretched as tall as the screen)")
expect(WindowSize.defaultHeight(visible: 830) == 798, "a screen a little taller than the Air's: its height less the margins")
expect(WindowSize.defaultHeight(visible: 400) == 500, "a tiny screen: never below 500 pt")
// Fill (title-bar double-click) made the window 1920 pt wide on a 1920 pt display: back to 800, centred.
expect(WindowSize.fixedWidth(x: 0, width: 1920) == (560, 800), "a filled window: 800 pt wide again, in the middle")
expect(WindowSize.fixedWidth(x: 100, width: 800) == (100, 800), "an 800 pt window stays where it is")

// MARK: The sidebar follows the scroll (ScrollSpy)

// The settings page as the window lays it out (measured in 3.1.0, a stopped
// VM): five sections, their headings in the content, and the content's height
// (General, Display, Input, Sharing & Devices, Storage & Updates; the last two
// never reach the top).
let spyTops: [Double] = [14, 259, 734, 963, 1170]
let spyContent = 1548.0
// The visible part under the 52 pt header: the 500 pt minimum, a 13-inch
// MacBook Air (760 and 860 pt windows), a tall window, and the Air with the
// update banner (52 + 52 pt).
for window: Double in [500, 760, 860, 1400, 808] {
    let viewport = window - 52
    let maxOffset = spyContent - viewport
    func at(_ offset: Double) -> Int { ScrollSpy.current(tops: spyTops, offset: offset, maxOffset: maxOffset, viewport: viewport) }
    expect(at(0) == 0, "\(Int(window)) pt window: at the top, General")
    expect(at(maxOffset) == 4, "\(Int(window)) pt window: at the very bottom, the last section")
    // A slow scroll down marks every section once, in order.
    var seen: [Int] = []
    var offset = 0.0
    while offset <= maxOffset {
        let i = at(offset)
        if seen.last != i { seen.append(i) }
        offset += 0.5
    }
    if seen.last != at(maxOffset) { seen.append(at(maxOffset)) }
    expect(seen == [0, 1, 2, 3, 4], "\(Int(window)) pt window: scrolling down marks each section once, in order (\(seen))")
    // Scrolling back up goes back through them.
    var back: [Int] = []
    offset = maxOffset
    while offset >= 0 {
        let i = at(offset)
        if back.last != i { back.append(i) }
        offset -= 0.5
    }
    expect(back == [4, 3, 2, 1, 0], "\(Int(window)) pt window: scrolling back up, in reverse (\(back))")
    // Mid-page (before the last stretch): the section whose heading passed the
    // line 90 pt below the top, as usual. (The 1400 pt window scrolls less than
    // its height: its whole scroll is the last stretch.)
    let stretchStart = maxOffset - min(maxOffset, viewport - 90)
    var usual = true
    offset = 0
    while offset <= stretchStart {
        let line = spyTops.lastIndex { $0 <= offset + 90 } ?? 0
        if at(offset) != line { usual = false }
        offset += 0.5
    }
    expect(usual, "\(Int(window)) pt window: mid-page, the section at the 90 pt line (up to \(Int(stretchStart)) of \(Int(maxOffset)) pt)")
}
// Mid-page examples: Display's heading at the line marks Display, half a point
// before not yet (760 pt window); in the 500 pt window the same for Input.
expect(ScrollSpy.current(tops: spyTops, offset: 169, maxOffset: spyContent - 708, viewport: 708) == 1
       && ScrollSpy.current(tops: spyTops, offset: 168.5, maxOffset: spyContent - 708, viewport: 708) == 0,
       "760 pt window: Display marked when its heading reaches the line, not before")
expect(ScrollSpy.current(tops: spyTops, offset: 644, maxOffset: spyContent - 448, viewport: 448) == 2
       && ScrollSpy.current(tops: spyTops, offset: 643.5, maxOffset: spyContent - 448, viewport: 448) == 1,
       "500 pt window: Input marked when its heading reaches the line, not before")
// Near the top the line is 90 pt down, as before: a section 80 pt down counts, one 120 pt down not yet.
expect(ScrollSpy.current(tops: [0, 80, 1000], offset: 0, maxOffset: 2000, viewport: 700) == 1, "top: a section 80 pt down is marked")
expect(ScrollSpy.current(tops: [0, 120, 1000], offset: 0, maxOffset: 2000, viewport: 700) == 0, "top: a section 120 pt down not yet")
// The probe: 90 pt down until the last stretch (here from 1390 of 2000), then
// twice as fast to the content's end; a scroll shorter than that moves it all
// the way.
expect(ScrollSpy.probe(offset: 0, maxOffset: 2000, viewport: 700) == 90, "the probe: 90 pt down at the top")
expect(ScrollSpy.probe(offset: 1000, maxOffset: 2000, viewport: 700) == 1090
       && ScrollSpy.probe(offset: 1390, maxOffset: 2000, viewport: 700) == 1480,
       "the probe: still 90 pt down mid-page and where the last stretch starts")
expect(ScrollSpy.probe(offset: 1695, maxOffset: 2000, viewport: 700) == 2090, "the probe: halfway through the last stretch, halfway down")
expect(ScrollSpy.probe(offset: 2000, maxOffset: 2000, viewport: 700) == 2700, "the probe: the content's end at the bottom")
expect(ScrollSpy.probe(offset: 150, maxOffset: 300, viewport: 700) == 545
       && ScrollSpy.probe(offset: 300, maxOffset: 300, viewport: 700) == 1000,
       "the probe: a short scroll (300 pt) moves it all the way, to the end at the bottom")
// Everything fits (a tall window): nothing scrolls, the first section is marked.
expect(ScrollSpy.current(tops: [10, 300, 500], offset: 0, maxOffset: -400, viewport: 1348) == 0, "it all fits: the first section")
expect(ScrollSpy.current(tops: [], offset: 0, maxOffset: 100, viewport: 500) == 0, "no sections: the first")

// A click marks its section at once and keeps it, also when the page cannot
// bring the heading to the top, until a scroll by hand.
var pin = ScrollSpyPin()
expect(pin.marked(2) == 2, "no click: the scroll decides")
pin.click(4)
expect(pin.marked(1) == 4, "click on Storage & Updates: marked at once")
pin.moved()
expect(pin.marked(2) == 4, "the click's own scroll does not unmark it")
pin.clickScrollEnded()
expect(pin.marked(3) == 4, "after the click's scroll, at the end: still the clicked one")
pin.moved()
expect(pin.marked(3) == 3, "then a move (the keyboard, the scroll bar): the scroll decides again")
pin.click(3)
pin.scrolledByHand()
expect(pin.marked(4) == 4, "a scroll by hand while the click's scroll runs: the scroll decides")
pin.click(1)
pin.clickScrollEnded()
expect(pin.marked(0) == 1, "nothing to scroll (it all fits): the click selects and stays")

// MARK: Settings 3.1 adds (the plan's contract keys)

expect(CloseAction.key == "closeAction" && CloseAction.parse(nil) == .shutdown, "closeAction: not set = shut down")
expect(CloseAction.parse("keepRunning") == .keepRunning && CloseAction.parse("ask") == .ask && CloseAction.parse("shutdown") == .shutdown,
       "closeAction: the three words")
expect(CloseAction.parse("KeepRunning") == .shutdown && CloseAction.parse(1) == .shutdown, "closeAction: anything else = shut down")
expect(CloseAction.allCases.map(\.rawValue) == ["shutdown", "keepRunning", "ask"], "closeAction: the values QEMU gets")
expect(SwipeOut.key == "SwipeOut" && !SwipeOut.isOn(stored: nil), "SwipeOut: not set = off")
expect(SwipeOut.isOn(stored: true) && SwipeOut.isOn(stored: 1) && SwipeOut.isOn(stored: "YES") && SwipeOut.isOn(stored: "true")
       && SwipeOut.isOn(stored: "1"), "SwipeOut: a bool, a number, true or yes (as CFPreferences reads it)")
expect(!SwipeOut.isOn(stored: false) && !SwipeOut.isOn(stored: 0) && !SwipeOut.isOn(stored: "no") && !SwipeOut.isOn(stored: "off"),
       "SwipeOut: false, 0, no: off")
expect(IconTheme.key == "appIconTheme" && IconTheme.choice(stored: nil).isDefault, "appIconTheme: not set = OmacVM's own icon")
expect(IconTheme.choice(stored: "flexoki-light").name == "Flexoki Light" && IconTheme.choice(stored: "nope").isDefault,
       "appIconTheme: a theme's id, anything else the default")
expect(IconTheme.all.count == 8 && IconTheme.all.filter(\.dark).count == 4 && IconTheme.all.prefix(4).allSatisfy(\.dark),
       "eight looks: four dark first, four light")
expect(Set(IconTheme.all.map(\.id)).count == 8 && IconTheme.all.filter { !$0.isDefault }.allSatisfy { $0.colors != nil },
       "each look has its own id and colours")
expect(IconTheme.mark.count == 43 && IconTheme.mark.allSatisfy { $0.count == 4 && $0[0] >= 330 && $0[0] + $0[2] <= 694 },
       "Omarchy's mark: 43 rectangles inside the pad")
expect(DeleteConfirm.matches(typed: "Omarchy", name: "Omarchy"), "Delete: the exact name")
expect(!DeleteConfirm.matches(typed: "omarchy", name: "Omarchy") && !DeleteConfirm.matches(typed: "Omarchy ", name: "Omarchy")
       && !DeleteConfirm.matches(typed: "", name: ""), "Delete: not another case, a space more, or nothing")

// The keys in a settings domain, as the app reads and writes them.
let suite = "org.omacvm.test.window-tests.\(getpid())"
if let d = UserDefaults(suiteName: suite) {
    expect(CloseAction.parse(d.object(forKey: CloseAction.key)) == .shutdown && !SwipeOut.isOn(stored: d.object(forKey: SwipeOut.key))
           && IconTheme.choice(stored: d.object(forKey: IconTheme.key)).isDefault, "an empty domain: every default")
    d.set(CloseAction.ask.rawValue, forKey: CloseAction.key)
    d.set(true, forKey: SwipeOut.key)
    d.set("gruvbox", forKey: IconTheme.key)
    let again = UserDefaults(suiteName: suite)!
    expect(CloseAction.parse(again.object(forKey: CloseAction.key)) == .ask && SwipeOut.isOn(stored: again.object(forKey: SwipeOut.key))
           && IconTheme.choice(stored: again.object(forKey: IconTheme.key)).id == "gruvbox", "written values read back")
    d.removePersistentDomain(forName: suite)
}

// MARK: What's New (the new app's own CHANGELOG.md)

let changelog = """
# Changelog

## Unreleased

- Not yet.

## 3.1.0

A new settings window.

- **One window** with a sidebar: General, Display.
  More on a second line.
- `Swipe out` to macOS (#342, by [@epicoun](https://github.com/epicoun)).

## 3.0.18

- Older.
"""
let news = WhatsNew.parse(changelog: changelog, version: "3.1.0")
expect(news?.intro == "A new settings window." && news?.items.count == 2, "3.1.0: its intro and its two items")
expect(news?.items.first == "**One window** with a sidebar: General, Display. More on a second line.", "an item's lines joined")
expect(news?.summary() == "A new settings window.", "the banner: the intro")
expect(WhatsNew.parse(changelog: changelog, version: "3.0.18")?.summary() == "Older.", "no intro: the first item")
expect(WhatsNew.parse(changelog: changelog, version: "3.0.9") == nil, "a version without a section: nothing")
expect(WhatsNew.parse(changelog: changelog, version: "3.0.1") == nil, "3.0.1 is not 3.0.18's prefix match")
expect(WhatsNew.plain("`Swipe out` to macOS (#342, by [@epicoun](https://github.com/epicoun)).") == "Swipe out to macOS (#342, by @epicoun).",
       "plain text: no Markdown marks")
let long = WhatsNew(intro: nil, items: ["OmacVM.app: the **start animation** plays again in full screen when the VM starts with the notch and a lot more words. Second."])
expect(long.summary(limit: 60)!.count <= 60 && long.summary(limit: 60)!.hasSuffix("…"), "a long first sentence is cut with …")
expect(WhatsNew(intro: nil, items: ["OmacVM.app: fixed. More."]).summary() == "OmacVM.app: fixed.", "the first sentence, not the app's name's dot")

// MARK: Window sides (the pictures' frames: OmacVM --render-vm-window)

expect(WindowLayout.width == 800 && WindowLayout.contentWidth == 552 && WindowLayout.inset == 16, "800 pt window, 552 pt of settings, 16 pt margin")
typealias Box = WindowLayout.Box
let even = [Box("title", minX: 92, maxX: 300), Box("update-vm", minX: 600, maxX: 690), Box("start", minX: 700, maxX: 784)]
expect(WindowLayout.problems(even, width: 800, trailing: ["start"]).isEmpty, "16 pt each side: fine")
let tight = [Box("title", minX: 4, maxX: 200), Box("start", minX: 700, maxX: 798)]
let found = WindowLayout.problems(tight, width: 800, trailing: [])
expect(found.contains { $0.hasPrefix("title: 4 pt from the left") }, "4 pt from the left edge: too close")
expect(found.contains { $0.hasPrefix("start: 2 pt from the right") }, "Start at the right edge: too close")
expect(WindowLayout.problems([Box("a", minX: 300, maxX: 760), Box("b", minX: 500, maxX: 740)], width: 800, trailing: ["a", "b"])
       .contains { $0.hasPrefix("right edges not on one line") }, "row ends 20 pt apart: not one line")
expect(WindowLayout.problems([Box("row", minX: -10, maxX: 900)], width: 800, trailing: []).count == 2, "past both edges")

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

// MARK: HDR row: the running VM's own start (HDRNote, #579)

// The head of qemu.log as Runner writes it: the "OmacVM: HDR:" line only when the switch was on at that start.
let head = "OmacVM: network: user\nOmacVM: keys: Input Monitoring allowed, Accessibility (keys) allowed for OmacVM\n"
let hdrOn = head + "OmacVM: HDR: on (10-bit, HDR where the window's display can show it)\nOmacVM: pointer layer: off\n"
let hdrSafe = head + "OmacVM: HDR: off (GPU safe mode)\n"
let noLine = head + "OmacVM: pointer layer: off\n"
expect(HDRNote.startAnswer(hdrOn)?.on == true, "the start's line: on")
expect(HDRNote.startAnswer(hdrSafe).map { !$0.on && $0.why == "GPU safe mode" } == true, "the start's line: off and why")
expect(HDRNote.startAnswer(noLine) == nil, "no line: started with the switch off")
expect(HDRNote.startAnswer(head + "OmacVM: HDR: off (switch off)\n") == nil, "off (switch off) reads as no HDR asked")
expect(HDRNote.startAnswer("cocoa: extra brightness: on, 2.00x, over HDR\n") == nil, "QEMU's own lines are not the start's answer")
let stillOn = HDRNote.note(switchOn: false, running: true, log: hdrOn)
expect(stillOn?.contains("still runs with HDR") == true && stillOn?.contains("restart inside the VM keeps it") == true,
       "switched off while the VM runs with HDR: says it still runs with HDR, and that a restart inside the VM keeps it")
let stillOff = HDRNote.note(switchOn: true, running: true, log: noLine)
expect(stillOff?.contains("runs without HDR") == true && stillOff?.contains("shut the VM down and start it again") == true,
       "switched on while the VM runs without: says when it comes")
expect(HDRNote.note(switchOn: true, running: true, log: hdrSafe) == "This start of the VM has no HDR: GPU safe mode.",
       "on, but this start had none: why")
expect(HDRNote.note(switchOn: true, running: true, log: hdrOn) == nil, "on and running with HDR: the usual subtitle")
expect(HDRNote.note(switchOn: false, running: true, log: noLine) == nil, "off and running without: the usual subtitle")
expect(HDRNote.note(switchOn: false, running: true, log: hdrSafe) == nil, "off, and the start had none either: the usual subtitle")
expect(HDRNote.note(switchOn: false, running: false, log: hdrOn) == nil, "not running: the usual subtitle (the log is an old start's)")
expect(HDRNote.note(switchOn: true, running: true, log: nil) == nil, "running without a log yet: nothing to say")
// The whole subtitle: the note in orange, and it wins over GPU safe mode's line (safe mode counts from the next start too).
let safeStillOn = HDRNote.subtitle(switchOn: true, safeMode: true, running: true, log: hdrOn)
expect(safeStillOn.isNote && safeStillOn.text.contains("still runs with HDR"),
       "GPU safe mode turned on while the VM runs with HDR: the note, not \"Off while GPU safe mode is on.\"")
expect(HDRNote.subtitle(switchOn: true, safeMode: true, running: true, log: hdrSafe) == ("Off while GPU safe mode is on.", false),
       "GPU safe mode, and this start had none: safe mode's line, grey")
expect(HDRNote.subtitle(switchOn: true, safeMode: true, running: false, log: nil) == ("Off while GPU safe mode is on.", false),
       "GPU safe mode, not running: safe mode's line")
expect(HDRNote.subtitle(switchOn: false, safeMode: false, running: true, log: hdrOn).isNote,
       "switched off while it runs with HDR: a note")
expect(HDRNote.subtitle(switchOn: true, safeMode: false, running: true, log: hdrOn) == (HDRNote.usual, false),
       "on and running with HDR: the usual line, grey")

// MARK: SSH repair (SSHRepair: the folder's key into a VM that knows only another Mac's)

let sshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOmacVMwindowTestKeyOnly0123456789abcdefghij omacvm-vm"
expect(SSHRepair.valid(sshKey), "ssh: a folder key is one valid line")
expect(SSHRepair.keyLine(pub: Data((sshKey + "\n").utf8)) == sshKey, "ssh: the .pub's line, its newline dropped")
expect(SSHRepair.keyLine(pub: Data((sshKey + "\nssh-ed25519 BBBB other\n").utf8)) == nil, "ssh: a .pub of two lines refused")
expect(!SSHRepair.valid(sshKey + "\r"), "ssh: a CR refused")
expect(!SSHRepair.valid("ssh-rsa AAAAB3NzaC1yc2E other"), "ssh: another key type refused")
expect(SSHRepair.valid("ssh-ed25519 " + String(repeating: "A", count: 188)), "ssh: 200 bytes taken")
expect(!SSHRepair.valid("ssh-ed25519 " + String(repeating: "A", count: 189)), "ssh: 201 bytes refused")
expect(!SSHRepair.valid("ssh-ed25519 AAAA\u{7}bell"), "ssh: a control character refused")
expect(!SSHRepair.valid("ssh-ed25519 AAAA$(reboot)"), "ssh: shell characters refused")
let sshCall = SSHRepair.command(key: sshKey)
expect(sshCall.path == "/bin/sh" && sshCall.args == ["-c", SSHRepair.script, "omacvm-key", sshKey], "ssh: the key goes in as $1 (argv), no shell around the call")
expect(!SSHRepair.script.contains("AAAA"), "ssh: no key inside the script")
for (r, word) in [(SSHRepair.Result.added, "added"), (.present, "present"), (.noAgent, "noagent"), (.failed("x"), "failed")] {
    expect(SSHRepair.answer(r) == word, "ssh: Update VM gets '\(word)'")
}
expect(SSHRepair.logLine(.added, stillRunning: true)?.contains("key added in the VM") == true, "ssh: qemu.log says when the key was added")
expect(SSHRepair.logLine(.present, stillRunning: true) == nil, "ssh: nothing logged when it was there")
expect(SSHRepair.logLine(.noAgent, stillRunning: false) == nil && SSHRepair.logLine(.noAgent, stillRunning: true) != nil,
       "ssh: no agent is logged only while the VM runs")
expect(SSHRepair.logLine(.failed("exit 1"), stillRunning: true)?.hasSuffix("exit 1") == true, "ssh: a failure says why")
expect(SSHRepair.logLine(.added, stillRunning: true)?.contains("another Mac") == false,
       "ssh: the added line names no cause (the folder's key may just have been made)")
let guestText = "refused\nOmacVM: SSH: fake line\u{1b}[2J" + String(repeating: "x", count: 300)
let guestLine = SSHRepair.logLine(.failed("the guest agent refused: " + guestText), stillRunning: true) ?? ""
expect(!guestLine.contains("\n") && !guestLine.contains("\u{1b}") && guestLine.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) },
       "ssh: the guest's error text reaches qemu.log as one printable line")
expect(SSHRepair.plain(guestText).count == 120 && SSHRepair.plain(guestText).hasSuffix("..."), "ssh: ... 120 characters at most")
expect(SSHRepair.plain("exit 1") == "exit 1", "ssh: plain text stays as it is")

// update-vm.sh's lines: only its own, in step 1 of an update, once each.
var sshLines = SSHRepair.Lines()
expect(sshLines.take("FIX ssh-key", update: false, step: 1) == nil, "ssh: a build's FIX line is ignored")
expect(sshLines.take("FIX ssh-key", update: true, step: 2) == nil, "ssh: FIX in step 2 (the guest's apply output) is ignored")
expect(sshLines.take("FIX ssh-key ERROR", update: true, step: 1) == nil, "ssh: only the exact line counts")
expect(sshLines.take("FIX ssh-key", update: true, step: 1) == .fix, "ssh: FIX in step 1 of an update: the repair")
expect(sshLines.take("FIX ssh-key", update: true, step: 1) == nil, "ssh: the repair once per run")
expect(sshLines.take("SSHKEY refused", update: true, step: 2) == nil, "ssh: SSHKEY refused in step 2 is ignored")
expect(sshLines.take("SSHKEY refused", update: true, step: 1) == .refused, "ssh: SSHKEY refused in step 1: Copy Command")
var nextRun = SSHRepair.Lines()   // Creator.reset
expect(nextRun.take("FIX ssh-key", update: true, step: 1) == .fix, "ssh: the next run asks again")

// The guest script under sh, root's folder in a temp folder.
do {
    let fm = FileManager.default
    let tmp = (fm.temporaryDirectory.appendingPathComponent("ssh-repair-\(getpid())").path as NSString).resolvingSymlinksInPath
    try? fm.removeItem(atPath: tmp)
    try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }
    let file = tmp + "/root/.ssh/authorized_keys"
    let script = SSHRepair.script.replacingOccurrences(of: "/root/.ssh", with: tmp + "/root/.ssh")
    func guest(_ key: String) -> (Int32, String) {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "omacvm-key", key]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    func mode(_ path: String) -> Int { ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1 }
    func lines() -> [String] { ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    let first = guest(sshKey)
    expect(first.0 == 0 && first.1 == "added", "ssh script: added (\(first))")
    expect(mode(tmp + "/root/.ssh") == 0o700 && mode(file) == 0o600, "ssh script: folder 700, file 600")
    let again = guest(sshKey)
    expect(again.0 == 0 && again.1 == "present" && lines() == [sshKey], "ssh script: present, no second line")
    let rsa = guest("ssh-rsa AAAAB3NzaC1yc2E other")
    expect(rsa.0 == 2 && rsa.1 == "bad" && lines() == [sshKey], "ssh script: another key type: bad, nothing written")
    let pwned = tmp + "/pwned"
    let injected = guest("ssh-ed25519 AAAA$(touch \(pwned))")
    expect(injected.0 == 2 && !fm.fileExists(atPath: pwned) && lines() == [sshKey], "ssh script: a key with $(...) runs nothing")
    let two = guest("ssh-ed25519 AAAA\nssh-ed25519 BBBB")
    expect(two.0 == 2 && lines() == [sshKey], "ssh script: two lines: bad")
    let long = guest("ssh-ed25519 " + String(repeating: "A", count: 189))
    expect(long.0 == 2 && lines() == [sshKey], "ssh script: over 200 bytes: bad")
    try Data("ssh-ed25519 OTHERKEY other-mac".utf8).write(to: URL(fileURLWithPath: file))   // no newline at its end
    let other = guest(sshKey)
    expect(other.1 == "added" && lines() == ["ssh-ed25519 OTHERKEY other-mac", sshKey], "ssh script: another Mac's key stays on its own line")
} catch {
    expect(false, "ssh script test: \(error)")
}

// Copy Command: the same command as src/lib/vm.sh's ssh_setup_command for app VMs.
do {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pub = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-repair-\(getpid()).pub")
    try Data((sshKey + "\n").utf8).write(to: pub)
    defer { try? FileManager.default.removeItem(at: pub) }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "eval \"$(sed -n '/^ssh_setup_command()/,/^}/p' \"$1\")\"; ssh_setup_command app \"$2\"", "bash",
                   repo.appendingPathComponent("src/lib/vm.sh").path, pub.path]
    p.standardOutput = out
    try p.run()
    let shell = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    expect(!shell.isEmpty && SSHRepair.manualCommand(key: sshKey) == shell, "ssh: Copy Command = ssh_setup_command app with the folder's key")
    expect(SSHRepair.manualCommand(key: "ssh-ed25519 AAAA\"; reboot; \"") == nil, "ssh: no command from a key that is not one")
} catch {
    expect(false, "ssh command test: \(error)")
}

// MARK: Extra brightness (ADR 0050): the row only with a display above 2x; the start's answer.

expect(!ExtraBrightness.available(potentials: [1]), "extra brightness: an SDR monitor (potential 1): no row")
expect(!ExtraBrightness.available(potentials: [2]), "extra brightness: a MacBook Air (potential 2): no row")
expect(ExtraBrightness.available(potentials: [16]), "extra brightness: an XDR panel (potential 16): the row")
expect(ExtraBrightness.available(potentials: [1, 16]), "extra brightness: an SDR monitor beside an XDR panel: the row")
expect(!ExtraBrightness.available(potentials: []) && !ExtraBrightness.available(potentials: [.nan, .infinity]),
       "extra brightness: no displays or no numbers: no row")
expect(ExtraBrightness.minPotential == 2.05, "extra brightness: the same threshold as QEMU (OMACVM_BRIGHT_MIN_POTENTIAL)")
expect(ExtraBrightness.start(on: false, display: true, gpuSafeMode: false, layerPresent: false) == (false, "switch off"),
       "extra brightness: switch off")
expect(ExtraBrightness.start(on: true, display: false, gpuSafeMode: false, layerPresent: false).on == false,
       "extra brightness: no display with the headroom: off")
expect(ExtraBrightness.start(on: true, display: true, gpuSafeMode: true, layerPresent: false) == (false, "GPU safe mode"),
       "extra brightness: GPU safe mode: off, and says so")
expect(ExtraBrightness.start(on: true, display: true, gpuSafeMode: false, layerPresent: true).on == false,
       "extra brightness: frames in a CAOpenGLLayer: off")
expect(ExtraBrightness.start(on: true, display: true, gpuSafeMode: false, layerPresent: false).on,
       "extra brightness: switch on, an XDR display: on")

// MARK: The VM's own Extra brightness switch (its Display panel): /omacvm/app/extra-brightness, the app's answer.

let ebPath = ExtraBrightnessGuest.path
let ebFront = ExtraBrightnessGuest.Context(display: true, safeMode: false, front: true, on: false)
func ebBody(_ s: String) -> Data { Data(s.utf8) }
func ebDecide(_ method: String, _ path: String = ebPath, _ body: String? = nil,
              _ c: ExtraBrightnessGuest.Context = ebFront, allowed: Bool = true) -> ExtraBrightnessGuest.Decision {
    ExtraBrightnessGuest.decide(method: method, path: path, body: body.map(ebBody), c) { allowed }
}
expect(ebDecide("GET") == .answer, "VM switch: GET answers the state")
let ebState = ExtraBrightnessGuest.state(ExtraBrightnessGuest.Context(display: true, safeMode: true, front: false, on: true))
expect(ebState["display"] as? Bool == true && ebState["safe_mode"] as? Bool == true && ebState["on"] as? Bool == true
       && ebState["available"] as? Bool == false && ebState.count == 4,
       "VM switch: the state is {display, safe_mode, on, available}; GPU safe mode: not available")
expect(ExtraBrightnessGuest.state(ebFront)["available"] as? Bool == true, "VM switch: an XDR display, no safe mode: available")
expect(ebDecide("POST", ebPath, #"{"on": true}"#) == .set(true) && ebDecide("POST", ebPath, #"{"on": false}"#) == .set(false),
       "VM switch: POST {\"on\": true|false} sets it")
for bad in [#"{"on": 1}"#, #"{"on": 0}"#, #"{"on": "true"}"#, #"{"on": null}"#, #"{}"#, #"{"on": true, "x": 1}"#,
            #"{"On": true}"#, #"[true]"#, "true", ""] {
    expect(ebDecide("POST", ebPath, bad) == .refuse(400, "bad-request"), "VM switch: body \(bad.isEmpty ? "(empty)" : bad): 400")
}
expect(ebDecide("POST") == .refuse(400, "bad-request"), "VM switch: POST without a body: 400")
expect(ebDecide("GET", ebPath, #"{"on": true}"#) == .refuse(400, "bad-request"), "VM switch: GET with a body: 400")
for p in [ebPath + "?x", ebPath + "/", ebPath + "s", "/omacvm/app/", "/omacvm/app/hdr", "/omacvm/app/extra-brightness/on"] {
    expect(ebDecide("GET", p) == .refuse(404, "not-found") && ExtraBrightnessGuest.isApp(p),
           "VM switch: \(p): 404, and the app's own (never relayed)")
}
expect(!ExtraBrightnessGuest.isApp("/omacvm/status") && !ExtraBrightnessGuest.isApp("/omacvm/apps")
       && !ExtraBrightnessGuest.isApp("/omacvm/app-update"), "VM switch: the Bridge's requests still go on (app-update too)")
expect(ebDecide("POST", ebPath, #"{"on": true}"#, ExtraBrightnessGuest.Context(display: false, safeMode: false, front: true, on: false))
       == .refuse(409, "no-display"), "VM switch: no XDR display: 409")
expect(ebDecide("POST", ebPath, #"{"on": true}"#, ExtraBrightnessGuest.Context(display: true, safeMode: true, front: true, on: false))
       == .refuse(409, "safe-mode"), "VM switch: GPU safe mode (this run): 409")
expect(ebDecide("POST", ebPath, #"{"on": true}"#, ExtraBrightnessGuest.Context(display: true, safeMode: false, front: false, on: false))
       == .refuse(409, "not-front"), "VM switch: a VM whose window is not in front: 409 (it would switch the one the user looks at)")
expect(ebDecide("GET", ebPath, nil, ExtraBrightnessGuest.Context(display: true, safeMode: false, front: false, on: true)) == .answer,
       "VM switch: reading needs no window in front")
expect(ebDecide("POST", ebPath, #"{"on": true}"#, allowed: false) == .refuse(429, "busy"), "VM switch: over the rate: 429")
expect(ebDecide("PUT") == .refuse(405, "method"), "VM switch: other methods: 405")
var ebAsked = false
_ = ExtraBrightnessGuest.decide(method: "POST", path: ebPath, body: ebBody(#"{"on": 2}"#), ebFront) { ebAsked = true; return true }
expect(!ebAsked, "VM switch: a refused request does not count against the rate")
var rate = WriteRate()
expect((0..<4).allSatisfy { rate.take(at: 10 + Double($0) * 0.1) } && !rate.take(at: 10.5),
       "VM switch: 4 writes in a second, the 5th refused")
expect(rate.take(at: 11.05), "VM switch: a second after the first: allowed again")
var rate2 = WriteRate()
expect(rate2.take(at: 100) && rate2.take(at: 50), "VM switch: the clock going back does not lock it")

// MARK: The switch keeps the user's setting: only a POST from the user's own switch writes, and only the value it names.

var ebContexts: [ExtraBrightnessGuest.Context] = []
for display in [false, true] { for safe in [false, true] { for front in [false, true] { for on in [false, true] {
    ebContexts.append(ExtraBrightnessGuest.Context(display: display, safeMode: safe, front: front, on: on))
} } } }
var ebReadWrites = 0, ebReadAsked = 0, ebWrongValue = 0, ebStateLies = 0
for c in ebContexts {
    // Reading (the panel opening, its 1 s refresh, `omacvm extra-brightness`) never writes and never takes a write slot.
    if case .set = ExtraBrightnessGuest.decide(method: "GET", path: ebPath, body: nil, c, writeAllowed: { ebReadAsked += 1; return true }) {
        ebReadWrites += 1
    }
    // A write is exactly the value the switch sent, whatever the switch is now: never a toggle, never a default.
    for want in [false, true] {
        let d = ExtraBrightnessGuest.decide(method: "POST", path: ebPath, body: ebBody(want ? #"{"on": true}"# : #"{"on": false}"#), c) { true }
        if case .set(let v) = d, v != want { ebWrongValue += 1 }
    }
    // The answer is the stored switch as it is, also with no display or GPU safe mode (the panel shows the user's setting).
    if ExtraBrightnessGuest.state(c)["on"] as? Bool != c.on { ebStateLies += 1 }
}
expect(ebReadWrites == 0 && ebReadAsked == 0, "VM switch: reading never writes, in any state (16 cases)")
expect(ebWrongValue == 0, "VM switch: a write is the value sent, never the opposite or a default")
expect(ebStateLies == 0, "VM switch: the answer's on is the stored switch, also without a display or in GPU safe mode")
let ebRefused = ebContexts.filter { !$0.display || $0.safeMode || !$0.front }
expect(ebRefused.allSatisfy { c in
    [#"{"on": true}"#, #"{"on": false}"#].allSatisfy {
        if case .refuse(409, _) = ExtraBrightnessGuest.decide(method: "POST", path: ebPath, body: ebBody($0), c, writeAllowed: { true }) { return true }
        return false
    }
}, "VM switch: no display, GPU safe mode or another VM in front: refused, the stored switch stays")
expect(ExtraBrightness.start(on: true, display: false, gpuSafeMode: false, layerPresent: false).why == "no display with extra brightness"
       && ExtraBrightness.start(on: true, display: true, gpuSafeMode: true, layerPresent: false).why == "GPU safe mode",
       "extra brightness: a start without it says why; the switch is not touched (the start only reads it)")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
