/* venus-raw: Venus commands that ended the whole VM through vkr up to 3.2.14 (ADR 0065,
 * "What else vkr refuses"), sent from a program in the VM. The guest's Mesa never sends
 * them, so this is a raw Venus client: it opens the render node, makes a Venus context and
 * sends hand-encoded commands with EXECBUFFER, as Mesa's virtgpu backend does. One case
 * per run; the caller runs each in its own process and checks that QEMU lives on. Object
 * creation, queries and binds only: no command buffer is submitted, nothing runs on the
 * GPU.
 * Last line: "alive: ..." (the context lives), "context ended: ..." (vkr ended it: no
 * reply), or nothing when the VM ended.
 * Build: cc -O1 -I<Vulkan headers> -o venus-raw venus-raw.c
 * Usage: venus-raw CASE    (cases: see main) */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm/virtgpu_drm.h>
#include <vulkan/vulkan.h>

/* the Venus protocol's command types and structure types (virglrenderer 1.3.0's
 * venus-protocol/vn_protocol_renderer_defines.h) */
enum {
   CT_vkCreateInstance = 0,
   CT_vkEnumeratePhysicalDevices = 2,
   CT_vkGetPhysicalDeviceMemoryProperties = 8,
   CT_vkCreateDevice = 11,
   CT_vkAllocateMemory = 21,
   CT_vkBindBufferMemory = 28,
   CT_vkGetBufferMemoryRequirements = 30,
   CT_vkCreateSemaphore = 40,
   CT_vkCreateBuffer = 50,
   CT_vkCreateCommandPool = 85,
   CT_vkAllocateCommandBuffers = 88,
   CT_vkBeginCommandBuffer = 90,
   CT_vkEnumerateInstanceVersion = 137,
   CT_vkBindBufferMemory2 = 138,
   CT_vkGetDeviceQueue2 = 155,
   CT_vkGetSemaphoreCounterValue = 172,
   CT_vkSetReplyCommandStreamMESA = 178,
   CT_vkSeekReplyCommandStreamMESA = 179,
   CT_vkCreateRingMESA = 188,
   CT_vkNotifyRingMESA = 190,
   CT_vkQueueSubmit2 = 206,
   CT_vkCmdSetCullMode = 215,
   CT_vkImportSemaphoreResourceMESA = 246,
   CT_vkGetPhysicalDeviceFragmentShadingRatesKHR = 277,
   CT_vkCreateAccelerationStructureKHR = 304,
   CT_vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR = 331,
};
#define ST_RING_CREATE_INFO_MESA 1000384000
#define ST_IMPORT_MEMORY_RESOURCE_INFO_MESA 1000384002
#define ST_IMPORT_SEMAPHORE_RESOURCE_INFO_MESA 1000384004
#define ST_DEVICE_QUEUE_TIMELINE_INFO_MESA 1000384005
#define ST_RING_MONITOR_INFO_MESA 1000384006
#define GENERATE_REPLY 1u /* VK_COMMAND_GENERATE_REPLY_BIT_EXT */
#define CAPSET_VENUS 4

#define REPLY_SIZE 65536
#define SYNC_POS 32768

static int fd = -1;
static uint32_t reply_res;
static volatile uint8_t *reply;
static uint8_t cs[1 << 16];
static size_t cs_n;
static uint64_t next_id = 100;
static const char *case_name;

static void step(const char *fmt, ...)
{
   va_list va;
   va_start(va, fmt);
   vprintf(fmt, va);
   va_end(va);
   printf("\n");
   fflush(stdout);
}

/* ---- the render node: a Venus context, blobs, command streams ---- */
static void venus_context(void)
{
   fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
   if (fd < 0) {
      step("venus-raw: no render node (%s)", strerror(errno));
      exit(2);
   }
   struct drm_virtgpu_context_set_param params[] = {
      { VIRTGPU_CONTEXT_PARAM_CAPSET_ID, CAPSET_VENUS },
      { VIRTGPU_CONTEXT_PARAM_NUM_RINGS, 64 },
   };
   struct drm_virtgpu_context_init init = { .num_params = 2,
                                            .ctx_set_params = (uintptr_t)params };
   if (ioctl(fd, DRM_IOCTL_VIRTGPU_CONTEXT_INIT, &init)) {
      step("venus-raw: no Venus context (%s)", strerror(errno));
      exit(2);
   }
}

