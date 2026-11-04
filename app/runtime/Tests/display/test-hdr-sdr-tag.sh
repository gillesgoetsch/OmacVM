#!/bin/bash
# HDR frames ask macOS for headroom only while they show HDR (ADR 0049, amended;
# omacvm-cocoa-hdr-sdr-tag-logic.patch, omacvm-cocoa-hdr-sdr-tag.patch):
#   - the rules: the logic patches make ui/omacvm-edr.h and ui/omacvm-hdr-tag.h in an empty folder and
#     test-hdr-sdr-tag.c runs against them (the tag, the hold, the guest's headroom, a model of macOS's
#     headroom ramp: no lock, no back and forth), then --self-test of the model (3.2.22's rule, a guest
#     told the current headroom and a 2 s hold must fail it);
#   - the peak shader on Apple's software renderer (test-hdr-sdr-tag-shader.m: one HDR pixel anywhere in
#     frames up to 5120x2880 reads back exactly);
#   - with a patched ui/cocoa.m: the wiring (the look in the present before surface n is taken and before
#     the tiles, every PQ surface tagged before Core Animation sees it, whole frames and tiles alike, the
#     layer follows its surface's tag, a change of tag is a whole frame and a redraw, the hold's timer,
#     the guest's headroom from the rule, the look's read back without a wait, OMACVM_HDR_SDR_TAG=0);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check fails on that code (CI: a
#     stub; the runtime build: the real cocoa.m before the patch).
#   test-hdr-sdr-tag.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
body() { awk -v h="$2" 'index($0, h) == 1 && $0 !~ /;$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
lacks() { [[ -n $1 ]] && hasnt "$1" "$2"; }
order() {
  awk -v a="$2" -v b="$3" -v c="${4:-}" '
    !x && index($0, a) {x=NR; next}
    x && !y && index($0, b) {y=NR; if (c == "") exit; next}
    y && c != "" && !z && index($0, c) {z=NR; exit}
    END {exit !(x && y && (c == "" || z))}' <<<"$1"
}
checks() {
  local m=$1 present tiles follow edrnow guest look read tag frame changed wanted
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  tiles=$(body "$m" 'static int cocoa_gl_present_tiles(GLuint src, bool flip)')
  follow=$(body "$m" 'static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)')
  edrnow=$(body "$m" 'static double omacvm_edr_now(void)')
  guest=$(body "$m" 'static double omacvm_hdr_guest_edr(uint32_t display, double current, double potential,')
  look=$(body "$m" 'static void omacvm_hdr_look(GLuint src, uint32_t w, uint32_t h)')
  read=$(body "$m" 'static void omacvm_hdr_read(int64_t now, bool in_present)')
  tag=$(body "$m" 'static void omacvm_hdr_tag(IOSurfaceRef s)')
  frame=$(body "$m" 'static void omacvm_hdr_frame(GLuint src, uint32_t w, uint32_t h, bool pq)')
  changed=$(body "$m" 'static void omacvm_hdr_changed(int64_t now, bool redraw)')
  wanted=$(body "$m" 'static bool omacvm_hdr_wanted(void)')
  chk "the rules are included" grep -q '#include "ui/omacvm-hdr-tag.h"' "$m"
  chk "the look runs in the present, before surface n is taken and before the tiles" order "$present" \
    'omacvm_hdr_frame(src, w, h, !splash && pq && present_deep && !present_linear &&' \
    'unsigned n = (present_next + i) % present_nsurf;' 'cocoa_gl_present_tiles(src, flip) >= 0'
  chk "the look runs only in the present (never out of sight)" \
    test "$(grep -c 'omacvm_hdr_frame(src, w, h,' "$m")" = 1
  chk "a whole frame's surface is tagged before Core Animation sees it" order "$present" \
    'IOSurfaceRef surf = present_surf[n];' 'omacvm_hdr_tag(surf);' 'IOSurfaceIncrementUseCount(surf);'
  chk "a tile's surface is tagged before Core Animation sees it" order "$tiles" \
    'IOSurfaceRef s = present_tsurf[tl[k]][bi[k]];' 'omacvm_hdr_tag(s);' 'IOSurfaceIncrementUseCount(s);'
  chk "a change of tag is a whole frame (no tiles over a base of the other tag)" has "$present" \
    '(uint64_t)(qatomic_read(&omacvm_hdr_need_c) > 0) << 8 |'
  chk "a PQ surface is tagged 1x" has "$tag" 'IOSurfaceSetValue(s, kIOSurfaceContentHeadroom, (CFNumberRef)@(1.0));'
  chk "a PQ surface showing HDR is untagged" has "$tag" 'IOSurfaceRemoveValue(s, kIOSurfaceContentHeadroom);'
  chk "only PQ surfaces are tagged (extra brightness keeps its 2x)" has "$tag" \
    'if (!present_deep || present_linear || present_color != 1 ||'
  chk "each layer follows its own surface's tag (extra brightness keeps 2x)" order "$follow" \
    'CGFloat need = hdr && linear ? OMACVM_BRIGHT_TARGET : 0;' 'need = omacvm_hdr_surf_tag(surf);' \
    '[layer setContentsHeadroom:need];'
  chk "PQ frames start tagged 1x" order "$frame" \
    'if (pq && (!omacvm_hdr.active || gen != omacvm_hdr.display_gen)) {' \
    'omacvm_hdr_need_reset(&omacvm_hdr.n);' 'qatomic_set(&omacvm_hdr_need_c, 100);'
  chk "the look is the header's shader in two passes" has "$look" 'glUniform2i(omacvm_hdr.u_size, k ? w1 : (GLint)w, k ? h1 : (GLint)h);'
  chk "the shader is the tested one" \
    grep -q 'omacvm_hdr_shader(GL_FRAGMENT_SHADER, OMACVM_HDR_PEAK_FRAG);' "$m"
  chk "the look reads back into a buffer, no wait for the GPU" order "$look" \
    'glBindBuffer(GL_PIXEL_PACK_BUFFER, omacvm_hdr.pbo);' \
    'glReadPixels(0, 0, omacvm_hdr.rw, omacvm_hdr.rh, GL_RED, GL_FLOAT, 0);' \
    'timer_mod(omacvm_hdr.timer, now + OMACVM_HDR_LOOK_NS / 2);'
  chk "the look runs at most 4 times a second" has "$look" 'now - omacvm_hdr.look_ns < OMACVM_HDR_LOOK_NS'
  chk "the result goes through the rule" order "$read" \
    'double peak = omacvm_hdr_pq_units(m);' 'changed = omacvm_hdr_need_peak(&omacvm_hdr.n, peak, now);' \
    'changed |= omacvm_hdr_need_tick(&omacvm_hdr.n, now);'
  chk "the hold ends on a timer, also with no new frame" order "$read" \
    'int64_t due = omacvm_hdr_need_due(&omacvm_hdr.n);' 'timer_mod(omacvm_hdr.timer, due);'
  chk "a change of tag redraws the newest frame" order "$changed" \
    'qatomic_set(&omacvm_hdr_need_c, one ? 100 : 0);' 'gl_dirty = true;' 'cocoa_gl_present_request();'
  chk "a change of tag says so in qemu.log" has "$changed" '"cocoa: HDR: SDR frames (peak %.2fx), asking macOS for 1x"'
  chk "the guest's headroom comes from the rule" has "$guest" \
    'double v = omacvm_edr_guest(&omacvm_edr_hold, &new_display, display, current, potential,'
  chk "the guest's headroom is the window's display's" has "$edrnow" \
    'return omacvm_hdr_guest_edr(omacvm_screen_id(s),'
  chk "the test display goes through the rule too" has "$edrnow" \
    'return omacvm_hdr_guest_edr(0, hook_n, hook_p, false);'
  chk "no headroom is sent around the rule" lacks "$edrnow" 'return omacvm_edr_value('
  chk "a new display tags PQ frames 1x again" has "$guest" 'qatomic_inc(&omacvm_hdr_display_gen);'
  chk "OMACVM_HDR_SDR_TAG=0 keeps 3.2.22's untagged frames" has "$wanted" 'getenv("OMACVM_HDR_SDR_TAG")'
  chk "OMACVM_HDR_SDR_TAG=0 keeps 3.2.22's guest headroom" order "$guest" \
    'getenv("OMACVM_HDR_SDR_TAG")' 'return omacvm_edr_value(current, potential, use_potential);'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hdr-sdr-tag.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    # 3.2.22's code these checks look at.
    cat > "$T/old.m" <<'EOF'
#include "ui/omacvm-edr.h"
static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)
{
    if (@available(macOS 26.0, *)) {
        CGFloat need = hdr && linear ? OMACVM_BRIGHT_TARGET : 0;
        if ([layer contentsHeadroom] != need) {
            [layer setContentsHeadroom:need];
        }
    }
}
static int cocoa_gl_present_tiles(GLuint src, bool flip)
{
        IOSurfaceRef s = present_tsurf[tl[k]][bi[k]];
        CFRetain(s);
        IOSurfaceIncrementUseCount(s);
}
static bool cocoa_gl_present(void)
{
    int gain = qatomic_read(&omacvm_bright_gain_c);
        if (cocoa_gl_present_tiles(src, flip) >= 0) {
        }
    unsigned n = (present_next + i) % present_nsurf;
    IOSurfaceRef surf = present_surf[n];
    IOSurfaceIncrementUseCount(surf);
}
static double omacvm_edr_now(void)
{
    if (omacvm_bright_test_edr(&hook_p, &hook_n)) {
        return omacvm_edr_value(hook_n, hook_p, false);
    }
    return omacvm_edr_value([s maximumExtendedDynamicRangeColorComponentValue],
                            [s maximumPotentialExtendedDynamicRangeColorComponentValue],
                            e && !strcmp(e, "potential"));
}
EOF
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
  if [[ -n $out ]]; then echo "test-hdr-sdr-tag: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-hdr-sdr-tag: $1: wiring ok"
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hdr-sdr-tag.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-hdr-headroom-logic.patch" || exit 1
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-hdr-sdr-tag-logic.patch" || exit 1
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-hdr-sdr-tag.c" -o "$work/t" -lm || exit 1
"$work/t" || exit 1
"$work/t" --self-test || exit 1
# The peak shader: Apple's software renderer only (never a real GPU: STANDARDS 14).
cc -fobjc-arc -Wall -Wextra -Werror -I"$work/ui" "$here/test-hdr-sdr-tag-shader.m" \
  -framework Foundation -framework OpenGL -o "$work/shader" || exit 1
"$work/shader"
