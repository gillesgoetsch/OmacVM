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
  if ⌃⌥ Esc left you in the VM without the trackpad, press it again. Check the
  Accessibility and Input Monitoring permissions of *OmacVM Gestures*
  (`omacvm check` names a missing one; the helpers' logs say
  "permissions: ... MISSING").
- **⌃⌥ Esc does nothing at all**: on Parallels, UTM or Fusion the Mac's
  OmacVM Gestures may be older than 3.0.0: `omacvm update` (OmacVM.app
  brings its own). `omacvm check` names a missing permission.
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
  macOS can set (an audio interface). With an OmacVM.app VM in front the keys
  change the VM's own volume instead; with Parallels, UTM and Fusion they stay
  macOS's. A VM
  OmacVM did not set up may need `omacvm update --vm NAME` once: the Mac lets in
  only VMs whose trackpad daemon says the Bridge's token.
- **The brightness keys do not change the external display**: the VM must be
  in front on it (Parallels, UTM and Fusion: in full screen). `omacvm check`
  lists each external display: "not settable" means it does not take DDC/CI
  on this connection. Switch DDC/CI on in the display's own menu, or try
  another port: some Macs' built-in HDMI ports (M1/M2 Mac mini) and some docks
  pass no DDC/CI (USB-C or DisplayPort usually do). A display that was asleep
  when the Bridge looked is asked again after a minute (by the keys, the VM
  or `omacvm check`) or when displays change.
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
| 24 | app | [A scale like 1.6 on a 5K display turns the VM black and flickering](#24-app-a-scale-like-16-on-a-5k-display-turns-the-vm-black-and-flickering) |
| 25 | app | [The sound crackles while the VM or the Mac is busy](#25-app-the-sound-crackles-while-the-vm-or-the-mac-is-busy) |
| 26 | app | [The VM does not start (no window), or freezes when sound starts](#26-app-the-vm-does-not-start-no-window-or-freezes-when-sound-starts) |
| 29 | app | [No sound at all after a start](#29-app-no-sound-at-all-after-a-start) |

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
  trackpad handed back with ⌃⌥ Esc, or a key posted by a script below the
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
  macOS says its memory is critical, or would be nearly used up while it
  warns (`app/runtime/patches/virgl-darwin-memory-pressure.patch`). The one
  fixed guard, three quarters of the Mac's memory, only stops a runaway VM.
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
  `app/app/Sources/OmacVM/Runner.swift` (`audioClassic`), `src/cmd/check.sh`,
  the measurement tools in `app/runtime/Tests/audio/`, ADR 0036; in the
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

## 27. All routes: black screen after an update or an OmacVM job

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
  (the control centre asks in its own dialog); `omacvm apply` never runs it.
  An update that shows nothing new for 10 minutes or runs over 40 is
  stopped.
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
