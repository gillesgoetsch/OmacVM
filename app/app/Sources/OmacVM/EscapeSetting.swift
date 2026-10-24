import Foundation

/// "Escape combo" (Ctrl+Option+Esc in a full-screen VM): move only the
/// focused monitor between the VM and macOS (the default: the one with the
/// VM's focus, which Gestures asks the guest for, else the one under the
/// pointer), or all monitors that show the VM. OmacVM Gestures does the swipe and reads this
/// from its own settings domain, so `defaults write org.omacvm.gestures
/// EscapeSwipe all` sets it for the other routes (Parallels, UTM, Fusion) too.
///
/// The rules on their own (Foundation only): src/tests/app-escape-window.sh
/// compiles and tests them without the app.
enum EscapeSetting {
    static let domain = "org.omacvm.gestures"
    /// The test identity's app talks to its own Gestures (Info.plist
    /// OmacVMGesturesDomain, app/scripts/build-app.sh --test-identity).
    static let appDomain = Bundle.main.object(forInfoDictionaryKey: "OmacVMGesturesDomain") as? String ?? domain
    static let key = "EscapeSwipe"

    enum Choice: String, CaseIterable {
        case pointer, all
        var title: String {
            switch self {
            case .pointer: "Focused monitor"
            case .all: "All monitors"
            }
        }
    }

    /// What Gestures does with a stored value: "all" (any case) swipes all
    /// monitors, anything else the focused one.
    static func choice(stored: Any?) -> Choice {
        (stored as? String)?.lowercased() == Choice.all.rawValue ? .all : .pointer
    }

    static func current(_ d: UserDefaults? = UserDefaults(suiteName: appDomain)) -> Choice {
        choice(stored: d?.object(forKey: key))
    }

    static func set(_ c: Choice, _ d: UserDefaults? = UserDefaults(suiteName: appDomain)) {
        d?.set(c.rawValue, forKey: key)
    }
}
