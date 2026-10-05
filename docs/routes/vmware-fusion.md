# The VMware Fusion route

Everything you need to know to run OmacVM in VMware Fusion: what you need,
what OmacVM does differently there, what works, and what to do when something
breaks. The plan and test log from when the route was built is in
[experiments/vmware-fusion.md](../experiments/vmware-fusion.md).

## In short

- VMware Fusion Pro is free, also for work. No licence cap on CPUs or memory.
- Every Mac display in full screen, laid out like in macOS, Retina resolution.
  The guest reports 120 Hz.
- Stock Omarchy shows a black screen on Fusion. OmacVM builds a fixed Hyprland,
  and builds it again after every Hyprland update (10 to 20 minutes).
- Speedometer 3.1 in Chrome reached 71 % of the Mac, the best of the four ways
  ([comparison](../compare.md),
  [benchmarks](../benchmarks/README.md)).
- The newest route, next to OmacVM.app, UTM and Parallels.

## What you need

| | |
|---|---|
| VMware Fusion | 13 or newer, tested with 26.0.1 |
| Download | no Homebrew cask: Broadcom wants a sign-in. support.broadcom.com > My Downloads > VMware Fusion > the newest version (for example 26H1u1). Drag it into Applications |
| First start | Fusion asks for Accessibility: click OK, then turn VMware Fusion on in System Settings > Privacy & Security > Accessibility |
| Everything else | as for the other routes: see the README's [Requirements](../../README.md#requirements) |

## Build

```bash
omacvm build --vm-type fusion
```

The build takes about 15 minutes longer than on Parallels or UTM, mostly for
compiling Hyprland and VMware Tools in the VM. Useful options:

