// Media keys (stage 1c): while an OmacVM.app VM is in front (full screen or in
// a window), the volume, brightness and
// keyboard-backlight keys are swallowed (no macOS popup) and applied here
// (Shift + brightness: the keyboard backlight, as in Omarchy); every change,
// ours or not, goes out as an "osd" event so the VM can draw its own popup.
// A Mac output without a software volume (an audio interface such as a
// Scarlett 2i2), and play/pause, next and previous, go into an OmacVM.app VM
// as its own keys (vm-keys.swift). Which key goes where: MediaRoute
// (keys-model.swift). Plus the config file and the menu-bar switch.
import AppKit
import ApplicationServices

// ---- config: ~/Library/Application Support/omacvm-bridge/config.json ----
final class Config {
  let path = supportDir + "/config.json"
  var captureKeys = true       // media keys go to the VM while it is full screen
  var menuBarIcon = true
  var keyboardLowSteps = true  // keyboard light: KeyboardSteps.low below macOS's lowest step (keylight.swift)
  var externalBrightness = true  // brightness keys set the external display a VM is on (external-brightness.swift)
  var brightnessSteps = BrightnessStep.defaultSteps   // display brightness keys: 1/N per press (external-model.swift)
  var onExternalBrightness: (() -> Void)?   // external_brightness switched in the file
  private var stamp: Date?

  init() {
    guard load() else { save(); return }
    if !has("keyboard_low_steps") || !has("external_brightness") || !has("brightness_steps") { save() }   // shows the switches in the file
  }

  private var object: [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
  }

  private func has(_ key: String) -> Bool { object?[key] != nil }

  private func load() -> Bool {
    stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    guard let o = object else { return false }
    captureKeys = o["capture_keys"] as? Bool ?? captureKeys
    menuBarIcon = o["menu_bar_icon"] as? Bool ?? menuBarIcon
    keyboardLowSteps = o["keyboard_low_steps"] as? Bool ?? keyboardLowSteps
    externalBrightness = o["external_brightness"] as? Bool ?? externalBrightness
    brightnessSteps = BrightnessStep.steps((o["brightness_steps"] as? NSNumber)?.intValue ?? brightnessSteps)
    return true
  }

  /// omacvm apply switches external_brightness in the file: taken without a restart.
  func reloadIfChanged() {
    let now = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    guard now != stamp else { return }
    let was = externalBrightness, steps = brightnessSteps
    _ = load()
    if steps != brightnessSteps { log("config: brightness_steps=\(brightnessSteps)") }
    guard was != externalBrightness else { return }
    log("config: external_brightness=\(externalBrightness)")
    onExternalBrightness?()
  }

  func save() {
    // Keys this class does not know stay (touch_id_password_fallback, touchid.swift).
    var o = object ?? [:]
    let mine: [String: Any] = ["capture_keys": captureKeys, "menu_bar_icon": menuBarIcon, "keyboard_low_steps": keyboardLowSteps,
                               "external_brightness": externalBrightness, "brightness_steps": brightnessSteps]
    o.merge(mine) { _, new in new }
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
      FileManager.default.createFile(atPath: path, contents: d)
    }
    stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }
}

func percent(_ v: Float) -> Int { Int((Double(v) * 100).rounded()) }

// ---- display brightness (DisplayServices, private) ----
enum Brightness {
  private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
  private typealias Can = @convention(c) (CGDirectDisplayID) -> Bool
  private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
  private static let getFn = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
  private static let setFn = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }
  private static let canFn = dlsym(lib, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: Can.self) }

  /// The display get() and set() use (MediaRoute: whether a key on the VM's display may).
  static var displayID: CGDirectDisplayID? { display }

  /// The built-in display; on a Mac without one (or with the lid closed) the
  /// display macOS dims itself (Studio Display, LG UltraFine), the main one
  /// first. nil when there is none.
  private static var display: CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let active = Array(ids.prefix(Int(n)))
    if let d = active.first(where: { CGDisplayIsBuiltin($0) != 0 }) { return d }
    guard let canFn else { return nil }
    let main = CGMainDisplayID()
    return (active.filter { $0 == main } + active.filter { $0 != main }).first { canFn($0) }
  }

  static func get() -> Float? {
    guard let d = display else { return nil }
    return level(d)
  }

  /// Any display macOS dims itself (built-in, Apple's and LG UltraFine
  /// displays); nil for the others (DDC/CI monitors).
  static func level(_ d: CGDirectDisplayID) -> Float? {
    guard let getFn else { return nil }
    var v: Float = 0
    return getFn(d, &v) == 0 ? v : nil
  }

  static func set(_ v: Float) -> Bool {
    guard let d = display else { return false }
    return set(v, on: d)
  }

  /// One display by its id (the guest's own brightness path: server.swift).
  static func set(_ v: Float, on d: CGDirectDisplayID) -> Bool {
    guard let setFn else { return false }
    return setFn(d, max(0, min(1, v))) == 0
  }
}

