# Sound crackle measurements

How the "sound crackles while the VM or the Mac is busy" fix was measured
(audio-crackle track, 2026-10-05). Test VMs only: these tools play sound,
install `stress-ng` with pacman and load every core.

## The sound path

Guest app → PipeWire (in a VM: quantum 1024 at least, ALSA headroom 2048) →
Intel HDA (`intel-hda` + `hda-micro`) → QEMU's mixer (44.1 kHz) → SDL2-compat
→ SDL3 → CoreAudio. QEMU's 1 ms audio timer and the HDA's DMA timer run in
QEMU's main loop, the same thread that runs virgl. SDL hands CoreAudio 512
frames (11.6 ms) per callback from its own thread; QEMU's ring holds 8 of
them (`out.buffer-count=8`, 93 ms).

## Tools

- `glitches.py`: counts breaks and silences in a recorded test tone (a sine
  breaks its own recurrence at every gap, repeat or skip). `--selftest` runs
  in CI (`src/tests/audio-timing.sh`).
- `measure.sh`: on a running test VM, plays a 30 Hz tone through PipeWire's
  PulseAudio part (as Spotify does), loads the guest (`stress-ng`, glmark2's
  scene changes) and optionally the Mac (`yes` loops), takes QEMU's mixer
  output with HMP `wavcapture` and prints guest xruns (`pw-top` ERR), tone
  glitches and how late QEMU's audio timer ran (QEMU started with
  `-trace audio_timer_delayed -trace hda_audio_full_recovery`). `LOAD_AS=user` runs
  `stress-ng` in the desktop user's `app.slice` (where a browser or a build
  runs) instead of root's SSH session.
- `sdlprobe.c`: a library injected into a test copy of the runtime (re-signed
  with the test identity plus `allow-dyld-environment-variables` and
  `disable-library-validation`) that records what QEMU really hands SDL, and
  can loop playback back into a fake recording device for a round trip
  without a microphone (`jack_iodelay` through `pipewire-jack` in the guest).
- `wedged-output-start.c`: a library that makes `AudioQueueStart` block, as
  it does when coreaudiod stops answering (forever, after the first N
  starts, or until a file exists, then start or fail). For the start-hang
  fix (`qemu-sdl-audio-playback-thread.patch`, troubleshooting finding 26):
  the VM must boot and play to nobody instead of hanging.

- `freeze.py SECONDS OUT.json`: in the guest at `chrt -f 50`, a 1 ms sleeper
  that records how late it woke: a gap is the VM not running (its vCPUs
  waiting for the BQL, or getting no Mac time), not guest scheduling.
- `scroll.html`, `video.html`, `mkvideo.sh`: the realistic cases of the
  audio lane (2026-10-16): a heavy page in Chromium that scrolls itself,
  and a 1080p H.264 video whose sound is the tone (FLAC, so it stays a pure
  sine). The lane's harness (`work/audio-rt/kit` on the mini: run.sh,
  cfg.sh) adds a terminal every 8 s and a new Chromium every 20 s for
  "browsing", and records the probe's stream, QEMU's mixer, guest xruns,
  freeze.py and how long vCPUs wait for the BQL apart.

## The sound's own thread (3.1.16, `audioThread`, Mac mini M4, 8 vCPUs, 4 minutes each)

Breaks in what SDL got, QEMU's main loop (3.1.14) vs the own thread
(`qemu-audio-own-thread.patch`, ring 6 x 256 frames at 48 kHz):

| Case | Main loop | Own thread |
|---|---|---|
| tone (pacat) + browsing in Chromium | 5, 14, 0, 0 | 0, 0, 0, 0, 2 |
| tone + 8 busy Mac threads | 12, 0, 0 | 0, 0, 0, 0 |
| the tone as a video's sound in Chromium + scrolling | 0, 44, 0, 0 | 2, 0, 2, 2, 2, 2, 17 |
| tone + glmark2 | 7, 4, 18 | 6, 2, 6, 8, 0, 4, 13 |
| tone + glmark2 + stress-ng + 8 Mac threads | 4 | 13 |
| tone + stress-ng / idle | 0 / 0 | 0 / 0 |

Round trip (jack_iodelay, loopback probe): 271.5-273.4 ms → 208.4-210.2 ms.
On the main loop most breaks were on the Mac's side (SDL got less than the
mixer played); on the own thread they are all guest side (vCPUs waiting for
the BQL while virgl holds it, or no Mac time). Full log: the audio-crackle
track notes.

## The tick follows the stream (3.5.0, `qemu-audio-tick-follows-stream.patch`)

Same build both ways, `OMACVM_AUDIO_THREAD_PERIOD_US=1000` (the old fixed
1 ms tick) vs the tick following the stream (5.33 ms here). Mac mini M4,
hidden test VM (4 vCPUs, Omarchy 4.5, ALSA period 1024, buffer 32768),
the tone for 3 minutes per case, sdlprobe with loopback and mute
(work/power-1116/snd/kit):

| Case | 1 ms | follows |
|---|---|---|
| tone (pacat), idle | 0 / 0 | 0 / 0 |
| tone + stress-ng in the user's app.slice | 0 / 0 | 0 / 0 |
| tone + glmark2 | 10 / 13 (xruns 0/5) | 6 / 16 (xruns 1/1) |
| round trip (jack_iodelay) | 211.7, 212.0 ms | 208.8, 208.9 ms |

Breaks are QEMU's mixer / what SDL got. The pacing's forgive and sync-step
traces counted the same in both (367 / 412-415 per boot).

## Results (MacBook Pro M4 Max, 8 vCPUs, 10 minutes each, bench lock held)

glmark2's terrain scene (a new scene every 10 s) and 8 busy `yes` loops on
the Mac, with or without 8 busy vCPUs (`stress-ng`); the tone through
PipeWire (`paplay`, or `pw-play --latency 1024`). Breaks per 10 minutes in
what SDL got:

| Load | 2.9.0 | QoS | QoS and no HDA catch-up |
|---|---|---|---|
| GPU + Mac | 12 | | 2 |
| CPU + GPU + Mac | 726, 392, 337, 28 (median 365) | 64, 197, 120, 216, 52 (median 120) | 132, 19, 37, 62 (median 50) |
| (sink xruns, same runs) | 414, 221, 7, 1 | 35, 99, 15, 14, 0 | 73, 0, 0, 0 |
| (main loop 10-49 ms late) | 2,261-4,752 | 3-9 | 1-3 |

2.9.0 with the guest's ALSA headroom at 8192 (troubleshooting finding 25):
15 and 44 breaks.

Round trip in the guest (`jack_iodelay`, loopback probe): about 282 ms for
2.9.0, QoS, and QoS with pacing; 400 ms with headroom 8192. The spread from
run to run is large (other work on the Mac): compare runs taken close
together. Full log: the audio-crackle track notes.
