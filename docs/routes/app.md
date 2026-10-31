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
- The disk's size: Disk › Change… in the VM window (the VM shut down) opens
  − / + for the new size in the row. It goes from what Omarchy needs (btrfs' chunks plus 10 % or 5 GB,
  never under 64 GB; read from the VM while it runs, else from disk.img)
  to the Mac's free space plus the size now, less 10 GB. Larger: Omarchy
  grows into it at the next start. Smaller: an APFS clone of disk.img
  first (`disk-before-resize.img`), then the VM starts and shrinks btrfs,
  shuts down, the app writes the smaller partition table and cuts
  disk.img, and at the next start a read-only scrub checks every block.
  The clone goes when the check passes; on a failed step the window
  offers Go Back. The steps are in the VM folder's `disk-resize`, the
  results in `logs/disk`. Space Omarchy frees goes back to the Mac by
  itself within about two minutes (btrfs `discard=async`, a trim at every
  Update VM and once a week, disk.img sparse:
  [disk options](../adr/0039-system-disk-options.md)). Files deleted
  outside your home folder stay while an update snapshot still holds them:
  OmacVM keeps the last 2 (omarchy-mac kept 5).
- Where things are: the app in `~/Applications`, the VMs in
  `~/OmacVM/<VM name>/`; moves, other drives, sizes and downloads:
  [where things are](#where-things-are).
- A VM folder from another Mac: copy it into `~/OmacVM/` once (the app runs
  one VM at a time, the first folder by name). Check that the app looks there:
  `~/Applications/OmacVM.app/Contents/MacOS/OmacVM --vms-folder` (or the
  same under `/Applications`) must print the same as `echo ~/OmacVM` (a home
  folder can be on another drive, under `/Volumes`). If it prints another
  folder, move the VM folder there and use that path below. Open the app and
  start the VM: the app says that the VM was set up on another Mac and offers
  **Update VM**, which sets up this Mac's side (Bridge, Gestures, token) and
  lets the helpers ask macOS for their permissions. By hand instead, with the VM running:
  `bash ~/Applications/OmacVM.app/Contents/Resources/scripts/apply-vm.sh ~/OmacVM/<VM name>`
  (or `omacvm apply --vm "<VM name>" --vm-type app`). If it says there is no
  SSH access, the VM does not know this VM folder's key yet: start it once in
  the app (it adds the key through the guest agent), or run the one command
  `omacvm apply` prints in the VM's terminal.
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
- For faster pages, use Google Chrome instead of Omarchy's Chromium. If
  Chrome is not installed yet: Omarchy menu > Install > Browser > Chrome
  (from the AUR). That writes a new `~/.config/chrome-flags.conf` with
  Omarchy's flags only, so run `omacvm apply --vm "<VM name>" --vm-type app`
  once afterwards, with the VM running, and restart Chrome: it puts back
  OmacVM's Chrome flags (scroll momentum, Mac input methods, video
  encoding). Without them Chrome glides too much on a trackpad. Chrome
  installed with OmacVM's `install-chrome.sh` (Google's .deb) blocks the
  AUR package ("exists in filesystem"): keep it, or remove
  `/opt/google/chrome` first. At the same version in the same VM,
  Speedometer 3.1 was 17 % higher in Chrome; JetStream, MotionMark, WebGL
  and scrolling were within 4 %
  ([numbers](../benchmarks/README.md#google-chrome-vs-omarchys-chromium-macbook-pro-m4-max-2026-10-25)).
  Arch Linux ARM's Chromium is built without Google's profile-guided
  optimization and with another clang, and runs without Google's field
  trials; the test does not tell which of them makes the difference. Chrome also decodes AV1 and
  HEVC on the Mac's media engine, Omarchy's Chromium only H.264 and VP9.
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
  software copy, slow in full screen). Automatic is Vulkan on macOS 26 and newer with
  KosmicKrisp, OpenGL before (since 3.0.13; OpenGL on every Mac before)
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
  reason if the update fails. `omacvm apply` and `omacvm update` do not
  update the VM's system (they say to run `omarchy update` first), except
  once for a VM fresh from a prebuilt image, at its setup. Arch's
  own builds of 26.2.4 do not replace it; a newer Mesa from Arch does
  (Vulkan keeps working, WebGPU in Chrome waits for OmacVM's next build of
  it; the check says so). VMs from 3.0.0 rebuild it once, after the next
  start or with `omacvm apply`. Until the driver is there the VM starts with
  OpenGL only, and the app, `omacvm graphics` and the control centre say
  "Vulkan (driver not built yet: runs on OpenGL until it is built (OmacVM in the VM: r on Graphics))". In the
  VM `omacvm-venus-driver.timer` checks again 90 s after boot, after the
  desktop, never in the boot's critical chain. Automatic is OpenGL on every
  Mac in 3.0.0 (CHANGELOG).
  WebGPU and GPU compute come with it (feature `gpu-compute`, on by default;
  [`venus/compute.sh`](../../src/app/guest/venus/compute.sh); its switch is
  the VM window's General › WebGPU and GPU compute (stopped: set up at the next start), the
  control centre or `omacvm disable gpu-compute`; off removes the parts
  below, Vulkan stays as Graphics says). OpenCL: apply installs Arch's
  `opencl-mesa` (rusticl) and `clinfo` and turns rusticl's Zink on
  (`RUSTICL_ENABLE=zink` and `ZINK_DEBUG=quiet`, which drops Zink's
  "Some incorrect rendering might occur" line, in
  `/etc/environment.d/90-omacvm-opencl.conf`, for apps started after the
  next login), so OpenCL apps (Geekbench, darktable, ffmpeg) run on the
  Mac's GPU through Zink on Venus ([`venus/opencl.sh`](../../src/app/guest/venus/opencl.sh);
  OpenGL turns the switch off again). That works on KosmicKrisp (macOS 26
  and newer). On MoltenVK Zink refuses the device (no `nullDescriptor`):
  `opencl.sh` checks Zink's device at apply and after each start and leaves
  OpenCL off there (apps use the CPU instead of a platform without a
  device); `omacvm check` says why, and OpenCL there needs the vulkan
  feature below. rusticl still prints one note at each OpenCL start
  ("Patched Mesa libclc not detected"; Mesa has no switch for it).
  `omacvm check` has an "OpenCL (rusticl on Zink)" row. WebGPU: a
  "Chromium (WebGPU)" menu entry ([`venus/webgpu.sh`](../../src/app/guest/venus/webgpu.sh))
  starts Chromium (`omacvm-chrome-webgpu`: Google Chrome) with its
  compositor on Vulkan, which Chrome needs before it gives pages the Mac's
  GPU for WebGPU; the normal Chromium entry stays as it is (that mode costs
  WebGL about a fifth and decodes video on the CPU, and Chrome's other
  route, ANGLE on Vulkan, has no WebGL 2 on Venus); Firefox gets WebGPU on
  (`dom.webgpu.enabled`; Omarchy has no Firefox, it counts once you add
  it). `omacvm check` has a "WebGPU in Chromium" row.
  Vulkan's host memory window (Venus' `hostmem`) comes from the VM's memory
  plan: what the Mac has beyond the VM's memory and macOS's reserve (4 GB up
  to 16 GB of memory, 6 GB up to 36 GB, 8 GB above), 4 to 32 GB; what Vulkan
  allocates counts against the VM's GPU memory budget.
  The hidden `venus` switch of 2.9 is gone: the app's first 3.0.0 launch
  moves it into the setting (Vulkan for each VM without its own choice).
