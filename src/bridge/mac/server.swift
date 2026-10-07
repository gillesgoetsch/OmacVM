// HTTP server (BSD sockets, one thread per request), auth, routing, and the
// hub that tracks state and pushes changes to Server-Sent Events clients.
import CryptoKit
import Foundation

struct APIError: Error {
  let status: Int, message: String
  init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

/// GET /proof: HMAC-SHA256(token, "omacvm-bridge mac <addr> <nonce>") in hex,
/// <addr> the Mac address the request came in on. The VM checks it, its own
/// Mac address included, before it sends the token, so a program listening in
/// the Bridge's place (on 127.0.0.1 any Mac program could) never gets it, not
/// even by fetching a proof from the Bridge on 10.211.55.2.
func proof(_ nonce: String, at addr: String) -> String {
  HMAC<SHA256>.authenticationCode(for: Data("omacvm-bridge mac \(addr) \(nonce)".utf8), using: SymmetricKey(data: token))
    .map { String(format: "%02x", $0) }.joined()
}

/// The Mac address a connection came in on.
func localAddress(_ fd: Int32) -> String? {
  var sin = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
  let r = withUnsafeMutablePointer(to: &sin) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
  }
  return r == 0 && sin.sin_family == sa_family_t(AF_INET) ? ipv4String(sin.sin_addr) : nil
}

/// A connection from a program on this Mac rather than a VM: from 127.x, or
/// from one of the Mac's own addresses (a Mac program that connects to
/// 10.211.55.2 comes from 10.211.55.2, or from any address it binds to first).
func fromThisMac(_ fd: Int32, peer: String) -> Bool {
  if peer.hasPrefix("127.") || peer == localAddress(fd) { return true }
  var list: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&list) == 0 else { return true }   // cannot tell: refuse
  defer { freeifaddrs(list) }
  var p = list
  while let a = p?.pointee {
    if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
       ipv4String(UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr) == peer { return true }
    p = a.ifa_next
  }
  return false
}

func sameSecret(_ given: [UInt8], _ want: [UInt8]) -> Bool {
  guard given.count == want.count, !want.isEmpty else { return false }
  var diff: UInt8 = 0
  for i in 0..<given.count { diff |= given[i] ^ want[i] }   // constant time
  return diff == 0
}

func authorized(_ header: String?) -> Bool {
  guard let h = header, h.hasPrefix("Bearer ") else { return false }
  return sameSecret(Array(h.dropFirst(7).trimmingCharacters(in: .whitespaces).utf8), token)
}

/// OmacVM.app relaying a VM's control port request (X-OmacVM-Relay).
func relayAuthorized(_ header: String?) -> Bool {
  guard let h = header else { return false }
  return sameSecret(Array(h.trimmingCharacters(in: .whitespaces).utf8), relayKey)
}

// ---- sockets ----
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
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

