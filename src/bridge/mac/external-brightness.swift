// External display brightness (feature external-brightness): while a VM window
// is in front on an external display, the brightness keys (and Omarchy's
// brightness commands in the VM) set that display. Two ways, found per display
// at run time: DDC/CI over IOAVService on Apple Silicon (VCP 0x10, as
// MonitorControl and m1ddc do), and DisplayServices for the displays macOS
// dims itself (Studio Display, Pro Display XDR, LG UltraFine), which wins over
// DDC/CI (MethodPick). A display with neither (no
// DDC on some Macs' HDMI ports, or the display ignores it) keeps today's
// behaviour; the built-in display is never touched here.
//
// Threading: every transfer runs on one serial queue (`io`), one at a time and
// at least `gap` apart; writes are coalesced (a held key sends the latest
// level only; a key's jump of more than two steps ramps there: Ramp). The
// key path (main thread, event tap) only reads the cache under `lock` and
// queues work: it never waits for a display.
//
// Off (external_brightness false): no DDC traffic at all, not even reads: no
// look at start, after a display change or for omacvm check.
import AppKit
import IOKit

// Private API, looked up at run time: a missing symbol means no DDC, never a crash.
private typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias AVTransfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias DSCan = @convention(c) (CGDirectDisplayID) -> Bool

