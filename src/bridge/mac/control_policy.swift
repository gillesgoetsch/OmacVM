// The control centre's requests (docs/adr/0031): the fixed list, checked
// before anything runs. Pure (no Bridge state), so tests/control_tests.swift
// covers every accepted shape and every refusal. The guest is untrusted:
// nothing it sends reaches a command line except feature names that are in
// the Mac's own features.tsv.
import CryptoKit
import Foundation

let controlProto = 1, controlProtoMin = 1
let controlBodyMax = 4096
let controlFeaturesMax = 16
let jobsPerHour = 20

enum ControlAction: String { case enable, disable, reinstall, update, graphics }

/// OmacVM.app's Graphics setting (src/cmd/graphics.sh): the only values a
/// graphics job takes.
let graphicsChoices: Set<String> = ["opengl", "vulkan", "auto"]

struct JobRequest: Equatable { let action: ControlAction; let features: [String] }

enum ControlRoute: Equatable {
  case hello, status, updates, updatesCheck, gpuMemory, appUpdate
  case setUpdateChecks(Bool)
  case mouseSwipe, setMouseSwipe(Int)
  case startJob(JobRequest)
  case job(String)
  case theme(Data)   // the Touch ID panel's colours (touchid_theme.swift checks the body)
}

struct PolicyError: Error, Equatable {
  let status: Int, code: String, message: String
  init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.code = code; self.message = message }
}

/// Old names a control centre from before a rename still sends: the Mac's
/// omacvm takes them (src/lib/features.sh: feature_alias).
let renamedFeatures = ["idle-lock": "no-idle-lock"]

/// The names the control centre may send (as features.tsv's own rule).
func validFeatureName(_ s: String) -> Bool {
  guard (2...32).contains(s.utf8.count), let f = s.utf8.first, (97...122).contains(f) else { return false }
  return s.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
}

func validJobID(_ s: String) -> Bool {
  s.utf8.count == 16 && s.utf8.allSatisfy { (97...102).contains($0) || (48...57).contains($0) }
}

/// A JSON object with only `allowed` keys, or nil for no body.
func strictObject(_ body: Data, allowed: Set<String>) throws -> [String: Any]? {
  if body.isEmpty { return nil }
  guard body.count <= controlBodyMax else { throw PolicyError(413, "too-large", "body over \(controlBodyMax) bytes") }
  guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
    throw PolicyError(400, "bad-json", "body must be a JSON object")
  }
  if let extra = obj.keys.first(where: { !allowed.contains($0) }) {
    throw PolicyError(400, "unknown-key", "unknown key '\(extra.prefix(32))'")
  }
  return obj
}

/// JSON true/false only (JSONSerialization also turns 0 and 1 into NSNumber).
func strictBool(_ v: Any?) -> Bool? {
  guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
  return n.boolValue
}

/// Method + path + body -> one of the allowed requests, or why not.
func controlRoute(method: String, path: String, body: Data, known: Set<String>) -> Result<ControlRoute, PolicyError> {
  do {
    guard path.hasPrefix("/omacvm/") else { throw PolicyError(404, "not-found", "not found") }
    let sub = String(path.dropFirst("/omacvm/".count))
    switch (method, sub) {
    case ("GET", "hello"), ("GET", "status"), ("GET", "updates"), ("GET", "gpu-memory"):
      guard body.isEmpty else { throw PolicyError(400, "body", "no body for GET") }
      return .success(sub == "hello" ? .hello : sub == "status" ? .status : sub == "updates" ? .updates : .gpuMemory)
    case ("POST", "updates/check"):
      if let o = try strictObject(body, allowed: []), !o.isEmpty { throw PolicyError(400, "unknown-key", "no keys") }
      return .success(.updatesCheck)
    case ("POST", "app-update"):
      // The VM never names a version: the Mac's own verified release counts.
      if let o = try strictObject(body, allowed: []), !o.isEmpty { throw PolicyError(400, "unknown-key", "no keys") }
      return .success(.appUpdate)
    case ("POST", "settings/update-checks"):
      guard let o = try strictObject(body, allowed: ["enabled"]), let b = strictBool(o["enabled"]) else {
        throw PolicyError(400, "bad-body", "send {\"enabled\": true|false}")
      }
      return .success(.setUpdateChecks(b))
    case ("GET", "settings/mouse-swipe"):
      guard body.isEmpty else { throw PolicyError(400, "body", "no body for GET") }
      return .success(.mouseSwipe)
    case ("POST", "settings/mouse-swipe"):
      guard let o = try strictObject(body, allowed: ["fingers"]), let n = strictFingers(o["fingers"]) else {
        throw PolicyError(400, "bad-body", "send {\"fingers\": 3|4}")
      }
      return .success(.setMouseSwipe(n))
    case ("POST", "jobs"):
      guard let o = try strictObject(body, allowed: ["action", "features", "graphics"]),
            let a = o["action"] as? String, let action = ControlAction(rawValue: a) else {
        throw PolicyError(400, "bad-action", "action: enable, disable, reinstall, update or graphics")
      }
      if action == .graphics {
        guard o["features"] == nil, let g = o["graphics"] as? String, graphicsChoices.contains(g) else {
          throw PolicyError(400, "bad-body", "send {\"action\": \"graphics\", \"graphics\": \"opengl\"|\"vulkan\"|\"auto\"}")
        }
        return .success(.startJob(JobRequest(action: .graphics, features: [g])))
      }
      guard o["graphics"] == nil else { throw PolicyError(400, "bad-body", "graphics only with the graphics action") }
      if action == .update {
        guard o["features"] == nil else { throw PolicyError(400, "bad-body", "update takes no features") }
        return .success(.startJob(JobRequest(action: .update, features: [])))
      }
      guard let list = o["features"] as? [Any], (1...controlFeaturesMax).contains(list.count) else {
        throw PolicyError(400, "bad-features", "features: 1 to \(controlFeaturesMax) names")
      }
      var names: [String] = []
      for item in list {
        guard let n = item as? String, validFeatureName(n) else { throw PolicyError(400, "bad-features", "not a feature name") }
        guard known.contains(n) || renamedFeatures[n].map(known.contains) == true else { throw PolicyError(400, "unknown-feature", "'\(n)' is not a feature of this Mac's OmacVM") }
        guard !names.contains(n) else { throw PolicyError(400, "bad-features", "'\(n)' twice") }
        names.append(n)
      }
      return .success(.startJob(JobRequest(action: action, features: names)))
    case ("POST", "theme"):
      return .success(.theme(body))
    case ("GET", let s) where s.hasPrefix("jobs/"):
      let id = String(s.dropFirst(5))
      guard validJobID(id), body.isEmpty else { throw PolicyError(404, "not-found", "no such job") }
      return .success(.job(id))
    case (_, "hello"), (_, "status"), (_, "updates"), (_, "updates/check"), (_, "settings/update-checks"), (_, "jobs"),
         (_, "gpu-memory"), (_, "settings/mouse-swipe"), (_, "app-update"), (_, "theme"):
      throw PolicyError(405, "method", "method not allowed")
    default:
      throw PolicyError(404, "not-found", "not found")
    }
  } catch let e as PolicyError {
    return .failure(e)
  } catch {
    return .failure(PolicyError(400, "bad-request", "bad request"))
  }
}

