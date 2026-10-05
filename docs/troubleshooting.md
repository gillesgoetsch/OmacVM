# Troubleshooting

Common problems first, with what to do. After them, problems whose cause is
not obvious from the symptom: each one as symptom, cause, fix and where the
fix lives. Recipes and the general failure table are in
[AGENTS.md](../AGENTS.md) (sections 6 and 7); notes for developers (security
reviews, measuring pitfalls, how the VM apps work inside) are in
[notes/findings.md](notes/findings.md).

## Common problems

- **First stop**: `omacvm check` names what is wrong and what to do.
- **The Mac's menu bar stays over the full-screen VM**: macOS is set to always
  show it. System Settings › Menu Bar (on older macOS: Control Center) ›
  Automatically hide and show the menu bar: **In Full Screen Only** (or Always).
  `omacvm check` points this out.
- **The Mac's pointer shows over the full-screen VM**: menu bar tools that keep
  their own window across the top of the screen (Bartender, for one) can bring
  it back. Quit them while you work in the VM.
- **The Bluetooth panel lists your devices but cannot connect them**: allow
  Bluetooth for *OmacVM Bridge* (System Settings › Privacy & Security ›
  Bluetooth); the panel says so too. A device that is off or out of range
  shows "Not in range?" after about 15 seconds.
- **Gestures or the scroll momentum do nothing**: the VM must be full screen and in front;
  ⌃⌥⌘ Esc may have handed the trackpad to macOS (press it again). Check the
  Accessibility and Input Monitoring permissions of *OmacVM Gestures*. A VM
  OmacVM did not set up may need `omacvm update --vm NAME` once: the Mac lets in
  only VMs whose trackpad daemon says the Bridge's token.
- **"answers with another SSH host key"**: OmacVM remembers each VM's SSH key.
  After rebuilding or reinstalling the VM: `omacvm apply --vm NAME --reset-host-key`.
- **Scrolling feels too fast or slow in one app**: Chromium-based apps get their
  own factor; tell us the app (window class from `hyprctl clients`) in an
  issue. The scroll momentum's settings are in `src/gestures/guest/omacvm-gestures`
  (`OMACVM_GLIDE_*`).

## Findings

