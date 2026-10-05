<h1 align="center">OmacVM</h1>

<h3 align="center">Omarchy in a VM on your Mac, feeling native</h3>

<p align="center">One command builds the VM, in its own app OmacVM.app, UTM, VMware Fusion or Parallels Desktop. Then your Mac's Wi-Fi, Bluetooth, sound, keys, trackpad, displays, Night Shift and wallpaper all work in Omarchy.</p>

<p align="center">
  <b>With <a href="src/omanotch/README.md">Omanotch</a></b>: Omarchy's real bar beside the MacBook's notch, where the VM leaves a black strip.
</p>

```bash
curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash
```

<p align="center">Using a coding agent? <a href="docs/agents.md">Copy the prompt for it</a>.</p>

<p align="center">
  <img src="docs/images/hero.svg" alt="Animated overview. A MacBook runs Omarchy full screen; the VM leaves a black strip beside the notch. The VM's invisible notch monitor appears above, Omanotch streams Omarchy's real bar into the strip piece by piece, the windows grow to full height, the pointer glides into the strip and a click on the clock opens Omarchy's calendar. Then, with the macOS host shown above the VM and OmacVM Bridge between them: the Mac's Wi-Fi and volume arrive in Omarchy's bar; volume and brightness keys drive the Mac while Omarchy shows the popup; three- and four-finger swipes and pinch arrive through OmacVM Gestures while macOS's Spaces swipe is off; Super+Ctrl+N switches the Mac's Night Shift; an external display joins in the macOS arrangement." width="100%">
</p>

| What you get in Omarchy | How you run it |
|---|---|
| 🔳 **Omanotch**<br>Omarchy's real bar beside the MacBook's notch, where the VM leaves a black strip. | 🍎 **Standalone app, UTM, VMware Fusion or Parallels**<br>Pick one, OmacVM sets it up the same way. |
| 🎬 **Hardware video decoding**<br>YouTube 4K on the Mac's media engine, not the CPU. | 💻 **Runs on M1, M2, M3, M4, M5, M6**<br>Adapts to notch, ProMotion, HDR and missing hardware on its own. |
| 🎮 **Real GPU performance**<br>Vulkan, WebGPU and OpenCL in the VM. *(coming with 2.9.0)* | 🛠️ **A setup script that fits your needs**<br>Pick the app, CPUs, memory, disk, keyboard, user and every feature; change them later anytime. |
| 🖥️ **Multiple external monitors**<br>Every display in your macOS arrangement, hardware accelerated. *(coming with 2.8.0)* | ⏱️ **Ready in 5 minutes**<br>Download a prebuilt VM, or build it fully yourself. |
| 👆 **Mac trackpad gestures**<br>2, 3 and 4 finger swipes and pinch zoom, plus optional macOS-like momentum scrolling. | 🎨 **Theme and wallpaper sync**<br>Your Omarchy theme and wallpaper carry over to macOS. |
| ⌨️ **Mac keys, fully Omarchy**<br>Cmd works as Super, macOS shortcuts stay out of the way. | 🔋 **Optimized for battery**<br>Measured power draw on every route, tuned to stay close to macOS. |
| 📶 **Wi-Fi, audio and battery from the Mac**<br>The bar shows your real networks, sound devices and battery. | 🔀 **Features on or off anytime**<br>`omacvm features` switches them on an existing VM. |
| 🔊 **Native volume and brightness**<br>The Mac's keys with Omarchy's own popups. | 🩺 **One check for everything**<br>`omacvm check` tells you what works and what to fix. |
| 💡 **Keyboard backlight**<br>Shift+F1/F2 dims and brightens the Mac's keyboard, like Omarchy on a laptop. | 🔄 **One command to update**<br>`omacvm update` brings the Mac side and the VM up to date. |
| 📷 **Camera and microphone**<br>Video calls in the VM. | 🔐 **Token-secured bridge to the Mac**<br>Only your own VM can talk to the Mac side, proven with a secret token. |
| 📋 **Copy and paste, both ways**<br>Plus Night Shift, True Tone and the Mac's clock format. | |

