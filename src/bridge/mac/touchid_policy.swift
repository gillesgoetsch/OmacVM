// Touch ID for the VM (ADR 0041), the parts without macOS: the request, the
// dialog text, the limits and the order of the checks. touchid.swift adds
// LocalAuthentication and the Mac's state; tests/touchid mocks both.
import Foundation

let touchIDPath = "/omacvm/touchid"
let touchIDBodyMax = 1024
let touchIDRequestLabel = "omacvm-touchid-request 1"
let touchIDAnswerLabel = "omacvm-touchid-answer 1"
let touchIDDialogTimeout: Double = 30

/// The file name of a VM's Touch ID key on the Mac: the control key's name + ".touchid".
func touchIDKeyName(type: String, name: String) -> String { vmKeyName(type: type, name: name) + ".touchid" }

enum TouchIDKind: String { case sudo, polkit, onePassword = "1password" }

struct TouchIDRequest: Equatable {
  let kind: TouchIDKind
  let user: String
  let detail: String
  let action: String
  var tty = ""   // sudo: the terminal it runs in (pts/3), shown in the dialog
}

/// Why the answer is no. The VM shows the fast ones (TouchIDNo.fast).
enum TouchIDNo: String {
  case cancelled, failed, timeout, busy, rate, locked, notFront = "not-front", noTouchID = "no-touch-id", lockout, off
}

private func matches(_ s: String, first: (UInt8) -> Bool, rest: (UInt8) -> Bool, max: Int) -> Bool {
  let b = Array(s.utf8)
  guard let f = b.first, b.count <= max, first(f) else { return false }
  return b.dropFirst().allSatisfy(rest)
}
private func lower(_ c: UInt8) -> Bool { (97...122).contains(c) }
private func digit(_ c: UInt8) -> Bool { (48...57).contains(c) }
private func upper(_ c: UInt8) -> Bool { (65...90).contains(c) }

/// "pts/3" or "tty2": a terminal's name under /dev, digits after the prefix.
func isTTYName(_ s: String) -> Bool {
  for p in ["pts/", "tty"] where s.hasPrefix(p) {
    let n = s.dropFirst(p.count)
    return (1...4).contains(n.utf8.count) && n.utf8.allSatisfy(digit)
  }
  return false
}

/// Strict JSON, at most 1 KB, known keys only, each field checked.
func parseTouchIDRequest(_ body: Data) -> Result<TouchIDRequest, PolicyError> {
  guard body.count <= touchIDBodyMax else { return .failure(PolicyError(413, "too-large", "body over \(touchIDBodyMax) bytes")) }
  let o: [String: Any]
  do {
    guard let obj = try strictObject(body, allowed: ["kind", "user", "detail", "action", "tty"]) else {
      return .failure(PolicyError(400, "bad-json", "body must be a JSON object"))
    }
    o = obj
  } catch let e as PolicyError { return .failure(e) } catch { return .failure(PolicyError(400, "bad-json", "body must be a JSON object")) }
  func text(_ k: String) -> String?? {   // nil: wrong type; .some(nil): missing
    guard let v = o[k] else { return .some(nil) }
    guard let s = v as? String else { return nil }
    return .some(s)
  }
  guard let k = text("kind"), let ks = k, let kind = TouchIDKind(rawValue: ks) else {
    return .failure(PolicyError(400, "kind", "kind: sudo, polkit or 1password"))
  }
  // A desktop user's name (dots and capitals too, as useradd --badname allows), never root.
  guard let u = text("user"), let user = u, user != "root",
        matches(user, first: { lower($0) || upper($0) || $0 == 95 },
                rest: { lower($0) || upper($0) || digit($0) || $0 == 95 || $0 == 45 || $0 == 46 }, max: 32) else {
    return .failure(PolicyError(400, "user", "user: a Linux user name, not root"))
  }
  guard let d = text("detail") else { return .failure(PolicyError(400, "detail", "detail: text")) }
  let detail = d ?? ""
  guard detail.utf8.count <= 200 else { return .failure(PolicyError(400, "detail", "detail: at most 200 bytes")) }
  guard let a = text("action") else { return .failure(PolicyError(400, "action", "action: a polkit action id")) }
  let action = a ?? ""
  let actionChar: (UInt8) -> Bool = { lower($0) || (65...90).contains($0) || digit($0) || $0 == 46 || $0 == 95 || $0 == 45 }
  guard action.isEmpty || matches(action, first: actionChar, rest: actionChar, max: 128) else {
    return .failure(PolicyError(400, "action", "action: a polkit action id"))
  }
  guard let y = text("tty") else { return .failure(PolicyError(400, "tty", "tty: pts/N or ttyN")) }
  let tty = y ?? ""
  guard tty.isEmpty || isTTYName(tty) else { return .failure(PolicyError(400, "tty", "tty: pts/N or ttyN")) }
  return .success(TouchIDRequest(kind: kind, user: user, detail: detail, action: action, tty: tty))
}

