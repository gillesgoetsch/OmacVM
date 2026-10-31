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
- **Later (2026-10-07, MacBook Air with a small internal disk):** `--vm-dir`
  works for UTM after all, without moving a registered VM: UTM makes the VM
  with only an empty NVMe disk, `export`s it into the folder, `delete`s its
  own copy (the bookmark points at the original, not at the export) and the
  export is opened with `open -a UTM`, which registers it by a new bookmark.
  The installer disk is added after that (`update configuration` with a
  `source`; UTM converts it to qcow2 inside the VM, on the drive). A UTM
  library moved as a whole (its `Documents` as a link) stops UTM from
  starting: secinitd "(AppContainer) Documents is not a directory".
  `src/vm/utm.sh` (`utm_move`, `utm_add_live`), `src/cmd/build.sh`.

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
- **Since:** OmacVM.app 3.1.27 (Mac mini M4, Chrome 156, 2026-10-21) it
  settles: 2981, 3015 and 3069 at 60 fps (±2.8 %), 30 % of Chrome on the Mac
  (9890). Per subtest, 2D canvas paths are the gap: Paths 8 %, Suits 11 %,
  Canvas Arcs 16 % of the Mac, the others 30 to 68 %.
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

## Disk in an OmacVM.app VM: the guest's btrfs sets the speed (October 2026)

Night run on 2026-10-21, MacBook Pro M1 Max (32 GB, macOS 27.0.1), VM with
8 vCPUs / 16 GB, fio 3.42 on both sides, median of 3:

| Test | Mac | VM | VM as % of the Mac |
|---|---|---|---|
| Seq write 1M, QD8, direct | 6461 MB/s | 726 MB/s | 11 % |
| Random read 4k, QD32 | 181k IOPS | 64.5k IOPS | 36 % |
| Random read 4k, QD1 | 15.4k IOPS | 11.75k IOPS | 76 % |
| Random write 4k, QD32 | 39.7k IOPS | 8.8k IOPS | 22 % |
| Write 4k + fsync | 21–36 µs | 431–457 µs | ~6 % |
| Seq read 1M | 6481 MB/s | 12227 MB/s | from the Mac's file cache |

- **Everyday work barely sees it.** Same Mac and VM: building rust-analyzer
  102 %, `git status` on 180k files 384 %, `git log` 95 %, `uv pip install`
  of 24k files 176 %. ADR 0039: git clone, checkout and pacman took the same
  time on a disk 40 % faster at small reads; they wait on the CPU.
- **Where a user would notice:** writing many GB (10 GB takes about 14 s
  instead of under 2 s), unpacking big archives, container image pulls,
  databases that commit thousands of times a second.
- **Not QEMU.** ADR 0039 measured the same NVMe disk without a file system at
  200k / 154k IOPS (4k QD32) and 7 GB/s seq write (Mac mini M4). In the VM,
  btrfs (copy on write, checksums, zstd:1) costs most of it: with `chattr +C`
  (nodatacow) on the test folder, seq write went from 730 MB/s to 1.6 GB/s.
- **Rollback today:** omarchy-mac snapshots `/` with snapper before each
  update, OmacVM keeps 2 (`src/guest/disk-space.sh`), and GRUB lists them for
  2 s at every start (grub-btrfsd). `/home` is not in them.

Second round on 2026-10-25, MacBook Pro M4 Max (internal SSD, macOS 27.0.1),
VM with 4 vCPUs / 4 GB, the VM's own btrfs (`compress=zstd:1`,
`discard=async`; NVMe queue: scheduler none, 4 queues, read-ahead 128 KiB),
fio 3.42 with direct I/O on both sides, median of 3. In the VM direct I/O only
skips the guest's cache: with `cache=writeback` its reads can still come from
the Mac's file cache (below).

