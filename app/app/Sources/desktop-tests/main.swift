// "Restart the Desktop…" after Later (OmacVMDesktop), without a VM:
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

if failures > 0 { print("\(failures) failed"); exit(1) }
print("desktop restart: all checks passed")
