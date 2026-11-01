# 0064: Ghostty draws on Mesa's CPU renderer: it needs OpenGL 4.3, the VM's GPU gives 4.1

Status: accepted, built (`issue-598`, 3.2.14), always on in OmacVM.app VMs
for the program `ghostty` alone. Amends ADR 0063: OmacVM's EGL vendor
library gets a second job, and for that job it sets an environment variable
(0063 had none). Reported in #598 (@benoitdepaire). Notes, the
investigation and the review: work/tracks/issue-598-ghostty.md. Amended in
3.2.18 (`ghostty-zink`): with the app's experimental switch "Ghostty on the
Mac's GPU" (off by default) Ghostty draws on Zink over Venus instead, on
KosmicKrisp only (section "Amendment" at the end).

## Context

Ghostty 1.2 and newer (since 2025-09) need OpenGL 4.3: their shaders read
storage buffers (`layout(std430) readonly buffer`). OpenGL in an OmacVM.app
VM is virgl on the Mac's OpenGL, which macOS stops at 4.1 core, so the VM
gets 4.1 core / ES 3.0. virgl serves OpenGL in both Graphics modes; Vulkan
adds Venus beside it for Vulkan apps (measured with Vulkan: Mac mini M4,
macOS 27.0, Omarchy 4.0.3rc4-2, Mesa 26.2.5, Ghostty 1.3.1). Ghostty then
logs "OpenGL version is too old. Ghostty requires OpenGL 4.3" and opens no
window.

Omarchy 4's default terminal is foot (omarchy-mac 3.3 had Ghostty); Ghostty,
Alacritty and Kitty are choices (Install > Terminal, Setup > Defaults >
Terminal). Omarchy's screensaver runs in the default terminal, one
full-screen window per display (`omarchy-launch-screensaver`).

## Options

Measured on 3.2.12 in a test VM (Graphics Automatic, so Vulkan on macOS 27):

| Driver | OpenGL core | compat | ES | Ghostty |
|---|---|---|---|---|
| virgl (the default) | 4.1 | 4.1 | 3.0 | no window (OpenGLOutdated) |
| virgl, 4.3 forced (`MESA_GL_VERSION_OVERRIDE=4.3 MESA_GLSL_VERSION_OVERRIDE=430`) | 4.3 claimed | | | no window: "Too many fragment shader storage blocks (1/0)" |
| llvmpipe (`LIBGL_ALWAYS_SOFTWARE=1`) | 4.6 | 4.6 | 3.2 | opens, draws, takes typing (in 614 ms) |
| Zink on Venus (KosmicKrisp) | none | 2.1 | 2.0 | frame only: "No EGL configuration available" |
| Zink, 4.3 forced | 4.3 claimed | | | QEMU aborted, 4 of 4 starts (up to 3.2.13; from 3.2.14 the VM goes on, ADR 0065) |

1. **Docs only** (`LIBGL_ALWAYS_SOFTWARE=1 ghostty`, or another terminal):
   Ghostty stays without a window for everyone who picks it.