private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
private func sym<T>(_ lib: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
  dlsym(lib ?? rtldDefault, name).map { unsafeBitCast($0, to: T.self) }
}
private let avCreate = sym(nil, "IOAVServiceCreateWithService", AVCreate.self)
private let avWrite = sym(nil, "IOAVServiceWriteI2C", AVTransfer.self)
private let avRead = sym(nil, "IOAVServiceReadI2C", AVTransfer.self)
private let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
private let displayInfo = sym(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", DisplayInfo.self)
private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
private let dsGet = sym(displayServices, "DisplayServicesGetBrightness", DSGet.self)
private let dsSet = sym(displayServices, "DisplayServicesSetBrightness", DSSet.self)
private let dsCan = sym(displayServices, "DisplayServicesCanChangeBrightness", DSCan.self)

final class ExternalBrightness {
  enum Method: Equatable {
    case ddc, apple
    case none(String)   // why not
    var name: String { switch self { case .ddc: "ddc"; case .apple: "apple"; case .none: "none" } }
    var works: Bool { self == .ddc || self == .apple }
  }

  struct Display {
    var method: Method
    var name: String
    var max = 100          // DDC: the display's raw maximum
    var level: Double?     // 0...1, last read or written
    var readAt = Date.distantPast
    var probedAt = Date()
  }

  /// Called after a brightness key changed a display: percent 0-100, its name.
  /// (A request from the VM shows Omarchy's own popup there.)
  var onKey: ((Int, String) -> Void)?
  static let fresh = 10.0        // a level read longer ago is read again before a step
  static var retryNone = 60.0    // a display that did not answer is asked again after this (tests shorten it)

  private let enabled: () -> Bool
  init(enabled: @escaping () -> Bool) { self.enabled = enabled }

  private let io = DispatchQueue(label: "omacvm-bridge.external-brightness")
  private let lock = NSLock()
  private var known: [CGDirectDisplayID: Display] = [:]   // lock
  private var probing: Set<CGDirectDisplayID> = []          // lock
  private var generation = 0                                // lock: bumped by a display change
  private var services: [CGDirectDisplayID: CFTypeRef] = [:]   // io
  private var servicesLoaded = false                           // io
  private var pending: [CGDirectDisplayID: Pending] = [:]      // io: raw levels to write
  private var lastRaw: [CGDirectDisplayID: Int] = [:]          // io: the raw level last read or written
  private var flushQueued = false                              // io
  private var lastTransfer = Date.distantPast                  // io
  private var lastWrite = Date.distantPast                     // io
  private var pendingFromVM = false                            // io: a queued write the VM asked for
  private var lookCount = 0                                    // io: probes so far
  private var failures: [CGDirectDisplayID: Int] = [:]         // io

  /// A raw level on its way; `ramp`: at most this much per write (a key's), nil = in one write (the VM's).
  private struct Pending { var raw: Int; var ramp: Int? }

  private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

  /// Finds what works on each display now and after every display change (while on).
  func start() {
    CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
      if !flags.contains(.beginConfigurationFlag) { externalBrightness.displaysChanged() }
    }, nil)
    io.asyncAfter(deadline: .now() + 1) { if self.enabled() { self.probeAll() } }
  }

  /// Plugged in, unplugged, rearranged, woken, or the feature switched: forget
  /// everything, look again once the displays settled (one look per burst of
  /// callbacks), if the feature is on then.
  func displaysChanged() {
    let g: Int = locked { known = [:]; generation += 1; return generation }
    io.async {
      self.services = [:]; self.servicesLoaded = false; self.pending = [:]; self.lastRaw = [:]; self.failures = [:]
    }
    io.asyncAfter(deadline: .now() + 2) {
      if self.locked({ self.generation }) == g, self.enabled() { self.probeAll() }
    }
  }

  /// The key path: what works on this display, from the cache only. nil = not
  /// known yet (a look is queued; the key goes to macOS meanwhile).
  func method(_ id: CGDirectDisplayID) -> Method? {
    guard enabled() else { return nil }
    let (d, ask): (Display?, Bool) = locked {
      let d = known[id]
      let ask = due(d) && !probing.contains(id)
      if ask { probing.insert(id) }
      return (d, ask)
    }
    if ask { io.async { _ = self.probe(id, again: d != nil) } }
    return d?.method
  }

  /// How many times a display was looked at (each look may read it over DDC/CI): tests.
  var looks: Int { io.sync { lookCount } }

  private func due(_ d: Display?) -> Bool {
    ProbeRule.due(works: d?.method.works, probedAt: d?.probedAt ?? .distantPast, now: Date(), retry: Self.retryNone)
  }

  // ---- looking at the displays (io) ----

  private func externalIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }
  }

  private func probeAll() {
    for id in externalIDs() { _ = probe(id) }
  }

  /// `again`: a look after one that found nothing; an AV service missing then
  /// may be there now, so the services are loaded again.
  @discardableResult
  private func probe(_ id: CGDirectDisplayID, again: Bool = false) -> Display {
    defer { locked { _ = probing.remove(id) } }
    lookCount += 1
    if !servicesLoaded || (again && services[id] == nil) { loadServices() }
    let name = displayName(id)
    var d: Display
    let info = displayInfo?(id)?.takeRetainedValue() as? [String: Any]
    let builtin = CGDisplayIsBuiltin(id) != 0
    let virtual = info?["kCGDisplayIsVirtualDevice"] as? Bool == true || info?["kCGDisplayIsAirPlay"] as? Bool == true
    let can = !builtin && !virtual && dsCan?(id) == true
    let native = can ? appleLevel(id) : nil
    switch MethodPick.choose(builtin: builtin, virtual: virtual, nativeCan: can, nativeReads: native != nil,
                             hasService: services[id] != nil, ioav: avCreate != nil && avRead != nil && avWrite != nil) {
    case .builtin: d = Display(method: .none(NotSettable.builtin), name: name)
    case .virtual: d = Display(method: .none(NotSettable.virtual), name: name)
    case .native: d = Display(method: .apple, name: name, level: native, readAt: Date())
    case .ddc:
      if let av = services[id], let (cur, max) = ddcRead(av) {
        lastRaw[id] = cur
        d = Display(method: .ddc, name: name, max: max, level: BrightnessStep.level(cur, max: max), readAt: Date())
      } else {
        d = Display(method: .none(NotSettable.noAnswer), name: name)
      }
    case .noIOAV: d = Display(method: .none(NotSettable.noIOAV), name: name)
    case .noService: d = Display(method: .none(NotSettable.noService), name: name)
    }
    let before: Method? = locked { let b = known[id]?.method; known[id] = d; return b }
    if before != d.method {
      let level = d.level.map { " at \(BrightnessStep.percent($0)) %" } ?? ""
      if case .none(let why) = d.method { log("external brightness: \(name): no (\(why))") }
      else { log("external brightness: \(name) (display \(id)) over \(d.method == .ddc ? "DDC/CI" : "DisplayServices")\(level)") }
    }
    return d
  }

  private func appleLevel(_ id: CGDirectDisplayID) -> Double? {
    var v: Float = 0
    guard let dsGet, dsGet(id, &v) == 0 else { return nil }
    return Double(v)
  }

  private func displayName(_ id: CGDirectDisplayID) -> String {
    if let info = displayInfo?(id)?.takeRetainedValue() as? [String: Any],
       let names = info["DisplayProductName"] as? [String: String],
       let n = names["en_US"] ?? names.values.first, !n.isEmpty { return n }
    return "display \(id)"
  }

  /// The external AV services, matched to the displays. Each one follows its
  /// framebuffer (IOMobileFramebufferShim, AppleCLCD2 on older macOS) in the
  /// IOService plane; the framebuffer's path is the display's
  /// IODisplayLocation (CoreDisplay), else vendor, model and serial match.
  private func loadServices() {
    services = [:]; servicesLoaded = true
    guard let avCreate else { return }
    struct Found { let path: String; let vendor: Int?; let model: Int?; let serial: Int?; let av: CFTypeRef }
    var found: [Found] = []
    var it = io_iterator_t()
    guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(it) }
    var fb: (path: String, vendor: Int?, model: Int?, serial: Int?)?
    while case let s = IOIteratorNext(it), s != 0 {
      defer { IOObjectRelease(s) }
      var cls = [CChar](repeating: 0, count: 128)
      IOObjectGetClass(s, &cls)
      switch String(cString: cls) {
      case "IOMobileFramebufferShim", "AppleCLCD2":
        var p = [CChar](repeating: 0, count: 1024)
        IORegistryEntryGetPath(s, kIOServicePlane, &p)
        let attrs = IORegistryEntryCreateCFProperty(s, "DisplayAttributes" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any]
        let pa = attrs?["ProductAttributes"] as? [String: Any]
        fb = (String(cString: p), (pa?["LegacyManufacturerID"] as? NSNumber)?.intValue,
              (pa?["ProductID"] as? NSNumber)?.intValue, (pa?["SerialNumber"] as? NSNumber)?.intValue)
      case "DCPAVServiceProxy":
        let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, nil, 0)?.takeRetainedValue() as? String
        if loc == "External", let f = fb, let av = avCreate(kCFAllocatorDefault, s)?.takeRetainedValue() {
          found.append(Found(path: f.path, vendor: f.vendor, model: f.model, serial: f.serial, av: av))
        }
        fb = nil
      default: break
      }
    }
    for id in externalIDs() {
      let info = displayInfo?(id)?.takeRetainedValue() as? [String: Any]
      if let loc = info?["IODisplayLocation"] as? String, let f = found.first(where: { $0.path == loc }) {
        services[id] = f.av; continue
      }
      let same = found.filter {
        $0.vendor == Int(CGDisplayVendorNumber(id)) && $0.model == Int(CGDisplayModelNumber(id)) &&
          ($0.serial == nil || $0.serial == Int(CGDisplaySerialNumber(id)))
      }
      if same.count == 1 { services[id] = same[0].av }   // two of a kind without a location: neither
    }
  }

  // ---- DDC/CI (io) ----

  private func pace() {
    let wait = WritePace.gap - Date().timeIntervalSince(lastTransfer)
    if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
  }

  private func transfer(_ f: AVTransfer, _ av: CFTypeRef, _ bytes: inout [UInt8]) -> Bool {
    bytes.withUnsafeMutableBytes { f(av, DDCPacket.address, DDCPacket.subAddress, $0.baseAddress!, UInt32($0.count)) } == kIOReturnSuccess
  }

  private func ddcRead(_ av: CFTypeRef) -> (Int, Int)? {
    guard let avWrite, let avRead else { return nil }
    defer { lastTransfer = Date() }
    for _ in 0..<3 {
      pace()
      var ask = DDCPacket.get(DDCPacket.luminance)
      guard transfer(avWrite, av, &ask) else { lastTransfer = Date(); continue }
      usleep(50_000)   // the display needs a moment to answer (DDC/CI: 40 ms)
      var reply = [UInt8](repeating: 0, count: 11)
      let ok = transfer(avRead, av, &reply)
      lastTransfer = Date()
      if ok, let v = DDCPacket.parse(reply, code: DDCPacket.luminance) { return v }
    }
    return nil
  }

  private func ddcWrite(_ av: CFTypeRef, _ raw: Int) -> Bool {
    guard let avWrite else { return false }
    pace()
    var ok = false
    // Sent twice, 10 ms apart, as MonitorControl and m1ddc do: some displays miss the first.
    for i in 0..<2 {
      var p = DDCPacket.set(DDCPacket.luminance, UInt16(max(0, min(65535, raw))))
      if transfer(avWrite, av, &p) { ok = true }
      if i == 0 { usleep(10_000) }
    }
    lastTransfer = Date(); lastWrite = lastTransfer
    return ok
  }

  private func queueWrite(_ id: CGDirectDisplayID, _ raw: Int, ramp: Int?, fromVM: Bool) {
    pending[id] = Pending(raw: raw, ramp: fromVM ? nil : ramp)
    pendingFromVM = pendingFromVM || fromVM
    guard !flushQueued else { return }
    flushQueued = true
    io.asyncAfter(deadline: .now() + writeDelay()) { self.flush() }
  }

  private func writeDelay() -> Double {
    WritePace.delay(sinceTransfer: Date().timeIntervalSince(lastTransfer), sinceWrite: Date().timeIntervalSince(lastWrite),
                    fromVM: pendingFromVM)
  }

  private func flush() {
    // A key's write may be queued first, then the VM's: wait for the VM's pace.
    let wait = writeDelay()
    if wait > 0 { io.asyncAfter(deadline: .now() + wait) { self.flush() }; return }
    flushQueued = false; pendingFromVM = false
    let work = pending
    pending = [:]
    for (id, p) in work {
      guard let av = services[id] else { continue }
      let raw = p.ramp.map { Ramp.next(from: lastRaw[id], to: p.raw, limit: $0) } ?? p.raw
      if ddcWrite(av, raw) {
        failures[id] = 0; lastRaw[id] = raw
        // Not there yet: the rest after the next gap (a newer level queued meanwhile replaces it).
        if raw != p.raw { queueWrite(id, p.raw, ramp: p.ramp, fromVM: false) }
        continue
      }
      lastRaw[id] = nil   // unknown now: the next write goes straight
      failures[id, default: 0] += 1
      if failures[id] == 3 {
        log("external brightness: display \(id) stopped taking DDC/CI writes; looking again")
        locked { known[id] = nil }
      }
    }
  }

  // ---- reading and setting (io) ----

  /// What works on this display, looked at again on the same rule as the
  /// key path (never looked, or nothing found over a minute ago).
  private func entry(_ id: CGDirectDisplayID) -> Display {
    let d = locked { known[id] }
    if let d, !due(d) { return d }
    return probe(id, again: d != nil)
  }

  /// The level now: from the cache while fresh and while writes are on their way.
  private func level(_ id: CGDirectDisplayID, _ d: inout Display, maxAge: Double) -> Double? {
    if let l = d.level, pending[id] != nil || Date().timeIntervalSince(d.readAt) < maxAge { return l }
    switch d.method {
    case .apple:
      guard let v = appleLevel(id) else { return nil }
      d.level = v
    case .ddc:
      guard let av = services[id], let (cur, max) = ddcRead(av) else { return nil }
      d.max = max; d.level = BrightnessStep.level(cur, max: max)
      if pending[id] == nil { lastRaw[id] = cur }
    case .none:
      return nil
    }
    d.readAt = Date()
    return d.level
  }

  private func write(_ id: CGDirectDisplayID, _ d: inout Display, _ v: Double, steps: Int = BrightnessStep.defaultSteps,
                     fromVM: Bool) -> Bool {
    switch d.method {
    case .apple:
      guard let dsSet, dsSet(id, Float(v)) == 0 else { return false }
    case .ddc:
      guard services[id] != nil else { return false }
      queueWrite(id, BrightnessStep.raw(v, max: d.max), ramp: Ramp.limit(max: d.max, steps: steps), fromVM: fromVM)
    case .none:
      return false
    }
    d.level = v; d.readAt = Date()
    return true
  }

  private func store(_ id: CGDirectDisplayID, _ d: Display) { locked { if known[id] != nil { known[id] = d } } }

  /// A brightness key (main thread): one step of 1/`steps` on that display
  /// (BrightnessStep.steps / .fine), queued.
  func step(_ id: CGDirectDisplayID, up: Bool, steps: Int, fine: Bool = false) {
    io.async {
      guard self.enabled() else { return }
      var d = self.entry(id)
      guard d.method.works else { return }
      guard let now = self.level(id, &d, maxAge: Self.fresh) else {
        self.keyFailed(d.name, "it did not answer (asleep, or the read failed)"); return
      }
      let to = BrightnessStep.next(now, up: up, steps: steps, max: d.method == .ddc ? d.max : nil)
      guard self.write(id, &d, to, steps: steps, fromVM: false) else {
        self.keyFailed(d.name, "it did not take the new level"); return
      }
      self.failedSaid.remove(d.name)
      self.store(id, d)
      self.onKey?(BrightnessStep.percent(to), d.name)
      log("media key brightness on \(d.name)\(fine ? " (fine)" : "") -> \(BrightnessStep.percent(to)) %")
    }
  }

  /// A brightness key the display did not take: said once per display (until
  /// one works again), so a held key is not a log line per press.
  private var failedSaid: Set<String> = []
  private func keyFailed(_ name: String, _ why: String) {
    if failedSaid.insert(name).inserted { log("media key brightness on \(name): failed, \(why)") }
  }

  /// The guest's request: the level now (percent), fresh (1 s) for a read.
  func get(_ id: CGDirectDisplayID) throws -> [String: Any] {
    try io.sync {
      guard enabled() else { throw APIError(409, Self.off) }
      var d = entry(id)
      guard d.method.works else { throw APIError(409, "\(d.name): \(reason(d.method))") }
      guard let v = level(id, &d, maxAge: 1) else { throw APIError(503, "\(d.name) did not answer") }
      store(id, d)
      return ["brightness": BrightnessStep.percent(v), "display": d.name, "method": d.method.name]
    }
  }

  /// The guest's request: set (percent 0-100) or move by delta (percent).
  func set(_ id: CGDirectDisplayID, percent: Double?, delta: Double?) throws -> [String: Any] {
    try io.sync {
      guard enabled() else { throw APIError(409, Self.off) }
      var d = entry(id)
      guard d.method.works else { throw APIError(409, "\(d.name): \(reason(d.method))") }
      var target = (percent ?? 0) / 100
      if let delta {
        guard let now = level(id, &d, maxAge: Self.fresh) else { throw APIError(503, "\(d.name) did not answer") }
        target = now + delta / 100
      }
      target = max(0, min(1, target))
      guard write(id, &d, target, fromVM: true) else { throw APIError(503, "\(d.name) did not take it") }
      store(id, d)
      return ["brightness": BrightnessStep.percent(target), "display": d.name, "method": d.method.name]
    }
  }

  static let off = "off on this Mac (external_brightness in the Bridge's config.json)"
  private func reason(_ m: Method) -> String { if case .none(let why) = m { return why }; return "" }

  /// Every external display and what works on it (omacvm check). Off: none,
  /// and no display is asked.
  func report() -> [[String: Any]] {
    guard enabled() else { return [] }
    return io.sync {
      externalIDs().map { id in
        var d = entry(id)
        let level = d.method.works ? self.level(id, &d, maxAge: Self.fresh) : nil
        store(id, d)
        var o: [String: Any] = ["id": Int(id), "name": d.name, "method": d.method.name,
                                "brightness": level.map { BrightnessStep.percent($0) } ?? NSNull()]
        if case .none(let why) = d.method { o["reason"] = why }
        return o
      }
    }
  }
}

