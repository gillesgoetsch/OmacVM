import AppKit

/// Omanotch, the macOS side.
///
/// Shows the real Omarchy bar, streamed from the VM, in the MacBook notch strip
/// while the VM is full screen on the built-in display, and sends clicks and
/// scrolling back. While the strip is shown the guest hides its own bar on the
/// built-in display ("park"); a heartbeat keeps it hidden, so the guest shows
/// its bar again by itself if this helper stops.
enum Log {
    static func info(_ message: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                             formatOptions: [.withTime, .withColonSeparatorInTime])
        FileHandle.standardError.write(Data("\(ts) omanotch: \(message)\n".utf8))
    }
}

struct Settings {
    let defaults = UserDefaults.standard  // domain ch.gillesgoetsch.omanotch (bundle id)

    /// Flush: the bar is exactly as tall as the camera housing; the few points
    /// of the strip below it show the wallpaper. Off (default): the bar fills
    /// the strip, as tall as macOS's menu bar.
    var flush: Bool { defaults.bool(forKey: "flush") }
    /// Listen on this one address instead of every VM network interface.
    var listenHost: String? { defaults.string(forKey: "listenHost") }
    var port: UInt16 { UInt16(defaults.integer(forKey: "port")).nonZero ?? 47811 }
    /// Interfaces that carry VM networks: Parallels and UTM (vmnet) use
    /// bridgeNNN, older Parallels versions vnicN.
    var interfacePrefixes: [String] { defaults.stringArray(forKey: "vmInterfacePrefixes") ?? ["bridge", "vnic"] }
    /// The VM shared networks: UTM (vmnet), Parallels shared and host-only,
    /// and VMware Fusion's NAT network (its subnet is picked at install time).
    var vmSubnets: [String] {
        defaults.stringArray(forKey: "vmSubnets") ?? ["192.168.64.0/24", "10.211.55.0/24", "10.37.129.0/24"] + [Settings.fusionSubnet()].compactMap { $0 }
    }
    /// Owner names (app names) of the VM windows: Parallels Desktop, UTM, VMware Fusion, OmacVM (OmacVM.app).
    var vmOwners: Set<String> {
        if let list = defaults.stringArray(forKey: "vmOwners"), !list.isEmpty { return Set(list) }
        if let one = defaults.string(forKey: "vmOwner") { return [one] }
        return ["Parallels Desktop", "UTM", "VMware Fusion", OmacVMApp.owner]
    }

    /// VMware Fusion's NAT network (vmnet8) as "a.b.c.0/24": the first
    /// VNET_8_HOSTONLY_SUBNET line of its settings, private addresses only.
    static func fusionSubnet() -> String? {
        guard let s = try? String(contentsOfFile: "/Library/Preferences/VMware Fusion/networking", encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 3, f[0] == "answer", f[1] == "VNET_8_HOSTONLY_SUBNET" else { continue }
            let o = f[2].split(separator: ".").compactMap { UInt8($0) }
            guard o.count == 4, o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) else { return nil }
            return "\(o[0]).\(o[1]).\(o[2]).0/24"
        }
        return nil
    }
}

extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}

/// What the controller keeps of each connected guest.
final class GuestInfo {
    let id: Int
    /// The app whose VM it runs in, from its "hello" (nil: not said, any VM app).
    var owner: String?
    /// The VM's name in that app, from "vmname" (nil: not said).
    var name: String?
    /// On its lock screen (see StripView.locked).
    var locked = false
    var cursorImages: [String: (CGImage, CGPoint, Int)] = [:]
    /// Its cursor size in logical px ("cursorsize"), nil if not sent.
    var cursorLogicalSize: Int?

    init(id: Int) { self.id = id }
}

