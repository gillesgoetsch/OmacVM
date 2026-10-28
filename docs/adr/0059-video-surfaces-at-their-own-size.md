# 0059: Video surfaces at their own size: the Mac samples a texture at the size the guest says

Status: accepted, built (`video-edge`, 3.2.11), on by default: the app sends
`omacvm.valogical=1`; `OMACVM_VIDEO_LOGICAL=0` on the Mac and
`OMACVM_VA_LOGICAL=0` in an app of the VM turn it off. Notes, the
investigation and the review: work/tracks/video-bottom-edge.md.

## Context

Mesa rounds a VA-API surface's planes up to 16: a 1920x1080 surface has a
1920x1088 Y and a 960x544 UV texture. An app that shows a decoded surface
itself imports the planes (an EGL dma-buf import) and samples them by
normalized coordinates: mpv with `hwdec=vaapi`, Chrome on Wayland (Omarchy's
default; NV12 counts as renderable there, so Chrome draws the decoder's
frames without converting them: "No ImageProcessor needed"), GStreamer's
sinks, Hyprland for mpv's `vo=dmabuf-wayland`. virgl drops the size an import asks for: the
import is the host's whole texture. So every such app drew the whole 1088
rows into the picture's 1080: the picture squeezed, the rows past it below
it. They were zero (a green bar) until 3.1.32 and the picture's last row
since (`virgl-video-plane-edge.patch`), which a user saw as "the last pixel
line stretched 10 px below" (in Chrome on Wayland: 8 rows of a 1080p
video, 10.7 pixels when it fills a 1440-high screen). Chrome on X11 converts
each picture to ARGB first; the VA-API shim made that exact at the bottom
(3.2.1), not at the right edge of 854 or 360 wide videos.

## Options

1. **A copy of the picture's size per export** (prototyped in the guest
   shim): exact in mpv, about 0.5 ms per 1080p60 frame on an M2, 3.1 MB of
   VM memory per surface, a fence wait per frame, and apps that import once
   (GStreamer, Chromium's V4L2 daemon) would need a copy after every decode.
   Not zero-copy.
2. **The shim reports the rounded size on export**: mpv ignores it (it
   imports at its frame size); nothing gained.
3. **The host re-creates the plane texture at the picture's size**: exact
   and free per frame, but the Mac's textures are immutable (texture
   storage): new GL names under live views in other contexts. High risk.
4. **The host scales the picture over the whole plane**: blurs it and
   breaks every bit-exact reader (`vaGetImage`, FFmpeg's `hwdownload`, the
   V4L2 daemon, the build-time tests).
5. **The host samples the texture at a size the guest says** (chosen): a
   per-resource logical size; shaders that sample such a texture scale
   their normalized coordinates and size queries.

## Decision

Option 5.

- Protocol: a private payload on `VIRGL_CCMD_NOP` ("OMLS", version 1, up to
  8 entries of resource, width, height). Older runtimes run NOP as a no-op
  and skip it; a new command number would end the VA context there. The Mac
  checks each entry (the sender's resource, a one-level single-sample 2D or
  2D-array texture, 0 < size <= its own) and ignores what does not fit,
  without an error: the guest is untrusted. In the fuzz corpus.
- Sampling: a view of such a texture sets a bit in its slot's shader key;
  that variant reads a uniform vec4 (scale, centre of the last logical
  texel) and its lookups use `min(coord.xy * scale, hi)` (TEX, TXP, TXB,
  TXL, TXD with its gradients, TG4); TXQ returns the logical size. The clamp
  stops sampling at the last texel's centre, as a texture's own edge does
  (no alpha or padding bleeds in at a linear edge). One variant for "has a
  logical size", not one per size; the uniform is set only when it changes
  (Apple's GL redoes much of its draw setup after a glUniform call).
  texelFetch, transfers, copies, blits and images are untouched.
- Guest: the VA-API shim declares each 4:2:0 surface Mesa makes at a size
  that is not a multiple of 16 (Y W x H, UV half rounded up), from an export
  and the planes' resources, one submit per `vaCreateSurfaces2`, no fence.
  Only the owner declares: imports never do (a camera frame of its own size
  stays as it is), so two apps cannot fight over a size. RGB surfaces are
  not declared: Mesa converts an RGB surface to YUV by its texture's size
  (`vl_compositor.c`), which a declared size would squeeze; Chrome's ARGB
  frames keep the 3.2.1 fill.
- Mesa's own reads through its compositor: VA-API video processing (FFmpeg's
  `scale_vaapi`, mpv's `vavpp`, GStreamer's `vapostproc`, Chrome's
  conversion on X11) takes the source region in parts of the size Mesa has
  for the source (its own surface: the planes rounded up to 16; an import:
  the size it was imported at), and the Mac then scales the lookup to the
  declared size: twice. So the shim scales a declared source's region by
  Mesa's size over the declared one, in every process (1920x1080: the
  picture's 1080 rows are 1088 of Mesa's), and Chromium's fill leaves
  declared sources alone: never both. Every import of a declared surface
  counts as declared at that surface's size, whatever size it asks for (one
  size per resource on the Mac). `vaGetImage` into another format (RGB,
  packed YUV) converts with the same compositor; the shim has Mesa read an
  import of the planes at the picture's size instead (same resources, no
  copy). The first version of this change missed both (review): FFmpeg's
  `scale_vaapi` from a 1080p decode lost its last 8 rows.
