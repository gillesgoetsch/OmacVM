# Findings for developers

What we learned building and measuring OmacVM that a user hunting for a fix
does not need: reviews, measuring pitfalls, how the VM apps work inside.
Problems with a fix you can apply are in
[troubleshooting.md](../troubleshooting.md); the current numbers are in
[benchmarks](../benchmarks/README.md).

The numbered findings keep their numbers from troubleshooting.md, where they
were first written down.

## 7. Fusion: setup facts

Small things that cost time the first time.

| Fact | What to do | Where |
|---|---|---|
| Homebrew has no Fusion cask: Broadcom wants a sign-in for the download | support.broadcom.com > My Downloads > VMware Fusion > the newest version, drag it to Applications | README, Requirements |
| On its first start Fusion asks for Accessibility | click OK, then turn VMware Fusion on in System Settings > Privacy & Security > Accessibility | |
| Graphics memory comes out of the VM's own RAM | OmacVM gives a quarter of the VM's memory, at least 1 GB and at most 8 GB (Fusion's limit). `--graphics-gb` changes it | `src/cmd/build.sh` (`gfx_auto`), `src/vm/fusion.sh` (`svga.graphicsMemoryKB`) |
| `mob memory overflow` lines in `dmesg` | harmless: the vmwgfx driver raising its own limit | |
| A leak of GPU memory with older Mesa | Mesa 26.2.1 or newer fixes an svga dmabuf leak; check with `pacman -Q mesa` | |

## 11. Benchmarks: Chromium vs Chrome, and the screensaver

- **Symptom:** the same VM gives very different browser scores from one day to
  the next. Parallels scored 35.4 in Speedometer 3.1, after about 45 before.
- **Cause:** the 35.4 was Arch's Chromium (153) in the VM, the 45 Google
  Chrome. Arch's Chromium is much slower than Google's Chrome. Omarchy's
  screensaver and lock can also start in the middle of a run.
- **Fix:** always benchmark Google Chrome, on the Mac and in the VM, with the
  same flags Omarchy uses. Turn the screensaver and lock off
  (`omacvm enable no-idle-lock`).
- **Where:** `src/bench/install-chrome.sh` (Chrome for Linux ARM in the VM),
  `src/bench/bench.sh`. The full method: [benchmarks/](../benchmarks/README.md).

## 12. UTM: moving a VM, and changing its config

- **Symptom:** moving a UTM VM to another folder through UTM's scripting lost
  the VM. Separately, UTM's AppleScript `update configuration` started failing on
  OmacVM's VMs.
- **Cause:** a moved VM keeps its UUID, so UTM keeps a stale entry. Deleting the
  stale entry deleted the moved files too, because UTM follows its bookmark to
  the new place. And `update configuration` fails once the VM has OmacVM's
  custom icon.
- **Fix:** `--vm-dir` (where the VM goes) is for Parallels and Fusion only; UTM
  keeps its VMs in its own library. Config changes after the icon is set go
  straight into the VM's `config.plist` (UTM reloads it), not through
  AppleScript.
- **Where:** `src/cmd/build.sh` (refuses `--vm-dir` with `--vm-type utm`),
  `src/vm/utm.sh` (`utm_drop_live` uses AppleScript before the icon is set,
  `utm_set_icon` edits `config.plist`).

## 13. Security review of the Fusion route (PR #1)

The review found places where the Fusion route trusted too much. All are fixed
on the branch.

| What | Fix | Where |
|---|---|---|
| Hyprland source | built from the exact commit the package's binary names, checked after the download | `src/fusion/guest/build-hyprland.sh` |
| VMware Tools recipe | Arch's `open-vm-tools` recipe pinned to commit `a2334c0c` (tag `6-13.1.0-3`) | `src/fusion/guest/build-open-vm-tools.sh` (`RECIPE_COMMIT`) |
| Builds as root | both builds run as the desktop user; only the install runs as root | both build scripts |
| The pacman hook runs as root | it runs a root-owned copy of the build script in `/usr/local/lib/omacvm/fusion` | `src/fusion/guest/install.sh` |
| The clipboard agent's X display | a private Xvfb display with its own xauth cookie (in `$XDG_RUNTIME_DIR`) and no TCP listener | `src/fusion/guest/omacvm-fusion-clipboard` |
| The guest guessed the Mac's address | the Mac passes it (`--host`); the guest accepts only an address ending in `.1` | `src/cmd/apply.sh`, `src/guest/install.sh` |
| Fusion's `networking` file | strict parsing: the first `VNET_8_HOSTONLY_SUBNET` line, and only a private address (not UTM's) | `src/lib/mac.sh` (`fusion_host`), `src/bridge/mac/main.swift`, `src/gestures/mac/omacvm-gestures.c` |
| Listeners on the Mac | Gestures never binds `0.0.0.0`: an address it cannot parse, or `0.0.0.0` itself, means no listener on that network | `src/gestures/mac/omacvm-gestures.c` (`serverThread`) |

