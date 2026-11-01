/* The threads guest calls make stay inside one budget for the process, and Venus contexts
 * inside the open-file limit (virgl-venus-thread-budget.patch, ADR 0065): past them the
 * guest's call fails cleanly, one line says so, and every thread taken is given back.
 *
 * With a small budget (OMACVM_VENUS_THREADS, the patch's test hook) each case drives the
 * thread sites to that failure, one process each:
 *   contexts       Venus contexts through the public API, as QEMU makes them (the render
 *                  server in this process): a render worker and a fence thread each;
 *   rings          vkCreateRingMESA with a ring monitor on one context: a thread per ring
 *                  and the monitor's;
 *   queues         vkCreateDevice again and again on one context: a sync thread per queue;
 *   context-files  a soft open-file limit of 64: contexts stop at 64 / 16, before the files
 *                  run out, and one context takes at most 8 files.
 * Each checks the budget's count and the task's threads virgl named are back where they
 * started once the contexts are gone. Objects only, nothing is submitted, no GPU work.
 *
 *   test-venus-threads          every case, one process each, then a summary
 *   test-venus-threads CASE     one case
 * The driver is vkr's choice from OMACVM_VULKAN_DRIVER, the binary sits beside the
 * runtime's loader and drivers (run-venus-limits.py builds that folder). */
#include <fcntl.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

#include "virgl_context.h"
#include "virgl_util.h"
#include "virglrenderer.h"
#include "vkr_context.h"
#include "vkr_physical_device.h"
#include "vkr_renderer.h"

extern char **environ;

enum { OK = 10, FAILED = 11, SKIP = 13, BROKEN = 2 };

static char log_text[1 << 16];
static size_t log_len;

static void log_cb(enum virgl_log_level_flags level, const char *message, void *data)
{
   (void)level;
   (void)data;
   printf("log: %s", message);
   const size_t n = strlen(message);
   if (log_len + n < sizeof(log_text)) {
      memcpy(log_text + log_len, message, n + 1);
      log_len += n;
   }
}

static bool logged(const char *needle)
{
   return strstr(log_text, needle) != NULL;
}

static int failures;

static void check(bool ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

/* the task's threads virgl names (vkr-queue-, vkr-ring-, vkr-ringmon-, a context's
 * virgl-N-...); the drivers' own threads and GCD's come and go apart from them */
static int task_threads_now(void)
{
   thread_act_array_t threads;
   mach_msg_type_number_t count = 0;
   if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS)
      return -1;
   int named = 0;
   for (mach_msg_type_number_t i = 0; i < count; i++) {
      thread_extended_info_data_t info;
      mach_msg_type_number_t n = THREAD_EXTENDED_INFO_COUNT;
      if (thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&info, &n) == KERN_SUCCESS &&
          (!strncmp(info.pth_name, "vkr-", 4) || !strncmp(info.pth_name, "virgl-", 6)))
         named++;
      mach_port_deallocate(mach_task_self(), threads[i]);
   }
   vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(threads[0]));
   return named;
}

/* virgl's threads end where they were (a thread ends a moment after its join) */
static bool threads_back(int start)
{
   for (int i = 0; i < 250; i++) {
      if (task_threads_now() <= start)
         return true;
      usleep(20000);
   }
   printf("virgl's threads: %d, at the start %d\n", task_threads_now(), start);
   return false;
}

/* the budget's count reaches want (the render server joins a context's worker after the
 * proxy's destroy returns) */
static bool budget_settles(int want)
{
   for (int i = 0; i < 250; i++) {
      if (virgl_thread_budget_used() == want)
         return true;
      usleep(20000);
   }
   printf("budget count: %d, wanted %d\n", virgl_thread_budget_used(), want);
   return false;
}

static int open_files(void)
{
   int n = 0;
   for (int fd = 0; fd < 4096; fd++)
      n += fcntl(fd, F_GETFD) != -1;
   return n;
}

/* ---- the public API: QEMU's path ---- */
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

static struct virgl_renderer_callbacks callbacks = {
   .version = 3,
   .write_fence = write_fence,
   .write_context_fence = write_context_fence,
};

#define VENUS_CAPSET 4

static void api_init(void)
{
   virgl_log_set_handler(log_cb, NULL, NULL);
   if (virgl_renderer_init(NULL, VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL | VIRGL_RENDERER_RENDER_SERVER |
                                    VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB,
                           &callbacks)) {
      printf("test setup: the renderer with Venus did not start\n");
      fflush(stdout);
      _exit(BROKEN);
   }
}

