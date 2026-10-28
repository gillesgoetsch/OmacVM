/* A texture the guest samples at a smaller size than it is (virgl-resource-logical-size.patch):
 * the guest's VA-API driver makes a video surface's planes with width and height rounded up
 * to 16 (a 1920x1080 surface has 1088 rows, 854 wide has 864 columns) and apps sample the
 * whole plane by normalized coordinates (mpv, Chrome's NV12 frames, GStreamer): the picture
 * was squeezed and the rows past it (the edge fill: its last row) showed as a strip at the
 * bottom. The guest now says the picture's size in a VIRGL_CCMD_NOP payload ("OMLS", version
 * 1, resource/width/height) and the shaders that sample such a texture scale their
 * coordinates and size queries to it.
 *
 * Through the public renderer API on Apple's software renderer (soft-gl.h; never on the GPU).
 * Context A owns the textures and declares them (the guest's VA-API driver), context B draws
 * with them (the app that shows the video). A 300x180 picture sits in a 320x192 texture whose
 * padding is a marker (magenta), declared 300x180; the same picture in a true 300x180
 * texture is the reference. Fragment shaders in TGSI, as Mesa sends them:
 *  1 TEX, TXP, TXB, TXL, TXD (nearest, into 300x180): every pixel is the reference's and the
 *    picture's own texel; the marker never shows;
 *  2 the same lookups linear into 540x324 (1.8x): within 1 of the reference per channel;
 *  3 TXQ: the size the shader sees is 300x180;
 *  4 an R8 plane 320x192 and an RG8 plane 160x96 declared 300x180 and 150x90 (NV12's planes),
 *    and a 2D-array texture of one layer through a 2D_ARRAY sampler; a 2D texture through a
 *    2D_ARRAY sampler (Mesa's video compositor declares its planes so);
 *  5 TG4 on a texture whose padding repeats the picture's edge (the host's edge fill, as for
 *    every decoded picture): the reference's gathers;
 *  6 an RGBA texture with transparent padding, linear at 1.8x: no alpha from the padding;
 *  7 one program, two textures of different logical sizes in turn, and an undeclared one
 *    after them: each draw at its own size;
 *  8 a texture nobody declared reads as before: the whole texture (the marker in the last row
 *    and columns); a declaration of its own size takes the logical size away again;
 *  9 reading the texture back (a transfer) gives all 192 rows, marker included: logical sizes
 *    are for sampling only;
 * 10 declarations that do not fit are ignored and the context goes on: an unknown handle, a
 *    resource of another context, a buffer, a 3D texture, a texture with two levels, zero
 *    or larger sizes, a payload of 9 entries, a wrong length, version or magic; the
 *    declared size stays, and a draw after them is drawn.
 * With OMACVM_VIDEO_LOGICAL=0 in the environment the renderer ignores every declaration: the
 * test then expects the squeezed picture with the marker (what the guest saw before), so it
 * shows it can see the strip.
 * Usage: test-video-logical-size */
#include <OpenGL/OpenGL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

enum { T_BUFFER = 0, T_2D = 2, T_3D = 3, T_2D_ARRAY = 7, SH_VERTEX = 0, SH_FRAGMENT = 1,
       PRIM_TRIANGLES = 4, CLEAR_COLOR0 = 1 << 2 };
enum { CTX_A = 1, CTX_B = 2, CTX_C = 3 };
/* resources */
enum { R_PAD = 10, R_TRUE, R_FILL, R_FILLTRUE, R_Y, R_YTRUE, R_UV, R_UVTRUE, R_ARR, R_ALPHA,
       R_ALPHATRUE, R_SMALL, R_SMALLTRUE, R_PLAIN, R_RT1, R_RT2, R_POS, R_BUF, R_3D, R_MIP,
       R_OTHER };
/* objects in B */
enum { VS = 1, FS_TEX, FS_TXP, FS_TXB, FS_TXL, FS_TXD, FS_TXQ, FS_TG4, FS_ARR, FS_TEXR, VE,
       SURF1, SURF2, BLEND, RS, SAMP_NEAREST, SAMP_LINEAR, VIEW = 100 };

#define PW 300               /* the picture */
#define PH 180
#define TW 320               /* its texture (rounded up to 16) */
#define TH 192
#define MARKER 0xffff00ffu   /* magenta, RGBA8 as read back (0xAABBGGRR) */

static CGLContextObj main_ctx;
static int cookie;
static int failures;
static int logical_on = 1;   /* OMACVM_VIDEO_LOGICAL=0: the renderer ignores declarations */

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void log_cb(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)data;
   if (level >= VIRGL_LOG_LEVEL_WARNING)
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
   uint32_t dw[16384];
   unsigned n;
};
static struct cmds cmd;

static void emit(uint32_t v)
{
   if (cmd.n < sizeof(cmd.dw) / 4)
      cmd.dw[cmd.n++] = v;
}

static void emit_float(float f)
{
   uint32_t u;
   memcpy(&u, &f, 4);
   emit(u);
}

static int submit(int ctx)
{
   int r = virgl_renderer_submit_cmd(cmd.dw, ctx, cmd.n);
   cmd.n = 0;
   return r;
}

/* ---- resources ---- */

