// Parallels, UTM and VMware Fusion VMs: retired in OmacVM 3.4.0 (AGENTS.md;
// never added back without the owner's explicit consent). The Bridge serves
// them nothing. It still listens on the Mac's address of those VM networks
// for one reason: an old VM's OmacVM 3.3 asks there, and gets one answer that
// says why and how to move, instead of a connection that fails without a word.
//   GET /proof?nonce=N  as on the Bridge's own addresses: the old VM checks it
//                       talks to the Bridge before it sends anything
//   GET /events         a stream that stays open: the text as a comment, then
//                       ": ping" every 15 s. The old VM's event service then
//                       connects once and stays quiet (it starts a new stream
//                       every 3 s while none is open)
//   anything else       410 {"error": the text, "code": "route-retired", "retired_in": "3.4.0"}
//                       (the control centre shows the error, Touch ID falls back to the password)
// Nothing here lists VMs, runs omacvm or reads the Mac's state. Pure parts
// first; the test (tests/retired, src/bridge/mac/test-retired.sh) runs the
// 3.3.0 guest clients against serveRetired.
import CryptoKit
import Foundation

let retiredIn = "3.4.0"
let retiredText = "This VM runs on a retired route (Parallels/UTM/VMware Fusion). OmacVM 3.4.0 supports OmacVM.app only: create a new VM in OmacVM.app and copy your files."
let retiredStreamsMax = 16
let retiredPingSeconds = 15.0

/// The Mac's address on the retired VM networks: Parallels' shared network,
/// UTM's shared network and VMware Fusion's NAT network (.1 of the subnet in
/// Fusion's `networking` file, when Fusion is installed).
func retiredAddrs(fusionNetworking: String?) -> [String] {
  ["10.211.55.2", "192.168.64.1"] + [retiredFusionHost(fusionNetworking)].compactMap { $0 }
}

func retiredAddrsOnThisMac() -> [String] {
  retiredAddrs(fusionNetworking: try? String(contentsOfFile: "/Library/Preferences/VMware Fusion/networking", encoding: .utf8))
}

/// The first VNET_8_HOSTONLY_SUBNET line, and only a private address that is
/// none of the Bridge's other ones.
func retiredFusionHost(_ text: String?) -> String? {
  guard let text else { return nil }
  for line in text.split(separator: "\n") {
    let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard f.count >= 3, f[0] == "answer", f[1] == "VNET_8_HOSTONLY_SUBNET" else { continue }
    let o = f[2].split(separator: ".").compactMap { UInt8($0) }
    guard o.count == 4, o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) else { return nil }
    let host = "\(o[0]).\(o[1]).\(o[2]).1"
    return ["10.211.55.2", "192.168.64.1", "192.168.77.1", "127.0.0.1"].contains(host) ? nil : host
  }
  return nil
}

enum RetiredReply: Equatable {
  case proof(String)   // the nonce
  case badNonce
  case events
  case gone
}

/// The request line's method and target -> the answer.
func retiredRoute(method: String, target: String) -> RetiredReply {
  let url = URLComponents(string: target)
  let path = url?.path ?? ""
  if method == "GET", path == "/proof" {
    guard let n = url?.queryItems?.first(where: { $0.name == "nonce" })?.value, n.utf8.count == 32,
          n.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return .badNonce }
    return .proof(n)
  }
  if method == "GET", path == "/events" { return .events }
  return .gone
}

/// As proof() in server.swift: HMAC-SHA256(token, "omacvm-bridge mac <addr> <nonce>"), hex.
func retiredProof(token: [UInt8], nonce: String, at addr: String) -> String {
  HMAC<SHA256>.authenticationCode(for: Data("omacvm-bridge mac \(addr) \(nonce)".utf8), using: SymmetricKey(data: token))
    .map { String(format: "%02x", $0) }.joined()
}

func retiredJSON(_ obj: [String: Any]) -> Data {
  ((try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8))
    + Data("\n".utf8)
}

