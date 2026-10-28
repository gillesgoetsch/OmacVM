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

static int convert(const char *name, const char *text, const struct vrend_shader_key *key,
                   const char *must, const char *must_not, bool have_gl)
{
   struct tgsi_token tokens[512];
   struct vrend_shader_cfg cfg = {
      .glsl_version = 410,
      .max_draw_buffers = 8,
      .use_core_profile = 1,
      .use_explicit_locations = 1,
      .has_gpu_shader5 = 1,
      .use_integer = 1,
   };
   struct vrend_shader_info info = {0};
   struct vrend_variable_shader_info variable_info = {0};
   struct vrend_strarray output = {0};
   if (!tgsi_text_translate(text, tokens, 512)) {
      printf("FAIL: %s TGSI parsing\n", name);
      return 1;
   }
   if (!strarray_alloc(&output, 3) ||
       !vrend_convert_shader(NULL, &cfg, tokens, 0, key, &info, &variable_info, &output)) {
      printf("FAIL: %s translation\n", name);
      return 1;
   }
   char glsl[32768] = {0};
   for (int i = 0; i < output.num_strings; i++)
      strncat(glsl, output.strings[i].buf, sizeof(glsl) - strlen(glsl) - 1);
   strarray_free(&output, true);
   /* Every core profile shader: GLSL 3.30, no extension that 3.30 has in core. */
   if (strncmp(glsl, "#version 330\n", 13) || strstr(glsl, "GL_ARB_shader_bit_encoding") ||
       strstr(glsl, "GL_ARB_explicit_attrib_location") || (must && !strstr(glsl, must)) ||
       (must_not && strstr(glsl, must_not))) {
      printf("FAIL: %s:\n%s\n", name, glsl);
      return 1;
   }
   GLenum type = !strncmp(text, "VERT", 4) ? GL_VERTEX_SHADER :
                 !strncmp(text, "GEOM", 4) ? GL_GEOMETRY_SHADER : GL_FRAGMENT_SHADER;
   if (have_gl && !gl_compiles(name, type, glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
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

   /* A plain float shader is unchanged apart from the version. */
   memset(&key, 0, sizeof(key));
   failed |= convert("float fragment shader",
                     "FRAG\nDCL IN[0], GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\n"
                     "MOV OUT[0], IN[0]\nEND\n",
                     &key, NULL, NULL, have_gl);
   return failed;
}
