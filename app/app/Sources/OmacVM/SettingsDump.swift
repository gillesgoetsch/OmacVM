import Foundation
import OmacVMFeatures
import OmacVMUSB
import OmacVMUpdate
import OmacVMIcon
import OmacVMWindow

/// `OmacVM --settings-dump`: every setting of the VM window as the window
/// reads it, as JSON, and quit (no window; only what the window itself
/// would tidy on reading, such as an old USB file, is written). The app-wide
/// ones once, then each VM's. src/tests/app-settings.sh and the e2e checks
/// compare it before and after a relaunch, an update, `omacvm` and the
/// control centre (AGENTS.md, "The VM window's settings").
@MainActor
enum SettingsDump {
    nonisolated static let flag = "--settings-dump"

    static func app() -> [String: Any] {
        [
            "startFullScreen": Settings.startFullScreen,
            "keepDockAway": Settings.keepDockAway,
            "audioThread": Settings.audioThread,
            "gpuOffMainLoop": Settings.gpuOffMainLoop,
            "shareKeyboard": Settings.shareKeyboard,
            "vkWindowsNoCopy": Settings.vkWindowsNoCopy,
            "hdr": Settings.hdr,
            "extraBrightness": Settings.extraBrightness,
            "pauseWhileHidden": Settings.pauseWhileHidden,
            "pointerPlane": Settings.pointerPlane,
            "presentTiles": Settings.presentTiles,
            "ghosttyGPU": Settings.ghosttyGPU,
            "mediaControls": Settings.mediaControls,
            "closeAction": Settings.closeAction.rawValue,
            "appIconTheme": IconTheme.choice(stored: UserDefaults.standard.object(forKey: IconTheme.key)).id,
            "escapeSwipe": EscapeSetting.current().rawValue,
            "mouseSwipeFingers": MouseSwipeSetting.current(),
            "swipeOut": SwipeOutSetting.current(),
            "updateChecks": SharedSettings.standard.updateChecks,
            "vmsRoot": Paths.vmsRoot.path,
        ]
    }

    static func vm(_ c: VMConfig) -> [String: Any] {
        let f = c.folder
        let record = try? String(contentsOf: f.appendingPathComponent("features"), encoding: .utf8)
        let pending = try? String(contentsOf: f.appendingPathComponent(MacIME.pendingFile), encoding: .utf8)
        let mode = NotchArea.read(folder: f)
        return [
            "name": c.name,
            "cpus": c.cpus,
            "memoryGB": c.memoryMB / 1024,
            "diskGB": c.diskGB,
            "graphics": Graphics.read(folder: f).rawValue,
            "notchMode": mode.rawValue,
            "notchSkip": NotchSkip.read(folder: f),
            // As a Mac with a notch shows it (a Mac without one shows Full screen for both).
            "startIn": StartIn.current(fullScreen: Settings.startFullScreen, mode: mode, hasNotch: true).rawValue,
            "macFolder": MacFolder.path(c) ?? "",
            "usb": USBSwitch.isOn(folder: f),
            "usbRemembered": USBMemory.load(folder: f).devices.count,
            "fastNetwork": FastNetwork.isOn(c),
            "macIME": MacIME.pending(pending) ?? MacIME.isOn(features: record),
            "gpuCompute": GPUCompute.switchState.pending(
                try? String(contentsOf: f.appendingPathComponent(GPUCompute.pendingFile), encoding: .utf8)) ?? GPUCompute.isOn(features: record),
        ]
    }

    static func main() -> Never {
        let all: [String: Any] = ["app": app(), "vms": VMConfig.all().map(vm)]
        let data = (try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    }
}
