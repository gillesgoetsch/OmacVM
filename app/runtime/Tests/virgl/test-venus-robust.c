/* What a guest's Venus commands ended QEMU's process with now ends only the app's Venus
 * context (virgl-venus-missing-entries.patch, virgl-venus-guest-asserts.patch,
 * virgl-venus-buffer-binds.patch; ADR 0065, "What else vkr refuses"), and what a reply
 * carries back is what the call wrote or zeros (virgl-venus-temp-zero.patch).
 *
 * A real vkr context on the runtime's real driver, as in test-venus-image-limits.c. Each
 * case sends hand-encoded commands through vkr_context_submit_cmd, the path of QEMU's
 * render worker: vkr's decoder, its dispatch table and the dispatching context (one case
 * through a ring thread, one inside vkExecuteCommandStreamsMESA). Each case runs in its
 * own process. Without the patches the cases end their process (a call to address 0, an
 * assert, the Vulkan loader's abort) or the driver binds memory the buffer does not fit
 * in; with them each ends only its context, with a log line, and the must-keep cases
 * work without one. Objects, queries and binds only: no command buffer is submitted,
 * nothing runs on the GPU (standards 14).
 *
 *   test-venus-robust              every case, one process each, then a summary
 *   test-venus-robust CASE         one case (what the children run)
 *   test-venus-robust --time N     microseconds per vkCreateBuffer through vkr
 *
 * The driver is vkr's choice from OMACVM_VULKAN_DRIVER, the binary sits beside the
 * runtime's loader and drivers (run-venus-limits.py builds that folder). */
#include <inttypes.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "virgl_context.h"
#include "virgl_util.h"
#include "virglrenderer.h"
#include "vkr_buffer.h"
#include "vkr_context.h"
#include "vkr_device.h"
#include "vkr_device_memory.h"
#include "vkr_physical_device.h"
#include "vkr_renderer.h"

extern char **environ;

/* what a case saw: the child's exit status */
enum { ALIVE = 10, REFUSED = 11, ENDED = 12, SKIP = 13, BROKEN = 2 };
/* what a case must see */
enum { E_ALIVE, E_REFUSED, E_ENDED };

#define REPLY_RES 1
#define REPLY_SIZE 65536
#define INSTANCE_ID 1
#define PDEV_ID 2
#define DEV_ID 3
#define QUEUE_ID 4

static struct vkr_context *ctx;
static uint8_t *reply;
static uint64_t next_id = 100;
static bool kosmickrisp;

/* ---- the log: kept to check a case's line, printed with the child's output ---- */
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

static void broken(const char *what)
{
   printf("test setup: %s\n", what);
   fflush(stdout);
   _exit(BROKEN);
}

/* ---- encoder: 4-byte units, as the guest's vn_cs_encoder ---- */
static uint8_t cs[1 << 16];
static size_t cs_n;

static void put(const void *p, size_t n)
{
   const size_t padded = (n + 3) & ~(size_t)3;
   if (cs_n + padded > sizeof(cs))
      broken("command stream full");
   memcpy(cs + cs_n, p, n);
   memset(cs + cs_n + n, 0, padded - n);
   cs_n += padded;
}
static void u32(uint32_t v) { put(&v, 4); }
static void i32(int32_t v) { put(&v, 4); }
static void u64(uint64_t v) { put(&v, 8); }
static void f32(float v) { put(&v, 4); }
static void ptr(int present) { u64(present ? 1 : 0); }
static void str(const char *s)
{
   const size_t n = strlen(s) + 1;
   u64(n);
   put(s, n);
}
static void cmd(VkCommandTypeEXT type, int want_reply)
{
   i32(type);
   u32(want_reply ? VK_COMMAND_GENERATE_REPLY_BIT_EXT : 0);
}
static void seek(uint64_t pos)
{
   cmd(VK_COMMAND_TYPE_vkSeekReplyCommandStreamMESA_EXT, 0);
   u64(pos);
}

/* everything encoded so far, through the context's own path */
static bool submit(void)
{
   const bool ok = vkr_context_submit_cmd(ctx, cs, cs_n);
   cs_n = 0;
   return ok;
}

/* a command with its reply at 0: the reply, or NULL when the context ended */
static const uint8_t *reply_call(void)
{
   memset(reply, 0xa5, 256);
   if (!submit() || vkr_context_get_fatal(ctx))
      return NULL;
   return reply;
}

static int32_t ret_of(const uint8_t *r)
{
   int32_t v;
   memcpy(&v, r + 4, 4);
   return v;
}

static int outcome(void)
{
   return vkr_context_get_fatal(ctx) ? ENDED : ALIVE;
}

/* ---- the guest's objects ---- */
static void retire(uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id)
{
   (void)ctx_id;
   (void)ring_idx;
   (void)fence_id;
}

static void *shm_resource(uint32_t res_id, uint64_t size)
{
   struct virgl_context_blob blob;
   if (!vkr_context_create_resource(ctx, res_id, 0, size, VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE,
                                    &blob))
      broken("no shared memory resource");
   close(blob.u.fd);
   return vkr_context_get_resource(ctx, res_id)->u.data;
}

/* a context with an instance of the API version, its physical device and a device with
 * the extensions, and the device's queue, all as encoded guest commands */
