/* Guest draws that would make the GPU read or write outside a buffer, through the public
 * renderer API on Apple's software renderer (soft-gl.h; never on the GPU). Linked with
 * gl-oracle.c: any GL draw call whose buffers are unbound or too small aborts the test,
 * and its draw counter shows whether a guest draw reached the GL at all.
 * Each case runs in a fresh context and expects one of:
 *  DRAWN   - the draw reaches the GL (edge cases that are valid),
 *  SKIPPED - the draw is dropped, the context keeps drawing,
 *  LOST    - the guest's command is refused and its context is lost.
 * Covers virgl-buffer-binding-checks.patch, virgl-draw-range-checks.patch and
 * virgl-uniform-buffer-checks.patch; case 29 virgl-shader-index-clamp.patch; cases 30-31
 * virgl-vertex-format-checks.patch, 32 virgl-uniform-buffer-alignment.patch, 33-34
 * virgl-uniform-block-array.patch (30-33 are the gpu-robust review's repros 1-3), 35
 * virgl-vertex-unused-first-input.patch (the second review's repro 5).
 * gl-oracle.c also aborts on a GL error pending at a draw (virgl-draw-gl-error-check).
 * Usage: test-gpu-ranges [case] */
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

unsigned long gl_oracle_draws(void);

enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2, TEST_SHADER_VERTEX = 0,
       TEST_SHADER_FRAGMENT = 1, TEST_PRIM_POINTS = 0, TEST_PRIM_TRIANGLES = 4 };
enum expect { DRAWN, SKIPPED, LOST };

static CGLContextObj main_ctx;
static int failures;
/* GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT of the renderer (256 on Apple's software renderer) */
static int ubo_align;

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
   /* QEMU (ui/cocoa) shares every context with its view's context, the first one too. */
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
   uint32_t dw[8192];
   unsigned n;
};

static void emit(struct cmds *c, uint32_t v)
{
   c->dw[c->n++] = v;
}

static uint32_t text_words(const char *text)
{
   return (strlen(text) + 1 + 3) / 4;
}

static void emit_shader(struct cmds *c, uint32_t handle, uint32_t type, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = text_words(text);
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

/* A vertex shader that records OUT[1] (4 components) into stream output buffer 0. */
static void emit_xfb_vertex_shader(struct cmds *c, uint32_t handle, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = text_words(text);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER,
                      VIRGL_OBJ_SHADER_HDR_SIZE(1) + words));
   emit(c, handle);
   emit(c, TEST_SHADER_VERTEX);
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

static void emit_bind_shader(struct cmds *c, uint32_t handle, uint32_t type)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_SHADER, 0, 2));
   emit(c, handle);
   emit(c, type);
}

/* elements: {src_offset, divisor, vertex buffer index} each, format RGBA32F */
static void emit_vertex_elements(struct cmds *c, uint32_t handle, unsigned n,
                                 const uint32_t (*e)[3])
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                      VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(n)));
   emit(c, handle);
   for (unsigned i = 0; i < n; i++) {
      emit(c, e[i][0]);
      emit(c, e[i][1]);
      emit(c, e[i][2]);
      emit(c, VIRGL_FORMAT_R32G32B32A32_FLOAT);
   }
}

static void emit_bind_vertex_elements(struct cmds *c, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(c, handle);
}

/* buffers: {stride, offset, handle} each */
static void emit_vertex_buffers(struct cmds *c, unsigned n, const uint32_t (*b)[3])
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, VIRGL_SET_VERTEX_BUFFERS_SIZE(n)));
   for (unsigned i = 0; i < n; i++) {
      emit(c, b[i][0]);
      emit(c, b[i][1]);
      emit(c, b[i][2]);
   }
}

static void emit_index_buffer(struct cmds *c, uint32_t handle, uint32_t size, uint32_t offset)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_INDEX_BUFFER, 0, VIRGL_SET_INDEX_BUFFER_SIZE(1)));
   emit(c, handle);
   emit(c, size);
   emit(c, offset);
}

