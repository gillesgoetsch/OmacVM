// The Bridge on a retired route's address (retired.swift): its pure parts,
// and `serve TOKEN-FILE PORT-FILE LOG-FILE`, which answers on 127.0.0.1 (a
// port of its own) with serveRetired exactly as the Bridge does on
// 10.211.55.2 and the others, for old_guest.py and the 3.3.0 guest clients.
// No VM, no network but 127.0.0.1, no permission.
import Foundation

var failed = 0, passed = 0
func check(_ ok: Bool, _ what: String) {
  if ok { passed += 1; print("ok   \(what)") } else { failed += 1; print("FAIL \(what)") }
}

let args = CommandLine.arguments
if args.count == 5, args[1] == "serve" {
  setvbuf(stdout, nil, _IOLBF, 0)
  let token = Array((try! String(contentsOfFile: args[2], encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var one: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
  var sin = sockaddr_in()
  sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  sin.sin_family = sa_family_t(AF_INET)
  sin.sin_port = 0
  inet_pton(AF_INET, "127.0.0.1", &sin.sin_addr)
  guard withUnsafePointer(to: &sin, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0, listen(fd, 16) == 0 else {
    print("cannot listen: \(String(cString: strerror(errno)))"); exit(1)
  }
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &sin) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
  try! "\(UInt16(bigEndian: sin.sin_port))\n".write(toFile: args[3], atomically: true, encoding: .utf8)
  let streams = RetiredStreams()
  let logFile = FileHandle(forWritingAtPath: args[4]) ?? FileHandle.standardOutput
  var n = 0
  while true {
    let c = accept(fd, nil, nil)
    if c < 0 { continue }
    n += 1
    logFile.write(Data("accept \(n)\n".utf8))
    DispatchQueue.global().async { serveRetired(c, at: "127.0.0.1", token: token, streams: streams) }
  }
}

// ---- the pure parts ----
check(retiredRoute(method: "GET", target: "/proof?nonce=0123456789abcdef0123456789abcdef") == .proof("0123456789abcdef0123456789abcdef"),
      "proof: answered as before")
check(retiredRoute(method: "GET", target: "/proof?nonce=XYZ") == .badNonce, "proof: a bad nonce")
check(retiredRoute(method: "GET", target: "/events") == .events && retiredRoute(method: "GET", target: "/events?osd=external") == .events,
      "events: the held stream")
for (m, t) in [("GET", "/omacvm/hello"), ("GET", "/omacvm/status"), ("POST", "/omacvm/jobs"), ("POST", "/omacvm/touchid"),
               ("GET", "/state"), ("GET", "/battery"), ("GET", "/camera"), ("POST", "/wallpaper"), ("POST", "/events")] {
  check(retiredRoute(method: m, target: t) == .gone, "\(m) \(t): gone, with the text")
}
let gone = String(decoding: retiredGone(), as: UTF8.self)
check(gone.hasPrefix("HTTP/1.1 410 Gone\r\n") && gone.contains("\"code\":\"route-retired\"") && gone.contains("\"retired_in\":\"3.4.0\""),
      "410 with code route-retired and 3.4.0")
check(gone.contains(retiredText) && retiredText.contains("OmacVM.app only") && retiredText.contains("copy your files"), "the move text")
check(String(decoding: retiredStreamHead(), as: UTF8.self).contains(": \(retiredText)\n\n"), "the stream starts with the text as a comment")
check(retiredAddrs(fusionNetworking: nil) == ["10.211.55.2", "192.168.64.1"], "the retired addresses without the third app")
let net = "answer VNET_1_HOSTONLY_SUBNET 192.168.100.0\nanswer VNET_8_HOSTONLY_SUBNET 172.16.42.0\n"
check(retiredAddrs(fusionNetworking: net) == ["10.211.55.2", "192.168.64.1", "172.16.42.1"], "the third app's NAT network: .1")
check(retiredFusionHost("answer VNET_8_HOSTONLY_SUBNET 8.8.8.0") == nil, "a public subnet: none")
check(retiredFusionHost("answer VNET_8_HOSTONLY_SUBNET 192.168.77.0") == nil, "the fast network's subnet: none")
// The 3.3.0 clients check the proof itself (old_guest.py): here only its shape.
check(retiredProof(token: Array("t".utf8), nonce: "n", at: "a").count == 64, "proof: 64 hex digits")
print("retired (pure): \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
