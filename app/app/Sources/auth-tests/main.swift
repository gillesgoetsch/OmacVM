// Touch ID's port relay for the app's VMs (OmacVMAuth), without a VM, a
// Bridge or a Touch ID dialog: the guest's port and the Bridge are socket
// pairs here.
//   cd app/app && swift run auth-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Darwin
import Foundation
import OmacVMAuth

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias R = AuthRelay
let nonce = String(repeating: "ab", count: 16)
let sig = String(repeating: "0f", count: 32)
let body = Data(#"{"kind":"sudo","user":"vincent","detail":"true","tty":"pts/0"}"#.utf8)
func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
func requestLine(id: String = nonce, auth: String? = nil, body b: Data = body) -> [String: Any] {
    ["op": "touchid", "id": id, "auth": auth ?? "1 1760000000 \(id) \(sig)", "proto": 1, "body": b.base64EncodedString()]
}

// MARK: Lines from the VM

if case .request(let r)? = R.parse(json(requestLine())) {
    expect(r.id == nonce && r.body == body && r.proto == 1 && r.auth.hasPrefix("1 1760000000 "), "request: parsed")
} else { expect(false, "request: parsed") }
expect(R.parse(json(["op": "ping", "id": nonce])) == .ping(nonce), "ping")
expect(R.parse(json(["op": "cancel", "id": nonce])) == .cancel(nonce), "cancel")
expect(R.parse(json(["op": "ping", "id": "AB" + String(nonce.dropFirst(2))])) == nil, "id: lower-case hex only")
expect(R.parse(json(["op": "ping", "id": "abc"])) == nil, "id: 32 digits")
expect(R.parse(json(["op": "other", "id": nonce])) == nil, "unknown op dropped")
expect(R.parse(Data("not json".utf8)) == nil, "not JSON dropped")
expect(R.parse(Data("[1]".utf8)) == nil, "not an object dropped")
let other = String(repeating: "cd", count: 16)
expect(R.parse(json(requestLine(auth: "1 1760000000 \(other) \(sig)"))) == nil, "auth's nonce must be the id")
expect(R.parse(json(requestLine(auth: "2 1760000000 \(nonce) \(sig)"))) == nil, "auth: version 1 only")
expect(R.parse(json(requestLine(auth: "1 -5 \(nonce) \(sig)"))) == nil, "auth: time digits only")
expect(R.parse(json(requestLine(auth: "1 1760000000 \(nonce) \(sig)\r\nX-Evil: 1"))) == nil, "auth: no header injection")
expect(R.parse(json(requestLine(auth: "1 1760000000 \(nonce) xyz"))) == nil, "auth: 64 hex digits")
expect(R.parse(json(requestLine(body: Data(repeating: 0x41, count: 1025)))) == nil, "body over 1 KB dropped")
expect(R.parse(json(requestLine(body: Data()))) == nil, "empty body dropped")
var badB64 = requestLine(); badB64["body"] = "%%%"
expect(R.parse(json(badB64)) == nil, "body not base64 dropped")
var big = requestLine(); big["pad"] = String(repeating: "x", count: 5000)
expect(R.parse(json(big)) == nil, "line over 4 KB dropped")

// MARK: To the Bridge and back

if case .request(let r)? = R.parse(json(requestLine())) {
    let h = String(decoding: R.httpRequest(r, headers: [("Authorization", "Bearer T"), ("X-OmacVM-Relay", "K"), ("X-OmacVM-App-VM", "Vk0=")]), as: UTF8.self)
    expect(h.hasPrefix("POST /omacvm/touchid HTTP/1.1\r\n"), "http: POST /omacvm/touchid")
    expect(h.contains("\r\nX-OmacVM-Auth: \(r.auth)\r\n") && h.contains("\r\nX-OmacVM-Relay: K\r\n") && h.contains("\r\nX-OmacVM-App-VM: Vk0=\r\n"),
           "http: the guest's signature and the app's headers")
    expect(h.contains("\r\nContent-Length: \(body.count)\r\n") && h.hasSuffix("\r\n\r\n" + String(decoding: body, as: UTF8.self)), "http: the body as sent")
}
let answerBody = Data("{\"result\":\"yes\"}\n".utf8)
let resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-OmacVM-Answer: \(sig)\r\nContent-Length: \(answerBody.count)\r\n\r\n".utf8) + answerBody
expect(R.parseResponse(resp) == R.Answer(status: 200, signature: sig, body: answerBody), "response: status, signature, body byte for byte")
expect(R.parseResponse(resp.prefix(resp.count - 3)) == nil, "response cut short: none")
expect(R.parseResponse(Data("garbage".utf8)) == nil, "not HTTP: none")
expect(R.parseResponse(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n{}".utf8)) == R.Answer(status: 403, signature: "", body: Data("{}".utf8)),
       "unsigned 403 passed on (the VM decides)")
let line = R.answerLine(id: nonce, R.Answer(status: 200, signature: sig, body: answerBody))
let lo = try! JSONSerialization.jsonObject(with: line.dropLast()) as! [String: Any]
expect(line.last == 0x0A && lo["id"] as? String == nonce && lo["status"] as? Int == 200 && lo["answer"] as? String == sig
       && Data(base64Encoded: lo["body"] as! String) == answerBody, "answer line: one line, body base64")
let none = try! JSONSerialization.jsonObject(with: R.answerLine(id: nonce, nil).dropLast()) as! [String: Any]
expect(none["status"] as? Int == 0 && none["body"] == nil, "no answer: status 0")

// MARK: The relay, end to end (socket pairs for the port and the Bridge)

func pair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    var one: Int32 = 1
    for f in fds { setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
    return (fds[0], fds[1])
}
func send(_ fd: Int32, _ o: [String: Any]) {
    var d = json(o); d.append(0x0A)
    _ = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}
/// Reads until the peer closes or `timeout`; returns the bytes and whether it closed.
func readAll(_ fd: Int32, timeout: Double, untilNewline: Bool = false, untilHeaders: Bool = false) -> (Data, Bool) {
    var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 50) > 0 else { continue }
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return (out, true) }
        out.append(contentsOf: buf[0..<n])
        if untilNewline, out.last == 0x0A { return (out, false) }
        if untilHeaders, let e = out.range(of: Data("\r\n\r\n".utf8)), out.count >= e.upperBound + body.count { return (out, false) }
    }
    return (out, false)
}