// ---- which display a VM is on (main thread: window list, front app) ----

enum VMApp {
  case omacvm   // OmacVM.app's VM windows (its QEMU): also windowed
  case other    // Parallels, UTM, VMware Fusion: full screen only, as the media keys

  /// The app's executable: OmacVM.app runs each VM as Contents/Resources/runtime/bin/OmacVM
  /// (a development build as qemu-system-aarch64); its launcher has no VM windows.
  /// A VM of the other identity's app (test or normal, VMOwner) is not ours: nil.
  /// The kernel's path first: LaunchServices reports OmacVM.app's own
  /// executable for its QEMU (the app's DockIdentity, 3.0.1).
  static func of(_ app: NSRunningApplication?) -> VMApp? {
    guard let app, let exe = pidPath(app.processIdentifier) ?? app.executableURL?.path else { return nil }
    let name = (exe as NSString).lastPathComponent
    if exe.hasSuffix("/runtime/bin/OmacVM") || name == "qemu-system-aarch64" {
      return VMOwner.ours(appID: appID(exe), testBridge: testBridge) ? .omacvm : nil
    }
    return ["prl_client_app", "UTM", "VMware Fusion"].contains(name) ? .other : nil
  }

  private static let testBridge = Bundle.main.bundleIdentifier == VMOwner.testBridge
  private static var ids: [String: String] = [:]   // app path -> bundle id, under idsLock
  private static let idsLock = NSLock()   // the key tap (main thread) and the server's threads ask

