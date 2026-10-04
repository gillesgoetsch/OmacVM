# Video encoding on the Mac's media engine

Work in progress (branch `video-encode`). Apps in the VM that encode H.264 through
VA-API (FFmpeg's `h264_vaapi`, Chrome's WebRTC encoder) use the Mac's media engine
instead of the VM's CPU.

## What works

| | Status |
|---|---|
| FFmpeg `-c:v h264_vaapi` | yes (Constrained Baseline, Main, High; up to 4096x2304) |
| Chrome WebRTC, camera | yes, with `--enable-features=AcceleratedVideoEncoder,VaapiVideoEncoder` (Chrome 154): *VaapiVideoEncodeAccelerator* |
| Chrome WebRTC, screen sharing | not yet: Chrome cannot import its screen frames into VA-API (*Plane 0 is out of bounds*), falls back to OpenH264 |
| HEVC | not yet |

## Numbers

Test VM (8 CPUs, 16 GB) on an M4 Max, 2026-10-04, no bench lock (first numbers):

| | Frames | Guest CPU | QEMU CPU | Quality |
|---|---|---|---|---|
| FFmpeg 1080p30, 10 s, 8 Mbit/s, media engine | 300 in 4.5 s | 5.4 s (testsrc2 + upload included) | | PSNR-Y 46.2 dB |
| FFmpeg 1080p30, 10 s, 8 Mbit/s, x264 veryfast | 300 in 4.9 s | 12.1 s | | PSNR-Y 45.3 dB |
| Chrome WebRTC 720p fake camera, 15 s, media engine | 296 | 0.67 cores | 0.52 cores | |
| Chrome WebRTC 720p fake camera, 15 s, OpenH264 | 235 | 1.11 cores | 0.80 cores | |

(The WebRTC loopback adapts to 960x540 while its bandwidth estimate ramps up.)

## How it works

```
App ─VA-API─▶ Mesa's virgl VA driver ─virtio-gpu─▶ virglrenderer (QEMU)
   raw NV12 picture + parameters                   │ VideoToolbox backend
                                                    ▼
   H.264 access unit (Annex B) ◀── VTCompressionSession (media engine)
```

- The guest's VA-API driver sends one raw NV12 picture per frame (two plane
  textures) and the encode parameters: bitrate, frame rate, key frame interval,
  picture type.
- The host blits the planes into an IOSurface from the compression session's
  pool and encodes them in real time without B frames. VideoToolbox writes the
  whole stream, SPS and PPS included; the guest gets an Annex B access unit with
  SPS and PPS before each key frame. The guest's reference lists and picture
  order counts are not used: VideoToolbox keeps its own.
- `OMACVM_VIDEO_NO_ENCODE=1` leaves encoding out (the guest then encodes on its
  CPU, as before).

## Tests

- Build time: `app/runtime/Tests/virgl/test-video-encode.c` encodes 30 frames
  through the virgl video protocol and decodes them again with VideoToolbox
  (all frames, luma PSNR above 30 dB; 54.9 dB measured).
- In a VM: `tests/video/webrtc-encode.sh [--fake] [--source camera|screen]`
  reports Chrome's encoder, frames, and the guest's and QEMU's CPU.
