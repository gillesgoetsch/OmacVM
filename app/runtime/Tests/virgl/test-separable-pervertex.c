/* Separable programs (program pipelines: glCreateShaderProgramv, GL_PROGRAM_SEPARABLE in the
 * guest) through the public renderer API on Apple's software renderer (soft-gl.h), which has
 * the same GLSL front end as the Mac's GPU. Apple's GL links a separable shader only when it
 * redeclares the gl_PerVertex block whose members it uses (out: gl_Position, gl_PointSize;
 * in: gl_in[]); vrend wrote the block only for a stage that is not the last one and whose next
 * stage asked for it, so no separable pipeline ever linked on the Mac and their draws were
 * skipped (#567, virgl-shader-separable-pervertex.patch). Each row draws with new separable
 * shaders and reads the colour back:
 *  - vertex + fragment, a varying between them (green);
 *  - a vertex shader that writes gl_PointSize: one point covers the 16x16 target (blue);
 *  - vertex + geometry + fragment, the geometry shader reads gl_in[] (yellow);
 *  - vertex + tessellation control + evaluation + fragment (magenta);
 *  - vertex + tessellation + geometry + fragment (cyan);
 *  - blocks that differ between stages: a vertex shader that writes gl_PointSize before a
 *    geometry shader that reads only gl_Position (yellow), and one that reads
 *    gl_in[].gl_PointSize (yellow from the point size);
 *  - clip distance arrays inside the blocks (vrend writes them on the Mac too since
 *    virgl-shader-clip-distances.patch): a geometry shader with clip outputs (yellow), and
 *    tessellation control and evaluation shaders that pass them on (magenta);
 *  - a flat integer varying (green);
 *  - transform feedback from a separable vertex shader: the recorded values come back;
 *  - programs with separable and whole stages, linked as one program: a whole vertex shader
 *    before a separable geometry shader (yellow), a separable vertex shader before a whole
 *    fragment shader (green);
 * and no shader is refused, no context error, no pipeline found invalid. Then rows where the
 * GL's pipeline validation fails at the first draw (virgl-pipeline-validate-log.patch):
 *  - a fragment shader that reads a 2D and a cube texture: vrend validates before the draw
 *    sets the sampler units, so both are on unit 0 ("Samplers of different types use the
 *    same texture image unit"): one log line, no context error, and it draws the sum of both
 *    textures (yellow);
 *  - a new pipeline's first draw into an incomplete framebuffer: that draw is lost, the
 *    context is not; the next draw with a complete framebuffer draws;
 *  - a context logs three such lines; another context logs its own.
 * With OMACVM_VIRGL_SHADER_FAILURES=lose the first two lose their context, as upstream.
 * Last, two shapes Apple's GL still refuses as separable programs (vrend's IO locations,
 * follow-ups): a patch varying from the tessellation control to the evaluation shader, and
 * a varying array. Their draws are skipped and logged, nothing crashes, the context draws
 * on. */
#include <OpenGL/OpenGL.h>
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
       TEXTURE_CUBE = 4, CLEAR_COLOR0 = 1 << 2 };
enum { GREEN = 0xff00ff00, BLUE = 0xffff0000, YELLOW = 0xff00ffff, MAGENTA = 0xffff00ff,
       CYAN = 0xffffff00, RED = 0xff0000ff, GREY = 0xff808080 };
enum { RS_TRIANGLES = 41, RS_POINTS = 42 };
/* resources: colour buffer, 4-sample buffer, 2D and cube textures, transform feedback */
enum { R_COLOUR = 5, R_MSAA = 7, R_TEX_2D = 11, R_TEX_CUBE = 12, R_XFB = 13 };

static CGLContextObj main_ctx;
static int failures, refused_lines, ctx_error_lines, invalid_lines, pipeline_error_lines;
static int invalid_ctx;   /* the context of the last "program pipeline invalid" line */

static void count_log(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)level;
   (void)data;
   /* "refused" is logged at most three times per context, the GL's own lines every time */
   refused_lines += strstr(message, "refused a shader") || strstr(message, "Error linking") ||
                    strstr(message, "failed to compile");
   ctx_error_lines += strstr(message, "context error reported") != NULL;
   if (strstr(message, "program pipeline invalid")) {
      invalid_lines++;
      if (sscanf(message, "context %d", &invalid_ctx) != 1)
         invalid_ctx = -1;
   }
   pipeline_error_lines += strstr(message, "context error reported") &&
                           strstr(message, "Illegal shader program pipeline");
   fputs(message, stderr);
}

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
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
   uint32_t dw[2048];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v)
{
   c->dw[c->n++] = v;
}

static void emit_float(struct cmds *c, float f)
{
   union { float f; uint32_t u; } v = { f };
   emit(c, v.u);
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

/* a vertex shader that records OUT[1] (4 components) into stream output buffer 0 */
static void emit_xfb_shader(struct cmds *c, uint32_t handle, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER,
                      VIRGL_OBJ_SHADER_HDR_SIZE(1) + words));
   emit(c, handle);
   emit(c, SHADER_VERTEX);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(bytes));
   emit(c, 300);
   emit(c, 1);                                     /* stream outputs */
   emit(c, 4); emit(c, 0); emit(c, 0); emit(c, 0); /* strides in dwords */
   emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_REGISTER_INDEX(1) |
           VIRGL_OBJ_SHADER_SO_OUTPUT_NUM_COMPONENTS(4));
   emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_STREAM(0));
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