static void setup(uint32_t api, int n_ext, const char *const *ext)
{
   static const struct vkr_renderer_callbacks cbs = { .retire_fence = retire };
   virgl_log_set_handler(log_cb, NULL, NULL);
   if (!vkr_renderer_init(VKR_RENDERER_THREAD_SYNC | VKR_RENDERER_ASYNC_FENCE_CB, &cbs))
      broken("vkr_renderer_init");
   ctx = vkr_context_create(1, retire, 4, "test");
   if (!ctx)
      broken("no Venus context (no Vulkan loader beside the binary?)");
   reply = shm_resource(REPLY_RES, REPLY_SIZE);
   cmd(VK_COMMAND_TYPE_vkSetReplyCommandStreamMESA_EXT, 0);
   ptr(1); u32(REPLY_RES); u64(0); u64(REPLY_SIZE);

   seek(0);
   cmd(VK_COMMAND_TYPE_vkCreateInstance_EXT, 1);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO); ptr(0); u32(0);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_APPLICATION_INFO); ptr(0);
   u64(0); u32(0); u64(0); u32(0); u32(api);
   u32(0); u64(0);
   u32(0); u64(0);
   ptr(0);
   ptr(1); u64(INSTANCE_ID);
   const uint8_t *r = reply_call();
   if (!r || ret_of(r))
      broken("vkCreateInstance");

   seek(0);
   cmd(VK_COMMAND_TYPE_vkEnumeratePhysicalDevices_EXT, 1);
   u64(INSTANCE_ID);
   ptr(1); u32(1);
   u64(1); u64(PDEV_ID);
   r = reply_call();
   if (!r || (ret_of(r) && ret_of(r) != VK_INCOMPLETE))
      broken("vkEnumeratePhysicalDevices");

   seek(0);
   cmd(VK_COMMAND_TYPE_vkCreateDevice_EXT, 1);
   u64(PDEV_ID);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO); ptr(0); u32(0);
   u32(1); u64(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO); ptr(0); u32(0); u32(0); u32(1); u64(1); f32(1.0f);
   u32(0); u64(0);
   u32((uint32_t)n_ext); u64((uint64_t)n_ext);
   for (int i = 0; i < n_ext; i++)
      str(ext[i]);
   ptr(0);
   ptr(0);
   ptr(1); u64(DEV_ID);
   r = reply_call();
   if (!r || ret_of(r))
      broken("vkCreateDevice");

   /* vkr wants vkGetDeviceQueue2 with its ring (vkGetDeviceQueue ends the context) */
   cmd(VK_COMMAND_TYPE_vkGetDeviceQueue2_EXT, 0);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2);
   ptr(1); i32(VK_STRUCTURE_TYPE_DEVICE_QUEUE_TIMELINE_INFO_MESA); ptr(0); u32(1);
   u32(0); u32(0); u32(0);
   ptr(1); u64(QUEUE_ID);
   if (!submit())
      broken("vkGetDeviceQueue2");

   VkPhysicalDeviceDriverProperties driver = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
   VkPhysicalDeviceProperties2 props = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
                                         .pNext = &driver };
   struct vkr_physical_device *pdev = vkr_context_get_object(ctx, PDEV_ID);
   pdev->proc_table.GetPhysicalDeviceProperties2(pdev->base.handle.physical_device, &props);
   kosmickrisp = driver.driverID == VK_DRIVER_ID_MESA_KOSMICKRISP;
}

static bool device_lists(const char *name)
{
   const struct vkr_physical_device *pdev = vkr_context_get_object(ctx, PDEV_ID);
   for (uint32_t i = 0; i < pdev->extension_count; i++) {
      if (!strcmp(pdev->extensions[i].extensionName, name))
         return true;
   }
   return false;
}

static uint64_t command_buffer(void)
{
   const uint64_t pool = next_id++, cb = next_id++;
   seek(0);
   cmd(VK_COMMAND_TYPE_vkCreateCommandPool_EXT, 1);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO); ptr(0); u32(2); u32(0);
   ptr(0); ptr(1); u64(pool);
   const uint8_t *r = reply_call();
   if (!r || ret_of(r))
      broken("vkCreateCommandPool");
   cmd(VK_COMMAND_TYPE_vkAllocateCommandBuffers_EXT, 0);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO); ptr(0); u64(pool); i32(0); u32(1);
   u64(1); u64(cb);
   cmd(VK_COMMAND_TYPE_vkBeginCommandBuffer_EXT, 0);
   u64(cb); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO); ptr(0); u32(1); ptr(0);
   if (!submit())
      broken("a command buffer");
   return cb;
}

static uint64_t semaphore(void)
{
   const uint64_t id = next_id++;
   cmd(VK_COMMAND_TYPE_vkCreateSemaphore_EXT, 0);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO); ptr(0); u32(0);
   ptr(0); ptr(1); u64(id);
   if (!submit())
      broken("vkCreateSemaphore");
   return id;
}

/* a buffer (0 when the driver refuses it) and its requirements: size, alignment, types;
 * window: as Mesa's PRIME buffer of a Vulkan window (ADR 0047) */
