# How it works

The short version is in the [README](../README.md#how-it-works). The whole
build, every VM setting and the dead ends we hit are in
[AGENTS.md](../AGENTS.md).

## A full Omarchy, not a demo

OmacVM installs [omarchy-mac](https://github.com/omacom/omarchy-mac), the Arch
Linux ARM port of Omarchy, onto the VM's own disk: the real system, with your
user, `omarchy update` and everything Omarchy ships. It uses omarchy-mac's
**release candidate** (`rc`) packages for now, and its `stable` lane
automatically once omarchy-mac publishes one.

[try-omarchy](https://github.com/omacom/try-omarchy) is something else: a
pinned, try-it-out image. OmacVM only boots it once, as the temporary
installer that puts Arch Linux ARM onto the disk, and then removes it.

<p align="center">
  <img src="images/build.svg" alt="A terminal running omacvm: live installer, Arch Linux ARM, Omarchy from omarchy-mac, OmacVM on the Mac and in the VM, then the Omarchy desktop." width="100%">
</p>

## The Mac and the VM

<p align="center">
  <img src="images/bridge.svg" alt="The Mac's menu bar and Omarchy's bar connected over the VM network: Wi-Fi signal, AirPods connecting and Night Shift travel across as events." width="100%">
</p>

The VM and the Mac talk over the VM's private network: the Mac is `10.211.55.2`
for Parallels, `192.168.64.1` for UTM and the `.1` of Fusion's NAT network
(Fusion picks it when installed). Nothing listens anywhere else, and the VM
needs a token. OmacVM.app uses QEMU's own network instead
([how](routes/app.md#how-it-talks-to-the-mac)).

- **OmacVM Bridge** (`src/bridge/`) is a small menu-bar app. It reads the Mac's
  Wi-Fi (CoreWLAN), Bluetooth (IOBluetooth), audio (CoreAudio) and display
  (brightness, Night Shift, True Tone) and pushes every change to the VM;
  Omarchy's bar widgets and popups listen. While the VM is full screen it
  takes the media keys. It also sets the wallpaper the VM sends.
  [API and details](../src/bridge/README.md).
- **OmacVM Gestures** (`src/gestures/`) reads the trackpad's raw touches and
  replays multi-finger frames on a virtual Apple touchpad in the VM, where
  Hyprland turns them into real gestures. Each VM tells it what it wants, so a
  VM without gestures keeps macOS's own. Over the full-screen VM it also hides
  the Mac's pointer, so only Omarchy's shows.
- **The camera** (`src/camera/`): in the VM, `/dev/video42` (*Mac Camera*,
  v4l2loopback) looks like any webcam. `omacvm-camera` watches who opens it
  and only then asks the Mac for frames: from the Bridge over the VM network
  on UTM and Fusion, from OmacVM.app over a virtio port. The Mac sends 1280×720
  frames while an app reads, and turns the camera off when the last one
  stops. Parallels passes the camera itself. The code comes from
  [try-omarchy](https://github.com/omacom/try-omarchy)'s camera bridge.
- **The Mac's battery** (`src/battery/`, UTM, VMware Fusion and OmacVM.app on a
  MacBook): a small kernel module shows it to the VM as a real battery, which
  UPower and Omarchy's bar read; the Bridge (or OmacVM.app itself) sends every
  change. [How it works](../src/battery/README.md).

<p align="center">
  <img src="images/gestures.svg" alt="Three fingers swipe on a MacBook trackpad and Omarchy's workspaces slide from 1 to 2 to 3; then a pinch zooms." width="100%">
</p>

## Omanotch: the bar beside the notch

On a notched MacBook, the full-screen VM sits *below* the camera housing and
leaves a black strip across the top. [Omanotch](../src/omanotch/README.md)
streams Omarchy's real bar into that strip and gives the space back to your
windows: `notchcast` in the VM streams the bar to Omanotch.app on the Mac,
which shows it beside the notch.

It is part of OmacVM (`src/omanotch/`, with its own history; it used to be a
separate repo) and works on Parallels, UTM, VMware Fusion and OmacVM.app.
OmacVM sets it up as a feature on a MacBook with a notch (`omacvm enable
omanotch` on an existing VM): Omanotch.app on the Mac next to the Bridge and
Gestures, `notchcast` in the VM.

## Displays, kernel and memory

- **Displays** (`src/display/`, Parallels): Parallels tells the guest the size,
  refresh rate and position of every display, but Hyprland never applies it;
  `parallels-dynres` does. On UTM (`src/utm/`) the display mode is the Mac's
  built-in display below the notch, set from boot. Fusion:
  [its own page](routes/vmware-fusion.md).
- **The memory-optimized kernel** (`src/kernel/`, opt-in) is Arch Linux ARM's
  own `linux-aarch64`, rebuilt with transparent huge pages always on and
  MGLRU; the stock kernel stays in GRUB as a fallback.
- **Memory** (`src/memory/`): the VM never hands back memory it touched while
  it runs, so the guest keeps a small zram and reclaims smoothly instead of
  hoarding.

## The wallpaper

<p align="center">
  <img src="images/wallpaper.svg" alt="Switching Omarchy's theme in the VM changes the Mac's desktop wallpaper to match." width="100%">
</p>

With two VMs running, the wallpaper follows whichever changed its theme last.
