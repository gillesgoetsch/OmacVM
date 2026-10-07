/* The index range cache (virgl-index-range-cache.patch) on Apple's software renderer
 * (soft-gl.h; never on the GPU), linked with gl-oracle.c: a GL draw call whose indices
 * reach past its vertex buffer aborts the test, and the oracle's draw counter shows
 * whether a guest draw reached the GL at all.
 * Each case draws once with valid indices (the range is read back and remembered), then
 * changes the indices through one path so that they point past the vertex buffer, and
 * draws again: that draw must be SKIPPED. A cache that missed the change would draw with
 * the old range (the oracle aborts). Paths: a transfer, an inline write, a copy transfer,
 * a copy from another buffer, stream output, a storage buffer, an image or an atomic
 * counter binding then a GPU write, a query result, the handle freed and reused, and the
 * same buffer with another offset, count, index size, restart index or restart switch.
 * Valid draws must stay DRAWN, a repeated draw must be a cache hit, a write to another
 * buffer must leave the range cached, a read-back the GL refused is not remembered, more
 * ranges than slots stay right, and only plain GL buffers are cached at all.
 * Run with OMACVM_VIRGL_INDEX_RANGE_CACHE=0 too: same results, never a hit.
 * Built with vrend_renderer.c included, so it can reach the cache's counters and turn on
 * the GL features Apple's GL 4.1 lacks (storage buffers, images, atomic counters, query
 * buffers) for the bindings; the GPU writes those would make are done by the test.
 * Usage: test-index-range-cache [case] */
#include <epoxy/gl.h>
/* Apple's GL has no GL_QUERY_BUFFER: vrend_get_query_result_qbo's bind and query are
 * stood in for by what a GL with ARB_query_buffer_object does (the result lands in the
 * buffer). The read-back can be made to fail once (fail_reads). */
#undef glBindBuffer
#define glBindBuffer test_bind_buffer
#undef glGetQueryObjectuiv
#define glGetQueryObjectuiv test_get_query_uiv
#undef glGetBufferSubData
#define glGetBufferSubData test_get_buffer_sub_data
static void test_bind_buffer(GLenum target, GLuint id);
static void test_get_query_uiv(GLuint id, GLenum pname, GLuint *params);
static void test_get_buffer_sub_data(GLenum target, GLintptr offset, GLsizeiptr size, void *data);
#ifdef VREND_RENDERER_C
#include VREND_RENDERER_C /* mutate-index-range-cache.py: a changed copy */
#else
#include "vrend/vrend_renderer.c"
#endif
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#undef glGetString /* soft-gl.h asks the GL itself, not through epoxy */
#include "soft-gl.h"

unsigned long gl_oracle_draws(void);

static GLuint query_buffer;
static int fail_reads;

static void test_bind_buffer(GLenum target, GLuint id)
{
   if (target == GL_QUERY_BUFFER) {
      query_buffer = id;
      return;
   }
   epoxy_glBindBuffer(target, id);
}

static void test_get_query_uiv(GLuint id, GLenum pname, GLuint *params)
{
   GLuint value = 0;
   GLint old = 0;

   if (!query_buffer) {
      epoxy_glGetQueryObjectuiv(id, pname, params);
      return;
   }
   /* the GPU writes the result at the offset given as the pointer */
   epoxy_glGetQueryObjectuiv(id, GL_QUERY_RESULT, &value);
   glGetIntegerv(GL_COPY_WRITE_BUFFER_BINDING, &old);
   epoxy_glBindBuffer(GL_COPY_WRITE_BUFFER, query_buffer);
   glBufferSubData(GL_COPY_WRITE_BUFFER, (GLintptr)params, sizeof(value), &value);
   epoxy_glBindBuffer(GL_COPY_WRITE_BUFFER, old);
}

static void test_get_buffer_sub_data(GLenum target, GLintptr offset, GLsizeiptr size, void *data)
{
   if (fail_reads > 0) {
      fail_reads--;
      /* a read the GL refuses (GL_INVALID_VALUE); what lands in data is garbage */
      memset(data, 0, size);
      epoxy_glGetBufferSubData(target, offset, (GLsizeiptr)1 << 40, data);
      return;
   }
   epoxy_glGetBufferSubData(target, offset, size, data);
}

enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2, TEST_SHADER_VERTEX = 0,
       TEST_SHADER_FRAGMENT = 1, TEST_PRIM_POINTS = 0, TEST_PRIM_TRIANGLES = 4 };

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
}

/* A vertex shader that records OUT[1] (= IN[0], 4 floats) into stream output buffer 0. */
static void emit_xfb_vertex_shader(struct cmds *c, uint32_t handle, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER,
                      VIRGL_OBJ_SHADER_HDR_SIZE(1) + words));
   emit(c, handle);
   emit(c, TEST_SHADER_VERTEX);
   emit(c, VIRGL_OBJ_SHADER_OFFSET_VAL(bytes));
   emit(c, 300);
   emit(c, 1);
   emit(c, 4); emit(c, 0); emit(c, 0); emit(c, 0);
   emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_REGISTER_INDEX(1) |
           VIRGL_OBJ_SHADER_SO_OUTPUT_NUM_COMPONENTS(4));
   emit(c, VIRGL_OBJ_SHADER_SO_OUTPUT_STREAM(0));
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

static void emit_index_buffer(struct cmds *c, uint32_t handle, uint32_t size, uint32_t offset)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_INDEX_BUFFER, 0, VIRGL_SET_INDEX_BUFFER_SIZE(1)));
   emit(c, handle);
   emit(c, size);
   emit(c, offset);
}

static void emit_write(struct cmds *c, uint32_t handle, uint32_t offset, const void *data,
                       uint32_t bytes)
{
   uint32_t words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(c, handle);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, offset);
   emit(c, 0);
   emit(c, 0);
   emit(c, bytes);
   emit(c, 1);
   emit(c, 1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

struct draw {
   uint32_t start, count, mode, indexed, restart, restart_index;
};

static void emit_draw(struct cmds *c, const struct draw *d)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, d->start);
   emit(c, d->count);
   emit(c, d->mode);
   emit(c, d->indexed);
   emit(c, 0);                   /* instances */
   emit(c, 0);                   /* index bias */
   emit(c, 0);                   /* start instance */
   emit(c, d->restart);
   emit(c, d->restart_index);
   emit(c, 0);                   /* min index */
   emit(c, 0xffffffff);          /* max index */
   emit(c, 0);                   /* count from stream output */
}

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}

static const char *vs1 =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

static const char *vs_xfb =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], IN[0]\n"
   "  2: END\n";

static const char *fs =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 { 1.0, 0.0, 0.0, 1.0 }\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

/* Resources (per context: handle + 1000 * ctx). IB holds 16 bytes of uint16 indices
 * {0, 1, 2, 3, 0xffff, 1, 2, 4}; VB 4 vertices; OTHER and STAGING 16 bytes. */
enum { R_RT = 1, R_VB = 2, R_IB = 3, R_OTHER = 4, R_STAGING = 5, R_SO = 6, R_QUERY = 7,
       R_COUNT };

static const uint16_t valid_idx[8] = { 0, 1, 2, 3, 0xffff, 1, 2, 4 };
static const uint16_t bad_idx[8] = { 9, 9, 9, 9, 9, 9, 9, 9 };
static uint8_t staging_mem[16], transfer_mem[16];

static uint32_t res_id(int ctx, int r)
{
   return 1000 * ctx + r;
}

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

