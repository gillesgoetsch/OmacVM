/* Whole programs (and their separable twins) that Apple's GL 4.1 drew wrong or refused because
 * it has no cull distances, no ARB_arrays_of_arrays and no atomic counters (#589), through the
 * public renderer API on Apple's software renderer (soft-gl.h, the GPU's GLSL front end). Each
 * row draws with new shaders and reads column 8 back (a 16-bit mask of the green rows) or the
 * recorded transform feedback values, and checks that no shader was refused and no context
 * error came. Each section runs in a guest context of its own:
 *  caps  the tessellation control and evaluation shaders' output limits reach the guest (its
 *        Mesa links whole tessellation programs against them; they were 0 without atomic
 *        counters: virgl-caps-tess-outputs.patch);
 *  A     a tessellation program without a geometry shader under a flipped viewport (a guest's
 *        window) draws where the same triangle from a vertex shader draws: the y prescale in a
 *        last evaluation shader (virgl-shader-clip-distances.patch), whole and separable;
 *  B     transform feedback recorded from a tessellation evaluation shader (same patch);
 *  C     clip distances (same patch): a vertex shader that writes gl_ClipDistance, with clip
 *        plane 0 off and on; a user clip plane (glClipPlane: rasterizer bit + SET_CLIP_STATE)
 *        after a vertex, geometry or tessellation shader; a tessellation evaluation shader's
 *        own clip distance; a separable vertex shader with its own and with the planes'; then
 *        one program drawn with the planes on, off and on again (a vertex shader, and a
 *        tessellation evaluation shader, as the last stage: the planes pick the variant);
 *        and a vertex shader that writes gl_CullDistance, which the Mac's GL has not: it stays
 *        refused, nothing drawn, no context error, the next rows still draw;
 *  E     a whole program with a varying array into a geometry shader (dynamically indexed:
 *        GL_ARB_arrays_of_arrays only where the GL has it, virgl-shader-arrays-of-arrays.patch),
 *        and its controls: single varyings into the geometry shader, an array into single
 *        fragment inputs. */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

enum { SHADER_VERTEX = 0, SHADER_FRAGMENT = 1, SHADER_GEOMETRY = 2, SHADER_TESS_CTRL = 3,
       SHADER_TESS_EVAL = 4 };
enum { PRIM_POINTS = 0, PRIM_TRIANGLES = 4, PRIM_PATCHES = 14, BUFFER = 0, TEXTURE_2D = 2,
       CLEAR_COLOR0 = 1 << 2 };
enum { GREEN = 0xff00ff00, GREY = 0xff808080 };
enum { RS_PLAIN = 41, RS_CLIP0 = 43 };
enum { R_COLOUR = 5, R_XFB = 13 };

static CGLContextObj main_ctx;
static int failures, refused_lines, ctx_error_lines;
static int verbose, has_cull_distance;
static uint32_t cur_ctx;      /* the guest context of the section that runs */
static uint32_t last_centre;   /* the pixel at (8, 8) of the last read */

static void count_log(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)level;
   (void)data;
   refused_lines += strstr(message, "refused a shader") || strstr(message, "Error linking") ||
                    strstr(message, "failed to compile");
   ctx_error_lines += strstr(message, "context error reported") != NULL;
   if (verbose)
      fputs(message, stderr);
}

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void write_fence(void *cookie, uint32_t fence) { (void)cookie; (void)fence; }

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie; (void)scanout; (void)param;
   return soft_gl_context(main_ctx);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie; (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1, .write_fence = write_fence, .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context, .make_current = make_current,
};

struct cmds {
   uint32_t dw[4096];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v) { c->dw[c->n++] = v; }

static void emit_float(struct cmds *c, float f)
{
   union { float f; uint32_t u; } v = { f };
   emit(c, v.u);
}

static void emit_shader_so(struct cmds *c, uint32_t handle, uint32_t type, const char *text, int so)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER,
                      (so ? VIRGL_OBJ_SHADER_HDR_SIZE(1) : 5) + words));
   emit(c, handle);
   emit(c, type);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(bytes));
   emit(c, 300);
   if (so) {
      emit(c, 1);                                     /* stream outputs */
      emit(c, 4); emit(c, 0); emit(c, 0); emit(c, 0); /* strides in dwords */
      emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_REGISTER_INDEX(1) |
              VIRGL_OBJ_SHADER_SO_OUTPUT_NUM_COMPONENTS(4));
      emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_STREAM(0));
   } else
      emit(c, 0);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], text, bytes);
   c->n += words;
}

