// The Mac's notifications on screen, as NotificationCenter's Accessibility
// tree shows them, and the action that closes each. notifications.swift walks
// the real tree; test-models.sh walks made-up ones (no Accessibility).

/// What the walk needs of an element of NotificationCenter's tree.
protocol NotificationElement {
  var subrole: String? { get }
  var actions: [String] { get }
  var children: [Self] { get }
}

enum MacNotifications {
  /// The banners and alerts on screen in NotificationCenter's `windows`, each
  /// with its Close action, in macOS's order. macOS 27 gives each one a group
  /// with the subrole AXNotificationCenterBanner (a banner, which goes by
  /// itself after a few seconds) or AXNotificationCenterAlert (an alert, which
  /// stays until it is closed). One without a Close action stays; a
  /// notification's own parts (its texts) are not walked.
  static func closable<E: NotificationElement>(_ windows: [E], close: String) -> [(element: E, action: String)] {
    var found: [(element: E, action: String)] = []
    func walk(_ e: E) {
      guard e.subrole?.hasPrefix("AXNotificationCenter") == true else { e.children.forEach(walk); return }
      if let action = e.actions.first(where: { closes($0, close) }) { found.append((e, action)) }
    }
    windows.forEach(walk)
    return found
  }

  /// macOS names an element's own actions "Name:<title>\nTarget:…\nSelector:…",
  /// the title in NotificationCenter's language ("Close", "Schließen").
  static func closes(_ action: String, _ close: String) -> Bool {
    action.split(separator: "\n", maxSplits: 1).first == Substring("Name:" + close)
  }
}
