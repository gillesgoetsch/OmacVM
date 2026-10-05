/* Transform feedback teardown orders a guest can send, through the public renderer
 * API on the Mac's own OpenGL (CGL core contexts, no window). Each case records
 * into a stream-output target, ends transform feedback the way Mesa's virgl driver
 * does (it unbinds the targets; the host keeps the GL object paused), then destroys
 * things in an order a guest app may choose. Apple's GL crashed QEMU in
 * glEndTransformFeedback for some of these (dEQP-GLES3.functional.transform_feedback.*,
 * WebGL 2 conformance2/transform_feedback). Every case must return, and the context
 * must keep working afterwards.
 * Usage: test-transform-feedback [case]   (no argument: all cases) */
#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

enum { TEST_QUERY_PRIMITIVES_GENERATED = 5, TEST_QUERY_PRIMITIVES_EMITTED = 6 };
enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2, TEST_SHADER_VERTEX = 0,
       TEST_SHADER_FRAGMENT = 1,
       TEST_PRIM_POINTS = 0, TEST_PRIM_TRIANGLES = 4 };

static CGLContextObj main_ctx;
static int failures;

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

static void emit_text(struct cmds *c, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], text, bytes);
   c->n += words;
}

static uint32_t text_words(const char *text)
{
   return (strlen(text) + 1 + 3) / 4;
}

static void emit_bind_shader(struct cmds *c, uint32_t handle, uint32_t type)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SHADER, 0, 2));
   emit(c, handle);
   emit(c, type);
}

static void emit_shader(struct cmds *c, uint32_t handle, uint32_t type, const char *text)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER, 5 + text_words(text)));
   emit(c, handle);
   emit(c, type);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(strlen(text) + 1));
   emit(c, 300);
   emit(c, 0);
   emit_text(c, text);
   emit_bind_shader(c, handle, type);
}

/* A vertex shader that records OUT[1] (4 components) into buffer 0. */
static void emit_xfb_vertex_shader(struct cmds *c, uint32_t handle, const char *text)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER,
                      VIRGL_OBJ_SHADER_HDR_SIZE(1) + text_words(text)));
   emit(c, handle);
   emit(c, TEST_SHADER_VERTEX);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(strlen(text) + 1));
   emit(c, 300);
   emit(c, 1);                                   /* stream outputs */
   emit(c, 4); emit(c, 0); emit(c, 0); emit(c, 0); /* strides in dwords */
   emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_REGISTER_INDEX(1) |
           VIRGL_OBJ_SHADER_SO_OUTPUT_NUM_COMPONENTS(4));
   emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_STREAM(0));
   emit_text(c, text);
   emit_bind_shader(c, handle, TEST_SHADER_VERTEX);
}

static void emit_so_target(struct cmds *c, uint32_t handle, uint32_t res)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_STREAMOUT_TARGET,
                      VIRGL_OBJ_STREAMOUT_SIZE));
   emit(c, handle);
   emit(c, res);
   emit(c, 0);
   emit(c, 4096);
}

static void emit_set_targets(struct cmds *c, uint32_t n, const uint32_t *handles)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 1 + n));
   emit(c, 0);
   for (uint32_t i = 0; i < n; i++)
      emit(c, handles[i]);
}

static void emit_destroy(struct cmds *c, uint32_t type, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_OBJECT, type, 1));
   emit(c, handle);
}

static void emit_draw(struct cmds *c, uint32_t mode)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, 0);                      /* start */
   emit(c, 3);                      /* count */
   emit(c, mode);
   for (int i = 0; i < VIRGL_DRAW_VBO_SIZE - 3; i++)
      emit(c, 0);
}

/* vrend clears with no program bound (glUseProgram(0)), like its transfers do. */
static void emit_clear(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, 1 << 2);                 /* PIPE_CLEAR_COLOR0 */
   for (int i = 0; i < VIRGL_OBJ_CLEAR_SIZE - 1; i++)
      emit(c, 0);
}

static void emit_query(struct cmds *c, uint32_t cmd, uint32_t handle)
{
   emit(c, VIRGL_CMD0(cmd, 0, 1));
   emit(c, handle);
}

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}

static const char *vs_xfb =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], IN[0]\n"
   "  2: END\n";

static const char *vs_plain =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: ADD OUT[1], IN[0], IN[0]\n"
   "  2: END\n";

static const char *fs_text =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

enum { RES_BASE = 100, RT_BASE = 200, QRES_BASE = 300 };