/* a host blob: blob_id 0 with MAPPABLE only is shared memory, else device memory */
static uint32_t blob(uint64_t blob_id, uint64_t size, uint32_t flags, uint32_t *bo)
{
   struct drm_virtgpu_resource_create_blob b = {
      .blob_mem = VIRTGPU_BLOB_MEM_HOST3D, .blob_flags = flags, .size = size, .blob_id = blob_id,
   };
   if (ioctl(fd, DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB, &b))
      return 0;
   if (bo)
      *bo = b.bo_handle;
   return b.res_handle;
}

static void *map(uint32_t bo, uint64_t size)
{
   struct drm_virtgpu_map m = { .handle = bo };
   if (ioctl(fd, DRM_IOCTL_VIRTGPU_MAP, &m))
      return NULL;
   void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m.offset);
   return p == MAP_FAILED ? NULL : p;
}

static int submit(void)
{
   struct drm_virtgpu_execbuffer e = { .size = (uint32_t)cs_n, .command = (uintptr_t)cs,
                                       .fence_fd = -1 };
   const int r = ioctl(fd, DRM_IOCTL_VIRTGPU_EXECBUFFER, &e);
   cs_n = 0;
   return r;
}

/* ---- encoder (4-byte units, as vn_cs_encoder) ---- */
static void put(const void *p, size_t n)
{
   const size_t padded = (n + 3) & ~(size_t)3;
   if (cs_n + padded > sizeof(cs)) {
      step("venus-raw: command buffer full");
      exit(2);
   }
   memcpy(cs + cs_n, p, n);
   memset(cs + cs_n + n, 0, padded - n);
   cs_n += padded;
}
static void u32(uint32_t v) { put(&v, 4); }
static void i32(int32_t v) { put(&v, 4); }
static void u64(uint64_t v) { put(&v, 8); }
static void f32(float v) { put(&v, 4); }
static void ptr(int present) { u64(present ? 1 : 0); }
static void cmd(int type, int want_reply)
{
   i32(type);
   u32(want_reply ? GENERATE_REPLY : 0);
}
static void seek(uint64_t pos)
{
   cmd(CT_vkSeekReplyCommandStreamMESA, 0);
   u64(pos);
}

/* queue a marker (vkEnumerateInstanceVersion with its reply at SYNC_POS), submit, wait:
 * true when everything before it was processed */
static int sync_and_wait(int seconds)
{
   memset((void *)(reply + SYNC_POS), 0xa5, 16);
   seek(SYNC_POS);
   cmd(CT_vkEnumerateInstanceVersion, 1);
   ptr(1);
   if (submit())
      return 0;
   for (int i = 0; i < seconds * 200; i++) {
      int32_t type;
      memcpy(&type, (const void *)(reply + SYNC_POS), 4);
      if (type == CT_vkEnumerateInstanceVersion)
         return 1;
      usleep(5000);
   }
   return 0;
}

static const uint8_t *reply_call(const char *what)
{
   memset((void *)reply, 0xa5, 256);
   if (!sync_and_wait(10)) {
      step("context ended: no reply to %s", what);
      exit(0);
   }
   return (const uint8_t *)reply;
}

static int32_t ret_of(const uint8_t *r)
{
   int32_t v;
   memcpy(&v, r + 4, 4);
   return v;
}

static void done(const char *what)
{
   if (!sync_and_wait(10)) {
      step("context ended: after %s", what);
      exit(0);
   }
   step("alive: %s", what);
   exit(0);
}

/* ---- the app's objects ---- */
static const uint64_t pdev = 2, dev = 3, queue = 4;

static void setup(uint32_t api)
{
   venus_context();
   uint32_t bo;
   reply_res = blob(0, REPLY_SIZE, VIRTGPU_BLOB_FLAG_USE_MAPPABLE, &bo);
   reply = reply_res ? map(bo, REPLY_SIZE) : NULL;
   if (!reply) {
      step("venus-raw: no reply memory (%s)", strerror(errno));
      exit(2);
   }
   cmd(CT_vkSetReplyCommandStreamMESA, 0);
   ptr(1); u32(reply_res); u64(0); u64(REPLY_SIZE);

   seek(0);
   cmd(CT_vkCreateInstance, 1);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO); ptr(0); u32(0);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_APPLICATION_INFO); ptr(0);
   u64(0); u32(0); u64(0); u32(0); u32(api);
   u32(0); u64(0);
   u32(0); u64(0);
   ptr(0);
   ptr(1); u64(1);
   if (ret_of(reply_call("vkCreateInstance")))
      exit(2);
   seek(0);
   cmd(CT_vkEnumeratePhysicalDevices, 1);
   u64(1);
   ptr(1); u32(1);
   u64(1); u64(pdev);
   const int32_t e = ret_of(reply_call("vkEnumeratePhysicalDevices"));
   if (e && e != VK_INCOMPLETE)
      exit(2);

   seek(0);
   cmd(CT_vkCreateDevice, 1);
   u64(pdev);
   ptr(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO); ptr(0); u32(0);
   u32(1); u64(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO); ptr(0); u32(0); u32(0); u32(1); u64(1); f32(1.0f);
   u32(0); u64(0);
   u32(0); u64(0);
   ptr(0);
   ptr(0);
   ptr(1); u64(dev);
   if (ret_of(reply_call("vkCreateDevice")))
      exit(2);
   cmd(CT_vkGetDeviceQueue2, 0);
   u64(dev); ptr(1);
   i32(VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2);
   ptr(1); i32(ST_DEVICE_QUEUE_TIMELINE_INFO_MESA); ptr(0); u32(1);
   u32(0); u32(0); u32(0);
   ptr(1); u64(queue);
   step("Venus context, instance %u.%u, device", VK_API_VERSION_MAJOR(api), VK_API_VERSION_MINOR(api));
}