// ---- "osd" events: {type, kind, value 0-100, muted, source, device} ----
// source: "keys" (caught media key), "api" (POST from the VM), "external"
// (anything else: menu bar, keys outside the VM, AirPods, auto-brightness).
final class OSDEvents {
  private let q = DispatchQueue(label: "omacvm-bridge.osd")
  private var volume: VolumeSnap?
  private var brightness: Int?
  private var brightnessQuietUntil = Date.distantPast
  private var timer: DispatchSourceTimer?
  private var polling = false

  /// The brightness poll runs only while a client asked for external events
  /// (`/events?osd=external`): nothing else uses it.
  func start() {
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(100))
    t.setEventHandler { [self] in pollBrightness() }
    timer = t   // created suspended
    hub.onExternalOSD = { on in self.poll(on) }
    q.async { self.volume = audio.outputSnap() }
  }

  private func poll(_ on: Bool) {
    q.async { [self] in
      guard on != polling, let timer else { return }
      polling = on
      if on { brightness = nil; timer.resume() } else { timer.suspend() }   // a fresh baseline: no stale jump
      log("osd: external brightness changes \(on ? "followed" : "not followed")")
    }
  }

  private func emit(_ kind: String, value: Int?, muted: Bool, source: String, device: String?) {
    hub.send("osd", ["type": "osd", "kind": kind, "value": nn(value), "muted": muted, "source": source,
                     "device": nn(device), "at": isoFormat.string(from: Date())])
  }

  /// We changed the default output's volume or mute.
  func volumeSet(kind: String, source: String) {
    q.async { [self] in
      guard let s = audio.outputSnap() else { return }
      volume = s
      emit(kind, value: s.value, muted: s.muted, source: source, device: s.name)
    }
  }

  /// CoreAudio says something changed; anything we did not set ourselves is external.
  /// Waits a moment so our own volumeSet() lands first.
  func audioChanged() {
    q.asyncAfter(deadline: .now() + 0.15) { [self] in
      let s = audio.outputSnap(), old = volume
      volume = s
      guard let s, let old, s.device == old.device else { return }   // a device switch is no popup
      if s.muted != old.muted { emit("mute", value: s.value, muted: s.muted, source: "external", device: s.name) }
      else if s.value != old.value { emit("volume", value: s.value, muted: s.muted, source: "external", device: s.name) }
    }
  }

  func brightnessSet(source: String) {
    q.async { [self] in
      guard let v = Brightness.get() else { return }
      brightness = percent(v)
      brightnessQuietUntil = Date() + 1   // the panel may ramp; that is not an external change
      emit("brightness", value: brightness, muted: false, source: source, device: "Built-in Display")
    }
  }

  /// The VM set the built-in display itself (Omarchy's slider or keys, which
  /// show their own popup): the level is noted and the poll stays quiet while
  /// the panel ramps, with no event.
  func brightnessQuiet() {
    q.async { [self] in
      if let v = Brightness.get() { brightness = percent(v) }
      brightnessQuietUntil = Date() + 1
    }
  }

  /// An external display's brightness changed (external-brightness.swift).
  func externalBrightnessSet(_ value: Int, display: String, source: String) {
    q.async { [self] in emit("brightness", value: value, muted: false, source: source, device: display) }
  }

  func keyboardSet(source: String) {
    q.async { [self] in
      emit("keyboard", value: KeyboardLight.get().map(KeyboardSteps.osdPercent), muted: false, source: source, device: "Keyboard")
    }
  }

  // No public change notification for brightness: poll, and report jumps of 2+
  // points per half second (keys, slider), not auto-brightness drift.
  private func pollBrightness() {
    guard let v = Brightness.get() else { return }
    let p = percent(v), old = brightness
    brightness = p
    if let old, abs(p - old) >= 2, Date() > brightnessQuietUntil {
      emit("brightness", value: p, muted: false, source: "external", device: "Built-in Display")
    }
  }
}