static void emit_bind(struct cmds *c, uint32_t handle, uint32_t type)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SHADER, 0, 2));
   emit(c, handle);
   emit(c, type);
}

static void emit_draw(struct cmds *c, uint32_t mode, uint32_t count)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE_TESS));
   emit(c, 0);
   emit(c, count);
   emit(c, mode);
   for (int i = VIRGL_DRAW_VBO_INDEXED; i <= VIRGL_DRAW_VBO_COUNT_FROM_SO; i++)
      emit(c, 0);
   emit(c, mode == PRIM_PATCHES ? 3 : 0);
   emit(c, 0);
}

static void emit_clear_grey(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, CLEAR_COLOR0);
   for (int i = 0; i < 3; i++)
      emit_float(c, 128.0f / 255.0f);
   emit_float(c, 1.0f);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
}

static void emit_rasterizer(struct cmds *c, uint32_t handle, uint32_t s3)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(c, handle);
   emit(c, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   emit_float(c, 1.0f);             /* point size */
   emit(c, 0);                      /* sprite coord enable */
   emit(c, s3);
   emit_float(c, 1.0f);             /* line width */
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
}

static void emit_bind_rasterizer(struct cmds *c, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, handle);
}

/* the viewport over the 16x16 target; flip = a negative y scale (a window surface) */
static void emit_viewport(struct cmds *c, int flip)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);
   emit_float(c, 8);
   emit_float(c, flip ? -8 : 8);
   emit_float(c, 0.5f);
   emit_float(c, 8);
   emit_float(c, 8);
   emit_float(c, 0.5f);
}

/* user clip plane 0 = (0, 1, 0, 0): keeps y >= 0 */
static void emit_clip_state(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CLIP_STATE, 0, VIRGL_SET_CLIP_STATE_SIZE));
   for (int i = 0; i < VIRGL_SET_CLIP_STATE_SIZE; i++)
      emit_float(c, i == 1 ? 1.0f : 0.0f);
}

static void emit_setup(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, 6);
   emit(c, R_COLOUR);
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, 6);
   emit_viewport(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_BLEND, VIRGL_OBJ_BLEND_SIZE));
   emit(c, 40);
   emit(c, 0);
   emit(c, 0);
   for (int i = 0; i < VIRGL_MAX_COLOR_BUFS; i++)
      emit(c, VIRGL_OBJ_BLEND_S2_RT_COLORMASK(0xf));
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_BLEND, 1));
   emit(c, 40);
   emit_rasterizer(c, RS_PLAIN, 0);
   emit_rasterizer(c, RS_CLIP0, VIRGL_OBJ_RS_S3_CLIP_PLANE_ENABLE(1));
   emit_bind_rasterizer(c, RS_PLAIN);
   emit_clip_state(c);
}

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}

/* the rows (bit y) where column 8 is green; 0xffffffff if the read fails */
static uint32_t read_mask(int ctx_id)
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   if (virgl_renderer_transfer_read_iov(R_COLOUR, ctx_id, 0, 16 * 4, 0, &box, 0, &iov, 1))
      return ~0u;
   uint32_t mask = 0;
   last_centre = pixels[8 * 16 + 8];
   for (int y = 0; y < 16; y++)
      mask |= (uint32_t)(pixels[y * 16 + 8] == GREEN) << y;
   return mask;
}

/* Shaders. A separable copy gets "PROPERTY SEPARABLE_PROGRAM 1" after its first line. */
#define VS_POS_BODY \
   "  0: AND TEMP[0].x, SV[0].xxxx, IMM[0].xxxx\n" \
   "  1: AND TEMP[0].y, SV[0].xxxx, IMM[0].yyyy\n" \
   "  2: USHR TEMP[0].y, TEMP[0].yyyy, IMM[0].xxxx\n" \
   "  3: U2F TEMP[0].xy, TEMP[0].xyyy\n"

