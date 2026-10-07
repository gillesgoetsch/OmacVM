/* The guest's memory budget for virgl resources (virgl-resource-memory-budget.patch)
 * and how it follows the Mac's memory (virgl-darwin-memory-pressure.patch), through
 * the public renderer API on Apple's software renderer (soft-gl.h; never on the GPU).
 * Each mode runs in its own process because the settings are read once, when the
 * renderer starts. The budget modes run with the pressure check off, so a busy build
 * Mac cannot change their result; the pressure modes set the level themselves:
 *   test-resource-budget            runs every mode below as a child process
 *   test-resource-budget limit      OMACVM_GPU_MEMORY_MB=64: what fits and what is refused,
 *                                   and the context that attaches a refused resource is lost
 *                                   (virgl-resource-budget-context-loss.patch)
 *   test-resource-budget off        OMACVM_GPU_MEMORY_MB=0: no budget
 *   test-resource-budget default    unset: three quarters of the Mac's memory, and the
 *                                   desktop reserve for this Mac's memory
 *   test-resource-budget critical   pressure critical: a big resource is made for the
 *                                   desktop only after trying again (the next one at
 *                                   once): an app that takes it is lost, Hyprland keeps
 *                                   it, also as the lost app's dropped buffer; small
 *                                   ones, screens and cursors fit; an app's pipe
 *                                   resource is refused
 *   test-resource-budget warn       pressure warn, 100 MB left: what fits
 *   test-resource-budget reserve    OMACVM_GPU_MEMORY_MB=64: the last 16 MB are kept for
 *                                   the desktop (virgl-gpu-guard-desktop-reserve.patch):
 *                                   the app past its share is lost, not Hyprland
 *   test-resource-budget dropped    OMACVM_GPU_MEMORY_MB=64: Hyprland showing a lost app's
 *                                   dropped buffer (it imports it and samples it) keeps
 *                                   drawing (virgl-gpu-guard-dropped-placeholder.patch)
 *   test-resource-budget wording    OMACVM_GPU_MEMORY_MB=64: a refusal at the apps' share
 *                                   says so in the log, not "budget reached"
 *   test-resource-budget status     the status file: in use, peak, a lost context
 *   test-resource-budget levelfile  the level read from a file at each look (the
 *                                   test hook that raises it while a VM runs) */
#include <fcntl.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

extern char **environ;

enum { T_BUFFER = 0, T_2D = 2, T_3D = 3, T_CUBE = 4, T_2D_ARRAY = 7 };
#define MB (1u << 20)

static uint64_t mac_memory(void);
static void settle(void);
static long status_value(const char *key, char *out, size_t out_len);

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

/* A guest context named NAME (the guest's kernel names it after the process) with a
 * status buffer (VIRGL_CCMD_SET_RESET_STATUS_BUFFER), as the guest's Mesa with
 * mesa-virgl-reset-status.patch sets one up. HANDLE: 899 + ctx_id (submit_nothing). */
static uint32_t *named_context(int ctx_id, uint32_t handle, const char *name)
{
   /* the renderer keeps the iovec array itself, so it lives as long as the buffer */
   static struct iovec iovs[8];
   uint32_t *status = calloc(1, 64);
   struct iovec *iov = &iovs[ctx_id & 7];
   *iov = (struct iovec){ status, 64 };
   struct virgl_renderer_resource_create_args a = {
      .handle = handle, .target = T_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_CUSTOM, .width = 64, .height = 1, .depth = 1, .array_size = 1,
   };
   uint32_t cmd[2] = { VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0,
                                  VIRGL_SET_RESET_STATUS_BUFFER_SIZE), handle };
   if (virgl_renderer_context_create(ctx_id, (uint32_t)strlen(name), name) ||
       virgl_renderer_resource_create(&a, NULL, 0) ||
       virgl_renderer_resource_attach_iov(handle, iov, 1))
      return status;
   virgl_renderer_ctx_attach_resource(ctx_id, handle);
   virgl_renderer_submit_cmd(cmd, ctx_id, 2);
   return status;
}

static uint32_t *status_context(int ctx_id, uint32_t handle)
{
   return named_context(ctx_id, handle, "test");
}

/* Names the context's status buffer again (changes nothing); a lost context refuses
 * every submit. */
static int submit_nothing(int ctx_id)
{
   uint32_t cmd[2] = { VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0,
                                  VIRGL_SET_RESET_STATUS_BUFFER_SIZE), 899 + ctx_id };
   return virgl_renderer_submit_cmd(cmd, ctx_id, 2);
}

