/* Shader constants (CONST[0], the guest's plain uniforms) through uniform buffers
 * (virgl-const-uniform-buffer.patch), through the public renderer API on Apple's software
 * renderer (soft-gl.h; never on the GPU). Linked with gl-oracle.c: a draw whose active
 * uniform blocks have no buffer, or a range shorter than the block, aborts.
 *
 * Each case runs in a fresh context and draws up to four times into four stripes of one
 * 16x16 colour buffer, then checks the middle pixel of every stripe:
 *  1 vertex shader constants changed before each draw, all in one submit (the colour sits
 *    in the third vec4, so the range offset counts);
 *  2 fragment shader constants changed before each draw;
 *  3 both stages per draw: the fragment colour is the vertex colour times its constant;
 *  4 fragment constants set once, then six submits with vertex constants only: the ring
 *    buffers the fragment constants came in take later submits, the draws still see them;
 *  5 fewer constants than the shader declares: the rest reads as zero (uniforms: not
 *    checked, the old path read past the guest's data);
 *  6 an index computed in the shader (ADDR) picks one of four colours, and one far out
 *    of range is clamped (drawn, no fault);
 *  7 two programs with 4 and 8 constants alternating in one submit;
 *  8 two sub contexts in one submit, each with its own constants; one destroyed after the
 *    submit's constants went to it;
 *  9 constants and a guest uniform buffer in one shader;
 * 10 a constants command with no data (zeros), and a submit whose last constants command
 *    runs past the buffer's end: the draws before it are drawn;
 * 11 white-box (OMACVM_VIRGL_CACHE_STATS=1, set here): 4 constants commands and 4 draws in
 *    one submit are one upload, then one window bind and 4 index values for the vertex
 *    shader (OMACVM_VIRGL_CONST_UBO=1: 4 range binds; =0: none, a plain uniform), nothing
 *    one by one; the program has the block "vsconstblk";
 * 12 800 draws with 8 vec4s each in one submit: more constants than one window holds, so
 *    the window moves on; every draw still reads its own;
 * 13 a vertex shader with 16 inputs (no location left for the index): with windows it keeps
 *    uniforms (a range at the 16-byte offset of a vertex entry would go one by one, slower
 *    than uniforms), with OMACVM_VIRGL_CONST_UBO=1 a range per draw;
 * 14 a vertex shader reading CONST[0][3000] with 4 constants declared, then 800 draws with
 *    red constants in the same submit: the shader is refused as before (uniforms and a
 *    block of 4 do not compile); a window must not let it read the other draws' constants;
 * 15 separable shaders linked early (LINK_SHADER): the vertex window still works (the index
 *    attribute is bound before that link), not only a fallback to uniforms; skipped where
 *    the host refuses the separable link in every mode. With a range per draw (=1) only
 *    stripe 0 is checked: Apple's software renderer keeps a bound pipeline's uniform buffer
 *    ranges until the pipeline is bound again (the Mac's GPU takes each new range);
 * 16 a submit of a pattern, then small vertex and fragment constants: the buffer the GPU
 *    reads holds those constants and zeros, nothing of the earlier submit (the gaps between
 *    entries and the window pad are zeroed);
 * 17 a 16-input vertex program, then a window program with the same constants; 18 a window
 *    program from the stage's own buffer, a 16-input program, the window program again;
 * 19 both orders, in one submit and across submits: a window is never bound past the end
 *    of the buffer it reads (gl-oracle: a 64 KB window over a 64-byte own buffer);
 * 20 vertex (window), geometry (an index) and fragment constants per draw;
 * 21 random runs (programs, constants, submits, sub contexts; SEED, SEEDS): every draw is
 *    checked by gl-oracle, and the printed hashes are the same in all three modes;
 * 22 constant buffer 0 as a guest buffer (SET_UNIFORM_BUFFER index 0, as Mesa's VA-API video
 *    compositor binds its colour matrix; virgl-const-buffer0-resource.patch): the shader's
 *    CONST[0..n] read it, new data in the same buffer is seen by the next draw, a later
 *    SET_CONSTANT_BUFFER wins again and binding the buffer again wins over that;
 * 23 a fragment shader that declares a 2D_ARRAY sampler (as Mesa's VA-API video compositor
 *    declares its planes) with a plain 2D texture view bound reads the texture, as gallium
 *    reads such a view (layer 0); the same program with the colour from constant buffer 0
 *    is the compositor's whole path (virgl-shader-array-sampler-2d-view.patch);
 * 24 two views of one texture with different swizzles (RRR1 and GGG1, as the compositor
 *    reads U and V from one UV plane) in one draw: each reads its own channel, not the
 *    swizzle bound last (GL keeps one per texture; virgl-view-swizzle-shared-texture.patch);
 *    a draw with only the second view after it still gets that view's swizzle.
 * Run as is, with OMACVM_VIRGL_CONST_UBO=1 and with OMACVM_VIRGL_CONST_UBO=0.
 * Usage: test-const-ubo [case] */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2, TEST_SHADER_VERTEX = 0,
       TEST_SHADER_FRAGMENT = 1, TEST_PRIM_TRIANGLES = 4, TEST_CLEAR_COLOR0 = 1 << 2 };

/* RGBA8 pixels as read back (little endian: 0xAABBGGRR) */
enum { RED = 0xff0000ff, GREEN = 0xff00ff00, BLUE = 0xffff0000, YELLOW = 0xff00ffff,
       WHITE = 0xffffffff, ZERO = 0x00000000 };

/* resources of a context: handle = 1000 * ctx + R_* */
enum { R_RT = 1, R_POS, R_UBO, R_TEX, R_COUNT };
/* objects */
enum { VS_CONST = 10, VS_CONST8, VS_INDEX, VS_UBO, VS_PLAIN, VS_IN16, FS_VARYING, FS_CONST, FS_MUL,
       VE = 20, VS_FAR = 30, VS_SEP, FS_SEP, SURFACE = 40, BLEND, RS, GS_CONST = 50,
       FS_CONST1D = 60, FS_ARRAY_SAMPLER, VIEW_2D, SAMPLER, FS_TWO_VIEWS, VIEW_R, VIEW_G,
       FS_ONE_VIEW };

static CGLContextObj main_ctx;
static int failures;
/* 0: uniforms, 1: a range per draw, 2: vertex shaders index a window */
static int const_ubo = 2;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

/* The renderer's constant buffer totals, from its log line when a context ends. */
static struct totals {
   unsigned long long uploads, bytes, binds, own, index, windows;
} last;
/* the host refused a separable link (Apple's GL before virgl-shader-separable-pervertex.patch:
 * a separable vertex shader must redeclare gl_PerVertex) */
static int separable_refused;

