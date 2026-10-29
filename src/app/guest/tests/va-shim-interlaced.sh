#!/bin/bash
# OmacVM's VA driver shim refuses H.264 coded interlaced (omacvm_drv_video.c, "H.264 coded
# interlaced"): the Mac's hardware decoder does not take it, and VideoToolbox's software decoder
# gave green or wrong pictures. An H.264 picture whose parameters say frame_mbs_only_flag 0
# (MBAFF frames, field pictures) gets VA_STATUS_ERROR_UNIMPLEMENTED at vaRenderPicture, its
# slices and vaEndPicture too: Mesa gets only its vaBeginPicture, none of its parameters, slices
# or vaEndPicture, and nothing reaches the Mac; players then decode on the CPU. Pictures coded as
# frames, HEVC, encoding and video processing pass on. Refusals are logged at most every 10 s.
# The shim runs against a stand-in for Mesa's driver (va-shim-interlaced.c), on Linux with
# libva's headers (libva-dev).
#   src/app/guest/tests/va-shim-interlaced.sh [SHIM_SOURCE]
# SHIM_SOURCE: another omacvm_drv_video.c (an older one must fail).
set -u
here=$(cd "$(dirname "$0")" && pwd)
shim_c=${1:-$here/../omacvm_drv_video.c}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
cc -shared -fPIC -O2 -Wall -DSTUB_DRIVER -o "$T/stub.so" "$here/va-shim-interlaced.c" || exit 1
cc -shared -fPIC -O2 -Wall -DMESA_DRIVER="\"$T/stub.so\"" -o "$T/shim.so" "$shim_c" -ldl -lpthread || exit 1
cc -O2 -Wall -o "$T/va-shim-interlaced" "$here/va-shim-interlaced.c" -ldl || exit 1

# run WHAT on|off LOGLINES [ARG]: the program in a clean environment plus WHAT (VAR=VALUE ...);
# LOGLINES: how many refusal lines it must print (the 6 refusals come within 10 s: one line).
run() {
  local what=$1 expect=$2 lines=$3 out n
  shift 3
  out=$(env -i PATH="$PATH" OMACVM_HOST_ENV="$T/none.env" $what "$T/va-shim-interlaced" "$T/shim.so" "$T/stub.so" "$expect" "$@" 2>&1)
  local st=$?
  n=$(grep -c 'interlaced' <<< "$(grep '^omacvm_drv_video:' <<< "$out")")
  if [[ $st == 0 && $n == "$lines" ]]; then
    echo "ok: ${what:-default} ${*:-} -> refusal $expect, $n log line(s)"
  else
    echo "FAIL: ${what:-default} ${*:-} (exit $st, $n refusal log lines, expected $lines)"
    grep -v '^ok' <<< "$out" | sed 's/^/    /'
    fail=1
  fi
}
# Every process (Chromium's are refused too, mpv, FFmpeg, GStreamer, Firefox), and with the
# other switches that decide which of the shim's hooks are on.
run "" on 1
run "" on 1 --type=gpu-process
run "OMACVM_VA_IMPORT_GUARD=0" on 1
run "OMACVM_VA_DECODE_WAIT=1" on 1
run "OMACVM_VA_FILL=0 OMACVM_VA_LOGICAL=0" on 1
# The switch: Mesa gets them (green or wrong pictures, as before).
run "OMACVM_VA_INTERLACED=1" off 0
(( fail )) && { echo "va-shim-interlaced: FAILED"; exit 1; }
echo "va-shim-interlaced: all ok"