static uint64_t command_buffer(void)
{
   const uint64_t pool = next_id++, cb = next_id++;
   cmd(CT_vkCreateCommandPool, 0);
   u64(dev); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO); ptr(0); u32(2); u32(0);
   ptr(0); ptr(1); u64(pool);
   cmd(CT_vkAllocateCommandBuffers, 0);
   u64(dev); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO); ptr(0); u64(pool); i32(0); u32(1);
   u64(1); u64(cb);
   cmd(CT_vkBeginCommandBuffer, 0);
   u64(cb); ptr(1);
   i32(VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO); ptr(0); u32(1); ptr(0);
   return cb;
}

static uint64_t semaphore(void)
{
   const uint64_t id = next_id++;
   cmd(CT_vkCreateSemaphore, 0);
   u64(dev); ptr(1);
   i32(VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO); ptr(0); u32(0);
   ptr(0); ptr(1); u64(id);
   return id;
}

static uint32_t mem_count, mem_flags[32];
static void memory_properties(void)
{
   seek(0);
   cmd(CT_vkGetPhysicalDeviceMemoryProperties, 1);
   u64(pdev); ptr(1); u64(32); u64(16);
   const uint8_t *r = reply_call("vkGetPhysicalDeviceMemoryProperties");
   memcpy(&mem_count, r + 12, 4);
   for (uint32_t i = 0; i < 32; i++)
      memcpy(&mem_flags[i], r + 24 + 8 * i, 4);
}

static uint32_t pick_type(uint32_t bits, uint32_t want, int not_in_bits)
{
   for (uint32_t i = 0; i < mem_count && i < 32; i++)
      if (!!(bits & (1u << i)) != !!not_in_bits && (mem_flags[i] & want) == want)
         return i;
   return UINT32_MAX;
}

