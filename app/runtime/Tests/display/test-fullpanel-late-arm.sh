#!/bin/bash
# FullPanel armed late (#716, omacvm-cocoa-fullpanel-late-arm-logic.patch and
# omacvm-cocoa-fullpanel-late-arm.patch): a full screen entered on a display
# without a camera housing (the lid closed at the start) takes the strip once
# its Space is on the MacBook's display. The rules of ui/omacvm-fullpanel-late.h
# (test-fullpanel-late-arm.c; the window's state replayed with a late entry is
# in test-fullpanel-retake.c), and the wiring in the patched ui/cocoa.m. No
# QEMU, no display, no notch.
#   test-fullpanel-late-arm.sh                the rules (CI)
#   test-fullpanel-late-arm.sh <ui/cocoa.m>   also the wiring in the patched file (the runtime build)
#   test-fullpanel-late-arm.sh --self-test    the wiring checks fail on the code before the patch (copied) (CI)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fullpanel-late.XXXXXX")
trap 'rm -rf "$work"' EXIT

body() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
flat() { tr -s ' \n' '  '; }

# What the wiring must have; one line per problem.
problems() {
  local m=$1 will did ending verify claims fits screen init f
  will=$(body "$m" '- (void)willEnterFullScreen')
  did=$(body "$m" '- (void)didEnterFullScreen:(NSNotification *)notification')
  claims=$(body "$m" '- (bool)claimsStrip')
  [[ -n $will && -n $did && -n $claims ]] || { echo "no FullPanel state"; return; }
  grep -q '^#include "ui/omacvm-fullpanel-late.h"$' "$m" || echo "the late rules are not included"
  # The way in: the main window only, what a display with a housing would say, one rule.
  grep -q 'bool main_window = !\[window isKindOfClass:objc_getClass("OmacVMHeadWindow")\];' <<<"$will" ||
    echo "the main window is not told from the other displays' windows"
  flat <<<"$will" | grep -qF 'with_housing = omacvm_fp_fallback(1, in_the_way, omacvm_fullpanel_install_reservation(),' ||
    echo "a display with a housing is not asked about the other parts"
  grep -q 'entry = omacvm_fp_entry(fallback, with_housing, main_window);' <<<"$will" &&
    grep -q 'fallback = omacvm_fp_entry_why(fallback, with_housing, main_window);' <<<"$will" ||
    echo "the way in is not decided by omacvm_fp_entry (or the line does not name why)"
  # Late: armed, released, its own display change; reveal as for the strip now.
  awk '/armed = true;/{a=NR} /reveal = !immersive_mode_enabled;/{r=NR} /if \(entry == OMACVM_FP_ENTRY_LATE\) \{/{e=NR}
       /late = released = true;/{l=NR} /\[self retakeNewChange\];/{n=NR}
       END{exit !(a && r && e && l && n && a < e && r < e && e < l && l < n)}' <<<"$will" ||
    echo "a late entry is not armed, released and a display change of its own"
  if grep -E '"omacvm: full panel: in full screen on a display without[^"]*(normal full screen|strip covered|strip lost|display change:)' <<<"$will" >/dev/null; then
    echo "the late line is one omacvm check reads"
  fi
  grep -q '"omacvm: full panel: in full screen on a display without a camera housing' <<<"$will" ||
    echo "a late entry says nothing"
  if grep -E 'toggleFullScreen|setFrame|makeKey|orderFront|orderOut|setPresentationOptions|SLS|CGS|omacvm_fullpanel_backdrop' <<<"$will" >/dev/null; then
    echo "the way in moves a window, a Space or the menu bar"
  fi
  # Entered: with the strip or late (the retake and the frame sorting need it).
  grep -q 'if (!omacvm_fp_entered(armed, accepted, late)) {' <<<"$did" && ! grep -q 'if (!armed || !accepted)' <<<"$did" ||
    echo "didEnterFullScreen does not count a late entry as entered"
  ending=$(body "$m" '- (void)endFullScreen')
  grep -q '^    late = false;$' <<<"$ending" || echo "the next full screen keeps the late arm"
  verify=$(body "$m" '- (void)verify:(bool)definitive')
  awk '/accepted = true;/{a=NR} /late = false;/{l=NR} END{exit !(a && l && a < l)}' <<<"$verify" ||
    echo "a late full screen with the strip stays late"
  # The claim: only on a display of this start's panel size.
  grep -q '&& \[self lateFits\];' <<<"$claims" || echo "the claim does not check the panel's size"
  fits=$(body "$m" '- (bool)lateFits')
  flat <<<"$fits" | grep -qF 'omacvm_fp_late_fits(late, omacvm_fullpanel_panel_given, omacvm_fullpanel_panel_w, omacvm_fullpanel_panel_h,' ||
    echo "lateFits is not omacvm_fp_late_fits with the panel given"
  screen=$(body "$m" '- (void)screenChanged:(NSNotification *)notification')
  awk '/late && !rejected && omacvm_fp_screen_resumes\(released, full, omacvm_fullpanel_notch\(window\)\)/{s=NR}
       /!\[self lateFits\]\) \{/{f=NR} /rejected = true;/{r=NR} /released = displaced = false;/{if (!d) d=NR}
       /} else if \(omacvm_fp_screen_resumes\(released, full, omacvm_fullpanel_notch\(window\)\)\) \{/{u=NR}
       END{exit !(s && f && r && d && u && s < f && f < r && r < d && d < u)}' <<<"$screen" ||
    echo "a late full screen on another panel size is resumed (its bar would sit unsplit under the housing)"
  grep -q '"omacvm: full panel: the MacBook.s display is %.0fx%.0f now, [^"]*normal full screen' <<<"$screen" ||
    echo "another panel size is not the line omacvm check reads"
  grep -q '"omacvm: full panel: display change: the full screen is on a display with a camera housing again' <<<"$screen" ||
    echo "the resume says nothing (omacvm check would not warn until the strip is covered)"
  init=$(body "$m" 'static void omacvm_fullpanel_init(void)')
  flat <<<"$init" | grep -qF 'omacvm_fullpanel_panel_given = omacvm_fp_panel(getenv("OMACVM_FULLPANEL_PANEL"),' ||
    echo "the panel's size is not read at the start"
  [[ $(grep -c 'late = released = true;' "$m") == 1 && $(grep -c 'omacvm_fp_entered(' "$m") == 1 ]] ||
    echo "the late arm is made somewhere else too"
}

patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-fullpanel-logic.patch" &&
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-display-settle-logic.patch" &&
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-fullpanel-retake-logic.patch" &&
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-fullpanel-late-arm-logic.patch" ||
  { echo "test-fullpanel-late-arm: the logic patches do not apply" >&2; exit 1; }

if [[ ${1:-} == --self-test ]]; then
  # The methods before the patch, copied verbatim from the patched ui/cocoa.m of rc-3.4.0 (02e3a4e4).
  cat > "$work/old.m" <<'EOF'
#include "ui/omacvm-fullpanel-retake.h"
- (bool)claimsStrip
{
    return window && omacvm_fp_claims(inside, armed, rejected, lost, omacvm_fullpanel_menu_failed,
                                      omacvm_fullpanel_notch(window));
}
- (void)willEnterFullScreen
{
    NSScreen *screen = [window screen];
    double notch = screen ? [screen safeAreaInsets].top : 0;
    bool always = [[NSUserDefaults standardUserDefaults] boolForKey:@"AppleMenuBarVisibleInFullscreen"];
    OmacVMFPFallback fallback;

    [self releaseSystemState];
    [self endFullScreen];
    inside = true;
    fallback = omacvm_fp_fallback(notch, omacvm_fp_menu_bar_in_the_way(always, immersive_mode_enabled),
                                  notch > 0 && omacvm_fullpanel_install_reservation(),
                                  omacvm_fullpanel_skylight() && !omacvm_fullpanel_menu_failed);
    if (fallback != OMACVM_FP_OK) {
        if (!fallback_logged) {
            fallback_logged = true;
            if (omacvm_fp_fallback_checked(fallback, omacvm_fullpanel_beside_builtin(window))) {
                fprintf(stderr, "omacvm: full panel: %s: normal full screen\n",
                        omacvm_fp_fallback_text(fallback));
            } else {
                fprintf(stderr, "omacvm: full panel: a window on another display than the built-in one: macOS's own full screen there\n");
            }
        }
        return;
    }
    armed = true;
    reveal = !immersive_mode_enabled;
}
- (void)didEnterFullScreen:(NSNotification *)notification
{
    [self verify:true];
    if (!armed || !accepted) {
        return;
    }
    entered = true;
    /* The way in is no return from away. */
    away = false;
    return_from_away = false;
    [self engage];
}
EOF
  if [[ -n $(problems "$work/old.m") ]]; then
    echo "ok   the wiring checks fail on the code before the patch (its methods, copied)"
    exit 0
  fi
  echo "FAIL the wiring checks pass on the code before the patch" >&2
  exit 1
fi

cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-fullpanel-late-arm.c" -o "$work/test" || exit 1
"$work/test" || exit 1
(( $# )) || exit 0
m=$1
out=$(problems "$m")
if [[ -n $out ]]; then
  echo "test-fullpanel-late-arm: $m: $out" >&2
  exit 1
fi
echo "test-fullpanel-late-arm: $m: wiring ok"
