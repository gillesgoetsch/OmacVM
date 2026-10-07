# A/V sync measurements

How far the sound is from the picture when a video plays in an OmacVM.app VM
(av-sync track, 3.0.1). Test VMs only: these tools play sound and take the
screen.

## Tools

- `mkclip.sh OUTDIR [SECONDS]`: test clips. Every second the whole picture
  turns white for 100 ms and a 1 kHz beep plays for 50 ms, both on the
  second. H.264 + AAC (MP4) and VP9 + Opus (WebM), 1280x720 at 60 fps, plus
  `av.html`, which plays one full screen and logs dropped frames.
- `clip2csv.sh CLIP OUT.csv`: decodes a clip with FFmpeg, to check the clip
  itself (H.264: 0 ms, VP9/Opus: -7 ms as FFmpeg decodes it).
- `avcap.swift`: records the Mac's screen and the Mac's sound together with
  ScreenCaptureKit (one clock for both): per frame the brightness of the
  centre of the screen, per millisecond of sound the loudest sample. Needs
  Screen Recording (an SSH session on the test Mac has it).
- `avsync.py FILE.csv`: pairs each flash with its beep. Offset = sound minus
  picture, positive when the sound is late. Prints median, spread and drift.
  `--selftest` checks it on a synthetic recording.
- `outlat.swift`: the output latency CoreAudio reports for the Mac's default
  output (what a Mac app adds to its own A/V sync, and what QEMU's sound path
  never tells the VM).
- `mini/`: the run on the Mac mini (plain QEMU from a copy of the test app's
  runtime, with the app's options; native Chrome on the Mac as reference).
  `mini/fix.sh` (after the matrix): the 3.0.1 fix, re-measured: installs
  `omacvm-audio-latency` in the test VM, sets the delay as the app would and
  plays the clips again (expected: about minus the device's latency, since
  avcap takes the sound before the device). `QPART` sets QEMU's part,
  `TAG` a label suffix; `mini/confirm.sh` waits for the mini lock and runs
  it twice with 115 ms. `mini/review.sh`: the review runs (other players,
  10 minutes for drift, the crackle tool with and without the offset);
  `mini/runp.sh` plays the clip with any player in the guest.

## Results (Mac mini M4, LG UltraFine 12.8 ms, 2026-10-06)

Sound minus picture at macOS's mixer, ms (add 12.8 for the ear):

| run | median |
|---|---|
| native Chrome on the Mac, H.264 / VP9 | +2.3 / -1.7 |
| 3.0.0, H.264 hardware / software decode | 143.4 / 151.0 |
| 3.0.0, VP9 | 113.6 |
| 3.0.0, H.264 with glmark2 stalls | 114 (p10 69, p90 140) |
| audioClassic, H.264 / with stalls | 112.0 / 107 |
| Vulkan, H.264 / VP9 | 146.9 / 126.0 |
| fix, QEMU part 115 (told 128), run a: H.264 / VP9 / stalls | -12.6 / -1.0 / -11.8 |
| fix, run b (VM restarted): H.264 / VP9 / stalls | +16.3 / +29.2 / -14.1 |

Steady within a run (sd 0.1-7 ms); from run to run QEMU's part moves
106-151 ms. After stalls the sound comes up to the stall's length earlier
for a few seconds.

ScreenCaptureKit takes the sound before the output device and the picture
before the display's scan-out: add the device latency `outlat` prints for
what you hear.

### Review runs (2026-10-06 evening, same Mac mini, at the mixer)

Other players, the same VM, offset 0 (as 3.0.0) and then 128 (115 + 12.8):

| player | offset 0 | offset 128 |
|---|---|---|
| mpv (PipeWire output), H.264 | +136.0 | +0.1 |
| mpv `--ao=pulse`, H.264 | | +14.6 |
| Firefox 157, VP9 | +136.7 | +10.1 |

All three take PipeWire's latency offset: the shift is the 128 ms that were
set. Within a run sd 7-13 ms; the first minute is often 15-20 ms later than
the rest, then steady.

Crackles (`../audio/measure.sh 300 both 4`: 8 busy vCPUs, glmark2, 4 busy
loops on the Mac): offset 0: 41 breaks per 10 min, 0 sink xruns; offset 286
(AirPods-sized): 25 breaks, 0 sink xruns. The offset changes no buffer:
quantum 2048 (sink) / 8192 (pacat), ALSA period 1024 and buffer 32768 in
both, and the same in the Chromium runs with and without it.

Drift, 10 minutes with offset 128: Chromium (700 s H.264 clip, hardware
decode) median +14.2, drift +1.2 ms/min; the offset moves only between
-3, +14 and +31 ms (one 60 Hz frame apart: which frame the flash lands on),
the same levels at the start and the end. mpv: median -2.1, drift -0.1
ms/min. No drift.

Two things that are not this fix, seen on the way:
- WirePlumber came up broken in both boots of the fresh clone: no stream
  linked to the sink, every player silent, until WirePlumber was restarted.
  Both times DKMS built `omacvm_vdec` at boot (the clone's kernel had no
  module yet) and loaded it 18 s after WirePlumber started; WirePlumber's
  V4L2 monitor logged "Cannot open '/dev/video0': No such device" at that
  moment. A user VM could hit this on the first boot after a kernel update
  (chromium-video on). `review.sh` checks and restarts WirePlumber.
- Chromium's loop of the 180 s H.264 clip with hardware decode hung at its
  end (t=180.000, not paused), so long runs use a 700 s clip.
