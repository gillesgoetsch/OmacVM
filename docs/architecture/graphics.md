# Graphics in OmacVM.app

How a frame (and a video frame) gets from an app in Omarchy to the Mac's
screen in OmacVM.app: the chain, the threads and locks, fences, who owns
which memory, the settings and fallbacks, what the guest may and may not
do, and how we test it. One document for every graphics track; each track
keeps its section current. Decisions with trade-offs are in
[../adr/](../adr/).

Status words used below:

- **shipped**: in `rc-2.6.0` (what users run).
- **built**: on a track branch, built and tested there, not merged yet.
  The branch is named.
- **planned**: designed, not written, or blocked.

The other routes (Parallels, UTM, Fusion) use their vendor's graphics stack;
this page is only about OmacVM.app's own QEMU.

## 1. The chain

### Today (shipped)

```
 app in the VM (Hyprland, Chrome, glmark2, ...)          GL / GLES
   |
 Mesa virgl driver (Gallium -> TGSI text)                guest user space
   |
 virtio-gpu kernel driver (DRM)                          guest kernel
   |   SUBMIT_3D, RESOURCE_*, fences, one ctrl queue
   v
 QEMU virtio-gpu-gl-pci  (hw/display/virtio-gpu-virgl.c) QEMU main loop, BQL
   |
 virglrenderer 1.3.0 + macOS patches (vrend)             same thread
   |   TGSI -> GLSL 4.1, state tracking
   v
 Apple OpenGL 4.1 core (CGL, runs on Metal)              one CGL context per guest context
   |
 scanout texture (borrowed by QEMU, no readback)
   |
 QEMU Cocoa display, gl=on: CAOpenGLLayer                AppKit main thread, takes the BQL
   v
 the VM window (one window, one output Virtual-1)
```

Hyprland renders the desktop through the same path: it is one more GL
client, and its output is the scanout the window shows.

QEMU is commit `c3d48b7` (11.1 line), virglrenderer 1.3.0 with the
patches from `startergo/homebrew-virglrenderer` 1.0.42 (MTLHeap export,
Apple GL fixes), then ours. All pinned by sha256 in
`app/runtime/build-qemu-gpu-runtime.sh`. ANGLE and libepoxy bottles are
linked for QEMU's EGL code; with `-display cocoa,gl=on` OmacVM.app renders
on CGL, not on ANGLE.

### Target design

```
 guest apps
   |                \                         \
 Mesa virgl (GL)    Mesa venus (Vulkan)       VA-API (Chrome, Firefox, mpv)
   |                 + Zink (GL on Vulkan)      Mesa virgl video
   |                  [planned, needs           |
   |                   KosmicKrisp]             |
   v                 v                          v
 virtio-gpu: ctrl queue, blob resources, hostmem window, 16 KiB blob alignment,
             up to 5 outputs (Virtual-1..5)
   |
 QEMU virtio-gpu-gl-pci (blob=true, venus=true, hostmem=<memory plan> when the Graphics setting gives Vulkan, ADR 0035)
   |  ctrl queue decoded on the main loop today; async (kick -> render
   |  thread) planned
   v
 virglrenderer
   +-- vrend (GL contexts)       -> Apple OpenGL 4.1 (CGL)
   +-- venus (render server as   -> Vulkan loader -> MoltenVK (macOS 15)
   |   a thread of QEMU)                           -> KosmicKrisp (macOS 26+)
   |                                                   -> Metal
   +-- video (virgl_video_vt.c)  -> VideoToolbox (the Mac's media engine)
   |                                -> IOSurface planes -> GL blit into the
   |                                   guest's textures
   +-- vrend-sync thread: fences signalled as the GPU finishes
   v
 scanout texture of each output
   |  blit on QEMU's thread into one of three IOSurfaces
   v
 CALayer.contents = IOSurface  (Core Animation composites it)
   |
 one window per Mac display in full screen, one window when windowed
```

| Piece | Status | Where |
|---|---|---|
| virgl GL on Apple OpenGL 4.1 | shipped | `virgl-native-opengl.patch`, tap patches |
| Scanout texture borrowing (no readback) | shipped | `qemu-texture-borrowing-11.1.patch` |
| Integer-sampler shader fix (Basemark hang) | shipped (2.6.0) | `virgl-texture-integer-samplers.patch` |
| Async fences (vrend-sync thread on macOS) | built: `gpu-native` | `qemu-cocoa-gl-async-fence.patch`, `virgl-darwin-thread-sync.patch` |
| Fence wait without a spinning core | built: `gpu-native` | `virgl-darwin-fence-wait.patch` |
| Fences polled when the sync thread cannot start | built: `gpu-native` | `virgl-thread-sync-fallback.patch` |
| Retire of other contexts' fences kept on context destroy | built: `gpu-native` (from `gpu-fence-hunt`) | `virgl-fence-waiting-ctx.patch` |
| GPU safe mode (the old fence and frame path) | built: `gpu-native`, hidden | `gpuSafeMode` default |
| Present on each flush | built: `gpu-native` | `qemu-cocoa-gl-present-on-flush.patch` |
| IOSurface present | built: `gpu-native` | `qemu-cocoa-gl-present-iosurface.patch` |
| Blob alignment for 16 KiB pages | built: `gpu-native`, `gpu-venus` | `qemu-virtio-gpu-blob-alignment.patch` |
| Venus on MoltenVK | built: `gpu-venus`, merged into `gpu-native`, hidden switch | see section 6 |
| KosmicKrisp on macOS 26 | built, in release builds (3.0.0, ADR 0035) | `virgl-darwin-vulkan-beside.patch` + `virgl-darwin-kosmickrisp-fallback.patch` |
| OpenCL (rusticl on Zink), WebGPU in Firefox and Chromium | built: `webgpu-compute`; feature `vulkan` (`gpu-next`, opt-in) | section 6, ADR 0022 |
| Zink as GL driver, ANGLE-on-Vulkan in Chrome | blocked on MoltenVK (GL 2.1, no `VK_EXT_provoking_vertex`) | - |
| VideoToolbox decode | built: `video-decode` | `virgl-videotoolbox-decode.patch` |
| One window per display | built: `app-displays` | `omacvm-cocoa-displays.patch` |
| Async ctrl queue (guest keeps encoding while the host runs) | planned | finding from `browser-gpu` |
| Guest scanout textures as IOSurfaces (zero copy present) | planned | ADR 0010 option 3 |
| Frames on the display's refresh (jitter buffer, display link thread) | built: `pacing-hdr` | `qemu-cocoa-gl-present-vsync.patch`, ADR 0020 |
| Colour-tagged frames, 10-bit scanout, HDR (PQ, EDR) | built: `pacing-hdr`, HDR off by default | `qemu-cocoa-gl-present-color.patch`, `src/app/guest/virtio-gpu/`, ADR 0021 |
| Guest paced by the host's vsync | planned | ADR 0020 option 1 |

## 2. Processes and threads

Everything runs in one process: QEMU (`qemu-system-aarch64`, hardened
runtime, started by the Swift launcher). There is no separate GPU process
and no render server process on macOS (ADR 0012).

```
 qemu-system-aarch64
 +-------------------------------------------------------------------------+
 | vCPU threads (HVF) x N                                                  |
 |   guest runs; a queue kick is an MMIO exit -> takes the BQL             |
 |                                                                         |
 | QEMU main loop  [BQL]                                                   |
 |   virtio-gpu ctrl + cursor queues, virglrenderer (vrend), all GL work,  |
 |   VideoToolbox decode calls, scanout -> IOSurface blit (built)          |
 |                                                                         |
 | vrend-sync      [no BQL, own CGL context]            (built: gpu-native)|
 |   tests each fence (spin 100 us, 50 us naps, 1 ms naps after 1 ms),     |
 |   wakes the main loop (fd); time-constraint thread (200 us budget)      |
 |                                                                         |
 | venus render server thread + vkr ring threads   (built: gpu-venus)      |
 |   [no BQL] decode the Venus ring, call Vulkan (MoltenVK)                |
 |                                                                         |
 | org.omacvm.present serial dispatch queue  [no BQL]  (built: gpu-native) |
 |   waits for an IOSurface's blit fence, hands it to the main thread      |
 |                                                                         |
 | VideoToolbox callback threads  [no BQL]             (built: video)      |
 |   receive decoded CVPixelBuffers                                        |
 |                                                                         |
 | AppKit main thread                                                      |
 |   windows, input, sets layer.contents; takes the BQL for input and,     |
 |   in the shipped CAOpenGLLayer path, for drawing                        |
 +-------------------------------------------------------------------------+
 VTDecoderXPCService (macOS process): the actual hardware decode
```

Rules:

- All vrend GL calls happen on the main loop, with the BQL. virglrenderer
  is not thread safe for vrend contexts; nothing else may call into it
  except the callbacks it documents (fence retire, `write_fence`).
- `vrend-sync` has its own CGL context shared with vrend's, only waits on
  sync objects, and never touches guest-visible state. It signals by writing
  one byte to an fd; the main loop reads it and retires fences there.
- The present queue and the main thread never take the BQL to draw
  (IOSurface path). The CAOpenGLLayer fallback does: the main thread draws
  inside `drawInCGLContext` holding the BQL.
