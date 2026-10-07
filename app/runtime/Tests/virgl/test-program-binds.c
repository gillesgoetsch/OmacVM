/* A draw binds its GL program only when it changed (virgl-use-program-cache.patch),
 * through the public renderer API on the Mac's own OpenGL (CGL core contexts, no window).
 * Every case draws a full-viewport triangle into a 16x16 colour buffer and reads the
 * colour back, so a program that was wrongly not bound shows as the wrong colour:
 *  - switching between two fragment shaders (red, green) and back draws each colour;
 *  - the same program twice is bound once: a program the test binds behind vrend's back
 *    (blue) stays bound for the second draw (white-box check that the cache works; with
 *    OMACVM_VIRGL_PROGRAM_CACHE=0 the second draw binds red again);
 *  - a read-back between draws (it binds program 0 in the context) makes the next draw
 *    bind its program again;
 *  - a destroyed fragment shader (its programs are deleted) and a new one;
 *  - two sub contexts (one GL context each) keep their own bound program;
 *  - one program draws twice in one submit with new constants in between (the
 *    Aquarium pattern: the second draw skips the bind and must still use its own
 *    constants). */
#include <stdio.h>
#include <stdlib.h>
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

/* RGBA8 pixels as read back (little endian: 0xAABBGGRR) */
enum { RED = 0xff0000ff, GREEN = 0xff00ff00, BLUE = 0xffff0000, GREY = 0xff808080 };

static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

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

/* one pixel of the colour buffer; ~0 when the read fails */
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

static void check_pixel(int x, int y, uint32_t want, const char *what)
{
   char text[160];
   uint32_t got = read_pixel(x, y);
   snprintf(text, sizeof(text), "%s (0x%08x, expected 0x%08x)", what, got, want);
   check(got == want, text);
}

static void check_colour(uint32_t want, const char *what)
{
   check_pixel(8, 8, want, what);
}

/* fragment constant 0 (the colour fs_const writes) */
static void emit_fs_colour(struct cmds *c, float r, float g, float b)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_CONSTANT_BUFFER, 0, 2 + 4));
   emit(c, TEST_SHADER_FRAGMENT);
   emit(c, 0);                      /* index */
   emit_float(c, r);
   emit_float(c, g);
   emit_float(c, b);
   emit_float(c, 1.0f);
}

/* the left half (x 0-7), the right half (x 8-15) or the whole 16x16 buffer */
static void emit_viewport(struct cmds *c, int part)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_VIEWPORT_STATE, 0, VIRGL_SET_VIEWPORT_STATE_SIZE(1)));
   emit(c, 0);                      /* start slot */
   emit_float(c, part ? 4 : 8);     /* scale */
   emit_float(c, 8);
   emit_float(c, 0.5f);
   emit_float(c, part == 1 ? 4 : part == 2 ? 12 : 8); /* translate */
   emit_float(c, 8);
   emit_float(c, 0.5f);
}

/* A triangle that covers the whole viewport, from gl_VertexID alone:
 * (-1,-1), (3,-1), (-1,3). */
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

static const char *fs_red =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    1.0000,     0.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

static const char *fs_green =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "IMM[0] FLT32 {    0.0000,     1.0000,     0.0000,     1.0000}\n"
   "  0: MOV OUT[0], IMM[0]\n"
   "  1: END\n";

/* writes fragment constant 0 */
static const char *fs_const =
   "FRAG\n"
   "DCL OUT[0], COLOR\n"
   "DCL CONST[0]\n"
   "  0: MOV OUT[0], CONST[0]\n"
   "  1: END\n";

