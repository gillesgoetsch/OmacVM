# 0062: Memory the VM gives back leaves the Mac (moved aside, advised MADV_FREE_REUSABLE on a worker thread)

Status: accepted, built (`vm-memory-reclaim`, QEMU patch
`qemu-hvf-free-page-reclaim-reusable.patch`, 3.2.12), always on for
OmacVM.app VMs; `OMACVM_RECLAIM_REUSABLE=0` is the old way. With it the app's
give-back while macOS compresses the VM (ADR 0059) runs. Notes, the spike and
the review: work/tracks/vm-memory-gap.md.

## Context

Linux in an OmacVM.app VM reports the memory it frees (virtio-balloon free
page reporting, blocks of 256 KiB and up). Since try-omarchy's
`qemu-hvf-free-page-reclaim.patch`, QEMU answers each report by removing the
range from the VM (`hv_vm_unmap`), mapping fresh memory at the same address
(`mmap(MAP_FIXED)`) and giving that to the VM (`hv_vm_map`). Darwin's
`MADV_DONTNEED` would keep what the guest wrote, so the replacement was the
way to give the pages back.

It gave them back only in the accounting. On XNU, unmapping part of an
anonymous object (`vm_map_delete`) only removes the page-table entries and
drops the entry's reference; the object keeps its pages until the whole
object goes. Guest RAM is a few objects of 128 MB, and the rest of each one
stays mapped, so the old pages stayed resident or compressed until QEMU quit:
not in QEMU's footprint (Activity Monitor), not free for the Mac.

- Host test (no VM): 2 GB touched, every other 4 MiB block replaced with
  `MAP_FIXED`: the footprint fell by 1 GB at once; the Mac got the 1 GB back
  only when the process unmapped everything.
- A 4 GB VM on the Mac mini after a browser session: of the 3.3 GB it had
  reported, 1.6 GB was still held at report time (88 % of it compressed),
  and stayed held.

The review of the spike asked for one thing first: `MADV_FREE_REUSABLE` acts on
a shared object only when it is copy-delay (`vm_map_reusable_pages`: one
reference, or a copy strategy that is not symmetric, no copy object, no
shadow). Guest RAM is shared with the hypervisor's map. The gate test
(`app/runtime/Tests/memory/test-reclaim.c`) answered it with a real
`hv_vm_map` on the Mac mini (macOS 27, M4) and the MacBook Air (macOS 27.0.1,
M2): `hv_vm_map` alone makes every entry of guest RAM true-shared with
two or more references (copy-delay), and after a report with the advice the
range's old pages are reusable or gone, compressed ones too (region 100 %
compressed first on the mini: 4847 compressed pages before, 0 after).
main's helper left all of them (4832 compressed + 16 resident).

## Options

1. **`MADV_FREE_REUSABLE` on the range, then the new backing, all under the
   main lock.** XNU drops the range's compressed copies at once and marks its
   resident pages clean and reusable: macOS takes them first and never
   compresses them. One call per block. Measured on the MacBook Air (M2, 4 GB
   VM, macOS compressing ~92 % of what the VM held): up to 21.5 ms per report
   under the main lock (main: 1.3 ms), and the per-vCPU probe saw the guest
   stand still for 107-160 ms during the give-back (main: no gap over 34 ms).
   Rejected.
2. **`MADV_ZERO`** (no reference rule): drops compressed copies, but zeroes
   resident pages in place; they stay resident until macOS compresses them
   (to almost nothing). Gate test: all 4848 pages still resident after.
   Kept as the fallback had option 1's advice not acted on shared memory;
   not needed.
3. **Move the old range aside, release it on a worker thread** (chosen):
   under the main lock only `mach_vm_remap` (one more mapping of the same
   pages, no page touched) before the new backing; a thread advises the
   aside range `MADV_FREE_REUSABLE` and unmaps it. Also lets the thread look
   again for pages macOS was compressing at that moment.
4. **Leave it**: every give-back, free page reporting's and the cold-cache
   give-back's (ADR 0059), is partly in the accounting only.

## Decision

