#!/bin/bash
# omacvm check's "window surfaces" line (src/cmd/check.sh, surfaces_line, #562): which kind
# of surfaces OmacVM.app's window used this run, from qemu.log's lines (#531, #536): 8-bit
# and half float, each lossless-compressed or plain, the last line of each kind; plain
# with the reason when lossless is off; a warning after a failure (plain from then on).
# The function is taken from check.sh as it is; the log lines are made up as QEMU writes them
# and checked against the patch's text.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../cmd/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-surfaces-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^surfaces_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no surfaces_line in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
q() { printf '2026-10-26T17:00:00.000000Z qemu-system-aarch64: %s\n' "$@"; }
I8="info: cocoa: 8-bit surfaces lossless-compressed"
P8="info: cocoa: 8-bit surfaces plain"
IH="info: cocoa: half-float surfaces lossless-compressed"
PH="info: cocoa: half-float surfaces plain"
F8="warning: cocoa: lossless surfaces failed, plain surfaces from now on"
F8OLD="warning: cocoa: lossless surfaces failed, plain 8-bit surfaces from now on"
FH="warning: cocoa: lossless half-float surfaces failed, plain ones from now on"
OFF="info: cocoa: lossless surfaces: off (OMACVM_GL_LOSSLESS)"
OLD="info: cocoa: lossless surfaces: off (checked on macOS 27 and newer only)"
DMG="info: cocoa: lossless surfaces: off (OMACVM_GL_PRESENT_DAMAGE=check reads them back)"
# The lines above must be the patch's own words (3.2.6 on), or a new wording would make
# the check print nothing without a test failing. F8OLD stays: 3.2.1 to 3.2.5's words; DMG:
# 3.2.x to 3.4.7's (their check mode kept surfaces plain; later ones keep them lossless).
patch="$here/../../app/runtime/patches/omacvm-cocoa-present-lossless.patch"
for s in '"cocoa: %s surfaces %s", half ? "half-float" : "8-bit"' 'packed ? "lossless-compressed" : "plain"' \
    "${F8#warning: }" "${FH#warning: }" "${OFF#info: }" "${OLD#info: }"; do
  if grep -qF -- "$s" "$patch"; then echo "ok   patch writes '$s'"
  else echo "FAIL patch does not write '$s'"; fail=1; fi
done
expect() {   # what, want status ("" = no line), want text in the detail, log lines...
  local what=$1 st=$2 text=$3 got; shift 3
  if (( $# )); then q "$@" > "$T/qemu.log"; else : > "$T/qemu.log"; fi
  got=$(surfaces_line "$T/qemu.log")
  if [[ -z $st && -z $got ]] || [[ -n $st && ${got%%$'\t'*} == "$st" && $got == *"$text"* ]]; then echo "ok   $what"
  else echo "FAIL $what: got '$got', want '$st' with '$text'"; fail=1; fi
}
expect "no surface line (an app before 3.2.1, no frame yet): nothing" "" "" "info: OmacVM: graphics: opengl"
expect "8-bit lossless: ok" ok "8-bit lossless-compressed" "$I8"
expect "8-bit lossless, half float plain (HDR before 3.2.6): ok, both kinds" ok "8-bit lossless-compressed, half float plain" "$I8" "$PH"
expect "both lossless (HDR, Extra brightness from 3.2.6): ok" ok "8-bit lossless-compressed, half float lossless-compressed" "$I8" "$IH"
expect "the last line of each kind counts" ok "8-bit lossless-compressed, half float plain" "$P8" "$IH" "$I8" "$PH"
expect "8-bit failed: warn, plain from then on" warn "plain from then on" "$I8" "$F8" "$P8"
expect "8-bit failed (3.2.1 to 3.2.5's words): warn" warn "plain from then on" "$I8" "$F8OLD" "$P8"
expect "half float failed: warn, names half float" warn "lossless half-float surfaces failed" "$I8" "$IH" "$FH" "$PH"
expect "off by OMACVM_GL_LOSSLESS: ok, plain and why" ok "lossless off (OMACVM_GL_LOSSLESS)" "$OFF" "$P8"
expect "off before macOS 27: ok, plain and why" ok "lossless off (checked on macOS 27 and newer only)" "$OLD" "$P8"
expect "off by OMACVM_GL_PRESENT_DAMAGE=check (3.4.7 and older): ok, plain and why" ok "lossless off (OMACVM_GL_PRESENT_DAMAGE=check" "$DMG" "$P8"
grep -q 'ok "window surfaces"' "$check" && grep -q 'warn "window surfaces"' "$check" &&
  grep -q 'surfaces_line "$miclog"' "$check" || { echo "FAIL: check.sh does not print the line"; fail=1; }
(( fail == 0 )) && echo "surfaces-check: all passed"
exit $fail
