#!/bin/bash
# OmacVM's VA driver shim tells the Mac's runtime each video surface's own size
# (omacvm_drv_video.c, "Pictures at their own size"): only when the runtime says
# omacvm.valogical=1, only Mesa's own 4:2:0 surfaces whose size is not a multiple of 16; video
# processing from such a surface (or an import of it) gets its source region scaled for the
# size the Mac samples it at (any process), and vaGetImage into another format reads an import
# of it at the picture's size. Surfaces at the coded size (H.264 1080p: 1920x1088) get the size
# the app's EGL import asks for (omacvm_va_dmabuf_imported_v1, called by omacvm_egl.c), only for
# planes the app exported through the shim, only when it changes. The shim runs against a
# stand-in for Mesa's driver and for the kernel's DRM ioctls (va-shim-logical.c), on Linux
# with libva's headers (libva-dev) and the kernel's (linux-libc-dev).
#   src/app/guest/tests/va-shim-logical.sh [SHIM_SOURCE]
# SHIM_SOURCE: another omacvm_drv_video.c (an older one must fail).
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
shim_c=${1:-$here/../omacvm_drv_video.c}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
cc -shared -fPIC -O2 -Wall -DSTUB_DRIVER -o "$T/stub.so" "$here/va-shim-logical.c" || exit 1
cc -shared -fPIC -O2 -Wall -DMESA_DRIVER="\"$T/stub.so\"" -o "$T/shim.so" "$shim_c" -ldl -lpthread || exit 1
cc -O2 -Wall -rdynamic -o "$T/va-shim-logical" "$here/va-shim-logical.c" -ldl || exit 1
printf 'OMACVM_VAEXPORT=1\nOMACVM_VADECASYNC=1\nOMACVM_VALOGICAL=1\n' > "$T/host-new.env"
printf 'OMACVM_VAEXPORT=1\nOMACVM_VADECASYNC=1\n' > "$T/host-old.env"

# run WHAT MODE [ARG]: the program in a clean environment plus WHAT (VAR=VALUE ...).
run() {
  local what=$1 mode=$2 out
  shift 2
  out=$(env -i PATH="$PATH" $what "$T/va-shim-logical" "$T/shim.so" "$T/stub.so" "$mode" "$@" 2>&1)
  if [[ $? == 0 ]] && { [[ $mode != refused ]] || grep -q 'refused here' <<< "$out"; }; then
    echo "ok: $what ${*:-} -> $mode"
  else
    echo "FAIL: $what ${*:-} (expected: $mode)"
    grep -v '^ok' <<< "$out" | sed 's/^/    /'
    fail=1
  fi
}
# A runtime that samples at the guest's sizes: every process (Chromium's, and mpv, FFmpeg,
# Firefox), Chromium's fill with it.
run "OMACVM_HOST_ENV=$T/host-new.env" declare --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-new.env" declare --type=utility
run "OMACVM_HOST_ENV=$T/host-new.env" declare
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_FILL=1" declare
# An older runtime (or the app with OMACVM_VIDEO_LOGICAL=0): nothing sent, the fill as before.
run "OMACVM_HOST_ENV=$T/host-old.env" none --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-old.env OMACVM_VA_FILL=1" none
run "OMACVM_HOST_ENV=$T/none.env" none
# Overrides.
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_LOGICAL=0" none --type=gpu-process
run "OMACVM_HOST_ENV=$T/host-old.env OMACVM_VA_LOGICAL=1" declare
# A sandbox that refuses the submit: that process's surfaces as before, said once.
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_FILL=1" refused --type=gpu-process

# The app says so at every start (Runner.swift), unless OMACVM_VIDEO_LOGICAL=0.
runner=$repo/app/app/Sources/OmacVM/Runner.swift
if grep -A1 -F 'if ProcessInfo.processInfo.environment["OMACVM_VIDEO_LOGICAL"] != "0" {' "$runner" |
   grep -q '^            a += \["-smbios", "type=11,value=omacvm.valogical=1"\]$' &&
   [[ $(grep -c 'omacvm.valogical=1' "$runner") == 1 ]]; then
  echo "ok: the app sends omacvm.valogical unless OMACVM_VIDEO_LOGICAL=0"
else
  echo "FAIL: Runner.swift does not send omacvm.valogical only without OMACVM_VIDEO_LOGICAL=0"; fail=1
fi
(( fail )) && { echo "va-shim-logical: FAILED"; exit 1; }
echo "va-shim-logical: all ok"