## 16. MotionMark gives no stable result

- **Symptom:** MotionMark 1.3.1 scores 1 to 4 on Parallels, UTM and
  OmacVM.app, with ±100 % to ±1900 % per subtest; every subtest stays at its
  minimum. On Fusion it measures normally (2368 at 120 fps, ±9 %).
- **Cause:** MotionMark raises each scene's complexity until the frame rate
  drops, which needs steady frame timing. Chrome's frames on the virgl routes
  come too unevenly for that, even at the lowest complexity. Animations and
  scrolling still look smooth in use; the benchmark can't settle.
- **Where:** `src/bench/browser-bench.py` prints the subtest breakdown.

## 17. Security review of the Mac and guest sides

- **Symptom:** `omacvm apply`, `check` or a build stops with "answers with
  another SSH host key than the one OmacVM remembered".
- **Cause:** OmacVM remembers each VM's SSH host key the first time it sets the
  VM up (build, apply) and refuses another one later. A rebuilt or reinstalled
  VM has a new key; anything else answering at the VM's address does too.
- **Fix:** after a rebuild, `omacvm apply --vm NAME --reset-host-key`.
- **Where:** `src/lib/mac.sh` (`gssh`, `hostkey_changed`), `src/lib/vm.sh`
  (`vm_pin`); the keys are in `~/Library/Application Support/omacvm/known_hosts/`.

What the review found, and the fixes:

| What | Fix | Where |
|---|---|---|
| No host-key check; `omacvm update` sent the Bridge token to any running VM that said it had OmacVM | host keys remembered per VM (above); `update` only updates VMs OmacVM set up from this Mac (a remembered key, or OmacVM's note or icon on the VM), others need `omacvm update --vm NAME` once | `src/lib/mac.sh`, `src/lib/vm.sh` (`vm_marked`), `src/cmd/update.sh` |
| Gestures let any VM on the VM networks connect (trackpad frames, Cmd keys, capture off) | every listener wants the Bridge token in the hello; daemons from before it were let in only from the VMs OmacVM had set up (their MAC addresses, listed once), until apply or update replaced them; after 2.7.0 they are refused (`omacvm update`) | `src/gestures/mac/omacvm-gestures.c`, `src/gestures/guest/omacvm-gestures` |
| A quote in a UTM VM's name ran AppleScript | the name goes in as an argument | `src/lib/mac.sh` (`utm_ip`) |
| The clipboard helper followed links in the folder the guest writes | only a plain file, never through a link, at most 4 MiB | `src/clipboard/mac/omacvm-clip-in` |
| A full name with `"`, `$` or a backtick ran in the install script; the hostname was not checked | values written with `printf %q`; hostname `^[a-z0-9][a-z0-9-]{0,62}$` | `src/vm/omarchy-install.sh`, `src/cmd/build.sh` |
| Root followed links in the user's home (`chown`, `monitors.lua`, the notchcast drop-in, the kernel build) | `chown -h`; those files written as the user; the kernel built in a folder of root's and installed from a copy root owns | guest installers, `src/kernel/build-thp-kernel.sh` |
| The Bridge: a slow client held a thread, a negative `Content-Length` crashed it | a deadline for the whole request, at most 32 requests at a time (16 per address), 400 for a bad length | `src/bridge/mac/server.swift` |

Left open: the Mac apps are signed ad hoc with a requirement that names only
their identifier, so another program signed the same way could keep their
privacy permissions (signing releases with a Developer ID fixes that); Omanotch
and Arch Linux ARM's kernel recipe follow their latest versions (not pinned to
a commit). The try-omarchy image is pinned: `src/vm/live/build-live.sh`
with `src/vm/live/release.sh` refuses a `TryOmarchy.dmg` whose SHA-256 differs.

