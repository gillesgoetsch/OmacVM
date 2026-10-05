# AGENTS.md: operating manual for coding agents

## Start here

OmacVM = Omarchy (omarchy-mac, Arch Linux ARM) in a VM on an Apple Silicon Mac,
made to feel native. One command, `omacvm`, builds and looks after the VM on
four routes: OmacVM.app (its own QEMU, in `app/`), UTM, VMware Fusion and
Parallels Desktop. Small Mac helpers (Bridge, Gestures, Omanotch) pass the
Mac's hardware to the VM over its private network, with a token.

**Where things are** (all of it: section 3)

| Path | What |
|---|---|
| `omacvm`, `src/cmd/` | The command and its subcommands |
| `src/lib/` | Mac-side libraries: finding VMs, the four apps, signing |
| `src/guest/` | The VM side: `install.sh` (root, idempotent) and `check.sh` |
| `src/<feature>/` | One folder per feature, `mac/` and `guest/` inside; the list is `src/features.tsv` |
| `src/omanotch/` | Omanotch, the bar beside the notch (`git subtree`, history kept, [own README](src/omanotch/README.md)) |
| `app/` | OmacVM.app: Swift launcher, QEMU runtime build, patches in `app/runtime/patches/` |
| `docs/` | For users; `docs/notes/findings.md` for developers |

**Rules that matter**

- The Mac side runs on macOS's `/bin/bash` 3.2: no `declare -A`, `mapfile`,
  `${x,,}`.
- Code changes go through a PR; CI (`.github/workflows/check.yml`) must pass.
  One concern per PR, one change per commit, plain messages
  ([CONTRIBUTING.md](CONTRIBUTING.md)).
- Installers are idempotent. Every feature has a line in `omacvm check`. The
  new-feature checklist is in section 9.
- The guest is untrusted on the Mac side: check sizes, counts and state of
  everything it sends.
- Never edit `/usr/share/omarchy`; Omarchy 4's Hyprland config is Lua.
  Section 8 lists the other dead ends: read it before trying the obvious.
- Only a person grants macOS permissions, installs the VM apps or picks a
  password. Hand it over (exit 3), never work around it.
- No personal data in the repo.

**Test without touching the person's setup**