// ---- Magic Mouse swipe (GET/POST /omacvm/settings/mouse-swipe) ----
// OmacVM Gestures' MouseSwipeFingers (#127): a two-finger swipe on a Magic
// Mouse is 3 or 4 fingers on the VM's trackpad. A Mac-wide setting, as in
// OmacVM.app (MouseSwipeSetting.swift); the control centre shows it only
// while the Mac has a Magic Mouse.
let mouseSwipeChoices = [3, 4]

/// A JSON 3 or 4: no bool, no 3.0, no "3".
func strictFingers(_ v: Any?) -> Int? {
  guard let n = v as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), !CFNumberIsFloatType(n),
        mouseSwipeChoices.contains(n.intValue) else { return nil }
  return n.intValue
}

/// What Gestures does with a stored value (mouseFingersOf in
/// omacvm-gestures.c): 3 (number or text) is 3, anything else 4.
func mouseSwipeFingers(stored: Any?) -> Int {
  if let s = stored as? String { return s == "3" ? 3 : 4 }
  if let n = stored as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID() { return n.doubleValue == 3 ? 3 : 4 }
  return 4
}

/// A Magic Mouse as Gestures and the app find it: Apple's multitouch family
/// 112, or Apple's product ids 0x030d, 0x0269, 0x0323 (Bluetooth or USB vendor).
func isMagicMouse(vendor: Int?, product: Int?, family: Int?) -> Bool {
  if family == 112 { return true }
  guard let p = product, [0x030d, 0x0269, 0x0323].contains(p), let v = vendor else { return false }
  return v == 0x004c || v == 0x05ac
}

func mouseSwipeAnswer(magicMouse: Bool, fingers: Int) -> [String: Any] {
  ["magic_mouse": magicMouse, "fingers": fingers == 3 ? 3 : 4]
}

/// The protocol both sides speak: the guest's (X-OmacVM-Proto, 1 when
/// missing) capped at ours; below our minimum nothing runs.
func negotiateProto(_ header: String?) -> Result<Int, PolicyError> {
  let guest = header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1
  let p = min(guest, controlProto)
  return p >= controlProtoMin ? .success(p)
    : .failure(PolicyError(409, "proto", "this VM's control centre is too old for the Mac (protocol \(guest)): update the VM"))
}

/// The relay socket's path (server.swift's RelaySocket): absolute and short
/// enough for a Unix socket address (sun_path holds 104 bytes with the NUL).
let relaySocketPathMax = 103
func relaySocketPathOK(_ p: String) -> Bool {
  p.hasPrefix("/") && !p.utf8.contains(0) && p.utf8.count <= relaySocketPathMax
}

/// A VM as `omacvm vms --json` lists it. `dir`: an OmacVM.app VM's folder.
struct VMEntry: Equatable {
  /// setup: OmacVM set it up from this Mac (its SSH host key is remembered).
  let name: String, type: String, state: String, ip: String, omacvm: String, setup: Bool
  var dir: String = ""
  /// OmacVM's SSH key got in at that address just now (`omacvm vms`).
  var reachable: Bool = true
  /// Why not (`omacvm vms`' "why", one line), when it runs and is not reachable.
  var why: String = ""
}

// ---- OmacVM.app's VMs: their CLI runs go through the app ----
// The Bridge spawns omacvm with its responsibility disclaimed (Local Network
// privacy, spawn() in control.swift). macOS then counts that bash as a
// program of its own and refuses it a VMs folder on an external drive
// without asking (Removable Volumes): the folder reads empty, and the VM is
// "no such OmacVM.app VM". For an app VM the Bridge runs omacvm through the
// app's own executable instead (`<app>/Contents/MacOS/OmacVM --control-run
// <cli> ...`, app/app/Sources/OmacVM/ControlRun.swift), also spawned
// disclaimed: macOS counts the run as the app's, with the access the person
// already gave the app (the drive, and the local network for the fast network).

/// The app executable that runs `cli` for the control centre: when cli is
/// an app's own copy (<app>/Contents/Resources/omacvm/omacvm, as the app
/// writes it) and that app's Info.plist (`info`) says it can
/// (OmacVMControlRun: an older app would open its window instead). The app
/// is of this Bridge's identity (`testApp`: the test identity's app id; a
/// lane's copy, `testApp`.<lane>, is the test identity too).
func appRunnerPath(cli: String, info: [String: Any]?, testIdentity: Bool, testApp: String) -> String? {
  let tail = "/Contents/Resources/omacvm/omacvm"
  guard cli.hasPrefix("/"), cli.hasSuffix(tail), !cli.contains("/../"), !cli.utf8.contains(0),
        let info, strictBool(info["OmacVMControlRun"]) == true,
        let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty, !exe.contains("/"), exe != "..",
        let id = info["CFBundleIdentifier"] as? String,
        (id == testApp || id.hasPrefix(testApp + ".")) == testIdentity else { return nil }
  return String(cli.dropLast(tail.count)) + "/Contents/MacOS/" + exe
}

/// One VM list from the Bridge's own run (`all`, every VM; an app VM on an
/// external drive is missing there) and the app's run (`app`, `omacvm vms
/// --json --app-only`; nil when there is none or it failed): the app's VMs
/// from the app's run, the others from the Bridge's. nil: the Bridge's run failed.
func mergeVMLists(all: [VMEntry]?, app: [VMEntry]?) -> [VMEntry]? {
  guard let all else { return nil }
  guard let app else { return all }
  return all.filter { $0.type != "app" } + app.filter { $0.type == "app" }
}

// ---- an OmacVM.app VM's graphics memory (GET /omacvm/gpu-memory) ----
// QEMU writes logs/gpu-memory in the VM's folder while it runs
// (virgl-darwin-memory-pressure.patch): what the VM's GPU work uses of the
// Mac's memory on top of the VM memory. The control centre shows it, asking
// at most every 2 s while it is open. Only numbers and a pressure word go
// back: no names (lost_last is a guest app's name), no paths.
let gpuMemoryFileMax = 4096
let gpuMemoryPressures: Set<String> = ["normal", "warn", "critical"]

/// The status file of a VM folder from `omacvm vms --json`, or nil.
func gpuMemoryFile(dir: String) -> String? {
  guard dir.hasPrefix("/"), !dir.utf8.contains(0), dir.utf8.count <= 1024, !dir.contains("/../"), !dir.hasSuffix("/..")
  else { return nil }
  return dir + "/logs/gpu-memory"
}

/// The file's text as OmacVM.app sends it with a relayed request
/// (X-OmacVM-GPU-Memory: base64, "-" when there is no file): the app reads
/// its VM's folder, which the Bridge may not (an external drive). nil
/// (absent or not valid): the Bridge reads the file itself (an older app).
/// .some(nil): the app says there is no file.
func gpuMemoryFromApp(_ header: String?) -> String?? {
  guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty, h.utf8.count <= 8192 else { return nil }
  if h == "-" { return .some(nil) }
  guard let d = Data(base64Encoded: h), d.count <= gpuMemoryFileMax, let t = String(data: d, encoding: .utf8) else { return nil }
  return .some(t)
}

