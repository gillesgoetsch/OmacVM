/* What a guest context sees when the Mac side cannot run its work, through the
 * public renderer API on the Mac's own OpenGL (CGL core contexts, no window):
 *  - a shader program the host GL refuses (here: more uniforms than Apple's limit,
 *    the guest's Mesa would not send that, the test does) skips its draws and the
 *    context keeps working: later commands run, the status buffer stays 0;
 *  - a fatal error (a framebuffer with a surface that does not exist) loses the
 *    context: the guest's status buffer reads VIRGL_RESET_STATUS_GUILTY, its later
 *    commands are refused, and a second context keeps working;
 *  - a shader vrend cannot translate to GLSL (a property it does not know) is
 *    treated the same way: its draws are skipped, the context lives;
 *  - a refused program is not linked again on every draw, also with dual-source
 *    blending on and one fragment output, and its skipped draws log one line. */
#include <OpenGL/OpenGL.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

/* Gallium values the protocol uses (pipe/p_defines.h needs the whole tree). */
enum { TEST_PIPE_BUFFER = 0, TEST_SHADER_VERTEX = 0, TEST_SHADER_FRAGMENT = 1,
       TEST_PRIM_TRIANGLES = 4 };

static CGLContextObj main_ctx;
static int failures;
static int refused_lines, dropped_lines;

static void count_log(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)level;
   (void)data;
   refused_lines += strstr(message, "refused a shader") != NULL;
   dropped_lines += strstr(message, "Dropping rendering") != NULL;
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

static CGLContextObj new_context(CGLContextObj share)
{
   return soft_gl_context(share);
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
   /* QEMU (ui/cocoa) shares every context with its view's context, the first one too. */
   return new_context(main_ctx);
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
   uint32_t dw[4096];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v)
{
   c->dw[c->n++] = v;
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

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}

static const char *vs_text =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

/* Blend with the second source colour: dual-source blending. */
static void emit_dual_source_blend(struct cmds *c, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_BLEND, VIRGL_OBJ_BLEND_SIZE));
   emit(c, handle);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_OBJ_BLEND_S2_RT_BLEND_ENABLE(1) |
           VIRGL_OBJ_BLEND_S2_RT_RGB_SRC_FACTOR(1 /* ONE */) |
           VIRGL_OBJ_BLEND_S2_RT_RGB_DST_FACTOR(9 /* SRC1_COLOR */) |
           VIRGL_OBJ_BLEND_S2_RT_ALPHA_SRC_FACTOR(1) |
           VIRGL_OBJ_BLEND_S2_RT_ALPHA_DST_FACTOR(1) |
           VIRGL_OBJ_BLEND_S2_RT_COLORMASK(0xf));
   for (int i = 1; i < VIRGL_MAX_COLOR_BUFS; i++)
      emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_BLEND, 1));
   emit(c, handle);
}

/* 4096 vec4 uniforms with an indirect read: Apple's GL links at most 4096
 * components, so the program fails to link on the Mac. */
static const char *fs_too_many_uniforms =
   "FRAG\n"
   "PROPERTY FS_COLOR0_WRITES_ALL_CBUFS 1\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[0][0..4095]\n"
   "DCL ADDR[0]\n"
   "DCL TEMP[0]\n"
   "  0: ARL ADDR[0].x, IN[0].xxxx\n"
   "  1: MOV OUT[0], CONST[0][ADDR[0].x]\n"
   "  2: END\n";

