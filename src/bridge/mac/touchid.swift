// Touch ID for the VM (ADR 0041): POST /omacvm/touchid from the VM's PAM
// client. The Mac shows its own Touch ID dialog and answers only yes or no,
// signed with the VM's Touch ID key. Nothing about the finger leaves macOS:
// LocalAuthentication gives the Bridge success or an error code, no more.
import AppKit
import Darwin
import LocalAuthentication

/// LocalAuthentication: a fresh LAContext per request, never reused.
final class LATouchID: TouchIDAuthenticator {
  private func policy(_ fallback: Bool) -> LAPolicy {
    fallback ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
  }

  static func no(_ e: Error?) -> TouchIDNo {
    guard let e = e as? LAError else { return .failed }
    switch e.code {
    case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
    case .biometryLockout: return .lockout
    case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet: return .noTouchID
    default: return .failed
    }
  }

  func unavailable(passwordFallback: Bool) -> TouchIDNo? {
    let c = LAContext()
    defer { c.invalidate() }
    var e: NSError?
    if c.canEvaluatePolicy(policy(passwordFallback), error: &e) { return nil }
    return LATouchID.no(e)
  }

  func evaluate(_ p: TouchIDPrompt, passwordFallback: Bool, timeout: Double, gone: @escaping () -> Bool) -> TouchIDOutcome {
    // OmacVM.app's panel when it can show (the Mac password needs this dialog).
    if let ask = p.appPanel, !passwordFallback, touchIDPanelSetting() {
      if let o = ask(p, timeout, gone) { return o }
      log("touchid: OmacVM.app's panel could not show: macOS's dialog instead")
    }
    let reason = p.reason
    let c = LAContext()
    c.touchIDAuthenticationAllowableReuseDuration = 0
    if !passwordFallback { c.localizedFallbackTitle = "" }   // no "Use Password" button
    let done = DispatchSemaphore(value: 0)
    var result = TouchIDOutcome.no(.failed)
    let lock = NSLock()
    c.evaluatePolicy(policy(passwordFallback), localizedReason: reason) { ok, e in
      lock.lock(); result = ok ? .yes : .no(LATouchID.no(e)); lock.unlock()
      done.signal()
    }
    let end = Date().addingTimeInterval(timeout)
    while done.wait(timeout: .now() + 0.25) == .timedOut {
      let why: TouchIDNo? = Date() >= end ? .timeout : gone() ? .cancelled : nil
      guard let why else { continue }
      c.invalidate()   // closes the dialog; the reply comes with appCancel
      _ = done.wait(timeout: .now() + 2)
      return .no(why)
    }
    c.invalidate()
    lock.lock(); defer { lock.unlock() }
    return result
  }
}

/// OmacVM.app's panel (TouchIDPanelPrompt in app/app/Sources/OmacVMAuth):
/// the words and the VM's theme go to the app in an interim answer on the
/// relay connection; the app's one-line answer comes back on it. The app is
/// this Mac user's own program behind the relay key, as trusted as the VM's
/// Touch ID key on this Mac. Nil: the panel could not show (macOS's dialog).
/// The app's connection closing (the VM's client went away) ends the wait.
func touchIDAskAppPanel(fd: Int32, _ p: TouchIDPrompt, timeout: Double) -> TouchIDOutcome? {
  let text = touchIDPanelText(p.request, vm: p.vmLabel)
  let theme = p.theme.flatMap { touchIDThemes.load($0) } ?? .tokyoNight
  var o: [String: Any] = ["title": text.title, "line": text.line, "timeout": Int(timeout), "theme": theme.panelColors]
  if let box = text.box { o["box"] = box }
  let head = "HTTP/1.1 103 Touch ID Panel\r\nX-OmacVM-Panel: \(jsonData(o).base64EncodedString())\r\n\r\n"
  guard writeAll(fd, Data(head.utf8)) else { return .no(.cancelled) }
  let end = Date().addingTimeInterval(timeout + 5)
  var line = Data(), b = [UInt8](repeating: 0, count: 64)
  while Date() < end {
    var pf = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pf, 1, 250)
    if ready < 0 { if errno == EINTR { continue }; return .no(.cancelled) }
    if ready == 0 { continue }
    let n = b.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if n < 0 && errno == EINTR { continue }
    if n <= 0 { return .no(.cancelled) }   // the app (and the VM's client) went away
    line.append(contentsOf: b[0..<n])
    guard let nl = line.firstIndex(of: 0x0A) else { if line.count > 64 { return .no(.failed) }; continue }
    let answer = String(decoding: line[..<nl], as: UTF8.self)
    log("touchid: OmacVM.app's panel: \(logSafe(answer))")
    return touchIDAppPanelOutcome(answer)
  }
  return .no(.timeout)
}

