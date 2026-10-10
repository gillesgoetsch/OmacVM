#!/bin/bash
# The start animation waits until the window shows
# (omacvm-cocoa-splash-after-reveal.patch):
#   - the logo layer's -tick: takes its time from omacvm_intro_clock() with
#     the full-screen start's omacvm_start_hidden, not from its first frame;
#   - -fadeIfStalled counts from the animation's own start;
#   - test-splash-after-reveal.c: the timeline the user sees for windows that
#     show after 0 to 6 s, and the logo inside FullPanel's panels.
#   test-splash-after-reveal.sh <patched ui/cocoa.m>   (the runtime build)
#   test-splash-after-reveal.sh                        (CI: from the patches; the
#                                                       checks must catch the old code)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
runtime=$(cd "$here/../.." && pwd -P)
patch_file="$runtime/patches/omacvm-cocoa-splash-after-reveal.patch"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-splash-reveal.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

body() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }

# Problems of a ui/cocoa.m (or the part of it the patch shows), one a line.
problems() {
  local f=$1 tick stalled
  tick=$(body "$f" '- (void)tick:(CADisplayLink *)l')
  stalled=$(body "$f" '- (void)fadeIfStalled')
  [[ -n $tick ]] || { echo "no -tick: of the logo layer"; return; }
  grep -q '#include "ui/omacvm-intro-clock.h"' "$f" || echo "ui/omacvm-intro-clock.h is not included"
  grep -q 't = omacvm_intro_clock(now, !omacvm_start_hidden, &start);' <<<"$tick" ||
    echo "-tick: does not take the animation's time from omacvm_intro_clock with omacvm_start_hidden"
  grep -Eq '^ *start = now;' <<<"$tick" && echo "-tick: starts the clock at its first frame, shown or not"
  grep -q 't = now - start;' <<<"$tick" && echo "-tick: counts from its first frame, shown or not"
  grep -q '(start ? start : opened) + INTRO_END' <<<"$stalled" ||
    echo "-fadeIfStalled counts from the window's opening, not the animation's start"
}

# The C test with ui/'s headers in DIR.
timeline() {
  cc -Wall -Wextra -Werror -Wno-unused-function -I"$1" "$here/test-splash-after-reveal.c" -o "$tmp/test-splash-after-reveal" &&
    "$tmp/test-splash-after-reveal"
}

if [[ $# -ge 1 ]]; then
  f=$1
  p=$(problems "$f")
  [[ -z $p ]] || { echo "test-splash-after-reveal: FAIL: $f:"; sed 's/^/  /' <<<"$p"; exit 1; }
  awk '$0 == "static bool omacvm_start_hidden;" {h=NR} $0 == "- (void)tick:(CADisplayLink *)l" {t=NR}
       END {exit !(h && t && h < t)}' "$f" ||
    { echo "test-splash-after-reveal: FAIL: omacvm_start_hidden is declared after the logo layer"; exit 1; }
  timeline "$(dirname "$f")" || exit 1
  echo "test-splash-after-reveal: $f: wiring ok"
  exit 0
fi

# CI: the headers are new files of the patches; ui/cocoa.m's two sides are the patch's hunks.
newfile() { awk -v f="+++ b/ui/$2" '$0 == f { on = 1; next } on && /^(diff|--- )/ { exit }
                                     on && /^\+/ { print substr($0, 2) }' "$1"; }
newfile "$runtime/patches/omacvm-cocoa-boot-splash.patch" omacvm-splash.h > "$tmp/omacvm-splash.h"
newfile "$patch_file" omacvm-intro-clock.h > "$tmp/omacvm-intro-clock.h"
[[ -s $tmp/omacvm-splash.h && -s $tmp/omacvm-intro-clock.h ]] || { echo "test-splash-after-reveal: FAIL: headers not found in the patches"; exit 1; }
side() { awk -v drop="$2" '/^\+\+\+ b\/ui\/cocoa.m$/ { on = 1; next } on && /^(diff|--- )/ { exit }
                          on && /^@@/ { next } on && substr($0, 1, 1) != drop { print substr($0, 2) }' "$patch_file"; }
side "$patch_file" - > "$tmp/new.m"
side "$patch_file" + > "$tmp/old.m"
p=$(problems "$tmp/new.m")
[[ -z $p ]] || { echo "test-splash-after-reveal: FAIL: the patch:"; sed 's/^/  /' <<<"$p"; exit 1; }
p=$(problems "$tmp/old.m")
[[ -n $p ]] || { echo "test-splash-after-reveal: FAIL: the checks pass the old code"; exit 1; }
timeline "$tmp" || exit 1
echo "test-splash-after-reveal: ok (the patch's code passes, the old code is caught: $(wc -l <<<"$p" | tr -d ' ') problems)"
