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

The VM goes into UTM's own library; UTM has no `--vm-dir`.

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
