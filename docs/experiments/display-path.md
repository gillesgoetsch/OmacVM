# What each frame costs on the way to the screen (OmacVM.app)

Power work of the weekend run 2026-10-24 to 2026-10-26 (lanes frame-path, window-path, guest-scanout,
hdr-pass, window-draw, background-power, direct-display, m1-power, m1-bench). The power work stopped on
2026-10-26. This page lists the passes a frame goes through, what each one costs, what shipped, what was
measured and dropped, and the gap that is left. The bench tool is
[display-path/passbench.m](display-path/passbench.m).

## How the numbers were taken

- Watts are the whole Mac's, from the battery gauge's accumulators (SystemLoad, on the adapter, not
  charging), means over windows of 180-300 s. GPU time per process (milliseconds of GPU work per second) is
  the process's AGX `accumulatedGPUTime`.
- MacBook Air M2: brightness 0, the 60 Hz panel, unless a row says 120 Hz (a virtual display).
- MacBook Pro M1 Max (XDR panel, 120 Hz): a test VM like a real one (10 vCPUs, 24 GB, full screen
  3024x1896 at 120 Hz, HDR on, animations on). Two sets that are never mixed: the night of 2026-10-25 at
  brightness 0.000, where the panel has no EDR headroom, and from the evening of 2026-10-25 at brightness
  0.500, with checks before and after every row (display on, nobody at the Mac, no remote session, nothing
  above the measured window, the VM in its full HDR mode). Only the 0.500 rows are used below unless a table
  says otherwise.
- **HDR VM vs SDR macOS.** A VM with HDR on puts the XDR panel into EDR (headroom 11.43 at 0.500); Chrome on
  macOS with SDR content leaves it at 1.00. A ratio of those two rows compares two panel states, not only
  the same task, and is marked "HDR VM vs SDR macOS". The fair reference rows hold the macOS panel in HDR
  mode too (a 16 px HDR dot on screen), so both sides run at EDR 11.43.
- Ratios are taken within one set (A/B/A/B or A/B/B/A); a number from another set is marked as such.

## The passes

A frame of the desktop (pointer, typing, a scrolling page):

1. The app draws its window in the guest (Chrome: Skia on ANGLE on virgl).
2. Hyprland draws the frame into a work buffer (only the damaged parts), then
3. copies the damage into the scanout buffer (two passes on every frame: Hyprland 0.56
   `CHyprOpenGLImpl::begin/end` always render off-screen first). With HDR on it also drew every frame
   into an SDR copy for screen sharing; since 3.2.2 only while something captures (#533).
4. QEMU's present draws the scanout into one of its IOSurfaces (`qemu-cocoa-gl-present-iosurface.patch`).
5. WindowServer composites the layer.

A video frame in Chrome adds, before 1:

- VideoToolbox decodes on the media engine into an IOSurface (NV12);
- virglrenderer copies its two planes into the guest's VA surface (`virgl-videotoolbox-decode.patch`,
  plus the edge fill of `virgl-video-plane-edge.patch`);
- Chrome converts the NV12 surface to an ARGB frame (VA-API video processing in Mesa), because with Skia
  on GL it cannot sample NV12 (chrome-hw-decode); Omarchy's Chromium (V4L2) has vdecd do the same
  conversion; then Chrome draws the frame into its window (1).

An M1 or M2 Mac has no AV1 decoder, not even in VideoToolbox's software path (`kVTCouldNotFindVideoDecoderErr`
on the M1 Max, macOS 27.0.1). YouTube sends AV1 at 1080p60 to Chrome on both sides there, so both decode it
in software; in the VM that runs on the vCPUs.

## What each pass costs