// ---- media key capture (MediaKey and the rules: keys-model.swift) ----

final class MediaKeys {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var keyTap = KeyTap()          // main thread: when the tap may exist (keys-model.swift, #192, #290)
  private let watchdog = TapWatchdog()
  private var active = true              // main thread: awake, and this session is the one in front
  private var disabledBy: String?        // main thread: what the tap's callback last heard from macOS
  private var askedAX = false
  private var createFailing = false      // main thread: a first tap could not be made (logged once)
  private var tapAtEnd = false           // main thread: the last tap was made at the end of the chain (shareKeyboard)
  private var tapOK = false              // main thread: the last "media keys: event tap|waiting|cannot" line says it works (omacvm check)
  private var slowPerms = MediaKeys.slowPermsNow()   // main thread: Input Monitoring + "control the computer", asked off it
  private var askingSlow = false         // main thread
  private var activity: NSObjectProtocol?   // main thread: no App Nap while a tap exists (#290)
  private let work = DispatchQueue(label: "omacvm-bridge.keys")
  private(set) var vmInFront = false
  private let vmKeys = VMKeys()
  private var once = OnceLog()          // main thread
  private var permissions: String?      // main thread: the last "permissions:" line
  private let brightnessKeys = BrightnessKeys()
  private var brightnessOnce = BrightnessOnce()   // main thread
  private var ownSteps = OwnSteps()               // main thread
  private var tapHold = KeyHold()                 // main thread: a held key's modifiers (the tap's repeats)

  var status: String {
    if !config.captureKeys { return "Media keys: off (macOS handles them)" }
    if !AXIsProcessTrusted() { return "Media keys: waiting for Accessibility permission" }
    if keyTap.policy.parked { return "Media keys: paused (macOS kept disabling the event tap)" }
    if tap == nil {
      return keyTap.policy.mayCreate(at: ProcessInfo.processInfo.systemUptime)
        ? "Media keys: armed (no VM in front)" : "Media keys: paused for a moment (macOS disabled the event tap)"
    }
    return vmInFront ? "Media keys: going to the VM" : "Media keys: armed (no VM in front)"
  }

  /// Logged at start and whenever one changes; omacvm check reads the last
  /// line. The media keys need Accessibility; Input Monitoring is shown too.
  private func logPermissions(_ now: TapPermissions) {
    let p = "Accessibility \(now.contains(.accessibility) ? "granted" : "MISSING"), " +
      "Input Monitoring \(now.contains(.inputMonitoring) ? "granted" : "MISSING")"
    guard p != permissions else { return }
    permissions = p
    log("permissions: \(p)")
  }

  /// AXIsProcessTrusted is answered in the process. The two CGPreflight calls
  /// ask tccd each time (about 5 ms each, longer when tccd is busy): they are
  /// asked off the main thread, which runs the tap's callback, and their last
  /// answer is used (as in the Gestures helper). A change runs check() again.
  private func permissionsNow() -> TapPermissions {
    refreshSlowPerms()
    return AXIsProcessTrusted() ? slowPerms.union(.accessibility) : slowPerms
  }

  private static func slowPermsNow() -> TapPermissions {
    var p: TapPermissions = []
    if CGPreflightListenEventAccess() { p.insert(.inputMonitoring) }
    if CGPreflightPostEventAccess() { p.insert(.postEvent) }
    return p
  }