/// The next line for the VM that is not an ack (acks are counted), or empty.
var acks = 0
func readAnswer(_ fd: Int32, timeout: Double) -> (Data, Bool) {
    var buf = Data()
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex...nl]
            buf = Data(buf[(nl + 1)...])
            if let o = try? JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any], o["ack"] as? Bool == true { acks += 1; continue }
            return (Data(line), false)
        }
        let (d, closed) = readAll(fd, timeout: max(0.01, end.timeIntervalSinceNow), untilNewline: true)
        if d.isEmpty { return (Data(), closed) }
        buf.append(d)
    }
    return (Data(), false)
}

final class FakeBridge: @unchecked Sendable {
    let lock = NSLock()
    var requests: [Data] = []
    var closedEarly: [Bool] = []
    var answer: Data? = resp   // nil: never answers (a dialog up)
    var connects = 0
    var open = 0, mostOpen = 0   // Bridge connections open at once (this side's view, it closes late)
    var overlaps = 0             // a new connection while the relay still had the last one open
    var lastA: Int32 = -1
    func connect() -> Int32? {
        lock.lock()
        if lastA >= 0, fcntl(lastA, F_GETFD) != -1 { overlaps += 1 }
        lock.unlock()
        let (a, b) = pair()
        lock.lock(); connects += 1; open += 1; mostOpen = max(mostOpen, open); lastA = a; lock.unlock()
        Thread.detachNewThread { [self] in
            let (req, _) = readAll(b, timeout: 5, untilHeaders: true)
            lock.lock(); requests.append(req); let a = answer; lock.unlock()
            if let a {
                _ = a.withUnsafeBytes { write(b, $0.baseAddress, $0.count) }
            } else {
                let (_, closed) = readAll(b, timeout: 8)   // the dialog waits: until the relay drops it
                lock.lock(); closedEarly.append(closed); lock.unlock()
            }
            close(b)
            lock.lock(); open -= 1; lock.unlock()
        }
        return a
    }
    func wait(_ f: () -> Bool, _ t: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { lock.lock(); let ok = f(); lock.unlock(); if ok { return true }; usleep(20_000) }
        return false
    }
}