/// The answer from the file's text (nil: no file). "measured": false until
/// QEMU wrote its first numbers (the VM just started, or an app older than 3.0.0).
func gpuMemoryAnswer(_ text: String?) -> [String: Any] {
  guard let text = text, text.utf8.count <= gpuMemoryFileMax else { return ["measured": false] }
  var numbers: [String: Int] = [:]
  var pressure = "unknown"
  for line in text.split(separator: "\n") {
    let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
    guard kv.count == 2 else { continue }
    switch kv[0] {
    case "in_use_mb", "peak_mb", "budget_mb", "refused", "lost":
      // Plain decimal only, at most 12 digits: no signs, no overflow.
      if (1...12).contains(kv[1].utf8.count), kv[1].utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(kv[1]) {
        numbers[kv[0]] = n
      }
    case "pressure":
      if gpuMemoryPressures.contains(kv[1]) { pressure = kv[1] }
    default:
      break
    }
  }
  guard let inUse = numbers["in_use_mb"] else { return ["measured": false] }
  return ["measured": true, "in_use_mb": inUse, "peak_mb": max(numbers["peak_mb"] ?? inUse, inUse),
          "budget_mb": numbers["budget_mb"] ?? 0, "pressure": pressure, "refused": numbers["refused"] ?? 0,
          "lost": numbers["lost"] ?? 0]
}

/// The VM a request came from: exactly one running VM OmacVM set up at the
/// peer's address. The guest never names a VM. Its key (verifyControlAuth) proves
/// it is that VM and not one that took its address.
func vmForPeer(_ peer: String, _ vms: [VMEntry]) -> Result<VMEntry, PolicyError> {
  if peer.hasPrefix("127.") {
    return .failure(PolicyError(403, "app-vm", "OmacVM.app's VMs ask through the app's control port: update OmacVM.app"))
  }
  let hits = vms.filter { $0.state == "running" && $0.setup && $0.reachable && $0.ip == peer }
  switch hits.count {
  case 1: return .success(hits[0])
  case 0:
    if let v = vms.first(where: { $0.state == "running" && $0.setup && $0.ip == peer }) {
      return .failure(PolicyError(409, "unknown-vm", unreachableText(v.why)))
    }
    return .failure(PolicyError(409, "unknown-vm", "no running VM that OmacVM set up has this address"))
  default: return .failure(PolicyError(409, "ambiguous-vm", "more than one VM has this address: nothing runs"))
  }
}

/// An OmacVM.app VM, named by the app (which knows which VM's control port a
/// request came through; the guest never names it): running and set up, and
/// reachable over SSH when the request needs that (`ssh`: the control
/// centre's checks and jobs do; Touch ID only needs the VM's key, and the app
/// vouches that the request came from that VM).
func vmForApp(_ name: String, _ vms: [VMEntry], ssh: Bool = true) -> Result<VMEntry, PolicyError> {
  let hits = vms.filter { $0.type == "app" && $0.name == name }
  guard let v = hits.first, hits.count == 1 else { return .failure(PolicyError(409, "unknown-vm", "no such OmacVM.app VM")) }
  guard v.state == "running" else { return .failure(PolicyError(409, "unknown-vm", notRunningText)) }
  guard v.setup else { return .failure(PolicyError(409, "unknown-vm", notSetUpText(v.name))) }
  guard v.reachable || !ssh else { return .failure(PolicyError(409, "unknown-vm", unreachableText(v.why))) }
  return .success(v)
}

/// The list has this OmacVM.app VM (by name), or a VM at this address, as
/// running: a refusal of it (not reachable, not set up) is answered from the
/// list, not by a fresh look at every VM (Control.vmList).
func appVMListed(_ name: String, _ vms: [VMEntry]) -> Bool {
  vms.contains { $0.type == "app" && $0.name == name && $0.state == "running" }
}
func peerListed(_ peer: String, _ vms: [VMEntry]) -> Bool {
  vms.contains { $0.state == "running" && !$0.ip.isEmpty && $0.ip == peer }
}

/// Requests about an OmacVM.app VM that the Bridge answers without SSH to
/// it: a job's state, graphics memory (a file), the Mac's own settings, the
/// Touch ID panel's colours. A VM the Mac cannot reach just now (busy, its
/// network moving) still gets them; checks and new jobs need SSH.
func routeNeedsSSH(_ r: ControlRoute) -> Bool {
  switch r {
  case .job, .gpuMemory, .mouseSwipe, .setMouseSwipe, .theme: return false
  default: return true
  }
}

let notRunningText = "the Mac's list of VMs has this VM as not running"
func notSetUpText(_ name: String) -> String {
  "OmacVM on the Mac did not set this VM up (on the Mac: omacvm apply --vm \"\(name)\" lets it in)"
}

/// A VM that runs and that OmacVM set up, but OmacVM's SSH did not get in
/// just now: why (`omacvm vms`), at most one short line of it.
func unreachableText(_ why: String) -> String {
  let w = String(why.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(240))
    .trimmingCharacters(in: .whitespaces)
  return "the Mac cannot reach this VM: " + (w.isEmpty ? "it runs, but SSH from the Mac did not answer" : w)
}

