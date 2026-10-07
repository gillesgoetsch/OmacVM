// Touch ID panel (ADR 0041, addendum 3.0.2): the Omarchy theme a VM sends
// (POST /omacvm/theme), the rules that make it safe to draw with, and the
// Mac's copy per VM. No AppKit here: tests/touchid runs it as is.
//
// The guest sends colours and a corner radius, nothing else. The panel's
// text never comes from the theme, the font is always the bundled JetBrains
// Mono, and the contrast rules keep the request readable whatever a VM sends.
import Foundation

let touchIDThemePath = "/omacvm/theme"
let touchIDThemeBodyMax = 512

/// An opaque sRGB colour from "#rrggbb" (alpha is never the guest's).
struct ThemeRGB: Equatable {
  let r: UInt8, g: UInt8, b: UInt8
  init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
  init?(hex: String) {
    let s = Array(hex.utf8)
    guard s.count == 7, s[0] == 35 else { return nil }
    func nib(_ c: UInt8) -> UInt8? {
      switch c {
      case 48...57: return c - 48
      case 97...102: return c - 87
      case 65...70: return c - 55
      default: return nil
      }
    }
    var v: [UInt8] = []
    for i in stride(from: 1, to: 7, by: 2) {
      guard let h = nib(s[i]), let l = nib(s[i + 1]) else { return nil }
      v.append(h << 4 | l)
    }
    r = v[0]; g = v[1]; b = v[2]
  }
  var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
  /// WCAG 2 relative luminance.
  var luminance: Double {
    func f(_ c: UInt8) -> Double {
      let x = Double(c) / 255
      return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
  }
  /// `t` of the way from this colour to `o`.
  func mix(_ o: ThemeRGB, _ t: Double) -> ThemeRGB {
    func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(a) + (Double(b) - Double(a)) * t).rounded()))) }
    return ThemeRGB(m(r, o.r), m(g, o.g), m(b, o.b))
  }
  /// WCAG contrast ratio, 1...21.
  func contrast(_ o: ThemeRGB) -> Double {
    let a = luminance, b = o.luminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }
}

/// What the panel draws with.
struct OmarchyTheme: Equatable {
  var background: ThemeRGB, foreground: ThemeRGB, accent: ThemeRGB, error: ThemeRGB
  var border: [ThemeRGB]     // one colour, or two for Hyprland's gradient
  var borderAngle: Double    // degrees, 0..<360, gradient only
  var radius: Double         // Hyprland's decoration:rounding, 0...12 pt
  var success = ThemeRGB(0x9e, 0xce, 0x6a)   // colors.toml green: the panel's "done"
  var muted = ThemeRGB(0x41, 0x48, 0x68)     // colors.toml muted: the panel's lines

  /// Light or dark from the background itself, not from the theme's "mode".
  var dark: Bool { background.luminance < 0.18 }

  /// Tokyo Night, Omarchy's default: the panel's look until the VM sends its theme.
  static let tokyoNight = OmarchyTheme(background: ThemeRGB(0x1a, 0x1b, 0x26), foreground: ThemeRGB(0xa9, 0xb1, 0xd6),
                                       accent: ThemeRGB(0x7a, 0xa2, 0xf7), error: ThemeRGB(0xf7, 0x76, 0x8e),
                                       border: [ThemeRGB(0x7a, 0xa2, 0xf7)], borderAngle: 0, radius: 0)

  /// The minimum contrasts. Text below its minimum refuses the whole theme;
  /// the others fall back to the text colour.
  static let textContrast = 4.5, accentContrast = 3.0, borderContrast = 1.5
  static let radiusMax = 12.0

  /// For the Mac's copy (the same keys the VM sends).
  var json: [String: Any] {
    ["background": background.hex, "foreground": foreground.hex, "accent": accent.hex, "error": error.hex,
     "border": border.map { $0.hex }, "border_angle": borderAngle, "radius": radius, "success": success.hex, "muted": muted.hex]
  }

  /// The colours OmacVM.app's panel draws with (TouchIDPanelPrompt's theme).
  var panelColors: [String: String] {
    ["background": background.hex, "foreground": foreground.hex, "accent": accent.hex, "error": error.hex,
     "success": success.hex, "muted": muted.hex]
  }

  /// Lines that stay visible on the background (else a mix of background and text).
  static let mutedContrast = 1.3
}

/// A JSON number that is not a bool and is finite.
private func strictNumber(_ v: Any?) -> Double? {
  guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
  let d = n.doubleValue
  return d.isFinite ? d : nil
}

