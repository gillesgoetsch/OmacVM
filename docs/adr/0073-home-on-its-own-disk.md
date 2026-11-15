# 0073: /home on its own disk, on xfs, for a VM built with a home disk

Status: proposed (`home-disk`). Off by default: only a VM built with a home
disk has it (the setup's Home disk row, `omacvm build --home-gb N`). Every
other VM starts and runs as before.

## Context

An OmacVM.app VM has one disk, disk.img: an emulated NVMe disk with one
btrfs (`@`, `@home`, `@log`; `compress=zstd:1,discard=async`). ADR 0039
measured the device and kept it; everyday work was the same on every device
option. What it did not measure is the file system.

The system needs btrfs: Omarchy's update snapshot and its GRUB entries
(snapper, config `root` only), the app's Disk › Change… (it reads btrfs'
superblock and cuts the last partition), `omacvm check` and Omarchy's
Factory Reset all rest on btrfs on `/`.

A home folder holds other work: databases, build trees, container and VM
images, caches. Files that change in place cost btrfs a copy on write each
time, and checksums and compression on every block.

## Measured

An M4 Pro Mac (internal SSD), OmacVM 3.4.5's QEMU 11.1.1 with the app's disk
options, a test VM with 8 vCPUs, Linux 7.3.3, both file systems fresh on the
same emulated NVMe disk, median of 3 boots. btrfs with the VM's mount options,
xfs with `noatime`:

| | btrfs, zstd:1 | xfs |
|---|---|---|
| 4k read, QD1, cold | 146 µs | 125 µs |
| 4k read, QD32, 4 jobs | 133k IOPS | 201k IOPS |
| 4k write + fsync, QD1 | 1,067/s | 2,870/s |
| pgbench, 8 clients | 3,635 tps (5,112 on a fresh btrfs) | 8,007 tps |
| a tree of 34k files (756 MB) written | 2.2 s fresh, 14.1 s on an aged btrfs | 0.62 s |
| a 4 GiB file after 20 s of random 4k overwrites | 885,849 extents, 0.75 GB/s buffered read | 2 extents, 6.5 GB/s |

git clone and cargo build wait on the CPU and took the same on both. On xfs
the device options again made no difference (NVMe, virtio-blk, an iothread,
direct I/O): the file system is what holds this work back, not QEMU's disk.

Not everything is faster on xfs. In the same runs big sequential I/O was a
little slower, and 4k random writes that nothing syncs were half as fast
(not looked into; work that needs its writes safe syncs them, the rows
above):

| | btrfs, zstd:1 | xfs |
|---|---|---|
| sequential read, 1 MiB, 8 jobs, direct | 6,638 MB/s | 6,207 MB/s |
| sequential write, 1 MiB, 8 jobs, direct, one sync at the end | 3,215 MB/s | 3,025 MB/s |
| 4 GiB read back cold through the page cache, 8 jobs | 6,721 MB/s | 5,506 MB/s |
| 4k random write, QD1, direct, no sync | 15,840 IOPS | 7,026 IOPS |

The same on a VM in daily use on that Mac, with a 50 GB home in about
490,000 files: one script in the home before and after its move from `@home`
to a home disk (2 runs before, 3 after), reads from the Mac's cache both
times:

| | btrfs `@home` | xfs home disk |
|---|---|---|
| 4k write + fsync, QD1 | 855 to 1,408/s | 1,626 to 2,034/s |
| pgbench, 8 clients | 3,443 to 3,508 tps | 6,010 to 6,318 tps |
| a tree of 74,809 files (1 GB) written | 4.7 to 5.2 s | 2.1 to 2.6 s |
| a 4 GiB file after 20 s of random 4k overwrites | 812,000 to 834,000 extents | 1 extent |

The home disk itself, in a VM built with `--home-gb 16` (the same Mac,
macOS 27.2.1, 6 vCPUs, 8 GB, Omarchy 4.5, Linux 7.2.11, a build of this
branch):

- **Interrupts**: each NVMe disk takes one MSI-X vector per vCPU and one
  more. The machine has 64 (GICv2m). Started by the app with 6 vCPUs, 31
  were in use, 7 of them the home disk's; both disks had 6 queues. With 14
  vCPUs that is 47.
- **Space back to the Mac**: 2 GiB written to `/home` took data.img from
  156 to 2204 MiB; deleted, it was back at 156 MiB within 5 s.
- **Larger**: data.img made 24 GB in the VM window; at the next start
  `systemd-growfs@home.service` grew xfs, and `df` said 24G.
- **What `discard` costs**, against the same file system mounted without
  it (3 rounds each, a tree of 94,243 files, 2.7 GB):

  | | `noatime,discard` | `noatime` |
  |---|---|---|
  | the tree deleted (`rm -rf`) | 2.2-2.6 s | 1.5-1.9 s |
  | `sync` after it | 0.83-0.88 s | 0.06 s |
  | 200 files of 4 KiB with fsync, right after | 0.49-0.63 s | 0.15-0.18 s |
  | the tree written again, with a sync | 3.7-5.8 s | 2.8-3.9 s |
  | 3000 synced 4 KiB writes, nothing deleted before | 1.3-1.9 s | 1.2-1.9 s |
  | 500 x (a file, fsync, delete) | 0.62-0.99 s | 0.56-0.87 s |

  Without discard, the 2.7 GB of the last deleted tree stayed on the Mac
  until an `fstrim`.

