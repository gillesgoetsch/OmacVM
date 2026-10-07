#!/bin/bash
# OmacVM.app's own window on the Mac's real displays: it opens centred on the
# built-in display (else the main one), as the app opens it (SwiftUI sizes the
# window after it is shown: it stays centred). Compiles
# AppWindowPlacement.swift and WindowPlacement.swift into a small throwaway
# app (own bundle id, no settings, no VM), opens it, reads where the window
# went. Needs a logged-in screen. With --old: NSWindow.center() as before 3.0.1.
# For a second display without a monitor: app/scripts/dev/virtual-display.m.
#   src/tests/app-window-real.sh [--old]
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
MODE=${1:-new}
A="$T/Window Test.app"
mkdir -p "$A/Contents/MacOS"
cat > "$A/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.omacvm.test.window-placement</string>
<key>CFBundleExecutable</key><string>t</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><false/>
</dict></plist>
PLIST
cat > "$T/main.swift" <<'SWIFT'
import AppKit
import SwiftUI
let out = CommandLine.arguments[1], old = CommandLine.arguments[2] == "--old"
// Like RootView: SwiftUI sizes the window, and grows it a moment later.
struct V: View {
    @State var tall = false
    var body: some View {
        Color.gray.frame(width: 640, height: tall ? 560 : 420)
            .onAppear { DispatchQueue.main.async { tall = true } }
    }
}
final class D: NSObject, NSApplicationDelegate {
    var w: NSWindow?
    var c: CentredWindow?
    var mainAtStart: NSScreen?
    func applicationDidFinishLaunching(_ n: Notification) {
        mainAtStart = NSScreen.main
        NSApp.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: V())
        w.isReleasedWhenClosed = false
        self.w = w
        c = CentredWindow(w)
        if old { w.center() } else { c?.place() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.report() }
    }
    func report() {
        guard let w else { return }
        func id(_ s: NSScreen) -> UInt32 { s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0 }
        var lines: [String] = []
        for s in NSScreen.screens {
            lines.append("screen \(id(s)) builtin=\(CGDisplayIsBuiltin(id(s)) != 0) primary=\(s == NSScreen.screens.first) main=\(s == mainAtStart) visible=\(s.visibleFrame)")
        }
        let f = w.frame
        lines.append("window \(f) on=\(w.screen.map(id) ?? 0)")
        let builtIn = NSScreen.screens.first { CGDisplayIsBuiltin(id($0)) != 0 }
        let want = builtIn ?? mainAtStart ?? NSScreen.screens.first!
        let v = want.visibleFrame
        let onIt = w.screen == want
        // 2 points: the menu bar's height can change while the app comes forward.
        let centred = abs(f.midX - v.midX) <= 2 && abs(f.midY - v.midY) <= 2
        lines.append("\(onIt ? "ok  " : "FAIL") on the \(builtIn != nil ? "built-in" : "main") display")
        lines.append("\(centred ? "ok  " : "FAIL") centred (window middle \(f.midX),\(f.midY), display middle \(v.midX),\(v.midY))")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        exit(onIt && centred ? 0 : 1)
    }
}
let d = D()
NSApplication.shared.delegate = d
NSApp.run()
SWIFT
swiftc -module-cache-path "$T/mc" -o "$A/Contents/MacOS/t" "$R/app/app/Sources/OmacVM/WindowPlacement.swift" \
  "$R/app/app/Sources/OmacVM/AppWindowPlacement.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL AppWindowPlacement.swift does not compile on its own"; exit 1; }
codesign -s - --force "$A" >/dev/null 2>&1
open -n -W "$A" --args "$T/out" "$MODE"
[[ -f $T/out ]] || { echo "FAIL the window test wrote nothing (no screen?)"; exit 1; }
cat "$T/out"
! grep -q '^FAIL' "$T/out"