/* A property vrend's TGSI -> GLSL translator does not handle. */
static const char *fs_untranslatable =
   "FRAG\n"
   "PROPERTY FS_POST_DEPTH_COVERAGE 1\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = new_context(NULL);
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

   uint32_t max_ver = 0, max_size = 0;
   virgl_renderer_get_cap_set(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, max_ver, caps);
   check(caps->v2.capability_bits_v2 & VIRGL_CAP_V2_RESET_STATUS_BUFFER,
         "capset offers the reset status buffer");

   check(!virgl_renderer_context_create(1, 8, "lost-app") &&
         !virgl_renderer_context_create(2, 9, "other-app"), "two contexts");

   /* The guest's status buffer: guest memory, no GL object (like query results). */
   uint32_t *status = calloc(1, 64);
   struct iovec iov = { status, 64 };
   struct virgl_renderer_resource_create_args args = {
      .handle = 7, .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_CUSTOM, .width = 64, .height = 1, .depth = 1, .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0) &&
         !virgl_renderer_resource_attach_iov(7, &iov, 1), "status buffer created");
   virgl_renderer_ctx_attach_resource(1, 7);

   struct cmds c = { .n = 0 };
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0, VIRGL_SET_RESET_STATUS_BUFFER_SIZE));
   emit(&c, 7);
   check(submit(1, &c) == 0 && status[0] == 0, "status buffer registered, reads 0");

   /* A program the Mac's GL refuses: its draws are skipped, nothing else. */
   emit_shader(&c, 20, TEST_SHADER_VERTEX, vs_text);
   emit_shader(&c, 21, TEST_SHADER_FRAGMENT, fs_too_many_uniforms);
   emit_draw(&c);
   emit_draw(&c);
   check(submit(1, &c) == 0, "draws with a refused program are accepted (skipped)");
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0, VIRGL_SET_RESET_STATUS_BUFFER_SIZE));
   emit(&c, 7);
   check(submit(1, &c) == 0 && status[0] == 0, "context still alive after the refused program");

   /* A fatal error: a colour buffer surface that was never created. */
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(&c, 1);
   emit(&c, 0);
   emit(&c, 77);
   submit(1, &c);
   check(status[0] == VIRGL_RESET_STATUS_GUILTY, "the guest's status buffer says the context is lost");
   emit_draw(&c);
   check(submit(1, &c) != 0, "the lost context refuses later draws");

   /* The other context does not care. */
   emit_shader(&c, 30, TEST_SHADER_VERTEX, vs_text);
   check(submit(2, &c) == 0, "another context keeps working");

   /* A status buffer must be guest memory, never a GL buffer. */
   struct virgl_renderer_resource_create_args gl_args = args;
   gl_args.handle = 8;
   gl_args.bind = VIRGL_BIND_VERTEX_BUFFER;
   uint32_t *other = calloc(1, 64);
   struct iovec other_iov = { other, 64 };
   virgl_renderer_resource_create(&gl_args, NULL, 0);
   virgl_renderer_resource_attach_iov(8, &other_iov, 1);
   virgl_renderer_ctx_attach_resource(2, 8);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0, VIRGL_SET_RESET_STATUS_BUFFER_SIZE));
   emit(&c, 8);
   submit(2, &c);
   emit_draw(&c);
   check(submit(2, &c) != 0, "a GL vertex buffer is refused as status buffer (fatal)");

   /* Dual-source blending on, one fragment output: the program fails to link once,
    * the memo keeps it from being linked again on each of the 20 draws. */
   check(!virgl_renderer_context_create(3, 9, "dual-app"), "third context");
   refused_lines = dropped_lines = 0;
   emit_dual_source_blend(&c, 40);
   emit_shader(&c, 41, TEST_SHADER_VERTEX, vs_text);
   emit_shader(&c, 42, TEST_SHADER_FRAGMENT, fs_too_many_uniforms);
   for (int i = 0; i < 20; i++)
      emit_draw(&c);
   check(submit(3, &c) == 0, "20 draws with a refused program and dual-source blending");
   printf("log lines: %d refused, %d dropped\n", refused_lines, dropped_lines);
   check(refused_lines == 1 && dropped_lines == 1,
         "linked once, one refused line and one dropped-draws line");
   virgl_renderer_context_destroy(3);

   /* A translation gap is contained like a refused compile. */
   check(!virgl_renderer_context_create(4, 12, "untranslated"), "fourth context");
   virgl_renderer_ctx_attach_resource(4, 7);
   refused_lines = dropped_lines = 0;
   status[0] = 0;
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0, VIRGL_SET_RESET_STATUS_BUFFER_SIZE));
   emit(&c, 7);
   emit_shader(&c, 51, TEST_SHADER_VERTEX, vs_text);
   emit_shader(&c, 52, TEST_SHADER_FRAGMENT, fs_untranslatable);
   for (int i = 0; i < 5; i++)
      emit_draw(&c);
   /* Translated once at creation and once for the draw's variant key. */
   check(submit(4, &c) == 0 && refused_lines == 2 && dropped_lines == 1,
         "an untranslatable shader is accepted, its draws skipped, no line per draw");
   emit_shader(&c, 53, TEST_SHADER_VERTEX, vs_text);
   check(submit(4, &c) == 0 && status[0] == 0, "the context is still alive");
   virgl_renderer_ctx_detach_resource(4, 7);
   virgl_renderer_context_destroy(4);

   virgl_renderer_ctx_detach_resource(1, 7);
   virgl_renderer_ctx_detach_resource(2, 8);
   virgl_renderer_resource_detach_iov(7, NULL, NULL);
   virgl_renderer_resource_detach_iov(8, NULL, NULL);
   virgl_renderer_context_destroy(1);
   virgl_renderer_context_destroy(2);
   virgl_renderer_resource_unref(7);
   virgl_renderer_resource_unref(8);
   virgl_renderer_cleanup(&cookie);
   free(status);
   free(other);
   free(caps);
   printf("%s\n", failures ? "context loss: FAILED" : "context loss: all checks passed");
   return failures != 0;
}
