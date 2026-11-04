#!/bin/bash
# Guest side, as root in the VM: build Mesa 26.2.3 (virgl only) with OmacVM's virgl
# patches into /opt/omacvm-gl-mesa (PREFIX=... for another folder). Not installed over
# the system Mesa: apps use it with LD_LIBRARY_PATH=/opt/omacvm-gl-mesa/lib
# GBM_BACKENDS_PATH=/opt/omacvm-gl-mesa/lib/gbm. It never installs into a folder that
# holds the Venus Mesa of a VM with Vulkan on (/opt/omacvm-mesa, venus/install.sh):
# that folder has the Venus build's omacvm-mesa-version file, and this script stops there.
# Needs Mesa's build dependencies (pacman -S --needed base-devel meson ninja
# python-mako glslang libdrm wayland wayland-protocols libxrandr libxshmfence ...).
set -euo pipefail
cd "$(dirname "$0")"
here=$PWD
version=26.2.3
sha256=1628058a8d2c0615975de5a15ab7bbb9638c50000b5bed9456ff423ea034a81f
prefix=${PREFIX:-/opt/omacvm-gl-mesa}
if [[ -e $prefix/omacvm-mesa-version || -e $prefix/lib/libvulkan_virtio.so ]]; then
  echo "$prefix holds the Venus Mesa of this VM (Graphics Vulkan); not built over it." >&2
  echo "Give PREFIX another folder (an empty one, or one this script built into)." >&2
  exit 1
fi
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
