#!/bin/bash
# Guest side, as root in the VM: build Mesa 26.2.3 (virgl only) with OmacVM's virgl
# patches into /opt/omacvm-mesa. Not installed over the system Mesa: apps use it
# with LD_LIBRARY_PATH=/opt/omacvm-mesa/lib GBM_BACKENDS_PATH=/opt/omacvm-mesa/lib/gbm.
# /opt/omacvm-mesa is also where a VM with Vulkan on keeps its Venus Mesa
# (venus/install.sh): in such a VM set PREFIX to another folder
# (PREFIX=/opt/omacvm-gl-mesa ./build.sh), or this build replaces the Venus Mesa.
# Needs Mesa's build dependencies (pacman -S --needed base-devel meson ninja
# python-mako glslang libdrm wayland wayland-protocols libxrandr libxshmfence ...).
set -euo pipefail
cd "$(dirname "$0")"
here=$PWD
version=26.2.3
sha256=1628058a8d2c0615975de5a15ab7bbb9638c50000b5bed9456ff423ea034a81f
prefix=${PREFIX:-/opt/omacvm-mesa}
work=$(mktemp -d /var/tmp/omacvm-mesa.XXXXXX)
trap 'rm -rf "$work"' EXIT
curl -sfL -o "$work/mesa.tar.xz" "https://archive.mesa3d.org/mesa-$version.tar.xz"
echo "$sha256  $work/mesa.tar.xz" | sha256sum -c --quiet
tar -C "$work" -xf "$work/mesa.tar.xz"
cd "$work/mesa-$version"
patch -p1 < "$here/mesa-virgl-reset-status.patch"
patch -p1 < "$here/mesa-virgl-tgsi-clip-copyback.patch"
meson setup build -Dprefix="$prefix" -Dbuildtype=release -Dgallium-drivers=virgl \
  -Dvulkan-drivers= -Dplatforms=x11,wayland -Dglx=dri -Degl=enabled -Dgbm=enabled \
  -Dllvm=disabled -Dvideo-codecs= -Dgles2=enabled -Dshared-glapi=enabled >/dev/null
ninja -C build install >/dev/null
echo "Mesa $version with OmacVM's virgl patches: $prefix"