func setTimeout(_ fd: Int32, _ opt: Int32, _ seconds: Int) {
  var tv = timeval(tv_sec: seconds, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, opt, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// Requests being handled (ConnectionGate in control_policy.swift): limits
/// per VM where the VM list knows the address, so slow or stuck peers cannot
/// hold every worker thread, and addresses a guest adds cannot take the known
/// VMs' places. Called from the listeners' queue and worker threads.
final class Gate {
  private let lock = NSLock()
  private var g = ConnectionGate()
  func enter(_ key: String, known: Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return g.enter(key, known: known) }
  func leave(_ key: String, known: Bool) { lock.lock(); defer { lock.unlock() }; g.leave(key, known: known) }
  func enterSlow(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return g.enterSlow(key) }
  func leaveSlow(_ key: String) { lock.lock(); defer { lock.unlock() }; g.leaveSlow(key) }
}
let gate = Gate()

/// Refusals in the log once a minute per key (LogLimiter): a peer that
/// floods must not fill the log the problem report reads.
private let refusalLock = NSLock()
private var refusals = LogLimiter()
func logRefusal(_ key: String, _ line: String) {
  refusalLock.lock()
  let skipped = refusals.admit(key, now: Date())
  refusalLock.unlock()
  guard let skipped else { return }
  log(skipped > 0 ? "\(line) (and \(skipped) more like it in the last minute)" : line)
}

func ipv4String(_ a: in_addr) -> String {
  var a = a, buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
  return String(cString: buf)
}

// ---- state + SSE clients ----
/// One pushed state (Wi-Fi, audio): re-read on events and every tick, sent only when it changed.
final class Feed {
  let event: String, delay: Double
  let read: () -> [String: Any]
  let describe: (_ old: [String: Any], _ new: [String: Any]) -> String?   // log line for notable changes
  /// What counts as a change worth sending at once; the rest (signal jitter)
  /// goes out at most every `minorSeconds`. nil: every change counts.
  let coarse: (([String: Any]) -> [String: Any])?
  fileprivate var compare = Data(), coarseCompare = Data(), state: [String: Any] = [:], seq = 0, pending = false
  fileprivate var sent = Date.distantPast, unsent = false

  init(event: String, delay: Double, read: @escaping () -> [String: Any],
       describe: @escaping ([String: Any], [String: Any]) -> String?,
       coarse: (([String: Any]) -> [String: Any])? = nil) {
    self.event = event; self.delay = delay; self.read = read; self.describe = describe; self.coarse = coarse
  }
}

final class Hub {
  private let q = DispatchQueue(label: "omacvm-bridge.hub")
  private let feeds: [Feed]
  private var clients: [Int32: String] = [:]
  private var external = Set<Int32>()   // clients that asked for external OSD events
  // One read source per client: a client never sends after its request, so
  // readable means it closed (or reset). Without this a closed client stays
  // counted until the next write fails, and writes are rare now.
  private var watchers: [Int32: DispatchSourceRead] = [:]

  private func drop(_ fd: Int32) {
    guard let peer = clients.removeValue(forKey: fd) else { return }
    external.remove(fd)
    if let w = watchers.removeValue(forKey: fd) { w.cancel() } else { close(fd) }   // the cancel handler closes it
    log("events: \(peer) disconnected (\(clients.count) left)")
  }
  private var lastSend = Date()
  private var timer: DispatchSourceTimer?
  /// Called (on the hub's queue) when the first client asks for external OSD
  /// events, and when the last one is gone.
  var onExternalOSD: ((Bool) -> Void)?

  init(_ feeds: [Feed]) { self.feeds = feeds }

  func start() {
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now(), repeating: tickSeconds, leeway: .milliseconds(500))
    t.setEventHandler { [self] in
      // Nobody listening: nothing to re-read (a new client and every request
      // read the current state anyway).
      guard !clients.isEmpty else { return }
      for f in feeds { refresh(f, "tick") }
      if Date().timeIntervalSince(lastSend) >= pingSeconds { write(": ping\n\n") }
    }
    t.resume()
    timer = t
  }

  private func feed(_ event: String) -> Feed { feeds.first { $0.event == event }! }

  // Events come in bursts; coalesce them per feed.
  func changed(_ event: String, why: String) {
    q.async { [self] in
      let f = feed(event)
      guard !f.pending else { return }
      f.pending = true
      q.asyncAfter(deadline: .now() + f.delay) { f.pending = false; self.refresh(f, why) }
    }
  }

  func current(_ event: String) -> [String: Any] { q.sync { let f = feed(event); refresh(f, "request"); return stamped(f) } }

  var hasClients: Bool { q.sync { !clients.isEmpty } }
  var clientCount: Int { q.sync { clients.count } }

  func send(_ event: String, _ obj: Any) { q.async { if !self.clients.isEmpty { self.broadcast(event, obj) } } }

  private func refresh(_ f: Feed, _ why: String) {
    let s = f.read(), cmp = jsonData(s)
    let due = f.unsent && Date().timeIntervalSince(f.sent) >= minorSeconds
    guard cmp != f.compare || due else { return }
    let old = f.state
    f.compare = cmp; f.state = s   // always the latest for /state and new clients
    let coarse = f.coarse.map { jsonData($0(s)) } ?? cmp
    if coarse == f.coarseCompare && !due { f.unsent = true; return }
    f.coarseCompare = coarse; f.seq += 1; f.sent = Date(); f.unsent = false
    if let line = f.describe(old, s) { log("\(f.event) (\(why)): \(line)") }
    broadcast(f.event, stamped(f))
  }

  private func stamped(_ f: Feed) -> [String: Any] {
    var s = f.state; s["seq"] = f.seq; s["updated_at"] = isoFormat.string(from: Date()); return s
  }

  private func broadcast(_ event: String, _ obj: Any) { write("event: \(event)\ndata: \(jsonString(obj))\n\n") }

  private func write(_ msg: String) {
    lastSend = Date()
    let data = Data(msg.utf8)
    let hadExternal = !external.isEmpty
    for (fd, _) in clients where !writeAll(fd, data) { drop(fd) }
    if hadExternal && external.isEmpty { onExternalOSD?(false) }
  }

  func addClient(_ fd: Int32, peer: String, externalOSD: Bool = false) {
    q.async { [self] in
      if clients.count >= maxClients { respond(fd, 503, ["error": "too many event clients"]); return }
      var first = "retry: 3000\n\n"
      for f in feeds { refresh(f, "events"); first += "event: \(f.event)\ndata: \(jsonString(stamped(f)))\n\n" }
      let head = httpHead(200, "text/event-stream", length: nil, extra: "X-Accel-Buffering: no\r\n")
      guard writeAll(fd, head + Data(first.utf8)) else { close(fd); return }
      clients[fd] = peer
      let w = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
      w.setEventHandler { [self] in
        var b = [UInt8](repeating: 0, count: 256)
        let n = recv(fd, &b, b.count, MSG_DONTWAIT)
        if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
          let hadExternal = !external.isEmpty
          drop(fd)
          if hadExternal && external.isEmpty { onExternalOSD?(false) }
        }
      }
      w.setCancelHandler { close(fd) }
      watchers[fd] = w
      w.resume()
      if externalOSD { external.insert(fd); if external.count == 1 { onExternalOSD?(true) } }
      log("events: \(peer) connected (\(clients.count) client\(clients.count == 1 ? "" : "s"))")
    }
  }
}

