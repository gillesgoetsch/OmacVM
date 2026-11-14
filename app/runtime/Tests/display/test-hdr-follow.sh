#!/bin/bash
# HDR only in full screen and the depth hold (ADR 0074; omacvm-cocoa-hdr-follow-logic.patch,
# omacvm-cocoa-present-depth-hold.patch, omacvm-cocoa-hdr-follow.patch): the logic patch makes
# ui/omacvm-hdr-follow.h in an empty folder (with omacvm-edr.h from the headroom's logic patch) and
# test-hdr-follow.c runs against it; then the wiring in ui/cocoa.m. No QEMU, no display.
#   test-hdr-follow.sh                         (CI: the wiring from the patches)
#   test-hdr-follow.sh <patched ui/cocoa.m>    (the runtime build)
#   test-hdr-follow.sh --self-test <ui/cocoa.m before the patches>: every wiring check fails there
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-hdr-follow.XXXXXX")
trap 'rm -rf "$work"' EXIT
self=0
if [[ ${1:-} == --self-test ]]; then self=1; shift; fi
if (( ! self )); then
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-hdr-headroom-logic.patch"
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-hdr-follow-logic.patch"
  san=(-fsanitize=address,undefined)
  cc -std=c11 -Wall -Wextra -Werror "${san[@]}" -x c /dev/null -c -o "$work/probe.o" 2>/dev/null || san=()
  cc -std=c11 -Wall -Wextra -Werror ${san[@]+"${san[@]}"} -I"$work/ui" "$here/test-hdr-follow.c" -o "$work/test-hdr-follow" -lm
  "$work/test-hdr-follow"
fi
full=0   # a whole ui/cocoa.m (the build, the self-test), or only the patches' hunks (CI)
if [[ $# -ge 1 ]]; then
  m=$1 full=1
else
  # The patches' new side: context and added lines, without the removed ones.
  m=$work/new.m
  for p in omacvm-cocoa-present-depth-hold.patch omacvm-cocoa-hdr-follow.patch; do
    awk '/^@@/ {on=1; next} on && /^-/ {next} on {print substr($0, 2)}' "$patches/$p"
  done > "$m"
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
# Functions the patches only add lines to: the whole function in a cocoa.m, the hunks in CI.
part() { if (( full )); then body "$1"; else cat "$m"; fi; }
alloc=$(part 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)')
present=$(part 'static bool cocoa_gl_present(void)')
now=$(part 'static double omacvm_edr_now(void)')
watch=$(part 'static void omacvm_edr_watch(void)')
layout=$(part 'static void omacvm_send_layout(void)')
line=$(part 'static void omacvm_chan_line(NSData *data)')
guest=$(body 'static double omacvm_hf_guest_edr(uint32_t display, double current, double potential,')
hread=$(body 'static void omacvm_hf_read(void)')
hinit=$(body 'static void omacvm_hf_init(void)')
has "the rules are included" "$all" '#include "ui/omacvm-hdr-follow.h"'
# The depth hold: decided in alloc's hold-off, the timer never in the past, before the queue and the tiles.
has "alloc starts each frame unheld" "$alloc" 'present_held = false;'
has "the hold-off holds a frame of the other colour" "$alloc" 'present_held = omacvm_hf_wrong_colour(present_deep, present_linear, deep,'
has "the hold-off's timer never at or before now" "$alloc" 'timer_mod(present_timer, omacvm_hf_hold_due(present_alloc_ns, PRESENT_REALLOC_NS, now));'
has "a held frame keeps the last one and comes back dirty" "$present" 'if (present_held) {'
has "a held frame is logged" "$present" 'frame held until its surfaces are made'
if (( full )); then   # the order needs the whole function (the hunks have only their context)
  order "the hold comes after alloc" "$present" 'if (!cocoa_gl_present_alloc(w, h, deep, linear)) {' 'if (present_held) {'
  order "the hold comes before a surface is taken" "$present" 'if (present_held) {' 'if (!IOSurfaceIsInUse(present_surf[n])) {'
  order "the hold comes before the tiles" "$present" 'if (present_held) {' 'if (present_tiles_wanted()'
  held=$(awk '/^    if \(present_held\) \{/ {on=1} on {print} on && /^    }$/ {exit}' <<<"$present")
  has "a held frame is drawn again once the surfaces are made" "$held" 'gl_dirty = true;'
fi
# The surfaces' state for the main thread, published by QEMU's thread.
has "the present publishes PQ surfaces" "$present" 'qatomic_set(&omacvm_hf_pq, hf_pq);'
has "and since when" "$present" 'qatomic_set(&omacvm_hf_pq_ns, qemu_clock_get_ns(QEMU_CLOCK_REALTIME));'
has "and counts the switches" "$present" 'qatomic_inc(&omacvm_hf_flips);'
# The headroom the guest is told.
has "the headroom: today's rule with the switch off" "$guest" 'if (omacvm_hf_switch != 1) {'
has "the headroom: the rule with it on" "$guest" 'return omacvm_hf_edr(&omacvm_hf_hold, display, current, potential, use_potential,'
has "the headroom reads the published state" "$guest" '!qatomic_read(&omacvm_hf_pq), qatomic_read(&omacvm_hf_pq_ns),'
has "the window's display is the key" "$now" 'return omacvm_hf_guest_edr(omacvm_screen_id(s),'
has "the test display goes the same way" "$now" 'return omacvm_hf_guest_edr(0, hook_n, hook_p, false);'
has "a minute line of switches" "$watch" 'unsigned flips = qatomic_xchg(&omacvm_hf_flips, 0);'
# The switch: the app's key, only with HDR, live, and in the layout only when on.
has "the switch is the app's key" "$hread" 'boolForKey:@"hdrFullScreenOnly"'
has "the switch only with HDR" "$hread" 'if (!cocoa_gl_present_hdr_wanted()) {'
has "a QEMU not started as the app" "$hread" 'getenv("OMACVM_HDR_FULL_SCREEN_ONLY")'
has "a change goes to the guest" "$hread" 'omacvm_send_layout();'
has "it is watched live" "$hinit" 'forKeyPath:@"hdrFullScreenOnly"'
has "the layout says it only when on" "$layout" 'entry[@"hdr_follow"] = @YES;'
order "read at the hello before the first headroom" "$line" 'omacvm_hf_init();' 'omacvm_edr_set(omacvm_edr_now());'
if (( self )); then
  exec 1>&3 3>&-
  if (( passed )); then
    echo "test-hdr-follow: --self-test: $passed wiring checks pass on $m without the patches" >&2
    exit 1
  fi
  echo "test-hdr-follow: --self-test ok (every wiring check fails on the code before)"
  exit 0
fi
if (( fail )); then echo "test-hdr-follow: FAIL" >&2; exit 1; fi
echo "test-hdr-follow: ok"
