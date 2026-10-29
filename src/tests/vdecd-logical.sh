#!/bin/bash
# Chromium's video decoder daemon (omacvm-vdecd) tells the Mac's runtime the picture's size
# when its buffers are rounded up to even (src/vdec/guest/vdecd-logical.h): an odd-size VP9
# (853x480 in 854x480 buffers) is sampled at its own size instead of squeezed by the extra
# column. Only when the runtime says OMACVM_VALOGICAL=1 (OMACVM_VA_LOGICAL=0|1 overrides),
# never for buffers of the picture's size, before the app gets the buffers. The header runs
# against a stand-in for the kernel's ioctls (src/vdec/guest/test/logical-test.c), on Linux
# with the kernel's headers (linux-libc-dev); the daemon's call is checked in its source.
#   src/tests/vdecd-logical.sh [VDEC_GUEST_DIR]
# VDEC_GUEST_DIR: another src/vdec/guest (an older one must fail).
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
G=${1:-$R/src/vdec/guest}
T=$(mktemp -d "${TMPDIR:-/tmp}/vdecd-logical.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

C=$G/omacvm-vdecd.c
if [[ ! -f $G/vdecd-logical.h ]]; then
  echo "FAIL no vdecd-logical.h in $G"
  exit 1
fi
# shellcheck disable=SC2086
if ! cc -O2 -Wall -Werror ${OMACVM_TEST_CFLAGS:-} -I"$G" -o "$T/t" "$R/src/vdec/guest/test/logical-test.c"; then
  echo "FAIL the test does not build"
  exit 1
fi
printf 'OMACVM_VAEXPORT=1\nOMACVM_VADECASYNC=1\nOMACVM_VALOGICAL=1\n' > "$T/host-new.env"
printf 'OMACVM_VAEXPORT=1\nOMACVM_VADECASYNC=1\n' > "$T/host-old.env"

# run WHAT MODE: the program in a clean environment plus WHAT (VAR=VALUE ...)
run() {
  local out
  # shellcheck disable=SC2086
  out=$(env -i PATH="$PATH" $1 "$T/t" "$2" 2>&1)
  if [[ $? == 0 ]]; then echo "ok   $2 (${1//$T\//})"; else echo "FAIL $2 (${1//$T\//})"; sed 's/^/    /' <<< "$out"; fail=1; fi
}
on() { env -i PATH="$PATH" "$@" "$T/t" on; }

# Which runtimes: one that says so (3.2.11 and newer), one that does not (3.2.10, or the Mac's
# OMACVM_VIDEO_LOGICAL=0), the switch both ways, no file (another hypervisor).
expect "on: the runtime says OMACVM_VALOGICAL=1" 1 "$(on OMACVM_HOST_ENV="$T/host-new.env")"
expect "off: the runtime does not say it" 0 "$(on OMACVM_HOST_ENV="$T/host-old.env")"
expect "off: no host.env" 0 "$(on OMACVM_HOST_ENV="$T/none.env")"
expect "off: OMACVM_VA_LOGICAL=0" 0 "$(on OMACVM_HOST_ENV="$T/host-new.env" OMACVM_VA_LOGICAL=0)"
expect "on: OMACVM_VA_LOGICAL=1" 1 "$(on OMACVM_HOST_ENV="$T/host-old.env" OMACVM_VA_LOGICAL=1)"

# What it sends: one RESOURCE_INFO per buffer, then NOPs of 8 entries in one submit on the
# buffers' DRM file; nothing for even sizes; a refused ioctl sends nothing.
for m in odd odd-rows even refused-info refused-exec; do run "OMACVM_HOST_ENV=$T/host-new.env" "$m"; done
run "OMACVM_HOST_ENV=$T/host-old.env" off
run "OMACVM_HOST_ENV=$T/host-new.env OMACVM_VA_LOGICAL=0" off

# The daemon: includes it, declares on the file GBM made the buffers on, with the picture's
# size, in cap_setup before the buffers go to the app (OVD_IOC_SET_BUFFERS), says a refusal once.
expect "daemon: includes vdecd-logical.h" 1 "$(grep -c '^#include "vdecd-logical.h"$' "$C")"
setup=$(sed -n '/^static void cap_setup(/,/^}/p' "$C")
expect "daemon: cap_setup declares before OVD_IOC_SET_BUFFERS" "cap_logical OVD_IOC_SET_BUFFERS" \
  "$(grep -oE 'cap_logical|OVD_IOC_SET_BUFFERS' <<< "$setup" | tr '\n' ' ' | sed 's/ $//')"
logical=$(sed -n '/^static void cap_logical(/,/^}/p' "$C")
expect "daemon: on the buffers' own DRM file, at the picture's size" 1 \
  "$(tr -d '\n\t' <<< "$logical" | grep -c 'vdecd_logical_declare(gbm_device_get_fd(gbm), handles, in->ncap, in->width, in->height, *in->vis_width, in->vis_height, &why)')"
expect "daemon: a refusal is said once" 1 "$(grep -c '^	static bool refused;$' <<< "$logical")"

exit $fail