// ---- HTTP ----
let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 408: "Request Timeout", 405: "Method Not Allowed",
               409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable"]

func httpHead(_ code: Int, _ type: String, length: Int?, extra: String = "") -> Data {
  var h = "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\n"
  if let length { h += "Content-Length: \(length)\r\nConnection: close\r\n" } else { h += "Connection: keep-alive\r\n" }
  return Data((h + extra + "\r\n").utf8)
}

func respond(_ fd: Int32, _ code: Int, _ obj: Any, extra: String = "") {
  let body = jsonData(obj) + Data("\n".utf8)
  _ = writeAll(fd, httpHead(code, "application/json", length: body.count, extra: extra) + body)
  close(fd)
}

/// POST /audio/*: applies the change, returns a log line.
func audioControl(_ path: String, _ body: [String: Any]) throws -> String {
  let input = (body["scope"] as? String) == "input"
  switch path {
  case "/audio/volume":
    let absolute = (body["volume"] as? NSNumber)?.doubleValue, delta = (body["delta"] as? NSNumber)?.doubleValue
    guard absolute != nil || delta != nil else { throw APIError(400, "send {\"volume\": 0..1} or {\"delta\": -1..1}") }
    let r = try audio.setVolume(input: input, absolute: absolute, delta: delta, unmute: !input && (delta ?? 0) > 0)
    if !input { osdEvents.volumeSet(kind: "volume", source: "api") }
    return "\(input ? "input" : "output") volume \(r.volume)\(r.muted ? " (muted)" : "")"
  case "/audio/mute":
    let muted: Bool?
    switch body["muted"] {
    case let b as Bool: muted = b
    case let s as String where s == "toggle": muted = nil
    default: throw APIError(400, "send {\"muted\": true|false|\"toggle\"}")
    }
    let r = try audio.setMute(input: input, muted: muted)
    if !input { osdEvents.volumeSet(kind: "mute", source: "api") }
    return "\(input ? "input" : "output") muted=\(r.muted)"
  case "/audio/output", "/audio/input":
    guard let uid = body["uid"] as? String else { throw APIError(400, "send {\"uid\": \"<device uid>\"}") }
    let output = path == "/audio/output"
    return "default \(output ? "output" : "input") -> \(try audio.setDefault(uid: uid, output: output))"
  default:
    throw APIError(404, "not found")
  }
}