static void log_cb(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)data;
   struct totals t;
   const char *p = strstr(message, "constant buffers (");
   if (p && (p = strstr(p, "totals uploads")) &&
       sscanf(p, "totals uploads %llu upload-bytes %llu binds %llu own-uploads %llu "
              "index-draws %llu window-binds %llu",
              &t.uploads, &t.bytes, &t.binds, &t.own, &t.index, &t.windows) == 6)
      last = t;
   else if (strstr(message, "(separable link)"))
      separable_refused = 1;
   if (p)
      return;
   if (level >= VIRGL_LOG_LEVEL_WARNING || strstr(message, "shader constants:"))
      fprintf(stderr, "virgl: %s", message);
}

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   (void)fence;
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
   return soft_gl_context(main_ctx);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
};

struct cmds {
   uint32_t dw[65536];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v)
{
   c->dw[c->n++] = v;
}

static void emit_float(struct cmds *c, float f)
{
   uint32_t u;
   memcpy(&u, &f, 4);
   emit(c, u);
}

static int submit(int ctx, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx, c->n);
   c->n = 0;
   return r;
}

static uint32_t res_id(int ctx, int r)
{
   return 1000 * ctx + r;
}

static void emit_shader(struct cmds *c, uint32_t handle, uint32_t type, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER, 5 + words));
   emit(c, handle);
   emit(c, type);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(bytes));
   emit(c, 300);
   emit(c, 0);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], text, bytes);
   c->n += words;
}

static void emit_bind_shader(struct cmds *c, uint32_t handle, uint32_t type)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SHADER, 0, 2));
   emit(c, handle);
   emit(c, type);
}

static void emit_bind_shaders(struct cmds *c, uint32_t vs, uint32_t fs)
{
   emit_bind_shader(c, vs, TEST_SHADER_VERTEX);
   emit_bind_shader(c, fs, TEST_SHADER_FRAGMENT);
}

/* n vec4s of constants for a stage; vec4 k is val[k] (RGBA floats) */
static void emit_consts(struct cmds *c, uint32_t stage, unsigned n, const float (*val)[4])
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2 + 4 * n));
   emit(c, stage);
   emit(c, 0);
   for (unsigned k = 0; k < n; k++)
      for (int i = 0; i < 4; i++)
         emit_float(c, val[k][i]);
}

/* n vec4s, all zero except vec4 at = colour */
static void emit_colour_consts(struct cmds *c, uint32_t stage, unsigned n, unsigned at,
                               uint32_t colour)
{
   float val[8][4];
   memset(val, 0, sizeof(val));
   for (int i = 0; i < 4; i++)
      val[at][i] = ((colour >> (8 * i)) & 0xff) / 255.0f;
   emit_consts(c, stage, n, (const float (*)[4])val);
}

static void emit_draw(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, 0);                      /* start */
   emit(c, 3);                      /* count */
   emit(c, TEST_PRIM_TRIANGLES);
   emit(c, 0);                      /* not indexed */
   emit(c, 0);                      /* instances */
   emit(c, 0);                      /* index bias */
   emit(c, 0);                      /* start instance */
   emit(c, 0);                      /* primitive restart */
   emit(c, 0);                      /* restart index */
   emit(c, 0);                      /* min index */
   emit(c, 0xffffffff);             /* max index */
   emit(c, 0);                      /* count from stream output */
}

/* stripe 0-3: x 4 * stripe .. 4 * stripe + 3 of the 16x16 buffer, all rows */
static void emit_stripe(struct cmds *c, int stripe)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);
   emit_float(c, 2);
   emit_float(c, 8);
   emit_float(c, 0.5f);
   emit_float(c, 4 * stripe + 2);
   emit_float(c, 8);
   emit_float(c, 0.5f);
}

static void emit_clear(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, TEST_CLEAR_COLOR0);
   emit_float(c, 0.5f);             /* grey: no case expects it */
   emit_float(c, 0.5f);
   emit_float(c, 0.5f);
   emit_float(c, 1);
   emit(c, 0);                      /* depth (double) */
   emit(c, 0);
   emit(c, 0);                      /* stencil */
}

static void emit_sub_ctx(struct cmds *c, uint32_t cmd, uint32_t id)
{
   emit(c, VIRGL_CMD0(cmd, 0, 1));
   emit(c, id);
}

/* colour from vec4 2 of 4 */
static const char *vs_const =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][2]\n"
   "  2: END\n";

/* colour from vec4 6 of 8 */
static const char *vs_const8 =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..7]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][6]\n"
   "  2: END\n";

/* colour from vec4 1 + CONST[0][0].x */
static const char *vs_index =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..4]\n"
   "DCL ADDR[0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: ARL ADDR[0].x, CONST[0][0].xxxx\n"
   "  2: MOV OUT[1], CONST[0][ADDR[0].x+1]\n"
   "  3: END\n";

/* colour = CONST[0][0] * the guest's uniform buffer 1, vec4 0 */
static const char *vs_ubo =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0]\n"
   "DCL CONST[1][0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MUL OUT[1], CONST[0][0], CONST[1][0]\n"
   "  2: END\n";

/* white */
static const char *vs_plain =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "IMM[0] FLT32 { 1.0, 1.0, 1.0, 1.0 }\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], IMM[0]\n"
   "  2: END\n";

/* 16 inputs, the colour from vec4 2 of 4 */
static const char *vs_inputs16 =
   "VERT\n"
   "DCL IN[0]\n" "DCL IN[1]\n" "DCL IN[2]\n" "DCL IN[3]\n" "DCL IN[4]\n" "DCL IN[5]\n"
   "DCL IN[6]\n" "DCL IN[7]\n" "DCL IN[8]\n" "DCL IN[9]\n" "DCL IN[10]\n" "DCL IN[11]\n"
   "DCL IN[12]\n" "DCL IN[13]\n" "DCL IN[14]\n" "DCL IN[15]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][2]\n"
   "  2: END\n";

/* reads vec4 3000 of 4 */
static const char *vs_far =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][3000]\n"
   "  2: END\n";

/* vs_const and fs_varying as separable programs */
static const char *vs_sep =
   "VERT\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..3]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], CONST[0][2]\n"
   "  2: END\n";

static const char *fs_sep =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

static const char *fs_varying =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

/* colour from vec4 1 of 2 */
static const char *fs_const =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[0][0..1]\n"
   "  0: MOV OUT[0], CONST[0][1]\n"
   "  1: END\n";

/* colour from vec4 1 of 2, constants declared one-dimensional as gallium's own shaders do
 * (Mesa's vl_compositor) */
static const char *fs_const1d =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[0..1]\n"
   "  0: MOV OUT[0], CONST[1]\n"
   "  1: END\n";

/* the texel at (0.5, 0.5), layer 0, of a sampler declared 2D_ARRAY, times CONST[1] (white
 * from constant buffer 0 in case 23), as Mesa's video compositor samples a plane */
static const char *fs_array_sampler =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL SAMP[0]\n"
   "DCL SVIEW[0], 2D_ARRAY, FLOAT\n"
   "DCL CONST[0..1]\n"
   "DCL TEMP[0]\n"
   "IMM[0] FLT32 {    0.5000,     0.5000,     0.0000,     0.0000}\n"
   "  0: TEX TEMP[0], IMM[0], SAMP[0], 2D_ARRAY\n"
   "  1: MUL OUT[0], TEMP[0], CONST[1]\n"
   "  2: END\n";