/* mode PRIM_PATCHES draws with three vertices per patch */
static void emit_draw(struct cmds *c, uint32_t mode, uint32_t count)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE_TESS));
   emit(c, 0);                      /* start */
   emit(c, count);
   emit(c, mode);
   for (int i = VIRGL_DRAW_VBO_INDEXED; i <= VIRGL_DRAW_VBO_COUNT_FROM_SO; i++)
      emit(c, 0);
   emit(c, mode == PRIM_PATCHES ? 3 : 0); /* vertices per patch */
   emit(c, 0);                      /* draw id */
}

static void emit_clear_grey(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, CLEAR_COLOR0);
   for (int i = 0; i < 3; i++)
      emit_float(c, 128.0f / 255.0f);
   emit_float(c, 1.0f);
   emit(c, 0);                      /* depth (double) */
   emit(c, 0);
   emit(c, 0);                      /* stencil */
}

static void emit_rasterizer(struct cmds *c, uint32_t handle, uint32_t s0, float point_size)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(c, handle);
   emit(c, s0);
   emit_float(c, point_size);
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 3; i++)
      emit(c, 0);
}

static void emit_bind_rasterizer(struct cmds *c, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, handle);
}

static void emit_framebuffer(struct cmds *c, uint32_t nr_cbufs, const uint32_t *surfaces)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0,
                      VIRGL_SET_FRAMEBUFFER_STATE_SIZE(nr_cbufs)));
   emit(c, nr_cbufs);
   emit(c, 0);
   for (uint32_t i = 0; i < nr_cbufs; i++)
      emit(c, surfaces[i]);
}

/* surface 6 on resource 5, framebuffer, 16x16 viewport, blend and rasterizer state */
static void emit_setup(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, 6);
   emit(c, 5);
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit_framebuffer(c, 1, (const uint32_t[]){ 6 });
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);
   emit_float(c, 8);
   emit_float(c, 8);
   emit_float(c, 0.5f);
   emit_float(c, 8);
   emit_float(c, 8);
   emit_float(c, 0.5f);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_BLEND, VIRGL_OBJ_BLEND_SIZE));
   emit(c, 40);
   emit(c, 0);
   emit(c, 0);
   for (int i = 0; i < VIRGL_MAX_COLOR_BUFS; i++)
      emit(c, VIRGL_OBJ_BLEND_S2_RT_COLORMASK(0xf));
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_BLEND, 1));
   emit(c, 40);
   emit_rasterizer(c, RS_TRIANGLES, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1), 1.0f);
   emit_rasterizer(c, RS_POINTS, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1) |
                   VIRGL_OBJ_RS_S0_POINT_SIZE_PER_VERTEX(1), 1.0f);
   emit_bind_rasterizer(c, RS_TRIANGLES);
}

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}

static uint32_t read_pixel_in(int ctx_id, int x, int y)
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   if (virgl_renderer_transfer_read_iov(R_COLOUR, ctx_id, 0, 16 * 4, 0, &box, 0, &iov, 1))
      return ~0u;
   return pixels[y * 16 + x];
}

static uint32_t read_pixel(int x, int y)
{
   return read_pixel_in(1, x, y);
}

/* A triangle over the whole viewport from gl_VertexID. */
#define VS_TRIANGLE_HEAD \
   "VERT\n" \
   "PROPERTY SEPARABLE_PROGRAM 1\n" \
   "DCL SV[0], VERTEXID\n" \
   "DCL OUT[0], POSITION\n"
#define VS_TRIANGLE_BODY \
   "  0: AND TEMP[0].x, SV[0].xxxx, IMM[0].xxxx\n" \
   "  1: AND TEMP[0].y, SV[0].xxxx, IMM[0].yyyy\n" \
   "  2: USHR TEMP[0].y, TEMP[0].yyyy, IMM[0].xxxx\n" \
   "  3: U2F TEMP[0].xy, TEMP[0].xyyy\n" \
   "  4: MAD OUT[0].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n" \
   "  5: MOV OUT[0].zw, IMM[1].zzzw\n"

static const char *vs_triangle =
   VS_TRIANGLE_HEAD
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   VS_TRIANGLE_BODY
   "  6: END\n";

/* the same, and green as a varying */
static const char *vs_triangle_green =
   VS_TRIANGLE_HEAD
   "DCL OUT[1], GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "IMM[2] FLT32 {    0.0000,     1.0000,     0.0000,     1.0000}\n"
   VS_TRIANGLE_BODY
   "  6: MOV OUT[1], IMM[2]\n"
   "  7: END\n";

/* one point in the middle, 16 pixels wide (gl_PointSize) */
static const char *vs_point =
   "VERT\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], PSIZE\n"
   "IMM[0] FLT32 {    0.0000,     0.5000,     1.0000,    16.0000}\n"
   "  0: MOV OUT[0], IMM[0].xxyz\n"
   "  1: MOV OUT[1].x, IMM[0].wwww\n"
   "  2: END\n";

static const char *fs_varying =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

static const char *fs_blue =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    0.0000,     0.0000,     1.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

