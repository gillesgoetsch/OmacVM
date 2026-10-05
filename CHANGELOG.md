# Changelog

What's new in each OmacVM release. The release notes on GitHub say the same
in more words.

## 2.9.0

A faster GPU path for OmacVM.app with frames on the display's refresh (120
Hz on a MacBook Pro), fewer black WebGL canvases, video encoding on the
Mac's media engine, ⌃⌥⌘ Esc straight back to macOS, media and brightness
keys for the VM and external displays, signed Mac helpers, and an opt-in
fast network. Numbers against 2.8.0 are from the release candidate, with
the benchmark lock held.

### GPU and display (OmacVM.app)

- A faster GPU path. GPU fences come back in about 0.2 ms instead of 1.5
  ms, so light 3D work runs two to three and a half times as fast:
  glmark2's short set 2,856 against 2.8.0's 1,124. A new frame goes to the
  window as soon as Omarchy finishes it, drawn off the main thread as an
  IOSurface, not on QEMU's 30 ms timer.
- WebGL-heavy pages stay about where they were; there Apple's OpenGL is the
  limit. Against 2.8.0 with one other VM running: Aquarium 19.0 against 19.9
  fps (4.5% slower: the new threads that wait for the GPU and show frames
  take Apple's OpenGL lock from the render thread; a fix is in testing),
  Basemark Web 3.0 2,669 against 2,482.
- The thread that waits for the GPU no longer keeps a core busy, also during
  a long GPU job (about 2,100 wakeups a second instead of 19,900). If it
  cannot start, the VM falls back to the old 1 ms polling and says so in
  `qemu.log` and `omacvm check`, instead of hanging the guest's GPU.
- Frames on the display's refresh: one new frame per refresh (testufo 117-120
  new frames a second on a 120 Hz display; 2.8.0 about 90). On a ProMotion
  MacBook the refresh rate follows what the guest draws (a 24 fps video asks
  for 24 Hz), as native apps do; displays with one rate keep it.
  `OMACVM_GL_REFRESH=fixed` keeps the full rate. The windows on other
  displays still draw the old way.
- Colours: frames are tagged sRGB, so the guest's colours are no longer
  stretched to the MacBook's P3 range (red was too saturated).
- WebGL and OpenGL apps: shaders and limits that Apple's OpenGL refuses no
  longer stop the app's whole GL context (the canvas or window went black for
  good). dEQP GLES3 (every 50th case) 812 to 855 of 869; the whole GLES3
  list in one process 22,445 to 43,125 cases; the WebGL conformance pages in
  one Chrome 430 to 776 (WebGL 1) and 97 to 959 (WebGL 2), because one
  refused shader no longer breaks every page after it. 107 transform
  feedback cases that failed in 2.7.1 pass.
- The guest can no longer make QEMU allocate up to 3 GiB of window surfaces,
  or new ones on every frame: they are at most the size of the largest Mac
  display and made again at most twice a second.
- If the picture or the GPU misbehaves on a Mac:
  `defaults write org.omacvm.app gpuSafeMode -bool true` and a VM restart go
  back to the fence and frame path of 2.8.0 (video decoding and the other
  fixes stay). `omacvm check` shows which path a VM took.
- Vulkan in the VM, hidden and experimental (Venus on MoltenVK):
  `defaults write org.omacvm.app venus -bool true`. Needs Mesa 26.2.4 or newer
  in the VM (`app/scripts/dev/guest-mesa-venus.sh` builds it while Arch Linux
  ARM has 26.2.3). vkmark about 4,500 to 5,200; the same build with the old
  polled fences gives about 730 (no release had Venus). Venus memory is mapped
  into the VM only in whole 16 KiB pages that belong to it. `omacvm check`
  names the Vulkan driver a VM uses.
- KosmicKrisp, opt-in at build time: a runtime built with
  `OMACVM_RUNTIME_KOSMICKRISP=1` (needs Xcode 26 and Homebrew's llvm,
  spirv-llvm-translator and spirv-tools) also carries Mesa's Vulkan
  driver on Metal. On macOS 26 and newer Venus then runs on it (Vulkan 1.4,
  more features than MoltenVK); when it cannot start, Venus falls back to
  MoltenVK, says why in `qemu.log`, and `omacvm check` shows a warning. The
  released app is built without it.
- HDR, hidden and experimental: `defaults write org.omacvm.app hdr -bool
  true`, then in the VM `sudo omacvm-virtio-gpu-build` (a 10-bit virtio-gpu
  module, rebuilt for new kernels) and a restart. Only on displays that can
  show HDR; the main window's output only. mpv and Chrome do not send HDR yet.
- In full screen the pointer no longer races near the screen corners and the
  Dock's edge (since 2.8.0 it got faster there with every move, up to about
  20 times). It now moves as macOS moves it everywhere, and reaches
  Omarchy's own corners. The Mac's cursor still stays off the corners and
  the Dock's edge. New setting "Keep the Dock and hot corners away in full
  screen" (on by default); off gives macOS's own full screen.
- "Use the notch for the menu bar" is on by default (Omarchy's bar beside the
  notch in full screen). It shows only on a Mac whose built-in display has a
  notch, checked again when displays change; if you switched it off before,
  it stays off.

### Video (OmacVM.app)

- Video encoding on the Mac's media engine: apps in the VM that encode H.264
  or HEVC through VA-API use it instead of the VM's CPU (FFmpeg's
  `h264_vaapi`/`hevc_vaapi`, OBS Studio's VAAPI encoders). Google Chrome's
  and Brave's WebRTC encoder (camera and screen sharing) is on by default.
  FFmpeg 1080p uses 6 to 8 times less Mac CPU than x264/x265. 8 encoders at
  once per VM, 12 at most. `OMACVM_VIDEO_NO_ENCODE=1` in QEMU's environment
  turns it off.
