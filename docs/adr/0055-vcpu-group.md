# 0055: The vCPU threads in a thread group of their own

Status: rejected (drops frames), not merged. Built for the record on draft
PR #541, behind the app's experimental switch "CPU clock by the VM's own
work" (off). It saves power on an M1 Max, but the VM drops frames at the
lower clock, and the rule for power work is the same frames (2026-10-25).
Notes and numbers: work/tracks/vcpu-clocks.md.

## Context

On an M1 Max the VM used 2.2-3.7x the power of macOS for the same work
(work/tracks/m1-power.md). Part of it is the CPU: the vCPU threads ran 95 %
on the performance cores at 2.55-2.7 GHz, where macOS ran the same work at
1.5-1.7 GHz. With the window hidden (the same guest work, nothing presented,
not the app in front) the vCPU threads ran at 1.56 GHz. Their QoS was the
same both times (default, priority 31).

macOS's performance controller sets the CPU clock per thread group. A
process is one thread group unless threads join a work interval with a group
of their own. QEMU's process is the app in front that shows frames; its
vCPU threads did most of the group's work, so the whole group, and with it
the performance cluster, ran at a high clock.

What did not work:

- Utility QoS on the vCPU threads (vm-power, 2026-10-24): a third of the
  frames lost. Utility also means timer latency tier 3: macOS coalesces the
  vCPUs' timed waits (Hypervisor.framework's `wait_for_interrupt` is a
  `pthread_cond_timedwait` until the guest's vtimer), so the guest's timers
  fire late (mini: 9.2k instead of 36k wake-ups in a bench, the guest's
  vblank 36/s instead of 60/s).
- Utility plus latency tier 0: setting a Mach latency tier removes the
  thread's QoS class (it is back at the default priority): no change.
- `os_workgroup_parallel_create` + join: no group of its own, no change
  (M1 Max: 2.59 GHz, 17.5 W vs 17.7 W).
- Fewer vCPUs: the same work on fewer threads runs at higher clocks
  (m1-power: +0.5 to +2.4 W).

## Decision

1. With the switch on (`OMACVM_VCPU_GROUP=1`), a vCPU thread is in one
   work interval while it is light, and out of it (as before) while it is
   busy or input comes in (`qemu-hvf-vcpu-group*.patch`,
   `include/qemu/omacvm-vcpu-group.h`): a thread "vcpu-group" reads each
   vCPU's CPU time every 25 ms; a vCPU above 25 % of a tick leaves for
   500 ms, all leave while input comes in and for 1 s after; a vCPU whose
   place changed is kicked and joins or leaves on its own thread (macOS
   allows only that), and leaves before its thread ends.
   `OMACVM_VCPU_GROUP=always` keeps every vCPU in (tests). Why adaptive: in
   the group all the time, a page that scrolls in bursts drew fewer frames
   on the M1 Max (36 instead of 43 a second). That row is not clean: the
   lab build also had timer latency tier 0 on (which also drops the thread
   to legacy QoS), and its base rows were m1-power's night rows of another
   build (300 s windows, not 240 s). So the group alone is not proven to
   cost those frames. The clip rows below are the clean A/B.
2. The work interval comes from AudioToolbox's `AudioWorkIntervalCreate`,
   looked up at run time: it is the only public API that makes a work
   interval with a thread group of its own. No interval is ever started:
   the vCPUs have no deadline; the group only separates them. Their QoS and
   priority stay as they are.
3. macOS then sets the vCPUs' clock by their own load: low while the guest
   is light, high when it is busy (guest `openssl speed` on 1 and 10 vCPUs:
   the same throughput with and without; measured on the mini only, where
   the clocks barely move, so not shown for the M1 Max).
4. Experimental and off by default: AudioToolbox documents the API for
   real-time audio threads, and a video can drop a frame now and then at
   the lower clock (below). QEMU logs `OmacVM: vCPU group: on|off|why not`,
   `omacvm check` shows it.

## Numbers

M1 Max, test VM like the user's (10 vCPU / 24 GB, full screen, HDR,
3024x1896@120), local AV1 1080p60 clip, whole Mac, brightness 0, 180 s:
base 17.74 / 17.78 W, vCPUs 2.55 GHz; group 14.68 / 15.38 W, vCPUs 1.45
GHz; dropped frames 0 / 0 vs 3 / 1 of ~12k (same session, A/B/A/B; a
parallel workgroup in between: 17.51 W, 2.59 GHz, 0 drops). This is the
only clean A/B set, and it alone shows "not the same frames".

MacBook Air M2 (8 vCPU / 4 GB, 2940x1840@60, Chromium 1080p30 clip, 240 s
windows): clip 4.01 / 4.04 / 4.05 W base vs 3.93 / 3.91 W group, scroll
4.71-4.89 vs 4.65 / 4.71 W, idle and typing the same (set 1's +0.23 W was
the order: it ran base first, with Spotlight and log processes busy).
Dropped frames 112 / 0 / 0 base vs 22 / 144 group: noise, they prove
nothing either way.

The adaptive build (decision 1) has no M1 Max rows (the Mac was not free).
On the Air it was 3.93 W on the clip with 71 dropped frames.

## Consequences

- QEMU's main loop shares the performance cluster and runs at its lower
  clock too (M1 Max: 7.7 % of a core at 2.59 GHz -> 22 % at 1.62 GHz).
- If Apple ever refuses non-real-time threads in an audio work interval,
  the join fails, QEMU logs why and the vCPUs run as before.

## Known gaps (not fixed: not merged)

- The input rule reads only QEMU's own input layer
  (`qemu_input_last_event_ns`). Trackpad scrolling and gestures go through
  OmacVMGestures into the guest's uinput, and with scroll momentum on QEMU
  drops its own trackpad scroll events. So burst scrolling, the case the
  adaptive rule is for, never takes the vCPUs out.
- A failed join is tried again on every pass of the vCPU loop (getenv and
  strcmp each time); it should be tried once.
- vCPU 0 logs "on" before the others join; a later vCPU that fails to join
  is not logged, and `omacvm check` still says on.

## Not tried

- A work interval with deadlines: start and finish it each frame with the
  refresh deadline (8.3 ms at 120 Hz), from a thread in the group (the
  present or display-link thread). Without that, macOS can only follow the
  load and raises the clock late after a burst starts.
- Which thread misses the frame: with the group on, qemu_main went from
  7.7 % of a core at 2.59 GHz to 22 % at 1.62 GHz, three times the CPU time
  for a 1.6x lower clock. The late frames may come from the main loop or
  the present threads, not the vCPUs. A P cluster shares one clock, so
  keeping those threads fast may undo the gain.
- Leaving the group on late frames (`cocoa_present_skips`) or on the
  guest's total load, not per-vCPU load (a video spreads light load over
  all vCPUs, so each stays in).
- Before anyone revives this: same-set A/B rows on the M1 Max with the group
  alone (no tier 0), and the first two levers above.
