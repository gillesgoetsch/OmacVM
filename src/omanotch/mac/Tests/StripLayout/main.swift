// Offline test of StripLayout: the strip's bottom row is NOTCH's bottom row.
import CoreGraphics
import Foundation

var fails = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { fails += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

// MacBook Air, scale 2: NOTCH 1470x33 logical, strip 1470x33 pt.
var p = StripLayout.place(barWidth: 1470, barHeight: 33, width: 1470, height: 33)
check(p == StripLayout(scale: 1, left: 0, top: 0), "Air at scale 2: image fills the strip exactly")

// 16-inch at scale 1.6: 2160 logical px on 1728 pt, strip 38 pt = 47.5 px,
// NOTCH rounded up to 50 px (80 device px).
p = StripLayout.place(barWidth: 2160, barHeight: 50, width: 1728, height: 38)
check(near(p.scale, 1.25), "scale 1.6: display's scale kept (\(p.scale))")
check(near(p.top + 50 / p.scale, 38), "scale 1.6: image bottom at the strip's bottom (top \(p.top))")
check(near((38 - p.top) * p.scale, 50), "scale 1.6: strip's bottom row is NOTCH's last row")

// Strip a fraction taller than NOTCH: the gap goes to the top, not the seam.
p = StripLayout.place(barWidth: 1470, barHeight: 33, width: 1470, height: 33.4)
check(near(p.top + 33, 33.4), "NOTCH a bit short: bottom-aligned, gap at the top")

// A bar really taller than the strip (big font): shrunk and centred as before.
p = StripLayout.place(barWidth: 2160, barHeight: 60, width: 1728, height: 38)
check(near(p.scale, 60.0 / 38), "tall bar: shrunk to the strip's height")
check(p.top == 0 && p.left > 0, "tall bar: centred (left \(p.left))")

print(fails == 0 ? "strip-layout: all ok" : "strip-layout: FAILED")
exit(fails == 0 ? 0 : 1)
