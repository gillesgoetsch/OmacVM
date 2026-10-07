// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmacVM",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "OmacVM", targets: ["OmacVM"]),
        // Touch ID's panel, loaded by QEMU (the VM window's process):
        // omacvm-cocoa-touchid-panel.patch, docs/adr/0041-touch-id.md.
        .library(name: "OmacVMTouchIDPanel", type: .dynamic, targets: ["OmacVMTouchIDPanel"]),
    ],
    targets: [
        .executableTarget(name: "OmacVM", dependencies: ["OmacVMUpdate", "OmacVMNet", "OmacVMUSB", "OmacVMFolder", "OmacVMFeatures", "OmacVMAuth", "OmacVMBuildProgress", "OmacVMWindow", "OmacVMDesktop", "OmacVMAudio"]),
        // The self-update's checks, apart from the UI so they can be tested
        // without Xcode: `swift run update-tests`.
        .target(name: "OmacVMUpdate"),
        .executableTarget(name: "update-tests", dependencies: ["OmacVMUpdate"]),
        // A release's feed and zip, checked as an installed app checks them
        // (src/release/release.sh verify).
        .executableTarget(name: "feed-check", dependencies: ["OmacVMUpdate"]),
        // When a running VM changes network (fast network <-> user network),
        // apart from QMP so it can be tested without a VM: `swift run net-tests`.
        .target(name: "OmacVMNet"),
        .executableTarget(name: "net-tests", dependencies: ["OmacVMNet"]),
        // The VM's USB devices: which ones the Mac lets a VM have, the VM's
        // choice and QEMU's arguments, without a VM: `swift run usb-tests`.
        .target(name: "OmacVMUSB"),
        .executableTarget(name: "usb-tests", dependencies: ["OmacVMUSB"]),
        // The Mac folder's QEMU arguments: `swift run folder-tests`.
        .target(name: "OmacVMFolder"),
        .executableTarget(name: "folder-tests", dependencies: ["OmacVMFolder"]),
        // The features a new VM starts with (Omanotch on with a notch):
        // `swift run features-tests`.
        .target(name: "OmacVMFeatures"),
        .executableTarget(name: "features-tests", dependencies: ["OmacVMFeatures"]),
        // The build window's progress lines, speed, time left and log tail,
        // without a VM: `swift run build-progress-tests`.
        .target(name: "OmacVMBuildProgress"),
        .executableTarget(name: "build-progress-tests", dependencies: ["OmacVMBuildProgress"]),
        // The VM window's rules: custom resources, disk Grow/Compact,
        // "omacvm in Terminal", the keyboard note: `swift run window-tests`.
        .target(name: "OmacVMWindow"),
        .executableTarget(name: "window-tests", dependencies: ["OmacVMWindow"]),
        // "Restart the Desktop…" in QEMU's app menu after Later on the
        // desktop-lost window: `swift run desktop-tests`.
        .target(name: "OmacVMDesktop"),
        .executableTarget(name: "desktop-tests", dependencies: ["OmacVMDesktop"]),
        // The sound delay the app tells a VM (QEMU's buffers and the Mac's
        // output device), so its players keep the picture in step:
        // `swift run audio-tests`.
        .target(name: "OmacVMAudio"),
        .executableTarget(name: "audio-tests", dependencies: ["OmacVMAudio"]),
        // Touch ID's port for the app's VMs (org.omacvm.auth), relayed to
        // OmacVM Bridge: `swift run auth-tests`.
        .target(name: "OmacVMAuth"),
        .executableTarget(name: "auth-tests", dependencies: ["OmacVMAuth"]),
        // Its panel in the VM's window (QEMU loads the dylib): `swift run touchid-panel-tests`.
        .target(name: "OmacVMTouchIDPanel", dependencies: ["OmacVMAuth"]),
        .executableTarget(name: "touchid-panel-tests", dependencies: ["OmacVMTouchIDPanel", "OmacVMAuth"]),
    ],
    swiftLanguageModes: [.v5]
)