/* passes the triangle on, yellow as a varying */
static const char *gs_yellow =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "IMM[0] INT32 {0, 0, 0, 0}\n"
   "IMM[1] FLT32 {    1.0000,     1.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IN[0][0]\n"
   "  1: MOV OUT[1], IMM[1]\n"
   "  2: EMIT IMM[0].xxxx\n"
   "  3: MOV OUT[0], IN[1][0]\n"
   "  4: MOV OUT[1], IMM[1]\n"
   "  5: EMIT IMM[0].xxxx\n"
   "  6: MOV OUT[0], IN[2][0]\n"
   "  7: MOV OUT[1], IMM[1]\n"
   "  8: EMIT IMM[0].xxxx\n"
   "  9: END\n";

/* the same reading the colour from the stage before */
static const char *gs_pass =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[][1], GENERIC[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "IMM[0] INT32 {0, 0, 0, 0}\n"
   "  0: MOV OUT[0], IN[0][0]\n"
   "  1: MOV OUT[1], IN[0][1]\n"
   "  2: EMIT IMM[0].xxxx\n"
   "  3: MOV OUT[0], IN[1][0]\n"
   "  4: MOV OUT[1], IN[1][1]\n"
   "  5: EMIT IMM[0].xxxx\n"
   "  6: MOV OUT[0], IN[2][0]\n"
   "  7: MOV OUT[1], IN[2][1]\n"
   "  8: EMIT IMM[0].xxxx\n"
   "  9: END\n";

/* passes each vertex on; tessellation levels 1 */
static const char *tcs_pass =
   "TESS_CTRL\n"
   "PROPERTY TCS_VERTICES_OUT 3\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
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

/* the triangle's point at the tessellation coordinate; magenta, or cyan for a geometry
 * shader after it */
#define TES_HEAD \
   "TESS_EVAL\n" \
   "PROPERTY TES_PRIM_MODE 4\n" \
   "PROPERTY TES_SPACING 2\n" \
   "PROPERTY TES_VERTEX_ORDER_CW 0\n" \
   "PROPERTY TES_POINT_MODE 0\n" \
   "PROPERTY SEPARABLE_PROGRAM 1\n" \
   "DCL IN[][0], POSITION\n" \
   "DCL SV[0], TESSCOORD\n" \
   "DCL OUT[0], POSITION\n" \
   "DCL OUT[1], GENERIC[0]\n" \
   "DCL TEMP[0]\n"
#define TES_BODY \
   "  0: MUL TEMP[0], IN[0][0], SV[0].xxxx\n" \
   "  1: MAD TEMP[0], IN[1][0], SV[0].yyyy, TEMP[0]\n" \
   "  2: MAD OUT[0], IN[2][0], SV[0].zzzz, TEMP[0]\n" \
   "  3: MOV OUT[1], IMM[0]\n" \
   "  4: END\n"

static const char *tes_magenta =
   TES_HEAD
   "IMM[0] FLT32 {    1.0000,     0.0000,     1.0000,     1.0000}\n"
   TES_BODY;

static const char *tes_cyan =
   TES_HEAD
   "IMM[0] FLT32 {    0.0000,     1.0000,     1.0000,     1.0000}\n"
   TES_BODY;

/* the triangle, and gl_PointSize 1 */
static const char *vs_triangle_psize =
   VS_TRIANGLE_HEAD
   "DCL OUT[1], PSIZE\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   VS_TRIANGLE_BODY
   "  6: MOV OUT[1].x, IMM[1].wwww\n"
   "  7: END\n";

/* passes the triangle on, its colour from gl_in[].gl_PointSize: (size, size, 0, 1) */
static const char *gs_psize =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[][1], PSIZE\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] INT32 {0, 0, 0, 0}\n"
   "IMM[1] FLT32 {    0.0000,     1.0000,     0.0000,     0.0000}\n"
   "  0: MOV TEMP[0].xy, IN[0][1].xxxx\n"
   "  1: MOV TEMP[0].zw, IMM[1].xxxy\n"
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

/* gs_yellow with four clip distances (1: nothing clipped) */
static const char *gs_clip =
   "GEOM\n"
   "PROPERTY GS_INPUT_PRIMITIVE TRIANGLES\n"
   "PROPERTY GS_OUTPUT_PRIMITIVE TRIANGLE_STRIP\n"
   "PROPERTY GS_MAX_OUTPUT_VERTICES 3\n"
   "PROPERTY GS_INVOCATIONS 1\n"
   "PROPERTY NUM_CLIPDIST_ENABLED 4\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL OUT[2], CLIPDIST[0]\n"
   "IMM[0] INT32 {0, 0, 0, 0}\n"
   "IMM[1] FLT32 {    1.0000,     1.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IN[0][0]\n"
   "  1: MOV OUT[1], IMM[1]\n"
   "  2: MOV OUT[2], IMM[1].xxxx\n"
   "  3: EMIT IMM[0].xxxx\n"
   "  4: MOV OUT[0], IN[1][0]\n"
   "  5: MOV OUT[1], IMM[1]\n"
   "  6: MOV OUT[2], IMM[1].xxxx\n"
   "  7: EMIT IMM[0].xxxx\n"
   "  8: MOV OUT[0], IN[2][0]\n"
   "  9: MOV OUT[1], IMM[1]\n"
   " 10: MOV OUT[2], IMM[1].xxxx\n"
   " 11: EMIT IMM[0].xxxx\n"
   " 12: END\n";

