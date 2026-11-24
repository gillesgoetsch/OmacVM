// Brightness keys read from the keyboard itself (why: keys-model.swift,
// HIDKeyboards). keys.swift's MediaKeys acts on them.
import AppKit   // NSEvent: macOS's key repeat speed
import IOKit
import IOKit.hid

// ---- brightness keys from the keyboard (HIDKeyboards: keys-model.swift) ----
// IOHIDManager on every keyboard, never seized (macOS keeps every key); needs
// Input Monitoring. Only F1-F12, fn, Shift, Option and the brightness usages
// are looked at (whether they are held, nothing else); no key is logged.
// Main thread (main run loop).
final class BrightnessKeys {
  // One manager for the Bridge's lifetime: a new IOHIDManager per try is
  // never given back by macOS (~370 KB each with 3 keyboards; at one try
  // every 2 s that was the 2.3 GB of #813).
  private var manager: IOHIDManager?
  private var isOpen = false
  private var retry = HIDOpenRetry()
  /// Seams for tests/hid: macOS's answers (the real calls by default).
  var access: () -> IOHIDAccessType = { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) }
  var open: (IOHIDManager) -> IOReturn = { IOHIDManagerOpen($0, IOOptionBits(kIOHIDOptionsTypeNone)) }
  var makeManager: (BrightnessKeys) -> IOHIDManager = { BrightnessKeys.make($0) }
  private var keyboards = HIDKeyboards()
  private var copies = HIDCopies()
  private var maps: [UInt64: [UInt32: UInt32]] = [:]   // per keyboard (registry id)
  private var ids: [Int: UInt64] = [:]                 // IOHIDDevice copy -> registry id (for its removal)
  private var said: String?
  private var asked = false
  /// A brightness key and the Shift/Option it was pressed with (a repeat:
  /// those of its first press).
  var onKey: ((MediaKey, KeyMods) -> Void)?

  // A held key repeats at macOS's key repeat speed (Keyboard settings): HID
  // sends one press and one release, no repeats. Stops on release, on another
  // brightness press, when the keyboard reads the key up (a release that never
  // came: KeyHeldCheck), on sleep, wake and the lock screen (reset), or after
  // `maxRepeats`.
  static let maxRepeats = 64
  private var held: (device: UInt64, usage: UInt32, key: MediaKey, mods: KeyMods, check: KeyHeldCheck)?
  private var holdID = 0
  private var repeats = 0
  var repeatTimes: () -> (delay: Double, interval: Double) = { (NSEvent.keyRepeatDelay, NSEvent.keyRepeatInterval) }
  var after: (Double, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }

  /// Opens once Input Monitoring is granted (asked every 2 s with the media
  /// keys); not decided yet: macOS asks the user once. What is missing is
  /// logged once. A failed open is tried again on the same manager, after
  /// HIDOpenRetry's wait (2 s doubling to 5 min), not at every ask (#813).
  func ensure(at now: Double = ProcessInfo.processInfo.systemUptime) {
    guard !isOpen else { return }
    let access = self.access()
    if access == kIOHIDAccessTypeUnknown && !asked {
      asked = true
      _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
    guard access == kIOHIDAccessTypeGranted else {
      say("brightness keys: Input Monitoring for OmacVM Bridge is \(access == kIOHIDAccessTypeDenied ? "off" : "not decided yet"): "
          + "with a VM in front they do nothing (System Settings > Privacy & Security > Input Monitoring)")
      return
    }
    guard retry.due(at: now) else { return }
    let m: IOHIDManager
    if let made = manager {
      // Its last open failed: close what of it did open, then open again.
      IOHIDManagerClose(made, IOOptionBits(kIOHIDOptionsTypeNone))
      m = made
    } else {
      m = makeManager(self)
      manager = m
    }
    let r = open(m)
    guard r == kIOReturnSuccess else {
      let wait = retry.failed(at: now)
      say("brightness keys: cannot read the keyboard (IOHIDManagerOpen: 0x\(String(UInt32(bitPattern: r), radix: 16))); "
          + "trying again in \(Int(wait)) s")
      return
    }
    isOpen = true
    retry.opened()
    said = nil
    log("brightness keys: reading them from the keyboard (they act only while an OmacVM VM is in front)\(Self.copiesNote(m))")
  }

  /// The manager: every keyboard and consumer control, on the main run loop.
  /// Made once (see `manager`).
  static func make(_ owner: BrightnessKeys) -> IOHIDManager {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let kinds: [[String: Any]] = [[kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
                                  [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl]]
    IOHIDManagerSetDeviceMatchingMultiple(m, kinds as CFArray)
    IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
      guard let ctx else { return }
      Unmanaged<BrightnessKeys>.fromOpaque(ctx).takeUnretainedValue().value(value)
    }, Unmanaged.passUnretained(owner).toOpaque())
    IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
      guard let ctx else { return }
      Unmanaged<BrightnessKeys>.fromOpaque(ctx).takeUnretainedValue().gone(device)
    }, Unmanaged.passUnretained(owner).toOpaque())
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    return m
  }

  /// Keyboards IOHIDManager gives more than once (each copy is read once, HIDCopies).
  private static func copiesNote(_ m: IOHIDManager) -> String {
    let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
    var seen: [UInt64: Int] = [:]
    for d in devices { seen[registryID(IOHIDDeviceGetService(d)), default: 0] += 1 }
    let twice = seen.values.filter { $0 > 1 }.count
    return twice == 0 ? "" : "; \(twice) of \(seen.count) keyboards listed more than once by macOS: one copy read"
  }

  private static func registryID(_ service: io_service_t) -> UInt64 {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &id)
    return id
  }

  private static func copy(_ device: IOHIDDevice) -> Int { Int(bitPattern: Unmanaged.passUnretained(device).toOpaque()) }

  private func say(_ s: String) {
    guard s != said else { return }
    said = s
    log(s)
  }

  private func value(_ v: IOHIDValue) {
    let e = IOHIDValueGetElement(v)
    let usage = HIDUsage.of(page: IOHIDElementGetUsagePage(e), usage: IOHIDElementGetUsage(e))
    guard Self.wanted(usage) else { return }
    let device = IOHIDElementGetDevice(e)
    let service = IOHIDDeviceGetService(device)
    let id = Self.registryID(service)
    let copy = Self.copy(device)
    ids[copy] = id
    let pressed = IOHIDValueGetIntegerValue(v) != 0
    // Whether this key still reads as down on its keyboard, for a held key's
    // repeats (KeyHeldCheck).
    let read: () -> Bool? = pressed ? { Self.reads(device, e) } : { nil }
    input(device: id, copy: copy, usage: usage, pressed: pressed, fnState: Self.fnState(), down: read) {
      Self.fnMap(device, service)
    }
  }

  /// The element's last reported value (without an update: nothing is sent to
  /// the keyboard, so a Bluetooth keyboard never holds up the main thread):
  /// true down, false up, nil when it cannot be read.
  static func reads(_ device: IOHIDDevice, _ element: IOHIDElement) -> Bool? {
    var raw: UnsafeMutableRawPointer?
    let r = withUnsafeMutablePointer(to: &raw) {
      $0.withMemoryRebound(to: Unmanaged<IOHIDValue>.self, capacity: 1) {
        IOHIDDeviceGetValueWithOptions(device, element, $0, IOHIDDeviceGetValueOptions.withoutUpdate.rawValue)
      }
    }
    guard r == kIOReturnSuccess, let raw else { return nil }
    return IOHIDValueGetIntegerValue(Unmanaged<IOHIDValue>.fromOpaque(raw).takeUnretainedValue()) != 0
  }

  /// A keyboard went away (unplugged, Bluetooth off): nothing of it stays held.
  private func gone(_ device: IOHIDDevice) {
    guard let id = ids.removeValue(forKey: Self.copy(device)) else { return }
    removed(device: id)
  }

  /// Only these usages are looked at: F1-F12, fn, Shift, Option, the brightness usages.
  static func wanted(_ usage: UInt32) -> Bool {
    HIDUsage.fn.contains(usage) || HIDUsage.shift.contains(usage) || HIDUsage.option.contains(usage)
      || HIDBrightness.key(usage) != nil || (0x0007_003A...0x0007_0045).contains(usage)
  }

  /// One key value of one keyboard (test-hid.sh drives this with made-up
  /// keyboards); its map is read once per keyboard. `copy`: which IOHIDDevice
  /// copy of the keyboard it came from (only the first one seen is read).
  /// `down`: whether the key reads as down on the keyboard now (KeyHeldCheck).
  func input(device id: UInt64, copy: Int = 0, usage: UInt32, pressed: Bool, fnState: Bool,
             down: @escaping () -> Bool? = { nil }, map read: () -> [UInt32: UInt32]) {
    guard copies.take(device: id, copy: copy) else { return }
    let map = maps[id] ?? {
      let m = read()
      maps[id] = m
      return m
    }()
    if !pressed, let h = held, h.device == id, h.usage == usage { endHold() }
    guard let key = keyboards.value(device: id, usage: usage, pressed: pressed, map: map, fnState: fnState) else { return }
    let mods = keyboards.mods
    onKey?(key, mods)
    endHold()
    held = (id, usage, key, mods, KeyHeldCheck(atPress: down(), read: down))
    let hold = holdID
    after(max(0.05, repeatTimes().delay)) { [weak self] in self?.repeatKey(hold) }
  }

  /// A keyboard went away: its copies, held keys and modifiers are forgotten.
  func removed(device id: UInt64) {
    copies.removed(device: id)
    keyboards.removed(device: id)
    maps[id] = nil
    if held?.device == id { endHold() }
  }

  /// The Mac slept or woke, a display slept or woke, the lock screen came or
  /// went (MediaKeys): a key-up can be lost across these, so a held key ends
  /// and fn, Shift and Option count as up until they are pressed again.
  func reset(_ why: String) {
    if let h = held { log("brightness keys: \(why): the held \(h.key) ended after \(repeats) repeats") }
    endHold()
    keyboards.releaseAll()
  }

  private func endHold() {
    held = nil
    holdID += 1
    repeats = 0
  }

  /// A held key's repeat: what its first press meant, whatever Shift and
  /// Option do meanwhile (as KeyHold does for the tap's repeats); only while
  /// the keyboard still reads the key down (KeyHeldCheck).
  private func repeatKey(_ hold: Int) {
    guard hold == holdID, let h = held else { return }
    guard repeats < Self.maxRepeats else {
      log("brightness keys: \(h.key) held for \(repeats) repeats with no key-up: repeats ended")
      endHold(); return
    }
    guard h.check.stillDown() else {
      log("brightness keys: no key-up came for \(h.key), but the keyboard reads it up (or no longer answers): repeats ended after \(repeats)")
      endHold(); return
    }
    repeats += 1
    onKey?(h.key, h.mods)
    after(max(0.015, repeatTimes().interval)) { [weak self] in self?.repeatKey(hold) }
  }

  /// The keyboard's own F-key map (on its event driver, below the device);
  /// an Apple keyboard (USB or Bluetooth) without one: F1/F2 as on all of them.
  static func fnMap(_ device: IOHIDDevice, _ service: io_service_t) -> [UInt32: UInt32] {
    let s = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "FnFunctionUsageMap" as CFString, nil,
                                            IOOptionBits(kIORegistryIterateRecursively)) as? String
    return HIDBrightness.map(published: s, vendor: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int)
  }

  /// "Use F1, F2, etc. keys as standard function keys" (Keyboard settings).
  static func fnState() -> Bool {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    return CFPreferencesCopyAppValue("com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication) as? Bool ?? false
  }
}
