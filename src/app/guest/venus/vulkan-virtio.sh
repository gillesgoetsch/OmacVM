#!/bin/bash
# vulkan-virtio.sh (as root, in an OmacVM.app VM): Vulkan through Venus on a
# stock Omarchy. When the app's Vulkan switch is on, the Mac sizes GPU memory
# in its 16 KiB pages (virtio-gpu blob alignment). Arch Linux ARM's Mesa 26.2.3
# Venus driver does not, the guest kernel refuses its first blob and every
# Vulkan app fails with "vkCreateInstance failed with ERROR_OUT_OF_HOST_MEMORY".
# Mesa 26.2.4 does. Chrome's WebGPU also needs shared (OPAQUE_FD) semaphores,
# which Venus lacks upstream. This builds the distro's vulkan-virtio package
# from Mesa 26.2.4 with that patch (PKGBUILD here, Venus only, a few minutes)
# and installs it with pacman; a newer Mesa from the distro replaces it on
# pacman -Syu (Vulkan keeps working, WebGPU in Chrome waits for OmacVM's next
# build). OpenGL stays on the distro's Mesa.
#   vulkan-virtio.sh            install it if this VM needs it (silent when Vulkan is off)
#   vulkan-virtio.sh --want     install it also before the VM has Vulkan (omacvm apply,
#                               when the VM's Graphics setting gives it Vulkan here)
#   vulkan-virtio.sh --ready    exit 0 if the VM has a Venus driver for 16 KiB pages
#                               (this package from 26.2.4 on, or OmacVM's Mesa)
#   vulkan-virtio.sh --status   one line: STATE DETAIL, STATE one of
#                               ok | needed (no Vulkan without the build) |
#                               update (Vulkan works; the build adds WebGPU in Chrome) |
#                               no-venus | no-pages (nothing to do)
# Tests: OMACVM_VENUS_PROBE replaces the probe's output ("venus=1 blob_alignment=16384"),
# OMACVM_VENUS_LIB the driver whose libraries are checked.
set -euo pipefail
cd "$(dirname "$0")"
# Packages only through guest/pkg-add: never an update of one the VM has.
PKG_ADD=${OMACVM_PKG_ADD:-$PWD/../../../guest/pkg-add}
FIXED=1:26.2.4                       # the first Venus driver that honours blob alignment
# This PKGBUILD's version (1:26.2.4.omacvm1): blob alignment and WebGPU's semaphores.
OURS=$(bash -c 'source ./PKGBUILD && echo "$epoch:$pkgver"')
LIB=${OMACVM_VENUS_LIB:-/usr/lib/libvulkan_virtio.so}
LOG=/var/log/omacvm-vulkan-virtio.log

# The installed driver is ours or newer. A distro update can leave ours
# without a library it links (a new soname): then it counts as missing.
current() {   # VERSION
  [[ -n $1 ]] && (( $(vercmp "$1" "$OURS") >= 0 )) || return 1
  [[ ! -e $LIB ]] || ! command -v ldd >/dev/null || ! ldd "$LIB" 2>/dev/null | grep -q 'not found'
}
# Our build is due: no driver, an older one, or ours with libraries missing
# (never over a newer distro Mesa: that is pacman's to fix).
due() {   # VERSION
  current "$1" && return 1
  [[ -z $1 || $1 == *omacvm* ]] && return 0
  (( $(vercmp "$1" "$OURS") < 0 ))
}
# Ours has the semaphores; a newer distro Mesa (no "omacvm" in it) does not.
webgpu() {
  if [[ $1 != *omacvm* ]]; then echo ", no shared semaphores for WebGPU in Chrome (OmacVM's next build adds them)"; fi
}

status() {
  local p venus align have
  p=${OMACVM_VENUS_PROBE:-$(python3 ./venus-probe.py 2>/dev/null || echo "venus=0 blob_alignment=0")}
  venus=$(sed -n 's/.*venus=\([0-9]*\).*/\1/p' <<<"$p"); align=$(sed -n 's/.*blob_alignment=\([0-9]*\).*/\1/p' <<<"$p")
  have=$(pacman -Q vulkan-virtio 2>/dev/null | awk '{ print $2 }' || true)
  if [[ ${venus:-0} != 1 ]]; then
    echo "no-venus Vulkan is off in OmacVM.app for this VM${have:+ (vulkan-virtio $have)}"
  elif (( ${align:-0} <= 4096 )); then
    echo "no-pages the GPU needs no page alignment here${have:+ (vulkan-virtio $have)}"
  elif current "$have"; then
    echo "ok vulkan-virtio $have sizes GPU memory to ${align}-byte pages$(webgpu "$have")"
  elif [[ -n $have ]] && (( $(vercmp "$have" "$OURS") >= 0 )); then
    # Libraries missing: ours is rebuilt; the distro's own (newer) is pacman's.
    if [[ $have == *omacvm* ]]; then echo "needed vulkan-virtio $have cannot load its libraries (after a distro update): rebuilt"
    else echo "ok vulkan-virtio $have (the distro's), but it misses libraries: pacman -Syu"; fi
  elif [[ -n $have ]] && (( $(vercmp "$have" "$FIXED") >= 0 )); then
    echo "update vulkan-virtio $have sizes GPU memory to ${align}-byte pages; ${OURS#*:} adds WebGPU in Chrome"
  else
    echo "needed vulkan-virtio ${have:-not installed} cannot size GPU memory to ${align}-byte pages (needs ${FIXED#*:})"
  fi
}