/* contexts 1.. until one is not made: how many were */
static uint32_t make_contexts(uint32_t most)
{
   uint32_t made = 0;
   while (made < most && !virgl_renderer_context_create_with_flags(made + 1, VENUS_CAPSET, 4, "test"))
      made++;
   printf("%u Venus contexts made, context %u not\n", made, made + 1);
   return made;
}

static void destroy_contexts(uint32_t n)
{
   for (uint32_t i = 1; i <= n; i++)
      virgl_renderer_context_destroy(i);
}

static int contexts_case(void)
{
   /* budget 5: two contexts (a worker and a fence thread each), the third's fence thread is
    * past it */
   api_init();
   const int start = task_threads_now(), used = virgl_thread_budget_used();
   const uint32_t made = make_contexts(16);
   check(made == 2, "a budget of 5 threads makes 2 contexts of 2 threads");
   check(logged("is not made, that call fails"), "the refusal is logged");
   check(budget_settles(used + 4), "the failed context gave its worker back");
   destroy_contexts(made);
   check(budget_settles(used), "every thread given back after the contexts");
   check(threads_back(start), "the task's threads are back to their start");
   return failures ? FAILED : OK;
}

static int context_files_case(void)
{
   struct rlimit r;
   getrlimit(RLIMIT_NOFILE, &r);
   r.rlim_cur = 64;
   if (setrlimit(RLIMIT_NOFILE, &r)) {
      printf("test setup: no soft open-file limit of 64\n");
      return BROKEN;
   }
   api_init();
   const int start = task_threads_now(), files = open_files();
   if (virgl_renderer_context_create_with_flags(1, VENUS_CAPSET, 4, "test")) {
      printf("test setup: no first context\n");
      return BROKEN;
   }
   const int per_context = open_files() - files;
   printf("one Venus context: %d open files\n", per_context);
   check(per_context > 0 && per_context <= 8, "a context takes at most 8 open files");
   virgl_renderer_context_destroy(1);
   const uint32_t made = make_contexts(16);
   check(made == 64 / 16, "contexts stop at the open-file limit / 16 (64: 4)");
   check(logged("Venus contexts already"), "the refusal is logged");
   check(open_files() <= 64 / 2 + files, "the contexts hold at most half of the files");
   destroy_contexts(made);
   check(threads_back(start), "the task's threads are back to their start");
   return failures ? FAILED : OK;
}

/* ---- vkr directly: rings and queues on a real driver ---- */
#define REPLY_RES 1
#define REPLY_SIZE 65536
#define RING_RES 2
static struct vkr_context *ctx;
static uint8_t *reply;
static uint8_t cs[1 << 14];
static size_t cs_n;

static void put(const void *p, size_t n)
{
   const size_t padded = (n + 3) & ~(size_t)3;
   memcpy(cs + cs_n, p, n);
   memset(cs + cs_n + n, 0, padded - n);
   cs_n += padded;
}
static void u32(uint32_t v) { put(&v, 4); }
static void i32(int32_t v) { put(&v, 4); }
static void u64(uint64_t v) { put(&v, 8); }
static void f32(float v) { put(&v, 4); }
static void ptr(int present) { u64(present ? 1 : 0); }
static void cmd(VkCommandTypeEXT type, int want_reply)
{
   i32(type);
   u32(want_reply ? VK_COMMAND_GENERATE_REPLY_BIT_EXT : 0);
}

static bool submit(void)
{
   const bool ok = vkr_context_submit_cmd(ctx, cs, cs_n);
   cs_n = 0;
   return ok;
}

static void retire(uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id)
{
   (void)ctx_id;
   (void)ring_idx;
   (void)fence_id;
}

static void *shm_resource(uint32_t res_id, uint64_t size)
{
   struct virgl_context_blob blob;
   if (!vkr_context_create_resource(ctx, res_id, 0, size, VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE, &blob)) {
      printf("test setup: no shared memory resource\n");
      fflush(stdout);
      _exit(BROKEN);
   }
   close(blob.u.fd);
   return vkr_context_get_resource(ctx, res_id)->u.data;
}

static int32_t reply_ret(void)
{
   int32_t v;
   memcpy(&v, reply + 4, 4);
   return v;
}

