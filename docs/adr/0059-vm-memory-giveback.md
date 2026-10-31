# 0059: The VM gives its cold file cache back while macOS compresses it

Status: accepted, built (`vm-memory-giveback`), no setting. The give-back
while macOS compresses the VM runs only with a QEMU that gives the pages back
to macOS (ADR 0062): on from 3.2.12, whose QEMU does. 3.2.11's QEMU did not,
so in 3.2.11 it was off and the warning's drop worked as in 3.2.10 (below,
"3.2.11: off until QEMU gives the pages back"). From 3.2.17 the VM also
compacts its free memory and gives back when it is idle (below, "3.2.17:
compaction, and a give-back when the VM is idle"). Notes, the spike and the
reviews: work/tracks/vm-memory-giveback.md, work/tracks/vm-memory-gap.md,
work/tracks/vm-memory.md. Sizes are binary (1 GB = 1024 MB), as the app,
Activity Monitor and `top` show them.

## Context

A 42 GB VM on a 64 GB Mac (3.2.6) showed a footprint of 51 GB in Activity
Monitor while the VM was "basically empty", and the Mac lagged. Inside the
VM: 10.3 GB used, 15.5 GB of file cache (12.7 GB of it inactive), 20.9 GB
free. On the Mac: 0.3 GB free, macOS compressing the VM from 13 to 20 GB in
10 minutes, memory pressure "normal" all along. What the VM used and cached
adds up to less than that footprint; this decision covers the cache (see
"What this does not explain").

- Free page reporting makes QEMU's footprint smaller: memory Linux frees
  leaves it within 10-20 s (2 GB filled and freed in the guest, on the Mac
  mini and on that Mac). Up to 3.2.11 that is the footprint, not memory back
  to the Mac (ADR 0062 fixes it in 3.2.12): QEMU's reclaim maps fresh memory
  over each reported block, and the pages
  macOS still held for the old block, compressed ones too, stay held outside
  the footprint (a host test: 1.0 of 1.0 GB stayed; on a MacBook Air, 4 GB
  VM, a give-back took the footprint from 6.7 to 5.7 GB while the compressor
  fell only from 2184 to 1845 MB).
- Linux keeps every file it read in its page cache. To the Mac that is the
  VM's own memory: macOS can compress it, never drop it, although its own
  file cache already holds the same disk image (QEMU's disk runs
  cache=writeback). Re-reading 345 MB of Chrome's files after a drop took
  0.2 s from the Mac's file cache, against 0.02 s from the VM's.
- The app dropped the VM's cache only at macOS's memory warning (since 2.9).
  macOS's pressure level counts every page it can still compress as
  available (`kern.memorystatus_level` = free + active + inactive +
  speculative over RAM, on the mini at 16 GB): it warns only when the
  compressor is nearly full. On a 64 GB Mac that would be tens of GB of
  compression later (an estimate from the mini's numbers, not measured on
  that Mac), or never.
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
  VM needs no Update VM for it): file cache not used lately, except the
  newest min(1 GB, an eighth of the VM). That is Linux's inactive file
  list. The memory-optimized kernel (`--thp-kernel`) sorts its cache by
  generation (MGLRU) instead: in the reported VM, which runs it, all file
  cache but shared memory counted as inactive (Active(file) 0 kB), so there
  the give-back asks for nearly all of it. It got less: on a MacBook Pro M1
  Max a 4 GB VM on that kernel (Inactive(file) 2457 of 2679 MB) gave back
  1.1 of 2.5 GB, the stock kernel 1.2 of 2.8 GB. The tool is `memory.reclaim` with
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
  line: how many this run and what the VM freed in the last one; never a
  failure). No
  setting: it only acts while macOS compresses the VM, and the VM's memory
  setting is never changed.

## 3.2.11: off until QEMU gives the pages back

