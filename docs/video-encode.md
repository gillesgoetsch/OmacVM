# Video encoding on the Mac's media engine

In OmacVM.app, apps in the VM that encode H.264 or HEVC through VA-API use the
Mac's media engine instead of the VM's CPU: FFmpeg, screen recording in OBS
Studio, and video calls in Google Chrome (camera and screen sharing).

## What works

| | Status |
|---|---|
| FFmpeg `-c:v h264_vaapi` | yes: Constrained Baseline, Main, High, up to 4096x2304 |
| FFmpeg `-c:v hevc_vaapi` | yes: Main (8-bit), up to 4096x2304 |
| Google Chrome, WebRTC: camera, screen sharing | yes, *VaapiVideoEncodeAccelerator* (H.264) |
| Brave | gets the same switches as Chrome; not tested in a call |
| OBS Studio | yes: *FFmpeg VAAPI H.264* and *HEVC*, screen capture through PipeWire |
| wf-recorder 0.6 | no: its GPU capture fails on virtio-gpu (Hyprland refuses the buffer) and it crashes; `--no-dmabuf` fails in wf-recorder itself. Software (`-c libx264`) works |
| Firefox | no: Firefox 157 has no VA-API encoder on Linux (it decodes with VA-API only) |
| Chromium from Arch Linux ARM (Omarchy's default browser) | no: built without VA-API (153), so it encodes on the CPU; `omacvm apply` adds the switches once it loads libva |
| HEVC Main 10, VP8, VP9, AV1 | no: the media engine encodes H.264 and HEVC; 10-bit would need P010 pictures |

A real call was tested end to end in a test VM: Chrome with the camera
(OmacVM's *Mac Camera*, `/dev/video42`), the microphone and the whole screen
(xdg-desktop-portal-hyprland) in one WebRTC connection, both video senders on
*VaapiVideoEncodeAccelerator* (`powerEfficientEncoder: true`), audio on Opus.
`chrome://webrtc-internals` shows the same encoder name.

Chrome picks the encoder itself: below 360p it uses its software encoder
(Chrome's rule: "Fallback to SW due to low resolution"), so a call that starts
small switches to the media engine when the resolution goes up. Calls that
negotiate VP8, VP9 or AV1 instead of H.264 stay on the CPU.

### Browser switches

Chrome's VA-API encoder is off on Linux unless `AcceleratedVideoEncoder` and
`VaapiVideoEncoder` are enabled. `omacvm apply` adds them for Chrome and Brave
when the app offers encoding (`src/app/guest/browser-video-encode.py`).
Chrome uses only the last `--enable-features` it is given, and Omarchy's flags
files already have one, so the features are added to the last
`--enable-features` the browser reads (`/etc/chrome-flags.conf`, then
`~/.config/<browser>-flags.conf`), or a new line when there is none. The
user's files are written by a process running as the user. OmacVM remembers
what it added in `/var/lib/omacvm/video-encode-flags.json` (root's) and
removes only that. Omarchy's `omarchy install browser brave` replaces Brave's
file: run `omacvm apply` afterwards. Quit the browser fully once.

Check in the VM: `vainfo` lists `VAEntrypointEncSlice`; `omacvm check` shows
*video encoding* and *WebRTC encoding* (Chrome and Brave when installed,
Chromium once it has VA-API).

## Numbers

Test VM (8 CPUs, 16 GB) on a MacBook Pro M4 Max, bench lock held, other test
VMs paused (2026-10-05). CPU is measured on the Mac: QEMU's CPU time (it
includes the VM's vCPUs) plus the VideoToolbox encoder service
(*VTEncoderXPCService*). The VM's own count is listed for reference only: it
is part of QEMU's time, so adding the two would count it twice, and for the
media engine it is even higher than QEMU's (probably because the VM cannot
tell when its vCPUs wait on the host).

### FFmpeg

1080p30, 300 frames of a moving test picture with noise (raw NV12 from the
VM's memory), 8 Mbit/s with the same rate limits for all encoders. Median of
5 runs; CPU in seconds for the whole clip:

| Encoder | Frames/s | Mac CPU (QEMU + VT) | VM's count | Luma PSNR | kbit/s |
|---|---|---|---|---|---|
| `h264_vaapi` (media engine) | 136 | 1.00 s (0.94 + 0.06) | 2.30 s | 39.6 dB | 8013 |
| `libx264 -preset veryfast` | 266 | 6.43 s | 6.11 s | 40.3 dB | 8241 |
| `hevc_vaapi` (media engine) | 84 | 1.23 s (1.15 + 0.08) | 3.38 s | 40.6 dB | 8060 |
| `libx265 -preset ultrafast` | 201 | 10.19 s | 9.73 s | 39.6 dB | 8098 |

- CPU: the media engine needs 16 % of x264's CPU for H.264 (1.00 against
  6.43 s) and 12 % of x265's for HEVC (1.23 against 10.19 s).
- Speed: the media engine is slower in wall time (136 against 266 frames per
  second for H.264, 84 against 201 for HEVC), still far above real time.
  FFmpeg uploads each raw picture to the GPU (`hwupload`), the host copies it
  into the encoder's picture, and each frame waits for its coded data before
  the next one starts. x264 and x265 spread over the VM's CPUs (about 6 and
  7 busy).
- Quality at the same bitrate: H.264 0.7 dB below x264 *veryfast*, HEVC
  1.1 dB above x265 *ultrafast*.

### Chrome WebRTC

30 seconds per run, median of 3. Hardware: the switches above; software:
the same with `--disable-features=AcceleratedVideoEncoder,VaapiVideoEncoder`
(Chrome then uses OpenH264). The test is a loopback in one Chrome
(`tests/video/guest/webrtc-loopback.html`), so the VM also receives, decodes
(VA-API in both cases) and shows every stream. Chrome sends a different
number of frames with each encoder, so the comparison is per frame and per
megapixel sent (`tests/video/webrtc-summary.py`):

| Source | Encoder | Frames/s sent | VM (cores) | QEMU (cores) | Mac CPU per frame | per megapixel |
|---|---|---|---|---|---|---|
| Camera 1280x720 | media engine | 29.9 | 0.49 | 0.78 | 26.4 ms | 28.6 ms |
| | OpenH264 | 27.8 | 0.51 | 0.77 | 27.7 ms | 30.0 ms |
| Screen 1280x720 | media engine | 23.6 | 0.46 | 0.69 | 29.4 ms | 31.9 ms |
| | OpenH264 | 28.1 | 0.56 | 0.79 | 29.1 ms | 31.6 ms |
| Call: camera, microphone, screen | media engine | 50.2 | 0.63 | 1.00 | 20.4 ms | 38.9 ms |
| | OpenH264 | 35.2 | 0.53 | 0.83 | 23.4 ms | 63.8 ms |

Camera and screen alone are `--hd` runs (full size, high starting bandwidth).
In the call Chrome sent the camera at 640x360 in both modes (limited by its
bandwidth estimate) and the screen at 1280x720; the screen sender made about
three times the frames on the media engine (about 20 against 7 per second;
Chrome reported no CPU or bandwidth limit in either case).

What this shows: at 720p the media engine does **not** save the Mac's CPU in
Chrome. Per frame the two are within 5 %. Most of a call's CPU goes to
capturing, Chrome itself and (in this test) receiving and showing the streams;
OpenH264 at 720p is cheap on an M4 Max. Chrome's own encode time per frame is
longer on the media engine (about 7 ms against 4 ms for the camera: the
picture goes through virtio-gpu, and the frame waits for its data). The call's
lower CPU per megapixel comes from the screen's extra frames, not from cheaper
encoding. Not measured yet: 1080p and larger screens, and slower Macs (M1, M2,
MacBook Air), where software encoding costs more.

### Soak

30 minutes on the same runtime, 25 rounds back to back (2026-10-05 01:25 to
01:56). Each round: FFmpeg `h264_vaapi` and `hevc_vaapi` on a 1080p clip (300
frames each, the frame count checked with ffprobe) and a 60-second Chrome call
(camera, microphone, screen). All 50 FFmpeg encodes complete, all 25 calls
send both video streams on *VaapiVideoEncodeAccelerator*, no encoder warning
in QEMU's log, and the same QEMU process the whole time (7.9 GB resident after
the first round, 7.6 GB at the end, 16 GB VM). The soak ran before the last
two encoder fixes (failure feedback for refused frames, constant QP), which
change only those paths.

## How it works

```
App ─VA-API─▶ Mesa's virgl VA driver ─virtio-gpu─▶ virglrenderer (QEMU)
   raw NV12 picture + parameters                   │ VideoToolbox backend
                                                    ▼
   H.264/HEVC access unit (Annex B) ◀── VTCompressionSession (media engine)
```

- The guest's VA-API driver sends one raw NV12 picture per frame (two plane
  textures) and the encode parameters: bitrate, frame rate, key frame interval
  or constant QP, picture type, and its SPS (for the picture's real size).
- The host blits the planes into an IOSurface from the compression session's
  pool (a CPU copy if the blit fails) and encodes them in real time without B
  frames. VideoToolbox writes the whole stream; the guest gets an Annex B access
  unit with the parameter sets (SPS and PPS; HEVC also VPS) before each key
  frame. The guest's reference lists and picture order counts are not used:
  VideoToolbox keeps its own (ADR [0024](adr/0024-video-encode-on-videotoolbox.md)).
- Pictures arrive padded (1080p as 1920x1088); the stream gets the size the
  guest's SPS crops them to.
- Rate control: the guest's bitrate as the average, at most 1.5 times it in any
  second. VideoToolbox's low-latency mode is not used for that: it drops
  frames, and VA-API has no way to tell the guest (Chrome then gave up on the
  hardware encoder for screen sharing).
- Constant QP (FFmpeg without `-b:v`): every frame carries the guest's QP
  (VideoToolbox's `BaseFrameQP`, which turns its rate control off). A switch
  between bitrate and constant QP starts a new session. In the test VM, 1080p
  `-rc_mode CQP`: QP 18 gives 54 MB (H.264) and 49 MB (HEVC) for the 10-second
  clip, QP 40 2.3 MB and 2.0 MB (luma PSNR 43.0/42.9 against 36.2/36.3 dB).
- A frame that fails, does not fit the guest's buffer, is refused before it
  reaches the encoder, or is never ended by the guest is reported to the guest
  as failed (never cut short, never the previous frame's result). Only a
  feedback buffer that is missing or not a buffer gets nothing, since there
  is nowhere to write.
- Everything the guest sends is checked on the Mac: sizes (16x16 to
  4096x2304), profiles, frame rate, bitrate, GOP and QP are clamped, the coded
  data and feedback must be buffers. `Tests/virgl/test-video-encode.c` feeds
  nonsense and random picture descriptions (on Apple's software OpenGL).

Switches on the Mac (QEMU's environment): `OMACVM_VIDEO_NO_ENCODE=1` leaves
encoding out (the guest then encodes on its CPU, and the next `omacvm apply`
takes the browser switches out again), `OMACVM_VIDEO_NO_HEVC=1` HEVC (decoding
and encoding), `OMACVM_VIDEO_DECODE=0` all video. The QEMU log says
`vt-video: hardware H.264 encoding offered` (or *not offered*) at start and
`vt-video: H.264 encoder 1920x1080 (pictures 1920x1088), bitrate` per stream.

Every Apple Silicon Mac (M1 and newer) has hardware H.264 and HEVC encoders;
the backend asks VideoToolbox at run time and offers only what it reports.

## Tests

- Build time: `app/runtime/Tests/virgl/test-video-encode.c`, H.264 and HEVC
  through the virgl video protocol: 30 frames decode again with VideoToolbox
  (luma PSNR above 30 dB), parameter sets and IDR in the first access unit,
  nonsense and random picture descriptions, frame-rate changes, a too small,
  a non-buffer and a missing coded-data resource, a frame never ended (failure
  feedback for each), refused sizes and profiles, cropped pictures through the
  GPU blit and the CPU copy, constant QP 18 against QP 40 and against 50 kbit/s
  before and after it.
- In a VM:
  - `tests/video/ffmpeg-encode.sh [ENCODER...]`: FFmpeg, frames per second,
    the VM's and the Mac's CPU, bitrate, PSNR.
  - `tests/video/webrtc-encode.sh --source camera|screen|call [--hd] [--fake]
    [--features ""]`: Chrome's encoder per video sender, frames, the VM's and
    the Mac's CPU. `--features ""` uses the flags files `omacvm apply` wrote;
    the real screen goes through the portal with a test picker.
  - `tests/video/webrtc-summary.py RESULT.json...`: runs side by side, CPU per
    frame and per megapixel.