/// The whole answer for a request that is not the proof or the stream.
func retiredGone() -> Data {
  let body = retiredJSON(["error": retiredText, "code": "route-retired", "retired_in": retiredIn])
  return Data("HTTP/1.1 410 Gone\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
}

/// The start of the held stream: its head and the text as an SSE comment.
func retiredStreamHead() -> Data {
  Data(("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
        + ": \(retiredText)\n\n").utf8)
}

// ---- sockets ----

private func retiredWrite(_ fd: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
    var off = 0
    while off < buf.count {
      let n = send(fd, buf.baseAddress! + off, buf.count - off, 0)
      if n <= 0 { return false }
      off += n
    }
    return true
  }
}

/// Answer, then read (and drop) what the VM still sends for at most a second,
/// so closing with unread bytes (a request's body) does not reset the
/// connection before the VM read the answer.
private func retiredClose(_ fd: Int32) {
  shutdown(fd, SHUT_WR)
  var tv = timeval(tv_sec: 1, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  var chunk = [UInt8](repeating: 0, count: 4096), left = 1 << 16
  while left > 0 {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    left -= n
  }
  close(fd)
}

/// The held /events streams: a ping every 15 s; one whose write fails goes.
/// At most retiredStreamsMax at once (one per old VM is usual).
final class RetiredStreams {
  private let q = DispatchQueue(label: "omacvm-bridge.retired")
  private var fds: [Int32] = []
  private var timer: DispatchSourceTimer?
  let max: Int, every: Double

  init(max: Int = retiredStreamsMax, every: Double = retiredPingSeconds) { self.max = max; self.every = every }

  var count: Int { q.sync { fds.count } }

  /// Takes the connection (it answers the head first), or false: full.
  func hold(_ fd: Int32) -> Bool {
    q.sync {
      guard fds.count < max else { return false }
      var tv = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      guard retiredWrite(fd, retiredStreamHead()) else { close(fd); return true }
      fds.append(fd)
      if timer == nil {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + every, repeating: every, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.ping() }
        t.resume()
        timer = t
      }
      return true
    }
  }

  private func ping() {
    let ping = Data(": ping\n\n".utf8)
    fds = fds.filter { fd in
      if retiredWrite(fd, ping) { return true }
      close(fd)
      return false
    }
    if fds.isEmpty { timer?.cancel(); timer = nil }
  }
}

/// One connection on a retired address. `at`: the Mac address it came in on.
func serveRetired(_ fd: Int32, at addr: String?, token: [UInt8], streams: RetiredStreams) {
  var one: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)   // BSD: accept() inherits O_NONBLOCK
  var tv = timeval(tv_sec: 2, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  // The head only, in at most 5 s and 16 KB.
  var buf = Data(), chunk = [UInt8](repeating: 0, count: 4096)
  let end = Data("\r\n\r\n".utf8), deadline = Date().addingTimeInterval(5)
  while buf.count < 16384, buf.range(of: end) == nil {
    let left = deadline.timeIntervalSinceNow
    guard left > 0.001 else { break }
    var rt = timeval(tv_sec: Int(left), tv_usec: max(1, Int32((left - left.rounded(.down)) * 1_000_000)))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rt, socklen_t(MemoryLayout<timeval>.size))
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { break }
    buf.append(contentsOf: chunk[0..<n])
  }
  guard let headEnd = buf.range(of: end) else { close(fd); return }
  let first = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")[0]
  let parts = first.split(separator: " ").map(String.init)
  let reply = parts.count == 3 ? retiredRoute(method: parts[0], target: parts[1]) : .gone
  switch reply {
  case .proof(let nonce):
    guard let addr else { close(fd); return }
    let body = retiredJSON(["proof": retiredProof(token: token, nonce: nonce, at: addr)])
    _ = retiredWrite(fd, Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
    retiredClose(fd)
  case .badNonce:
    let body = retiredJSON(["error": "nonce: 32 hex digits"])
    _ = retiredWrite(fd, Data("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
    retiredClose(fd)
  case .events:
    if !streams.hold(fd) {
      _ = retiredWrite(fd, retiredGone())
      retiredClose(fd)
    }
  case .gone:
    _ = retiredWrite(fd, retiredGone())
    retiredClose(fd)
  }
}
