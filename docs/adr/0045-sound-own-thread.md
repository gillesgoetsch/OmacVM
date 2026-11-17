# 0045: The sound on its own real-time thread, not in QEMU's main loop

Status: accepted, built (`audio`, 3.1.16), off by default (`audioThread`).

## Context

3.0.0 put QEMU's main loop at user-interactive QoS and stopped the HDA
codec catching up after a stall (ADR 0036). Users still heard crackles
"on cpu load ... listening to spotify ... or youtube". The main loop still
moves the sound: the HDA codec's DMA timers and the mixer's 1 ms audio
timer run there, beside the VM's GPU (virgl), which holds the main loop
and the BQL for 100-350 ms while an app opens or a page scrolls in
Chromium. QEMU's 93 ms ring covers shorter stalls; after one it refills
at 1/32 of real time, so stalls in a row add up to a break.

Measured on the Mac mini M4 (VM with 8 CPUs, a 30 Hz tone through
PipeWire, QEMU's mixer output and what SDL got recorded apart, a 1 ms
real-time sleeper in the guest, how long vCPUs wait for the BQL;
`work/tracks/audio-crackle.md`, 2026-10-16):

1. On the main loop most breaks were on the Mac's side: SDL got less than
   QEMU's mixer played (the ring ran dry in the long stalls).
2. Every main loop stall also stops the vCPUs that leave the guest
   (any exit takes the BQL): the worst vCPU wait equalled the worst stall
   in every run. The guest's own buffers have to cover that part.
3. With the Mac busy (a build) the guest itself froze for up to 150 ms
   (its vCPU threads got no Mac time) and its streams ran dry. Nothing in
   QEMU's sound path can cover that.

## Options

1. The HDA codec's DMA and the mixer as ticks on one thread of their own,
   at macOS's time-constraint policy, never taking the BQL (DMA to guest
   RAM directly under RCU, the interrupt from a bottom half, one lock for
   the sound's state). Then the ring only covers the thread's own jitter.
2. As 1, and pause the guest's sound clock while the main loop holds the
   BQL (as the main loop path does by itself): the ring then still has to
   cover the stalls, so it stays at 93 ms, and the guest's clock stops in
   every stall (videos wait).
3. QEMU's CoreAudio driver with a small buffer: lower latency than SDL's
   AudioQueue (6 x 5.3 ms), but no recording, no start without hanging on
   a dead coreaudiod, and the same main loop unless 1 comes with it.
4. A bigger quantum or headroom in the guest: covers guest-side breaks at
   the price of latency for every app.
5. vCPU 0 at a higher QoS with the guest's sound pinned to it: tried; no
   difference measured with 8 busy Mac threads.

## Decision

Option 1 (`qemu-audio-own-thread.patch`, `OMACVM_AUDIO_THREAD=1`), with
SDL kept and QEMU's ring cut from 8 x 512 frames at 44.1 kHz (93 ms) to
6 x 256 frames at 48 kHz (32 ms; 48 kHz is the guest's and the Mac's
rate, so nothing is resampled). The app tells the VM QEMU's shorter delay
for A/V sync (`AudioDelay.qemuThreadMs`). Off by default for now (below):
`defaults write org.omacvm.app audioThread -bool true` turns it on,
`audioMainLoop` keeps 3.1.14's path whatever the default; `omacvm check`
says which ("sound timing").

## Consequences

- Breaks in the tone per run (what SDL got; 4 minutes, a few 3-minute
  screening runs), the 3.1.14 path vs the own thread: browsing 5, 14, 0, 0
  vs 0, 0, 0, 0, 2; the Mac busy (8 threads) 12, 0, 0 vs 0 (4 runs); a
  video in Chromium 0, 44, 0, 0 vs 2, 0, 2, 2, 2, 2, 17 (mostly one 21 ms
  dropout when a second Chromium starts; 17 with the Mac busy as well);
  glmark2 7, 4, 18 vs 6, 2, 6, 8, 0, 4, 13; every
  core busy 4 vs 13 (one run each); idle and the VM's CPUs busy 0 both. The
  audio tick was never more than 2-17 ms late (the main loop's timers:
  up to 350 ms). Round trip 271.5-273.4 → 208.4-210.2 ms.
- Not better in every case, so off by default: the GPU and everything-busy
  cases are a draw or worse, because the shorter ring holds less of the
  BQL stalls the guest goes through. The user's listening test decides.
- The guest-side part stays: while virgl holds the BQL, vCPUs that leave
  the guest wait. Moving the GPU off the main loop (the gpu-thread lane)
  removes it.
- A Mac that starves the VM's vCPUs (a build on every core) still breaks
  the guest's streams; more guest buffering would cover it at a latency
  cost. Not done.
- CoreAudio direct (option 3) would save SDL's AudioQueue as well (about
  25 ms more); it needs recording and the no-hang start first.
- 3.2.5 (#548): AirPods (A2DP) refused to start SDL's AudioQueue of this
  path (48 kHz, 6 x 256 frames; AudioQueueStart -66681) and played the
  main loop's (44.1 kHz, 4 x 512; SDL3 opens the queue at QEMU's rate).
  A start with a wireless output now uses the main loop's queue on this
  path (`AudioPath.threadWirelessOptions`, ring 4 x 512); a switch to one
  while the VM runs reopens it with 512 frames (the app's size file), and
  a refused start tries 512, then 1024, at once, each only while QEMU's
  ring holds twice that (`qemu-sdl-audio-out-size*.patch`).

## 3.5.0: the tick follows the streams

The thread ticked every 1 ms whatever the streams needed: about 1000
real-time wakeups a second while any stream was open, silence too. Each
tick now says the longest period it can take and the thread runs at the
shortest, 1-10 ms (`qemu-audio-tick-follows-stream.patch`):

- an HDA stream: a quarter of the guest's shortest DMA entry (the guest
  sees its position move once a tick), at most an eighth of the codec's
  8 KiB buffer;
- the mixer: a quarter of QEMU's ring after two of CoreAudio's buffers
  (one for the next callback, one in flight), read every tick, so the
  AirPods sizes of #548 shorten it at once.

PipeWire in a VM (1024-frame periods, 4096-byte entries) and the 6 x 256
ring both give 5.33 ms; a refused start with 1024-frame buffers keeps
1 ms. A plain longer tick was not safe: the pacing (ADR 0036) forgave
anything above a 5.33 ms burst as a stall, so its burst now grows with the
period and a late tick keeps the 4.3 ms of slack it had at 1 ms. The
queued audio does not grow (the codec buffer is held at half whatever the
tick), so `AudioDelay.qemuThreadMs` stays. `OMACVM_AUDIO_THREAD_PERIOD_US`
still fixes the period (1000 = before).

Measured (same build, 1 ms fixed vs following): Mac mini M4, hidden test
VM, a tone through PipeWire for 3 minutes per case (idle, busy vCPUs,
glmark2), three pairs: 22 / 26 breaks (QEMU's mixer / what SDL got) and
2/8 xruns with 1 ms, 16 / 28 and 2/2 following; the extra breaks of one
pair came with the Mac stalling the thread for 66 ms, which empties the
ring with either tick. Round trip median 211.7 ms vs 208.9 ms. MacBook Air M2, on
screen, the browser blend (an AV1 video with sound, a chat page, typing),
6 + 6 windows: 5.26 -> 5.15 W (-0.11 +- 0.07 W), QEMU's wakeups
4113 -> 3397 a second; frames shown 60.4-60.5/s both ways, dropped video
frames within the run-to-run spread (3-89 vs 37-189 per 2 minutes; earlier
1 ms rows 106-222).