- The edge fill stays on: for an older VM side or app, undeclared surfaces,
  lookups at the very edge (gather, offsets) and texel reads near it.
- Gated by `omacvm.valogical=1` (host.env), read once when the driver loads.
  An older app or `OMACVM_VIDEO_LOGICAL=0` sends no marker and the guest is
  as before; an older VM side sends no declarations and the Mac is as
  before.

## Consequences

- Exact video geometry in every app that samples the planes, with no copy
  and no wait: two ALU operations per lookup in those shaders.
- Texel reads are unchanged and stay bit-exact: `vaGetImage` into the
  surface's own format and FFmpeg's `hwdownload` (framemd5 equal to FFmpeg's
  software decoding with the declarations on: VP9 at 1080p, 360p, 854x480,
  360x640 and 1000x562, HEVC at 1080p and 854x480, H.264 at 1080p), `vaDeriveImage`, the shim's
  I420/YV12 copies, the V4L2 daemon's texelFetch, the build-time decode
  tests. Mesa's compositor reads (video processing, a converting
  `vaGetImage`) resample by nature: on the test card they land exactly as
  with 3.2.10 (red band 8 rows and columns, lines in place), not bit for
  bit.
- Not covered: surfaces the decoder asks for larger than the picture itself,
  at the stream's coded size (FFmpeg in mpv, Chrome on Wayland): H.264 at every size that is not a multiple of 16
  (1080p in 1088 rows, 360p in 368, 854 wide in 864) and HEVC at sizes that
  are not a multiple of 8 (1000x562 in 1000x568). VA-API carries no crop,
  so the shim declares the surface's size and the app shows the stream's
  padding rows (a surface whose coded size is a multiple of 16, such as
  1080p H.264's, is not declared at all): in Chrome on Wayland an H.264
  1080p video keeps the 8-row strip (the encoder's padding rows, usually
  the last row repeated). A real fix would be virgl
  honouring the import's size (a view of that size) and the app cropping,
  in Mesa and virglrenderer upstream.
- Chrome on Wayland with GL (the user's command line: `--ozone-platform=wayland`,
  no Vulkan) decodes without an image processor ("No ImageProcessor
  needed") and draws the NV12 planes whole, like mpv. Measured on a test
  VM (Chrome 154, M4, the user's switches): 3.2.10 showed the strip at
  every size and codec (1080p red band 15.75 rows; 854x480 and 360x640 at
  the right); with this change VP9, AV1 and HEVC are exact at 1080p, 360p,
  854x480 and 360x640, except where the decoder's surface has the coded
  size (below): H.264 is unchanged at all four sizes, HEVC 854x480 shows
  2 coded columns. Without `--ozone-platform=wayland` (X11) Chrome converts
  to ARGB and is exact. A Vulkan compositor would sample through Venus,
  which this does not reach (not measured).
- A wrap mode other than clamp-to-edge on a declared texture clamps at the
  logical edge; LOD queries (`textureQueryLOD`) are not scaled. No video
  path uses either.
- An import of a declared surface in another process at another size would
  still be sampled at the owner's size (one size per resource); Chrome
  imports at the size it allocated.
- Tests: `Tests/virgl/test-video-logical-size.c`, the fuzz seeds
  `seed-nop-logical*`, `src/app/guest/tests/va-shim-logical.sh` (also video
  processing regions and a converting `vaGetImage`), and in a test VM
  `tests/video/video-geometry.sh` (mpv, Chrome, Chromium, Firefox on a test
  card, Chrome's path per row; 3.2.10 fails it, 3.2.11 passes with the
  known cases above). Mesa's compositor paths were measured in a test VM
  with FFmpeg (`scale_vaapi=format=bgra`, `hwdownload,format=bgra`): exact
  with 3.2.10, with this change, and with `OMACVM_VA_LOGICAL=0`; the first
  version of this change lost the red band at every declared size.