/* the top half (y 0..1) of the viewport */
static const char *vs_half =
   "VERT\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,     2.0000,    -1.0000,     0.0000}\n"
   "IMM[2] FLT32 {    0.5000,     1.0000,     0.0000,     0.0000}\n"
   VS_POS_BODY
   "  4: MAD OUT[0].xy, TEMP[0].xyyy, IMM[1].xyyy, IMM[1].zwww\n"
   "  5: MOV OUT[0].zw, IMM[2].xxxy\n"
   "  6: END\n";

/* the whole viewport */
static const char *vs_full =
   "VERT\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   VS_POS_BODY
   "  4: MAD OUT[0].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: MOV OUT[0].zw, IMM[1].zzzw\n"
   "  6: END\n";

/* the whole viewport, gl_ClipDistance[0] = y */
static const char *vs_clip =
   "VERT\n"
   "PROPERTY NUM_CLIPDIST_ENABLED 1\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], CLIPDIST[0]\n"
   "DCL TEMP[0..1]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   VS_POS_BODY
   "  4: MAD TEMP[1].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: MOV TEMP[1].zw, IMM[1].zzzw\n"
   "  6: MOV OUT[0], TEMP[1]\n"
   "  7: MOV OUT[1].x, TEMP[1].yyyy\n"
   "  8: END\n";

/* the whole viewport, gl_CullDistance[0] = y (the Mac's GL has no cull distances) */
static const char *vs_cull =
   "VERT\n"
   "PROPERTY NUM_CULLDIST_ENABLED 1\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], CLIPDIST[0]\n"
   "DCL TEMP[0..1]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   VS_POS_BODY
   "  4: MAD TEMP[1].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: MOV TEMP[1].zw, IMM[1].zzzw\n"
   "  6: MOV OUT[0], TEMP[1]\n"
   "  7: MOV OUT[1].x, TEMP[1].yyyy\n"
   "  8: END\n";

static const char *fs_green =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    0.0000,     1.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

static const char *fs_varying =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

static const char *tcs_pass =
   "TESS_CTRL\n"
   "PROPERTY TCS_VERTICES_OUT 3\n"
   "DCL IN[][0], POSITION\n"
   "DCL SV[0], INVOCATIONID\n"
   "DCL OUT[][0], POSITION\n"
   "DCL OUT[1], TESSOUTER\n"
   "DCL OUT[2], TESSINNER\n"
   "DCL ADDR[0]\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     0.0000}\n"
   "  0: UARL ADDR[0].x, SV[0].xxxx\n"
   "  1: MOV OUT[ADDR[0].x][0], IN[ADDR[0].x][0]\n"
   "  2: MOV OUT[1].x, IMM[0].xxxx\n"
   "  3: MOV OUT[1].y, IMM[0].xxxx\n"
   "  4: MOV OUT[1].z, IMM[0].xxxx\n"
   "  5: MOV OUT[2].x, IMM[0].xxxx\n"
   "  6: END\n";

#define TES_PROPS \
   "PROPERTY TES_PRIM_MODE 4\n" \
   "PROPERTY TES_SPACING 2\n" \
   "PROPERTY TES_VERTEX_ORDER_CW 0\n" \
   "PROPERTY TES_POINT_MODE 0\n"
#define TES_POS \
   "  0: MUL TEMP[0], IN[0][0], SV[0].xxxx\n" \
   "  1: MAD TEMP[0], IN[1][0], SV[0].yyyy, TEMP[0]\n" \
   "  2: MAD TEMP[0], IN[2][0], SV[0].zzzz, TEMP[0]\n" \
   "  3: MOV OUT[0], TEMP[0]\n"

static const char *tes_pos =
   "TESS_EVAL\n"
   TES_PROPS
   "DCL IN[][0], POSITION\n"
   "DCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\n"
   "DCL TEMP[0]\n"
   TES_POS
   "  4: END\n";

/* gl_ClipDistance[0] = y of the evaluated point */
static const char *tes_clip =
   "TESS_EVAL\n"
   TES_PROPS
   "PROPERTY NUM_CLIPDIST_ENABLED 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], CLIPDIST[0]\n"
   "DCL TEMP[0]\n"
   TES_POS
   "  4: MOV OUT[1].x, TEMP[0].yyyy\n"
   "  5: END\n";

