#!/bin/bash
# The Mac's display on while a video plays in the VM (omacvm-cocoa-video-awake-logic.patch,
# omacvm-cocoa-video-awake.patch, ADR 0070): the patch makes ui/omacvm-video-awake.h in an
# empty folder and test-video-awake.c runs against it; then the wiring in ui/cocoa.m.
# No QEMU, no display.
#   test-video-awake.sh                         (CI: the wiring from the patch)
#   test-video-awake.sh <patched ui/cocoa.m>    (the runtime build)
#   test-video-awake.sh --self-test <ui/cocoa.m before the patch>: every wiring check fails there
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-video-awake.XXXXXX")
trap 'rm -rf "$work"' EXIT
self=0
if [[ ${1:-} == --self-test ]]; then self=1; shift; fi
if (( ! self )); then
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-video-awake-logic.patch"
  san=(-fsanitize=address,undefined)
  cc -std=c11 -Wall -Wextra -Werror "${san[@]}" -x c /dev/null -c -o "$work/probe.o" 2>/dev/null || san=()
  cc -std=c11 -Wall -Wextra -Werror ${san[@]+"${san[@]}"} -I"$work/ui" "$here/test-video-awake.c" -o "$work/test-video-awake"
  "$work/test-video-awake"
fi
full=0   # a whole ui/cocoa.m (the build, the self-test), or only the patch's hunks (CI)
if [[ $# -ge 1 ]]; then
  m=$1 full=1
else
  # The patch's new side: context and added lines, without the removed ones.
  m=$work/new.m
  awk '/^@@/ {on=1; next} on && /^-/ {next} on {print substr($0, 2)}' "$patches/omacvm-cocoa-video-awake.patch" > "$m"
fi
fail=0 passed=0
# Self-test: the checks' own lines would read as failures in the build log; only the verdict shows.
if (( self )); then exec 3>&1 1>/dev/null; fi
body() { awk -v h="$1" 'index($0, h) == 1 && !/;$/ {on=1} on {print} on && /^}$/ {exit}' "$m"; }
has() {
  if grep -qF -- "$3" <<<"$2"; then echo "ok   $1"; passed=$((passed + 1)); else echo "FAIL $1"; fail=1; fi
}
order() {   # WHAT TEXT FIRST SECOND: FIRST comes before SECOND in TEXT
  local a b
  a=$(grep -nF -- "$3" <<<"$2" | head -1 | cut -d: -f1 || true)
  b=$(grep -nF -- "$4" <<<"$2" | head -1 | cut -d: -f1 || true)
  if [[ -n $a && -n $b && $a -lt $b ]]; then echo "ok   $1"; passed=$((passed + 1)); else echo "FAIL $1"; fail=1; fi
}
all=$(cat "$m")
# Functions the patch only adds a line to: the whole function in a cocoa.m, the hunks in CI.
part() { if (( full )); then body "$1"; else cat "$m"; fi; }
gp=$(part 'static void omacvm_gp_update(void)')
update=$(body 'static void omacvm_va_update(void)')
seen=$(body 'static unsigned omacvm_va_seen(void)')
create=$(body 'static bool omacvm_va_create(void)')
renew=$(body 'static void omacvm_va_renew(void)')
line=$(body 'static void omacvm_va_line(id list)')
init=$(body 'static void omacvm_va_init(void)')
vmch=$(body 'static void omacvm_va_vm_change(void *opaque, bool running, RunState state)')
lost=$(body 'static void omacvm_va_lost(OmacVMVaWhy why)')
chan=$(part 'static void omacvm_chan_line(NSData *data)')
close=$(part 'static void omacvm_chan_close(void)')
dinit=$(part 'static void omacvm_displays_init(void)')
has "the rules are included" "$all" '#include "ui/omacvm-video-awake.h"'
# Display only, never system sleep; named for the person; backed by powerd's own timeout.
has "the assertion keeps the display on" "$create" 'kIOPMAssertionTypePreventUserIdleDisplaySleep'
has "... named for the person" "$create" 'CFSTR("OmacVM: the VM is playing video")'
has "... with powerd's own timeout" "$create" 'kIOPMAssertionTimeoutKey, kIOPMAssertionTimeoutActionKey'
has "... that releases it" "$create" 'kIOPMAssertionTimeoutActionRelease'
n=$(grep -cE 'PreventUserIdleSystemSleep|PreventSystemSleep|NoIdleSleep|NSActivityIdleSystemSleepDisabled' <<<"$all" || true)
if [[ -n $create && $n -eq 0 ]]; then echo "ok   never a system-sleep assertion"; passed=$((passed + 1)); else echo "FAIL a system-sleep assertion ($n)"; fail=1; fi
n=$(grep -c 'IOPMAssertionCreateWithProperties' <<<"$all" || true)
if [[ $n -eq 1 ]]; then echo "ok   one place makes it"; passed=$((passed + 1)); else echo "FAIL IOPMAssertionCreateWithProperties in $n places"; fail=1; fi
has "renewing arms powerd's timeout again" "$renew" 'IOPMAssertionSetProperty(omacvm_va_id, kIOPMAssertionTimeoutKey, timeout)'
# The rules decide with the sight, the run state and the switch; every outcome acted on; a look again.
has "the rules decide" "$update" 'switch (omacvm_va_decide(&omacvm_va, omacvm_va_seen(), qatomic_read(&omacvm_va_running),'
has "... hold" "$update" 'if (omacvm_va_create()) {'
has "... release" "$update" 'omacvm_va_release();'
has "... renew" "$update" 'omacvm_va_renew();'
has "... and look again by itself" "$update" 'double at = omacvm_va_look_at(&omacvm_va, now);'
# Seen: the window on screen and not covered, nobody locked out (the sight guest-pause uses); the test switch only for hidden windows.
has "seen: the lock, sleep, another user, the test lock" "$seen" 'if (omacvm_ds_screen_locked || omacvm_ds_asleep || omacvm_ds_away || omacvm_ds_test_locked) {'
has "seen: each output's own window" "$seen" 'NSWindow *w = i ? omacvm_heads[i].window : [cocoaView window];'
has "seen: on screen and not covered" "$seen" '[w isVisible] && ([w occlusionState] & NSWindowOcclusionStateVisible)'
order "the lock is checked before the test switch" "$seen" 'omacvm_ds_test_locked) {' 'omacvm_va_test_seen ||'
# What feeds it: the guest's line, every change of sight (through guest-pause's update), the VM's run state, the Mac's sleep, the channel.
has "the guest's inhibit reaches it" "$chan" 'omacvm_va_line(d[@"inhibit"]);'
has "a line is checked before it counts" "$line" 'int i = omacvm_va_name([u bytes], [u length]);'
has "... at most OMACVM_VA_MAX names" "$line" '[list count] > OMACVM_VA_MAX'
has "the window's sight and the lock reach it" "$gp" 'omacvm_va_update();'
has "the VM's run state reaches it" "$init" 'qemu_add_vm_change_state_handler(omacvm_va_vm_change, NULL);'
has "... from QEMU's thread to the main thread" "$vmch" 'dispatch_async(dispatch_get_main_queue(), ^{ omacvm_va_update(); });'
has "the Mac's sleep lets it go" "$init" 'omacvm_va_lost(OMACVM_VA_WHY_SLEEP);'
has "... before the sleep" "$init" 'NSWorkspaceWillSleepNotification'
has "the channel closing lets it go" "$close" 'omacvm_va_lost(OMACVM_VA_WHY_CHANNEL);'
has "... the guest's word forgotten" "$lost" 'omacvm_va_forget(&omacvm_va, why);'
has "OMACVM_VIDEO_AWAKE=0 leaves it out" "$init" 'getenv("OMACVM_VIDEO_AWAKE")'
has "started with the displays" "$dinit" 'omacvm_va_init();'
order "... after the lock watch" "$dinit" 'omacvm_ds_watch_lock();' 'omacvm_va_init();'
# Nothing from the guest in qemu.log or the assertion's name.
n=$(grep -cE 'info_report\([^;]*(list|u bytes|\[n )' <<<"$line$update" || true)
if [[ -n $line && $n -eq 0 ]]; then echo "ok   no guest word in qemu.log"; passed=$((passed + 1)); else echo "FAIL a guest word reaches qemu.log"; fail=1; fi
if (( self )); then
  exec 1>&3 3>&-
  if (( passed == 0 )); then
    echo "test-video-awake: self-test ok: every wiring check fails on code without the patch"
    exit 0
  fi
  echo "test-video-awake: self-test FAIL: $passed check(s) pass on code without the patch" >&2
  exit 1
fi
if (( fail )); then
  echo "test-video-awake: $m: the wiring is not as tested" >&2
  exit 1
fi
echo "test-video-awake: wiring ok ($passed checks)"
