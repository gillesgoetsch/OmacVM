// The Touch ID panel (touchid_panel.swift) without the Bridge:
//   panel-tests mock [<png dir>]   the panel's flow with a mock evaluation, and
//                                  snapshots drawn off screen. No window is ever
//                                  ordered on screen, no LAContext is made: safe
//                                  on a Mac someone works at.
//   panel-tests live <scenario> [theme] [style]
//                                  a real panel over the frontmost app's window
//                                  with Apple's embedded Touch ID view, for a
//                                  test Mac (tests/panel/live.sh). Prints the result.
// Built by tests/panel/build.sh with the fonts beside it.
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

var tFailures = 0, tPassed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { tPassed += 1 } else { tFailures += 1; print("FAIL line \(line): \(what)") }
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().path
TouchIDPanelFonts.register(here)
let icon = NSImage(contentsOfFile: here + "/omacvm.png")
let marker: Int64 = 0x0BAC_0E5C   // VMKeys.marker (vm-keys.swift)

/// Stock themes from the fixture (tests/fixtures/omarchy-themes.tsv), as a VM sends them.
func stockTheme(_ name: String, border: [String]? = nil, angle: Double = 0, radius: Double = 0) -> OmarchyTheme {
  let tsv = (try? String(contentsOfFile: here + "/omarchy-themes.tsv", encoding: .utf8)) ?? ""
  for line in tsv.split(separator: "\n") where line.hasPrefix(name + "\t") {
    let f = line.split(separator: "\t").map(String.init)
    let o: [String: Any] = ["background": f[1], "foreground": f[2], "accent": f[3], "error": f[4], "border": border ?? [f[3]],
                            "border_angle": angle, "radius": radius]
    if case .success(let t) = parseTouchIDTheme(try! JSONSerialization.data(withJSONObject: o)) { return t }
  }
  return .tokyoNight
}

let sudo = TouchIDRequest(kind: .sudo, user: "v", detail: "pacman -Syu", action: "", tty: "pts/3")
let long = TouchIDRequest(kind: .sudo, user: "v",
  detail: String("yay -S --needed --noconfirm base-devel git rustup python-pipx docker docker-compose lazydocker btop fastfetch zoxide".prefix(120)),
  action: "", tty: "pts/12")