  private func refreshSlowPerms() {
    guard !askingSlow else { return }
    askingSlow = true
    DispatchQueue.global(qos: .utility).async {
      let p = MediaKeys.slowPermsNow()
      DispatchQueue.main.async { [self] in
        askingSlow = false
        guard p != slowPerms else { return }
        slowPerms = p
        check()
      }
    }
  }

  func start() {
    brightnessKeys.onKey = { [weak self] key, mods in self?.keyboardBrightness(key, mods) }
    let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    t.tolerance = 0.5
    RunLoop.main.add(t, forMode: .common)
    // An app switch is checked at once, not up to 2 s later.
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.check() }
    // No tap while the Mac sleeps or another user's session is in front (fast
    // user switching): a tap of this session must never hold theirs (#290).
    for (name, on) in [(NSWorkspace.willSleepNotification, false), (NSWorkspace.didWakeNotification, true),
                       (NSWorkspace.sessionDidResignActiveNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, true)] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.active = on; self?.check() }
    }
    // macOS's Accessibility list changed (a permission taken away, #192, or
    // granted again): look now, and once more when it has settled.
    DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"),
                                                        object: nil, queue: .main) { [weak self] _ in
      self?.keyTap.accessibilityChanged()
      self?.check()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.check() }
    }
    check()
  }

  /// Out of the HID chain at once: disabled, its run-loop source and port gone.
  private func removeTap() {
    guard let t = tap else { return }
    watchdog.watch(nil)
    if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    CGEvent.tapEnable(tap: t, enable: false)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
    CFMachPortInvalidate(t)
    tap = nil
    source = nil
  }

  /// The tap exists only while a VM app is in front and everything it needs
  /// is there (KeyTap, keys-model.swift): Accessibility (#192), a callback
  /// that answers (#290), this session in front and awake. It is created
  /// again when an OmacVM VM comes to the front (TapRearm) or macOS
  /// invalidated it; one macOS disabled is removed, never enabled again.
  /// Main thread.
  func check() {
    config.reloadIfChanged()
    let perms = permissionsNow()
    logPermissions(perms)
    let front = NSWorkspace.shared.frontmostApplication
    let kind = VMApp.of(front)
    let uptime = ProcessInfo.processInfo.systemUptime
    // An OmacVM.app VM, also when LaunchServices names no executable for QEMU.
    let now: TapNow? = tap.map { !CFMachPortIsValid($0) ? .invalid : CGEvent.tapIsEnabled(tap: $0) ? .enabled : .disabled }
    let inputs = TapInputs(capture: config.captureKeys, vmFront: kind != nil,
                           omacvmPid: kind != nil ? front?.processIdentifier : nil,
                           active: active, perms: perms, tap: now)
    if config.captureKeys { brightnessKeys.ensure() }
    // macOS's prompt, once, as soon as it is missing (also with no VM in front).
    if config.captureKeys, !perms.contains(.accessibility), !askedAX {
      _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
      askedAX = true
      tapOK = false
      log("media keys: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > OmacVM Bridge)")
    }
    switch keyTap.check(inputs, at: uptime) {
    case .none: break
    case .remove(let why):
      removeTap()
      vmInFront = false
      switch why {
      case .permission:
        askedAX = true   // no Accessibility prompt right after the user took it away
        tapOK = false
        log("media keys: waiting for Accessibility permission (taken away: event tap removed, macOS has the media keys)")
      case .disabled, .parked:
        tapOK = false
        log("media keys: event tap removed, not enabled again: \(why.rawValue)\(disabledBy.map { " (\($0))" } ?? "")")
      case .invalid:
        tapOK = false
        log("media keys: event tap removed: \(why.rawValue)")
      case .captureOff, .notActive, .noVM: break   // every app switch: not logged
      }
      disabledBy = nil
    case .create(let why): install(again: why, perms)
    }
    // omacvm check reads the last line: with no VM in front there is no tap, and that is fine.
    // Not while a tap may not be made (a hold-off, parked, a permission): the warning stays.
    if tap == nil, !tapOK, !createFailing, config.captureKeys, keyTap.mayCreate(perms, at: uptime) {
      tapOK = true
      log("media keys: event tap armed (made while a VM is in front)")
    }
  }

  /// The tap's callback heard that macOS disabled it (main thread).
  fileprivate func macOSDisabled(_ type: CGEventType) {
    disabledBy = type == .tapDisabledByTimeout ? "timeout" : "user input"
    check()
  }

  /// The new tap goes in before the old one is removed: no gap without one.
  /// A failed re-creation keeps the old tap and is logged once.
  /// At the HID level: on macOS 27 (Mac mini, Magic Keyboard) the volume keys
  /// never reach a session-level tap, only play/next/previous do.
  private func install(again why: String?, _ perms: TapPermissions) {
    let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media/brightness/illumination keys
    // At the end of the chain with OmacVM.app's shareKeyboard (#350, keys-model.swift).
    let atEnd = ShareKeyboard.on(UserDefaults(suiteName: ShareKeyboard.domain(testIdentity: testIdentity)))
    guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: ShareKeyboard.place(atEnd), options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, _ in
      // Never enabled again here (#290); check() removes it. Not from inside its own callback.
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async { mediaKeys.macOSDisabled(type) }
        return Unmanaged.passUnretained(event)
      }
      return mediaKeys.handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }, userInfo: nil), let s = CFMachPortCreateRunLoopSource(nil, t, 0) else {
      if let why {
        if keyTap.createFailed() { tapOK = false; log("media keys: cannot create the event tap again (\(why)); keeping the old one") }
      } else {
        if !createFailing { log("media keys: cannot create the event tap although Accessibility is granted; retrying") }
        createFailing = true
        tapOK = false
      }
      return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
    if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
    tap = t
    source = s
    watchdog.watch(t)
    // A napping Bridge runs its main thread (the tap's callback) at background
    // priority, behind a busy VM: not while it holds a tap.
    if activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                       reason: "media-key event tap")
    }
    keyTap.created(perms)
    if atEnd != tapAtEnd {
      tapAtEnd = atEnd
      // Not "media keys: event tap ...": omacvm check reads those (media_keys_state).
      log("media keys: keyboard sharing (shareKeyboard) \(atEnd ? "on: the tap at the end of the chain" : "off: the tap at the head of the chain")")
    }
    createFailing = false
    if !tapOK || why != nil { tapOK = true; log(why.map { "media keys: event tap created again (\($0))" } ?? "media keys: event tap installed") }
  }

  /// The OmacVM.app VM in front (full screen or in a window) and the display it is on.
  private func frontVM(_ front: FrontWindows) -> FrontVM? {
    guard let app = front.app, VMApp.of(app) != nil, let t = VMScreens.front(front) else { return nil }
    return FrontVM(fullScreen: t.fullScreen, display: t.display.id, builtin: t.display.builtin,
                   vmKeys: vmKeys.socket(for: app.processIdentifier) != nil)
  }

  /// The VM in front, the key after Shift and Option (BrightnessCombo, as in
  /// Omarchy: Shift + brightness keys = keyboard backlight, Option = small
  /// steps) and where it goes (MediaRoute, keys-model.swift). nil: no VM in front.
  private func decide(_ pressed: MediaKey, _ mods: KeyMods, command: Bool, _ front: FrontWindows)
    -> (vm: FrontVM, key: MediaKey, route: KeyRoute, fine: Bool)? {
    let vm = frontVM(front)
    vmInFront = vm != nil
    guard let vm else { return nil }
    let (key, option) = BrightnessCombo.key(pressed, mods)
    // Only what this key needs is asked (CoreAudio, the display cache).
    let volume = key == .volumeUp || key == .volumeDown, brightness = key == .brightnessUp || key == .brightnessDown
    let route = MediaRoute.route(key, vm: vm,
                                 volumeSettable: volume && audio.outputVolumeSettable,
                                 muteSettable: key == .mute && audio.outputMuteSettable,
                                 macBrightness: brightness ? Brightness.displayID : nil,
                                 external: brightness ? externalState(vm) : .unknown,
                                 keyboardLight: [.keyboardUp, .keyboardDown, .keyboardToggle].contains(key) && KeyboardLight.get() != nil,
                                 command: command)
    return (vm, key, route, option)
  }

  /// Runs in the tap callback (main thread): true = swallow the event. Where
  /// each key goes: MediaRoute (keys-model.swift).
  func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    guard config.captureKeys, type.rawValue == 14, event.getIntegerValueField(.eventSourceUserData) != VMKeys.marker,
          let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
    let code = (ns.data1 & 0xFFFF0000) >> 16, down = (ns.data1 & 0xFF00) >> 8 == 0xA, repeating = ns.data1 & 0x1 == 1
    guard let pressed = MediaKey(rawValue: code) else { return false }
    // A held key's repeats and its key up go where its first press went (KeyHold).
    let mods = down ? tapHold.down(pressed, repeating: repeating, mods: KeyMods(event.flags))
                    : tapHold.up(pressed) ?? KeyMods(event.flags)
    let front = FrontWindows()   // one copy of the window list for every question below
    guard let d = decide(pressed, mods, command: event.flags.contains(.maskCommand), front) else { return false }   // no VM: macOS's keys
    let (vm, key, route, option) = d
    switch route {
    case .macOS(let why):
      // Never swallowed without a word: macOS gets it, and the log says why once.
      if let why, down, once.first("\(key) \(vm.display) \(why)") { log("media key \(key): to macOS: \(why)") }
      return false
    case .external, .mac:
      // The same press read from the keyboard already acted (BrightnessKeys): swallowed only.
      let brightness = pressed == .brightnessUp || pressed == .brightnessDown
      if down, brightness, !brightnessOnce.take(.tap, pressed, at: ProcessInfo.processInfo.systemUptime) { return true }
      if case .external(let id) = route {
        if down { ownSteps.stepped(id, at: ProcessInfo.processInfo.systemUptime); externalBrightness.step(id, up: key == .brightnessUp, steps: brightnessSteps(option), fine: option) }
      } else if down {
        if brightness, let id = Brightness.displayID { ownSteps.stepped(id, at: ProcessInfo.processInfo.systemUptime) }
        work.async { self.apply(key, fine: option) }   // key-up is swallowed too
      }
    case .vm(let qcode):
      guard down else { return true }
      guard let pid = front.app?.processIdentifier, let path = vmKeys.socket(for: pid) else { return false }
      if event.flags.contains(.maskCommand), once.first("command \(key)") {
        log("media key \(key) with Command: to the VM as Super + \(qcode) (Omarchy's screenshot keys), not the Mac's volume")
      }
      work.async {
        let ok = VMKeys.press(qcode, socket: path)
        DispatchQueue.main.async { self.typed(key, into: pid, ok) }
      }
    }
    return true
  }

  /// A brightness key read from the keyboard (main thread). Only while an
  /// OmacVM VM is in front, to the display the rule picks (MediaRoute);
  /// anything else is macOS's, which handles these keys itself. Shift and
  /// Option come from the keyboard too (HIDKeyboards: macOS's session does
  /// not see Shift while QEMU has the keyboard).
  private func keyboardBrightness(_ pressed: MediaKey, _ mods: KeyMods) {
    guard config.captureKeys, let d = decide(pressed, mods, command: false, FrontWindows()) else { return }
    let (vm, key, route, fine) = d
    let display: CGDirectDisplayID?
    switch route {
    case .macOS(let why):
      if let why, once.first("keyboard \(key) \(vm.display) \(why)") { log("brightness key \(key) (from the keyboard): left to macOS: \(why)") }
      return
    case .vm: return
    case .external(let id): display = id
    case .mac: display = key == .keyboardUp || key == .keyboardDown ? nil : Brightness.displayID
    }
    guard brightnessOnce.take(.keyboard, pressed, at: ProcessInfo.processInfo.systemUptime) else { return }
    if once.first("keyboard brightness") { log("brightness keys: read from the keyboard while an OmacVM VM is in front (macOS gives no key event for them)") }
    let act = { [self] in
      if case .external(let id) = route { externalBrightness.step(id, up: key == .brightnessUp, steps: brightnessSteps(fine), fine: fine) }
      else { work.async { self.apply(key, fine: fine) } }
    }
    // macOS may still handle the key itself (it reaches no tap, so it cannot be
    // swallowed): a moment later, a display macOS dims that already changed is
    // not stepped again, unless the Bridge stepped it itself meanwhile (quick
    // presses, a held key: OwnSteps), so every press steps once.
    guard let display, let before = Brightness.level(display) else { act(); return }
    let at = ProcessInfo.processInfo.systemUptime
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
      if ownSteps.macOSDidIt(display, pressAt: at, before: before, after: Brightness.level(display)) {
        if once.first("macOS brightness \(display)") { log("brightness key \(key): macOS changed display \(display) itself: not stepped again") }
        return
      }
      ownSteps.stepped(display, at: ProcessInfo.processInfo.systemUptime)
      act()
    }
  }

  /// The VM set this display's brightness itself (main thread): a key read
  /// from the keyboard that is checked meanwhile must not take the change
  /// for macOS's own and skip its step (OwnSteps).
  func vmSet(_ display: CGDirectDisplayID) {
    ownSteps.stepped(display, at: ProcessInfo.processInfo.systemUptime)
  }

  /// After a key went to the VM (main thread): the first one per VM is
  /// logged; one that did not go through goes to macOS instead.
  private func typed(_ key: MediaKey, into pid: pid_t, _ ok: Bool) {
    if ok {
      if once.first("typed \(pid)") { log("media keys: typed into the VM (pid \(pid)) through QEMU's control socket, e.g. \(key)") }
      return
    }
    if once.first("untyped \(pid)") { log("media key \(key): the VM did not take it (QEMU's control socket busy or gone): to macOS") }
    VMKeys.repost(key)
  }

  /// What is known about the VM's display when it is external (cache only:
  /// never waits; an unknown one is looked at meanwhile).
  private func externalState(_ vm: FrontVM) -> ExternalState {
    guard !vm.builtin else { return .unknown }
    guard config.externalBrightness else { return .off }
    switch externalBrightness.method(vm.display) {
    case nil: return .unknown
    case .some(let m) where m.works: return .works
    case .some(.none(let why)): return .no(why)
    default: return .unknown
    }
  }

  /// The display brightness keys' steps (config.json brightness_steps, 32 by default; Option: finer).
  private func brightnessSteps(_ fine: Bool) -> Int {
    fine ? BrightnessStep.fine(config.brightnessSteps) : config.brightnessSteps
  }

  private func apply(_ key: MediaKey, fine: Bool) {
    let steps: Float = fine ? 64 : 16   // volume, keyboard light: macOS's 16 steps, Shift+Option = quarter steps
    func step(_ v: Float, _ up: Bool) -> Float { max(0, min(1, ((v * steps).rounded() + (up ? 1 : -1)) / steps)) }
    var result = "failed"
    switch key {
    case .volumeUp, .volumeDown:
      if let r = try? audio.stepVolume(up: key == .volumeUp, steps: Double(steps)) {
        osdEvents.volumeSet(kind: "volume", source: "keys"); result = "\(r.volume)"
      }
    case .mute:
      if let r = try? audio.setMute(input: false, muted: nil) { osdEvents.volumeSet(kind: "mute", source: "keys"); result = "muted=\(r.muted)" }
    case .brightnessUp, .brightnessDown:
      let n = brightnessSteps(fine)
      if let v = Brightness.get() {
        let to = Float(BrightnessStep.next(Double(v), up: key == .brightnessUp, steps: n))
        if Brightness.set(to) { osdEvents.brightnessSet(source: "keys"); result = "\(to) (1/\(n))" }
      }
    case .keyboardUp, .keyboardDown:
      // Option: 1/64 steps as before; else macOS's 1/16 steps and the low ones below.
      let up = key == .keyboardUp
      if fine, let v = KeyboardLight.get(), KeyboardLight.set(step(v, up)) {
        osdEvents.keyboardSet(source: "keys"); result = "\(step(v, up))"
      } else if !fine, let to = KeyboardLight.step(up: up, low: config.keyboardLowSteps) {
        osdEvents.keyboardSet(source: "keys"); result = "\(to)"
      }
    case .keyboardToggle:
      if KeyboardLight.toggle() { osdEvents.keyboardSet(source: "keys"); result = "toggled" }
    case .play, .next, .previous, .fast, .rewind:
      return   // the VM's (MediaRoute), never set here
    }
    log("media key \(key)\(fine ? " (fine)" : "") -> \(result)")
  }
}