static void emit_stage_uniform_buffer(struct cmds *c, uint32_t stage, uint32_t index,
                                      uint32_t offset, uint32_t length, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_UNIFORM_BUFFER, 0, VIRGL_SET_UNIFORM_BUFFER_SIZE));
   emit(c, stage);
   emit(c, index);
   emit(c, offset);
   emit(c, length);
   emit(c, handle);
}

static void emit_uniform_buffer(struct cmds *c, uint32_t index, uint32_t offset,
                                uint32_t length, uint32_t handle)
{
   emit_stage_uniform_buffer(c, TEST_SHADER_VERTEX, index, offset, length, handle);
}

/* one vertex element at offset 0 of vertex buffer 0, in the given format */
static void emit_vertex_element_format(struct cmds *c, uint32_t handle, uint32_t format)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                      VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(1)));
   emit(c, handle);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, format);
}

static void emit_write(struct cmds *c, uint32_t handle, uint32_t offset, const void *data,
                       uint32_t bytes)
{
   uint32_t words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(c, handle);
   emit(c, 0);          /* level */
   emit(c, 0);          /* usage */
   emit(c, 0);          /* stride */
   emit(c, 0);          /* layer stride */
   emit(c, offset);     /* x */
   emit(c, 0);
   emit(c, 0);
   emit(c, bytes);      /* w */
   emit(c, 1);
   emit(c, 1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

struct draw {
   uint32_t start, count, mode, indexed, instances, bias, start_instance, restart, restart_index;
   uint32_t indirect, indirect_offset, indirect_stride, indirect_count;
};

static void emit_draw(struct cmds *c, const struct draw *d)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0,
                      d->indirect ? VIRGL_DRAW_VBO_SIZE_INDIRECT : VIRGL_DRAW_VBO_SIZE));
   emit(c, d->start);
   emit(c, d->count);
   emit(c, d->mode);
   emit(c, d->indexed);
   emit(c, d->instances);
   emit(c, d->bias);
   emit(c, d->start_instance);
   emit(c, d->restart);
   emit(c, d->restart_index);
   emit(c, 0);                   /* min index */
   emit(c, 0xffffffff);          /* max index */
   emit(c, 0);                   /* count from stream output */
   if (d->indirect) {
      emit(c, 0);                /* vertices per patch */
      emit(c, 0);                /* draw id */
      emit(c, d->indirect);
      emit(c, d->indirect_offset);
      emit(c, d->indirect_stride);
      emit(c, d->indirect_count);
      emit(c, 0);
      emit(c, 0);
   }
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

static const char *vs2 =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL IN[1]\n"
   "DCL OUT[0], POSITION\n"
   "  0: ADD OUT[0], IN[0], IN[1]\n"
   "  1: END\n";

/* reads a 64-byte uniform block (gallium buffer 1) */
static const char *vs_ubo =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL CONST[1][0..3]\n"
   "  0: ADD OUT[0], IN[0], CONST[1][3]\n"
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

/* reads a 32-byte uniform block (gallium buffer 1) */
static const char *vs_ubo32 =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL CONST[1][0..1]\n"
   "  0: ADD OUT[0], IN[0], CONST[1][1]\n"
   "  1: END\n";

/* declares two inputs and reads only IN[1]: IN[0] gets no attribute location */
static const char *vs_in1_only =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL IN[1]\n"
   "DCL OUT[0], POSITION\n"
   "  0: MOV OUT[0], IN[1]\n"
   "  1: END\n";

/* Uniform blocks 1 and 3 (block 2 is a hole) picked at run time: block ADDR + 1. Case 33
 * picks block 2, case 34 block 3. */
static const char *fs_block_holes =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[1][0..3]\n"
   "DCL CONST[3][0..3]\n"
   "DCL ADDR[0]\n"
   "IMM[0] FLT32 { 1.0, 2.0, 0.0, 0.0 }\n"
   "  0: ARL ADDR[0].x, IMM[0].%s\n"
   "  1: MOV OUT[0], CONST[ADDR[0].x+1][3]\n"
   "  2: END\n";

