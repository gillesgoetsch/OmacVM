# 0062: Memory the VM gives back leaves the Mac (MADV_FREE_REUSABLE before the new backing)

Status: accepted, built (`vm-memory-reclaim`, QEMU patch
`qemu-hvf-free-page-reclaim-reusable.patch`), always on for OmacVM.app VMs;
`OMACVM_RECLAIM_REUSABLE=0` is the old way. Notes, the spike and the review:
work/tracks/vm-memory-gap.md.

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
touches none of these pages until then. A full queue (4096 ranges)
releases in place; a range that cannot move aside is advised in place; a
refused `madvise` is logged once per run and the replacement goes on as
before. `OMACVM_RECLAIM_REUSABLE=0` is the old way.

What it shows: `logs/qemu.log` gets a line an hour while the guest reports
and one at exit (reports, MB back to the Mac, blocks, the main lock's hold per
report: p99 and longest, and what the releases left on the Mac).
`OMACVM_RECLAIM_CHECK=1` (tests only) logs, per report, what its ranges
held before the release and what they left after.

## Consequences

- Pages macOS is compressing at the moment of the advice are skipped by XNU
  (busy, in the compressor's queue). The worker advises again 20 ms later.
  The gate test allows 5 % of a run's pages to stay that way.
- QEMU's footprint (Activity Monitor) does not change: those pages were never
  in it. The fix shows in what the Mac has free and in its compressor, and in
  the qemu.log lines. Activity Monitor's figure for the VM can also show more
  than the VM holds: once QEMU's own threads touched a guest page (disk,
  graphics, network) and macOS compressed it, it counts that page twice
  (4 GB VM on the mini after a browser session: 5.9 GB shown, 2.1 GB of it
  counted twice; the Mac got back 4.8 GB when QEMU was killed).
- Main lock and guest stalls (Mac mini, 3 GB VM; of what the VM gave back,
  macOS had compressed 90-94 % of what it still held): the hold per report p99 0.85-0.98 ms,
  longest 1.12 ms (the old way: 0.39-0.68 ms, longest 0.68 ms); the
  per-vCPU probe's worst 10 s window 8 ms against 5 ms before the give-back
  (the old way's row: 26 against 12), no gap over 100 ms, no RCU or watchdog
  line. The advice under the lock (option 1) had held it 21.5 ms per report
  and stalled the guest 107-160 ms (MacBook Air).
- Version mixes: the app's runtime only. Any guest works (any
  `page_reporting_order`; QEMU sees only blocks). UTM, Parallels and Fusion:
  unchanged.

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
