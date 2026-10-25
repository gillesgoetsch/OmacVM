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
| [0034](0034-gpu-memory-budget-for-runaway-vms.md) | The GPU memory budget stops a runaway VM, never a desktop | accepted, built (`fractional-scale`) |
| [0035](0035-graphics-setting.md) | A Graphics setting per VM: OpenGL, Vulkan or Automatic; KosmicKrisp in release builds | accepted, built (`vk300`, 3.0.0) |
| [0036](0036-sound-main-loop-qos.md) | Sound on a busy Mac: main loop at user-interactive QoS, no HDA catch-up | accepted, built (`audio-crackle`) |
| [0037](0037-no-instant-resume-yet.md) | No save-to-disk resume while the VM uses the Mac's GPU; a faster cold start instead | accepted, start part built (`instant-resume`) |
| [0038](0038-desktop-restarts-after-lost-gpu-context.md) | The desktop restarts by itself after a lost GPU context (once in 10 min, then the app asks) | accepted, built (`gpu-auto-recovery`, 3.0.1) |
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
| [0052](0052-lossless-window-surfaces.md) | The VM window's 8-bit surfaces are lossless-compressed: fewer bytes for QEMU's draw and WindowServer's composite | accepted, built (`window-path`), on by default on macOS 27 |
| [0053](0053-disk-flush-barrier.md) | A guest disk flush is a write barrier on the Mac's drive (F_BARRIERFSYNC), so the VM's file system is safer at a power cut | accepted, built (`disk`, 3.2.1) |
| [0055](0055-vcpu-group.md) | The vCPU threads in a thread group of their own, so macOS sets their clock by their own load, not the window's | accepted, built (`vcpuGroup`), off by default |

The whole chain: [../architecture/graphics.md](../architecture/graphics.md).
