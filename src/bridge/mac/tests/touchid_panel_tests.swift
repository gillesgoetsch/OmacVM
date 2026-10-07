// Tests for the Touch ID panel's parts without AppKit (ADR 0041, addendum
// 3.0.2): the theme a VM sends and its rules (touchid_theme.swift), the
// Mac's copy, the panel's words against the alert's, where the panel goes,
// its keys, panel or alert, and that it ends once (touchid_panel_model.swift).
// Run: src/bridge/mac/tests/run.sh (CI runs it too). Fixtures: tests/fixtures.
import Foundation

var tFailures = 0, tPassed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { tPassed += 1 } else { tFailures += 1; print("FAIL line \(line): \(what)") }
}

func body(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
func theme(_ o: Any) -> OmarchyTheme? { if case .success(let t) = parseTouchIDTheme(body(o)) { return t }; return nil }
func refusal(_ d: Data) -> String? { if case .failure(let e) = parseTouchIDTheme(d) { return e.code }; return nil }
func refusal(_ o: Any) -> String? { refusal(body(o)) }

final class PromptAuth: TouchIDAuthenticator {
  var prompts: [TouchIDPrompt] = []
  func unavailable(passwordFallback: Bool) -> TouchIDNo? { nil }
  func evaluate(_ p: TouchIDPrompt, passwordFallback: Bool, timeout: Double, gone: @escaping () -> Bool) -> TouchIDOutcome {
    prompts.append(p); return .yes
  }
}
struct FrontMac: TouchIDMacState { var locked = false; var frontType: String? = "app" }

@main struct TouchIDPanelTests {
  static func main() {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    let base: [String: Any] = ["background": "#1a1b26", "foreground": "#a9b1d6", "accent": "#7aa2f7", "error": "#f7768e",
                               "border": ["#7aa2f7"], "border_angle": 0, "radius": 0, "success": "#9ece6a", "muted": "#414868"]
    func with(_ k: String, _ v: Any?) -> [String: Any] { var o = base; o[k] = v; return o }

    // ---- the 22 stock themes ----
    let tsv = try! String(contentsOfFile: here + "/fixtures/omarchy-themes.tsv", encoding: .utf8)
    var stock = 0, lowest = 21.0, errorFallback: [String] = [], successFallback: [String] = [], mutedMix: [String] = []
    for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
      let f = line.split(separator: "\t").map(String.init)
      guard f.count == 8 else { check(false, "fixture line \(line)"); continue }
      let t = theme(["background": f[1], "foreground": f[2], "accent": f[3], "error": f[4], "border": [f[3]], "radius": 0,
                     "success": f[6], "muted": f[7]])
      check(t != nil, "stock theme \(f[0]) passes")
      guard let t else { continue }
      stock += 1
      lowest = min(lowest, t.foreground.contrast(t.background))
      check(t.dark == (f[5] == "dark"), "\(f[0]): light or dark from the background matches its mode")
      check(t.background.hex == f[1].lowercased() && t.foreground.hex == f[2].lowercased(), "\(f[0]): colours kept")
      if t.error != ThemeRGB(hex: f[4]) { errorFallback.append(f[0]) }
      if t.success != ThemeRGB(hex: f[6]) { successFallback.append(f[0]) }
      if t.muted != ThemeRGB(hex: f[7]) { mutedMix.append(f[0]) }
      check(t.accent.contrast(t.background) >= 3 && t.border.allSatisfy { $0.contrast(t.background) >= 1.5 }, "\(f[0]): contrasts")
    }
    check(stock == 22, "22 stock themes (got \(stock))")
    check(lowest >= 6.5, "lowest text contrast of the stock themes \(lowest)")
    check(errorFallback.sorted() == ["miasma", "solitude"], "stock themes whose red is too faint for errors: \(errorFallback)")
    print("note: stock themes whose green falls back to the text colour: \(successFallback.sorted()); muted mixed: \(mutedMix.sorted())")

    // ---- the theme's rules ----
    let tn = theme(base)
    check(tn == OmarchyTheme.tokyoNight, "Tokyo Night as sent equals the built-in default")
    check(tn.flatMap { theme($0.json) } == tn, "the Mac's copy reads back the same")
    check(theme(["background": "#1A1B26", "foreground": "#A9B1D6"])?.background == ThemeRGB(0x1a, 0x1b, 0x26), "capitals")
    check(theme(["background": "#1a1b26", "foreground": "#a9b1d6"])?.accent == ThemeRGB(0xa9, 0xb1, 0xd6), "no accent: the text colour")
    check(refusal(with("foreground", "#1a1b26")) == "contrast", "text the colour of the background: refused")
    check(refusal(with("foreground", "#30323f")) == "contrast", "faint text: refused")
    check(refusal(with("background", "#1a1b26ff")) == "background", "8 hex digits (alpha) refused")
    check(refusal(with("background", "#fff")) == "background", "3 hex digits refused")
    check(refusal(with("background", "rgb(26,27,38)")) == "background", "rgb() refused")
    check(refusal(with("background", " #1a1b26")) == "background", "spaces refused")
    check(refusal(with("background", 0x1a1b26)) == "background", "a number for a colour refused")
    check(refusal(with("accent", "#gggggg")) == "accent", "not hex")
    check(refusal(with("background", nil)) == "background", "no background")
    check(refusal(with("foreground", nil)) == "foreground", "no foreground")
    check(theme(with("accent", "#20212c"))?.accent == ThemeRGB(0xa9, 0xb1, 0xd6), "faint accent: the text colour")
    check(theme(with("error", "#30202a"))?.error == ThemeRGB(0xa9, 0xb1, 0xd6), "faint error: the text colour")
    check(theme(with("border", ["#1c1d28"]))?.border == [ThemeRGB(0x7a, 0xa2, 0xf7)], "invisible border: the accent")
    check(theme(with("border", ["#7aa2f7", "#1c1d28"]))?.border == [ThemeRGB(0x7a, 0xa2, 0xf7)], "half invisible gradient: the accent")
    check(refusal(with("border", ["#7aa2f7", "#bb9af7", "#f7768e"])) == "border", "three border colours refused")
    check(refusal(with("border", [])) == "border", "no border colours refused")
    check(refusal(with("border", "#7aa2f7")) == "border", "border not a list")
    let g = theme(with("border", ["#798186", "#cacccc"]).merging(["border_angle": 45, "background": "#101315", "foreground": "#cacccc"]) { $1 })
    check(g?.border.count == 2 && g?.borderAngle == 45, "a gradient with its angle")
    check(theme(with("border", ["#7aa2f7", "#bb9af7"]).merging(["border_angle": -90]) { $1 })?.borderAngle == 270, "angle below 0")
    check(theme(with("border", ["#7aa2f7", "#bb9af7"]).merging(["border_angle": 720]) { $1 })?.borderAngle == 0, "angle over 360")
    check(theme(with("border_angle", 45))?.borderAngle == 0, "one colour: no angle")
    check(refusal(with("border_angle", "45deg")) == "border_angle", "angle as text")
    check(refusal(with("border_angle", 1e9)) == "border_angle", "huge angle")
    check(theme(with("radius", 999))?.radius == 12, "radius at most 12")
    check(theme(with("radius", -5))?.radius == 0, "radius at least 0")
    check(theme(with("radius", 6.5))?.radius == 6.5, "radius kept")
    check(refusal(with("radius", true)) == "radius", "a bool for the radius")
    check(refusal(with("radius", "6")) == "radius", "radius as text")
    check(refusal(with("font", "Symbols Nerd Font")) == "unknown-key", "no font from the guest")
    check(refusal(with("title", "Touch ID in macOS")) == "unknown-key", "no text from the guest")
    check(refusal(Data(##"{"background":"#1a1b26","foreground":"#a9b1d6","pad":""##.utf8) + Data(repeating: 32, count: 500) + Data("}".utf8)) == "too-large",
          "over 512 bytes")
    check(refusal(Data("[1]".utf8)) == "bad-json", "not an object")
    check(refusal(Data()) == "bad-json", "empty")
    check(refusal(Data("{".utf8)) == "bad-json", "broken JSON")
    check(OmarchyTheme.tokyoNight.dark && theme(with("background", "#ffffff").merging(["foreground": "#000000"]) { $1 })?.dark == false,
          "dark and light")

    // ---- the panel's done and line colours ----
    let plain: [String: Any] = ["background": "#1a1b26", "foreground": "#a9b1d6"]
    var sm = plain; sm["success"] = "#9ece6a"; sm["muted"] = "#414868"
    check(theme(sm)?.success == ThemeRGB(hex: "#9ece6a") && theme(sm)?.muted == ThemeRGB(hex: "#414868"), "success and muted as sent")
    sm["success"] = "#1c1d28"; sm["muted"] = "#1b1c27"
    check(theme(sm)?.success == ThemeRGB(hex: "#a9b1d6"), "a success colour that melts in: the text colour")
    check(theme(sm)?.muted == ThemeRGB(hex: "#1a1b26")!.mix(ThemeRGB(hex: "#a9b1d6")!, 0.28), "a muted colour that melts in: a mix")
    check(theme(plain)?.muted == ThemeRGB(hex: "#1a1b26")!.mix(ThemeRGB(hex: "#a9b1d6")!, 0.28), "no muted colour: a mix")
    sm["success"] = "green"
    check(theme(sm) == nil, "success: #rrggbb only")

    // ---- the Mac's copy ----
    let dir = NSTemporaryDirectory() + "touchid-theme-\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let store = TouchIDThemeStore(dir: dir + "/touchid-theme")
    let vm = vmKeyName(type: "app", name: "Omarchy")
    let latte = theme(["background": "#eff1f5", "foreground": "#4c4f69", "accent": "#1e66f5", "error": "#d20f39", "radius": 4])!
    check(store.load(vm) == nil, "nothing kept yet")
    check(store.save(latte, for: vm), "kept")
    check(store.load(vm) == latte, "read back")
    var st = stat()
    check(stat(store.dir + "/\(vm).json", &st) == 0 && st.st_mode & 0o777 == 0o600, "file 0600")
    check(stat(store.dir, &st) == 0 && st.st_mode & 0o777 == 0o700, "folder 0700")
    check(!store.save(latte, for: "../x") && !store.save(latte, for: String(repeating: "A", count: 32)), "only a VM key name is a file name")
    check(store.load("../../etc/passwd") == nil, "no paths")
    try? "{\"background\":\"#000000\",\"foreground\":\"#010101\"}".write(toFile: store.dir + "/\(vm).json", atomically: true, encoding: .utf8)
    check(store.load(vm) == nil, "a copy that breaks the rules is not used")
    let other = vmKeyName(type: "app", name: "Other")
    try? FileManager.default.createSymbolicLink(atPath: store.dir + "/\(other).json", withDestinationPath: store.dir + "/\(vm).json")
    check(store.load(other) == nil, "a link is not read")
    store.save(latte, for: vm); store.remove(vm)
    check(store.load(vm) == nil, "removed")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    check(store.admit(vm, now: t0) == nil, "first theme")
    check(store.admit(vm, now: t0.addingTimeInterval(0.5))?.code == "rate", "one a second")
    check(store.admit(other, now: t0.addingTimeInterval(0.5)) == nil, "per VM")
    check(store.admit(vm, now: t0.addingTimeInterval(1.1)) == nil, "a second later")

    // ---- the panel's words are the alert's ----
    func after(_ reason: String) -> String? {
      if let r = reason.range(of: "): ") ?? reason.range(of: "Omarchy: ") { return String(reason[r.upperBound...]) }
      if let a = reason.firstIndex(of: "\""), let b = reason.lastIndex(of: "\""), a < b { return String(reason[reason.index(after: a)..<b]) }
      return nil
    }
    let reqs: [(TouchIDRequest, String?)] = [
      (TouchIDRequest(kind: .sudo, user: "v", detail: "pacman -Syu", action: "", tty: "pts/3"), nil),
      (TouchIDRequest(kind: .sudo, user: "v", detail: "pacman -Syu", action: ""), "Work"),
      (TouchIDRequest(kind: .sudo, user: "v", detail: "rm\n-rf\u{202E} / \u{200B}x", action: "", tty: "tty2"), nil),
      (TouchIDRequest(kind: .sudo, user: "v", detail: String(repeating: "b", count: 120), action: ""), "Work"),
      (TouchIDRequest(kind: .sudo, user: "v", detail: String(repeating: "c", count: 200), action: ""), nil),
      (TouchIDRequest(kind: .polkit, user: "v", detail: "", action: "org.freedesktop.systemd1.manage-units"), nil),
      (TouchIDRequest(kind: .polkit, user: "v", detail: "", action: "org.x.y"), "Work\u{202E}"),
    ]
    for (r, label) in reqs {
      let p = touchIDPanelText(r, vm: label), reason = touchIDReason(r, vm: label)
      check(p.box != nil && p.box == after(reason), "panel box == alert text: \(p.box ?? "nil") vs \(reason)")
      if let l = label { check(p.title.hasSuffix(" (\(touchIDClean(l, max: 40)))") && reason.contains(touchIDClean(l, max: 40)), "VM name the same") }
    }
    check(touchIDPanelText(reqs[0].0, vm: nil) == TouchIDPanelText(title: "Touch ID in Omarchy", line: "sudo in pts/3 wants to run", box: "pacman -Syu"), "sudo words")
    check(touchIDPanelText(reqs[2].0, vm: nil).box == "rm -rf / x", "cleaned like the alert")
    check(touchIDPanelText(reqs[3].0, vm: nil).box?.count == 120, "a whole 120-character command")
    check(touchIDPanelText(TouchIDRequest(kind: .sudo, user: "v", detail: "", action: "", tty: "pts/1"), vm: nil)
          == TouchIDPanelText(title: "Touch ID in Omarchy", line: "Run sudo in pts/1", box: nil), "sudo without a command")
    check(touchIDPanelText(TouchIDRequest(kind: .polkit, user: "v", detail: "", action: ""), vm: nil)
          == TouchIDPanelText(title: "Touch ID in Omarchy", line: "Allow a system request", box: nil), "polkit without an action")
    check(touchIDPanelText(TouchIDRequest(kind: .onePassword, user: "v", detail: "x", action: ""), vm: "Work")
          == TouchIDPanelText(title: "Touch ID in Omarchy (Work)", line: "Unlock 1Password", box: nil), "1Password: no box")

    // ---- OmacVM.app's panel: its answer line ----
    check(touchIDAppPanelOutcome("yes") == .yes, "app panel: yes")
    check(touchIDAppPanelOutcome("error") == nil, "app panel: error -> macOS's dialog")
    check(touchIDAppPanelOutcome("no cancelled") == .no(.cancelled) && touchIDAppPanelOutcome("no lockout") == .no(.lockout)
          && touchIDAppPanelOutcome("no not-front") == .no(.notFront) && touchIDAppPanelOutcome("no timeout") == .no(.timeout),
          "app panel: each no")
    for junk in ["YES", "yes ", "", "no", "ok", "yes\r", "no yes"] {
      check(touchIDAppPanelOutcome(junk) == .no(.failed), "app panel: \(junk.debugDescription) is never a yes")
    }
    let colours = OmarchyTheme.tokyoNight.panelColors
    check(Set(colours.keys) == ["background", "foreground", "accent", "error", "success", "muted"] && colours["success"] == "#9ece6a"
          && colours["muted"] == "#414868", "app panel: the colours it draws with")

    // ---- the decider hands the panel what it needs ----
    let pa = PromptAuth()
    let r = TouchIDRequest(kind: .sudo, user: "v", detail: "ls", action: "", tty: "pts/2")
    _ = TouchIDDecider(auth: pa, mac: FrontMac()).decide(vm: "app/Work", type: "app", on: true, request: r, vmLabel: "Work",
                                                         passwordFallback: false, theme: vm, now: t0)
    check(pa.prompts.count == 1 && pa.prompts[0].request == r && pa.prompts[0].vmType == "app" && pa.prompts[0].theme == vm
          && pa.prompts[0].vmLabel == "Work" && pa.prompts[0].reason == touchIDReason(r, vm: "Work"), "prompt")
    let pb = PromptAuth()
    _ = TouchIDDecider(auth: pb, mac: FrontMac()).decide(vm: "app/Work", type: "app", on: true, request: r, vmLabel: nil,
                                                         passwordFallback: false, appPanel: { _, _, _ in .yes }, now: t0)
    check(pb.prompts.first?.appPanel != nil && pa.prompts.first?.appPanel == nil, "the app's panel reaches the authenticator only when given")

    print("touchid-panel: \(tPassed) passed, \(tFailures) failed")
    exit(tFailures == 0 ? 0 : 1)
  }
}
