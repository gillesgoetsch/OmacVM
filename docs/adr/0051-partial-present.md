# 0051: Partial present: draw only what the guest changed

Status: accepted, built (`omacvm-cocoa-present-damage*.patch`). From 3.5.0
on by default for SDR starts: the VM window's switch "Copy only what
changed" (`partialPresent`) has the app set `OMACVM_GL_PRESENT_DAMAGE=1`;
off for HDR starts until an on-screen check on an HDR display passes
(addendum 2026-11-16). It acts only on flushes with real rects: a buffer
flushed again (boot console, TTYs) on any kernel, a compositor's frames
from Linux 7.4 or OmacVM's virtio-gpu driver with the fix. Notes and
numbers: work/tracks/frame-path.md, work/power-1116/rects/.

## Context

QEMU's present ([0010](0010-iosurface-present.md)) draws the guest's whole
scanout into one of its IOSurfaces for every frame shown, also when only the
pointer moved or one character was typed. Measured offscreen on a MacBook Air
M2 (the same draw as the present, 2940x1840, whole-Mac power, 3 minutes a
row): +0.19 W at 60 frames a second and +0.47 W at 120 over the same loop
without the draw; the same draw scissored to a 64x64 box +0.06 and +0.02 W.
On the M4 Max the GPU time per draw is mostly a fixed cost (a 64x64 box takes
55-75 % of a full draw), on the M2 it follows the size (591 vs 1767 us).

The guest says what changed: each RESOURCE_FLUSH carries a rect. Linux up to
7.3 sets it to the whole plane on every page flip (virtgpu_plane.c:
ignore_damage_clips when the framebuffer changes), which a compositor does on
every frame. Linux 7.4 keeps the compositor's damage for rendered buffers
(upstream 730f8554f35c, a9cc9905ddb7). Hyprland and aquamarine send buffer-age
damage, a superset of what changed on screen.

## Options

1. Keep full draws. Nothing to get wrong; the cost above stays.
2. Draw the union of the rects since each surface's last draw, scissored,
   without the clear. Full draws for everything that is not a plain copy.
3. Show the guest's own buffer (zero copy, 0010 option 3). Removes the draw
   entirely, but needs rectangle sampling in virglrenderer and flip pacing
   against WindowServer: size L, high risk.

## Decision