/// The file name of a VM's control key (lib/mac.sh vm_key_file): the first
/// 32 hex digits of SHA-256("<type>/<name>").
func vmKeyName(type: String, name: String) -> String {
  String(SHA256.hash(data: Data("\(type)/\(name)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
}

// ---- the VM's key: requests signed with it, answers too ----
// The key itself never crosses the network: every VM has the Bridge token, so
// a VM that answers for the Mac's address passes /proof and would learn
// anything sent after it. Each request carries
//   X-OmacVM-Auth: 1 <unix time> <nonce, 32 hex> <HMAC-SHA256(key, request text), hex>
// and each answer to a signed request
//   X-OmacVM-Answer: <HMAC-SHA256(key, answer text), hex>
// so the VM only believes answers from the Mac that has its key.

let authWindow: Double = 300          // seconds a request is good for, either way
let authKeyMin = 32

func hexSHA256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

func hmacHex(_ key: String, _ text: String) -> String {
  HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(key.utf8)))
    .map { String(format: "%02x", $0) }.joined()
}

/// What a request's signature covers: method, path, time, nonce, protocol
/// header and the body's hash.
func requestMAC(key: String, method: String, path: String, time: Int64, nonce: String, proto: String, body: Data,
                label: String = "omacvm-control-request 1") -> String {
  hmacHex(key, [label, method, path, String(time), nonce, proto, hexSHA256(body)].joined(separator: "\n"))
}

/// What an answer's signature covers: the request's nonce, the status and the body.
func answerMAC(key: String, nonce: String, status: Int, body: Data, label: String = "omacvm-control-answer 1") -> String {
  hmacHex(key, [label, nonce, String(status), hexSHA256(body)].joined(separator: "\n"))
}

func sameText(_ a: String, _ b: String) -> Bool {
  let x = Array(a.utf8), y = Array(b.utf8)
  guard x.count == y.count else { return false }
  var diff: UInt8 = 0
  for i in 0..<x.count { diff |= x[i] ^ y[i] }   // constant time
  return diff == 0
}

/// Nonces seen in the window, per VM: each signed request is taken once.
/// Each VM has its own set and its own cap, so a VM that sends many requests
/// fills only its own (and gets "rate"), never another VM's. A nonce is kept
/// while its request time is still in the window (time + authWindow).
/// `lines`/`load` keep the sets across Bridge restarts (an update restarts
/// it): a request caught before a restart is still refused after it.
enum NonceResult: Equatable { case taken, replay, full }

struct NonceStore {
  private var perVM: [String: [String: Int64]] = [:]   // VM -> nonce -> request time
  private var fresh: [String] = []                       // taken since the last drainNew()
  let perVMLimit: Int
  init(perVMLimit: Int = 4096) { self.perVMLimit = perVMLimit }

  private static func live(_ t: Int64, _ now: Int64) -> Bool { now - t <= Int64(authWindow) }

  mutating func take(vm: String, nonce: String, time: Int64, now: Date) -> NonceResult {
    let n = Int64(now.timeIntervalSince1970)
    var seen = perVM[vm] ?? [:]
    if seen[nonce] != nil { return .replay }
    if seen.count >= perVMLimit { seen = seen.filter { Self.live($0.value, n) } }
    defer { perVM[vm] = seen }
    if seen.count >= perVMLimit { return .full }
    seen[nonce] = time
    fresh.append("\(vm) \(nonce) \(time)")
    return .taken
  }

  /// The lines taken since the last call, to append to the file.
  mutating func drainNew() -> [String] { defer { fresh = [] }; return fresh }

  func count(vm: String) -> Int { perVM[vm]?.count ?? 0 }

  /// The live entries, one "VM nonce time" line each (VM: a file-name-safe
  /// key, vmKeyName).
  func lines(now: Date) -> [String] {
    let n = Int64(now.timeIntervalSince1970)
    return perVM.flatMap { vm, seen in seen.filter { Self.live($0.value, n) }.map { "\(vm) \($0.key) \($0.value)" } }
  }

  /// Lines as `lines` wrote them (also appended one at a time); expired,
  /// malformed and over-the-cap lines are dropped.
  mutating func load(_ text: String, now: Date) {
    let n = Int64(now.timeIntervalSince1970)
    for line in text.split(separator: "\n") {
      let f = line.split(separator: " ").map(String.init)
      guard f.count == 3, f[0].utf8.count == 32, f[1].utf8.count == 32, let t = Int64(f[2]), Self.live(t, n),
            (f[0] + f[1]).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
      var seen = perVM[f[0]] ?? [:]
      if seen.count < perVMLimit { seen[f[1]] = t }
      perVM[f[0]] = seen
    }
  }
}

/// Signed requests per VM: a burst, then a steady rate (the control centre
/// asks about once a second while a job runs). Keeps one VM's flood to itself
/// and below its nonce cap (rate x window < cap).
struct RequestLimiter {
  let burst: Double, perSecond: Double
  private var buckets: [String: (tokens: Double, at: Date)] = [:]
  init(burst: Double = 60, perSecond: Double = 4) { self.burst = burst; self.perSecond = perSecond }

  mutating func admit(_ vm: String, now: Date = Date()) -> PolicyError? {
    var b = buckets[vm] ?? (burst, now)
    b.tokens = min(burst, b.tokens + max(0, now.timeIntervalSince(b.at)) * perSecond)
    b.at = now
    defer { buckets[vm] = b }
    guard b.tokens >= 1 else { return PolicyError(429, "rate", "too many requests from this VM: wait a moment") }
    b.tokens -= 1
    return nil
  }
}

/// A refused signed request. `nonce` is set when the signature itself was
/// right (the answer may then be signed too: clock, replay); `macTime` for
/// a clock that is off.
struct AuthFailure: Error, Equatable {
  let error: PolicyError, nonce: String?, macTime: Int64?
}

func noVMKey() -> PolicyError {
  PolicyError(403, "no-vm-key", "the Mac has no control centre key for this VM yet: omacvm apply on the Mac")
}

/// Checks X-OmacVM-Auth against the key the Mac keeps for the VM (made by
/// omacvm apply). Success: the request's nonce (the answer is signed with it).
func verifyControlAuth(header: String?, key stored: String?, vm: String, method: String, path: String, proto: String,
                       body: Data, now: Date, nonces: inout NonceStore,
                       label: String = "omacvm-control-request 1") -> Result<String, AuthFailure> {
  guard let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines), key.utf8.count >= authKeyMin else {
    return .failure(AuthFailure(error: noVMKey(), nonce: nil, macTime: nil))
  }
  let bad = AuthFailure(error: PolicyError(403, "vm-key", "this VM's control centre key does not match: omacvm apply on the Mac"),
                        nonce: nil, macTime: nil)
  let f = (header ?? "").split(separator: " ").map(String.init)
  guard f.count == 4, f[0] == "1", let t = Int64(f[1]), f[2].utf8.count == 32, f[3].utf8.count == 64,
        f[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return .failure(bad) }
  guard sameText(requestMAC(key: key, method: method, path: path, time: t, nonce: f[2], proto: proto, body: body, label: label), f[3]) else {
    return .failure(bad)
  }
  let mac = Int64(now.timeIntervalSince1970)
  let off = abs(Double(t) - Double(mac))   // no Int64 overflow for a far-off time
  guard off <= authWindow else {
    return .failure(AuthFailure(error: PolicyError(403, "clock", "this VM's clock is \(off < 1e9 ? String(Int(off)) : "far") s off the Mac's"),
                                nonce: f[2], macTime: mac))
  }
  switch nonces.take(vm: vm, nonce: f[2], time: t, now: now) {
  case .taken: return .success(f[2])
  case .replay:
    return .failure(AuthFailure(error: PolicyError(403, "replay", "this request was sent before: not run again"), nonce: f[2], macTime: nil))
  case .full:
    return .failure(AuthFailure(error: PolicyError(429, "rate", "too many requests from this VM: wait a moment"), nonce: f[2], macTime: nil))
  }
}

/// Text from a request for the Bridge's log: no control characters (a
/// %0A in a path must not write a line of its own), at most 200 characters.
func logSafe(_ s: String) -> String {
  let control: (Unicode.Scalar) -> Bool = { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }
  return String(String(s.unicodeScalars.map { control($0) ? "?" : Character($0) }).prefix(200))
}

/// The exact command for a job: a fixed argv, no shell. `commit` only for
/// update, from the manifest the Mac verified itself. reinstall repairs the
/// named features only. The VM by name and app (a name may be in two apps).
func jobArgv(cli: String, _ r: JobRequest, vm: String, type: String, commit: String?) -> [String] {
  let which = ["--vm", vm, "--vm-type", type]
  switch r.action {
  case .enable, .disable:
    return [cli, r.action.rawValue] + r.features + which + ["--yes", "--transaction"]
  case .reinstall:
    return [cli, "apply"] + which + ["--transaction", "--yes"] + r.features.flatMap { ["--reinstall", $0] }
  case .update:
    return [cli, "update"] + which + ["--transaction", "--yes"] + (commit.map { ["--commit", $0] } ?? [])
  case .graphics:
    // The value is one of graphicsChoices (controlRoute); OmacVM.app VMs only.
    return [cli, "graphics", r.features.first ?? "auto"] + which + ["--yes"]
  }
}

/// A job's state from its exit code (nil: not ended): apply and update end
/// with 4 when they went back to what the VM had (--transaction).
func jobState(rc: Int32?, alive: Bool) -> String {
  switch rc {
  case nil: return alive ? "running" : "failed"
  case 0: return "done"
  case 4: return "rolled-back"
  default: return "failed"
  }
}

struct Progress: Equatable { let n: Int, of: Int, text: String }

/// What failed in a job (apply's and update's {"omacvm_failed": 1, "part",
/// "text", "side"} line; side "mac" for a Mac helper, else "vm").
struct Failed: Equatable {
  let part: String, text: String, side: String
  init(part: String, text: String, side: String = "vm") { self.part = part; self.text = text; self.side = side }
}

