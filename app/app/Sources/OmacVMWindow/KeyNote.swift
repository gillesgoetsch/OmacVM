import Foundation

/// What the VM window says about the keyboard (KeyAccess in the app).
/// QEMU's log of the VM's last start carries two lines that matter: the app's
/// record of macOS's answer at that start ("keys: Input Monitoring allowed,
/// ...") and QEMU's "Could not create event tap" when the tap was refused.
/// A refusal from a start before the user allowed OmacVM is old news: the
/// next start gets the tap.
public enum KeyNote: Equatable {
    /// Nothing to say.
    case none
    /// Allowed now; the VM that ran without it gets it at its next start.
    case allowedNextStart
    /// The red note with Allow….
    case needsUser

    /// - allowedNow: Input Monitoring or Accessibility allowed now.
    /// - lastLog: the head of logs/qemu.log (nil: none yet).
    public static func decide(allowedNow: Bool, lastLog: String?) -> KeyNote {
        guard allowedNow else { return .needsUser }
        guard let log = lastLog, log.contains("Could not create event tap") else { return .none }
        // The start that failed already had access: macOS still refuses this
        // build (an older signature): the user has to act.
        return startHadAccess(log) == true ? .needsUser : .allowedNextStart
    }

    /// What the app recorded at that start; nil when the log has no record.
    public static func startHadAccess(_ log: String) -> Bool? {
        guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.contains("keys: Input Monitoring") }) else {
            return nil
        }
        return line.contains("Input Monitoring allowed") || line.contains("Accessibility (keys) allowed")
    }

    public static let allowedText = "Keyboard: allowed (takes effect at the next VM start)"
}
