#!/bin/bash
# webgpu.sh (as root, in an OmacVM.app VM): WebGPU in Chromium/Chrome on the
# Mac's GPU for a VM whose Graphics setting gives it Vulkan. Chrome hands
# pages a Vulkan WebGPU adapter only when its own compositor runs on Vulkan
# (omacvm-chromium-webgpu says how) and the Venus driver shares semaphores
# (vulkan-virtio.sh builds it with that patch). This puts the launcher in
# place: omacvm-chromium-webgpu (+ omacvm-chrome-webgpu) and a
# "Chromium (WebGPU)" menu entry. Chromium's normal entry stays as it is.
#   webgpu.sh          install the launcher
#   webgpu.sh --off    remove it, unless the VM still has WebGPU another way
#                      (Graphics Vulkan, or the vulkan feature's Mesa)
# Tests: src/tests/venus-driver.sh (offline).
set -euo pipefail
cd "$(dirname "$0")"
DEST=${OMACVM_WEBGPU_ROOT:-}
LAUNCH=$DEST/usr/local/bin/omacvm-chromium-webgpu
LAUNCH2=$DEST/usr/local/bin/omacvm-chrome-webgpu
DESK=$DEST/usr/share/applications/omacvm-chromium-webgpu.desktop
ENVF=$DEST/etc/omacvm/env
OURS=$DEST/etc/vulkan/icd.d/omacvm_venus_icd.json

case ${1:-} in
  --off)
    graphics=$(sed -n 's/^OMACVM_GRAPHICS=//p' "$ENVF" 2>/dev/null | tail -1)
    [[ $graphics == vulkan || -f $OURS ]] && exit 0
    rm -f "$LAUNCH" "$LAUNCH2" "$DESK"
    exit 0 ;;
  "") ;;
  *) echo "usage: webgpu.sh [--off]" >&2; exit 2 ;;
esac
[[ -n $DEST ]] || (( EUID == 0 )) || { echo "webgpu.sh: run as root" >&2; exit 1; }
install -Dm755 omacvm-chromium-webgpu "$LAUNCH"
ln -sf omacvm-chromium-webgpu "$LAUNCH2"
# The menu entry only with Chromium (Omarchy's browser); Chrome has the command.
if [[ -x ${OMACVM_CHROMIUM:-/usr/bin/chromium} ]]; then
  install -Dm644 omacvm-chromium-webgpu.desktop "$DESK"
fi
echo "WebGPU: \"Chromium (WebGPU)\" in the menu (omacvm-chromium-webgpu)"