/// The VM's body -> a theme the panel may use. Strict JSON, at most 512
/// bytes, known keys only, "#rrggbb" colours. Text that would be hard to
/// read refuses the whole theme (the last good one stays); a weak accent,
/// error or border colour becomes the text colour.
func parseTouchIDTheme(_ body: Data) -> Result<OmarchyTheme, PolicyError> {
  guard body.count <= touchIDThemeBodyMax else {
    return .failure(PolicyError(413, "too-large", "body over \(touchIDThemeBodyMax) bytes"))
  }
  let o: [String: Any]
  do {
    guard let obj = try strictObject(body, allowed: ["background", "foreground", "accent", "error", "success", "muted",
                                                     "border", "border_angle", "radius"]) else {
      return .failure(PolicyError(400, "bad-json", "body must be a JSON object"))
    }
    o = obj
  } catch let e as PolicyError { return .failure(e) } catch { return .failure(PolicyError(400, "bad-json", "body must be a JSON object")) }
  func colour(_ k: String, required: Bool) -> Result<ThemeRGB?, PolicyError> {
    guard let v = o[k] else {
      return required ? .failure(PolicyError(400, k, "\(k): a #rrggbb colour")) : .success(nil)
    }
    guard let s = v as? String, let c = ThemeRGB(hex: s) else { return .failure(PolicyError(400, k, "\(k): a #rrggbb colour")) }
    return .success(c)
  }
  var got: [String: ThemeRGB] = [:]
  for (k, req) in [("background", true), ("foreground", true), ("accent", false), ("error", false), ("success", false), ("muted", false)] {
    switch colour(k, required: req) {
    case .failure(let e): return .failure(e)
    case .success(let c): got[k] = c
    }
  }
  let bg = got["background"]!, fg = got["foreground"]!
  guard fg.contrast(bg) >= OmarchyTheme.textContrast else {
    return .failure(PolicyError(422, "contrast", "foreground on background under \(OmarchyTheme.textContrast):1"))
  }
  var border: [ThemeRGB] = []
  if let v = o["border"] {
    guard let list = v as? [Any], (1...2).contains(list.count) else {
      return .failure(PolicyError(400, "border", "border: one or two #rrggbb colours"))
    }
    for item in list {
      guard let s = item as? String, let c = ThemeRGB(hex: s) else {
        return .failure(PolicyError(400, "border", "border: one or two #rrggbb colours"))
      }
      border.append(c)
    }
  }
  var angle = 0.0, radius = 0.0
  if let v = o["border_angle"] {
    guard let a = strictNumber(v), abs(a) <= 3600 else { return .failure(PolicyError(400, "border_angle", "border_angle: degrees")) }
    angle = a.truncatingRemainder(dividingBy: 360)
    if angle < 0 { angle += 360 }
  }
  if let v = o["radius"] {
    guard let r = strictNumber(v) else { return .failure(PolicyError(400, "radius", "radius: points")) }
    radius = min(max(r, 0), OmarchyTheme.radiusMax)
  }
  let accent = got["accent"].flatMap { $0.contrast(bg) >= OmarchyTheme.accentContrast ? $0 : nil } ?? fg
  let error = got["error"].flatMap { $0.contrast(bg) >= OmarchyTheme.accentContrast ? $0 : nil } ?? fg
  let success = got["success"].flatMap { $0.contrast(bg) >= OmarchyTheme.accentContrast ? $0 : nil } ?? fg
  let muted = got["muted"].flatMap { $0.contrast(bg) >= OmarchyTheme.mutedContrast ? $0 : nil } ?? bg.mix(fg, 0.28)
  // A border colour that melts into the background: the whole border is the accent.
  if border.isEmpty || border.contains(where: { $0.contrast(bg) < OmarchyTheme.borderContrast }) { border = [accent] }
  return .success(OmarchyTheme(background: bg, foreground: fg, accent: accent, error: error, border: border,
                               borderAngle: border.count == 2 ? angle : 0, radius: radius, success: success, muted: muted))
}

/// The Mac's copy of each VM's theme: <dir>/<vm key name>.json, 0600, in a
/// 0700 folder of the Bridge's. Read back through the same rules. One theme
/// a second per VM. Thread-safe.
final class TouchIDThemeStore {
  let dir: String
  private let lock = NSLock()
  private var last: [String: Date] = [:]
  init(dir: String) { self.dir = dir }

  /// A VM key name is 32 hex digits (vmKeyName): nothing else becomes a file name.
  static func validName(_ s: String) -> Bool {
    s.utf8.count == 32 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  private func path(_ name: String) -> String { dir + "/" + name + ".json" }

  /// Nil when this VM may send a theme now; else the 429.
  func admit(_ name: String, now: Date) -> PolicyError? {
    lock.lock(); defer { lock.unlock() }
    if let l = last[name], now.timeIntervalSince(l) < 1, now >= l {
      return PolicyError(429, "rate", "one theme a second")
    }
    last[name] = now
    return nil
  }

  @discardableResult
  func save(_ t: OmarchyTheme, for name: String) -> Bool {
    guard TouchIDThemeStore.validName(name),
          let d = try? JSONSerialization.data(withJSONObject: t.json, options: [.sortedKeys]) else { return false }
    lock.lock(); defer { lock.unlock() }
    var st = stat()
    if lstat(dir, &st) != 0 {
      guard mkdir(dir, 0o700) == 0 else { return false }
    } else if (st.st_mode & S_IFMT) != S_IFDIR || st.st_uid != getuid() {
      return false
    }
    chmod(dir, 0o700)
    let tmp = path(name) + ".new"
    unlink(tmp)
    let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return false }
    let ok = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) } == d.count
    close(fd)
    guard ok, rename(tmp, path(name)) == 0 else { unlink(tmp); return false }
    return true
  }

  /// The VM's last good theme, or nil (Tokyo Night then).
  func load(_ name: String) -> OmarchyTheme? {
    guard TouchIDThemeStore.validName(name) else { return nil }
    lock.lock(); defer { lock.unlock() }
    var st = stat()
    guard lstat(path(name), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
          st.st_size <= 1024, let d = FileManager.default.contents(atPath: path(name)) else { return nil }
    if case .success(let t) = parseTouchIDTheme(d) { return t }
    return nil
  }

  func remove(_ name: String) {
    guard TouchIDThemeStore.validName(name) else { return }
    lock.lock(); defer { lock.unlock() }
    unlink(path(name))
  }
}
