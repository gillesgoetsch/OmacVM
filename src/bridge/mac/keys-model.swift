// When the media-key tap is created again, without AppKit (keys.swift uses it;
// test.sh's offline tests check it). Same rule as the Gestures helper's tap.
import Foundation

/// A new event tap goes to the head of its chain, so a tap made by a VM app
/// started after the Bridge (each OmacVM VM is its own QEMU process) sits
/// ahead of ours. So the tap is created again whenever an OmacVM process comes
/// to the front that was not in front just before: a new VM, a restarted app,
/// or the same VM again after another app.
struct TapRearm {
  private var lastFront: pid_t = 0
  private var failureLogged = false

  /// `vmPid`: the front app's pid when it is an OmacVM process, else nil.
  /// True: create the tap again now.
  mutating func front(_ vmPid: pid_t?) -> Bool {
    defer { lastFront = vmPid ?? 0 }
    guard let vmPid else { return false }
    return vmPid != lastFront
  }

  /// A re-creation failed (Accessibility taken away): true the first time
  /// only, until one works again.
  mutating func failed() -> Bool {
    defer { failureLogged = true }
    return !failureLogged
  }

  mutating func worked() { failureLogged = false }
}

// ---- where a media key goes (keys.swift asks; test-models.sh checks) ----

/// The media keys the Bridge looks at (NX_KEYTYPE_*, IOKit/hidsystem/ev_keymap.h).
enum MediaKey: Int {
  case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
  case play = 16, next = 17, previous = 18, fast = 19, rewind = 20
  case keyboardUp = 21, keyboardDown = 22, keyboardToggle = 23

  /// The key QEMU types for it in the VM (a QKeyCode): XF86AudioRaiseVolume &
  /// co. there, which Omarchy binds to its own volume popup and to playerctl.
  var qcode: String? {
    switch self {
    case .volumeUp: "volumeup"
    case .volumeDown: "volumedown"
    case .mute: "audiomute"
    case .play: "audioplay"
    case .next, .fast: "audionext"   // Apple keyboards send FAST/REWIND for the track keys
    case .previous, .rewind: "audioprev"
    default: nil
    }
  }
}

/// The VM app in front as the key path sees it. `omacvm`: an OmacVM.app VM
/// (also windowed); Parallels, UTM and Fusion count only full screen.
/// `display`: the Mac display it is on, `builtin` whether that is the
/// built-in one. `vmKeys`: keys can be typed into it (OmacVM.app's QMP).
struct FrontVM: Equatable {
  var omacvm: Bool
  var fullScreen: Bool
  var display: UInt32
  var builtin: Bool
  var vmKeys: Bool
}

/// What the Bridge knows about an external display's brightness.
enum ExternalState: Equatable {
  case works        // DDC/CI or the display's own control (Apple displays, LG UltraFine)
  case unknown      // not looked at yet (a look is queued)
  case no(String)   // why not
  case off          // external_brightness off in config.json
}

enum KeyRoute: Equatable {
  case macOS(String?)       // passed on to macOS; the reason is logged once (nil: nothing to say)
  case mac                  // the Bridge sets the Mac's own (volume, mute, keyboard light, its brightness display)
  case external(UInt32)     // that external display's brightness
  case vm(String)           // typed into the VM in front (a QKeyCode)
}