- OmacVM's own Mesa for WebGPU and GPU compute, for macOS 15 (feature `vulkan`,
  experimental, off by default; on macOS 26 and newer the Graphics path above
  has them): `omacvm enable vulkan --vm NAME`, then shut the VM down and start it again.
  The VM gets OpenCL (rusticl on Zink), WebGPU in Firefox, and a
  "Chromium (WebGPU)" menu entry that starts Chromium with WebGPU on the
  Mac's GPU (the normal Chromium keeps its software WebGPU: its Vulkan mode
  costs WebGL about a fifth), with OmacVM's own Mesa (pinned 26.2.4 with
  five patches) in `/opt/omacvm-mesa`, and Vulkan whatever the Graphics
  setting. The first time the VM builds that Mesa: about 3 minutes on an M4
  Max and a 140 MB download (Mesa's source and Rust; Omarchy has LLVM and
  Clang already). The build tools it adds (Rust, meson, ninja, bindgen) are
  removed after the build. If the build fails, the feature stays off and
  apply says so (log: `/var/log/omacvm-mesa-build.log` in the VM). With it,
  the session's OpenCL loader reads only OmacVM's ICD (`OCL_ICD_VENDORS`),
  so Arch's rusticl adds no second platform and no "Zink requires the
  nullDescriptor feature" error. Off: Vulkan follows the Graphics setting.
  `omacvm disable vulkan` removes it. Numbers:
  [benchmarks](../benchmarks/README.md#gpu-compute-with-venus-2026-10-04),
  how it works: [ADR 0022](../adr/0022-webgpu-and-opencl-on-venus.md).
- Quit, logging out and restarting the Mac shut Omarchy down cleanly first.
  The window's close button follows **Closing the window** (`closeAction` in
  `org.omacvm.app`, for every VM): *Shut down* (the default, as Quit), *Keep
  running* (the window goes away, the VM goes on; click OmacVM in the Dock to
  come back to it) or *Ask*. A change counts from the next time you close the
  window, also while the VM runs. The Mac's sleep pauses the VM; after waking,
  the VM's clock is set to the Mac's.
