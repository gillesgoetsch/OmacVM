#!/bin/bash
# OmacVM's VA driver shim refuses to decode into an imported surface (omacvm_drv_video.c,
# "Decoding into an imported surface"): Mesa's virgl driver crashes the app's process there
# (Chrome's GPU process). The shim runs against a stand-in for Mesa's driver
# (va-shim-import-decode.c), on Linux with libva's headers (libva-dev).
#   src/app/guest/tests/va-shim-import-decode.sh [SHIM_SOURCE]
# SHIM_SOURCE: another omacvm_drv_video.c (an older one must fail).
set -u
here=$(cd "$(dirname "$0")" && pwd)
shim_c=${1:-$here/../omacvm_drv_video.c}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
cc -shared -fPIC -O2 -Wall -DSTUB_DRIVER -o "$T/stub.so" "$here/va-shim-import-decode.c" || exit 1
cc -shared -fPIC -O2 -Wall -DMESA_DRIVER="\"$T/stub.so\"" -o "$T/shim.so" "$shim_c" -ldl -lpthread || exit 1
cc -O2 -Wall -o "$T/va-shim-import-decode" "$here/va-shim-import-decode.c" -ldl || exit 1

# run WHAT [ARG]: the program in a clean environment plus WHAT (VAR=VALUE ...).
run() {
  local what=$1 out
  shift
  out=$(env -i PATH="$PATH" OMACVM_HOST_ENV="$T/none.env" $what "$T/va-shim-import-decode" "$T/shim.so" "$T/stub.so" "$@" 2>&1)
  if [[ $? == 0 ]]; then
    echo "ok: $what ${*:-} -> decoding into imports refused"
  else
    echo "FAIL: $what ${*:-}"
    grep -v '^ok' <<< "$out" | sed 's/^/    /'
    fail=1
  fi
}
# Every process: Chromium's GPU and decoder processes, and the others (mpv, FFmpeg, Firefox),
# with the fill on or off.
run "" --type=gpu-process
run "" --type=utility
run ""
run "OMACVM_VA_FILL=0" --type=gpu-process
run "OMACVM_VA_FILL=1"
(( fail )) && { echo "va-shim-import-decode: FAILED"; exit 1; }
echo "va-shim-import-decode: all ok"
