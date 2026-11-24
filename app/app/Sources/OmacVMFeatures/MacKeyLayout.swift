import Foundation

/// Mac key layout (#784): XKB's Mac variant of the VM's layout ("de mac":
/// Option-L = @, Option-5/6 = [ ], as on the Mac) or the PC layout ("de":
/// AltGr-Q = @). A new VM gets the Mac variant from its setup
/// (src/keyboard/mac-layout.sh); a VM from before keeps its PC layout until
/// the person picks the Mac variant in the Input card. The pairs are
/// mac-layout.sh's (src/keyboard/test.sh compares the two). In every Mac
/// variant only the right Option key types the Option characters; the left
/// one stays Alt for Omarchy's bindings.
/// Apart from the UI so it is tested without a VM: `swift run features-tests`.
public enum MacKeyLayout {
    /// PC layout and its Mac variant, as vm.env's KEYBOARD has them.
    public static let pairs: [(pc: String, mac: String)] = [
        ("de", "de mac"),
        ("ch de", "ch de_mac"),
        ("ch fr", "ch fr_mac"),
        ("fr", "fr mac"),
        ("gb", "gb mac"),
        ("it", "it mac"),
        ("nl", "nl mac"),
        ("pt", "pt mac"),
        ("se", "se mac"),
        ("dk", "dk mac"),
        ("fi", "fi mac"),
        ("is", "is mac"),
    ]

    /// The layout has both ways (the row shows only then).
    public static func hasChoice(_ keyboard: String) -> Bool {
        let k = normalized(keyboard)
        return pairs.contains { $0.pc == k || $0.mac == k }
    }

    public static func isMac(_ keyboard: String) -> Bool {
        let k = normalized(keyboard)
        return pairs.contains { $0.mac == k }
    }

    /// The layout with the Mac variant on or off; nil when it has no choice.
    public static func keyboard(_ keyboard: String, mac: Bool) -> String? {
        let k = normalized(keyboard)
        guard let p = pairs.first(where: { $0.pc == k || $0.mac == k }) else { return nil }
        return mac ? p.mac : p.pc
    }

    /// vm.env's KEYBOARD line for it: quoted, as VMConfig.write writes it.
    public static func envValue(_ keyboard: String) -> String { "'\(keyboard)'" }

    static func normalized(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    public static let title = "Mac key layout"
    public static let subtitle = "Option characters where the Mac has them, with the right Option key."
    public static let pending = "From the next Update VM."
    public static let info = "On: the VM types like the Mac's own layout. Right Option with a key gives what Option gives on the Mac, for example Option-L for @ on a German keyboard. Off: the PC layout VMs had before, where right Option works as AltGr (@ is right Option-Q on German). The left Option key stays Alt either way, so Omarchy's shortcuts keep working. New VMs start with it on. It counts from the next Update VM."
}
