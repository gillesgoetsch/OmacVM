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

   /* A plain float shader is unchanged apart from the version. */
   memset(&key, 0, sizeof(key));
   failed |= convert("float fragment shader",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);
   return failed;
}
