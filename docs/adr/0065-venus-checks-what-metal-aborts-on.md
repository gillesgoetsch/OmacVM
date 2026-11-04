# 0065: Venus checks what the Mac's Vulkan driver aborts on

Status: accepted, built (`zink-abort`, 3.2.14), always on; amended in 3.2.15
(`venus-robust`, "What else vkr refuses" below), 3.2.18 (`venus-624`,
"Indices, counts and offsets" below) and 3.2.18 (`venus-624-c`, "Frees,
submits, dedicated memory, replies, threads and pass views" below). Amends
[0012](0012-venus-in-process.md). Notes, probes and the reviews:
work/tracks/zink-abort.md, work/tracks/venus-robust.md,
work/tracks/venus-624.md, work/venus-624/c/plan.md.

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
the app's Venus context and the VM goes on (in the 3.2.14 test rows the five
programs with such a call printed "alive" after it and exited 0).
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
  end asserted). A guest can also reach the two in `vkr_context.h` that add
  and remove an object, with two rings creating or destroying one id at once
  (a race; read, not probed). The ring monitor's needs a failed thread
  creation; the other 73 are internal. 79 = 4 reached + 73 kept + 1 thread
  exhaustion + 1 race (the add is one of the 4: one call naming an id twice).
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
  ring that never started is not stopped. The 73 internal asserts stay. The
  ring thread and ring monitor fixes only take thread creation out of the
  asserts: a guest that runs QEMU out of threads still ends it (QEMU aborts
  when its own thread creation fails), which stays open in #624. The two race
  asserts in `vkr_context.h` stay too: a guest can still reach them with two
  rings creating or destroying one id at once, open in #624.
- `virgl-venus-buffer-binds.patch`: **buffer binds follow the image rule**
  through one helper (`vkr_device_memory_bind_ok`: memory type, alignment, the
  end inside the memory), with each buffer's requirements asked once at
  create; sparse buffers are refused in `vkBindBufferMemory*`. **Memory made
  from a resource** may be no larger than the memory behind the resource, up
  to its host page's end (`vkr_resource.memory_size`, set at export); a larger
  one gets `VK_ERROR_INVALID_EXTERNAL_HANDLE`.

A refused bind or a missing entry ends the app's Venus context (the guest's
Mesa sends most commands without waiting) and the VM goes on. The cost: one
requirements query per `vkCreateBuffer`, 0.01 us of the 0.13 us a
`vkCreateBuffer` + `vkDestroyBuffer` takes through vkr on KosmicKrisp (0.14 us
on MoltenVK; 10,000 creates, the query timed alone in a loop, as for images).

Still open (#624): pipelines and shader modules, render passes, descriptor
writes, `vkCmd*` parameters, two rings creating or destroying one object at
once, thread exhaustion, duplicate frees, `vkQueueBindSparse` ranges, binds
that do not match a dedicated allocation, and the asserts in the render server
and proxy (the fence and ring ones are checked before them).

## Indices, counts and offsets (amendment, 3.2.18)

Lane `venus-624` (#624). What was left open above: pipelines and shader
modules, render passes and framebuffers, descriptor writes and `vkCmd*`
parameters. A probe through vkr's own dispatch on the M1 Max (Apple7, macOS
27.0.1; KosmicKrisp, MoltenVK, and MoltenVK with
`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1`, which encodes at
`vkEndCommandBuffer` what it otherwise encodes when QEMU submits; nothing
submitted; 3 runs) found that vkr passed all four classes on unchecked, and:

- **Guest values used as host memory addresses.** KosmicKrisp is built with
  `NDEBUG`, so Mesa's and its own asserts on indices are gone: push constants
  are copied to `push + offset`, `vkCmdSetViewport`/`SetScissor`,
  vertex buffers and descriptor sets are stored at the guest's first index,
  descriptor writes and copies at `binding offset + element * stride` in the
  set's memory, query reports read and zeroed at `firstQuery`,
  `vkCmdClearAttachments` writes a clear colour into an array of 8 on the stack
  at `colorAttachment`, a layout's binding array is sized by the largest
  binding number + 1 (0xffffffff wraps to 0), dynamic buffers are counted in a
  `uint8_t` into a 64-slot table, sets, layouts and pools are sized in 32-bit
  arithmetic, Mesa's `vk_pipeline_layout` and `vk_graphics_state` copy set
  layouts, push constant ranges, viewports, blend state, vertex input, sample
  and attachment locations into fixed arrays, and a secondary that executes
  itself recurses until the ring thread's stack ends. MoltenVK grows a vector
  to `offset + size` in 32 bits for push constants and reads query results and
  descriptor slots at guest offsets too. SIGBUS/SIGSEGV in 3 of 3 runs. Any
  Vulkan program in the VM reaches these through the normal API (the guest's
  Venus driver passes the values on; it reads its own layout only for sampler
  descriptors).
- **Enum values a switch does not know.** In release builds Mesa's and
  KosmicKrisp's `UNREACHABLE` is `__builtin_unreachable()`: compare ops, cull
  modes, blend factors and ops, logic ops, index types, bind points, descriptor
  types, query types, dynamic states, resolve modes and robustness behaviours
  outside the known values are undefined behaviour in the driver.
- **A legal app ended the VM.** KosmicKrisp told 32 multiview views and renders
  N views with a Metal vertex amplification count of N; Metal aborts on 9 to 32
  on Apple7 ("maxVertexAmplificationCount ... is not supported").
- **App bugs that aborted Metal or crashed a driver:** more than 8 colour
  attachments, blit and clear level ranges, a NULL sampler, a stage without a
  module, a blend state for 3 colours in a pass with 1 (MoltenVK).
- **GPU-side ranges:** copies, fills, indirect and vertex offsets, descriptor
  ranges and render areas past their resources were accepted when recorded;
  the GPU would read or write outside them when they run.
- **Shader compilation:** malformed SPIR-V (garbage, truncated, a huge id
  bound, a bad magic, a missing entry point) crashed both compilers.

Decision: vkr bounds every guest index, count, offset, stride and known enum
the driver uses to address host memory or a table, before the driver gets it,
against the device's limits (`struct vkr_limits`, read once per physical
device) and small tables of what objects were made with. Semantic validity
stays with the driver (this is not a validation layer), and values Vulkan
ignores are left alone: a resolve mode on an attachment without a view, a
colour attachment's stencil load op, a pipeline's sample locations while
sample locations are off (unless switched on at draw time, as Mesa then
copies them). Every refusal ends the app's Venus context with a log line
(`vkr_context_check`): the guest
records commands and makes these objects without waiting, so an error code
would be lost and the next use of the id would end the context anyway, with a
less clear line. Four patches, one per class:

- `virgl-venus-command-limits.patch`: `vkCmd*` parameters against the limits
  and the sizes of the buffers, images and query pools they name; query pools
  (a type the device has, 1 to 2^20 queries) and the host query calls; the
  enum values above where a command passes them; command buffer levels (only a
  primary executes secondaries, `VK_EXT_nested_command_buffer` is hidden);
  `vkCmdDrawMulti(Indexed)EXT` gets its entries' own size as the stride (the
  decoder packs the array).
- `virgl-venus-descriptor-limits.patch`: a refcounted table per set layout
  (shared with its sets and the pipeline layouts that use it, so a layout may
  be destroyed first); layouts, pools, variable counts, writes and copies
  (the spec's consecutive-binding rule, which skips bindings without
  descriptors; `nullDescriptor` for NULL handles, dynamic buffers too;
  ranges inside the buffer and the range limits, multi-planar views only
  where immutable YCbCr samplers sized the binding), pipeline layouts, and
  binds and pushes against them (one dynamic offset per dynamic buffer).
- `virgl-venus-render-pass-limits.patch`: attachment references, colour
  counts, dependencies, multiview info, framebuffers (the pass's attachment
  count, sizes within the limits), begins (clear values, imageless views,
  sample locations), dynamic rendering and inheritance. KosmicKrisp's
  `maxMultiviewViewCount` is told to the guest as the largest vertex
  amplification count Metal supports on the GPU (`vkr_metal_limits.m`, read
  once; 8 on the M1 Max), and view masks past it are refused at all five places
  one arrives (render pass multiview info, subpass description 2, rendering
  info, inheritance rendering info, pipeline rendering info). Correlation
  masks are not checked: no rule bounds them by the view count, and the
  drivers only copy them. MoltenVK renders 32 views and keeps telling 32.
- `virgl-venus-pipeline-limits.patch`: stages (one known bit each, code: a
  module, or SPIR-V chained into the stage with a size in whole words; the
  inline path skipped vkr's only shader check), specialization entries inside
  their data, creation feedback, dynamic states Mesa knows, vertex input,
  viewports, blend attachment counts equal to the subpass's colours, sample
  counts and locations, the subpass, and the enums above (fields a dynamic
  state replaces are left alone).

`app/runtime/Tests/virgl/venus-command-ledger.tsv` gives each of vkr's 140
`vkCmd*` handlers a verdict (checked, command-buffer state, values only,
stub, GPU-side); the runtime build fails when a handler has none, so a new
command in a virglrenderer update needs a decision. `test-venus-commands.c`
(222 cases, a legal-maxima group among them: every limit at its advertised
value must keep working) runs on KosmicKrisp, MoltenVK and MoltenVK with
prefilled command buffers at every runtime build. Against 3.2.15's vkr 147 of
the first 210 failed on KosmicKrisp and 134 on MoltenVK; with the patches all
pass.

The cost, through vkr's dispatch on the M1 Max (10,000 calls, medians of 3
runs): `vkUpdateDescriptorSets` 0.009 -> 0.017 us on KosmicKrisp and 0.021 ->
0.030 us on MoltenVK, `vkCmdBindDescriptorSets` 0.009 -> 0.018 / 0.035 ->
0.046 us, `vkCmdPushConstants` 0.009 -> 0.012 / 0.108 -> 0.110 us,
`vkCmdSetViewport` 0.005 -> 0.007 / 0.029 -> 0.032 us, `vkCmdDraw` 0.163 ->
0.165 / 0.022 -> 0.022 us.

