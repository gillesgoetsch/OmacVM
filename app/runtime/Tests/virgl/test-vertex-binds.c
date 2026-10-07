/* A draw sets its vertex attributes and index buffer, and selects its shaders, only when
 * something changed (virgl-legacy-vertex-cache.patch), through the public renderer API on
 * Apple's software renderer (soft-gl.h; never on the GPU). Linked with gl-oracle.c: a GL
 * draw whose enabled attributes or indices have no buffer, or lie outside it, aborts.
 *
 * Each case runs in a fresh context and draws two or four times into four stripes of one
 * 16x16 colour buffer in ONE submit (a read-back between draws drops the caches), then
 * checks the colour of every stripe:
 *  1 one program, vertex elements switched between float and integer colours: the shader
 *    key changes, so the shaders are selected again (the program's attribute type too);
 *  2 RGBA and BGRA colour elements on one program (GL_BGRA attribute size);
 *  3 two vertex elements objects alternating on one program;
 *  4 a program switch where the attributes sit at other locations;
 *  5 a stride-0 colour whose buffer is written between draws (each draw sees the new one);
 *  6 a vertex buffer freed, its GL name reused by a new buffer at the same slot, stride
 *    and offset (two submits, nothing read back between them);
 *  7 an index buffer freed and its GL name reused by another buffer (two submits);
 *  8 an index buffer written between two indexed draws (a transfer binds it to its
 *    target, which is the VAO's element buffer binding);
 *  9 points and triangles alternating.
 * White-box (OMACVM_VIRGL_CACHE_STATS=1, set here: the renderer logs its counter totals
 * when a context ends):
 * 10 16 identical draws (8 plain, 8 indexed): one shader select, 15 vertex setups and 14
 *    element binds skipped (OMACVM_VIRGL_SELECT_CACHE=0: 16 selects;
 *    OMACVM_VIRGL_VERTEX_CACHE=0: nothing skipped);
 * 11 a sampler view with shader key bits unbound, the rasterizer unbound, the vertex
 *    elements unbound: each next draw selects the shaders again.
 * 12 one program and one vertex elements object, the colour buffer switched between draws:
 *    another buffer at the same stride and offset, then another offset in that buffer
 *    (each draw reads its own buffer and offset);
 * 13 vertex elements freed while bound and new ones made at once (they likely get the
 *    freed memory, and the record keeps a pointer): the colour comes from another offset.
 * Sampler views whose key bits change are in test-view-key.c (a pixel case would need a
 * program that samples a texture buffer: linking one crashes Apple's software renderer).
 * Run as is, with OMACVM_VIRGL_SELECT_CACHE=0 and with OMACVM_VIRGL_VERTEX_CACHE=0.
 * Usage: test-vertex-binds [case] */
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
       TEST_SHADER_FRAGMENT = 1, TEST_PRIM_POINTS = 0, TEST_PRIM_TRIANGLES = 4,
       TEST_CLEAR_COLOR0 = 1 << 2 };

/* RGBA8 pixels as read back (little endian: 0xAABBGGRR) */
enum { RED = 0xff0000ff, GREEN = 0xff00ff00, BLUE = 0xffff0000,
       MAGENTA = 0xffff00ff };

/* resources of a context: handle = 1000 * ctx + R_* */
enum { R_RT = 1, R_POS, R_COL, R_COL8, R_C0, R_IB, R_TBO, R_TMP, R_TMP2, R_COUNT };
/* objects */
enum { VS_COLOR = 10, VS_COLOR2, FS_VARYING, VE_F = 20, VE_I, VE_RGBA8, VE_BGRA8, VE_B, VE_3,
       VE_S, VIEW_L8 = 30, SURFACE = 40, BLEND, RS };

static CGLContextObj main_ctx;
static int failures;
static int select_cache = 1, vertex_cache = 1;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

/* The renderer's counter totals, from its "totals" log line when a context ends. */
static struct totals { unsigned long long draws, selects, vertex_skips, element_skips; } last;

static void log_cb(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)data;
   struct totals t;
   const char *p = strstr(message, "totals draws");
   if (p && sscanf(p, "totals draws %llu selects %llu vertex-skips %llu element-skips %llu",
                   &t.draws, &t.selects, &t.vertex_skips, &t.element_skips) == 4)
      last = t;
   else if (level >= VIRGL_LOG_LEVEL_WARNING)
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
   uint32_t dw[8192];
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

