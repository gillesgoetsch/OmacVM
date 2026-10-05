/* texture() on integer samplers: the GLSL the renderer writes must compile.
 * Chrome samples usampler2D in some of its shaders; a vec4 temporary there made
 * Apple's OpenGL refuse the shader, and the guest's context stopped for good.
 * Translates TGSI offline, checks the text, then compiles it with the Mac's own
 * OpenGL (a CGL core profile context, no window) when one is available. */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tgsi/tgsi_text.h"
#include "vrend/vrend_shader.h"
#include "vrend/vrend_strbuf.h"

typedef int (*choose_fn)(const int *, void **, int *);
typedef int (*create_fn)(void *, void *, void **);
typedef int (*current_fn)(void *);
typedef unsigned (*create_shader_fn)(unsigned);
typedef void (*source_fn)(unsigned, int, const char *const *, const int *);
typedef void (*compile_fn)(unsigned);
typedef void (*getiv_fn)(unsigned, unsigned, int *);
typedef void (*log_fn)(unsigned, int, int *, char *);

static struct {
   create_shader_fn create; source_fn source; compile_fn compile; getiv_fn getiv; log_fn log;
} gl;

/* A core profile context like the renderer's (OpenGL 4.1 on the Mac). */
static bool gl_init(void)
{
   void *cgl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
   if (!cgl)
      return false;
   choose_fn choose = (choose_fn)dlsym(cgl, "CGLChoosePixelFormat");
   create_fn create = (create_fn)dlsym(cgl, "CGLCreateContext");
   current_fn current = (current_fn)dlsym(cgl, "CGLSetCurrentContext");
   gl.create = (create_shader_fn)dlsym(cgl, "glCreateShader");
   gl.source = (source_fn)dlsym(cgl, "glShaderSource");
   gl.compile = (compile_fn)dlsym(cgl, "glCompileShader");
   gl.getiv = (getiv_fn)dlsym(cgl, "glGetShaderiv");
   gl.log = (log_fn)dlsym(cgl, "glGetShaderInfoLog");
   if (!choose || !create || !current || !gl.create || !gl.source || !gl.compile ||
       !gl.getiv || !gl.log)
      return false;
   const int attrs[] = {99 /* kCGLPFAOpenGLProfile */, 0x3200 /* 3.2 core and later */, 0};
   void *pix = NULL, *ctx = NULL;
   int n = 0;
   return !choose(attrs, &pix, &n) && pix && !create(pix, NULL, &ctx) && ctx && !current(ctx);
}

static bool gl_compiles(const char *name, const char *glsl)
{
   unsigned s = gl.create(0x8B30 /* GL_FRAGMENT_SHADER */);
   int ok = 0;
   gl.source(s, 1, &glsl, NULL);
   gl.compile(s);
   gl.getiv(s, 0x8B81 /* GL_COMPILE_STATUS */, &ok);
   if (!ok) {
      char log[2048] = {0};
      gl.log(s, sizeof(log), NULL, log);
      printf("FAIL: %s does not compile:\n%s\n%s\n", name, log, glsl);
   }
   return ok;
}

static int convert(const char *name, const char *text, const char *must, const char *must_not,
                   bool lower_swizzle, bool have_gl)
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
   struct vrend_shader_key key = {0};
   struct vrend_shader_info info = {0};
   struct vrend_variable_shader_info variable_info = {0};
   struct vrend_strarray output = {0};
   key.fs.lower_left_origin = 1;   /* drawing into a texture, as Chrome does */
   if (lower_swizzle) {   /* A8_UNORM on the core profile: 0, 0, 0, R */
      vrend_shader_sampler_views_mask_set(key.sampler_views_lower_swizzle_mask, 0);
      key.tex_swizzle[0] = PIPE_SWIZZLE_0 | PIPE_SWIZZLE_0 << 3 | PIPE_SWIZZLE_0 << 6 |
                           PIPE_SWIZZLE_X << 9;
   }
   if (!tgsi_text_translate(text, tokens, 512)) {
      printf("FAIL: %s TGSI parsing\n", name);
      return 1;
   }
   if (!strarray_alloc(&output, 3) ||
       !vrend_convert_shader(NULL, &cfg, tokens, 0, &key, &info, &variable_info, &output)) {
      printf("FAIL: %s translation\n", name);
      return 1;
   }
   char glsl[32768] = {0};
   for (int i = 0; i < output.num_strings; i++)
      strncat(glsl, output.strings[i].buf, sizeof(glsl) - strlen(glsl) - 1);
   strarray_free(&output, true);
   if ((must && !strstr(glsl, must)) || (must_not && strstr(glsl, must_not))) {
      printf("FAIL: %s:\n%s\n", name, glsl);
      return 1;
   }
   if (have_gl && !gl_compiles(name, glsl))
      return 1;
   printf("PASS: %s%s\n", name, have_gl ? " (compiled by the Mac's OpenGL)" : "");
   return 0;
}

#define FS(view, tex, out) \
   "FRAG\nDCL IN[0].xy, GENERIC[0], PERSPECTIVE\nDCL OUT[0], COLOR\nDCL SAMP[0]\n" \
   "DCL SVIEW[0], 2D, " view "\nDCL TEMP[0]\n" tex "\n" out "\nEND\n"

int main(void)
{
   bool have_gl = gl_init();
   if (!have_gl)
      puts("SKIP: no OpenGL context here; checking the GLSL text only");
   int failed = 0;
   failed |= convert("uint sampler", FS("UINT", "TEX TEMP[0], IN[0].xyyy, SAMP[0], 2D",
                                        "U2F OUT[0], TEMP[0]"),
                     "uvec4 val = texture(", "vec4(uintBitsToFloat(vec4", false, have_gl);
   failed |= convert("int sampler", FS("SINT", "TEX TEMP[0], IN[0].xyyy, SAMP[0], 2D",
                                       "I2F OUT[0], TEMP[0]"),
                     "ivec4 val = texture(", NULL, false, have_gl);
   failed |= convert("uint sampler, two channels",
                     FS("UINT", "TEX TEMP[0].xy, IN[0].xyyy, SAMP[0], 2D",
                        "U2F OUT[0], TEMP[0].xyxy"),
                     "uvec4 val = texture(", NULL, false, have_gl);
   failed |= convert("float sampler, one channel",
                     FS("FLOAT", "TEX TEMP[0].x, IN[0].xyyy, SAMP[0], 2D",
                        "MOV OUT[0], TEMP[0].xxxx"),
                     "vec4 val = texture(", NULL, false, have_gl);
   failed |= convert("alpha-only sampler, swizzled in the shader",
                     FS("FLOAT", "TEX TEMP[0], IN[0].xyyy, SAMP[0], 2D", "MOV OUT[0], TEMP[0]"),
                     "val = vec4(0, 0, 0, val.x)", NULL, true, have_gl);
   return failed;
}