/// The CLI's progress lines (OMACVM_PROGRESS=json: {"omacvm_progress": 1,
/// "step", "n", "of", "text"}) and failure lines: the last of each, and the
/// other lines without them.
func progress(_ lines: [String]) -> (Progress?, [String], Failed?) {
  var last: Progress?, failed: Failed?, rest: [String] = []
  for l in lines {
    if l.hasPrefix("{\"omacvm_progress\""), let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
       let n = o["n"] as? Int, let of = o["of"] as? Int, let t = o["text"] as? String,
       (0...99).contains(n), (0...99).contains(of) {
      last = Progress(n: n, of: max(of, n), text: String(t.prefix(120)))
    } else if l.hasPrefix("{\"omacvm_failed\""), let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any],
              let t = o["text"] as? String {
      let p = o["part"] as? String ?? ""
      failed = Failed(part: validFeatureName(p) ? p : "", text: String(t.prefix(160)), side: (o["side"] as? String) == "mac" ? "mac" : "vm")
    } else {
      rest.append(l)
    }
  }
  return (last, rest, failed)
}

/// With update checks off, an update installs only from a check the person
/// asked for in the last hour (never from an old cached result).
func updateGate(checksEnabled: Bool, checkedAt: Date?, now: Date = Date()) -> PolicyError? {
  if checksEnabled { return nil }
  guard let at = checkedAt, now.timeIntervalSince(at) < 3600, now >= at.addingTimeInterval(-60) else {
    return PolicyError(409, "stale-update", "update checks are off and the last result may be old: check for updates first")
  }
  return nil
}

/// One job per VM at a time, at most `jobsPerHour` per VM per hour.
struct JobLimiter {
  private var started: [String: [Date]] = [:]
  private var running: Set<String> = []

  mutating func admit(_ vm: String, now: Date = Date()) -> PolicyError? {
    if running.contains(vm) { return PolicyError(409, "busy", "a job runs for this VM: wait for it") }
    let recent = (started[vm] ?? []).filter { now.timeIntervalSince($0) < 3600 }
    started[vm] = recent
    if recent.count >= jobsPerHour { return PolicyError(429, "rate", "\(jobsPerHour) jobs in the last hour: try later") }
    started[vm] = recent + [now]
    running.insert(vm)
    return nil
  }

  mutating func finished(_ vm: String) { running.remove(vm) }
}

/// "2.9.1" -> [2, 9, 1]; nil for anything else.
func versionParts(_ v: String) -> [Int]? {
  let p = v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
  guard (1...4).contains(p.count), p.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
  return p.map { $0! }
}

/// a < b as versions (nil when either is not one).
func versionLess(_ a: String, _ b: String) -> Bool? {
  guard var x = versionParts(a), var y = versionParts(b) else { return nil }
  while x.count < y.count { x.append(0) }
  while y.count < x.count { y.append(0) }
  return x.lexicographicallyPrecedes(y)
}

/// Toggles install the Mac's copy of OmacVM into the VM, so they only run
/// when both have the same version (otherwise a toggle would update the VM in
/// passing). Update is the way out. A VM whose update went back (the Mac kept
/// the newer OmacVM) is never locked: turning a feature off and a repair still
/// run, and bring the VM to the Mac's version without that feature or with it
/// installed again. A VM newer than the Mac: the Mac is updated first.
func versionGate(_ r: JobRequest, mac: String, vm: String) -> PolicyError? {
  if r.action == .update || mac == vm { return nil }
  if versionLess(mac, vm) == true {
    return PolicyError(409, "mac-older", "this VM has OmacVM \(vm), the Mac \(mac): update the Mac first (u in the control centre)")
  }
  if r.action == .disable || r.action == .reinstall || r.action == .graphics { return nil }
  return PolicyError(409, "update-first", "the Mac has OmacVM \(mac), this VM \(vm.isEmpty ? "none" : vm): update first")
}

/// An update job only goes forward: never to a release older than the Mac's
/// OmacVM, and only when it brings this VM something newer.
func forwardGate(release: String, mac: String, vm: String) -> PolicyError? {
  guard versionLess(release, mac) == false else {
    return PolicyError(409, "not-newer", "the Mac has OmacVM \(mac), newer than the release \(release): nothing to install")
  }
  if versionLess(release, vm) == true {
    return PolicyError(409, "not-newer", "this VM has OmacVM \(vm), newer than the release \(release): nothing to install")
  }
  if versionLess(mac, release) == false && versionLess(vm, release) == false {
    return PolicyError(409, "not-newer", "the Mac and this VM have OmacVM \(release) already")
  }
  return nil
}

/// The Mac's omacvm is OmacVM.app's own copy (no checkout): the app updates
/// it, never `omacvm update`.
func cliIsAppCopy(_ cli: String, hasGit: Bool) -> Bool {
  cli.hasSuffix(".app/Contents/Resources/omacvm/omacvm") && !hasGit
}

/// POST /omacvm/app-update: the Bridge only says yes; OmacVM.app (which relays
/// the request) checks its own signed feed and updates itself. Only for the
/// app's own VMs, only when the Mac's omacvm is the app's copy, only forward.
func appUpdateGate(viaApp: Bool, vmType: String, macAppCopy: Bool, release: String?, mac: String) -> PolicyError? {
  guard viaApp, vmType == "app" else {
    return PolicyError(409, "not-app", "the Mac updates OmacVM.app only for its own VMs: update it on the Mac")
  }
  guard macAppCopy else {
    return PolicyError(409, "not-app-copy", "this Mac has an OmacVM checkout: u updates the Mac and this VM as usual")
  }
  guard let release else {
    return PolicyError(409, "no-update", "no verified update on the Mac: check for updates first")
  }
  guard versionLess(mac, release) == true else {
    return PolicyError(409, "not-newer", "OmacVM.app has \(mac), the release \(release): nothing newer")
  }
  return nil
}

/// The manifest's fields that are used, checked after its signature.
struct Manifest: Equatable {
  let version: String, commit: String, date: String, notesURL: String, proto: Int, protoMin: Int
  let parts: [String: [String: String]]   // name -> digest, release, note
  /// The Developer ID teams of the release (required, as in OmacVM.app's feed).
  let teams: [String]
}

/// The Developer ID teams a signed document allows: 1 to 4 distinct Apple
/// team IDs. Missing, empty or anything else: nil, and the document is refused.
func devidTeams(_ v: Any?) -> [String]? {
  guard let a = v as? [Any], (1...4).contains(a.count) else { return nil }
  var out: [String] = []
  for t in a {
    guard let s = t as? String, s.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil, !out.contains(s) else { return nil }
    out.append(s)
  }
  return out
}

func parseManifest(_ data: Data) -> Result<Manifest, PolicyError> {
  func bad(_ m: String) -> Result<Manifest, PolicyError> { .failure(PolicyError(502, "bad-manifest", m)) }
  guard data.count <= 256 << 10, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return bad("not JSON") }
  guard (o["schema"] as? Int) == 1 else { return bad("unknown schema") }
  // One release key signs this feed and OmacVM.app's (kind "app-feed"): a
  // signed document of the other kind is no manifest.
  guard (o["kind"] as? String) == "control-manifest" else { return bad("not a control centre manifest") }
  guard let v = o["version"] as? String, v.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,6}$"#, options: .regularExpression) != nil else { return bad("version") }
  guard let c = o["commit"] as? String, c.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return bad("commit") }
  let date = (o["date"] as? String).flatMap { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? $0 : nil } ?? ""
  let notes = (o["notes_url"] as? String).flatMap { $0.hasPrefix("https://github.com/gillesgoetsch/omacvm/") && $0.count < 200 ? $0 : nil } ?? ""
  guard let raw = o["parts"] as? [String: Any], raw.count <= 64 else { return bad("parts") }
  var parts: [String: [String: String]] = [:]
  for (name, value) in raw {
    guard validFeatureName(name), let p = value as? [String: Any],
          let d = p["digest"] as? String, d.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil,
          let r = p["release"] as? String, r.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,6}$"#, options: .regularExpression) != nil else {
      return bad("part '\(name.prefix(32))'")
    }
    var entry = ["digest": d, "release": r]
    if let n = p["note"] as? String { entry["note"] = String(n.prefix(120)).filter { !$0.isNewline } }
    parts[name] = entry
  }
  guard let teams = devidTeams(o["devid_teams"]) else { return bad("no Developer ID teams") }
  if let k = o["next_spare_key"] { guard let s = k as? String, ReleaseKeys.key(s) != nil else { return bad("next_spare_key") } }
  if let r = o["revoked_keys"], ReleaseKeys.revokedKeys(r) == nil { return bad("revoked_keys") }
  return .success(Manifest(version: v, commit: c, date: date, notesURL: notes,
                           proto: o["proto"] as? Int ?? 1, protoMin: o["proto_min"] as? Int ?? 1, parts: parts, teams: teams))
}

