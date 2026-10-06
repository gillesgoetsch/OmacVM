// The app's Graphics rules (Graphics.swift) for src/tests/graphics-setting.sh:
// one line per case, "choice macos kk ready forced macgb vmgb ipabits fallback -> venus hostmemMB windowGB | summary".
import Foundation

let args = CommandLine.arguments
if args.count > 1 && args[1] == "file" {
    // file DIR: what the app reads from a VM folder.
    print(Graphics.read(folder: URL(fileURLWithPath: args[2])).rawValue)
    exit(0)
}
if args.count > 1 && args[1] == "migrate" {
    // migrate DIR...: the hidden venus switch moved into these VM folders.
    for l in Graphics.migrateVenusSwitch(folders: args.dropFirst(2).map { URL(fileURLWithPath: $0) }) { print(l) }
    exit(0)
}
if args.count > 1 && args[1] == "waiting" {
    print(Graphics.waitingForDriver)
    exit(0)
}
if args.count > 1 && args[1] == "didnotstart" {
    print(Graphics.didNotStart)
    exit(0)
}
if args.count > 1 && args[1] == "fallback" {
    // fallback DIR: what the app reads from graphics-fallback ("-": none).
    print(Graphics.fallback(folder: URL(fileURLWithPath: args[2])) ?? "-")
    exit(0)
}
if args.count > 1 && args[1] == "write" {
    // write CHOICE DIR: the app's Graphics.write.
    try Graphics.write(GraphicsChoice(rawValue: args[2])!, folder: URL(fileURLWithPath: args[3]))
    exit(0)
}
if args.count > 1 && args[1] == "watch" {
    // watch: VenusStartWatch scenarios, one line each "name verdict".
    func run(_ name: String, _ polls: [VenusStartWatch.Poll], dt: Double = 3) {
        var w = VenusStartWatch()
        var v = VenusStartWatch.Verdict.wait
        for p in polls {
            v = w.poll(p, seconds: dt)
            if v != .wait { break }
        }
        switch v {
        case .wait: print("\(name) wait")
        case .fine: print("\(name) fine")
        case .fallBack(let why, let graceful): print("\(name) fallback \(graceful ? "graceful" : "now") \(why)")
        }
    }
    let ok = VenusStartWatch.Poll(answered: true, pciMapped: true, consoleOutput: true)
    let early = VenusStartWatch.Poll(answered: true, pciMapped: false)
    let silent = VenusStartWatch.Poll(answered: false)
    // The Air hang: no BAR mapped, nothing on the console.
    run("air-hang", Array(repeating: early, count: 20))
    // Normal: a few early polls, then the firmware maps; fine after 180 s.
    run("normal", Array(repeating: early, count: 3) + Array(repeating: ok, count: 80))
    run("normal-24s", Array(repeating: early, count: 8) + [ok])
    // Paused (the Mac asleep) does not count.
    run("paused", Array(repeating: VenusStartWatch.Poll(answered: true, paused: true, pciMapped: false), count: 40))
    // QEMU's monitor silent 30 s (virgl blocks its main loop).
    run("silent", [ok] + Array(repeating: silent, count: 10))
    run("silent-short", [ok] + Array(repeating: silent, count: 5) + [ok])
    // QMP never reachable: no hang verdict from silence; the console decides.
    run("no-qmp-console", Array(repeating: VenusStartWatch.Poll(answered: false, consoleOutput: true), count: 20))
    run("no-qmp-nothing", Array(repeating: silent, count: 20))
    // The window's no-picture line, after the firmware ran: shut down first.
    run("no-picture", [ok, ok, VenusStartWatch.Poll(answered: true, pciMapped: true, consoleOutput: true, noPicture: true)])
    // Only the console says the firmware ran (info pci not asked).
    run("console-only", Array(repeating: VenusStartWatch.Poll(answered: true, consoleOutput: true), count: 12))
    var w = VenusStartWatch()
    _ = w.poll(ok, seconds: 3); _ = w.poll(silent, seconds: 25); w.woke()
    print("woke \(w.poll(silent, seconds: 25) == .wait ? "wait" : "fallback")")
    print("pci-mapped \(VenusStartWatch.pciMapped("BAR0: 64 bit memory at 0x10000000 [0x10003fff].")) \(VenusStartWatch.pciMapped("BAR0: 64 bit memory (not mapped)\n      BAR4: 64 bit prefetchable memory (not mapped)\n BAR0: I/O (not mapped)"))")
    print("bits \(Graphics.hostmemMB(macMemoryGB: 8, vmMemoryGB: 4, ipaBits: 36)) \(Graphics.hostmemMB(macMemoryGB: 8, vmMemoryGB: 4, ipaBits: 40)) \(Graphics.hostmemMB(macMemoryGB: 8, vmMemoryGB: 4, ipaBits: nil)) \(Graphics.size(mb: 256)) \(Graphics.size(mb: 4096))")
    let air = Graphics.plan(choice: .vulkan, macOSMajor: 26, kosmicKrisp: true, driverReady: true, forced: false,
                            macMemoryGB: 8, vmMemoryGB: 4, ipaBits: 36)
    print("record \(air.record)")
    exit(0)
}
for c in GraphicsChoice.allCases {
    for macos in [15, 26, 27] {
        for kk in [false, true] {
            for ready in [false, true] {
                for forced in [false, true] {
                    for (mac, vm) in [(8, 4), (16, 8), (24, 12), (36, 16), (48, 24), (64, 32), (128, 16), (128, 48), (96, 60), (128, 62)] {
                        for ipa in [36, 42] {
                            for fb in [false, true] {
                                let p = Graphics.plan(choice: c, macOSMajor: macos, kosmicKrisp: kk, driverReady: ready,
                                                      forced: forced, macMemoryGB: mac, vmMemoryGB: vm, ipaBits: ipa,
                                                      fallback: fb ? "the firmware found no devices" : nil)
                                print("\(c.rawValue) \(macos) \(kk ? 1 : 0) \(ready ? 1 : 0) \(forced ? 1 : 0) \(mac) \(vm) \(ipa) \(fb ? 1 : 0) -> \(p.venus ? "vulkan" : "opengl") \(p.hostmemMB) \(p.highWindowGB.map(String.init) ?? "-") | \(p.summary)")
                            }
                        }
                    }
                }
            }
        }
    }
}
