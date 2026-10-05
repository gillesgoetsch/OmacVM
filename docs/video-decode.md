# Video decoding on the Mac's media engine

In OmacVM.app, videos in the VM are decoded by the Mac's own video decoder
(the media engine) instead of the VM's CPU. YouTube in 4K at 60 frames per
second plays in Google Chrome with the VM's CPU nearly idle: 0.3 cores busy
instead of 1.2 to 1.6.

## What works

| | OmacVM.app | UTM | Parallels | VMware Fusion |
|---|---|---|---|---|
| H.264 | yes | patch tested, see below | no | no |
| VP9 (YouTube) | yes | patch tested, see below | no | no |
| AV1 (YouTube) | yes, Chromium-based browsers | – | no | no |
| HEVC | yes: mpv, FFmpeg, GStreamer, Chrome | – | no | no |
| 10-bit (VP9 profile 2, HEVC Main 10, AV1) | yes | – | no | no |

Browsers in an OmacVM.app VM:

- **Google Chrome** (Linux ARM): yes, no flags needed. YouTube chooses AV1 or
  VP9; `chrome://gpu` shows *Video Decode: Hardware accelerated* and
  `chrome://media-internals` *VaapiVideoDecoder*. Install it with
  `src/bench/install-chrome.sh` (Arch Linux ARM has no package).
- **Firefox**: yes for H.264 and VP9 (AV1 stays on the CPU, see below; HEVC
  Firefox does not hand to VA-API at all here).
- **Brave** (Linux ARM, from Brave's `.deb`): like Chrome. YouTube 4K at
  60 fps in VP9 and AV1 (Brave 1.96).
- **Chromium from Arch Linux ARM** (Omarchy's default browser): no. Arch Linux
  ARM builds it without VA-API, so it always decodes on the CPU.
- **mpv, FFmpeg** (`--hwdec=vaapi`, `-hwaccel vaapi`) and **GStreamer**
  (`vah264dec`, `vah265dec`, `vavp9dec`; Celluloid and other GStreamer
  players): H.264, VP9 and HEVC. FFmpeg decodes a 4K HEVC clip at about 200
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

Each row is one run, and the Mac was busy with other work during them. The
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
  and libvpx streams and real 1080p clips.
- The decoded frame is an IOSurface; the GPU copies it into the textures the
  VM sees (no CPU copy on the Mac's OpenGL).
- In the VM, `src/app/guest/install.sh` adds `vainfo` and a small VA-API driver
  shim (`omacvm_drv_video.c`, used through `LIBVA_DRIVER_NAME=omacvm`): Mesa's
  driver unchanged, but it offers only NV12 surfaces (Firefox cannot show the
  I420 ones FFmpeg would pick) and lists AV1 only to Chromium-based browsers.
  Its folder `/usr/local/lib/dri` goes into `/etc/ld.so.conf.d`: Firefox
  decodes in a sandboxed process that may load libraries only from the paths
  ld.so knows, so without it YouTube in Firefox falls back to the CPU.

Switches on the Mac (QEMU's environment): `OMACVM_VIDEO_DECODE=0` turns it
off, `OMACVM_VIDEO_DEBUG=1` logs each stream and the time per frame,
`OMACVM_VIDEO_AV1=1` offers AV1 (the app sets it for VMs whose `omacvm apply`
put the shim in: the VM folder's `video-decode` file).

## Limits

- **AV1 in Firefox and mpv**: FFmpeg sends only the tile data of an AV1 frame,
  without its headers, and VideoToolbox needs the headers. Chrome sends the
  whole frame. So AV1 is offered to Chromium-based browsers only.
- **HEVC**: Main and Main 10; long-term reference pictures from the SPS are
  not supported (rare).
- **At most 8 decoders at once per VM.** Each holds a session on the Mac's
  media engine, which the Mac's own apps and other VMs share, plus its
  pictures; without a limit one VM could tie it all up. A player or a
  browser video uses one. The 9th gets no decoder, and the guest cannot be
  told (creating a decoder has no reply): that video plays with empty
  pictures (FFmpeg runs to the end with blank frames) and QEMU's log says
  `decoders already open`. Closing a video frees its slot; so does a player
  that quits or crashes. `Tests/virgl/test-video-decode.c` checks the limit
  at build time.
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
