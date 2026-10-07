# OmacVM.app

Omarchy in a VM on an Apple Silicon Mac, in one app. No Parallels, UTM or
VMware Fusion: the app brings its own QEMU (Apple's Hypervisor framework,
GPU through VirGL).

Part of [OmacVM](../README.md): this folder is the app, `../src` is OmacVM's
VM side the app carries. Get the app with `omacvm build --vm-type app`, or
as `OmacVM-<version>.zip` from OmacVM's
[releases](https://github.com/gillesgoetsch/omacvm/releases).

## Build

Needs macOS 15 and Xcode's Command Line Tools.

```sh
git clone https://github.com/gillesgoetsch/omacvm && cd omacvm/app
scripts/build-app.sh          # dist/OmacVM.app
open dist/OmacVM.app
```

The first build compiles QEMU (about 70 seconds) and the UEFI firmware (about
2 minutes, 800 MB of downloads, kept in `runtime/.build/edk2`). The app takes
`../src` as committed: the build stops when `src/` has uncommitted changes.

The firmware is edk2 as QEMU ships it (edk2-stable202408, QEMU's own build
flags), built on the Mac by `runtime/build-edk2.sh`: a VM starts with
Omarchy's logo instead of TianoCore's, and otherwise sees the same firmware
(see `runtime/README.md`). When that build or its test fails, the app gets
QEMU's prebuilt firmware (TianoCore logo) and the build says so;
`OMACVM_FIRMWARE=qemu scripts/build-app.sh` asks for it.
`Contents/Resources/firmware/firmware-source` says which one an app has, and
`omacvm check` shows it for a running VM.

## Release

```sh
export OMACVM_SIGN_ID=<Developer ID identity, name or SHA-1>
scripts/build-app.sh --release      # stops unless the whole repo is committed
scripts/package-release.sh          # dist/OmacVM-<version>.zip and .sha256
```

A release build has KosmicKrisp (Vulkan on macOS 26 and newer; Graphics'
Automatic uses it): it needs Xcode 26 and Homebrew's `llvm`, `bison`,
`spirv-llvm-translator` and `spirv-tools` on the release Mac
(`runtime/build-kosmickrisp.sh --check` lists what is missing), about 13 MB
in the app, its licence notice in `Contents/Resources/licenses`.
`OMACVM_RUNTIME_KOSMICKRISP=0` and `OMACVM_RELEASE_NO_KOSMICKRISP=1` leave
it out (MoltenVK only).

With `OMACVM_SIGN_ID` the app, its QEMU and QEMU's libraries are signed with
that Developer ID, the hardened runtime and a timestamp; QEMU gets
`runtime/qemu-hvf.entitlements` (Hypervisor, microphone), the app
`app/OmacVM.entitlements` (microphone). Without it the build is signed ad hoc,
and `package-release.sh` refuses it: a release needs a Developer ID (its team
goes into the signed update feed, see [docs/release-keys.md](../docs/release-keys.md)).
It also refuses a history that holds `runtime/.build-runtime.log` (local home
paths, filtered out of the history): rebase a branch made before that onto
the filtered history first.
Check the unzipped app with `codesign --verify --deep --strict` and
`spctl -a -vv -t exec`: until it is notarized, spctl says "Unnotarized
Developer ID", and a browser download needs Open Anyway the first time.
Notarizing (not part of the scripts yet): `xcrun notarytool submit
dist/OmacVM-<version>.zip --keychain-profile <profile> --wait`, then
`xcrun stapler staple dist/OmacVM.app` and `scripts/package-release.sh` again.

The version is OmacVM's (`../src/VERSION`). Upload both files to the GitHub
release `v<version>`: `omacvm build --vm-type app` and `omacvm update`
download them from there. `package-release.sh` also writes the update feed
`OmacVM-appcast.json` and its `.sig` (`scripts/appcast.sh`, signed with the
release key from the Keychain: [docs/release-keys.md](../docs/release-keys.md));
upload them too. Publish as a pre-release
first and try its zip; installed apps see it once the release is marked
latest. (Release builds ignore `OMACVM_APPCAST_URL`; the update itself is
tested with `scripts/dev/self-update-test.sh`.)

## Updates

The app updates itself ([ADR 0033](../docs/adr/0033-app-self-update.md)):

- Once a week it looks at the latest release's update feed (signed with
  OmacVM's main or spare release key). A newer version is downloaded and
  checked: size and SHA-256 from the feed, then the app and its QEMU signed
  with a Developer ID of a team the feed names. The window then offers it: What's New,
  Skip This Version, Update to X…. **Check Now** next to the weekly switch (or
  *OmacVM › Check for Updates…*) asks right away, also with weekly checks off.
- A VM that runs from the app is never replaced under it. With the VM
  running, *Update to X…* (or `u` in the VM's control centre) shuts the VM
  down cleanly, updates, restarts the app and starts the VM again, after one
  confirm. A VM that is still running after 3 minutes stops the update;
  forcing it off needs a second confirm. A VM started another way (the CLI)
  makes the update wait until nothing runs from the app any more.
- The new version must start (its QEMU too) within 90 s, or the old one
  comes back by itself and that version is skipped. The previous version is
  kept for one step back: *OmacVM › Go Back to <version>…*.
- A copy installed under its own name keeps it.
- *Check for updates once a week* in the window switches it off: no checks,
  no messages. It is the same switch as in OmacVM's control centre
  (`update_checks` in `~/Library/Application Support/omacvm/settings.json`).
- When the update goes in because you quit or shut the VM down, the new
  version starts in the background only to check itself: no window pops up.
  The next start says it updated.
- Files and log, per copy of the app:
  `~/Library/Application Support/OmacVM/Updates/org.omacvm.app/<name>-<hash>/`
  (`update.log`, `previous/`, `staged/`). An app on another disk keeps
  `previous/` next to itself in `.omacvm-updates/`, so the swap never copies
  across disks.
- Not notarized yet: the app downloads without a quarantine flag, so macOS
  does not ask; the feed signature and the Developer ID check stand in for it.

Tests: `cd app && swift run update-tests` (CI), and on a Mac
`scripts/dev/self-update-test.sh` with a test build
(`scripts/build-app.sh --name "OmacVM SU-test" --id org.omacvm.sutest`): its
own bundle id, settings and VMs folder, a local feed with a test key,
nothing in /Applications.

## Status

Works: setup, VM build (10 to 30 minutes, 8 on an M4 Max, plus a 1.4 GB
download the first time), window that Omarchy follows (native resolution,
120 Hz), full screen in its own Space with the bar beside the notch (Omanotch), clipboard both ways, sound and the microphone,
the Mac's camera (on only while a Linux app reads it), WebGL in Chromium,
Chrome, Brave and Firefox, video decoding on the Mac's media engine (Google
Chrome, Brave, Firefox, mpv, FFmpeg, GStreamer apps; [docs](../docs/video-decode.md)), clean shutdown on Quit, pause on Mac sleep,
install under a chosen name, the Mac's battery in Omarchy's bar, ⌘ keys as Super in full screen (through OmacVM
Gestures, which the build installs on the Mac with the other helpers),
every Mac display in full screen (one window and one Omarchy output per
display, placed as in macOS; "Use external displays" in Omarchy's display
panel switches it off), tested on a real monitor.

Not confirmed on this route yet: the Bridge's features (Wi-Fi, Bluetooth,
media keys) and trackpad gestures.

