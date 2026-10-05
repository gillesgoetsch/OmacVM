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
- One display at a time. The window can go to an external display and be full
  screen there, but Omarchy gets one screen, not one per Mac display.
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
  only the app's user can open. The battery goes one way; the VM can only ask
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

## Why one display

QEMU's macOS window (its "cocoa" display) shows one guest screen at a time:
it has a single window and a single display listener, and its View menu
switches between screens. Parallels and VMware Fusion open a window per
display; QEMU on the Mac does not. Two ways to get there, neither done:

- Teach the cocoa display one window per guest screen. Most of its code
  assumes one window (global view, one GL context, mouse coordinates for one
  screen), so this is a larger patch, plus routing the pointer to the right
  screen in Hyprland. Several days.
- QEMU's SDL display opens a window per screen, but it lacks everything the
  cocoa patches add here: the window size the VM follows, the notch strip,
  ⌘ as Super, pinch and smooth scrolling.
