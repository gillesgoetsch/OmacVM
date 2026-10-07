/// A VM's record of its features: its features file, "bridge=on
/// fast-network=off ..." (src/lib/features.sh). The app's Fast network
/// button switches fast-network there too, so `omacvm features`, `omacvm
/// check` and the control centre say what the app does.
public enum FeaturesRecord {
    /// TEXT with NAME set to on or off (added when it is not named); the
    /// other words as they were.
    public static func set(_ text: String, _ name: String, on: Bool) -> String {
        var words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        let word = "\(name)=\(on ? "on" : "off")"
        if let i = words.firstIndex(where: { $0.hasPrefix("\(name)=") }) { words[i] = word } else { words.append(word) }
        return words.joined(separator: " ") + "\n"
    }
}