/// "touch_id_panel": false in the Bridge's config.json: macOS's dialog instead
/// of OmacVM.app's panel (on unless set; read at each request).
func touchIDPanelSetting() -> Bool {
  guard let d = FileManager.default.contents(atPath: config.path),
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return true }
  return strictBool(o["touch_id_panel"]) ?? true
}

/// The themes VMs sent (POST /omacvm/theme), kept per VM in the Bridge's folder.
let touchIDThemes = TouchIDThemeStore(dir: supportDir + "/touchid-theme")

/// The Mac's state as macOS says it now, read on the main thread (requests
/// come on their own threads; NSWorkspace is the main thread's, as in
/// external-brightness.swift).
struct LiveMacState: TouchIDMacState {
  var locked: Bool {
    DispatchQueue.main.sync {
      let d = CGSessionCopyCurrentDictionary() as? [String: Any]
      if (d?["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
      if (d?["kCGSSessionOnConsoleKey"] as? Bool) == false { return true }   // another user's session in front
      return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
  }
  var frontType: String? {
    DispatchQueue.main.sync {
      guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
      return vmTypeOfFront(kernelPath: pidPath(app.processIdentifier), launchServicesPath: app.executableURL?.path)
    }
  }
}

/// "touch_id_password_fallback": true in the Bridge's config.json lets the
/// dialog offer the Mac's password. Off unless the person sets it; read at
/// each request (Config is the main thread's).
func touchIDPasswordFallback() -> Bool {
  guard let d = FileManager.default.contents(atPath: config.path),
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
  return strictBool(o["touch_id_password_fallback"]) ?? false
}

let touchID = TouchIDDecider(auth: LATouchID(), mac: LiveMacState())

/// True once the VM's client closed its end (Ctrl+C in sudo).
func peerGone(_ fd: Int32) -> Bool {
  var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
  guard poll(&p, 1, 0) > 0 else { return false }
  if p.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
  var b: UInt8 = 0
  return recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT) == 0
}

/// One request (server.swift, after the Bridge token checked out).
func touchIDRequest(fd: Int32, peer: String, method: String, path: String, headers: [String: String], body: Data) {
  let c = control.touchIDCaller(fd: fd, peer: peer, method: method, path: path, headers: headers, body: body)
  let name = c.vm?.name ?? "-"
  func reply(_ code: Int, _ obj: [String: Any], _ note: String, quiet: Bool = false) {
    // Refusals and fast noes once a minute per kind: a looping VM must not fill the log.
    let line = "touchid: from \(peer) (\(logSafe(name))): \(code) \(logSafe(note))"
    if code >= 400 || quiet { logRefusal("touchid \(peer) \(name) \(code) \(quiet ? note : "")", line) } else { log(line) }
    guard let k = c.key, let n = c.nonce else { return respond(fd, code, obj) }
    let data = jsonData(obj) + Data("\n".utf8)
    let sig = answerMAC(key: k, nonce: n, status: code, body: data, label: touchIDAnswerLabel)
    _ = writeAll(fd, httpHead(code, "application/json", length: data.count, extra: "X-OmacVM-Answer: \(sig)\r\n") + data)
    close(fd)
  }
  guard method == "POST" else { return reply(405, ["error": "POST only"], "not POST") }
  if let e = c.error { return reply(e.status, ["error": e.message, "code": e.code], e.code) }
  guard let vm = c.vm else { return reply(403, ["error": "unknown VM", "code": "unknown-vm"], "unknown") }
  // The feature is off for this VM (no key on the Mac): refused, no dialog.
  guard c.key != nil else { return reply(403, ["error": "Touch ID is off for this VM", "code": "off"], "off") }
  let r: TouchIDRequest
  switch parseTouchIDRequest(body) {
  case .success(let x): r = x
  case .failure(let e): return reply(e.status, ["error": e.message, "code": e.code], e.code)
  }
  let label = control.setUpVMCount() > 1 ? vm.name : nil
  // OmacVM.app says it can show the panel (only through its relay: c.vm came from there).
  let panel: TouchIDAppPanel? = headers["x-omacvm-panel"] == "1" && vm.type == "app"
    ? { p, timeout, _ in touchIDAskAppPanel(fd: fd, p, timeout: timeout) } : nil
  let o = touchID.decide(vm: VMListCache.key(vm), type: vm.type, on: true, request: r, vmLabel: label,
                         passwordFallback: touchIDPasswordFallback(), theme: vmKeyName(type: vm.type, name: vm.name),
                         appPanel: panel, gone: { peerGone(fd) })
  let result: String
  if case .no(let n) = o { result = "no " + n.rawValue } else { result = "yes" }
  var fast = false
  if case .no(let n) = o, n == .rate || n == .busy { fast = true }
  reply(200, touchIDAnswer(o), "\(r.kind.rawValue) \(result)", quiet: fast)   // never the detail
}