- Venus threads do not take the BQL; they talk to the main loop only
  through the proxy's fence fd and resource callbacks.
- Head windows (one per extra display) share the main view's GL context
  (`gl_view_ctx`); all their drawing happens under the same rules.

Rule for new code: where both are needed, take the BQL first, then any
virglrenderer internal mutex. Never wait for the BQL from a Core Animation
callback in a new path (the shipped `drawInCGLContext` does, and that is
why the main thread and QEMU waited on each other every frame).

## 3. A frame, step by step

1. The app draws; Mesa encodes commands into a command buffer (256 KiB).
   When it is full or the app flushes, the kernel sends `SUBMIT_3D` with a
   fence.
2. The vCPU kicks the ctrl queue. HVF has no ioeventfd, so the kick is an
   MMIO exit and the vCPU waits there while QEMU's main loop decodes the
   **whole** queue (`virtio_gpu_process_cmdq`). Chrome's GPU process spends
   about a third of its time in this kick (`browser-gpu` perf).
3. vrend turns TGSI into GLSL (cached per shader) and makes the GL calls on
   Apple's OpenGL. Apple's per-draw cost (state revalidation) dominates
   draw-call heavy WebGL (Aquarium 30k fish, about 34 submits per frame).
4. The fence: a `glFenceSync` is placed after the submit.
   - shipped: a 1 ms QEMU timer polls fences (`qemu-darwin-gpu-fence-poll.patch`).
     Median fence-to-reply 1.56 ms, so light scenes cap near 1000 frames/s.
   - built: `vrend-sync` waits and reports at once: median 199 us.
     It tests the fence instead of calling Apple's spinning
     `glClientWaitSync` (see section 4).
5. Hyprland composites and page-flips; virtio-gpu sends
   `RESOURCE_FLUSH`/`SET_SCANOUT`. QEMU borrows the scanout texture (no
   readback).
6. Present:
   - shipped: the view is marked dirty; Cocoa redraws on QEMU's GUI refresh
     tick (30 ms): by the code at most 33 redraws a second. (Inside the guest
     a page still runs at 120, so testufo reports 120; what reaches the panel
     is measured on `pacing-hdr`.)
   - built: each flush asks for a redraw; QEMU's thread blits the scanout
     into one of three IOSurfaces, the present queue waits for that blit
     (testing its fence, not with Apple's spinning wait), the main thread
     sets `layer.contents`. At most one surface per display refresh; a
     surface is reused only when `IOSurfaceIsInUse` is false. The surfaces
     are never larger than the largest display and are made again at most
     twice a second (a larger or quickly changing scanout is drawn scaled).
7. Core Animation composites the surface into the window.

## 4. Fences

| Kind | Who creates it | Who signals | Path today |
|---|---|---|---|
| virgl context fence (GL) | guest `SUBMIT_3D` + fence flag | vrend: `glClientWaitSync` done | shipped: 1 ms poll; built: `vrend-sync` |
| Venus fence | guest ring + `SUBMIT_3D` | render server thread writes the proxy's fence fd | built: needs the fd to be writable (see below) |
| Present fence | QEMU's IOSurface blit | GL sync, waited on the present queue | built |
| Video decode | VideoToolbox callback | buffer kept until the GPU copy is done (last 3 retained) | built |

macOS has no `eventfd`. `virgl-darwin-thread-sync.patch` uses an unlinked
FIFO opened read-write: one fd that can be written and read, also after
`dup` or when passed over the proxy socket. A pipe did not work: Venus's
server writes the fd it was given, and a pipe's read end cannot be written,
so Venus fences never retired (found by `gpu-venus`, fixed in `gpu-native`
`9b176fa`).

The soak "hang" of 2026-10-04 morning was not a fence bug: another track's
benchmark had stopped every test QEMU with `SIGSTOP` (the bench lock
protocol). `gpu-fence-hunt` confirmed it and ran 12.9 million fences on the
host without a VM, none over 20 ms; it also found an upstream bug kept as
`virgl-fence-waiting-ctx.patch` (destroying one context dropped the retire
of a fence of another context the sync thread was waiting on). Soaks since:
30 min glmark2 (async fences + IOSurface), 33 min of glmark2 on the final
runtime, and `conformance-runs`' 30 min glmark2 + WebGL + video soak, all
without a stuck fence.

If the sync thread cannot start (no shared CGL context, no FIFO in
`$TMPDIR`, no thread), virglrenderer polls the fences on the render thread
and has no poll fd (`virgl-thread-sync-fallback.patch`); QEMU's 1 ms timer
then retires them, and `qemu.log` says "virgl fences polled every 1 ms (the
sync thread did not start)". Before, the guest's GPU waited forever while
the log named the new path.

Cost of async fences: Apple's `glClientWaitSync` spins (`gleTestSync`).
`virgl-darwin-fence-wait.patch` tests the fence instead: busy for up to
100 us after the thread last slept, then 50 us waits with `mach_wait_until` on a time-constraint thread (plain
`nanosleep` is stretched by timer coalescing: Aquarium fell to 7-15 fps
with it). After 1 ms of waiting the wait doubles up to 1 ms, so a long or
stuck GPU job wakes the thread about 1000 times a second, not 20,000. The
thread's budget per wake (200 us) covers the spin, also when fences finish
back to back (the spin counts from the last sleep, not per fence). With the bench lock:
QEMU's CPU during glmark2 195% -> 165%, Aquarium 194% -> 176%, frame rates
the same (ADR 0017).

Fence tests and the render thread (`virgl-darwin-fence-wait-busy.patch`,
ADR 0026): every `glClientWaitSync` takes Apple GL's share-group lock, which
the render thread's GL calls take too, and a collision parks the render
thread in the kernel. Where the render thread is the bottleneck (WebGL
Aquarium) the sync thread's back-to-back tests after each new fence cost
about 5 %. So while the render thread runs a guest command buffer,
`vrend-sync` waits for the end of the submit (the render thread wakes it,
at most 1 ms) instead of testing on a timer; an idle render thread gets the
spin and naps above. `OMACVM_VIRGL_FENCE_BUSY=0` turns it off. Bench lock,
2.8.0 / 2.9.0 / this part alone: Aquarium 20.2 / 19.0 / 20.15-20.6 fps
(one session for the last); with the present queue's backoff too (not
shipped, ADR 0026) 19.9 fps, glmark2 short set 1160 / 2986 / 3168, testufo
unchanged.

Program binds (`virgl-use-program-cache.patch`): vrend called `glUseProgram`
before every draw, also when that program was already bound, and Apple's GL
rebuilds its draw state after each one. WebGL Aquarium makes one draw per
fish, so it paid that about 590,000 times a second. vrend now remembers the
bound program per sub context (one GL context each) and skips the repeat.
Deleting a program or pipeline, the GL blitter, and binds from paths that do
not know their sub context (transfers, read-back) drop what it remembers.
`bench-program-binds` (vrend through its API, one draw with new constants
per object, mini, no lock): 0.83 -> 0.64 us per draw. In a VM, the same
runtime with the cache off and on: Aquarium 30k fish 20.85 -> 25.45 fps
(MacBook Pro M4 Max) and 19.65 -> 24.2 fps (Mac mini M4, macOS 27);
Basemark the same within its noise; WebGL 1 and 2 conformance identical.
`OMACVM_VIRGL_PROGRAM_CACHE=0` binds on every draw again. Test:
`test-program-binds`.

Vertex binds (`virgl-legacy-vertex-cache.patch`): Apple's GL 4.1 has no
`ARB_vertex_attrib_binding`, so vrend takes its legacy vertex path, which never
cleared `vbo_dirty`. Every draw therefore selected the shaders again (three
shader key fills and compares) and sent `glBindBuffer`,
`glVertexAttrib*Pointer` and `glVertexAttribDivisor` for every attribute and
`glBindBuffer(GL_ELEMENT_ARRAY_BUFFER)`; Apple's GL then rebuilt its vertex
state in the draw. Now the legacy path clears `vbo_dirty` like the GL 4.3 path,
and each sub context (one VAO each) records its last vertex setup: program,
vertex elements, and each element's buffer name, stride and offset. A draw with
the same setup skips the calls, and the element buffer is bound only when it
changes. An attribute with stride 0 (its value is read from the buffer) is
never skipped. `vrend_vertex_state_gen` drops every record when the VAO may
have changed outside a draw: an index buffer bound to its own target (transfer,
map, create), a buffer deleted (its GL name can come back), vertex elements
freed, a video command; a draw the GL refused keeps no record. A static check
in `run-regressions.py` fails the build when a GL call that changes VAO state
or frees a buffer is in a function that does not tell the cache and is not
reviewed. The selects on every draw had hidden missing dirty flags, now set:
unbinding the vertex elements or the rasterizer, a framebuffer change that
stops half way, and a sampler view slot whose shader key bits (emulated
rectangle, buffer swizzle) change. `OMACVM_VIRGL_SELECT_CACHE=0` selects on
every draw again, `OMACVM_VIRGL_VERTEX_CACHE=0` sets the attributes and index
buffer on every draw again (both 0: the GL calls of before);
`OMACVM_VIRGL_CACHE_STATS=1` logs draws, selects and skips every 10 s. Test:
`test-vertex-binds` (run as is and with each switch at 0).

