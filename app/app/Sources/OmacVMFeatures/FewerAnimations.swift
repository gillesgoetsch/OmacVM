import Foundation

/// Fewer animations (feature fewer-animations: experimental, off by default,
/// Omarchy 4.5; docs/features.md): Omarchy's own no-animations toggle in the
/// VM (animations, blur and shadows off), the same switch as `omarchy toggle
/// animations` and Omarchy's menu. Nothing of it runs on the Mac: the app only
/// switches it, as Mission Control (PendingSwitch while the VM is stopped,
/// `omacvm enable|disable` while it runs). Apart from the UI so it is tested
/// without a VM: `swift run features-tests`.
public enum FewerAnimations {
    public static let feature = "fewer-animations"

    /// Switched in the window while the VM is stopped: PendingSwitch, as Mac input.
    public static let switchState = PendingSwitch(feature: feature, defaultOn: false)

    public static func isOn(features text: String?) -> Bool { switchState.isOn(features: text) }

    public static let needs45 = "Needs Omarchy 4.5: Move to Omarchy 4.5 at the top of this window."
    public static let subtitle = "Less power while windows change focus. Changes Omarchy's look."

    /// The settings row: Mac input's rules (MacIME.row), and off and greyed
    /// out with the reason on an Omarchy below 4.5 (it has no such toggle).
    /// One that is on stays switchable, so it can go off.
    public static func row(record: String?, pending text: String?, omarchy: String?,
                           running: Bool, busy: Bool, cli: Bool) -> MacIME.Row {
        let p = switchState.pending(text)
        let on = p ?? isOn(features: record)
        if !on && MissionControl.omarchyBelow45(record: omarchy) { return MacIME.Row(on: false, enabled: false, note: needs45) }
        if busy { return MacIME.Row(on: on, enabled: false, note: nil) }
        if !running { return MacIME.Row(on: on, enabled: true, note: nil) }
        return MacIME.Row(on: on, enabled: cli, note: p != nil ? "Being set up in the VM for this start." : nil)
    }

    /// The (i) text of the window's row. The figures: docs/features.md
    /// (MacBook Air M2, the pointer moving across windows, whole Mac, A/B/B/A).
    public static let info = "Experimental. Turns on Omarchy's own \"no animations\" setting in the VM, the same one as Omarchy's menu and `omarchy toggle animations`: Hyprland then draws no animations, blur or shadows. Windows open, close and move at once, and a window's border changes colour at once when it gets the focus. Why it saves power: while a border's colour fades, Hyprland draws both windows again in every frame, so moving the pointer from one window to another redraws most of the screen. On a MacBook Air (M2) moving the pointer across windows took about 0.46 W less for the whole Mac. It changes how Omarchy looks; your window opacity stays as it is. Switching it in Omarchy's menu switches this too. Needs Omarchy 4.5."
}
