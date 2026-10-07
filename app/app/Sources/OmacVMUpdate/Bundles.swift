import CryptoKit
import Darwin
import Foundation
import Security

/// What an app bundle says about itself, read from its Info.plist directly
/// (Bundle(url:) caches per path, wrong for a bundle that was just swapped).
public struct BundleInfo: Equatable, Sendable {
    public var identifier: String
    public var version: String
    public var name: String

    public static func read(_ app: URL) -> BundleInfo? {
        guard let d = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let o = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any],
              let id = o["CFBundleIdentifier"] as? String,
              let v = o["CFBundleShortVersionString"] as? String else { return nil }
        return BundleInfo(identifier: id, version: v, name: o["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent)
    }
}

/// Code signatures, with Security.framework (as `codesign --verify --deep
/// --strict -R=REQUIREMENT`).
public enum CodeCheck {
    /// The Developer ID teams a signed document allows: 1 to 4 distinct
    /// Apple team IDs (10 capitals or digits). Missing, empty or anything
    /// else: nil, and the document is refused (never "any team").
    public static func teams(_ v: Any?) -> [String]? {
        guard let a = v as? [Any], (1...4).contains(a.count) else { return nil }
        var out: [String] = []
        for t in a {
            guard let s = t as? String, s.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
                  !out.contains(s) else { return nil }
            out.append(s)
        }
        return out
    }

    /// Developer ID Application, issued by Apple, of one of TEAMS (checked
    /// by teams() first: they go into the requirement's text).
    public static func developerID(teams: [String]) -> String {
        let ou = teams.map { "certificate leaf[subject.OU] = \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and (\(ou))"
    }

    /// nil when the code at URL is intact (nested code too) and meets the
    /// requirement; else why not.
    public static func problem(_ url: URL, requirement: String?) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return "\(url.lastPathComponent) has no readable code signature"
        }
        var req: SecRequirement?
        if let requirement {
            guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess else {
                return "bad requirement"
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var err: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &err)
        guard status == errSecSuccess else {
            let why = err.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "OSStatus \(status)"
            return status == errSecCSReqFailed
                ? "\(url.lastPathComponent) is not signed with a Developer ID the update feed allows"
                : "\(url.lastPathComponent): \(why)"
        }
        return nil
    }
}

public enum Files {
    /// SHA-256 of a file, read in 1 MB pieces.
    public static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hash = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// The one app at the top of an unpacked zip (a real folder, no link).
    public static func singleApp(in folder: URL) -> URL? {
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 != "__MACOSX" && !$0.hasPrefix(".") }
        guard items.count == 1, items[0].hasSuffix(".app") else { return nil }
        let app = folder.appendingPathComponent(items[0])
        let attrs = try? FileManager.default.attributesOfItem(atPath: app.path)
        return attrs?[.type] as? FileAttributeType == .typeDirectory ? app : nil
    }
}

/// Processes whose executable lies inside an app bundle: its QEMU while a VM
/// runs from it. The bundle is never replaced while one is there.
public enum Running {
    public static func pids(inside bundle: URL, except: pid_t = getpid()) -> [pid_t] {
        let prefix = realPath(bundle) + "/"
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var out: [pid_t] = []
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(got)) where pid > 0 && pid != except {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            if String(cString: buf).hasPrefix(prefix) { out.append(pid) }
        }
        return out
    }

    /// The kernel's path of a process's executable (links resolved). Not
    /// NSRunningApplication.executableURL: LaunchServices reports the app's
    /// own executable for the VM's QEMU (DockIdentity).
    public static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// A QEMU of the app at BUNDLE (any app when nil): its VM, not a launcher.
    public static func isQEMU(_ pid: pid_t, of bundle: URL? = nil) -> Bool {
        guard let p = path(of: pid), p.hasSuffix("/Contents/Resources/runtime/bin/OmacVM") else { return false }
        return bundle.map { p.hasPrefix(realPath($0) + "/") } ?? true
    }

    /// The path as the kernel reports executables: links resolved, /private
    /// kept (URL.resolvingSymlinksInPath drops it).
    public static func realPath(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(p) }
        return String(cString: p)
    }
}

/// Where the self-update keeps its files: one folder per copy of the app.
/// Two copies with one bundle id (OmacVM.app and a renamed Omarchy.app, a
/// test copy on a USB disk) must not share their kept version, staged
/// download or swap result.
public enum UpdateFolders {
    /// "<app name>-<first 8 hex digits of SHA-256 of its real path>": stays
    /// readable, differs per place. A moved app gets a new folder.
    public static func key(for bundle: URL) -> String {
        let path = Running.realPath(bundle)
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return "\(name)-\(hash)"
    }

    /// Where the swap keeps the previous and the incoming app. A rename only
    /// stays a rename on one volume (across volumes mv copies and deletes:
    /// slow, and half done when it fails), so these lie on the app's volume:
    /// HOME when it is there, else a hidden folder next to the app.
    public static func work(for bundle: URL, home: URL) -> URL {
        let parent = bundle.deletingLastPathComponent()
        if let a = device(parent), let b = device(home), a == b { return home }
        return parent.appendingPathComponent(".omacvm-updates/\(key(for: bundle))")
    }

    /// The volume a path lies on (its nearest existing folder: HOME may not
    /// be made yet).
    public static func device(_ url: URL) -> dev_t? {
        var u = url.standardizedFileURL
        while true {
            var st = stat()
            if stat(u.path, &st) == 0 { return st.st_dev }
            if u.path == "/" { return nil }
            u = u.deletingLastPathComponent()
        }
    }
}