Option 3, as a new patch after `qemu-hvf-free-page-reclaim.patch` and
`qemu-hvf-mapped-sections.patch` (both pinned and left as they are; the
second carries `hvf_report_free_pages`' old body as context). Under the main
lock: `hv_vm_unmap` (no vCPU reaches the range), `mach_vm_remap` aside,
`mmap(MAP_FIXED)`, `hv_vm_map`. The worker ("omacvm-reclaim", utility QoS)
takes the ranges in order: `madvise(MADV_FREE_REUSABLE)`, a look at what the
Mac still holds of it (`mach_vm_page_range_query`), up to two more tries
20 ms apart for pages that were on their way into the compressor, `munmap`.
The reusable state stays on pages no guest mapping reaches again: the fresh
mapping takes the range before QEMU acknowledges the report, and the guest
touches none of these pages until then. The advice never runs under the
main lock: a range the worker has no room for (4096 ranges queued) or that
cannot move aside (`mach_vm_remap` fails) gets the new backing alone, as in
3.2.11, and qemu.log counts it with the reason. Only the main lock's holder
adds to the queue, and it looks for room before the move aside, so a range
moved aside always gets a place. `OMACVM_RECLAIM_REUSABLE=0` is the old way.

The app turns its give-back while macOS compresses the VM (ADR 0059) on only
with this fix: its QEMU's binary has `MemoryGiveBack.reclaimMarker`, the text
of the worker's first qemu.log line ("free page reclaim gives the pages back
to macOS"; `prepare-qemu-gpu-runtime.sh` refuses a runtime without it). That
says the fix is built in, not that it works on this Mac, and without it the
give-back would make QEMU's footprint smaller while the Mac kept the pages
(the harm that turned it off in 3.2.11). So the fix watches itself:

- A refused `madvise` stops it at once.
- An advice XNU skips returns no error (`vm_map_reusable_pages` passes over an
  object it does not take as copy-delay). The worker measures what each
  release found held (resident and not reusable, or compressed) and what it
  left. Once the releases found 64 MB held, half or more of it still held
  after them stops it. The advice leaves only pages macOS was compressing at
  that moment (0-2 % in the tests); no advice leaves all of them.

Stopped means: the replacement alone for the rest of the run (as 3.2.11), one
qemu.log line with the reason ("macOS keeps the pages the VM gives back"), and
"reclaim=keeps" with the reason in the file `OMACVM_RECLAIM_STATUS` names
(the app: `logs/memory-reclaim`, removed before each start). The app reads
that file every 5 s while its give-back is on and turns the give-back off for
the rest of the run ("off for the rest of this run" in qemu.log; `omacvm
check`'s "VM memory" row says it). macOS's warning still drops the VM's file
cache. Showing instead that the refusal cannot happen was not enough: the
skip needs no refusal, and what makes guest RAM copy-delay (the hypervisor's
map) is macOS's to change.

What it shows: `logs/qemu.log` gets a line an hour while the guest reports
and one at exit: reports, MB reported (what the guest gave QEMU), blocks, the
main lock's hold per report (the work that holds the lock: p99, never above
the longest, and longest), MB not moved aside and why (switched off, macOS
keeps the pages, the worker's queue full, no room to move them aside), and
what the worker released and how much of it is still on the Mac (held:
resident and not reusable, or compressed). `OMACVM_RECLAIM_CHECK=1` (tests
only) logs, per report, what its ranges held before the release and what
they left after.

## Consequences

- Pages macOS is compressing at the moment of the advice are skipped by XNU
  (busy, in the compressor's queue). The worker advises again 20 ms later.
  The gate test allows 5 % of a run's pages to stay that way.
- Reusable pages count as given back: macOS takes them first, without
  compressing, whenever it needs memory. On a Mac with room they stay
  resident until then, or until QEMU quits (MacBook Pro M1 Max, 32 GB: after
  each browser session with the fix 1.2-1.6 GB was still reusable and went
  at the quit, 1.7-1.8 GB with the memory-optimized kernel, 0.6-0.8 GB
  after an idle boot). "None stayed" in the rows below means none stayed
  held.
- While the worker falls behind (4096 ranges queued), new ranges get the
  old way: what the Mac held of them stays until QEMU quits. qemu.log says
  how much ("not moved aside ... the worker's queue was full").
- QEMU's footprint (Activity Monitor) does not change: those pages were never
  in it. The fix shows in what the Mac has free and in its compressor, and in
  the qemu.log lines. Activity Monitor's figure for the VM can also show more
  than the VM holds: once QEMU's own threads touched a guest page (disk,
  graphics, network) and macOS compressed it, it counts that page twice
  (4 GB VM on the mini after a browser session: 5.9 GB shown, 2.1 GB of it
  counted twice; the Mac got back 4.8 GB when QEMU was killed).
  Note (3.2.17, ADR 0066): compression is not what makes it count twice.
  macOS counts a page once per mapping that touched it, resident or
  compressed (a 12 GB VM with nothing compressed: 1.2 to 2.0 GB counted
  twice); QEMU's own-view sweep now drops that count every 5 minutes.
  A free page report and the sweep go by one rule for QEMU's private RAM
  (`omacvm_ram_private`).
- Main lock and guest stalls (Mac mini, 3 GB VM; of what the VM gave back,
  macOS had compressed 90-94 % of what it still held): the hold per report p99 0.85-0.98 ms,
  longest 1.12 ms (the old way: 0.39-0.68 ms, longest 0.68 ms); the
  per-vCPU probe's worst 10 s window 8 ms against 5 ms before the give-back
  (the old way's row: 26 against 12), no gap over 100 ms, no RCU or watchdog
  line. The advice under the lock (option 1) had held it 21.5 ms per report
  and stalled the guest 107-160 ms (MacBook Air). MacBook Pro M1 Max, 6 GB
  VM, a drop of 4092 MB of file cache macOS had compressed (3817 MB still
  held, all of it compressed): hold per report p99 2.11 ms, longest 2.21 ms
  (the old way, its cache dropped by macOS's warning while compressed: run
  p99 19.1 ms, longest 25.7 ms); the probe's worst 10 s window 19 ms in the
  drop against 27 ms in the minute before (18 ms before the fill), no gap
  over 100 ms, no RCU or watchdog line. Over whole runs (boot included) the
  M1 Max held it up to 7.9 ms per report with the fix and up to 8.0 ms the
  old way without compression: unmapping 100-128 MB of resident pages costs
  that either way.
- The worker now looks at every range before and after the advice
  (`mach_vm_page_range_query`, on its own thread at utility QoS; before only
  with `OMACVM_RECLAIM_CHECK=1`).
- Version mixes: the app's runtime only. Any guest works (any
  `page_reporting_order`; QEMU sees only blocks). An older app with this
  runtime does not exist (the runtime ships inside the app). UTM, Parallels
  and Fusion: unchanged.

## Not now

- Showing the VM's real memory next to Activity Monitor's figure (QEMU would
  read which guest pages the Mac holds; about 1 s for 47 GB).
- Small free blocks (under 256 KiB) the guest never reports; compaction.
- Graphics memory: nothing measured that grows and stays.
- The rest of the reported VM's gap (40 GB shown, about 22 GB used by Linux):
  needs that Mac's `logs/gpu-memory` and a `footprint` of its QEMU.

## Tests

- `app/runtime/Tests/memory/test-reclaim.sh`: build time on the patched
  source, CI on the patch (`src/tests/memory-reclaim.sh`, which also checks
  the pins, the order and the log lines). Guest RAM shared like QEMU's (a
  second map, or a real `hv_vm_map` where the Mac allows the test a VM),
  split by earlier reports, reports of 256 KiB to 4 MiB: no compressed page
  left, at most 5 % of resident ones (in flight), the pages around keep their
  data. main's helper and `OMACVM_RECLAIM_REUSABLE=0` must fail it.
  `--keeps`: the 64 MB rule on numbers; real pages the advice works on (no
  word); memory a child process shares since `fork` (XNU skips the advice
  there, `madvise` returns 0: the rule stops the fix, one line, the status
  file); a read-only range (`madvise` refuses: the same at once).
  `--overflow`: QEMU's queue and worker with the worker held back until
  4096 ranges wait. The next report, and later a range that cannot move
  aside, get the new backing alone: no `madvise` under the BQL (the test's
  stand-in sleeps 5 ms there, so a hold that misses it shows), counted with
  the reason; every report's hold covers all it did under the BQL; the
  worker then releases the 4097 ranges it was given; reported and
  neighbouring pages read right; the run's qemu.log line says "MB reported",
  what was not moved aside and why, and a p99 no higher than the longest
  hold. The behaviour before (the full queue advised in place under the BQL,
  outside the hold) fails 7 of its 13 rows.
- `desktop-tests`: the app reads QEMU's word (`MemoryGiveBack.qemuKeeps`) and
  the same session that gives back without it never does with it; the
  warning's drop stays. `src/tests/memory-giveback.sh`: the wiring, the
  marker in the patch and in prepare, check's row with `kept=1`.
- VM rows (`OMACVM_RECLAIM_CHECK=1`; the old way = `OMACVM_RECLAIM_REUSABLE=0`
  on the first build, whose check mapped each range once more before its
  replacement): Mac mini, 3 GB clone of M-chw (stock kernel, order 6):
  after a browser session the old way left 1345 of the 1346 MB the Mac
  still held of 2136 MB given back (92 % compressed), the fix 0 of 1478 MB
  (2414 MB given back, 90 % compressed); after a cache drop 1721 of 1721 MB
  against 0 of 1606 MB. MacBook Air, 4 GB clone of A-chw (order 9; first
  build, advice under the lock): the old way left 1209 of 1209 MB and 2302
  of 2303 MB, the advice 0 of 739 and 0 of 2193 MB. Guest data: 10 rounds
  of a 2 GiB per-page pattern with give-backs around it, 0 pages wrong
  (Air, first build). One run per row: the mini went to critical memory
  pressure with a third VM start (fseventsd held 23 GB there) and the Air
  went offline.
- M1 Max rows (MacBook Pro M1 Max, 32 GB, macOS 27.0.1; the build before
  the review's fixup, whose release path is the same: the fixup changed the
  full queue's path, the hold's timing and qemu.log's words;
  hidden 4 GB clone of a 3.2.0 test VM through the test app; the Mac had
  room, nothing compressed): 3 browser sessions per mode and kernel. With
  the fix every report's range left 0 MB held on the Mac: 1673-2160 MB
  held before (stock 7.2.11), 3253-3521 MB (memory-optimized 7.3, THP
  always, MGLRU), 2705 MB with `page_reporting_order` 9; the Mac had room,
  so those pages stayed resident as reusable (1.2-1.6 GB at each quit,
  1.7-1.8 GB memory-optimized). The
  old way has no check on this build (it moves nothing aside), so the
  Mac's counters around QEMU's quit say it: what came back beyond QEMU's
  footprint (the rise in free pages less the reusable pages freed), median
  of 3, -783 MB the old way against -1998 MB with the fix and -1022 MB for a
  VM with no session (stock); +51, -1696 and -1065 MB (memory-optimized).
  At the quit the Mac got 1161 MB more held pages back after the old way's
  sessions than after the fix's (41 % of the 2821 MB they reported), 1752
  MB with the memory-optimized kernel (38 % of 4557 MB). (The offset
  is below 0 also with no session: QEMU's footprint counts more than comes
  back at its quit.) Guest data, that runtime: 0 pages wrong in 10 rounds
  of 2 GiB, stock and memory-optimized kernel.
- Mac mini smoke on the fixup's build (c968f042; hidden 3 GB clone of
  M-chw, stock 7.2.11; boot, 1.2 GB of files read, the cache dropped, 600 MB
  filled and freed): the fix, 2238 MB reported, 1643 MB held before (99 %
  compressed), 0.0 MB left, hold per report at most 0.79 ms;
  `OMACVM_RECLAIM_REUSABLE=0`, 2458 MB reported, all of it "not moved aside
  (OMACVM_RECLAIM_REUSABLE=0)", hold up to 16.5 ms (one run each).
