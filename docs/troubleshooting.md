# Troubleshooting

Common problems first, with what to do. After them, problems whose cause is
not obvious from the symptom: each one as symptom, cause, fix and where the
fix lives. Recipes and the general failure table are in
[AGENTS.md](../AGENTS.md) (sections 6 and 7); notes for developers (security
reviews, measuring pitfalls, how the VM apps work inside) are in
[notes/findings.md](notes/findings.md).

## Common problems

- **First stop**: `omacvm check` names what is wrong and what to do.
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
  (Hyprland 0.57; OmacVM.app, UTM, Parallels): Update VM (3.2.15) or
  `omacvm update`, then log out and in
  ([50](#50-all-routes-notifications-panels-and-the-omarchy-menu-black-out-the-screen-hyprland-057)).
- **Ghostty opens no window** (OpenGL 4.3 needed, the VM gives 4.1): Update
  VM (3.2.14), then log out and in; it then draws on the VM's CPU. Alacritty
  and Kitty draw on the Mac's GPU
  ([47](#47-app-ghostty-opens-no-window-or-draws-on-the-cpu)).
- **Activity Monitor shows the VM with far more memory than you gave it**
  (OmacVM.app, e.g. 23 GB for a 12 GB VM): its graphics come on top, and
  macOS counts part of a compressed VM twice. `omacvm check` says what the
  number is made of; above the Mac's Best tier, give it less
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
  [27](#27-all-routes-black-screen-after-an-update-or-an-omacvm-job)). Update
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
  or `omacvm check`), at most three times, or when displays change. On the
  Mac's own HDMI port the Bridge sends no DDC/CI at all (3.1.17, #433: a
  display behind an HDMI to DisplayPort adapter went black at the Bridge's
  first read); `omacvm check` says so.
- **An external display went black or vanished when the Bridge started**
  (3.1.16 and before, on the Mac's HDMI port): replug it, then update. Until
  then, `omacvm disable external-brightness --vm NAME` stops all DDC/CI.
- **The VM does not lock again after an unlock** (the lock key and the
  idle lock do nothing): Omarchy's bug with Quickshell 0.3.2
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
    minutes, inside `omarchy update`);
  - one copy of the patch per Hyprland release (0.56.2, 0.57.0: the same
    change; the lines around it moved), the one that applies is used. For a
    Hyprland none applies to yet, the build says "no vmwgfx fix for Hyprland
    <version> yet" and the rest of the apply or update goes on, but the
    package's own Hyprland stays: a black screen from the next login.
    `omacvm check`'s "Hyprland" line names the version; `omacvm update` brings
    the patch once OmacVM has one. From 3.2.16 the next apply or update says
    the same without downloading Hyprland's source again (99 240 KB of
    git objects for 0.57.0) until Hyprland or OmacVM's patches change; `omacvm update` to
    3.2.16 checks once more.
- **Where:** `src/fusion/guest/build-hyprland.sh`,
  `src/fusion/guest/hyprland-vmwgfx/<release>.patch`, the hook
  `/etc/pacman.d/hooks/zz-omacvm-hyprland.hook` written by
  `src/fusion/guest/install.sh`. In the VM: state in
  `/var/lib/omacvm/hyprland-vmwgfx`, log in
  `/var/cache/omacvm/hyprland-vmwgfx/build.log`. Test:
  `src/tests/fusion-vmwgfx.sh` (each patch applies to its release; the
  skip for a recorded "none").
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
  (10-100 instead of ~550 million loops/s in the VM). UTM's and Parallels' VM
  processes are never napped.
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
  them from the trackpad itself, not from the tap. On Parallels, UTM and
  VMware Fusion the switch moves only OmacVM Gestures' and the Bridge's
  taps; how those apps take the keyboard is their own.
- **Where:** `app/runtime/patches/omacvm-cocoa-keys-last.patch`
  (`OMACVM_KEYS_LAST=1`), `app/app/Sources/OmacVMFeatures/ShareKeyboard.swift`,
  `src/gestures/mac/omacvm-gestures.c` (`shareKeyboard`),
  `src/bridge/mac/keys-model.swift` (`ShareKeyboard`); tests
  `app/runtime/Tests/keys/test-keys-last.sh`, `swift run features-tests`,
  `src/gestures/mac/test.sh` (test-tap.c), `src/bridge/mac/test-models.sh`.
  Issue [#350](https://github.com/gillesgoetsch/OmacVM/issues/350).

## 35. All routes: the bar, menus and pop-ups draw empty after an update (Qt 6.12)

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

## 37. All routes: files deleted in the VM keep their space on the Mac

- **Symptom:** you delete big files in Omarchy, but the VM's disk on the Mac
  (OmacVM.app: `disk.img`, the size in the window's Storage) does not get
  smaller.
- **Cause:** the space comes back by itself within about two minutes:
  btrfs discards what it frees (`discard=async`), QEMU punches it out of
  `disk.img`, and a trim at every Update VM and once a week
  (`fstrim.timer`) gets the rest. `disk.img` still grows up to the disk's
  set size. The space stays taken when:
  - an update snapshot still holds the files. omarchy-mac snapshots `/`
    before every `omarchy update`, so whatever you delete outside `/home`
    stays until that snapshot goes. omarchy-mac keeps 5 (up to 3.1.24, 5
    updates); OmacVM now keeps the last 2.
  - `@factory`, omarchy-mac's factory-reset copy of the system as
    installed, still holds files that updates replaced. OmacVM leaves it,
    so the factory reset keeps working.
  - the VMs folder is on a Mac OS Extended drive (no sparse files: the disk
    takes its full size there), or another file shares the blocks: an APFS
    clone such as `disk-before-resize.img` during a resize, or a Finder
    duplicate.
  - UTM, Parallels and Fusion: the VM trims the same way; whether their
    disk file gets smaller is up to the app.
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

## 46. All routes: the lock screen has no password field after an update of a locked VM

- **Symptom:** `omacvm update` or `omacvm apply` ran while the VM's Omarchy
  session was locked (3.2.12 and older; also switching Omanotch off). The
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
  Before 3.2.14, and on UTM, Fusion or Parallels (not measured there):
  `LIBGL_ALWAYS_SOFTWARE=1 ghostty`, set for Ghostty only, not for the whole
  session (GL programs started from that Ghostty's shell draw on the CPU too;
  Chromium drops the variable). A driver set by hand (`LIBGL_ALWAYS_SOFTWARE`,
  `MESA_LOADER_DRIVER_OVERRIDE`, `GALLIUM_DRIVER`) wins over OmacVM's.
- **Where:** `src/app/guest/omacvm_egl.c` (OmacVM's EGL vendor library),
  `src/guest/check.sh` ("Ghostty"); tests
  `src/app/guest/tests/egl-vendor.sh`, `src/tests/ghostty-check.sh`;
  ADR 0064 (#598).

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
  `src/tests/desktop-recover-gpu.sh`), ADR 0038's 3.2.15 amendment.

## 49. app: Activity Monitor shows the VM with far more memory than it has

- **Symptom:** Activity Monitor's Memory for OmacVM (the VM's QEMU) is far
  above the memory set for the VM: 23 GB for a 12 GB VM on a 16 GB Mac mini,
  19.3 GB at 10 GB (Chrome full screen at 5K, 2026-10-30). The Mac swaps, its
  memory pressure is yellow or red, and apps in the VM can lose their
  graphics (`omacvm check`'s "GPU contexts" row names them).
- **Cause:** the number is QEMU's footprint, and it holds more than the VM's
  memory. The VM's graphics come on top of it, from the Mac's memory as the
  VM draws (2 to 5 GB for a 5K desktop with a browser; 4.5 GB in the 12 GB
  run). And once QEMU itself touched a page of the VM (disk, graphics,
  network) and macOS compressed it, macOS counts that page twice: a 4 GB VM
  after a browser session showed 5.9 GB, 2.1 GB of it counted twice, and the
  Mac got 4.8 GB back when QEMU stopped (ADR 0062). A VM above the Mac's
  Best tier (8 GB on a 16 GB Mac) plus its graphics leaves macOS too little.
- **Check:** `omacvm check --vm NAME` has an "Activity Monitor" row while
  the VM runs: "19.3 GB for the VM: VM memory at most 10.0 GB, graphics
  3.2 GB now, the rest 6.1 GB (QEMU itself, graphics overhead and pages
  macOS counts twice while it compresses the VM)", a warning above the Best
  tier. `omacvm resources --vm NAME` says the same warning.
- **Fix:** give the VM the Best tier or less: in OmacVM.app the VM's
  General › Resources › Best, or `omacvm resources --vm NAME --resources
  best`; it applies at the VM's next start. OmacVM never lowers the setting
  by itself. Quitting big Mac apps helps too. The graphics stay outside the
  setting (Linux sees exactly the memory set), and their runaway guard stays
  at three quarters of the Mac
  ([graphics memory and VM memory](routes/app.md#graphics-memory-and-vm-memory)).
- **Where:** `src/cmd/check.sh` ("Activity Monitor"), `src/lib/footprint.py`,
  `src/lib/setup.sh` (`mem_warning`), `src/cmd/resources.sh`,
  `app/app/Sources/OmacVMWindow/CustomResources.swift`
  (`ResourceLimits.warning`), `app/app/Sources/OmacVMDesktop/GPUMemory.swift`
  (the (i)); tests `src/tests/activity-monitor.sh`, `src/tests/resources.sh`,
  `swift run window-tests`, `swift run desktop-tests`.

## 50. All routes: notifications, panels and the Omarchy menu black out the screen (Hyprland 0.57)

- **Symptom:** while an Omarchy notification, a bar panel or the Omarchy
  menu shows, the whole screen is black around its card. Opaque windows are
  fine. With `QT_QUICK_BACKEND=software` (Qt's CPU renderer) it is
  transparent. OmacVM.app, UTM and Parallels, with Hyprland 0.57
  (`hyprctl version`; released 2026-10-28): Omarchy's edge repository (the
  dev channel) since 2026-10-29, Omarchy stable once it ships 0.57, or Arch
  Linux ARM's 0.57.0 after a bare `pacman -Syu`.
  VMware Fusion is not affected (its display takes formats with alpha).
- **Cause:** Hyprland 0.57.0 turns `quirks:skip_non_kms_dmabuf_formats` on
  by default (hyprwm/Hyprland#15803). Hyprland then offers apps only the
  buffer formats a display plane takes, and virtio-gpu's plane (OmacVM.app,
  UTM, Parallels) takes XRGB8888 only: no format with alpha is left. Mesa
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
- **Where:** `src/guest/omacvm_vm.lua` (Hyprland settings every route needs),
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
