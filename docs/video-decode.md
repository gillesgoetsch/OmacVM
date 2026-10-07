# Video decoding on the Mac's media engine

In OmacVM.app, videos in the VM are decoded by the Mac's own video decoder
(the media engine) instead of the VM's CPU. YouTube in 4K at 60 frames per
second keeps the VM's CPU far less busy: about 0.3 cores in Google Chrome
and 0.4 to 0.6 in Omarchy's own Chromium, instead of 1.0 to 1.6 (see
[Numbers](#numbers) and [Chromium](#chromium-from-arch-linux-arm)). Firefox
decodes in hardware too, but its VM stays at about 0.9 cores.

## What works

| | OmacVM.app | UTM | Parallels | VMware Fusion |
|---|---|---|---|---|
| H.264 | yes | patch tested, see below | no | no |
| VP9 (YouTube) | yes | patch tested, see below | no | no |
| AV1 (YouTube) | yes: Google Chrome, Brave | – | no | no |
| HEVC | yes: mpv, FFmpeg, GStreamer, Chrome | – | no | no |
| 10-bit (VP9 profile 2, HEVC Main 10, AV1) | yes | – | no | no |

Browsers in an OmacVM.app VM:

- **Google Chrome** (Linux ARM): yes, no flags needed. YouTube chooses AV1 or
  VP9; `chrome://gpu` shows *Video Decode: Hardware accelerated* and
  `chrome://media-internals` *VaapiVideoDecoder*. Install it with
  `src/bench/install-chrome.sh` (Arch Linux ARM has no package).
- **Firefox**: yes for H.264 and VP9 (AV1 stays on the CPU, see below; HEVC
  Firefox does not hand to VA-API at all here). The decoding is on the media
  engine, but YouTube 4K at 60 fps in VP9 still kept the VM at 0.9 to 1.0
  cores (two 4-minute runs, Mac busy), near what CPU decoding costs. Where
  Firefox spends it is not measured yet.
- **Brave** (Linux ARM, from Brave's `.deb`): like Chrome. YouTube 4K at
  60 fps in VP9 and AV1 (Brave 1.96).
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
- The decoded frame is an IOSurface; the GPU copies it into the textures the
  VM sees (no CPU copy on the Mac's OpenGL). The copy pauses the guest's
  conditional rendering and turns its rasterizer discard off while it runs:
  either could drop it without an error and leave the old picture. (Apple's
  software OpenGL, which the build-time test runs on, copies either way, so
  the test guards the path but cannot show the GPU's behaviour.)
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
  Its folder `/usr/local/lib/dri` goes into `/etc/ld.so.conf.d`: Firefox
  decodes in a sandboxed process that may load libraries only from the paths
  ld.so knows, so without it YouTube in Firefox falls back to the CPU.

Switches on the Mac (QEMU's environment): `OMACVM_VIDEO_DECODE=0` turns it
off, `OMACVM_VIDEO_DEBUG=1` logs each stream and the time per frame,
`OMACVM_VIDEO_AV1=1` offers AV1 (the app sets it for VMs whose `omacvm apply`
put the shim in: the VM folder's `video-decode` file).

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
(1000 drain commands: the module fails that decoder instead of growing).

Limits:

- **HEVC**: not offered. Chromium 153's V4L2 decoder for this kind of device
  does not implement it (`OMACVM_VDEC_HEVC=1` offers it to other V4L2 apps).
- **AV1**: not built into this Chromium. YouTube gets VP9 (the extension);
  another site that sends AV1 plays on the CPU.
- **10-bit** (VP9 profile 2): on the CPU; the pictures are 8-bit ARGB.
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
- **VA-API conversions on the GPU give black pictures**: an image in RGB
  (FFmpeg's `hwdownload,format=bgra`) and VA-API video processing
  (`scale_vaapi`, GStreamer's `vapostproc`). Mesa does them with its video
  compositor, whose shaders the Mac's OpenGL does not run as Mesa means
  them (a swizzled sampler, 2D textures read as 2D arrays, two swizzles of
  one texture). Read the picture out in YUV and convert or scale on the CPU
  (`hwdownload,format=nv12,scale=...`). The other YUV layout comes from the
  shim (above); outside the desktop session (SSH, sudo, services) it is used
  only with `LIBVA_DRIVER_NAME=omacvm`, without it that one is black too.
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
