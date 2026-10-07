// Tests for touchid_policy.swift (ADR 0041) with LocalAuthentication and the
// Mac's state mocked: the request, the dialog text, the limits, the order of
// the checks, timeout and a client that goes away, and the signatures.
// Run: src/bridge/mac/tests/run.sh (CI runs it too).
import Foundation

var tFailures = 0, tPassed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { tPassed += 1 } else { tFailures += 1; print("FAIL line \(line): \(what)") }
}

final class MockAuth: TouchIDAuthenticator {
  var notThere: TouchIDNo?
  var answer: TouchIDOutcome = .yes
  var waits = false              // never answers: only timeout or gone end it
  var asked: [String] = []
  var fallbacks: [Bool] = []
  func unavailable(passwordFallback: Bool) -> TouchIDNo? { notThere }
  var prompts: [TouchIDPrompt] = []
  func evaluate(_ p: TouchIDPrompt, passwordFallback: Bool, timeout: Double, gone: @escaping () -> Bool) -> TouchIDOutcome {
    asked.append(p.reason); fallbacks.append(passwordFallback); prompts.append(p)
    guard waits else { return answer }
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if gone() { return .no(.cancelled) }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return .no(.timeout)
  }
}

struct MockMac: TouchIDMacState {
  var locked = false
  var frontType: String? = "parallels"
}

func json(_ o: Any) -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
}

func req(_ s: String) -> Result<TouchIDRequest, PolicyError> { parseTouchIDRequest(Data(s.utf8)) }
func code(_ r: Result<TouchIDRequest, PolicyError>) -> String? { if case .failure(let e) = r { return e.code }; return nil }
func value(_ r: Result<TouchIDRequest, PolicyError>) -> TouchIDRequest? { if case .success(let v) = r { return v }; return nil }

