// Offline test of the camera's re-pick (camera.swift, run by test-camera.sh):
// which camera a start picks, and that the camera hub starts again after a
// loss (the lid closed, the camera unplugged, no picture), with whichever
// camera there is then. The hub talks to a made-up VM over a socket pair, as
// to a real one; the camera is a stand-in. No camera, no permission.
import Darwin
import Foundation

var failed = false
func check(_ ok: Bool, _ what: String) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failed = true }
}

// ---- the pick ----
let builtIn = CameraChoice(id: "builtin", builtIn: true, usable: true)
let lidClosed = CameraChoice(id: "builtin", builtIn: true, usable: false)
let lg = CameraChoice(id: "lg", builtIn: false, usable: true)
let opal = CameraChoice(id: "opal", builtIn: false, usable: true)
let gone = CameraChoice(id: "opal", builtIn: false, usable: false)
check(pickCamera([lg, builtIn], systemDefault: "lg") == "builtin", "pick: the built-in camera first")
check(pickCamera([lidClosed, lg], systemDefault: nil) == "lg", "pick: lid closed (built-in suspended): the display's camera")
check(pickCamera([lidClosed, lg, opal], systemDefault: "opal") == "opal", "pick: lid closed: macOS's default camera before the first")
check(pickCamera([lg, gone], systemDefault: "opal") == "lg", "pick: the default unplugged: the first one there is")
check(pickCamera([lidClosed], systemDefault: "builtin") == nil, "pick: only the closed lid's camera: none")
check(pickCamera([], systemDefault: nil) == nil, "pick: no camera: none")

// ---- the hub ----
/// The camera stand-in: start answers with the next name (or fails), frames
/// and failures come when the test says.
final class FakeSource: CameraSource {
  let test = false
  var onFrame: ((Data) -> Void)?
  var onFailure: ((String) -> Void)?
  var onCameraAdded: (() -> Void)?
  private let lock = NSLock()
  private var camera: String?   // what a start finds now; nil: no camera
  private(set) var starts = 0, stops = 0
  func answer(_ name: String?) { lock.lock(); camera = name; lock.unlock() }
  func start(_ done: @escaping (Result<String, CameraError>) -> Void) {
    lock.lock(); starts += 1
    let name = camera
    lock.unlock()
    DispatchQueue.global().async {
      if let name { done(.success(name)) } else { done(.failure(CameraError(reason: "no-camera", message: "no camera"))) }
    }
  }
  func stop() { lock.lock(); stops += 1; lock.unlock() }
  var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (starts, stops) }
}

/// The made-up VM's end: reads the hub's messages ("TOCM" headers) as they come.
final class VM {
  let fd: Int32
  private let lock = NSLock()
  private var statuses: [[String: Any]] = []
  private(set) var frames = 0
  init(_ fd: Int32) {
    self.fd = fd
    Thread.detachNewThread { self.read() }
  }
  func say(_ type: String) {
    let line = "{\"type\": \"\(type)\"}\n"
    _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
  }
  private func read() {
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = Darwin.read(fd, &chunk, chunk.count)
      if n <= 0 { return }
      buf.append(contentsOf: chunk[0..<n])
      while buf.count >= 16 {
        let b = [UInt8](buf.prefix(16))
        let len = Int(b[8]) | Int(b[9]) << 8 | Int(b[10]) << 16 | Int(b[11]) << 24
        guard buf.count >= 16 + len else { break }
        let payload = buf.subdata(in: buf.startIndex + 16 ..< buf.startIndex + 16 + len)
        buf.removeFirst(16 + len)
        lock.lock()
        if b[5] == 1, let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] { statuses.append(o) }
        if b[5] == 2 { frames += 1 }
        lock.unlock()
      }
    }
  }
  /// The statuses since the last call, as "streaming:<name>", "idle", "unavailable".
  func take() -> [String] {
    lock.lock(); defer { lock.unlock() }
    let out = statuses.map { s -> String in
      let st = s["status"] as? String ?? "?"
      return st == "streaming" ? "streaming:\(s["name"] as? String ?? "")" : st
    }
    statuses = []
    return out
  }
  var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }
}

