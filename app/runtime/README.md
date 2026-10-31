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
  2.6 s, done at 3.56 s; also with macOS's Reduce motion on; the still logo
  only with `OMACVM_SPLASH_ANIMATION=0`). The logo holds over the firmware, GRUB and
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
- `patches/omacvm-cocoa-usb-menu.patch`: "USB Devices…" in the app menu,
  under "Features…", while the VM's USB switch is on (`OMACVM_USB_REQUEST`,
  set by the app). A click hands QEMU's activation to the app that set the
  name, then posts it; the app opens its list of USB devices over the VM
  (`USBRun.showList`). Without the variable the menu is unchanged.
  `Tests/display/test-usb-menu.sh` checks it at build time and in CI; with
  `--qemu` it presses the items of a hidden QEMU of a built runtime through
  Accessibility, with "Features…" as the control.
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
- `patches/virgl-sysval-block-check.patch`: a linked program whose VirglBlock
  (vrend's own uniform block) the GL reports smaller than vrend fills, or whose
  size query fails, is refused like a failed link: its draws are skipped. An
  assert there aborted QEMU once at desktop start, right after the Mac's GL had
  refused calls of the bar's context (#547). Checked by
  `Tests/virgl/test-sysval-block.c`
- `patches/virgl-query-results-init.patch`: the info log of a failed compile or
  link starts empty and a separable pipeline's validate status starts as valid, so
  a GL that refuses calls (and writes nothing) no longer puts stack bytes into
  qemu.log or stops the guest app's context with a false pipeline error. Checked
  by `Tests/virgl/test-sysval-block.c`
- `patches/virgl-query-result-unanswered.patch`: a query result the GL does not
  answer (a query never begun or still running, or a GL that refuses calls) reaches
  the guest as done with 0, logged once. vrend copied its unset stack variables
  into the guest's query buffer, or left the query "not ready" for ever. A query
  still waiting when its context is lost is done with 0 too (it was dropped
  unanswered). Checked by `Tests/virgl/test-query-result.c`
- `patches/virgl-shader-separable-pervertex.patch`: a shader of a separable
  program (an app's program pipeline) redeclares the gl_PerVertex blocks it
  writes and reads. Apple's GL links a separable shader only then, so every
  such pipeline was refused and its draws skipped (#567). Clip distance arrays
  go inside the block: one beside it crashed Apple's GLSL compiler. Checked by
  `Tests/virgl/test-separable-pervertex.c`
- `patches/virgl-pipeline-validate-log.patch`: a program pipeline the GL finds
  invalid at its first draw is logged (three lines per context) and kept; it
  ended the guest app's whole context. The check runs before the draw sets the
  sampler units (a 2D and a cube sampler then fail), and Apple's GL also fails
  it while the framebuffer is incomplete.
  `OMACVM_VIRGL_SHADER_FAILURES=lose` keeps upstream's context error. Checked
  by `Tests/virgl/test-separable-pervertex.c`
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
- `patches/qemu-darwin-surface-memory.patch`: QEMU keeps a display surface's
  pixels in plain memory, not in a temp file each (macOS has no memfd).
  Making and deleting those files ran with the BQL held at every display
  off/on and mode change, and waited on the disk while the Mac swapped (one
  close() 2.2 s). `OMACVM_SURFACE_MEMORY=file` keeps the temp files; qemu.log
  says which ("OmacVM: display surfaces: ..."). Only in a build without a
  D-Bus display (the runtime build checks config-host.h). Checked by
  `Tests/display/test-surface-memory.sh` (the patched functions, stand-ins
  for the file calls, a 2.2 s close()); `src/tests/surface-memory.sh` in CI
- `patches/virgl-control-queue-flush.patch`: vrend's own context is flushed
  after QEMU's resource create, unref and transfer-to-host commands; the
  guest's new screen, uploaded there on every mode change, stayed in GPU
  memory too (ADR 0018). Checked in a test VM by
  `tests/graphics/scanout-churn.sh`
- `patches/virgl-darwin-context-switch-flush.patch`: vrend flushes a GL
  context before it switches to another one (`vrend_sync_make_current`).
  `CGLSetCurrentContext` does not flush (EGL's and GLX's make-current do), and
  Apple's `glWaitSync` does not wait for a fence that was never flushed, so a
  Vulkan window's re-stride in the blitter's context reached Hyprland's draw
  one frame late (#499). Checked by `Tests/virgl/test-vulkan-window-handover.c`
  (GPU, both ways between the contexts; `OMACVM_TEST_BENCH=1` times the
  switches, not run by the build)
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
- `patches/virgl-gpu-guard-critical-grace.patch`: at critical memory
  pressure a new big resource has room when it fits in what macOS has left
  and the guest's GPU memory stays within what was in use when critical began
  plus a grace (a 32nd of the Mac's memory, 256 MB to 1 GB): an app that only
  replaces its buffers is never lost there (ADR 0034). Checked by
  `Tests/virgl/test-gpu-guard-policy.sh` (CI) and
  `Tests/virgl/test-resource-budget.c` (modes critical, critical-steady,
  levelfile)
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
- `patches/qemu-cocoa-gl-console-texture-lazy.patch`: a console's GL texture
  (QEMU's copy of its surface) is made when something draws it, on QEMU's
  thread: a 2D update, a present or the refresh tick without a GL scanout.
  While the guest shows a GL scanout nothing draws it, and the boot logo
  stands in for the placeholder, so most runs make none: QEMU's graphics
  88-181 MB lower per 5K output in hidden test VMs (M4, M1 Max), and no
  upload under the BQL at a display off or on. `OMACVM_CONSOLE_TEXTURE=eager` makes it at every switch,
  as before. Checked by `Tests/display/test-console-texture.sh` (the
  listeners from the patched `ui/cocoa.m` with a GL stub that counts the
  bytes uploaded; the code before fails it)
- `patches/omacvm-cocoa-present-volatile-logic.patch`,
  `omacvm-cocoa-present-volatile.patch`: after 2 s out of sight the window's
  spare present surfaces (all but the one Core Animation shows or reads) are
  volatile and leave QEMU's footprint (a 5K window on a locked M1 Max: 3 or 4
  of 5, 176-238 MB; 335-369 MB in half float); in sight again, or taken for a
  frame, they come back first, and
  one macOS emptied is drawn whole. `OMACVM_PRESENT_VOLATILE=0` keeps them;
  `OMACVM_TEST_PRESENT_PURGE=1` (tests) empties each one before it comes back.
  Checked by `Tests/display/test-present-volatile.sh` (the rules and the wiring)
- `patches/qemu-hvf-free-page-reclaim.patch` (try-omarchy): a range of guest
  memory Linux reports free (virtio-balloon free page reporting) gets fresh
  memory in its place (MAP_FIXED; Darwin's `MADV_DONTNEED` keeps what the
  guest wrote). `patches/qemu-hvf-free-page-reclaim-reusable.patch` (after
  `qemu-hvf-mapped-sections.patch`; both earlier patches stay as they are)
  moves the range's old pages aside under the main lock (`mach_vm_remap`,
  no page touched) and has a worker thread tell macOS they may go
  (`MADV_FREE_REUSABLE`, then unmap): macOS frees an anonymous object's
  pages only when the whole object goes, and guest RAM is a few 128 MB
  objects, so without it the old pages stayed resident or compressed, in no
  footprint, until QEMU quit. Now their compressed copies go at once and
  the resident ones are reusable: macOS takes them first, without
  compressing them (on a Mac with room they stay resident until then); only
  pages macOS is compressing at that very moment stay held. Nothing is
  advised under the main lock: a range the worker has no room for (4096
  queued) or that cannot move aside gets the old way, counted.
  `logs/qemu.log`: a line an hour while the guest reports and one at exit
  (reports, MB reported, the main lock's hold per report over all of
  `hvf_report_free_pages`: p99 and longest, MB not moved aside and why,
  what the worker released and what of it is still held on the Mac).
  `OMACVM_RECLAIM_REUSABLE=0`: the old way;
  `OMACVM_RECLAIM_CHECK=1` (tests): a line per report with what it left on
  the Mac. The worker's first line ("free page reclaim gives the pages back
  to macOS") is the text the app looks for in this binary to turn its
  give-back while macOS compresses on (`prepare-qemu-gpu-runtime.sh` checks
  it is there). When macOS keeps the pages anyway (a refused advice, or half
  or more of 64 MB still held after it), QEMU goes back to the old way for
  the run, says why in `logs/qemu.log` and writes "reclaim=keeps" into the
  file `OMACVM_RECLAIM_STATUS` names (the app then turns that give-back
  off). `Tests/memory/test-reclaim.sh` at build time (guest RAM shared like
  QEMU's, with a real `hv_vm_map` where the Mac lets the build make a VM;
  `--keeps`: a refused and a skipped advice; `--overflow`: the worker
  behind until its queue is full, no advice under the BQL) and in CI
  (`src/tests/memory-reclaim.sh`); ADR 0062
- `patches/qemu-hvf-own-view-sweep.patch` (after the reclaim patch):
  Activity Monitor counts guest RAM once. macOS charges a page once per
  mapping that touched it, so every guest page QEMU's own threads touched
  (disk, network, graphics) counted twice, compressed or not. A sweep remaps
  QEMU's view of the VM's main RAM over itself (`mach_vm_remap`, no copy,
  fixed over itself: the same objects, without QEMU's page table entries),
  128 MB at a time under the main lock, 20 ms apart; a pass a minute after
  the start, then every 5 minutes, skipped while QEMU's footprint grew less
  than 64 MB (twice in a row at most). No page moves; the Mac gets nothing back. Main RAM only, by the
  rule free page reports now share (`omacvm_ram_private`: never the Venus
  window's blobs, pflash, ROM, shared or file-backed memory). Before each
  remap every map entry must share its object with the guest (true shared
  or shared, an object, read-write, not wired), else the chunk stays as it
  is (counted); in the first pass a changed view stops QEMU; a failed remap
  stops the sweep for the run. `logs/qemu.log`: "own-view sweep: on" or
  "off" at the start (`omacvm check` reads it), a line an hour and one at
  exit (passes, MB less in Activity Monitor, the main lock's hold per
  chunk). `OMACVM_DCOUNT_SWEEP=0`: off; seconds there: the time between
  passes, and `OMACVM_DCOUNT_SWEEP_CHECK=1` a line per pass (tests).
  `Tests/memory/test-dcount.sh` at build time (no VM; a real `hv_vm_map`
  where the Mac lets the build make a VM; pread/pwrite and free page
  reports during a pass) and in CI (`src/tests/memory-dcount.sh`); ADR 0066
- `patches/mesa-kosmickrisp-*.patch`: changes to KosmicKrisp, applied by
  `build-kosmickrisp.sh` in name order (their hash is in its stamp).
  `mesa-kosmickrisp-shared-align.patch` declares a compute shader's shared
  memory 16-byte aligned; as a plain char array the MSL compiler made every
  access to it slow (WebGPU matmul in a VM on an M2: ~256 -> ~757 GFLOPS, MoltenVK ~895)
- `patches/virgl-test-shader-fault.patch`: test runtimes only
  (`OMACVM_RUNTIME_TEST_HOOKS=1 ./build-qemu-gpu-runtime.sh`): refuse shaders
  whose GLSL contains `OMACVM_VIRGL_TEST_FAIL_GLSL`. Such a runtime is marked
  (`.build/qemu-gpu-runtime.test-hooks`) and `build-app.sh` rebuilds instead of
  shipping it. `Tests/virgl/test-context-loss.c` runs in every build
- GLSL and limits that Apple's core profile accepts (one refused shader or GL
  error stopped the guest's whole GL context; the app drew black from then on):
  `patches/virgl-shader-core-glsl-version.patch` (GLSL 3.30, no extensions that
  are core), `virgl-shader-shadow-lod-extension.patch`,
  `virgl-shader-integer-outputs.patch`, `virgl-shader-sampler-swizzle.patch`
  (no swizzle on a sampler: Mesa's VA-API video compositor, Chrome's decoded
  frames; with it `virgl-const-buffer0-resource.patch`,
  `virgl-shader-array-sampler-2d-view.patch`,
  `virgl-view-swizzle-shared-texture.patch` and, for VideoToolbox's AV1 frames,
  `virgl-video-picture-size.patch`: docs/video-decode.md; decoding beside QEMU's GPU thread:
  `virgl-videotoolbox-decode-async.patch`, `Tests/virgl/test-video-decode-async.c`), `virgl-blitter-core-glsl-version.patch`,
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