# The VM's Venus driver sizes GPU memory to 16 KiB pages (with or without the
# Venus device now): the Mac's Automatic Graphics waits for this.
ready() {
  local have
  [[ -f ${OMACVM_MESA_ICD:-/etc/vulkan/icd.d/omacvm_venus_icd.json} ]] && return 0
  have=$(pacman -Q vulkan-virtio 2>/dev/null | awk '{ print $2 }' || true)
  [[ -n $have ]] && (( $(vercmp "$have" "$FIXED") >= 0 ))
}

case ${1:-} in
  --status) status; exit 0 ;;
  --ready) ready; exit ;;
  --want|"") ;;
  *) echo "usage: vulkan-virtio.sh [--want | --ready | --status]" >&2; exit 2 ;;
esac
s=$(status)
have=$(pacman -Q vulkan-virtio 2>/dev/null | awk '{ print $2 }' || true)
case ${s%% *} in
  needed) ;;
  # OmacVM's Mesa (the vulkan feature) has the semaphores itself.
  update) [[ ! -f ${OMACVM_MESA_ICD:-/etc/vulkan/icd.d/omacvm_venus_icd.json} ]] || exit 0 ;;
  ok) echo "Vulkan (Venus): ${s#* }"; exit 0 ;;
  # No Venus device yet: with --want (Graphics Vulkan) build it ahead.
  *) [[ ${1:-} == --want ]] && due "$have" &&
       ! [[ -f ${OMACVM_MESA_ICD:-/etc/vulkan/icd.d/omacvm_venus_icd.json} ]] || exit 0 ;;
esac
(( EUID == 0 )) || { echo "vulkan-virtio.sh: run as root" >&2; exit 1; }

# From the boot timer (OMACVM_VENUS_BOOT): the unit does not wait for the
# network or for the user's own pacman, so this does, for a while.
if [[ -n ${OMACVM_VENUS_BOOT:-} ]]; then
  for _ in $(seq 60); do getent hosts archive.mesa3d.org >/dev/null && break; sleep 5; done
  for _ in $(seq 120); do [[ -e /var/lib/pacman/db.lck ]] || break; sleep 5; done
  [[ -e /var/lib/pacman/db.lck ]] && { echo "Vulkan (Venus): pacman is busy, trying again at the next boot"; exit 0; }
fi
echo "Vulkan (Venus): building Mesa's vulkan-virtio ${OURS#*:} (a few minutes, log $LOG)"
# Build tools this VM lacks are added for the build and removed after.
deps=(base-devel)
while IFS= read -r d; do deps+=("$d"); done < <(bash -c 'source ./PKGBUILD; printf "%s\n" "${depends[@]}" "${makedepends[@]}"')
missing=$(pacman -T "${deps[@]}" || true)
tools=""                             # what this run installed (removed again at the end)
B=$(mktemp -d /var/tmp/omacvm-vulkan-virtio.XXXXXX)
cleanup() {
  rm -rf "$B"
  if [[ -n $tools ]]; then
    # shellcheck disable=SC2086 # one package per word
    pacman -Rns --noconfirm $tools >>"$LOG" 2>&1 || echo "Vulkan (Venus): build tools left installed (pacman -Rns did not take them all)"
  fi
}
trap cleanup EXIT
fail() { echo "Vulkan (Venus): $1 (OpenGL is unaffected; details in $LOG)" >&2; exit 1; }
: > "$LOG"
if [[ -n $missing ]]; then
  # Never a partial upgrade: when the package lists are newer than the system,
  # installing a build tool can pull newer versions of installed packages (a
  # newer libdrm or LLVM under the old Mesa ends in a black desktop). Then
  # nothing is installed and the driver waits for a full pacman -Syu.
  # shellcheck disable=SC2086 # one package per word
  "$PKG_ADD" --asdeps $missing || fail "the build tools are not installed"
  tools=$missing
fi
install -m644 PKGBUILD patches/mesa-venus-opaque-fd-semaphores.patch "$B/"
chown -R nobody: "$B"
# makepkg refuses root: build as nobody (it downloads and checks the sha256 itself).
( cd "$B" && runuser -u nobody -- env HOME="$B" PKGDEST="$B" BUILDDIR="$B/build" SRCDEST="$B" LOGDEST="$B" PACKAGER="OmacVM <omacvm@users.noreply.github.com>" \
    makepkg --nodeps --noconfirm --noprogressbar ) >>"$LOG" 2>&1 || fail "the build failed"
pkg=""
# name-epoch:pkgver-pkgrel-arch
for f in "$B"/vulkan-virtio-"$OURS"-*-aarch64.pkg.tar.*; do [[ -f $f ]] && pkg=$f; done
[[ -n $pkg ]] || fail "the build made no package"
# Keep how the distro's package was installed (a dependency of Omarchy's, or by hand).
reason=--asexplicit
LC_ALL=C pacman -Qi vulkan-virtio 2>/dev/null | grep -q '^Install Reason *: Installed as a dependency' && reason=--asdeps
pacman -U --noconfirm "$reason" "$pkg" >>"$LOG" 2>&1 || fail "pacman could not install $(basename "$pkg")"
s=$(status)
if [[ ${s%% *} == no-venus || ${s%% *} == no-pages ]]; then
  current "$(pacman -Q vulkan-virtio | awk '{ print $2 }')" || fail "installed, but it is not ${OURS#*:} or newer"
  echo "Vulkan (Venus): vulkan-virtio $(pacman -Q vulkan-virtio | awk '{ print $2 }') ready for the VM's next start"
  exit 0
fi
[[ ${s%% *} == ok ]] || fail "installed, but: ${s#* }"
echo "Vulkan (Venus): ${s#* } (restart Vulkan apps)"
