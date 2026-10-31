// The VM window's settings across launches: src/tests/app-settings.sh.
//   t dump                 the settings as the window reads them (SettingsDump)
//   t start                what a start of a VM reads: Extra brightness and HDR for it
//   t ghostty VENUS DRIVER what a start reads for Ghostty on the Mac's GPU, with or without Venus
//                          (1/0) on that Vulkan driver (kosmickrisp, moltenvk, listed)
//   t retire               what a launch does with retired switches (Settings.removeRetiredSwitches)
//   t mediadefault ID      AirPods and media controls' default for that bundle id
//   t set KEY VALUE [VM]   one change, made with the call the window's row makes
import AppKit
import Foundation
import OmacVMUSB
import OmacVMUpdate
import OmacVMIcon
import OmacVMWindow
import OmacVMFeatures

MainActor.assumeIsolated {
    // The icon's look goes to the Dock (NSApp) too: an app, never shown.
    NSApplication.shared.setActivationPolicy(.prohibited)
    let a = CommandLine.arguments
    guard a.count > 1 else { exit(2) }
    if a[1] == "dump" { SettingsDump.main() }
    if a[1] == "start" {   // what a start of a VM reads (Runner.start), printed; nothing is written
        let x = Settings.extraBrightnessStart(), h = Settings.hdrStart(), t = Settings.presentTilesStart()
        print("extra \(x.on) (\(x.why)), hdr \(h.on) (\(h.why)), tiles \(t.on) (\(t.why))")
        exit(0)
    }
    if a[1] == "ghostty", a.count > 3 {   // Ghostty on the Mac's GPU at a start (Runner.arguments)
        let d: VulkanDriverKind = a[3] == "kosmickrisp" ? .kosmicKrisp : a[3] == "moltenvk" ? .moltenVK : .listed
        let g = Settings.ghosttyGPUStart(venus: a[2] == "1", driver: d)
        print("ghostty \(g.on) (\(g.why))")
        exit(0)
    }
    if a[1] == "retire" { Settings.removeRetiredSwitches(); exit(0) }
    if a[1] == "mediadefault" {   // the switch's default for a bundle id (TestIdentity)
        print(Settings.mediaControlsDefault(bundleID: a.count > 2 ? a[2] : nil))
        exit(0)
    }
    guard a[1] == "set", a.count > 3 else { exit(2) }
    let key = a[2], value = a[3]
    let vm = a.count > 4 ? VMConfig.named(a[4]) : nil
    func need() -> VMConfig {
        guard let vm else { FileHandle.standardError.write(Data("no VM \(a.count > 4 ? a[4] : "")\n".utf8)); exit(1) }
        return vm
    }
    do {
        switch key {
        // App-wide (every VM).
        case "startFullScreen": Settings.startFullScreen = value == "true"
        case "keepDockAway": Settings.keepDockAway = value == "true"
        case "audioThread": Settings.audioThread = value == "true"
        case "gpuOffMainLoop": Settings.gpuOffMainLoop = value == "true"
        case "shareKeyboard": Settings.shareKeyboard = value == "true"
        case "vkWindowsNoCopy": Settings.vkWindowsNoCopy = value == "true"
        case "hdr": Settings.hdr = value == "true"
        case "extraBrightness": Settings.extraBrightness = value == "true"
        case "pauseWhileHidden": Settings.pauseWhileHidden = value == "true"
        case "pointerPlane": Settings.pointerPlane = value == "true"
        case "presentTiles": Settings.presentTiles = value == "true"
        case "ghosttyGPU": Settings.ghosttyGPU = value == "true"
        case "mediaControls": Settings.mediaControls = value == "true"
        case "closeAction": Settings.closeAction = CloseAction.parse(value)
        case "appIconTheme": AppIcon.set(IconTheme.choice(stored: value))
        case "escapeSwipe": EscapeSetting.set(EscapeSetting.Choice(rawValue: value) ?? .pointer)
        case "mouseSwipeFingers": MouseSwipeSetting.set(Int(value) ?? 4)
        case "swipeOut": SwipeOutSetting.set(value == "true")
        case "updateChecks": try SharedSettings.standard.setUpdateChecks(value == "true")
        // Per VM.
        case "resources":   // CPUS:GB
            var c = need()
            let p = value.split(separator: ":").compactMap { Int($0) }
            c.cpus = p[0]; c.memoryMB = p[1] * 1024
            try c.writeResources()
        case "graphics": try Graphics.write(GraphicsChoice(rawValue: value) ?? .auto, folder: need().folder)
        case "notchMode": try NotchArea.write(NotchMode(rawValue: value) ?? .native, folder: need().folder)
        case "notchSkip": try NotchSkip.write(value == "true", folder: need().folder)
        case "macFolder": try MacFolder.set(value.isEmpty ? nil : URL(fileURLWithPath: value), for: need())
        case "usb": try USBSwitch.set(value == "true", folder: need().folder)
        case "usbRemember":
            try USBMemory(devices: [.init(vendor: "0483", product: "3748", name: value, maker: "STMicroelectronics",
                                          choice: .omarchy, since: "2026-10-12")]).save(folder: need().folder)
        case "macIME":   // the VM stopped: the record and the pending file (MacIMERow.write)
            let f = need().folder
            let record = try? String(contentsOf: f.appendingPathComponent("features"), encoding: .utf8)
            let pending = try? String(contentsOf: f.appendingPathComponent(MacIME.pendingFile), encoding: .utf8)
            let next = MacIME.switchStopped(record: record, pending: pending, on: value == "true")
            try next.record.write(to: f.appendingPathComponent("features"), atomically: true, encoding: .utf8)
            if let p = next.pending { try p.write(to: f.appendingPathComponent(MacIME.pendingFile), atomically: true, encoding: .utf8) }
        default:
            FileHandle.standardError.write(Data("unknown setting \(key)\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("\(key): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}