static uint64_t buffer(uint64_t size, uint32_t flags, int window, uint64_t req[3])
{
   const uint64_t id = next_id++;
   seek(0);
   cmd(VK_COMMAND_TYPE_vkCreateBuffer_EXT, 1);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
   if (window) {
      ptr(1); i32(VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO); ptr(0);
      u32(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT);
   } else {
      ptr(0);
   }
   u32(flags); u64(size);
   u32(window ? VK_BUFFER_USAGE_TRANSFER_DST_BIT
              : VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
   i32(0); u32(0); u64(0);
   ptr(0); ptr(1); u64(id);
   const uint8_t *r = reply_call();
   if (!r)
      broken("vkCreateBuffer ended the context");
   printf("vkCreateBuffer(%" PRIu64 ", flags 0x%x) = %d\n", size, flags, ret_of(r));
   if (ret_of(r))
      return 0;
   seek(0);
   cmd(VK_COMMAND_TYPE_vkGetBufferMemoryRequirements_EXT, 1);
   u64(DEV_ID); u64(id); ptr(1);
   r = reply_call();
   if (!r)
      broken("vkGetBufferMemoryRequirements");
   uint32_t bits;
   memcpy(&req[0], r + 12, 8);
   memcpy(&req[1], r + 20, 8);
   memcpy(&bits, r + 28, 4);
   req[2] = bits;
   printf("requirements: size %" PRIu64 " alignment %" PRIu64 " types 0x%x\n", req[0], req[1],
          bits);
   return id;
}

/* a memory type in (or, not_in, outside) bits with the properties; UINT32_MAX if none */
static uint32_t memory_type(uint32_t bits, uint32_t want, int not_in)
{
   const struct vkr_physical_device *pdev = vkr_context_get_object(ctx, PDEV_ID);
   const VkPhysicalDeviceMemoryProperties *mp = &pdev->memory_properties;
   for (uint32_t i = 0; i < mp->memoryTypeCount; i++) {
      if (!!(bits & (1u << i)) != !!not_in && (mp->memoryTypes[i].propertyFlags & want) == want)
         return i;
   }
   return UINT32_MAX;
}

/* memory: 0 when the driver or vkr refuses it (*ret says why); export_types,
 * import_res (VkImportMemoryResourceInfoMESA) and dedicated_buffer are optional */
static uint64_t memory(uint64_t size, uint32_t type, uint32_t export_types, uint32_t import_res,
                       uint64_t dedicated_buffer, int32_t *ret)
{
   const uint64_t id = next_id++;
   seek(0);
   cmd(VK_COMMAND_TYPE_vkAllocateMemory_EXT, 1);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
   /* the chain: export -> dedicated -> import; each struct's own fields after its pNext */
   if (export_types) {
      ptr(1); i32(VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO);
   }
   if (dedicated_buffer) {
      ptr(1); i32(VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO);
   }
   if (import_res) {
      ptr(1); i32(VK_STRUCTURE_TYPE_IMPORT_MEMORY_RESOURCE_INFO_MESA);
   }
   ptr(0);
   if (import_res)
      u32(import_res);
   if (dedicated_buffer) {
      u64(0); u64(dedicated_buffer);
   }
   if (export_types)
      u32(export_types);
   u64(size); u32(type);
   ptr(0); ptr(1); u64(id);
   const uint8_t *r = reply_call();
   *ret = r ? ret_of(r) : VK_ERROR_UNKNOWN;
   printf("vkAllocateMemory(%" PRIu64 ", type %u, export 0x%x, import %u) = %d\n", size, type,
          export_types, import_res, *ret);
   return r && !*ret ? id : 0;
}

/* a bind the guest does not wait for, as Mesa sends it; the result is in the reply when
 * the context lives */
static void bind_buffer(uint64_t buf, uint64_t mem, uint64_t offset, int two)
{
   seek(0);
   if (two) {
      cmd(VK_COMMAND_TYPE_vkBindBufferMemory2_EXT, 1);
      u64(DEV_ID); u32(1); u64(1);
      i32(VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO); ptr(0); u64(buf); u64(mem); u64(offset);
   } else {
      cmd(VK_COMMAND_TYPE_vkBindBufferMemory_EXT, 1);
      u64(DEV_ID); u64(buf); u64(mem); u64(offset);
   }
   const uint8_t *r = reply_call();
   printf("%s(offset %" PRIu64 ") = %d\n", two ? "vkBindBufferMemory2" : "vkBindBufferMemory",
          offset, r ? ret_of(r) : -1);
}

/* a blob resource of this context from device memory, as RESOURCE_CREATE_BLOB makes it
 * (vkr's own export, outside the guest's commands) */
static bool blob_from(uint32_t res_id, uint64_t mem, uint64_t size)
{
   struct virgl_context_blob blob;
   const bool ok = vkr_context_create_resource(
      ctx, res_id, mem, size,
      VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE | VIRGL_RENDERER_BLOB_FLAG_USE_SHAREABLE, &blob);
   printf("blob %u from memory %" PRIu64 " = %s (type %d)\n", res_id, mem, ok ? "ok" : "failed",
          ok ? blob.type : -1);
   return ok;
}

/* a 64 KiB host-visible memory exported as the guest's WSI does (DMA_BUF: a Metal heap on
 * a Mac) and a blob of it as resource 7: 0 when the driver has no such memory */
static uint64_t exported_memory(uint32_t export_types)
{
   const uint32_t type = memory_type(~0u, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
   int32_t ret;
   const uint64_t mem = memory(65536, type, export_types, 0, 0, &ret);
   if (!mem)
      return 0;
   return blob_from(7, mem, 65536) ? mem : 0;
}

/* ---- the cases ---- */
static const char *const ext_eds = "VK_EXT_extended_dynamic_state";

/* vkCmdSetCullMode: core 1.3 or EXT_extended_dynamic_state */
static int cull_mode_case(uint32_t api, int with_ext)
{
   setup(api, with_ext, &ext_eds);
   const uint64_t cb = command_buffer();
   cmd(VK_COMMAND_TYPE_vkCmdSetCullMode_EXT, 0);
   u64(cb); u32(VK_CULL_MODE_BACK_BIT);
   submit();
   return outcome();
}

/* the same command through a ring thread (vkCreateRingMESA on a shm resource) */
static int ring_case(int monitor_period_0, int send_cull_mode)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   const uint64_t cb = command_buffer();
   uint8_t *shm = shm_resource(2, 65536);
   volatile uint32_t *head = (volatile uint32_t *)shm, *tail = (volatile uint32_t *)(shm + 4),
                     *status = (volatile uint32_t *)(shm + 8);
   const uint64_t ring = 77;
   cmd(VK_COMMAND_TYPE_vkCreateRingMESA_EXT, 0);
   u64(ring); ptr(1);
   i32(VK_STRUCTURE_TYPE_RING_CREATE_INFO_MESA);
   if (monitor_period_0) {
      ptr(1); i32(VK_STRUCTURE_TYPE_RING_MONITOR_INFO_MESA); ptr(0); u32(0);
   } else {
      ptr(0);
   }
   u32(0); u32(2);         /* flags, resourceId */
   u64(0); u64(65536);     /* offset, size */
   u64(1000000);           /* idleTimeout (ns) */
   u64(0); u64(4); u64(8); /* head, tail, status */
   u64(64); u64(4096);     /* buffer */
   u64(64 + 4096); u64(0); /* extra */
   submit();
   printf("vkCreateRingMESA%s: the context %s\n", monitor_period_0 ? " (monitor period 0)" : "",
          vkr_context_get_fatal(ctx) ? "ended" : "lives");

   if (send_cull_mode && !vkr_context_get_fatal(ctx)) {
      cmd(VK_COMMAND_TYPE_vkCmdSetCullMode_EXT, 0);
      u64(cb); u32(VK_CULL_MODE_BACK_BIT);
      memcpy(shm + 64, cs, cs_n);
      const uint32_t n = (uint32_t)cs_n;
      cs_n = 0;
      __atomic_store_n(tail, n, __ATOMIC_SEQ_CST);
      cmd(VK_COMMAND_TYPE_vkNotifyRingMESA_EXT, 0);
      u64(ring); u32(0); u32(0);
      submit();
      for (int i = 0; i < 400 && *head != n && !(*status & VK_RING_STATUS_FATAL_BIT_MESA); i++)
         usleep(5000);
      printf("ring head %u of %u, status 0x%x\n", *head, n, *status);
   }
   const int seen = outcome();
   /* the guest's end of the app destroys the context: rings and all */
   printf("destroying the context ...\n");
   vkr_context_destroy(ctx);
   printf("the context is destroyed, the process lives\n");
   return seen;
}

/* the same command inside vkExecuteCommandStreamsMESA (a stream in a shm resource) */
static int nested_case(void)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   const uint64_t cb = command_buffer();
   uint8_t *shm = shm_resource(3, 4096);
   cmd(VK_COMMAND_TYPE_vkCmdSetCullMode_EXT, 0);
   u64(cb); u32(VK_CULL_MODE_BACK_BIT);
   memcpy(shm, cs, cs_n);
   const uint64_t n = cs_n;
   cs_n = 0;
   cmd(VK_COMMAND_TYPE_vkExecuteCommandStreamsMESA_EXT, 0);
   u32(1);
   u64(1); u32(3); u64(0); u64(n); /* pStreams: resource 3, offset 0, size n */
   u64(0);                         /* no pReplyPositions */
   u32(0); u64(0);                 /* no dependencies */
   u32(0);                         /* flags */
   submit();
   return outcome();
}

/* the physical-device query of an extension the device does not list */
static int physical_query_case(VkCommandTypeEXT type, const char *ext)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   if (device_lists(ext)) {
      printf("skip: the device lists %s\n", ext);
      return SKIP;
   }
   seek(0);
   cmd(type, 1);
   u64(PDEV_ID); ptr(1); u32(0); u64(0);
   reply_call();
   return outcome();
}