static void setup(struct cmds *c, int ctx)
{
   char name[16];
   snprintf(name, sizeof(name), "irc-%d", ctx);
   virgl_renderer_context_create(ctx, strlen(name), name);

   struct virgl_renderer_resource_create_args rt = {
      .handle = res_id(ctx, R_RT), .target = TEST_PIPE_TEXTURE_2D,
      .format = VIRGL_FORMAT_B8G8R8A8_UNORM, .bind = VIRGL_BIND_RENDER_TARGET, .width = 64,
      .height = 64, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&rt, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, R_RT));
   make_buffer(ctx, R_VB, VIRGL_BIND_VERTEX_BUFFER, 64);
   make_buffer(ctx, R_IB, VIRGL_BIND_INDEX_BUFFER, 16);
   make_buffer(ctx, R_OTHER, VIRGL_BIND_INDEX_BUFFER, 16);
   make_buffer(ctx, R_STAGING, VIRGL_BIND_STAGING, 16);
   make_buffer(ctx, R_SO, VIRGL_BIND_STREAM_OUTPUT, 64);
   make_buffer(ctx, R_QUERY, VIRGL_BIND_CUSTOM, 64);
   /* the renderer keeps the iovec array, not a copy */
   static struct iovec staging_iov = { staging_mem, sizeof(staging_mem) };
   virgl_renderer_resource_attach_iov(res_id(ctx, R_STAGING), &staging_iov, 1);

   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, 1);
   emit(c, res_id(ctx, R_RT));
   emit(c, VIRGL_FORMAT_B8G8R8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, 1);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);
   const float vp[6] = { 32, 32, 0.5f, 32, 32, 0.5f };
   for (int i = 0; i < 6; i++) {
      uint32_t u;
      memcpy(&u, &vp[i], 4);
      emit(c, u);
   }
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(c, 41);
   emit(c, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 2; i++)
      emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, 41);

   emit_shader(c, 1, TEST_SHADER_VERTEX, vs1);
   emit_shader(c, 2, TEST_SHADER_FRAGMENT, fs);
   emit_bind_shader(c, 1, TEST_SHADER_VERTEX);
   emit_bind_shader(c, 2, TEST_SHADER_FRAGMENT);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                      VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(1)));
   emit(c, 10);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_FORMAT_R32G32B32A32_FLOAT);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(c, 10);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, VIRGL_SET_VERTEX_BUFFERS_SIZE(1)));
   emit(c, 16);
   emit(c, 0);
   emit(c, res_id(ctx, R_VB));

   /* a full-screen triangle (vertex 3 too), so stream output and queries see data */
   const float verts[16] = { -1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1, 1, 1, 0, 1 };
   emit_write(c, res_id(ctx, R_VB), 0, verts, sizeof(verts));
   emit_write(c, res_id(ctx, R_IB), 0, valid_idx, sizeof(valid_idx));
   emit_write(c, res_id(ctx, R_OTHER), 0, bad_idx, sizeof(bad_idx));
   emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
}

static void teardown(int ctx)
{
   virgl_renderer_context_destroy(ctx);
   for (int r = R_RT; r < R_COUNT; r++)
      virgl_renderer_resource_unref(res_id(ctx, r));
}

static struct vrend_resource *vres(uint32_t handle)
{
   struct virgl_resource *r = virgl_resource_lookup(handle);
   return r ? (struct vrend_resource *)r->pipe_resource : NULL;
}

/* The vrend context of a guest context (the one that ran the last submit). */
static struct vrend_context *vctx(int ctx)
{
   struct vrend_context *c = vrend_state.current_ctx;
   return c && c->ctx_id == ctx ? c : NULL;
}

/* A GPU write vrend does not see (a shader storing through a binding): new indices
 * straight into the GL buffer. */
static void gpu_write(uint32_t handle, const void *data, uint32_t bytes)
{
   struct vrend_resource *res = vres(handle);
   GLint old = 0;
   glGetIntegerv(GL_COPY_WRITE_BUFFER_BINDING, &old);
   epoxy_glBindBuffer(GL_COPY_WRITE_BUFFER, res->gl_id);
   glBufferSubData(GL_COPY_WRITE_BUFFER, 0, bytes, data);
   epoxy_glBindBuffer(GL_COPY_WRITE_BUFFER, old);
}

static const struct draw idx4 = { .count = 4, .mode = TEST_PRIM_TRIANGLES, .indexed = 1 };

/* Submits one draw; returns how many GL draw calls it made (0 = skipped). */
static unsigned long draw(struct cmds *c, int ctx, const struct draw *d)
{
   emit_draw(c, d);
   unsigned long before = gl_oracle_draws();
   submit(ctx, c);
   return gl_oracle_draws() - before;
}

