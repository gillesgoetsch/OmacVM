import Foundation

/// The app window's sides: every part of it at least an inset from the
/// window's edges, and the controls at the end of the rows of one card (or
/// of the header) on one line. Checked on the window pictures
/// (`OmacVM --render-vm-window`, a CI step).
public enum WindowLayout {
    /// The window's width (WindowSize).
    public static let width: Double = WindowSize.width
    /// The header's side margin; the settings sit further in.
    public static let inset: Double = 16
    /// The settings' column: beside the sidebar, 24 pt in from each side.
    public static let contentInset: Double = 24
    public static var contentWidth: Double { width - WindowSize.sidebar - 2 * contentInset }
    /// A card's rows: 16 pt in from the card's sides.
    public static let rowInset: Double = 16
    /// The sidebar's items: 10 pt in from its sides.
    public static let sidebarInset: Double = 10

    /// Edges this close count as one line.
    public static let tolerance: Double = 1

    /// Where a part of the window is, left to right, in points from the
    /// window's left edge.
    public struct Box: Equatable {
        public var name: String
        public var minX: Double
        public var maxX: Double

        public init(_ name: String, minX: Double, maxX: Double) {
            self.name = name
            self.minX = minX
            self.maxX = maxX
        }
    }

    /// What is wrong with these parts in a window `width` wide: closer than
    /// `inset` to an edge (or past it), and the `trailing` ones not ending
    /// on one line. Empty: all fine.
    public static func problems(_ boxes: [Box], width: Double, trailing: [String], inset: Double = inset) -> [String] {
        var out: [String] = []
        for b in boxes {
            if b.minX < inset - tolerance {
                out.append("\(b.name): \(Int(b.minX.rounded())) pt from the left edge (\(Int(inset)) at least)")
            }
            if width - b.maxX < inset - tolerance {
                out.append("\(b.name): \(Int((width - b.maxX).rounded())) pt from the right edge (\(Int(inset)) at least)")
            }
        }
        let ends = boxes.filter { trailing.contains($0.name) }
        if let first = ends.first, ends.contains(where: { abs($0.maxX - first.maxX) > tolerance }) {
            out.append("right edges not on one line: " + ends.map { "\($0.name) \(Int($0.maxX.rounded()))" }.joined(separator: ", "))
        }
        return out
    }
}
