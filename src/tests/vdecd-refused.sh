#!/bin/bash
# Chromium's video decoder daemon (omacvm-vdecd) fails a video whose first pictures VA-API
# refuses (src/vdec/guest/vdecd-refused.h), so Chromium decodes it on the CPU instead of
# showing no picture: H.264 coded interlaced, which the VA shim refuses. Three refusals
# (AVERROR(EIO)) before the first picture, counted from each START; an SPS or PPS alone
# (AVERROR_INVALIDDATA) does not count, nothing changes after the first picture. The rule
# runs in src/vdec/guest/test/refused-test.c (FFmpeg's libavutil headers); the daemon's
# calls are checked in its source.
#   src/tests/vdecd-refused.sh [VDEC_GUEST_DIR]
# VDEC_GUEST_DIR: another src/vdec/guest (an older one must fail).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
G=${1:-$R/src/vdec/guest}
T=$(mktemp -d "${TMPDIR:-/tmp}/vdecd-refused.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

C=$G/omacvm-vdecd.c
if [[ ! -f $G/vdecd-refused.h ]]; then
  echo "FAIL no vdecd-refused.h in $G"
  exit 1
fi
# shellcheck disable=SC2046,SC2086
if ! cc -O2 -Wall -Werror ${OMACVM_TEST_CFLAGS:-} -I"$G" $(pkg-config --cflags libavutil 2>/dev/null) \
     -o "$T/t" "$R/src/vdec/guest/test/refused-test.c"; then
  echo "FAIL the test does not build"
  exit 1
fi
"$T/t" || fail=1

# The daemon: counts at both places FFmpeg says no, marks a received VA-API picture, starts
# again at each START (also on the same decoder), and fails the video in pump() once the
# packet is off the queue, never inside the decode loops (inst_fail drops the queue).
fn() { sed -n "/^static [a-z ]*$1(/,/^}/p" "$C"; }
expect "daemon: includes vdecd-refused.h" 1 "$(grep -c '^#include "vdecd-refused.h"$' "$C")"
expect "daemon: feed_input counts a refused packet" 1 \
  "$(fn feed_input | grep -c 'if (r < 0 && vdecd_refused_error(&in->refused, r))')"
expect "daemon: receive_all counts a decode error" 1 \
  "$(fn receive_all | grep -c 'if (vdecd_refused_error(&in->refused, r))')"
expect "daemon: receive_all marks a VA-API picture, after its check" "AV_PIX_FMT_VAAPI vdecd_refused_picture" \
  "$(fn receive_all | grep -oE 'AV_PIX_FMT_VAAPI|vdecd_refused_picture' | tr '\n' ' ' | sed 's/ $//')"
expect "daemon: neither loop fails the video itself" 0 "$( (fn feed_input; fn receive_all) | grep -c 'inst_fail')"
expect "daemon: pump fails it" 1 "$(fn pump | tr -d '\n\t' | grep -c 'if (in->refused_fail) {in->refused_fail = false;inst_fail(in, ')"
expect "daemon: every START starts the count again" 1 \
  "$(sed -n '/case OVD_MSG_START:/,/break;/p' "$C" | grep -c 'vdecd_refused_start(&in->refused);')"

exit $fail
