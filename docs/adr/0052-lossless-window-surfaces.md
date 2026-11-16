# 0052: The VM window's surfaces are lossless-compressed

Status: accepted, built (`window-path`; half float: `hdr-surfaces`), on by default on
macOS 27 (`OMACVM_GL_LOSSLESS=0` keeps plain surfaces). Notes and numbers:
work/tracks/window-path.md, work/tracks/hdr-surfaces.md.

## Context

Each guest frame is drawn by QEMU into one of the window's IOSurfaces (2940x1840 on a
MacBook Air: 21 MB) and read again by WindowServer for its composite. Measured on the
Air, the window costs about 0.5 W at 30 frames a second, and its GPU time is not what
costs: taking WindowServer's colour matching out of its composite (frames in the
display's colour space, tried and dropped: work/tracks/window-path.md) took a third off
its GPU time and nothing off the watts. What costs is moving the pixels. Apple GPUs
keep surfaces in a lossless-compressed layout when asked ('&BGA',
`kCVPixelFormatType_Lossless_32BGRA`); VideoToolbox and Apple's apps use it. Such a
surface cannot be read back (not on the CPU, not with `glReadPixels`), and the present
does not read its surfaces back, except in a test mode (below). The boot logo's readback
reads the guest's texture. GL draws into one exactly (read
back through Core Image: 0 codes off, on an M1 Max, an M2 and an M4).

## Decision

1. The present's 8-bit surfaces are made through CoreVideo as lossless-compressed BGRA,
   tagged sRGB as before.
2. Half-float surfaces (HDR, Extra brightness) stay plain: there is no such layout for
   them here.
3. If one cannot be made or bound to GL, every surface is plain `BGRA` for the rest of
   the run (one warning in qemu.log). qemu.log names the kind when it changes.
4. Only on macOS 27 and newer for now: there it is checked on an M1 Max, an M2 and an M4
   (the picture as a layer's contents, captured with ScreenCaptureKit: the same pixels
   as plain surfaces). MacBook Air M2: the real VM, a 144-patch page. M1 Max (built-in
   ProMotion panel, 120 frames a second) and Mac mini M4 (an external LG UltraFine, 60):
   `work/window-path/oncheck.m`, GL drawing with a shader into the shown surface as QEMU
   does, 0 codes off and the full frame rate. No Mac here runs an older macOS, and a
   surface the system cannot show would be a black window, not an error.

## Consequences

- MacBook Air M2, the real VM full screen at 60 Hz, A/B/A/B: scrolling 4.45 W against
  4.65 W plain (-0.20 W, -4 %); a 1080p30 video the same within the gauge's noise. The
  same pixels on screen (a 144-patch page: all identical) and the same frame rates.
- QEMU's own draw takes 20-25 % less GPU time (a window like the VM's, no VM).
- How much a frame saves depends on the picture: flat areas and text compress much
  more than video.
- Nothing may read these surfaces back: not on the CPU, and not with `glReadPixels`,
  which crashes the process on them (M4, macOS 27). The partial present's check mode
  (`OMACVM_GL_PRESENT_DAMAGE=check`, ADR 0051) kept the surfaces plain for that until
  3.4.7; from 3.5.0 it has the GPU copy the shown surface into a plain texture and reads
  that one (exact for '&BGA' and '&RhA', work/power-1116/rects/spike/lbread.m), so it
  checks the lossless surfaces that are shown. test-present-lossless.sh checks both: no
  CPU read, and no `glReadPixels` with a present surface attached anywhere.

## Update: half float (2026-10-26, PR #536)

- Half-float surfaces of HDR (PQ) and Extra brightness (linear light, with or without
  HDR) are lossless too ('&RhA', `kCVPixelFormatType_Lossless_64RGBAHalf`); this
  replaces point 2. A 10-bit scanout without HDR keeps plain half float (not checked on
  screen; the app turns 10-bit on only with HDR), and so do frames the layer shows
  without EDR (`OMACVM_GL_COLOR=native`, a dev setting). A half-float failure makes only
  half-float surfaces plain for the run; an 8-bit failure makes both kinds plain
  (point 3). GL draws into them exactly within half-float rounding,
  values above 1 included (M1 Max, M2, M4: work/window-path/lbcheck16.m).
- Checked on an M1 Max's XDR panel (macOS 27, 120 Hz, brightness 0.50) through
  WindowServer (ScreenCaptureKit HDR capture, work/hdr-surfaces/kit/hdrcheck.m `cmpq`,
  in the light the panel gives): HDR PQ and Extra brightness pictures are identical to
  plain half float (all pixels, Delta E ITP 0, the same EDR headroom; a picture one code
  up is caught), colours outside Display P3 and highlights up to 6x SDR white included;
  the VM's own HDR pictures (a BT.2020 PQ clip) identical too. Mac mini (SDR display):
  identical. Whole Mac, M1 Max, HDR on, A/B twice: a 1080p60 clip -0.62 W (-3.2 %),
  scrolling -0.53 W (-4.5 %); over Extra brightness -0.55 W (-2.6 %) and -0.56 W
  (-4.0 %, one round); the same frame rates and EDR headroom. MacBook Air, Extra
  brightness, scrolling at 60 Hz: -0.19 W (-4 %).
- Not checked: M3 and M5 GPUs (both kinds; GL drawing was read back on an M1 Max, an
  M2 and an M4 only). A wrong picture without a GL error has no automatic fallback,
  as for 8-bit since 3.2.1: `launchctl setenv OMACVM_GL_LOSSLESS 0`, then quit and
  reopen the app, keeps every surface plain.
- Tried and dropped: HDR in plain 10-bit surfaces ('l10r', the guest's codes, half the
  bytes of half float; CoreVideo has no lossless 10-bit RGB form). On the XDR panel one
  patch of BT.2020 colour outside Display P3 came out differently from half float (Delta
  E ITP 13.45 on screen; a VM clip 18.8), though Core Animation's own renderer offscreen
  showed them within a code. It saved no more than lossless half float (M1 Max: clip
  the same, scrolling 0.18 W more), so only the lossless half-float part ships. Notes:
  work/tracks/hdr-surfaces.md.