static void make_resource(uint32_t handle, uint32_t target, uint32_t format, uint32_t bind,
                          uint32_t w, uint32_t h, uint32_t depth, uint32_t layers,
                          uint32_t last_level)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = handle, .target = target, .format = format, .bind = bind, .width = w,
      .height = h, .depth = depth, .array_size = layers, .last_level = last_level,
   };
   if (virgl_renderer_resource_create(&a, NULL, 0))
      printf("note: resource %u not created\n", handle);
}

static void attach(int ctx, uint32_t handle)
{
   virgl_renderer_ctx_attach_resource(ctx, handle);
}

static void make_texture(uint32_t handle, uint32_t target, uint32_t format, uint32_t w, uint32_t h)
{
   make_resource(handle, target, format, VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, w, h,
                 1, 1, 0);
   attach(CTX_A, handle);
   attach(CTX_B, handle);
}

static int upload(int ctx, uint32_t handle, const void *data, uint32_t bpp, uint32_t w, uint32_t h)
{
   struct iovec iov = { (void *)data, (size_t)w * h * bpp };
   struct virgl_box box = { 0, 0, 0, w, h, 1 };
   return virgl_renderer_transfer_write_iov(handle, ctx, 0, w * bpp, 0, &box, 0, &iov, 1);
}

static int download(int ctx, uint32_t handle, void *data, uint32_t bpp, uint32_t w, uint32_t h)
{
   struct iovec iov = { data, (size_t)w * h * bpp };
   struct virgl_box box = { 0, 0, 0, w, h, 1 };
   memset(data, 0x11, (size_t)w * h * bpp);
   return virgl_renderer_transfer_read_iov(handle, ctx, 0, w * bpp, 0, &box, 0, &iov, 1);
}

/* the picture: smooth enough that 1.8x linear stays within 1 of the reference */
static uint32_t picture(uint32_t x, uint32_t y)
{
   uint32_t r = (x * 255) / (PW - 1), g = (y * 255) / (PH - 1), b = ((x + 2 * y) * 3) & 0xff;
   return 0xff000000u | b << 16 | g << 8 | r;
}

/* a TW x TH RGBA texture with the picture at 0,0; the rest MARKER, or (fill) the picture's
 * last row and column repeated as the host's edge fill writes them, or transparent (alpha) */
enum pad { PAD_MARKER, PAD_FILL, PAD_ALPHA };
static void picture_texture(uint32_t *t, uint32_t tw, uint32_t th, uint32_t pw, uint32_t ph,
                            enum pad pad)
{
   for (uint32_t y = 0; y < th; y++)
      for (uint32_t x = 0; x < tw; x++) {
         uint32_t px = x < pw ? x : pw - 1, py = y < ph ? y : ph - 1;
         int inside = x < pw && y < ph;
         t[y * tw + x] = inside || pad == PAD_FILL ? picture(px, py) :
                         pad == PAD_MARKER ? MARKER : 0x00000000u;
      }
}

/* ---- commands (context B draws) ---- */

static void nop_logical(uint32_t n, const uint32_t (*e)[3])
{
   emit(VIRGL_CMD0(VIRGL_CCMD_NOP, 0, 2 + 3 * n));
   emit(0x534c4d4fu);   /* "OMLS" */
   emit(1);
   for (uint32_t i = 0; i < n; i++) {
      emit(e[i][0]);
      emit(e[i][1]);
      emit(e[i][2]);
   }
}

static void declare(int ctx, uint32_t handle, uint32_t w, uint32_t h, const char *what)
{
   const uint32_t e[1][3] = { { handle, w, h } };
   nop_logical(1, e);
   check(submit(ctx) == 0, what);
}

static void emit_shader(uint32_t handle, uint32_t type, const char *text)
{
   uint32_t bytes = strlen(text) + 1, words = (bytes + 3) / 4;
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SHADER, 5 + words));
   emit(handle);
   emit(type);
   emit(VIRGL_OBJ_SHADER_OFFSET_VAL(bytes));
   emit(300);
   emit(0);
   memset(&cmd.dw[cmd.n], 0, words * 4);
   memcpy(&cmd.dw[cmd.n], text, bytes);
   cmd.n += words;
}

static void bind_shader(uint32_t handle, uint32_t type)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_BIND_SHADER, 0, 2));
   emit(handle);
   emit(type);
}

static void emit_sampler(uint32_t handle, int linear)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_STATE,
                   VIRGL_OBJ_SAMPLER_STATE_SIZE));
   emit(handle);
   emit(VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_S(2) | VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_T(2) |
        VIRGL_OBJ_SAMPLE_STATE_S0_WRAP_R(2) | VIRGL_OBJ_SAMPLE_STATE_S0_MIN_MIP_FILTER(2) |
        VIRGL_OBJ_SAMPLE_STATE_S0_MIN_IMG_FILTER(linear) |
        VIRGL_OBJ_SAMPLE_STATE_S0_MAG_IMG_FILTER(linear));
   emit_float(0);
   emit_float(0);
   emit_float(0);
   for (int i = 0; i < 4; i++)
      emit(0);
}

static uint32_t next_view = VIEW;

