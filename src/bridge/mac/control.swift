// The control centre's requests on the Mac (docs/adr/0031): /omacvm/*.
// control_policy.swift decides what is allowed; this file runs it: which VM
// asked (from `omacvm vms --json`), the Mac's view of its features and checks,
// jobs (the omacvm CLI with a fixed argv, no shell, in its own session so an
// update that restarts the Bridge does not stop it), and the signed update
// feed (docs/adr/0032).
//
// Threading: requests arrive on worker threads (server.swift). Shared state
// (caches, jobs, limiter) is only touched on `q`; CLI runs and downloads
// happen outside it.
import Foundation
import IOKit

/// The test identity's Bridge (org.omacvm.test.bridge, from app/scripts/build-app.sh
/// --test-identity) keeps its own port and folders: it never meets the installed Bridge
/// or runs the installed omacvm.
let testIdentity = Bundle.main.bundleIdentifier == VMOwner.testBridge
let omacvmSupport = FileManager.default.homeDirectoryForCurrentUser.path
  + (testIdentity ? "/Library/Application Support/omacvm-test" : "/Library/Application Support/omacvm")
let jobsDir = supportDir + "/jobs"
/// OmacVM Gestures' settings (Magic Mouse swipe): the test identity's own Gestures.
let gesturesDomain = (testIdentity ? "org.omacvm.test.gestures" : "org.omacvm.gestures") as CFString
let feedDefault = "https://github.com/gillesgoetsch/omacvm/releases/latest/download/omacvm-manifest.json"

/// What a spawned CLI run gets: a fixed, small environment.
func cliEnvironment(extra: [String: String] = [:]) -> [String: String] {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  var e = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home,
           "USER": NSUserName(), "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8", "TERM": "dumb",
           "TMPDIR": NSTemporaryDirectory()]
  // The test identity's omacvm uses the test folders and helpers (src/lib/mac.sh).
  if testIdentity { e["OMACVM_TEST_IDENTITY"] = "1" }
  for (k, v) in extra { e[k] = v }
  // What a VM asks for never becomes root on the Mac, nor puts up macOS's
  // password dialog (src/net/mac/install.sh: exit 3, also when sudo needs no
  // password): the fast network's service is installed or updated when the
  // person starts the VM on the Mac (OmacVM.app asks then) or in Terminal.
  e["OMACVM_ADMIN_PROMPT"] = "none"
  return e
}

/// posix_spawn with a fixed argv: stdin /dev/null, stdout and stderr to `out`,
/// every other descriptor closed, its own session. `app`: run it through
/// OmacVM.app's executable (appRunner), which answers for it.
func spawn(_ argv: [String], env: [String: String], out: Int32, app: String? = nil) -> pid_t? {
  let argv = app.map { [$0, "--control-run"] + argv } ?? argv
  var fa: posix_spawn_file_actions_t?
  var attr: posix_spawnattr_t?
  posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
  posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
  posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_adddup2(&fa, out, 1)
  posix_spawn_file_actions_adddup2(&fa, out, 2)
  var none = sigset_t(), all = sigset_t()
  sigemptyset(&none); sigfillset(&all)
  posix_spawnattr_setsigmask(&attr, &none)
  posix_spawnattr_setsigdefault(&attr, &all)
  posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
  // The CLI answers for itself, not as part of the Bridge app: otherwise
  // macOS counts its ssh to the VM as the Bridge reaching the local network
  // (Local Network privacy) and refuses it. Terminal does the same for its
  // shells. Missing on a macOS without it: spawned as before. Through the
  // app (`app`), the app answers for it (control_policy.swift appRunnerPath).
  if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    _ = unsafeBitCast(sym, to: Disclaim.self)(&attr, 1)
  }
  let cargv = argv.map { strdup($0) } + [nil]
  let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer { cargv.forEach { free($0) }; cenv.forEach { free($0) } }
  var pid = pid_t()
  return posix_spawn(&pid, argv[0], &fa, &attr, cargv, cenv) == 0 ? pid : nil
}

/// A read-only CLI run: its output, or nil after `timeout` (then killed).
/// `app`: through OmacVM.app (appRunner).
func runCLI(_ argv: [String], timeout: Double, app: String? = nil) -> (Int32, Data)? {
  var p: [Int32] = [0, 0]
  guard pipe(&p) == 0 else { return nil }
  guard let pid = spawn(argv, env: cliEnvironment(), out: p[1], app: app) else { close(p[0]); close(p[1]); return nil }
  close(p[1])
  var data = Data(), buf = [UInt8](repeating: 0, count: 65536)
  let deadline = Date().addingTimeInterval(timeout)
  var pfd = pollfd(fd: p[0], events: Int16(POLLIN), revents: 0)
  while data.count < 4 << 20 {
    let left = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
    if left == 0 || poll(&pfd, 1, left) <= 0 { kill(-pid, SIGKILL); break }
    let n = read(p[0], &buf, buf.count)
    if n <= 0 { break }
    data.append(contentsOf: buf[0..<n])
  }
  close(p[0])
  var status: Int32 = 0
  waitpid(pid, &status, 0)
  guard Date() < deadline else { return nil }
  return ((status >> 8) & 0xff, data)
}