/* The guest's kernel makes a resource without waiting for the answer: the app learns
 * of a refusal only through its context. The context that attaches a refused handle is
 * lost and its status buffer says so; others, and a refused handle the guest freed
 * before attaching it, are not touched. */
static void run_refused_context(void)
{
   uint32_t *st2 = status_context(2, 901), *st3 = status_context(3, 902);
   check(st2[0] == 0 && st3[0] == 0 && submit_nothing(2) == 0 && submit_nothing(3) == 0,
         "two contexts with status buffers, both alive");
   uint32_t h[64] = {0};
   int n = 0;
   while (n < 64 && (h[n] = tex2d(1024, 1024, 1)))
      n++;
   struct virgl_renderer_resource_create_args a = {
      .handle = 950, .target = T_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_SAMPLER_VIEW, .width = 1024, .height = 1024, .depth = 1,
      .array_size = 1,
   };
   check(virgl_renderer_resource_create(&a, NULL, 0) != 0, "budget full: resource 950 refused");
   a.handle = 951;
   check(virgl_renderer_resource_create(&a, NULL, 0) != 0, "and resource 951");
   virgl_renderer_ctx_attach_resource(3, 960);
   check(st3[0] == 0 && submit_nothing(3) == 0,
         "attaching a handle that was never made does not lose a context");
   virgl_renderer_resource_unref(951);
   virgl_renderer_ctx_attach_resource(3, 951);
   check(st3[0] == 0 && submit_nothing(3) == 0,
         "a refused handle the guest freed first does not lose a context");
   virgl_renderer_ctx_attach_resource(2, 950);
   check(st2[0] == VIRGL_RESET_STATUS_GUILTY,
         "the context that attaches a refused resource reads GUILTY in its status buffer");
   check(submit_nothing(2) != 0, "and its commands are refused from then on");
   check(st3[0] == 0 && submit_nothing(3) == 0, "the other context keeps working");
   virgl_renderer_ctx_attach_resource(3, 950);
   check(st3[0] == 0, "a refused handle loses only the first context that attaches it");
   unref(h, n);
   virgl_renderer_resource_unref(950);
   virgl_renderer_context_destroy(2);
   virgl_renderer_context_destroy(3);
   virgl_renderer_resource_unref(901);
   virgl_renderer_resource_unref(902);
   free(st2);
   free(st3);
   a.handle = 950;
   uint32_t again = virgl_renderer_resource_create(&a, NULL, 0) ? 0 : 950;
   check(again != 0, "with the budget free again, handle 950 is made");
   if (again)
      virgl_renderer_resource_unref(again);
}

/* Not lost: nothing in its status buffer and its commands go through. */
static int alive(int ctx_id, const uint32_t *status)
{
   return status[0] == 0 && submit_nothing(ctx_id) == 0;
}

static int lost(int ctx_id, const uint32_t *status)
{
   int refused = submit_nothing(ctx_id) != 0;
   if (status[0] != VIRGL_RESET_STATUS_GUILTY || !refused)
      printf("   (context %d: status %u, commands %s)\n", ctx_id, status[0], refused ? "refused" : "taken");
   return status[0] == VIRGL_RESET_STATUS_GUILTY && refused;
}

/* A 4 MB texture for context CTX_ID: made, then attached to it, as the guest's kernel
 * does; 0 when the renderer refused it. */
static uint32_t tex_for(int ctx_id)
{
   uint32_t h = tex2d(1024, 1024, 1);
   if (h)
      virgl_renderer_ctx_attach_resource(ctx_id, h);
   return h;
}

/* A buffer of SIZE bytes made in context CTX_ID's own commands (its context is known at
 * once); the submit's result. */
