import AppKit
import CoreGraphics

/// The VM's keyboard tap. QEMU (a child of this app, so macOS asks about
/// OmacVM) puts an event tap in front of macOS's own key handling, so ⌘ Tab,
/// ⌘ Space and macOS's screenshot keys reach Omarchy while the VM has the
/// keyboard. It is an active tap at the HID level (ui/cocoa.m:
/// kCGHIDEventTap, kCGEventTapOptionDefault: it swallows the keys), and macOS
/// makes that only for an app allowed to control the computer
/// (CGPreflightPostEventAccess, listed under Accessibility). Input Monitoring
/// covers listen-only taps and does not count; AXIsProcessTrusted is a
/// separate answer too (#211). Without it QEMU writes "Could not create event
/// tap" into its log and those keys go to macOS instead. Seen on a MacBook
/// (2026-10-07): Input Monitoring on, "control the computer" off, tap refused;
/// the window's Allow… opened Input Monitoring, and the note stayed red.
enum KeyAccess {
    /// The answers QEMU gets too: both ask for org.omacvm.app (QEMU's
    /// requests count for the app that started it). No prompt.
    static var listen: Bool { CGPreflightListenEventAccess() }
    static var post: Bool { CGPreflightPostEventAccess() }

    /// What QEMU's tap needs, and all the window checks.
    static var allowed: Bool { post }

    /// macOS's answer now: this process keeps its first answer (a grant
    /// given in System Settings while OmacVM runs did not show until OmacVM
    /// was quit), a new process gets the current one. About 50 ms, at most
    /// 2 s; nil when the new process gave no answer.
    static func fresh() -> Bool? {
        guard let exe = Bundle.main.executablePath else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--key-access"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    /// One line for qemu.log (KeyNote and omacvm check read it). Input
    /// Monitoring only for the record.
    static var record: String {
        "keys: Input Monitoring \(listen ? "allowed" : "NOT allowed"), Accessibility (keys) \(post ? "allowed" : "NOT allowed") for OmacVM"
    }

    /// The head of qemu.log of the VM's last start: macOS's answer recorded
    /// then (`record`) and QEMU's "Could not create event tap" both come in
    /// QEMU's first second.
    static func lastLog(folder: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: folder.appendingPathComponent("logs/qemu.log")) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        return String(decoding: head, as: UTF8.self)
    }

    /// QEMU's own word from the VM's last start: its tap was refused.
    static func tapFailed(folder: URL) -> Bool {
        lastLog(folder: folder)?.contains("Could not create event tap") == true
    }

    /// The list in System Settings › Privacy & Security that holds "control
    /// the computer", by the name this macOS shows: "Accessibility", and
    /// "Device Control and Data Access" on macOS 27.2. System Settings' own
    /// text, so the window names the row the user looks for there. English,
    /// as the rest of the path: OmacVM has no other language, so macOS gives
    /// it the pane's English strings.
    static let listName: String = {
        let pane = Bundle(path: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex")
        return pane?.localizedString(forKey: "ACCESSIBILITY", value: "Accessibility", table: nil) ?? "Accessibility"
    }()

    /// Behind the (i): the steps.
    static var missingText: String {
        let app = (Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath
        let id = Bundle.main.bundleIdentifier ?? "org.omacvm.app"
        return "Without it, ⌘ Tab, ⌘ Space and ⌘ ⇧ 4 go to macOS instead of Omarchy. Input Monitoring is not enough.\n\n1. Allow… clears what macOS kept for an older OmacVM build (OmacVM can show as on and still not count) and opens System Settings › Privacy & Security › \(listName).\n2. Turn OmacVM on there. This note turns grey by itself.\n3. Quit the VM and start it again.\n\nStill red: select OmacVM there, remove it with −, add \(app) with + and turn it on. Or in Terminal: tccutil reset PostEvent \(id)"
    }

    /// macOS keeps "control the computer" (kTCCServicePostEvent) as an entry
    /// of its own next to Accessibility, tied to the signature of the build
    /// that made it. Without that entry macOS takes the Accessibility answer
    /// ("composed authorization" in tccd's log). An entry from an older build
    /// no longer matches and macOS refuses, whatever Accessibility says, and
    /// CGRequestPostEventAccess does not replace it. Seen on a MacBook
    /// (2026-10-07): tccd "Failed to match existing code requirement for
    /// subject org.omacvm.app and service kTCCServicePostEvent" (an entry
    /// pinned to an old build's cdhash) at every VM start, OmacVM on in the
    /// Accessibility list, the note red after Allow…. tccutil resets this
    /// app's own entries without an admin password.
    static func reset(_ service: String) {
        guard let id = Bundle.main.bundleIdentifier else { return }   // unbundled build
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = resetArguments(service, id: id)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
    }

    static func resetArguments(_ service: String, id: String) -> [String] { ["reset", service, id] }

    /// Allow…: nothing when macOS allows already (the note turns grey a few
    /// seconds after the switch in System Settings, so a click can come after
    /// it, and a reset would take that grant away). Else an old "control the
    /// computer" entry goes first; with Accessibility on that is all (allowed
    /// at once, no prompt). Else Accessibility's own entry may be an old one
    /// too: it goes as well, then macOS's prompt for "control the computer"
    /// (once per app; it lists OmacVM under Accessibility, switched off) and
    /// the Accessibility pane. `post` is macOS's answer now (`fresh`), never
    /// this process's kept one, and only its no resets an entry: without an
    /// answer Allow… does nothing. The parts are passed in for the test.
    static func allow(reset: (String) -> Void, post: () -> Bool?, ask: () -> Void) {
        guard post() == false else { return }
        reset("PostEvent")
        guard post() == false else { return }
        reset("Accessibility")
        ask()
    }

    /// Allow… in the window; macOS's answers and tccutil off the main
    /// thread, then `done`.
    static func request(done: @escaping @MainActor () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ask = false
            allow(reset: reset, post: fresh, ask: { ask = true })
            DispatchQueue.main.async {
                if ask {
                    _ = CGRequestPostEventAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                MainActor.assumeIsolated { done() }
            }
        }
    }

    /// Once per app run, when the note would be red: an old "control the
    /// computer" entry goes without a click (only this app's own entry, and
    /// only while macOS refuses). With Accessibility on the note goes away;
    /// else nothing changes (QEMU does not ask at start: only Allow… asks).
    private static var clearedOnce = false   // main thread only
    static func clearOldEntryOnce(done: @escaping @MainActor () -> Void) {
        guard !clearedOnce else { return }
        clearedOnce = true
        DispatchQueue.global(qos: .utility).async {
            reset("PostEvent")
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }
}