### Where the time goes

- Light frames (glmark2, the desktop): the fence round trip. Fixed above.
- A faster poll timer is no way around it: QEMU's main loop on macOS has no
  `ppoll` and waits in whole milliseconds (50 us and 20 us timers gave the
  same ~1100-1200 as 1 ms).
- Heavy browser frames (WebGL Aquarium, 30,000 fish): QEMU's main loop is
  busy all the time, about 60% of it inside Apple's OpenGL (pipeline-state
  lookups and texture validation for every draw), about 14% in the kernel
  (main-loop polls, user network, the BQL), only about 9% in virglrenderer.
  Faster fences do not change Aquarium (about 21 fps before and after).
  A render thread away from the main loop might give 10%; the large step is
  to stop going through Apple's OpenGL (Venus + Zink on KosmicKrisp).
- Not levers: ANGLE on Metal as the host GL (`gl=es`): the guest gets only
  OpenGL 2.1 and glmark2 drops to about 700.

## 4a. Shaders and limits on Apple's GL (built: `gl-compat`)

virglrenderer was written for Linux drivers. Where Apple's OpenGL 4.1 core profile
disagrees, one refused shader or one GL error used to put the guest's whole virgl
context in error (`vrend_report_context_error`): everything that app drew later was
black, and the guest was never told. Fixed in the translation and the caps (ADR 0019),
one patch each, each with a build-time test that compiles or runs on the Mac's GL:

| Gap on the Mac | Patch | Test (`app/runtime/Tests/virgl`) |
|---|---|---|
| floatBitsToInt() etc. need GLSL 3.30; `GL_ARB_draw_instanced` refused (one table: extension → GLSL version where it is core) | `virgl-shader-core-glsl-version.patch` | `test-core-glsl-shaders.c` |
| `GL_EXT_texture_shadow_lod` asked for core lookups (gradients, cube shadow bias, gather) | `virgl-shader-shadow-lod-extension.patch` | `test-core-glsl-shaders.c` |
| results written to an integer output lost their bits or did not compile (upstream bug) | `virgl-shader-integer-outputs.patch` (integer outputs written like a float temporary, stored once with their bits) | `test-core-glsl-shaders.c` |
| blitter shaders were GLSL 1.30: every shader blit drew nothing | `virgl-blitter-core-glsl-version.patch` | `test-blitter-shaders.c` |
| integer multisample blit used texture() on a MS sampler (upstream bug) | `virgl-blitter-integer-msaa.patch` | `test-blitter-shaders.c` |
| framebuffer without attachments (all draw buffers GL_NONE): GL error on draw | `virgl-framebuffer-no-attachments.patch` (depth stand-in as large as the first viewport, at most 8192², kept between switches, freed when unused; depth test off while it is attached) | `test-empty-framebuffer.c` |
| guest told 32 samplers per stage, the Mac has 16 | `virgl-caps-sampler-limit.patch` (smallest limit of all stages) | `test-sampler-limit.c` |

The patches apply after gpu-native's and only touch `vrend_shader.c`,
`vrend_blitter.[ch]` and `vrend_renderer.c` (framebuffer state, caps).
`virgl-shader-core-glsl-version.patch` covers gpu-robust's `virgl-core-instance-id.patch`
(same loop in `emit_header`); both apply in either order, drop that one when both land.
gpu-robust's containment (refused shader skips its draws) is the safety net for gaps
not found yet.

Measured with tests/graphics (branch conformance-runs; VK-GL-CTS vulkan-cts-1.4.6.2,
WebGL conformance 1.0.4 and 2.0.0, Chrome 154; transform feedback left out, see
gpu-robust). "One process" = one dEQP process for the whole list, one Chrome for every
page, as apps run; "isolated" = restarted after every failure. Before = gpu-native's
runtime with gpu-hang's integer sampler fix (conformance-runs' gn-v4h); after = this
branch at 6140dc5. Correctness runs, no bench lock.

| Suite | before, one process | before, isolated | after, one process | after, isolated |
|---|---|---|---|---|
| dEQP-GLES2, every 20th case (859) | 853 | 853 | 853 | 853 |
| dEQP-GLES3, every 50th case (869) | 455 of 896 (with TF, 12 QEMU crashes) | 812 + 24 QW | 855 + 3 QW | 855 + 3 QW |
| WebGL 1 pages (787) | 430 | 776 | 776 | 776 |
| WebGL 2 pages (967 without TF) | 97 of 970 | 960 of 970 | 959 | 959 |
| dEQP-GLES2, whole list (17165) | 16971 | | 16972 | 16972 |
| dEQP-GLES3, whole list (43448) | 21140 + 1116 QW | | 42837 + 104 QW | 42835 + 104 QW |

After the patches the one-process numbers equal the isolated ones, case by case (the
three flush_finish cases pass or give a compatibility warning depending on timing). Against
the isolated "before" no case got worse; 22 dEQP-GLES3 cases (stride) and WebGL 2
`rendering/draw-buffers.html` pass now. The QEMU log of the one-process runs has no
context error. What still fails fails in both modes: cube map filtering, one blit
format conversion (rgb8 to rg32f), 11 WebGL 1 and 8 WebGL 2 pages, and the
transform feedback crash that gpu-robust fixes
(`lifetime.attach.deleted_output.buffer_transform_feedback`).

A 30-minute soak on the same runtime (glmark2, Chrome on a WebGL page and mpv playing
1080p at once) passed: no hang, no missed heartbeat, 6.1 million fences, no new QEMU
log line, QEMU memory 5.5 GB at the start and 4.5 GB at the end (5.7 GB peak).

## 5. Memory ownership

| Memory | Owner | Lifetime | Guest sees |
|---|---|---|---|
| Guest RAM | QEMU (HVF mapping, 16 KiB pages) | VM | itself |
| Classic resources (non-blob) | guest pages as backing + a host GL texture/buffer owned by vrend | until `RESOURCE_UNREF` | its own backing pages; transfers copy |
| Scanout texture | vrend; QEMU only borrows it per frame | until the guest replaces the scanout | nothing extra |
| Present IOSurfaces (3 per window) | QEMU Cocoa code | window; reused when not in use by Core Animation | nothing |
| Blob resources, host-visible (Venus) | MoltenVK `MTLHeap` in QEMU's process | until unref; mapped into the hostmem BAR | a window in the hostmem PCI BAR (4 GiB of address space, costs no RAM until used) |
| VideoToolbox pixel buffers | VideoToolbox pool; we retain the last 3 | until the GPU copy into the guest texture is done | never; copied into the guest's plane textures |

Rules:

- The guest never gets a host pointer. Blob memory reaches it only as a
  mapping inside QEMU's hostmem region, at an offset QEMU chooses.
- HVF maps in 16 KiB pages and macOS 15 has no 4 KiB IPA granule
  (`hv_vm_config_set_ipa_granule` is macOS 26). QEMU offers
  `VIRTIO_GPU_F_BLOB_ALIGNMENT` with the host page size and refuses a blob
  that the renderer maps on part of a host page
  (`qemu-virtio-gpu-blob-alignment.patch`): mapping the rest of that page
  would hand the guest memory the renderer may not own. Venus allocates its
  Metal-exported memory in whole host pages, so its blobs pass. Guest Mesa must
  round blob sizes: Mesa 26.2.4 and later do, Arch Linux ARM's 26.2.3 does
  not (Venus fails with `EINVAL`).
- QEMU 11 mapped blobs with `mmap(MAP_FIXED)` into hostmem; HVF keeps the
  pages it got from `hv_vm_map`, so the guest saw stale memory.
  `qemu-hvf-virgl-blob-subregion.patch` maps a memory subregion instead.
- Metal heaps are pointers in one process, which is why the Venus server
  runs in process (ADR 0012).
- Classic resources count against a budget (all levels, layers and
  samples; `virgl-resource-memory-budget.patch`): three quarters of the
  Mac's memory, so only a runaway VM reaches it (ADR 0034). Below it,
  `virgl-darwin-memory-pressure.patch` follows macOS's memory pressure (a
  dispatch source; its handler only stores the level, the renderer thread
  acts in `virgl_renderer_poll` and also reads the level once a second,
  because macOS tells only some processes about a warning): big new resources (16 MB+, not screens or
  cursors) are refused only at "critical", or at "warn" when they are bigger
  than all macOS has left, after a glFinish and three more looks. It writes
  `logs/gpu-memory` for the app and `omacvm check`. A desktop takes
  1.1 GB at 4K to 3.1 GB at 8K, up to 6.2 GB for a moment while the scale
  changes (every screen-sized buffer is made again). QEMU's log notes each
  new peak in 512 MB steps. The budget's last part (512 MB to 2 GB) is the
  desktop's (`virgl-gpu-guard-desktop-reserve.patch`): the guest's kernel
  makes a resource before it names its context, so one past the apps'
  share (or one macOS has no room for) is made for the desktop only and the
  first GL context that attaches it decides: Hyprland, quickshell or hyprlock keep
  it, an app's context is lost. Venus memory is an app's. The lost app's buffer
  keeps an empty 1x1 stand-in (`virgl-gpu-guard-dropped-placeholder.patch`):
  if the app already handed it to Hyprland, Hyprland still finds it and shows
  an empty window instead of losing its own context.