## Parallels vs UTM, first measurements (September 2026)

From Omanotch's early days, before OmacVM's benchmark harness. The scores are
superseded by [benchmarks](../benchmarks/README.md); what is kept here is why
the gaps were there.

Setup: MacBook Pro 16" (2024), M4 Max, 64 GB, macOS 15.7.4; guest Omarchy
(Hyprland 0.56), 16 vCPUs, 48 GB; Parallels Desktop 27.0.2 and UTM 5.0.6 beta
(QEMU 10.0.12, HVF), both virtio-gpu with virgl; Arch Linux ARM's kernel
rebuilt with transparent huge pages in both.

- **UTM's Vulkan driver costs memory speed.** With it on, UTM starts QEMU with
  `ipa-granule-size=0x1000` (4 KB second-stage pages): a 20 MB typed-array loop
  in Node.js took 99 ms, 53 ms with Vulkan off (51 ms native).
- **Cross-CPU wake-ups cost twice as much in UTM**: 46.6 µs per round trip
  against 24.8 µs in Parallels (same-CPU round trips equal at about 1.8 µs).
  QEMU emulates the interrupt controller in user space; likely the cause, not
  proven. Plain computation is equal (`openssl speed rsa2048`: 3037 native,
  3035 Parallels, 3018 UTM). UTM's guest also does not see SME/SME2.
- **Transparent huge pages matter in a VM.** The stock Arch Linux ARM kernel
  has none, and every page-table miss costs extra:

  | Single thread, lower is better | macOS | Parallels stock | Parallels THP | UTM stock | UTM THP |
  |---|---|---|---|---|---|
  | Random reads over 1 GiB | 0.186 s | 0.474 s | 0.21–0.27 s | 0.49–0.53 s | 0.26–0.28 s |
  | First touch of 1 GiB (page faults) | 0.070 s | 0.138 s | 0.101 s | 0.24–0.27 s | 0.041–0.049 s |

- **UTM gets one GPU display per VM.** Two `virtio-gpu-gl-pci` adapters: QEMU
  refuses to start. One adapter with `max_outputs=2`: the guest sees the
  second output, UTM opens no window for it. A second, plain `virtio-gpu-pci`:
  UTM opens a window and Hyprland drives it, but every frame is copied over
  and the copy shows unfinished frames: 20–57 of 120 frames partly magenta at
  1920×1200 and above (grabbed with `ffmpeg -f kmsgrab`); only 1280×800 is
  clean. VRR, explicit sync, linear blits and damage tracking made no
  difference.
- **Chrome on UTM fell back to software compositing**: it got no OpenGL ES 3.0
  context from virgl until a patched Mesa reported multisampling.

How: Geekbench and the first Speedometer runs by hand; later Speedometer runs
driven over Chrome's DevTools protocol; memory with a small C program (1 GiB
random reads, first-touch faults); wake-ups with two processes ping-ponging a
byte over pipes, pinned to the same or different CPUs.