- A window you cannot see (minimised, hidden, covered, on another Space) gets
  no new frames drawn until it shows again: no GPU time for pictures nobody
  sees (`OMACVM_PRESENT_HIDDEN=1` in QEMU's environment draws them anyway).
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
  Full screen including notch, no Omanotch needed (experimental, off by
  default, per VM; the VM window's **Start in**): the full screen keeps its
  own Space and also covers the strip, and the VM draws its bar there;
  Omanotch is idle for such a start ([details](../features.md#full-screen-including-notch),
  [ADR 0044](../adr/0044-fullpanel.md)).
  One pointer at the strip's edge: leaving the VM up into the strip, QEMU
  moves the guest's pointer into the hidden NOTCH output (right above the
  display, behind the camera, never shown) as the Mac's arrow appears, and
  the next motion over the VM brings it back (`omacvm-cocoa-notch-park.patch`).
  The app tells the VM (`omacvm.notchpointer=1`), so notchcast does not hide
  the guest's pointer there: Hyprland applies `cursor:invisible` only on a
  periodic tick, up to half a second late, which showed two arrows or none at
  every crossing. Only if the pointer did not get to NOTCH does notchcast hide
  it as before.
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
  full size; what Omarchy deletes goes back to the Mac within about two
  minutes), `efi-vars.fd`, `logs/`
  ([disk options](../adr/0039-system-disk-options.md)),
  `ssh-key` (the VM's own SSH key: `omacvm apply` puts it into the VM beside
  the Mac's `~/.ssh/omacvm`, so the VM is reached on any Mac its folder goes to).
  To take a VM to another Mac, copy its folder into that Mac's VMs folder
  (the VM must be shut down; above: a copy made while it runs has a damaged
  disk, and the app asks before it starts one: the file `running` in the
  folder names the Mac it ran on) with `cp -R`, which keeps the disk sparse (`ditto` wrote it in full).
  There, the app says before the first start that the VM was set up on another
  Mac and offers Update VM: it sets up that Mac's helpers and token. Where
  something else already has the name ~/OmacVM (a file, a git clone
  ~/omacvm: the same folder on a case-insensitive disk), new VMs go to the
  old place below instead.
- **Open Existing VM…** (in the setup, and in the settings below VMs
  folder): shows a VM that is somewhere else, copied from another Mac or on
  an external drive, without a restart. Pick the VM's folder (the one with
  `vm.env`) or the folder it is in; that folder becomes the VMs folder, and
  the VMs of the old one are still found. Nothing is copied. A VM that runs
  in another app or on another Mac (its disk is locked) is not started: the
  window says so. A VM from a bigger Mac (more CPUs or memory than this Mac
  allows) starts at this Mac's Best tier; its `vm.env` keeps its size.
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
  and Delete. **Delete VM…** asks for the VM's name, typed exactly, then
  moves its folder to the Trash (not while it runs).
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
  time it starts a VM: allow it. Omarchy's network runs through OmacVM (its
  DNS server and devices on your network). Updates keep the answer; another
  version in another folder is asked again
  ([troubleshooting 42](../troubleshooting.md#42-app-macos-asks-to-let-omacvm-find-devices-on-local-networks)).
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
  below), AirPods and media controls (`org.omacvm.media`,
  [below](#airpods-and-media-controls-on-by-default)) and, with `mac-ime` on, the Mac's input methods (`org.omacvm.ime`,
  [below](#mac-input-methods-experimental-off-by-default)). The battery goes one way; the VM can only ask
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
- While the VM has the pointer, the Mac's cursor is hidden and its picture
  is an empty one too. Other programs and macOS can show a hidden cursor
  again (a background helper, an app or Space switch); then it shows
  nothing over the VM. A motion over the VM, and while it is hidden a look
  every 0.5 s without one, sets the empty picture again when the window
  server says the hidden cursor shows after all; QEMU's log then says
  "cocoa: the hidden Mac cursor showed over the VM"
  (`omacvm-cocoa-cursor-stays-hidden.patch`; in a VM:
  `src/tests/pointer-reveal-vm.sh`). OmacVM Gestures leaves the Mac's
  pointer over the app's VMs to QEMU.
- Pointer on its own layer (experimental, off; the VM window's Display
  section, `defaults write org.omacvm.app pointerPlane -bool true`, from the
  VM's next start; ADR 0054): the VM loads OmacVM's virtio-gpu driver with
  the option `cursor_plane=1` (built by Update VM like the 10-bit one), which
  shows its cursor plane to Hyprland: since Linux 6.8 a virtual GPU hides it
  from compositors that send no cursor hotspots, and Hyprland's aquamarine
  sends none. `omacvm_app.lua` then puts the pointer there (from a CPU
  buffer), and QEMU shows that image over its window, 1:1 at the plane's
  place, so a pointer move no longer redraws the VM's screen. Every output
  gets a plane, and QEMU puts a pointer layer over the window of every
  display the VM uses (the main window and the windows on other displays;
  #554). The app sends `omacvm.pointerplane=2` and the VM's loader takes only
  that: a VM before 3.2.5 draws its own pointer until Update VM, and an app
  of 3.2.4 or older (`=1`, layer over the main window only) gets Hyprland's
  own pointer. With Extra brightness QEMU gives the main window's layer the
  frames' gain, so the pointer is as bright as the page under it. Not with the hidden Mac pointer setting (that one needs the
  hotspot). `omacvm check` says "Pointer layer".
- Draw only what changed (experimental, off; the VM window's Display
  section, `defaults write org.omacvm.app presentTiles -bool true`, from the
  VM's next start; ADR 0055): QEMU keeps the last whole frame on the window
  and puts a frame that changed in at most 12 squares of 256 x 256 on tile
  layers over it, so macOS redraws only those. It needs the VM to say what
  changed: with the switch on the VM loads OmacVM's virtio-gpu driver for
  Linux 7.4's damage fix (SMBIOS `omacvm.damage=1`; Update VM builds it;
  `omacvm check`, "Changed parts"); off, or in GPU safe mode, QEMU draws
  whole frames and the VM loads the driver it would without this switch:
  the standard one, or OmacVM's own for HDR, the pointer layer or frames in
  step (which now always has the fix; QEMU then only collects the changed
  parts). MacBook Air M2, full screen at 60 Hz, the pointer moving:
  11-17 % less power for the whole Mac; MacBook Pro M1 Max, HDR at 120 Hz:
  WindowServer less GPU time (pointer moving, spinner; watts there are a
  first measurement, set td2, to be re-run). The same pictures
  and frame rate at 60 Hz (8-bit and HDR) and 120 Hz (HDR).
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

## Mac input methods (experimental, off by default)

The Mac's input methods type in Omarchy (feature `mac-ime`; what it does:
[features](../features.md#mac-input-methods-chinese-japanese-korean); design:
[ADR 0043](../adr/0043-mac-ime.md); requested and scoped by @Vocllum in
[#273](https://github.com/gillesgoetsch/OmacVM/issues/273)).

- Only for a VM whose record (its folder's `features`) says `mac-ime=on`
  at its start, the app adds the virtio port `org.omacvm.ime` (`nr=8` on
  `vser0`, after Touch ID's: no PCI device moves) and sets
  `OMACVM_IME_SOCKET` for QEMU. Any other VM starts exactly as before: no
  port, no socket, and QEMU's window code never looks at a key for it.
  qemu.log's "Mac links" line says "Mac input methods on|off" for each
  start; `omacvm apply` says when the switch waits for the next start.
- In the VM, OmacVM's Fcitx5 module (`src/ime/guest`, package
  `omacvm-fcitx5-ime`, built in the VM against its Fcitx5) opens the port
  (udev gives it to the desktop user) and tells the Mac which kind of field
  has the focus and where its caret is, in Hyprland's logical pixels; it
  puts what the Mac composes into that field as preedit and commit. JSON
  lines, at most 4 KiB each.
- QEMU's window code (`omacvm-cocoa-ime.patch`, rules in
  `omacvm-cocoa-ime-logic.patch`) is the input method's client
  (`NSTextInputClient`) while a text field in the VM has the focus, the
  Mac's input source is an input method and the VM has the keyboard. Keys
  with Cmd or Control, and modifiers, always go to the VM as keys; keys the
  input method does not take go to the VM as keys too. The caret goes
  through the same display layout as the pointer (every output, the
  notch's black rows). The Mac never reads the guest's text, and the guest
  can only move the candidate window or keep keys going to the VM. No
  entitlement, no permission.
- QEMU's log: "cocoa: mac-ime: ..." (on, the module's hello, which way the
  keys go). Tests: `src/ime/tests/run.sh` (the module's protocol and the VM
  step), `app/runtime/Tests/keys/test-ime.sh` (the window code's rules and
  hooks), `swift run features-tests` (the port only with the record's on).

## Pause drawing while hidden (experimental, off by default)

The VM window's settings have **Pause drawing while hidden** (Display). With
it on, a VM whose window nobody can see stops drawing, as a macOS app does:

- "Cannot be seen" is macOS's own word for the window (its occlusion): the
  window minimised, wholly covered by other windows, on a Space that is not
  shown (the VM full screen and you in macOS), closed with **Keep running**;
  or the screen locked, the displays asleep, another user on the screen.
  After 2 seconds of that, QEMU tells the VM's display agent
  (`omacvm-displays`), which turns that display off in Hyprland (DPMS, as
  Omarchy's own screen blanking does). No frames and no vblank then, so
  Hyprland and the Linux apps stop drawing; sound, a video's sound,
  downloads, timers and everything else in the VM keep running.
- As soon as any part of the window shows again, the display is turned on
  at once and the VM draws again; until its first new picture (a few frames
  later) the window shows the last one. A window that can be seen is never
  touched: every frame, at the display's full rate.
- A screen share or a recording of that display from inside the VM keeps it
  drawing (any window share keeps every display drawing). A display the VM
  had turned off itself before the pause (Omarchy's idle) is left off. If
  Omarchy's idle comes while the display is paused, the agent cannot tell
  it apart (the display is off already), so the display comes on with the
  window and shows Omarchy's lock screen.
- QEMU tells only a display agent that says it can (Update VM brings it;
  `omacvm check`'s "every Mac display" line says "pause while hidden: ready"
  and which display is paused). "Unseen" is said again every 5 s; with no
  word for 15 s the agent turns its displays on again, and "seen" is said
  again until the VM's first new frame, so a lost line never leaves the
  display off.
- It works at once in a running VM (QEMU watches the setting). The Mac side
  is in QEMU (`omacvm-cocoa-guest-pause*.patch`), the VM side in the display
  agent (Update VM brings it). `defaults write org.omacvm.app
  pauseWhileHidden -bool true` does the same as the row.
- QEMU's log: "OmacVM: pause drawing while hidden: on|off" at the start and
  on a change, and after each pause "guest drawing: paused for N s ...;
  frames again A and B ms after it was seen". The VM's journal:
  "omacvm-displays: drawing paused on Virtual-1" / "drawing again".
- Only the main window (Virtual-1); the windows on other displays in full
  screen keep drawing.
- While the display is paused, Hyprland's own wake on a pointer move or a
  key (`misc:mouse_move_enables_dpms`, `misc:key_press_enables_dpms`, both
  on in Omarchy) is off: it turns every display on, also the paused one
  while you work in the VM on another display, and the Mac then turned it
  off again a few seconds later. Only options that were on are touched;
  they are back as they were once the window is seen again (also after a
  restart of the agent), and while another display is off by itself
  (Omarchy's idle) so input wakes it. `omacvm check` says "Hyprland's wake
  on moves and keys held off meanwhile".

## AirPods and media controls (on by default)

The VM window's settings have **AirPods and media controls** (Output). While
something plays in the VM (a video in the browser, music, mpv), the app is
the Mac's Now Playing app, like Music or Safari:

- Play, pause and skip on AirPods and other Bluetooth headphones and
  speakers, in Control Center and with the keyboard's play keys go to the
  VM's player. Control Center shows what plays under the app's name.
  Volume stays the Mac's.
- macOS gives the controls to the app that started playing last. A Mac app
  that starts playing takes them; when the VM's player pauses and plays
  again, the VM takes them back. A short stop (the next track, a video
  buffering) changes nothing, and a player that stops and starts again and
  again (also with longer stops) takes them at most once every 10 s.
- Paused in the VM, the app keeps the controls, so the next press resumes
  the VM. Nothing plays for 3 s (the player closed, the video ended), 30
  minutes paused, the VM stopped, or the switch off: the controls go back to
  the Mac's apps.
- With the VM in front, OmacVM Bridge still types the play keys into the VM
  as keys (Omarchy's own media keys) and macOS never sees them, so a press
  never counts twice. QEMU's window takes no media keys of its own.
- The Mac side is the app itself (not QEMU, which macOS would show without a
  name). It needs no permission. The VM side is `omacvm-media` (a user
  service, Update VM brings it): it reads the VM's MPRIS players (Chromium,
  Firefox, mpv) once the switch is on and runs Play, Pause, Next and Previous
  on the one that played last, never a toggle (AirPods pause when one comes
  out). Over its own virtio port, `org.omacvm.media`; nothing goes to a VM
  without the service.
- It works at once in a running VM (the app watches the setting).
  `defaults write org.omacvm.app mediaControls -bool false` does the same as
  the row. The test identity (OmacVM Test) has it off by default, so a test
  VM never takes your AirPods.
- QEMU's log: "OmacVM: media controls: on|off" at each start, then a line
  when the VM becomes Now Playing, for each command from macOS and when it
  gives the controls up (why). Titles never go into a log. In the VM:
  `omacvm-media status`, `journalctl --user -u omacvm-media`; `omacvm check`
  has a "media controls" line.

## HDR and 10-bit colour (experimental, off by default)

On a Mac with an HDR display (a MacBook Pro's XDR panel, an HDR monitor),
the VM window's Display settings have **HDR and 10-bit colour**. From the
next start of the VM its main window runs at 10 bits: smoother gradients,
and HDR highlights from Linux apps that send HDR. White stays the Mac's
white; brighter parts go as far as the display can show at its current
brightness. Macs without an HDR display do not show the switch and keep
the 8-bit path.

- The VM's 10-bit graphics driver: Update VM builds it (internet once, a
  few seconds); the VM loads it only for a start with the switch on, else
  the standard driver.
- It counts when the VM starts: shut the VM down and start it again. A
  restart inside the VM (Omarchy's menu) keeps the setting it started with.
  While the VM runs with the other setting, the switch says so.
- Which Linux apps send HDR (October 2026): Chrome, Chromium and GStreamer
  do; mpv shows HDR video as SDR for now.
- Only the main window; windows on other displays stay 8-bit.
- Extra brightness (below) wins while it is on: no HDR highlights then.
- Screenshots, colour picks and screen sharing (Teams, Meet, OBS through
  the desktop portal) show apps that draw HDR, such as Chrome, at normal
  white; parts brighter than white are cut off there, as captures are SDR.
  Update VM brings this; `omacvm check` has an "HDR captures" line.
  Omarchy's screen recordings make SDR of the HDR screen themselves once the
  VM was shut down and started again after Update VM (white at about 224
  of 255 at a high headroom; "HDR recordings" in `omacvm check`;
  [troubleshooting 44](../troubleshooting.md#44-app-screenshots-and-screen-sharing-of-chrome-too-bright-in-an-hdr-vm)).
- GPU safe mode turns it off. `omacvm check` has an "HDR" line.
- How it works: [ADR 0049](../adr/0049-hdr-guest-tone-maps.md).

## Extra brightness (experimental, off by default)

On a Mac with an XDR display (a 14- or 16-inch MacBook Pro, a Pro Display
XDR, an HDR monitor with more than 2x headroom), the VM window's Display
settings have **Extra brightness**. It makes the VM's main window up to
about twice as bright as the Mac's normal white, at once, in a running VM.
Use it with care: it uses much more battery and makes the Mac warmer.

- How bright: as far as the display can go right now, at most 2x. macOS
  turns it down when the Mac gets hot or the panel is already bright, and
  gives none at the display's lowest brightness.
- It ends by itself when the VM stops, its window is hidden or on another
  Space, or you turn it off. The switch keeps your setting, on or off, from
  the app or the VM's panel: through a restart of the VM or the Mac, Update
  VM and app updates, HDR or GPU safe mode switched, and a start on a
  display without it (no switch shown there; it works again on the XDR
  display). Only you change it.
- Only the VM's main window; the rest of the screen, other displays and
  screenshots stay at normal brightness.
- With HDR and 10-bit colour on, this wins while it is on: the picture
  gets brighter, HDR highlights do not. Off, HDR is back at once.
- A MacBook Air and SDR monitors do not show the switch. GPU safe mode
  turns it off. `omacvm check` has an "Extra brightness" line.
- From the command line: `defaults write org.omacvm.app extraBrightness
  -bool true` (a running VM follows at once).
- How it works: [ADR 0050](../adr/0050-extra-brightness.md).

### In the VM's Display panel

The Display panel in Omarchy's bar (the monitor icon) has the same switches
from the VM:

- **Brightness**: Omarchy's own slider sets the brightness of the Mac
  display the VM's window is on, the MacBook's own display too (through
  macOS, as the brightness keys). The keys and the slider stay in step. It
  needs **External display brightness** (on by default) and the Bridge.
- **Extra brightness**, right under it, only on a Mac with an XDR display:
  Omarchy's own switch, with the same use-with-care (i) as the app's row.
  Click it, or walk to it with j/k and press Return or Space. It is the
  app's setting, so the VM window's row and the panel always agree, and it
  switches only while that VM's window is in front. GPU safe mode dims it.
  It needs the control centre (on by default). In the VM's terminal:
  `omacvm extra-brightness [on|off]`.

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
- The display panel keeps zoom separately for each secondary output in
  `~/.config/omacvm/scales/Virtual-N` (`$XDG_CONFIG_HOME` when set). Its
  buttons call `omacvm-displays scale SCALE` for secondary and full-panel
  outputs; normal primary scaling keeps Omarchy's original command. The
  wrapper also works from a terminal on the focused output. A secondary
  output with a named rule in `monitors.lua` is refused without changes:
  edit that rule, or remove it to use automatic sizing and independent zoom.
  The main output still uses Omarchy's
  `omarchy_monitor_scale`. Other outputs keep their EDID density until a
  scale is chosen for them. A choice survives reloads, window resizing and
  reconnecting the output, without pinning its resolution or refresh rate.
  Remove that output's scale file and run `omacvm-display-sync --once` to
  return to its automatic density. Choices belong to virtual outputs, not
  physical monitor serial numbers. Omarchy's original scaling command still
  has its global persistence semantics; use the panel or OmacVM's command
  for independent secondary zoom.
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
- With one display switched to macOS (its Space) and a Mac app in front, a
  move over the VM on another display still moves the VM's pointer: hover,
  scrolling where the pointer is. Only the pointer's place goes to the VM:
  the keyboard stays with the Mac app, the Mac's arrow shows over the VM's
  pointer (as while the VM boots) and nothing comes to the front; a click
  takes the pointer and the keyboard as before. Only on two or more
  displays, in full screen, with nothing above the VM's window under the
  pointer (`omacvm-cocoa-pointer-hover*.patch`; 3.2.10 and older left the
  pointer standing until a click). `OMACVM_POINTER_HOVER=0` in QEMU's
  environment keeps the old way.
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
  that shows only the grey with no window on it (with HDR on, the screenshot
  has nothing there at all, alpha 0: Hyprland's copy for captures lacks its
  background colour) gets the shell restarted
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
  gives it as the VM touches it. What Linux frees goes back to the Mac
  (QEMU's balloon device with free page reporting, in blocks of 256 KiB and
  up: `src/memory/guest/90-omacvm-mm.tmpfiles`; QEMU tells macOS it may take
  the old pages, ADR 0062) and leaves QEMU's footprint, the number Activity
  Monitor shows. Up to 3.2.11 macOS kept holding those pages until the VM
  stopped. When macOS compresses the VM or warns that memory is short, the VM
  gives back its file cache (below).
- **Graphics memory** is extra, on top: the textures and buffers the VM's
  desktop and apps draw with, kept by the Mac's GPU driver for the VM. It
  grows and shrinks with what is on screen: Omarchy alone at 5K about
  1.2 GB, with a browser 2 to 5 GB (Chrome full screen on a 16 GB Mac mini's
  5K display: 2.1 GB, 4.5 GB at its peak), 3 GB at 8K, and for a moment more
  while the display scale changes (the table above). QEMU adds a part of its
  own per window, outside these numbers: the frames it hands to macOS (5
  buffers of about 62 MB at 5K, twice that with HDR or Extra brightness).
  2 s after the window goes out of sight (minimised, covered, another Space,
  the screen locked) the ones macOS is not showing or reading (3 or 4 of 5)
  become purgeable: they leave Activity Monitor's number and macOS may take
  them; they come back before the next frame (from 3.2.17, ADR 0067). QEMU's
  copy of the console's picture is made only while that picture shows (the
  console before the guest's first frame), not for the desktop (3.2.16 and
  older: 90-180 MB more graphics at 5K).

The app shows both: before a start, "VM memory: 8 GB; graphics memory last
run: peak 2.6 GB, from the Mac on top" (the (i) beside General › Resources
says the same); while the VM runs, its app menu (the
one beside the Apple menu) has "VM memory: 8 GB" and "Graphics memory:
1.6 GB (peak 2.6 GB)", read when you open the menu (a click explains them).
`omacvm check` has a "graphics memory" row: now, the peak of this run, and
macOS's memory pressure. So does the control centre in the VM (`omacvm`):
"Graphics memory: 1.6 GB (peak 2.6 GB)", looked at every 2 s while it is
open (nothing while it is closed), with a warning (!) while macOS is short of
memory or after refused allocations. `omacvm check`'s "Activity Monitor"
row says what Activity Monitor's number for the VM is made of (below).

**When macOS compresses the VM** (ADR 0059). Linux keeps every file it
read in its page cache, and to the Mac that is the VM's memory: macOS can
compress it but never drop it, although its own file cache already holds the
same disk image. macOS's memory pressure stays "normal" while it compresses
(it counts every page it can still compress as available), so a VM of 42 GB
on a 64 GB Mac held 15.5 GB of cache while macOS compressed the VM. The app
has a give-back for this (on from 3.2.12; 3.2.11 had it off). It runs only
with a QEMU that gives the pages the VM frees back to macOS (ADR 0062):
3.2.11's QEMU kept them held (Mac mini, 3 GB VM: of the given-back memory
the Mac still held, 1345 of 1346 MB and 1721 of 1721 MB stayed held), and a
file the VM reads again takes new pages, so there the give-back would make
the footprint smaller while the Mac held as much or more. The app knows
which QEMU it has from the fix's text in QEMU's binary
(`MemoryGiveBack.reclaimMarker`, read once per app run, off the main thread);
`OMACVM_RECLAIM_REUSABLE=0` (the fix's own switch) counts as without it.
`logs/qemu.log` says at each start "VM memory: give-back while macOS
compresses: on" or "off (this QEMU keeps given-back pages)". The text shows
that the fix is built in, not that it works on this Mac: if macOS keeps the
pages anyway (it refuses QEMU's advice, or half or more of 64 MB the Mac
held is still held after it), QEMU stops the fix for the run and writes
`logs/memory-reclaim`; the app looks at that file every 5 s and turns the
give-back off for the rest of the run ("off for the rest of this run" in
`logs/qemu.log` and in `omacvm check`).

The app looks every 5 s at QEMU's footprint and resident size
and at what macOS compressed. When QEMU has at least min(2 GB, a quarter of
the Mac) outside its resident memory, min(1 GB, an eighth of the Mac) more
than at its lowest, and macOS itself compressed 1 GB or more since (in all
processes: growing graphics trigger it only when macOS compresses 1 GB
elsewhere meanwhile), the app runs `src/memory/guest/giveback.sh` from its
own bundle in the VM (guest agent; no Update VM needed): the VM gives back
its file cache not used lately, except the newest min(1 GB, an eighth of the
VM) (`memory.reclaim` with `swappiness=0` on Inactive(file), in 1 GB steps,
at most 20 s; the memory-optimized kernel counted nearly all its file cache
as inactive in the VM read, so there it asks for nearly all of it; a 4 GB VM
on the MacBook Pro M1 Max gave back 1.1 of 2.5 GB, the stock kernel 1.2 of
2.8 GB, and of what the Mac still held of it none stayed held). The newest
part stays, so the files read last are not read again (on the Mac mini,
Chrome started in 1.02 s after a give-back that followed reading its files,
the same as without one); a file read again later comes from the Mac's file
cache (345 MB of Chrome's files: 0.2 s instead of 0.02 s). Programs' memory,
zram and the VM's memory setting are never touched. One give-back per 10
minutes at most (the warning's drop below included); after one that brought
back under 256 MB the next waits twice as long, up to 2 hours (what macOS
compresses then is the programs' own memory); the warning's drop does not
change that wait. When the VM's agent does not answer: again in 30 s, then
1, 2, 4, 8 minutes, then every 10 (one line in qemu.log). A kernel without a
cold-only way (before Linux 6.11) drops its whole cache instead.
`logs/qemu.log` has two lines per give-back ("macOS is compressing the VM
...", then what the VM freed and QEMU's footprint 60 s later).

`omacvm check` has a "VM memory" row: the VM's memory, whether the give-back
while macOS compresses is on, how many times the VM freed its file cache
this run and what it freed the last time (for the warning's drop, how much
smaller QEMU's footprint was a minute later: the footprint, not memory back
to the Mac), and when macOS still holds a quarter of the Mac compressed and
the VM had little left to give, that a smaller VM memory leaves the Mac more
(`omacvm resources`). A large VM's footprint can still be well above what
Linux uses (ADR 0059, "What this does not explain"). UTM, Parallels and
Fusion: nothing changes (their balloons do not report free pages).

**No fixed limit.** QEMU asks macOS how much memory it can give
(`virgl-darwin-memory-pressure.patch`):

- While macOS's memory pressure is normal (green in Activity Monitor),
  every allocation goes through.
- When macOS warns (yellow), QEMU lets the Mac's GPU driver free what it
  still holds for deleted textures (measured: nothing, as QEMU already
  flushes after every resource command; `logs/qemu.log` says "freed N MB"),
  and the app asks the VM to drop its whole file cache (at most every 10
  minutes, also counting the give-backs above, or 2 minutes after one of
  them; again after 30 s, then less often, if the VM did not answer), which
  then leaves QEMU's footprint (the cache it dropped: 0.1 GB on a fresh VM,
  1 GB after a long session; up to 3.2.11 macOS could keep holding the
  pages, above).
  QEMU keeps no cache of its own for the VM's graphics: everything it holds
  belongs to a live buffer of an app in the VM.
  Everything still goes through, unless a new big buffer (16 MB or more)
  is bigger than all the memory macOS has left: more swapping is better
  than a black desktop.
- When macOS is critical (red), a new big buffer goes through only when it
  fits in what macOS has left and the VM's graphics memory stays within what
  it used when critical began plus a grace: a 32nd of the Mac's memory,
  256 MB to 1 GB (16 GB Mac: 512 MB). So an app can go on replacing its
  window buffers (a 5K one is about 56 MB), and only growth past the grace
  is stopped. 3.2.14 and older refused every new big buffer at critical, so
  a browser lost its graphics at its next window for as long as critical
  lasted. Before a refusal QEMU frees what it can and looks again three
  times (100 ms; within a second of the last refusal it does not wait again,
  as the VM stands still while it waits).
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
shows a note ("chromium's graphics were restarted", or "firefox stopped
drawing") and why. On a MacBook Air with
8 GB a browser with big WebGL pages reached the guard while macOS still
said normal, and before this the next buffer refused was often Hyprland's
(a black VM). `OMACVM_GPU_MEMORY_RESERVE_MB` sets the desktop's part (0:
none) and `OMACVM_GPU_MEMORY_DESKTOP` its contexts (comma-separated
process names; for tests).

**When a buffer is refused**, the app that wanted it loses its GPU context
(the VM's graphics driver cannot hand back an "out of memory" for it), and
the VM's Mesa cannot tell the app: Chrome kept drawing into the lost
context, blank or flickering, until it was quit (3.2.14 and older). From
3.2.15 the VM ends the GPU process of an app that has one, and Chrome or
Chromium starts a new one within seconds: its windows draw again, open tabs
stay, pages with WebGL may need a reload (other Chromium-based apps such as
Electron's have the same GPU process; not measured). At most once per app
in 6 minutes and 3 times in an hour, because Chrome counts each as a crash
and draws without the GPU for the rest of its session after 3 recent ones. Lost again within that time,
the note says to quit the app and open it again. The app tells the VM once a minute per app at most; a
loss inside that minute is told when the minute is over (3.2.16; before, it was dropped and the app
stayed blank with no note). Other apps (Firefox, mpv)
draw nothing until they are restarted. `journalctl -t
omacvm-desktop-recover` in the VM says what was ended (ADR 0038). Hyprland
cannot get a new context that way: the VM's Mesa does not report a lost
context, and Hyprland 0.56, when told, stops ("Cannot
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

**When the VM stands still.** When macOS runs out of free memory (a VM that
holds most of the Mac, macOS compressing and swapping it), a vCPU's thread
can wait in macOS's kernel for seconds while macOS makes a page free for it;
the other vCPUs run on. In the VM that looks like a freeze: the guest kernel
logs an RCU stall, its daemons miss their watchdogs, the display agent says
"no word from the Mac for 15 s" (the user's M4 Max, 2026-10-28: vCPUs 1, 2,
3 and 8 stood still for about 60 s; on a Mac mini at critical pressure three
vCPUs stood 1.2-2.4 s; `tracks/vm-stall.md`). QEMU now says so
(`qemu-hvf-vcpu-stall-note.patch`): the stall watchdog's thread, when it
wakes anyway, looks at every vCPU thread's CPU time and state and at the
Mac's paging, and `logs/qemu.log` gets one line per stall of 1 s or more, in
this format (the numbers are an example): "OmacVM: stall: vCPUs 1, 2, 3, 8
stood still for about 58 s, blocked in macOS's kernel waiting for memory
(Mac: compressor and swap 900 MB/s, 0.3 GB free, pressure normal; the VM
holds 51 GB, 20 GB of it compressed by macOS)", "vCPU 3 stood still for
about 2.4 s, blocked in macOS's kernel (the Mac was not paging ...)" or
"vCPU 5 waited 2.1 s for a Mac core"; "waiting for memory" only when the
Mac was compressing or swapping 16 MB/s or more, or its pressure was warn or
critical, then. `logs/vm-stalls` keeps the counts, with QEMU's main loop
stalls of 2 s or more (with the BQL: the VM waited; in a GPU run: only the
display, disks and network). The app menu then has, for example, "The VM
stood still 2 times (longest 58 s): the Mac ran out of memory" under
"Graphics memory", `omacvm check` a "VM stalls" warning with what helps, and
after a stall of 10 s or more for memory the VM shows a note ("The VM stood
still for 58 s", at most once per 30 minutes; Update VM puts the note in).
No new timer, so short stalls can be missed: a vCPU blocked in macOS's
kernel under about 2.25 s (3.25 s if it was nearly idle before), one
without a Mac core under about 4 s. What helps: less
VM memory (`omacvm resources --vm NAME`), or fewer big apps on the Mac. The
app's give-back of the VM's cold file cache while macOS compresses it is on
from 3.2.12 (QEMU's free page reclaim, ADR 0062); 3.2.11 had it off. That a
stall came from the Mac's memory has been shown only in tests so far
(simulated stalls); live, on a Mac mini with its processors busy, the "waited
for a Mac core" lines matched the VM's own pauses.
QEMU's graphics thread no longer waits for the Mac's video service when a
video decoder starts ([video decoding](../video-decode.md#when-the-macs-video-service-is-slow)),
and its stall watchdog says when a stall of its own was in a GPU run without
the BQL (the vCPUs ran on) rather than with it (ADR 0060).

The guard is not only for runaway VMs on an 8 GB Mac: on a MacBook Air M2
(8 GB, 4 GB VM, 2026-10-06) Chromium with 7 windows of big WebGL pages
(5K canvas and 512 MB of textures each) reached 6 GB while macOS still said
normal (it said warn on the way, never critical; 2.3 GB swap, the Mac stayed
responsive). The browser lost its context first, Hyprland a few seconds later.

**On an 8 GB Mac** the VM gets 4 GB of VM memory by default; with apps
open on a 4K or 5K display the Mac is near its limit. macOS then compresses
and swaps first, and only refuses new graphics when it says memory is
critical. A smaller window or scale 2 needs the least.

**Memory the VM gives back leaves the Mac** (ADR 0062). When Linux reports
free memory, QEMU puts fresh memory in its place. Up to 3.2.11 the old
pages stayed on the Mac anyway, resident or compressed, until the VM
stopped: macOS frees such pages only with the whole block of memory they
belong to (guest RAM is a few blocks of 128 MB), and the rest of the block
was still the VM's. Activity Monitor did not count them, and macOS did not
count them as free. Now QEMU moves the old pages aside and a thread of its
own tells macOS they may go (`MADV_FREE_REUSABLE`): their compressed copies
go at once, and the resident ones are marked reusable: macOS takes them
first, without compressing them. Pages macOS is compressing at that very
moment get the same once more 20 ms later. "Held" below means in memory
and not marked, or compressed: marked pages count as given back, though on
a Mac with room they stay in memory until macOS needs it or the VM stops.
The advice never runs under QEMU's main lock: a range the thread has no room
for (4096 ranges waiting) or that cannot be moved aside gets the old way,
and `logs/qemu.log` counts it. On the Mac mini (a 3 GB VM after a browser
session, macOS compressing it), the old way left on the Mac all 1.3 GB it
still held of the 2.1 GB the VM gave back; now none of 1.5 GB (90 % of it
compressed). On a MacBook Pro M1 Max (a 4 GB VM, 3 browser sessions each
way) none of the 1.7-2.2 GB stayed held (3.3-3.5 GB with the
memory-optimized kernel); that Mac had room, so 1.2-1.6 GB of it stayed in
memory, marked, until the VM stopped (1.7-1.8 GB with that kernel). The old
way held 1.2 GB more until the VM stopped (1.8 GB with that kernel). QEMU's main lock per report of
freed memory: about 1 ms on the mini (the old way 0.4-0.7 ms, and 16.5 ms
in one run with 99 % of the pages compressed); on the M1
Max up to 8 ms either way, and 2.2 ms at most in a 4.1 GB drop of file
cache macOS had compressed (the old way up to 26 ms while macOS
compressed). `logs/qemu.log` has a line an hour while the VM gives memory
back and one when it stops: "free page reporting this run: N reports, X MB
reported in B blocks; main lock held per report p99 ..., longest ...", then
what was not moved aside and why, if any, and "this run the worker
released R MB, L MB of it left on the Mac". X is what the VM gave QEMU; L is
what the Mac still holds of R.
`OMACVM_RECLAIM_REUSABLE=0` in the app's environment is the old way. When
macOS keeps the pages anyway (a refused advice, or the pages still held
after it: half or more of 64 MB the Mac held), QEMU goes back to the old way
for the rest of the run, says why in `logs/qemu.log` ("macOS keeps the pages
the VM gives back") and in `logs/memory-reclaim`, and the app turns off its
give-back while macOS compresses (above). QEMU's first line of a run that
gives memory back, "free page reclaim gives the pages back to macOS", shows
the fix runs.

Activity Monitor's Memory for the VM is QEMU's footprint. The pages that
stayed were never in it, so it does not change with this. It can also show
more than the VM holds: once QEMU's own threads touched a guest page (the
disk, graphics, network) and macOS compressed it, macOS counts that page
twice there (a 4 GB VM on the Mac mini after a browser session: 5.9 GB
shown, 2.1 GB of it counted twice; the Mac got 4.8 GB back when QEMU was
killed). On a 16 GB Mac mini with Chrome full screen at 5K (2026-10-30) it
showed 23 GB for a VM of 12 GB with 4.5 GB of graphics, and 19.3 GB for
the same VM at 10 GB with 3.2 GB of graphics, while macOS compressed most
of it. `omacvm check`'s "Activity Monitor" row says what the number is made
of while the VM runs: "19.3 GB for the VM: VM memory at most 10.0 GB,
graphics 3.2 GB now, the rest 6.1 GB (QEMU itself, graphics overhead and
pages macOS counts twice while it compresses the VM)". VM memory is at most
what QEMU runs with (`-m`), as Linux may not have touched all of it; the
graphics are the VM's own count (`logs/gpu-memory`); the rest is not split
further: nothing on the Mac says which pages are counted twice. The row
reads QEMU's footprint with `proc_pid_rusage` (`src/lib/footprint.py`):
no task port, QEMU runs on.

**VM memory above the Best tier.** The Best tier leaves macOS and the
graphics max(8 GB, a quarter) of the Mac: 8 GB of a 16 GB Mac. More is
allowed, but the graphics come on top of it: a 12 GB VM with 4.5 GB of
graphics is up to 16.5 GB before macOS and the Mac's own apps, so macOS
compresses and swaps, reaches critical, and then refuses new big graphics
buffers for apps (above). The VM's General › Resources says so under the
memory in orange, with the last run's graphics peak, `omacvm resources`
says it as a `Warning:` line (and `"warning"` in `--json`) when it sets or
only reads such a value, and `omacvm check`'s "Activity Monitor" row is a
warning then (after a lower setting, until the VM starts again, it adds
"8 GB is set (applies at the next start)"). Nothing lowers the setting by
itself. The graphics stay
outside the setting, and the runaway guard stays at three quarters of the
Mac whatever the VM's memory (ADR 0034; one sized from the VM's memory
would stop Chrome at about 3 GB of graphics on a 16 GB Mac with an 8 GB VM,
below the 4.5 GB it used at 5K).

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
`tests/graphics/fractional-scale.sh` (a running VM),
`app/runtime/Tests/memory/test-reclaim.sh` (build time and CI: what a free
page report leaves on the Mac, with a real `hv_vm_map` where the Mac allows
one).

