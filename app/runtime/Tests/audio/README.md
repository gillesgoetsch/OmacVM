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
