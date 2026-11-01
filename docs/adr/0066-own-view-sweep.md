# 0066: Activity Monitor counts guest RAM once (QEMU sweeps its own view)

Status: accepted, built (`vm-memory` unit `dcount-sweep`, 3.2.17), on by
default; `OMACVM_DCOUNT_SWEEP=0` turns it off. Amended in 3.2.18 (unit
`sweep-safe`, [below](#amendment-3218-the-sweep-turns-itself-off-instead-of-stopping-qemu)):
a sweep that would not do what this ADR expects turns itself off or maps
back instead of stopping QEMU. Corrects the "counted twice
while macOS compresses" words of [0062](0062-free-page-reclaim.md) and #633.
Notes and raw rows: work/tracks/vm-memory.md ("dcount-sweep"),
work/vm-memory/dcount-sweep/raw.

## Context

Activity Monitor's Memory for the VM is QEMU's footprint (`phys_footprint`).
macOS charges a page to it once for every mapping that touched it, resident
or compressed: the guest's touches go through the hypervisor's map, QEMU's own
threads' (disk reads into guest RAM, network, graphics transfers) through
QEMU's mapping of the same memory. Both map the same VM objects (`hv_vm_map`
makes QEMU's entries true shared), so a page both touched is counted twice
and is one page on the Mac.

- Host test, no VM (Mac mini, macOS 27.0; `Tests/memory/test-dcount.sh`):
  QEMU writes 1 GB, a real vCPU reads it: footprint 2049 MB for 1024 MB the
  Mac holds. A compressed page keeps its second count after the guest pulls
  it back (investigation: 467 MB counted compressed with 0 MB of the region
  compressed).
- MacBook Pro M1 Max, 12 GB VM, nothing compressed: 1.2 to 2.0 GB of QEMU's
  footprint was this second count ("Untagged" in footprint(1), all of it in
  QEMU's own mapping of guest RAM), growing with the guest's disk cache (1368
  to 1985 MB in 25 minutes of browsing). At QMP quit the Mac got 3204 MB back
  for 4262 MB shown (idle) and 7222 MB for 8499 MB (Chrome).
- So #633's words ("macOS counts part of a compressed VM twice") were wrong:
  compression is not needed. The second count is no memory, but it is the
  number the user reads (over 20 GB for a 12 GB VM).

## Options

1. **Leave the number, explain it** (3.2.16): the words were wrong, and the
   number stays several GB above what the Mac holds.
2. **An estimate in `omacvm check`**: nothing on the Mac says which pages are
   counted twice without a task port; an estimator needs rows on many Macs.
3. **QEMU without its own mapping of guest RAM**: every device model reads
   and writes guest RAM through it.
4. **Drop QEMU's page table entries now and then (chosen)**: a remap of
   QEMU's view over itself (`mach_vm_remap`, copy=FALSE,
   `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE`) maps the same objects at the same
   offsets without QEMU's page table entries; their charges go with them. No
   page is touched, copied or moved; QEMU's next touch maps a page again
   (about 0.4 us per 16 KiB page).

## Decision

`qemu-hvf-own-view-sweep.patch` (accel/hvf/hvf-all.c, after the free page
reclaim of ADR 0062):

- Main RAM only (`current_machine->ram`), QEMU's private anonymous memory:
  `omacvm_ram_private()`, the rule free page reports now go by too. Never the
  Venus host memory window's blobs (`memory_region_init_ram_ptr`:
  `RAM_PREALLOC`), pflash, ROM, shared or file-backed memory, nor while dirty
  logging is on.
- One 128 MB chunk (XNU's anonymous object) at a time, under the BQL, 20 ms
  apart: a chunk never meets a free page report's replacement or its move
  aside, which run under the BQL too (the reclaim worker only advises and
  unmaps its own aside ranges). A pass a minute after the start, then every
  5 minutes; skipped while QEMU's footprint grew less than 64 MB since the
  last one, at most twice in a row: free page reports can shrink the
  footprint while QEMU's touches grow the second count (M1 Max rows: no
  pass for 4 minutes at a one-minute period, 289 MB counted twice again).
- Checked at run time, not by macOS version: before each remap every map
  entry of the chunk must share its object (3.2.17: `SM_TRUESHARED` or
  `SM_SHARED`; from 3.2.18 the share mode the trial measured, below), an
  object id, be readable and writable and not wired. A copy-on-write
  entry, or one with no object yet, would get memory of its own from the
  remap, and QEMU and the guest would no longer see the same page (a disk read
  would land where the guest cannot see it). Such a chunk stays as it is and
  is counted, with one qemu.log line. In 3.2.17's first pass QEMU read the
  chunk's objects and offsets again after each remap and stopped (abort) on a
  change; 3.2.18 checks every pass and maps the chunk back (amendment). A
  failed remap that left the view as it was stops the sweep for the run, one
  line.
- qemu.log: a start line, "own-view sweep: on" or "off" (`omacvm check`'s
  "Activity Monitor" row picks its words from it, so an omacvm beside an
  older app says the right thing); a line an hour from the sweep's own timer
  and one at exit: passes, passes skipped, chunks remapped, MB less in
  Activity Monitor, the main lock's hold per chunk (p99, longest), chunks
  left as they were, why it stopped. `OMACVM_DCOUNT_SWEEP=0` turns it off;
  seconds there set the time between passes, and
  `OMACVM_DCOUNT_SWEEP_CHECK=1` adds a line per pass (tests).

## Consequences

- Accounting only. The Mac gets no memory back; no text may say it does.
  After a pass, QEMU's footprint is the guest RAM the Mac holds (once), the
  graphics, QEMU itself and what QEMU touched since its last pass.
- A page only QEMU touched since the guest last did (a disk read the guest
  has not used yet) leaves the count until one of them touches it again; the
  Mac still holds it. A probe with a real `hv_vm_map` (raw/probe-qemu-only-hv.txt):
  128 MB only QEMU wrote, 128 MB both touched, 128 MB only the guest:
  footprint 514 MB for 384 MB held; after a remap 258 MB; after the guest
  read the first 128 MB, 386 MB.
- The app's give-back while macOS compresses (ADR 0059) reads `footprint -
  resident`: the stale compressed markers of QEMU's mapping leave it at each
  pass, so it now sees what macOS compressed of the VM once. In the mini's
  Chrome row it still fired as often (2 give-backs in the run, main and this
  patch; `taken` 4805 MB on main, 3736 MB with the sweep at the last one).
- A pass costs the main lock a few ms per chunk and QEMU's later touches a
  fault each: per chunk p99 7.90 ms, longest 8.30 ms on the compressing Mac
  mini (192 chunks), longest 1.74-3.66 ms on the M1 Max; the guests' vCPUs
  did not wake later for it (below).
- The second count can grow back between passes faster than the footprint:
  hence at most two skipped passes in a row.

## Tests and rows

- `app/runtime/Tests/memory/test-dcount.sh` (runtime build on the patched
  source; CI `src/tests/memory-dcount.sh` on the patch): no VM, guest RAM
  shared with a second mapping or a real `hv_vm_map` and vCPU. QEMU writes
  1 GB, the guest reads it: 2.00x held; after a clean pass 1.001x; main
  without the sweep stays 2.001x (the test fails there). Pass 1 runs while a
  thread preads and pwrites a file into and out of guest RAM (buffered and
  F_NOCACHE: 6 rounds, 0 bad) and with two free page reports between chunks
  (one chunk swept, one not), their moves aside released after the pass;
  every page right as the guest sees it, QEMU's writes seen by the guest and
  the guest's by QEMU, the replaced ranges too; an idle pass skipped; a
  copy-on-write chunk and one without an object left as they are; a failed
  remap stops the sweep; `--predicate`: only main RAM is swept, never the
  Venus window's blobs, pflash or ROM; `--diverge`: QEMU stops.
- VM rows, main 3.2.16 (the published build) against this patch, hidden
  4 GB test VMs (4 vCPUs, Chrome 156, KosmicKrisp), one pass a minute
  (`OMACVM_DCOUNT_SWEEP=60`), each row taken after the next pass; P =
  Activity Monitor, H = guest RAM the Mac holds (once), U = the second count
  (footprint(1)'s "Untagged"), graphics = IOAccelerator mapped + unmapped,
  heap = malloc; MB (work/vm-memory/dcount-sweep/raw/mini-table.md):

  | Mac mini M4, macOS 27.0, compressing | P main / sweep | H main / sweep | U main / sweep | P - H - graphics - heap, main / sweep |
  |---|---|---|---|---|
  | boot + 2 min | 4424 / 2505 | 2435 / 2014 | 1201 / 143 | 1229 / 168 |
  | 2.5 GB of /usr read from the disk | 6924 / 4539 | 4066 / 4073 | 2069 / 116 | 2098 / 143 |
  | 10 x 2 GiB pattern in the guest | 4050 / 2315 | 2071 / 1800 | 1190 / 162 | 1219 / 191 |
  | 5K Chrome, 10 tabs, WebGL, 1080p video | 8073 / 6368 | 3894 / 3919 | 1751 / 159 | 1815 / 224 |
  | the same at the quit | 8267 / 6558 | 3958 / 3982 | 1768 / 187 | 1867 / 273 |

  Same both ways: the read files' sha256 from the cache and again from the
  disk after a pass, 300 MB written and read back, 10 x 2 GiB pattern (0
  wrong units); free page reporting 0.0 MB left on the Mac, no "macOS keeps
  the pages"; vkcube on Venus, the WebGL tab (0 contexts lost) and the
  1080p video (293 of 17317 frames dropped, main 319 of 17368); 0 GPU
  faults. A per-vCPU probe (5 ms sleeps on each vCPU, 150 s, during the
  pattern rows): p99 2.58 ms late on every vCPU with 4 passes in the window,
  max 3.47-5.73 ms (main, no pass: p99 2.58-2.59, max 7.63-14.59 ms).
  At the quit the Mac got 4132 MB back for 6445 MB shown (main 4277 for
  8135): compressed pages count at full size in Activity Monitor.

  MacBook Pro M1 Max, macOS 27.0.1, nothing compressed (exit rows: QMP quit,
  the Mac's free + reusable before and after; CI jobs ran on the M1's
  runners during these takes, and the Mac's counters include them):

  | row | P main / first patch / this patch | U main / first / this | back - P main / first / this |
  |---|---|---|---|
  | idle, 3 min after the start | 4153 / 2985 / 2927 | 1334 / 164 / 117 | -1659 / +867 / +103 |
  | 5K Chrome, 3 min | 7353 / 5983 / 5775 | 1638 / 289 / 129 | -1389 / +167 / +2110 |

  The first version of this patch skipped passes while the footprint did not
  grow: only the pass a minute after the start had run before its rows, and
  U had grown back to 164 and 289 MB; that made the skip limit. With it
  ("this", each row right after a pass) U was 117 and 129 MB. With the sweep
  the Mac gets back more than Activity Monitor showed (+103 to +2110 MB):
  pages only QEMU touched since the pass are held and not counted (above).
  QEMU's CPU at idle with the default 5-minute period, 10 minutes each: 54.0
  s per hour on main, 57.2 s per hour with the sweep (no pass ran in the
  window: two looks, both skipped). Watts at idle were not measured under
  the bench lock.

## Amendment (3.2.18): the sweep turns itself off instead of stopping QEMU

Unit `sweep-safe` (work/tracks/arch-review-3217.md's follow-up and the
lane's architecture review; work/followups-3217/sweep-safe).

### Context

- 3.2.17 stopped QEMU (abort) when its first pass found that a remap had
  changed QEMU's view, and its host test ran on macOS 27 only. OmacVM.app
  supports macOS 15 and newer. Nothing on the Mac promises that a remap
  with copy=FALSE keeps the same objects on every macOS, and a user cannot
  easily set `OMACVM_DCOUNT_SWEEP=0`.
- What XNU (`vm_map.c` with `vm_sanitize`, macOS 15 era or later) can do to
  such a remap:
  - `vm_map_region_walk` reads an object's reference count one low while a
    fault or page-out runs on it (`paging_in_progress`). QEMU's view and
    the hypervisor's map share each object (two references), so true
    shared memory can read `SM_PRIVATE` for a moment. 3.2.17's check after
    the remap refused that and stopped QEMU: possible on a busy Mac with
    nothing wrong.
  - A failed overwrite can leave the old entries unmapped (the delete's
    zap list is not put back), so "a failed remap left the view as it was"
    is not promised.
  - A kernel-wired entry (`vm_map_wire`: mlock, `-overcommit mem-lock`,
    physio on a raw disk device) makes the overwrite wait, without a time
    limit, with the map lock released and earlier entries already unlinked.
    No check can see kernel wiring. IOMemoryDescriptor and direct I/O
    (F_NOCACHE) wire pages, not entries, and do not block the remap.
  - With copy=FALSE XNU can shadow QEMU's own entry while it extracts it
    (copy strategy symmetric and needs-copy, shadowed, or not true shared
    and the object larger than the entry). `SM_TRUESHARED` (true share, copy
    delay) is safe; `SM_SHARED` is not promised to be.
  - Full region info looks at every page of the range; the short info has
    every field the sweep reads.

### Decision

- **A trial before the machine starts.** QEMU allocates 256 MB of scratch
  memory as it allocates RAM blocks and the hypervisor maps it as guest RAM
  (`hv_vm_map` at a 1 GB boundary past one of the machine's regions, 4 GB
  up at least, below the VM's IPA size, that no region or container
  overlaps: no vCPU or device reaches it; with no such IPA, or a failing
  `hv_vm_map`, a second mapping stands in). QEMU's view writes a word every
  MB of the first 128 MB, then a 4 MB piece gets new memory as a free page
  report leaves it (`hv_vm_unmap`, `mmap`, `hv_vm_map`, without the
  reclaim's call, worker or counters). The trial reads the share mode every
  map entry has (normally `SM_TRUESHARED`), makes a second mapping of the
  chunk, runs the real chunk steps on it (below), and then QEMU's view and
  the second mapping must read what was there and each other's writes.
  Anything else, or a trial past 3 s (on its own thread: a kernel that wired
  what the hypervisor maps would make the remap wait), and the sweep is off
  for the run: one start line, "own-view sweep: off (why): Activity Monitor
  counts the VM's pages QEMU touches twice", no timer, guest RAM never
  remapped, the scratch memory and its mappings gone (a trial past the
  limit removes them itself when it ends), the reclaim untouched. It takes
  about 1 ms. No trial when the sweep is off by `OMACVM_DCOUNT_SWEEP=0`, for
  RAM that is not QEMU's private memory, or with `-overcommit mem-lock`
  (off, with that reason).
- **Each chunk**, under the BQL:
  1. its map entries (short region info) must have the trial's share mode,
     an object, be readable and writable, not wired, inherited alike; else
     it stays as it is (a reference count read low then only skips it);
  2. a spare: one more mapping of the chunk (`mach_vm_remap`, copy=FALSE,
     anywhere, not inherited, as the reclaim's move aside). It touches no
     page and makes no page table entry; it holds one more reference per
     object for a moment. It must map the same objects and offsets, and
     QEMU's view must still do (no spare: the sweep stops; a view that
     changed: mapped back from the spare if the spare is right);
  3. the remap over itself (`VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE`, copy=FALSE);
  4. at once, with nothing between (no log, no footprint read), the entries
     read again: the same objects at the same offsets, readable and writable,
     not copy-on-write or empty. Any other share mode passes (the reference
     count read low). The objects are compared by `object_id` (a 32-bit hash in
     the short region info, so this says which object, not what it holds).
     This runs on every pass, not only the first;
  5. right: the spare goes. Changed (other memory, or a hole after a failed
     remap): QEMU's view is mapped back from the spare, over what is mapped
     there and into what is not (`VM_FLAGS_FIXED` alone: a delete across a
     hole raises EXC_GUARD), checked again, twice at most; the spare goes;
     the sweep stops for the run: "stopped for this run: mapped back after
     N us: the remap at +X MB changed QEMU's view (...); a disk, network or
     graphics transfer through that chunk in that time may have gone wrong".
     The mapped-back chunk is counted apart ("1 mapped back"). QEMU stops
     (abort) only when its view is still not the guest's memory after that:
     "could not be mapped back".
  QEMU never unmaps, maps, protects or deallocates its view itself.
- **What remains.** Disk and network threads and Venus' ring threads do not
  take the BQL. In the time between a remap that went wrong and the end of
  mapping back, a transfer through that chunk can read or write the wrong
  page: 44-118 us in the unit test for a chunk without page table entries,
  0.8-4.3 ms for one QEMU had touched all over, 2.2 ms in the M1 VM row
  (below), and on GitHub's macos-15 runner 340 us (`--diverge`) and 7469 us
  (`--hole`), past those ranges. A hole in that time faults such a thread,
  which ends QEMU; it does not only reach the wrong page. 3.2.17 had the same
  window before its abort. It only matters on a macOS that does what the
  trial did not show.
- **Precondition**: guest RAM is not wired by the kernel: no mlock, no
  `-overcommit mem-lock` (turns the sweep off) and no raw disk device for a
  VM disk (OmacVM.app's disks are files).
- **omacvm check** takes the why from "off (why):" or "stopped for this
  run: why" (printable ASCII, 120 characters at most): "QEMU's own-view
  sweep is off for this run: why". A 3.2.17 CLI with this QEMU still reads
  "off"/"stopped" as before (the plain words, no why); a new CLI with
  3.2.17's QEMU shows 3.2.17's reasons; with 3.2.16's QEMU (no line) it
  says nothing about the sweep. qemu.log is emptied at each start.
- **Test hook** (test mode only, `OMACVM_TEST_SKIP_DISPLAYS`; the app drops
  it in a release build): `OMACVM_TEST_SWEEP_DIVERGE=canary` gives the
  trial's view new memory after its remap, `=chunk` the same to guest RAM's
  third chunk (256 MB in) at its first remap (`=chunk:N`: at the remap after
  N of them, a later pass). It lives in the sweep's block
  (`omacvm_sweep_test_*`), which the unit test builds too.

### Tests and rows (3.2.18)

- `Tests/memory/test-dcount.sh` (and CI's `src/tests/memory-dcount.sh`, 40
  checks): the trial passes and leaves nothing behind; the rows of 3.2.17;
  with the hook, each with a second mapping and a real `hv_vm_map`:
  `--canary` (off with why, no remap of guest RAM, memory the same both
  ways), `--diverge` (the first pass), `--chunk` (a later pass, under
  pread/pwrite: mapped back, 0 bad rounds), `--spare` (stopped before that
  chunk's remap), `--hole` (mapped back around and into the hole, no remap
  over it), `--dip` (a chunk read private once: the pass goes on, no line),
  `--hang` (the trial past a 200 ms limit: off; its memory gone once it
  ends) and `--unmapped` (mapping back fails too: QEMU stops, the only abort
  left). The same cases against 3.2.17's sweep (6fddfa70, the hook around
  its calls): `--diverge`, `--hole` and `--dip` stop QEMU, `--chunk` leaves
  QEMU's view other memory than the guest's
  (work/followups-3217/sweep-safe/old-block-6fddfa70.txt).
- VM rows, MacBook Pro M1 Max (macOS 27.0.1), a hidden 4 GB test VM (4
  vCPUs, a clone updated to 3.2.17) with a test app of this branch,
  `OMACVM_DCOUNT_SWEEP=60`, one take (work/followups-3217/sweep-safe/raw/m1):
  - default: the one start line "on: ... (after a trial on scratch memory
    mapped by the hypervisor, 1.2 ms; ...)"; U 106 MB right after the first
    pass (3.2.17's release gate on the mini: 183-205 MB); 1477 MB after
    2.5 GB of reads, 114 MB after the next pass; a 300+ MB file's sha256 the
    same from the cache and from the disk after a pass, 300 MB written and
    read back the same; per chunk p99 and longest 7.85 ms; check: no "off".
  - `canary`: the one start line "off (a trial remap on scratch memory: the
    remap at +0 MB changed QEMU's view (...); mapped back)"; QMP says
    running; no pass; U 1305 MB after the boot and 1845 MB after the reads,
    as up to 3.2.16; check's row ends "QEMU's own-view sweep is off for this
    run: a trial remap on scratch memory: ...".
  - `chunk:1` (the second pass, the guest idle): "stopped for this run:
    mapped back after 2193 us: the remap at +256 MB changed QEMU's view
    (...)"; QMP says running; the file's sha256 the same before, from the
    cache and from the disk after; 300 MB written and read back the same;
    the run's line "34 chunks remapped, 1 mapped back", p99 and longest
    10.13 ms; check says why.
  - 0 host GPU faults, 0 tccd "Notifying" lines.
- GitHub's macos-15 (a manual "Run workflow", run 41254137128): memory-dcount
  40 of 40, test-dcount all ok on the second-mapping path (no hypervisor for
  the runner's processes: `--hv` skipped), activity-monitor ok.
- macOS 26.6.2 and 15.7.7 in headless VMs on the M1 (followups-3217/host,
  work/tracks/vm-memory.md "sweep on macOS 26 and 15"): this branch's
  test-dcount all ok on the second-mapping path (the trial passes, 1.1 and
  1.4 ms; the hook's cases as on macOS 27), and 3.2.17's sweep does not
  diverge there either. The real `hv_vm_map` rows need a Mac that runs
  macOS 26 or 15 itself (no nested virtualization on the M1): OWED.

