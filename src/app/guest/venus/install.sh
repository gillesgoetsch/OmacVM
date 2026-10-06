#!/bin/bash
# Venus extras for OmacVM.app VMs: Vulkan (Venus), OpenCL (rusticl on Zink on
# Venus), WebGPU in Firefox and, from an extra launcher, in Chromium/Chrome.
# The feature vulkan (omacvm enable vulkan) runs it with --force from
# guest/install.sh; the app starts that VM with Venus from then on.
# Run as root inside the VM: ./install.sh [--force | --remove | --venus-on]
# Without --force it only does something when the VM runs with Venus now.
# --venus-on: status 0 if this VM runs with Venus now (for omacvm check).
#
# Builds the pinned Mesa below with OmacVM's patches into /opt/omacvm-mesa
# (Arch Linux ARM's Mesa stays the GL driver) and registers it:
#   /etc/vulkan/icd.d/omacvm_venus_icd.json     Vulkan (Venus)
#   /etc/OpenCL/vendors/omacvm-rusticl.icd      OpenCL (rusticl, Zink)
#   /etc/environment.d/90-omacvm-venus.conf     RUSTICL_ENABLE=zink, distro venus off
#   Firefox: omacvm-webgpu.js                   WebGPU on
#   omacvm-chromium-webgpu (+ omacvm-chrome-webgpu) and a "Chromium (WebGPU)"
#   menu entry (webgpu.sh): Chromium with its compositor on Vulkan, which WebGPU needs
# ./install.sh --remove undoes all of it (the launcher stays with Graphics Vulkan).
set -euo pipefail
cd "$(dirname "$0")"
# Packages only through guest/pkg-add: never an update of one the VM has.
PKG_ADD=${OMACVM_PKG_ADD:-$PWD/../../../guest/pkg-add}
MESA_VERSION=26.2.4
MESA_SHA256=bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9
PREFIX=/opt/omacvm-mesa
ICD=/etc/vulkan/icd.d/omacvm_venus_icd.json
CLICD=/etc/OpenCL/vendors/omacvm-rusticl.icd
ENVF=/etc/environment.d/90-omacvm-venus.conf
FFPREF=/usr/lib/firefox/defaults/pref/omacvm-webgpu.js
LOG=/var/log/omacvm-mesa-build.log      # the last failed build's log

remove() {
  rm -rf "$PREFIX" "$ICD" "$CLICD" "$ENVF" "$FFPREF" "$LOG" /var/cache/omacvm/mesa-build
  ./webgpu.sh --off
  echo "OmacVM Venus extras removed"
}