| Test | Mac | VM | VM as % of the Mac |
|---|---|---|---|
| Seq write 1M, QD8 | 7161 MB/s | 1237 MB/s | 17 % |
| Random read 4k, QD32 | 202k IOPS | 91.7k IOPS | 45 % |
| Random read 4k, QD1 | 15.4k IOPS (60 µs) | 19.6k IOPS (44 µs) | 127 % |
| Random write 4k, QD32 | 48.1k IOPS | 14.8k IOPS | 31 % |
| Seq read 1M | 6400 MB/s | 19.7 GB/s | from the Mac's file cache |

- The VM reads faster than the Mac at queue depth 1 and in big reads because
  `cache=writeback` keeps disk.img in the Mac's file cache: a "cold" start in
  the VM (its own cache dropped) often reads from the Mac's memory. Cold in the
  VM: `python3` with four modules 0.06 s, `git status` on 20k files 0.03 s,
  headless Chromium to its first page 0.19 s.
- Write speed is btrfs (the raw NVMe disk takes 7 GB/s, ADR 0039), as on the
  M1 Max.
- QEMU's side was checked again for this round, nothing better found: aio
  threads is the only mode on macOS, `cache=none` costs 70 % of random
  writes, the guest already uses no I/O scheduler, NVMe already has a queue
  per vCPU; virtio-blk + iothread still waits for its pause hang (ADR 0039).
- TRIM: deleting 2 GiB and `fstrim /` took disk.img from 14443 to 10531 MiB
  on the Mac (the trim also returned blocks earlier test runs had freed, whose
  async discards were lost at power-off: ADR 0048).
- The guest's flushes are write barriers since 3.2.1 (ADR 0053, #516); these
  rows ran with them.

Options for later (none started; parked on 2026-10-21):

1. **nodatacow and no compression on heavy-write folders** (containers,
   databases, Downloads, caches): about 2x seq write there. Those files lose
   btrfs checksums and compression; snapshots of `/` keep working.
2. **`compress=no` alone:** not measured.
3. **virtio-blk + iothread:** +40 % 4k IOPS, blocked by the hang after pause
   and resume (ADR 0039).
4. **ext4 or xfs as the root, the Mac takes the snapshots:** an APFS clone of
   `disk.img` (`cp -c`, instant, no space until blocks change) at each VM
   start, a few kept, "go back" in the app. Expected close to the raw disk;
   ext4 itself not measured. What it costs:
   - a whole-disk rollback also takes back the user's own files (snapper
     leaves `/home` alone), so a separate home disk or a clear warning;
   - no compression: more space on the Mac (measure with `compsize` in a real VM);
   - "make the disk smaller" shrinks btrfs while the VM runs; ext4 shrinks only
     offline, xfs never;
   - omarchy-mac expects btrfs and snapper (update snapshots, the GRUB menu):
     switched off and kept off through its updates;
   - a new image, so new VMs only; existing VMs would need their files copied;
   - no checksums on file data (macOS has none on file data either).

   First step if picked up: an ext4 test disk beside btrfs in a test VM, with
   fio, the everyday tests above and `compsize`.
5. **Flushes and power cuts:** a guest flush becomes `fdatasync()` on APFS, not
   `F_BARRIERFSYNC` or `F_FULLFSYNC`. It reaches the file system but not the
   SSD's cache, so only a hard power cut can lose the last writes. Measured on
   the M1 Max per call: fsync 21–36 µs, `F_BARRIERFSYNC` 0.66–0.75 ms,
   `F_FULLFSYNC` 5.7–6.0 ms. With `F_BARRIERFSYNC` a guest fsync would go from
   about 0.45 ms to roughly 1.1–1.9 ms (estimate: btrfs sends 1–2 flushes per
   fsync). Done in 3.2.1 (ADR 0053): measured on the M4 Max, whose barrier
   costs about a third of the M1 Max's (211 µs on the Mac), a guest fsync went
   from 0.38 to 0.63 ms; git commits +40 %, installs and checkouts the same.
   Not measured in a VM on the M1 Max, where the estimate above still holds.

