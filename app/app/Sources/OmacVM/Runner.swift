import AppKit
import AVFoundation
import Foundation

/// Runs one VM: QEMU with its own Cocoa window (VirGL), a QMP socket for
/// power and pause, and the Mac's sleep and wake.
@MainActor
final class Runner {
    let config: VMConfig
    private(set) var process: Process?
    private let sleep = VMHostSleepCoordinator()
    private var observers: [NSObjectProtocol] = []
    var onExit: ((Int32) -> Void)?

    init(config: VMConfig) { self.config = config }

    var isRunning: Bool { process?.isRunning ?? false }

    /// virtio-gpu outputs: the window and up to four more Mac displays.
    static let maxOutputs = 5

    func arguments() -> [String] {
        let c = config
        // QEMU option values split at commas; a comma in a value is written twice.
        func q(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ",,") }
        // Omarchy draws its own pointer once omacvm apply has written guest-pointer;
        // older VMs keep the Mac's pointer.
        let guestPointer = FileManager.default.fileExists(
            atPath: c.folder.appendingPathComponent("guest-pointer").path)
        var a: [String] = [
            "-name", q(c.name),
            "-machine", "virt,gic-version=3",
            "-accel", "hvf",
            // HVF has no usable guest PMU on Apple Silicon.
            "-cpu", "host,pmu=off",
            "-smp", "\(c.cpus),sockets=1,cores=\(c.cpus),threads=1",
            "-m", "\(c.memoryMB)M",
            "-nodefaults",
            "-action", "reboot=reset,shutdown=poweroff",
            // UEFI firmware (read-only) and this VM's own boot variables.
            "-drive", "if=pflash,format=raw,readonly=on,file=\(q(Paths.firmware.path))",
            "-drive", "if=pflash,format=raw,file=\(q(c.efiVars.path))",
            "-drive", "if=none,id=disk,file=\(q(c.disk.path)),format=raw,cache=writeback,discard=unmap",
            "-device", "nvme,serial=omacvm,drive=disk,bootindex=0",
            // QEMU's user network: the Mac is 10.0.2.2 for the VM; SSH from the Mac on 127.0.0.1.
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(c.sshPort)-:22",
            "-device", "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,romfile=",
            // One output per Mac display in full screen (Virtual-1 is the window;
            // QEMU's window code opens the others): the built-in and four more.
            "-device", "virtio-gpu-gl-pci,max_outputs=\(Runner.maxOutputs),xres=1920,yres=1080,romfile=",
            "-display", "cocoa,gl=on,show-cursor=\(guestPointer ? "off" : "on"),zoom-to-fit=on,full-screen=\(Settings.startFullScreen ? "on" : "off"),full-grab=on,immersive=on,swap-opt-cmd=off",
            "-device", "virtio-keyboard-pci,romfile=",
            "-device", "virtio-tablet-pci,romfile=",
            "-object", "rng-random,id=rng0,filename=/dev/urandom",
            "-device", "virtio-rng-pci,rng=rng0",
            // Linux reports free memory, so the Mac gets it back.
            "-device", "virtio-balloon-pci,free-page-reporting=on",
            // No recording without the microphone permission: QEMU's recording
            // would wait minutes for an answer (silence, and a sound that
            // starts meanwhile waits too).
            "-audiodev", "sdl,id=snd0,timer-period=1000,out.buffer-count=8\(Runner.micAllowed ? "" : ",in.voices=0")",
            "-device", "intel-hda,id=hda0,romfile=",
            "-device", "hda-micro,bus=hda0.0,audiodev=snd0",
            "-serial", "none",
            "-monitor", "none",
            "-qmp", "unix:\(q(c.qmpSocket.path)),server=on,wait=off",
        ]
        // Notch mode: the guest learns the strip's height (OEM strings, omacvm-app-host).
        if Settings.useNotch, let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let k = s.backingScaleFactor
            let rows = Int((s.safeAreaInsets.top * k).rounded(.up))
            let size = "\(Int(s.frame.width * k))x\(Int(s.frame.height * k))"
            a += ["-smbios", "type=11,value=omacvm.notch=\(rows),value=omacvm.screen=\(size)"]
        }
        let console = c.folder.appendingPathComponent("logs/console.log").path
        a += ["-device", "virtio-serial-pci,id=vser0",
              "-chardev", "file,id=hvc0,path=\(q(console))",
              "-device", "virtconsole,bus=vser0.0,nr=0,chardev=hvc0",
              // QEMU guest agent: a clean shutdown even when the power key is ignored.
              "-chardev", "socket,id=qga0,path=\(q(c.agentSocket.path)),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0",
              // The clipboard, both ways (omacvm-clipboard in the VM).
              "-chardev", "socket,id=clip0,path=\(q(c.clipboardSocket.path)),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=2,chardev=clip0,name=org.omacvm.clipboard",
              // The Mac's battery (omacvm-battery in the VM, from try-omarchy).
              "-chardev", "socket,id=batt0,path=\(q(c.batterySocket.path)),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=3,chardev=batt0,name=org.omacvm.battery",
              // The Mac's camera, while a Linux app reads it (omacvm-camera in the VM).
              "-chardev", "socket,id=cam0,path=\(q(c.cameraSocket.path)),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=4,chardev=cam0,name=org.omacvm.camera",
              // The displays: QEMU's window code tells the VM the Mac's arrangement,
              // the VM says where its outputs are and whether it wants the
              // external displays (omacvm-displays in the VM).
              "-chardev", "socket,id=disp0,path=\(q(c.displaySocket.path)),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=5,chardev=disp0,name=org.omacvm.display"]
        return a
    }

    func start() throws {
        let c = config
        try FileManager.default.createDirectory(at: c.folder.appendingPathComponent("logs"),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: c.qmpSocket)
        try? FileManager.default.removeItem(at: c.displaySocket)
        let p = Process()
        p.executableURL = Paths.qemu
        p.arguments = arguments()
        var env = ProcessInfo.processInfo.environment
        env["OMACVM_PRODUCT_NAME"] = Product.name
        if let icon = Paths.icon { env["OMACVM_ICON"] = icon.path }
        // The VM reaches the Mac's 127.0.0.1 (as 10.0.2.2) only on OmacVM's
        // ports: Omanotch, Gestures and Bridge (patched libslirp).
        env["OMACVM_SLIRP_HOST_PORTS"] = "47811,47830,47831"
        env["OMACVM_NOTCH"] = Settings.useNotch && Mac.hasNotch ? "1" : "0"
        // Video decoding on the Mac's media engine (H.264, VP9, HEVC). AV1 only for
        // VMs whose VA-API shim keeps it to Chromium (omacvm apply writes
        // video-decode): FFmpeg's AV1 cannot go to VideoToolbox.
        if let v = try? String(contentsOf: c.folder.appendingPathComponent("video-decode"), encoding: .utf8),
           v.contains("av1") {
            env["OMACVM_VIDEO_AV1"] = "1"
        }
        // QEMU's window code talks to the VM's display agent over this port.
        env["OMACVM_DISPLAY_SOCKET"] = c.displaySocket.path
        p.environment = env
        let logURL = c.folder.appendingPathComponent("logs/qemu.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        if !Runner.micAllowed {
            log.write(Data("OmacVM: no microphone permission yet: the VM records nothing until its next start\n".utf8))
        }
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                self?.stopObserving()
                self?.clipboard?.stop()
                self?.battery?.stop()
                self?.onExit?(status)
            }
        }
        // QEMU records through SDL in its own process, which cannot ask macOS
        // for the microphone (its AudioQueueStart just fails): the app asks,
        // once, and QEMU records under its grant from then on.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        try p.run()
        process = p
        observeSleep()
        startClipboard()
        startBattery()
        startCamera()
    }

    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Asks the guest to shut down: the power button, then the guest agent
    /// if Omarchy is still up after 20 seconds.
    func powerDown() {
        let qmpPath = config.qmpSocket.path, agentPath = config.agentSocket.path
        Task.detached {
            if let qmp = try? QMPConnection(socketPath: qmpPath, identifierPrefix: "omacvm-power") {
                // A VM paused by the Mac's sleep cannot shut down: resume it first.
                if let status = try? qmp.execute("query-status"), status["status"] as? String == "paused" {
                    _ = try? qmp.execute("cont")
                }
                _ = try? qmp.execute("system_powerdown")
                qmp.close()
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            GuestAgent.shutdown(socketPath: agentPath)
        }
    }

    /// Stops QEMU at once (the guest gets no chance to save anything).
    func forceStop() { process?.terminate() }

    // MARK: Mac sleep: pause the VM before, resume after (from try-omarchy).

    // MARK: Clipboard (try-omarchy's bridge), reconnected while QEMU runs.

    private var clipboard: NativeClipboardBridge?

    private func startClipboard() {
        let path = config.clipboardSocket.path
        Thread.detachNewThread { [weak self] in
            while true {
                let running = DispatchQueue.main.sync { self?.isRunning ?? false }
                guard running else { return }
                if FileManager.default.fileExists(atPath: path),
                   let bridge = try? NativeClipboardBridge(socketPath: path) {
                    DispatchQueue.main.sync { self?.clipboard = bridge }
                    try? bridge.run()
                    bridge.stop()
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    // MARK: The Mac's battery (try-omarchy's bridge), reconnected while QEMU runs.

    private var battery: NativeBatteryBridge?

    private func startBattery() {
        let path = config.batterySocket.path
        Thread.detachNewThread { [weak self] in
            while true {
                let running = DispatchQueue.main.sync { self?.isRunning ?? false }
                guard running else { return }
                if FileManager.default.fileExists(atPath: path),
                   let bridge = try? NativeBatteryBridge(socketPath: path) {
                    DispatchQueue.main.sync { self?.battery = bridge }
                    try? bridge.run()
                    bridge.stop()
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    // MARK: The Mac's camera (camera.swift, shared with OmacVM Bridge), reconnected while QEMU runs.

    private let camera = CameraHub { FileHandle.standardError.write(Data("camera: \($0)\n".utf8)) }

    private func startCamera() {
        let path = config.cameraSocket.path, hub = camera
        Thread.detachNewThread { [weak self] in
            while true {
                let running = DispatchQueue.main.sync { self?.isRunning ?? false }
                guard running else { return }
                if FileManager.default.fileExists(atPath: path),
                   let fd = try? NativeBridgeSocket.connectSecure(path: path, label: "camera") {
                    hub.run(fd: fd, label: "VM")   // until QEMU closes it
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        // The socket appears a moment after QEMU starts.
        Task { [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                if FileManager.default.fileExists(atPath: self.config.qmpSocket.path) {
                    if (try? self.sleep.connect(to: self.config.qmpSocket.path)) != nil { return }
                }
            }
        }
    }

    private func willSleep() {
        try? sleep.prepareForHostSleep(vmIsRunning: isRunning, isStopping: false)
    }

    private func didWake() {
        do {
            try sleep.resumeAfterHostWake(vmIsRunning: isRunning, isStopping: false)
            syncClock()
        } catch {
            if !sleep.scheduleWakeRetry({ [weak self] in self?.didWake() }) {
                wakeFailed()
            }
        }
    }

    /// The VM's clock stood still while the Mac slept: set it to the Mac's
    /// (guest agent), a few tries while the guest wakes up.
    private func syncClock() {
        let path = config.agentSocket.path
        Task.detached {
            for _ in 0..<5 {
                if GuestAgent.setTime(socketPath: path) { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Resume after sleep failed for good: the VM stays paused. Say so.
    private func wakeFailed() {
        let alert = NSAlert()
        alert.messageText = "\(config.name) did not wake up with the Mac"
        alert.informativeText = "It is paused. Resume it, or shut it down."
        alert.addButton(withTitle: "Resume")
        alert.addButton(withTitle: "Shut Down")
        let shutDown = alert.runModal() == .alertSecondButtonReturn
        resumeIfPaused()
        if shutDown { powerDown() } else { syncClock() }
    }

    /// cont on a fresh QMP connection when QEMU reports "paused".
    private func resumeIfPaused() {
        guard let qmp = try? QMPConnection(socketPath: config.qmpSocket.path, identifierPrefix: "omacvm-resume") else { return }
        defer { qmp.close() }
        if let status = try? qmp.execute("query-status"), status["status"] as? String == "paused" {
            _ = try? qmp.execute("cont")
        }
    }

    private func stopObserving() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        sleep.disconnect()
    }
}