# With Venus the host offers a third capset (virgl, virgl2, venus) and a host
# visible region for blobs; debugfs shows both.
venus_on() {
  mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
  local f
  for f in /sys/kernel/debug/dri/*/virtio-gpu-features; do
    [[ -r $f ]] || continue
    awk -F: '/cap sets/ { n = $2 + 0 } /host visible region/ { h = 1 } END { exit !(n >= 3 && h) }' "$f" && return 0
  done
  return 1
}

case ${1:-} in
  --remove) remove; exit 0 ;;
  --venus-on) venus_on; exit ;;
  --force) ;;
  *) venus_on || { echo "OmacVM Venus extras: no Venus in this VM, skipped"; exit 0; } ;;
esac

# The loader and the tools omacvm check uses (small; also when Mesa is built).
"$PKG_ADD" vulkan-icd-loader vulkan-tools ocl-icd clinfo ||
  echo "OmacVM Venus extras: vulkan-tools/clinfo not installed (omacvm check cannot test Vulkan)"
# Rusticl and Zink link the distro's LLVM: a new LLVM major version (an Arch
# update) needs a rebuild, which the next omacvm apply does.
llvm=$(pacman -Q llvm-libs 2>/dev/null | awk '{ split($2, v, "."); print v[1] }')
STAMP="$MESA_VERSION $(cat patches/*.patch | sha256sum | cut -c1-16) llvm-${llvm:-none}"
if [[ $(cat "$PREFIX/omacvm-mesa-version" 2>/dev/null) != "$STAMP" ]]; then
  # What the built Mesa links stays; build tools this VM lacks (on a stock
  # Omarchy: Rust, meson, ninja, bindgen) come for the build and go after it.
  # A rebuild (an LLVM update) downloads them again.
  "$PKG_ADD" spirv-tools spirv-llvm-translator llvm-libs clang libclc \
    libdrm wayland libx11 libxext libxrandr libxshmfence libxxf86vm ocl-icd zstd expat ||
    { echo "OmacVM Venus extras: pacman could not install Mesa's libraries"; exit 1; }
  BUILD_TOOLS=$(pacman -T meson ninja pkgconf python-mako python-yaml python-packaging glslang \
    wayland-protocols llvm rust rust-bindgen cbindgen || true)
  B=/var/cache/omacvm/mesa-build
  # shellcheck disable=SC2086 # one package per word
  trap 'rm -rf "$B"; [[ -z $BUILD_TOOLS ]] || pacman -Rns --noconfirm $BUILD_TOOLS >/dev/null 2>&1 ||
    echo "OmacVM Venus extras: build tools left installed (pacman -Rns did not take them all)"' EXIT
  if [[ -n $BUILD_TOOLS ]]; then
    # shellcheck disable=SC2086
    "$PKG_ADD" --asdeps $BUILD_TOOLS ||
      { echo "OmacVM Venus extras: pacman could not install Mesa's build tools"; exit 1; }
  fi
  rm -rf "$B"; mkdir -p "$B"
  curl -fsSL -o "$B/mesa.tar.xz" "https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"
  echo "$MESA_SHA256  $B/mesa.tar.xz" | sha256sum -c --quiet
  tar -C "$B" -xf "$B/mesa.tar.xz"
  S=$B/mesa-$MESA_VERSION
  for p in patches/*.patch; do patch -d "$S" -p1 --quiet < "$p"; done
  # Venus + Zink + rusticl only; GL stays with the distro's virgl.
  meson setup "$S/build" "$S" --prefix="$PREFIX" -Dbuildtype=release \
    -Dvulkan-drivers=virtio -Dgallium-drivers=zink -Dgallium-rusticl=true -Dllvm=enabled \
    -Dplatforms=wayland,x11 -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled \
    -Dglx=disabled -Dgbm=disabled -Dvideo-codecs= -Dvalgrind=disabled -Dlibunwind=disabled \
    > "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; cp "$B/build.log" "$LOG"; exit 1; }
  ninja -C "$S/build" install >> "$B/build.log" 2>&1 || { tail -30 "$B/build.log"; cp "$B/build.log" "$LOG"; exit 1; }
  echo "$STAMP" > "$PREFIX/omacvm-mesa-version"
fi

mkdir -p /etc/vulkan/icd.d /etc/OpenCL/vendors /etc/environment.d
sed "s#\"library_path\": \"[^\"]*\"#\"library_path\": \"$PREFIX/lib/libvulkan_virtio.so\"#" \
  "$PREFIX/share/vulkan/icd.d/virtio_icd.aarch64.json" > "$ICD"
echo "$PREFIX/lib/libRusticlOpenCL.so.1" > "$CLICD"
# The distro's venus (Mesa < 26.2.4 cannot round blobs to the host's 16 KiB
# pages) would add a second, broken device: the loader skips its manifest.
cat > "$ENVF" <<CONF
RUSTICL_ENABLE=zink
VK_LOADER_DRIVERS_DISABLE=virtio_icd.json
CONF
# Also before Firefox is installed (as the app's video pref): it reads it once it is.
install -Dm644 omacvm-webgpu.js "$FFPREF"
./webgpu.sh >/dev/null || echo "OmacVM Venus extras: the Chromium (WebGPU) launcher is not installed"
echo "OmacVM Venus extras: Mesa $MESA_VERSION in $PREFIX (Vulkan, OpenCL); WebGPU in Firefox and omacvm-chromium-webgpu"
