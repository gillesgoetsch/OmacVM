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
  the person's. Check it with `./omacvm check --vm NAME --json` (read-only,
  but for OmacVM's record of a feature switched outside OmacVM, which it fixes
  to the real state; without `--vm` it picks the person's VM). `--no-mac` on `build` and `apply`
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
person (the message says what), 4 failed and rolled back (`--transaction`). Only the person can grant macOS permissions,
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
     download) or OmacVM.app (free, every display in full screen; `--vm-type app` installs the
     app if it is missing, after asking, and runs its own create script); the resource tiers; each feature (`omacvm features --json` has
     titles and summaries; without `--vm` it also reads a running VM's state,
     so pass `--vm NAME` whenever there are VMs). Ask for their password (never invent one) and
     what they want changed. macOS-native scroll momentum (`scroll-momentum`)
     is experimental and on by default; it only ever takes a trackpad's
     scrolling (mice scroll one to one), so a Mac with only mice is unaffected.
     `prebuilt.available` in the plan: a prebuilt VM exists for this app
     (same major version, up to this one; for OmacVM.app only when the
     installed app has `scripts/prebuilt-vm.sh`); offer it (`--prebuilt`: a 3.5-6 GB download, then a few
     minutes) or a build here (`--build`, the default with `--yes`).
  3. Run `command` with `OMACVM_PASSWORD` set (30-70 minutes, OmacVM.app 10-30, Fusion 45-85:
     `minutes` in the plan; run it in the background and follow its output). Exit 3 = something to install first.
  4. Hand over the `needs_human` steps, then `omacvm check --vm NAME --json`
     until `ok` (the person must be logged in to Omarchy; `needs_human: true`
     entries are theirs). With several VMs, Omanotch serves one at a time: an
     Omanotch failure on the others is expected, and `check` exits 1 for it.