## GPU work in an OmacVM.app VM: where the time goes (October 2026)

Measured on a Mac mini M4 (10-core GPU, macOS 27.0) with 3.1.27, a VM with 4 CPUs and 6 GB, Vulkan on Venus
with KosmicKrisp, OpenCL on rusticl and Zink. Same program versions on the Mac and in the VM (llama.cpp b11760,
Llama 3.2 3B Instruct Q4_K_M, whisper.cpp v1.9.5 base.en, darktable 5.6.1, Geekbench 7.1.0), medians of 3, nothing
else running. "VM %" is the VM's speed against the Mac's.

| Work | Mac | VM | VM % |
|---|---|---|---|
| llama.cpp prompt (pp512, t/s) | Metal 550; Vulkan: MoltenVK 423, KosmicKrisp 160 | 159 | 29 % of Metal, 99 % of KosmicKrisp |
| llama.cpp generation (tg128, t/s) | Metal 46.3; KosmicKrisp 45.8 | 45.2 | 98 % |
| whisper.cpp encoder (ms) | Metal 47 | 104 | 45 % |
| Geekbench 7 GPU (one run each) | Metal 52630, OpenCL 33795 | OpenCL 17879 | 53 % of OpenCL |
| darktable RAW export (s) | OpenCL 3.5, CPU 3.7 | OpenCL 5.8, CPU 2.0 | OpenCL slower than the VM's own CPU |
| one dispatch, submit + wait (us) | KosmicKrisp 101, Metal 158 | 185 | 55 % |
| OpenCL kernel + clFinish (us) | Apple's OpenCL 165 | 229 | 72 % |

- **The loss is in KosmicKrisp's shader translation, not in Venus.** llama.cpp's prompt processing runs at 99 % of
  the same driver on the Mac; that driver itself is at 29 % of Metal and 38 % of MoltenVK. KosmicKrisp never
  unrolls a loop, so llama.cpp's matmul keeps its accumulators in scratch memory and its caches in if-else trees.
  Unrolling loops of up to 32 iterations before local arrays are lowered gives llama.cpp's prompt +130 % natively
  on an M1 Max and an M2 and +22 % on an M4 (in a VM: +119 % on an M2, +15 % on an M4 Max). But on an M2 it costs
  Dawn's WebGPU matmul 25 %, and a model's first pipeline creation takes 54 % longer (about 1.4 s more, once:
  Metal caches the shaders after), so it is not shipped. Also: KosmicKrisp scalarizes every ALU operation and never merges
  loads into vectors, where MoltenVK's MSL keeps `half2` fma and vector loads (look with `MESA_KK_DEBUG=msl`).
- **MoltenVK is the faster driver for llama.cpp** (VM: pp512 432 t/s against 159, tg128 42.6 against 45.2) but has
  no OpenCL (Zink needs nullDescriptor), its pipeline barriers cost 38 us per dispatch on the Mac (in the VM,
  64 dispatches recorded with barriers take 1.3 ms against 0.36 ms on KosmicKrisp) and it has no copy-free Vulkan windows. `OMACVM_VULKAN_DRIVER=moltenvk` for the app
  picks it for a test.