(3.2.12 brings that QEMU, ADR 0062: the give-back runs. What follows is why
3.2.11 had it off, and the rule that stays.)

The review of the free page reclaim (work/tracks/vm-memory-gap.md) measured
what 3.2.11's QEMU does with the pages the VM gives back: it takes them out of
its footprint, and macOS keeps holding them (Mac mini, 3 GB VM: of the
given-back memory the Mac still held, 1345 of 1346 MB stayed held after a
browser session and 1721 of 1721 MB after a cache drop). A file the VM reads
again then takes new pages on the Mac. So with that QEMU this give-back makes
Activity Monitor's number smaller while the Mac holds as much or more, and on
the memory-optimized kernel it asks for nearly all of the VM's file cache (a
4 GB VM on the M1 Max gave back 1.1 of 2.5 GB with the fix, 3.2.12).

- The give-back while macOS compresses the VM runs only when the app's QEMU
  carries the fix (ADR 0062): its binary has the fix's text
  (`MemoryGiveBack.reclaimMarker`, read once per app run off the main thread,
  as for `qemu-virt-small-high-window.patch`), and `OMACVM_RECLAIM_REUSABLE`
  is not 0. Otherwise it never fires (`desktop-tests`).
- macOS's warning drops the VM's file cache as in 3.2.10: at most once per
  10 minutes.
