/* The guest's memory budget for virgl resources (virgl-resource-memory-budget.patch),
 * through the public renderer API on Apple's software renderer (soft-gl.h; never on
 * the GPU). Each mode runs in its own process because the budget is read once, when
 * the renderer starts:
 *   test-resource-budget            runs every mode below as a child process
 *   test-resource-budget limit      OMACVM_GPU_MEMORY_MB=64: what fits and what is refused
 *   test-resource-budget off        OMACVM_GPU_MEMORY_MB=0: no budget
 *   test-resource-budget default    unset: a quarter of the Mac's memory */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

extern char **environ;

enum { T_BUFFER = 0, T_2D = 2, T_3D = 3, T_CUBE = 4, T_2D_ARRAY = 7 };
#define MB (1u << 20)

static CGLContextObj main_ctx;
static int failures;
static uint32_t next_handle = 1;

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

/* Returns the new handle, or 0 when the renderer refused the resource. */
static uint32_t make(int target, uint32_t format, uint32_t bind, uint32_t w, uint32_t h,
                     uint32_t depth, uint32_t layers, uint32_t last_level, uint32_t samples)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = next_handle, .target = target, .format = format, .bind = bind,
      .width = w, .height = h, .depth = depth, .array_size = layers,
      .last_level = last_level, .nr_samples = samples,
   };
   if (virgl_renderer_resource_create(&a, NULL, 0))
      return 0;
   return next_handle++;
}

static uint32_t tex2d(uint32_t w, uint32_t h, uint32_t levels)
{
   return make(T_2D, VIRGL_FORMAT_R8G8B8A8_UNORM, VIRGL_BIND_SAMPLER_VIEW, w, h, 1, 1,
               levels - 1, 0);
}

static void unref(uint32_t *handles, int n)
{
   for (int i = 0; i < n; i++)
      if (handles[i])
         virgl_renderer_resource_unref(handles[i]);
}

/* How many of the same resource fit before the first refusal (at most max). */
static int count_fit(uint32_t *handles, int max, uint32_t (*fn)(void *), void *arg)
{
   int n = 0;
   while (n < max && (handles[n] = fn(arg)))
      n++;
   return n;
}

struct spec { int target; uint32_t format, bind, w, h, d, layers, levels, samples; };
static uint32_t make_spec(void *p)
{
   struct spec *s = p;
   return make(s->target, s->format, s->bind, s->w, s->h, s->d, s->layers, s->levels - 1,
               s->samples);
}

static void expect_fit(const char *what, struct spec s, int want)
{
   uint32_t h[64] = {0};
   char line[200];
   int n = count_fit(h, 64, make_spec, &s);
   snprintf(line, sizeof line, "%s: %d fit in 64 MB (want %d)", what, n, want);
   check(n == want, line);
   unref(h, n);
}

