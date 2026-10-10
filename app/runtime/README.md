# Runtime

QEMU for OmacVM, built from source. The build scripts and patches come from
[try-omarchy](https://github.com/omacom/try-omarchy) (MIT, `LICENSE.try-omarchy`),
commit 82927e9. Changes here:

- scratch files go to `.build/tmp` instead of `/private/tmp` (macOS's temp folder when the
  checkout's path has a space: QEMU's configure refuses one)
- `patches/omacvm-cocoa-identity.patch`: the app name and icon come from the
  launcher (`OMACVM_PRODUCT_NAME`, `OMACVM_ICON`)
- the edk2 UEFI firmware is kept in `.build/firmware`, so an installed
  system boots through GRUB. `build-edk2.sh` builds it: the edk2 QEMU 11.1.1
  ships (edk2-stable202408, `roms/edk2-version`), with QEMU's own helper and
  flags (`roms/edk2-build.py`, `roms/edk2-build.config`, build
  `armvirt.aa64`, DEBUG as QEMU ships it), clang 18 instead of GCC, and
  `patches/edk2-logo-omarchy.patch`: Omarchy's logo instead of TianoCore's
  (made by `boot-logo/make-logo-bmp.py` from Omarchy's `logo.svg`, 10 pixels
  a cell, 810 x 190: as big as the app's start animation draws it; on a
  screen too small for it, the biggest whole cell that fits), and
  `patches/edk2-bootmanager-nvme-identify-align.patch`: with clang, edk2
  could not read the NVMe disk's name and renamed its boot entry to "UEFI
  Misc Device"; now it is "UEFI QEMU NVMe Ctrl omacvm 1" as with QEMU's
  firmware. `Tests/firmware/test-firmware.py` boots it with an empty disk
  and checks both: the logo on the screen and the disk's boot entry. If the
  build or that test fails, or with `OMACVM_FIRMWARE=qemu`, QEMU's prebuilt
  firmware is used (TianoCore logo);
  `.build/firmware/firmware-source` says which. It builds in
  `/private/tmp/omacvm-edk2-build` whatever the checkout: the DEBUG build
  carries its file paths, so every checkout gives the same bytes and the
  firmware carries no user name (the build checks that). The flash layout and the
  boot variables are the same either way: a VM's `efi-vars.fd` works with
  both
- `patches/omacvm-cocoa-boot-splash.patch`: when the window opens, OMACVM
  turns into Omarchy's logo (Core Animation: OMACVM 0.6 s, the morph about
  2.6 s, done at 3.56 s; the still logo with Reduce motion or
  `OMACVM_SPLASH_ANIMATION=0`). The logo holds over the firmware, GRUB and
  Linux's text until Omarchy's desktop is there (its display agent opens
  `org.omacvm.display`, or the picture is lit almost everywhere), then
  fades; also after a reboot. It gives way at once when the VM stops on an
  error, and after 40 s of running time without a desktop
  (`OMACVM_SPLASH_HOLD_SECONDS`). An output without a picture shows the logo
  instead of QEMU's "Display output is not active.", black once the desktop
  was there; after 90 s of the guest running with nothing of its own on the
  screen (`OMACVM_SPLASH_HINT_SECONDS`), a line under the logo names the VM's
  logs (`OMACVM_LOGS`) and qemu.log gets a warning. `OMACVM_BOOT_SPLASH=0`
  shows QEMU's text again. The cells are the firmware's
  (`boot-logo/make-logo-bmp.py logo.svg --rows`), the animation's table is
  `boot-logo/make-splash-morph.py`'s; the build checks both, the
  animation's core and its fade (`Tests/display/`, also `check-boot-splash.sh` in CI)
- `patches/omacvm-cocoa-fullscreen-own-space.patch`: full screen is always
  macOS's own, in a Space of its own on every display (beside a notch it sits
  below the camera; Omanotch fills the strip). The borderless kind of
  `omacvm-cocoa-notch.patch` is left for tests only.
  `patches/omacvm-cocoa-head-key-same-space.patch`: another display's window
  hands the keyboard back to the main window only while the main window's
  Space shows, so the escape combo's move to macOS is not undone.
  `Tests/display/test-fullscreen-space.sh` checks both in the patched
  `ui/cocoa.m` at build time.
