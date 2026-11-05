# OmacVM docs

The background to OmacVM: how OmacVM.app works, how we measure speed, and what
we found along the way. To set OmacVM up, start with the
[README](../README.md); coding agents start with [AGENTS.md](../AGENTS.md).

| Page | What it is for |
|---|---|
| [guide.md](guide.md) | Build and use a VM, step by step: every build question, the feature defaults, what to do after the build, switching features, update, check |
| [features.md](features.md) | Every feature in detail, full screen and ⌃⌥ Esc, the macOS-native scroll momentum |
| [how-it-works.md](how-it-works.md) | How the Mac and the VM talk: Bridge, Gestures, camera, battery, Omanotch, displays, kernel, memory |
| [routes/app.md](routes/app.md) | Everything about OmacVM.app |
| [architecture/graphics.md](architecture/graphics.md) | OmacVM.app's graphics and display stack: the chain, threads, fences, memory, settings, security, tests; what is shipped, built or planned |
| [adr/](adr/) | Decision records for the graphics stack (IOSurface present, async fences, Venus, MoltenVK/KosmicKrisp, VideoToolbox, a window per display) |
| [usb.md](usb.md) | USB devices in OmacVM.app: which ones a VM can have, which stay with the Mac and why |
| [prebuilt.md](prebuilt.md) | Prebuilt VMs: using one, downloading one by hand, how they are made and checked, licences |
| [benchmarks/README.md](benchmarks/README.md) | How we benchmark OmacVM.app against the Mac, step by step, and the results so far |
| [troubleshooting.md](troubleshooting.md) | Common problems and what to do, then the non-obvious problems we hit, each as symptom, cause, fix and where in the code |
| [notes/findings.md](notes/findings.md) | Notes for developers: security reviews, measuring pitfalls, how the VM works inside |
| [experiments/kosmickrisp.md](experiments/kosmickrisp.md) | Vulkan in the VM on KosmicKrisp (macOS 26+): what it took, numbers, and what still blocks Zink GL 3+, ANGLE on Vulkan and WebGPU |
| [experiments/trackpad-scrolling.md](experiments/trackpad-scrolling.md) | How the macOS-native scroll momentum was tuned, over 29 rounds, with every measurement |
| [experiments/scroll-analysis/](experiments/scroll-analysis/) | The analysis scripts for the scroll momentum |
| [images/](images/) | The README's graphics (hand-written SVG with SMIL animation) and the demo video |

Parallels, UTM and VMware Fusion were retired in 3.4.0
([ADR 0071](adr/0071-omacvm-app-only.md)); their pages are in
[v3.3.0's docs](https://github.com/gillesgoetsch/OmacVM/tree/v3.3.0/docs).