**[See the full compatibility list per app below](#which-app), or [every feature in detail](docs/features.md).**

<p align="center">
  <img src="docs/images/demo.webp" alt="Filmed on a MacBook Pro: a swipe from macOS into the full-screen Omarchy VM, Omarchy's bar beside the notch, and the Mac's Wi-Fi, sound and battery in Omarchy's bar, then a swipe to the next workspace." width="100%">
</p>

<a name="four-ways-parallels-utm-vmware-fusion-or-omacvmapp"></a>

### Which app?

**OmacVM.app** is the recommended way: free, open source, and the only one with hardware video and the full GPU. **UTM** is the free classic. **VMware Fusion** is free and supports external monitors. **Parallels** is the most polished, but paid.

| | OmacVM.app | UTM | VMware Fusion | Parallels |
|---|:---:|:---:|:---:|:---:|
| **Price** | free | free | free | paid |
| **Open source** | ✅ | ✅ | ❌ | ❌ |
| Omanotch | ✅ | ✅ | ✅ | ✅ |
| Hardware video decoding | ✅ | ❌ | ❌ | ❌ |
| GPU in desktop and browsers | ✅ | ✅ | ✅ | ✅ |
| Vulkan, WebGPU, OpenCL | 🔜 2.9.0 | ❌ | ❌ | ❌ |
| External monitors | 🔜 2.8.0 | ❌ | ✅ | ✅ |
| 120 Hz ProMotion | 🔜 2.9.0 | ✅ | ✅ | ✅ |
| Trackpad gestures | ✅ | ✅ | ✅ | ✅ |
| Momentum scrolling (optional) | ✅ | ✅ | ✅ | ✅ |
| Cmd as Super | ✅ | ✅ | ✅ | ✅ ¹ |
| Wi-Fi, Bluetooth, audio from the Mac | ✅ | ✅ | ✅ | ✅ |
| Battery in the bar | ✅ | ✅ | ✅ | ✅ |
| Volume and brightness | ✅ | ✅ | ✅ | ✅ |
| Keyboard backlight (Shift+F1/F2) | ✅ | ✅ | ✅ | ✅ |
| Camera and microphone | ✅ | ✅ | ✅ | ✅ |
| Copy and paste | ✅ | ✅ | ✅ ² | ✅ |
| Theme and wallpaper sync | ✅ | ✅ | ✅ | ✅ |
| Prebuilt VM (5 min) | 🔜 ³ | ✅ | ✅ | ✅ |
| CPU and memory limit | none | none | none | 4 CPUs, 8 GB on Standard |

¹ after one setting in Parallels · ² when the pointer crosses the VM's edge · ³ coming soon; until then the app builds its VM in 10 to 30 minutes

<p align="center">
  <img src="docs/images/benchmarks.svg" alt="Bar chart: each route as a share of the Mac, OmacVM.app first, then UTM, VMware Fusion, Parallels. CPU all cores (Geekbench 7): 99, 89, 99, 96 percent. Web apps (Speedometer 3.1): 70, 52, 71, 67. Browser graphics (WebGL Aquarium): 22, 26, 38, 25. Browser overall (Basemark Web 3.0): OmacVM.app no full-screen run yet, 67, 78, 75. GPU compute (Geekbench 7 GPU, OpenCL): OmacVM.app 45 percent (not released yet), not available in the others." width="100%">
</p>

Full comparison with benchmarks: [docs/compare.md](docs/compare.md).

## Get started

The command at the top puts OmacVM in `~/.omacvm`, adds the `omacvm` command
and starts it. Run `omacvm` any time after that: with no VM yet it builds one;
otherwise it asks what you want to do (build another VM, switch features,
update, check). Prefer git? `git clone https://github.com/gillesgoetsch/omacvm`
and run `./install.sh` in it. Using a coding agent? [Copy the prompt](docs/agents.md).

## Requirements

- An Apple Silicon Mac, M1 or newer, with macOS 15 for OmacVM.app or macOS 14
  for the others. (On an M1 or M2, [Asahi Linux](https://asahilinux.org) can
  also run Omarchy natively.)
- About 30 GB of free disk space and a decent connection.
- One of the apps: OmacVM.app (`omacvm` downloads it), UTM 5 (beta), VMware
  Fusion 13 or Parallels Desktop 19, or newer. How to get each:
  [docs/routes/](docs/routes/).
- Xcode Command Line Tools. For UTM, Fusion and Parallels also
  [Homebrew](https://brew.sh) with `zstd` and `e2fsprogs`.

`omacvm` checks all of this first, and installs what is missing or waits for you.

## Build a VM

```bash
omacvm            # or: omacvm build
```

It asks a few questions (the app, build or download, CPUs and memory,
features, your user and password), shows a summary and builds. A build takes
30 to 70 minutes: OmacVM.app 10 to 30, VMware Fusion about 15 more. A prebuilt
VM is ready a few minutes after a 3.5 to 6 GB download. A VM window opens on
the way: that is the temporary installer, leave it alone.

For scripts: `--vm-type app|utm|fusion|parallels`, `--prebuilt`, `--vm-dir PATH`
(Parallels and Fusion), `--FEATURE` or `--no-FEATURE`, `--yes`. `omacvm build --help` lists
them all; every step in detail: [docs/guide.md](docs/guide.md).

When it is done, allow the macOS prompts for *OmacVM Bridge* and *OmacVM
Gestures* ([which ones](docs/guide.md#after-the-build)). On Parallels, change
[one setting](docs/routes/parallels.md#after-the-build-let-cmd-reach-omarchy)
so Cmd reaches Omarchy.

## Everyday use

```bash
omacvm features                 # switch features on or off
omacvm update                   # the newest OmacVM, on the Mac and in every running VM
omacvm check                    # what works and what to fix; it changes nothing
omacvm vms                      # your VMs and their OmacVM version
```

Add `--vm NAME` for a VM other than the default. Have an Omarchy VM from
omarchy-mac already? `omacvm apply --vm NAME` adds OmacVM to it.

Put the VM in full screen for the gestures and media keys. **⌃⌥⌘ Esc** gives
the trackpad back to macOS, for example to swipe to your other Spaces; press it
again to hand it back ([more](docs/features.md#full-screen-and-the-escape-keys)).
Everything else: [docs/guide.md](docs/guide.md).

## How it works

OmacVM installs [omarchy-mac](https://github.com/omacom/omarchy-mac), the Arch
Linux ARM port of Omarchy, onto the VM's own disk: a full Omarchy with
`omarchy update`, not a demo. Small helpers on the Mac pass its hardware to the
VM over the VM's private network, with a secret token: **OmacVM Bridge**,
**OmacVM Gestures** and **Omanotch**.

More: [docs/how-it-works.md](docs/how-it-works.md), the whole build in
[AGENTS.md](AGENTS.md), everything else in [docs/](docs/README.md).

## Troubleshooting

Start with `omacvm check`: it names what is wrong and what to do.

- **The Mac's menu bar stays over the full-screen VM**: System Settings › Menu
  Bar › Automatically hide and show the menu bar: **In Full Screen Only**.
- **Gestures do nothing**: the VM must be full screen and in front; ⌃⌥⌘ Esc
  may have handed the trackpad to macOS (press it again).
- **"answers with another SSH host key"** after a rebuild:
  `omacvm apply --vm NAME --reset-host-key`.

More: [docs/troubleshooting.md](docs/troubleshooting.md).

## Uninstall

```bash
omacvm uninstall            # --purge also removes the bridge token and settings
```

Then delete the VM in its app, and remove the OmacVM apps from System Settings
› Privacy & Security › Location Services if still listed. The `omacvm` command
itself stays: `rm -rf ~/.omacvm "$(command -v omacvm)"` removes it. OmacVM.app
stays too: drag it to the Bin (its VMs stay in ~/Library/Application
Support/OmacVM until you delete them).

**OmacVM 2.7.0 and older: don't use `--purge` if you have OmacVM.app VMs.** It
deletes them with the settings; fixed in the next release.

## Credits

[Omarchy](https://omarchy.org) (MIT) and [DHH](https://github.com/dhh) for making this!

[omarchy-mac](https://github.com/omacom/omarchy-mac) and
[try-omarchy](https://github.com/omacom/try-omarchy) by the Omarchy team.
try-omarchy (MIT) gives the camera bridge, the Mac's battery in the VM and
OmacVM.app's pieces. Also [Arch Linux ARM](https://archlinuxarm.org);
[omarchy-parallels](https://github.com/vincenzopalazzo/omarchy-parallels) by
Vincenzo Palazzo (MIT), whose image builder is the temporary installer; and
[omarchy-arm-utm](https://github.com/ggalancs/omarchy-arm-utm), whose UTM
findings shaped the UTM route and whose Wayland SPICE agent (MIT) is the base
of `omacvm-vdagent`. The bar widgets are clones of Omarchy's own.

OmacVM is a community project, not affiliated with the Omarchy team,
Parallels, UTM, VMware (Broadcom) or Apple.

Want to help? Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT, see [LICENSE](LICENSE). Code reused from others:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