/* red from view 0's x, green from view 1's x: two views of one texture */
static const char *fs_two_views =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL SAMP[0]\n"
   "DCL SAMP[1]\n"
   "DCL SVIEW[0], 2D, FLOAT\n"
   "DCL SVIEW[1], 2D, FLOAT\n"
   "DCL TEMP[0..1]\n"
   "IMM[0] FLT32 {    0.5000,     0.5000,     0.0000,     1.0000}\n"
   "  0: TEX TEMP[0], IMM[0], SAMP[0], 2D\n"
   "  1: TEX TEMP[1], IMM[0], SAMP[1], 2D\n"
   "  2: MOV OUT[0].x, TEMP[0].xxxx\n"
   "  3: MOV OUT[0].y, TEMP[1].xxxx\n"
   "  4: MOV OUT[0].zw, IMM[0].zzzw\n"
   "  5: END\n";

/* red from view 1's x alone */
static const char *fs_one_view =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL SAMP[1]\n"
   "DCL SVIEW[1], 2D, FLOAT\n"
   "DCL TEMP[0]\n"
   "IMM[0] FLT32 {    0.5000,     0.5000,     0.0000,     1.0000}\n"
   "  0: TEX TEMP[0], IMM[0], SAMP[1], 2D\n"
   "  1: MOV OUT[0].x, TEMP[0].xxxx\n"
   "  2: MOV OUT[0].yzw, IMM[0].zzzw\n"
   "  3: END\n";

/* colour = the vertex colour * CONST[0][0] */
static const char *fs_mul =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[0][0]\n"
   "  0: MUL OUT[0], IN[0], CONST[0][0]\n"
   "  1: END\n";

static void make_buffer(int ctx, int r, uint32_t bind, uint32_t width)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = res_id(ctx, r), .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = bind, .width = width, .height = 1, .depth = 1, .array_size = 1,
   };
   if (virgl_renderer_resource_create(&a, NULL, 0))
      printf("note: buffer %d not created\n", r);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, r));
}

static void emit_write(struct cmds *c, uint32_t handle, const void *data, uint32_t bytes)
{
   uint32_t words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(c, handle);
   emit(c, 0);                      /* level */
   emit(c, 0);                      /* usage */
   emit(c, 0);                      /* stride */
   emit(c, 0);                      /* layer stride */
   emit(c, 0);                      /* x */
   emit(c, 0);
   emit(c, 0);
   emit(c, bytes);                  /* w */
   emit(c, 1);
   emit(c, 1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

/* the objects of a sub context (each has its own): surface, blend, rasterizer, shaders,
 * vertex elements and buffer, cleared colour buffer */
static void emit_state(struct cmds *c, int ctx)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, SURFACE);
   emit(c, res_id(ctx, R_RT));
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, SURFACE);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_BLEND, VIRGL_OBJ_BLEND_SIZE));
   emit(c, BLEND);
   emit(c, 0);
   emit(c, 0);
   for (int i = 0; i < VIRGL_MAX_COLOR_BUFS; i++)
      emit(c, VIRGL_OBJ_BLEND_S2_RT_COLORMASK(0xf));
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_BLEND, 1));
   emit(c, BLEND);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(c, RS);
   emit(c, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   emit_float(c, 1.0f);
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 3; i++)
      emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, RS);

   emit_shader(c, VS_CONST, TEST_SHADER_VERTEX, vs_const);
   emit_shader(c, VS_CONST8, TEST_SHADER_VERTEX, vs_const8);
   emit_shader(c, VS_INDEX, TEST_SHADER_VERTEX, vs_index);
   emit_shader(c, VS_UBO, TEST_SHADER_VERTEX, vs_ubo);
   emit_shader(c, VS_PLAIN, TEST_SHADER_VERTEX, vs_plain);
   emit_shader(c, VS_IN16, TEST_SHADER_VERTEX, vs_inputs16);
   emit_shader(c, FS_VARYING, TEST_SHADER_FRAGMENT, fs_varying);
   emit_shader(c, FS_CONST, TEST_SHADER_FRAGMENT, fs_const);
   emit_shader(c, FS_MUL, TEST_SHADER_FRAGMENT, fs_mul);
   emit_shader(c, FS_CONST1D, TEST_SHADER_FRAGMENT, fs_const1d);
   emit_shader(c, FS_ARRAY_SAMPLER, TEST_SHADER_FRAGMENT, fs_array_sampler);
   emit_shader(c, FS_TWO_VIEWS, TEST_SHADER_FRAGMENT, fs_two_views);
   emit_shader(c, FS_ONE_VIEW, TEST_SHADER_FRAGMENT, fs_one_view);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);

   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                      VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(1)));
   emit(c, VE);
   emit(c, 0);                      /* src offset */
   emit(c, 0);                      /* instance divisor */
   emit(c, 0);                      /* vertex buffer */
   emit(c, VIRGL_FORMAT_R32G32B32A32_FLOAT);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(c, VE);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, VIRGL_SET_VERTEX_BUFFERS_SIZE(1)));
   emit(c, 16);
   emit(c, 0);
   emit(c, res_id(ctx, R_POS));
   emit_clear(c);
}

/* A context with a 16x16 colour buffer, one triangle over the whole viewport (POS) and a
 * guest uniform buffer of one vec4 (UBO: white). */
static void setup(struct cmds *c, int ctx)
{
   char name[16];
   snprintf(name, sizeof(name), "const-%d", ctx);
   virgl_renderer_context_create(ctx, strlen(name), name);

   struct virgl_renderer_resource_create_args rt = {
      .handle = res_id(ctx, R_RT), .target = TEST_PIPE_TEXTURE_2D,
      .format = VIRGL_FORMAT_R8G8B8A8_UNORM, .bind = VIRGL_BIND_RENDER_TARGET, .width = 16,
      .height = 16, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&rt, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, R_RT));
   make_buffer(ctx, R_POS, VIRGL_BIND_VERTEX_BUFFER, 3 * 16);
   make_buffer(ctx, R_UBO, VIRGL_BIND_CONSTANT_BUFFER, 256);
   struct virgl_renderer_resource_create_args tex = {
      .handle = res_id(ctx, R_TEX), .target = TEST_PIPE_TEXTURE_2D,
      .format = VIRGL_FORMAT_R8G8B8A8_UNORM, .bind = VIRGL_BIND_SAMPLER_VIEW, .width = 4,
      .height = 4, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&tex, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, R_TEX));

   emit_state(c, ctx);
   const float pos[3][4] = { { -1, -1, 0, 1 }, { 3, -1, 0, 1 }, { -1, 3, 0, 1 } };
   emit_write(c, res_id(ctx, R_POS), pos, sizeof(pos));
   const float white[4] = { 1, 1, 1, 1 };
   emit_write(c, res_id(ctx, R_UBO), white, sizeof(white));
   check(submit(ctx, c) == 0, "setup");
}