let headers: () -> [(String, String)]? = { [("Authorization", "Bearer T"), ("X-OmacVM-Relay", "K"), ("X-OmacVM-App-VM", "Vk0=")] }
func relay(_ fb: FakeBridge, headers h: @escaping () -> [(String, String)]? = headers, connect: (() -> Int32?)? = nil) -> (Int32, AuthRelay) {
    let (vm, app) = pair()
    let r = AuthRelay(guest: app, connectBridge: connect ?? { fb.connect() }, headers: h)
    r.pingTimeout = 0.6
    r.minimumGap = 0
    Thread.detachNewThread { try? r.run() }
    usleep(50_000)   // run() first drops what was already waiting
    return (vm, r)
}

// A yes from the Bridge reaches the VM unchanged.
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb)
    send(vm, ["op": "ping", "id": nonce])   // a ping for nothing: ignored
    send(vm, requestLine())
    let (got, _) = readAnswer(vm, timeout: 5)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["id"] as? String == nonce && o["status"] as? Int == 200 && o["answer"] as? String == sig
           && Data(base64Encoded: o["body"] as? String ?? "") == answerBody, "relay: the Bridge's signed answer to the VM, byte for byte")
    let req = String(decoding: fb.requests.first ?? Data(), as: UTF8.self)
    expect(req.contains("X-OmacVM-Auth: 1 1760000000 \(nonce) \(sig)\r\n") && req.contains("X-OmacVM-Relay: K\r\n"), "relay: request carries the guest's signature and the relay key")
    r.stop(); close(vm)
}

// No pings: the client is gone (Ctrl+C), the Bridge connection is dropped.
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, r) = relay(fb)
    let t0 = Date()
    send(vm, requestLine())
    expect(fb.wait({ fb.closedEarly.count == 1 }), "relay: no pings -> Bridge connection dropped")
    let dt = Date().timeIntervalSince(t0)
    expect(fb.closedEarly.first == true && dt < 2.5, "relay: dropped within the ping timeout (\(String(format: "%.2f", dt)) s)")
    let (got, _) = readAnswer(vm, timeout: 0.3)
    expect(got.isEmpty, "relay: nothing written for a client that is gone")
    r.stop(); close(vm)
}

// Pings keep it up; a cancel drops it at once.
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, r) = relay(fb)
    send(vm, requestLine())
    for _ in 0..<6 { usleep(250_000); send(vm, ["op": "ping", "id": nonce]) }   // 1.5 s, past the ping timeout
    expect(fb.closedEarly.isEmpty, "relay: pings keep the request up")
    let t0 = Date()
    send(vm, ["op": "cancel", "id": other])   // someone else's id: ignored
    send(vm, ["op": "cancel", "id": nonce])
    expect(fb.wait({ fb.closedEarly.count == 1 }, 1) && Date().timeIntervalSince(t0) < 0.6, "relay: cancel drops it at once")
    r.stop(); close(vm)
}

// A new request while one is open: the old one goes (one opener at a time).
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, r) = relay(fb)
    send(vm, requestLine())
    _ = fb.wait({ fb.requests.count == 1 })
    fb.lock.lock(); fb.answer = resp; fb.lock.unlock()
    send(vm, requestLine(id: other))
    expect(fb.wait({ fb.closedEarly.count == 1 }), "relay: a new request drops the old one")
    let (got, _) = readAnswer(vm, timeout: 5)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["id"] as? String == other && o["status"] as? Int == 200, "relay: the new one is answered")
    r.stop(); close(vm)
}

// The Bridge not set up, or not there: status 0 at once.
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb, headers: { nil })
    send(vm, requestLine())
    let (got, _) = readAnswer(vm, timeout: 2)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["status"] as? Int == 0 && fb.connects == 0, "relay: no Bridge token or relay key -> status 0, no connection")
    r.stop(); close(vm)
}
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb, connect: { nil })
    send(vm, requestLine())
    let (got, _) = readAnswer(vm, timeout: 2)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["status"] as? Int == 0, "relay: Bridge socket not there -> status 0")
    r.stop(); close(vm)
}

// Junk from the VM never reaches the Bridge; the relay keeps reading.
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb)
    let junk = Data(repeating: 0x41, count: 10000) + Data("\nnot json\n".utf8)
    _ = junk.withUnsafeBytes { write(vm, $0.baseAddress, $0.count) }
    send(vm, requestLine(auth: "1 1760000000 \(other) \(sig)"))
    send(vm, requestLine())
    let (got, _) = readAnswer(vm, timeout: 5)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["status"] as? Int == 200 && fb.connects == 1, "relay: junk and a bad line dropped, the good one relayed")
    r.stop(); close(vm)
}