// ---- the tap's watchdog (#290) ----
// The tap's callback runs on the main thread. When that thread does not answer
// for a second (a slow call, a hang), every click and key waits behind the
// tap: this thread disables it, and check() removes it when the main thread
// is back. Should macOS not take the disable, the Bridge ends itself (launchd
// starts it again): host input goes first.
final class TapWatchdog {
  private let q = DispatchQueue(label: "omacvm-bridge.tap-watchdog", qos: .userInteractive)
  private let lock = NSLock()
  private var tap: CFMachPort?          // under lock
  private var state = TapWatch()        // under lock
  private var timer: DispatchSourceTimer?

  /// The tap to watch (main thread); nil: none, the timer stops.
  func watch(_ t: CFMachPort?) {
    lock.lock(); tap = t; state = TapWatch(); lock.unlock()
    if t != nil, timer == nil {
      let s = DispatchSource.makeTimerSource(queue: q)
      s.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
      s.setEventHandler { [weak self] in self?.tick() }
      s.resume()
      timer = s
    } else if t == nil, let s = timer {
      s.cancel()
      timer = nil
    }
  }

  private func tick() {
    lock.lock()
    guard let t = tap else { lock.unlock(); return }
    let (ping, stalled) = state.tick(at: ProcessInfo.processInfo.systemUptime)
    if stalled { tap = nil }   // once: check() removes it when the main thread is back
    lock.unlock()
    if ping {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.lock.lock(); self.state.answered(); self.lock.unlock()
      }
    }
    guard stalled else { return }
    CGEvent.tapEnable(tap: t, enable: false)
    log("media keys: the main thread did not answer for \(TapWatch.limit) s: event tap disabled (macOS passes every key and click on)")
    if CFMachPortIsValid(t), CGEvent.tapIsEnabled(tap: t) {
      log("media keys: the event tap could not be disabled: quitting so it goes (launchd starts the Bridge again)")
      _exit(75)
    }
  }
}