/* elements: {src_offset, vertex buffer index, format} each */
static void emit_ve(struct cmds *c, uint32_t handle, unsigned n, const uint32_t (*e)[3])
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                      VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(n)));
   emit(c, handle);
   for (unsigned i = 0; i < n; i++) {
      emit(c, e[i][0]);
      emit(c, 0);                   /* instance divisor */
      emit(c, e[i][1]);
      emit(c, e[i][2]);
   }
}

static void emit_bind_ve(struct cmds *c, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(c, handle);
}

/* buffers: {stride, offset, handle} each */
static void emit_vbs(struct cmds *c, unsigned n, const uint32_t (*b)[3])
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, VIRGL_SET_VERTEX_BUFFERS_SIZE(n)));
   for (unsigned i = 0; i < n; i++) {
      emit(c, b[i][0]);
      emit(c, b[i][1]);
      emit(c, b[i][2]);
   }
}

/* position, float colour, 8-bit colour */
static void emit_default_vbs(struct cmds *c, int ctx)
{
   emit_vbs(c, 3, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_POS) },
                                         { 16, 0, res_id(ctx, R_COL) },
                                         { 4, 0, res_id(ctx, R_COL8) } });
}

static void emit_ib(struct cmds *c, uint32_t handle)
{
   if (!handle) {
      emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_INDEX_BUFFER, 0, VIRGL_SET_INDEX_BUFFER_SIZE(0)));
      emit(c, 0);
      return;
   }
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_INDEX_BUFFER, 0, VIRGL_SET_INDEX_BUFFER_SIZE(1)));
   emit(c, handle);
   emit(c, 2);                      /* uint16 indices */
   emit(c, 0);                      /* offset */
}

static void emit_write(struct cmds *c, uint32_t handle, uint32_t offset, const void *data,
                       uint32_t bytes)
{
   uint32_t words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(c, handle);
   emit(c, 0);                      /* level */
   emit(c, 0);                      /* usage */
   emit(c, 0);                      /* stride */
   emit(c, 0);                      /* layer stride */
   emit(c, offset);                 /* x */
   emit(c, 0);
   emit(c, 0);
   emit(c, bytes);                  /* w */
   emit(c, 1);
   emit(c, 1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

static void emit_draw(struct cmds *c, uint32_t start, uint32_t count, uint32_t mode,
                      uint32_t indexed)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, start);
   emit(c, count);
   emit(c, mode);
   emit(c, indexed);
   emit(c, 0);                      /* instances */
   emit(c, 0);                      /* index bias */
   emit(c, 0);                      /* start instance */
   emit(c, 0);                      /* primitive restart */
   emit(c, 0);                      /* restart index */
   emit(c, 0);                      /* min index */
   emit(c, 0xffffffff);             /* max index */
   emit(c, 0);                      /* count from stream output */
}

/* the triangle of vertices 0-2 (red) or 3-5 (green) */
static void emit_triangle(struct cmds *c, int green)
{
   emit_draw(c, green ? 3 : 0, 3, TEST_PRIM_TRIANGLES, 0);
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
   emit_float(c, 1);                /* magenta */
   emit_float(c, 0);
   emit_float(c, 1);
   emit_float(c, 1);
   emit(c, 0);                      /* depth (double) */
   emit(c, 0);
   emit(c, 0);                      /* stencil */
}

/* a buffer sampler view of elements [first, last] */
static void emit_buffer_view(struct cmds *c, uint32_t handle, uint32_t res, uint32_t format,
                             uint32_t first, uint32_t last)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_VIEW,
                      VIRGL_OBJ_SAMPLER_VIEW_SIZE));
   emit(c, handle);
   emit(c, res);
   emit(c, format | TEST_PIPE_BUFFER << 24);
   emit(c, first);
   emit(c, last);
   emit(c, 0 | 1 << 3 | 2 << 6 | 3 << 9);   /* identity swizzle */
}

static void emit_fs_view(struct cmds *c, uint32_t handle)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_SAMPLER_VIEWS, 0, VIRGL_SET_SAMPLER_VIEWS_SIZE(1)));
   emit(c, TEST_SHADER_FRAGMENT);
   emit(c, 0);
   emit(c, handle);
}