/* a view of HANDLE (identity swizzle) in fragment slot 0, with SAMPLER */
static void bind_view(uint32_t handle, uint32_t target, uint32_t format, uint32_t sampler)
{
   uint32_t view = next_view++;
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_VIEW, VIRGL_OBJ_SAMPLER_VIEW_SIZE));
   emit(view);
   emit(handle);
   emit(format | target << 24);
   emit(0);                         /* layers 0..0 */
   emit(0);                         /* levels 0..0 */
   emit(0 | 1 << 3 | 2 << 6 | 3 << 9);
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_SAMPLER_VIEWS, 0, VIRGL_SET_SAMPLER_VIEWS_SIZE(1)));
   emit(SH_FRAGMENT);
   emit(0);
   emit(view);
   emit(VIRGL_CMD0(VIRGL_CCMD_BIND_SAMPLER_STATES, 0, 3));
   emit(SH_FRAGMENT);
   emit(0);
   emit(sampler);
}

/* the colour buffer RT (W x H) with its surface, cleared to grey */
static void target(uint32_t surface, uint32_t w, uint32_t h)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(1);
   emit(0);
   emit(surface);
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(0);
   emit_float(w / 2.0f);
   emit_float(h / 2.0f);
   emit_float(0.5f);
   emit_float(w / 2.0f);
   emit_float(h / 2.0f);
   emit_float(0.5f);
   emit(VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(CLEAR_COLOR0);
   emit_float(0.5f);
   emit_float(0.5f);
   emit_float(0.5f);
   emit_float(1);
   emit(0);
   emit(0);
   emit(0);
}

static void draw(void)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(0);
   emit(3);
   emit(PRIM_TRIANGLES);
   for (int i = 0; i < 6; i++)
      emit(0);
   emit(0);
   emit(0xffffffff);
   emit(0);
}

/* texture coordinates 0..1 over the viewport */
static const char *vs =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "IMM[0] FLT32 {    0.5000,     0.5000,     0.0000,     0.0000}\n"
   "IMM[1] FLT32 {    0.5000,     0.5000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: MAD OUT[1], IN[0], IMM[0], IMM[1]\n"
   "  2: END\n";

#define FS_HEAD(type) \
   "FRAG\n" \
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n" \
   "DCL OUT[0], COLOR\n" \
   "DCL SAMP[0]\n" \
   "DCL SVIEW[0], " type ", FLOAT\n" \
   "DCL TEMP[0..2]\n"

static const char *fs_tex =
   FS_HEAD("2D")
   "  0: TEX OUT[0], IN[0], SAMP[0], 2D\n"
   "  1: END\n";

/* (2s, 2t, 0, 2): projected back to (s, t) */
static const char *fs_txp =
   FS_HEAD("2D")
   "IMM[0] FLT32 {    2.0000,     2.0000,     0.0000,     0.0000}\n"
   "IMM[1] FLT32 {    0.0000,     0.0000,     0.0000,     2.0000}\n"
   "  0: MAD TEMP[0], IN[0], IMM[0], IMM[1]\n"
   "  1: TXP OUT[0], TEMP[0], SAMP[0], 2D\n"
   "  2: END\n";

static const char *fs_txb =
   FS_HEAD("2D")
   "IMM[0] FLT32 {    0.0000,     0.0000,     0.0000,     0.5000}\n"
   "  0: MOV TEMP[0], IMM[0]\n"
   "  1: MOV TEMP[0].xy, IN[0].xyxx\n"
   "  2: TXB OUT[0], TEMP[0], SAMP[0], 2D\n"
   "  3: END\n";

static const char *fs_txl =
   FS_HEAD("2D")
   "IMM[0] FLT32 {    0.0000,     0.0000,     0.0000,     0.0000}\n"
   "  0: MOV TEMP[0], IMM[0]\n"
   "  1: MOV TEMP[0].xy, IN[0].xyxx\n"
   "  2: TXL OUT[0], TEMP[0], SAMP[0], 2D\n"
   "  3: END\n";

static const char *fs_txd =
   FS_HEAD("2D")
   "  0: DDX TEMP[1], IN[0]\n"
   "  1: DDY TEMP[2], IN[0]\n"
   "  2: TXD OUT[0], IN[0], TEMP[1], TEMP[2], SAMP[0], 2D\n"
   "  3: END\n";

/* the size at level 0 / 1024 in red and green */
static const char *fs_txq =
   FS_HEAD("2D")
   "IMM[0] FLT32 {    0.0009765625,     0.0000,     0.0000,     1.0000}\n"
   "IMM[1] INT32 {0, 0, 0, 0}\n"
   "  0: TXQ TEMP[0].xy, IMM[1], SAMP[0], 2D\n"
   "  1: I2F TEMP[1], TEMP[0]\n"
   "  2: MUL OUT[0].xy, TEMP[1].xyxx, IMM[0].xxxx\n"
   "  3: MOV OUT[0].zw, IMM[0].yyyw\n"
   "  4: END\n";

/* the red channel of the 2x2 texels around the corner after (s, t)'s texel (half a texel of
 * the picture on: a gather at a texel's centre picks its footprint by rounding) */
static const char *fs_tg4 =
   FS_HEAD("2D")
   "IMM[0] FLT32 {    0.0016666667,     0.0027777778,     0.0000,     0.0000}\n"
   "IMM[1] INT32 {0, 0, 0, 0}\n"
   "  0: ADD TEMP[0], IN[0], IMM[0]\n"
   "  1: TG4 OUT[0], TEMP[0], IMM[1].xxxx, SAMP[0], 2D\n"
   "  2: END\n";