final class Controller: NSObject, NSApplicationDelegate, StripInputDelegate {
    private let settings = Settings()
    private var link: GuestLink!
    private var panel: StripPanel?
    private var view: StripView?
    private var geometry: StripGeometry?
    /// The guest the strip serves, and whether its bar is parked.
    private var state = ParkState()
    private var parked: Bool { state.parked }
    private var guests: [Int: GuestInfo] = [:]
    private var activeGuest: GuestInfo? { state.active.flatMap { guests[$0] } }
    private var activeStream: GuestStream? { state.active.flatMap { link.stream(for: $0) } }
    /// The VM's full-screen window on the built-in display, tracked across Spaces.
    private var vmWindow: CGWindowID?
    private var misses = 0
    /// Set when the pointer left the strip; the guest cursor is shown again
    /// where the pointer lands in a VM window.
    private var pendingGuestCursor = false
    private var pollTimer: Timer?
    private var beatTimer: Timer?
    private var lastBackground: CGColor?
    private var cursorHider: VMCursorHider!
    /// Keeps timers running on schedule (App Nap would stretch the 1 s
    /// heartbeat past the guest's 5 s watchdog).
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = BackgroundCursor.enabled
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Mirrors the VM bar into the notch strip")
        cursorHider = VMCursorHider(vmOwners: settings.vmOwners, ownOwner: "Omanotch")
        cursorHider.onEnterVM = { [weak self] point, rect in self?.pointerEnteredVM(at: point, window: rect) }
        cursorHider.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.cursorHider.stop() }
        link = GuestLink(port: settings.port, interfacePrefixes: settings.interfacePrefixes,
                         subnets: settings.vmSubnets, onlyAddress: settings.listenHost)
        link.onMessages = { [weak self] id, messages in self?.handle(messages, from: id) }
        link.onConnectionChange = { [weak self] id, connected in self?.connectionChanged(id, connected) }
        link.start()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        // Entering and leaving full screen has no public notification for other
        // apps' windows; a cheap once-a-second poll covers it (Space, app and
        // screen changes are handled at once through the notifications above).
        // Timer tolerance lets macOS batch the wake-ups with others.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.evaluate() }
        pollTimer?.tolerance = 0.2
        // The guest notices a vanished helper through the connection itself;
        // this only has to beat its watchdog (15 s) comfortably.
        beatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.heartbeat() }
        beatTimer?.tolerance = 0.5
        evaluate()
        Log.info("started")
    }

    // MARK: state

    /// Decides whether the strip is shown, and tells the guest.
    ///
    /// The panel lives on the VM's full-screen Space: it is ordered in while
    /// that Space is active and then left alone, so it moves with the Space
    /// when switching. It is only removed when the VM leaves full screen on the
    /// built-in display (or the guest goes away). The guest bar stays parked
    /// meanwhile, so the VM does not re-layout on every Space switch.
    private func evaluate() {
        cursorHider?.refresh()
        // The full-screen VM window on the built-in display, of an app the
        // connected guests run in, and the guest for it.
        var front: StripGeometry?
        let connected = link.connectedIDs.compactMap { guests[$0] }
        if !connected.isEmpty {
            let owners = connected.contains { $0.owner == nil } ? settings.vmOwners : Set(connected.compactMap(\.owner))
            front = StripDetector.detect(vmOwners: owners)
        }
        if let f = front {
            let candidates = connected.map { GuestCandidate(id: $0.id, owner: $0.owner) }
            if let pick = GuestPicker.pick(candidates, owner: f.owner, current: state.active) {
                activate(pick)
            } else {
                front = nil  // none of the guests runs in this app
            }
        }
        let ready = state.active.map { link.isConnected($0) } == true && activeStream?.hasImage == true
        let visibleNow = ready ? front : nil

        if let g = visibleNow {
            misses = 0
            vmWindow = g.windowID
            if g != geometry || panel?.isVisible != true || panel?.isOnActiveSpace != true {
                showPanel(g)
                sendGeometry(g)
            }
            geometry = g
        } else if ready, let id = vmWindow, let g = geometry,
                  StripDetector.stillFullScreen(id, stripHeight: g.frame.height) {
            // The VM's Space is not in front (or is sliding): keep everything as
            // is, so the panel moves with that Space.
            misses = 0
        } else if !ready {
            vmWindow = nil
            geometry = nil
            hidePanel()
        } else if vmWindow != nil || geometry != nil {
            // Gone or no longer full screen; require two checks in a row.
            misses += 1
            if misses >= 2 {
                vmWindow = nil
                geometry = nil
                hidePanel()
            }
        }
        setParked(ready && vmWindow != nil)
        // The macOS cursor is only hidden over the app whose VM feeds the strip.
        cursorHider?.activeOwner = parked ? geometry?.owner : nil
        view?.activeOwner = parked ? geometry?.owner : nil
    }

    private func setParked(_ on: Bool) {
        let commands = state.setParked(on)
        guard !commands.isEmpty else { return }
        for c in commands { link.send(c.line, to: c.guest) }
        Log.info(on ? "strip shown, guest bar parked" : "strip hidden, guest bar restored")
    }

    /// Serves another guest: the old one gets its bar back, the new one is
    /// parked by the next evaluate().
    private func activate(_ id: Int) {
        guard id != state.active else { return }
        let old = state.active
        for c in state.activate(id) { link.send(c.line, to: c.guest) }
        let g = guests[id]
        Log.info("strip serves guest \(id)\(g?.name.map { " (\"\($0)\")" } ?? "")"
                 + (old.map { ", was guest \($0)" } ?? ""))
        vmWindow = nil
        geometry = nil  // the new guest gets the geometry when its strip is shown
        misses = 0
        misfitSince = nil
        pendingGuestCursor = false
        lastBackground = nil
        freshGuest = true
        view?.locked = g?.locked ?? false
        view?.targets = []
        view?.arrowCursor = .arrow
        view?.pointerCursor = .pointingHand
        arrowCursor = nil
        pointerCursor = nil
        for name in g?.cursorImages.keys.sorted() ?? [] { buildCursor(name) }
        link.send("targets", to: id)
        showFrame()
    }

    /// Sends one command line to the guest the strip serves.
    private func send(_ line: String) {
        link.send(line, to: state.active)
    }

    private var beats = 0
    private var flush = false

    /// Tells the guest where the camera housing is and how tall the strip is,
    /// so the hidden output (and the bar in it) fill the strip exactly.
    private func sendGeometry(_ g: StripGeometry) {
        // In guest logical px, which differ from points when the guest display
        // does not match the Mac point for point.
        // Points and the strip's width: notchcast converts with the guest
        // display's own width (robust while its hidden output is resized).
        send(String(format: "geom %.1f %.1f %.1f %.1f", g.notchLeft, g.notchRight, g.frame.height, g.frame.width))
        // Older notchcast builds only know these, converted here.
        let k = view?.guestPerPoint ?? 1
        send("notch \(Int((g.notchLeft * k).rounded())) \(Int((g.notchRight * k).rounded()))")
        send("strip \(Int((g.frame.height * k).rounded()))")
        // The bar's height in points (0: the whole strip); older notchcast
        // builds ignore it.
        flush = settings.flush
        send(String(format: "bar %.1f", flush && g.notchHeight > 0 ? min(g.notchHeight, g.frame.height) : 0))
    }

    /// Re-asserts the parked state every two seconds. notchcast turns this
    /// into a heartbeat file for the bar and re-parks a restarted Omarchy
    /// shell (which starts unparked). The notch geometry is refreshed too;
    /// notchcast only passes it on when it changed.
    private func heartbeat() {
        guard parked else { return }
        send("park 1")
        beats += 1
        // The flush setting is read again here, so `defaults write` takes
        // effect within two seconds, without a restart.
        if let g = geometry, beats % 5 == 0 || settings.flush != flush {
            if settings.flush != flush { Log.info("bar height: " + (settings.flush ? "the notch's (flush)" : "the menu bar's")) }
            sendGeometry(g)
        }
    }

    private func connectionChanged(_ id: Int, _ connected: Bool) {
        // A new session (also a takeover from the same address) starts over:
        // the guest starts unparked.
        state.reset(id, gone: !connected)
        guests[id] = connected ? GuestInfo(id: id) : nil
        if id == state.active {
            view?.locked = false
            send("targets")
            if let g = geometry { sendGeometry(g) }
        } else if !connected && state.active == nil {
            // The served guest is gone: start over with the next one.
            vmWindow = nil
            geometry = nil
        }
        evaluate()
    }

    private func handle(_ messages: [GuestMessage], from id: Int) {
        guard let guest = guests[id] else { return }
        let active = id == state.active
        var gotFrame = false
        var changed = false
        for m in messages {
            switch m {
            case .frame:
                gotFrame = true
            case .text(let text):
                changed = handleText(text, from: guest, active: active) || changed
            case let .cursor(name, image, hotSpot, nominal):
                setCursor(name: name, image: image, hotSpot: hotSpot, nominal: nominal, for: guest, active: active)
            }
        }
        // Frames of the other guests only keep their image up to date.
        if active && gotFrame {
            if panel == nil || geometry == nil { evaluate() }
            showFrame()
        }
        if changed { evaluate() }
    }

    /// Since when frames have had a shape that does not fit the strip.
    private var misfitSince: Date?

    /// Shows the latest frame. While the guest's hidden output is being
    /// resized (a display change, a Hyprland reload), frames can briefly have
    /// a shape that does not fit the strip; the last good frame stays up for
    /// up to two seconds instead, so the strip does not visibly jump.
    private func showFrame(force: Bool = false) {
        guard let view, let stream = activeStream, let image = stream.makeImage() else { return }
        // The first frame of a newly served guest is shown as it is.
        let force = force || freshGuest
        freshGuest = false
        if !force, view.bounds.width > 0, view.bounds.height > 0, view.hasImage {
            // In guest logical px: the strip's height at this image's width,
            // against the image's height. A few px off is whole-pixel rounding
            // of the hidden output (fractional scales), not a resize.
            let w = CGFloat(image.width) / stream.scale, h = CGFloat(image.height) / stream.scale
            let expected = view.bounds.height * w / view.bounds.width
            if abs(h - expected) > max(4, expected * 0.03) {
                let since = misfitSince ?? Date()
                if misfitSince == nil {
                    misfitSince = since
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
                        guard let self, self.misfitSince == since else { return }
                        self.showFrame(force: true)  // it is how the guest looks now
                    }
                }
                if Date().timeIntervalSince(since) < 2 { return }
            } else {
                misfitSince = nil
            }
        }
        let bg = stream.backgroundColor()
        view.show(image: image, scale: stream.scale, background: bg == lastBackground ? nil : bg)
        lastBackground = bg
    }

    /// The next frame is the first one of a newly served guest.
    private var freshGuest = false
    private var arrowCursor: NSCursor?
    private var pointerCursor: NSCursor?

    /// Guest cursors are sized for its display (e.g. 48 px for 24 pt at 2x).
    private func setCursor(name: String, image: CGImage, hotSpot: CGPoint, nominal: Int, for guest: GuestInfo,
                           active: Bool) {
        Log.info("guest \(guest.id) cursor \(name): \(image.width)x\(image.height) px (nominal \(nominal))")
        guest.cursorImages[name] = (image, hotSpot, nominal)
        if active { buildCursor(name) }
    }

    /// The guest cursor as it looks in the VM window: N px at guest scale S
    /// are N/S guest logical px, which are N/(S*k) strip points.
    private func buildCursor(_ name: String) {
        guard let guest = activeGuest, let (image, hotSpot, nominal) = guest.cursorImages[name] else { return }
        let k = view?.guestPerPoint ?? 1
        // px per strip point. With the guest's cursor size known: the image is
        // `nominal` px for `cursorLogicalSize` logical px (Hyprland scales the
        // theme image it picks to exactly that size), which are /k points.
        // Older guests: assume the image matches the output scale.
        var d = (activeStream?.scale ?? 2) * k
        if let size = guest.cursorLogicalSize, size > 0, nominal > 0 {
            d = CGFloat(nominal) / CGFloat(size) * k
        }
        let cursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / d,
                                                                          height: CGFloat(image.height) / d)),
                              hotSpot: NSPoint(x: hotSpot.x / d, y: hotSpot.y / d))
        switch name {
        case "arrow": arrowCursor = cursor; view?.arrowCursor = cursor
        case "pointer": pointerCursor = cursor; view?.pointerCursor = cursor
        default: break
        }
    }

    /// Returns whether the guest's owner or name changed.
    private func handleText(_ text: String, from guest: GuestInfo, active: Bool) -> Bool {
        if text.hasPrefix("cursorsize "), let size = Int(text.dropFirst("cursorsize ".count)) {
            guest.cursorLogicalSize = size
            if active { for name in guest.cursorImages.keys { buildCursor(name) } }
        } else if text == "lock 1" || text == "lock 0" {
            guest.locked = text == "lock 1"
            if active { view?.locked = guest.locked }
            Log.info("guest \(guest.id) " + (guest.locked ? "session locked" + (active ? ": strip blank" : "") : "session unlocked"))
        } else if text.hasPrefix("hello ") {
            let hv = String(text.dropFirst("hello ".count))
            // An app that is not a VM app here (vmOwners) could be any of them.
            // OmacVM.app's VMs (QEMU too) come in on 127.0.0.1.
            guest.owner = link.viaOmacVMApp(guest.id) ? OmacVMApp.owner
                : GuestPicker.owner(hello: hv).flatMap { settings.vmOwners.contains($0) ? $0 : nil }
            Log.info("guest \(guest.id) runs in \(hv) (\(guest.owner ?? "any VM app"))")
            return true
        } else if text.hasPrefix("vmname ") {
            guest.name = GuestPicker.vmName(base64: String(text.dropFirst("vmname ".count)))
            Log.info("guest \(guest.id) is VM " + (guest.name.map { "\"\($0)\"" } ?? "(name not readable)"))
            return true
        } else if !active {
            // targets: only the served guest's count
        } else if text.hasPrefix("targets ") {
            let json = Data(text.dropFirst("targets ".count).utf8)
            if let arr = try? JSONSerialization.jsonObject(with: json) as? [[Double]] {
                view?.targets = arr.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            }
        }
        return false
    }

    // MARK: panel

    private func showPanel(_ g: StripGeometry) {
        if panel == nil {
            let p = StripPanel(frame: g.frame)
            let v = StripView(frame: NSRect(origin: .zero, size: g.frame.size))
            v.autoresizingMask = [.width, .height]
            v.input = self
            v.vmOwners = settings.vmOwners
            v.locked = activeGuest?.locked ?? false
            v.onGuestScaleChange = { [weak self] in
                guard let self else { return }
                Log.info(String(format: "guest bar: %.3f logical px per strip point", self.view?.guestPerPoint ?? 1))
                // Cursors first: they must follow even while the strip is hidden.
                for name in self.activeGuest?.cursorImages.keys.sorted() ?? [] { self.buildCursor(name) }
                if let g = self.geometry { self.sendGeometry(g) }
            }
            if let arrowCursor { v.arrowCursor = arrowCursor }
            if let pointerCursor { v.pointerCursor = pointerCursor }
            p.contentView = v
            panel = p
            view = v
            if let stream = activeStream, let image = stream.makeImage() {
                v.show(image: image, scale: stream.scale, background: stream.backgroundColor())
            }
            send("targets")
        }
        panel?.setFrame(g.frame, display: true)
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        view?.resetHover()
        panel?.orderOut(nil)
    }

    // MARK: StripInputDelegate

    func stripClicked(x: CGFloat, y: CGFloat, button: Int) {
        send(String(format: "click %.1f %.1f %d", x, y, button))
        // Widgets can change size after a click (e.g. a panel toggles an icon).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.send("targets") }
    }

    func stripScrolled(x: CGFloat, y: CGFloat, steps: Int) {
        send(String(format: "wheel %.1f %.1f %d", x, y, steps * 120))
    }

    func stripHoverChanged(_ inside: Bool, exit: (direction: String, x: CGFloat)?) {
        // Only one cursor at a time: the guest hides its own while the pointer
        // is over the strip, where the helper shows the guest's cursor images.
        if inside {
            pendingGuestCursor = false
            send("cursor 0")
            cursorHider.pointerOnStrip(showAfter: 0.045)
            send("targets")
        } else if exit != nil {
            // Show the guest cursor once the pointer lands in a VM window (at
            // that exact spot, see pointerEnteredVM). If it lands elsewhere,
            // show it anyway after a moment so it is never left hidden.
            pendingGuestCursor = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.pendingGuestCursor else { return }
                self.pendingGuestCursor = false
                self.send("cursor 1")
            }
        } else {
            pendingGuestCursor = false
            send("cursor 1")
        }
    }

    /// The pointer arrived over a full-screen VM window (CG coordinates).
    private func pointerEnteredVM(at p: CGPoint, window: CGRect) {
        guard pendingGuestCursor, let screen = StripDetector.builtinScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }
        pendingGuestCursor = false
        let builtin = CGDisplayBounds(number.uint32Value)
        let x = p.x - builtin.minX
        // In guest logical px: the guest may not match the Mac point for point.
        let k = view?.guestPerPoint ?? 1
        if window.maxY == builtin.maxY {
            // Back into the built-in display's VM window, below the strip.
            send(String(format: "cursor 1 down %.1f %.1f", x * k, (p.y - window.minY) * k))
        } else if window.maxY <= builtin.minY {
            // Up to the display above.
            send(String(format: "cursor 1 up %.1f %.1f", x * k, window.maxY - p.y))
        } else {
            send("cursor 1")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