## 6. Vulkan: Venus (built: `gpu-venus`)

```
 guest Vulkan app -> Mesa venus (vulkan-virtio) -> virtio-gpu ring in a blob
   -> QEMU -> virglrenderer proxy -> render server THREAD (in process)
   -> vkr (venus renderer) -> libvulkan.1.dylib (in the runtime)
   -> ICD: MoltenVK 1.4.2 (macOS 15) | KosmicKrisp (macOS 26+, release builds)
   -> Metal
```

Patches (all in `app/runtime/patches`, one per concern):

- `virgl-darwin-venus-in-process.patch` + `-Drender-server-worker=thread`
- `virgl-darwin-stream-sockets.patch`: macOS has no `AF_UNIX SOCK_SEQPACKET`;
  stream sockets with fixed framing.
- `virgl-darwin-vulkan-beside.patch`: load the loader beside
  libvirglrenderer, pick the ICD by macOS version, `MVK_CONFIG_USE_MTLHEAP=1`.
- `virgl-darwin-venus-heap-check.patch`: a NULL heap fails cleanly (QEMU
  crashed in `CFRetain`).
- `virgl-darwin-venus-ext-table.patch`: a tap patch shifted the extension
  table by one entry.
- `virgl-darwin-venus-host-pages.patch`: Metal-exported memory in whole host
  pages (it was 4 KiB-aligned), so every blob the guest maps is the
  allocation's own memory.
- `qemu-hvf-virgl-blob-subregion.patch`, `qemu-virtio-gpu-blob-alignment.patch`.
- `virgl-set-type-without-egl.patch`: Vulkan windows. Hyprland imports a
  Venus image (a Metal heap) as a dma-buf (`PIPE_RESOURCE_SET_TYPE` in its
  virgl context). macOS OpenGL cannot import it, and the old EINVAL ended
  Hyprland's whole context (black desktop). Now the resource gets a plain GL
  texture, filled from the heap when a draw samples it (Metal blit into a
  shared buffer, then `glTexSubImage2D`, once per command buffer); memory
  that cannot be read leaves it blank. The app says so at start (OEM string
  `omacvm.vkwindows=1`, with MoltenVK and with KosmicKrisp since 3.0.1:
  KosmicKrisp's heaps are shared memory, so the texture is filled straight
  from them, without the blit); the guest then keeps Mesa's normal WSI,
  otherwise (older app) it sets `MESA_VK_WSI_DEBUG=sw` (`omacvm-vulkan-present`).

