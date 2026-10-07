import AppKit

/// "Features…" in the VM's app menu: OmacVM's control centre on the VM's
/// desktop. The menu is QEMU's (its window is in front while the VM runs,
/// omacvm-cocoa-features-menu.patch); a click there posts a distributed
/// notification under `requestName`, which QEMU gets as
/// OMACVM_FEATURES_REQUEST. This side runs the VM's own script for it through
/// the guest agent (src/control/guest/open.sh: one window, in front) and says
/// in an alert what is missing when it cannot. Main thread; the guest agent
/// is asked on a thread of its own.
@MainActor
final class ControlCentreRoute {
    nonisolated static let script = "/usr/local/share/omacvm/control/guest/open.sh"
    /// Exit code of the wrapper when the VM has no open.sh (an OmacVM from before 3.0.1).
    nonisolated static let tooOld: Int32 = 64

    let requestName: String
    private let agentPath: String
    private let vmName: String
    private let log: (String) -> Void
    private var observer: NSObjectProtocol?
    private var busy = false

    init(agentPath: String, vmName: String, log: @escaping (String) -> Void) {
        self.agentPath = agentPath
        self.vmName = vmName
        self.log = log
        requestName = "\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").features.\(getpid())"
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(requestName), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    /// One request at a time; clicks while one runs are dropped.
    private func open() {
        guard !busy else { return }
        busy = true
        let path = agentPath
        let wrapper = "[ -x \(Self.script) ] || exit \(Self.tooOld); exec \(Self.script)"
        Thread.detachNewThread { [weak self] in
            let outcome = GuestAgent.runAndWait(socketPath: path, "/bin/sh", ["-c", wrapper], seconds: 12)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(outcome) }
            }
        }
    }

    private func finish(_ outcome: GuestAgent.Outcome) {
        busy = false
        log("OmacVM: Features…: \(Self.record(outcome))")
        guard let (title, text) = Self.problem(outcome, vmName: vmName) else { return }
        let qemu = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
        qemu?.activate()
    }

    /// The VM's line: printable, one line, short (the guest is untrusted).
    nonisolated static func line(_ out: String) -> String {
        let last = out.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let clean = String(last.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        return String(clean.prefix(200))
    }

    /// For qemu.log.
    nonisolated static func record(_ outcome: GuestAgent.Outcome) -> String {
        switch outcome {
        case .noAgent: return "no answer from the guest agent"
        case .refused(let why): return "not started (\(line(why)))"
        case .running: return "no result within 12 s"
        case .badReply: return "the guest agent's reply could not be read (too long or not JSON)"
        case .exited(let code, let out): return "exit \(code): \(line(out))"
        }
    }

    /// What to tell the user (title, text); nil when it opened.
    nonisolated static func problem(_ outcome: GuestAgent.Outcome, vmName: String) -> (String, String)? {
        let enable = "omacvm enable control-centre --vm \"\(vmName)\""
        switch outcome {
        case .exited(0, _):
            return nil
        case .exited(3, _):
            return ("Log in to the VM first",
                    "The control centre opens on the VM's desktop once you are logged in there.")
        case .exited(5, _):
            return ("The control centre is off in this VM",
                    "Turn it on in Terminal on your Mac:\n\(enable)")
        case .exited(tooOld, _):
            return ("This VM has an older OmacVM",
                    "Bring it up to date (on your Mac: omacvm update), then try again. Until then: omacvm in a terminal in Omarchy, or OmacVM in the Omarchy menu.")
        case .exited(_, let out):
            let why = line(out)
            return ("The control centre did not open",
                    (why.isEmpty ? "The VM gave no reason." : "The VM says: \(why).")
                    + " In Omarchy: omacvm in a terminal, or OmacVM in the Omarchy menu.")
        case .noAgent, .refused:
            return ("The VM does not answer yet",
                    "It may still be starting. Try again once its desktop is there.")
        case .running:
            return ("The control centre did not open",
                    "The VM did not answer within 12 seconds. In Omarchy: omacvm in a terminal, or OmacVM in the Omarchy menu.")
        case .badReply:
            return ("The control centre did not open",
                    "The VM's answer could not be read. In Omarchy: omacvm in a terminal, or OmacVM in the Omarchy menu.")
        }
    }
}
