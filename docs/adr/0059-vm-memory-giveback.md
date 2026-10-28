# 0059: The VM gives its cold file cache back while macOS compresses it

Status: accepted, built (`vm-memory-giveback`), always on for OmacVM.app VMs
(no setting). Notes, the spike and the review: work/tracks/vm-memory-giveback.md.

## Context

A 42 GB VM on a 64 GB Mac (3.2.6) showed a footprint of 51 GB in Activity
Monitor while the VM was "basically empty", and the Mac lagged. Inside the
VM: 10.3 GB used, 15.5 GB of file cache (12.7 GB of it inactive), 20.9 GB
free. On the Mac: 0.3 GB free, macOS compressing the VM from 13 to 20 GB in
10 minutes, memory pressure "normal" all along. What the VM used and cached
adds up to less than that footprint; this decision covers the cache (see
"What this does not explain").

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
  guest core for 8 GB) and decompresses on the Mac what macOS compressed. It
  does not explain the reported VM: read again later (below), almost all of
  its free memory was in 4 MB blocks, about 70 MB in blocks under 256 KiB.

## Decision

- **The app decides when, on what the Mac sees**, in its existing 5 s look
  (GPUMemoryWatch): macOS is compressing the VM when QEMU's footprint less its
  resident size (`proc_pid_rusage`) is at least min(2 GB, a quarter of the
  Mac), has grown at least min(1 GB, an eighth of the Mac) above its lowest
  (since the start, or since 60 s after the last give-back), and macOS itself
  compressed at least 1 GB since then (`host_statistics64` compressions).
  Graphics count in the footprint but not in the resident size: growing
  graphics trigger nothing as long as macOS compresses under 1 GB while they
  grow. macOS's count covers every process, so when it compresses 1 GB or
  more elsewhere meanwhile, growing graphics do trigger a give-back (a test
  shows both). Rejected: the pressure level and `kern.memorystatus_level`
  (see above), free pages (always low on macOS), swap-outs (too late).
- **The VM decides how much**: `src/memory/guest/giveback.sh compressing`,
  which the app carries in its bundle and runs through the guest agent (so a
  VM needs no Update VM for it): file cache read once and not again, except
  the newest min(1 GB, an eighth of the VM). That is Linux's inactive file
  list. The memory-optimized kernel (`--thp-kernel`) sorts its cache by
  generation (MGLRU) instead: in the reported VM, which runs it, all file
  cache but shared memory counted as inactive (Active(file) 0 kB), so there
  the give-back takes nearly all of it. The tool is `memory.reclaim` with
  `swappiness=0` on the root cgroup (file pages only, the oldest first), in
  1 GB steps 1 s apart, at most 20 s. Each step is one write, so the time
  limit and a refusal (EAGAIN: nothing more to take) stop it between steps.
  The newest part stays, so the files read last are not read again: with
  only 256 MB kept, Chrome's files read once 30 s before a give-back went,
  and its next start took 1.08 s instead of 0.66 s on the Mac mini (median
  of 3); with the newest eighth kept (738 MB of that 6 GB VM), 1.02 s with
  and without a give-back. These rows ran the stock kernel. The active
  cache, programs' memory and zram stay. A kernel without a cold-only way
  (no `memory.reclaim`, before Linux 5.19; or `swappiness=` refused with
  EINVAL, before Linux 6.11: both read in the kernel's source) drops the
  whole cache instead, as the warning does. A balloon that does not report
  free pages: one line in qemu.log, then nothing more in that run.
- **How Linux hands it to the Mac**: free page reporting, by itself, at most
  32 blocks per report, each report waiting for QEMU's answer
  (`virtballoon_free_page_report`). QEMU handles a report under its main
  lock: per block an unmap, a fresh mapping and a map
  (`qemu-hvf-free-page-reclaim.patch`). So one hold of the lock covers at
  most 32 blocks, however much the VM gives back. Mac mini, 6 GB VM, 3.3 GB
  given back in 4 s: the per-vCPU timers' worst 10 s window 9-13 ms against
  11-17 ms before, no RCU stall or watchdog line.
- **How often**: one 10-minute gap for every give-back, the warning's drop
  included. When the VM's agent does not answer, again in 30 s, then 1, 2, 4
  and 8 minutes, then every 10 minutes; qemu.log says the first miss and
  when it answers again, nothing in between. A give-back for "compressing"
  that returned under 256 MB (by the VM's own count; QEMU's footprint 60 s
  later only when the VM's answer could not be read: a VM that goes on
  reading files grows the footprint again in that minute) doubles the gap
  for "compressing", up to 2 hours: what macOS compresses then is the
  programs' own memory, and dropping a cache the VM just rebuilt would only
  cost. 1 GB or more puts it back to 10 minutes. The warning's drop leaves
  that gap as it is. The warning may follow a cold-only give-back after 2
  minutes.
- **What shows**: two lines in qemu.log per give-back (when it asks, with
  what QEMU has outside its resident memory and what macOS compressed; 60 s
  after the answer, GB back, cache before and after, free memory in blocks
  too small to report, QEMU's footprint before and after),
  `logs/memory-giveback` (the last one, for `omacvm check`'s "VM memory"
  line: how many this run and what the last one gave; never a failure). No
  setting: it only acts while macOS compresses the VM, and the VM's memory
  setting is never changed.

## What this does not explain

The reported VM, read again after a restart and 5 hours of use: QEMU's
footprint 40 GB (top's MEM, what Activity Monitor shows; 25 GB resident,
10 GB compressed by macOS), while Linux used about 22 GB: programs 10.1 GB,
file cache 10.6 GB (2.4 GB of it shared memory, Inactive(file) 8.2 GB; the
VM runs the memory-optimized kernel: 2 GB of transparent huge pages, which
the stock kernel does not have). 24.7 GB was free, almost all in 4 MB
blocks. This decision gives back those 8.2 GB less the newest 1 GB. Why
QEMU holds more than what Linux uses is not known yet (free pages reported
but still held, graphics, QEMU's own memory) and is looked into separately.

## Not now

- Compaction: idle only, never while macOS compresses; needs a stall test
  and the Mac's real physical memory measured, not the footprint.
- `page_reporting_order` 3 (32 KiB blocks): more and smaller blocks to
  report, each unmapped and mapped again under QEMU's main lock; CPU and
  power not measured.
- A give-back when the VM is idle (the review's S3): its threshold needs
  calibrating with the window in front at 120 Hz, which no test Mac had.

Each give-back line has `small_free_mb` (from `/proc/buddyinfo`), so field
numbers decide between compaction and a smaller reporting order. In the
reported VM they would gain little (about 70 MB in blocks under 256 KiB).

## Routes

UTM runs QEMU too, but the app is not there to ask; Parallels and Fusion
keep every page the VM touched until it stops (their balloons do not report
free pages). Nothing changes on those routes.
