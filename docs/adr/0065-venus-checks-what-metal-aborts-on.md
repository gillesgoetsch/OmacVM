# 0065: Venus checks what the Mac's Vulkan driver aborts on

Status: accepted, built (`zink-abort`, 3.2.14), always on; amended in 3.2.15
(`venus-robust`, "What else vkr refuses" below). Amends
[0012](0012-venus-in-process.md). Notes, probes and the review:
work/tracks/zink-abort.md, work/tracks/venus-robust.md.

## Context

Venus runs in QEMU's process on macOS (ADR 0012: Metal heaps are process-local,
so there is no render server process to lose instead). ADR 0012 accepted that a
bug in vkr or the driver ends QEMU, with "Venus off by default; revisit option 1
if Venus becomes the default". That has not held since 3.0.13: Automatic gives
Vulkan with KosmicKrisp on macOS 26 and newer (ADR 0035).

Then an ordinary program in the VM ended the whole VM (#598): `glxinfo -B` or
Ghostty with Zink. Zink asked about a linear render target with the emulated
LINEAR DRM modifier, vkr asked the host a shortened question (without
INPUT_ATTACHMENT and COLOR_ATTACHMENT), heard yes, and KosmicKrisp made the
image a 2D array texture. Metal ended the process at `vkBindImageMemory2`:
"Linear texture: must be of type MTLTextureType2D".

Metal checks texture descriptors in release builds too (`MTLReportFailure`,
then abort; no `MTL_*` setting is involved and none turns it off). KosmicKrisp
and MoltenVK hand guest values on to it. Through vkr as 3.2.13 builds it, on
3.2.13's drivers (the build-time test below, one process per case, M4, macOS 27),
31 of 101 image, bind, view, sampler and query cases end the process on
KosmicKrisp and 14 on MoltenVK: too many levels, layers or texels, a sample count the format has not,
a zero size, a linear depth, compressed or 3D image, a 2D image with depth 4, a
view past its image or of another texel size, a cube view of 5 layers, an
unknown format, sampler filter 7, `PLANE_1` of a one-plane image in a layout
query.

## Options

1. **Patch KosmicKrisp** to refuse what Metal cannot make: a Mesa patch and a
   rebuild of every KosmicKrisp, MoltenVK still open (it is the macOS 15 and
   fallback driver), and Mesa treats invalid usage as undefined behaviour.
2. **Venus in its own process** (ADR 0012 option 1): device memory as IOSurfaces
   or Mach ports across processes, a big change in both drivers' export paths.
3. **Check in vkr** (chosen): vkr is where guest input enters, it sees every
   call before either driver, and the driver's own format query already knows
   its limits, so vkr needs no Metal rules of its own.

## Decision

Option 3, in three patches, each with a build-time test case:

- `virgl-venus-linear-modifier-usage.patch`: the emulated LINEAR modifier's
  question keeps INPUT_ATTACHMENT; COLOR_ATTACHMENT is left out only where the
  format's optimal tiling renders (window buffers are linear colour images).
- `virgl-venus-image-limits.patch`: `vkCreateImage` and the queries that take an
  image description get vkr's changes to it (dma-buf handles, the LINEAR
  modifier) and then a check: the spec's shapes, known flag bits, and the
  driver's own `vkGetPhysicalDeviceImageFormatProperties2` for exactly that
  description (a new question without external memory or format lists).
  Binds must fit the memory and the image's memory types; layout queries name
  a subresource of the image; a query the device does not have is refused (vkr
  called a NULL entry point).
