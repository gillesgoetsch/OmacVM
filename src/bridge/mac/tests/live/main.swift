// Live tool for ../../test.sh --live: the Bridge's own external-brightness code
// against this Mac's real displays.
//   external-live report | get ID | set ID PERCENT
//   external-live keys ID N   N brightness-key steps up, then N down, at key-repeat speed
import AppKit

struct APIError: Error {
  let status: Int, message: String
  init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}
func log(_ s: String) { FileHandle.standardError.write(Data("\(s)\n".utf8)) }
let externalBrightness = ExternalBrightness { true }

func out(_ o: Any) {
  let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
  print(String(decoding: d, as: UTF8.self))
}
let a = CommandLine.arguments
do {
  switch (a.count > 1 ? a[1] : "", a.count) {
  case ("report", 2): out(externalBrightness.report())
  case ("get", 3): out(try externalBrightness.get(CGDirectDisplayID(a[2])!))
  case ("set", 4):
    out(try externalBrightness.set(CGDirectDisplayID(a[2])!, percent: Double(a[3])!, delta: nil))
    usleep(300_000)   // the write is queued: let it go out before exiting
  case ("keys", 4):
    let id = CGDirectDisplayID(a[2])!, n = Int(a[3])!
    var presses = 0
    externalBrightness.onKey = { _, _ in presses += 1 }
    let t0 = Date()
    for up in [true, false] {
      for _ in 0..<n { externalBrightness.step(id, up: up, steps: BrightnessStep.defaultSteps); usleep(33_000) }   // ~30 repeats a second
    }
    let queued = Date().timeIntervalSince(t0)
    usleep(500_000)   // the last coalesced write
    out(["presses": 2 * n, "applied": presses, "seconds_to_queue": (queued * 1000).rounded() / 1000])
  default: log("usage: external-live report | get ID | set ID PERCENT | keys ID N"); exit(2)
  }
} catch let e as APIError {
  log("\(e.status): \(e.message)"); exit(1)
}
