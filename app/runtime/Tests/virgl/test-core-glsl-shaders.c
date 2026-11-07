/* The GLSL version the renderer asks for on a core profile.
 * Apple's core profile (GLSL 4.10) refuses "#version 130", extensions it does
 * not list (GL_ARB_draw_instanced) and floatBitsToInt() and friends below
 * GLSL 3.30. One refused shader used to stop the guest's whole GL context, so
 * every later draw of that app was black. Translates TGSI offline, checks the
 * text, then compiles it with the Mac's own OpenGL (a CGL core profile context,
 * no window) when one is available. */
#include <epoxy/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tgsi/tgsi_text.h"
#include "vrend/vrend_shader.h"
#include "vrend/vrend_strbuf.h"
#include "cgl-context.h"

static bool gl_compiles(const char *name, GLenum type, const char *glsl)
{
   GLuint s = glCreateShader(type);
   GLint ok = 0;
   glShaderSource(s, 1, &glsl, NULL);
   glCompileShader(s);
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048] = {0};
      glGetShaderInfoLog(s, sizeof(log), NULL, log);
      printf("FAIL: %s does not compile:\n%s\n%s\n", name, log, glsl);
   }
   glDeleteShader(s);
   return ok;
}

static GLenum stage_type(const char *text)
{
   return !strncmp(text, "VERT", 4) ? GL_VERTEX_SHADER :
          !strncmp(text, "GEOM", 4) ? GL_GEOMETRY_SHADER :
          !strncmp(text, "TESS_CTRL", 9) ? GL_TESS_CONTROL_SHADER :
          !strncmp(text, "TESS_EVAL", 9) ? GL_TESS_EVALUATION_SHADER : GL_FRAGMENT_SHADER;
}

/* the host GL a translation is for: the Mac's (desktop 4.1 without cull distances), a
 * desktop GL with cull distances, GLES 3.2 */
enum host { HOST_MAC, HOST_CULL, HOST_GLES };

static bool translate(const char *name, const char *text, const struct vrend_shader_key *key,
                      enum host host, char glsl[32768], struct vrend_variable_shader_info *var)
{
   static struct tgsi_token tokens[4096];
   struct vrend_shader_cfg cfg = {
      .glsl_version = host == HOST_GLES ? 320 : 410,
      .max_draw_buffers = 8,
      .use_gles = host == HOST_GLES,
      .use_core_profile = host != HOST_GLES,
      .use_explicit_locations = 1,
      .has_gpu_shader5 = 1,
      .use_integer = 1,
      .has_cull_distance = host == HOST_CULL,
   };
   struct vrend_shader_info info = {0};
   struct vrend_strarray output = {0};
   memset(var, 0, sizeof(*var));
   if (!tgsi_text_translate(text, tokens, 4096)) {
      printf("FAIL: %s TGSI parsing\n", name);
      return false;
   }
   if (!strarray_alloc(&output, 3) ||
       !vrend_convert_shader(NULL, &cfg, tokens, 0, key, &info, var, &output)) {
      printf("FAIL: %s translation\n", name);
      return false;
   }
   glsl[0] = 0;
   for (int i = 0; i < output.num_strings; i++)
      strncat(glsl, output.strings[i].buf, 32768 - strlen(glsl) - 1);
   strarray_free(&output, true);
   return true;
}

