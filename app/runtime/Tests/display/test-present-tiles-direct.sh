#!/bin/bash
# Tiled present when frames are shown when drawn (omacvm-cocoa-present-tiles-direct.patch, ADR 0055's
# addendum of 2026-11-17):
#   - with a patched ui/cocoa.m: the wiring (no "needs the vsync present" gate; present_bh in both
#     modes; a tile frame shown when drawn goes on the layers on the main queue, as whole frames do, and
#     its surfaces go back after; both kinds of whole-frame show hide the tiles and measure the fit
#     through one helper);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check fails on that code (CI: a
#     stub; the runtime build: the real cocoa.m before the patch).
#   test-present-tiles-direct.sh <patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]
set -uo pipefail
body() { awk -v h="$2" 'index($0, h) == 1 && $0 !~ /;$/ {on=1} on {print} on && /^}$/ {exit}' "$1"; }
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
# A function found (not empty) without the text: an empty body would pass a plain hasnt.
lacks() { [[ -n $1 ]] && hasnt "$1" "$2"; }
order() {
  awk -v a="$2" -v b="$3" -v c="${4:-}" '
    !x && index($0, a) {x=NR; next}
    x && !y && index($0, b) {y=NR; if (c == "") exit; next}
    y && c != "" && !z && index($0, c) {z=NR; exit}
    END {exit !(x && y && (c == "" || z))}' <<<"$1"
}
checks() {
  local m=$1 init wanted tiles present show helper
  init=$(body "$m" 'static bool cocoa_gl_present_init(void)')
  wanted=$(body "$m" 'static bool present_tiles_wanted(void)')
  tiles=$(body "$m" 'static int cocoa_gl_present_tiles(GLuint src, bool flip)')
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  show=$(body "$m" 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,')
  helper=$(body "$m" 'static void present_tiles_whole_shown(CALayer *layer, IOSurfaceRef surf)')
  chk "tiles are not kept off without the vsync present" lacks "$wanted" 'if (on && !present_vsync) {'
  chk "the tile program decides alone" grep -q '^        if (on && !present_tile_program(why, sizeof(why))) {$' <<<"$wanted"
  # made at the function's own level (4 spaces), not inside "if (present_vsync) {"
  chk "present_bh in both present modes" grep -q '^    present_bh = aio_bh_new(iohandler_get_aio_context(),$' <<<"$init"
  chk "the vsync present still queues tile frames" order "$tiles" 'if (present_vsync) {' 'cocoa_gl_present_queue_frame(tf);' 'return;'
  chk "a tile frame shown when drawn goes on the main queue, then its surfaces go back" \
    order "$tiles" 'dispatch_async(dispatch_get_main_queue(), ^{' 'present_frame_show(&f);' 'present_frame_put(&f);'
  chk "only the vsync present counts tile frames in flight" order "$tiles" 'if (present_vsync) {' 'present_sync.inflight++;'
  chk "a whole frame shown when drawn hides the tiles and measures the fit" \
    order "$present" '[layer setContents:(id)surf];' 'present_tiles_whole_shown(layer, surf);' '[CATransaction commit];'
  chk "a whole frame on the vsync present does the same through the helper" has "$show" 'present_tiles_whole_shown(layer, surf);'
  chk "the helper: tiles off, nothing" order "$helper" 'if (present_tiles_on <= 0) {' 'return;'
  chk "the helper measures the fit" has "$helper" 'qatomic_set(&present_tiles_fit, present_tiles_fits(layer, fw, fh) ?'
  chk "the helper hides the tiles under their lock" \
    order "$helper" 'os_unfair_lock_lock(&present_tile_lock);' 'present_tiles_hide_locked();' 'os_unfair_lock_unlock(&present_tile_lock);'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-tiles-direct.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    { printf 'static bool cocoa_gl_present_init(void)\n{\n    if (present_vsync) {\n        present_bh = aio_bh_new(iohandler_get_aio_context(),\n                                cocoa_gl_present_bh, NULL);\n    }\n}\n'
      printf 'static bool present_tiles_wanted(void)\n{\n        if (on && !present_vsync) {\n            present_tiles_on = 0;\n        } else if (on && !present_tile_program(why, sizeof(why))) {\n        }\n}\n'
      printf 'static int cocoa_gl_present_tiles(GLuint src, bool flip)\n{\n    present_sync.inflight++;\n    dispatch_async(present_queue, ^{\n        cocoa_gl_present_queue_frame((PresentFrame){ .pt = pt });\n    });\n}\n'
      printf 'static bool cocoa_gl_present(void)\n{\n            [layer setContents:(id)surf];\n            [CATransaction commit];\n}\n'
      printf 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,\n{\n    if (present_tiles_on > 0) {\n        present_tiles_hide_locked();\n    }\n}\n'; } > "$T/old.m"
    old=$T/old.m
  fi
  passed=$(checks "$old" | grep '^ok ')
  if [[ -z $passed ]]; then echo "ok   every wiring check fails on the code without the patch ($old)"; exit 0; fi
  echo "FAIL these wiring checks pass on the code without the patch ($old):" >&2
  echo "$passed" >&2
  exit 1
fi
[[ $# -ge 1 ]] || { echo "usage: test-present-tiles-direct.sh <patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>]" >&2; exit 64; }
out=$(checks "$1" | grep '^FAIL ')
if [[ -n $out ]]; then echo "test-present-tiles-direct: $1:" >&2; echo "$out" >&2; exit 1; fi
echo "test-present-tiles-direct: $1: wiring ok"