static const char *vs_color =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL IN[1]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], IN[1]\n"
   "  2: END\n";

/* declares IN[1] without reading it (no attribute location), takes the colour from IN[2] */
static const char *vs_color2 =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL IN[1]\n"
   "DCL IN[2]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MOV OUT[1], IN[2]\n"
   "  2: END\n";

static const char *fs_varying =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
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

static uint32_t gl_name(int ctx, int r)
{
   struct virgl_renderer_resource_info info;
   memset(&info, 0, sizeof(info));
   if (virgl_renderer_resource_get_info(res_id(ctx, r), &info))
      return 0;
   return info.tex_id;
}

/* A context with a 16x16 colour buffer and:
 *  POS:  7 positions (RGBA32F): 0-2 and 3-5 a triangle over the whole viewport, 6 its
 *        middle (for points);
 *  COL:  7 colours (RGBA32F): 0-2 red, 3-5 green, 6 blue;
 *  COL8: 7 colours (RGBA8 bytes 255, 0, 0, 255: red as RGBA, blue as BGRA);
 *  C0:   one RGBA32F colour (stride 0), red;
 *  IB:   uint16 indices 0-5;
 *  TBO:  a texture buffer and an L8 view of it (its shader key bits: RRR1). */
static void setup(struct cmds *c, int ctx)
{
   char name[16];
   snprintf(name, sizeof(name), "vertex-%d", ctx);
   virgl_renderer_context_create(ctx, strlen(name), name);

   struct virgl_renderer_resource_create_args rt = {
      .handle = res_id(ctx, R_RT), .target = TEST_PIPE_TEXTURE_2D,
      .format = VIRGL_FORMAT_R8G8B8A8_UNORM, .bind = VIRGL_BIND_RENDER_TARGET, .width = 16,
      .height = 16, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&rt, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx, res_id(ctx, R_RT));
   make_buffer(ctx, R_POS, VIRGL_BIND_VERTEX_BUFFER, 7 * 16);
   make_buffer(ctx, R_COL, VIRGL_BIND_VERTEX_BUFFER, 7 * 16);
   make_buffer(ctx, R_COL8, VIRGL_BIND_VERTEX_BUFFER, 7 * 4);
   make_buffer(ctx, R_C0, VIRGL_BIND_VERTEX_BUFFER, 16);
   make_buffer(ctx, R_IB, VIRGL_BIND_INDEX_BUFFER, 12);
   make_buffer(ctx, R_TBO, VIRGL_BIND_SAMPLER_VIEW, 64);

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
   /* depth clip, points 4 pixels wide */
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(c, RS);
   emit(c, VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   emit_float(c, 4.0f);
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 3; i++)
      emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, RS);

   emit_shader(c, VS_COLOR, TEST_SHADER_VERTEX, vs_color);
   emit_shader(c, VS_COLOR2, TEST_SHADER_VERTEX, vs_color2);
   emit_shader(c, FS_VARYING, TEST_SHADER_FRAGMENT, fs_varying);
   emit_bind_shader(c, VS_COLOR, TEST_SHADER_VERTEX);
   emit_bind_shader(c, FS_VARYING, TEST_SHADER_FRAGMENT);

   const uint32_t f = VIRGL_FORMAT_R32G32B32A32_FLOAT;
   emit_ve(c, VE_F, 2, (const uint32_t[][3]){ { 0, 0, f }, { 0, 1, f } });
   emit_ve(c, VE_I, 2, (const uint32_t[][3]){ { 0, 0, f },
                                               { 0, 1, VIRGL_FORMAT_R32G32B32A32_SINT } });
   emit_ve(c, VE_RGBA8, 2, (const uint32_t[][3]){ { 0, 0, f },
                                                   { 0, 2, VIRGL_FORMAT_R8G8B8A8_UNORM } });
   emit_ve(c, VE_BGRA8, 2, (const uint32_t[][3]){ { 0, 0, f },
                                                   { 0, 2, VIRGL_FORMAT_B8G8R8A8_UNORM } });
   emit_ve(c, VE_B, 2, (const uint32_t[][3]){ { 0, 0, f }, { 48, 1, f } });
   emit_ve(c, VE_3, 3, (const uint32_t[][3]){ { 0, 0, f }, { 0, 1, f }, { 48, 1, f } });
   emit_ve(c, VE_S, 2, (const uint32_t[][3]){ { 0, 0, f }, { 0, 1, f } });
   emit_bind_ve(c, VE_F);
   emit_default_vbs(c, ctx);

   const float tri[4] = { -1, -1, 0, 1 }, tri1[4] = { 3, -1, 0, 1 }, tri2[4] = { -1, 3, 0, 1 };
   float pos[7][4], col[7][4];
   for (int v = 0; v < 7; v++) {
      const float *p = v == 6 ? (const float[4]){ 0, 0, 0, 1 } :
                       v % 3 == 0 ? tri : v % 3 == 1 ? tri1 : tri2;
      memcpy(pos[v], p, sizeof(pos[v]));
      const float red[4] = { 1, 0, 0, 1 }, green[4] = { 0, 1, 0, 1 }, blue[4] = { 0, 0, 1, 1 };
      memcpy(col[v], v < 3 ? red : v < 6 ? green : blue, sizeof(col[v]));
   }
   emit_write(c, res_id(ctx, R_POS), 0, pos, sizeof(pos));
   emit_write(c, res_id(ctx, R_COL), 0, col, sizeof(col));
   uint8_t col8[7][4];
   for (int v = 0; v < 7; v++)
      memcpy(col8[v], (const uint8_t[4]){ 255, 0, 0, 255 }, 4);
   emit_write(c, res_id(ctx, R_COL8), 0, col8, sizeof(col8));
   emit_write(c, res_id(ctx, R_C0), 0, col[0], 16);
   const uint16_t idx[6] = { 0, 1, 2, 3, 4, 5 };
   emit_write(c, res_id(ctx, R_IB), 0, idx, sizeof(idx));
   emit_buffer_view(c, VIEW_L8, res_id(ctx, R_TBO), VIRGL_FORMAT_L8_UNORM, 0, 63);
   emit_clear(c);
   check(submit(ctx, c) == 0, "setup");
}