/// GET or POST /display/external-brightness: the external display the VM is
/// on. Everything from the VM is checked: a box (x, y, width, height: an
/// OmacVM.app output from its layout) only picks among the displays that show
/// an OmacVM.app window, without one the VM app in front decides; the display
/// must be external and settable; levels are 0-100.
func externalBrightnessRequest(_ query: [URLQueryItem], body: Data?) throws -> [String: Any] {
  guard config.externalBrightness else { throw APIError(409, "off on this Mac (external_brightness in the Bridge's config.json)") }
  let names = ["x", "y", "width", "height"]
  let given = names.compactMap { n in query.first { $0.name == n }?.value }
  var box: CGRect?
  if !given.isEmpty {
    let v = given.compactMap { Double($0) }
    guard given.count == 4, v.count == 4 else { throw APIError(400, "a box needs x, y, width and height (numbers)") }
    let b = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    guard DisplayPick.validBox(b) else { throw APIError(400, "box out of range") }
    box = b
  }
  var percent: Double?, delta: Double?
  if let body {
    guard let o = (body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      throw APIError(400, "send {\"brightness\": 0-100} or {\"delta\": -100..100}")
    }
    percent = (o["brightness"] as? NSNumber)?.doubleValue
    delta = (o["delta"] as? NSNumber)?.doubleValue
    guard (percent == nil) != (delta == nil) else { throw APIError(400, "send {\"brightness\": 0-100} or {\"delta\": -100..100}") }
    if let p = percent, !(p.isFinite && (0...100).contains(p)) { throw APIError(400, "brightness: 0-100") }
    if let d = delta, !(d.isFinite && (-100...100).contains(d)) { throw APIError(400, "delta: -100..100") }
  }
  // Windows and the front app: read on the main thread (this one is a connection's).
  let target: MacDisplay? = DispatchQueue.main.sync {
    if let box { return VMScreens.forBox(box) }
    return VMScreens.front(windowed: true)?.display
  }
  guard let t = target else { throw APIError(404, "no VM window in front on a display (or this output is not on one)") }
  guard !t.builtin else { throw APIError(409, "the built-in display: its brightness stays macOS's") }
  return body == nil ? try externalBrightness.get(t.id) : try externalBrightness.set(t.id, percent: percent, delta: delta)
}

