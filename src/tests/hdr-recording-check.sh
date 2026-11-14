#!/bin/bash
# omacvm check's "HDR recordings" line (src/guest/check.sh, hdr_recording_line): with HDR
# on, screen recorders that read the screen over KMS (Omarchy's gpu-screen-recorder) know
# the screen is HDR only from the connector's HDR metadata, which OmacVM's driver offers
# with deep colour from linux-virtio-gpu-hdr-metadata.patch on. The function is taken from
# check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hdr-recording.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^hdr_recording_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no hdr_recording_line in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
expect() {   # what, loader word, build has it, it runs, want status [, Virtual-1 PQ now (default 1)]
  local got; got=$(hdr_recording_line "$2" "$3" "$4" "${6:-1}" | cut -f1)
  if [[ $got == "$5" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$5'"; fail=1; fi
}
says() {   # what, PQ now, text it must have [, HDR only in full screen's state]
  if hdr_recording_line omacvm 1 1 "$2" "${4:-}" | cut -f2 | grep -qF "$3"; then echo "ok   $1"; else echo "FAIL $1: no '$3'"; fail=1; fi
}
expect "10-bit driver with the metadata, running: ok" "omacvm" 1 1 ok
says "PQ now: says the screen is HDR now" 1 "the screen is HDR (PQ) now"
expect "SDR now (the Mac cannot show PQ): ok" "omacvm" 1 1 ok 0
says "SDR now: says so" 0 "the screen is SDR now (the Mac cannot show PQ)"
says "SDR in HDR only in full screen: says why" 0 "no window in full screen" sdr
says "PQ in HDR only in full screen: HDR now" 1 "the screen is HDR (PQ) now" pq
says "declined: the Mac's own reason stays" 0 "the Mac cannot show PQ" "declined: x"
expect "with the pointer layer, running: ok" "omacvm cursor_plane=1" 1 1 ok
expect "a build left without damage_clips, metadata running: ok" "omacvm without damage_clips" 1 1 ok
expect "built after this boot (Update VM): from the next start" "omacvm" 1 0 warn
expect "this build has none (its patch did not fit, or an older build)" "omacvm" 0 1 warn
expect "the stock driver runs: skip (the HDR output line says why)" "stock stamp out of date" 1 1 skip
expect "8-bit (pointer layer only): skip" "omacvm 8-bit cursor_plane=1" 1 1 skip
expect "no word from the loader: skip" "" 1 1 skip
grep -q 'warn "HDR recordings"' "$check" || { echo "FAIL check.sh does not show the line"; fail=1; }
grep -q 'hdr_recording_line .*"\$pq" "\$follow")' "$check" || { echo "FAIL check.sh does not pass whether Virtual-1 is PQ now and why"; fail=1; }
(( fail == 0 )) && echo "hdr-recording-check: all passed"
exit $fail