/* tcs_pass with four clip distances per vertex (gl_out[]) */
static const char *tcs_clip =
   "TESS_CTRL\n"
   "PROPERTY TCS_VERTICES_OUT 3\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL SV[0], INVOCATIONID\n"
   "DCL OUT[][0], POSITION\n"
   "DCL OUT[][1], CLIPDIST[0]\n"
   "DCL OUT[2], TESSOUTER\n"
   "DCL OUT[3], TESSINNER\n"
   "DCL ADDR[0]\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     0.0000}\n"
   "  0: UARL ADDR[0].x, SV[0].xxxx\n"
   "  1: MOV OUT[ADDR[0].x][0], IN[ADDR[0].x][0]\n"
   "  2: MOV OUT[ADDR[0].x][1], IMM[0].xxxx\n"
   "  3: MOV OUT[2].x, IMM[0].xxxx\n"
   "  4: MOV OUT[2].y, IMM[0].xxxx\n"
   "  5: MOV OUT[2].z, IMM[0].xxxx\n"
   "  6: MOV OUT[3].x, IMM[0].xxxx\n"
   "  7: END\n";

/* tes_magenta that reads the clip distances (gl_in[]) and writes them on */
static const char *tes_clip =
   "TESS_EVAL\n"
   "PROPERTY TES_PRIM_MODE 4\n"
   "PROPERTY TES_SPACING 2\n"
   "PROPERTY TES_VERTEX_ORDER_CW 0\n"
   "PROPERTY TES_POINT_MODE 0\n"
   "PROPERTY NUM_CLIPDIST_ENABLED 4\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[][1], CLIPDIST[0]\n"
   "DCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL OUT[2], CLIPDIST[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     1.0000,     1.0000}\n"
   "  0: MUL TEMP[0], IN[0][0], SV[0].xxxx\n"
   "  1: MAD TEMP[0], IN[1][0], SV[0].yyyy, TEMP[0]\n"
   "  2: MAD OUT[0], IN[2][0], SV[0].zzzz, TEMP[0]\n"
   "  3: MOV OUT[1], IMM[0]\n"
   "  4: MOV OUT[2], IN[0][1]\n"
   "  5: END\n";

/* tcs_pass that also writes a patch varying (white) */
static const char *tcs_patch =
   "TESS_CTRL\n"
   "PROPERTY TCS_VERTICES_OUT 3\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL SV[0], INVOCATIONID\n"
   "DCL OUT[][0], POSITION\n"
   "DCL OUT[1], TESSOUTER\n"
   "DCL OUT[2], TESSINNER\n"
   "DCL OUT[3], PATCH[0]\n"
   "DCL ADDR[0]\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     0.0000}\n"
   "  0: UARL ADDR[0].x, SV[0].xxxx\n"
   "  1: MOV OUT[ADDR[0].x][0], IN[ADDR[0].x][0]\n"
   "  2: MOV OUT[1].x, IMM[0].xxxx\n"
   "  3: MOV OUT[1].y, IMM[0].xxxx\n"
   "  4: MOV OUT[1].z, IMM[0].xxxx\n"
   "  5: MOV OUT[2].x, IMM[0].xxxx\n"
   "  6: MOV OUT[3], IMM[0].xxxx\n"
   "  7: END\n";

/* the triangle's point, its colour from the patch varying */
static const char *tes_patch =
   "TESS_EVAL\n"
   "PROPERTY TES_PRIM_MODE 4\n"
   "PROPERTY TES_SPACING 2\n"
   "PROPERTY TES_VERTEX_ORDER_CW 0\n"
   "PROPERTY TES_POINT_MODE 0\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[][0], POSITION\n"
   "DCL IN[1], PATCH[0]\n"
   "DCL SV[0], TESSCOORD\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "  0: MUL TEMP[0], IN[0][0], SV[0].xxxx\n"
   "  1: MAD TEMP[0], IN[1][0], SV[0].yyyy, TEMP[0]\n"
   "  2: MAD OUT[0], IN[2][0], SV[0].zzzz, TEMP[0]\n"
   "  3: MOV OUT[1], IN[1]\n"
   "  4: END\n";

/* the triangle, and green as integers (0, 255, 0, 255) for a flat input */
static const char *vs_triangle_int =
   VS_TRIANGLE_HEAD
   "DCL OUT[1], GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "IMM[2] UINT32 {0, 255, 0, 255}\n"
   VS_TRIANGLE_BODY
   "  6: MOV OUT[1], IMM[2]\n"
   "  7: END\n";

static const char *fs_flat_int =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[0], GENERIC[0], CONSTANT\n"
   "DCL OUT[0], COLOR\n"
   "DCL TEMP[0]\n"
   "IMM[0] FLT32 {    0.0039216,     0.0000,     0.0000,     0.0000}\n"
   "  0: U2F TEMP[0], IN[0]\n"
   "  1: MUL OUT[0], TEMP[0], IMM[0].xxxx\n"
   "  2: END\n";

/* the triangle, and green in two parts in a varying array */
static const char *vs_triangle_array =
   VS_TRIANGLE_HEAD
   "DCL OUT[1..2], ARRAY(1), GENERIC[0]\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "IMM[2] FLT32 {    0.0000,     1.0000,     0.0000,     0.0000}\n"
   VS_TRIANGLE_BODY
   "  6: MOV OUT[1], IMM[2].xyxx\n"
   "  7: MOV OUT[2], IMM[2].xxxy\n"
   "  8: END\n";

