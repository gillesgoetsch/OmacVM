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
  (made by `boot-logo/make-logo-bmp.py` from Omarchy's `logo.svg`), and
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
  their estimated size against a budget (`OMACVM_GPU_MEMORY_MB`, default a
  quarter of the Mac's memory, 0 = off); past it, creation fails and the
  QEMU log says so (ADR 0018). Screens and cursors may go 256 MB past it.
  Checked by `Tests/virgl/test-resource-budget.c`
- `patches/qemu-virgl-2d-resource-scanout.patch`: QEMU makes 2D resources
  (the guest's dumb buffers: console, plymouth, dumb screens and cursors)
  with the SCANOUT bind, so the budget's screen reserve covers them; the
  build checks the patched source
- `patches/virgl-test-shader-fault.patch`: test runtimes only
  (`OMACVM_RUNTIME_TEST_HOOKS=1 ./build-qemu-gpu-runtime.sh`): refuse shaders
  whose GLSL contains `OMACVM_VIRGL_TEST_FAIL_GLSL`. Such a runtime is marked
  (`.build/qemu-gpu-runtime.test-hooks`) and `build-app.sh` rebuilds instead of
  shipping it. `Tests/virgl/test-context-loss.c` runs in every build

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