static uint64_t hits(void)
{
   return vrend_index_range_stats.hits;
}

static uint64_t misses(void)
{
   return vrend_index_range_stats.misses;
}

static void expect(int ok, int n, const char *what, const char *result)
{
   char line[200];
   snprintf(line, sizeof(line), "case %d: %s: %s", n, what, result);
   check(ok, line);
}

/* Cases 1-10: draw (fills the cache), draw again (a hit), change the indices through
 * one path, draw: must be skipped; then valid indices again: drawn. */
static void run_change_case(int n)
{
   struct cmds *c = calloc(1, sizeof(*c));
   const int ctx = n;
   const char *what = NULL;
   const bool cache = vrend_index_range_cache_on;

   setup(c, ctx);
   if (submit(ctx, c)) {
      check(0, "setup accepted");
      teardown(ctx);
      free(c);
      return;
   }
   const uint32_t ib = res_id(ctx, R_IB);

   uint64_t h = hits();
   expect(draw(c, ctx, &idx4) == 1, n, "indices 0..3", "drawn");
   expect(draw(c, ctx, &idx4) == 1, n, "the same draw again", "drawn");
   expect(cache ? hits() == h + 1 : hits() == h, n, "the same draw again",
          cache ? "a cache hit" : "no cache hit (cache off)");

   switch (n) {
   case 1: {
      what = "indices changed by a transfer";
      struct iovec iov = { transfer_mem, sizeof(transfer_mem) };
      struct virgl_box box = { 0, 0, 0, 16, 1, 1 };
      memcpy(transfer_mem, bad_idx, sizeof(bad_idx));
      virgl_renderer_resource_attach_iov(ib, &iov, 1);
      virgl_renderer_transfer_write_iov(ib, ctx, 0, 0, 0, &box, 0, NULL, 0);
      virgl_renderer_resource_detach_iov(ib, NULL, NULL);
      break;
   }
   case 2:
      what = "indices changed by an inline write";
      emit_write(c, ib, 0, bad_idx, sizeof(bad_idx));
      break;
   case 3:
      what = "indices changed by a copy transfer";
      memcpy(staging_mem, bad_idx, sizeof(bad_idx));
      emit(c, VIRGL_CMD0(VIRGL_CCMD_COPY_TRANSFER3D, 0, VIRGL_COPY_TRANSFER3D_SIZE));
      emit(c, ib);
      emit(c, 0); emit(c, 0); emit(c, 0); emit(c, 0); /* level, usage, strides */
      emit(c, 0); emit(c, 0); emit(c, 0);             /* x, y, z */
      emit(c, 16); emit(c, 1); emit(c, 1);            /* w, h, d */
      emit(c, res_id(ctx, R_STAGING));
      emit(c, 0);
      emit(c, VIRGL_COPY_TRANSFER3D_FLAGS_SYNCHRONIZED);
      break;
   case 4:
      what = "indices changed by a copy from another buffer";
      emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_COPY_REGION, 0, VIRGL_CMD_RESOURCE_COPY_REGION_SIZE));
      emit(c, ib);
      emit(c, 0); emit(c, 0); emit(c, 0); emit(c, 0);
      emit(c, res_id(ctx, R_OTHER));
      emit(c, 0); emit(c, 0); emit(c, 0); emit(c, 0);
      emit(c, 16); emit(c, 1); emit(c, 1);
      break;
   case 5:
      /* point 0 recorded as 4 floats: (-1, -1, 0, 1) -> uint16 0x0000, 0xbf80, ... */
      what = "indices changed by stream output";
      emit_xfb_vertex_shader(c, 5, vs_xfb);
      emit_bind_shader(c, 5, TEST_SHADER_VERTEX);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_STREAMOUT_TARGET,
                         VIRGL_OBJ_STREAMOUT_SIZE));
      emit(c, 30);
      emit(c, ib);
      emit(c, 0);
      emit(c, 16);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 2));
      emit(c, 0);
      emit(c, 30);
      emit_draw(c, &(struct draw){ .count = 1, .mode = TEST_PRIM_POINTS });
      emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 1));
      emit(c, 0);
      emit_bind_shader(c, 1, TEST_SHADER_VERTEX);
      submit(ctx, c); /* the recording draw is not the one counted below */
      break;
   case 6: {
      what = "a storage buffer binding, then a GPU write";
      struct vrend_context *v = vctx(ctx);
      const uint32_t align = vrend_state.ssbo_offset_alignment;
      set_feature(feat_ssbo);
      vrend_state.ssbo_offset_alignment = 4;
      vrend_set_single_ssbo(v, TEST_SHADER_FRAGMENT, 0, 0, 16, ib);
      vrend_set_single_ssbo(v, TEST_SHADER_FRAGMENT, 0, 0, 0, 0);
      vrend_state.ssbo_offset_alignment = align;
      clear_feature(feat_ssbo);
      gpu_write(ib, bad_idx, sizeof(bad_idx));
      break;
   }
   case 7: {
      what = "an image binding, then a GPU write";
      struct vrend_context *v = vctx(ctx);
      set_feature(feat_images);
      vrend_set_single_image_view(v, TEST_SHADER_FRAGMENT, 0, VIRGL_FORMAT_R32_UINT,
                                  PIPE_IMAGE_ACCESS_WRITE, 0, 16, ib);
      vrend_set_single_image_view(v, TEST_SHADER_FRAGMENT, 0, 0, 0, 0, 0, 0);
      clear_feature(feat_images);
      gpu_write(ib, bad_idx, sizeof(bad_idx));
      break;
   }
   case 8: {
      what = "an atomic counter binding, then a GPU write";
      struct vrend_context *v = vctx(ctx);
      set_feature(feat_atomic_counters);
      vrend_set_single_abo(v, 0, 0, 16, ib);
      vrend_set_single_abo(v, 0, 0, 0, 0);
      clear_feature(feat_atomic_counters);
      gpu_write(ib, bad_idx, sizeof(bad_idx));
      break;
   }
   case 9:
      /* samples passed by a full-screen triangle (4096) written as uint32 at offset 0:
       * uint16 indices 4096, 0 */
      what = "indices changed by a query result";
      emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_QUERY, VIRGL_OBJ_QUERY_SIZE));
      emit(c, 60);
      emit(c, VIRGL_OBJ_QUERY_TYPE(PIPE_QUERY_OCCLUSION_COUNTER));
      emit(c, 0);
      emit(c, res_id(ctx, R_QUERY));
      emit(c, VIRGL_CMD0(VIRGL_CCMD_BEGIN_QUERY, 0, 1));
      emit(c, 60);
      emit_draw(c, &(struct draw){ .count = 3, .mode = TEST_PRIM_TRIANGLES });
      emit(c, VIRGL_CMD0(VIRGL_CCMD_END_QUERY, 0, 1));
      emit(c, 60);
      submit(ctx, c);
      set_feature(feat_qbo);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_GET_QUERY_RESULT_QBO, 0, VIRGL_QUERY_RESULT_QBO_SIZE));
      emit(c, 60);
      emit(c, ib);
      emit(c, 1);
      emit(c, PIPE_QUERY_TYPE_U32);
      emit(c, 0);
      emit(c, 0);
      submit(ctx, c);
      clear_feature(feat_qbo);
      query_buffer = 0;
      break;
   case 10:
      /* the context still holds the old buffer until the guest sets the new one */
      what = "the handle freed and reused for a buffer with other indices";
      virgl_renderer_ctx_detach_resource(ctx, ib);
      virgl_renderer_resource_unref(ib);
      make_buffer(ctx, R_IB, VIRGL_BIND_INDEX_BUFFER, 16);
      emit_write(c, ib, 0, bad_idx, sizeof(bad_idx));
      emit_index_buffer(c, ib, 2, 0);
      break;
   }

   expect(draw(c, ctx, &idx4) == 0, n, what, "the next draw is skipped");

   emit_write(c, ib, 0, valid_idx, sizeof(valid_idx));
   expect(draw(c, ctx, &idx4) == 1, n, "valid indices again", "drawn");

   teardown(ctx);
   free(c);
}

