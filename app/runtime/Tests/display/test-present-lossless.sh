#!/bin/bash
# Lossless-compressed present surfaces (omacvm-cocoa-present-lossless.patch): the patched ui/cocoa.m makes
# its 8-bit surfaces as '&BGA' and its half-float ones (HDR, Extra brightness) as '&RhA' through CoreVideo,
# falls back to plain surfaces of that kind for the run when one cannot be made or bound, gives the layer
# EDR for both half-float kinds, makes half float lossless only where that was checked on screen (HDR, Extra
# brightness, both with the layer's EDR; a 10-bit scanout without HDR or OMACVM_GL_COLOR=native stays plain), never makes 10-bit 'l10r' surfaces, reads OMACVM_GL_LOSSLESS and never reads a present surface on the CPU.
# Nothing reads a present surface with glReadPixels (it crashes on a compressed one): the partial present's check mode
# (OMACVM_GL_PRESENT_DAMAGE=check) reads a plain copy the GPU makes of it, and keeps lossless surfaces. Without an argument: only that the checks catch the code
# without it (CI); GL drawing into such a surface is checked on the Mac by work/window-path/lbcheck.m (a GPU).
#   test-present-lossless.sh                       (CI)
#   test-present-lossless.sh <patched ui/cocoa.m>  (the runtime build)
set -euo pipefail
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-present-lossless.XXXXXX")
trap 'rm -rf "$work"' EXIT

