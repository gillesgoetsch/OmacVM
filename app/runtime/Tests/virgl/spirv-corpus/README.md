# SPIR-V corpus for Venus' validation (#624)

Modules for `Tests/virgl/test-venus-spirv-validate.sh`, run on the CPU only (no Vulkan
driver, no GPU; STANDARDS 14b: invalid and hostile modules never reach a real driver).

`pass/`: real modules; each must pass vkr's scan, the interface limits, spirv-val for
both Mac drivers' targets, the element and Workgroup byte caps and, with a `.lay` beside
it, the pipeline checks (on MoltenVK under a Vulkan 1.0 or 1.1 app, `mvk11`, those past
SPIR-V 1.4 must be refused by spirv-val instead). 90 modules:

| Prefix | Modules | From | Licence |
|---|---|---|---|
| `dxvk-` | 29 | DXVK 3.1.1's d3d9 and d3d11 shaders, taken out of its release DLLs | zlib (DXVK's LICENSE at v3.1.1) |
| `dawn-` | 2 | Chromium's WebGPU (Dawn) compute shaders | BSD-3-Clause (Dawn's LICENSE) |
| `deqp-` | 36 | dEQP-VK shader data | Apache-2.0 (VK-GL-CTS's LICENSE) |
| `kit-` | 15 | glslc test shaders of the probe kit (not from an app) | MIT (this repository) |
| `vkcube-` | 2 | vkcube's two shaders | Apache-2.0 (Vulkan-Tools' LICENSE.txt) |
| `zink-` | 6 | Zink's modules for glxgears in an OmacVM.app test VM (`ZINK_DEBUG=spirv`, KosmicKrisp, 2026-11-04) | MIT (Mesa's Zink) |

A `NAME.vs.spv` is the vertex shader a `.lay` pipeline pairs a fragment shader with: 16
more files, 6 different ones; the test runs them as real modules too (106 files in all).

vkd3d-proton's modules are not here: vkd3d-proton is LGPL-2.1, this repository MIT. Its
42 real modules (vkd3d-proton 3.1's release DLLs) and its two crash modules
(e-vkd3d-d3d12core-021, -041) went through the final checks on the CPU outside the repo
(kk, mvk and mvk11, also under AddressSanitizer): the 42 pass for kk and mvk, the two
are refused by spirv-val.

`refuse/`: modules that must be refused (by the scan, the interface limits, the type
cost, spirv-val, an exception or the step budget inside it, the element cap or the
pipeline checks), and whose check stays under the test's 512 MB footprint cap.

157 modules: 136 of the 138 crash modules (`fuzz-`, `hand-`, `tools-`; the other two are
vkd3d-proton's) and 21 that broke spirv-val itself (`val-`, `throw-`):

| Prefix | Modules | What | Licence |
|---|---|---|---|
| `fuzz-` | 98 | mutations of real modules that ended KosmicKrisp's or MoltenVK's process or hung them (M4, 2026-11-03) | the seed's (the next word of the name: `dxvk`, `dawn`, `kit`, `vkcube`, as above) |
| `hand-` | 20 | hand-made crash cases (h-function-huge-array: legal, KosmicKrisp to 9 GB) | MIT (this repository) |
| `tools-` | 18 | SPIRV-Tools' own invalid test modules that crashed a driver | Apache-2.0 (SPIRV-Tools' LICENSE at v2026.3) |
| `val-io-` | 12 | interface variables of 2^22..2^32 locations (5 found by valfuzz): spirv-val's location walk past 512 MB | MIT (this repository) |
| `val-dag-`, `val-layout-` | 4 | type DAGs (spirv-val past 20 s) and nested struct arrays (1.8 s at depth 12, 4 times more a level) | MIT (this repository) |
| `val-cfg-` | 2 | 400 nested loops, 1000 nested ifs: spirv-val's dominance walks 1.8 s and 6.5 s, stopped at 2 s | MIT (this repository) |
| `throw-` | 3 | spirv-val ended the process (SIGSEGV in ValidateImage, abort in a decoration check, SIGSEGV in a BuiltIn check on an untyped variable: valfuzz) | MIT (this repository) |