// Lines written before the relay connected (nobody relayed): dropped, never to the Bridge.
do {
    let fb = FakeBridge()
    let (vm, app) = pair()
    send(vm, requestLine())
    let r = AuthRelay(guest: app, connectBridge: { fb.connect() }, headers: headers)
    Thread.detachNewThread { try? r.run() }
    usleep(300_000)
    expect(fb.connects == 0, "relay: a request from before the relay connected is dropped")
    acks = 0
    send(vm, requestLine(id: other))
    let (got, _) = readAnswer(vm, timeout: 5)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["id"] as? String == other && o["status"] as? Int == 200 && acks == 1, "relay: a new one: ack first, then the answer")
    r.stop(); close(vm)
}

// A VM that floods: requests closer than the gap get status 0, no Bridge connection.
do {
    let fb = FakeBridge()
    let (vm, app) = pair()
    let r = AuthRelay(guest: app, connectBridge: { fb.connect() }, headers: headers)
    Thread.detachNewThread { try? r.run() }
    usleep(50_000)
    send(vm, requestLine())
    _ = readAnswer(vm, timeout: 5)
    send(vm, requestLine(id: other))
    let (got, _) = readAnswer(vm, timeout: 2)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["id"] as? String == other && o["status"] as? Int == 0 && fb.connects == 1, "relay: a request right after another: status 0, not to the Bridge")
    usleep(600_000)
    send(vm, requestLine())
    let (got2, _) = readAnswer(vm, timeout: 5)
    let o2 = (try? JSONSerialization.jsonObject(with: got2.dropLast())) as? [String: Any] ?? [:]
    expect(o2["status"] as? Int == 200 && fb.connects == 2, "relay: after the gap, relayed again")
    r.stop(); close(vm)
}

// stop() from another thread: run() returns and closes the socket itself.
do {
    let fb = FakeBridge()
    let (vm, app) = pair()
    let r = AuthRelay(guest: app, connectBridge: { fb.connect() }, headers: headers)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { try? r.run(); done.signal() }
    usleep(100_000)
    r.stop()
    expect(done.wait(timeout: .now() + 2) == .success && fcntl(app, F_GETFD) == -1, "relay: stop() ends run(), which closes the socket")
    close(vm)
}

// The VM side closes (QEMU quits): run() returns, an open request is dropped.
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, app) = pair()
    let r = AuthRelay(guest: app, connectBridge: { fb.connect() }, headers: headers)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { try? r.run(); done.signal() }
    usleep(50_000)
    send(vm, requestLine())
    _ = fb.wait({ fb.requests.count == 1 })
    close(vm)
    expect(done.wait(timeout: .now() + 2) == .success, "relay: run() returns when the port's socket closes")
    expect(fb.wait({ fb.closedEarly.count == 1 }, 2), "relay: and the open request is dropped")
    r.stop()
}

// stop() after run() closed the socket (Runner does so) leaves the number
// alone: by then it may be another socket's.
do {
    let fb = FakeBridge()
    let (vm, app) = pair()
    let r = AuthRelay(guest: app, connectBridge: { fb.connect() }, headers: headers)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { try? r.run(); done.signal() }
    usleep(50_000)
    close(vm)
    _ = done.wait(timeout: .now() + 2)
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let other = fds.contains(app) ? app : -1
    r.stop()
    if other >= 0 {
        let peer = fds[0] == other ? fds[1] : fds[0]
        var b: UInt8 = 7
        expect(write(peer, &b, 1) == 1 && read(other, &b, 1) == 1, "relay: stop() after the close does not shut a reused descriptor")
    } else {
        print("note: descriptor not reused, the reuse check did not run")
    }
    close(fds[0]); close(fds[1])
}

// A VM that floods requests while the Bridge's dialog is up: one Bridge
// connection at a time (a new request waits for the dropped one to end).
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, r) = relay(fb)
    for i in 0..<12 {
        send(vm, requestLine(id: String(format: "%032x", i + 1)))
        usleep(30_000)
    }
    _ = fb.wait({ fb.closedEarly.count >= 10 }, 4)
    fb.lock.lock(); let overlaps = fb.overlaps, connects = fb.connects; fb.lock.unlock()
    expect(overlaps == 0 && connects >= 2, "flood: one Bridge connection at a time (\(overlaps) overlaps, \(connects) in all)")
    r.stop(); close(vm)
}