static int pipe_buffer(int ctx_id, uint32_t size, uint32_t blob_id)
{
   uint32_t cmd[12] = { VIRGL_CMD0(VIRGL_CCMD_PIPE_RESOURCE_CREATE, 0, VIRGL_PIPE_RES_CREATE_SIZE) };
   cmd[VIRGL_PIPE_RES_CREATE_TARGET] = T_BUFFER;
   cmd[VIRGL_PIPE_RES_CREATE_FORMAT] = VIRGL_FORMAT_R8_UNORM;
   cmd[VIRGL_PIPE_RES_CREATE_BIND] = VIRGL_BIND_VERTEX_BUFFER;
   cmd[VIRGL_PIPE_RES_CREATE_WIDTH] = size;
   cmd[VIRGL_PIPE_RES_CREATE_HEIGHT] = cmd[VIRGL_PIPE_RES_CREATE_DEPTH] = 1;
   cmd[VIRGL_PIPE_RES_CREATE_ARRAY_SIZE] = 1;
   cmd[VIRGL_PIPE_RES_CREATE_BLOB_ID] = blob_id;
   return virgl_renderer_submit_cmd(cmd, ctx_id, 12);
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

   run_refused_context();

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
   uint64_t mem = mac_memory();
   uint32_t default_mb = (uint32_t)(mem / 4 * 3 / MB);
   char line[160];
   uint32_t a = make(T_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_STAGING, 4096, 1, 1, 1, 0, 0);
   check(a != 0, "default budget: a small resource fits");
   /* 16384x16384 RGBA32F, 64 layers = 256 GB: refused unless three quarters of the
    * memory are 256 GB or more */
   uint32_t b = make(T_2D_ARRAY, VIRGL_FORMAT_R32G32B32A32_FLOAT, VIRGL_BIND_SAMPLER_VIEW,
                     16384, 16384, 1, 64, 0, 0);
   snprintf(line, sizeof line, "default budget (%u MB = three quarters of %llu MB): a 256 GB "
            "texture array is refused", default_mb, (unsigned long long)(mem / MB));
   check(default_mb >= 262144 ? 1 : b == 0, line);
   /* the desktop reserve: a sixteenth of the Mac, 512 MB to 2 GB, at most a quarter of the budget */
   uint64_t reserve = mem / 16;
   reserve = reserve < 512ull * MB ? 512ull * MB : reserve > 2048ull * MB ? 2048ull * MB : reserve;
   if (reserve > (uint64_t)default_mb * MB / 4)
      reserve = (uint64_t)default_mb * MB / 4;
   settle();
   snprintf(line, sizeof line, "the desktop keeps the last %llu MB of it: reserve_mb=%ld, apps_mb=%ld",
            (unsigned long long)(reserve / MB), status_value("reserve_mb", NULL, 0),
            status_value("apps_mb", NULL, 0));
   check(status_value("reserve_mb", NULL, 0) == (long)(reserve / MB) &&
         status_value("apps_mb", NULL, 0) == (long)(default_mb - reserve / MB), line);
   if (a)
      virgl_renderer_resource_unref(a);
   if (b)
      virgl_renderer_resource_unref(b);
   return 0;
}

static uint64_t mac_memory(void)
{
   uint64_t mem = 0;
   size_t len = sizeof mem;
   sysctlbyname("hw.memsize", &mem, &len, NULL, 0);
   return mem;
}