Switch: the VM's Graphics setting (ADR 0035; up to 2.9 the hidden `venus`
default, moved into it at the first 3.0.0 launch) adds
`blob=true,venus=true,hostmem=<n>M` to the GPU device, once the VM has a
Venus driver with blob rounding (`venus-ready`). Automatic is OpenGL in 3.0.0.
That driver is OmacVM's build of the distro's `vulkan-virtio` (Mesa 26.2.4
with `mesa-venus-opaque-fd-semaphores.patch`, version `26.2.4.omacvm1`:
it sorts after Arch's 26.2.4-x and before 26.2.5), so Chrome's WebGPU works
with the setting alone, through the `omacvm-chromium-webgpu` launcher
(`venus/webgpu.sh`; next section for why Chrome needs both).

M1/M2: macOS gives their VMs 36 address bits (64 GB), and QEMU's high PCI
window (512 GB at 512 GB) does not fit. Every BAR then shares the 751 MB
window below 1 GB, where a 1 GB host memory window never fits and the
firmware maps no device at all (3.0.0: a Vulkan start there never boots).
From 3.0.1 the app adds `highmem-mmio-size=<n>G` to the machine there
(`Graphics.highWindowGB`, 16 GB at most) and
`qemu-virt-small-high-window.patch` puts that window right above RAM; the
host memory window takes at most half of it (M2 Air, 4 GB VM: 1 GB in
16-32 GB). If no window fits (a VM near 64 GB), or the app's QEMU lacks the
patch (the app looks for the patch's error text in the binary), it is
256 MB, which fits below 1 GB.

A start with Vulkan is watched for 3 minutes (`VenusStartWatch`). No PCI
BAR mapped 25 s after QMP first answered (the firmware found no devices),
or QMP silent before that: the app stops QEMU (SIGTERM, SIGKILL after 5 s)
and starts the VM on OpenGL, and keeps OpenGL (`graphics-fallback`) until
Vulkan is chosen again: that failure repeats on every start on this Mac.
The window's "no picture" line, or QEMU exiting with an error within 15 s:
OpenGL for that start only, the next start tries Vulkan again. No picture
after the firmware ran falls back only on Macs under 40 bits (M1/M2); on M3
and newer it is only logged, so a slow boot never gets the power button.
QMP silent after the firmware ran is only logged. The app deletes
`logs/console.log` before QEMU starts (QEMU empties it only when it opens
it), so the last boot's text never counts as "the firmware ran". A Shut
Down or Force Stop from the app ends the watch: no OpenGL start follows.
qemu.log of the failed start stays as `logs/qemu-vulkan-fallback.log`;
`omacvm check` warns on the Graphics row.

Limits: MoltenVK has no `nullDescriptor`, no geometry shaders, no logicOp,
no float64, no `VK_EXT_provoking_vertex`. So Zink as a GL driver and
ANGLE-on-Vulkan in Chrome do not work; they wait for KosmicKrisp, which
needs Metal 4 (macOS 26). See ADR 0013. Zink for compute (rusticl) works
with patches: next section, ADR 0022. With fences polled every 1 ms each
vkmark frame waited about 1.3 ms: vkmark ~730-800 was latency, not GPU.
With the sync thread's fences (`gpu-native`) the same runtime gives about
5,200 (bench lock, 800x600 headless, median of 3: 5195 vs 732 polled).

### WebGPU and OpenCL on Venus (built: `webgpu-compute`)

```
 Firefox (WebGPU, wgpu)   Chromium (WebGPU, Dawn)     OpenCL app (Geekbench, ffmpeg, clpeak)
        |                 launcher: Skia Graphite          |
        |                 on Dawn-Vulkan, X11         rusticl (Mesa OpenCL 3.0) -> Zink
        |                        |                         |
 /opt/omacvm-mesa: Mesa 26.2.4 venus + zink + rusticl with OmacVM's patches, built in the guest
        \________________________|_________________________/
                                 |  Venus ring, as in the chain above
                                 v
                    vkr -> MoltenVK -> Metal
```

- The feature `vulkan` (`omacvm enable vulkan --vm NAME`, off by default,
  experimental): apply writes the VM folder's `vulkan` file, and the app
  starts that VM with `blob=true,venus=true,hostmem=4G`; the guest install
  runs `src/app/guest/venus/install.sh --force` (`--remove` when the
  feature goes off). Run by hand without `--force` the script does nothing
  without Venus (it reads the capset count and the host visible region
  from virtio-gpu's debugfs). It builds the pinned Mesa once (stamp: version + patch hash), registers
  `/etc/vulkan/icd.d/omacvm_venus_icd.json` and
  `/etc/OpenCL/vendors/omacvm-rusticl.icd`, writes
  `/etc/environment.d/90-omacvm-venus.conf` (`RUSTICL_ENABLE=zink`,
  `VK_LOADER_DRIVERS_DISABLE=virtio_icd.json`: the distro's venus, Mesa
  26.2.3, fails on 16 KiB blob pages), Firefox's `dom.webgpu.enabled`, and
  the `omacvm-chromium-webgpu` launcher with a "Chromium (WebGPU)" menu entry.
- Patches (guest Mesa, `src/app/guest/venus/patches`):
  - `mesa-zink-moltenvk-no-push-descriptors.patch`: SPIRV-Cross can alias
    zink's typed bo arrays only in argument buffers, which MoltenVK never
    uses for push sets (every kernel failed);
  - `mesa-zink-moltenvk-null-descriptor.patch`: start without
    `nullDescriptor`; unbound slots are undefined on MoltenVK;
  - `mesa-zink-moltenvk-global-loads.patch`: MoltenVK 1.4.2's SPIRV-Cross
    forwards loads through buffer addresses past stores to the same memory,
    so swaps lost elements (Geekbench's Feature Matching failed); zink reads
    each global address back from a variable, which keeps the load in place;
  - `mesa-venus-opaque-fd-semaphores.patch`: OPAQUE_FD binary semaphores on
    the DRM syncobj Venus already has, the one thing Dawn was missing;
  - `mesa-venus-incremental-present.patch` (from the `kosmickrisp` track).
- Host (`app/runtime/patches`): `virgl-darwin-venus-moltenvk-zero-init.patch`
  reports `shaderZeroInitializeWorkgroupMemory` off on MoltenVK, for every
  guest instance version (Dawn uses 1.1): MoltenVK's SPIRV-Cross cannot
  compile zero-initialized workgroup memory, and such a WebGPU shader lost
  the whole Vulkan context.
- GL stays on virgl. Zink as a GL driver is not installed (GL 2.1 only on
  MoltenVK).
- Chrome's two gates (ADR 0022): a Vulkan compositor, and Dawn's
  `SupportsExternalImages()` (OPAQUE_FD semaphores). The launcher passes
  `--ozone-platform=x11 --enable-skia-graphite
  --skia-graphite-dawn-backend=vulkan` with `MESA_VK_WSI_DEBUG=sw`: Chrome
  refuses Vulkan on Wayland, and Venus' DRI3 present to Xwayland is half as
  fast as its software path. WebGL stays on virgl and is copied into the
  compositor (about a fifth slower), so the default Chromium is unchanged.
- Copying a WebGPU canvas into a 2D canvas returns zeros in every Chrome
  mode in the VM (also the default): open.
- Kernel launches cross the Venus ring like draw calls: launch-heavy
  OpenCL work pays Venus's latency (see vkmark above).
- On KosmicKrisp (Mac mini M4, macOS 27) the same guest Mesa passes the
  same checks; the Zink patches and the host zero-init patch act on
  MoltenVK's driver ID only, so they stay off there. Results tables:
  [../benchmarks/README.md](../benchmarks/README.md#gpu-compute-with-venus-2026-10-04).

## 7. Video decode (built: `video-decode`)

```
 Chrome / Firefox / mpv -> libva -> Mesa virtio_gpu_drv_video.so
   (Firefox/mpv via the omacvm VA shim that hides I420/YV12)
   -> virgl video commands in SUBMIT_3D
   -> vrend_video.c -> virgl_video_vt.c
        H.264: SPS/PPS rebuilt from picture params
        VP9:   one frame at a time (hidden frames too)
        AV1:   the frame's OBUs cut from the TU (Chrome only)
        HEVC:  Main / Main 10 (SPS short-term RPS limits apply)
   -> VTDecompressionSession (real-time, hardware)
   -> CVPixelBuffer (IOSurface planes)
   -> CGLTexImageIOSurface2D (rect texture) + glBlitFramebuffer
      into the guest's plane textures (0.5 ms per 4K frame; CPU copy 5.5 ms)
```

Decode calls run on QEMU's main loop under the BQL (about 5 ms per 4K VP9
frame of waiting; two 4K streams contend). Moving the wait off the main loop
is planned. Why VideoToolbox sits inside virglrenderer's video path: ADR 0014.

## 8. Displays (built: `app-displays`)

```
 Mac display 1 (window, Virtual-1)  Mac display 2 (Virtual-2) ... up to 5
        |                                 |
 QEMU cocoa main view               head window: own DisplayChangeListener,
 (console 0)                        CAOpenGLLayer sharing gl_view_ctx (console N)
        \______________ virtio-gpu, max_outputs=5 _______________/
                               |
 virtio-serial port org.omacvm.display  <->  omacvm-displays (guest agent)
   QEMU -> guest: {"layout": [...points...], "external", "fullscreen"}
   guest -> QEMU: {"hello":1,"external":bool}, {"monitors":[...]}
```

- Heads are created only after the guest agent says hello, and only in full
  screen with "Use external displays" on. Windowed: one window, one output.
- Linux virtio-gpu has no suggested position, so positions travel over the
  port. One virtio-tablet: QEMU maps window-local pointer positions into the
  bounding box of all monitors the guest reported.
- `qemu-virtio-gpu-display-event-race.patch`: a second display change while
  Linux reads the outputs was lost.
- Head windows still draw with CAOpenGLLayer; moving them to the IOSurface
  present is part of merging `gpu-native` and `app-displays` (one present
  path for every head). ADR 0015.

## 9. Settings and fallbacks

Every new path has a safe default and a way back to today's path. A failure
falls back and logs once.

| Setting | Default | Effect | Status |
|---|---|---|---|
| `defaults write org.omacvm.app gpuSafeMode -bool true` | false | the 2.6.0/2.8.0 fence and frame path: sets the three settings below (poll, tick, layer); video decoding and the virgl fixes stay | built (`gpu-native`) |
| `OMACVM_VIRGL_POLL_FENCES=1` | off | back to the 1 ms fence poll | built (`gpu-native`) |
| `OMACVM_GL_PRESENT_ON_TICK=1` | off | redraw on QEMU's 30 ms tick again | built |
| `OMACVM_GL_PRESENT=layer` | iosurface | CAOpenGLLayer path; also taken by itself if the IOSurface contexts fail | built |
| `OMACVM_GL_VSYNC=0` | on | show frames when drawn instead of on the display's refresh | built (`pacing-hdr`) |
| `OMACVM_GL_LEAD_MS` | 3 | how long before the vsync a frame goes on the layer | built (`pacing-hdr`) |
| `OMACVM_GL_REFRESH=fixed` | follows the guest | display link at the screen's full rate while frames come | built (`pacing-hdr`) |
| `OMACVM_IDLE_REFRESH=0` | on | QEMU's refresh tick stays at the display's rate; by default it slows to 500 ms while it has nothing to do | built (`idle-power`) |
| `OMACVM_GL_COLOR=native` | sRGB | untagged surfaces (old colours, oversaturated on P3) | built (`pacing-hdr`) |
| `OMACVM_GL_HDR=1` | off (the app sets it only with an EDR display) | a 10-bit scanout is BT.2100 PQ: tag PQ, EDR on | built (`pacing-hdr`) |
| `omacvm-virtio-gpu-build` (guest, root) | not installed | guest virtio-gpu with 10-bit planes; `--remove` goes back | built (`pacing-hdr`) |
| `omacvm enable vulkan` (feature, per VM) | off | the VM folder's `vulkan` file: Venus device options for that VM; OmacVM's Mesa in the VM | built (`gpu-next`) |
| Graphics setting (`graphics` file per VM) | auto (= OpenGL in 3.0.0) | Venus device options for that VM once `venus-ready`; replaces the hidden `venus` default (moved once, removed) | built (`vk300`, `vk-review-fixes`) |
| `OMACVM_VULKAN_DRIVER` | by macOS version | force an ICD file | built |
| Guest: `src/app/guest/venus/install.sh` (`--force`, `--remove`) | with the feature `vulkan` | OmacVM's Mesa for Vulkan, OpenCL (rusticl), Firefox WebGPU | built (`webgpu-compute`, `gpu-next`) |
| `OMACVM_VIDEO_DECODE=0` | on | no video caps offered; guest decodes in software | built (`video-decode`) |
| `OMACVM_VIDEO_AV1=1` | set by the app when the VM has the shim | offer AV1 | built |
| `OMACVM_VIDEO_NO_VP9`, `OMACVM_VIDEO_NO_HEVC` | off | hide one codec | built |
| `OMACVM_VIDEO_COPY` | off | CPU copy instead of IOSurface blit | built |
| `OMACVM_VIDEO_NO_REALTIME` | off | no real-time VT session | built |
| `OMACVM_VIRGL_VIDEO_ABI=legacy` | Mesa 26 numbers | profile numbers of older guests | built |
| `OMACVM_VIDEO_DEBUG=1` | off | log decode details | built |
| "Use external displays" (Omarchy display panel, stored in the VM) | toggle in the VM | one output per Mac display | built (`app-displays`) |
| `OMACVM_MAX_OUTPUTS`, `OMACVM_DISPLAY_SOCKET` | set by the launcher | heads and agent socket | built |
| `OMACVM_DISPLAYS_DEBUG=1` | off | log the display port | built |
| `OMACVM_BACKGROUND=1`, `OMACVM_COCOA_HIDDEN=1` | off | test only: window behind / no window | built |
| `OMACVM_TEST_SKIP_DISPLAYS`, `OMACVM_TEST_MAIN_DISPLAY` | off | test only: virtual displays | built |
| `OMACVM_POINTER_START=0` (app: `pointerStart` false) | on | pointer taken only on enter or a click (QEMU's way) | built |
| `OMACVM_POINTER_DEBUG=1`, `OMACVM_TEST_POINTER=<s>` | off | log pointer takes / test only: made-up motion | built |

What the app records: QEMU's log (`qemu.log` in the VM folder) has the
paths taken (fence mode, present mode, Venus ICD, video caps). `omacvm check`
reads the guest side (renderer string, vainfo profiles, outputs). Planned: one
line per path in a file `omacvm check` reads from the host side, so a
fallback is visible without reading logs.

## 10. Security: the guest is untrusted

```
  untrusted                         | trusted (QEMU process, user's account,
                                    |  hardened runtime, no extra entitlements
  guest kernel + apps               |  beyond hypervisor + what the app needs)
  --------------------------------> | virtio-gpu ctrl queue   -> QEMU checks
    command streams, shaders,       | virglrenderer decoders  -> vrend checks
    resource sizes, blob sizes,     | Venus ring              -> vkr checks
    video bitstreams,               | our VT parser           -> our checks
    display JSON lines              | omacvm-cocoa-displays   -> our checks
```

What crosses and who checks it:

- **virgl command streams and shaders**: virglrenderer's decoder (bounds,
  handles, formats). Upstream code plus our patches; every patch that touches
  a decoder states its bounds check. A refused shader kills that guest
  context only (Chrome then hangs, which is how the Basemark bug showed up);
  reporting a context loss instead is planned.
- **resource and blob sizes**: QEMU checks sizes against guest RAM and the
  hostmem window; a blob that is not whole host pages is refused, never
  rounded up.
- **scanout size**: the guest picks it; the present IOSurfaces are capped
  at the largest display and made again at most twice a second.
  Still open (found 2026-10-04, in 2.6.0 too, owner `gpu-robust`): switching
  the scanout between two very large framebuffers (8000x6000 and 7000x5000)
  grows QEMU's GPU memory by about 1 GB per switch and never frees it.
- **Venus**: the ring and command decoding are upstream vkr; the render
  server runs in QEMU's process on macOS, so a Venus bug is a QEMU bug
  (no process boundary, ADR 0012). Mitigation: off by default, hardened
  runtime.
- **video bitstreams**: our code parses slice headers (H.264 `pps_id`,
  ref-idx overrides), AV1 OBU headers and VP9 frames before VideoToolbox
  sees them. These parsers need a libFuzzer harness (planned, owner:
  `video-decode`). VideoToolbox itself decodes in `VTDecoderXPCService`,
  a separate macOS process.
- **display messages**: JSON from the guest agent; numbers type-checked
  (finite `NSNumber` below 1e7, else the monitor is skipped), at most one
  update applied per second (`app-displays` round 2; tested with nulls,
  arrays, 1e300, 101 flips).
- **no host pointers** reach the guest; no guest-controlled allocation
  without a limit (hostmem 4 GiB, outputs 5, retained pixel buffers 3,
  IOSurfaces 3 per window, each at most the largest display, classic
  resources three quarters of the Mac's memory and, below that, macOS's
  memory pressure). The lost context's name in `logs/gpu-memory` is the
  guest's: only letters, digits and `. _ -` are written.
- **scanout size and format**: the present surfaces follow the guest's
  scanout, capped at the largest display. `pacing-hdr` keeps five of them
  with vsync (queue for the display's refresh; three with
  `OMACVM_GL_VSYNC=0`) and a 10-bit scanout doubles them to 8 bytes a
  pixel: at most 5 x 8 bytes x the largest display (a 6K XDR: about 800 MB;
  three 8-bit ones before: about 240 MB). A guest that flushes faster than
  the display gets at most one blit per refresh, with or without vsync. The
  colour space comes from QEMU's own setting, never from the guest.

## 11. Test strategy

| Level | What | Where |
|---|---|---|
| Build time | virglrenderer's own tests + ours, run in every runtime build (e.g. `Tests/virgl/test-integer-sampler-shader.c`: TGSI -> GLSL, compiled on the Mac's OpenGL) | `app/runtime` |
| Host only | Venus init + context create without a VM; VT probe; JSON and pointer-math unit tests | track scratch, to move into `app/runtime/Tests` |
| Conformance | dEQP GLES2/3 (virgl), Vulkan CTS smoke (Venus), WebGL 1 and 2 conformance in Chrome; `compare.py` diffs two runtimes case by case | `tests/graphics` (`conformance-runs`) |
| Smoke | Hyprland up, `chrome://gpu` green, guest `grim` vs a capture of the window (`screencapture -l`): upright, right colours | per track |
| Video | `ffmpeg -hwaccel vaapi` framemd5 equal to software (H.264, VP9, real content) | `video-decode` |
| Compute | `src/app/guest/venus/cltest.c` (saxpy, reduction, atomics, in-place sort vs CPU), `semtest.c` (OPAQUE_FD semaphores shared by two devices; prints Dawn's adapter check), Geekbench 7 GPU OpenCL validation, WebGPU matmul vs CPU sample (`webgpu-compute` tools) | `webgpu-compute` |
| GPU check | `app/scripts/gpu-check.sh VM_DIR 3`: Aquarium + Basemark finish, no refused shaders in `qemu.log` | `gpu-hang` |
| Performance | glmark2, vkmark, Aquarium, Basemark, video-bench.py; same window size, median of 3, JSON, with `~/.omacvm-bench.lock` and other test VMs paused | `src/bench`, `docs/benchmarks` |
| Stability | 30 min soak per path (browser + video + glmark2 loop), sleep/wake, display plug/unplug | per track |

Numbers so far (track notes have the raw data; most were taken without the
bench lock and are indications only):

| What | Shipped | Built |
|---|---|---|
| glmark2, window 1440x810 pt, 60 Hz | 1259 | 4006 (async fences + present on flush) |
| glmark2 short set, bench lock | 1096-1139 | 3310-3590 (final: + fence wait) |
| 2.9.0 candidate, same build, safe mode vs new (bench lock, quiet Mac) | glmark2 short 932/1073, Aquarium 23.0/23.1/24.0 | glmark2 short 3748/3696, Aquarium 22.9/22.6/22.8 |
| same, other VMs loading the Mac | Aquarium 23.4/24.0/23.1 | Aquarium 19.9/20.6/21.5 (the extra threads compete for CPU) |
| RC after the review (c293), quiet Mac, bench lock | glmark2 short 1445/1539, Aquarium 20.8/21.2/21.4 | glmark2 short 3610/3583, Aquarium 21.9/22.1/22.2 (first candidate: 3538/3629, 22.0/22.2/22.8) |
| same, 12 busy processes on the Mac (CPU load only) | Aquarium 10.4/10.4/10.5 | Aquarium 11.8/12.0/12.2 and 12.1/12.5/13.2 (first candidate: 12.2-12.8) |
| Long guest GPU job (65-100 ms draws), QEMU wakeups/s and CPU energy in 20 s, one run each | - | 2,100/s, 1.5 J (with 50 us naps throughout: 19,900/s, 2.8 J) |
| Fence to reply, median | 1.56 ms | 0.20 ms |
| Window frames/s (QEMU side) | <= 33 by the code (30 ms timer) | 60 on a 60 Hz display; at 120 Hz about 108 of 120 reach the panel (`pacing-hdr`) |
| WebGL Aquarium 30k, bench lock | 21.2-21.6 fps | 19.6-22.9 fps (same on a quiet Mac; about 10% lower when other VMs load it, row above) |
| QEMU CPU, glmark2 / Aquarium, bench lock | - | 165% / 176% (fence wait; spinning: 195% / 194%) |
| vkmark headless 800x600 (Venus, never in a release), bench lock | - | 5195; the same build with polled fences: 732 |
| dEQP GLES2/GLES3, WebGL 1/2 (`tests/graphics`, 2.9.0 candidate, also c293) | 853/859, 812/869, 776/787, 959/970 | same cases; one flaky GLES3 case; the transform-feedback crash of 2.6.0 remains |
| Vulkan CTS smoke (Venus, 1958 cases), c293 | - | 546 pass, 1402 not supported, 5 fail, 5 timeout: the same cases as the combo runtime |
| 30-minute soaks, c293 | - | GL + WebGL + VA-API video: pass, 3.2 million fences; Venus (vkmark + vkcube, 11 rounds): pass, no refused blob |
| WebGPU matmul f32 2048, Chromium in the VM (launcher) vs Chrome on the Mac, same locked batch | - | 5071 vs 6038 GFLOPS (84 %) |
| WebGPU matmul f32 2048, Firefox, VM vs Mac, same locked batch | - | 665 vs 319 GFLOPS |
| OpenCL clpeak fp32 (VM, 40-CU shim / as reported) vs Mac OpenCL | - | 8.9 / 1.5 vs 15.6-16.1 TFLOPS |
| Geekbench 7 GPU OpenCL, VM vs Mac, same locked batch | - | 42486 vs 95380 (45 %); before the global-loads fix 10673, Feature Matching failed |
| ffmpeg 4K nlmeans in the VM, OpenCL vs 8 vCPUs | - | 1.07 vs 0.33 fps |
| WebGPU matmul f32 2048 on KosmicKrisp (Mac mini M4, unlocked), Chromium launcher / Firefox in the VM vs Chrome on the mini | - | 1148 / 167 vs 1614 GFLOPS |
| Geekbench 7 GPU OpenCL on KosmicKrisp (Mac mini M4), VM vs the mini's OpenCL | - | 18973 vs 35240 (54 %), all workloads valid |
| Compute soak (OpenCL, Firefox and Chromium WebGPU, ffmpeg OpenCL), M4 Max / mini on KosmicKrisp | - | 63 rounds in 36 min / 24 in 15 min, 0 failures |
| YouTube 4K60 VP9, guest cores / QEMU cores | 1.21 / 1.71 (software) | 0.34 / 0.45 (VideoToolbox) |

## 12. Frame pacing, colour and HDR (built: `pacing-hdr`)

```
 guest: Hyprland flips on the DRM vblank timer (EDID rate, e.g. 120.006 Hz)
   |  RESOURCE_FLUSH
 QEMU thread [BQL]: blit scanout -> IOSurface (BGRA8, or half float when the
   |                scanout is 10-bit), tagged sRGB or BT.2100 PQ
 present_queue: wait for the blit's fence
   |-- frames one at a time (> 52 ms apart): layer.contents now, no link
   |-- close frames: jitter buffer (<= 3 frames)
   |
 display link (own thread, window's screen; rate: the guest's, see below)
   |  each tick: dispatch_after(vsync - 3 ms) on the commit queue
 commit queue: oldest frame -> layer.contents (+ EDR when PQ)
   v
 Core Animation latches at the vsync
```

- **Why**: the guest's frames come at the display's rate but at their own
  phase; shown as soon as drawn, jitter around the latch put two frames into
  one refresh and none into the next. The queue absorbs that: a late frame
  waits one refresh; once a second, if a frame was left over after every
  tick and none came late, one is skipped (the guest's EDID rate is a hair
  faster than the display). A second flush within half a refresh replaces
  the first only while the guest draws more than 1.25x the display's rate
  (at the display's own rate close frames are jitter, both real). The link
  follows the window's screen and asks for that screen's full rate (60, 120,
  144 Hz) on every move; QEMU's EDID follows too, so the guest's vblank
  timer switches with it. While the guest draws faster than the link,
  QEMU blits at most one frame per refresh of the window's screen (the
  newest), as gpu-native does, instead of one per flush. Five present
  surfaces with vsync (three with `OMACVM_GL_VSYNC=0`, as before). ADR 0020.
- **Refresh rate** (ProMotion): the link runs only while frames come close
  together; single frames (typing, a cursor) go on the layer when ready and
  nothing ticks (an idle desktop sends no frames at all). On a
  variable-refresh screen the link asks for the slowest whole fraction of
  the full rate that is a whole multiple of the guest's frame rate (24 fps:
  24 Hz, 30: 30, 60: 60, 20: 40, else the full rate), so macOS can lower
  the panel's rate like for a native app. Lower after two seconds, higher
  at once. Fixed-rate screens (60 Hz externals) keep their rate. The guest
  itself stays at the EDID rate: virtio-gpu has no adaptive-sync property,
  so Hyprland's VRR stays off. `OMACVM_GL_REFRESH=fixed` keeps the full
  rate. ADR 0023.
- **Idle**: QEMU's own refresh tick (`gui_update`, every listener's
  `dpy_refresh`) runs at the display's rate too. The main window's GL frames
  never need it (they are pushed) and virtio-gpu's `gfx_update` does
  nothing; only 2D updates, new scanouts, the extra outputs' windows (drawn
  on the tick) and a frame not shown yet do. A second without those and it
  slows to 500 ms; the next one re-arms it at once
  (`qemu-cocoa-idle-refresh.patch`, `OMACVM_IDLE_REFRESH=0` to keep it).
- **Latency**: Core Animation shows a commit at the next vsync if it lands
  about 3 ms before it; committing earlier does not show it sooner. So the
  delay from a finished guest frame to the glass is set by the guest's vblank
  phase (free-running), between ~3 ms and one refresh more. Only a guest
  vblank locked to the host's (ADR 0020 option 1, a guest module change)
  can take the average half refresh off.
- **Locks**: `present_lock` (an `os_unfair_lock`) guards the queue and the
  counters; nothing on the display link thread or the commit queue takes the
  BQL. The link pauses 0.25 s after the last frame, or after a second of
  single frames (pause and wake both on the main thread, so a frame never
  waits behind a paused link).
- **Colour**: surfaces are tagged; Core Animation converts sRGB (or PQ) to
  the display. HDR needs the guest at 10 bits (guest module) with Hyprland's
  `cm = "hdr"` and QEMU's `OMACVM_GL_HDR=1`. The app's hidden switch
  (`defaults write org.omacvm.app hdr -bool true`) sets QEMU's side and tells
  the guest (SMBIOS `omacvm.hdr=1`), but only while a display has EDR
  headroom (`NSScreen` potential EDR > 1); Macs with SDR displays only keep
  the 8-bit path and `qemu.log` says so. `omacvm-display-sync` then adds the
  HDR fields to the output's rule once the 10-bit module runs. ADR 0021.
- **HDR clients**: an app must hand Hyprland a PQ image description
  (`wp_color_manager_v1`). GStreamer's `waylandsink` does; mpv 0.41 with
  `--gpu-api=opengl` does not (it only reads the preferred description, its
  hint needs a Vulkan swapchain), and Chrome 154 clips CSS `rec2100-pq` at
  SDR white. Those show as SDR, correctly tone-mapped.
- **Measuring** (`tests/graphics/pacing`):
  a pacing page draws its frame number as 16 bit cells; ScreenCaptureKit
  captures the VM window per WindowServer frame and counts how far the number
  moved (1 = each frame shown once). F13 presses over QMP and a marker cell
  give key to screen latency; a dev build decodes the number on the host to
  time QEMU flush to screen per frame. `pacing.html?fps=N` draws N new
  frames a second (video-like) and `cadence.py` reads how long each stayed
  on screen. QEMU's trace events `cocoa_present_*` (`-trace`) give the
  link's rate, ticks and counters. Colour: six colour bars captured in
  Display P3; HDR: a capture in extended linear P3 (1.0 = SDR white) plus the
  screen's EDR headroom.

Numbers (window 1440x810 pt, Chrome page at 120.01 fps (60 on the 60 Hz
display) in the guest, bench lock held, 12 s per run):

| | gpu-native (frames when drawn) | `pacing-hdr` |
|---|---|---|
| MacBook 120 Hz: distinct frames on screen per second | 107.9, 109.0, 108.9, 110.0 | 119.8, 119.8, 119.8 |
| MacBook 120 Hz: guest frames shown exactly once | 74-82 % | 99.0-99.6 % |
| MacBook 120 Hz: QEMU flush to screen, median | 5.2-7.2 ms | 12.6-14.2 ms |
| virtual 120 Hz display: shown once (frames/s) | 55.5 % (107.4) | 98.2 % (117.5) |
| external 60 Hz display: shown once (frames/s) | 82 % (52.1) | 99.7 % (60.0) |
| glmark2 quick, 8 runs each, median | 2829 | 2764 (an earlier build) |
| glmark2 quick, final build, 3 runs each, median (virtual 120 Hz display) | 2488 (`OMACVM_GL_VSYNC=0`) | 2518 |
| colour of guest `#ff0000` in Display P3 | (255,0,0) (oversaturated) | (234,51,35) (sRGB red) |
| EDR headroom of the screen with HDR on | 1.0 | 4.2-16 |

testufo.com (the 120 fps lane, UFO position per WindowServer frame,
`ufopace`), MacBook 120 Hz, bench lock, 12 s per run, new frames per second
and refreshes that skipped a frame:

| | new frames/s | skipped |
|---|---|---|
| 2.7.0 as installed (CAOpenGLLayer path) | 82.5-99.2 (one run 58.9) | 91-221 |
| gpu-native (frames when drawn) | 76.4-90.4 | 203-324 |
| `pacing-hdr` (merge always) | 107.4-119.6 | 5-72 |
| `pacing-hdr` (merge only when the guest is faster) | 116.4-118.7 | 3-4 |

Full screen on the MacBook (how the app starts by default), bench lock:

| | new frames/s | skipped per 12 s |
|---|---|---|
| 2.7.0 as installed | 112.8, 115.0, 115.4 | 55-79 |
| gpu-native | 106.4, 107.2 | 138-159 |
| `pacing-hdr` | 119.3, 119.3, 119.9 | 1-7 |

The 2.6/2.7 path is not capped at 33 frames a second as once thought: it
shows 80-99 of 120 but skips a frame on a fifth of the refreshes (judder).

Window moved between displays: built-in 120 Hz, external 60 Hz (57-60 shown
per second), a 144 Hz virtual display (guest at 143.94 Hz, 142.9 shown per
second); the guest's refresh and the display link followed each move.

HDR (PQ bars at 100/203/400/600/1000 nits in GStreamer's `waylandsink`):
0.37 / 0.60 / 0.89 / 1.10 / 1.50 times SDR white on the MacBook's XDR panel
(Hyprland 0.56 compresses the top; the host passes at least 2.95x).

After the rebase onto gpu-native's capped IOSurface present (`3bf87cc`),
testufo on a virtual 120 Hz display, bench lock, 3 x 12 s:

| | new frames/s | skipped |
|---|---|---|
| `pacing-hdr` r2d, default (the virtual display has one rate, so the rate logic does not run) | 119.6, 119.9, 119.9 | 35, 8, 3 |
| `pacing-hdr` r2d, `OMACVM_GL_REFRESH=fixed` | 119.6, 119.8, 109.5 | 25, 8, 11 |
| `pacing-hdr` r2final (clean runtime build), 3 sessions | 117.7-119.8 in 7 of 9 runs; 114.8 and 90.2 | 3-26 |
| `pacing-hdr` final build (review fixes, clean runtime build) | 119.9, 119.9, 119.6 | 1, 1, 5 |
| final build, MacBook's 24 Hz floor faked (dev build: the rate logic runs) | 118.6, 119.2, 116.2 | 4, 4, 3 |
| gpu-native (frames when drawn) | 92.0, 98.2, 100.5 | 220-251 |

Two r2final runs were below the 116 bar. The 90.2 one: WindowServer itself
composited only 90 frames a second then (other tracks' VMs loaded the Mac;
the bench lock does not pause QEMUs outside `~/omacvm-*`). The 114.8 one has
no recorded cause. In the final build's 116.2 run WindowServer composited
116.4 frames a second, nearly every one with a new frame. With the 24 Hz
floor faked the link stayed at 120 Hz in every second of the testufo runs:
no rate change, no flapping.

Refresh rate following the guest, virtual 120 Hz display with the screen's
slowest rate faked at 24 Hz (dev build; the MacBook panel's floor), bench
lock, 30 s per row (`ab-matrix`, build r2k): ticks of the display link per
second, frames held on screen exactly as long as they should (10 s
capture), QEMU CPU. The 60 fps "even" values here are not valid: that
version of `pacing.html` ticked its 60 and 30 fps clock right on a vblank
(see the next table):

| guest content | follows the guest | fixed full rate |
|---|---|---|
| page at 24 fps | 23.8 ticks/s, 84 % even, 17.2 % | 120.6, 72 %, 17.5 % |
| page at 60 fps | 60.5, 98.5 %, 29.4 % | 120.7, 77 %, 32.0 % |
| page at 5 fps | 0 (shown when ready), 9.5 % | 114, 11.3 % |
| page at 120 fps | 120.5, 97 %, 46.4 % | 120.8, 91 %, 58.8 % |
| mpv, 24 fps video | 23.7, -, 19.5 % | 120.7, -, 23.7 % |

Soak, 30 minutes of one VM run (final code as the dev build with the 24 Hz
floor faked, virtual 120 Hz display, two bench-locked 15-minute halves;
20 cycles of pacing page, testufo, glmark2 and 20 s of mpv): the guest
stayed up (same QEMU, guest uptime 32 minutes), no QEMU errors. testufo
119.1-120.0 new frames a second and the pacing page 116.3-120.1 shown in
18 of 20 cycles; the other two (105.9 and 115.2) came while VMs outside
the lock's reach loaded the Mac and the guest's own rAF fell to 111-114.
glmark2 1617-2679 (50 in that loaded cycle). QEMU's RSS 5.3-5.6 GB, then
2.7-3.4 GB after macOS compressed it under the other VMs' memory pressure.

Final build, fixed `pacing.html` (its clock half a refresh off the vblank),
bench lock, 10 s per row: frames held exactly as long as they should.

| page | follows the guest (24 Hz floor faked) | one rate (120 Hz) |
|---|---|---|
| 24 fps | 97.9 % (link 24 Hz) | 55.8 % (4, 5 or 6 refreshes) |
| 30 fps | 97.7 % (link 30 Hz) | 98.3 % |
| 60 fps | 99.8 % (link 60 Hz) | 99.0 % |

On the MacBook panel itself (window on Space 1, nobody at the Mac):
the link is granted 24 Hz. It ticked 24-26 times a second for a 24 fps
video (fixed: 120.5) and not at all for a page changing 5 times a second
(fixed: 120.6). The panel's own refresh was not measured: ScreenCaptureKit's
update count for the whole built-in display includes other windows (37.8 a
second with no VM), so it does not show the panel's rate; that needs
WindowServer's frame times on that display (with the power matrix). The Mac's power in that 10-minute check (14.4-20.7 W
with the VM, 26.9 W without) was set by other tracks' VMs, not by this:
the power comparison needs a quiet Mac (end of the pipeline).

### Input latency (3.0.1 lane `input-latency-cursor`)

From an event on the Mac to the first changed picture of the VM's window on
screen (WindowServer's display time, ScreenCaptureKit), Mac mini M4, a 60 Hz
virtual display, a 1440x900 window, `foot` in Omarchy, 30 events per row,
median (p10-p90) in ms. `src/tests/input-latency-vm.sh`
(`tests/graphics/pacing/inputlat.swift`); the native row is a plain AppKit
window on the same display (`nativelat.swift`), the floor macOS itself sets.

| | Mac to screen | Mac to QEMU's input | QEMU's input to the guest's flush | flush to screen |
|---|---|---|---|---|
| native AppKit window, key | 16.0-19.0 (9-24) | - | - | - |
| VM, key on an idle screen | 24.1-26.7 (18-36) | 0.7-1.0 | 5.2-8.1 | 16.2-17.5 |
| VM, pointer move (software cursor, QMP) | 23.3-27.2 (16-33) | 1.4-1.6 (QMP) | 3.4-5.1 | 17.9-19.7 |
| VM, key while the pointer moves | 34.3-44.7 (26-52) | 0.5-1.5 | 7.6-9.7 | 19.6-30.7 |

- Where the VM's time goes: the present itself costs what macOS costs any
  app (flush to screen 16-18 ms on an idle screen = the native floor); the
  guest's own part (Hyprland and the app, through virgl) is 3-10 ms; QEMU's
  input path under 1 ms. While frames come steadily (the pointer moving, an
  animation) the flush-to-screen part grows by up to a refresh: frames wait
  in the jitter buffer (ADR 0020), and the guest's vblank phase is free.
- Opt-in, `OMACVM_GL_INPUT_FIRST=1` (`qemu-cocoa-gl-present-input-first.patch`):
  while input comes, the newest queued frame goes on screen and older ones
  are dropped. The queue behind a new frame shrank (2 deep in 4 % of frames
  instead of 26 %); keys while the pointer moved: median 34.8 vs 35.1 ms
  (n=30) and 34.3 vs 39.5 ms (n=60), p90 46.7 vs 51.3 and 41.4 vs 49.9 ms.
  Off by default until scrolling's pacing with it is measured (scrolling is
  input too). Showing frames when drawn (`OMACVM_GL_VSYNC=0`) was no faster
  (43.9 vs 44.7 ms).
- The pointer is the biggest single delay: with Omarchy's software cursor a
  move waits for a whole guest frame and its present (about 25 ms at 60 Hz;
  the Mac's own cursor is not in a frame at all). The Mac pointer setting
  (`omacvm-cocoa-hw-cursor.patch`, hidden, off) makes the guest's cursor
  plane image the Mac's cursor; Hyprland 0.56.2 does not use the cursor
  plane on virtio-gpu yet (Linux hides a virtual GPU's cursor plane from
  atomic clients without DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT, and
  aquamarine does not ask for it), so it waits for the guest side.
- Posted mouse moves (`CGEventPostToPid`) reach no app's view, so pointer
  rows go in through QMP (no AppKit; AppKit's part for keys is under 1 ms).

## 13. Merging the tracks

The tracks share one runtime. Order and overlaps known today:

1. `gpu-hang` (`virgl-texture-integer-samplers.patch`) goes first: a fix,
   after `virgl-native-opengl.patch`.
2. Done: `gpu-venus` is merged into `gpu-native` (each shared patch applied
   once; gpu-venus's other patches after the fence and present patches).
   Venus fences use `gpu-native`'s FIFO thread-sync.
3. `gpu-native` and `app-displays` both patch `ui/cocoa.m` heavily. On
   `gpu-2.9.0` the present patches apply after the display patch and leave
   the head windows on their `CAOpenGLLayer` (QEMU's 30 ms tick); moving the
   heads to the IOSurface present is still open (with `pacing-hdr`'s pacing).
4. Done on `gpu-2.9.0`: one test-window patch (`qemu-cocoa-hidden-for-tests.patch`:
   `OMACVM_COCOA_HIDDEN`, `OMACVM_BACKGROUND`), applied after the display
   patch, which has its own test mode at the same two places.
5. Done: this version replaced `gpu-native`'s earlier draft.
6. `pacing-hdr` sits on `gpu-native` (its two patches apply after
   `qemu-cocoa-gl-present-iosurface.patch`). On `gpu-2.9.0` they apply
   after `qemu-hvf-virgl-blob-subregion.patch` without offsets and
   `ui/cocoa.m` compiles (checked against the 2.9.0 candidate's patch
   series); `omacvm-cocoa-background.patch` is gone there (the hidden-for-tests
   patch has `OMACVM_BACKGROUND`). With `app-displays` the head windows need
   the same present (one queue and one display link per head, each on its
   own screen); until then HDR goes to `Virtual-1` only, since the heads'
   8-bit `CAOpenGLLayer` has no PQ.
7. The 2.9.0 RC2 (`gpu-2.9.0`) is built on 2.8.0 as released, which brings
   2.7.1's GPU security patches (`gpu-robust`). Order in the virgl chain:
   2.7.1's patches, then `gpu-native`'s and `kosmickrisp`'s, then
   `gl-compat`'s; in QEMU: 2.8.0's display patches, the view-flush and 2D
   scanout patches, then the GPU path and `pacing-hdr`'s. Both chains apply
   with no fuzz or offsets. `virgl-core-instance-id.patch` stays next to
   `virgl-shader-core-glsl-version.patch` (one `#extension` rule in the
   patched source). On the RC2 runtime: the conformance stride lists equal
   `gl-compat`'s final runtime case by case; dEQP GLES3 transform feedback
   (every 3rd case) 404 pass, 0 fail, 0 crash, where 2.7.1 failed 107 of the
   same cases (integer outputs); 30-minute soak passed; against 2.8.0 (bench
   lock, one VM of another track running): glmark2 short set 2,856 vs 1,124,
   Aquarium 19.0 vs 19.9 fps, Basemark Web 3.0 2,669 vs 2,482; testufo on a
   virtual 120 Hz display 116.6-119.6 new frames a second (2.8.0: 88.8-90.6;
   `pacing-hdr`'s final runtime in the same session: 114.5-118.7); Venus
   vkmark 4,470 vs the first candidate's 4,354 (medians of 3).