The revisit trigger above ("a crash class inside shader compilation") has
fired: malformed SPIR-V crashes both compilers. It is answered with a check in
vkr, not with option 2. Four more patches, one per class, after the four above:

- `virgl-venus-command-state.patch`: each command buffer's state (recording,
  the open render pass or rendering with its subpass, colours and view mask,
  all cleared when it ends; its render pass and framebuffer by id and a serial
  given at create, never by pointer; the bound pipelines, conditional
  rendering). Commands on a buffer that does not record, draws outside a pass
  or without a graphics pipeline, dispatches inside a pass or without a
  compute pipeline, clears outside a pass or past its colours, a pass begun
  inside another, `vkCmdNextSubpass` past the last subpass, ends without their
  begin, a next subpass or an end after the app destroyed the pass's render
  pass or framebuffer (vkr and Mesa's `vk_render_pass` read both there; such a
  command buffer is invalid in Vulkan), queries (begin and end) and
  timestamps in a multiview pass past the pool (one query per view), and
  secondaries that still record or do not match the primary's pass end the
  context. KosmicKrisp and MoltenVK with prefill crashed on the probed ones.
- `virgl-venus-spirv-scan.patch`: a structural scan of every module and of
  SPIR-V chained into a stage (`vkr_spirv.c`, no driver): header, every
  instruction inside the code, the ids it reads inside the bound (at most
  2^20; KosmicKrisp allocates per id), entry point names that end. Pipelines
  need their stage's entry point by name and execution model, a workgroup
  size after specialization (`LocalSize`, `LocalSizeId` or the
  `WorkgroupSize` built-in) inside the device's limits, and the descriptor
  sets and bindings that the functions their entry point reaches through
  calls use in their layout. Entry point interfaces are not used for this:
  glslang lists unused descriptors there from SPIR-V 1.4, which a valid layout
  need not have. The scan is fuzzed on the CPU alone under the sanitizers
  (`Tests/virgl/fuzz-venus-spirv.sh`, CI and every runtime build).
- `virgl-venus-copy-regions.patch`: copy, blit and resolve regions name an
  aspect the image has and texels inside the level (a plane's share, block
  formats in whole blocks); buffer-image copies name bytes inside the buffer
  up to their last texel block (overflow-checked). `vkr_format_extent.h` is
  generated from the Vulkan registry like `vkr_format_table.h`.
- `virgl-venus-pipeline-formats.patch`: render pass attachments and the
  formats of a pipeline's or a secondary's dynamic rendering are known formats
  with the colour or depth/stencil attachment feature on the host (an unknown
  format ended both drivers, R64G64B64A64 ended KosmicKrisp).

`test-venus-commands.c` has 281 cases now (59 for these classes, legal
maxima among them: a mirrored blit, a copy that ends at the buffer's last
byte, the largest workgroup, a shader with an unused descriptor set the layout
lacks). With the four patches above all 40 refused new cases fail on
KosmicKrisp, MoltenVK and MoltenVK with prefill (the process ended in 8, 6 and
12 of them); with 3.2.15's vkr 187, 174 and 174 of the first 260 failed; with all
eight patches every case passes (3 of 3 runs, 0 GPU restarts). `vkCmdDraw`
through vkr costs 0.169 -> 0.173 us on KosmicKrisp and 0.025 -> 0.029 us on
MoltenVK (medians of 3 runs). The scan runs once per `vkCreateShaderModule`;
the fuzz test's largest module (2.9 million words, 131,072 functions) scans in
0.02-0.03 s and its call graph walks in 0.03-0.05 s (each build log prints
them).

A full validator (SPIRV-Tools) would be a new pinned dependency and a cost
per module; it is added only if a crash past the structural scan is found.
Option 2 is revisited if such crashes keep coming, or when KosmicKrisp can
share memory across processes.

Still open (#624): MoltenVK reads vertex buffers,
descriptor sets and push constants a draw or dispatch uses but the app never
set when it encodes them (at submit in QEMU; a test without them ended
MoltenVK's process at `vkEndCommandBuffer` with prefilled command buffers);
objects destroyed while a recorded or pending command buffer still uses them
(vkr checks only the open pass's render pass and framebuffer, at its next
subpass and end; MoltenVK encodes at submit from stored pointers, KosmicKrisp's Metal 4 command
buffers do not retain their resources); what the GPU does when commands run
(robustness off, hangs, huge dispatches); driver bugs on valid input; two rings
on one object at once; thread exhaustion; huge descriptor pools (each pool size
is bounded at 2^24 against overflow, not against memory); the other items
listed in the amendment above.

## Frees, submits, dedicated memory, replies, threads and pass views (amendment, 3.2.18)

Lane `venus-624-c` (#624, after #643 and #644). A probe of the drivers
alone on the mini's M4 (Apple9; KosmicKrisp and MoltenVK of that runtime;
objects, allocations and frees only, each case in its own process, plainly and
under libgmalloc, which unmaps freed memory) and reading Mesa at the
KosmicKrisp pin, MoltenVK 1.4.2 and the guest's Mesa 26.2.5 found more ways a
program in the VM reached QEMU's memory, several of them with legal input:

- **Frees.** KosmicKrisp destroyed a descriptor set named twice in one
  `vkFreeDescriptorSets` twice (SIGSEGV), Mesa's runtime put a command buffer
  of another pool into the pool that freed it (SIGSEGV when that pool was
  destroyed), and KosmicKrisp's descriptor pool took over another pool's
  memory range, which its next set then used.
- **Submit chains.** MoltenVK writes the values of a chained
  `VkTimelineSemaphoreSubmitInfo` by that struct's own counts into arrays of
  the submit's semaphore counts (`MVKQueue.mm`). Vulkan ignores the values when
  only binary semaphores are named, so a legal submit wrote guest values past a
  host heap array. Mesa reads the values and `VkDeviceGroupSubmitInfo`'s
  indices by the submit's counts. vkr reads the first struct of a type and
  MoltenVK's loops keep the last, so a second value struct would go past any
  check of the first.
- **Dedicated memory.** MoltenVK keeps the image or buffer memory was made for
  and writes to it when the memory is freed: an image destroyed before it was
  bound (legal) left a dangling pointer, written after its free. It also
  accepted an `ALIAS_BIT` image on memory dedicated to another image without
  counting it, and locked the freed memory's mutex when that image went later.
  KosmicKrisp ignores dedicated allocations. A second dedicated struct in the
  chain would name another target for MoltenVK than for vkr.
- **Consecutive descriptor updates.** KosmicKrisp writes a whole write at its
  first binding's offset + element * that binding's stride, and MoltenVK with
  that binding's layout, but consecutive bindings of one type can differ in
  size (immutable YCbCr samplers of 2 or 3 planes, a mutable binding as wide as
  its largest type): a legal update over a 3-plane and a 1-plane binding wrote
  past the set. The "same type stays inside the set" argument of the amendment
  above did not hold for these.
- **Pass views.** Mesa's `vk_render_pass` reads the open pass's image views at
  its begin, each next subpass and its end, KosmicKrisp a rendering's at its
  end (its resolves): a view destroyed while recording was freed memory there.
- **Replies.** An output struct chained to a query is decoded with only its
  `sType` and `pNext` written. One vkr refuses (it zeroes the main struct) or
  one the driver does not fill went back with the decoder's old bytes (other
  commands' data, host pointers).
- **Threads.** Nothing bounded the threads guest calls make (a render worker
  and a fence thread per context, a thread per ring and the ring monitor, a
  sync thread per queue). macOS allows 4096 per process, and QEMU ends when it
  cannot make one of its own. A failed context create also never joined its
  render worker (the proxy destroyed context 0).
- Size-0 allocations hurt neither driver. A legal texel buffer view of 0
  elements (`VK_WHOLE_SIZE` with less than a texel left) aborts both (Metal:
  width 0); vkr keeps refusing it.

Decision: six more patches after `virgl-venus-pipeline-formats.patch`, one
concern each, and two changes in the earlier patches:

- `virgl-venus-descriptor-limits.patch` (changed): an update over several
  bindings reaches the driver as one write or copy per binding
  (`vkr_set_walk_*`), each part checked in its own binding (type, mutable type
  list, YCbCr planes); writes, copies on both sides and push descriptors. An
  update may also start past its first binding, as Vulkan allows
  (VUID-VkWriteDescriptorSet-dstArrayElement-00321); the earlier `first > room`
  refusal is gone. A refused NULL buffer now says "no buffer (the device's
  nullDescriptor is off)".
- `virgl-venus-pipeline-formats.patch` (changed): the attachment format
  features only for attachments a subpass uses (Vulkan puts those rules on the
  references); an attachment no subpass uses needs only a known format.
- `virgl-venus-submit-counts.patch`: timeline value arrays made exactly the
  submit's length (extra values dropped, missing ones and an absent array 0:
  they count only for timeline semaphores, where the call was invalid anyway);
  a device group with other counts refused (VUIDs 00082 to 00084);
  `vkQueueBindSparse` on a family without `SPARSE_BINDING` refused (all of
  them on both Mac drivers); a chain that names a structure type twice
  refused in both calls (VUIDs `VkSubmitInfo-sType-unique`,
  `VkBindSparseInfo-sType-unique`). The decoder takes only a few types in such
  a chain, so the walk meets a repeat within those few steps, however long the
  chain is.
- `virgl-venus-pool-frees.patch`: pooled objects keep their pool; a free
  checks every handle (of this pool, named once; a stamp per call, no
  allocation) before any is freed.