/* A 64x64 colour buffer, so draws have somewhere to go. */
static void setup_framebuffer(struct cmds *c, int ctx_id)
{
   uint32_t rt = RT_BASE + ctx_id;
   struct virgl_renderer_resource_create_args args = {
      .handle = rt, .target = TEST_PIPE_TEXTURE_2D, .format = VIRGL_FORMAT_B8G8R8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 64, .height = 64, .depth = 1,
      .array_size = 1,
   };
   virgl_renderer_resource_create(&args, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx_id, rt);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, 1);
   emit(c, rt);
   emit(c, VIRGL_FORMAT_B8G8R8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, 1);
}

static void release_framebuffer(int ctx_id)
{
   virgl_renderer_ctx_detach_resource(ctx_id, RT_BASE + ctx_id);
   virgl_renderer_resource_unref(RT_BASE + ctx_id);
}

/* Record with one target, end the way Mesa does (unbind), leave it paused on the host.
 * Handles: shaders 10 (xfb vs), 11 (fs), target 20 on buffer res. */
static void record(struct cmds *c, uint32_t res, uint32_t mode)
{
   uint32_t target = 20;
   emit_xfb_vertex_shader(c, 10, vs_xfb);
   emit_shader(c, 11, TEST_SHADER_FRAGMENT, fs_text);
   emit_so_target(c, target, res);
   emit_set_targets(c, 1, &target);
   emit_draw(c, mode);
}

