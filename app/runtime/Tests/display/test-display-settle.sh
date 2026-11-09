#!/bin/bash
# The VM's windows follow the Mac's displays once they settle (#428,
# omacvm-cocoa-display-settle-logic.patch, omacvm-cocoa-display-settle.patch):
# the patch makes ui/omacvm-display-settle.h in an empty folder and
# test-display-settle.c runs the report's bursts, the lock, a display at
# 1 x 1 and the full-screen loop against it (and the old per-window count,
# which must fail). Then the wiring checks catch the old code (--self-test
# part, always). With ui/cocoa.m as argument (the runtime build, after the
# wiring patch): also that the patched file is wired as tested.
#   test-display-settle.sh                       (CI)
#   test-display-settle.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-display-settle.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-display-settle-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-display-settle.c" -o "$work/t"
"$work/t"

body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
bodyx() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 update apply fired fullnext headon headoff resize resizeDid screenChange params check uiinfo watch
  update=$(bodyx "$m" 'static void omacvm_displays_update(void)')
  apply=$(bodyx "$m" 'static double omacvm_displays_apply(void)')
  fired=$(bodyx "$m" 'static void omacvm_ds_fired(void)')
  fullnext=$(bodyx "$m" 'static void omacvm_full_next(void)')
  headon=$(body "$m" 'static void omacvm_head_on(')
  headoff=$(bodyx "$m" 'static void omacvm_head_off(OmacVMHead *hd)')
  resize=$(bodyx "$m" '- (void) resizeWindow')
  resizeDid=$(awk '/^@implementation QemuCocoaAppController/{on=1} on&&/^- \(void\)windowDidResize:/{w=1} w{print} w&&/^}$/{exit}' "$m")
  screenChange=$(body "$m" '- (void)windowDidChangeScreen:')
  check=$(bodyx "$m" '- (void) omacvmCheckGuestTop')
  uiinfo=$(bodyx "$m" '- (void) updateUIInfo')
  watch=$(bodyx "$m" 'static void omacvm_ds_watch_lock(void)')
  [[ -n $update && -n $fullnext && -n $headon && -n $resize ]] || { echo "the display code is missing"; return; }
  grep -q '#include "ui/omacvm-display-settle.h"' "$m" || echo "ui/omacvm-display-settle.h is not used"
  # One update path: changes ask the timer; only the timer runs the update.
  grep -q 'omacvm_ds_ask(&omacvm_ds_timer' <<<"$update" || echo "a display change runs the update at once"
  ! grep -q 'omacvm_head_on\|omacvm_head_off' <<<"$update" || echo "omacvm_displays_update changes windows itself"
  [[ -n $apply && -n $fired ]] && grep -q 'retry = omacvm_displays_apply();' <<<"$fired" ||
    echo "the update does not run from the timer"
  [[ $(grep -c 'omacvm_displays_apply()' "$m") == 1 ]] || echo "the update runs from somewhere else than the timer"
  ! grep -q 'omacvm_displays_apply' <<<"$screenChange" || echo "a screen change runs the update at once"
  ! grep -q 'dispatch_get_main_queue(), ^{ omacvm_displays_update(); });' "$m" ||
    echo "a change waits on its own instead of the timer"
  # Displays that do not count are absent; a new one waits until it settles.
  grep -q 'double left = omacvm_ds_look(omacvm_ds_display(&omacvm_ds_known,' <<<"$apply" &&
    grep -q 'omacvm_display_key(id), now),' <<<"$apply" &&
    grep -q 'omacvm_screen_counts(s), now);' <<<"$apply" || echo "inactive or 1 x 1 displays get windows"
  grep -q 'omacvm_ds_listed(&omacvm_ds_known, listed, n);' <<<"$apply" || echo "an unplugged display keeps counting"
  grep -q 'hd->key = omacvm_display_key(hd->display);' <<<"$headon" || echo "tries are kept per display id, not per monitor"
  grep -q 'if (want && !omacvm_screen_counts(ms)) {' <<<"$apply" ||
    echo "windows move while the main window's display does not count"
  # Tries per display, never reset by a new window; none while locked.
  ! grep -q 'full_tries' "$m" || echo "full-screen tries are still counted per window"
  grep -q 'omacvm_ds_may_try(d, now, &wait)' <<<"$fullnext" && grep -q 'omacvm_ds_tried(d, now);' <<<"$fullnext" ||
    echo "full-screen tries are not counted per display"
  grep -q 'if (omacvm_full_busy || omacvm_ds_timer.locked) {' <<<"$fullnext" || echo "full screen is asked while locked"
  grep -q 'setAlphaValue:1.0' <<<"$fullnext" || echo "a display's window stays invisible when the tries end"
  # A window macOS is moving is not closed in the middle of it.
  grep -q 'omacvm_head_leave(hd->window);' <<<"$headoff" || echo "a display's window is closed while macOS moves it"
  # resizeWindow never inside itself; the size check after a resize later.
  grep -q 'if (busy) {' <<<"$resize" || echo "resizeWindow can run inside itself"
  grep -q 'omacvmCheckGuestTopSoon' <<<"$resizeDid" && ! grep -q 'omacvmCheckGuestTop\]' <<<"$resizeDid" ||
    echo "the main window is sized again inside its resize notification"
  grep -q 'if (refused >= 3) {' <<<"$check" || echo "a size macOS refuses is tried on every resize"
  grep -q 'omacvmScreenCounts' <<<"$uiinfo" || echo "the guest gets a size from a display that does not count"
  # The lock and sleep reach the app also in the background.
  [[ $(grep -c 'NSNotificationSuspensionBehaviorDeliverImmediately' <<<"$watch") -ge 2 ]] &&
    grep -q 'NSWorkspaceScreensDidSleepNotification' <<<"$watch" || echo "the lock or sleep is not watched"
  # What began before QEMU sends no notice: the lock, another user and sleeping displays are read at start.
  grep -q 'omacvm_ds_session(&omacvm_ds_screen_locked, &omacvm_ds_away);' <<<"$watch" &&
    grep -q 'omacvm_ds_asleep = CGDisplayIsAsleep(CGMainDisplayID());' <<<"$watch" &&
    grep -q 'if (omacvm_ds_screen_locked || omacvm_ds_away || omacvm_ds_asleep) {' <<<"$watch" ||
    echo "a lock or sleep that began before the start is not read"
}

# The checks catch the old code (3.1.14's omacvm-cocoa-displays.patch).
cat > "$work/old.m" <<'EOF'
- (void) resizeWindow
{
    [[self window] setContentSize:area];
}
- (void)windowDidChangeScreen:(NSNotification *)notification
{
    omacvm_displays_update();
}
static void omacvm_head_on(OmacVMHead *hd, NSScreen *s)
{
    hd->want_full = true;
    hd->full_tries = 0;
}
static void omacvm_full_next(void)
{
    if (omacvm_full_busy) {
        return;
    }
    if (++hd->full_tries > 5) {
        [hd->window setAlphaValue:1.0];
    }
}
static void omacvm_displays_update(void)
{
    omacvm_head_on(&omacvm_heads[i], s);
}
EOF
old=$(problems "$work/old.m")
for want in "a display change runs the update at once" "per window" "resizeWindow can run inside itself" \
            "closed while macOS moves it" "asked while locked"; do
  [[ $old == *"$want"* ]] || { echo "test-display-settle: the checks miss the old code: $want" >&2; exit 1; }
done

(( $# )) || exit 0
m=$1
out=$(problems "$m")
if [[ -n $out ]]; then echo "test-display-settle: $m: $out" >&2; exit 1; fi
echo "test-display-settle: $m: wiring ok"