static void teardown(int ctx)
{
   virgl_renderer_context_destroy(ctx);
   for (int r = R_RT; r < R_COUNT; r++)
      virgl_renderer_resource_unref(res_id(ctx, r));
}

static void read_stripes(int ctx, uint32_t got[4])
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   if (virgl_renderer_transfer_read_iov(res_id(ctx, R_RT), ctx, 0, 16 * 4, 0, &box, 0, &iov, 1))
      memset(pixels, 0x11, sizeof(pixels));
   for (int s = 0; s < 4; s++)
      got[s] = pixels[8 * 16 + 4 * s + 2];
}

static void check_stripes(int ctx, int n, const uint32_t *want, const char *what)
{
   uint32_t got[4];
   char text[256];
   read_stripes(ctx, got);
   for (int s = 0; s < n; s++) {
      snprintf(text, sizeof(text), "%s: stripe %d (0x%08x, expected 0x%08x)", what, s, got[s],
               want[s]);
      check(got[s] == want[s], text);
   }
}

static const uint32_t colours[4] = { RED, GREEN, BLUE, YELLOW };

static void case_vs(struct cmds *c, int ctx)
{
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "vertex constants before each of 4 draws, one submit");
   check_stripes(ctx, 4, colours, "vertex constants per draw");
}

static void case_fs(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_PLAIN, FS_CONST);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 2, 1, colours[3 - s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "fragment constants before each of 4 draws, one submit");
   const uint32_t want[4] = { YELLOW, BLUE, GREEN, RED };
   check_stripes(ctx, 4, want, "fragment constants per draw");
}

static void case_both(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_CONST, FS_MUL);
   const uint32_t vs[4] = { WHITE, YELLOW, WHITE, BLUE }, fs[4] = { RED, GREEN, BLUE, WHITE };
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, vs[s]);
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, fs[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "both stages' constants before each draw");
   const uint32_t want[4] = { RED, GREEN, BLUE, BLUE };
   check_stripes(ctx, 4, want, "vertex colour times fragment constant");
}

static void case_stale(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_CONST, FS_MUL);
   emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, WHITE);
   check(submit(ctx, c) == 0, "fragment constants alone");
   /* six submits: the fragment constants' ring buffer takes a later submit */
   for (int k = 0; k < 6; k++) {
      emit_stripe(c, k % 4);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[k % 4]);
      emit_draw(c);
      check(submit(ctx, c) == 0, "vertex constants and a draw, one submit");
   }
   check_stripes(ctx, 4, colours, "fragment constants from 6 submits back");
}

static void case_short(struct cmds *c, int ctx)
{
   emit_stripe(c, 0);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   emit_stripe(c, 1);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 2, 1, RED);     /* the colour vec4 is missing */
   emit_draw(c);
   emit_stripe(c, 2);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, BLUE);
   emit_draw(c);
   check(submit(ctx, c) == 0, "2 of 4 vec4s sent between two full ones");
   const uint32_t want[3] = { GREEN, ZERO, BLUE };
   if (!const_ubo) {
      /* uniforms: the missing part was never defined */
      uint32_t got[4];
      read_stripes(ctx, got);
      check(got[0] == GREEN && got[2] == BLUE, "short constants: the full draws around it");
      return;
   }
   check_stripes(ctx, 3, want, "short constants read as zero");
}

static void case_index(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_INDEX, FS_VARYING);
   for (int s = 0; s < 4; s++) {
      float val[5][4];
      memset(val, 0, sizeof(val));
      val[0][0] = 3 - s;
      for (int k = 0; k < 4; k++)
         for (int i = 0; i < 4; i++)
            val[1 + k][i] = ((colours[k] >> (8 * i)) & 0xff) / 255.0f;
      emit_stripe(c, s);
      emit_consts(c, TEST_SHADER_VERTEX, 5, (const float (*)[4])val);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "an index in the shader picks the colour");
   const uint32_t want[4] = { YELLOW, BLUE, GREEN, RED };
   check_stripes(ctx, 4, want, "indexed constants");

   float far[5][4];
   memset(far, 0, sizeof(far));
   far[0][0] = 100000;
   emit_stripe(c, 0);
   emit_consts(c, TEST_SHADER_VERTEX, 5, (const float (*)[4])far);
   emit_draw(c);
   far[0][0] = -100000;
   emit_consts(c, TEST_SHADER_VERTEX, 5, (const float (*)[4])far);
   emit_draw(c);
   check(submit(ctx, c) == 0, "an index far out of range is clamped (drawn)");
}

static void case_programs(struct cmds *c, int ctx)
{
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      if (s & 1) {
         emit_bind_shaders(c, VS_CONST8, FS_VARYING);
         emit_colour_consts(c, TEST_SHADER_VERTEX, 8, 6, colours[s]);
      } else {
         emit_bind_shaders(c, VS_CONST, FS_VARYING);
         emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      }
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "programs with 4 and 8 constants by turns");
   check_stripes(ctx, 4, colours, "4 and 8 constants");

   /* the 8-constant program with only the 4 vec4s of the last draw: zeros (block) */
   emit_stripe(c, 1);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_bind_shaders(c, VS_CONST8, FS_VARYING);
   emit_draw(c);
   check(submit(ctx, c) == 0, "a program with more constants than were sent");
   if (const_ubo)
      check_stripes(ctx, 2, (const uint32_t[2]){ RED, ZERO }, "more constants than sent");
}

static void case_subs(struct cmds *c, int ctx)
{
   emit_sub_ctx(c, VIRGL_CCMD_CREATE_SUB_CTX, 1);
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 1);
   emit_state(c, ctx);
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
   check(submit(ctx, c) == 0, "a second sub context");
   for (int s = 0; s < 4; s++) {
      emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, s & 1);
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
   check(submit(ctx, c) == 0, "two sub contexts by turns, one submit");
   check_stripes(ctx, 4, colours, "sub contexts");
   /* again, now sub context 1 first */
   for (int s = 0; s < 4; s++) {
      emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, !(s & 1));
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[3 - s]);
      emit_draw(c);
   }
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
   check(submit(ctx, c) == 0, "two sub contexts, sub context 1 first");
   check_stripes(ctx, 4, (const uint32_t[4]){ YELLOW, BLUE, GREEN, RED }, "sub contexts again");
   /* the upload goes to sub context 1, which is destroyed before sub context 0 draws in
    * the same submit: sub context 0 must not use sub context 1's (deleted) buffer */
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 1);
   emit_stripe(c, 0);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, RED);
   emit_draw(c);
   emit_sub_ctx(c, VIRGL_CCMD_DESTROY_SUB_CTX, 1);
   emit_stripe(c, 1);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   check(submit(ctx, c) == 0, "constants uploaded in a sub context destroyed in the submit");
   check_stripes(ctx, 2, (const uint32_t[2]){ RED, GREEN }, "after the sub context is gone");
}