/* The test's own program (blue), bound behind vrend's back. */
static GLuint blue_program(void)
{
   static const char *vs =
      "#version 330 core\n"
      "void main() {\n"
      "  vec2 p = vec2(float(gl_VertexID & 1), float((gl_VertexID & 2) >> 1));\n"
      "  gl_Position = vec4(p * 4.0 - 1.0, 0.5, 1.0);\n"
      "}\n";
   static const char *fs =
      "#version 330 core\n"
      "out vec4 colour;\n"
      "void main() { colour = vec4(0.0, 0.0, 1.0, 1.0); }\n";
   GLuint prog = glCreateProgram();
   const char *text[2] = { vs, fs };
   GLenum type[2] = { GL_VERTEX_SHADER, GL_FRAGMENT_SHADER };
   for (int i = 0; i < 2; i++) {
      GLuint s = glCreateShader(type[i]);
      glShaderSource(s, 1, &text[i], NULL);
      glCompileShader(s);
      glAttachShader(prog, s);
      glDeleteShader(s);
   }
   glBindFragDataLocation(prog, 0, "colour");
   glLinkProgram(prog);
   GLint linked = 0;
   glGetProgramiv(prog, GL_LINK_STATUS, &linked);
   return linked ? prog : 0;
}

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   const char *cache_env = getenv("OMACVM_VIRGL_PROGRAM_CACHE");
   int cache_off = cache_env && !strcmp(cache_env, "0");
   if (cache_off)
      printf("OMACVM_VIRGL_PROGRAM_CACHE=0: every draw binds its program\n");
   if (!cgl_init_renderer_main()) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &cgl_renderer_callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   check(!virgl_renderer_context_create(1, 6, "chrome"), "context");
   struct virgl_renderer_resource_create_args args = {
      .handle = 5, .target = TEST_TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET, .width = 16, .height = 16, .depth = 1,
      .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "colour buffer");
   virgl_renderer_ctx_attach_resource(1, 5);

   struct cmds c = { .n = 0 };
   emit_setup(&c);
   emit_create_shader(&c, 10, TEST_SHADER_VERTEX, vs_text);
   emit_bind_shader(&c, 10, TEST_SHADER_VERTEX);
   emit_create_shader(&c, 11, TEST_SHADER_FRAGMENT, fs_red);
   emit_create_shader(&c, 12, TEST_SHADER_FRAGMENT, fs_green);
   check(submit(1, &c) == 0, "shaders and framebuffer");

   /* 1: program changes between draws */
   static const struct { uint32_t fs, colour; const char *what; } steps[] = {
      { 11, RED, "red" }, { 12, GREEN, "green after red" }, { 11, RED, "red after green" },
      { 11, RED, "red again" }, { 12, GREEN, "green again" },
   };
   for (unsigned i = 0; i < sizeof(steps) / sizeof(steps[0]); i++) {
      emit_clear_grey(&c);
      emit_bind_shader(&c, steps[i].fs, TEST_SHADER_FRAGMENT);
      emit_draw(&c);
      check(submit(1, &c) == 0, "draw");
      check_colour(steps[i].colour, steps[i].what);
   }

   /* 2: the same program twice in one submit is bound once. The read-back above left
    * program 0 bound, so the first draw binds red; the test then binds its own blue
    * program in the renderer's context (still current after a submit) and the next red
    * draw must leave it bound: it draws blue. */
   GLuint blue = blue_program();
   check(blue != 0, "the test's own blue program links");
   emit_clear_grey(&c);
   emit_bind_shader(&c, 11, TEST_SHADER_FRAGMENT);
   emit_draw(&c);
   check(submit(1, &c) == 0, "red draw");
   GLint bound = 0;
   glGetIntegerv(GL_CURRENT_PROGRAM, &bound);
   check(bound != 0, "the red draw left its program bound");
   glUseProgram(blue);
   emit_draw(&c);
   check(submit(1, &c) == 0, "red draw again");
   if (cache_off)
      check_colour(RED, "OMACVM_VIRGL_PROGRAM_CACHE=0: the same program is bound again (red)");
   else
      check_colour(BLUE, "the same program is not bound again (the test's blue program drew)");

   /* 3: that read-back bound program 0 in the context: the next draw with the same red
    * program must bind it again. No clear first: a clear unbinds the program itself. */
   emit_draw(&c);
   check(submit(1, &c) == 0, "red draw after a read-back");
   check_colour(RED, "a read-back between two draws of one program: the second binds it again");
   glDeleteProgram(blue);

   /* 4: the bound program's fragment shader destroyed (its programs deleted), a new
    * shader bound: the draw uses the new one, and then the old colour again. */
   emit_clear_grey(&c);
   emit_bind_shader(&c, 11, TEST_SHADER_FRAGMENT);
   emit_draw(&c);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_DESTROY_OBJECT, VIRGL_OBJECT_SHADER, 1));
   emit(&c, 11);
   emit_clear_grey(&c);
   emit_create_shader(&c, 13, TEST_SHADER_FRAGMENT, fs_green);
   emit_bind_shader(&c, 13, TEST_SHADER_FRAGMENT);
   emit_draw(&c);
   check(submit(1, &c) == 0, "draw, destroy its shader, draw with a new one");
   check_colour(GREEN, "a destroyed shader's program is not used again");
   emit_clear_grey(&c);
   emit_create_shader(&c, 11, TEST_SHADER_FRAGMENT, fs_red);
   emit_bind_shader(&c, 11, TEST_SHADER_FRAGMENT);
   emit_draw(&c);
   emit_draw(&c);
   check(submit(1, &c) == 0, "red made again");
   check_colour(RED, "the new red program draws");

   /* 5: a second sub context (its own GL context): each keeps its own bound program. */
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_CREATE_SUB_CTX, 0, 1));
   emit(&c, 1);
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_SUB_CTX, 0, 1));
   emit(&c, 1);
   emit_setup(&c);
   emit_create_shader(&c, 10, TEST_SHADER_VERTEX, vs_text);
   emit_bind_shader(&c, 10, TEST_SHADER_VERTEX);
   emit_create_shader(&c, 12, TEST_SHADER_FRAGMENT, fs_green);
   emit_bind_shader(&c, 12, TEST_SHADER_FRAGMENT);
   emit_clear_grey(&c);
   emit_draw(&c);
   check(submit(1, &c) == 0, "sub context 1: green");
   check_colour(GREEN, "sub context 1 draws green");
   for (int i = 0; i < 3; i++) {
      emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_SUB_CTX, 0, 1));
      emit(&c, 0);
      emit_clear_grey(&c);
      emit_draw(&c);
      check(submit(1, &c) == 0, "sub context 0");
      check_colour(RED, "sub context 0 still draws red");
      emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_SUB_CTX, 0, 1));
      emit(&c, 1);
      emit_clear_grey(&c);
      emit_draw(&c);
      check(submit(1, &c) == 0, "sub context 1");
      check_colour(GREEN, "sub context 1 still draws green");
   }

   /* 6: one program, two draws in ONE submit (a read-back would drop the cache), new
    * constants and viewport between them and no other state change: the second draw
    * does not bind the program again and must still draw with its own constants.
    * Then the same again in the other order, and red/green swapped. */
   emit(&c, VIRGL_CMD0(VIRGL_CCMD_SET_SUB_CTX, 0, 1));
   emit(&c, 0);
   emit_create_shader(&c, 14, TEST_SHADER_FRAGMENT, fs_const);
   emit_bind_shader(&c, 14, TEST_SHADER_FRAGMENT);
   for (int round = 0; round < 2; round++) {
      emit_clear_grey(&c);
      emit_viewport(&c, 1);
      emit_fs_colour(&c, round ? 0 : 1, round ? 1 : 0, 0);
      emit_draw(&c);
      emit_viewport(&c, 2);
      emit_fs_colour(&c, round ? 1 : 0, round ? 0 : 1, 0);
      emit_draw(&c);
      check(submit(1, &c) == 0, "one program, two constants, one submit");
      check_pixel(4, 8, round ? GREEN : RED, "left half: the first draw's constants");
      check_pixel(12, 8, round ? RED : GREEN,
                  "right half: the second draw's constants (same program as the first)");
   }
   emit_viewport(&c, 0);
   check(submit(1, &c) == 0, "whole viewport again");

   virgl_renderer_ctx_detach_resource(1, 5);
   virgl_renderer_context_destroy(1);
   virgl_renderer_resource_unref(5);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "program binds: FAILED" : "program binds: all checks passed");
   return failures != 0;
}