static double now_s(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* "KEY=" value from the status file, or -1 (text values: 0 and copied to out). */
static long status_value(const char *key, char *out, size_t out_len)
{
   char line[256];
   long v = -1;
   FILE *f = fopen(getenv("OMACVM_GPU_MEMORY_STATUS"), "r");
   if (!f)
      return -1;
   while (fgets(line, sizeof line, f)) {
      size_t k = strlen(key);
      if (!strncmp(line, key, k) && line[k] == '=') {
         line[strcspn(line, "\n")] = 0;
         if (out) {
            snprintf(out, out_len, "%s", line + k + 1);
            v = 0;
         } else {
            v = strtol(line + k + 1, NULL, 10);
         }
      }
   }
   fclose(f);
   return v;
}

/* The renderer writes the status file at most four times a second, from its poll. */
static void settle(void)
{
   usleep(300000);
   virgl_renderer_poll();
}

static int sampler_view(int ctx_id, uint32_t handle, uint32_t res);

static int run_critical(void)
{
   char line[200], text[64] = "";
   uint32_t *app = named_context(2, 901, "chromium"), *desk = named_context(3, 902, "Hyprland");
   double t = now_s();
   uint32_t big = tex2d(4096, 4096, 1);   /* 64 MB */
   double waited = now_s() - t;
   check(big != 0, "pressure critical: a 64 MB texture is made, for the desktop only");
   snprintf(line, sizeof line, "after trimming and looking again (%.0f ms)", waited * 1000);
   check(waited >= 0.09, line);
   virgl_renderer_ctx_attach_resource(2, big);
   check(lost(2, app), "chromium attaches it: chromium is lost, told GUILTY");
   check(status_value("lost_why", text, sizeof text) == 0 && !strcmp(text, "pressure"),
         "the status file says lost_why=pressure");
   check(status_value("refused", NULL, 0) == 1, "and refused=1");
   check(status_value("pressure", text, sizeof text) == 0 && !strcmp(text, "critical"),
         "and pressure=critical");
   /* chromium was not told and hands that buffer to the compositor: Hyprland finds its
    * empty stand-in (virgl-gpu-guard-dropped-placeholder.patch) and is not lost */
   virgl_renderer_ctx_attach_resource(3, big);
   check(sampler_view(3, 70, big) == 0 && alive(3, desk),
         "Hyprland imports chromium's dropped buffer and samples it: Hyprland keeps drawing");
   /* the next big one within a second: after one look, no 100 ms hold */
   t = now_s();
   uint32_t big2 = tex2d(4096, 4096, 1);
   waited = now_s() - t;
   check(big2 != 0, "a second 64 MB texture right after is made for the desktop only too");
   snprintf(line, sizeof line, "at once, without holding the VM (%.0f ms)", waited * 1000);
   check(waited < 0.05, line);
   virgl_renderer_ctx_attach_resource(3, big2);
   check(alive(3, desk), "Hyprland attaches it and keeps drawing");
   uint32_t small = tex2d(1024, 2048, 1); /* 8 MB */
   check(small != 0, "an 8 MB texture fits (small ones are never held back for pressure)");
   uint32_t scan = make(T_2D, VIRGL_FORMAT_B8G8R8X8_UNORM, VIRGL_BIND_SCANOUT | VIRGL_BIND_RENDER_TARGET,
                        5120, 2880, 1, 1, 0, 0);
   check(scan != 0, "a 5K screen (56 MB) fits (screens are never held back for pressure)");
   uint32_t *ff = named_context(4, 903, "firefox");
   check(pipe_buffer(4, 64 * MB, 11) != 0, "firefox's own 64 MB pipe buffer is refused at once");
   check(status_value("lost_why", text, sizeof text) == 0 && !strcmp(text, "pressure") && !alive(4, ff),
         "firefox is lost, lost_why=pressure");
   check(pipe_buffer(3, 64 * MB, 12) == 0, "Hyprland's own 64 MB pipe buffer is made");
   check(alive(3, desk), "and Hyprland keeps drawing");
   settle();
   check(status_value("in_use_mb", NULL, 0) == 64 + 64 + 64,
         "in_use_mb=192 (Hyprland's 64 MB texture, 8 MB texture + 5K screen, Hyprland's buffer; "
         "chromium's gave its memory back)");
   virgl_renderer_context_destroy(4);
   virgl_renderer_context_destroy(3);
   virgl_renderer_context_destroy(2);
   uint32_t done[] = { big, big2, small, scan, 901, 902, 903 };
   unref(done, 7);
   free(app);
   free(desk);
   free(ff);
   return 0;
}

static int run_warn(void)
{
   /* the parent set macOS's free, inactive and purgeable memory to 100 MB */
   uint32_t *app = named_context(2, 901, "chromium");
   uint32_t a = tex_for(2);
   uint32_t b = tex2d(4096, 4096, 1);     /* 64 MB */
   check(a != 0 && b != 0, "pressure warn: a 64 MB texture fits into the 100 MB macOS has left");
   virgl_renderer_ctx_attach_resource(2, b);
   check(alive(2, app), "chromium keeps it");
   uint32_t c = tex2d(8192, 4096, 1);     /* 128 MB */
   check(c != 0, "a 128 MB texture, more than macOS has left, is made for the desktop only");
   virgl_renderer_ctx_attach_resource(2, c);
   check(lost(2, app), "chromium attaches it: chromium is lost");
   virgl_renderer_context_destroy(2);
   uint32_t done[] = { a, b, c, 901 };
   unref(done, 4);
   free(app);
   return 0;
}

static int run_reserve(void)
{
   char text[64] = "";
   uint32_t h[16] = {0};
   /* every context first: each status buffer is a resource too (4 KB), and past the
    * apps' share a new one would already be for the desktop only */
   uint32_t *app = named_context(2, 901, "chromium"), *desk = named_context(3, 902, "Hyprland"),
            *bar = named_context(4, 903, "quickshell"), *ff = named_context(5, 904, "firefox"),
            *app2 = named_context(6, 905, "chromium");
   check(alive(2, app) && alive(3, desk) && alive(4, bar) && alive(5, ff) && alive(6, app2),
         "chromium, Hyprland, quickshell, firefox and a second chromium, all alive");
   settle();
   check(status_value("apps_mb", NULL, 0) == 48 && status_value("reserve_mb", NULL, 0) == 16,
         "a 64 MB budget: apps_mb=48, reserve_mb=16 (a quarter, the most a reserve takes)");
   /* five status buffers of 4 KB are in use: 11 textures of 4 MB fit into the apps' 48 MB */
   int n = 0;
   while (n < 11 && (h[n] = tex_for(2)))
      n++;
   check(n == 11 && alive(2, app), "chromium makes 11 textures of 4 MB (44 MB) and keeps drawing");
   h[n] = tex2d(2048, 2048, 1);           /* 16 MB: the status file follows in 8 MB steps */
   check(h[n] != 0, "a 16 MB 12th (past the apps' 48 MB) is made, for the desktop only");
   virgl_renderer_ctx_attach_resource(2, h[n++]);
   check(lost(2, app), "chromium attaches it: chromium is lost, told GUILTY");
   check(alive(3, desk) && alive(4, bar), "Hyprland and quickshell keep drawing");
   check(status_value("lost_last", text, sizeof text) == 0 && !strcmp(text, "chromium"), "lost_last=chromium");
   check(alive(5, ff) && alive(6, app2), "the other apps keep drawing");

   check(status_value("lost_why", text, sizeof text) == 0 && !strcmp(text, "guard"),
         "lost_why=guard (the apps' share)");
   check(status_value("refused", NULL, 0) == 1, "refused=1");
   settle();
   check(status_value("in_use_mb", NULL, 0) == 44, "the 12th gave its memory back: in_use_mb=44");
   /* chromium's driver was not told (no status buffer read) and goes on: what it makes past
    * the share is dropped at once, no second loss */
   uint32_t more = tex2d(2048, 2048, 1);
   check(more != 0, "the lost chromium makes another texture: for the desktop only");
   virgl_renderer_ctx_attach_resource(2, more);
   settle();
   check(status_value("in_use_mb", NULL, 0) == 44 && status_value("lost", NULL, 0) == 1 &&
         status_value("refused", NULL, 0) == 2,
         "dropped at once: in_use_mb=44, still lost=1, refused=2");
   /* 44 MB + 20 KB in use: the desktop goes on into its reserve */
   uint32_t d1 = tex_for(3), d2 = tex_for(4), d3 = tex_for(3), d4 = tex_for(4);
   check(d1 && d2 && d3 && d4 && alive(3, desk) && alive(4, bar),
         "Hyprland and quickshell make four more of 4 MB from the reserve and keep drawing");
   check(tex2d(1024, 1024, 1) == 0, "past the whole 64 MB budget nothing is made, for the desktop neither");
   /* an import: a buffer the desktop took first stays the desktop's */
   virgl_renderer_ctx_attach_resource(5, d1);
   check(alive(5, ff), "firefox attaching a buffer Hyprland already took (an import) loses nothing");
   uint32_t ds[] = { d1, d2, d3, d4, more };
   unref(ds, 5);
   /* 44 MB + 20 KB in use: a new one is for the desktop only; freed before any context
    * takes it, it is forgotten */
   uint32_t f = tex2d(1024, 1024, 1);
   check(f != 0, "with the apps' share full, another texture is made for the desktop only");
   virgl_renderer_resource_unref(f);
   virgl_renderer_ctx_attach_resource(5, f);
   check(alive(5, ff), "freed before anyone took it: forgotten, firefox loses nothing");
   /* made in a context's own commands: whose it is is known at once */
   check(pipe_buffer(5, 4 * MB, 21) != 0, "firefox's own 4 MB pipe buffer past the apps' share is refused");
   check(!alive(5, ff) && status_value("lost_why", text, sizeof text) == 0 && !strcmp(text, "guard"),
         "firefox is lost, lost_why=guard");
   check(pipe_buffer(3, 8 * MB, 22) == 0 && alive(3, desk), "Hyprland's own 8 MB pipe buffer is made");
   check(status_value("lost_recent", text, sizeof text) == 0 && !strcmp(text, "chromium,firefox"),
         "lost_recent=chromium,firefox");
   check(status_value("lost_recent_why", text, sizeof text) == 0 && !strcmp(text, "guard,guard"),
         "lost_recent_why=guard,guard");
   virgl_renderer_context_destroy(2);
   unref(h, n);
   /* the app's textures are gone: the other chromium gets its share again */
   uint32_t again = tex_for(6);
   check(again != 0 && alive(6, app2), "chromium again after the old one ended: its textures fit");
   virgl_renderer_resource_unref(again);
   for (int c = 3; c <= 6; c++)
      virgl_renderer_context_destroy(c);
   uint32_t st[] = { 901, 902, 903, 904, 905 };
   unref(st, 5);
   free(app);
   free(desk);
   free(bar);
   free(ff);
   free(app2);
   return 0;
}

/* A sampler view HANDLE on the 2D texture RES, made in context CTX_ID's commands: how a
 * compositor draws a window (it samples the app's buffer). The submit's result. */
static int sampler_view(int ctx_id, uint32_t handle, uint32_t res)
{
   uint32_t cmd[1 + VIRGL_OBJ_SAMPLER_VIEW_SIZE] = {
      VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SAMPLER_VIEW, VIRGL_OBJ_SAMPLER_VIEW_SIZE) };
   cmd[VIRGL_OBJ_SAMPLER_VIEW_HANDLE] = handle;
   cmd[VIRGL_OBJ_SAMPLER_VIEW_RES_HANDLE] = res;
   cmd[VIRGL_OBJ_SAMPLER_VIEW_FORMAT] = VIRGL_FORMAT_R8G8B8A8_UNORM | (T_2D << 24);
   cmd[VIRGL_OBJ_SAMPLER_VIEW_TEXTURE_LAYER] = 0;
   cmd[VIRGL_OBJ_SAMPLER_VIEW_TEXTURE_LEVEL] = 0;
   cmd[VIRGL_OBJ_SAMPLER_VIEW_SWIZZLE] = VIRGL_OBJ_SAMPLER_VIEW_SWIZZLE_R(0) |
      VIRGL_OBJ_SAMPLER_VIEW_SWIZZLE_G(1) | VIRGL_OBJ_SAMPLER_VIEW_SWIZZLE_B(2) |
      VIRGL_OBJ_SAMPLER_VIEW_SWIZZLE_A(3);
   return virgl_renderer_submit_cmd(cmd, ctx_id, 1 + VIRGL_OBJ_SAMPLER_VIEW_SIZE);
}