/* records (0.25, 0.5, 0.75, 1) for each evaluated point (emit_shader_so) */
static const char *tes_xfb =
   "TESS_EVAL\n"
   TES_PROPS
   "DCL IN[][0], POSITION\n"
   "DCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] FLT32 {    0.2500,     0.5000,     0.7500,     1.0000}\n"
   TES_POS
   "  4: MOV OUT[1], IMM[0]\n"
   "  5: END\n";

static const char *gs_pass =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL OUT[0], POSITION\n"
   "IMM[0] INT32 {0, 0, 0, 0}\n"
   "  0: MOV OUT[0], IN[0][0]\n"
   "  1: EMIT IMM[0].xxxx\n"
   "  2: MOV OUT[0], IN[1][0]\n"
   "  3: EMIT IMM[0].xxxx\n"
   "  4: MOV OUT[0], IN[2][0]\n"
   "  5: EMIT IMM[0].xxxx\n"
   "  6: END\n";

/* separable varying array: green in two parts of OUT[1..2] (GENERIC[0..1]) */
static const char *vs_array =
   "VERT\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1..2], ARRAY(1), GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "IMM[2] FLT32 {    0.0000,     1.0000,     0.0000,     0.0000}\n"
   VS_POS_BODY
   "  4: MAD OUT[0].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: MOV OUT[0].zw, IMM[1].zzzw\n"
   "  6: MOV OUT[1], IMM[2].xyxx\n"
   "  7: MOV OUT[2], IMM[2].xxxy\n"
   "  8: END\n";

/* the same as two single outputs GENERIC[0], GENERIC[1] */
static const char *vs_two =
   "VERT\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL OUT[2], GENERIC[1]\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "IMM[2] FLT32 {    0.0000,     1.0000,     0.0000,     0.0000}\n"
   VS_POS_BODY
   "  4: MAD OUT[0].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: MOV OUT[0].zw, IMM[1].zzzw\n"
   "  6: MOV OUT[1], IMM[2].xyxx\n"
   "  7: MOV OUT[2], IMM[2].xxxy\n"
   "  8: END\n";

/* the same as two single inputs */
static const char *fs_two =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL IN[1], GENERIC[1], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: ADD OUT[0], IN[0], IN[1]\n"
   "  1: END\n";

/* a geometry shader passing the triangle on, the colour from GENERIC[0] + GENERIC[1] of
 * vertex 0 read as single inputs (gs_two) or as an array with a dynamic index (gs_array) */
static const char *gs_two =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[][1], GENERIC[0]\n"
   "DCL IN[][2], GENERIC[1]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] INT32 {0, 0, 0, 0}\n"
   "  0: ADD TEMP[0], IN[0][1], IN[0][2]\n"
   "  1: MOV OUT[0], IN[0][0]\n"
   "  2: MOV OUT[1], TEMP[0]\n"
   "  3: EMIT IMM[0].xxxx\n"
   "  4: MOV OUT[0], IN[1][0]\n"
   "  5: MOV OUT[1], TEMP[0]\n"
   "  6: EMIT IMM[0].xxxx\n"
   "  7: MOV OUT[0], IN[2][0]\n"
   "  8: MOV OUT[1], TEMP[0]\n"
   "  9: EMIT IMM[0].xxxx\n"
   " 10: END\n";