/// The omacvm CLI the Bridge may run: from the file src/mac/install.sh writes
/// (OMACVM_CONTROL_CLI for tests). It and the folders whose scripts it runs
/// must belong to this user and not be writable by others.
func controlCLI() -> Result<String, PolicyError> {
  let env = ProcessInfo.processInfo.environment
  let raw = env["OMACVM_CONTROL_CLI"] ?? (try? String(contentsOfFile: omacvmSupport + "/cli", encoding: .utf8)) ?? ""
  let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard path.hasPrefix("/"), !path.contains("/../") else {
    return .failure(PolicyError(503, "no-cli", "the Mac's OmacVM is not set up for the control centre: open OmacVM on the Mac once"))
  }
  let root = (path as NSString).deletingLastPathComponent
  for p in [path, root, root + "/src", root + "/src/cmd", root + "/src/lib"] {
    var st = stat()
    guard lstat(p, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o022 == 0,
          p != path || (st.st_mode & S_IFMT) == S_IFREG else {
      return .failure(PolicyError(503, "cli-unsafe", "the Mac's OmacVM at \(p) is not this user's alone: not run"))
    }
  }
  return .success(path)
}

func cliRoot(_ cli: String) -> String { (cli as NSString).deletingLastPathComponent }

/// OmacVM.app's executable that runs `cli` for its VMs (appRunnerPath), when
/// it is this user's alone like the CLI; nil: the CLI runs on its own.
func appRunner(_ cli: String) -> String? {
  let tail = "/Contents/Resources/omacvm/omacvm"
  guard cli.hasSuffix(tail) else { return nil }
  let app = String(cli.dropLast(tail.count))
  let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any]
  guard let exe = appRunnerPath(cli: cli, info: info, testIdentity: testIdentity, testApp: VMOwner.testApp) else { return nil }
  var st = stat()
  guard lstat(exe, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o022 == 0 else { return nil }
  return exe
}

func macFeatures(_ cli: String) -> [String] {
  let tsv = (try? String(contentsOfFile: cliRoot(cli) + "/src/features.tsv", encoding: .utf8)) ?? ""
  return tsv.split(separator: "\n").compactMap { line in
    let name = String(line.split(separator: "\t", maxSplits: 1).first ?? "")
    return validFeatureName(name) ? name : nil
  }
}

/// The Mac's omacvm is OmacVM.app's own copy: the app updates it.
func macIsAppCopy(_ cli: String) -> Bool {
  cliIsAppCopy(cli, hasGit: FileManager.default.fileExists(atPath: cliRoot(cli) + "/.git"))
}

func macVersion(_ cli: String) -> String {
  ((try? String(contentsOfFile: cliRoot(cli) + "/src/VERSION", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func chipName() -> String {
  var size = 0
  sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
  var b = [CChar](repeating: 0, count: max(size, 1))
  sysctlbyname("machdep.cpu.brand_string", &b, &size, nil, 0)
  return String(cString: b)
}

let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]")
/// A job's output for the VM: no colours, the Mac's home folder as ~.
func cleanLines(_ data: Data) -> [String] {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  var s = String(decoding: data, as: UTF8.self)
  s = ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
  s = s.replacingOccurrences(of: home, with: "~").replacingOccurrences(of: "\r", with: "\n")
  return s.split(separator: "\n", omittingEmptySubsequences: true).map { String($0.prefix(300)) }
}

final class JobRun {
  let id: String, vm: String, action: String, features: [String], started: Date
  var pid: pid_t
  var rc: Int32?
  init(id: String, vm: String, action: String, features: [String], started: Date, pid: pid_t) {
    self.id = id; self.vm = vm; self.action = action; self.features = features; self.started = started; self.pid = pid
  }
  var logPath: String { jobsDir + "/\(id).log" }
  var rcPath: String { jobsDir + "/\(id).rc" }
}

final class Control {
  private let q = DispatchQueue(label: "omacvm-bridge.control")
  private var limiter = JobLimiter()
  private var vms = VMListCache()
  private var status: [String: (at: Date, body: [String: Any])] = [:]
  private var statusRunning: Set<String> = []
  private var jobs: [String: JobRun] = [:]
  private var nonces = NonceStore()
  private var requests = RequestLimiter()
  private var nonceFD: Int32 = -1, nonceAppended = 0
  private var lastCheck = Date.distantPast
  /// The app ran the last VM list for the Bridge (appRunner): its status
  /// runs and jobs go through it too. False after it refused or failed
  /// (another signer, say): they run as before until a list works again.
  private var runnerOK = true
  private var timer: DispatchSourceTimer?

  func start() {
    try? FileManager.default.createDirectory(atPath: jobsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    q.sync {
      nonces.load((try? String(contentsOfFile: noncePath, encoding: .utf8)) ?? "", now: Date())
      compactNonces()
    }
    // Jobs older than a week go.
    for f in (try? FileManager.default.contentsOfDirectory(atPath: jobsDir)) ?? [] {
      let p = jobsDir + "/" + f
      if let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
         Date().timeIntervalSince(d) > 7 * 86400 { try? FileManager.default.removeItem(atPath: p) }
    }
    let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    t.schedule(deadline: .now() + 60, repeating: 6 * 3600, leeway: .seconds(60))
    t.setEventHandler { [self] in weeklyCheck() }
    t.resume()
    timer = t
  }

  // ---- entry point (server.swift) ----
  func handle(fd: Int32, peer: String, method: String, path: String, headers: [String: String], body: Data) {
    var vmName = "-"
    // Set once the VM's signature checked out: the answer is signed with its key.
    var signer: (key: String, nonce: String)?
    // Graphics memory is asked every 2 s while the control centre is open:
    // its answers are not logged (refusals still are).
    var quiet = false
    func answer(_ code: Int, _ obj: [String: Any], _ note: String = "") {
      let line = "control: \(logSafe(method)) \(logSafe(path)) from \(peer) (\(logSafe(vmName))): \(code)\(note.isEmpty ? "" : " " + logSafe(note))"
      // Refusals once a minute per address, VM and reason: a guest that
      // floods (or any guest, from addresses of its own) must not fill the
      // log the report reads.
      if code >= 400 { logRefusal("control \(peer) \(vmName) \(code) \(note)", line) } else if !quiet { log(line) }
      guard let s = signer else { return respond(fd, code, obj) }
      let data = jsonData(obj) + Data("\n".utf8)
      let sig = answerMAC(key: s.key, nonce: s.nonce, status: code, body: data)
      _ = writeAll(fd, httpHead(code, "application/json", length: data.count, extra: "X-OmacVM-Answer: \(sig)\r\n") + data)
      close(fd)
    }
    func refuse(_ e: PolicyError, _ extra: [String: Any] = [:]) {
      answer(e.status, ["error": e.message, "code": e.code].merging(extra) { a, _ in a }, e.code)
    }

    let cli: String
    switch controlCLI() { case .success(let c): cli = c; case .failure(let e): return refuse(e) }
    let known = Set(macFeatures(cli))
    let route: ControlRoute
    switch controlRoute(method: method, path: path, body: body, known: known) {
    case .success(let r): route = r
    case .failure(let e): return refuse(e)
    }
    let proto: Int
    switch negotiateProto(headers["x-omacvm-proto"]) { case .success(let p): proto = p; case .failure(let e): return refuse(e) }
    let version = macVersion(cli)
    // Graphics memory and the Magic Mouse swipe are asked while the control centre is open.
    quiet = route == .gpuMemory || route == .mouseSwipe
    // The VM list as it is for graphics memory (asked every 2 s): a new run of
    // omacvm vms only when the VM is not in it, not each minute.
    let fresh = route != .gpuMemory

    if route == .hello {
      let v = ProcessInfo.processInfo.operatingSystemVersion
      return answer(200, ["proto": proto, "proto_min": controlProtoMin, "omacvm": version,
                          "requests": ["hello", "status", "updates", "updates/check", "settings/update-checks", "jobs",
                                       "gpu-memory", "settings/mouse-swipe", "app-update", "theme"],
                          "features": known.sorted(), "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                          "chip": chipName()])
    }
    // Everything else is about the VM that asked, also the Mac-wide update
    // settings: only a VM OmacVM set up, which proves it with its own key.
    // Programs on this Mac (and OmacVM.app's guests, which all come from
    // 127.0.0.1) get hello only, except OmacVM.app relaying a request from a
    // VM's control port (relay key; the app names the VM): on the relay
    // socket (server.swift), or on 127.0.0.1 from an app older than it.
    let vm: VMEntry
    let relayed = peer == relayPeer || fromThisMac(fd, peer: peer)
    var viaApp = false
    if relayed {
      guard relayAuthorized(headers["x-omacvm-relay"]), let b64 = headers["x-omacvm-app-vm"],
            let d = Data(base64Encoded: b64), let name = String(data: d, encoding: .utf8), !name.isEmpty, name.count <= 200 else {
        return refuse(PolicyError(403, "app-vm", "OmacVM.app's VMs ask through the app's control port: update OmacVM.app"))
      }
      let ssh = routeNeedsSSH(route)
      switch vmForApp(name, vmList(cli, fresh: fresh, every: VMListCache.appEvery, key: "app/" + name, listed: { appVMListed(name, $0) }) {
                        if case .success = vmForApp(name, $0, ssh: ssh) { return true }; return false }, ssh: ssh) {
      case .success(let v): vm = v
      case .failure(let e): return refuse(lookingAgain(e), looking(e))
      }
      viaApp = true
      if let e = q.sync(execute: { requests.admit(vmKey(vm)) }) { return refuse(e) }
    } else {
      switch vmForPeer(peer, vmList(cli, fresh: fresh, key: "address " + peer, listed: { peerListed(peer, $0) }) {
                         if case .success = vmForPeer(peer, $0) { return true }; return false }) {
      case .success(let v): vm = v
      case .failure(let e): return refuse(lookingAgain(e), looking(e))
      }
      vmName = vm.name
      // Each VM's requests are limited on their own: one VM cannot crowd out another.
      if let e = q.sync(execute: { requests.admit(vmKey(vm)) }) { return refuse(e) }
      // Signed with the VM's own key, which never crosses the network.
      let key = storedVMKey(vm)
      let checked = q.sync { () -> Result<String, AuthFailure> in
        let r = verifyControlAuth(header: headers["x-omacvm-auth"], key: key, vm: vmKeyName(type: vm.type, name: vm.name),
                                  method: method, path: path, proto: headers["x-omacvm-proto"] ?? "", body: body,
                                  now: Date(), nonces: &nonces)
        keepNonces()
        return r
      }
      switch checked {
      case .success(let nonce): signer = (key!.trimmingCharacters(in: .whitespacesAndNewlines), nonce)
      case .failure(let f):
        if let n = f.nonce, let k = key { signer = (k.trimmingCharacters(in: .whitespacesAndNewlines), n) }
        if f.error.code == "vm-key" || f.error.code == "no-vm-key" {
          // The list may be old: the VM it has here stopped and this one took
          // its address. Look again (rate-limited); the VM asks again meanwhile.
          let e = keyMismatch(f.error, cli)
          return refuse(e, looking(e))
        }
        return refuse(f.error, f.macTime.map { ["mac_time": Int($0)] } ?? [:])
      }
    }
    vmName = vm.name
    switch route {
    case .updates: return answer(200, updatesAnswer(version, cli))
    case .appUpdate:
      // OmacVM.app asks this for its VM, then checks its own signed feed and
      // updates itself (it shuts the VM down cleanly first). The Bridge gates
      // as for an update job: a verified release, newer than the Mac's.
      let m = verifiedManifest()
      if let e = appUpdateGate(viaApp: viaApp, vmType: vm.type, macAppCopy: macIsAppCopy(cli), release: m?.version, mac: version) {
        return refuse(e)
      }
      let at = (lastResult()["checked_at"] as? String).flatMap { isoFormat.date(from: $0) }
      if let e = updateGate(checksEnabled: updateChecks(), checkedAt: at) { return refuse(e) }
      if runningOnDisk(vmKey(vm)) { return refuse(PolicyError(409, "busy", "a job runs for this VM: wait for it")) }
      // Counts toward the jobs per hour; nothing runs here, so it is free again at once.
      if let e = q.sync(execute: { limiter.admit(vmKey(vm)) }) { return refuse(e) }
      q.sync { limiter.finished(vmKey(vm)) }
      return answer(200, ["go": true, "release": m?.version ?? "", "mac": version], "app-update for \(vm.name)")
    case .updatesCheck:
      let wait = q.sync { () -> Double in
        let w = 60 - Date().timeIntervalSince(lastCheck)
        if w <= 0 { lastCheck = Date() }
        return w
      }
      if wait > 0 { return refuse(PolicyError(429, "rate", "checked a moment ago: try again in \(Int(wait) + 1) s")) }
      _ = checkFeed()
      return answer(200, updatesAnswer(version, cli))
    case .setUpdateChecks(let on):
      setUpdateChecks(on)
      return answer(200, updatesAnswer(version, cli), on ? "checks on" : "checks off")
    case .mouseSwipe:
      answer(200, mouseSwipeAnswer(magicMouse: magicMouseConnected(), fingers: mouseSwipeNow()))
    case .setMouseSwipe(let n):
      setMouseSwipe(n)
      answer(200, mouseSwipeAnswer(magicMouse: magicMouseConnected(), fingers: mouseSwipeNow()), "mouse swipe \(n) fingers")
    case .status:
      answer(200, statusAnswer(cli, vm, version))
    case .gpuMemory:
      guard vm.type == "app" else { return refuse(PolicyError(409, "not-app", "graphics memory is measured for OmacVM.app's VMs")) }
      // The app sends the file with the request: the Bridge does not read an external drive itself.
      let fromApp = relayed ? gpuMemoryFromApp(headers["x-omacvm-gpu-memory"]) : nil
      answer(200, gpuMemoryAnswer(fromApp ?? gpuMemoryText(vm)))
    case .theme(let b):
      // The Touch ID panel's colours: only from a VM with Touch ID on (its key on the Mac).
      guard touchIDKey(vm) != nil else { return refuse(PolicyError(403, "off", "Touch ID is off for this VM")) }
      let name = vmKeyName(type: vm.type, name: vm.name)
      if let e = touchIDThemes.admit(name, now: Date()) { return refuse(e) }
      switch parseTouchIDTheme(b) {
      case .failure(let e): return refuse(e)
      case .success(let t):
        guard touchIDThemes.save(t, for: name) else { return refuse(PolicyError(500, "not-kept", "the Mac could not keep the theme")) }
        answer(200, ["ok": true, "dark": t.dark], "theme \(t.background.hex) \(t.dark ? "dark" : "light")")
      }
    case .job(let id):
      guard let j = job(id), j.vm == vmKey(vm) else { return refuse(PolicyError(404, "not-found", "no such job")) }
      answer(200, jobAnswer(j))
    case .startJob(let r):
      if r.action == .graphics && vm.type != "app" {
        return refuse(PolicyError(409, "not-app", "Graphics is OmacVM.app's setting"))
      }
      if r.action == .notch && vm.type != "app" {
        return refuse(PolicyError(409, "not-app", "full screen including notch is OmacVM.app's setting (Omanotch fills the strip on the other routes)"))
      }
      if let e = versionGate(r, mac: version, vm: vm.omacvm) { return refuse(e) }
      var commit: String?
      if r.action == .update {
        guard let m = verifiedManifest() else {
          return refuse(PolicyError(409, "no-update", "no verified update on the Mac: check for updates first"))
        }
        let at = (lastResult()["checked_at"] as? String).flatMap { isoFormat.date(from: $0) }
        if let e = updateGate(checksEnabled: updateChecks(), checkedAt: at) { return refuse(e) }
        if let e = forwardGate(release: m.version, mac: version, vm: vm.omacvm) { return refuse(e) }
        commit = m.commit
      }
      // A job started before a Bridge restart (an update reinstalls the Bridge) still counts.
      if runningOnDisk(vmKey(vm)) { return refuse(PolicyError(409, "busy", "a job runs for this VM: wait for it")) }
      if let e = q.sync(execute: { limiter.admit(vmKey(vm)) }) { return refuse(e) }
      let argv = jobArgv(cli: cli, r, vm: vm.name, type: vm.type, commit: commit)
      guard let j = startJob(argv, vm: vm, request: r, app: appRunnerFor(cli, vm)) else {
        q.sync { limiter.finished(vmKey(vm)) }
        return refuse(PolicyError(500, "spawn", "the job did not start"))
      }
      answer(202, jobAnswer(j), "\(r.action.rawValue) \(r.features.joined(separator: " ")) job \(j.id)")
    default:
      refuse(PolicyError(404, "not-found", "not found"))
    }
  }

  // ---- nonces kept across restarts (on q) ----
  private var noncePath: String { supportDir + "/nonces" }

  /// The live nonces to a fresh file, then appended to one line per request.
  private func compactNonces() {
    if nonceFD >= 0 { close(nonceFD); nonceFD = -1 }
    let tmp = noncePath + ".new"
    let text = nonces.lines(now: Date()).map { $0 + "\n" }.joined()
    FileManager.default.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    if rename(tmp, noncePath) != 0 { log("control: nonces not kept across restarts (\(String(cString: strerror(errno))))") }
    nonceFD = open(noncePath, O_WRONLY | O_APPEND | O_CLOEXEC)
    nonceAppended = 0
  }

  private func keepNonces() {
    let new = nonces.drainNew()
    guard !new.isEmpty, nonceFD >= 0 else { return }
    let d = Data(new.map { $0 + "\n" }.joined().utf8)
    _ = d.withUnsafeBytes { write(nonceFD, $0.baseAddress, d.count) }
    nonceAppended += new.count
    if nonceAppended > 2 * nonces.perVMLimit { compactNonces() }
  }

  /// The app's executable for this VM's CLI runs, or nil (not an app VM, no
  /// runner, or it did not work for the last VM list).
  private func appRunnerFor(_ cli: String, _ vm: VMEntry) -> String? {
    guard vm.type == "app", q.sync(execute: { runnerOK }) else { return nil }
    return appRunner(cli)
  }

  // ---- which VM ----
  private func vmKey(_ v: VMEntry) -> String { VMListCache.key(v) }

  /// The control key `omacvm apply` made for this VM (lib/mac.sh
  /// vm_key_ensure): only when this user's alone.
  private func storedVMKey(_ v: VMEntry) -> String? {
    let path = omacvmSupport + "/vm-keys/" + vmKeyName(type: v.type, name: v.name)
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
          st.st_size < 256 else { return nil }
    return try? String(contentsOfFile: path, encoding: .utf8)
  }

  /// `omacvm vms --json`, cached (VMListCache). `known`: whether the list
  /// has the VM that asks; then the cache at once, and a run in the
  /// background when it is due (`fresh` false: never for its age).
  /// `listed`: the list has it as running, but it is refused (the Mac cannot
  /// reach it, or OmacVM did not set it up; one that just started again): a
  /// run at most every VMListCache.refusedEvery (a guest asking again and
  /// again never makes the Bridge probe every VM each second), waited for as
  /// below while it goes; else the cache at once. A VM
  /// it does not have (or has as not running): a fresh run first (at most
  /// once per `every` seconds), waited for up to VMListCache.unknownWait
  /// (`fresh` false: not waited for, graphics memory is asked every 2 s with
  /// a short timeout). A Bridge that just started, or a VM that just started,
  /// is found by that run instead of a minute later.
  private func vmList(_ cli: String, fresh: Bool = true, every: Double = VMListCache.addressEvery,
                      wait: Double = VMListCache.unknownWait, key: String, listed: ([VMEntry]) -> Bool,
                      known: ([VMEntry]) -> Bool) -> [VMEntry] {
    let (list, start, waitFor) = q.sync { () -> ([VMEntry], Bool, Int?) in
      if known(vms.list) {
        vms.reached(key: key)
        return (vms.list, fresh && vms.shouldRefresh(known: true, now: Date()), nil)
      }
      if listed(vms.list) { let r = vms.refused(key: key, now: Date()); return (vms.list, r.start, r.waitFor) }
      // Graphics memory (every 2 s while the control centre is open) asks no faster than an address.
      let u = vms.unknown(now: Date(), every: fresh ? every : max(every, VMListCache.addressEvery))
      return (vms.list, u.start, u.waitFor)
    }
    if start { refreshVMs(cli) }
    guard fresh, let n = waitFor else { return list }
    waitForRun(n, until: Date().addingTimeInterval(wait))
    return q.sync { vms.list }
  }

  /// Signalled when a run of the VM list ends (refreshVMs).
  private let runEnded = NSCondition()

  /// Until run `n` of the VM list ended, no run is going any more, or `deadline`.
  private func waitForRun(_ n: Int, until deadline: Date) {
    runEnded.lock(); defer { runEnded.unlock() }
    while true {
      let (ended, running) = q.sync { (vms.ended, vms.running) }
      if ended >= n || !running { return }
      if !runEnded.wait(until: deadline) { return }
    }
  }

  /// `omacvm vms --json ...`: the list, or nil.
  private func listVMs(_ argv: [String], app: String? = nil) -> [VMEntry]? {
    guard let (rc, out) = runCLI(argv, timeout: 90, app: app), rc == 0,
          let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any],
          let list = o["vms"] as? [[String: Any]] else { return nil }
    return list.map { v in
      VMEntry(name: v["name"] as? String ?? "", type: v["type"] as? String ?? "", state: v["state"] as? String ?? "",
              ip: v["ip"] as? String ?? "", omacvm: v["omacvm"] as? String ?? "",
              // Set up by OmacVM (its SSH host key is remembered), and that key answered at that address just now.
              setup: strictBool(v["setup"]) ?? false, dir: v["dir"] as? String ?? "",
              reachable: strictBool(v["reachable"]) ?? false, why: v["why"] as? String ?? "")
    }
  }

  /// One run of `omacvm vms --json` in the background (the cache says when),
  /// and one of OmacVM.app's VMs through the app at the same time (an
  /// external drive: control_policy.swift appRunnerPath).
  private func refreshVMs(_ cli: String) {
    DispatchQueue.global(qos: .utility).async { [self] in
      var all: [VMEntry]?, app: [VMEntry]?
      let runner = appRunner(cli)
      let g = DispatchGroup()
      if let runner {
        DispatchQueue.global(qos: .utility).async(group: g) { [self] in
          app = listVMs([cli, "vms", "--json", "--app-only"], app: runner)
          if app == nil { log("control: OmacVM.app's VM list through the app gave none (the Bridge's own list counts)") }
          q.sync { runnerOK = app != nil }
        }
      }
      all = listVMs([cli, "vms", "--json"])
      g.wait()
      let fresh = mergeVMLists(all: all, app: app)
      if fresh == nil { log("control: omacvm vms --json gave no list (asked again in 10 s at the earliest)") }
      let again = q.sync { () -> Bool in
        let r = vms.finished(fresh, now: Date())
        for k in r.changed { status[k] = nil }   // asked again with the VM's new state
        return r.again
      }
      runEnded.lock(); runEnded.broadcast(); runEnded.unlock()
      if again { refreshVMs(cli) }
    }
  }

  /// An unknown VM while a run is going: say it is being looked for.
  private func lookingAgain(_ e: PolicyError) -> PolicyError {
    guard e.code == "unknown-vm", q.sync(execute: { vms.running }) else { return e }
    return PolicyError(e.status, e.code, e.message + lookingText)
  }

  private let lookingText = " (the Mac is looking at its VMs again: try in a moment)"

  /// "looking": true in the answer while a run goes: the VM asks again.
  private func looking(_ e: PolicyError) -> [String: Any] {
    e.message.hasSuffix(lookingText) ? ["looking": true] : [:]
  }

  /// A key that does not match the VM the list has at this address: look
  /// again (VMListCache.keyMismatch says when); while a run goes, say so
  /// instead of sending the person to omacvm apply.
  private func keyMismatch(_ e: PolicyError, _ cli: String) -> PolicyError {
    let (start, running) = q.sync { () -> (Bool, Bool) in
      let s = vms.keyMismatch(now: Date())
      return (s, vms.running)
    }
    if start { refreshVMs(cli) }
    guard running else { return e }
    return PolicyError(e.status, e.code, "this VM's key does not match the VM the Mac had at this address" + lookingText)
  }

  /// For the connection limits (server.swift): the VM at this address, when
  /// the cache has it. Never waits for a run.
  func connectionKey(_ peer: String) -> (key: String, known: Bool) {
    if peer == relayPeer { return ("relay", true) }      // OmacVM.app's relay socket
    if peer.hasPrefix("127.") { return ("mac", true) }   // this Mac and OmacVM.app's guests (and an older app's relay)
    if let vm = q.sync(execute: { vms.vm(at: peer) }) { return ("vm " + vm, true) }
    return ("address " + peer, false)
  }

  /// Touch ID (touchid.swift): the VM that asks, found as for the control
  /// centre's requests, and its Touch ID key and checked nonce. `key` nil:
  /// the feature is off for that VM (no key on the Mac). The nonce is also
  /// given back with an error once the signature checked out, so the
  /// refusal can be signed. `asked`: the VM the app named (for the log,
  /// also when it is not found).
  func touchIDCaller(fd: Int32, peer: String, method: String, path: String, headers: [String: String], body: Data)
      -> (vm: VMEntry?, key: String?, nonce: String?, error: PolicyError?, asked: String?) {
    let vm: VMEntry
    let found: Result<VMEntry, PolicyError>
    var asked: String?
    if peer == relayPeer || fromThisMac(fd, peer: peer) {
      guard relayAuthorized(headers["x-omacvm-relay"]), let b64 = headers["x-omacvm-app-vm"],
            let d = Data(base64Encoded: b64), let name = String(data: d, encoding: .utf8), !name.isEmpty, name.count <= 200 else {
        return (nil, nil, nil, PolicyError(403, "app-vm", "OmacVM.app's VMs ask through the app's auth port"), nil)
      }
      asked = name
      // The app named it and it has a Touch ID key here: no need to wait for the VM list.
      if let v = touchIDRelayVM(name, list: q.sync(execute: { vms.list }), hasKey: { touchIDKey($0) != nil }) {
        found = .success(v)
      } else {
        let cli: String
        switch controlCLI() { case .success(let c): cli = c; case .failure(let e): return (nil, nil, nil, e, asked) }
        // Touch ID needs no SSH to the VM: one the Mac cannot reach just now still gets it.
        found = vmForApp(name, vmList(cli, every: VMListCache.appEvery, wait: touchIDListWait, key: "app/" + name, listed: { appVMListed(name, $0) }) {
          if case .success = vmForApp(name, $0, ssh: false) { return true }; return false }, ssh: false)
      }
    } else {
      let cli: String
      switch controlCLI() { case .success(let c): cli = c; case .failure(let e): return (nil, nil, nil, e, nil) }
      found = vmForPeer(peer, vmList(cli, wait: touchIDListWait, key: "address " + peer, listed: { peerListed(peer, $0) }) {
        if case .success = vmForPeer(peer, $0) { return true }; return false })
    }
    switch found { case .success(let v): vm = v; case .failure(let e): return (nil, nil, nil, lookingAgain(e), asked) }
    guard let key = touchIDKey(vm) else { return (vm, nil, nil, nil, asked) }
    let checked = q.sync { () -> Result<String, AuthFailure> in
      let r = verifyControlAuth(header: headers["x-omacvm-auth"], key: key, vm: vmKeyName(type: vm.type, name: vm.name),
                                method: method, path: path, proto: headers["x-omacvm-proto"] ?? "", body: body,
                                now: Date(), nonces: &nonces, label: touchIDRequestLabel)
      keepNonces()
      return r
    }
    switch checked {
    case .success(let n): return (vm, key, n, nil, asked)
    case .failure(let f): return (vm, key, f.nonce, f.error, asked)
    }
  }

  /// The VM's Touch ID key on the Mac (lib/mac.sh touchid_key_ensure), only
  /// when this user's alone; nil: Touch ID is off for it.
  func touchIDKey(_ vm: VMEntry) -> String? {
    let path = omacvmSupport + "/vm-keys/" + touchIDKeyName(type: vm.type, name: vm.name)
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0, st.st_size < 256,
          let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// How many VMs this Mac has set up (the dialog names the VM when more than one).
  func setUpVMCount() -> Int { q.sync { vms.list.filter { $0.setup && $0.reachable }.count } }

  /// An address the cache does not have was turned away for the limits: a
  /// VM that just started may be one, so look again (at most every 10 s).
  func unknownTurnedAway() {
    guard q.sync(execute: { vms.shouldRefresh(known: false, now: Date()) }) else { return }
    if case .success(let cli) = controlCLI() { refreshVMs(cli) } else { q.sync { _ = vms.finished(nil, now: Date()) } }
  }

  // ---- status: the Mac's view of this VM's features ----
  private func statusAnswer(_ cli: String, _ vm: VMEntry, _ version: String) -> [String: Any] {
    let key = vmKey(vm)
    if let c = q.sync(execute: { status[key] }), Date().timeIntervalSince(c.at) < 30 { return c.body }
    // One run per VM at a time; others get the last answer meanwhile.
    let mine = q.sync { () -> Bool in statusRunning.insert(key).inserted }
    guard mine else { return q.sync { status[key]?.body } ?? ["omacvm": version, "pending": true] }
    defer { _ = q.sync { statusRunning.remove(key) } }
    var feats: Any = NSNull(), checks: Any = NSNull()
    let app = appRunnerFor(cli, vm)
    let g = DispatchGroup()
    DispatchQueue.global().async(group: g) {
      if let (_, out) = runCLI([cli, "features", "--vm", vm.name, "--vm-type", vm.type, "--json"], timeout: 60, app: app),
         let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any], let f = o["features"] as? [[String: Any]] {
        // fixed: what OmacVM's record had wrong about this feature, now fixed (omacvm features --json).
        feats = f.map { ["name": $0["name"] ?? "", "on": $0["on"] ?? false, "available": $0["available"] ?? true, "reason": $0["reason"] ?? "",
                         "fixed": $0["fixed"] ?? ""] }
      }
    }
    DispatchQueue.global().async(group: g) {
      if let (_, out) = runCLI([cli, "check", "--vm", vm.name, "--vm-type", vm.type, "--json", "--mac-only"], timeout: 60, app: app),
         let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any], let c = o["checks"] as? [[String: Any]] {
        checks = c.map { c -> [String: Any] in
          var d: [String: Any] = [:]
          for k in ["status", "name", "detail", "needs_human", "feature"] { d[k] = c[k] ?? "" }
          if let s = d["detail"] as? String { d["detail"] = cleanLines(Data(s.utf8)).joined(separator: " ") }
          return d
        }
      }
    }
    var graphics: Any = NSNull()
    var notch: Any = NSNull()
    if vm.type == "app" {
      DispatchQueue.global().async(group: g) {
        // OmacVM.app's notch area (src/cmd/notch.sh, FullPanel); a Mac older than it has none.
        if let (rc, out) = runCLI([cli, "notch", "--vm", vm.name, "--vm-type", "app", "--json"], timeout: 30, app: app), rc == 0,
           let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] {
          var d: [String: Any] = [:]
          for k in ["notch", "next_start", "this_start", "mac_has_notch", "full_screen", "vm_ready"] { d[k] = o[k] ?? NSNull() }
          notch = d
        }
      }
      DispatchQueue.global().async(group: g) {
        // OmacVM.app's Graphics setting (src/cmd/graphics.sh); a Mac older than 3.0.0 has none.
        if let (rc, out) = runCLI([cli, "graphics", "--vm", vm.name, "--vm-type", "app", "--json"], timeout: 30, app: app), rc == 0,
           let o = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] {
          var d: [String: Any] = [:]
          for k in ["graphics", "next_start", "summary", "this_start", "driver_ready", "waiting_for_driver"] { d[k] = o[k] ?? NSNull() }
          graphics = d
        }
      }
    }
    g.wait()
    let body: [String: Any] = ["omacvm": version, "vm_omacvm": vm.omacvm, "type": vm.type, "features": feats,
                               "checks": checks, "graphics": graphics, "notch": notch, "checked_at": isoFormat.string(from: Date())]
    q.sync { status[key] = (Date(), body) }
    return body
  }

  // ---- graphics memory: the VM's status file, read as is ----
  /// logs/gpu-memory of an app VM: a regular file of this user, at most 4 KB
  /// (no link followed); nil when there is none.
  private func gpuMemoryText(_ vm: VMEntry) -> String? {
    guard let path = gpuMemoryFile(dir: vm.dir) else { return nil }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
          st.st_size <= off_t(gpuMemoryFileMax) else { return nil }
    var buf = [UInt8](repeating: 0, count: gpuMemoryFileMax)
    let n = read(fd, &buf, buf.count)
    guard n >= 0 else { return nil }
    return String(decoding: buf[0..<n], as: UTF8.self)
  }

  // ---- jobs ----
  private func startJob(_ argv: [String], vm: VMEntry, request r: JobRequest, app: String?) -> JobRun? {
    var b = [UInt8](repeating: 0, count: 8)
    guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { return nil }
    let id = b.map { String(format: "%02x", $0) }.joined()
    let j = JobRun(id: id, vm: vmKey(vm), action: r.action.rawValue, features: r.features, started: Date(), pid: 0)
    let fd = open(j.logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    // omacvm writes its exit code there, also when the Bridge restarts meanwhile (an update).
    guard let pid = spawn(argv, env: cliEnvironment(extra: ["OMACVM_JOB_STATUS": j.rcPath, "OMACVM_PROGRESS": "json"]),
                          out: fd, app: app) else { return nil }
    j.pid = pid
    let meta: [String: Any] = ["id": id, "vm": j.vm, "action": j.action, "features": j.features,
                               "started": isoFormat.string(from: j.started), "pid": Int(pid)]
    try? jsonData(meta).write(to: URL(fileURLWithPath: jobsDir + "/\(id).json"))
    q.sync { jobs[id] = j }
    DispatchQueue.global(qos: .utility).async { [self] in
      var st: Int32 = 0
      // The longest job is the memory-optimized kernel's build: about 10
      // minutes with 16 CPUs, over an hour with 4 (an M2 MacBook Air's VM).
      let deadline = Date().addingTimeInterval(4 * 3600)
      while waitpid(pid, &st, WNOHANG) == 0 {
        if Date() > deadline { kill(-pid, SIGTERM); sleep(5); kill(-pid, SIGKILL) }
        usleep(250_000)
      }
      let rc = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
      // A job that worked leaves the VM at the Mac's OmacVM; either way the VM list is read again.
      let now = rc == 0 ? macVersionNow() : ""
      let run = q.sync { () -> Bool in
        j.rc = rc
        limiter.finished(j.vm)
        status[j.vm] = nil   // the next status asks again
        return vms.jobEnded(vm: j.vm, version: now.isEmpty ? nil : now)
      }
      if run, case .success(let cli) = controlCLI() { refreshVMs(cli) } else if run { q.sync { _ = vms.finished(nil, now: Date()) } }
      log("control: job \(id) (\(j.action) \(j.features.joined(separator: " "))) ended \(rc)")
    }
    return j
  }

  /// A job of this VM from an earlier Bridge run that has not ended.
  private func runningOnDisk(_ vm: String) -> Bool {
    for f in (try? FileManager.default.contentsOfDirectory(atPath: jobsDir)) ?? [] where f.hasSuffix(".json") {
      let id = String(f.dropLast(5))
      guard q.sync(execute: { jobs[id] }) == nil, let j = job(id), j.vm == vm,
            !FileManager.default.fileExists(atPath: j.rcPath) else { continue }
      if j.pid > 0 && kill(j.pid, 0) == 0 { return true }
    }
    return false
  }

  /// A job from this run, or one from before a restart (its files).
  private func job(_ id: String) -> JobRun? {
    if let j = q.sync(execute: { jobs[id] }) { return j }
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: jobsDir + "/\(id).json")),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
    let j = JobRun(id: id, vm: o["vm"] as? String ?? "", action: o["action"] as? String ?? "",
                   features: o["features"] as? [String] ?? [], started: isoFormat.date(from: o["started"] as? String ?? "") ?? Date(),
                   pid: pid_t(o["pid"] as? Int ?? 0))
    return j
  }

  private func jobAnswer(_ j: JobRun) -> [String: Any] {
    let data = (try? Data(contentsOf: URL(fileURLWithPath: j.logPath))) ?? Data()
    let (step, lines, failed) = progress(cleanLines(data.suffix(65536)))
    var rc = q.sync { j.rc }
    if rc == nil, let s = try? String(contentsOfFile: j.rcPath, encoding: .utf8) { rc = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
    // The state comes from the exit code alone (4: rolled back), never from the output.
    let state = jobState(rc: rc, alive: j.pid > 0 && kill(j.pid, 0) == 0)
    let last = lines.last(where: { $0.hasPrefix("==> ") }).map { String($0.dropFirst(4)) }
    // Failed or rolled back: what failed (apply says it), else the last line.
    let text = state == "running" ? (step?.text ?? last ?? "starting")
      : state == "done" ? "done" : (failed?.text ?? lines.last ?? "failed")
    return ["id": j.id, "action": j.action, "features": j.features, "state": state, "step": step?.n ?? 0, "of": step?.of ?? 0,
            "text": text, "failed_part": failed?.part ?? "", "failed_side": failed?.side ?? "", "mac_omacvm": macVersionNow(),
            "rc": rc.map { Int($0) } ?? NSNull(), "lines": Array(lines.suffix(20))]
  }

  /// The Mac's OmacVM now (an update job moves it): the VM tells from it
  /// whether it went back to an older OmacVM than the Mac's.
  private func macVersionNow() -> String {
    guard case .success(let cli) = controlCLI() else { return "" }
    return macVersion(cli)
  }

  // ---- updates ----
  private var settingsPath: String { omacvmSupport + "/settings.json" }
  private var updatesPath: String { omacvmSupport + "/updates.json" }

  /// The one switch for update checks (off: no checks, no prompts), shared
  /// with OmacVM.app's own updates.
  func updateChecks() -> Bool {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return true }
    return strictBool(o["update_checks"]) ?? true
  }

  private func setUpdateChecks(_ on: Bool) {
    var o: [String: Any] = [:]
    if let d = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
       let old = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { o = old }
    o["update_checks"] = on
    try? FileManager.default.createDirectory(atPath: omacvmSupport, withIntermediateDirectories: true)
    try? jsonData(o).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
  }

  // ---- Magic Mouse swipe: Gestures' own setting, read at each swipe ----
  private func mouseSwipeNow() -> Int {
    CFPreferencesAppSynchronize(gesturesDomain)
    return mouseSwipeFingers(stored: CFPreferencesCopyAppValue("MouseSwipeFingers" as CFString, gesturesDomain))
  }

  private func setMouseSwipe(_ n: Int) {
    CFPreferencesSetAppValue("MouseSwipeFingers" as CFString, (n == 3 ? 3 : 4) as CFNumber, gesturesDomain)
    CFPreferencesAppSynchronize(gesturesDomain)
  }

  /// A Magic Mouse connected now (Bluetooth or USB), looked for as the app does.
  private func magicMouseConnected() -> Bool {
    for cls in ["AppleMultitouchDevice", "IOHIDDevice"] {
      var it: io_iterator_t = 0
      guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
      defer { IOObjectRelease(it) }
      while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        func num(_ k: String) -> Int? {
          (IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        if isMagicMouse(vendor: num("VendorID"), product: num("ProductID"), family: num("Family ID")) { return true }
      }
    }
    return false
  }

  private func lastResult() -> [String: Any] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: updatesPath)),
          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
    return o
  }

  /// The cached manifest, verified again (the file is only a cache).
  private func verifiedManifest() -> Manifest? {
    guard let raw = (lastResult()["raw"] as? String).flatMap({ Data(base64Encoded: $0) }),
          let sig = (lastResult()["sig"] as? String).flatMap({ Data(base64Encoded: $0) }),
          let keys = releaseKeys(), manifestSigned(raw, sig: sig, keys: keys),
          case .success(let m) = parseManifest(raw) else { return nil }
    return m
  }

  /// The main and the spare release key of the installed checkout (either
  /// one signs), or OMACVM_FEED_KEY (test keys, space-separated); plus the
  /// spares signed documents named. nil: no key at all.
  private func releaseKeys() -> ReleaseKeys? {
    let store = URL(fileURLWithPath: omacvmSupport + "/release-keys")
    if let k = ProcessInfo.processInfo.environment["OMACVM_FEED_KEY"], !k.isEmpty {
      return ReleaseKeys(shipped: k.split(separator: " ").map(String.init), store: store)
    }
    guard case .success(let cli) = controlCLI() else { return nil }
    let shipped = ["release-key.pub", "release-key-spare.pub"].compactMap {
      try? String(contentsOfFile: cliRoot(cli) + "/src/lib/" + $0, encoding: .utf8)
    }.filter { ReleaseKeys.key($0) != nil }
    return shipped.isEmpty ? nil : ReleaseKeys(shipped: shipped, store: store)
  }

  private func fetch(_ url: URL) -> (Data?, String?) {
    var result: (Data?, String?) = (nil, "no answer")
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    req.setValue("OmacVM-Bridge", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { d, r, e in
      if let e { result = (nil, e.localizedDescription) }
      else if let h = r as? HTTPURLResponse, h.statusCode != 200 { result = (nil, "HTTP \(h.statusCode)") }
      else if let d, d.count <= 256 << 10 { result = (d, nil) }
      else { result = (nil, "too large") }
      sem.signal()
    }.resume()
    sem.wait()
    return result
  }

  /// Fetch and verify the manifest; the result (good or not) is kept.
  @discardableResult
  func checkFeed() -> [String: Any] {
    let env = ProcessInfo.processInfo.environment
    let feed = env["OMACVM_FEED_URL"] ?? feedDefault
    var out: [String: Any] = ["checked_at": isoFormat.string(from: Date()), "ok": false]
    let old = lastResult()
    defer {
      try? FileManager.default.createDirectory(atPath: omacvmSupport, withIntermediateDirectories: true)
      try? jsonData(out).write(to: URL(fileURLWithPath: updatesPath), options: .atomic)
    }
    guard let keys = releaseKeys() else {
      out["error"] = "this OmacVM has no release key yet: updates come with omacvm update on the Mac"
      return out
    }
    guard let url = URL(string: feed), let sigURL = URL(string: feed + ".sig") else { out["error"] = "bad feed address"; return out }
    let (data, e1) = fetch(url)
    let (sig, e2) = data == nil ? (nil, e1) : fetch(sigURL)
    switch feedFetch(manifest: data, manifestError: e1, sig: sig, sigError: e2) {
    case .got: break
    case .unsigned:
      // The server has the manifest but no signature: refused like a bad one.
      out["error"] = "the update is not signed: not used"; out["unsigned"] = true
      log("control: update check: the manifest has no signature (\(e2 ?? "?")): refused")
      return out
    case .offline(let e):
      // Offline: the last good result stays, marked.
      out = old; out["offline"] = true; out["error"] = e
      out["tried_at"] = isoFormat.string(from: Date())
      return out
    }
    guard let data, let sig else { return out }
    guard manifestSigned(data, sig: sig, keys: keys) else { out["error"] = "the update's signature does not match: not used"; return out }
    switch parseManifest(data) {
    case .failure(let e): out["error"] = e.message
    case .success(let m):
      out["ok"] = true
      if keys.remember(data, signature: sig) { log("control: the release names a new spare release key or revokes one") }
      out["raw"] = data.base64EncodedString(); out["sig"] = sig.base64EncodedString()
      log("control: update check: \(m.version) (\(m.parts.count) parts)")
    }
    return out
  }

  private func weeklyCheck() {
    guard updateChecks() else { return }
    let at = (lastResult()["checked_at"] as? String).flatMap { isoFormat.date(from: $0) } ?? .distantPast
    if Date().timeIntervalSince(at) > 7 * 86400 { checkFeed() }
  }

  private func updatesAnswer(_ version: String, _ cli: String) -> [String: Any] {
    let r = lastResult()
    // mac_app: the Mac's omacvm is OmacVM.app's copy (the app updates it: app-update).
    var a: [String: Any] = ["checks_enabled": updateChecks(), "omacvm": version, "mac_app": macIsAppCopy(cli),
                            "checked_at": r["checked_at"] ?? NSNull(), "ok": r["ok"] ?? false,
                            "offline": r["offline"] ?? false, "unsigned": r["unsigned"] ?? false,
                            "error": r["error"] ?? NSNull(), "manifest": NSNull()]
    if let m = verifiedManifest() {
      a["manifest"] = ["version": m.version, "date": m.date, "notes_url": m.notesURL, "proto": m.proto,
                       "proto_min": m.protoMin, "parts": m.parts]
    }
    return a
  }
}
let control = Control()
