# OmacVM.app

Omarchy in its own Mac app, without Parallels, UTM or VMware Fusion. The app
brings QEMU (built from try-omarchy's patched source) and runs it with Apple's
Hypervisor framework. The GPU goes through VirGL on the Mac's OpenGL.

Source: [`app/`](../../app/README.md) in this repo (the launcher, QEMU's build
scripts and patches, the VM build script); it carries OmacVM's `src/` and has
OmacVM's version.

## Get it

- `omacvm build --vm-type app`: when the app is missing, OmacVM offers to
  download it (below) and goes on with the build.
- Or download `OmacVM-<version>.zip` from the
  [releases](https://github.com/gillesgoetsch/omacvm/releases) (signed with
  a Developer ID), unzip it and open it: it offers to install itself in
  Applications, keeping that signature (under another name it is signed
  again ad hoc). Downloaded with a
  browser, macOS blocks it the first time: click Open Anyway in System
  Settings › Privacy & Security.

`omacvm update` replaces an older OmacVM.app with the one for its version
(not while the app is open), and keeps the name it was installed under.

## What works

- Setup in the app: VM name, user, password, resources, disk size, where the
  disk goes (any APFS or Mac OS Extended drive).
- The build: the same steps as the other routes (try-omarchy as a temporary
  live system, Arch Linux ARM on btrfs with GRUB, Omarchy from omarchy-mac,
  OmacVM's VM side). 10 to 30 minutes (8 on an M4 Max), plus a 1.4 GB
  download the first time.
- A normal install: boots through UEFI and GRUB, so `omarchy update` and
  snapshots work.
- The window: Omarchy follows its size and the display's refresh rate
  (120 Hz on a MacBook Pro).
- GPU in browsers: WebGL 1 and 2 on the hardware in Chromium, Google Chrome,
  Brave and Firefox (`virgl (Apple M4 Max)`), no flags.
- Video decoding on the Mac's media engine (since 2.7.0): H.264, VP9 and AV1
  in Google Chrome (YouTube 4K at 60 fps, the VM's CPU nearly idle), VP9 in
  Brave, H.264 and VP9 in Firefox (AV1 not yet), H.264, VP9 and HEVC in mpv,
  FFmpeg and GStreamer apps. Omarchy's Chromium (Arch Linux ARM) is built
  without VA-API and decodes on the CPU for now; a route for it (V4L2) is
  planned. [How it works](../video-decode.md).
- Quit, the window's close button, logging out and restarting the Mac shut
  Omarchy down cleanly first. The Mac's sleep pauses the VM; after waking,
  the VM's clock is set to the Mac's.
- Full screen in its own Space, below the notch, like Parallels; Omanotch puts
  Omarchy's bar into the strip beside the notch, as on the other routes.
- Every Mac display in full screen: with an external display connected, full
  screen opens a window on each Mac display (each in its own Space) and
  Omarchy gets one output per display (Virtual-1 the main window, Virtual-2,
  ...), each at that display's resolution, scale and refresh rate, placed as
  in macOS's arrangement. Plugging a display in or out works live: its
  workspaces move to the main display and come back with it, as on a
  laptop. Leaving full screen closes the other windows; in a window Omarchy
  has one screen. Omanotch's strip stays on the MacBook whichever display
  holds the main window: the app tells the VM which output is the built-in
  display. Omarchy's display panel (the monitor icon in the bar) has
  **Use external displays**: off, full screen stays on one display. The VM
  keeps the setting (`~/.config/omacvm/displays.conf`; also
  `omacvm-displays external on|off`).
- ⌘ shortcuts (⌘Space too) go to Omarchy as Super in full screen, through
  OmacVM Gestures, as on UTM: the app needs no Accessibility of its own.
- Optional notch-strip mode (a switch in the app): the window covers the
  strip itself and Omarchy's bar moves there, but that full screen has no
  Space of its own (macOS 15 keeps full-screen Spaces below the notch).
- Install under a name: OmacVM, Omarchy or your own; it shows in the Dock.
- Clipboard both ways, text and images (try-omarchy's agent, over a virtio
  port, not the network).
- Sound through the Mac (QEMU's HDA card; PipeWire in the VM), and the Mac's
  microphone: the app asks for it when it starts a VM, because QEMU cannot
  ask itself and records nothing without it ([finding 22](../troubleshooting.md#22-parallels-fusion-app-the-microphone-records-nothing-or-silence)).
  Until you allow it, the VM starts without recording (QEMU would wait
  minutes for an answer): allow it, then restart the VM. QEMU starts the
  recording on a thread of its own, so the VM never stops for it; until the
  microphone runs, the VM records silence.
- The Mac's camera as *Mac Camera* (`/dev/video42`): QEMU has a virtio port
  `org.omacvm.camera`, the launcher serves it with the Bridge's camera code
  (`src/bridge/mac/camera.swift`) and turns the camera on only while a Linux
  app reads it. macOS asks for the camera for OmacVM the first time.
- The Mac's battery in Omarchy's bar, on a MacBook: charge, charging and
  Omarchy's battery panel; time left and the low-battery warning are not
  tested yet with the Mac on battery (try-omarchy's bridge, over a virtio
  port; [how it works](../../src/battery/README.md)).

## From the omacvm command

`omacvm build --vm-type app` (or OmacVM.app in the build's first question)
builds the VM through the app instead of in it. The questions and the summary
are the same as for the other routes; the VM goes into the app's VMs folder
(set in the app; no `--vm-dir`). Then:

1. It finds the app in /Applications or ~/Applications by its bundle id
   (`org.omacvm.app`, under any name it was installed as). Not installed:
   after asking, it downloads `OmacVM-<version>.zip` (this OmacVM's version)
   from the GitHub release `v<version>` with curl, checks it against the
   `.sha256` next to it and that the app is signed with OmacVM's Developer
   ID (team 722686Y34B), and puts it in /Applications (or ~/Applications when
   /Applications is not writable). curl sets no quarantine attribute, so
   Gatekeeper does not stop the app. Releases from before the app have no
   zip: it says so and stops (exit 3). With `--yes` it installs nothing and
   stops with the command to run (exit 3).
2. It writes the VM's `vm.env` as the app does (name, CPUs, memory, disk,
   a free SSH port from 52222, user, hostname, timezone, language, keyboard,
   features) and runs the app's `Contents/Resources/scripts/create-vm.sh`
   with the password on stdin: the same script and steps as a build in the
   app. It leaves the VM shut down.
3. `omacvm apply` from this checkout, which starts the VM in the app, then a
   reboot, as on the other routes.

No Homebrew tools are needed (the app brings QEMU and zstd). OmacVM.app runs
one VM at a time: the build stops at the start while another one runs.

## What needs a person

- The password for Omarchy, typed in the setup.
- macOS asks whether OmacVM may find devices on local networks the first
  time the Developer ID build starts a VM: allow it.
- The permissions OmacVM's Mac helpers ask for (as on the other routes).

## Not done yet

- The Bridge's features (Wi-Fi, Bluetooth, media keys and the rest) and
  trackpad gestures: the build installs Bridge and Gestures on the Mac and
  they accept the VM on 127.0.0.1 (below), but these are not confirmed on
  this route yet.
- Every Mac display: up to five (the window and four more). Tested with one
  real external monitor and with virtual displays; two or more real
  monitors are not tested yet.
- When another app takes over a display (it shows that app's desktop there)
  or the display with the main window is unplugged and plugged in again,
  macOS may leave the other display on its desktop after you come back to
  OmacVM. Swipe to OmacVM's Space on that display (Control-arrow or
  Mission Control); the pointer goes to Omarchy again once its window shows.
- The app needs Xcode's Command Line Tools (it builds OmacVM's Mac helpers);
  it checks for them before a build and offers to install them.

## How it talks to the Mac

QEMU's user network: the Mac is `10.0.2.2` for the VM, and the Mac reaches
the VM's SSH on `127.0.0.1:<port>`.

- The VM reaches only three of the Mac's local ports through `10.0.2.2`:
  47811 (Omanotch), 47830 (Gestures) and 47831 (Bridge). Everything else the Mac runs on
  127.0.0.1 (dev servers, databases) is refused, like on the other routes.
  The app's QEMU carries a libslirp patch for that
  (`OMACVM_SLIRP_HOST_PORTS`).
- The clipboard and the Mac's battery do not use the network: each has its
  own virtio port (`org.omacvm.clipboard`, `org.omacvm.battery`) on a socket
  only the app's user can open. So do the displays (`org.omacvm.display`,
  below). The battery goes one way; the VM can only ask
  for a fresh reading.
- Gestures and Bridge also listen on the Mac's 127.0.0.1, where any Mac
  program could connect, or listen in their place while they are not
  running. So the VM gives the Bridge's token to neither before it has proved
  it knows it (HMAC-SHA256 of a fresh nonce and the Mac address it answered
  on, which must be 127.0.0.1: a proof passed on from the helper on
  10.211.55.2 fails): Gestures then wants the VM's own proof (the token
  never goes over the wire, and the VM acts on no key or gesture before the
  proof); the Bridge gets the token on each request after `GET /proof`.
  The app makes the token when the Bridge has not, and puts it into the VM.
- Not covered yet, so the token is not safe from Mac programs on this route:
  VMs set up before the proof still send the token straight away (to
  whatever listens) until their next `omacvm apply`, and so does an
  Omanotch installed before it came with OmacVM (its notchcast sends
  `auth <token>` to 47811). The Omanotch in `src/omanotch` proves it the same
  way (`mac/Sources/GuestAuth.swift`).
- Omanotch (47811) needs a version that serves 127.0.0.1; `omacvm apply` and
  `omacvm check` say when the one on the Mac is older.
- `omacvm apply` writes `guest-pointer` into the VM's folder once the VM
  draws Omarchy's own pointer; VMs set up before that still need the Mac's
  pointer (QEMU's `show-cursor=on`).

## Fast network (experimental, off by default)

`omacvm enable fast-network --vm NAME` puts the VM on macOS's own VM network
(vmnet, shared mode, as Parallels and UTM) instead of QEMU's user network.
The VM gets an address of its own on `192.168.64.0/24`, the Mac is
`192.168.64.1` for it, and traffic between the VM and the Mac no longer goes
through one QEMU thread. Measured: see
[the numbers](../benchmarks/README.md#fast-network-omacvmapp).

- vmnet needs root or Apple's `com.apple.vm.networking` entitlement, which the
  app does not have. So `omacvm enable fast-network` builds and installs a
  small system service, `omacvm-netd` (`src/net/mac`), and macOS asks for your
  password once. launchd starts it when a VM connects; it quits a minute
  after the last one went.
- The service only takes connections from OmacVM.app's QEMU: it checks the
  connecting process's code signature (OmacVM's Developer ID team, or for an
  app built from source exactly that build: enable it again after a rebuild).
  It makes one vmnet interface per VM, isolated from the other VMs'
  interfaces, and does nothing else: no commands, no files, no other requests.
- The app picks the network at each start: the fast network when the VM has
  it (its `fast-network` file, with its own MAC address), the service is
  there and would take this app's QEMU; else QEMU's user network as before.
  `logs/network` and `qemu.log` say which and why; `omacvm check` shows it.
- On the fast network the Mac reaches the VM's SSH on its own address (from
  macOS's DHCP leases), with the same remembered host key; the VM lets SSH in
  from `192.168.64.1` only. The VM's Bridge and Gestures find the Mac at the
  gateway and prove it with that address, as on UTM.
- `omacvm disable fast-network` goes back at the next start; `omacvm
  uninstall` removes the service.

What is missing before it can become the default: [below](#fast-network-not-done-yet).

### Fast network: not done yet

- Omanotch over the fast network (its notchcast still looks for the Mac at
  `10.0.2.2` in app VMs).
- Tested on a Mac mini (macOS 27): SSH, DNS, IPv6, the Bridge (proof on
  `192.168.64.1`), a restart of the service under a running VM (QEMU
  reconnects, about 1 s without network), the VM paused for a minute (as over
  the Mac's sleep), and the fallback to the user network without the service.
- Not tested yet: VPN clients on the Mac, a real sleep and wake, Wi-Fi
  changes while the VM runs, several app VMs at once, trackpad gestures over
  the fast network, and the MacBook (numbers there too).
- The service is built on the Mac (Xcode's Command Line Tools) and installed
  from the omacvm command; the app has no button for it yet.

## Every Mac display

QEMU's macOS window (its "cocoa" display) showed one guest screen. OmacVM's
QEMU patch (`app/runtime/patches/omacvm-cocoa-displays.patch`) gives it a
window per guest screen:

- The VM has a virtio-gpu with five outputs. In full screen, each other Mac
  display gets a window of its own, full screen in its own Space, showing
  the next output; QEMU tells the VM that output's size, scale (as the EDID's
  pixel density) and refresh rate, as for the main window. Outputs without a
  window are disconnected.
- Linux's virtio-gpu driver has no place for an output's position, so the
  arrangement goes over a virtio port, `org.omacvm.display`, from QEMU's
  window code to `omacvm-displays` in the VM (a user service), which writes
  it for `omacvm-display-sync`; that places each output as the Mac's
  displays are. A display with its own rule in `monitors.lua` keeps it.
- QEMU opens the other windows only after `omacvm-displays` said hello on
  that port (a VM without it keeps one screen) and while the switch is on.
  It applies the VM's switch at most once a second, and it takes only
  numbers it can use from the port: anything else is ignored.
- The pointer: the VM has one tablet, and Hyprland spreads it over the box
  around all its outputs. `omacvm-displays` reports where Hyprland put each
  output, and QEMU points the tablet at the matching spot of that box, so
  the pointer lands where it is on the Mac, also with Omarchy's zoom.
  The other displays' windows take the pointer (and with it the keyboard)
  only while OmacVM.app is in front, or on a click; another app coming to
  the front gets both back.
- A drag keeps the pointer from one display to the next, also across the
  menu bar strip above a full-screen window on a MacBook with a notch, so
  ⌘-dragging a window moves it to the other display. QEMU reads the
  modifier keys only from input events
  (`qemu-cocoa-modifiers-input-only.patch`): the pointer entering another
  window comes without them and used to let go of Super mid-drag.
- On a Mac with a notch, macOS's full screen ends below the menu bar, a few
  points lower than the screen's safe area. Each output gets its window's
  real size once the window is in full screen
  (`omacvm-cocoa-fullscreen-size.patch`), so the picture is not squeezed
  and the pointer is exact. For the main window that size is the area macOS
  gives full screen, not the view: the view is letterboxed while the guest
  reboots, and sizing from it shrank the output on every reboot
  (`omacvm-cocoa-fullscreen-area.patch`).
- Two outputs switched at once could leave Linux with an old list (it
  clears the display event after reading); a small virtio-gpu patch
  (`qemu-virtio-gpu-display-event-race.patch`) raises the event again.
- A display with only Hyprland's dark grey (no wallpaper, no bar) means the
  shell draws nothing there. The cause found: QEMU refused the memory of a
  big texture (the wallpaper) when it came in more than 16384 pieces, as it
  does in fragmented guest memory, and virglrenderer then dropped the
  shell's GPU context (`qemu-virtio-gpu-mapping-entries.patch` allows 262144
  pieces: at least 1 GiB even when every piece is a single 4 KiB page).
  `omacvm-displays` also looks at what each display shows (a small
  screenshot) after the shell starts and after the layout changes; a display
  that shows only the grey with no window on it gets the shell restarted
  (not while locked, at most every 2 minutes, 3 times per session, not again
  when a restart changed nothing; `repair-shell=off` in
  `~/.config/omacvm/displays.conf` turns that off). `omacvm check` says
  "desktop" in the VM and "GPU contexts" on the Mac (QEMU's log).
- Outputs move when displays come and go. Omarchy's remap for a layer
  surface left at its output's old place never fires (it waits for x/y
  signals Quickshell's screens do not have); Omanotch's patched bar and
  wallpaper remap themselves when their output moves.
- In full screen the Dock and the menu bar stay hidden on every display, and
  the Mac's cursor stays 3 points off the screen corners while the VM has
  the pointer (`omacvm-cocoa-fullscreen-edges.patch`; `immersive=off` turns
  both off). That is meant to keep hot corners from firing, but it is not
  confirmed: with simulated mouse motion the bottom-left corner still fired,
  and a check with a real mouse is open.

Testing without a monitor: `app/scripts/dev/virtual-display.m` makes a
virtual Mac display (killing it is unplugging it). With
`OMACVM_TEST_SKIP_DISPLAYS=<the real displays' ids>` (and
`OMACVM_TEST_MAIN_DISPLAY=<id>` for the main window), QEMU uses only the
other displays, "full screen" is a plain window over each display (no
Space, no menu bar change) and QEMU never takes the focus.
`OMACVM_TEST_ONLY_DISPLAYS=<ids>` keeps real full screen but gives windows
only to those displays (another test's virtual display is left alone).
`OMACVM_DISPLAYS_DEBUG=1` logs what goes over the port (QEMU's log).