/* A lost app's buffer is dropped (it gives its memory back), but the app may still have
 * handed it to the compositor (a Wayland buffer): Hyprland imports it (attach) and draws
 * it (a sampler view). 3.0.3-3.0.5 lost Hyprland there: the handle had no storage, so its
 * command named a resource that was not there (a black VM). Now a dropped buffer keeps an
 * empty 1x1 stand-in: the window shows empty, Hyprland keeps drawing, nothing is charged. */
static int run_dropped(void)
{
   char text[64] = "";
   uint32_t h[16] = {0};
   uint32_t *app = named_context(2, 901, "chromium"), *desk = named_context(3, 902, "Hyprland"),
            *ff = named_context(4, 903, "firefox");
   check(alive(2, app) && alive(3, desk) && alive(4, ff), "chromium, Hyprland and firefox, all alive");
   int n = 0;
   while (n < 11 && (h[n] = tex_for(2)))
      n++;
   check(n == 11 && alive(2, app), "chromium makes 11 textures of 4 MB (44 MB)");
   uint32_t big = tex2d(2048, 2048, 1);
   check(big != 0, "a 16 MB 12th (past the apps' 48 MB) is made, for the desktop only");
   virgl_renderer_ctx_attach_resource(2, big);
   check(lost(2, app), "chromium attaches it: chromium is lost, its buffer is dropped");
   settle();
   check(status_value("in_use_mb", NULL, 0) == 44, "the dropped buffer gave its memory back: in_use_mb=44");
   /* chromium was not told and hands the buffer to the compositor */
   virgl_renderer_ctx_attach_resource(3, big);
   check(sampler_view(3, 70, big) == 0, "Hyprland imports the dropped buffer and samples it: the command goes through");
   check(alive(3, desk), "Hyprland keeps drawing (not lost)");
   check(status_value("lost", NULL, 0) == 1 && status_value("lost_last", text, sizeof text) == 0 &&
         !strcmp(text, "chromium"), "still lost=1 (chromium only)");
   /* the lost chromium goes on: its next buffer is dropped at once, Hyprland shows it too */
   uint32_t more = tex2d(2048, 2048, 1);
   check(more != 0, "the lost chromium makes another buffer: for the desktop only");
   virgl_renderer_ctx_attach_resource(2, more);
   virgl_renderer_ctx_attach_resource(3, more);
   check(sampler_view(3, 71, more) == 0 && alive(3, desk), "Hyprland samples that one too and keeps drawing");
   virgl_renderer_ctx_attach_resource(4, more);
   check(sampler_view(4, 72, more) == 0 && alive(4, ff), "an app importing it is not lost either");
   settle();
   check(status_value("in_use_mb", NULL, 0) == 44, "the stand-ins cost nothing: in_use_mb=44");
   struct virgl_renderer_resource_info info;
   check(virgl_renderer_resource_get_info((int)big, &info) == 0 && info.width == 1 && info.height == 1,
         "a dropped buffer reads as an empty 1x1 texture");
   /* the guest frees them; the handles work again */
   uint32_t gone[] = { big, more };
   unref(gone, 2);
   virgl_renderer_context_destroy(2);
   unref(h, n);
   uint32_t again = tex_for(4);
   check(again != 0 && alive(4, ff) && alive(3, desk), "after chromium ended, firefox gets its share");
   virgl_renderer_resource_unref(again);
   virgl_renderer_context_destroy(3);
   virgl_renderer_context_destroy(4);
   uint32_t st[] = { 901, 902, 903 };
   unref(st, 3);
   free(app);
   free(desk);
   free(ff);
   return 0;
}