- **Each GPU round trip costs ~85 us more in the VM** (submit + wait 185 against 101 us). Polling the fence in the
  guest instead of sleeping saves only ~19 us: most of it is on the Mac (the Venus ring thread's wake-up, the fence
  through the render server, QEMU's main loop and the interrupt). Token generation and big kernels do not
  notice it. The ring thread's naps end late on macOS (10 us take 16). Looking for the next command 200 us longer
  before napping was tried and dropped: submit + wait got 12-15 us faster on the M4s (Mac mini 185 -> 170, MacBook
  Pro M4 Max 154 -> 142), but 64 dispatches recorded with barriers got twice as slow on the M4 Max (285 ->
  587 us; M1 Max 516 -> 657) and vkcube 10 % slower; WebGPU, GTK4's first frame and scrolling stayed the same.
- KosmicKrisp re-records a command buffer that is submitted again (Metal's are one-shot): 77 us per
  `vkQueueSubmit` of the same buffer, MoltenVK 6 us.
- Geekbench 7's Linux ARM preview lists no Vulkan device, only OpenCL. Arch Linux ARM's darktable 5.6.1 (October
  2026) is linked against OpenEXR 3.4 while the repo has 3.5; the measurement used OpenEXR 3.4.16 built next to it.
- **Where:** `src/bench/gpu/` (`vklaunch`, `cllaunch`, `mtllaunch`)
  measure a dispatch's round trip; `MESA_KK_DEBUG=msl` prints KosmicKrisp's MSL.

## macOS's Touch ID dialog: which display it shows on (October 2026)

coreauthd puts its own Touch ID dialog (an `LAContext` evaluated by a process
without a window, as OmacVM Bridge does; its window is coreautha's, layer
1000) on the display of QEMU's key window. In every row below that was also
QEMU's main window (QEMU hands the keyboard back to it), so these rows do not
tell key and main window apart. Not the display under the pointer, and not
the main display. Mac mini (macOS 27), two virtual displays (A main, B),
OmacVM.app 3.2.9's QEMU in front: QEMU's main window full screen on A and its
window for B full screen on B, pointer on B: the dialog on A; main window on
B: on B; one window on B, pointer on A or on B: on B.

So for an OmacVM.app VM in full screen on two displays, macOS's dialog (the
fallback when the command is too long for OmacVM's panel, the Mac-password
fallback if turned on, the panel turned off) shows on the main window's
display, which is the display the VM started on. OmacVM's own panel follows
the pointer instead (ADR 0041, 3.2.11 addendum). Moving the dialog would at
least mean making the pointer's window key before asking, which changes who
holds the keyboard.

## Full screen including notch after a display change (October 2026)

From the user's MacBook Pro M4 Max (3.2.9) and macOS 27's AppKit, read on
the Mac mini (ADR 0044, "Retake after a display change").

- **NSScreen lags a display change; AppKit's layout does not.** With the
  built-in display leaving the set (lid shut, or an external display
  waking first), AppKit laid the full-screen window out for the external
  display while `[window screen]` still named the built-in, in coordinates
  from the old primary height: frame `0,-323 2560x1440` on `0,0 1728x1117`.
  A frame not inside its NSScreen, or one on a display CoreGraphics has
  inactive or asleep, is a display change on its way, not a window AppKit
  moved itself.
- **AppKit lays a full-screen tile out only on its own occasions.** After a
  Space returns to a display, nothing asks the content controller's
  `reservesSpaceForMenuBarInFullScreen` again unless AppKit does a layout.
  `-[_NSFullScreenSpace updateTileShapeAndReshapeContents]` is that layout
  (`_updateTileShapeAndReshapeContentsWithAckServer:YES` ->
  `tileContentRectForTileRect:`, which asks the reservation and takes
  `_revealedMenuBarHeight` off), but it returns at once while a flag byte
  of the Space (offset 0xa9 on 27.0) is set: judge a call by the window's
  frame afterwards.
- **`-[_NSFullScreenSpace alwaysReservesSpaceForMenuBarInFullScreen]`** is
  AppKit's own "the Space's display has a camera housing"
  (`[[space screen] _notchFrameForSpace:]` higher than 0), or a branch on
  the app's presentation options; it does not depend on a stale NSScreen.
- **Where:** the names and types are checked at
  run time by `omacvm-cocoa-fullpanel-retake.patch`.

## SPIR-V 1.4+ entry point interfaces list unused descriptors (October 2026)

Found with #624 (lane `venus-624`). From SPIR-V 1.4 an entry point's interface
lists every global it uses, so it looks like the list of descriptors a shader
needs in its pipeline layout. It is not: glslang (shaderc 2026.4, `--target-env
vulkan1.3`) lists a declared but unused storage buffer there too
(`fuzz-venus-spirv.c`, seed `spec16`: set 5 in the interface, used nowhere).
Vulkan only requires the descriptors a shader statically uses to be in the
layout. vkr's SPIR-V scan therefore takes the descriptors from the pointer
instructions of the functions the entry point reaches through calls, not from
the interface; a check by interface would end valid apps.

## KosmicKrisp has no index checks in release builds; Metal's amplification count is 8 on Apple7 (October 2026)

Found with #624 (lane `venus-624`; probe and test through vkr's dispatch on the
M1 Max, Apple7, macOS 27.0.1, 3 runs; work/tracks/venus-624.md). KosmicKrisp is
built with `-Db_ndebug=true`, so every `assert()` in Mesa's Vulkan runtime and
in KosmicKrisp is gone, and `UNREACHABLE` is `__builtin_unreachable()`. A
Vulkan app's index, count or offset is then a memory address in QEMU:
`push + offset` for push constants, the first index of viewports, scissors,
vertex buffers and descriptor sets, `binding offset + element * stride` in a
descriptor set's memory, query reports at `firstQuery`, a clear colour in an
array of 8 on the stack, a binding array sized by the largest binding number + 1
(0xffffffff wraps to 0), dynamic buffers counted in a `uint8_t`, and
`vk_pipeline_layout` / `vk_graphics_state` copying into fixed arrays (32 set
layouts, 14 push constant ranges, 16 viewports, 8 colours, 32 vertex bindings
and attributes, 32 sample locations). An unknown compare op, cull mode, blend
factor, dynamic state or descriptor type reaches `__builtin_unreachable()`.
MoltenVK checks less of this at record time and encodes at submit (set
`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` to see at `vkEndCommandBuffer`
what QEMU's submit would do), and also reads vertex buffers, descriptor sets
and push constants a draw uses when the app never set them.

KosmicKrisp told 32 multiview views and renders N views with Metal vertex
amplification count N: Metal aborts on 9 or more on Apple7
(`supportsVertexAmplificationCount:` says yes up to 8); MoltenVK renders 32.
vkr now tells KosmicKrisp's count as Metal's (ADR 0065). The mini's M4
(Apple9) says 8 too (the runtime build's test there, #644).

What the test found against 3.2.15's vkr (`Tests/virgl/test-venus-commands.c`,
210 cases): 147 fail on KosmicKrisp, 134 on MoltenVK and on MoltenVK with
prefilled command buffers (signals on the refused classes, the legal multiview
passes on KosmicKrisp, and cases the drivers accept that the GPU would run out
of range); none with the patches.

## MoltenVK trusts a submit's value counts and keeps dedicated targets (October 2026)

Found with #624 (lane `venus-624-c`; drivers probed alone on the mini's M4,
plainly and under libgmalloc). MoltenVK 1.4.2 writes the values of a chained
`VkTimelineSemaphoreSubmitInfo` by that struct's own counts into its arrays of
the submit's semaphore counts, also when only binary semaphores are named and
Vulkan ignores the values. It keeps the image or buffer memory was made for
(`VkMemoryDedicatedAllocateInfo`) in the memory and writes to it when the
memory is freed, so an image destroyed before its bind leaves a dangling
pointer there. Both drivers write a descriptor update over several bindings
with the first binding's stride or layout, and KosmicKrisp frees whatever a
free names (twice, or into another pool). vkr fits or refuses each (ADR 0065).
QEMU 11 raises its own soft open-file limit to `OPEN_MAX` (10240) on macOS
(`os_setup_limits`), whatever launchd's 256 is.

