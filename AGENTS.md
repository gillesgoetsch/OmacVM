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
  out. An app VM's folder also has `mac-setup` ("token <hash>": which Mac's
  Bridge token `omacvm apply` gave the VM; `src/lib/mac-setup.sh`). The fast network (the app's switch) and autologin (any SDDM
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
  exit 2; add `--vm-type`. Memory above the Mac's Best tier is allowed:
  `warning` in the JSON (a `Warning:` line in text) says what it leaves
  macOS; pass it on to the person, and never lower their setting unasked.
- **Graphics** of an OmacVM.app VM: `omacvm graphics --vm NAME --json`
  (`graphics`: opengl|vulkan|auto, `next_start`, `this_start` from qemu.log,
  `driver_ready`), then `omacvm graphics --vm NAME opengl|vulkan|auto`:
  written to the VM folder's `graphics` file, applies on the next start; a
  running VM that gets Vulkan builds its Venus driver at once.
- **Full screen including notch** of an OmacVM.app VM (FullPanel, experimental; the app's
  **Start in** picker: Window / Full screen, notch via Omanotch / Full screen including notch,
  no Omanotch needed): `omacvm fullscreen --vm NAME --json` (`notch`: native|fullpanel,
  `next_start` with the reason when native, `this_start` from qemu.log), then
  `omacvm fullscreen --vm NAME notch|standard` (= `omacvm notch --vm NAME fullpanel|native`):
  from the next start. Window is the app's `startFullScreen` off (every VM). Omanotch stays on
  in the VM (its bar does the strip); on UTM, Fusion and Parallels there is no such setting.
  Skip the notch (off by default, either full screen): `omacvm notch --vm NAME --skip on|off`,
  at once in a running VM; `--json` says `skip` and `skip_ready` (the VM's bar can do it).
- **An Omarchy installed by hand**: `omacvm apply --vm NAME`. Exit 3 with a
  command in the message = the person runs that command once in the VM's
  terminal (it adds OmacVM's SSH key), then apply again. An OmacVM.app VM
  that knows only another Mac's key: starting it once in the app does the same.
  An OmacVM.app VM folder copied to another Mac has none of that Mac's helpers
  and the other Mac's token: the app says so before a start and offers Update
  VM (`omacvm apply --vm NAME` does the same); `omacvm check` says it in its
  "Mac setup" line.
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
   and scale) while "Use external displays" is on (with one display switched
   to macOS and a Mac app in front, a move over the VM on another display
   still moves the VM's pointer, without taking the keyboard:
   `omacvm-cocoa-pointer-hover*.patch`, ADR 0015's addendum); `omacvm-displays status`
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
| UTM route | UTM 5 (verified 5.0.6, QEMU 10.0.12); required: on UTM 4.7 GL clients map but never paint (black windows) unless rendering is forced to software (ggalancs/omarchy-arm-utm#7). OmacVM never sets `LIBGL_ALWAYS_SOFTWARE` on UTM (in OmacVM.app VMs only for Ghostty's `eglInitialize`, ADR 0064); VirGL (virtio-gpu-gl), Vulkan off. VM creation through UTM's AppleScript dictionary (`/Applications/UTM.app/Contents/Resources/UTM.sdef`), `utmctl` for start/stop/status/ip-address |
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
| `src/lib/app.sh` | OmacVM.app from the Mac: its VMs (`app_list`, `app_ip`, `app_start`), the installed app (`app_bundle`: the app whose omacvm runs, else OmacVM.app by name, then a renamed install, test/bench/RC/lane copies last, the newest within each; `app_boot_app`: never an app older than the VM's `omacvm-version`, never while another copy of the app is open: it would take the start), `app_create`, and the download (`app_published`, `app_install`, `app_install_cmd`; curl sets no quarantine) |
| `src/net/mac/` | The fast network for OmacVM.app (feature `fast-network`, opt-in): `omacvm-netd.c`, a root daemon (launchd socket `/var/run/org.omacvm.netd.sock`) that gives OmacVM.app's QEMU (`-netdev stream`) one isolated vmnet shared-mode interface per connection on its own `192.168.77.0/24` (UTM's `192.168.64.0/24` refuses isolated interfaces while UTM uses it) after checking the caller's user and code signature, with a back-off after vmnet failures (each failed start leaks a descriptor in macOS's InternetSharing), and a VPN NAT: while a VM is on it, NAT for networks macOS's sharing does not cover (a VPN connected later) in its own pf anchor `com.apple/org.omacvm.netd` (routing socket, `pfctl -E`/`-X` reference, state `/var/run/org.omacvm.netd.nat`); `install.sh` installs the copy built and signed inside the app (`Contents/Library/LaunchServices`, by `build-app.sh`; built here only for older apps), `--status` (+ `vpn-nat: IF` line), `--remove` (this Mac user; the service when none is left), `OMACVM_ADMIN_PROMPT=gui` for macOS's password dialog (the app's Fast network button, its question before a start, `FastNetwork.turnOn/turnOff`), `=none` for everything the Bridge runs for a VM (never root, exit 3); `--protocol` (`NETD_PROTOCOL`): an installed daemon of the same protocol serves a newer app (`KNOWN_BUILDS` for builds without it); `test.sh` offline tests. For app VMs the VM's `fast-network` file is the switch (button, apply, check). The app picks vmnet or slirp per start (`FastNetwork.swift`, `logs/network`) and swaps to a hot-plugged user-network card and back while the VM runs (`Runner.watchFastNetwork`); `app_ip` then finds the VM in `/var/db/dhcpd_leases` by the MAC on the running QEMU's command line (`app_vm_mac`), never the `fast-network` file (the next start's switch) |
| `src/lib/version.sh` | OmacVM's version order (`version_cmp`, `version_lt`: 3.0.10 > 3.0.9, a pre-release older than its release) and the downgrade guard (`omacvm_downgrade`): `apply`, `enable`/`disable` and `update` stop with exit 3 before changing anything when the VM has a newer OmacVM than the omacvm that runs (an old `~/.omacvm` checkout beside a newer OmacVM.app, #233); `--allow-downgrade` goes back on purpose. The `omacvm` entry script warns when OmacVM.app is newer than the checkout that runs (`omacvm_app_newer`). `src/tests/version-guard.sh`. `src/lib/follow-release.sh`: install.sh's `~/.omacvm` (`git config omacvm.follow release`; unset on main = an install before 3.0.9) follows releases, not `main` (#291): `update` and `install.sh` move it to GitHub's latest release tag, or OmacVM.app's version when newer, only forward and only to a tag that has this file; local changes, `omacvm.follow ref` (`OMACVM_REF`) or another clone: never moved. `src/tests/follow-release.sh` |
| `src/features.tsv` | **The feature list**: name, default (`on`/`off`/`notch`/`laptop`: on with a battery, never on Parallels), sides, tags (`experimental`, `slow`, `notch`, `laptop`, `not-parallels`, `app-only`), needs, title, summary. `feature_default`/`feature_available` in `src/lib/features.sh` turn defaults and tags into on/off and reasons (with `NOTCH` and the VM's `TYPE`). Read by `src/lib/features.sh` (Mac, bash 3.2), `src/guest/install.sh` (VM), `features.sh`; a new feature also needs its case in `build.sh` (`feature_flag`, question), the VM installer and the checks |
| `src/lib/vm.sh` | Finding VMs without starting UTM (`vms_list`: Parallels via prlctl, UTM via utmctl when it runs and answers within 15 s, else UTM's `Registry` preference, which knows VMs outside its folder (state `unknown` while UTM runs: no answer, e.g. over SSH or while macOS asks whether the terminal may control UTM; `resolve_vm` then stops with exit 3, never starts it), and Fusion's VM folders), `vm_type` (running first, Parallels' "invalid" last), `resolve_vm` (no name: "Omarchy", else the only running VM; it starts a stopped VM only for a change (`start`) to a VM named with `--vm`, never one picked by default), `vm_probe` (user, version, env, features set up before 2.0), `ssh_setup_command` |
| `src/cmd/build.sh` | Nothing → finished VM. Interactive questionnaire (`src/lib/setup.sh`, bash 3.2, reads `/dev/tty`): Parallels, UTM, VMware Fusion or OmacVM.app (waits until installed; UTM ≥ 5, Fusion ≥ 13; a missing OmacVM.app is downloaded after asking: `OmacVM-<version>.zip` of this OmacVM's GitHub release, checked against the release's signed `OmacVM-appcast.json` (SHA-256, size, Developer ID teams), into ~/Applications; no zip for this version: exit 3; `--yes`: exit 3 with the command), VM name if taken, resources Low/Balanced/High/Best (`tier_values`: Best leaves max(8 GB, ¼) for macOS + GPU; capped by the Parallels licence; custom values also ask Fusion's graphics memory), where the VM goes (Parallels, UTM, Fusion), one checklist of every feature in `features.tsv` (defaults on, experimental ones marked), user/full name, summary, password. Options: `--vm-type --vm-name --vm-dir --resources --cpus --memory-gb --disk-gb --graphics-gb --user --full-name --hostname` (`--graphics-gb`: Fusion only, 1-8 GB of the VM's memory) (`--vm-dir`: Parallels, UTM and Fusion; the drive must be APFS or Mac OS Extended with 30 GB free, UTM with `--vm-dir` is always built here: a prebuilt UTM VM goes into UTM's library), `--feature NAME=on|off` / `--FEATURE` / `--no-FEATURE`, `--yes --dry-run --plan --json`, `--parallels-edition standard|pro` (only while Parallels reports "No license installed", a fresh install whose trial starts with the first VM: the edition to size by; the questionnaire asks it, default standard), hidden `--channel` (default: omarchy-mac's `stable` lane once published, else `rc`); `OMACVM_PASSWORD` for `--yes`. Ends with one `apply` call (Mac side, VM side, Omanotch). `--vm-type app`: vm.env into OmacVM.app's VMs folder (`app_vms_root`: ~/OmacVM unless set in the app; `app_vms_roots` also lists older folders and the old hidden one), the app's own `Contents/Resources/scripts/create-vm.sh` builds the VM (password on stdin), then the same `apply` |
| `src/cmd/check.sh` + `src/guest/check.sh` | Read-only feature check, Mac side then guest side over SSH (`bash -s` of `src/guest/check.sh`, so it works on VMs with an older copy). One line per feature, exit 1 on any FAIL (WARN = works on a fallback, e.g. an app VM's Vulkan on MoltenVK because KosmicKrisp could not run; it does not fail the check); `--json` (guest side `--tsv`) with `needs_human` and `feature` (the `features.tsv` name, "" = general; set with `FEATURE=` before the lines) per check; `--mac-only` skips the guest. Add a line here for every new feature |
| `src/cmd/apply.sh` | OmacVM onto a running VM (a stopped one is started only when named with `--vm`, else exit 3): reads the VM (`vm_probe`), merges `--feature` changes (dependencies via `features_fix`), installs the Mac side those features need (`src/mac/install.sh --quiet`, `--omanotch` with that feature), copies the bridge token, the VM's control key (control-centre on), an app VM's folder SSH key (`src/guest/ssh-key.sh`: the user's `~/.ssh` written as the user, never as root) and `src/` to `/usr/local/share/omacvm` (unpacked beside the old copy, swapped in when complete; same layout there, without `src/`), runs `src/guest/install.sh` with every feature explicit, Dock icon (Parallels). `--reinstall F` repairs one feature (its Mac helper with `--force-app`, `guest/install.sh --only F`); `--transaction` (the control centre's jobs) goes back to the old copy and features on failure and exits 4; `--yes` asks nothing. No SSH access: exit 3 with the command for the VM's terminal; another SSH host key than the one remembered: exit 3 (`--reset-host-key` after a rebuild) |
| `src/cmd/gestures.sh` | `omacvm gestures`: OmacVM Gestures' Mac-wide settings for every route, the same keys as the app window and the control centre (`/omacvm/settings/gestures` on the Bridge): `escape pointer\|all` (`EscapeSwipe`; `focused` and `display` are aliases of `pointer`), `swipe-out on\|off` (`SwipeOut`, #342), `mouse-swipe 3\|4` (`MouseSwipeFingers`), `--json`; the test identity's domain with `OMACVM_TEST_IDENTITY=1`. Test `src/tests/gestures-settings.sh` |
| `src/cmd/graphics.sh` + `src/lib/graphics.sh` | `omacvm graphics`: OmacVM.app's Graphics setting (the VM folder's `graphics` file: opengl, vulkan, auto). The same rules as the app's `Graphics.swift` (Automatic: Vulkan on macOS 26+ with KosmicKrisp in the app and the VM's Venus driver there, `venus-ready` from apply; the Venus host memory window from the memory plan); `src/tests/graphics-setting.sh` checks both agree |
| `src/cmd/notch.sh` + `src/lib/notch.sh` | `omacvm fullscreen` / `omacvm notch`: OmacVM.app's full screen including notch per VM (the app's Start in picker with `startFullScreen`) (the VM folder's `notch-mode` file: `fullpanel`, none = native; FullPanel, experimental, #339, ADR 0044). The same rules as the app's `NotchArea.swift` (FullPanel only with the setting, "Start in full screen", a notch now and `fullpanel-ready` from apply with Omanotch on; else native and why); qemu.log `OmacVM: notch area: ...` per start, QEMU's `omacvm: full panel: strip covered|strip lost|display change:|strip not back` (check reads them: ok, warn, warn until "strip covered", warn with "leave full screen and enter it again", or the menu bar setting for "menu bar always shown"); after a display change (the built-in gone and back) the strip comes back once the displays settle, one checked AppKit relayout of the tile, at most 3 per display change, each new one its own (`omacvm-cocoa-fullpanel-retake*.patch`; "strip taken again ..." not read by check; a Split View tile's shape always stays lost; `app/runtime/Tests/display/test-fullpanel-retake.sh`, `src/tests/fullpanel-check.sh`). A FullPanel start: `OMACVM_FULLPANEL=1` for QEMU (`omacvm-cocoa-fullpanel*.patch`), SMBIOS `omacvm.fullpanel=LxRxHxWxD` (Mac points) into host.env, no Omanotch link; notchcast's unit skips the boot, Omanotch's bar (patch v34) sits in the strip of the built-in output (hidden: see-through, still reserving the strip, so the wallpaper shows there). Every Omarchy scale there (#355): the VM's display agent sends `{"scale": s}` (Omarchy's `omarchy_monitor_scale`, or the panel button just pressed: `omacvm-displays scale`, which waits for the new size, then runs Omarchy's own command); QEMU gives the guest the panel's size rounded up to the next size that fits (`omacvm-cocoa-fullpanel-scale*.patch`, at most 7 px more), shown scaled onto the panel, and keeps the scale in the VM folder's `fullpanel-scale` (1/120 steps) for the next start. Test builds: `OMACVM_TEST_NOTCH_GEOMETRY` (a made-up notch on the mini). `src/tests/notch-setting.sh` checks both sides agree. Skip the notch: the folder's `notch-skip` (`--skip on\|off`), `notch-skip-ready` from apply; the app's Runner passes a change to a running VM within seconds (NotchSkipLive), the bar (patch v34, `notchSkipPlace`) lays out only bars with a notch role; Omarchy's hidden indicators open where they are when they fit there, else left of the housing (`peekAt`, a Translate on their hidden block; their slot then lies under its neighbours); decisions stick until a width is 12 pt past the edge; tests: `test_bar_patch.py` Matrix (every MacBook, macOS size and Omarchy scale) |
| `src/cmd/resources.sh` + `src/lib/resources.sh` | `omacvm resources`: a VM's CPUs and memory, read (`res_get`) and changed (`res_set`) in its app's own settings: Parallels `prlctl set` (Standard has none: `pvs.py resources` while unregistered, as the build), UTM `System.CPUCount`/`MemorySize` in config.plist (through UTM's scripting while UTM runs, it keeps what it read), Fusion `numvcpus`/`memsize` (and `svga.graphicsMemoryKB` lowered when it would no longer fit), OmacVM.app `CPUS`/`MEM_MB` in vm.env. Tiers and limits from `src/lib/setup.sh` (`mac_specs`, `tier_values`, `parallels_limits`), as the build. Memory above the Best tier (`tier_best_mem`): a `Warning:` line and `"warning"` in `--json` (`mem_warning`, also `omacvm check`'s "Activity Monitor" row; the words of OmacVM.app's `ResourceLimits.warning`), never a change. Refuses a name found in two apps or twice in one. Tests: `src/tests/resources.sh` (fixtures and a stand-in 16 GB Mac, in CI; `--live` also on throwaway VMs it creates and deletes, none started) |
| `src/cmd/features.sh` | `features` (list, `--json`, or a checklist in a terminal: `src/lib/checklist.sh`, the alternate screen drawn whole on every key and size change, every row cut to one line, a long list scrolls; `src/tests/features-checklist.sh` in a pseudo-terminal, #292), `enable`/`disable`; changes go through `apply.sh` |
| `src/cmd/update.sh`, `vms.sh`, `home.sh` | `update`: git pull (clean clone only, then re-exec), Mac side as installed (Omanotch included), OmacVM.app when installed and older than `src/VERSION` and that zip is published (in place, its install name kept; not while the app or one of its VMs runs), `apply --no-mac` on every running OmacVM VM. `vms`: table or `--json`. `home.sh`: the menu |
| `src/mac/install.sh`, `src/mac/uninstall.sh` | Mac side: bridge, gestures, clipboard helper, Omanotch (`--omanotch`, its own `mac/install.sh`); an app whose sources and options are unchanged since its install is skipped (stamps in `~/Library/Application Support/omacvm/installed`, `--force`). `--status VM_DIR` installs nothing: is this Mac set up for that app VM (`src/lib/mac-setup.sh`). `src/mac/parallels-shortcuts.sh`: empty Parallels' Linux keyboard profile (opt-in, app-wide) |
| `src/lib/mac-setup.sh` | What a VM needs from the Mac it runs on: one map of features to Mac helpers (`mac_helper_of`, `mac_helpers_needed`; `apply` installs by it), the VM folder's `mac-setup` record (`mac_setup_write`: a hash of the Bridge token apply gave the VM; a Mac moved with Migration Assistant keeps its token) and `mac_setup_state DIR`: ok, none, setup (helpers missing, not running, too old, or the VM set up on another Mac: another token, or no record and no control centre key here; fix Update VM, or the app first for a VM with a newer OmacVM), login-items (installed, launchd does not load it), permission (a helper waiting for Accessibility/Input Monitoring over 60 s; one macOS started without a log gives none). Read by `src/mac/install.sh --status` (OmacVM.app before each start: `MacSetup`, `MacSetupAsk.swift`, the question with Update VM or the System Settings pane, Later per VM and app version, the window's red notice and the header's Update VM, qemu.log `OmacVM: Mac helpers: ...`; test hook `OMACVM_TEST_HELPERS_ANSWER=update\|later`) and `omacvm check` ("Mac setup"). Test `src/tests/mac-setup.sh` |
| `src/guest/install.sh` | Guest side, root, idempotent. Detects the VM type (DMI vendor Parallels/QEMU), writes `/etc/omacvm/env`, runs the shared features and the per-type ones. `default-keyring.sh` (also run by the prebuilt first boot): Omarchy's default keyring (no password) for a home without keyrings (restarts a running gnome-keyring, which would not see it), never another default for a home with its own; check line "keyring"; `src/tests/default-keyring.sh`. `shell-colors.py` (every route, #376): Qt 6.12's QtQuick has a `Color` singleton that hides Omarchy's (`qs.Commons`) in every file importing plain QtQuick, so the shell draws empty; it imports QtQuick 6.11 (marked `// omacvm #376`) in Omarchy's shell files and the user's plugin clones that use bare `Color`, only on a Qt with that singleton (else the marked lines go back), again from the pacman hook `zz-omacvm-shell-colors.hook` after Omarchy or Qt updates; check line "shell colours" (the colour errors in the running shell's log); `src/tests/shell-colors.sh`. OmacVM's own QML reaches Omarchy's Color as `Commons.Color` (`import qs.Commons as Commons`; also the row omacvm.monitor adds). Upstream Omarchy says `Commons.Color` itself from October 2026 (omacom/omarchy#14553): its files are left as they are, clones of older plugins still get the import (#14672). `omarchy-targets.sh` (every route, omacom/omarchy-mac#741): omarchy-mac's installer and omarchy update ask Omarchy's repo for `omarchy/hyprtoolkit` and `omarchy/hyprland-guiutils`, which it has not built for ARM since 2026-10-18 ("target not found"); a marked block in `arm-package-sources.sh` leaves out the targets the synced `[omarchy]` repo lacks (Arch Linux ARM's builds, same sonames, fill in; repo list unreadable: upstream's targets), in `/usr/share/omarchy` from `--hook` and the pacman hook `zz-omacvm-omarchy-targets.hook`, in the installer's checkout only for the install (`omarchy-install.sh`; `build.sh` and `create-vm.sh` copy the script in first); `src/tests/omarchy-targets.sh`. `hypr-vm.sh` (every route, #630): `omacvm_vm.lua` in `~/.config/hypr`, required from `hyprland.lua` (the file first, then the line: one reload), Hyprland settings every route needs, each with why and when it can go; now Hyprland 0.57's `quirks:skip_non_kms_dmabuf_formats` off (virtio-gpu's plane takes XRGB8888 only, so the on default left apps no format with alpha), only when `hl.get_config` says the key exists and is on and the user's files do not name it; check line "transparent panels"; `src/tests/dmabuf-alpha.sh`. `system-update` takes OMARCHY_PATH as Omarchy's env-bootstrap does (dev link in `/etc/omarchy.conf`, else the package; the home checkout only without the package) |
| `src/prebuilt/` | Prebuilt VMs (`docs/prebuilt.md`): `make-image.sh ROUTE [build generalize package upload clean]` makes one (`omacvm build --image`: placeholder user `omacvmuser`, nothing of the Mac, no Parallels Tools), `guest/generalize.sh` strips it in the VM, `guest/omacvm-firstboot` + its service (before SDDM: grows the disk, user from the OMACVM-SEED ISO or console questions, home from `/var/lib/omacvm/prebuilt/home`), `guest/first-update` (the first `apply` of such a VM runs it before the features: Omarchy's own update via `guest/system-update`, as the image's package list is as old as the image and the mirrors keep only the newest versions; a new kernel restarts the VM first), `lib.sh` (lookup on GitHub releases `prebuilt-*`: newest image, same major, version up to ours; download, unpack, seed ISO), `vm.sh` (`omacvm build --prebuilt`: unpack, new ids/MACs, seed, first boot, `apply`, seed removed), `vmconfig.py` (config.pvs/config.plist/.vmx edits), `manifest.py`, `sha512crypt.py` (`$6$` hash without Homebrew, for the app). OmacVM.app: `make-image.sh app` (the app's `create-vm.sh` with `OMACVM_CREATE_IMAGE=1`, headless, disk.img only), `app/scripts/prebuilt-vm.sh` (the app's twin of `create-vm.sh`: download, unpack, seed, headless first boot, apply) |
| `src/vm/live/` | Temporary live installer (from vincenzopalazzo/omarchy-parallels, MIT): try-omarchy → bootable ARM64 Linux with SSH; a Parallels VM, or `--raw-image` for UTM |
| `src/vm/base-install.sh` | In the live system: GPT + btrfs on the NVMe disk, pacstrap, locale/keyboard/user, GRUB |
| `src/vm/omarchy-install.sh` | In the new system: omarchy-mac `install.sh --channel $OMARCHY_MAC_CHANNEL`, unattended; SSH rule for the Mac's network. `build.sh` and `create-vm.sh` set the channel once, at build time: `stable` if omarchy-mac has published that release, else `rc` (`omarchy_channel`; `build.sh --channel` overrides). An existing VM keeps the lane its pacman.conf names |
| `src/vm/progress.sh` | Sent in front of the two above by OmacVM.app: pacman's output -> `{"omacvm_progress": 1, ...}` lines (package n of N, download bytes from the cache size); raw lines as `\| line` for the step log |
| `src/vm/pvs.py` | Parallels `config.pvs` editor (settings, NVMe disk, boot order, shares) |
| `src/vm/fusion.sh` | VMware Fusion: create the VM (`fusion_create`: vmcli, then `.vmx` lines; the raw live image through a monolithicFlat descriptor), drop the live disk |
| `src/fusion/` | Fusion guest specifics: public DNS (`dns.sh`), Hyprland with the vmwgfx fix (`build-hyprland.sh`, one patch per Hyprland release in `hyprland-vmwgfx/`: the newest that applies; none: "no vmwgfx fix for Hyprland <version> yet", recorded with the source commit and the patch set (no new download until one of them changes), exit 0; a pacman hook that rebuilds after hyprland upgrades; test `src/tests/fusion-vmwgfx.sh`), VMware Tools (`build-open-vm-tools.sh`), the display layout (`omacvm-fusion-layout`, `omacvm-fusion-displays` + its user unit), `monitors.lua` |
| `src/vm/utm.sh` | UTM: create the VM (AppleScript `make new virtual machine`), `--vm-dir` (`utm_move`: export to the folder, delete UTM's copy, `open -a UTM` the export; `utm_add_live` then adds the installer disk), drop the live disk, app-wide speed settings (`utm_tune_app`: not writable = a hint, the build goes on). Test: `src/tests/utm-vm-dir.sh` (a stand-in UTM) |
| `src/lib/mac.sh` | Mac helpers: `gssh`, Parallels (`vm_ip` by DHCP lease, `vm_state`, `vm_start`), UTM (`vm_type`, `utm_ip`, `utm_state`, `utm_start`, `utm_wait_stopped`) and Fusion (`fusion_list`: Fusion's `vmInventory`, running VMs and `$FUSION_DIR`, `fusion_ip` from `vmnet-dhcpd-vmnet8.leases`, `fusion_state`, `fusion_start`, `fusion_host`) |
| `src/guest/omacvm-omanotch.service` | The omanotch feature: one-shot user unit that runs `/usr/local/share/omacvm/omanotch/guest/install.sh` in the first desktop session (it needs Hyprland running), skipped once `~/.local/bin/notchcast` exists. `src/guest/install.sh` removes notchcast when that copy changed (stamp `~/.local/state/omacvm/omanotch`; Python's `__pycache__` left out, `src/tests/omanotch-stamp.sh`), so it installs again |
| `src/omanotch/` | Omanotch (`git subtree`, history kept): `mac/` (Omanotch.app, Swift; `mac/test.sh` = offline tests), `guest/` (`notchcast`, the bar, background and display panel patches, `notchbar.lua`; `guest/tests` = offline tests). The patches know omarchy-mac's shell and upstream Omarchy's newer one (October 2026: notch floor, a bar thickness per screen, BackgroundMedia, `Commons.Color`): where an anchor differs, each form is listed (`replace_variant`); Omarchy's own files of both in `src/tests/omarchy-shell` (also `src/tests/notch-wallpaper.sh`, `src/tests/omarchy-shell.sh`). Toasts under the bar (parked: only the gap; OmacVM.app's FullPanel: the strip's height + the gap): the bar's `barSizeFor` (newer Omarchy asks it), `guest/omanotch-notifications.sh` on an older notification service. The bar and background clones follow Omarchy's updates like Omarchy's own plugins (`guest/copies.py`, installed to `~/.local/lib/omanotch`, run by `install.sh`, the user unit `omanotch-copies.service` at each login and from OmacVM's pacman hook `zz-omacvm-omanotch-copies.hook` after an update): Omarchy's new plugin with the patch again, merged three ways (`git merge-file`) with the clone against what was written last (`~/.local/state/omanotch/copies/<name>/written`), shell lines of shell-colors.py not counted; overlap or a patch that does not fit: the clone stays as it is (check WARN `bar copy`); a clone without a record (3.1.11 and older) is made new once, kept first as `~/.config/omarchy/plugins/.$USER.bar.before-3.1.13` when it differed (WARN with the path for 14 days or until deleted; shell-colors.py skips dot folders); the shell restarts and must load it (no errors on its path, the bar's notchbar IPC) or every changed file goes back (`guest/tests/test_copies.py`). Its own README. Work on it here; github.com/gillesgoetsch/omanotch is archived and points here |
| `src/lib/install-plugin.sh`, `src/lib/omacvm-plugins` | Omarchy shell plugin install; validates the copy first, writes nothing when the folder has it already, queues until the shell runs (first login); restarts the shell once when a plugin's files changed. While the session is locked (`src/guest/session-lock.sh`) the copy waits in `~/.local/state/omacvm/plugins-staged/<id>` and `src/guest/restart-shell.sh`'s job after the unlock puts it in place (section 8). Tests: `src/tests/plugin-lock.sh`, `src/tests/restart-shell.sh`, `src/tests/lock-rules.sh` |
| `src/lib/sign.sh` | Signs Mac apps with `designated => identifier "<id>"`, so TCC grants survive rebuilds |
| `src/control/` | Feature `control-centre` (docs/adr/0030-0032): `omacvm` in the VM, a Textual TUI (`omacvm_cc/tui.py`; `state.py` = the pure status rules, `controller.py` = data, `bridge.py` = the client with the Bridge's proof, `report.py` + `collect.py` = report a problem with redaction and a gate, also run by the Mac's `omacvm report` with macOS's python3 3.9, or OmacVM.app's 3.13 on a Mac without the Command Line Tools: keep it 3.9-compatible). `omacvm status [--json]`, `omacvm report`, `omacvm notify` (user timer: one notice per new version unless update checks are off), `omacvm extra-brightness [on\|off] [--json]` (OmacVM.app's Extra brightness over the control port, answered by the app itself: `/omacvm/app/extra-brightness`, `ExtraBrightnessGuest` in `OmacVMWindow/ExtraBrightness.swift`, ADR 0031; only while that VM's window is in front). Guest install (`guest/install.sh`): Textual from OmacVM's own wheels (`vendor/`, pinned with `SHA256SUMS`, unpacked by `omacvm_cc/vendor.py` into the user's `~/.cache/omacvm/python/`; no pacman: a VM older than the mirrors gets every file as a 404), `/usr/local/bin/omacvm`, root socket `omacvm-check.socket` (runs `guest/check.sh --tsv` for the desktop user, nothing read from the caller), desktop entry, a marked row in `~/.config/omarchy/extensions/omarchy-menu.jsonc`, bar plugin `plugins/omacvm.control`. Tests: `tests/` (pytest + Textual Pilot against `tests/fakes.py`), `tests/vm_e2e.py` drives the real TUI in a test VM |
| `src/release/` | Update manifests (ADR 0032): `parts.tsv` (files → parts, first match wins, `core` last), `manifest.py digests|build|parts`, `sign.swift keygen|sign|verify` (Ed25519), `release-key.sh sign|team|teams|spare` (signs with the Keychain key and checks it), `keys.py` (verify on the command line: plain-python Ed25519, either key, kept spares). `omacvm apply` writes the digests it installed to the VM's `/etc/omacvm/installed.json`. Release keys: `src/lib/release-key.pub` (main) and `release-key-spare.pub`, either one signs; documents carry `kind` and `devid_teams`; who holds the private halves and how to rotate: `docs/release-keys.md`. A release: `release.sh` (every step, `--dry-run`, rollback; `docs/releasing.md`). Tests use `OMACVM_FEED_URL` + `OMACVM_FEED_KEY` (Bridge), `OMACVM_APPCAST_KEY` (app test builds), `OMACVM_RELEASE_TEST_KEYS` (command line), all throwaway keys |
| `src/lib/helpers.sh` | OmacVM.app's prebuilt Bridge, Gestures and Omanotch (`Contents/Helpers`, Developer ID; `app/scripts/build-app.sh` builds and signs them): `src/mac/install.sh` installs them (`install.sh --prebuilt`) when built from the same sources, else builds (with Xcode's Command Line Tools; without them it says so and builds nothing); `src/tests/prebuilt-helpers.sh` |
| `src/lib/tools.sh` | Apple's developer tools without Xcode's Command Line Tools (sourced by `mac.sh` and `app/scripts/vm-common.sh`): `clt_has` (asks `xcode-select -p` first, never a stub), `tools_python` / `tools_path` (macOS's python3 with the tools, else OmacVM.app's `Contents/Resources/python` from `app/scripts/fetch-python.sh`, first on PATH; `PYTHONDONTWRITEBYTECODE=1`, so nothing is written into the signed app), `mac_tool NAME` (the app's own built `Contents/Resources/tools/NAME` when this omacvm is part of an app, else `swift src/*/NAME.swift` from the checkout, else the installed app's built copy, also when that Swift run fails, e.g. on an SDK the compiler does not support, #387: mac-notch, mac-display, mac-clock, mac-free-gb). Tests: `src/tests/no-clt.sh` (stand-ins for every stub), `src/tests/mac-tools.sh` (the order and the fallback) |
| `src/bridge/` | OmacVM Bridge: `mac/*.swift` (OmacVMBridge.app), `guest/` (client, shared event stream, OSD follower, nightlight and Wi-Fi QR command replacements, `omacvm-timezone`: root service, the VM's zone follows the Mac's `timezone` events (`GET /timezone`, at the stream's start and on `NSSystemTimeZoneDidChange`) with `timedatectl set-timezone`; the zone it set last in `/var/lib/omacvm/timezone`, another zone in the VM = set by hand, kept until the VM is on the Mac's again; state `/run/omacvm/timezone` for the check's "time zone"; `src/tests/timezone.sh`), `plugins/omacvm.{wifi,audio,wifiqr,nightshift}`. External display brightness (feature `external-brightness`): `mac/external-brightness.swift` (DDC/CI over IOAVService, Apple displays over DisplayServices, found per display at run time; one serial queue, coalesced writes), `mac/external-model.swift` (steps, DDC packets, which display; `mac/test.sh` offline, `--live` on this Mac's displays, always restoring), `/display/external*` in the API, `guest/omacvm-ddcutil` as `/usr/local/bin/ddcutil` in the VM so Omarchy's own DDC path asks the Bridge (`src/tests/external-brightness.sh`); the output on the built-in display too, which the Bridge sets through DisplayServices by its id (`OutputBrightness`, no osd event, `MediaKeys.vmSet` for OwnSteps): Omarchy's brightness slider. Night light: the Mac's Night Shift only; the guest install hides Omarchy's NightLight indicator (`items` of `omarchy.indicators` in `shell.json`, original kept in `~/.local/state/omacvm/nightlight-indicator`, restored with bridge=off; Omarchy's default list read from the installed widget: `guest/nightlight-indicator.sh`) and stops `hyprsunset`. `mac/control_policy.swift` + `control.swift`: the control centre's fixed request list under `/omacvm/` (ADR 0031; the VM is worked out from the peer address via `omacvm vms --json` and proves itself by signing each request with its own key, which never leaves it, jobs run the CLI named in `~/Library/Application Support/omacvm/cli` (written only by the installed checkout, `cli_for_bridge` in `src/lib/mac.sh`: a worktree that runs `src/mac/install.sh` does not take it over; `OMACVM_SET_CLI=1` forces it; OmacVM.app takes it from a checkout with an older OmacVM, and a checkout never takes it from a newer omacvm: `cli_file_app`, `ControlCLI.swift`) with posix_spawn, own session, responsibility disclaimed so macOS's Local Network privacy lets its ssh through; job files in `omacvm-bridge/jobs/`); `mac/tests/run.sh` tests the policy |
| `src/gestures/` | OmacVM Gestures: `mac/omacvm-gestures.c` (MultitouchSupport + event tap, created again when an OmacVM VM comes to the front; at start it waits for its permissions on the run loop (every 3 s and on macOS's Accessibility notice; a grant in a sleep loop was never seen, #330), listens only then, and starts again once (LaunchAgent: exit 75, KeepAlive; started by macOS: `open`) when a new copy of itself (`--permissions`) may make the tap and it may not (`mac/test-wait.c`); output to /dev/null (started by macOS) goes to its log, which starts with `starting (pid N)`; never enabled or created without Accessibility: a permission taken away (Accessibility, or Input Monitoring or "control the computer" = `CGPreflightPostEventAccess` when the tap was made with it; those two cost ~5 ms of tccd each and are asked off the main thread every 10 s) removes the tap and stops the trackpads at once, back when it is granted again, #192 (the Bridge's media-key tap and QEMU's full-grab tap, `omacvm-cocoa-tap-permission.patch`, likewise; QEMU's goes on whichever of the two it was made with, as OmacVM.app may hold only "control the computer"); ⌃⌥ Esc (exact modifiers; the old ⌃⌥⌘ Esc still works through 3.0.x, the guest names the new one once per VM, then it is removed) moves the focused display out of the VM with macOS's own Space shortcut, a display the pointer is not on with a Dock swipe (the shortcut posted by Gestures moved the display the pointer was on before its warp, 2026-10-24) (`EscapeSwipe` = `all` in `org.omacvm.gestures`: every display), and back; focused = with OmacVM.app's VM on two or more displays the one with Hyprland's focus (the guest answers `Q` with `D x y w h`, where that output sits in OmacVM.app's arrangement, or `D -`; `guest/test-focus.py`; Omarchy does not warp the pointer on a keyboard focus change), else, with no answer in 0.15 s (older guests, not waited for again) or one display, the pointer's; back in (in macOS) the pointer's display, into the VM's Space there (any of its windows', not only the main one's); shortcut off or Space unchanged = a Dock swipe (macOS 15 ignores the shortcut from the notched display's full-screen Space); still no way out = a log line (no notice in Omarchy), never out of full screen; Swipe out to macOS (#342, `SwipeOut`, off by default): macOS's Space follows the fingers (`swipe-take.h`): after `X on 2` the guest says on every workspace change (Hyprland's event socket) where a swipe of fingers going left or right would go (`E <l> <r>`, `guest/test-swipe-out.py`) and, at once and after each config reload, which finger counts and ways switch workspaces (`G 4lr`, `G -`: `workspace_swipes()` reads Hyprland's `hl.gesture` lines in the order Hyprland runs its Lua config; Hyprland has no query for them; unreadable = no `G` = any 3+ fingers); a swipe with such a count (or a Magic Mouse swipe with its `MouseSwipeFingers` count) that begins with a way out and a macOS Space on that side is held back from the guest until its way is clear (2 % of the trackpad's width, mostly sideways), outward it drives the Dock's own swipe (Began/Changed, Ended or Cancelled at the lift: back when the fingers go back, finished past half a Space or with a flick; one Space per half the width, hidden `SwipeOutTravel`), any other way all of it goes to the guest; macOS 27 reads the Dock swipe only as an IOHIDEvent attached to the event (`dockSwipeEvent`, older macOS the fields, whose progress sign is not documented: the learned `SwipeSign` of the escape combo counts for this swipe too (a MacBook Pro on macOS 15.7 reads it the other way, 2026-10-17), a swipe that lands on the other side flips and keeps it, and a first miss in a row tries the other way once); macOS not following (a finished swipe did not change the Space) = the one step after all (`leaveToward`), twice in a row = the one step at the lift from then on (logged; CGSManagedDisplayIsAnimating cannot tell from the helper: it said no while the Space followed); the capture check waits while such a swipe runs (macOS's move shows other windows); guests from 3.1.0-3.1.5 (after `X on`) say `X left|right` at the lift and get the one step; nothing without a Space there; the test identity's helper plays made-up frames from `OMACVM_TEST_REPLAY_DIR/next.tsv` (a Mac without a trackpad); a late Space change is looked for before the next step (one press, one Space); Mission Control only on a double press (twice within 0.4 s); `mac/test-escape.c` tests it against a made-up world of displays and Spaces; also hides the Mac's pointer over the full-screen VM of Parallels, UTM and Fusion (not OmacVM.app's: QEMU hides it itself, keeps its image empty while hidden, `omacvm-cocoa-cursor-stays-hidden.patch`; a second hider showed it again, 2026-10-19) (looks at 120 Hz while it moves; at rest a listen-only tap for its moves, `cursor-rest.h`, wakes the look at the first move, else 20 Hz; hidden `PointerRestTap` false = the 20 Hz look); a Magic Mouse's two-finger sideways swipe = three virtual fingers (workspaces), its one-finger flick = Back/Forward keys, `mac/mouse-model.h` + `mac/test-mouse.c`; macOS's Three Finger Drag on (`TrackpadThreeFingerDrag` in `com.apple.AppleMultitouchTrackpad` or the Magic Trackpad's `com.apple.driver.AppleBluetoothMultitouch.trackpad`, read with the capture check, at most once a second) = three-finger frames stay macOS's (nothing to the guest, macOS's gesture events pass, no swipe out with three), four and more go to the VM, `mac/test-three-drag.c`; offline tests `mac/test.sh`), `guest/omacvm-gestures` (uinput touchpad; Glide), `guest/glide.sh` + `guest/omacvm_glide.lua` (Glide's Hyprland settings and Chromium flag). The scroll momentum's tuning history: `docs/experiments/trackpad-scrolling.md`, analysis scripts in `docs/experiments/scroll-analysis/` |
| `src/display/` | Parallels: `parallels-dynres` + `monitors.lua`. `mac-display.swift`: the built-in display below the notch, for UTM |
| `src/utm/` | UTM guest specifics: guest tools, virtio-gpu environment, fixed display mode |
| `src/app/guest/` | OmacVM.app's VM side: `omacvm-display-sync` (each output follows its Mac window or display: mode, scale by EDID, position from the Mac's arrangement; Omarchy's zoom for Virtual-1, independent saved zoom for secondary outputs), `omacvm-displays` (user service on virtio port `org.omacvm.display`: hello and the switch to QEMU, the arrangement from it, Hyprland's outputs back for the pointer; `external on\|off\|toggle`, `status`; `desktop`: a `grim -s 0.1 -t png` grab of each Mac display that should show the wallpaper, read by a small PNG reader in the file (8- or 16-bit RGB or RGBA): more than 97 % below the top tenth with nothing drawn, Hyprland's `misc:background_color` or alpha 0 (HDR's capture copy, section 8), gets the shell restarted and fails check's "desktop" line; `src/app/guest/tests/test_omacvm_displays.py`), `omacvm-media` (user service on virtio port `org.omacvm.media`, AirPods and media controls: the VM's MPRIS players through Gio once the app's switch is on, the state of the player that played last to the app, its play/pause/next/previous back, never PlayPause; `status`; `src/app/guest/tests/test_omacvm_media.py`; ADR 0058), `monitor-widget/` (bar widget `omacvm.monitor` = Omarchy's display panel built from the installed Omarchy plus MAC DISPLAYS "Use external displays" and, under BRIGHTNESS, the Mac's Extra brightness: Omarchy's `ToggleSwitch` in a row, section `extra`, (i) with `PanelToolTip`, state from `omacvm extra-brightness`; left out when the installed Omarchy lacks those parts or anchors; rebuilt by the agent after an Omarchy update), clipboard, guest agent, notch strip; `omacvm_egl.c` (OmacVM's glvnd EGL vendor library, `/usr/local/lib/libEGL_omacvm.so.0` before Mesa's in every app VM, rebuilt at each apply in the VA shim's block; the desktop's own processes skip it): apps' video imports to the VA shim (ADR 0063), and in a process named `ghostty` alone `LIBGL_ALWAYS_SOFTWARE=1` for Mesa's `eglInitialize` and gone right after (Ghostty needs OpenGL 4.3, virgl gives 4.1; a driver variable already set wins; ADR 0064; `src/app/guest/tests/egl-vendor.sh`, check line "Ghostty", `src/tests/ghostty-check.sh`); `hypr-capture/` (#579): Hyprland's `cm_helpers.glsl`, one per release (`0.56.2/`, `0.57.0/`), with the same two hunks marked OmacVM into `/usr/local/share/hypr/shaders/` (read before Hyprland's built-in copy, at its start and `hyprctl reloadshaders`): PQ/HLG windows in the SDR copy every screenshot, hyprpicker and portal share reads at SDR white 203 nits (was 80), window shares mapped to the share's white before the clamp; installed only while `/usr/bin/Hyprland` was built from that release's tag and carries the five shader files in its `original` byte for byte (`guard.py`; the first folder that fits), pacman hooks on the path (pre: out, post: the new release's file if one fits; else the "uncovered" text names the installed `hyprland` package from pacman's database and the releases with a fix), a running Hyprland of that binary reloaded as its user; another file of those five names in `/usr/share/hypr/shaders/` or beside ours keeps it out; `hypr-capture.sh --status USER\|--remove` (until the next Update VM or Hyprland update); check line "HDR captures"; `src/tests/hypr-capture.sh` (with every shader variant through glslangValidator) |
| `src/workspaces/` | Per-display workspaces: `monitor_workspaces.lua` (Virtual-1 IDs 1..10, Virtual-N (N-1)\*10+1..; an unplugged display's workspaces park on Virtual-1 and go back on replug), bindings, `plugins/omacvm.workspaces`, `tests/` (park and unpark against a fake Hyprland) |
| `src/clipboard/` | Parallels only: VM → Mac copy (guest `parallels-clip-out`, Mac `omacvm-clip-in`) |
| `src/battery/` | The Mac's battery (feature `battery`; UTM, Fusion, OmacVM.app; Parallels has its own): DKMS module `omacvm_battery` (BAT0, ADP0; from try-omarchy, GPL-2.0-only), root agent `omacvm-battery` (OmacVM.app: virtio port `org.omacvm.battery`; UTM/Fusion: the Bridge's `battery` events through `bridge/guest/omacvm-bridge`), UPower never suspends for it. Mac side: `bridge/mac/battery.swift`, OmacVM.app's `NativeBatteryBridge.swift`. Its README |
| `src/wallpaper/` | Guest `omacvm-wallpaper` (path unit) → `POST /wallpaper` on the bridge |
| Video decoding (OmacVM.app) | Guest VA-API (Mesa virgl) → virglrenderer's video protocol → VideoToolbox backend (`app/runtime/patches/virgl-videotoolbox-decode.patch`: `src/vrend/virgl_video_vt.c`; SPS/PPS rebuilt for H.264, VPS/SPS/PPS for HEVC with an explicit short-term RPS rewritten into every slice header (VA-API omits the SPS's sets), AV1 frames cut from the temporal unit by the first tile's offset (with film grain also into the buffer the guest shows, its `film_grain_target`: `virgl-video-av1-film-grain.patch`), VP9 frames as they come; bit-exact against FFmpeg's software decoding; IOSurface → GPU copy into the guest's textures; pictures finish beside QEMU's GPU thread, from a serial queue per decoder, and planes and fences wait for theirs: `virgl-videotoolbox-decode-async.patch`, `OMACVM_VIDEO_DECODE_SYNC=1` = the old wait). VM side in `src/app/guest/install.sh`: `vainfo`, VA driver shim `omacvm_drv_video.c` (`LIBVA_DRIVER_NAME=omacvm`, `/usr/local/lib/dri`: NV12 surfaces only, AV1 only for Chromium-based processes, exportable surfaces of their real size for Chromium's processes when the runtime says `omacvm.vaexport=1`: Chrome checks the dma-buf size of the ARGB frames it converts to, `OMACVM_VA_EXPORT=1|0`; Chromium told a largest size of 1920 (`OMACVM_VA_MAX`, 0: none) only with a runtime that does not say `omacvm.vadecasync=1`; with one, Chromium's decoders wait for each picture after `vaEndPicture` (a fenced empty command on the display's DRM file; `OMACVM_VA_DECODE_WAIT=1|0`); Chromium's converted ARGB frames fill their rounded planes (RGB imports at the rounded size, the video processing regions rewritten, `OMACVM_VA_FILL=1|0`): call tiles not squeezed; with a runtime that says `omacvm.valogical=1` every 4:2:0 surface Mesa makes at a size not a multiple of 16 is declared to the Mac at its own size (a NOP payload, `virgl-resource-logical-size.patch`, ADR 0061; `OMACVM_VA_LOGICAL=1|0`; Mac `OMACVM_VIDEO_LOGICAL=0`): apps that sample the planes (mpv, Chrome on Wayland) draw exactly the picture, no repeated last row; video processing from a declared source gets its region scaled by Mesa's size over the declared one (every process; Chromium's fill leaves it alone) and a converting `vaGetImage` reads an import of the planes at the picture's size; surfaces the decoder asks at the coded size (H.264 not a multiple of 16, HEVC not of 8; VA-API has no crop) get the size the app's EGL import asks for: an EGL vendor library in front of Mesa's (`omacvm_egl.c`, `/etc/glvnd/egl_vendor.d/10_omacvm.json`, ADR 0063; not loaded by Hyprland, Xwayland, quickshell (Omarchy's shell and lock screen), hyprlock, sddm-greeter; no devices of its own) hands video-format dma-buf imports to the shim's `omacvm_va_dmabuf_imported_v1` when the shim is loaded in that process, and the shim declares the planes of a surface the app exported through it (its `vaExportSurfaceHandle` hook notes the dma-bufs) when the size changes; a decoding or encoding context never begins a picture in a surface made from the app's memory, where Mesa's virgl driver crashes: `VA_STATUS_ERROR_INVALID_SURFACE`, also for that picture's `vaRenderPicture`/`vaEndPicture` (an error instead of a crash); imports and codec contexts are remembered until destroyed, no table limit; `OMACVM_VA_IMPORT_GUARD=0` (tests); an H.264 decoder's picture coded interlaced (`frame_mbs_only_flag` 0: fields, MBAFF) is refused at `vaRenderPicture` with `VA_STATUS_ERROR_UNIMPLEMENTED`, its slices and `vaEndPicture` too (the Mac's hardware decoder does not take it, VideoToolbox's software decoder gave green or wrong pictures; Mesa gets only its `vaBeginPicture`; the app decodes on the CPU), `OMACVM_VA_INTERLACED=1` (tests); tests `src/app/guest/tests/va-shim-surfaces.sh`, `va-shim-decode-wait.sh`, `va-shim-vpp-fill.sh`, `va-shim-import-decode.sh`, `va-shim-interlaced.sh`, `va-shim-logical.sh`, `egl-vendor.sh`), Firefox pref. QEMU env: `OMACVM_VIDEO_DECODE=0`, `OMACVM_VIDEO_DEBUG=1`, `OMACVM_VIDEO_AV1=1` (the app sets it when the VM folder has `video-decode` = `av1`, written by `apply`). Guest profile numbers are Mesa ≥ 26's (`OMACVM_VIRGL_VIDEO_ABI=legacy`). `docs/video-decode.md` |
| Chromium video (OmacVM.app) | Feature `chromium-video` (tag `app-only`: on in OmacVM.app VMs, off elsewhere). Arch Linux ARM's Chromium has no VA-API, only V4L2 (ADR 0025). `src/vdec/guest/`: kernel module `omacvm-vdec` (DKMS, `module/`: V4L2 stateful decoder, no decoding of its own; CAPTURE = single-plane ARGB (`V4L2_PIX_FMT_ABGR32`) dmabufs the daemon hands in; protocol in `module/omacvm-vdec.h` (`OVD_VERSION`: daemon and module of different builds refuse each other, daemon exit 3), control device `/dev/omacvm-vdec`; instance ids cyclic (never reused); max 8 open, 256 unread messages per decoder; daemon gone = errors, not hangs; its poll `ovd_poll` says EPOLLERR only when neither queue streams or the daemon failed the decoder, and `inst_fail_all` wakes a sleeping poll: Chromium 153 drops a wait that gets EPOLLERR, and with the kernel's `v4l2_m2m_fop_poll` (EPOLLERR while nothing is queued) a clip's end and a size change stood still, 3.2.15 and older) + `omacvm-vdecd` (FFmpeg VA-API decode, GL pass NV12→ARGB into GBM buffers, EGL fences with a 1 s timeout; buffers rounded up to even, and for an odd-size picture the Mac is told its size before Chromium gets them (`vdecd-logical.h`: an OMLS NOP on the daemon's render node, only with `omacvm.valogical=1`, `OMACVM_VA_LOGICAL=0`; Chromium imports the picture's part and virgl drops that size; `src/tests/vdecd-logical.sh`); one failing video fails alone, also one whose first 3 pictures VA-API refuses (`AVERROR(EIO)` before the first picture, counted from each START: `vdecd-refused.h`, `src/tests/vdecd-refused.sh`), since Chromium falls back to the CPU only before its first picture; H.264 + VP9, HEVC only with `OMACVM_VDEC_HEVC=1` since Chromium 153's stateful V4L2 decoder lacks it; service `omacvm-vdecd` as user `omacvm-vdec`, `WatchdogSec=5`, status in `/run/omacvm-vdec/status`, `OMACVM_VDEC_DEBUG=1`; GPU not usable at start = the daemon waits 0 s -> 118 s (count in `/run/omacvm-vdec/gpu-tries`, `RuntimeDirectoryPreserve=restart`, cleared when ready), then exit 4, `RestartSec=2` (flat: crashes still restart in 2 s); exit 127 (a library gone) is not restarted; pacman hook `95-omacvm-vdecd.hook` (any `usr/lib/*.so*`) → `vdecd.sh hook`: built again when a library in its own NEEDED is gone (new FFmpeg soname), started when down or not ready; `vdecd.sh why` = the check's reason (last run only, `_SYSTEMD_INVOCATION_ID`); `vdecd.sh vafail` = the "video decoding" FAIL line when `vaInitialize` failed; test `src/tests/vdecd-down.sh`). Module update while an app has it open: installed, loaded at the next VM start (`omacvm check` says so). DKMS helpers shared with battery/camera: `src/guest/dkms.sh`. `chromium-flags.py` (as the user) adds `AcceleratedVideoDecoder` and the `no-av1` extension (YouTube sends VP9) to the last `--enable-features`/`--load-extension` of `~/.config/chromium-flags.conf`, marker `~/.local/state/omacvm/chromium-v4l2-flags.json`. "Chromium (WebGPU)" turns the decoder off for itself (`--disable-accelerated-video-decode` on X11, `src/tests/venus-driver.sh`): Graphite cannot draw its buffers on Venus, and the first frame restarted the GPU process (3.2.14 and older). WirePlumber rule `50-omacvm-vdec.conf` (`/etc/wireplumber/wireplumber.conf.d/`): WirePlumber 0.5 hangs, and links no sound, on a V4L2 device it cannot open (the decoder without a ready daemon), so it leaves the decoder alone; `install.sh` restarts a running WirePlumber once when the rule is new, before it loads the module, never during a call (`in_call`: a running `Stream/Input/Audio` node; then the module waits for the next VM start). `70-omacvm-vdec.rules`: the misc device `/dev/omacvm-vdec` belongs to the daemon and starts it (`TAG+="systemd"`, `SYSTEMD_WANTS`) whenever the module loads, also late (`src/tests/vdec-wireplumber.sh`). `install.sh USER on|off` from `guest/install.sh` (app VMs). Test: `test/vdec-test.c` (V4L2 like Chromium vs FFmpeg software; `--churn`, `--early-drain`, `--expect-fail`, `--stall`, `--flood`, `--hold-all-at-eos`: Chromium's wait at a stream's end). `docs/video-decode.md` |
| `src/camera/` | Feature `camera` (from try-omarchy): guest `omacvm-camera` (user service) feeds `/dev/video42` "Mac Camera" (v4l2loopback via DKMS, `exclusive_caps`) and asks the Mac for frames only while v4l2loopback reports a reader: Bridge `GET /camera` (UTM, Fusion; `src/bridge/mac/camera.swift`) or OmacVM.app's virtio port `org.omacvm.camera` (same Swift file, linked into `app/app/Sources/OmacVM`). Each start makes a new capture session with the camera picked then (`pickCamera`: the built-in one unless suspended, the lid closed; else macOS's default; else the first connected); gone (`wasDisconnected`), suspended (`isSuspended`, macOS 14+), interrupted or no frame for 5 s = stopped and started again (2 s, up to 30 s) while a VM reads, at once when a camera is connected; `src/bridge/mac/test-camera.sh`. Parallels passes the camera itself (a USB camera, `uvcvideo`, "MacBook Pro Camera" on /dev/video0; `SharedCamera` in config.pvs): nothing installed there. `omacvm-camera --status` for the check |
| `src/keyboard/` | `mac-layout.sh` (macOS input source → XKB), guest layout + Cmd+V paste |
| `src/ime/` | Feature `mac-ime` (experimental, off, OmacVM.app only; docs/adr/0043-mac-ime.md, #273 by @Vocllum): the Mac's input methods type in Omarchy. `guest/addon/`: an Fcitx5 module (C++, `protocol.cpp` = the port's JSON lines, no Fcitx5 in it) in Omarchy's own Fcitx5: focus, field kind and caret (Hyprland logical pixels: a RelativeRect caret plus `j/activewindow`'s origin, else the window's box with `exact:false`) to the Mac, preedit and commit into the focused field; `guest/install.sh USER on\|off\|--status` builds it in the VM as package `omacvm-fcitx5-ime` (PKGBUILD, again when its sources or Fcitx5's version change), the port's udev rule (`uaccess`), `GTK_IM_MODULE=fcitx` in `~/.config/environment.d/90-omacvm-ime.conf` (unset for Fcitx5 itself: drop-in `~/.config/systemd/user/omarchy-fcitx5.service.d/90-omacvm-ime.conf`, else it shows a tip to unset it) and `--enable-wayland-ime` in existing Chromium/Electron flag files (marker `~/.local/state/omacvm/ime-flags`). Mac side: virtio port `org.omacvm.ime` (nr 8) and `OMACVM_IME_SOCKET` only when the VM's record says on at its start (`OmacVMFeatures/MacIME.swift`, MacLinks), QEMU's window code as `NSTextInputClient` (`omacvm-cocoa-ime.patch`, rules in `omacvm-cocoa-ime-logic.patch`), the app's switch row `MacIMERow.swift` (runs its own `omacvm enable\|disable mac-ime` while the VM runs). Tests: `src/ime/tests/run.sh`, `app/runtime/Tests/keys/test-ime.sh`, `swift run features-tests` |
| `src/memory/`, `src/kernel/` | zram/sysctl/THP-defrag/MGLRU; `memory/guest/giveback.sh`: the VM's cold file cache while macOS compresses the VM (OmacVM.app runs it from its bundle through the guest agent; `GPUMemoryWatch` + `OmacVMDesktop/MemoryGiveBack.swift` decide when, only with a QEMU whose binary has the reclaim fix's text `MemoryGiveBack.reclaimMarker` (off in 3.2.11, on from 3.2.12) and until that QEMU writes "reclaim=keeps" to `logs/memory-reclaim`; `logs/memory-giveback`; ADR 0059; `src/tests/memory-giveback.sh`; the QEMU side: `qemu-hvf-free-page-reclaim-reusable.patch`, ADR 0062, `src/tests/memory-reclaim.sh`); opt-in memory-optimized kernel (THP always + MGLRU) from ALARM's PKGBUILD, built only with `--thp-kernel`; a newer ALARM release is built only when asked (`omacvm apply`/`update` ask in a terminal, `--kernel` builds without asking, `--yes` and no terminal keep the VM's kernel; OmacVM.app's Update VM prints `ASK kernel HAVE LATEST CPUS LOW HIGH` and reads `build` or `later` on stdin: Build Now / Later in the update screen, a build adds three times its estimate to the update's time; `src/kernel/alarm.sh`, `src/tests/kernel-ask.sh`). ALARM's stock `linux-aarch64` has `# CONFIG_TRANSPARENT_HUGEPAGE is not set` and `# CONFIG_LRU_GEN is not set` (verified 7.2.8), so the THP/MGLRU tmpfiles lines are no-ops there (systemd-tmpfiles skips missing files) |
| Feature switches | `src/guest/install.sh --feature NAME=on\|off` for every feature in `src/features.tsv`, kept in `/etc/omacvm/env`; `omacvm apply` passes all of them (also `--[no-]FEATURE`). omanotch=on: `omacvm-omanotch.service` installs Omanotch from the copy of `src/omanotch` in the session (now if Hyprland runs, else at the next login), again when that copy changed; the clone earlier versions made in `~/.local/share/omanotch` is removed; off: `src/guest/off.sh` (Omanotch's own `guest/uninstall.sh` in the session, its files also without one, and an install queued for the next login). scroll-momentum ("glide" in the code; the old key in /etc/omacvm/env still maps to it): `gestures/guest/glide.sh` on/off (`omacvm_glide.lua` required from `hyprland.lua`, `--disable-smooth-scrolling` in existing `chromium-flags.conf`/`chrome-flags.conf`, marker `~/.local/state/omacvm/glide-flags` so off removes only what it added). no-idle-lock=on (called idle-lock before 3.0.1, on and off the other way round; old names and values are read through `feature_alias`/`feature_old_value` in `src/lib/features.sh`, `FLIPPED_OLD_NAMES` in the control centre, and are never written) = Omarchy's own Stay Awake file (`~/.local/state/omarchy/indicators/stay-awake`, watched by the shell) plus an OmacVM marker so turning it back on never undoes a user's own Stay Awake. bridge=off disables the clones (Omarchy restores its stock widgets; nobody logged in: at the next login, `pending-plugins-off`) and removes the client. battery: `battery/guest/install.sh on|off` (forced off on Parallels); chromium-video: `vdec/guest/install.sh USER on|off` (OmacVM.app VMs; forced off on the other routes); on UTM and Fusion `omacvm apply` installs the Bridge for it even with bridge=off. Gestures off: the VM's daemon is disabled on every route (also UTM, Fusion and OmacVM.app, where it typed Cmd as Super), so the VM does not connect to the Mac's Gestures. `--keys-only` on the Mac app is a Mac-wide off switch |
| `src/icon/` | `omacvm.svg` is the one icon (⌘ loops around Omarchy's mark): `make-icns.sh` renders it with AppKit (`render.swift`) + `iconutil` into both apps' `Contents/Resources/OmacVM.icns`, the Parallels VM's Dock icon (`set-vm-icon.sh` → Finder custom icon of the .pvm) and UTM's library icon (`src/vm/utm.sh` `utm_set_icon`: `Data/omacvm.png` + `Information.Icon`/`IconCustom` in config.plist, VM stopped; UTM's scripting only takes built-in icon names). OmacVM.app's looks (`appIconTheme`): `app/app/Sources/OmacVMIcon` (`IconTheme`, `IconArt`: one drawing for the window's header, the launcher's Dock icon, QEMU's (a PNG) and `OmacVMDockTile`, the Dock tile plug-in in `Contents/PlugIns` (`NSDockTilePlugIn`), which macOS loads into its Dock helper while the app is in the Dock and which draws the look, read from the app's defaults, while the app is not running; the app posts `org.omacvm.app.iconTheme.changed` when it changes). The bundle's icon file is never changed. Test: `swift run icon-tests` |
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
OmacVM.app (QEMU's window code, mac-ime on only): ◀▶ Omarchy's Fcitx5 + OmacVM's module → the focused text field
  org.omacvm.ime: focus, field kind, caret in; preedit, commit, cancel from the Mac's input method out
OmacVM.app (launcher, macOS's Now Playing): ◀───▶ omacvm-media (user) → MPRIS players (Gio)
  org.omacvm.media: hello, the player's state in; hello (the switch), play/pause/next/previous out
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
  sends frames, keys, the capture state and the escape combo's `Q` only to the VM whose name it holds
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
  still routes media keys. Keyboard sharing apps (Synergy, Deskflow, #350): the
  window's switch `shareKeyboard` (org.omacvm.app, off by default; the test identity's
  org.omacvm.app.test) puts QEMU's tap (`OMACVM_KEYS_LAST=1`,
  `omacvm-cocoa-keys-last.patch`), Gestures' and the Bridge's media-key tap at the
  end of the chain (kCGTailAppendEventTap) instead of the head, so the sharing app
  sees the keys first (docs/troubleshooting.md, 34). The guest's modifier keys
  follow each event's flags, left or right from the NX_DEVICE* bits, never
  flipped (`omacvm-cocoa-modifier-state*.patch`, ui/omacvm-modifiers.h, #412:
  with Universal Control Shift went up the moment it went down); only
  a key going down or a modifier changing presses one, a pointer event only
  releases (`app/runtime/Tests/keys/test-modifier-state.sh`).
- Escape combo (Gestures): NEVER take the VM out of full screen or hide it
  (user, 2026-10-05). Out = macOS's own "Move left/right a space" shortcut
  (symbolic hotkeys 79/81, read per press: key, modifiers, enabled), posted
  at the HID level once the combo's keys are up, marked 0x0BAC0E5C (our tap
  and QEMU, `omacvm-cocoa-keys-for-macos.patch`, let it through), toward the
  Space the display showed before (`cameFrom`). Each move is checked: not
  moved or shortcut off → a Dock swipe (macOS 15 ignores the shortcut from
  the notched built-in's full-screen Space; the user's log 2026-10-06), then
  the other direction once; still not moved, or no Spaces info → one log
  line, nothing else: no notice in Omarchy (user, 2026-10-12; helpers up to
  3.0.18 sent `N <why>`), NEVER Mission Control (user, 2026-10-06).
  Swipe out to macOS (`SwipeOut`) moves the Space with the fingers (macOS's
  own Dock swipe, posted by Gestures), else the same way out, toward that
  side; no Space there = nothing, silently. Back in: the shortcut, else the VM's window to the front. An
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
- AirPods and media controls (OmacVM.app, `mediaControls`, ADR 0058): while
  the VM's player plays, the launcher (not QEMU: macOS names a helper by its
  signing id, `org.omacvm.app.qemu`) holds `MPRemoteCommandCenter` targets
  and `MPNowPlayingInfoCenter` (`NowPlaying.swift`; rules in `OmacVMMedia`'s
  `MediaClaim`, `swift run media-tests`), so AirPods, Control Center and play
  keys that reach macOS go to the VM's player over `org.omacvm.media` (nr 9,
  every start). The Bridge's keys with the VM in front never reach macOS, and
  QEMU's tap takes no media keys: a press never counts twice. Rules on the
  main thread, the port read on its own thread, writes `MSG_DONTWAIT`; Now
  Playing is given up first in the Runner's QEMU-exit handler (the launcher
  outlives a crash). qemu.log `OmacVM: media controls: ...` (the switch at
  each start, claim, command, release with why; never a title); check line
  "media controls".
- SSH: `gssh` checks each VM's host key, remembered the first time OmacVM sets
  the VM up (`~/Library/Application Support/omacvm/known_hosts/`, `vm_pin`);
  another key stops with exit 3 and `omacvm apply --vm NAME --reset-host-key`.
  OmacVM.app VMs are reached with their folder's key first (`ssh-key`,
  `app_ssh_key`). A VM that knows only another Mac's key (set up there, or
  before 3.0.12) gets the folder's key through the guest agent, without SSH
  (`VMKey.swift`; the guest script, key checks and texts in
  `OmacVMWindow/SSHRepair.swift`): root's `authorized_keys` only, the key as
  an argument, `systemctl try-restart sshd` only after an add (clears sshd's
  PerSourcePenalties, keeps open sessions). At each window start, before the
  feature switches made while the VM was stopped (qemu.log
  `OmacVM: SSH: ... added` only when it was missing). In Update VM, whose
  headless QEMU has the agent's port at the window's path: `wait_ssh 300
  refused` stops at the first "Permission denied", `FIX ssh-key` on stdout,
  the app answers on fd 3 (added, present, noagent, failed). Not fixed:
  `SSHKEY refused`, then the failed screen's Copy Command (`ssh_setup_command
  app` with the folder key, built by the app, never taken from the output)
  with an (i); a VM that turns the key down shuts down by ACPI
  (`qmp system_powerdown`). Tests: `src/tests/update-vm-watch.sh`,
  `swift run window-tests`.
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
  What the VM frees goes back to the Mac (QEMU `discard=unmap` punches holes
  in disk.img): `src/guest/disk-space.sh`, run by `apply.sh` at every full
  apply once the VM side worked, has snapper keep 2 update snapshots once
  (`KEEP`; omarchy-mac's 5 held deleted files for 5 updates; a number set by
  hand stays), `fstrim.timer` on, then btrfs's cleaner and a trim, both
  waited for (at most a minute together); `@factory` stays (factory reset). Check line "freeing disk space";
  `src/tests/disk-space.sh`.
  OmacVM.app's QEMU turns each guest flush into `fcntl(F_BARRIERFSYNC)`
  (`qemu-darwin-disk-flush-barrier.patch`, ADR 0053; `OMACVM_DISK_FLUSH=full|fsync`), qemu.log
  "OmacVM: disk flush: ...", check line "disk flush"; `src/tests/disk-flush.sh`,
  `app/runtime/Tests/disk/test-flush.sh`.
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
| guest Hyprland | built with `src/fusion/guest/hyprland-vmwgfx/<release>.patch` (the one that applies), stock kept as `/usr/bin/Hyprland.stock`, `/var/lib/omacvm/hyprland-vmwgfx` = version + checksum (or `<version> none <source commit> <patch set>`: no patch for that Hyprland yet; the next apply or hook run with the same three skips the download and says it again; the patch set is 16 hex of a sha256 over the patches' names and contents, the same from either folder; 3.2.15 wrote `<version> none`, which checks once more) | without it every GPU client dies (`invalid arguments for wl_surface.attach`), SDDM's greeter first |

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

### OmacVM.app's VM window (`SettingsView.swift`, docs/design/settings-3.1)

Sections in order: General, Display, Input, Output (the sound, from 3.1.17), Sharing & Devices, Storage & Updates.

Every setting in the window, where it is kept, its default and whether it is
per VM or for the app (every VM). The window reads them again when it comes to
the front, so `omacvm` and the control centre changes show; 3.1 kept 3.0's keys,
so an update keeps every choice. App-wide keys are in the app's domain
(`org.omacvm.app`; the test identity `org.omacvm.app.test`) or Gestures'
(`org.omacvm.gestures`; the test identity `org.omacvm.test.gestures`). VM files
are in the VM's folder. `OmacVM --settings-dump` prints them all as the window
reads them; `src/tests/app-settings.sh` checks defaults, relaunches, two VMs,
3.0's files and the CLI.

| Setting | Key or file | Default | Scope |
|---|---|---|---|
| Resources | `vm.env` `CPUS`, `MEM_MB` (`omacvm resources`) | the tier chosen at setup (Balanced) | VM |
| Graphics | `graphics`: `auto`, `opengl`, `vulkan` (`omacvm graphics`) | `auto` (no file) | VM |
| WebGPU and GPU compute (with Vulkan) | `features` `gpu-compute=on\|off` (`omacvm enable\|disable gpu-compute`, the control centre); switched while the VM is stopped: + `gpu-compute-pending`, set up at the next start (as Mac input) | on (no word = on) | VM |
| Graphics without QEMU's lock | `gpuOffMainLoop` (bool; hidden `gpuMainLoop` and `gpuSafeMode` force it off; read at each start; ADR 0046) | `true` (3.1.18 to 3.1.25: `false`, experimental; switch from 3.1.19) | app |
| Vulkan windows without a copy | `vkWindowsNoCopy` (bool; hidden `vkWindowsCopy` and `gpuSafeMode` force it off; read at each start; QEMU env `OMACVM_VK_WINDOWS=iosurface`, KosmicKrisp only; ADR 0047) | `true` (3.1.24 and 3.1.25: `false`, experimental) | app |
| Closing the window | `closeAction`: `shutdown`, `keepRunning`, `ask` (QEMU: `OMACVM_CLOSE_ACTION`) | `shutdown` | app |
| Start in: Window / Full screen | `startFullScreen` (bool) | `true` | app |
| Start in: Full screen including notch | `notch-mode`: `fullpanel` (`omacvm fullscreen`) | native (no file) | VM |
| Skip the notch (with a notch; its (i) has a picture) | `notch-skip`: `on` (`omacvm notch --skip on\|off`, the control centre); the VM gets it at each start (SMBIOS `omacvm.notchskip=1`) and while it runs (guest agent: `/run/omacvm/notch-skip`) | off (no file) | VM |
| (no row) The guest's scale, for Full screen including notch's next start | `fullpanel-scale`: 1/120 steps, written by QEMU from the VM's display agent (#355) | none (the panel's own size) | VM |
| Keep the Dock and hot corners away | `keepDockAway` (bool) | `true` | app |
| HDR and 10-bit colour (experimental; only shown with a display that can show HDR) | `hdr` (bool, the key it had while hidden; `gpuSafeMode` keeps it off; read at each start: with a display that can show HDR, SMBIOS `omacvm.deepcolor=1` and QEMU env `OMACVM_GL_EDR=1`; qemu.log `OmacVM: HDR: on\|off (why)` (only when the switch was on at that start: no line = started with it off); a restart inside the VM keeps QEMU and that start's value, so while the VM runs with the other value the row says so, in orange and before GPU safe mode's line, which also counts only from the next start (`HDRNote` in `OmacVMWindow`, read from that line; `swift run window-tests`); in the VM `omacvm-display-sync` runs Virtual-1 PQ and gives every window `tonemap = "clamp"`, else Chrome looked gray; screenshots and shares of PQ windows at SDR white through `src/app/guest/hypr-capture/` (check line "HDR captures", #579); with deep colour the driver's connectors take Hyprland's HDR output metadata (`linux-virtio-gpu-hdr-metadata.patch`), so Omarchy's recorder (gpu-screen-recorder over KMS) makes SDR of the PQ screen (check line "HDR recordings"; display-sync's SDR rule for Virtual-1 keeps `supports_hdr = 1` and `omacvm_app.lua` sets `render:cm_auto_hdr = 0`, so that metadata follows display-sync's mode); while Extra brightness is on the guest is told `edr` 1 and its PQ frames end at SDR white, ADR 0050; test builds: `OMACVM_TEST_EDR=potential,headroom` counts as an HDR display at start (potential above 1), so a hidden test VM on an SDR Mac gets HDR, ADR 0049) | `false` | app |
| Extra brightness (experimental; only shown with a display above 2x EDR headroom, potential > 2.05) | `extraBrightness` (bool; written only by the person's switches: this row, the VM's Display panel or `omacvm extra-brightness` (the app's answer on the control port) and `defaults write`; a start, stop, update, HDR, GPU safe mode or a display without the headroom only read it, so it stays as set (`src/tests/app-settings.sh` (f)); QEMU, which runs as the app, reads and watches it live (KVO, again when the window is seen); `OMACVM_EXTRA_BRIGHT=1` for a QEMU not started as the app; `gpuSafeMode` keeps it off; the VM's frames up to 2x in extended linear sRGB surfaces with EDR; wins over HDR: PQ frames decoded, clipped at SDR white, the guest told `edr` 1 while on; `omacvm-cocoa-extra-brightness*.patch`; qemu.log `cocoa: extra brightness: on, 2.00x\|held back by macOS, 1.40x` (`, over HDR` with PQ) `\|not on this display\|off (why)`; test builds: `OMACVM_TEST_EDR=potential,headroom` (also the guest's HDR headroom); ADR 0050) | `false` | app |
| Pause drawing while hidden (experimental) | `pauseWhileHidden` (bool; QEMU, which runs as the app, reads and watches it live (KVO); `OMACVM_GUEST_PAUSE=1\|0` decides for a QEMU not started as the app or a test; `omacvm-cocoa-guest-pause*.patch`, ui/omacvm-guest-pause.h: once none of the main window can be seen for 2 s (occlusion: minimised, covered, another Space, closed with Keep running; or the screen locked, the displays asleep, another user on the console) the guest's display agent gets `{"unseen": ["Virtual-1"]}` on org.omacvm.display (only an agent whose hello says `"pause": 1`) and turns that display off with Hyprland's DPMS (not while a screencast of it or any window share runs, nor in the 3 s after its start or a lost event socket; only displays it turned off itself go on again; list in `$XDG_RUNTIME_DIR/omacvm/paused-displays`, turned on by a restarted agent; while one is off it also holds Hyprland's `misc:mouse_move_enables_dpms` and `misc:key_press_enables_dpms` off (Omarchy turns both on, and Hyprland then turns EVERY display on at any move or key: with the VM on two displays each move on the other one woke the paused one and the Mac's next "unseen" turned it off again), only those that were on (`j/getoption`: `bool` in Hyprland 0.56, `int` before; another answer: left alone), set with `eval hl.config(...)`, off again after a `configreloaded`, back when nothing is paused, when another display goes off by itself (the guest's idle: input wakes it as usual) and at the agent's next start (`$XDG_RUNTIME_DIR/omacvm/paused-wake`); `omacvm-displays pause` (`wake_off`); check's "every Mac display" line), `{"unseen": []}` at once when seen again, the window keeping its last picture until the guest's first frame (at most 1 s); the channel drops lines it cannot write at once, so "unseen" is a lease said again every 5 s (no word for 15 s: the agent turns its displays on) and "seen" again every 0.25 s until the first frame (at most 5 s); qemu.log `OmacVM: pause drawing while hidden: on\|off (...)` and per pause `omacvm: guest drawing: paused for N s ...; frames again A and B ms after it was seen`; test `app/runtime/Tests/display/test-guest-pause.sh`, `src/app/guest/tests/test_omacvm_displays.py`) | `false` | app |
| Pointer on its own layer (experimental) | `pointerPlane` (bool; read at each start: SMBIOS `omacvm.pointerplane=2` (`=1` from 3.2.4 and older: its QEMU showed the pointer on the main window only, so the loader then takes the stock driver); the VM's `omacvm-virtio-gpu-load` loads OmacVM's virtio-gpu driver with `cursor_plane=1` (a cursor plane on every output; never with the hidden `macPointer`: it needs the hotspot; the 10-bit formats only with HDR: `deep_color=1`), and `omacvm_app.lua` puts the pointer on the cursor plane when the running driver shows it; QEMU's cursor layer shows it over the main window and a pointer layer over each other display's window (`omacvm-cocoa-pointer-heads*.patch`, #554: an output without a plane got no pointer at all), with Extra brightness at the frames' gain (half floats, EDR: `omacvm-cocoa-pointer-bright*.patch`); qemu.log `OmacVM: pointer layer: asked\|off (why)` (the check line says what runs); check line "Pointer layer"; ADR 0054) | `false` | app |
| Draw only what changed (experimental) | `presentTiles` (bool; read at each start, `Settings.presentTilesStart`: not in GPU safe mode or with `OMACVM_GL_PRESENT=layer`; QEMU env `OMACVM_GL_PRESENT_TILES=1` and SMBIOS `omacvm.damage=1`, so the VM's `omacvm-virtio-gpu-load` loads OmacVM's virtio-gpu driver for its Linux 7.4 damage fix (a 7.4 kernel has it: stock); the fix is built into OmacVM's driver, not an option, so HDR and the pointer layer send the changed parts with this switch off too, and QEMU without tiles draws whole frames; a frame that changed in at most 12 256x256 tiles goes to WindowServer as those tiles, each drawn with the viewport inside its own surface (the tile program and `omacvm_pt_tex_rect` in `ui/omacvm-present-tiles.h`; 3.2.14 squeezed the tiles right of x 4096 on pictures wider than 4352 pixels, section 8; `Tests/display/test-present-tiles-gl.m`, `--gpu` on a test Mac); qemu.log `OmacVM: tiled present: on\|off (why)` and once a minute `tiled present, last minute:`; check line "Changed parts"; `src/tests/app-settings.sh` (g); ADR 0055) | `false` | app |
| Escape combo | Gestures `EscapeSwipe`: `pointer`, `all` (also the control centre, `omacvm gestures`) | `pointer` (Focused monitor) | app |
| Magic Mouse swipe (with a Magic Mouse) | Gestures `MouseSwipeFingers`: 3, 4 | 4 | app |
| Keyboard access | macOS: Accessibility ("control the computer") for the app; asked only from the window's Allow… (QEMU makes its full-grab tap only when already allowed, `omacvm-cocoa-tap-no-ask.patch`: no macOS dialog at a VM start) | asked | Mac |
| Mac input | `features` `mac-ime=on` (+ `mac-ime-pending` while stopped) | off | VM |
| Swipe out to macOS | Gestures `SwipeOut` (bool); hidden `SwipeOutTravel` (trackpad widths per Space, 0.15-1.5) | `false`; 0.5 | app |
| Keyboard sharing apps | `shareKeyboard` (bool; QEMU's `OMACVM_KEYS_LAST=1` at each start; Gestures and the Bridge read it when they make their taps) | `false` (3.0.18: defaults only; switch from 3.1.23) | app |
| Sound on its own thread | `audioThread` (bool; hidden `audioMainLoop`, `audioClassic` force it off; read at each start; the playback buffers follow the Mac's output (#548): a start with a Bluetooth/AirPlay output uses the main loop's queue, 44.1 kHz 512 frames (`AudioPath.threadWirelessOptions`), a switch to one while it runs 512 frames (the app's size file, `OMACVM_AUDIO_OUT_FRAMES_FILE`, `AudioOutputSize`), a refused start the next size (`qemu-sdl-audio-out-size*.patch`); check line "sound buffers") | `true` (from 3.1.17; 3.1.16 `false`) | app |
| AirPods and media controls | `mediaControls` (bool; the launcher watches it (KVO), so it counts at once in a running VM; the VM is macOS's Now Playing app while its player plays: `NowPlaying.swift`, ADR 0058; qemu.log `OmacVM: media controls: on\|off` at each start; check line "media controls") | `true`; the test identity `false` (a test VM never takes the person's AirPods) | app |
| Mac folder | `mac-folder` (the folder's path) | off (no file) | VM |
| USB devices | `usb-enabled`, remembered devices `usb.json` | off | VM |
| Fast network | `fast-network` + `features` `fast-network=on` | off | VM |
| Disk | `disk.img`'s length, `vm.env` `DISK_GB`; `disk-jobs`, `disk-resize` | 64 GB at setup | VM |
| VMs folder | `vmsRoot`, `otherVMsRoots` | `~/OmacVM` | app |
| omacvm in Terminal | a link to the app's `omacvm` on the PATH | not installed | Mac |
| Check for updates once a week | `~/Library/Application Support/omacvm/settings.json` `update_checks` (shared with the control centre) | `true` | app |
| The icon's look (click the header's icon) | `appIconTheme`: `default` or an Omarchy theme's id; in the Dock from the launcher, QEMU and, while the app is not running, the Dock tile plug-in (`src/icon/` row) | `default` | app |

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
  OmacVM.app's key tap: an old "control the computer" entry (`kTCCServicePostEvent`, tied to an earlier build;
  tccd: "Failed to match existing code requirement ... kTCCServicePostEvent") refuses it whatever Accessibility shows;
  the app clears its own (`KeyAccess.reset`), by hand `tccutil reset PostEvent org.omacvm.app`.
- **Test identity (one per Mac, granted once)**: macOS keys a grant on the bundle id and the signing team, so
  every renamed or ad hoc test copy asks again, while copies of `org.omacvm.app.test` at any path and of any
  build share its grants (2026-10-26: 8 copies of 3 builds on the mini, all allowed). A lane's own id
  (`org.omacvm.app.test.<lane>`) is a new app to macOS with no grants (`src/tests/e2e/relabel.sh` refuses it;
  the release kits' r322-r324 made 54 "would like to control this Mac" dialogs in 36 hours). Local Network is kept per id
  and folder instead: a new build copied over a folder that has an answer keeps it (as an update does), a new build
  in a new folder (`apps/<sha>/`) is asked again (2026-10-26, mini; troubleshooting 42). Kits that start new builds
  on a Mac someone uses copy them over one fixed folder. Test with only this one:
  `OMACVM_SIGN_ID=<Developer ID> app/scripts/build-app.sh --test-identity --install` builds "OmacVM Test"
  (`org.omacvm.app.test`) and copies it over `~/Applications/OmacVM Test.app`; its helpers in
  `Contents/Helpers` are "OmacVM Test Bridge" (`org.omacvm.test.bridge`, port 47931,
  `~/Library/Application Support/omacvm-test-bridge`) and "OmacVM Test Gestures" (`org.omacvm.test.gestures`,
  port 47930, settings domain `org.omacvm.test.gestures`). The test Bridge and Gestures take only OmacVM
  Test.app's VMs, the normal ones only the others (the Bridge reads the app a VM runs from, Gestures the VM's
  code signature `<bundle id>.qemu`; a development build's QEMU is every helper's). Its VMs reach Omanotch on 47911 only: a test Omanotch
  (src/omanotch/mac build, launched with `--args -port 47911 -bridgeDir omacvm-test-bridge`; never `defaults write
  ch.gillesgoetsch.omanotch`, which is the person's Omanotch's) on a Mac without the user's. Start a helper with `open` (so macOS checks its own
  grant, not the Terminal's); small tools without a bundle run as children of your shell (the Terminal's grants).
  Never `src/mac/install.sh` from a test: that installs over the user's helpers. If one runs anyway with the test
  identity or another HOME, every helper LaunchAgent gets an `org.omacvm.test.*` label (`omacvm_label` in
  `src/lib/labels.sh`; launchd has one GUI session per user, whatever HOME says), never a production one
  (`src/tests/test-labels.sh`). The test app's own
  `Contents/Resources/omacvm/omacvm` (and its VM scripts) run by hand is the test identity too (src/lib/identity.sh).
  Its VMs folder is its own `vmsRoot` (`defaults write org.omacvm.app.test vmsRoot DIR`), else
  `~/OmacVM Test VMs`; never `~/OmacVM`, the old hidden place or another folder of the installed app (a setting
  that names one is not used: `TestVMs` in `VMPick.swift`, `app_vms_root` in `src/lib/app.sh`). `--vm NAME`
  that is not there starts nothing. No test build (any non-release bundle id) starts, updates or resizes a VM of
  the installed app, and it hands a start only to its own copy; `app_start` with the test identity needs a test app
  with `OmacVMTestVMs` (build-app.sh) and never opens the installed app by bundle id. Destructive test hooks (`OMACVM_TEST_DISK_GB`, `OMACVM_RESTART_FORCE`,
  `--update-restart`) act only on a VM directly in the build's own `vmsRoot`. e2e harnesses source
  `src/tests/e2e/test-vms.sh`: `e2e_settings_save`/`_restore` for the settings they change, `e2e_vm_guard`
  before every start.
  Before every publish a release runs the on-screen test `src/tests/e2e/onscreen.sh` on each test Mac's macOS
  (window size, Update VM, a switch with the VM stopped, full screen, the Mac's cursor over the VM, leftovers;
  docs/releasing.md); it moves the pointer and clicks only while nobody uses that Mac. It and the other e2e
  harnesses ask again before every step (`src/tests/e2e/person.sh`: a remote session, input not theirs) and wait
  while someone is there; `--pause-ci` stops the test Mac's CI runners for the run (`ci-runners.sh`).
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
| Updated widget does not change | a running shell keeps loaded plugins | `src/lib/install-plugin.sh` flags changes; `src/guest/install.sh` restarts the shell (`guest/restart-shell.sh`; locked: right after the unlock) |
| Omarchy's lock screen without a password field after `omacvm update`/`apply` on a locked VM (3.2.12 and older); journal: "Session lock object was destroyed without unlocking", "lock-stranded: recovering", "lock-pending: screen-stabilizing" | omarchy-mac 4.0.3's shell reloads every plugin, its lock screen too, on a write under `~/.config/omarchy/plugins` or a `rescanPlugins` call; the new lock screen never gets the lock Hyprland still holds | shut the VM down and start it again; from 3.2.13 nothing is written or rescanned under the lock (section 8; docs/troubleshooting.md, 46) |
| Disabling an old clone brings the stock widget back next to the new one | `clonedFrom` hand-back | rename ids in `shell.json` instead, or disable the stock widget |
| SSIDs null, `location_authorized: false` | Location Services not granted (new bundle id or reset) | Privacy & Security › Location Services |
| Media keys still show the macOS popup | Accessibility missing (`permissions:` line, `omacvm check`), no VM in front (Parallels/UTM/Fusion: not full screen), or capture switched off in the bridge menu | `media keys:` / `media key ...: to macOS:` lines in the bridge log |
| Build stops right after the Omarchy install | Omarchy enables ufw; new SSH connections from the Mac are refused | `src/vm/omarchy-install.sh` adds the rule while its own session is open |
| `ERROR: problem running` from ufw | rule stored but not applicable live right after the install | ignored on purpose; verified with `ufw show added` |
| UTM desktop blank after a resolution change | virgl under UTM cannot switch modes live | fixed mode in `monitors.lua`, reboot to change it |
| OmacVM.app: the VM freezes for seconds or a minute; the guest logs RCU stalls on some CPUs, `omacvm-vdecd` watchdog timeouts, "no word from the Mac for 15 s" | macOS ran out of free memory: those vCPUs wait in macOS's kernel for a free page (others run on); often a VM holding most of the Mac | `logs/qemu.log` "OmacVM: stall: vCPUs ... stood still ... waiting for memory (Mac: compressor and swap N MB/s ...)" (memory only when the Mac paged then; else "blocked in macOS's kernel"), `logs/vm-stalls`, `omacvm check` "VM stalls"; give the VM less memory (`omacvm resources`); "main loop stalled ... in a GPU run without the BQL" is QEMU's graphics thread, not the vCPUs (docs/troubleshooting.md, 45; ADR 0060) |
| OmacVM.app: Chrome's windows go blank or flicker after macOS ran short of memory (3.2.14 and older); the VM says "chrome stopped drawing" | QEMU's memory guard cut the app's GPU context off (`logs/qemu.log` "context N (chrome) ... the context is lost"); the VM's Mesa cannot tell Chrome, which keeps drawing into the lost context | 3.2.15: `omacvm-desktop-recover app NAME` ends that app's GPU process (its own processes named exactly NAME with the argument `--type=gpu-process`, or that word in a one-string process title; once per app in 6 minutes, 3 times an hour: Chrome's 3-crash limit) and Chrome starts a new one; by hand, once macOS is no longer critical (red: the new one is lost again at once), `pkill -f -- 'chrome --type=gpu-process'` (docs/troubleshooting.md, 48; ADR 0038) |
| OmacVM.app: a video in Omarchy's Chromium stops on its last picture, a looped one never starts again, a stream stops where its size changes (3.2.15 and older) | Chromium holds every buffer of the V4L2 decoder at a stream's end; the module's poll answered EPOLLERR, and Chromium 153 drops such a wait and never sees the end | 3.2.16: Update VM, then restart Chromium (a video open during the update: the new module at the next VM start, `omacvm check` says so); `vdec-test --hold-all-at-eos` in the VM (docs/troubleshooting.md, 51) |
| OmacVM.app: video still decodes on the CPU | the app predates video decoding, or `vainfo` lists nothing; in Arch's Chromium: `omacvm-vdecd` not running, no module for the running kernel, the flags not in `~/.config/chromium-flags.conf`, or the codec is AV1/HEVC/10-bit; in "Chromium (WebGPU)" always (expected: its Vulkan compositor cannot show the decoder's buffers) | `omacvm check` (video decoding, video decoding in Chromium: says why the daemon is down); `journalctl -u omacvm-vdecd`; `OMACVM_VIDEO_DEBUG=1` logs each stream in the VM's `logs/qemu.log` (`docs/video-decode.md`) |
| UTM VM very slow | UTM started with `open -g` (background priority) or Vulkan driver on | start UTM normally; `QEMUVulkanDriver` 1 |
| VM resumes a dead state after a hard kill (Parallels) | suspend files | delete `<pvm>/*.mem*` and `vm.lock` |
| OmacVM.app in full screen on two displays, one switched to macOS: the VM's pointer stands still on the other display until a click (3.2.10 and older) | a Mac app in front; QEMU dropped moves over its windows while it was not in front (only a click took the pointer, so a passing pointer did not take the keyboard) | 3.2.11: such a move gives the guest only the pointer's place (`omacvm-cocoa-pointer-hover*.patch`, `OMACVM_POINTER_HOVER=0` turns it off; `OMACVM_POINTER_DEBUG=1`: `omacvm-pointer: hover (output N)`); with Pause drawing while hidden, Update VM too (the agent holds Hyprland's wake on moves off while a display is paused) |
| The Mac's pointer shows over the full-screen VM | another app's window over the VM hit-test area (Bartender's menu-bar overlay brings it back) | the gestures helper hides the pointer by AppKit hit test (click-through overlays such as `screencaptureui`'s are skipped); quit such menu-bar tools |
| OmacVM.app: the Mac's arrow over the VM beside Omarchy's pointer, until switching out and back (3.1.24 and older) | QEMU hid the cursor once; a background show (Gestures' own hider, also over app VMs then) or macOS showed it again | QEMU keeps the hidden cursor's image empty and sets it again on motion or, at rest, within 0.5 s (`omacvm-cocoa-cursor-stays-hidden.patch`, `src/tests/pointer-reveal-vm.sh`); Gestures leaves app VMs alone |
| The Mac's wallpaper changes only on one Space | `NSWorkspace.setDesktopImageURL` sets only the current Space | the Bridge rewrites `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` for every Space (the `imageFile` URL inside each image choice's `Configuration` plist, which can come from an older Space, #388; `Files` as macOS writes them: none on macOS 27, whose WallpaperAgent refuses a choice with one and shows its default picture, else the URL) and restarts `WallpaperAgent` |
| A command starts UTM by itself | `utmctl` launches UTM | use `vms_list`/`vm_type` from `src/lib/vm.sh` (UTM's `Registry` preference while UTM is not running) |
| SSH output in a `while read` loop eats the loop's input | `ssh` reads stdin | `< /dev/null` on SSH calls inside loops (`vm_probe` has it) |
| ALARM downloads time out | geo-DNS mirror far away | `src/vm/base-install.sh` ranks mirrors |
| OmacVM.app, HDR on: screenshots, hyprpicker and screen shares of Chrome (PQ windows) far too bright, light greys white; SDR apps exact | Hyprland 0.56.2's and 0.57.0's SDR copy for captures puts PQ windows' SDR white at 80 nits, not 203 | Update VM (`src/app/guest/hypr-capture/`, a file per Hyprland release); `omacvm check` "HDR captures" says whether a fix fits this Hyprland and names the installed version when none does (docs/troubleshooting.md, 44) |
| OmacVM.app: Ghostty opens no window, "Ghostty requires OpenGL 4.3" (3.2.13 and older) | virgl gives OpenGL 4.1 (the Mac's OpenGL); Ghostty 1.2 and newer need 4.3; Zink on KosmicKrisp gives 2.1, and with the 3.2.13 app and older a forced 4.3 aborted QEMU (ADR 0065) | 3.2.14: the EGL vendor library starts Ghostty alone on Mesa's llvmpipe (`src/app/guest/omacvm_egl.c`, ADR 0064); Update VM, then log out and in; `omacvm check` "Ghostty"; Alacritty and Kitty draw on the GPU (docs/troubleshooting.md, 47) |
| Omarchy notifications, bar panels or the Omarchy menu black out the whole screen around their card (OmacVM.app, UTM, Parallels; Hyprland 0.57); fine with `QT_QUICK_BACKEND=software` | Hyprland 0.57.0's default `quirks:skip_non_kms_dmabuf_formats` = true (hyprwm/Hyprland#15803) offers apps only the formats a display plane takes; virtio-gpu's takes XRGB8888 only, so Mesa has no EGL config with alpha and Qt Quick's transparent layers draw opaque | 3.2.15: Update VM, then log out and in (`src/guest/omacvm_vm.lua`); `omacvm check` "transparent panels"; before: the line in docs/troubleshooting.md, 50 |
| Fusion VM: black screen at SDDM, `invalid arguments for wl_surface.attach` in the journal | stock Hyprland on vmwgfx (e.g. an update the hook could not rebuild, or a Hyprland no OmacVM patch applies to yet: check says "no vmwgfx fix for Hyprland <version> yet") | `omacvm apply`, or in the VM `/usr/local/share/omacvm/fusion/guest/build-hyprland.sh` (log `/var/cache/omacvm/hyprland-vmwgfx/build.log`); no patch yet: `omacvm update` once OmacVM has one (docs/troubleshooting.md, 1) |
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
- Parallels, UTM and Fusion never return touched VM memory to the Mac while
  the VM runs (their balloons do not report free pages). Keep zram small and
  memory capped. OmacVM.app's QEMU gives what Linux frees back to the Mac
  (free page reporting, ADR 0059; from 3.2.12 it moves the old pages aside
  and advises them `MADV_FREE_REUSABLE`, ADR 0062; up to 3.2.11 macOS kept
  holding them until the VM stopped, as `qemu-hvf-free-page-reclaim.patch`
  only maps new memory over them). Do not count a smaller footprint
  (Activity Monitor) as memory back to the Mac: it never counted those
  pages; the reclaim's qemu.log lines say how much the VM reported and how
  much of what the worker released is still held (reusable pages count as
  given back: macOS takes them first, but on a Mac with room they stay
  resident until it needs them). The file
  cache stays on the Mac, which can only compress it, and macOS's pressure
  stays "normal" while it does; the app's give-back of the cold cache while
  macOS compresses the VM (`src/memory/guest/giveback.sh`) runs only with a
  QEMU that carries the fix, and stops for the run when that QEMU says macOS
  keeps the pages anyway (`logs/memory-reclaim`).
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
- Root never writes into the desktop user's home itself, not even with
  `chown` after it. The guest scripts run as root at every apply, and a link
  the user put in the home (`~/.config/hypr -> /etc`) would point root's
  write, `install -d -o`, `chown`, `sed -i`, `rm -rf` or mount at a system
  file: root for any program running as the user. Use
  `src/guest/home-files.sh` (`home_put`, `home_append`, `home_mkdir`,
  `home_run`, ... as the user, through `setpriv`; content read as the user
  too) and `src/tests/home-links.sh`, which fails on any `chown`/`install -o`
  left and, as root on Linux, plants links and runs the scripts. Root
  daemons read the user's files only as their own plain files (`O_NOFOLLOW`,
  owner checked) or through a child running as the user.
- Only one agent should edit the guest's Hyprland config at a time.
- Do not switch the user's macOS Spaces or Mission Control in tests.
- Do not start a VM from a command that only reads or lists (features,
  `--json`, check, vms, report): a stopped VM is answered from its folder on
  the Mac (2026-10-08: `omacvm features` without `--vm` booted the person's
  VM through an old bench copy of the app). Start one only through
  `resolve_vm start` / `app_start`, which check the name and the app's version
  (`src/tests/no-autostart.sh`).
- Do not give OmacVM.app a custom icon on its bundle (`NSWorkspace.setIcon`)
  for the icon's look: it writes `Icon\r` and a FinderInfo attribute into
  the signed bundle's root, `codesign --verify --deep --strict` then fails
  ("detritus not allowed"), and the Dock keeps showing the old icon of a
  pinned app until it restarts (macOS 27, 2026-10-13). The Dock tile plug-in
  draws the look instead.
- Do not ask `omarchy-shell lock isLocked` whether the session is locked: with
  Quickshell 0.3.2 and older it answers true after the first unlock until the
  shell restarts (omarchy-mac#738), and omarchy-mac's `lock lock` then does
  nothing. Read `omarchy-shell lock status` (`requested`, `sessionLocked`,
  `secure`, read at the call), as `guest/restart-shell.sh` and Omanotch's
  `copies.py` do. Root's `sudo -u` in an apply has no locale: there `qs ipc`
  prints Qt's locale warning on stdout before every answer (Omarchy's own
  scripts misread it too), so give Omarchy's commands `LC_ALL=C.UTF-8`
  (`guest/restart-shell.sh` and `lib/omacvm-plugins` export it: without it
  `omarchy plugin enable` fails on the warning though the shell enabled the
  plugin, and the id stayed queued, 3.2.13 and older).
- Do not write under `~/.config/omarchy/plugins` or call `omarchy-shell
  shell rescanPlugins` while the session is locked or the shell does not
  answer (`src/guest/session-lock.sh`: busy counts as locked). The shell of
  omarchy-mac 4.0.3 reloads every plugin on either (an inotify watch on that
  folder; hidden entries skipped), its lock screen too, and the new one has
  no password field until a VM restart (3.2.11, 3.2.12). Upstream Omarchy
  keeps such services over the reload (omacom/omarchy#9485); omarchy-mac
  4.0.3 lacks it. Stage the copy outside the folder and let
  `guest/restart-shell.sh`'s job put it in place after the unlock, before its
  one restart (`lib/install-plugin.sh`, `lib/omacvm-plugins`); `omarchy plugin
  validate`, `enable` and `disable` are safe (they read the folder or change
  shell.json only). Feature offs under the lock: the control centre goes out
  of the bar and its folder stays until the next apply; Omanotch's own
  uninstall waits for the unlock (`guest/off.sh`, `guest/restart-shell.sh`);
  Omanotch's `display-panel.py` asks Omarchy's lock status as `copies.py`
  does; both count a shell that runs and does not answer as locked, after
  up to 20 s where nobody asks again (`display-panel.py` in every mode,
  `copies.py --install`). `src/tests/lock-rules.sh` runs one table of the
  shell's answers through all three rules. Do not try to recover with a
  shell restart instead: `omarchy-restart-shell` refuses while the lock is
  requested, and a restart under the lock is what #612 removed.
  `src/tests/plugin-lock.sh` fails for a new `rescanPlugins` caller that
  does not ask first. Not Omarchy's #738 (no lock after an unlock): that one
  stays Omarchy's.
- Do not leave files in the desktop user's runtime folder (`/run/user/UID`,
  `XDG_RUNTIME_DIR`): it is a tmpfs of 10 % of the VM's memory, and when it is
  full, Hyprland and apps die of SIGBUS on their shared-memory buffers there
  (2026-10-19: OmacVM.app's hyprpicker left 3 buffer files per display per
  screenshot; fixed in `src/app/guest/hyprpicker/`, check line "runtime folder").
- Do not read other programs' text (`ps`, `pgrep -f`, `pkill -f`) with awk patterns,
  `tolower`, sed, tr, cut or sort in omacvm's UTF-8 locale: one line that is not UTF-8 stops
  macOS's awk and sed there and makes `pgrep -f` fail (#545: a running VM taken as stopped).
  Give the reader `LC_ALL=C` (never `ps` itself: it then prints UTF-8 as `M-C`);
  `src/tests/ps-not-utf8.sh`.
- Do not send H.264 coded interlaced (field pictures, MBAFF frames) to
  VideoToolbox: the Mac's hardware decoder refuses it (-12911 when the session
  asks for the hardware, also with the stream's own SPS and PPS; FFmpeg's own
  `-hwaccel videotoolbox` the same), and the software decoder VideoToolbox
  takes instead drops every picture after a format change and has the colours
  wrong at 1080 lines (M4, macOS 27). The VA shim refuses such pictures;
  `omacvm-vdecd` fails a video after 3 of them before its first picture, so
  Chromium decodes it on the CPU (it waits for a picture with no error
  otherwise).
- Do not look for a video's visible size in VA-API: decoding has no crop, and
  apps send only slice NAL units, never an SPS. Do not guess it (1088 -> 1080
  is wrong for real 1088-row videos), fix it on the Mac alone (the size never
  gets there), preload a wrapper (sandboxes, setuid) or patch the VM's Mesa.
  The size is only in the app's EGL import; OmacVM's glvnd vendor library
  hands it to the VA shim (ADR 0063).
- Do not hand guest Vulkan values to the Mac's driver unchecked. Metal checks
  texture descriptors in release builds too and ends the process (QEMU, the VM)
  on one it cannot make; KosmicKrisp and MoltenVK pass guest values on to it.
  vkr checks image descriptions, binds, layouts, views and samplers first (ADR
  0065); a vkr path that hands the driver a new guest description needs the
  same check and a case in `app/runtime/Tests/virgl/test-venus-image-limits.c`.
  vkr's proc table entries are never NULL: a command the app's device was not
  made with reaches a stub that ends its context (`vkr_missing_entries.h`), so
  test an entry with `VKR_MISSING`, never against NULL (the runtime build
  fails on one), and a new thread that dispatches guest commands sets
  `vkr_dispatching_context`. No guest value may reach an `assert()` in vkr
  (virgl keeps them in release); such cases go in `test-venus-robust.c`.
- Do not run guest apps on Zink as their OpenGL (`MESA_LOADER_DRIVER_OVERRIDE=zink`)
  in an OmacVM.app VM with Vulkan: on KosmicKrisp it gives OpenGL 2.1 only.
  Ghostty's OpenGL 4.3 comes from llvmpipe instead. With the 3.2.13 app and
  older not even in a test: a forced 4.3 (or `LIBGL_KOPPER_DISABLE=1 glxinfo
  -B`) aborted QEMU in Metal's linear-texture check, the VM gone at once (ADR
  0064); from 3.2.14 vkr reports that image as unsupported and the VM goes on
  (ADR 0065).
- Do not give `omacvm-vdec` the kernel's `v4l2_m2m_fop_poll` back: it
  answers EPOLLERR while neither queue has a buffer queued, which is the
  normal state at the end of a stream and at a size change (Chromium holds
  every CAPTURE buffer, the daemon owes the last pictures and the LAST one).
  Chromium 153 drops a wait that gets EPOLLERR and posts no new one, so
  playback stood still there (3.2.15 and older). `ovd_poll` clears it while
  a queue streams and the decoder is not failed; `vdec-test
  --hold-all-at-eos` fails without it.
- Do not give Chromium a Vulkan compositor (`--use-vulkan`, Graphite)
  without `--disable-accelerated-video-decode` while chromium-video is on:
  its V4L2 decoder stays on there, and its buffers
  cannot be drawn on Venus. Graphite restarted the GPU process at the first
  frame (Dawn in the VM has no dma-buf import), Ganesh on Vulkan lost its
  Venus context (vkr cannot import the virgl resource). "Chromium (WebGPU)"
  decodes on the CPU for that reason (ADR 0025).
- Do not draw with an OpenGL viewport that starts more than 4096 pixels
  outside its target on the Mac (OpenGL 4.1 on Metal, M1 and M4): the
  picture comes out squeezed (the start becomes -4096, the far edge stays),
  although `GL_VIEWPORT_BOUNDS_RANGE` says -32768..32767; the software
  renderer draws it right. Keep the viewport inside the target and pick the
  part by texture coordinates. The tiled present did it in 3.2.14: tiles
  right of x 4096 squeezed on pictures wider than 4352 pixels (ADR 0055).
- Do not take `pcall(hl.config, ...)` for a guard against a Hyprland without
  the key: `hl.config` with an unknown key records a config error (a red
  banner on the screen) and raises nothing. Ask `hl.get_config(key)` first: it
  gives nil and a message for a key this Hyprland lacks (`omacvm_vm.lua`;
  `omacvm_app.lua` asks `hl.get_config` first too, from 3.2.15, #639).
- Do not take `hyprctl getoption` or a config reload for proof that a
  linux-dmabuf format setting took effect. Hyprland builds its format table at
  its start and when a monitor comes or goes; its reload listener keeps the
  last value in a function static that is first set at the first reload, so
  the first reload that changes `quirks:skip_non_kms_dmabuf_formats` never
  rebuilds it, and `hyprctl eval` never does (0.56.2 and 0.57.0,
  `LinuxDMABUF.cpp`). Only a Hyprland start applies it for sure: log out and
  in (#630).
- Do not feed a probe with `printf x | cmd` on the Mac side when `cmd` may exit
  before it reads (LibreSSL's `openssl passwd -6`, a missing binary): CI jobs
  run with SIGPIPE ignored, and bash 5's printf then writes "write error:
  Broken pipe" to stderr, which broke `omacvm build --plan --json` in a test
  that reads its output with `2>&1`. Use a here-string (`cmd <<<x`), but
  not for secrets: bash 3.2 writes a here-string to a temp file (the
  password hash in `src/cmd/build.sh` keeps its pipe).
- Do not compare a screenshot of an HDR output with `misc:background_color`
  to find the bare background. With an SDR modifier on the output (OmacVM's
  HDR rule sets `sdr_max_luminance = 203`, Hyprland's default is 80) every
  capture (grim, Omarchy's screenshot, hyprpicker, portal shares) reads
  Hyprland's unmodified SDR copy, draw buffer 1 of the frame's framebuffer
  (`render:keep_unmodified_copy` 0 makes one too while a capture runs).
  Hyprland draws its background colour with a clear of draw buffer 0 only
  (`GLElementRenderer.cpp`, 0.56.2, 0.57.0), and once attached the copy is
  emptied to (0,0,0,0) with the frame's own clear every frame, so where
  only the background shows a capture is black with alpha 0 while the
  screen shows the grey: no old picture stays there. Look at the PNG's
  alpha (`omacvm-displays` from 3.2.16): PPM has none, and black is not
  "nothing drawn" (a black wallpaper has alpha 255).
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
- Tests wait for the thing they check, on a busy CI Mac too: a control centre
  Pilot test settles on the drawn screen (`#body`), not on the state a worker
  thread set before the app's loop redraws; a time the code logged is compared
  with the event's own time, never with the clock at the check (a minute on).
- Verify on real VMs before committing behaviour changes: `omacvm apply` against a
  test VM, `omacvm build --vm-name "OmacVM Test"` (and `--vm-type utm`) for the full path,
  then `omacvm check --vm <name>` must pass.