/* layer 0 through a 2D_ARRAY sampler, as Mesa's video compositor reads its planes */
static const char *fs_arr =
   FS_HEAD("2D_ARRAY")
   "IMM[0] FLT32 {    0.0000,     0.0000,     0.0000,     0.0000}\n"
   "  0: MOV TEMP[0], IMM[0]\n"
   "  1: MOV TEMP[0].xy, IN[0].xyxx\n"
   "  2: TEX OUT[0], TEMP[0], SAMP[0], 2D_ARRAY\n"
   "  3: END\n";

/* R8 and RG8 planes: their red and green, alpha 1 */
static const char *fs_texr =
   FS_HEAD("2D")
   "IMM[0] FLT32 {    0.0000,     0.0000,     0.0000,     1.0000}\n"
   "  0: TEX TEMP[0], IN[0], SAMP[0], 2D\n"
   "  1: MOV OUT[0], IMM[0]\n"
   "  2: MOV OUT[0].xy, TEMP[0].xyxx\n"
   "  3: END\n";

static void setup_b(void)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(SURF1);
   emit(R_RT1);
   emit(VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(0);
   emit(0);
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(SURF2);
   emit(R_RT2);
   emit(VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(0);
   emit(0);
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_BLEND, VIRGL_OBJ_BLEND_SIZE));
   emit(BLEND);
   emit(0);
   emit(0);
   for (int i = 0; i < VIRGL_MAX_COLOR_BUFS; i++)
      emit(VIRGL_OBJ_BLEND_S2_RT_COLORMASK(0xf));
   emit(VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_BLEND, 1));
   emit(BLEND);
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_RASTERIZER, VIRGL_OBJ_RS_SIZE));
   emit(RS);
   emit(VIRGL_OBJ_RS_S0_DEPTH_CLIP(1));
   emit_float(1.0f);
   for (int i = 0; i < VIRGL_OBJ_RS_SIZE - 3; i++)
      emit(0);
   emit(VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_RASTERIZER, 1));
   emit(RS);
   emit_shader(VS, SH_VERTEX, vs);
   emit_shader(FS_TEX, SH_FRAGMENT, fs_tex);
   emit_shader(FS_TXP, SH_FRAGMENT, fs_txp);
   emit_shader(FS_TXB, SH_FRAGMENT, fs_txb);
   emit_shader(FS_TXL, SH_FRAGMENT, fs_txl);
   emit_shader(FS_TXD, SH_FRAGMENT, fs_txd);
   emit_shader(FS_TXQ, SH_FRAGMENT, fs_txq);
   emit_shader(FS_TG4, SH_FRAGMENT, fs_tg4);
   emit_shader(FS_ARR, SH_FRAGMENT, fs_arr);
   emit_shader(FS_TEXR, SH_FRAGMENT, fs_texr);
   bind_shader(VS, SH_VERTEX);
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                   VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(1)));
   emit(VE);
   emit(0);
   emit(0);
   emit(0);
   emit(VIRGL_FORMAT_R32G32B32A32_FLOAT);
   emit(VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(VE);
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, VIRGL_SET_VERTEX_BUFFERS_SIZE(1)));
   emit(16);
   emit(0);
   emit(R_POS);
   emit_sampler(SAMP_NEAREST, 0);
   emit_sampler(SAMP_LINEAR, 1);
   check(submit(CTX_B) == 0, "app context: shaders, samplers, colour buffers");
}

/* ---- drawing and comparing ---- */

static uint32_t img_a[540 * 324], img_b[540 * 324];

/* draws SHADER with HANDLE (target, format) in slot 0 into RT1 (PW x PH) or RT2 (1.8x);
 * the pixels into OUT */
static int render(uint32_t shader, uint32_t handle, uint32_t ttarget, uint32_t format,
                  int linear, int big, uint32_t *out)
{
   uint32_t w = big ? 540 : PW, h = big ? 324 : PH;
   target(big ? SURF2 : SURF1, w, h);
   bind_shader(shader, SH_FRAGMENT);
   bind_view(handle, ttarget, format, linear ? SAMP_LINEAR : SAMP_NEAREST);
   draw();
   int r = submit(CTX_B);
   if (download(CTX_B, big ? R_RT2 : R_RT1, out, 4, w, h))
      r = -1;
   return r;
}

static int channel_diff(uint32_t a, uint32_t b)
{
   int max = 0;
   for (int c = 0; c < 32; c += 8) {
      int d = (int)((a >> c) & 0xff) - (int)((b >> c) & 0xff);
      if (d < 0)
         d = -d;
      if (d > max)
         max = d;
   }
   return max;
}

/* largest per-channel difference of two images, and where */
static int image_diff(const uint32_t *a, const uint32_t *b, uint32_t w, uint32_t h,
                      uint32_t *at_x, uint32_t *at_y)
{
   int max = 0;
   for (uint32_t y = 0; y < h; y++)
      for (uint32_t x = 0; x < w; x++) {
         int d = channel_diff(a[y * w + x], b[y * w + x]);
         if (d > max) {
            max = d;
            *at_x = x;
            *at_y = y;
         }
      }
   return max;
}

