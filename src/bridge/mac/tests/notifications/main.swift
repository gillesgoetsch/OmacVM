// The Mac's notifications on screen, through the Bridge's own code
// (notifications.swift), for ../../test-notifications.sh. It prints no
// notification's text: the others on screen may hold personal data.
//   notifications-live count        how many it would close
//   notifications-live shows TEXT   exit 0 when one of them says TEXT
//   notifications-live close        closes them all: {"found": N, "closed": N}
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "count":
  print(MacNotifications.onScreen().count)
case "shows" where args.count == 2:
  let says = MacNotifications.onScreen().contains { n in
    var text: AnyObject?
    AXUIElementCopyAttributeValue(n.element.ref, kAXDescriptionAttribute as CFString, &text)
    return (text as? String)?.contains(args[1]) == true
  }
  exit(says ? 0 : 1)
case "close":
  guard AXIsProcessTrusted() else { print("no Accessibility permission"); exit(1) }
  let r = MacNotifications.closeOnScreen()
  print("{\"found\": \(r.found), \"closed\": \(r.closed)}")
default:
  print("usage: notifications-live count | shows TEXT | close"); exit(2)
}
