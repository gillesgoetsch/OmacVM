#!/bin/bash
# HDR frames get EDR only while they show HDR (ADR 0049, amended;
# omacvm-cocoa-hdr-sdr-tag-logic.patch, omacvm-cocoa-hdr-sdr-tag.patch):
#   - the rules: the logic patches make ui/omacvm-edr.h and ui/omacvm-hdr-tag.h in an empty folder and
#     test-hdr-sdr-tag.c runs against them (EDR on/off, the hold, what a layer asks of macOS for a
#     surface, macOS 26+ only, the guest's headroom, a model of macOS's headroom ramp: no lock, no back
#     and forth), then --self-test of the model (3.2.22's rule, a guest told the current headroom, a 2 s
#     hold, 3.2.22's layer and a tone map that follows EDR must fail it);
#   - the peak shader on Apple's software renderer (test-hdr-sdr-tag-shader.m: one HDR pixel anywhere in
#     frames up to 5120x2880 reads back exactly);
#   - with a patched ui/cocoa.m: the wiring (the look in the present before surface n is taken and before
#     the tiles, every PQ surface flagged SDR or not before Core Animation sees it, whole frames and tiles
#     alike, no headroom tag on PQ, each layer's EDR from its surface's flag, tone map never on its own
#     condition, hidden tile layers drop EDR, a switch is a whole frame and a redraw, the hold's timer
#     (never at or before now: a timer in the past hangs QEMU), a look later for a frame no look saw,
#     the guest's headroom from the rule, macOS 26+ only, the look's read back without a wait, the
#     trace's commit numbers, OMACVM_HDR_SDR_TAG=0); it fails on 3.3.0's first try (a 1.0 tag);
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
lacks_with() { has "$1" "$3" && hasnt "$1" "$2"; }   # the new code ($3) is there, the old ($2) is not
order() {
  awk -v a="$2" -v b="$3" -v c="${4:-}" '
    !x && index($0, a) {x=NR; next}
    x && !y && index($0, b) {y=NR; if (c == "") exit; next}
    y && c != "" && !z && index($0, c) {z=NR; exit}
    END {exit !(x && y && (c == "" || z))}' <<<"$1"
}
checks() {
  local m=$1 present tiles follow edrnow guest look read arm tag frame changed wanted rule hide trace
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  tiles=$(body "$m" 'static int cocoa_gl_present_tiles(GLuint src, bool flip)')
  follow=$(body "$m" 'static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)')
  edrnow=$(body "$m" 'static double omacvm_edr_now(void)')
  guest=$(body "$m" 'static double omacvm_hdr_guest_edr(uint32_t display, double current, double potential,')
  look=$(body "$m" 'static void omacvm_hdr_look(GLuint src, uint32_t w, uint32_t h)')
  read=$(body "$m" 'static void omacvm_hdr_read(int64_t now, bool in_present)')
  arm=$(body "$m" 'static void omacvm_hdr_arm(int64_t now)')
  tag=$(body "$m" 'static void omacvm_hdr_tag(IOSurfaceRef s)')
  frame=$(body "$m" 'static void omacvm_hdr_frame(GLuint src, uint32_t w, uint32_t h, bool pq)')
  changed=$(body "$m" 'static void omacvm_hdr_changed(int64_t now, bool redraw)')
  wanted=$(body "$m" 'static bool omacvm_hdr_wanted(void)')
  rule=$(body "$m" 'static bool omacvm_hdr_rule(void)')
  hide=$(body "$m" 'static void present_tiles_hide_locked(void)')
  trace=$(body "$m" 'static void omacvm_hdr_trace_layer(CALayer *layer, IOSurfaceRef surf)')
  chk "the rules are included" grep -q '#include "ui/omacvm-hdr-tag.h"' "$m"
  chk "the look runs in the present, before surface n is taken and before the tiles" order "$present" \
    'omacvm_hdr_frame(src, w, h, !splash && pq && present_deep && !present_linear &&' \
    'unsigned n = (present_next + i) % present_nsurf;' 'cocoa_gl_present_tiles(src, flip) >= 0'
  chk "the look runs only in the present (never out of sight)" \
    test "$(grep -c 'omacvm_hdr_frame(src, w, h,' "$m")" = 1
  chk "a whole frame's surface gets its SDR flag before Core Animation sees it" order "$present" \
    'IOSurfaceRef surf = present_surf[n];' 'omacvm_hdr_tag(surf);' 'IOSurfaceIncrementUseCount(surf);'
  chk "a tile's surface gets its SDR flag before Core Animation sees it" order "$tiles" \
    'IOSurfaceRef s = present_tsurf[tl[k]][bi[k]];' 'omacvm_hdr_tag(s);' 'IOSurfaceIncrementUseCount(s);'
  chk "a switch is a whole frame (no tiles over a base in the other state)" has "$present" \
    '(uint64_t)(qatomic_read(&omacvm_hdr_need_c) > 0) << 8 |'
  chk "a PQ surface with an SDR frame gets the private SDR flag" has "$tag" \
    'IOSurfaceSetValue(s, CFSTR(OMACVM_HDR_SURF_SDR_KEY), kCFBooleanTrue);'
  chk "a PQ surface showing HDR loses the flag" has "$tag" \
    'IOSurfaceRemoveValue(s, CFSTR(OMACVM_HDR_SURF_SDR_KEY));'
  chk "only PQ surfaces are flagged SDR (extra brightness keeps its EDR)" has "$tag" \
    'bool sdr = omacvm_hdr_on == 1 && present_deep && !present_linear && present_color == 1 &&'
  chk "no headroom tag on PQ surfaces (macOS ignores 1.0)" lacks "$tag" 'kIOSurfaceContentHeadroom'
  chk "nothing tags a surface 1.0" test "$(grep -c 'kIOSurfaceContentHeadroom, (CFNumberRef)@(1.0)' "$m")" = 0 -a -n "$tag"
  chk "each layer's EDR comes from its own surface's SDR flag" order "$follow" \
    'OmacvmHdrLayer want = omacvm_hdr_layer(colour, linear, colour && omacvm_hdr_surf_sdr(surf));' \
    'BOOL hdr = want.edr;' '[layer setWantsExtendedDynamicRangeContent:hdr];'
  chk "tone map never on its own condition (SDR white stays 1.0 with EDR off)" order "$follow" \
    'CAToneMapMode tm = want.never ? CAToneMapModeNever : CAToneMapModeAutomatic;' \
    'if (![[layer toneMapMode] isEqualToString:tm]) {' '[layer setToneMapMode:tm];'
  chk "tone map is not tied to EDR" lacks "$follow" '[layer setToneMapMode:hdr ?'
  chk "the layer's headroom: 2x for extra brightness only, PQ untagged" order "$follow" \
    'omacvm_hdr_layer(colour, linear,' 'CGFloat need = hdr && linear ? OMACVM_BRIGHT_TARGET : 0;' \
    '[layer setContentsHeadroom:need];'
  chk "the layer's headroom is not the surface's tag" lacks_with "$follow" 'need = omacvm_hdr_surf_tag(surf);' \
    'omacvm_hdr_layer(colour, linear,'
  chk "hidden tile layers drop EDR" order "$hide" '[l setHidden:YES];' \
    '[l setWantsExtendedDynamicRangeContent:NO];'
  chk "every transaction that shows a frame or hides tiles has a commit number for the trace" \
    test "$(grep -c '^ *omacvm_hdr_commit_begin();$' "$m")" = 4
  chk "the trace names the commit and the surface's SDR flag" has "$trace" \
    '"cocoa: hdr-trace: commit %u %s layer %p surface %u %s sdr %d edr %d "'
  chk "PQ frames start SDR (no EDR)" order "$frame" \
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
    'changed |= omacvm_hdr_need_tick(&omacvm_hdr.n, now);' 'omacvm_hdr_arm(now);'
  chk "the hold's timer is never set at or before now (QEMU runs it again and again: a hang)" order "$arm" \
    'int64_t due = omacvm_hdr_need_due(&omacvm_hdr.n);' 'due = omacvm_hdr_timer_at(due, now);' \
    'timer_mod(omacvm_hdr.timer, due);'
  chk "the result sets the timer only through omacvm_hdr_arm" lacks_with "$read" 'timer_mod(' 'omacvm_hdr_arm(now);'
  chk "the look's timer and omacvm_hdr_arm's are the only ones" \
    test "$(grep -c 'timer_mod(omacvm_hdr.timer,' "$m")" = 2 -a -n "$arm"
  chk "a frame no look saw sets the timer" order "$look" \
    'omacvm_hdr.skipped = true;' 'omacvm_hdr_arm(now);' 'omacvm_hdr.skipped = false;'
  chk "the timer has a frame no look saw drawn again for one" order "$read" \
    'now - omacvm_hdr.look_ns >= OMACVM_HDR_RELOOK_NS) {' 'cocoa_gl_present_request();' 'omacvm_hdr_arm(now);'
  chk "the timer for a frame no look saw is the hold's timer" has "$arm" \
    'int64_t re = omacvm_hdr.look_ns + OMACVM_HDR_RELOOK_NS;'
  chk "a switch redraws the newest frame" order "$changed" \
    'qatomic_set(&omacvm_hdr_need_c, one ? 100 : 0);' 'gl_dirty = true;' 'cocoa_gl_present_request();'
  chk "a switch says so in qemu.log" has "$changed" '"cocoa: HDR: SDR frames (peak %.2fx), EDR off"'
  chk "the guest's headroom comes from the rule" has "$guest" \
    'double v = omacvm_edr_guest(&omacvm_edr_hold, &new_display, display, current, potential,'
  chk "the guest's headroom is the window's display's" has "$edrnow" \
    'return omacvm_hdr_guest_edr(omacvm_screen_id(s),'
  chk "the test display goes through the rule too" has "$edrnow" \
    'return omacvm_hdr_guest_edr(0, hook_n, hook_p, false);'
  chk "no headroom is sent around the rule" lacks "$edrnow" 'return omacvm_edr_value('
  chk "a new display starts PQ frames SDR again" has "$guest" 'qatomic_inc(&omacvm_hdr_display_gen);'
  chk "the rule runs from macOS 26 only, and not with OMACVM_HDR_SDR_TAG=0" has "$rule" \
    'r = omacvm_hdr_rule_on((int)v.majorVersion, getenv("OMACVM_HDR_SDR_TAG"));'
  chk "the frames' EDR follows that (macOS 15: EDR on, as 3.2.22)" has "$wanted" \
    'omacvm_hdr_on = omacvm_hdr_rule();'
  chk "the guest's headroom follows that (macOS 15: 3.2.22's)" order "$guest" \
    'if (!omacvm_hdr_rule()) {' 'return omacvm_edr_value(current, potential, use_potential);'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hdr-sdr-tag.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    # 3.3.0's code these checks look at.
    cat > "$T/old.m" <<'EOF'
#include "ui/omacvm-edr.h"
static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)
{
    OSType fmt = IOSurfaceGetPixelFormat(surf);
    BOOL hdr = (fmt == 'RGhA' || fmt == '&RhA') &&
               present_color == 1 && (cocoa_gl_present_hdr_wanted() || linear);
    if ([layer wantsExtendedDynamicRangeContent] != hdr) {
        [layer setWantsExtendedDynamicRangeContent:hdr];
        [layer setToneMapMode:hdr ? CAToneMapModeNever : CAToneMapModeAutomatic];
    }
    if (@available(macOS 26.0, *)) {
        CGFloat need = hdr && linear ? OMACVM_BRIGHT_TARGET : 0;
        if ([layer contentsHeadroom] != need) {
            [layer setContentsHeadroom:need];
        }
    }
}
static void present_tiles_hide_locked(void)
{
        if (l && ![l isHidden]) {
            [l setHidden:YES];
            [l setContents:nil];
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
