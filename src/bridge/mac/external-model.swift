// External display brightness, the parts without hardware: macOS's steps,
// the DDC/CI packets for VCP 0x10 (luminance), and which Mac display a VM
// window or a guest output is on. Compiled into the Bridge and into
// test.sh's offline tests (no AppKit here).
import CoreGraphics
import Foundation

enum BrightnessStep {
  /// Steps on 0...1 for the display brightness keys while a VM is in front
  /// (the built-in display, Apple displays, DDC/CI). macOS uses 16; the user
  /// found that too rough (2026-10-06), so 32 by default. config.json
  /// "brightness_steps" changes it (8...100, read again without a restart).
  static let defaultSteps = 32
  static func steps(_ n: Int?) -> Int { max(8, min(100, n ?? defaultSteps)) }
  /// Option (Shift+Option): at least macOS's quarter steps (64), twice the
  /// normal ones when they are finer already, at most 100.
  static func fine(_ steps: Int) -> Int { min(100, max(64, 2 * steps)) }

  /// One step up or down on the grid of `steps`, clamped to 0...1. With the
  /// display's raw maximum (DDC/CI) the step goes on until the raw value moves,
  /// so a coarse monitor (max 10, 50) never takes a press without a change.
  static func next(_ v: Double, up: Bool, steps n: Int, max m: Int? = nil) -> Double {
    let s = Double(n)
    var grid = (max(0, min(1, v)) * s).rounded()
    for _ in 0..<n {
      grid = max(0, min(s, grid + (up ? 1 : -1)))
      let to = grid / s
      guard let m, m > 0, raw(to, max: m) == raw(v, max: m), grid > 0, grid < s else { return to }
    }
    return grid / s
  }

  /// A level 0...1 as the monitor's raw value 0...max, and back.
  static func raw(_ v: Double, max m: Int) -> Int { Int((max(0, min(1, v)) * Double(m)).rounded()) }
  static func level(_ raw: Int, max m: Int) -> Double { m > 0 ? max(0, min(1, Double(raw) / Double(m))) : 0 }
  static func percent(_ v: Double) -> Int { Int((max(0, min(1, v)) * 100).rounded()) }
}

/// DDC/CI over I2C (VESA DDC/CI 1.1): the display at 7-bit address 0x37, the
/// host's sub-address 0x51. A packet: 0x80 | length, the payload, a checksum
/// (XOR of 0x6E, 0x51 and every byte before it).
enum DDCPacket {
  static let address: UInt32 = 0x37
  static let subAddress: UInt32 = 0x51
  static let luminance: UInt8 = 0x10

  /// "Get VCP feature" (opcode 0x01).
  static func get(_ code: UInt8) -> [UInt8] { sealed([0x82, 0x01, code]) }

  /// "Set VCP feature" (opcode 0x03), value big-endian.
  static func set(_ code: UInt8, _ value: UInt16) -> [UInt8] {
    sealed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
  }

  private static func sealed(_ b: [UInt8]) -> [UInt8] { b + [b.reduce(0x6E ^ 0x51, ^)] }

  /// The reply to get: 0x6E, 0x88, 0x02 (VCP reply), result (0 = supported),
  /// the code, type, max (2 bytes), current (2 bytes), checksum (XOR of 0x50
  /// and the bytes before it). nil for anything else: the display is untrusted
  /// input too (a missing answer reads as zeros or 0xFF).
  static func parse(_ r: [UInt8], code: UInt8) -> (current: Int, max: Int)? {
    guard r.count >= 11, r[1] == 0x88, r[2] == 0x02, r[3] == 0x00, r[4] == code,
          r[0..<10].reduce(0x50, ^) == r[10] else { return nil }
    let maximum = Int(r[6]) << 8 | Int(r[7]), current = Int(r[8]) << 8 | Int(r[9])
    guard maximum > 0 else { return nil }
    return (min(current, maximum), maximum)
  }
}

/// How a display's brightness is set, from what macOS says about it.
/// macOS's own control (DisplayServices) comes first: the displays macOS dims
/// itself (Studio Display, Pro Display XDR, the LG UltraFine family over USB)
/// use it even when they also have an AV service, since it is what macOS's
/// keys use and the UltraFine has no DDC/CI. DDC/CI only for the rest.
enum MethodPick {
  enum Choice: Equatable { case builtin, virtual, native, ddc, noIOAV, noService }
  static func choose(builtin: Bool, virtual: Bool, nativeCan: Bool, nativeReads: Bool,
                     hasService: Bool, ioav: Bool) -> Choice {
    if builtin { return .builtin }
    if virtual { return .virtual }
    if nativeCan && nativeReads { return .native }
    if hasService { return .ddc }
    return ioav ? .noService : .noIOAV
  }
}

