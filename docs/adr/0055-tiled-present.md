# 0055: Tiled present: only the changed tiles of a frame go to WindowServer

Status: accepted, built (`omacvm-cocoa-present-tiles*.patch`), off by default:
the experimental switch "Draw only what changed" (`presentTiles`, the VM
window's Display section) or `OMACVM_GL_PRESENT_TILES=1` (`=check` for tests).
It acts only when the guest says what changed: Linux 7.4, or OmacVM's
virtio-gpu driver with the damage fix ([0051](0051-partial-present.md), #520),
which the switch asks the VM to load (SMBIOS `omacvm.damage=1`; not in GPU
safe mode); the switch ships with that driver (on a stock 7.2 guest it would
do nothing). Notes and numbers:
work/tracks/window-draw.md.

## Context

QEMU's present ([0010](0010-iosurface-present.md)) puts every guest frame on
the view's layer as a new whole IOSurface. WindowServer cannot know which
pixels of it changed, so it composites the whole window again for every frame,
also when only a caret blinked or a spinner turned. 0051 makes QEMU's own draw
into the surface partial; WindowServer's composite stays whole.

What that costs, measured without a VM (work/window-draw/kit/wdbench.m, a window
like the VM's): on a MacBook Air M2 at 60 frames a second, full screen SDR, the
whole Mac draws 2.22 W idle and 3.09 / 3.15 W with a whole new surface per
frame (WindowServer 155 GPU ms/s). The same window as a grid of 16x10 tile
layers, only 2 of them getting a new surface per frame: 2.46 W (WindowServer
35 GPU ms/s, our copy 31 instead of 98); 8 tiles: 2.75 W. WindowServer's work
follows the changed area once only those layers change.

Not counted: the MacBook Pro M1 Max rows of the same bench (120 frames a
second, half-float HDR surfaces, 3024x1896: 4.45 W idle, 8.49 W with whole
frames; 2 tiles: WindowServer 51 instead of 124 GPU ms/s). They were single
rows at brightness 0, where the panel has no EDR headroom, and were taken
before all M1 Max rows of that day were started over. They show where the
cost is, not what tiles save there; the M1 Max is measured again.

## Options

1. Keep whole frames. WindowServer composites the whole window per frame.
2. Direct to the display (no composite at all): needs a full-screen opaque
   CAMetalLayer and nothing above it. No setup went direct in our rows (also a
   bare CAMetalLayer, untagged, over the notch), and on the user's M1 Max an app
   keeps a 1x1 window above everything, which forces a composite for every
   full-screen app.
3. Tiles: a grid of tile layers over the last whole frame; a frame that changed
   little gets new surfaces for its changed tiles only.

## Decision

Option 3, experimental. 256x256 tiles; a frame whose changed box (the
guest's flush rects since the last frame drawn, one box) touches at most 12
tiles is drawn into those tiles' own surfaces (up to five per tile, as the
whole frames, made when needed, in the whole surfaces' format and colour
space; at most 32 tiles keep theirs, the least recently drawn give theirs back
first, and none 10 s after the last frame in tiles) and only those tile
layers change; else a whole frame, which hides the tiles. Nothing changed:
nothing is presented. Whole frames for everything 0051 draws in full (boot
logo, extra brightness, another size or colour path, a buffer not seen lately
or not flushed yet), and whenever the window does not show the frame pixel for
pixel. Each whole frame shown measures that; tiles that do not fit hide, and
frames stay whole until a whole frame finds the window showing it pixel for
pixel again (a window that scales the picture never goes back and forth
between tiles and whole frames). Frames the present queue
skips hand their tiles to the frame after them, so nothing changed is lost.

## Measured (a real VM)

MacBook Air M2, the VM full screen at 60 Hz with #520's driver, A/B/A/B,
180 s windows, whole-Mac power: the pointer moving (Hyprland draws it) 3.13 /
3.12 W with tiles, 3.75 / 3.75 W without (WindowServer 43 vs 154 GPU ms/s,
guest 59.9 frames a second either way); a scrolling terminal and typing: no
change. A second set with the final code (three rounds, a new clone of the
same VM): 3.16 / 3.16 / 3.17 W with tiles, 3.55 / 3.56 / 3.55 W without
(WindowServer 43 vs 155 GPU ms/s, 59.9 frames a second either way). So the
pointer moving costs 0.39-0.62 W (11-17 %) less. Pictures of the window,
tiles on vs off: 0 pixels differ; the check mode never found a differing tile
(0 of 524 checks in the second set; all rows up to 3456 pixels wide).

MacBook Pro M1 Max, HDR at 120 Hz (3024x1896, XRGB2101010, EDR headroom
11.43 on both sides), the VM full screen on the built-in panel at brightness
0.50, OmacVM's driver on both sides (an HDR start loads it), only QEMU's
tiles on or off, 180 s rows on/off/on/off (2026-10-26, m1-bench set td2):
WindowServer 129 vs 198-209 GPU ms/s with the pointer moving, 47 vs 216 with
a spinner. Whole-Mac power, a first measurement only: 19.83 / 20.18 W with
tiles, 21.98 / 22.09 W without (pointer), 13.48 vs 16.89 W (spinner, one
pair). A macOS prompt (Local Network) was on screen over the VM on both
sides and the two pointer rounds do not agree well, so these watts are not
counted until the set is run again without it (td2b). Guest 119-120 flushes and 120 vblanks a second either
way; about half of the ~7170 frames a minute went in tiles. HDR pictures,
tiles on vs off from fresh starts: the same within a step; the check mode
0 of 601 differed.

## Consequences

- WindowServer composites the changed tiles only; QEMU draws only them.
- Up to 12 small GL passes a frame instead of one large one: more than 12
  changed tiles is one whole frame.
- Up to five surfaces for each of at most 32 tiles (3024x1896: 42 MB of 10-bit
  or 8-bit tiles, 84 MB half float), given back 10 s after the last frame in
  tiles.
- No gain without the guest's damage: Linux before 7.4 flushes the whole
  plane on every page flip (then every frame is whole, as with the switch off).

## Addendum (3.2.15): each tile is drawn inside its own surface

3.2.14 drew a tile as the whole frame's quad moved by -x, -y onto the
tile's 256x256 surface (`glViewport(-x, -y, frame width, frame height)`).
Apple's OpenGL (4.1 on Metal) draws a viewport that starts more than 4096
pixels outside its target squeezed (on the M1 Max 4097 is still right, 4100
is not): the start becomes -4096 and the far edge stays, so the picture is
scaled into the smaller span. The driver
reports `GL_VIEWPORT_BOUNDS_RANGE` -32768..32767, and GL says the start is
clamped to that range with the size kept, so this is a driver fault; the
software renderer draws it right. Tiles that start past x 4096 exist only
on pictures wider than 4352 pixels: full screen on a 5K or 6K display, a
4K display set to look like more than 2176 points wide, the 24-inch iMac
(4480), or a window that wide. There each of them came out squeezed,
anchored at the picture's right edge (5120 wide: the last three columns at
0.95, 0.90 and 0.85; columns 17 and 18 squeeze toward x 5120, not toward
their own right edge), and stayed until a whole frame hid the tiles.
Frames of the pointer alone (tiles) and whole frames (an app repainting)
took turns, so the right part flickered while the pointer moved there;
where the last column starts (128 points from the right edge at 5K) the
right picture met the squeezed one and a line in it showed twice. Rows are
never affected (the last row of the largest grid starts at 3840). Every
earlier tiles row was at most 3456 pixels wide, so the check mode never
met such a tile. Found from the user's report and screen recording (Mac
mini M4, LG UltraFine 5K): the squeeze fitted there is 0.850 starting 256
pixels from the right, the same as the M1 Max's driver gives for the last
column.

Now each tile is drawn with the viewport inside its own surface (0, 0, its
width, its height), and its part of the frame comes from texture
coordinates: a tile program (QEMU's blit shaders with the part as a
uniform; the text and the part's maths in `ui/omacvm-present-tiles.h`)
with its own quad, made where the switch is first read. If it does not
build, tiles stay off for the run ("tiled present: off (the tile shader
does not build: ...)") and frames are whole as before. No viewport in the
present starts outside its target.

Rejected:
- `glBlitFramebuffer` from the frame into each tile: its alpha and sRGB
  handling differ from the whole frame's blit, and it was never tried on
  Apple's driver.
- Tiles only left of x 4096: simplest, but it loses the saving on the
  right side of big displays, where the bar and the pointer are.
- A part rectangle in QEMU's `ui/shader.c`: the gtk, egl and dbus displays
  share it.

Tests: `test-present-tiles.c` checks every fragment's texture coordinate
against the centre of the texel the whole frame samples (5 sizes, both
flips); `test-present-tiles-gl.m` draws every tile and compares it with the
whole frame on Apple's software renderer (CI, the runtime build), `--gpu`
on a test Mac's GPU. M1 Max (macOS 27.0.1, 4.1 Metal - 91.7), 3.2.14's draw:
36 of 240 tiles differ at 5120x2880 (also in half-float surfaces), 98 of
336 at 6016x3384, 112 of 384 at 6144x4096, 10 of 180 at 4480x2520, 0 at
3024x1964; the tile program: 0 at every size, both flips, 8-bit and
half-float.

## Addendum (2026-10-31): the release row

A hidden test start (`OMACVM_COCOA_HIDDEN`) never orders its window in, so
its view's display link never ticks: QEMU presents its first frames and
then none, and no tiles check runs. 3.2.15's gate row for #637 said ok
with 0 checks. Releases run `src/tests/e2e/present-locked.sh` instead, on a
locked test Mac: the test app's window ordered in on a virtual display
made for the run (60 Hz, a new serial each time), guests at 5120x2880 and
6016x3384, check mode, a guest pointer at the top right. Under the lock
macOS composites none of it (0 of 900 drawables presented on the locked
M1 Max), but the window gets its display's frame clock and QEMU runs the
real present. Locked M1 Max (macOS 27.0.1), present-locked.sh, a guest
pointer at the top right for 120 s: 3.2.14 98 of 196 checks differed at
5120x2880 and 197 of 198 at 6016x3384; 3.2.15 0 of 198 and 0 of 195, about
2600 frames a minute in tiles and 440 whole. A private unlock notice in the
middle of a row ended the test app's 2 processes before the display went,
with none of its windows on another display in 496 samples.
Not covered: WindowServer's composite, 120 Hz pacing, the hold for a
window nobody sees (present-unseen), the look on a real panel.
