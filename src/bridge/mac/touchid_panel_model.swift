// Touch ID panel (ADR 0041, addendum 3.0.2), the parts without AppKit: the
// words, where the panel goes, which keys cancel, when macOS's own alert is
// used instead, and that a panel ends once. touchid_panel.swift draws it;
// tests/touchid runs this file as is.
import CoreGraphics
import Foundation

/// What the panel says. Only from the request the Bridge verified, cleaned
/// as for touchIDReason: the box holds exactly what the alert would show.
struct TouchIDPanelText: Equatable {
  var title: String   // "Touch ID in Omarchy", " (VM)" with several VMs
  var line: String    // who asks, plain
  var box: String?    // the command or polkit action, mono, whole
}

func touchIDPanelText(_ r: TouchIDRequest, vm: String?) -> TouchIDPanelText {
  let title = "Touch ID in Omarchy" + (vm.map { " (\(touchIDClean($0, max: 40)))" } ?? "")
  switch r.kind {
  case .onePassword: return TouchIDPanelText(title: title, line: "Unlock 1Password", box: nil)
  case .sudo:
    let at = r.tty.isEmpty ? "" : " in \(r.tty)"
    let cmd = touchIDClean(r.detail, max: touchIDCommandMax)
    return cmd.isEmpty ? TouchIDPanelText(title: title, line: "Run sudo\(at)", box: nil)
                       : TouchIDPanelText(title: title, line: "sudo\(at) wants to run", box: cmd)
  case .polkit:
    return TouchIDPanelText(title: title, line: "Allow a system request", box: r.action.isEmpty ? nil : r.action)
  }
}

/// OmacVM.app's line for its panel's end (TouchIDPanelResult.bridgeLine) ->
/// the outcome; nil for "error": the panel could not show. Anything else is
/// a failure (never a yes).
func touchIDAppPanelOutcome(_ line: String) -> TouchIDOutcome? {
  switch line {
  case "yes": return .yes
  case "error": return nil
  case "no cancelled": return .no(.cancelled)
  case "no timeout": return .no(.timeout)
  case "no lockout": return .no(.lockout)
  case "no no-touch-id": return .no(.noTouchID)
  case "no not-front": return .no(.notFront)
  case "no locked": return .no(.locked)
  default: return .no(.failed)
  }
}