/// Waits up to `seconds` for a condition.
func until(_ seconds: Double, _ ok: () -> Bool) -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end { if ok() { return true }; usleep(10_000) }
  return ok()
}

var logs: [String] = []
let logLock = NSLock()
let source = FakeSource()
let hub = CameraHub(log: { m in logLock.lock(); logs.append(m); logLock.unlock() }, source: source, firstRetry: 0.2, frameTimeout: 0.5)
var sv: [Int32] = [0, 0]
guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { print("FAIL socketpair"); exit(1) }
hub.attach(fd: sv[0], label: "test VM")
let vm = VM(sv[1])
var seen: [String] = []
func saw(_ s: String) -> Bool { seen += vm.take(); return seen.contains(s) }

// 1. A Linux app reads the camera: the built-in one starts and its frames go to the VM.
source.answer("FaceTime HD Camera")
vm.say("start")
check(until(2) { saw("streaming:FaceTime HD Camera") }, "start: the VM gets the built-in camera")
for _ in 0..<5 { source.onFrame?(Data(count: 16)); usleep(20_000) }
check(until(2) { vm.frameCount == 5 }, "start: its frames reach the VM")

// 2. The lid closes (the built-in camera suspended, or unplugged): the VM hears
//    it is gone, and soon gets the next camera there is, picked again.
seen = []
source.answer("LG UltraFine Display Camera")
let before = source.counts
source.onFailure?("FaceTime HD Camera is suspended (the lid closed?)")
check(until(2) { saw("unavailable") }, "lost: the VM hears the camera is gone")
check(until(2) { saw("streaming:LG UltraFine Display Camera") }, "lost: the next camera there is, started again")
check(source.counts.1 > before.1 && source.counts.0 == before.0 + 1, "lost: the old session ended, one new start (the pick comes with it)")
source.onFrame?(Data(count: 16))

// 3. A camera that stops giving pictures without a word: started again.
seen = []
source.answer("LG UltraFine Display Camera")
let quiet = source.counts.0
check(until(3) { saw("unavailable") && source.counts.0 > quiet }, "no picture for the timeout: the camera is started again")
check(until(2) { saw("streaming:LG UltraFine Display Camera") }, "no picture: streaming again")
source.onFrame?(Data(count: 16))

// 4. No camera at all (lid closed, the display's camera unplugged): it keeps
//    trying while the VM reads; a camera connected then is taken at once.
seen = []
source.answer(nil)
source.onFailure?("LG UltraFine Display Camera is gone")
check(until(3) { saw("unavailable") && source.counts.0 >= quiet + 3 }, "none there: it keeps trying while the VM reads")
_ = until(1.5) { false }   // the retries are 0.8 s apart and more by now
let waiting = source.counts.0
source.answer("Opal C1")
let at = Date()
source.onCameraAdded?()
check(until(2) { saw("streaming:Opal C1") }, "a camera connected: taken")
check(Date().timeIntervalSince(at) < 0.5 && source.counts.0 >= waiting + 1, "a camera connected: at once, not at the next retry")
source.onFrame?(Data(count: 16))

// 5. The VM stops reading: the camera goes off, nothing starts again.
seen = []
vm.say("stop")
check(until(2) { saw("idle") }, "stop: the VM hears idle")
let off = source.counts
_ = until(1.2) { false }
check(source.counts.0 == off.0 && source.counts.1 >= 1, "stop: off, and no start after it (no watchdog, no retry)")
source.onCameraAdded?()
_ = until(0.3) { false }
check(source.counts.0 == off.0, "stop: a camera connected later starts nothing")

logLock.lock()
let lines = logs
logLock.unlock()
check(lines.contains { $0.hasPrefix("stopped: no picture from LG UltraFine Display Camera for 1 s") }, "log: no picture, named")
check(lines.contains("back: LG UltraFine Display Camera"), "log: back, with the camera it took")
print(failed ? "FAIL camera" : "ok   camera: picked again after the lid closed, an unplug or no picture")
exit(failed ? 1 : 0)
