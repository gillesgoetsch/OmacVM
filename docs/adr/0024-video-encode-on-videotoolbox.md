# 0024: Video encoding through VideoToolbox, VideoToolbox's own stream

Status: accepted, built (`video-encode`, `virgl-videotoolbox-encode.patch`), not merged.
Builds on [0014](0014-videotoolbox-in-virglrenderer.md) (decoding).

## Context

Apps in the VM encode H.264 and HEVC through VA-API: FFmpeg (`h264_vaapi`,
`hevc_vaapi`), OBS, and Chrome's WebRTC encoder (camera and screen sharing in
calls). Mesa's virgl VA driver forwards an encode as one raw NV12 picture plus a
picture description (rate control, GOP, picture type, the guest's SPS fields,
reference lists). On a Linux host virglrenderer hands that to VA-API, whose
hardware encoder follows the guest's description slice by slice. The Mac's
media engine is reached through VTCompressionSession, which takes pictures and
returns a whole stream: it picks frame types, references and parameter sets
itself and offers no slice-level control.

## Options

1. VTCompressionSession as a black box: take the guest's rate, frame rate, GOP
   and IDR requests, ignore its reference lists and SPS/PPS, return
   VideoToolbox's stream (Annex B, parameter sets before every key frame).
2. Make VideoToolbox's output match the guest's description (rewrite slice
   headers, SPS/PPS, reference lists). Not possible: VideoToolbox does not take
   a reference structure, and rewriting coded slices means re-encoding.
3. No encoding (status quo): FFmpeg and WebRTC encode on the VM's CPU.

## Decision

Option 1, without B frames (`AllowFrameReordering` off: VA-API's
one-picture-in, one-access-unit-out model has no room for reordering) and in
real time. The guest's padded picture is cropped to the size its SPS asks for
(1920x1088 -> 1080), since VideoToolbox writes its own SPS.

Rate control: VideoToolbox's low-latency mode drops frames to hold the
bitrate, and VA-API cannot tell the guest a frame was dropped (Chrome then
gives up on the hardware encoder: "Invalid encoded chunk size"). The session
uses the normal rate control with `AverageBitRate` and `DataRateLimits` (1.5 x
the target in any second); no frame was dropped in any test, and the bitrate
stays near the target. Constant QP is the one case for the low-latency
session: it takes a QP with every frame (`BaseFrameQP`, which turns its rate
control off, so nothing is dropped); an encoder without that would get
VideoToolbox's quality from the QP (not a QP, logged). A switch between
bitrate and constant QP makes a new session.

## Consequences

- Stock Mesa and stock apps in the guest. Chrome needs its VA-API encoder
  features switched on (`src/app/guest/browser-video-encode.py`); FFmpeg and
  OBS need nothing. Arch Linux ARM's Chromium has no VA-API: it encodes on the
  CPU.
- The guest's own headers are not in the stream: an app that writes its own
  SPS/PPS (packed headers) into the container gets VideoToolbox's in-band ones
  too; decoders use the in-band ones. FFmpeg, OBS and Chrome play back fine.
- Frame-level requests the guest makes beyond rate, GOP and IDR (long-term
  references, temporal layers, intra refresh, ROI) are ignored. Chrome's
  WebRTC uses none of them on Linux for H.264.
- Each frame waits for its coded data in end_frame on vrend's thread
  (1-3 ms at 1080p): parallel streams queue behind each other.
- H.264 Constrained Baseline, Main, High and HEVC Main up to 4096x2304; no
  HEVC Main 10 (would need P010 input), no AV1/VP9 (the media engine does
  not encode them). Firefox (157) has no VA-API encoder on Linux.
- `OMACVM_VIDEO_NO_ENCODE=1` (all) and `OMACVM_VIDEO_NO_HEVC=1` turn it off;
  the guest then encodes on its CPU.
