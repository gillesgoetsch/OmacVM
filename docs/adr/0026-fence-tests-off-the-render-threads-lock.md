# 0026: Fence tests stay off Apple GL's lock while the render thread works

Status: accepted, built (`aquarium-perf`). Builds on
[0011](0011-async-fences.md), [0017](0017-fence-wait-short-sleeps.md) and
[0010](0010-iosurface-present.md).

## Context

In 2.9.0 WebGL Aquarium (30,000 fish) ran about 5 % slower than in 2.8.0,
while glmark2 was 2.5 times as fast. In Aquarium QEMU's main loop, which
is the render thread, is busy all the time (96-98 % of a core), so anything
that slows it down shows one to one in the frame rate.

Two threads of 2.9.0 test GL fences beside it: `vrend-sync` (each new fence:
up to 100 us of back-to-back tests, then a test every 50 us) and the present
queue (a test every 100 us until the blit of a shown frame is done; in
Aquarium that blit waits behind the guest's 50 ms of GPU work). Every
`glClientWaitSync` takes Apple GL's share-group lock, and so do the render
thread's `glBindBuffer`, `glUseProgram` and friends. Samples of the render
thread show it in `_os_unfair_lock_lock_slow` and `__ulock_wake` inside
those calls in 2.9.0 and hardly at all in 2.8.0; `vrend-sync` shows the
same lock from its side. Each collision parks the render thread in the
kernel. RC3 in GPU safe mode (2.8.0's polled fences and layer drawing) was
as fast as 2.8.0, so the shader and security changes are not the cause.

## Options

1. Accept the cost: glmark2 and every light or fence-bound app gain far
   more than Aquarium loses.
2. Fewer tests for everyone: longer naps or no spin. Costs glmark2-like
   apps, whose guest waits on the fence while the render thread is idle;
   that is where the sync thread's speed comes from.
3. Test fences only when they cannot collide: while the render thread runs
   guest commands the sync thread waits for the end of the submit (the
   render thread wakes it) and tests then; when it is idle, test as before.
   The present queue, which has no such signal, backs off after 1 ms.
4. Retire fences on the render thread itself between commands, with the
   sync thread only for the idle case. Larger change in QEMU and
   virglrenderer for the same effect.

## Decision

Option 3, macOS only:

- `virgl_renderer_submit_cmd(2)` mark the render thread busy. While it is
  busy, or stopped less than 50 us ago, `vrend-sync` neither spins nor naps
  on a timer: it waits on a Mach semaphore that the render thread signals at
  the end of a submit (only when someone waits), at most 1 ms, then tests.
  After a busy wait the wait starts over (spin and short naps first), so an
  idle render thread reports fences as fast as before.
- The present queue tests every 100 us for the first millisecond, then the
  nap doubles up to 1 ms. Frames whose blit is done within 1 ms (testufo,
  video, the desktop) see no change.
- `OMACVM_VIRGL_FENCE_BUSY=0` and `OMACVM_GL_PRESENT_NAP_MAX_US=100` go
  back to the 2.9.0 RC behaviour; the sync thread logs which way it waits.

## Consequences

- Bench lock, one app VM, window alone on a virtual 120 Hz display, two
  sessions each (2.8.0 / RC3 / this): Aquarium 20.2 / 19.0 / 19.9 fps,
  glmark2 short set 1160 / 2986 / 3168, testufo 117.0 / 117.5 new frames a
  second (RC3 / this), Basemark Web 3.0 2524 / 2916 (RC3 / this, ranges
  overlap). The sync thread part alone gives Aquarium 20.15-20.6, the
  present part alone 19.65-19.85, neither 19.1-19.85.
- The sync thread's CPU during Aquarium 7.3 % -> 2.3 %; QEMU's wakeups
  5,900 -> 3,600 a second.
- Outside QEMU (`Tests/virgl/bench-fence-contention.c`, two shared CGL
  contexts, bench lock): a thread testing a fence back to back, as the
  sync thread does for up to 100 us after each new fence, cuts a draw-heavy
  GL thread by 35 %; one test every 50 us or every 1 ms stays within the
  noise (2-4 %). The spin after each new fence (thousands a second in
  Aquarium) is what hurt; it now happens only while the render thread is
  idle.
- A fence that finishes while the render thread is busy is reported at the
  end of the current submit or within 1 ms. The guest only waits on such a
  fence when it has nothing else to send, and then the render thread is
  idle and the fast path applies.
- One more cross-thread signal per submit, only while the sync thread waits
  (a Mach semaphore, about a microsecond).