/// When the Bridge looks at a display (again). `works`: nil = never looked.
/// A display that could not be set is asked again after `retry` seconds: it
/// may have been asleep, or its AV service not there yet.
enum ProbeRule {
  static func due(works: Bool?, probedAt: Date, now: Date, retry: Double) -> Bool {
    guard let works else { return true }
    return !works && now.timeIntervalSince(probedAt) > retry
  }
}

/// Time between DDC transfers: 50 ms for anything (a held key sends the
/// latest level); writes the VM asked for at least 250 ms apart, since some
/// monitors save the level to EEPROM on every write.
enum WritePace {
  static let gap = 0.05
  static let vmGap = 0.25
  static func delay(sinceTransfer: Double, sinceWrite: Double, fromVM: Bool) -> Double {
    max(0, gap - sinceTransfer, fromVM ? vmGap - sinceWrite : 0)
  }
}

/// A key's DDC/CI write in parts: a jump bigger than two steps (presses
/// coalesced while the monitor was busy, a held key) goes out as one write
/// per transfer gap of at most two steps each, so the level ramps instead of
/// jumping. Single presses are one write. The latest target always wins.
/// The VM's writes are not ramped (one write per 250 ms, see WritePace).
enum Ramp {
  static let stepsPerWrite = 2
  static func limit(max m: Int, steps: Int) -> Int { Swift.max(1, Int((Double(stepsPerWrite * m) / Double(steps)).rounded())) }
  /// The next raw value on the way from `from` (nil: unknown, so straight) to `to`.
  static func next(from: Int?, to: Int, limit: Int) -> Int {
    guard let from else { return to }
    return from + Swift.max(-limit, Swift.min(limit, to - from))
  }
}

/// Why a display's brightness can't be set (omacvm check shows these).
enum NotSettable {
  static let builtin = "the built-in display (the brightness keys stay macOS's)"
  static let virtual = "a virtual or AirPlay display"
  static let noIOAV = "this macOS has no IOAVService for DDC/CI"
  // An M1/M2 Mac mini's HDMI port has an AV service but passes no DDC/CI: the same silence as a display with DDC off.
  static let noAnswer = "it does not answer DDC/CI (switched off in its own menu, asleep, or this port passes none: " +
    "some Macs' HDMI ports, try USB-C/DisplayPort)"
  static let noService = "no DDC/CI on this connection (some Macs' HDMI ports have none: try USB-C/DisplayPort)"
}

/// The on-screen normal windows (layer 0, bigger than 100x100) of one process,
/// front to back, from one copy of macOS's window list.
enum WindowList {
  static func rects(_ list: [[String: Any]], pid: Int32) -> [CGRect] {
    list.compactMap { w in
      guard w[kCGWindowOwnerPID as String] as? Int32 == pid, w[kCGWindowLayer as String] as? Int == 0,
            let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
            r.width > 100, r.height > 100 else { return nil }
      return r
    }
  }
}

/// Which Bridge an OmacVM.app VM belongs to. A Mac can run OmacVM.app's Bridge
/// and the test identity's Bridge side by side (OmacVM Test.app, port 47931).
/// Each VM talks only to the Bridge of its own app. If both Bridges took its
/// media keys, the one the VM does not talk to could swallow them and send
/// the popup to nobody (MacBook Air, 2026-10-06: no Omarchy OSD at all).
enum VMOwner {
  static let testApp = "org.omacvm.app.test"
  static let testBridge = "org.omacvm.test.bridge"
  private static let runtime = "/Contents/Resources/runtime/bin/OmacVM"

  /// The .app a VM process runs from (<app>/Contents/Resources/runtime/bin/OmacVM).
  /// nil for a development build's qemu-system-aarch64.
  static func app(executable exe: String) -> String? {
    guard exe.hasSuffix(runtime) else { return nil }
    let app = String(exe.dropLast(runtime.count))
    return app.hasSuffix(".app") ? app : nil
  }