func on(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
func onSync<T>(_ f: () -> T) -> T { DispatchQueue.main.sync(execute: f) }

// ---- mock: the flow, never on screen ----

func mock(_ out: String?) {
  let place: (_ size: (TouchIDPanelStyle) -> CGSize) -> TouchIDPanelPlacement? = { size in
    TouchIDPanelPlacement(style: .window, frame: CGRect(origin: CGPoint(x: 100, y: 100), size: size(.window)), screen: 0)
  }
  /// A flow whose evaluation answers `answer` after `after` s (nil: never, only a stop ends it).
  func flow(_ answer: TouchIDLAEnd?, after: Double = 0.05, text: TouchIDPanelText? = nil) -> (TouchIDPanelFlow, () -> Int) {
    let f = TouchIDPanelFlow(theme: .tokyoNight, text: text ?? touchIDPanelText(sudo, vm: nil), icon: icon, marker: marker)
    f.present = false
    f.poll = 0.02
    f.place = place
    var stops = 0
    var reply: ((TouchIDLAEnd) -> Void)?
    let l = NSLock()
    f.start = { done in
      l.lock(); reply = done; l.unlock()
      if let a = answer { DispatchQueue.global().asyncAfter(deadline: .now() + after) { done(a) } }
    }
    f.stop = { l.lock(); stops += 1; let r = reply; reply = nil; l.unlock(); r?(.cancelled) }
    return (f, { l.lock(); defer { l.unlock() }; return stops })
  }
  func whileUp(_ f: TouchIDPanelFlow, _ act: @escaping (TouchIDPanel) -> Void) {
    DispatchQueue.global().async {
      for _ in 0..<200 {
        if let p = onSync({ f.panel }) { on { act(p) }; return }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
  }

  var (f, stops) = flow(.yes)
  if case .ended(let e, let t) = f.run(timeout: 5, gone: { false }) { check(e == .yes && t < 1, "yes, at once") } else { check(false, "yes") }
  check(onSync { f.panel } == nil, "closed after")

  (f, stops) = flow(nil)
  whileUp(f) { _ = $0.view.cancel.accessibilityPerformPress() }
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.cancelled)) && stops() == 1, "Cancel: cancelled, the evaluation stopped")

  (f, stops) = flow(nil)
  whileUp(f) { p in
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: p.window.windowNumber,
                             context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    p.window.keyDown(with: e)
  }
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.cancelled)), "Esc cancels")

  (f, stops) = flow(nil)
  whileUp(f) { p in
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: p.window.windowNumber,
                             context: nil, characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47)!
    _ = p.window.performKeyEquivalent(with: e)
  }
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.cancelled)), "Cmd-. cancels")

  // Return, and an Esc with OmacVM's marker (a VM can cause those): nothing; then the finger.
  (f, stops) = flow(.yes, after: 0.4)
  whileUp(f) { p in
    let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: p.window.windowNumber,
                               context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    p.window.keyDown(with: ret)
    let cg = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!   // made, never posted
    cg.setIntegerValueField(.eventSourceUserData, value: marker)
    if let e = NSEvent(cgEvent: cg) { p.window.sendEvent(e) }
  }
  if case .ended(let e, _) = f.run(timeout: 5, gone: { false }) { check(e == .yes, "Return and a marked Esc do nothing") }
  else { check(false, "Return and a marked Esc do nothing") }

  (f, stops) = flow(nil)
  let t0 = Date()
  check(f.run(timeout: 0.3, gone: { false }) == .done(.no(.timeout)) && Date().timeIntervalSince(t0) < 1.5 && stops() == 1, "timeout")
  (f, stops) = flow(nil)
  var gone = false
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gone = true }
  check(f.run(timeout: 5, gone: { gone }) == .done(.no(.cancelled)), "the VM's client went away (Ctrl+C)")
  (f, stops) = flow(nil)
  var front = true
  f.interrupt = { front ? nil : .notFront }
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { front = false }
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.notFront)), "another app in front: closed")
  (f, stops) = flow(nil)
  f.interrupt = { .locked }
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.locked)), "the Mac locked: closed")
  (f, stops) = flow(.other, after: 0.05)
  if case .ended(let e, let t) = f.run(timeout: 5, gone: { false }) { check(e == .other && t < TouchIDPanelGate.fast, "a fast error comes back for the gate") }
  else { check(false, "fast error") }
  (f, stops) = flow(.yes)
  f.place = { _ in nil }
  check(f.run(timeout: 5, gone: { false }) == .noWindow, "no VM window: the alert")
  // Cancel stops the evaluation at once, not at the next poll.
  (f, stops) = flow(nil)
  f.poll = 1
  whileUp(f) { _ = $0.view.cancel.accessibilityPerformPress() }
  let tc = Date()
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.cancelled)) && stops() == 1 && Date().timeIntervalSince(tc) < 0.8,
        "Cancel stops the evaluation at once")
  // Cancel wins over a finger that matches right after it.
  var stops0 = 0
  (f, stops) = flow(.yes, after: 0.3)
  f.poll = 1
  f.stop = { stops0 += 1 }   // this evaluation does not end on its stop: the finger comes anyway
  whileUp(f) { _ = $0.view.cancel.accessibilityPerformPress() }
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.cancelled)) && stops0 == 1, "Cancel, then a finger: no")
  // Cancel twice, and a Cancel after the end: one end.
  (f, stops) = flow(nil)
  whileUp(f) { p in _ = p.view.cancel.accessibilityPerformPress(); _ = p.view.cancel.accessibilityPerformPress() }
  check(f.run(timeout: 5, gone: { false }) == .done(.no(.cancelled)) && stops() == 1, "two Cancels: one end")

  onSync {   // AppKit objects on the main thread
    // The panel: borderless, non-activating, level 28, never movable; shadow only windowed.
    let v = TouchIDPanelView(theme: .tokyoNight, text: touchIDPanelText(sudo, vm: nil), style: .window, icon: icon, auth: TouchIDGlyphStandIn())
    let p = TouchIDPanel(view: v, placement: TouchIDPanelPlacement(style: .window, frame: CGRect(x: 0, y: 0, width: 360, height: v.frame.height), screen: 0),
                         marker: marker) {}
    check(p.window.styleMask.contains(.nonactivatingPanel) && p.window.styleMask.contains(.borderless), "non-activating, borderless")
    check(p.window.level.rawValue == 28 && !p.window.isMovable && p.window.hasShadow && p.window.canBecomeKey && !p.window.canBecomeMain, "level, key, not main")
    check(p.window.collectionBehavior.contains(.fullScreenAuxiliary) && p.window.collectionBehavior.contains(.moveToActiveSpace), "over full screen")
    check(!p.window.isVisible, "never on screen in the mock")
    check(v.accessibilityLabel() == "Touch ID in Omarchy: sudo in pts/3 wants to run: pacman -Syu. Touch ID to allow", "VoiceOver reads the words")
    check(p.window.accessibilitySubrole() == .dialog && p.window.accessibilityTitle() == "Touch ID in Omarchy", "VoiceOver: a dialog with its title")
    let n = TouchIDPanelView(theme: stockTheme("catppuccin-latte"), text: touchIDPanelText(sudo, vm: nil), style: .notch, icon: icon, auth: TouchIDGlyphStandIn())
    let pn = TouchIDPanel(view: n, placement: TouchIDPanelPlacement(style: .notch, frame: n.frame, screen: 0), marker: marker) {}
    check(!pn.window.hasShadow && pn.window.appearance?.name == .aqua, "notch card: no shadow; light theme, light appearance")
    check(n.frame.height < v.frame.height, "the notch card has no icon")
    let lv = TouchIDPanelView(theme: .tokyoNight, text: touchIDPanelText(long, vm: "Work"), style: .window, icon: icon, auth: TouchIDGlyphStandIn())
    check(lv.frame.height > v.frame.height + 20, "a long command wraps, whole")

    // ---- snapshots ----
    if let out = out {
      try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
      func shot(_ theme: OmarchyTheme, _ r: TouchIDRequest, _ vm: String?, _ style: TouchIDPanelStyle, _ name: String) {
        let v = TouchIDPanelView(theme: theme, text: touchIDPanelText(r, vm: vm), style: style, icon: icon, auth: TouchIDGlyphStandIn())
        guard let d = v.png() else { check(false, "snapshot \(name)"); return }
        check((try? d.write(to: URL(fileURLWithPath: out + "/" + name))) != nil, "snapshot \(name)")
        print("  \(out)/\(name)")
      }
      shot(.tokyoNight, sudo, nil, .window, "snap-dark.png")
      shot(stockTheme("catppuccin-latte"), TouchIDRequest(kind: .onePassword, user: "v", detail: "", action: ""), nil, .window, "snap-light.png")
      shot(stockTheme("flexoki-light"), sudo, nil, .window, "snap-light-sudo.png")
      shot(.tokyoNight, long, "Work", .window, "snap-long.png")
      shot(stockTheme("solitude", border: ["#798186", "#cacccc"], angle: 45, radius: 6),
           TouchIDRequest(kind: .polkit, user: "v", detail: "", action: "org.freedesktop.systemd1.manage-units"), nil, .window, "snap-rounded-gradient.png")
      shot(stockTheme("gruvbox"), TouchIDRequest(kind: .polkit, user: "v", detail: "", action: ""), nil, .window, "snap-polkit-generic.png")
      shot(.tokyoNight, sudo, nil, .notch, "snap-notch.png")
      shot(stockTheme("rose-pine"), sudo, nil, .notch, "snap-notch-light.png")
      // Stacked combining marks stay inside the command's box.
      shot(.tokyoNight, TouchIDRequest(kind: .sudo, user: "v", detail: "ls a" + String(repeating: "\u{0301}", count: 60) + " b",
                                       action: "", tty: "pts/3"), nil, .window, "snap-combining.png")
    }
  }
}