static void teardown(int ctx)
{
   virgl_renderer_context_destroy(ctx);
   for (int r = R_RT; r < R_COUNT; r++)
      virgl_renderer_resource_unref(res_id(ctx, r));
}

/* the middle pixel of each stripe */
static void read_stripes(int ctx, uint32_t got[4])
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   if (virgl_renderer_transfer_read_iov(res_id(ctx, R_RT), ctx, 0, 16 * 4, 0, &box, 0, &iov, 1))
      memset(pixels, 0xff, sizeof(pixels));
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

/* Integer attributes of the program bound now (the last draw's), -1 without one. */
static int int_attributes(void)
{
   GLint prog = 0, n = 0, ints = 0;
   glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
   if (!prog)
      return -1;
   glGetProgramiv(prog, GL_ACTIVE_ATTRIBUTES, &n);
   for (GLint i = 0; i < n; i++) {
      char name[64];
      GLint size;
      GLenum type;
      glGetActiveAttrib(prog, i, sizeof(name), NULL, &size, &type, name);
      ints += type == GL_INT || type == GL_INT_VEC2 || type == GL_INT_VEC3 ||
              type == GL_INT_VEC4;
   }
   return ints;
}

static void case_int_float(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, GREEN, RED, GREEN };
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_bind_ve(c, s & 1 ? VE_I : VE_F);
      emit_triangle(c, s & 1);
   }
   check(submit(ctx, c) == 0, "float, integer, float, integer colours on one program");
   check(int_attributes() == 1, "after the integer draw the program has an integer attribute");
   check_stripes(ctx, 4, want, "float/integer elements");

   static const uint32_t want2[4] = { GREEN, RED, GREEN, RED };
   emit_clear(c);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_bind_ve(c, s & 1 ? VE_F : VE_I);
      emit_triangle(c, !(s & 1));
   }
   check(submit(ctx, c) == 0, "integer, float, integer, float colours on one program");
   check(int_attributes() == 0, "after the float draw the program has no integer attribute");
   check_stripes(ctx, 4, want2, "integer/float elements");
}

static void case_bgra(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, BLUE, RED, BLUE };
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_bind_ve(c, s & 1 ? VE_BGRA8 : VE_RGBA8);
      emit_triangle(c, 0);
   }
   check(submit(ctx, c) == 0, "RGBA and BGRA colours on one program");
   check_stripes(ctx, 4, want, "RGBA/BGRA elements");
}

