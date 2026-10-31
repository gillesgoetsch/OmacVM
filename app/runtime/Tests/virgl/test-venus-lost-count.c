/* A lost Venus context counts in the status file with its app's name, like a lost GL
 * context (virgl-venus-lost-context-count.patch), through the public renderer API.
 *
 * The app's ring is ended the way vkr ends a guest's: a command it cannot dispatch, on
 * the ring thread (vkr's ring-fatal path, "venus context N (NAME) is lost"). The status
 * file (OMACVM_GPU_MEMORY_STATUS), which OmacVM.app reads every 5 s, must then say
 * lost=1 with the name, why (venus, or guard when the budget had refused memory of that
 * context) and the kind (venus). Without the patch it stays at lost=0 (the 4 lose rows of
 * tracks/ghostty-gpu.md: gpu_lost_delta 0). A context the guest was closing is not
 * counted: test-venus-robust.c's l-teardown (it needs vkr's own calls).
 *
 * The renderer runs as QEMU's (GL on Apple's software renderer, soft-gl.h; Venus in this
 * process with the render server as a thread). run-regressions.py links a stub libvulkan
 * that lets a Venus context start while any real Vulkan call fails: rings and shm blobs
 * need no driver, so no GPU is used. Each mode in its own process (the settings are read
 * once at the start):
 *   test-venus-lost-count            every mode below, then a summary
 *   test-venus-lost-count lost       a bad ring command: lost=1, the name, venus; a second
 *                                    ring of the same app failing after it: still 1
 *   test-venus-lost-count guard      OMACVM_GPU_MEMORY_MB=64: a 60 MB blob refused, then a
 *                                    bad ring command: lost=1 with why guard */
#include <OpenGL/OpenGL.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "config.h"
#include "soft-gl.h"
#include "virglrenderer.h"

extern char **environ;

#define VENUS_CAPSET 4
#define CTX 1
#define RING_RES 2
#define RING2_RES 3
#define BIG_RES 4
#define SHM_SIZE 65536
/* venus-protocol (vn_protocol_renderer_defines.h) */
#define CMD_CREATE_RING 188        /* VK_COMMAND_TYPE_vkCreateRingMESA_EXT */
#define RING_CREATE_INFO 1000384000 /* VK_STRUCTURE_TYPE_RING_CREATE_INFO_MESA */
#define RING_STATUS_FATAL 0x2      /* VK_RING_STATUS_FATAL_BIT_MESA */
/* the ring's layout in its shm blob: head, tail, status, then the buffer */
#define RING_BUFFER 64
#define RING_BUFFER_SIZE 4096

static CGLContextObj main_ctx;
static int failures;
static char log_text[1 << 16];
static size_t log_len;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void log_cb(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)level;
   (void)data;
   printf("log: %s", message);
   size_t n = strlen(message);
   if (log_len + n < sizeof(log_text)) {
      memcpy(log_text + log_len, message, n + 1);
      log_len += n;
   }
}

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   (void)fence;
}

static void write_context_fence(void *cookie, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id)
{
   (void)cookie;
   (void)ctx_id;
   (void)ring_idx;
   (void)fence_id;
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
   .version = 3,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
   .write_context_fence = write_context_fence,
};

/* ---- the guest's commands: 4-byte units, as the guest's vn_cs_encoder ---- */
static uint32_t cs[256];
static size_t cs_n;

static void u32(uint32_t v)
{
   cs[cs_n++] = v;
}

static void u64(uint64_t v)
{
   u32((uint32_t)v);
   u32((uint32_t)(v >> 32));
}

static int submit(void)
{
   int ret = virgl_renderer_submit_cmd(cs, CTX, (int)cs_n);
   cs_n = 0;
   return ret;
}