// ---- live: a real panel on a test Mac ----

/// Scenarios: wait (until the finger, Cancel, Esc or the timeout), timeout (5 s), cancel (Cancel pressed by
/// AX after 3 s), notfront (closes when another app comes to the front).
func live(_ scenario: String, theme name: String, vm: String?) {
  let theme = name == "tokyo-night" ? OmarchyTheme.tokyoNight
    : name == "solitude" ? stockTheme("solitude", border: ["#798186", "#cacccc"], angle: 45, radius: 6) : stockTheme(name)
  let c = LAContext()
  c.touchIDAuthenticationAllowableReuseDuration = 0
  c.localizedFallbackTitle = ""
  var e: NSError?
  print("canEvaluate biometrics: \(c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)) \(e.map { "\($0.code)" } ?? "")")
  let frontApp = onSync { NSWorkspace.shared.frontmostApplication }
  print("front app: \(frontApp?.localizedName ?? "-") pid \(frontApp?.processIdentifier ?? 0)")
  let f = TouchIDPanelFlow(theme: theme, text: touchIDPanelText(sudo, vm: vm), icon: icon, marker: marker)
  var placed: TouchIDPanelPlacement?
  f.place = { size in
    guard let app = NSWorkspace.shared.frontmostApplication, let w = touchIDFrontWindow(pid: app.processIdentifier) else { return nil }
    print("window: \(w)  screens: \(touchIDPanelScreens())")
    placed = touchIDPanelPlacement(window: w, screens: touchIDPanelScreens(), size: size)
    return placed
  }
  var authView: NSView?
  f.authView = { let v = LAAuthenticationView(context: c, controlSize: .regular); authView = v; return v }
  f.start = { done in
    c.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "run sudo in Omarchy (pts/3): pacman -Syu") { ok, err in
      print("evaluatePolicy: ok=\(ok) error=\((err as NSError?).map { "\($0.domain) \($0.code)" } ?? "-")")
      if ok { done(.yes); return }
      switch (err as? LAError)?.code {
      case .userCancel?, .appCancel?, .systemCancel?, .userFallback?: done(.cancelled)
      case .biometryLockout?: done(.lockout)
      case .biometryNotAvailable?, .biometryNotEnrolled?, .passcodeNotSet?: done(.notAvailable)
      case .authenticationFailed?: done(.failed)
      default: done(.other)
      }
    }
  }
  f.stop = { c.invalidate() }
  if scenario == "notfront" {
    let pid = frontApp?.processIdentifier
    f.interrupt = { onSync { NSWorkspace.shared.frontmostApplication?.processIdentifier } != pid ? .notFront : nil }
  }
  if scenario == "cancel" {
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { on { _ = f.panel?.view.cancel.accessibilityPerformPress() } }
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
    on {
      guard let p = f.panel else { return }
      print("panel: \(p.window.frame) style \(p.placement.style) key=\(p.window.isKeyWindow) visible=\(p.window.isVisible) "
            + "app active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-") "
            + "auth view \(authView?.frame ?? .zero) fitting \(authView?.fittingSize ?? .zero) window id \(p.window.windowNumber)")
      try? "\(p.window.windowNumber)".write(toFile: "/tmp/touchid-panel.window", atomically: true, encoding: .utf8)
    }
  }
  let t0 = Date()
  let r = f.run(timeout: scenario == "timeout" ? 5 : 30, gone: { false })
  c.invalidate()
  print("result: \(r) after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; placed \(String(describing: placed))")
  print("front after: \(onSync { NSWorkspace.shared.frontmostApplication?.localizedName ?? "-" })")
}

let app = NSApplication.shared
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "mock"
app.setActivationPolicy(mode == "live" ? .accessory : .prohibited)
DispatchQueue.global().async {
  if mode == "live" {
    live(args.count > 2 ? args[2] : "wait", theme: args.count > 3 ? args[3] : "tokyo-night", vm: args.count > 4 ? args[4] : nil)
    exit(0)
  }
  mock(args.count > 2 ? args[2] : nil)
  print("touchid panel (mock): \(tPassed) passed, \(tFailures) failed")
  exit(tFailures == 0 ? 0 : 1)
}
app.run()