static void case_two_ve(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, GREEN, RED, GREEN };
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_bind_ve(c, s & 1 ? VE_B : VE_F);
      emit_triangle(c, 0);
   }
   check(submit(ctx, c) == 0, "two vertex elements objects alternating");
   check_stripes(ctx, 4, want, "two vertex elements objects");
}

static void case_program_switch(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, GREEN, RED, GREEN };
   emit_bind_ve(c, VE_3);
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      emit_bind_shader(c, s & 1 ? VS_COLOR2 : VS_COLOR, TEST_SHADER_VERTEX);
      emit_triangle(c, 0);
   }
   check(submit(ctx, c) == 0, "programs with the colour at other attributes alternating");
   check_stripes(ctx, 4, want, "program switch");
}

static void case_stride0(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, GREEN, BLUE, RED };
   static const float colours[4][4] = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 },
                                        { 1, 0, 0, 1 } };
   emit_bind_ve(c, VE_S);
   emit_vbs(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_POS) },
                                         { 0, 0, res_id(ctx, R_C0) } });
   for (int s = 0; s < 4; s++) {
      emit_write(c, res_id(ctx, R_C0), 0, colours[s], 16);
      emit_stripe(c, s);
      emit_triangle(c, 0);
   }
   check(submit(ctx, c) == 0, "a stride-0 colour written between draws");
   check_stripes(ctx, 4, want, "stride-0 colour");
}

/* Draw, free a buffer, make a new one that likely gets its GL name, draw from that one in
 * the same place: the second draw must use the new buffer. No read-back in between. */
static void case_name_reuse(struct cmds *c, int ctx, int index_buffer)
{
   static const uint32_t want[2] = { RED, GREEN };
   const char *what = index_buffer ? "index buffer" : "vertex buffer";
   char text[160];

   make_buffer(ctx, R_TMP, index_buffer ? VIRGL_BIND_INDEX_BUFFER : VIRGL_BIND_VERTEX_BUFFER,
               index_buffer ? 6 : 3 * 16);
   if (index_buffer) {
      const uint16_t idx[3] = { 0, 1, 2 };
      emit_write(c, res_id(ctx, R_TMP), 0, idx, sizeof(idx));
      emit_ib(c, res_id(ctx, R_TMP));
      emit_stripe(c, 0);
      emit_draw(c, 0, 3, TEST_PRIM_TRIANGLES, 1);
      emit_ib(c, 0);
   } else {
      const float red[3][4] = { { 1, 0, 0, 1 }, { 1, 0, 0, 1 }, { 1, 0, 0, 1 } };
      emit_write(c, res_id(ctx, R_TMP), 0, red, sizeof(red));
      emit_vbs(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_POS) },
                                            { 16, 0, res_id(ctx, R_TMP) } });
      emit_stripe(c, 0);
      emit_triangle(c, 0);
      emit_vbs(c, 1, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_POS) } });
   }
   snprintf(text, sizeof(text), "draw from a %s, then unbind it", what);
   check(submit(ctx, c) == 0, text);

   uint32_t old_name = gl_name(ctx, R_TMP);
   virgl_renderer_ctx_detach_resource(ctx, res_id(ctx, R_TMP));
   virgl_renderer_resource_unref(res_id(ctx, R_TMP));
   /* a vertex buffer either way: creating it binds GL_ARRAY_BUFFER, not the element
    * buffer, so only the freed name tells the cache */
   make_buffer(ctx, R_TMP2, VIRGL_BIND_VERTEX_BUFFER, index_buffer ? 6 : 3 * 16);
   uint32_t new_name = gl_name(ctx, R_TMP2);
   if (old_name != new_name)
      printf("note: the GL gave the new %s another name (%u, was %u): the reuse is not "
             "exercised\n", what, new_name, old_name);

   if (index_buffer) {
      const uint16_t idx[3] = { 3, 4, 5 };
      emit_write(c, res_id(ctx, R_TMP2), 0, idx, sizeof(idx));
      emit_ib(c, res_id(ctx, R_TMP2));
      emit_stripe(c, 1);
      emit_draw(c, 0, 3, TEST_PRIM_TRIANGLES, 1);
   } else {
      const float green[3][4] = { { 0, 1, 0, 1 }, { 0, 1, 0, 1 }, { 0, 1, 0, 1 } };
      emit_write(c, res_id(ctx, R_TMP2), 0, green, sizeof(green));
      emit_vbs(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_POS) },
                                            { 16, 0, res_id(ctx, R_TMP2) } });
      emit_stripe(c, 1);
      emit_triangle(c, 0);
   }
   snprintf(text, sizeof(text), "draw from a new %s with the freed one's name", what);
   check(submit(ctx, c) == 0, text);
   snprintf(text, sizeof(text), "%s freed and its name reused", what);
   check_stripes(ctx, 2, want, text);
}