enum MediaRoute {
  /// `vm`: the VM in front, nil for none. `volumeSettable`/`muteSettable`: the
  /// Mac's default output has a software volume/mute (a Scarlett 2i2 has
  /// neither). `macBrightness`: the display the Bridge's own brightness call
  /// sets (the built-in one, else the display macOS dims itself, the main one
  /// first; nil: none). `external`: what is known about the VM's display when
  /// it is external. `keyboardLight`: this Mac has one. `command`: Command
  /// is held.
  static func route(_ key: MediaKey, vm: FrontVM?, volumeSettable: Bool, muteSettable: Bool,
                    macBrightness: UInt32?, external: ExternalState, keyboardLight: Bool,
                    command: Bool = false) -> KeyRoute {
    guard let vm, vm.omacvm || vm.fullScreen else { return .macOS(nil) }   // no VM in front: macOS's keys
    switch key {
    case .volumeUp, .volumeDown, .mute:
      // Command + a volume key is a shortcut, not a volume change: Omarchy's
      // Super + mute / volume down / volume up are its screenshot keys on Mac
      // keyboards (window, region, display; Super + Option + volume up records).
      // QEMU already holds Super in the VM for the Command key, so only the key
      // itself is typed. Without this a Mac output with a volume (the MacBook's
      // speakers) took the key and Omarchy never saw it.
      if command && vm.omacvm && vm.vmKeys, let q = key.qcode { return .vm(q) }
      if key == .mute ? muteSettable : volumeSettable { return .mac }
      // No software volume on the Mac's output: the VM's own volume (its
      // popup), never macOS's greyed-out panel.
      if vm.omacvm && vm.vmKeys, let q = key.qcode { return .vm(q) }
      return .macOS(vm.omacvm ? "the VM takes no keys from the Bridge (QEMU's control socket not found)"
                              : "the Mac's output has no volume macOS can set, and only OmacVM.app VMs take keys")
    case .play, .next, .previous, .fast, .rewind:
      // To the VM's players (MPRIS through playerctl), not macOS's Now Playing.
      guard vm.omacvm else { return .macOS(nil) }
      if vm.vmKeys, let q = key.qcode { return .vm(q) }
      return .macOS("the VM takes no keys from the Bridge (QEMU's control socket not found)")
    case .brightnessUp, .brightnessDown:
      if !vm.builtin, external == .works { return .external(vm.display) }
      // The Bridge's own call reaches the VM's display: the built-in one, or a
      // Mac mini's only display that macOS dims itself (LG UltraFine, Studio
      // Display), full screen or not. An OmacVM.app window on the built-in one
      // too: while it has the keyboard, macOS's own shortcuts are off (they go
      // to the VM), so the Bridge sets the brightness itself rather than rely
      // on macOS for it.
      if macBrightness == vm.display && (vm.fullScreen || !vm.builtin || vm.omacvm) { return .mac }
      if vm.builtin { return .macOS(nil) }
      switch external {
      case .no(let why): return .macOS(why)
      case .unknown: return .macOS("not looked at yet (the next press uses it if it can be set)")
      case .off: return .macOS("external brightness is off (external_brightness in config.json)")
      case .works: return .external(vm.display)
      }
    case .keyboardUp, .keyboardDown, .keyboardToggle:
      return keyboardLight ? .mac : .macOS(nil)
    }
  }
}

// ---- brightness keys read from the keyboard itself (keys.swift: BrightnessKeys) ----
// On macOS 27 (Mac mini, Magic Keyboard) the brightness keys reach no event
// tap at all, not even at the HID level: macOS handles them below. So the
// Bridge also reads them from the keyboard (IOHIDManager, not seized: macOS
// still gets every key). Apple keyboards send F1/F2 (keyboard page) and macOS
// turns them into brightness by the keyboard's own "FnFunctionUsageMap"
// (IORegistry; on this MacBook: 0x0007003a -> 0x00ff0005, 0x0007003b ->
// 0x00ff0004, Apple's top-case page) unless "Use F1, F2, etc. keys as standard
// function keys" is on (then fn + F1/F2 are brightness). Other keyboards send
// the consumer page's brightness usages (0x0C 0x6F/0x70) directly.

