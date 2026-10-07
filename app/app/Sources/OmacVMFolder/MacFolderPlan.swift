import Foundation

/// The Mac folder (off by default): one folder of the Mac, shown in the VM at
/// ~/Mac. QEMU shares it over virtio-9p with its local backend, running as the
/// Mac user, so the VM reaches only what is inside that folder and only what
/// the Mac user may (QEMU opens each path below the folder without following
/// symlinks out of it). The VM's mac-folder file holds the path; the VM
/// mounts the share at each boot when it is there (omacvm-mac-folder).
/// Apart from the app so `swift run folder-tests` can check it.
public enum MacFolderPlan {
    /// The share's name in the VM (omacvm-mac-folder looks for it).
    public static let tag = "omacvm-mac"
    /// Omarchy's desktop user: the Mac user's files show as theirs
    /// (qemu-9p-guest-owner.patch), so the VM's own permission checks agree.
    public static let guestUID = 1000

    /// The folder in a mac-folder file's text: one absolute path on its first
    /// line; nil when the file is empty (off) or the path is not usable.
    public static func path(fromFile text: String?) -> String? {
        guard let line = text?.split(separator: "\n", omittingEmptySubsequences: false).first else { return nil }
        let p = String(line)
        guard p.hasPrefix("/"), p != "/", !p.contains("\0") else { return nil }
        // QEMU itself must not see "..": the folder is what the user picked.
        guard !p.split(separator: "/").contains("..") else { return nil }
        return p
    }

    /// What a start of the VM gets: QEMU's arguments and the line for
    /// qemu.log (omacvm check reads it).
    public struct Plan: Equatable {
        public let arguments: [String]
        public let record: String
    }

    /// Why `p` cannot be the Mac folder; nil when it can. `holdsHome`: `p` is
    /// the Mac user's home folder or a folder that holds it (~/.ssh, keychains
    /// and every app's data would be in the VM, and macOS would ask about each
    /// protected folder whenever something in the VM walks the tree).
    public static func refusal(_ p: String, holdsHome: (String) -> Bool) -> String? {
        // The mac-folder file keeps the path on one line: a line break would
        // cut it short and share another folder.
        if p.contains("\n") || p.contains("\r") || p.contains("\0") {
            return "its name has a line break: rename it or choose another folder"
        }
        if p == "/" || holdsHome(p) {
            return "\(p) holds your home folder (your keys, every app's data): choose a folder inside it"
        }
        return nil
    }

    /// `p` is `home` or a folder above it, by name (APFS ignores case by
    /// default). The app also compares the folders themselves.
    public static func holdsHome(_ p: String, home: String) -> Bool {
        let a = p.lowercased(), h = home.lowercased()
        return a == "/" || h == a || h.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    /// This process can open and list `p` now, as QEMU must at start. Denied
    /// in System Settings' Files and Folders, or no permission: false. macOS
    /// asks here, once, for a protected folder (Documents, Desktop, ...).
    public static func canOpen(_ p: String) -> Bool {
        guard let d = opendir(p) else { return false }
        defer { closedir(d) }
        errno = 0
        return readdir(d) != nil || errno == 0
    }

    /// The plan for a start. `fileText`: the mac-folder file (nil: none);
    /// `isDirectory`: the folder is there now; `canOpen`: the app may read
    /// it now (macOS privacy, permissions); `holdsHome`: see refusal. A
    /// folder that is not there or not readable is left out for this start,
    /// so the VM still starts: QEMU opens the folder at start and refuses to
    /// start when it cannot.
    public static func plan(fileText: String?, isDirectory: (String) -> Bool,
                            canOpen: (String) -> Bool, holdsHome: (String) -> Bool) -> Plan {
        guard let text = fileText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Plan(arguments: [], record: "off")
        }
        guard let p = path(fromFile: text) else {
            return Plan(arguments: [], record: "off this start: the setting is not a usable folder (choose it again)")
        }
        if let why = refusal(p, holdsHome: holdsHome) {
            return Plan(arguments: [], record: "off this start: \(why)")
        }
        guard isDirectory(p) else {
            return Plan(arguments: [], record: "off this start: \(p) is not there (a drive not connected?)")
        }
        guard canOpen(p) else {
            return Plan(arguments: [], record: "off this start: no access to \(p) (System Settings > Privacy & Security > Files and Folders, or the folder's permissions)")
        }
        // QEMU option values split at commas; a comma in a value is written twice.
        let q = p.replacingOccurrences(of: ",", with: ",,")
        return Plan(arguments: [
            // security_model=none: files keep the Mac user's owner and modes;
            // the VM sees them as its desktop user's. multidevs=remap: a disk
            // mounted inside the folder cannot give two files the same id.
            "-fsdev", "local,id=macfs,path=\(q),security_model=none,multidevs=remap,guest_owner_uid=\(guestUID),guest_owner_gid=\(guestUID)",
            "-device", "virtio-9p-pci,fsdev=macfs,mount_tag=\(tag)",
        ], record: "\(p) at ~/Mac")
    }
}
