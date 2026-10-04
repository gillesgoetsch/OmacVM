# Every feature in detail

The short version is the grid at the top of the [README](../README.md).

| Feature | What it does |
|---|---|
| **The bar beside the notch** | With [Omanotch](../src/omanotch/README.md), Omarchy's real bar moves into the black strip beside the MacBook's notch, and your windows get the full height of the screen. The bar is as tall as macOS's menu bar, or exactly as tall as the notch (`defaults write ch.gillesgoetsch.omanotch flush -bool true`). OmacVM.app does it on its own |
| **Trackpad gestures** | Three- and four-finger swipes switch workspaces and pinch zooms while the VM is full screen; macOS's own Spaces swipe is off meanwhile. ⌃⌥⌘Esc hands the trackpad back to macOS. The MacBook's trackpad, or a Magic Trackpad on a Mac mini, iMac or Studio |
| **macOS-native scroll momentum** *(experimental, but awesome)* | Two-finger scrolling in every direction with your Mac's own acceleration and momentum, pinch included. Off unless you choose it ([how it works](#macos-native-scroll-momentum)) |
| **The Mac's Wi-Fi in the bar** | Real network name and signal, nearby networks, and Omarchy's QR card to share the password (macOS asks you first). Joining a network and switching Wi-Fi stay on the Mac for now |
| **The Mac's Bluetooth in the bar** | Omarchy's own Bluetooth panel for the Mac's devices: connect and disconnect them, battery levels (AirPods left, right and case), Bluetooth on and off, forget a device. Pairing a new one opens the Mac's Bluetooth settings |
| **The Mac's audio in the bar** | Volume, mute, microphone, switching outputs (AirPods show up when they connect), with Omarchy's input meter |
| **The Mac's camera** | Linux apps and video calls in the browser see the Mac's camera as *Mac Camera*. It is on, green light included, only while one of them uses it. Parallels passes the camera itself; on UTM, VMware Fusion and OmacVM.app OmacVM brings it ([how](how-it-works.md#the-mac-and-the-vm)). On UTM and Fusion it comes through OmacVM Bridge, which is then installed even with the Bridge turned off |
| **Media keys, Omarchy's popup** | Volume, mute and brightness keys drive the Mac and Omarchy shows its own on-screen display instead of macOS's. Shift with the brightness keys sets the Mac's keyboard light, with three dimmer steps below macOS's lowest, Option takes small steps, as in Omarchy |
| **Displays that follow the Mac** | Native Retina resolution and 120 Hz ProMotion. On Parallels and VMware Fusion also every external display, in exactly the arrangement you set in macOS, with Omarchy's scaling menu kept |
| **The GPU, in the desktop and the browsers** | Hyprland's animations, and pages and WebGL in Chromium, Chrome, Brave and Firefox, drawn by the Mac's GPU on every route (OmacVM fixes what each app gets wrong: [UTM](troubleshooting.md#14-utm-chrome-has-no-gpu-then-webgl-comes-out-empty), [Fusion](troubleshooting.md#2-fusion-browsers-draw-everything-in-software)) |
| **Per-display workspaces** | Each display has its own workspaces 1…0, like Spaces. Unplug and they park on the Mac's screen; plug back in and they return |
| **Clipboard both ways, Cmd+V** | Copy in Omarchy, paste on the Mac and back; Cmd+V pastes everywhere, terminals included |
| **Night Shift and True Tone** | The Mac's Night Shift in Omarchy's bar, with Omarchy's own night light icon, lit while it is on. A click opens a panel like Omarchy's own: Night Shift, its strength and True Tone, all on the Mac (Super+Ctrl+N switches Night Shift directly). It replaces Omarchy's own night light, so the screen is never tinted twice |
| **Wallpaper follows the theme** | Switch Omarchy's theme or background and the Mac's desktop wallpaper follows, on every Space (macOS also shows it behind its own lock screen) |
| **The Mac's clock** | Omarchy's clock at the far right of the bar, in your Mac's menu bar format (day, date, 12 or 24 hours, seconds, language) |
| **The Mac's battery** | On a MacBook, Omarchy's battery icon and panel show the Mac's charge and charging, as on a laptop, plus time left and Omarchy's low-battery warning (not tested yet with the Mac on battery; the VM never suspends for it). Parallels does this itself; OmacVM adds it on UTM, VMware Fusion and OmacVM.app |
| **Your keyboard layout** | Taken from the Mac |
| **Fast network** *(experimental, OmacVM.app, off by default)* | The VM on macOS's own VM network (vmnet) instead of QEMU's built-in one: faster to and from the Mac, steady latency, an address of its own. A small system service, so macOS asks for your password once: `omacvm enable fast-network` ([how](routes/app.md#fast-network-experimental-off-by-default)) |
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

**⌃⌥⌘ Esc** (Control + Option + Command + Escape) hands the trackpad back to
macOS (Omarchy shows a notification), so you can swipe to your other Spaces.
Press it again, or come back to the full-screen VM, to hand it to Omarchy
again. Volume and brightness keys always change the Mac, with Omarchy's popup
while you are in the VM.

<p align="center">
  <img src="images/capture.svg" alt="A MacBook shows Omarchy full screen, marked as captured with a lock. Three fingers swipe and Omarchy changes workspace while macOS's Spaces swipe is blocked; Command+Space opens Omarchy's launcher. Control+Option+Command+Escape opens the lock: Omarchy shows a notification, the trackpad belongs to macOS again and a four-finger swipe moves to the Mac's other Space. Back on the full-screen VM it is captured again. A panel shows where trackpad gestures, Command shortcuts and media keys go in each moment." width="100%">
</p>

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

It is **experimental**: tuned on one Mac, by feel and by measurement, over 29
rounds. The whole story, with every measurement and the analysis scripts, is in
[experiments/trackpad-scrolling.md](experiments/trackpad-scrolling.md).
Try it with `omacvm enable scroll-momentum`, go back with `omacvm disable scroll-momentum`.