/// Text from the VM for the dialog: control, direction, invisible and
/// unusual space characters become one plain space; cut to `max` with "… (cut)".
func touchIDClean(_ s: String, max: Int) -> String {
  let bad: (Unicode.Scalar) -> Bool = { c in
    let v = c.value
    return v < 0x20 || (0x7f...0xa0).contains(v) || v == 0x00ad || v == 0x034f || v == 0x061c || v == 0x115f || v == 0x1160
      || v == 0x1680 || v == 0x180e || (0x2000...0x200f).contains(v) || (0x2028...0x202f).contains(v)
      || (0x205f...0x206f).contains(v) || v == 0x2800 || v == 0x3000 || v == 0x3164 || (0xfe00...0xfe0f).contains(v)
      || v == 0xfeff || v == 0xffa0 || (0xfff9...0xfffb).contains(v) || (0xe0000...0xe007f).contains(v)
  }
  var out = String(String.UnicodeScalarView(s.unicodeScalars.map { bad($0) ? Unicode.Scalar(UInt8(32)) : $0 }))
  out = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
  let mark = "… (cut)"
  if out.count > max { out = String(out.prefix(max - mark.count)) + mark }
  return out
}

/// The longest command the dialog shows; the VM's client asks for the
/// password instead of sending a longer one (ADR 0041).
let touchIDCommandMax = 120

/// macOS shows "OmacVM Bridge is trying to <reason>." `vm`: the VM's name when
/// this Mac has more than one VM set up, else nil.
func touchIDReason(_ r: TouchIDRequest, vm: String?) -> String {
  let label = vm.map { touchIDClean($0, max: 40) }
  let place = "Omarchy" + (label.map { " (\($0))" } ?? "")
  switch r.kind {
  case .onePassword: return "unlock 1Password in \(place)"
  case .sudo:
    // The terminal it runs in: a dialog for a terminal the person has not open stands out.
    let parts = [label, r.tty.isEmpty ? nil : r.tty].compactMap { $0 }
    let at = "Omarchy" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
    let cmd = touchIDClean(r.detail, max: touchIDCommandMax)
    return cmd.isEmpty ? "run sudo in \(at)" : "run sudo in \(at): \(cmd)"
  case .polkit:
    return r.action.isEmpty ? "allow a system request in \(place)" : "allow \"\(r.action)\" in \(place)"
  }
}

/// The VM app type (omacvm vms --json "type") of the app in front, from its executable.
/// The app in front, from its kernel path first: OmacVM.app starts QEMU
/// through Contents/MacOS/OmacVM-VM (DockIdentity, 3.0.1), and LaunchServices
/// then names the app's own executable (Contents/MacOS/OmacVM) for it, while
/// the kernel keeps runtime/bin/OmacVM. As VMApp.of in external-brightness.swift.
func vmTypeOfFront(kernelPath: String?, launchServicesPath: String?) -> String? {
  guard let exe = kernelPath ?? launchServicesPath else { return nil }
  return vmTypeOfExecutable(exe)
}

func vmTypeOfExecutable(_ path: String) -> String? {
  let name = (path as NSString).lastPathComponent
  if path.hasSuffix("/runtime/bin/OmacVM") || name == "qemu-system-aarch64" { return "app" }
  switch name {
  case "prl_client_app": return "parallels"
  case "UTM": return "utm"
  case "VMware Fusion": return "fusion"
  default: return nil
  }
}

/// One dialog at a time on the Mac; per VM one request every 2 s, 10 a
/// minute, and after 3 misses in a row (cancelled, failed or not answered)
/// a pause of "rate": 60 s, then 5 min, then 30 min, until a yes or an hour
/// without a pause. So a VM
/// that keeps dialogs up for nobody stops doing so quickly.
let touchIDPauses: [TimeInterval] = [60, 300, 1800]
struct TouchIDLimiter {
  private(set) var busy = false
  private var last: [String: Date] = [:]
  private var minute: [String: [Date]] = [:]
  private var failures: [String: Int] = [:]
  private var pausedUntil: [String: Date] = [:]
  private var pauses: [String: Int] = [:]

  mutating func admit(_ vm: String, now: Date) -> TouchIDNo? {
    if let p = pausedUntil[vm], now < p { return .rate }
    if let l = last[vm], now.timeIntervalSince(l) < 2 { return .rate }
    let recent = (minute[vm] ?? []).filter { now.timeIntervalSince($0) < 60 }
    minute[vm] = recent
    if recent.count >= 10 { return .rate }
    if busy { return .busy }
    busy = true
    last[vm] = now
    minute[vm] = recent + [now]
    return nil
  }

