/* Every texture format vrend offers moves as many bytes per row in GL as in
 * the guest's buffers (virgl-transfer-row-size.patch). R8G8_R8B8 did not:
 * stored as GL_RGBA8 at the full width, its readbacks wrote twice the
 * guest's buffer (a QEMU heap overflow, mpv's VA-API probe hit it). No GL
 * context is needed: this checks the format tables and the row check. */
#include "vrend/vrend_formats.c"

#define TABLE(t) { #t, t, ARRAY_SIZE(t) }
static const struct {
   const char *name;
   const struct vrend_format_table *entries;
   unsigned count;
} tables[] = {
   TABLE(base_rgba_formats), TABLE(gl_base_rgba_formats), TABLE(base_depth_formats),
   TABLE(gl_z32_format), TABLE(gles_z32_format), TABLE(rg_base_formats),
   TABLE(integer_base_formats), TABLE(integer_3comp_formats), TABLE(float_base_formats),
   TABLE(integer_rg_formats), TABLE(float_rg_formats), TABLE(float_3comp_formats),
   TABLE(la_formats_fallback), TABLE(la_formats_compat), TABLE(snorm_formats),
   TABLE(snorm_la_formats), TABLE(dxtn_formats), TABLE(dxtn_srgb_formats),
   TABLE(etc2_formats), TABLE(astc_formats), TABLE(rgtc_formats), TABLE(srgb_formats),
   TABLE(bit10_formats), TABLE(gl_bit10_formats), TABLE(gles_bit10_formats),
   TABLE(packed_float_formats), TABLE(exponent_float_formats), TABLE(bptc_formats),
   TABLE(gl_bgra_formats), TABLE(macos_bgra_formats), TABLE(gles_bgra_formats),
};

int main(void)
{
   static const uint32_t widths[] = { 1, 2, 3, 127, 128, 4096 };
   unsigned checked = 0;
   bool passed = true;

   for (unsigned t = 0; t < ARRAY_SIZE(tables); t++) {
      for (unsigned i = 0; i < tables[t].count; i++) {
         const struct vrend_format_table *e = &tables[t].entries[i];
         if (e->format == VIRGL_FORMAT_R8G8_R8B8_UNORM) {
            fprintf(stderr, "FAIL: %s offers R8G8_R8B8 again\n", tables[t].name);
            passed = false;
         }
         for (unsigned w = 0; w < ARRAY_SIZE(widths); w++) {
            if (!vrend_format_gl_rows_fit(e->format, e->glformat, e->gltype, widths[w])) {
               fprintf(stderr, "FAIL: %s format %d: GL rows longer than the guest's (width %u)\n",
                       tables[t].name, e->format, widths[w]);
               passed = false;
            }
         }
         checked++;
      }
   }
   printf("%s: %u table entries move no more per row in GL than in the guest\n",
          passed ? "PASS" : "FAIL", checked);

   /* The check itself: the old R8G8_R8B8 entry is refused, the same width in
    * RGBA8 passes, a pair it does not know passes. */
   if (vrend_format_gl_rows_fit(VIRGL_FORMAT_R8G8_R8B8_UNORM, GL_RGBA, GL_UNSIGNED_BYTE, 128) ||
       !vrend_format_gl_rows_fit(VIRGL_FORMAT_R8G8B8A8_UNORM, GL_RGBA, GL_UNSIGNED_BYTE, 128) ||
       !vrend_format_gl_rows_fit(VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 128)) {
      fprintf(stderr, "FAIL: the row check\n");
      passed = false;
   } else {
      printf("PASS: the row check refuses a 2x1 block stored as one RGBA8 texel per pixel\n");
   }
   return passed ? 0 : 1;
}
