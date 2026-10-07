// inputlat PID MODE COUNT OUT.jsonl: input latency from a Mac event to the first changed picture of a
// QEMU window, as ScreenCaptureKit sees it on screen (WindowServer's display time of that frame).
// The events go to QEMU's own event queue (CGEventPostToPid): AppKit, QEMU's window code and the
// whole guest path, never another app and never the real cursor.
// MODE:
//   key      'x' and Backspace by turns, one every 250-400 ms (a terminal in the guest shows them)
//   pointer  the pointer jumps between two places, one move every 250-400 ms (the guest's pointer)
//   keymove  'key' while the pointer moves all the time in the window's lower right part (frames come
//            close together: the present's jitter-buffer path, not single frames)
// Environment: REGION=x0,y0,x1,y1 (fractions of the window) limits where a change counts (default:
// keymove the upper left part, else everything); QMP=/path/qmp.sock sends the keys or pointer moves
// through QMP instead (input-send-event: no AppKit, no window code), for comparison.
// Prints one JSON line per event to OUT and a summary line to stdout. Times: post = when the event was
// posted (wall clock, us, comparable with QEMU's -msg timestamp=on log), lat_ms = display time - post.
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

_ = NSApplication.shared
let args = CommandLine.arguments
guard args.count == 5, let pid = pid_t(args[1]), let count = Int(args[3]),
      ["key", "pointer", "keymove"].contains(args[2]) else {
  FileHandle.standardError.write("usage: inputlat PID key|pointer|keymove COUNT OUT.jsonl\n".data(using: .utf8)!)
  exit(2)
}
let mode = args[2], outPath = args[4]
let env = ProcessInfo.processInfo.environment
var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
func machMs(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e6 }
func wallUs() -> Double { var tv = timeval(); gettimeofday(&tv, nil); return Double(tv.tv_sec) * 1e6 + Double(tv.tv_usec) }

var region = mode == "keymove" ? [0.0, 0.0, 0.6, 0.6] : [0.0, 0.0, 1.0, 1.0]
if let r = env["REGION"] {
  let v = r.split(separator: ",").compactMap { Double($0) }
  guard v.count == 4, v[0] < v[2], v[1] < v[3] else { print("bad REGION"); exit(2) }
  region = v
}

/// Luminance samples of the region (every 2nd pixel); compared against the picture before an event.
final class Capture: NSObject, SCStreamOutput {
  let lock = NSLock()
  var last: [UInt8] = []
  var ref: [UInt8]? = nil       // the picture before the pending event
  var armedAt = 0.0             // mach ms of the pending event's post
  var hit: Double? = nil        // display time (mach ms) of the first changed frame
  var frames = 0, changedIdle = 0

  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen,
          let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
          (att[.status] as? Int) == SCFrameStatus.complete.rawValue,
          let dt = att[.displayTime] as? UInt64, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let x0 = Int(region[0] * Double(w)), x1 = Int(region[2] * Double(w))
    let y0 = Int(region[1] * Double(h)), y1 = Int(region[3] * Double(h))
    var cur = [UInt8]()
    cur.reserveCapacity(((x1 - x0) / 2 + 1) * ((y1 - y0) / 2 + 1))
    var y = y0
    while y < y1 {
      var x = x0
      let row = base + y * bpr
      while x < x1 {
        let p = row + x * 4
        cur.append(UInt8((Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) / 4))
        x += 2
      }
      y += 2
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    lock.lock()
    frames += 1
    if let r = ref, hit == nil, machMs(dt) > armedAt, r.count == cur.count {
      var n = 0
      for i in 0..<cur.count where abs(Int(cur[i]) - Int(r[i])) > 24 { n += 1; if n >= 3 { break } }
      if n >= 3 { hit = machMs(dt) }
    } else if ref == nil, !last.isEmpty, last.count == cur.count, last != cur {
      changedIdle += 1
    }
    last = cur
    lock.unlock()
  }
}

let cap = Capture()
let sem = DispatchSemaphore(value: 0)
var stream: SCStream?
var winFrame = CGRect.zero
var winID: CGWindowID = 0
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
  guard let wins = content?.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 }),
        let win = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
    print("no window of pid \(pid): \(String(describing: err))"); exit(1)
  }
  winFrame = win.frame
  winID = win.windowID
  let c = SCStreamConfiguration()
  c.width = Int(win.frame.width); c.height = Int(win.frame.height)
  c.minimumFrameInterval = CMTime(value: 1, timescale: 240)
  c.queueDepth = 8; c.showsCursor = false; c.pixelFormat = kCVPixelFormatType_32BGRA
  let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: c, delegate: nil)
  try! s.addStreamOutput(cap, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
  s.startCapture { e in if let e = e { print("start failed: \(e)"); exit(1) }; sem.signal() }
  stream = s
}
sem.wait()
Thread.sleep(forTimeInterval: 0.5)

// Events: to QEMU's queue only. Window frame: global, top-left origin (as CGEvent locations).
let src = CGEventSource(stateID: .privateState)
func key(_ code: CGKeyCode, _ down: Bool) {
  CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)?.postToPid(pid)
}
var lastMove = CGPoint(x: winFrame.midX, y: winFrame.midY)
let moveLock = NSLock()
func move(_ p: CGPoint) {
  guard let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
  moveLock.lock()
  e.setIntegerValueField(.mouseEventDeltaX, value: Int64(p.x - lastMove.x))
  e.setIntegerValueField(.mouseEventDeltaY, value: Int64(p.y - lastMove.y))
  // The window under the pointer (WindowServer fills these for real moves): AppKit routes the move by it.
  e.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(winID))
  e.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(winID))
  lastMove = p
  moveLock.unlock()
  e.postToPid(pid)
}
func at(_ fx: Double, _ fy: Double) -> CGPoint {
  CGPoint(x: winFrame.minX + fx * winFrame.width, y: winFrame.minY + fy * winFrame.height)
}

