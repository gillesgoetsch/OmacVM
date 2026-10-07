// The Bridge's external-brightness code with the feature off and on, without
// touching a real display: display 999999 does not exist, and with the
// feature on only that display is asked (no report, no start). Checks:
// - off: no look at any display at start, after a display change, for
//   omacvm check (report) or a key; the VM's requests are refused;
// - on: a display that found nothing is looked at again after retryNone on
//   the VM's request path too, not only on the key path;
// - the key path copies the window list once for both of its questions.
// Built and run by ../../test.sh (CI).
import AppKit

struct APIError: Error {
  let status: Int, message: String
  init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}
func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }
var on = false
let externalBrightness = ExternalBrightness { on }
var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok { failed += 1; print("FAIL (line \(line)): \(what)") }
}
func looks() -> Int { Thread.sleep(forTimeInterval: 0.2); return externalBrightness.looks }   // queued looks done
func status(_ f: () throws -> Any) -> Int {
  do { _ = try f(); return 200 } catch let e as APIError { return e.status } catch { return 500 }
}
let fake: CGDirectDisplayID = 999_999

// Off.
externalBrightness.start()
externalBrightness.displaysChanged()
check(externalBrightness.report().isEmpty, "off: omacvm check gets no displays")
check(externalBrightness.method(fake) == nil, "off: the key path finds nothing")
externalBrightness.step(fake, up: true, steps: BrightnessStep.defaultSteps)
check(status { try externalBrightness.get(fake) } == 409, "off: the VM's read is refused")
check(status { try externalBrightness.set(fake, percent: 50, delta: nil) } == 409, "off: the VM's write is refused")
Thread.sleep(forTimeInterval: 3.2)   // past the look at start (1 s) and after the display change (2 s)
check(looks() == 0, "off: no display looked at (DDC reads) at all")

// On, the made-up display only.
on = true
ExternalBrightness.retryNone = 3   // long enough for a slow CI runner between two checks
check(externalBrightness.method(fake) == nil, "on: not known yet, a look is queued")
check(looks() == 1, "on: the key path looked once")
check(externalBrightness.method(fake).map { !$0.works } == true, "on: the made-up display can't be set")
check(looks() == 1, "...and is not asked again at once")
check(status { try externalBrightness.get(fake) } == 409, "on: the VM's read: not settable")
check(looks() == 1, "...from the cache")
Thread.sleep(forTimeInterval: 3.2)
_ = status { try externalBrightness.get(fake) }
check(looks() == 2, "after retryNone the VM's request looks again")
Thread.sleep(forTimeInterval: 3.2)
_ = status { try externalBrightness.set(fake, percent: 10, delta: nil) }
check(looks() == 3, "...the VM's write too")
on = false

// One copy of the window list per key event.
var copies = 0
let front = FrontWindows(app: NSRunningApplication.current) { copies += 1; return [] }
check(copies == 0, "no copy before a question needs the windows")
_ = front.windows; _ = VMScreens.front(windowed: false, front); _ = front.windows
check(copies == 1, "the window list copied \(copies) times for one key event, want 1")

if failed > 0 { print("\(failed) failed"); exit(1) }
print("external brightness: off/on gate tests passed")