/// The manifest's Ed25519 signature (base64 in the .sig file) under a
/// trusted release key. Checked before any field of the manifest is read.
func manifestSigned(_ data: Data, sig: Data, keys: ReleaseKeys) -> Bool {
  ReleaseKeys.signed(data, sig, by: keys.trusted())
}

/// OmacVM's release keys (docs/release-keys.md), as OmacVM.app reads them
/// (app/app/Sources/OmacVMUpdate/ReleaseKeys.swift, the same rules and the
/// same folder): the main and the spare public key from the checkout's
/// src/lib, either one valid, plus a spare a signed document named
/// ("next_spare_key"), minus named keys a document signed by a shipped key
/// revoked ("revoked_keys"). Such documents are kept with their signature in
/// ~/Library/Application Support/omacvm/release-keys, never as a bare key,
/// so a file written there by another process adds nothing.
struct ReleaseKeys {
  let shipped: [String]
  let store: URL?
  static let kinds: Set<String> = ["app-feed", "control-manifest", "prebuilt-manifest"]
  static let maxKept = 8, maxHeld = 16, maxRevoked = 8, maxDocumentBytes = 256 << 10

  static func key(_ b64: String) -> Curve25519.Signing.PublicKey? {
    guard let d = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == 32 else { return nil }
    return try? Curve25519.Signing.PublicKey(rawRepresentation: d)
  }

  static func signatureBytes(_ sig: Data) -> Data? {
    guard let s = Data(base64Encoded: String(decoding: sig, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          s.count == 64 else { return nil }
    return s
  }

  static func signed(_ data: Data, _ sig: Data, by keys: [Curve25519.Signing.PublicKey]) -> Bool {
    guard let s = signatureBytes(sig) else { return false }
    return keys.contains { $0.isValidSignature(s, for: data) }
  }

  /// "revoked_keys": 1 to maxRevoked distinct keys; nil for anything else.
  static func revokedKeys(_ v: Any?) -> [Curve25519.Signing.PublicKey]? {
    guard let a = v as? [Any], (1...maxRevoked).contains(a.count) else { return nil }
    let keys = a.compactMap { ($0 as? String).flatMap(key) }
    guard keys.count == a.count, Set(keys.map(\.rawRepresentation)).count == keys.count else { return nil }
    return keys
  }

  /// A document that may change the trusted keys (names a spare, revokes
  /// keys, or both). Not verified yet.
  struct Doc {
    let data: Data, sig: Data
    let named: Curve25519.Signing.PublicKey?
    let revokes: [Curve25519.Signing.PublicKey]

    init?(_ data: Data, _ sig: Data) {
      guard data.count <= ReleaseKeys.maxDocumentBytes, sig.count <= 1024, ReleaseKeys.signatureBytes(sig) != nil,
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let kind = o["kind"] as? String, ReleaseKeys.kinds.contains(kind) else { return nil }
      named = (o["next_spare_key"] as? String).flatMap(ReleaseKeys.key)
      revokes = ReleaseKeys.revokedKeys(o["revoked_keys"]) ?? []
      guard named != nil || !revokes.isEmpty else { return nil }
      self.data = data
      self.sig = sig
    }
  }

  /// The trusted keys, the revoked ones and the documents used (indexes),
  /// as ReleaseKeys.resolve in the app: revocations only from a shipped key
  /// (used once per shipped key that signs them) and never of a shipped key; then the named spares, each signed by a
  /// trusted key that is not revoked; at most maxKept documents used, and
  /// one that does not verify uses none.
  static func resolve(shipped: [Curve25519.Signing.PublicKey], docs: [Doc])
    -> (keys: [Curve25519.Signing.PublicKey], revoked: Set<Data>, used: [Int]) {
    var known = Set<Data>(), keys: [Curve25519.Signing.PublicKey] = []
    for k in shipped where known.insert(k.rawRepresentation).inserted { keys.append(k) }
    let base = keys
    var revoked = Set<Data>(), used: [Int] = [], by: [Data: Set<Data>] = [:]
    for (i, d) in docs.enumerated() where !d.revokes.isEmpty && used.count < maxKept {
      guard let signer = base.first(where: { signed(d.data, d.sig, by: [$0]) })?.rawRepresentation else { continue }
      let new = Set(d.revokes.map(\.rawRepresentation)).subtracting(known).subtracting(by[signer, default: []])
      if !new.isEmpty { by[signer, default: []].formUnion(new); revoked.formUnion(new); used.append(i) }
    }
    var fresh = base
    var left = docs.indices.filter { docs[$0].named != nil }
    while !fresh.isEmpty && !left.isEmpty {
      var added: [Curve25519.Signing.PublicKey] = []
      for i in left where signed(docs[i].data, docs[i].sig, by: fresh) {
        left.removeAll { $0 == i }
        let k = docs[i].named!, raw = k.rawRepresentation
        guard !revoked.contains(raw), !known.contains(raw), used.contains(i) || used.count < maxKept else { continue }
        known.insert(raw)
        keys.append(k)
        added.append(k)
        if !used.contains(i) { used.append(i) }
      }
      fresh = added
    }
    return (keys, revoked, used)
  }

  /// The shipped keys plus those named by kept documents a trusted key signed, minus the revoked ones.
  func trusted() -> [Curve25519.Signing.PublicKey] {
    Self.resolve(shipped: shipped.compactMap(Self.key), docs: kept()).keys
  }

  /// Keeps a verified document that names a key not trusted yet or revokes one not revoked yet.
  @discardableResult
  func remember(_ data: Data, signature: Data) -> Bool {
    guard let store, let doc = Doc(data, signature) else { return false }
    let base = shipped.compactMap(Self.key), docs = kept()
    let before = Self.resolve(shipped: base, docs: docs), after = Self.resolve(shipped: base, docs: docs + [doc])
    let old = Set(before.keys.map(\.rawRepresentation))
    guard after.used.contains(docs.count),
          after.keys.contains(where: { !old.contains($0.rawRepresentation) }) || !after.revoked.isSubset(of: before.revoked)
            || !doc.revokes.isEmpty else { return false }
    let name = Self.fileName(data, signature)
    do {
      try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
      try signature.write(to: store.appendingPathComponent("\(name).json.sig"), options: .atomic)
      try data.write(to: store.appendingPathComponent("\(name).json"), options: .atomic)
    } catch { return false }
    return true
  }

  /// The documents in the folder that could matter, as ReleaseKeys.kept in
  /// the app: every file looked at, cheap checks first, a document held only
  /// once a key signed it and it adds a key or a revocation (at most
  /// maxHeld), the folder read again for each round of new keys. Junk,
  /// however many files, neither pushes real documents out nor fills memory.
  func kept() -> [Doc] {
    guard let store else { return [] }
    let base = shipped.compactMap(Self.key), baseRaw = Set(base.map(\.rawRepresentation))
    var held: [String: Doc] = [:], known = baseRaw, revoked = Set<Data>(), by: [Data: Set<Data>] = [:]
    var fresh = base, first = true
    while !fresh.isEmpty && held.count < Self.maxHeld {
      var added: [Curve25519.Signing.PublicKey] = []
      Self.eachDocument(in: store.path) { name, doc in
        guard held[name] == nil else { return true }
        if first, !doc.revokes.isEmpty,
           let signer = base.first(where: { Self.signed(doc.data, doc.sig, by: [$0]) })?.rawRepresentation {
          let new = Set(doc.revokes.map(\.rawRepresentation)).subtracting(baseRaw).subtracting(by[signer, default: []])
          if !new.isEmpty { by[signer, default: []].formUnion(new); revoked.formUnion(new); held[name] = doc }
        }
        if let k = doc.named, !known.contains(k.rawRepresentation), !revoked.contains(k.rawRepresentation),
           Self.signed(doc.data, doc.sig, by: fresh) {
          known.insert(k.rawRepresentation)
          added.append(k)
          held[name] = doc
        }
        return held.count < Self.maxHeld
      }
      first = false
      fresh = added.filter { !revoked.contains($0.rawRepresentation) }
    }
    return held.keys.sorted().map { held[$0]! }
  }

  /// Calls body with each document in dir (name, unverified) until it returns
  /// false; other names, non-regular or too large files and junk are skipped.
  static func eachDocument(in dir: String, _ body: (String, Doc) -> Bool) {
    guard let d = opendir(dir) else { return }
    defer { closedir(d) }
    while let e = readdir(d) {
      let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
      guard name.utf8.count == 21, name.hasSuffix(".json"),
            name.utf8.prefix(16).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let sig = readSmall(dir + "/" + name + ".sig", limit: 1024), signatureBytes(sig) != nil,
            let data = readSmall(dir + "/" + name, limit: maxDocumentBytes),
            fileName(data, sig) == name.prefix(16), let doc = Doc(data, sig) else { continue }
      if !body(name, doc) { return }
    }
  }

  /// A kept document's file name (without .json): the first 16 hex digits of
  /// SHA-256(document + signature). A cheap first check: copies and other
  /// junk under a wrong name are skipped before any signature check.
  static func fileName(_ data: Data, _ sig: Data) -> String {
      SHA256.hash(data: data + sig).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// A regular file's bytes (not a link, pipe or device), nil when larger than limit.
  static func readSmall(_ path: String, limit: Int) -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
    var out = Data(), buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let n = read(fd, &buf, buf.count)
      if n < 0 { return nil }
      if n == 0 { return out }
      out.append(contentsOf: buf[0..<n])
      if out.count > limit { return nil }
    }
  }
}

// ---- the VM list (`omacvm vms --json`) ----

/// The cached VM list and when to read it again. A known VM gets the cache at
/// once; a run starts in the background, one at a time, when the list is a
/// minute old or when a job ended (its VM changed). A VM the list does not
/// have (or not as running, set up and reachable: it may have just started,
/// or the Bridge just started) gets a fresh run first, and its request waits
/// for it a few seconds (`unknownWait`) before the answer is "unknown VM".
/// Such runs at most once a second for OmacVM.app's VMs (the app names the VM)
/// and every 10 s for an address (any guest can add addresses, and each run
/// asks every running VM over SSH). Only touched on Control's queue.
struct VMListCache {
  static let maxAge: Double = 60, appEvery: Double = 1, addressEvery: Double = 10, afterFailure: Double = 10
  /// How long a request for a VM the list does not have waits for a run.
  static let unknownWait: Double = 4
  private(set) var list: [VMEntry] = []
  private(set) var at = Date.distantPast
  private(set) var running = false
  /// Runs started and runs ended (failed ones too): a request waits until
  /// `ended` reaches the run it needs.
  private(set) var started = 0, ended = 0
  private var again = false                  // a job ended (or a VM was missed) while a run was going
  private var unknownAt = Date.distantPast   // the last run asked for for an unknown VM
  private var failedAt = Date.distantPast