func handle(_ fd: Int32, peer: String) {
  var one: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)   // BSD: accept() inherits O_NONBLOCK
  setTimeout(fd, SO_SNDTIMEO, 2)

  var buf = Data(), chunk = [UInt8](repeating: 0, count: 4096)
  let end = Data("\r\n\r\n".utf8)
  // Reads stop at a deadline for the whole head (and later the body), not
  // per read: a byte every few seconds no longer keeps a thread forever.
  var deadline = Date().addingTimeInterval(5)
  func readMore() -> Bool {
    let left = deadline.timeIntervalSinceNow
    guard left > 0.001 else { return false }   // {0, 0} would mean no timeout at all
    var tv = timeval(tv_sec: Int(left), tv_usec: max(1, Int32((left - left.rounded(.down)) * 1_000_000)))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let n = read(fd, &chunk, chunk.count)
    if n > 0 { buf.append(contentsOf: chunk[0..<n]) }
    return n > 0
  }
  while buf.count < 16384, buf.range(of: end) == nil, readMore() {}
  guard let headEnd = buf.range(of: end) else { close(fd); return }
  let lines = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
  let parts = lines[0].split(separator: " ")
  guard parts.count == 3 else { respond(fd, 400, ["error": "bad request"]); return }
  var headers: [String: String] = [:]
  for l in lines.dropFirst() {
    if let c = l.firstIndex(of: ":") {
      headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
    }
  }
  let method = String(parts[0]), url = URLComponents(string: String(parts[1]))
  let path = url?.path ?? "", query = url?.queryItems ?? []

  // The relay socket carries the control centre's requests only.
  if peer == relayPeer, !path.hasPrefix("/omacvm/") {
    respond(fd, 404, ["error": "only the control centre's requests come here"]); return
  }
  if method == "GET", path == "/proof" {   // no token: it is how the VM checks this is the Bridge
    guard let n = query.first(where: { $0.name == "nonce" })?.value, n.count == 32,
          n.allSatisfy({ "0123456789abcdef".contains($0) }) else {
      respond(fd, 400, ["error": "nonce: 32 hex digits"]); return
    }
    guard let at = localAddress(fd) else { respond(fd, 500, ["error": "no local address"]); return }
    respond(fd, 200, ["proof": proof(n, at: at)])
    return
  }
  guard authorized(headers["authorization"]) else {
    logRefusal("401 \(peer)", "401 \(logSafe(method)) \(logSafe(path)) from \(peer)")
    respond(fd, 401, ["error": "missing or wrong bearer token"], extra: "WWW-Authenticate: Bearer\r\n")
    return
  }
  // Bodies are small JSON, except a wallpaper image (read only after the token checked out).
  guard let wanted = Int(headers["content-length"] ?? "0"), wanted >= 0 else {
    respond(fd, 400, ["error": "bad Content-Length"]); return
  }
  let limit = path == "/wallpaper" ? 48 << 20 : path.hasPrefix("/omacvm/") ? controlBodyMax : 65536
  guard wanted <= limit else { respond(fd, 413, ["error": "body too large"]); return }
  // Long requests (a big body, a password dialog) at most two at once per VM:
  // they must not hold all its places (ConnectionGate).
  var slowKey: String?
  defer { if let k = slowKey { gate.leaveSlow(k) } }
  if (method == "POST" && path == "/wallpaper") || (method == "GET" && path == "/wifi/password") {
    let key = control.connectionKey(peer).key
    guard gate.enterSlow(key) else {
      logRefusal("slow \(key)", "busy: \(logSafe(path)) from \(peer) while two of its own run")
      respond(fd, 429, ["error": "busy: wait for this VM's last \(path == "/wallpaper" ? "wallpaper" : "Wi-Fi password") request"])
      return
    }
    slowKey = key
  }
  deadline = Date().addingTimeInterval(path == "/wallpaper" ? 120 : 5)
  while buf.count - headEnd.upperBound < wanted, readMore() {}
  let body = buf[headEnd.upperBound...].prefix(wanted)
  if path == touchIDPath {   // Touch ID for the VM's sudo and polkit (touchid.swift)
    touchIDRequest(fd: fd, peer: peer, method: method, path: path, headers: headers, body: Data(body))
    return
  }
  if path.hasPrefix("/omacvm/") {   // the control centre's fixed list (control.swift)
    control.handle(fd: fd, peer: peer, method: method, path: path, headers: headers, body: Data(body))
    return
  }
  switch (method, path) {
  case ("GET", "/state"):
    respond(fd, 200, hub.current("wifi"))
  case ("GET", "/scan"):
    let cached = query.contains { $0.name == "cached" && $0.value != "0" }
    let (code, body) = scanner.scan(cached: cached)
    respond(fd, code, body)
  case ("GET", "/audio"):
    respond(fd, 200, hub.current("audio"))
  case ("GET", "/display"):
    respond(fd, 200, hub.current("display"))
  case ("GET", "/display/external"):
    respond(fd, 200, ["enabled": config.externalBrightness, "displays": externalBrightness.report()])
  case (let m, "/display/external-brightness") where m == "GET" || m == "POST":
    do {
      let r = try externalBrightnessRequest(query, body: m == "POST" ? Data(body) : nil)
      if m == "POST" { log("\(path) from \(peer): \(r["display"] ?? "") -> \(r["brightness"] ?? "")") }
      respond(fd, 200, r)
    } catch let e as APIError {
      if m == "POST" { log("\(path) from \(peer) failed: \(e.message)") }
      respond(fd, e.status, ["error": e.message])
    } catch {
      respond(fd, 500, ["error": "\(error)"])
    }
  case ("GET", "/bluetooth"):
    respond(fd, 200, hub.current("bluetooth"))
  case ("GET", "/battery"):
    respond(fd, 200, hub.current("battery"))
  case ("POST", let p) where p.hasPrefix("/bluetooth/"):
    guard let obj = (body.isEmpty ? [:] : try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      respond(fd, 400, ["error": "body must be a JSON object"]); return
    }
    do {
      log("\(logSafe(p)) from \(peer): \(try bluetooth.control(p, obj))")
      respond(fd, 200, hub.current("bluetooth"))   // also pushes the change to /events clients
    } catch let e as APIError {
      log("\(logSafe(p)) from \(peer) failed: \(e.message)")
      respond(fd, e.status, ["error": e.message])
    } catch {
      respond(fd, 500, ["error": "\(error)"])
    }
  case ("GET", "/wifi/password"):
    let ssid = query.first { $0.name == "ssid" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    do { respond(fd, 200, try wifiPassword(ssid: ssid, peer: peer)) }
    catch let e as APIError { respond(fd, e.status, ["error": e.message]) }
    catch { respond(fd, 500, ["error": "\(error)"]) }
  case ("GET", "/events"):
    hub.addClient(fd, peer: peer, externalOSD: query.contains { $0.name == "osd" && $0.value == "external" })
  case ("POST", let p) where p.hasPrefix("/audio/") || p.hasPrefix("/display/"):
    guard let obj = (body.isEmpty ? [:] : try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
      respond(fd, 400, ["error": "body must be a JSON object"]); return
    }
    do {
      let audioPath = p.hasPrefix("/audio/")
      log("\(logSafe(p)) from \(peer): \(try audioPath ? audioControl(p, obj) : displayControl(p, obj))")
      respond(fd, 200, hub.current(audioPath ? "audio" : "display"))   // also pushes the change to /events clients
    } catch let e as APIError {
      log("\(logSafe(p)) from \(peer) failed: \(e.message)")
      respond(fd, e.status, ["error": e.message])
    } catch {
      respond(fd, 500, ["error": "\(error)"])
    }
  case ("POST", "/wallpaper"):
    do {
      let theme = headers["x-omarchy-theme"] ?? ""
      log("/wallpaper from \(peer): \(try setWallpaper(Data(body), theme: theme))")
      respond(fd, 200, ["ok": true])
    } catch let e as APIError {
      log("/wallpaper from \(peer) failed: \(e.message)")
      respond(fd, e.status, ["error": e.message])
    } catch {
      respond(fd, 500, ["error": "\(error)"])
    }
  // The camera is only for VMs. A Mac program could read the token file and
  // would get frames under the Bridge's camera permission, without asking
  // macOS itself. OmacVM.app's VMs use their virtio port, not 127.0.0.1.
  case ("GET", let p) where (p == "/camera" || p == "/camera/status") && fromThisMac(fd, peer: peer):
    log("403 \(logSafe(path)) from \(peer): the camera is only for VMs")
    respond(fd, 403, ["error": "the camera is only for VMs, not for programs on this Mac"])
  case ("GET", "/camera/status"):
    respond(fd, 200, camera.status())
  case ("GET", "/camera"):
    // From here on the connection carries the camera (camera.swift): the VM
    // says start and stop, the Bridge sends frames while it is started.
    guard camera.canAttach else { respond(fd, 503, ["error": "too many camera connections"]); return }
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-omacvm-camera\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    guard writeAll(fd, Data(head.utf8)) else { close(fd); return }
    var forever = timeval()
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
    camera.attach(fd: fd, label: peer, leftover: Data(buf[headEnd.upperBound...]))
  case ("POST", "/power"), ("POST", "/join"), ("POST", "/disconnect"):
    respond(fd, 501, ["error": "Wi-Fi control is not implemented yet (stage 2)"])
  case (_, "/state"), (_, "/scan"), (_, "/audio"), (_, "/display"), (_, "/bluetooth"), (_, "/battery"), (_, "/wifi/password"), (_, "/events"),
       (_, "/camera"), (_, "/camera/status"), (_, "/display/external"), (_, "/display/external-brightness"):
    respond(fd, 405, ["error": "method not allowed"])
  default:
    respond(fd, 404, ["error": "not found"])
  }
}