- `virgl-venus-dedicated-memory.patch`: memory made for one image or buffer is
  linked to it (a record shared by the object and its memories, under a device
  mutex never held across a driver call). Only that object binds to it, at
  offset 0 (VUIDs 02628, 10926, 01508, 10925; no Mac driver has
  `dedicatedAllocationImageAliasing`, the exception of 02629). One exception,
  on KosmicKrisp alone: an `ALIAS_BIT` image may bind to memory dedicated to an
  `ALIAS_BIT` image, at offset 0. An app that binds a swapchain image with
  `VkBindImageMemorySwapchainInfoKHR` gets that from guest Mesa (a second image
  of the swapchain's create info, bound to `wsi_common_get_memory`, which is
  dedicated to the swapchain's own image), and KosmicKrisp ignores dedicated
  allocations. On MoltenVK that bind stays refused: it ended the process
  (`x-dedicated-alias`), so such an app ends there. A dedicated struct chained
  twice (VUID `VkMemoryAllocateInfo-sType-unique`) and a target of another
  device are refused at the allocation. When the app destroys the object
  first, the driver's destroy waits for the last of that memory: memory first,
  then the object, also when the context ends (`vkr_device_object_destroy`
  keeps the same rule).
- `virgl-venus-temp-zero.patch`: the decoder's temporary memory is zeroed for a
  command with a reply (the flag is set per command in `vn_dispatch_command`);
  `vkCmd*` never reply.
- `virgl-venus-thread-budget.patch`: one process-wide count of those threads,
  1024 at most (`OMACVM_VENUS_THREADS` for tests), taken before each is made
  and given back at its join; past it the call fails cleanly (no context,
  `vkCreateRingMESA` ends its context, `vkCreateDevice` returns
  `VK_ERROR_OUT_OF_HOST_MEMORY`), with a log line. Contexts also stop at a
  sixteenth of the open-file limit read at run time (each takes at most 8
  files; QEMU raises its soft limit to `OPEN_MAX`, 10240, on macOS, so the
  render server's 256 workers bound them there). A failed create now destroys
  its server context by its id.
- `virgl-venus-pass-views.patch`: image views get the serial render passes and
  framebuffers have (`vkr_object_next_serial`, moved to `vkr_common.c`); a
  framebuffer keeps its views by id and serial, an imageless begin and
  `vkCmdBeginRendering` leave theirs with the command buffer until the pass
  ends. A begin whose framebuffer view was destroyed, and a next subpass or end
  after one of the open pass's views was, end the context (the command buffer
  is invalid). A resolve view Vulkan ignores (no resolve mode, or no view) is
  not kept, and the driver gets NULL there: destroying it is legal, and
  MoltenVK reads it whatever the mode.

`virgl-venus-render-pass-limits.patch` also refuses a framebuffer or imageless
begin with a count and no array, which the decoder lets through: vkr read
address 0 there.

Still open (#624): an app that binds a swapchain image through
`VkBindImageMemorySwapchainInfoKHR` on MoltenVK (above; a bind MoltenVK counts
would need a change in MoltenVK); structure types chained twice on the calls
other than these (`vkBindImageMemory2`'s plane info, `vkCreateImage`'s stencil
usage: vkr reads the first, MoltenVK's loops the last; a check in the decoder
would cover every chain at once); two rings on one object at once (vkr looks an object up
and uses it after its object mutex is released; a per-context read-write lock
or per-object references need a measured cost and a test hook first, and must
not deadlock `vkWaitRingSeqnoMESA`, which blocks the context's own dispatch
until a ring reaches a seqno, or nested `vkExecuteCommandStreamsMESA`);
objects destroyed under a recorded or pending command buffer (MoltenVK encodes
at submit from stored pointers; KosmicKrisp also reads a pass's resolve views
where it splits the pass inside: barriers in multisampled passes, compute in a
pass, its flushes); a null descriptor in place of a 0-element texel view where
the app enabled `nullDescriptor`; the caps that guard host memory rather than
addresses (pool sizes, sets and layouts above 2^24 descriptors, SPIR-V id
bounds above 2^20, workgroup sizes built with `OpSpecConstantOp`, more than
2^20 queries, binding numbers from 2^16); a pipeline's colour attachment count
when blend enable, equation and write mask are all dynamic (no Mac driver has
those states; Mesa writes by the count, so the bound stays); what the GPU does
when commands run; driver bugs on valid input; full SPIR-V validation;
option 1.

`test-venus-commands.c` has 324 cases now (43 for these), `test-venus-robust.c`
two more (a refused query's chained output, an output struct the driver does not
write), `test-venus-threads.c` drives each thread site and the context bound to
its refusal under a small budget, and `test-venus-descriptor-walk.c` checks the
walk against a plain model of Vulkan's rule (100,000 random updates per seed).
On the mini's M4 with #644's vkr and these tests, 17 of the new cases fail on
KosmicKrisp, MoltenVK and MoltenVK with prefill (the process ended in 5, 2 and
7 of them), and under libgmalloc 12 and 15 of the 24 cases run there then (6 and
5 ended); the two robust cases fail on both. `d-planes-ok`, `d-mutable-ok` and
`c-push-set-split-ok` pass before too, even under libgmalloc: the driver's
write past the set stays in its pool's memory there, so they guard the split
rather than show the overrun. The 9 cases added last (a struct chained twice on
a submit, a sparse bind and an allocation, a target of another device, no array
with a count on a framebuffer and a begin, an ignored resolve view, two
`ALIAS_BIT` images) fail 9, 8 and 8 on the first head of these patches (bebb5bda)
on the three, the process ended in 2 each; under libgmalloc 4 and 3 of the 27
cases (MoltenVK's write ended the process in all 3). With these patches every
case passes 3 of 3 on all three, under libgmalloc too, the walk at seeds 1, 2,
3, 77 and 12345, the SPIR-V fuzz at the same seeds (0 failures), 0 GPU restarts. Medians of 3 runs
of 10,000 calls (A B B A A B): a `vkUpdateDescriptorSets` of 1000 writes costs
8.1 -> 11.0 us on KosmicKrisp and 13.8 -> 17.4 us on MoltenVK (about 3 ns a
write), one write 0.013 -> 0.016 and 0.023 -> 0.026 us, a
`vkCmdBeginRenderPass` + `vkCmdEndRenderPass` 10.5 -> 10.4 and 0.080 -> 0.103
us; `vkCmdDraw`, `SetViewport`, `PushConstants`, `BindDescriptorSets` and
`PipelineBarrier` stay within their noise, and so does a command with a reply
through the decoder (0.059 -> 0.055 and 0.034 -> 0.035 us).

## Rings of one app, and views under a command buffer (amendment, 3.2.19)

Lane `open-1102/venus` (#624's two open points above). Read in vkr at
61c2de6f, guest Mesa 26.2.4, KosmicKrisp at the runtime's pin and MoltenVK
1.4.2; the architecture review (`work/tracks/venus-624.md`, 2026-11-02 07:56)
replaced the read-write lock this ADR named with what follows.

**Two threads on one object.** Each ring has its own thread, and the context's
own stream runs on QEMU's (in QEMU `on_worker_thread` is false). vkr let go of its table lock right after
a lookup, so one ring could destroy an image, buffer, layout or pipeline cache
another ring's call was reading (freed memory in vkr and the driver), two rings
could record into one command buffer, QEMU's blob export read a memory a ring
freed (`vkr_context_create_resource_from_device_memory`), and two creates of one
id could both pass the id check (the second hit `vkr_context_add_object`'s
assert; release builds keep asserts). A read-write lock would not cover two
readers on one command buffer or pool, would stall a destroy on the main ring
behind every compile on another ring, missed the export, and its read side was
taken again by nested `vkExecuteCommandStreamsMESA`.

Guest Mesa 26.2.4 sends only pipeline creation and pipeline cache reads to a
second ring (`vn_tls_get_ring`, synchronous there); each VkInstance is its own
context. So:

- `virgl-venus-ring-lock.patch`: one dispatch lock per context. A ring takes it
  per batch it reads, the context's stream per command (not for the ring and
  reply-stream commands, which touch no object), QEMU's calls per call (a device
  memory's blob, a resource's removal, a fence on a queue); nested streams keep
  it (`vkr_locked_context`, thread-local). `vkWaitRingSeqnoMESA`,
  `vkWaitVirtqueueSeqnoMESA` and `vkDestroyRingMESA` give it up while they wait
  for or join a ring. `vkCreateGraphicsPipelines`, `vkCreateComputePipelines`
  and `vkGetPipelineCacheData` give it up while the driver runs them, with the
  objects they name pinned (device, cache, layout, render pass, shader modules,
  base pipeline, libraries; a count under the lock); the pins go before the
  answer or the ring position reaches the guest. Destroying a pinned object, or
  the instance while a pipeline call runs, is refused: the spec's Threading
  Behavior and Object Lifetime rules do not let an app destroy what another
  thread's call uses, and a legal app never sees it (its create returned before
  it can destroy). An id the table has already is refused when it is added (the
  guest named it twice); pipelines made while the lock was given up are checked
  for that and destroyed again.
- Not covered: a call that blocks in the driver (a fence or semaphore wait
  without end) holds its app's lock and stops that app's other rings and its own
  stream. QEMU's thread takes the same lock for that app's fences, blobs and
  resource removals, so a ring stuck under it in a `vkWaitForFences` or
  `vkWaitSemaphores` with a guest-chosen timeout (`vkr_queue.c`) stops QEMU's
  thread at that app's next fence or blob, and with it the whole VM. Not a new
  kind of hang: the context's stream and a teardown joining a stuck ring could
  already do it. Other apps' calls do not take this lock.

**Views read after their destroy.** KosmicKrisp reads a pass's views (and a
view's image: its views do not keep it) where it splits a pass while
recording: a barrier with more than one sample or a split, a draw after a color
map or sample location change, the store ops at the end. MoltenVK's recorded
commands keep raw image view, framebuffer and render pass pointers, and with its
default synchronous submits it reads them at `vkQueueSubmit`.

- `virgl-venus-command-holds.patch`: a command buffer holds the image views, the
  framebuffers and render passes its render pass begins, dynamic renderings and
  a secondary's inheritance named, until the driver let go of what it recorded
  (a reset, a new begin, a free, a pool reset or destroy, the context's end; the
  pool's destroy now lets the driver free its command buffers first). An image
  view holds its image. Destroying a held object is legal (the command buffer
  becomes invalid): the id leaves the table at once, and the driver's destroy
  waits for the last holder (a zombie on its device). Dedicated memory still goes
  before its image; a device's teardown frees its pools, which lets go of its
  zombies, before the device. Holds stay within one device (a begin naming
  another device's object, or a view of another device's image, is refused:
  the commonparent VUIDs, VUID-vkCreateImageView-image-parent). The pass-views
  checks at the begin, a next subpass and the end stay.
- Not covered: views reached only through descriptor sets (probe on MoltenVK: a
  stale set bound, nothing dispatched, submitted: no read, plain and under
  libgmalloc), what a pending KosmicKrisp command buffer reads on the GPU
  (Metal 4 command buffers keep no texture alive), and secondaries (next
  paragraph).

**Secondaries read after their free (#676).** MoltenVK keeps raw secondary
pointers in `MVKCmdExecuteCommands` and reads them when it encodes the primary
at `vkQueueSubmit`; a free hands a command buffer back to its pool (reset), the
pool's destroy deletes it. KosmicKrisp replays a secondary into the primary
while recording.

- `virgl-venus-secondary-holds.patch`: a primary holds the secondaries
  `vkCmdExecuteCommands` named, as it holds its views (same release points). A
  freed held secondary leaves the table and stays in the driver as a zombie
  that holds its pool; the last holder frees it into the pool. A destroyed pool
  with a held command buffer frees its other command buffers one by one, leaves
  the table and waits for its last zombie; without one it goes at once, as
  before. `vkFreeCommandBuffers` hands the driver NULL for a held one. The
  device's teardown destroys pools this way, and frees zombies left over
  holders first (command buffers, then views, framebuffers and passes, then
  images, then pools).

`virgl-venus-test-pause.patch` (first, test only, NULL in QEMU) stops a call
between vkr's reads and the driver, so a build without the fix runs the same
tests. `test-venus-commands.c` has 344 cases now: 10 `t-` cases with a real ring
beside the context's stream (destroys under a paused pipeline create and cache
read, a duplicate id, a destroy, a recording and a memory free beside a paused
call, a nested wait, a destroy beside a compile, a teardown), 9 held-view cases
and the probe; `--ring-time` times calls through a ring and the stream.

On the mini's M4 with the hook alone, the three destroy-under-a-pipeline-call
cases ended the process (SIGSEGV) on KosmicKrisp and MoltenVK, plainly and
under libgmalloc; the duplicate id hit the assert; the destroy, recording and
memory free beside a paused call did not wait (SIGSEGV on KosmicKrisp and under
libgmalloc); MoltenVK's submit of a command buffer whose view was destroyed
ended the process; KosmicKrisp's barrier in a multisampled pass read the freed
resolve view under libgmalloc (`kk_get_attachment_store_op` from
`kk_CmdPipelineBarrier2`). The mini's MoltenVK-with-prefill run before the fix
was stopped before the `t-` cases; on the M1 Max that run has the three destroy
cases end the process (SIGSEGV), the duplicate id the assert, and the other
three not wait, and passes with the fix. The legal held cases and the
no-deadlock cases pass before too. With the patches the 20 new cases pass where
they run: 20 on MoltenVK plain and under libgmalloc, 18 on KosmicKrisp plain
and under libgmalloc (the held submit and the probe are MoltenVK-only and skip),
12 on MoltenVK with prefill (it commits at a reset and encodes at the end, so the
7 held-view cases and the probe skip); every case of the file once: 344 ok
(skipped among them: 4 on KosmicKrisp, 13 on MoltenVK, 21 with prefill), 47
under libgmalloc. Without the give-up in `vkWaitRingSeqnoMESA` the nested-wait
case deadlocks. On the M1 Max (Apple7, KosmicKrisp new there) the runtime's
build runs them all: 344 of 344 on KosmicKrisp, MoltenVK and MoltenVK with
prefill, 45 of 45 under libgmalloc. Timing there (A B B A A B, medians of 3, the
hook-only build against this one, no VM or CI job at the start, bench lock):
per call in microseconds, KosmicKrisp `vkCmdDraw` 0.168 and 0.168, 1000
descriptor writes 15.86 and 15.70, a render pass begin and end 12.78 and 12.69;
MoltenVK `vkCmdDraw` 0.027 and 0.027, a render pass begin and end 0.147 and
0.185 (the holds), a call with a reply through the context's stream 0.084 and
0.092; `vkCmdDraw` through a ring beside a compile ring 0.317 and 0.313
(KosmicKrisp), 0.284 and 0.298 (MoltenVK). In a
4 GB test VM there (guest Mesa 26.2.4), vkcube, vkmark, Zink, rusticl, Chromium's
WebGPU matmul and WebGL Aquarium show no refusal line, and a guest program
through its own driver ends only itself: a free through another pool and a
layout destroyed while another thread compiled with it are refused, vkcube beside
it keeps drawing. Through guest Mesa a view destroyed mid-recording reaches QEMU
before the recorded commands (Mesa sends a command buffer's commands when it
flushes them), so that begin names a gone view and the decoder ends the context;
the holds matter for commands QEMU already has. The dEQP-VK subset made the M1's
GPU restart (firmware-detected lockup, timeline semaphore cases with
tessellation and geometry stages) on 3.2.18 and this branch alike; it was
stopped there (STANDARDS 14) and stays to compare on an M4.

The secondary holds have 7 `c-state-secondary-held-` cases (a primary executes
a secondary that records one barrier; the secondary is freed, or freed and its
pool destroyed, then the primary is submitted, reset or freed, or both share a
pool, or the context ends; a free after the primary's reset leaves no zombie).
On the M1 Max (virgl-only builds of #673's head and this one, the case file of
this one, drivers of the 3.2.16 test app): before, 6 of 7 fail on KosmicKrisp,
MoltenVK and MoltenVK with prefill, plainly and under libgmalloc (the freed
secondary goes at once: no zombie), and MoltenVK under libgmalloc ends the
process (SIGSEGV) in the submit of the primary whose secondary's pool was
destroyed; plain MoltenVK and KosmicKrisp submit it without a crash. After, 7 of
7 on all five; the whole file (`run-venus-limits.py`) 351 ok on KosmicKrisp (4
skipped), MoltenVK (13) and with prefill (21), 52 under libgmalloc on both, no
teardown zombie line, no GPU restart.

## A structure type twice in a chain (amendment, 3.2.20)

Lane `v624-rest` (#624's "structure types chained twice on the calls other than
these" above). Read in vkr at #683's head (9462653d), Mesa e5f06878 (KosmicKrisp,
the runtime, the guest's Venus driver) and MoltenVK 1.4.2.

vkr's checks read the first struct of a type (`vkr_find_struct`); the drivers
read the last. Mesa's `vk_common_CreateRenderPass` (KosmicKrisp) keeps the last
`VkRenderPassMultiviewCreateInfo` and reads its masks for every subpass;
MoltenVK's `vkCmdBeginRenderPass` keeps the last
`VkRenderPassAttachmentBeginInfo`, whose views vkr had not checked or held. Both
drivers keep the last of others too (plane info, stencil usage, vertex
divisors, ycbcr, border and reduction info). Every struct concerned has a
`VUID-<struct>-sType-unique` rule; the exceptions some allow (Metal export and
import structs) are not in venus-protocol, so the decoder ends the context on
them first. The guest's Venus driver keeps one slot per type when it rewrites a
chain, so legal input never reaches vkr with a repeat.

- `virgl-venus-chain-repeats.patch` (last in the series): `vkr_chain_repeat`
  compares each struct with the ones before it and stops at the first repeat
  (at most the known types squared). Every chain a vkr check reads goes through
  it first, through its call's refusal path: image create info (also the
  `vkGetDeviceImage*` queries; before vkr's own fixes), image binds, image
  memory requirements, samplers, buffers (before vkr's fixes) and buffer
  views, descriptor set layouts, writes (also push descriptors), set
  allocation and pools, render passes (v1, v2 and each v2 subpass), begins,
  framebuffers, a secondary's inheritance, dynamic rendering, shader stages
  (vkr scans the first chained SPIR-V only), graphics pipelines with their
  vertex input, multisample and color blend states, compute pipelines. The
  text names the type: "structure type 1000053000 twice in the chain of
  VkRenderPassCreateInfo".
- Left alone: `VkDeviceCreateInfo` (repeats of `VkDevicePrivateDataCreateInfo`
  are legal; MoltenVK sets each feature from every struct in turn, so the last
  wins, Mesa ORs them; vkr reads robustness2's `nullDescriptor`, which MoltenVK
  refuses in any struct and Mesa then has on; maintenance6, which MoltenVK's
  NULL index buffer path does not need; texel buffer alignment, which no
  offset ends the process on), the image format query (vkr changes its first
  external info: a repeat asks the driver about DMA_BUF, unsupported), views
  (vkr reads nothing in their chains), output chains, and vkr's own ring and
  queue chains.

A check in the decoder (this ADR's earlier note) would also refuse the legal
repeats of `VkDeviceCreateInfo`, and it cannot say which chain a check reads;
one call per checked chain keeps the exceptions in view.

Tests: 25 cases in `test-venus-commands.c` (21 `-repeat-` cases that must be
refused, 4 `-two-types-ok` controls), 6 `repeat-` cases in
`test-venus-image-limits.c` (5 refused, 1 control); the rows below ran them
beside r-ok, r-mv-legal-9, r-fb-fewer, d-ok, p-gfx-ok, c-inherit-ok, opt-2d and
bind-disjoint-planes-ok (39 cases a run). On the M1 Max (virgl-only builds of
9462653d and of this one, this one's test files, drivers of the 3.2.18 test app,
3 runs each on KosmicKrisp, MoltenVK, MoltenVK with prefill and both under
libgmalloc): before, every refusal case works or ends the process:
r-repeat-multiview ends it on KosmicKrisp (SIGABRT, Metal), r-repeat-multiview-
short on both drivers (SIGBUS: Mesa and MoltenVK read the second struct's one
mask for both subpasses, into a guard page), r-repeat-attachment-begin on
MoltenVK with prefill (SIGSEGV when it encodes); after, all 39 as expected on
all five, no crash report. The whole file (`run-venus-limits.py`) on this
build: 376 ok on KosmicKrisp (4 skipped), MoltenVK (13) and with prefill (21),
55 under libgmalloc on both, the image file 113 on both, no GPU restart.
KosmicKrisp timing (20000 calls, A B B A): `vkUpdateDescriptorSets` 0.024,
0.024, 0.025, 0.024 us; a render pass begin and end 13.82, 13.32, 13.29,
13.55 us: no change outside the noise.

## Values Vulkan ignores (amendment, 3.2.20)

Lane `v624-batch` (#624's batch after #687). Read in vkr at #687's head
(e66b77c5), Mesa e5f06878, MoltenVK 1.4.2 and validusage.json 1.4.363; every new
value first went straight to both drivers on the M1 Max (no vkr, nothing
submitted, 3 runs on KosmicKrisp, MoltenVK, MoltenVK with prefill and both under
libgmalloc; raw in work/v624-batch/probe/out).

- A whole-size texel view with less than one texel after its offset is legal
  (`VUID-VkBufferViewCreateInfo-offset-00925`, `-range-04059`), and both drivers
  end the process on it in Metal ("MTLTextureDescriptor has width of zero":
  KosmicKrisp at the create, MoltenVK at the descriptor write). So it never
  goes to them: with nullDescriptor on, vkr makes the view without a driver view
  (handle `VK_NULL_HANDLE`), and the decoder writes a null descriptor wherever
  the guest names it (`VUID-VkWriteDescriptorSet-descriptorType-02994/02995`);
  a view of no texel reads 0, as a null descriptor does. The format, usage,
  offset and alignment checks still come first. Such a view is freed without
  `vkr_buffer_view_from_handle`, which asserts a driver handle. MoltenVK has no
  nullDescriptor (it refuses a device asking for it), so there the view stays
  refused, now with its reason.
- A pipeline's vertex binding stride is not checked while the stride is dynamic
  (`VUID-VkVertexInputBindingDescription-stride-00619` does not apply); the
  stride used is `vkCmdBindVertexBuffers2`'s, which vkr bounds. Both drivers take
  a pipeline stride past the limit then, also with a draw recorded after a
  `vkCmdBindVertexBuffers` without strides.
- A color blend state needs its array and a count equal to the colors wherever
  Vulkan reads them. vkr let a NULL array through always, and any count with
  the three dynamic blend states set, features or not. A NULL array with
  nothing dynamic ended the process on both drivers (Mesa's
  `vk_color_blend_state_init`, MoltenVK's `addFragmentOutputToPipeline`), and
  with the three dynamic on MoltenVK. Now the array counts as ignored only with
  `COLOR_BLEND_ENABLE`, `EQUATION`, `WRITE_MASK` and `ADVANCED` dynamic
  (`VUID-VkPipelineColorBlendStateCreateInfo-pAttachments-07353`), the count
  with the first three and `ADVANCED` too when advancedBlendCoherentOperations
  is on (`VUID-VkGraphicsPipelineCreateInfo-renderPass-07609`, `-06055`), each
  only with its extendedDynamicState3 feature on (`-07378`, `-07379`, `-07380`,
  `-07386`). Neither Mac driver has these features today. The whole state stays
  ignored with rasterization statically off, for a library without fragment
  output and without colors (both drivers take a NULL array there, and the
  guest's Venus driver drops such a state itself).
- Dropped: `attachmentCount` past `maxColorAttachments` with the blend states
  dynamic. Those states need the features (neither driver has them), and a
  count of 9 makes MoltenVK crash and Mesa write past its 8-entry array.
- Refusal lines print a buffer range as "16 bytes at 0 of a 64-byte buffer",
  "the whole size at 0, no buffer", not 18446744073709551615 and "of 0"; the text
  is made only on a refusal.

Tests: 18 cases in `test-venus-commands.c` (`case_ignored`) and `tview-empty` in
`test-venus-image-limits.c`; five run under libgmalloc too. On the M1 Max
(virgl-only builds of e66b77c5 and of this one, this one's test files, drivers
of the 3.2.18 test app, 3 runs in the five modes): before, 15 cases fail on
KosmicKrisp and 10 on MoltenVK: the view and stride cases are refused, the
NULL-array cases end the process (SIGSEGV), the count-past case works (1 of 3
runs a SIGSEGV on MoltenVK, also with prefill), and the texts show
18446744073709551615. After, all 25
listed cases as expected in every mode, no crash report. The whole file
(`run-venus-limits.py`) on this build: 394 cases on KosmicKrisp (4 skipped),
MoltenVK (19) and with prefill (27), 60 under libgmalloc on both, the image file
114 on both, no GPU restart.

## State a draw or dispatch never set (amendment, 3.2.20)

Lane `v624-unset` (#624, after #690). MoltenVK reads some bound state only when it
encodes a command buffer: at `vkQueueSubmit` in QEMU, or at `vkEndCommandBuffer`
with prefill. First every unset case went straight to both drivers on the M1 Max
(Apple7), with no vkr and robust buffer access on: 3 runs each on KosmicKrisp,
MoltenVK and MoltenVK with prefill, each also under libgmalloc, 900 runs, 0 GPU
restarts (raw in work/v624-unset/out).

- A set the bound shaders use that was never bound: MoltenVK SIGSEGV in
  `bindMetalResources` (<- `prepareDraw` / `prepareComputeDispatch`, a NULL set
  slot). That happened at 18 of 18 plain submits (graphics set 0, graphics set 1
  with only set 0 bound, compute set 0). With prefill it crashed at the end or the
  submit, depending on the heap.
- An indexed draw without an index buffer: MoltenVK SIGSEGV in
  `drawIndexedPrimitives` (<- `MVKCmdDrawIndexed::encode`, a nil Metal buffer). That
  happened at 6 of 6 plain submits and 6 of 6 prefill ends. A NULL index buffer
  bound with maintenance6 works in all four MoltenVK modes.
- KosmicKrisp crashed in none. No driver crashed on these: a set bound with
  another layout, descriptors never written, push constants never set (with and
  without maintenance4), vertex buffers never bound.

So vkr now keeps, per command buffer, the sets bound at each bind point since
`vkBeginCommandBuffer` and whether an index buffer was bound
(`virgl-venus-unset-state.patch`):

- Each graphics and compute pipeline gets the sets its shaders use. These come
  from the SPIR-V scan's walk over the functions an entry point reaches, collected
  in the layout check `vkr_stage_shader_ok` already makes. A variable only listed
  in a SPIR-V 1.4 interface does not count, so vkr counts fewer sets than Vulkan's
  static use and refuses less, never more. A pipeline without a layout, with
  libraries or with descriptor buffers is not checked. There is one mask per
  create info, set on the pipeline objects before the driver's call, so a partial
  failure keeps each its own.
- A draw or dispatch is refused when the bound pipeline uses a set to which
  nothing was bound at that point since the begin (`VUID-vkCmdDraw-None-08600`,
  the same for every draw and dispatch).
- An indexed draw (`vkCmdDrawIndexed`, `-IndexedIndirect`, `-IndexedIndirectCount`,
  `vkCmdDrawMultiIndexedEXT`) is refused without an index buffer unless the guest
  turned maintenance6 on (`-None-07312`). With maintenance6 that draw is legal, so
  vkr binds the NULL index buffer for it, once per recording, after every check.
- The `*2` binds count by their stages: the compute stage binds at the compute
  point, any graphics, task or mesh stage at the graphics point.
- A secondary starts with nothing bound (it inherits no state).
  `vkCmdExecuteCommands` leaves the primary's state as it was. Vulkan makes all of
  the primary's state undefined there, so keeping it refuses nothing an app may do.
- The cost per draw is two 32-bit masks and an AND.

Not covered:

- A primary that draws with a pipeline bound only inside a secondary has no
  pipeline sets, so those draws are not checked.
- What the GPU reads from a vertex buffer never bound or a descriptor never
  written stays with robust buffer access (the GPU-side item of #624).
- The push descriptor template calls have no handler: the guest driver sends
  them as plain pushes.

Tests: 27 `u-` cases in `test-venus-commands.c` (`case_unset`), 11 also under
libgmalloc. On the M1 Max (virgl-only builds of #690's head de1ba2c8 and of this
one, this one's test file, drivers of the 3.2.18 test app, 3 runs in the five
modes):

- Before, 10 cases fail in every mode. On KosmicKrisp, vkr refuses none of the
  10 not-allowed cases. On MoltenVK 8 of them run (2 skip), and vkr refuses none;
  with prefill all 8 end the process (SIGSEGV). The two legal maintenance6
  draws without an index buffer also end the process (SIGSEGV) in all three
  MoltenVK modes, 9 of 9 each, so the NULL bind vkr adds is needed.
- After, every case is as expected in every mode, with no crash report.
- MoltenVK has neither drawIndirectCount nor VK_EXT_multi_draw, so those 4
  cases skip there. KosmicKrisp records the maintenance6 cases but does not
  submit them.
- The whole file (`run-venus-limits.py`) on this build: 421 cases on KosmicKrisp
  (4 skipped), MoltenVK (23) and with prefill (31), 71 under libgmalloc, the image
  file 114 on both, no GPU restart.

## An app's image on a swapchain's memory (amendment, 3.2.20)

Lane `v624-swap` (#624, after #693). This changes the KosmicKrisp-only exception of
`virgl-venus-dedicated-memory.patch` above.

An app may make an image with `VkImageSwapchainCreateInfoKHR` and bind it with
`VkBindImageMemorySwapchainInfoKHR`. Venus has no host swapchain, so guest Mesa
does this itself: it makes the image B from the swapchain's own create info
(`ALIAS_BIT`, VUID `VkImageSwapchainCreateInfoKHR-swapchain-00995`) and binds it
to memory M at offset 0. M is dedicated to the swapchain's image A. vkr allowed
that bind on KosmicKrisp only, so on MoltenVK the app's context ended.

What MoltenVK 1.4.2 does with it, straight to the drivers on the M1 Max (Apple7),
no vkr, 3 runs each on KosmicKrisp, MoltenVK and MoltenVK with prefill, each
also under libgmalloc (504 runs, 0 GPU restarts, raw in work/v624-swap/out/m1):

- The bind works on both drivers.
- Every order that frees M before B is destroyed ends the process on MoltenVK
  at `vkDestroyImage(B)`: 60 SIGABRT, and 60 SIGSEGV under libgmalloc, in
  `MVKDeviceMemory::removeImageMemoryBinding` on the freed memory.
  `MVKDeviceMemory.mm:171` lets an aliasable image bind to dedicated memory, but
  `:175` counts it only in non-dedicated memory, so `~MVKDeviceMemory` never
  clears B's pointer to M. That order is legal: `vkDestroySwapchainKHR` has only
  VUIDs 01282-01284, and memory may be freed with images bound to it.
- B draws from A's `MTLTexture` (`MVKImage.mm:105-111`), so B must match A.
- KosmicKrisp crashed in none.

So vkr now (`virgl-venus-alias-memory.patch`):

- lets an `ALIAS_BIT` image bind at offset 0 to memory dedicated to an
  `ALIAS_BIT` image on both drivers, only when its create info equals the
  target's: type, format, tiling, flags, usage, extent, levels, layers and
  samples. That is what Mesa sends. Other create info is refused with a log
  line. On KosmicKrisp such binds went through before; they break 02628 for the
  host driver and are not what a legal guest call becomes.
- makes B hold M for every such bind it passes on, whatever the driver returns
  (MoltenVK stores M in B before it can fail). A freed M stays in the driver as
  a zombie until B's driver destroy. When B is itself the target of dedicated
  memory, its destroy is deferred and the hold moves to B's record, so M goes
  after that deferred destroy too. The order is always B, then M, then A.
- refuses a second bind of such an image (VUID
  `VkBindImageMemoryInfo-image-07460`), so a hold is never lost. In one
  `vkBindImageMemory2` it refuses an image named again only when the later bind
  is such a bind (`vkBindImageMemory2-pBindInfos-04006`). Such a bind followed
  by a plain bind of the same image in the same call still reaches the driver:
  invalid in Vulkan, but the image takes its one hold on the memory either way,
  so no hold is lost; no crash with it (v624-swap). (Wording corrected after
  3.2.20: it said one image twice in one call was refused.)
- frees all memory through one helper (`vkr_device_memory_free`): the guest's
  `vkFreeMemory`, the device's teardown and a zombie's last holder. In the
  teardown zombies go after images (rank: command buffers, views, images,
  memory, pools).

A zombie M keeps its GPU memory charge until B is destroyed; the guest's own B
bounds that. Nothing changes on a hot path.

Tests: 13 `x-dedicated-alias` cases in `test-venus-commands.c` (`case_alias`), 9
of them also under libgmalloc. On the M1 Max (virgl-only builds of #693's head
cb8f58b3 and of this one, this one's test file, drivers of the 3.2.18 test app,
3 runs in the five modes, 21 dedicated-memory cases each):

- Before, 11 cases fail on KosmicKrisp (no refusal, no hold) and 12 on MoltenVK
  (every alias bind refused, the legal ones too).
- After, 21 of 21 in every mode, with no crash report.
- The same build without the hold: the 5 legal cases that free M before B end
  the process on MoltenVK every time (30 SIGABRT, 15 SIGSEGV under libgmalloc).
  So the hold is what keeps QEMU alive, not the bind rule.
- The whole file (`run-venus-limits.py`) on this build: 432 cases on KosmicKrisp
  (4 skipped), MoltenVK (23) and with prefill (31), 79 under libgmalloc, the
  image file 114 on both, no GPU restart.

VM row on a hidden clone on the M1, both drivers: Ghostty on Zink (KosmicKrisp),
vkcube resized twice, Zink glxgears, the validation layer with 0 VUID lines, and
a guest program that binds an image with `VkBindImageMemorySwapchainInfoKHR`
beside vkcube in three orders (the image first, the swapchain first, the
process ending with the image alive): all three work on both drivers, with 0
refusal lines.

## The image that aliases a YCbCr plane on MoltenVK (amendment, 3.2.20)

Lane `v624-aliasfmt` (#624, after #696). Found by owed-m4 on the M4: 349 of the
400 `dEQP-VK.ycbcr.plane_view.memory_alias.*_fragment` cases failed on MoltenVK
with `VK_ERROR_FORMAT_NOT_SUPPORTED` at `vkCreateImage` (3.2.18, 3.2.19, #693).
qemu.log: `the driver has no format 9 ... flags 0x608`.

Each case makes a disjoint multi-planar image, then an image of a one-plane
format at one plane's extent with the same flags, `MUTABLE | ALIAS | DISJOINT`
(0x608), and binds it with `PLANE_0` to that plane's memory. That is legal:
VUID `VkImageCreateInfo-format-01577` allows `DISJOINT` on a format that is not
multi-planar when `ALIAS` is set. dEQP asks the format query only for the
multi-planar format; VUID `VkImageCreateInfo-imageCreateMaxMipLevels-02251`
wants one for the alias too, so strictly dEQP skips a query, but it is not the
one that was wrong.

MoltenVK 1.4.2's format query refuses `DISJOINT` on every format that is not
multi-planar and does not look at `ALIAS` (`MVKDevice.mm:1578`). Its
`vkCreateImage` makes the image with one memory binding, as without `DISJOINT`
(`MVKImage.mm:1261`). vkr's create check asks the driver's query with exactly
the guest's flags, so it refused what MoltenVK makes.

Driver probe on the M4, straight to the 3.2.19 app's drivers, no vkr, all 400
cases per run (raw in work/v624-aliasfmt/probe/out):

- MoltenVK, 3 runs, 3 under libgmalloc, 1 with Metal validation: 0 crashes, 0
  validation errors, every run the same. The query says no to 0x608 for all
  400, yes to 0x408 for 388 (no for 12: R4G4, which MoltenVK has not). It makes
  all 388 with 0x608; their memory requirements equal a 0x408 image's, also
  asked with `PLANE_0`. In the 349 cases dEQP runs, bytes copied into the alias
  come out of the multi-planar image's plane unchanged, as with a 0x408 alias.
- MoltenVK ends the process (Metal: invalid pixel format) when asked to make
  the R4G4 image its query refused. So the second question must stay a real
  question.
- KosmicKrisp, 3 runs and 3 under libgmalloc: it answers 0x608 as 0x408 in 400
  of 400 (296 yes with the same limits, 104 no), and 128 cases bind and copy.

So vkr now (`virgl-venus-disjoint-alias-format.patch`) asks the driver once more
without `DISJOINT` when it said `FORMAT_NOT_SUPPORTED` to a one-plane format
(one that vkr's table knows) with `DISJOINT | ALIAS`. That answer counts in
`vkr_image_info_ok` (vkCreateImage and the three `vkGetDeviceImage*` queries)
and in what the guest is told by `vkGetPhysicalDeviceImageFormatProperties` and
`...2` (a copy of the guest's info, its chain kept). The create info goes to the
driver as the guest sent it. A driver that answers these flags itself keeps its
answer, so KosmicKrisp is not changed. One-plane `DISJOINT` without `ALIAS` (not
legal) and multi-planar `DISJOINT` are not changed. The refusal line names the
flags asked too.

Tests, on the M4 with the 3.2.19 app's drivers:

- `test-venus-image-limits.c`: the `bind-alias-*` cases asked MoltenVK directly
  and so always skipped there; they now ask vkr's query, as the guest does, and
  must work (or end the context) on both drivers. New `agree-*` cases check
  that the guest's query (versions 1 and 2) and `vkCreateImage` agree (02251)
  for R8, R8_UINT, R16, R8G8, R32_UINT, R10X6 and R12X4 with 0x608, R8 with
  0x208 (refused on both) and a two-plane 0x608 image; `devreq-alias` covers
  `vkGetDeviceImageMemoryRequirements`.
- Before (virgl-only build of #696, 383437be), MoltenVK: 12 cases fail (4
  bind-alias, 7 agree-alias, devreq-alias); KosmicKrisp: 124 of 124. After:
  124 of 124 on both, 3 runs, and the 10 plane-bind cases under libgmalloc.
- The test app built from source (3f3efaa1): 0 FAIL lines; `run-venus-limits.py`
  all ok (the image file 124 on both drivers).
- dEQP-VK in a hidden clone (guest 3.2.19), the 2880-case subset and all 800
  `memory_alias` cases, against owed-m4's #693 rows case by case: KosmicKrisp 0
  cases differ; MoltenVK 349 `memory_alias` cases Fail -> Pass (3 of them in the
  subset), 0 new failures, 11 refusal lines -> 0, 0 GPU faults.

## Full SPIR-V validation (amendment, 3.2.21)

The structural scan let 66 of 138 modules that end QEMU in KosmicKrisp's or
MoltenVK's compiler through (#624, M4, compile only). Guest SPIR-V now goes
through SPIRV-Tools' validator after the scan (`virgl-venus-spirv-validate.patch`),
for the device's Vulkan version and the layouts its features allow, never what
one app enabled; spirv-val refuses 65 of the 66, a Function element cap
(2^20 after specialization) the last one. Passed modules are cached by
SHA-256 (4096 entries, LRU). The device's version is the one the guest is
told: KosmicKrisp reports its own, MoltenVK the instance's, so a 1.0 or 1.1
app on MoltenVK is validated as Vulkan 1.1 (SPIR-V up to 1.4), as it was
told. Private arrays count against the same element cap, and a stage's
Workgroup variables may take at most maxComputeSharedMemorySize bytes: a
Private or Workgroup uint[2^32-1] passed the scan and spirv-val. Both count
what the stage's compiler gets (3.2.22; 3.2.21 counted every variable of the
module): the Function variables of the functions its entry point reaches,
and every Private and Workgroup variable of the module, as MoltenVK's
SPIRV-Cross declares each in every entry point it compiles (Mesa's
spirv_to_nir too before SPIR-V 1.4); on KosmicKrisp from SPIR-V 1.4 only
those in the entry point's interface, as spirv_to_nir skips the rest. So two
compute entry points in one module no longer add up their Function arrays.
A stage the device lacks keeps Vulkan's
minimum interface locations, so vkd3d-proton's geometry module still
creates on MoltenVK.

spirv-val is guest-facing too, so it gets the same treatment as the drivers,
on the CPU only (hostile modules never reach a real driver, STANDARDS 14b):
an Input of a struct of uint[2^32-1] took it past 512 MB, a type DAG 30 deep
past 20 s, 1000 nested loops 53 s, and three fuzzed modules ended the process
(a NULL read after an assert compiled out, an abort from `at()`, a NULL read
for a BuiltIn untyped variable). So before it reads a module the scan's caps
refuse interface variables past the device's location limits
(VUID-RuntimeSpirv-Location-06272) and types that cost more than 2^24; inside
it (`spirv-tools-val-catch-throws.patch`) asserts stay on and throw,
exceptions are caught, a BuiltIn check no longer reads a missing type, and a
CPU budget of 2 s stops its superlinear walks. Those refusals hold also in a log-only build. The slowest hostile
module measured takes 2.03 s; real modules at most 3.1 ms. Ray tracing
pipelines are refused (no Mac driver has them).

MoltenVK's own crash after a caught SPIRV-Cross error (decided: no
MoltenVK from source). Of the 127 modules that ended or hung MoltenVK, 119
ended it in a plain run (6 more only under Guard Malloc, 2 were runaway
compiles past 2 GB). In 93 of the 119 SPIRV-Cross's parser threw in
`new CompilerMSL`, MoltenVK caught it and then called the compiler it never
got (`SPIRVToMSLConverter::convert`); in the other 26 SPIRV-Cross crashed by
itself, which no MoltenVK patch can catch. A throw in `compile()` (134
modules) fails the pipeline cleanly. SPIRV-Cross run as a CPU library on the
324 modules the validator lets through for MoltenVK: 0 throw in the parser,
0 crash, 24 throw in `compile()` (f64 in buffers, a clean error). So the
validator already stops every module the fix would save, and the runtime keeps
Homebrew's MoltenVK bottle. When the MoltenVK or SPIRV-Tools pin moves, run
the same SPIRV-Cross check on the new versions; an accepted module that throws
in the parser or crashes SPIRV-Cross reopens this. The upstream report is
drafted, not sent.

## Metal passes and host memory (amendment, 3.2.22)

Lane `v624-hostmem` (#624's "host-memory caps", after #697). The question: can
one guest program make QEMU (vkr and the Mac's driver) hold memory beyond what
the guest's own limits allow, or end it that way? Probes through vkr's own
dispatch on the M1 Max (macOS 27, the 3.2.18 test app's KosmicKrisp and
MoltenVK, each probe its own bounded process, no VM; raw in
work/v624-hostmem/out run4-run12).

Device memory was already charged right (written memory matches the charge, a
budget refusal leaves the context alive). Three things were not:

- **Metal passes end QEMU.** One Metal command buffer with about 98304 passes
  (render encoders) ends the process: SIGABRT, "Failed to allocate
  IOGPUDeviceShmem" in `IOGPUMetalCommandBufferStorageGrowKernelCommandBuffer`
  from `AGX::RenderContext::beginRenderPass`. KosmicKrisp opens a pass while
  recording for each clear (per level; a level's layers are one layered pass,
  and so are a 3D level's depth slices), render pass begin, rendering, and
  each by-region barrier inside a 4x pass; it aborted past 98304 clears, past
  98304 empty passes, between 90112 and 98304 split barriers, between 6144
  and 6656 clears of 15 levels, with no submit. 1M plain draws, 204800 copies
  and 1x in-pass barriers, 16384 clears of a 2048-deep 3D image and 65536
  blits or resolves did not. MoltenVK encodes at the submit (at
  `vkEndCommandBuffer` with prefill) and puts a batch's command buffers into
  one Metal command buffer: with prefill it aborted at the end after 150000
  clears or 204800 passes, renderings, blits or resolves; without, one batch
  of 8 x 16384 clears aborted at `vkQueueSubmit`, 4 x 16384 in one batch went
  through.
- **Some draws split a pass** (found in the review, probed in fix-700,
  work/v624-hostmem/fix/out). KosmicKrisp unrolls a draw in a compute pass
  first (`kk_cmd_draw.c`, `requires_unroll`) for triangle fans, 8-bit indices,
  8- or 16-bit strips with restart off, list restart with
  `primitiveTopologyListRestart`, a Flat fragment input with the last vertex
  provoking, and index robustness; it applies predicates (conditional
  rendering) the same way, runs each tessellated draw's stages as compute, and
  starts a new pass when sample locations or the color attachment map change.
  Each such draw cost 60-113 KB while recording (a color-map or
  sample-location change 24 KB; a plain draw 0.1 KB), and between 73728 and
  81920 fan draws in one pass ended the process. MoltenVK with prefill ended
  the process at the end of 114688 tessellated draws, or draws with a
  sample-location or color-map change each. 32-bit strips, strips with
  restart, flat inputs with the first vertex provoking, timestamps in a pass
  and robust draws inside an aligned index buffer did not split.
- **Recordings and objects cost memory nobody counted.** Per command
  (footprint): KosmicKrisp 2423 B per 44-byte fill (2 GB in 0.57 s), 84017 B per
  64 KB update, 36415 B per blit region; MoltenVK 65881 B per update. Per
  object: KosmicKrisp 18366 B per event (1148 MB in 0.47 s) and 34137 B per
  command buffer, MoltenVK 142082 B per command pool (1110 MB in 0.09 s) and
  12.6 MB per 2^20 timestamps. A submitted pass held 171-179 KB, most of it
  wired, after the queue went idle, at any image size and also after the
  command buffer's reset, free or its pool's destroy. 8 x 16384 clears in one
  KosmicKrisp submit took the process to 22 GB (memory level 86 -> 74). That
  storage is used again for the process's next command buffers (fix-700,
  out-C): 10 rounds of a new pool, 2048 submitted passes, free and destroy
  stayed at 301-317 MB on KosmicKrisp and 356-363 MB on MoltenVK, also with
  one pool reset each round and over 10 contexts in turn (307-317 MB), and
  10 rounds of 2048 64 KB updates on MoltenVK at 243-260 MB. The process
  keeps about its peak; it does not grow from round to round.
- **The reported heaps were bigger than what Venus may use.** MoltenVK
  reported 32768 MB (all of the M1 Max), KosmicKrisp 25559 MB, both more than
  the 22528 MB apps' share; maxBufferSize 19169 MB.

What vkr does now:

1. `virgl-venus-encoder-cap.patch`: each command buffer counts its passes
   (clears per level, pass begins, next subpasses, renderings, on KosmicKrisp
   every barrier inside a pass, because vkr does not keep a pass's sample
   count, and a primary the passes of the secondaries it executes, each
   time). Blit and resolve regions count as a pass each, to be safe. So do
   the draws that split a pass (`vkr_cmd_draw_weigh`): on both drivers each
   tessellated draw and each sample-location or attachment-location change
   inside a pass; on KosmicKrisp a draw call it unrolls or predicates. For
   that vkr keeps each graphics pipeline's topology, restart, provoking mode,
   tessellation and Flat use (from the SPIR-V scan; pipeline libraries
   merged) and follows the recording's dynamic state and index buffer.
   Robust indirect or over-reading indexed draws count on any macOS (macOS 27's
   KosmicKrisp also needs a misaligned index buffer for those). Past 16384
   per command buffer, or 32768 in one MoltenVK batch, the command (or the
   submit) is refused and the app's context ends. 16384 is 6x below the clear
   abort and 4.5x below the fan-draw abort; a Zink frame has about 2000
   passes. `OMACVM_VENUS_ENCODER_CAP` sets it for tests. The cap is fixed,
   not measured per Mac. On the mini's M4 KosmicKrisp aborted between 74752
   and 75264 clears of one level (fix-700 r2), so 16384 is 4.6x below there;
   an 8 GB Mac is not measured.
2. `virgl-venus-host-memory.patch`: each context has a host memory account
   (`OMACVM_VENUS_HOST_MB`, else a quarter of the apps' share, 256 MB to
   4 GB), and the same bytes go to the shared GPU budget, so one app's
   recordings cannot starve the others and all apps stay inside the budget.
   Objects are charged a fixed estimate per type, whatever their size (a
   shader module 4 KB though its code may be 4 MB, which both drivers keep a
   copy of; a pipeline cache 20 KB whatever its initial data; charging these
   by size is a follow-up), recordings 512 B per command,
   184 KB per pass or draw that splits one (recorded and held after the
   submit), an update's data x
   1.5, on KosmicKrisp 3 KB per fill and attachment clear and 40 KB per blit or
   resolve region. Every charge is at least what a probe measured
   (`kit/costs.py` over the probe output). A command buffer takes 1 MB at a
   time (no shared counter per command: `--time` shows no change, e.g.
   vkCmdDraw 0.168-0.170 us before and 0.169-0.170 after on KosmicKrisp) and
   keeps the most one recording took through resets; freed, that goes to its
   pool for the pool's next recordings, and back with the pool (the memory
   stays in the process but is used again: the rounds above). Charges come
   back where vkr frees the object: after the driver's destroy, a zombie's at
   its last holder, and in the context's teardown, which logs the peak. A lost
   context the guest never closes keeps its charge until its teardown.
3. The same patch reports heaps of at most the apps' share (both memory
   property queries), maxMemoryAllocationSize and maxBufferSize at most the
   heap, and for VK_EXT_memory_budget this context's device memory as
   heapUsage and that plus what the share has left as heapBudget (a page at
   least, at most the heap). Zink, DXVK and Chromium read these; 32 -> 22 GB
   changes nothing for them on this Mac.
4. The decoder frees a temp buffer over 16 MB after each stream (one 256 MB
   command left 320 MB per context and per ring).

Every refusal here ends the app's context. The guest's Mesa records, submits and
creates without waiting for vkr, so no `VK_ERROR_OUT_OF_*_MEMORY` would reach the
app there: it sees a lost device, the VM goes on. Only `vkAllocateMemory` (with
`VN_PERF=no_async_mem_alloc`) and what vkr reports can tell an app about memory
before that. Venus against macOS memory pressure (the GPU guard's levels) is a
later patch.

Tests, on the M1 Max: `test-venus-commands.c`'s h- cases (28), on KosmicKrisp,
MoltenVK and MoltenVK with prefill. On the build before (#697, 85270088, the 3.2.20 set) 16
fail on KosmicKrisp and on MoltenVK and 13 with prefill (its 4 submit and
teardown cases skip there), among them `h-pass-default-past-metal` ending the
process (signal 6) on KosmicKrisp and with prefill, and `h-rec-fills`,
`h-rec-updates` and `h-obj-events` stopped at 1.5 GB on KosmicKrisp; the 12
legal cases work before and after. With both patches all 28 pass on every
driver.

The review's follow-up (fix-700) adds 17 cases: `h-pass-draw-` for each draw
kind that splits a pass and each that does not, and `h-pass-3d-ok`/`-over`.
On the build before it, 10 fail on KosmicKrisp (fan, u8, strip16,
list-restart, flat-last, pred, robust-indirect, tess, sample-locations,
attachment-locations: they fit where they must not) and 3 on MoltenVK and with
prefill (tess, sample-locations, attachment-locations); after it all 45 h-
cases pass on all three.

Second follow-up (fix-700 r2, 2026-11-04). On the mini's M4 (16 GB): a submitted
pass held 86 KB on KosmicKrisp and 36 KB on MoltenVK after the queue went idle
(4096 clears, also after the free and the pool's destroy), below the 184 KB
charge; 10 rounds of a new pool (or a new context) with 2048 submitted clears
stayed at 150-215 MB. The VM row on the M1 (fc5d5bde, hidden 4 GB clone,
KosmicKrisp and MoltenVK) logged each context's peak against its 4096 MB
account: Ghostty on Zink 37 MB, Zink glxgears 26, Zink glxinfo 7, Chromium
(WebGL, ANGLE on Venus) 21-27, vkcube 8 (KosmicKrisp) and 27 (MoltenVK, also
with the validation layer), clinfo 2, vulkaninfo 0; 0 "still charged" lines.
On an 8 GB Mac the budget is 6144 MB, the desktop keeps 512 MB, the apps'
share is 5632 MB and each context's account 1408 MB: about 7800 passes held at
once (184 KB each), summed over each live command buffer's largest recording.
The row's apps used at most 37 MB (about 200 passes' worth). DXVK or Zink with
4 frames in flight fit up to about 1900 passes per frame; a frame near the
2000 of `h-zink-frame-ok` with 4 or more in flight would end the app's context
there. Not measured with DXVK (no Windows app in the row).

## Secondaries recorded again, and what is submitted (amendment, 3.2.23)

Lane `venus-3223` (#676's follow-up; plan and review in work/venus-3223). #678
(3.2.19) made a primary hold the secondaries it executed, so a freed secondary
stays in the driver until the primary lets go; #700 gives its charge back then.
Two gaps were left, both from the driver sources at the pins:

- **A secondary recorded again.** Begin, reset or a pool reset of a secondary a
  primary executed is legal; the primary becomes invalid. MoltenVK encodes the
  secondary's current content when it encodes the primary (at the submit, or at
  the primary's `vkEndCommandBuffer` with prefill). KosmicKrisp replays it into
  the primary while recording and again at a reusable primary's 2nd and later
  submit (`kk_queue.c`, `vk_command_buffer.c`). vkr weighed the secondary's
  Metal passes and its pass continuation at the execute, so a secondary
  recorded again with more passes got past the encoder cap.
- **What is submitted.** Nothing checked that a submitted command buffer is an
  ended primary. MoltenVK refuses a secondary and a 2nd submit of a one-time
  buffer itself (`canExecute`); KosmicKrisp relies on the app.

`virgl-venus-submit-state.patch`: a command buffer has a serial (one more at
each begin, reset and pool reset, also of a pool's held zombies, before the
driver's call) and an executable flag (a successful end; cleared by begin,
reset, pool reset, free). The primary's held entry of a secondary keeps the
secondary's serial from the execute. vkQueueSubmit and vkQueueSubmit2 refuse,
before any driver call, a command buffer that is not an ended primary and a
primary whose secondary's serial changed; the primary's end refuses the
latter too. Vulkan calls all of these invalid.

The holds rest on one assumption, now written down: both drivers read a
secondary inside `vkQueueSubmit` on the calling thread (MoltenVK's
`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS` defaults to 1; KosmicKrisp submits in
Mesa's immediate mode and never threaded). A pin bump that changes either
needs the `c-state-secondary-held-` cases again, under libgmalloc too.

Tests (mini M4, virgl-only builds of main and of the patch, KosmicKrisp,
MoltenVK and MoltenVK with prefill, each also under libgmalloc; raw in
work/venus-3223/out): 11 new cases. On main the 5 refusal cases
(`-rerecord-submit`, `-reset-submit`, `-pool-reset-submit`,
`-free-pool-reset-submit`, `-rerecord-end`) work where they must be refused,
on all 6 runs; the 3 legal ones (`-resubmit-ok`: a reusable primary
submitted twice after its secondary's free, `-rerecord-ok`,
`h-release-secondary-ok`: the charge is back to the byte after the primary's
reset, while the context lives) work. `s-submit-secondary`, `-recording` and
`-initial` were not run on main (they would hand a driver what it must not
get). With the patch all 11 pass on all 6 runs, and all 488 cases pass on
the three drivers (4, 28 and 40 skipped, as on 3.2.22); 0 GPU Restart.

## A shader module's charge by its code size (amendment, 3.2.23)

Lane `venus-3223` (X3 of the 3.2.22 architecture review). The host-memory
account charged a shader module 4 KB whatever its code, up to 4 MB, of which
both drivers keep a copy and vkr its scan. A capped probe (work/venus-3223/kit/
probe, phys_footprint inside the process, 512 MB) made N modules of one real
corpus module through vkr's dispatch on the mini's M4 and kept them:

| Module | Code | KosmicKrisp | MoltenVK | MoltenVK prefill |
|---|---|---|---|---|
| dxvk-d3d11-004 (x200) | 68496 B | 106906 B (1.56/B) | 121979 B (1.78/B) | 121651 B (1.78/B) |
| dxvk-d3d11-009 (x500) | 17808 B | 30310 B (1.70/B) | 30442 B (1.71/B) | 30507 B (1.71/B) |
| vkcube-frag (x1000) | 2644 B | 6160 B (2.33/B) | 6390 B (2.42/B) | 6308 B (2.39/B) |

(bytes per module; per code byte in brackets). The same number of creates and
destroys of one module left the footprint where it was on every driver.
`virgl-venus-host-memory.patch` now charges a module 2 B per byte of its code
on top of the 4 KB (68 KB of code: 141 KB; 2.6 KB: 9.3 KB), at least what
each row took. `h-obj-module-size` (200 of the 68 KB module under an 8 MB
account) works on main and is refused with the change; `h-obj-module-again-ok`
(2000 creates and destroys) works on both. Small modules take more per code
byte (2.33-2.42 at 2644 B), which the 4 KB covers (9384 B charged against
6160-6390 B taken).

A pipeline cache was 20 KB whatever its initial data. A cache made from a
driver's own data (`vkGetPipelineCacheData` of a cache with a real compute
pipeline) reports as much data again: 2597 B on KosmicKrisp, 6570 B on
MoltenVK and MoltenVK prefill (lane `venus-3223`'s run). It now counts 1 B per
byte of initial data on top of the 20 KB, back at its destroy.
`h-obj-cache-size` gives 50 new caches the driver's data of a cache with 32
pipelines (84673 B on KosmicKrisp, 6570 B on MoltenVK): 20480 B a cache before
the change (the case fails), the data on top with it, all of it back after the
destroys; `h-obj-cache-again-ok` (2000 creates and destroys under an 8 MB
account) works on both. Not changed: pipelines that leave Metal libraries in a
module (MoltenVK without a cache) or a cache stay uncharged until a probe
measures them, repeats included.