| # | Route | Finding |
|---|---|---|
| 1 | Fusion | [Black screen with stock Omarchy](#1-fusion-black-screen-with-stock-omarchy) |
| 2 | Fusion | [Browsers draw everything in software](#2-fusion-browsers-draw-everything-in-software) |
| 3 | Fusion | [Displays sit in the wrong place on a Retina Mac](#3-fusion-displays-sit-in-the-wrong-place-on-a-retina-mac) |
| 4 | Fusion | [No hover or clicks on Omanotch's strip](#4-fusion-no-hover-or-clicks-on-omanotchs-strip) |
| 5 | Fusion | [Omanotch cannot find the Mac](#5-fusion-omanotch-cannot-find-the-mac) |
| 6 | Fusion | [Cmd+Space opens Spotlight, not Omarchy](#6-fusion-cmdspace-opens-spotlight-not-omarchy) |
| 8 | Fusion | [`no such host` during the build](#8-fusion-no-such-host-during-the-build) |
| 9 | All | [A swipe jumps to the next workspace when the fingers lift](#9-all-routes-a-swipe-jumps-when-the-fingers-lift) |
| 10 | All | [The Mac's pointer hides over the VM app's other windows](#10-all-routes-the-macs-pointer-hides-over-the-vm-apps-other-windows) |
| 14 | UTM | [Chrome has no GPU, then WebGL comes out empty](#14-utm-chrome-has-no-gpu-then-webgl-comes-out-empty) |
| 15 | UTM | [UTM idle power is being measured again](#15-utm-idle-power-is-being-measured-again) |
| 18 | All | [No snapshots in GRUB with Arch Linux ARM's own kernel](#18-all-routes-no-snapshots-in-grub-with-arch-linux-arms-own-kernel) |
| 19 | All | [Two VMs in one app both get the swipes and Cmd shortcuts](#19-all-routes-two-vms-in-one-app-both-get-the-swipes-and-cmd-shortcuts) |
| 20 | UTM | [Cmd+W stops the VM](#20-utm-cmdw-stops-the-vm) |
| 21 | UTM, Fusion | [No sound at all, no microphone](#21-utm-fusion-no-sound-at-all-no-microphone) |
| 22 | Parallels, Fusion, app | [The microphone records nothing, or silence](#22-parallels-fusion-app-the-microphone-records-nothing-or-silence) |
| 23 | app | [Chrome hangs in Basemark Web 3.0, the screen flickers](#23-app-chrome-hangs-in-basemark-web-30-the-screen-flickers) |

Findings 7, 11, 12, 13, 16 and 17 are notes for developers now:
[notes/findings.md](notes/findings.md).

## 1. Fusion: black screen with stock Omarchy

- **Symptom:** the VM boots to a black screen. SDDM's greeter never shows. The
  journal has `invalid arguments for wl_surface.attach` for every app.
- **Cause:** Fusion's GPU driver, `vmwgfx`, imports the apps' dmabufs as TTM
  surface handles, not GEM handles. Hyprland closes the imported handle with
  `GEM_CLOSE`, gets `EINVAL` and rejects the buffer. So every GPU client dies
  on its first frame.
- **Fix:** a one-file Hyprland patch by Pascal-0x90
  ([hyprwm/Hyprland#12966](https://github.com/hyprwm/Hyprland/discussions/12966)).
  When the driver is `vmwgfx` and `GEM_CLOSE` fails, it releases the handle with
  `DRM_VMW_UNREF_SURFACE`. There is no upstream pull request, so OmacVM carries
  the patch and builds Hyprland itself:
  - from the exact commit the installed package was built from (the stock
    binary names it in `Hyprland --version`), checked after the download;
  - as the desktop user, only the install step runs as root;
  - the package's own binary stays as `/usr/bin/Hyprland.stock`;
  - a pacman hook builds it again after every Hyprland update (10 to 20
    minutes, inside `omarchy update`).
- **Where:** `src/fusion/guest/build-hyprland.sh`,
  `src/fusion/guest/hyprland-vmwgfx-dmabuf.patch`, the hook
  `/etc/pacman.d/hooks/zz-omacvm-hyprland.hook` written by
  `src/fusion/guest/install.sh`. In the VM: state in
  `/var/lib/omacvm/hyprland-vmwgfx`, log in
  `/var/cache/omacvm/hyprland-vmwgfx/build.log`.
- **If it comes back:** `omacvm apply --vm NAME`, or in the VM
  `/usr/local/lib/omacvm/fusion/build-hyprland.sh`. To test the hook, reinstall
  with `pacman -S omarchy/hyprland`. Plain `pacman -S hyprland` takes Arch's
  `extra` first and downgrades Hyprland.

## 2. Fusion: browsers draw everything in software

- **Symptom:** Chromium, Chrome, Brave and Firefox are slow on Fusion, and
  WebGL is off or runs on `llvmpipe` (the CPU).
- **Cause:** Chromium's GPU blocklist has an entry for VMware's GPU on Linux
  (`software_rendering_list`, entry 176, "VMware is buggy on Linux"). Firefox
  counts every `vmwgfx` driver as software GL (`widget/gtk/GfxInfo.cpp`), so it
  draws pages with software WebRender and WebGL on `llvmpipe`. The GPU works
  fine with the vmwgfx fix above.
- **Fix:** OmacVM adds `--ignore-gpu-blocklist` to `/etc/chromium-flags.conf`
  and `/etc/chrome-flags.conf`, which Omarchy never rewrites, and to Brave's
  `~/.config/brave-flags.conf`. Omarchy's `omarchy install browser brave`
  replaces that file, so run `omacvm apply` after installing Brave. For
  Firefox it writes `/usr/lib/firefox/defaults/pref/omacvm-fusion.js`, which
  sets `gfx.blacklist.layers.opengl`, `gfx.blacklist.webrender` and
  `gfx.blacklist.webgl-use-hardware` to 1 (`gfx.webrender.all` and
  `layers.acceleration.force-enabled` don't help). Quit each browser fully
  afterwards: closing the window is not enough.
- **Check:** `chrome://gpu` says "Hardware accelerated" for Compositing,
  Rasterization and WebGL; Firefox's `about:support` says "Compositing:
  WebRender" (not "(Software)") and the WebGL renderer is SVGA3D.
- **Note:** WebGPU then shows "Hardware accelerated", but Fusion gives Linux
  no Vulkan, so there is no real WebGPU or GPU compute behind it. Video is
  decoded on the CPU: Mesa has no VA-API driver for `vmwgfx`, so YouTube 4K
  plays in software in every browser.
- **Where:** `src/fusion/guest/install.sh`. Google Chrome from
  `src/bench/install-chrome.sh` reads `/etc/chrome-flags.conf` through its
  `google-chrome-stable` launcher; Google's own launcher reads no flags file.

## 3. Fusion: displays sit in the wrong place on a Retina Mac

- **Symptom:** with the VM full screen on a Retina Mac, the Mac's pointer and
  Omarchy's pointer drift apart. To reach the notch strip or an external
  display you cross an invisible area first.
- **Cause:** Fusion sends its display layout in pixels. Hyprland's monitor
  positions are in logical points. At scale 2 the built-in display sat about
  1200 points too low (the external display ended 1200 points above it, not
  43).
- **Fix:** divide Fusion's positions by the shared scale before passing them to
  Hyprland. This only works when every output has the same scale; with mixed
  scales the positions are passed as they are.
- **Where:** `src/fusion/guest/omacvm-fusion-displays` (`apply()`).

## 4. Fusion: no hover or clicks on Omanotch's strip

- **Symptom:** on Fusion, the pointer gets pushed out of the strip beside the
  notch as soon as it enters. Nothing in Omarchy's bar there reacts to hover or
  clicks.
- **Cause:** Fusion moves the Mac's pointer whenever the guest moves its cursor.
  Parallels and UTM don't. Omanotch's `notchcast` nudged or moved the guest
  cursor when the pointer entered or left the strip, and Fusion pulled the Mac
  pointer straight back with it.
- **Fix:** on VMware, `notchcast` only hides and shows the guest cursor; it
  never moves it.
- **Where:** [Omanotch](../src/omanotch/README.md)'s `notchcast`,
  `src/omanotch/guest/notchcast/notchcast.c`.

## 5. Fusion: Omanotch cannot find the Mac

- **Symptom:** Omanotch's strip stays empty on a Fusion VM; `notchcast` cannot
  connect.
- **Cause:** `notchcast` looked for the Mac at the default gateway. On Fusion's
  NAT network the gateway is `.2` (Fusion's NAT), and the Mac is `.1`.
- **Fix:** OmacVM passes the Mac's address to `notchcast` as `NOTCHBAR_HOST`,
  on every route. `notchcast` also knows Fusion now.
- **Where:** `src/guest/install.sh` writes
  `~/.config/systemd/user/notchcast.service.d/omacvm-host.conf`.

## 6. Fusion: Cmd+Space opens Spotlight, not Omarchy

- **Symptom:** in a full-screen Fusion VM, Cmd+Space and other Cmd shortcuts go
  to macOS.
- **Cause:** Fusion, like UTM, keeps Cmd combos for macOS.
- **Fix:** OmacVM Gestures catches Cmd combos while the VM is full screen and in
  front, and sends them to Omarchy as Super, through the VM's
  `omacvm-gestures` daemon. Same as on UTM.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (the event tap, `NET_UTM ||
  NET_FUSION`).

## 8. Fusion: `no such host` during the build

- **Symptom:** the build fails while downloading many things at once (it first
  failed in the `yay` build, a Go build fetching its modules) with
  `no such host`.
- **Cause:** Fusion's NAT answers DNS itself and drops lookups when many come
  at once.
- **Fix:** public DNS (1.1.1.1, 9.9.9.9) only while OmacVM installs, then
  Fusion's DNS again. Fusion's DNS follows the Mac's, so a VPN, a Pi-hole or
  company DNS keeps working afterwards. `omacvm check` has a line for it.
- **Where:** `src/fusion/guest/dns.sh` (`on` at the start of
  `src/fusion/guest/install.sh`, `off` at the end of `src/guest/install.sh`),
  check in `src/guest/check.sh`.

## 9. All routes: a swipe jumps when the fingers lift

- **Symptom:** a three-finger swipe moves nothing while the fingers move, then
  the next workspace appears at once when they lift.
- **Cause:** Omarchy turns Hyprland's workspace animation off.
- **Fix:** with trackpad gestures on, OmacVM adds a slide animation for
  workspaces, like macOS Spaces, unless you already set a `workspaces`
  animation yourself.
- **Where:** `src/gestures/guest/install.sh`, writes to
  `~/.config/hypr/input.lua`.

## 10. All routes: the Mac's pointer hides over the VM app's other windows

- **Symptom:** the Mac's pointer disappears over any window of the VM app, for
  example Fusion's library window, not only over the full-screen VM.
- **Cause:** OmacVM Gestures hid the pointer over every window of the VM app.
- **Fix:** it now hides the pointer only over a window that fills its display.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (the hit test: the window must
  cover the display's width, and its height minus the menu bar).

## 14. UTM: Chrome has no GPU, then WebGL comes out empty

- **Symptom:** on UTM, `chrome://gpu` says "Software only" and WebGL is off
  (before 2.2.1). With 2.2.1, the GPU was on, but a page that read an
  antialiased WebGL canvas back got nothing, and the whole Chrome window
  could turn transparent.
- **Cause:** UTM's virglrenderer reports `max_samples 1` to Linux. OpenGL ES
  3.0 needs 4 samples, so Chrome's ANGLE refuses ES 3.0 and turns the GPU
  off. try-omarchy has the same problem
  ([try-omarchy#230](https://github.com/omacom/try-omarchy/issues/230)). And
  UTM can't really draw into multisampled buffers.
- **Fix:** a small preload library (`src/utm/guest/virgl-msaa.c`, from
  `/etc/ld.so.preload`) reports 4 samples to Mesa and creates every buffer
  single-sampled. The picture is right, without antialiasing. OmacVM also
  sets UTM's default renderer: with "Apple Core OpenGL" Chrome stays without
  GPU. After `omacvm update`, restart the browsers.
- **Note:** video is decoded on the CPU: UTM's VA-API lists no decode
  profiles. Chrome's "Video Decode: Hardware accelerated" is only a flag.
- **Where:** `src/utm/guest/install.sh`, `src/vm/utm.sh`, `src/cmd/apply.sh`.

## 15. UTM idle power is being measured again

- **Symptom:** the benchmark measured about 15 W for the whole Mac with an
  idle Omarchy desktop on UTM, against 5.5 to 6.2 W on Parallels, Fusion and
  OmacVM.app. A later check showed about 5 W on UTM at idle, also with an
  app open.
- **What we know:** UTM's QEMU only lets a virtual CPU sleep if its next timer
  is more than 2 ms away (`hvf_wfi()`), so a CPU with a running 1 ms tick
  wakes up more often. With nothing busy in the VM, Linux stops the tick and
  this costs little. The benchmark's run most likely had something busy in
  the VM.
- **Next:** a fair re-run, same state on every route
  ([#32](https://github.com/gillesgoetsch/omacvm/issues/32)).

## 18. All routes: no snapshots in GRUB with Arch Linux ARM's own kernel

- **Symptom:** without the memory-optimized kernel, GRUB has no "Omarchy
  snapshots" menu, and `/proc/cmdline` says `BOOT_IMAGE=/Image` with no
  initramfs (no Plymouth splash, and a read-only snapshot would get no
  writable overlay). Found when `omacvm disable thp-kernel` went back to the
  stock kernel.
- **Cause:** Arch Linux ARM installs its kernel as `/boot/Image`. GRUB's
  `10_linux` lists it but looks for `initramfs-Image.img`, which does not
  exist; grub-btrfs only looks at `vmlinuz-*`, so it found no kernel at all
  ("Kernels not found"). The memory-optimized kernel never had the problem:
  it is `vmlinuz-linux-aarch64-thp`.
- **Fix:** a copy of the kernel as `/boot/vmlinuz-linux`, which pairs with
  `initramfs-linux.img` in both, kept current by a pacman hook after every
  kernel update; GRUB boots it by default when the memory-optimized kernel is
  off. `omacvm check` fails "bootable snapshots" when GRUB has no snapshots
  menu.
- **Where:** `src/kernel/stock-kernel.sh` (copy and hooks
  `/etc/pacman.d/hooks/zz-omacvm-stock-kernel*.hook`), `src/guest/install.sh`
  (`GRUB_TOP_LEVEL`), `src/guest/check.sh`.

## 19. All routes: two VMs in one app both get the swipes and Cmd shortcuts

- **Symptom:** with two OmacVM VMs running in UTM, a Cmd shortcut in the
  full-screen one (Super+Return, Super+W) also reaches the other, and so do
  swipes and scrolling. Found from the code during the UTM end-to-end test,
  while a second UTM VM ran.
- **Cause:** OmacVM Gestures knows which app is in front (UTM, Parallels or
  Fusion), not which of its VMs. It sends keys and touches to every VM
  connected from that app's network (`sendTo(frontNet, …)`); every app has one
  network for all its VMs. On Parallels only the swipes and scrolling are
  affected (Parallels passes Cmd itself).
- **Fix:** `omacvm apply` gives the VM its name (`OMACVM_VM_NAME_B64` in
  `/etc/omacvm/env`), the guest daemon says it in its hello, and the helper
  reads the title of the VM app's front window through Accessibility (on
  every app switch and on its 0.2 s check while a VM app is full screen in
  front). Frames, keys and the capture state go only to the VM whose name is
  in the title; switching VMs sends `S off` to the old one and `S on` to the
  new one. Window titles seen: Parallels the VM's name (windowed and full
  screen), UTM "UTM – NAME", VMware Fusion and OmacVM.app the VM's name
  (windowed; their full screen not checked yet). Tested with two Parallels VMs: Cmd+Return opened a terminal only in
  the VM in front, and only it got the swipe. A VM set up before this (no
  name in its hello) or renamed since its last `omacvm apply` matches no
  title: then every VM of that app gets them, as before; run `omacvm update`.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (`pickTargets`,
  `windowTitle`), `src/gestures/guest/omacvm-gestures` (hello),
  `src/guest/install.sh` (`--vm-name-b64`), `src/cmd/apply.sh`.

## 20. UTM: Cmd+W stops the VM

- **Symptom:** the VM is gone after Cmd+W; the guest journal of that boot
  just ends, without a shutdown.
- **Cause:** when OmacVM Gestures does not take the key (VM not full screen,
  trackpad handed back with ⌃⌥⌘Esc, or a key posted by a script below the
  keyboard, such as System Events' `keystroke`), UTM gets Cmd+W and closes
  the VM window. With UTM's "don't ask before quitting" setting
  (`NoQuitConfirmation`), closing the window stops the VM at once.
- **Fix:** in full screen with the trackpad captured, Cmd+W is Super+W in
  Omarchy (tested: it closes the guest's window, UTM never sees it). To test
  Cmd shortcuts from a script, post them at the HID level
  (`CGEvent.post(tap: .cghidEventTap)` with a `.hidSystemState` source), not
  with System Events.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (event tap at
  `kCGHIDEventTap`).

## 21. UTM, Fusion: no sound at all, no microphone

- **Symptom:** in a UTM or VMware Fusion VM, `aplay -l` says "no soundcards
  found"; Omarchy plays nothing and PipeWire has no input.
- **Cause:** neither app gave the VM a sound card. UTM's scripting has no
  sound property, so the VM it made had `Sound = []`; `vmcli VM Create`
  writes no `sound.*` lines.
- **Fix:** UTM: `Sound = [{Hardware = intel-hda}]` in the VM's config.plist
  (QEMU then gets `intel-hda` + `hda-duplex` on UTM's SPICE audio, input and
  output). UTM starts a VM with the configuration it read at its own start,
  so after the edit UTM is quit first (only when no UTM VM runs), else the VM
  comes up without the card. Fusion: `sound.present`, `sound.virtualDev =
  "hdaudio"`, `sound.fileName = "-1"`, `sound.autodetect` in the .vmx. New VMs
  get it during the build; an older VM when `omacvm apply` starts it from shut
  down. Tested: UTM records the Mac's microphone (RMS about 9, a quiet room),
  Fusion shows "HD-Audio Generic" for playback and capture.
- **Where:** `src/lib/mac.sh` (`utm_add_sound`, `fusion_add_sound`),
  `src/lib/vm.sh` (`vm_boot`), `src/cmd/build.sh`.

## 22. Parallels, Fusion, app: the microphone records nothing, or silence

- **Symptom:** PipeWire lists the input, but a recording is empty: on Fusion
  and OmacVM.app `pw-record` gets no samples at all
  (`/proc/asound/card0/pcm0c/sub0/status`: `hw_ptr 0`); on Parallels the
  samples come but are all zero (`Capture` at 100 % and on). On Fusion the
  whole VM also stops for about four minutes when the recording starts (no
  SSH, `vmware-vmx` at full CPU) until the refusal below is logged; on
  OmacVM.app before 2.6.0's fix too.
- **Cause:** macOS's microphone permission for the app that records on the
  Mac. Fusion's `vmware-vmx` and OmacVM.app's QEMU are helpers that cannot
  ask for it themselves: their `AudioQueueStart` fails with 268451843.
  vmware.log says `SoundAQStartStream: Failed to start input audio queue,
  error: (no mapping) (268451843)`; OmacVM.app's `logs/qemu.log` says
  `SDL_OpenAudioDevice for recording failed: CoreAudio error
  (AudioQueueStart): 268451843`. Parallels hands the VM silence instead. UTM
  recorded the Mac's microphone on the same Mac because UTM had the
  permission already. 268451843 is 0x10004003, `MACH_RCV_TIMED_OUT`:
  coreaudiod did not answer `AudioQueueStart` (`_TellServerAboutStreamUsage`)
  in time. Why the app's VM stopped: QEMU opened the recording on a vCPU
  thread that holds its global lock (`sample` showed `sdl_open` under
  `intel_hda_set_st_ctl`), so the whole VM waited with it.
- **Fix:** Parallels and Fusion: allow Parallels Desktop or VMware Fusion in
  System Settings › Privacy & Security › Microphone (a person's step), then
  restart the VM. OmacVM.app: the app now asks for the microphone when it
  starts a VM, and QEMU records under its grant; the Developer ID build has
  the `audio-input` entitlement for that. Without the permission the app
  starts QEMU without recording (`in.voices=0`, and a line in `qemu.log`);
  allow it, then restart the VM. macOS counts QEMU's recording as the app's
  (tccd: microphone for `org.omacvm.app`, allowed), and with the grant
  `AudioQueueStart` answers in well under a second. The app's QEMU now
  starts and stops the recording on a thread of its own
  (`qemu-sdl-audio-capture-thread.patch`): the VM keeps running whatever
  CoreAudio does, records silence until the microphone runs, and logs
  `SDL recording device did not start within 5 seconds` when it is slow
  (a sound that starts meanwhile waits for it). `omacvm check` reads the
  Fusion and app logs for the refusal (and says to restart).
- **Where:** `app/app/Sources/OmacVM/Runner.swift`, `app/app/OmacVM.entitlements`,
  `app/runtime/patches/qemu-sdl-audio-capture-thread.patch`, `src/cmd/check.sh`.

## 23. app: Chrome hangs in Basemark Web 3.0, the screen flickers

- **Symptom:** in OmacVM.app (2.6.0), Basemark Web 3.0 in Google Chrome
  stops at test 5 of 20, the page flickers and no score comes, even after
  15 minutes. It finishes on the Mac and in Parallels, UTM and Fusion. WebGL
  Aquarium and the desktop keep working.
- **Cause:** the app's virglrenderer turns the guest's shaders (TGSI) into
  GLSL for the Mac's OpenGL 4.1. One of the patches it is built with
  (`virglrenderer-a8-shader-swizzle-texture.patch`, for alpha-only textures)
  reads every `texture()` result into a `vec4`. On an integer texture
  (`usampler2D`) that gives `uintBitsToFloat(vec4)`, which does not exist, so
  Apple's compiler refuses the shader. The VM's `logs/qemu.log` says
  `Shader failed to compile`, `ERROR: 0:273: No matching function for call to
  uintBitsToFloat(vec4)`, then `context 11 failed to dispatch DRAW_VBO` and
  `ctrl 0x106, error 0x1200` for every later command: virglrenderer stops
  that GL context for good, and Chrome's GPU process keeps drawing into a
  dead context. The patch also put the write mask on that `vec4`
  (`vec4 val = texture(...).x`), which does not compile either.
- **Fix:** `app/runtime/patches/virgl-texture-integer-samplers.patch`: the
  temporary has the sampler's own type (`vec4`, `uvec4`, `ivec4`), the write
  mask goes on the assignment only. Each runtime build compiles these
  shaders with the Mac's OpenGL (`app/runtime/Tests/virgl/test-integer-sampler-shader.c`),
  and `app/scripts/gpu-check.sh` runs Aquarium and Basemark in an app VM and
  reads `qemu.log` for refused shaders.
  Tested on a new app VM (8 CPUs, 8 GB, a window, not full screen): with
  2.6.0's runtime the same shader is refused at Basemark's test 5, later
  WebGL tests score -1 and the tab stops answering; with the patch Basemark
  finished 3 times in a row (1054, 772, 1073 in that small window, with other
  VMs running on the Mac) and Aquarium still runs (19-21 fps).
- **Where:** `app/runtime/patches/`, `app/runtime/build-qemu-gpu-runtime.sh`,
  `app/runtime/Tests/virgl/`, `app/scripts/gpu-check.sh`.
