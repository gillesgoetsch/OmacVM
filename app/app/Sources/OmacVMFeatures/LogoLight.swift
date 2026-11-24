import Foundation

/// The Apple logo's light (feature logo-light: opt-in, off by default;
/// docs/features.md, contributed in #844 and #845): `omacvm-logo` in the VM
/// sets the lit Apple logo on a MacBook Pro's lid through OmacVM Bridge. The
/// app only switches it, as Prefer VP9 (PendingSwitch while the VM is
/// stopped, `omacvm enable|disable` while it runs; both also set the Bridge's
/// `logo_light`). Apart from the UI so it is tested without a VM: `swift run
/// features-tests`.
public enum LogoLight {
    public static let feature = "logo-light"

    /// Switched in the window while the VM is stopped: PendingSwitch, as Mac input.
    public static let switchState = PendingSwitch(feature: feature, defaultOn: false)

    public static func isOn(features text: String?) -> Bool { switchState.isOn(features: text) }

    /// The row shows on a Mac with a lit logo (its PWM in the IORegistry,
    /// asked at run time), and on any Mac while it is on, so a VM brought
    /// from such a MacBook Pro can still switch it off.
    public static func shown(hasLogo: Bool, record: String?, pending text: String?) -> Bool {
        hasLogo || (switchState.pending(text) ?? isOn(features: record))
    }

    /// The settings row: Mac input's rules (MacIME.row).
    public static func row(record: String?, pending text: String?, running: Bool, busy: Bool, cli: Bool) -> MacIME.Row {
        let p = switchState.pending(text)
        let on = p ?? isOn(features: record)
        if busy { return MacIME.Row(on: on, enabled: false, note: nil) }
        if !running { return MacIME.Row(on: on, enabled: true, note: nil) }
        return MacIME.Row(on: on, enabled: cli, note: p != nil ? "Being set up in the VM for this start." : nil)
    }

    public static let subtitle = "omacvm-logo in the VM sets the lit Apple logo on the lid."

    /// The (i) text of the window's row.
    public static let info = "Lets the VM set the lit Apple logo on this MacBook Pro's lid: in the VM, omacvm-logo auto (macOS's own), off, on 1-100 (steady) or breathe 6-30 (breaths a minute); every change fades over 3 s. The logo stays dark while the display sleeps or the lid is closed, and it is macOS's again once no VM runs or OmacVM Bridge stops. It uses a private part of macOS (CoreBrightness), loaded only while this is on; a macOS update can break it, and then omacvm-logo says so. Shown only on a Mac with a lit logo. Off by default."
}
