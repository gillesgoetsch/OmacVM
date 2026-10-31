# Video decoding on the Mac's media engine

In OmacVM.app, videos in the VM are decoded by the Mac's own video decoder
(the media engine) instead of the VM's CPU. YouTube in 4K at 60 frames per
second keeps the VM's CPU far less busy: about 0.3 cores in Google Chrome
154 and 0.4 to 0.6 in Omarchy's own Chromium, instead of 1.0 to 1.6 (see
[Numbers](#numbers) and [Chromium](#chromium-from-arch-linux-arm)). Google
Chrome 155 and newer use it since 3.2.0 (up to 1080p) and at every size
since 3.2.1, with about as many dropped frames as its CPU decoders: a 4K60
video at 0.4 cores of the VM instead of 0.8 to 1.3
([Chrome's converted frames](#chromes-converted-frames)).
Firefox decodes in hardware too, but its VM stays at about 0.9 cores.

## What works

| | OmacVM.app | UTM | Parallels | VMware Fusion |
|---|---|---|---|---|
| H.264 | yes | patch tested, see below | no | no |
| VP9 (YouTube) | yes | patch tested, see below | no | no |
| AV1 (YouTube) | yes: Google Chrome (Brave not tested since 1.96) | – | no | no |
| HEVC | yes: mpv, FFmpeg, GStreamer, Chrome | – | no | no |
| 10-bit (VP9 profile 2, HEVC Main 10, AV1) | yes | – | no | no |

Browsers in an OmacVM.app VM:

- **Google Chrome** (Linux ARM): yes, no flags needed. YouTube chooses AV1 or
  VP9; `chrome://gpu` shows *Video Decode: Hardware accelerated* and
  `chrome://media-internals` *VaapiVideoDecoder*. Install it from the
  Omarchy menu (Install > Browser > Chrome, the AUR's `google-chrome`, which
  builds for ARM), then `omacvm apply` once
  ([why](routes/app.md)); `src/bench/install-chrome.sh` unpacks Google's
  .deb instead (the benchmarks use it; the AUR package then stops on its
  files until `/opt/google/chrome` is removed). Chrome 155
  and newer decode in hardware from OmacVM 3.2.0 with Update VM (before:
  on the CPU, *Plane 0 is out of bounds: ... > 4096* in Chrome's log; see
  [Chrome's converted frames](#chromes-converted-frames)); 3.2.0 kept
  1440p and 4K on the CPU, 3.2.1 decodes them on the media engine too.
  `OMACVM_VA_EXPORT=0` in Chrome's environment keeps it on the CPU,
  `OMACVM_VA_MAX=1920` only 1440p and 4K.
- **Firefox**: yes for H.264 and VP9 (AV1 stays on the CPU, see below; HEVC
  Firefox does not hand to VA-API at all here). The decoding is on the media
  engine, but YouTube 4K at 60 fps in VP9 still kept the VM at 0.9 to 1.0
  cores (two 4-minute runs, Mac busy), near what CPU decoding costs. Where
  Firefox spends it is not measured yet.
- **Brave** (Linux ARM, from Brave's `.deb`): like Chrome. YouTube 4K at
  60 fps in VP9 and AV1 (Brave 1.96, early October). Later it showed
  Chrome's "Plane 0 is out of bounds" too; the 3.2.0 fix shares Chrome's
  code but was tested in Chrome 156 only.
- **Chromium from Arch Linux ARM** (Omarchy's default browser): H.264 and
  VP9, YouTube included, through a V4L2 decoder that `omacvm apply` adds to
  the VM ([below](#chromium-from-arch-linux-arm)); on YouTube a small
  extension has it send VP9 instead of AV1. HEVC, AV1 and 10-bit stay on the
  CPU.
- **mpv, FFmpeg** (`--hwdec=vaapi`, `-hwaccel vaapi`) and **GStreamer**
  (`vah264dec`, `vah265dec`, `vavp9dec` from the `gst-plugin-va` package;
  Celluloid and other GStreamer players): H.264, VP9 and HEVC. 8-bit frames
  come out bit for bit as in software decoding; 10-bit ones within one step
  of 1023. FFmpeg decodes a 4K HEVC clip at about 200
  frames per second.
- **HEVC in Google Chrome** (154): in hardware, but not finished: 1080p60
  plays smoothly until Chrome seeks (the end of a looped clip, a jump in
  the video), then the picture stops; a 4K HEVC clip showed only 10 to 20
  frames per second (the decoding is not the limit, see FFmpeg above).
  YouTube does not send HEVC. mpv, FFmpeg and GStreamer have neither problem.

Check in the VM: `vainfo` lists `VAProfileH264*` and `VAProfileVP9Profile0`
with `VAEntrypointVLD`.

## Numbers

YouTube *Big Buck Bunny* in 4K at 60 fps (VP9 or AV1), Google Chrome, 60
seconds, measured with `src/bench/video-bench.py` in an OmacVM.app VM (6 CPUs,
8 GB) on an M4 Max. CPU in cores busy:

| | Frames | Dropped | VM's CPU | QEMU on the Mac |
|---|---|---|---|---|
| CPU decoding (VP9, before) | 55.5 fps | 7.7 % | 1.56 | 1.76 |
| Mac's media engine, VP9 | 60 fps | 0.1 % | 0.33 | 0.45 |
| Mac's media engine, AV1 | 60 fps | 0.5 % | 0.30 | 0.42 |

These are not benchmark numbers: each row is one run, taken without the
benchmark lock while the Mac was busy with other work. The
dropped frames depend on that load: a CPU-decoding run in a test VM (the
try-omarchy live system, same CPUs and memory) had 60 fps and 0.0 % dropped,
with the VM at 1.21 cores and QEMU at 1.71. So the media engine is not shown
to drop fewer frames; what holds in every run is the CPU: about 0.3 cores
instead of 1.2 to 1.6. The Mac's power draw is not measured yet (it needs a
quiet Mac, `src/bench/power.sh`).

## How it works

```
Browser ─VA-API─▶ Mesa's virgl VA driver ─virtio-gpu─▶ virglrenderer (QEMU)
                                                         │ VideoToolbox backend
                                                         ▼
                              Mac's media engine ◀─ VTDecompressionSession
decoded frame (IOSurface) ─GPU copy─▶ the guest's video textures ─▶ browser
```

- In the VM, Mesa's VA-API driver for virtio-gpu sends the compressed video
  and the decoded picture parameters to the host. This is virglrenderer's
  video protocol; on Linux hosts it ends in VA-API.
- OmacVM's QEMU carries a VideoToolbox backend for it
  (`app/runtime/patches/virgl-videotoolbox-decode.patch`). VA-API hands over
  only the slices and parsed parameters, VideoToolbox wants whole frames with
  their parameter sets, so the backend rebuilds what is missing: H.264's SPS
  and PPS and HEVC's VPS, SPS and PPS from the picture parameters (HEVC's
  slice headers get explicit reference picture sets, as VA-API does not pass
  the SPS's), AV1 frames cut out of the temporal unit. VP9 frames arrive
  whole. Tested bit-exact against software decoding (FFmpeg) with x264, x265
  and libvpx streams, real 1080p clips and HEVC from the Mac's own encoder
  (`hevc_vaapi` in the VM in bitrate and constant-QP mode,
  `hevc_videotoolbox` on the Mac). That HEVC uses syntax that VA-API does not
  describe to the host (Mesa leaves `NumPocTotalCurr` and
  `deblocking_filter_control_present_flag` at 0): the backend works both out
  from the values it does get.
- The media engine decodes beside QEMU's GPU thread (from 3.2.1,
  `virgl-videotoolbox-decode-async.patch`): END_FRAME hands the picture to the
  decoder's own queue and returns, and the picture goes into the VM's
  textures when it is in. Anything that reads or writes those textures
  first (a draw, a copy, a read back, another app that imports them) waits
  for it, and a fence the VM asks for after END_FRAME signals only once it
  is in. Before, the GPU thread waited for every picture (about 5 ms for a
  4K picture, every app's drawing behind it).
- The decoded frame is an IOSurface; the GPU copies it into the textures the
  VM sees (no CPU copy on the Mac's OpenGL). The copy pauses the guest's
  conditional rendering and turns its rasterizer discard off while it runs:
  either could drop it without an error and leave the old picture. (Apple's
  software OpenGL, which the build-time test runs on, copies either way, so
  the test guards the path but cannot show the GPU's behaviour.)
- The guest's textures can be bigger than the picture: Mesa rounds a VA
  surface's planes up to 16 (1920x1080 has 1088 rows, 854 wide has 864
  columns), and apps that show the surface (mpv with `hwdec=vaapi`, Chrome
  on Wayland, which draws the decoder's NV12 frames itself, GStreamer,
  Hyprland for mpv's `vo=dmabuf-wayland`) import its planes and sample them
  whole: virgl drops the size an import asks for. So the picture came out
  squeezed and the rows past it showed below it: a green bar before 3.1.32
  (they stayed zero), the picture's last row repeated from 3.1.32 to 3.2.10
  (1080p: 8 of 1088 rows, 10.7 pixels when the video fills a 1440-high
  screen; a 320x180 call tile: 12 of 192; 854-wide and portrait 360x640
  videos the same at the right). Since 3.2.11 the Mac samples each such surface at its own size:
  the VM's VA-API shim tells it the size of every 4:2:0 surface Mesa makes
  at a size that is not a multiple of 16 (a NOP with a private payload,
  only when the app says `omacvm.valogical=1`), and every shader that
  samples such a texture scales its coordinates and size queries to it
  (`virgl-resource-logical-size.patch`, [ADR 0061](adr/0061-video-surfaces-at-their-own-size.md)).
  No copy: two more operations per lookup in those shaders. Texel reads
  are as before and bit-exact (`vaGetImage` into the surface's own format,
  FFmpeg's `hwdownload`, Chromium's V4L2 daemon). Mesa's own reads through
  its video compositor (VA-API video processing: FFmpeg's `scale_vaapi`,
  mpv's `vavpp`, GStreamer's `vapostproc`, Chrome's conversion on X11; and
  `vaGetImage` into another format) take a source region in parts of the
  size Mesa has for the surface, which the Mac would scale again: the shim
  scales a declared source's region by Mesa's size over the declared one,
  and a converting `vaGetImage` reads an import of the planes at the
  picture's size. Surfaces the decoder itself asks for larger than the
  picture, at the stream's coded size (FFmpeg in mpv, Chrome on Wayland;
  H.264 at every size that is not a multiple of 16: 1080p in 1088 rows,
  360p in 368; HEVC at sizes that are not a multiple of 8, such as 1000x562
  in 1000x568): VA-API carries no crop, and the apps send no SPS, so the
  picture's size is only in the app's EGL import of the planes (Chrome: one
  NV12 image of 1920x1080; mpv: R8 1920x1080 and GR88 960x540), which
  virgl drops. Up to 3.2.11 the app showed the stream's own padding rows
  there. Since 3.2.12 an EGL vendor library in front of Mesa's
  (`src/app/guest/omacvm_egl.c`, `/etc/glvnd/egl_vendor.d/10_omacvm.json`,
  [ADR 0063](adr/0063-video-size-from-the-apps-import.md)) hands such
  imports to the shim when it is loaded in that process, and the shim tells
  the Mac the import's size for the planes of a surface the app exported
  through it, when the size changes. Hyprland, Xwayland, Omarchy's shell
  (quickshell, also its lock screen), hyprlock and the login screen run
  Mesa's EGL alone. Not reached: Firefox (it decodes in
  its RDD process and shows the frames in another; it shows them at
  their own size by itself), mpv's `vo=dmabuf-wayland`, Vulkan
  importers. Off for one app:
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`;
  for the VM: delete `10_omacvm.json` (that also ends Ghostty's CPU renderer,
  [ADR 0064](adr/0064-ghostty-on-the-cpu.md): Ghostty then opens no window).
  The copy still fills the rows and columns past the picture with its last
  row and column (`virgl-video-plane-edge.patch`): for an older VM side or
  app, surfaces the shim did not declare, and lookups at the very edge.
  Planes more than 64 bigger than the picture are surfaces the guest crops
  itself and are left alone. `OMACVM_VIDEO_EDGE_FILL=0` turns the fill off,
  `OMACVM_VIDEO_LOGICAL=0` (Mac) and `OMACVM_VA_LOGICAL=0` (an app in the
  VM) the sizes. Tests: `Tests/virgl/test-video-padding.c`,
  `Tests/virgl/test-video-logical-size.c`,
  `src/app/guest/tests/va-shim-logical.sh`, and in a test VM
  `tests/video/video-geometry.sh` (a test card in mpv, Chrome, Chromium and
  Firefox: where its rows and columns land on the screen).
- Chrome's hardware frames (3.2.1): on X11 Chrome converts each picture into an
  ARGB frame of its own and shows that frame by its own size, but Mesa
  rounds that frame's planes up to 16 too, and its conversion read the
  picture's planes by the surface's size while they are rounded. A 320x180
  call tile showed its picture squeezed into the top 168 rows with 12
  transparent rows below it (8 at 360p and 1080p, a column strip at 854
  wide). The VM's VA-API shim now, in Chromium's processes only, imports
  such a frame at its rounded size when its buffer holds it, has the
  conversion fill the whole frame, and scales the conversion's source
  region to the picture's part of the rounded planes (only for 4:2:0
  surfaces Mesa allocated itself: an imported picture, such as a camera
  frame of its real size, keeps its region): the tile shows every
  row where Chrome's CPU decoders put it (WebRTC loopback, VP9, AV1 and
  H.264 at 320x180, 480x270, 640x360, 854x480 and 1920x1080: off by 0.4 to
  2 rows on average, as on the CPU). With a runtime that samples surfaces
  at their own size (above), the shim declares the decoder's surfaces, and
  the conversion's source region gets the declared size's scaling instead
  of this one; the RGB frames keep this fill (Mesa converts an RGB surface
  to YUV by its texture's size, so a declared size would squeeze those). It relies on how Mesa rounds and reads
  those planes, so it runs only with a Mesa it was checked with (up to 26.2,
  from Mesa's vendor string; a newer Mesa: off, with one line in Chrome's
  log, until it is checked again). `OMACVM_VA_FILL=0` or `1` in Chrome's
  environment turns it off or on. Test: `src/app/guest/tests/va-shim-vpp-fill.sh`.
- In the VM, `src/app/guest/install.sh` adds `vainfo` and a small VA-API driver
  shim (`omacvm_drv_video.c`, used through `LIBVA_DRIVER_NAME=omacvm`): Mesa's
  driver unchanged, but it offers only NV12 surfaces (Firefox cannot show the
  I420 ones FFmpeg would pick), lists AV1 only to Chromium-based browsers and
  keeps to the Mac's limit of open decoders (Limits, below;
  `OMACVM_VA_DEBUG=1` prints it). It also reads pictures out in the other
  YUV layout itself (vaGetImage/vaPutImage between NV12 and I420 or YV12:
  FFmpeg's `hwdownload,format=yuv420p`), a plain reshuffle on the CPU, so
  they stay bit for bit the decoded ones; Mesa would convert on the GPU
  through RGB.
  In Chromium's processes it also asks Mesa for exportable surfaces
  ([below](#chromes-converted-frames)). In every process it refuses to
  decode into, or encode from, a surface made from the app's memory (an
  import): Mesa's virgl driver has no video buffer on the Mac for such a
  surface and crashed the process (Chrome's GPU process); the app gets
  `VA_STATUS_ERROR_INVALID_SURFACE` for that picture's `vaBeginPicture`,
  `vaRenderPicture` and `vaEndPicture` instead of a crash. The shim
  remembers every import until the app destroys it.
  `OMACVM_VA_IMPORT_GUARD=0` turns this off (tests only).
  Test: `src/app/guest/tests/va-shim-import-decode.sh`.
  Its folder `/usr/local/lib/dri` goes into `/etc/ld.so.conf.d`: Firefox
  decodes in a sandboxed process that may load libraries only from the paths
  ld.so knows, so without it YouTube in Firefox falls back to the CPU.

Switches on the Mac (QEMU's environment): `OMACVM_VIDEO_DECODE=0` turns it
off, `OMACVM_VIDEO_DECODE_SYNC=1` has the GPU thread wait for each picture
(as before 3.2.1; the app then also leaves `omacvm.vadecasync` out, so Chrome
stays at 1080p in the VM), `OMACVM_VIDEO_DEBUG=1` logs each stream and the time per
frame (and how many pictures were in flight),
`OMACVM_VIDEO_AV1=1` offers AV1 (the app sets it for VMs whose `omacvm apply`
put the shim in: the VM folder's `video-decode` file),
`OMACVM_VIDEO_GIVEUP_MS=N` sets how long a decoded picture may take before it
is given up (default 250, 50-500; [below](#when-the-macs-video-service-is-slow)). In the VM:
`OMACVM_VA_EXPORT=1` or `0` in an app's environment turns the shim's
exportable surfaces on or off for it; `OMACVM_VA_MAX=N` sets the largest
size Chromium decodes in hardware (default: none with an app that says
`omacvm.vadecasync=1`, else 1920; 0: no limit; only in Chromium's processes
and only for decoding: VA-API encoders and video processing keep Mesa's
sizes); `OMACVM_VA_DECODE_WAIT=0` or `1` turns the shim's wait after
`vaEndPicture` off or on (default: on in Chromium's processes with such an
app); `OMACVM_VA_FILL=0` keeps Chromium's
converted frames as Mesa makes them (above).

## When the Mac's video service is slow

Every decoder's VideoToolbox session is made, changed (a new format), made
again after it broke, and ended on that decoder's own queue, in order with its
pictures; QEMU's graphics thread, which every guest app, the display and their
fences wait for, never waits for it
(`virgl-videotoolbox-session-queue.patch`). Starting a session is an XPC call
to the Mac's video service: usually 10-300 ms, but on a Mac out of free memory
it took 1.6 s (2026-10-28, `tracks/vm-stall.md`), and before this the whole VM's
graphics stood still that long, at every new video stream (a call's tiles
switch streams every few seconds). Now a picture sent meanwhile waits on the
queue; one not in within `OMACVM_VIDEO_GIVEUP_MS` (250 ms) after its END_FRAME
is given up: that video shows its last picture until its decoder is there.
The VM's fences finish in one order, so the frames of other apps that come
after that picture wait for it too, up to those 250 ms; nothing waits longer.
The picture is still decoded once the session is there (a later picture may
refer to it), but never written into the guest's planes: the fence the guest
waited on has let them go. An AV1 picture with film grain goes into two
buffers (the decoder's and the one Chrome shows): a read of either waits for
it, and a picture given up is written into neither. A fence whose pictures are in but still being
copied into their planes waits for the copy. qemu.log says when a start took
that long or longer ("the Mac's video decoder took 1.6 s to start (H.264
320x180): 3 pictures skipped", at most every 10 s).

Limits: a decoder keeps up to 16 pictures on their way; with a 17th the oldest
is given up if its session is still starting. Its queue holds up to 64 pictures
not handed to VideoToolbox yet, so a session start of more than about 1 s at
60 fps fills it: pictures past the 64th are refused at once (not decoded), and
the pictures after them that refer to them can show errors until the stream's
next key frame. A closed decoder counts against the 48 until its session has
ended on its queue. What the Mac decodes and encodes is asked once when QEMU
starts, beside its graphics thread; if the guest asks before the answer is in,
the graphics thread waits for it once, 10 s at most, and after that only looks
(no hardware video until the answer comes).

## Chrome's converted frames

Google Chrome (and, by the same code, Brave and Electron apps: tested in
Chrome 156 only) with Skia on OpenGL on X11 shows a hardware-decoded frame
only as ARGB: there NV12 counts as renderable only with Vulkan or when GBM
can make NV12 buffers, which virgl cannot. On Wayland
(`--ozone-platform=wayland`, as Omarchy starts it) Chrome 154 counts NV12 as
renderable with OpenGL too (its zero-copy GL path, on by default, imports
the planes with EGL): it decodes without converting ("No ImageProcessor
needed" in its log) and draws the NV12 planes itself, so the planes' size
above is what it shows. On X11 Chrome converts each frame on the GPU
(VA-API video processing, Mesa's video compositor: one shader pass on the
Mac's GPU) into an ARGB surface of its own, and hands that surface back to
VA-API. Six things stood in the way, all fixed in 3.2.0:

- Chrome first checks each plane against its dma-buf's size
  (`vaapi_wrapper.cc`, `ValidateAndGetPlaneInfo`). Mesa's virgl gives a
  surface whose pixels the Mac keeps a guest buffer of one page, so the
  dma-buf said 4096 bytes and Chrome decoded on the CPU. The shim now adds
  libva's export hint (memory type `DRM_PRIME_2` without a descriptor) to
  every surface Mesa allocates in Chromium's processes (the browser by
  name, its GPU and decoder processes by their `--type=` switch): Mesa then
  gives them a guest buffer of their real size. That costs guest memory:
  at 1080p 3.3 MB per NV12 surface and 8.3 MB per ARGB one, at 4K 12.5 and
  33 MB; Chrome keeps up to 16 ARGB frames and the decoder's NV12 ones.
  Other apps (Firefox, mpv, FFmpeg) keep Mesa's one page.
- Mesa's compositor shader samples with a swizzle on the sampler, which
  virglrenderer wrote into the GLSL; the Mac refused it, and the converted
  frames stayed black (`virgl-shader-sampler-swizzle.patch`).
- The compositor binds its colour matrix as a buffer in constant slot 0;
  virglrenderer took a shader's constants only from the data the guest
  sends, so the matrix read as zeros and the frames were black again
  (`virgl-const-buffer0-resource.patch`). FFmpeg's `scale_vaapi` (the same
  conversion) showed it too.
- The compositor reads U and V from the one UV plane through two views with
  different swizzles; OpenGL keeps one swizzle per texture, so both read V
  (red came out magenta). Such views now get their swizzle in the shader
  (`virgl-view-swizzle-shared-texture.patch`).
- The compositor declares its plane samplers as 2D arrays, while the
  planes of a progressive video buffer are plain 2D textures. Gallium reads
  such a texture as layer 0; on OpenGL a 2D-array sampler reads nothing
  from it. Where a shader declares a 2D-array sampler and a plain 2D texture
  is bound there, virglrenderer now declares a 2D sampler
  (`virgl-shader-array-sampler-2d-view.patch`).

- VideoToolbox's AV1 frame is as large as the format description, which
  the backend made from Mesa's `max_width` and `max_height` plus one; Mesa
  sends the surface's size there (not minus one), so the frame came back
  larger than the picture and its extra rows (near zero: green) were copied
  as picture. The copy now takes AV1's and VP9's frame size from the
  picture description (`virgl-video-picture-size.patch`;
  `OMACVM_VIDEO_DEBUG=1` logs "output WxH, picture WxH").
- AV1 with film grain (3.2.11): Chrome decodes such a picture into one
  buffer and shows another, which Mesa sends as the film grain target;
  VideoToolbox's picture has the grain applied, and it now goes into both
  (`virgl-video-av1-film-grain.patch`, one more GPU copy per picture for
  such videos only). Before, on Macs that decode AV1 on the media engine
  (M3, M4), Chrome showed a buffer the Mac had not written for that
  picture. Test: `test-video-padding.c` (av1fg-320x180.ivf).

How well it plays: *Big Buck Bunny* 60 fps, Chrome 156, test VMs with 4 CPUs
and 4 GB without a window, busy cores of the VM and of QEMU on the Mac (the
VM's CPUs and the graphics thread together) and dropped frames over 60 s.
3.2.1 against the CPU decoders and against 3.2.0's way (the graphics thread
waits for each picture: `OMACVM_VIDEO_DECODE_SYNC=1`), same app, same
session, 2026-10-25. YouTube itself played nothing in the test VMs that
morning, so the rows play the same video from a local file: 40 s of
Blender's 2160p60 master in VP9 (libvpx, 23 / 12 / 6.7 Mbit/s at 2160p /
1440p / 1080p) and AV1 (SVT-AV1, 8 / 4 / 2.2 Mbit/s), in a `<video>` that
fills Chrome's window, measured as `src/bench/video-bench.py` does (Chrome's
media events and `getVideoPlaybackQuality`). Two runs each, alternating:

| Mac, video | CPU: VM, QEMU, dropped | Media engine, 3.2.1: VM, QEMU, dropped | 3.2.0's way: dropped |
|---|---|---|---|
| MacBook Air M2, 4K VP9 (no AV1 decoder) | 1.30-1.32, 1.53-1.55, 0.2 % | 0.39-0.43, 0.88-0.94, 0.5 % | on the CPU (1920 limit) |
| MacBook Air M2, 1440p VP9 | 1.13-1.20, 1.40-1.45, 0.1-0.2 % | 0.44-0.45, 0.94-0.96, 0.1-0.2 % | on the CPU |
| MacBook Air M2, 1080p VP9 | 0.98, 1.28-1.29, 0.2-1.9 % | 0.44-0.45, 0.90-0.94, 0.2-1.2 % | 7.3-17.5 % |
| MacBook Pro M4 Max, 4K AV1 | 0.79-0.80, 1.06-1.08, 3.8-4.1 % | 0.41-0.42, 0.92-0.94, 2.3-2.4 % | on the CPU |
| MacBook Pro M4 Max, 1440p AV1 | 0.77, 1.07-1.09, 2.5-2.8 % | 0.42-0.43, 0.95-0.96, 2.3-2.4 % | on the CPU |
| MacBook Pro M4 Max, 1080p AV1 | 0.63-0.65, 0.97-1.01, 1.5-2.0 % | 0.41-0.42, 0.93-0.95, 2.3-2.7 % | 5.0-5.6 % |

Earlier the same day, with YouTube (60 s rows; the Air's on the build
before the decoder's own queue, below): 4K AV1 on the M4 Max 6.7-6.8 %
on the media engine against 8.0-8.2 % on the CPU and 12.9-20.2 % the old
way; 4K VP9 on the Air 6.3-6.6 % against 7.2 % and 38.2 % the old way.
About 6 % of YouTube's frames went missing on the CPU too in these hidden
test VMs, so the local file shows the differences better.

Where the frames went: QEMU's graphics thread, which runs every guest app's
GPU commands, waited for the media engine on every picture (VideoToolbox
decode and wait, about 5 ms for a 4K picture on the M2, 3 on the M4 Max).
At 4K60 that thread was busy 94 to 96 % of the time (`sample` of QEMU),
more than half of it waiting, and Chrome's compositor and the desktop
waited behind it. Since 3.2.1 (`virgl-videotoolbox-decode-async.patch`)
END_FRAME hands the picture to the decoder's own queue, which gives it to
VideoToolbox (its "asynchronous" DecodeFrame still waits on its remote
decoder, so not on the graphics thread either), and the picture goes into
the VM's planes when it is in: the thread is idle 38 % of the time at 4K
on the M2 instead of 4 %. Chrome converts each picture to ARGB right after
decoding it; so that this conversion does not wait on the graphics thread
for the picture, the VM's VA-API shim lets Chrome's decoder wait for it
after `vaEndPicture` (an empty command with a fence, which the Mac signals
once the picture is in; only in Chromium's processes, only when the app
says `omacvm.vadecasync=1`; `OMACVM_VA_DECODE_WAIT=0` in Chrome's
environment turns it off). With such a runtime the shim no longer limits
Chrome to 1920 x 1920 (`OMACVM_VA_MAX=N` still sets a limit; an older app,
without the marker, keeps the limit of 1920, and so does the app started
with `OMACVM_VIDEO_DECODE_SYNC=1`, which leaves the marker out).
`OMACVM_VA_EXPORT=0` in Chrome's environment keeps every size on the CPU.
Not measured yet: video calls at these sizes, M1 and M3 Macs (the M1 Max is
the user's own), and watts. Firefox, mpv and FFmpeg get no wait of their
own: their next draw or read of the planes waits for the picture on the
graphics thread, as before (not measured).
Chrome's canvas readback of a hardware frame (not the screen) takes the
ARGB surface's coded size: 8 black rows under 1080p, 10 black columns at 854
wide.

The shim adds the hint only when the Mac's runtime has the shader fix: the
app says `omacvm.vaexport=1` at every start (`/run/omacvm/host.env`, read
once when the driver loads, before Chrome's sandbox closes). A VM updated
by a newer `omacvm` than its app keeps decoding on the CPU instead of
showing black video. Tests: `src/app/guest/tests/va-shim-surfaces.sh` (CI),
`tests/video/guest/va-export-size.c` (in a VM: every plane fits its
dma-buf), `Tests/virgl/test-core-glsl-shaders.c` (the compositor's shader),
`Tests/virgl/test-const-ubo.c` cases 22 to 24 (constant slot 0 as a
buffer, a 2D texture through a 2D-array sampler, two views of one texture),
`test-view-key.c`, `test-video-padding.c` (AV1 with Mesa's sizes).

## Chromium from Arch Linux ARM

Arch Linux ARM builds Chromium without VA-API: its only hardware decoder is
V4L2, Linux's video device interface. In OmacVM.app VMs `omacvm apply` adds
such a device whose decoding is done by the VA-API path above
([ADR 0025](adr/0025-chromium-video-through-v4l2.md) has the why):

```
Chromium ─V4L2─▶ /dev/videoN (omacvm-vdec module) ─▶ omacvm-vdecd
                                                       │ FFmpeg, VA-API
                                                       ▼
                         Mac's media engine (as above: VideoToolbox)
                                                       │ NV12 picture
Chromium ◀─ its GPU buffer (ARGB) ◀─ GPU pass in omacvm-vdecd
```

- `omacvm-vdec` (`src/vdec/guest/module`) is a kernel module, built by DKMS
  for every kernel that comes with its headers: a V4L2 stateful decoder that
  does no decoding itself and hands each bitstream buffer to the daemon.
- `omacvm-vdecd` decodes it with FFmpeg's VA-API decoder and writes the
  picture into Chromium's buffer, converted to ARGB by the GPU. Those buffers
  are GPU buffers the daemon allocates, so Chromium's compositor can show
  them (ARGB is what Chromium shows from a decoder with OpenGL). The daemon
  runs as its own user in a sandboxed service without network.
- Chromium gets `AcceleratedVideoDecoder` (its V4L2 decoder, off by default
  in builds without VA-API) and the extension in `~/.config/chromium-flags.conf`,
  merged into Omarchy's last `--enable-features` and `--load-extension` (Chromium
  takes only the last of each). The extension tells YouTube that AV1 is not
  supported, so YouTube sends VP9: this Chromium decodes AV1 only on the CPU.
  It lives in `/usr/local/lib/omacvm/chromium-no-av1`, outside the copy of
  OmacVM that every `omacvm apply` replaces (up to 3.1.4 it was in that copy,
  and an apply of other features left Chromium saying "Failed to load
  extension" at each start).
- When the GPU is not usable (a Mesa update that broke GBM), the daemon
  waits and exits, and systemd starts it again: after 2 seconds at first,
  then less often, up to every 2 minutes. Once it is ready the wait starts
  at 2 seconds again, and a crash is restarted after 2 seconds as before.
  A pacman hook starts it at once after any library update, and builds it
  again when a library it links to is gone (a new FFmpeg:
  `libavcodec.so.N`): `src/vdec/guest/vdecd.sh`.
  Chromium looks for decoders when it starts: restart it once after that.
- Check: `omacvm check` shows *video decoding in Chromium* (and why the
  daemon is down when it is), and `chrome://media-internals`
  *V4L2VideoDecoder*.
- "Chromium (WebGPU)" decodes video on the CPU (from 3.2.15): its Vulkan
  compositor cannot draw these buffers on Venus, and the first one restarted
  its GPU process (3.2.14 and older: the video stopped after a few
  frames). The normal Chromium entry uses the media engine.
- **The end of a video** (fixed in 3.2.16): a video stopped on its last
  picture, a looped one never started again, and a stream that changed its
  picture size in the middle stood still at the change (3.2.15 and older).
  At those points Chromium holds all of the decoder's picture buffers while
  the decoder still owes it the last pictures and the buffer that marks the
  end. The module's poll answered that with an error (EPOLLERR, what the
  kernel's helper for such devices says while no buffer is queued), and
  Chromium 153 drops a wait that gets that answer and starts no new one: the
  end never reached it. The module's own poll (`ovd_poll`) sleeps instead
  while a queue streams, until a picture, an event, a stream off or a
  failure; a decoder the daemon failed, or one with both queues off, still
  gets the error, so a gone daemon still ends in an error, not a hang.
  Measured on a Mac mini M4 in a hidden test VM (3.2.15 app, the guest
  before and after): looped clips, 3 runs each, 6 s at 2160p60 and 30 s at
  1080p60: all 6 stopped at their end before, all looped after (the 4K clip
  in a 70 s run 12 times, 55-104 ms per seek, one decoder open at a time,
  59 frames a second decoded); the 4K clip without loop: `ended` 0 of 3
  before, 3 of 3 after; a Media Source stream that switches from 1080p to
  720p at 6 s and ends at 12 s: stopped at the switch before, played both
  sizes to its end after. A frame rate measured over a window that spans
  the end of a looped clip came out low for this reason (17 frames a second
  for the 6 s 4K clip in a 10 s window), not for decoding: a 30 s 2160p60
  clip decodes at 59.9-60 frames a second through this decoder (3 runs
  before, 3 after). Update VM, then restart Chromium; if a video was open
  during the update, the new module loads at the next VM start
  (`omacvm check` says so). Nothing on the Mac; any app version.

YouTube *Big Buck Bunny* at 60 fps, Arch Linux ARM's Chromium 153, 60
seconds with `src/bench/video-bench.py` (`--quality hd1080` for 1080p), in a
test VM (8 CPUs, 16 GB) on an M4 Max, Chromium without media logging. Two
series, each with the benchmark lock held for every run and the media
engine and CPU runs taken in turn (3 + 3 per row and series). The Mac was not
quiet in either: in the first other test VMs kept running (the lock pauses
only some), in the second (with this page's fixes in the decoder) few other
VMs ran but Spotlight indexing took about one core all along. CPU in cores
busy, the range over both series (6 runs per row):

| | Codec | Dropped | VM's CPU | QEMU on the Mac |
|---|---|---|---|---|
| 4K, CPU decoding (before) | VP9 | 0.0–7.7 % | 1.00–1.11 | 1.41–1.62 |
| 4K, Mac's media engine | VP9 | 0.1–7.2 % | 0.41–0.62 | 0.49–0.90 |
| 1080p, CPU decoding (before: YouTube sent AV1) | AV1 | 0.0 % | 0.64–0.69 | 0.83–0.93 |
| 1080p, CPU decoding | VP9 | 0.0 % | 0.57–0.75 | 0.80–1.09 |
| 1080p, Mac's media engine | VP9 | 0.0–1.4 % | 0.35–0.63 | 0.42–0.91 |

(The AV1 row is 2 runs from an earlier series, same lock.) So: at 4K the
media engine takes about half of the VM's CPU and of QEMU's; at 1080p the
gain is smaller (0.1 to 0.2 cores) and in single runs none. The media engine
path drops frames when the Mac is busy (up to 7 % at 4K), the CPU path at 4K
did too in the second series. The hardware path shares the Mac's GPU with
everything else: the busier the Mac, the closer its CPU numbers come to CPU
decoding. Google Chrome's VA-API path, for comparison: 0.33 and 0.45 at 4K
(above, single runs). The results files: `yt-locked3.jsonl` and
`yt-locked4.jsonl` in the track's results (not in the repository); a quiet
Mac is still to be measured.

Switches: the feature `chromium-video` (on in OmacVM.app VMs):
`omacvm disable chromium-video` takes it all out, the flags file included,
and it stays out on later `omacvm apply` runs. `OMACVM_VIDEO_DECODE=0` on the
Mac turns it off with the rest (the daemon then finds no decoders and
Chromium decodes on the CPU). `OMACVM_VDEC_DEBUG=1` in the service's
environment logs every frame with its times.

Tests: `src/vdec/guest/test/vdec-test FILE` checks the device against
FFmpeg's software decoder (every picture, a seek, a drain, a size change).
Its modes check the failures: `--churn` (a busy decoder closes while the next
opens), `--early-drain` (a drain before the first picture), `--expect-fail`
(a picture under 64 pixels fails at once), `--stall` (the daemon stopped
mid-video: an error within seconds, then the next video decodes), `--flood`
(1000 drain commands: the module fails that decoder instead of growing),
`--hold-all-at-eos` (Chromium's end of a stream: every picture buffer held
while the decoder still owes the last pictures and the end; a second thread
polls the way Chromium waits and must sleep, then wake within a second when
the buffers come back, when both queues stop, and with an error when the
daemon is gone; 3.2.15's module answers at once with an error).
`src/tests/vdecd-logical.sh` (CI) checks what the daemon tells the Mac for
odd sizes, against a stand-in for the kernel's ioctls.

Limits:

- **HEVC**: not offered. Chromium 153's V4L2 decoder for this kind of device
  does not implement it (`OMACVM_VDEC_HEVC=1` offers it to other V4L2 apps).
- **AV1**: not built into this Chromium. YouTube gets VP9 (the extension);
  another site that sends AV1 plays on the CPU.
- **10-bit** (VP9 profile 2): on the CPU; the pictures are 8-bit ARGB.
- **Odd sizes** (a VP9 video of 853x480 or 1001x563): the daemon's buffers
  are the picture's size rounded up to even (the module's step), and Chromium
  imports the picture's own part of each one. Mesa's virgl driver drops the
  size of an import, so the Mac sampled the whole buffer and the picture came
  out one column (and row) narrower than it is (3.2.11 and older). Since
  3.2.12 the daemon tells the Mac the picture's size for such buffers, as the
  VA-API shim does for its surfaces: a NOP with a private payload
  (`src/vdec/guest/vdecd-logical.h`), only when the app's runtime says
  `omacvm.valogical=1` (3.2.11 and newer; with an older app the column
  stays). `OMACVM_VA_LOGICAL=0` in the service's environment turns it off.
  Even sizes need nothing (measured: 854x480, 720p, 1080p and 1000x562
  exact, nothing sent).
- **Memory**: Chromium's buffers are pinned VM memory, about 33 MB each at
  4K and 10 per video (8 MB each at 1080p).
- **At most 8 videos** decode this way at once; more play on the CPU. One
  daemon thread serves them in turn.
- **Pictures under 64 pixels** wide or high: that video plays on the CPU.
- **When something goes wrong** with one video (a stream VA-API cannot take,
  the Mac's GPU not finishing a picture within a second), that video reports
  a decode error and Chromium plays it on the CPU; the others go on.
- **If the daemon stops or hangs**, the videos playing report a decode error
  (reload the page). systemd's watchdog kills a daemon that hangs for 5
  seconds and starts it again 2 seconds later.
- **An update while a video plays**: the new module loads at the next VM
  start; until then the old one keeps working and `omacvm check` says an
  update waits. `omacvm apply` restarts the daemon only when it changed.
- **A new kernel**: pacman's DKMS hook builds the module during the update
  (with the new kernel's headers), and it loads early at the next start.
  Without the headers in Arch Linux ARM's repository yet, Chromium decodes
  on the CPU until `omacvm apply` finds them.
- **A module that comes late** (`omacvm apply` loads it while the VM runs,
  after the services started): its device starts the daemon
  (`70-omacvm-vdec.rules`); a Chromium already open decodes on the CPU until
  it starts again. WirePlumber leaves the decoder alone
  (`50-omacvm-vdec.conf`, [troubleshooting 29](troubleshooting.md#29-app-no-sound-at-all-after-a-start)).

## Limits

- **AV1 in Firefox and mpv**: FFmpeg sends only the tile data of an AV1 frame,
  without its headers, and VideoToolbox needs the headers. Chrome sends the
  whole frame. So AV1 is offered to Chromium-based browsers only.
- **VA-API conversions on the GPU** (to RGB: FFmpeg's `hwdownload,format=bgra`
  and `scale_vaapi=format=bgra`, GStreamer's `vapostproc`, Chrome's conversion
  on X11) were black before 3.2.0; the compositor fixes of 3.2.0
  ([above](#chromes-converted-frames)) made them draw. Measured on 3.2.11
  (H.264 1920x1080, HEVC 1000x562): `hwdownload,format=bgra` and
  `scale_vaapi=format=bgra` show the test card in place (its lines and bands
  at their rows and columns). They are RGB, so not bit for bit; YUV to YUV
  draws with the row pairs below. For bit-exact pictures read the picture out
  in YUV (`hwdownload,format=nv12`); the other YUV layout comes from the shim
  (above), which outside the desktop session (SSH, sudo, services) is used
  only with `LIBVA_DRIVER_NAME=omacvm`.
- **Motion-adaptive deinterlacing gave a green picture before 3.2.13**: mpv's
  `--vf=vavpp` with its default deinterlacer (or `--deinterlace=yes` with
  `--hwdec=vaapi`), FFmpeg's `deinterlace_vaapi` in its default or
  `motion_adaptive` mode. That was OmacVM's runtime, not Mesa. Mesa's
  deinterlacer declares its samplers without views and reads the decoded
  pictures, plain 2D textures, with 2D-array lookups.
  `virgl-shader-array-sampler-2d-view.patch`
  turned such lookups into 2D ones only where a shader declares the view (as
  Mesa's video compositor does), so the Mac's OpenGL got a 2D-array sampler
  on a 2D texture and read zeros (QEMU's log, once:
  `GLD_TEXTURE_INDEX_2D_ARRAY is unloadable ... using zero texture`): Y, U
  and V 0 are green, also with Mesa's VA driver alone. Since 3.2.13 (#615) a
  2D-array lookup in a shader without sampler views counts as that
  declaration. Measured on an interlaced 1080p test clip coded as frames
  (Mac mini M4, Mesa 26.2.5, FFmpeg 9.0.2, mpv 0.41): FFmpeg's
  `deinterlace_vaapi` 0 of 47 frames green (3.2.12: 47), 28.1 dB against
  FFmpeg's CPU `bwdif` (3.2.12: 5.1 dB); mpv's `vavpp` shows the second
  field without combing, 33.0 dB against the test pattern's own picture of
  that field (mpv's CPU deinterlacer 34.2 dB on the first field; 3.2.12:
  9.9 dB, all green); no `unloadable` line in QEMU's log. GStreamer's
  `vadeinterlace` with `method=adaptive` takes the same Mesa path (not
  measured). Bob and weave do not deinterlace: in Mesa 26.2 they are a plain
  copy (with the YUV-to-YUV row pairs below).
- **H.264 coded interlaced decodes on the CPU** (field pictures or MBAFF
  frames, as interlaced TV recordings and x264's interlaced mode write them;
  interlaced video coded as progressive frames is not affected). The Mac's
  hardware decoder does not take these streams: VideoToolbox refuses a
  session that asks for the hardware (-12911,
  `kVTVideoDecoderMalfunctionErr`), also with the stream's own SPS and PPS,
  and FFmpeg's own `-hwaccel videotoolbox` on macOS refuses them the same
  way. Checked on a Mac mini M4 (macOS 27.0) with x264's MBAFF at 1920x1080
  and 720x576 and five interlaced conformance streams from FFmpeg's test
  suite (MBAFF, PAFF, field pictures); the progressive ones decode in
  hardware. Up to 3.2.12 the runtime then got VideoToolbox's software
  decoder instead, which drops every picture once the runtime rebuilds the
  PPS a few pictures in (QEMU's log in the test VM: `vt-video: decode
  failed: -8969`, its "bad data"; at 576 lines a `decode failed: 1` came
  first) and has the colours wrong at 1080 lines even without that. In the
  test VM on 3.2.12 that gave green or wrong pictures: mpv 99 % green at
  1080i and wrong at 576i (24.3 dB against its CPU decoding), 100 % green
  with `--deinterlace=yes`; FFmpeg's frames were not right (0 of 50 bit for
  bit at 1080i, 2 of 50 at 576i; not measured for green). From 3.2.13 the
  shim refuses such a picture before it reaches the Mac
  (`VA_STATUS_ERROR_UNIMPLEMENTED` at `vaRenderPicture`, logged at most
  every 10 s): Mesa gets only the picture's `vaBeginPicture`, none of its
  parameters, slices or `vaEndPicture`, and nothing of it reaches the Mac,
  so the app gets an error instead of a green picture. mpv
  (`--hwdec=vaapi`, also with `--deinterlace=yes`) switches to the CPU after
  3 of them (its `--hwdec-software-fallback`) and shows the same picture as
  its CPU decoding (3.2.12: 99 % green at 1080i). FFmpeg
  with `-hwaccel vaapi` prints an error for each picture and exits with 69,
  after writing its last two pictures, which were never decoded: leave out
  `-hwaccel vaapi` for these videos. Measured in a test VM (Mac mini M4,
  Mesa 26.2.5, FFmpeg 9.0.2, mpv 0.41) on the 1080i and 576i clips above;
  H.264 coded as frames decodes in hardware as before (50 of 50 frames bit
  for bit) and no codec for the interlaced clips reaches the Mac.
  Chromium from Arch (`omacvm-vdecd`) waits for a first picture that never
  comes and gives no error, so up to 3.2.14 such a video got no pictures
  instead of green ones (from the code). From 3.2.15 the daemon fails the
  video once VA-API refused 3 of its pictures before the first one came out
  (`AVERROR(EIO)`; an SPS or PPS alone does not count), and Chromium plays
  it on the CPU: its V4L2 decoder falls back to its own decoder only after a
  decode error before its first picture. Counted per decoder from each start
  (Chromium starts again on the same device for a new track); a refused
  picture after the first one is a lost picture as before. A seek opens a
  new decoder while Chromium remembers its first picture, so 3 refusals
  right after a seek would end in a playback error instead; the shim
  refuses by the stream's SPS, so a video that played gets none after a
  seek. Checked in a test VM on a MacBook Pro M1 Max (Arch's Chromium,
  `tests/video/guest/video-geometry.py`): with 3.2.14 the 1080i clip
  showed no video; with this change Chromium plays it on its CPU decoder
  (`FFmpegVideoDecoder`) and vdecd logs one "VA-API refused its first
  pictures" line; the progressive 1080 clip stays on `V4L2VideoDecoder`
  (its SPS and PPS alone gave 3 `AVERROR_INVALIDDATA`, not counted).
  `vdec-test --expect-fail` gets an error 2-36 ms after the start for the
  1080i and 576i clips, a PAFF and a field-picture stream (CVPA1_TOSHIBA_B,
  CVFI1_Sony_D); with 3.2.14 none, and no picture.
  `src/vdec/guest/vdecd-refused.h`, `src/tests/vdecd-refused.sh`.
  `OMACVM_VA_INTERLACED=1` sends them to the Mac anyway (tests);
  `src/app/guest/tests/va-shim-interlaced.sh`.
- **VA-API video processing from YUV to YUV loses vertical detail** (mpv's
  `vavpp` with `deint=bob` or `weave`, FFmpeg's `deinterlace_vaapi`,
  GStreamer's `vapostproc`; measured on copies at the same size, and in
  Mesa's source scaling takes the same shader). Mesa's video compositor does
  YUV to YUV with its weave shader when the driver has no compute path for
  it, as virgl (`vl_compositor.c` in Mesa 26.2.5 and main: the progressive
  case falls through to weave), and the weave shader reads the picture as two
  fields of half the height. On surfaces whose height is a multiple of 16
  (854x480; 1080p in 1088 rows), and on all of them with Mesa's VA driver
  alone, each pair of rows comes out alike (rows 474-479 as 475 475 477 477
  479 479). With the shim, surfaces of other heights come out with a pattern
  that depends on the height (rows 556-561 of 1000x562 as 556 557 558 559 560
  560; of a 1000x568 surface as 556 557 559 559 561 561), and every row is
  within one row of its place. With Mesa's driver alone the last chroma row
  of a 1000x562 surface is far off. Edges of colour that start on an odd row of the chroma plane fringe:
  the test card's bottom band of an HEVC 1000x562 video in mpv with
  `deint=bob` looks one row off. Players that show the decoder's own frames
  (mpv without `vavpp`, Chrome, Firefox, Chromium) are not affected. Mesa's,
  not OmacVM's.
- **HEVC**: Main and Main 10; long-term reference pictures from the SPS are
  not supported (rare).
- **32 decoders at once per VM, 48 at most.** Each holds a session on the
  Mac's media engine, which the Mac's own apps and other VMs share, plus its
  pictures (about 30 MB in VideoToolbox's service per 1080p video, 90 MB at
  4K); without a limit one VM could tie it all up. A playing video uses one:
  Chrome keeps at most 16 itself, Firefox has no limit of its own (a page of
  24 muted videos opened 24, two such tabs 48 for a moment). The Mac tells the
  VM 32 in its video caps: Chrome's 16 plus one Firefox's 16. The shim
  refuses `vaCreateContext` past that (`VA_STATUS_ERROR_MAX_NUM_EXCEEDED`),
  so that video decodes on the CPU instead of staying black. Checked in a VM:
  FFmpeg (`-hwaccel vaapi`, frames identical to software), mpv
  (`--hwdec=vaapi`, `--vo=gpu`), Chrome and Firefox (every video plays with
  pictures; the ones past the limit on the CPU). The shim counts across
  processes with a lock per slot on `/dev/shm/omacvm-va-slots` (freed when a
  process quits or crashes). Firefox decodes in a sandbox that can neither
  open nor lock it, so a process like that counts only its own, up to 16,
  and the shared slots are the other 16. So all apps that can share the
  count (Chrome, mpv, FFmpeg) have 16 together: with Chrome's 16 in use, mpv
  decodes on the CPU even when no Firefox runs.
  The Mac itself refuses only past 48. The room above 32 is for two cases
  the shim cannot see: Mesa sends a closed decoder to the Mac only with the
  app's next commands (a browser that closed a tab of videos may send it
  much later, while the shim has given the slots to other apps already), and
  apps outside the desktop session (SSH shells, sudo, system services) do
  not get `LIBVA_DRIVER_NAME=omacvm` and use Mesa's driver directly. Past 48
  a video gets no decoder and stays black, and QEMU's log says `decoders
  already open` (at most every 10 s, with a count). The shim prints its own
  refusals the same way; `omacvm check` shows the limit.
  `Tests/virgl/test-video-decode.c` checks at build time that the caps say
  32 and that the Mac keeps 48 open and refuses one more.
- **YUYV surfaces**: not offered. virglrenderer stored their plane format
  (R8G8_R8B8) at twice its size, and reading one back overflowed QEMU's heap
  (mpv's VA-API check did it, before 2.7.0's release);
  `app/runtime/patches/virgl-transfer-row-size.patch` removes the format and
  refuses any texture transfer that would move more bytes per row in GL than
  the guest's buffer holds.
- **HDR**: 10-bit video decodes (P010, bit-exact); how HDR looks is up to the
  browser and Hyprland in the VM.
- **Guests with Mesa older than 26.0** number the video profiles differently;
  `OMACVM_VIRGL_VIDEO_ABI=legacy` switches the backend to the old numbers.
  Upstream virglrenderer's copy of the numbers is the old one, so with a
  current Mesa, virgl video does not work on Linux hosts either.

## UTM

UTM ships its own virglrenderer (utmapp/virglrenderer). The same patch
applies to UTM 5.0.6's version and was tested in UTM's own QEMU, run from a
copy of UTM's frameworks (the installed UTM untouched): `vainfo` lists H.264
and VP9, FFmpeg decodes 4K VP9 at 73 frames per second (CPU copy: UTM draws
through ANGLE), Firefox decodes through VA-API. Google Chrome cannot use it
there yet: in UTM, Chrome turns its GPU off completely (WebGL too), because
UTM's virglrenderer reports one MSAA sample.

What an upstream change in UTM would need:

- the backend (`virgl_video_vt.c`, the `vrend_video.c` changes, meson's
  `video` option on macOS), built with `-Dvideo=true`;
- the video profile numbers of current Mesa (above);
- virglrenderer turns video on only when QEMU asks (`VIRGL_RENDERER_USE_VIDEO`);
  QEMU never does, so either QEMU passes the flag or virglrenderer turns it on
  for VideoToolbox, as this patch does;
- Chrome's GPU in UTM (the MSAA sample count) before Chrome benefits;
- a frame-order issue seen only there: in a readback test 107 of 120 frames
  matched (all 120 in OmacVM.app);
- a bounds check virglrenderer's video code lacks on every host: it copies as
  many bitstream bytes as the guest says into the bitstream buffer
  (`vrend_video_decode_bitstream`); the patch clamps it to the buffer's size.

## Parallels and VMware Fusion

Both are closed source; nothing in the VM can add a decoder the host does not
offer.

- **VMware Fusion**: the VM's GPU driver is Mesa's `svga` (vmwgfx). That
  driver has no video decoding at all (no `create_video_codec`), so there is
  no VA-API, VDPAU or Vulkan video in the VM, whatever the host could do.
- **Parallels** (checked with Parallels Desktop 27.0.2 and try-omarchy's
  Arch Linux ARM, Mesa 26.2): the VM sees a virtio-gpu with virgl
  (`virgl (Apple M4 Max (Compat))`), so Mesa's virgl VA-API driver loads, but
  `vainfo` lists no decoder: Parallels' host side reports no video
  capabilities in virgl's capability set. There is no V4L2 decoder either
  (`/dev/video*` are the shared Mac camera and OmacVM's *Mac Camera*), Vulkan
  is only llvmpipe (no Vulkan Video), and Mesa has no VDPAU drivers anymore.
  Only Parallels can add it on the host side.
