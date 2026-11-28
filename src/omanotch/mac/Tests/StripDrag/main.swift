// Offline test of StripDrag (#849): press, moves at most one per interval
// (the last one always), release; clamped to the bar; clicks on the release.
import CoreGraphics
import Foundation

var fails = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { fails += 1 }
}
var d = StripDrag()
d.size = CGSize(width: 1000, height: 26)
check(d.moved(CGPoint(x: 5, y: 5), now: 0) == nil, "a move with no press: nothing")
check(d.up(CGPoint(x: 5, y: 5)).isEmpty, "a release with no press: nothing")
check(d.down(CGPoint(x: 100, y: 10)) == .press(100, 10), "press: where it started")
check(d.moved(CGPoint(x: 110, y: 10), now: 1.0) == .drag(110, 10), "first move: sent")
check(d.moved(CGPoint(x: 120, y: 10), now: 1.01) == nil, "a move within the interval: kept")
check(d.moved(CGPoint(x: 130, y: 10), now: 1.02) == nil, "another: kept, the newest wins")
check(d.moved(CGPoint(x: 140, y: 10), now: 1.04) == .drag(140, 10), "after the interval: sent")
check(d.moved(CGPoint(x: 150, y: 10), now: 1.05) == nil, "kept again")
check(d.up(CGPoint(x: 155, y: 10)) == [.drag(150, 10), .release(155, 10)], "release: the kept move first, then the release")
check(!d.held, "released: not held")
_ = d.down(CGPoint(x: 300, y: 10))
check(d.up(CGPoint(x: 300, y: 10)) == [.release(300, 10)], "a click: press, release at the same place (the bar clicks)")
_ = d.down(CGPoint(x: 300, y: 10))
check(d.moved(CGPoint(x: 310, y: 400), now: 2) == .drag(310, 25), "below the strip: clamped to the bar (no remove)")
check(d.moved(CGPoint(x: -50, y: -9), now: 3) == .drag(0, 0), "left of and above it: clamped")
check(d.moved(CGPoint(x: 5000, y: 5), now: 4) == .drag(999, 5), "right of it: clamped")
check(d.cancel() == .release(-1, -1) && !d.held, "cancel while held: a release off the bar")
check(d.cancel() == nil, "cancel when not held: nothing")
_ = d.down(CGPoint(x: 100, y: 10))
check(d.moved(CGPoint(x: 101, y: 10), now: 5) == .drag(101, 10), "a quick drag: its first move (below the bar's threshold) sent")
check(d.moved(CGPoint(x: 140, y: 10), now: 5.01) == nil, "a quick drag: the move past it kept")
check(d.up(CGPoint(x: 140, y: 10)) == [.drag(140, 10), .release(140, 10)],
      "a quick drag released where its kept move ended: that move still goes first, so the bar drags instead of clicking at 140")
check(StripDrag.line(.press(1, 2.25)) == "press 1.0 2.2" || StripDrag.line(.press(1, 2.25)) == "press 1.0 2.3", "line: press")
check(StripDrag.line(.drag(10, 3)) == "drag 10.0 3.0" && StripDrag.line(.release(-1, -1)) == "release -1.0 -1.0", "line: drag, release")
if fails > 0 { print("\(fails) failed"); exit(1) }
print("all StripDrag checks passed")
