import Foundation

/// "omacvm in Terminal": a link to the app's own CLI
/// (Contents/Resources/omacvm/omacvm) in ~/.local/bin when that is on the
/// user's PATH, else in /usr/local/bin (macOS's default PATH; an administrator
/// makes the link there). Never over another omacvm: a checkout's
/// (install.sh) or anything that is not a link to an OmacVM app stays.
public enum CommandLineInstall {
    public static let appSuffix = "/Contents/Resources/omacvm/omacvm"

    /// What a path holds, as the planner needs it.
    public enum Entry: Equatable {
        case none
        /// A symbolic link and where it points (as written, made absolute).
        case link(to: String)
        /// A file or anything else that is not a link.
        case other
    }

    public enum State: Equatable {
        /// `omacvm` in Terminal runs this app's copy (at that path).
        case installed(at: String)
        /// Not there yet: Install makes the link at `target`.
        case available(target: String, needsAdmin: Bool)
        /// Another omacvm comes first on the PATH; nothing is changed.
        case other(at: String)
    }

    /// - path: the user's PATH (their login shell's), dirs split by ":".
    /// - entry: what a path holds; resolve: a link's final target (realpath).
    public static func state(path: String, home: String, appCLI: String,
                             entry: (String) -> Entry, resolve: (String) -> String?) -> State {
        let app = resolve(appCLI) ?? appCLI
        let dirs = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        // The first omacvm on the PATH is what Terminal runs.
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("omacvm")
            switch entry(p) {
            case .none: continue
            case .link(let to):
                if resolve(p) == app { return .installed(at: p) }
                // A link to an OmacVM app that is gone or older: ours to renew.
                if to.hasSuffix(appSuffix) { return .available(target: p, needsAdmin: !userDir(d, home: home)) }
                return .other(at: p)
            case .other:
                return .other(at: p)
            }
        }
        let local = home + "/.local/bin"
        let target = dirs.contains(local) ? local + "/omacvm" : "/usr/local/bin/omacvm"
        // Not on the PATH, but something sits there: leave it.
        switch entry(target) {
        case .other: return .other(at: target)
        case .link(let to) where !to.hasSuffix(appSuffix): return .other(at: target)
        default: return .available(target: target, needsAdmin: !userDir((target as NSString).deletingLastPathComponent, home: home))
        }
    }

    /// What `path` holds on disk.
    public static func entry(_ path: String) -> Entry {
        let fm = FileManager.default
        if let to = try? fm.destinationOfSymbolicLink(atPath: path) {
            return .link(to: to.hasPrefix("/") ? to : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(to))
        }
        return fm.fileExists(atPath: path) ? .other : .none
    }

    /// Why the app's own place is no good to link to, or nil: a copy macOS
    /// runs from a random temporary folder (App Translocation, the app was
    /// opened from Downloads) or from the disk image goes away and leaves a
    /// dead link.
    public static func placeProblem(appCLI: String, readOnlyVolume: Bool) -> String? {
        if appCLI.contains("/AppTranslocation/") || readOnlyVolume {
            return "Move OmacVM to Applications and open it from there first."
        }
        return nil
    }

    /// `path` with every link followed; nil when it leads nowhere.
    public static func resolve(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// `state` on this Mac's disk.
    public static func state(path: String, home: String, appCLI: String) -> State {
        state(path: path, home: home, appCLI: appCLI, entry: entry, resolve: resolve)
    }

    static func userDir(_ dir: String, home: String) -> Bool { dir == home || dir.hasPrefix(home + "/") }

    /// The shell command that makes the link (run with administrator rights
    /// for /usr/local/bin). `ln -sfn` replaces only what `state` allowed: no
    /// entry, or a link to an OmacVM app.
    public static func linkCommand(target: String, appCLI: String) -> String {
        let dir = (target as NSString).deletingLastPathComponent
        return "/bin/mkdir -p \(quote(dir)) && /bin/ln -sfn \(quote(appCLI)) \(quote(target))"
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// AppleScript's string quoting for `do shell script ... with administrator privileges`.
    public static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The OmacVM version of an omacvm (its checkout's or app copy's src/VERSION).
    public static func version(ofCLI cli: String) -> String? {
        let dir = ((resolve(cli) ?? cli) as NSString).deletingLastPathComponent
        guard let v = try? String(contentsOfFile: dir + "/src/VERSION", encoding: .utf8) else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(32))
    }

    /// OmacVM's version order, the same as version_cmp in src/lib/version.sh:
    /// -1, 0 or 1, nil when either is no version. Numbers by value (3.0.10 >
    /// 3.0.9, 3.0 == 3.0.0); a label after them is a pre-release, older than
    /// the release (3.0.5-rc1 < 3.0.5, rc9 < rc10); "+build" and a leading v
    /// are ignored.
    public static func compareVersions(_ a: String, _ b: String) -> Int? {
        func parse(_ s: String) -> (nums: [Double], label: [String])? {
            var t = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
            if t.first == "v" || t.first == "V" { t = t.dropFirst() }
            if let p = t.firstIndex(of: "+") { t = t[..<p] }
            guard let r = t.range(of: "^[0-9]+(\\.[0-9]+)*", options: .regularExpression) else { return nil }
            let nums = t[r].split(separator: ".").map { Double($0) ?? 0 }
            var label: [String] = [], cur = "", digits = false
            for ch in t[r.upperBound...] {
                let d = ch.isASCII && ch.isNumber, w = ch.isASCII && ch.isLetter
                if d || w {
                    if !cur.isEmpty && d != digits { label.append(cur); cur = "" }
                    cur.append(ch); digits = d
                } else if !cur.isEmpty { label.append(cur); cur = "" }
            }
            if !cur.isEmpty { label.append(cur) }
            return (nums, label)
        }
        guard let x = parse(a), let y = parse(b) else { return nil }
        for i in 0..<max(x.nums.count, y.nums.count) {
            let p = i < x.nums.count ? x.nums[i] : 0, q = i < y.nums.count ? y.nums[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        if x.label.isEmpty || y.label.isEmpty {
            return x.label.isEmpty == y.label.isEmpty ? 0 : (x.label.isEmpty ? 1 : -1)
        }
        for (p, q) in zip(x.label, y.label) {
            // Each part is all digits or all letters ("inf" is no number here).
            let pn = p.first?.isNumber == true ? Double(p) : nil, qn = q.first?.isNumber == true ? Double(q) : nil
            if let pn, let qn { if pn != qn { return pn < qn ? -1 : 1 }; continue }
            if pn != nil { return -1 }
            if qn != nil { return 1 }
            let pl = p.lowercased(), ql = q.lowercased()
            if pl != ql { return pl < ql ? -1 : 1 }
        }
        return x.label.count == y.label.count ? 0 : (x.label.count < y.label.count ? -1 : 1)
    }

    /// A is an older OmacVM than B (false when either is no version).
    public static func older(_ a: String?, than b: String?) -> Bool {
        guard let a, let b else { return false }
        return compareVersions(a, b) == -1
    }

    /// The other omacvm Terminal runs is older than this app's: what to say
    /// (#233: an old checkout on the PATH took a newer app's VM back), or nil.
    public static func olderNote(_ s: State, other: String?, app: String?) -> String? {
        guard case .other = s, let other, let app, older(other, than: app) else { return nil }
        return "That omacvm is OmacVM \(other), older than this app (\(app)): it leaves VMs with a newer OmacVM alone. Run omacvm update in Terminal, or remove it to use this app's."
    }

    /// The row's text.
    public static func text(_ s: State) -> String {
        switch s {
        case .installed: "Installed"
        case .available(let t, let admin): admin ? "Not installed (goes to \(t); macOS asks for your password)" : "Not installed (goes to \(t))"
        case .other(let at): "Another omacvm is installed at \(at): kept as it is"
        }
    }

    /// The row's short text; `text` goes into its (i).
    public static func shortText(_ s: State) -> String {
        switch s {
        case .installed: "Installed"
        case .available: "Not installed"
        case .other: "Another omacvm is installed"
        }
    }
}
