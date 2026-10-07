# 0039: The app VM's disk stays NVMe, cache=writeback, discard=unmap

Status: accepted (`disk-speed`, 3.0.2). Measured, no change to the defaults.
virtio-blk with an iothread is faster but hung after pause and resume.

## Context

OmacVM.app gives the VM its disk as QEMU's emulated NVMe controller:
`-drive format=raw,cache=writeback,discard=unmap` + `-device nvme`. In the
VM, btrfs mounts with `discard=async` and `fstrim.timer` runs weekly.

On macOS, QEMU's raw file code (block/file-posix.c, QEMU 11.1.1):

- `aio=threads` is the only choice (native and io_uring are Linux-only).
- A guest flush becomes `fdatasync()`/`fsync()`, not `F_FULLFSYNC`: about
  70 µs, so flushes are cheap with `cache=writeback`.
- Discard becomes `fcntl(F_PUNCHHOLE)`: APFS frees the space, 4 KiB at a time.
- Write-zeroes has no macOS path (ENOTSUP), so QEMU writes real zeros:
  `detect-zeroes=unmap` cannot make holes.

## Measured

`src/bench/disk-speed.sh` on the Mac mini M4 (16 GB, internal SSD), a clone
of a real app VM (6 vCPUs, 6 GB), one 8 GiB sparse test disk per option in
the same boot, fio with direct I/O on the raw disk, median of 3:

| option | 4k read QD32 IOPS | 4k read QD1 µs | 4k write QD32 IOPS | 4k write+fsync QD1 IOPS | seq write MB/s | seq read MB/s |
|---|---|---|---|---|---|---|
| **NVMe, writeback (kept)** | **200k** | **23.1** | **154k** | **13.9k** | 6995 | 1704 |
| NVMe, cache=none | 233k | 23.1 | 45k | 13.3k | 1823 | 1858 |
| virtio-blk, writeback, no iothread (2 runs) | 151k | 24.4 | 141k | 15.7k | 7209 | 2495 |
| virtio-blk, writeback, iothread | 284k | 17.2 | 220k | 18.8k | 7456 | 2189 |
| virtio-blk, cache=none, iothread | 288k | 18.4 | 48k | 17.9k | 1990 | 2879 |

One run each: NVMe with `ioeventfd=on` 193k / 28.3 µs / 156k / 12.6k (no
gain); NVMe with `cache=unsafe` (flushes ignored, reference only) 205k /
24.4 / 159k / 17.1k; NVMe on the mini's external Thunderbolt SSD 197k /
24.5 / 166k / 10.2k.

Everyday work on btrfs (the VM's own mount options) was the same on NVMe and
virtio-blk + iothread: git clone of git.git 12.3 s vs 12.2 s, two checkouts
0.35 s, pacman installing `base` (136 packages from a local cache) 7.2 s vs
7.3 s. At these speeds they wait on the CPU, not the disk. Boot to SSH:
13 s NVMe, 14 s virtio-blk.

Space on the Mac, the same on both buses: 2 GiB written took 2052 MiB;
deleted, btrfs' `discard=async` gave it back within 60 s (5 MiB left);
`fstrim` and `blkdiscard` left 0. 1 GiB of zeros written to the raw disk
took 1024 MiB with or without `detect-zeroes=unmap`.

## The soak that stopped virtio-blk

`disk-speed.sh soak`: 5-10 minutes of verified random I/O on the system disk
(fio randrw 4k-64k, queue depth 16, crc32c verify), the VM paused and resumed
over QMP every 30 s (as the app does when the Mac sleeps), fstrim every
2 minutes, then a reboot and a btrfs scrub.

| system disk | pause/resume | result |
|---|---|---|
| virtio-blk + iothread | yes | **hung twice** (10-min and 5-min runs): after ~4 minutes the VM's I/O stopped for good ("blocked in I/O wait > 122 s" for fio, btrfs, journald); QEMU still said "running" |
| virtio-blk + iothread | no | passed: 0 verify errors, 126 GB read / 119 GB written, scrub clean |
| NVMe (today) | yes | passed: 10 pauses, 0 verify errors, 109 GB read / 103 GB written, scrub clean |

So the hang comes with pausing a VM whose disk has its own I/O thread (QEMU
drains and restarts the iothread on every stop/cont). The app pauses VMs
for the Mac's sleep, so this would freeze a user's VM. Not shipped.

## Decision

- Keep NVMe, `cache=writeback,discard=unmap`, aio threads. No
  `detect-zeroes`. Keep btrfs `discard=async` and `fstrim.timer` in the VM.
- `cache=none`: no. It loses 70 % of random write speed; the Mac's file
  cache is memory macOS takes back when it needs it.
- virtio-blk + iothread: not until the pause hang is found and fixed in
  QEMU (rerun `disk-speed.sh soak` with `DS_SYS_BUS=virtio`). A VM boots on
  either bus (root by UUID, `CONFIG_VIRTIO_BLK=y`, GRUB's entry names the
  partition: tested both ways on a clone), so switching later needs no
  change in the VM.