static void vkr_init(void)
{
   static const struct vkr_renderer_callbacks cbs = { .retire_fence = retire };
   virgl_log_set_handler(log_cb, NULL, NULL);
   if (!vkr_renderer_init(VKR_RENDERER_THREAD_SYNC | VKR_RENDERER_ASYNC_FENCE_CB, &cbs) ||
       !(ctx = vkr_context_create(1, retire, 4, "test"))) {
      printf("test setup: no Venus context\n");
      fflush(stdout);
      _exit(BROKEN);
   }
   reply = shm_resource(REPLY_RES, REPLY_SIZE);
   cmd(VK_COMMAND_TYPE_vkSetReplyCommandStreamMESA_EXT, 0);
   ptr(1); u32(REPLY_RES); u64(0); u64(REPLY_SIZE);
   submit();
}

static void seek0(void)
{
   cmd(VK_COMMAND_TYPE_vkSeekReplyCommandStreamMESA_EXT, 0);
   u64(0);
}

/* an instance and its first physical device (ids 1, 2) */
static void instance(void)
{
   seek0();
   cmd(VK_COMMAND_TYPE_vkCreateInstance_EXT, 1);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO); ptr(0); u32(0);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_APPLICATION_INFO); ptr(0);
   u64(0); u32(0); u64(0); u32(0); u32(VK_API_VERSION_1_1);
   u32(0); u64(0);
   u32(0); u64(0);
   ptr(0);
   ptr(1); u64(1);
   if (!submit() || reply_ret()) {
      printf("test setup: vkCreateInstance\n");
      fflush(stdout);
      _exit(BROKEN);
   }
   seek0();
   cmd(VK_COMMAND_TYPE_vkEnumeratePhysicalDevices_EXT, 1);
   u64(1);
   ptr(1); u32(1);
   u64(1); u64(2);
   submit();
}

/* a device with one queue: its VkResult (the context lives) */
static int32_t device(uint64_t id)
{
   seek0();
   cmd(VK_COMMAND_TYPE_vkCreateDevice_EXT, 1);
   u64(2);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO); ptr(0); u32(0);
   u32(1); u64(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO); ptr(0); u32(0); u32(0); u32(1); u64(1); f32(1.0f);
   u32(0); u64(0);
   u32(0); u64(0);
   ptr(0);
   ptr(0);
   ptr(1); u64(id);
   if (!submit() || vkr_context_get_fatal(ctx))
      return VK_ERROR_UNKNOWN;
   return reply_ret();
}

static int queues_case(void)
{
   /* budget 2: two devices of one queue each, the third is not made. A first device made
    * and destroyed before counts the driver's own threads in the start. */
   vkr_init();
   instance();
   if (device(3)) {
      printf("test setup: no first device\n");
      return BROKEN;
   }
   cmd(VK_COMMAND_TYPE_vkDestroyDevice_EXT, 0);
   u64(3); ptr(0);
   submit();
   const int start = task_threads_now(), used = virgl_thread_budget_used();
   int32_t r1 = device(4), r2 = device(5), r3 = device(6);
   printf("vkCreateDevice: %d, %d, %d\n", r1, r2, r3);
   check(!r1 && !r2, "two devices of one queue in a budget of 2");
   check(r3 == VK_ERROR_OUT_OF_HOST_MEMORY && !vkr_context_get_fatal(ctx),
         "the third vkCreateDevice fails with an error, the context lives");
   check(logged("is not made, that call fails"), "the refusal is logged");
   check(virgl_thread_budget_used() == used + 2, "the failed device gave its queue's thread back");
   vkr_context_destroy(ctx);
   check(virgl_thread_budget_used() == used, "every thread given back after the context");
   check(threads_back(start), "the task's threads are back to their start");
   return failures ? FAILED : OK;
}

static void ring(uint64_t id, uint64_t offset, bool monitor)
{
   cmd(VK_COMMAND_TYPE_vkCreateRingMESA_EXT, 0);
   u64(id); ptr(1);
   i32(VK_STRUCTURE_TYPE_RING_CREATE_INFO_MESA);
   if (monitor) {
      ptr(1); i32(VK_STRUCTURE_TYPE_RING_MONITOR_INFO_MESA); ptr(0); u32(3000000);
   } else {
      ptr(0);
   }
   u32(0); u32(RING_RES);
   u64(offset); u64(4096);
   u64(1000000);
   u64(0); u64(4); u64(8);
   u64(64); u64(1024);
   u64(64 + 1024); u64(0);
   submit();
}