Needs a person: the permissions OmacVM's Mac helpers ask for; the app needs no
Accessibility of its own.

## What the app does

1. Asks for a VM name, your user and password, resources and where the disk goes.
2. Builds the VM (10-30 minutes): try-omarchy's release boots as a temporary
   live system, OmacVM's installers put Arch Linux ARM (btrfs, GRUB) and
   Omarchy (omarchy-mac) on the disk, then OmacVM's VM side.
3. Starts it: QEMU shows Omarchy in a window that follows its size. Quit
   shuts the VM down cleanly; the Mac's sleep pauses it.
4. Before a start, the window has a Resources picker (the same tiers as the
   create screen): it writes `CPUS` and `MEM_MB` into the VM's `vm.env`,
   which applies on the next start. `omacvm resources --vm NAME` does the same
   from the terminal.

The VM is a normal install: `omarchy update` and snapshots work.

## Layout

| Path | What |
|---|---|
| `runtime/` | QEMU build, from try-omarchy, with OmacVM's patches; the UEFI firmware (`build-edk2.sh`) |
| `app/` | the launcher (Swift) |
| `scripts/create-vm.sh` | builds a VM, headless |
| `scripts/build-app.sh` | builds the app |
| `scripts/package-release.sh` | zips the built app for a release |
| `scripts/appcast.sh` | the release's signed update feed |
| `scripts/update-swap.sh` | swaps in an update, puts the old app back if the new one does not start |
| `app/Sources/OmacVMUpdate` | the update's checks (feed, signatures, schedule), tested by `update-tests` |
| `../src` | OmacVM: the installers and the VM side, `app` route |

Licences: `THIRD_PARTY_NOTICES.md`. QEMU is GPL-2.0: its build scripts and
every patch the app's QEMU is built with are in `runtime/` of this public
repo, which is the source offer for the QEMU in the app.
