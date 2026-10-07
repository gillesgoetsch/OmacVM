# OmacVM.app

Omarchy in its own Mac app, without Parallels, UTM or VMware Fusion. The app
brings QEMU (built from try-omarchy's patched source) and runs it with Apple's
Hypervisor framework. The GPU goes through VirGL on the Mac's OpenGL.

Source: [`app/`](../../app/README.md) in this repo (the launcher, QEMU's build
scripts and patches, the VM build script); it carries OmacVM's `src/` and has
OmacVM's version.

## Get it

OmacVM.app needs macOS 15 or newer on an Apple Silicon Mac (the other
routes run on macOS 14).

- `omacvm build --vm-type app`: when the app is missing, OmacVM offers to
  download it (below) and goes on with the build.
- Or download `OmacVM-<version>.zip` from the
  [releases](https://github.com/gillesgoetsch/omacvm/releases) (signed with
  a Developer ID), unzip it and open it: it offers to install itself in
  Applications, keeping that signature (under another name it is signed
  again ad hoc). A newer download starts on the name and folder of the copy
  you installed before, so Install replaces it in place. Run Without
  Installing counts for that copy only: the next download asks again. Updates
  (`omacvm update`) never ask. Downloaded with a
  browser, macOS blocks it the first time: click Open Anyway in System
  Settings › Privacy & Security.

`omacvm update` replaces an older OmacVM.app with the one for its version
(not while the app is open), and keeps the name it was installed under.
The app also updates itself, once a week unless switched off, never while a
VM runs, and goes back by itself when a new version does not start
([app README](../../app/README.md#updates)).

## What works

- Setup in the app: VM name, user, password, resources, disk size, the VMs
  folder (any APFS or Mac OS Extended drive).
- Where things are: the app in `~/Applications`, the VMs in
  `~/OmacVM/<VM name>/`; moves, other drives, sizes and downloads:
  [where things are](#where-things-are).
- A VM folder from another Mac: copy it into `~/OmacVM/` once (the app runs
  one VM at a time, the first folder by name). Check that the app looks there:
  `~/Applications/OmacVM.app/Contents/MacOS/OmacVM --vms-folder` (or the
  same under `/Applications`) must print the same as `echo ~/OmacVM` (a home
  folder can be on another drive, under `/Volumes`). If it prints another
  folder, move the VM folder there and use that path below. Open the app and
  start the VM. Then, with the VM running, set up this Mac's side (Bridge, Gestures, clock, token) with
  `bash ~/Applications/OmacVM.app/Contents/Resources/scripts/apply-vm.sh ~/OmacVM/<VM name>`
  (or `omacvm apply --vm "<VM name>" --vm-type app`). If it says there is no
  SSH access, the VM does not know this Mac's key yet: `omacvm apply` prints
  the one command to run in the VM's terminal.
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
  without VA-API: H.264 and VP9 (YouTube) go through a V4L2 decoder OmacVM
  adds to the VM (feature `chromium-video`, on by default). [How it works](../video-decode.md).
- A new frame goes to the window as soon as Omarchy finishes it, drawn off
  the main thread as an IOSurface (before, QEMU redrew the window on a 30 ms
  timer). GPU fences come back in about 0.2 ms instead of 1.5 ms, so light 3D
  work runs two to three and a half times as fast (glmark2's short set
  2,800-3,700 instead of 1,000-1,500). WebGL-heavy pages stay the same on a
  quiet Mac (Aquarium 21-23 fps): there Apple's OpenGL is the limit. While
  other VMs use the Mac they ran about 10% slower than with the old path;
  with only the CPU busy, about 15% faster ([how](../architecture/graphics.md)).
  If the picture or the GPU misbehaves on a Mac: `defaults write
  org.omacvm.app gpuSafeMode -bool true` and restart the VM goes back to the
  2.8.0 fence and frame path; `omacvm check` shows which path a VM took.
- Graphics, per VM: **OpenGL**, **Vulkan** or **Automatic** (the default),
  in the app's setup and VM window, with `omacvm graphics --vm NAME
  opengl|vulkan|auto`, or on the control centre's Graphics row. OpenGL:
  Omarchy, its apps and browsers draw with OpenGL on the Mac's GPU (virgl),
  as up to 2.9. Vulkan: the same, plus Vulkan on the Mac's GPU (Venus) for
  Vulkan apps: on KosmicKrisp on macOS 26 and newer (in the app since 3.0.0),
  on MoltenVK before (fewer Vulkan features). OpenGL stays on virgl either
  way, so Vulkan only adds Vulkan apps; Vulkan windows reach the screen
  by a copy on the Mac (on KosmicKrisp since 3.0.1, before through the VM's
  software copy, slow in full screen). Automatic is OpenGL on every Mac in 3.0.0
  ([numbers and why](../benchmarks/README.md#graphics-automatic-2026-10-05)).
  A change applies at the
  VM's next start; `omacvm check` shows what the start got ("Graphics" row)
  and which Vulkan driver the Mac used ("Vulkan (Venus)": KosmicKrisp, or
  MoltenVK when KosmicKrisp cannot run on that Mac, logged).
  The VM needs a Venus driver that sizes GPU memory to the Mac's 16 KiB
  pages (Mesa 26.2.4 or newer; with Arch Linux ARM's 26.2.3 every Vulkan app
  fails with `ERROR_OUT_OF_HOST_MEMORY`). Apply builds Mesa 26.2.4's Venus
  driver as Arch's own `vulkan-virtio` package, with OmacVM's patch for the
  shared semaphores Chrome's WebGPU needs (version `26.2.4.omacvm1`,
  [`src/app/guest/venus`](../../src/app/guest/venus), a few minutes the
  first time) when the setting gives the VM Vulkan (also
  `omacvm graphics --vm NAME vulkan` on a running VM). When the VM's
  package list is too old for the build tools (a prebuilt VM a day after
  its image: the mirrors no longer have those versions), `omacvm graphics`
  and the control centre's Graphics -> Vulkan first update the whole
  system the way `omarchy update` does
  ([`src/guest/system-update`](../../src/guest/system-update), then the GBM
  test; in a terminal `omacvm graphics` asks first) and stop with the
  reason if the update fails. `omacvm apply` and `omacvm update` never
  update the VM's system: they say to run `omarchy update` first. Arch's
  own builds of 26.2.4 do not replace it; a newer Mesa from Arch does
  (Vulkan keeps working, WebGPU in Chrome waits for OmacVM's next build of
  it; the check says so). VMs from 3.0.0 rebuild it once, after the next
  start or with `omacvm apply`. Until the driver is there the VM starts with
  OpenGL only, and the app, `omacvm graphics` and the control centre say
  "Vulkan (driver not built yet: runs on OpenGL until the next apply)". In the
  VM `omacvm-venus-driver.timer` checks again 90 s after boot, after the
  desktop, never in the boot's critical chain. Automatic is OpenGL on every
  Mac in 3.0.0 (CHANGELOG).
  OpenCL comes with it: apply installs Arch's `opencl-mesa` (rusticl) and
  `clinfo` and turns rusticl's Zink on (`RUSTICL_ENABLE=zink` in
  `/etc/environment.d/90-omacvm-opencl.conf`, for apps started after the
  next login), so OpenCL apps (Geekbench, darktable, ffmpeg) run on the
  Mac's GPU through Zink on Venus ([`venus/opencl.sh`](../../src/app/guest/venus/opencl.sh);
  OpenGL turns the switch off again). That works on KosmicKrisp (macOS 26
  and newer). On MoltenVK Zink refuses the device (no `nullDescriptor`):
  there OpenCL needs the vulkan feature below. `omacvm check` has an
  "OpenCL (rusticl on Zink)" row. WebGPU in Chromium comes with it too: a
  "Chromium (WebGPU)" menu entry ([`venus/webgpu.sh`](../../src/app/guest/venus/webgpu.sh))
  starts Chromium (`omacvm-chrome-webgpu`: Google Chrome) with its
  compositor on Vulkan, which Chrome needs before it gives pages the Mac's
  GPU for WebGPU; the normal Chromium entry stays as it is (that mode costs
  WebGL about a fifth). `omacvm check` has a "WebGPU in Chromium" row.
  Vulkan's host memory window (Venus' `hostmem`) comes from the VM's memory
  plan: what the Mac has beyond the VM's memory and macOS's reserve (4 GB up
  to 16 GB of memory, 6 GB up to 36 GB, 8 GB above), 1 to 32 GB; what Vulkan
  allocates counts against the VM's GPU memory budget.
  The hidden `venus` switch of 2.9 is gone: the app's first 3.0.0 launch
  moves it into the setting (Vulkan for each VM without its own choice).
- WebGPU and GPU compute (experimental, off by default):
  `omacvm enable vulkan --vm NAME`, then shut the VM down and start it again.
  The VM gets OpenCL (rusticl on Zink), WebGPU in Firefox, and a
  "Chromium (WebGPU)" menu entry that starts Chromium with WebGPU on the
  Mac's GPU (the normal Chromium keeps its software WebGPU: its Vulkan mode
  costs WebGL about a fifth), with OmacVM's own Mesa (pinned 26.2.4 with
  five patches) in `/opt/omacvm-mesa`, and Vulkan whatever the Graphics
  setting. The first time the VM builds that Mesa: about 3 minutes on an M4
  Max and a 140 MB download (Mesa's source and Rust; Omarchy has LLVM and
  Clang already). The build tools it adds (Rust, meson, ninja, bindgen) are
  removed after the build. If the build fails, the feature stays off and
  apply says so (log: `/var/log/omacvm-mesa-build.log` in the VM).
  `omacvm disable vulkan` removes it. Numbers:
  [benchmarks](../benchmarks/README.md#gpu-compute-with-venus-2026-10-04),
  how it works: [ADR 0022](../adr/0022-webgpu-and-opencl-on-venus.md).
- Quit, the window's close button, logging out and restarting the Mac shut
  Omarchy down cleanly first. The Mac's sleep pauses the VM; after waking,
  the VM's clock is set to the Mac's.
- Full screen, like Parallels: macOS's own, in a Space of its own on every
  display; on a MacBook with a notch Omanotch puts Omarchy's bar beside the
  notch (below).
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
  With the gestures feature off the VM does not talk to Gestures, so these
  shortcuts stay with macOS.
- A feature switched off gets nothing of the Mac: from the VM's next start
  the app keeps that feature's port on the Mac (Omanotch, Gestures, Bridge)
  closed to the VM and does not serve its battery or camera port.
  `omacvm apply` writes the VM's features into its folder (`features`); a
  VM without that file gets everything, as before. On the fast network the
  VM reaches the Mac directly: there only the VM side keeps it away.
- The app reads the features only when the VM starts. A feature turned on
  while the VM runs (`omacvm enable bridge`) gets its link to the Mac at the
  next start: shut the VM down and start it again. `omacvm apply` names
  such features, and `omacvm check` fails on them until then.
- On a MacBook with a notch, full screen sits below the camera in its own
  Space (macOS keeps full-screen windows there and the strip beside the
  notch black), and Omanotch fills the strip with Omarchy's bar. It is on
  by default for a VM made on a Mac with a notch. A VM made with the lid
  closed or by an app before 3.0.0 has it off: `omacvm enable omanotch`
  (with it off the strip stays black). Before 3.0.0 the app had a switch,
  "Use the notch for the menu bar", whose full screen covered the strip
  but had no Space of its own: other windows could share it and the
  escape combo had nothing to leave. It is gone.
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

## Where things are

- **The app**: `~/Applications/OmacVM.app`, your own Applications folder
  (updates need no administrator). An app in /Applications keeps working;
  it offers once to move itself to ~/Applications (one rename on the Mac's
  disk, the signature stays). `omacvm` and its updates find the app in
  either place.
- **The VMs**: `~/OmacVM/<VM name>/`, one folder per VM: `vm.env` (the
  settings), `disk.img` (the disk; sparse: it takes what it holds, not its
  full size; what Omarchy deletes goes back to the Mac within a minute),
  `efi-vars.fd`, `logs/` ([disk options](../adr/0039-system-disk-options.md)).
  To take a VM to another Mac, copy its folder into that Mac's VMs folder
  (the VM must be shut down; above) with `cp -R`, which keeps the disk sparse (`ditto` wrote it in full). Where
  something else already has the name ~/OmacVM (a file, a git clone
  ~/omacvm: the same folder on a case-insensitive disk), new VMs go to the
  old place below instead.
- **Another VMs folder** (an external drive, say): in the setup, or in the
  settings under Storage › Change. With VMs there already, the app asks:
  **Move** (on the same drive a rename; to another drive copied, read back
  and compared, then deleted in the old place, with progress and a Cancel
  that leaves the VM where it was), **New VMs Only** (the VMs stay where
  they are and keep working from there) or Cancel. A VM that runs is never
  moved: it stays, and the app says so. If a file in the VM's folder changes
  or appears during a move (an `omacvm apply`, say), the copy is deleted and
  the VM stays where it was; try again. A VM folder that is a link to
  another folder is not moved: move the folder it points to in Finder. A
  half copy (`.NAME.moving`) left by quitting during a move is deleted the
  next time the app opens.
- **A drive that is not connected**: the app says so ("SD4TB is not
  connected") instead of offering a new VM, and builds nothing there (a
  leftover empty /Volumes/NAME folder counts as not connected). Plug it in
  and the window shows its VMs again by itself. A VM whose files went
  missing says which, and does not start.
- **A drive that drops off while its VM runs** (unplugged, a loose cable,
  ejected by force): the VM's disk goes with it, so the VM cannot go on or
  shut down. The app stops it at once (what the VM had not saved is lost,
  as at a power cut) and the window shows the VM as unavailable: "The
  drive with your VMs (SD4TB) is gone. Reconnect it and start the VM
  again." Start comes back when the drive does.
- **2.9 and older** kept the VMs hidden in
  `~/Library/Application Support/OmacVM/VMs`. They keep working there; the
  app offers once to move them to ~/OmacVM (Storage › Move later too).
  `omacvm` finds VMs in every folder the app does. Going back to 2.9.0
  after that: it shows only the VMs in ~/OmacVM (or the picked folder); the
  others are hidden from it, not deleted.
- **Sizes**: Storage shows the VM in the window with its size on disk and
  Show in Finder. **All VMs…** lists every VM with its size, Show in Finder
  and Delete (to the Trash; not while it runs).
- **Downloaded images**: the Omarchy images the app downloaded to set up
  VMs (try-omarchy's live system, prebuilt VMs), in `~/Library/Caches/omacvm`,
  or in `.downloads` inside the VMs folder when that is on another drive:
  builds then leave the Mac's own disk alone. A live system downloaded
  before, in another such folder, moves there at the next build; a VMs
  folder you leave takes its downloads along on the same drive, else they
  stay listed here until a build or **Remove…** takes them. **Remove…**
  deletes them after a confirmation with the size (not while a VM is being
  set up). Your VMs keep everything; a new VM downloads them again. The
  Mac's Downloads folder is not touched.
- **Backups and search**: Time Machine leaves VM folders out (the disk
  changes all the time). Spotlight never reads a VM's disk (it has no
  importer for it), but lists the files' names; macOS has no switch an app
  can set for one folder, so to hide them add ~/OmacVM in System Settings ›
  Spotlight › Search Privacy.

## From the omacvm command

`omacvm build --vm-type app` (or OmacVM.app in the build's first question)
builds the VM through the app instead of in it. The questions and the summary
are the same as for the other routes; the VM goes into the app's VMs folder
(~/OmacVM, or the one set in the app; no `--vm-dir`; a drive that is not
connected stops it, exit 3). Then:

1. It finds the app in ~/Applications or /Applications by its bundle id
   (`org.omacvm.app`, under any name it was installed as). Not installed:
   after asking, it downloads `OmacVM-<version>.zip` (this OmacVM's version)
   from the GitHub release `v<version>` with curl, checks it against the
   release's signed update feed (`OmacVM-appcast.json`, release key: SHA-256,
   size, and the Developer ID teams the app must be signed by), and puts it in
   ~/Applications. curl sets no quarantine attribute, so
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
- The app does not need Xcode's Command Line Tools or Homebrew: it carries
  OmacVM's Mac helpers (Bridge, Gestures, Omanotch) ready made, a python3
  for its scripts and the small Swift programs they ask (is there a notch,
  the clock format, free space). macOS never asks to install the developer
  tools for it, also not from "omacvm in Terminal".
- Instant resume (save the VM when you quit, continue where you were at the
  next start): QEMU cannot save a VM that uses the Mac's GPU, so Quit still
  shuts Omarchy down and the next start boots it
  ([why, and what could change it](../adr/0037-no-instant-resume-yet.md)).

## How it talks to the Mac

QEMU's user network: the Mac is `10.0.2.2` for the VM, and the Mac reaches
the VM's SSH on `127.0.0.1:<port>`.

- The VM reaches only three of the Mac's local ports through `10.0.2.2`:
  47811 (Omanotch), 47830 (Gestures) and 47831 (Bridge). Everything else the Mac runs on
  127.0.0.1 (dev servers, databases) is refused, like on the other routes.
  The app's QEMU carries a libslirp patch for that
  (`OMACVM_SLIRP_HOST_PORTS`). One more port when the Mac has a proxy on
  its 127.0.0.1 (`MacProxy.swift`, [Behind a proxy](../guide.md#behind-a-proxy)).
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
- The VM's window takes the pointer without a click: on the first motion
  over the VM, and when the window becomes key, the app comes to the front
  or the window goes full screen with the pointer on it (after a start, a
  reboot in the VM, Command-Tab or the escape combo). Not after
  Ctrl+Option+G until the pointer left the window. The Mac's pointer over
  the VM hides only once Omarchy draws its own (its display agent said
  hello on `org.omacvm.display` since the VM's last reset), so one pointer
  is always there while the VM boots (`omacvm-cocoa-pointer-start.patch`,
  rules in `omacvm-cocoa-pointer-start-logic.patch`, unit test
  `app/runtime/Tests/display/test-pointer-start.sh`; in a VM:
  `src/tests/pointer-start-vm.sh`). QEMU's log says which way it takes
  ("cocoa: pointer: ..."). Off (QEMU's own way, on entering the window or a
  click): `defaults write org.omacvm.app pointerStart -bool false`.
- Mac pointer for the VM (experimental, off, no switch in the window yet:
  `defaults write org.omacvm.app macPointer -bool true`, from the VM's
  next start): Omarchy is asked to put its pointer on virtio-gpu's cursor
  plane (Hyprland's hardware cursor) and QEMU makes that image the Mac's
  own cursor over the VM's windows, so the pointer would move with the
  Mac's cursor instead of waiting for the next guest frame (about 25 ms at
  60 Hz, see `docs/architecture/graphics.md`) and stay one cursor over the
  VM, Omanotch's strip and every display. The app sets
  `OMACVM_HW_CURSOR=1` for QEMU and the OEM string `omacvm.hwcursor=1`
  (`/run/omacvm/host.env`; `omacvm_app.lua` turns `no_hardware_cursors`
  off, notchcast stops hiding the guest's pointer at the strip). Not working
  yet: Hyprland 0.56.2 keeps drawing a software cursor on OmacVM's
  virtio-gpu (no cursor command reaches QEMU, also with `use_cpu_buffer`),
  so today nothing changes. Why: since Linux 6.8 a virtual GPU's cursor
  plane is hidden from atomic clients that do not ask for cursor hotspots
  (DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT); the guest kernel has it (plane 36,
  unused) but Hyprland's aquamarine only sees the primary plane. Next:
  aquamarine with that cap, or its legacy (non-atomic) path for this
  mode. Until the guest's first image after a reset and with a relative
  pointer (games) QEMU keeps its own way anyway.
  `omacvm-cocoa-hw-cursor.patch`, rules in
  `omacvm-cocoa-hw-cursor-logic.patch` (unit test
  `app/runtime/Tests/display/test-hw-cursor.sh`); in a VM:
  `src/tests/input-latency-vm.sh --hw-cursor`.

## Fast network (experimental, off by default)

`omacvm enable fast-network --vm NAME`, or the **Fast network
(experimental)** switch on the VM's screen in the app, puts the VM on macOS's own VM
network (vmnet, shared mode, as Parallels and UTM) instead of QEMU's user
network.
The VM gets an address of its own on a network of its own, `192.168.77.0/24`
(the Mac is `192.168.77.1`), and traffic between the VM and the Mac no
longer goes through one QEMU thread. Measured: see
[the numbers](../benchmarks/README.md#fast-network-omacvmapp).

- vmnet needs root or Apple's `com.apple.vm.networking` entitlement, which the
  app does not have. So turning it on installs a small system service,
  `omacvm-netd` (`src/net/mac`), and macOS asks for your password once (sudo
  in the terminal for `omacvm`, macOS's password dialog for the app's button).
  The button never runs by itself; a cancelled dialog changes nothing. For
  app VMs the VM's `fast-network` file is the switch: the button, `omacvm
  enable`/`disable`, `omacvm apply` and `omacvm check` all go by it. It comes built and signed inside OmacVM.app (Developer ID for
  published apps; no Xcode needed); apps from before that build it from
  source. launchd starts it when a VM connects; it quits a minute after the
  last connection.
- The service only takes connections from OmacVM.app's QEMU run by a Mac user
  who enabled it: it checks the connecting process's user and code signature
  (OmacVM's Developer ID team, or for an app built from source exactly that
  build: enable it again after a rebuild). It makes one vmnet interface per
  VM, isolated from the other VMs' interfaces, and the VPN NAT below; nothing
  else: no other requests, no files but its two state files in `/var/run`,
  and no program but `/sbin/pfctl` (fixed arguments, no shell).
- VPNs connected while a VM runs: macOS's NAT for vmnet only covers the
  networks that were up when its sharing service started. A VPN you connect
  later (a new `utun`) got the VM's packets with their `192.168.77.x`
  source, and the VPN's server dropped them (with a full tunnel the VM lost
  the internet). The service now adds that NAT itself, while a VM is on the
  fast network, for each network that is up and that macOS's sharing does
  not cover: Ethernet, Wi-Fi and VPN tunnels (`en`, `utun`, `ipsec`, `ppp`,
  `tun`, `tap`), never a bridge (Parallels' and other VM networks stay as
  they are). IPv4, and IPv6 where the VPN has an IPv6 address. The rules are
  the same as macOS's own (`nat on utun5 inet from 192.168.77.0/24 to any ->
  (utun5:0) extfilter ei`) and live only in the service's own pf anchor,
  `com.apple/org.omacvm.netd` (macOS's main ruleset already evaluates
  `com.apple/*`); no other anchor and not the main ruleset is changed. pf is
  enabled with a reference of the service's own (`pfctl -E`, given back with
  `pfctl -X`), so pf stays on for whoever else wants it. The service learns
  of new and gone networks from the kernel's routing socket (no polling) and
  follows within a second or two; the NAT goes when the network goes, when
  the last VM stops and when the service stops (`omacvm disable
  fast-network`, `omacvm uninstall`). `src/net/mac/install.sh --status`
  prints `vpn-nat: utun5` while it is on, `omacvm check` has a VPN NAT row,
  and the service's log says each change. DNS needs nothing: the VM asks
  the Mac (`192.168.77.1`), and the Mac asks the VPN's DNS servers where
  macOS uses them. pf keeps the emptied anchor listed (without rules) until
  the Mac restarts.
- Its own network, not UTM's `192.168.64.0/24`: while UTM (or another app)
  has that one up, vmnet refuses an isolated interface on it. With its own,
  UTM VMs and the fast network run side by side (tested on the Mac mini).
  Each refused start costs macOS's vmnet service a descriptor it never gives
  back (at 256 vmnet stops working on the whole Mac until a restart), so after
  a failed start the service waits 30 s before the next one, doubling up to
  an hour while it keeps failing, and after 8 failures in a row it stops
  trying until the Mac restarts or `omacvm enable fast-network` runs again
  (`omacvm check` says so). It keeps that count in
  `/var/run/org.omacvm.netd.state`, so quitting when idle does not reset it.
  After a failure it also does not try while another program's VM network
  holds `192.168.77.0/24` (a bridge with those addresses that is not its
  own): one failed start per conflict, not one a minute. When another
  interface (a LAN, a VPN) already has addresses in `192.168.77.0/24`, the
  app does not try and takes QEMU's user network, saying why.
- When macOS's vmnet service (InternetSharing) stops or crashes, every VM
  interface on the Mac goes with it, but vmnet tells no one. The service
  watches that process and closes its connections when it exits; QEMU
  connects again at once and gets a new interface (tested: the VM answered
  again 3 s after the kill). Parallels' shared and host-only networks are
  gone after such a restart too, and Parallels does not notice: quit and
  reopen Parallels Desktop, or `sudo killall prl_naptd` (its watchdog starts
  it again within about a minute, with its networks).
- The app picks the network at each start: the fast network when the VM has
  it (its `fast-network` file, with its own MAC address), the service is
  there and would take this app's QEMU; else QEMU's user network as before.
  While the VM runs, the app watches the link (every 3 s): when vmnet stays
  down (service gone, vmnet refusing), it plugs a second network card on
  QEMU's user network into the VM and takes the first one's link down (the
  VM's NetworkManager moves over within seconds); when vmnet is back for 15 s,
  it swaps back, make before break: the user network's card stays up until
  vmnet has worked for 12 s more, so the VM is never without a network on the
  way back. App VMs skip the routes of a card without a link at once
  (`/etc/sysctl.d/90-omacvm-net.conf`, `ignore_routes_with_linkdown`): before,
  the VM kept sending on the card that just went down until NetworkManager
  dropped its route, about 6 s. Measured on the Mac mini with two VMs (ping
  every 0.5 s in the VM): service away -> internet back after 6.6 s (was 14.5
  s; the rest is the app noticing), service back -> no gap (was 6.6-8 s). A switch that fails (QEMU's monitor busy) is tried again
  every 3 s, adding only what is not there yet. `logs/network` and
  `qemu.log` say which network the VM has and why; `omacvm check` shows it,
  with the service's last refusal.
- On the fast network the Mac reaches the VM's SSH on its own address (from
  macOS's DHCP leases), with the same remembered host key; the VM lets SSH in
  from `192.168.77.1` only (every app VM allows it since this version, so the
  `omacvm` command still reaches a VM the app's button moved). The VM's
  Bridge, Gestures and Omanotch (notchcast) find the Mac at the gateway and
  prove it with that address; the Mac's Bridge, Gestures and Omanotch listen
  there too and count those VMs as the app's. When the app
  moves the VM between the two networks, the VM's Gestures and notchcast see
  the new gateway and connect again within a second (tested both ways; on the
  Mac, Omanotch drops the old connection when the same VM, by name, comes in
  on the other network). On the Mac
  the old connection goes in one of two ways: TCP keepalive drops it in
  about 10 s when its path went away (the fast network); on the user network
  QEMU itself keeps answering for the VM, so keepalive never fires, and the
  Mac drops it when the same app VM (by name) connects from the other
  address. So two running app VMs with the same name (an APFS clone before
  `omacvm apply` renames it), one on each network, push each other out of
  Gestures every 2 s: give clones their own name.
- Turning it on or off (the app, `omacvm enable`/`disable`, the control
  centre, Update VM) is for the VM's next start: a VM that runs keeps the
  network it has until it shuts down, and every address lookup follows the
  running QEMU (its network in `logs/network`, its card's MAC address on its
  command line), never the `fast-network` file. When none of your app VMs
  has the fast network any more and none runs on it, turning it off also
  removes the service; while one still runs on it the service stays (`omacvm
  uninstall` takes it off).
  `omacvm uninstall` removes it for your Mac user, and from the Mac when no
  other user has it.
- After an app update: the service has a protocol number (`omacvm-netd
  --protocol`; builds from 3.0.1 to 3.0.3, which have none, count as 1;
  3.0.0's and 2.9's are installed again). An
  installed service of the same protocol serves the new app as it is, so most
  updates need no new install and no password. When the protocol changed (or
  the service was installed for another app), `src/net/mac/install.sh
  --status` says `old`: the app asks before the VM's next start (**The fast
  network needs an update: Update…**, one password), its window has
  **Update…** beside the switch, and `omacvm check` and `omacvm enable
  fast-network` say and do the same. The control centre (anything a VM
  asks for) never puts up macOS's password dialog nor uses sudo: turning
  the fast network on there sets it for the next start, and the app asks on
  the Mac then. If
  you say no, the VM starts on QEMU's user network and says so
  (`logs/network`, `omacvm check`); nothing else stops on it (other
  switches, Update VM).

What is missing before it can become the default: [below](#fast-network-not-done-yet).

### Fast network: not done yet

- Tested on a Mac mini (macOS 27): SSH, DNS, IPv6, the Bridge (proof on
  `192.168.77.1`), a UTM VM on UTM's shared network at the same time, the
  service going away and coming back under a running VM (user network after
  7 s, vmnet again after 13 s), a start with the service unreachable (user
  network after 17 s), vmnet refusing (back-off), a restart of the service
  (QEMU reconnects, about 1 s without network), the VM paused for a minute (as
  over the Mac's sleep), refused callers (another program, another user),
  macOS's vmnet service killed under a running VM, another program holding
  `192.168.77.0/24` while the VM starts (one failed start, user network,
  vmnet again once it was gone), the Gestures link across network switches
  (with the helper's own handshake code: the mini's Gestures helper waits
  for its permissions, so no real swipes), Omanotch's link (notchcast on
  `192.168.77.1`, and across a switch to the user network and back), two app
  VMs on the fast network at once (isolated from each other, both with
  internet, DNS, IPv6 and Omanotch).
- Two app VMs at once need two launchers: the app runs one at a time (a
  second start hands over to the first), so today that takes a copy of the
  app with its own bundle identifier.
- Field tests on the Mac mini (macOS 27, 3.0.0 test build, two app VMs on
  the fast network at once, 2026-10-05):
  - A real sleep and wake (`pmset sleepnow`, woken by `pmset schedule wake`
    2 minutes later): both VMs stay on vmnet; the Mac pings them 2 s after
    the wake, SSH works by the first try (+5 s), Omanotch's link is back in
    2 s, internet in the VMs at once. No reconnect to the service was needed.
  - Network changes on the Mac while the VMs run (Wi-Fi moved before
    Ethernet and back; Ethernet off for 45 s and on): no ping gap over 1.5 s
    in either VM, to the internet or to the Mac, and nothing in the service's
    log. macOS's NAT for vmnet covers every network service the Mac has.
  - VPNs: traffic follows the Mac's routes (a route into a VPN-like tunnel,
    Tailscale to another Mac). But macOS's NAT for vmnet covers only the
    interfaces it saw when it started: a tunnel that came up later got the
    VM's packets with their `192.168.77.x` source untranslated, which a real
    VPN server drops. Fixed by the service's VPN NAT (above).
- VPN NAT on the Mac mini (macOS 27, 2026-10-05; an app VM's QEMU on the
  fast network, the service installed by `install.sh`; a test tunnel
  `utun-sink` that answers pings and DNS, with split routes for
  `203.0.113.7` and `2001:db8:77::7`, and a resolver for one domain through
  it):
  - Tunnel up while the VM runs: the NAT is on within a second
    (`install.sh --status`: `vpn-nat: utun0`); the VM reaches both addresses
    through the tunnel, which sees the tunnel's own addresses as source
    (`10.99.0.1`, `2001:db8:99::1`), not the VM's. In the VM a name only the
    tunnel's DNS server knows resolves (the VM asks `192.168.77.1`).
  - A full tunnel (`0/1` and `128/1` into the tunnel for 20 s): the VM's
    pings to `1.1.1.1` and `9.9.9.9` went through it, NATed. Afterwards the
    internet as before.
  - Tunnel down: its rule goes, the VM's internet stays; up again (a new
    `utun`): back within a second. The VM stopping: everything goes, pf's
    references are as before. A VM starting with the tunnel up: NAT in the
    same second.
  - A real sleep and wake (2 minutes) with the tunnel up, twice: the rules
    stay, the VM reaches the tunnel (IPv4 and IPv6) and the internet once the
    Mac has its own back (about 10 s after the wake).
  - The service killed (`kill -9`) with the NAT on: rules and reference
    stay, the next start removes both; stopped or removed (`install.sh
    --remove`): removed at once.
  - Untouched: macOS's main ruleset, its own anchors (sharing, AirDrop,
    firewall), Tailscale (the VM reaches the other Mac through it with
    macOS's own NAT), and Parallels' `10.211.55.2`/`10.37.129.2` while
    awake. After a wake with the test tunnel up, Parallels' two networks
    came back as `192.168.18.1`/`192.168.19.1`; that happened with only the
    tunnel too (no VM, no service), and not without it: Parallels' (or
    macOS's) doing with a tunnel present, not the NAT. Quit and reopen
    Parallels Desktop, or `sudo killall prl_naptd`, brings them back.
- A real WireGuard client on the Mac mini (macOS 27, 2026-10-06):
  `wireguard-go` on a `utun`, set up as a VPN app does (addresses, MTU
  1420, split routes), and a WireGuard server in userspace that takes only
  the tunnel's own address as source, as a real one does. A stand-in VM on
  the fast network (the daemon's socket, ARP and pings): the NAT is on
  about a second after the tunnel; the VM's pings reach the server as
  `10.99.0.1`. With the service's anchor emptied by hand the server drops
  them ("packet with disallowed source address"): what VMs got before the
  VPN NAT. Down and up again, the VM leaving: as with the test tunnel.
  An IKEv2-style `ipsec0` (macOS's own kernel interface for IKEv2, here
  without a security association) got no NAT at first: for an IPv4
  address added to an interface that was already up, the service saw only
  a new route (its local route), which it did not count. Fixed: it
  follows route changes too (not ARP entries or per-destination routes);
  `ipsec0` now gets its rule within a second, and pf translates to its
  address. It also missed IPv4 address messages, which are shorter than
  it expected; it counts them now.
  Then an app VM's QEMU (headless clone of a test VM) on the fast network
  with the fixed service and the same client: NAT on 1.1 s after the
  tunnel; the VM reaches the server over IPv4 and IPv6 (seen as
  `10.99.0.1` and `2001:db8:99::1`), 20 MiB down and 20 MiB up through the
  tunnel's MTU of 1420 (VM 1500) at about 70 MB/s each; anchor emptied by
  hand: dropped by the server, back 1.1 s later on the next change. A full
  tunnel for 25 s: the VM's requests to `1.1.1.1` and `9.9.9.9` went
  through it as `10.99.0.1`; internet as before after. The VM restarting
  with the tunnel up: NAT in the same second, all of the above again.
  pf outside the service's anchor, Parallels and Tailscale unchanged.
- Not tested yet: a VPN app's own tunnel (WireGuard app, an IKEv2 profile in
  System Settings; the tests above use the same kernel interfaces without
  touching the Mac's VPN settings), real trackpad gestures over the fast network
  (the choice of VM is covered by `src/gestures/mac/test.sh`), Omanotch's
  strip on a MacBook with a notch over it (the link is tested), the app's
  password dialog end to end (its arguments are covered by
  `src/net/mac/test.sh`), and the MacBook (macOS 15: the VPN NAT, and
  numbers).
- SMAppService would give macOS's own approval (System Settings) instead of
  a password dialog; not done.

## Mac folder (off by default)

The **Mac folder** switch in the VM's settings asks for a folder and shares
it with the VM (**Choose…** picks another). From the VM's next start it is at
`~/Mac` in Omarchy. Switched off, it stops from the next start.

- The VM can read and change everything in that folder, as your Mac user,
  and nothing outside it. Share a project folder: the app refuses your home
  folder and the folders above it (your keys and every app's data would be
  in the VM).
- Your files show as your Omarchy user's in the VM; files the VM makes are
  yours on the Mac. `chown` in the VM fails (as root too): the Mac keeps the
  owner.
- How: QEMU's virtio-9p, run as your Mac user. No system service, no
  password. The VM mounts it with `cache=mmap,msize=512000`
  (`omacvm-mac-folder`).
- A change on either side shows on the other at once (tested: rewrite,
  grow, create, delete, rename on the Mac; write in the VM).
- A folder that is not there at a start (a drive not connected), or that
  OmacVM may not open (denied in System Settings > Privacy & Security >
  Files and Folders, or no permission), is left out for that start, and the
  VM starts as usual. `omacvm check` says what the start shared and why not.
- A folder in Documents, Desktop, Downloads or iCloud Drive: macOS may ask
  once whether OmacVM may open it (not tested yet).
- The Mac's disk ignores case by default: two files whose names differ only
  in case (some git repos, such as the Linux kernel) are one file there.
- File locks are not passed to the Mac: do not use one SQLite database or
  lock file from the Mac and the VM at the same time.
- VMs from before 3.0.1 need the VM side once: `omacvm apply` (or the
  control centre's update).
- Git in one repo from both sides: each side's git re-reads every file once
  after the other ran (the two record files differently; 57 s for 30,000
  files the first time below). `git config core.checkStat minimal` in that
  repo avoids most of it.

Speed (Mac mini M4, macOS 27, a 4-CPU VM, one run each; small files: 12,000
files of 0.5-16 KB; git: `git status` in a 30,000-file repo made on the Mac):

| | 1 GiB write | 1 GiB read | unpack 12k files | read them | `git status` |
|---|---|---|---|---|---|
| VM's own disk | 1991 MB/s | 5224 MB/s | 0.7 s | 0.8 s | 0.02 s |
| Mac folder (`cache=mmap`) | 1747 MB/s | 3135 MB/s | 18 s | 16 s | 8.1 s |
| 9p without cache (QEMU's usual) | 123 MB/s | 114 MB/s | 19 s | 18 s | 8.1 s |
| 9p `cache=loose` (not used) | 1670 MB/s | 3551 MB/s | 13 s | 7.5 s | 1.8 s |

Big files are fast. Many small files are slow: every file operation is a
round trip to QEMU (about 0.4 ms), and only `cache=loose` saves those, but
it shows old content after the Mac changes a file. Build in the VM's own
disk, keep sources on the Mac if you like.

NFS instead of 9p (a user-space NFS server on the Mac, over QEMU's network,
for comparison only): unpacking was 3x faster (5.6 s), the rest no better
(big files 315/1227 MB/s, reading the small files 12 s, `stat` 5.6 s). It
would need a server program, a port and its own access control, so the Mac
folder stays on 9p. virtio-fs needs a Linux host daemon; QEMU on macOS has
none.

Tested on the Mac mini (M4, macOS 27; a throwaway copy of a test VM,
`tests/share/rig.sh`): the VM's unit mounts `~/Mac` at boot and the desktop
user can write there; without a share it does nothing (18 ms) and leaves no
`~/Mac`. Not tested on macOS 15 or 26, nor on another Mac.

### Mac folder: not done yet

- One folder per VM, read and write; no read-only switch.
- It changes only at the VM's next start.
- Not measured: Parallels' and UTM's shared folders on the same Mac.
- QEMU cannot save a VM's state while the folder is mounted (9p blocks it):
  matters once instant resume comes.

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
  Hyprland sends no event when an output only moves (display-sync and
  Omanotch move them, and a config reload puts them back to "auto" for a
  moment), and a stale report kept the pointer in half the screen for up
  to 30 s. So a Lua hook (`monitor.layout_changed`) pokes the agent, which
  also compares the layout twice a second for 15 s after any change and
  every 10 s otherwise (a report goes out only when it changed).
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
  while the VM has the pointer the Mac's cursor never gets onto a screen
  corner or the Dock's edge: within 200 points of them it is detached and
  stays put, and the guest's pointer moves on by the mouse's own motion
  (VMs that show the Mac's cursor instead of the guest's, `show-cursor=on`:
  the cursor follows the guest's pointer, still kept off the corners and
  the Dock's edge) (`omacvm-cocoa-fullscreen-edges.patch`, maths in
  `omacvm-cocoa-pointer-guard.patch`, unit test
  `app/runtime/Tests/display/test-pointer-guard.sh`). The pointer moves the
  same there as anywhere else. The app's setting "Keep the Dock and hot
  corners away in full screen" (QEMU's `immersive`) turns both off. Whether
  hot corners stay quiet with a real mouse is still to be confirmed (with
  simulated motion the bottom-left corner fired in an earlier test).

Testing without a monitor: `app/scripts/dev/virtual-display.m` makes a
virtual Mac display (killing it is unplugging it). With
`OMACVM_TEST_SKIP_DISPLAYS=<the real displays' ids>` (and
`OMACVM_TEST_MAIN_DISPLAY=<id>` for the main window), QEMU uses only the
other displays, "full screen" is a plain window over each display (no
Space, no menu bar change) and QEMU never takes the focus.
`OMACVM_TEST_ONLY_DISPLAYS=<ids>` keeps real full screen but gives windows
only to those displays (another test's virtual display is left alone).
`OMACVM_DISPLAYS_DEBUG=1` logs what goes over the port (QEMU's log).

## Display scale on 4K, 5K and larger displays

Omarchy's scale menu (Super+/ and its display panel) works at any scale; the
VM's screen keeps the Mac window's full size (5120×2880 on a 5K display)
and Hyprland scales the desktop. What a scale costs:

- **2x** (or another whole number) is the sharp one: every app draws at the
  screen's own size. On a 4K or larger display, OmacVM.app's display panel
  says so under the scale presets.
- **In-between scales** (1.25, 1.6, ...) look the same size as macOS's
  "looks like" settings, but apps that cannot draw at a fraction (X11 apps,
  Omarchy's own bar) draw at the next whole scale and are shrunk (1.6) or
  at the one below and stretched (1.25: a softer bar). Hyprland always
  draws the screen's full size.
- **GPU memory on the Mac** (the VM's textures and buffers, from QEMU's
  log; Omarchy's desktop with Chromium showing WebGL Aquarium and a page;
  virtual 60 Hz displays at 2x on an M4 Max):

  | Display (guest screen) | 2x | 1.6 | 1.25 | 1x | Highest, while the scale changed |
  |---|---|---|---|---|---|
  | 4K (3840×2160) | 1.1 GB | 1.1 GB | 1.1 GB | 1.2 GB | 1.6 GB |
  | 5K (5120×2880) | 1.6 GB | 1.8 GB | 1.9 GB | 1.7 GB | 2.6 GB |
  | 6K (6016×3384) | 2.0 GB | 2.2 GB | 2.1 GB (1.33) | 2.5 GB | 3.4 GB |
  | 8K (7680×4320) | 3.1 GB | 3.3 GB | 3.2 GB | 4.1 GB | 6.2 GB |

  Omarchy alone at 5K: 1.2 GB at 2x, 1.3 GB at 1.6. Scales that would not
  give whole pixels are rounded the way Omarchy does: on 5K 1.5 becomes 1.6
  and 1.75 becomes 2; on 4K and 8K 1.75 becomes 1.875.

- **Frame times** (Chromium showing a full-screen page that redraws every
  frame, `tests/graphics/fractional-scale.sh --frames`, 60 Hz virtual
  display, M4 Max, benchmark lock held): at 5K every scale kept 60 fps
  (median 16.7 ms, no late frames). At 8K: 56 fps at 2x, 49 at 1.6 and
  1.25, 39 at 1x. On the Mac mini (M4, 10-core GPU, 16 GB; 8 GB VM):
  4K and 5K keep 59.4 to 60 fps at every scale (5K on its LG UltraFine,
  4K on a virtual display); 6K (virtual) only 36 to 39 fps at every scale,
  2x included: there the GPU is the limit, not the scale. While the
  scale changes, one frame takes 70 to 370 ms (the modeset) and 1 to 9
  frames are late; at 6K about 150. A Mac with a smaller GPU has less
  room; 2x is the lightest.
- **A scale change** makes every screen-sized buffer again, Hyprland's and
  every app's (20 to 50 of them, 32 to 127 MB each from 4K to 8K): Hyprland
  sets the mode 2 or 3 times (Omarchy's scale command sets it, then its
  config reload sets it again) and for a moment old and new buffers both
  count (the last column). Omarchy's bar (quickshell) draws one frame at
  the new size with the old scale: going from 1.6 to 1 on 5K it makes
  8192×4608 buffers (150 MB each) for a moment. Switching between 1.6 and
  2 sixteen times left the same memory in use each time, and so did a
  35-minute session on the Mac mini (149 scale changes, 75 mode changes
  like a window resize, 50 browser windows opened): back at 2 windows it
  used 1.52 GB, as at the start (1.55 GB). Nothing leaks.
- The VM's graphics memory has no fixed limit: it grows as long as macOS
  has memory to give ([Graphics memory and VM memory](#graphics-memory-and-vm-memory)).
  Up to 2.9.1 it had a budget of a quarter of the Mac's memory, which a 5K
  desktop at 1.6 with apps open could reach on a 16 GB Mac
  ([troubleshooting, finding 24](../troubleshooting.md#24-app-a-scale-like-16-on-a-5k-display-turns-the-vm-black-and-flickering)).
- The display sync (`omacvm-display-sync`) sends Hyprland a mode only when
  it shows another, one call at a time, and stops following an output that
  keeps changing (6 times in 10 s between two states, or 12 times at all)
  for a minute, then looks once more; `omacvm check` in the VM says so
  ("display sync"). A window being resized is never held.

Tests: `src/app/guest/tests/test_display_sync.py` (no VM: 4K and 5K at
Omarchy's scales, nothing sent twice, the loop guard),
`tests/graphics/fractional-scale.sh` (a running VM: every scale, mode kept,
no loop, no refused memory or lost GPU context in QEMU's log; `--frames`
adds frame times of a full-screen page).

## Graphics memory and VM memory

A Mac with Apple silicon has one pool of memory for everything: macOS, your
apps, the GPU. A VM takes two kinds from it:

- **VM memory** is the VM's RAM, the number you pick for the VM ("Resources"
  in the app, `omacvm resources`). Linux sees exactly that much. The Mac
  gives it as the VM touches it, and the VM gives back what Linux frees
  (QEMU's balloon device with free page reporting).
- **Graphics memory** is extra, on top: the textures and buffers the VM's
  desktop and apps draw with, kept by the Mac's GPU driver for the VM. It
  grows and shrinks with what is on screen: Omarchy alone at 5K about
  1.2 GB, with a browser about 2 GB, 3 GB at 8K, and for a moment more
  while the display scale changes (the table above).

The app shows both: before a start, "VM memory: 8 GB; graphics memory last
run: peak 2.6 GB, from the Mac on top"; while the VM runs, its app menu (the
one beside the Apple menu) has "VM memory: 8 GB" and "Graphics memory:
1.6 GB (peak 2.6 GB)", read when you open the menu (a click explains them).
`omacvm check` has a "graphics memory" row: now, the peak of this run, and
macOS's memory pressure. So does the control centre in the VM (`omacvm`):
"Graphics memory: 1.6 GB (peak 2.6 GB)", looked at every 2 s while it is
open (nothing while it is closed), with a warning (!) while macOS is short of
memory or after refused allocations.

**No fixed limit.** QEMU asks macOS how much memory it can give
(`virgl-darwin-memory-pressure.patch`):

- While macOS's memory pressure is normal (green in Activity Monitor),
  every allocation goes through.
- When macOS warns (yellow), QEMU lets the Mac's GPU driver free what it
  still holds for deleted textures (measured: nothing, as QEMU already
  flushes after every resource command; `logs/qemu.log` says "freed N MB"),
  and the app asks the VM to drop its file cache (at most every 10 minutes,
  again after 30 s if the VM did not answer), which Linux then gives back to
  the Mac (the cache it dropped: 0.1 GB on a fresh VM, 1 GB after a long
  session).
  QEMU keeps no cache of its own for the VM's graphics: everything it holds
  belongs to a live buffer of an app in the VM.
  Everything still goes through, unless a new big buffer (16 MB or more)
  is bigger than all the memory macOS has left: more swapping is better
  than a black desktop.
- When macOS is critical (red), new big buffers are refused. Before a
  refusal QEMU frees what it can and looks again three times (100 ms;
  within a second of the last refusal it does not wait again, as the VM
  stands still while it waits).
  Screens, cursors and small buffers are never refused for this, so the
  desktop keeps drawing as long as it can.

Only a runaway VM meets the one fixed guard: all graphics memory together
at most three quarters of the Mac's memory (`OMACVM_GPU_MEMORY_MB` in
QEMU's environment sets another, 0 turns it off; for tests). Its last part
is kept for the VM's desktop, Hyprland, the bar (quickshell) and the lock
screen (hyprlock): a
sixteenth of the Mac's memory, 512 MB to 2 GB (8 GB Mac: apps up to 5.5 GB
of 6 GB; 16 GB: 11 of 12 GB; 64 GB: 46 of 48 GB). An app past that share,
or an app that wants a big new buffer while macOS is short of memory, loses
its own GPU context; the desktop goes on into its part (macOS's pressure
does not hold the desktop back, only the guard) and keeps drawing. The VM
shows a note: "chromium stopped drawing", and why. On a MacBook Air with
8 GB a browser with big WebGL pages reached the guard while macOS still
said normal, and before this the next buffer refused was often Hyprland's
(a black VM). `OMACVM_GPU_MEMORY_RESERVE_MB` sets the desktop's part (0:
none) and `OMACVM_GPU_MEMORY_DESKTOP` its contexts (comma-separated
process names; for tests).

**When a buffer is refused**, the app that wanted it loses its GPU context
(the VM's graphics driver cannot hand back an "out of memory" for it). A
browser starts its GPU process again. Hyprland cannot: the VM's Mesa does
not report a lost context, and Hyprland 0.56, when told, stops ("Cannot
continue until proper GPU reset handling is implemented"). So the app tells
the VM through its guest agent, and the VM's `omacvm-desktop-recover`
restarts the desktop session by itself, a few seconds after the loss (on
the Mac mini the desktop drew again 2 to 3 seconds after QEMU reported it):
SDDM logs you in again (or shows its login screen when autologin is off).
**Apps open in the VM close, and what was not saved in them is lost.** The
new session shows a notification that says so and names the apps that
closed. A session that was locked locks itself again. At most once in 10 minutes: when the desktop is lost again that
soon (macOS still short of memory), the app shows "The VM's desktop
stopped drawing" with a button that restarts it, as it always did with
the automatic restart off; the window says why: the VM's graphics reached
the guard, macOS ran short, or the graphics failed (`defaults write org.omacvm.app
desktopAutoRestart -bool false`). After Later in that window the app menu
(beside the Apple menu, under "Graphics memory") has "Restart the
Desktop…", which brings the window back; it goes away once the desktop
restarts or the VM stops. When only the shell (Omarchy's bar and
launcher, Quickshell) is lost, only the shell starts again, and no app
closes. `logs/qemu.log` says which app lost its context and why, and each
restart the app made; `journalctl -t omacvm-desktop-recover` in the VM
says what was closed (ADR 0038).

The guard is not only for runaway VMs on an 8 GB Mac: on a MacBook Air M2
(8 GB, 4 GB VM, 2026-10-06) Chromium with 7 windows of big WebGL pages
(5K canvas and 512 MB of textures each) reached 6 GB while macOS still said
normal (it said warn on the way, never critical; 2.3 GB swap, the Mac stayed
responsive). The browser lost its context first, Hyprland a few seconds later.

**On an 8 GB Mac** the VM gets 4 GB of VM memory by default; with apps
open on a 4K or 5K display the Mac is near its limit. macOS then compresses
and swaps first, and only refuses new graphics when it says memory is
critical. A smaller window or scale 2 needs the least.

**Other VM apps** (what we checked; their own documents may say more):

- **UTM** runs the same QEMU and virglrenderer: graphics memory comes from
  the Mac on top of the VM's memory, with no limit at all.
- **VMware Fusion** has a graphics memory setting of its own
  (`svga.graphicsMemoryKB` in the `.vmx`, 8 GB at most; OmacVM's Fusion route
  sets it), taken from the VM's memory.
- **Parallels Desktop** has a video memory setting (OmacVM's Parallels route
  sets 0, automatic) and draws with the Mac's GPU in its own way; how much
  memory that takes on the Mac it does not say.

Tests: `app/runtime/Tests/virgl/test-resource-budget.c` (build time: the
budget, refusals at critical and warn, the status file, a lost context),
`tests/graphics/fractional-scale.sh` (a running VM).

