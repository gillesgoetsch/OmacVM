# 0065: Venus checks what the Mac's Vulkan driver aborts on

Status: accepted, built (`zink-abort`, 3.2.14), always on. Amends
[0012](0012-venus-in-process.md). Notes, probes and the review:
work/tracks/zink-abort.md.

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
on KosmicKrisp, 10,000 creates), so no cache.

## Consequences

- vkr is the trust boundary for Venus on macOS. KosmicKrisp and MoltenVK stay
  unpatched; the KosmicKrisp report is a draft
  (work/upstream-drafts/kosmickrisp-linear-texture-abort.md).
- Covered: what the probe found at image create, bind, view, sampler and
  queries. Not covered, a follow-up: buffer bind ranges (GPU fault risk),
  pipelines and shader modules, render passes and framebuffers, descriptor
  writes, command encoding, vkr's `assert()`s (virgl is built with asserts on),
  NULL entry points of other commands a device was not made with.
- Zink is now told that a linear render target with input attachments is not
  supported on KosmicKrisp and takes another path or fails with a GL error.
- `Tests/virgl/test-venus-image-limits.c` runs at every runtime build on the
  staged drivers; a new vkr path that hands a guest description to the driver
  needs a case there.
- Revisit option 2 when a crash class appears that a check in vkr cannot catch
  (inside shader compilation or command execution), or when KosmicKrisp can
  share memory across processes.