- No VM needed: the CI steps ([CONTRIBUTING.md](CONTRIBUTING.md#test-your-change)),
  `./omacvm build --plan --json --vm-type ROUTE`, `src/omanotch/mac/test.sh`.
- Use your own VM, named for the test (`--vm-name "OmacVM Test-<topic>"`), never
  the person's. Check it with `./omacvm check --vm NAME --json` (read-only;
  without `--vm` it picks the person's VM). `--no-mac` on `build` and `apply`
  leaves the Mac's installed helpers as they are; `OMACVM_HEADLESS=1` starts
  VMs without a window (UTM, Fusion, Parallels Pro or trial).
- Ask before anything that changes the Mac side: `src/mac/install.sh`,
  `omacvm update`, `omacvm uninstall`, `build` or `apply` without `--no-mac`
  (`build` ends in `apply`). They replace or remove the person's Bridge,
  Gestures and Omanotch.
- Never rebuild an app bundle that is running. Don't switch Spaces, go full
  screen or inject input on a Mac someone is using.
- Done means section 1 holds and `omacvm check --vm NAME` passes. Then shut
  down and delete your test VMs.

The rest of this file: how to set OmacVM up for a person (section 0), how the
full setup is built on each route, how the pieces talk to each other, how to
verify it, and what has already been tried and does not work.

## 0. Recipes: setting OmacVM up for someone

Install: `curl -fsSL https://raw.githubusercontent.com/gillesgoetsch/omacvm/main/install.sh | bash -s -- --no-start`
(clones to `~/.omacvm`, puts `omacvm` on the PATH, installs Xcode's command
line tools first on a fresh Mac, which needs the person to click Install in
macOS's window; `--no-start` keeps it from opening the interactive setup).
Homebrew, Parallels, UTM or VMware Fusion are the person's to install (or `omacvm build`
offers it in a terminal); with `--yes` it stops with the exact command (exit 3).
Everything goes through `./omacvm` (or `omacvm` once `install.sh` put it on
the PATH). Without a terminal it never asks: give options, read `--json`.
Exit codes: 0 done, 1 failed, 2 usage (a missing option is named), 3 needs a
person (the message says what). Only the person can grant macOS permissions,
change Parallels' "Send macOS system shortcuts" setting, install Parallels or
UTM, or choose their password: hand those over, never work around them.

- **New VM**:
  1. `omacvm vms --json` (what exists) and
     `omacvm build --plan --json --vm-type parallels|utm|fusion|app [--feature scroll-momentum=on ...]`:
     resources within the licence, `resource_tiers` (what each
     `--resources` tier gives on this Mac), features, `needs_human`, and
     `command`. The VM name defaults to "Omarchy", or the next free
     "Omarchy N" when a VM of that name exists in either app.
  2. Show the person the plan and explain the choices: Parallels (fast, every
     display, paid: Standard 4 CPUs / 8 GB per VM), UTM (free, one display,
     slower) or VMware Fusion (free, every display, GPU in Chrome, about 71 %
     of the Mac in the browser, about 15 more build minutes, Broadcom sign-in to
     download) or OmacVM.app (free, one display; `--vm-type app` installs the
     app if it is missing, after asking, and runs its own create script); the resource tiers; each feature (`omacvm features --json` has
     titles and summaries; without `--vm` it also reads a running VM's state,
     so pass `--vm NAME` whenever there are VMs). Ask for their password (never invent one) and
     what they want changed. macOS-native scroll momentum (`scroll-momentum`)
     is experimental and off by default: offer
     it, do not decide it.
     `prebuilt.available` in the plan: a prebuilt VM exists for this app
     (same major version, up to this one; never for OmacVM.app); offer it (`--prebuilt`: a 3.5-6 GB download, then a few
     minutes) or a build here (`--build`, the default with `--yes`).
  3. Run `command` with `OMACVM_PASSWORD` set (30-70 minutes, OmacVM.app 10-30, Fusion 45-85:
     `minutes` in the plan; run it in the background and follow its output). Exit 3 = something to install first.
  4. Hand over the `needs_human` steps, then `omacvm check --vm NAME --json`
     until `ok` (the person must be logged in to Omarchy; `needs_human: true`
     entries are theirs). With several VMs, Omanotch serves one at a time: an
     Omanotch failure on the others is expected, and `check` exits 1 for it.
- **Switch a feature** on an existing VM: `omacvm features --vm NAME --json`,
  then `omacvm enable|disable FEATURE... --vm NAME --yes`, then
  `omacvm check --vm NAME --json`. Dependencies are handled (scroll-momentum brings
  gestures, bridge off takes wallpaper).
- **An Omarchy installed by hand**: `omacvm apply --vm NAME`. Exit 3 with a
  command in the message = the person runs that command once in the VM's
  terminal (it adds OmacVM's SSH key), then apply again.
- **Update**: `omacvm update` (all running OmacVM VMs) or `--vm NAME`.
- **Something is off**: `omacvm check --json`, then section 7 below.

## 1. Definition of done

A build is done when all of this holds:

1. The VM is registered (`prlctl list -a`, `utmctl list`, or Fusion's
   library: `omacvm vms`; `vmrun list` shows it once running) and boots to SDDM /
   the Omarchy desktop from its NVMe disk; GRUB default entry = stock
   `linux-aarch64`, or `linux-aarch64-thp` when the memory-optimized kernel
   was chosen (`--thp-kernel`).
2. `ssh -i ~/.ssh/omacvm root@<ip>` works (key only; ufw allows 22 from the VM
   network's /24).
3. `/etc/omacvm/env` names the VM type, the Mac's address, the VM's name
   (`OMACVM_VM_NAME_B64`) and the feature choices (`OMACVM_FEATURE_<name>=on|off`, every feature of
   `src/features.tsv`); `/usr/local/share/omacvm/VERSION` = `src/VERSION`;
   `omacvm check --vm <name>` passes.
4. Display: Parallels: `hyprctl monitors` matches the Mac (native pixels,
   refresh rate, arrangement) within seconds of a change. UTM: Virtual-1 runs
   the mode from `src/display/mac-display.swift` (e.g. 3456x2160@120).
   Fusion: in full screen one monitor per Mac display, placed as in macOS
   (`omacvm-fusion-displays` user unit; `omacvm check` counts the outputs).
5. On the Mac: `lsof -nP -iTCP -sTCP:LISTEN` shows 47830 (Gestures) and 47831
   (Bridge) on 10.211.55.2, 192.168.64.1 and/or the `.1` of Fusion's vmnet8
   (see "VMware Fusion settings" below); `launchctl list | grep omacvm`
   shows bridge, gestures, clip-in (clip-in once a Parallels VM was set up).
6. In the guest as the desktop user: `omacvm-bridge state` prints the Mac's
   Wi-Fi with an SSID (Location Services granted), `omacvm-bridge audio` the
   Mac's devices, `omacvm-bridge bluetooth` its Bluetooth devices; the bar
   shows `omacvm.bluetooth`, `omacvm.wifi`, `omacvm.audio`,
   `omacvm.workspaces` in the slots of the stock widgets.
7. Changing Omarchy's background sets the Mac's wallpaper (bridge log
   `/wallpaper from …`).

## 2. Environment

| Requirement | Value |
|---|---|
| Host | Apple Silicon, macOS 14+ (verified 15.7.4, MacBook Pro M4 Max) |
| Parallels route | Parallels Desktop 19+ (verified 27.0.2, Pro trial). Per-VM limits from `prlsrvctl info --license` (`cpu_total`, `max_memory`): Standard 4 CPUs / 8 GB, Pro/Business/trial 32 CPUs (18 tested on Apple Silicon) / 128 GB; build.sh never writes more than the licence allows (Parallels would reject the config). Only `prlctl list/register/unregister` and `prl_disk_tool`; everything else is `config.pvs` (vm/pvs.py); `prlctl start` only as a fallback |
| UTM route | UTM 5 (verified 5.0.6, QEMU 10.0.12); required: on UTM 4.7 GL clients map but never paint (black windows) unless rendering is forced to software (ggalancs/omarchy-arm-utm#7). OmacVM never sets `LIBGL_ALWAYS_SOFTWARE`; VirGL (virtio-gpu-gl), Vulkan off. VM creation through UTM's AppleScript dictionary (`/Applications/UTM.app/Contents/Resources/UTM.sdef`), `utmctl` for start/stop/status/ip-address |
| VMware Fusion route (new) | VMware Fusion 13+ (verified 26.0.1). Needs Hyprland with the vmwgfx fix (`src/fusion/guest/`); see `docs/routes/vmware-fusion.md` (and the build log `docs/experiments/vmware-fusion.md`). `vmcli VM Create`, `vmware-vdiskmanager`, `vmrun start/list` from `VMware Fusion.app/Contents/Library`; the rest is the `.vmx` (`src/vm/fusion.sh`). VMs in `~/Virtual Machines.localized` or `$OMACVM_FUSION_DIR` |
| Tools | Xcode Command Line Tools (swiftc, clang, swift), Homebrew `zstd` + `e2fsprogs` (live installer), python3, openssl |
| Network | ~1.4 GB try-omarchy download (live installer) + Arch Linux ARM and Omarchy packages |
| Disk | ~30 GB free for the build (peaks about 25 GB); the VM's disk is expanding and grows as it is used |

## 3. Repository map

The root holds only the entry points (`omacvm`, `install.sh`), the docs and
`docs/` (graphics, route pages, benchmarks, findings), and `app/` (OmacVM.app, its own
build); everything else lives in `src/`: the commands in
`src/cmd/`, one folder per feature, and the install plumbing (`guest/`, `mac/`,
`lib/`, `vm/`). Keep it that way: a short root keeps the README near the top on
GitHub.

| Path | What |
|---|---|
| `omacvm` | The command: dispatches to `src/cmd/*.sh` (`build`, `apply`, `check`, `vms`, `update`, `features`/`enable`/`disable` → `features.sh`, no command → `home.sh`, the menu; without a terminal it prints the help, exit 2). Resolves its own symlink, so it works from the PATH |
| `install.sh` | Bootstrap: clones to `~/.omacvm` (or links the clone it runs from), symlinks `omacvm` into Homebrew's bin (else `~/.local/bin`), starts it on `/dev/tty` (works piped from curl) |
| `src/VERSION` | OmacVM's version; copied into the VM with `src/` (what `omacvm vms` reports per VM); also OmacVM.app's version |
| `app/` | OmacVM.app (`git subtree` of the former omacvm-app repo, history kept): `app/` the launcher (Swift, `swift build`), `runtime/` QEMU's build scripts and patches (GPL-2.0: this public repo is the source offer), `scripts/create-vm.sh` (the build the app and `omacvm build --vm-type app` run), `scripts/build-app.sh` (takes `src/` as committed; `--release` needs a clean tree; the commit goes into Info.plist `OmacVMCommit`), `scripts/package-release.sh` (`dist/OmacVM-<version>.zip` + `.sha256` for the GitHub release `v<version>`). Its own README and THIRD_PARTY_NOTICES |
| `src/lib/app.sh` | OmacVM.app from the Mac: its VMs (`app_list`, `app_ip`, `app_start`), the installed app (`app_bundle`), `app_create`, and the download (`app_published`, `app_install`, `app_install_cmd`; curl sets no quarantine) |
| `src/features.tsv` | **The feature list**: name, default (`on`/`off`/`notch`/`laptop`: on with a battery, never on Parallels), sides, tags (`experimental`, `slow`, `notch`, `laptop`, `not-parallels`), needs, title, summary. `feature_default`/`feature_available` in `src/lib/features.sh` turn defaults and tags into on/off and reasons (with `NOTCH` and the VM's `TYPE`). Read by `src/lib/features.sh` (Mac, bash 3.2), `src/guest/install.sh` (VM), `features.sh`; a new feature also needs its case in `build.sh` (`feature_flag`, question), the VM installer and the checks |
| `src/lib/vm.sh` | Finding VMs without starting UTM (`vms_list`: Parallels via prlctl, UTM via utmctl when it runs, else UTM's `Registry` preference, which knows VMs outside its folder, and Fusion's VM folders), `vm_type` (running first, Parallels' "invalid" last), `resolve_vm` (no name: "Omarchy", else the only running VM), `vm_probe` (user, version, env, features set up before 2.0), `ssh_setup_command` |
| `src/cmd/build.sh` | Nothing → finished VM. Interactive questionnaire (`src/lib/setup.sh`, bash 3.2, reads `/dev/tty`): Parallels, UTM, VMware Fusion or OmacVM.app (waits until installed; UTM ≥ 5, Fusion ≥ 13; a missing OmacVM.app is downloaded after asking: `OmacVM-<version>.zip` of this OmacVM's GitHub release, checked against its `.sha256`, into /Applications or ~/Applications; no zip for this version: exit 3; `--yes`: exit 3 with the command), VM name if taken, resources Low/Balanced/High/Best (`tier_values`: Best leaves max(8 GB, ¼) for macOS + GPU; capped by the Parallels licence; custom values also ask Fusion's graphics memory), where the VM goes (Parallels, Fusion), one checklist of every feature in `features.tsv` (defaults on, experimental ones marked), user/full name, summary, password. Options: `--vm-type --vm-name --vm-dir --resources --cpus --memory-gb --disk-gb --graphics-gb --user --full-name --hostname` (`--graphics-gb`: Fusion only, 1-8 GB of the VM's memory) (`--vm-dir`: Parallels and Fusion only; the drive must be APFS or Mac OS Extended with 30 GB free), `--feature NAME=on|off` / `--FEATURE` / `--no-FEATURE`, `--yes --dry-run --plan --json`, `--parallels-edition standard|pro` (only while Parallels reports "No license installed", a fresh install whose trial starts with the first VM: the edition to size by; the questionnaire asks it, default standard), hidden `--channel` (default: omarchy-mac's `stable` lane once published, else `rc`); `OMACVM_PASSWORD` for `--yes`. Ends with one `apply` call (Mac side, VM side, Omanotch). `--vm-type app`: vm.env into OmacVM.app's VMs folder, the app's own `Contents/Resources/scripts/create-vm.sh` builds the VM (password on stdin), then the same `apply` |
| `src/cmd/check.sh` + `src/guest/check.sh` | Read-only feature check, Mac side then guest side over SSH (`bash -s` of `src/guest/check.sh`, so it works on VMs with an older copy). One line per feature, exit 1 on any FAIL; `--json` (guest side `--tsv`) with `needs_human` per check. Add a line here for every new feature |
| `src/cmd/apply.sh` | OmacVM onto a running VM (a stopped one is started): reads the VM (`vm_probe`), merges `--feature` changes (dependencies via `features_fix`), installs the Mac side those features need (`src/mac/install.sh --quiet`, `--omanotch` with that feature), copies the bridge token and `src/` to `/usr/local/share/omacvm` (same layout there, without `src/`), runs `src/guest/install.sh` with every feature explicit, Dock icon (Parallels). No SSH access: exit 3 with the command for the VM's terminal; another SSH host key than the one remembered: exit 3 (`--reset-host-key` after a rebuild) |
| `src/cmd/features.sh` | `features` (list, `--json`, or a checklist in a terminal), `enable`/`disable`; changes go through `apply.sh` |
| `src/cmd/update.sh`, `vms.sh`, `home.sh` | `update`: git pull (clean clone only, then re-exec), Mac side as installed (Omanotch included), OmacVM.app when installed and older than `src/VERSION` and that zip is published (in place, its install name kept; not while the app or one of its VMs runs), `apply --no-mac` on every running OmacVM VM. `vms`: table or `--json`. `home.sh`: the menu |
| `src/mac/install.sh`, `src/mac/uninstall.sh` | Mac side: bridge, gestures, clipboard helper, Omanotch (`--omanotch`, its own `mac/install.sh`); an app whose sources and options are unchanged since its install is skipped (stamps in `~/Library/Application Support/omacvm/installed`, `--force`). `src/mac/parallels-shortcuts.sh`: empty Parallels' Linux keyboard profile (opt-in, app-wide) |
| `src/guest/install.sh` | Guest side, root, idempotent. Detects the VM type (DMI vendor Parallels/QEMU), writes `/etc/omacvm/env`, runs the shared features and the per-type ones |
| `src/prebuilt/` | Prebuilt VMs (`docs/prebuilt.md`): `make-image.sh ROUTE [build generalize package upload clean]` makes one (`omacvm build --image`: placeholder user `omacvmuser`, nothing of the Mac, no Parallels Tools), `guest/generalize.sh` strips it in the VM, `guest/omacvm-firstboot` + its service (before SDDM: grows the disk, user from the OMACVM-SEED ISO or console questions, home from `/var/lib/omacvm/prebuilt/home`), `lib.sh` (lookup on GitHub releases `prebuilt-*`: newest image, same major, version up to ours; download, unpack, seed ISO), `vm.sh` (`omacvm build --prebuilt`: unpack, new ids/MACs, seed, first boot, `apply`, seed removed), `vmconfig.py` (config.pvs/config.plist/.vmx edits), `manifest.py` |
| `src/vm/live/` | Temporary live installer (from vincenzopalazzo/omarchy-parallels, MIT): try-omarchy → bootable ARM64 Linux with SSH; a Parallels VM, or `--raw-image` for UTM |
| `src/vm/base-install.sh` | In the live system: GPT + btrfs on the NVMe disk, pacstrap, locale/keyboard/user, GRUB |
| `src/vm/omarchy-install.sh` | In the new system: omarchy-mac `install.sh --channel rc`, unattended; SSH rule for the Mac's network |
| `src/vm/pvs.py` | Parallels `config.pvs` editor (settings, NVMe disk, boot order, shares) |
| `src/vm/fusion.sh` | VMware Fusion: create the VM (`fusion_create`: vmcli, then `.vmx` lines; the raw live image through a monolithicFlat descriptor), drop the live disk |
| `src/fusion/` | Fusion guest specifics: public DNS (`dns.sh`), Hyprland with the vmwgfx fix (`build-hyprland.sh`, the patch, a pacman hook that rebuilds after hyprland upgrades), VMware Tools (`build-open-vm-tools.sh`), the display layout (`omacvm-fusion-layout`, `omacvm-fusion-displays` + its user unit), `monitors.lua` |
| `src/vm/utm.sh` | UTM: create the VM (AppleScript `make new virtual machine`), drop the live disk, app-wide speed settings |
| `src/lib/mac.sh` | Mac helpers: `gssh`, Parallels (`vm_ip` by DHCP lease, `vm_state`, `vm_start`), UTM (`vm_type`, `utm_ip`, `utm_state`, `utm_start`, `utm_wait_stopped`) and Fusion (`fusion_list`: Fusion's `vmInventory`, running VMs and `$FUSION_DIR`, `fusion_ip` from `vmnet-dhcpd-vmnet8.leases`, `fusion_state`, `fusion_start`, `fusion_host`) |
| `src/guest/omacvm-omanotch.service` | The omanotch feature: one-shot user unit that runs `/usr/local/share/omacvm/omanotch/guest/install.sh` in the first desktop session (it needs Hyprland running), skipped once `~/.local/bin/notchcast` exists. `src/guest/install.sh` removes notchcast when that copy changed (stamp `~/.local/state/omacvm/omanotch`), so it installs again |
| `src/omanotch/` | Omanotch (`git subtree`, history kept): `mac/` (Omanotch.app, Swift; `mac/test.sh` = offline tests), `guest/` (`notchcast`, the bar and background patches, `notchbar.lua`). Its own README. Work on it here; github.com/gillesgoetsch/omanotch is archived and points here |
| `src/lib/install-plugin.sh`, `src/lib/omacvm-plugins` | Omarchy shell plugin install; queues until the shell runs (first login); restarts the shell once when a plugin's files changed |
| `src/lib/sign.sh` | Signs Mac apps with `designated => identifier "<id>"`, so TCC grants survive rebuilds |
| `src/bridge/` | OmacVM Bridge: `mac/*.swift` (OmacVMBridge.app), `guest/` (client, shared event stream, OSD follower, nightlight and Wi-Fi QR command replacements), `plugins/omacvm.{wifi,audio,wifiqr,nightshift}`. Night light: the Mac's Night Shift only; the guest install hides Omarchy's NightLight indicator (`items` of `omarchy.indicators` in `shell.json`, original kept in `~/.local/state/omacvm/nightlight-indicator`, restored with bridge=off) and stops `hyprsunset` |
| `src/gestures/` | OmacVM Gestures: `mac/omacvm-gestures.c` (MultitouchSupport + event tap; also hides the Mac's pointer over the full-screen VM), `guest/omacvm-gestures` (uinput touchpad; Glide), `guest/glide.sh` + `guest/omacvm_glide.lua` (Glide's Hyprland settings and Chromium flag). The scroll momentum's tuning history: `docs/experiments/trackpad-scrolling.md`, analysis scripts in `docs/experiments/scroll-analysis/` |
| `src/display/` | Parallels: `parallels-dynres` + `monitors.lua`. `mac-display.swift`: the built-in display below the notch, for UTM |
| `src/utm/` | UTM guest specifics: guest tools, virtio-gpu environment, fixed display mode |
| `src/workspaces/` | Per-display workspaces: `monitor_workspaces.lua`, bindings, `plugins/omacvm.workspaces` |
| `src/clipboard/` | Parallels only: VM → Mac copy (guest `parallels-clip-out`, Mac `omacvm-clip-in`) |
| `src/battery/` | The Mac's battery (feature `battery`; UTM, Fusion, OmacVM.app; Parallels has its own): DKMS module `omacvm_battery` (BAT0, ADP0; from try-omarchy, GPL-2.0-only), root agent `omacvm-battery` (OmacVM.app: virtio port `org.omacvm.battery`; UTM/Fusion: the Bridge's `battery` events through `bridge/guest/omacvm-bridge`), UPower never suspends for it. Mac side: `bridge/mac/battery.swift`, OmacVM.app's `NativeBatteryBridge.swift`. Its README |
| `src/wallpaper/` | Guest `omacvm-wallpaper` (path unit) → `POST /wallpaper` on the bridge |
| Video decoding (OmacVM.app) | Guest VA-API (Mesa virgl) → virglrenderer's video protocol → VideoToolbox backend (`app/runtime/patches/virgl-videotoolbox-decode.patch`: `src/vrend/virgl_video_vt.c`; SPS/PPS rebuilt for H.264, VPS/SPS/PPS for HEVC with an explicit short-term RPS rewritten into every slice header (VA-API omits the SPS's sets), AV1 frames cut from the temporal unit by the first tile's offset, VP9 frames as they come; bit-exact against FFmpeg's software decoding; IOSurface → GPU copy into the guest's textures). VM side in `src/app/guest/install.sh`: `vainfo`, VA driver shim `omacvm_drv_video.c` (`LIBVA_DRIVER_NAME=omacvm`, `/usr/local/lib/dri`: NV12 surfaces only, AV1 only for Chromium-based processes), Firefox pref. QEMU env: `OMACVM_VIDEO_DECODE=0`, `OMACVM_VIDEO_DEBUG=1`, `OMACVM_VIDEO_AV1=1` (the app sets it when the VM folder has `video-decode` = `av1`, written by `apply`). Guest profile numbers are Mesa ≥ 26's (`OMACVM_VIRGL_VIDEO_ABI=legacy`). `docs/video-decode.md` |
| `src/camera/` | Feature `camera` (from try-omarchy): guest `omacvm-camera` (user service) feeds `/dev/video42` "Mac Camera" (v4l2loopback via DKMS, `exclusive_caps`) and asks the Mac for frames only while v4l2loopback reports a reader: Bridge `GET /camera` (UTM, Fusion; `src/bridge/mac/camera.swift`) or OmacVM.app's virtio port `org.omacvm.camera` (same Swift file, linked into `app/app/Sources/OmacVM`). Parallels passes the camera itself (a USB camera, `uvcvideo`, "MacBook Pro Camera" on /dev/video0; `SharedCamera` in config.pvs): nothing installed there. `omacvm-camera --status` for the check |
| `src/keyboard/` | `mac-layout.sh` (macOS input source → XKB), guest layout + Cmd+V paste |
| `src/memory/`, `src/kernel/` | zram/sysctl/THP-defrag/MGLRU; opt-in memory-optimized kernel (THP always + MGLRU) from ALARM's PKGBUILD, built only with `--thp-kernel`. ALARM's stock `linux-aarch64` has `# CONFIG_TRANSPARENT_HUGEPAGE is not set` and `# CONFIG_LRU_GEN is not set` (verified 7.2.8), so the THP/MGLRU tmpfiles lines are no-ops there (systemd-tmpfiles skips missing files) |
| Feature switches | `src/guest/install.sh --feature NAME=on\|off` for every feature in `src/features.tsv`, kept in `/etc/omacvm/env`; `omacvm apply` passes all of them (also `--[no-]FEATURE`). omanotch=on: `omacvm-omanotch.service` installs Omanotch from the copy of `src/omanotch` in the session (now if Hyprland runs, else at the next login), again when that copy changed; the clone earlier versions made in `~/.local/share/omanotch` is removed; off: Omanotch's own `guest/uninstall.sh` in the session. scroll-momentum ("glide" in the code; the old key in /etc/omacvm/env still maps to it): `gestures/guest/glide.sh` on/off (`omacvm_glide.lua` required from `hyprland.lua`, `--disable-smooth-scrolling` in existing `chromium-flags.conf`/`chrome-flags.conf`, marker `~/.local/state/omacvm/glide-flags` so off removes only what it added). idle-lock=off = Omarchy's own Stay Awake file (`~/.local/state/omarchy/indicators/stay-awake`, watched by the shell) plus an OmacVM marker so turning it back on never undoes a user's own Stay Awake. bridge=off disables the clones (Omarchy restores its stock widgets). battery: `battery/guest/install.sh on|off` (forced off on Parallels); on UTM and Fusion `omacvm apply` installs the Bridge for it even with bridge=off. Gestures off: the VM's daemon says so in its hello (on UTM it still runs, for Cmd as Super) and the Mac helper leaves that VM's trackpad to macOS; on Parallels the daemon is not installed. `--keys-only` on the Mac app is a Mac-wide off switch |
| `src/icon/` | `omacvm.svg` is the one icon (⌘ loops around Omarchy's mark): `make-icns.sh` renders it with AppKit (`render.swift`) + `iconutil` into both apps' `Contents/Resources/OmacVM.icns`, the Parallels VM's Dock icon (`set-vm-icon.sh` → Finder custom icon of the .pvm) and UTM's library icon (`src/vm/utm.sh` `utm_set_icon`: `Data/omacvm.png` + `Information.Icon`/`IconCustom` in config.plist, VM stopped; UTM's scripting only takes built-in icon names) |
| `docs/` | Index `docs/README.md`. `images/`: README graphics (hand-written SVG + SMIL; `parallels-shortcuts.svg` stays in `docs/`, `src/mac/parallels-system-shortcuts.sh` opens it). `routes/` (one page per app: `app.md`, `utm.md`, `vmware-fusion.md`, `parallels.md`), `guide.md` (build and everyday use in full), `how-it-works.md`, `features.md`, `benchmarks/README.md` (method + results, behind `compare.md`, the full comparison of the four apps; tools in `src/bench/`), `troubleshooting.md` (user problems: symptom, cause, fix, code), `notes/findings.md` (developer findings: reviews, measuring pitfalls, VM app internals), `experiments/` |

## 4. Architecture

```
Mac (macOS)                                         VM (Arch Linux ARM + Omarchy)
───────────                                         ─────────────────────────────
OmacVMBridge.app   :47831 on 10.211.55.2 ◀── HTTP ── omacvm-bridge (curl, SSE) ← omacvm-bridge-events ← bar widgets,
  CoreWLAN, CoreAudio,  192.168.64.1, Fusion's .1   omacvm-bridge-osd → omarchy-osd,
  CoreBrightness, media-key event tap,              omarchy-toggle-nightlight, omarchy-network-qr,
  keychain, wallpaper                               omacvm-wallpaper (POST /wallpaper)
OmacVMGestures.app :47830 on the same   ◀── TCP ─── omacvm-gestures (root, uinput touchpad, scroll momentum)
Parallels only:
omacvm-clip-in     ◀── share "clip"  ◀──────────── parallels-clip-out (wl-paste --watch)
VM bundle (.pvm)   ──▶ share "vmlog" (ro) ───────▶ parallels-dynres reads parallels.log [DYNRES]
Omanotch.app (src/omanotch) :47811     ◀────────── notchcast
OmacVMBridge.app /battery, events ──────────────▶ omacvm-battery (root) → module → BAT0 → UPower (UTM, Fusion)
OmacVM.app: virtio port org.omacvm.battery ─────▶ omacvm-battery (root) → module → BAT0 → UPower
```

- The Mac is **10.211.55.2** on Parallels' shared network (not .1), the
  default gateway (**192.168.64.1**) on UTM's shared network and **.1** of
  Fusion's NAT network (vmnet8; the guest's gateway there is .2). The guest's
  `/etc/omacvm/env` holds `OMACVM_VM_TYPE` and `OMACVM_HOST`; the client, the
  gestures daemon (EnvironmentFile) and the widgets use it.
- Mac listeners bind those addresses only, never 0.0.0.0; one listener per
  address, re-bound when the bridge interface comes and goes. The bridge needs
  `Authorization: Bearer <token>` (`~/Library/Application Support/omacvm-bridge/token`
  → guest `~/.config/omacvm-bridge/token`, 0600). API: `src/bridge/README.md`.
- Full-screen capture (media keys, gestures): frontmost app `prl_client_app`
  (Parallels), `UTM` or `VMware Fusion`, and its window covers a display (the strip beside the
  notch excepted).
- Gestures protocol (one line each, `src/gestures/mac/omacvm-gestures.c`
  header): both sides first prove they know the Bridge's token (`C`, `M`,
  then the guest's `R <gestures> <glide> <proof> <name>`; the VM's name in
  base64, `OMACVM_VM_NAME_B64` in `/etc/omacvm/env`, from `omacvm apply`).
  Daemons from 2.4 and 2.5 say `H <gestures> <glide> <token> <name>` (the
  token itself) and are still let in; daemons without a token (2.3 and older)
  are refused until `omacvm update`. All VMs of one app share its network, so
  the helper reads the title of the app's front window (Accessibility) and
  sends frames, keys and the capture state only to the VM whose name it holds
  (the exact name first, else the longest name in the title); without a match
  (older daemons, a VM renamed since its last `omacvm apply`) to every VM of
  that app. The helper captures the trackpad only when those VMs all want it,
  and the scroll momentum (macOS's continuous scroll events dropped,
  `A`/`W`/`P` sent, every two-finger frame forwarded) only when they all want
  that.
- SSH: `gssh` checks each VM's host key, remembered the first time OmacVM sets
  the VM up (`~/Library/Application Support/omacvm/known_hosts/`, `vm_pin`);
  another key stops with exit 3 and `omacvm apply --vm NAME --reset-host-key`.
- Scroll momentum in the guest (feature `scroll-momentum`, called Glide in the code and
  the experiment: the `Glide` class, `glide.sh`, `omacvm_glide.lua`, `OMACVM_GLIDE_*`): two-finger frames go through a One Euro
  filter (rigid spacing, so libinput never reads a pinch); below 80 mm/s the
  raw movement (× `RAW_SCALE` × self-calibration × scroll direction), above
  160 mm/s macOS's accelerated `A` deltas (× `POINT_UNITS`), smoothstep in
  between; after the lift the virtual fingers stay down and macOS's momentum
  (`W`) drains with τ = 25 ms, capped at 1000 mm/s (libinput's touch-jump
  limit), lifting 0.5 s after the last movement; `P` (macOS saw a magnify)
  restarts the touch as raw fingers. Frames ≥ 3 ms apart; a lift and a new
  touch never share a frame. Virtual pad 1 × 1 m, the real trackpad in its
  middle. `omacvm_glide.lua`: `scroll_factor = 0.328 × 3.3 × 2 / scale` for the
  virtual trackpad, `scroll_touchpad = 1/3.3` for Chromium/Electron windows.
- Disk: GPT on NVMe: 2 GiB EFI at `/boot` + btrfs `@ @home @log` (+ `@factory`
  and snapper from omarchy-mac), `noatime,compress=zstd:1,space_cache=v2,discard=async`.
  GRUB (omarchy-mac's restore tooling expects it), normal and `--removable`.
- Kernel: stock `linux-aarch64`, booted as `/boot/vmlinuz-linux` (a copy of
  its `/boot/Image`, kept current by a pacman hook, `src/kernel/stock-kernel.sh`:
  only that name pairs with `initramfs-linux.img` in GRUB and grub-btrfs);
  with `--thp-kernel` also `linux-aarch64-thp`
  (`/boot/vmlinuz-linux-aarch64-thp`, GRUB default via `GRUB_TOP_LEVEL`), stock as fallback. Cmdline
  `loglevel=3 quiet mitigations=off nowatchdog`.

### Parallels settings (vm/pvs.py `omacvm`)

| config.pvs | Value | Why |
|---|---|---|
| `Hardware/Cpu/Number`, `AutoCountEnabled` | N, 0 | default suggestion = performance cores (vCPUs cannot be pinned) |
| `Hardware/Memory/RAM`, `RamAutoSizeEnabled` | MB, 0 | default suggestion = half the Mac |
| `Hardware/Video/Enable3DAcceleration`, `EnableVSync`, `VideoMemorySize` | 1, 1, 0 | virgl GPU for Hyprland and Chrome |
| `EnableHiResDrawing`, `UseHiResInGuest`, `Settings/Runtime/HostRetinaEnabled`, `OsResolutionInFullScreen` | 1 | native Retina pixels |
| `Settings/Runtime/FullScreen/UseAllDisplays` | 1 | external displays in full screen |
| `Settings/Tools/SmoothScrolling/Enabled` | 1 | hi-res wheel events with inertia (0 = ±120 notches only) |
| HostSharing `vmlog` (the .pvm, ro), `clip` (rw); `SharedCloud` 0, `SharedVolumes` 0, `SharedProfile` 0 | | display layout, clipboard; no Mac volumes/iCloud in the guest |
| `Hardware/Hdd` InterfaceType 3 | NVMe, expanding, OnlineCompactMode 1 | the system disk |

GUI-only (app-wide): Shortcuts › macOS System Shortcuts › **Send macOS system
shortcuts: Always**; the Linux keyboard profile's Cmd→Ctrl mappings
(`src/mac/parallels-shortcuts.sh` empties it: `~/Library/Preferences/Parallels/Linux.dat`,
a Qt data stream, Parallels must be quit).
"Send macOS system shortcuts: Always" has no CLI, plist key or config.pvs
setting; with Always, Parallels writes `sendtovmkeys.dat` (count + one 9-byte
entry per macOS shortcut, flag 1). `src/lib/mac.sh` `parallels_sends_shortcuts`
reads that as a best guess and `parallels_shortcuts_alert` reminds the user
(omacvm build, omacvm apply); never write the file.

### VMware Fusion settings (vm/fusion.sh)

| Setting | Value | Why |
|---|---|---|
| guest OS, firmware | `arm-other6xlinux-64`, `efi` | |
| `mks.enable3d`, `svga.graphicsMemoryKB` | TRUE, 4 GB | vmwgfx with SVGA3D |
| `nvme0:0` | system disk (vmware-vdiskmanager, growable) | base-install takes the one NVMe disk |
| `sata0:0` | the raw live image via a monolithicFlat `live.vmdk` (removed after the base install) | ALARM's live kernel boots from it; no conversion |
| `ethernet0` | `e1000e`, `nat` | ALARM's kernel has no vmxnet3 |
| `sound.present`, `sound.virtualDev`, `sound.fileName`, `sound.autodetect` (`fusion_add_sound`, VM stopped) | TRUE, `hdaudio`, `-1`, TRUE | vmcli makes no sound card: no speakers or microphone without it |
| guest NetworkManager `90-omacvm-fusion.conf` (`src/fusion/guest/dns.sh`) | global DNS 1.1.1.1, 9.9.9.9, only while OmacVM installs | Fusion's NAT DNS drops lookups under load (failed the yay build); afterwards Fusion's DNS, which follows the Mac's |
| `svga.numDisplays`, `svga.maxWidth`/`maxHeight`, `gui.fullScreenOnAllHostDisplays` | the Mac's display count, its arrangement in pixels, TRUE | one guest display per Mac display in full screen |
| guest VMware Tools | `open-vm-tools` built from Arch's recipe with `makepkg -A` (`--without-gtkmm4`), `[resolutionKMS] enable=true`, rebuilt when `vmtoolsd` misses a library | Fusion sends its display layout (`DisplayTopology_Set`) only to a guest running the tools; without them every Mac display shows the same screen |
| guest user unit `omacvm-fusion-displays` | applies vmwgfx's suggested positions (`omacvm-fusion-layout`, libdrm) with `hyprctl eval hl.monitor{…}` on every DRM change and config reload | Hyprland ignores suggested positions |
| guest user unit `omacvm-fusion-clipboard` | Xvfb `:99`, VMware's agent (`vmware-user`, dndcp) on it, Wayland ↔ `:99` clipboard sync (`wl-paste --watch`, `xsel`); the tools' autostart entry hidden in `~/.config/autostart` | on XWayland Hyprland owns the X11 clipboard and refuses clients without an X11 window in focus (`XWM.cpp`: "xwayland not in focus"); the agent finds a new copy by TIMESTAMP, which xclip answers with the text |
| guest Hyprland | built with `src/fusion/guest/hyprland-vmwgfx-dmabuf.patch`, stock kept as `/usr/bin/Hyprland.stock`, `/var/lib/omacvm/hyprland-vmwgfx` = version + checksum | without it every GPU client dies (`invalid arguments for wl_surface.attach`), SDDM's greeter first |

The Mac is `.1` on Fusion's NAT network (`VNET_8_HOSTONLY_SUBNET` in
`/Library/Preferences/VMware Fusion/networking`, chosen per Fusion install); the
guest's gateway is `.2`.

### UTM settings (vm/utm.sh)

| Setting | Value | Why |
|---|---|---|
| backend, architecture, `hypervisor`, `uefi` | qemu, aarch64, true, true | HVF, EDK2 |
| `Sound` in config.plist (`utm_add_sound`, VM stopped: the build, or `omacvm apply` starting a stopped VM) | `intel-hda` | UTM's scripting has no sound; without it the VM has no speakers or microphone. Audio goes through UTM's default SPICE backend (input and output; "CoreAudio" in UTM's settings is output only) |
| display | `virtio-gpu-gl-pci`, native resolution, dynamic resolution | virgl; the guest pins its mode |
| network | `virtio-net-pci`, shared | Mac = gateway 192.168.64.1 |
| drives | live installer VirtIO (removed after the base install), system NVMe | base-install looks for NVMe |
| app-wide `QEMUVulkanDriver` = 1, `NSAppSleepDisabled` | | Vulkan on makes UTM pass a 4K stage-2 granule (2x slower memory work); App Nap off |
| guest `/etc/environment.d/90-omacvm-utm.conf` | `WLR_NO_HARDWARE_CURSORS=1 AQ_NO_MODIFIERS=1 WLR_RENDERER_ALLOW_SOFTWARE=1` | hardware cursors and DRM modifiers misbehave on virtio-gpu |
| guest user unit `omacvm-vdagent.service` (stock `spice-vdagent.service` masked globally) | reports the largest Hyprland monitor to spice-vdagentd, clipboard text via wl-copy/wl-paste | the stock agent is X11: on XWayland it sees Omanotch's notch strip beside the screen, reports 2× the width and vdagentd's pointer tablet then only reaches the left half |

## 5. Build pipeline (omacvm build)

1. Questionnaire (see `build.sh` above); keyboard, timezone, language from the
   Mac; password hashed (SHA-512) after the summary. Cmd as Super: Parallels'
   Linux keyboard profile emptied right away when no VM runs (quits the idle
   Parallels app first).
2. Live installer: Parallels: `build-live.sh --skip-boot` → registered VM;
   unregister, NVMe disk via `prl_disk_tool`, `pvs.py` settings/shares/boot,
   register, start. UTM: `build-live.sh --raw-image`, `utm_create`, start.
   Fusion: `build-live.sh --raw-image`, `fusion_create` (the image as a
   monolithicFlat `live.vmdk`), start.
3. Over SSH (key injected by the live initramfs): `src/vm/base-install.sh`. Poweroff.
4. Drop the live disk, boot from NVMe (pvs.py / `utm_drop_live` / `fusion_drop_live`).
5. `src/vm/omarchy-install.sh` (temporary NOPASSWD + `verifypw=any` sudo, removed by
   trap; SSH firewall rule kept even if ufw cannot apply it live); on Fusion
   public DNS first (`src/fusion/guest/dns.sh`). Parallels Tools on Parallels.
6. `src/cmd/apply.sh` with every feature explicit: Mac side, token, `src/`,
   `src/guest/install.sh` (Omanotch included), icon; reboot.

`--prebuilt` (`src/prebuilt/vm.sh`) replaces steps 2-5: download the image
(the newest GitHub release `prebuilt-*` with an image of the same major
version up to this one, parts checked by SHA-256), unpack into
the VM folder, new VM id/MACs/name/resources, grow the disk, a seed ISO
(OMACVM-SEED: user, hash, root key, hostname, keyboard, timezone, language,
display mode, the Mac's network) attached, first boot (`omacvm-firstboot`
before SDDM), host key pinned, then step 6 (Parallels Tools from the Mac's
Parallels in `apply`), power off, seed detached and deleted, start.
Images: `src/prebuilt/make-image.sh ROUTE` (`docs/prebuilt.md`); run it from
a copy of the checkout, not from one you edit (bash reads scripts as it goes).

## 6. Standard procedures

- **Build**: `./omacvm build [--vm-type utm]` or unattended with `OMACVM_PASSWORD=… ./omacvm build --yes …` (`--plan --json` first).
- **Update**: `./omacvm update` (pull, Mac side, every running OmacVM VM; keeps feature choices); one VM: `./omacvm apply --vm <name>`.
- **Features**: `./omacvm features|enable|disable … --vm <name>`.
- **Try the questionnaire**: `./omacvm build --dry-run`; scripted with `expect` for tests (it reads `/dev/tty`).
- **Scroll momentum diagnostics**: Mac helper `-v --record` (`src/gestures/mac/install.sh -v --record`, back without), guest `OMACVM_GLIDE_DEBUG=1` / `OMACVM_GLIDE_RECORD=1` in a systemd drop-in for `omacvm-gestures`; `docs/experiments/scroll-analysis/`.
- **SSH**: `ssh -i ~/.ssh/omacvm root@<ip>` (Parallels: DHCP lease file
  `/Library/Preferences/Parallels/parallels_dhcp_leases`; UTM: `utmctl ip-address <name>`
  or `/var/db/dhcpd_leases`; Fusion: the VM's MAC from its `.vmx` in
  `/var/db/vmware/vmnet-dhcpd-vmnet8.leases`, as `fusion_ip` in `src/lib/mac.sh`).
- **As the desktop user over SSH**: `sudo -u <user> env XDG_RUNTIME_DIR=/run/user/1000 bash -c 'source /usr/share/omarchy/default/bash/env-bootstrap; <cmd>'`
  (`hyprctl`/`grim` also need `WAYLAND_DISPLAY=wayland-1` and `HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/1000/hypr | head -1)`).
- **Screenshot the guest**: `grim -o Virtual-1` as above.
- **Camera**: in the VM `omacvm-camera --status`, `journalctl --user -u omacvm-camera`,
  `ffmpeg -f v4l2 -i /dev/video42 -frames 30 -f null -` (reads it, so the Mac's camera turns on); the
  Bridge's log `camera:` lines. Without the camera permission (or to test the path):
  `OMACVM_CAMERA=test` in the Bridge's or the app's environment sends a moving test picture.
- **Microphone**: as the desktop user `pw-record --rate 48000 --channels 1 /tmp/m.wav` for a few seconds;
  all zeros = the VM's app has no microphone permission (or no sound card: `pactl list short sources`).
- **Bridge from the guest**: `omacvm-bridge state|audio|display|events`; from the Mac:
  `curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/omacvm-bridge/token)" http://10.211.55.2:47831/state`.
- **Permissions**: Location Services (bridge), Accessibility (bridge, gestures), Input Monitoring
  (gestures), Camera (bridge on UTM and Fusion, OmacVM.app, Parallels Desktop; asked when a Linux app
  first uses it), Microphone (the VM's app). Reset: `tccutil reset Accessibility org.omacvm.bridge` (and `org.omacvm.gestures`,
  `ListenEvent`), then `launchctl kickstart -k gui/$(id -u)/org.omacvm.<app>`.
- **Logs**: `~/Library/Logs/omacvm-{bridge,gestures}.log`; guest
  `journalctl --user -u omacvm-bridge-osd` (and `-u omacvm-bridge-events`, the shared event stream), `journalctl -u omacvm-gestures`,
  Omarchy shell `/run/user/1000/quickshell/by-id/*/log.log`.
- **Uninstall**: `src/mac/uninstall.sh [--purge]`; delete the VM in Parallels, UTM or Fusion.

## 7. Failure modes

The less obvious ones, with causes and where the fix lives, are in
`docs/troubleshooting.md`.

| Symptom | Cause | Fix |
|---|---|---|
| `omacvm check`: Omanotch not connected, Mac log says "another guest is connected" | Omanotch serves one VM at a time | close or stop `notchcast` in the other VM |
| Bar widgets missing after a fresh build | the Omarchy shell was not running at install time | queued; `omacvm-plugins.service` enables them at the first login |
| `OMARCHY_PATH is not set` from omarchy commands run as root/sudo | no Omarchy env | `source /usr/share/omarchy/default/bash/env-bootstrap` first |
| A command replacement in `/usr/local/bin` is ignored by the bar | the Omarchy shell runs with `/usr/share/omarchy/bin` (symlinks to /usr/bin) first on PATH; Hyprland does not | call `/usr/local/bin/...` by full path from QML (see `omacvm.wifiqr`) |
| `Target not found` / "handler will not be used" for a widget's IPC | a clone kept the stock widget's IPC target | give clones their own target (`omacvm.wifi`) |
| Updated widget does not change | a running shell keeps loaded plugins | `src/lib/install-plugin.sh` flags changes; `src/guest/install.sh` runs `omarchy-restart-shell` |
| Disabling an old clone brings the stock widget back next to the new one | `clonedFrom` hand-back | rename ids in `shell.json` instead, or disable the stock widget |
| SSIDs null, `location_authorized: false` | Location Services not granted (new bundle id or reset) | Privacy & Security › Location Services |
| Media keys still show the macOS popup | Accessibility missing, VM not full screen, or capture switched off in the bridge menu | `media keys:` lines in the bridge log |
| Build stops right after the Omarchy install | Omarchy enables ufw; new SSH connections from the Mac are refused | `src/vm/omarchy-install.sh` adds the rule while its own session is open |
| `ERROR: problem running` from ufw | rule stored but not applicable live right after the install | ignored on purpose; verified with `ufw show added` |
| UTM desktop blank after a resolution change | virgl under UTM cannot switch modes live | fixed mode in `monitors.lua`, reboot to change it |
| OmacVM.app: video still decodes on the CPU | Arch Linux ARM's Chromium has no VA-API; or the app predates video decoding; or `vainfo` lists nothing | Google Chrome, Brave or Firefox; `omacvm check` (video decoding); `OMACVM_VIDEO_DEBUG=1` logs each stream in the VM's `logs/qemu.log` (`docs/video-decode.md`) |
| UTM VM very slow | UTM started with `open -g` (background priority) or Vulkan driver on | start UTM normally; `QEMUVulkanDriver` 1 |
| VM resumes a dead state after a hard kill (Parallels) | suspend files | delete `<pvm>/*.mem*` and `vm.lock` |
| The Mac's pointer shows over the full-screen VM | another app's window over the VM hit-test area (Bartender's menu-bar overlay brings it back) | the gestures helper hides the pointer by AppKit hit test (click-through overlays such as `screencaptureui`'s are skipped); quit such menu-bar tools |
| The Mac's wallpaper changes only on one Space | `NSWorkspace.setDesktopImageURL` sets only the current Space | the Bridge rewrites `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` for every Space and restarts `WallpaperAgent` |
| A command starts UTM by itself | `utmctl` launches UTM | use `vms_list`/`vm_type` from `src/lib/vm.sh` (UTM's `Registry` preference while UTM is not running) |
| SSH output in a `while read` loop eats the loop's input | `ssh` reads stdin | `< /dev/null` on SSH calls inside loops (`vm_probe` has it) |
| ALARM downloads time out | geo-DNS mirror far away | `src/vm/base-install.sh` ranks mirrors |
| Fusion VM: black screen at SDDM, `invalid arguments for wl_surface.attach` in the journal | stock Hyprland on vmwgfx (e.g. an update the hook could not rebuild) | `omacvm apply`, or in the VM `/usr/local/share/omacvm/fusion/guest/build-hyprland.sh` (log `/var/cache/omacvm/hyprland-vmwgfx/build.log`) |
| Fusion VM: `no such host` during a build | Fusion's NAT DNS | `src/fusion/guest/dns.sh` |
| Testing the hook with `pacman -S hyprland` downgrades Hyprland | Arch's `extra` comes before Omarchy's repo | `pacman -S omarchy/hyprland` |
| Fusion VM: copy and paste does nothing | Fusion exchanges clipboards only when the pointer enters or leaves the VM; or the agent runs on Hyprland's X11 display | move into / out of the VM; `omacvm check` (one `vmtoolsd -n vmusr`, `DISPLAY=:99`) |

## 8. Hard-won rules (do NOT)

- Do not use try-omarchy as the installed system (pinned demo runtime). It is
  only the temporary live installer.
- Do not update with bare `pacman -Syu`: omarchy-mac pins the Hyprland stack to
  Omarchy's ARM repo; use `omarchy update`.
- Do not expect Hyprland to apply Parallels' display pushes: `parallels-dynres`
  reads `[DYNRES]` lines from `parallels.log` and applies them with
  `hyprctl eval 'hl.monitor{…}'`; runtime rules are lost on reload, hence the
  saved layout. Do not hard-code scales (Omarchy's scale menu writes
  `omarchy_monitor_scale`). On UTM, do not change modes live at all.
- Omarchy 4's Hyprland config is **Lua**; `hyprland.conf` is ignored.
- Parallels Tools syncs the clipboard Mac → VM only under Hyprland; its helper
  window "Parallels Shared Clipboard" tiles unless the window rule keeps it out.
- The VM never returns touched memory to the Mac while it runs (Parallels'
  balloon has no free-page reporting). Keep zram small and memory capped.
- GRUB on Arch only boots kernels named `/boot/vmlinuz-*` with their initramfs
  (`/boot/Image` boots without one, and grub-btrfs ignores it).
- A Linux guest gets no trackpad gestures from Parallels, UTM or Fusion; they come from
  MultitouchSupport on the Mac + uinput in the guest.
- UTM: only one `virtio-gpu-gl` device is allowed, so no second accelerated
  display; QEMU's user-space interrupt controller makes cross-CPU wake-ups
  ~2x slower than Parallels (Speedometer gap); a 4K stage-2 granule (Vulkan
  driver on) halves memory-heavy throughput.
- The Mac's lock screen cannot be themed: only the wallpaper (shown behind it).
  An Omarchy-styled password field on the Mac would be fake.
- Never edit `/usr/share/omarchy` (updates replace it); extend through plugins,
  `~/.config`, and `/usr/local/bin` replacements (remember the shell's PATH).
- Only one agent should edit the guest's Hyprland config at a time.
- Do not switch the user's macOS Spaces or Mission Control in tests.
- Do not put personal data in this repo.

## 9. Conventions

- Identifiers: bundle IDs and LaunchAgent labels `org.omacvm.*`; Omarchy plugin
  IDs `omacvm.*`; guest commands `omacvm-*`.
- Every installer is idempotent and safe to re-run.
- Ports: 47811 Omanotch, 47830 Gestures, 47831 Bridge.
- One commit per change, message says what the user gets.
- A new feature: a line in `src/features.tsv`, its `feature_flag` case and
  question in `src/cmd/build.sh`, its on/off in `src/guest/install.sh`, its
  checks, the README's tables and `docs/guide.md`'s feature list. Experimental features are off by default
  and say so wherever they are offered.
- Verify on real VMs before committing behaviour changes: `omacvm apply` against a
  test VM, `omacvm build --vm-name "OmacVM Test"` (and `--vm-type utm`) for the full path,
  then `omacvm check --vm <name>` must pass.
