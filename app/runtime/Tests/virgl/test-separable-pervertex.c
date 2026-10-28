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
 * and no shader is refused, no context error. */
#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

enum { SHADER_VERTEX = 0, SHADER_FRAGMENT = 1, SHADER_GEOMETRY = 2, SHADER_TESS_CTRL = 3,
       SHADER_TESS_EVAL = 4 };
enum { PRIM_POINTS = 0, PRIM_TRIANGLES = 4, PRIM_PATCHES = 14, TEXTURE_2D = 2,
       CLEAR_COLOR0 = 1 << 2 };
enum { GREEN = 0xff00ff00, BLUE = 0xffff0000, YELLOW = 0xff00ffff, MAGENTA = 0xffff00ff,
       CYAN = 0xffffff00 };
enum { RS_TRIANGLES = 41, RS_POINTS = 42 };

static CGLContextObj main_ctx;
static int failures, refused_lines, ctx_error_lines;

static void count_log(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)level;
   (void)data;
   /* "refused" is logged at most three times per context, the GL's own lines every time */
   refused_lines += strstr(message, "refused a shader") || strstr(message, "Error linking") ||
                    strstr(message, "failed to compile");
   ctx_error_lines += strstr(message, "context error reported") != NULL;
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

static uint32_t read_pixel(int x, int y)
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   if (virgl_renderer_transfer_read_iov(5, 1, 0, 16 * 4, 0, &box, 0, &iov, 1))
      return ~0u;
   return pixels[y * 16 + x];
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

/* clear grey, create and bind the shaders (handle, type, text; handle 0 ends), one draw */
struct stage {
   uint32_t handle, type;
   const char *text;
};

static uint32_t draw_pipeline(const struct stage *stages, uint32_t mode, uint32_t count,
                              int x, int y)
{
   struct cmds c = { .n = 0 };
   emit_clear_grey(&c);
   for (const struct stage *s = stages; s->handle; s++) {
      emit_shader(&c, s->handle, s->type, s->text);
      emit_bind(&c, s->handle, s->type);
   }
   emit_draw(&c, mode, count);
   if (submit(1, &c))
      return ~0u;
   uint32_t pixel = read_pixel(x, y);
   /* unbind them again (each row binds only the stages it has) */
   for (const struct stage *s = stages; s->handle; s++)
      emit_bind(&c, 0, s->type);
   submit(1, &c);
   return pixel;
}

static void row(const char *what, const struct stage *stages, uint32_t mode, uint32_t count,
                int x, int y, uint32_t want)
{
   char text[200];
   int refused = refused_lines, errors = ctx_error_lines;
   uint32_t got = draw_pipeline(stages, mode, count, x, y);
   snprintf(text, sizeof(text), "%s: drawn (0x%08x, want 0x%08x)", what, got, want);
   check(got == want, text);
   snprintf(text, sizeof(text), "%s: no shader refused, no context error", what);
   check(refused_lines == refused && ctx_error_lines == errors, text);
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
   check(!virgl_renderer_context_create(1, 8, "separable"), "context");
   struct virgl_renderer_resource_create_args args = {
      .handle = 5, .target = TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1,
      .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "colour buffer");
   virgl_renderer_ctx_attach_resource(1, 5);
   struct cmds c = { .n = 0 };
   emit_setup(&c);
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

   virgl_renderer_ctx_detach_resource(1, 5);
   virgl_renderer_context_destroy(1);
   virgl_renderer_resource_unref(5);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "separable pervertex: FAILED" :
          "separable pervertex: all checks passed");
   return failures != 0;
}
