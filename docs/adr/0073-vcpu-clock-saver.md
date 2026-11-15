# 0073: VM CPU clock saver (the vCPU threads in a thread group of their own)

Status: accepted as an experimental switch, off by default (for 3.5.0). The
owner chose it as an opt-in and accepts its rare dropped frames for this
switch only (2026-11-14); off is today's behaviour. Built on the work of the
closed PR #541 (an earlier draft of this ADR, numbered 0055 there, rejected
then because the static group dropped frames). Notes and numbers:
work/tracks/vcpu-clocks.md, work/power-1114/cpu/.

## Context

On an M1 Max the VM used 2.2-3.7x the power of macOS for the same work.
Part of it is the CPU: the vCPU threads ran 95 % on the performance cores
at 2.55-3.0 GHz, where macOS ran the same work at 1.5-1.7 GHz. With the
window hidden (the same guest work, nothing presented, not the app in
front) the vCPU threads ran at 1.56 GHz. Their QoS was the same both times
(default, priority 31).

macOS's performance controller sets the CPU clock per thread group. A
process is one thread group unless threads join a work interval with a group
of their own. QEMU's process is the app in front that shows frames; its
vCPU threads did most of the group's work, so the whole group, and with it
the performance cluster, ran at a high clock.

What did not work, and is not to be tried again for vCPUs (PLAN P3):

- Utility QoS on the vCPU threads: a third of the frames lost. Utility also
  means timer latency tier 3: macOS coalesces the vCPUs' timed waits, so the
  guest's timers fire late (the guest's vblank 36/s instead of 60/s).
- The whole QEMU process in the background, or the background thread class
  (`PRIO_DARWIN_BG`, `taskpolicy`): the same family as utility.
- `os_workgroup_parallel_create` + join: no group of its own, no change.
- Fewer vCPUs: the same work on fewer threads runs at higher clocks.

## Decision

1. The app's switch "VM CPU clock saver" (`vcpuClockSaver`, General, after
   Resources; experimental, off by default). QEMU runs as the app, reads the
   key at start and watches it with KVO, like "Pause drawing while hidden",
   so it works at once in a running VM (`omacvm-cocoa-vcpu-clock-saver.patch`).
   `OMACVM_VCPU_CLOCK_SAVER=1|0` decides instead (a QEMU not started as the
   app, tests); GPU safe mode sets `0`.
2. With it on, every vCPU thread joins one work interval and nothing else
   does (`qemu-hvf-vcpu-clock-saver*.patch`,
   `include/qemu/omacvm-vcpu-clock-saver.h`). The main loop, the sound
   thread, the present threads, the display link and virgl's threads stay
   where they are. The interval comes from AudioToolbox's
   `AudioWorkIntervalCreate`, looked up at run time (the only public API
   that makes a work interval with a thread group of its own), made at the
   first join. It is never started: no deadline, nothing real-time. The
   vCPUs' QoS class, priority and timer latency tier stay as they are
   (checked by the test on threads).
3. A change reaches each vCPU as queued work (`async_run_on_cpu`), which
   also wakes a halted, offline or stopped vCPU; the vCPU joins or leaves on
   its own thread (macOS allows only that). A vCPU made while it is on
   joins at its start; every vCPU leaves before its thread ends (libdispatch
   stops a thread that ends while joined). A failed join is not tried again
   until the switch goes off. The last vCPU to follow a change writes
   `OmacVM: vCPU clock saver: on, N of M vCPUs (why)`, `off (why)` or
   `not available: why (why)` to qemu.log; `omacvm check` shows it (ok when
   every vCPU joined, a warning otherwise).
4. With the switch never on in a run, nothing is queued, AudioToolbox is
   not loaded and no group is made: today's behaviour exactly.
5. Every vCPU joins (the rule #541 measured). Keeping vCPU 0 out (it takes
   virtio-gpu's interrupts and runs the kworker that wakes the compositor)
   is the one clean candidate to cut the drops; it ships only if an M1 Max
   set shows it at most half the drops of "every vCPU" with the watts
   within 0.3 W (work/power-1114/cpu/design.md, section 2). Not built in
   the product.

## Numbers

M1 Max (#541's product build, the same mechanism), test VM like the
owner's (10 vCPU / 24 GB, full screen, HDR, 3024x1896@120), local AV1
1080p60 clip, whole Mac, brightness 0, 180 s, A/B/A/B in one session: base
17.74 / 17.78 W, vCPUs 2.55 GHz; group 14.68 / 15.38 W, vCPUs 1.45 GHz;
dropped frames 0 / 0 vs 3 / 1 of ~12k. The only clean A/B set so far.

MacBook Air M2 (8 vCPU / 4 GB, 60 Hz): clip 4.01-4.05 W vs 3.91-3.93 W,
scroll 4.71-4.89 vs 4.65-4.71 W, idle and typing the same. Its drop counts
were noise in both arms and say nothing.

Not measured yet (owed before the switch's text is final): a busy desktop,
burst scrolling at 120 Hz (a lower scroll frame rate would be a cut, not a
rare drop: the switch does not ship then), idle, sound glitches, the
guest's timer lateness, browser scores, input latency, M1 Pro, M3, and whole-Mac watts on an
M4 (the mini was measured hidden, from thread counters only, see
Consequences).

## Consequences

- The threads that stay in the app's group share the performance cluster
  and run at its lower clock too (M1 Max: qemu_main 7.7 % of a core at
  2.59 GHz -> 22 % at 1.62 GHz). They keep their own QoS and settings.
- On an M4 they can also move to the efficiency cores. Mac mini M4, hidden
  rows from thread counters only (no whole-Mac watts): qemu_main is not in
  the group, yet with the switch on its P-core share fell from 100 % to
  3-5 % in video (its CPU rose from 6 % to 19 % of a core) and from 89 % to
  30 % while scrolling. So on an M4 the frame and sound path runs on E
  cores while the switch is on. "Frame path and audio never join" holds in
  the code, but not in where macOS runs them. This is why the switch stays
  opt-in and Experimental, and why its gates (same scroll fps, sound
  glitch count, qemu_main's own energy off vs on) must pass on screen.
- The row's (i) states the measured watts, the drop counts and which Macs
  are not measured; it is updated with the M1 Max set before 3.5.0.
- If Apple ever refuses non-real-time threads in an audio work interval,
  the join fails, QEMU logs why, the vCPUs run as before and `omacvm check`
  warns.

## Not done

- #541's adaptive rule (a 25 ms thread, busy and input rules): never
  measured on an M1 Max, and its input rule missed trackpad scrolling,
  which goes from OmacVMGestures straight to the guest.
- A work interval with deadlines started each frame: the API is for audio
  deadlines and there is no host frame start for the guest's work.
- Real-time or raised priority for the main loop or present threads: that
  changes the frame and sound path.