static void image_create_info(void)
{
   ptr(1);
   i32(VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO); ptr(0);
   u32(0); i32(VK_IMAGE_TYPE_2D); i32(VK_FORMAT_B8G8R8A8_UNORM);
   u32(64); u32(64); u32(1);
   u32(1); u32(1); i32(VK_SAMPLE_COUNT_1_BIT); i32(VK_IMAGE_TILING_OPTIMAL);
   u32(VK_IMAGE_USAGE_SAMPLED_BIT);
   i32(VK_SHARING_MODE_EXCLUSIVE); u32(0); u64(0);
   i32(VK_IMAGE_LAYOUT_UNDEFINED);
}

/* #623's queries of maintenance4/5 on a device without them: zeros, the context lives */
static int device_image_query_case(int layout)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   seek(0);
   if (layout) {
      cmd(VK_COMMAND_TYPE_vkGetDeviceImageSubresourceLayout_EXT, 1);
      u64(DEV_ID);
      ptr(1); i32(VK_STRUCTURE_TYPE_DEVICE_IMAGE_SUBRESOURCE_INFO); ptr(0);
      image_create_info();
      ptr(1); i32(VK_STRUCTURE_TYPE_IMAGE_SUBRESOURCE_2); ptr(0);
      u32(VK_IMAGE_ASPECT_COLOR_BIT); u32(0); u32(0);
      ptr(1); i32(VK_STRUCTURE_TYPE_SUBRESOURCE_LAYOUT_2); ptr(0);
   } else {
      cmd(VK_COMMAND_TYPE_vkGetDeviceImageMemoryRequirements_EXT, 1);
      u64(DEV_ID);
      ptr(1); i32(VK_STRUCTURE_TYPE_DEVICE_IMAGE_MEMORY_REQUIREMENTS); ptr(0);
      image_create_info();
      u32(0);
      ptr(1); i32(VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2); ptr(0);
   }
   const uint8_t *r = reply_call();
   if (!r)
      return ENDED;
   /* the reply: command type, pointer, sType, pNext, then the answer (VkSubresourceLayout:
    * 5 sizes; VkMemoryRequirements: size, alignment, type bits); the rest is still 0xa5 */
   int32_t type;
   memcpy(&type, r, 4);
   const int want = layout ? VK_COMMAND_TYPE_vkGetDeviceImageSubresourceLayout_EXT
                           : VK_COMMAND_TYPE_vkGetDeviceImageMemoryRequirements_EXT;
   const size_t end = layout ? 24 + 5 * 8 : 24 + 8 + 8 + 4;
   bool zero = type == want;
   for (size_t i = 24; i < end; i++)
      zero &= !r[i];
   printf("reply %d: the answer is %s\n", type, zero ? "zeros" : "not zeros");
   return zero ? outcome() : BROKEN;
}

/* ---- replies: chained output structs a refused or unfilled query leaves (temp-zero) ---- */
/* the temp pool's first bytes full of 0x5a: vkCmdSetViewport's viewports are decoded there
 * (the pool starts over at the same place for the next command) */
static void fill_temp_pool(uint64_t cb)
{
   const struct vkr_physical_device *pdev = vkr_context_get_object(ctx, PDEV_ID);
   const uint32_t n = MIN2(pdev->properties.limits.maxViewports, 16);
   cmd(VK_COMMAND_TYPE_vkCmdSetViewport_EXT, 0);
   u64(cb); u32(0); u32(n);
   u64(n);
   for (uint32_t i = 0; i < n * 6; i++)
      u32(0x5a5a5a5au);
   submit();
}

/* the two 32-bit words after the struct of type `stype` in the reply (its pNext pointer
 * between), or false when the reply lacks it */
static bool reply_struct_words(VkStructureType stype, uint32_t out[2])
{
   for (size_t at = 0; at + 20 <= 512; at += 4) {
      int32_t t;
      memcpy(&t, reply + at, 4);
      if (t == (int32_t)stype) {
         memcpy(out, reply + at + 12, 8);
         return true;
      }
   }
   return false;
}

static int reply_chain_case(int refused)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   const uint64_t cb = command_buffer();
   fill_temp_pool(cb);
   uint32_t words[2];
   VkStructureType stype;
   if (refused) {
      /* the second plane's requirements of an image of one: refused, the context lives;
       * its chained VkMemoryDedicatedRequirements is not written */
      const uint64_t img = next_id++;
      cmd(VK_COMMAND_TYPE_vkCreateImage_EXT, 0);
      u64(DEV_ID);
      image_create_info();
      ptr(0); ptr(1); u64(img);
      submit();
      fill_temp_pool(cb);
      seek(0);
      cmd(VK_COMMAND_TYPE_vkGetImageMemoryRequirements2_EXT, 1);
      u64(DEV_ID);
      ptr(1); i32(VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2);
      ptr(1); i32(VK_STRUCTURE_TYPE_IMAGE_PLANE_MEMORY_REQUIREMENTS_INFO); ptr(0); u32(VK_IMAGE_ASPECT_PLANE_1_BIT);
      u64(img);
      ptr(1); i32(VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2);
      ptr(1); i32(VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS); ptr(0);
      stype = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS;
   } else {
      /* a format query with an output struct the driver does not fill (no image view
       * info asks for it) */
      seek(0);
      cmd(VK_COMMAND_TYPE_vkGetPhysicalDeviceImageFormatProperties2_EXT, 1);
      u64(PDEV_ID);
      ptr(1); i32(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2); ptr(0);
      i32(VK_FORMAT_R8G8B8A8_UNORM); i32(VK_IMAGE_TYPE_2D); i32(VK_IMAGE_TILING_OPTIMAL);
      u32(VK_IMAGE_USAGE_SAMPLED_BIT); u32(0);
      ptr(1); i32(VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2);
      ptr(1); i32(VK_STRUCTURE_TYPE_FILTER_CUBIC_IMAGE_VIEW_IMAGE_FORMAT_PROPERTIES_EXT); ptr(0);
      stype = VK_STRUCTURE_TYPE_FILTER_CUBIC_IMAGE_VIEW_IMAGE_FORMAT_PROPERTIES_EXT;
   }
   if (!reply_call())
      return ENDED;
   if (!reply_struct_words(stype, words)) {
      printf("the reply has no struct of type %d\n", stype);
      return BROKEN;
   }
   printf("the chained struct's two words in the reply: 0x%08x 0x%08x\n", words[0], words[1]);
   /* VkBool32s: 0 or 1 when written or zeroed; the pool's old bytes otherwise */
   return words[0] <= 1 && words[1] <= 1 ? outcome() : BROKEN;
}

