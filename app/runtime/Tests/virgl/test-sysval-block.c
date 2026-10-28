/* A program whose VirglBlock the GL does not report as large as vrend's sysval block
 * (virgl-sysval-block-check.patch, #547), through the public renderer API on Apple's
 * software renderer (soft-gl.h). QEMU aborted on vrend's assert there once, right after
 * the Mac's GL had refused a shader of the same context (quickshell at desktop start).
 * sysval-block-gl.c (linked in) fails the GL's answer on demand:
 *  - the GL reports 16 bytes: the program is not used, its draws are skipped and
 *    logged as a refused link, the context lives (later submits run);
 *  - the query fails (a GL error, nothing written): the same;
 *  - then, the GL answering again: new shaders draw (green in the colour buffer), and a
 *    program that was refused stays refused (not linked again for every draw), as for
 *    other refused shaders;
 *  - a separable pipeline whose VirglBlock fails at a rebind (its shaders were used by
 *    another pipeline since): that draw is skipped, the next one binds again and draws.
 * Status queries that write nothing on such a GL (virgl-query-results-init.patch), in a
 * second context, with the stack filled first so an unset value shows:
 *  - a shader's compile status and info log: the "Shader failed to compile" line has an
 *    empty log, not stack bytes; the same for a program's link;
 *  - a pipeline's validate status: no ILLEGAL_PROGRAM_PIPELINE, the context draws on. */
#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

void sysval_block_fault(int mode);
unsigned long sysval_block_faults(void);
unsigned long sysval_block_draws(void);
unsigned long sysval_block_queries(void);
void gl_status_fault(int mode);
unsigned long gl_status_faults(void);

enum { TEST_SHADER_VERTEX = 0, TEST_SHADER_FRAGMENT = 1, TEST_PRIM_TRIANGLES = 4,
       TEST_TEXTURE_2D = 2, TEST_CLEAR_COLOR0 = 1 << 2 };
enum { GREEN = 0xff00ff00, BLUE = 0xffff0000, GREY = 0xff808080 };

static CGLContextObj main_ctx;
static int failures, refused_lines, block_lines, ctx_error_lines;
static char compile_line[256], link_line[256];

static void keep_first(char *dst, size_t size, const char *message, const char *start)
{
   if (!dst[0] && !strncmp(message, start, strlen(start)))
      snprintf(dst, size, "%s", message);
}

static void count_log(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)level;
   (void)data;
   refused_lines += strstr(message, "refused a shader (link)") != NULL;
   block_lines += strstr(message, "VirglBlock") != NULL;
   ctx_error_lines += strstr(message, "context error reported") != NULL;
   keep_first(compile_line, sizeof(compile_line), message, "Shader failed to compile");
   keep_first(link_line, sizeof(link_line), message, "Error linking program");
   fputs(message, stderr);
}

/* Fills the stack below main with one byte, so a value vrend leaves unset in a frame
 * there reads as that byte, not as whatever an earlier call left. */
static void __attribute__((noinline)) fill_stack(int byte)
{
   volatile char junk[512 * 1024];
   for (size_t i = 0; i < sizeof(junk); i++)
      junk[i] = (char)byte;
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
   uint32_t dw[1024];
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

static void emit_draw(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, 0);                      /* start */
   emit(c, 3);                      /* count */
   emit(c, TEST_PRIM_TRIANGLES);
   for (int i = 0; i < VIRGL_DRAW_VBO_SIZE - 3; i++)
      emit(c, 0);
}

static void emit_clear_grey(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, TEST_CLEAR_COLOR0);
   for (int i = 0; i < 3; i++)
      emit_float(c, 128.0f / 255.0f);
   emit_float(c, 1.0f);
   emit(c, 0);                      /* depth (double) */
   emit(c, 0);
   emit(c, 0);                      /* stencil */
}

/* surface on resource 5, framebuffer, 16x16 viewport, blend and rasterizer state */
static void emit_setup(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, 6);
   emit(c, 5);
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, 6);
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
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(c, 41);
   emit(c, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 2; i++)
      emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, 41);
}

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}

static uint32_t read_middle(void)
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   if (virgl_renderer_transfer_read_iov(5, 1, 0, 16 * 4, 0, &box, 0, &iov, 1))
      return ~0u;
   return pixels[8 * 16 + 8];
}

/* A triangle over the whole viewport from gl_VertexID; every vertex shader vrend makes
 * scales gl_Position.y by the VirglBlock's winsys_adjust_y, so every program has one. */