- **Where a VM's features are kept**: an OmacVM.app VM's folder has the
  record in its `features` file (the app reads it at each start); every VM
  has a copy in `/etc/omacvm/env`. `omacvm apply` (and so `enable`,
  `disable`, the control centre's jobs) writes both; the app's Fast network
  button writes the `fast-network` file and the record. `vm.env`'s
  `FEATURES` is only the setup's choice for the first apply, which takes it
  out. The fast network (the app's switch) and autologin (any SDDM
  `[Autologin] User=`, also a file OmacVM did not write) keep their real
  state: `omacvm features`, `check` and `apply` read it and fix the record
  ("fixed the record"). Never edit the record by hand.
- **Switch a feature** on an existing VM: `omacvm features --vm NAME --json`,
  then `omacvm enable|disable FEATURE... --vm NAME --yes`, then
  `omacvm check --vm NAME --json`. Dependencies are handled (scroll-momentum brings
  gestures, bridge off takes wallpaper).
- **CPUs and memory** of an existing VM: `omacvm resources --vm NAME --json`
  (what it has, `limits`, `resource_tiers`), then
  `omacvm resources --vm NAME --resources low|balanced|high|best` or
  `--cpus N --memory-gb N`. Parallels, UTM and Fusion: the VM must be stopped
  (exit 3 otherwise: ask the person to shut it down); OmacVM.app: written to
  `vm.env`, applies on the next start. A name in two apps (or twice in one):
  exit 2; add `--vm-type`.
- **Graphics** of an OmacVM.app VM: `omacvm graphics --vm NAME --json`
  (`graphics`: opengl|vulkan|auto, `next_start`, `this_start` from qemu.log,
  `driver_ready`), then `omacvm graphics --vm NAME opengl|vulkan|auto`:
  written to the VM folder's `graphics` file, applies on the next start; a
  running VM that gets Vulkan builds its Venus driver at once.
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
   OmacVM.app: the same in full screen (Virtual-2, ... at each display's size
   and scale) while "Use external displays" is on; `omacvm-displays status`
   in the VM shows the switch, the Mac's arrangement and Hyprland's outputs;
   `$XDG_RUNTIME_DIR/omacvm/builtin` names the MacBook's output, which
   Omanotch (NOTCH, the parked bar) follows.
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
| Host | Apple Silicon, macOS 14+ (OmacVM.app: macOS 15+; verified 15.7.4, MacBook Pro M4 Max) |
| Parallels route | Parallels Desktop 19+ (verified 27.0.2, Pro trial). Per-VM limits from `prlsrvctl info --license` (`cpu_total`, `max_memory`): Standard 4 CPUs / 8 GB, Pro/Business/trial 32 CPUs (18 tested on Apple Silicon) / 128 GB; build.sh never writes more than the licence allows (Parallels would reject the config). Only `prlctl list/register/unregister` and `prl_disk_tool`; everything else is `config.pvs` (vm/pvs.py); `prlctl start` only as a fallback |
| UTM route | UTM 5 (verified 5.0.6, QEMU 10.0.12); required: on UTM 4.7 GL clients map but never paint (black windows) unless rendering is forced to software (ggalancs/omarchy-arm-utm#7). OmacVM never sets `LIBGL_ALWAYS_SOFTWARE`; VirGL (virtio-gpu-gl), Vulkan off. VM creation through UTM's AppleScript dictionary (`/Applications/UTM.app/Contents/Resources/UTM.sdef`), `utmctl` for start/stop/status/ip-address |
| VMware Fusion route (new) | VMware Fusion 13+ (verified 26.0.1). Needs Hyprland with the vmwgfx fix (`src/fusion/guest/`); see `docs/routes/vmware-fusion.md` (and the build log `docs/experiments/vmware-fusion.md`). `vmcli VM Create`, `vmware-vdiskmanager`, `vmrun start/list` from `VMware Fusion.app/Contents/Library`; the rest is the `.vmx` (`src/vm/fusion.sh`). VMs in `~/Virtual Machines.localized` or `$OMACVM_FUSION_DIR` |
| Tools | UTM, Fusion, Parallels: Xcode Command Line Tools (swiftc, clang, swift, python3, git), Homebrew `zstd` + `e2fsprogs` (live installer), openssl. OmacVM.app: none (it carries python3, its Mac helpers and the Swift answers: `src/lib/tools.sh`); never run a Command Line Tools stub (`/usr/bin/python3`, `swift`, `git` ...) on its route: on a Mac without them each one opens macOS's install window (`src/tests/no-clt.sh`) |
| Network | ~1.4 GB try-omarchy download (live installer) + Arch Linux ARM and Omarchy packages |
| Disk | ~30 GB free for the build (peaks about 25 GB) on the VM's drive, plus ~15 GB on the Mac's disk for the download when the VM goes to another drive (Parallels, Fusion; `src/lib/space.sh`); the VM's disk is expanding and grows as it is used |

## 3. Repository map

The root holds only the entry points (`omacvm`, `install.sh`), the docs and
`docs/` (graphics, route pages, benchmarks, findings), and `app/` (OmacVM.app, its own
build); everything else lives in `src/`: the commands in
`src/cmd/`, one folder per feature, and the install plumbing (`guest/`, `mac/`,
`lib/`, `vm/`). Keep it that way: a short root keeps the README near the top on
GitHub.

| Path | What |
|---|---|
| `omacvm` | The command: dispatches to `src/cmd/*.sh` (`build`, `apply`, `check`, `vms`, `update`, `resources`, `features`/`enable`/`disable` → `features.sh`, no command → `home.sh`, the menu; without a terminal it prints the help, exit 2). Resolves its own symlink, so it works from the PATH |
| `install.sh` | Bootstrap: clones to `~/.omacvm` (or links the clone it runs from), symlinks `omacvm` into Homebrew's bin (else `~/.local/bin`), starts it on `/dev/tty` (works piped from curl) |
| `src/VERSION` | OmacVM's version; copied into the VM with `src/` (what `omacvm vms` reports per VM); also OmacVM.app's version |
| `app/` | OmacVM.app (`git subtree` of the former omacvm-app repo, history kept): `app/` the launcher (Swift, `swift build`), `runtime/` QEMU's build scripts and patches (GPL-2.0: this public repo is the source offer), `scripts/create-vm.sh` (the build the app and `omacvm build --vm-type app` run), `scripts/build-app.sh` (takes `src/` as committed; `--release` needs a clean tree; the commit goes into Info.plist `OmacVMCommit`), `scripts/package-release.sh` (`dist/OmacVM-<version>.zip` + `.sha256` for the GitHub release `v<version>`). Its own README and THIRD_PARTY_NOTICES |
| `src/lib/app.sh` | OmacVM.app from the Mac: its VMs (`app_list`, `app_ip`, `app_start`), the installed app (`app_bundle`), `app_create`, and the download (`app_published`, `app_install`, `app_install_cmd`; curl sets no quarantine) |
| `src/net/mac/` | The fast network for OmacVM.app (feature `fast-network`, opt-in): `omacvm-netd.c`, a root daemon (launchd socket `/var/run/org.omacvm.netd.sock`) that gives OmacVM.app's QEMU (`-netdev stream`) one isolated vmnet shared-mode interface per connection on its own `192.168.77.0/24` (UTM's `192.168.64.0/24` refuses isolated interfaces while UTM uses it) after checking the caller's user and code signature, with a back-off after vmnet failures (each failed start leaks a descriptor in macOS's InternetSharing), and a VPN NAT: while a VM is on it, NAT for networks macOS's sharing does not cover (a VPN connected later) in its own pf anchor `com.apple/org.omacvm.netd` (routing socket, `pfctl -E`/`-X` reference, state `/var/run/org.omacvm.netd.nat`); `install.sh` installs the copy built and signed inside the app (`Contents/Library/LaunchServices`, by `build-app.sh`; built here only for older apps), `--status` (+ `vpn-nat: IF` line), `--remove` (this Mac user; the service when none is left), `OMACVM_ADMIN_PROMPT=gui` for macOS's password dialog (the app's Fast network button, its question before a start, `FastNetwork.turnOn/turnOff`), `=none` for everything the Bridge runs for a VM (never root, exit 3); `--protocol` (`NETD_PROTOCOL`): an installed daemon of the same protocol serves a newer app (`KNOWN_BUILDS` for builds without it); `test.sh` offline tests. For app VMs the VM's `fast-network` file is the switch (button, apply, check). The app picks vmnet or slirp per start (`FastNetwork.swift`, `logs/network`) and swaps to a hot-plugged user-network card and back while the VM runs (`Runner.watchFastNetwork`); `app_ip` then finds the VM in `/var/db/dhcpd_leases` by the MAC on the running QEMU's command line (`app_vm_mac`), never the `fast-network` file (the next start's switch) |
| `src/lib/version.sh` | OmacVM's version order (`version_cmp`, `version_lt`: 3.0.10 > 3.0.9, a pre-release older than its release) and the downgrade guard (`omacvm_downgrade`): `apply`, `enable`/`disable` and `update` stop with exit 3 before changing anything when the VM has a newer OmacVM than the omacvm that runs (an old `~/.omacvm` checkout beside a newer OmacVM.app, #233); `--allow-downgrade` goes back on purpose. The `omacvm` entry script warns when OmacVM.app is newer than the checkout that runs (`omacvm_app_newer`). `src/tests/version-guard.sh` |
| `src/features.tsv` | **The feature list**: name, default (`on`/`off`/`notch`/`laptop`: on with a battery, never on Parallels), sides, tags (`experimental`, `slow`, `notch`, `laptop`, `not-parallels`, `app-only`), needs, title, summary. `feature_default`/`feature_available` in `src/lib/features.sh` turn defaults and tags into on/off and reasons (with `NOTCH` and the VM's `TYPE`). Read by `src/lib/features.sh` (Mac, bash 3.2), `src/guest/install.sh` (VM), `features.sh`; a new feature also needs its case in `build.sh` (`feature_flag`, question), the VM installer and the checks |
| `src/lib/vm.sh` | Finding VMs without starting UTM (`vms_list`: Parallels via prlctl, UTM via utmctl when it runs and answers within 15 s, else UTM's `Registry` preference, which knows VMs outside its folder (state `unknown` while UTM runs: no answer, e.g. over SSH or while macOS asks whether the terminal may control UTM; `resolve_vm` then stops with exit 3, never starts it), and Fusion's VM folders), `vm_type` (running first, Parallels' "invalid" last), `resolve_vm` (no name: "Omarchy", else the only running VM), `vm_probe` (user, version, env, features set up before 2.0), `ssh_setup_command` |
| `src/cmd/build.sh` | Nothing → finished VM. Interactive questionnaire (`src/lib/setup.sh`, bash 3.2, reads `/dev/tty`): Parallels, UTM, VMware Fusion or OmacVM.app (waits until installed; UTM ≥ 5, Fusion ≥ 13; a missing OmacVM.app is downloaded after asking: `OmacVM-<version>.zip` of this OmacVM's GitHub release, checked against the release's signed `OmacVM-appcast.json` (SHA-256, size, Developer ID teams), into ~/Applications; no zip for this version: exit 3; `--yes`: exit 3 with the command), VM name if taken, resources Low/Balanced/High/Best (`tier_values`: Best leaves max(8 GB, ¼) for macOS + GPU; capped by the Parallels licence; custom values also ask Fusion's graphics memory), where the VM goes (Parallels, Fusion), one checklist of every feature in `features.tsv` (defaults on, experimental ones marked), user/full name, summary, password. Options: `--vm-type --vm-name --vm-dir --resources --cpus --memory-gb --disk-gb --graphics-gb --user --full-name --hostname` (`--graphics-gb`: Fusion only, 1-8 GB of the VM's memory) (`--vm-dir`: Parallels and Fusion only; the drive must be APFS or Mac OS Extended with 30 GB free), `--feature NAME=on|off` / `--FEATURE` / `--no-FEATURE`, `--yes --dry-run --plan --json`, `--parallels-edition standard|pro` (only while Parallels reports "No license installed", a fresh install whose trial starts with the first VM: the edition to size by; the questionnaire asks it, default standard), hidden `--channel` (default: omarchy-mac's `stable` lane once published, else `rc`); `OMACVM_PASSWORD` for `--yes`. Ends with one `apply` call (Mac side, VM side, Omanotch). `--vm-type app`: vm.env into OmacVM.app's VMs folder (`app_vms_root`: ~/OmacVM unless set in the app; `app_vms_roots` also lists older folders and the old hidden one), the app's own `Contents/Resources/scripts/create-vm.sh` builds the VM (password on stdin), then the same `apply` |
| `src/cmd/check.sh` + `src/guest/check.sh` | Read-only feature check, Mac side then guest side over SSH (`bash -s` of `src/guest/check.sh`, so it works on VMs with an older copy). One line per feature, exit 1 on any FAIL (WARN = works on a fallback, e.g. an app VM's Vulkan on MoltenVK because KosmicKrisp could not run; it does not fail the check); `--json` (guest side `--tsv`) with `needs_human` and `feature` (the `features.tsv` name, "" = general; set with `FEATURE=` before the lines) per check; `--mac-only` skips the guest. Add a line here for every new feature |
| `src/cmd/apply.sh` | OmacVM onto a running VM (a stopped one is started): reads the VM (`vm_probe`), merges `--feature` changes (dependencies via `features_fix`), installs the Mac side those features need (`src/mac/install.sh --quiet`, `--omanotch` with that feature), copies the bridge token, the VM's control key (control-centre on) and `src/` to `/usr/local/share/omacvm` (unpacked beside the old copy, swapped in when complete; same layout there, without `src/`), runs `src/guest/install.sh` with every feature explicit, Dock icon (Parallels). `--reinstall F` repairs one feature (its Mac helper with `--force-app`, `guest/install.sh --only F`); `--transaction` (the control centre's jobs) goes back to the old copy and features on failure and exits 4; `--yes` asks nothing. No SSH access: exit 3 with the command for the VM's terminal; another SSH host key than the one remembered: exit 3 (`--reset-host-key` after a rebuild) |
| `src/cmd/graphics.sh` + `src/lib/graphics.sh` | `omacvm graphics`: OmacVM.app's Graphics setting (the VM folder's `graphics` file: opengl, vulkan, auto). The same rules as the app's `Graphics.swift` (Automatic: Vulkan on macOS 26+ with KosmicKrisp in the app and the VM's Venus driver there, `venus-ready` from apply; the Venus host memory window from the memory plan); `src/tests/graphics-setting.sh` checks both agree |
| `src/cmd/resources.sh` + `src/lib/resources.sh` | `omacvm resources`: a VM's CPUs and memory, read (`res_get`) and changed (`res_set`) in its app's own settings: Parallels `prlctl set` (Standard has none: `pvs.py resources` while unregistered, as the build), UTM `System.CPUCount`/`MemorySize` in config.plist (through UTM's scripting while UTM runs, it keeps what it read), Fusion `numvcpus`/`memsize` (and `svga.graphicsMemoryKB` lowered when it would no longer fit), OmacVM.app `CPUS`/`MEM_MB` in vm.env. Tiers and limits from `src/lib/setup.sh` (`mac_specs`, `tier_values`, `parallels_limits`), as the build. Refuses a name found in two apps or twice in one. Tests: `src/tests/resources.sh` (fixtures; `--live` also on throwaway VMs it creates and deletes, none started) |
| `src/cmd/features.sh` | `features` (list, `--json`, or a checklist in a terminal), `enable`/`disable`; changes go through `apply.sh` |
| `src/cmd/update.sh`, `vms.sh`, `home.sh` | `update`: git pull (clean clone only, then re-exec), Mac side as installed (Omanotch included), OmacVM.app when installed and older than `src/VERSION` and that zip is published (in place, its install name kept; not while the app or one of its VMs runs), `apply --no-mac` on every running OmacVM VM. `vms`: table or `--json`. `home.sh`: the menu |
| `src/mac/install.sh`, `src/mac/uninstall.sh` | Mac side: bridge, gestures, clipboard helper, Omanotch (`--omanotch`, its own `mac/install.sh`); an app whose sources and options are unchanged since its install is skipped (stamps in `~/Library/Application Support/omacvm/installed`, `--force`). `src/mac/parallels-shortcuts.sh`: empty Parallels' Linux keyboard profile (opt-in, app-wide) |
| `src/guest/install.sh` | Guest side, root, idempotent. Detects the VM type (DMI vendor Parallels/QEMU), writes `/etc/omacvm/env`, runs the shared features and the per-type ones. `default-keyring.sh` (also run by the prebuilt first boot): Omarchy's default keyring (no password) for a home without keyrings (restarts a running gnome-keyring, which would not see it), never another default for a home with its own; check line "keyring"; `src/tests/default-keyring.sh` |
| `src/prebuilt/` | Prebuilt VMs (`docs/prebuilt.md`): `make-image.sh ROUTE [build generalize package upload clean]` makes one (`omacvm build --image`: placeholder user `omacvmuser`, nothing of the Mac, no Parallels Tools), `guest/generalize.sh` strips it in the VM, `guest/omacvm-firstboot` + its service (before SDDM: grows the disk, user from the OMACVM-SEED ISO or console questions, home from `/var/lib/omacvm/prebuilt/home`), `lib.sh` (lookup on GitHub releases `prebuilt-*`: newest image, same major, version up to ours; download, unpack, seed ISO), `vm.sh` (`omacvm build --prebuilt`: unpack, new ids/MACs, seed, first boot, `apply`, seed removed), `vmconfig.py` (config.pvs/config.plist/.vmx edits), `manifest.py`, `sha512crypt.py` (`$6$` hash without Homebrew, for the app). OmacVM.app: `make-image.sh app` (the app's `create-vm.sh` with `OMACVM_CREATE_IMAGE=1`, headless, disk.img only), `app/scripts/prebuilt-vm.sh` (the app's twin of `create-vm.sh`: download, unpack, seed, headless first boot, apply) |
| `src/vm/live/` | Temporary live installer (from vincenzopalazzo/omarchy-parallels, MIT): try-omarchy → bootable ARM64 Linux with SSH; a Parallels VM, or `--raw-image` for UTM |
| `src/vm/base-install.sh` | In the live system: GPT + btrfs on the NVMe disk, pacstrap, locale/keyboard/user, GRUB |
| `src/vm/omarchy-install.sh` | In the new system: omarchy-mac `install.sh --channel rc`, unattended; SSH rule for the Mac's network |
| `src/vm/progress.sh` | Sent in front of the two above by OmacVM.app: pacman's output -> `{"omacvm_progress": 1, ...}` lines (package n of N, download bytes from the cache size); raw lines as `\| line` for the step log |
| `src/vm/pvs.py` | Parallels `config.pvs` editor (settings, NVMe disk, boot order, shares) |
| `src/vm/fusion.sh` | VMware Fusion: create the VM (`fusion_create`: vmcli, then `.vmx` lines; the raw live image through a monolithicFlat descriptor), drop the live disk |
| `src/fusion/` | Fusion guest specifics: public DNS (`dns.sh`), Hyprland with the vmwgfx fix (`build-hyprland.sh`, the patch, a pacman hook that rebuilds after hyprland upgrades), VMware Tools (`build-open-vm-tools.sh`), the display layout (`omacvm-fusion-layout`, `omacvm-fusion-displays` + its user unit), `monitors.lua` |
| `src/vm/utm.sh` | UTM: create the VM (AppleScript `make new virtual machine`), drop the live disk, app-wide speed settings |
| `src/lib/mac.sh` | Mac helpers: `gssh`, Parallels (`vm_ip` by DHCP lease, `vm_state`, `vm_start`), UTM (`vm_type`, `utm_ip`, `utm_state`, `utm_start`, `utm_wait_stopped`) and Fusion (`fusion_list`: Fusion's `vmInventory`, running VMs and `$FUSION_DIR`, `fusion_ip` from `vmnet-dhcpd-vmnet8.leases`, `fusion_state`, `fusion_start`, `fusion_host`) |
| `src/guest/omacvm-omanotch.service` | The omanotch feature: one-shot user unit that runs `/usr/local/share/omacvm/omanotch/guest/install.sh` in the first desktop session (it needs Hyprland running), skipped once `~/.local/bin/notchcast` exists. `src/guest/install.sh` removes notchcast when that copy changed (stamp `~/.local/state/omacvm/omanotch`), so it installs again |
| `src/omanotch/` | Omanotch (`git subtree`, history kept): `mac/` (Omanotch.app, Swift; `mac/test.sh` = offline tests), `guest/` (`notchcast`, the bar, background and display panel patches, `notchbar.lua`; `guest/tests` = offline tests). Its own README. Work on it here; github.com/gillesgoetsch/omanotch is archived and points here |
| `src/lib/install-plugin.sh`, `src/lib/omacvm-plugins` | Omarchy shell plugin install; queues until the shell runs (first login); restarts the shell once when a plugin's files changed |
| `src/lib/sign.sh` | Signs Mac apps with `designated => identifier "<id>"`, so TCC grants survive rebuilds |
| `src/control/` | Feature `control-centre` (docs/adr/0030-0032): `omacvm` in the VM, a Textual TUI (`omacvm_cc/tui.py`; `state.py` = the pure status rules, `controller.py` = data, `bridge.py` = the client with the Bridge's proof, `report.py` + `collect.py` = report a problem with redaction and a gate, also run by the Mac's `omacvm report` with macOS's python3 3.9, or OmacVM.app's 3.13 on a Mac without the Command Line Tools: keep it 3.9-compatible). `omacvm status [--json]`, `omacvm report`, `omacvm notify` (user timer: one notice per new version unless update checks are off). Guest install (`guest/install.sh`): `python-textual`, `/usr/local/bin/omacvm`, root socket `omacvm-check.socket` (runs `guest/check.sh --tsv` for the desktop user, nothing read from the caller), desktop entry, a marked row in `~/.config/omarchy/extensions/omarchy-menu.jsonc`, bar plugin `plugins/omacvm.control`. Tests: `tests/` (pytest + Textual Pilot against `tests/fakes.py`), `tests/vm_e2e.py` drives the real TUI in a test VM |
| `src/release/` | Update manifests (ADR 0032): `parts.tsv` (files → parts, first match wins, `core` last), `manifest.py digests|build|parts`, `sign.swift keygen|sign|verify` (Ed25519), `release-key.sh sign|team|teams|spare` (signs with the Keychain key and checks it), `keys.py` (verify on the command line: plain-python Ed25519, either key, kept spares). `omacvm apply` writes the digests it installed to the VM's `/etc/omacvm/installed.json`. Release keys: `src/lib/release-key.pub` (main) and `release-key-spare.pub`, either one signs; documents carry `kind` and `devid_teams`; who holds the private halves and how to rotate: `docs/release-keys.md`. A release: `release.sh` (every step, `--dry-run`, rollback; `docs/releasing.md`). Tests use `OMACVM_FEED_URL` + `OMACVM_FEED_KEY` (Bridge), `OMACVM_APPCAST_KEY` (app test builds), `OMACVM_RELEASE_TEST_KEYS` (command line), all throwaway keys |
| `src/lib/helpers.sh` | OmacVM.app's prebuilt Bridge, Gestures and Omanotch (`Contents/Helpers`, Developer ID; `app/scripts/build-app.sh` builds and signs them): `src/mac/install.sh` installs them (`install.sh --prebuilt`) when built from the same sources, else builds (with Xcode's Command Line Tools; without them it says so and builds nothing); `src/tests/prebuilt-helpers.sh` |
| `src/lib/tools.sh` | Apple's developer tools without Xcode's Command Line Tools (sourced by `mac.sh` and `app/scripts/vm-common.sh`): `clt_has` (asks `xcode-select -p` first, never a stub), `tools_python` / `tools_path` (macOS's python3 with the tools, else OmacVM.app's `Contents/Resources/python` from `app/scripts/fetch-python.sh`, first on PATH; `PYTHONDONTWRITEBYTECODE=1`, so nothing is written into the signed app), `mac_tool NAME` (the app's built `Contents/Resources/tools/NAME`, else `swift src/*/NAME.swift`: mac-notch, mac-display, mac-clock, mac-free-gb). Test: `src/tests/no-clt.sh` (stand-ins for every stub) |
| `src/bridge/` | OmacVM Bridge: `mac/*.swift` (OmacVMBridge.app), `guest/` (client, shared event stream, OSD follower, nightlight and Wi-Fi QR command replacements), `plugins/omacvm.{wifi,audio,wifiqr,nightshift}`. External display brightness (feature `external-brightness`): `mac/external-brightness.swift` (DDC/CI over IOAVService, Apple displays over DisplayServices, found per display at run time; one serial queue, coalesced writes), `mac/external-model.swift` (steps, DDC packets, which display; `mac/test.sh` offline, `--live` on this Mac's displays, always restoring), `/display/external*` in the API, `guest/omacvm-ddcutil` as `/usr/local/bin/ddcutil` in the VM so Omarchy's own DDC path asks the Bridge (`src/tests/external-brightness.sh`). Night light: the Mac's Night Shift only; the guest install hides Omarchy's NightLight indicator (`items` of `omarchy.indicators` in `shell.json`, original kept in `~/.local/state/omacvm/nightlight-indicator`, restored with bridge=off) and stops `hyprsunset`. `mac/control_policy.swift` + `control.swift`: the control centre's fixed request list under `/omacvm/` (ADR 0031; the VM is worked out from the peer address via `omacvm vms --json` and proves itself by signing each request with its own key, which never leaves it, jobs run the CLI named in `~/Library/Application Support/omacvm/cli` (written only by the installed checkout, `cli_for_bridge` in `src/lib/mac.sh`: a worktree that runs `src/mac/install.sh` does not take it over; `OMACVM_SET_CLI=1` forces it; OmacVM.app takes it from a checkout with an older OmacVM, and a checkout never takes it from a newer omacvm: `cli_file_app`, `ControlCLI.swift`) with posix_spawn, own session, responsibility disclaimed so macOS's Local Network privacy lets its ssh through; job files in `omacvm-bridge/jobs/`); `mac/tests/run.sh` tests the policy |
| `src/gestures/` | OmacVM Gestures: `mac/omacvm-gestures.c` (MultitouchSupport + event tap, created again when an OmacVM VM comes to the front; never enabled or created without Accessibility: a permission taken away (Accessibility, or Input Monitoring or "control the computer" = `CGPreflightPostEventAccess` when the tap was made with it; those two cost ~5 ms of tccd each and are asked off the main thread every 10 s) removes the tap and stops the trackpads at once, back when it is granted again, #192 (the Bridge's media-key tap and QEMU's full-grab tap, `omacvm-cocoa-tap-permission.patch`, likewise; QEMU's goes on whichever of the two it was made with, as OmacVM.app may hold only "control the computer"); ⌃⌥ Esc (exact modifiers; the old ⌃⌥⌘ Esc still works through 3.0.x, the guest names the new one once per VM, then it is removed) moves the display under the pointer out of the VM with macOS's own Space shortcut (`EscapeSwipe` = `all` in `org.omacvm.gestures`: every display), and back; shortcut off or Space unchanged = a Dock swipe (macOS 15 ignores the shortcut from the notched display's full-screen Space); still no way out = a log line and a notice in Omarchy, never out of full screen; a late Space change is looked for before the next step (one press, one Space); Mission Control only on a double press (twice within 0.4 s); `mac/test-escape.c` tests it against a made-up world of displays and Spaces; also hides the Mac's pointer over the full-screen VM; a Magic Mouse's two-finger sideways swipe = three virtual fingers (workspaces), its one-finger flick = Back/Forward keys, `mac/mouse-model.h` + `mac/test-mouse.c`; offline tests `mac/test.sh`), `guest/omacvm-gestures` (uinput touchpad; Glide), `guest/glide.sh` + `guest/omacvm_glide.lua` (Glide's Hyprland settings and Chromium flag). The scroll momentum's tuning history: `docs/experiments/trackpad-scrolling.md`, analysis scripts in `docs/experiments/scroll-analysis/` |
| `src/display/` | Parallels: `parallels-dynres` + `monitors.lua`. `mac-display.swift`: the built-in display below the notch, for UTM |
| `src/utm/` | UTM guest specifics: guest tools, virtio-gpu environment, fixed display mode |
| `src/app/guest/` | OmacVM.app's VM side: `omacvm-display-sync` (each output follows its Mac window or display: mode, scale by EDID, position from the Mac's arrangement; Omarchy's zoom only for Virtual-1), `omacvm-displays` (user service on virtio port `org.omacvm.display`: hello and the switch to QEMU, the arrangement from it, Hyprland's outputs back for the pointer; `external on\|off\|toggle`, `status`), `monitor-widget/` (bar widget `omacvm.monitor` = Omarchy's display panel built from the installed Omarchy plus MAC DISPLAYS "Use external displays"; rebuilt by the agent after an Omarchy update), clipboard, guest agent, notch strip |
| `src/workspaces/` | Per-display workspaces: `monitor_workspaces.lua` (Virtual-1 IDs 1..10, Virtual-N (N-1)\*10+1..; an unplugged display's workspaces park on Virtual-1 and go back on replug), bindings, `plugins/omacvm.workspaces`, `tests/` (park and unpark against a fake Hyprland) |
| `src/clipboard/` | Parallels only: VM → Mac copy (guest `parallels-clip-out`, Mac `omacvm-clip-in`) |
| `src/battery/` | The Mac's battery (feature `battery`; UTM, Fusion, OmacVM.app; Parallels has its own): DKMS module `omacvm_battery` (BAT0, ADP0; from try-omarchy, GPL-2.0-only), root agent `omacvm-battery` (OmacVM.app: virtio port `org.omacvm.battery`; UTM/Fusion: the Bridge's `battery` events through `bridge/guest/omacvm-bridge`), UPower never suspends for it. Mac side: `bridge/mac/battery.swift`, OmacVM.app's `NativeBatteryBridge.swift`. Its README |
| `src/wallpaper/` | Guest `omacvm-wallpaper` (path unit) → `POST /wallpaper` on the bridge |
| Video decoding (OmacVM.app) | Guest VA-API (Mesa virgl) → virglrenderer's video protocol → VideoToolbox backend (`app/runtime/patches/virgl-videotoolbox-decode.patch`: `src/vrend/virgl_video_vt.c`; SPS/PPS rebuilt for H.264, VPS/SPS/PPS for HEVC with an explicit short-term RPS rewritten into every slice header (VA-API omits the SPS's sets), AV1 frames cut from the temporal unit by the first tile's offset, VP9 frames as they come; bit-exact against FFmpeg's software decoding; IOSurface → GPU copy into the guest's textures). VM side in `src/app/guest/install.sh`: `vainfo`, VA driver shim `omacvm_drv_video.c` (`LIBVA_DRIVER_NAME=omacvm`, `/usr/local/lib/dri`: NV12 surfaces only, AV1 only for Chromium-based processes), Firefox pref. QEMU env: `OMACVM_VIDEO_DECODE=0`, `OMACVM_VIDEO_DEBUG=1`, `OMACVM_VIDEO_AV1=1` (the app sets it when the VM folder has `video-decode` = `av1`, written by `apply`). Guest profile numbers are Mesa ≥ 26's (`OMACVM_VIRGL_VIDEO_ABI=legacy`). `docs/video-decode.md` |
| Chromium video (OmacVM.app) | Feature `chromium-video` (tag `app-only`: on in OmacVM.app VMs, off elsewhere). Arch Linux ARM's Chromium has no VA-API, only V4L2 (ADR 0025). `src/vdec/guest/`: kernel module `omacvm-vdec` (DKMS, `module/`: V4L2 stateful decoder, no decoding of its own; CAPTURE = single-plane ARGB (`V4L2_PIX_FMT_ABGR32`) dmabufs the daemon hands in; protocol in `module/omacvm-vdec.h` (`OVD_VERSION`: daemon and module of different builds refuse each other, daemon exit 3), control device `/dev/omacvm-vdec`; instance ids cyclic (never reused); max 8 open, 256 unread messages per decoder; daemon gone = errors, not hangs) + `omacvm-vdecd` (FFmpeg VA-API decode, GL pass NV12→ARGB into GBM buffers, EGL fences with a 1 s timeout; one failing video fails alone; H.264 + VP9, HEVC only with `OMACVM_VDEC_HEVC=1` since Chromium 153's stateful V4L2 decoder lacks it; service `omacvm-vdecd` as user `omacvm-vdec`, `WatchdogSec=5`, status in `/run/omacvm-vdec/status`, `OMACVM_VDEC_DEBUG=1`; GPU not usable at start = the daemon waits 0 s -> 118 s (count in `/run/omacvm-vdec/gpu-tries`, `RuntimeDirectoryPreserve=restart`, cleared when ready), then exit 4, `RestartSec=2` (flat: crashes still restart in 2 s); exit 127 (a library gone) is not restarted; pacman hook `95-omacvm-vdecd.hook` (any `usr/lib/*.so*`) → `vdecd.sh hook`: built again when a library in its own NEEDED is gone (new FFmpeg soname), started when down or not ready; `vdecd.sh why` = the check's reason (last run only, `_SYSTEMD_INVOCATION_ID`); `vdecd.sh vafail` = the "video decoding" FAIL line when `vaInitialize` failed; test `src/tests/vdecd-down.sh`). Module update while an app has it open: installed, loaded at the next VM start (`omacvm check` says so). DKMS helpers shared with battery/camera: `src/guest/dkms.sh`. `chromium-flags.py` (as the user) adds `AcceleratedVideoDecoder` and the `no-av1` extension (YouTube sends VP9) to the last `--enable-features`/`--load-extension` of `~/.config/chromium-flags.conf`, marker `~/.local/state/omacvm/chromium-v4l2-flags.json`. WirePlumber rule `50-omacvm-vdec.conf` (`/etc/wireplumber/wireplumber.conf.d/`): WirePlumber 0.5 hangs, and links no sound, on a V4L2 device it cannot open (the decoder without a ready daemon), so it leaves the decoder alone; `install.sh` restarts a running WirePlumber once when the rule is new, before it loads the module, never during a call (`in_call`: a running `Stream/Input/Audio` node; then the module waits for the next VM start). `70-omacvm-vdec.rules`: the misc device `/dev/omacvm-vdec` belongs to the daemon and starts it (`TAG+="systemd"`, `SYSTEMD_WANTS`) whenever the module loads, also late (`src/tests/vdec-wireplumber.sh`). `install.sh USER on|off` from `guest/install.sh` (app VMs). Test: `test/vdec-test.c` (V4L2 like Chromium vs FFmpeg software; `--churn`, `--early-drain`, `--expect-fail`, `--stall`, `--flood`). `docs/video-decode.md` |
| `src/camera/` | Feature `camera` (from try-omarchy): guest `omacvm-camera` (user service) feeds `/dev/video42` "Mac Camera" (v4l2loopback via DKMS, `exclusive_caps`) and asks the Mac for frames only while v4l2loopback reports a reader: Bridge `GET /camera` (UTM, Fusion; `src/bridge/mac/camera.swift`) or OmacVM.app's virtio port `org.omacvm.camera` (same Swift file, linked into `app/app/Sources/OmacVM`). Parallels passes the camera itself (a USB camera, `uvcvideo`, "MacBook Pro Camera" on /dev/video0; `SharedCamera` in config.pvs): nothing installed there. `omacvm-camera --status` for the check |
| `src/keyboard/` | `mac-layout.sh` (macOS input source → XKB), guest layout + Cmd+V paste |
| `src/memory/`, `src/kernel/` | zram/sysctl/THP-defrag/MGLRU; opt-in memory-optimized kernel (THP always + MGLRU) from ALARM's PKGBUILD, built only with `--thp-kernel`. ALARM's stock `linux-aarch64` has `# CONFIG_TRANSPARENT_HUGEPAGE is not set` and `# CONFIG_LRU_GEN is not set` (verified 7.2.8), so the THP/MGLRU tmpfiles lines are no-ops there (systemd-tmpfiles skips missing files) |
| Feature switches | `src/guest/install.sh --feature NAME=on\|off` for every feature in `src/features.tsv`, kept in `/etc/omacvm/env`; `omacvm apply` passes all of them (also `--[no-]FEATURE`). omanotch=on: `omacvm-omanotch.service` installs Omanotch from the copy of `src/omanotch` in the session (now if Hyprland runs, else at the next login), again when that copy changed; the clone earlier versions made in `~/.local/share/omanotch` is removed; off: `src/guest/off.sh` (Omanotch's own `guest/uninstall.sh` in the session, its files also without one, and an install queued for the next login). scroll-momentum ("glide" in the code; the old key in /etc/omacvm/env still maps to it): `gestures/guest/glide.sh` on/off (`omacvm_glide.lua` required from `hyprland.lua`, `--disable-smooth-scrolling` in existing `chromium-flags.conf`/`chrome-flags.conf`, marker `~/.local/state/omacvm/glide-flags` so off removes only what it added). no-idle-lock=on (called idle-lock before 3.0.1, on and off the other way round; old names and values are read through `feature_alias`/`feature_old_value` in `src/lib/features.sh`, `FLIPPED_OLD_NAMES` in the control centre, and are never written) = Omarchy's own Stay Awake file (`~/.local/state/omarchy/indicators/stay-awake`, watched by the shell) plus an OmacVM marker so turning it back on never undoes a user's own Stay Awake. bridge=off disables the clones (Omarchy restores its stock widgets; nobody logged in: at the next login, `pending-plugins-off`) and removes the client. battery: `battery/guest/install.sh on|off` (forced off on Parallels); chromium-video: `vdec/guest/install.sh USER on|off` (OmacVM.app VMs; forced off on the other routes); on UTM and Fusion `omacvm apply` installs the Bridge for it even with bridge=off. Gestures off: the VM's daemon is disabled on every route (also UTM, Fusion and OmacVM.app, where it typed Cmd as Super), so the VM does not connect to the Mac's Gestures. `--keys-only` on the Mac app is a Mac-wide off switch |
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
OmacVM.app (QEMU's window code): virtio port ◀───▶ omacvm-displays (user) → omacvm-display-sync → Hyprland
  org.omacvm.display: arrangement out; hello, "Use external displays", Hyprland's outputs back
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
  and the scroll momentum (a trackpad's scroll events dropped, `A`/`W`/`P`
  sent, every two-finger frame forwarded) only when they all want that.
  Which scroll is a trackpad's: `mac/scroll-model.h`, per event (phases and
  momentum of a scroll made while a trackpad has two fingers on it); wheel
  mice, smooth-scrolling mice and a Magic Mouse always pass to the VM app.
- OmacVM.app's keyboard: while QEMU's window has the keyboard (full grab, app
  active, window key) macOS's global shortcuts are off
  (CGSSetGlobalHotKeyOperatingMode, `omacvm-cocoa-system-shortcuts.patch`;
  logic in `omacvm-cocoa-shortcuts-logic.patch`, tested against macOS's whole
  list by `app/runtime/Tests/keys/test-shortcuts.sh` and in a real QEMU by
  `src/tests/vm-shortcuts.sh`). The switch belongs to QEMU's window-server
  connection (macOS restores it when QEMU dies); a watchdog thread turns it
  on after 2 s without the main thread. Off by default since 2.9.1 (not
  always handed back on the Mac mini): `macShortcuts` (org.omacvm.app,
  default true) → `OMACVM_MAC_SHORTCUTS=1` keeps them with macOS; false
  turns the switch on. Gestures' tap still takes ⌃⌥ Esc (and the old ⌃⌥⌘ Esc) first;
  QEMU's tap lets both through to it (omacvm-cocoa-escape-combo-tap.patch); the Bridge
  still routes media keys.
- Escape combo (Gestures): NEVER take the VM out of full screen or hide it
  (user, 2026-10-05). Out = macOS's own "Move left/right a space" shortcut
  (symbolic hotkeys 79/81, read per press: key, modifiers, enabled), posted
  at the HID level once the combo's keys are up, marked 0x0BAC0E5C (our tap
  and QEMU, `omacvm-cocoa-keys-for-macos.patch`, let it through), toward the
  Space the display showed before (`cameFrom`). Each move is checked: not
  moved or shortcut off → a Dock swipe (macOS 15 ignores the shortcut from
  the notched built-in's full-screen Space; the user's log 2026-10-06), then
  the other direction once; still not moved, or no Spaces info → one log
  line and `N <why>` (a notice in Omarchy), nothing else: NEVER Mission
  Control (user, 2026-10-06). Back in: the shortcut, else the VM's window to the front. An
  OmacVM.app window with the
  keyboard: the combo gives it to the app from before / Finder
  (`COMBO_WINDOW_OUT`), again in macOS brings the window back.
- Bridge media keys: the tap is at `.cghidEventTap` (macOS 27 sends volume
  only there). Brightness keys reach no tap on macOS 27: `hid-keys.swift`
  reads them with IOHIDManager (not seized; Input Monitoring): F1/F2 through
  the keyboard's own `FnFunctionUsageMap` (IORegistry; none on an Apple
  keyboard, also Bluetooth vendor 0x004C: Apple's F1/F2 default) and
  `com.apple.keyboard.fnState`, or the consumer/Apple brightness usages;
  acted on only with an OmacVM.app VM in front (`MediaRoute`), deduplicated
  against the tap (`BrightnessOnce`), and not stepped again when macOS
  changed the display itself (`OwnSteps`: not when the Bridge stepped it
  itself meanwhile). Held keys repeat at macOS's key repeat speed.
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
  (gestures), none for Omanotch, Camera (bridge on UTM and Fusion, OmacVM.app, Parallels Desktop; asked when a Linux app
  first uses it), Microphone (the VM's app). Reset: `tccutil reset Accessibility org.omacvm.bridge` (and `org.omacvm.gestures`,
  `ListenEvent`), then `launchctl kickstart -k gui/$(id -u)/org.omacvm.<app>`.
- **Test identity (one per Mac, granted once)**: macOS keys a grant on the bundle id and the signing team, so
  every renamed or ad hoc test copy asks again. Test with only this one:
  `OMACVM_SIGN_ID=<Developer ID> app/scripts/build-app.sh --test-identity --install` builds "OmacVM Test"
  (`org.omacvm.app.test`) and copies it over `~/Applications/OmacVM Test.app`; its helpers in
  `Contents/Helpers` are "OmacVM Test Bridge" (`org.omacvm.test.bridge`, port 47931,
  `~/Library/Application Support/omacvm-test-bridge`) and "OmacVM Test Gestures" (`org.omacvm.test.gestures`,
  port 47930, settings domain `org.omacvm.test.gestures`). The test Bridge and Gestures take only OmacVM
  Test.app's VMs (and a lane's copy re-signed as `org.omacvm.app.test.<lane>`), the normal ones only the others (the Bridge reads the app a VM runs from, Gestures the VM's
  code signature `<bundle id>.qemu`; a development build's QEMU is every helper's). Its VMs reach Omanotch on 47911 only: a test Omanotch
  (src/omanotch/mac build, `port` 47911, `bridgeDir` omacvm-test-bridge) on a Mac without the user's. Start a helper with `open` (so macOS checks its own
  grant, not the Terminal's); small tools without a bundle run as children of your shell (the Terminal's grants).
  Never `src/mac/install.sh` from a test: that installs over the user's helpers. The test app's own
  `Contents/Resources/omacvm/omacvm` (and its VM scripts) run by hand is the test identity too (src/lib/identity.sh).
- **Logs**: `~/Library/Logs/omacvm-{bridge,gestures}.log`; guest
  `journalctl --user -u omacvm-bridge-osd` (and `-u omacvm-bridge-events`, the shared event stream), `journalctl -u omacvm-gestures`,
  Omarchy shell `/run/user/1000/quickshell/by-id/*/log.log`.
- **Uninstall**: `src/mac/uninstall.sh [--purge]`; delete the VM in Parallels, UTM or Fusion.

## 7. Failure modes

The less obvious ones, with causes and where the fix lives, are in
`docs/troubleshooting.md`.

| Symptom | Cause | Fix |
|---|---|---|
| Black screen at start, journal: `Couldn't open a GBM device` | partial update: Mesa newer than its LLVM (`ldd /usr/lib/gbm/dri_gbm.so` shows "not found") | full `pacman -Syu`, or `pacman -U` the old Mesa from the cache; `src/guest/gbm-guard test` (docs/troubleshooting.md, 27) |
| `omacvm apply`/`enable`/`disable`/`update`: "has OmacVM X, this omacvm is Y ... does not go back" (exit 3) | an older omacvm runs (an old `~/.omacvm` checkout first on the PATH, beside a newer OmacVM.app) | the app's own `Contents/Resources/omacvm/omacvm`, or `omacvm update` first; `--allow-downgrade` only to go back on purpose |
| `omacvm check`: Omanotch not connected, Mac log says "another guest is connected" | Omanotch serves one VM at a time | close or stop `notchcast` in the other VM |
| Bar widgets missing after a fresh build | the Omarchy shell was not running at install time | queued; `omacvm-plugins.service` enables them at the first login |
| `OMARCHY_PATH is not set` from omarchy commands run as root/sudo | no Omarchy env | `source /usr/share/omarchy/default/bash/env-bootstrap` first |
| A command replacement in `/usr/local/bin` is ignored by the bar | the Omarchy shell runs with `/usr/share/omarchy/bin` (symlinks to /usr/bin) first on PATH; Hyprland does not | call `/usr/local/bin/...` by full path from QML (see `omacvm.wifiqr`) |
| `Target not found` / "handler will not be used" for a widget's IPC | a clone kept the stock widget's IPC target | give clones their own target (`omacvm.wifi`) |
| Updated widget does not change | a running shell keeps loaded plugins | `src/lib/install-plugin.sh` flags changes; `src/guest/install.sh` runs `omarchy-restart-shell` |
| Disabling an old clone brings the stock widget back next to the new one | `clonedFrom` hand-back | rename ids in `shell.json` instead, or disable the stock widget |
| SSIDs null, `location_authorized: false` | Location Services not granted (new bundle id or reset) | Privacy & Security › Location Services |
| Media keys still show the macOS popup | Accessibility missing (`permissions:` line, `omacvm check`), no VM in front (Parallels/UTM/Fusion: not full screen), or capture switched off in the bridge menu | `media keys:` / `media key ...: to macOS:` lines in the bridge log |
| Build stops right after the Omarchy install | Omarchy enables ufw; new SSH connections from the Mac are refused | `src/vm/omarchy-install.sh` adds the rule while its own session is open |
| `ERROR: problem running` from ufw | rule stored but not applicable live right after the install | ignored on purpose; verified with `ufw show added` |
| UTM desktop blank after a resolution change | virgl under UTM cannot switch modes live | fixed mode in `monitors.lua`, reboot to change it |
| OmacVM.app: video still decodes on the CPU | the app predates video decoding, or `vainfo` lists nothing; in Arch's Chromium: `omacvm-vdecd` not running, no module for the running kernel, the flags not in `~/.config/chromium-flags.conf`, or the codec is AV1/HEVC/10-bit | `omacvm check` (video decoding, video decoding in Chromium: says why the daemon is down); `journalctl -u omacvm-vdecd`; `OMACVM_VIDEO_DEBUG=1` logs each stream in the VM's `logs/qemu.log` (`docs/video-decode.md`) |
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

- Do not install packages in the VM with `pacman -S --needed` or refresh the
  package list with `pacman -Sy` (without `u`): use `src/guest/pkg-add`, which
  installs only missing packages and never updates one alone. A partial update
  (2026-10-06: Mesa 26.2.4 next to LLVM 22) leaves GBM unable to load and the
  VM on a black screen (docs/troubleshooting.md, 27).
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
  checks (with `FEATURE=` so the control centre maps them), a part in
  `src/release/parts.tsv` when it has its own files, the README's tables and
  `docs/guide.md`'s feature list. Off means
  off on every route: nothing of it runs in the VM or connects to the Mac
  (a `*_off` in `src/guest/off.sh` that runs whenever it is off, also with
  nobody logged in), the Mac side does not serve that VM, `omacvm check`
  says "off"; a line in `src/tests/features-off.sh`'s table says how. Experimental features are off by default
  and say so wherever they are offered.
- Verify on real VMs before committing behaviour changes: `omacvm apply` against a
  test VM, `omacvm build --vm-name "OmacVM Test"` (and `--vm-type utm`) for the full path,
  then `omacvm check --vm <name>` must pass.
