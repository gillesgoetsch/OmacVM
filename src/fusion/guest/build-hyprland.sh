#!/bin/bash
# Build and install Hyprland with the vmwgfx fix (hyprland-vmwgfx-dmabuf.patch):
# without it no GPU client survives on VMware Fusion, SDDM's greeter included,
# and the VM shows a black screen. Run as root inside the VM.
#   build-hyprland.sh [--hook] [desktop-user]
# Builds the exact source commit the installed hyprland package was built
# from (its binary says which), checked after the download, as the desktop
# user; only the install runs as root. The package's own binary is kept beside
# it (Hyprland.stock). Does nothing when the installed binary already is the
# patched build. A pacman hook (--hook: no pacman calls, its database is
# locked then) runs it again after every hyprland upgrade. Takes 10 to 20
# minutes on 4 vCPUs. OMACVM_REBUILD_HYPRLAND=1 builds anyway.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
HOOK=0; [[ ${1:-} == --hook ]] && { HOOK=1; shift; }
BIN=/usr/bin/Hyprland
STATE=/var/lib/omacvm/hyprland-vmwgfx      # "<package version> <sha256 of the patched binary>"
W=/var/cache/omacvm/hyprland-vmwgfx
DEPS=(base-devel git cmake ninja hyprwayland-scanner hyprland-protocols glaze)
U=${1:-$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env 2>/dev/null | tail -1)}
[[ -n $U ]] && id "$U" >/dev/null 2>&1 || { echo "build-hyprland: no desktop user in /etc/omacvm/env" >&2; exit 1; }

pkg=$(pacman -Q hyprland 2>/dev/null | awk '{ print $2 }')
[[ -n $pkg ]] || { echo "build-hyprland: the hyprland package is not installed" >&2; exit 1; }
sum() { sha256sum "$1" | awk '{ print $1 }'; }
if [[ -z ${OMACVM_REBUILD_HYPRLAND:-} && -f $STATE && $(cat "$STATE") == "$pkg $(sum $BIN)" ]]; then
  echo "Hyprland $pkg already has the vmwgfx fix: nothing to build"
  exit 0
fi
# The package's binary (signed by its repository) names its source commit.
stock=$BIN
[[ -f $STATE && $(awk '{ print $2 }' "$STATE") == "$(sum $BIN)" && -f $BIN.stock ]] && stock=$BIN.stock
commit=$("$stock" --version 2>/dev/null | grep -o '\b[0-9a-f]\{40\}\b' | head -1 || true)
[[ -n $commit ]] || { echo "build-hyprland: $stock does not say its source commit" >&2; exit 1; }

if (( ! HOOK )); then "$here/../../guest/pkg-add" "${DEPS[@]}"; fi
rm -rf "$W"; install -d -o "$U" -g "$U" "$W"; mkdir -p "$(dirname "$STATE")"
as_u() { sudo -u "$U" env HOME="$W" "$@"; }
cd "$W"
as_u git init -q src
cd src
as_u git fetch -q --depth 1 https://github.com/hyprwm/Hyprland "$commit" 2>/dev/null ||
  { echo "build-hyprland: cannot download Hyprland $commit" >&2; exit 1; }
as_u git checkout -q FETCH_HEAD
[[ $(as_u git rev-parse HEAD) == "$commit" ]] || { echo "build-hyprland: downloaded source is not $commit" >&2; exit 1; }
as_u git submodule update -q --init --recursive --depth 1
as_u git apply --check "$here/hyprland-vmwgfx-dmabuf.patch" 2>/dev/null ||
  { echo "build-hyprland: the vmwgfx fix does not apply to Hyprland $pkg (omacvm update may bring a newer one)" >&2; exit 1; }
as_u git apply "$here/hyprland-vmwgfx-dmabuf.patch"
echo "building Hyprland $pkg with the vmwgfx fix (10 to 20 minutes)"
as_u cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr > "$W/build.log" 2>&1 &&
  as_u cmake --build build --target Hyprland >> "$W/build.log" 2>&1 ||
  { tail -20 "$W/build.log" >&2; echo "build-hyprland: the build failed, full log: $W/build.log" >&2; exit 1; }
[[ -x build/Hyprland ]] || { echo "build-hyprland: no Hyprland binary after the build" >&2; exit 1; }

# The package's binary, unless what is there is an earlier patched build.
if [[ ! -f $STATE || $(awk '{ print $2 }' "$STATE") != "$(sum $BIN)" ]]; then cp -a $BIN $BIN.stock; fi
install -o root -g root -m755 build/Hyprland $BIN
echo "$pkg $(sum $BIN)" > "$STATE"
cd /; rm -rf "$W/src"
echo "Hyprland $pkg with the vmwgfx fix installed; log out or reboot to use it"
