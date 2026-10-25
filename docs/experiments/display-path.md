# What each frame costs on the way to the screen (OmacVM.app)

Weekend run 2026-10-25, lane frame-path. Goal: power close to macOS's own for the same task. This page
lists the passes a frame goes through, what each one costs in watts and GPU time, what was changed
(partial present, [ADR 0051](../adr/0051-partial-present.md)) and what was not, with the reasons.
The bench tool is [display-path/passbench.m](display-path/passbench.m).

## The passes

A frame of the desktop (pointer, typing, a scrolling page):

1. The app draws its window in the guest (Chrome: Skia on ANGLE on virgl).
2. Hyprland draws the frame into a work buffer (only the damaged parts), then
3. copies the damage into the scanout buffer (two passes on every frame: Hyprland 0.56
   `CHyprOpenGLImpl::begin/end` always render off-screen first).
4. QEMU's present draws the scanout into one of its IOSurfaces (`qemu-cocoa-gl-present-iosurface.patch`).
5. WindowServer composites the layer.

A video frame in Chrome adds, before 1:

- VideoToolbox decodes on the media engine into an IOSurface (NV12);
- virglrenderer copies its two planes into the guest's VA surface (`virgl-videotoolbox-decode.patch`,
  plus the edge fill of `virgl-video-plane-edge.patch`);
- Chrome converts the NV12 surface to an ARGB frame (VA-API video processing in Mesa), because with Skia
  on GL it cannot sample NV12 (chrome-hw-decode); Omarchy's Chromium (V4L2) has vdecd do the same
  conversion; then Chrome draws the frame into its window (1).

## What each pass costs

**Offscreen bench, no VM** (`passbench`: the present's own draw and the plane copy on the Mac's OpenGL at a
fixed rate, no window). MacBook Air M2, whole-Mac power (battery gauge SystemLoad, 180 s a row, brightness 0,
plugged in, not charging), 2940x1840 (the Air's full screen at scale 2):

| Row | Watts | Over the loop without a draw |
|---|---|---|
| Fence and flush only, 60/s | 2.104 | - |
| The present's draw as shipped, 60/s | 2.294 | +0.190 |
| The same without the clear and the alpha mask | 2.297 | +0.193 |
| Drawn only in a 64x64 box, 60/s | 2.167 | +0.063 |
| The present's draw as shipped, 120/s | 2.574 | +0.470 |
| Drawn only in a 64x64 box, 120/s | 2.123 | +0.019 |
| VideoToolbox plane copy, 1080p30 | 2.081 | about 0 |
| VideoToolbox plane copy, 4K30 | 2.138 | +0.034 |

GPU time per draw (the process's AGX `accumulatedGPUTime`): on the M2 it follows the size (full 1767 us,
64x64 box 591 us); on an M4 Max it is mostly a fixed cost per pass (full 563-727 us, a 64x64 box 213-406 us,
a whole draw into a 64x64 surface 422-441 us). An extra `glFlush` costs about 45 us; the edge-fill blits and
the textures made per video frame cost nothing measurable.

**In a VM** (MacBook Air, Chromium full screen-ish, guest 2940x1840, from the vm-power lane's rows; the
same task natively in Chrome on macOS):

| Task | macOS | VM | QEMU GPU ms/s | WindowServer GPU ms/s (macOS) |
|---|---|---|---|---|
| Idle | 2.00 W | 2.11 W | 0 | 0 |
| 1080p30 video, window in view | 2.60 W | 3.89-3.97 W | 157-173 | 59-77 (40) |
| The same, VM window hidden (no present, no composite) | | 3.37 W | 153 | 0 |
| Page scrolling, 60 Hz | 2.74 W | 4.67 W | 213 | 151 (111) |
| Page scrolling, 120 Hz | 2.98 W | 6.48 W | 434 | 189 (229) |
| Typing (~9 characters a second), 60 Hz | 2.39 W | 2.55 W | 23 | 19 (9) |

So for video the guest's own passes are most of QEMU's GPU time (153 of ~170 ms/s even with the window
hidden); the present and WindowServer together are about 0.5 W at 30 frames a second. Scrolling repaints
the whole frame every frame: 3.5-3.6 ms of QEMU GPU time per frame at 60 and at 120 Hz, the present's draw
~0.19 / ~0.47 W of it (rows above), the rest is Chrome's drawing and Hyprland's two passes.

## Partial present (built, off by default: PR #519, ADR 0051)

Each present surface keeps what it showed, so only the box the guest flushed since that surface's last
draw is drawn into it again. It stays off until a VM run in a composited window shows it draws right. It
acts only when the guest sends real flush rects: Linux up to 7.3 sends the whole plane on every page flip
(`virtgpu_plane.c`, `ignore_damage_clips`), so on today's 7.2 guests only a buffer flushed again (boot
console, TTYs) gets partial draws; Linux 7.4 keeps the compositor's damage (upstream 730f8554f35c,
a9cc9905ddb7; OmacVM's driver with that fix: draft PR #520). In the offscreen bench (no VM) the draw
costs 0.13 W less at 60 frames a second and 0.45 W less at 120 when only a 64x64 box changes on every
frame (noise about 0.04 W). That is the most it can save, and only at that frame rate: typing (~9
flushes a second) would save about 0.02 W. On today's guests the desktop's frames save 0 W. No VM A/B yet.

## Direct scanout (spike)

Pending.

## Zero-copy video: design, size, risk (not done)