/* Resources (per context id: handle + 1000 * ctx). */
enum { R_RT = 1, R_VB = 2, R_VB_SMALL = 3, R_IB = 4, R_UBO64 = 5, R_UBO32 = 6, R_UBO52 = 7,
       R_ARGS = 8, R_SO = 9, R_EMPTY = 10, R_UBO_ALIGNED = 11, R_UBO_COLOR = 12, R_COUNT };

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

/* A context with a 64x64 colour buffer, the shaders, vertex elements and buffers:
 *  VB: 64 bytes = 4 vertices of RGBA32F; VB_SMALL: 16 bytes = 1 vertex;
 *  IB: 16 bytes of uint16 indices {0, 1, 2, 3, 0xffff, 1, 2, 4};
 *  ARGS: 32 bytes of draw-indirect commands. */
static void setup(struct cmds *c, int ctx)
{
   char name[16];
   snprintf(name, sizeof(name), "ranges-%d", ctx);
   virgl_renderer_context_create(ctx, strlen(name), name);

   struct virgl_renderer_resource_create_args rt = {
      .handle = res_id(ctx, R_RT), .target = TEST_PIPE_TEXTURE_2D,
      .format = VIRGL_FORMAT_B8G8R8A8_UNORM, .bind = VIRGL_BIND_RENDER_TARGET, .width = 64,
      .height = 64, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&rt, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, R_RT));
   make_buffer(ctx, R_VB, VIRGL_BIND_VERTEX_BUFFER, 64);
   make_buffer(ctx, R_VB_SMALL, VIRGL_BIND_VERTEX_BUFFER, 16);
   make_buffer(ctx, R_IB, VIRGL_BIND_INDEX_BUFFER, 16);
   make_buffer(ctx, R_UBO64, VIRGL_BIND_CONSTANT_BUFFER, 64);
   make_buffer(ctx, R_UBO32, VIRGL_BIND_CONSTANT_BUFFER, 32);
   make_buffer(ctx, R_UBO52, VIRGL_BIND_CONSTANT_BUFFER, 52);
   make_buffer(ctx, R_UBO_ALIGNED, VIRGL_BIND_CONSTANT_BUFFER, ubo_align + 32);
   make_buffer(ctx, R_UBO_COLOR, VIRGL_BIND_CONSTANT_BUFFER, 64);
   make_buffer(ctx, R_ARGS, VIRGL_BIND_COMMAND_ARGS, 32);
   make_buffer(ctx, R_SO, VIRGL_BIND_STREAM_OUTPUT, 4096);
   make_buffer(ctx, R_EMPTY, VIRGL_BIND_VERTEX_BUFFER, 0);

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

   emit_shader(c, 1, TEST_SHADER_VERTEX, vs1);
   emit_shader(c, 2, TEST_SHADER_FRAGMENT, fs);
   emit_shader(c, 3, TEST_SHADER_VERTEX, vs2);
   emit_shader(c, 4, TEST_SHADER_VERTEX, vs_ubo);
   emit_bind_shader(c, 1, TEST_SHADER_VERTEX);
   emit_bind_shader(c, 2, TEST_SHADER_FRAGMENT);
   emit_vertex_elements(c, 10, 1, (const uint32_t[][3]){ { 0, 0, 0 } });
   emit_vertex_elements(c, 11, 2, (const uint32_t[][3]){ { 0, 0, 0 }, { 0, 0, 1 } });
   emit_vertex_elements(c, 12, 2, (const uint32_t[][3]){ { 0, 0, 0 }, { 0, 1, 1 } });
   emit_bind_vertex_elements(c, 10);
   emit_vertex_buffers(c, 1, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) } });

   float verts[16] = { 0 };
   emit_write(c, res_id(ctx, R_VB), 0, verts, sizeof(verts));
   emit_write(c, res_id(ctx, R_VB_SMALL), 0, verts, 16);
   const uint16_t idx[8] = { 0, 1, 2, 3, 0xffff, 1, 2, 4 };
   emit_write(c, res_id(ctx, R_IB), 0, idx, sizeof(idx));
   float ubo[16] = { 0 };
   emit_write(c, res_id(ctx, R_UBO64), 0, ubo, 64);
   /* indirect commands: {count 4, 1 instance, first 0, 0}, {count 5, 1 instance, first 0, 0} */
   const uint32_t args[8] = { 4, 1, 0, 0, 5, 1, 0, 0 };
   emit_write(c, res_id(ctx, R_ARGS), 0, args, sizeof(args));
}

