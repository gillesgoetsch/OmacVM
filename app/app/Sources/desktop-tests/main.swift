// "Restart the Desktop…" after Later, the graphics memory file and what the app
// says about a lost GPU context (OmacVMDesktop), without a VM:
//   cd app/app && swift run desktop-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMDesktop

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

let logs = FileManager.default.temporaryDirectory
    .appendingPathComponent("omacvm-desktop-tests-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: logs)
try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: logs) }
let d = DesktopRestart(logs: logs, bundleID: "org.omacvm.app.test", pid: 4242)

expect(d.lost.lastPathComponent == "desktop-lost", "the file name QEMU's patch is given")
expect(d.requestName == "org.omacvm.app.test.desktop-restart.4242", "request name: bundle id and pid")
expect(DesktopRestart(logs: logs, bundleID: nil, pid: 7).requestName == "org.omacvm.app.desktop-restart.7",
       "no bundle id: the release id")
expect(d.requestName != DesktopRestart(logs: logs, bundleID: "org.omacvm.app.test", pid: 4243).requestName,
       "another running app (another VM) has another name")
expect(d.requestName.hasSuffix(".4242") && !d.requestName.contains("features"), "not the Features… name")

expect(!d.isLost && !d.takesRequest(), "a new VM: no menu item, a click does nothing")

// Later, then the menu item.
expect(d.markLost("Hyprland lost its GPU context; Later"), "Later writes desktop-lost")
expect(d.isLost && d.takesRequest(), "the menu item shows and a click counts")
expect((try? String(contentsOf: d.lost, encoding: .utf8)) == "Hyprland lost its GPU context; Later\n", "with why in it")
expect(d.markLost("again") && d.isLost, "a second Later keeps it")

// Restart the Desktop, or the VM starts or stops.
d.clear()
expect(!d.isLost && !d.takesRequest(), "clear: no menu item, a late click does nothing")
d.clear()
expect(!d.isLost, "clear twice is fine")

// A folder where the file should be is not "lost" (QEMU checks a plain file too).
try FileManager.default.createDirectory(at: d.lost, withIntermediateDirectories: false)
expect(!d.isLost, "a folder named desktop-lost does not count")
try? FileManager.default.removeItem(at: d.lost)

// No logs folder (the VM folder went away): nothing breaks.
let gone = DesktopRestart(logs: logs.appendingPathComponent("missing"), bundleID: nil, pid: 1)
expect(!gone.markLost("x") && !gone.isLost, "a missing logs folder: false, no crash")
gone.clear()

// QEMU's logs/gpu-memory (GPUMemory): the desktop reserve and why contexts were lost
// (virgl-gpu-guard-desktop-reserve.patch).
let status = """
    in_use_mb=6100
    peak_mb=6144
    budget_mb=6144
    pressure=normal
    refused=3
    lost=3
    lost_last=chromium
    lost_recent=quickshell,Hyprland,chromium
    apps_mb=5632
    reserve_mb=512
    lost_why=guard
    lost_recent_why=error,guard,guard

    """
let gm = GPUMemory.parse(status)
expect(gm?.appsMB == 5632 && gm?.reserveMB == 512 && gm?.budgetMB == 6144, "apps_mb, reserve_mb, budget_mb read")
expect(gm?.lostRecentWhy == ["error", "guard", "guard"], "lost_recent_why read")
expect(gm?.why(of: DesktopRecovery.compositors) == "guard", "why Hyprland was lost: guard")
expect(gm?.why(of: DesktopRecovery.shells) == "error", "why quickshell was lost: error")
expect(gm?.why(of: ["firefox"]) == nil, "a context not lost: nil")
expect(gm?.lostReason == "Its graphics reached the most one VM may use on this Mac (6.0 GB, even with the 512 MB kept for the desktop).",
       "the alert names the budget and the desktop's part")
var gp = gm!
gp.lostRecentWhy = ["error", "pressure", "guard"]
expect(gp.lostReason == "macOS ran short of memory for its graphics.", "lost for pressure: macOS short of memory")
gp.lostRecentWhy = ["error", "error", "guard"]
expect(gp.lostReason == "Its graphics on the Mac failed.", "lost for another reason: failed, even at the budget")
expect(DesktopRecovery.reason(why: "guard", pressure: "normal", refused: 3) == "guard", "the VM's note: guard")
expect(DesktopRecovery.reason(why: "pressure", pressure: "normal", refused: 0) == "memory", "pressure: memory")
expect(DesktopRecovery.reason(why: "error", pressure: "critical", refused: 9) == "graphics", "error: graphics, whatever else")
expect(DesktopRecovery.reason(why: nil, pressure: "normal", refused: 0) == "graphics", "older runtime, nothing refused: graphics")
expect(DesktopRecovery.reason(why: nil, pressure: "warn", refused: 0) == "memory", "older runtime, pressure: memory")
// An older runtime: no apps_mb, reserve_mb or why; the old guesses.
let old = GPUMemory.parse("in_use_mb=6000\nbudget_mb=6144\npressure=normal\nrefused=3\nlost=1\nlost_recent=Hyprland\n")
expect(old?.why(of: DesktopRecovery.compositors) == nil && old?.reserveMB == 0, "older runtime: no why, no reserve")
expect(old?.lostReason == "Its graphics reached the most one VM may use on this Mac (6.0 GB).", "older runtime at the budget: the budget")
var older = old!
older.inUseMB = 2000
expect(older.lostReason == "macOS ran short of memory for its graphics.", "older runtime, refused below the budget: macOS")
older.refused = 0
expect(older.lostReason == "Its graphics on the Mac failed.", "older runtime, nothing refused: failed")
// Lists of different length (a reader between two writes cannot get that, but): no why.
var odd = gm!
odd.lostRecentWhy = ["guard"]
expect(odd.why(of: DesktopRecovery.compositors) == nil, "why list of another length: not trusted")
expect(GPUMemory.parse("pressure=normal\n") == nil, "no in_use_mb: not a status file")