// QMP (keys only): a second way in, without AppKit.
var qmpFD: Int32 = -1
var qbuf = [UInt8](repeating: 0, count: 65536)
func qsend(_ s: String) { _ = s.withCString { write(qmpFD, $0, strlen($0)) } }
if let path = env["QMP"] {
  qmpFD = socket(AF_UNIX, SOCK_STREAM, 0)
  var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8CString)
  withUnsafeMutableBytes(of: &addr.sun_path) { d in bytes.withUnsafeBytes { s in _ = memcpy(d.baseAddress!, s.baseAddress!, min(d.count, s.count)) } }
  let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(qmpFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  guard ok == 0 else { print("qmp connect failed"); exit(1) }
  _ = read(qmpFD, &qbuf, qbuf.count)
  qsend("{\"execute\":\"qmp_capabilities\"}\n"); usleep(20000); _ = read(qmpFD, &qbuf, qbuf.count)
}
func qkey(_ qcode: String, _ down: Bool) {
  qsend("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":\(down),\"key\":{\"type\":\"qcode\",\"data\":\"\(qcode)\"}}}]}}\n")
}

// keymove: a pointer that never stops, 125 moves a second, in the lower right part (with QMP set,
// the moves go through QMP and the keys through AppKit).
var moving = true
let qmpMotion = mode == "keymove" && qmpFD >= 0
if mode == "keymove" {
  Thread.detachNewThread {
    var t = 0.0
    while moving {
      let fx = 0.8 + 0.1 * cos(t), fy = 0.8 + 0.1 * sin(t)
      if qmpMotion {
        qsend("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[" +
              "{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":\(Int(fx * 32767))}}," +
              "{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":\(Int(fy * 32767))}}]}}\n")
        _ = read(qmpFD, &qbuf, qbuf.count)
      } else {
        move(at(fx, fy))
      }
      t += 0.12
      usleep(8000)
    }
  }
}
if mode != "pointer" { move(at(0.95, 0.95)) }   // out of the text's way

// Before the run: how often the picture changes by itself (blinking cursor, clock).
cap.lock.lock(); cap.changedIdle = 0; cap.lock.unlock()
if mode != "keymove" { Thread.sleep(forTimeInterval: 1.5) }
cap.lock.lock(); let noise = cap.changedIdle; cap.lock.unlock()

var rows: [String] = [], lats: [Double] = []
var misses = 0
for i in 0..<count {
  usleep(UInt32(250_000 + arc4random_uniform(150_000)))
  cap.lock.lock()
  cap.ref = cap.last; cap.hit = nil; cap.armedAt = machMs(mach_absolute_time())
  cap.lock.unlock()
  let post = wallUs(), postMach = machMs(mach_absolute_time())
  var what = ""
  switch mode {
  case "pointer":
    let fx = i % 2 == 0 ? 0.3 : 0.6, fy = i % 2 == 0 ? 0.55 : 0.45
    if qmpFD >= 0 {
      // The tablet's own range (0..0x7fff) over the guest's output.
      qsend("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[" +
            "{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":\(Int(fx * 32767))}}," +
            "{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":\(Int(fy * 32767))}}]}}\n")
      usleep(20000); _ = read(qmpFD, &qbuf, qbuf.count)
    } else {
      move(at(fx, fy))
    }
    what = "move"
  default:
    let code: CGKeyCode = i % 2 == 0 ? 7 : 51     // kVK_ANSI_X, kVK_Delete (Backspace)
    if qmpFD >= 0 && !qmpMotion {
      let q = i % 2 == 0 ? "x" : "backspace"
      qkey(q, true); usleep(20000); qkey(q, false); _ = read(qmpFD, &qbuf, qbuf.count)
    } else {
      key(code, true); usleep(20000); key(code, false)
    }
    what = i % 2 == 0 ? "x" : "backspace"
  }
  // Wait up to 300 ms for the change.
  var hit: Double? = nil
  for _ in 0..<300 {
    cap.lock.lock(); hit = cap.hit; cap.lock.unlock()
    if hit != nil { break }
    usleep(1000)
  }
  cap.lock.lock(); cap.ref = nil; cap.lock.unlock()
  if let h = hit {
    let l = h - postMach
    lats.append(l)
    rows.append("{\"i\":\(i),\"ev\":\"\(what)\",\"post_us\":\(Int64(post)),\"lat_ms\":\(String(format: "%.2f", l))}")
  } else {
    misses += 1
    rows.append("{\"i\":\(i),\"ev\":\"\(what)\",\"post_us\":\(Int64(post)),\"lat_ms\":null}")
  }
}
moving = false
stream!.stopCapture { _ in sem.signal() }
sem.wait()
try! (rows.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
lats.sort()
func q(_ x: Double) -> Double { lats.isEmpty ? 0 : lats[min(lats.count - 1, Int(x * Double(lats.count)))] }
let mean = lats.isEmpty ? 0 : lats.reduce(0, +) / Double(lats.count)
print(String(format: "{\"mode\":\"%@\",\"via\":\"%@\",\"events\":%d,\"seen\":%d,\"missed\":%d,\"idle_changes_1_5s\":%d,\"p10\":%.1f,\"p50\":%.1f,\"p90\":%.1f,\"max\":%.1f,\"mean\":%.1f}",
             mode, qmpMotion ? "appkit keys, qmp motion" : qmpFD >= 0 ? "qmp" : "appkit", count, lats.count, misses, noise, q(0.1), q(0.5), q(0.9), lats.last ?? 0, mean))
