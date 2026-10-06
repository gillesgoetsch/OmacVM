# 0035: A Graphics setting per VM: OpenGL, Vulkan or Automatic

Status: accepted, built (`vk300`, 3.0.0). Replaces the hidden `venus`
switch for users (it stays for development) and builds on 0013 (MoltenVK
now, KosmicKrisp on macOS 26) and 0022 (WebGPU and OpenCL on Venus).

## Context

Up to 2.9 Vulkan in an OmacVM.app VM was a hidden switch for every VM
(`defaults write org.omacvm.app venus`). Turned on in RC9 on a stock VM,
every Vulkan app failed: Arch Linux ARM's Mesa 26.2.3 does not size Venus
memory to the Mac's 16 KiB pages (`tracks/venus-user-vm.md`). KosmicKrisp
(Mesa's Vulkan on Metal 4, macOS 26+) beat MoltenVK on the Mac mini, but
was not in the app. The user asked for "Graphics: OpenGL / Vulkan /
Automatic" in the setup and the control centre, with Automatic set from
measurements per macOS version.

What Vulkan on means in OmacVM: the VM gets the Venus device next to virgl.
OpenGL keeps running on virgl either way: Zink (GL on Vulkan) gives only
GL 2.1 / ES 2.0 on MoltenVK and KosmicKrisp (no transform feedback,
no geometry shaders), too little for Omarchy's desktop. So the setting
decides whether Vulkan apps get the Mac's GPU, not how the desktop draws.

## Decision

- One setting per VM, the VM folder's `graphics` file: `opengl`, `vulkan`
  or `auto` (none = auto). The app reads it at each start
  (`Graphics.swift`), the Mac side of omacvm in `src/lib/graphics.sh`
  (same rules, `src/tests/graphics-setting.sh` checks both on 576 cases).
  Set in the app's setup and VM window, `omacvm graphics`, and the control
  centre (one more Bridge request: `{"action": "graphics", "graphics":
  "opengl"|"vulkan"|"auto"}`, app VMs only, a fixed argv).
- Automatic = OpenGL on every Mac in 3.0.0 (`Graphics.autoVulkan` /
  `GRAPHICS_AUTO_VULKAN` = off): the black desktop from Vulkan windows is
  fixed (the host no longer ends Hyprland's context on that import), but on
  macOS 26 and newer (KosmicKrisp) Vulkan windows still go through the slow
  CPU copy and the GPU path is not tested there yet. With it on: Vulkan on
  macOS 26 and newer when the app has KosmicKrisp, OpenGL otherwise. The
  numbers are in
  [benchmarks](../benchmarks/README.md#graphics-automatic-2026-10-05).
- No start gives Venus to a VM without a working Venus driver (the old one
  fails every Vulkan app with ERROR_OUT_OF_HOST_MEMORY): apply writes
  `venus-ready` when the VM's driver sizes memory to 16 KiB pages (Mesa >=
  26.2.4, or OmacVM's Mesa of the vulkan feature). With the setting giving
  Vulkan, apply (or `omacvm graphics` on a running VM) builds Mesa 26.2.4's
  `vulkan-virtio` ahead. Until then Vulkan starts with OpenGL and says
  "Vulkan (driver not built yet: runs on OpenGL until the next apply)".
  In the VM `omacvm-venus-driver.timer` checks again 90 s after boot (never
  in the boot's critical chain: no network-online.target, idle priority).
- The hidden `venus` switch of 2.9 is moved once at the app's first 3.0.0
  launch (Graphics Vulkan for each VM without its own choice) and removed.
- A guest can ask for Vulkan for itself through the control centre's Bridge
  job without a confirm on the Mac (as for feature jobs). That opens more of
  the host's GPU stack to the guest (Venus, and the black-desktop import
  above), so the job only takes the three values and app VMs.
- KosmicKrisp ships in release builds (`build-app.sh --release`,
  `package-release.sh` refuses an app without it). The runtime picks the
  driver per start: macOS < 26 MoltenVK without loading KosmicKrisp;
  macOS 26+ KosmicKrisp, falling back to MoltenVK (logged) when it does not
  load or has no device; `OMACVM_VULKAN_DRIVER` forces one.
- Venus' host memory window follows the memory plan (fractional-scale's
  design): Mac memory minus the VM's minus macOS's reserve (4/6/8 GB),
  a power of two from 1 to 32 GB. It is address space; allocations count
  against the GPU memory budget (`virgl-venus-memory-budget.patch`).

## Consequences

- With `autoVulkan` on, a VM that moves to macOS 26 (or gets an app with
  KosmicKrisp) turns Vulkan on by itself at its next start once its driver
  is there. In 3.0.0 nothing turns Vulkan on except the user.
- MoltenVK users who want Vulkan pick Vulkan; Automatic does not expose
  MoltenVK's gaps (no `VK_EXT_provoking_vertex`, no zero-initialised
  workgroup memory, five failing CTS cases) to everyone.
- The `vulkan-virtio` step goes once Arch Linux ARM ships a Mesa with both
  blob alignment (>= 26.2.4) and Venus' OPAQUE_FD semaphores (not upstream
  yet; OmacVM's build carries the patch so Chrome's WebGPU works with
  Graphics Vulkan, 3.0.1).
- KosmicKrisp needs Xcode 26 and Homebrew's LLVM and SPIR-V tools on the
  release Mac (`build-kosmickrisp.sh --check`); CI builds without it.