static int rings_case(void)
{
   /* budget 4: the monitor and three rings; the fourth ring has no thread (its context ends) */
   vkr_init();
   const int start = task_threads_now(), used = virgl_thread_budget_used();
   shm_resource(RING_RES, 16 * 4096);
   uint32_t made = 0;
   for (uint32_t i = 0; i < 8 && !vkr_context_get_fatal(ctx); i++) {
      ring(100 + i, 4096 * (uint64_t)i, i == 0);
      made += !vkr_context_get_fatal(ctx);
   }
   printf("%u rings made, then the context %s\n", made, vkr_context_get_fatal(ctx) ? "ended" : "lives");
   check(made == 3, "a budget of 4 threads makes the monitor and 3 rings");
   check(logged("is not made, that call fails") && logged("no thread for the ring"), "the refusal is logged");
   check(virgl_thread_budget_used() == used + 4, "the ring without a thread took none");
   vkr_context_destroy(ctx);
   check(virgl_thread_budget_used() == used, "every thread given back after the context");
   check(threads_back(start), "the task's threads are back to their start");
   return failures ? FAILED : OK;
}

static const struct {
   const char *name;
   const char *budget;
} cases[] = {
   { "contexts", "5" },
   { "rings", "4" },
   { "queues", "2" },
   { "context-files", NULL },
};

int main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IOLBF, 0);
   if (argc == 2) {
      int status = BROKEN;
      if (!strcmp(argv[1], "contexts"))
         status = contexts_case();
      else if (!strcmp(argv[1], "rings"))
         status = rings_case();
      else if (!strcmp(argv[1], "queues"))
         status = queues_case();
      else if (!strcmp(argv[1], "context-files"))
         status = context_files_case();
      else if (!strcmp(argv[1], "driver")) {
         vkr_init();
         instance();
         struct vkr_physical_device *pdev = vkr_context_get_object(ctx, 2);
         VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
         VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drv };
         if (!pdev)
            _exit(BROKEN);
         pdev->proc_table.GetPhysicalDeviceProperties2(pdev->base.handle.physical_device, &p2);
         _exit(drv.driverID == VK_DRIVER_ID_MESA_KOSMICKRISP ? FAILED : OK);
      }
      fflush(stdout);
      _exit(status);
   }
   pid_t pid;
   int status;
   const char *driver_args[] = { argv[0], "driver", NULL };
   if (posix_spawn(&pid, argv[0], NULL, NULL, (char **)driver_args, environ) || waitpid(pid, &status, 0) < 0 ||
       !WIFEXITED(status) || (WEXITSTATUS(status) != OK && WEXITSTATUS(status) != FAILED)) {
      printf("FAIL: no Venus device to test\n");
      return 1;
   }
   const bool kk = WEXITSTATUS(status) == FAILED;
   int bad = 0;
   const size_t n = sizeof(cases) / sizeof(cases[0]);
   for (size_t i = 0; i < n; i++) {
      if (cases[i].budget)
         setenv("OMACVM_VENUS_THREADS", cases[i].budget, 1);
      else
         unsetenv("OMACVM_VENUS_THREADS");
      const char *args[] = { argv[0], cases[i].name, NULL };
      char out[] = "/tmp/venus-threads.XXXXXX";
      const int fd = mkstemp(out);
      posix_spawn_file_actions_t fa;
      posix_spawn_file_actions_init(&fa);
      posix_spawn_file_actions_adddup2(&fa, fd, 1);
      posix_spawn_file_actions_adddup2(&fa, fd, 2);
      const int spawned = posix_spawn(&pid, argv[0], &fa, NULL, (char **)args, environ);
      posix_spawn_file_actions_destroy(&fa);
      const bool ok = !spawned && waitpid(pid, &status, 0) == pid && WIFEXITED(status) &&
                      WEXITSTATUS(status) == OK;
      printf("%s: %s: %s\n", ok ? "ok" : "FAIL", cases[i].name,
             WIFSIGNALED(status) ? "the process ended (signal)" : ok ? "as expected" : "see below");
      if (!ok) {
         FILE *f = fopen(out, "r");
         char line[1024];
         while (f && fgets(line, sizeof(line), f))
            printf("   | %s", line);
         if (f)
            fclose(f);
      }
      close(fd);
      unlink(out);
      bad += !ok;
   }
   unsetenv("OMACVM_VENUS_THREADS");
   printf("%s: %zu cases (0 skipped) on %s\n", bad ? "FAILED" : "all ok", n, kk ? "KosmicKrisp" : "MoltenVK");
   return bad != 0;
}
