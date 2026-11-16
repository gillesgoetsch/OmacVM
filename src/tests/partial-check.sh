#!/bin/bash
# omacvm check's "Copy only what changed" line (src/cmd/check.sh, partial_line; ADR 0051):
# the app's word at the start and QEMU's last count of frames drawn in part and in full.
# Off says why; on without a count says one comes once a minute; whole frames are no fault
# (the stock driver of Linux 7.3 or older sends them); a check mode that found differing
# pixels warns. The function is taken from check.sh as it is; the log lines are made up as
# the app and QEMU write them and checked against their sources' text.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../cmd/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-partial-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^partial_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no partial_line in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
q() { printf '2026-11-16T23:00:00.000000Z qemu-system-aarch64: %s\n' "$@"; }
ON="OmacVM: partial present: on (only what the VM changed is drawn into the window's picture)"
OFFHDR="OmacVM: partial present: off (HDR start: not checked on an HDR display yet)"
OFFSW="OmacVM: partial present: off (switch off)"
C1="info: cocoa: partial present, last 60 s: 3412 frames in part (812 with nothing to draw), 41 in full: new buffer 3, catching up after a change 38; frame 2940x1912, surfaces 2940x1912"
C2="info: cocoa: partial present, last 61 s: 0 frames in part (0 with nothing to draw), 3600 in full: three quarters or more changed 3600; frame 2940x1912, surfaces 2940x1912"
OK0="info: cocoa: present check, so far: 0 of 400 checks bad"
BAD="info: cocoa: present check, so far: 3 of 400 checks bad"
# The lines must be what the app and the patch write.
runner="$here/../../app/app/Sources/OmacVM/Runner.swift"
model="$here/../../app/app/Sources/OmacVM/Model.swift"
patch="$here/../../app/runtime/patches/omacvm-cocoa-present-damage.patch"
for p in "$runner:OmacVM: partial present: \\(partial.on ? \"on\" : \"off\") (\\(partial.why))" \
         "$model:only what the VM changed is drawn into the window's picture" \
         "$model:HDR start: not checked on an HDR display yet" \
         "$patch:cocoa: partial present, last %\" PRId64 \" s: %\" PRIu64 \" frames in part" \
         "$patch:(%\" PRIu64 \" with nothing to draw), %\" PRIu64 \" in full%s; frame %ux%u," \
         "$patch:cocoa: present check, so far: %\" PRIu64 \" of %\" PRIu64 \" checks bad" \
         "$patch:\"three quarters or more changed\"" "$patch:\"new buffer\"" "$patch:\"catching up after a change\""; do
  f=${p%%:*}; s=${p#*:}
  if grep -qF -- "$s" "$f"; then echo "ok   ${f##*/} writes '$s'"; else echo "FAIL ${f##*/} does not write '$s'"; fail=1; fi
done
expect() {   # what, want status ("" = no line), want text in the detail, log lines...
  local what=$1 st=$2 text=$3 got; shift 3
  if (( $# )); then q "$@" > "$T/qemu.log"; else : > "$T/qemu.log"; fi
  # the app's own lines have no QEMU prefix
  sed -i '' 's/^.*qemu-system-aarch64: OmacVM: /OmacVM: /' "$T/qemu.log"
  got=$(partial_line "$T/qemu.log")
  if [[ -z $st && -z $got ]] || [[ -n $st && ${got%%$'\t'*} == "$st" && $got == *"$text"* ]]; then echo "ok   $what"
  else echo "FAIL $what: got '$got', want '$st' with '$text'"; fail=1; fi
}
expect "an app before it: nothing" "" "" "info: OmacVM: graphics: opengl"
expect "off by the switch: ok, says why" ok "off (switch off)" "$OFFSW"
expect "off for an HDR start: ok, says why" ok "off (HDR start: not checked" "$OFFHDR"
expect "on, no count yet: ok, a count comes once a minute" ok "once a minute" "$ON"
expect "on, a count: ok, the last count" ok "on: last 60 s: 3412 frames in part" "$ON" "$C1"
expect "on, the last count counts" ok "3600 in full: three quarters or more" "$ON" "$C1" "$C2"
expect "on, whole frames only (stock driver before 7.4): ok, no warning" ok "0 frames in part" "$ON" "$C2"
expect "check mode, 0 bad: ok" ok "on: last 60 s" "$ON" "$C1" "$OK0"
expect "check mode, differing pixels: warn" warn "3 of 400 checks bad" "$ON" "$C1" "$BAD"
grep -q 'ok "Copy only what changed"' "$check" && grep -q 'warn "Copy only what changed"' "$check" &&
  grep -q 'partial_line "$miclog"' "$check" || { echo "FAIL: check.sh does not print the line"; fail=1; }
(( fail == 0 )) && echo "partial-check: all passed"
exit $fail
