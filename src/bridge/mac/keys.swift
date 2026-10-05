// Media keys (stage 1c): while the VM is full screen, the volume, brightness
// and keyboard-backlight keys are swallowed (no macOS popup) and applied here
// (Shift + brightness: the keyboard backlight, as in Omarchy); every change, ours or not, goes out as an "osd" event so the VM
// can draw its own popup. Plus the config file and the menu-bar switch.
import AppKit
import ApplicationServices

// ---- config: ~/Library/Application Support/omacvm-bridge/config.json ----
final class Config {
  let path = supportDir + "/config.json"
  var captureKeys = true       // media keys go to the VM while it is full screen
  var menuBarIcon = true
  var keyboardLowSteps = true  // keyboard light: KeyboardLight.lowSteps below macOS's lowest step

  init() {
    guard let d = FileManager.default.contents(atPath: path),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { save(); return }
    captureKeys = o["capture_keys"] as? Bool ?? captureKeys
    menuBarIcon = o["menu_bar_icon"] as? Bool ?? menuBarIcon
    keyboardLowSteps = o["keyboard_low_steps"] as? Bool ?? keyboardLowSteps
    if o["keyboard_low_steps"] == nil { save() }   // shows the switch in the file
  }

  func save() {
    let o: [String: Any] = ["capture_keys": captureKeys, "menu_bar_icon": menuBarIcon, "keyboard_low_steps": keyboardLowSteps]
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
      FileManager.default.createFile(atPath: path, contents: d)
    }
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
    guard let getFn, let d = display else { return nil }
    var v: Float = 0
    return getFn(d, &v) == 0 ? v : nil
  }

  static func set(_ v: Float) -> Bool {
    guard let setFn, let d = display else { return false }
    return setFn(d, max(0, min(1, v))) == 0
  }
}

