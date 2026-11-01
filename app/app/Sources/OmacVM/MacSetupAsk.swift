import AppKit
import OmacVMFeatures
import OmacVMWindow

/// Is this Mac set up for a VM (OmacVMFeatures' MacSetup): asked before each
/// start (AppDelegate.askMacHelpers) and shown in the window (AppState's
/// notice). A VM folder copied from another Mac has none of the Mac helpers
/// its features need, and the other Mac's token (2026-10-20: a new M1 Max
/// with the mini's VM, no gestures and no question). Nothing is installed
/// without the person: Update VM installs the helpers, and they ask macOS
/// for their permissions themselves.
extension MacSetup {
    /// `src/mac/install.sh --status` from the app's copy of OmacVM for VM
    /// `c` (about 0.1 s, reads only). Never on the main thread; `notch` is
    /// Mac.hasNotch, read there. nil when it could not say.
    static func probe(_ c: VMConfig, notch: Bool) -> MacSetup? {
        let script = Paths.resources.appendingPathComponent("omacvm/src/mac/install.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "--status", c.folder.path]
        var env = TestIdentity.environment()
        env["OMACVM_MAC_NOTCH"] = notch ? "notch" : "none"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The question before a start: the fix (Update VM, Check for Updates,
    /// a System Settings pane) or Later. Over a full-screen Space too (a
    /// start from there: omacvm start, --start), as USB's questions.
    @MainActor func ask(vm: String, personAsked: Bool) -> Answer {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title(vm: vm)
        a.informativeText = message(vm: vm)
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        AskKeys.take(a.window, personAsked: personAsked)
        return a.runModal() == .alertFirstButtonReturn ? .fix : .later
    }
}

/// Later, per VM (its folder): this problem with this app version
/// (MacSetup.laterKey) is not asked again before a start. A new problem, a
/// new app version, or the problem gone (cleared) asks again. The window's
/// notice stays either way.
enum MacSetupLater {
    static let key = "macHelpersLater"

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static func isQuiet(_ s: MacSetup, folder: URL) -> Bool {
        (UserDefaults.standard.dictionary(forKey: key)?[folder.standardizedFileURL.path] as? String) == s.laterKey(appVersion: appVersion)
    }

    static func remember(_ s: MacSetup, folder: URL) {
        var d = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        d[folder.standardizedFileURL.path] = s.laterKey(appVersion: appVersion)
        UserDefaults.standard.set(d, forKey: key)
    }

    static func clear(folder: URL) {
        guard var d = UserDefaults.standard.dictionary(forKey: key), d[folder.standardizedFileURL.path] != nil else { return }
        d[folder.standardizedFileURL.path] = nil
        UserDefaults.standard.set(d, forKey: key)
    }
}
