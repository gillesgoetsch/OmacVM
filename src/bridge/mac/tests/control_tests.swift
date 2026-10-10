// Tests for control_policy.swift: every accepted request shape and every
// refusal. Run: src/bridge/mac/tests/run.sh (CI runs it too).
import CryptoKit
import Foundation

var failures = 0, passed = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { passed += 1 } else { failures += 1; print("FAIL line \(line): \(what)") }
}

let known: Set<String> = ["bridge", "gestures", "scroll-momentum", "mac-clock", "control-centre"]
func route(_ m: String, _ p: String, _ body: String = "") -> Result<ControlRoute, PolicyError> {
  controlRoute(method: m, path: p, body: Data(body.utf8), known: known)
}
func ok(_ r: Result<ControlRoute, PolicyError>) -> ControlRoute? { if case .success(let v) = r { return v }; return nil }
func err(_ r: Result<ControlRoute, PolicyError>) -> PolicyError? { if case .failure(let e) = r { return e }; return nil }

@main struct ControlTests {
  static func main() {
    // ---- accepted ----
    expect(ok(route("GET", "/omacvm/hello")) == .hello, "hello")
    expect(ok(route("GET", "/omacvm/status")) == .status, "status")
    expect(ok(route("GET", "/omacvm/updates")) == .updates, "updates")
    expect(ok(route("POST", "/omacvm/updates/check")) == .updatesCheck, "check, no body")
    expect(ok(route("POST", "/omacvm/updates/check", "{}")) == .updatesCheck, "check, {}")
    expect(ok(route("POST", "/omacvm/settings/update-checks", #"{"enabled": false}"#)) == .setUpdateChecks(false), "silence")
    expect(ok(route("POST", "/omacvm/settings/update-checks", #"{"enabled": true}"#)) == .setUpdateChecks(true), "checks on")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["scroll-momentum", "gestures"]}"#))
           == .startJob(JobRequest(action: .enable, features: ["scroll-momentum", "gestures"])), "enable two")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "disable", "features": ["mac-clock"]}"#))
           == .startJob(JobRequest(action: .disable, features: ["mac-clock"])), "disable")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "reinstall", "features": ["bridge"]}"#))
           == .startJob(JobRequest(action: .reinstall, features: ["bridge"])), "reinstall")
    expect(ok(route("POST", "/omacvm/jobs", #"{"action": "update"}"#)) == .startJob(JobRequest(action: .update, features: [])), "update")
    expect(ok(route("GET", "/omacvm/jobs/0123456789abcdef")) == .job("0123456789abcdef"), "job")
    expect(ok(route("GET", "/omacvm/settings/mouse-swipe")) == .mouseSwipe, "mouse swipe")
    expect(ok(route("POST", "/omacvm/settings/mouse-swipe", #"{"fingers": 3}"#)) == .setMouseSwipe(3), "mouse swipe 3")
    expect(ok(route("POST", "/omacvm/settings/mouse-swipe", #"{"fingers": 4}"#)) == .setMouseSwipe(4), "mouse swipe 4")
    // The Touch ID panel's colours: the body goes to touchid_theme.swift's rules (tests/touchid_panel_tests.swift).
    expect(ok(route("POST", "/omacvm/theme", ##"{"background": "#1a1b26"}"##)) == .theme(Data(##"{"background": "#1a1b26"}"##.utf8)), "theme")
    expect(err(route("GET", "/omacvm/theme"))?.status == 405, "theme: POST only")
    for g in ["opengl", "vulkan", "auto"] {
      expect(ok(route("POST", "/omacvm/jobs", #"{"action": "graphics", "graphics": "\#(g)"}"#))
             == .startJob(JobRequest(action: .graphics, features: [g])), "graphics \(g)")
    }

    // ---- refused ----
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "graphics", "graphics": "metal"}"#))?.code == "bad-body", "graphics: unknown value")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "graphics", "graphics": "auto; rm -rf ~"}"#))?.code == "bad-body", "graphics: shell")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "graphics"}"#))?.code == "bad-body", "graphics: no value")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "graphics", "graphics": "auto", "features": ["bridge"]}"#))?.code == "bad-body", "graphics with features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "graphics", "graphics": true}"#))?.code == "bad-body", "graphics: not a string")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge"], "graphics": "auto"}"#))?.code == "bad-body", "graphics on another action")
    // The notch area (FullPanel, #339): two values, nothing else.
    for n in ["native", "fullpanel"] {
      expect(ok(route("POST", "/omacvm/jobs", #"{"action": "notch", "notch": "\#(n)"}"#))
             == .startJob(JobRequest(action: .notch, features: [n])), "notch \(n)")
    }
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "notch", "notch": "omanotch"}"#))?.code == "bad-body", "notch: unknown value")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "notch", "notch": "native; rm -rf ~"}"#))?.code == "bad-body", "notch: shell")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "notch"}"#))?.code == "bad-body", "notch: no value")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "notch", "notch": "native", "features": ["omanotch"]}"#))?.code == "bad-body", "notch with features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "notch", "notch": "native", "graphics": "auto"}"#))?.code == "bad-body", "notch with graphics")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "graphics", "graphics": "auto", "notch": "native"}"#))?.code == "bad-body", "graphics with notch")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge"], "notch": "native"}"#))?.code == "bad-body", "notch on another action")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "run", "features": ["bridge"]}"#))?.code == "bad-action", "unknown action")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["rm"]}"#))?.code == "unknown-feature", "unknown feature")
    // A control centre from before 3.0.1 says idle-lock for no-idle-lock.
    let renamed = controlRoute(method: "POST", path: "/omacvm/jobs", body: Data(#"{"action": "disable", "features": ["idle-lock"]}"#.utf8),
                               known: known.union(["no-idle-lock"]))
    expect(renamed == .success(.startJob(JobRequest(action: .disable, features: ["idle-lock"]))), "the old name of a renamed feature")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "disable", "features": ["idle-lock"]}"#))?.code == "unknown-feature",
           "the old name only when the Mac has the new one")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge; rm -rf ~"]}"#))?.code == "bad-features", "shell metacharacters")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["$(id)"]}"#))?.code == "bad-features", "substitution")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["--vm"]}"#))?.code == "bad-features", "an option as a name")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["Bridge"]}"#))?.code == "bad-features", "upper case")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": [1]}"#))?.code == "bad-features", "a number")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": []}"#))?.code == "bad-features", "no features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge", "bridge"]}"#))?.code == "bad-features", "twice")
    let many = (0..<17).map { "\"f\($0)x\"" }.joined(separator: ",")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": [\#(many)]}"#))?.code == "bad-features", "17 features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "enable", "features": ["bridge"], "vm": "Other"}"#))?.code == "unknown-key", "naming a VM")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "update", "features": ["bridge"]}"#))?.code == "bad-body", "update with features")
    expect(err(route("POST", "/omacvm/jobs", #"{"action": "update", "commit": "abc"}"#))?.code == "unknown-key", "update picking a commit")
    expect(err(route("POST", "/omacvm/jobs", #"["enable"]"#))?.code == "bad-json", "not an object")
    expect(err(route("POST", "/omacvm/jobs", "{"))?.code == "bad-json", "broken JSON")
    expect(err(route("POST", "/omacvm/jobs", "{\"action\": \"enable\", \"features\": [\"bridge\"], \"x\": \"" + String(repeating: "a", count: 5000) + "\"}"))?.status == 413, "oversized body")
    expect(err(route("POST", "/omacvm/settings/update-checks", #"{"enabled": 1}"#))?.code == "bad-body", "1 is not true")
    expect(err(route("POST", "/omacvm/settings/update-checks", #"{"enabled": "false"}"#))?.code == "bad-body", "a string is not a bool")
    expect(err(route("POST", "/omacvm/updates/check", #"{"url": "http://evil"}"#))?.code == "unknown-key", "check from another feed")
    for b in [#"{"fingers": 5}"#, #"{"fingers": 2}"#, #"{"fingers": 3.0}"#, #"{"fingers": 3.5}"#, #"{"fingers": "3"}"#,
              #"{"fingers": true}"#, #"{"fingers": null}"#, "{}", ""] {
      expect(err(route("POST", "/omacvm/settings/mouse-swipe", b))?.code == "bad-body", "mouse swipe: \(b) is not 3 or 4")
    }
    expect(err(route("POST", "/omacvm/settings/mouse-swipe", #"{"fingers": 3, "domain": "com.apple.dock"}"#))?.code == "unknown-key",
           "mouse swipe: no other key")
    expect(err(route("GET", "/omacvm/settings/mouse-swipe", #"{"fingers": 3}"#))?.code == "body", "mouse swipe: GET with a body")
    expect(err(route("DELETE", "/omacvm/settings/mouse-swipe"))?.status == 405, "mouse swipe: method")
    expect(err(route("GET", "/omacvm/jobs/../../etc"))?.status == 404, "job path")
    expect(err(route("GET", "/omacvm/jobs/ABCDEF0123456789"))?.status == 404, "job id upper case")
    expect(err(route("GET", "/omacvm/run"))?.status == 404, "no other requests")
    expect(err(route("DELETE", "/omacvm/jobs"))?.status == 405, "method")
    expect(err(route("GET", "/omacvm/hello", "{}"))?.code == "body", "GET with a body")
    expect(err(route("GET", "/state"))?.status == 404, "outside /omacvm/")

    // ---- Magic Mouse swipe: Gestures' rules ----
    expect(mouseSwipeFingers(stored: nil) == 4, "not set: 4")
    expect(mouseSwipeFingers(stored: NSNumber(value: 3)) == 3 && mouseSwipeFingers(stored: "3") == 3, "3 as a number or text")
    expect(mouseSwipeFingers(stored: NSNumber(value: 5)) == 4 && mouseSwipeFingers(stored: "three") == 4
           && mouseSwipeFingers(stored: NSNumber(value: 3.5)) == 4, "anything else: 4")
    expect(mouseSwipeFingers(stored: kCFBooleanTrue) == 4, "a bool: 4")
    expect(isMagicMouse(vendor: nil, product: nil, family: 112), "multitouch family 112")
    expect(isMagicMouse(vendor: 0x004c, product: 0x0269, family: nil), "Magic Mouse 2 over Bluetooth")
    expect(isMagicMouse(vendor: 0x05ac, product: 0x0323, family: nil), "Magic Mouse USB-C over USB")
    expect(isMagicMouse(vendor: 0x05ac, product: 0x030d, family: nil), "first Magic Mouse")
    expect(!isMagicMouse(vendor: 0x05ac, product: 0x0265, family: nil), "Magic Trackpad 2 is no mouse")
    expect(!isMagicMouse(vendor: 0x046d, product: 0x0269, family: nil), "another vendor's 0x0269")
    expect(!isMagicMouse(vendor: nil, product: 0x0269, family: nil), "no vendor")
    let ms = mouseSwipeAnswer(magicMouse: true, fingers: 3)
    expect(ms["magic_mouse"] as? Bool == true && ms["fingers"] as? Int == 3 && ms.count == 2, "answer: two keys")
    expect(mouseSwipeAnswer(magicMouse: false, fingers: 7)["fingers"] as? Int == 4, "answer: never another number")

    // ---- protocol ----
    if case .success(let p) = negotiateProto(nil) { expect(p == 1, "no header: 1") } else { expect(false, "no header") }
    if case .success(let p) = negotiateProto("7") { expect(p == controlProto, "newer guest: ours") } else { expect(false, "newer guest") }
    if case .failure(let e) = negotiateProto("0") { expect(e.code == "proto", "older than min") } else { expect(false, "proto 0") }

    // ---- which VM ----
    let appA = VMEntry(name: "Omarchy", type: "app", state: "running", ip: "127.0.0.1:2222", omacvm: "2.9.0", setup: true)
    let a = VMEntry(name: "A", type: "parallels", state: "running", ip: "10.211.55.5", omacvm: "2.9.0", setup: true)
    let b = VMEntry(name: "B", type: "parallels", state: "running", ip: "10.211.55.6", omacvm: "2.9.0", setup: true)
    let stranger = VMEntry(name: "C", type: "utm", state: "running", ip: "10.211.55.7", omacvm: "", setup: false)
    let stopped = VMEntry(name: "D", type: "parallels", state: "stopped", ip: "10.211.55.8", omacvm: "2.9.0", setup: true)
    if case .success(let v) = vmForPeer("10.211.55.6", [a, b]) { expect(v == b, "peer B") } else { expect(false, "peer B") }
    if case .failure(let e) = vmForPeer("10.211.55.7", [a, stranger]) { expect(e.code == "unknown-vm", "not set up") } else { expect(false, "stranger") }
    if case .failure(let e) = vmForPeer("10.211.55.8", [stopped]) { expect(e.code == "unknown-vm", "stopped") } else { expect(false, "stopped") }
    let twin = VMEntry(name: "A2", type: "utm", state: "running", ip: "10.211.55.5", omacvm: "2.9.0", setup: true)
    if case .failure(let e) = vmForPeer("10.211.55.5", [a, twin]) { expect(e.code == "ambiguous-vm", "two VMs on one address") } else { expect(false, "twin") }
    if case .failure(let e) = vmForPeer("127.0.0.1", [a]) { expect(e.status == 403, "127.0.0.1") } else { expect(false, "loopback") }
    if case .failure(let e) = vmForPeer("127.0.0.1", [appA]) { expect(e.code == "app-vm", "an app VM's address is no identity") } else { expect(false, "app loopback") }

    // ---- argv ----
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .enable, features: ["gestures"]), vm: "My VM", type: "parallels", commit: nil)
           == ["/c/omacvm", "enable", "gestures", "--vm", "My VM", "--vm-type", "parallels", "--yes", "--transaction"], "enable argv")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .update, features: []), vm: "V", type: "app", commit: String(repeating: "a", count: 40))
           == ["/c/omacvm", "update", "--vm", "V", "--vm-type", "app", "--transaction", "--yes", "--commit", String(repeating: "a", count: 40)],
           "update argv")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .reinstall, features: ["bridge"]), vm: "V", type: "utm", commit: nil)
           == ["/c/omacvm", "apply", "--vm", "V", "--vm-type", "utm", "--transaction", "--yes", "--reinstall", "bridge"], "reinstall: that feature only")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .reinstall, features: ["gestures", "mac-clock"]), vm: "V", type: "utm", commit: nil).suffix(4)
           == ["--reinstall", "gestures", "--reinstall", "mac-clock"], "reinstall two")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .graphics, features: ["vulkan"]), vm: "My VM", type: "app", commit: nil)
           == ["/c/omacvm", "graphics", "vulkan", "--vm", "My VM", "--vm-type", "app", "--yes"], "graphics argv")
    expect(jobArgv(cli: "/c/omacvm", JobRequest(action: .notch, features: ["fullpanel"]), vm: "My VM", type: "app", commit: nil)
           == ["/c/omacvm", "notch", "fullpanel", "--vm", "My VM", "--vm-type", "app", "--yes"], "notch argv")

    // ---- the VM's own key: requests signed with it, never sent ----
    let k = String(repeating: "5a", count: 32)
    let jobBody = Data(#"{"action": "disable", "features": ["gestures"]}"#.utf8)
    let n0 = "0123456789abcdef0123456789abcdef"
    // The same vector as the VM's client (src/control/tests/test_bridge_sign.py).
    expect(requestMAC(key: k, method: "POST", path: "/omacvm/jobs", time: 1760000000, nonce: n0, proto: "1", body: jobBody)
           == "e939f8224895cf8b312f3eb4af84fd179551fc9920e39ebba4b94905138a2b56", "request signature vector")
    expect(answerMAC(key: k, nonce: n0, status: 202, body: Data("{\"ok\": true}\n".utf8))
           == "10be1a4a1ddefe1ec4fe0f09d079c9cb4ad19225688a1ad00af15da382883718", "answer signature vector")
    let tNow = Date(timeIntervalSince1970: 1760000100)
    func auth(_ t: Int64, _ n: String, method: String = "POST", path: String = "/omacvm/jobs", body: Data = jobBody, key: String = k) -> String {
      "1 \(t) \(n) " + requestMAC(key: key, method: method, path: path, time: t, nonce: n, proto: "1", body: body)
    }
    func check(_ h: String?, stored: String? = k, method: String = "POST", path: String = "/omacvm/jobs", body: Data = jobBody,
               vm: String = String(repeating: "a", count: 32), now: Date = tNow, cache: inout NonceStore) -> Result<String, AuthFailure> {
      verifyControlAuth(header: h, key: stored, vm: vm, method: method, path: path, proto: "1", body: body, now: now, nonces: &cache)
    }
    func code(_ r: Result<String, AuthFailure>) -> String { if case .failure(let f) = r { return f.error.code }; return "ok" }
    var nc = NonceStore()
    expect(code(check(auth(1760000090, n0), stored: k + "\n", cache: &nc)) == "ok", "signed with its key")
    expect(code(check(auth(1760000090, n0), cache: &nc)) == "replay", "the same request again: replay")
    let n1 = "1123456789abcdef0123456789abcdef", n2 = "2123456789abcdef0123456789abcdef"
    expect(code(check(auth(1760000090, n1, key: String(repeating: "5b", count: 32)), cache: &nc)) == "vm-key", "another VM's key")
    expect(code(check(nil, cache: &nc)) == "vm-key", "not signed (an older client)")
    expect(code(check(k, cache: &nc)) == "vm-key", "the key itself as the header")
    expect(code(check(auth(1760000090, n1), body: Data(#"{"action": "enable", "features": ["gestures"]}"#.utf8), cache: &nc)) == "vm-key",
           "body changed on the way")
    expect(code(check(auth(1760000090, n1), path: "/omacvm/settings/update-checks", cache: &nc)) == "vm-key", "path changed")
    expect(code(check(auth(1760000090, n1), method: "GET", cache: &nc)) == "vm-key", "method changed")
    expect(code(check(auth(1760000090, n1), stored: nil, cache: &nc)) == "no-vm-key", "no key on the Mac")
    expect(code(check(auth(1760000090, n1), stored: "short", cache: &nc)) == "no-vm-key", "a short key on the Mac is none")
    expect(code(check("1 1760000090 \(n1) zz", cache: &nc)) == "vm-key", "garbage signature")
    expect(code(check("1 99999999999999999999 \(n1) " + String(repeating: "0", count: 64), cache: &nc)) == "vm-key", "time overflow")
    if case .failure(let f) = check(auth(1759990000, n1), cache: &nc) {
      expect(f.error.code == "clock" && f.nonce == n1 && f.macTime == 1760000100, "an old request: clock, signed answer with the Mac's time")
    } else { expect(false, "old request") }
    if case .failure(let f) = check(auth(Int64.max, n2), cache: &nc) {
      expect(f.error.code == "clock", "far future: clock, no overflow")
    } else { expect(false, "far future") }
    if case .failure(let f) = check(auth(1760000090, n2, key: String(repeating: "5b", count: 32)), cache: &nc) {
      expect(f.nonce == nil, "a wrong signature gets no signed answer (no oracle)")
    } else { expect(false, "unsigned refusal") }
    // Per VM: one VM that fills its own set never stops another.
    let vmA = String(repeating: "a", count: 32), vmB = String(repeating: "b", count: 32)
    var small = NonceStore(perVMLimit: 4)
    for i in 0..<4 { expect(small.take(vm: vmA, nonce: String(format: "%032x", i), time: 1760000090, now: tNow) == .taken, "A takes \(i)") }
    expect(small.take(vm: vmA, nonce: String(format: "%032x", 9), time: 1760000090, now: tNow) == .full, "A full of fresh nonces: refused, not forgotten")
    expect(small.take(vm: vmA, nonce: String(format: "%032x", 0), time: 1760000090, now: tNow) == .replay, "A's own replay still says replay")
    expect(small.take(vm: vmB, nonce: String(format: "%032x", 9), time: 1760000090, now: tNow) == .taken, "B is not stopped by A")
    expect(small.take(vm: vmB, nonce: String(format: "%032x", 0), time: 1760000090, now: tNow) == .taken, "the same nonce from B is B's own")
    expect(small.take(vm: vmA, nonce: String(format: "%032x", 9), time: 1760000500, now: tNow.addingTimeInterval(authWindow + 1)) == .taken,
           "A's old ones expire with their request time")
    // A flood through verifyControlAuth: A gets "rate" (signed), B still gets in.
    var flood = NonceStore(perVMLimit: 50)
    for i in 0..<50 { _ = check(auth(1760000090, String(format: "%032x", 1000 + i)), vm: vmA, cache: &flood) }
    expect(code(check(auth(1760000090, String(format: "%032x", 2000)), vm: vmA, cache: &flood)) == "rate", "flooding VM: rate")
    if case .failure(let f) = check(auth(1760000090, String(format: "%032x", 2001)), vm: vmA, cache: &flood) {
      expect(f.error.status == 429 && f.nonce != nil, "rate answer is signed (the VM believes it)")
    } else { expect(false, "flood") }
    expect(code(check(auth(1760000090, String(format: "%032x", 2002)), vm: vmB, cache: &flood)) == "ok", "the other VM still gets in")
    // Kept across a restart: the lines, loaded into a new store.
    var before = NonceStore()
    _ = before.take(vm: vmA, nonce: n0, time: 1760000090, now: tNow)
    _ = before.take(vm: vmB, nonce: n1, time: 1759999000, now: tNow)   // already expired
    let fresh = before.drainNew()
    expect(fresh == ["\(vmA) \(n0) 1760000090", "\(vmB) \(n1) 1759999000"] && before.drainNew().isEmpty, "new lines once: \(fresh)")
    expect(before.lines(now: tNow) == ["\(vmA) \(n0) 1760000090"], "only live lines kept")
    var after = NonceStore()
    after.load(fresh.joined(separator: "\n") + "\nnot a line\n\(vmA) ZZ 1\n\(vmA.uppercased()) \(n2) 1760000090\n", now: tNow)
    expect(after.count(vm: vmA) == 1 && after.count(vm: vmB) == 0, "load: live and well-formed only")
    expect(code(check(auth(1760000090, n0), vm: vmA, cache: &after)) == "replay", "a request caught before a restart is refused after it")
    var capped = NonceStore(perVMLimit: 2)
    capped.load((0..<5).map { "\(vmA) \(String(format: "%032x", $0)) 1760000090" }.joined(separator: "\n"), now: tNow)
    expect(capped.count(vm: vmA) == 2, "load keeps the cap")
    // Requests per VM: a burst, then the steady rate; per VM.
    var rl = RequestLimiter(burst: 3, perSecond: 1)
    for _ in 0..<3 { expect(rl.admit("A", now: tNow) == nil, "burst") }
    expect(rl.admit("A", now: tNow)?.code == "rate", "over the burst: rate")
    expect(rl.admit("B", now: tNow) == nil, "another VM has its own")
    expect(rl.admit("A", now: tNow.addingTimeInterval(1.1)) == nil, "refilled after a second")
    expect(rl.admit("A", now: tNow.addingTimeInterval(1.2))?.code == "rate", "but only one")
    // The defaults keep a VM at the steady rate below its nonce cap for a whole window.
    let d = RequestLimiter(), cap = NonceStore().perVMLimit
    expect(d.burst + d.perSecond * 2 * authWindow < Double(cap), "rate x window < cap")
    expect(logSafe("/omacvm/x\nFAKE line\r\u{1b}[31m") == "/omacvm/x?FAKE line??[31m", "log: no control characters")
    expect(logSafe("a\u{2028}b") == "a?b" && logSafe(String(repeating: "x", count: 500)).count == 200, "log: line separators, length")
    // As lib/mac.sh vm_key_file: printf '%s/%s' parallels "My VM" | shasum -a 256 | cut -c1-32
    expect(vmKeyName(type: "parallels", name: "My VM") == "6904477035f2e239f66f28d2d8ff406a", "key file name: \(vmKeyName(type: "parallels", name: "My VM"))")

    // ---- OmacVM.app's VMs (the app names them; its relay key) ----
    let appOff = VMEntry(name: "Off", type: "app", state: "stopped", ip: "", omacvm: "", setup: false)
    if case .success(let v) = vmForApp("Omarchy", [a, appA]) { expect(v == appA, "app VM by name") } else { expect(false, "app VM") }
    if case .failure(let e) = vmForApp("A", [a, appA]) { expect(e.code == "unknown-vm", "a Parallels VM is no app VM") } else { expect(false, "type") }
    if case .failure(let e) = vmForApp("Off", [appOff]) { expect(e.code == "unknown-vm", "stopped app VM") } else { expect(false, "stopped") }

    // ---- graphics memory (GET /omacvm/gpu-memory) ----
    expect(ok(route("GET", "/omacvm/gpu-memory")) == .gpuMemory, "gpu-memory")
    expect(err(route("GET", "/omacvm/gpu-memory", "{}"))?.code == "body", "gpu-memory: no body")
    expect(err(route("POST", "/omacvm/gpu-memory"))?.status == 405, "gpu-memory: GET only")
    expect(err(route("GET", "/omacvm/gpu-memory/../status"))?.code == "not-found", "gpu-memory: nothing under it")
    expect(err(route("GET", "/omacvm/gpu-memory?vm=Other"))?.code == "not-found", "gpu-memory: no VM named")
    let appDir = VMEntry(name: "Omarchy", type: "app", state: "running", ip: "127.0.0.1:2222", omacvm: "3.0.0", setup: true,
                         dir: "/Users/x/OmacVM/Omarchy")
    expect(gpuMemoryFile(dir: appDir.dir) == "/Users/x/OmacVM/Omarchy/logs/gpu-memory", "file in the VM folder")
    expect(gpuMemoryFile(dir: "") == nil && gpuMemoryFile(dir: "OmacVM/x") == nil, "no folder, relative: none")
    expect(gpuMemoryFile(dir: "/Users/x/../../etc") == nil && gpuMemoryFile(dir: "/Users/x/..") == nil, "no ..")
    expect(gpuMemoryFile(dir: "/Users/x\u{0}/y") == nil, "no NUL")
    let full = "in_use_mb=1126\npeak_mb=1638\nbudget_mb=49152\npressure=normal\nrefused=0\nlost=0\nlost_last=\nlost_recent=\n"
    let g = gpuMemoryAnswer(full)
    expect(g["measured"] as? Bool == true && g["in_use_mb"] as? Int == 1126 && g["peak_mb"] as? Int == 1638
           && g["budget_mb"] as? Int == 49152 && g["pressure"] as? String == "normal" && g["refused"] as? Int == 0
           && g["lost"] as? Int == 0, "gpu memory: all numbers")
    let short = gpuMemoryAnswer("in_use_mb=4096\npeak_mb=4500\npressure=critical\nrefused=12\nlost=2\nlost_last=Hyprland\n")
    expect(short["pressure"] as? String == "critical" && short["refused"] as? Int == 12 && short["lost"] as? Int == 2, "pressure, refusals")
    expect(short["lost_last"] == nil && short["lost_recent"] == nil, "no guest app names go back")
    expect(gpuMemoryAnswer(nil)["measured"] as? Bool == false, "no file: not measured")
    expect(gpuMemoryAnswer("")["measured"] as? Bool == false, "empty: not measured")
    expect(gpuMemoryAnswer("peak_mb=100\n")["measured"] as? Bool == false, "no in_use: not measured")
    let bad = gpuMemoryAnswer("in_use_mb=-5\npeak_mb=1e9\npressure=$(id)\nrefused=99999999999999999999\n")
    expect(bad["measured"] as? Bool == false, "a sign is no number: not measured")
    let odd = gpuMemoryAnswer("in_use_mb=200\npeak_mb=1e9\npressure=panic\nrefused=99999999999999999999\nlost= 3\n")
    expect(odd["peak_mb"] as? Int == 200 && odd["pressure"] as? String == "unknown" && odd["refused"] as? Int == 0
           && odd["lost"] as? Int == 0, "odd values: dropped, peak at least now")
    expect(gpuMemoryAnswer(String(repeating: "x", count: gpuMemoryFileMax + 1))["measured"] as? Bool == false, "too long")

    // ---- job state: the exit code alone ----
    expect(jobState(rc: nil, alive: true) == "running" && jobState(rc: nil, alive: false) == "failed", "running / gone")
    expect(jobState(rc: 0, alive: false) == "done" && jobState(rc: 4, alive: false) == "rolled-back", "done / rolled back")
    expect(jobState(rc: 1, alive: false) == "failed" && jobState(rc: 3, alive: false) == "failed", "failed")

    // ---- progress lines ----
    let (p, rest, fl) = progress(["==> OmacVM Bridge on the Mac", #"{"omacvm_progress": 1, "step": "mac", "n": 1, "of": 4, "text": "the Mac side"}"#,
                              "pacman: rolled back nothing", #"{"omacvm_progress": 1, "step": "vm", "n": 3, "of": 4, "text": "the VM side"}"#,
                              #"{"omacvm_failed": 1, "part": "camera", "text": "camera was not set up"}"#, "==> old install"])
    expect(p == Progress(n: 3, of: 4, text: "the VM side"), "last progress line")
    expect(rest == ["==> OmacVM Bridge on the Mac", "pacman: rolled back nothing", "==> old install"], "progress lines are not shown as output")
    expect(fl == Failed(part: "camera", text: "camera was not set up"), "what failed")
    expect(progress([#"{"omacvm_failed": 1, "part": "../x", "text": "t"}"#]).2 == Failed(part: "", text: "t"), "a bad part name is dropped")
    expect(progress([#"{"omacvm_failed": 1, "part": "gestures", "text": "OmacVM Gestures did not build on the Mac", "side": "mac"}"#]).2
           == Failed(part: "gestures", text: "OmacVM Gestures did not build on the Mac", side: "mac"), "a Mac helper that failed: side mac")
    expect(progress([#"{"omacvm_failed": 1, "part": "", "text": "t", "side": "shell"}"#]).2?.side == "vm", "unknown side: vm")
    expect(progress([#"{"omacvm_progress": 1, "n": 500, "of": 4, "text": "x"}"#]).0 == nil, "nonsense counts")
    expect(progress(["{\"omacvm_progress\": 1, broken"]).0 == nil, "broken line")

    // ---- updates with checks off ----
    let now = Date()
    expect(updateGate(checksEnabled: true, checkedAt: nil, now: now) == nil, "checks on: the weekly result")
    expect(updateGate(checksEnabled: false, checkedAt: now.addingTimeInterval(-300), now: now) == nil, "off, checked 5 min ago")
    expect(updateGate(checksEnabled: false, checkedAt: now.addingTimeInterval(-7200), now: now)?.code == "stale-update", "off, 2 h old")
    expect(updateGate(checksEnabled: false, checkedAt: nil, now: now)?.code == "stale-update", "off, never checked")
    expect(updateGate(checksEnabled: false, checkedAt: now.addingTimeInterval(86400), now: now)?.code == "stale-update", "a time in the future")

    // ---- limits ----
    var lim = JobLimiter()
    let t0 = Date()
    expect(lim.admit("A", now: t0) == nil, "first job")
    expect(lim.admit("A", now: t0)?.code == "busy", "one at a time")
    expect(lim.admit("B", now: t0) == nil, "another VM")
    lim.finished("A")
    for i in 1..<jobsPerHour { expect(lim.admit("A", now: t0.addingTimeInterval(Double(i))) == nil, "job \(i)"); lim.finished("A") }
    expect(lim.admit("A", now: t0.addingTimeInterval(100))?.code == "rate", "21st in an hour")
    expect(lim.admit("A", now: t0.addingTimeInterval(3700)) == nil, "an hour later")

    // ---- versions ----
    expect(versionGate(JobRequest(action: .enable, features: ["bridge"]), mac: "2.9.0", vm: "2.8.0")?.code == "update-first", "older VM")
    expect(versionGate(JobRequest(action: .update, features: []), mac: "2.9.0", vm: "2.8.0") == nil, "update always")
    expect(versionGate(JobRequest(action: .disable, features: ["bridge"]), mac: "2.9.0", vm: "2.9.0") == nil, "same version")
    // An update that went back (the Mac kept the newer one) never locks the VM.
    expect(versionGate(JobRequest(action: .disable, features: ["camera"]), mac: "2.9.1", vm: "2.9.0") == nil, "off after a failed update")
    expect(versionGate(JobRequest(action: .reinstall, features: ["camera"]), mac: "2.9.1", vm: "2.9.0") == nil, "repair after a failed update")
    expect(versionGate(JobRequest(action: .enable, features: ["camera"]), mac: "2.9.1", vm: "2.9.0")?.code == "update-first", "on: update first")
    expect(versionGate(JobRequest(action: .graphics, features: ["vulkan"]), mac: "3.0.0", vm: "2.9.1") == nil, "graphics: the Mac's setting")
    expect(versionGate(JobRequest(action: .graphics, features: ["vulkan"]), mac: "2.9.1", vm: "3.0.0")?.code == "mac-older", "graphics: Mac older")
    expect(versionGate(JobRequest(action: .notch, features: ["fullpanel"]), mac: "3.0.16", vm: "3.0.15") == nil, "notch: the Mac's setting")
    expect(versionGate(JobRequest(action: .disable, features: ["camera"]), mac: "2.9.0", vm: "2.9.1")?.code == "mac-older", "a newer VM: the Mac first")
    expect(versionGate(JobRequest(action: .disable, features: ["camera"]), mac: "2.9.0", vm: "1.x") == nil, "a 1.x VM may turn off")
    expect(versionLess("2.9.0", "2.10.0") == true && versionLess("2.10.0", "2.9.9") == false && versionLess("2.9", "2.9.0") == false,
           "versions compare as numbers")
    expect(versionLess("1.x", "2.0.0") == nil, "not a version")
    // Updates only go forward.
    // ---- app-update: OmacVM.app updates itself for its own VM ----
    expect(ok(route("POST", "/omacvm/app-update")) == .appUpdate, "app-update, no body")
    expect(ok(route("POST", "/omacvm/app-update", "{}")) == .appUpdate, "app-update, {}")
    expect(err(route("POST", "/omacvm/app-update", #"{"version": "9.9.9"}"#))?.code == "unknown-key", "app-update names no version")
    expect(err(route("GET", "/omacvm/app-update"))?.status == 405, "app-update: POST only")
    expect(appUpdateGate(viaApp: true, vmType: "app", macAppCopy: true, release: "3.0.2", mac: "3.0.1") == nil, "app-update: newer")
    expect(appUpdateGate(viaApp: false, vmType: "app", macAppCopy: true, release: "3.0.2", mac: "3.0.1")?.code == "not-app", "not through the app")
    expect(appUpdateGate(viaApp: true, vmType: "parallels", macAppCopy: true, release: "3.0.2", mac: "3.0.1")?.code == "not-app", "not an app VM")
    expect(appUpdateGate(viaApp: true, vmType: "app", macAppCopy: false, release: "3.0.2", mac: "3.0.1")?.code == "not-app-copy", "a checkout")
    expect(appUpdateGate(viaApp: true, vmType: "app", macAppCopy: true, release: nil, mac: "3.0.1")?.code == "no-update", "no manifest")
    expect(appUpdateGate(viaApp: true, vmType: "app", macAppCopy: true, release: "3.0.1", mac: "3.0.1")?.code == "not-newer", "same")
    expect(appUpdateGate(viaApp: true, vmType: "app", macAppCopy: true, release: "3.0.0", mac: "3.0.1")?.code == "not-newer", "never down")
    expect(appUpdateGate(viaApp: true, vmType: "app", macAppCopy: true, release: "x", mac: "3.0.1")?.code == "not-newer", "bad version")
    expect(cliIsAppCopy("/Users/a/Applications/OmacVM.app/Contents/Resources/omacvm/omacvm", hasGit: false), "app copy")
    expect(!cliIsAppCopy("/Users/a/Applications/OmacVM.app/Contents/Resources/omacvm/omacvm", hasGit: true), "app copy with .git")
    expect(!cliIsAppCopy("/Users/a/omacvm/omacvm", hasGit: true), "checkout")
    expect(forwardGate(release: "2.9.1", mac: "2.9.0", vm: "2.9.0") == nil, "a newer release")
    expect(forwardGate(release: "2.9.1", mac: "2.9.1", vm: "2.9.0") == nil, "retry after a VM went back")
    expect(forwardGate(release: "2.9.1", mac: "2.9.0", vm: "") == nil, "a VM without a version")
    expect(forwardGate(release: "2.9.0", mac: "2.9.1", vm: "2.9.0")?.code == "not-newer", "the Mac is ahead of the release")
    expect(forwardGate(release: "2.9.0", mac: "2.9.0", vm: "2.9.1")?.code == "not-newer", "the VM is ahead of the release")
    expect(forwardGate(release: "2.9.0", mac: "2.9.0", vm: "2.9.0")?.code == "not-newer", "nothing newer")

    // ---- manifest ----
    // Throwaway keys: key and spare play the main and the spare release key.
    let key = Curve25519.Signing.PrivateKey()
    let spare = Curve25519.Signing.PrivateKey()
    let other = Curve25519.Signing.PrivateKey()
    func b64(_ k: Curve25519.Signing.PrivateKey) -> String { k.publicKey.rawRepresentation.base64EncodedString() }
    func sign(_ d: Data, _ k: Curve25519.Signing.PrivateKey) -> Data { Data(try! k.signature(for: d).base64EncodedString().utf8) }
    let pub = b64(key)
    let keys = ReleaseKeys(shipped: [pub, b64(spare)], store: nil)
    let digest = "sha256:" + String(repeating: "ab", count: 32)
    let body = Data(#"{"schema": 1, "kind": "control-manifest", "version": "2.9.1", "commit": "\#(String(repeating: "c", count: 40))", "date": "2026-10-20", "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v2.9.1", "proto": 1, "proto_min": 1, "parts": {"gestures": {"digest": "\#(digest)", "release": "2.9.1", "note": "fewer missed swipes"}}, "devid_teams": ["722686Y34B"]}"#.utf8)
    let sig = Data(try! key.signature(for: body).base64EncodedString().utf8)
    expect(manifestSigned(body, sig: sig, keys: keys), "good signature (main key)")
    expect(manifestSigned(body, sig: sign(body, spare), keys: keys), "good signature (spare key)")
    expect(!manifestSigned(body, sig: sign(body, other), keys: keys), "wrong key")
    expect(!manifestSigned(body, sig: sign(body, spare), keys: ReleaseKeys(shipped: [pub], store: nil)), "spare where only the main key ships")
    var tampered = body; tampered[tampered.count - 3] = UInt8(ascii: "x")
    expect(!manifestSigned(tampered, sig: sig, keys: keys), "changed manifest")
    expect(!manifestSigned(body, sig: Data("bm90IGEgc2ln".utf8), keys: keys), "garbage signature")
    expect(!manifestSigned(body, sig: sig, keys: ReleaseKeys(shipped: [""], store: nil)), "no key")
    if case .success(let m) = parseManifest(body) {
      expect(m.version == "2.9.1" && m.parts["gestures"]?["note"] == "fewer missed swipes" && m.teams == ["722686Y34B"], "manifest fields")
    } else { expect(false, "manifest parses") }
    for (what, teams) in [("no teams", ""), ("empty teams", #", "devid_teams": []"#), ("lower-case team", #", "devid_teams": ["722686y34b"]"#),
                          ("team twice", #", "devid_teams": ["722686Y34B", "722686Y34B"]"#), ("teams as a string", #", "devid_teams": "722686Y34B""#)] {
      let d = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #", "devid_teams": ["722686Y34B"]"#, with: teams).utf8)
      if case .failure(let e) = parseManifest(d) { expect(e.code == "bad-manifest", what) } else { expect(false, what) }
    }
    let badSpare = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""schema": 1"#, with: #""schema": 1, "next_spare_key": "bm90IGEga2V5""#).utf8)
    if case .failure = parseManifest(badSpare) { expect(true, "next_spare_key not a key") } else { expect(false, "next_spare_key not a key") }

    // Rotation: a signed manifest names a new spare, kept with its signature.
    let store = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omacvm-bridge-keys-\(getpid())")
    defer { try? FileManager.default.removeItem(at: store) }
    let rotating = ReleaseKeys(shipped: [pub, b64(spare)], store: store)
    let next = Curve25519.Signing.PrivateKey()
    let naming = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""schema": 1"#, with: #""schema": 1, "next_spare_key": "\#(b64(next))""#).utf8)
    if case .success = parseManifest(naming) { expect(true, "a manifest naming a new spare parses") } else { expect(false, "a manifest naming a new spare parses") }
    let byNext = sign(body, next)
    expect(!manifestSigned(body, sig: byNext, keys: rotating), "the new spare before it was named: refused")
    expect(!rotating.remember(naming, signature: sign(naming, other)), "named by a stranger: not kept")
    expect(rotating.remember(naming, signature: sign(naming, spare)), "named by the spare: kept")
    expect(!rotating.remember(naming, signature: sign(naming, spare)), "named again: already trusted")
    expect(manifestSigned(body, sig: byNext, keys: rotating), "signed by the named spare: accepted from then on")
    expect(!manifestSigned(body, sig: byNext, keys: ReleaseKeys(shipped: [b64(other)], store: store)), "other shipped keys: the kept one does not count")
    for n in (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? [] where n.hasSuffix(".json") {
      var d = try! Data(contentsOf: store.appendingPathComponent(n)); d[d.count / 2] ^= 1
      try! d.write(to: store.appendingPathComponent(n))
    }
    expect(!manifestSigned(body, sig: byNext, keys: rotating), "kept document changed on disk: ignored")
    // A leaked named spare: revoked by a manifest a shipped key signed.
    func with(_ extra: String) -> Data {
      Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""schema": 1"#, with: #""schema": 1, "# + extra).utf8)
    }
    for (what, extra) in [("revoked_keys empty", #""revoked_keys": []"#), ("revoked_keys not a key", #""revoked_keys": ["bm90IGEga2V5"]"#),
                          ("revoked_keys as a string", #""revoked_keys": "\#(pub)""#)] {
      if case .failure = parseManifest(with(extra)) { expect(true, what) } else { expect(false, what) }
    }
    try? FileManager.default.removeItem(at: store)
    expect(rotating.remember(naming, signature: sign(naming, spare)), "the spare names a new one (again)")
    let third = Curve25519.Signing.PrivateKey()
    let naming2 = with(#""next_spare_key": "\#(b64(third))""#)
    expect(rotating.remember(naming2, signature: sign(naming2, next)), "the named spare names the next")
    let badRevoke = with(#""revoked_keys": ["\#(pub)", "\#(b64(spare))"]"#)
    expect(!rotating.remember(badRevoke, signature: sign(badRevoke, next)) && rotating.trusted().count == 4,
           "a named spare revoking the shipped keys: ignored")
    let revoke = with(#""revoked_keys": ["\#(b64(next))"]"#)
    if case .success = parseManifest(revoke) { expect(true, "a manifest with revoked_keys parses") } else { expect(false, "a manifest with revoked_keys parses") }
    expect(rotating.remember(revoke, signature: sign(revoke, key)), "the revocation (signed by the main key) is kept")
    expect(!manifestSigned(body, sig: byNext, keys: rotating) && !manifestSigned(body, sig: sign(body, third), keys: rotating)
           && rotating.trusted().count == 2, "the revoked key and the one it named: refused")
    expect(!rotating.remember(revoke, signature: sign(revoke, key)), "revoked again: not kept")
    // Junk that sorts first counts toward nothing.
    try? FileManager.default.removeItem(at: store)
    try! FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    for i in 0..<12 {
      let n = String(format: "%016x", i)
      try! with(#""next_spare_key": "\#(b64(Curve25519.Signing.PrivateKey()))""#).write(to: store.appendingPathComponent("\(n).json"))
      try! sign(body, other).write(to: store.appendingPathComponent("\(n).json.sig"))
    }
    expect(rotating.remember(naming, signature: sign(naming, spare)) && manifestSigned(body, sig: byNext, keys: rotating),
           "12 junk documents first: a real one is still kept and trusted")
    // More junk than the old 256-file cap on both sides of the real names, and a pipe named like one.
    try? FileManager.default.removeItem(at: store)
    try! FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    let junkDoc = with(#""next_spare_key": "\#(b64(Curve25519.Signing.PrivateKey()))""#), junkSig = sign(body, other)
    for i in 0..<300 {
      for n in [String(format: "%016x", i), String(format: "ffffffff%08x", i)] {
        try! junkDoc.write(to: store.appendingPathComponent("\(n).json"))
        try! junkSig.write(to: store.appendingPathComponent("\(n).json.sig"))
      }
    }
    expect(mkfifo(store.appendingPathComponent("00000000000b0000.json").path, 0o600) == 0
           && mkfifo(store.appendingPathComponent("00000000000b0000.json.sig").path, 0o600) == 0, "a pipe named like a document")
    expect(rotating.remember(naming, signature: sign(naming, spare)) && manifestSigned(body, sig: byNext, keys: rotating),
           "600 junk documents and a pipe around it: a real one is still kept and trusted")
    let schema2 = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""schema": 1"#, with: #""schema": 2"#).utf8)
    if case .failure(let e) = parseManifest(schema2) { expect(e.code == "bad-manifest", "schema 2") } else { expect(false, "schema 2") }
    // One key signs both feeds: the app's feed, or no kind, is no manifest.
    let appFeed = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""kind": "control-manifest""#, with: #""kind": "app-feed""#).utf8)
    if case .failure(let e) = parseManifest(appFeed) { expect(e.message.contains("control centre"), "app-feed refused") } else { expect(false, "app-feed refused") }
    let noKind = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: #""kind": "control-manifest", "#, with: "").utf8)
    if case .failure = parseManifest(noKind) { expect(true, "no kind refused") } else { expect(false, "no kind refused") }
    let badPart = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\"gestures\"", with: "\"../x\"").utf8)
    if case .failure = parseManifest(badPart) { expect(true, "bad part name") } else { expect(false, "bad part name") }

    do {   // own scope: names of their own
    // ---- the VM list: never waited for (review round 4, point 3) ----
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let vmA = VMEntry(name: "A", type: "parallels", state: "running", ip: "10.211.55.5", omacvm: "2.8.0", setup: true)
    let vmB = VMEntry(name: "B", type: "parallels", state: "running", ip: "10.211.55.6", omacvm: "2.8.0", setup: true)
    var c = VMListCache()
    expect(c.shouldRefresh(known: false, now: t0), "empty cache: a run starts")
    expect(!c.shouldRefresh(known: false, now: t0) && !c.shouldRefresh(known: true, now: t0), "one run at a time")
    var r = c.finished([vmA], now: t0 + 2)
    expect(r.changed == ["parallels/A"] && !r.again && c.list == [vmA], "run done: A is in, it changed")
    expect(!c.shouldRefresh(known: true, now: t0 + 30), "known and fresh: no run")
    expect(c.shouldRefresh(known: false, now: t0 + 3) == false, "unknown address: at most every 10 s (one ran at t0)")
    expect(!c.shouldRefresh(known: false, now: t0 + 9), "unknown address: still within the 10 s")
    // Before 3.0.4 an unknown VM waited a minute for the next run: a Bridge
    // that just started answered "unknown VM" for minutes.
    expect(c.shouldRefresh(known: false, now: t0 + 12), "unknown address: 10 s later, a run")
    _ = c.finished([vmA, vmB], now: t0 + 14)
    // An address flood (unknown addresses) starts a run every 10 s, no more.
    var runs = 0
    for s in stride(from: 15.0, to: 15.0 + 300, by: 0.5) where c.shouldRefresh(known: false, now: t0 + s) {
      runs += 1; _ = c.finished([vmA, vmB], now: t0 + s + 3)
    }
    expect(runs <= 31, "flood of unknown addresses for 5 minutes: at most a run every 10 s (\(runs))")
    var c2 = VMListCache()
    _ = c2.shouldRefresh(known: false, now: t0); _ = c2.finished([vmA], now: t0)
    expect(c2.shouldRefresh(known: true, now: t0 + 60), "known but a minute old: a run (the cache is served meanwhile)")
    expect(c2.list == [vmA], "the cache stays while the run goes")
    // A job ended while a run goes: that run's list may be from before the job.
    expect(!c2.jobEnded(vm: "parallels/A", version: "2.8.1"), "job ended during a run: not a second run now")
    expect(c2.list.first?.omacvm == "2.8.1", "the job's VM has the Mac's OmacVM at once")
    r = c2.finished([vmA], now: t0 + 63)
    expect(r.again, "and a run again after the one going")
    r = c2.finished([VMEntry(name: "A", type: "parallels", state: "running", ip: "10.211.55.5", omacvm: "2.8.1", setup: true)], now: t0 + 66)
    expect(!r.again && r.changed == ["parallels/A"], "then done")
    expect(c2.jobEnded(vm: "parallels/A", version: nil), "job ended, nothing running: a run now")
    _ = c2.finished(nil, now: t0 + 70)
    expect(!c2.shouldRefresh(known: false, now: t0 + 75) && !c2.shouldRefresh(known: true, now: t0 + 200 - 126),
           "a failed run: not again within 10 s")
    expect(c2.vm(at: "10.211.55.5") == "parallels/A" && c2.vm(at: "10.211.55.99") == nil, "VM by address")

    // ---- a VM the list does not have: a fresh run first, and the request waits for it ----
    let appVM = VMEntry(name: "Omarchy", type: "app", state: "running", ip: "127.0.0.1:52500", omacvm: "3.0.3", setup: true)
    var u = VMListCache()
    // The Bridge just started (empty list): the first request starts a run and waits for run 1.
    var w = u.unknown(now: t0, every: VMListCache.appEvery)
    expect(w.start && w.waitFor == 1 && u.started == 1 && u.ended == 0, "fresh Bridge: run 1 starts, the request waits for it")
    // Another request meanwhile: that run may have started before its VM; one more follows, it waits for run 2.
    w = u.unknown(now: t0 + 1.5, every: VMListCache.appEvery)
    expect(!w.start && w.waitFor == 2, "during a run: waits for the run after it")
    w = u.unknown(now: t0 + 1.8, every: VMListCache.appEvery)
    expect(!w.start && w.waitFor == 1, "during a run, within a second: waits for the run going")
    r = u.finished([], now: t0 + 2)
    expect(r.again && u.ended == 1 && u.started == 2 && u.running, "run 1 ended: run 2 starts at once")
    r = u.finished([appVM], now: t0 + 3)
    expect(!r.again && u.ended == 2 && !u.running, "run 2 ended")
    if case .success = vmForApp("Omarchy", u.list) { expect(true, "found") } else { expect(false, "the VM is found after the wait") }
    // A run ended less than a second ago: the list is fresh, no new run, no wait.
    w = u.unknown(now: t0 + 3.5, every: VMListCache.appEvery)
    expect(!w.start && w.waitFor == nil, "a run just ended: answered from it")
    w = u.unknown(now: t0 + 4.2, every: VMListCache.appEvery)
    expect(w.start && w.waitFor == 3, "a second later: a run again (OmacVM.app's VMs: at most once a second)")
    _ = u.finished(nil, now: t0 + 5)
    w = u.unknown(now: t0 + 9, every: VMListCache.appEvery)
    expect(!w.start && w.waitFor == nil, "after a failed run: none for 10 s, nothing to wait for")
    // Addresses (any guest can add them): at most every 10 s.
    var ua = VMListCache()
    expect(ua.unknown(now: t0, every: VMListCache.addressEvery).start, "address: a run")
    _ = ua.finished([vmA], now: t0 + 1)
    expect(!ua.unknown(now: t0 + 5, every: VMListCache.addressEvery).start, "address: not again within 10 s")
    expect(ua.unknown(now: t0 + 11, every: VMListCache.addressEvery).start, "address: 10 s after the last list")
    // A VM the list has as running, but refused (not reachable): answered at
    // once; a background run at most every 10 s, however often it asks.
    var ur = VMListCache()
    _ = ur.unknown(now: t0, every: 1)
    let unreach = VMEntry(name: "Omarchy", type: "app", state: "running", ip: "", omacvm: "", setup: true, reachable: false, why: "no address")
    _ = ur.finished([unreach], now: t0 + 1)
    expect(appVMListed("Omarchy", ur.list) && !appVMListed("Other", ur.list), "listed: by name, running")
    let k = "app/Omarchy"
    var rr = ur.refused(key: k, now: t0 + 2)
    expect(!rr.start && rr.waitFor == nil, "refused: no run within 5 s of the last list, answered at once")
    rr = ur.refused(key: k, now: t0 + 7)
    expect(rr.start && rr.waitFor == ur.started && ur.running, "refused: a run 5 s after the last list, waited for (a VM that just started again)")
    rr = ur.refused(key: k, now: t0 + 7.5)
    expect(!rr.start && rr.waitFor == ur.started, "refused: while its run goes, no second one; that one waited for")
    _ = ur.finished([unreach], now: t0 + 8)
    // Still unreachable: back off 30, 60, 120 s, answered at once in between.
    rr = ur.refused(key: k, now: t0 + 20)
    expect(!rr.start && rr.waitFor == nil, "back-off: no run 12 s later")
    rr = ur.refused(key: k, now: t0 + 38)
    expect(rr.start, "back-off: a run 30 s after the last")
    _ = ur.finished([unreach], now: t0 + 39)
    expect(!ur.refused(key: k, now: t0 + 80).start && ur.refused(key: k, now: t0 + 99).start, "back-off: then 60 s")
    _ = ur.finished([unreach], now: t0 + 100)
    expect(!ur.refused(key: k, now: t0 + 200).start && ur.refused(key: k, now: t0 + 220).start, "back-off: then 120 s")
    _ = ur.finished([unreach], now: t0 + 221)
    expect(!ur.refused(key: k, now: t0 + 300).start && ur.refused(key: k, now: t0 + 342).start, "back-off: stays at 120 s")
    _ = ur.finished([unreach], now: t0 + 343)
    var refusedRuns = 0
    for i in 0..<600 where ur.refused(key: k, now: t0 + 344 + Double(i)).start { refusedRuns += 1; _ = ur.finished([unreach], now: t0 + 344 + Double(i) + 0.5) }
    expect(refusedRuns <= 5, "a VM asking every second for 10 minutes starts at most 5 runs (got \(refusedRuns))")
    // Another VM is not held back by this one's back-off; found again: starts over.
    expect(ur.refused(key: "app/Other", now: t0 + 1000).start, "back-off is per VM")
    _ = ur.finished([unreach], now: t0 + 1001)
    ur.reached(key: k)
    expect(ur.refused(key: k, now: t0 + 1010).start, "found again: the next refusal looks after 5 s again")
    _ = ur.finished([unreach], now: t0 + 1011)
    expect(peerListed("10.211.55.5", [vmA]) && !peerListed("10.211.55.9", [vmA]) && !peerListed("", [VMEntry(name: "x", type: "app", state: "running", ip: "", omacvm: "", setup: true)]),
           "listed: by address, never an empty one")
    // jobEnded keeps whether the VM was reachable.
    var uj = VMListCache()
    _ = uj.unknown(now: t0, every: 1)
    _ = uj.finished([VMEntry(name: "A", type: "app", state: "running", ip: "", omacvm: "3.0.2", setup: true, reachable: false)], now: t0 + 1)
    _ = uj.jobEnded(vm: "app/A", version: "3.0.3")
    expect(uj.list.first?.omacvm == "3.0.3" && uj.list.first?.reachable == false, "a job's new version keeps reachable")

    // ---- a VM that runs but the Mac cannot reach: said so, with why, not "not running" ----
    let lost = VMEntry(name: "Omarchy", type: "app", state: "running", ip: "", omacvm: "", setup: true, reachable: false,
                       why: "no address: its fast network is down: omacvm-netd refused")
    if case .failure(let e) = vmForApp("Omarchy", [lost]) {
      expect(e.code == "unknown-vm" && e.message == "the Mac cannot reach this VM: no address: its fast network is down: omacvm-netd refused",
             "running, set up, unreachable: says the Mac cannot reach it and why (\(e.message))")
    } else { expect(false, "unreachable app VM") }
    // Touch ID needs no SSH: the app vouches for the VM, its key signs the request.
    if case .success(let v) = vmForApp("Omarchy", [lost], ssh: false) { expect(v == lost, "Touch ID: an unreachable app VM still found") }
    else { expect(false, "Touch ID without SSH") }
    let noWhy = VMEntry(name: "N", type: "app", state: "running", ip: "", omacvm: "", setup: true, reachable: false)
    if case .failure(let e) = vmForApp("N", [noWhy]) {
      expect(e.message == "the Mac cannot reach this VM: it runs, but SSH from the Mac did not answer", "no why (an older omacvm): the general reason")
    } else { expect(false, "no why") }
    let ugly = VMEntry(name: "U", type: "app", state: "running", ip: "", omacvm: "", setup: true, reachable: false,
                       why: "a\u{1b}[31mb\n" + String(repeating: "x", count: 500))
    if case .failure(let e) = vmForApp("U", [ugly]) {
      expect(!e.message.contains("\u{1b}") && !e.message.contains("\n") && e.message.count <= 30 + 240, "why: no control characters, short")
    } else { expect(false, "ugly why") }
    expect(!routeNeedsSSH(.job("0123456789abcdef")) && !routeNeedsSSH(.gpuMemory), "a job's state and graphics memory: no SSH needed")
    expect(routeNeedsSSH(.status) && routeNeedsSSH(.startJob(JobRequest(action: .enable, features: ["touch-id"]))),
           "checks and new jobs need SSH")
    let lostPeer = VMEntry(name: "P", type: "parallels", state: "running", ip: "10.211.55.9", omacvm: "", setup: true, reachable: false,
                           why: "OmacVM's SSH key did not get in at 10.211.55.9")
    if case .failure(let e) = vmForPeer("10.211.55.9", [lostPeer]) {
      expect(e.message == "the Mac cannot reach this VM: OmacVM's SSH key did not get in at 10.211.55.9", "unreachable VM at that address: said so, and why")
    } else { expect(false, "unreachable peer") }
    let offApp = VMEntry(name: "Off", type: "app", state: "stopped", ip: "", omacvm: "", setup: true, reachable: false)
    if case .failure(let e) = vmForApp("Off", [offApp]) {
      expect(e.message == notRunningText, "stopped: 'not running', nothing about set up")
    } else { expect(false, "stopped") }
    if case .failure = vmForApp("Off", [offApp], ssh: false) { expect(true, "Touch ID: a stopped VM is still refused") }
    else { expect(false, "Touch ID stopped") }
    let notMine = VMEntry(name: "Other", type: "app", state: "running", ip: "192.168.77.4", omacvm: "", setup: false, reachable: false)
    if case .failure(let e) = vmForApp("Other", [notMine], ssh: false) {
      expect(e.message.hasPrefix("OmacVM on the Mac did not set this VM up") && e.message.contains("--vm \"Other\""), "not set up: said so, with the command")
    } else { expect(false, "not set up") }
    var uw = VMListCache()
    _ = uw.unknown(now: t0, every: 1)
    _ = uw.finished([lost], now: t0 + 1)
    _ = uw.jobEnded(vm: "app/Omarchy", version: "3.0.4")
    expect(uw.list.first?.why == lost.why, "a job's new version keeps why")

    // ---- refusals in the log ----
    var ll = LogLimiter(every: 60, maxKeys: 4)
    expect(ll.admit("a", now: t0) == 0, "first refusal logged")
    expect(ll.admit("a", now: t0 + 1) == nil && ll.admit("a", now: t0 + 2) == nil, "then not within a minute")
    expect(ll.admit("b", now: t0 + 2) == 0, "another key is logged")
    expect(ll.admit("a", now: t0 + 61) == 2, "a minute later: logged, with 2 left out")
    for i in 0..<100 { _ = ll.admit("addr\(i)", now: t0 + 62) }
    expect(ll.count <= 5, "many addresses share one key over the cap (\(ll.count))")
    var lines = 0
    for i in 0..<10_000 where ll.admit("addr\(i % 500)", now: t0 + 62 + Double(i) / 100) != nil { lines += 1 }
    expect(lines <= 8, "a flood from 500 addresses for 100 s: a few lines (\(lines))")

    // ---- connection limits (final review point 2) ----
    var g = ConnectionGate()
    var held = 0
    for _ in 0..<40 where g.enter("address 10.211.55.200", known: false) { held += 1 }
    expect(held == 8, "one unknown address: 8")
    for _ in 0..<40 where g.enter("address 10.211.55.201", known: false) { held += 1 }
    for _ in 0..<40 where g.enter("address 10.211.55.202", known: false) { held += 1 }
    expect(held == 16, "unknown addresses together: 16")
    // One guest holds all it can: its own 12 and the 16 unknown places.
    var inA = 0
    for _ in 0..<40 where g.enter("vm parallels/A", known: true) { inA += 1 }
    expect(inA == 12, "12 per VM (\(inA))")
    expect(g.sharedInUse == 8 + 16, "A's 8 past its own 4 and the 16 unknown share the 48 (\(g.sharedInUse))")
    var inB = 0, inMac = 0
    for _ in 0..<40 where g.enter("vm parallels/B", known: true) { inB += 1 }
    for _ in 0..<40 where g.enter("mac", known: true) { inMac += 1 }
    expect(inB == 12 && inMac == 12, "another VM and this Mac still get all theirs (\(inB), \(inMac))")
    // OmacVM.app's guests (all from 127.0.0.1, key "mac") hold all of theirs:
    // the relay socket's key still gets all of its own.
    var inRelay = 0
    for _ in 0..<40 where g.enter("relay", known: true) { inRelay += 1 }
    expect(!g.enter("mac", known: true) && inRelay == 12, "app guests full, the relay still gets 12 (\(inRelay))")
    // Many known VMs fill the shared places: each still has its own 4.
    var g2 = ConnectionGate()
    for v in 0..<10 { for _ in 0..<12 { _ = g2.enter("vm parallels/V\(v)", known: true) } }
    expect(g2.sharedInUse == 48, "the shared places are all taken")
    expect(!g2.enter("vm parallels/V0", known: true) && !g2.enter("address 10.211.55.9", known: false),
           "nobody past their own places now")
    var own = 0
    for _ in 0..<10 where g2.enter("mac", known: true) { own += 1 }
    for _ in 0..<10 where g2.enter("vm parallels/NEW", known: true) { own += 1 }
    expect(own == 8, "the relay and a VM that comes later: their own 4 each (\(own))")
    g2.leave("vm parallels/V3", known: true)
    expect(g2.sharedInUse == 47 && g2.enter("address 10.211.55.9", known: false), "a shared place freed: anyone")
    // Leave gives back the right kind of place.
    var g3 = ConnectionGate()
    for _ in 0..<6 { _ = g3.enter("vm parallels/A", known: true) }
    expect(g3.sharedInUse == 2, "6 in: 4 own + 2 shared")
    for _ in 0..<6 { g3.leave("vm parallels/A", known: true) }
    g3.leave("vm parallels/A", known: true)   // one too many: ignored
    expect(g3.sharedInUse == 0 && g3.enter("vm parallels/A", known: true), "all back")
    // Long requests: two at once per VM.
    expect(g3.enterSlow("vm parallels/A") && g3.enterSlow("vm parallels/A") && !g3.enterSlow("vm parallels/A"),
           "two long requests per VM")
    expect(g3.enterSlow("vm parallels/B"), "another VM's long request")
    g3.leaveSlow("vm parallels/A")
    expect(g3.enterSlow("vm parallels/A"), "one ended: another")

    // ---- the relay socket's path ----
    expect(relaySocketPathOK("/Users/max/Library/Application Support/omacvm-bridge/relay.sock"), "the usual path")
    expect(!relaySocketPathOK("relay.sock"), "relative")
    expect(relaySocketPathOK("/" + String(repeating: "a", count: 102)), "103 bytes fit")
    expect(!relaySocketPathOK("/" + String(repeating: "a", count: 103)), "104 bytes do not (sun_path and its NUL)")
    expect(!relaySocketPathOK("/tmp/a\u{0}b"), "a NUL")

    // ---- a key that does not match: look again (final review point 3) ----
    var c3 = VMListCache()
    _ = c3.shouldRefresh(known: false, now: t0); _ = c3.finished([vmA], now: t0)
    expect(!c3.keyMismatch(now: t0 + 2), "a list just made: no run")
    expect(c3.keyMismatch(now: t0 + 10), "older: a run")
    expect(!c3.keyMismatch(now: t0 + 11), "one at a time")
    _ = c3.finished([vmB], now: t0 + 13)
    expect(!c3.keyMismatch(now: t0 + 40), "at most once a minute")
    expect(c3.keyMismatch(now: t0 + 71), "a minute later: again")
    _ = c3.finished([vmB], now: t0 + 72)
    expect(c3.shouldRefresh(known: false, now: t0 + 73), "its own minute: unknown addresses still look")

    // ---- log keys over the cap: a minute later they go (point 6) ----
    var ll2 = LogLimiter(every: 60, maxKeys: 8)
    for i in 0..<8 { _ = ll2.admit("addr\(i)", now: t0); _ = ll2.admit("addr\(i)", now: t0 + 1) }
    expect(ll2.admit("other", now: t0 + 2) == 0 && ll2.count == 9, "full of keys with lines left out: shared one")
    expect(ll2.admit("late", now: t0 + 70) == 0 && ll2.count <= 2, "a minute later the old keys go (\(ll2.count))")
    }

    // ---- the feed fetch: a missing signature is "not signed", not offline ----
    let some = Data("x".utf8)
    expect(feedFetch(manifest: some, manifestError: nil, sig: some, sigError: nil) == .got, "manifest + sig: got")
    expect(feedFetch(manifest: some, manifestError: nil, sig: nil, sigError: "HTTP 404") == .unsigned, "no .sig (404): not signed")
    expect(feedFetch(manifest: some, manifestError: nil, sig: nil, sigError: "HTTP 403") == .unsigned, "no .sig (403): not signed")
    expect(feedFetch(manifest: some, manifestError: nil, sig: nil, sigError: "The request timed out.") == .offline("The request timed out."), ".sig timed out: offline")
    expect(feedFetch(manifest: some, manifestError: nil, sig: nil, sigError: "HTTP 503") == .offline("HTTP 503"), ".sig 503: offline")
    expect(feedFetch(manifest: nil, manifestError: "HTTP 404", sig: nil, sigError: "HTTP 404") == .offline("HTTP 404"), "no manifest: offline")

    // ---- OmacVM.app's VMs through the app (an external drive) ----
    let appCLI = "/Users/max/Applications/OmacVM.app/Contents/Resources/omacvm/omacvm"
    let info: [String: Any] = ["OmacVMControlRun": true, "CFBundleExecutable": "OmacVM", "CFBundleIdentifier": "org.omacvm.app"]
    let tApp = "org.omacvm.app.test"
    expect(appRunnerPath(cli: appCLI, info: info, testIdentity: false, testApp: tApp)
           == "/Users/max/Applications/OmacVM.app/Contents/MacOS/OmacVM", "the app's own omacvm: its executable")
    expect(appRunnerPath(cli: "/Users/max/omacvm/omacvm", info: info, testIdentity: false, testApp: tApp) == nil, "a checkout: on its own")
    expect(appRunnerPath(cli: appCLI, info: nil, testIdentity: false, testApp: tApp) == nil, "no Info.plist")
    var old = info; old["OmacVMControlRun"] = nil
    expect(appRunnerPath(cli: appCLI, info: old, testIdentity: false, testApp: tApp) == nil, "an older app (no key): would open its window")
    var one = info; one["OmacVMControlRun"] = 1
    expect(appRunnerPath(cli: appCLI, info: one, testIdentity: false, testApp: tApp) == nil, "the key must be a plist true")
    var slash = info; slash["CFBundleExecutable"] = "../../bin/sh"
    expect(appRunnerPath(cli: appCLI, info: slash, testIdentity: false, testApp: tApp) == nil, "an executable name with a path")
    expect(appRunnerPath(cli: appCLI, info: info, testIdentity: true, testApp: tApp) == nil, "the test Bridge: not the installed app")
    var test = info; test["CFBundleIdentifier"] = tApp
    expect(appRunnerPath(cli: appCLI, info: test, testIdentity: false, testApp: tApp) == nil, "the installed Bridge: not the test app")
    expect(appRunnerPath(cli: appCLI, info: test, testIdentity: true, testApp: tApp) != nil, "the test Bridge: the test app")
    var lane = info; lane["CFBundleIdentifier"] = tApp + ".fixid"
    expect(appRunnerPath(cli: appCLI, info: lane, testIdentity: true, testApp: tApp) != nil, "the test Bridge: a lane's copy of the test app")
    expect(appRunnerPath(cli: appCLI, info: lane, testIdentity: false, testApp: tApp) == nil, "the installed Bridge: not a lane's copy")
    var tester = info; tester["CFBundleIdentifier"] = "org.omacvm.app.tester"
    expect(appRunnerPath(cli: appCLI, info: tester, testIdentity: true, testApp: tApp) == nil, "the test Bridge: not org.omacvm.app.tester")
    expect(appRunnerPath(cli: "/a/../b/OmacVM.app/Contents/Resources/omacvm/omacvm", info: info, testIdentity: false, testApp: tApp) == nil, "..")
    expect(appRunnerPath(cli: "Applications/OmacVM.app/Contents/Resources/omacvm/omacvm", info: info, testIdentity: false, testApp: tApp) == nil, "relative")

    let prl = VMEntry(name: "P", type: "parallels", state: "running", ip: "10.211.55.5", omacvm: "3.0.1", setup: true)
    let inside = VMEntry(name: "In", type: "app", state: "running", ip: "127.0.0.1:52000", omacvm: "3.0.1", setup: true, dir: "/Users/max/VMs/In")
    let ext = VMEntry(name: "SD", type: "app", state: "running", ip: "127.0.0.1:52612", omacvm: "3.0.1", setup: true, dir: "/Volumes/SD/VMs/SD")
    let stale = VMEntry(name: "In", type: "app", state: "running", ip: "127.0.0.1:52000", omacvm: "3.0.0", setup: false, dir: "/Users/max/VMs/In")
    expect(mergeVMLists(all: [prl, stale], app: [inside, ext]) == [prl, inside, ext], "app VMs from the app's run, the others from the Bridge's")
    expect(mergeVMLists(all: [prl, inside], app: nil) == [prl, inside], "the app's run failed: the Bridge's list as it is")
    expect(mergeVMLists(all: nil, app: [ext]) == nil, "the Bridge's run failed: none (asked again)")
    expect(mergeVMLists(all: [prl], app: []) == [prl], "the app has no VM")
    expect(mergeVMLists(all: [prl], app: [prl, ext]) == [prl, ext], "the app's run lists only app VMs")

    expect(gpuMemoryFromApp(nil) == nil, "no header (an older app): the Bridge reads the file")
    expect(gpuMemoryFromApp("-") == .some(nil), "-: the app has no file")
    expect(gpuMemoryFromApp(Data("in_use_mb=12\n".utf8).base64EncodedString()) == .some("in_use_mb=12\n"), "the file's text")
    expect(gpuMemoryFromApp("not base64!") == nil, "not base64: read it here")
    expect(gpuMemoryFromApp(Data(repeating: 65, count: 4097).base64EncodedString()) == nil, "over 4 KB: no")
    expect(gpuMemoryAnswer(gpuMemoryFromApp("-") ?? "x") as NSDictionary == ["measured": false] as NSDictionary, "no file: not measured")

    var c4 = VMListCache()
    _ = c4.shouldRefresh(known: false, now: t0); _ = c4.finished([ext], now: t0)
    _ = c4.jobEnded(vm: "app/SD", version: "3.0.2")
    expect(c4.list.first?.dir == "/Volumes/SD/VMs/SD" && c4.list.first?.omacvm == "3.0.2", "a job ended: the folder stays")

    print("control policy: \(passed) passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
  }
}
