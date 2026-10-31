# 0067: QEMU's own graphics per window: no console texture while a GL scanout shows, spare present surfaces volatile out of sight

Status: accepted, built (`vm-memory-gfx-fixed`), on by default; switches
`OMACVM_CONSOLE_TEXTURE=eager` and `OMACVM_PRESENT_VOLATILE=0` give the old
way. Notes, the investigation and the review: work/tracks/vm-memory.md
(plan, unit 3 "gfx-fixed"), work/tracks/vm-memory/inv-host-code.md.

## Context

Activity Monitor's number for OmacVM.app's QEMU holds, besides the VM's
memory and the guest's own GPU resources, graphics that QEMU keeps for the
window by itself. None of it is in the GPU budget, `logs/gpu-memory` or the
app's numbers. Per 5120x2880 main window (host test without a VM, Mac mini
M4, macOS 27.0; work/vm-memory/host-code and gfx-fixed raw):

- **The console texture**, QEMU's GL copy of the console's DisplaySurface.
  Every set scanout made one (`qemu_console_resize` at each mode change and
  display on, the "display not active" placeholder at the old size at each
  display off), filled from the surface: Apple's GL keeps a second copy of a
  texture filled from client memory, 127.4 MiB of footprint (a texture made
  with no data: 0). Each upload holds the BQL (#609's rows: up to 218.6 ms,
  161-170 holds of 20 ms or more in 60 display off/on cycles). With virgl
  the window shows the guest's scanout texture and never this one; the boot
  logo stands in for the placeholder. It is drawn only without a GL
  scanout: the firmware and boot console (2D resources), and only there.
- **The present surfaces**: 5 IOSurfaces (with vsync; 3 without) at the
  frame's size, 62.1 MiB each in 8-bit or plain (63.1 lossless '&BGA'),
  118.4 in half float (HDR, extra brightness). Out of sight (minimised,
  covered, another Space, the screen locked, closed with Keep running) QEMU
  draws no frame (omacvm-cocoa-present-unseen.patch), but all of them stayed.

## Options

1. **Console texture made with no data at each switch** (`glTexImage2D`
   with NULL): costs 0 until written, but a reader would draw an empty
   texture until the next update, and a 2D surface switched in without an
   update would stay black.
2. **Console texture made when first drawn** (chosen): on QEMU's thread,
   whole from the surface, at the surface's first update (2D), at a present
   without a GL scanout, or at the refresh tick before a CAOpenGLLayer draws
   (GPU safe mode's layer path, extra displays). Readers on the AppKit thread
   draw black until it is there and never make it (QEMU's view context and
   the upload stay on QEMU's thread, where they were). The boot logo's three
   places stay in front of the texture, so the placeholder behind the logo
   never gets one.
3. **Fewer present surfaces**: the vsync queue needs them (one shown, one
   committed, up to three queued); fewer means dropped frames while the
   window shows.
4. **Spare present surfaces volatile while out of sight** (chosen): after
   2 s out of sight every surface Core Animation does not show or read (in
   use, or the layer's contents) gets `IOSurfaceSetPurgeable` volatile. Host
   test: one leaves the footprint down to 5.9 MiB (plain, lossless and half
   float alike), comes back to its full size non-volatile with its picture
   kept, and macOS may take its pages without compressing them. In sight
   again (or taken for a frame) it comes back first; one macOS emptied is
   drawn whole (the partial present's state set to full). A refusal stops
   the rule for the run. 2 s, the wait of "Pause drawing while hidden": a
   window out of sight for less keeps everything.
5. **Spare surfaces volatile while in sight and idle**: another ~170 MiB at
   5K on a still desktop, but every frame after a pause would have to make
   one non-volatile first; not now.
6. **Free the surfaces out of sight**: no footprint at all, but the window
   would need a new allocation (and a whole frame at 5K) at every return,
   and Core Animation's own copy of the shown one must stay anyway.

## Decision

Options 2 and 4: `qemu-cocoa-gl-console-texture-lazy.patch`,
`omacvm-cocoa-present-volatile-logic.patch` (the rules in
`ui/omacvm-present-volatile.h`) and `omacvm-cocoa-present-volatile.patch`.
qemu.log says which way each runs, once: "cocoa: console texture: made when
first drawn" and "cocoa: present surfaces: spare ones volatile while the
window is out of sight"; after a return "cocoa: present: in sight again: N
spare surfaces were volatile, M emptied by macOS (drawn whole)".

## Consequences

- Per 5K output, about 127 MiB less in every run with a GL scanout (the
  console texture), and 4 of 5 present surfaces out of the footprint while
  the window is out of sight: about 225 MiB (450 MiB in half float), by the
  host test's per-surface costs. The VM rows are in the PR.
- No upload under the BQL at a display off or on or a mode change.
- A 2D picture in the CAOpenGLLayer path (GPU safe mode's boot console) may
  be black for one refresh tick after a switch until QEMU's thread makes its
  texture; the IOSurface present makes it at once.
- Extra displays draw through CAOpenGLLayers and have no present surfaces of
  their own: only the console texture part applies to them.
- Tests: `Tests/display/test-console-texture.sh` (the listeners from the
  patched `ui/cocoa.m` with a GL stub that counts uploaded bytes),
  `Tests/display/test-present-volatile.sh` (the rules and the wiring); both
  fail on the code before. `OMACVM_TEST_PRESENT_PURGE=1` empties each
  surface for real before it comes back, so a test can show that an emptied
  surface is drawn whole.