- `patches/omacvm-cocoa-shutdown-events.patch`: once QEMU's thread has
  cleaned up the display (Quit, guest shutdown), AppKit events and blocks no
  longer reach QEMU (they crashed on the freed keyboard state).
  `patches/omacvm-cocoa-fullscreen-start.patch`: a VM that starts in full
  screen stays invisible until macOS has it there (no windowed frame, no
  menu bar over it). `Tests/display/test-shutdown-events.sh` and
  `test-fullscreen-start.sh` check them at build time.
- `patches/omacvm-cocoa-splash-after-reveal.patch`: the start animation
  (OMACVM becomes Omarchy's logo) starts its clock with the first frame of a
  window that shows, so a slow way into full screen ("Full screen including
  notch") no longer plays it while the window is still invisible.
  `Tests/display/test-splash-after-reveal.sh` checks it at build time and in CI.
- `patches/omacvm-cocoa-quit-clean.patch`: QEMU no longer quits when AppKit
  sees its last window go (a hidden full-screen test run quit after a minute
  when AppKit closed its full-screen mouse detection window); the close
  button, or the VM window closing any other way, still quits. A quit within
  2 minutes of the guest's start or reset presses the power button again
  every 10 s up to 40 s (a press while the guest boots is lost) and stops the
  guest at 70 s; a guest that is up gets one press and 60 s, as before
  (Omarchy's power menu opens on the key). qemu.log gets a line for each.
  `Tests/display/test-quit-clean.sh` checks it at build time.
- `patches/omacvm-cocoa-borderless-no-rim.patch`: a window switched to
  borderless (the tests' full screen over a display) has no shadow. macOS 26
  draws a light 1 pt rim with a window's shadow, and QEMU's window, titled
  first, kept its shadow, so a line ran around the whole display. Leaving
  that full screen gives the window its shadow back. macOS's own full screen
  never had it. `Tests/display/test-borderless-rim.sh` checks it at build
  time; `test-borderless-rim-live.sh` measures the pixels on macOS 26 or newer.
- `patches/virgl-texture-integer-samplers.patch`: shaders that read integer
  textures (`usampler2D`) compile on the Mac's OpenGL. Before, Apple's
  compiler refused them and the guest's GL context stopped for good: Chrome's
  GPU process hung (Basemark Web 3.0 at test 5). The build checks it with
  `Tests/virgl/test-integer-sampler-shader.c`, which compiles the generated
  GLSL with the Mac's OpenGL
- `patches/virgl-transfer-row-size.patch`: no texture transfer moves more
  bytes per row in GL than the guest's buffers hold. The YUYV plane format
  (R8G8_R8B8) moved twice as many, and its readback overflowed QEMU's heap:
  mpv's VA-API probe stopped the VM. That format is gone; the row check covers
  the others. Tested at build time by `Tests/virgl/test-transfer-row-size.c`

- `patches/virgl-shader-failure-skip-draws.patch`: a shader the Mac's OpenGL
  refuses (although the guest's Mesa accepted it) skips the draws that need it;
  the guest's context keeps running. `OMACVM_VIRGL_SHADER_FAILURES=lose` goes
  back to upstream (the whole context stops)
- `patches/virgl-context-loss-report.patch`: a context that is lost anyway tells
  the guest through a status buffer the guest's Mesa names
  (`src/app/guest/mesa/`), and the log says so once
- `patches/virgl-shader-variant-null-checks.patch`,
  `patches/virgl-shader-size-limits.patch`: a guest command stream could crash
  QEMU (NULL variant) or ask for 4 GiB per shader; found by
  `Tests/virgl/fuzz-cmd-stream.sh`
- `patches/virgl-core-instance-id.patch`: shaders that read `gl_InstanceID`
  (instanced WebGL) asked for `GL_ARB_draw_instanced`, which Apple's core
  profile refuses; checked by `Tests/virgl/test-integer-sampler-shader.c`
- `patches/virgl-transform-feedback-end.patch`: transform feedback ends with
  the program it began with bound; with none bound Apple's GL crashed QEMU
  (dEQP and WebGL 2 transform feedback tests); checked by
  `Tests/virgl/test-transform-feedback.c`
- `patches/virgl-stream-output-checks.patch`: a shader's stream output info
  (from the guest) could name a register past the translator's outputs: an
  assertion aborted QEMU; found by the fuzzer, replayed in every build
- `patches/virgl-gl-error-skip-command.patch`: a GL error after a guest
  command no longer stops the context (out of memory and a lost GL context
  still do); the GL ignored the failed call, the rest of the command ran
- `patches/virgl-buffer-binding-checks.patch`,
  `patches/virgl-draw-range-checks.patch`,
  `patches/virgl-uniform-buffer-checks.patch`,
  `patches/virgl-shader-index-clamp.patch`: the guest cannot make the Mac's GPU
  read or write outside a buffer (a GPU fault resets the GPU; on 2026-10-04 it
  panicked macOS). Buffer bindings, vertex, instance and index ranges,
  indirect commands and uniform blocks are checked before any GL call; a draw
  that fails is skipped; run-time shader array indexes are clamped (ADR 0017).
  Checked by `Tests/virgl/test-gpu-ranges.c`
- `patches/virgl-vertex-format-checks.patch`,
  `patches/virgl-uniform-buffer-alignment.patch`,
  `patches/virgl-uniform-block-array.patch`,
  `patches/virgl-draw-gl-error-check.patch`: a GL call the Mac's GL refuses
  keeps older state that the checks never saw. Vertex formats and buffer
  offsets the GL would refuse are refused first, uniform block arrays are
  named and bound as the shader declares them, and a GL error while a draw is
  set up skips the draw (ADR 0017). Checked by `Tests/virgl/test-gpu-ranges.c`
  cases 30-34 and `gl-oracle.c`
- `patches/virgl-vertex-unused-first-input.patch`: a vertex shader that does
  not read its first input no longer stops vrend from setting the other
  attributes; before, the draw kept the previous draw's attribute pointers
  without any GL error (ADR 0017). Checked by `Tests/virgl/test-gpu-ranges.c`
  case 35
- `patches/virgl-venus-robust-buffer-access.patch`: Venus devices always get
  robust buffer access where the host's Vulkan device offers it (MoltenVK
  does), whatever the guest asked for
- `patches/virgl-venus-lost-context-fences.patch`: a Venus context the render
  server ended signals its fences, so the guest app ends instead of hanging
- `patches/qemu-cocoa-gl-view-flush.patch`: QEMU's view context is flushed
  after surface texture work. Apple's GL kept every large surface texture
  made there until a flush that never came, so each guest mode change left a
  screen texture in GPU memory. Checked by `Tests/display/test-gl-view-flush.c`
  (software renderer; runs the patched `with_gl_view_ctx()` taken from
  `ui/cocoa.m`); `Tests/display/view-texture-churn.c` measures the GPU memory
  per switch by hand (GPU, capped, not run by the build)
- `patches/virgl-control-queue-flush.patch`: vrend's own context is flushed
  after QEMU's resource create, unref and transfer-to-host commands; the
  guest's new screen, uploaded there on every mode change, stayed in GPU
  memory too (ADR 0018). Checked in a test VM by
  `tests/graphics/scanout-churn.sh`
- `patches/virgl-resource-memory-budget.patch`: guest resources are charged
  their estimated size against a budget (`OMACVM_GPU_MEMORY_MB`, default
  three quarters of the Mac's memory, 0 = off: only a guard against a runaway
  VM, ADR 0034); past it, creation fails and the QEMU log says so (ADR 0018).
  Screens and cursors may go 256 MB past it. Checked by
  `Tests/virgl/test-resource-budget.c`
- `patches/virgl-darwin-memory-pressure.patch`: below that guard, a new big
  resource is refused only when macOS's memory pressure says the Mac is
  short; a status file (`OMACVM_GPU_MEMORY_STATUS`) for the app and
  `omacvm check` (ADR 0034). Checked by `Tests/virgl/test-resource-budget.c`
- `patches/virgl-gpu-guard-desktop-reserve.patch`: the guard's last part (a
  sixteenth of the Mac's memory, 512 MB to 2 GB) is kept for the VM's
  desktop (Hyprland, quickshell, hyprlock; `OMACVM_GPU_MEMORY_DESKTOP`,
  `OMACVM_GPU_MEMORY_RESERVE_MB`). A resource past the apps' share, or one
  macOS has no room for, is made "for the desktop only": the first GL
  context that attaches it keeps it if it is the desktop's, else that
  context is lost. The status file says why each context was lost (ADR 0034).
  Checked by `Tests/virgl/test-gpu-guard-policy.sh` (CI) and
  `Tests/virgl/test-resource-budget.c`
- `patches/virgl-gpu-guard-dropped-placeholder.patch`: the buffer a lost app
  made past its share gives its memory back but keeps an empty 1x1 stand-in,
  so Hyprland can still show it (the app may have handed it over already)
  and is not lost too. A refusal at the apps' share is logged as "apps' share
  of N MB reached", not as the whole budget. Checked by
  `Tests/virgl/test-resource-budget.c` (modes dropped, wording)
- `patches/qemu-virgl-2d-resource-scanout.patch`: QEMU makes 2D resources
  (the guest's dumb buffers: console, plymouth, dumb screens and cursors)
  with the SCANOUT bind, so the budget's screen reserve covers them; the
  build checks the patched source
- `patches/virgl-resource-budget-context-loss.patch`: a resource the budget
  refused loses the GL context that made it as soon as that context attaches
  it, and the QEMU log says why. A guest Mesa with
  `src/app/guest/mesa/mesa-virgl-reset-status.patch` is told
  (`GL_GUILTY_CONTEXT_RESET` for robust contexts; other apps end at their next
  flush). Stock guest Mesa has no channel for it: the app draws nothing.
  Checked by `Tests/virgl/test-resource-budget.c`
- `patches/virgl-venus-memory-budget.patch`: Venus device memory and shm blobs
  count against the same budget (one per VM); past it `vkAllocateMemory`
  fails with `VK_ERROR_OUT_OF_DEVICE_MEMORY` (guest Mesa allocates
  asynchronously by default: then the app ends at its next use of the memory).
  The charge goes with the storage: it lasts until the last holder is gone
  (the memory, memory imported from it, the guest's blob), so a kept dma-buf
  fd or mapping still counts. Checked by `Tests/virgl/test-venus-budget-storage.c`
- `patches/qemu-cocoa-idle-refresh.patch`: QEMU's refresh tick (every 8 ms on
  a 120 Hz display, for every output) slows to 500 ms after a second without
  work for it (2D updates, new scanouts, the extra outputs' windows) and comes
  back with the next. The main window's GL frames are pushed and never needed
  it, so an idle desktop (or a blinking cursor) no longer wakes QEMU 60-120
  times a second. `OMACVM_IDLE_REFRESH=0` keeps the display's rate. The build
  tests the rate logic, taken from the patched `ui/cocoa.m`
  (`Tests/display/test-idle-refresh.c`). Numbers: the idle-power PR
- `patches/virgl-test-shader-fault.patch`: test runtimes only
  (`OMACVM_RUNTIME_TEST_HOOKS=1 ./build-qemu-gpu-runtime.sh`): refuse shaders
  whose GLSL contains `OMACVM_VIRGL_TEST_FAIL_GLSL`. Such a runtime is marked
  (`.build/qemu-gpu-runtime.test-hooks`) and `build-app.sh` rebuilds instead of
  shipping it. `Tests/virgl/test-context-loss.c` runs in every build
- GLSL and limits that Apple's core profile accepts (one refused shader or GL
  error stopped the guest's whole GL context; the app drew black from then on):
  `patches/virgl-shader-core-glsl-version.patch` (GLSL 3.30, no extensions that
  are core), `virgl-shader-shadow-lod-extension.patch`,
  `virgl-shader-integer-outputs.patch`, `virgl-blitter-core-glsl-version.patch`,
  `virgl-blitter-integer-msaa.patch`, `virgl-framebuffer-no-attachments.patch`,
  `virgl-caps-sampler-limit.patch`. Checked at build time by
  `Tests/virgl/test-core-glsl-shaders.c`, `test-blitter-shaders.c`,
  `test-empty-framebuffer.c` and `test-sampler-limit.c` on the Mac's OpenGL
  (shared CGL setup: `Tests/virgl/cgl-context.h`)
  (docs/architecture/graphics.md, ADR 0019)

Every build also replays `Tests/virgl/fuzz-regressions/` (inputs that once
crashed QEMU, asked for 4 GiB or reached past a buffer) through the fuzz
harness without libFuzzer (`fuzz-replay-main.c`).

The virgl API tests and the fuzzer run on Apple's software renderer only
(`Tests/virgl/soft-gl.h`): invalid or random command streams must never reach
the GPU. `Tests/virgl/gl-oracle.c`, linked into the fuzzer, the replay and
`test-gpu-ranges`, checks every GL draw call's buffer ranges against the GL's
state and aborts on one that leaves a buffer.

Build: `./build-qemu-gpu-runtime.sh` (about 70 seconds, needs only the Command
Line Tools; the firmware about 2 minutes more the first time, then kept in
`.build/edk2`). Output: `.build/qemu-gpu-runtime` and `.build/firmware`.

QEMU is GPL-2.0. Anyone who gets a built app must also be able to get this
source and the patches.
