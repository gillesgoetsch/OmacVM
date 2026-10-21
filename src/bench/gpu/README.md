# GPU round trips

What one small GPU job costs from submit to "done", on the Mac and in a VM. One compute shader (64 threads add 1
to a buffer); each tool prints JSON lines with the median and p10/p90 in microseconds and checks the buffer.

| Tool | API | Modes |
|---|---|---|
| `vklaunch.c` | Vulkan (Venus in a VM; KosmicKrisp or MoltenVK on the Mac) | `sync` submit + wait, `poll` the fence polled, `submit` alone, `rec64` record 64 dispatches with barriers + submit + wait, `batch` 1000 dispatches in one submit (per dispatch) |
| `cllaunch.c` | OpenCL (rusticl on Zink in a VM, Apple's on the Mac) | `sync` kernel + clFinish, `batch` 1000 kernels + clFinish |
| `mtllaunch.m` | Metal (the Mac's own number) | `sync`, `rec64`, `batch` |

Build in the VM: `cc -O2 -o vklaunch vklaunch.c -lvulkan`, `cc -O2 -o cllaunch cllaunch.c -lOpenCL`
(packages gcc, vulkan-headers, opencl-headers, ocl-icd; OpenCL needs `RUSTICL_ENABLE=zink`).
On the Mac: `cc -O2 -fobjc-arc -o mtllaunch mtllaunch.m -framework Metal -framework Foundation`,
`cc -O2 -o cllaunch cllaunch.c -framework OpenCL`, and vklaunch against OmacVM.app's Vulkan loader
(`-I<Vulkan headers> .../OmacVM.app/Contents/Resources/runtime/lib/libvulkan.1.dylib`, then
`VK_DRIVER_FILES=.../runtime/share/vulkan/icd.d/kosmickrisp_mesa_icd.json`).
Usage: `vklaunch [N=2000] [device index]`, `cllaunch [N=2000] [platform index]`, `mtllaunch [N=2000]`.
Numbers from October 2026: [findings](../../../docs/notes/findings.md#gpu-work-in-an-omacvmapp-vm-where-the-time-goes-october-2026).