  /// `appID`: the bundle id of the VM's app (nil: unknown, e.g. a development
  /// build; such a VM stays every Bridge's, as before). The test Bridge takes
  /// only OmacVM Test.app's VMs, every other Bridge all the others.
  static func ours(appID: String?, testBridge: Bool) -> Bool {
    guard let appID else { return true }
    return (appID == testApp) == testBridge
  }
}

/// A Mac display, in CoreGraphics' global space (points, top-left origin).
struct MacDisplay: Equatable {
  let id: CGDirectDisplayID
  let bounds: CGRect
  let builtin: Bool
}

enum DisplayPick {
  /// A window covering a display: full screen (the menu bar or the notch strip
  /// may stay above it), as the media keys have always checked.
  static func covers(_ w: CGRect, _ d: CGRect) -> Bool {
    abs(w.width - d.width) < 2 && w.height >= d.height - 80 && abs(w.minX - d.minX) < 2 &&
      w.minY >= d.minY - 2 && w.maxY <= d.maxY + 2
  }

  /// The media keys' older, looser rule: a window as wide as a display, at
  /// its left edge and at most 80 points short (Parallels, UTM, Fusion and
  /// OmacVM.app full screen).
  static func spansOne(_ windows: [CGRect], _ displays: [CGRect]) -> Bool {
    windows.contains { r in displays.contains { abs(r.width - $0.width) < 2 && r.height >= $0.height - 80 && abs(r.minX - $0.minX) < 2 } }
  }

  /// The display with most of the window on it.
  static func home(_ w: CGRect, _ displays: [MacDisplay]) -> MacDisplay? {
    var best: MacDisplay?, area: CGFloat = 0
    for d in displays {
      let i = w.intersection(d.bounds)
      if !i.isNull, i.width * i.height > area { best = d; area = i.width * i.height }
    }
    return best
  }

  /// The display of the VM window in front, for the brightness keys and for
  /// a guest request without a box. `windows`: the front VM app's windows,
  /// front to back. Full screen: the display under the pointer when the VM
  /// covers it, else the first one it covers. `windowed` (OmacVM.app, or a
  /// request from the guest): also a window that is not full screen, the one
  /// under the pointer first, else the front window's display.
  static func focused(windows: [CGRect], displays: [MacDisplay], pointer: CGPoint,
                      windowed: Bool) -> (display: MacDisplay, fullScreen: Bool)? {
    let under = displays.first { $0.bounds.contains(pointer) }
    let full = displays.filter { d in windows.contains { covers($0, d.bounds) } }
    if let u = under, full.contains(u) { return (u, true) }
    if let f = windows.lazy.compactMap({ w in full.first { covers(w, $0.bounds) } }).first { return (f, true) }
    guard windowed else { return nil }
    if let u = under, windows.contains(where: { home($0, displays) == u }) { return (u, false) }
    if let w = windows.first, let d = home(w, displays) { return (d, false) }
    return nil
  }

  /// A guest output's box from OmacVM.app's layout (points; the layout's
  /// top-left corner is 0,0) -> the display it is on, among the displays that
  /// show an OmacVM.app window. First by size: the output's window is as wide
  /// as the box and at most a title bar or the notch strip taller (another
  /// VM's windows rarely match). Several left: the layout keeps the Mac's
  /// arrangement, so the box's centre, moved by the top-left corner of their
  /// displays, lands on its display (the notch strip shifts it a little).
  static func forBox(_ box: CGRect, windows: [CGRect], displays: [MacDisplay]) -> MacDisplay? {
    func homes(_ ws: [CGRect]) -> [MacDisplay] {
      var out: [MacDisplay] = []
      for w in ws { if let d = home(w, displays), !out.contains(d) { out.append(d) } }
      return out
    }
    let sized = homes(windows.filter { abs($0.width - box.width) < 2 && (-2...60).contains($0.height - box.height) })
    if sized.count == 1 { return sized[0] }
    let shown = sized.isEmpty ? homes(windows) : sized
    if shown.count == 1 { return shown[0] }
    guard let minX = shown.map({ $0.bounds.minX }).min(), let minY = shown.map({ $0.bounds.minY }).min() else { return nil }
    let p = CGPoint(x: minX + box.midX, y: minY + box.midY)
    return shown.first { $0.bounds.contains(p) }
  }

  /// A box from the guest is untrusted: finite, positive size, within reason.
  static func validBox(_ b: CGRect) -> Bool {
    [b.minX, b.minY, b.width, b.height].allSatisfy { $0.isFinite && abs($0) <= 100_000 } && b.width > 0 && b.height > 0
  }
}
