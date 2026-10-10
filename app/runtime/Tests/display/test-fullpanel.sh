#!/bin/bash
# FullPanel's rules (omacvm-cocoa-fullpanel-logic.patch): the patch makes
# ui/omacvm-fullpanel.h in an empty folder, and test-fullpanel.c runs
# against it on every notched MacBook's size, external displays and a
# window moving between them. No QEMU, no display, no notch. CI and the
# runtime build run it.
# With ui/cocoa.m as argument (the runtime build, after the wiring patch):
# also that the wiring is there and every way in goes through the rules.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fullpanel.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-fullpanel-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" \
  "$here/test-fullpanel.c" -o "$work/test-fullpanel"
"$work/test-fullpanel"

(( $# )) || exit 0
m=$1
fail() { echo "test-fullpanel: $m: $*" >&2; exit 1; }
# Asked for per start only, through the header's rule.
[[ $(grep -c 'getenv("OMACVM_FULLPANEL")' "$m") == 1 ]] || fail "OMACVM_FULLPANEL is not read once"
grep -q 'return omacvm_fp_requested(getenv("OMACVM_FULLPANEL"));' "$m" || fail "the start's switch is not omacvm_fp_requested"
# The three places that size the guest and the area ask the window first.
[[ $(grep -c 'omacvm_fullpanel_window_usable(' "$m") -ge 5 ]] || fail "screenSafeAreaSize, the full-screen size or the display box does not ask FullPanel"
grep -q 'if (below_notch && !omacvm_fullpanel_window_usable(\[cocoaView window\])) {' "$m" || fail "the display box ignores FullPanel"
# Both window classes: prepared on the way into full screen, frames kept.
[[ $(grep -c 'omacvm_fullpanel_prepare_window(self);' "$m") == 2 ]] || fail "QemuWindow and OmacVMHeadWindow are not both prepared"
[[ $(grep -c 'if (omacvm_fullpanel_keep_frame(self, ' "$m") == 10 ]] || fail "not every frame setter of both windows goes through omacvm_fullpanel_keep_frame"
# The decisions are the tested ones.
for f in omacvm_fp_display_ok omacvm_fp_frame omacvm_fp_keep omacvm_fp_strip_lost omacvm_fp_reveal_allowed; do
  grep -q "$f(" "$m" || fail "$f is not used"
done
# Private interfaces only looked up at run time (no link to SkyLight).
grep -q 'dlopen(' "$m" && grep -q '"SLSTransactionSetMenuBarSystemOverrideAlpha"' "$m" || fail "SkyLight is not looked up at run time"
grep -q '"_frameForFullScreenMode"' "$m" || fail "the frame hook is not looked up by name"
# What omacvm check reads.
grep -q '"omacvm: full panel: strip covered: ' "$m" || fail "no 'strip covered' line for omacvm check"
echo "test-fullpanel: $m: wiring ok"
