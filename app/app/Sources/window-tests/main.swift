// The VM window's rules (OmacVMWindow), without a VM or the app:
//   cd app/app && swift run window-tests
// Custom resources, disk Grow/Compact, "omacvm in Terminal", the keyboard
// note. Exit 0 when all pass. CI runs it on every pull request.
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
expect(DiskSize.firstGrowGB(currentGB: 64) == 80 && DiskSize.firstGrowGB(currentGB: 70) == 80
       && DiskSize.firstGrowGB(currentGB: 4096) == 4096, "Grow starts one step up")
expect(DiskSize.growProblem(currentGB: 64, newGB: 128, vmRunning: false) == nil, "grow 64 -> 128 with the VM off")
expect(DiskSize.growProblem(currentGB: 64, newGB: 128, vmRunning: true) != nil, "never while the VM runs")
expect(DiskSize.growProblem(currentGB: 64, newGB: 64, vmRunning: false) != nil
       && DiskSize.growProblem(currentGB: 64, newGB: 32, vmRunning: false) != nil, "grow never shrinks")
expect(DiskSize.growProblem(currentGB: 64, newGB: 5000, vmRunning: false) != nil, "4 TB at most")
expect(DiskSize.growWarning(newGB: 128, allocatedBytes: 20 * DiskSize.gib, freeBytes: 500 * DiskSize.gib) == nil,
       "enough free on the Mac: no warning")
expect(DiskSize.growWarning(newGB: 512, allocatedBytes: 20 * DiskSize.gib, freeBytes: 100 * DiskSize.gib) != nil,
       "more than the Mac has free: a warning")
expect(DiskSize.growWarning(newGB: 512, allocatedBytes: 0, freeBytes: nil) == nil, "free space unknown: no claim")

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
for (name, script) in [("grow", DiskSize.growScript), ("compact", DiskSize.compactScript)] {
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-n", "-c", script]
    try? sh.run(); sh.waitUntilExit()
    expect(sh.terminationStatus == 0, "\(name) script: sh -n")
}

// MARK: Keyboard note

let refused = "OmacVM: keys: Input Monitoring NOT allowed, Accessibility (keys) NOT allowed for OmacVM\nCould not create event tap\n"
let refusedWithAccess = "OmacVM: keys: Input Monitoring allowed, Accessibility (keys) NOT allowed for OmacVM\nCould not create event tap\n"
let fine = "OmacVM: keys: Input Monitoring allowed, Accessibility (keys) allowed for OmacVM\n"
expect(KeyNote.decide(allowedNow: false, lastLog: nil) == .needsUser, "not allowed: the red note")
expect(KeyNote.decide(allowedNow: true, lastLog: refused) == .allowedNextStart, "allowed since the last start: next start")
expect(KeyNote.decide(allowedNow: true, lastLog: refusedWithAccess) == .needsUser, "allowed at that start and still refused: red")
expect(KeyNote.decide(allowedNow: true, lastLog: "Could not create event tap\n") == .allowedNextStart, "old log without a record: next start")
expect(KeyNote.decide(allowedNow: true, lastLog: fine) == .none, "allowed and the tap worked: nothing")
expect(KeyNote.decide(allowedNow: true, lastLog: nil) == .none, "allowed, no start yet: nothing")
expect(KeyNote.startHadAccess(refused) == false && KeyNote.startHadAccess(fine) == true
       && KeyNote.startHadAccess("x") == nil, "the record read")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
