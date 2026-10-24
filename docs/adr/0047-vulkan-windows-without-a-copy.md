# 0047: Vulkan windows at the display's rate, and without a copy on the Mac

Status: accepted. Pacing: on for every app VM with Vulkan. No copy: the app
switch `vkWindowsNoCopy`, on by default after 3.1.25 (off and experimental
in 3.1.24 and 3.1.25). Builds on
[0010](0010-iosurface-present.md), [0012](0012-venus-in-process.md),
[0035](0035-graphics-setting.md) and [0046](0046-gpu-off-the-main-loop.md).
Notes and numbers: work/tracks/vulkan-zero-copy.md (sections 3 and 7).

## Context

Graphics Automatic gives VMs Vulkan (Venus on KosmicKrisp) on macOS 26 and
newer. Host-visible Vulkan memory is already shared with the guest (Metal
heaps mapped into the hostmem BAR). A Vulkan window's frames are not:

- Venus has no DRM modifiers on the Mac, so Mesa's WSI renders into an
  optimal image and blits it into a linear buffer it exports as a dma-buf
  (the PRIME blit). Hyprland imports that buffer into its GL context. macOS
  OpenGL cannot see Metal memory, so `virgl-set-type-without-egl.patch`
  gives it a plain GL texture and refills it with `glTexSubImage2D` from the
  heap's pages whenever Hyprland's frame samples it: on QEMU's main loop,
  with the BQL unless `gpuOffMainLoop` is on. Mac mini M4: 2.5 ms a frame
  for a 1816x870 window (vkcube's half-float format), 1.8-2.3 ms at
  3680x1840, up to 5.6 ms at 4K when the GPU is busy.
- Vulkan windows that wait for the display (FIFO, the default) ran at 45-50
  fps on a 60 Hz display; OpenGL ones at 60. Not the copy: the same with it
  removed. Mesa's Wayland WSI gives each FIFO commit a target time (Wayland
  commit timing: the last presentation plus one refresh) and Hyprland holds
  the commit until then; the guest's frame clock runs a few ms late (a 13.3
  ms sleep wakes ~4 ms late, median), so commits often waited one refresh
  more. Without commit timing (`MESA_VK_WSI_DEBUG=nowlts`), without Venus's
  asynchronous present, or through Xwayland: 59-60 fps.

Apple's OpenGL binds an IOSurface only as `GL_TEXTURE_RECTANGLE` and has no
other way to see Metal memory. KosmicKrisp imports host memory
(`VK_EXT_external_memory_host`, for buffers); IOSurface pages are
page-aligned whole pages, so it takes them.

## Decision

1. **Pacing (guest).** The session's environment generator
   (`omacvm-vulkan-present`) sets `MESA_VK_WSI_DEBUG=nowlts` when the app
   shows Vulkan windows, unless the user set the variable. The fifo-v1
   barrier alone paces FIFO windows. `omacvm check` warns if the Venus
   driver no longer knows the word. The guest's late frame clock stays its
   own item.