static const char *vs_text =
   "VERT\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "  0: AND TEMP[0].x, SV[0].xxxx, IMM[0].xxxx\n"
   "  1: AND TEMP[0].y, SV[0].xxxx, IMM[0].yyyy\n"
   "  2: USHR TEMP[0].y, TEMP[0].yyyy, IMM[0].xxxx\n"
   "  3: U2F TEMP[0].xy, TEMP[0].xyyy\n"
   "  4: MAD OUT[0].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: MOV OUT[0].zw, IMM[1].zzzw\n"
   "  6: END\n";

static const char *fs_green =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    0.0000,     1.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

/* The same as separable programs (vrend links each stage alone, into a pipeline). */
static const char *vs_separable =
   "VERT\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL TEMP[0]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "  0: AND TEMP[0].x, SV[0].xxxx, IMM[0].xxxx\n"
   "  1: AND TEMP[0].y, SV[0].xxxx, IMM[0].yyyy\n"
   "  2: USHR TEMP[0].y, TEMP[0].yyyy, IMM[0].xxxx\n"
   "  3: U2F TEMP[0].xy, TEMP[0].xyyy\n"
   "  4: MAD OUT[0].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: MOV OUT[0].zw, IMM[1].zzzw\n"
   "  6: END\n";

static const char *fs_separable_green =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    0.0000,     1.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

static const char *fs_separable_blue =
   "FRAG\n"
   "PROPERTY SEPARABLE_PROGRAM 1\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    0.0000,     0.0000,     1.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

/* new shader objects (so a new program), three draws, one submit */
static int draw_with_new_shaders_in(int ctx_id, struct cmds *c, uint32_t handle,
                                    const char *vs, const char *fs)
{
   emit_clear_grey(c);
   emit_shader(c, handle, TEST_SHADER_VERTEX, vs);
   emit_bind(c, handle, TEST_SHADER_VERTEX);
   emit_shader(c, handle + 1, TEST_SHADER_FRAGMENT, fs);
   emit_bind(c, handle + 1, TEST_SHADER_FRAGMENT);
   for (int i = 0; i < 3; i++)
      emit_draw(c);
   return submit(ctx_id, c);
}

static int draw_with_new_shaders(struct cmds *c, uint32_t handle)
{
   return draw_with_new_shaders_in(1, c, handle, vs_text, fs_green);
}

/* clear, bind the two shaders, one draw, one submit */
static int draw_with(int ctx_id, struct cmds *c, uint32_t vs, uint32_t fs)
{
   emit_clear_grey(c);
   emit_bind(c, vs, TEST_SHADER_VERTEX);
   emit_bind(c, fs, TEST_SHADER_FRAGMENT);
   emit_draw(c);
   return submit(ctx_id, c);
}

/* A separable pipeline's rebind (vrend_select_program): its shaders were bound into
 * another pipeline since, so vrend binds its blocks again, VirglBlock included. When the
 * GL's answer fails there, that draw is skipped and the pipeline stays usable: the next
 * draw binds again and draws. */
static void separable_rebind(struct cmds *c)
{
   emit_shader(c, 50, TEST_SHADER_VERTEX, vs_separable);
   emit_shader(c, 51, TEST_SHADER_FRAGMENT, fs_separable_green);
   emit_shader(c, 52, TEST_SHADER_FRAGMENT, fs_separable_blue);
   check(submit(1, c) == 0, "separable: shaders");
   unsigned long draws = sysval_block_draws(), queries = sysval_block_queries();
   refused_lines = 0;
   check(draw_with(1, c, 50, 51) == 0 && sysval_block_draws() == draws + 1 &&
         sysval_block_queries() > queries && refused_lines == 0 && read_middle() == GREEN,
         "separable: the first pipeline links, binds its VirglBlock and draws (green)");
   check(draw_with(1, c, 50, 52) == 0 && sysval_block_draws() == draws + 2 &&
         read_middle() == BLUE, "separable: a second pipeline with the same vertex shader (blue)");

   unsigned long faults = sysval_block_faults();
   sysval_block_fault(2);
   int r = draw_with(1, c, 50, 51);
   sysval_block_fault(0);
   check(r == 0 && sysval_block_faults() > faults,
         "separable: back to the first pipeline, its rebind gets 16 bytes: no abort");
   check(sysval_block_draws() == draws + 2 && read_middle() == GREY,
         "separable: that draw is skipped");
   check(refused_lines == 0, "separable: not refused as a link (the pipeline stays)");

   queries = sysval_block_queries();
   emit_clear_grey(c);
   emit_draw(c);
   check(submit(1, c) == 0 && sysval_block_queries() > queries,
         "separable: the next draw binds the pipeline's blocks again");
   check(sysval_block_draws() == draws + 3 && read_middle() == GREEN,
         "separable: and draws (green)");
}

/* Status queries that write nothing, in their own context (a context logs the details
 * only of its first refused shader). */
