#!/bin/bash
# Partial present (omacvm-cocoa-present-damage*.patch):
#   - the rules: the logic patch makes ui/omacvm-present-damage.h in an empty
#     folder and test-present-damage.c runs against it (no QEMU, no display);
#   - with a patched ui/cocoa.m: the wiring (the guest's flush rects go in, the
#     present draws a surface's box scissored and without the clear, full
#     draws on the listed changes, off unless OMACVM_GL_PRESENT_DAMAGE=1 or
#     =check, the counts in qemu.log, the check mode reading a plain copy of
#     the shown surface, its test fault);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check
#     fails on that code (CI: a stub; the runtime build: the real cocoa.m
#     before the patch).
#   test-present-damage.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
# One line per check: "ok WHAT" or "FAIL WHAT".
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
# A before B before C (fixed strings), in that order in the text.
order() {
  awk -v a="$2" -v b="$3" -v c="${4:-}" '
    !x && index($0, a) {x=NR; next}
    x && !y && index($0, b) {y=NR; if (c == "") exit; next}
    y && c != "" && !z && index($0, c) {z=NR; exit}
    END {exit !(x && y && (c == "" || z))}' <<<"$1"
}
checks() {
  local m=$1 present flush alloc tex pdcheck part
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  flush=$(body "$m" 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,')
  alloc=$(body "$m" 'static bool cocoa_gl_present_alloc(')
  tex=$(body "$m" 'static void cocoa_gl_scanout_texture(DisplayChangeListener *dcl,')
  pdcheck=$(body "$m" 'static void cocoa_gl_present_pd_check(')
  # The statement that decides a partial draw, on one line, spaces squeezed.
  part=$(awk '/bool part = /{on=1} on {printf "%s ", $0} on && /;/ {exit}' <<<"$present" | tr -s ' \t' ' ')
  chk "the rules are included" grep -q '#include "ui/omacvm-present-damage.h"' "$m"
  chk "the guest's flush rects are collected" has "$flush" 'omacvm_pd_add(&present_pd, x, y, w, h);'
  chk "a flush marks the scanout buffer as flushed" has "$flush" 'present_pd_unflushed = false;'
  chk "a new scanout buffer is marked as not flushed yet" order "$tex" \
    'present_pd_unflushed |= backing_id != gl_scanout_id;' 'gl_scanout_id = backing_id;'
  chk "new surfaces are drawn in full" has "$alloc" 'omacvm_pd_reset(&present_pd, present_nsurf,'
  chk "the present asks what surface n needs" has "$present" 'omacvm_pd_take(&present_pd, n, &pd)'
  chk "another frame size draws in full" has "$present" 'omacvm_pd_frame(&present_pd, w, h);'
  chk "a change of path or buffer draws in full" has "$present" 'omacvm_pd_all_full(&present_pd);'
  for want in 'omacvm_pd_take(&present_pd, n, &pd)' 'present_damage_on' 'gl_scanout_borrow' \
              '!present_pd_unflushed' '!splash' '!boost' 'w == present_w' 'h == present_h' \
              'gl_scanout_x == 0' 'gl_scanout_y == 0' 'gl_scanout_w == w' 'gl_scanout_h == h'; do
    chk "a partial draw needs: $want" has "$part" "$want"
  done
  chk "the box is scissored" has "$present" 'glScissor(pd.x, pd.y, pd.w, pd.h);'
  # The clear only on full draws: it sits in the else branch of the partial one.
  chk "a partial draw does not clear the surface" order "$present" \
    'glScissor(pd.x, pd.y, pd.w, pd.h);' '} else {' 'glClear(GL_COLOR_BUFFER_BIT);'
  chk "the scissor goes off after the draw" order "$present" \
    'glScissor(pd.x, pd.y, pd.w, pd.h);' 'qemu_gl_run_texture_blit(present_gls, flip);' 'glDisable(GL_SCISSOR_TEST);'
  chk "OMACVM_GL_PRESENT_DAMAGE is read" has "$present" 'getenv("OMACVM_GL_PRESENT_DAMAGE")'
  chk "off unless OMACVM_GL_PRESENT_DAMAGE=1 or =check" has "$present" \
    'present_damage_on = e && !strcmp(e, "1") ? 1 : e && !strcmp(e, "check") ? 2 : 0;'
  chk "the check mode is wired" has "$present" 'cocoa_gl_present_pd_check(src, flip, n, pd);'
  # The kind of the surface it compares with, read from it (not "deep colour": extra brightness is half float too).
  chk "the check takes the shown surface's kind" has "$pdcheck" "bool half = fmt == 'RGhA' || fmt == '&RhA';"
  chk "the check draws in that kind's format" has "$pdcheck" 'half ? GL_RGBA16F : GL_RGBA8'
  # glReadPixels crashes on a lossless-compressed surface: the GPU copies it into a plain texture first.
  chk "the check reads a plain copy of the shown surface" order "$pdcheck" \
    'glBindFramebuffer(GL_READ_FRAMEBUFFER, present_fbo);' 'glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);' \
    'glReadPixels(0, 0, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, a);'
  chk "the frames after a full draw are all checked" has "$present" 'present_pd_check_burst = 4 * present_nsurf;'
  chk "the test fault is for the check mode only" has "$present" 'present_pd_fault = present_damage_on == 2 && fault && !strcmp(fault, "shrink");'
  chk "qemu.log gets the counts (frames in part, in full and why)" has "$present" 'present_pd_stats(w, h);'
  chk "the counts know the reasons" has "$m" 'present_pd.last == OMACVM_PD_FULL_BIG ? PD_WHY_BIG : PD_WHY_CATCHUP;'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-damage.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    { printf 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)\n{\n}\n'
      printf 'static bool cocoa_gl_present(void)\n{\n    glDisable(GL_SCISSOR_TEST);\n    glClear(GL_COLOR_BUFFER_BIT);\n}\n'
      printf 'static void cocoa_gl_scanout_texture(DisplayChangeListener *dcl,\n{\n    gl_scanout_id = backing_id;\n}\n'
      printf 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,\n{\n    gl_dirty = true;\n}\n'; } > "$T/old.m"
    old=$T/old.m
  fi
  passed=$(checks "$old" | grep '^ok ')
  if [[ -z $passed ]]; then echo "ok   every wiring check fails on the code without the patch ($old)"; exit 0; fi
  echo "FAIL these wiring checks pass on the code without the patch ($old):" >&2
  echo "$passed" >&2
  exit 1
fi
if [[ $# -ge 1 ]]; then
  out=$(checks "$1" | grep '^FAIL ')
  if [[ -n $out ]]; then echo "test-present-damage: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-present-damage: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-damage.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-present-damage-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-present-damage.c" -o "$work/test-present-damage"
"$work/test-present-damage"