static const char *gs_array =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[][1..2], ARRAY(1), GENERIC[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "DCL ADDR[0]\n"
   "IMM[0] INT32 {0, 0, 0, 0}\n"
   "  0: UARL ADDR[0].x, IMM[0].xxxx\n"
   "  1: ADD TEMP[0], IN[0][ADDR[0].x+1], IN[0][2]\n"
   "  2: MOV OUT[0], IN[0][0]\n"
   "  3: MOV OUT[1], TEMP[0]\n"
   "  4: EMIT IMM[0].xxxx\n"
   "  5: MOV OUT[0], IN[1][0]\n"
   "  6: MOV OUT[1], TEMP[0]\n"
   "  7: EMIT IMM[0].xxxx\n"
   "  8: MOV OUT[0], IN[2][0]\n"
   "  9: MOV OUT[1], TEMP[0]\n"
   " 10: EMIT IMM[0].xxxx\n"
   " 11: END\n";

/* A copy marked separable. */
static const char *separable(const char *text)
{
   static char buf[8][4096];
   static int next;
   char *b = buf[next++ % 8];
   const char *nl = strchr(text, '\n');
   snprintf(b, sizeof(buf[0]), "%.*sPROPERTY SEPARABLE_PROGRAM 1\n%s", (int)(nl - text + 1), text,
            nl + 1);
   return b;
}

struct stage {
   uint32_t handle, type;
   const char *text;
   int so;
};

static uint32_t next_handle = 200;

/* clear grey, new shaders bound, one draw, the green rows */
static uint32_t draw_mask(const struct stage *stages, uint32_t mode, uint32_t count)
{
   struct cmds c = { .n = 0 };
   emit_clear_grey(&c);
   uint32_t handles[8];
   int n = 0;
   for (const struct stage *s = stages; s->text; s++, n++) {
      handles[n] = next_handle++;
      emit_shader_so(&c, handles[n], s->type, s->text, s->so);
      emit_bind(&c, handles[n], s->type);
   }
   emit_draw(&c, mode, count);
   if (submit(cur_ctx, &c))
      return ~0u;
   uint32_t mask = read_mask(cur_ctx);
   for (int i = 0; i < n; i++)
      emit_bind(&c, 0, stages[i].type);
   submit(cur_ctx, &c);
   return mask;
}

static void use(int flip, uint32_t rs)
{
   struct cmds c = { .n = 0 };
   emit_viewport(&c, flip);
   emit_bind_rasterizer(&c, rs);
   submit(cur_ctx, &c);
}

static void row(const char *what, const struct stage *stages, uint32_t mode, uint32_t want)
{
   char text[240];
   int refused = refused_lines, errors = ctx_error_lines;
   uint32_t got = draw_mask(stages, mode, 3);
   snprintf(text, sizeof(text), "%s: green rows 0x%04x, want 0x%04x (centre 0x%08x)", what, got, want,
            last_centre);
   check(got == want, text);
   snprintf(text, sizeof(text), "%s: no shader refused (%d), no context error (%d)", what,
            refused_lines - refused, ctx_error_lines - errors);
   check(refused_lines == refused && ctx_error_lines == errors, text);
}

static void xfb_row(int sep)
{
   struct virgl_renderer_resource_create_args args = {
      .handle = R_XFB, .target = BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_STREAM_OUTPUT, .width = 4096, .height = 1, .depth = 1, .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "B transform feedback: buffer");
   virgl_renderer_ctx_attach_resource(cur_ctx, R_XFB);
   int refused = refused_lines, errors = ctx_error_lines;
   struct cmds c = { .n = 0 };
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_STREAMOUT_TARGET,
                       VIRGL_OBJ_STREAMOUT_SIZE));
   emit(&c, 95);
   emit(&c, R_XFB);
   emit(&c, 0);
   emit(&c, 4096);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 2));
   emit(&c, 0);
   emit(&c, 95);
   const struct stage st[] = {
      { 0, SHADER_VERTEX, sep ? separable(vs_full) : vs_full, 0 },
      { 0, SHADER_TESS_CTRL, sep ? separable(tcs_pass) : tcs_pass, 0 },
      { 0, SHADER_TESS_EVAL, sep ? separable(tes_xfb) : tes_xfb, 1 },
      { 0, SHADER_FRAGMENT, sep ? separable(fs_varying) : fs_varying, 0 },
   };
   uint32_t h[4];
   for (int i = 0; i < 4; i++) {
      h[i] = next_handle++;
      emit_shader_so(&c, h[i], st[i].type, st[i].text, st[i].so);
      emit_bind(&c, h[i], st[i].type);
   }
   emit_draw(&c, PRIM_PATCHES, 3);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 1));
   emit(&c, 0);
   for (int i = 0; i < 4; i++)
      emit_bind(&c, 0, st[i].type);
   check(submit(cur_ctx, &c) == 0, "B transform feedback: the submit runs");
   float got[12] = { 0 };
   struct iovec iov = { got, sizeof(got) };
   struct virgl_box box = { 0, 0, 0, sizeof(got), 1, 1 };
   int r = virgl_renderer_transfer_read_iov(R_XFB, cur_ctx, 0, 0, 0, &box, 0, &iov, 1);
   int same = r == 0;
   for (int i = 0; i < 12; i++)
      same &= got[i] == 0.25f * (i % 4 + 1);
   char text[240];
   snprintf(text, sizeof(text), "B transform feedback from a %s tessellation evaluation shader: "
            "recorded (%.2f %.2f %.2f %.2f %.2f ...)", sep ? "separable" : "whole", got[0], got[1],
            got[2], got[3], got[4]);
   check(same, text);
   snprintf(text, sizeof(text), "B transform feedback (%s): no shader refused (%d), no context error",
            sep ? "separable" : "whole", refused_lines - refused);
   check(refused_lines == refused && ctx_error_lines == errors, text);
   virgl_renderer_ctx_detach_resource(cur_ctx, R_XFB);
   virgl_renderer_resource_unref(R_XFB);
}