Option 2. Per surface one box (the union of every flush rect since that
surface was drawn: merged and skipped frames count). Full draws for new
surfaces, another frame size, a scaled frame, the boot logo, the 2D console,
extra brightness, another colour path, a scanout that is part of its
resource, a box of three quarters of the frame or more, a new scanout buffer
until its first flush, and a scanout buffer not among the last four seen: a compositor's own buffers rotate, while a new
one (a client's buffer scanned out directly, a new swapchain) may come with
damage that is not relative to what was shown. The rules are a header without
AppKit or GL, tested on their own; the wiring is checked in the patched
`ui/cocoa.m` at build time and in CI. `OMACVM_GL_PRESENT_DAMAGE=check` draws
every 30th partial frame in full beside it and compares them pixel for pixel
(qemu.log), for tests in a VM.

## Consequences

- Guests before Linux 7.4 send whole-plane rects for a compositor's frames
  (page flips): those stay full draws until their kernel (or OmacVM's
  driver) sends real damage. OmacVM's driver carries the fix
  (`linux-virtio-gpu-damage-clips.patch`, the two upstream commits squashed);
  it loads for a start with "Draw only what changed" on (SMBIOS
  `omacvm.damage=1`, 0055) and for the other switches that load it (HDR,
  the pointer layer, frames in step until 3.2.7; amended in 0049). `omacvm check`'s
  "Changed parts" line says whether the damage reaches QEMU. A buffer flushed again (the boot console, a
  TTY) carries real rects on any kernel, so once on, partial draws happen
  there on today's 7.2 guests too.
- The watt numbers are an offscreen bench (no VM); there is no A/B in a VM
  yet. The 120/s scissored row (+0.02 W) below the 60/s one (+0.06 W) puts
  the noise at about 0.04 W. Where only small parts change, the present's
  share goes from up to +0.19 W (60 frames a second) or +0.47 W (120) to a
  few hundredths, but only at that frame rate: typing is about 9 flushes a
  second (about 0.02 W saved); a moving pointer or a spinner flushes at the
  display's rate. Scrolling and video change most of the frame: no gain
  there.
- A wrong rect from the guest shows as stale pixels until the next full draw.
  The rules only trust rects for buffers already seen; the check mode exists
  to find such guests. The guest kernel reuses resource ids (lowest free),
  so a new buffer can count as one already seen: that is safe while the
  compositor's damage is relative to what the plane showed, as the DRM
  damage contract says.
- WindowServer still composites the whole layer each frame: that part of a
  frame's cost does not change.

## Addendum (2026-11-16): on by default for SDR starts

What changed:

- **The switch.** "Copy only what changed" (`partialPresent`, on by
  default, the VM window's Display section, with an (i)). A start
  (`Settings.partialPresentStart(hdr:)`) sets `OMACVM_GL_PRESENT_DAMAGE=1`
  for QEMU (an inherited `=check` stays) unless the switch is off, GPU safe
  mode is on, the layer present runs (`OMACVM_GL_PRESENT=layer`), the
  environment says `=0`, or the start is an HDR start. qemu.log:
  `OmacVM: partial present: on|off (why)`.
- **Counts** (STANDARDS 3). Once a minute while frames come, QEMU writes
  `partial present, last N s:` with the frames drawn in part (how many of
  them had nothing to draw, the boxes' average size), the frames drawn in
  full and why (not a plain copy, scaled, part of its resource, colour path
  or size changed, new buffer, buffer not flushed yet, three quarters or
  more changed, catching up after a change), the frame and surface size.
  `omacvm check` shows the last count ("Copy only what changed";
  `src/tests/partial-check.sh`).
- **The check mode checks what is shown.** It kept the window's surfaces
  plain (`glReadPixels` crashes on the lossless ones, 0052), so the default
  `'&BGA'` / `'&RhA'` surfaces had never been compared. It now has the GPU
  copy the shown surface into a plain texture of its format and reads that
  one; lossless surfaces stay on. The copy is exact (a picture drawn whole,
  then a box drawn scissored without a clear, read back through the copy:
  0 bytes differ for `'&BGA'` and `'&RhA'`, and the same as a plain
  surface; Core Image's readback agrees; M4, macOS 27:
  work/power-1116/rects/spike/lbread.m). It checks every partial frame for
  a while after a full draw (new surfaces, buffers, colour paths), then
  every 30th. `OMACVM_TEST_PRESENT_DAMAGE_FAULT=half|skip` (check mode
  only) draws only the left half of each box, or none of it, so a test
  shows the check fails when it should (a box 1 px narrower was tried
  first: 0 bad in 172 checks, because a compositor's damage covers about
  three frames and a box's edge seldom changed). Only the check mode can see a wrong box: the guest's own pixels
  (grim, QMP `screendump`) are right whatever QEMU draws, and Mac
  screenshots are not taken in tests (STANDARDS 51).

Which windows can gain. Only a frame shown pixel for pixel is drawn in part
(the frame's size is the surface's, and the surfaces are capped at the
largest display per dimension). A window and native full screen give the
guest the view's own size: they can. Full screen including notch gives the
guest the panel's size rounded up to fit its scale
(omacvm-cocoa-fullpanel-scale.patch): at Omarchy's scales 1, 2 and 4 that is
the panel's size (the 13-inch Air: 2940x1912) and it can; at 1.25, 1.6 and 3
it is a few pixels more (2940x1915, 2944x1912, 2940x1914), over the cap, so
every frame is drawn scaled and in full, as before (the counts say
"scaled"). The 14- and 16-inch panels round the same scales up. Extra
brightness draws in full (its own colour path); the other displays' windows
have their own present and draw in full.

What it gains, restated. The whole present draw costs +0.19 W at 60 frames a
second on the M2 (+0.06 W scissored to 64x64; the bench above), so the
ceiling at 60 Hz is about 0.13 W where only small parts change: about -0.05
to -0.15 W on the Air for a pointer, typing or a clock; a compositor's
buffer-age damage covers about three frames' changes, so boxes are bigger
than one frame's. WindowServer still composites the whole layer (0055's
tiles are the lever for that). Scrolling and video: about 0. Watts are the
Air's rows (power-1116/rects), never the mini's.

HDR starts stay out. They are the only default starts that send real rects
today (OmacVM's driver loads for them), and their half-float lossless
surfaces get `'&RhA'` only on a PQ start. The EDR headroom is not in the
present's signature (deep, PQ, boost, linear, flip, splash, borrow, size,
and the gain only while boosting), contrary to an earlier note: a headroom
change goes to the guest (display sync's `max_luminance`) and Hyprland
applies it without a modeset, so the frames after it are right only if
Hyprland damages the whole output then. Owed before HDR starts get it: the
check mode on an XDR Mac on screen (the vsync composited path, 120 Hz, a
headroom change mid-run).

Tested (hidden test VMs on the Mac mini, functional only; a clone of an
Omarchy 4.5 VM, Linux 7.2.11, Hyprland 0.56.2, the guest at the hidden
window's own 1320x740, frames shown when drawn; work/power-1116/rects/t1):

- Check mode, no fault: 0 differing pixels in 2041 checks. With OmacVM's
  driver at 8 bits on `'&BGA'` surfaces (the driver start of the stacked
  change): boot, pointer circles, a light desktop (terminals, an agent, a
  chat page), typing, workspace switches, Chromium scrolling (60 fps),
  blur on with the pointer over a see-through window, a TTY and back, a
  mode change to 1280x720 and back, a 120 Hz modeline, a guest reboot
  without a QEMU restart, out of sight and back (the spare surfaces went
  volatile and macOS emptied two: drawn whole). PQ on `'&RhA'` surfaces
  (an HDR start with the check mode set by hand): 0 in 243.
- The check finds wrong draws: half of each box drawn, 145 of 158 checks
  bad (`'&BGA'`), 90 of 160 (plain `'BGRA'`), 146 of 174 (PQ, `'&RhA'`);
  none of a box drawn, 156 of 175.
- The stock driver (no driver start): 0 frames in part on the desktop,
  every frame "three quarters or more changed" (its whole-plane rects), so
  this alone gains nothing on an SDR desktop before Linux 7.4.
- The boxes are one bounding box of all that changed since a surface's
  last draw: typing in a terminal gave the whole window (641x690, the
  window's own damage), the light desktop 14 % of the frame on average,
  pointer circles 15-20 %. Several separate small changes make one big box;
  rects per clip are a later step.
- KMS planes, formats, modifiers and properties: the same with the stock
  driver and OmacVM's at 8 bits (drmdump, 0 lines differ).

Owed: the check mode on screen on the vsync composited path (the Air, and
120 Hz on an XDR Mac); tiles and this both on in the check mode (tiles need
the vsync present); a real second display; the desktop restart after a lost
GPU context (0038); Mac sleep and wake and a display change on screen;
moving the window between displays; the guest's lock screen and SDDM with
autologin off; a client buffer scanned out directly (`direct_scanout`);
the GPU copy's readback on an M2; the Air's watts.


## Addendum (2026-11-18): the check counts levels, not bytes

3.5.0's M1 Max rows (full screen including the notch at scale 2, 3024x1964
drawn 1:1, the pointer over windows) found 508-1775 bad checks a start,
in 1-pixel columns and rows at the edges of the pointer's old places and
of window borders. The same rows in a window, at scale 1.6 and on the mini
had none. It was not a wrong box, and nothing could be seen:

- Every differing pixel was 1 level off in one channel: 140249 pixels in
  1801 checks in one start, 97540 in 1604 in the next, none 2 levels or
  more (a test build that measured every pixel of every bad check). A
  stale pointer pixel is 30-200 levels off.
- No flush since the surface's last draw touched the pixels that differed
  (the same build logged the guest's rects since each surface's last
  draw): the rules drew what the guest said had changed.
- The pixels follow the guest's buffer: Hyprland's three swapchain buffers
  held, for example, 1b1c29 in one and 1b1b28 in the other two along a
  window border, white as ffffff in one and fefefe in another, in places
  it no longer damaged. A full draw shows each buffer's own level in turn
  (a 1-level flicker), a partial draw keeps the level of the buffer it
  copied there last. Neither is wrong.
- Blur off changed nothing (617 bad of 3878). Whether Hyprland's animations
  leave the last level without damage is noted in work/release-3.5.0/ptr.
  Timing decides how often it shows: a window, the hidden window, and full
  screen with a kit's 119.93 Hz modeline had none; vsync off had some.

So the check (`omacvm_pd_cmp` in the logic header) counts a pixel as
wrong only when a colour channel is more than 2 levels off, the levels a
guest's own rounding moves; a box that misses a change leaves the old
picture, far more off. Checks with level differences only are counted
apart ("N with level differences only" in the minute line, the first one
logged with its place). The half-box fault stays caught. The partial
present itself did not change.