static const char *fs_array =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL IN[0..1], ARRAY(1), GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: ADD OUT[0], IN[0], IN[1]\n"
   "  1: END\n";

/* records (0.25, 0.5, 0.75, 1) per vertex (emit_xfb_shader) */
static const char *vs_xfb =
   "VERT\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "IMM[0] FLT32 {    0.2500,     0.5000,     0.7500,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0].xxxw\n"
   "  1: MOV OUT[1], IMM[0]\n"
   "  2: END\n";

/* vs_triangle and fs_varying as whole-program shaders */
static const char *vs_triangle_whole =
   "VERT\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   VS_TRIANGLE_BODY
   "  6: END\n";

static const char *fs_varying_whole =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

/* the sum of a 2D texture (red) and a cube texture (green) */
static const char *fs_two_samplers =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL OUT[0], COLOR\n"
   "DCL SAMP[0]\n"
   "DCL SAMP[1]\n"
   "DCL SVIEW[0], 2D, FLOAT\n"
   "DCL SVIEW[1], CUBE, FLOAT\n"
   "DCL TEMP[0..2]\n"
   "IMM[0] FLT32 {    0.5000,     0.5000,     1.0000,     0.0000}\n"
   "  0: MOV TEMP[0], IMM[0]\n"
   "  1: TEX TEMP[1], TEMP[0], SAMP[0], 2D\n"
   "  2: TEX TEMP[2], TEMP[0].zxyw, SAMP[1], CUBE\n"
   "  3: ADD OUT[0], TEMP[1], TEMP[2]\n"
   "  4: END\n";

/* clear grey, create and bind the shaders (handle, type, text; handle 0 ends), one draw */
struct stage {
   uint32_t handle, type;
   const char *text;
};

static uint32_t draw_pipeline_in(int ctx_id, const struct stage *stages, uint32_t mode,
                                 uint32_t count, int x, int y)
{
   struct cmds c = { .n = 0 };
   emit_clear_grey(&c);
   for (const struct stage *s = stages; s->handle; s++) {
      emit_shader(&c, s->handle, s->type, s->text);
      emit_bind(&c, s->handle, s->type);
   }
   emit_draw(&c, mode, count);
   if (submit(ctx_id, &c))
      return ~0u;
   uint32_t pixel = read_pixel_in(ctx_id, x, y);
   /* unbind them again (each row binds only the stages it has) */
   for (const struct stage *s = stages; s->handle; s++)
      emit_bind(&c, 0, s->type);
   submit(ctx_id, &c);
   return pixel;
}

static void row(const char *what, const struct stage *stages, uint32_t mode, uint32_t count,
                int x, int y, uint32_t want)
{
   char text[200];
   int refused = refused_lines, errors = ctx_error_lines, invalid = invalid_lines;
   uint32_t got = draw_pipeline_in(1, stages, mode, count, x, y);
   snprintf(text, sizeof(text), "%s: drawn (0x%08x, want 0x%08x)", what, got, want);
   check(got == want, text);
   snprintf(text, sizeof(text), "%s: no shader refused, no context error, valid", what);
   check(refused_lines == refused && ctx_error_lines == errors && invalid_lines == invalid,
         text);
}

/* Transform feedback from a separable vertex shader: three points record OUT[1]. */
static void xfb_row(void)
{
   struct virgl_renderer_resource_create_args args = {
      .handle = R_XFB, .target = BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_STREAM_OUTPUT, .width = 4096, .height = 1, .depth = 1,
      .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "transform feedback: buffer");
   virgl_renderer_ctx_attach_resource(1, R_XFB);
   int refused = refused_lines, errors = ctx_error_lines, invalid = invalid_lines;
   struct cmds c = { .n = 0 };
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_STREAMOUT_TARGET,
                       VIRGL_OBJ_STREAMOUT_SIZE));
   emit(&c, 95);
   emit(&c, R_XFB);
   emit(&c, 0);                     /* offset */
   emit(&c, 4096);                  /* size */
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 2));
   emit(&c, 0);                     /* append bitmask */
   emit(&c, 95);
   emit_xfb_shader(&c, 96, vs_xfb);
   emit_bind(&c, 96, SHADER_VERTEX);
   emit_shader(&c, 97, SHADER_FRAGMENT, fs_varying);
   emit_bind(&c, 97, SHADER_FRAGMENT);
   emit_draw(&c, PRIM_POINTS, 3);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 1));
   emit(&c, 0);
   emit_bind(&c, 0, SHADER_VERTEX);
   emit_bind(&c, 0, SHADER_FRAGMENT);
   check(submit(1, &c) == 0, "transform feedback: the submit runs");
   float got[12] = { 0 };
   struct iovec iov = { got, sizeof(got) };
   struct virgl_box box = { 0, 0, 0, sizeof(got), 1, 1 };
   int r = virgl_renderer_transfer_read_iov(R_XFB, 1, 0, 0, 0, &box, 0, &iov, 1);
   int same = r == 0;
   for (int i = 0; i < 12; i++)
      same &= got[i] == 0.25f * (i % 4 + 1);
   char text[200];
   snprintf(text, sizeof(text), "transform feedback from a separable vertex shader: "
            "recorded (%.2f %.2f %.2f %.2f ...)", got[0], got[1], got[2], got[3]);
   check(same, text);
   check(refused_lines == refused && ctx_error_lines == errors && invalid_lines == invalid,
         "transform feedback: no shader refused, no context error, valid");
   virgl_renderer_ctx_detach_resource(1, R_XFB);
   virgl_renderer_resource_unref(R_XFB);
}

