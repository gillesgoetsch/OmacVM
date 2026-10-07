/* Render-thread cost of a draw through vrend, the way WebGL Aquarium draws: one draw per
 * object, new vertex-shader constants before each, the same program throughout. Drives the
 * public renderer API in one thread (like QEMU's render thread) on the Mac's own OpenGL,
 * 16x16 target, so the CPU side dominates. Not a build-time test; numbers for
 * virgl-use-program-cache.patch. Usage: bench-program-binds [DRAWS] [ROUNDS]; prints one
 * line per round: microseconds per draw. Uses the GPU lightly: take the bench lock.
 * Build: like test-program-binds (run-regressions.py run_api_test), -O2. */
#include <mach/mach_time.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>
#include <OpenGL/gl3.h>
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"
#define CGL_CONTEXT_RENDERER_CALLBACKS
#include "cgl-context.h"

/* Gallium values the protocol uses (pipe/p_defines.h needs the whole tree). */
enum { TEST_SHADER_VERTEX = 0, TEST_SHADER_FRAGMENT = 1, TEST_PRIM_TRIANGLES = 4,
       TEST_TEXTURE_2D = 2, TEST_CLEAR_COLOR0 = 1 << 2 };

struct cmds {
   uint32_t dw[65536];
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

static void emit_create_shader(struct cmds *c, uint32_t handle, uint32_t type, const char *text)
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

static void emit_draw(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, 0);                      /* start */
   emit(c, 3);                      /* count */
   emit(c, TEST_PRIM_TRIANGLES);
   for (int i = 0; i < VIRGL_DRAW_VBO_SIZE - 3; i++)
      emit(c, 0);
}

/* surface on resource 5, framebuffer, 16x16 viewport, blend and rasterizer state */
static void emit_setup(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, 6);                      /* surface handle */
   emit(c, 5);                      /* resource */
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(c, 0);                      /* level */
   emit(c, 0);                      /* layers */
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, 6);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);                      /* start slot */
   emit_float(c, 8);
   emit_float(c, 8);
   emit_float(c, 0.5f);
   emit_float(c, 8);
   emit_float(c, 8);
   emit_float(c, 0.5f);
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

static int submit(int ctx_id, struct cmds *c)
{
   int r = virgl_renderer_submit_cmd(c->dw, ctx_id, c->n);
   c->n = 0;
   return r;
}


static double now_us(void)
{
   static mach_timebase_info_data_t tb;
   if (!tb.denom)
      mach_timebase_info(&tb);
   return mach_absolute_time() * (double)tb.numer / tb.denom / 1e3;
}

/* full-viewport triangle moved by CONST[0].xy */
static const char *vs_text =
   "VERT\n"
   "DCL SV[0], VERTEXID\n"
   "DCL OUT[0], POSITION\n"
   "DCL CONST[0]\n"
   "DCL TEMP[0..1]\n"
   "IMM[0] UINT32 {1, 2, 0, 0}\n"
   "IMM[1] FLT32 {    4.0000,    -1.0000,     0.5000,     1.0000}\n"
   "  0: AND TEMP[0].x, SV[0].xxxx, IMM[0].xxxx\n"
   "  1: AND TEMP[0].y, SV[0].xxxx, IMM[0].yyyy\n"
   "  2: USHR TEMP[0].y, TEMP[0].yyyy, IMM[0].xxxx\n"
   "  3: U2F TEMP[0].xy, TEMP[0].xyyy\n"
   "  4: MAD TEMP[1].xy, TEMP[0].xyyy, IMM[1].xxxx, IMM[1].yyyy\n"
   "  5: ADD OUT[0].xy, TEMP[1].xyyy, CONST[0].xyyy\n"
   "  6: MOV OUT[0].zw, IMM[1].zzzw\n"
   "  7: END\n";

static const char *fs_text =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

int main(int argc, char **argv)
{
   long draws = argc > 1 ? atol(argv[1]) : 200000;
   int rounds = argc > 2 ? atoi(argv[2]) : 3;
   if (!cgl_init_renderer_main())
      return 1;
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &cgl_renderer_callbacks) ||
       virgl_renderer_context_create(1, 6, "bench"))
      return 1;
   struct virgl_renderer_resource_create_args args = {
      .handle = 5, .target = TEST_TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1,
      .array_size = 1,
   };
   if (virgl_renderer_resource_create(&args, NULL, 0))
      return 1;
   virgl_renderer_ctx_attach_resource(1, 5);
   static struct cmds c;
   emit_setup(&c);
   emit_create_shader(&c, 10, TEST_SHADER_VERTEX, vs_text);
   emit_bind_shader(&c, 10, TEST_SHADER_VERTEX);
   emit_create_shader(&c, 11, TEST_SHADER_FRAGMENT, fs_text);
   emit_bind_shader(&c, 11, TEST_SHADER_FRAGMENT);
   if (submit(1, &c))
      return 1;
   for (int r = 0; r < rounds; r++) {
      double t0 = now_us();
      for (long i = 0; i < draws; i++) {
         emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2 + 4));
         emit(&c, TEST_SHADER_VERTEX);
         emit(&c, 0);
         emit_float(&c, (i % 7) * 0.001f);
         emit_float(&c, (i % 5) * 0.001f);
         emit_float(&c, 0);
         emit_float(&c, 0);
         emit_draw(&c);
         if (c.n > 65536 - 64 && submit(1, &c))
            return 1;
      }
      if (c.n && submit(1, &c))
         return 1;
      glFinish();
      double t = now_us() - t0;
      printf("%.3f us/draw (%ld draws, round %d)\n", t / draws, draws, r + 1);
   }
   virgl_renderer_context_destroy(1);
   virgl_renderer_cleanup(&cookie);
   return 0;
}
