import Carbon
import Foundation

/// Apple ISO keyboards (#784, @epicoun): macOS reports the key left of 1 as
/// kVK_ISO_Section and the key left of Z (Y on German) as kVK_ANSI_Grave.
/// QEMU's key table makes those KEY_102ND and KEY_GRAVE, the other way round
/// from where Linux's layouts have them: on a German ISO keyboard ^ typed <
/// and < typed ^. QEMU's qemu-cocoa-iso-section-grave-swap.patch swaps the two
/// only when TRYOMARCHY_KEYBOARD=iso is in its environment, and nothing set it
/// before. The app sets it at each start from macOS's keyboard type, as OmacVM
/// Gestures does for the keys it forwards (src/gestures/mac/omacvm-gestures.c).
/// Apart from the UI so it is tested without a VM: `swift run features-tests`.
public enum ISOKeyboard {
    public static let variable = "TRYOMARCHY_KEYBOARD"

    /// The Mac's keyboard is ISO (macOS's answer for the keyboard in use).
    public static var isISO: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == PhysicalKeyboardLayoutType(kKeyboardISO)
    }

    /// QEMU's environment for one start: "iso" on an ISO keyboard, none on
    /// ANSI and JIS ones (also not one the app itself was started with).
    public static func apply(_ iso: Bool, to env: inout [String: String]) {
        if iso { env[variable] = "iso" } else { env.removeValue(forKey: variable) }
    }
}
