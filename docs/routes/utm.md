# The UTM route

How OmacVM runs in UTM: which UTM you need, why, and what to keep in mind.
UTM's VM settings, failure modes and dead ends are in
[AGENTS.md](../../AGENTS.md) (sections 4, 7 and 8).

## In short

- Free and open source.
- One display. The display mode is set at boot and does not change live.
- OmacVM brings the Mac's camera and battery through OmacVM Bridge.

## What you need: UTM 5

UTM 5 is still a beta (tested with 5.0.6):

```bash
brew install --cask utm@beta
```

Or UTM.dmg from the newest "Beta" release on
[UTM's GitHub](https://github.com/utmapp/UTM/releases).

UTM's website, the App Store and `brew install --cask utm` all give UTM 4.7,
which does not work here: its GPU acceleration leaves Linux apps as black
windows, and only software rendering works
([omarchy-arm-utm#7](https://github.com/ggalancs/omarchy-arm-utm/issues/7)).
Already have 4.7 from Homebrew? Your VMs stay when you switch:

```bash
brew uninstall --cask utm && brew install --cask utm@beta
```

OmacVM uses UTM 5's OpenGL path (VirGL), which renders Linux desktops, unlike
its new Vulkan one, and UTM's default renderer, which gives Chrome in the VM
the GPU. OmacVM sets both.

Everything else is as for the other routes: Xcode Command Line Tools,
Homebrew, `zstd` and `e2fsprogs` (see the README's
[Requirements](../../README.md#requirements)).

## Build

```bash
omacvm build --vm-type utm
```

The VM goes into UTM's own library, which is inside UTM's data folder on the
Mac's internal disk. To put it somewhere else, an external drive for example
(APFS or Mac OS Extended), answer the build's "Where should the VM go?" with
another folder, or pass `--vm-dir PATH`:

```bash
omacvm build --vm-type utm --vm-dir /Volumes/MyDrive/VMs
```

### UTM on an external drive

UTM is sandboxed: it cannot keep its whole library elsewhere (with its
`Documents` folder replaced by a link to another drive, UTM does not start:
"Documents is not a directory"). But UTM runs any VM you open from another
place (File > Open, or `open -a UTM Name.utm`) and keeps it in its list, by a
bookmark. That is what `--vm-dir` uses:

1. The installer image and its work files are written into that folder
   (not into `~/Library/Caches`) and removed when they are done.
2. UTM makes the VM in its own folder with only an empty system disk (a few
   hundred KB), exports it into that folder, deletes its own copy and opens
   the exported one.
3. The installer image is added to that VM (UTM copies it into the VM, on
   the drive), and the build goes on as usual.

What you need:

- **About 30 GB free on the drive** (the build checks it and stops before
  anything is made). The VM, its installer and the work files all go
  there, not on the Mac's own disk.
- The drive formatted **APFS or Mac OS Extended** (Disk Utility can erase it
  as APFS). exFAT and FAT drives are refused.
- The drive connected before you open UTM, and never unplugged while the VM
  runs. If UTM shows the VM as missing, the drive is not connected: connect
  it and start the VM again.
- On a removable drive (an SD card, a USB stick) macOS asks once whether
  Terminal may access files on it: allow it.

A prebuilt UTM VM always goes into UTM's library; with `--vm-dir` the build
makes the VM here instead.

Run the build in Terminal on the Mac, not over SSH: OmacVM drives UTM
through AppleScript, and macOS asks once whether Terminal may control UTM.
Allow it.

UTM keeps its VMs in its own data folder, and macOS (14 and later) asks
before another app reads there. OmacVM reads it only when you run omacvm in
a terminal (or act on a UTM VM), never from the Bridge or a script, and
gives up after 2 seconds. If macOS asks whether Terminal may access data
from other apps, allow it; until then a stopped UTM VM shows as
"unknown (UTM data not readable)". If it was answered Don't Allow, a build
still makes the VM, but cannot set UTM's speed settings (it says so). OmacVM lists UTM VMs only once you use
UTM with it on this Mac (`OMACVM_UTM=1` lists them anyway).

## Keep UTM in the foreground

Start UTM from the Dock or Spotlight, so it is in the foreground app list.
UTM launched in the background runs the VM several times slower.

## Camera, sound and battery

- **Camera**: comes through OmacVM Bridge, which is installed for it even with
  the Bridge feature off. macOS asks for the camera for *OmacVM Bridge* the
  first time a Linux app uses it. With the Bridge off, the Bridge still asks
  for Location Services, Accessibility and Bluetooth: say no, the camera does
  not need them.
- **Microphone**: belongs to UTM; it asks the first time.
- **The Mac's battery**: through OmacVM Bridge and a small kernel module
  ([how it works](../../src/battery/README.md)).

## How it is set up

- The Mac is `192.168.64.1` on UTM's shared network.
- The display mode (`src/utm/`) is the Mac's built-in display below the notch,
  set from boot.
- More on every piece: [how it works](../how-it-works.md). UTM-specific
  findings: [troubleshooting](../troubleshooting.md) (12, 14, 20, 21).
