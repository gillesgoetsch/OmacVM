import AppKit
import Foundation
import OmacVMFolder

/// The Mac folder setting (off by default): one folder of the Mac at ~/Mac in
/// the VM (MacFolderPlan says how). The VM's mac-folder file is the switch:
/// the folder's path, or no file. Applies from the VM's next start.
enum MacFolder {
    static func file(_ c: VMConfig) -> URL { c.folder.appendingPathComponent("mac-folder") }

    /// The folder this VM shares, nil when off.
    static func path(_ c: VMConfig) -> String? {
        MacFolderPlan.path(fromFile: try? String(contentsOf: file(c), encoding: .utf8))
    }

    /// QEMU's arguments for this start, and the qemu.log line.
    static func plan(_ c: VMConfig) -> MacFolderPlan.Plan {
        MacFolderPlan.plan(fileText: try? String(contentsOf: file(c), encoding: .utf8),
                           isDirectory: { p in
                               var dir: ObjCBool = false
                               return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
                           },
                           canOpen: MacFolderPlan.canOpen, holdsHome: holdsHome)
    }

    /// `p` is the home folder or holds it: by name, and by the folders
    /// themselves (another spelling of the same folder, such as
    /// /System/Volumes/Data/Users).
    static func holdsHome(_ p: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if MacFolderPlan.holdsHome(p, home: home) { return true }
        var s = stat()
        guard stat(p, &s) == 0 else { return false }
        var h = URL(fileURLWithPath: home)
        while true {
            var t = stat()
            if stat(h.path, &t) == 0, t.st_dev == s.st_dev, t.st_ino == s.st_ino { return true }
            if h.path == "/" { return false }
            h = h.deletingLastPathComponent()
        }
    }

    /// Why `url` cannot be the Mac folder; nil when it can.
    static func refusal(_ url: URL) -> String? {
        MacFolderPlan.refusal(url.standardizedFileURL.path, holdsHome: holdsHome)
    }

    /// Shares `url` from the next start (nil: off).
    static func set(_ url: URL?, for c: VMConfig) throws {
        guard let url else {
            try? FileManager.default.removeItem(at: file(c))
            return
        }
        if let why = refusal(url) {
            throw NSError(domain: "OmacVM", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
        }
        try Data("\(url.standardizedFileURL.path)\n".utf8).write(to: file(c), options: .atomic)
    }

    /// Asks for the folder (the Finder's panel). nil: cancelled.
    @MainActor static func choose(current: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "The VM can read and change everything in this folder, at ~/Mac."
        panel.directoryURL = current.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