| Option | What |
|---|---|
| `--vm-dir PATH` | where the VM goes, an external drive for example (APFS or Mac OS Extended). Default: `~/Virtual Machines.localized`, or `$OMACVM_FUSION_DIR` |
| `--graphics-gb N` | graphics memory, taken out of the VM's own memory. Default: a quarter of the VM's memory, 1 to 8 GB (8 is Fusion's limit) |

`omacvm build --plan --json --vm-type fusion` shows what would be built, without
building it.

## What OmacVM does differently on Fusion

| Piece | Why it is needed | Where |
|---|---|---|
| Hyprland with the vmwgfx fix | without it every app dies on its first frame, the login screen first ([finding 1](../troubleshooting.md#1-fusion-black-screen-with-stock-omarchy)) | `src/fusion/guest/build-hyprland.sh`, `hyprland-vmwgfx-dmabuf.patch`, a pacman hook |
| VMware Tools (`open-vm-tools`), built in the VM | Arch Linux ARM does not package them. Fusion sends the display layout only to a guest running them; without them every Mac display shows the same screen | `src/fusion/guest/build-open-vm-tools.sh` (Arch's recipe, pinned) |
| Display layout | Hyprland ignores the positions vmwgfx suggests; this applies them, converted from pixels to points | `src/fusion/guest/omacvm-fusion-displays`, `omacvm-fusion-layout` |
| Copy and paste | VMware's agent is X11 and cannot work on Hyprland's XWayland display. It gets a private Xvfb display, synced with Wayland's clipboard | `src/fusion/guest/omacvm-fusion-clipboard` |
| Browsers on the GPU | Chromium, Chrome and Brave blocklist VMware's GPU; Firefox counts vmwgfx as software GL. OmacVM allows the GPU in all four ([finding 2](../troubleshooting.md#2-fusion-browsers-draw-everything-in-software)) | `src/fusion/guest/install.sh` |
| Public DNS during the install | Fusion's NAT DNS drops lookups under load ([finding 8](../troubleshooting.md#8-fusion-no-such-host-during-the-build)) | `src/fusion/guest/dns.sh` |
| Cmd shortcuts as Super | Fusion keeps Cmd+Space and friends for macOS; OmacVM Gestures forwards them in full screen ([finding 6](../troubleshooting.md#6-fusion-cmdspace-opens-spotlight-not-omarchy)) | `src/gestures/mac/omacvm-gestures.c` |
| The Mac's battery | Fusion gives a Linux VM no battery. OmacVM Bridge sends the Mac's and a small kernel module shows it as BAT0, so Omarchy's bar shows it | `src/battery/`, `src/bridge/mac/battery.swift` |
| The Mac's address | the Mac is `.1` on Fusion's NAT network, the gateway `.2` is Fusion. The Mac reads it from Fusion's `networking` file and passes it to the guest | `src/lib/mac.sh` (`fusion_host`), `src/cmd/apply.sh` |

## What works

| | |
|---|---|
| Desktop and apps on the GPU (SVGA3D) | ✓ |
| Every Mac display in full screen, in the macOS arrangement | ✓ (tested with three displays) |
| Window mode: Omarchy follows the window size | ✓ |
| Retina resolution, 120 Hz | ✓, 120 Hz as reported by the guest |
| OmacVM Bridge: Wi-Fi, Bluetooth, audio, Night Shift, wallpaper | ✓ |
| The Mac's camera, as *Mac Camera* | ✓ through OmacVM Bridge (`GET /camera`), as on UTM; the Bridge is installed for it also with the Bridge feature off |
| Sound, the Mac's microphone | ✓ HD Audio card (playback and capture); recording needs the microphone permission for VMware Fusion; without it the VM stops for about four minutes when an app starts recording ([finding 22](../troubleshooting.md#22-parallels-fusion-app-the-microphone-records-nothing-or-silence)) |
| Media keys and trackpad gestures in full screen | ✓ |
| Cmd shortcuts in full screen | ✓ (through OmacVM Gestures) |
| Copy and paste text, both ways | ✓, Fusion syncs when the pointer enters or leaves the VM |
| The Mac's battery in the bar | the same path as on UTM, where it is tested; not yet tested on Fusion |
| Omanotch | ✓ ([finding 4](../troubleshooting.md#4-fusion-no-hover-or-clicks-on-omanotchs-strip), [5](../troubleshooting.md#5-fusion-omanotch-cannot-find-the-mac)) |
| `omacvm check` | every line passes |
| GPU compute (Vulkan, OpenCL) | ✗ Fusion offers neither to Linux. Same on Parallels and UTM |

## How it is set up

The VM (`src/vm/fusion.sh`; created with `vmcli`, the rest is lines in the `.vmx`):

| Setting | Value | Why |
|---|---|---|
| guest OS, firmware | `arm-other6xlinux-64`, `efi` | |
| `mks.enable3d`, `svga.graphicsMemoryKB` | TRUE, a quarter of the VM's memory (1 to 8 GB) | vmwgfx with SVGA3D. Graphics memory comes out of the VM's RAM |
| `nvme0:0` | the system disk (`vmware-vdiskmanager`, growable) | the base install takes the one NVMe disk |
| `sata0:0` | the raw live image through a monolithicFlat `live.vmdk`, removed after the base install | Arch Linux ARM's live kernel boots from it, no conversion |
| `ethernet0` | `e1000e`, `nat` | ALARM's kernel has no `vmxnet3` |
| `sound.present`, `sound.virtualDev`, `sound.fileName`, `sound.autodetect` | TRUE, `hdaudio`, `-1`, TRUE | speakers and the Mac's microphone; vmcli makes no sound card (`fusion_add_sound`, also when `omacvm apply` starts an older VM) |
| `svga.numDisplays`, `svga.maxWidth`/`maxHeight`, `gui.fullScreenOnAllHostDisplays` | the Mac's display count, its arrangement in pixels, TRUE | one guest display per Mac display in full screen |

Network and tools on the Mac:

| | |
|---|---|
| The Mac's address | `.1` on Fusion's NAT network (`vmnet8`). The subnet is picked per Fusion install: `VNET_8_HOSTONLY_SUBNET` in `/Library/Preferences/VMware Fusion/networking` |
| The guest's gateway | `.2`, Fusion's NAT. Not the Mac |
| The VM's address | `/var/db/vmware/vmnet-dhcpd-vmnet8.leases`, matched by `ethernet0.generatedAddress` from the `.vmx` |
| Command-line tools | `vmcli`, `vmware-vdiskmanager`, `vmrun start/list`, all in `VMware Fusion.app/Contents/Library` |
| In the guest | DMI `sys_vendor` = `VMware, Inc.` |

## Updates

`omarchy update` works as usual. When it brings a new Hyprland, the pacman hook
builds the fixed one again, which adds 10 to 20 minutes to that update. Don't
stop it: without the fix the next login is a black screen.

Mesa 26.2.1 or newer fixes an svga dmabuf leak; `pacman -Q mesa` shows yours.

## When something breaks

| Symptom | Fix |
|---|---|
| Black screen at the login, `invalid arguments for wl_surface.attach` in the journal | stock Hyprland is back (an update the hook could not rebuild). `omacvm apply --vm NAME`, or in the VM `/usr/local/lib/omacvm/fusion/build-hyprland.sh`. Log: `/var/cache/omacvm/hyprland-vmwgfx/build.log` |
| `no such host` during a build | Fusion's NAT DNS. In the VM: `/usr/local/share/omacvm/fusion/guest/dns.sh on`, and `off` afterwards |
| Copy and paste does nothing | move the pointer into or out of the VM. `omacvm check` (one `vmtoolsd -n vmusr`, `DISPLAY=:99`) |
| Chrome is slow, WebGL off | `--ignore-gpu-blocklist` in `~/.config/chrome-flags.conf`, then quit Chrome fully |
| Pointer drifts between displays | an older OmacVM: `omacvm update` |
| `mob memory overflow` in `dmesg` | harmless |
| Testing the hook with `pacman -S hyprland` downgrades Hyprland | use `pacman -S omarchy/hyprland` |

More, with causes: [troubleshooting.md](../troubleshooting.md).

## Credits

The Hyprland fix is by Pascal-0x90,
[hyprwm/Hyprland#12966](https://github.com/hyprwm/Hyprland/discussions/12966).
There is no upstream pull request yet, so OmacVM carries it.
