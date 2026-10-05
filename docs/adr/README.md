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
| [0023](0023-refresh-rate-follows-the-guest.md) | The refresh rate follows the guest (ProMotion) | accepted, built (`pacing-hdr`) |
| [0026](0026-fence-tests-off-the-render-threads-lock.md) | Fence tests stay off Apple GL's lock while the render thread works | accepted, built (`aquarium-perf`) |

The whole chain: [../architecture/graphics.md](../architecture/graphics.md).