2. **Ghostty alone on llvmpipe**, three ways:
   a. **OmacVM's EGL vendor library** (chosen): already first in every app
      VM's glvnd chain and rebuilt at every Update VM; covers every way
      Ghostty starts (Super+Return through uwsm-app and xdg-terminal-exec,
      its D-Bus/systemd service, a shell, Omarchy's screensaver).
   b. Launcher files (a desktop file copy with `env LIBGL_ALWAYS_SOFTWARE=1`,
      a systemd drop-in for `app-com.mitchellh.ghostty.service`, a
      `/usr/local/bin/ghostty` wrapper): three copies that go stale with
      Ghostty's own files, and the variable reaches the programs started
      inside Ghostty (measured: with it on Ghostty's command line, eglinfo
      from Ghostty's shell got llvmpipe; Chromium drops it for its GPU
      process and kept the GPU).
   c. Mesa's driconf per program (`dri_driver`): measured, no: `swrast`
      opens no window (Ghostty stops after GTK's start), `kms_swrast` is
      refused by the kernel (`DRM_IOCTL_MODE_CREATE_DUMB`: permission denied).
3. **Zink on Venus**: OpenGL 2.1 without a core profile, because the Mac's
   Vulkan driver (KosmicKrisp, pinned at Mesa e5f0687) has no transform
   feedback (3.0) and no geometry shaders (3.2). (Float64 is no limit: Zink
   reports doubles whatever the Vulkan driver has, `zink_screen.c` in Mesa
   26.2.6 and main.) With a forced 4.3 every Ghostty start aborted QEMU, and so
   did one `MESA_LOADER_DRIVER_OVERRIDE=zink LIBGL_KOPPER_DISABLE=1 glxinfo -B`
   run as the desktop user: a Metal assertion in KosmicKrisp's
   `vkBindImageMemory2` for a linear image Metal takes as a 2D array
   (`mtl_new_texture_with_descriptor_linear`). The VM was gone at once. So it
   was up to OmacVM.app 3.2.13; from 3.2.14 vkr reports that image as
   unsupported and the VM goes on (ADR 0065), and Zink still gives no 4.3.
4. **virgl 4.3**: Apple's OpenGL 4.1 has no storage buffers and no compute
   shaders; the forced version fails Ghostty's shader link. Turning read-only
   storage buffers into buffer textures in virglrenderer's shader translation
   would still not be 4.3 (no compute).
5. **Another default terminal**: Omarchy's choice, and it is foot already.

## Decision

Option 2a.

- In a process whose executable (`/proc/self/exe`, worked out once in
  `__egl_Main`) is named `ghostty`, and only there, the library's
  `getProcAddress` hands glvnd a wrapper for `eglInitialize`; every other
  process gets Mesa's own `eglInitialize`, as before.
- Mesa picks its driver in `eglInitialize` (it reads
  `LIBGL_ALWAYS_SOFTWARE` there, and the software screen reads
  `GALLIUM_DRIVER` while it is made). The wrapper sets
  `LIBGL_ALWAYS_SOFTWARE=1` for Mesa's call and removes it right after, also
  when Mesa's call fails, on every call, under a mutex: Ghostty draws with
  llvmpipe (OpenGL 4.6), and the programs started in it (its shell and what
  runs there) get an environment without the variable, so they keep the GPU
  (measured: eglinfo from its shell got virgl).
- A `LIBGL_ALWAYS_SOFTWARE`, `MESA_LOADER_DRIVER_OVERRIDE` or
  `GALLIUM_DRIVER` that is already set is left alone: a driver chosen by
  hand wins (the reporter tried `MESA_LOADER_DRIVER_OVERRIDE=zink`).
- No switch and no settings row: it is not opt-in, Ghostty opens no window
  without it. `omacvm check` has a "Ghostty" line when Ghostty is installed:
  ok (on the CPU, the cost, the GPU-drawn terminals) or FAIL (no window: the
  library is missing or from before 3.2.14).
- Omarchy's screensaver in Ghostty is kept, not left out by its class
  (`org.omarchy.screensaver`): it then runs on the CPU too while it shows,
  and that is heavy (Cost: 3.7 of a 4-CPU VM's cores, and the Mac mini
  drew about 36 W against 14-18 W with no screensaver and 20 W with it in
  foot). Without the change it opened no window at all. Off: Omarchy's
  `omarchy-toggle-screensaver`, `omacvm enable no-idle-lock` (both named
  in `omacvm check`'s Ghostty line), or foot as the default terminal (foot
  draws on the CPU as well, by design, at a fraction of the cost). Keeping
  it is open after these numbers; the other way is to leave the class out,
  so that with Ghostty the screensaver opens no window, as before.

## Cost

Ghostty on the CPU, against foot (Omarchy's default, CPU by design) and
Alacritty (GPU); 4-CPU VM, 10 s of output at 2,400 lines/s, then 10 s idle;
median of 3 (`work/issue-598/kit`, `kit2`):

| Window | Ghostty: scrolling 10 s / idle 10 s | foot | Alacritty |
|---|---|---|---|
| 1296x690 pixels at scale 1 (3.2.12 with `LIBGL_ALWAYS_SOFTWARE=1`; no bench lock) | 24.9 / 1.57 CPU-s | 1.47 / 0.02 | 0.72 / 0.03 |
| 1272x640 pixels at scale 2 (this change; bench lock) | 19.8 / 1.58 CPU-s | 0.82 / 0.03 | 0.60 / 0.03 |
| 1296x690 pixels at scale 1 (this change; bench lock) | 22.8 / 1.82 CPU-s | 1.53 / 0.00 | 0.80 / 0.07 |
| 2512x1500 pixels at scale 2, a 2560x1600 output (this change; bench lock) | 35.5 / 4.21 CPU-s | 2.03 / 0.01 | 0.84 / 0.01 |

So about 2 to 2.5 of the 4 vCPUs while output scrolls in the smaller
windows and 3.5 (29.9-35.5 CPU-s) in the large one, and 0.16 to 0.42 of
one in the 10 s after it stopped, with the cursor blinking (foot and
Alacritty almost none). On the Mac, QEMU used 25.0 CPU-seconds per 26 s
run with Ghostty against 5.5 with foot and 5.4 with Alacritty (1272x640),
and 44.6 against 7.5 and 6.7 per 26-27 s run (2512x1500); the Mac GPU's busy
share stayed at 0-7 % in all (a hidden test window).

Omarchy's screensaver with Ghostty as the default terminal, this change:
two outputs at scale 2 (the hidden test window's 1320x740 and a 2560x1600
one), one full-screen screensaver window on each. Windows of 180 s between
two of macOS's power telemetry updates (about one a minute); whole-Mac power
of the Mac mini M4 from that telemetry (no sudo), with other work on the
Mac taking one to two cores (its own apps, at times another lane's tests),
so the two idle runs differ by 4 W:

| 180 s | guest CPU | QEMU on the Mac | Mac power | Mac GPU busy |
|---|---|---|---|---|
| No screensaver (2 runs) | 5.3 / 2.6 CPU-s | 4.9 / 3.9 CPU-s | 14.4 / 18.5 W | 0 % |
| Screensaver in Ghostty (2 runs) | 670 / 673 CPU-s | 656 / 664 CPU-s | 35.8 / 35.6 W | 3 % |
| Screensaver in foot (1 run; the second stopped at critical memory pressure) | 152 CPU-s | 201 CPU-s | 20.4 W | 13 % |

So the screensaver in Ghostty keeps 3.7 of the VM's 4 vCPUs and 3.7 of the
Mac's cores busy while it shows; in foot 0.8 and 1.1. Three 30-s runs of each
gave the same split (QEMU 102-103 CPU-s per 30 s with Ghostty, 31-33 with
foot). On 3.2.12 it opened no window with Ghostty (guest 0.66 CPU-s in 20 s).
How long it shows (Omarchy's source, 4.0.3rc4-2 as the VM installs it; not
measured): with Omarchy's defaults (`idle` in `~/.config/omarchy/shell.json`:
screensaver 150, lock 300) it runs from 2.5 minutes idle until the lock at
5 minutes, which closes it (`omarchy-system-lock` kills the screensaver's
terminals), and it does not start while the screen is locked.

## Consequences

- The first app OmacVM puts on the CPU on purpose. A Ghostty that prints a
  lot keeps several of the VM's cores busy where Alacritty or Kitty use the
  Mac's GPU; `omacvm check` and docs/troubleshooting.md (47) say so.
- ADR 0063's "no environment variable" no longer holds for Ghostty: one
  variable, for one call, in one program. Risk left: another thread of
  Ghostty reading the environment while it changes (`getenv` is not safe
  against `setenv`); GTK sets up EGL once per display, on its main thread,
  for the first window.
- A Ghostty that already runs keeps the driver it started with: its D-Bus
  service (`--initial-window=false`) can outlive Update VM. After the
  update: log out and in, or `systemctl --user stop
  app-com.mitchellh.ghostty.service`. A precaution: in the 3.2.12 test VM
  no Ghostty was left to keep the old driver. Ghostty started from a shell
  exits when OpenGL fails, and its service did not start at all, neither by
  `systemctl --user start` nor by D-Bus activation (systemd: "Main process
  lacks handler for reload signal USR2, refusing service startup"; seen
  once each). After the update D-Bus activation started the same service
  fine.
- Opt-outs: `LIBGL_ALWAYS_SOFTWARE=0` (Ghostty on virgl again: no window),
  any `MESA_LOADER_DRIVER_OVERRIDE` or `GALLIUM_DRIVER`; for one program
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`;
  for the VM, deleting `/etc/glvnd/egl_vendor.d/10_omacvm.json` (that also
  ends 0063's video sizes).
- Not covered, and not measured: UTM, VMware Fusion and Parallels VMs
  (other GL stacks), a Flatpak Ghostty (its own glvnd inside the sandbox).
  There `LIBGL_ALWAYS_SOFTWARE=1 ghostty` is the way, where Mesa's llvmpipe
  is installed.
- Zink again when (i) the QEMU abort above is fixed (done in 3.2.14, ADR
  0065) and (ii) KosmicKrisp has transform feedback and geometry shaders,
  so Zink gives a real 4.x core; then window, typing and cost rows
  and a soak, and never for the desktop or browsers without browser numbers.
- Tests: `src/app/guest/tests/egl-vendor.sh` (an exe named ghostty: Mesa's
  stand-in sees `=1` during its `eglInitialize` and nothing afterwards, also
  on a second call, when Mesa's call fails and from two threads at once; a
  variable set before is kept; foot and chromium get Mesa's own pointer),
  `src/tests/ghostty-check.sh` (the check line, also against the library
  built from source); the VM rows R1-R9 in the PR and the track.

## Amendment (3.2.18): Ghostty on the Mac's GPU, an experimental switch

Lane `ghostty-gpu` (work/tracks/ghostty-gpu.md: the investigation, the plan,
the architecture review, unit `ghostty-zink`).

### Context

Zink on KosmicKrisp still gives OpenGL 2.1 only (no transform feedback, no
geometry shaders at the pinned Mesa e5f0687; float64 is no limit, see
option 3). With `MESA_GL_VERSION_OVERRIDE=4.3` Zink claims 4.3 core, and
Ghostty 1.3.1 opens, draws and takes typing on the Mac's GPU, on the Mac
mini M4 and the MacBook Pro M1 Max (Apple7, new coverage), since 3.2.14 also
without ending QEMU (ADR 0065). Measured against llvmpipe (below), it types
about twice as fast and takes about a tenth of the CPU while output scrolls,
for some of the Mac's GPU and its graphics memory. The cost of a loss: when
the Mac ends a Venus context, that Ghostty stops drawing and answers no
input (Hyprland's "not responding", only Terminate), and the programs in it
end with it.

### Decision

- An app switch, `ghosttyGPU` (General, under the Vulkan rows; off; (i)). A
  start sends SMBIOS `omacvm.glzink=1` (host.env `OMACVM_GLZINK=1`) only with
  the switch on, no GPU safe mode, Venus at that start and KosmicKrisp as its
  Vulkan driver: one pure rule, `GhosttyGPU.start` (`OmacVMWindow`), with
  the driver as a typed value (`Graphics.vulkanDriverKind`). MoltenVK Macs
  (macOS 15) get no switch to turn: Zink does not start there. qemu.log
  `OmacVM: Ghostty on the Mac's GPU: on|off (why)` while the switch is on; the
  row says what the running VM's start did, as the HDR row.
- No probe service in the VM: the app knows Venus, the driver and that its
  runtime refuses instead of aborting; where Zink cannot start, Mesa falls
  back to llvmpipe by itself.
- The EGL library, in a process named `ghostty`: with the marker, no
  `/run/omacvm/gl-zink-off` (a Venus context lost in this boot; written by
  the lost-context work, absent = no effect) and none of the person's
  `LIBGL_ALWAYS_SOFTWARE`, `MESA_LOADER_DRIVER_OVERRIDE`, `GALLIUM_DRIVER`,
  `MESA_GL_VERSION_OVERRIDE`, its `eglInitialize` gets
  `MESA_LOADER_DRIVER_OVERRIDE=zink MESA_GL_VERSION_OVERRIDE=4.3` instead of
  `LIBGL_ALWAYS_SOFTWARE=1`, the same way (lock, gone after the call). Mesa
  reads the GL version override once per process, at its first display
  (`version.c`, a static), so 4.3 holds for every context. No GLSL override:
  under a GL override `_mesa_compute_version` skips the GLSL clamp, and
  Zink's own 460 stays (the rows draw without one).
- After Mesa's call the library asks it which driver it took
  (`eglGetDisplayDriverName`), writes one stderr line and
  `$XDG_RUNTIME_DIR/omacvm/ghostty-gl` ("PID ASKED GOT WHY"); `omacvm check`'s
  "Ghostty" line names zink or llvmpipe for a running Ghostty from it (only a
  live process named ghostty), and why.
- The bad fd. Under Zink, GTK 4.24 logged a CRITICAL (`fd > 0` failed) and a
  close of a bad descriptor about once a frame (646-901 lines per 10 s of
  scrolling in the investigation). Mesa's `dri2_export_dma_buf_image_mesa`
  (egl_dri2.c, 26.2.6) ignores a failed fd query and returns `EGL_TRUE`; on
  Zink over Venus (and on llvmpipe) that query fails, and GTK passes its fd
  array unset, so it made a texture of whatever was there. Measured with a
  stand-in that sets the array to 12345 first: Mesa answers yes and the 12345
  stays (Zink and llvmpipe, M4 and M1). GTK's own switch does not help:
  Ghostty sets `GDK_DISABLE` itself before GTK starts. So for a display set up
  on Zink in a Ghostty process, `eglQueryString(EGL_EXTENSIONS)` leaves out
  `EGL_MESA_image_dma_buf_export` and GTK never tries (told no instead, GTK
  logged "eglExportDMABUFImage failed" every frame), and
  `eglExportDMABUFImageMESA`, for apps that call it anyway (Ghostty 1.4),
  sets the fds to -1 first and says no when plane 0 got none.

### Measured

Hidden 4 GB test clones, Graphics Automatic (KosmicKrisp), Mesa 26.2.6, GTK
4.24.1, Ghostty 1.3.1 started as its desktop entry or by D-Bus (no variable
by hand), window 1896x1030 pixels, bench lock, median of 3; the 3.2.16 app
and library against this change with the switch on
(work/ghostty-gpu/ghostty-zink, `kit/summary.py`):

| | Mac mini M4 | MacBook Pro M1 Max (3 CI jobs on it) |
|---|---|---|
| typing shown, p50 / p90 | 55.6 / 62.6 ms -> 24.7 / 31.2 ms | 57.2 / 63.2 ms -> 28.2 / 37.1 ms |
| Ghostty CPU-s per 10 s of scrolling (guest total) | 32.8 (33.3) -> 3.3 (4.5) | 31.7 (32.6) -> 3.4 (4.7) |
| Ghostty CPU-s in the 10 s after it | 2.5 -> 0.2 | 2.6 -> 0.2 |
| QEMU on the Mac, CPU-s per scroll step (~26 s) | 44.9 -> 12.4 | 45.2 -> 12.4 |
| changed frames on the output per s | 37.2 -> 56.2 | 29.7 -> 57.5 |
| Mac GPU busy while scrolling | 0.6 % -> 8.8 % | 0 % -> 6 % |
| Ghostty's resident memory | 240 -> 141 MB | 240 -> 141 MB |

CRITICAL and export lines 0 in every row; qemu.log refused / lost /
assertion lines 0. Zink set by hand with one scroll run: 1330 (M1) and 1336
(mini) GTK CRITICAL lines with the 3.2.16 library, 0 and 0 with this one. A
30-minute soak on each Mac (output at 2,400 lines/s): alive, drawing in 29
of 30 samples, typing after, resident memory 140 -> 141 MB, 0 lines.
Omarchy's screensaver in Ghostty on two outputs at scale 2, whole-Mac power of the Mac mini in one session (180 s
windows; another app kept a core busy all along): no screensaver 34.6 / 35.9
W, in Ghostty on llvmpipe 53.1 / 53.8 W (guest 690 / 694 CPU-s), in foot 39.0
W, in Ghostty on Zink 40.0 / 41.0 W (guest 103 / 100 CPU-s, Mac GPU 44 %).
Browser first (Mac mini, bench lock, 3 runs each, Ghostty idle on another
workspace, Chromium 156 full screen): MotionMark 1.3.1 with one Ghostty
window 4287 (4143-4379) on llvmpipe, 4340 (4335-4383) on Zink, with three
4271 (3863-4279) and 4227 (4191-4238); Speedometer 3.1 33.1 / 33.4 and 32.8 /
33.3. Idle Zink windows cost nothing (60 s hidden or visible: Ghostty 0-0.4
CPU-s). The M1 Max's browser rows are left out: its three CI jobs moved
Speedometer between 7 and 23 on one boot with no Ghostty at all. Fallbacks, each its own start with the switch on: Graphics
OpenGL and `OMACVM_VULKAN_DRIVER=moltenvk` send no marker and Ghostty draws
on llvmpipe as before; with the switch off, the same. The programs Ghostty
starts get none of the variables (eglinfo from its shell: virgl 4.1).
Ghostty 1.4.0 (the build of unit `ghostty-14-cpu`) on Zink: window, drawing,
typing; its own dma-buf export is told no and it reads each frame back, as it
does on llvmpipe.

### Consequences

- A lost Venus context hangs that Ghostty (said in the (i)). This change
  only reads `/run/omacvm/gl-zink-off`: once the lost-context work writes it
  after such a loss, the next Ghostty of that boot starts on the CPU; without
  that work nothing writes it, and the next Ghostty starts on Zink again.
- The forced 4.3 claims transform feedback and geometry shaders KosmicKrisp
  lacks: a Ghostty version that uses them would be refused and land in that
  hang. Ghostty 1.3.1 and 1.4.0 use neither.
- Venus memory counts against the VM's graphics budget (ADR 0034) and the
  pressure guard does not cut it: a Ghostty on Zink takes 150-300 MB of the
  Mac's graphics memory (M1 Max: one window +155-163 MB, three windows of one
  Ghostty +164-278 MB; Mac mini: one window +171 MB; the investigation's
  separate processes 150-290 MB each). Past the budget its Venus context is lost: with a 384 MB budget and
  Chromium on WebGL Aquarium first, a Ghostty on Zink ended at its start
  ("venus context N (ghostty) is lost", the guest driver ended it); one on
  llvmpipe opened and took typing. Started with
  `VN_PERF=no_async_mem_alloc` it ended the same way, but those rows cannot
  show the variable reached it (it ended first); the same start passed it on
  at 1024 MB on the Mac mini, not on the M1 Max. The library does not set it.
- Not measured: M2 and M3 GPUs, MacBook Air (off limits during the lane).
- Default stays off. The soaks on both Macs and the 1.4.0 rows passed; on by
  default only after the lost-context work and the M1 Max's browser rows
  (left out above); without the override once KosmicKrisp has transform
  feedback (upstream MR 44928).