/* The renderer's log (stderr) while a step runs: log_start, the step, log_text. */
static int saved_stderr = -1;
static char log_path[256];
static void log_start(void)
{
   snprintf(log_path, sizeof log_path, "%s/omacvm-budget-log-%d",
            getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
   fflush(stderr);
   saved_stderr = dup(2);
   int fd = open(log_path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
   dup2(fd, 2);
   close(fd);
}

static void log_text(char *out, size_t out_len)
{
   fflush(stderr);
   dup2(saved_stderr, 2);
   close(saved_stderr);
   FILE *f = fopen(log_path, "r");
   size_t n = f ? fread(out, 1, out_len - 1, f) : 0;
   out[n] = 0;
   if (f)
      fclose(f);
   unlink(log_path);
   fputs(out, stderr);
}

/* The log says which line a refusal hit: an app's own resource stops at the apps' share
 * (the rest is the desktop's), anything else at the whole budget. 3.0.5's first guard
 * said "budget of 64 MB reached" for both. */
static int run_wording(void)
{
   char log[4096];
   uint32_t h[24] = {0};
   uint32_t *app = named_context(2, 901, "foot"), *desk = named_context(3, 902, "Hyprland");
   int n = 0;
   while (n < 11 && (h[n] = tex_for(2)))
      n++;
   check(n == 11 && alive(2, app), "foot makes 11 textures of 4 MB (44 MB)");
   log_start();
   int refused = pipe_buffer(2, 8 * MB, 31) != 0;
   log_text(log, sizeof log);
   check(refused, "foot's own 8 MB pipe buffer past the apps' share is refused");
   check(strstr(log, "apps' share of 48 MB reached (the last 16 MB of the 64 MB budget are kept "
                     "for the desktop)") != NULL, "the log says the apps' share of 48 MB was reached");
   check(strstr(log, "budget of 64 MB reached") == NULL, "and not that the 64 MB budget was reached");
   log_start();
   while (n < 24 && (h[n] = tex_for(3)))
      n++;
   log_text(log, sizeof log);
   check(n == 15, "Hyprland takes four more of 4 MB, then nothing more is made");
   check(strstr(log, "budget of 64 MB reached") != NULL, "past the whole budget the log says the 64 MB budget was reached");
   check(alive(3, desk), "Hyprland is still alive");
   unref(h, n);
   virgl_renderer_context_destroy(2);
   virgl_renderer_context_destroy(3);
   uint32_t st[] = { 901, 902 };
   unref(st, 2);
   free(app);
   free(desk);
   return 0;
}

static int run_status(void)
{
   uint32_t h[10] = {0};
   char text[64] = "";
   for (int i = 0; i < 10; i++)
      h[i] = tex2d(1024, 1024, 1);
   settle();
   check(status_value("in_use_mb", NULL, 0) == 40 && status_value("peak_mb", NULL, 0) == 40,
         "10 textures of 4 MB: in_use_mb=40, peak_mb=40");
   check(status_value("budget_mb", NULL, 0) == 0, "budget_mb=0 (OMACVM_GPU_MEMORY_MB=0)");
   check(status_value("pressure", text, sizeof text) == 0 && !strcmp(text, "normal"), "pressure=normal");
   unref(h, 10);
   settle();
   check(status_value("in_use_mb", NULL, 0) == 0 && status_value("peak_mb", NULL, 0) == 40,
         "all freed: in_use_mb=0, the peak stays 40");
   /* a lost context: the name is the guest's, only letters, digits and . _ - pass */
   check(virgl_renderer_context_create(1, (uint32_t)strlen("Hypr\nland=1"), "Hypr\nland=1") == 0, "a context");
   uint32_t cmd[] = { VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)),
                      1, 0, 77 };      /* a surface that was never made */
   virgl_renderer_submit_cmd(cmd, 1, 4);
   check(status_value("lost", NULL, 0) == 1, "its loss is in the status file at once: lost=1");
   check(status_value("lost_last", text, sizeof text) == 0 && !strcmp(text, "Hypr_land_1"),
         "lost_last=Hypr_land_1");
   /* a second loss right after: the app must still see that the first one was lost */
   check(virgl_renderer_context_create(2, 8, "chromium") == 0, "a second context");
   virgl_renderer_submit_cmd(cmd, 2, 4);
   check(status_value("lost", NULL, 0) == 2 &&
         status_value("lost_recent", text, sizeof text) == 0 && !strcmp(text, "Hypr_land_1,chromium"),
         "lost=2, lost_recent=Hypr_land_1,chromium");
   virgl_renderer_context_destroy(2);
   virgl_renderer_context_destroy(1);
   return 0;
}