/* a Venus shm blob attached to the context, mapped as the guest maps it */
static uint8_t *blob(uint32_t handle, uint64_t size)
{
   struct virgl_renderer_resource_create_blob_args args = {
      .res_handle = handle,
      .ctx_id = CTX,
      .blob_mem = VIRGL_RENDERER_BLOB_MEM_HOST3D,
      .blob_flags = VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE,
      .blob_id = 0,
      .size = size,
   };
   void *map = NULL;
   uint64_t map_size = 0;
   if (virgl_renderer_resource_create_blob(&args))
      return NULL;
   virgl_renderer_ctx_attach_resource(CTX, handle);
   if (virgl_renderer_resource_map(handle, &map, &map_size) || map_size < size)
      return NULL;
   return map;
}

/* vkCreateRingMESA on the blob: polls its tail for 30 s before it waits for a notify */
static void create_ring(uint64_t ring_id, uint32_t res)
{
   u32(CMD_CREATE_RING); u32(0);
   u64(ring_id); u64(1);                 /* the ring's id, pCreateInfo */
   u32(RING_CREATE_INFO); u64(0);        /* sType, pNext */
   u32(0); u32(res);                     /* flags, resourceId */
   u64(0); u64(SHM_SIZE);                /* offset, size */
   u64(30000000000ull);                  /* idleTimeout (ns) */
   u64(0); u64(4); u64(8);               /* head, tail, status */
   u64(RING_BUFFER); u64(RING_BUFFER_SIZE);
   u64(RING_BUFFER + RING_BUFFER_SIZE); u64(0); /* extra */
   submit();
}

/* puts the command WORD (no flags) into the ring and moves its tail, as the guest does */
static void ring_command(uint8_t *shm, uint32_t word)
{
   const uint32_t cmd[2] = { word, 0 };
   volatile uint32_t *tail = (volatile uint32_t *)(shm + 4);
   uint32_t at = *tail;
   memcpy(shm + RING_BUFFER + (at % RING_BUFFER_SIZE), cmd, sizeof(cmd));
   atomic_thread_fence(memory_order_seq_cst);
   *tail = at + (uint32_t)sizeof(cmd);
}

