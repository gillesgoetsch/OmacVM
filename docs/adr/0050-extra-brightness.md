# 0050: Extra brightness: QEMU draws the VM's frames up to 2x on an XDR display

Status: accepted, built (`extraBrightness`), behind the app's experimental
switch "Extra brightness" (off). Builds on
[0049](0049-hdr-guest-tone-maps.md). Amended 2026-10-21: it wins over HDR
(decision 7; amends 0049: the guest is told headroom 1 while it is on).
Notes and numbers: work/tracks/night-brightness.md,
work/tracks/bar-brightness.md.

## Context

The user asked for an opt-in extra brightness for the VM's window (bright
light), with a caution in its (i), that ends by itself when the VM stops.
XDR panels can show more than the Mac's white (EDR headroom: up to 16x at
low brightness, less at full SDR brightness); a MacBook Air reports a
potential of 2 and has no XDR, an SDR monitor 1.

Doing it in the guest does not work: it needs the HDR switch, the 10-bit
driver and a restart, SDR guests get nothing, and Hyprland 0.56 gives PQ
windows (Chrome) the PQ reference white of 203 nits whatever
`sdr_max_luminance` says, so Chrome would stay at 1x next to 2x terminals.
A plain 2x of a PQ frame doubles HDR highlights and clips them.

## Decision

1. **The Mac side only, in QEMU's present.** With the switch on, the
   IOSurface present draws the guest's SDR frames (8-bit, or 10-bit sRGB)
   through a shader into half-float surfaces tagged extended linear sRGB:
   decoded from sRGB to linear light and multiplied by g. The layer shows
   them with EDR and `toneMapMode` never (macOS's own tone mapping halves
   SDR white below full headroom, 0049). The guest is untouched.
2. **g follows the display, never above it.** g = the window's display's
   headroom now, at most 2, in hundredths, rounded down; read every 250 ms
   on the main thread while the switch is on, the window is seen and its
   display's potential is above 2.05; a move of 0.02 or more redraws the
   newest frame at once (a bottom half in both present modes, so a static
   desktop changes too). macOS lowers the headroom when the Mac is hot or
   the panel bright; g follows it down.
3. **Ask macOS for 2x, not for the panel's most.** On an M1 Max at low
   brightness an EDR layer with untagged content took the panel's headroom
   from 1 to 16 within 2 s (backlight for nothing); with the layer's
   `contentsHeadroom` at 2 it stayed at 2. Boosted frames set it to 2 on
   the commit thread (macOS 26+) and every other frame back to 0
   (untagged), so HDR keeps the full headroom; the surfaces also carry
   `kIOSurfaceContentHeadroom` 2.0 (macOS 15+).
