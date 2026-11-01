#!/bin/bash
# omacvm check's "GPU contexts" row (src/cmd/check.sh) from QEMU's log of this
# run: the apps whose GL context ("context error reported N "NAME"") or Vulkan
# (Venus) context ("venus context N (NAME) is lost") was lost, once each, the
# Vulkan ones marked; a Venus context the guest was closing ("ended while the
# guest closed it", 3.2.18) is not named. Never a failure. No VM. macOS only.
#   src/tests/gpu-contexts-check.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
[[ $(uname -s) == Darwin ]] || { echo "skip: macOS only"; exit 0; }
C=$R/src/cmd/check.sh
row=$(sed -n '/^# A VM app whose GPU context virglrenderer dropped/,/^  else ok "GPU contexts"/p' "$C")
expect "check.sh has the row, and it is never bad" "yes 0" "$([[ -n $row ]] && echo yes) $(grep -c 'bad ' <<< "$row")"
ctxrow() {   # QEMU_LOG: the row's text
  ( ok() { echo "ok $1: $2"; }; skip() { echo "skip $1: $2"; }
    TYPE=app miclog=$1; eval "$row
fi" )
}
L=$T/qemu.log
: > "$L"
expect "nothing lost: ok" "ok GPU contexts: no VM app lost its GPU context in this run" "$(ctxrow "$L")"
# 3.2.15's log in the ghostty-gpu lose row (M1 Max, qemu-k15.log): a Zink Ghostty's Venus context.
cat > "$L" <<'LOG'
vkr: failed to look up object 305 of type 10
vkr: vkCreateImageView resulted in CS error
vkr: ring_submit_cmd: vn_dispatch_command failed
venus context 18 (ghostty) is lost: the guest driver sees the fatal ring status and ends the app
vkr: vkWaitRingSeqnoMESA resulted in CS error
LOG
expect "a Venus loss is named, marked Vulkan" \
  "skip GPU contexts: lost earlier in this run by: ghostty (Vulkan) (an app that draws nothing needs a restart; the shell: omarchy-restart-shell)" \
  "$(ctxrow "$L")"
cat >> "$L" <<'LOG'
venus context 21 (ghostty) is lost: the guest driver sees the fatal ring status and ends the app (the GPU memory budget had refused its memory)
vrend_decode_ctx_submit_cmd: context error reported 20 "chrome" Illegal resource 77
venus context 23 (vkcube) is lost: the guest driver sees the fatal ring status and ends the app
venus context 17 (zed) ended while the guest closed it: not a lost context
LOG
expect "GL and Venus losses, once each; a context the guest was closing is not named" \
  "skip GPU contexts: lost earlier in this run by: chrome, ghostty (Vulkan), vkcube (Vulkan) (an app that draws nothing needs a restart; the shell: omarchy-restart-shell)" \
  "$(ctxrow "$L")"
echo "OmacVM: restarting the VM's desktop by itself: apps open in the VM close (once per 10 min, else the app asks)" >> "$L"
case $(ctxrow "$L") in
*"vkcube (Vulkan); the app restarted the desktop by itself 1 time(s), closing the apps open in it"*)
  expect "the desktop restarts are still counted" yes yes ;;
*) expect "the desktop restarts are still counted" yes "$(ctxrow "$L")" ;;
esac
exit $fail