static uint32_t count_marker(const uint32_t *a, uint32_t w, uint32_t h)
{
   uint32_t n = 0;
   for (uint32_t i = 0; i < w * h; i++)
      n += a[i] == MARKER;
   return n;
}

/* SHADER on the declared texture against the reference, within TOL per channel */
static void compare(const char *name, uint32_t shader, uint32_t decl, uint32_t ref,
                    uint32_t format, int linear, int big, int tol)
{
   uint32_t w = big ? 540 : PW, h = big ? 324 : PH, x = 0, y = 0;
   char text[256];
   int ra = render(shader, decl, T_2D, format, linear, big, img_a);
   int rb = render(shader, ref, T_2D, format, linear, big, img_b);
   int d = image_diff(img_a, img_b, w, h, &x, &y);
   uint32_t markers = count_marker(img_a, w, h);
   if (logical_on) {
      snprintf(text, sizeof(text), "%s: like the %ux%u texture (largest difference %d at %u,%u: "
               "0x%08x, reference 0x%08x; %u marker pixels)", name, PW, PH, d, x, y,
               img_a[y * w + x], img_b[y * w + x], markers);
      check(!ra && !rb && d <= tol && !markers, text);
   } else {
      snprintf(text, sizeof(text), "%s (declarations ignored): the whole texture (largest "
               "difference %d, %u marker pixels)", name, d, markers);
      check(!ra && !rb && d > tol, text);
   }
}

/* ---- the cases ---- */

static uint32_t tex_pad[TW * TH], tex_true[PW * PH], tex_fill[TW * TH], tex_alpha[TW * TH];

static void case_lookups(void)
{
   /* 1: nearest, every lookup; the picture's own texels (orientation as the reference) */
   compare("TEX nearest", FS_TEX, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 0);
   uint32_t bad = 0;
   for (uint32_t y = 0; y < PH; y++)
      for (uint32_t x = 0; x < PW; x++) {
         uint32_t want_up = picture(x, y), want_down = picture(x, PH - 1 - y);
         bad += img_b[y * PW + x] != want_up && img_b[y * PW + x] != want_down;
      }
   check(!bad, "the reference draws the picture's own texels");
   compare("TXP nearest", FS_TXP, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 0);
   compare("TXB nearest", FS_TXB, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 0);
   compare("TXL nearest", FS_TXL, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 0);
   compare("TXD nearest", FS_TXD, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 0);
   /* 2: linear at 1.8x */
   compare("TEX linear 1.8x", FS_TEX, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, 1);
   compare("TXP linear 1.8x", FS_TXP, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, 1);
   compare("TXB linear 1.8x", FS_TXB, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, 1);
   compare("TXL linear 1.8x", FS_TXL, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, 1);
   compare("TXD linear 1.8x", FS_TXD, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, 1);
}

static void case_txq(void)
{
   uint32_t want_r = (PW * 255 + 512) / 1024, want_g = (PH * 255 + 512) / 1024;
   uint32_t old_r = (TW * 255 + 512) / 1024, old_g = (TH * 255 + 512) / 1024;
   char text[200];
   int r = render(FS_TXQ, R_PAD, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, img_a);
   uint32_t got_r = img_a[0] & 0xff, got_g = img_a[0] >> 8 & 0xff;
   uint32_t er = logical_on ? want_r : old_r, eg = logical_on ? want_g : old_g;
   snprintf(text, sizeof(text), "TXQ: size %u/1024 x %u/1024 (expected %u x %u: %ux%u)", got_r, got_g,
            er, eg, logical_on ? PW : TW, logical_on ? PH : TH);
   check(!r && (int)got_r - (int)er >= -1 && (int)got_r - (int)er <= 1 &&
         (int)got_g - (int)eg >= -1 && (int)got_g - (int)eg <= 1, text);
}

