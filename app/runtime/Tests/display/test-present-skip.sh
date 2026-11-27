#!/bin/bash
# A drawn frame that the vsync queue skips last goes on the layer at the next tick
# (omacvm-cocoa-present-skipped-last.patch):
#   - test-present-skip.c runs the vsync queue and its skip code, taken from a ui/cocoa.m, with the
#     tiled present on and off: a drawn frame that a trim after a tick skips with none after it
#     waits in present_pend for the frame that comes next, or else the next tick shows it (a scroll
#     that ends on a trimmed frame ends on screen too); a first tick a second late keeps the link
#     for the frame it skipped;
#   - with --self-test [<ui/cocoa.m without the patch>]: the test fails on that code (CI: the code
#     before the patch, as the extract takes it, in test-present-skip-before.inc; the runtime
#     build: the real cocoa.m before the patch).
#   test-present-skip.sh <patched ui/cocoa.m> | --self-test [<ui/cocoa.m without the patch>]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-skip.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The definition (not a prototype) of the function whose first line starts with $2.
body() { awk -v h="$2" 'index($0, h) == 1 && $0 !~ /;$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }

# present-queue.inc from a cocoa.m, in the file's order: the queue's sizes and times, PresentFrame,
# present_sync, the skip code, and the queue (a frame comes, a tick).
extract() {
  local m=$1 h
  grep -E '^#define PRESENT_(QUEUE|IDLE_S|INPUT_NS|CLOSE_S) ' "$m"
  awk '/^typedef struct PresentFrame \{$/ {on=1} on {print} on && /^\} PresentFrame;$/ {exit}' "$m"
  awk 'p == "static struct {" && /^    PresentFrame queue\[PRESENT_QUEUE\];/ {on=1; print p} {p=$0} on {print} on && /^};$/ {exit}' "$m"
  for h in 'static void present_frame_put(PresentFrame *f)' 'static void present_frame_absorb(PresentFrame *newer, PresentFrame *older)'; do
    body "$m" "$h"
  done
  grep -x 'static PresentFrame present_pend;' "$m"
  for h in 'static void present_frame_skip(PresentFrame *older, PresentFrame *next)' \
           'static void present_window_reset(double now)' 'static void cocoa_gl_present_queue_frame(PresentFrame f)' \
           'static double present_wanted_hz(void)' 'static bool cocoa_gl_present_vsync(double T'; do
    body "$m" "$h"
  done
}
build() {
  patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-present-tiles-logic.patch" || return 1
  cc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -I"$work" -I"$work/ui" \
    "$here/test-present-skip.c" -o "$work/t" -lm 2>"$work/cc.log" || { cat "$work/cc.log" >&2; return 1; }
}

if [[ ${1:-} == --self-test ]]; then
  if [[ $# -ge 2 ]]; then
    extract "$2" > "$work/present-queue.inc"
  else
    cp "$here/test-present-skip-before.inc" "$work/present-queue.inc"
  fi
  build || exit 1
  "$work/t" > "$work/old.out"
  # its last line: every check ran (a crash or a test that never started says nothing)
  if ! grep -qx 'test-present-skip: FAIL' "$work/old.out"; then
    echo "FAIL the queue test passes or does not run on the code before the patch" >&2; cat "$work/old.out" >&2; exit 1
  fi
  # the build's log and CI look for the word FAIL: say these as "fails before"
  grep '^FAIL ' "$work/old.out" | sed 's/^FAIL /  fails before the patch, as it should: /'
  echo "ok   the queue test fails on the code before the patch"
  exit 0
fi

m=${1:?usage: test-present-skip.sh <patched ui/cocoa.m> | --self-test [<ui/cocoa.m without the patch>]}
extract "$m" > "$work/present-queue.inc"
build || exit 1
if ! "$work/t"; then echo "test-present-skip: $m: FAIL" >&2; exit 1; fi
echo "test-present-skip: $m: all ok"
