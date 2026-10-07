// The Mac folder's QEMU arguments (OmacVMFolder), without a VM or Xcode:
//   cd app/app && swift run folder-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMFolder

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias P = MacFolderPlan
let there: (String) -> Bool = { _ in true }
let gone: (String) -> Bool = { _ in false }
let home = "/Users/me"
let holds: (String) -> Bool = { P.holdsHome($0, home: home) }
func plan(_ text: String?, isDirectory: (String) -> Bool = there, canOpen: (String) -> Bool = there) -> P.Plan {
    P.plan(fileText: text, isDirectory: isDirectory, canOpen: canOpen, holdsHome: holds)
}

// Off: no file, an empty file.
let off = plan(nil)
expect(off.arguments.isEmpty && off.record == "off", "no file: off")
expect(plan("\n").arguments.isEmpty, "empty file: off")

// On: one fsdev and one device, the folder as written.
var p = plan("/Users/me/Projects\n")
expect(p.arguments.count == 4 && p.arguments[0] == "-fsdev" && p.arguments[2] == "-device", "folder: -fsdev and -device")
expect(p.arguments[1].hasPrefix("local,id=macfs,path=/Users/me/Projects,security_model=none,"), "folder: local backend, security_model=none")
expect(p.arguments[1].contains("guest_owner_uid=1000,guest_owner_gid=1000"), "folder: shown as the desktop user's")
expect(p.arguments[3] == "virtio-9p-pci,fsdev=macfs,mount_tag=omacvm-mac", "folder: tag omacvm-mac")
expect(p.record == "/Users/me/Projects at ~/Mac", "folder: record")

// A comma cannot add QEMU options.
p = plan("/Users/me/a,readonly=off,b")
expect(p.arguments[1].contains("path=/Users/me/a,,readonly=off,,b,security_model=none"), "comma written twice")

// Only the first line counts.
p = plan("/Users/me/x\n/etc\n")
expect(p.arguments[1].contains("path=/Users/me/x,"), "first line only")

// Not usable: relative, the whole disk, "..", NUL.
for bad in ["Users/me", "/", "/Users/me/../..", "/Users/me/a\0b"] {
    let b = plan(bad)
    expect(b.arguments.isEmpty && b.record.hasPrefix("off this start: the setting"), "refused: \(bad.debugDescription)")
}

// Not there now (a drive not connected): the VM starts without it.
p = plan("/Volumes/USB/work", isDirectory: gone)
expect(p.arguments.isEmpty && p.record == "off this start: /Volumes/USB/work is not there (a drive not connected?)", "missing folder: left out")

// There, but the app may not open it (Files and Folders denied, chmod 000,
// another user's): left out, so QEMU does not refuse to start.
p = plan("/Users/me/Documents/work", canOpen: gone)
expect(p.arguments.isEmpty && p.record.hasPrefix("off this start: no access to /Users/me/Documents/work (System Settings"), "unreadable folder: left out")

// The real check, on a folder with no permissions (chmod 000).
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("folder-tests-\(getpid())")
let locked = tmp.appendingPathComponent("locked")
try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
expect(P.canOpen(tmp.path), "canOpen: readable folder")
chmod(locked.path, 0)
if getuid() != 0 { expect(!P.canOpen(locked.path), "canOpen: chmod 000 folder") }
p = P.plan(fileText: locked.path, isDirectory: there, canOpen: P.canOpen, holdsHome: holds)
if getuid() != 0 { expect(p.arguments.isEmpty && p.record.hasPrefix("off this start: no access to"), "chmod 000 folder: left out") }
chmod(locked.path, 0o755)
try? FileManager.default.removeItem(at: tmp)
expect(!P.canOpen("/no/such/folder"), "canOpen: missing folder")

// The home folder or a folder above it: refused, also when set by hand.
for h in ["/Users/me", "/users/ME", "/Users", "/Users/", "/"] {
    expect(P.holdsHome(h, home: home), "holds home: \(h)")
}
for h in ["/Users/me/Projects", "/Users/meme", "/Users/other", "/Volumes/USB"] {
    expect(!P.holdsHome(h, home: home), "does not hold home: \(h)")
}
p = plan("/Users/me\n")
expect(p.arguments.isEmpty && p.record == "off this start: /Users/me holds your home folder (your keys, every app's data): choose a folder inside it", "home folder: left out")
expect(plan("/Users").arguments.isEmpty, "folder above home: left out")
expect(P.refusal("/Users/me", holdsHome: holds) != nil, "choosing home: refused")
expect(P.refusal("/Users/me/Projects", holdsHome: holds) == nil, "choosing a project folder: fine")

// A line break in the name would save a shorter path (another folder).
expect(P.refusal("/Users/me/a\nb", holdsHome: holds)?.contains("line break") == true, "line break: refused")
expect(P.refusal("/Users/me/a\rb", holdsHome: holds) != nil, "carriage return: refused")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