// ---- keyboard backlight (CoreBrightness KeyboardBrightnessClient, private) ----
enum KeyboardLight {
  private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
  private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
  private typealias IsBuiltIn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
  private static let getSel = NSSelectorFromString("brightnessForKeyboard:")
  private static let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
  private static let client: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
          let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
    let c = cls.init()
    return c.responds(to: getSel) && c.responds(to: setSel) ? c : nil
  }()
  private static let keyboard: UInt64? = {
    guard let c = client,
          let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else { return nil }
    let sel = NSSelectorFromString("isKeyboardBuiltIn:")
    let builtIn = c.responds(to: sel) ? unsafeBitCast(c.method(for: sel), to: IsBuiltIn.self) : nil
    return (ids.first { builtIn?(c, sel, $0.uint64Value) ?? true } ?? ids.first)?.uint64Value
  }()
  private static var lastOn: Float = 0.5   // for the toggle key
  /// Below macOS's lowest step (1/16). Measured on a MacBook Pro M4 Max
  /// (macOS 15.7): each value is kept and lights the keys at its own level
  /// (backlightLevelForKeyboard: 0.25, 0.39, 0.68 against 1.01 at 1/16).
  /// Whether the LEDs flicker that low only a person can see:
  /// "keyboard_low_steps": false in config.json switches them off.
  static let lowSteps: [Float] = [0.01, 0.02, 0.04]

  /// The next level up or down: 0, lowSteps, then macOS's 16 steps.
  static func step(_ v: Float, up: Bool, low: Bool) -> Float {
    let levels = [0] + (low ? lowSteps : []) + (1...16).map { Float($0) / 16 }
    return up ? levels.first { $0 > v + 0.001 } ?? 1 : levels.last { $0 < v - 0.001 } ?? 0
  }

  static func get() -> Float? {
    guard let c = client, let k = keyboard else { return nil }
    let v = unsafeBitCast(c.method(for: getSel), to: Get.self)(c, getSel, k)
    return v < 0 ? nil : v
  }

  static func set(_ v: Float) -> Bool {
    guard let c = client, let k = keyboard else { return false }
    if let now = get(), now > 0 { lastOn = now }
    return unsafeBitCast(c.method(for: setSel), to: Set.self)(c, setSel, max(0, min(1, v)), k)
  }

  static func toggle() -> Bool { guard let now = get() else { return false }; return set(now > 0 ? 0 : lastOn) }
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

  func keyboardSet(source: String) {
    q.async { [self] in
      emit("keyboard", value: KeyboardLight.get().map(percent), muted: false, source: source, device: "Keyboard")
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

// ---- media key capture ----
enum MediaKey: Int {   // NX_KEYTYPE_* (IOKit/hidsystem/ev_keymap.h)
  case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
  case keyboardUp = 21, keyboardDown = 22, keyboardToggle = 23
}

final class MediaKeys {
  private var tap: CFMachPort?
  private var askedAX = false
  private let work = DispatchQueue(label: "omacvm-bridge.keys")
  private(set) var vmFullScreen = false

  var status: String {
    if !config.captureKeys { return "Media keys: off (macOS handles them)" }
    if tap == nil { return "Media keys: waiting for Accessibility permission" }
    return vmFullScreen ? "Media keys: going to the VM" : "Media keys: armed (VM not full screen)"
  }

  func start() {
    let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    t.tolerance = 0.5
    RunLoop.main.add(t, forMode: .common)
    check()
  }

  /// Creates the tap once Accessibility is granted; keeps it enabled.
  func check() {
    guard config.captureKeys else { return }
    if let tap { if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }; return }
    if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): !askedAX] as CFDictionary) {
      if !askedAX { log("media keys: waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility > OmacVM Bridge)") }
      askedAX = true
      return
    }
    let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED: media/brightness/illumination keys
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, _ in
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { mediaKeys.check() }
      return mediaKeys.handle(type, event) ? nil : Unmanaged.passUnretained(event)
    }, userInfo: nil) else {
      log("media keys: cannot create the event tap although Accessibility is granted; retrying")
      return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    tap = t
    log("media keys: event tap installed")
  }

  /// Parallels (prl_client_app), UTM, VMware Fusion or OmacVM.app is frontmost and its VM window spans a whole
  /// display (it sits below the menu bar/notch strip, so allow a gap on top).
  private func parallelsFullScreen() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication,
          ["prl_client_app", "UTM", "VMware Fusion", "OmacVM"].contains(app.executableURL?.lastPathComponent ?? ""),
          let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    let displays = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
    return wins.contains { w in
      guard w[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier, w[kCGWindowLayer as String] as? Int == 0,
            let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
      return displays.contains { abs(r.width - $0.width) < 2 && r.height >= $0.height - 80 && abs(r.minX - $0.minX) < 2 }
    }
  }

  /// Runs in the tap callback (main thread): true = swallow the event.
  func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    guard config.captureKeys, type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
    let code = (ns.data1 & 0xFFFF0000) >> 16, down = (ns.data1 & 0xFF00) >> 8 == 0xA
    guard var key = MediaKey(rawValue: code) else { return false }
    vmFullScreen = parallelsFullScreen()
    // As in Omarchy: Shift + brightness keys = keyboard backlight (a MacBook has
    // no keys of its own for it), Option + brightness keys = small steps.
    let shift = event.flags.contains(.maskShift), option = event.flags.contains(.maskAlternate)
    if shift && !option {
      if key == .brightnessUp { key = .keyboardUp } else if key == .brightnessDown { key = .keyboardDown }
    }
    guard vmFullScreen, canApply(key) else { return false }   // macOS handles it as usual
    let fine = option
    if down { work.async { self.apply(key, fine: fine) } }   // key-up is swallowed too
    return true
  }

  private func canApply(_ key: MediaKey) -> Bool {
    switch key {
    case .volumeUp, .volumeDown: audio.outputVolumeSettable
    case .mute: audio.outputMuteSettable
    case .brightnessUp, .brightnessDown: Brightness.get() != nil
    case .keyboardUp, .keyboardDown, .keyboardToggle: KeyboardLight.get() != nil
    }
  }

  private func apply(_ key: MediaKey, fine: Bool) {
    let steps: Float = fine ? 64 : 16   // macOS: 16 steps, Shift+Option = quarter steps
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
      if let v = Brightness.get(), Brightness.set(step(v, key == .brightnessUp)) {
        osdEvents.brightnessSet(source: "keys"); result = "\(step(v, key == .brightnessUp))"
      }
    case .keyboardUp, .keyboardDown:
      // Option: 1/64 steps as before; else macOS's 1/16 steps and the low ones below.
      if let v = KeyboardLight.get() {
        let to = fine ? step(v, key == .keyboardUp) : KeyboardLight.step(v, up: key == .keyboardUp, low: config.keyboardLowSteps)
        if KeyboardLight.set(to) { osdEvents.keyboardSet(source: "keys"); result = "\(to)" }
      }
    case .keyboardToggle:
      if KeyboardLight.toggle() { osdEvents.keyboardSet(source: "keys"); result = "toggled" }
    }
    log("media key \(key)\(fine ? " (fine)" : "") -> \(result)")
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
    let capture = NSMenuItem(title: "Send Media Keys to Full-Screen VM", action: #selector(toggleCapture), keyEquivalent: "")
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
    info("Camera: " + (cameraPermission() == "granted" ? "granted" : cameraPermission() == "not-determined" ? "asked when a VM first uses it" : "not granted…"), #selector(openCamera))
    info("Camera for VMs: \(camera.summary)")
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

  @objc private func openCamera() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
  }

  @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }

  @objc private func quit() { log("quit from the menu bar (starts again at next login)"); exit(0) }
}