#ifdef VKR_MISSING
/* every entry of both tables is set, the missing ones are the stubs */
static int tables_case(void)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   struct vkr_physical_device *pdev = vkr_context_get_object(ctx, PDEV_ID);
   struct vkr_device *dev = vkr_context_get_object(ctx, DEV_ID);
   void *dev_entries[sizeof(dev->proc_table) / sizeof(void *)];
   void *pdev_entries[sizeof(pdev->proc_table) / sizeof(void *)];
   memcpy(dev_entries, &dev->proc_table, sizeof(dev_entries));
   memcpy(pdev_entries, &pdev->proc_table, sizeof(pdev_entries));
   int bad = 0;
   for (size_t i = 0; i < sizeof(dev_entries) / sizeof(dev_entries[0]); i++) {
      if (!dev_entries[i])
         printf("device entry %zu is NULL\n", i), bad = 1;
   }
   for (size_t i = 0; i < sizeof(pdev_entries) / sizeof(pdev_entries[0]); i++) {
      if (!pdev_entries[i])
         printf("physical device entry %zu is NULL\n", i), bad = 1;
   }
   unsigned dev_stubs = 0, pdev_stubs = 0;
#define COUNT(ret, name, params, fallback) dev_stubs += VKR_MISSING(&dev->proc_table, name);
#define COUNT_VOID(name, params) dev_stubs += VKR_MISSING(&dev->proc_table, name);
   VKR_DEVICE_PROC_ENTRIES(COUNT, COUNT_VOID)
#undef COUNT
#undef COUNT_VOID
#define COUNT(ret, name, params, fallback) pdev_stubs += VKR_MISSING(&pdev->proc_table, name);
#define COUNT_VOID(name, params) pdev_stubs += VKR_MISSING(&pdev->proc_table, name);
   VKR_PHYSICAL_DEVICE_PROC_ENTRIES(COUNT, COUNT_VOID)
#undef COUNT
#undef COUNT_VOID
   printf("a 1.1 device without extensions: %u of %u device entries and %u of %u physical "
          "device entries are stubs\n", dev_stubs, VKR_DEVICE_PROC_ENTRY_COUNT, pdev_stubs,
          VKR_PHYSICAL_DEVICE_PROC_ENTRY_COUNT);
   if (!VKR_MISSING(&dev->proc_table, CmdSetCullMode) ||
       !VKR_MISSING(&dev->proc_table, GetSemaphoreCounterValue) ||
       !VKR_MISSING(&dev->proc_table, CreateAccelerationStructureKHR))
      printf("a 1.2/1.3 or extension entry is not a stub\n"), bad = 1;
   if (VKR_MISSING(&dev->proc_table, CreateBuffer) || VKR_MISSING(&dev->proc_table, BindBufferMemory2))
      printf("a 1.0/1.1 entry is a stub\n"), bad = 1;
   /* the loader's entries of device extensions count only when the device lists them */
   const struct {
      bool stub;
      const char *ext, *ext2;
   } queries[] = {
      { VKR_MISSING(&pdev->proc_table, GetPhysicalDeviceCalibrateableTimeDomainsKHR),
        "VK_KHR_calibrated_timestamps", "VK_EXT_calibrated_timestamps" },
      { VKR_MISSING(&pdev->proc_table, GetPhysicalDeviceCooperativeMatrixPropertiesKHR),
        "VK_KHR_cooperative_matrix", NULL },
      { VKR_MISSING(&pdev->proc_table, GetPhysicalDeviceFragmentShadingRatesKHR),
        "VK_KHR_fragment_shading_rate", NULL },
      { VKR_MISSING(&pdev->proc_table, GetPhysicalDeviceMultisamplePropertiesEXT),
        "VK_EXT_sample_locations", NULL },
   };
   for (size_t i = 0; i < sizeof(queries) / sizeof(queries[0]); i++) {
      const bool listed = device_lists(queries[i].ext) ||
                          (queries[i].ext2 && device_lists(queries[i].ext2));
      printf("%s: %s, its query %s\n", queries[i].ext, listed ? "listed" : "not listed",
             queries[i].stub ? "a stub" : "the loader's");
      if (listed == queries[i].stub)
         bad = 1;
   }
   return bad ? BROKEN : outcome();
}

/* a stub reached from vkr's own code (no guest command dispatched): an error back, a log
 * line, no context touched */
static int no_context_case(void)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   struct vkr_device *dev = vkr_context_get_object(ctx, DEV_ID);
   if (vkr_dispatching_context)
      printf("a dispatching context outside any stream\n");
   uint64_t value = 0;
   const VkResult r = dev->proc_table.GetSemaphoreCounterValue(dev->base.handle.device,
                                                               VK_NULL_HANDLE, &value);
   printf("vkGetSemaphoreCounterValue from vkr itself = %d\n", r);
   if (vkr_dispatching_context || r != VK_ERROR_FEATURE_NOT_PRESENT || !logged("vkr's call failed"))
      return BROKEN;
   return outcome();
}

/* vkr_context_submit_cmd puts the outer dispatching context back, also on its early bail */
static int dispatch_restore_case(void)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   struct vkr_context *outer = (struct vkr_context *)(uintptr_t)0x1000;
   vkr_dispatching_context = outer;
   cmd(VK_COMMAND_TYPE_vkEnumerateInstanceVersion_EXT, 0);
   ptr(1);
   const bool ok = submit();
   const bool kept = vkr_dispatching_context == outer;
   vkr_context_set_fatal(ctx);
   cmd(VK_COMMAND_TYPE_vkEnumerateInstanceVersion_EXT, 0);
   ptr(1);
   const bool bailed = !submit();
   const bool kept_on_bail = vkr_dispatching_context == outer;
   vkr_dispatching_context = NULL;
   printf("submit %d, kept %d; early bail %d, kept %d\n", ok, kept, bailed, kept_on_bail);
   return ok && kept && bailed && kept_on_bail ? ALIVE : BROKEN;
}
#endif