static void case_planes(void)
{
   /* 4: NV12's planes: Y (R8) 320x192 -> 300x180, UV (RG8) 160x96 -> 150x90 */
   static uint8_t y_pad[TW * TH], y_true[PW * PH], uv_pad[160 * 96 * 2], uv_true[150 * 90 * 2];
   for (uint32_t y = 0; y < TH; y++)
      for (uint32_t x = 0; x < TW; x++)
         y_pad[y * TW + x] = x < PW && y < PH ? (uint8_t)((x + y) & 0xff) : 0xff;
   for (uint32_t y = 0; y < PH; y++)
      for (uint32_t x = 0; x < PW; x++)
         y_true[y * PW + x] = (uint8_t)((x + y) & 0xff);
   for (uint32_t y = 0; y < 96; y++)
      for (uint32_t x = 0; x < 160; x++) {
         int in = x < 150 && y < 90;
         uv_pad[2 * (y * 160 + x)] = in ? (uint8_t)(x * 255 / 149) : 0xff;
         uv_pad[2 * (y * 160 + x) + 1] = in ? (uint8_t)(y * 255 / 89) : 0x00;
      }
   for (uint32_t y = 0; y < 90; y++)
      for (uint32_t x = 0; x < 150; x++) {
         uv_true[2 * (y * 150 + x)] = (uint8_t)(x * 255 / 149);
         uv_true[2 * (y * 150 + x) + 1] = (uint8_t)(y * 255 / 89);
      }
   check(!upload(CTX_A, R_Y, y_pad, 1, TW, TH) && !upload(CTX_A, R_YTRUE, y_true, 1, PW, PH) &&
         !upload(CTX_A, R_UV, uv_pad, 2, 160, 96) && !upload(CTX_A, R_UVTRUE, uv_true, 2, 150, 90),
         "planes uploaded");
   declare(CTX_A, R_Y, PW, PH, "Y plane declared 300x180");
   declare(CTX_A, R_UV, 150, 90, "UV plane declared 150x90");
   uint32_t x = 0, yy = 0;
   char text[200];
   int ra = render(FS_TEXR, R_Y, T_2D, VIRGL_FORMAT_R8_UNORM, 1, 1, img_a);
   int rb = render(FS_TEXR, R_YTRUE, T_2D, VIRGL_FORMAT_R8_UNORM, 1, 1, img_b);
   int d = image_diff(img_a, img_b, 540, 324, &x, &yy);
   snprintf(text, sizeof(text), "R8 Y plane, linear 1.8x: largest difference %d at %u,%u", d, x, yy);
   check(!ra && !rb && (logical_on ? d <= 1 : d > 1), text);
   ra = render(FS_TEXR, R_UV, T_2D, VIRGL_FORMAT_R8G8_UNORM, 1, 1, img_a);
   rb = render(FS_TEXR, R_UVTRUE, T_2D, VIRGL_FORMAT_R8G8_UNORM, 1, 1, img_b);
   d = image_diff(img_a, img_b, 540, 324, &x, &yy);
   snprintf(text, sizeof(text), "RG8 UV plane, linear 1.8x: largest difference %d at %u,%u", d, x, yy);
   check(!ra && !rb && (logical_on ? d <= 1 : d > 1), text);

   /* a one-layer 2D array (as an interlaced-capable driver makes planes) */
   check(!upload(CTX_A, R_ARR, tex_pad, 4, TW, TH), "2D array uploaded");
   declare(CTX_A, R_ARR, PW, PH, "2D array declared 300x180");
   ra = render(FS_ARR, R_ARR, T_2D_ARRAY, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, img_a);
   rb = render(FS_TEX, R_TRUE, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, img_b);
   d = image_diff(img_a, img_b, PW, PH, &x, &yy);
   snprintf(text, sizeof(text), "2D array through a 2D_ARRAY sampler: largest difference %d", d);
   check(!ra && !rb && (logical_on ? d == 0 : d > 0), text);
   /* a plain 2D texture through a 2D_ARRAY sampler (Mesa's video compositor) */
   ra = render(FS_ARR, R_PAD, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, img_a);
   rb = render(FS_TEX, R_TRUE, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, img_b);
   d = image_diff(img_a, img_b, 540, 324, &x, &yy);
   snprintf(text, sizeof(text), "2D texture through a 2D_ARRAY sampler, linear 1.8x: largest "
            "difference %d at %u,%u", d, x, yy);
   check(!ra && !rb && (logical_on ? d <= 1 : d > 1), text);
}

static void case_gather(void)
{
   /* 5: padding = the picture's edge (the host's edge fill) */
   compare("TG4 (padding = the edge, as the edge fill writes it)", FS_TG4, R_FILL, R_FILLTRUE,
           VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 0);
}

static void case_alpha(void)
{
   /* 6: transparent padding, linear 1.8x: no alpha bleeds in at the edge */
   uint32_t x = 0, y = 0;
   char text[200];
   int ra = render(FS_TEX, R_ALPHA, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, img_a);
   int rb = render(FS_TEX, R_ALPHATRUE, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 1, img_b);
   int d = image_diff(img_a, img_b, 540, 324, &x, &y);
   uint32_t min_alpha = 255;
   for (uint32_t i = 0; i < 540 * 324; i++)
      if ((img_a[i] >> 24) < min_alpha)
         min_alpha = img_a[i] >> 24;
   snprintf(text, sizeof(text), "transparent padding, linear 1.8x: largest difference %d at "
            "%u,%u, lowest alpha %u", d, x, y, min_alpha);
   check(!ra && !rb && (logical_on ? d <= 1 && min_alpha >= 254 : min_alpha < 254), text);
}

static void case_switch(void)
{
   /* 7: one program; the 300x180 picture, a 120x40 one in a 128x48 texture, an undeclared
    * one, and the first again: each at its own size */
   static uint32_t small_pad[128 * 48], small_true[120 * 40];
   for (uint32_t y = 0; y < 48; y++)
      for (uint32_t x = 0; x < 128; x++)
         small_pad[y * 128 + x] = x < 120 && y < 40 ? picture(x * 2, y * 4) : MARKER;
   for (uint32_t y = 0; y < 40; y++)
      for (uint32_t x = 0; x < 120; x++)
         small_true[y * 120 + x] = picture(x * 2, y * 4);
   check(!upload(CTX_A, R_SMALL, small_pad, 4, 128, 48) &&
         !upload(CTX_A, R_SMALLTRUE, small_true, 4, 120, 40), "small picture uploaded");
   declare(CTX_A, R_SMALL, 120, 40, "120x40 in 128x48 declared");
   compare("program, first texture", FS_TEX, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 0, 1);
   compare("same program, a texture of another logical size", FS_TEX, R_SMALL, R_SMALLTRUE,
           VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 0, 1);
   /* the undeclared one: its whole texture, as before */
   int r = render(FS_TEX, R_PLAIN, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, img_a);
   uint32_t last_row_marker = 0;
   for (uint32_t x = 0; x < PW; x++)
      last_row_marker += img_a[(PH - 1) * PW + x] == MARKER || img_a[x] == MARKER;
   check(!r && last_row_marker > 0, "same program, an undeclared texture: its whole texture "
         "(marker in the last row)");
   compare("same program, the first texture again", FS_TEX, R_PAD, R_TRUE,
           VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 0, 1);
}