Today a decoded frame is copied once on the Mac before the guest sees it: VideoToolbox decodes into an
IOSurface (NV12 or P010), and `blit_pixbuf_to_video_buffer` (virgl-videotoolbox-decode.patch) binds its two
planes as rectangle textures and blits them into the guest's plane textures (R8 + RG8, the VA surface Mesa
made), plus the edge fill (virgl-video-plane-edge.patch). Zero copy means the guest's VA surface *is* the
IOSurface.

### What it would take

1. **Storage.** A VA surface's planes are virgl resources whose host storage is a `GL_TEXTURE_2D` (or a
   2D array) that vrend made when the guest created the surface. Apple's OpenGL binds an IOSurface only as
   `GL_TEXTURE_RECTANGLE` (`CGLTexImageIOSurface2D`). So the resource would have to become a rectangle
   texture, and every guest shader that samples it (Mesa's VA video compositor for Chrome's NV12 -> ARGB
   step, vdecd's NV12 -> ARGB pass, mpv, Firefox) samples a `sampler2D` with normalised coordinates.
   vrend would need a shader variant per sampler binding that turns `texture(sampler2D, uv)` into
   `texture(sampler2DRect, uv * size)`, keyed on which bound views are IOSurface-backed. vrend already keys
   variants on sampler state (shadow, swizzle), so the mechanism exists, but it touches every draw path.
   The Vulkan-windows patch (ADR 0047) avoided exactly this by re-striding into a 2D texture on use: that is
   a copy again.
2. **Lifetime.** VideoToolbox hands out a new IOSurface from its own pool for every frame; the guest's
   surfaces are fixed objects (Chrome keeps 10-17 decode surfaces and 16 ARGB frames). The resource's
   storage would be re-pointed at each decode, and the CVPixelBuffer held until the guest decodes into that
   surface again, so VideoToolbox's pool grows to the guest's surface count (1080p NV12: 3.1 MB each, 4K:
   12.4 MB each; ~17 surfaces = 53 / 211 MB of extra host memory, guest-controlled: needs a cap).
   `VTDecompressionSession` cannot be told to decode into a given buffer, only to use a pool with given
   attributes.
3. **Sync.** Today the copy is fenced into the guest's context. With shared storage, a re-decode into a
   surface the guest still samples would show the next picture early; the guest's own VA sync points
   (vaSyncSurface) would have to map to holding the old CVPixelBuffer until the guest's last read finished.
4. **Rounded planes.** Mesa rounds planes to 16 (1080 -> 1088 rows). VideoToolbox's buffers have the
   picture's size, so the guest would sample past the IOSurface's rows (the green-bar bug in another form)
   unless the shader variant also clamps coordinates.

### What it would save

The copy reads and writes the frame once on the GPU: 1080p NV12 3.1 MB + 3.1 MB per frame, 4K 12.4 + 12.4 MB.
passbench (offscreen, same code path): 0.39 ms GPU per 1080p30 frame on the M4 Max, 0.48-0.51 ms at 4K, mostly
a fixed cost per pass; on the Air about 0 W at 1080p30 and +0.03 W at 4K30 (table above). The guest's own passes after the
copy (Chrome's NV12 -> ARGB, Chrome's compositing, Hyprland's two passes, QEMU's present, WindowServer)
stay as they are.

### Size and risk

- Size **L**: vrend storage swap + per-binding rectangle shader variants + pool lifetime with a guest-memory
  cap + sync mapping + coordinate clamping, for 2-plane and 3-plane formats, both decode paths (VA-API and
  vdecd). Tests: bit-exact compares for every codec and odd size (the existing padding test set), plus
  every guest app that samples video surfaces.
- Risk **high**: it changes how every video texture is sampled, in a part of virglrenderer that already had
  three shader bugs this month (sampler swizzle, 2D view of a 2D array, const buffer 0); a mistake shows as
  wrong or black video for everyone. The fallback (the copy) has to stay for ANGLE, MoltenVK-only hosts and
  formats the variant does not cover.
- Not done: the gain is one GPU pass of the video's size, below the per-frame cost of the guest's own
  compositing; not S/M.

### Scanout zero copy (the other half of "straight to the screen")

QEMU's present copies the guest's scanout into an IOSurface every shown frame (ADR 0010 option 2). Option 3 of
that ADR, the guest's scanout buffers as IOSurfaces shown directly as the layer's contents, has the same
rectangle problem (screencopy and Hyprland's mirror sample the buffer) plus pacing: the guest may draw into a
buffer again once its flip completes, while WindowServer can still be reading it, so QEMU would have to hold
the flip's completion until the IOSurface is no longer in use. Size L, risk high (every frame, tearing).
Gain: the present's draw, +0.19 W at 60 and +0.47 W at 120 frames a second on the Air (table above); partial
present takes most of that already while little changes.

### Cheaper ways to the same passes

- **Hyprland direct scanout** for a full-screen client (render:direct_scanout 1): the client's buffer goes to
  the plane as it is, which skips Hyprland's two passes (work buffer + copy to the scanout buffer). Blocked in
  our VMs by the primary plane offering only XRGB8888 (a client's buffer in another format cannot go on it;
  Linux 7.4 adds ARGB8888) and by the software cursor while it shows (not once it hides). Spike: see
  the direct-scanout rows.
- **Skia on Vulkan** in Chrome removes Chrome's NV12 -> ARGB step (VA-API video processing) because NV12 counts
  as renderable there (the chrome-hw-decode lane's finding): the browser-gpu lane's field.
