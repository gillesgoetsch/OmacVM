# 0066: Activity Monitor counts guest RAM once (QEMU sweeps its own view)

Status: accepted, built (`vm-memory` unit `dcount-sweep`, 3.2.17), on by
default; `OMACVM_DCOUNT_SWEEP=0` turns it off. Corrects the "counted twice
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
  last one (an idle VM wakes nothing).
- Checked at run time, not by macOS version: before each remap every map
  entry of the chunk must share its object (`SM_TRUESHARED` or `SM_SHARED`,
  an object id), be readable and writable and not wired. A copy-on-write
  entry, or one with no object yet, would get memory of its own from the
  remap, and QEMU and the guest would no longer see the same page (a disk read
  would land where the guest cannot see it). Such a chunk stays as it is and
  is counted, with one qemu.log line. In the first pass QEMU reads the
  chunk's objects and offsets again after each remap; a change means that has
  happened anyway, so QEMU stops (abort) before it reads or writes there
  rather than run on with a view that is not the guest's memory. A failed
  remap that left the view as it was stops the sweep for the run, one line.
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
  pass, so it now sees what macOS compressed of the VM once (rows below).
- A pass costs the main lock a few ms per chunk (host test: longest
  4.16 ms for 128 MB) and QEMU's later touches a fault each.

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
- VM rows, main 3.2.16 against this patch: see work/tracks/vm-memory.md
  ("dcount-sweep") and the PR.