static int ring_fatal(const uint8_t *shm)
{
   return (*(const volatile uint32_t *)(shm + 8) & RING_STATUS_FATAL) != 0;
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
   char line[1024];
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

static int is(const char *key, const char *want)
{
   char text[256] = "";
   return status_value(key, text, sizeof text) == 0 && !strcmp(text, want);
}

/* QEMU polls the renderer while the guest works; the status file is written there. Waits
 * until the ring says fatal and lost reaches WANT (or SECONDS pass); then two more polls. */
static long poll_until(const uint8_t *shm, long want, double seconds)
{
   double end = now_s() + seconds;
   while (now_s() < end && !(ring_fatal(shm) && status_value("lost", NULL, 0) >= want)) {
      virgl_renderer_poll();
      usleep(20000);
   }
   for (int i = 0; i < 2; i++) {
      usleep(20000);
      virgl_renderer_poll();
   }
   return status_value("lost", NULL, 0);
}

static int start(void)
{
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   virgl_set_log_callback(log_cb, NULL, NULL);
   static int cookie;
   if (virgl_renderer_init(&cookie, VIRGL_RENDERER_VENUS | VIRGL_RENDERER_RENDER_SERVER |
                                    VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB,
                           &callbacks)) {
      printf("FAIL: renderer with GL and Venus did not start\n");
      return -1;
   }
   return 1;
}

static int run_lost(void)
{
   const char *name = "vkcube";
   check(virgl_renderer_context_create_with_flags(CTX, VENUS_CAPSET, (uint32_t)strlen(name), name) == 0,
         "a Venus context named vkcube");
   uint8_t *ring = blob(RING_RES, SHM_SIZE), *ring2 = blob(RING2_RES, SHM_SIZE);
   check(ring && ring2, "two shm blobs for its rings");
   if (!ring || !ring2)
      return 0;
   create_ring(77, RING_RES);
   create_ring(78, RING2_RES);
   virgl_renderer_poll();
   check(status_value("lost", NULL, 0) == 0, "before: lost=0");
   ring_command(ring, 0x7fffu);          /* no such command */
   long lost = poll_until(ring, 1, 3.0);
   check(ring_fatal(ring), "the ring says fatal (the guest's driver sees it)");
   check(strstr(log_text, "venus context 1 (vkcube) is lost") != NULL, "QEMU's log names it");
   check(lost == 1, "the status file: lost=1");
   check(is("lost_last", "vkcube") && is("lost_recent", "vkcube"), "lost_last=vkcube, lost_recent=vkcube");
   check(is("lost_why", "venus") && is("lost_recent_why", "venus"), "why: venus");
   check(is("lost_recent_kind", "venus"), "kind: venus");
   /* the same app's second ring fails after it: the same lost context */
   ring_command(ring2, 0x10u);
   lost = poll_until(ring2, 1, 3.0);
   check(ring_fatal(ring2) && lost == 1, "its second ring fails too: still lost=1");
   virgl_renderer_context_destroy(CTX);
   return 0;
}

static int run_guard(void)
{
   const char *name = "chromium";
   check(virgl_renderer_context_create_with_flags(CTX, VENUS_CAPSET, (uint32_t)strlen(name), name) == 0,
         "a Venus context named chromium");
   uint8_t *ring = blob(RING_RES, SHM_SIZE);
   check(ring != NULL, "a shm blob for its ring");
   if (!ring)
      return 0;
   check(blob(BIG_RES, 60u << 20) == NULL, "a 60 MB blob past the apps' share of a 64 MB budget is refused");
   create_ring(77, RING_RES);
   ring_command(ring, 0x7fffu);
   long lost = poll_until(ring, 1, 3.0);
   check(lost == 1 && is("lost_last", "chromium"), "lost=1, lost_last=chromium");
   check(is("lost_why", "guard") && is("lost_recent_kind", "venus"), "why: guard (its memory was refused), kind: venus");
   check(strstr(log_text, "(the GPU memory budget had refused its memory)") != NULL, "QEMU's log says so");
   virgl_renderer_context_destroy(CTX);
   return 0;
}

static int child(const char *mode)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   int s = start();
   if (s <= 0)
      return s < 0;
   if (!strcmp(mode, "lost"))
      run_lost();
   else
      run_guard();
   /* no virgl_renderer_cleanup: joining the in-process render server thread waits for a
    * socket it has not closed yet (QEMU never cleans up either) */
   printf("%s: %s\n", mode, failures ? "FAILED" : "all ok");
   return failures != 0;
}

static int spawn(const char *self, const char *mode, const char *budget)
{
   setenv("OMACVM_GPU_MEMORY_MB", budget, 1);
   setenv("OMACVM_GPU_MEMORY_PRESSURE", "off", 1);
   char *argv[] = { (char *)self, (char *)mode, NULL };
   pid_t pid;
   int status = 0;
   printf("-- %s (OMACVM_GPU_MEMORY_MB=%s)\n", mode, budget);
   unlink(getenv("OMACVM_GPU_MEMORY_STATUS"));
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
#ifndef ENABLE_RENDER_SERVER_WORKER_THREAD
   (void)argc;
   (void)argv;
   printf("skip: this build forks the render server (no in-process Venus to test)\n");
   return 0;
#else
   if (argc > 1)
      return child(argv[1]);
   setvbuf(stdout, NULL, _IONBF, 0);
   char status_file[256];
   snprintf(status_file, sizeof status_file, "%s/omacvm-venus-lost-test-%d",
            getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", (int)getpid());
   setenv("OMACVM_GPU_MEMORY_STATUS", status_file, 1);
   int bad = spawn(argv[0], "lost", "0") + spawn(argv[0], "guard", "64");
   unlink(status_file);
   printf("%s\n", bad ? "venus lost count: FAILED" : "venus lost count: all checks passed");
   return bad != 0;
#endif
}