**Offscreen bench, no VM** (`passbench`: the present's own draw and the plane copy on the Mac's OpenGL at a
fixed rate, no window). MacBook Air M2, 180 s a row, 2940x1840 (the Air's full screen at scale 2):

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

**In a VM, MacBook Air M2** (OmacVM 3.2.0, before the changes below; Chromium full screen, guest 2940x1840 at
60 Hz; the same task natively in Chrome on macOS):

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

**In a VM, MacBook Pro M1 Max, brightness 0.500** (2026-10-25 evening, A/B/B/A, means of 2 rounds, every
row valid; the user's Refresh Floor app, a 1x1 pt window above every app, ran on both sides). VM rows are
HDR (EDR 11.43), macOS rows SDR (EDR 1.00): **HDR VM vs SDR macOS**. "Stack" is a lab build of 3.2.0 with
the changes below that were ready then, not a release: #531, #533, the pointer layer (#534) and the tiled
present switched on, plus two pieces dropped later (#536's first form with 10-bit surfaces, #530's fence naps):

| Task | macOS | 3.2.0 | Stack | 3.2.0 / macOS | Stack / macOS | Stack vs 3.2.0 |
|---|---|---|---|---|---|---|
| Idle | 6.50 W | 7.58 W | 7.60 W | 1.17 | 1.17 | +0.1 %, within the spread |
| Typing | 6.51 W | 7.69 W | 7.54 W | 1.18 | 1.16 | -2.0 %, within the spread |
| Scrolling | 7.41 W | 13.11 W | 12.46 W | 1.77 | 1.68 | -5.0 % |
| AV1 1080p60 clip (software on both sides) | 9.89 W | 19.66 W | 18.88 W | 1.99 | 1.91 | -4.0 % |
| VP9 4K60 clip | 8.73 W | 17.34 W | 16.91 W | 1.99 | 1.94 | -2.5 % |
| Video call (720p30 VP8 both ways) | 9.20 W | 19.73 W | 19.01 W | 2.14 | 2.07 | -3.6 % |
| App mix (Orca with 4 agents, Chrome, chat pages) | 13.50 W | 24.87 W | 22.31 W | 1.84 | 1.65 | -10.3 % |

Round-to-round spread: up to 0.48 W on macOS, 0.43 W for 3.2.0, 0.17 W for the stack; the guest's frame
rates were the same on both builds. Frame times in the same set: a 120 Hz animation 119.07 frames/s with
24 long frames (3.2.0) vs 119.94 with 1 (stack); Chrome's smooth scroll 116.5-120.1 frames/s on both; Speedometer 3.1 29.9 on both.

**Fair reference, M1 Max, brightness 0.500** (2026-10-26, A/B/B/A = macOS, VM, VM, macOS, means of 2 rounds,
12 of 12 rows valid; Refresh Floor quit and nothing above any window; EDR 11.43 at every window's start and end on
both sides). Here macOS holds the panel in HDR mode too (a 16 px HDR dot on screen), so both sides pay for EDR.
VM: a test build of 3.2.2 with the tiled present (#520), Pointer on its own layer and Draw only what changed on
(not #536):

| Task | macOS, panel in HDR | VM | VM / macOS | GPU ms/s: VM (QEMU + WindowServer) vs macOS (WindowServer) |
|---|---|---|---|---|
| Idle | 5.47 W | 5.45 W | 1.00 | about 0 |
| Scrolling | 10.88 W | 11.60 W | 1.07 | 206-208 + 37 vs 30-34 |
| AV1 1080p60 clip (software on both sides) | 12.63 W | 19.21 W | 1.52 | 326-328 + 54-55 vs 44 |

Round-to-round spread in the VM: up to 0.19 W. With SDR content macOS leaves the panel out of EDR: in another set
the same day (Refresh Floor quit too) macOS idled at 4.58 W, so the panel's HDR mode alone costs about 0.9 W at
idle, and the HDR VM idles at 1.19x SDR macOS.

**Where the M1 Max's watts go** (the night set at brightness 0.000, one window per row; measurements of where
the cost is, not options: HDR, 120 Hz and a visible window stay as they are). QEMU's GPU time was 6.5 ms per
guest frame with HDR on and 2.0 ms with it off (AV1 clip); the same output in SDR drew 2.78 W less on the clip
and 6.50 W less on the app mix; 60 Hz instead of 120 Hz 0.74 W (clip, with 1.7 % of the frames dropped) and
6.99 W (mix); a hidden window 3.54 W (clip) and 6.42 W (mix), part of it because the app in the background also
gets lower CPU clocks. The vCPUs ran at 2.7-3.0 GHz on the performance cores where macOS ran the same work at
1.5-1.7 GHz; 4 vCPUs instead of 10 drew more, not less (+0.54 W clip, +2.37 W mix).

## What shipped

| Change | Release | Default | Measured (whole Mac) |
|---|---|---|---|
| Partial present: QEMU draws only the box the guest flushed ([0051](../adr/0051-partial-present.md), #519) | 3.2.1 | off (`OMACVM_GL_PRESENT_DAMAGE=1` for tests) | bench only: -0.13 W at 60 frames/s, -0.45 W at 120 with a 64x64 box changing (Air) |
| Window surfaces in the Mac's lossless-compressed format, 8-bit ([0052](../adr/0052-lossless-window-surfaces.md), #531) | 3.2.1 | on (macOS 27) | Air scrolling -0.20 W (-4 %) at 60 Hz, -0.37 W (-6 %) at 120 Hz; video about the same; same pixels |
| Hyprland's SDR copy of each HDR frame only while something captures (#533) | 3.2.2 | on (Update VM) | QEMU GPU -10-19 % per frame; M1 Max HDR 120 Hz: clip -0.29 W (-1.5 %), scrolling -0.55 W (-4.6 %), app mix -1.16 W (-4.7 %); same frame rates |
| Pointer on its own layer ([0054](../adr/0054-pointer-on-its-own-layer.md), #534) | 3.2.2 | experimental, off | Air pointer moving -0.26 W (-7 %); M1 Max HDR 120 Hz pointer moving -1.31 W (-6.3 %), scrolling -0.1 W |
| Tiled present, "Draw only what changed" ([0055](../adr/0055-tiled-present.md), #520) | built 3.2.3, switch 3.2.4 | experimental, off | Air 60 Hz pointer moving 3.13-3.17 W instead of 3.55-3.75 W (-11 to -17 %), scrolling and typing the same. M1 Max watts: not given yet (the rows so far had a macOS window above the VM on both sides) |
| Pause drawing while hidden (#542) | 3.2.3 | experimental, off | Air, window minimised: 1080p video 3.5 -> 2.9 W (one clean row without the switch), a terminal scrolling 3.6 -> 2.5 W; M1 Max (HDR window): visible clip 19.99 W with the switch vs 20.01 W without (no cost while seen) |
| Frames in step with the Mac (#543) | 3.2.3, removed in 3.2.7 (#564) | experimental, off | a latency change; Air power within 1 %; no gain worth its cost |
| HDR and Extra brightness surfaces lossless-compressed, half float (#536) | for 3.2.6 | on | M1 Max HDR 120 Hz vs plain half float: clip 18.72 vs 19.34 W (-3.2 %), scrolling 11.30 vs 11.83 W (-4.5 %); Extra brightness clip -2.6 %, scrolling -4.0 % (one round); the same pixels on the XDR |

## Measured and dropped

- **Frames in the display's own colour space** (#522): WindowServer's GPU time -30 %, the whole Mac the same
  (Air: video -0.01 W, scrolling +0.07 W). The colour matching moves into QEMU's pass.
- **A swap-style present** (CAMetalLayer or AVSampleBufferDisplayLayer instead of a CALayer showing our
  IOSurfaces): WindowServer's CPU down a quarter, the whole Mac -0.06 W at 60 frames/s (Air bench). Below the
  5 % bar for a new present path.
- **Straight to the display** (no composite): on macOS 27 a full-screen CAMetalLayer window goes direct, also
  in scaled modes and with our own sublayers; any window above it, even a 1x1 pt one, stops it. QEMU's CALayer
  with IOSurfaces never goes direct. The VM went direct with a Metal copy into the drawables (WindowServer 0
  GPU ms/s, the same pixels), but the whole Mac drew the same (Air, SDR 60 Hz: scrolling 4.17 vs 4.15 W, video
  3.77 vs 3.75 W, pointer 3.42 vs 3.42 W): the copy costs QEMU what the composite cost WindowServer, and GL
  cannot draw straight into compressed drawables. Not measured on the XDR at 120 Hz. Branch only.
- **Surface properties of CAMetalLayer's drawables** (IsDisplayable, cache mode) on our IOSurfaces: no change.
- **10-bit window surfaces**: WindowServer +10 % on the Air; on the XDR the picture differed from the half
  float one (colours outside P3), so #536 keeps half float.
- **vCPU threads in a thread group of their own** (#541): M1 Max clip -2.4 to -3.1 W, but frames dropped (3
  and 1 of ~12k vs 0 and 0). Closed.
- **Fence answer naps** (#530): no gain in the browser A/B. Closed.
- **Hyprland direct scanout** for a full-screen client: never engaged in a test VM; blocked by the primary
  plane offering only XRGB8888 (Linux 7.4 adds ARGB8888) and by the software cursor while it shows.
- **Chromium's Wayland overlay delegation**: no change (Air 3.96 vs 4.00 W).
- **Guest at 60 Hz instead of 120 Hz while a 30 fps video plays** (Air): no change.
- **YouTube's network path**: about 1 % of a core, ~50 mW; the rest of YouTube's extra cost is its own page
  (player scripts, the ambient-mode canvas), natively too.
- **SDR output while nothing HDR is on screen**: not an option: switching HDR off changes the panel's
  brightness. Features stay as they are; only the same output may get cheaper.

## Where the gap is left

- **The guest's own passes, per frame.** Scrolling at 120 Hz on the Air: QEMU 430 GPU ms/s for Chrome's
  drawing and Hyprland's two passes, while WindowServer for our window is already below Chrome's own (184-190
  vs 229 ms/s). On the M1 Max with HDR every guest frame costs several ms of GPU time.
- **Video.** WindowServer composites our full-size RGB window (77 GPU ms/s on the Air at 1080p30) where Chrome
  hands it a 1080p YUV video layer (40). Only a zero-copy video layer from the guest would close that (design
  below, not done). AV1 on M1/M2 runs in software on the vCPUs, at their higher clocks.
- **Video on the M1 Max** is the biggest gap left with both panels in HDR: the AV1 clip at 1.52x (QEMU's GPU
  work per frame on top of the software decode both sides do), against 1.00x at idle and 1.07x scrolling.
- **Idle and typing** are close to native (Air 1.06x and 1.07x; M1 Max idle 1.00x with both panels in HDR,
  1.17x and 1.16x HDR VM vs SDR macOS with Refresh Floor running).

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
present (and the tiled present on WindowServer's side) takes most of that already while little changes.

### Cheaper ways to the same passes

- **Hyprland direct scanout** for a full-screen client (render:direct_scanout 1): the client's buffer goes to
  the plane as it is, which skips Hyprland's two passes (work buffer + copy to the scanout buffer). Blocked in
  our VMs by the primary plane offering only XRGB8888 (a client's buffer in another format cannot go on it;
  Linux 7.4 adds ARGB8888) and by the software cursor while it shows (not once it hides). In a
  test VM on the mini (`render:direct_scanout 1`) it never engaged.
- **Skia on Vulkan** in Chrome removes Chrome's NV12 -> ARGB step (VA-API video processing) because NV12 counts
  as renderable there (the chrome-hw-decode lane's finding): the browser-gpu lane's field.
