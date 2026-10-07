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