/* OMACVM_GPU_MEMORY_PRESSURE=file:PATH: the level changes while the renderer runs */
static void level_to(const char *level)
{
   FILE *f = fopen(getenv("OMACVM_TEST_LEVEL_FILE"), "w");
   if (f) {
      fprintf(f, "%s\n", level);
      fclose(f);
   }
}

static int run_levelfile(void)
{
   char text[64] = "";
   uint32_t a = tex2d(4096, 4096, 1);     /* 64 MB */
   check(a != 0, "level file says normal: a 64 MB texture fits");
   level_to("critical");
   uint32_t *app = named_context(2, 901, "chromium");
   uint32_t b = tex2d(4096, 4096, 1);
   virgl_renderer_ctx_attach_resource(2, b);
   check(b != 0 && lost(2, app), "level file says critical: the next 64 MB texture is for the desktop only, "
         "chromium that takes it is lost");
   usleep(1100000);                       /* the once-a-second look */
   settle();
   check(status_value("pressure", text, sizeof text) == 0 && !strcmp(text, "critical"),
         "the status file follows: pressure=critical");
   level_to("normal");
   uint32_t c = tex2d(4096, 4096, 1);
   check(c != 0, "back to normal: a 64 MB texture fits again");
   virgl_renderer_context_destroy(2);
   uint32_t done[] = { a, b, c, 901 };
   unref(done, 4);
   free(app);
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
   else if (!strcmp(mode, "critical"))
      run_critical();
   else if (!strcmp(mode, "warn"))
      run_warn();
   else if (!strcmp(mode, "reserve"))
      run_reserve();
   else if (!strcmp(mode, "dropped"))
      run_dropped();
   else if (!strcmp(mode, "wording"))
      run_wording();
   else if (!strcmp(mode, "status"))
      run_status();
   else if (!strcmp(mode, "levelfile"))
      run_levelfile();
   else
      run_default();
   virgl_renderer_cleanup(&cookie);
   return failures != 0;
}