// Listens on one address only. The VM network's bridge interface appears when
// Parallels or UTM starts and can be recreated, so the listener follows it.
final class Server {
  private let q = DispatchQueue(label: "omacvm-bridge.listen")
  private var source: DispatchSourceRead?
  private var boundInterface: String?
  private var waitingLogged = false
  let onConnection: (Int32, String) -> Void
  let listenAddr: String

  init(addr: String, onConnection: @escaping (Int32, String) -> Void) {
    self.listenAddr = addr; self.onConnection = onConnection
  }

  func check(rebind: Bool = false) { q.async { self.checkLocked(rebind: rebind) } }

  var status: String {
    q.sync { boundInterface.map { "Listening on \(listenAddr):\(listenPort) (\($0))" } ?? "Waiting for \(listenAddr) (VM network not up)" }
  }

  private func interfaceOwningAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var p = list
    while let a = p?.pointee {
      if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
        let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
        if ipv4String(sin.sin_addr) == listenAddr { return String(cString: a.ifa_name) }
      }
      p = a.ifa_next
    }
    return nil
  }

  private func checkLocked(rebind: Bool) {
    let owner = interfaceOwningAddress()
    if source != nil, rebind || owner != boundInterface {
      log("listener: re-binding (\(listenAddr) on \(boundInterface ?? "-") -> \(owner ?? "gone"))")
      source?.cancel(); source = nil; boundInterface = nil
    }
    guard source == nil else { return }
    guard let owner else {
      if !waitingLogged { log("listener: waiting for \(listenAddr) to appear (VM network not up yet)"); waitingLogged = true }
      return
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = listenPort.bigEndian
    inet_pton(AF_INET, listenAddr, &sin.sin_addr)
    let ok = withUnsafePointer(to: &sin) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0 && listen(fd, SOMAXCONN) == 0   // a burst from one guest must not drop the others' connections
    guard ok else {
      log("listener: cannot listen on \(listenAddr):\(listenPort): \(String(cString: strerror(errno)))")
      close(fd); return
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
    src.setEventHandler { [onConnection] in
      while true {
        var peer = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &peer) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
        }
        if c < 0 { break }
        let who = ipv4String(peer.sin_addr)
        let (key, known) = control.connectionKey(who)
        guard gate.enter(key, known: known) else {
          close(c)
          if !known { control.unknownTurnedAway() }   // never waits: a run goes in the background
          logRefusal("busy \(key)", "busy: turned away a connection from \(who) (\(known ? "too many from this VM" : "too many from unknown addresses"))")
          continue
        }
        DispatchQueue.global(qos: .utility).async { onConnection(c, who); gate.leave(key, known: known) }
      }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    source = src; boundInterface = owner; waitingLogged = false
    log("listener: http://\(listenAddr):\(listenPort) on \(owner)")
  }
}