static void case_ubo(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_UBO, FS_VARYING);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_UNIFORM_BUFFER, 0, VIRGL_SET_UNIFORM_BUFFER_SIZE));
   emit(c, TEST_SHADER_VERTEX);
   emit(c, 1);
   emit(c, 0);
   emit(c, 16);
   emit(c, res_id(ctx, R_UBO));
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 1, 0, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "constants and a uniform buffer in one shader");
   check_stripes(ctx, 4, colours, "constants times a white uniform buffer");
}

/* the fragment stage's constant buffer 0 bound as the guest's buffer R_UBO */
static void emit_const_buffer0(struct cmds *c, int ctx)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_UNIFORM_BUFFER, 0, VIRGL_SET_UNIFORM_BUFFER_SIZE));
   emit(c, TEST_SHADER_FRAGMENT);
   emit(c, 0);                      /* index 0: the constants */
   emit(c, 0);
   emit(c, 32);
   emit(c, res_id(ctx, R_UBO));
}

/* vec4 0 zero, vec4 1 = colour */
static void emit_buffer_colour(struct cmds *c, int ctx, uint32_t colour)
{
   float val[2][4];
   memset(val, 0, sizeof(val));
   for (int i = 0; i < 4; i++)
      val[1][i] = ((colour >> (8 * i)) & 0xff) / 255.0f;
   emit_write(c, res_id(ctx, R_UBO), val, sizeof(val));
}

static void case_buffer0(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_PLAIN, FS_CONST1D);
   emit_buffer_colour(c, ctx, RED);
   emit_const_buffer0(c, ctx);
   emit_stripe(c, 0);
   emit_draw(c);
   emit_buffer_colour(c, ctx, GREEN);
   emit_stripe(c, 1);
   emit_draw(c);
   emit_colour_consts(c, TEST_SHADER_FRAGMENT, 2, 1, BLUE);
   emit_stripe(c, 2);
   emit_draw(c);
   check(submit(ctx, c) == 0, "constant buffer 0 as a guest buffer, then plain constants");
   emit_const_buffer0(c, ctx);
   emit_stripe(c, 3);
   emit_draw(c);
   check(submit(ctx, c) == 0, "constant buffer 0 as a guest buffer again, next submit");
   const uint32_t want[4] = { RED, GREEN, BLUE, GREEN };
   check_stripes(ctx, 4, want, "constant buffer 0 from a guest buffer");
}

/* the 4x4 texture R_TEX in one colour, a 2D view of it and a nearest sampler for the
 * fragment stage */
static void emit_texture(struct cmds *c, int ctx, uint32_t colour)
{
   uint32_t texels[16];
   for (int i = 0; i < 16; i++)
      texels[i] = colour;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + 16));
   emit(c, res_id(ctx, R_TEX));
   emit(c, 0);                      /* level */
   emit(c, 0);                      /* usage */
   emit(c, 16);                     /* stride */
   emit(c, 0);                      /* layer stride */
   emit(c, 0);                      /* x, y, z */
   emit(c, 0);
   emit(c, 0);
   emit(c, 4);                      /* w, h, d */
   emit(c, 4);
   emit(c, 1);
   memcpy(&c->dw[c->n], texels, sizeof(texels));
   c->n += 16;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_VIEW,
                      VIRGL_OBJ_SAMPLER_VIEW_SIZE));
   emit(c, VIEW_2D);
   emit(c, res_id(ctx, R_TEX));
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM | TEST_PIPE_TEXTURE_2D << 24);
   emit(c, 0);                      /* layers 0..0 */
   emit(c, 0);                      /* levels 0..0 */
   emit(c, 0 | 1 << 3 | 2 << 6 | 3 << 9);   /* identity swizzle */
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_SAMPLER_VIEWS, 0, VIRGL_SET_SAMPLER_VIEWS_SIZE(1)));
   emit(c, TEST_SHADER_FRAGMENT);
   emit(c, 0);
   emit(c, VIEW_2D);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_STATE,
                      VIRGL_OBJ_SAMPLER_STATE_SIZE));
   emit(c, SAMPLER);
   emit(c, VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_S(2) | VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_T(2) |
           VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_R(2) | VIRGL_OBJ_SAMPLE_STATE_S0_MIN_MIP_FILTER(2));
   emit_float(c, 0);                /* lod bias, min and max lod */
   emit_float(c, 0);
   emit_float(c, 0);
   for (int i = 0; i < 4; i++)
      emit(c, 0);                   /* border colour */
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SAMPLER_STATES, 0, 3));
   emit(c, TEST_SHADER_FRAGMENT);
   emit(c, 0);
   emit(c, SAMPLER);
}

static void case_array_sampler(struct cmds *c, int ctx)
{
   emit_texture(c, ctx, GREEN);
   emit_bind_shaders(c, VS_PLAIN, FS_ARRAY_SAMPLER);
   emit_colour_consts(c, TEST_SHADER_FRAGMENT, 2, 1, WHITE);
   emit_stripe(c, 0);
   emit_draw(c);
   emit_buffer_colour(c, ctx, WHITE);
   emit_const_buffer0(c, ctx);
   emit_stripe(c, 1);
   emit_draw(c);
   check(submit(ctx, c) == 0, "a 2D_ARRAY sampler with a 2D view");
   const uint32_t want[2] = { GREEN, GREEN };
   check_stripes(ctx, 2, want, "a 2D view read through a 2D_ARRAY sampler");
}

/* a 2D view of R_TEX with swizzle s (3 bits per channel, PIPE_SWIZZLE_*) */
static void emit_view(struct cmds *c, int ctx, uint32_t handle, uint32_t s)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_VIEW,
                      VIRGL_OBJ_SAMPLER_VIEW_SIZE));
   emit(c, handle);
   emit(c, res_id(ctx, R_TEX));
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM | TEST_PIPE_TEXTURE_2D << 24);
   emit(c, 0);
   emit(c, 0);
   emit(c, s);
}

static void case_shared_swizzle(struct cmds *c, int ctx)
{
   emit_texture(c, ctx, 0xff00c040);          /* R 0x40, G 0xc0, B 0, A 0xff */
   emit_view(c, ctx, VIEW_R, 0 | 0 << 3 | 0 << 6 | 5 << 9);   /* RRR1 */
   emit_view(c, ctx, VIEW_G, 1 | 1 << 3 | 1 << 6 | 5 << 9);   /* GGG1 */
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_SAMPLER_VIEWS, 0, VIRGL_SET_SAMPLER_VIEWS_SIZE(2)));
   emit(c, TEST_SHADER_FRAGMENT);
   emit(c, 0);
   emit(c, VIEW_R);
   emit(c, VIEW_G);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SAMPLER_STATES, 0, 4));
   emit(c, TEST_SHADER_FRAGMENT);
   emit(c, 0);
   emit(c, SAMPLER);
   emit(c, SAMPLER);
   emit_bind_shaders(c, VS_PLAIN, FS_TWO_VIEWS);
   emit_stripe(c, 0);
   emit_draw(c);
   emit_bind_shaders(c, VS_PLAIN, FS_ONE_VIEW);
   emit_stripe(c, 1);
   emit_draw(c);
   check(submit(ctx, c) == 0, "two views of one texture with different swizzles");
   const uint32_t want[2] = { 0xff00c040, 0xff0000c0 };
   check_stripes(ctx, 2, want, "each view of a shared texture with its own swizzle");
}