/* buffer binds: ranges, alignment, type, sparse buffers */
static int bind_case(const char *c)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   const int huge = !strcmp(c, "b-huge-buffer"), sparse = !strcmp(c, "b-sparse");
   uint64_t req[3];
   const uint64_t buf = buffer(huge ? 1ull << 40 : 65536,
                               sparse ? VK_BUFFER_CREATE_SPARSE_BINDING_BIT : 0, 0, req);
   if (!buf) {
      printf("skip: the driver makes no such buffer\n");
      return SKIP;
   }
   const int wrong = !strcmp(c, "b-wrong-type");
   const uint32_t type = memory_type((uint32_t)req[2], 0, wrong);
   if (type == UINT32_MAX) {
      printf("skip: no memory type outside 0x%" PRIx64 "\n", req[2]);
      return SKIP;
   }
   uint64_t mem_size = req[0], offset = 0;
   if (huge)
      mem_size = 65536;
   else if (!strcmp(c, "b-past-end") || !strcmp(c, "b2-past-end"))
      offset = req[0] / 2 - (req[0] / 2) % req[1]; /* half the buffer outside */
   else if (!strcmp(c, "b-offset-beyond"))
      offset = mem_size + req[1] * 16; /* past the memory's end */
   else if (!strcmp(c, "b-unaligned"))
      offset = req[1] > 1 ? 1 : 0, mem_size = req[0] * 2;
   else if (!strcmp(c, "b-small-memory"))
      mem_size = req[1] > 4096 ? req[1] : 4096; /* memory smaller than the buffer */
   else if (!strcmp(c, "b-offset-wrap"))
      offset = (UINT64_MAX - 0xffff) & ~(req[1] - 1); /* offset + size wraps */
   int32_t ret;
   const uint64_t mem = memory(mem_size, type, 0, 0, 0, &ret);
   if (!mem)
      return BROKEN;
   bind_buffer(buf, mem, offset, !strncmp(c, "b2-", 3));
   return outcome();
}

/* Mesa's PRIME buffer of a Vulkan window: on KosmicKrisp with OMACVM_VK_WINDOWS=iosurface
 * its memory is an IOSurface imported as host memory (ADR 0047), elsewhere a heap */
static int window_case(void)
{
   setenv("OMACVM_VK_WINDOWS", "iosurface", 1);
   setup(VK_API_VERSION_1_1, 0, NULL);
   uint64_t req[3];
   const uint64_t size = 1920 * 1080 * 4;
   const uint64_t buf = buffer(size, 0, 1, req);
   if (!buf)
      return BROKEN;
   const uint32_t type = memory_type((uint32_t)req[2], VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
   int32_t ret;
   const uint64_t mem =
      memory(req[0], type, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, 0, buf, &ret);
   if (!mem)
      return BROKEN;
   bind_buffer(buf, mem, 0, 0);
   if (kosmickrisp && !logged("Vulkan window buffers are IOSurfaces")) {
      printf("KosmicKrisp: the window buffer is not an IOSurface\n");
      return BROKEN;
   }
   return outcome();
}

/* memory made from a resource of this context (a blob of exported memory), its size the
 * guest's: the blob's own (must keep) or 1024 times it */
static int import_case(int oversize)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   if (!exported_memory(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT))
      return BROKEN;
   const uint64_t size = oversize ? 65536 * 1024 : 65536;
   uint64_t req[3];
   const uint64_t buf = buffer(size, 0, 0, req);
   if (!buf)
      return BROKEN;
   const uint32_t type = memory_type((uint32_t)req[2], VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
   int32_t ret;
   const uint64_t mem = memory(size, type, 0, 7, 0, &ret);
   if (!mem)
      return vkr_context_get_fatal(ctx) ? ENDED : REFUSED;
   bind_buffer(buf, mem, 0, 0);
   return outcome();
}

/* host-visible memory exported for the guest's blob; opaque: asked as OPAQUE_FD (the
 * emulated KHR_external_memory_fd), alone or with DMA_BUF */
static int export_case(uint32_t export_types)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   const uint32_t type = memory_type(~0u, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
   int32_t ret;
   const uint64_t mem = memory(65536, type, export_types, 0, 0, &ret);
   if (!mem) {
      printf("the driver made no such memory\n");
      return outcome();
   }
   if (!blob_from(7, mem, 65536))
      return BROKEN;
   return outcome();
}

static int semaphore_import_case(uint32_t resource)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   const uint64_t sem = semaphore();
   cmd(VK_COMMAND_TYPE_vkImportSemaphoreResourceMESA_EXT, 0);
   u64(DEV_ID); ptr(1); i32(VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_RESOURCE_INFO_MESA); ptr(0);
   u64(sem); u32(resource);
   submit();
   return outcome();
}

/* two command buffers in one call, with two ids or one id twice */
static int allocate_case(int same_id)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   const uint64_t pool = next_id++, a = next_id++, b = next_id++;
   cmd(VK_COMMAND_TYPE_vkCreateCommandPool_EXT, 0);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO); ptr(0); u32(2); u32(0);
   ptr(0); ptr(1); u64(pool);
   cmd(VK_COMMAND_TYPE_vkAllocateCommandBuffers_EXT, 0);
   u64(DEV_ID); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO); ptr(0); u64(pool); i32(0); u32(2);
   u64(2); u64(a); u64(same_id ? a : b);
   submit();
   if (!same_id && !vkr_context_get_fatal(ctx)) {
      cmd(VK_COMMAND_TYPE_vkFreeCommandBuffers_EXT, 0);
      u64(DEV_ID); u64(pool); u32(2); u64(2); u64(a); u64(b);
      submit();
   }
   return outcome();
}

static int simple_command_case(const char *c)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   if (!strcmp(c, "n-semvalue")) {
      const uint64_t sem = semaphore();
      cmd(VK_COMMAND_TYPE_vkGetSemaphoreCounterValue_EXT, 0);
      u64(DEV_ID); u64(sem); ptr(1);
   } else if (!strcmp(c, "n-submit2")) {
      cmd(VK_COMMAND_TYPE_vkQueueSubmit2_EXT, 0);
      u64(QUEUE_ID); u32(0); u64(0); u64(0);
   } else { /* n-accel: the generated create path; no Mac driver has the extension */
      uint64_t req[3];
      const uint64_t buf = buffer(65536, 0, 0, req);
      if (!buf)
         return BROKEN;
      cmd(VK_COMMAND_TYPE_vkCreateAccelerationStructureKHR_EXT, 0);
      u64(DEV_ID); ptr(1);
      i32(VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR); ptr(0);
      u32(0); u64(buf); u64(0); u64(4096); i32(0); u64(0);
      ptr(0); ptr(1); u64(next_id++);
   }
   submit();
   return outcome();
}

struct test_case {
   const char *name;
   int expect;
   /* the log line it must leave (NULL: none), or, for E_ALIVE, NULL = no refusal at all */
   const char *line;
};