## Decision

- **Opt-in at the build**: the Home disk row of the app's setup (Off, or a
  size, under Disk), `omacvm build --home-gb N`, or its questions under
  Custom, where it asks for the disk's size. vm.env gets `HOME_GB=N`, and
  that line is what says a VM has a home disk: the app and its scripts
  attach `data.img` for it and count it as one of the VM's files (a start
  without it is refused, as without disk.img).
- **A build option like the disk's size, not a feature** in
  `src/features.tsv`: those switch on and off on a running VM
  (`omacvm enable`, the control centre, `off.sh`), and a home cannot move
  back and forth. Nothing of it is in `/etc/omacvm/env`.
- **Not with a prebuilt VM.** Its first boot makes the user's home from the
  image's template on the system disk, and the image has no `xfsprogs`: a
  home disk there needs new images and a first boot that makes the file
  system before the user. `--home-gb` with `--prebuilt` is refused, and the
  setup's row is off while Download is chosen.
- **On the Mac**: `data.img`, a sparse raw file beside disk.img, attached
  as a second NVMe disk with the system disk's options
  (`cache=writeback,discard=unmap`, ADR 0039; the flush barrier of ADR 0053
  covers every raw file), serial `omacvm-home`, no boot index. It is the
  last disk on QEMU's command line, after the devices every VM has, so a VM
  that gets one later keeps its other devices where they were.
- **In the VM**: xfs on the whole disk (no partition table: growing is one
  step), label `omacvm-home`, made by `src/vm/base-install.sh` before the
  user's home is created. No `@home`. fstab:
  `LABEL=omacvm-home /home xfs noatime,discard,x-systemd.growfs 0 0`.
- **`discard`**, not only the weekly trim: what is deleted in the home
  goes back to the Mac within seconds, as btrfs' `discard=async` gives it
  back from disk.img within about two minutes (ADR 0048). Without it a
  home would hold every deleted file on the Mac for up to a week. It costs
  in the seconds after a large delete (table above) and nothing in steady
  work. `fstrim.timer` and the trim at Update VM cover it as they cover
  disk.img (`fstrim.service` trims every file system in fstab).
- **Larger only**: Home disk › Change… in the VM window makes data.img
  longer (the VM off) and `HOME_GB` follows; systemd grows xfs when it
  mounts it (`x-systemd.growfs`), so nothing has to run or be remembered on
  the Mac. xfs cannot shrink, and the row says so.
- **The first boots find the root by PARTUUID.** Linux numbers two NVMe
  disks in the order they answer, another one at each start (nvme0n1 was
  the system disk in the installer and the home disk at the next boot).
  Until `omacvm apply` gives the kernel its initramfs (root by UUID), GRUB
  names the root for the kernel itself, by today's device name; with a home
  disk base-install.sh sets `GRUB_DISABLE_LINUX_PARTUUID=false`. Nothing in
  OmacVM reads a disk by its name.
- **`omacvm check`** has a "home disk" line for such a VM: /home is on that
  disk, on xfs, reads, and is mounted with discard.
- **An existing VM** gets nothing by itself. Moving a home is a copy of a
  person's files while nobody uses them; the steps by hand are in
  [the app's page](../routes/app.md#home-disk-off-by-default).

## What it leaves alone

- **Update snapshots**: snapper's only config is `root`, and `@home` was
  never part of a snapshot. Nothing is lost.
- **Not all on xfs**: the disk's size, `omacvm check`, Factory Reset and the
  update snapshot with its GRUB entry need btrfs on `/`.
- **Not a third partition on disk.img**: the app's resize takes the last
  partition for the btrfs root.
- **Not xfs in a file on the btrfs** (a loop device with direct I/O; one
  boot of the test VM above): 741 synced 4k writes a second and 5,808 tps
  in pgbench, under btrfs itself on the first and well under xfs on a disk
  of its own.
- **Not btrfs without copy on write for the home** (`chattr +C`; median of
  3 boots): the rewritten file stays in 1 extent and pgbench does 5,343
  tps, but synced 4k writes stay at 1,583 a second, and it holds only for
  files made after the switch, without checksums.
- **Factory Reset**: an OmacVM VM on Omarchy 4.5 has no `@factory`, so
  Omarchy's reset changes nothing there (`omacvm check` says so). Where a VM
  has one, the reset empties `@home` and `@log` and puts the installed
  system back, whose fstab has no home disk: the files on data.img stay,
  unmounted. Deleting data.img is what erases them.
- **Copies of the VM folder** (a move to another drive, a copy to another
  Mac, Storage's sizes, Time Machine's exclusion) take the folder, so
  data.img goes with it. The backup of the move to Omarchy 4.5 clones
  disk.img only: a VM with a home disk is built on 4.5 and never gets that
  move.
