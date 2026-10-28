# 0060: When the VM stands still: a note per stall, no video session work on the GPU thread

Status: accepted, built (`vm-stall`): the stall note and the app menu line in
QEMU, VideoToolbox sessions on each decoder's queue with one time limit per
picture (`OMACVM_VIDEO_GIVEUP_MS`, 250 ms), the note in the VM and `omacvm
check`'s "VM stalls" line. Notes, the probe and the reviews:
work/tracks/vm-stall.md.

## Context

On 2026-10-28 the user's VM (OmacVM.app 3.2.6, 42 GB and 14 vCPUs on a 64 GB
M4 Max, a video call in Chrome) stood still twice: the guest logged an RCU
stall of about 60 s on CPUs 1, 2, 3 and 8 while CPU 10 ran, its video daemon
missed its 10 s watchdog, the display agent heard nothing from the Mac for
15 s. The Mac had 0.3 GB free and was compressing the VM (13 to 20 GB in
10 minutes) while its pressure level said normal. Nothing in qemu.log said
why.

A probe on the Mac mini (a test-only dylib: BQL and GPU lock holds, each vCPU
thread's CPU time and Mach state, slow calls) with pinned per-CPU probes in
the guest, under a call-like load, found:

- At critical memory pressure three vCPU threads stood in `hv_vcpu_run`
  without CPU time for 2.4, 2.1 and 1.2 s, Mach state 4 (uninterruptible:
  a stage-2 page fault waiting for macOS to make a page free), matching the
  guest's per-CPU gaps; the BQL was held at most 6 ms then, and at most
  75 ms in every row, also while the mini swapped. 3.2.6 and main alike.
- The same paging held QEMU's main loop (virglrenderer's thread) 1.6 s in
  `VTDecompressionSessionCreate` (an XPC look-up of the Mac's video service),
  in Metal submits (100-780 ms) and in copies from guest RAM, mostly in
  virtio-gpu's unlocked runs (no BQL): the vCPUs ran on, but no fence, frame
  or disk request of the VM moved meanwhile.
- The stall watchdog (3.0.6) called a stall inside such a run "with the BQL
  held (the VM waits)", which was false.

## Decision

1. **Say it.** The stall watchdog's thread, which wakes every 2 s anyway,
   reads every vCPU thread's CPU time and Mach state (`thread_info`); a vCPU
   in the same `hv_vcpu_run` with no CPU time since, uninterruptible or
   runnable, stands still; while one does it looks every 250 ms. One
   qemu.log line per stall of 1 s or more, with the Mac's free memory and how
   much of the VM macOS compressed, and `logs/vm-stalls`. Uptime clock (no
   lines for a Mac asleep), nothing for a look that came late (App Nap, QEMU
   stopped) or while the VM is not running. The app menu, `omacvm check` and,
   after 10 s or more for memory, a note in the VM (once per 30 minutes) say
   the same in their words. The watchdog says when a stall of its own was in
   a GPU run without the BQL.
2. **Keep the GPU thread off the Mac's video service.** Each decoder's
   VideoToolbox session is made, changed, made again and ended on the
   decoder's own serial queue, in order with its pictures; the codec is
   freed there after `Invalidate`. What the Mac decodes and encodes is asked
   once when QEMU starts, beside the GPU thread.
3. **Bound what a picture can hold up.** One time limit per decoded picture,
   250 ms (at least 4 times the slowest picture seen at normal pressure, at
   most 500 ms): given up by the poll, waited for that long at most, and the
   sync thread lets a fence go at its pictures' limit, marking them dropped
   so that they are never written into planes the guest may already use
   again. That video keeps its last picture while its decoder starts; the
   desktop goes on.
4. **The cause itself** is the Mac's memory: the app gives the VM's cold
   file cache back while macOS compresses it (ADR 0059).

## Not done (each waits for its evidence)

- No change to which calls hold the BQL: none held it long in any row.
  Surface creation and detach backing touch memory with the BQL (up to
  71 ms here); moved off it only if field notes show holds of 250 ms or more.
- Extra displays take the GPU lock on the AppKit thread with a plain wait;
  a bounded try only if a hang report or a two-display full-screen row shows
  the AppKit thread waiting there.
- The encoder's `VTCompressionSessionCreate` stays on the GPU thread until a
  VA-encode row shows 100 ms or more under pressure.
- No guest tuning: the stock kernel has no THP or MGLRU; khugepaged's
  `max_ptes_none` matters only on the opt-in THP kernel, after a measured row.
- A GPU thread of its own (ADR 0046 option 2): only if field notes show main
  loop stalls of 1 s or more outside the calls named above.

## Consequences

- A user report with a freeze now names its cause in qemu.log, with the
  numbers that tell whether the Mac or QEMU stood still.
- No new timer: the watchdog's own wakes, two stores per `hv_vcpu_run`.
- A video that starts while macOS is short of memory shows its first
  pictures late (given up after 250 ms each) instead of freezing the VM's
  whole display for the time the Mac's video service needs.