/* A new guest context with the colour buffer and the fixed state for each section: a section that
 * ends its context on a host without the fixes (B on main) does not take the later ones with it. */
static void section_context(const char *name)
{
   if (cur_ctx) {
      virgl_renderer_ctx_detach_resource(cur_ctx, R_COLOUR);
      virgl_renderer_context_destroy(cur_ctx);
   }
   cur_ctx++;
   char text[80];
   snprintf(text, sizeof(text), "context %u for %s", cur_ctx, name);
   check(!virgl_renderer_context_create(cur_ctx, strlen(name), name), text);
   virgl_renderer_ctx_attach_resource(cur_ctx, R_COLOUR);
   struct cmds c = { .n = 0 };
   emit_setup(&c);
   snprintf(text, sizeof(text), "framebuffer of context %u", cur_ctx);
   check(submit(cur_ctx, &c) == 0, text);
}

/* the host's tessellation output limits as the guest gets them: its Mesa links each
 * tessellation shader's per-vertex outputs against them */
static void caps_row(void)
{
   GLint tcs = 0, tes = 0;
   glGetIntegerv(GL_MAX_TESS_CONTROL_OUTPUT_COMPONENTS, &tcs);
   glGetIntegerv(GL_MAX_TESS_EVALUATION_OUTPUT_COMPONENTS, &tes);
   uint32_t max_ver = 0, max_size = 0;
   virgl_renderer_get_cap_set(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, max_ver, caps);
   char text[200];
   snprintf(text, sizeof(text), "caps: tessellation control outputs %u, evaluation outputs %u "
            "(the GL's per-vertex limits %d and %d components)", caps->v2.max_tcs_outputs,
            caps->v2.max_tes_outputs, tcs, tes);
   check(tcs > 0 && tes > 0 && caps->v2.max_tcs_outputs == (uint32_t)tcs / 4 &&
         caps->v2.max_tes_outputs == (uint32_t)tes / 4, text);
   free(caps);
}

/* One program drawn with the user clip planes on, off and on again: the same shaders, so only
 * the planes pick what the last vertex stage writes. */
static void toggle_rows(const char *what, const struct stage *stages, uint32_t mode, uint32_t top)
{
   static const uint32_t rs[] = { RS_CLIP0, RS_PLAIN, RS_CLIP0 };
   struct cmds c = { .n = 0 };
   uint32_t handles[8];
   int n = 0;
   for (const struct stage *s = stages; s->text; s++, n++) {
      handles[n] = next_handle++;
      emit_shader_so(&c, handles[n], s->type, s->text, s->so);
      emit_bind(&c, handles[n], s->type);
   }
   submit(cur_ctx, &c);
   for (int i = 0; i < 3; i++) {
      int refused = refused_lines, errors = ctx_error_lines;
      emit_bind_rasterizer(&c, rs[i]);
      emit_clear_grey(&c);
      emit_draw(&c, mode, 3);
      uint32_t got = submit(cur_ctx, &c) ? ~0u : read_mask(cur_ctx);
      uint32_t want = rs[i] == RS_CLIP0 ? top : 0xffff;
      char text[240];
      snprintf(text, sizeof(text), "%s, draw %d (planes %s): green rows 0x%04x, want 0x%04x", what,
               i + 1, rs[i] == RS_CLIP0 ? "on" : "off", got, want);
      check(got == want, text);
      snprintf(text, sizeof(text), "%s, draw %d: no shader refused (%d), no context error (%d)",
               what, i + 1, refused_lines - refused, ctx_error_lines - errors);
      check(refused_lines == refused && ctx_error_lines == errors, text);
   }
   for (int i = 0; i < n; i++)
      emit_bind(&c, 0, stages[i].type);
   emit_bind_rasterizer(&c, RS_PLAIN);
   submit(cur_ctx, &c);
}