static void teardown(int ctx)
{
   virgl_renderer_context_destroy(ctx);
   for (int r = R_RT; r < R_COUNT; r++)
      virgl_renderer_resource_unref(res_id(ctx, r));
}

static const struct draw plain3 = { .count = 3, .mode = TEST_PRIM_TRIANGLES };

static const char *vs_ubo_indirect =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[1][0..3]\n"
   "DCL ADDR[0]\n"
   "IMM[0] FLT32 { 1000.0, 0.0, 0.0, 0.0 }\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: ARL ADDR[0].x, IMM[0].xxxx\n"
   "  2: MOV OUT[1], CONST[1][ADDR[0].x]\n"
   "  3: END\n";

static const char *fs_varying =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

/* A full-screen triangle with a viewport, blend and rasterizer state, so the colour the
 * fragment shader writes lands in the colour buffer. */
static void emit_pixel_draw_state(struct cmds *c, int ctx)
{
   const float tri[12] = { -1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1 };
   emit_write(c, res_id(ctx, R_VB), 0, tri, sizeof(tri));
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);
   const float vp[6] = { 32, 32, 0.5f, 32, 32, 0.5f };
   for (int i = 0; i < 6; i++) {
      uint32_t u;
      memcpy(&u, &vp[i], 4);
      emit(c, u);
   }
   /* blend state writing all channels, rasterizer state with depth clip */
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

/* the first pixel of the colour buffer, BGRA */
static void read_pixel(int ctx, uint8_t px[4])
{
   struct iovec iov = { px, 4 };
   struct virgl_box box = { 0, 0, 0, 1, 1, 1 };
   memset(px, 0, 4);
   virgl_renderer_transfer_read_iov(res_id(ctx, R_RT), ctx, 0, 0, 0, &box, 0, &iov, 1);
}

/* the colour 0.25, 0.5, 0.75, 1 as BGRA bytes */
static int is_test_colour(const uint8_t px[4])
{
   return px[0] > 180 && px[1] > 120 && px[1] < 136 && px[2] > 56 && px[2] < 72;
}

/* A shader indexes its 4-element uniform block at 1000: the translator clamps the index
 * to the last element, so the colour drawn is element 3, not memory past the buffer. */
static void run_clamp_case(void)
{
   struct cmds *c = calloc(1, sizeof(*c));
   const int ctx = 29;

   setup(c, ctx);
   const float ubo[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.25f, 0.5f, 0.75f, 1 };
   emit_write(c, res_id(ctx, R_UBO64), 0, ubo, sizeof(ubo));
   emit_pixel_draw_state(c, ctx);
   emit_shader(c, 6, TEST_SHADER_VERTEX, vs_ubo_indirect);
   emit_shader(c, 7, TEST_SHADER_FRAGMENT, fs_varying);
   emit_bind_shader(c, 6, TEST_SHADER_VERTEX);
   emit_bind_shader(c, 7, TEST_SHADER_FRAGMENT);
   emit_uniform_buffer(c, 1, 0, 64, res_id(ctx, R_UBO64));
   unsigned long before = gl_oracle_draws();
   emit_draw(c, &plain3);
   int r = submit(ctx, c);
   check(r == 0 && gl_oracle_draws() - before == 1,
         "case 29: a uniform block indexed at 1000 by an address register: drawn");

   uint8_t px[4];
   read_pixel(ctx, px);
   char line[128];
   snprintf(line, sizeof(line), "case 29: it read the block's last element (BGRA %u %u %u %u)",
            px[0], px[1], px[2], px[3]);
   check(is_test_colour(px), line);

   teardown(ctx);
   free(c);
}

/* Blocks 1 and 3 indexed at run time, every block of the array bound: the index picks
 * block 3 and the pixel shows its colour (block 1 and the hole, block 2, hold zeros). */