- `logs/qemu.log` says at each start "VM memory: give-back while macOS
  compresses: on" or "off (this QEMU keeps given-back pages)"; `omacvm
  check`'s "VM memory" line says the same, and its numbers are what the VM
  freed and QEMU's footprint, not memory back to the Mac.
- The fix's patch must put the text into QEMU and
  `prepare-qemu-gpu-runtime.sh` must check for it; `src/tests/memory-giveback.sh`
  fails when the patch is there without both. 3.2.12: the reclaim worker's
  first qemu.log line has it, and the runtime build refuses a QEMU without it.
- The text says the fix is built in, not that it works on this Mac. From
  3.2.12, when QEMU finds macOS keeping the pages anyway (a refused advice, or
  half or more of 64 MB the Mac held still held after it), it stops the fix
  for the run and writes `logs/memory-reclaim` (`OMACVM_RECLAIM_STATUS`); the
  app reads it every 5 s and turns this give-back off for the rest of the run
  (qemu.log "off for the rest of this run"; `omacvm check` says the same).
  ADR 0062 says how.

## 3.2.17: compaction, and a give-back when the VM is idle

Free page reporting hands only free blocks of `page_reporting_order` (6:
256 KiB) and up to QEMU. Right after a browser closes or a cache drop, much
of what Linux freed sits in smaller blocks (the "5 h later" reading above
was 70 MB; right after Chrome closed it was 1191 MB in a 12 GB VM on the
MacBook Pro M1 Max and 1061-1190 MB in a 4 GB VM on the Mac mini), and that
stays on the Mac. One compaction then took the guest RAM the Mac held down
by 1068 MB (M1 Max, nothing compressed) and 893 MB (Mac mini, macOS
compressing: about 1049 MB less compressed and 156 MB more resident, so far
less than that in real memory); a cache drop alone gave back only 536 of its
1687 MB (work/tracks/vm-memory.md, the investigations of 2026-10-31).

- **Compaction** ends the idle give-back and follows the warning's drop
  (`giveback.sh`): one write to `/proc/sys/vm/compact_memory` when 256 MB or
  more is free in blocks under the reporting order and the VM does not wait
  for memory (PSI memory some avg10 0.10 or less). Compaction moves pages in
  use, so it runs under `timeout -s KILL` (at most 10 s; a fatal signal
  stops it in the kernel),
  the whole script stays under 25 s (the app waits 30 s), and `flock` keeps
  it to one run at a time (the VM goes on running it after the app stopped
  waiting; a second run answers `act=locked`). No PSI, no `compact_memory`,
  no `timeout` or `flock`: no compaction, the rest as before. Pages pinned
  for the GPU have extra references and are never moved.
- **Not while macOS compresses the VM.** Moving pages makes macOS decompress
  those it compressed. On the Mac mini (4 GB VM, macOS compressing, Chrome
  just closed) one compaction by hand joined 1082 -> 188 and 1047 -> 112 MB
  of small blocks in 0.33 s, and the Mac got 330-460 and 570-630 MB more
  free + reusable memory than in control windows around it, with no wait of
  10 ms or more in the VM's own probe; but one of the two windows had a
  "stall: the stall watchdog woke 1.2 s late" line, and the rule for this
  was none. So the give-back while macOS compresses stays cache only, and
  the idle give-back never runs while QEMU has min(2 GB, a quarter of the
  Mac) or more outside its resident memory (in the mini's quiet rows: 3.3 to
  4.9 GB in every 30 s sample).
- **Idle** (the review's S3): every 15 minutes at most, while macOS's
  pressure is normal, QEMU used at most a fifth of a core over the last
  minute (its CPU time from the 5 s look; idle VMs used 4-10 %, a 1080p60
  video at 5K 71-85 %), QEMU has under min(2 GB, a quarter of the Mac)
  outside its resident memory (above; graphics count there too, so on a
  small Mac a 5K desktop with a browser open waits until the browser
  closes), and no give-back ran in the last 10 minutes, the app runs
  `giveback.sh idle`: cold cache above the newest min(2 GB, a quarter of the
  VM), then the compaction. The VM answers `busy` when its memory PSI is
  over 0.10 or its io PSI over 1.00; the memory-optimized kernel (MGLRU on)
  counts nearly all its cache as inactive, so there idle leaves the cache
  and only compacts (`act=mglru`). It counts as cold-only (the warning may
  follow after 2 minutes). An idle step the agent did not answer is tried
  again in 15 minutes and never sets the shared retry, so the warning's drop
  is never held up. One that brought back under 256 MB (cache and the small
  blocks it joined, by the VM's count), or after which the VM read back half
  of what the last one gave (`workingset_refault_file`), doubles the gap, up
  to 2 hours; 1 GB or more puts it back to 15 minutes. `busy` or `locked`:
  not a give-back, again in 15 minutes. `OMACVM_GIVEBACK_IDLE=0` turns it
  off (tests).
- **After the warning's drop**: once macOS's pressure is normal again and
  the VM is quiet (as for idle), one compaction-only call (`giveback.sh
  compact`), not counted as a give-back; an idle give-back before then
  compacts too. Never at warn or critical: a warning forced through QEMU's
  level file does not show what moving pages costs at a real one. On the M1
  Max (Chrome open with the video, a warning forced for 15 s) the drop and
  the compaction after it (564 -> 104 MB in 0.5 s, before the quiet rule)
  took the Mac's hold of the VM's memory down by 655 MB against 319 MB for
  the drop alone, and the reusable pages up by 755 against 430 MB; the
  VM's worst wait was 32 ms in both, but its waits of 10 ms or more were
  49-61 per CPU in 150 s against 11-12, so it now waits for a quiet VM.
- **What shows**: qemu.log at each start "VM memory: idle give-back: on" or
  "off"; one line per idle give-back that ran ("the VM was idle: it gave back
  ... and compacted its free memory: X -> Y in blocks too small to give back
  (Z s); QEMU's footprint ... 60 s later"); one line for the compaction
  after the drop. `logs/memory-giveback` counts idle give-backs on their own
  (`idle=`, `idle_mb=`), so `omacvm check`'s "N times" stays the others'.
- **Measured** (hidden 4 GB test VMs at 5K, Chrome with 10 tabs and a
  1080p60 video for 150 s, then closed and left quiet for 20 minutes; 3.2.16
  against this change, the same QEMU; work/tracks/vm-memory.md, raw
  work/vm-memory/giveback-compact/raw):
  - MacBook Pro M1 Max (nothing compressed): the app's own idle step came
    15 minutes after the start (QEMU used 4-5 % of a core while quiet),
    compacted 1.2 GB -> 205 MB of small blocks in 0.6 s and cost about 1 s
    of QEMU's CPU. 20 minutes after the close the Mac held 2425 MB of the
    VM's memory against 3.2.16's 3445 MB (-1020 MB; Activity Monitor
    -1511 MB), and at quit it got back 3491 MB against 4535 MB (-1044 MB by
    the Mac's own counters).
  - The same Mac with the video playing: QEMU used 71-85 % of a core, so no
    idle step. Steps forced by hand during the video: the one that compacted
    (270 MB in 0.4 s) dropped 6 of 1523 frames in its 25 s window against
    1-2 without a step, the VM's worst wait 42 ms against 10-20 ms.
  - The same Mac, the step by hand right after Chrome closed, 3 times: it
    found 871-1118 MB in small blocks and joined 699-1016 MB of it in
    73-385 ms; the VM's worst wait in
    those 30 s windows 16-21 ms against 15-22 ms without a step; Chrome's
    cold start after it 245 ms (median of 3) against 265 ms; memory PSI 0.
    (The 4 GB VM's cache stayed under the keep: these steps only compacted.)
  - Mac mini, macOS compressing: QEMU had 3.3-4.9 GB outside its resident
    memory in every sample of the quiet row, so no idle step runs there and
    the VM behaves as with 3.2.16 (no compaction while macOS compresses). A
    build without that limit ran one there 20 minutes after the start:
    1.0 GB -> 290 MB of small blocks in 0.2 s, the Mac's hold of the VM's
    memory 2779 against 3631 MB 20 minutes after the close, but what it got
    back at quit only 290 MB less (3241 against 3531 MB): most of that memory
    was compressed and cost the Mac about a third of its size.
  - Not run: the 12 GB rows (a 4 GB VM is the test limit without an
    exception), a 30-minute browser and build session, idle watts (one step
    of about 1 s of CPU every 15 minutes at most; no exclusive Mac for a
    power window).

## What this does not explain

The reported VM (48 GB at that reading; Linux saw 46.9 GB), read again after
a restart and 5 hours of use: QEMU's
footprint 40 GB (top's MEM, what Activity Monitor shows; 25 GB resident,
10 GB compressed by macOS), while Linux used about 22 GB: programs 10.1 GB,
file cache 10.6 GB (2.4 GB of it shared memory, Inactive(file) 8.2 GB; the
VM runs the memory-optimized kernel: 2 GB of transparent huge pages, which
the stock kernel does not have). 24.7 GB was free, almost all in 4 MB
blocks. With QEMU's fix this decision asks for those 8.2 GB less the
newest 1 GB (3.2.11: off; from 3.2.12 on); how much it gets is not measured
on that VM (the 4 GB row above got 1.1 of 2.5 GB). Why
QEMU holds more than what Linux uses is not known yet (free pages reported
but still held, graphics, QEMU's own memory) and is looked into separately.

## Not now

- Compaction while macOS compresses the VM: two rows by hand gave 330-630
  MB of real memory, one of them with a 1.2 s stall line; a third row that
  tells that stall's cause would decide.
- `page_reporting_order` 2 or 3 (16 or 32 KiB blocks): after a compaction it
  added only 101 MB (M1 Max) and 146 MB (Mac mini) held, for about 20 times
  the reports, 1.2-1.4 s more of QEMU's CPU per burst and 18-26 thousand map
  entries.
- The idle give-back's threshold with the VM's window in front at 120 Hz:
  the rows ran hidden VMs only.

## Routes

UTM runs QEMU too, but the app is not there to ask; Parallels and Fusion
keep every page the VM touched until it stops (their balloons do not report
free pages). Nothing changes on those routes.
