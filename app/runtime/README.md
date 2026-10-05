# Runtime

QEMU for OmacVM, built from source. The build scripts and patches come from
[try-omarchy](https://github.com/omacom/try-omarchy) (MIT, `LICENSE.try-omarchy`),
commit 82927e9. Changes here:

- scratch files go to `.build/tmp` instead of `/private/tmp`
- `patches/omacvm-cocoa-identity.patch`: the app name and icon come from the
  launcher (`OMACVM_PRODUCT_NAME`, `OMACVM_ICON`)
- QEMU's edk2 UEFI firmware is kept in `.build/firmware`, so an installed
  system boots through GRUB
- `patches/virgl-texture-integer-samplers.patch`: shaders that read integer
  textures (`usampler2D`) compile on the Mac's OpenGL. Before, Apple's
  compiler refused them and the guest's GL context stopped for good: Chrome's
  GPU process hung (Basemark Web 3.0 at test 5). The build checks it with
  `Tests/virgl/test-integer-sampler-shader.c`, which compiles the generated
  GLSL with the Mac's OpenGL
- `patches/virgl-transfer-row-size.patch`: no texture transfer moves more
  bytes per row in GL than the guest's buffers hold. The YUYV plane format
  (R8G8_R8B8) moved twice as many, and its readback overflowed QEMU's heap:
  mpv's VA-API probe stopped the VM. That format is gone; the row check covers
  the others. Tested at build time by `Tests/virgl/test-transfer-row-size.c`

Build: `./build-qemu-gpu-runtime.sh` (about 70 seconds, needs only the Command
Line Tools). Output: `.build/qemu-gpu-runtime` and `.build/firmware`.

QEMU is GPL-2.0. Anyone who gets a built app must also be able to get this
source and the patches.
