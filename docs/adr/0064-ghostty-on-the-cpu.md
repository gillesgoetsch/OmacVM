# 0064: Ghostty draws on Mesa's CPU renderer: it needs OpenGL 4.3, the VM's GPU gives 4.1

Status: accepted, built (`issue-598`, 3.2.14), always on in OmacVM.app VMs
for the program `ghostty` alone. Amends ADR 0063: OmacVM's EGL vendor
library gets a second job, and for that job it sets an environment variable
(0063 had none). Reported in #598 (@benoitdepaire). Notes, the
investigation and the review: work/tracks/issue-598-ghostty.md.

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
| Zink, 4.3 forced | 4.3 claimed | | | QEMU aborted, 4 of 4 starts |

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
   feedback (3.0) and no geometry shaders (3.2); it also lacks float64,
   which 4.0 needs. With a forced 4.3 every Ghostty start aborted QEMU, and so
   did one `MESA_LOADER_DRIVER_OVERRIDE=zink LIBGL_KOPPER_DISABLE=1 glxinfo -B`
   run as the desktop user: a Metal assertion in KosmicKrisp's
   `vkBindImageMemory2` for a linear image Metal takes as a 2D array
   (`mtl_new_texture_with_descriptor_linear`). The VM is gone at once.
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
  (`org.omarchy.screensaver`): it then runs on the CPU too while it shows.
  Without the change it opened no window at all. Off: Omarchy's
  `omarchy-toggle-screensaver`, `omacvm enable no-idle-lock`, or foot as
  the default terminal (foot draws on the CPU as well, by design).

## Cost

Ghostty on the CPU, against foot (Omarchy's default, CPU by design) and
Alacritty (GPU); 4-CPU VM, 10 s of output at 2,400 lines/s, then 10 s idle;
median of 3 (`work/issue-598/kit`, `kit2`):

| Window | Ghostty: scrolling 10 s / idle 10 s | foot | Alacritty |
|---|---|---|---|
| 1296x690 pixels at scale 1 (3.2.12 with `LIBGL_ALWAYS_SOFTWARE=1`; no bench lock) | 24.9 / 1.57 CPU-s | 1.47 / 0.02 | 0.72 / 0.03 |
| 1272x640 pixels at scale 2 (this change; bench lock) | 19.8 / 1.58 CPU-s | 0.82 / 0.03 | 0.60 / 0.03 |

So about 2 to 2.5 of the 4 vCPUs while output scrolls, and 0.16 of one in
the 10 s after it stopped (foot and Alacritty almost none). On the Mac, QEMU used 25.0
CPU-seconds per 26 s run with Ghostty against 5.5 with foot and 5.4 with
Alacritty; the Mac GPU's busy share stayed at 0-1 % in all three (a hidden
test window). A full-screen window on a large display has several times
these pixels: not measured, because the test Mac (Mac mini M4, its swap
nearly full) went to critical memory pressure with a 2560x1600 output. The
same for the screensaver in Ghostty with this change; on 3.2.12 it opened no
window on either of two outputs (guest 0.66 CPU-s in 20 s).

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
  none was left, since a Ghostty that fails on OpenGL exits, and
  `systemctl --user start` of the service failed there for another reason
  (systemd: "lacks handler for reload signal USR2", a start-up race of
  Ghostty 1.3.1; D-Bus activation started the same service fine after the
  update).
- Opt-outs: `LIBGL_ALWAYS_SOFTWARE=0` (Ghostty on virgl again: no window),
  any `MESA_LOADER_DRIVER_OVERRIDE` or `GALLIUM_DRIVER`; for one program
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`;
  for the VM, deleting `/etc/glvnd/egl_vendor.d/10_omacvm.json` (that also
  ends 0063's video sizes).
- Not covered, and not measured: UTM, VMware Fusion and Parallels VMs
  (other GL stacks), a Flatpak Ghostty (its own glvnd inside the sandbox).
  There `LIBGL_ALWAYS_SOFTWARE=1 ghostty` is the way, where Mesa's llvmpipe
  is installed.
- Zink again when (i) the QEMU abort above is fixed (its own lane) and (ii)
  KosmicKrisp has transform feedback, geometry shaders and float64, so Zink
  gives a real 4.x core; then window, typing and cost rows and a soak, and
  never for the desktop or browsers without browser numbers.
- Tests: `src/app/guest/tests/egl-vendor.sh` (an exe named ghostty: Mesa's
  stand-in sees `=1` during its `eglInitialize` and nothing afterwards, also
  on a second call, when Mesa's call fails and from two threads at once; a
  variable set before is kept; foot and chromium get Mesa's own pointer),
  `src/tests/ghostty-check.sh` (the check line, also against the library
  built from source); the VM rows R1-R9 in the PR and the track.