static int convert(const char *name, const char *text, const struct vrend_shader_key *key,
                   const char *must, const char *must_not, bool have_gl)
{
   struct vrend_variable_shader_info variable_info;
   static char glsl[32768];
   if (!translate(name, text, key, HOST_MAC, glsl, &variable_info))
      return 1;
   /* Every core profile shader: GLSL 3.30, no extension that 3.30 has in core. */
   if (strncmp(glsl, "#version 330\n", 13) || strstr(glsl, "GL_ARB_shader_bit_encoding") ||
       strstr(glsl, "GL_ARB_explicit_attrib_location") || (must && !strstr(glsl, must)) ||
       (must_not && strstr(glsl, must_not))) {
      printf("FAIL: %s:\n%s\n", name, glsl);
      return 1;
   }
   if (have_gl && !gl_compiles(name, stage_type(text), glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

/* Does a gl_PerVertex block named NAME ("gl_out[]", "gl_in[]") hold gl_ClipDistance? */
static bool block_has_clip(const char *glsl, const char *name)
{
   for (const char *b = strstr(glsl, "gl_PerVertex {"); b; b = strstr(b + 1, "gl_PerVertex {")) {
      const char *end = strchr(b, '}');
      const char *semi = end ? strchr(end, ';') : NULL;
      if (!semi)
         return false;
      char tail[64] = "";
      snprintf(tail, sizeof(tail), "%.*s", (int)(semi - end), end);
      const char *c = strstr(b, "gl_ClipDistance");
      if (c && c < end && strstr(tail, name))
         return true;
   }
   return false;
}

/* #589 (virgl-shader-tess-clip-varyings.patch): the clip distances between a tessellation
 * control and an evaluation shader. On the Mac (WANT distances) they go as the varyings
 * omacvm_clip0[] (omacvm_clip1[] for more than 4) and are in no gl_out[]/gl_in[] block or
 * access: Apple's Metal pipeline build failed on those, every draw ran on its CPU vertex path.
 * WANT 0: gl_PerVertex as before. Compiling one stage does not build a pipeline: this is the
 * text; the draws on the GPU are the M1 rows (work/gpu-1102/v589). */
static int tess_clip(const char *name, const char *text, const struct vrend_shader_key *key,
                     enum host host, int want, const char *must, bool have_gl)
{
   static char glsl[32768];
   struct vrend_variable_shader_info var;
   if (!translate(name, text, key, host, glsl, &var))
      return 1;
   bool tcs = stage_type(text) == GL_TESS_CONTROL_SHADER;
   bool block_clip = block_has_clip(glsl, tcs ? "gl_out[]" : "gl_in[]");
   bool access = strstr(glsl, tcs ? "gl_out[gl_InvocationID].gl_ClipDistance" : "].gl_ClipDistance") != NULL;
   bool decl0 = strstr(glsl, tcs ? "out vec4 omacvm_clip0[];" : "in vec4 omacvm_clip0[];") != NULL;
   bool decl1 = strstr(glsl, tcs ? "out vec4 omacvm_clip1[];" : "in vec4 omacvm_clip1[];") != NULL;
   bool ok = want ? !block_clip && !access && decl0 && decl1 == (want > 4)
                  : !strstr(glsl, "omacvm_clip");
   if (tcs)
      ok = ok && var.tess_clip_out == (want > 0) && (!want || var.num_out_clip == want);
   if (!ok || (must && !strstr(glsl, must))) {
      printf("FAIL: %s (want %d; gl_PerVertex clip %d, clip access %d, omacvm_clip0 %d, "
             "omacvm_clip1 %d, tess_clip_out %d, num_out_clip %d):\n%s\n", name, want, block_clip,
             access, decl0, decl1, var.tess_clip_out, var.num_out_clip, glsl);
      return 1;
   }
   have_gl = have_gl && host == HOST_MAC;
   if (have_gl && !gl_compiles(name, stage_type(text), glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

#define TCS_HEAD "TESS_CTRL\nPROPERTY TCS_VERTICES_OUT 3\n"
#define TES_HEAD "TESS_EVAL\nPROPERTY TES_PRIM_MODE 4\nPROPERTY TES_SPACING 2\n" \
   "PROPERTY TES_VERTEX_ORDER_CW 0\nPROPERTY TES_POINT_MODE 0\n"
#define TCS_LEVELS "DCL OUT[2], TESSOUTER\nDCL OUT[3], TESSINNER\n"
#define TCS_LEVELS_SET "MOV OUT[2].x, IMM[0].xxxx\nMOV OUT[2].y, IMM[0].xxxx\n" \
   "MOV OUT[2].z, IMM[0].xxxx\nMOV OUT[3].x, IMM[0].xxxx\n"
#define TES_POS "MUL TEMP[0], IN[0][0], SV[0].xxxx\nMAD TEMP[0], IN[1][0], SV[0].yyyy, TEMP[0]\n" \
   "MAD TEMP[0], IN[2][0], SV[0].zzzz, TEMP[0]\nMOV OUT[0], TEMP[0]\n"

/* the vertex shader's gl_ClipDistance[0] passed on (test-whole-program-shapes.c C15/C16) */
static const char *tcs_clip1 =
   TCS_HEAD "PROPERTY NUM_CLIPDIST_ENABLED 1\n"
   "DCL IN[][0], POSITION\nDCL IN[][1], CLIPDIST[0]\nDCL SV[0], INVOCATIONID\n"
   "DCL OUT[][0], POSITION\nDCL OUT[][1], CLIPDIST[0]\n" TCS_LEVELS "DCL ADDR[0]\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     0.0000}\n"
   "UARL ADDR[0].x, SV[0].xxxx\nMOV OUT[ADDR[0].x][0], IN[ADDR[0].x][0]\n"
   "MOV OUT[ADDR[0].x][1].x, IN[ADDR[0].x][1].xxxx\n" TCS_LEVELS_SET "END\n";
static const char *tes_clip1 =
   TES_HEAD "PROPERTY NUM_CLIPDIST_ENABLED 1\n"
   "DCL IN[][0], POSITION\nDCL IN[][1], CLIPDIST[0]\nDCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\nDCL OUT[1], CLIPDIST[0]\nDCL TEMP[0..1]\n" TES_POS
   "MUL TEMP[1].x, IN[0][1].xxxx, SV[0].xxxx\nMAD TEMP[1].x, IN[1][1].xxxx, SV[0].yyyy, TEMP[1].xxxx\n"
   "MAD TEMP[1].x, IN[2][1].xxxx, SV[0].zzzz, TEMP[1].xxxx\nMOV OUT[1].x, TEMP[1].xxxx\nEND\n";
/* eight distances written by the control shader, read by the evaluation shader with an
 * indirect index (vertex 1, distance 4 * ADDR + 1) */
static const char *tcs_clip8 =
   TCS_HEAD "PROPERTY NUM_CLIPDIST_ENABLED 8\n"
   "DCL IN[][0], POSITION\nDCL SV[0], INVOCATIONID\n"
   "DCL OUT[][0], POSITION\nDCL OUT[][1], CLIPDIST[0]\nDCL OUT[][4], CLIPDIST[1]\n"
   "DCL OUT[2], TESSOUTER\nDCL OUT[3], TESSINNER\nDCL ADDR[0]\n"
   "IMM[0] FLT32 {    1.0000,     0.2500,     0.5000,     0.7500}\n"
   "UARL ADDR[0].x, SV[0].xxxx\nMOV OUT[ADDR[0].x][0], IN[ADDR[0].x][0]\n"
   "MOV OUT[ADDR[0].x][1], IMM[0]\nMOV OUT[ADDR[0].x][4], IMM[0].wzyx\n" TCS_LEVELS_SET "END\n";
static const char *tes_clip8 =
   TES_HEAD "PROPERTY NUM_CLIPDIST_ENABLED 1\n"
   "DCL IN[][0], POSITION\nDCL IN[][1..2], ARRAY(1), CLIPDIST[0]\nDCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\nDCL OUT[1], CLIPDIST[0]\nDCL TEMP[0..1]\nDCL ADDR[0]\n"
   "IMM[0] INT32 {1, 0, 0, 0}\n" TES_POS
   "UARL ADDR[0].x, IMM[0].xxxx\nMOV TEMP[1].x, IN[1][ADDR[0].x+1].yyyy\n"
   "MOV TEMP[1].y, IN[2][2].wwww\nADD OUT[1].x, TEMP[1].xxxx, TEMP[1].yyyy\nEND\n";
/* an evaluation shader that reads no clip distance */
static const char *tes_noclip =
   TES_HEAD "DCL IN[][0], POSITION\nDCL SV[0], TESSCOORD\nDCL OUT[0], POSITION\nDCL TEMP[0]\n"
   TES_POS "END\n";

static char *separable(const char *text)
{
   static char buf[8][4096];
   static int n;
   char *b = buf[n++ % 8];
   const char *nl = strchr(text, '\n');
   snprintf(b, 4096, "%.*sPROPERTY SEPARABLE_PROGRAM 1\n%s", (int)(nl - text + 1), text, nl + 1);
   return b;
}

static int tess_clip_rows(bool have_gl)
{
   int failed = 0;
   struct vrend_shader_key key;
   for (int sep = 0; sep < 2; sep++) {
      char name[160];
      const char *how = sep ? "separable" : "whole";
      /* the control shader: the key of a whole program carries the evaluation shader's count */
      memset(&key, 0, sizeof(key));
      key.num_in_clip = 1;
      key.num_out_clip = sep ? 0 : 1;
      snprintf(name, sizeof(name), "%s TCS passes 1 clip distance as omacvm_clip0[]", how);
      failed |= tess_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_MAC, 1,
                          "omacvm_clip0[gl_InvocationID].x = clip_dist_temp[0].x;", have_gl);
      memset(&key, 0, sizeof(key));
      snprintf(name, sizeof(name), "%s TCS passes 8 clip distances as omacvm_clip0[] and omacvm_clip1[]", how);
      failed |= tess_clip(name, sep ? separable(tcs_clip8) : tcs_clip8, &key, HOST_MAC, 8,
                          "omacvm_clip1[gl_InvocationID].w = clip_dist_temp[1].w;", have_gl);
      /* the evaluation shader after it (key from the control shader's variable info) */
      memset(&key, 0, sizeof(key));
      key.tcs_present = 1;
      key.tess_clip_in = 1;
      key.num_in_clip = 1;
      snprintf(name, sizeof(name), "%s TES reads omacvm_clip0[]", how);
      failed |= tess_clip(name, sep ? separable(tes_clip1) : tes_clip1, &key, HOST_MAC, 1,
                          "omacvm_clip0[2][0]", have_gl);
      snprintf(name, sizeof(name), "%s TES that reads no clip distance still declares omacvm_clip0[]", how);
      failed |= tess_clip(name, sep ? separable(tes_noclip) : tes_noclip, &key, HOST_MAC, 1, NULL,
                          have_gl);
      key.num_in_clip = 8;
      snprintf(name, sizeof(name), "%s TES reads 8 distances, one with an indirect index", how);
      failed |= tess_clip(name, sep ? separable(tes_clip8) : tes_clip8, &key, HOST_MAC, 8,
                          " < 4 ? omacvm_clip0[1][", have_gl);
      /* a control shader that kept gl_out[] (no tess_clip_in): gl_in[] as before */
      key.tess_clip_in = 0;
      key.num_in_clip = 1;
      snprintf(name, sizeof(name), "%s TES after a TCS with gl_out[] clip distances keeps gl_in[]", how);
      failed |= tess_clip(name, sep ? separable(tes_clip1) : tes_clip1, &key, HOST_MAC, 0,
                          "gl_in[0].gl_ClipDistance", have_gl);
      /* other hosts keep their GLSL (text only) */
      memset(&key, 0, sizeof(key));
      key.num_in_clip = 1;
      snprintf(name, sizeof(name), "%s TCS on a GL with cull distances keeps gl_out[]", how);
      failed |= tess_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_CULL, 0, NULL, false);
      snprintf(name, sizeof(name), "%s TCS on GLES keeps gl_out[]", how);
      failed |= tess_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_GLES, 0, NULL, false);
      key.num_out_cull = 1;
      snprintf(name, sizeof(name), "%s TCS with a cull distance keeps gl_out[]", how);
      failed |= tess_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_MAC, 0, NULL, false);
   }
   /* a control shader whose varyings would not fit: gl_out[] as before, never refused */
   static char full[8192];
   int n = snprintf(full, sizeof(full), TCS_HEAD "PROPERTY NUM_CLIPDIST_ENABLED 1\n"
                    "DCL IN[][0], POSITION\nDCL SV[0], INVOCATIONID\nDCL OUT[][0], POSITION\n"
                    "DCL OUT[][1], CLIPDIST[0]\nDCL OUT[2], TESSOUTER\nDCL OUT[3], TESSINNER\n");
   for (int i = 0; i < 28; i++)
      n += snprintf(full + n, sizeof(full) - n, "DCL OUT[][%d], GENERIC[%d]\n", 4 + i, i);
   n += snprintf(full + n, sizeof(full) - n, "DCL ADDR[0]\nIMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     0.0000}\n"
                 "UARL ADDR[0].x, SV[0].xxxx\nMOV OUT[ADDR[0].x][0], IN[ADDR[0].x][0]\n"
                 "MOV OUT[ADDR[0].x][1].x, IMM[0].xxxx\n");
   for (int i = 0; i < 28; i++)
      n += snprintf(full + n, sizeof(full) - n, "MOV OUT[ADDR[0].x][%d], IMM[0]\n", 4 + i);
   snprintf(full + n, sizeof(full) - n, TCS_LEVELS_SET "END\n");
   memset(&key, 0, sizeof(key));
   failed |= tess_clip("TCS with 28 varyings beside its clip distance keeps gl_out[] (no slot left)",
                       full, &key, HOST_MAC, 0, "gl_out[gl_InvocationID].gl_ClipDistance[0] = clip_dist_temp[0].x;",
                       false);
   return failed;
}

/* #589 (virgl-shader-vs-tes-clip-varyings.patch): a vertex shader whose clip distances go
 * straight to an evaluation shader (no control shader). On the Mac (WANT distances) it
 * writes the varyings omacvm_clip0 (omacvm_clip1 for more than 4) and has no gl_ClipDistance
 * at all (Apple's Metal pipeline build failed on it, and a loose gl_ClipDistance beside the
 * block crashed Apple's GLSL compiler); its variable info says so (tess_clip_out). #692
 * (virgl-shader-vs-tcs-clip-varyings.patch): before a control shader (key->tcs_present) the
 * same as omacvm_vclip0/omacvm_vclip1. WANT 0: the text as before. The next shader's key
 * comes from vrend_sync_shader_io, which this test does not reach (vs_tcs_pair() below fills
 * it the same way): test-whole-program-shapes.c C17, C18, C21-C24 and the L rows draw it. */
static int vs_tes_clip(const char *name, const char *text, const struct vrend_shader_key *key,
                       enum host host, int want, const char *must, bool have_gl)
{
   static char glsl[32768];
   struct vrend_variable_shader_info var;
   if (!translate(name, text, key, host, glsl, &var))
      return 1;
   const char *vn = key->tcs_present ? "omacvm_vclip" : "omacvm_clip";
   char d0[48], d1[48];
   snprintf(d0, sizeof(d0), "out vec4 %s0;", vn);
   snprintf(d1, sizeof(d1), "out vec4 %s1;", vn);
   bool clip = strstr(glsl, "gl_ClipDistance") != NULL;
   bool decl0 = strstr(glsl, d0) != NULL;
   bool decl1 = strstr(glsl, d1) != NULL;
   bool ok = want ? !clip && decl0 && decl1 == (want > 4) && var.tess_clip_out &&
                    var.num_out_clip == want
                  : !strstr(glsl, "omacvm_clip") && !strstr(glsl, "omacvm_vclip") && !var.tess_clip_out;
   if (!ok || (must && !strstr(glsl, must))) {
      printf("FAIL: %s (want %d; gl_ClipDistance %d, %s0 %d, %s1 %d, "
             "tess_clip_out %d, num_out_clip %d):\n%s\n", name, want, clip, vn, decl0, vn, decl1,
             var.tess_clip_out, var.num_out_clip, glsl);
      return 1;
   }
   have_gl = have_gl && host == HOST_MAC;
   if (have_gl && !gl_compiles(name, GL_VERTEX_SHADER, glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

/* gl_ClipDistance[0] = y beside a generic varying (test-whole-program-shapes.c C21/C22) */
static const char *vs_clip1 =
   "VERT\nPROPERTY NUM_CLIPDIST_ENABLED 1\nDCL IN[0]\nDCL OUT[0], POSITION\n"
   "DCL OUT[1], CLIPDIST[0]\nDCL OUT[2], GENERIC[0]\n"
   "MOV OUT[0], IN[0]\nMOV OUT[1].x, IN[0].yyyy\nMOV OUT[2], IN[0]\nEND\n";
static const char *vs_clip8 =
   "VERT\nPROPERTY NUM_CLIPDIST_ENABLED 8\nDCL IN[0]\nDCL OUT[0], POSITION\n"
   "DCL OUT[1], CLIPDIST[0]\nDCL OUT[2], CLIPDIST[1]\n"
   "MOV OUT[0], IN[0]\nMOV OUT[1], IN[0]\nMOV OUT[2], IN[0].wzyx\nEND\n";
static const char *vs_clip5 =
   "VERT\nPROPERTY NUM_CLIPDIST_ENABLED 5\nDCL IN[0]\nDCL OUT[0], POSITION\n"
   "DCL OUT[1], CLIPDIST[0]\nDCL OUT[2].x, CLIPDIST[1]\n"
   "MOV OUT[0], IN[0]\nMOV OUT[1], IN[0]\nMOV OUT[2].x, IN[0].wwww\nEND\n";

static int vs_tes_clip_rows(bool have_gl)
{
   int failed = 0;
   struct vrend_shader_key key;
   char name[160];
   for (int sep = 0; sep < 2; sep++) {
      const char *how = sep ? "separable" : "whole";
      /* the keys vrend_fill_shader_key gives: an evaluation shader, no control shader; a
       * whole program's evaluation shader redeclares gl_in[] (use_pervertex_in) */
      memset(&key, 0, sizeof(key));
      key.tes_present = 1;
      key.use_pervertex_in = !sep;
      snprintf(name, sizeof(name), "%s VS -> TES (no TCS) passes 1 clip distance as omacvm_clip0", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_MAC, 1,
                            "omacvm_clip0.x = clip_dist_temp[0].x;", have_gl);
      snprintf(name, sizeof(name), "%s VS -> TES (no TCS) passes 8 clip distances as omacvm_clip0 and omacvm_clip1", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip8) : vs_clip8, &key, HOST_MAC, 8,
                            "omacvm_clip1.w = clip_dist_temp[1].w;", have_gl);
      /* the evaluation shader after it (key from the vertex shader's variable info) */
      struct vrend_shader_key tes_key;
      memset(&tes_key, 0, sizeof(tes_key));
      tes_key.tes_present = 1;
      tes_key.tess_clip_in = 1;
      tes_key.num_in_clip = 1;
      snprintf(name, sizeof(name), "%s TES after a VS (no TCS) reads omacvm_clip0[]", how);
      failed |= tess_clip(name, sep ? separable(tes_clip1) : tes_clip1, &tes_key, HOST_MAC, 1,
                          "omacvm_clip0[2][0]", have_gl);
      /* the geometry shader after the evaluation shader changes nothing for the VS */
      key.gs_present = 1;
      snprintf(name, sizeof(name), "%s VS -> TES -> GS (no TCS) passes 1 clip distance as omacvm_clip0", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_MAC, 1,
                            "omacvm_clip0.x = clip_dist_temp[0].x;", have_gl);
      key.gs_present = 0;
      /* a control shader in between: kept gl_ClipDistance up to 3.2.19; vs_tcs_clip_rows()
       * has the rows since #692 */
      /* other hosts and a cull distance after it (text only) */
      snprintf(name, sizeof(name), "%s VS -> TES on a GL with cull distances keeps gl_ClipDistance", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_CULL, 0,
                            "gl_ClipDistance[0] = clip_dist_temp[0].x;", false);
      snprintf(name, sizeof(name), "%s VS -> TES on GLES keeps its text", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_GLES, 0, NULL, false);
      key.num_out_cull = 1;
      snprintf(name, sizeof(name), "%s VS -> TES with a cull distance keeps gl_ClipDistance", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_MAC, 0, NULL, false);
      /* the last stage: no evaluation shader */
      memset(&key, 0, sizeof(key));
      snprintf(name, sizeof(name), "%s VS as the last stage keeps gl_ClipDistance", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_MAC, 0,
                            "gl_ClipDistance[0] = clip_dist_temp[0].x;", have_gl);
   }
   /* a vertex shader whose varyings would not fit (position, clip, 30 generics): as before,
    * never refused */
   static char full[8192];
   int n = snprintf(full, sizeof(full), "VERT\nPROPERTY NUM_CLIPDIST_ENABLED 1\nDCL IN[0]\n"
                    "DCL OUT[0], POSITION\nDCL OUT[1], CLIPDIST[0]\n");
   for (int i = 0; i < 30; i++)
      n += snprintf(full + n, sizeof(full) - n, "DCL OUT[%d], GENERIC[%d]\n", 2 + i, i);
   n += snprintf(full + n, sizeof(full) - n, "MOV OUT[0], IN[0]\nMOV OUT[1].x, IN[0].yyyy\n");
   for (int i = 0; i < 30; i++)
      n += snprintf(full + n, sizeof(full) - n, "MOV OUT[%d], IN[0]\n", 2 + i);
   snprintf(full + n, sizeof(full) - n, "END\n");
   memset(&key, 0, sizeof(key));
   key.tes_present = 1;
   key.use_pervertex_in = 1;
   failed |= vs_tes_clip("VS -> TES with 30 varyings beside its clip distance keeps gl_ClipDistance (no slot left)",
                         full, &key, HOST_MAC, 0, "gl_ClipDistance[0] = clip_dist_temp[0].x;", false);
   return failed;
}

/* #589 (virgl-shader-separable-patch-fill-writes.patch): between two separable stages on
 * desktop GL a control shader declares every patch varying from 0 up to its highest one
 * (virgl-shader-separable-patch-varyings.patch); it also writes the padding ones
 * ("patchNN = vec4(0.0);"): Apple's GL links a control shader with a patch output it never
 * writes, but its Metal pipeline build fails (the draws ran on its CPU vertex path; the M1
 * rows are in work/v589-rest). The written set must be the declared padding set: WRITE.
 * REAL: the patch varyings of the shader itself. Each patch output is declared once. */
static int patch_fill(const char *name, const char *text, const struct vrend_shader_key *key,
                      enum host host, uint64_t real, uint64_t write, const char *must,
                      bool have_gl)
{
   static char glsl[32768];
   struct vrend_variable_shader_info var;
   if (!translate(name, text, key, host, glsl, &var))
      return 1;
   bool tcs = stage_type(text) == GL_TESS_CONTROL_SHADER;
   uint64_t wrote = 0, declared = 0;
   bool twice = false;
   char what[32];
   for (int sid = 0; sid < 64; sid++) {
      snprintf(what, sizeof(what), "patch%02d = vec4(0.0);", sid);
      if (strstr(glsl, what))
         wrote |= 1ull << sid;
   }
   /* "patch out vec4 patch01;", "patch out vec4 patch02[2];" (in the evaluation shader "in") */
   const char *decl = tcs ? "patch out vec4 patch" : "patch in vec4 patch";
   for (const char *d = strstr(glsl, decl); d; d = strstr(d + 1, decl)) {
      char *end;
      long sid = strtol(d + strlen(decl), &end, 10);
      long n = *end == '[' ? strtol(end + 1, NULL, 10) : 1;
      for (long i = sid; i < sid + n && i < 64; i++) {
         twice |= (declared >> i) & 1;
         declared |= 1ull << i;
      }
   }
   bool ok = wrote == (tcs ? write : 0) && declared == (real | write) && !twice;
   if (!ok || (must && !strstr(glsl, must))) {
      printf("FAIL: %s (padding written 0x%llx, want 0x%llx; declared 0x%llx, want 0x%llx; "
             "one declared twice %d):\n%s\n", name, (unsigned long long)wrote,
             (unsigned long long)(tcs ? write : 0), (unsigned long long)declared,
             (unsigned long long)(real | write), twice, glsl);
      return 1;
   }
   have_gl = have_gl && host == HOST_MAC;
   if (have_gl && !gl_compiles(name, stage_type(text), glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

/* #589 (virgl-shader-indirect-temps.patch): temps the shader indexes at run time without an
 * ARRAY declaration. The guest's Mesa sends them for a clip distance output written in a loop
 * (virgl_tgsi_transform_instruction moves the output into a temp and keeps the indirect
 * index: MOV TEMP[ADDR[1].x][ADDR[0].x+18].x). Each was a plain "vec4 temp18;", so the write
 * "temp18[clamp(addr0 + 0, 0, 0)].x" did not compile on the Mac ("Swizzle of non-vector
 * primitive float") and a read gave one component in all four. Now the declaration from its
 * lowest indexed register on is one array; the rest of the GLSL is as before. MUST: strings
 * the text holds, MUST_NOT: one it must not.
 * #692 (virgl-shader-clip-copyback.patch): that Mesa copies only the first temp back
 * (MOV OUT[1], TEMP[18]), so distances 4..7 never reached OUT[2]; the GLSL now copies the
 * next temp too. COPY: that line (clip_dist_temp[1] = vec4(temp18[1]);), NULL: the text has
 * no such copy. */
#define CLIP_COPY "clip_dist_temp[1] = vec4(temp"
static int indirect_temp(const char *name, const char *text, const struct vrend_shader_key *key,
                         const char *must1, const char *must2, const char *must_not, const char *copy,
                         bool have_gl)
{
   static char glsl[32768];
   struct vrend_variable_shader_info var;
   if (!translate(name, text, key, HOST_MAC, glsl, &var))
      return 1;
   if ((must1 && !strstr(glsl, must1)) || (must2 && !strstr(glsl, must2)) ||
       (must_not && strstr(glsl, must_not)) || (copy ? !strstr(glsl, copy) : !!strstr(glsl, CLIP_COPY))) {
      printf("FAIL: %s (want \"%s\", \"%s\", %s\"%s\", not \"%s\"):\n%s\n", name, must1 ? must1 : "",
             must2 ? must2 : "", copy ? "" : "not ", copy ? copy : CLIP_COPY, must_not ? must_not : "", glsl);
      return 1;
   }
   if (have_gl && !gl_compiles(name, stage_type(text), glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

#define TCS_PATCH_PRE TCS_HEAD "DCL IN[][0], POSITION\nDCL SV[0], INVOCATIONID\n" \
   "DCL OUT[][0], POSITION\n" TCS_LEVELS
#define TCS_PATCH_POS "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     0.0000}\n" \
   "UARL ADDR[0].x, SV[0].xxxx\nMOV OUT[ADDR[0].x][0], IN[ADDR[0].x][0]\n" TCS_LEVELS_SET
/* patch varyings 1 and 3 (test-separable-pervertex.c D4 without its per-vertex varying) */
static const char *tcs_patch13 =
   TCS_PATCH_PRE "DCL OUT[4], PATCH[1]\nDCL OUT[5], PATCH[3]\nDCL ADDR[0]\n" TCS_PATCH_POS
   "MOV OUT[4], IMM[0].yxyx\nMOV OUT[5], IMM[0].yyxx\nEND\n";
/* only patch varying 1 (D7) */
static const char *tcs_patch1 =
   TCS_PATCH_PRE "DCL OUT[4], PATCH[1]\nDCL ADDR[0]\n" TCS_PATCH_POS
   "MOV OUT[4], IMM[0].yxyx\nEND\n";
/* a patch array at 2..3, written with an indirect index */
static const char *tcs_patch_array23 =
   TCS_PATCH_PRE "DCL OUT[4..5], ARRAY(1), PATCH[2]\nDCL ADDR[0..1]\n" TCS_PATCH_POS
   "UARL ADDR[1].x, SV[0].xxxx\nMOV OUT[ADDR[1].x+4], IMM[0].yxyx\nEND\n";
/* patch varying 1, a barrier and a return in an if: the writes come before both */
static const char *tcs_patch1_barrier =
   TCS_PATCH_PRE "DCL OUT[4], PATCH[1]\nDCL ADDR[0]\n" TCS_PATCH_POS
   "BARRIER\nUIF SV[0].xxxx\nRET\nENDIF\nMOV OUT[4], IMM[0].yxyx\nEND\n";
/* patch varyings 0 to 11: nothing to pad */
static const char *tcs_patch0_11 =
   TCS_PATCH_PRE "DCL OUT[4..15], ARRAY(1), PATCH[0]\nDCL ADDR[0]\n" TCS_PATCH_POS
   "MOV OUT[4], IMM[0].yxyx\nMOV OUT[15], IMM[0].yyxx\nEND\n";
/* the evaluation shader that reads patch varying 1 only (D1, D7) */
static const char *tes_patch1 =
   TES_HEAD "DCL IN[][0], POSITION\nDCL IN[1], PATCH[1]\nDCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\nDCL OUT[1], GENERIC[0]\nDCL TEMP[0]\n" TES_POS "MOV OUT[1], IN[1]\nEND\n";

static int patch_fill_rows(bool have_gl)
{
   int failed = 0;
   struct vrend_shader_key key;
   memset(&key, 0, sizeof(key));
   key.separable_out = 1;
   failed |= patch_fill("separable TCS, patch varyings 1 and 3: writes the padding 0 and 2",
                        separable(tcs_patch13), &key, HOST_MAC, 0xa, 0x5,
                        "{\npatch00 = vec4(0.0);\npatch02 = vec4(0.0);\n", have_gl);
   failed |= patch_fill("separable TCS, only patch varying 1: writes the padding 0",
                        separable(tcs_patch1), &key, HOST_MAC, 0x2, 0x1, "patch00 = vec4(0.0);", have_gl);
   failed |= patch_fill("separable TCS, a patch array at 2..3 with an indirect index: writes 0 and 1",
                        separable(tcs_patch_array23), &key, HOST_MAC, 0xc, 0x3, "patch out vec4 patch02[2];",
                        have_gl);
   failed |= patch_fill("separable TCS with a barrier and a return: the padding is written first",
                        separable(tcs_patch1_barrier), &key, HOST_MAC, 0x2, 0x1,
                        "{\npatch00 = vec4(0.0);\n", have_gl);
   /* kept as before */
   failed |= patch_fill("separable TCS, patch varyings 0 to 11: no padding",
                        separable(tcs_patch0_11), &key, HOST_MAC, 0xfff, 0, NULL, have_gl);
   memset(&key, 0, sizeof(key));
   failed |= patch_fill("TCS before a whole evaluation shader (separable_out 0): no padding",
                        separable(tcs_patch13), &key, HOST_MAC, 0xa, 0, NULL, have_gl);
   failed |= patch_fill("whole TCS, patch varyings 1 and 3: no padding", tcs_patch13, &key,
                        HOST_MAC, 0xa, 0, NULL, have_gl);
   key.separable_out = 1;
   failed |= patch_fill("separable TCS on GLES: no padding (its own names)", separable(tcs_patch13),
                        &key, HOST_GLES, 0xa, 0, "patch out vec4 patch1;", false);
   /* the evaluation shader declares its padding and writes nothing (as before) */
   memset(&key, 0, sizeof(key));
   key.separable_in = 1;
   key.tcs_present = 1;
   failed |= patch_fill("separable TES reading patch varying 1: declares the padding 0, writes none",
                        separable(tes_patch1), &key, HOST_MAC, 0x2, 0x1, "patch in vec4 patch00;", have_gl);
   return failed;
}

/* the control shader of the 3.2.19 gate's tcs-8loop row as the guest's Mesa 26.2.5 sent it
 * (work/release-3.2.19 r4-qemu-b-take2.log): a for loop copies gl_in[].gl_ClipDistance[i]
 * into gl_out[].gl_ClipDistance[i]; only OUT[1] is copied back from the temps (OUT[2],
 * distances 4..7, never: that is the guest's Mesa; the GLSL copies TEMP[19] itself, #692) */
static const char *tcs_loop8_guest =
   "TESS_CTRL\n"
   "PROPERTY TCS_VERTICES_OUT 3\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[][1], CLIPDIST\n"
   "DCL IN[][2], CLIPDIST[1]\n"
   "DCL SV[0], INVOCATIONID\n"
   "DCL OUT[][0].xy, POSITION\n"
   "DCL OUT[][1], CLIPDIST\n"
   "DCL OUT[][2], CLIPDIST[1]\n"
   "DCL OUT[3].xyz, TESSOUTER\n"
   "DCL OUT[4].x, TESSINNER\n"
   "DCL TEMP[0..13]\n"
   "DCL ADDR[0..1]\n"
   "IMM[0] UINT32 {0, 3, 2, 1}\n"
   "IMM[1] UINT32 {8, 1065353216, 0, 0}\n"
   "DCL TEMP[14..17]\n"
   "DCL TEMP[18..19]\n"
   "  0: UARL ADDR[1].x, SV[0].xxxx\n"
   "  1: MOV TEMP[4].xy, IN[ADDR[1].x][0].xyyy\n"
   "  2: UARL ADDR[1].x, SV[0].xxxx\n"
   "  3: MOV OUT[ADDR[1].x][0].xy, TEMP[4].xyxx\n"
   "  4: MOV TEMP[3].x, IMM[0].xxxx\n"
   "  5: BGNLOOP :0\n"
   "  6:   AND TEMP[5].x, TEMP[3].xxxx, IMM[0].yyyy\n"
   "  7:   ISHR TEMP[6].x, TEMP[3].xxxx, IMM[0].zzzz\n"
   "  8:   ISLT TEMP[7].xyz, TEMP[5].xxxx, IMM[0].zwyz\n"
   "  9:   MOV TEMP[8].x, TEMP[7].yxxx\n"
   " 10:   UARL ADDR[0].x, TEMP[6].xxxx\n"
   " 11:   UARL ADDR[1].x, SV[0].xxxx\n"
   " 12:   MOV TEMP[9], IN[ADDR[1].x][ADDR[0].x+1]\n"
   " 13:   MOV TEMP[10].x, TEMP[7].zxxx\n"
   " 14:   MOV TEMP[11].x, TEMP[7].xxxx\n"
   " 15:   UIF TEMP[11].xxxx :27\n"
   " 16:     UIF TEMP[8].xxxx :21\n"
   " 17:       MOV TEMP[12].x, TEMP[9].xxxx\n"
   " 18:       UARL ADDR[0].x, TEMP[6].xxxx\n"
   " 19:       UARL ADDR[1].x, SV[0].xxxx\n"
   " 20:       MOV TEMP[ADDR[1].x][ADDR[0].x+18].x, TEMP[12].xxxx\n"
   " 21:       MOV OUT[1], TEMP[18]\n"
   " 22:     ELSE :26\n"
   " 23:       MOV TEMP[2].y, TEMP[9].xyxx\n"
   " 24:       UARL ADDR[0].x, TEMP[6].xxxx\n"
   " 25:       UARL ADDR[1].x, SV[0].xxxx\n"
   " 26:       MOV TEMP[ADDR[1].x][ADDR[0].x+18].y, TEMP[2].xyxx\n"
   " 27:       MOV OUT[1], TEMP[18]\n"
   " 28:     ENDIF\n"
   " 29:   ELSE :39\n"
   " 30:     UIF TEMP[10].xxxx :33\n"
   " 31:       MOV TEMP[1].z, TEMP[9].xxzx\n"
   " 32:       UARL ADDR[0].x, TEMP[6].xxxx\n"
   " 33:       UARL ADDR[1].x, SV[0].xxxx\n"
   " 34:       MOV TEMP[ADDR[1].x][ADDR[0].x+18].z, TEMP[1].xxzx\n"
   " 35:       MOV OUT[1], TEMP[18]\n"
   " 36:     ELSE :38\n"
   " 37:       MOV TEMP[0].w, TEMP[9].xxxw\n"
   " 38:       UARL ADDR[0].x, TEMP[6].xxxx\n"
   " 39:       UARL ADDR[1].x, SV[0].xxxx\n"
   " 40:       MOV TEMP[ADDR[1].x][ADDR[0].x+18].w, TEMP[0].xxxw\n"
   " 41:       MOV OUT[1], TEMP[18]\n"
   " 42:     ENDIF\n"
   " 43:   ENDIF\n"
   " 44:   UADD TEMP[3].x, TEMP[3].xxxx, IMM[0].wwww\n"
   " 45:   ISGE TEMP[13].x, TEMP[3].xxxx, IMM[1].xxxx\n"
   " 46:   UIF TEMP[13].xxxx :44\n"
   " 47:     BRK\n"
   " 48:   ENDIF\n"
   " 49: ENDLOOP :0\n"
   " 50: MOV OUT[3].x, IMM[1].yyyy\n"
   " 51: MOV OUT[3].y, IMM[1].yyyy\n"
   " 52: MOV OUT[3].z, IMM[1].yyyy\n"
   " 53: MOV OUT[4].x, IMM[1].yyyy\n"
   " 54: END\n";

/* The same loop for N distances (1..8; one vec4 temp up to 4, two above). FIXED: the second
 * vec4 is copied back too (what a guest Mesa that copied every element would send). */
static const char *tcs_clip_loop(int n, int fixed)
{
   static char buf[4][8192];
   static int next;
   char *b = buf[next++ % 4];
   const int o = n > 4 ? 3 : 2;
   char copy[64];
   snprintf(copy, sizeof(copy), n > 4 && fixed ? "MOV OUT[1], TEMP[18]\nMOV OUT[2], TEMP[19]\n" :
            "MOV OUT[1], TEMP[18]\n");
   snprintf(b, sizeof(buf[0]),
            "TESS_CTRL\nPROPERTY TCS_VERTICES_OUT 3\nDCL IN[][0], POSITION\nDCL IN[][1], CLIPDIST\n%s"
            "DCL SV[0], INVOCATIONID\nDCL OUT[][0], POSITION\nDCL OUT[][1], CLIPDIST\n%s"
            "DCL OUT[%d].xyz, TESSOUTER\nDCL OUT[%d].x, TESSINNER\nDCL TEMP[0..13]\nDCL ADDR[0..1]\n"
            "IMM[0] UINT32 {0, 3, 2, 1}\nIMM[1] UINT32 {%d, 1065353216, 0, 0}\nDCL TEMP[14..17]\n%s"
            "UARL ADDR[1].x, SV[0].xxxx\nMOV TEMP[4], IN[ADDR[1].x][0]\nUARL ADDR[1].x, SV[0].xxxx\n"
            "MOV OUT[ADDR[1].x][0], TEMP[4]\nMOV TEMP[3].x, IMM[0].xxxx\nBGNLOOP\n"
            "AND TEMP[5].x, TEMP[3].xxxx, IMM[0].yyyy\nISHR TEMP[6].x, TEMP[3].xxxx, IMM[0].zzzz\n"
            "ISLT TEMP[7].xyz, TEMP[5].xxxx, IMM[0].zwyz\nMOV TEMP[8].x, TEMP[7].yxxx\n"
            "UARL ADDR[0].x, TEMP[6].xxxx\nUARL ADDR[1].x, SV[0].xxxx\n"
            "MOV TEMP[9], IN[ADDR[1].x][ADDR[0].x+1]\nMOV TEMP[10].x, TEMP[7].zxxx\n"
            "MOV TEMP[11].x, TEMP[7].xxxx\nUIF TEMP[11].xxxx\nUIF TEMP[8].xxxx\n"
            "MOV TEMP[12].x, TEMP[9].xxxx\nUARL ADDR[0].x, TEMP[6].xxxx\nUARL ADDR[1].x, SV[0].xxxx\n"
            "MOV TEMP[ADDR[1].x][ADDR[0].x+18].x, TEMP[12].xxxx\n%sELSE\n"
            "MOV TEMP[2].y, TEMP[9].xyxx\nUARL ADDR[0].x, TEMP[6].xxxx\nUARL ADDR[1].x, SV[0].xxxx\n"
            "MOV TEMP[ADDR[1].x][ADDR[0].x+18].y, TEMP[2].xyxx\n%sENDIF\nELSE\nUIF TEMP[10].xxxx\n"
            "MOV TEMP[1].z, TEMP[9].xxzx\nUARL ADDR[0].x, TEMP[6].xxxx\nUARL ADDR[1].x, SV[0].xxxx\n"
            "MOV TEMP[ADDR[1].x][ADDR[0].x+18].z, TEMP[1].xxzx\n%sELSE\n"
            "MOV TEMP[0].w, TEMP[9].xxxw\nUARL ADDR[0].x, TEMP[6].xxxx\nUARL ADDR[1].x, SV[0].xxxx\n"
            "MOV TEMP[ADDR[1].x][ADDR[0].x+18].w, TEMP[0].xxxw\n%sENDIF\nENDIF\n"
            "UADD TEMP[3].x, TEMP[3].xxxx, IMM[0].wwww\nISGE TEMP[13].x, TEMP[3].xxxx, IMM[1].xxxx\n"
            "UIF TEMP[13].xxxx\nBRK\nENDIF\nENDLOOP\n"
            "MOV OUT[%d].x, IMM[1].yyyy\nMOV OUT[%d].y, IMM[1].yyyy\nMOV OUT[%d].z, IMM[1].yyyy\n"
            "MOV OUT[%d].x, IMM[1].yyyy\nEND\n",
            n > 4 ? "DCL IN[][2], CLIPDIST[1]\n" : "", n > 4 ? "DCL OUT[][2], CLIPDIST[1]\n" : "",
            o, o + 1, n, n > 4 ? "DCL TEMP[18..19]\n" : "DCL TEMP[18]\n", copy, copy, copy, copy,
            o, o, o, o + 1);
   return b;
}

/* the guest's form in the other stages: gl_ClipDistance[i] = 1.0 for i < 8 in a loop (TEMP[2..3]
 * hold the two vec4s; TEMP[1].x is i) */
#define CLIP_LOOP \
   "MOV TEMP[1].x, IMM[0].xxxx\nBGNLOOP\nISHR TEMP[1].y, TEMP[1].xxxx, IMM[0].wwww\n" \
   "UARL ADDR[0].x, TEMP[1].yyyy\nMOV TEMP[ADDR[0].x+2].x, IMM[1].xxxx\nMOV OUT[1], TEMP[2]\n" \
   "UADD TEMP[1].x, TEMP[1].xxxx, IMM[0].yyyy\nISGE TEMP[1].y, TEMP[1].xxxx, IMM[0].zzzz\n" \
   "UIF TEMP[1].yyyy\nBRK\nENDIF\nENDLOOP\n"
#define CLIP_LOOP_DCL \
   "DCL OUT[1], CLIPDIST\nDCL OUT[2], CLIPDIST[1]\nDCL TEMP[0..1]\nDCL ADDR[0]\n" \
   "IMM[0] UINT32 {0, 1, 8, 2}\nIMM[1] FLT32 {    1.0000,     1.0000,     1.0000,     1.0000}\n" \
   "IMM[2] INT32 {0, 0, 0, 0}\nDCL TEMP[2..3]\n"
static const char *vs_clip_loop =
   "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n" CLIP_LOOP_DCL "MOV OUT[0], IN[0]\n" CLIP_LOOP "END\n";
static const char *gs_clip_loop =
   "GEOM\nPROPERTY GS_INPUT_PRIMITIVE TRIANGLES\nPROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\nPROPERTY GS_INVOCATIONS 1\nDCL IN[][0], POSITION\n"
   "DCL OUT[0], POSITION\n" CLIP_LOOP_DCL "MOV OUT[0], IN[0][0]\n" CLIP_LOOP "EMIT IMM[2].xxxx\nEND\n";
static const char *tes_clip_loop =
   TES_HEAD "DCL IN[][0], POSITION\nDCL SV[0], TESSCOORD\nDCL OUT[0], POSITION\n" CLIP_LOOP_DCL
   TES_POS CLIP_LOOP "END\n";
/* #692: the same loop, then distance 5 written directly and OUT[2] copied (the guest's form for
 * gl_ClipDistance[5] = -1.0 after the loop): the shader writes OUT[2] itself */
static const char *vs_clip_loop_own1 =
   "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n" CLIP_LOOP_DCL "MOV OUT[0], IN[0]\n" CLIP_LOOP
   "MOV TEMP[3].y, IMM[1].xxxx\nMOV OUT[2], TEMP[3]\nEND\n";
/* a sender with the clip outputs as one array, written with an index (not the guest's Mesa),
 * and OUT[1] copied from its own indexed temps: OUT[2] may be written, so no copy */
static const char *vs_clip_array_out =
   "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\nDCL OUT[1..2], ARRAY(1), CLIPDIST\nDCL TEMP[0..1]\n"
   "DCL ADDR[0]\nIMM[0] UINT32 {0, 1, 8, 2}\n"
   "IMM[1] FLT32 {    1.0000,     1.0000,     1.0000,     1.0000}\nDCL TEMP[2..3]\n"
   "MOV OUT[0], IN[0]\n" CLIP_LOOP "UARL ADDR[0].x, IMM[0].yyyy\nMOV OUT[ADDR[0].x+1], IMM[1]\nEND\n";

/* a temp array read and written with an indirect index: DECL is its declaration (TEMP[0] then
 * the three that are indexed); WRITE the indexed write (ADDR[0] or ADDR[1]) */
static const char *temp_index_frag(const char *decl, const char *addr)
{
   static char buf[4][1024];
   static int next;
   char *b = buf[next++ % 4];
   snprintf(b, sizeof(buf[0]),
            "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n%sDCL ADDR[0..1]\n"
            "IMM[0] FLT32 {    0.0000,     1.0000,     0.0000,     1.0000}\n"
            "IMM[1] FLT32 {    1.0000,     0.0000,     0.0000,     1.0000}\n"
            "MOV TEMP[0], IN[0]\nMOV TEMP[1], IMM[0]\nMOV TEMP[2], IMM[1]\n"
            "ARL ADDR[%s].x, TEMP[0].xxxx\nMOV TEMP[ADDR[%s].x+1].y, IMM[1].xxxx\n"
            "MOV OUT[0], TEMP[ADDR[%s].x+1]\nEND\n", decl, addr, addr, addr);
   return b;
}

static int indirect_temp_rows(bool have_gl)
{
   int failed = 0;
   struct vrend_shader_key key;
   char name[160];
   for (int sep = 0; sep < 2; sep++) {
      const char *how = sep ? "separable" : "whole";
      /* the key of a whole program carries the evaluation shader's count */
      memset(&key, 0, sizeof(key));
      key.num_in_clip = 8;
      key.num_out_clip = sep ? 0 : 8;
      snprintf(name, sizeof(name), "%s TCS from the guest's Mesa: 8 clip distances copied in a loop", how);
      failed |= indirect_temp(name, sep ? separable(tcs_loop8_guest) : tcs_loop8_guest, &key,
                              "vec4 temp18[2];", "temp18[clamp(addr0 + 0, 0, 1)].x = ", "vec4 temp18;",
                              "clip_dist_temp[1] = vec4(temp18[1]);", have_gl);
      for (int n = 1; n <= 8; n++) {
         for (int fixed = 0; fixed < 1 + (n > 4); fixed++) {
            /* the guest sends no NUM_CLIPDIST_ENABLED on the Mac: the counts are the declared
             * vec4s' */
            memset(&key, 0, sizeof(key));
            key.num_in_clip = n > 4 ? 8 : 4;
            key.num_out_clip = sep ? 0 : key.num_in_clip;
            snprintf(name, sizeof(name), "%s TCS copies %d clip distance%s in a loop%s", how, n,
                     n > 1 ? "s" : "", fixed ? " (both vec4s copied back)" : "");
            failed |= indirect_temp(name, sep ? separable(tcs_clip_loop(n, fixed)) : tcs_clip_loop(n, fixed),
                                    &key, n > 4 ? "vec4 temp18[2];" : "vec4 temp18[1];",
                                    n > 4 ? "temp18[clamp(addr0 + 0, 0, 1)].w = " :
                                            "temp18[clamp(addr0 + 0, 0, 0)].w = ",
                                    "vec4 temp18;",
                                    /* the second vec4 copied by the GLSL only when the guest
                                     * did not copy it */
                                    n > 4 && !fixed ? "clip_dist_temp[1] = vec4(temp18[1]);" : NULL,
                                    have_gl);
         }
      }
      /* the other stages that write clip distances in a loop; the counter temps stay single */
      memset(&key, 0, sizeof(key));
      snprintf(name, sizeof(name), "%s VS writes 8 clip distances in a loop", how);
      failed |= indirect_temp(name, sep ? separable(vs_clip_loop) : vs_clip_loop, &key, "vec4 temp2[2];",
                              "temp2[clamp(addr0 + 0, 0, 1)].x = ", "vec4 temp1[",
                              "clip_dist_temp[1] = vec4(temp2[1]);", have_gl);
      snprintf(name, sizeof(name), "%s GS writes 8 clip distances in a loop", how);
      failed |= indirect_temp(name, sep ? separable(gs_clip_loop) : gs_clip_loop, &key, "vec4 temp2[2];",
                              "temp2[clamp(addr0 + 0, 0, 1)].x = ", "vec4 temp1[",
                              "clip_dist_temp[1] = vec4(temp2[1]);", have_gl);
      key.tcs_present = 1;
      snprintf(name, sizeof(name), "%s TES writes 8 clip distances in a loop", how);
      failed |= indirect_temp(name, sep ? separable(tes_clip_loop) : tes_clip_loop, &key, "vec4 temp2[2];",
                              "temp2[clamp(addr0 + 0, 0, 1)].x = ", "vec4 temp1[",
                              "clip_dist_temp[1] = vec4(temp2[1]);", have_gl);
      /* #692: a shader that writes OUT[2] itself keeps its own distances 4..7 */
      memset(&key, 0, sizeof(key));
      snprintf(name, sizeof(name), "%s VS loop into the temps, then distance 5 written and copied itself", how);
      failed |= indirect_temp(name, sep ? separable(vs_clip_loop_own1) : vs_clip_loop_own1, &key,
                              "vec4 temp2[2];", "temp2[1].y = ", NULL, NULL, have_gl);
      snprintf(name, sizeof(name), "%s VS with clip outputs as one array written with an index", how);
      failed |= indirect_temp(name, sep ? separable(vs_clip_array_out) : vs_clip_array_out, &key,
                              "vec4 temp2[2];", "clip_dist_temp[0 + addr0]", NULL, NULL, have_gl);
   }
   memset(&key, 0, sizeof(key));
   /* a read: the indexed vec4, not one component of a single temp in all four; TEMP[0], before
    * the lowest indexed register, stays single (Mesa's one DCL TEMP[0..N]) */
   failed |= indirect_temp("indexed temp read and write without ARRAY",
                           temp_index_frag("DCL TEMP[0..3]\n", "0"), &key, "vec4 temp0;\n",
                           " vec4(temp1[clamp(addr0 + 0, 0, 2)])", "vec4 temp1;", NULL, have_gl);
   failed |= indirect_temp("direct writes into the indexed part use its array",
                           temp_index_frag("DCL TEMP[0..3]\n", "0"), &key, "temp1[1] = ",
                           "temp1[clamp(addr0 + 0, 0, 2)].y = ", NULL, NULL, have_gl);
   /* an index in ADDR[1]: the write names addr1 as the read always did */
   failed |= indirect_temp("indexed temp write through ADDR[1]",
                           temp_index_frag("DCL TEMP[0..3]\n", "1"), &key,
                           "temp1[clamp(addr1 + 0, 0, 2)].y = ", " vec4(temp1[clamp(addr1 + 0, 0, 2)])",
                           "addr0 + 0", NULL, have_gl);
   /* a declared array keeps its text */
   failed |= indirect_temp("indexed temp ARRAY(1) as before",
                           temp_index_frag("DCL TEMP[0]\nDCL TEMP[1..3], ARRAY(1)\n", "0"), &key,
                           "vec4 temp1[3];", "temp1[clamp(addr0 + 0, 0, 2)].y = ", NULL, NULL, have_gl);
   /* no temp indexed (an indexed constant instead): every temp a single vec4 as before */
   failed |= indirect_temp("no temp indexed: single temps as before",
                           "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\nDCL CONST[0..3]\nDCL TEMP[0..3]\n"
                           "DCL ADDR[0]\nARL ADDR[0].x, IN[0].xxxx\nMOV TEMP[1], CONST[ADDR[0].x+1]\n"
                           "MOV TEMP[3], IN[0]\nADD OUT[0], TEMP[1], TEMP[3]\nEND\n",
                           &key, "vec4 temp0;\n vec4 temp1;\n vec4 temp2;\n vec4 temp3;\n", "temp1 = ", "temp1[",
                           NULL, have_gl);
   return failed;
}

/* #692 (virgl-shader-vs-tcs-clip-varyings.patch): the control shader after a vertex shader
 * that passes its clip distances as omacvm_vclip0/omacvm_vclip1 (vs_clip_in). On the Mac
 * (WANT distances) it has no gl_ClipDistance in its gl_in[] block and reads none from
 * gl_in[], and declares in vec4 omacvm_vclip0[] (omacvm_vclip1[] for more than 4), also when
 * it reads none. WANT 0: no omacvm_vclip. MUST, MUST2: strings the text holds. */
static bool gl_in_clip_read(const char *glsl)
{
   for (const char *g = strstr(glsl, "gl_in["); g; g = strstr(g + 1, "gl_in[")) {
      const char *e = strchr(g, ']');
      if (e && !strncmp(e + 1, ".gl_ClipDistance", 16))
         return true;
   }
   return false;
}

static int vs_tcs_clip(const char *name, const char *text, const struct vrend_shader_key *key,
                       enum host host, int want, const char *must, const char *must2, bool have_gl)
{
   static char glsl[32768];
   struct vrend_variable_shader_info var;
   if (!translate(name, text, key, host, glsl, &var))
      return 1;
   bool block_clip = block_has_clip(glsl, "gl_in[]");
   bool access = gl_in_clip_read(glsl);
   bool decl0 = strstr(glsl, "in vec4 omacvm_vclip0[];") != NULL;
   bool decl1 = strstr(glsl, "in vec4 omacvm_vclip1[];") != NULL;
   bool ok = want ? !block_clip && !access && decl0 && decl1 == (want > 4)
                  : !strstr(glsl, "omacvm_vclip");
   if (!ok || (must && !strstr(glsl, must)) || (must2 && !strstr(glsl, must2))) {
      printf("FAIL: %s (want %d; gl_in[] clip %d, gl_in[] clip read %d, omacvm_vclip0[] %d, "
             "omacvm_vclip1[] %d; want \"%s\", \"%s\"):\n%s\n", name, want, block_clip, access,
             decl0, decl1, must ? must : "", must2 ? must2 : "", glsl);
      return 1;
   }
   have_gl = have_gl && host == HOST_MAC;
   if (have_gl && !gl_compiles(name, GL_TESS_CONTROL_SHADER, glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

/* a vertex shader and its control shader as vrend_sync_shader_io keys them: the control
 * shader's vs_clip_in and num_in_clip from the vertex shader's variable info. Both sides
 * declare the same names (Apple matches varyings without a location by their names). */
static int vs_tcs_pair(const char *name, const char *vs, const char *tcs, bool sep, int want,
                       const char *must_tcs, bool have_gl)
{
   static char glsl_vs[32768], glsl_tcs[32768];
   struct vrend_variable_shader_info var, tvar;
   struct vrend_shader_key key;
   char what[200];
   memset(&key, 0, sizeof(key));
   key.tes_present = 1;
   key.tcs_present = 1;
   key.use_pervertex_in = !sep;
   if (!translate(name, sep ? separable(vs) : vs, &key, HOST_MAC, glsl_vs, &var))
      return 1;
   memset(&key, 0, sizeof(key));
   key.tes_present = 1;
   key.tcs_present = 1;
   key.vs_clip_in = var.tess_clip_out;
   key.num_in_clip = var.num_out_clip;
   key.num_out_clip = sep ? 0 : var.num_out_clip;
   if (!translate(name, sep ? separable(tcs) : tcs, &key, HOST_MAC, glsl_tcs, &tvar))
      return 1;
   for (int k = 0; k < 2; k++) {
      char o[48], i[48];
      snprintf(o, sizeof(o), "out vec4 omacvm_vclip%d;", k);
      snprintf(i, sizeof(i), "in vec4 omacvm_vclip%d[];", k);
      if (!strstr(glsl_vs, o) != !strstr(glsl_tcs, i) || var.num_out_clip != want) {
         printf("FAIL: %s: omacvm_vclip%d declared %d in the VS, %d in the TCS (num_out_clip %d, "
                "want %d):\n%s\n%s\n", name, k, !!strstr(glsl_vs, o), !!strstr(glsl_tcs, i),
                var.num_out_clip, want, glsl_vs, glsl_tcs);
         return 1;
      }
   }
   snprintf(what, sizeof(what), "%s: the VS side", name);
   memset(&key, 0, sizeof(key));
   key.tes_present = 1;
   key.tcs_present = 1;
   key.use_pervertex_in = !sep;
   int failed = vs_tes_clip(what, sep ? separable(vs) : vs, &key, HOST_MAC, want, NULL, have_gl);
   snprintf(what, sizeof(what), "%s: the TCS side", name);
   key.vs_clip_in = var.tess_clip_out;
   key.num_in_clip = var.num_out_clip;
   key.num_out_clip = sep ? 0 : var.num_out_clip;
   key.use_pervertex_in = 0;
   failed |= vs_tcs_clip(what, sep ? separable(tcs) : tcs, &key, HOST_MAC, want, must_tcs, NULL, have_gl);
   return failed;
}

static int vs_tcs_clip_rows(bool have_gl)
{
   int failed = 0;
   struct vrend_shader_key key;
   char name[160];
   for (int sep = 0; sep < 2; sep++) {
      const char *how = sep ? "separable" : "whole";
      /* the vertex shader before a control shader (an evaluation shader after it) */
      memset(&key, 0, sizeof(key));
      key.tes_present = 1;
      key.tcs_present = 1;
      key.use_pervertex_in = !sep;
      snprintf(name, sizeof(name), "%s VS -> TCS passes 1 clip distance as omacvm_vclip0", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_MAC, 1,
                            "omacvm_vclip0.x = clip_dist_temp[0].x;", have_gl);
      snprintf(name, sizeof(name), "%s VS -> TCS passes 5 clip distances as omacvm_vclip0 and omacvm_vclip1", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip5) : vs_clip5, &key, HOST_MAC, 5,
                            "omacvm_vclip1.x = clip_dist_temp[1].x;", have_gl);
      snprintf(name, sizeof(name), "%s VS -> TCS passes 8 clip distances as omacvm_vclip0 and omacvm_vclip1", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip8) : vs_clip8, &key, HOST_MAC, 8,
                            "omacvm_vclip1.w = clip_dist_temp[1].w;", have_gl);
      snprintf(name, sizeof(name), "%s VS -> TCS, 8 clip distances written in the guest's loop", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip_loop) : vs_clip_loop, &key, HOST_MAC, 8,
                            "omacvm_vclip1.w = clip_dist_temp[1].w;", have_gl);
      /* other hosts and a cull distance after it: the text as before (text only) */
      snprintf(name, sizeof(name), "%s VS -> TCS on a GL with cull distances keeps gl_ClipDistance", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_CULL, 0,
                            "gl_ClipDistance[0] = clip_dist_temp[0].x;", false);
      snprintf(name, sizeof(name), "%s VS -> TCS on GLES keeps its text", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_GLES, 0, NULL, false);
      key.num_out_cull = 1;
      snprintf(name, sizeof(name), "%s VS -> TCS with a cull distance keeps gl_ClipDistance", how);
      failed |= vs_tes_clip(name, sep ? separable(vs_clip1) : vs_clip1, &key, HOST_MAC, 0, NULL, false);

      /* the control shader after it */
      memset(&key, 0, sizeof(key));
      key.tes_present = 1;
      key.tcs_present = 1;
      key.vs_clip_in = 1;
      key.num_in_clip = 1;
      key.num_out_clip = sep ? 0 : 1;
      snprintf(name, sizeof(name), "%s TCS reads 1 distance from omacvm_vclip0[]", how);
      failed |= vs_tcs_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_MAC, 1,
                            "omacvm_vclip0[addr0][0]", "out vec4 omacvm_clip0[];", have_gl);
      key.num_in_clip = 4;
      key.num_out_clip = sep ? 0 : 4;
      snprintf(name, sizeof(name), "%s TCS reads 4 distances from omacvm_vclip0[] in the guest's loop", how);
      failed |= vs_tcs_clip(name, sep ? separable(tcs_clip_loop(4, 0)) : tcs_clip_loop(4, 0), &key,
                            HOST_MAC, 4, "omacvm_vclip0[addr1][", "out vec4 omacvm_clip0[];", have_gl);
      for (int n = 5; n <= 8; n += 3) {
         key.num_in_clip = n;
         key.num_out_clip = sep ? 0 : n;
         snprintf(name, sizeof(name), "%s TCS reads %d distances from omacvm_vclip0[] and omacvm_vclip1[] "
                  "in the guest's loop (indirect index)", how, n);
         failed |= vs_tcs_clip(name, sep ? separable(tcs_clip_loop(n, 1)) : tcs_clip_loop(n, 1), &key,
                               HOST_MAC, n, " < 4 ? omacvm_vclip0[addr1][", " : omacvm_vclip1[addr1][",
                               have_gl);
      }
      key.num_in_clip = 5;
      key.num_out_clip = sep ? 0 : 8;
      snprintf(name, sizeof(name), "%s TCS that reads no clip distance still declares omacvm_vclip0[] and "
               "omacvm_vclip1[]", how);
      failed |= vs_tcs_clip(name, sep ? separable(tcs_clip8) : tcs_clip8, &key, HOST_MAC, 5,
                            "out vec4 omacvm_clip1[];", NULL, have_gl);
      /* the text as before: a vertex shader that kept gl_ClipDistance (no vs_clip_in), other
       * hosts */
      key.vs_clip_in = 0;
      key.num_in_clip = 1;
      key.num_out_clip = sep ? 0 : 1;
      snprintf(name, sizeof(name), "%s TCS after a VS with gl_ClipDistance keeps gl_in[]", how);
      failed |= vs_tcs_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_MAC, 0,
                            "gl_in[addr0].gl_ClipDistance", NULL, have_gl);
      key.vs_clip_in = 1;
      snprintf(name, sizeof(name), "%s TCS on a GL with cull distances keeps gl_in[]", how);
      failed |= vs_tcs_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_CULL, 0,
                            "gl_in[addr0].gl_ClipDistance", NULL, false);
      snprintf(name, sizeof(name), "%s TCS on GLES keeps gl_in[]", how);
      failed |= vs_tcs_clip(name, sep ? separable(tcs_clip1) : tcs_clip1, &key, HOST_GLES, 0, NULL, NULL,
                            false);

      /* both sides keyed as vrend_sync_shader_io keys them: the same names */
      static const struct { const char **vs; int want; } pairs[] = {
         { &vs_clip1, 1 }, { &vs_clip5, 5 }, { &vs_clip8, 8 }, { &vs_clip_loop, 8 } };
      for (unsigned i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
         int w = pairs[i].want;
         snprintf(name, sizeof(name), "%s VS -> TCS pair, %d distance%s%s: the same names on both sides",
                  how, w, w > 1 ? "s" : "", *pairs[i].vs == vs_clip_loop ? " (the guest's loop)" : "");
         failed |= vs_tcs_pair(name, *pairs[i].vs, tcs_clip_loop(w, 1), sep, w,
                               w > 4 ? " : omacvm_vclip1[addr1][" : "omacvm_vclip0[addr1][", have_gl);
      }
   }
   return failed;
}

int main(void)
{
   bool have_gl = cgl_init_current();
   if (!have_gl)
      puts("SKIP: no OpenGL context here; checking the GLSL text only");
   int failed = 0;
   struct vrend_shader_key key;

   /* dEQP-GLES3.functional.shaders.precision.int.*: integer vertex attributes
    * passed on as they are. The copy goes through intBitsToFloat() without
    * SHADER_REQ_INTS, which gave "#version 140" and a refused shader. */
   memset(&key, 0, sizeof(key));
   key.vs.attrib_signed_int_bitmask = 0x6;
   failed |= convert("signed integer attributes passed on",
                     "VERT\nDCL IN[0]\nDCL IN[1]\nDCL IN[2]\nDCL OUT[0], POSITION\n"
                     "DCL OUT[1], GENERIC[0]\nDCL OUT[2], GENERIC[1]\n"
                     "MOV OUT[0], IN[0]\nMOV OUT[1], IN[1]\nMOV OUT[2], IN[2]\nEND\n",
                     &key, "intBitsToFloat", NULL, have_gl);
   memset(&key, 0, sizeof(key));
   key.vs.attrib_unsigned_int_bitmask = 0x2;
   failed |= convert("unsigned integer attribute passed on",
                     "VERT\nDCL IN[0]\nDCL IN[1]\nDCL OUT[0], POSITION\nDCL OUT[1], GENERIC[0]\n"
                     "MOV OUT[0], IN[0]\nMOV OUT[1], IN[1]\nEND\n",
                     &key, "uintBitsToFloat", NULL, have_gl);

   /* A separable program (program pipelines) asks for explicit locations too;
    * they are core in GLSL 3.30. */
   memset(&key, 0, sizeof(key));
   failed |= convert("separable vertex shader",
                     "VERT\nPROPERTY SEPARABLE_PROGRAM 1\nDCL IN[0]\nDCL OUT[0], POSITION\n"
                     "DCL OUT[1], GENERIC[0]\nMOV OUT[0], IN[0]\nMOV OUT[1], IN[0]\nEND\n",
                     &key, "layout", NULL, have_gl);
   /* and redeclares the gl_PerVertex blocks it uses, also as the last stage: Apple's GL
    * links a separable shader only then (#567, virgl-shader-separable-pervertex.patch) */
   memset(&key, 0, sizeof(key));
   failed |= convert("separable vertex shader, last stage: gl_PerVertex",
                     "VERT\nPROPERTY SEPARABLE_PROGRAM 1\nDCL IN[0]\nDCL OUT[0], POSITION\n"
                     "DCL OUT[1], PSIZE\nMOV OUT[0], IN[0]\nMOV OUT[1].x, IN[0].xxxx\nEND\n",
                     &key, "out gl_PerVertex {\n vec4 gl_Position;\n out float gl_PointSize;\n};",
                     NULL, have_gl);
   memset(&key, 0, sizeof(key));
   failed |= convert("separable geometry shader: gl_PerVertex in and out",
                     "GEOM\nPROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
                     "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
                     "PROPERTY GS_MAX_OUTPUT_VERTICES 1\nPROPERTY GS_INVOCATIONS 1\n"
                     "PROPERTY SEPARABLE_PROGRAM 1\n"
                     "DCL IN[][0], POSITION\nDCL OUT[0], POSITION\n"
                     "IMM[0] UINT32 {0, 0, 0, 0}\nMOV OUT[0], IN[0][0]\nEMIT IMM[0].xxxx\nEND\n",
                     &key, "} gl_in[];\nout gl_PerVertex {\n vec4 gl_Position;\n };", NULL, have_gl);

   /* Integer render target written from a flat input. */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("unsigned integer color output",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);

   /* Results written straight to an integer output (the guest's TGSI folds
    * floatBitsToUint(f(x)) or uint(i) into "OP OUT[n], ..."). Every write goes
    * to a float temporary, with the same GLSL as for a TEMP register, and one
    * store keeps its bits: dEQP-GLES3 builtin_functions.precision.sqrt read 315
    * for sqrt(99463) (uint(1.0 / x)), and texture fetches, CMP, SEQ or TXQ into
    * such an output did not compile at all. */
   static const struct {
      const char *op, *decls;
      bool mac_has_it;          /* images, buffers: the Mac's GL 4.1 has none */
   } int_out[] = {
      {"RCP OUT[0].x, IN[0].xxxx", "", true},
      {"SQRT OUT[0], IN[0]", "", true},
      {"DP3 OUT[0].x, IN[0], IN[0]", "", true},
      {"LRP OUT[0], IN[0], IN[0], IN[0]", "", true},
      {"CMP OUT[0], IN[0], IN[0], IN[0]", "", true},
      {"UCMP OUT[0], IN[0], IN[0], IN[0]", "", true},
      {"SEQ OUT[0], IN[0], IN[0]", "", true},
      {"I2F OUT[0], IN[0]", "", true},
      {"UADD OUT[0], IN[0], IN[0]", "", true},
      {"NOT OUT[0], IN[0]", "", true},
      {"USEQ OUT[0], IN[0], IN[0]", "", true},
      {"F2U OUT[0], IN[0]", "", true},
      {"TEX OUT[0], IN[0], SAMP[0], 2D", "DCL SAMP[0]\nDCL SVIEW[0], 2D, FLOAT\n", true},
      {"TXF OUT[0], IN[0], SAMP[0], 2D", "DCL SAMP[0]\nDCL SVIEW[0], 2D, UINT\n", true},
      {"TXQ OUT[0].xy, IN[0].xxxx, SAMP[0], 2D", "DCL SAMP[0]\nDCL SVIEW[0], 2D, FLOAT\n", true},
      {"LOAD OUT[0], IMAGE[0], IN[0], 2D, PIPE_FORMAT_R32G32B32A32_UINT",
       "DCL IMAGE[0], 2D, PIPE_FORMAT_R32G32B32A32_UINT, WR\n", false},
      {"RESQ OUT[0].xy, IMAGE[0]", "DCL IMAGE[0], 2D, PIPE_FORMAT_R32G32B32A32_UINT, WR\n", false},
      {"ATOMUADD OUT[0].x, BUFFER[0], IN[0].xxxx, IN[0].yyyy", "DCL BUFFER[0]\n", false},
   };
   for (unsigned i = 0; i < sizeof(int_out) / sizeof(int_out[0]); i++) {
      for (int sign = 0; sign < 2; sign++) {
         char name[128], text[512];
         snprintf(name, sizeof(name), "%.*s into an %s color output",
                  (int)strcspn(int_out[i].op, " "), int_out[i].op, sign ? "int" : "uint");
         snprintf(text, sizeof(text), "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                  "DCL TEMP[0]\n%s%s\nEND\n", int_out[i].decls, int_out[i].op);
         memset(&key, 0, sizeof(key));
         if (sign)
            key.fs.cbufs_signed_int_bitmask = 0x1;
         else
            key.fs.cbufs_unsigned_int_bitmask = 0x1;
         /* one store of the written components */
         char store[96], mask[5] = "";
         const char *dst = strstr(int_out[i].op, "OUT[0]") + 6;
         if (*dst == '.')
            snprintf(mask, sizeof(mask), "%.*s", (int)strcspn(dst + 1, ","), dst + 1);
         snprintf(store, sizeof(store), "fsout_c0%s%s = %s(int_out_tmp0%s%s);", *mask ? "." : "",
                  mask, sign ? "floatBitsToInt" : "floatBitsToUint", *mask ? "." : "", mask);
         failed |= convert(name, text, &key, store, NULL, have_gl && int_out[i].mac_has_it);
      }
   }

   /* dEQP-GLES3.functional.draw_buffers_indexed.random.*: colour outputs
    * declared in reverse order, mixed types. The outputs are sorted after the
    * body is written; the temporaries must still be the ones declared. */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   key.fs.cbufs_signed_int_bitmask = 0xa;
   failed |= convert("integer colour outputs declared in reverse order",
                     "FRAG\nDCL IN[0].xy, GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR[3]\n"
                     "DCL OUT[1], COLOR[2]\nDCL OUT[2], COLOR[1]\nDCL OUT[3], COLOR\nDCL TEMP[0]\n"
                     "F2U TEMP[0], IN[0].xyxy\nMOV OUT[3], TEMP[0]\nF2I TEMP[0], IN[0].yxyx\n"
                     "MOV OUT[2], TEMP[0]\nMOV OUT[1], IN[0].xyxy\nMOV OUT[0], TEMP[0]\nEND\n",
                     &key, "fsout_c1 = floatBitsToInt(int_out_tmp2);", NULL, have_gl);

   /* The other integer outputs: gl_SampleMask from an integer op, gl_Layer
    * from a geometry shader (stored before each EmitVertex). */
   memset(&key, 0, sizeof(key));
   failed |= convert("AND into gl_SampleMask",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "DCL OUT[1], SAMPLEMASK\nMOV OUT[0], IN[0]\n"
                     "AND OUT[1].x, IN[0].xxxx, IN[0].yyyy\nEND\n",
                     &key, "gl_SampleMask[0] = floatBitsToInt(int_out_tmp1.x);", NULL, have_gl);
   memset(&key, 0, sizeof(key));
   failed |= convert("UADD into gl_Layer (geometry shader)",
                     "GEOM\nPROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
                     "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
                     "PROPERTY GS_MAX_OUTPUT_VERTICES 1\nPROPERTY GS_INVOCATIONS 1\n"
                     "DCL IN[][0], POSITION\nDCL OUT[0], POSITION\nDCL OUT[1], LAYER\n"
                     "IMM[0] UINT32 {1, 0, 0, 0}\nMOV OUT[0], IN[0][0]\n"
                     "UADD OUT[1].x, IMM[0].xxxx, IMM[0].xxxx\nEMIT IMM[0].yyyy\nEND\n",
                     &key, "gl_Layer = floatBitsToInt(int_out_tmp1.x);", NULL, have_gl);

   /* Instanced drawing (WebGL through ANGLE): gl_InstanceID is core GLSL;
    * Apple's core profile refuses "#extension GL_ARB_draw_instanced". */
   memset(&key, 0, sizeof(key));
   failed |= convert("vertex shader reading gl_InstanceID",
                     "VERT\nDCL IN[0]\nDCL SV[0], INSTANCEID\nDCL OUT[0], POSITION\n"
                     "DCL TEMP[0]\nI2F TEMP[0].x, SV[0].xxxx\nADD OUT[0], IN[0], TEMP[0].xxxx\nEND\n",
                     &key, "gl_InstanceID", "GL_ARB_draw_instanced", have_gl);

   /* dEQP-GLES3.functional.shaders.texture_functions.texturegradoffset.*:
    * textureGrad() on shadow array and cube samplers is core GLSL, but the
    * renderer asked for GL_EXT_texture_shadow_lod, which the Mac lacks. */
   memset(&key, 0, sizeof(key));
   failed |= convert("textureGradOffset on a shadow array sampler",
                     "VERT\nDCL IN[0]\nDCL IN[1]\nDCL IN[2]\nDCL IN[3]\nDCL OUT[0], POSITION\n"
                     "DCL OUT[1].x, GENERIC[0]\nDCL SAMP[0]\nDCL SVIEW[0], SHADOW2D_ARRAY, FLOAT\n"
                     "IMM[0] UINT32 {4294967288, 7, 0, 0}\n"
                     "TXD OUT[1].x, IN[1], IN[2].xyyy, IN[3].xyyy, SAMP[0], SHADOW2D_ARRAY, IMM[0].xyx\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, "textureGradOffset", "GL_EXT_texture_shadow_lod", have_gl);
   failed |= convert("textureGrad on a shadow cube sampler",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\nDCL SAMP[0]\n"
                     "DCL SVIEW[0], SHADOWCUBE, FLOAT\nDCL TEMP[0]\n"
                     "TXD TEMP[0].x, IN[0], IN[0].xyzz, IN[0].zyxx, SAMP[0], SHADOWCUBE\n"
                     "MOV OUT[0], TEMP[0].xxxx\nEND\n",
                     &key, "textureGrad", "GL_EXT_texture_shadow_lod", have_gl);
   /* dEQP-GLES3.functional.shaders.texture_functions.texture.samplercubeshadow_bias_*:
    * texture(samplerCubeShadow, P, bias) is core GLSL 1.30 and ESSL 3.00; the
    * extension only adds lod forms and bias for array samplers. */
   failed |= convert("texture() with a bias on a shadow cube sampler",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL IN[1], GENERIC[1], PERSPECTIVE\n"
                     "DCL OUT[0], COLOR\nDCL SAMP[0]\nDCL SVIEW[0], SHADOWCUBE, FLOAT\nDCL TEMP[0]\n"
                     "TXB2 TEMP[0].x, IN[0], IN[1].xxxx, SAMP[0], SHADOWCUBE\n"
                     "MOV OUT[0], TEMP[0].xxxx\nEND\n",
                     &key, "texture(", "GL_EXT_texture_shadow_lod", have_gl);
   /* The compare value of a gather is no bias either (GLSL 4.00). */
   failed |= convert("textureGather on a shadow cube sampler",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\nDCL SAMP[0]\n"
                     "DCL SVIEW[0], SHADOWCUBE, FLOAT\nDCL TEMP[0]\nIMM[0] UINT32 {0, 0, 0, 0}\n"
                     "TG4 TEMP[0], IN[0], IMM[0].xxxx, SAMP[0], SHADOWCUBE\n"
                     "MOV OUT[0], TEMP[0]\nEND\n",
                     &key, "textureGather", "GL_EXT_texture_shadow_lod", have_gl);

   /* gl_SampleMask written with every component: only gl_SampleMask[0]
    * exists on the Mac ("Index 1 beyond bounds"). The stencil value is .y. */
   memset(&key, 0, sizeof(key));
   failed |= convert("MOV of all components into gl_SampleMask",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "DCL OUT[1], SAMPLEMASK\nMOV OUT[0], IN[0]\nMOV OUT[1], IN[0]\nEND\n",
                     &key, "gl_SampleMask[0] = floatBitsToInt(int_out_tmp1.x);", "gl_SampleMask[1]",
                     have_gl);
   memset(&key, 0, sizeof(key));
   failed |= convert("stencil value from .y",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\nDCL OUT[1], STENCIL\n"
                     "MOV OUT[0], IN[0]\nMOV OUT[1].x, IN[0].yyyy\nMOV OUT[1].y, IN[0].xxxx\nEND\n",
                     &key, "gl_FragStencilRefARB = floatBitsToInt(int_out_tmp1.y);", NULL,
                     false /* the Mac has no ARB_shader_stencil_export */);
   /* A shader that reads or writes an output with an indirect index keeps
    * upstream's direct outputs: the index could reach an output past its
    * temporary. */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("integer colour output also written indirectly",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\nDCL ADDR[0]\n"
                     "IMM[0] INT32 {0, 0, 0, 0}\nUARL ADDR[0].x, IMM[0].xxxx\n"
                     "MOV OUT[ADDR[0].x], IN[0]\nMOV OUT[0], IN[0]\nEND\n",
                     &key, "fsout_c0 = ", "int_out_tmp", have_gl);
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("integer colour output read indirectly",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\nDCL TEMP[0]\nDCL ADDR[0]\n"
                     "IMM[0] INT32 {0, 0, 0, 0}\nUARL ADDR[0].x, IMM[0].xxxx\n"
                     "MOV OUT[0], IN[0]\nMOV TEMP[0], OUT[ADDR[0].x]\nUADD OUT[0], TEMP[0], IN[0]\nEND\n",
                     &key, "fsout_c0 = ", "int_out_tmp", have_gl);

   /* Only the written components are stored: with framebuffer fetch the
    * others keep the fetched value (the Mac has no framebuffer fetch: text
    * only there). */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("partial write into an integer colour output",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "UADD OUT[0].xz, IN[0], IN[0]\nEND\n",
                     &key, "fsout_c0.xz = floatBitsToUint(int_out_tmp0.xz);", "fsout_c0 = ", have_gl);
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("partial write after framebuffer fetch",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\nDCL TEMP[0]\n"
                     "FBFETCH TEMP[0], OUT[0]\nUADD OUT[0].y, TEMP[0].xxxx, IN[0].xxxx\nEND\n",
                     &key, "fsout_c0.y = floatBitsToUint(int_out_tmp0.y);", "fsout_c0 = ", false);
   /* A precise result keeps precise in its temporary. */
   memset(&key, 0, sizeof(key));
   key.fs.cbufs_unsigned_int_bitmask = 0x1;
   failed |= convert("precise MAD into an integer color output",
                     "FRAG\nDCL IN[0], GENERIC[0], CONSTANT\nDCL OUT[0], COLOR\n"
                     "MAD_PRECISE OUT[0], IN[0], IN[0], IN[0]\nEND\n",
                     &key, "precise vec4 int_out_tmp0;", NULL, have_gl);

   /* A vertex emitted in a loop before the text that writes gl_Layer still
    * stores it: which components are written comes from a pass before the
    * translation, not from the text order. */
   memset(&key, 0, sizeof(key));
   failed |= convert("gl_Layer written after EmitVertex in a loop",
                     "GEOM\nPROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
                     "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
                     "PROPERTY GS_MAX_OUTPUT_VERTICES 3\nPROPERTY GS_INVOCATIONS 1\n"
                     "DCL IN[][0], POSITION\nDCL OUT[0], POSITION\nDCL OUT[1], LAYER\nDCL TEMP[0]\n"
                     "IMM[0] UINT32 {1, 0, 3, 0}\nMOV TEMP[0].x, IMM[0].yyyy\nBGNLOOP\n"
                     "USGE TEMP[0].y, TEMP[0].xxxx, IMM[0].zzzz\nUIF TEMP[0].yyyy\nBRK\nENDIF\n"
                     "UIF TEMP[0].xxxx\nEMIT IMM[0].yyyy\nENDIF\nMOV OUT[0], IN[0][0]\n"
                     "MOV OUT[1].x, TEMP[0].xxxx\nUADD TEMP[0].x, TEMP[0].xxxx, IMM[0].xxxx\n"
                     "ENDLOOP\nEMIT IMM[0].yyyy\nEND\n",
                     &key, "{\n\t\tgl_Layer = floatBitsToInt(int_out_tmp1.x);", NULL, have_gl);

   /* Compute shaders are always "#version 330" (hosts with compute; the Mac
    * has none): a shader that needs GLSL 4.30 for a vote still needs the
    * texture gather extension line. Text only. */
   memset(&key, 0, sizeof(key));
   failed |= convert("compute shader with a vote and a gather",
                     "COMP\nPROPERTY CS_FIXED_BLOCK_WIDTH 1\nPROPERTY CS_FIXED_BLOCK_HEIGHT 1\n"
                     "PROPERTY CS_FIXED_BLOCK_DEPTH 1\nDCL SAMP[0]\nDCL SVIEW[0], 2D, FLOAT\n"
                     "DCL TEMP[0]\nIMM[0] FLT32 {    0.5000,     0.5000,     0.0000,     0.0000}\n"
                     "IMM[1] UINT32 {0, 0, 0, 0}\n"
                     "TG4 TEMP[0], IMM[0], IMM[1].xxxx, SAMP[0], 2D\n"
                     "VOTE_ANY TEMP[0].x, TEMP[0].xxxx\nEND\n",
                     &key, "#extension GL_ARB_texture_gather", NULL, false);

   /* Mesa's VA-API video compositor (vl_compositor_gfx.c, create_frag_shader_yuv)
    * reads the alpha with a swizzle on the sampler: TEX ..., SAMP[0].wwww. Gallium's
    * own translators ignore a sampler's swizzle; written into GLSL as
    * "fssamp0.wwww" the Mac refused the shader ("Swizzle of non-vector primitive"),
    * so every frame Chrome's decoder converts to RGB was black
    * (virgl-shader-sampler-swizzle.patch). */
   memset(&key, 0, sizeof(key));
   failed |= convert("swizzle on a sampler (Mesa's video compositor)",
                     "FRAG\nDCL IN[0], GENERIC[0], LINEAR\nDCL OUT[0], COLOR\n"
                     "DCL SAMP[0]\nDCL SAMP[1]\nDCL SAMP[2]\n"
                     "DCL SVIEW[0], 2D_ARRAY, FLOAT\nDCL SVIEW[1], 2D_ARRAY, FLOAT\n"
                     "DCL SVIEW[2], 2D_ARRAY, FLOAT\nDCL CONST[0..2]\nDCL TEMP[0..1]\n"
                     "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     0.0000}\n"
                     "TEX TEMP[0].x, IN[0], SAMP[0], 2D_ARRAY\n"
                     "TEX TEMP[0].y, IN[0], SAMP[1], 2D_ARRAY\n"
                     "TEX TEMP[0].z, IN[0], SAMP[2], 2D_ARRAY\n"
                     "TEX TEMP[0].w, IN[0], SAMP[0].wwww, 2D_ARRAY\n"
                     "MOV TEMP[1].w, TEMP[0].wwww\nMOV TEMP[0].w, IMM[0].xxxx\n"
                     "DP4 OUT[0].x, CONST[0], TEMP[0]\nDP4 OUT[0].y, CONST[1], TEMP[0]\n"
                     "DP4 OUT[0].z, CONST[2], TEMP[0]\nMOV OUT[0].w, TEMP[1].wwww\nEND\n",
                     &key, "texture(fssamp0, ", "fssamp0.", have_gl);

   failed |= tess_clip_rows(have_gl);
   failed |= vs_tes_clip_rows(have_gl);
   failed |= patch_fill_rows(have_gl);
   failed |= vs_tcs_clip_rows(have_gl);
   failed |= indirect_temp_rows(have_gl);

   /* A plain float shader is unchanged apart from the version. */
   memset(&key, 0, sizeof(key));
   failed |= convert("float fragment shader",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);
   return failed;
}