  /// The bundle id of the app a VM process runs from (read once per app path).
  /// A failed read is not kept: during an update swap or before an external
  /// volume is ready, the next key press reads it again.
  private static func appID(_ exe: String) -> String? {
    guard let path = VMOwner.app(executable: exe) else { return nil }
    idsLock.lock(); defer { idsLock.unlock() }
    if let id = ids[path] { return id }
    guard let id = Bundle(path: path)?.bundleIdentifier else { return nil }
    ids[path] = id
    return id
  }
}

/// A process's executable, for an app LaunchServices names no executable for
/// (QEMU makes itself an app without a bundle).
func pidPath(_ pid: pid_t) -> String? {
  var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
}

enum VMScreens {
  static func displays() -> [MacDisplay] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).map { MacDisplay(id: $0, bounds: CGDisplayBounds($0), builtin: CGDisplayIsBuiltin($0) != 0) }
  }

  /// macOS's list of on-screen windows, front to back (a copy each call).
  static func windowList() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  }

  /// On-screen normal windows of the processes `keep` accepts, front to back.
  static func windows(_ keep: (pid_t) -> Bool) -> [CGRect] {
    windowList().compactMap { w in
      guard let pid = w[kCGWindowOwnerPID as String] as? Int32, keep(pid) else { return nil }
      return WindowList.rects([w], pid: pid).first
    }
  }

  static func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

  /// The display the VM app in front shows its VM on (keys: OmacVM.app also
  /// windowed, the others full screen; guest: windowed too). nil: no VM app in front.
  static func front(windowed guest: Bool, _ front: FrontWindows = FrontWindows()) -> (display: MacDisplay, fullScreen: Bool)? {
    guard let app = front.app, let kind = VMApp.of(app) else { return nil }
    return DisplayPick.focused(windows: front.windows, displays: displays(), pointer: pointer(),
                               windowed: guest || kind == .omacvm)
  }

  /// The display a guest output of an OmacVM.app VM is on (its layout box).
  static func forBox(_ box: CGRect) -> MacDisplay? {
    var kinds: [pid_t: Bool] = [:]
    let wins = windows { pid in
      if let k = kinds[pid] { return k }
      let k = VMApp.of(NSRunningApplication(processIdentifier: pid)) == .omacvm
      kinds[pid] = k
      return k
    }
    return DisplayPick.forBox(box, windows: wins, displays: displays())
  }
}

/// The app in front and, on first use, its windows: one copy of macOS's
/// window list per key event, shared by every question about it (main thread).
final class FrontWindows {
  let app: NSRunningApplication?
  private let copy: () -> [[String: Any]]
  init(app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication,
       copy: @escaping () -> [[String: Any]] = VMScreens.windowList) {
    self.app = app; self.copy = copy
  }
  lazy var windows: [CGRect] = app.map { WindowList.rects(copy(), pid: $0.processIdentifier) } ?? []
}