static const struct test_case cases[] = {
   /* missing entry points: every path a guest command reaches one by */
   { "tables", E_ALIVE, NULL },
   { "no-context", E_ALIVE, "vkr's call failed" },
   { "dispatch-restore", E_ALIVE, NULL },
   { "n-cullmode", E_ENDED, "vkCmdSetCullMode refused" },
   { "n-accel", E_ENDED, "vkCreateAccelerationStructureKHR refused" },
   { "n-semvalue", E_ENDED, "vkGetSemaphoreCounterValue refused" },
   { "n-submit2", E_ENDED, "vkQueueSubmit2 refused" },
   { "n-sem-import", E_ENDED, "vkImportSemaphoreFdKHR refused" },
   { "n-ring", E_ENDED, "vkCmdSetCullMode refused" },
   { "n-nested", E_ENDED, "vkCmdSetCullMode refused" },
   { "p-coopmat", E_ENDED, "vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR refused" },
   { "p-fsr", E_ENDED, "vkGetPhysicalDeviceFragmentShadingRatesKHR refused" },
   /* must keep: the commands on devices that have them, #623's zero answers */
   { "c-cullmode", E_ALIVE, NULL },
   { "c-cullmode-ext", E_ALIVE, NULL },
   { "c-devreq", E_ALIVE, "vkGetDeviceImageMemoryRequirements refused: the device has no" },
   { "c-devlayout", E_ALIVE, "vkGetDeviceImageSubresourceLayout refused: the device has no" },
   /* asserts a guest reached */
   { "a-sem-import-res", E_ENDED, "vkImportSemaphoreResourceMESA refused" },
   { "a-dup-alloc", E_ENDED, "an object array refused" },
   { "a-monitor0", E_ENDED, "invalid ring reporting period" },
   { "c-alloc2", E_ALIVE, NULL },
   { "c-ring", E_ALIVE, NULL },
   { "x-opaque", E_ALIVE, NULL },
   { "x-opaque-dmabuf", E_ALIVE, NULL },
   { "x-dmabuf", E_ALIVE, NULL },
   /* buffer binds */
   { "b-ok", E_ALIVE, NULL },
   { "b2-ok", E_ALIVE, NULL },
   { "b-window", E_ALIVE, NULL },
   { "b-past-end", E_ENDED, "vkBindBufferMemory refused" },
   { "b2-past-end", E_ENDED, "vkBindBufferMemory2 refused: bind 0" },
   { "b-offset-beyond", E_ENDED, "vkBindBufferMemory refused" },
   { "b-offset-wrap", E_ENDED, "vkBindBufferMemory refused" },
   { "b-unaligned", E_ENDED, "not a multiple of" },
   { "b-small-memory", E_ENDED, "past the memory's" },
   { "b-wrong-type", E_ENDED, "not one of" },
   { "b-huge-buffer", E_ENDED, "past the memory's" },
   { "b-sparse", E_ENDED, "a sparse buffer" },
   { "i-import", E_ALIVE, NULL },
   { "i-oversize", E_REFUSED, "vkAllocateMemory refused" },
   /* replies carry zeros where nothing was written */
   { "o-refused-chain", E_ALIVE, "vkGetImageMemoryRequirements2 refused" },
   { "o-unwritten-chain", E_ALIVE, NULL },
};

#define IS(s) (!strcmp(name, s))

static int run_case(const char *name)
{
   if (IS("driver")) {
      setup(VK_API_VERSION_1_1, 0, NULL);
      return kosmickrisp ? REFUSED : ALIVE;
   }
#ifdef VKR_MISSING
   if (IS("tables"))
      return tables_case();
   if (IS("no-context"))
      return no_context_case();
   if (IS("dispatch-restore"))
      return dispatch_restore_case();
#else
   if (IS("tables") || IS("no-context") || IS("dispatch-restore")) {
      printf("built without virgl-venus-missing-entries.patch\n");
      return BROKEN;
   }
#endif
   if (IS("n-cullmode"))
      return cull_mode_case(VK_API_VERSION_1_1, 0);
   if (IS("c-cullmode"))
      return cull_mode_case(VK_API_VERSION_1_3, 0);
   if (IS("c-cullmode-ext"))
      return cull_mode_case(VK_API_VERSION_1_1, 1);
   if (IS("n-accel") || IS("n-semvalue") || IS("n-submit2"))
      return simple_command_case(name);
   if (IS("n-sem-import"))
      return semaphore_import_case(0);
   if (IS("a-sem-import-res"))
      return semaphore_import_case(5);
   if (IS("n-ring"))
      return ring_case(0, 1);
   if (IS("c-ring"))
      return ring_case(0, 0);
   if (IS("a-monitor0"))
      return ring_case(1, 0);
   if (IS("n-nested"))
      return nested_case();
   if (IS("p-coopmat"))
      return physical_query_case(VK_COMMAND_TYPE_vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR_EXT,
                                 "VK_KHR_cooperative_matrix");
   if (IS("p-fsr"))
      return physical_query_case(VK_COMMAND_TYPE_vkGetPhysicalDeviceFragmentShadingRatesKHR_EXT,
                                 "VK_KHR_fragment_shading_rate");
   if (IS("c-devreq"))
      return device_image_query_case(0);
   if (IS("c-devlayout"))
      return device_image_query_case(1);
   if (IS("a-dup-alloc"))
      return allocate_case(1);
   if (IS("c-alloc2"))
      return allocate_case(0);
   if (IS("x-opaque"))
      return export_case(VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT);
   if (IS("x-opaque-dmabuf"))
      return export_case(VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT |
                         VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT);
   if (IS("x-dmabuf"))
      return export_case(VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT);
   if (IS("b-window"))
      return window_case();
   if (IS("b-ok") || IS("b2-ok"))
      return bind_case(name);
   if (!strncmp(name, "b-", 2) || !strncmp(name, "b2-", 3))
      return bind_case(name);
   if (IS("i-import"))
      return import_case(0);
   if (IS("i-oversize"))
      return import_case(1);
   if (IS("o-refused-chain"))
      return reply_chain_case(1);
   if (IS("o-unwritten-chain"))
      return reply_chain_case(0);
   printf("unknown case %s\n", name);
   return BROKEN;
}

/* a case's own checks of its log, when it saw what it must see (another outcome stays as
 * it is: a bind that went through before the patch shows as "the context lives") */
static int checked(const struct test_case *c, int got)
{
   const int want = c->expect == E_ALIVE ? ALIVE : c->expect == E_REFUSED ? REFUSED : ENDED;
   if (got != want)
      return got;
   if (c->line && !logged(c->line)) {
      printf("no log line with \"%s\"\n", c->line);
      return BROKEN;
   }
   if (!c->line && got == ALIVE && logged(" refused: ")) {
      printf("a refusal in a case that must keep working\n");
      return BROKEN;
   }
   return got;
}

/* microseconds per vkCreateBuffer + vkDestroyBuffer through vkr's dispatch, and how much
 * of it is the one requirements query virgl-venus-buffer-binds.patch adds at create */