static void unwritten_status(void)
{
   check(!virgl_renderer_context_create(2, 6, "statusq"), "status queries: context");
   virgl_renderer_ctx_attach_resource(2, 5);
   struct cmds c = { .n = 0 };
   emit_setup(&c);
   check(submit(2, &c) == 0, "status queries: framebuffer");

   unsigned long faults = gl_status_faults(), draws = sysval_block_draws();
   gl_status_fault(1);
   fill_stack('X');
   int r = draw_with_new_shaders_in(2, &c, 10, vs_text, fs_green);
   gl_status_fault(0);
   check(r == 0 && gl_status_faults() > faults && sysval_block_draws() == draws,
         "compile status unwritten: taken as a failed compile, no draw");
   check(!strcmp(compile_line, "Shader failed to compile\n\n"),
         "compile status unwritten: \"Shader failed to compile\" with an empty log");

   faults = gl_status_faults();
   gl_status_fault(3);
   fill_stack('X');
   r = draw_with_new_shaders_in(2, &c, 20, vs_text, fs_green);
   gl_status_fault(0);
   check(r == 0 && gl_status_faults() > faults && sysval_block_draws() == draws,
         "link status unwritten: taken as a failed link, no draw");
   check(!strcmp(link_line, "Error linking program:\n\n"),
         "link status unwritten: \"Error linking program\" with an empty log");

   faults = gl_status_faults();
   ctx_error_lines = 0;
   gl_status_fault(2);
   fill_stack(0);
   r = draw_with_new_shaders_in(2, &c, 30, vs_separable, fs_separable_green);
   gl_status_fault(0);
   check(gl_status_faults() > faults, "validate status unwritten: the pipeline was validated");
   check(r == 0 && ctx_error_lines == 0,
         "validate status unwritten: no context error (ILLEGAL_PROGRAM_PIPELINE)");
   check(sysval_block_draws() == draws + 3 && read_middle() == GREEN,
         "validate status unwritten: the pipeline draws (green)");

   virgl_renderer_ctx_detach_resource(2, 5);
   virgl_renderer_context_destroy(2);
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
   check(!virgl_renderer_context_create(1, 10, "quickshell"), "context");
   struct virgl_renderer_resource_create_args args = {
      .handle = 5, .target = TEST_TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1,
      .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "colour buffer");
   virgl_renderer_ctx_attach_resource(1, 5);
   struct cmds c = { .n = 0 };
   emit_setup(&c);
   check(submit(1, &c) == 0, "framebuffer");

   /* 16 bytes first: before the fix that aborted for sure (the failed query left an
    * uninitialized size, which may or may not have passed the assert) */
   static const char *what[] = { NULL, "the GL's query fails", "the GL reports 16 bytes" };
   for (int mode = 2; mode >= 1; mode--) {
      char text[160];
      unsigned long faults = sysval_block_faults(), draws = sysval_block_draws();
      refused_lines = block_lines = 0;
      sysval_block_fault(mode);
      int r = draw_with_new_shaders(&c, 10 * mode);
      sysval_block_fault(0);
      snprintf(text, sizeof(text), "%s: the submit runs (no abort)", what[mode]);
      check(r == 0 && sysval_block_faults() > faults, text);
      snprintf(text, sizeof(text), "%s: no draw reaches the GL", what[mode]);
      check(sysval_block_draws() == draws, text);
      snprintf(text, sizeof(text), "%s: one refused link and one VirglBlock line",
               what[mode]);
      check(refused_lines == 1 && block_lines == 1, text);
      check(read_middle() == GREY, "the colour buffer keeps its clear colour");
   }

   /* The GL answers again: a new program draws; a refused one stays refused. */
   unsigned long draws = sysval_block_draws();
   check(draw_with_new_shaders(&c, 30) == 0 && sysval_block_draws() == draws + 3,
         "the context lives: new shaders draw");
   check(read_middle() == GREEN, "and the draws are seen (green)");
   unsigned long faults = sysval_block_faults();
   refused_lines = 0;
   emit_clear_grey(&c);
   emit_bind(&c, 20, TEST_SHADER_VERTEX);
   emit_bind(&c, 21, TEST_SHADER_FRAGMENT);
   for (int i = 0; i < 5; i++)
      emit_draw(&c);
   check(submit(1, &c) == 0 && sysval_block_draws() == draws + 3 &&
         sysval_block_faults() == faults && read_middle() == GREY,
         "the refused program is not linked again, its draws stay skipped");

   separable_rebind(&c);
   unwritten_status();

   virgl_renderer_ctx_detach_resource(1, 5);
   virgl_renderer_context_destroy(1);
   virgl_renderer_resource_unref(5);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "sysval block: FAILED" : "sysval block: all checks passed");
   return failures != 0;
}
