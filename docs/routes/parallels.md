# The Parallels route

How OmacVM runs in Parallels Desktop: what you need, the one setting to change
after the build, and what Parallels does itself. The VM settings, failure
modes and dead ends are in [AGENTS.md](../../AGENTS.md) (sections 4, 7 and 8).

## In short

- Paid. The least to set up, and the fastest 3D of the four apps
  ([comparison](../compare.md)).
- Every Mac display in full screen, in your macOS arrangement, with live
  resolution changes.
- Parallels passes the Mac's camera and battery itself.

## What you need

| | |
|---|---|
| Parallels Desktop | 19 or newer |
| Edition | Standard gives a VM at most 4 CPUs and 8 GB. Pro (or the trial) allows up to 18 CPUs and 128 GB |
| Get it | buy it, or start the trial, at [parallels.com](https://www.parallels.com) |
| Everything else | Xcode Command Line Tools, Homebrew, `zstd` and `e2fsprogs`, as in the README's [Requirements](../../README.md#requirements) |

A fresh Parallels without a licence yet makes the build ask which edition you
plan on (the trial is Pro), so it can size the VM. OmacVM stays within the
Standard limits on Standard. For scripts: `--parallels-edition standard|pro`.

## Build

```bash
omacvm build --vm-type parallels
```

Parallels Desktop may show its own windows during the build (sign in,
continue the trial): click through them, the build waits. The VM can go into
any folder, an external drive too (APFS or Mac OS Extended), with `--vm-dir PATH`.

## After the build: let Cmd reach Omarchy

Parallels' Linux keyboard profile turns Cmd+C/V/X into Ctrl before the VM sees
them. The build empties that profile when no VM is running (otherwise: quit
Parallels Desktop and run `src/mac/parallels-shortcuts.sh`).

Then set *macOS System Shortcuts › Send macOS system shortcuts* to **Always**,
so Cmd+Space and friends reach Omarchy. Parallels keeps this setting to
itself, so OmacVM can't set it. The build shows a macOS alert with this guide
until it is set (`src/mac/parallels-system-shortcuts.sh` brings it back), and
`omacvm check` tells you whether both are done.

<p align="center">
  <img src="../parallels-shortcuts.svg" alt="Where to click in Parallels Desktop: press Cmd+comma, click Shortcuts, then macOS System Shortcuts, then set Send macOS system shortcuts to Always. Afterwards Cmd+Space in the VM opens Omarchy's launcher." width="100%">
</p>

## What Parallels does itself

- **Camera**: Parallels passes the Mac's camera to the VM. macOS asks for the
  camera for *Parallels Desktop* the first time a Linux app uses it.
- **Microphone**: belongs to Parallels Desktop. Check System Settings ›
  Privacy & Security › Microphone, or the VM records silence or nothing
  ([finding 22](../troubleshooting.md#22-parallels-fusion-app-the-microphone-records-nothing-or-silence)).
- **The Mac's battery** in Omarchy's bar: Parallels' own.

## How it is set up

- The Mac is `10.211.55.2` on Parallels' shared network; the VM talks to
  OmacVM's helpers there.
- **Displays** (`src/display/`): Parallels tells the guest the size, refresh
  rate and position of every display, but Hyprland never applies it;
  `parallels-dynres` does.
- More on every piece: [how it works](../how-it-works.md).