// OmacVM.app's relay (its NativeControlBridge.swift) on a channel of its own:
// a Unix socket only this Mac user can open (mode 0600 in the 0700 support
// folder, and the peer's user checked on every connection). The app's guests
// reach the Bridge from 127.0.0.1 like every program on this Mac, so on
// 127.0.0.1 they could use up the relay's places; here they cannot
// (ConnectionGate key "relay"). Only /omacvm/... is served on it.
let relayPeer = "relay"

final class RelaySocket {
  private let q = DispatchQueue(label: "omacvm-bridge.relay")
  private var source: DispatchSourceRead?
  private var bound: (dev: dev_t, ino: ino_t)?
  private var lastProblem: String?
  let path: String

  init(path: String) { self.path = path }

  /// Listens, or listens again when the socket file was removed or replaced.
  func check() { q.async { self.checkLocked() } }

  private func problem(_ s: String) {
    if s != lastProblem { log("relay socket: \(s)") }
    lastProblem = s
  }

  private func checkLocked() {
    if source != nil {
      var st = stat()
      if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, let b = bound, st.st_dev == b.dev, st.st_ino == b.ino { return }
      log("relay socket: \(path) was removed or replaced: listening again")
      source?.cancel(); source = nil; bound = nil
    }
    guard relaySocketPathOK(path) else {
      return problem("\(path) is too long for a Unix socket (\(relaySocketPathMax) bytes): OmacVM.app relays on 127.0.0.1")
    }
    // The folder: ours and private (connectSecure in the app checks the same).
    let dir = (path as NSString).deletingLastPathComponent
    var ds = stat()
    guard lstat(dir, &ds) == 0, (ds.st_mode & S_IFMT) == S_IFDIR, ds.st_uid == getuid() else {
      return problem("\(dir) is not a folder of this Mac user")
    }
    if ds.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
    // An old socket (a Bridge that stopped) goes; anything else stays and we give up.
    var st = stat()
    if lstat(path, &st) == 0 {
      guard (st.st_mode & S_IFMT) == S_IFSOCK else { return problem("\(path) exists and is not a socket") }
      unlink(path)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return problem("no socket: \(String(cString: strerror(errno)))") }
    var addr = sockaddr_un()
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    } == 0 && chmod(path, 0o600) == 0 && listen(fd, 64) == 0
    guard ok, lstat(path, &st) == 0 else {
      let e = String(cString: strerror(errno))
      close(fd)
      return problem("cannot listen on \(path): \(e)")
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
    src.setEventHandler {
      while true {
        let c = accept(fd, nil, nil)
        if c < 0 { break }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else {
          close(c)
          logRefusal("relay uid", "relay socket: refused a connection from another user (uid \(uid))")
          continue
        }
        guard gate.enter(relayPeer, known: true) else {
          close(c)
          logRefusal("busy relay", "busy: turned away a relay connection (too many at once)")
          continue
        }
        DispatchQueue.global(qos: .utility).async { handle(c, peer: relayPeer); gate.leave(relayPeer, known: true) }
      }
    }
    src.setCancelHandler { close(fd) }
    src.resume()
    source = src; bound = (st.st_dev, st.st_ino); lastProblem = nil
    log("relay socket: \(path)")
  }
}
