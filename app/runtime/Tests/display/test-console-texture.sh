#!/bin/bash
# A console's GL texture made when it is first drawn, not at every switch
# (qemu-cocoa-gl-console-texture-lazy.patch):
#   - test-console-texture.c runs the listener calls of a set scanout (GL
#     scanout, display off and on, the placeholder, a 2D surface, an extra
#     display) through the texture code taken from the files, with a GL stub
#     that counts the bytes uploaded; and OMACVM_CONSOLE_TEXTURE=eager;
#   - the wiring: every reader of the texture (the present without a GL
#     scanout, the CAOpenGLLayer path, extra displays' layers, behind the boot
#     logo's three places) draws it only when it is there and makes it only on
#     QEMU's thread.
#   test-console-texture.sh <patched ui/cocoa.m> <ui/console-gl.c>      (the runtime build)
#   test-console-texture.sh --self-test [<ui/cocoa.m> <ui/console-gl.c>] the code before the patch
#       fails both (CI: 3.2.16's code, copied in test-console-texture-3216.inc; the runtime
#       build: the real files before the patch)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-console-texture.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The definition (not a prototype) of the function whose first line starts with $2.
fbody() {
  awk -v h="$2" '
    !on && !buf && index($0, h) == 1 { buf = $0 "\n"; if ($0 ~ /;[ \t]*$/) buf = ""; next }
    buf && !on { if ($0 == "{") { on = 1; printf "%s", buf; print; next }
                 buf = buf $0 "\n"; if ($0 ~ /;[ \t]*$/) buf = ""; next }
    on { print; if ($0 ~ /^}$/) exit }' "$1"
}
chk() { local what=$1; shift; if "$@"; then echo "ok $what"; else echo "FAIL $what"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }
# A before B (fixed strings), in that order in the text.
order() { awk -v a="$2" -v b="$3" '!x && index($0, a) {x=NR; next} x && index($0, b) {y=NR; exit} END {exit !(x && y)}' <<<"$1"; }

# texture-code.inc from a cocoa.m and a console-gl.c; prints the HAVE_TEX_READY value.
extract() {
  local m=$1 c=$2 h ready=0
  : > "$work/texture-code.inc"
  for h in 'static bool map_format(pixman_format_code_t format,' 'void surface_gl_create_texture(QemuGLShader *gls,' \
           'void surface_gl_update_texture(QemuGLShader *gls,' 'void surface_gl_destroy_texture(QemuGLShader *gls,'; do
    fbody "$c" "$h" >> "$work/texture-code.inc"
  done
  for h in 'static bool omacvm_splash_enabled(void)' 'static bool omacvm_splash_wanted(DisplayGLTextureBorrower borrow,' \
           'static bool omacvm_console_tex_eager(void)' 'static bool omacvm_console_tex_wanted(DisplaySurface *s, bool scanout)' \
           'static bool omacvm_console_tex_ready(DisplaySurface *s, bool scanout)' \
           'static void cocoa_gl_update(DisplayChangeListener *dcl,' 'static void cocoa_gl_switch(DisplayChangeListener *dcl,' \
           'static void omacvm_head_gfx_update(DisplayChangeListener *dcl,' 'static void omacvm_head_gfx_switch(DisplayChangeListener *dcl,'; do
    fbody "$m" "$h" >> "$work/texture-code.inc"
  done
  grep -q '^static bool omacvm_console_tex_ready(' "$work/texture-code.inc" && ready=1
  echo "$ready"
}
build() { # $1 = HAVE_TEX_READY
  cc -std=gnu11 -fblocks -Wall -Wno-unused-function -DHAVE_TEX_READY="$1" -I"$work" \
    "$here/test-console-texture.c" -o "$work/t" 2>"$work/cc.log" || { cat "$work/cc.log" >&2; return 1; }
}