4. **Live, from the app's key.** QEMU runs as the app, so it reads
   `extraBrightness` from its own defaults and watches it with KVO (which
   also reports `defaults write` and the app's window), and reads it again
   when the window is seen again or the app becomes active.
   `OMACVM_EXTRA_BRIGHT=1` covers a QEMU not started as the app. The
   switch is app-wide; the row shows only with a display above 2.05
   (`ExtraBrightness.available`, the same number as QEMU's). The bar's
   Display panel in the VM can switch it too, through the app on the VM's
   own control port ([0031](0031-control-centre-bridge-requests.md)).
5. **It goes back by itself.** Off: the next frame takes the plain 8-bit
   path and the layer drops EDR. Out of sight (hidden, minimised, covered,
   another Space) no frame is drawn. Hidden, macOS drops the headroom about
   15 s later, as after the switch goes off (M1 Max). Fully covered by
   another window it does not: the panel keeps 2x headroom until the window
   shows again or the switch goes off, though nothing on screen is brighter.
   The VM stopped: the layer is gone.
   On a display without the headroom, g is 1 and the frames are 8-bit.
6. **The surfaces decide how a frame is drawn**, not the switch: during the
   half-second realloc hold-off a frame of the other kind goes into the
   surfaces there are and keeps its own colours. The boot logo stays at 1x
   (the start animation's layers next to it are SDR); in linear surfaces
   its clear colour is decoded too.
7. **Wins over HDR** (amended 2026-10-21; 3.1.29 kept it off over HDR,
   "not with HDR yet"). The user: "when HDR brightness is enabled HDR
   would not be effective, when it's disabled normal hdr behaviour again".
   With both switches on, PQ frames (0049) go the same way as SDR frames,
   into the same linear surfaces: the shader decodes PQ to nits, divides
   by 203 (SDR white, the Mac's white), clips each channel at 1 (as
   Hyprland's own clamp), turns BT.2020 into sRGB's primaries (colours
   outside sRGB stay, as values below 0 or above 1) and multiplies by g.
   So SDR white is at g and HDR highlights end there. While boosted, QEMU
   tells the guest headroom 1 (`"edr": 1`; after the cases where PQ cannot
   be shown at all, which stay 0), so the guest fits its HDR into SDR
   white itself (Chrome rolls its video's highlights off) and Hyprland
   changes only the luminance, without a modeset. Off: the next frame goes
   into the PQ surfaces again with a plain blit (HDR at once, SDR white at
   1x) and the guest gets the display's headroom now at once, then follows
   macOS up as before. qemu.log: "on, 2.00x, over HDR".
8. **Fallbacks, said once.** No IOSurface present (GPU safe mode,
   `OMACVM_GL_PRESENT=layer`), untagged colour (`OMACVM_GL_COLOR=native`),
   half-float surfaces failing or the shader not compiling: off for the
   run. The shader is made on the present context the first time it is
   needed, never at start, so a failure there cannot stop a VM. qemu.log:
   `cocoa: extra brightness: on, 2.00x | held back by macOS, 1.40x` (both
   with `, over HDR` while the guest sends PQ) `| not on this display |
   off (why)`, once per change; `omacvm check` reads the last one.

## Options not taken

- In the guest (`sdr_max_luminance = 203 x g` on the HDR output): see
  Context.
- A multiply-blend overlay layer over the VM's layer (what some Mac
  brightness tools do): no shader, but how Core Animation composites it in
  one window is not documented. The fallback if the shader path fails.
- A fixed 2x left to macOS's automatic tone mapping: SDR white drops when
  the headroom is short (0049).
- Core Image filters on the layer: every composite goes offscreen.
- Over HDR, a knee that maps SDR white to g and re-encodes the highlights
  above it up to the headroom: the panel would have to run at its full
  headroom (16x at low brightness: backlight and battery), and the user
  wants HDR off while it is on.
- Over HDR, telling the guest "no headroom" (0: `cm srgb`): Hyprland
  changes its colour mode, and QEMU cannot tell which 10-bit frames are
  still PQ while it does (0049), so some frames would show in the wrong
  colours at each switch.
- Over HDR, extended linear BT.2020 surfaces (no matrix in the shader): a
  third kind of surface for one 3x3 matrix.

## Consequences

- Cost while on: the present surfaces take 8 bytes a pixel instead of 4
  (5 surfaces with vsync: about +154 MB at 3456x2234, more on a 6K
  display; measured on an M1 Max: QEMU +60 to +140 MB) and the shader one
  `pow()` a pixel. Off costs nothing (the
  look does not run).
- Power: the panel's backlight follows the headroom. M1 Max at brightness
  0.1, a white page, 3 min windows: 3.28 W on against 3.22 W off for the
  whole Mac (+2 %, within the noise). Not measured at higher brightness.
- Next to a 2x VM these stay at 1x: windows on other displays, Omanotch's
  strip in native full screen, the start animation, QEMU's cursor layer
  (if Hyprland ever uses the cursor plane), and screenshots and recordings
  (SDR).
- macOS 15 gets wantsEDR, `toneMapMode` never and the surface's content
  headroom; 26 and later also the layer's. Verified on macOS 27 only
  (every test Mac runs 27).
- The M1 Max granted no EDR at all at its lowest brightness (also to
  content at 3x): there the switch changes nothing. Battery and Low Power Mode were not tested: macOS may
  hold the headroom back there, which the "held back" state covers.
- An HDR monitor whose potential is above 2.05 shows the row, and the gain
  works there too.
- Over HDR: no new surfaces (the PQ surfaces are half-float already); the
  shader does two `pow()` and a 3x3 matrix a pixel. Very bright saturated
  highlights go toward white (each channel is clipped on its own, as
  Hyprland's clamp). A client that does not re-read the output's luminance
  keeps its old range and is clipped at SDR white while it is on.