static void case_undeclared(void)
{
   /* 8: undeclared reads the whole texture; declaring its own size takes the logical one away */
   int r = render(FS_TEX, R_PLAIN, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, img_a);
   uint32_t m = count_marker(img_a, PW, PH);
   check(!r && m > 0, "an undeclared texture reads as before (the marker shows)");
   declare(CTX_A, R_PAD, TW, TH, "R_PAD declared at its own size (no logical size)");
   r = render(FS_TEX, R_PAD, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, img_b);
   uint32_t x = 0, y = 0;
   check(!r && image_diff(img_a, img_b, PW, PH, &x, &y) == 0,
         "its own size: reads as an undeclared texture");
   declare(CTX_A, R_PAD, PW, PH, "R_PAD declared 300x180 again");
   compare("declared again", FS_TEX, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM, 0, 0, 0);
}

static void case_readback(void)
{
   /* 9: a transfer reads every row, the marker too */
   static uint32_t back[TW * TH];
   int r = download(CTX_A, R_PAD, back, 4, TW, TH);
   check(!r && !memcmp(back, tex_pad, sizeof(back)),
         "reading the declared texture back: all 320x192 texels, bit for bit");
}

static void case_bad(void)
{
   /* 10: none of these may change R_PAD's 300x180 or stop a context */
   const uint32_t one_bad[][3] = {
      { 999999, PW, PH },            /* no such resource */
      { R_OTHER, 10, 10 },           /* another context's */
      { R_BUF, 10, 1 },              /* a buffer */
      { R_3D, 8, 8 },                /* a 3D texture */
      { R_MIP, 32, 32 },             /* two levels */
      { R_PAD, 0, PH },
      { R_PAD, PW, 0 },
      { R_PAD, TW + 1, PH },
      { R_PAD, PW, TH + 1 },
      { R_PAD, 0xffffffffu, 0xffffffffu },
      { 0, PW, PH },
   };
   char text[200];
   for (unsigned i = 0; i < sizeof(one_bad) / sizeof(one_bad[0]); i++) {
      nop_logical(1, &one_bad[i]);
      snprintf(text, sizeof(text), "declaration %u (resource %u, %ux%u) refused, context alive",
               i, one_bad[i][0], one_bad[i][1], one_bad[i][2]);
      check(submit(CTX_A) == 0, text);
   }
   /* 9 entries (one past the limit): the whole payload is ignored, also its good entry */
   uint32_t nine[9][3];
   for (int i = 0; i < 9; i++) {
      nine[i][0] = R_PAD;
      nine[i][1] = PW;
      nine[i][2] = PH;
   }
   nine[8][1] = TW;
   nine[8][2] = TH;
   nop_logical(9, (const uint32_t (*)[3])nine);
   check(submit(CTX_A) == 0, "9 entries ignored");
   /* a length that is not 2 + 3n, a wrong version, a wrong magic, an empty NOP */
   emit(VIRGL_CMD0(VIRGL_CCMD_NOP, 0, 4));
   emit(0x534c4d4fu);
   emit(1);
   emit(R_PAD);
   emit(TW);
   emit(VIRGL_CMD0(VIRGL_CCMD_NOP, 0, 5));
   emit(0x534c4d4fu);
   emit(2);
   emit(R_PAD);
   emit(TW);
   emit(TH);
   emit(VIRGL_CMD0(VIRGL_CCMD_NOP, 0, 5));
   emit(0x12345678u);
   emit(1);
   emit(R_PAD);
   emit(TW);
   emit(TH);
   emit(VIRGL_CMD0(VIRGL_CCMD_NOP, 0, 0));
   emit(VIRGL_CMD0(VIRGL_CCMD_NOP, 0, 1));
   emit(0x534c4d4fu);
   check(submit(CTX_A) == 0, "odd length, version 2, another magic, empty NOPs: context alive");
   /* the owner's 300x180 holds; context B draws (B's context is alive too) */
   compare("after the refused declarations", FS_TEX, R_PAD, R_TRUE, VIRGL_FORMAT_R8G8B8A8_UNORM,
           0, 0, 0);
   /* context A still runs commands: it declares, and the declaration counts */
   declare(CTX_A, R_SMALL, 120, 40, "context A declares after them");
   compare("a declaration after the refused ones", FS_TEX, R_SMALL, R_SMALLTRUE,
           VIRGL_FORMAT_R8G8B8A8_UNORM, 1, 0, 1);
}