static int run_limit(void)
{
   uint32_t h[64] = {0};
   const uint32_t rgba = VIRGL_FORMAT_R8G8B8A8_UNORM, sv = VIRGL_BIND_SAMPLER_VIEW;

   /* 1024x1024 RGBA = 4 MB: exactly 16 fit, the 17th is refused */
   int n = 0;
   while (n < 64 && (h[n] = tex2d(1024, 1024, 1)))
      n++;
   check(n == 16, "16 textures of 4 MB fill a 64 MB budget exactly");
   /* freeing one gives its bytes back */
   virgl_renderer_resource_unref(h[0]);
   h[0] = tex2d(1024, 1024, 1);
   check(h[0] != 0, "after freeing one texture, one more fits");
   check(tex2d(1024, 1024, 1) == 0, "and the next is refused again");
   check(make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 4096, 1, 1, 1, 0, 0) == 0,
         "a small buffer is refused while the budget is full");
   unref(h, n);
   memset(h, 0, sizeof h);

   /* after freeing everything the whole budget is free again */
   uint32_t big = make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 64 * MB, 1, 1, 1, 0, 0);
   check(big != 0, "after freeing all, a 64 MB buffer fits");
   check(make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 1, 1, 1, 1, 0, 0) == 0,
         "a 1-byte buffer next to it is refused (each resource costs at least 4 KB)");
   virgl_renderer_resource_unref(big);
   check(make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 64 * MB + 1, 1, 1, 1, 0, 0) == 0,
         "a buffer one byte over the budget is refused");

   /* the estimate counts mip levels, layers, depth and samples */
   expect_fit("2048x2048 RGBA, full mip chain (21.3 MB)", (struct spec){T_2D, rgba, sv, 2048, 2048, 1, 1, 12, 0}, 3);
   expect_fit("2048x2048 RGBA, one level (16 MB)", (struct spec){T_2D, rgba, sv, 2048, 2048, 1, 1, 1, 0}, 4);
   expect_fit("1024x1024 RGBA, 16 layers (64 MB)", (struct spec){T_2D_ARRAY, rgba, sv, 1024, 1024, 1, 16, 1, 0}, 1);
   expect_fit("1024x1024 RGBA, 17 layers (68 MB)", (struct spec){T_2D_ARRAY, rgba, sv, 1024, 1024, 1, 17, 1, 0}, 0);
   expect_fit("256x256x256 RGBA 3D (64 MB)", (struct spec){T_3D, rgba, sv, 256, 256, 256, 1, 1, 0}, 1);
   expect_fit("256x256x257 RGBA 3D", (struct spec){T_3D, rgba, sv, 256, 256, 257, 1, 1, 0}, 0);
   expect_fit("512x512 RGBA cube (6 MB)", (struct spec){T_CUBE, rgba, sv, 512, 512, 1, 6, 1, 0}, 10);
   expect_fit("1024x1024 RGBA, 4 samples (16 MB)",
              (struct spec){T_2D, rgba, VIRGL_BIND_RENDER_TARGET, 1024, 1024, 1, 1, 1, 4}, 4);
   /* a blob pipe resource (made in a context's command stream) that the guest never
    * claims is freed with its context, and its bytes come back */
   check(virgl_renderer_context_create(1, 4, "test") == 0, "context for a pipe resource");
   uint32_t cmd[12] = { VIRGL_CMD0(VIRGL_CCMD_PIPE_RESOURCE_CREATE, 0, VIRGL_PIPE_RES_CREATE_SIZE) };
   cmd[VIRGL_PIPE_RES_CREATE_TARGET] = T_BUFFER;
   cmd[VIRGL_PIPE_RES_CREATE_FORMAT] = VIRGL_FORMAT_R8_UNORM;
   cmd[VIRGL_PIPE_RES_CREATE_BIND] = VIRGL_BIND_VERTEX_BUFFER;
   cmd[VIRGL_PIPE_RES_CREATE_WIDTH] = 48 * MB;
   cmd[VIRGL_PIPE_RES_CREATE_HEIGHT] = cmd[VIRGL_PIPE_RES_CREATE_DEPTH] = 1;
   cmd[VIRGL_PIPE_RES_CREATE_ARRAY_SIZE] = 1;
   cmd[VIRGL_PIPE_RES_CREATE_BLOB_ID] = 7;
   check(virgl_renderer_submit_cmd(cmd, 1, 12) == 0, "a 48 MB pipe resource is made");
   check(make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 32 * MB, 1, 1, 1, 0, 0) == 0,
         "next to it a 32 MB buffer is refused");
   virgl_renderer_context_destroy(1);
   big = make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_VERTEX_BUFFER, 64 * MB, 1, 1, 1, 0, 0);
   check(big != 0, "after its context is gone, a 64 MB buffer fits");
   if (big)
      virgl_renderer_resource_unref(big);

   /* 3-component formats are charged as 4 (Apple's GL pads them): 1024x1024 RGB32F is
    * 12 MB by the format, 16 MB stored; 4 fit, not 5 */
   expect_fit("1024x1024 RGB32F (charged 16 MB)",
              (struct spec){T_2D, VIRGL_FORMAT_R32G32B32_FLOAT, sv, 1024, 1024, 1, 1, 1, 0}, 4);

   /* with the budget full, screens and cursors still get up to 256 MB more */
   n = 0;
   while (n < 64 && (h[n] = tex2d(1024, 1024, 1)))
      n++;
   check(n == 16, "budget filled with textures again");
   uint32_t scan = make(T_2D, VIRGL_FORMAT_B8G8R8X8_UNORM, VIRGL_BIND_SCANOUT | VIRGL_BIND_RENDER_TARGET,
                        3840, 2160, 1, 1, 0, 0);
   check(scan != 0, "a 4K screen still fits past the budget (display reserve)");
   check(make(T_2D, VIRGL_FORMAT_B8G8R8A8_UNORM, VIRGL_BIND_CURSOR, 64, 64, 1, 1, 0, 0) != 0,
         "and a cursor");
   check(tex2d(256, 256, 1) == 0, "an ordinary texture is still refused");
   /* the reserve's upper limit: 256 MB - 4K screen (33,177,600) - cursor (16,384) leaves
    * 235,241,472 bytes = 8192x7179 BGRX exactly. Same bind and format both times, so
    * only the budget can tell them apart (SCANOUT alone is refused as a bind) */
   check(make(T_2D, VIRGL_FORMAT_B8G8R8X8_UNORM, VIRGL_BIND_SCANOUT | VIRGL_BIND_RENDER_TARGET,
              8192, 7180, 1, 1, 0, 0) == 0,
         "a screen one row past the reserve is refused");
   uint32_t last = make(T_2D, VIRGL_FORMAT_B8G8R8X8_UNORM, VIRGL_BIND_SCANOUT | VIRGL_BIND_RENDER_TARGET,
                        8192, 7179, 1, 1, 0, 0);
   check(last != 0, "a screen that ends exactly at the reserve fits");
   check(make(T_2D, VIRGL_FORMAT_B8G8R8A8_UNORM, VIRGL_BIND_CURSOR | VIRGL_BIND_RENDER_TARGET,
              64, 64, 1, 1, 0, 0) == 0,
         "with the reserve full, a cursor is refused too");
   if (last)
      virgl_renderer_resource_unref(last);
   if (scan)
      virgl_renderer_resource_unref(scan);
   unref(h, n);
   memset(h, 0, sizeof h);
   next_handle += 8;

   /* staging buffers only use guest memory: 4 KB each */
   expect_fit("1 GB staging buffers", (struct spec){T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_STAGING,
              1u << 30, 1, 1, 1, 1, 0}, 64);
   return 0;
}