static uint64_t buffer(uint64_t size, uint64_t req[3])
{
   const uint64_t id = next_id++;
   seek(0);
   cmd(CT_vkCreateBuffer, 1);
   u64(dev); ptr(1);
   i32(VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO); ptr(0); u32(0); u64(size);
   u32(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
   i32(0); u32(0); u64(0);
   ptr(0); ptr(1); u64(id);
   const int32_t r = ret_of(reply_call("vkCreateBuffer"));
   step("vkCreateBuffer(%llu) = %d", (unsigned long long)size, r);
   if (r)
      return 0;
   seek(0);
   cmd(CT_vkGetBufferMemoryRequirements, 1);
   u64(dev); u64(id); ptr(1);
   const uint8_t *rr = reply_call("vkGetBufferMemoryRequirements");
   uint32_t bits;
   memcpy(&req[0], rr + 12, 8);
   memcpy(&req[1], rr + 20, 8);
   memcpy(&bits, rr + 28, 4);
   req[2] = bits;
   return id;
}

/* memory; export_types and import_res (VkImportMemoryResourceInfoMESA) are optional */
static uint64_t memory(uint64_t size, uint32_t type, uint32_t export_types, uint32_t import_res)
{
   const uint64_t id = next_id++;
   seek(0);
   cmd(CT_vkAllocateMemory, 1);
   u64(dev); ptr(1);
   i32(VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
   if (export_types) {
      ptr(1); i32(VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO);
   }
   if (import_res) {
      ptr(1); i32(ST_IMPORT_MEMORY_RESOURCE_INFO_MESA);
   }
   ptr(0);
   if (import_res)
      u32(import_res);
   if (export_types)
      u32(export_types);
   u64(size); u32(type);
   ptr(0); ptr(1); u64(id);
   const int32_t r = ret_of(reply_call("vkAllocateMemory"));
   step("vkAllocateMemory(%llu, type %u, export 0x%x, import %u) = %d", (unsigned long long)size,
        type, export_types, import_res, r);
   return r ? 0 : id;
}

static void bind_buffer(uint64_t buf, uint64_t mem, uint64_t offset, int two)
{
   seek(0);
   if (two) {
      cmd(CT_vkBindBufferMemory2, 1);
      u64(dev); u32(1); u64(1);
      i32(VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO); ptr(0); u64(buf); u64(mem); u64(offset);
   } else {
      cmd(CT_vkBindBufferMemory, 1);
      u64(dev); u64(buf); u64(mem); u64(offset);
   }
   step("bind at %llu = %d", (unsigned long long)offset, ret_of(reply_call("the bind")));
}

int main(int argc, char **argv)
{
   if (argc < 2) {
      fprintf(stderr, "usage: venus-raw CASE\n");
      return 2;
   }
   const char *c = case_name = argv[1];
   setup(!strcmp(c, "c-cullmode") ? VK_API_VERSION_1_3 : VK_API_VERSION_1_1);

   /* commands of a version or extension the 1.1 device was not made with */
   if (!strcmp(c, "n-cullmode") || !strcmp(c, "c-cullmode")) {
      const uint64_t cb = command_buffer();
      cmd(CT_vkCmdSetCullMode, 0);
      u64(cb); u32(VK_CULL_MODE_BACK_BIT);
      done(c);
   }
   if (!strcmp(c, "n-semvalue")) {
      const uint64_t sem = semaphore();
      cmd(CT_vkGetSemaphoreCounterValue, 0);
      u64(dev); u64(sem); ptr(1);
      done(c);
   }
   if (!strcmp(c, "n-submit2")) {
      cmd(CT_vkQueueSubmit2, 0);
      u64(queue); u32(0); u64(0); u64(0);
      done(c);
   }
   if (!strcmp(c, "n-accel")) {
      uint64_t req[3];
      const uint64_t buf = buffer(65536, req);
      cmd(CT_vkCreateAccelerationStructureKHR, 0);
      u64(dev); ptr(1);
      i32(VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR); ptr(0);
      u32(0); u64(buf); u64(0); u64(4096); i32(0); u64(0);
      ptr(0); ptr(1); u64(next_id++);
      done(c);
   }
   if (!strcmp(c, "n-sem-import") || !strcmp(c, "a-sem-import-res")) {
      const uint64_t sem = semaphore();
      cmd(CT_vkImportSemaphoreResourceMESA, 0);
      u64(dev); ptr(1); i32(ST_IMPORT_SEMAPHORE_RESOURCE_INFO_MESA); ptr(0);
      u64(sem); u32(!strcmp(c, "a-sem-import-res") ? 5 : 0);
      done(c);
   }
   if (!strcmp(c, "p-coopmat") || !strcmp(c, "p-fsr")) {
      seek(0);
      cmd(!strcmp(c, "p-coopmat") ? CT_vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR
                                  : CT_vkGetPhysicalDeviceFragmentShadingRatesKHR, 1);
      u64(pdev); ptr(1); u32(0); u64(0);
      done(c);
   }
   /* one id twice in one call, or two ids (control) */
   if (!strcmp(c, "a-dup-alloc") || !strcmp(c, "c-alloc2")) {
      const uint64_t pool = next_id++, a = next_id++, b = next_id++;
      const int dup = !strcmp(c, "a-dup-alloc");
      cmd(CT_vkCreateCommandPool, 0);
      u64(dev); ptr(1);
      i32(VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO); ptr(0); u32(2); u32(0);
      ptr(0); ptr(1); u64(pool);
      cmd(CT_vkAllocateCommandBuffers, 0);
      u64(dev); ptr(1);
      i32(VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO); ptr(0); u64(pool); i32(0); u32(2);
      u64(2); u64(a); u64(dup ? a : b);
      done(c);
   }
   /* a ring with a monitor period of 0 (vkr ends the context, the ring never starts), or a
    * vkCmdSetCullMode through a ring thread; the process's end then ends the context */
   if (!strcmp(c, "a-monitor0") || !strcmp(c, "n-ring")) {
      const int monitor0 = !strcmp(c, "a-monitor0");
      const uint64_t cb = monitor0 ? 0 : command_buffer();
      uint32_t bo;
      const uint32_t res = blob(0, 65536, VIRTGPU_BLOB_FLAG_USE_MAPPABLE, &bo);
      uint8_t *shm = res ? map(bo, 65536) : NULL;
      if (!shm) {
         step("venus-raw: no ring memory");
         return 2;
      }
      volatile uint32_t *head = (volatile uint32_t *)shm, *tail = (volatile uint32_t *)(shm + 4);
      const uint64_t ring = 77;
      cmd(CT_vkCreateRingMESA, 0);
      u64(ring); ptr(1);
      i32(ST_RING_CREATE_INFO_MESA);
      if (monitor0) {
         ptr(1); i32(ST_RING_MONITOR_INFO_MESA); ptr(0); u32(0);
      } else {
         ptr(0);
      }
      u32(0); u32(res);
      u64(0); u64(65536);
      u64(1000000);
      u64(0); u64(4); u64(8);
      u64(64); u64(4096);
      u64(64 + 4096); u64(0);
      if (!monitor0) {
         if (!sync_and_wait(10)) {
            step("context ended: after vkCreateRingMESA");
            return 0;
         }
         cmd(CT_vkCmdSetCullMode, 0);
         u64(cb); u32(VK_CULL_MODE_BACK_BIT);
         memcpy(shm + 64, cs, cs_n);
         const uint32_t n = (uint32_t)cs_n;
         cs_n = 0;
         __atomic_store_n(tail, n, __ATOMIC_SEQ_CST);
         cmd(CT_vkNotifyRingMESA, 0);
         u64(ring); u32(0); u32(0);
         submit();
         for (int i = 0; i < 400 && *head != n; i++)
            usleep(5000);
      }
      done(c);
   }

   memory_properties();
   /* host-visible memory exported for a blob: OPAQUE_FD (the emulated
    * KHR_external_memory_fd) or DMA_BUF (control) */
   if (!strcmp(c, "x-opaque") || !strcmp(c, "x-dmabuf")) {
      const uint32_t type = pick_type(~0u, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
      const uint64_t mem = memory(65536, type, !strcmp(c, "x-opaque")
                                                  ? VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT
                                                  : VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, 0);
      if (!mem)
         done("allocation refused by the driver");
      if (!sync_and_wait(10)) {
         step("context ended: after the allocation");
         return 0;
      }
      const uint32_t res = blob(mem, 65536, VIRTGPU_BLOB_FLAG_USE_MAPPABLE | VIRTGPU_BLOB_FLAG_USE_SHAREABLE, NULL);
      step("blob from the memory: %s", res ? "made" : strerror(errno));
      done(c);
   }
   /* memory made from a blob of this context: its own size (control) or 1024 times it */
   if (!strcmp(c, "i-import") || !strcmp(c, "i-oversize")) {
      const uint32_t type = pick_type(~0u, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, 0);
      const uint64_t small = 65536, big = !strcmp(c, "i-import") ? small : small * 1024;
      const uint64_t a = memory(small, type, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, 0);
      if (!a || !sync_and_wait(10))
         done("the first memory");
      const uint32_t res = blob(a, small, VIRTGPU_BLOB_FLAG_USE_MAPPABLE | VIRTGPU_BLOB_FLAG_USE_SHAREABLE, NULL);
      if (!res)
         done("no blob from the first memory");
      uint64_t req[3];
      const uint64_t buf = buffer(big, req);
      const uint64_t b = memory(big, type, 0, res);
      if (!b || !buf) {
         step("refused: the memory from the blob");
         done(c);
      }
      bind_buffer(buf, b, 0, 0);
      done(c);
   }
   /* buffer binds */
   if (!strncmp(c, "b-", 2) || !strncmp(c, "b2-", 3)) {
      uint64_t req[3];
      const int huge = !strcmp(c, "b-huge-buffer");
      const uint64_t buf = buffer(huge ? 1ull << 40 : 65536, req);
      if (!buf)
         done("buffer refused by the driver");
      const int wrong = !strcmp(c, "b-wrong-type");
      const uint32_t type = pick_type((uint32_t)req[2], 0, wrong);
      if (type == UINT32_MAX)
         done("skip: one memory type only");
      uint64_t mem_size = huge ? 65536 : req[0], offset = 0;
      if (!strcmp(c, "b-past-end") || !strcmp(c, "b2-past-end"))
         offset = req[0] / 2 - (req[0] / 2) % req[1];
      else if (!strcmp(c, "b-offset-wrap"))
         offset = (UINT64_MAX - 0xffff) & ~(req[1] - 1);
      else if (!strcmp(c, "b-small-memory"))
         mem_size = req[1] > 4096 ? req[1] : 4096;
      const uint64_t mem = memory(mem_size, type, 0, 0);
      if (!mem)
         done("memory refused by the driver");
      bind_buffer(buf, mem, offset, !strncmp(c, "b2-", 3));
      done(c);
   }
   step("unknown case %s", c);
   return 2;
}