static void case_odd(struct cmds *c, int ctx)
{
   emit_stripe(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2));    /* no data */
   emit(c, TEST_SHADER_VERTEX);
   emit(c, 0);
   emit_draw(c);
   emit_stripe(c, 1);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   check(submit(ctx, c) == 0, "a constants command with no data");
   if (const_ubo)
      check_stripes(ctx, 2, (const uint32_t[2]){ ZERO, GREEN }, "no data: zeros");

   emit_stripe(c, 2);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, BLUE);
   emit_draw(c);
   emit_stripe(c, 3);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2 + 16));   /* runs past the end */
   emit(c, TEST_SHADER_VERTEX);
   emit(c, 0);
   submit(ctx, c);
   uint32_t got[4];
   read_stripes(ctx, got);
   check(got[2] == BLUE, "a cut-off constants command: the draw before it");
}

static void case_counts(struct cmds *c, int ctx)
{
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "vertex constants before each of 4 draws, one submit");
   /* the program of the last draw, before a read-back binds another */
   GLint prog = 0;
   glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
   GLuint block = prog ? glGetUniformBlockIndex(prog, "vsconstblk") : GL_INVALID_INDEX;
   GLint plain = prog ? glGetUniformLocation(prog, "vsconst0") : -1;
   if (const_ubo)
      check(block != GL_INVALID_INDEX && plain == -1, "the program reads its constants "
            "from the block vsconstblk");
   else
      check(block == GL_INVALID_INDEX && plain != -1, "the program has the uniform vsconst0");
   check_stripes(ctx, 4, colours, "vertex constants per draw");
}

static struct totals totals_before;

static void check_counts(void)
{
   unsigned long long uploads = last.uploads - totals_before.uploads;
   unsigned long long binds = last.binds - totals_before.binds;
   unsigned long long own = last.own - totals_before.own;
   unsigned long long index = last.index - totals_before.index;
   unsigned long long windows = last.windows - totals_before.windows;
   char text[200];
   snprintf(text, sizeof(text), "4 constants commands and 4 draws: %llu uploads, %llu range binds, "
            "%llu index draws in %llu windows, %llu one by one", uploads, binds, index, windows, own);
   if (const_ubo == 2)
      check(uploads == 1 && binds == 0 && index == 4 && windows == 1 && own == 0, text);
   else if (const_ubo == 1)
      check(uploads == 1 && binds == 4 && index == 0 && windows == 0 && own == 0, text);
   else
      check(uploads == 0 && binds == 0 && index == 0 && own == 0, text);
}

static void case_many(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_CONST8, FS_VARYING);
   for (int k = 0; k < 800; k++) {
      emit_stripe(c, k % 4);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 8, 6, colours[(k / 4 + k) % 4]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "800 draws with their own 8 vec4s, one submit");
   uint32_t want[4];
   for (int s = 0; s < 4; s++)
      want[s] = colours[(796 / 4 + 796 + s) % 4];
   check_stripes(ctx, 4, want, "the last 4 of 800 draws");
}

static void check_many_counts(void)
{
   unsigned long long index = last.index - totals_before.index;
   unsigned long long windows = last.windows - totals_before.windows;
   char text[160];
   snprintf(text, sizeof(text), "800 draws: %llu index draws in %llu windows", index, windows);
   check(const_ubo == 2 ? index == 800 && windows >= 2 : index == 0, text);
}

static void case_inputs16(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_IN16, FS_VARYING);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "a vertex shader with 16 inputs");
   check_stripes(ctx, 4, colours, "16 inputs");
}

static void check_inputs16_counts(void)
{
   unsigned long long binds = last.binds - totals_before.binds;
   unsigned long long index = last.index - totals_before.index;
   unsigned long long own = last.own - totals_before.own;
   char text[160];
   snprintf(text, sizeof(text), "16 inputs: %llu range binds, %llu index draws, %llu one by one",
            binds, index, own);
   check(const_ubo == 1 ? binds == 4 && index == 0 : binds == 0 && index == 0 && own == 0, text);
}

static void check_stale_counts(void)
{
   unsigned long long own = last.own - totals_before.own;
   char text[160];
   snprintf(text, sizeof(text), "stale fragment constants went one by one %llu times", own);
   check(const_ubo ? own >= 1 : own == 0, text);
}

static void case_far(struct cmds *c, int ctx)
{
   emit_shader(c, VS_FAR, TEST_SHADER_VERTEX, vs_far);
   submit(ctx, c);   /* refused: a compile error (all modes) */
   float green[4][4], red[4][4];
   for (int k = 0; k < 4; k++)
      for (int i = 0; i < 4; i++) {
         green[k][i] = ((GREEN >> (8 * i)) & 0xff) / 255.0f;
         red[k][i] = ((RED >> (8 * i)) & 0xff) / 255.0f;
      }
   /* the far read first, so a window would start at its constants */
   emit_bind_shaders(c, VS_FAR, FS_VARYING);
   emit_stripe(c, 0);
   emit_consts(c, TEST_SHADER_VERTEX, 4, (const float (*)[4])green);
   emit_draw(c);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   for (int k = 0; k < 800; k++) {
      emit_stripe(c, 1 + k % 3);
      emit_consts(c, TEST_SHADER_VERTEX, 4, (const float (*)[4])red);
      emit_draw(c);
   }
   submit(ctx, c);
   uint32_t got[4];
   read_stripes(ctx, got);
   char text[160];
   snprintf(text, sizeof(text), "CONST[0][3000] of 4: no other draw's constants (0x%08x)", got[0]);
   check(got[0] != RED, text);
}

static void case_separable(struct cmds *c, int ctx)
{
   emit_shader(c, VS_SEP, TEST_SHADER_VERTEX, vs_sep);
   emit_shader(c, FS_SEP, TEST_SHADER_FRAGMENT, fs_sep);
   emit_bind_shaders(c, VS_SEP, FS_SEP);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_LINK_SHADER, 0, VIRGL_LINK_SHADER_SIZE));
   emit(c, VS_SEP);
   emit(c, FS_SEP);
   for (int i = 0; i < 4; i++)
      emit(c, 0);
   check(submit(ctx, c) == 0, "separable shaders linked early");
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "separable shaders: vertex constants before each draw");
   if (separable_refused) {
      printf("skip: the host refused the separable link (as with uniforms)\n");
      return;
   }
   /* Apple's software renderer: a new range for a pipeline that stays bound is not seen */
   check_stripes(ctx, const_ubo == 1 ? 1 : 4, colours, "separable shaders");
}