static void case_index_write(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, GREEN, GREEN, RED };
   const uint16_t red[3] = { 0, 1, 2 }, green[3] = { 3, 4, 5 };
   emit_ib(c, res_id(ctx, R_IB));
   for (int s = 0; s < 4; s++) {
      emit_write(c, res_id(ctx, R_IB), 0, s == 1 || s == 2 ? green : red, 6);
      emit_stripe(c, s);
      emit_draw(c, 0, 3, TEST_PRIM_TRIANGLES, 1);
   }
   check(submit(ctx, c) == 0, "indexed draws with the index buffer written between them");
   check_stripes(ctx, 4, want, "index buffer written between draws");
}

static void case_points(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, BLUE, RED, BLUE };
   for (int s = 0; s < 4; s++) {
      emit_stripe(c, s);
      if (s & 1)
         emit_draw(c, 6, 1, TEST_PRIM_POINTS, 0);
      else
         emit_triangle(c, 0);
   }
   check(submit(ctx, c) == 0, "triangles and points alternating");
   check_stripes(ctx, 4, want, "triangles/points");
}

/* Only the vertex buffer behind an attribute changes (program, elements, stride stay):
 * the recorded setup must not hide another buffer or another offset. */
static void case_buffer_switch(struct cmds *c, int ctx)
{
   static const uint32_t want[4] = { RED, BLUE, GREEN, RED };
   const float blue[4] = { 0, 0, 1, 1 }, green[4] = { 0, 1, 0, 1 };
   float tmp[6][4];
   for (int v = 0; v < 6; v++)
      memcpy(tmp[v], v < 3 ? blue : green, sizeof(tmp[v]));
   make_buffer(ctx, R_TMP, VIRGL_BIND_VERTEX_BUFFER, sizeof(tmp));
   emit_write(c, res_id(ctx, R_TMP), 0, tmp, sizeof(tmp));
   static const struct { int r; uint32_t offset; } col[4] = {
      { R_COL, 0 },    /* red */
      { R_TMP, 0 },    /* another buffer, same stride and offset: blue */
      { R_TMP, 48 },   /* the same buffer at another offset: green */
      { R_COL, 0 },    /* back to the first: red */
   };
   for (int s = 0; s < 4; s++) {
      emit_vbs(c, 2, (const uint32_t[][3]){ { 16, 0, res_id(ctx, R_POS) },
                                            { 16, col[s].offset, res_id(ctx, col[s].r) } });
      emit_stripe(c, s);
      emit_triangle(c, 0);
   }
   check(submit(ctx, c) == 0, "the colour buffer and its offset switched between draws");
   check_stripes(ctx, 4, want, "vertex buffer switch");
}

/* VE_F drawn, freed while bound, a new object with the colour 48 bytes further on made and
 * bound at once, drawn: the second draw must use the new object's offsets. */