/* A 1x1 2D texture (red) and a 1x1 cube texture (green on every face). */
static void create_textures(void)
{
   struct virgl_renderer_resource_create_args tex = {
      .handle = R_TEX_2D, .target = TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_SAMPLER_VIEW, .width = 1, .height = 1, .depth = 1, .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&tex, NULL, 0), "samplers: 2D texture");
   tex.handle = R_TEX_CUBE;
   tex.target = TEXTURE_CUBE;
   tex.array_size = 6;
   check(!virgl_renderer_resource_create(&tex, NULL, 0), "samplers: cube texture");
   uint32_t red = RED, green = GREEN;
   struct iovec iov = { &red, 4 };
   struct virgl_box box = { 0, 0, 0, 1, 1, 1 };
   int r = virgl_renderer_transfer_write_iov(R_TEX_2D, 0, 0, 4, 4, &box, 0, &iov, 1);
   iov.iov_base = &green;
   for (int face = 0; face < 6; face++) {
      box.z = face;
      r |= virgl_renderer_transfer_write_iov(R_TEX_CUBE, 0, 0, 4, 4, &box, 0, &iov, 1);
   }
   check(r == 0, "samplers: texels written");
}

/* the textures' views and a sampler state for the fragment shader, in a context */
static void emit_samplers(struct cmds *c)
{
   static const uint32_t views[2][3] = {
      { 81, R_TEX_2D, TEXTURE_2D }, { 82, R_TEX_CUBE, TEXTURE_CUBE } };
   for (int i = 0; i < 2; i++) {
      emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_VIEW,
                         VIRGL_OBJ_SAMPLER_VIEW_SIZE));
      emit(c, views[i][0]);
      emit(c, views[i][1]);
      emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM | views[i][2] << 24);
      emit(c, views[i][2] == TEXTURE_CUBE ? 5 << 16 : 0);   /* layers */
      emit(c, 0);                                            /* levels 0..0 */
      emit(c, 0 | 1 << 3 | 2 << 6 | 3 << 9);                 /* identity swizzle */
   }
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_SAMPLER_VIEWS, 0, VIRGL_SET_SAMPLER_VIEWS_SIZE(2)));
   emit(c, SHADER_FRAGMENT);
   emit(c, 0);
   emit(c, 81);
   emit(c, 82);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_STATE,
                      VIRGL_OBJ_SAMPLER_STATE_SIZE));
   emit(c, 83);
   emit(c, VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_S(2) | VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_T(2) |
           VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_R(2) | VIRGL_OBJ_SAMPLE_STATE_S0_MIN_MIP_FILTER(2));
   emit_float(c, 0);                /* lod bias, min and max lod */
   emit_float(c, 0);
   emit_float(c, 0);
   for (int i = 0; i < 4; i++)
      emit(c, 0);                   /* border colour */
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SAMPLER_STATES, 0, 4));
   emit(c, SHADER_FRAGMENT);
   emit(c, 0);
   emit(c, 83);
   emit(c, 83);
}

/* A context with the colour buffer, the textures and their views (contexts 2 and 3). */
static void new_context(int ctx_id, const char *name)
{
   check(!virgl_renderer_context_create(ctx_id, strlen(name), name), name);
   virgl_renderer_ctx_attach_resource(ctx_id, R_COLOUR);
   virgl_renderer_ctx_attach_resource(ctx_id, R_TEX_2D);
   virgl_renderer_ctx_attach_resource(ctx_id, R_TEX_CUBE);
   struct cmds c = { .n = 0 };
   emit_setup(&c);
   emit_samplers(&c);
   check(submit(ctx_id, &c) == 0, "new context: framebuffer and samplers");
}

static void end_context(int ctx_id)
{
   virgl_renderer_ctx_detach_resource(ctx_id, R_COLOUR);
   virgl_renderer_ctx_detach_resource(ctx_id, R_TEX_2D);
   virgl_renderer_ctx_detach_resource(ctx_id, R_TEX_CUBE);
   virgl_renderer_context_destroy(ctx_id);
}

/* A new separable pipeline with a 2D and a cube sampler (fragment shader handle fs): it
 * fails the GL's validation at its first draw (both samplers on unit 0 then). */
static void samplers_row(int ctx_id, uint32_t fs, const char *what, int lose)
{
   char text[200];
   int errors = ctx_error_lines, invalid = invalid_lines, lost = pipeline_error_lines;
   uint32_t got = draw_pipeline_in(ctx_id, (const struct stage[]){
                                      { fs - 1, SHADER_VERTEX, vs_triangle },
                                      { fs, SHADER_FRAGMENT, fs_two_samplers }, { 0 } },
                                   PRIM_TRIANGLES, 3, 8, 8);
   if (lose) {
      snprintf(text, sizeof(text), "%s, failures 'lose': the pipeline's context error "
               "(as upstream)", what);
      check(pipeline_error_lines == lost + 1, text);
      return;
   }
   snprintf(text, sizeof(text), "%s: drawn (0x%08x, want 0x%08x)", what, got, YELLOW);
   check(got == YELLOW, text);
   snprintf(text, sizeof(text), "%s: no context error", what);
   check(ctx_error_lines == errors, text);
   snprintf(text, sizeof(text), "%s: the failed validation is logged", what);
   check(invalid_lines == invalid + 1 && invalid_ctx == ctx_id, text);
}

