import Foundation

/// How tall the app's window may be. It takes its content's height, up to
/// what the screen shows below the menu bar and above the Dock; the rest
/// scrolls inside the window.
public enum WindowFit {
    /// A 13-inch MacBook at its default resolution with the menu bar and
    /// the Dock shows about this much: the VM window fits it whole in its
    /// usual state (checked with `OmacVM --render-vm-window`).
    public static let smallScreenHeight: Double = 760

    /// Below this the window does not shrink: a few rows stay in view.
    public static let minimumContent: Double = 320

    /// The content's height in the window: all of it when it fits on a
    /// screen whose visible height is `visible` (title bar included), else
    /// what fits; the rest scrolls.
    public static func contentHeight(content: Double, visible: Double, titleBar: Double) -> Double {
        min(content, max(visible - titleBar, minimumContent))
    }

    /// The window's whole height for that content.
    public static func windowHeight(content: Double, titleBar: Double) -> Double {
        content + titleBar
    }

    /// The window fits a 13-inch MacBook without scrolling.
    public static func fitsSmallScreen(content: Double, titleBar: Double) -> Bool {
        windowHeight(content: content, titleBar: titleBar) <= smallScreenHeight
    }
}
