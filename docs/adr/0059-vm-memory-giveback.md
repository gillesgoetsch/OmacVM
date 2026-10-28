# 0059: The VM gives its cold file cache back while macOS compresses it

Status: accepted, built (`vm-memory-giveback`), always on for OmacVM.app VMs
(no setting). Notes, the spike and the review: work/tracks/vm-memory-giveback.md.

## Context

A 42 GB VM on a 64 GB Mac (3.2.6) showed a footprint of 51 GB in Activity
Monitor while the VM was "basically empty", and the Mac lagged. Inside the
VM: 10.3 GB used, 15.5 GB of file cache (12.7 GB of it inactive), 20.9 GB
free. On the Mac: 0.3 GB free, macOS compressing the VM from 13 to 20 GB in
10 minutes, memory pressure "normal" all along.

- Free page reporting works: memory Linux frees comes back to the Mac within
  10-20 s (2 GB filled and freed in the guest, on the Mac mini and on that Mac).
- Linux keeps every file it read in its page cache. To the Mac that is the
  VM's own memory: macOS can compress it, never drop it, although its own
  file cache already holds the same disk image (QEMU's disk runs
  cache=writeback). Re-reading 345 MB of Chrome's files after a drop took
  0.2 s from the Mac's file cache, against 0.02 s from the VM's.
- The app dropped the VM's cache only at macOS's memory warning (since 2.9).
  macOS's pressure level counts every page it can still compress as
  available (`kern.memorystatus_level` = free + active + inactive +
  speculative over RAM, on the mini at 16 GB): it warns only when the
  compressor is nearly full. On a 64 GB Mac that came 30 GB of compression
  too late, or never.
- Free guest memory in blocks under 256 KiB (`page_reporting_order` 6) is
  never reported: 12-20 % of the free memory after a browser session on the
  mini. Compaction makes it reportable but moves pages in use (12 s of a
  guest core for 8 GB) and decompresses on the Mac what macOS compressed.

## Decision

- **The app decides when, on what the Mac sees**, in its existing 5 s look
  (GPUMemoryWatch): macOS is compressing the VM when QEMU's footprint less its
  resident size (`proc_pid_rusage`) is at least min(2 GB, a quarter of the
  Mac), has grown at least min(1 GB, an eighth of the Mac) above its lowest
  (since the start, or since 60 s after the last give-back), and macOS itself
  compressed at least 1 GB since then (`host_statistics64` compressions):
  graphics, which count in the footprint but not in the resident size, do
  not trigger it on a Mac with room. Rejected: the pressure level and
  `kern.memorystatus_level` (see above), free pages (always low on macOS),
  swap-outs (too late).
- **The VM decides how much**: `src/memory/guest/giveback.sh compressing`,
  which the app carries in its bundle and runs through the guest agent (so a
  VM needs no Update VM for it): `memory.reclaim` with `swappiness=0` on the
  root cgroup (file pages only, the oldest first) for Inactive(file) less
  min(1 GB, an eighth of the VM), in 1 GB steps 1 s apart (QEMU handles the
  reports under its main lock), at most 20 s. The newest part of the cold
  cache stays, so files read in the last minutes are not read again: with
  only 256 MB kept, Chrome's files read once 30 s before a give-back went,
  and its next start took 1.08 s instead of 0.66 s on the Mac mini (median
  of 3). The active cache, programs' memory and zram stay. A
  kernel without a cold-only way (no `memory.reclaim`, or `swappiness=`
  refused: before Linux 6.11) drops the whole cache instead, as the warning
  does. A balloon that does not report free pages: one line in qemu.log,
  then nothing more in that run.
- **How often**: one 10-minute gap for every give-back, the warning's drop
  included; 30 s when the agent did not answer. A give-back that returned
  under 256 MB (by the VM's own count; QEMU's footprint 60 s later only for
  the warning's drop, which gives no count: a VM that goes on reading files
  grows the footprint again in that minute) doubles the gap for this
  trigger, up to 2 hours: what macOS compresses then
  is the programs' own memory, and dropping a cache the VM just rebuilt
  would only cost. 1 GB or more puts it back to 10 minutes. The warning may
  follow a cold-only give-back after 2 minutes.
- **What shows**: two lines in qemu.log per give-back (when it asks, with
  what QEMU has outside its resident memory and what macOS compressed; 60 s
  after the answer, GB back, cache before and after, free memory in blocks
  too small to report, QEMU's footprint before and after),
  `logs/memory-giveback` (the last one, for `omacvm check`'s "VM memory"
  line; never a failure). No setting: it only acts while macOS compresses
  the VM, and the VM's memory setting is never changed.

## Not now

- Compaction: idle only, never while macOS compresses; needs a stall test
  and the Mac's real physical memory measured, not the footprint.
- `page_reporting_order` 3 (32 KiB blocks): 8x more reports under QEMU's main
  lock; CPU and power not measured.
- A give-back when the VM is idle (the review's S3): its threshold needs
  calibrating with the window in front at 120 Hz, which no test Mac had.

Each give-back line has `small_free_mb` (from `/proc/buddyinfo`), so field
numbers decide between compaction and a smaller reporting order.

## Routes

UTM runs QEMU too, but the app is not there to ask; Parallels and Fusion
keep every page the VM touched until it stops (their balloons do not report
free pages). Nothing changes on those routes.