  /// After an admitted request: the dialog is closed, and the count of misses goes on.
  mutating func finished(_ vm: String, yes: Bool, no: TouchIDNo?, now: Date) {
    busy = false
    if yes { failures[vm] = 0; pauses[vm] = 0; return }
    guard no == .cancelled || no == .failed || no == .timeout else { return }
    let n = (failures[vm] ?? 0) + 1
    guard n >= 3 else { failures[vm] = n; return }
    // An hour without a pause starts the pauses at 60 s again.
    var p = pauses[vm] ?? 0
    if let u = pausedUntil[vm], now.timeIntervalSince(u) > 3600 { p = 0 }
    pausedUntil[vm] = now.addingTimeInterval(touchIDPauses[min(p, touchIDPauses.count - 1)])
    pauses[vm] = p + 1; failures[vm] = 0
  }
}

enum TouchIDOutcome: Equatable { case yes, no(TouchIDNo) }

/// What the dialog (or the panel) is about, and for which VM.
struct TouchIDPrompt {
  let reason: String           // touchIDReason: the text of macOS's alert
  let request: TouchIDRequest  // the panel's words come from here (touchIDPanelText)
  let vmLabel: String?         // the VM's name when the Mac has several
  let vmType: String           // its app (omacvm vms --json "type")
  var theme: String?           // its key name: the theme the Mac keeps for it
  var appPanel: TouchIDAppPanel? = nil
}

/// OmacVM.app's panel, shown by the VM window's own process (QEMU): asks it
/// and gives the outcome, or nil when it could not show (macOS's dialog then).
typealias TouchIDAppPanel = (_ p: TouchIDPrompt, _ timeout: Double, _ gone: @escaping () -> Bool) -> TouchIDOutcome?

/// LocalAuthentication, or a mock.
protocol TouchIDAuthenticator {
  /// Nil when a dialog can be shown; else why not (no-touch-id, lockout).
  func unavailable(passwordFallback: Bool) -> TouchIDNo?
  /// Shows the dialog; a fresh context each time. `gone` is asked about every
  /// quarter second: true (the VM's client went away) cancels the dialog.
  func evaluate(_ p: TouchIDPrompt, passwordFallback: Bool, timeout: Double, gone: @escaping () -> Bool) -> TouchIDOutcome
}

/// The Mac's state, or a mock.
protocol TouchIDMacState {
  var locked: Bool { get }          // screen locked or display asleep
  var frontType: String? { get }    // the VM app type in front (vmTypeOfExecutable), nil for another app
}

/// The checks in order, and the dialog. Thread-safe: requests come on their own threads.
final class TouchIDDecider {
  private let lock = NSLock()
  private var limits = TouchIDLimiter()
  let auth: TouchIDAuthenticator
  let mac: TouchIDMacState
  var timeout = touchIDDialogTimeout
  init(auth: TouchIDAuthenticator, mac: TouchIDMacState) { self.auth = auth; self.mac = mac }

  /// `vm`: the VM's key for the limits; `type`: its app (omacvm vms --json);
  /// `on`: the feature is on for it (its key is on the Mac); `theme`: its
  /// key name, for the panel's colours.
  func decide(vm: String, type: String, on: Bool, request: TouchIDRequest, vmLabel: String?, passwordFallback: Bool,
              theme: String? = nil, appPanel: TouchIDAppPanel? = nil, now: Date = Date(),
              gone: @escaping () -> Bool = { false }) -> TouchIDOutcome {
    guard on else { return .no(.off) }
    if let n = locked({ limits.admit(vm, now: now) }) { return .no(n) }
    let outcome: TouchIDOutcome
    if mac.locked { outcome = .no(.locked) }
    else if mac.frontType != type { outcome = .no(.notFront) }
    else if let n = auth.unavailable(passwordFallback: passwordFallback) { outcome = .no(n) }
    else {
      let p = TouchIDPrompt(reason: touchIDReason(request, vm: vmLabel), request: request, vmLabel: vmLabel, vmType: type, theme: theme,
                            appPanel: appPanel)
      outcome = auth.evaluate(p, passwordFallback: passwordFallback, timeout: timeout, gone: gone)
    }
    // The pause after misses counts from the request's time (tests give it).
    locked {
      if case .no(let n) = outcome { limits.finished(vm, yes: false, no: n, now: now) } else { limits.finished(vm, yes: true, no: nil, now: now) }
    }
    return outcome
  }

  private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
}

/// The answer's body: {"result":"yes"} or {"result":"no","reason":...}.
func touchIDAnswer(_ o: TouchIDOutcome) -> [String: Any] {
  switch o {
  case .yes: return ["result": "yes"]
  case .no(let n): return ["result": "no", "reason": n.rawValue]
  }
}
