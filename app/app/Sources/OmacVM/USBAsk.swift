import AppKit
import OmacVMUSB

/// The question when a device is plugged in while the VM runs (USBSession),
/// as a standard macOS alert from this app: floating, on every Space and
/// over a full-screen window (as GPUMemory's alert), so it shows on the VM's
/// full-screen Space without switching. After the answer the VM's window
/// gets the keys back. Non-modal: the session can close it when the device
/// is unplugged. Both buttons and the box wait 0.5 s, so a Return typed into the VM
/// does not answer it.
@MainActor
final class USBAlertAsker: NSObject, @preconcurrency USBAsker {
    /// QEMU's process: it gets the keys back after an answer.
    var qemuPID: () -> pid_t? = { nil }
    private var alert: NSAlert?
    private var answer: ((USBAnswer) -> Void)?
    private var notices: [NSAlert] = []
    static let guardTime = 0.5

    func ask(_ q: USBQuestion, answer: @escaping (USBAnswer) -> Void) {
        close()
        let a = Self.alert(q)
        a.buttons[0].target = self
        a.buttons[0].action = #selector(connect)
        a.buttons[1].target = self
        a.buttons[1].action = #selector(keep)
        // The box too: a Space typed into the VM must not check it.
        let controls = a.buttons + [a.suppressionButton].compactMap { $0 }
        controls.forEach { $0.isEnabled = false }
        alert = a
        self.answer = answer
        show(a.window)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.guardTime) {
            controls.forEach { $0.isEnabled = true }
        }
    }

    /// The alert with the question's words (also drawn by RenderVMWindow).
    static func alert(_ q: USBQuestion) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = q.title
        a.informativeText = q.text + "\n\n" + q.detail
        let c = a.addButton(withTitle: q.connect)
        c.keyEquivalent = "\r"
        let k = a.addButton(withTitle: q.keep)
        k.keyEquivalent = "\u{1b}"
        a.showsSuppressionButton = true
        a.suppressionButton?.title = q.always
        a.suppressionButton?.state = .off
        a.suppressionButton?.setAccessibilityLabel(q.always)
        a.layout()
        return a
    }

    @objc private func connect() { answered(true) }
    @objc private func keep() { answered(false) }

    private func answered(_ connect: Bool) {
        guard let a = alert, let done = answer else { return }
        let always = a.suppressionButton?.state == .on
        close()
        backToVM()
        done(USBAnswer(connect: connect, always: always))
    }

    func cancel() {
        let wasOpen = alert != nil
        close()
        if wasOpen { backToVM() }
    }

    private func close() {
        alert?.window.orderOut(nil)
        alert = nil
        answer = nil
    }

    func notice(title: String, text: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        let ok = a.addButton(withTitle: "OK")
        ok.target = self
        ok.action = #selector(noticeDone(_:))
        a.layout()
        notices.append(a)
        show(a.window)
    }

    @objc private func noticeDone(_ sender: NSButton) {
        guard let i = notices.firstIndex(where: { $0.window == sender.window }) else { return }
        notices[i].window.orderOut(nil)
        notices.remove(at: i)
        if alert == nil && notices.isEmpty { backToVM() }
    }

    private func show(_ w: NSWindow) {
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.center()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func backToVM() {
        if let pid = qemuPID() { NSRunningApplication(processIdentifier: pid)?.activate() }
    }
}