static int time_creates(int n)
{
   setup(VK_API_VERSION_1_1, 0, NULL);
   struct vn_dispatch_context *D = &ctx->dispatch;
   struct vkr_device *dev = vkr_context_get_object(ctx, DEV_ID);
   const VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                     .size = 65536,
                                     .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
   struct timespec t0, t1;
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      const uint64_t id = next_id++;
      VkBuffer handle = (VkBuffer)(uintptr_t)id;
      VkBufferCreateInfo copy = info;
      struct vn_command_vkCreateBuffer a = { .device = (VkDevice)dev, .pCreateInfo = &copy,
                                             .pBuffer = &handle };
      D->dispatch_vkCreateBuffer(D, &a);
      struct vkr_buffer *buffer = vkr_context_get_object(ctx, id);
      if (a.ret != VK_SUCCESS || !buffer)
         broken("a create failed while timing");
      struct vn_command_vkDestroyBuffer d = { .device = (VkDevice)dev, .buffer = (VkBuffer)buffer };
      D->dispatch_vkDestroyBuffer(D, &d);
   }
   clock_gettime(CLOCK_MONOTONIC, &t1);
   const double with = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / 1e3 / n;

   VkBuffer host;
   dev->proc_table.CreateBuffer(dev->base.handle.device, &info, NULL, &host);
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      VkMemoryRequirements req;
      dev->proc_table.GetBufferMemoryRequirements(dev->base.handle.device, host, &req);
   }
   clock_gettime(CLOCK_MONOTONIC, &t1);
   const double query = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / 1e3 / n;
   dev->proc_table.DestroyBuffer(dev->base.handle.device, host, NULL);
   printf("timing: %d creates: %.2f us per vkCreateBuffer+vkDestroyBuffer through vkr, "
          "%.2f us of it the requirements query, %.2f us without it\n", n, with, query,
          with - query);

   /* through the decoder (vkr_context_submit_cmd), 64 commands a stream: a query with a
    * reply (its temp memory zeroed by virgl-venus-temp-zero.patch) and a vkCmd* (none) */
   const uint64_t cb = command_buffer();
   double per[2];
   for (int kind = 0; kind < 2; kind++) {
      const int batches = n / 64 > 0 ? n / 64 : 1;
      double total = 0;
      for (int b = 0; b < batches; b++) {
         for (int i = 0; i < 64; i++) {
            if (kind == 0) {
               seek(0);
               cmd(VK_COMMAND_TYPE_vkGetPhysicalDeviceFormatProperties2_EXT, 1);
               u64(PDEV_ID); i32(VK_FORMAT_R8G8B8A8_UNORM);
               ptr(1); i32(VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2); ptr(0);
            } else {
               cmd(VK_COMMAND_TYPE_vkCmdSetViewport_EXT, 0);
               u64(cb); u32(0); u32(1); u64(1);
               f32(0); f32(0); f32(64); f32(64); f32(0); f32(1);
            }
         }
         clock_gettime(CLOCK_MONOTONIC, &t0);
         if (!submit())
            broken("a stream failed while timing");
         clock_gettime(CLOCK_MONOTONIC, &t1);
         total += (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
      }
      per[kind] = total / 1e3 / (batches * 64);
   }
   printf("timing: through the decoder, us per command: vkGetPhysicalDeviceFormatProperties2 "
          "(a reply) %.3f, vkCmdSetViewport %.3f\n", per[0], per[1]);
   return 0;
}

static const char *outcome_name(int status)
{
   switch (status) {
   case ALIVE: return "the context lives";
   case REFUSED: return "refused, the context lives";
   case ENDED: return "the context ended";
   case SKIP: return "skipped";
   default: return "broken";
   }
}

int main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IOLBF, 0);
   if (argc == 3 && !strcmp(argv[1], "--time"))
      return time_creates(atoi(argv[2]));
   if (argc == 2) {
      int status = run_case(argv[1]);
      for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
         if (!strcmp(cases[i].name, argv[1]))
            status = checked(&cases[i], status);
      }
      fflush(stdout);
      /* no cleanup: the process ends here, the driver's objects with it */
      _exit(status);
   }

   pid_t pid;
   int status;
   const char *driver_args[] = { argv[0], "driver", NULL };
   if (posix_spawn(&pid, argv[0], NULL, NULL, (char **)driver_args, environ) ||
       waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) ||
       (WEXITSTATUS(status) != ALIVE && WEXITSTATUS(status) != REFUSED)) {
      printf("FAIL: no Venus device to test\n");
      return 1;
   }
   const bool kk = WEXITSTATUS(status) == REFUSED;
   /* each child writes to one file; printed only when its case fails */
   char log[] = "/tmp/venus-robust.XXXXXX";
   const int log_fd = mkstemp(log);
   if (log_fd < 0) {
      printf("FAIL: no file for the cases' output\n");
      return 1;
   }
   posix_spawn_file_actions_t to_log;
   posix_spawn_file_actions_init(&to_log);
   posix_spawn_file_actions_adddup2(&to_log, log_fd, 1);
   posix_spawn_file_actions_adddup2(&to_log, log_fd, 2);
   int failures = 0, skipped = 0;
   for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
      const struct test_case *c = &cases[i];
      const char *args[] = { argv[0], c->name, NULL };
      if (ftruncate(log_fd, 0) || lseek(log_fd, 0, SEEK_SET) ||
          posix_spawn(&pid, argv[0], &to_log, NULL, (char **)args, environ) ||
          waitpid(pid, &status, 0) < 0) {
         printf("FAIL: %s: not started\n", c->name);
         failures++;
         continue;
      }
      char seen[64];
      int got = -1;
      if (WIFSIGNALED(status)) {
         snprintf(seen, sizeof(seen), "the process ended (signal %d)", WTERMSIG(status));
      } else {
         got = WEXITSTATUS(status);
         snprintf(seen, sizeof(seen), "%s", outcome_name(got));
      }
      bool ok;
      switch (c->expect) {
      case E_ALIVE: ok = got == ALIVE; break;
      case E_REFUSED: ok = got == REFUSED; break;
      default: ok = got == ENDED || got == SKIP; break;
      }
      skipped += got == SKIP;
      printf("%s: %s: %s\n", ok ? "ok" : "FAIL", c->name, seen);
      if (!ok) {
         char line[512];
         FILE *f = fopen(log, "r");
         while (f && fgets(line, sizeof(line), f))
            printf("   | %s", line);
         if (f)
            fclose(f);
      }
      failures += !ok;
   }
   posix_spawn_file_actions_destroy(&to_log);
   close(log_fd);
   unlink(log);
   printf("%s: %zu cases (%d skipped) on %s\n", failures ? "FAILED" : "all ok",
          sizeof(cases) / sizeof(cases[0]), skipped, kk ? "KosmicKrisp" : "MoltenVK");
   return failures != 0;
}
