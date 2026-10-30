#!/bin/bash
# Tiled present (omacvm-cocoa-present-tiles*.patch):
#   - the rules: the logic patch makes ui/omacvm-present-tiles.h in an empty folder and
#     test-present-tiles.c runs against it (the grid, boxes to tiles, skipped frames lose nothing,
#     the tile program's texture coordinates on the frame texels' centres);
#   - the tile draw on Apple's software renderer (test-present-tiles-gl.m: every tile equals the
#     whole frame); --gpu [--before]: on the Mac's GPU, for rows on a test Mac (--before tests
#     3.2.14's draw, which Apple's GPUs squeeze right of x 4096);
#   - with a patched ui/cocoa.m: the wiring (what changed since the last frame is collected, a frame in
#     tiles only under the listed conditions and before surface n is taken, nothing presented when
#     nothing changed, whole frames hide the tiles, skipped frames pass their tiles on, off unless
#     OMACVM_GL_PRESENT_TILES=1 or =check, each tile drawn with the viewport inside its surface by the
#     tile program);
#   - with --self-test [<ui/cocoa.m without the patch>]: every wiring check fails on that code (CI: a
#     stub; the runtime build: the real cocoa.m before the patch).
#   test-present-tiles.sh [<patched ui/cocoa.m> | --self-test [<old ui/cocoa.m>] | --gpu [--before]]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patches=$(cd "$here/../../patches" && pwd -P)
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
  local m=$1 present flush alloc tiles show showt queue vsync skip viewsz hide wanted stats gate prog
  present=$(body "$m" 'static bool cocoa_gl_present(void)')
  flush=$(body "$m" 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,')
  alloc=$(body "$m" 'static bool cocoa_gl_present_alloc(')
  tiles=$(body "$m" 'static int cocoa_gl_present_tiles(GLuint src, bool flip)')
  show=$(body "$m" 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,')
  showt=$(body "$m" 'static void cocoa_gl_present_show_tiles(PresentFrame *f)')
  queue=$(body "$m" 'static void cocoa_gl_present_queue_frame(PresentFrame f)')
  vsync=$(body "$m" 'static bool cocoa_gl_present_vsync(double T')
  skip=$(body "$m" 'static void present_frame_skip(PresentFrame *older, PresentFrame *next)')
  viewsz=$(body "$m" 'static void omacvm_splash_view_size(uint32_t w, uint32_t h)')
  hide=$(body "$m" 'static void present_tiles_hide(void)')
  stats=$(body "$m" 'static void present_tiles_stats(void)')
  wanted=$(body "$m" 'static bool present_tiles_wanted(void)')
  prog=$(body "$m" 'static bool present_tile_program(char *why, size_t n)')
  # The condition for a frame in tiles, on one line, spaces squeezed.
  gate=$(awk '/if \(present_tiles_wanted\(\) &&/{on=1} on {printf "%s ", $0} on && /\) \{$/ {exit}' <<<"$present" | tr -s ' \t' ' ')
  chk "the rules are included" grep -q '#include "ui/omacvm-present-tiles.h"' "$m"
  chk "what changed since the last frame is collected" has "$flush" 'present_td = omacvm_pd_union(present_td, r);'
  chk "new surfaces are a new grid" has "$alloc" 'present_alloc_gen++;'
  for want in 'present_tiles_wanted()' 'pd_sig == pd_sig_was' 'pd_known' '!present_pd_unflushed' '!splash' \
              '!boost' 'gl_scanout_borrow' 'w == present_w' 'h == present_h' 'gl_scanout_x == 0' 'gl_scanout_y == 0' \
              'gl_scanout_w == w' 'gl_scanout_h == h' 'present_base_gen == present_alloc_gen' \
              '!qatomic_read(&present_tiles_full)' \
              'qatomic_read(&present_tiles_fit) == ((uint64_t)w << 32 | h)'; do
    chk "a frame in tiles needs: $want" has "$gate" "$want"
  done
  chk "tiles are decided before surface n is taken" order "$present" \
    'cocoa_gl_present_tiles(src, flip) >= 0' 'present_next = n;' 'omacvm_pd_take(&present_pd, n, &pd)'
  chk "a whole frame is what the tiles lie over" order "$present" \
    'present_base_gen = present_alloc_gen;' 'present_td = (OmacvmPDRect){ 0, 0, 0, 0 };' 'qatomic_set(&present_tiles_full, false);'
  chk "nothing changed: nothing is presented" order "$tiles" 'if (omacvm_pd_empty(present_td)) {' 'return 0;'
  chk "at most OMACVM_PT_FRAME_MAX tiles, else a whole frame" has "$tiles" 'tl, OMACVM_PT_FRAME_MAX);'
  # Apple's OpenGL squeezes a viewport that starts more than 4096 pixels outside its target (3.2.14's tiles past x 4096).
  chk "a tile is drawn with the viewport inside its surface" has "$tiles" 'glViewport(0, 0, tw, th);'
  chk "no tile is drawn with a viewport that starts outside its surface" lacks "$tiles" 'glViewport(-'
  chk "a tile's part of the frame is the header's rectangle" has "$tiles" 'omacvm_pt_tex_rect(&present_tg, tl[k], rect);'
  chk "a tile's rectangle reaches the program" has "$tiles" 'glUniform4fv(present_tile_u_rect, 1, rect);'
  chk "tiles are drawn with the tile program" order "$tiles" \
    'glUseProgram(present_tile_prog);' 'glBindVertexArray(present_tile_vao);' 'glBindVertexArray(0);'
  chk "the tile program is the header's shader text" order "$prog" \
    'present_tile_shader(GL_VERTEX_SHADER, OMACVM_PT_VERT, why, n);' \
    'present_tile_shader(GL_FRAGMENT_SHADER, OMACVM_PT_FRAG, why, n)'
  chk "the tile program's in_position is location 0 of its own quad" order "$prog" \
    'glBindAttribLocation(present_tile_prog, 0, "in_position");' 'glGenVertexArrays(1, &present_tile_vao);' \
    'glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);'
  chk "the tile program is made where the switch is read; tiles stay off if it does not build" has "$wanted" \
    '} else if (on && !present_tile_program(why, sizeof(why))) {'
  chk "a tile program that does not build says so in qemu.log" has "$wanted" \
    'info_report("cocoa: tiled present: off (the tile shader does not build: %s)", why);'
  chk "the switch is set once" has "$wanted" 'present_tiles_on = on;'
  chk "a tile surface waits for the GPU before Core Animation sees it" has "$tiles" 'IOSurfaceIncrementUseCount(s);'
  chk "a whole frame hides the tiles" has "$show" 'present_tiles_hide_locked();'
  chk "tiles that do not sit pixel for pixel hide and ask for a whole frame" order "$showt" \
    'if (!fits) {' 'present_tiles_hide_locked();' 'qatomic_set(&present_tiles_full, true);'
  chk "a whole frame measures if the window shows its size pixel for pixel" order "$show" \
    'omacvm_present_gravity(layer, surf);' 'qatomic_set(&present_tiles_fit,'
  chk "tiles that do not fit keep the next frames whole (no back and forth)" order "$showt" \
    'if (!fits) {' 'qatomic_set(&present_tiles_fit, 0);' 'qatomic_set(&present_tiles_full, true);'
  chk "a new view size is measured again" has "$hide" 'qatomic_set(&present_tiles_fit, 0);'
  chk "the pointer hand-off hears only of tiles that were shown" has "$showt" \
    'if (fits && qatomic_read(&omacvm_park_hold_on)) {'
  chk "tile surfaces go back after a while without tile frames" has "$tiles" \
    'timer_mod(present_tile_idle_timer, present_tile_last_ns + PRESENT_TILE_IDLE_NS);'
  chk "the check mode's count is in the minute line" has "$stats" 'present_tile_checks_bad, present_tile_checks'
  chk "a frame skipped while none was queued comes along" has "$queue" 'present_frame_absorb(&f, &present_pend);'
  chk "a merged frame passes its tiles on" has "$queue" 'present_frame_skip(last, &f);'
  chk "a frame pushed out of a full queue passes its tiles on" has "$queue" \
    'present_frame_skip(&present_sync.queue[0], &present_sync.queue[1]);'
  chk "the vsync tick drops no tiles" lacks "$vsync" 'surface_put(drop.surf);'
  chk "the vsync tick shows tile frames" has "$vsync" 'present_frame_show(&show);'
  chk "without tiles a skipped frame just goes (as before)" order "$skip" 'if (present_tiles_on <= 0) {' 'present_frame_put(older);'
  chk "a new view size hides the tiles" has "$viewsz" 'present_tiles_hide();'
  chk "OMACVM_GL_PRESENT_TILES is read" has "$wanted" 'getenv("OMACVM_GL_PRESENT_TILES")'
  chk "off unless OMACVM_GL_PRESENT_TILES=1 or =check" has "$wanted" \
    'int on = e && !strcmp(e, "1") ? 1 : e && !strcmp(e, "check") ? 2 : 0;'
  chk "only with the vsync present" has "$wanted" 'if (on && !present_vsync) {'
  chk "the check mode is wired" has "$tiles" 'cocoa_gl_present_tiles_check(src, flip, tl, bi, nt);'
}
if [[ ${1:-} == --self-test ]]; then
  old=${2:-}
  if [[ -z $old ]]; then
    T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-tiles.XXXXXX")
    trap 'rm -rf "$T"' EXIT
    { printf 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)\n{\n    present_w = w;\n}\n'
      printf 'static bool cocoa_gl_present(void)\n{\n    bool part = omacvm_pd_take(&present_pd, n, &pd);\n}\n'
      printf 'static void cocoa_gl_present_show(IOSurfaceRef surf, GLint filter, double flushed,\n{\n}\n'
      printf 'static bool cocoa_gl_present_vsync(double T)\n{\n    if (drop.surf) {\n        surface_put(drop.surf);\n    }\n}\n'
      printf 'static void omacvm_splash_view_size(uint32_t w, uint32_t h)\n{\n    gl_dirty = true;\n}\n'
      printf 'static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,\n{\n    gl_dirty = true;\n}\n'; } > "$T/old.m"
    old=$T/old.m
  fi
  passed=$(checks "$old" | grep '^ok ')
  if [[ -z $passed ]]; then echo "ok   every wiring check fails on the code without the patch ($old)"; exit 0; fi
  echo "FAIL these wiring checks pass on the code without the patch ($old):" >&2
  echo "$passed" >&2
  exit 1
fi
if [[ $# -ge 1 && $1 != --gpu ]]; then
  out=$(checks "$1" | grep '^FAIL ')
  if [[ -n $out ]]; then echo "test-present-tiles: $1:" >&2; echo "$out" >&2; exit 1; fi
  echo "test-present-tiles: $1: wiring ok"
  exit 0
fi
gl=()
if [[ ${1:-} == --gpu ]]; then
  gl=(--gpu)
  [[ ${2:-} == --before ]] && gl+=(--before)
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-tiles.XXXXXX")
trap 'rm -rf "$work"' EXIT
patch -s -d "$work" -p1 -f -i "$patches/omacvm-cocoa-present-tiles-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$work/ui" "$here/test-present-tiles.c" -o "$work/test-present-tiles"
"$work/test-present-tiles" || exit 1
# The tile draw: Apple's software renderer unless --gpu (the result must not depend on the machine).
cc -fobjc-arc -Wall -Wextra -Werror -I"$work/ui" "$here/test-present-tiles-gl.m" \
  -framework Foundation -framework OpenGL -framework IOSurface -o "$work/test-present-tiles-gl"
"$work/test-present-tiles-gl" ${gl[@]+"${gl[@]}"}