@main struct TouchIDTests {
  static func main() {
    // ---- the request ----
    let sudo = value(req(#"{"kind":"sudo","user":"vincent","detail":"pacman -Syu"}"#))
    check(sudo == TouchIDRequest(kind: .sudo, user: "vincent", detail: "pacman -Syu", action: ""), "sudo request")
    check(value(req(#"{"kind":"1password","user":"a_b-1"}"#))?.kind == .onePassword, "1password")
    check(value(req(#"{"kind":"polkit","user":"v","action":"org.freedesktop.systemd1.manage-units"}"#))?.action
          == "org.freedesktop.systemd1.manage-units", "polkit action")
    check(code(req(#"{"kind":"sudo","user":"v","extra":1}"#)) == "unknown-key", "unknown key")
    check(code(req(#"{"kind":"root","user":"v"}"#)) == "kind", "bad kind")
    check(code(req(#"{"user":"v"}"#)) == "kind", "no kind")
    check(code(req(#"{"kind":"sudo"}"#)) == "user", "no user")
    check(value(req(#"{"kind":"sudo","user":"First.Last"}"#))?.user == "First.Last", "user with a dot and capitals")
    check(code(req(#"{"kind":"sudo","user":"root"}"#)) == "user", "root never")
    check(code(req(#"{"kind":"sudo","user":".x"}"#)) == "user", "user dot first")
    check(value(req(#"{"kind":"sudo","user":"v","detail":"true","tty":"pts/3"}"#))?.tty == "pts/3", "tty")
    check(value(req(#"{"kind":"sudo","user":"v","tty":"tty2"}"#))?.tty == "tty2", "console tty")
    for t in ["pts/", "pts/x", "pts/12345", "ssh", "../pts/1", "pts/1 x", "tty"] {
      check(code(req(#"{"kind":"sudo","user":"v","tty":"\#(t)"}"#)) == "tty", "bad tty \(t)")
    }
    check(code(req(#"{"kind":"sudo","user":"1v"}"#)) == "user", "user digit first")
    check(code(req(#"{"kind":"sudo","user":"\#(String(repeating: "a", count: 33))"}"#)) == "user", "user too long")
    check(code(req(#"{"kind":"sudo","user":"v","detail":5}"#)) == "detail", "detail not text")
    check(code(req(#"{"kind":"sudo","user":"v","detail":"\#(String(repeating: "x", count: 201))"}"#)) == "detail", "detail too long")
    check(code(req(#"{"kind":"polkit","user":"v","action":"a b"}"#)) == "action", "action with space")
    check(code(req(#"{"kind":"polkit","user":"v","action":"a\"b"}"#)) == "action", "action with quote")
    check(code(req(#"[1]"#)) == "bad-json", "not an object")
    check(code(req("")) == "bad-json", "empty")
    check(code(parseTouchIDRequest(Data(repeating: 32, count: 1025))) == "too-large", "over 1 KB")

    // ---- the dialog text ----
    let r1 = TouchIDRequest(kind: .onePassword, user: "v", detail: "", action: "")
    check(touchIDReason(r1, vm: nil) == "unlock 1Password in Omarchy", "1password text")
    check(touchIDReason(r1, vm: "Work") == "unlock 1Password in Omarchy (Work)", "with the VM's name")
    check(touchIDReason(sudo!, vm: nil) == "run sudo in Omarchy: pacman -Syu", "sudo text")
    let sudoTTY = TouchIDRequest(kind: .sudo, user: "v", detail: "pacman -Syu", action: "", tty: "pts/3")
    check(touchIDReason(sudoTTY, vm: nil) == "run sudo in Omarchy (pts/3): pacman -Syu", "sudo text with its terminal")
    check(touchIDReason(sudoTTY, vm: "Work") == "run sudo in Omarchy (Work, pts/3): pacman -Syu", "... and the VM's name")
    check(touchIDReason(TouchIDRequest(kind: .sudo, user: "v", detail: "", action: ""), vm: nil) == "run sudo in Omarchy", "sudo, no command")
    check(touchIDReason(TouchIDRequest(kind: .polkit, user: "v", detail: "", action: "org.x.y"), vm: nil) == "allow \"org.x.y\" in Omarchy", "polkit text")
    check(touchIDReason(TouchIDRequest(kind: .polkit, user: "v", detail: "", action: ""), vm: nil) == "allow a system request in Omarchy", "polkit, no action")
    check(touchIDClean("rm\n-rf\u{202E}/ \u{7}x", max: 80) == "rm -rf / x", "control and bidi characters go")
    let long = touchIDClean(String(repeating: "a", count: 100), max: 80)
    check(long.count == 80 && long.hasSuffix("… (cut)"), "cut to 80, said so")
    check(touchIDClean("a\u{00A0}b\u{2003}c\u{200B}d\u{200D}e\u{2060}f\u{3000}g\u{2800}h\u{202F}i\u{205F}j\u{00AD}k", max: 80)
          == "a b c d e f g h i j k", "odd spaces and invisible characters become one plain space")
    check(touchIDClean("ls\u{FE0F}\u{E0041}", max: 80) == "ls", "variation selectors and tags go")
    let full = String(repeating: "b", count: touchIDCommandMax)
    check(touchIDReason(TouchIDRequest(kind: .sudo, user: "v", detail: full, action: ""), vm: nil) == "run sudo in Omarchy: " + full,
          "a command as long as the client sends is shown whole")

    // ---- which app is in front ----
    check(vmTypeOfExecutable("/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM") == "app", "OmacVM.app")
    check(vmTypeOfExecutable("/Applications/Parallels Desktop.app/Contents/MacOS/prl_client_app") == "parallels", "Parallels")
    check(vmTypeOfExecutable("/Applications/UTM.app/Contents/MacOS/UTM") == "utm", "UTM")
    check(vmTypeOfExecutable("/Applications/VMware Fusion.app/Contents/MacOS/VMware Fusion") == "fusion", "Fusion")
    check(vmTypeOfExecutable("/Applications/Safari.app/Contents/MacOS/Safari") == nil, "another app")
    // OmacVM.app's QEMU started through Contents/MacOS/OmacVM-VM (DockIdentity): LaunchServices names the
    // app's own executable, the kernel the runtime: the kernel's path counts.
    check(vmTypeOfFront(kernelPath: "/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM",
                        launchServicesPath: "/Applications/OmacVM.app/Contents/MacOS/OmacVM") == "app", "OmacVM.app's QEMU as one Dock app")
    check(vmTypeOfFront(kernelPath: nil, launchServicesPath: "/Applications/UTM.app/Contents/MacOS/UTM") == "utm", "no kernel path: LaunchServices")
    check(vmTypeOfFront(kernelPath: "/Applications/OmacVM.app/Contents/MacOS/OmacVM",
                        launchServicesPath: "/Applications/OmacVM.app/Contents/MacOS/OmacVM") == nil, "OmacVM.app's launcher has no VM")
    check(vmTypeOfFront(kernelPath: nil, launchServicesPath: nil) == nil, "nothing in front")

    // ---- the order of the checks ----
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func decide(_ a: MockAuth, _ m: MockMac = MockMac(), on: Bool = true, vm: String = "parallels/A", type: String = "parallels",
                at: Date, fallback: Bool = false, d: TouchIDDecider? = nil) -> TouchIDOutcome {
      (d ?? TouchIDDecider(auth: a, mac: m)).decide(vm: vm, type: type, on: on, request: sudo!, vmLabel: nil, passwordFallback: fallback, now: at)
    }
    var a = MockAuth()
    check(decide(a, at: t0) == .yes, "yes")
    check(a.asked == ["run sudo in Omarchy: pacman -Syu"] && a.fallbacks == [false], "one dialog, no password fallback")
    a = MockAuth()
    check(decide(a, at: t0, fallback: true) == .yes && a.fallbacks == [true], "password fallback only when asked")
    a = MockAuth(); a.answer = .no(.failed)
    check(decide(a, at: t0) == .no(.failed), "wrong finger")
    a = MockAuth()
    check(decide(a, on: false, at: t0) == .no(.off) && a.asked.isEmpty, "off: no dialog")
    check(decide(a, MockMac(locked: true), at: t0) == .no(.locked) && a.asked.isEmpty, "locked: no dialog")
    check(decide(a, MockMac(frontType: nil), at: t0) == .no(.notFront) && a.asked.isEmpty, "another app in front: no dialog")
    check(decide(a, MockMac(frontType: "utm"), at: t0) == .no(.notFront) && a.asked.isEmpty, "another VM app in front: no dialog")
    a.notThere = .noTouchID
    check(decide(a, at: t0) == .no(.noTouchID) && a.asked.isEmpty, "no sensor: no dialog")
    a.notThere = .lockout
    check(decide(a, at: t0) == .no(.lockout) && a.asked.isEmpty, "lockout: no dialog")

    // ---- limits ----
    a = MockAuth()
    let d = TouchIDDecider(auth: a, mac: MockMac())
    check(decide(a, at: t0, d: d) == .yes, "first")
    check(decide(a, at: t0.addingTimeInterval(1), d: d) == .no(.rate), "again within 2 s")
    check(decide(a, vm: "parallels/B", at: t0.addingTimeInterval(1), d: d) == .yes, "another VM has its own limit")
    var n = 0
    for i in 0..<12 where decide(a, at: t0.addingTimeInterval(Double(2 + i * 2)), d: d) == .yes { n += 1 }
    check(n == 9, "10 a minute (got \(n + 1))")
    check(decide(a, at: t0.addingTimeInterval(70), d: d) == .yes, "the next minute")

    a = MockAuth(); a.answer = .no(.cancelled)
    let d2 = TouchIDDecider(auth: a, mac: MockMac())
    for i in 0..<3 { _ = decide(a, at: t0.addingTimeInterval(Double(i * 3)), d: d2) }
    a.answer = .yes
    check(decide(a, at: t0.addingTimeInterval(10), d: d2) == .no(.rate), "3 misses: paused")
    check(decide(a, at: t0.addingTimeInterval(69), d: d2) == .yes, "60 s later: again")
    a.answer = .no(.failed)
    _ = decide(a, at: t0.addingTimeInterval(72), d: d2); _ = decide(a, at: t0.addingTimeInterval(75), d: d2)
    a.answer = .yes; _ = decide(a, at: t0.addingTimeInterval(78), d: d2)
    a.answer = .no(.failed); _ = decide(a, at: t0.addingTimeInterval(81), d: d2)
    check(decide(a, at: t0.addingTimeInterval(84), d: d2) == .no(.failed), "a yes starts the count again")
    // Dialogs nobody answers count as misses too, and the pauses grow: 60 s, 5 min, 30 min.
    a = MockAuth(); a.answer = .no(.timeout)
    let d7 = TouchIDDecider(auth: a, mac: MockMac())
    var at = t0
    func three() { for _ in 0..<3 { _ = decide(a, at: at, d: d7); at = at.addingTimeInterval(3) } }
    three()
    check(decide(a, at: at, d: d7) == .no(.rate), "3 timeouts: paused")
    at = at.addingTimeInterval(61); three()
    check(decide(a, at: at.addingTimeInterval(200), d: d7) == .no(.rate), "second pause: 5 min")
    at = at.addingTimeInterval(301); three()
    check(decide(a, at: at.addingTimeInterval(1700), d: d7) == .no(.rate), "third pause: 30 min")
    at = at.addingTimeInterval(1801); a.answer = .yes
    check(decide(a, at: at, d: d7) == .yes, "after it: again")
    a.answer = .no(.cancelled); at = at.addingTimeInterval(3); three()
    check(decide(a, at: at.addingTimeInterval(61), d: d7) != .no(.rate), "a yes starts the pauses at 60 s again")
    at = at.addingTimeInterval(64); three()
    check(decide(a, at: at.addingTimeInterval(200), d: d7) == .no(.rate), "two pauses close together: 5 min")
    at = at.addingTimeInterval(300 + 3700); three()
    check(decide(a, at: at.addingTimeInterval(61), d: d7) != .no(.rate), "an hour later: 60 s again")

    a = MockAuth(); a.notThere = .noTouchID
    let d3 = TouchIDDecider(auth: a, mac: MockMac())
    for i in 0..<4 { _ = decide(a, at: t0.addingTimeInterval(Double(i * 3)), d: d3) }
    a.notThere = nil
    check(decide(a, at: t0.addingTimeInterval(15), d: d3) == .yes, "fast noes do not pause")

    var lim = TouchIDLimiter()
    check(lim.admit("x", now: t0) == nil, "admitted")
    check(lim.admit("y", now: t0) == .busy, "one dialog at a time on the Mac")
    lim.finished("x", yes: true, no: nil, now: t0)
    check(lim.admit("y", now: t0) == nil, "the next one after it")

    // ---- timeout and a client that goes away (real time, short) ----
    a = MockAuth(); a.waits = true
    let d4 = TouchIDDecider(auth: a, mac: MockMac()); d4.timeout = 0.2
    check(d4.decide(vm: "v", type: "parallels", on: true, request: sudo!, vmLabel: nil, passwordFallback: false) == .no(.timeout), "timeout")
    let d5 = TouchIDDecider(auth: a, mac: MockMac()); d5.timeout = 5
    let start = Date()
    var gone = false
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gone = true }
    check(d5.decide(vm: "v", type: "parallels", on: true, request: sudo!, vmLabel: nil, passwordFallback: false, gone: { gone }) == .no(.cancelled)
          && Date().timeIntervalSince(start) < 1, "client gone: dialog closed")
    // Two at once: the second is busy while the first dialog is up.
    let d6 = TouchIDDecider(auth: a, mac: MockMac()); d6.timeout = 0.5
    var first: TouchIDOutcome?
    let g = DispatchGroup(); g.enter()
    DispatchQueue.global().async { first = d6.decide(vm: "v1", type: "parallels", on: true, request: sudo!, vmLabel: nil, passwordFallback: false); g.leave() }
    Thread.sleep(forTimeInterval: 0.1)
    check(d6.decide(vm: "v2", type: "parallels", on: true, request: sudo!, vmLabel: nil, passwordFallback: false) == .no(.busy), "busy")
    g.wait()
    check(first == .no(.timeout), "the first one ran to its end")

    // ---- answers and signatures ----
    check(json(touchIDAnswer(.yes)) == #"{"result":"yes"}"#, "yes body")
    check(json(touchIDAnswer(.no(.notFront))) == #"{"reason":"not-front","result":"no"}"#, "no body")
    let key = String(repeating: "k", count: 64), body = Data(#"{"kind":"sudo","user":"v"}"#.utf8)
    let control = requestMAC(key: key, method: "POST", path: touchIDPath, time: 1, nonce: "n", proto: "1", body: body)
    let tid = requestMAC(key: key, method: "POST", path: touchIDPath, time: 1, nonce: "n", proto: "1", body: body, label: touchIDRequestLabel)
    check(control != tid, "a control centre signature never counts for Touch ID")
    check(answerMAC(key: key, nonce: "n", status: 200, body: body) != answerMAC(key: key, nonce: "n", status: 200, body: body, label: touchIDAnswerLabel),
          "answers are labelled apart too")
    var nonces = NonceStore()
    let now = Date(timeIntervalSince1970: 1_800_000_000), nonce = String(repeating: "a", count: 32)
    let hdr = { (label: String) in "1 1800000000 \(nonce) " + requestMAC(key: key, method: "POST", path: touchIDPath, time: 1_800_000_000,
                                                                       nonce: nonce, proto: "1", body: body, label: label) }
    let bad = verifyControlAuth(header: hdr("omacvm-control-request 1"), key: key, vm: "x", method: "POST", path: touchIDPath, proto: "1",
                                body: body, now: now, nonces: &nonces, label: touchIDRequestLabel)
    if case .failure(let f) = bad { check(f.error.code == "vm-key", "control label refused") } else { check(false, "control label refused") }
    let good = verifyControlAuth(header: hdr(touchIDRequestLabel), key: key, vm: "x", method: "POST", path: touchIDPath, proto: "1",
                                 body: body, now: now, nonces: &nonces, label: touchIDRequestLabel)
    check(good == .success(nonce), "Touch ID label taken")
    check(touchIDKeyName(type: "parallels", name: "A") == vmKeyName(type: "parallels", name: "A") + ".touchid", "key file name")

    print("touchid: \(tPassed) passed, \(tFailures) failed")
    exit(tFailures == 0 ? 0 : 1)
  }
}