  static func key(_ v: VMEntry) -> String { "\(v.type)/\(v.name)" }

  private mutating func start() { running = true; started += 1 }

  /// True when this request starts a run (the caller runs it, then calls
  /// finished). `every`: how often an unknown VM may start one.
  mutating func shouldRefresh(known: Bool, now: Date, every: Double = Self.addressEvery) -> Bool {
    guard !running, now.timeIntervalSince(failedAt) >= Self.afterFailure else { return false }
    let stale = now.timeIntervalSince(at) >= Self.maxAge
    if known {
      guard stale else { return false }
    } else {
      guard stale || now.timeIntervalSince(unknownAt) >= every else { return false }
      unknownAt = now
    }
    start()
    return true
  }

  /// A request for a VM the list does not have. `start`: the caller starts a
  /// run now. `waitFor`: the run whose end the request waits for (`ended`
  /// reaching it), nil: answer from the list as it is (a run ended less than
  /// `every` ago, or the last one failed). A run already going may have
  /// started before the VM did: one more follows it, and the request waits for that.
  mutating func unknown(now: Date, every: Double) -> (start: Bool, waitFor: Int?) {
    guard now.timeIntervalSince(failedAt) >= Self.afterFailure else { return (false, nil) }
    let due = now.timeIntervalSince(unknownAt) >= every
    if running {
      guard due else { return (false, started) }
      unknownAt = now
      again = true
      return (false, started + 1)
    }
    guard due, now.timeIntervalSince(at) >= every else { return (false, nil) }
    unknownAt = now
    start()
    return (true, started)
  }

  /// A request about a VM the list has as running, but refused (the Mac
  /// cannot reach it, or OmacVM did not set it up; a VM that just started
  /// again is one until a run sees it). `start`: the caller starts a run now,
  /// at most every `refusedEvery` seconds however often a guest asks (each
  /// run probes every VM over SSH). `waitFor`: the run the request waits for
  /// (VMListCache.unknownWait at most): the one it started or the one going;
  /// nil: answered from the list at once (no run due).
  /// The first look for a VM refused this way comes after `refusedEvery`
  /// (one that just started again is found by it); when that look still
  /// could not reach it, the next ones wait 30, 60, then 120 s (`backOff`):
  /// each look probes the VM over SSH, and while its sshd turns the Mac away
  /// (PerSourcePenalties) more tries keep it that way. Per VM (`key`); a
  /// request that finds it again (`reached`) starts over.
  static let refusedEvery: Double = 5
  static let backOff: [Double] = [30, 60, 120]
  private var refusedAt: [String: Date] = [:]
  private var refusedRuns: [String: Int] = [:]
  mutating func refused(key: String, now: Date) -> (start: Bool, waitFor: Int?) {
    guard now.timeIntervalSince(failedAt) >= Self.afterFailure else { return (false, nil) }
    let n = refusedRuns[key] ?? 0
    let every = n == 0 ? Self.refusedEvery : Self.backOff[min(n - 1, Self.backOff.count - 1)]
    let last = refusedAt[key] ?? .distantPast
    // Only a run this VM's refusal started (or its first one) is waited for.
    if running { return (false, n == 0 || now.timeIntervalSince(last) < Self.unknownWait ? started : nil) }
    guard now.timeIntervalSince(last) >= every, now.timeIntervalSince(at) >= Self.refusedEvery else { return (false, nil) }
    if refusedAt.count > 64 { refusedAt.removeAll(); refusedRuns.removeAll() }   // a guest cannot grow these
    refusedAt[key] = now
    refusedRuns[key] = n + 1
    start()
    return (true, started)
  }