- Video decoding: up to 32 hardware decoders per VM (Chrome's 16 plus one
  Firefox's 16). Past that, a video decodes on the CPU instead of playing
  black (the VM's VA-API driver knows the Mac's limit). The copy of each
  decoded picture can no longer be dropped by the app's own graphics state.
  Existing VMs get the new driver with `omacvm update`.

### Keys, brightness and the Mac's helpers

- ⌃⌥⌘ Esc in the full-screen VM now takes you straight back to macOS: the
  monitor under the pointer swipes to the Space beside the VM's, with
  macOS's own animation, and the keyboard follows the pointer's monitor (no
  trackpad needed, a mouse is enough). Pressed there again it swipes back
  into the VM, full screen, with the trackpad and keys. OmacVM.app's
  "Escape combo" setting swipes all monitors instead (other routes:
  `defaults write org.omacvm.gestures EscapeSwipe all`). If the swipe cannot
  be made or does not land, the app you were in before comes to the front
  instead, and if macOS refuses that too, the VM's app is hidden: the
  keyboard is never stuck in the VM. Before, it only handed the trackpad
  back. OmacVM.app, Parallels, UTM and VMware Fusion.
- Media keys with an OmacVM.app VM in front, full screen or in a window:
  volume and mute set the Mac's output; when it has no software volume (an
  audio interface such as a Focusrite Scarlett), they set the VM's own
  volume with Omarchy's popup instead of macOS's greyed-out panel.
  Play/pause, next and previous go to the VM's players, not macOS's Now
  Playing. The keys reach the VM through QEMU's control socket; if that is
  busy, the key goes to macOS. The Bridge takes them at the HID level: on
  macOS 27 the volume keys never reach a session tap.
- OmacVM.app carries OmacVM Bridge and OmacVM Gestures built and signed with
  OmacVM's Developer ID: `omacvm apply`, `omacvm update` and the app install
  these copies (nothing is compiled on the Mac), and macOS keeps their
  Accessibility and Input Monitoring permissions across updates. macOS asks
  once more after the first signed install. A source checkout without the
  app, or of another version, builds them as before. Both helpers log which
  permission is missing, and `omacvm check` shows it.
- After OmacVM.app was restarted, ⌃⌥⌘ Esc and the media keys could stop
  working until the Mac's helpers were restarted: the new VM's own key tap
  sat ahead of theirs. They now take the front place again whenever an
  OmacVM VM comes to the front (Gestures fix by brianmerchant, #39).
- External display brightness (feature `external-brightness`, on): with the
  VM in front on an external display, the Mac's brightness keys set that
  display, in macOS's 16 steps (Option: 64), with Omarchy's popup. A display
  macOS dims itself (Studio Display, Pro Display XDR, LG UltraFine) goes
  through macOS's own control, also on a Mac mini where it is the only
  display; other monitors over DDC/CI. Omarchy's
  brightness keys, `omarchy brightness display` and its monitor panel in the
  VM do the same through OmacVM Bridge. OmacVM.app also in a window;
  Parallels, UTM and VMware Fusion in full screen. The built-in display works
  as before, and so does a display without DDC/CI (`omacvm check` names it
  and why). A key the Bridge cannot use goes to macOS, and the Bridge's log
  says once why.
- OmacVM Bridge: Wi-Fi no longer flips between connected and disconnected
  in Omarchy's bar on a Mac on Ethernet with Wi-Fi also on (Mac mini).
- Trackpad gestures off now means the VM's Gestures service is off on every
  route. On UTM, VMware Fusion and OmacVM.app it used to keep running for
  the Cmd shortcuts and connected to the Mac's Gestures anyway; Cmd as Super
  there now comes with the gestures feature. `omacvm apply` stops the service
  in VMs that have gestures off.

### OmacVM.app and its VMs

- OmacVM.app keeps its VMs in `~/OmacVM`, one folder per VM, and installs
  itself in `~/Applications`. VMs in the old place
  (`~/Library/Application Support/OmacVM/VMs`) stay there and keep working
  while `~/OmacVM` does not exist; a folder picked in the app still wins.
  `omacvm` finds the app in `~/Applications` or `/Applications` and the VMs
  the same way as the app. Spotlight still lists the file names in
  `~/OmacVM` (it never reads inside a VM disk); to hide them, add the folder
  under System Settings › Spotlight › Search Privacy.
- The install dialog starts on the name and folder of the copy you installed
  before, so a new download replaces it instead of adding a second app, and
  says when Install replaces a copy. Run Without Installing now counts for
  that copy only. Install refuses to replace a copy that is running.
- OmacVM.app opens the VM's window on the display you are using (under the
  pointer, else the one with the active menu bar) and gives it the keyboard.
- Fast network, experimental and off by default:
  `omacvm enable fast-network --vm NAME` puts the VM on macOS's own VM
  network (vmnet, as Parallels and UTM) through a small system service,
  `omacvm-netd`, that asks for your password once. On a Mac mini, VM to Mac
  7.2 instead of 3.0 Gbit/s with less CPU; Mac to VM is lower than the user
  network (9.5 against 12.2 Gbit/s). Without the service the VM keeps QEMU's
  user network. Not tested yet: a MacBook, VPNs, sleep and wake, Wi-Fi
  changes, several VMs at once, Omanotch over it.
- The app carries the licence texts of MoltenVK and the Vulkan loader
  (Apache-2.0, with cereal and cJSON), and of KosmicKrisp in builds that
  have it.

### Prebuilt VMs

- The image's manifest is checked before use. A bad value in a manifest (for
  example a disk size with a command in it) could run that command on the
  Mac; now such a manifest is refused and the VM is built here instead.

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