## Metal ends the process on a texture it cannot make, also in release (October 2026)

Found with #598 (Ghostty and `glxinfo` with Zink ended the VM on Vulkan). Metal
checks a texture's descriptor when it is made and, if it cannot make it, calls
`MTLReportFailure` and aborts: `_mtlValidateStrideTextureParameters` for linear
textures, `newTextureViewWithPixelFormat` checks for views. This runs in release
builds with no `MTL_*` setting (the crash stacks have no MTLDebug frame), and
nothing turns it off. KosmicKrisp and MoltenVK pass a Vulkan app's values on to
it, so in OmacVM.app, where Venus runs in QEMU's process (ADR 0012), a guest
program's bad image, view or sampler ended the VM. vkr now checks first (ADR 0065).

What ended the process before the check (`Tests/virgl/test-venus-image-limits.c`
against 3.2.13's vkr and drivers, M4, macOS 27; KK = KosmicKrisp, MVK = MoltenVK;
the kit's probes in work/zink-abort/out/ have 3 identical runs of each case
called on the drivers directly):

| What the guest asks | KK | MVK |
|---|---|---|
| a LINEAR image with COLOR and INPUT_ATTACHMENT (Zink), bound | abort at bind: "Linear texture: must be of type MTLTextureType2D" | made |
| LINEAR with 2 levels, 4 samples, a 3D, depth or BC1 format | abort | refused by its create |
| 5 levels on a 1x1 image; past 16384 texels; past 2048 layers or depth | abort | abort |
| samples 3 or 64 | abort | abort |
| a zero width or 0 layers | abort | made |
| a 2D image with depth 4 | made | abort |
| a format the driver has no entry for (R64G64B64A64 float): an image or texel view | crash | abort |
| the same format for a view of an image | crash | made |
| a view past the image's levels or layers, of another texel size, viewType 7, 3D of 2D, cube of 5 layers | abort | made |
| a texel view of 2^28 + 65536 R8 texels | abort | made |
| sampler magFilter 7 | abort | made |
| `vkGetImageSubresourceLayout` with PLANE_1 on a one-plane image | answers | crash |
| `vkGetDeviceImageMemoryRequirements` with 5 levels on 1x1 / a LINEAR D32 | abort / abort | abort / answers |
| a bind of memory of a type the image does not take | (one type only) | abort |