/// A HID usage as page << 16 | usage, as FnFunctionUsageMap writes it.
enum HIDUsage {
  static let f1: UInt32 = 0x0007_003A, f2: UInt32 = 0x0007_003B
  /// fn: Apple's top-case page (MacBook, Magic Keyboard) or Apple's keyboard page.
  static let fn: Set<UInt32> = [0x00FF_0003, 0xFF01_0003]
  /// Brightness up/down: consumer page, Apple's top-case page, Apple's keyboard page.
  static let up: Set<UInt32> = [0x000C_006F, 0x00FF_0004, 0xFF01_0020]
  static let down: Set<UInt32> = [0x000C_0070, 0x00FF_0005, 0xFF01_0021]
  static func of(page: UInt32, usage: UInt32) -> UInt32 { page << 16 | (usage & 0xFFFF) }
}

enum HIDBrightness {
  /// An Apple keyboard without the property: F1 down, F2 up, as on all of them.
  static let appleDefault: [UInt32: UInt32] = [HIDUsage.f1: 0x00FF_0005, HIDUsage.f2: 0x00FF_0004]
  /// Apple's vendor IDs: 0x05AC over USB, 0x004C (Apple's Bluetooth id) over
  /// Bluetooth. The Mac mini's Magic Keyboard is Bluetooth, 0x004C, and
  /// publishes no FnFunctionUsageMap.
  static let appleVendors: Set<Int> = [0x05AC, 0x004C]

  /// A keyboard's F-key map: its own published one, else Apple's default for
  /// an Apple keyboard, else none (a PC keyboard: its F1 is F1).
  static func map(published: String?, vendor: Int?) -> [UInt32: UInt32] {
    let m = fnMap(published)
    if !m.isEmpty { return m }
    return vendor.map { appleVendors.contains($0) } == true ? appleDefault : [:]
  }

  /// FnFunctionUsageMap: "0xFROM,0xTO,0xFROM,0xTO,...". Pairs that do not
  /// parse are left out; an odd last entry is ignored.
  static func fnMap(_ s: String?) -> [UInt32: UInt32] {
    guard let s else { return [:] }
    let v = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .map { UInt32($0.lowercased().hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) }
    var m: [UInt32: UInt32] = [:]
    var i = 0
    while i + 1 < v.count {
      if let a = v[i], let b = v[i + 1] { m[a] = b }
      i += 2
    }
    return m
  }

  static func key(_ usage: UInt32) -> MediaKey? {
    HIDUsage.up.contains(usage) ? .brightnessUp : HIDUsage.down.contains(usage) ? .brightnessDown : nil
  }
}

/// Each keyboard's fn key and what a press means. `map`: that keyboard's
/// FnFunctionUsageMap (empty: none). `fnState`: macOS's "standard function
/// keys" setting. A press that is a brightness key gives it, nil otherwise.
struct HIDKeyboards {
  private var fnDown: Set<UInt64> = []

  mutating func value(device: UInt64, usage: UInt32, pressed: Bool, map: [UInt32: UInt32], fnState: Bool) -> MediaKey? {
    if HIDUsage.fn.contains(usage) {
      if pressed { fnDown.insert(device) } else { fnDown.remove(device) }
      return nil
    }
    guard pressed else { return nil }
    if let k = HIDBrightness.key(usage) { return k }
    // F1/F2 are brightness when fn is up with special keys (macOS's default),
    // or fn is down with standard function keys. Any keyboard's fn counts: a
    // keyboard may send fn from another of its HID interfaces than F1.
    guard let to = map[usage], !fnDown.isEmpty == fnState else { return nil }
    return HIDBrightness.key(to)
  }
}

/// One press can reach the Bridge twice: from the keyboard (IOHIDManager) and
/// as macOS's media-key event (the tap), where a Mac delivers both. Whichever
/// comes first acts; the other path's copy within `window` s is dropped.
struct BrightnessOnce {
  enum Path { case keyboard, tap }
  static let window = 0.3
  private var last: (path: Path, key: MediaKey, at: Double)?

  mutating func take(_ path: Path, _ key: MediaKey, at now: Double) -> Bool {
    if let l = last, l.path != path, l.key == key, now - l.at < BrightnessOnce.window {
      last = nil   // matched: the next press acts again
      return false
    }
    last = (path, key, now)
    return true
  }