static int run_off(void)
{
   uint32_t h[40] = {0};
   int n = 0;
   while (n < 40 && (h[n] = tex2d(1024, 1024, 1)))
      n++;
   check(n == 40, "OMACVM_GPU_MEMORY_MB=0: 40 textures of 4 MB, no budget");
   unref(h, n);
   return 0;
}

static int run_default(void)
{
   uint64_t mem = 0;
   size_t len = sizeof mem;
   sysctlbyname("hw.memsize", &mem, &len, NULL, 0);
   uint32_t quarter_mb = (uint32_t)(mem / 4 / MB);
   char line[160];
   uint32_t a = make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_STAGING, 4096, 1, 1, 1, 0, 0);
   check(a != 0, "default budget: a small resource fits");
   /* 16384x16384 RGBA32F, 64 layers = 256 GB: refused unless a quarter of the memory
    * is more than 64 GB */
   uint32_t b = make(T_2D_ARRAY, VIRGL_FORMAT_R32G32B32A32_FLOAT, VIRGL_BIND_SAMPLER_VIEW,
                     16384, 16384, 1, 64, 0, 0);
   snprintf(line, sizeof line, "default budget (%u MB = a quarter of %llu MB): a 256 GB texture "
            "array is refused", quarter_mb, (unsigned long long)(mem / MB));
   check(quarter_mb >= 262144 ? 1 : b == 0, line);
   if (a)
      virgl_renderer_resource_unref(a);
   if (b)
      virgl_renderer_resource_unref(b);
   return 0;
}

static int child(const char *mode)
{
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
   if (!strcmp(mode, "limit"))
      run_limit();
   else if (!strcmp(mode, "off"))
      run_off();
   else
      run_default();
   virgl_renderer_cleanup(&cookie);
   return failures != 0;
}

static int spawn(const char *self, const char *mode, const char *budget)
{
   if (budget)
      setenv("OMACVM_GPU_MEMORY_MB", budget, 1);
   else
      unsetenv("OMACVM_GPU_MEMORY_MB");
   char *argv[] = { (char *)self, (char *)mode, NULL };
   pid_t pid;
   int status = 0;
   printf("-- %s (OMACVM_GPU_MEMORY_MB=%s)\n", mode, budget ? budget : "unset");
   if (posix_spawn(&pid, self, NULL, NULL, argv, environ) || waitpid(pid, &status, 0) < 0) {
      printf("FAIL: could not run %s\n", mode);
      return 1;
   }
   if (!WIFEXITED(status) || WEXITSTATUS(status)) {
      printf("FAIL: %s exited with status %d\n", mode, status);
      return 1;
   }
   return 0;
}

int main(int argc, char **argv)
{
   if (argc > 1)
      return child(argv[1]);
   setvbuf(stdout, NULL, _IONBF, 0);
   int bad = spawn(argv[0], "limit", "64") + spawn(argv[0], "off", "0") +
             spawn(argv[0], "default", NULL);
   printf("%s\n", bad ? "resource budget: FAILED" : "resource budget: all checks passed");
   return bad != 0;
}
