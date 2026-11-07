// usage: swift set-icon.swift <image.icns|png> <path> — sets a Finder custom icon
import AppKit
let img = NSImage(contentsOfFile: CommandLine.arguments[1])!
let ok = NSWorkspace.shared.setIcon(img, forFile: CommandLine.arguments[2], options: [])
print(ok ? "icon set: \(CommandLine.arguments[2])" : "FAILED: \(CommandLine.arguments[2])")
