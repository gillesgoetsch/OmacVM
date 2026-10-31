#!/bin/bash
# The window's spare present surfaces volatile while it is out of sight
# (omacvm-cocoa-present-volatile-logic.patch, omacvm-cocoa-present-volatile.patch):
#   - the rules: the logic patch makes ui/omacvm-present-volatile.h in an empty
#     folder and test-present-volatile.c runs against it (no QEMU, no display):
#     out of sight 2 s -> 4 of 5 volatile, not the one shown; in sight -> none;
#     emptied by macOS -> drawn whole; off, refused;
#   - with a patched ui/cocoa.m: the wiring;
#   - with --self-test [<ui/cocoa.m without the patch>]: the rules' test fails
#     with 3.2.16's decisions (test-present-volatile-stub.h: every surface kept)
#     and every wiring check fails on that code (CI: a stub; the runtime
#     build: the real cocoa.m before the patch).
#   test-present-volatile.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-volatile.XXXXXX")
trap 'rm -rf "$work"' EXIT
fbody() {
  awk -v h="$2" '
    !on && !buf && index($0, h) == 1 { buf = $0 "\n"; if ($0 ~ /;[ \t]*$/) buf = ""; next }
    buf && !on { if ($0 == "{") { on = 1; printf "%s", buf; print; next }
                 buf = buf $0 "\n"; if ($0 ~ /;[ \t]*$/) buf = ""; next }
    on { print; if ($0 ~ /^}$/) exit }' "$1"
}
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
# A before B (fixed strings), in that order in the text.
order() { awk -v a="$2" -v b="$3" '!x && index($0, a) {x=NR; next} x && index($0, b) {y=NR; exit} END {exit !(x && y)}' <<<"$1"; }

checks() {
  local m=$1 free alloc look back present refresh show showt nonvsync
  free=$(fbody "$m" 'static void cocoa_gl_present_free(void)')
  alloc=$(fbody "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)')
  look=$(fbody "$m" 'static void present_volatile_look(void)')
  back=$(fbody "$m" 'static void present_volatile_back(unsigned i)')
  present=$(fbody "$m" 'static bool cocoa_gl_present(void)')
  refresh=$(fbody "$m" 'static void cocoa_gl_refresh(DisplayChangeListener *dcl)')
  show=$(fbody "$m" 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,')
  showt=$(fbody "$m" 'static void cocoa_gl_present_show_tiles(PresentFrame *f)')
  chk "the rules are included" grep -q '#include "ui/omacvm-present-volatile.h"' "$m"
  chk "freed surfaces leave no volatile mark" has "$free" 'omacvm_pv_reset(&present_pv, 0);'
  chk "new surfaces start non-volatile" has "$alloc" 'omacvm_pv_reset(&present_pv, present_nsurf);'
  chk "the look follows the window's sight" has "$look" 'omacvm_pv_sight(&present_pv, qatomic_read(&omacvm_window_seen), now);'
  chk "shown = in use or the layer's contents" has "$look" 'bool busy = present_surf[i] == shown || IOSurfaceIsInUse(present_surf[i]);'
  chk "a spare surface is made volatile" has "$look" 'IOSurfaceSetPurgeable(present_surf[i], kIOSurfacePurgeableVolatile, &old);'
  chk "macOS's answer is checked (a refusal stops the rule)" has "$look" 'omacvm_pv_made(&present_pv, i, kr == KERN_SUCCESS);'
  chk "a refusal brings every volatile one back" order "$look" 'if (kr != KERN_SUCCESS) {' 'present_volatile_back(k);'
  chk "in sight: volatile ones come back" order "$look" '} else if (step < 0) {' 'present_volatile_back(i);'
  chk "back: non-volatile, emptied when macOS took it" order "$back" \
    'IOSurfaceSetPurgeable(present_surf[i], kIOSurfacePurgeableNonVolatile, &old);' 'old == kIOSurfacePurgeableEmpty'
  chk "an emptied surface is drawn whole" order "$back" 'if (omacvm_pv_back(&present_pv, i, emptied)) {' 'omacvm_pd_all_full(&present_pd);'
  chk "the test hook empties it for real" has "$back" 'IOSurfaceSetPurgeable(present_surf[i], kIOSurfacePurgeableEmpty, &old);'
  chk "OMACVM_PRESENT_VOLATILE=0 and OMACVM_PRESENT_HIDDEN keep them all" has "$look" \
    'present_pv.off = hidden || (e && !strcmp(e, "0"));'
  chk "qemu.log says which, once" has "$look" '"cocoa: present surfaces: %s%s"'
  chk "qemu.log says what came back" has "$look" 'spare surfaces were volatile, '
  chk "the present looks first, before the out-of-sight return" order "$present" 'present_volatile_look();' \
    'if (!qatomic_read(&omacvm_window_seen) && !always) {'
  chk "the present makes the surface it takes non-volatile first" order "$present" \
    'if (omacvm_pv_needed(&present_pv, n)) {' 'omacvm_pd_take(&present_pd, n, &pd)'
  chk "the refresh tick looks (500 ms out of sight)" has "$refresh" 'present_volatile_look();'
  chk "the shown surface is noted (vsync)" order "$show" '[layer setContents:(id)surf];' 'qatomic_set(&present_shown, surf);'
  chk "the shown surface is noted (tiles' whole frame)" order "$showt" '[layer setContents:(id)pt->base];' \
    'qatomic_set(&present_shown, pt->base);'
  nonvsync=$(awk '/dispatch_async\(dispatch_get_main_queue\(\), \^\{/{on=1} on && /\[layer setContents:\(id\)surf\];/{s=1} s && /qatomic_set\(&present_shown, surf\);/{ok=1; exit} END{exit !ok}' <<<"$present" && echo y)
  chk "the shown surface is noted (frames shown when drawn)" test -n "$nonvsync"
}

if [[ ${1:-} == --self-test ]]; then
  mkdir -p "$work/stub"
  cp "$here/test-present-volatile-stub.h" "$work/stub/omacvm-present-volatile.h"
  cc -std=c11 -Wall -Wextra -Werror -I"$work/stub" "$here/test-present-volatile.c" -o "$work/t-stub" || exit 1
  if "$work/t-stub" > "$work/stub.out"; then
    echo "FAIL the rules' test passes with 3.2.16's decisions (every surface kept)" >&2; exit 1
  fi
  echo "ok   the rules' test fails with 3.2.16's decisions ($(grep -c '^FAIL' "$work/stub.out") checks)"
  old=${2:-}
  if [[ -z $old ]]; then
    old=$work/old.m
    { printf 'static void cocoa_gl_present_free(void)\n{\n    present_w = present_h = 0;\n}\n'
      printf 'static bool cocoa_gl_present(void)\n{\n    if (!qatomic_read(&omacvm_window_seen) && !always) {\n    }\n}\n'
      printf 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,\n{\n    [layer setContents:(id)surf];\n}\n'; } > "$old"
  fi
  passed=$(checks "$old" | grep '^ok ')
  if [[ -n $passed ]]; then echo "FAIL these wiring checks pass on the code without the patch ($old):" >&2; echo "$passed" >&2; exit 1; fi
  echo "ok   every wiring check fails on the code without the patch ($old)"
  exit 0
fi
if [[ $# -ge 1 ]]; then
  out=$(checks "$1" | grep '^FAIL ')
  if [[ -n $out ]]; then echo "test-present-volatile: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-present-volatile: $1: wiring ok"
  exit 0
fi
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-present-volatile-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-present-volatile.c" -o "$work/test-present-volatile"
"$work/test-present-volatile"
