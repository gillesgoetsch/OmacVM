# 0059: Video surfaces at their own size: the Mac samples a texture at the size the guest says

Status: accepted, built (`video-edge`, 3.2.11), on by default: the app sends
`omacvm.valogical=1`; `OMACVM_VIDEO_LOGICAL=0` on the Mac and
`OMACVM_VA_LOGICAL=0` in an app of the VM turn it off. Notes, the
investigation and the review: work/tracks/video-bottom-edge.md.

## Context

Mesa rounds a VA-API surface's planes up to 16: a 1920x1080 surface has a
1920x1088 Y and a 960x544 UV texture. An app that shows a decoded surface
itself imports the planes (an EGL dma-buf import) and samples them by
normalized coordinates: mpv with `hwdec=vaapi`, Chrome when NV12 is
renderable (Vulkan, or its zero-copy GL path), GStreamer's sinks, Hyprland
for mpv's `vo=dmabuf-wayland`. virgl drops the size an import asks for: the
import is the host's whole texture. So every such app drew the whole 1088
rows into the picture's 1080: the picture squeezed, the rows past it below
it. They were zero (a green bar) until 3.1.32 and the picture's last row
since (`virgl-video-plane-edge.patch`), which a user saw as "the last pixel
line stretched 10 px below". Chrome's usual GL path converts each picture to
ARGB first; the VA-API shim made that exact at the bottom (3.2.1), not at
the right edge of 854 or 360 wide videos.

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
  frames keep the 3.2.1 fill. Declared surfaces (and imports of them in the
  same process) get no source-region scaling from that fill: never both.
- The edge fill stays on: for an older VM side or app, undeclared surfaces,
  lookups at the very edge (gather, offsets) and texel reads near it.
- Gated by `omacvm.valogical=1` (host.env), read once when the driver loads.
  An older app or `OMACVM_VIDEO_LOGICAL=0` sends no marker and the guest is
  as before; an older VM side sends no declarations and the Mac is as
  before.

## Consequences

- Exact video geometry in every app that samples the planes, with no copy
  and no wait: two ALU operations per lookup in those shaders.
- `vaGetImage`, `hwdownload`, the V4L2 daemon's texel reads and the
  build-time decode tests stay bit-exact.
- Not covered: surfaces FFmpeg asks for larger than the picture itself:
  H.264 at 1080p (1088 rows) and HEVC at sizes that are not a multiple of
  8 (its coded size: 1000x562 in 1000x568). VA-API carries no crop, so the
  shim declares the surface's size and mpv shows the stream's padding
  rows (a 1080p H.264 is not declared at all). A real fix would be virgl
  honouring the import's size (a view of that size) and the app cropping,
  in Mesa and virglrenderer upstream.
- Chrome's path without an image processor (NV12 renderable: Vulkan, or
  zero-copy GL with NV12 buffers) samples the planes in its compositor; on
  GL that is covered like mpv. In the test VMs Chrome 154 converted to
  ARGB with every flag tried (GL, ZeroCopyGL, `--use-vulkan`), so that
  path was not measured; a Vulkan compositor would sample through Venus,
  which this does not reach.
- A wrap mode other than clamp-to-edge on a declared texture clamps at the
  logical edge; LOD queries (`textureQueryLOD`) are not scaled. No video
  path uses either.
- An import of a declared surface in another process at another size would
  still be sampled at the owner's size (one size per resource); Chrome
  imports at the size it allocated.
- Tests: `Tests/virgl/test-video-logical-size.c`, the fuzz seeds
  `seed-nop-logical*`, `src/app/guest/tests/va-shim-logical.sh`, and the VM
  rows in work/tracks/video-bottom-edge.md.