static void run_block_array_case(void)
{
   struct cmds *c = calloc(1, sizeof(*c));
   const int ctx = 34;
   char text[512];

   setup(c, ctx);
   const float colour[16] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.25f, 0.5f, 0.75f, 1 };
   emit_write(c, res_id(ctx, R_UBO_COLOR), 0, colour, sizeof(colour));
   emit_pixel_draw_state(c, ctx);
   snprintf(text, sizeof(text), fs_block_holes, "yyyy");
   emit_shader(c, 51, TEST_SHADER_FRAGMENT, text);
   emit_bind_shader(c, 51, TEST_SHADER_FRAGMENT);
   emit_stage_uniform_buffer(c, TEST_SHADER_FRAGMENT, 1, 0, 64, res_id(ctx, R_UBO64));
   emit_stage_uniform_buffer(c, TEST_SHADER_FRAGMENT, 2, 0, 64, res_id(ctx, R_UBO64));
   emit_stage_uniform_buffer(c, TEST_SHADER_FRAGMENT, 3, 0, 64, res_id(ctx, R_UBO_COLOR));
   unsigned long before = gl_oracle_draws();
   emit_draw(c, &plain3);
   int r = submit(ctx, c);
   check(r == 0 && gl_oracle_draws() - before == 1,
         "case 34: a uniform block array with a hole, all bound: drawn");

   uint8_t px[4];
   read_pixel(ctx, px);
   char line[128];
   snprintf(line, sizeof(line), "case 34: it read block 3 (BGRA %u %u %u %u)",
            px[0], px[1], px[2], px[3]);
   check(is_test_colour(px), line);

   teardown(ctx);
   free(c);
}

