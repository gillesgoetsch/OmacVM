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
   qemu.log line per stall of 1 s or more, and `logs/vm-stalls`. A vCPU
   blocked in macOS's kernel is put down to memory only when the Mac was
   paging then (from the second look before the stall to its end: the
   compressor and swap moving 16 MB/s or more, 1 MB swapped, or pressure warn
   or critical; a healthy idle MacBook Air moves about 0.03 MB/s, the
   swapping mini about 4 GB/s); otherwise the line says only "blocked in
   macOS's kernel" (another macOS version may block a vCPU there for other
   reasons) and the VM gets no note. Uptime clock (no lines for a Mac asleep),
   nothing for a look that came late (App Nap, QEMU stopped; a line says the
   watchdog woke late, once per 10 minutes) or while the VM is not running.
   No timer of its own, so short stalls can be missed: in macOS's kernel
   under about 2.25 s (3.25 s for a vCPU that ran under 10 % of a core before:
   its start is dated late, up to 2.1 s short), without a Mac core under
   about 4 s (a 20 000-stall simulation). The watchdog says when a stall of
   its own was in a GPU run without the BQL, and counts its stalls with the
   BQL (`main_stalls`: the VM waited). Only the watchdog's thread writes the
   file; the main loop, which may hold the BQL, records in memory. The app
   menu, `omacvm check` and, after 10 s or more for memory, a note in the VM
   (once per 30 minutes) say the same in their words.
2. **Keep the GPU thread off the Mac's video service.** Each decoder's
   VideoToolbox session is made, changed, made again and ended on the
   decoder's own serial queue, in order with its pictures; the codec is
   freed there after `Invalidate`. What the Mac decodes and encodes is asked
   once when QEMU starts, beside the GPU thread; if the guest asks first, the
   GPU thread waits for the answer once, 10 s at most, then only looks.
3. **Bound what a picture can hold up.** One time limit per decoded picture,
   250 ms (`OMACVM_VIDEO_GIVEUP_MS`, at most 500): given up by the poll,
   waited for that long at most, and the sync thread lets a fence go at its
   pictures' limit, marking them dropped so that they are never written into
   planes the guest may already use again (a fence whose pictures are in but
   still being copied waits for the copy). That video keeps its last picture
   while its decoder starts. The fences are one timeline, so other apps'
   frames made after a late picture wait for it too, up to the 250 ms. Up to
   16 pictures per decoder are on their way (was 4), so a stream's first
   pictures wait for its session instead of being given up, and the Mac's
   video decoder service is connected once when QEMU starts (its first
   connection took 230-390 ms on the mini). A decoder's queue holds 64
   pictures not handed over yet: a start of more than about 1 s at 60 fps
   fills it, and the pictures past it are refused (errors until the next key
   frame). Calibration (each stream's slowest picture, END_FRAME to picture
   in, its session's start included):
   - Mac mini M4, one call row at pressure warn (the mini swapped all day):
     212 streams, median 3.2 ms, p99 29 ms, max 47 ms; 0 given up.
   - MacBook Pro M1 Max (32 GB, macOS 27.0.1) at normal pressure: YouTube
     4K60 (VP9 3840x2160, 600 s) 26.7 ms; a 600 s WebRTC call 7.7 ms; a
     30 minute soak with a call load and a 4K60 clip 40.8 ms over 567
     streams; 0 given up in each.
   - The same M1 Max at pressure warn (a memory hog beside a 10 vCPU VM
     with a call load; 155-223 s of warn, critical 0-2 s): pictures were
     given up in 4 of 6 tries (3, 287, 258 and 144 "given up" lines), and
     the pictures that came in took up to 249.9 ms. So at warn the limit
     does cut pictures that would have come later.
   - None on an M4 Max or a MacBook Air.
4. **The cause itself** is the Mac's memory. The app gives the VM's cold
   file cache back while macOS compresses it (ADR 0059): on from 3.2.12
   (QEMU's free page reclaim, ADR 0062); 3.2.11 had it off.

## Not done (each waits for its evidence)

- No change to which calls hold the BQL. Surface creation and freeing and
  detach backing touch memory with the BQL: up to 71 ms in the probe's rows,
  but once 2.2 s in an idle row on the swapping mini (close() of the old
  display surface's memfd in `qemu_free_displaysurface`, the watchdog's line
  "with the BQL held"). That meets the gate of 250 ms or more in the lab:
  freeing a surface off the BQL is the first follow-up, a change of its own;
  until then `main_stalls` counts such holds.
- Extra displays take the GPU lock on the AppKit thread with a plain wait;
  a bounded try only if a hang report or a two-display full-screen row shows
  the AppKit thread waiting there.
- The encoder's `VTCompressionSessionCreate` stays on the GPU thread until a
  VA-encode row shows 100 ms or more under pressure.
- No guest tuning yet. The reported VM runs the memory-optimized kernel
  (`--thp-kernel`: THP and MGLRU; 2.0 GB of transparent huge pages in its
  guest on 2026-10-28), so khugepaged's `max_ptes_none` and MGLRU's settings
  can matter there; they change only after a measured row on that kernel.
- A GPU thread of its own (ADR 0046 option 2): only if field notes show main
  loop stalls of 1 s or more outside the calls named above.
- A live row for the memory cause. The "waiting for memory" line and the
  note in the VM have been shown only in tests (simulated stalls,
  `test-vcpu-stall.sh`, `vm-stalls.sh`): the M1 Max never held critical
  pressure for more than 2 s in 6 tries, and the mini's swap was full. Live,
  on the mini with its processors busy, two runs gave 7 and 11 "waited for a
  Mac core" lines (longest 5.8 s), each matching a pause the guest saw; one
  of the 11 was 1.9 s longer than the vCPU's no-CPU window as macOS counted
  it, within the guest's own pause.

## Consequences

- A user report with a freeze of more than a few seconds now names its cause
  in qemu.log, with the numbers that tell whether the Mac or QEMU stood
  still; shorter stalls can go unseen (the limits in 1).
- No new timer: the watchdog's own wakes (one `host_statistics64` and one
  sysctl each), two stores per `hv_vcpu_run`.
- A video that starts while macOS is short of memory shows its first
  pictures late (given up after 250 ms each), and other apps' frames wait up
  to those 250 ms, instead of the VM's whole display freezing for the time
  the Mac's video service needs.