  /// macOS changed the brightness itself meanwhile (read before and a moment
  /// after the key): then the Bridge does not step it again.
  static func macOSDidIt(before: Float?, after: Float?) -> Bool {
    guard let before, let after else { return false }
    return abs(after - before) >= 0.004
  }
}

/// The Bridge's own brightness steps per display. A key read from the keyboard
/// checks a moment later whether macOS changed the display itself; a step of
/// the Bridge's in that time (an earlier quick press, a held key's repeat)
/// would look like macOS's, so then the check is skipped and the key steps.
struct OwnSteps {
  /// How long before the press a step of the Bridge's may still show up.
  static let settle = 0.3
  private var last: [UInt32: Double] = [:]

  mutating func stepped(_ display: UInt32, at now: Double) { last[display] = now }

  /// The Bridge stepped `display` since shortly before the press at `pressAt`.
  func since(_ display: UInt32, pressAt: Double) -> Bool {
    guard let l = last[display] else { return false }
    return l >= pressAt - OwnSteps.settle
  }

  /// The press's check: true = macOS changed it itself, the Bridge does not step.
  func macOSDidIt(_ display: UInt32, pressAt: Double, before: Float?, after: Float?) -> Bool {
    !since(display, pressAt: pressAt) && BrightnessOnce.macOSDidIt(before: before, after: after)
  }
}

/// Says each reason once (per display), so a held key is not a log line per press.
struct OnceLog {
  private var said: Set<String> = []
  mutating func first(_ what: String) -> Bool { said.insert(what).inserted }
  mutating func reset() { said = [] }
}

// ---- QEMU's control socket (QMP) of an OmacVM.app VM ----
enum QMPKeys {
  /// The socket from QEMU's command line: "-qmp unix:PATH,server=on,wait=off"
  /// (a comma in the path is written twice). nil: none, or not a Unix socket.
  static func socketPath(_ args: [String]) -> String? {
    guard let i = args.firstIndex(of: "-qmp"), i + 1 < args.count, args[i + 1].hasPrefix("unix:") else { return nil }
    let v = Array(args[i + 1].dropFirst(5))
    var out = "", k = 0
    while k < v.count {
      if v[k] == "," {
        guard k + 1 < v.count, v[k + 1] == "," else { break }
        k += 1
      }
      out.append(v[k]); k += 1
    }
    return out.isEmpty || out.utf8.count > 103 ? nil : out   // sun_path holds 104 bytes
  }

  /// The commands for one key press: capabilities, the key down, the key up.
  static func commands(_ qcode: String) -> [String] {
    func key(_ down: Bool) -> String {
      #"{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":\#(down),"key":{"type":"qcode","data":"\#(qcode)"}}}]}}"#
    }
    return [#"{"execute":"qmp_capabilities"}"#, key(true), key(false)]
  }

  /// One line from QEMU: "greeting", "ok" (a return), "error", or nil for
  /// anything else (an event, which may come in between).
  static func kind(_ line: String) -> String? {
    guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    if o["QMP"] != nil { return "greeting" }
    if o["return"] != nil { return "ok" }
    if o["error"] != nil { return "error" }
    return nil
  }
}

/// KERN_PROCARGS2's buffer -> the arguments (argv only, no environment).
/// Untrusted size and content: anything odd gives nil.
enum ProcArgs {
  static func parse(_ b: [UInt8]) -> [String]? {
    guard b.count >= 4 else { return nil }
    let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
    guard argc > 0, argc < 4096 else { return nil }
    var i = 4
    while i < b.count, b[i] != 0 { i += 1 }   // the executable's path
    while i < b.count, b[i] == 0 { i += 1 }   // its padding
    var args: [String] = []
    while args.count < argc, i < b.count {
      let start = i
      while i < b.count, b[i] != 0 { i += 1 }
      guard i < b.count else { return nil }
      args.append(String(decoding: b[start..<i], as: UTF8.self))
      i += 1
    }
    return args.count == argc ? args : nil
  }
}