static void run_case(int n)
{
   struct cmds *c = calloc(1, sizeof(*c));
   const int ctx = n;
   const char *what = NULL;
   enum expect expect = DRAWN;
   struct draw d = { .mode = TEST_PRIM_TRIANGLES };

   setup(c, ctx);
   if (submit(ctx, c)) {
      check(0, "setup accepted");
      teardown(ctx);
      free(c);
      return;
   }

   switch (n) {
   case 1:
      what = "4 vertices from a 4-vertex buffer";
      d.count = 4;
      break;
   case 2:
      what = "5 vertices from a 4-vertex buffer";
      expect = SKIPPED;
      d.count = 5;
      break;
   case 3:
      what = "first vertex 0xfffffff0";
      expect = SKIPPED;
      d.start = 0xfffffff0;
      d.count = 3;
      break;
   case 4:
      what = "a vertex buffer offset past the buffer";
      expect = SKIPPED;
      emit_vertex_buffers(c, 1, (const uint32_t[][3]){ { 16, 64, res_id(ctx, R_VB) } });
      d.count = 1;
      break;
   case 5:
      what = "a texture bound as vertex buffer";
      expect = LOST;
      emit_vertex_buffers(c, 1, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_RT) } });
      d.count = 1;
      break;
   case 6:
      what = "a zero-size vertex buffer";
      expect = SKIPPED;
      emit_vertex_buffers(c, 1, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_EMPTY) } });
      d.count = 1;
      break;
   case 7:
      what = "indexed: indices 0..3";
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
      d.indexed = 1;
      d.count = 4;
      break;
   case 8:
      what = "indexed: index 4 of a 4-vertex buffer";
      expect = SKIPPED;
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 10);
      d.indexed = 1;
      d.count = 3;
      break;
   case 9:
      what = "indexed: restart index 0xffff skipped, rest inside";
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
      d.indexed = 1;
      d.count = 7;
      d.restart = 1;
      d.restart_index = 0xffff;
      break;
   case 10:
      what = "indexed: 0xffff without restart";
      expect = SKIPPED;
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
      d.indexed = 1;
      d.count = 7;
      break;
   case 11:
      what = "indexed: indices past the index buffer";
      expect = SKIPPED;
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
      d.indexed = 1;
      d.count = 9;
      break;
   case 12:
      what = "indexed: a count whose byte size wraps 32 bits";
      expect = SKIPPED;
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
      d.indexed = 1;
      d.count = 0x80000002;
      break;
   case 13:
      what = "indexed: index size 3";
      expect = SKIPPED;
      emit_index_buffer(c, res_id(ctx, R_IB), 3, 0);
      d.indexed = 1;
      d.count = 3;
      break;
   case 14:
      what = "indexed: index bias -1 (vertex -1)";
      expect = SKIPPED;
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
      d.indexed = 1;
      d.count = 3;
      d.bias = (uint32_t)-1;
      break;
   case 15:
      what = "indexed: index bias 1 (vertex 4)";
      expect = SKIPPED;
      emit_index_buffer(c, res_id(ctx, R_IB), 2, 0);
      d.indexed = 1;
      d.count = 4;
      d.bias = 1;
      break;
   case 16:
      what = "instanced: 2 instances from a 1-instance buffer";
      expect = SKIPPED;
      emit_bind_shader(c, 3, TEST_SHADER_VERTEX);
      emit_bind_vertex_elements(c, 12);
      emit_vertex_buffers(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) },
                                                        { 16, 0, res_id(ctx, R_VB_SMALL) } });
      d.count = 3;
      d.instances = 2;
      break;
   case 17:
      what = "instanced: 1 instance from a 1-instance buffer";
      emit_bind_shader(c, 3, TEST_SHADER_VERTEX);
      emit_bind_vertex_elements(c, 12);
      emit_vertex_buffers(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) },
                                                        { 16, 0, res_id(ctx, R_VB_SMALL) } });
      d.count = 3;
      d.instances = 1;
      break;
   case 18:
      /* attribute 1 drew from the 1-vertex buffer, then its buffer is unbound: the GL
       * attribute must be disabled, not left fetching 4 vertices from the old buffer */
      what = "an attribute whose buffer was unbound stops fetching";
      emit_bind_shader(c, 3, TEST_SHADER_VERTEX);
      emit_bind_vertex_elements(c, 11);
      emit_vertex_buffers(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) },
                                                        { 16, 0, res_id(ctx, R_VB_SMALL) } });
      emit_draw(c, &(struct draw){ .count = 1, .mode = TEST_PRIM_TRIANGLES });
      emit_vertex_buffers(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) },
                                                        { 0, 0, 0 } });
      d.count = 4;
      break;
   case 19:
      what = "a uniform block with no buffer";
      expect = SKIPPED;
      emit_bind_shader(c, 4, TEST_SHADER_VERTEX);
      d.count = 3;
      break;
   case 20:
      what = "a 64-byte uniform block in a 64-byte buffer";
      emit_bind_shader(c, 4, TEST_SHADER_VERTEX);
      emit_uniform_buffer(c, 1, 0, 64, res_id(ctx, R_UBO64));
      d.count = 3;
      break;
   case 21:
      what = "a 64-byte uniform block in a 32-byte buffer";
      expect = SKIPPED;
      emit_bind_shader(c, 4, TEST_SHADER_VERTEX);
      emit_uniform_buffer(c, 1, 0, 32, res_id(ctx, R_UBO32));
      d.count = 3;
      break;
   case 22:
      what = "a 64-byte uniform block in a 52-byte buffer (rounded up to 64)";
      emit_bind_shader(c, 4, TEST_SHADER_VERTEX);
      emit_uniform_buffer(c, 1, 0, 52, res_id(ctx, R_UBO52));
      d.count = 3;
      break;
   case 23:
      what = "a 64-byte uniform block 32 bytes before the end of its buffer";
      expect = SKIPPED;
      emit_bind_shader(c, 4, TEST_SHADER_VERTEX);
      emit_uniform_buffer(c, 1, ubo_align, 64, res_id(ctx, R_UBO_ALIGNED));
      d.count = 3;
      break;
   case 24:
      what = "indirect: a command inside the vertex buffer";
      d.indirect = res_id(ctx, R_ARGS);
      d.indirect_count = 1;
      break;
   case 25:
      what = "indirect: a command reading past the vertex buffer";
      expect = SKIPPED;
      d.indirect = res_id(ctx, R_ARGS);
      d.indirect_offset = 16;
      d.indirect_count = 1;
      break;
   case 26:
      what = "indirect: a command past the end of the indirect buffer";
      expect = SKIPPED;
      d.indirect = res_id(ctx, R_ARGS);
      d.indirect_offset = 24;
      d.indirect_count = 1;
      break;
   case 27: {
      /* a 1 GiB range at offset 16 of a 4 KiB buffer is clamped to the buffer; the
       * oracle checks the GL's transform feedback ranges on the draw */
      what = "stream output range past the buffer, clamped";
      emit_xfb_vertex_shader(c, 5, vs_xfb);
      emit_bind_shader(c, 5, TEST_SHADER_VERTEX);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_STREAMOUT_TARGET,
                         VIRGL_OBJ_STREAMOUT_SIZE));
      emit(c, 30);
      emit(c, res_id(ctx, R_SO));
      emit(c, 16);
      emit(c, 0x40000000);
      emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 2));
      emit(c, 0);
      emit(c, 30);
      d.count = 3;
      d.mode = TEST_PRIM_POINTS;
      break;
   }
   case 28:
      what = "stream output target at an unaligned offset";
      expect = LOST;
      emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_STREAMOUT_TARGET,
                         VIRGL_OBJ_STREAMOUT_SIZE));
      emit(c, 30);
      emit(c, res_id(ctx, R_SO));
      emit(c, 2);
      emit(c, 64);
      d.count = 3;
      break;
   case 30:
   case 31:
      /* the GL refuses GL_BGRA for integer and unnormalized attributes; a refused
       * attribute pointer kept fetching the 16-byte buffer of the draw before */
      what = n == 30 ? "vertex format B8G8R8A8_UINT after a draw from a smaller buffer" :
                       "vertex format B8G8R8A8_USCALED after a draw from a smaller buffer";
      expect = LOST;
      emit_vertex_buffers(c, 1, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB_SMALL) } });
      emit_draw(c, &(struct draw){ .count = 1, .mode = TEST_PRIM_POINTS });
      emit_vertex_element_format(c, 20, n == 30 ? VIRGL_FORMAT_B8G8R8A8_UINT :
                                                  VIRGL_FORMAT_B8G8R8A8_USCALED);
      emit_bind_vertex_elements(c, 20);
      emit_vertex_buffers(c, 1, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) } });
      d.count = 4;
      d.mode = TEST_PRIM_POINTS;
      break;
   case 32:
      /* the GL refuses an unaligned range and kept the 32-byte buffer of the draw before */
      what = "a uniform block at offset 4 after one in a 32-byte buffer";
      expect = LOST;
      emit_shader(c, 50, TEST_SHADER_VERTEX, vs_ubo32);
      emit_bind_shader(c, 50, TEST_SHADER_VERTEX);
      emit_uniform_buffer(c, 1, 0, 32, res_id(ctx, R_UBO32));
      emit_draw(c, &plain3);
      emit_bind_shader(c, 4, TEST_SHADER_VERTEX);
      emit_uniform_buffer(c, 1, 4, 64, res_id(ctx, R_SO));
      d.count = 3;
      break;
   case 33: {
      /* block 2 is a hole without a buffer; it used to read binding 0, the vertex
       * shader's 32-byte block */
      char text[512];
      snprintf(text, sizeof(text), fs_block_holes, "xxxx");
      what = "a uniform block array with a hole that has no buffer";
      expect = SKIPPED;
      emit_shader(c, 50, TEST_SHADER_VERTEX, vs_ubo32);
      emit_shader(c, 51, TEST_SHADER_FRAGMENT, text);
      emit_bind_shader(c, 50, TEST_SHADER_VERTEX);
      emit_bind_shader(c, 51, TEST_SHADER_FRAGMENT);
      emit_uniform_buffer(c, 1, 0, 32, res_id(ctx, R_UBO32));
      emit_stage_uniform_buffer(c, TEST_SHADER_FRAGMENT, 1, 0, 64, res_id(ctx, R_UBO64));
      emit_stage_uniform_buffer(c, TEST_SHADER_FRAGMENT, 3, 0, 64, res_id(ctx, R_UBO64));
      d.count = 3;
      break;
   }
   case 35:
      /* With IN[0] unused, vrend stopped setting attributes and the draw kept the
       * pointers of the draw before: IN[1] fetched 4 vertices from a 1-vertex buffer. */
      what = "a shader without its first input after a draw from smaller buffers";
      emit_bind_shader(c, 3, TEST_SHADER_VERTEX);
      emit_bind_vertex_elements(c, 11);
      emit_vertex_buffers(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB_SMALL) },
                                                        { 16, 0, res_id(ctx, R_VB_SMALL) } });
      emit_draw(c, &(struct draw){ .count = 1, .mode = TEST_PRIM_POINTS });
      emit_shader(c, 52, TEST_SHADER_VERTEX, vs_in1_only);
      emit_bind_shader(c, 52, TEST_SHADER_VERTEX);
      emit_vertex_buffers(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) },
                                                        { 16, 0, res_id(ctx, R_VB) } });
      d.count = 4;
      d.mode = TEST_PRIM_POINTS;
      break;
   default:
      teardown(ctx);
      free(c);
      return;
   }

   unsigned long before = gl_oracle_draws();
   unsigned long setup_draws = n == 18 || (n >= 30 && n <= 32) || n == 35 ? 1 : 0;
   emit_draw(c, &d);
   int r = submit(ctx, c);
   unsigned long drawn = gl_oracle_draws() - before - setup_draws;
   char line[160];

   switch (expect) {
   case DRAWN:
      snprintf(line, sizeof(line), "case %d: %s: drawn", n, what);
      check(r == 0 && drawn == 1, line);
      break;
   case SKIPPED:
   case LOST:
      snprintf(line, sizeof(line), "case %d: %s: not drawn", n, what);
      check(drawn == 0, line);
      break;
   }

   /* afterwards: a skipped draw leaves a working context, a lost one draws nothing */
   emit_bind_shader(c, 1, TEST_SHADER_VERTEX);
   emit_bind_shader(c, 2, TEST_SHADER_FRAGMENT);
   emit_bind_vertex_elements(c, 10);
   emit_vertex_buffers(c, 1, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_VB) } });
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_STREAMOUT_TARGETS, 0, 1));
   emit(c, 0);
   emit_draw(c, &plain3);
   before = gl_oracle_draws();
   submit(ctx, c);
   drawn = gl_oracle_draws() - before;
   snprintf(line, sizeof(line), "case %d: then the context %s", n,
            expect == LOST ? "is lost" : "still draws");
   check(expect == LOST ? drawn == 0 : drawn == 1, line);

   teardown(ctx);
   free(c);
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
   glGetIntegerv(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT, &ubo_align);
   if (ubo_align <= 4) {
      printf("FAIL: uniform buffer offset alignment %d; case 32 needs more than 4\n", ubo_align);
      return 1;
   }
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }

   for (int n = 1; n <= 33; n++)
      if (n != 29 && (!only || only == n))
         run_case(n);
   if (!only || only == 29)
      run_clamp_case();
   if (!only || only == 34)
      run_block_array_case();
   if (!only || only == 35)
      run_case(35);

   /* A buffer asking for persistent mapping gets no GL storage on a GL without
    * ARB_buffer_storage (macOS): creating it must fail, not leave an empty GL buffer. */
   if (!only) {
      struct virgl_renderer_resource_create_args a = {
         .handle = 99999, .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
         .bind = VIRGL_BIND_VERTEX_BUFFER, .width = 4096, .height = 1, .depth = 1,
         .array_size = 1, .flags = VIRGL_RESOURCE_FLAG_MAP_PERSISTENT,
      };
      int r = virgl_renderer_resource_create(&a, NULL, 0);
      check(r != 0, "a persistent buffer without buffer storage is not created");
      if (!r)
         virgl_renderer_resource_unref(99999);
   }

   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "gpu ranges: FAILED" : "gpu ranges: all checks passed");
   return failures != 0;
}
