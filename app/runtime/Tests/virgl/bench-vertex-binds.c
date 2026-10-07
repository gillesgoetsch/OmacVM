/* Render-thread cost of a draw through vrend the way WebGL Aquarium draws a fish: the same
 * program, five vertex attributes from two vertex buffers, an index buffer, new vertex
 * constants before each indexed draw. Drives the public renderer API in one thread (like
 * QEMU's render thread) on the Mac's own OpenGL, 16x16 target, so the CPU side dominates.
 * Not a build-time test; numbers for virgl-legacy-vertex-cache.patch: run it with
 * OMACVM_VIRGL_SELECT_CACHE=0 OMACVM_VIRGL_VERTEX_CACHE=0 (as before), with one of them or
 * as is, in turns. Usage: bench-vertex-binds [DRAWS] [ROUNDS]; one line per round:
 * microseconds per draw. Uses the GPU lightly: take the bench lock.
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
enum { TEST_PIPE_BUFFER = 0, TEST_SHADER_VERTEX = 0, TEST_SHADER_FRAGMENT = 1,
       TEST_PRIM_TRIANGLES = 4, TEST_TEXTURE_2D = 2 };

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

/* one indexed draw of 36 indices (12 triangles), like a fish's draw */
static void emit_draw(struct cmds *c)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_DRAW_VBO, 0, VIRGL_DRAW_VBO_SIZE));
   emit(c, 0);                      /* start */
   emit(c, 36);                     /* count */
   emit(c, TEST_PRIM_TRIANGLES);
   emit(c, 1);                      /* indexed */
   for (int i = 0; i < VIRGL_DRAW_VBO_SIZE - 6; i++)
      emit(c, 0);
   emit(c, 0xffffffff);             /* max index */
   emit(c, 0);                      /* count from stream output */
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

/* position, normal, texcoord, tangent, binormal (Aquarium's fish inputs), 16 vec4 constants */
static const char *vs_text =
   "VERT\n"
   "DCL IN[0]\n"
   "DCL IN[1]\n"
   "DCL IN[2]\n"
   "DCL IN[3]\n"
   "DCL IN[4]\n"
   "DCL OUT[0], POSITION\n"
   "DCL OUT[1], GENERIC[0]\n"
   "DCL CONST[0..15]\n"
   "DCL TEMP[0]\n"
   "  0: MUL TEMP[0], IN[0], CONST[0]\n"
   "  1: MAD TEMP[0], IN[1], CONST[1], TEMP[0]\n"
   "  2: MAD TEMP[0], IN[3], CONST[2], TEMP[0]\n"
   "  3: MAD TEMP[0], IN[4], CONST[3], TEMP[0]\n"
   "  4: ADD OUT[0], TEMP[0], CONST[15]\n"
   "  5: MOV OUT[1], IN[2]\n"
   "  6: END\n";

static const char *fs_text =
   "FRAG\n"
   "DCL IN[0], GENERIC[0], PERSPECTIVE\n"
   "DCL OUT[0], COLOR\n"
   "  0: MOV OUT[0], IN[0]\n"
   "  1: END\n";

static void make_buffer(uint32_t handle, uint32_t bind, uint32_t width)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = handle, .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = bind, .width = width, .height = 1, .depth = 1, .array_size = 1,
   };
   if (virgl_renderer_resource_create(&a, NULL, 0))
      exit(1);
   virgl_renderer_ctx_attach_resource(1, handle);
}

static void emit_write(struct cmds *c, uint32_t handle, const void *data, uint32_t bytes)
{
   uint32_t words = (bytes + 3) / 4;
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_INLINE_WRITE, 0, 11 + words));
   emit(c, handle);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
   emit(c, bytes);
   emit(c, 1);
   emit(c, 1);
   memset(&c->dw[c->n], 0, words * 4);
   memcpy(&c->dw[c->n], data, bytes);
   c->n += words;
}

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
   /* 24 vertices: buffer 20 = position + normal + texcoord interleaved (48 bytes each),
    * buffer 21 = tangent + binormal (32 bytes each); 36 uint16 indices */
   make_buffer(20, VIRGL_BIND_VERTEX_BUFFER, 24 * 48);
   make_buffer(21, VIRGL_BIND_VERTEX_BUFFER, 24 * 32);
   make_buffer(22, VIRGL_BIND_INDEX_BUFFER, 36 * 2);
   static struct cmds c;
   emit_setup(&c);
   emit_create_shader(&c, 10, TEST_SHADER_VERTEX, vs_text);
   emit_bind_shader(&c, 10, TEST_SHADER_VERTEX);
   emit_create_shader(&c, 11, TEST_SHADER_FRAGMENT, fs_text);
   emit_bind_shader(&c, 11, TEST_SHADER_FRAGMENT);
   static float a[24 * 12], b[24 * 8];
   for (int i = 0; i < 24 * 12; i++)
      a[i] = (i % 7) * 0.1f - 0.3f;
   for (int i = 0; i < 24 * 8; i++)
      b[i] = (i % 5) * 0.1f;
   uint16_t idx[36];
   for (int i = 0; i < 36; i++)
      idx[i] = i % 24;
   emit_write(&c, 20, a, sizeof(a));
   emit_write(&c, 21, b, sizeof(b));
   emit_write(&c, 22, idx, sizeof(idx));
   const uint32_t f4 = VIRGL_FORMAT_R32G32B32A32_FLOAT, f3 = VIRGL_FORMAT_R32G32B32_FLOAT,
                  f2 = VIRGL_FORMAT_R32G32_FLOAT;
   const uint32_t ve[5][3] = { { 0, 0, f4 }, { 16, 0, f4 }, { 32, 0, f2 }, { 0, 1, f4 }, { 16, 1, f3 } };
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS,
                       VIRGL_OBJ_VERTEX_ELEMENTS_SIZE(5)));
   emit(&c, 30);
   for (int i = 0; i < 5; i++) {
      emit(&c, ve[i][0]);
      emit(&c, 0);
      emit(&c, ve[i][1]);
      emit(&c, ve[i][2]);
   }
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_BIND_OBJECT, VIRGL_OBJECT_VERTEX_ELEMENTS, 1));
   emit(&c, 30);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_VERTEX_BUFFERS, 0, VIRGL_SET_VERTEX_BUFFERS_SIZE(2)));
   emit(&c, 48);
   emit(&c, 0);
   emit(&c, 20);
   emit(&c, 32);
   emit(&c, 0);
   emit(&c, 21);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_INDEX_BUFFER, 0, VIRGL_SET_INDEX_BUFFER_SIZE(1)));
   emit(&c, 22);
   emit(&c, 2);
   emit(&c, 0);
   if (submit(1, &c))
      return 1;
   for (int r = 0; r < rounds; r++) {
      double t0 = now_us();
      for (long i = 0; i < draws; i++) {
         emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2 + 64));
         emit(&c, TEST_SHADER_VERTEX);
         emit(&c, 0);
         for (int k = 0; k < 64; k++)
            emit_float(&c, ((i + k) % 7) * 0.01f);
         emit_draw(&c);
         if (c.n > 65536 - 128 && submit(1, &c))
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