/* Cases 11-15: one buffer; a draw that differs from a cached one in one part of the key
 * (offset, count, index size, restart index, restart on) gets its own range. */
static void run_key_case(int n)
{
   struct cmds *c = calloc(1, sizeof(*c));
   const int ctx = n;
   const char *what = NULL;
   struct draw first = { .count = 3, .mode = TEST_PRIM_POINTS, .indexed = 1 }, second = first;
   uint32_t first_size = 2, second_size = 2, first_offset = 0, second_offset = 0;

   setup(c, ctx);
   submit(ctx, c);
   const uint32_t ib = res_id(ctx, R_IB);

   switch (n) {
   case 11:
      what = "another offset (byte 10: indices 1, 2, 4)";
      second_offset = 10;
      break;
   case 12:
      what = "another count (5: 0xffff without restart)";
      first.count = 4;
      second.count = 5;
      break;
   case 13: {
      /* bytes 1, 2, 3, 0: as bytes 1 and 2, as uint16 0x0201 */
      const uint8_t bytes[16] = { 1, 2, 3, 0 };
      what = "another index size (2 bytes: 0x0201)";
      emit_write(c, ib, 0, bytes, sizeof(bytes));
      first.count = second.count = 2;
      first_size = 1;
      break;
   }
   case 14:
      what = "another restart index (0xfffe: 0xffff is an index)";
      first.count = second.count = 7;
      first.restart = second.restart = 1;
      first.restart_index = 0xffff;
      second.restart_index = 0xfffe;
      break;
   case 15:
      what = "restart off after restart on (0xffff is an index)";
      first.count = second.count = 7;
      first.restart = 1;
      first.restart_index = second.restart_index = 0xffff;
      break;
   }

   emit_index_buffer(c, ib, first_size, first_offset);
   expect(draw(c, ctx, &first) == 1, n, "the first draw", "drawn");
   expect(draw(c, ctx, &first) == 1, n, "the first draw again", "drawn");
   emit_index_buffer(c, ib, second_size, second_offset);
   expect(draw(c, ctx, &second) == 0, n, what, "skipped");
   emit_index_buffer(c, ib, first_size, first_offset);
   expect(draw(c, ctx, &first) == 1, n, "the first draw once more", "drawn");

   teardown(ctx);
   free(c);
}