// A VM that never reads its answers: the write gives up, the port is dropped.
do {
    let fb = FakeBridge()
    fb.answer = Data("HTTP/1.1 200 OK\r\nContent-Length: 4000\r\n\r\n".utf8) + Data(repeating: 0x7B, count: 4000)
    let (vm, app) = pair()
    var small: Int32 = 2048
    setsockopt(app, SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(vm, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
    let r = AuthRelay(guest: app, connectBridge: { fb.connect() }, headers: headers)
    r.writeTimeout = 0.3
    r.minimumGap = 0
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { try? r.run(); done.signal() }
    let t0 = Date()
    for i in 0..<40 {
        send(vm, requestLine(id: String(format: "%032x", i + 100)))
        send(vm, ["op": "ping", "id": String(format: "%032x", i + 100)])
        usleep(20_000)
        if done.wait(timeout: .now()) == .success { done.signal(); break }
    }
    expect(done.wait(timeout: .now() + 5) == .success, "slow reader: the port is dropped, run() ends (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
    close(vm)
}

// Shared HTTP helper: headers in lower case, a bad length is no answer.
if let h = BridgeHTTP.parse(Data("HTTP/1.1 204 No Content\r\nX-A: b\r\nContent-Length: 0\r\n\r\n".utf8)) {
    expect(h.status == 204 && h.headers["x-a"] == "b" && h.body.isEmpty, "http helper: status, headers, body")
} else { expect(false, "http helper: status, headers, body") }
expect(BridgeHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n{}".utf8)) == nil, "http helper: a bad Content-Length is no answer")

// MARK: Touch ID's panel (the Bridge's interim 103, the panel's socket)

let promptJSON: [String: Any] = ["title": "Touch ID in Omarchy", "line": "sudo in pts/1 wants to run", "box": "pacman -Syu", "timeout": 30,
                                 "theme": ["background": "#1a1b26", "foreground": "#a9b1d6", "accent": "#7AA2F7", "success": "#9ece6a", "extra": "#ffffff"]]
let header = json(promptJSON).base64EncodedString()
if let p = TouchIDPanelPrompt.parse(header: header) {
    expect(p.title == "Touch ID in Omarchy" && p.box == "pacman -Syu" && p.timeout == 30, "panel prompt: words and timeout")
    expect(p.colors == ["background": "#1a1b26", "foreground": "#a9b1d6", "success": "#9ece6a"], "panel prompt: lower-case #rrggbb of known keys only")
} else { expect(false, "panel prompt: parsed") }
var badP = promptJSON; badP["title"] = "a\u{1b}[31mb"
expect(TouchIDPanelPrompt.parse(badP) == nil, "panel prompt: control characters refused")
badP = promptJSON; badP["timeout"] = 600
expect(TouchIDPanelPrompt.parse(badP) == nil, "panel prompt: timeout 5...60 s")
badP = promptJSON; badP["box"] = String(repeating: "x", count: 1025)
expect(TouchIDPanelPrompt.parse(badP) == nil, "panel prompt: box at most 1024 characters")
expect(TouchIDPanelResult.parse(Data(#"{"result":"no","reason":"cancelled"}"#.utf8)) == .no("cancelled"), "panel result: no with its reason")
expect(TouchIDPanelResult.parse(Data(#"{"result":"no","reason":"rm -rf"}"#.utf8)) == .no("failed"), "panel result: an unknown reason is failed")
expect(TouchIDPanelResult.no("weird").bridgeLine == Data("no failed\n".utf8) && TouchIDPanelResult.error.bridgeLine == Data("error\n".utf8),
       "panel result: the line to the Bridge")
let interimData = Data("HTTP/1.1 103 Touch ID Panel\r\nX-OmacVM-Panel: \(header)\r\n\r\nHTTP/1.1 200".utf8)
if let (p, rest) = R.interim(interimData) {
    expect(p?.title == "Touch ID in Omarchy" && rest == Data("HTTP/1.1 200".utf8), "interim: the prompt and what follows it")
} else { expect(false, "interim: found") }
expect(R.interim(Data("HTTP/1.1 103 Touch ID Panel\r\nX-OmacVM-Panel: x".utf8)) == nil, "interim: not yet complete")
expect(R.interim(resp) == nil, "interim: a final answer is none")

/// A Bridge that asks for the panel, reads the app's line and answers with it.
final class PanelBridge: @unchecked Sendable {
    let lock = NSLock()
    var gotLine = "", sawPanelHeader = false
    func connect() -> Int32? {
        let (a, b) = pair()
        Thread.detachNewThread { [self] in
            let (req, _) = readAll(b, timeout: 5, untilHeaders: true)
            lock.lock(); sawPanelHeader = String(decoding: req, as: UTF8.self).contains("\r\nX-OmacVM-Panel: 1\r\n"); lock.unlock()
            let interim = Data("HTTP/1.1 103 Touch ID Panel\r\nX-OmacVM-Panel: \(header)\r\n\r\n".utf8)
            _ = interim.withUnsafeBytes { write(b, $0.baseAddress, $0.count) }
            let (line, closed) = readAll(b, timeout: 5, untilNewline: true)
            lock.lock(); gotLine = String(decoding: line, as: UTF8.self); lock.unlock()
            if !closed {
                let body = Data("{\"result\":\"yes\"}\n".utf8)
                let r = Data("HTTP/1.1 200 OK\r\nX-OmacVM-Answer: \(sig)\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
                _ = r.withUnsafeBytes { write(b, $0.baseAddress, $0.count) }
            }
            close(b)
        }
        return a
    }
}
do {
    let pb = PanelBridge()
    let (vm, app) = pair()
    var shown: TouchIDPanelPrompt?
    let r = AuthRelay(guest: app, connectBridge: { pb.connect() }, headers: headers, panel: { p, _ in shown = p; return .yes })
    Thread.detachNewThread { try? r.run() }
    usleep(50_000)
    send(vm, requestLine())
    let (got, _) = readAnswer(vm, timeout: 5)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    pb.lock.lock(); let line = pb.gotLine, saw = pb.sawPanelHeader; pb.lock.unlock()
    expect(saw, "panel relay: the app says it can show the panel")
    expect(shown?.box == "pacman -Syu" && line == "yes\n", "panel relay: the panel's answer goes back to the Bridge")
    expect(o["status"] as? Int == 200 && o["answer"] as? String == sig, "panel relay: the Bridge's signed answer reaches the VM")
    r.stop(); close(vm)
}
do {
    // The VM's client goes away while the panel is up: the panel is told, nothing reaches the VM.
    let pb = PanelBridge()
    let (vm, app) = pair()
    let closedPanel = DispatchSemaphore(value: 0)
    let r = AuthRelay(guest: app, connectBridge: { pb.connect() }, headers: headers, panel: { _, gone in
        while !gone() { usleep(50_000) }
        closedPanel.signal()
        return .no("cancelled")
    })
    r.pingTimeout = 0.6
    Thread.detachNewThread { try? r.run() }
    usleep(50_000)
    send(vm, requestLine())
    expect(closedPanel.wait(timeout: .now() + 3) == .success, "panel relay: no pings -> the panel is closed")
    let (got, _) = readAnswer(vm, timeout: 0.5)
    expect(got.isEmpty, "panel relay: nothing written for a client that is gone")
    r.stop(); close(vm)
}
do {
    // The panel's socket: show, then its answer; and when the client goes away, close.
    let (appEnd, panelEnd) = pair()
    let p = TouchIDPanelPrompt.parse(header: header)!
    Thread.detachNewThread {
        let (line, _) = readAll(panelEnd, timeout: 3, untilNewline: true)
        let o = (try? JSONSerialization.jsonObject(with: line.dropLast())) as? [String: Any] ?? [:]
        let ok = o["op"] as? String == "show" && (o["prompt"] as? [String: Any])?["box"] as? String == "pacman -Syu"
        let d = ok ? TouchIDPanelResult.no("lockout").line : Data("{}\n".utf8)
        _ = d.withUnsafeBytes { write(panelEnd, $0.baseAddress, $0.count) }
    }
    expect(TouchIDPanelClient.ask(fd: appEnd, p, gone: { false }) == .no("lockout"), "panel client: show, then the panel's answer")
    close(appEnd); close(panelEnd)
    let (a2, b2) = pair()
    var flag = false
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag = true }
    expect(TouchIDPanelClient.ask(fd: a2, p, gone: { flag }) == .no("cancelled"), "panel client: the VM's client gone -> cancelled")
    let (sent, _) = readAll(b2, timeout: 1)
    expect(String(decoding: sent, as: UTF8.self).contains("{\"op\":\"close\"}"), "panel client: and the panel is told to close")
    close(a2); close(b2)
    let (a3, b3) = pair()
    close(b3)
    expect(TouchIDPanelClient.ask(fd: a3, p, gone: { false }) == .error, "panel client: no panel -> error (the Mac's own dialog)")
    close(a3)
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
