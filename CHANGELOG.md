# Changelog

What's new in each OmacVM release. The release notes on GitHub say the same
in more words.

## 2.8.0

- OmacVM.app uses every Mac display in full screen: a window (in its own
  Space) and an Omarchy output per display, at its resolution, scale and
  refresh rate, placed as in macOS's arrangement, with plugging in and out
  live. "Use external displays" in Omarchy's display panel keeps full screen
  on one display. Tested on a real external monitor next to a MacBook with a
  notch, and on virtual displays.
- OmacVM.app in full screen on a Mac with a notch: Omarchy gets the window's
  real size (1728x1080 points on a 14-inch MacBook Pro, was 1728x1085). The
  picture is no longer squeezed and the pointer lands where it is on the Mac
  (it was up to 5 points off at the bottom).
- OmacVM.app in full screen: the Dock no longer comes up at the edge of an
  external display. Near a screen corner the Mac's cursor is held 3 points
  short of it; whether that keeps macOS hot corners from firing is not
  confirmed yet (in tests with simulated mouse motion they still fired).
- Cmd-drag moves an Omarchy window from one Mac display to another; a held
  modifier key is no longer let go when the pointer crosses to another
  display's window.
- Omanotch with external displays: the strip and its bar stay on the
  MacBook whichever display holds the main window (OmacVM.app tells the VM
  which output is the built-in display). Before, with the main window on an
  external display, the MacBook showed two bars.
- OmacVM.app: displays no longer come up black (dark grey, no wallpaper, no
  bar) after a start or reboot, about one boot in six with two displays.
  QEMU refused the memory of a large texture (Omarchy's wallpaper, 81 MB)
  when the VM's memory was fragmented, and the shell lost its GPU context.
  It also happened with one display, less often, in earlier versions.
  The VM now also checks what each display really shows and restarts the
  shell once if one stays grey; omacvm check says "desktop" and, on the Mac,
  "GPU contexts".
- Omanotch's wallpaper is decoded at the display's size (about a third of
  the memory per display on a MacBook, so UTM's QEMU, which keeps the old
  limit, no longer refuses it up to about a 4K display; a 6K display's
  upload is still too big for it), and its bar and wallpaper follow their
  output when it moves in the layout.
- Omanotch: after a shell restart the bar is parked under the strip again
  within seconds; before, the MacBook could show two bars.
- Per-display workspaces handle more than two displays (Virtual-3 gets
  21..30, and so on), and several workspaces of an unplugged display all
  come back when it returns. Tested on OmacVM.app; Parallels and Fusion use
  the same file.
- Change the CPUs and memory of an existing VM: `omacvm resources --vm NAME`
  with `--resources low|balanced|high|best`, `--cpus N` or `--memory-gb N`
  (also in the `omacvm` menu). The same tiers and limits as the build, on
  every route: Parallels (`prlctl set`, or its settings file on Standard),
  UTM, VMware Fusion (graphics memory goes down with the memory when it would
  no longer fit) and OmacVM.app. The VM must be stopped, except on
  OmacVM.app, which takes the change at its next start. A name used in two
  apps needs `--vm-type`.
- OmacVM.app: a Resources picker in the VM's window, with the create
  screen's tiers; it applies on the next start.

## 2.7.1

Security and crash fixes for OmacVM.app's GPU (a VM could restart the Mac),
plus fixes from testing 2.7.0 on a Mac mini.

- OmacVM.app: a Linux app could make the Mac's GPU read outside a buffer (a
  draw past the end of its buffers, an unbound uniform block); the GPU
  faulted and macOS restarted. The app now checks every buffer range a draw
  reaches before the GPU sees it, and skips draws that would leave one.
- OmacVM.app: a WebGL 2 or OpenGL ES app using transform feedback could stop
  the VM (QEMU crashed in Apple's OpenGL when it ended the recording). Fixed in
  the app's virglrenderer, with a build-time test.
- OmacVM.app: a shader the Mac refuses skips its draws instead of stopping the
  whole app's GPU context.
- OmacVM.app: a Linux app switching the screen between large modes in a loop
  grew the VM's GPU memory on the Mac by up to 1.1 GB per switch and never gave
  it back, until the Mac ran out of memory (2.6.0 and 2.7.0 too). Two GL
  contexts were never flushed; both are now, and the memory stays flat.
- OmacVM.app: the textures and buffers a VM's apps make have a memory budget
  on the Mac, a quarter of its memory (`OMACVM_GPU_MEMORY_MB` changes it, 0
  turns it off). Past it, the app's GPU context stops; the VM and the Mac go on.
  Screens and cursors may go 256 MB past it, so the desktop keeps working.
- OmacVM.app: a texture copy whose size the app's check cannot work out is
  refused (2.7.0 let such copies through unchecked).
- OmacVM.app: a VM starts with Omarchy's logo instead of TianoCore's. The app
  builds its UEFI firmware itself: the same edk2 as QEMU's, with QEMU's build
  flags, only the logo is new. If that build fails, the app keeps QEMU's
  firmware and says so.
- Omanotch no longer asks for Accessibility. It picks the VM for the strip by
  the full-screen window's app; with two VMs of one app it keeps the one it
  serves (or takes the one that connected last) instead of reading window
  titles.
- `omacvm uninstall --purge` deleted every OmacVM.app VM: on macOS's usual
  disk, OmacVM's settings folder and the app's VMs folder are the same. It
  now removes only OmacVM's own files, and says what stays.
- A VM name used in two apps (a Parallels VM and an OmacVM.app VM both called
  "OmacVM Test") is no longer guessed: `omacvm apply`, `check`, `features` and
  `update --vm NAME` stop and ask for `--vm-type`. Before, they took the
  Parallels VM.
- UTM: listing VMs (the menu, `omacvm vms`, `update`, `build --dry-run`) no
  longer hangs for up to 10 minutes while macOS asks whether the terminal may
  control UTM; a VM's address is found without waiting on UTM; a UTM VM in an
  unknown state is never started. The build asks about that permission before
  the download, and a timeout says it may be macOS's unanswered prompt. Build
  UTM VMs in Terminal on the Mac, not over SSH.
- `omacvm build` lists OmacVM.app first in the app question, as the README
  recommends.
- `omacvm check` on a Mac without a notch says "no notch" for the app's notch
  strip line.
- `omacvm update` says "macOS asks for permissions now" only on a first
  install.
- **VMs last set up or updated with OmacVM 2.3 or older need one
  `omacvm update`** (with the VM running). Until then OmacVM Gestures doesn't
  let them in, because their trackpad daemon has no Bridge token.
  `omacvm check` says so.
- Old names are gone: `--mac-wallpaper` (now `--wallpaper`), the feature name
  `glide` on the command line (now `scroll-momentum`; a VM that still has the
  old setting keeps it), and the clean-up of the "Omarchy Notch Bar" app from
  before Omanotch had its name.
- The 1.x commands `./build.sh`, `./apply.sh` and `./check.sh` in the
  repository's root are gone. Use `omacvm build`, `omacvm apply` and
  `omacvm check`.

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
