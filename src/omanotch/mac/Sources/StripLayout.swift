import CoreGraphics

/// Where the bar image sits in the strip (points, top-left based).
struct StripLayout: Equatable {
    var scale: CGFloat  // guest logical px per point
    var left: CGFloat
    var top: CGFloat

    /// Full width, the height following the image's aspect (it equals the
    /// strip once the guest has sized NOTCH to it), at the strip's bottom.
    /// A few guest px too tall only means the hidden output was rounded up to
    /// whole pixels (fractional scales): that padding is cut off at the top
    /// only, so the strip's bottom row stays NOTCH's bottom row, which meets
    /// the display's top row (the wallpaper runs through; background patch).
    /// A really taller bar (its minimum height) is shrunk and centred instead.
    static func place(barWidth: CGFloat, barHeight: CGFloat, width: CGFloat, height: CGFloat) -> StripLayout {
        let k = barWidth > 0 && width > 0 ? barWidth / width : 1
        let excess = barHeight - height * k
        let shrink = height > 0 && excess > 4
        let s = shrink ? max(k, barHeight / height) : k
        let w = barWidth > 0 ? barWidth / s : width
        let h = barHeight / s
        let top = shrink ? ((height - h) / 2).rounded(.down) : height - h
        return StripLayout(scale: s, left: ((width - w) / 2).rounded(.down), top: top)
    }
}