- `virgl-venus-view-limits.patch`: image views (ranges, 3D only of 3D, cube
  layers, a known format of the image's texel size), texel buffer views
  (inside the buffer, aligned, texel usage, at most `maxTexelBufferElements`)
  and sampler enums. Type pairs that live on both drivers are left alone.

Error codes: a refused create returns `VK_ERROR_FORMAT_NOT_SUPPORTED` (what the
format query gives for the same values; not in `vkCreateImage`'s list in the
spec, but vkr already returned it for modifiers, and guest Mesa passes it on).
A refused query zeroes only its main output (`VkMemoryRequirements`,
`VkSubresourceLayout`, `VkImageFormatProperties`; a sparse count of 0), and the
format queries also return `VK_ERROR_FORMAT_NOT_SUPPORTED`. Output structs
chained to it (`VkMemoryDedicatedRequirements`, `VkExternalImageFormatProperties`,
`VkSubresourceHostMemcpySize`) are not written and keep what vkr's decoder had
in that memory; the guest's Mesa caches the dedicated flags with the refused
requirements (follow-up #624). The guest makes
binds, views and samplers without waiting for an answer, so a refused one ends
the app's Venus context; the guest's Mesa then ends that app and the VM goes on.
The verdict depends only on the device and the description. QEMU's log names
the app, the call, the values and the limit at the 1st, 2nd, 4th ... refusal.

The cost: about 0.03 us of host queries per `vkCreateImage` (1.45 us through vkr
on KosmicKrisp, 10,000 creates), so no cache. The 0.03 us is the checks' two
host calls timed alone in a loop; a create without the checks (1.42 us) is the
difference, not a run with the checks off.

## Consequences

- vkr is the trust boundary for Venus on macOS. KosmicKrisp and MoltenVK stay
  unpatched; the KosmicKrisp report is a draft
  (work/upstream-drafts/kosmickrisp-linear-texture-abort.md).
- Covered: what the probe found at image create, bind, view, sampler and
  queries. Not covered, a follow-up: buffer bind ranges (GPU fault risk),
  pipelines and shader modules, render passes and framebuffers, descriptor
  writes, command encoding, vkr's `assert()`s (virgl is built with asserts on),
  NULL entry points of other commands a device was not made with (the
  amendment below covers buffer binds, the asserts and the entry points).
- Zink is now told that a linear render target with input attachments is not
  supported on KosmicKrisp and takes another path or fails with a GL error.
- `Tests/virgl/test-venus-image-limits.c` runs at every runtime build on the
  staged drivers; a new vkr path that hands a guest description to the driver
  needs a case there.
- Revisit option 2 when a crash class appears that a check in vkr cannot catch
  (inside shader compilation or command execution), or when KosmicKrisp can
  share memory across processes.

## What else vkr refuses (amendment, 3.2.15)

Lane `venus-robust` (#624). The 3.2.13 release's own libvirglrenderer, driven
through its public API as QEMU drives it, on its KosmicKrisp and MoltenVK (one
process per case, 3 identical runs, M4, macOS 27), showed that a program in the
VM could still end QEMU through vkr itself:

- **NULL entry points.** A device's entries follow MIN(the driver's version,
  the guest's instance `apiVersion`) and its extensions. On a 1.1 device
  without extensions 148 of 286 are NULL on KosmicKrisp (146 on MoltenVK),
  and 130 guest commands call such an entry without a check: QEMU called address 0 on every path (command buffer,
  generated create, query, queue, the MESA commands, a ring thread, nested
  streams). Two physical-device queries of extensions the device lacks did
  the same on KosmicKrisp; on MoltenVK the Vulkan loader's own entry ended the
  process (`abort()` after "ICD ... does not support").
- **Asserts.** Of vkr's 79 `assert()`s, four were reached by guest values: a
  semaphore resource id other than 0, one object id twice in one call, an
  OPAQUE_FD export on KosmicKrisp, and a ring whose monitor period was 0
  (vkr ended the context but kept the never-started ring, and the context's
  end asserted).
- **Buffer binds.** Both drivers returned `VK_SUCCESS` for a buffer bound past
  its memory's end, at a wrapping offset, unaligned or to smaller memory, and
  MoltenVK for a 1 TiB buffer on 64 KiB (the GPU could then read and write
  outside the memory); MoltenVK ended the process on a memory type the buffer cannot
  take. Both made memory from a 64 KiB resource with 1024 times its size and
  bound a buffer of that size to it.

Decisions, one patch each, each case in `Tests/virgl/test-venus-robust.c`:

- `virgl-venus-missing-entries.patch`: **missing entries are stubbed when the
  tables are loaded.** Every NULL entry of a physical device's or a device's
  table gets a stub of the entry's own type (the list `vkr_proc_entries.h` is
  generated from the tables and the PFN typedefs; a static assert stops the
  build when upstream adds an entry). A stub ends the context that the thread
  is dispatching, or logs and returns an error when vkr itself calls it. Chosen
  over a lookup in the dispatch layer: it is one place, costs nothing per
  command and covers vkr's own calls; a dispatch-layer table would need a
  hand-kept map of commands to the entries their handlers call. The loader's
  entries for the four physical-device queries of device extensions count only
  when the device lists the extension.
- **Entries are never NULL.** A test for a missing entry is
  `VKR_MISSING(vk, Name)`, never a NULL test; the runtime build fails on one in
  `src/venus`. #623's device-image queries keep answering zeros on a device
  without maintenance4/5.
- **The dispatching context is per thread** (`vkr_dispatching_context`):
  `vkr_context_submit_cmd` sets it around a stream and puts the old one back on
  every way out, a ring thread sets it for its life. A new thread that
  dispatches guest commands sets it too.
- `virgl-venus-guest-asserts.patch`: **the reached asserts are refusals**, with
  a log line, and the context ends; ids are checked for duplicates on a sorted
  copy before any driver call; memory with a Metal heap exports the heap; a
  ring that never started is not stopped. The other 73 asserts are internal
  and stay. The ring thread and ring monitor fixes only remove two asserts on
  thread creation: a guest that runs QEMU out of threads still ends it (QEMU
  aborts when its own thread creation fails), which stays open in #624.
- `virgl-venus-buffer-binds.patch`: **buffer binds follow the image rule**
  through one helper (`vkr_device_memory_bind_ok`: memory type, alignment, the
  end inside the memory), with each buffer's requirements asked once at
  create; sparse buffers are refused in `vkBindBufferMemory*`. **Memory made
  from a resource** may be no larger than the memory behind the resource, up
  to its host page's end (`vkr_resource.memory_size`, set at export); a larger
  one gets `VK_ERROR_INVALID_EXTERNAL_HANDLE`.

A refused bind or a missing entry ends the app's context (the guest's Mesa
sends most commands without waiting); the guest's Mesa then ends that app and
the VM goes on. The cost: one requirements query per `vkCreateBuffer`,
0.01 us of the 0.13 us a `vkCreateBuffer` + `vkDestroyBuffer` takes through vkr
on KosmicKrisp (0.14 us on MoltenVK; 10,000 creates, the query timed alone in a
loop, as for images).

Still open (#624): pipelines and shader modules, render passes, descriptor
writes, `vkCmd*` parameters, two rings creating or destroying one object at
once, thread exhaustion, duplicate frees, `vkQueueBindSparse` ranges, binds
that do not match a dedicated allocation, and the asserts in the render server
and proxy (the fence and ring ones are checked before them).