static void check_separable_counts(void)
{
   unsigned long long binds = last.binds - totals_before.binds;
   unsigned long long index = last.index - totals_before.index;
   char text[160];
   snprintf(text, sizeof(text), "separable: %llu index draws, %llu range binds", index, binds);
   if (separable_refused)
      return;
   check(const_ubo == 2 ? index == 4 : const_ubo == 1 ? binds == 4 : index == 0 && binds == 0,
         text);
}

static void check_zeroed(float mark);

static void case_zeroed(struct cmds *c, int ctx)
{
   const float mark = 0.123f;
   float pattern[8][4];
   for (int k = 0; k < 8; k++)
      for (int i = 0; i < 4; i++)
         pattern[k][i] = mark;
   emit_bind_shaders(c, VS_CONST8, FS_VARYING);
   for (int k = 0; k < 200; k++) {
      emit_stripe(c, k % 4);
      emit_consts(c, TEST_SHADER_VERTEX, 8, (const float (*)[4])pattern);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "a submit of 200 x 8 vec4s of a pattern");
   emit_bind_shaders(c, VS_CONST, FS_MUL);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, colours[s]);
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, WHITE);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "then small vertex and fragment constants");
   if (const_ubo)
      check_zeroed(mark);
   check_stripes(ctx, 4, colours, "small constants after a big submit");
}

/* the buffer the last draw's fragment constants are bound from (the submit's upload):
 * before a read-back binds another program */
static void check_zeroed(float mark)
{
   GLint prog = 0, binding = -1, buf = 0, prev = 0, size = 0;
   glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
   GLuint block = prog ? glGetUniformBlockIndex(prog, "fsconstblk") : GL_INVALID_INDEX;
   if (block != GL_INVALID_INDEX)
      glGetActiveUniformBlockiv(prog, block, GL_UNIFORM_BLOCK_BINDING, &binding);
   if (binding >= 0)
      glGetIntegeri_v(GL_UNIFORM_BUFFER_BINDING, binding, &buf);
   glGetIntegerv(GL_COPY_READ_BUFFER, &prev);   /* the binding (GL_COPY_READ_BUFFER_BINDING) */
   unsigned marks = 0;
   if (buf) {
      glBindBuffer(GL_COPY_READ_BUFFER, buf);
      glGetBufferParameteriv(GL_COPY_READ_BUFFER, GL_BUFFER_SIZE, &size);
      uint32_t *words = calloc(1, size > 0 ? size : 4), want;
      memcpy(&want, &mark, 4);
      glGetBufferSubData(GL_COPY_READ_BUFFER, 0, size, words);
      for (GLint i = 0; i < size / 4; i++)
         marks += words[i] == want;
      free(words);
      glBindBuffer(GL_COPY_READ_BUFFER, prev);
   }
   char text[200];
   snprintf(text, sizeof(text), "the uploaded constants buffer (%d bytes) holds %u words of the "
            "earlier submit", size, marks);
   check(buf && size > 0 && marks == 0, text);
}

/* 17: a vertex program without a window (16 inputs) whose constants go to the stage's own
 * buffer (a range at a misaligned offset), then a window program with the same constants:
 * the window must not be bound past that buffer's end (gl-oracle) */
static void case_own_small(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_IN16, FS_CONST);
   emit_stripe(c, 0);
   emit_colour_consts(c, TEST_SHADER_FRAGMENT, 2, 1, WHITE);  /* vertex entry lands at 32 */
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_stripe(c, 1);
   emit_draw(c);
   check(submit(ctx, c) == 0, "16 inputs, then a window program with the same constants");
   const uint32_t want[2] = { WHITE, GREEN };
   check_stripes(ctx, 2, want, "window after a vertex range program");
}

/* 18: the other way round: a window program from the own buffer (stale constants), then a
 * 16-input program re-specifies that buffer smaller, then the window program draws again
 * with its cached window binding */
static void case_own_shrink(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, RED);
   check(submit(ctx, c) == 0, "constants only");
   for (int k = 0; k < 5; k++) {
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, WHITE);
      check(submit(ctx, c) == 0, "ring turnover");
   }
   emit_stripe(c, 0);
   emit_draw(c);
   check(submit(ctx, c) == 0, "window draw from the own buffer");
   emit_bind_shaders(c, VS_IN16, FS_CONST);
   emit_stripe(c, 1);
   emit_colour_consts(c, TEST_SHADER_FRAGMENT, 2, 1, WHITE);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_stripe(c, 2);
   emit_draw(c);
   check(submit(ctx, c) == 0, "window again after a 16-input program");
   const uint32_t want[3] = { RED, WHITE, GREEN };
   check_stripes(ctx, 3, want, "window, 16 inputs, window");
}

/* 19: both orders in one context, in one submit and across submits */
static void case_own_mixed(struct cmds *c, int ctx)
{
   emit_bind_shaders(c, VS_IN16, FS_VARYING);
   emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, WHITE);   /* vertex entry not at 0 */
   emit_stripe(c, 0);
   emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, GREEN);
   emit_draw(c);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_stripe(c, 1);
   emit_draw(c);
   check(submit(ctx, c) == 0, "16 inputs then window, one submit");
   check_stripes(ctx, 2, (const uint32_t[2]){ GREEN, GREEN }, "one submit");
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_stripe(c, 2);
   emit_draw(c);
   check(submit(ctx, c) == 0, "window");
   for (int k = 0; k < 5; k++) {
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, WHITE);
      submit(ctx, c);
   }
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_stripe(c, 2);
   emit_draw(c);
   emit_bind_shaders(c, VS_IN16, FS_VARYING);
   emit_stripe(c, 3);
   emit_draw(c);
   emit_bind_shaders(c, VS_CONST, FS_VARYING);
   emit_stripe(c, 0);
   emit_draw(c);
   check(submit(ctx, c) == 0, "window, 16 inputs, window across submits");
   check_stripes(ctx, 4, (const uint32_t[4]){ GREEN, GREEN, GREEN, GREEN }, "mixed");
}

/* a geometry shader: the colour is the vertex colour times CONST[0][ADDR + 1], the index
 * from CONST[0][0].x */
static const char *gs_const =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[][1], GENERIC[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0][0..2]\n"
   "DCL ADDR[0]\n"
   "IMM[0] INT32 { 0, 0, 0, 0 }\n"
   "  0: ARL ADDR[0].x, CONST[0][0].xxxx\n"
   "  1: MOV OUT[0], IN[0][0]\n"
   "  2: MUL OUT[1], IN[0][1], CONST[0][ADDR[0].x+1]\n"
   "  3: EMIT IMM[0].xxxx\n"
   "  4: MOV OUT[0], IN[1][0]\n"
   "  5: MUL OUT[1], IN[1][1], CONST[0][ADDR[0].x+1]\n"
   "  6: EMIT IMM[0].xxxx\n"
   "  7: MOV OUT[0], IN[2][0]\n"
   "  8: MUL OUT[1], IN[2][1], CONST[0][ADDR[0].x+1]\n"
   "  9: EMIT IMM[0].xxxx\n"
   " 10: END\n";