/* A shader the host cannot have (gl_CullDistance on a GL without cull distances): refused,
 * its draw skipped, no context error; the renderer goes on. */
static void cull_row(void)
{
   int refused = refused_lines, errors = ctx_error_lines;
   uint32_t got = draw_mask((const struct stage[]){ { 0, SHADER_VERTEX, vs_cull, 0 },
                                                     { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
                            PRIM_TRIANGLES, 3);
   char text[240];
   if (has_cull_distance) {
      snprintf(text, sizeof(text), "C9 vertex shader with gl_CullDistance (the GL has cull "
               "distances): drawn 0x%04x, refused %d", got, refused_lines - refused);
      check(got == 0xffff && refused_lines == refused, text);
   } else {
      snprintf(text, sizeof(text), "C9 vertex shader with gl_CullDistance on a GL without cull "
               "distances: still refused (%d lines), nothing drawn (0x%04x), no context error (%d)",
               refused_lines - refused, got, ctx_error_lines - errors);
      check(refused_lines > refused && got == 0 && ctx_error_lines == errors, text);
   }
}

int main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   verbose = getenv("TEST_SHAPES_VERBOSE") != NULL;
   const char *only = argc > 1 ? argv[1] : "ABCE";
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   GLint num_ext = 0;
   glGetIntegerv(GL_NUM_EXTENSIONS, &num_ext);
   for (GLint i = 0; i < num_ext; i++)
      has_cull_distance |= !strcmp((const char *)glGetStringi(GL_EXTENSIONS, i),
                                   "GL_ARB_cull_distance");
   virgl_set_log_callback(count_log, NULL, NULL);
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   caps_row();
   struct virgl_renderer_resource_create_args args = {
      .handle = R_COLOUR, .target = TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1, .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "colour buffer");
   section_context("reference");

   /* references: the top half from a vertex shader, straight and flipped */
   use(0, RS_PLAIN);
   uint32_t top = draw_mask((const struct stage[]){ { 0, SHADER_VERTEX, vs_half, 0 },
                                                     { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
                            PRIM_TRIANGLES, 3);
   use(1, RS_PLAIN);
   uint32_t top_flipped = draw_mask((const struct stage[]){ { 0, SHADER_VERTEX, vs_half, 0 },
                                                             { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
                                    PRIM_TRIANGLES, 3);
   char text[200];
   snprintf(text, sizeof(text), "reference: top half 0x%04x, flipped 0x%04x (8 rows each, apart)",
            top, top_flipped);
   check(__builtin_popcount(top) == 8 && __builtin_popcount(top_flipped) == 8 && top != top_flipped,
         text);

   if (strchr(only, 'A')) {
      section_context("A");
      for (int sep = 0; sep < 2; sep++) {
         for (int flip = 0; flip < 2; flip++) {
            use(flip, RS_PLAIN);
            snprintf(text, sizeof(text), "A %s tessellation, %s viewport: drawn where the vertex shader draws",
                     sep ? "separable" : "whole", flip ? "flipped" : "straight");
            row(text, (const struct stage[]){
                   { 0, SHADER_VERTEX, sep ? separable(vs_half) : vs_half, 0 },
                   { 0, SHADER_TESS_CTRL, sep ? separable(tcs_pass) : tcs_pass, 0 },
                   { 0, SHADER_TESS_EVAL, sep ? separable(tes_pos) : tes_pos, 0 },
                   { 0, SHADER_FRAGMENT, sep ? separable(fs_green) : fs_green, 0 }, { 0 } },
                PRIM_PATCHES, flip ? top_flipped : top);
         }
      }
      use(0, RS_PLAIN);
   }

   if (strchr(only, 'B')) {
      section_context("B");
      xfb_row(0);
      xfb_row(1);
   }

   if (strchr(only, 'C')) {
      section_context("C");
      use(0, RS_PLAIN);
      row("C0 vertex shader with gl_ClipDistance, clip plane off: all drawn", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_clip, 0 }, { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_TRIANGLES, 0xffff);
      use(0, RS_CLIP0);
      row("C1 vertex shader with gl_ClipDistance = y, plane 0 on: top half", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_clip, 0 }, { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_TRIANGLES, top);
      row("C2 user clip plane y >= 0 after a vertex shader: top half", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_full, 0 }, { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_TRIANGLES, top);
      row("C3 user clip plane after a geometry shader: top half", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_full, 0 }, { 0, SHADER_GEOMETRY, gs_pass, 0 },
             { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_TRIANGLES, top);
      row("C4 user clip plane after tessellation: top half", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_full, 0 }, { 0, SHADER_TESS_CTRL, tcs_pass, 0 },
             { 0, SHADER_TESS_EVAL, tes_pos, 0 }, { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_PATCHES, top);
      row("C5 tessellation evaluation shader with gl_ClipDistance = y: top half", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_full, 0 }, { 0, SHADER_TESS_CTRL, tcs_pass, 0 },
             { 0, SHADER_TESS_EVAL, tes_clip, 0 }, { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_PATCHES, top);
      row("C6 separable vertex shader with gl_ClipDistance = y: top half", (const struct stage[]){
             { 0, SHADER_VERTEX, separable(vs_clip), 0 },
             { 0, SHADER_FRAGMENT, separable(fs_green), 0 }, { 0 } },
          PRIM_TRIANGLES, top);
      row("C7 separable: user clip plane after a vertex shader: top half", (const struct stage[]){
             { 0, SHADER_VERTEX, separable(vs_full), 0 },
             { 0, SHADER_FRAGMENT, separable(fs_green), 0 }, { 0 } },
          PRIM_TRIANGLES, top);
      use(0, RS_PLAIN);
      row("C8 after the clip rows, plane off again: all drawn", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_full, 0 }, { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_TRIANGLES, 0xffff);
      toggle_rows("C10 one program, user clip plane after a vertex shader",
                  (const struct stage[]){ { 0, SHADER_VERTEX, vs_full, 0 },
                                          { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
                  PRIM_TRIANGLES, top);
      toggle_rows("C11 one program, user clip plane after tessellation",
                  (const struct stage[]){ { 0, SHADER_VERTEX, vs_full, 0 },
                                          { 0, SHADER_TESS_CTRL, tcs_pass, 0 },
                                          { 0, SHADER_TESS_EVAL, tes_pos, 0 },
                                          { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
                  PRIM_PATCHES, top);
      /* its own context: the refusal is logged once per context */
      section_context("C9");
      use(0, RS_PLAIN);
      cull_row();
      row("C12 after the refused shader: all drawn", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_full, 0 }, { 0, SHADER_FRAGMENT, fs_green, 0 }, { 0 } },
          PRIM_TRIANGLES, 0xffff);
   }

   if (strchr(only, 'E')) {
      section_context("E");
      use(0, RS_PLAIN);
      row("E8 whole program: array output into a geometry shader's array input (green)",
          (const struct stage[]){
             { 0, SHADER_VERTEX, vs_array, 0 }, { 0, SHADER_GEOMETRY, gs_array, 0 },
             { 0, SHADER_FRAGMENT, fs_varying, 0 }, { 0 } },
          PRIM_TRIANGLES, 0xffff);
      row("E9 whole program: single outputs into a geometry shader's single inputs (green)",
          (const struct stage[]){
             { 0, SHADER_VERTEX, vs_two, 0 }, { 0, SHADER_GEOMETRY, gs_two, 0 },
             { 0, SHADER_FRAGMENT, fs_varying, 0 }, { 0 } },
          PRIM_TRIANGLES, 0xffff);
      row("E4 whole program: array output, single inputs (green)", (const struct stage[]){
             { 0, SHADER_VERTEX, vs_array, 0 }, { 0, SHADER_FRAGMENT, fs_two, 0 }, { 0 } },
          PRIM_TRIANGLES, 0xffff);
   }

   virgl_renderer_ctx_detach_resource(cur_ctx, R_COLOUR);
   virgl_renderer_context_destroy(cur_ctx);
   virgl_renderer_resource_unref(R_COLOUR);
   virgl_renderer_cleanup(&cookie);
   if (failures)
      printf("whole program shapes: %d checks FAILED\n", failures);
   else
      printf("whole program shapes: all checks passed\n");
   return failures != 0;
}