static void run_case(int n, int ctx_id)
{
   struct cmds *c = calloc(1, sizeof(*c));
   uint32_t res = RES_BASE + ctx_id, target = 20, none = 0;
   char name[32];
   void *query_mem = NULL;

   snprintf(name, sizeof(name), "tf-case-%d", n);
   if (virgl_renderer_context_create(ctx_id, strlen(name), name)) {
      check(0, "context create");
      free(c);
      return;
   }
   struct virgl_renderer_resource_create_args args = {
      .handle = res, .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_STREAM_OUTPUT, .width = 4096, .height = 1, .depth = 1,
      .array_size = 1,
   };
   virgl_renderer_resource_create(&args, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx_id, res);
   setup_framebuffer(c, ctx_id);

   switch (n) {
   case 1:
      printf("case 1: target destroyed while transform feedback is paused\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 2:
      printf("case 2: unbound (Mesa's end), then the target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 3:
      printf("case 3: unbound, other program drawn, then the target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      emit_shader(c, 12, TEST_SHADER_VERTEX, vs_plain);
      emit_draw(c, TEST_PRIM_TRIANGLES);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 4:
      printf("case 4: unbound, recording shaders destroyed, then the target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      emit_bind_shader(c, 0, TEST_SHADER_VERTEX);
      emit_bind_shader(c, 0, TEST_SHADER_FRAGMENT);
      emit_destroy(c, VIRGL_OBJECT_SHADER, 10);
      emit_destroy(c, VIRGL_OBJECT_SHADER, 11);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 5:
      /* Mesa never sends this (it unbinds the targets to pause); GL refuses to record
       * with a program that has no outputs to record: that draw is skipped. */
      printf("case 5: program without outputs drawn while still bound, target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_shader(c, 12, TEST_SHADER_VERTEX, vs_plain);
      emit_draw(c, TEST_PRIM_POINTS);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 6:
      printf("case 6: recording shaders destroyed while bound, then the target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_bind_shader(c, 0, TEST_SHADER_VERTEX);
      emit_destroy(c, VIRGL_OBJECT_SHADER, 10);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 7:
      printf("case 7: rebound after the end (same target), drawn with another mode, destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      emit_set_targets(c, 1, &target);
      emit_draw(c, TEST_PRIM_TRIANGLES);
      emit_set_targets(c, 0, NULL);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 8:
      printf("case 8: buffer resource released before the target\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      submit(ctx_id, c);
      virgl_renderer_ctx_detach_resource(ctx_id, res);
      virgl_renderer_resource_unref(res);
      res = 0;
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 11:
      printf("case 11: unbound, other program drawn, recording shaders destroyed, target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      emit_shader(c, 12, TEST_SHADER_VERTEX, vs_plain);
      emit_draw(c, TEST_PRIM_TRIANGLES);
      emit_destroy(c, VIRGL_OBJECT_SHADER, 10);
      emit_draw(c, TEST_PRIM_TRIANGLES);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 12:
   case 13:
      printf("case %d: %s query around the recording, query destroyed, target destroyed\n", n,
             n == 12 ? "primitives-written" : "primitives-generated");
      /* Query results land in guest memory (Mesa: a PIPE_BUFFER with VIRGL_BIND_CUSTOM). */
      query_mem = calloc(1, 64);
      struct virgl_renderer_resource_create_args qargs = {
         .handle = QRES_BASE + ctx_id, .target = TEST_PIPE_BUFFER,
         .format = VIRGL_FORMAT_R8_UNORM, .bind = VIRGL_BIND_CUSTOM, .width = 64,
         .height = 1, .depth = 1, .array_size = 1,
      };
      struct iovec qiov = { query_mem, 64 };
      virgl_renderer_resource_create(&qargs, NULL, 0);
      virgl_renderer_resource_attach_iov(QRES_BASE + ctx_id, &qiov, 1);
      virgl_renderer_ctx_attach_resource(ctx_id, QRES_BASE + ctx_id);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_QUERY, VIRGL_OBJ_QUERY_SIZE));
      emit(c, 60);
      emit(c, VIRGL_OBJ_QUERY_TYPE(n == 12 ? TEST_QUERY_PRIMITIVES_EMITTED
                                          : TEST_QUERY_PRIMITIVES_GENERATED));
      emit(c, 0);
      emit(c, QRES_BASE + ctx_id);
      emit_query(c, VIRGL_CCMD_BEGIN_QUERY, 60);
      record(c, res, TEST_PRIM_POINTS);
      emit_query(c, VIRGL_CCMD_END_QUERY, 60);
      emit_set_targets(c, 0, NULL);
      emit_destroy(c, VIRGL_OBJECT_QUERY, 60);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 14:
      printf("case 14: unbound, cleared (no program bound), then the target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      emit_clear(c);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 15:
      printf("case 15: cleared while bound, then the target destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_clear(c);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, target);
      break;
   case 9:
      printf("case 9: context destroyed while transform feedback is paused\n");
      record(c, res, TEST_PRIM_POINTS);
      break;
   case 10:
      printf("case 10: unbound, recording shaders destroyed, context destroyed\n");
      record(c, res, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, NULL);
      emit_bind_shader(c, 0, TEST_SHADER_VERTEX);
      emit_destroy(c, VIRGL_OBJECT_SHADER, 10);
      break;
   }
   int r = submit(ctx_id, c);
   char what[80];
   snprintf(what, sizeof(what), "case %d: commands accepted", n);
   check(r == 0, what);

   /* The context keeps working: record again from scratch and draw. */
   if (n != 8 && n != 9 && n != 10) {
      emit_set_targets(c, 0, NULL);
      emit_shader(c, 30, TEST_SHADER_VERTEX, vs_plain);
      emit_shader(c, 31, TEST_SHADER_FRAGMENT, fs_text);
      emit_draw(c, TEST_PRIM_TRIANGLES);
      emit_so_target(c, 40, res);
      emit_set_targets(c, 1, (uint32_t[]){ 40 });
      emit_xfb_vertex_shader(c, 41, vs_xfb);
      emit_draw(c, TEST_PRIM_POINTS);
      emit_set_targets(c, 0, &none);
      emit_destroy(c, VIRGL_OBJECT_STREAMOUT_TARGET, 40);
      snprintf(what, sizeof(what), "case %d: context still draws afterwards", n);
      check(submit(ctx_id, c) == 0, what);
   }

   if (res) {
      virgl_renderer_ctx_detach_resource(ctx_id, res);
      virgl_renderer_resource_unref(res);
   }
   if (query_mem) {
      virgl_renderer_ctx_detach_resource(ctx_id, QRES_BASE + ctx_id);
      virgl_renderer_resource_detach_iov(QRES_BASE + ctx_id, NULL, NULL);
      virgl_renderer_resource_unref(QRES_BASE + ctx_id);
   }
   virgl_renderer_context_destroy(ctx_id);
   release_framebuffer(ctx_id);
   free(query_mem);
   free(c);
}

int main(int argc, char **argv)
{
   int only = argc > 1 ? atoi(argv[1]) : 0;

   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = new_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }

   for (int n = 1; n <= 15; n++)
      if (!only || only == n)
         run_case(n, n);

   /* One more context after all of that. */
   struct cmds *c = calloc(1, sizeof(*c));
   check(!virgl_renderer_context_create(50, 5, "after"), "a new context after the cases");
   setup_framebuffer(c, 50);
   emit_shader(c, 1, TEST_SHADER_VERTEX, vs_plain);
   emit_shader(c, 2, TEST_SHADER_FRAGMENT, fs_text);
   emit_draw(c, TEST_PRIM_TRIANGLES);
   check(submit(50, c) == 0, "and it draws");
   virgl_renderer_context_destroy(50);
   release_framebuffer(50);
   free(c);

   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "transform feedback: FAILED" : "transform feedback: all checks passed");
   return failures != 0;
}
