# OmacVM docs

The background to OmacVM: how each route works, how we measure speed, and what
we found along the way. To set OmacVM up, start with the
[README](../README.md); coding agents start with [AGENTS.md](../AGENTS.md).

| Page | What it is for |
|---|---|
| [guide.md](guide.md) | Build and use a VM, step by step: every build question, the feature defaults, what to do after the build, switching features, update, check |
| [features.md](features.md) | Every feature in detail, full screen and ⌃⌥⌘ Esc, the macOS-native scroll momentum |
| [how-it-works.md](how-it-works.md) | How the Mac and the VM talk: Bridge, Gestures, camera, battery, Omanotch, displays, kernel, memory |
| [compare.md](compare.md) | The four apps side by side: the full table, benchmark numbers and how we measured |
| [routes/app.md](routes/app.md) | Everything about OmacVM.app |
| [routes/utm.md](routes/utm.md) | Everything about the UTM route: why UTM 5, what to keep in mind |
| [routes/vmware-fusion.md](routes/vmware-fusion.md) | Everything about the VMware Fusion route: what you need, what OmacVM does differently there, what works, fixes |
| [routes/parallels.md](routes/parallels.md) | Everything about the Parallels route: editions, the Cmd setting, what Parallels does itself |
| [prebuilt.md](prebuilt.md) | Prebuilt VMs: using one, downloading one by hand, how they are made and checked, licences |
| [benchmarks/README.md](benchmarks/README.md) | How we benchmark the routes against the Mac, step by step, and the results so far |
| [troubleshooting.md](troubleshooting.md) | Common problems and what to do, then the non-obvious problems we hit, each as symptom, cause, fix and where in the code |
| [notes/findings.md](notes/findings.md) | Notes for developers: security reviews, measuring pitfalls, how the VM apps work inside, the first Parallels vs UTM measurements |
| [experiments/vmware-fusion.md](experiments/vmware-fusion.md) | The plan and test log from building the Fusion route |
| [experiments/trackpad-scrolling.md](experiments/trackpad-scrolling.md) | How the macOS-native scroll momentum was tuned, over 29 rounds, with every measurement |
| [experiments/scroll-analysis/](experiments/scroll-analysis/) | The analysis scripts for the scroll momentum |
| [images/](images/) | The README's graphics (hand-written SVG with SMIL animation) and the demo video |

The settings, failure modes and dead ends of Parallels and UTM are in
[AGENTS.md](../AGENTS.md) (sections 4, 7 and 8).

`parallels-shortcuts.svg` stays in this folder, not in `images/`: `omacvm`
opens it from there (`src/mac/parallels-system-shortcuts.sh`).
