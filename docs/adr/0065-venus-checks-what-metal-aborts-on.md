# 0065: Venus checks what the Mac's Vulkan driver aborts on

Status: accepted, built (`zink-abort`, 3.2.14), always on; amended in 3.2.15
(`venus-robust`, "What else vkr refuses" below) and 3.2.17 (`venus-624`,
"Indices, counts and offsets" below). Amends [0012](0012-venus-in-process.md).
Notes, probes and the reviews: work/tracks/zink-abort.md,
work/tracks/venus-robust.md, work/tracks/venus-624.md.

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

## Indices, counts and offsets (amendment, 3.2.17)

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
