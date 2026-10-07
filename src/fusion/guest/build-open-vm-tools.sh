#!/bin/bash
# Build and install open-vm-tools (VMware Tools) for Arch Linux ARM, which
# does not package it: Arch's own package recipe, built for aarch64. Fusion
# sends its display layout (one display per Mac display in full screen, the
# window size in a window) only to a guest that runs VMware Tools, and copy
# and paste needs their dndcp plugin (omacvm-fusion-clipboard runs it). Run as root inside the VM:
# build-open-vm-tools.sh <desktop-user> (makepkg will not run as root). Does
# nothing when the installed build is complete and still starts (an update of
# one of its libraries can break it; then it builds again). About 5 minutes.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
U=${1:?usage: build-open-vm-tools.sh <desktop-user>}
W=/var/cache/omacvm/open-vm-tools
RECIPE=https://gitlab.archlinux.org/archlinux/packaging/packages/open-vm-tools.git
RECIPE_COMMIT=a2334c0c598a9efdc14f9bdf62aa827e19135d84   # tag 6-13.1.0-3
DNDCP=/usr/lib/open-vm-tools/plugins/vmusr/libdndcp.so

if pacman -Q open-vm-tools >/dev/null 2>&1 && [[ -f $DNDCP ]] &&
   ! ldd /usr/bin/vmtoolsd "$DNDCP" 2>/dev/null | grep -q "not found"; then
  echo "open-vm-tools $(pacman -Q open-vm-tools | awk '{ print $2 }') installed"
else
  rm -rf "$W"; install -d -o "$U" -g "$U" "$W"
  as_u() { sudo -u "$U" env HOME="$W" "$@"; }
  cd "$W"; as_u git init -q src; cd src
  as_u git fetch -q --depth 1 "$RECIPE" "$RECIPE_COMMIT"
  as_u git checkout -q FETCH_HEAD
  [[ $(as_u git rev-parse HEAD) == "$RECIPE_COMMIT" ]] || { echo "build-open-vm-tools: recipe is not $RECIPE_COMMIT" >&2; exit 1; }
  # Omarchy has GTK 4, so configure would build the copy and paste plugin
  # (dndcp) with gtkmm 4, which does not compile against libsigc++ 3: GTK 3
  # and gtkmm 3, as in Arch's own build.
  as_u sed -i 's|    --without-kernel-modules|    --without-kernel-modules --without-gtk4 --without-gtkmm4|' PKGBUILD
  grep -q -- '--without-gtkmm4' PKGBUILD || { echo "build-open-vm-tools: the recipe changed, GTK 3 not set" >&2; exit 1; }
  # Dependencies as makepkg reads them, without running the recipe as root.
  deps=$(as_u makepkg --printsrcinfo | sed -n 's/^\t\(make\)\{0,1\}depends = //p' | sed 's/[<>=].*//' | sort -u)
  "$here/../../guest/pkg-add" base-devel $deps
  echo "building open-vm-tools for aarch64 (about 5 minutes)"
  sudo -u "$U" env MAKEFLAGS="-j$(nproc)" makepkg -A --nodeps --noconfirm > "$W/build.log" 2>&1 ||
    { tail -20 "$W/build.log" >&2; echo "build-open-vm-tools: the build failed, full log: $W/build.log" >&2; exit 1; }
  # Installed from a root-owned copy.
  P=/var/cache/omacvm/open-vm-tools-pkg; rm -rf "$P"; install -d -m700 "$P"
  cp "$W"/src/open-vm-tools-*.pkg.tar.* "$P/"
  pacman -U --noconfirm "$P"/open-vm-tools-*.pkg.tar.* >/dev/null
  rm -rf "$P"
  [[ -f $DNDCP ]] || { echo "build-open-vm-tools: built without copy and paste (dndcp), see $W/build.log" >&2; exit 1; }
  rm -rf "$W/src"
  echo "open-vm-tools $(pacman -Q open-vm-tools | awk '{ print $2 }') built and installed"
fi
# resolutionKMS hands Fusion's display layout to vmwgfx.
install -Dm644 /dev/stdin /etc/vmware-tools/tools.conf <<'CONF'
[resolutionKMS]
enable=true
CONF
systemctl enable vmtoolsd >/dev/null 2>&1
systemctl restart vmtoolsd
