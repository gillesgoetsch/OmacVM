# 0037: No save-to-disk resume while the VM uses the Mac's GPU; a faster cold start instead

Status: accepted (`instant-resume`, 3.0.1). Built: the firmware's 5 s wait is gone
(hidden fallback `firmwareWait`). Not built: saving the VM on quit.

## Context

The user's list of everyday wishes has "instant resume": quit OmacVM.app,
start it again later, and be back where you were in a second or two, as a
laptop lid does. Today Quit presses the guest's power button
(`omacvm-cocoa-quit-powerdown.patch`) and the next start is a cold boot:
about 11-13 s from the window to the desktop.

QEMU can write a running VM to a file and load it again (`migrate` to
`file:`, or `savevm` on a qcow2 disk). In QEMU 11.1.1, the version the app
ships, this works with HVF on Apple Silicon: the CPU registers and the
virtual timer's offset go into the stream, and the GIC, NVMe disk, sound
card, virtio devices and the user network all save their state.

The GPU does not. Every OmacVM.app VM has `virtio-gpu-gl-pci` (OpenGL through
virgl, and Vulkan through Venus), and QEMU refuses to save such a VM:
"virgl is not yet migratable" (`hw/display/virtio-gpu-base.c`). That is not
an oversight. The guest's GPU state lives in the Mac's graphics driver:
virglrenderer's GL contexts, textures and shaders, IOSurfaces, Venus memory
in Metal heaps. None of it can be written to a file and read back into a
new process.

## Options

1. Save everything, GPU included. Not possible: the driver state cannot be
   serialised (above). Would need virglrenderer and Venus to rebuild every
   object from a record of the guest's commands: a research project.
2. Save without the GPU state and give the guest an empty GPU after the
   restore. The guest's Mesa and Hyprland still hold handles to GL contexts
   and buffers that no longer exist. Linux's virtio-gpu driver has no way to
   tell user space "the GPU was lost", and neither Mesa's virgl driver nor
   Hyprland recovers from it: the compositor dies or hangs. Worse than a cold
   boot (the session is lost anyway, and a hung VM breaks our rule "never a
   hung VM").
3. Hibernate inside Linux (suspend to disk). Same GPU problem: the new QEMU
   has an empty GPU. Also needs swap as big as the VM's memory.
4. Keep the VM in memory, paused, when its window closes (QMP `stop`, the
   path the Mac's sleep already uses, `VMHostSleepController`), and continue
   it when the app opens it again. Instant and safe for the GPU, because
   the QEMU process and its GL contexts stay. But it does not survive
   quitting QEMU or restarting the Mac, and the VM's memory stays in use
   (macOS compresses or swaps it). It also changes what the close button
   does (today: shut down).
5. Make the cold start faster.

## Decision

No save-to-disk resume for now (options 1-3). Build option 5 now.
Option 4 is a proposal for the user (it changes what Close means).

Measured on the Mac mini M4 (macOS 27), 2026-10-06: a test VM (6 CPUs,
8 GB) with OmacVM.app's devices and window, QEMU from the 3.0.0 test build,
old and new start taking turns, the firmware variables reset before each:

| | before | `-boot menu=on,splash-time=0` |
|---|---|---|
| Linux starts (median of 5 and 6) | 8.0 s | 2.6 s |
| desktop: the boot logo gives way (median) | 14.2 s (13.4-17.4) | 8.65 s (8.1-8.9) |
| Linux itself (systemd-analyze) | 0.55 s kernel + 3.1 s user space | same |

One of the six old starts never reached Linux within a minute (without a
serial log in that run; the old path, not seen again).

The same VM without the GPU device (plain virtio-gpu, no window) saves and
restores fine: 2.2 GB of its 8 GB in use made a 2.2 GB file (8.8 GB
sparse), written in 14 s (34 s at QEMU's default speed limit); loading it
had the VM running again 1.7-2.2 s after QEMU started, same boot, uptime
going on. With OmacVM.app's GPU device QEMU says "virgl is not yet
migratable" and saves nothing. So the GPU is the only thing in the way.

What the firmware did: edk2's boot manager waits `PcdPlatformBootTimeOut`
seconds for a key ("Start boot option" and a progress bar). ArmVirtQemu
keeps it in the `Timeout` variable, default 5. QEMU only passes its own
value with `-boot menu=on`, so the firmware waited 5 s on every start, hidden
under the boot logo. `-boot menu=on,splash-time=0` sets it to 0 and the
firmware boots at once. The value is written to the VM's own firmware
variables each start, so the fallback (`defaults write org.omacvm.app
firmwareWait -int 5`) brings the old wait back exactly.

The next 2 s are GRUB's menu (`GRUB_TIMEOUT=2`). It lists the btrfs
snapshots (grub-btrfs), the way back after a bad update, so it stays until
the user decides. In OmacVM.app the menu is under the boot logo, so only
someone who knows it is there can use it.

## Consequences

- Every start of an app VM is about 5.5 s shorter (14.2 to 8.7 s on the
  mini). Headless runs (image build, first boot: `app/scripts/vm-common.sh`)
  lose the same wait (they boot with it: the save test above ran headless;
  not timed).
- No firmware menu by key at start. Nobody could see it under the boot
  logo; `firmwareWait` brings it back.
- Instant resume stays open. Save and restore themselves are ready in
  QEMU (numbers above). What would make option 2 or 3 possible: a
  "GPU lost" path from the virtio-gpu driver through Mesa to Hyprland
  (upstream work in three projects), or virglrenderer/Venus state that can
  be rebuilt.
