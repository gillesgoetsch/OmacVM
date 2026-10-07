# Every feature in detail

The short version is the grid at the top of the [README](../README.md).

| Feature | What it does |
|---|---|
| **The bar beside the notch** | With [Omanotch](../src/omanotch/README.md), Omarchy's real bar moves into the black strip beside the MacBook's notch, and your windows get the full height of the screen. The bar is as tall as macOS's menu bar, or exactly as tall as the notch (`defaults write ch.gillesgoetsch.omanotch flush -bool true`). OmacVM.app too: its full screen has a Space of its own, below the camera, and Omanotch fills the strip (on by default for new VMs on a Mac with a notch) |
| **Trackpad gestures** | Three- and four-finger swipes switch workspaces and pinch zooms while the VM is full screen; macOS's own Spaces swipe is off meanwhile. ⌃⌥ Esc takes you back to macOS, and from macOS back into the VM. The MacBook's trackpad, or a Magic Trackpad on a Mac mini, iMac or Studio |
| **macOS-native scroll momentum** *(experimental, but awesome)* | Two-finger scrolling on a trackpad in every direction with your Mac's own acceleration and momentum, pinch included; mice scroll one to one. On by default ([how it works](#macos-native-scroll-momentum)) |
| **The Mac's Wi-Fi in the bar** | Real network name and signal, nearby networks, and Omarchy's QR card to share the password (macOS asks you first). Joining a network and switching Wi-Fi stay on the Mac for now |
| **The Mac's Bluetooth in the bar** | Omarchy's own Bluetooth panel for the Mac's devices: connect and disconnect them, battery levels (AirPods left, right and case), Bluetooth on and off, forget a device. Pairing a new one opens the Mac's Bluetooth settings |
| **The Mac's audio in the bar** | Volume, mute, microphone, switching outputs (AirPods show up when they connect), with Omarchy's input meter |
| **The Mac's camera** | Linux apps and video calls in the browser see the Mac's camera as *Mac Camera*. It is on, green light included, only while one of them uses it. Parallels passes the camera itself; on UTM, VMware Fusion and OmacVM.app OmacVM brings it ([how](how-it-works.md#the-mac-and-the-vm)). On UTM and Fusion it comes through OmacVM Bridge, which is then installed even with the Bridge turned off |
| **External display brightness** | With the VM in front on an external display, the brightness keys set *that* display, over DDC/CI, in 32 steps (twice as fine as macOS's; Option: finer still), with Omarchy's popup. So do Omarchy's own brightness keys, `omarchy brightness display` and its monitor panel in the VM. A Studio Display, Pro Display XDR or LG UltraFine goes through macOS's own control. OmacVM.app: also in a window; Parallels, UTM and VMware Fusion: in full screen. On the built-in display nothing changes. Some displays and connections have no DDC/CI (some Macs' HDMI ports, or DDC/CI switched off in the display's own menu): there the keys do what they did before, and `omacvm check` says so. Off: `omacvm disable external-brightness` ([how it works](#external-display-brightness)) |
| **Media keys, Omarchy's popup** | Volume, mute and brightness keys drive the Mac and Omarchy shows its own on-screen display instead of macOS's. Shift with the brightness keys sets the Mac's keyboard light, with four dimmer steps below macOS's lowest (for night work), Option takes small steps, as in Omarchy |
| **Displays that follow the Mac** | Native Retina resolution and 120 Hz ProMotion. On Parallels and VMware Fusion also every external display, in exactly the arrangement you set in macOS, with Omarchy's scaling menu kept. Any Omarchy scale works on 4K, 5K, 6K and 8K displays; 2x is the sharp one ([what in-between scales cost](routes/app.md#display-scale-on-4k-5k-and-larger-displays)) |
| **The GPU, in the desktop and the browsers** | Hyprland's animations, and pages and WebGL in Chromium, Chrome, Brave and Firefox, drawn by the Mac's GPU on every route (OmacVM fixes what each app gets wrong: [UTM](troubleshooting.md#14-utm-chrome-has-no-gpu-then-webgl-comes-out-empty), [Fusion](troubleshooting.md#2-fusion-browsers-draw-everything-in-software)) |
| **Per-display workspaces** | Each display has its own workspaces 1…0, like Spaces. Unplug and they park on the Mac's screen; plug back in and they return |
| **Clipboard both ways, Cmd+V** | Copy in Omarchy, paste on the Mac and back; Cmd+V pastes everywhere, terminals included |
| **Night Shift and True Tone** | The Mac's Night Shift in Omarchy's bar, with Omarchy's own night light icon, lit while it is on. A click opens a panel like Omarchy's own: Night Shift, its strength and True Tone, all on the Mac (Super+Ctrl+N switches Night Shift directly). It replaces Omarchy's own night light, so the screen is never tinted twice |
| **Wallpaper follows the theme** | Switch Omarchy's theme or background and the Mac's desktop wallpaper follows, on every Space (macOS also shows it behind its own lock screen) |
| **The Mac's clock** | Omarchy's clock at the far right of the bar, in your Mac's menu bar format (day, date, 12 or 24 hours, seconds, language) |
| **The Mac's battery** | On a MacBook, Omarchy's battery icon and panel show the Mac's charge and charging, as on a laptop, plus time left and Omarchy's low-battery warning (not tested yet with the Mac on battery; the VM never suspends for it). Parallels does this itself; OmacVM adds it on UTM, VMware Fusion and OmacVM.app |
| **Your keyboard layout** | Taken from the Mac |
| **Chromium video on the Mac** *(OmacVM.app, on by default)* | Omarchy's own Chromium decodes H.264 and VP9 (YouTube included) on the Mac's media engine, as Google Chrome and Brave do on their own: YouTube 4K takes about half the CPU it takes otherwise. A small kernel module and a sandboxed decoder service in the VM; a video it cannot take plays on the CPU. Off: `omacvm disable chromium-video` ([details](video-decode.md#chromium-from-arch-linux-arm)) |
| **The control centre** | `omacvm` in Omarchy (the Omarchy menu, the bar's OmacVM item or a terminal; from the Mac: *Features…* in OmacVM.app's menu or `omacvm features --in-vm`) opens a floating window in the middle of the display (Escape or `q` closes it; `omacvm --here` stays in the terminal) and lists every feature with its live status: works, needs you (with the exact step on the Mac), failing, off, or not available on this Mac and why. Space switches a feature, `r` repairs it, `enter` shows its checks, version and log, `U` the updates (only the features a release changes, install now, weekly checks on or off; `o` updates the VM's own system with `omarchy update` and checks the graphics after), `!` reports a problem. The Mac does the work through a fixed list of requests to OmacVM Bridge; a failed switch puts the earlier features back. Theme colours come from the terminal, so it follows Omarchy's theme |
| **Fast network** *(experimental, OmacVM.app, off by default)* | The VM on macOS's own VM network (vmnet) instead of QEMU's built-in one: faster to and from the Mac, steady latency, an address of its own. A small system service, so macOS asks for your password once: the app's **Fast network (experimental)** switch, or `omacvm enable fast-network` ([how](routes/app.md#fast-network-experimental-off-by-default)). On it the VM is a machine on a network of the Mac (`192.168.77.0/24`, the Mac at `192.168.77.1`), as with Parallels and UTM: it reaches every service the Mac offers on all its addresses (Remote Login, File Sharing, a dev server on `0.0.0.0`), not only OmacVM's own as on QEMU's built-in network |
| **Graphics: OpenGL, Vulkan or Automatic** *(OmacVM.app, Automatic by default)* | Per VM, in the app's setup and VM window, `omacvm graphics` or the control centre. OpenGL: Omarchy and its apps draw with OpenGL on the Mac's GPU. Vulkan: the same plus Vulkan on the Mac's GPU for Vulkan apps (KosmicKrisp on macOS 26 and newer, MoltenVK before). Vulkan windows reach the screen by a copy on the Mac, faster than the VM's software copy (on KosmicKrisp since 3.0.1). Automatic is OpenGL on every Mac in 3.0.0 ([how](routes/app.md)) |
| **WebGPU and GPU compute** *(experimental, OmacVM.app, off by default)* | WebGPU (Firefox, and Chromium from its "Chromium (WebGPU)" menu entry) and OpenCL (darktable, ffmpeg's OpenCL filters, Geekbench GPU) on the Mac's GPU: `omacvm enable vulkan`, then restart the VM. WebGPU in Chromium also works with Graphics set to Vulkan alone. The VM builds a Mesa for it the first time (about 3 minutes, a 140 MB download) ([how](routes/app.md)) |
| **USB devices** *(experimental, OmacVM.app, off by default)* | Switch **USB devices (experimental)** on in the app's VM window. Then, when you plug in a device while the VM runs, OmacVM asks: connect it to the VM or keep it on the Mac? Your answer is for that plug-in only, unless you check **Always do this for this device**. **Devices…** lists the remembered devices: change what happens next time, or forget them. Nothing connects by itself. Only devices macOS doesn't use itself can go to the VM (debug probes, SDR sticks, logic analysers, phones in fastboot); keyboards, security keys, USB disks and serial adapters stay with the Mac and are never asked about ([details](usb.md)) |
| **x86 Linux apps** *(experimental, off by default)* | x86_64 Linux programs and AppImages run in the VM through box64, which translates them to ARM: `omacvm enable x86-apps`. Slower than native ARM apps; the VM builds box64 the first time (a few minutes). ([details](#x86-linux-apps)) |
| **Touch ID** *(off by default)* | sudo in Omarchy's terminals, polkit prompts and 1Password's "Unlock using system authentication" ask the Mac's Touch ID first. The Mac says what is asked ("sudo in pts/1 wants to run pacman -Syu"), and the VM gets only yes or no. On OmacVM.app it asks in a panel in your Omarchy theme over the VM's window (no click needed); on Parallels, UTM and Fusion in macOS's own dialog. Only for the person at the VM's screen with the VM in front: over SSH, from a program without a terminal, with the Mac locked or another app in front, the password prompt comes at once. Your password always works. Apps that unlock through polkit use it only with their own switch on: 1Password: Settings › Security › Unlock using system authentication (OmacVM says so once while it is off, and in the control centre's Touch ID details); Bitwarden: Settings › Security › Unlock with system authentication; KeePassXC 2.8 (beta): quick unlock, on by default. `omacvm enable touch-id` or the control centre ([how](adr/0041-touch-id.md)): it works at once, on every route, and ends with "Touch ID is ready: try sudo -v". When it falls back to the password it says why in the prompt; `omacvm check` says what is missing. A VM that OmacVM.app 3.0.3 or older started has no Touch ID port yet: shut it down and start it again once (the update to 3.0.4 does that; a restart inside the VM is not enough; the control centre says "from the next start" until then) |
| **Storage** *(OmacVM.app)* | VMs live in `~/OmacVM` or a folder you pick, an external drive too; the app moves them for you. Storage in the app's window shows the VM's size; **All VMs…** lists every VM with its size, Show in Finder and Delete. **Downloaded images** are the Omarchy images the app downloaded to set up VMs: **Remove…** frees that space (your VMs keep everything, a new VM downloads them again, the Mac's Downloads folder is not touched) ([where things are](routes/app.md#where-things-are)) |
| **Fast** | Near-native speed on Parallels; memory tuning so the VM does not hoard the Mac's RAM; btrfs snapshots you can boot from GRUB; optionally a memory-optimized kernel (transparent huge pages, MGLRU) |

<p align="center">
  <img src="images/features.svg" alt="Eight small animations: clipboard both ways with Cmd+V, Omarchy's Wi-Fi QR card after macOS asks, AirPods switching Omarchy's audio output, the Mac's wallpaper following the Omarchy theme, workspaces per display that park when unplugged, the keyboard layout taken from the Mac, the Omarchy Dock icon, and the omacvm command." width="100%">
</p>

<p align="center">
  <img src="images/displays.svg" alt="The macOS display arrangement and the Omarchy VM's monitors: when a display is moved in macOS, the VM's monitor moves the same way." width="100%">
</p>

## Full screen and the escape keys

Put the VM in full screen for the trackpad gestures, the scroll momentum and
the media keys. While it is full screen and in front, the Mac's trackpad
gestures and ⌘ shortcuts go to Omarchy, and macOS's own Spaces swipe is off.

**Every key combination to the VM** (OmacVM.app, experimental, off by
default): `defaults write org.omacvm.app macShortcuts -bool false` and a VM
restart. Then, while the VM has the keyboard (full screen or its window in
front), macOS's own shortcuts are off. Screenshots (⌘⇧3, ⌘⇧4, ⌘⇧5 and the ⌃ variants), Mission
Control, App Exposé, Show Desktop (F11, ⌘F11), Launchpad, ⌃-arrows,
Spotlight (⌘ Space), input sources (⌃ Space), ⌘ Tab, ⌘ \`, ⌘ Q/H/M/W (they
never quit or hide the VM's app) and F-keys with any modifier reach Omarchy.
The top-row keys that macOS knows by their own code (Mission Control,
Spotlight, Dictation, Do Not Disturb) arrive as F3 to F6. What stays macOS's:
**⌃⌥ Esc**, and the media keys with their rules (volume and brightness set
the Mac's, else the VM's; play, next and previous go to the VM's players).
The moment the VM's window loses the keyboard (another app, the escape
combo, a click outside its window), macOS has its shortcuts again; macOS
also turns them back on by itself if the VM's app quits or crashes, and
OmacVM does if its window stops answering. Off by default because on a Mac
mini the switch was not always handed back: `defaults delete org.omacvm.app
macShortcuts` and a VM restart go back to macOS keeping them. `omacvm check`
says which way it went.

**The globe (fn) key** (OmacVM.app): pressed on its own while the VM has the
keyboard, it goes to Omarchy and opens Omarchy's emoji picker, not macOS's
Emoji & Symbols over the VM (in Omarchy it is the key XF86Launch3, for your
own bindings). Only this one macOS shortcut is off, only while the VM has
the keyboard; fn+F1..F12, fn as a modifier and the globe key in macOS work
as before. VMs set up before 3.0.1 get the emoji picker binding with
`omacvm update` (or `omacvm apply`). `defaults write org.omacvm.app
globeKeyToVM -bool false` and a VM restart leave it with macOS.

**⌃⌥ Esc** (Control + Option + Escape) in the VM takes you
straight back to macOS: the trackpad and keys go back to macOS and the
monitor under the pointer moves to the Space beside the VM's, toward the one
you came from, with macOS's own "Move left/right a space" shortcut (System
Settings › Keyboard › Keyboard Shortcuts › Mission Control; ⌃← and ⌃→
unless you changed them) and its own animation. The VM stays full screen in
its Space. Only that monitor changes; the keyboard goes to what it shows.
No trackpad needed, so it works with a mouse too. Press **⌃⌥ Esc** there
again to go back into the VM, with the trackpad and keys. Coming back with
a swipe or Mission Control works as well. Press **⌃⌥ Esc twice** quickly
(within 0.4 s) for Mission Control; a single press never opens it. In
Mission Control, Esc closes it, and one **⌃⌥ Esc** closes it and takes you
back into the VM.

OmacVM.app's **Escape combo** setting: *This monitor* (the one under the
pointer, the default) or *All monitors*, every monitor that shows the VM. For
Parallels, UTM and VMware Fusion: `defaults write org.omacvm.gestures
EscapeSwipe all` (or `pointer`).

Never out of full screen, and one press moves one Space at most: every move
is checked, and a Space change that lands late is waited for before anything
else is tried.
If the shortcut is off or did not move the Space (macOS 15 ignores it on a
MacBook's built-in display), OmacVM swipes the Space like a trackpad. If that
did not move it either, or macOS gives no Spaces information, Omarchy shows
a short notice (which setting to turn on) and
nothing else happens; the trackpad is macOS's, so a swipe still works.
Back in, if the shortcut does not land, the VM's window comes to the front
and macOS shows its Space.

In an OmacVM.app window, ⌃⌥ Esc gives the keyboard back to macOS (the app
you were in before, else Finder); press it again in macOS to get the window
back with the keyboard.

A **Magic Mouse** in the full-screen VM: two fingers sideways swipe
Omarchy's workspaces, as four fingers on a trackpad (macOS's own Space
swipe is off meanwhile); a one-finger flick sideways goes back or forward.
Scrolling stays as macOS sends it. While a Magic Mouse is connected,
OmacVM.app shows **Magic Mouse swipe** (in the setup and the VM window):
*4 fingers* (the default; Omarchy switches workspaces with 4) or *3
fingers*. It counts from the next swipe. The control centre in Omarchy has
the same row on every route (space switches it), and on the Mac `defaults
write org.omacvm.gestures MouseSwipeFingers -int 3` (or `4`) sets it. It is one
setting for the whole Mac, all VMs included.

Media keys while a VM is in front (OmacVM.app full screen or in a window;
Parallels, UTM and Fusion full screen): volume and mute change the Mac's
output, with Omarchy's popup. When the output has no volume macOS can set
(an audio interface such as a Focusrite Scarlett), they change the VM's own
volume instead, with Omarchy's popup, not macOS's greyed-out panel.
With ⌘ held they go to the VM (OmacVM.app), never to the Mac's volume:
⌘ + mute, volume down, volume up (F10, F11, F12 on Apple keyboards) are
Omarchy's screenshot keys (window, region, display; ⌘⌥ + volume up records).
Play/pause, next and previous go to the VM's players (OmacVM.app). Brightness
keys change the display the VM is on (below).

OmacVM.app's VM takes ⌘ Tab, ⌘ Space and macOS's screenshot keys only when
macOS lets OmacVM control the computer (System Settings › Privacy & Security ›
Accessibility; Input Monitoring is not enough). When it does not, the VM's
window says so with an Allow… button, and `omacvm check` warns ("VM keyboard").

<p align="center">
  <img src="images/capture.svg" alt="A MacBook shows Omarchy full screen, marked as captured with a lock. Three fingers swipe and Omarchy changes workspace while macOS's Spaces swipe is blocked; Command+Space opens Omarchy's launcher. Control+Option+Escape opens the lock and moves the monitor one Space over to macOS with macOS's own animation; the VM stays full screen in its Space and the trackpad and keys belong to macOS. Pressed again, the monitor moves back into the VM, captured again. A setting chooses the monitor under the pointer or all monitors. A panel shows where trackpad gestures, Command shortcuts and media keys go in each moment." width="100%">
</p>

## External display brightness

macOS sets the brightness of its own displays only: the built-in one and
Apple's Studio Display and Pro Display XDR, and the LG UltraFine. Most other monitors take it over
DDC/CI, a small command channel in the display cable, which macOS does not
use (apps like MonitorControl do). OmacVM Bridge does it for the display your
VM is on:

- **Which display.** The one the VM's window is in front on: under the
  pointer when the VM covers several displays. OmacVM.app counts in a window
  too; Parallels, UTM and VMware Fusion in full screen, as for the other media
  keys. On the MacBook's own display the keys work as before.
- **How.** It reads the display's level first, then steps in 32 steps
  (macOS has 16; Option or Shift+Option: 64), and shows Omarchy's popup.
  The built-in display steps the same while a VM is in front. Held keys
  are sent at most every 50 ms, only the latest level, bigger jumps ramp
  over a few writes, and the keys never wait for the display.
  `"brightness_steps"` in the Bridge's `config.json` changes the step (8 to 100).
- **From the VM.** Omarchy drives an external monitor with `ddcutil`; OmacVM
  puts a small `ddcutil` in the VM (`/usr/local/bin/ddcutil`) that asks the
  Bridge instead: "set the brightness of the display this output is on, 0 to
  100". The Bridge checks which display that is itself and only ever touches
  an external display with a VM window on it: the VM never reaches the
  display's I2C bus. Its writes go out at most every 250 ms (some displays
  save the level on every write).
- **What works where.** `omacvm check` lists each external display: DDC/CI,
  its own control (Apple displays), or why not. No DDC/CI: on some Macs'
  built-in HDMI ports (try USB-C or DisplayPort), through some docks, or when
  DDC/CI is switched off in the display's own menu.
- **Off.** `omacvm disable external-brightness` takes it out of the VM and,
  through the Bridge's `config.json` (`external_brightness`), out of the
  keys. Off means no DDC/CI at all: the Bridge then does not even read the
  displays. The Bridge is one for all VMs, so the last `omacvm apply` decides.

## macOS-native scroll momentum

Parallels, UTM and Fusion give Linux a mouse wheel: your trackpad's two-finger
scrolling arrives as wheel steps, and the feel of macOS (acceleration,
momentum, precise slow scrolling) is gone. With this on, the full-screen
VM gets the real thing instead:

- **Your fingers**, as raw positions from the trackpad, precise to
  hundredths of a millimetre, on a virtual Apple trackpad in the VM: slow
  scrolling follows them exactly;
- **macOS's own acceleration**, blended in as you speed up;
- **macOS's own momentum** after you lift, continued on the same virtual
  fingers, so apps add no fling of their own. Measured side by side with macOS,
  the glide after a flick lands within 5–10 % of macOS's distance, with the
  same decay;
- **pinch** whenever macOS recognizes one.

It is tuned against a MacBook Pro 16" and scales itself to yours: the
trackpad's size, your scrolling direction and speed setting, and Omarchy's
display scale. Chromium-based apps (Chrome, Slack, VS Code, …) scroll about 3×
further per movement than GTK apps, so they get their own factor.

**Only a trackpad's scrolling** gets it: the built-in trackpad or a Magic
Trackpad, also one you connect later (a Mac mini with a Magic Trackpad gets
it from the first touch). OmacVM Gestures decides per scroll, by whether a
trackpad's fingers made it. A mouse wheel, a smooth-scrolling mouse
(Logitech MX and the like) and a Magic Mouse scroll one to one through the
VM app, exactly as macOS sends them, with nothing added after the wheel
stops. On a Mac with only mice it does nothing, so it is on by default.

It is **experimental**: tuned on one Mac, by feel and by measurement, over 29
rounds. The whole story, with every measurement and the analysis scripts, is in
[experiments/trackpad-scrolling.md](experiments/trackpad-scrolling.md).
Switch it off with `omacvm disable scroll-momentum`, on again with `omacvm enable scroll-momentum`.

## x86 Linux apps

Omarchy here is ARM Linux. Most apps exist for ARM, but some ship only for
x86_64 (an AppImage, a tarball, a vendor's CLI). There is no Rosetta for Linux
in OmacVM.app, UTM's QEMU VMs or VMware Fusion, so OmacVM brings its own
translator: [box64](https://github.com/ptitSeb/box64).

- **On:** `omacvm enable x86-apps` (or the control centre). The VM builds
  box64 (a pinned build of its main branch) as a pacman package and
  installs it: about 2 minutes on an M4 with 6 cores (4-5 with 4 cores), 70 MB of downloads (sources and build
  tools; the tools go again after), 76 MB on disk. From then on an x86_64
  program or AppImage starts like any other: `./Some-App-x86_64.AppImage`.
  box64 translates the app's own code and uses the VM's native libraries
  (glibc, GTK, X11, Wayland, OpenGL, SDL, FUSE) where it can.
- **Off:** `omacvm disable x86-apps` removes the package (`omacvm-box64`,
  not `box64`, so Omarchy's update does not swap it for the AUR's box64)
  and its binfmt rule. A box64 you installed yourself is left alone.
- `omacvm check` runs a tiny x86_64 program to show it works.

**Speed**, the same program and version, the x86_64 build through box64
against the native ARM build, in an OmacVM.app VM (6 cores, 8 GB) on a
Mac mini M4:

| Test | x86_64 through box64 | Native ARM | x86 in % of native |
|---|---|---|---|
| 7-Zip 26.03 benchmark, 1 thread | 8,257 MIPS | 9,589 MIPS | 86 % |
| 7-Zip 26.03 benchmark, all threads | 46,239 MIPS | 55,353 MIPS | 84 % |
| ripgrep 15.2.0, regex over 222 MB | 0.044 s | 0.017 s | 39 % |
| Node.js 24, a small JavaScript benchmark | 1.09 s | 0.21 s | 20 % |
| Start of a small program (ripgrep `--version`) | 23 ms | 0.4 ms | |
| Start of Node.js 24 (`node -e`) | 3.0 s | 0.01 s | |

Plain computing code runs at about 85 % of native speed, vector-heavy
code at under half, a JavaScript engine at a fifth; every start costs
extra, a lot for big runtimes like Node.js. Prefer the ARM build of an app
when there is one.

**Tested:** 7-Zip, ripgrep and appimagetool run. Obsidian's x86_64
AppImage (Electron) opens in 3.9 s against 0.8 s for its ARM build (on an
ARM64 Linux server with an X11 display; box64's malloc hack is on for
every program, which Electron apps need; to turn it off for one program,
give it its own entry in `~/.box64rc`, as the environment variable
`BOX64_MALLOC_HACK=0` does not win over the shared entry). Node.js runs, but crashed in 2
of 3 runs of the benchmark. **Not covered:** 32-bit x86 programs and
Windows programs (Wine).

On Parallels, keep Parallels' own Rosetta for Linux off (OmacVM's VMs
start with it off): it and box64 both claim x86_64 programs. Installing or
removing box64 restarts systemd-binfmt, which drops binfmt rules that were
added by hand and are not in a binfmt.d folder.