// Which apps the VM tells about (GPUMemoryNotice), looked at every 5 s as
// GPUMemoryWatch does. A tell reads "second:name:why", "@second" when it was
// kept from an earlier look.
do {
let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
func looks(_ n: inout GPUMemoryNotice, until: Int, _ losses: [Int: ([String], [String])],
           restartAt: Int? = nil) -> [String] {
    var out: [String] = []
    for s in stride(from: 0, through: until, by: 5) {
        if s == restartAt { n.sessionRestarted() }
        let (lost, why) = losses[s] ?? ([], [])
        for t in n.look(lost: lost, why: why, now: t0.addingTimeInterval(Double(s))) {
            out.append("\(s):\(t.name):\(t.why)" + (t.heldSince.map { "@\(Int($0.timeIntervalSince(t0)))" } ?? ""))
        }
    }
    return out
}
let c = (["chrome"], ["pressure"]), g = (["chrome"], ["guard"])

var n = GPUMemoryNotice()
let first = n.look(lost: ["chromium", "Hyprland", "quickshell", "firefox", "chromium", "mpv"],
                   why: ["guard", "guard", "pressure", "pressure", "guard", "error"], now: t0)
expect(first.map { "\($0.name):\($0.why)" } == ["chromium:guard", "firefox:pressure"],
       "apps lost to the guard or pressure, once each; not the desktop, the shell or another error")
n = GPUMemoryNotice()
expect(n.look(lost: ["chromium"], why: [], now: t0).isEmpty && n.waiting.isEmpty, "an older runtime (no why): nothing")

// R2 and A1h (chrome-lost-context rows): lost again 30 s after the note.
n = GPUMemoryNotice()
var r = looks(&n, until: 180, [0: c, 30: c])
expect(r == ["0:chrome:pressure", "60:chrome:pressure@30"],
       "a second loss 30 s after the first: told when the minute is over, with its own time (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 180, [0: g, 20: g, 40: c])
expect(r == ["0:chrome:guard", "60:chrome:pressure@40"], "two losses inside the minute: one tell, the newest (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 180, [0: c, 10: c, 20: c, 30: c])
expect(r == ["0:chrome:pressure", "60:chrome:pressure@30"], "three in a minute: one tell after it, not three (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 300, Dictionary(uniqueKeysWithValues: stride(from: 0, through: 300, by: 5).map { ($0, g) }))
expect(r == ["0:chrome:guard", "60:chrome:guard", "120:chrome:guard", "180:chrome:guard", "240:chrome:guard",
             "300:chrome:guard"], "a loss every 5 s for 5 minutes: once a minute (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 180, [0: c, 30: g, 60: c])
expect(r == ["0:chrome:pressure", "60:chrome:pressure"], "a kept loss and a new one as the minute ends: one tell (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 180, [0: c, 30: c], restartAt: 40)
expect(r == ["0:chrome:pressure"] && n.waiting.isEmpty, "the desktop restarted: the kept loss is void (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 180, [0: c, 30: (["Hyprland", "quickshell", "chrome"], ["guard", "pressure", "error"])])
expect(r == ["0:chrome:pressure"], "the desktop, the shell and other errors are never kept (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 180, [0: c, 30: c, 40: (["chrome", "firefox"], ["guard"])])
expect(r == ["0:chrome:pressure", "60:chrome:pressure@30"], "lists of another length: nothing new, the kept one told (\(r))")
n = GPUMemoryNotice()
r = looks(&n, until: 180, [0: (["b", "a"], ["guard", "guard"]), 20: (["chromium"], ["guard"]),
                           30: (["b", "a"], ["guard", "pressure"]), 50: (["chromium"], ["pressure"])])
expect(r == ["0:b:guard", "0:a:guard", "20:chromium:guard", "60:a:pressure@30", "60:b:guard@30", "80:chromium:pressure@50"],
       "each app its own minute; kept ones by name (\(r))")
n = GPUMemoryNotice()
_ = n.look(lost: (0..<50).map { "app\($0)" }, why: Array(repeating: "guard", count: 50), now: t0)
let busy = n.recent
_ = n.look(lost: [], why: [], now: t0.addingTimeInterval(GPUMemoryNotice.window))
expect(busy == 50 && n.recent == 0, "apps told are forgotten after their minute (\(busy) -> \(n.recent))")
}


do {
// Giving the VM's cold file cache back while macOS compresses the VM (MemoryGiveBack, ADR 0059).
let GB = MemoryGiveBack.gib, MB = MemoryGiveBack.mib
func sample(_ t: Double, fp: Double, res: Double, comp: Double) -> MemoryGiveBack.Sample {
    MemoryGiveBack.Sample(time: t, footprint: UInt64(fp * Double(GB)), resident: UInt64(res * Double(GB)),
                          compressed: UInt64(comp * Double(GB)))
}
// "compressing" needs a QEMU that gives the pages back to macOS (the reclaim fix, 3.2.12). 3.2.11's QEMU
// keeps what the VM gives back (Mac mini: 1345 of 1346 MB, 1721 of 1721 MB; vm-memory-gap), and a file read again
// takes fresh pages: a give-back would only make Activity Monitor's number smaller. Without it: never; the warning's
// drop as in 3.2.10 (once per 10 minutes). The rest of this block is a QEMU with the fix (behaviour unchanged).
func withFix(_ ram: UInt64) -> MemoryGiveBack { MemoryGiveBack(ram: ram, pagesGoBack: true) }
func warn(_ s: MemoryGiveBack.Sample) -> MemoryGiveBack.Sample { var w = s; w.normal = false; return w }
var keeps = MemoryGiveBack(ram: 64 * GB)
expect(!keeps.pagesGoBack, "a QEMU not known to give the pages back: it keeps them (the default)")
expect(!keeps.allowed(.compressing, at: 0) && keeps.allowed(.warning, at: 0) && keeps.allowed(.critical, at: 0),
       "it keeps them: never allowed for compressing, the warning's drop is")
_ = keeps.compressing(sample(0, fp: 30, res: 30, comp: 100))
var keepsFired = false
for i in 1...240 { keepsFired = keepsFired || keeps.compressing(sample(Double(i) * 5, fp: 30 + Double(i) * 0.1, res: 28, comp: 100 + Double(i) * 0.1)) }
expect(!keepsFired && !keeps.compressing(sample(1300, fp: 51, res: 28, comp: 130)),
       "it keeps them: the user's numbers (23 GB outside RAM, macOS compressing) never give back")
keeps.started(.warning, at: 2000)
keeps.answered(nil)
expect(!keeps.allowed(.warning, at: 2599) && keeps.allowed(.critical, at: 2600) && !keeps.allowed(.compressing, at: 9000),
       "it keeps them: the warning's drop once per 10 minutes, as in 3.2.10")
keeps.started(.warning, at: 3000)
keeps.noAnswer(at: 3001)
expect(keeps.allowed(.warning, at: 3031) && !keeps.allowed(.compressing, at: 3031), "a silent agent's retry is the warning's only")
// Which QEMU: the fix's text in its binary (like Graphics.qemuTakesSmallHighWindow); the fix's own switch off keeps them.
let qemuBin = logs.appendingPathComponent("qemu-bin")
try? Data(("\u{0}\u{1}junk" + MemoryGiveBack.reclaimMarker + "\u{0}more").utf8).write(to: qemuBin)
expect(MemoryGiveBack.qemuGivesPagesBack(binary: qemuBin, environment: [:]), "a QEMU with the fix's text gives the pages back")
expect(!MemoryGiveBack.qemuGivesPagesBack(binary: qemuBin, environment: ["OMACVM_RECLAIM_REUSABLE": "0"]),
       "the same QEMU with the fix switched off (OMACVM_RECLAIM_REUSABLE=0) keeps them")
expect(MemoryGiveBack.qemuGivesPagesBack(binary: qemuBin, environment: ["OMACVM_RECLAIM_REUSABLE": "1"]), "  =1: gives them back")
try? Data("HVF free-page backing replacement failed: %s".utf8).write(to: qemuBin)
expect(!MemoryGiveBack.qemuGivesPagesBack(binary: qemuBin, environment: [:]), "3.2.11's QEMU (the old reclaim patch only) keeps them")
try? Data(MemoryGiveBack.reclaimMarker.dropLast().utf8).write(to: qemuBin)
expect(!MemoryGiveBack.qemuGivesPagesBack(binary: qemuBin, environment: [:]), "part of the text is not the text")
expect(!MemoryGiveBack.qemuGivesPagesBack(binary: logs.appendingPathComponent("none"), environment: [:]), "no binary: keeps them")
// A real built QEMU (OMACVM_TEST_QEMU = an app's Contents/Resources/runtime/bin/OmacVM, or the runtime build's
// qemu-system-aarch64): the app's own probe finds the fix's text in it. Not in CI (no runtime there).
if let real = ProcessInfo.processInfo.environment["OMACVM_TEST_QEMU"], !real.isEmpty {
    let url = URL(fileURLWithPath: real)
    let t0 = Date()
    let gives = MemoryGiveBack.qemuGivesPagesBack(binary: url, environment: [:])
    let ms = Int(Date().timeIntervalSince(t0) * 1000)
    let size = ((try? FileManager.default.attributesOfItem(atPath: real)[.size]) as? Int ?? 0) >> 20
    expect(gives, "the built QEMU (\(real), \(size) MB) has the fix's text: gives the pages back (read in \(ms) ms)")
    expect(!MemoryGiveBack.qemuGivesPagesBack(binary: url, environment: ["OMACVM_RECLAIM_REUSABLE": "0"]),
           "  the same QEMU with OMACVM_RECLAIM_REUSABLE=0: keeps them")
} else {
    print("skip the built QEMU's text (OMACVM_TEST_QEMU not set: no runtime here)")
}
// The fix built in is not the fix working: QEMU says when macOS keeps the pages anyway (a refused or skipped advice;
// logs/memory-reclaim, OMACVM_RECLAIM_STATUS), and the give-back while macOS compresses goes off for the run.
expect(MemoryGiveBack.qemuKeeps(status: nil) == nil && MemoryGiveBack.qemuKeeps(status: "") == nil,
       "QEMU said nothing (no file, empty): not kept")
expect(MemoryGiveBack.qemuKeeps(status: "reclaim=gives\nwhy=x\n") == nil && MemoryGiveBack.qemuKeeps(status: "why=x\nreclaim=keeps\n") == nil,
       "  another word, or not first: not kept")
expect(MemoryGiveBack.qemuKeeps(status: "reclaim=keeps\nwhy=madvise refused: Operation not permitted\n") == "madvise refused: Operation not permitted",
       "QEMU's file (test-reclaim --keeps writes the same): kept, with the reason")
expect(MemoryGiveBack.qemuKeeps(status: "reclaim=keeps\n") == "no reason given", "  no reason: still kept")
let longWhy = MemoryGiveBack.qemuKeeps(status: "reclaim=keeps\nwhy=\u{1b}[2J" + String(repeating: "x", count: 500) + "\n")
expect(longWhy?.count == 120 && longWhy?.contains("\u{1b}") == false, "  the reason: printable, 120 characters at most")
func compressingSession(_ m: inout MemoryGiveBack, from t0: Double) -> Bool {
    _ = m.compressing(sample(t0, fp: 30, res: 30, comp: 100))
    var fired = false
    for i in 1...240 { fired = fired || m.compressing(sample(t0 + Double(i) * 5, fp: 30 + Double(i) * 0.1, res: 28, comp: 100 + Double(i) * 0.1)) }
    return fired
}
var heard = MemoryGiveBack(ram: 64 * GB, pagesGoBack: true)
expect(compressingSession(&heard, from: 0), "a QEMU with the fix, nothing heard: the give-back while macOS compresses fires")
var told = MemoryGiveBack(ram: 64 * GB, pagesGoBack: true)
told.qemuKept()
expect(!told.pagesGoBack && !compressingSession(&told, from: 0) && !told.allowed(.compressing, at: 9000),
       "QEMU says macOS keeps the pages: the same session never gives back")
told.started(.warning, at: 10000)
told.answered(nil)
expect(told.allowed(.critical, at: 10600) && !told.allowed(.warning, at: 10599), "  the warning's drop stays, once per 10 minutes")
expect(MemoryGiveBack.keptLine("why") == "OmacVM: VM memory: give-back while macOS compresses: off for the rest of this run: "
       + "QEMU says macOS keeps the pages the VM gives back (why)", "the qemu.log line when QEMU said so")
var kst = MemoryGiveBack.Status()
expect(kst.text.contains("\nkept=0\n"), "the status file says kept=0")
kst.kept = true
expect(kst.text.contains("\nkept=1\n"), "  kept=1 once QEMU said so (omacvm check's row)")
// qemu.log's line at each start; omacvm check's "VM memory" row reads "compresses: on|off" from it.
expect(MemoryGiveBack.startLine(pagesGoBack: false) == "OmacVM: VM memory: give-back while macOS compresses: off "
       + "(this QEMU keeps given-back pages); macOS's memory warning still drops the VM's file cache", "the line when off")
expect(MemoryGiveBack.startLine(pagesGoBack: true) == "OmacVM: VM memory: give-back while macOS compresses: on "
       + "(this QEMU gives the pages back to macOS)", "the line when on")
// The settings' words (GPUMemory.explanation), true with the reclaim fix (3.2.12): freed memory goes back to the Mac,
// the cold cache while macOS compresses the VM, the whole cache at macOS's warning. 3.2.11 said the Mac kept the pages.
// 3.2.17: also when the VM is idle, and its scattered free memory (compaction).
let says = GPUMemory.explanation
expect(says.contains("goes back to the Mac and leaves QEMU's footprint") && !says.contains("keep holding")
       && says.contains("When the VM is idle and while macOS compresses it, the VM gives back the file cache it has not used lately")
       && says.contains("when it is idle it also gathers its scattered free memory, so that the Mac can take it back")
       && says.contains("drops its whole"), "the settings' words: back to the Mac, the give-back when idle and while macOS compresses, compaction, the warning's drop")
// The maintainer's Mac mini (2026-10-30): 12 GB set, 4.5 GB of graphics at 5K, Activity Monitor 23 GB. The words say
// the field's range at 5K (not "about 2 GB") and that Activity Monitor counts compressed pages twice (ADR 0062's row).
expect(says.contains("Linux sees exactly this much") && says.contains("Graphics memory comes on top")
       && says.contains("(a 5K desktop with a browser: 2 to 5 GB)") && !says.contains("about 2 GB"),
       "the settings' words: the VM's RAM, graphics on top, 2 to 5 GB at 5K")
expect(says.contains("macOS counts that page twice (a 4 GB VM after a browser session: 5.9 GB shown, 2.1 GB of it counted twice)"),
       "the settings' words: Activity Monitor counts part of a compressed VM twice, with the measured row")
// One text for both (i)s: the VM header's and General's Resources row's say the same about memory.
let lastPeak = GPUMemory.parse("in_use_mb=2186\npeak_mb=4619\n")
expect(GPUMemory.lastRun(lastPeak) == "Graphics memory last run: peak 4.5 GB, from the Mac on top."
       && GPUMemory.lastRun(nil) == "Graphics memory comes from the Mac on top, as the VM needs it.", "the last run's graphics, or how they come")
expect(GPUMemory.resourcesInfo(lastPeak).hasPrefix("CPUs are the Mac's cores")
       && GPUMemory.resourcesInfo(lastPeak).hasSuffix(GPUMemory.lastRun(lastPeak) + "\n\n" + GPUMemory.explanation),
       "the Resources (i): CPUs, then the header's graphics line and the same explanation")

// The user's report: 64 GB Mac, 42 GB VM; footprint 51 GB, resident 27-30 GB, macOS compressing at "normal".
var u = withFix(64 * GB)
expect(u.minTaken == 2 * GB && u.minGrowth == 1 * GB, "64 GB Mac: 2 GB taken, 1 GB growth")
expect(!u.compressing(sample(0, fp: 30, res: 30, comp: 100)), "the VM's start: nothing")
expect(!u.compressing(sample(300, fp: 40, res: 39.5, comp: 101)), "growing in RAM, nothing compressed: nothing")
expect(u.compressing(sample(600, fp: 51, res: 28, comp: 108)), "the user's numbers (23 GB outside RAM, macOS compressed 7 GB): give back")
u.started(.compressing, at: 600)
expect(!u.compressing(sample(605, fp: 51, res: 28, comp: 108.5)), "a give-back under way counts: not again")

// Graphics that grow on a Mac with room count in the footprint, not in the resident size: not compressing.
var g = withFix(64 * GB)
_ = g.compressing(sample(0, fp: 20, res: 19, comp: 50))
var fired = false
for i in 1...120 {   // 10 minutes of a graphics-heavy session: +8.7 GB of graphics, macOS compresses 0.3 GB
    let t = Double(i) * 5
    fired = fired || g.compressing(sample(t, fp: 20 + 8.7 * t / 600, res: 19, comp: 50 + 0.3 * t / 600))
}
expect(!fired, "8.7 GB of graphics growth without compressions: nothing")
// The limit of that rule: macOS's count covers every process. The same growth while macOS compresses 1 GB or more
// (another app, say) does trigger it.
var g2 = withFix(64 * GB)
_ = g2.compressing(sample(0, fp: 20, res: 19, comp: 50))
var fired2 = false
for i in 1...120 {
    let t = Double(i) * 5
    fired2 = fired2 || g2.compressing(sample(t, fp: 20 + 8.7 * t / 600, res: 19, comp: 50 + 1.5 * t / 600))
}
expect(fired2, "the same graphics growth while macOS compresses 1.5 GB elsewhere: gives back (the rule's limit)")

// A 4 GB VM on an 8 GB Mac: the thresholds scale (a quarter, an eighth of the Mac).
var a = withFix(8 * GB)
expect(a.minTaken == 2 * GB && a.minGrowth == 1 * GB, "8 GB Mac: 2 GB taken, 1 GB growth")
_ = a.compressing(sample(0, fp: 4.2, res: 4.0, comp: 30))
expect(!a.compressing(sample(60, fp: 5.0, res: 3.5, comp: 32)), "8 GB Mac, 1.5 GB outside RAM: not yet")
expect(a.compressing(sample(120, fp: 5.6, res: 3.3, comp: 33)), "8 GB Mac, 2.3 GB outside RAM, 3 GB compressed: give back")
let b16 = withFix(16 * GB)
expect(b16.minTaken == 2 * GB && b16.minGrowth == 1 * GB, "16 GB Mac: 2 GB, 1 GB")

// A recorded row (MacBook Air M2 8 GB, 4 GB VM, 3.2.10, 2026-10-28 11:06-11:09, one look per 5 s): QEMU's footprint,
// its resident size and macOS's compressions (MB) while the VM read 2.6 GB of files and macOS compressed it at
// "normal". Replayed as it was, and as on a Mac with room (macOS compressing nothing): the same footprint growth,
// which graphics can also give, must never trigger there.
let air: [(Double, Double, Double)] = [
    (4201, 2971, 33146985), (4224, 2848, 33147071), (4204, 2833, 33147071), (4190, 2821, 33147071),
    (4184, 2817, 33147071), (6691, 3048, 33150741), (6690, 2860, 33150944), (6690, 2862, 33150944),
    (6690, 2785, 33151013), (6690, 2693, 33151092), (6672, 2431, 33151333), (6672, 2400, 33151378),
    (6672, 2402, 33151380), (6672, 2402, 33151380), (6672, 2402, 33151380), (6672, 2402, 33151380),
    (6672, 2402, 33151380), (6611, 2442, 33151459), (6611, 2443, 33151459), (6611, 2445, 33151459),
    (6611, 2445, 33151459), (6611, 2428, 33151505), (6614, 2371, 33151584), (6613, 2309, 33151640),
    (6614, 2310, 33151640), (6614, 2311, 33151640), (6614, 2311, 33151640), (6614, 2311, 33151640),
    (6614, 2311, 33151640), (6615, 2315, 33151640), (6616, 2317, 33151640), (6617, 2319, 33151640),
    (6617, 2319, 33151640), (6617, 2319, 33151640), (6619, 2314, 33151649), (6618, 2290, 33151676)
]
var airLive = withFix(8 * GB), airRoomy = withFix(8 * GB)
var firstLive: Int?, roomyFired = false
for (i, x) in air.enumerated() {
    let m = Double(MB)
    let s = MemoryGiveBack.Sample(time: Double(i) * 5, footprint: UInt64(x.0 * m), resident: UInt64(x.1 * m),
                                  compressed: UInt64(x.2 * m))
    if airLive.compressing(s) && firstLive == nil { firstLive = i }
    var r = s
    r.compressed = UInt64(air[0].2 * m)
    if airRoomy.compressing(r) { roomyFired = true }
}
expect(firstLive == 5, "the Air's recorded row: gives back at the first look after macOS compressed the VM")
expect(!roomyFired, "the same row with nothing compressed (a Mac with room): never")
var airKeeps = MemoryGiveBack(ram: 8 * GB)
var airKeepsFired = false
for (i, x) in air.enumerated() {
    let m = Double(MB)
    airKeepsFired = airKeeps.compressing(MemoryGiveBack.Sample(time: Double(i) * 5, footprint: UInt64(x.0 * m),
                                                               resident: UInt64(x.1 * m), compressed: UInt64(x.2 * m))) || airKeepsFired
}
expect(!airKeepsFired, "the Air's recorded row with a QEMU that keeps given-back pages: never")

// The baseline only moves down, and macOS's count starts again whenever the VM is near it.
var d = withFix(64 * GB)
_ = d.compressing(sample(0, fp: 10, res: 7, comp: 0))       // 3 GB outside RAM at the start
_ = d.compressing(sample(5, fp: 10, res: 7.5, comp: 0.2))   // 2.5: the new lowest
expect(d.baseline?.taken == UInt64(2.5 * Double(GB)), "the baseline moves down")
expect(!d.compressing(sample(10, fp: 11, res: 7.6, comp: 1.5)), "3.4 GB: less than 1 GB above the lowest")
expect(d.compressing(sample(15, fp: 11.5, res: 7.9, comp: 1.5)), "3.6 GB, macOS compressed 1.3 GB since: give back")
var f = withFix(64 * GB)
_ = f.compressing(sample(0, fp: 10, res: 9, comp: 0))
for i in 1...60 { _ = f.compressing(sample(Double(i) * 5, fp: 10, res: 9, comp: Double(i) * 0.1)) }   // flat, others compressed 6 GB
expect(!f.compressing(sample(305, fp: 13.2, res: 10, comp: 6.5)), "compressions while the VM sat at its lowest do not count")
expect(f.compressing(sample(310, fp: 13.2, res: 10, comp: 7.2)), "1.2 GB compressed since it last sat there: give back")

// One 10-minute gap across all triggers; macOS's warning may follow a cold-only give-back after 2 minutes.
var w = withFix(64 * GB)
expect(w.allowed(.warning, at: 0) && w.allowed(.compressing, at: 0), "nothing before: allowed")
w.started(.compressing, at: 1000)
expect(!w.allowed(.compressing, at: 1599) && w.allowed(.compressing, at: 1600), "compressing again after 10 minutes")
expect(!w.allowed(.warning, at: 1119) && w.allowed(.critical, at: 1120), "warning 2 minutes after a cold-only give-back")
w.answered(MemoryGiveBack.Result.parse("act=drop got=900", maxMB: 8192))
expect(!w.allowed(.warning, at: 1500) && w.allowed(.warning, at: 1600), "after a whole-cache drop: 10 minutes for the warning too")
w.started(.warning, at: 2000)
expect(!w.allowed(.compressing, at: 2300) && !w.allowed(.warning, at: 2300), "after the warning's drop: nothing for 10 minutes")
expect(w.allowed(.compressing, at: 2600) && w.allowed(.warning, at: 2600), "then both again")

// The VM's agent did not answer: as if nothing started, again in 30 s (as before).
var n = withFix(64 * GB)
n.started(.warning, at: 100)
n.noAnswer(at: 102)
expect(n.last == nil, "no answer: not counted")
expect(!n.allowed(.warning, at: 131) && n.allowed(.warning, at: 132) && n.allowed(.compressing, at: 132), "again in 30 s")
n.started(.warning, at: 132)
expect(n.answered(nil) == 1 && n.misses == 0, "it answers: one miss before, none now")
expect(!n.allowed(.warning, at: 500), "an answered start counts again")

// An agent that stays down while macOS compresses the VM: not asked (and logged) every 30 s for ever. Again in
// 30 s, 1, 2, 4, 8 minutes, then every 10 minutes; the app logs only the first miss (misses == 1).
var q = withFix(64 * GB)
var qt = 0.0, waits: [Double] = [], firsts = 0
for _ in 0..<9 {
    q.started(.compressing, at: qt)
    q.noAnswer(at: qt)
    if q.misses == 1 { firsts += 1 }
    var next = qt + 1
    while !q.allowed(.compressing, at: next) { next += 1 }
    waits.append(next - qt)
    qt = next
}
expect(waits == [30, 60, 120, 240, 480, 600, 600, 600, 600], "no answer: 30 s, 1, 2, 4, 8 min, then every 10 min (\(waits))")
expect(q.misses == 9 && firsts == 1, "9 misses in a row, one of them the first (the only one logged)")
var qAsks = 0, qAt = 0.0
while qAt < 3600 { qAsks += 1; qAt += MemoryGiveBack.retryAfter(misses: qAsks) }
expect(qAsks == 10, "an hour of a silent agent: 10 asks, not 120 (\(qAsks))")
q.started(.compressing, at: qt)
expect(q.answered(MemoryGiveBack.Result.parse("act=reclaim got=2000", maxMB: 43008)) == 9 && q.misses == 0,
       "it answers again: the streak ends")
q.noAnswer(at: qt + 700)
expect(!q.allowed(.compressing, at: qt + 729) && q.allowed(.compressing, at: qt + 730) && q.misses == 1,
       "a new miss later: 30 s again, and logged again")
expect(MemoryGiveBack.retryAfter(misses: 0) == 30 && MemoryGiveBack.retryAfter(misses: 1000) == 600, "retryAfter's ends")

// Backoff: under 256 MB back doubles the gap for "compressing" (up to 2 h); 1 GB or more resets it.
var k = withFix(64 * GB)
var t = 0.0
for want in [2.0, 4, 8, 12, 12] {
    k.started(.compressing, at: t)
    k.answered(MemoryGiveBack.Result.parse("act=none got=0", maxMB: 43008))
    k.settled(.compressing, guest: 0, footprintDrop: 100 * MB, at: t + 70)
    expect(k.backoff == want, "small give-back: backoff x\(Int(want))")
    t += 600 * want
}
expect(!k.allowed(.compressing, at: t - 600 * 12 + 7199) && k.allowed(.compressing, at: t - 600 * 12 + 7200), "at most 2 h")
expect(k.allowed(.warning, at: t - 600 * 12 + 600), "the warning keeps its 10 minutes")
k.started(.compressing, at: t)
k.settled(.compressing, guest: 600 * MB, footprintDrop: 600 * MB, at: t + 70)
expect(k.backoff == 12, "256 MB to 1 GB back: backoff stays")
k.settled(.warning, guest: nil, footprintDrop: 5 * GB, at: t + 80)
expect(k.backoff == 12, "the warning's drop, 5 GB less footprint: the gap for compressing stays")
k.settled(.compressing, guest: 3 * GB, footprintDrop: 2 * GB, at: t + 90)
expect(k.backoff == 1, "1 GB or more back: 10 minutes again")
k.settled(.critical, guest: nil, footprintDrop: 0, at: t + 95)
k.settled(.warning, guest: nil, footprintDrop: 10 * MB, at: t + 96)
expect(k.backoff == 1, "the warning's drop with nothing back: the gap for compressing stays too")

var m = withFix(64 * GB)
m.settled(.compressing, guest: 100 * MB, footprintDrop: 3 * GB, at: 10)
expect(m.backoff == 2, "3 GB less footprint but the VM gave 100 MB: small (something else freed it)")
m.settled(.compressing, guest: 737 * MB, footprintDrop: 0, at: 20)
expect(m.backoff == 2, "the VM gave 737 MB while it went on reading files (footprint up): not small (Air row 12:21)")
m.settled(.compressing, guest: nil, footprintDrop: 100 * MB, at: 30)
expect(m.backoff == 4, "its answer could not be read, 100 MB less footprint: small")
m.settled(.compressing, guest: nil, footprintDrop: 2 * GB, at: 40)
expect(m.backoff == 1, "its answer could not be read, 2 GB less footprint: the footprint counts")

// After a give-back the baseline starts again from 60 s later, not from the old lowest.
var s = withFix(64 * GB)
_ = s.compressing(sample(0, fp: 10, res: 10, comp: 0))
s.started(.compressing, at: 10)
s.settled(.compressing, guest: 2 * GB, footprintDrop: 2 * GB, at: 80)
_ = s.compressing(sample(85, fp: 15, res: 10, comp: 5))
expect(s.baseline?.taken == 5 * GB, "the new baseline: taken 60 s after the give-back")

// A balloon that does not report: no more give-backs for "compressing"; the warning stays.
var o = withFix(64 * GB)
o.started(.compressing, at: 0)
o.answered(MemoryGiveBack.Result.parse("mode=compressing act=norep rep=0", maxMB: 8192))
expect(o.off && !o.compressing(sample(5000, fp: 60, res: 20, comp: 900)), "not reporting: off for this run")
expect(o.allowed(.warning, at: 5000), "the warning's drop still runs")

// The idle give-back (ADR 0059, 3.2.17): every 15 minutes while macOS's pressure is normal, QEMU used at most a fifth of a
// core over the last minute, the compressing rule does not hold and no give-back ran in the last 10 minutes.
let core = 1_000_000_000.0   // QEMU's CPU time in ns: one core for one second
func idleLooks(_ m: inout MemoryGiveBack, from t0: Double, to t1: Double, fp: Double = 6, res: Double = 5, comp: Double = 100,
               load: Double = 0.02, normal: Bool = true) -> Double? {
    // One look every 5 s; QEMU uses `load` of a core. Returns the first time idle() says go (nil: never).
    var t = t0
    while t <= t1 {
        let s = MemoryGiveBack.Sample(time: t, footprint: UInt64(fp * Double(GB)), resident: UInt64(res * Double(GB)),
                                      compressed: UInt64(comp * Double(GB)), cpu: UInt64(t * load * core), normal: normal)
        m.seen(s)
        if !m.compressing(s) && m.idle(s) { return t }
        t += 5
    }
    return nil
}
var i1 = withFix(32 * GB)
expect(i1.idleOn && MemoryGiveBack.idleOn(environment: [:]) && !MemoryGiveBack.idleOn(environment: ["OMACVM_GIVEBACK_IDLE": "0"])
       && MemoryGiveBack.idleOn(environment: ["OMACVM_GIVEBACK_IDLE": "1"]), "idle on by default; OMACVM_GIVEBACK_IDLE=0 turns it off")
expect(idleLooks(&i1, from: 0, to: 2000) == 900, "a quiet VM, pressure normal: the first idle give-back 15 minutes after the start")
var i2 = withFix(32 * GB)
expect(idleLooks(&i2, from: 0, to: 2000, normal: false) == nil, "macOS's pressure warn or critical: never")
var i3 = withFix(32 * GB)
expect(idleLooks(&i3, from: 0, to: 2000, load: 0.31) == nil, "QEMU used 31 % of a core (a muted video): not quiet, never")
var i3b = withFix(32 * GB)
expect(idleLooks(&i3b, from: 0, to: 2000, load: 0.095) == 900, "  9.5 % of a core (an idle hidden VM on the M1 Max): quiet")
var i3c = withFix(32 * GB)
expect(idleLooks(&i3c, from: 0, to: 2000, load: 0.21) == nil, "  21 %: not quiet (the limit is a fifth of a core)")
var i4 = MemoryGiveBack(ram: 32 * GB, pagesGoBack: true, idle: false)
expect(idleLooks(&i4, from: 0, to: 3000) == nil && !i4.allowed(.idle, at: 3000), "OMACVM_GIVEBACK_IDLE=0: never")
var i5 = MemoryGiveBack(ram: 32 * GB)
expect(idleLooks(&i5, from: 0, to: 3000) == nil, "a QEMU that keeps given-back pages: never (as for compressing)")
// Not a full minute of looks yet (the app looks every 5 s): not quiet.
var i6 = withFix(32 * GB)
i6.seen(sample(895, fp: 6, res: 5, comp: 100))
expect(!i6.quiet && !i6.idle(sample(900, fp: 6, res: 5, comp: 100)), "under a minute of looks: not known to be quiet")
// QEMU has min(2 GB, a quarter of the Mac) or more outside its resident memory (what macOS compressed of it, and
// graphics): no idle give-back (it compacts: macOS would decompress what moves; the compressing rule has its own
// back-off). The Mac mini's quiet rows had 3.3-4.9 GB there all along; the M1 Max's 0.3 GB.
var i7 = withFix(32 * GB)
expect(idleLooks(&i7, from: 0, to: 2000, fp: 6.95, res: 5, comp: 100) == 900, "1.95 GB outside the resident memory: idle runs")
var i8 = withFix(32 * GB)
expect(idleLooks(&i8, from: 0, to: 2000, fp: 7, res: 5, comp: 100) == nil && i8.compressingHolds(sample(2000, fp: 7, res: 5, comp: 100))
       && i8.last == nil, "2 GB outside (compressed pages or graphics, nothing compressed lately): no idle give-back")
var i8b = withFix(8 * GB), i8c = withFix(8 * GB)
expect(idleLooks(&i8b, from: 0, to: 2000, fp: 5.9, res: 4, comp: 100) == 900 && idleLooks(&i8c, from: 0, to: 2000, fp: 6.1, res: 4, comp: 100) == nil,
       "an 8 GB Mac: the same 2 GB (a quarter of it)")
// One 10-minute gap with the other give-backs: none within 10 minutes of a give-back while macOS compressed.
var i9 = withFix(32 * GB)
_ = idleLooks(&i9, from: 0, to: 500)
i9.started(.compressing, at: 500)
i9.answered(MemoryGiveBack.Result.parse("act=reclaim got=2000", maxMB: 8192))
expect(idleLooks(&i9, from: 505, to: 3000) == 1100, "the last give-back at 500 s: idle at 1100 s, not at 900 s")
// It counts as cold-only: the warning may follow 2 minutes after it, and the next compressing give-back after 10.
var j = withFix(32 * GB)
let jt = idleLooks(&j, from: 0, to: 2000)!
j.started(.idle, at: jt)
expect(!j.allowed(.warning, at: jt + 119) && j.allowed(.critical, at: jt + 120) && !j.allowed(.compressing, at: jt + 599)
       && j.allowed(.compressing, at: jt + 600), "idle counts as cold-only: the warning after 2 minutes, compressing after 10")
// Its agent did not answer: again in 15 minutes, never sooner, and the warning's drop is not held up (no shared retry).
j.idleNoAnswer(at: jt + 5)
expect(j.last == nil && j.idleMisses == 1 && j.misses == 0, "an idle miss: as if it had not started, not the shared miss count")
expect(j.allowed(.warning, at: jt + 3) && j.allowed(.compressing, at: jt + 3), "  the warning's drop and compressing may go at once")
expect(idleLooks(&j, from: jt + 10, to: jt + 3000) == jt + 5 + 900, "  the next idle give-back 15 minutes after the miss")
// A retry of the warning or compressing that is due goes first; idle waits until it answered.
var jr = withFix(32 * GB)
_ = idleLooks(&jr, from: 0, to: 850)
jr.started(.warning, at: 850)
jr.noAnswer(at: 851)
expect(!jr.allowed(.idle, at: 2000) && jr.allowed(.warning, at: 2000), "a warning retry pending: no idle give-back before it")
// What came back sets the gap: under 256 MB doubles it (30, 60, 120 minutes, then 2 hours at most); 1 GB or more: 15 again.
var b = withFix(32 * GB)
var bt = idleLooks(&b, from: 0, to: 2000)!
var gaps: [Double] = []
for _ in 0..<5 {
    b.started(.idle, at: bt)
    b.idleAnswered(MemoryGiveBack.Result.parse("act=none got=0 small=100 small_to=100 cpt=small rf=0", maxMB: 8192), at: bt + 5)
    b.settled(.idle, guest: 0, footprintDrop: 0, at: bt + 65)
    let next = idleLooks(&b, from: bt + 70, to: bt + 9000)!
    gaps.append(next - (bt + 5))
    bt = next
}
expect(gaps == [1800, 3600, 7200, 7200, 7200] && b.idleBackoff == 8, "under 256 MB back: 30, 60, 120 minutes, then 2 hours at most (\(gaps))")
b.started(.idle, at: bt)
b.idleAnswered(MemoryGiveBack.Result.parse("act=reclaim got=600 small=900 small_to=300 cpt=ran rf=0", maxMB: 8192), at: bt + 3)
expect(b.idleBackoff == 1 && b.backoff == 1, "600 MB of cache + 600 MB compacted (1.2 GB): back to 15 minutes; compressing's gap untouched")
b.started(.idle, at: bt + 1000)
b.idleAnswered(MemoryGiveBack.Result.parse("act=reclaim got=500 small=200 small_to=200 cpt=small rf=100", maxMB: 8192), at: bt + 1003)
expect(b.idleBackoff == 1, "500 MB back (256 MB to 1 GB): the gap stays; refaults 100 MB since the last (it gave 600): stays")
b.started(.idle, at: bt + 2000)
b.idleAnswered(MemoryGiveBack.Result.parse("act=reclaim got=2000 small=200 small_to=200 cpt=small rf=360", maxMB: 8192), at: bt + 2003)
expect(b.idleBackoff == 2, "2 GB back, but the VM read 260 MB again of the 500 the last gave (half or more): the gap doubles")
// busy or locked: nothing ran; not counted, again in 15 minutes, the gap as it was.
var c = withFix(32 * GB)
let ct = idleLooks(&c, from: 0, to: 2000)!
c.started(.idle, at: ct)
c.idleAnswered(MemoryGiveBack.Result.parse("act=busy psi=0.5", maxMB: 8192), at: ct + 5)
expect(c.last == nil && c.idleBackoff == 1 && c.allowed(.compressing, at: ct + 2), "busy: not a give-back (no gap for the others)")
expect(idleLooks(&c, from: ct + 10, to: ct + 3000) == ct + 5 + 900, "  the next try 15 minutes later")
c.started(.idle, at: ct + 1000)
c.idleAnswered(MemoryGiveBack.Result.parse("act=locked", maxMB: 8192), at: ct + 1001)
expect(c.last == nil && c.idleBackoff == 1, "locked (the last one still runs in the VM): the same")
// An answer that could not be read: it may have run, so it counts (the gap as it was).
c.started(.idle, at: ct + 2000)
c.idleAnswered(nil, at: ct + 2030)
expect(c.last?.trigger == .idle && c.idleBackoff == 1, "no readable answer: counted as a give-back")
// A balloon that does not report: off, for compressing too.
var d2 = withFix(32 * GB)
d2.started(.idle, at: 900)
d2.idleAnswered(MemoryGiveBack.Result.parse("act=norep rep=0", maxMB: 8192), at: 901)
expect(d2.off && !d2.allowed(.idle, at: 9000) && !d2.allowed(.compressing, at: 9000) && d2.allowed(.warning, at: 9000),
       "norep: no more idle or compressing give-backs; the warning's drop stays")
// After the warning's drop: one compaction-only call once the pressure is normal again and the VM is quiet (compaction
// moves pages in use: on the M1 Max with a video playing, waits of 10 ms or more went from 12 to about 50 in 150 s).
func looks(_ m: inout MemoryGiveBack, from t0: Double, to t1: Double, load: Double, normal: Bool = true) -> Double? {
    var t = t0
    while t <= t1 {
        var s = sample(t, fp: 6, res: 5, comp: 100)
        s.cpu = UInt64(t * load * core); s.normal = normal
        m.seen(s)
        if m.compactAfterDrop(s) { return t }
        t += 5
    }
    return nil
}
var e = withFix(32 * GB)
e.started(.warning, at: 100)
e.answered(nil)
e.dropped()
expect(e.compactDue && looks(&e, from: 0, to: 300, load: 0.02, normal: false) == nil, "the drop done, pressure still warn: no compaction")
expect(looks(&e, from: 305, to: 600, load: 0.7) == nil && e.compactDue, "  normal again but QEMU busy (a video, 70 % of a core): not yet")
let quietAt = looks(&e, from: 605, to: 900, load: 0.02)
expect(quietAt == 665 && !e.compactDue && looks(&e, from: 670, to: 2000, load: 0.02) == nil,
       "  normal and quiet for a minute: one compaction-only call, once (at \(quietAt ?? -1))")
expect(e.last?.trigger == .warning, "  not a give-back for the gaps (the drop's stays)")
var e3 = withFix(32 * GB)
e3.dropped()
e3.started(.idle, at: 50)
expect(!e3.compactDue, "an idle give-back before it compacts too: the call after the drop is dropped")
var e2 = MemoryGiveBack(ram: 32 * GB)
e2.dropped()
expect(!e2.compactDue, "a QEMU that keeps given-back pages: no compaction after the drop")
// qemu.log's words.
expect(MemoryGiveBack.idleLine(on: true, pagesGoBack: true) == "OmacVM: VM memory: idle give-back: on (at most every 15 minutes while the VM is quiet and macOS's pressure normal)"
       && MemoryGiveBack.idleLine(on: false, pagesGoBack: true) == "OmacVM: VM memory: idle give-back: off (OMACVM_GIVEBACK_IDLE=0)"
       && MemoryGiveBack.idleLine(on: true, pagesGoBack: false) == "OmacVM: VM memory: idle give-back: off (this QEMU keeps given-back pages)",
       "the start line about the idle give-back")
let ran = MemoryGiveBack.Result.parse("act=none small=1191 small_to=131 cpt=ran cpt_ms=430", maxMB: 8192)!
expect(MemoryGiveBack.compactionWords(ran) == "compacted its free memory: 1.2 GB -> 131 MB in blocks too small to give back (0.4 s)",
       "the compaction's words")
expect(MemoryGiveBack.compactionWords(MemoryGiveBack.Result.parse("act=none small=1191 small_to=600 cpt=cap cpt_ms=10000", maxMB: 8192)!)
       .hasSuffix("(10.0 s, stopped at its time cap)")
       && MemoryGiveBack.compactionWords(MemoryGiveBack.Result.parse("act=none small=90 cpt=small", maxMB: 8192)!) == "90 MB free in blocks too small to give back"
       && MemoryGiveBack.compactionWords(MemoryGiveBack.Result.parse("act=none small=900 cpt=busy", maxMB: 8192)!) == "no compaction (the VM was waiting for memory)",
       "  at its cap, too little to compact, the VM busy")
var ist = MemoryGiveBack.Status()
ist.idle = 4; ist.idleMB = 2150; ist.idleAt = 1_793_177_520
expect(ist.text.contains("\ncount=0\n") || ist.text.hasPrefix("count=0\n"), "idle give-backs do not count in count= (omacvm check's N times)")
expect(ist.text.hasSuffix("idle=4\nidle_mb=2150\nidle_at=1793177520\n"), "  their own lines: idle=, idle_mb=, idle_at=")

// The VM's answer is untrusted.
let line = "mode=compressing act=reclaim want=12444 got=12380 cache=15550 cache_to=3170 small=1191 small_to=131 cpt=ran cpt_ms=430 psi=0 rf=812 rep=1 order=6 steps=13 secs=19"
let r = MemoryGiveBack.Result.parse("noise\n" + line + "\n", maxMB: 43008)
expect(r?.act == "reclaim" && r?.wantMB == 12444 && r?.gotMB == 12380 && r?.cacheMB == 15550 && r?.cacheAfterMB == 3170
       && r?.smallFreeMB == 1191 && r?.smallAfterMB == 131 && r?.compaction == "ran" && r?.compactionMS == 430 && r?.refaultMB == 812
       && r?.reporting == true && r?.order == 6 && r?.seconds == 19, "giveback.sh's line read")
expect(r?.compactedMB == 1060, "  what compaction made reportable: the small free blocks it joined (1191 -> 131)")
expect(MemoryGiveBack.Result.parse("act=none small=900 small_to=100 cpt=busy", maxMB: 4096)?.compactedMB == 0
       && MemoryGiveBack.Result.parse("act=none small=900 small_to=950 cpt=cap", maxMB: 4096)?.compactedMB == 0
       && MemoryGiveBack.Result.parse("act=none small=900 small_to=300 cpt=cap", maxMB: 4096)?.compactedMB == 600,
       "  only a compaction that ran (or ran to its cap) counts, never below 0")
expect(MemoryGiveBack.Result.parse("act=none", maxMB: 4096)?.refaultMB == nil, "  no refaults in the line: nil")
let big = MemoryGiveBack.Result.parse("act=reclaim got=99999999 cache=-5 small=x order=77 secs=99999 cpt_ms=-4 rf=99999999999999", maxMB: 4096)
expect(big?.gotMB == 4096 && big?.cacheMB == 0 && big?.smallFreeMB == 0 && big?.order == 10 && big?.seconds == 600
       && big?.compactionMS == 0 && big?.refaultMB == Int(Int32.max), "numbers clamped to 0 and the VM's memory (refaults to 2^31)")
expect(MemoryGiveBack.Result.parse("act=re\u{1b}[31mcl\u{7}aim got=5", maxMB: 100)?.act == "remclaim", "act: letters only")
expect(MemoryGiveBack.Result.parse("act=none cpt=r\u{1b}an9", maxMB: 100)?.compaction == "ran", "cpt: letters only")
expect(MemoryGiveBack.Result.parse("got=5 cache=7", maxMB: 100) == nil, "no act: not an answer")
expect(MemoryGiveBack.Result.parse("act=;; got=5", maxMB: 100) == nil, "an act without letters: not an answer")
expect(MemoryGiveBack.Result.parse(String(repeating: "x", count: 300) + " act=reclaim", maxMB: 100) == nil, "past 200 characters: cut")
expect(MemoryGiveBack.Result.parse("", maxMB: 100) == nil && MemoryGiveBack.Result.parse("\n\n", maxMB: 100) == nil, "empty: nil")

// Seeded fuzz: random answers never crash and never give a number out of range.
var seed: UInt64 = 0x5eed_0059
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
let pieces = ["act=", "reclaim", "got=", "cache=", "cache_to=", "small=", "small_to=", "cpt=", "cpt_ms=", "rf=", "order=", "secs=",
              "rep=", "=", " ", "\n", "\r", "-", "9", "99999999999999999999", "-1", "\u{0}", "\u{1b}", "é", "🙂", "\u{7f}", "a"]
var bad = 0
for _ in 0..<5000 {
    var text = ""
    for _ in 0..<Int(next() % 40) { text += pieces[Int(next() % UInt64(pieces.count))] }
    let cap = Int(next() % 65536)
    guard let x = MemoryGiveBack.Result.parse(text, maxMB: cap) else { continue }
    let nums = [x.wantMB, x.gotMB, x.cacheMB, x.cacheAfterMB, x.smallFreeMB, x.smallAfterMB, x.compactedMB]
    if nums.contains(where: { $0 < 0 || $0 > cap }) || x.act.isEmpty || x.act.count > 12 || x.compaction.count > 12
        || !(x.act + x.compaction).unicodeScalars.allSatisfy({ $0.value >= 0x61 && $0.value <= 0x7A })
        || !(0...600_000).contains(x.compactionMS) || (x.refaultMB.map { $0 < 0 } ?? false)
        || !(-1...10).contains(x.order) || !(0...600).contains(x.seconds) { bad += 1 }
}
expect(bad == 0, "5000 random answers: every number within range, act and cpt letters only")

// The status file for omacvm check.
var st = MemoryGiveBack.Status()
st.count = 3; st.at = 1_793_177_520; st.trigger = "compressing"; st.act = "reclaim"; st.givenMB = 11900; st.returnedMB = 11200
expect(st.text.hasPrefix("count=3\nat=1793177520\ntrigger=compressing\nact=reclaim\ngiven_mb=11900\nreturned_mb=11200\n")
       && st.text.hasSuffix("off=0\nkept=0\nidle=0\nidle_mb=0\nidle_at=0\n"), "status file: key=value lines")
st.givenMB = nil
expect(st.text.contains("\ngiven_mb=\n"), "the warning's drop: no count from the VM, given_mb empty")
expect(MemoryGiveBack.gb(900 * MB) == "900 MB" && MemoryGiveBack.gb(11900 * MB) == "11.6 GB", "sizes as the log says them")
}

// When the VM stood still (VMStalls, ADR 0060): QEMU's logs/vm-stalls, and the note in the VM.
do {
let user = """
stalls=2
longest_ms=58000
longest_cause=memory
last_ms=58000
last_cause=memory
last_vcpus=1,2,3,8
last_at=1761637419
last_vm_mb=52224
last_free_mb=300
last_compressed_mb=20480
gpu_stalls=1
gpu_longest_ms=2500
gpu_last_where=VTDecompressionSessionCreate (from session_create)
"""
let s = VMStalls.parse(user)
expect(s?.stalls == 2 && s?.longestMs == 58000 && s?.longestCause == "memory" && s?.lastMs == 58000
       && s?.lastCause == "memory" && s?.lastAt == 1761637419 && s?.lastVMMB == 52224 && s?.lastFreeMB == 300
       && s?.gpuStalls == 1 && s?.gpuLongestMs == 2500, "logs/vm-stalls read (the user's 58 s)")
expect(VMStalls.parse("gpu_stalls=1\n") == nil && VMStalls.parse("") == nil, "no stalls= line: not the file")
let odd = VMStalls.parse("stalls=-3\nlast_ms=99999999999999999\nlast_cause=memory\u{1b}\nlongest_cause=cpu\nlast_vm_mb=x")
expect(odd?.stalls == 0 && odd?.lastMs == 0 && odd?.lastCause == "" && odd?.longestCause == "cpu" && odd?.lastVMMB == 0,
       "untrusted: numbers clamped (an overlong one is 0), causes from the list only")
let zero = VMStalls.parse("stalls=0\nlongest_ms=0\nlongest_cause=none\n")
expect(zero == VMStalls(), "QEMU's start: all zeros")
let now = Date()
expect(VMStalls.noteDue(s!, seen: 1, lastNote: nil, now: now), "a new 58 s stall for memory: a note")
expect(!VMStalls.noteDue(s!, seen: 2, lastNote: nil, now: now), "the same stall again: no note")
expect(!VMStalls.noteDue(s!, seen: 1, lastNote: now.addingTimeInterval(-600), now: now), "a note 10 min ago: none now")
expect(VMStalls.noteDue(s!, seen: 1, lastNote: now.addingTimeInterval(-1801), now: now), "a note 30 min ago: a note")
var short = s!; short.lastMs = 9999
expect(!VMStalls.noteDue(short, seen: 1, lastNote: nil, now: now), "under 10 s: no note")
var cpu = s!; cpu.lastCause = "cpu"
expect(!VMStalls.noteDue(cpu, seen: 1, lastNote: nil, now: now), "waiting for a Mac core: no note")
let kernel = VMStalls.parse("stalls=1\nlongest_ms=58000\nlongest_cause=kernel\nlast_ms=58000\nlast_cause=kernel\nlast_vm_mb=52224\n")
expect(kernel?.lastCause == "kernel" && kernel?.longestCause == "kernel" && kernel.map { !VMStalls.noteDue($0, seen: 0, lastNote: nil, now: now) } == true,
       "58 s blocked in macOS's kernel while the Mac did not page: no memory note")
let main = VMStalls.parse("stalls=0\nmain_stalls=1\nmain_longest_ms=2214\nmain_last_where=close (from qemu_memfd_free)\n")
expect(main?.mainStalls == 1 && main?.mainLongestMs == 2214 && main.map { !VMStalls.noteDue($0, seen: 0, lastNote: nil, now: now) } == true,
       "QEMU's main loop held the VM 2.2 s: read, no note")
expect(VMStalls.noteArguments(s!, macBytes: 64 << 30) == ["stall", "58", "51", "64"], "the note's arguments: 58 s, 51 of 64 GB")
var stallSeed: UInt64 = 0x5eed_0060
func nextStall() -> UInt64 { stallSeed = stallSeed &* 6364136223846793005 &+ 1442695040888963407; return stallSeed >> 33 }
var fuzzBad = 0
for _ in 0..<3000 {
    var text = ""
    let parts = ["stalls=", "last_ms=", "last_cause=", "memory", "kernel", "cpu", "last_vm_mb=", "\n", "=", "-", "9", "999999999999999",
                 "\u{0}", "é", "x", "last_at=", "gpu_stalls=", "main_stalls="]
    for _ in 0..<Int(nextStall() % 30) { text += parts[Int(nextStall() % UInt64(parts.count))] }
    guard let x = VMStalls.parse(text) else { continue }
    let nums = [x.stalls, x.longestMs, x.lastMs, x.lastAt, x.lastVMMB, x.lastFreeMB, x.gpuStalls, x.gpuLongestMs, x.mainStalls,
                x.mainLongestMs]
    if nums.contains(where: { $0 < 0 || $0 > VMStalls.most }) || !["", "memory", "kernel", "cpu"].contains(x.lastCause) { fuzzBad += 1 }
    _ = VMStalls.noteArguments(x, macBytes: 8 << 30)
}
expect(fuzzBad == 0, "3000 random files: every number within range, causes from the list")
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("desktop restart, graphics memory, memory give-back and VM stalls: all checks passed")