// ---- menu bar ----
final class MenuBar: NSObject, NSMenuDelegate {
  private var item: NSStatusItem?
  let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/omacvm-bridge.log").path

  func show() {
    let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    i.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "OmacVM Bridge")
    let menu = NSMenu()
    menu.delegate = self
    i.menu = menu
    item = i
    updateIcon()
  }

  private func updateIcon() { item?.button?.appearsDisabled = !config.captureKeys }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let capture = NSMenuItem(title: "Send Media Keys to the VM in Front", action: #selector(toggleCapture), keyEquivalent: "")
    capture.state = config.captureKeys ? .on : .off
    capture.target = self
    menu.addItem(capture)
    menu.addItem(.separator())
    func info(_ title: String, _ action: Selector? = nil) {
      let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
      m.target = self
      menu.addItem(m)
    }
    info(mediaKeys.status)
    info("Accessibility: " + (AXIsProcessTrusted() ? "granted" : "not granted…"), #selector(openAccessibility))
    info("Location Services: " + (location.authorized ? "granted" : "not granted…"), #selector(openLocation))
    info("Bluetooth: " + (bluetooth.permission == "granted" ? "granted" : "not granted…"), #selector(openBluetooth))
    for s in servers { info(s.status) }
    info("VM event clients: \(hub.clientCount)")
    menu.addItem(.separator())
    info("Open Log", #selector(openLog))
    info("Quit OmacVM Bridge", #selector(quit))
  }

  @objc private func toggleCapture() {
    config.captureKeys.toggle()
    config.save()
    log("media keys: capture \(config.captureKeys ? "ON" : "OFF") (menu)")
    updateIcon()
    mediaKeys.check()
  }

  @objc private func openAccessibility() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }

  @objc private func openLocation() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
  }

  @objc private func openBluetooth() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
  }

  @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }

  @objc private func quit() { log("quit from the menu bar (starts again at next login)"); exit(0) }
}
