import AppKit

/// Gives a question the keys when no click of the person's reached this app:
/// a plug-in, a lost desktop, a timeout, a click in QEMU's menu, `omacvm start`.
/// NSApp.activate() only asks: another app in front must yield first, and
/// nothing yields here, so the question sat there without the keys (found
/// with 3.2.18, the same in 3.2.17). In front of an app nobody yields for,
/// the old "ignoring other apps" flag is what still works: macOS 15.8, 26.6
/// and 27.0 refuse activate() and activate(options: []) and honour the flag
/// (docs/adr/0068-ask-keys.md). It is deprecated: if macOS ever drops it,
/// questions go back to floating without the keys, and the person can still
/// click them. A panel that takes keys without activating is no way round:
/// QEMU stays in front with its keyboard grab.
/// The window floats on every Space and over a full-screen VM, so taking
/// the keys does not move the person to another Space.
@MainActor
public enum AskKeys {
    /// The half second in which a question's buttons wait: a Return typed
    /// into the VM a moment earlier does not answer it.
    public static let guardTime = 0.5

    /// A question from the VM's side: takes the keys from the VM, never from
    /// another app the person works in (the window floats there; a click answers it).
    public static func take(_ window: NSWindow, overVM vm: pid_t?) {
        float(window)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if takes(front: front, me: getpid(), vm: vm) { NSApp.activate(ignoringOtherApps: true) }
    }

    /// A question before a start. A start the person just asked for (also
    /// from a terminal) waits for it, so it takes the keys. A start that comes
    /// by itself (after an update's install, after Update VM) may come minutes
    /// later: the rule above, or Return meant for another app answers it.
    public static func take(_ window: NSWindow, personAsked: Bool) {
        float(window)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if takes(front: front, me: getpid(), vm: nil, personAsked: personAsked) { NSApp.activate(ignoringOtherApps: true) }
    }

    /// The person just asked, nobody's app is in front, or this one or the VM is.
    public nonisolated static func takes(front: pid_t?, me: pid_t, vm: pid_t?, personAsked: Bool = false) -> Bool {
        guard !personAsked, let front else { return true }
        return front == me || front == vm
    }

    /// Buttons and box off for guardTime. For a question whose Return does
    /// something and that comes with no warning. A run loop timer: a block
    /// on the main queue waits for ever while runModal runs inside another
    /// such block, and the buttons would stay off.
    public static func hold(_ alert: NSAlert) {
        hold(controls: alert.buttons + [alert.suppressionButton].compactMap { $0 })
    }

    public static func hold(controls: [NSControl]) {
        controls.forEach { $0.isEnabled = false }
        let timer = Timer(timeInterval: guardTime, target: Held(controls), selector: #selector(Held.done), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor private final class Held: NSObject {
        let controls: [NSControl]
        init(_ controls: [NSControl]) { self.controls = controls }
        @objc func done() { controls.forEach { $0.isEnabled = true } }
    }

    private static func float(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
