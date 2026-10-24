#!/bin/bash
# mpv.sh (as root, in an OmacVM.app or UTM VM): mpv's defaults for the VM, in a
# marked block of the system-wide mpv.conf. mpv reads the user's
# ~/.config/mpv/mpv.conf after it, so a vo or gpu-api line there wins.
# - vo=gpu in every app and UTM VM (both draw OpenGL with virgl, with the same
#   Mesa and mpv). mpv's default output, gpu-next, leaks a GL fence per
#   frame on OpenGL: mpv presents through its own swap_buffers, and libplacebo
#   frees its frame fences only in pl_swapchain_swap_buffers, which mpv never
#   calls. On virgl each fence holds a file descriptor, so after ~17 s at
#   60 fps mpv reaches its 1024 limit and every frame fails ("expect bad
#   rendering 24"). vo=gpu frees its fences (mpv 0.41, libplacebo 7.360,
#   Mesa 26.2; Mac mini M4, 2026-10-18).
# - gpu-api=opengl while the VM has Vulkan. mpv picks Vulkan by itself whenever
#   the VM has a Vulkan driver, and on Venus it shows no video at all (Mac mini
#   M4, KosmicKrisp, 2026-10-17: stuck after its first frames in every swap
#   mode). OpenGL (virgl) plays it.
#   mpv.sh          write the block for the VM's graphics now
#   mpv.sh --off    the same (older callers ran it when Vulkan was switched off)
# The rest of the file is left as it is. Omarchy 4.5's omarchy-settings ships
# the file itself (hwdec=auto-safe) and its updates replace it: a pacman hook
# (zz-omacvm-mpv.hook) runs this again after them. Nothing ships the file on
# Omarchy 4.0, where the hook never fires.
# Tests: src/tests/venus-driver.sh (offline).
set -euo pipefail
DEST=${OMACVM_MPV_ROOT:-}
CONF=$DEST/etc/mpv/mpv.conf
ENVF=$DEST/etc/omacvm/env
OURS=$DEST/etc/vulkan/icd.d/omacvm_venus_icd.json
BEGIN='# OmacVM: begin (vo=gpu: gpu-next leaks a file per frame here; gpu-api=opengl: no video on Venus yet; ~/.config/mpv/mpv.conf wins)'
END='# OmacVM: end'
HOOK=$DEST/etc/pacman.d/hooks/zz-omacvm-mpv.hook
SELF=/usr/local/share/omacvm/app/guest/venus/mpv.sh

strip() {   # the file without our block
  [[ -f $CONF ]] || return 0
  awk -v e="$END" 'index($0, "# OmacVM: begin") == 1 { s = 1; next } s && $0 == e { s = 0; next } !s' "$CONF" > "$CONF.omacvm"
  if grep -q '[^[:space:]]' "$CONF.omacvm"; then mv "$CONF.omacvm" "$CONF"; else rm -f "$CONF.omacvm" "$CONF"; fi
}

case ${1:-} in
  ""|--off) ;;
  *) echo "usage: mpv.sh [--off]" >&2; exit 2 ;;
esac
[[ -n $DEST ]] || (( EUID == 0 )) || { echo "mpv.sh: run as root" >&2; exit 1; }
graphics=$(sed -n 's/^OMACVM_GRAPHICS=//p' "$ENVF" 2>/dev/null | tail -1)
feature=$(sed -n 's/^OMACVM_FEATURE_vulkan=//p' "$ENVF" 2>/dev/null | tail -1)
api=""
[[ $graphics == vulkan || $feature == on || -f $OURS ]] && api=$'\ngpu-api=opengl'
strip
mkdir -p "$(dirname "$CONF")"
printf '%s\nvo=gpu%s\n%s\n' "$BEGIN" "$api" "$END" >> "$CONF"
mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<EOF
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = etc/mpv/mpv.conf

[Action]
Description = OmacVM: mpv's defaults for the VM (vo=gpu)
When = PostTransaction
Exec = /bin/sh -c '[ ! -x $SELF ] || $SELF >/dev/null'
EOF
echo "mpv: vo=gpu${api:+, OpenGL} (~/.config/mpv/mpv.conf can choose)"