2. **No copy (host only, no guest change).** With `vkWindowsNoCopy`
   (QEMU env `OMACVM_VK_WINDOWS=iosurface`) and KosmicKrisp:
   - vkr creates Mesa's PRIME buffer (transfer target only, exported as a
     dma-buf) with the host-allocation handle type, and makes its dedicated
     memory an IOSurface of 16 KiB rows (4096 BGRA texels a row; the window's
     layout is not known yet), imported as host memory. Blob type
     `VIRGL_RESOURCE_IOSURFACE`; mapped as the IOSurface's own pages.
   - vrend's `PIPE_RESOURCE_SET_TYPE` binds the IOSurface as a RECTANGLE
     texture. When a draw samples the window, the blitter's own GL context
     re-strides it into the window's 2D texture: 4-byte BGRA/RGBA pixels, or
     8-byte half floats taken apart bit by bit. Bit-exact; 0.3-0.4 ms of
     QEMU's time a frame, no CPU wait.
   - On by default after 3.1.25 (Mac mini M4 and MacBook Air M2 soaks,
     PR #475).

Options not taken: a GPU copy through a staging IOSurface (needs a CPU wait
for the Metal blit: 11-14 ms on a busy GPU); a guest Mesa patch that tells
the host the window's shape (the re-stride makes it unnecessary, and old
guests keep working); sampling the RECTANGLE directly (needs the window's
shape in vrend's shader translator; the re-stride costs ~0.4 ms of GPU);
blob scanout (full screen only, needs Hyprland's direct scanout); a cheaper
CPU copy (a PBO is slower at 4K/5K); disabling Venus's asynchronous present
instead of commit timing (it keeps the app's thread from waiting).

### Synchronization

Venus finished the buffer before the guest handed it to Hyprland (its
present waits). The fix for #499 relies on that: a guest Mesa that presents
before the frame is done would bring stale frames back, and the build test
(no guest in it) would not see that. The re-stride reads it in the blitter's context;
`vrend_sync_make_current` puts a GPU wait for it into the guest's context, so
the fence of that command buffer, made in the guest's context afterwards,
covers the read, and the guest writes the buffer again only after that fence
(its implicit fence on the dma-buf). Nothing may switch GL contexts between
the re-stride and that fence. GL sees Metal's writes to the pages without a
lock or rebind because Apple silicon's memory is one (checked bit-exact).

2026-10-24 (#499): that GPU wait holds only once the context it leaves is
flushed. A `glWaitSync` waits only for a flushed fence (ARB_sync);
`eglMakeCurrent` and `glXMakeCurrent` flush the context they leave, but
`CGLSetCurrentContext` does not, and Apple's `glWaitSync` on an unflushed
fence does not wait. From 3.1.24 to 3.1.31 Hyprland's draw therefore ran
before the re-stride was even sent: the first frame Hyprland drew after each
new one showed the buffer's previous frame (Zed's caret one character back
for a frame), a FIFO window was one swapchain cycle late, a mailbox window
tore. `vrend_sync_make_current` now flushes before it switches, into the
blitter and back (`virgl-darwin-context-switch-flush.patch`). Host harness,
Mac mini M4: 7-8 us more CPU per re-stride (0.024 -> 0.031 ms at 1816x870,
0.028 -> 0.036 ms at 4K), and the switch back stays a GPU wait (0.02-0.09
ms with up to 16 more 4K re-strides queued in the blitter). Test VM on the
mini (bench lock, median of 3, 3.1.31 -> fixed): vkcube FIFO 57.9 -> 57.7
fps, QEMU's busiest thread 1.30 -> 1.40 ms a frame; vkmark windowed 2682 ->
2646. The blit fallback's flushes did not run at all in glmark2, a terminal,
WebGL Aquarium or vkcube (no GL fallback blits there).
The window texture is not bound again in Hyprland's context after a
re-stride. GL 4.6 Appendix D.3.3 rule 4 asks for that when another context
changed a texture; Apple's GL was measured not to need it on macOS 27
(the build test runs both ways: bound before every draw and bound once).
Workaround on 3.1.24-3.1.31: the switch off (VM restart).

### Lifetime

| Holder | Takes | Drops |
|---|---|---|
| vkr device memory | the IOSurface it made | at `vkFreeMemory`, after every queue of the device passed it (an empty submission per queue holds a reference) |
| vkr resource (the blob in the Venus context) | one reference | with the resource |
| virgl resource (the guest's blob) | one reference | when the guest's last handle goes |
| vrend texture (Hyprland's import) | one reference + the RECTANGLE texture | with the texture |

## Fails closed

- Another Vulkan driver (MoltenVK), no host-memory import: today's copy,
  logged once ("Vulkan windows are copied (no IOSurfaces: ...)").
- A format other than 4-byte 8-bit BGRA/RGBA or 8-byte half-float RGBA, a
  layout outside the IOSurface (`vrend_iosurface_layout_ok`, checked before
  CGL sees it), a failed bind or re-stride: the CPU copy from the same pages.
- The IOSurface itself cannot be made: the Metal heap as before (the buffer
  then has the host-allocation type, which KosmicKrisp does not check).
- GPU safe mode and the hidden `vkWindowsCopy` keep the copy.

Limits: such a buffer cannot be imported into another Venus context (a
Vulkan compositor inside the VM): `VK_ERROR_INVALID_EXTERNAL_HANDLE`.

## Consequences

- FIFO Vulkan windows reach the display's rate (vkcube 50 -> 60 fps on the
  Mac mini, KosmicKrisp and MoltenVK; two windows 58-60 each).
- With the switch on, QEMU's main loop spends 0.3-0.4 ms instead of 1.8-2.5
  ms on each frame of a Vulkan window (its busiest thread 15-18 % -> 10-14 %);
  frame rates are the same on an idle GPU.
- A new resource type and a guest-visible buffer type change in
  virglrenderer, macOS only (`virgl-vulkan-windows-iosurface.patch`).
- M1/M2 (less memory bandwidth) should gain more from no copy; KosmicKrisp,
  IOSurface and the RECTANGLE bind are checked at run time, not by model.
- Not touched: the software WSI path (the WebGPU launcher), mpv's own stall
  on Venus (it stays on OpenGL), MoltenVK's copy (macOS 15).

Tests: `Tests/virgl/test-vulkan-window-restride.c` (build time: the real
shader and draw on the Mac's OpenGL, bit-exact for all three layouts, and
the layout check's limits); `Tests/virgl/test-vulkan-window-handover.c`
(build time, GPU: the re-stride seen by the guest context's very next draw,
and the guest's work seen by the blitter, with shared CGL contexts;
`OMACVM_TEST_BENCH=1` times the switches); `src/tests/venus-driver.sh` (the generator);
the Vulkan validation layer on the host harness (no errors); VM rows:
vkcube FIFO, Xwayland, resizes, two windows, vkmark full screen,
`gpuOffMainLoop`, MoltenVK forced, a 30-minute soak with no GPU restart.