bodyx() { awk -v h="$2" 'index($0, h) == 1 {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 alloc packed follow choice
  alloc=$(bodyx "$m" 'static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear')
  packed=$(bodyx "$m" 'static IOSurfaceRef cocoa_gl_present_packed(uint32_t w, uint32_t h, bool half)')
  follow=$(bodyx "$m" 'static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)')
  grep -q 'kCVPixelFormatType_Lossless_32BGRA' <<<"$packed" && grep -q 'kCVPixelFormatType_Lossless_64RGBAHalf' <<<"$packed" &&
    grep -q 'CVPixelBufferGetIOSurface(pb)' <<<"$packed" && grep -q 'CFRetain(surf);' <<<"$packed" ||
    echo "the surfaces are not made lossless-compressed (or not kept)"
  # The statement that chooses a lossless surface, on one line, spaces squeezed.
  choice=$(awk '/bool packed = /{on=1} on {printf "%s ", $0} on && /;/ {exit}' <<<"$alloc" | tr -s ' \t' ' ')
  [[ $choice == *'bool packed = present_lossless == 1 && (!half || '*'present_lossless_half == 1'* ]] ||
    echo "the switch or the half-float fallback is not used"
  local hc at_cs at_hc
  hc=$(awk '/bool half_checked = /{on=1} on {printf "%s ", $0} on && /;/ {exit}' <<<"$alloc" | tr -s ' \t' ' ')
  [[ $hc == *'linear || (deep && cocoa_gl_present_hdr_wanted())'* ]] &&
    [[ $choice == *'(!half || (half_checked && present_lossless_half == 1));'* ]] ||
    echo "half float lossless where it was not checked on screen (only HDR and extra brightness were)"
  [[ $hc == *'bool half_checked = present_color == 1 && ('* ]] ||
    echo "half float lossless without the layer's EDR (OMACVM_GL_COLOR=native): not checked on screen"
  # present_color is read lazily by cocoa_gl_present_colorspace: before that call it is still -1.
  at_cs=$(grep -n 'cocoa_gl_present_colorspace(deep, linear)' <<<"$alloc" | head -1 | cut -d: -f1)
  at_hc=$(grep -n 'bool half_checked = ' <<<"$alloc" | head -1 | cut -d: -f1)
  [[ -z $at_hc || ( -n $at_cs && $at_cs -lt $at_hc ) ]] ||
    echo "present_color is used before cocoa_gl_present_colorspace reads it (the first surfaces would stay plain)"
  ! grep -q "'l10r'" <<<"$alloc" ||
    echo "10-bit 'l10r' surfaces are made (on an XDR panel their HDR colours did not show like half float)"
  grep -q 'packed ? cocoa_gl_present_packed(w, h, half)' <<<"$alloc" || echo "the surfaces are still plain"
  grep -q 'present_lossless = 0;' <<<"$alloc" && grep -q 'present_lossless_half = 0;' <<<"$alloc" &&
    grep -q 'goto again;' <<<"$alloc" || echo "no plain surfaces after a lossless one fails (a black window)"
  grep -q "fmt == 'RGhA' || fmt == '&RhA'" <<<"$follow" || echo "the layer has no EDR for lossless half-float surfaces (HDR, extra brightness)"
  grep -q 'getenv("OMACVM_GL_LOSSLESS")' <<<"$alloc" || echo "OMACVM_GL_LOSSLESS is not read"
  grep -q '@available(macOS 27.0, \*)' <<<"$alloc" || echo "lossless surfaces on a macOS they are not checked on"
  ! grep -q 'IOSurfaceLock(present_surf\|IOSurfaceGetBaseAddress(present_surf' "$m" ||
    echo "a present surface is read on the CPU (a compressed one cannot be)"
  # The check mode keeps lossless surfaces (it reads a plain copy), so it checks what is shown.
  ! grep -q 'getenv("OMACVM_GL_PRESENT_DAMAGE")' <<<"$alloc" ||
    echo "the partial present's check mode makes plain surfaces (it would not check the lossless ones that are shown)"
  # glReadPixels with a present surface attached crashes on a compressed one: nothing may do it.
  local readers
  readers=$(present_readers "$m")
  [[ -z $readers ]] ||
    echo "a present surface is read back with glReadPixels: ${readers//$'\n'/ }"
}
# Functions that call glReadPixels while a present surface (present_tex[...]) is the framebuffer's attachment.
present_readers() {
  awk '
    /^[A-Za-z_].*\(/ && !/;[[:space:]]*$/ { fn = $0; sub(/\(.*/, "", fn); n = split(fn, p, /[ *]+/); fn = p[n]; att = 0; st = "" }
    { st = st $0 }
    /;/ {
      if (st ~ /glFramebufferTexture2D\(/) att = (st ~ /present_tex\[/)
      if (st ~ /glReadPixels\(/ && att && !(fn in seen)) { seen[fn] = 1; print fn }
      st = ""
    }' "$1"
}

cat > "$work/old.m" <<'EOF2'
static void cocoa_gl_layer_follow(CALayer *layer, IOSurfaceRef surf, bool linear)
{
    BOOL hdr = IOSurfaceGetPixelFormat(surf) == 'RGhA' &&
}
static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)
{
    const char *pd = getenv("OMACVM_GL_PRESENT_DAMAGE");
    bool packed = present_lossless == 1 && (!half || present_lossless_half == 1);
    for (int i = 0; i < present_nsurf && ok; i++) {
        present_surf[i] = IOSurfaceCreate((CFDictionaryRef)props);
    }
    (id)kIOSurfacePixelFormat: @(ten ? (uint32_t)'l10r' : half ? (uint32_t)'RGhA' : (uint32_t)'BGRA'),
}

static void cocoa_gl_present_snapshot(unsigned n)
{
    glBindFramebuffer(GL_FRAMEBUFFER, present_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_RECTANGLE, present_tex[n], 0);
    glReadPixels(0, 0, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, a);
}

static void cocoa_gl_present_guest(GLuint t)
{
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_RECTANGLE, present_tex[0], 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, t, 0);
    glReadPixels(0, 0, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, a);
}
EOF2
# The colour check put in before present_color is read: the first surfaces would never be lossless.
cat > "$work/early.m" <<'EOF2'
static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)
{
    bool half_checked = present_color == 1 &&
                        (linear || (deep && cocoa_gl_present_hdr_wanted()));
    CGColorSpaceRef cs = cocoa_gl_present_colorspace(deep, linear);
}
EOF2
[[ $(problems "$work/early.m") == *"present_color is used before"* ]] ||
  { echo "test-present-lossless: the checks miss present_color read too early" >&2; exit 1; }
# #536's first form: no colour check (OMACVM_GL_COLOR=native gave '&RhA' without EDR).
cat > "$work/nocolor.m" <<'EOF2'
static bool cocoa_gl_present_alloc(uint32_t w, uint32_t h, bool deep, bool linear)
{
    CGColorSpaceRef cs = cocoa_gl_present_colorspace(deep, linear);
    bool half_checked = linear || (deep && cocoa_gl_present_hdr_wanted());
}
EOF2
[[ $(problems "$work/nocolor.m") == *"without the layer's EDR"* ]] ||
  { echo "test-present-lossless: the checks miss half float lossless without EDR" >&2; exit 1; }
old=$(problems "$work/old.m")
for want in "not made lossless-compressed" "still plain" "no plain surfaces after" "OMACVM_GL_LOSSLESS is not read" "not checked on" \
  "no EDR for lossless" "where it was not checked on screen" "10-bit 'l10r' surfaces are made" "check mode makes plain surfaces" "read back with glReadPixels: cocoa_gl_present_snapshot"; do
  [[ $old == *"$want"* ]] || { echo "test-present-lossless: the checks miss the old code: $want" >&2; exit 1; }
done
[[ $old != *cocoa_gl_present_guest* ]] ||
  { echo "test-present-lossless: a readback of another texture counts as a present surface's" >&2; exit 1; }
echo "test-present-lossless: the checks catch the code without it"

if [[ $# -ge 1 ]]; then
  out=$(problems "$1")
  if [[ -n $out ]]; then
    echo "test-present-lossless: $1:" >&2
    echo "$out" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "test-present-lossless: $1: wiring ok"
fi