/* Shapes Apple's GL still refuses as separable programs, in their own context (one refused
 * shader is enough to lose a context with "lose"). vrend gives a patch varying a layout
 * location, and Apple's GL refuses every location on a patch variable (0 to 31; without
 * one it links); it puts a varying array at location 31 - its first, so the array runs
 * past the last location. */
static void refused_row(const char *what, const struct stage *stages, uint32_t mode)
{
   char text[200];
   int refused = refused_lines, errors = ctx_error_lines;
   uint32_t got = draw_pipeline_in(4, stages, mode, 3, 8, 8);
   snprintf(text, sizeof(text), "%s: refused and its draw skipped (0x%08x)", what, got);
   check(got == GREY && refused_lines > refused, text);
   snprintf(text, sizeof(text), "%s: no context error", what);
   check(ctx_error_lines == errors, text);
}

static void refused_rows(void)
{
   new_context(4, "refused");
   refused_row("still refused: a patch varying", (const struct stage[]){
                  { 130, SHADER_VERTEX, vs_triangle }, { 131, SHADER_TESS_CTRL, tcs_patch },
                  { 132, SHADER_TESS_EVAL, tes_patch }, { 133, SHADER_FRAGMENT, fs_varying },
                  { 0 } }, PRIM_PATCHES);
   refused_row("still refused: a varying array", (const struct stage[]){
                  { 134, SHADER_VERTEX, vs_triangle_array },
                  { 135, SHADER_FRAGMENT, fs_array }, { 0 } }, PRIM_TRIANGLES);
   uint32_t got = draw_pipeline_in(4, (const struct stage[]){
                                      { 136, SHADER_VERTEX, vs_triangle_green },
                                      { 137, SHADER_FRAGMENT, fs_varying }, { 0 } },
                                   PRIM_TRIANGLES, 3, 8, 8);
   check(got == GREEN, "still refused: the context draws on (green)");
   end_context(4);
}

/* A context logs three failed validations; another context logs its own. */
static void log_budget(void)
{
   int invalid = invalid_lines;
   for (int i = 0; i < 3; i++) {
      draw_pipeline_in(1, (const struct stage[]){
                          { 110 + 2 * i, SHADER_VERTEX, vs_triangle },
                          { 111 + 2 * i, SHADER_FRAGMENT, fs_two_samplers }, { 0 } },
                       PRIM_TRIANGLES, 3, 8, 8);
   }
   /* context 1 had two lines before (the samplers and the incomplete framebuffer) */
   check(invalid_lines == invalid + 1, "log budget: a context logs three failed validations");
   new_context(3, "budget");
   samplers_row(3, 121, "log budget: another context logs its own", 0);
   end_context(3);
}

/* A new separable pipeline whose first draw has an incomplete framebuffer (a second colour
 * buffer with 4 samples): Apple's pipeline validation fails there. */