int main(void)
{
   const char *env = getenv("OMACVM_VIDEO_LOGICAL");
   logical_on = !(env && !strcmp(env, "0"));
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      fprintf(stderr, "no OpenGL context\n");
      return 1;
   }
   soft_gl_require();
   virgl_set_log_callback(log_cb, NULL, NULL);
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      fprintf(stderr, "virgl_renderer_init failed\n");
      return 1;
   }
   virgl_renderer_context_create(CTX_A, 2, "va");
   virgl_renderer_context_create(CTX_B, 3, "app");
   virgl_renderer_context_create(CTX_C, 5, "other");

   make_texture(R_PAD, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, TW, TH);
   make_texture(R_TRUE, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, PW, PH);
   make_texture(R_FILL, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, TW, TH);
   make_texture(R_FILLTRUE, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, PW, PH);
   make_texture(R_Y, T_2D, VIRGL_FORMAT_R8_UNORM, TW, TH);
   make_texture(R_YTRUE, T_2D, VIRGL_FORMAT_R8_UNORM, PW, PH);
   make_texture(R_UV, T_2D, VIRGL_FORMAT_R8G8_UNORM, 160, 96);
   make_texture(R_UVTRUE, T_2D, VIRGL_FORMAT_R8G8_UNORM, 150, 90);
   make_texture(R_ARR, T_2D_ARRAY, VIRGL_FORMAT_R8G8B8A8_UNORM, TW, TH);
   make_texture(R_ALPHA, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, TW, TH);
   make_texture(R_ALPHATRUE, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, PW, PH);
   make_texture(R_SMALL, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 128, 48);
   make_texture(R_SMALLTRUE, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, 120, 40);
   make_texture(R_PLAIN, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, TW, TH);
   make_resource(R_RT1, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, VIRGL_BIND_RENDER_TARGET, PW, PH, 1, 1, 0);
   make_resource(R_RT2, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, VIRGL_BIND_RENDER_TARGET, 540, 324, 1, 1, 0);
   attach(CTX_B, R_RT1);
   attach(CTX_B, R_RT2);
   make_resource(R_POS, T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 3 * 16, 1, 1, 1, 0);
   attach(CTX_B, R_POS);
   make_resource(R_BUF, T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 4096, 1, 1, 1, 0);
   make_resource(R_3D, T_3D, VIRGL_FORMAT_R8G8B8A8_UNORM, VIRGL_BIND_SAMPLER_VIEW, 16, 16, 4, 1, 0);
   make_resource(R_MIP, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, VIRGL_BIND_SAMPLER_VIEW, 64, 64, 1, 1, 1);
   make_resource(R_OTHER, T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, VIRGL_BIND_SAMPLER_VIEW, 64, 64, 1, 1, 0);
   attach(CTX_A, R_BUF);
   attach(CTX_A, R_3D);
   attach(CTX_A, R_MIP);
   attach(CTX_C, R_OTHER);

   const float pos[3][4] = { { -1, -1, 0, 1 }, { 3, -1, 0, 1 }, { -1, 3, 0, 1 } };
   struct iovec iov = { (void *)pos, sizeof(pos) };
   struct virgl_box box = { 0, 0, 0, sizeof(pos), 1, 1 };
   check(!virgl_renderer_transfer_write_iov(R_POS, CTX_B, 0, 0, 0, &box, 0, &iov, 1),
         "vertices uploaded");

   picture_texture(tex_pad, TW, TH, PW, PH, PAD_MARKER);
   picture_texture(tex_true, PW, PH, PW, PH, PAD_MARKER);
   picture_texture(tex_fill, TW, TH, PW, PH, PAD_FILL);
   picture_texture(tex_alpha, TW, TH, PW, PH, PAD_ALPHA);
   check(!upload(CTX_A, R_PAD, tex_pad, 4, TW, TH) && !upload(CTX_A, R_TRUE, tex_true, 4, PW, PH) &&
         !upload(CTX_A, R_FILL, tex_fill, 4, TW, TH) &&
         !upload(CTX_A, R_FILLTRUE, tex_true, 4, PW, PH) &&
         !upload(CTX_A, R_ALPHA, tex_alpha, 4, TW, TH) &&
         !upload(CTX_A, R_ALPHATRUE, tex_true, 4, PW, PH) &&
         !upload(CTX_A, R_PLAIN, tex_pad, 4, TW, TH), "pictures uploaded");

   /* the owner (context A) declares; context B samples */
   declare(CTX_A, R_PAD, PW, PH, "R_PAD declared 300x180 by its owner");
   declare(CTX_A, R_FILL, PW, PH, "R_FILL declared 300x180");
   declare(CTX_A, R_ALPHA, PW, PH, "R_ALPHA declared 300x180");
   setup_b();

   case_lookups();
   case_txq();
   case_planes();
   case_gather();
   case_alpha();
   case_switch();
   case_undeclared();
   case_readback();
   case_bad();

   virgl_renderer_context_destroy(CTX_A);
   virgl_renderer_context_destroy(CTX_B);
   virgl_renderer_context_destroy(CTX_C);
   for (uint32_t r = R_PAD; r <= R_OTHER; r++)
      virgl_renderer_resource_unref(r);
   virgl_renderer_cleanup(&cookie);
   if (failures) {
      printf("test-video-logical-size: %d FAILED\n", failures);
      return 1;
   }
   printf("test-video-logical-size: all ok%s\n", logical_on ? "" : " (declarations ignored)");
   return 0;
}