Lives on both and is not refused unless the spec check is cheap: a cube view
without CUBE_COMPATIBLE, a 2D view of a 3D image without 2D_ARRAY_COMPATIBLE, an
sRGB view without MUTABLE, anisotropy 17, LOD bias 1e9. A texel view past its
buffer lives on both but would have the GPU read outside it; it is refused.

## A Vulkan device's entry points follow the app's version, and the loader can end the process (October 2026)

Found with #624 (lane `venus-robust`). vkr loads a device's entry points for
MIN(the driver's Vulkan version, the guest instance's `apiVersion`) and the
extensions the device was made with; the rest are NULL. A guest app that asks
for Vulkan 1.1 gets a 1.1 device even on a 1.3 driver, and any program in the
VM can still send a 1.3 command: up to 3.2.14, vkr called address 0 in QEMU's
process. Since 3.2.15 every missing entry is a stub that ends that app's
context (ADR 0065's amendment); check one with `VKR_MISSING`, never against
NULL.

The Vulkan loader in the runtime (`libvulkan.1.dylib`) gives instance-level
entries for device-extension queries (cooperative matrix, fragment shading
rates and 26 more) whether the driver has them or not. When the driver has
not, the loader's entry logs "ICD associated with VkPhysicalDevice does not
support ..." and calls `abort()`: MoltenVK has no cooperative matrix or
fragment shading rate query, so a program asking for one ended the VM.
KosmicKrisp gave NULL there instead. vkr now uses those entries only when the
device lists the extension.

## HDR screenshots of the bare desktop are black (October 2026)

Found with lane `hdr-grab` (a follow-up from #639's rows). In an OmacVM.app
VM with HDR on, a screenshot of a part of the screen where only Hyprland's
background colour shows comes out black, while the screen shows the grey.
Rows on the Mac mini: hidden test VM, HDR on as in #639's rows (the test
app's `hdr` switch and `OMACVM_TEST_EDR=16,6.69`: Virtual-1 XRGB2101010 in
PQ, SDR white 203 nits), Hyprland 0.56.2-7 and 0.57.0-2 alike, Omarchy's
shell stopped:

- grim: (0,0,0) on 100 % of the picture below its top tenth, alpha 0 in its
  PNG (also at `-s 0.1`); the screen (the scanout read over KMS, PQ decoded
  at 203 nits): the grey, 19.1 of 255. Omarchy's own screenshot: black.
- The same with OmacVM's capture file removed (`hypr-capture.sh --remove`)
  and with `render:keep_unmodified_copy` 0 or 2; no old picture stays where
  a closed window was.
- With Virtual-1 in SDR: grim (17,17,17), the same as the screen.
- Omarchy's wallpaper and windows: grim gives what the screen shows; a drawn
  black block has alpha 255.

Why: captures read Hyprland's unmodified SDR copy when the output is PQ or
HLG and has an SDR modifier (`CMonitor::needsUnmodifiedCopy()`: SDR min or
max luminance, brightness or saturation other than the defaults; the max
default is 80, OmacVM's HDR rule sets `sdr_max_luminance = 203` in
`omacvm-display-sync`). The copy is the second draw buffer of the frame's
framebuffer (the mirror texture, `GLFramebuffer.cpp`); surfaces write it
from their shader, but the background colour is
`glClearBufferfv(GL_COLOR, 0, ...)`, buffer 0 only (`GLElementRenderer.cpp`,
0.56.2, 0.57.0 and main of 2026-10-30). Once attached the copy stays
attached (`IFramebuffer::enableMirror` returns early for the same texture),
so the frame's own clear (`clearAfterInvalidation`) empties both buffers to
(0,0,0,0) every frame: nothing old stays behind. `keep_unmodified_copy` 0
behaves like 2 here: with a modifier and PQ it falls back to
`needsACopyFB()`, which is true while any capture runs. Without a modifier
there is no copy and captures read the screen's buffer.

What it broke in OmacVM: `omacvm-displays`' desktop look (a `grim -t ppm`
grab compared with `misc:background_color`) and `omacvm check`'s "desktop"
line never saw an undrawn wallpaper in HDR: with a see-through layer named
like Omarchy's wallpaper the look found the grey on 0.0 of the picture
(undrawn: no) in HDR and on 1.0 (undrawn: yes) in SDR. From 3.2.16 the look
reads grim's PNG (a small reader in the file: 8- or 16-bit RGB or RGBA) and
counts alpha 0 as nothing drawn as well. Rows with it (same VM, 0.56.2-7 and
0.57.0-2, grim -s 0.1 = 192x108 RGBA in HDR and SDR alike):

- see-through layer, HDR: nothing drawn on 1.0 (alpha 0 on 1.0), undrawn;
  3.2.15's look on the same desktop 0.0. SDR: 1.0 in both.
- Omarchy's wallpaper: 0.0 in both modes (alpha 255 on 0.979; the rest are
  the picture's edges, part transparent after the downscale); no restart and
  no "no desktop drawn" line over 3 looks (pokes and a shell start).
- an opaque black layer: 0.0 (alpha 255 on 0.979), not counted.
- a window over the see-through layer: the display is not judged (a window
  on its workspace); beside the window alpha 0 on 0.708 in HDR.
- the agent with the see-through layer in HDR: "no desktop drawn on
  Virtual-1: restarting the shell" once, shell-repairs count 1, then the
  wallpaper drawn; `omacvm check`'s "desktop" FAIL before, ok after. With
  3.2.15's agent (0.56.2): no line and no restart over two looks, check ok.

About 2 % of the small grab of a drawn wallpaper is part transparent (its
edges after the downscale), so only alpha 0 counts as nothing drawn.

People see the black only while the shell's wallpaper is down (a shell
restart or crash): screenshots and shares of the bare background. That
part is Hyprland's; a report for Hyprland is drafted, not posted.