/* 20: vertex (window), geometry (an index) and fragment constants, per draw */
static void case_gs(struct cmds *c, int ctx)
{
   emit_shader(c, GS_CONST, 2, gs_const);
   emit_bind_shaders(c, VS_CONST, FS_MUL);
   emit_bind_shader(c, GS_CONST, 2);
   const uint32_t vs[4] = { WHITE, YELLOW, WHITE, BLUE }, fs[4] = { RED, GREEN, BLUE, WHITE };
   for (int s = 0; s < 4; s++) {
      float g[3][4];
      memset(g, 0, sizeof(g));
      g[0][0] = s & 1;
      for (int i = 0; i < 4; i++) { g[1][i] = 1; g[2][i] = 1; }
      g[1][0] = 0;
      emit_stripe(c, s);
      emit_colour_consts(c, TEST_SHADER_VERTEX, 4, 2, vs[s]);
      emit_consts(c, 2, 3, (const float (*)[4])g);
      emit_colour_consts(c, TEST_SHADER_FRAGMENT, 1, 0, fs[s]);
      emit_draw(c);
   }
   check(submit(ctx, c) == 0, "three stages' constants per draw");
   const uint32_t want[4] = { 0xff000000, GREEN, BLUE, BLUE };
   check_stripes(ctx, 4, want, "vertex * geometry * fragment constants");
}

/* 21: random runs (programs, constants of 8 vec4s, submits, two sub contexts), one per
 * seed from SEED (default 1) for SEEDS seeds (default 4); prints a hash of the stripes
 * after every submit per seed: the same in all three modes (run-regressions.py) */
static unsigned rng_state;
static unsigned rnd(unsigned n)
{
   rng_state = rng_state * 1103515245u + 12345u;
   return (rng_state >> 16) % n;
}

static void random_run(struct cmds *c, int ctx, unsigned seed)
{
   static const uint32_t vss[] = { VS_CONST, VS_CONST8, VS_INDEX, VS_IN16, VS_PLAIN };
   static const uint32_t fss[] = { FS_VARYING, FS_CONST, FS_MUL };
   rng_state = seed;
   emit_sub_ctx(c, VIRGL_CCMD_CREATE_SUB_CTX, 1);
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 1);
   emit_state(c, ctx);
   emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
   submit(ctx, c);
   unsigned long long hash = 1469598103934665603ull;
   int sub = 0;
   for (int submitn = 0; submitn < 40; submitn++) {
      int ops = 1 + rnd(60);
      for (int k = 0; k < ops; k++) {
         switch (rnd(6)) {
         case 0: emit_bind_shader(c, vss[rnd(5)], TEST_SHADER_VERTEX); break;
         case 1: emit_bind_shader(c, fss[rnd(3)], TEST_SHADER_FRAGMENT); break;
         case 2: case 3: {
            float v[8][4];
            for (int a = 0; a < 8; a++)
               for (int b = 0; b < 4; b++)
                  v[a][b] = rnd(5) / 4.0f;
            v[0][0] = rnd(6);
            emit_consts(c, rnd(2) ? TEST_SHADER_VERTEX : TEST_SHADER_FRAGMENT, 8,
                        (const float (*)[4])v);
            break; }
         case 4:
            if (rnd(4) == 0) {
               sub = !sub;
               emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, sub);
            }
            break;
         default: emit_stripe(c, rnd(4)); emit_draw(c); break;
         }
      }
      submit(ctx, c);
      uint32_t got[4];
      read_stripes(ctx, got);
      for (int q = 0; q < 4; q++) {
         hash ^= got[q];
         hash *= 1099511628211ull;
      }
   }
   if (sub) {
      emit_sub_ctx(c, VIRGL_CCMD_SET_SUB_CTX, 0);
      submit(ctx, c);
   }
   emit_sub_ctx(c, VIRGL_CCMD_DESTROY_SUB_CTX, 1);
   submit(ctx, c);
   printf("random seed %u hash %016llx\n", seed, hash);
}

static void case_random(struct cmds *c, int ctx)
{
   const char *first = getenv("SEED"), *count = getenv("SEEDS");
   unsigned seed = first ? (unsigned)atoi(first) : 1, n = count ? (unsigned)atoi(count) : 4;
   for (unsigned k = 0; k < n; k++)
      random_run(c, ctx, seed + k);
   check(1, "random runs drawn (gl-oracle checked every draw)");
}

static void run_case(int n)
{
   static struct cmds c;
   int ctx = n;
   printf("case %d\n", n);
   c.n = 0;
   setup(&c, ctx);
   switch (n) {
   case 1: case_vs(&c, ctx); break;
   case 2: case_fs(&c, ctx); break;
   case 3: case_both(&c, ctx); break;
   case 4: case_stale(&c, ctx); break;
   case 5: case_short(&c, ctx); break;
   case 6: case_index(&c, ctx); break;
   case 7: case_programs(&c, ctx); break;
   case 8: case_subs(&c, ctx); break;
   case 9: case_ubo(&c, ctx); break;
   case 10: case_odd(&c, ctx); break;
   case 11: case_counts(&c, ctx); break;
   case 12: case_many(&c, ctx); break;
   case 13: case_inputs16(&c, ctx); break;
   case 14: case_far(&c, ctx); break;
   case 15: case_separable(&c, ctx); break;
   case 16: case_zeroed(&c, ctx); break;
   case 17: case_own_small(&c, ctx); break;
   case 18: case_own_shrink(&c, ctx); break;
   case 19: case_own_mixed(&c, ctx); break;
   case 20: case_gs(&c, ctx); break;
   case 21: case_random(&c, ctx); break;
   case 22: case_buffer0(&c, ctx); break;
   case 23: case_array_sampler(&c, ctx); break;
   case 24: case_shared_swizzle(&c, ctx); break;
   }
   teardown(ctx);
   if (n == 4)
      check_stale_counts();
   if (n == 11)
      check_counts();
   if (n == 12)
      check_many_counts();
   if (n == 13)
      check_inputs16_counts();
   if (n == 15)
      check_separable_counts();
   totals_before = last;
}

int main(int argc, char **argv)
{
   int only = argc > 1 ? atoi(argv[1]) : 0;

   setvbuf(stdout, NULL, _IONBF, 0);
   const char *env = getenv("OMACVM_VIRGL_CONST_UBO");
   const_ubo = env && !strcmp(env, "0") ? 0 : env && !strcmp(env, "1") ? 1 : 2;
   printf("shader constants: %s\n", const_ubo == 2 ? "uniform buffers, vertex window index" :
          const_ubo == 1 ? "uniform buffers, a range per draw" : "uniforms");
   setenv("OMACVM_VIRGL_CACHE_STATS", "1", 1);
   setenv("VIRGL_USE_INTEGER", "1", 1);

   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   virgl_set_log_callback(log_cb, NULL, NULL);
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }

   for (int n = 1; n <= 24; n++)
      if (!only || only == n)
         run_case(n);

   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "const ubo: FAILED" : "const ubo: all checks passed");
   return failures != 0;
}
