import Foundation

/// What the VM window says about the keyboard (KeyAccess in the app).
/// QEMU's tap is an active one: macOS makes it only when OmacVM may control
/// the computer (CGPreflightPostEventAccess, under Accessibility; Input
/// Monitoring does not count). QEMU's log of the VM's last start carries two
/// lines that matter: the app's record of macOS's answers at that start
/// ("keys: Input Monitoring allowed, Accessibility (keys) NOT allowed ...")
/// and QEMU's "Could not create event tap" when the tap was refused. A
/// refusal from a start before the user allowed OmacVM is old news: the next
/// start gets the tap.
public enum KeyNote: Equatable {
    /// Nothing to say.
    case none
    /// Allowed now; the VM that ran without it gets it at its next start.
    case allowedNextStart
    /// The red note with Allow….
    case needsUser

    /// - allowedNow: "control the computer" allowed now
    ///   (CGPreflightPostEventAccess, what QEMU's tap needs).
    /// - lastLog: the head of logs/qemu.log (nil: none yet).
    public static func decide(allowedNow: Bool, lastLog: String?) -> KeyNote {
        guard allowedNow else { return .needsUser }
        guard let log = lastLog, log.contains("Could not create event tap") else { return .none }
        // The start that failed already had it: macOS still refuses this
        // build (an older signature): the user has to act.
        return startHadAccess(log) == true ? .needsUser : .allowedNextStart
    }

    /// Whether that start had "control the computer" ("Accessibility (keys)"
    /// in the record; Input Monitoring at that start does not count); nil
    /// when the log has no record.
    public static func startHadAccess(_ log: String) -> Bool? {
        guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.contains("keys: Input Monitoring") }) else {
            return nil
        }
        return line.contains("Accessibility (keys) allowed")
    }

    public static let allowedText = "Allowed (takes effect at the next VM start)"
}