static int spawn(const char *self, const char *mode, const char *budget, const char *pressure)
{
   if (budget)
      setenv("OMACVM_GPU_MEMORY_MB", budget, 1);
   else
      unsetenv("OMACVM_GPU_MEMORY_MB");
   setenv("OMACVM_GPU_MEMORY_PRESSURE", pressure, 1);
   char *argv[] = { (char *)self, (char *)mode, NULL };
   pid_t pid;
   int status = 0;
   printf("-- %s (OMACVM_GPU_MEMORY_MB=%s, OMACVM_GPU_MEMORY_PRESSURE=%s)\n", mode,
          budget ? budget : "unset", pressure);
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
   char status_file[256];
   snprintf(status_file, sizeof status_file, "%s/omacvm-gpu-memory-test-%d",
            getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
   setenv("OMACVM_GPU_MEMORY_STATUS", status_file, 1);
   char level_file[300], level_env[310];
   snprintf(level_file, sizeof level_file, "%s.level", status_file);
   snprintf(level_env, sizeof level_env, "file:%s", level_file);
   setenv("OMACVM_TEST_LEVEL_FILE", level_file, 1);
   FILE *lf = fopen(level_file, "w");
   if (lf) {
      fputs("normal\n", lf);
      fclose(lf);
   }
   int bad = spawn(argv[0], "limit", "64", "off") + spawn(argv[0], "off", "0", "off") +
             spawn(argv[0], "default", NULL, "off") + spawn(argv[0], "critical", "0", "critical") +
             spawn(argv[0], "warn", "0", "warn:100") + spawn(argv[0], "status", "0", "normal") +
             spawn(argv[0], "reserve", "64", "off") + spawn(argv[0], "dropped", "64", "off") +
             spawn(argv[0], "wording", "64", "off") +
             spawn(argv[0], "levelfile", "0", level_env);
   unlink(status_file);
   unlink(level_file);
   printf("%s\n", bad ? "resource budget: FAILED" : "resource budget: all checks passed");
   return bad != 0;
}