static void case_ve_reuse(struct cmds *c, int ctx)
{
   static const uint32_t want[2] = { RED, GREEN };
   const uint32_t f = VIRGL_FORMAT_R32G32B32A32_FLOAT;
   emit_stripe(c, 0);
   emit_triangle(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(c, VE_F);
   emit_ve(c, VE_F, 2, (const uint32_t[][3]){ { 0, 0, f }, { 48, 1, f } });
   emit_bind_ve(c, VE_F);
   emit_stripe(c, 1);
   emit_triangle(c, 0);
   check(submit(ctx, c) == 0, "vertex elements freed while bound, new ones made and drawn");
   check_stripes(ctx, 2, want, "vertex elements freed and made again");
}

/* the counters the renderer logged when the case's context ended, less those before */
static struct totals totals_before;

static struct totals delta(void)
{
   struct totals d = {
      last.draws - totals_before.draws, last.selects - totals_before.selects,
      last.vertex_skips - totals_before.vertex_skips,
      last.element_skips - totals_before.element_skips,
   };
   return d;
}

static void case_counts(struct cmds *c, int ctx)
{
   unsigned long draws = gl_oracle_draws();
   emit_ib(c, res_id(ctx, R_IB));
   for (int i = 0; i < 16; i++)
      emit_draw(c, 0, 3, TEST_PRIM_TRIANGLES, i >= 8);
   check(submit(ctx, c) == 0, "16 identical draws (8 plain, 8 indexed)");
   check(gl_oracle_draws() - draws == 16, "all 16 reached the GL");
}

static void check_counts(void)
{
   struct totals d = delta();
   char text[200];
   snprintf(text, sizeof(text), "16 identical draws: %llu draws, %llu selects, %llu vertex "
            "setups and %llu element binds skipped", d.draws, d.selects, d.vertex_skips,
            d.element_skips);
   check(d.draws == 16, text);
   check(d.selects == (select_cache ? 1 : 16),
         select_cache ? "the shaders are selected once" :
                        "OMACVM_VIRGL_SELECT_CACHE=0: the shaders are selected for every draw");
   check(d.vertex_skips == (vertex_cache ? 15 : 0),
         vertex_cache ? "15 vertex setups skipped" :
                        "OMACVM_VIRGL_VERTEX_CACHE=0: no vertex setup skipped");
   check(d.element_skips == (vertex_cache ? 14 : 0),
         vertex_cache ? "14 element binds skipped (one per change)" :
                        "OMACVM_VIRGL_VERTEX_CACHE=0: no element bind skipped");
}

static void case_unbinds(struct cmds *c, int ctx)
{
   /* view L8 (key bits) on a fragment shader that does not sample it */
   emit_fs_view(c, VIEW_L8);
   emit_triangle(c, 0);
   emit_fs_view(c, 0);
   emit_triangle(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(c, 0);
   emit_triangle(c, 0);
   emit_bind_ve(c, 0);
   emit_triangle(c, 0);
   check(submit(ctx, c) == 0, "draws after a sampler view, the rasterizer, the elements unbound");
}

static void check_unbinds(void)
{
   struct totals d = delta();
   char text[200];
   snprintf(text, sizeof(text), "every unbind selects the shaders again (%llu selects for "
            "4 draws)", d.selects);
   check(d.draws == 4 && d.selects == 4, text);
}

static void run_case(int n)
{
   static struct cmds c;
   int ctx = n;
   printf("case %d\n", n);
   c.n = 0;
   setup(&c, ctx);
   switch (n) {
   case 1: case_int_float(&c, ctx); break;
   case 2: case_bgra(&c, ctx); break;
   case 3: case_two_ve(&c, ctx); break;
   case 4: case_program_switch(&c, ctx); break;
   case 5: case_stride0(&c, ctx); break;
   case 6: case_name_reuse(&c, ctx, 0); break;
   case 7: case_name_reuse(&c, ctx, 1); break;
   case 8: case_index_write(&c, ctx); break;
   case 9: case_points(&c, ctx); break;
   case 10: case_counts(&c, ctx); break;
   case 11: case_unbinds(&c, ctx); break;
   case 12: case_buffer_switch(&c, ctx); break;
   case 13: case_ve_reuse(&c, ctx); break;
   }
   teardown(ctx);
   if (n == 10)
      check_counts();
   if (n == 11)
      check_unbinds();
   totals_before = last;
}

int main(int argc, char **argv)
{
   int only = argc > 1 ? atoi(argv[1]) : 0;
   const char *env;

   setvbuf(stdout, NULL, _IONBF, 0);
   env = getenv("OMACVM_VIRGL_SELECT_CACHE");
   select_cache = !(env && !strcmp(env, "0"));
   env = getenv("OMACVM_VIRGL_VERTEX_CACHE");
   vertex_cache = !(env && !strcmp(env, "0"));
   printf("shader select cache %s, vertex cache %s\n", select_cache ? "on" : "off",
          vertex_cache ? "on" : "off");
   /* the counters for the white-box cases; integer vertex inputs as on the Mac's GPU
    * (the software renderer's vendor string is not "Apple") */
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

   for (int n = 1; n <= 13; n++)
      if (!only || only == n)
         run_case(n);

   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "vertex binds: FAILED" : "vertex binds: all checks passed");
   return failures != 0;
}
