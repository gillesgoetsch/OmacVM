# SPIR-V corpus for Venus' validation (#624)

Modules for `Tests/virgl/test-venus-spirv-validate.sh`, run on the CPU only (no Vulkan
driver, no GPU; STANDARDS 14b: invalid and hostile modules never reach a real driver).

`pass/`: real modules; each must pass vkr's scan, the interface limits, spirv-val for
both Mac drivers' targets and, with a `.lay` beside it, the pipeline checks.

| Prefix | Modules | From |
|---|---|---|
| `dxvk-` | 29 | DXVK 3.1.1's d3d9 and d3d11 shaders, taken out of its release DLLs |
| `dawn-` | 2 | Chromium's WebGPU (Dawn) compute shaders |
| `deqp-` | 36 | dEQP-VK shader data |
| `kit-` | 17 | the probe kit's glslc shaders |
| `vkcube-` | 3 | vkcube's two shaders |

A `NAME.vs.spv` is the vertex shader a `.lay` pipeline pairs a fragment shader with.

`refuse/`: modules that must be refused (by the scan, the interface limits, the type
cost, spirv-val, an exception or the step budget inside it, the element cap or the
pipeline checks), and whose check stays under the test's 512 MB footprint cap.

| Prefix | Modules | What |
|---|---|---|
| `fuzz-` | 156 | mutations of real modules that ended KosmicKrisp's or MoltenVK's process or hung them (M4, 2026-11-03) |
| `hand-` | 20 | hand-made crash cases (h-function-huge-array: legal, KosmicKrisp to 9 GB) |
| `tools-` | 32 | SPIRV-Tools' own invalid test modules that crashed a driver |
| `val-io-` | 12 | interface variables of 2^22..2^32 locations (5 found by valfuzz): spirv-val's location walk past 512 MB |
| `val-dag-`, `val-layout-` | 4 | type DAGs (spirv-val past 20 s) and nested struct arrays (1.8 s at depth 12, 4 times more a level) |
| `val-cfg-` | 2 | 400 nested loops, 1000 nested ifs: spirv-val's dominance walks 1.8 s and 6.5 s, stopped at 2 s |
| `throw-` | 2 | spirv-val ended the process (SIGSEGV in ValidateImage, abort in a decoration check) |