/* Case 16: more ranges than slots, each one stays right; case 17: a write to another
 * buffer keeps this buffer's range; case 18: a read-back the GL refused is not kept;
 * case 20: restart on with restart index 0 and restart off have their own ranges (all
 * indices 0: nothing to draw with restart, one point without). */
static void run_other_case(int n)
{
   struct cmds *c = calloc(1, sizeof(*c));
   const int ctx = n;
   const bool cache = vrend_index_range_cache_on;

   setup(c, ctx);
   submit(ctx, c);
   const uint32_t ib = res_id(ctx, R_IB);

   if (n == 16) {
      int ok = 1;
      for (int round = 0; round < 2; round++)
         for (uint32_t count = 1; count <= 4; count++) /* 4 ranges + offset 2 = 5 keys */
            for (uint32_t off = 0; off <= 2; off += 2) {
               emit_index_buffer(c, ib, 2, off);
               ok &= draw(c, ctx, &(struct draw){ .count = count, .mode = TEST_PRIM_POINTS,
                                                  .indexed = 1 }) == (off + 2 * count <= 8 ? 1u : 0u);
            }
      expect(ok, n, "8 ranges of one buffer, twice (more than its 4 slots)", "all right");
      emit_index_buffer(c, ib, 2, 0);
      emit_write(c, ib, 0, bad_idx, sizeof(bad_idx));
      expect(draw(c, ctx, &idx4) == 0, n, "then new indices", "skipped");
   } else if (n == 17) {
      const float verts[16] = { 0 };
      draw(c, ctx, &idx4);
      uint64_t h = hits();
      emit_write(c, res_id(ctx, R_VB), 0, verts, sizeof(verts));
      expect(draw(c, ctx, &idx4) == 1, n, "a write to the vertex buffer", "drawn");
      expect(cache ? hits() == h + 1 : hits() == h, n, "a write to the vertex buffer",
             cache ? "the index range still a hit" : "no hit (cache off)");
   } else if (n == 18) {
      fail_reads = 1;
      expect(draw(c, ctx, &idx4) == 0, n, "a read-back the GL refuses", "skipped");
      uint64_t m = misses(), h = hits();
      expect(draw(c, ctx, &idx4) == 1, n, "the same draw again", "drawn");
      expect(cache ? misses() == m + 1 && hits() == h : hits() == h, n,
             "the same draw again", "read back again (the refused read was not kept)");
   } else if (n == 20) {
      const uint16_t zeros[8] = { 0 };
      const struct draw on0 = { .count = 4, .mode = TEST_PRIM_POINTS, .indexed = 1,
                                .restart = 1, .restart_index = 0 };
      const struct draw off = { .count = 4, .mode = TEST_PRIM_POINTS, .indexed = 1 };
      emit_write(c, ib, 0, zeros, sizeof(zeros));
      expect(draw(c, ctx, &on0) == 0, n, "indices all 0, restart index 0", "nothing drawn");
      expect(draw(c, ctx, &on0) == 0, n, "the same draw again", "nothing drawn");
      expect(draw(c, ctx, &off) == 1, n, "the same indices without restart", "drawn");
   }

   teardown(ctx);
   free(c);
}

