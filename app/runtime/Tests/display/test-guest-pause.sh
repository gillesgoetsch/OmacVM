#!/bin/bash
# Pause drawing while hidden (omacvm-cocoa-guest-pause-logic.patch,
# omacvm-cocoa-guest-pause.patch): the patch makes ui/omacvm-guest-pause.h in
# an empty folder and test-guest-pause.c runs against it. With ui/cocoa.m as
# argument (the runtime build, after the wiring patch): also that the window's
# occlusion and the lock feed it, the guest is told, and the present keeps the
# last picture while the guest's display is off.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-guest-pause.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-guest-pause-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-guest-pause.c" -o "$work/test-guest-pause"
"$work/test-guest-pause"

(( $# )) || exit 0
m=$1
fail() { echo "test-guest-pause: $m: $*" >&2; exit 1; }
body() { awk -v h="$1" 'index($0, h) == 1 && !/;$/ {on=1} on {print} on && /^}$/ {exit}' "$m"; }
seen=$(body '- (void)omacvmWindowSeen:(NSNotification *)note')
lock=$(body 'static void omacvm_ds_lock_changed(const char *why)')
update=$(body 'static void omacvm_gp_update(void)')
tell=$(body 'static void omacvm_gp_tell(OmacVMGpTell tell)')
send=$(body 'static void omacvm_gp_send(OmacVMGpTell tell)')
again=$(body 'static void omacvm_gp_again_arm(void)')
ghello=$(body 'static void omacvm_gp_hello(NSDictionary *hello)')
close=$(body 'static void omacvm_chan_close(void)')
fire=$(body 'static void omacvm_gp_fire(unsigned gen)')
sw=$(body 'static void omacvm_gp_read_switch(void)')
present=$(body 'static bool cocoa_gl_present(void)')
off=$(body 'static void cocoa_gl_scanout_disable(DisplayChangeListener *dcl)')
flush=$(body 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,')
gfx=$(body 'static void cocoa_gl_update(DisplayChangeListener *dcl,')
frame=$(body 'static void omacvm_gp_guest_frame(void)')
hello=$(body 'static void omacvm_chan_line(NSData *data)')
init=$(body 'static void omacvm_displays_init(void)')
why=$(body 'static OmacVMGpWhy omacvm_gp_why(void)')
say=$(body 'static void omacvm_gp_say(OmacVMGpTell tell, OmacVMGpWhy why)')
write=$(body 'static void omacvm_chan_write(NSString *line)')
[[ -n $seen && -n $lock && -n $update && -n $tell && -n $send && -n $again && -n $ghello && -n $close && -n $fire &&
   -n $sw && -n $present && -n $off && -n $flush && -n $gfx && -n $frame && -n $hello && -n $init && -n $why &&
   -n $say && -n $write ]] || fail "a piece of the wiring is missing"
grep -q '#include "ui/omacvm-guest-pause.h"' "$m" || fail "the rules are not included"
# What feeds it: the occlusion, the lock and sleep, the start.
grep -q 'omacvm_gp_update();' <<<"$seen" && grep -q 'omacvm_gp_update();' <<<"$lock" &&
  grep -q 'omacvm_gp_update();' <<<"$init" || fail "the window's state does not reach the rules"
# A window hidden from the start sent no notice: its first one may match the old flag, so the rules are fed first.
awk '/omacvm_gp_update\(\);/ && !u {u = NR} /return;/ && !r {r = NR} END {exit !(u && r && u < r)}' <<<"$seen" ||
  fail "a window that first shows after a hidden start does not reach the rules"
# Seen = some of the window on screen and nobody locked out; OMACVM_PRESENT_HIDDEN draws anyway.
grep -q '\[w isVisible\] && (\[w occlusionState\] & NSWindowOcclusionStateVisible)' <<<"$update" &&
  grep -q 'bool seen = always || (on_screen && !omacvm_ds_screen_locked &&' <<<"$update" &&
  grep -q '!omacvm_ds_asleep && !omacvm_ds_away && !omacvm_ds_test_locked' <<<"$update" &&
  grep -q 'getenv("OMACVM_PRESENT_HIDDEN")' <<<"$update" || fail "seen is not worked out as tested"
grep -q 'tell = omacvm_gp_feed(&omacvm_gp, omacvm_gp_switch == 1 && omacvm_gp_able, seen, now);' <<<"$update" &&
  grep -q 'omacvm_gp_fire(gen)' <<<"$update" && grep -q 'tell = omacvm_gp_due(&omacvm_gp, CACurrentMediaTime());' <<<"$fire" &&
  grep -q 'gen != omacvm_gp_gen' <<<"$fire" || fail "the rules are not asked as tested"
# The switch: the app's key (live), else OMACVM_GUEST_PAUSE.
grep -q 'boolForKey:@"pauseWhileHidden"' <<<"$sw" && grep -q 'getenv("OMACVM_GUEST_PAUSE")' <<<"$sw" &&
  grep -q 'forKeyPath:@"pauseWhileHidden"' <<<"$update" || fail "the switch is not read as tested"
# The guest is told over the display channel, only an agent that says it can, a restarted agent again;
# the lease and "seen" again in case a line was dropped.
grep -q '{\\"unseen\\":\[\\"Virtual-1\\"\]}' <<<"$send" && grep -q '{\\"unseen\\":\[\]}' <<<"$send" &&
  grep -q 'omacvm_chan_write' <<<"$send" && grep -q '!omacvm_gp_able ? OMACVM_GP_NOT_ABLE' <<<"$why" &&
  grep -q 'OmacVMGpWhy why = omacvm_gp_why();' <<<"$send" && grep -q 'if (why == OMACVM_GP_SENT) {' <<<"$send" &&
  grep -q 'omacvm_gp_send(tell);' <<<"$tell" && grep -q 'omacvm_gp_again_arm();' <<<"$tell" &&
  grep -q 'omacvm_gp_hello(d);' <<<"$hello" || fail "the guest is not told as tested"
grep -q 'hello\[@"pause"\]' <<<"$ghello" && grep -q 'omacvm_gp_able = able;' <<<"$ghello" &&
  grep -q 'omacvm_gp_able = false;' <<<"$close" || fail "the agent's ability is not taken from its hello"
grep -q 'at = omacvm_gp_again_at(&omacvm_gp);' <<<"$again" && grep -q 'again = omacvm_gp_again(&omacvm_gp, CACurrentMediaTime());' <<<"$again" &&
  grep -q 'gen != omacvm_gp_again_gen' <<<"$again" || fail "the lease and the repeated 'seen' are not wired as tested"
# The present: after the unseen check, the last picture kept while the guest's display is off.
awk '/omacvm_frames_unseen\+\+;/ {a = NR} /if \(omacvm_gp_keep\(&omacvm_gp, gl_scanout_borrow != NULL, CACurrentMediaTime\(\)\)\) \{/ {b = NR}
     /if \(gl_scanout_borrow\) \{/ && !c {c = NR} END {exit !(a && b && c && a < b && b < c)}' <<<"$present" ||
  fail "the present does not keep the last picture before drawing without a scanout"
grep -q 'omacvm_gp_dark = true;' <<<"$off" && grep -q 'unsigned n = omacvm_gp_frame(&omacvm_gp);' <<<"$frame" &&
  grep -q 'omacvm: guest drawing: paused for' <<<"$frame" || fail "the guest's pause is not logged"
# qemu.log: every word for the guest and what became of it (a short write too), through the limiter;
# out of sight with nobody to tell, once it lasted as long as a pause would wait.
grep -q 'omacvm_chan_short = left > 0;' <<<"$write" && grep -q 'why = omacvm_chan_short ? OMACVM_GP_NOT_TAKEN : OMACVM_GP_SENT;' <<<"$send" &&
  grep -q 'omacvm_gp_say(tell, why);' <<<"$send" && grep -q 'OmacVMGpSay say = omacvm_gp_log(&said, tell, why, CACurrentMediaTime());' <<<"$say" &&
  grep -q 'if (say == OMACVM_GP_QUIET) {' <<<"$say" && grep -q 'told the VM to stop drawing' <<<"$say" &&
  grep -q 'but the VM was not told' <<<"$say" && grep -q 'told the VM to draw again after' <<<"$say" &&
  grep -q 'the VM was not told to draw again' <<<"$say" && grep -q 'OMACVM_GP_SAY_LAST' <<<"$say" ||
  fail "what becomes of the words for the guest is not logged as tested"
grep -q 'if (!seen && omacvm_gp_switch == 1 && omacvm_gp_why() != OMACVM_GP_SENT) {' <<<"$update" &&
  grep -q 'now - omacvm_gp_unable_at >= OMACVM_GP_AFTER_S' <<<"$update" &&
  grep -q 'omacvm_gp_say(OMACVM_GP_UNSEEN, omacvm_gp_why());' <<<"$update" ||
  fail "a window out of sight with nobody to tell is not logged as tested"
# Both kinds of guest frame end the hold: a GL scanout's flush, and a plain surface's update (GPU safe mode),
# not QEMU's own "display not active" surface.
grep -q 'omacvm_gp_guest_frame();' <<<"$flush" && grep -q '!surface_is_placeholder(surface)' <<<"$gfx" &&
  grep -q 'omacvm_gp_guest_frame();' <<<"$gfx" || fail "a guest frame does not end the hold on every path"
echo "test-guest-pause: $m: wiring ok"
