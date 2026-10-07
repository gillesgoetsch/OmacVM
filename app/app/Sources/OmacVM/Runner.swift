import AppKit
import AVFoundation
import Foundation
import OmacVMAuth
import OmacVMNet
import OmacVMUpdate
import OmacVMUSB
import OmacVMDesktop

/// Runs one VM: QEMU with its own Cocoa window (VirGL), a QMP socket for
/// power and pause, and the Mac's sleep and wake.
@MainActor
final class Runner {
    let config: VMConfig
    private(set) var process: Process?
    private let sleep = VMHostSleepCoordinator()
    private var gpuMemory: GPUMemoryWatch?
    private var featuresRoute: ControlCentreRoute?
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
        let g = Runner.graphicsPlan(c, fallbackOnce: openGLOnce)
        graphics = g
        var a: [String] = [
            "-name", q(c.name),
            // M1/M2 with Vulkan: a high PCI window that fits their address
            // space, for Venus's host memory window (Graphics.highWindowGB;
            // only with a QEMU that takes it: runtimeHasSmallHighWindow).
            "-machine", "virt,gic-version=3" + (g.highWindowGB.map { ",highmem-mmio-size=\($0)G" } ?? ""),
            "-accel", "hvf",
            // HVF has no usable guest PMU on Apple Silicon.
            "-cpu", "host,pmu=off",
            "-smp", "\(c.cpus),sockets=1,cores=\(c.cpus),threads=1",
            "-m", "\(c.memoryMB)M",
            "-nodefaults",
            "-action", "reboot=reset,shutdown=poweroff",
            // The firmware boots at once instead of waiting 5 s for a key
            // (Settings.firmwareWait; it sets the VM's Timeout variable each start).
            "-boot", "menu=on,splash-time=\(Settings.firmwareWait * 1000)",
            // UEFI firmware (read-only) and this VM's own boot variables.
            "-drive", "if=pflash,format=raw,readonly=on,file=\(q(Paths.firmware.path))",
            "-drive", "if=pflash,format=raw,file=\(q(c.efiVars.path))",
            "-drive", "if=none,id=disk,file=\(q(c.disk.path)),format=raw,cache=writeback,discard=unmap",
            "-device", "nvme,serial=omacvm,drive=disk,bootindex=0",
        ] + networkArguments() + [
            // One output per Mac display in full screen (Virtual-1 is the window;
            // QEMU's window code opens the others): the built-in and four more.
            // Venus (Vulkan: the VM's Graphics setting, see Graphics.swift)
            // needs blobs and a host memory window for them.
            "-device", "virtio-gpu-gl-pci,max_outputs=\(Runner.maxOutputs),xres=1920,yres=1080,romfile=\(g.venus ? ",blob=true,venus=true,hostmem=\(g.hostmemMB)M" : "")",
            "-display", "cocoa,gl=on,show-cursor=\(guestPointer ? "off" : "on"),zoom-to-fit=on,full-screen=\(Settings.startFullScreen ? "on" : "off"),full-grab=on,immersive=\(Settings.keepDockAway ? "on" : "off"),swap-opt-cmd=off",
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
            // The codec paces the guest's sound (no catch-up after a stalled
            // main loop); audioClassic keeps QEMU's own timing.
            "-device", "hda-micro,bus=hda0.0,audiodev=snd0\(Settings.audioClassic ? ",pace=off" : "")",
            "-serial", "none",
            "-monitor", "none",
            "-qmp", "unix:\(q(c.qmpSocket.path)),server=on,wait=off",
        ]
        // This runtime shows a Vulkan window Hyprland imports (virgl-set-type-without-egl.patch),
        // with MoltenVK and with KosmicKrisp: the guest then keeps Mesa's normal Vulkan present,
        // not the software copy (omacvm-vulkan-present); the Mac copies each frame into GL.
        a += ["-smbios", "type=11,value=omacvm.vkwindows=1"]
        // HDR: the guest's display sync reads it (omacvm-app-host).
        if Settings.hdrActive {
            a += ["-smbios", "type=11,value=omacvm.hdr=1"]
        }
        // Experimental: the guest's pointer on the cursor plane, shown by the
        // Mac's cursor (omacvm_app.lua reads it from host.env; QEMU: OMACVM_HW_CURSOR).
        if Settings.macPointer {
            a += ["-smbios", "type=11,value=omacvm.hwcursor=1"]
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
              "-device", "virtserialport,bus=vser0.0,nr=5,chardev=disp0,name=org.omacvm.display",
              // The control centre's requests (omacvm in the VM), passed on to OmacVM Bridge.
              "-chardev", "socket,id=ctl0,path=\(q(c.controlSocket.path)),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=6,chardev=ctl0,name=org.omacvm.control"]
        // Touch ID (docs/adr/0041): the VM's PAM client asks through it, the
        // app passes it on to OmacVM Bridge (AuthRelay). Every VM has it from
        // its start, whatever the setting, so turning Touch ID on later works
        // at once (3.0.3: only with touch-id on at the start, so one more
        // restart). While Touch ID is off nothing in the VM opens it (no PAM
        // line, no client; root's alone by udev rule) and the Bridge has no
        // key for the VM: it answers "off". A port on vser0 moves no PCI
        // device; the VM finds it by its name.
        a += ["-chardev", "socket,id=auth0,path=\(q(c.authSocket.path)),server=on,wait=off",
              "-device", "virtserialport,bus=vser0.0,nr=7,chardev=auth0,name=org.omacvm.auth"]
        // The fast network: an empty PCIe slot for the user network's NIC
        // should vmnet fail while the VM runs (useUserNetwork). Last,
        // so no other device moves.
        if network.vmnet { a += ["-device", "pcie-root-port,id=netfb"] }
        // The VM's USB devices (off by default; docs/usb.md): with the switch
        // on, an empty xHCI controller; the app adds a device only when the
        // user says so (USBRun). After everything else, so no other device moves.
        let usbMemory = USBMemory.load(folder: c.folder)
        usbOn = USBSwitch.isOn(folder: c.folder)
        usbRecord = usbOn ? "on (asks" + (usbMemory.devices.isEmpty ? ")" : "; remembered: \(usbMemory.record))") : "off"
        a += USBSwitch.arguments(on: usbOn)
        // The Mac folder (off by default): last, so turning it on or off
        // moves no other device (the VM finds it by its tag, wherever it is).
        let share = MacFolder.plan(c)
        macFolder = share.record
        a += share.arguments
        return a
    }

    /// The USB switch at this start (USBSwitch), and its qemu.log record.
    private(set) var usbOn = false
    private var usbRecord = "off"
    /// The devices while the VM runs (switch on only).
    private var usb: USBRun?

    /// What the last start did with the Mac folder (MacFolderPlan's record).
    private(set) var macFolder = "off"

    /// The display for the VM's window: under the pointer, else the one with
    /// the active menu bar; nil with one display.
    static func placement() -> UInt32? {
        let screens = NSScreen.screens.compactMap { s -> WindowPlacement.Screen? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return WindowPlacement.Screen(id: id, frame: s.frame)
        }
        let menuBar = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        return WindowPlacement.display(pointer: NSEvent.mouseLocation, screens: screens, menuBar: menuBar)
    }

    /// QEMU shows a window now (on any display).
    nonisolated static func hasWindow(_ pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == 0 }
    }

    /// The graphics this start got (Graphics.swift).
    private(set) var graphics: GraphicsPlan?

    /// The runtime has KosmicKrisp (release builds; Venus uses it on macOS 26+).
    static var runtimeHasKosmicKrisp: Bool {
        let lib = Paths.qemu.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/libvulkan_kosmickrisp.dylib")
        return FileManager.default.fileExists(atPath: lib.path)
    }

    /// The runtime's QEMU takes a small high PCI window (our patch; an app
    /// with an older runtime keeps 256 MB on M1/M2).
    static var runtimeHasSmallHighWindow: Bool { RuntimeQEMU.takesSmallHighWindow }

    /// The VM's Graphics setting on this Mac now: the macOS version, whether
    /// the runtime has KosmicKrisp, whether the VM has its Venus driver.
    /// `fallbackOnce`: this start's Vulkan try just fell back (OpenGL once).
    static func graphicsPlan(_ c: VMConfig, fallbackOnce: String? = nil) -> GraphicsPlan {
        // QEMU's binary is read only where the window matters (M1/M2).
        let bits = Mac.vmAddressBits
        let small = (bits ?? Graphics.highPCIWindowBits) >= Graphics.highPCIWindowBits || runtimeHasSmallHighWindow
        let forced = FileManager.default.fileExists(atPath: c.folder.appendingPathComponent("vulkan").path)
        return Graphics.plan(choice: Graphics.read(folder: c.folder),
                             macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                             kosmicKrisp: runtimeHasKosmicKrisp,
                             driverReady: Graphics.driverReady(folder: c.folder), forced: forced,
                             macMemoryGB: Mac.memoryGB, vmMemoryGB: c.memoryMB / 1024,
                             ipaBits: bits, smallHighWindow: small,
                             fallback: Graphics.fallback(folder: c.folder), fallbackOnce: fallbackOnce)
    }

    // MARK: A Vulkan start that shows nothing (VenusStartWatch)

    /// Set when this start with Vulkan showed nothing and QEMU is being
    /// stopped for it (or QEMU exited at once): the caller (main.swift
    /// onExit) starts the VM again on OpenGL. keep: record it in
    /// graphics-fallback (OpenGL until Vulkan is chosen again); else
    /// openGLOnce for that start only.
    private(set) var venusFallback: (why: String, keep: Bool)?
    /// Set by the caller before start: Vulkan just fell back for this start.
    var openGLOnce: String?
    /// The user (or the app) asked QEMU to stop: an exit is no Vulkan failure.
    private var stopAsked = false
    private var startedAt = Date()
    private var venusWatch = VenusStartWatch()
    private var hostAsleep = false

    /// Polls QMP and the VM's logs every 3 s while VenusStartWatch says
    /// wait; QMP off the main thread (it blocks up to 2 s per call).
    private func watchVenusStart() {
        let c = config
        venusWatch = VenusStartWatch(smallAddressSpace:
            (Mac.vmAddressBits ?? Graphics.highPCIWindowBits) < Graphics.highPCIWindowBits)
        let qmpPath = c.qmpSocket.path
        let console = c.folder.appendingPathComponent("logs/console.log").path
        let qemuLog = c.folder.appendingPathComponent("logs/qemu.log").path
        let pid = process?.processIdentifier
        Task { [weak self] in
            var last = Date()
            while true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isRun(pid) else { return }
                if self.hostAsleep { last = Date(); continue }
                let poll = await Task.detached(operation: {
                    Runner.venusPoll(qmpPath: qmpPath, console: console, qemuLog: qemuLog)
                }).value
                guard self.isRun(pid) else { return }
                if self.hostAsleep { last = Date(); continue }
                let now = Date()
                let verdict = self.venusWatch.poll(poll, seconds: now.timeIntervalSince(last))
                last = now
                switch verdict {
                case .wait: continue
                case .fine: return
                case .note(let line):
                    // Not "OmacVM: graphics:": omacvm check and the control
                    // centre read the last such line as this start's record.
                    self.appendLog("OmacVM: Vulkan start: \(line)")
                case .fallBack(let why, let graceful, let keep):
                    // The user stopped the VM already: no OpenGL start.
                    if self.stopAsked { return }
                    self.venusFallback = (why, keep)
                    self.appendLog("OmacVM: Vulkan start: \(Graphics.didNotStart): \(why); stopping this start and starting again on OpenGL")
                    if graceful {
                        self.powerDown(byApp: true)
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        if self.isRun(pid) { self.forceStop(byApp: true) }
                    } else {
                        self.forceStop(byApp: true)
                    }
                    return
                }
            }
        }
    }

    nonisolated static func venusPoll(qmpPath: String, console: String, qemuLog: String) -> VenusStartWatch.Poll {
        var p = VenusStartWatch.Poll(answered: false)
        let size = (try? FileManager.default.attributesOfItem(atPath: console)[.size] as? Int) ?? 0
        p.consoleOutput = size > 0
        // qemu.log stays small while starting (a few KB).
        if let log = try? String(contentsOfFile: qemuLog, encoding: .utf8) {
            p.noPicture = log.contains("no picture from the guest")
        }
        guard let qmp = try? QMPConnection(socketPath: qmpPath, identifierPrefix: "omacvm-venus") else { return p }
        defer { qmp.close() }
        guard let status = try? qmp.execute("query-status") else { return p }
        p.answered = true
        p.paused = status["status"] as? String == "paused"
        if let r = try? qmp.execute("human-monitor-command", arguments: ["command-line": "info pci"]),
           let text = r["text"] as? String {
            p.pciMapped = VenusStartWatch.pciMapped(text)
        }
        return p
    }

    /// The path the network took at the last start (FastNetwork).
    private(set) var network = FastNetwork.Choice(vmnet: false, mac: FastNetwork.defaultMAC, record: "slirp off")
    /// This start on QEMU's user network although the fast network is on, and
    /// why (its service needs an update the person did not make now).
    var userNetwork: String?

    private func networkArguments() -> [String] {
        let c = config
        let choice = FastNetwork.choose(for: c, userNetwork: userNetwork)
        network = choice
        if choice.vmnet {
            // vmnet (shared, its own 192.168.77.0/24: the Mac is .1) through omacvm-netd; QEMU
            // connects again within a second if the daemon restarts. The NIC
            // sits right on it: through a QEMU hub (to swap networks) VM -> Mac
            // lost a quarter of its speed. The fallback adds a NIC instead.
            return ["-netdev", "stream,id=fast,server=off,reconnect-ms=1000,addr.type=unix,addr.path=\(FastNetwork.socket)",
                    "-device", "virtio-net-pci,id=nic0,netdev=fast,mac=\(choice.mac),romfile="]
        }
        // QEMU's user network: the Mac is 10.0.2.2 for the VM; SSH from the Mac on 127.0.0.1.
        return ["-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(c.sshPort)-:22",
                "-device", "virtio-net-pci,netdev=net0,mac=\(choice.mac),romfile="]
    }

    func start() throws {
        let c = config
        try FileManager.default.createDirectory(at: c.folder.appendingPathComponent("logs"),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: c.qmpSocket)
        try? FileManager.default.removeItem(at: c.displaySocket)
        // QEMU empties the console log only when it opens it: the last
        // boot's text would tell the Vulkan start watch the firmware ran.
        try? FileManager.default.removeItem(at: c.folder.appendingPathComponent("logs/console.log"))
        try? FileManager.default.removeItem(at: c.touchIDPanelSocket)
        let p = Process()
        p.executableURL = Paths.qemu
        // What of the Mac this start may use (its features), read once.
        links = MacLinks.load(folder: c.folder)
        p.arguments = arguments()
        var env = ProcessInfo.processInfo.environment
        env["OMACVM_PRODUCT_NAME"] = Product.name
        // Named under the boot logo when the VM is slow to show anything.
        env["OMACVM_LOGS"] = c.folder.appendingPathComponent("logs").path
        if let icon = Paths.icon { env["OMACVM_ICON"] = icon.path }
        // The VM reaches the Mac's 127.0.0.1 (as 10.0.2.2) only on OmacVM's
        // ports (patched libslirp), and only for its features that are on:
        // Omanotch, Gestures, Bridge.
        env["OMACVM_SLIRP_HOST_PORTS"] = links.hostPorts
        // And the port of the Mac's proxy on its 127.0.0.1, if it has one
        // (MacProxy, #122): a VM built behind it reaches it as 10.0.2.2.
        let proxy = MacProxy.current()
        env["OMACVM_SLIRP_HOST_PORTS"] = proxy.addingPorts(to: links.hostPorts)
        if Settings.macShortcuts { env["OMACVM_MAC_SHORTCUTS"] = "1" }
        if !Settings.pointerStart { env["OMACVM_POINTER_START"] = "0" }
        if Settings.macPointer { env["OMACVM_HW_CURSOR"] = "1" }
        if !Settings.globeKeyToVM { env["OMACVM_GLOBE_KEY"] = "mac" }
        // Video decoding on the Mac's media engine (H.264, VP9, HEVC). AV1 only for
        // VMs whose VA-API shim keeps it to Chromium (omacvm apply writes
        // video-decode): FFmpeg's AV1 cannot go to VideoToolbox.
        if let v = try? String(contentsOf: c.folder.appendingPathComponent("video-decode"), encoding: .utf8),
           v.contains("av1") {
            env["OMACVM_VIDEO_AV1"] = "1"
        }
        // QEMU's window code talks to the VM's display agent over this port.
        env["OMACVM_DISPLAY_SOCKET"] = c.displaySocket.path
        // "Features…" in QEMU's app menu asks this app to open the control
        // centre in the VM (ControlCentreRoute).
        let route = ControlCentreRoute(agentPath: c.agentSocket.path, vmName: c.name) { [weak self] line in
            self?.appendLog(line)
        }
        env["OMACVM_FEATURES_REQUEST"] = route.requestName
        // "Restart the Desktop…" in QEMU's app menu after Later on the
        // desktop-lost window (GPUMemoryWatch, DesktopRestart).
        let desktop = DesktopRestart(for: c)
        env["OMACVM_DESKTOP_LOST"] = desktop.lost.path
        env["OMACVM_DESKTOP_RESTART_REQUEST"] = desktop.requestName
        // Touch ID's panel in QEMU's own window process (omacvm-cocoa-touchid-panel.patch):
        // macOS reads the finger only for the app in front. Loaded for every
        // VM, as the port: it only listens on the app's private socket, and
        // shows only what the Bridge verified (Touch ID on, a finger asked).
        if let panel = Paths.touchIDPanel {
            try? FileManager.default.removeItem(at: c.touchIDPanelSocket)
            env["OMACVM_TOUCHID_PANEL"] = panel.path
            env["OMACVM_TOUCHID_PANEL_SOCKET"] = c.touchIDPanelSocket.path
        }
        // "USB Devices…" in QEMU's app menu (a runtime with that item) opens
        // the list while the VM runs (USBRun.requestName).
        if usbOn { env["OMACVM_USB_REQUEST"] = USBRun.requestName() }
        // The VM's graphics memory on the Mac, for this app and omacvm check (GPUMemory).
        env["OMACVM_GPU_MEMORY_STATUS"] = GPUMemory.file(for: c).path
        try? FileManager.default.removeItem(at: GPUMemory.file(for: c))
        // The window opens on the display the user is using (WindowPlacement).
        // QEMU's hook for that (omacvm-cocoa-displays.patch) still has the name
        // its first user, the display tests, gave it; it is no test mode.
        // A test build keeps a display it was given (a virtual one), so a test
        // never opens a window on the user's screens.
        if TestHooks.value("OMACVM_TEST_MAIN_DISPLAY", bundleID: Bundle.main.bundleIdentifier) == nil,
           let d = Runner.placement() {
            env["OMACVM_TEST_MAIN_DISPLAY"] = String(d)
        }
        if Settings.hdrActive {
            env["OMACVM_GL_HDR"] = "1"
        }
        // QEMU puts its main loop (sound card timers, virgl) at user-interactive
        // QoS and logs which one it got; audioClassic keeps the default.
        if Settings.audioClassic {
            env["OMACVM_MAIN_LOOP_QOS"] = "default"
        }
        if Settings.gpuSafeMode {
            env["OMACVM_VIRGL_POLL_FENCES"] = "1"
            env["OMACVM_GL_PRESENT"] = "layer"
            env["OMACVM_GL_PRESENT_ON_TICK"] = "1"
        }
        p.environment = env
        // One OmacVM in the Dock: QEMU counts as this app (DockIdentity).
        let launch = DockIdentity.launchPath(qemu: Paths.qemu.path, bundle: Bundle.main.bundlePath, env: env)
        p.executableURL = URL(fileURLWithPath: launch)
        let logURL = c.folder.appendingPathComponent("logs/qemu.log")
        // Append mode: this app adds "OmacVM: ..." lines while QEMU writes
        // (appendLog); without O_APPEND QEMU's next write lands at its own
        // offset and overwrites them.
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logURL.path]) }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Which network this start took, for omacvm check and the omacvm command
        // (SSH: the VM's vmnet address, else 127.0.0.1:SSH_PORT).
        log.write(Data("OmacVM: network: \(network.record)\n".utf8))
        log.write(Data("OmacVM: Mac links: \(links.record)\n".utf8))
        log.write(Data("OmacVM: Mac proxy: \(proxy.record(fastNetwork: network.vmnet))\n".utf8))
        log.write(Data("OmacVM: Mac folder: \(macFolder)\n".utf8))
        if let g = graphics { log.write(Data("OmacVM: graphics: \(g.record)\n".utf8)) }
        log.write(Data("OmacVM: USB devices: \(usbRecord)\n".utf8))
        if Settings.firmwareWait > 0 {
            log.write(Data("OmacVM: the firmware waits \(Settings.firmwareWait) s for a key (firmwareWait)\n".utf8))
        }
        try? Data("\(network.record)\n".utf8).write(to: c.folder.appendingPathComponent("logs/network"))
        if !Runner.micAllowed {
            log.write(Data("OmacVM: no microphone permission yet: the VM records nothing until its next start\n".utf8))
        }
        log.write(Data("OmacVM: \(KeyAccess.record)\n".utf8))
        log.write(Data("OmacVM: \(DockIdentity.record(launch: launch, qemu: Paths.qemu.path))\n".utf8))
        if Settings.hdr && !Mac.hasHDRDisplay {
            log.write(Data("OmacVM: HDR is on, but no display here can show it: the VM gets the SDR path\n".utf8))
        }
        p.standardOutput = log
        p.standardError = log
        let agentPath = c.agentSocket.path
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // A QEMU killed while the VM had the keyboard leaves macOS's globe
            // shortcut off: give it back (GlobeKey).
            let globe = GlobeKey.giveBack(after: proc.processIdentifier)
            GuestAgent.release(socketPath: agentPath)
            let reason = proc.terminationReason
            Task { @MainActor in
                self?.noteEarlyExit(status: status, reason: reason)
                if globe { self?.appendLog("OmacVM: macOS's globe shortcut given back (QEMU ended without)") }
                self?.stopObserving()
                self?.driveWatch?.stop()
                self?.gpuMemory?.stop()
                self?.clipboard?.stop()
                self?.battery?.stop()
                self?.control?.stop()
                self?.featuresRoute?.stop()
                self?.audioLatency?.stop()
                self?.audioLatency = nil
                self?.auth?.stop()
                self?.usb?.stop()
                self?.usb = nil
                self?.onExit?(status)
            }
        }
        // QEMU records through SDL in its own process, which cannot ask macOS
        // for the microphone (its AudioQueueStart just fails): the app asks,
        // once, and QEMU records under its grant from then on.
        // Not in a hidden test run (OMACVM_COCOA_HIDDEN) and not for the test
        // identity (its grants are given once, by hand; tests run unattended):
        // no prompt there.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined,
           ProcessInfo.processInfo.environment["OMACVM_COCOA_HIDDEN"] == nil, !TestIdentity.isOn {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        try p.run()
        process = p
        if usbOn {
            usb = USBRun(config: c, qemuPID: p.processIdentifier) { [weak self] line in self?.appendLog(line) }
        }
        driveWatch = DriveWatch(folder: c.folder) { [weak self] name in
            MainActor.assumeIsolated { self?.driveLost(name) }
        }
        route.start()
        featuresRoute = route
        startedAt = Date()
        if network.vmnet { watchFastNetwork() }
        if graphics?.venus == true { watchVenusStart() }
        observeSleep()
        let watch = GPUMemoryWatch(config: c) { [weak self] line in self?.appendLog(line) }
        watch.start()
        gpuMemory = watch
        observeActivation()
        startClipboard()
        // A feature that is off: nothing of the Mac on its port.
        if links.battery { startBattery() }
        if links.camera { startCamera() }
        startControl()
        // The sound's delay on the Mac, so the VM's videos keep the picture in step.
        let audioDelay = AudioLatencyWatch(agentSocket: agentPath) { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        audioDelay.start()
        audioLatency = audioDelay
        // Touch ID's port, relayed for every VM (the Bridge decides on or off per request).
        startAuth()
        // USB devices (switch on): asked about as they are plugged in, once QMP answers.
        if let u = usb {
            u.listen()
            u.start()
        }
        // Held while QEMU runs, so qemu-ga in the VM sleeps (GuestAgent).
        Thread.detachNewThread { GuestAgent.hold(socketPath: agentPath) }
        // Grow or Compact asked for in the window (VMDisk), once the guest answers.
        let pid = p.processIdentifier
        VMDisk.runJobs(config: c, agentPath: agentPath, running: { kill(pid, 0) == 0 })
    }

    /// What of the Mac this start of the VM may use (its features).
    private(set) var links = MacLinks()

    /// omacvm-netd may still refuse QEMU (another build, the limit), vmnet
    /// may not start, or the daemon may go away later: then QEMU only tries
    /// to connect again and again, and the VM has no network. Watched for the
    /// whole run: when vmnet stays down, QEMU's user network takes over
    /// (switchNetwork); when it is back for a whole window, vmnet takes over
    /// again, make before break: the user network stays up until the guest
    /// has had time for its vmnet address (FastNetworkWatch, tested by
    /// `swift run net-tests`). A switch that fails or is only half done (QMP
    /// busy or timed out) is tried again at the next poll: switching is safe
    /// to repeat.
    /// logs/network and qemu.log say what the VM has now (omacvm check,
    /// app_ip). launchd accepts every connect at first, so one "connected"
    /// poll proves nothing: most of the last polls must see it.
    private func watchFastNetwork() {
        let qmpPath = config.qmpSocket.path
        let sshPort = config.sshPort
        let pid = process?.processIdentifier
        // Polls and switches off the main thread (QMP blocks); the verdicts back here.
        Task { [weak self] in
            var watch = FastNetworkWatch()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            while self?.isRun(pid) == true {
                let up = await Task.detached(operation: { Runner.fastLinkUp(qmpPath: qmpPath) }).value
                let step = watch.poll(up)
                if step != .none {
                    let links = await Task.detached(operation: {
                        Runner.switchNetwork(qmpPath: qmpPath, sshPort: sshPort, step: step)
                    }).value
                    guard let self, self.isRun(pid) else { return }
                    watch.finished(step, ok: links.error == nil)
                    if step != .userDown, let line = Runner.networkRecord(links, toUser: step == .toUser) {
                        self.recordNetwork(line, note: line == "vmnet" ? "the fast network is back" : nil)
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// What logs/network says after a switch: what the VM has now (nil:
    /// nothing changed for it).
    nonisolated static func networkRecord(_ l: NetLinks, toUser: Bool) -> String? {
        let why = "the fast network stopped working (QEMU could not stay connected to omacvm-netd; its log: /var/log/org.omacvm.netd.log)"
        if toUser {
            if l.user == true {
                return "slirp fallback: \(why): QEMU's user network took over until it is back"
                    + (l.fast == false ? "" : " (the fast network's NIC is still up: trying again)")
            }
            return "vmnet-down \(why), and the user network could not take over yet (\(l.error ?? "unknown")): trying again every 3 s (omacvm check; omacvm disable fast-network)"
        }
        // Back to vmnet once its NIC is up again; until then the user network stays.
        return l.fast == true ? "vmnet" : nil
    }

    /// One "OmacVM: ..." line at the end of qemu.log.
    private func appendLog(_ line: String) {
        guard let h = FileHandle(forWritingAtPath: config.folder.appendingPathComponent("logs/qemu.log").path) else { return }
        h.seekToEndOfFile()
        h.write(Data("\(line)\n".utf8))
        try? h.close()
    }

    /// logs/network (first line: vmnet, slirp or vmnet-down, then why) and a
    /// line in qemu.log; a retry that changes nothing writes nothing.
    private func recordNetwork(_ line: String, note: String? = nil) {
        if line == network.record { return }
        try? Data("\(line)\n".utf8).write(to: config.folder.appendingPathComponent("logs/network"))
        if let h = FileHandle(forWritingAtPath: config.folder.appendingPathComponent("logs/qemu.log").path) {
            h.seekToEndOfFile()
            h.write(Data("OmacVM: network: \(line)\(note.map { " (\($0))" } ?? "")\n".utf8))
            try? h.close()
        }
        network = FastNetwork.Choice(vmnet: line == "vmnet", mac: network.mac, record: line)
    }

    /// QEMU of the run with this pid still runs.
    private func isRun(_ pid: Int32?) -> Bool { isRunning && process?.processIdentifier == pid }

    /// Is QEMU connected to omacvm-netd? nil when QMP did not answer (busy).
    /// "info network" shows "fast: index=0,type=stream,unix:<path>" while
    /// connected, "connecting" or an error while not.
    nonisolated static func fastLinkUp(qmpPath: String) -> Bool? {
        guard let qmp = try? QMPConnection(socketPath: qmpPath, identifierPrefix: "omacvm-net") else { return nil }
        defer { qmp.close() }
        guard let r = try? qmp.execute("human-monitor-command", arguments: ["command-line": "info network"]),
              let text = r["text"] as? String else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first { $0.contains("fast: index=") } ?? ""
        return line.contains("type=stream,unix:") && !line.contains("link=down")
    }

    /// The two NICs after a switch: true/false once set, nil when the switch
    /// stopped before (error says why).
    struct NetLinks { var fast: Bool?; var user: Bool?; var error: String? }

    /// To QEMU's user network (toUser) or back to vmnet; safe to repeat after
    /// a half-done switch. The user network is as at a start without the fast
    /// network (SSH on 127.0.0.1:sshPort): its netdev ("slow") and its NIC
    /// ("nic1", in the empty slot; the guest's NetworkManager takes it up with
    /// DHCP: 10.0.2.15) are added the first time, only what is not there yet;
    /// later its link goes up again. The vmnet NIC's link goes down, so its
    /// address and route go. Its netdev stays: QEMU keeps a NIC's netdev until
    /// the NIC goes (and cannot unplug this one), and its reconnects are what
    /// tells that vmnet is back. Back (toVmnet): the vmnet NIC's link up (the
    /// guest asks DHCP); the user network's NIC stays up until userDown, a few
    /// polls later, so the guest is never without a network meanwhile (at
    /// once, its DHCP on vmnet left it without one for about 8 s).
    nonisolated static func switchNetwork(qmpPath: String, sshPort: Int, step: FastNetworkWatch.Step) -> NetLinks {
        var l = NetLinks()
        guard let qmp = try? QMPConnection(socketPath: qmpPath, identifierPrefix: "omacvm-net") else {
            l.error = "QEMU's monitor did not answer"
            return l
        }
        defer { qmp.close() }
        do {
            let have = networkNames(try qmp.execute("human-monitor-command", arguments: ["command-line": "info network"])["text"] as? String ?? "")
            switch step {
            case .toUser:
                if !have.contains("slow") {
                    _ = try qmp.execute("netdev_add", arguments: [
                        "type": "user", "id": "slow", "hostfwd": [["str": "tcp:127.0.0.1:\(sshPort)-:22"]]])
                }
                if !have.contains("nic1") {
                    _ = try qmp.execute("device_add", arguments: [
                        "driver": "virtio-net-pci", "id": "nic1", "netdev": "slow", "bus": "netfb",
                        "mac": FastNetwork.defaultMAC, "romfile": ""])
                } else {
                    _ = try qmp.execute("set_link", arguments: ["name": "nic1", "up": true])
                }
                l.user = true
                _ = try qmp.execute("set_link", arguments: ["name": "nic0", "up": false])
                l.fast = false
            case .toVmnet:
                _ = try qmp.execute("set_link", arguments: ["name": "nic0", "up": true])
                l.fast = true
            case .userDown:
                if have.contains("nic1") { _ = try qmp.execute("set_link", arguments: ["name": "nic1", "up": false]) }
                l.user = false
            case .none:
                break
            }
        } catch {
            l.error = error.localizedDescription
        }
        return l
    }

    /// The NICs and netdevs "info network" lists: "nic0: index=0,...", its
    /// netdev indented after a backslash, a netdev without a NIC on its own line.
    nonisolated static func networkNames(_ text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            var l = line.drop { $0 == " " }
            if l.hasPrefix("\\ ") { l = l.dropFirst(2) }
            if let colon = l.firstIndex(of: ":"), l[colon...].hasPrefix(": index=") { names.insert(String(l[..<colon])) }
        }
        return names
    }

    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Asks the guest to shut down: the power button, then the guest agent
    /// if Omarchy is still up after 20 seconds. byApp: the Vulkan start
    /// watch; else the user asked, and no OpenGL start follows.
    func powerDown(byApp: Bool = false) {
        stopAsked = true
        if !byApp { venusFallback = nil }
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

    /// Stops QEMU at once (the guest gets no chance to save anything):
    /// SIGTERM, then SIGKILL after 5 s if QEMU is still there (its main loop
    /// may hang, and only that loop handles SIGTERM).
    func forceStop(byApp: Bool = false) {
        guard let p = process, p.isRunning else { return }
        stopAsked = true
        if !byApp { venusFallback = nil }
        let pid = p.processIdentifier
        p.terminate()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.isRun(pid) else { return }
            self.appendLog("OmacVM: QEMU did not stop in 5 s: killed")
            kill(pid, SIGKILL)
        }
    }

    // MARK: The drive with the VM's folder goes away (DriveWatch)

    private var driveWatch: DriveWatch?
    /// The drive's name when it went away while the VM ran: QEMU is being
    /// stopped for it, and main.swift then shows the VM as unavailable.
    private(set) var driveGone: String?

    /// The VM's disk went with the drive: the VM cannot go on, nor shut down
    /// in the guest. QEMU is asked to pause the VM and quit (it closes its
    /// window and hands macOS's shortcuts back itself); if it has not ended
    /// within 5 s, forceStop (SIGTERM, then SIGKILL). Nothing is written to
    /// the VM's folder: it is not there (appendLog finds no qemu.log).
    private func driveLost(_ name: String) {
        guard driveGone == nil, let pid = process?.processIdentifier, isRunning else { return }
        driveGone = name
        stopAsked = true
        venusFallback = nil
        FileHandle.standardError.write(Data("drive: \(name), the drive with \(config.name), is gone: stopping QEMU\n".utf8))
        let qmpPath = config.qmpSocket.path
        Task.detached {
            guard let qmp = try? QMPConnection(socketPath: qmpPath, identifierPrefix: "omacvm-drive") else { return }
            defer { qmp.close() }
            _ = try? qmp.execute("stop")
            _ = try? qmp.execute("quit")
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.isRun(pid) else { return }
            self.forceStop(byApp: true)
        }
    }

    /// QEMU of a Vulkan start ended with an error within 15 s, unasked (an
    /// option this QEMU refuses, Venus failing to set up): start once more on
    /// OpenGL. If that fails too, the error is not Vulkan's and shows as usual.
    private func noteEarlyExit(status: Int32, reason: Process.TerminationReason) {
        guard venusFallback == nil, graphics?.venus == true, !stopAsked,
              reason == .exit, status != 0, Date().timeIntervalSince(startedAt) < 15 else { return }
        venusFallback = ("QEMU stopped at once with Vulkan (exit \(status))", false)
    }

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
                    DispatchQueue.main.sync {
                        self?.clipboard = bridge
                        bridge.setVMActive(self?.qemuIsActive ?? true)
                    }
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

    // MARK: The control centre's port (NativeControlBridge.swift), reconnected while QEMU runs.

    private var control: NativeControlBridge?
    private var audioLatency: AudioLatencyWatch?

    private func startControl() {
        let path = config.controlSocket.path, name = config.name, gpuMemory = GPUMemory.file(for: config)
        Thread.detachNewThread { [weak self] in
            while true {
                let running = DispatchQueue.main.sync { self?.isRunning ?? false }
                guard running else { return }
                if FileManager.default.fileExists(atPath: path),
                   let bridge = try? NativeControlBridge(socketPath: path, vmName: name, gpuMemoryFile: gpuMemory) {
                    DispatchQueue.main.sync { self?.control = bridge }
                    try? bridge.run()
                    bridge.stop()
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    // MARK: Touch ID's port (OmacVMAuth), reconnected while QEMU runs.

    private var auth: AuthRelay?

    private func startAuth() {
        let path = config.authSocket.path, name = config.name, folder = config.folder
        let panelPath = config.touchIDPanelSocket.path
        let panel: AuthRelay.Panel? = Paths.touchIDPanel == nil ? nil : { prompt, gone in
            guard let fd = try? NativeBridgeSocket.connectSecure(path: panelPath, label: "Touch ID panel") else {
                FileHandle.standardError.write(Data("[auth] Touch ID panel: not there (the Mac's own dialog instead)\n".utf8))
                return .error
            }
            defer { Darwin.close(fd) }
            return TouchIDPanelClient.ask(fd: fd, prompt, gone: gone)
        }
        Thread.detachNewThread { [weak self] in
            while true {
                let running = DispatchQueue.main.sync { self?.isRunning ?? false }
                guard running else { return }
                if FileManager.default.fileExists(atPath: path),
                   let fd = try? NativeBridgeSocket.connectSecure(path: path, label: "auth port") {
                    let relay = AuthRelay(guest: fd, connectBridge: {
                        try? NativeBridgeSocket.connectSecure(path: NativeControlBridge.relaySocketPath, label: "Bridge relay")
                    },
                                          headers: { NativeControlBridge.relayHeaders(vmName: name) },
                                          panel: panel,
                                          // The features as they are now: on works at once, off is refused here.
                                          enabled: { MacLinks.load(folder: folder).touchID },
                       log: { FileHandle.standardError.write(Data("[auth] \($0)\n".utf8)) })
                    DispatchQueue.main.sync { self?.auth = relay }
                    try? relay.run()
                    relay.stop()
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

    /// QEMU's window is the active app (the clipboard polls only then).
    private var qemuIsActive: Bool {
        guard let pid = process?.processIdentifier else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// The clipboard polls fast only while QEMU's window is the active app.
    private func observeActivation() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clipboard?.setVMActive(self.qemuIsActive)
                }
            })
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
        hostAsleep = true
        try? sleep.prepareForHostSleep(vmIsRunning: isRunning, isStopping: false)
    }

    private func didWake() {
        hostAsleep = false
        venusWatch.woke()
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

/// The runtime's QEMU binary, read once per app run. Not on the main actor:
/// the app reads it at launch on a background queue (M1/M2 only), so the
/// window never waits for it.
enum RuntimeQEMU {
    static let takesSmallHighWindow = Graphics.qemuTakesSmallHighWindow(binary: Paths.qemu)
}