/* Case 19: which buffers may be cached at all. */
static void run_eligibility_case(void)
{
   struct vrend_resource r;
   const bool cache = vrend_index_range_cache_on;
#define ELIG(what, stmt, want)                                                     \
   do {                                                                             \
      memset(&r, 0, sizeof(r));                                                     \
      r.base.target = PIPE_BUFFER;                                                  \
      r.storage_bits = VREND_STORAGE_GUEST_MEMORY | VREND_STORAGE_GL_BUFFER;        \
      r.gl_id = 1;                                                                  \
      stmt;                                                                         \
      check(vrend_index_range_cacheable(&r) == ((want) && cache),                   \
            want && cache ? "case 19: " what ": cached" : "case 19: " what ": not cached"); \
   } while (0)
   ELIG("a plain GL buffer", (void)0, true);
   ELIG("immutable storage", r.storage_bits |= VREND_STORAGE_GL_IMMUTABLE, false);
   ELIG("persistent mapping", r.buffer_storage_flags = GL_MAP_PERSISTENT_BIT, false);
   ELIG("coherent mapping", r.buffer_storage_flags = GL_MAP_COHERENT_BIT, false);
   ELIG("a memory object", r.storage_bits |= VREND_STORAGE_GL_MEMOBJ, false);
   ELIG("a GBM buffer", r.storage_bits |= VREND_STORAGE_GBM_BUFFER, false);
   ELIG("host memory", r.storage_bits = VREND_STORAGE_HOST_SYSTEM_MEMORY, false);
   ELIG("guest memory only", r.storage_bits = VREND_STORAGE_GUEST_MEMORY, false);
   ELIG("a blob", r.blob_id = 7, false);
   ELIG("imported", r.is_imported = true, false);
   ELIG("a texture", r.base.target = PIPE_TEXTURE_2D, false);
   ELIG("bound where the GPU writes", vrend_resource_no_index_range_cache(&r), false);
#undef ELIG
}

int main(int argc, char **argv)
{
   int only = argc > 1 ? atoi(argv[1]) : 0;

   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = soft_gl_context(NULL);
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
   printf("index range cache %s\n", vrend_index_range_cache_on ? "on" : "off");

   for (int n = 1; n <= 10; n++)
      if (!only || only == n)
         run_change_case(n);
   for (int n = 11; n <= 15; n++)
      if (!only || only == n)
         run_key_case(n);
   for (int n = 16; n <= 18; n++)
      if (!only || only == n)
         run_other_case(n);
   if (!only || only == 19)
      run_eligibility_case();
   if (!only || only == 20)
      run_other_case(20);

   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "index range cache: FAILED" : "index range cache: all checks passed");
   return failures != 0;
}