  /// A request found this VM in the list as it should be again: its back-off starts over.
  mutating func reached(key: String) {
    refusedAt[key] = nil
    refusedRuns[key] = nil
  }

  /// A request from a VM the list has at this address did not prove with
  /// that VM's key: the list may be old (that VM stopped, another took its
  /// address). True when the caller starts a run now: when the list is at
  /// least `mismatchAge` old, at most once a minute (any guest can send bad keys).
  static let mismatchAge: Double = 5, mismatchEvery: Double = 60
  private var mismatchAt = Date.distantPast
  mutating func keyMismatch(now: Date) -> Bool {
    guard !running, now.timeIntervalSince(failedAt) >= Self.afterFailure, now.timeIntervalSince(at) >= Self.mismatchAge,
          now.timeIntervalSince(mismatchAt) >= Self.mismatchEvery else { return false }
    mismatchAt = now
    start()
    return true
  }

  /// A job of this VM ended. `version`: the OmacVM it has now when the job
  /// worked (the Mac's), so the next request does not see the old one while
  /// the run goes. True when the caller starts a run now.
  mutating func jobEnded(vm: String, version: String?) -> Bool {
    if let version {
      list = list.map { v in
        Self.key(v) == vm ? VMEntry(name: v.name, type: v.type, state: v.state, ip: v.ip, omacvm: version, setup: v.setup, dir: v.dir,
                                     reachable: v.reachable, why: v.why) : v
      }
    }
    if running { again = true; return false }
    start()
    return true
  }

  /// A run ended (nil: it failed). Returns the VMs whose entry changed (their
  /// cached status goes) and whether the caller starts another run at once.
  mutating func finished(_ fresh: [VMEntry]?, now: Date) -> (changed: Set<String>, again: Bool) {
    running = false
    ended = started
    var changed = Set<String>()
    if let fresh {
      let old = Dictionary(list.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
      let new = Dictionary(fresh.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
      for k in Set(old.keys).union(new.keys) where old[k] != new[k] { changed.insert(k) }
      list = fresh
      at = now
    } else {
      failedAt = now
    }
    if again && fresh != nil {
      again = false
      start()
      return (changed, true)
    }
    again = false
    return (changed, false)
  }

  /// The running VM at this address, for the connection limits ("type/name").
  func vm(at peer: String) -> String? {
    let hits = list.filter { $0.state == "running" && $0.ip == peer }
    return hits.count == 1 ? Self.key(hits[0]) : nil
  }
}

// ---- refusals in the log ----

/// A refusal is logged once a minute per key (an address, a VM and the
/// reason); the next line says how many were left out. At most `maxKeys`
/// keys at a time, then the rest share one, so many addresses cannot grow
/// it or the log either.
struct LogLimiter {
  let every: Double, maxKeys: Int
  private var keys: [String: (at: Date, skipped: Int)] = [:]
  init(every: Double = 60, maxKeys: Int = 256) { self.every = every; self.maxKeys = maxKeys }

  /// nil: leave this line out. Else log it, with the count left out before it.
  mutating func admit(_ key: String, now: Date) -> Int? {
    var k = key
    if keys[k] == nil && keys.count >= maxKeys {
      // Keys whose minute is over go, also with lines left out (only their
      // count is lost): else many addresses refused twice would hold them all.
      keys = keys.filter { now.timeIntervalSince($0.value.at) < every }
      if keys.count >= maxKeys { k = "*" }
    }
    if let e = keys[k], now.timeIntervalSince(e.at) < every {
      keys[k] = (e.at, e.skipped + 1)
      return nil
    }
    let skipped = keys[k]?.skipped ?? 0
    keys[k] = (now, 0)
    return skipped
  }

  var count: Int { keys.count }
}

// ---- connections being handled ----

/// Requests being handled at once, one thread each. Every VM the Mac knows
/// (by its address in the VM list), this Mac (127.x: its programs and
/// OmacVM.app's guests) and OmacVM.app's relay (its own socket) each have
/// `reserved` places nobody else can take; past them it shares `total`
/// with everyone, at most `perKey` in all. Addresses the list does not have
/// take at most `unknownTotal` of `total` together and `perUnknown` each: a
/// guest can add any number of addresses. So a guest holding all it can (its
/// own 12 and all 16 unknown places, 24 of the 48 shared) never keeps another
/// VM or the app relay out. Threads: at most total + reserved per known VM.
/// Long requests (a wallpaper upload, a Wi-Fi password dialog) at most
/// `perKeySlow` per VM or address at once: they wait on the person or a big
/// body, and a VM must not hold its places with them.
struct ConnectionGate {
  let total: Int, perKey: Int, reserved: Int, perUnknown: Int, unknownTotal: Int, perKeySlow: Int
  private var shared = 0, unknown = 0, per: [String: Int] = [:], slow: [String: Int] = [:]
  init(total: Int = 48, perKey: Int = 12, reserved: Int = 4, perUnknown: Int = 8, unknownTotal: Int = 16, perKeySlow: Int = 2) {
    self.total = total; self.perKey = perKey; self.reserved = reserved
    self.perUnknown = perUnknown; self.unknownTotal = unknownTotal; self.perKeySlow = perKeySlow
  }

  mutating func enter(_ key: String, known: Bool) -> Bool {
    let n = per[key, default: 0]
    if known {
      guard n < perKey else { return false }
      if n >= reserved {   // past its own places: from the shared ones
        guard shared < total else { return false }
        shared += 1
      }
    } else {
      guard n < perUnknown, unknown < unknownTotal, shared < total else { return false }
      unknown += 1; shared += 1
    }
    per[key] = n + 1
    return true
  }

  /// With the same key and known as enter.
  mutating func leave(_ key: String, known: Bool) {
    let n = per[key, default: 0]
    guard n > 0 else { return }
    if !known { unknown -= 1; shared -= 1 } else if n > reserved { shared -= 1 }
    per[key] = n > 1 ? n - 1 : nil
  }

  /// A request already let in turns out to be a long one.
  mutating func enterSlow(_ key: String) -> Bool {
    let n = slow[key, default: 0]
    guard n < perKeySlow else { return false }
    slow[key] = n + 1
    return true
  }

  mutating func leaveSlow(_ key: String) {
    let n = slow[key, default: 0]
    slow[key] = n > 1 ? n - 1 : nil
  }

  var sharedInUse: Int { shared }
}

// ---- the update feed's fetch: offline or not signed ----

/// How a manifest fetch ended. The manifest came but its .sig is missing on
/// the server (404/403/410): an unsigned release, refused, not "offline".
enum FeedFetch: Equatable { case got, offline(String), unsigned }

func feedFetch(manifest: Data?, manifestError: String?, sig: Data?, sigError: String?) -> FeedFetch {
  guard manifest != nil else { return .offline(manifestError ?? "no answer") }
  if sig != nil { return .got }
  if let e = sigError, ["HTTP 404", "HTTP 403", "HTTP 410"].contains(e) { return .unsigned }
  return .offline(sigError ?? "no answer")
}
