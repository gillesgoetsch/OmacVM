// Touch ID for the VM (ADR 0041): POST /omacvm/touchid from the VM's PAM
// client. The Mac shows its own Touch ID dialog and answers only yes or no,
// signed with the VM's Touch ID key. Nothing about the finger leaves macOS:
// LocalAuthentication gives the Bridge success or an error code, no more.
import AppKit
import Darwin
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

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

/// The Bridge's own panel (touchid_panel.swift) in the VM's Omarchy theme,
/// with Apple's embedded Touch ID view for a fresh LAContext; macOS's alert
/// (LATouchID) when the panel cannot be used (TouchIDPanelGate): the Mac
/// password offered, "touch_id_panel": false, no VM window on a screen, or
/// the embedded view failed fast once in this run.
final class LAPanelTouchID: TouchIDAuthenticator {
  private let alert = LATouchID()
  private let lock = NSLock()
  private var gate = TouchIDPanelGate()
  let themes: TouchIDThemeStore
  let mac: TouchIDMacState
  init(themes: TouchIDThemeStore, mac: TouchIDMacState) { self.themes = themes; self.mac = mac }

  /// The bundled fonts, once (Contents/Resources).
  private static let fonts: Void = { if let r = Bundle.main.resourcePath { TouchIDPanelFonts.register(r) } }()

  func unavailable(passwordFallback: Bool) -> TouchIDNo? { alert.unavailable(passwordFallback: passwordFallback) }

  private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

  static func end(_ ok: Bool, _ e: Error?) -> TouchIDLAEnd {
    if ok { return .yes }
    guard let e = e as? LAError else { return .other }
    switch e.code {
    case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
    case .biometryLockout: return .lockout
    case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet: return .notAvailable
    case .authenticationFailed: return .failed
    default: return .other
    }
  }

  func evaluate(_ p: TouchIDPrompt, passwordFallback: Bool, timeout: Double, gone: @escaping () -> Bool) -> TouchIDOutcome {
    let show = locked { gate.show(passwordFallback: passwordFallback, setting: touchIDPanelSetting(), windowFound: true) }
    guard show == .panel else { return alert.evaluate(p, passwordFallback: passwordFallback, timeout: timeout, gone: gone) }
    _ = LAPanelTouchID.fonts
    let theme = p.theme.flatMap { themes.load($0) } ?? .tokyoNight
    let c = LAContext()
    c.touchIDAuthenticationAllowableReuseDuration = 0
    c.localizedFallbackTitle = ""   // no "Use Password" (that needs the alert)
    let flow = TouchIDPanelFlow(theme: theme, text: touchIDPanelText(p.request, vm: p.vmLabel),
                                icon: DispatchQueue.main.sync { NSApp.applicationIconImage }, marker: VMKeys.marker)
    flow.place = { size in
      // The VM's app is in front (the decider checked): its frontmost window.
      guard let app = NSWorkspace.shared.frontmostApplication, let w = touchIDFrontWindow(pid: app.processIdentifier),
            let pl = touchIDPanelPlacement(window: w, screens: touchIDPanelScreens(), size: size) else { return nil }
      log("touchid: panel \(pl.style == .notch ? "under the notch" : "over the VM's window") (theme \(theme.background.hex))")
      return pl
    }
    flow.authView = { LAAuthenticationView(context: c, controlSize: .regular) }   // 64 pt, the panel's slot
    flow.start = { done in
      c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: p.reason) { ok, e in done(LAPanelTouchID.end(ok, e)) }
    }
    flow.stop = { c.invalidate() }
    let mac = self.mac
    flow.interrupt = { mac.locked ? .locked : mac.frontType != p.vmType ? .notFront : nil }
    let began = Date()
    let r = flow.run(timeout: timeout, gone: gone)
    c.invalidate()
    switch r {
    case .done(let o): return o
    case .noWindow:
      log("touchid: the VM's window is not on a screen: macOS's alert instead of the panel")
      return alert.evaluate(p, passwordFallback: passwordFallback, timeout: timeout, gone: gone)
    case .ended(let e, let after):
      if locked({ gate.ended(e, after: after) }) {
        log("touchid: the panel's Touch ID view did not work (it ended at once): macOS's alert until the Bridge restarts")
        let left = max(5, timeout - Date().timeIntervalSince(began))
        return alert.evaluate(p, passwordFallback: passwordFallback, timeout: left, gone: gone)
      }
      return touchIDOutcome(e)
    }
  }
}

/// "touch_id_panel": false in the Bridge's config.json: macOS's alert instead
/// of the panel (on unless set; read at each request).
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
      guard let app = NSWorkspace.shared.frontmostApplication,
            let exe = app.executableURL?.path ?? pidPath(app.processIdentifier) else { return nil }
      return vmTypeOfExecutable(exe)
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

let touchID = TouchIDDecider(auth: LAPanelTouchID(themes: touchIDThemes, mac: LiveMacState()), mac: LiveMacState())

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
  let o = touchID.decide(vm: VMListCache.key(vm), type: vm.type, on: true, request: r, vmLabel: label,
                         passwordFallback: touchIDPasswordFallback(), theme: vmKeyName(type: vm.type, name: vm.name),
                         gone: { peerGone(fd) })
  let result: String
  if case .no(let n) = o { result = "no " + n.rawValue } else { result = "yes" }
  var fast = false
  if case .no(let n) = o, n == .rate || n == .busy { fast = true }
  reply(200, touchIDAnswer(o), "\(r.kind.rawValue) \(result)", quiet: fast)   // never the detail
}
