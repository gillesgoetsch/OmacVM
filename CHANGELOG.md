# Changelog

What's new in each OmacVM release. The release notes on GitHub say the same
in more words.

## 2.7.0

- OmacVM.app: videos are decoded by the Mac's media engine instead of the
  VM's CPU. Google Chrome, Brave and Firefox (H.264 and VP9; AV1 in Chrome,
  not yet in Firefox), mpv, FFmpeg and GStreamer apps use it: YouTube in 4K
  at 60 fps plays with the VM's CPU nearly idle. HEVC and 10-bit video work
  too (mpv, FFmpeg, GStreamer; in Chrome HEVC stops after a seek for now). Omarchy's own Chromium
  (Arch Linux ARM) is built without VA-API and still decodes on the CPU; a
  route for it (V4L2) is planned. OmacVM installs no browser for this; Google
  Chrome for Linux ARM comes from `src/bench/install-chrome.sh`. See
  [docs/video-decode.md](docs/video-decode.md).
- OmacVM.app: a Linux app could stop the VM by reading back a texture in the
  YUYV plane format (mpv's VA-API check did): QEMU's heap overflowed. Fixed in
  the app's virglrenderer, with a build-time test for every texture format.
- Mac mini, iMac and Studio: a Studio Display or LG UltraFine's brightness
  follows the brightness keys; no keyboard light, notch or trackpad is a skip
  in `omacvm check`, not a failure; a Parallels VM on a Mac without a battery
  says so; Gestures finds VMware Fusion VMs when Fusion started after it; the
  Bridge picks the main display first.
- The menu says a suspended VM is suspended, not stopped.
- UTM and VMware Fusion: right after the first boot, the battery agent waits
  for the Bridge instead of failing (`omacvm check` reported it, and the
  Wi-Fi QR card, until a minute later).
- VMs from the 2.5 and 2.6 prebuilt images: the desktop background was black
  (links into the image's placeholder home). First boot now fixes the links;
  `omacvm apply` or `omacvm update` repairs older VMs.
- OmacVM.app: building a VM under the name of a deleted one no longer stops
  at step 5 (the old SSH host key), and a build works again after macOS
  cleared the live system's cache.
- Gestures: with two OmacVM.app VMs running, each keeps its connection (they
  all come from 127.0.0.1 and pushed each other out every second).

## 2.6.0

- OmacVM.app: Omarchy in its own Mac app, without Parallels, UTM or VMware
  Fusion. It brings QEMU (try-omarchy's patched build) and runs it with
  Apple's Hypervisor framework. Download `OmacVM-2.6.0.zip` from the release,
  signed with a Developer ID. See [docs/routes/app.md](docs/routes/app.md).
- `omacvm build --vm-type app`: builds the VM through OmacVM.app with the same
  questions as the other routes. It downloads the app when it is missing
  (after asking), checks the zip against its `.sha256` and that the app is
  signed with OmacVM's Developer ID. `omacvm update` replaces an older app.
- Omanotch is built in: it lives in `src/omanotch` and OmacVM installs it
  from there, on the Mac and in the VM, with no clone of its own repo.
- Proofs between the VM and the Mac, so another program on the Mac can't pose
  as Gestures, the Bridge or Omanotch: Gestures and Omanotch never get the
  Bridge's token; the VM and the helper each prove they know it (HMAC-SHA256
  over fresh nonces and the Mac address). The Bridge gets the token only
  after its own proof checks out.
- The Mac's battery in Omarchy's bar on a MacBook: charge, charging and
  Omarchy's battery panel, as on a laptop (feature `battery`, on for UTM,
  VMware Fusion and OmacVM.app; Parallels shows it itself). The VM never
  suspends for a low battery. Time left and the low-battery warning are not
  tested yet with the Mac on battery. See
  [src/battery/README.md](src/battery/README.md).
- The Mac's camera as *Mac Camera* for Linux apps and video calls in the
  browser (feature `camera`). It is on only while an app uses it. UTM and
  Fusion get it through OmacVM Bridge (installed for it also with the
  Bridge off), OmacVM.app over its own port, Parallels shares it itself.
  Programs on the Mac can't use the Bridge's camera.
- Sound and the Mac's microphone on UTM and Fusion: new VMs get a sound card,
  an existing one gets it the next time `omacvm apply` starts it from shut
  down. macOS must allow the VM's app the microphone; `omacvm check` says
  when it doesn't. OmacVM.app asks for it when it starts a VM; its QEMU
  starts the recording on a thread of its own, so a slow start never stops
  the VM (the VM records silence until the microphone runs).
- WebGL pages no longer hang in OmacVM.app. Basemark Web 3.0 stopped at its
  fifth test because the app's virglrenderer turned shaders that read integer
  textures into GLSL the Mac refuses (finding 23 in
  [docs/troubleshooting.md](docs/troubleshooting.md)).
- Omanotch can make its bar exactly as tall as the notch:
  `defaults write ch.gillesgoetsch.omanotch flush -bool true`. Off by default.
- The Mac's keyboard light goes three steps dimmer than macOS's lowest with
  Shift and the brightness keys (`"keyboard_low_steps": false` in the
  Bridge's `config.json` turns them off).
- One event stream from the Mac per VM, shared by the bar widgets and the
  on-screen display, instead of up to nine.
- Benchmarks: the GPU as a share of the Mac in the README (Basemark Web 3.0
  and WebGL Aquarium in Chrome). `bench.sh` runs Basemark too, and Geekbench's
  GPU test with Metal and OpenCL on the Mac. No VM can run Geekbench's GPU
  test: its Linux ARM preview has none, and no VM offers Vulkan or OpenCL.

## 2.5.0

- Prebuilt VMs for Parallels, UTM and VMware Fusion: `omacvm build` asks
  whether to build the VM here or download one (`--prebuilt`). The VM is
  ready in about 4 to 6 minutes instead of 30 to 70. See
  [docs/prebuilt.md](docs/prebuilt.md).
- The build picks the fastest Arch Linux ARM mirrors first, so a slow
  default mirror no longer stops it (#24).

## 2.4.1

- With Omanotch, notifications sit right under the notch strip.
- VMs on Arch Linux ARM's own kernel have their snapshots in GRUB again, and
  `omacvm check` says when they go missing.
- Two VMs in one app: Cmd shortcuts and swipes go only to the VM in front.
- The memory-optimized kernel: turning it off really goes back to the stock
  kernel; its build output goes to a log.

## 2.4.0

- Shift and the brightness keys set the Mac's keyboard light, with Omarchy's
  own popup; Option takes small steps.
- Longer battery life: the Gestures daemon, the Gestures helper, the
  clipboard, the Parallels display sync and the Bridge no longer wake up for
  nothing. `omacvm update` is much faster.
- Safer: OmacVM remembers each VM's SSH host key (after a rebuild:
  `omacvm apply --vm NAME --reset-host-key`); `omacvm update` sends the
  Bridge's key only to VMs it set up; Gestures talks only to VMs that know
  the Bridge's token; the clipboard from the VM follows no links; names are
  checked or quoted everywhere.
- Fixes: `omacvm update` goes on past a VM it can't reach; `--vm-dir` works
  with spaces and relative paths; your own lines in `input.lua` survive an
  update; UTM applies a new display mode at the next restart.

## 2.3.1

- New VMs get the Mac's clock (#11); builds no longer hang at "Waiting for
  SSH" with several keys in ssh-agent (#10); Canadian English keyboards get
  the English layout (#13).
- The README compares all four ways: speed, browser graphics, YouTube 4K,
  power and battery hours.

## 2.3.0

- The Mac's clock in Omarchy's bar, at the far right, in the Mac's format
  (`omacvm disable mac-clock` puts it back).
- Chromium, Chrome, Brave and Firefox draw on the GPU on every route.
- Older Parallels VMs use every display in full screen.
- Scroll momentum works in Brave; tools to measure power, battery life and
  video decoding.

## 2.2.2

- UTM: WebGL reads back right; every buffer is drawn without multisampling
  (no WebGL antialiasing on UTM).

## 2.2.1

- UTM: Chrome and the other Chromium browsers use the GPU. OmacVM sets UTM's
  default renderer, and `omacvm check` tells you if it isn't set.

## 2.2.0

- VMware Fusion is the third way, next to Parallels and UTM: every display
  in the macOS arrangement, the GPU, and all of OmacVM's features. OmacVM
  builds Hyprland with a fix for Fusion's black screen and builds VMware
  Tools. See [docs/routes/vmware-fusion.md](docs/routes/vmware-fusion.md).
- Choose where the VM goes (`--vm-dir`, also on an external drive).
- New Parallels VMs use every display in full screen; the slide between
  workspaces is back after a three-finger swipe; Omanotch repairs itself if
  its first build failed.

## 2.1.1

- The Mac's wallpaper keeps following Omarchy's theme after many theme
  switches (systemd no longer stops the watcher).

## 2.1.0

- The Mac's Bluetooth in Omarchy's Bluetooth panel: paired devices with
  battery levels, connect and disconnect, Bluetooth on and off, forget a
  device. Pairing opens the Mac's Bluetooth settings.

## 2.0.2

- Builds with scroll momentum no longer stop in the last step.
- macOS's permission prompts are explained when they appear; the Swift
  compiler is checked before the build starts.
- VM names are unique across Parallels and UTM.
- `omacvm check` points out a menu bar that is always shown; the setup draws
  right without a UTF-8 locale.

## 2.0.1

- Fresh Macs: Xcode's command line tools come through macOS's software
  update; free space is measured like Finder does (30 GB to build); home
  folders with spaces work; long build steps show a live status line.

## 2.0.0

- `omacvm`: one command to build, switch features, update and check, put on
  your PATH by the one-line installer.
- A setup that installs what is missing (Xcode's tools, Homebrew, Parallels
  or UTM 5) and asks its questions as screens.
- macOS-native scroll momentum (experimental).
- Every feature can be switched on an existing VM; each VM tells Gestures
  what it wants.
- Night Shift and True Tone in the bar; `--json` and exit codes for coding
  agents; Mac mini, iMac and Studio with a Magic Trackpad.

## 1.1.0

- `./build.sh` asks first: Parallels or UTM, resources, features, user, then
  a summary. The VM remembers the choices; `./apply.sh` keeps them.
- The memory-optimized kernel is opt-in.
- OmacVM's own icon; everything but the entry points moved to `src/`.

## 1.0.0

- First release: one command builds an Omarchy VM in Parallels Desktop or
  UTM, with the Mac's Wi-Fi, audio, media keys, Night Shift and True Tone,
  trackpad gestures, Retina displays at 120 Hz, the clipboard both ways and
  the keyboard layout from the Mac. `./check.sh` checks every feature.