# The readers in ui/cocoa.m; one line per check ("(kept)": true before the patch too).
wiring() {
  local m=$1 render present refresh hrender hrefresh wanted ready update hupdate switch hswitch
  render=$(fbody "$m" 'static void cocoa_gl_render(void)')
  present=$(fbody "$m" 'static bool cocoa_gl_present(void)')
  refresh=$(fbody "$m" 'static void cocoa_gl_refresh(DisplayChangeListener *dcl)')
  hrender=$(fbody "$m" 'static void omacvm_head_render(OmacVMHead *hd, NSSize size)')
  hrefresh=$(fbody "$m" 'static void omacvm_head_refresh(DisplayChangeListener *dcl)')
  wanted=$(fbody "$m" 'static bool omacvm_console_tex_wanted(DisplaySurface *s, bool scanout)')
  ready=$(fbody "$m" 'static bool omacvm_console_tex_ready(DisplaySurface *s, bool scanout)')
  switch=$(fbody "$m" 'static void cocoa_gl_switch(DisplayChangeListener *dcl,')
  hswitch=$(fbody "$m" 'static void omacvm_head_gfx_switch(DisplayChangeListener *dcl,')
  chk "a texture is drawn only where the boot logo does not stand in" has "$wanted" 'return s && !scanout && !omacvm_splash_wanted(NULL, s);'
  chk "a texture is made whole, in QEMU's view context" order "$ready" 'with_gl_view_ctx(^{' 'surface_gl_create_texture(dgc.gls, s);'
  chk "making it keeps the caller's GL context" order "$ready" 'CGLContextObj prev = CGLGetCurrentContext();' 'CGLSetCurrentContext(prev);'
  chk "a switch makes no texture unless OMACVM_CONSOLE_TEXTURE=eager" order "$switch" 'if (eager) {' 'surface_gl_create_texture(dgc.gls, new_surface);'
  chk "an extra display's switch likewise" order "$hswitch" 'if (eager && new_surface) {' 'surface_gl_create_texture(dgc.gls, new_surface);'
  chk "the present (QEMU's thread) makes the texture it draws" has "$present" '} else if (omacvm_console_tex_ready(surface, false)) {'
  chk "the present: the boot logo before the texture" order "$present" '} else if (omacvm_splash_wanted(NULL, surface)) {' 'omacvm_console_tex_ready(surface, false)'
  chk "the CAOpenGLLayer path (AppKit thread) draws it only when it is there" has "$render" '} else if (surface && surface->texture) {'
  chk "the CAOpenGLLayer path: the boot logo before the texture" order "$render" '} else if (omacvm_splash_wanted(NULL, surface)) {' '} else if (surface && surface->texture) {'
  chk "the CAOpenGLLayer path draws black without one" order "$render" '} else if (surface && surface->texture) {' 'glClear(GL_COLOR_BUFFER_BIT);'
  chk "(kept) the AppKit thread never makes one" hasnt "$render$hrender" 'surface_gl_create_texture'
  chk "the refresh tick (QEMU's thread) makes it for the layer path" has "$refresh" 'omacvm_console_tex_ready(surface, gl_scanout_borrow != NULL)'
  chk "(kept) extra displays' layers draw it only when it is there" has "$hrender" '} else if (hd->surface && hd->surface->texture) {'
  chk "(kept) extra displays: the boot logo before the texture" order "$hrender" '} else if (omacvm_splash_wanted(NULL, hd->surface)) {' '} else if (hd->surface && hd->surface->texture) {'
  chk "extra displays' refresh tick makes it for their layers" has "$hrefresh" 'omacvm_console_tex_ready(hd->surface, hd->borrow != NULL)'
  chk "qemu.log says how the console texture is made" grep -qF '"cocoa: console texture: %s"' "$m"
}

if [[ ${1:-} == --self-test ]]; then
  if [[ $# -ge 3 ]]; then
    ready=$(extract "$2" "$3")
    old="$2"
  else
    cp "$here/test-console-texture-3216.inc" "$work/texture-code.inc"
    ready=0
    old=$work/old.m
    printf 'static void cocoa_gl_render(void)\n{\n    glBindTexture(GL_TEXTURE_2D, surface->texture);\n}\n' > "$old"
  fi
  [[ $ready == 0 ]] || { echo "FAIL --self-test: $old already has the lazy console texture" >&2; exit 1; }
  build 0 || exit 1
  if "$work/t" old > "$work/old.out"; then
    echo "FAIL the sequences pass on the code before the patch" >&2; cat "$work/old.out" >&2; exit 1
  fi
  grep '^FAIL' "$work/old.out" | sed 's/^/  (before) /'
  # "(kept)": what 3.2.16 already did right and must stay so; every other check is new.
  passed=$(wiring "$old" | grep '^ok ' | grep -v '^ok (kept) ')
  if [[ -n $passed ]]; then echo "FAIL these wiring checks pass on the code before the patch:" >&2; echo "$passed" >&2; exit 1; fi
  echo "ok   the sequences and every wiring check fail on the code before the patch"
  exit 0
fi

m=${1:?usage: test-console-texture.sh <patched ui/cocoa.m> <ui/console-gl.c> | --self-test [<ui/cocoa.m> <ui/console-gl.c>]}
c=${2:?usage: test-console-texture.sh <patched ui/cocoa.m> <ui/console-gl.c>}
ready=$(extract "$m" "$c")
[[ $ready == 1 ]] || { echo "test-console-texture: $m: no omacvm_console_tex_ready (patch not applied?)" >&2; exit 1; }
build 1 || exit 1
fail=0
"$work/t" || fail=1
"$work/t" eager || fail=1
out=$(wiring "$m")
echo "$out" | sed 's/^/  wiring: /'
grep -q '^FAIL' <<<"$out" && fail=1
if (( fail )); then echo "test-console-texture: $m: FAIL" >&2; exit 1; fi
echo "test-console-texture: $m: all ok"
