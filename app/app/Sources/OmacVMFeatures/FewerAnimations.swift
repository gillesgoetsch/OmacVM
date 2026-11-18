import Foundation

/// Fewer animations (feature fewer-animations: experimental, off by default;
/// docs/features.md): OmacVM's own small Hyprland file in the VM
/// (animations/guest/install.sh) that turns the border animations off, so a
/// window's border takes its new colour at once when the focus moves. Every
/// other animation, blur and shadows stay as Omarchy has them; Omarchy's own
/// "no animations" toggle stays Omarchy's. Omarchy 4.0 and 4.5 alike. Nothing
/// of it runs on the Mac: the app only switches it, as Mission Control
/// (PendingSwitch while the VM is stopped, `omacvm enable|disable` while it
/// runs). Apart from the UI so it is tested without a VM: `swift run
/// features-tests`.
public enum FewerAnimations {
    public static let feature = "fewer-animations"

    /// Switched in the window while the VM is stopped: PendingSwitch, as Mac input.
    public static let switchState = PendingSwitch(feature: feature, defaultOn: false)

    public static func isOn(features text: String?) -> Bool { switchState.isOn(features: text) }

    public static let subtitle = "Less power while windows change focus: borders change colour at once."

    /// The settings row: Mac input's rules (MacIME.row).
    public static func row(record: String?, pending text: String?, running: Bool, busy: Bool, cli: Bool) -> MacIME.Row {
        let p = switchState.pending(text)
        let on = p ?? isOn(features: record)
        if busy { return MacIME.Row(on: on, enabled: false, note: nil) }
        if !running { return MacIME.Row(on: on, enabled: true, note: nil) }
        return MacIME.Row(on: on, enabled: cli, note: p != nil ? "Being set up in the VM for this start." : nil)
    }

    /// The (i) text of the window's row. The figure: docs/features.md
    /// (MacBook Air M2, the pointer moving across windows, whole Mac, A/B/B/A).
    public static let info = "Experimental. A window's border takes its new colour at once when the focus moves to it, instead of fading to it. Why it saves power: while a border's colour fades, Hyprland draws both windows again in every frame, so moving the pointer from one window to another redraws most of the screen. On a MacBook Air (M2) moving the pointer across windows took about 0.43 W less for the whole Mac. Every other animation, blur and shadows stay as Omarchy has them. It is OmacVM's own small Hyprland setting in the VM; Omarchy's own \"no animations\" switch in its menu stays Omarchy's and turns off much more. Works at once in a running VM."
}
