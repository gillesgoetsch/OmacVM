# Troubleshooting

Common problems first, with what to do. After them, problems whose cause is
not obvious from the symptom: each one as symptom, cause, fix and where the
fix lives. Recipes and the general failure table are in
[AGENTS.md](../AGENTS.md) (sections 6 and 7); notes for developers (security
reviews, measuring pitfalls, how the VM apps work inside) are in
[notes/findings.md](notes/findings.md).

## Common problems

- **First stop**: `omacvm check` names what is wrong and what to do.
- **Omarchy's update says "You need at least 10 GiB free to safely update
  Omarchy."**: the VM's disk is nearly full. `omacvm check` warns first
  ("free space"). Delete files in your home you no longer need (they free
  their space at once; system files stay in the 2 update snapshots until
  newer ones replace them), or give the VM a larger disk: shut it down, then
  Disk › Change… in its window. The VM grows into it at its next start.
- **A VM in Parallels, UTM or VMware Fusion**: OmacVM 3.4.0 retired those
  routes. The VM keeps running as it is, without OmacVM updates. Move to
  OmacVM.app: [how](../README.md#retired-routes).
- **Google Chrome's tab crashes ("Aw, Snap!") on videos, on a Mac with an M4
  or newer** (OmacVM.app): update Chrome to 155 or newer. Chrome 154 and
  older, and older Electron apps (Electron 42 and 44 measured), crash on every
  video they decode on the CPU (small ones below 360 rows, or all with
  hardware decoding off).
  The VM sees the chip's SME, and their libyuv was built for chips that also
  have SVE, which the M4 does not (fixed in Chrome 155). `omacvm check` warns
  about it ("Google Chrome").
- **Chrome goes blank or flickers while the Mac is short of memory**
  (OmacVM.app 3.2.14 and older; the VM says "chrome stopped drawing"): the VM
  needs no restart. Free memory first: close Chrome windows and tabs at 5K
  and quit Mac apps you do not need until Activity Monitor's memory pressure
  is no longer red. While it is red, a restarted Chrome loses its graphics
  again at once, and each restart counts as a Chrome crash. Then, in a
  terminal in the VM, `pkill -f -- 'chrome --type=gpu-process'` (at most once
  every 5 minutes), or quit Chrome and open it again. With 3.2.15 the VM
  restarts Chrome's graphics by itself (Update VM), and an app that only
  replaces its buffers keeps them (the app update, from the VM's next start)
  ([48](#48-app-chrome-goes-blank-or-flickers-while-the-mac-is-short-of-memory)).
- **Notifications, bar panels or the Omarchy menu black out the whole screen**
  (Hyprland 0.57): Update VM (3.2.15) or
  `omacvm update`, then log out and in
  ([50](#50-notifications-panels-and-the-omarchy-menu-black-out-the-screen-hyprland-057)).
- **Ghostty opens no window** (OpenGL 4.3 needed, the VM gives 4.1): Update
  VM (3.2.14), then log out and in; it then draws on the VM's CPU. Alacritty
  and Kitty draw on the Mac's GPU; from 3.2.18 the app's experimental switch
  Ghostty on the Mac's GPU moves Ghostty there too (macOS 26 and newer)
  ([47](#47-app-ghostty-opens-no-window-or-draws-on-the-cpu)).
- **Activity Monitor shows the VM with far more memory than you gave it**
  (OmacVM.app, e.g. 23 GB for a 12 GB VM): its graphics come on top, and
  macOS counted every page of the VM that QEMU itself touched twice (from
  3.2.17 QEMU drops that count every few minutes: update the app).
  `omacvm check` says what the number is made of; above the Mac's Best
  tier, give it less
  ([49](#49-app-activity-monitor-shows-the-vm-with-far-more-memory-than-it-has)).
- **Screenshots or screen sharing of Chrome far too bright in an HDR VM**:
  Update VM
  ([44](#44-app-screenshots-and-screen-sharing-of-chrome-too-bright-in-an-hdr-vm)).
- **Gestures do nothing after copying a VM to another Mac**: the Mac helpers
  are set up per Mac, by Update VM in OmacVM. The app says so before the
  start and offers it
  ([40](#40-app-gestures-and-the-bar-do-nothing-in-a-vm-copied-from-another-mac)).
- **macOS asks "Allow “OmacVM” to find devices on local networks?"**: click
  Allow. Omarchy's network runs through OmacVM, so its name lookups (through
  the Mac's DNS server, often your router or Tailscale) and the devices on
  your network count as OmacVM reaching the local network. macOS asks once;
  updates through OmacVM keep the answer. A copy of another version in
  another folder is asked again. To change it later: System Settings ›
  Privacy & Security › Local Network › OmacVM, then restart the VM
  ([42](#42-app-macos-asks-to-let-omacvm-find-devices-on-local-networks)).
- **AirPods or Control Center play or pause the Mac's music, not the VM's
  video** (OmacVM.app): pause and play in the VM once; a Mac app that played
  later has the controls, as between Mac apps
  ([43](#43-app-airpods-or-control-center-play-the-macs-music-not-the-vm)).
- **A feature does not switch on: "Omarchy's package list is older than the
  mirrors"**: the VM's system was not updated for a while, and the packages
  the feature needs are no longer on the mirrors in those versions. OmacVM
  never updates one package alone (a partial update can leave a black screen,
  [27](#27-black-screen-after-an-update-or-an-omacvm-job)). Update
  the VM's system first with omarchy update (the control centre offers it:
  y, or U then o), then switch the feature on again. A VM made from a
  prebuilt image gets this update once at its setup (from 3.1.25).
- **The Mac's menu bar stays over the full-screen VM**: macOS is set to always
  show it. System Settings › Menu Bar (on older macOS: Control Center) ›
  Automatically hide and show the menu bar: **In Full Screen Only** (or Always).
  OmacVM.app with **Keep the Dock and hot corners away** on (the default)
  hides it anyway; with that setting off, **Full screen including notch**
  starts as normal full screen. `omacvm check` points this out.
- **A keyboard sharing app (Synergy, Deskflow, Barrier, Input Leap) loses
  the keyboard to the VM**: the VM types what was meant for the other
  computer. Turn on the hidden switch in
  [34](#34-app-keyboard-sharing-apps-the-vm-takes-the-keys-meant-for-the-other-computer).
- **The Mac's pointer shows over the full-screen VM**: menu bar tools that keep
  their own window across the top of the screen (Bartender, for one) can bring
  it back. Quit them while you work in the VM. In OmacVM.app up to 3.1.24 the
  Mac's arrow could also stay next to Omarchy's pointer until you switched out
  of the VM and back; Ctrl+Option+G and then a click into the VM hides it too.
- **The Bluetooth panel lists your devices but cannot connect them**: allow
  Bluetooth for *OmacVM Bridge* (System Settings › Privacy & Security ›
  Bluetooth); the panel says so too. A device that is off or out of range
  shows "Not in range?" after about 15 seconds.
- **Gestures or the scroll momentum do nothing**: the VM must be full screen and in front;
  if ⌃⌥ Esc left you in the VM without the trackpad, press it again. Check the
  Accessibility and Input Monitoring permissions of *OmacVM Gestures*
  (`omacvm check` names a missing one; the helpers' logs say
  "permissions: ... MISSING").
- **⌃⌥ Esc does not move to another Space**: the move needs a Space beside
  the VM's on that monitor (System Settings › Desktop & Dock › Mission
  Control: "Displays have separate Spaces" decides whether each monitor has
  its own) and macOS's "Move left/right a space" shortcuts (System Settings ›
  Keyboard › Keyboard Shortcuts › Mission Control). Without them, Omarchy
  shows a notice ("No way to macOS: turn on ...") and nothing else happens.
  The Gestures log (`~/Library/Logs/omacvm-gestures.log`, lines
  "escape combo: ...") says which way it took.
- **A macOS shortcut still does its macOS thing in the VM** (a screenshot,
  Mission Control): that is the default; sending them all to the VM is
  experimental (`defaults write org.omacvm.app macShortcuts -bool false` and
  a VM restart). With it on, the VM's window must have the keyboard (click
  into it). `omacvm check` shows "macOS shortcuts"; `logs/qemu.log` in the
  VM's folder says "macOS shortcuts off" while the VM has them. The power /
  Touch ID key stays macOS's (macOS handles it below every app).
- **The globe (fn) key opens Emoji & Symbols over the VM**: since 3.0.1 a
  lone globe press in OmacVM.app goes to the VM while its window has the
  keyboard (Omarchy's emoji picker; the key is XF86Launch3 there, for your
  own bindings). Only that one macOS shortcut is switched off, only while the
  VM has the keyboard; fn+F1..F12 and fn as a modifier work as before.
  `qemu.log` says "globe key goes to the VM", and for the first presses
  how macOS showed them ("globe key pressed: fn alone" or "key code 0xb3";
  none at all means the press never reached the VM; "fn with a key, click
  or scroll the VM window did not see" means fn was used as a modifier).
  The globe key reaches the VM but nothing opens: the VM was set up before
  3.0.1, run `omacvm update`. To leave it with macOS:
  `defaults write org.omacvm.app globeKeyToVM -bool false` and a VM restart.
  If the globe key ever does nothing in macOS after a VM crashed: start and
  quit any OmacVM VM (it gives macOS's shortcut back), or log out and in.
- **macOS's shortcuts (⌘Tab, ⌘Space, brightness) do not work after leaving
  the VM** (only with the experimental `macShortcuts` false): they come back
  the moment the VM's window loses the keyboard, and macOS restores them by
  itself if the VM's app quits or crashes. If the VM's window hangs, OmacVM
  turns them on after 2 seconds (`qemu.log`: "the VM window stopped
  answering"). Go back to the default with `defaults delete org.omacvm.app
  macShortcuts` and a VM restart.
- **The VM is frozen and macOS's shortcuts are gone** (⌘Tab, ⌘Space and
  ⌥⌘Esc do nothing; only with the experimental `macShortcuts` false): a VM
  stopped as a whole (all of QEMU stuck, or paused by a debugger) keeps
  them off, and no other app can turn them on for it. Quit that VM: right-
  click OmacVM in the Dock, hold Option, choose Force Quit (or Activity
  Monitor › OmacVM › Force Quit; Activity Monitor opens from Finder ›
  Applications › Utilities). The shortcuts work again at once. From the
  Terminal: `pkill -9 -f 'Contents/(MacOS/OmacVM-VM|Resources/runtime/bin/OmacVM) '`.
- **⌃⌥ Esc showed "macOS did not switch the Space"**: neither macOS's "Move
  left/right a space" shortcut nor the swipe after it moved the Space (the
  VM stays full screen; Mission Control only opens when you press the combo
  twice). Check that the shortcuts are
  on in System Settings › Keyboard › Keyboard Shortcuts › Mission Control;
  a trackpad swipe works meanwhile. The Gestures log
  (`~/Library/Logs/omacvm-gestures.log`) says what happened ("escape combo:
  ..."); please send those lines.
- **Brightness keys do nothing with the VM in front**: OmacVM Bridge reads
  them from the keyboard and needs Input Monitoring (System Settings › Privacy
  & Security › Input Monitoring › OmacVM Bridge). Its log says
  "brightness keys: reading them from the keyboard" when it can.
- **A mouse scrolls on after the wheel stops, or jumps**: scroll momentum is
  for trackpads only and passes every mouse's scrolling one to one; this was
  a smooth-scrolling mouse (Logitech MX and co.) taken as a trackpad before
  2.9.1. Update the Mac's helpers (`omacvm update`).
- **Omarchy's bar shows Wi-Fi without its name**: OmacVM Bridge has no
  Location Services permission (macOS needs it for the network's name). The
  bar still shows connected from the Mac's link. Allow it in System
  Settings › Privacy & Security › Location Services › OmacVM Bridge.
- **Permissions asked again after updating to 2.9.0**: OmacVM Bridge and
  OmacVM Gestures now come signed with OmacVM's Developer ID, which macOS
  treats as a new app once. Turn them on again in System Settings › Privacy &
  Security (Accessibility, Input Monitoring); an older entry of the same name
  can go (select it, −). Later updates keep the permissions.
- **Volume keys show macOS's greyed-out panel**: the output has no volume
  macOS can set (an audio interface). With the VM in front the keys
  change the VM's own volume instead. A VM
  OmacVM did not set up may need `omacvm update --vm NAME` once: the Mac lets in
  only VMs whose trackpad daemon says the Bridge's token.
- **The brightness keys do not change the external display**: the VM must be
  in front on it. `omacvm check`
  lists each external display: "not settable" means it does not take DDC/CI
  on this connection. Switch DDC/CI on in the display's own menu, or try
  another port: some Macs' built-in HDMI ports (M1/M2 Mac mini) and some docks
  pass no DDC/CI (USB-C or DisplayPort usually do). A display that was asleep
  when the Bridge looked is asked again after a minute (by the keys, the VM
  or `omacvm check`), at most three times, or when displays change. On the
  Mac's own HDMI port the Bridge sends no DDC/CI at all (3.1.17, #433: a
  display behind an HDMI to DisplayPort adapter went black at the Bridge's
  first read); `omacvm check` says so.
- **An external display went black or vanished when the Bridge started**
  (3.1.16 and before, on the Mac's HDMI port): replug it, then update. Until
  then, `omacvm disable external-brightness --vm NAME` stops all DDC/CI.
- **The VM does not lock again after an unlock** (Omarchy 4.0 VMs; the lock
  key and the idle lock do nothing): Omarchy's bug with Quickshell 0.3.2
  (omarchy-mac 4.0.x,
  [omacom/omarchy-mac#738](https://github.com/omacom/omarchy-mac/issues/738);
  an open fix: omacom/omarchy-mac#752). It happens after every unlock. A
  restart of Omarchy's shell brings the lock back for the next lock only:
  after each unlock, run `omarchy-restart-shell` in a terminal (the bar
  redraws once). OmacVM VMs have the idle lock on by default, so an idle VM
  stays open while it is stuck. `omacvm check` warns while it is stuck
  ("Omarchy's lock").
- **The lock screen has no password field after an update of a locked VM**
  (`omacvm update` or `omacvm apply` on a running VM whose screen was
  locked, 3.2.12 and older): typing the password does nothing. Shut the VM
  down and start it again. From 3.2.13 such an update waits for the unlock
  (46).
- **Touch ID asks for the password instead**: the line above the password
  prompt says why ("Touch ID not available (VM not in front), use your
  password", "the Mac is still starting: try again in a moment", ...).
  Nothing there means you cancelled on the Mac, or it does not ask here at
  all (over SSH, or a program without a terminal). `omacvm check` has a
  "Touch ID (Mac)" line (the VM's key, OmacVM Bridge, a fingerprint) and, in
  the VM, "Touch ID last request"; `journalctl -t omacvm-touchid` in the VM
  lists each request. 1Password asks for its own password until its
  Settings › Security › Unlock using system authentication is on, and once
  after it starts.
- **"answers with another SSH host key"**: OmacVM remembers each VM's SSH key.
  After rebuilding or reinstalling the VM: `omacvm apply --vm NAME --reset-host-key`.
- **"has OmacVM 3.0.3, this omacvm is 2.9.1 ... does not go back"**: the
  `omacvm` Terminal runs is older than the VM's OmacVM, usually an old
  command line install (`~/.omacvm`) first on the PATH beside a newer
  OmacVM.app (`omacvm --version` says so too). Nothing was changed. Run the
  app's own (`~/Applications/OmacVM.app/Contents/Resources/omacvm/omacvm`,
  or its "omacvm in Terminal" link), or bring the old one up to date with
  `omacvm update` (from 3.0.9 it follows the releases; an install from
  before that which says "already up to date": run the install command at
  the top of the README again, #291). `--allow-downgrade` takes the VM back
  on purpose.
- **Scrolling feels too fast or slow in one app**: Chromium-based apps get their
  own factor; tell us the app (window class from `hyprctl clients`) in an
  issue. The scroll momentum's settings are in `src/gestures/guest/omacvm-gestures`
  (`OMACVM_GLIDE_*`).

## Findings

| # | Finding |
|---|---|
| 9 | [A swipe jumps to the next workspace when the fingers lift](#9-a-swipe-jumps-when-the-fingers-lift) |
| 10 | [The Mac's pointer hides over the VM app's other windows](#10-the-macs-pointer-hides-over-the-vm-apps-other-windows) |
| 18 | [No snapshots in GRUB with Arch Linux ARM's own kernel](#18-no-snapshots-in-grub-with-arch-linux-arms-own-kernel) |
| 19 | [Two VMs in one app both get the swipes and Cmd shortcuts](#19-two-vms-in-one-app-both-get-the-swipes-and-cmd-shortcuts) |
| 22 | [The microphone records nothing, or silence](#22-app-the-microphone-records-nothing-or-silence) |
| 23 | [Chrome hangs in Basemark Web 3.0, the screen flickers](#23-app-chrome-hangs-in-basemark-web-30-the-screen-flickers) |
| 24 | [A scale like 1.6 on a 5K display turns the VM black and flickering](#24-app-a-scale-like-16-on-a-5k-display-turns-the-vm-black-and-flickering) |
| 25 | [The sound crackles while the VM or the Mac is busy](#25-app-the-sound-crackles-while-the-vm-or-the-mac-is-busy) |
| 26 | [The VM does not start (no window), or freezes when sound starts](#26-app-the-vm-does-not-start-no-window-or-freezes-when-sound-starts) |
| 29 | [No sound at all after a start](#29-app-no-sound-at-all-after-a-start) |

Findings 11, 16 and 17 are notes for developers now:
[notes/findings.md](notes/findings.md). Findings 1-8, 12-15, 20 and 21
were about Parallels, UTM and VMware Fusion, retired in 3.4.0; they are in
[v3.3.0's copy](https://github.com/gillesgoetsch/OmacVM/blob/v3.3.0/docs/troubleshooting.md).

<a name="9-all-routes-a-swipe-jumps-when-the-fingers-lift"></a>

## 9. A swipe jumps when the fingers lift

- **Symptom:** a three-finger swipe moves nothing while the fingers move, then
  the next workspace appears at once when they lift.
- **Cause:** Omarchy turns Hyprland's workspace animation off.
- **Fix:** with trackpad gestures on, OmacVM adds a slide animation for
  workspaces, like macOS Spaces, unless you already set a `workspaces`
  animation yourself.
- **Where:** `src/gestures/guest/install.sh`, writes to
  `~/.config/hypr/input.lua`.

<a name="10-all-routes-the-macs-pointer-hides-over-the-vm-apps-other-windows"></a>

## 10. The Mac's pointer hides over the VM app's other windows

- **Symptom:** the Mac's pointer disappears over any window of the VM app, for
  example the app's own settings window, not only over the full-screen VM.
- **Cause:** OmacVM Gestures hid the pointer over every window of the VM app.
- **Fix:** it now hides the pointer only over a window that fills its display.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (the hit test: the window must
  cover the display's width, and its height minus the menu bar).

<a name="18-all-routes-no-snapshots-in-grub-with-arch-linux-arms-own-kernel"></a>

## 18. No snapshots in GRUB with Arch Linux ARM's own kernel

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

<a name="19-all-routes-two-vms-in-one-app-both-get-the-swipes-and-cmd-shortcuts"></a>

## 19. Two VMs in one app both get the swipes and Cmd shortcuts

- **Symptom:** with two OmacVM VMs running, a Cmd shortcut in the
  full-screen one (Super+Return, Super+W) also reaches the other, and so do
  swipes and scrolling.
- **Cause:** OmacVM Gestures knew which app is in front, not which of its
  VMs. It sent keys and touches to every VM connected from that app's
  network (`sendTo(frontNet, …)`).
- **Fix:** `omacvm apply` gives the VM its name (`OMACVM_VM_NAME_B64` in
  `/etc/omacvm/env`), the guest daemon says it in its hello, and the helper
  reads the title of the app's front window through Accessibility (on every
  app switch and on its 0.2 s check while the app is full screen in front).
  Frames, keys and the capture state go only to the VM whose name is in the
  title (OmacVM.app's window title is the VM's name); switching VMs sends
  `S off` to the old one and `S on` to the new one. A VM set up before this
  (no name in its hello) or renamed since its last `omacvm apply` matches no
  title: then every VM gets them, as before; run `omacvm update`.
- **Where:** `src/gestures/mac/omacvm-gestures.c` (`pickTargets`,
  `windowTitle`), `src/gestures/guest/omacvm-gestures` (hello),
  `src/guest/install.sh` (`--vm-name-b64`), `src/cmd/apply.sh`.

<a name="22-parallels-fusion-app-the-microphone-records-nothing-or-silence"></a>

## 22. app: the microphone records nothing, or silence

- **Symptom:** PipeWire lists the input, but a recording is empty:
  `pw-record` gets no samples at all (`/proc/asound/card0/pcm0c/sub0/status`:
  `hw_ptr 0`). Before 2.6.0's fix the whole VM also stopped when the
  recording started.
- **Cause:** macOS's microphone permission for the app that records on the
  Mac. OmacVM.app's QEMU is a helper that cannot ask for it itself: its
  `AudioQueueStart` fails with 268451843, and `logs/qemu.log` says
  `SDL_OpenAudioDevice for recording failed: CoreAudio error
  (AudioQueueStart): 268451843`. 268451843 is 0x10004003,
  `MACH_RCV_TIMED_OUT`: coreaudiod did not answer `AudioQueueStart`
  (`_TellServerAboutStreamUsage`) in time. Why the VM stopped: QEMU opened
  the recording on a vCPU thread that holds its global lock (`sample` showed
  `sdl_open` under `intel_hda_set_st_ctl`), so the whole VM waited with it.
- **Fix:** the app asks for the microphone when it starts a VM, and QEMU
  records under its grant; the Developer ID build has the `audio-input`
  entitlement for that. Without the permission the app starts QEMU without
  recording (`in.voices=0`, and a line in `qemu.log`); allow it, then
  restart the VM. macOS counts QEMU's recording as the app's (tccd:
  microphone for `org.omacvm.app`, allowed), and with the grant
  `AudioQueueStart` answers in well under a second. QEMU starts and stops
  the recording on a thread of its own
  (`qemu-sdl-audio-capture-thread.patch`): the VM keeps running whatever
  CoreAudio does, records silence until the microphone runs, and logs
  `SDL recording device did not start within 5 seconds` when it is slow (a
  sound that starts meanwhile waits for it). `omacvm check` reads the app's
  log for the refusal (and says to restart).
- **Where:** `app/app/Sources/OmacVM/Runner.swift`, `app/app/OmacVM.entitlements`,
  `app/runtime/patches/qemu-sdl-audio-capture-thread.patch`, `src/cmd/check.sh`.

## 23. app: Chrome hangs in Basemark Web 3.0, the screen flickers

- **Symptom:** in OmacVM.app (2.6.0), Basemark Web 3.0 in Google Chrome
  stops at test 5 of 20, the page flickers and no score comes, even after
  15 minutes. It finishes on the Mac and in other VM apps. WebGL
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

## 24. app: a scale like 1.6 on a 5K display turns the VM black and flickering

- **Symptom:** in OmacVM.app 2.9.0 on a Mac mini (16 GB) with an LG
  UltraFine 5K, picking 1.6 in Omarchy's scale menu made the screen freeze
  and flicker, then the VM stayed black. Setting the scale back did not bring
  the picture back; restarting the VM did, and 1.6 then worked.
- **Cause:** the VM's GPU memory on the Mac has a budget, so a runaway VM
  cannot fill the Mac's memory. 2.9.0 set it to a quarter of the Mac's
  memory: 4 GB on 16 GB. A 5K desktop takes about 1.2 GB, with a browser
  open 1.6 to 1.9 GB, and more with more apps. A scale change makes every
  screen-sized buffer again (Hyprland's and every app's, 56 to 90 MB each at
  5K), so for a moment old and new ones both count. The VM reached the
  budget, the Mac refused Hyprland's next buffer, and Hyprland's GPU context
  was lost: `logs/qemu.log` says `guest GPU memory budget of 4096 MB
  reached`, then `context ... (Hyprland) is lost`. It was not a loop and not
  a leak: switching between 1.6 and 2 sixteen times leaves the same memory
  in use each time, and a 35-minute session with 149 scale changes and 50
  browser windows came back to where it started. The refused 8192-wide
  buffer was most likely Omarchy's bar (quickshell): for one frame after
  a scale change it draws the new size at the old scale (8192×4608 from
  1.6 to 1 at 5K). A desktop with more apps open than in our tests (each
  browser window at 5K holds a few buffers of 30 to 90 MB) plus that
  moment explains the 3993 MB in use.
- **Fix:** no fixed limit any more. The VM's graphics memory grows as
  long as macOS has memory to give; new big buffers are refused only when
  macOS has no room for them: bigger than what it has left while it warns,
  and while it is critical also past a grace of growth since critical began
  (`app/runtime/patches/virgl-darwin-memory-pressure.patch`,
  `virgl-gpu-guard-critical-grace.patch` from 3.2.15). The one
  fixed guard, three quarters of the Mac's memory, only stops a runaway VM,
  and its last part is kept for the desktop: on an 8 GB Mac a browser could
  fill the guard while macOS still said normal, and the next buffer refused
  was Hyprland's. Now the app past its share loses its own GPU context and
  the VM says so (3.0.5, `app/runtime/patches/virgl-gpu-guard-desktop-reserve.patch`).
  If the desktop still loses its GPU context, the app says so and offers to
  restart the desktop session instead of leaving the VM black.
  `omacvm check` shows the graphics memory now and its peak ("graphics
  memory"); the app shows it beside the VM memory
  ([what the two are](routes/app.md#graphics-memory-and-vm-memory)). The display sync also sends a
  mode only when Hyprland shows another, one call at a time, and stops
  following an output that keeps changing (6 times in 10 s between two
  states, or 12 times at all) for a minute; the VM's `omacvm check` says so
  ("display sync"). On a 4K or larger display, Omarchy's display panel
  says 2x is the sharp scale. What in-between scales cost:
  [routes/app.md](routes/app.md#display-scale-on-4k-5k-and-larger-displays).
- **Where:** `app/runtime/patches/virgl-resource-memory-budget.patch`,
  `app/runtime/patches/virgl-darwin-memory-pressure.patch`,
  `app/app/Sources/OmacVM/GPUMemory.swift`,
  `src/app/guest/omacvm-display-sync` (tests:
  `src/app/guest/tests/test_display_sync.py`),
  `src/app/guest/monitor-widget/build.py`, `src/cmd/check.sh`,
  `src/guest/check.sh`, `tests/graphics/fractional-scale.sh` (every scale in
  a running VM).

## 25. app: the sound crackles while the VM or the Mac is busy

- **Symptom:** music in the VM (Spotify, a browser) crackles or drops out
  for a moment while the VM works hard and you move around in it: opening
  apps, scrolling, a compile. Seen on a Mac mini M4 (10 cores) with the VM
  at 8 CPUs.
- **Cause:** QEMU moves the sound in its main loop (the HDA's DMA timer and
  the 1 ms audio timer), the same thread that runs the VM's GPU (virgl).
  Up to 2.9.1 that thread ran at the default QoS, on equal terms with the
  VM's CPUs and the Mac's own work; with the cores busy it ran 10-50 ms late
  thousands of times in 10 minutes and up to 200 ms late now and then. New
  shaders (an app's first frames) stop it for 50-80 ms by themselves. QEMU's
  own buffer kept the Mac playing, but afterwards the sound card took the
  whole missed time from the VM at once, so the VM's PipeWire ran out (an
  xrun).
- **Fix:** from 3.0.0 QEMU's main loop runs at user-interactive QoS
  (`app/runtime/patches/qemu-darwin-main-loop-qos.patch`) and the sound card
  no longer catches up after a stall (`qemu-hda-no-catch-up.patch`: the VM's
  sound clock pauses instead). Measured on a MacBook Pro M4 Max, VM with 8
  CPUs, a 30 Hz tone in the VM, 10 minutes each, breaks in the tone:
  - the VM's GPU busy (glmark2, a new scene every 10 s), 8 busy threads on
    the Mac: 12 (2.9.0) → 2;
  - the VM's CPUs busy too: median 365 (2.9.0, 4 runs) → 120 (QoS only,
    5 runs) → 50 (both, 4 runs); the main loop 10-49 ms late 2,261-4,752
    times per run → 1-9.

  The rest are the VM's own apps starved of CPU at 100 % load. The sound's
  delay stays the same (round trip in the VM about 282 ms).
  `omacvm check` shows both ("sound timing");
  `defaults write org.omacvm.app audioClassic -bool true` goes back to
  2.9.1's timing.
- **In the VM (3.0.1):** PipeWire's sound threads run real-time through
  RTKit, so a busy VM does not starve them. But RTKit's watchdog (its
  "canary") takes 10 seconds in which the VM's threads did not run while
  its clock went on for a runaway real-time thread, and demotes every one
  of them for the rest of the session (`journalctl -u rtkit-daemon`: "The
  canary thread is apparently starving"). Seen when QEMU itself was
  stopped (`kill -STOP` for 15 s, as test locks do; once in a test VM's
  history); the app's own pause keeps the VM's clock and does not do it. PipeWire then runs at normal priority, and the
  sound can break when the VM is busy. Measured on a Mac mini M4, VM with
  8 CPUs, its CPUs and GPU busy and 2 busy threads on the Mac, 5 minutes
  each, breaks in a test tone: real-time PipeWire 2, 6, 2, 0 (guest xruns
  0-4); demoted 81 (22 / 68 xruns, the mini also busy with two builds) and
  0 (mini less busy). In the VM, systemd's slices already give PipeWire its
  share of the CPUs; real-time matters when the VM's CPUs get less time
  from a busy Mac. From 3.0.1 `omacvm apply` runs
  RTKit without the watchdog (`src/guest/sound/rtkit-no-canary.conf`;
  RTKit's other limits stay), and `omacvm check` shows "sound priority".
  By hand: `systemctl --user restart pipewire pipewire-pulse wireplumber`
  makes PipeWire real-time again until the next stop.
- **3.1.16 (experimental), on by default from 3.1.17:** the sound card's
  DMA and the mixer on a thread of their own at real-time priority (macOS's
  time-constraint policy), not in QEMU's main loop. The VM window's
  Output › Sound on its own thread switches it (3.1.17), or
  `defaults write org.omacvm.app audioThread -bool false` (or `true`), then
  restart the VM. Measured on
  the Mac mini M4 (VM with 8 CPUs, a 30 Hz tone, 4 minutes each), the
  main loop's path stopped the sound card whenever the VM's graphics held
  that loop (100-350 ms while Chromium opened a window or scrolled), and
  QEMU's ring ran dry. On its own thread the sound card is never more than
  a few ms late, so QEMU's ring is 32 ms at 48 kHz instead of 93 ms at
  44.1 kHz: the round trip in the VM goes from 272 to 209 ms, and the app
  tells the VM the shorter delay for videos. Breaks: browsing while music
  plays 0, 0, 0, 0, 2 (5, 14, 0, 0 before), the Mac busy 0 in 4 runs (12,
  0, 0 before). With the VM's GPU busy (glmark2) about the same (own thread 8,
  4, 13; main loop 7, 4, 18), and worse in one run with everything busy at
  once (13; main loop 4):
  while the main loop holds the BQL, vCPUs that leave the guest wait for
  it, and the guest's own buffers have to cover that, which are shorter
  than QEMU's old ring. `omacvm check` "sound timing" says "sound card and
  mixer on their own real-time thread". What is left in every path: a Mac
  so busy that the VM's own threads get no time (a build on every core:
  the guest stopped for up to 150 ms) breaks the guest's streams. ADR 0045.
- **For 2.9.0 and 2.9.1:** a bigger safety buffer in the VM. As root in
  the VM (USER = your user):

  ```
  mkdir -p /etc/wireplumber/wireplumber.conf.d
  printf '%s\n' 'monitor.alsa.rules = [ { matches = [ { node.name = "~alsa_output.*" } ] actions = { update-props = { api.alsa.headroom = 8192 } } } ]' \
    > /etc/wireplumber/wireplumber.conf.d/90-omacvm-audio-headroom.conf
  systemctl --user -M USER@ restart wireplumber
  ```

  Same test on 2.9.0: 337 → 15 breaks in 10 minutes, xruns 234 → 1. It adds
  128 ms to the sound's delay (round trip in the VM 275 → 400 ms). Remove the
  file and restart WirePlumber to undo; 3.0.0 does not need it. (2.9.1 has
  the same sound path as 2.9.0.)
- **Where:** `app/runtime/patches/qemu-darwin-main-loop-qos.patch`,
  `app/runtime/patches/qemu-hda-no-catch-up.patch`,
  `app/runtime/patches/qemu-audio-own-thread.patch` (3.1.16, `audioThread`;
  `AudioPath.swift`, `AudioDelay.qemuThreadMs`),
  `app/app/Sources/OmacVM/Runner.swift` (`audioClassic`), `src/cmd/check.sh`,
  the measurement tools in `app/runtime/Tests/audio/`, ADR 0036 and 0045; in the
  VM `src/guest/sound/rtkit-no-canary.conf`, `src/guest/install.sh`,
  `src/guest/check.sh` ("sound priority").

## 26. app: the VM does not start (no window), or freezes when sound starts

- **Symptom:** OmacVM.app starts the VM but no window comes, the VM never
  boots and the app cannot reach it; or a running VM freezes the moment it
  plays a sound. Other apps on the Mac play no sound either, or `afplay`
  hangs. Seen on a Mac mini M4 with a USB audio interface (Scarlett 2i2) as
  the output, coreaudiod up for 7 days.
- **Cause:** the Mac's audio device did not answer: every `AudioQueueStart`
  blocked. Up to 2.9.1 QEMU opened the sound device in its main thread (at
  the start, and again whenever the VM starts a sound), and SDL waits for
  the device without a time limit, so QEMU waited for good.
- **Fix:** from 3.0.0 QEMU opens and closes the Mac's sound device on a
  thread of its own (`app/runtime/patches/qemu-sdl-audio-playback-thread.patch`).
  If it has not opened within 3 s the VM runs without sound, `qemu.log` says
  "the Mac's audio device does not answer" and `omacvm check` warns
  ("sound"). Sound comes back by itself once the device answers. To get it
  answering: pick another output in System Settings > Sound, replug the
  device, or `sudo killall coreaudiod` (macOS restarts it).
- **For 2.9.0 and 2.9.1:** the same fixes for the device, then start the VM
  again (quit the app first if it hangs). To start without sound meanwhile:
  `launchctl setenv SDL_AUDIO_DRIVER dummy`, reopen the app, and
  `launchctl unsetenv SDL_AUDIO_DRIVER` afterwards.
- **Where:** `app/runtime/patches/qemu-sdl-audio-playback-thread.patch`,
  `src/cmd/check.sh`, the test stub
  `app/runtime/Tests/audio/wedged-output-start.c`.

<a name="27-all-routes-black-screen-after-an-update-or-an-omacvm-job"></a>

## 27. Black screen after an update or an OmacVM job

- **Symptom:** the VM starts to a black screen (no login screen, no desktop);
  over SSH, `journalctl -b | grep -i gbm` shows Hyprland's
  `Couldn't open a GBM device` / `Cannot create a GBM Allocator` /
  `Cannot open backend: no allocator available`.
- **Cause:** a partial update. Mesa was updated on its own, without the
  libraries it was built for. Arch Linux ARM's Mesa 26.2.4 needs LLVM 23
  (`libLLVM.so.23.1`); next to LLVM 22 its GBM backend cannot load, so
  Hyprland stops. Seen 2026-10-06: a `pacman -Sy` (a newer package list, no
  update) and then OmacVM's `pacman -S --needed ... mesa` (Chromium video)
  updated Mesa alone. Mesa 26.2.4 itself is fine: a full update (Mesa and
  LLVM together) starts the desktop.
- **Fix (3.0.0):** OmacVM installs only packages the VM does not have and
  never updates one it has (`src/guest/pkg-add`); when an install would
  update others, it stops and says to update the whole system first. It no
  longer runs `pacman -Sy`. Every guest install checks at the end that GBM
  still opens and, if this install broke it, puts the changed packages back
  from pacman's cache (`src/guest/gbm-guard`). The Vulkan (Venus) driver
  check runs only when the VM's Graphics gives it Vulkan.
- **Recover a VM that already shows the black screen:** SSH in (or
  Ctrl+Alt+F3 for a text console) as root, then either
  1. update the whole system, which brings the matching LLVM:
     `pacman -Syu` (Omarchy's `omarchy update` does the same and more), or
  2. go back to the Mesa from before:
     `pacman -U /var/cache/pacman/pkg/mesa-<old version>-aarch64.pkg.tar.*`
     (`grep 'upgraded mesa' /var/log/pacman.log` names it).
  Then `/usr/local/share/omacvm/guest/gbm-guard test` must say "GBM opens";
  `systemctl restart sddm` (or restart the VM) brings the desktop back. Do
  not pin Mesa with `IgnorePkg`: the next `omarchy update` then brings LLVM
  23 and keeps the old Mesa, which needs LLVM 22 (`libLLVM.so.22.1`): the
  same black screen. If you pinned it, remove the pin in the same sitting
  as the full update.
- **3.0.1:** Graphics -> Vulkan on a VM whose package list is older than
  the mirrors (a prebuilt VM a day later) runs the whole update first
  (`src/guest/system-update`: `omarchy update -y` as the desktop user, then
  `gbm-guard test`), never `pacman -Sy` alone. `omacvm graphics` asks first
  (the control centre asks in its own dialog). `omacvm apply` runs it only
  once, for a VM fresh from a prebuilt image (`src/prebuilt/guest/first-update`,
  3.1.25), before any feature installs a package. An update that shows
  nothing new for 10 minutes or runs over 40 is stopped.
- **Where:** `src/guest/pkg-add`, `src/guest/gbm-guard`,
  `src/guest/system-update`, `src/guest/install.sh` (runs both),
  `src/tests/pkg-safe.sh`.

## 28. app: the sound is late in videos (YouTube looks out of sync)

- **Symptom:** in a video in the VM (YouTube in Chromium, a film in mpv)
  the sound comes a bit after the picture: lips move before the words.
  Worse with AirPods or other Bluetooth headphones.
- **Cause:** players hold the picture back by the sound delay the system
  tells them. In the VM, PipeWire only knows the VM's own buffers. After
  the VM's sound card come QEMU's buffers (110-150 ms: the card's buffer,
  QEMU's ring, SDL's queue; the fill moves from run to run) and the Mac's
  output device (about 13 ms wired, about 170 ms for AirPods), and nothing
  told the VM about them. Not new in 3.0.0: with `audioClassic` (the old
  sound timing) the sound was as late. After the VM stalls (heavy GPU
  load) the sound comes up to the stall's length earlier for a few seconds,
  then back.
- **Fix (3.0.2):** the app works out that delay (QEMU's part plus what
  CoreAudio says about the Mac's default output) and sends it to the VM at
  the start and whenever the output changes. In the VM,
  `omacvm-audio-latency` sets it as PipeWire's latency offset on the sound
  card's output (pavucontrol shows it under Output Devices, "Latency
  offset"); Chromium, Firefox and mpv then wait with the picture.
  `qemu.log` says what was sent ("OmacVM: sound delay for the VM: ...");
  in the VM `omacvm-audio-latency --show` says what is set.
- **Still off a little?** `defaults write org.omacvm.app audioDelayExtraMs
  -int N` (ms, -500 to 500): negative when the sound now comes early,
  positive when it is still late; it applies at the next VM start or output
  change.
- **Where:** `app/app/Sources/OmacVMAudio/AudioDelay.swift`,
  `app/app/Sources/OmacVM/AudioLatencyWatch.swift`,
  `src/app/guest/omacvm-audio-latency`, the measurement tools in
  `app/runtime/Tests/av-sync/`.

## 29. app: no sound at all after a start

- **Symptom:** in an OmacVM.app VM with Chromium video on, every app is
  silent after a start; the sound card is there (`wpctl status` lists it)
  but players are not linked to it. `systemctl --user restart wireplumber`
  brings the sound back. The user journal has
  `spa.v4l2: Cannot open '/dev/video0': 19, No such device`.
- **Cause:** Chromium's video decoder (`omacvm-vdec`, a V4L2 device) opens
  only while `omacvm-vdecd` is ready. When WirePlumber meets the decoder
  before that (the module loaded while the desktop runs, as `omacvm apply`
  does, or WirePlumber starting while the daemon still waits for the GPU)
  WirePlumber 0.5 tries to open it as a camera, fails, and its event queue
  waits forever for that device: nothing is linked any more. A kernel
  update alone does not cause it: DKMS builds the module during the update
  and it loads early at the next start, before the daemon and WirePlumber.
- **Fix (3.0.4):** a WirePlumber rule leaves the decoder alone
  (`/etc/wireplumber/wireplumber.conf.d/50-omacvm-vdec.conf`; the journal
  says "V4L2 device v4l2_device.platform-omacvm-vdec disabled"). Chromium
  opens the decoder itself, not through PipeWire. Older VMs: `omacvm apply`
  (it restarts WirePlumber once, not while a call or a recording runs:
  then the rule counts from the next login). The decoder now also starts
  `omacvm-vdecd` when it comes late, which stayed down until the next
  start before (Chromium decoded on the CPU).
- **Where:** `src/vdec/guest/50-omacvm-vdec.conf`,
  `src/vdec/guest/70-omacvm-vdec.rules`, `src/vdec/guest/install.sh`,
  `src/tests/vdec-wireplumber.sh` (`--vm NAME` checks a running VM).

## 30. app: the drive with the VMs drops off while a VM runs

- **Symptom:** the VMs folder is on an external drive (an SD card, a USB
  SSD) and the drive goes away while a VM runs: unplugged, a loose cable,
  a USB link that resets ("I/O error ... terminateDevice" in the Mac's
  log), or ejected by force. Up to 3.0.4 the VM froze or showed disk
  errors in Omarchy and the app said nothing.
- **Cause:** the VM's disk is a file on that drive. Once the drive is gone,
  QEMU's open files fail and nothing it writes lands anywhere; QEMU itself
  kept running. If the app itself was on that drive too, macOS ends it at
  once ("quit unexpectedly"): it can no longer read its own code.
- **Fix (3.0.5):** the app watches the drive of a running VM (the VM
  folder's file system is unmounted, macOS's unmount notice, or a check
  every 2 s). When it goes, QEMU stops the VM and quits (forced after 5 s),
  and the window shows the VM as unavailable: "The drive with your VMs
  (NAME) is gone. Reconnect it and start the VM again." Plug the drive in
  and the VM is ready again; start it. What the VM had not written to its
  disk is lost, as at a power cut (btrfs starts from its last consistent state).
  Keep OmacVM.app itself on the Mac's own disk.
- **Where:** `app/app/Sources/OmacVM/DriveWatch.swift`, `Runner.driveLost`,
  `AppState.drivesChanged` and `UnavailableView`; test
  `src/tests/app-drive-drop.sh`.

## 31. app: the VM crawls while its window is out of sight

- **Symptom:** a job in the VM (a build, a download, an update) almost
  stops while the Mac's screen is locked, the VM's full screen is on
  another Space, or its window is minimized or covered; it runs at full
  speed again once the window shows. Up to 3.0.5.
- **Cause:** App Nap. macOS slows an app none of whose windows can be seen:
  every QEMU thread, the vCPUs too, drops to background priority. Measured
  on an M4 Max with the screen locked, 4 busy vCPUs: 2-20 % of the speed
  (10-100 instead of ~550 million loops/s in the VM).
- **Fix (3.0.6):** QEMU's window process tells macOS the VM is working
  (an `NSProcessInfo` activity that still lets the idle Mac sleep), so it
  is never napped. QEMU's log says "OmacVM: App Nap: off while the VM runs".
  `OMACVM_APP_NAP=1` in QEMU's environment allows App Nap again (tests).
  Before: keep the VM's window visible while a job runs.
- **Where:** `app/runtime/patches/omacvm-cocoa-no-app-nap.patch`; test
  `src/tests/app-nap.sh` (`--live PID` checks a running VM's vCPU threads).

## 32. app: the VM lags and the sound crackles while recording the screen or taking a screenshot

- **Symptom:** in Omarchy's capture mode (a screenshot of a region or a
  window, screen recording) the VM gets slow and the sound crackles or drops
  out; worst while recording, and on 120 Hz or several displays. Up to 3.0.5.
- **Cause:** two kinds of work stopped QEMU's main loop, which also runs the
  VM's sound and display. Recording: each frame waited 12-13 ms in the Mac's
  video encoder (constant QP used VideoToolbox's low-latency session): the
  main loop was busy 93 % of the time, the display ran at 12 frames a second
  and the Mac got a third of the sound (MacBook Air M2, 2940x1840). The
  frozen screen of the screenshot picker: hyprpicker drew every display again
  on every frame, and each time Hyprland sent the whole screen (21.6 MB)
  through the GPU's upload path.
- **Fix (3.0.8):** the encoder works beside the main loop; the VM's fences
  wait for its frames instead (ADR
  [0042](adr/0042-encoder-beside-the-main-loop.md)): recording keeps the
  sound whole, the display at 29 frames a second. OmacVM.app VMs get a
  hyprpicker that draws only when something changed (`omacvm apply` builds
  it; `omacvm check` shows "screenshot freeze"), and big uploads take half
  the main loop's time. Numbers: [video-encode.md](video-encode.md#while-recording).
- **Where:** `app/runtime/patches/virgl-videotoolbox-encode-async.patch`,
  `virgl-transfer-upload-pbo.patch`, `src/app/guest/hyprpicker/`; tests
  `app/runtime/Tests/virgl/test-video-encode.c`, `test-upload-pbo.c`.

## 33. app: Mac input methods (experimental): keys arrive as plain letters, or the candidate window is in the wrong place

- **Symptom:** with `mac-ime` on and an input method (Pinyin, Kotoeri,
  2-Set Korean) selected on the Mac, typing in a text field in Omarchy
  gives plain letters and no candidate window; or the candidate window
  shows at the bottom left of the window instead of at the text cursor.
- **Cause and fix:**
  - Plain letters right after `omacvm enable mac-ime`: the port comes with
    the VM's next start. Shut the VM down and start it again;
    `omacvm check --vm NAME` says "on from the VM's next start" until then.
  - Plain letters after an update of the VM's Fcitx5: the module must be
    built for it. `omacvm apply --vm NAME` builds it again; the check says
    "built for Fcitx5 X, the VM has Y".
  - Plain letters in one app only: it does not reach an input method. GTK
    apps need the GTK line from the next login (log out and in once);
    Chromium and Electron apps need `--enable-wayland-ime`, which OmacVM
    adds to `~/.config/chromium-flags.conf` and `electron-flags.conf` when
    the files exist (restart the app).
  - Plain letters in a password field: on purpose.
  - The candidate window at the window's corner: the app does not tell the
    input method where its cursor is (Chromium, Electron, foot, alacritty,
    XWayland apps). Click into the field first: the window then opens at
    the click. Qt and GTK apps and kitty give the cursor.
- **Where:** `src/ime/guest/` (the Fcitx5 module, its VM step),
  `app/runtime/patches/omacvm-cocoa-ime.patch`; QEMU's log
  (`logs/qemu.log` in the VM folder) has "cocoa: mac-ime: ..." lines, the
  VM's Fcitx5 log `journalctl --user -u omarchy-fcitx5` has "omacvm-ime"
  lines.

## 34. app: Keyboard sharing apps: the VM takes the keys meant for the other computer

- **Symptom:** with a keyboard and mouse sharing app on the Mac (Synergy,
  Deskflow, Barrier, Input Leap) and an OmacVM.app VM running, the pointer
  moves to the other computer but the keys still go to the VM. The mouse
  works. Starting the sharing app after the VM fixes it until the next VM
  start.
- **Cause:** the order of macOS's event taps. QEMU's keyboard grab and the
  sharing app's tap both go to the front of macOS's input chain, and the
  newest tap runs first. A VM started after the sharing app sees the keys
  before it and keeps them. The mouse is not affected: QEMU's tap only
  takes keys.
- **Fix (off by default):** in the VM window's settings, Input, turn on
  **Keyboard sharing apps** (3.1.23; before that only in Terminal:
  `defaults write org.omacvm.app shareKeyboard -bool true`).

  Then restart the VM. OmacVM's taps (QEMU's, OmacVM Gestures', the
  Bridge's media keys) go to the end of the chain, so the sharing app sees
  the keys first. QEMU's log says "full-grab tap at the end of the event
  tap chain". To turn it off, switch it off again and restart the VM.
- **Limits:** trackpad gestures (swipes, the scroll momentum) still go to
  Omarchy while the pointer is on the other computer: OmacVM Gestures reads
  them from the trackpad itself, not from the tap.
- **Where:** `app/runtime/patches/omacvm-cocoa-keys-last.patch`
  (`OMACVM_KEYS_LAST=1`), `app/app/Sources/OmacVMFeatures/ShareKeyboard.swift`,
  `src/gestures/mac/omacvm-gestures.c` (`shareKeyboard`),
  `src/bridge/mac/keys-model.swift` (`ShareKeyboard`); tests
  `app/runtime/Tests/keys/test-keys-last.sh`, `swift run features-tests`,
  `src/gestures/mac/test.sh` (test-tap.c), `src/bridge/mac/test-models.sh`.
  Issue [#350](https://github.com/gillesgoetsch/OmacVM/issues/350).

<a name="35-all-routes-the-bar-menus-and-pop-ups-draw-empty-after-an-update-qt-612"></a>

## 35. The bar, menus and pop-ups draw empty after an update (Qt 6.12)

- **Symptom:** Omarchy's bar is an empty dark strip, Super+Space (the
  Omarchy menu) shows a blank screen until Escape, the volume OSD and
  notifications are empty or unthemed. The shell's log
  (`/run/user/1000/quickshell/by-pid/*/log.log`) has hundreds of
  `TypeError: Cannot read property 'border' of undefined` and
  `Unable to assign [undefined] to QColor` from the first start. A VM built
  from scratch since Arch's Qt 6.12 (2026-10-12) has it from the first boot;
  an older VM after `pacman -Syu` or `omarchy update`.
- **Cause:** Qt 6.12 brought a singleton named `Color` into QtQuick
  (`Color.rgba()`, `Color.lighter()`, ...). Omarchy's shell has its own
  `Color` (`qs.Commons`), and its files import both. With a plain
  `import QtQuick` (the newest version), a bare `Color` is QtQuick's,
  whatever the order of the imports, so every colour the shell reads
  (`Color.bar.text`, `Color.foreground`, ...) is undefined.
- **Fix (3.1.1):** `omacvm apply` (OmacVM.app: Update VM) imports QtQuick
  below 6.12 (`import QtQuick 6.11`, which leaves QtQuick's `Color` out) in
  each of Omarchy's shell files, and the user's clones of them, that use
  Omarchy's bare `Color`; the line is marked `// omacvm #376`. Nothing
  changes on Qt 6.11. Then the shell restarts (after the next unlock if the
  screen is locked). A pacman hook does it again after every Omarchy or Qt
  update (`omarchy update` restarts the shell at its end); a file Omarchy
  itself changed so that it no longer needs it is left alone. `omacvm check` has a "shell colours" row: it counts these
  errors in the running shell's log and says what to do. By hand, as root
  in the VM: `/usr/local/lib/omacvm/shell-colors.py` (`--status`,
  `--revert`), then `omarchy restart shell` as the desktop user.
- **Where:** `src/guest/shell-colors.py`, `src/guest/install.sh` (the step
  and the hook `/etc/pacman.d/hooks/zz-omacvm-shell-colors.hook`),
  `src/guest/check.sh` ("shell colours"); test `src/tests/shell-colors.sh`.
  OmacVM's own panels (Wi-Fi, sound, Bluetooth) use `Commons.Color`.
  Issue [#376](https://github.com/gillesgoetsch/OmacVM/issues/376).

## 36. app: black full-screen Spaces pile up after a display goes while the Mac is locked

- **Symptom:** the VM in full screen on two displays; the Mac locked, then
  one display unplugged (or, after the displays slept, one wakes up
  inactive for a few seconds). The Mac clicks fast, and after unlocking
  Mission Control shows a growing row of black full-screen Spaces until the
  VM quits. Up to 3.1.14.
- **Cause:** macOS reports such a change in steps (an unplugged or waking
  display shows up for a few seconds as inactive at 1 x 1) and moves the
  main window's full-screen Space while the displays settle. Each step went
  straight to the display update, inside AppKit's own window and screen
  notifications: the second display's window was made again, each new one
  asked for full screen in a new Space (the five tries were counted per
  window), and the old one was closed while macOS still moved it, so AppKit
  kept it and its Space.
- **Fix (3.1.15):** the VM's windows follow the displays from one timer once
  they settle (0.5 s after the last change), never inside the notification
  that asked, never while the screen is locked or the displays sleep (1 s
  after unlock or wake). A display that is inactive, asleep or under
  100 x 100 points counts as gone; one that comes back gets its window after
  2 s. Full screen is tried at most 4 times per monitor (also when its
  window is made again; a full screen that held 10 s starts over). QEMU's
  log says "display N: full screen for its window (try k of 4)" for each
  try, and "displays: no window changes while locked or asleep" while it
  waits. Before: quit the VM to stop it.
- **Where:** `app/runtime/patches/omacvm-cocoa-display-settle-logic.patch`
  (the rules, `ui/omacvm-display-settle.h`) and
  `omacvm-cocoa-display-settle.patch`; tests
  `app/runtime/Tests/display/test-display-settle.sh` and
  `src/tests/e2e/display-unplug.sh` (the head cases; `OMACVM_TEST_LOCK_HOOK=1`
  with `app/scripts/dev/test-lock.m` stands in for the lock).
  Issue [#428](https://github.com/gillesgoetsch/OmacVM/issues/428).

<a name="37-all-routes-files-deleted-in-the-vm-keep-their-space-on-the-mac"></a>

## 37. Files deleted in the VM keep their space on the Mac

- **Symptom:** you delete big files in Omarchy, but the VM's disk on the Mac
  (OmacVM.app: `disk.img`, the size in the window's Storage) does not get
  smaller.
- **Cause:** the space comes back by itself within about two minutes:
  btrfs discards what it frees (`discard=async`), QEMU punches it out of
  `disk.img`, and a trim at every Update VM and once a week
  (`fstrim.timer`) gets the rest. `disk.img` still grows up to the disk's
  set size. The space stays taken when:
  - an update snapshot still holds the files. Omarchy snapshots `/`
    before every `omarchy update`, so whatever you delete outside `/home`
    stays until that snapshot goes. omarchy-mac 4.0 keeps 5 (up to 3.1.24, 5
    updates); OmacVM now keeps the last 2.
  - Omarchy 4.0 VMs: `@factory`, omarchy-mac's factory-reset copy of the
    system as installed, still holds files that updates replaced. OmacVM
    leaves it, so the factory reset keeps working. Omarchy 4.5 VMs have none
    (the move to 4.5 removes it).
  - the VMs folder is on a Mac OS Extended drive (no sparse files: the disk
    takes its full size there), or another file shares the blocks: an APFS
    clone such as `disk-before-resize.img` during a resize, or a Finder
    duplicate.
- **Fix:** Update VM (or `omacvm apply`): 2 update snapshots instead of 5,
  the extra ones go once the VM side worked, then a trim (it waits up to a
  minute for btrfs to free them and for the trim to finish). `omacvm check` shows it as
  "freeing disk space". OmacVM changes omarchy-mac's 5 once; a number you
  set afterwards stays:
  `sudo snapper -c root set-config NUMBER_LIMIT=N NUMBER_LIMIT_IMPORTANT=N`.
  To free the space at once: `sudo snapper list`, then
  `sudo snapper delete N` for the snapshots you no longer need.
- **Where:** `src/guest/disk-space.sh` (run by `src/cmd/apply.sh`),
  `src/guest/check.sh`; test `src/tests/disk-space.sh`;
  [ADR 0048](adr/0048-freed-space-back-to-the-mac.md).

## 38. app: Update VM stops: the VM doesn't let this Mac in over SSH

- **Symptom:** Update VM stops in its first step. Up to 3.1.24 it waited 5
  minutes and said the VM "did not come up", although it had started. Now it
  says "... doesn't let this Mac in over SSH" and offers **Copy Command**.
  `omacvm apply` exits 3 with the same command.
- **Cause:** OmacVM reaches an app VM over SSH with a key kept in the VM's
  folder (`ssh-key`). A VM set up on another Mac, or before OmacVM 3.0.12,
  may know only that Mac's key (`~/.ssh/omacvm` there). Its SSH turns this
  Mac away.
- **Fix:** none needed in most cases: the app adds the folder's key in the
  VM through its guest agent, without SSH, at each start in the app and in
  Update VM (`logs/qemu.log`: "OmacVM: SSH: this VM folder's key added in the
  VM"). Only when the guest agent does not answer (it was removed, or never
  installed): click **Copy Command**, start the VM, open a terminal in it,
  paste the command and enter your password, then Update VM again. It adds
  that one public key for root and keeps SSH on, reachable from this Mac
  only; it changes no passwords and removes no keys. If the key went in and
  SSH still refuses, the VM's SSH settings were changed (`/etc/ssh/sshd_config`:
  `PermitRootLogin` must allow keys).
- **Where:** `app/app/Sources/OmacVM/VMKey.swift`,
  `app/app/Sources/OmacVMWindow/SSHRepair.swift` (the guest script),
  `app/scripts/update-vm.sh`, `app/scripts/vm-common.sh` (`wait_ssh ...
  refused`), `src/lib/vm.sh` (`ssh_setup_command`); tests
  `src/tests/update-vm-watch.sh`, `swift run window-tests`.

## 39. app: Hyprland and apps crash after a few screenshots (SIGBUS)

- **Symptom:** the desktop restarts (Hyprland in safe mode), and apps such as
  Electron apps and hypridle die at the same moment. `coredumpctl` shows
  SIGBUS, Hyprland's in `createTexture` while it reads a window's buffer.
- **Cause:** the desktop user's runtime folder (`/run/user/1000`) is full. It
  is a tmpfs of 10 % of the VM's memory (about 1 GB with 10 GB), and apps keep
  their shared-memory buffers there: when nothing fits, touching one is
  SIGBUS. Up to 3.1.24 OmacVM.app's hyprpicker (the frozen screen of
  screenshots) left its buffers there each time: 3 files per display, 59 MB
  each on a 5K display, so a handful of screenshots filled 1 GB (on a test
  VM with 3 GB, 17 did). hyprpicker's own release deletes them when it
  stops; OmacVM's build stops with `_Exit` and skipped that.
- **Fix:** Update VM (or `omacvm apply`): the build now deletes each file's
  name as soon as it has made the file, so nothing stays whatever way it
  stops, and the leftovers go (only while no hyprpicker runs). A restart
  empties the folder too. `omacvm check` shows "runtime folder" and warns
  above 80 %.
- **Where:** `src/app/guest/hyprpicker/redraw-on-change.patch` (built by
  `build.sh`), `src/app/guest/install.sh`, `src/guest/check.sh`; test
  `src/tests/hyprpicker-patch.sh`.

## 40. app: gestures and the bar do nothing in a VM copied from another Mac

- **Symptom:** a VM folder copied to another Mac (a new Mac, a second Mac)
  starts, but trackpad gestures, ⌃⌥ Esc and scroll momentum do nothing, the
  bar shows "Ethernet" instead of the Mac's Wi-Fi, and macOS never asked to
  allow anything. Since 3.1.28 OmacVM says so before the start ("... was set
  up on another Mac") and as a red notice in its window.
- **Cause:** the Mac helpers (OmacVM Gestures, OmacVM Bridge, Omanotch) and
  the token the VM uses to talk to them belong to a Mac. Only Update VM, a
  build or `omacvm apply` install them; a start does not. A copied VM also
  has the other Mac's token, which the helpers here refuse. macOS asks for
  Accessibility and Input Monitoring only when a helper starts for the first
  time, so with no helper there is no question either.
- **Fix:** click **Update VM** (in the question before the start, the notice
  or the window's header). It starts the VM without a window, installs the
  helpers the VM's features need, gives the VM this Mac's token and shuts it
  down, then starts it. macOS then asks you to allow OmacVM Gestures
  (Accessibility, Input Monitoring) and OmacVM Bridge (also Location Services
  and Bluetooth). A helper that is installed but not allowed, or switched off
  under System Settings › General › Login Items & Extensions, gets a button
  for that pane instead. A VM from a newer OmacVM needs the app updated first
  (Check for Updates). `omacvm check --vm NAME` shows the same in its
  "Mac setup" line. Later starts the VM as it is and is not asked again for
  that problem until it or the app changes.
- **Where:** `src/lib/mac-setup.sh` (which helpers a VM's features need, the
  same map `omacvm apply` installs by; `mac_setup_state`), `src/mac/install.sh
  --status`, the VM folder's `mac-setup` record (a hash of the token `omacvm
  apply` gave the VM), `src/cmd/check.sh` ("Mac setup"),
  `app/app/Sources/OmacVMFeatures/MacSetup.swift` (the words),
  `app/app/Sources/OmacVM/MacSetupAsk.swift` and `main.swift`
  (`askMacHelpers`); tests `src/tests/mac-setup.sh`, `swift run features-tests`.

## 41. app: no sound with AirPods (or another Bluetooth output) as the Mac's output

- **Symptom:** with AirPods as the Mac's output the VM is silent, while Mac
  apps play over them (#548). `qemu.log` has `SDL_OpenAudioDevice for
  playback failed: CoreAudio error (AudioQueueStart): -66681` at each sound.
  Afterwards the Mac's speakers sometimes stayed silent too, until
  `sudo killall coreaudiod`. 3.1.17 to 3.2.4, with Sound on its own thread
  (the default).
- **Cause:** SDL3 opens CoreAudio's AudioQueue at QEMU's rate with QEMU's
  buffer size: on the sound's own thread 48 kHz and 6 x 256 frames, on
  QEMU's main loop 44.1 kHz and 4 x 512 frames. The AirPods (A2DP) refused
  to start the own thread's queue (-66681, kAudioQueueErr_CannotStart) and
  played the main loop's. The thread itself never talks to CoreAudio.
- **Fix (3.2.5):** a VM started while the Mac's output is wireless
  (Bluetooth, AirPlay) gives CoreAudio the main loop's queue from the own
  thread (44.1 kHz, 512 frames). When you switch to such an output while
  the VM runs, QEMU opens it again with 512-frame buffers. Any output that
  still refuses a start gets the next size at once (512, then 1024, each
  only while QEMU's ring holds twice that), and a size that played stays
  for the run. qemu.log:
  `OmacVM: sound: playback buffers: 512 frames (...)`; `omacvm check` shows
  it as "sound buffers". If it still says the output refused every size,
  restart the VM with the AirPods connected (a VM started with them
  connected already has those buffers: pick another output instead). From
  3.2.7 QEMU does not start that output again until the Mac's output
  changes or macOS's sound service restarts (`sudo killall coreaudiod`);
  before: every 30 s while the VM played. Before 3.2.5: `defaults write
  org.omacvm.app audioThread -bool false` and a restart of the VM (thanks to
  @maxschoenberger for the workaround).
- **Where:** `app/runtime/patches/qemu-sdl-audio-out-size*.patch`,
  `app/app/Sources/OmacVMAudio/AudioOutputSize.swift`,
  `app/app/Sources/OmacVM/AudioLatencyWatch.swift` (the size file,
  `OMACVM_AUDIO_OUT_FRAMES_FILE`); tests `Tests/audio/test-out-size.sh`,
  `Tests/audio/refuse-small-start.c` (fakes the refusal),
  `swift run audio-tests`, `src/tests/audio-timing.sh`.

## 42. app: macOS asks to let OmacVM find devices on local networks

- **Symptom:** at the first start of a VM macOS asks "Allow “OmacVM” to find
  devices on local networks?". With Don't Allow, macOS may keep Omarchy from
  devices on your network (printers, a NAS, other computers).
- **Cause:** macOS's Local Network privacy (macOS 15 and later). QEMU's own
  network (the default; the fast network is off) sends the VM's traffic from
  QEMU, which OmacVM starts inside the app: the VM's DNS queries go to the
  Mac's DNS server, its connections to the Mac's networks go from there.
  macOS counts QEMU as OmacVM and keeps one answer for the app in its folder:
  by bundle id, not by signature or version. An update through OmacVM puts
  the new version in the same place: no new question (tested from 3.2.3 to
  3.2.4 through the app's updater, both with new programs; macOS's log says
  "allowed by preference"). Another version of the app in another folder is
  asked again for that folder. With the fast network on, the Mac reaches the
  VM at 192.168.77.x: the same answer covers it.
- **Fix:** Allow. To change it later: System Settings › Privacy & Security ›
  Local Network › OmacVM, then restart the VM. Keep one copy of the app (in
  Applications).
- **Where:** the question's text is `NSLocalNetworkUsageDescription` in
  `app/scripts/build-app.sh`. macOS keeps the answers in
  `/Library/Preferences/com.apple.networkextension.plist` (one rule per
  bundle id, and one per folder for copies of other versions); `log show
  --info --predicate 'process == "nehelper"'` says "Local network preference
  not yet set, prompting for OmacVM", or "allowed by preference" / "denied by
  preference" when macOS already has an answer.

## 43. app: AirPods or Control Center play the Mac's music, not the VM

- **Symptom:** a video plays in an OmacVM.app VM, and a press on the AirPods
  (or Control Center's play button, or a play key with the VM not in front)
  pauses or starts Music on the Mac instead.
- **Cause:** macOS gives these controls to its Now Playing app: the app that
  started playing last. The VM is that app only while its player plays, with
  **AirPods and media controls** on and the VM's side updated. A Mac app that
  started playing after the VM took the controls (macOS's rule); a Mac app
  that played and was paused while the VM kept playing keeps them too.
- **Fix:** pause and play in the VM once: the VM takes the controls back.
  Else check, in this order: the switch (VM window, Output, **AirPods and
  media controls**; the test identity has it off by default); Update VM (an
  OmacVM.app from before 3.2.9, or a VM not updated since, has no
  `omacvm-media`); `omacvm check`'s "media controls" line (the service not
  running: `omacvm apply`; "waiting for the app to answer": the port is there
  but the app has not answered the VM's side yet, which tries again at most
  30 s apart; if it stays, quit the VM and start it again from the app); a
  player the VM's MPRIS does not see
  (`busctl --user list | grep mpris` in the VM: Chromium, Firefox and mpv
  with mpv-mpris are there).
- **Where:** `app/app/Sources/OmacVM/NowPlaying.swift`,
  `app/app/Sources/OmacVMMedia/` (the rules, `swift run media-tests`),
  `src/app/guest/omacvm-media`; qemu.log `OmacVM: media controls: ...` (why
  the VM gave the controls up), `journalctl --user -u omacvm-media` in the VM;
  docs/adr/0058-now-playing.md.

## 44. app: screenshots and screen sharing of Chrome too bright in an HDR VM

- **Symptom:** with HDR and 10-bit colour on, screenshots of Chrome or
  Chromium (Omarchy's screenshot, also its frozen screen while you pick a
  region, `grim`), colours picked with hyprpicker, and screen or window
  sharing (Teams, Meet, OBS through the desktop portal) come out washed out: light greys white, Teams' #5B5FC7 as (142,148,255).
  On screen they look right; apps that draw SDR (imv, a terminal) come out
  exact. Omarchy's screen recordings come out grey and flat for every app.
- **Cause:** those apps draw in HDR (PQ) with SDR white at 203 nits
  (BT.2408). Hyprland 0.56.2 and 0.57.0 write the SDR copy every capture reads with
  SDR white at 80 nits for HDR windows (`cm_helpers.glsl`, a TODO upstream),
  so every colour is 2.54 times too bright in linear light and the light
  ones clip; a window shared alone is clamped at 80 nits the same way. SDR
  windows get their own 203 nits there. It happens inside the VM, not on
  the Mac. The recordings are another cause: Omarchy's recorder
  (gpu-screen-recorder) reads the screen itself and took its PQ codes for
  SDR, because the VM's display did not say it is HDR.
- **Fix:** Update VM (or `omacvm apply`). OmacVM puts a fixed copy of that
  one shader file into `/usr/local/share/hypr/shaders/`: HDR windows get SDR
  white at 203 nits in the copy, and a window shared alone is brought to
  the share's white before Hyprland's clamp. A running desktop takes it at
  once. Captures are SDR, so parts brighter than white (HDR video
  highlights) are cut off in them. One file per Hyprland release (0.56.2,
  0.57.0), each only for the Hyprland it was made for (checked byte for byte
  at each Hyprland update; a Hyprland update puts in the new release's file):
  with another one `omacvm check`'s "HDR captures" line says there is no
  OmacVM fix for it, names the installed version and the releases OmacVM has
  fixes for (e.g. "no OmacVM fix for Hyprland 0.58.0-1 yet (OmacVM has fixes
  for 0.56.2 and 0.57.0)"), and Hyprland's own copy is used. After a Hyprland
  update, log out and in before running `hyprctl reloadshaders` yourself: the
  Hyprland still running from before would read the new release's file.
  Back to Hyprland's own copy until the
  next Update VM or Hyprland update (both put it back):
  `sudo /usr/local/lib/omacvm/hypr-capture/hypr-capture.sh --remove`. Do not
  keep a copy of the file in `~/.config/hypr/shaders/`: Hyprland would read
  it before OmacVM's and keep it after a Hyprland update it was not made
  for, where it may not compile and windows draw nothing. Recordings:
  Update VM, then shut the VM down and start it again: the VM's graphics
  driver then tells the recorder the screen is HDR (`omacvm check`: "HDR
  recordings"), and it makes SDR of it itself, with its own curve: white
  comes out at about 224 of 255 at a high headroom, 244 at headroom 2, 255
  with Extra brightness. While the Mac cannot show PQ the VM's screen is SDR
  and says so too ("HDR recordings" says which). Screenshots and shares taken on the Mac (a macOS
  screenshot, sharing the VM's window from a Mac app) are macOS's own and
  not covered.
- **Black screenshots of the empty desktop:** with HDR on, a screenshot or
  share of the desktop while its wallpaper is missing (Omarchy's shell
  restarting or crashed) is black where the screen shows dark grey: Hyprland
  leaves its background colour out of the copy that captures read. Nothing
  to do; the wallpaper and windows come out right. Up to 3.2.15 the same
  kept OmacVM's repair of a display without wallpaper (`omacvm-displays`,
  `omacvm check`'s "desktop" line) from seeing it with HDR on; Update VM
  (3.2.16) fixes that (`docs/notes/findings.md`).
- **Where:** `src/app/guest/hypr-capture/` (the file, `guard.py`, the
  pacman hooks, `hypr-capture.sh`), `src/app/guest/install.sh`,
  `src/guest/check.sh`; test `src/tests/hypr-capture.sh`; recordings:
  `src/app/guest/virtio-gpu/linux-virtio-gpu-hdr-metadata.patch`, tests
  `src/tests/virtio-gpu-patches.sh`, `src/tests/hdr-recording-check.sh`;
  ADR 0049 (amended 2026-10-27).

## 45. app: the VM freezes for seconds or a minute, the Mac is out of memory

- **Symptom:** the VM stands still for seconds to a minute and then goes on:
  windows, video and the pointer stop, sound drops out. In the VM,
  `journalctl -k` has "rcu: INFO: rcu_preempt detected stalls on CPUs/tasks"
  (some CPUs, not all), `journalctl -u omacvm-vdecd` a "Watchdog timeout",
  the display agent "no word from the Mac for 15 s". On the Mac, Activity
  Monitor's Memory tab shows little free memory and the VM's "Compressed
  Memory" growing, while the pressure graph may still be green.
- **Cause:** macOS ran out of free memory and makes pages free by compressing
  and swapping. A vCPU whose guest touches a page macOS compressed or swapped
  out waits in macOS's kernel until macOS has a free page for it: that vCPU
  stands still, the others run on. A VM that holds most of the Mac's memory
  (a 42 GB VM on a 64 GB Mac held 51 GB with its file cache and graphics)
  gets there with nothing else running. QEMU's graphics thread can stand
  still the same way in a call to the Mac.
- **Check:** `logs/qemu.log` in the VM's folder has a line for each stall
  of 1 s or more, in this format (the numbers are an example): "OmacVM:
  stall: vCPUs 1, 2, 3, 8 stood still for about 58 s, blocked in macOS's
  kernel waiting for memory (Mac: compressor and swap 900 MB/s, 0.3 GB
  free, ...)". It says "waiting for memory" only when the Mac was paging
  then (compressing or swapping 16 MB/s or more, or pressure warn or
  critical); "blocked in macOS's kernel (the Mac was not paging ...)" is
  something else in macOS, and "waited ... for a Mac core" means the Mac's
  CPUs were busy. The app menu says "The VM stood still N times";
  `omacvm check --vm NAME` has a "VM stalls" warning. "main loop stalled for
  N s in a GPU run without the BQL" is QEMU's graphics thread waiting in a
  call to the Mac (the vCPUs ran on); "with the BQL held (the VM waits)" is
  the whole VM waiting for QEMU (counted as `main_stalls`). Short stalls can
  be missed: a vCPU blocked in macOS's kernel under about 2.25 s (3.25 s if
  it was nearly idle before), one without a Mac core under about 4 s.
- **Fix:** give the VM less memory (`omacvm resources --vm NAME --memory-gb
  N`, from its next start), or quit big apps on the Mac. OmacVM.app's
  give-back of the VM's cold file cache while macOS compresses it (ADR 0059)
  is on from 3.2.12 (QEMU's free page reclaim, ADR 0062); 3.2.11 had it off.
  From 3.2.18 the VM also gives back when it is idle, and gathers its
  scattered free memory so that the Mac can take it back (compaction).
  After a stall of 10 s or more for memory the VM shows a note that says so
  (once per 30 minutes; Update VM puts the note in). The memory cause has
  been shown only in tests so far (simulated stalls), so the note has not
  yet been seen on a real Mac.
- **Where:** `app/runtime/patches/qemu-hvf-vcpu-stall-note.patch` (the
  lines, `logs/vm-stalls`), `qemu-main-loop-stall-gpu-run.patch`,
  `omacvm-cocoa-vm-stalls-menu.patch`, `app/app/Sources/OmacVMDesktop/VMStalls.swift`,
  `src/app/guest/omacvm-desktop-recover` (the note), `src/cmd/check.sh`;
  tests `app/runtime/Tests/vcpu/test-vcpu-stall.sh`, `src/tests/vm-stalls.sh`,
  `swift run desktop-tests`; ADR 0060.

<a name="46-all-routes-the-lock-screen-has-no-password-field-after-an-update-of-a-locked-vm"></a>

## 46. The lock screen has no password field after an update of a locked VM

- **Symptom:** (Omarchy 4.0 VMs) `omacvm update` or `omacvm apply` ran while
  the VM's Omarchy session was locked (3.2.12 and older; also switching
  Omanotch off). The
  lock screen comes back without its password field, and typing the password
  does nothing. Omarchy's shell log (`journalctl --user -t omarchy-shell` in
  the VM) has "Session lock object was destroyed without unlocking", then
  "lock-stranded: recovering" and "lock-pending: screen-stabilizing".
- **Cause:** the shell of omarchy-mac 4.0.3 reloads all its plugins, its own
  lock screen too, whenever a file under `~/.config/omarchy/plugins` changes
  or it is asked to rescan them. Every update wrote OmacVM's bar widgets
  there again and asked for a rescan. The new lock screen never gets the
  lock Hyprland still holds, so it waits without a password field. Upstream
  Omarchy keeps its lock screen over such a reload (omacom/omarchy#9485);
  omarchy-mac 4.0.3 does not have that yet. This is not Omarchy's other lock
  bug above (omacom/omarchy-mac#738), which only stops the next lock.
- **Fix:** shut the VM down and start it again (`omarchy-restart-shell`
  refuses while the lock is asked for). From 3.2.13 an update of a locked VM
  writes nothing there and asks for no rescan: changed widgets wait in
  `~/.local/state/omacvm/plugins-staged`, and right after the unlock they go
  in place and the shell restarts once. A widget that did not change is not
  written again at all. `omacvm check` says "right after the next unlock" for
  a widget that waits. Switching the control centre or Omanotch off while
  the VM is locked does the same: the control centre leaves the bar at once
  and its folder goes at the next update; Omanotch stops at once and removes
  its copies of Omarchy's plugins right after the unlock.
- **Where:** `src/guest/session-lock.sh` (the one lock check),
  `src/lib/install-plugin.sh`, `src/lib/omacvm-plugins`,
  `src/guest/restart-shell.sh`, `src/app/guest/omacvm-displays` (the display
  widget), `src/omanotch/guest/monitor/display-panel.py` (Omanotch's display
  panel), `src/guest/off.sh` and `src/control/guest/install.sh` (the offs);
  tests `src/tests/plugin-lock.sh`, `src/tests/restart-shell.sh`,
  `src/tests/lock-rules.sh` (the three lock rules against one table),
  `src/tests/features-off.sh`, `src/omanotch/guest/tests/test_display_panel.py`.

## 47. app: Ghostty opens no window, or draws on the CPU

- **Symptom:** Ghostty (Omarchy's Install > Terminal, or the default terminal
  you picked) opens no window. Started from a terminal with
  `GHOSTTY_LOG=stderr ghostty` it says "loaded OpenGL 4.1", "OpenGL version
  is too old. Ghostty requires OpenGL 4.3" and "error.OpenGLOutdated"
  (3.2.13 and older). From 3.2.14 Ghostty opens, and `omacvm check` says
  "Ghostty: draws on the VM's CPU".
- **Cause:** OpenGL in an OmacVM.app VM is virgl on the Mac's OpenGL, which
  macOS stops at 4.1 (in both Graphics modes: Vulkan adds Venus beside it). Ghostty 1.2 and newer need 4.3
  (storage buffers in their shaders), which the Mac's OpenGL cannot give.
  Zink on the Mac's Vulkan driver gives only OpenGL 2.1 (GTK: "No EGL
  configuration available"). With OmacVM.app 3.2.13 and older a forced 4.3
  stopped the whole VM (QEMU aborted in the Mac's Metal driver, unsaved work
  in the VM was lost): don't start apps with `MESA_LOADER_DRIVER_OVERRIDE=zink`
  there. From 3.2.14 the VM goes on (ADR 0065), and Zink still gives no 4.3.
- **Fix:** Update VM (3.2.14). Ghostty alone then draws with Mesa's CPU
  renderer (llvmpipe, OpenGL 4.6); the programs started inside it keep the
  Mac's GPU. Then log out and in, or
  `systemctl --user stop app-com.mitchellh.ghostty.service`: a Ghostty
  service that ran before the update keeps what it started with. It costs
  CPU: 10 s of fast output (2,400 lines/s) took Ghostty 19.8 CPU-seconds in
  a 1272x640-pixel window at scale 2 and 22.8 in a 1296x690 one at scale 1
  (about 2 to 2.3 of the VM's 4 cores; foot 0.8 and 1.5, Alacritty 0.6 and
  0.8), and 35.5 in a 2512x1500 one on a 2560x1600 display at scale 2
  (3.5 cores, nearly the whole VM; foot 2.0, Alacritty 0.8). Omarchy's screensaver runs in the
  default terminal, so with Ghostty it draws on the CPU too while it shows,
  and that is heavy: on two displays at scale 2 it kept 3.7 of a test
  VM's 4 cores busy, and the Mac mini drew about 36 W against 14-18 W without
  it (20 W with the screensaver in foot). With Omarchy's defaults it runs
  from 2.5 minutes idle until the lock at 5 minutes, which closes it, and
  not while the screen is locked (Omarchy's source; not measured). Off:
  `omarchy-toggle-screensaver`, or `omacvm enable no-idle-lock`. Terminals
  that draw on the Mac's GPU in the VM: Alacritty and Kitty (Install >
  Terminal); Omarchy's default foot draws on the CPU by design and costs
  little (Setup > Defaults > Terminal, or `omarchy-default-terminal foot`).
  Before 3.2.14:
  `LIBGL_ALWAYS_SOFTWARE=1 ghostty`, set for Ghostty only, not for the whole
  session (GL programs started from that Ghostty's shell draw on the CPU too;
  Chromium drops the variable). A driver set by hand (`LIBGL_ALWAYS_SOFTWARE`,
  `MESA_LOADER_DRIVER_OVERRIDE`, `GALLIUM_DRIVER`) wins over OmacVM's.
- **On the Mac's GPU (3.2.18, experimental):** the VM window's switch
  Ghostty on the Mac's GPU (General) starts Ghostty alone on Zink over the
  VM's Vulkan with a forced OpenGL 4.3, on macOS 26 and newer (KosmicKrisp)
  with Graphics Automatic or Vulkan. Update OmacVM.app, Update VM, turn the
  switch on, then shut the VM down and start it again (a restart inside the
  VM keeps the old answer; the row says what the running VM got); a Ghostty
  that is open keeps its driver until you quit it. Measured on a Mac mini M4
  and a MacBook Pro M1 Max: typing shown in 25 and 28 ms instead of 56 and
  57, 10 s of fast output 3.3 and 3.4 instead of 32.8 and 31.7 Ghostty
  CPU-seconds, for 6-9 % of the Mac's GPU and 150-300 MB of its graphics
  memory (M1 Max: one window 155-163 MB, three windows of one Ghostty
  164-278 MB). Omarchy's screensaver
  in Ghostty on two displays: the Mac mini drew 40-41 W on Zink against
  53-54 W on the CPU (35-36 W without it, 39 W in foot; one session). `omacvm check` says which
  driver a running Ghostty has (zink or llvmpipe) and why. Not with GPU safe
  mode, Graphics OpenGL or MoltenVK (macOS 15): Ghostty stays on the CPU.
- **Symptom with the switch on:** Ghostty stops drawing and takes no input,
  and Hyprland asks "Application Not Responding ... Terminate / Wait"; or
  Ghostty ends, or does not open at all. **Cause:** the Mac ended Ghostty's
  Vulkan context: it refused a command, or the VM's graphics memory was used
  up (qemu.log: "venus context N (ghostty) is lost"; with a 384 MB budget and
  Chromium on a WebGL page a Ghostty on Zink ended at its start, one on the
  CPU opened). **Fix:** Terminate (the programs running in that Ghostty end
  with it), then open Ghostty again; if it happens again, turn the switch
  off, then shut the VM down and start it again: the switch counts only from
  a VM start, so until then a new Ghostty can start on Zink again.
- **Where:** `src/app/guest/omacvm_egl.c` (OmacVM's EGL vendor library),
  `src/guest/check.sh` ("Ghostty"), the app's `GhosttyGPU`
  (`app/app/Sources/OmacVMWindow/GhosttyGPU.swift`); tests
  `src/app/guest/tests/egl-vendor.sh`, `src/tests/ghostty-check.sh`,
  `swift run window-tests`, `src/tests/app-settings.sh`; ADR 0064 and its
  amendment (#598).

## 48. app: Chrome goes blank or flickers while the Mac is short of memory

- **Symptom:** in an OmacVM.app VM (3.2.14 and older), Chrome's windows go
  blank or flicker and its pages stop drawing; the VM says "chrome stopped
  drawing" because macOS ran short of memory. Only quitting Chrome, or
  restarting the VM, helped. Seen on a Mac mini with 16 GB: a 12 GB VM, Chrome
  full screen on a 5K display, macOS at critical memory pressure (red in
  Activity Monitor).
- **Cause:** while macOS is short of memory, QEMU gives an app no new big
  buffer it has no room for (16 MB or more; a 5K window's is about 56 MB):
  the app that takes one loses its GPU context on the Mac, so the desktop
  keeps drawing (ADR 0034). `logs/qemu.log` says "context N (chrome) made
  resource ... while macOS is short of memory (pressure critical): only the
  desktop may have more now, the context is lost ... the guest driver cannot
  be told, the app must be restarted". The VM's Mesa cannot tell Chrome, so
  Chrome kept drawing into the lost context.
- **Fix:** 3.2.15 (Update VM): the VM ends the lost app's GPU process, and
  Chrome or Chromium starts a new one within seconds; open tabs stay, pages
  with WebGL may need a reload. Other Chromium-based apps (Electron apps such
  as VS Code) have the same GPU process and should do the same (not
  measured). At most once per app in 6 minutes and 3 times in an hour:
  Chrome counts each as a crash and draws without the GPU for the rest of its
  session after 3 recent ones. Lost again within that time, the note says to
  quit Chrome and open it again. With the app update too (3.2.15, from the
  VM's next start), an app that only replaces its buffers while macOS is
  critical keeps its graphics, and one that grows loses them only past a
  grace ([24](#24-app-a-scale-like-16-on-a-5k-display-turns-the-vm-black-and-flickering)).
  With 3.2.15's app, a loss less than a minute after the app's last note for
  Chrome was not told at all (Chrome blank, no note); from 3.2.16 (an app
  update; the VM needs none) it is told when that minute is over, 60 to 66 s
  after the last note: inside the 6 minutes that is the note "chrome stopped
  drawing", not a second restart.
- **Before the update:** free memory first. While Activity Monitor's memory
  pressure is red, a Chrome restarted by hand loses its graphics again at
  once (seen in a test VM), and each restart counts as a Chrome crash. Close
  Chrome windows and tabs at 5K and quit Mac apps you do not need until the
  pressure is no longer red; then, in a terminal in the VM,
  `pkill -f -- 'chrome --type=gpu-process'` (Google Chrome; Chromium:
  `pkill -f -- 'chromium --type=gpu-process'`), at most once every 5 minutes,
  or quit Chrome (Ctrl+Shift+Q) and open it again. The VM's graphics come on
  top of its memory, so a VM memory that leaves macOS room keeps the Mac out
  of critical
  ([45](#45-app-the-vm-freezes-for-seconds-or-a-minute-the-mac-is-out-of-memory)).
- **Where:** `src/app/guest/omacvm-desktop-recover` (test
  `src/tests/desktop-recover-gpu.sh`), ADR 0038's 3.2.15 amendment; which
  losses the app tells and when: `GPUMemoryNotice` in
  `app/app/Sources/OmacVMDesktop/GPUMemory.swift` (test
  `swift run desktop-tests`), ADR 0038's 3.2.16 amendment.

## 49. app: Activity Monitor shows the VM with far more memory than it has

- **Symptom:** Activity Monitor's Memory for OmacVM (the VM's QEMU) is far
  above the memory set for the VM: 23 GB for a 12 GB VM on a 16 GB Mac mini,
  19.3 GB at 10 GB (Chrome full screen at 5K, 2026-10-30). The Mac swaps, its
  memory pressure is yellow or red, and apps in the VM can lose their
  graphics (`omacvm check`'s "GPU contexts" row names them).
- **Cause:** the number is QEMU's footprint, and it holds more than the VM's
  memory. The VM's graphics come on top of it, from the Mac's memory as the
  VM draws (2 to 5 GB for a 5K desktop with a browser; 4.5 GB in the 12 GB
  run). And macOS counts a page of the VM twice once QEMU itself touched it
  (disk, graphics, network), compressed or not: a 4 GB VM after a browser
  session showed 5.9 GB, 2.1 GB of it counted twice, and the Mac got 4.8 GB
  back when QEMU stopped; a 12 GB VM with nothing compressed showed 1.2 to
  2.0 GB more than it held. From 3.2.17 QEMU remaps its own view of the VM's
  memory every 5 minutes, which drops that count; what it touched since then
  is still counted twice (ADR 0066). From 3.2.18 a sweep that does not keep
  the same memory on a Mac turns itself off for the run (QEMU tries it on
  scratch memory first) or maps the memory back and stops; the VM keeps
  running. It never was memory: the Mac gets
  nothing back from it. A VM above the Mac's Best tier (8 GB on a 16 GB Mac)
  plus its graphics leaves macOS too little.
- **Check:** `omacvm check --vm NAME` has an "Activity Monitor" row while
  the VM runs: "19.3 GB for the VM: VM memory at most 10.0 GB, graphics
  3.2 GB now, the rest 6.1 GB (QEMU itself, graphics overhead and pages of
  the VM QEMU touched, which macOS counts twice)", a warning above the Best
  tier; with 3.2.17's QEMU "pages of the VM QEMU touched since its last
  sweep, counted twice until then", and "QEMU's own-view sweep is off for
  this run: why" when it is off or stopped. `logs/qemu.log` has the sweep's
  lines ("own-view sweep": on or "off (why)", then a line an hour; "stopped
  for this run: why"). `omacvm resources --vm NAME` says the same warning.
- **Fix:** give the VM the Best tier or less: in OmacVM.app the VM's
  General › Resources › Best, or `omacvm resources --vm NAME --resources
  best`; it applies at the VM's next start. OmacVM never lowers the setting
  by itself. Quitting big Mac apps helps too. The graphics stay outside the
  setting (Linux sees exactly the memory set), and their runaway guard stays
  at three quarters of the Mac
  ([graphics memory and VM memory](routes/app.md#graphics-memory-and-vm-memory)).
- **Where:** `src/cmd/check.sh` ("Activity Monitor"), `src/lib/footprint.py`,
  `app/runtime/patches/qemu-hvf-own-view-sweep.patch` (the sweep and its
  trial, ADR 0066; `app/runtime/Tests/memory/test-dcount.sh`),
  `src/lib/setup.sh` (`mem_warning`), `src/cmd/resources.sh`,
  `app/app/Sources/OmacVMWindow/CustomResources.swift`
  (`ResourceLimits.warning`), `app/app/Sources/OmacVMDesktop/GPUMemory.swift`
  (the (i)); tests `src/tests/activity-monitor.sh`, `src/tests/resources.sh`,
  `src/tests/memory-dcount.sh`, `swift run window-tests`, `swift run desktop-tests`,
  and the window pictures (`OmacVM --render-vm-window`, CI): the warning 2 GB above the
  Mac's Best tier inside the window (window-26), none at Best (window-27),
  the (i)'s text (popover-2-resources).

<a name="50-all-routes-notifications-panels-and-the-omarchy-menu-black-out-the-screen-hyprland-057"></a>

## 50. Notifications, panels and the Omarchy menu black out the screen (Hyprland 0.57)

- **Symptom:** while an Omarchy notification, a bar panel or the Omarchy
  menu shows, the whole screen is black around its card. Opaque windows are
  fine. With `QT_QUICK_BACKEND=software` (Qt's CPU renderer) it is
  transparent. With Hyprland 0.57
  (`hyprctl version`; released 2026-10-28): Omarchy's edge repository (the
  dev channel) since 2026-10-29, Omarchy stable once it ships 0.57, or Arch
  Linux ARM's 0.57.0 after a bare `pacman -Syu`.
- **Cause:** Hyprland 0.57.0 turns `quirks:skip_non_kms_dmabuf_formats` on
  by default (hyprwm/Hyprland#15803). Hyprland then offers apps only the
  buffer formats a display plane takes, and virtio-gpu's plane takes
  XRGB8888 only: no format with alpha is left. Mesa
  then has no EGL config with alpha (15 configs instead of 165 in a test
  VM), Qt Quick draws the shell's transparent layers into XRGB8888 buffers,
  and Hyprland shows them opaque: black where they are transparent. Qt's CPU
  renderer uses shared-memory buffers, which keep ARGB8888. Not OmacVM
  3.2.13: the same VM and app flip between black and transparent on that one
  option, also on Hyprland 0.56.2 with it set by hand.
- **Fix (3.2.15):** Update VM (`omacvm apply`, `omacvm update`), then log
  out and in (or restart the VM). OmacVM turns the option off
  (`~/.config/hypr/omacvm_vm.lua`), only when this Hyprland has it on and
  your own Hyprland files do not name it; on Hyprland 0.56 nothing changes.
  Hyprland builds the table of formats at its start: a reload that changes
  the option does not always rebuild it (the first reload after Hyprland
  starts never does), so `hyprctl getoption quirks:skip_non_kms_dmabuf_formats`
  saying false is no proof before you log out and in. An OmacVM.app VM
  updated while it was shut down needs nothing more. `omacvm check` has a
  "transparent panels" row: it says ok from the first login after the fix,
  and "log out and in" before. Your own setting wins: `true` in your
  Hyprland files keeps the black (the row says which file).
- **Before 3.2.15:** add this line to `~/.config/hypr/looknfeel.lua`, then
  log out and in:

  ```lua
  hl.config({ quirks = { skip_non_kms_dmabuf_formats = false } })
  ```

  and take `QT_QUICK_BACKEND=software` out of `~/.config/environment.d/` (it
  makes the shell draw on the CPU). The line can stay after the update:
  OmacVM then sets nothing.
- **Where:** `src/guest/omacvm_vm.lua` (Hyprland settings every VM needs),
  `src/guest/hypr-vm.sh` (from `src/guest/install.sh`), `src/guest/check.sh`
  ("transparent panels"); test `src/tests/dmabuf-alpha.sh` (Lua part:
  `src/tests/omacvm_vm_test.lua`). Issue
  [#630](https://github.com/gillesgoetsch/OmacVM/issues/630), reported by
  @epicoun.

## 51. app: a video in Chromium stops at its end, a looped one never loops

- **Symptom:** in an OmacVM.app VM, Omarchy's Chromium stops a video on its
  last picture when it decodes it on the Mac's media engine
  (`chrome://media-internals` says *V4L2VideoDecoder*): a looped video
  never starts again, the page never gets `ended` (a playlist does not go
  on), and a stream that changes its picture size in the middle (Media
  Source, as streaming sites do when they change the quality) stands still
  at the change. Up to there it plays at its full frame rate. 3.2.15 and
  older.
- **Cause:** at the end of a stream, and at a size change (which empties
  the decoder the same way), Chromium holds all of the decoder's picture
  buffers while the decoder still owes it the last pictures and the buffer
  that marks the end. The decoder (`omacvm-vdec`) answered Chromium's wait
  in that state with an error: the kernel's helper for such devices says
  EPOLLERR while no buffer is queued. Chromium 153 drops a wait that gets
  that answer and starts no new one, so it never saw the pictures and the
  end that came next.
- **Fix (3.2.16):** Update VM (`omacvm apply`, `omacvm update`), then quit
  and start Chromium again. If a video was open during the update, the new
  decoder loads at the next VM start (`omacvm check` says an update waits).
  Nothing on the Mac; any app version. Before 3.2.16, `omacvm disable
  chromium-video` has Chromium decode on the VM's CPU, which loops and ends
  (and costs about twice the VM's CPU at 4K).
- **Where:** `src/vdec/guest/module/omacvm-vdec.c` (`ovd_poll`, the wake in
  `inst_fail_all`); test `src/vdec/guest/test/vdec-test.c
  --hold-all-at-eos` (in the VM, as root);
  [video-decode.md](video-decode.md#chromium-from-arch-linux-arm).

## 52. app: canvas and SVG pages are slow in Brave, Vivaldi or an Electron app

- **Symptom:** in an OmacVM.app VM (3.2.17 and older), pages that draw many
  canvas strokes, clip paths or SVG paths (charts, whiteboards, diagram
  apps) are much slower in Brave, Vivaldi or Electron than in Google Chrome
  or Omarchy's Chromium. `chrome://gpu` (or a WebGL page) names the GPU
  `ANGLE (Mesa, virgl (Apple M4), ...)`, where Chrome says `OmacVM-GPU`.
- **Cause:** Skia, the graphics library of every Chromium-based app, turns
  instanced drawing off when the GL renderer names virgl, and then draws
  every canvas stroke and clip path on the CPU. Since 3.1.32 Mesa gives
  Chrome and Chromium the name "OmacVM-GPU" instead, by program name
  (`/usr/share/drirc.d/50-omacvm-chrome.conf`); every other program kept
  "virgl".
- **Fix (3.2.18):** Update VM (`omacvm apply`, `omacvm update`), then quit
  and start those apps again. The file now also names `brave`,
  `vivaldi-bin` and `electron` (the program of Electron's own arm64 build;
  Arch Linux ARM has no Electron package), on Wayland and X11. Brave
  1.98.63 in a test VM on a Mac mini M4: MotionMark 2754 -> 4483 (medians
  of 3), its Paths test 7.3x; Electron 45 at a fixed Paths complexity: 5.5
  -> 34 fps on Wayland. Nothing on the Mac; any app version.
- **Not covered:** an Electron app shipped under its own program name (its
  GPU process is that program).
- **The real name for one app:** start it with `force_gl_renderer=`
  (empty), e.g. `force_gl_renderer= brave`: Mesa then skips the file (also
  for Chrome) and prints "ATTENTION: option value of option
  force_gl_renderer ignored." on the app's error output.
- **Where:** `src/app/guest/50-omacvm-chrome.drirc`; test
  `src/app/guest/tests/test_chrome_drirc.py`;
  [graphics.md](architecture/graphics.md).

## 53. app: Ghostty on the Mac's GPU stops drawing, or a Vulkan app ends

- **Symptom:** in an OmacVM.app VM with Graphics on Vulkan, a Ghostty that
  draws through Zink on the Mac's GPU (set up by hand, for example) stops
  drawing and takes no typing;
  Hyprland says "Application Not Responding" with Terminate and Wait, and a
  new Ghostty window (Super+Return) does not open. Or another Vulkan app
  (vkcube, a game, Zed, Chromium with WebGPU) stops drawing or ends. The rest
  of the VM keeps working. The VM's `logs/qemu.log` has `venus context N
  (<app>) is lost`.
- **Cause:** the app's Vulkan (Venus) context ended on the Mac: the Mac
  refused one of its Vulkan commands (ADR 0065), or the graphics memory apps
  may use was full (`... (the GPU memory budget had refused its memory)`).
  Most Vulkan apps then end by themselves. Ghostty on Zink stays: its windows
  never draw again, and since Omarchy starts Ghostty as one instance, a new
  Ghostty asks the frozen one for its window over D-Bus, gets no answer and
  gives up (its log: `error registering application: Timeout was reached`).
  Up to 3.2.17 OmacVM did not count a lost
  Vulkan context (`logs/gpu-memory` stayed at lost=0), so nothing was said,
  and `omacvm check` did not name the app.
- **Fix (3.2.18, the app update and Update VM):** the app counts the loss
  and tells the VM, which shows a note ("Ghostty stopped drawing", or
  "<app> stopped drawing") and ends nothing. Close the frozen Ghostty first:
  Terminate in Hyprland's window (programs running in it end), then open
  Ghostty again without Zink's variables (in test VMs its window came in
  about 0.55 s): it starts on the CPU (llvmpipe, ADR 0064). Until the VM
  restarts OmacVM keeps `/run/omacvm/gl-zink-off` (one line "lost TIME
  WHY"): a start of Ghostty on Zink by OmacVM has to take the CPU while it
  exists. Other apps: restart them.
  `omacvm check`'s "GPU contexts" names the app, marked "(Vulkan)". A
  context the guest was closing anyway (the app was ending) is not counted:
  QEMU's log says `venus context N (<app>) ended while the guest closed it`.
  With the app update but no Update VM, the VM shows no note (the app's log
  says "Update VM puts it in").
- **Where:** `app/runtime/patches/virgl-venus-lost-context-count.patch`
  (tests `app/runtime/Tests/virgl/test-venus-lost-count.c`,
  `test-venus-robust.c` l-lost and l-teardown), `GPUMemoryNotice` and
  `DesktopRecovery` in `app/app/Sources/OmacVMDesktop/` (`swift run
  desktop-tests`), `src/app/guest/omacvm-desktop-recover venus` (tests
  `src/tests/app-desktop-recovery.sh`, `src/tests/desktop-recover-gpu.sh`),
  `src/cmd/check.sh` (`src/tests/gpu-contexts-check.sh`); ADR 0038's 3.2.18
  amendment.

## 54. app: a desktop OpenGL program draws nothing, upside down or without its clipping

- **Symptom:** in an OmacVM.app VM, a desktop OpenGL program (an app or game, not a browser) draws
  nothing where a shader writes gl_ClipDistance (qemu.log: "the host refused a shader (compile)",
  "Use of undeclared identifier 'clip_dist_temp'"); glClipPlane clips nothing; tessellated
  geometry drawn into a window shows upside down, in the other half; transform feedback from a
  tessellation evaluation shader records zeros; a program with a tessellation shader fails to link
  in the VM with "tessellation control shader uses too many output components (4 > 0)"; or a
  tessellation shader that indexes its varyings or patch varyings with a computed index draws
  nothing ("extension 'GL_ARB_arrays_of_arrays' is not supported" in qemu.log). 3.2.17 and older.
- **Cause:** the Mac's OpenGL 4.1 has no cull distances, no arrays of arrays and no atomic
  counters. The VM's virglrenderer wrote clip distances (and the end of a last tessellation
  evaluation shader: its y flip and transform feedback) only on a GL with cull distances, asked for
  arrays of arrays without checking, and reported the tessellation shaders' output limits only on
  a GL with atomic counters, so the VM's Mesa saw 0 and refused such programs itself (#589).
- **Fix (3.2.18):** update the app; it applies from the VM's next start. Nothing in the VM.
  Separable programs with patch varyings or varying arrays between their stages are a separate
  case. "Fallback to SW vertex processing for EVAL_PROG TF" once in qemu.log is expected: Apple's
  OpenGL records transform feedback from a tessellation evaluation shader on its software vertex
  path (on the CPU); the values are right.
- **3.2.19:** a program whose tessellation control shader passes clip distances to its evaluation
  shader ran on Apple's CPU vertex path with 3.2.18 ("Fallback to SW vertex processing because
  buildPipelineState failed" in qemu.log, a first draw of ~270 ms, MTLCompilerService crash
  reports), and on the M1 Max often drew nothing; 3.2.19 passes them as plain varyings and the
  draws stay on the GPU. 3.2.19 does the same for a vertex shader that passes clip distances
  straight to an evaluation shader (no control shader); on the M1 Max such draws drew nothing.
  Update the app.
- **3.2.20:** an OpenGL program pipeline (separate shader programs) whose tessellation patch values
  do not start at 0 or have a gap (explicit locations such as 1 and 3) ran on Apple's CPU vertex
  path ("Fallback to SW vertex processing because buildPipelineState failed" in qemu.log, a first
  draw of ~270 ms) on the M1 Max and drew nothing on the M4; the control shader now writes the gaps
  and the draws stay on the GPU. Update the app.
- **3.2.20:** a shader that writes its clip distances in a loop (a control shader copying
  `gl_ClipDistance[i]` in a `for` loop, also a vertex, geometry or evaluation shader) was refused
  ("Swizzle of non-vector primitive float" in qemu.log after "the host refused a shader") and
  its draws were skipped; 3.2.20 compiles it. A vertex shader that writes `gl_ClipDistance[4..7]`
  into a control shader drew nothing on the M1 Max and M4 GPUs; 3.2.20 passes them as plain
  varyings too. One case is left in the VM's Mesa: a control shader that copies 5 to 8 distances
  in a loop gets only 0..3 back, and 4..7 are undefined. On the M4 they read 0 (a negative one
  does not clip), on the M1 Max the draw is clipped away. 3.4.1 copies 4..7 on the Mac's side
  (#692), so no guest Mesa build is needed for it. Update the app.
- **Where:** `app/runtime/patches/virgl-shader-clip-distances.patch`,
  `virgl-shader-arrays-of-arrays.patch`, `virgl-caps-tess-outputs.patch`,
  `virgl-shader-tess-clip-varyings.patch`, `virgl-shader-vs-tes-clip-varyings.patch` (3.2.19),
  `virgl-shader-separable-patch-fill-writes.patch`, `virgl-shader-indirect-temps.patch`,
  `virgl-shader-vs-tcs-clip-varyings.patch` (3.2.20), `virgl-shader-clip-copyback.patch` (3.4.1); tests
  `app/runtime/Tests/virgl/test-whole-program-shapes.c`, `test-core-glsl-shaders.c`,
  `test-separable-pervertex.c`;
  [architecture/graphics.md](architecture/graphics.md#4a-shaders-and-limits-on-apples-gl-built-gl-compat)
  and ADR 0019.

## 55. app: a Vulkan app ends, the VM goes on

- **Symptom:** in an OmacVM.app VM with Graphics on Vulkan, one Vulkan app (a
  game, a tool, Chromium's GPU process) ends or says its device was lost,
  and the rest of the VM keeps working. The VM's `qemu.log` (in the VM's
  folder, `logs/`) has `vkr: <app>: vkCmd... refused: ...; the app's Vulkan
  context ends (N refused so far)` and `venus context N (<app>) is lost`.
  Or, with very many Vulkan apps or devices at once, a new one does not start:
  `vkr: N threads for guest calls already (at most 1024): the ... is not made`
  or `proxy: N Venus contexts already ...`.
- **Cause:** from 3.2.18 OmacVM.app checks the indices, counts, offsets and
  values a Vulkan app sends against the Mac GPU's limits and what the app
  made (ADR 0065). The Mac's Vulkan drivers use such values as memory
  addresses; before 3.2.18 a wrong one could stop the whole VM. The app sent
  one the Vulkan spec does not allow (an app bug), so only its connection
  ends. The line names the call and the values; only the 1st, 2nd, 4th, 8th
  ... refusal since the VM started is logged.
- **Fix:** update the app in the VM (most are fixed upstream once
  reported: the line is what to report), or give the VM OpenGL: Graphics
  OpenGL in the VM window, or `omacvm graphics --vm NAME opengl` (from the
  next start), which avoids Venus. A
  correct app that ends this way is an OmacVM bug: please report it with the
  line.
- **Not an app bug: Zink without kopper.** An OpenGL app on Zink started with
  `LIBGL_KOPPER_DISABLE=1` (OmacVM never sets it) ends in under a second with
  `host memory for recordings and objects at 2816 MB, past the app's 2816 MB`
  (the number depends on the Mac). Without kopper, Zink (Mesa 26.2) does not
  hold the app to the GPU's pace: glxgears put about 2200 draws into each
  submit and made 450 command pools in its first second (10 in all with
  kopper). Before 3.2.22 nothing stopped it, and QEMU grew by 5 GB in 7
  seconds and was still growing; from 3.2.22 the app's account for Mac memory
  (`OMACVM_VENUS_HOST_MB`) ends it first. The 2816 MB is the account's
  estimate: QEMU had grown only about 300 MB by then. Fix: leave
  `LIBGL_KOPPER_DISABLE` unset (with kopper, Zink waits for each frame:
  glxgears runs at 60 FPS and its account peaks at 26 MB). This is a Mesa (Zink) problem,
  not fixed in OmacVM.
- **Where:** `app/runtime/patches/virgl-venus-*-limits.patch`,
  `virgl-venus-host-memory.patch` (the `host memory` line),
  `virgl-venus-command-state.patch`, `virgl-venus-spirv-scan.patch` and
  `virgl-venus-spirv-validate.patch` (shaders: the line says `SPIR-V: ...` or
  `spirv-val (...): ...`), `virgl-venus-copy-regions.patch`,
  `virgl-venus-pipeline-formats.patch`, `virgl-venus-submit-counts.patch`,
  `virgl-venus-pool-frees.patch`, `virgl-venus-dedicated-memory.patch`,
  `virgl-venus-pass-views.patch`, `virgl-venus-thread-budget.patch` (the
  threads line), `virgl-venus-ring-lock.patch` (two threads of one app: `a
  pipeline call of another thread uses it`, `its id was taken while it was
  made`), `virgl-venus-command-holds.patch`, `virgl-venus-secondary-holds.patch`; tests `app/runtime/Tests/virgl/test-venus-commands.c`,
  `test-venus-threads.c`, `fuzz-venus-spirv.sh`, `venus-command-ledger.tsv`;
  ADR 0065.

## 56. app: the Mac's display turns off while a video plays in the VM

- **Symptom:** watching a video in the VM, the Mac's display goes dark
  after the time set in macOS (2 minutes on battery by default). Up to
  3.3.0.
- **Cause:** a Mac video player tells macOS to keep the display on while it
  plays. A player in the VM told only Omarchy (Wayland's idle inhibit).
- **Fix (3.3.1, the app update and Update VM):** the VM's display agent
  tells QEMU which of its outputs show a window whose app asks not to idle,
  and QEMU keeps the Mac's display on (`pmset -g assertions`: "OmacVM: the
  VM is playing video") while that window can be seen and the VM runs (ADR
  [0070](adr/0070-display-awake-for-video.md)). It lets go when the video
  pauses or ends, the window is minimised, covered or on another Space, the
  screen locks, the VM stops, or the VM says nothing for 30 s.
- **Stays on?** A player in the VM that hangs while it plays, in a window
  that can be seen, keeps asking Omarchy not to idle, so the Mac's display
  stays on until the window is hidden or minimised, the Mac locks or the VM
  stops, as with a Mac player that hangs.
- **Still dark?**
  - Chromium (Omarchy's browser and web apps, Chrome, Brave, Electron apps)
    counts only while it holds its display wake lock: Chromium takes it for
    a video that plays in a visible tab, large enough or with sound, and
    for a page's screen wake lock, as Chrome does on a Mac. Before 157
    Chromium also asks Wayland not to idle for music, downloads and calls;
    those never count. Chromium tells its display locks to
    `org.freedesktop.ScreenSaver`, which the VM's display agent serves for
    this (`busctl --user status org.freedesktop.ScreenSaver` names
    `omacvm-displays`). If another program serves that name, a video in
    Chromium before 157 does not count (the agent's log says so). While the
    agent serves it, a program installed later that wants the name (hypridle,
    a power manager) cannot take it.
  - It stays on, as on a Mac, for a music video with sound (YouTube,
    YouTube Music with its video shown) and for a large muted video that
    plays by itself in a visible tab: Chromium takes its display wake lock
    for both. Music from a plain audio player does not keep it on.
  - Chromium keeps one Wayland inhibit per process, on the window that has
    the focus when its first lock starts. So with music in one Chromium
    window and a video in another, the first window's display counts (not
    tested); and a video that starts while no Chromium window has the focus
    (an autoplay in the background) does not count until the next play.
  - Firefox was not tested: it may tell D-Bus instead of Wayland, or not
    reach either. mpv counts.
  - Hyprland window rules (Omarchy's full-screen rules, the `noidle` tag)
    and Omarchy's Stay Awake do not count: they would keep the Mac's display
    on for any full-screen window or for good.
  - In the VM: `omacvm-displays status` shows `"inhibit"`, the outputs that
    count now. QEMU's log: `OmacVM: video awake: ...` (each hold and release
    with why).
- **Where:** `app/runtime/patches/omacvm-cocoa-video-awake*.patch`,
  `src/app/guest/omacvm-displays`; tests
  `app/runtime/Tests/display/test-video-awake.sh`,
  `src/app/guest/tests/test_omacvm_displays.py`.

## 57. A pinch starts with a right click (Omarchy 4.5)

- **Symptom:** in Chrome (or another app), every pinch zoom on the Mac's
  trackpad starts with a right click: a context menu opens, then the page
  zooms. Also a middle-click paste from a three-finger tap. Trackpad
  gestures and scroll momentum on, in full screen, on Omarchy 4.5 (a new
  VM, or one moved from 4.0). Up to 3.4.0.
- **Cause:** Omarchy 4.5 leaves Hyprland's tap-to-click on (omarchy-mac's
  4.0 had it off). OmacVM's virtual trackpad gets the Mac's fingers, and
  with scroll momentum it keeps two fingers still at the start of a pinch,
  then lifts them when macOS calls it a pinch and puts them down again. That
  short still touch is a two-finger tap for libinput: a right click.
- **Fix (3.4.1):** Update VM (`omacvm apply`). OmacVM turns tap-to-click off
  for its virtual trackpad only (`~/.config/hypr/input.lua`). Taps and clicks
  still reach the VM through the VM app's pointer, as the Mac's own trackpad
  settings make them. `omacvm check` has a "trackpad taps" row. Your own
  `tap_to_click` for `apple-inc.-magic-trackpad-(omacvm)` wins (the row then
  warns); one in an `hl.device` table over several lines is not seen, and
  the one that loads later wins.
- **Before 3.4.1:** add this line to `~/.config/hypr/input.lua`:

  ```lua
  hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", tap_to_click = false })
  ```

- **Where:** `src/gestures/guest/install.sh`, `src/guest/check.sh`
  ("trackpad taps"); tests `src/gestures/guest/test-install-gestures.sh`,
  `src/tests/trackpad-taps.sh`.
