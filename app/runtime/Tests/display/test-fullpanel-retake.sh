#!/bin/bash
# FullPanel after a display change (omacvm-cocoa-fullpanel-retake-logic.patch
# and omacvm-cocoa-fullpanel-retake.patch): the rules of
# ui/omacvm-fullpanel-retake.h and the user's qemu.log (the built-in display
# gone and back with an external one on: the strip beside the notch stayed
# away) replayed through a C copy of the window's FullPanel state
# (test-fullpanel-retake.c). No QEMU, no display, no notch.
#   test-fullpanel-retake.sh                the rules and the rows (CI)
#   test-fullpanel-retake.sh <ui/cocoa.m>   also the wiring in the patched file (the runtime build)
#   test-fullpanel-retake.sh --self-test    the user's rows fail with 3.2.10's decisions and the
#                                           wiring checks fail on 3.2.10's methods (copied) (CI)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fullpanel-retake.XXXXXX")
trap 'rm -rf "$work"' EXIT

body() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
flat() { tr -s ' \n' '  '; }

# What the wiring must have; one line per problem.
problems() {
  local m=$1 claims frame screen facts retake ask again new taken expired give reshape space own uses all soon fired moving locked engage release check_ret b f
  grep -q '^#include "ui/omacvm-fullpanel-retake.h"$' "$m" || echo "the retake rules are not included"
  claims=$(body "$m" '- (bool)claimsStrip')
  grep -q 'omacvm_fp_claims(inside, armed, rejected, lost, omacvm_fullpanel_menu_failed,' <<<"$claims" &&
    ! grep -q 'released' <<<"$claims" || echo "the claim waits for the resume (released), not omacvm_fp_claims"
  frame=$(body "$m" '- (void)frameChanged:(NSNotification *)notification')
  grep -q 'switch (omacvm_fp_frame_kind(omacvm_fullpanel_covers(window),' <<<"$frame" &&
    ! grep -q 'omacvm_fp_lost(' <<<"$frame" || echo "a frame change is not sorted by omacvm_fp_frame_kind (a display change taken for a lost strip)"
  awk '/case OMACVM_FP_FRAME_DISPLACED:/{d=1} d && /displaced = true;/{a=1} d && a && /\[self retakeNewChange\];/{ok=1} /case OMACVM_FP_FRAME_LOST:/{d=0} END{exit !ok}' <<<"$frame" &&
    grep -q '"omacvm: full panel: display change: frame ' <<<"$frame" || echo "a displaced frame does not note the display change"
  # Back inside its live display (or on a display with a housing again): the next displacement is a new change.
  awk '/case OMACVM_FP_FRAME_WAIT:/{w=1} w && /if \(within && live\) \{/{i=1} i && /displaced = false;/{ok=1; exit} END{exit !ok}' <<<"$frame" ||
    echo "a frame back inside its display does not end the displacement (a later display change gets no tries)"
  grep -q 'lost_at = omacvm_ds_clock();' <<<"$frame" || echo "a lost strip does not note when"
  # The band after a display change is no Split View (also released, the resume before the resize); a tile is.
  grep -q 'bool tile = omacvm_fp_tile(omacvm_fullpanel_rect(actual), omacvm_fullpanel_rect(physical));' <<<"$frame" &&
    flat <<<"$frame" | grep -qF 'live, omacvm_fullpanel_same_display(screen, accepted_display), display_changed, tile))' &&
    grep -q 'lost_tile = tile;' <<<"$frame" ||
    echo "a frame change does not pass the display change and the tile shape (the band after a resume taken for Split View)"
  awk '/case OMACVM_FP_FRAME_DISPLACED:/{d=1} d && /relayout/{bad=1} /case OMACVM_FP_FRAME_LOST:/{d=0} END{exit bad}' <<<"$frame" ||
    echo "a displaced frame lays the guest out again (resize churn)"
  screen=$(body "$m" '- (void)screenChanged:(NSNotification *)notification')
  grep -q 'omacvm_fp_lost_to_display_change(' <<<"$screen" || echo "a strip lost just before a display change stays lost"
  flat <<<"$screen" | grep -qF '!omacvm_fullpanel_same_display(screen, accepted_display), lost_tile))' ||
    echo "a Split View tile lost just before a display change is turned into one"
  awk '/omacvm_fp_screen_releases\(/{r=1} r && /released = true;/{x=1} x && /\[self retakeNewChange\];/{ok=1; exit} END{exit !ok}' <<<"$screen" ||
    echo "a full screen on a display without a housing does not note the display change"
  [[ $(grep -c '\[self retakeNewChange\];' <<<"$screen") == 2 ]] && grep -q 'released = displaced = false;' <<<"$screen" ||
    echo "a strip lost to a display change or the resume does not note the display change"
  engage=$(body "$m" '- (bool)engage')
  grep -q 'bool taken = retake_pending && \[self retakeTaken\];' <<<"$engage" &&
    grep -q 'displaced = display_changed = false;' <<<"$engage" || echo "engage does not end the display change and say the try worked"
  awk '/\[self retakeTaken\]/{t=NR} /"omacvm: full panel: strip covered: /{c=NR} END{exit !(t && c && t < c)}' <<<"$engage" ||
    echo "'strip taken again' does not come before 'strip covered'"
  release=$(body "$m" '- (void)releaseSystemState')
  grep -q 'selector:@selector(retakeExpired)' <<<"$release" && grep -q 'retake_pending = false;' <<<"$release" ||
    echo "releaseSystemState leaves a try's check running"
  grep -q 'selector:@selector(retakeAgain)' <<<"$release" || echo "releaseSystemState leaves an ask again queued"
  # The retake itself: AppKit's tile relayout only, checked; nothing that moves windows or Spaces.
  facts=$(body "$m" '- (OmacVMFPRetakeFacts)retakeFacts')
  retake=$(body "$m" '- (void)retake:(const char *)why')
  ask=$(body "$m" '- (void)retakeAsk:(const char *)why')
  again=$(body "$m" '- (void)retakeAgain')
  new=$(body "$m" '- (void)retakeNewChange')
  taken=$(body "$m" '- (bool)retakeTaken')
  expired=$(body "$m" '- (void)retakeExpired')
  give=$(body "$m" '- (void)retakeGiveUp:(const char *)reason')
  reshape=$(body "$m" 'static bool omacvm_fullpanel_reshape(NSWindow *w)')
  space=$(body "$m" 'static id omacvm_fullpanel_tile_space(NSWindow *w)')
  b=$(body "$m" 'static bool omacvm_fullpanel_appkit_band(NSWindow *w)')
  all=$(body "$m" 'static void omacvm_fullpanel_retake_all(const char *why)')
  soon=$(body "$m" 'static void omacvm_fullpanel_retake_soon(void)')
  for f in facts retake ask again new taken expired give reshape space b all soon; do
    [[ -n ${!f} ]] || { echo "no retake ($f)"; return; }
  done
  if grep -E 'toggleFullScreen|setFrame|makeKey|orderFront|orderOut|activate|setPresentationOptions|SLS|CGS|Space\(|omacvm_fullpanel_backdrop|method_setImplementation' \
       <<<"$facts$retake$ask$again$new$taken$expired$give$reshape$space$b$all$soon" >/dev/null; then
    echo "the retake moves a window, a Space or the menu bar itself"
  fi
  [[ $(grep -c 'method_setImplementation(' "$m") == 1 ]] || echo "more than the reservation method is replaced"
  own=$(body "$m" 'static IMP omacvm_fullpanel_own_method(const char *cls_name, const char *name, const char *want,' | flat)
  grep -q 'omacvm_fullpanel_in_image(method_getImplementation(m), c)' <<<"$own" &&
    grep -q 'class_getInstanceMethod(parent, method_getName(m)) == m' <<<"$own" &&
    grep -q 'strcmp(has, want)' <<<"$own" || echo "AppKit's methods are not checked for types, own method and AppKit's image"
  f=$(flat < "$m")
  for want in 'omacvm_fullpanel_own_method("NSWindow", "_fullScreenContentController", "@16@0:8",' \
              'omacvm_fullpanel_own_method("_NSFullScreenContentController", "space", "@16@0:8",' \
              'omacvm_fullpanel_own_method("_NSFullScreenSpace", "updateTileShapeAndReshapeContents", "v16@0:8",' \
              'omacvm_fullpanel_own_method("_NSFullScreenSpace", "alwaysReservesSpaceForMenuBarInFullScreen", "B16@0:8",'; do
    grep -qF "$want" <<<"$f" || echo "not looked up by name and types: ${want#*(}"
  done
  uses=$(body "$m" 'static bool omacvm_fullpanel_uses(id obj, Class cls, SEL sel, IMP imp)')
  grep -q 'class_getMethodImplementation(object_getClass(obj), sel) == imp' <<<"$uses" ||
    echo "an object whose class changed AppKit's method is still used"
  grep -q '\[NSThread isMainThread\]' <<<"$reshape" && grep -q '@try' <<<"$reshape" ||
    echo "AppKit's tile relayout is not main thread only and caught"
  grep -q 'omacvm_fp_band_kept(' <<<"$facts" && grep -q 'omacvm_fullpanel_compositor(window) == 1' <<<"$facts" &&
    grep -q 'omacvm_fullpanel_displays_locked()' <<<"$facts" && grep -q 'omacvm_fullpanel_displays_moving()' <<<"$facts" &&
    grep -q 'omacvm_fp_menu_bar_in_the_way(always, immersive_mode_enabled)' <<<"$facts" &&
    grep -q 'omacvm_fp_band_tall(' <<<"$facts" &&
    grep -q 'omacvm_fullpanel_hook_state() == OMACVM_FP_HOOK_USABLE' <<<"$facts" ||
    echo "a retake's facts miss the band, WindowServer, the lock, the moving windows, the menu bar or the reservation"
  awk '/omacvm_fp_retake\(f, &reason\)/{n++} /omacvm_fullpanel_appkit_band\(window\)/{a=NR; if (n != 1) bad=1} END{exit bad || !a}' <<<"$ask" ||
    echo "AppKit's Space is asked before the rules say now"
  grep -q 'retake_tries++;' <<<"$ask" && grep -q 'retake_settle = omacvm_fullpanel_settles;' <<<"$ask" &&
    grep -q 'retake_tried = true;' <<<"$ask" &&
    grep -q 'performSelector:@selector(retakeExpired) withObject:nil afterDelay:OMACVM_FP_RETAKE_CHECK_S' <<<"$ask" ||
    echo "a try is not counted or not checked"
  # Asked again after a wait nothing else ends, as the rules say, bounded; a trigger drops a queued one.
  awk '/if \(omacvm_fp_retake_reask\(f, r, retake_reasks\)\) \{/{r=1} r && /performSelector:@selector\(retakeAgain\) withObject:nil afterDelay:OMACVM_FP_RETAKE_REASK_S/{ok=1; exit} END{exit !ok}' <<<"$ask" &&
    grep -q 'selector:@selector(retakeAgain)' <<<"$retake" && grep -q 'retake_reasks = 0;' <<<"$retake" &&
    grep -q '\[self retakeAsk:why\];' <<<"$retake" && grep -q 'retake_reasks++;' <<<"$again" &&
    grep -q '\[self retakeAsk:"a moment later"\];' <<<"$again" ||
    echo "a wait nothing else ends is not asked again as the rules say (or a trigger keeps a queued one)"
  # Tries per display change: every new one (displaced, released, a loss that went with it) starts them
  # again, also after "strip not back"; one try per settle stays (its settle is not reset).
  grep -q 'display_changed = true;' <<<"$new" && grep -q 'retake_tries = retake_reasks = 0;' <<<"$new" &&
    grep -q 'retake_given_up = false;' <<<"$new" && ! grep -q 'retake_tried\|retake_settle' <<<"$new" &&
    [[ $(grep -c '\[self retakeNewChange\];' "$m") == 3 && $(grep -c 'display_changed = true' "$m") == 1 ]] ||
    echo "a new display change does not start its own tries (or not only there)"
  grep -q '\.tried_this_settle = retake_tried && retake_settle == omacvm_fullpanel_settles,' <<<"$facts" ||
    echo "one try per settle ends with the tries of a display change"
  grep -q 'strcmp(reason, OMACVM_FP_WHY_BAND_TALL)' <<<"$give" || echo "'strip not back' below a taller band does not say both heights"
  # Called from the three triggers only: the settled update, the displays' windows done, a return.
  [[ $(grep -c 'omacvm_fullpanel_retake_all(' "$m") == 3 ]] && [[ $(grep -c '\[self retake:' "$m") == 1 ]] &&
    [[ $(grep -c 'omacvm_fullpanel_retake_soon();' "$m") == 1 ]] && [[ $(grep -c '\[self retakeAsk:' "$m") == 2 ]] &&
    [[ $(grep -c '@selector(retakeAgain)' "$m") == 3 ]] || echo "the retake is asked from somewhere else"
  fired=$(body "$m" 'static void omacvm_ds_fired(void)')
  awk '/omacvm_ds_done\(/{d=NR} /omacvm_fullpanel_settles\+\+;/{s=NR} /if \(retry <= 0\) \{/{r=NR} /omacvm_fullpanel_retake_all\("the displays settled"\);/{a=NR} END{exit !(d && s && r && a && d < s && s < r && r < a)}' <<<"$fired" ||
    echo "the settled display update does not ask (after its done, when nothing is due)"
  awk '/^- \(void\)windowDidEnterFullScreen:\(NSNotification \*\)note$/{on=1} on && /omacvm_fullpanel_retake_soon\(\);/{ok=1} on && /^}$/{exit} END{exit !ok}' "$m" ||
    echo "the head delegate does not ask once the displays' windows are in full screen"
  check_ret=$(body "$m" '- (void)checkReturn')
  grep -q 'retake_asked = true;' <<<"$check_ret" && grep -q '\[self retake:"back on its Space"\];' <<<"$check_ret" ||
    echo "a return to the VM's Space does not ask once"
  moving=$(body "$m" 'static bool omacvm_fullpanel_displays_moving(void)')
  locked=$(body "$m" 'static bool omacvm_fullpanel_displays_locked(void)')
  grep -q 'omacvm_ds_timer.armed || omacvm_ds_timer.running || omacvm_full_busy' <<<"$moving" &&
    grep -q 'omacvm_heads_leaving count' <<<"$moving" && grep -q 'return omacvm_ds_timer.locked;' <<<"$locked" ||
    echo "settled does not mean: no update due or running, no display window moving, not locked"
  # The lines: check reads "strip not back" (warns), not the display change or "taken again".
  grep -q '"omacvm: full panel: strip taken again after a display change' "$m" &&
    grep -q '"omacvm: full panel: strip not back after a display change' "$m" &&
    grep -q '"omacvm: full panel: display change: ' "$m" || echo "a retake line is missing"
  if grep -E '"omacvm: full panel: (display change|strip taken again|below the notch after)[^"]*normal full screen' "$m" >/dev/null; then
    echo "a line check reads as normal full screen is not one"
  fi
  grep -E '"omacvm: full panel: strip not back after a display change [^"]*normal full screen' "$m" >/dev/null ||
    echo "'strip not back' is not the line check reads"
}

patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-fullpanel-logic.patch" &&
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-display-settle-logic.patch" &&
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-fullpanel-retake-logic.patch" ||
  { echo "test-fullpanel-retake: the logic patches do not apply" >&2; exit 1; }

if [[ ${1:-} == --self-test ]]; then
  cc -std=c11 -Wall -Wextra -Werror -DOMACVM_RETAKE_STUB -I"$work/ui" -I"$here" \
    "$here/test-fullpanel-retake.c" -o "$work/stub" || exit 1
  out=$("$work/stub")
  if [[ $? == 0 ]] || [[ $(grep -c "^FAIL the user's log" <<<"$out") != 4 ]]; then
    echo "FAIL the user's rows do not fail with 3.2.10's decisions" >&2
    exit 1
  fi
  echo "ok   the user's rows fail with 3.2.10's decisions ($(grep -c '^FAIL' <<<"$out") rows)"
  # 3.2.10's claimsStrip, frameChanged:, omacvm_ds_fired and the hook's line, copied verbatim from
  # its patched ui/cocoa.m (the whole file fails these checks too: checked 2026-10-28).
  cat > "$work/old.m" <<'EOF'
- (bool)claimsStrip
{
    return window && inside && armed && !rejected && !lost && !released &&
           !omacvm_fullpanel_menu_failed && omacvm_fullpanel_notch(window);
}
- (void)frameChanged:(NSNotification *)notification
{
    NSScreen *screen = [window screen];
    bool covers;

    if (!armed || !inside || !omacvm_fullpanel_in_full_screen(window)) {
        return;
    }
    if (!accepted) {
        [self verify:false];
    } else if (entered && !lost && !released && screen) {
        covers = omacvm_fullpanel_covers(window);
        if (covers) {
            accepted_display = [screen frame];
        } else if (omacvm_fp_lost(accepted, true, covers,
                                  omacvm_fullpanel_same_display(screen, accepted_display))) {
            NSRect actual = [window frame], physical = [screen frame];

            lost = true;
            [self releaseSystemState];
            fprintf(stderr, "omacvm: full panel: strip lost: frame (%.0f %.0f %.0fx%.0f) on display (%.0f %.0f %.0fx%.0f); normal full screen until the next one\n",
                    actual.origin.x, actual.origin.y, actual.size.width, actual.size.height,
                    physical.origin.x, physical.origin.y, physical.size.width, physical.size.height);
            [self relayout];
            return;
        }
    }
    [self comeBack];
}
static void omacvm_ds_fired(void)
{
    double at, retry;

    switch (omacvm_ds_fire(&omacvm_ds_timer, omacvm_ds_clock(), &at)) {
    case OMACVM_DS_REARM:
        omacvm_ds_arm(at);
        return;
    case OMACVM_DS_SKIP:
        return;
    case OMACVM_DS_RUN:
        break;
    }
    retry = omacvm_displays_apply();
    if (omacvm_ds_done(&omacvm_ds_timer, omacvm_ds_clock(), retry, &at)) {
        omacvm_ds_arm(at);
    }
}
        method_setImplementation(reserves, omacvm_fullpanel_reservation);
EOF
  if [[ -n $(problems "$work/old.m") ]]; then
    echo "ok   the wiring checks fail on 3.2.10's code (its methods, copied)"
    exit 0
  fi
  echo "FAIL the wiring checks pass on 3.2.10's code" >&2
  exit 1
fi

cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-fullpanel-retake.c" -o "$work/test" || exit 1
"$work/test" || exit 1
(( $# )) || exit 0
m=$1
out=$(problems "$m")
if [[ -n $out ]]; then
  echo "test-fullpanel-retake: $m: $out" >&2
  exit 1
fi
echo "test-fullpanel-retake: $m: wiring ok"
