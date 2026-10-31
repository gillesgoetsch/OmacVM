# Decision records

Short records of decisions with real trade-offs: context, options, decision,
consequences. Numbers start at 0010 (0001-0009 left free for older
decisions we may write down later). A record is not edited once accepted;
a new record replaces it and says so.

| No. | Decision | Status |
|---|---|---|
| [0010](0010-iosurface-present.md) | Show the guest's frames as IOSurfaces | accepted, built (`gpu-native`) |
| [0011](0011-async-fences.md) | Report GPU fences from a sync thread, not a timer | accepted, built (`gpu-native`) |
| [0012](0012-venus-in-process.md) | Venus render server as a thread of QEMU on macOS | accepted, built (`gpu-venus`) |
| [0013](0013-moltenvk-then-kosmickrisp.md) | MoltenVK now, KosmicKrisp on macOS 26 | accepted, MoltenVK built |
| [0014](0014-videotoolbox-in-virglrenderer.md) | VideoToolbox inside virglrenderer's video path | accepted, built (`video-decode`) |
| [0015](0015-one-window-per-display.md) | One window per Mac display | accepted, built (`app-displays`) |
| [0017](0017-fence-wait-short-sleeps.md) | Wait for GPU fences in short sleeps, not a spin | accepted, built (`gpu-native`) |
| [0018](0018-gpu-safe-mode.md) | A hidden GPU safe mode that is exactly the old path | accepted, built (`gpu-native`) |
| [0020](0020-frames-on-the-displays-refresh.md) | Show the guest's frames on the Mac display's refresh | accepted, built (`pacing-hdr`) |
| [0021](0021-colour-deep-colour-hdr.md) | Colour-tagged frames, deep colour and HDR | accepted, built (`pacing-hdr`), HDR off by default, only on EDR displays |
| [0022](0022-webgpu-and-opencl-on-venus.md) | WebGPU (Firefox, Chromium launcher) and OpenCL (rusticl) on Venus | accepted, built (`webgpu-compute`) |
| [0023](0023-refresh-rate-follows-the-guest.md) | The refresh rate follows the guest (ProMotion) | accepted, built (`pacing-hdr`) |
| [0026](0026-fence-tests-off-the-render-threads-lock.md) | Fence tests stay off Apple GL's lock while the render thread works | accepted, sync-thread part in 2.9.1 |
| [0034](0034-gpu-memory-budget-for-runaway-vms.md) | The GPU memory budget stops a runaway VM, never a desktop; at critical pressure growth is judged, not each buffer (3.2.15) | accepted, built (`fractional-scale`), amended 3.2.15 |
| [0035](0035-graphics-setting.md) | A Graphics setting per VM: OpenGL, Vulkan or Automatic; KosmicKrisp in release builds | accepted, built (`vk300`, 3.0.0) |
| [0036](0036-sound-main-loop-qos.md) | Sound on a busy Mac: main loop at user-interactive QoS, no HDA catch-up | accepted, built (`audio-crackle`) |
| [0037](0037-no-instant-resume-yet.md) | No save-to-disk resume while the VM uses the Mac's GPU; a faster cold start instead | accepted, start part built (`instant-resume`) |
| [0038](0038-desktop-restarts-after-lost-gpu-context.md) | The desktop restarts by itself after a lost GPU context (once in 10 min, then the app asks); a lost Chrome or Chromium gets a new GPU process (3.2.15) | accepted, built (`gpu-auto-recovery`, 3.0.1), amended 3.2.15 |
| [0039](0039-system-disk-options.md) | The app VM's disk stays NVMe, writeback, discard (virtio-blk + iothread hangs after a pause) | accepted (`disk-speed`) |
| [0040](0040-x86-apps-box64.md) | x86_64 Linux apps through box64, built in the VM | accepted, built (`x86-apps`, 3.0.1) |
| [0041](0041-touch-id.md) | Touch ID in the VM: pam_exec asks the Bridge, the Mac answers yes or no | accepted (`touch-id`, 3.0.2) |
| [0042](0042-encoder-beside-the-main-loop.md) | Capture mode: the video encoder works beside QEMU's main loop, guest fences wait for its frames | accepted, built (`capture-perf`, 3.0.8) |
| [0043](0043-mac-ime.md) | The Mac's input methods in the VM: macOS composes, Fcitx5 inserts (#273) | accepted, built (`mac-ime`, 3.0.8, off by default) |
| [0044](0044-fullpanel.md) | Omanotch is the shared notch integration; FullPanel is OmacVM.app only, experimental (#339) | accepted, built (off by default) |
| [0045](0045-sound-own-thread.md) | The sound on its own real-time thread, not in QEMU's main loop | accepted, built (`audio`, 3.1.16) |
| [0046](0046-gpu-off-the-main-loop.md) | The VM's GPU work lets go of the BQL, then leaves the main loop | accepted, built (`gpu-thread`), off by default |
| [0047](0047-vulkan-windows-without-a-copy.md) | Vulkan windows at the display's rate (no Wayland commit timing), and without a CPU copy (IOSurface window buffers, GPU re-stride) | accepted; no copy built (`vulkan-zc`), off by default |
| [0048](0048-freed-space-back-to-the-mac.md) | What the VM frees goes back to the Mac; 2 update snapshots instead of omarchy-mac's 5, a trim at every full apply | accepted, built (`disk`, `disk-followup`) |
| [0049](0049-hdr-guest-tone-maps.md) | HDR and 10-bit colour: the guest tone-maps into the Mac's headroom, its 10-bit driver loaded only per start | accepted, built (`hdr`), off by default |
| [0050](0050-extra-brightness.md) | Extra brightness: QEMU draws the VM's frames up to 2x on an XDR display, live from the app's switch; it wins over HDR while on | accepted, built (`extraBrightness`), off by default |
| [0051](0051-partial-present.md) | Partial present: QEMU draws only the box the guest changed since a surface's last draw | accepted, built (`frame-path`), off by default |
| [0052](0052-lossless-window-surfaces.md) | The VM window's surfaces are lossless-compressed (8-bit; half float for HDR and Extra brightness): fewer bytes for QEMU's draw and WindowServer's composite | accepted, built (`window-path`, `hdr-surfaces`), on by default on macOS 27 |
| [0053](0053-disk-flush-barrier.md) | A guest disk flush is a write barrier on the Mac's drive (F_BARRIERFSYNC), so the VM's file system is safer at a power cut | accepted, built (`disk`, 3.2.1) |
| [0054](0054-pointer-on-its-own-layer.md) | The pointer on its own layer: virtio-gpu's cursor plane shown without hotspots, QEMU draws the image; direct scanout measured, not built | accepted, built (`guest-scanout`), off by default |
| [0055](0055-tiled-present.md) | Tiled present: only the changed tiles of a frame go to WindowServer | accepted, built (`window-draw`), off by default (experimental switch "Draw only what changed") |
| [0056](0056-frames-in-step.md) | Frames in step with the Mac: the guest's vblank timer follows a refresh grid QEMU gives (OmacVM's virtio-gpu command), the vblank a measured lead before each commit | replaced by 0057 (removed in 3.2.7) |
| [0057](0057-frames-in-step-removed.md) | Frames in step removed: no gain worth its cost (input a few ms sooner only while the screen moves, no power saved, our own guest driver patch) | accepted, built (`drop-vsync`, 3.2.7) |
| [0058](0058-now-playing.md) | AirPods and media controls: the launcher is the Mac's Now Playing app while the VM plays (own virtio port, the guest's MPRIS players through Gio) | accepted, built (`airpods-media`), on by default |
| [0059](0059-vm-memory-giveback.md) | The VM gives its cold file cache back while macOS compresses it (the app sees it in QEMU's footprint and macOS's compressions; memory.reclaim, file pages only) | accepted, built (`vm-memory-giveback`); off in 3.2.11, on from 3.2.12 (runs only with QEMU's free page reclaim fix, ADR 0062) |
| [0060](0060-vm-stalls.md) | When the VM stands still: a qemu.log line per vCPU stall (Mac memory, no core), VideoToolbox sessions on each decoder's queue, one time limit per decoded picture | accepted, built (`vm-stall`) |
| [0061](0061-video-surfaces-at-their-own-size.md) | Video surfaces at their own size: the guest's VA-API shim declares each surface's size (a NOP payload), the Mac's shaders sample the rounded planes at it; no copy | accepted, built (`video-edge`, 3.2.11), on by default |
| [0062](0062-free-page-reclaim.md) | Memory the VM gives back leaves the Mac: QEMU moves a reported range's old pages aside and a worker advises them `MADV_FREE_REUSABLE` (before, they stayed resident or compressed until QEMU quit) | accepted, built (`vm-memory-reclaim`), always on |
| [0063](0063-video-size-from-the-apps-import.md) | Videos at the size the app imports them: a glvnd EGL vendor library in front of Mesa's hands an app's video imports to the VA shim, which says the size for surfaces at the coded size (H.264 1080p: 1088 rows) | accepted, built (`h264-edge`, 3.2.12), on with the 3.2.11 app's marker; amended by 0064 |
| [0064](0064-ghostty-on-the-cpu.md) | Ghostty draws on Mesa's CPU renderer (llvmpipe): it needs OpenGL 4.3, the VM's GPU gives 4.1; the EGL vendor library sets `LIBGL_ALWAYS_SOFTWARE` for Ghostty's `eglInitialize` alone, its children keep the GPU (#598) | accepted, built (`issue-598`, 3.2.14), Ghostty only |
| [0065](0065-venus-checks-what-metal-aborts-on.md) | Venus checks what the Mac's Vulkan driver aborts on: image descriptions against the driver's own format answer, binds, layouts, views and samplers, before KosmicKrisp or MoltenVK (Metal) gets them; amends 0012 | accepted, built (`zink-abort`, 3.2.14), always on; amended in 3.2.15 (`venus-robust`: missing entry points, reached asserts, buffer binds) and 3.2.17 (`venus-624`: indices, counts, offsets and enums of commands, descriptors, render passes and pipelines; multiview views; command-buffer state, a SPIR-V scan, copy regions, attachment formats; `venus-624-c`: frees, submit counts, dedicated memory, zeroed replies, a thread budget, pass views, descriptor updates per binding) |

The whole chain: [../architecture/graphics.md](../architecture/graphics.md).
