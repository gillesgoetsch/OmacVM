import Foundation

/// Mission Control in the VM (feature mission-control: experimental, off by
/// default, Omarchy 4.5, needs Trackpad gestures; docs/features.md): the Mac
/// Mission Control plugin by Gilles Goetsch in Omarchy's shell, four fingers
/// up and down in the full-screen VM. Nothing of it runs on the Mac: the app
/// only switches it, as drag and drop (PendingSwitch while the VM is stopped,
/// `omacvm enable|disable` while it runs). Apart from the UI so it is tested
/// without a VM: `swift run features-tests`.
public enum MissionControl {
    public static let feature = "mission-control"

    /// Switched in the window while the VM is stopped: PendingSwitch, as Mac input.
    public static let switchState = PendingSwitch(feature: feature, defaultOn: false)

    public static func isOn(features text: String?) -> Bool { switchState.isOn(features: text) }

    /// The VM folder's omarchy record (`omacvm apply` writes it) names an
    /// Omarchy below 4.5. The same rule as OmarchyMove.Record (parse, then
    /// isMoved), src/lib/features.sh's omarchy_below_45 and the control
    /// centre's: the first word, the first two numbers in it. No record,
    /// "none" or a word that is no version: not below (the VM decides).
    public static func omarchyBelow45(record text: String?) -> Bool {
        guard let w = (text ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init),
              w != "none", w.count <= 40,
              w.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_+".contains($0)) }) else { return false }
        let n = w.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).prefix(2).compactMap { Int($0) }
        guard let major = n.first else { return true }
        let minor = n.count > 1 ? n[1] : 0
        return major < 4 || (major == 4 && minor < 5)
    }

    public static let needs45 = "Needs Omarchy 4.5: Move to Omarchy 4.5 at the top of this window."
    public static let needsGestures = "Needs Trackpad gestures."
    public static let onNote = "On: swipe up with four fingers in the full-screen VM."

    /// The settings row: Mac input's rules (MacIME.row), and off and greyed
    /// out with the reason where it cannot be on (Omarchy below 4.5, Trackpad
    /// gestures off). One that is on stays switchable, so it can go off.
    public static func row(record: String?, pending text: String?, omarchy: String?, gesturesOff: Bool,
                           running: Bool, busy: Bool, cli: Bool) -> MacIME.Row {
        let p = switchState.pending(text)
        let on = p ?? isOn(features: record)
        if !on && omarchyBelow45(record: omarchy) { return MacIME.Row(on: false, enabled: false, note: needs45) }
        if !on && gesturesOff { return MacIME.Row(on: false, enabled: false, note: needsGestures) }
        if busy { return MacIME.Row(on: on, enabled: false, note: nil) }
        if !running { return MacIME.Row(on: on, enabled: true, note: nil) }
        return MacIME.Row(on: on, enabled: cli, note: p != nil ? "Being set up in the VM for this start." : (on ? onNote : nil))
    }

    /// The (i) text of the window's row.
    public static let info = "Experimental. Swipe up with four fingers in the full-screen VM and its windows spread out, with your workspaces along the top; four fingers down close it. While it is open, four fingers sideways (two on a Magic Mouse) go through your workspaces; click a window to go to it, or drag it onto a workspace to move it there. ⌃↑ stays macOS's Mission Control unless every key combination goes to the VM (a hidden setting, see the docs). In a window, macOS's own Mission Control answers. Needs Trackpad gestures and Omarchy 4.5. The Mac Mission Control plugin by Gilles Goetsch (MIT)."
}