static void incomplete_framebuffer(int lose)
{
   struct virgl_renderer_resource_create_args msaa = {
      .handle = R_MSAA, .target = TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1,
      .array_size = 1, .nr_samples = 4,
   };
   check(!virgl_renderer_resource_create(&msaa, NULL, 0), "incomplete framebuffer: 4-sample buffer");
   virgl_renderer_ctx_attach_resource(1, R_MSAA);
   struct cmds c = { .n = 0 };
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(&c, 8);
   emit(&c, R_MSAA);
   emit(&c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(&c, 0);
   emit(&c, 0);
   emit_clear_grey(&c);
   emit_framebuffer(&c, 2, (const uint32_t[]){ 6, 8 });
   emit_shader(&c, 90, SHADER_VERTEX, vs_triangle_green);
   emit_bind(&c, 90, SHADER_VERTEX);
   emit_shader(&c, 91, SHADER_FRAGMENT, fs_varying);
   emit_bind(&c, 91, SHADER_FRAGMENT);
   emit_draw(&c, PRIM_TRIANGLES, 3);
   int errors = ctx_error_lines, invalid = invalid_lines, lost = pipeline_error_lines;
   int r = submit(1, &c);
   if (lose) {
      check(pipeline_error_lines == lost + 1,
            "incomplete framebuffer, failures 'lose': the pipeline's context error (as upstream)");
      virgl_renderer_ctx_detach_resource(1, R_MSAA);
      virgl_renderer_resource_unref(R_MSAA);
      return;
   }
   check(r == 0, "incomplete framebuffer: the submit runs");
   check(ctx_error_lines == errors, "incomplete framebuffer: no context error");
   check(invalid_lines == invalid + 1, "incomplete framebuffer: the failed validation is logged");

   emit_framebuffer(&c, 1, (const uint32_t[]){ 6 });
   emit_clear_grey(&c);
   emit_draw(&c, PRIM_TRIANGLES, 3);
   check(submit(1, &c) == 0 && read_pixel(8, 8) == GREEN,
         "incomplete framebuffer: the next draw with a complete one draws (green)");
   virgl_renderer_ctx_detach_resource(1, R_MSAA);
   virgl_renderer_resource_unref(R_MSAA);
}

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   virgl_set_log_callback(count_log, NULL, NULL);
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   check(!virgl_renderer_context_create(1, strlen("separable"), "separable"), "context");
   struct virgl_renderer_resource_create_args args = {
      .handle = R_COLOUR, .target = TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1,
      .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "colour buffer");
   virgl_renderer_ctx_attach_resource(1, R_COLOUR);
   create_textures();
   virgl_renderer_ctx_attach_resource(1, R_TEX_2D);
   virgl_renderer_ctx_attach_resource(1, R_TEX_CUBE);
   struct cmds c = { .n = 0 };
   emit_setup(&c);
   emit_samplers(&c);
   check(submit(1, &c) == 0, "framebuffer");

   row("vertex + fragment, a varying", (const struct stage[]){
          { 10, SHADER_VERTEX, vs_triangle_green }, { 11, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, GREEN);

   emit_bind_rasterizer(&c, RS_POINTS);
   submit(1, &c);
   row("a vertex shader that writes gl_PointSize (16)", (const struct stage[]){
          { 20, SHADER_VERTEX, vs_point }, { 21, SHADER_FRAGMENT, fs_blue }, { 0 } },
       PRIM_POINTS, 1, 1, 1, BLUE);
   emit_bind_rasterizer(&c, RS_TRIANGLES);
   submit(1, &c);

   row("vertex + geometry + fragment", (const struct stage[]){
          { 30, SHADER_VERTEX, vs_triangle }, { 31, SHADER_GEOMETRY, gs_yellow },
          { 32, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, YELLOW);

   row("vertex + tessellation + fragment", (const struct stage[]){
          { 40, SHADER_VERTEX, vs_triangle }, { 41, SHADER_TESS_CTRL, tcs_pass },
          { 42, SHADER_TESS_EVAL, tes_magenta }, { 43, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_PATCHES, 3, 8, 8, MAGENTA);

   row("vertex + tessellation + geometry + fragment", (const struct stage[]){
          { 50, SHADER_VERTEX, vs_triangle }, { 51, SHADER_TESS_CTRL, tcs_pass },
          { 52, SHADER_TESS_EVAL, tes_cyan }, { 53, SHADER_GEOMETRY, gs_pass },
          { 54, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_PATCHES, 3, 8, 8, CYAN);

   row("vertex (gl_PointSize) + geometry (gl_Position only) + fragment", (const struct stage[]){
          { 60, SHADER_VERTEX, vs_triangle_psize }, { 61, SHADER_GEOMETRY, gs_yellow },
          { 62, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, YELLOW);

   row("a geometry shader that reads gl_in[].gl_PointSize", (const struct stage[]){
          { 63, SHADER_VERTEX, vs_triangle_psize }, { 64, SHADER_GEOMETRY, gs_psize },
          { 65, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, YELLOW);

   row("a geometry shader with clip distances", (const struct stage[]){
          { 66, SHADER_VERTEX, vs_triangle }, { 67, SHADER_GEOMETRY, gs_clip },
          { 68, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, YELLOW);

   row("tessellation shaders that pass clip distances on", (const struct stage[]){
          { 69, SHADER_VERTEX, vs_triangle }, { 70, SHADER_TESS_CTRL, tcs_clip },
          { 71, SHADER_TESS_EVAL, tes_clip }, { 72, SHADER_FRAGMENT, fs_varying }, { 0 } },
       PRIM_PATCHES, 3, 8, 8, MAGENTA);

   row("a flat integer varying", (const struct stage[]){
          { 77, SHADER_VERTEX, vs_triangle_int }, { 78, SHADER_FRAGMENT, fs_flat_int }, { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, GREEN);

   row("one program: whole vertex + separable geometry + whole fragment",
       (const struct stage[]){
          { 84, SHADER_VERTEX, vs_triangle_whole }, { 85, SHADER_GEOMETRY, gs_yellow },
          { 86, SHADER_FRAGMENT, fs_varying_whole }, { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, YELLOW);

   row("one program: separable vertex + whole fragment", (const struct stage[]){
          { 87, SHADER_VERTEX, vs_triangle_green }, { 88, SHADER_FRAGMENT, fs_varying_whole },
          { 0 } },
       PRIM_TRIANGLES, 3, 8, 8, GREEN);

   xfb_row();

   const char *policy = getenv("OMACVM_VIRGL_SHADER_FAILURES");
   int lose = policy && !strcmp(policy, "lose");
   if (lose) {
      new_context(2, "samplers");
      samplers_row(2, 101, "samplers: a 2D and a cube sampler in one fragment shader", 1);
      end_context(2);
      incomplete_framebuffer(1);
   } else {
      samplers_row(1, 101, "samplers: a 2D and a cube sampler in one fragment shader", 0);
      incomplete_framebuffer(0);
      log_budget();
      refused_rows();
   }

   virgl_renderer_ctx_detach_resource(1, R_COLOUR);
   virgl_renderer_ctx_detach_resource(1, R_TEX_2D);
   virgl_renderer_ctx_detach_resource(1, R_TEX_CUBE);
   virgl_renderer_context_destroy(1);
   virgl_renderer_resource_unref(R_COLOUR);
   virgl_renderer_resource_unref(R_TEX_2D);
   virgl_renderer_resource_unref(R_TEX_CUBE);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "separable pervertex: FAILED" :
          "separable pervertex: all checks passed");
   return failures != 0;
}
