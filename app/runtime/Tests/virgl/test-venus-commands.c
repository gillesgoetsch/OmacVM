/* Guest values in pipelines, render passes, descriptor sets, queries and vkCmd* parameters
 * stay inside what the Mac's Vulkan driver addresses (virgl-venus-command-limits.patch,
 * virgl-venus-descriptor-limits.patch, virgl-venus-render-pass-limits.patch,
 * virgl-venus-pipeline-limits.patch; ADR 0065, "Indices, counts and offsets").
 *
 * A real vkr context on the runtime's real driver, as in test-venus-image-limits.c: every
 * case goes through vkr's own dispatch functions (ctx->dispatch, where the decoder hands
 * over guest commands), with arguments shaped as the decoder makes them, each case in its
 * own child process. Without the patches the refused cases end their child (a write or
 * read at a guest-chosen offset, a Metal assertion, a NULL dereference) or reach the
 * driver; with them each ends only the app's context with a "refused" log line, and the
 * cases that must keep working (the legal maxima: every limit at its advertised value)
 * still work without one.
 *
 * Objects, pipelines, descriptor writes and command RECORDING only: nothing is submitted,
 * and a child ends with _exit() right after its last call, so no command buffer is reset
 * or destroyed (MoltenVK commits a prefilled Metal command buffer then). Run with
 * MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1, MoltenVK encodes at vkEndCommandBuffer what
 * it otherwise encodes at vkQueueSubmit in QEMU, still without committing (standards 14).
 *
 *   test-venus-commands              every case, one child each, then a summary
 *   test-venus-commands CASE         one case (what the children run)
 *   test-venus-commands --list       the case names
 *   test-venus-commands --time N     microseconds per command through vkr
 *
 * The driver is vkr's choice from OMACVM_VULKAN_DRIVER, the binary sits beside the
 * runtime's loader and drivers (run-venus-limits.py builds that folder). */
#include <fcntl.h>
#include <inttypes.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "virgl_util.h"
#include "vkr_buffer.h"
#include "vkr_command_buffer.h"
#include "vkr_context.h"
#include "vkr_descriptor_set.h"
#include "vkr_device.h"
#include "vkr_device_memory.h"
#include "vkr_image.h"
#include "vkr_instance.h"
#include "vkr_physical_device.h"
#include "vkr_pipeline.h"
#include "vkr_query_pool.h"
#include "vkr_render_pass.h"
#include "vkr_renderer.h"

extern char **environ;

/* what a case saw: the child's exit status */
enum { WORKS = 10, ERROR = 11, FATAL = 12, SKIP = 13, BROKEN = 2 };
/* what a case must see: refused (the context ends with a log line), kept (works or a
 * VkResult error, no refusal), works (no error, no refusal); the multiview and push
 * constant cases decide in the child from the device's limits ("expect:" line) */
enum { E_REFUSE, E_KEEP, E_WORKS, E_CHILD };

/* device features a case needs; a case whose feature the device lacks is skipped */
enum {
   N_NULLDESC = 1 << 0,  /* robustness2 nullDescriptor on */
   N_NESTED = 1 << 1,    /* VK_EXT_nested_command_buffer when the guest is told of it */
   N_SAMPLELOC = 1 << 2, /* VK_EXT_sample_locations */
   N_LOCALREAD = 1 << 3, /* VK_KHR_dynamic_rendering_local_read */
   N_MULTIDRAW = 1 << 4, /* VK_EXT_multi_draw */
   N_PUSHDESC = 1 << 5,  /* VK_KHR_push_descriptor */
   N_MAINT6 = 1 << 6,    /* VK_KHR_maintenance6 (vkCmd*2 descriptor calls) */
   N_MAINT5 = 1 << 7,    /* VK_KHR_maintenance5 (shader code inside a pipeline stage) */
   N_ROBUST = 1 << 8,    /* VK_EXT_pipeline_robustness */
   N_LOGICOP = 1 << 9,   /* extendedDynamicState2LogicOp */
   N_BLENDEN = 1 << 10,  /* extendedDynamicState3ColorBlendEnable */
};

static const uint32_t spv_vert[] = {
   0x07230203, 0x00010300, 0x000d000b, 0x00000015, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0007000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000d, 0x00000011, 0x00030047,
   0x0000000b, 0x00000002, 0x00050048, 0x0000000b, 0x00000000, 0x0000000b, 0x00000000, 0x00050048,
   0x0000000b, 0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x0000000b, 0x00000002, 0x0000000b,
   0x00000003, 0x00050048, 0x0000000b, 0x00000003, 0x0000000b, 0x00000004, 0x00040047, 0x00000011,
   0x0000001e, 0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
   0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040015, 0x00000008,
   0x00000020, 0x00000000, 0x0004002b, 0x00000008, 0x00000009, 0x00000001, 0x0004001c, 0x0000000a,
   0x00000006, 0x00000009, 0x0006001e, 0x0000000b, 0x00000007, 0x00000006, 0x0000000a, 0x0000000a,
   0x00040020, 0x0000000c, 0x00000003, 0x0000000b, 0x0004003b, 0x0000000c, 0x0000000d, 0x00000003,
   0x00040015, 0x0000000e, 0x00000020, 0x00000001, 0x0004002b, 0x0000000e, 0x0000000f, 0x00000000,
   0x00040020, 0x00000010, 0x00000001, 0x00000007, 0x0004003b, 0x00000010, 0x00000011, 0x00000001,
   0x00040020, 0x00000013, 0x00000003, 0x00000007, 0x00050036, 0x00000002, 0x00000004, 0x00000000,
   0x00000003, 0x000200f8, 0x00000005, 0x0004003d, 0x00000007, 0x00000012, 0x00000011, 0x00050041,
   0x00000013, 0x00000014, 0x0000000d, 0x0000000f, 0x0003003e, 0x00000014, 0x00000012, 0x000100fd,
   0x00010038,
};
static const uint32_t spv_frag[] = {
   0x07230203, 0x00010300, 0x000d000b, 0x00000019, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0006000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x00000009, 0x00030010, 0x00000004,
   0x00000007, 0x00040047, 0x00000009, 0x0000001e, 0x00000000, 0x00030047, 0x0000000a, 0x00000002,
   0x00050048, 0x0000000a, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x0000000c, 0x00000021,
   0x00000000, 0x00040047, 0x0000000c, 0x00000022, 0x00000000, 0x00030047, 0x00000012, 0x00000002,
   0x00050048, 0x00000012, 0x00000000, 0x00000023, 0x00000000, 0x00020013, 0x00000002, 0x00030021,
   0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
   0x00000004, 0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003b, 0x00000008, 0x00000009,
   0x00000003, 0x0003001e, 0x0000000a, 0x00000007, 0x00040020, 0x0000000b, 0x00000002, 0x0000000a,
   0x0004003b, 0x0000000b, 0x0000000c, 0x00000002, 0x00040015, 0x0000000d, 0x00000020, 0x00000001,
   0x0004002b, 0x0000000d, 0x0000000e, 0x00000000, 0x00040020, 0x0000000f, 0x00000002, 0x00000007,
   0x0003001e, 0x00000012, 0x00000007, 0x00040020, 0x00000013, 0x00000009, 0x00000012, 0x0004003b,
   0x00000013, 0x00000014, 0x00000009, 0x00040020, 0x00000015, 0x00000009, 0x00000007, 0x00050036,
   0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x00050041, 0x0000000f,
   0x00000010, 0x0000000c, 0x0000000e, 0x0004003d, 0x00000007, 0x00000011, 0x00000010, 0x00050041,
   0x00000015, 0x00000016, 0x00000014, 0x0000000e, 0x0004003d, 0x00000007, 0x00000017, 0x00000016,
   0x00050081, 0x00000007, 0x00000018, 0x00000011, 0x00000017, 0x0003003e, 0x00000009, 0x00000018,
   0x000100fd, 0x00010038,
};
static const uint32_t spv_comp[] = {
   0x07230203, 0x00010300, 0x000d000b, 0x00000019, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0006000f, 0x00000005, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000f, 0x00060010, 0x00000004,
   0x00000011, 0x00000001, 0x00000001, 0x00000001, 0x00040047, 0x00000007, 0x00000006, 0x00000004,
   0x00030047, 0x00000008, 0x00000002, 0x00050048, 0x00000008, 0x00000000, 0x00000023, 0x00000000,
   0x00040047, 0x0000000a, 0x00000021, 0x00000002, 0x00040047, 0x0000000a, 0x00000022, 0x00000000,
   0x00040047, 0x0000000f, 0x0000000b, 0x0000001c, 0x00040047, 0x00000017, 0x00000001, 0x00000000,
   0x00040047, 0x00000018, 0x0000000b, 0x00000019, 0x00020013, 0x00000002, 0x00030021, 0x00000003,
   0x00000002, 0x00040015, 0x00000006, 0x00000020, 0x00000000, 0x0003001d, 0x00000007, 0x00000006,
   0x0003001e, 0x00000008, 0x00000007, 0x00040020, 0x00000009, 0x0000000c, 0x00000008, 0x0004003b,
   0x00000009, 0x0000000a, 0x0000000c, 0x00040015, 0x0000000b, 0x00000020, 0x00000001, 0x0004002b,
   0x0000000b, 0x0000000c, 0x00000000, 0x00040017, 0x0000000d, 0x00000006, 0x00000003, 0x00040020,
   0x0000000e, 0x00000001, 0x0000000d, 0x0004003b, 0x0000000e, 0x0000000f, 0x00000001, 0x0004002b,
   0x00000006, 0x00000010, 0x00000000, 0x00040020, 0x00000011, 0x00000001, 0x00000006, 0x0004002b,
   0x00000006, 0x00000014, 0x00000001, 0x00040020, 0x00000015, 0x0000000c, 0x00000006, 0x00040032,
   0x00000006, 0x00000017, 0x00000001, 0x00060033, 0x0000000d, 0x00000018, 0x00000017, 0x00000014,
   0x00000014, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005,
   0x00050041, 0x00000011, 0x00000012, 0x0000000f, 0x00000010, 0x0004003d, 0x00000006, 0x00000013,
   0x00000012, 0x00060041, 0x00000015, 0x00000016, 0x0000000a, 0x0000000c, 0x00000013, 0x0003003e,
   0x00000016, 0x00000014, 0x000100fd, 0x00010038,
};

static struct vkr_context *ctx;
static struct vn_dispatch_context *D;
static struct vkr_physical_device *pdev;
static struct vkr_device *dev;
static uint64_t next_id = 100;
static VkPhysicalDeviceProperties props;
static VkPhysicalDeviceLimits lim;
static bool kosmickrisp;
static unsigned have;            /* N_* the device was made with */
static uint32_t max_views;       /* maxMultiviewViewCount as vkr reports it to the guest */
static uint32_t max_push_descriptors, max_inline_block;
static uint32_t dynamic_ubo_max, dynamic_ssbo_max; /* the larger of the core and update-after-bind limits */
static VkSampleCountFlags sample_location_counts;
static VkExtent2D sample_location_grid;
static VkResult last_ret;

#define DEVH ((VkDevice)dev)
#define FMT VK_FORMAT_R8G8B8A8_UNORM
#define FAR32 0x7fffff00u
#define FAR_INDEX 0x04000000u

/* ---- the log: kept to check for a refusal line, printed with the child's output ---- */
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

static void step(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void step(const char *fmt, ...)
{
   va_list ap;
   va_start(ap, fmt);
   printf("step: ");
   vprintf(fmt, ap);
   printf("\n");
   va_end(ap);
   fflush(stdout);
}

static void broken(const char *what)
{
   printf("test setup: %s\n", what);
   fflush(stdout);
   _exit(BROKEN);
}

static void *object(uint64_t id)
{
   return vkr_context_get_object(ctx, id);
}

static void retire(uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id)
{
   (void)ctx_id;
   (void)ring_idx;
   (void)fence_id;
}

/* whether vkr tells the guest of the extension */
static bool lists(const char *name)
{
   for (uint32_t i = 0; i < pdev->extension_count; i++)
      if (!strcmp(pdev->extensions[i].extensionName, name))
         return true;
   return false;
}

/* ---- setup: instance, physical device, and a device with what the case needs ---- */
static void instance_and_physical_device(void)
{
   static const struct vkr_renderer_callbacks cbs = { .retire_fence = retire };
   virgl_log_set_handler(log_cb, NULL, NULL);
   if (!vkr_renderer_init(VKR_RENDERER_THREAD_SYNC | VKR_RENDERER_ASYNC_FENCE_CB, &cbs))
      broken("vkr_renderer_init");
   ctx = vkr_context_create(1, retire, 4, "test");
   if (!ctx)
      broken("no Venus context (no Vulkan loader beside the binary?)");
   D = &ctx->dispatch;
   const VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                                   .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                .pApplicationInfo = &app };
   VkInstance instance_id = (VkInstance)(uintptr_t)1;
   struct vn_command_vkCreateInstance ci = { .pCreateInfo = &ici, .pInstance = &instance_id };
   D->dispatch_vkCreateInstance(D, &ci);
   if (ci.ret != VK_SUCCESS || !object(1))
      broken("vkCreateInstance");
   uint32_t count = 1;
   VkPhysicalDevice pdev_id = (VkPhysicalDevice)(uintptr_t)2;
   struct vn_command_vkEnumeratePhysicalDevices ep = {
      .instance = (VkInstance)object(1), .pPhysicalDeviceCount = &count, .pPhysicalDevices = &pdev_id };
   D->dispatch_vkEnumeratePhysicalDevices(D, &ep);
   pdev = object(2);
   if ((ep.ret != VK_SUCCESS && ep.ret != VK_INCOMPLETE) || !pdev)
      broken("vkEnumeratePhysicalDevices");
   props = pdev->properties;
   lim = props.limits;

   /* what the guest is told, through vkr's own query */
   VkPhysicalDeviceMultiviewProperties mvp = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTIVIEW_PROPERTIES };
   VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
                                            .pNext = &mvp };
   VkPhysicalDevicePushDescriptorPropertiesKHR pdp = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PUSH_DESCRIPTOR_PROPERTIES_KHR, .pNext = &drv };
   VkPhysicalDeviceInlineUniformBlockProperties iub = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_INLINE_UNIFORM_BLOCK_PROPERTIES,
      .pNext = lists(VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME) ? (void *)&pdp : (void *)&drv };
   VkPhysicalDeviceSampleLocationsPropertiesEXT slp = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLE_LOCATIONS_PROPERTIES_EXT, .pNext = &iub };
   VkPhysicalDeviceVulkan12Properties p12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES,
                                              .pNext = lists(VK_EXT_SAMPLE_LOCATIONS_EXTENSION_NAME)
                                                          ? (void *)&slp
                                                          : (void *)&iub };
   VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &p12 };
   struct vn_command_vkGetPhysicalDeviceProperties2 gp = { .physicalDevice = (VkPhysicalDevice)pdev,
                                                          .pProperties = &p2 };
   D->dispatch_vkGetPhysicalDeviceProperties2(D, &gp);
   kosmickrisp = drv.driverID == VK_DRIVER_ID_MESA_KOSMICKRISP;
   max_views = mvp.maxMultiviewViewCount;
   max_push_descriptors = pdp.maxPushDescriptors;
   max_inline_block = iub.maxInlineUniformBlockSize;
   dynamic_ubo_max = lim.maxDescriptorSetUniformBuffersDynamic > p12.maxDescriptorSetUpdateAfterBindUniformBuffersDynamic
                        ? lim.maxDescriptorSetUniformBuffersDynamic
                        : p12.maxDescriptorSetUpdateAfterBindUniformBuffersDynamic;
   dynamic_ssbo_max = lim.maxDescriptorSetStorageBuffersDynamic > p12.maxDescriptorSetUpdateAfterBindStorageBuffersDynamic
                         ? lim.maxDescriptorSetStorageBuffersDynamic
                         : p12.maxDescriptorSetUpdateAfterBindStorageBuffersDynamic;
   sample_location_counts = slp.sampleLocationSampleCounts;
   sample_location_grid = slp.maxSampleLocationGridSize;
}

/* sample locations the device takes: its smallest count, one grid cell */
static VkSampleLocationsInfoEXT valid_sample_locations(void)
{
   static VkSampleLocationEXT pts[64];
   const VkSampleCountFlagBits per_pixel = (VkSampleCountFlagBits)(sample_location_counts & -sample_location_counts);
   for (int i = 0; i < 64; i++)
      pts[i] = (VkSampleLocationEXT){ 0.5f, 0.5f };
   return (VkSampleLocationsInfoEXT){ .sType = VK_STRUCTURE_TYPE_SAMPLE_LOCATIONS_INFO_EXT,
                                      .sampleLocationsPerPixel = per_pixel, .sampleLocationGridSize = { 1, 1 },
                                      .sampleLocationsCount = per_pixel, .pSampleLocations = pts };
}

static void setup_device(unsigned needs)
{
   VkPhysicalDevice host = pdev->base.handle.physical_device;
   /* features the driver has, read on the host directly (setup only) */
   VkPhysicalDeviceRobustness2FeaturesEXT r2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
   VkPhysicalDeviceExtendedDynamicState3FeaturesEXT eds3 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT };
   VkPhysicalDeviceExtendedDynamicState2FeaturesEXT eds2 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT };
   VkPhysicalDeviceMultiDrawFeaturesEXT md = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTI_DRAW_FEATURES_EXT };
   VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR lr = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR };
   VkPhysicalDeviceMaintenance5FeaturesKHR m5 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR };
   VkPhysicalDeviceMaintenance6FeaturesKHR m6 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES_KHR };
   VkPhysicalDevicePipelineRobustnessFeaturesEXT pr = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PIPELINE_ROBUSTNESS_FEATURES_EXT };
   VkPhysicalDeviceNestedCommandBufferFeaturesEXT nested = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_NESTED_COMMAND_BUFFER_FEATURES_EXT };
   VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
   VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &f13 };
   VkPhysicalDeviceVulkan11Features f11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &f12 };
   VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f11 };
   void **tail = &f13.pNext;
#define QUERY(ext, s)                                                                     \
   if (lists(ext)) {                                                                      \
      *tail = &(s);                                                                       \
      tail = &(s).pNext;                                                                  \
   }
   QUERY(VK_EXT_ROBUSTNESS_2_EXTENSION_NAME, r2);
   QUERY(VK_EXT_EXTENDED_DYNAMIC_STATE_3_EXTENSION_NAME, eds3);
   QUERY(VK_EXT_EXTENDED_DYNAMIC_STATE_2_EXTENSION_NAME, eds2);
   QUERY(VK_EXT_MULTI_DRAW_EXTENSION_NAME, md);
   QUERY(VK_KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME, lr);
   QUERY(VK_KHR_MAINTENANCE_5_EXTENSION_NAME, m5);
   QUERY(VK_KHR_MAINTENANCE_6_EXTENSION_NAME, m6);
   QUERY(VK_EXT_PIPELINE_ROBUSTNESS_EXTENSION_NAME, pr);
   QUERY(VK_EXT_NESTED_COMMAND_BUFFER_EXTENSION_NAME, nested);
#undef QUERY
   pdev->proc_table.GetPhysicalDeviceFeatures2(host, &f2);

   const struct {
      unsigned need;
      const char *ext;
      bool feature;
   } table[] = {
      { N_NULLDESC, VK_EXT_ROBUSTNESS_2_EXTENSION_NAME, r2.nullDescriptor },
      { N_NESTED, VK_EXT_NESTED_COMMAND_BUFFER_EXTENSION_NAME, nested.nestedCommandBuffer },
      { N_SAMPLELOC, VK_EXT_SAMPLE_LOCATIONS_EXTENSION_NAME, true },
      { N_LOCALREAD, VK_KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME, lr.dynamicRenderingLocalRead },
      { N_MULTIDRAW, VK_EXT_MULTI_DRAW_EXTENSION_NAME, md.multiDraw },
      { N_PUSHDESC, VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME, true },
      { N_MAINT6, VK_KHR_MAINTENANCE_6_EXTENSION_NAME, m6.maintenance6 },
      { N_MAINT5, VK_KHR_MAINTENANCE_5_EXTENSION_NAME, m5.maintenance5 },
      { N_ROBUST, VK_EXT_PIPELINE_ROBUSTNESS_EXTENSION_NAME, pr.pipelineRobustness },
      { N_LOGICOP, VK_EXT_EXTENDED_DYNAMIC_STATE_2_EXTENSION_NAME, eds2.extendedDynamicState2LogicOp },
      { N_BLENDEN, VK_EXT_EXTENDED_DYNAMIC_STATE_3_EXTENSION_NAME, eds3.extendedDynamicState3ColorBlendEnable },
   };
   const char *exts[16];
   uint32_t n_ext = 0;
   have = 0;
   for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
      if (!(needs & table[i].need))
         continue;
      if (!lists(table[i].ext) || !table[i].feature) {
         if (table[i].need == N_NESTED)
            continue; /* the case runs without it (vkr hides the extension) */
         printf("skip: the device has no %s\n", table[i].ext);
         fflush(stdout);
         _exit(SKIP);
      }
      have |= table[i].need;
      bool dup = false;
      for (uint32_t j = 0; j < n_ext; j++)
         dup |= !strcmp(exts[j], table[i].ext);
      if (!dup)
         exts[n_ext++] = table[i].ext;
   }

   /* enable: Vulkan 1.1-1.3 features the cases use, plus the needed extensions' */
   VkPhysicalDeviceVulkan13Features e13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
                                            .dynamicRendering = f13.dynamicRendering,
                                            .inlineUniformBlock = f13.inlineUniformBlock,
                                            .synchronization2 = f13.synchronization2,
                                            .maintenance4 = f13.maintenance4 };
   VkPhysicalDeviceVulkan12Features e12 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &e13,
      .hostQueryReset = f12.hostQueryReset, .drawIndirectCount = f12.drawIndirectCount,
      .descriptorIndexing = f12.descriptorIndexing,
      .descriptorBindingVariableDescriptorCount = f12.descriptorBindingVariableDescriptorCount,
      .runtimeDescriptorArray = f12.runtimeDescriptorArray,
      .descriptorBindingPartiallyBound = f12.descriptorBindingPartiallyBound,
      .imagelessFramebuffer = f12.imagelessFramebuffer };
   VkPhysicalDeviceVulkan11Features e11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
                                            .pNext = &e12, .multiview = f11.multiview };
   VkPhysicalDeviceFeatures2 e2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &e11 };
   e2.features.robustBufferAccess = f2.features.robustBufferAccess;
   e2.features.independentBlend = f2.features.independentBlend;
   e2.features.multiDrawIndirect = f2.features.multiDrawIndirect;
   e2.features.multiViewport = f2.features.multiViewport;
   e2.features.logicOp = f2.features.logicOp;
   tail = &e13.pNext;
   VkPhysicalDeviceRobustness2FeaturesEXT er2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
                                                  .nullDescriptor = VK_TRUE };
   VkPhysicalDeviceNestedCommandBufferFeaturesEXT enested = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_NESTED_COMMAND_BUFFER_FEATURES_EXT, .nestedCommandBuffer = VK_TRUE };
   VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR elr = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR,
      .dynamicRenderingLocalRead = VK_TRUE };
   VkPhysicalDeviceMultiDrawFeaturesEXT emd = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MULTI_DRAW_FEATURES_EXT,
                                                .multiDraw = VK_TRUE };
   VkPhysicalDeviceMaintenance5FeaturesKHR em5 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR,
                                                   .maintenance5 = VK_TRUE };
   VkPhysicalDeviceMaintenance6FeaturesKHR em6 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES_KHR,
                                                   .maintenance6 = VK_TRUE };
   VkPhysicalDevicePipelineRobustnessFeaturesEXT epr = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PIPELINE_ROBUSTNESS_FEATURES_EXT, .pipelineRobustness = VK_TRUE };
   VkPhysicalDeviceExtendedDynamicState2FeaturesEXT eeds2 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_2_FEATURES_EXT,
      .extendedDynamicState2LogicOp = VK_TRUE };
   VkPhysicalDeviceExtendedDynamicState3FeaturesEXT eeds3 = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_3_FEATURES_EXT,
      .extendedDynamicState3ColorBlendEnable = VK_TRUE };
#define ENABLE(n, s)                                                                      \
   if (have & (n)) {                                                                      \
      *tail = &(s);                                                                       \
      tail = &(s).pNext;                                                                  \
   }
   ENABLE(N_NULLDESC, er2);
   ENABLE(N_NESTED, enested);
   ENABLE(N_LOCALREAD, elr);
   ENABLE(N_MULTIDRAW, emd);
   ENABLE(N_MAINT5, em5);
   ENABLE(N_MAINT6, em6);
   ENABLE(N_ROBUST, epr);
   ENABLE(N_LOGICOP, eeds2);
   ENABLE(N_BLENDEN, eeds3);
#undef ENABLE
   const float priority = 1;
   const VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
                                       .pQueuePriorities = &priority };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &e2,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
                              .enabledExtensionCount = n_ext, .ppEnabledExtensionNames = exts };
   VkDevice device_id = (VkDevice)(uintptr_t)3;
   struct vn_command_vkCreateDevice cd = { .physicalDevice = (VkPhysicalDevice)pdev, .pCreateInfo = &dci,
                                           .pDevice = &device_id };
   D->dispatch_vkCreateDevice(D, &cd);
   dev = object(3);
   if (cd.ret != VK_SUCCESS || !dev)
      broken("vkCreateDevice");
   printf("driver: %s on %s, api %u.%u; maxMultiviewViewCount told %u, maxViewports %u, "
          "maxColorAttachments %u, maxPushConstantsSize %u, maxBoundDescriptorSets %u, "
          "maxVertexInputBindings %u, maxVertexInputAttributes %u\n",
          kosmickrisp ? "KosmicKrisp" : "MoltenVK", props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
          VK_API_VERSION_MINOR(props.apiVersion), max_views, lim.maxViewports, lim.maxColorAttachments,
          lim.maxPushConstantsSize, lim.maxBoundDescriptorSets, lim.maxVertexInputBindings,
          lim.maxVertexInputAttributes);
}

static void setup(unsigned needs)
{
   instance_and_physical_device();
   setup_device(needs);
}

/* ---- objects through vkr's dispatch (fresh structs per call: vkr replaces the handles
 * in what it is handed with the driver's) ---- */
static uint32_t memory_type(uint32_t bits)
{
   const VkPhysicalDeviceMemoryProperties *mp = &pdev->memory_properties;
   for (uint32_t i = 0; i < mp->memoryTypeCount; i++)
      if ((bits & (1u << i)) && (mp->memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
         return i;
   for (uint32_t i = 0; i < mp->memoryTypeCount; i++)
      if (bits & (1u << i))
         return i;
   return 0;
}

static struct vkr_device_memory *allocate(VkDeviceSize size, uint32_t type)
{
   const uint64_t id = next_id++;
   VkDeviceMemory h = (VkDeviceMemory)(uintptr_t)id;
   VkMemoryAllocateInfo info = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = size,
                                 .memoryTypeIndex = type };
   struct vn_command_vkAllocateMemory a = { .device = DEVH, .pAllocateInfo = &info, .pMemory = &h };
   D->dispatch_vkAllocateMemory(D, &a);
   if (a.ret != VK_SUCCESS)
      broken("vkAllocateMemory");
   return object(id);
}

static struct vkr_buffer *buffer(VkDeviceSize size)
{
   const uint64_t id = next_id++;
   VkBuffer h = (VkBuffer)(uintptr_t)id;
   VkBufferCreateInfo info = {
      .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
      .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
               VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT |
               VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
               VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT };
   struct vn_command_vkCreateBuffer c = { .device = DEVH, .pCreateInfo = &info, .pBuffer = &h };
   D->dispatch_vkCreateBuffer(D, &c);
   struct vkr_buffer *buf = object(id);
   if (c.ret != VK_SUCCESS || !buf)
      broken("vkCreateBuffer");
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetBufferMemoryRequirements r = { .device = DEVH, .buffer = (VkBuffer)buf,
                                                        .pMemoryRequirements = &req };
   D->dispatch_vkGetBufferMemoryRequirements(D, &r);
   struct vkr_device_memory *mem = allocate(req.size, memory_type(req.memoryTypeBits));
   struct vn_command_vkBindBufferMemory b = { .device = DEVH, .buffer = (VkBuffer)buf,
                                              .memory = (VkDeviceMemory)mem };
   D->dispatch_vkBindBufferMemory(D, &b);
   if (b.ret != VK_SUCCESS)
      broken("vkBindBufferMemory");
   return buf;
}

static struct vkr_image *image(uint32_t w, uint32_t h, uint32_t layers, VkImageUsageFlags usage)
{
   const uint64_t id = next_id++;
   VkImage hd = (VkImage)(uintptr_t)id;
   VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                              .format = FMT, .extent = { w, h, 1 }, .mipLevels = 1, .arrayLayers = layers,
                              .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                              .usage = usage };
   struct vn_command_vkCreateImage c = { .device = DEVH, .pCreateInfo = &info, .pImage = &hd };
   D->dispatch_vkCreateImage(D, &c);
   struct vkr_image *img = object(id);
   if (c.ret != VK_SUCCESS || !img)
      broken("vkCreateImage");
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetImageMemoryRequirements r = { .device = DEVH, .image = (VkImage)img,
                                                       .pMemoryRequirements = &req };
   D->dispatch_vkGetImageMemoryRequirements(D, &r);
   struct vkr_device_memory *mem = allocate(req.size, memory_type(req.memoryTypeBits));
   struct vn_command_vkBindImageMemory b = { .device = DEVH, .image = (VkImage)img,
                                             .memory = (VkDeviceMemory)mem };
   D->dispatch_vkBindImageMemory(D, &b);
   if (b.ret != VK_SUCCESS)
      broken("vkBindImageMemory");
   return img;
}

#define CA_SA (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | \
               VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT)

static void *view(struct vkr_image *img, uint32_t layers)
{
   const uint64_t id = next_id++;
   VkImageView h = (VkImageView)(uintptr_t)id;
   VkImageViewCreateInfo info = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = (VkImage)img,
      .viewType = layers > 1 ? VK_IMAGE_VIEW_TYPE_2D_ARRAY : VK_IMAGE_VIEW_TYPE_2D, .format = FMT,
      .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, layers } };
   struct vn_command_vkCreateImageView c = { .device = DEVH, .pCreateInfo = &info, .pView = &h };
   D->dispatch_vkCreateImageView(D, &c);
   if (c.ret != VK_SUCCESS || !object(id))
      broken("vkCreateImageView");
   return object(id);
}

static void *sampler(void)
{
   const uint64_t id = next_id++;
   VkSampler h = (VkSampler)(uintptr_t)id;
   VkSamplerCreateInfo info = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = VK_FILTER_LINEAR,
                                .minFilter = VK_FILTER_LINEAR, .maxLod = 1 };
   struct vn_command_vkCreateSampler c = { .device = DEVH, .pCreateInfo = &info, .pSampler = &h };
   D->dispatch_vkCreateSampler(D, &c);
   if (c.ret != VK_SUCCESS || !object(id))
      broken("vkCreateSampler");
   return object(id);
}

/* a shader module from words (codeSize in bytes); NULL with last_ret on an error */
static void *shader(const uint32_t *code, size_t bytes)
{
   const uint64_t id = next_id++;
   VkShaderModule h = (VkShaderModule)(uintptr_t)id;
   VkShaderModuleCreateInfo info = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = bytes,
                                     .pCode = code };
   struct vn_command_vkCreateShaderModule c = { .device = DEVH, .pCreateInfo = &info, .pShaderModule = &h };
   D->dispatch_vkCreateShaderModule(D, &c);
   last_ret = c.ret;
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

/* a set layout from bindings (fresh copies: vkr replaces immutable sampler handles) */
static void *set_layout_of(const VkDescriptorSetLayoutBinding *b, uint32_t n, VkDescriptorSetLayoutCreateFlags flags,
                           const void *next)
{
   const uint64_t id = next_id++;
   VkDescriptorSetLayout h = (VkDescriptorSetLayout)(uintptr_t)id;
   VkDescriptorSetLayoutCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                            .pNext = next, .flags = flags, .bindingCount = n, .pBindings = b };
   struct vn_command_vkCreateDescriptorSetLayout c = { .device = DEVH, .pCreateInfo = &info, .pSetLayout = &h };
   step("vkCreateDescriptorSetLayout %u bindings, flags 0x%x", n, flags);
   D->dispatch_vkCreateDescriptorSetLayout(D, &c);
   last_ret = c.ret;
   step("vkCreateDescriptorSetLayout = %d", c.ret);
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

/* the world's set layout: 0 UBO, 1 combined image sampler, 2 storage buffer, 3 dynamic
 * storage buffer, 4 storage image, 5 inline uniform block (64 bytes) */
static void *set_layout(void)
{
   VkDescriptorSetLayoutBinding b[6] = {
      { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL },
      { 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_ALL, NULL },
      { 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL },
      { 3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_ALL, NULL },
      { 4, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1, VK_SHADER_STAGE_ALL, NULL },
      { 5, VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK, 64, VK_SHADER_STAGE_ALL, NULL },
   };
   void *l = set_layout_of(b, max_inline_block ? 6 : 5, 0, NULL);
   if (!l)
      broken("vkCreateDescriptorSetLayout");
   return l;
}

static void *pipeline_layout_of(void *const *dsls, uint32_t n, const VkPushConstantRange *ranges, uint32_t nr)
{
   VkDescriptorSetLayout sets[64];
   for (uint32_t i = 0; i < n && i < 64; i++)
      sets[i] = (VkDescriptorSetLayout)dsls[i];
   const uint64_t id = next_id++;
   VkPipelineLayout h = (VkPipelineLayout)(uintptr_t)id;
   VkPipelineLayoutCreateInfo info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                                       .setLayoutCount = n, .pSetLayouts = sets,
                                       .pushConstantRangeCount = nr, .pPushConstantRanges = ranges };
   struct vn_command_vkCreatePipelineLayout c = { .device = DEVH, .pCreateInfo = &info, .pPipelineLayout = &h };
   step("vkCreatePipelineLayout %u sets, %u push ranges", n, nr);
   D->dispatch_vkCreatePipelineLayout(D, &c);
   last_ret = c.ret;
   step("vkCreatePipelineLayout = %d", c.ret);
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

static void *pipeline_layout(void *dsl)
{
   const VkPushConstantRange push = { VK_SHADER_STAGE_ALL, 0, 128 };
   void *l = pipeline_layout_of(&dsl, 1, &push, 1);
   if (!l)
      broken("vkCreatePipelineLayout");
   return l;
}

/* a pool for every type the cases use, with room for 8 sets */
static void *pool(void)
{
   VkDescriptorPoolSize sizes[6] = {
      { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 64 }, { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 64 },
      { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 64 }, { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 64 },
      { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 64 }, { VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK, 1 << 17 } };
   VkDescriptorPoolInlineUniformBlockCreateInfo inl = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_INLINE_UNIFORM_BLOCK_CREATE_INFO, .maxInlineUniformBlockBindings = 8 };
   const uint64_t id = next_id++;
   VkDescriptorPool h = (VkDescriptorPool)(uintptr_t)id;
   VkDescriptorPoolCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                       .pNext = max_inline_block ? &inl : NULL,
                                       .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT, .maxSets = 64,
                                       .poolSizeCount = max_inline_block ? 6 : 5, .pPoolSizes = sizes };
   struct vn_command_vkCreateDescriptorPool c = { .device = DEVH, .pCreateInfo = &info, .pDescriptorPool = &h };
   D->dispatch_vkCreateDescriptorPool(D, &c);
   if (c.ret != VK_SUCCESS || !object(id))
      broken("vkCreateDescriptorPool");
   return object(id);
}

/* a set of layout dsl from pool p (next: the allocate info's pNext) */
static void *set_from(void *p, void *dsl, const void *next)
{
   const uint64_t id = next_id++;
   VkDescriptorSet h = (VkDescriptorSet)(uintptr_t)id;
   VkDescriptorSetLayout layouts[1] = { (VkDescriptorSetLayout)dsl };
   VkDescriptorSetAllocateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .pNext = next,
                                        .descriptorPool = (VkDescriptorPool)p, .descriptorSetCount = 1,
                                        .pSetLayouts = layouts };
   struct vn_command_vkAllocateDescriptorSets a = { .device = DEVH, .pAllocateInfo = &info, .pDescriptorSets = &h };
   step("vkAllocateDescriptorSets");
   D->dispatch_vkAllocateDescriptorSets(D, &a);
   last_ret = a.ret;
   step("vkAllocateDescriptorSets = %d", a.ret);
   return a.ret == VK_SUCCESS ? object(id) : NULL;
}

/* render pass: n color attachments (refs to attachment ref_base + i), one subpass, view_mask */
static void *render_pass(uint32_t n_att, uint32_t n_refs, uint32_t ref_base, uint32_t view_mask)
{
   VkAttachmentDescription att[16];
   VkAttachmentReference refs[16];
   for (uint32_t i = 0; i < 16; i++) {
      att[i] = (VkAttachmentDescription){ 0, FMT, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
                                          VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                          VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED,
                                          VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
      refs[i] = (VkAttachmentReference){ ref_base + i, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
   }
   VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                .colorAttachmentCount = n_refs, .pColorAttachments = refs };
   VkRenderPassMultiviewCreateInfo mv = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                                          .subpassCount = 1, .pViewMasks = &view_mask };
   const uint64_t id = next_id++;
   VkRenderPass h = (VkRenderPass)(uintptr_t)id;
   VkRenderPassCreateInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                                   .pNext = view_mask ? &mv : NULL, .attachmentCount = n_att, .pAttachments = att,
                                   .subpassCount = 1, .pSubpasses = &sub };
   struct vn_command_vkCreateRenderPass c = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
   step("vkCreateRenderPass %u attachments, %u refs from %u, view mask 0x%x", n_att, n_refs, ref_base, view_mask);
   D->dispatch_vkCreateRenderPass(D, &c);
   last_ret = c.ret;
   step("vkCreateRenderPass = %d", c.ret);
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

static void *framebuffer(void *rp, void **views, uint32_t n, uint32_t w, uint32_t h, uint32_t layers)
{
   VkImageView v[16];
   for (uint32_t i = 0; i < n; i++)
      v[i] = (VkImageView)views[i];
   const uint64_t id = next_id++;
   VkFramebuffer hd = (VkFramebuffer)(uintptr_t)id;
   VkFramebufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                    .renderPass = (VkRenderPass)rp, .attachmentCount = n,
                                    .pAttachments = n ? v : NULL, .width = w, .height = h, .layers = layers };
   struct vn_command_vkCreateFramebuffer c = { .device = DEVH, .pCreateInfo = &info, .pFramebuffer = &hd };
   step("vkCreateFramebuffer %u attachments %ux%ux%u", n, w, h, layers);
   D->dispatch_vkCreateFramebuffer(D, &c);
   last_ret = c.ret;
   step("vkCreateFramebuffer = %d", c.ret);
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

/* graphics pipeline knobs */
struct gfx {
   void *rp; /* render pass, or NULL for dynamic rendering */
   uint32_t subpass;
   uint32_t colors; /* color attachments (blend state and rendering info) */
   uint32_t blend_count;
   uint32_t viewports;
   uint32_t vbinding, vlocation, vstride;
   VkSampleCountFlagBits samples;
   void *vert, *frag;
   const void *next;    /* chained after the rendering info */
   const void *ms_next; /* chained on the multisample state */
   const VkDynamicState *dynamic;
   uint32_t dynamic_count;
   VkShaderStageFlagBits vert_stage;
   VkBlendFactor src_factor;
   VkCompareOp depth_compare;
   VkCullModeFlags cull;
   const VkSpecializationInfo *spec;
   uint32_t feedback_count; /* chain a creation feedback with this many stage entries */
   bool feedback;
};

static void *graphics_pipeline(void *layout, const struct gfx *g)
{
   VkPipelineShaderStageCreateInfo st[2] = {
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = g->vert_stage ? g->vert_stage : VK_SHADER_STAGE_VERTEX_BIT, .module = (VkShaderModule)g->vert,
        .pName = "main", .pSpecializationInfo = g->spec },
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = (VkShaderModule)g->frag, .pName = "main" } };
   VkVertexInputBindingDescription vb = { g->vbinding, g->vstride ? g->vstride : 16, VK_VERTEX_INPUT_RATE_VERTEX };
   VkVertexInputAttributeDescription va = { g->vlocation, g->vbinding, VK_FORMAT_R32G32B32A32_SFLOAT, 0 };
   VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
                                               .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &vb,
                                               .vertexAttributeDescriptionCount = 1,
                                               .pVertexAttributeDescriptions = &va };
   VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                 .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
   static VkViewport vps[64];
   static VkRect2D scs[64];
   for (int i = 0; i < 64; i++) {
      vps[i] = (VkViewport){ 0, 0, 64, 64, 0, 1 };
      scs[i] = (VkRect2D){ { 0, 0 }, { 64, 64 } };
   }
   VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                                            .viewportCount = g->viewports ? g->viewports : 1, .pViewports = vps,
                                            .scissorCount = g->viewports ? g->viewports : 1, .pScissors = scs };
   VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                                                 .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = g->cull,
                                                 .lineWidth = 1 };
   VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                               .pNext = g->ms_next, .rasterizationSamples = g->samples ? g->samples : VK_SAMPLE_COUNT_1_BIT };
   VkPipelineDepthStencilStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
                                                .depthCompareOp = g->depth_compare };
   static VkPipelineColorBlendAttachmentState cba[64];
   for (int i = 0; i < 64; i++)
      cba[i] = (VkPipelineColorBlendAttachmentState){ .blendEnable = g->src_factor != 0, .colorWriteMask = 0xf,
                                                      .srcColorBlendFactor = g->src_factor };
   VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                              .attachmentCount = g->blend_count ? g->blend_count : g->colors,
                                              .pAttachments = cba };
   static VkFormat formats[64];
   for (int i = 0; i < 64; i++)
      formats[i] = FMT;
   VkPipelineRenderingCreateInfo ri = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .pNext = g->next,
                                        .colorAttachmentCount = g->colors, .pColorAttachmentFormats = formats };
   VkPipelineDynamicStateCreateInfo dyn = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                                            .dynamicStateCount = g->dynamic_count, .pDynamicStates = g->dynamic };
   VkPipelineCreationFeedback whole = { 0 }, stages[2] = { { 0 } };
   VkPipelineCreationFeedbackCreateInfo fb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO,
                                               .pNext = g->rp ? g->next : &ri, .pPipelineCreationFeedback = &whole,
                                               .pipelineStageCreationFeedbackCount = g->feedback_count,
                                               .pPipelineStageCreationFeedbacks = stages };
   const uint64_t id = next_id++;
   VkPipeline h = (VkPipeline)(uintptr_t)id;
   VkGraphicsPipelineCreateInfo info = {
      .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .pNext = g->feedback ? (const void *)&fb : g->rp ? g->next : (const void *)&ri, .stageCount = 2,
      .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia, .pViewportState = &vp,
      .pRasterizationState = &rs, .pMultisampleState = &ms, .pDepthStencilState = &ds, .pColorBlendState = &cb,
      .pDynamicState = g->dynamic_count ? &dyn : NULL, .layout = (VkPipelineLayout)layout,
      .renderPass = (VkRenderPass)g->rp, .subpass = g->subpass };
   struct vn_command_vkCreateGraphicsPipelines c = { .device = DEVH, .createInfoCount = 1, .pCreateInfos = &info,
                                                     .pPipelines = &h };
   step("vkCreateGraphicsPipelines colors %u blend %u viewports %u vbinding %u vlocation %u stride %u samples %u "
        "subpass %u", g->colors, cb.attachmentCount, vp.viewportCount, g->vbinding, g->vlocation, vb.stride,
        ms.rasterizationSamples, g->subpass);
   D->dispatch_vkCreateGraphicsPipelines(D, &c);
   last_ret = c.ret;
   step("vkCreateGraphicsPipelines = %d", c.ret);
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

static uint32_t spec_local_size = 64;
static const VkSpecializationMapEntry spec_entry = { 0, 0, 4 };
static const VkSpecializationInfo spec_ok = { 1, &spec_entry, 4, &spec_local_size };

/* a compute pipeline: module or (module NULL) the code chained into the stage */
static void *compute_pipeline(void *layout, void *module, const VkShaderModuleCreateInfo *inline_code,
                              VkShaderStageFlagBits stage, const VkSpecializationInfo *spec, const void *next)
{
   const uint64_t id = next_id++;
   VkPipeline h = (VkPipeline)(uintptr_t)id;
   VkComputePipelineCreateInfo info = {
      .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .pNext = next,
      .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = inline_code,
                 .stage = stage, .module = (VkShaderModule)module, .pName = "main", .pSpecializationInfo = spec },
      .layout = (VkPipelineLayout)layout };
   struct vn_command_vkCreateComputePipelines c = { .device = DEVH, .createInfoCount = 1, .pCreateInfos = &info,
                                                    .pPipelines = &h };
   step("vkCreateComputePipelines stage 0x%x module %s", stage, module ? "set" : "NULL");
   D->dispatch_vkCreateComputePipelines(D, &c);
   last_ret = c.ret;
   step("vkCreateComputePipelines = %d", c.ret);
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

static void *command_buffer_level(VkCommandBufferLevel level)
{
   const uint64_t pid = next_id++, cid = next_id++;
   VkCommandPool ph = (VkCommandPool)(uintptr_t)pid;
   VkCommandPoolCreateInfo pinfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
   struct vn_command_vkCreateCommandPool cp = { .device = DEVH, .pCreateInfo = &pinfo, .pCommandPool = &ph };
   D->dispatch_vkCreateCommandPool(D, &cp);
   if (cp.ret != VK_SUCCESS || !object(pid))
      broken("vkCreateCommandPool");
   VkCommandBuffer ch = (VkCommandBuffer)(uintptr_t)cid;
   VkCommandBufferAllocateInfo ainfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                         .commandPool = (VkCommandPool)object(pid), .level = level,
                                         .commandBufferCount = 1 };
   struct vn_command_vkAllocateCommandBuffers a = { .device = DEVH, .pAllocateInfo = &ainfo, .pCommandBuffers = &ch };
   D->dispatch_vkAllocateCommandBuffers(D, &a);
   if (a.ret != VK_SUCCESS || !object(cid))
      broken("vkAllocateCommandBuffers");
   return object(cid);
}

static void *command_buffer(void)
{
   return command_buffer_level(VK_COMMAND_BUFFER_LEVEL_PRIMARY);
}

static void begin(void *cmd)
{
   VkCommandBufferBeginInfo info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                     .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
   struct vn_command_vkBeginCommandBuffer b = { .commandBuffer = (VkCommandBuffer)cmd, .pBeginInfo = &info };
   D->dispatch_vkBeginCommandBuffer(D, &b);
   if (b.ret != VK_SUCCESS)
      broken("vkBeginCommandBuffer");
}

/* a secondary begun outside any pass; next: the inheritance info's pNext */
static int begin_secondary(void *cmd, const void *next)
{
   VkCommandBufferInheritanceInfo inh = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO, .pNext = next };
   VkCommandBufferBeginInfo info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                     .flags = next ? VK_COMMAND_BUFFER_USAGE_RENDER_PASS_CONTINUE_BIT : 0,
                                     .pInheritanceInfo = &inh };
   struct vn_command_vkBeginCommandBuffer b = { .commandBuffer = (VkCommandBuffer)cmd, .pBeginInfo = &info };
   step("vkBeginCommandBuffer (secondary)");
   D->dispatch_vkBeginCommandBuffer(D, &b);
   step("vkBeginCommandBuffer = %d", b.ret);
   return b.ret;
}

/* whether vkr ended the context */
static bool ended(void)
{
   return vkr_context_get_fatal(ctx);
}

/* the end of a recording case: vkEndCommandBuffer's result (MoltenVK with prefill encodes
 * here); nothing is submitted. A refused command ends the context: the decoder stops
 * there, so the case stops too. */
static int end(void *cmd)
{
   if (ended())
      return FATAL;
   step("vkEndCommandBuffer");
   struct vn_command_vkEndCommandBuffer e = { .commandBuffer = (VkCommandBuffer)cmd };
   D->dispatch_vkEndCommandBuffer(D, &e);
   step("vkEndCommandBuffer = %d", e.ret);
   if (ended())
      return FATAL;
   return e.ret == VK_SUCCESS ? WORKS : ERROR;
}

static void begin_pass_clear(void *cmd, void *rp, void *fb, uint32_t w, uint32_t h, uint32_t clear_count)
{
   VkClearValue clear[16] = { 0 };
   VkRenderPassBeginInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                  .renderPass = (VkRenderPass)rp, .framebuffer = (VkFramebuffer)fb,
                                  .renderArea = { { 0, 0 }, { w, h } }, .clearValueCount = clear_count,
                                  .pClearValues = clear_count ? clear : NULL };
   struct vn_command_vkCmdBeginRenderPass c = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderPassBegin = &info,
                                                .contents = VK_SUBPASS_CONTENTS_INLINE };
   step("vkCmdBeginRenderPass area %ux%u, %u clear values", w, h, clear_count);
   D->dispatch_vkCmdBeginRenderPass(D, &c);
   step("vkCmdBeginRenderPass done");
}

static void begin_pass(void *cmd, void *rp, void *fb, uint32_t w, uint32_t h)
{
   begin_pass_clear(cmd, rp, fb, w, h, 16);
}

static void end_pass(void *cmd)
{
   if (ended())
      return;
   struct vn_command_vkCmdEndRenderPass c = { .commandBuffer = (VkCommandBuffer)cmd };
   step("vkCmdEndRenderPass");
   D->dispatch_vkCmdEndRenderPass(D, &c);
}

static void bind_pipeline(void *cmd, VkPipelineBindPoint point, void *pipe)
{
   struct vn_command_vkCmdBindPipeline c = { .commandBuffer = (VkCommandBuffer)cmd, .pipelineBindPoint = point,
                                             .pipeline = (VkPipeline)pipe };
   step("vkCmdBindPipeline point %d", point);
   D->dispatch_vkCmdBindPipeline(D, &c);
}

static void *query_pool_of(VkQueryType type, uint32_t count)
{
   const uint64_t id = next_id++;
   VkQueryPool h = (VkQueryPool)(uintptr_t)id;
   VkQueryPoolCreateInfo info = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = type,
                                  .queryCount = count };
   struct vn_command_vkCreateQueryPool c = { .device = DEVH, .pCreateInfo = &info, .pQueryPool = &h };
   step("vkCreateQueryPool type %d count %u", type, count);
   D->dispatch_vkCreateQueryPool(D, &c);
   last_ret = c.ret;
   step("vkCreateQueryPool = %d", c.ret);
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

static void *query_pool(VkQueryType type, uint32_t count)
{
   void *p = query_pool_of(type, count);
   if (!p)
      broken("vkCreateQueryPool");
   return p;
}

/* memory with a guard page right after `bytes`: an access past it faults */
static void *guarded(size_t bytes)
{
   const size_t page = (size_t)getpagesize();
   const size_t pages = (bytes + page - 1) / page;
   uint8_t *p = mmap(NULL, (pages + 1) * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
   if (p == MAP_FAILED)
      broken("mmap");
   mprotect(p + pages * page, page, PROT_NONE);
   return p + pages * page - bytes;
}

/* the shared world of the cases */
struct world {
   void *dsl, *layout, *pool, *set, *rp, *fb, *cmd, *gfx_pipe, *comp_pipe, *vert, *frag, *comp;
   struct vkr_buffer *buf, *buf2;
   struct vkr_image *img, *img2;
   void *iv, *smp;
};

static void make_world(struct world *w, bool pipelines)
{
   w->buf = buffer(65536);
   w->buf2 = buffer(65536);
   w->img = image(64, 64, 1, CA_SA);
   w->img2 = image(64, 64, 1, CA_SA);
   w->iv = view(w->img, 1);
   w->smp = sampler();
   w->dsl = set_layout();
   w->layout = pipeline_layout(w->dsl);
   w->pool = pool();
   w->set = set_from(w->pool, w->dsl, NULL);
   if (!w->set)
      broken("vkAllocateDescriptorSets");
   w->rp = render_pass(1, 1, 0, 0);
   if (!w->rp)
      broken("render pass");
   void *views[1] = { w->iv };
   w->fb = framebuffer(w->rp, views, 1, 64, 64, 1);
   if (!w->fb)
      broken("framebuffer");
   w->cmd = command_buffer();
   if (pipelines) {
      w->vert = shader(spv_vert, sizeof(spv_vert));
      w->frag = shader(spv_frag, sizeof(spv_frag));
      w->comp = shader(spv_comp, sizeof(spv_comp));
      if (!w->vert || !w->frag || !w->comp)
         broken("shader modules");
      const struct gfx g = { .rp = w->rp, .colors = 1, .vert = w->vert, .frag = w->frag };
      w->gfx_pipe = graphics_pipeline(w->layout, &g);
      w->comp_pipe = compute_pipeline(w->layout, w->comp, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL);
      if (!w->gfx_pipe || !w->comp_pipe)
         broken("pipelines");
   }
   step("world ready");
}

static int created(void *obj)
{
   if (ended())
      return FATAL;
   if (!obj) {
      printf("error %d\n", last_ret);
      return ERROR;
   }
   return WORKS;
}

/* the child's own expectation, from the device's limits (E_CHILD cases) */
static void expect(bool refuse)
{
   printf("expect: %s\n", refuse ? "refuse" : "works");
}

#define IS(n) (!strcmp(c, (n)))

/* ---------------- pipelines, pipeline layouts, shader stages ---------------- */

/* a pipeline cache from data: garbage, or a valid header for this device + garbage */
static int cache_case(bool with_header)
{
   static uint8_t data[4096];
   for (size_t i = 0; i < sizeof(data); i++)
      data[i] = (uint8_t)(i * 131 + 7);
   if (with_header) {
      const uint32_t hdr[4] = { 32, VK_PIPELINE_CACHE_HEADER_VERSION_ONE, props.vendorID, props.deviceID };
      memcpy(data, hdr, sizeof(hdr));
      memcpy(data + 16, props.pipelineCacheUUID, VK_UUID_SIZE);
   }
   const uint64_t id = next_id++;
   VkPipelineCache h = (VkPipelineCache)(uintptr_t)id;
   VkPipelineCacheCreateInfo info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
                                      .initialDataSize = sizeof(data), .pInitialData = data };
   struct vn_command_vkCreatePipelineCache cc = { .device = DEVH, .pCreateInfo = &info, .pPipelineCache = &h };
   step("vkCreatePipelineCache %zu bytes, header %s", sizeof(data), with_header ? "valid" : "garbage");
   D->dispatch_vkCreatePipelineCache(D, &cc);
   last_ret = cc.ret;
   return created(cc.ret == VK_SUCCESS ? object(id) : NULL);
}

/* n set layouts of one binding each of type t with count descriptors */
static void *one_binding_layout(VkDescriptorType t, uint32_t count, VkShaderStageFlags stages)
{
   const VkDescriptorSetLayoutBinding b = { 0, t, count, stages, NULL };
   return set_layout_of(&b, 1, 0, NULL);
}

static int case_pipeline_layout(const char *c)
{
   if (IS("p-layout-sets-over") || IS("p-layout-sets-max") || IS("p-layout-sets-far")) {
      const uint32_t n = IS("p-layout-sets-max") ? lim.maxBoundDescriptorSets
                         : IS("p-layout-sets-far") ? 64 : lim.maxBoundDescriptorSets + 1;
      void *dsl = one_binding_layout(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL);
      void *sets[64];
      for (uint32_t i = 0; i < n && i < 64; i++)
         sets[i] = dsl;
      return created(pipeline_layout_of(sets, n > 64 ? 64 : n, NULL, 0));
   }
   if (IS("p-layout-push-ranges-far") || IS("p-layout-push-ranges-ok") || IS("p-layout-push-over")) {
      VkPushConstantRange r[32];
      uint32_t n = 0;
      if (IS("p-layout-push-ranges-far")) {
         for (n = 0; n < 32; n++)
            r[n] = (VkPushConstantRange){ VK_SHADER_STAGE_VERTEX_BIT, 0, 4 };
      } else if (IS("p-layout-push-ranges-ok")) {
         r[n++] = (VkPushConstantRange){ VK_SHADER_STAGE_VERTEX_BIT, 0, 16 };
         r[n++] = (VkPushConstantRange){ VK_SHADER_STAGE_FRAGMENT_BIT, 16, lim.maxPushConstantsSize - 16 };
      } else {
         r[n++] = (VkPushConstantRange){ VK_SHADER_STAGE_ALL, 0, lim.maxPushConstantsSize + 4 };
      }
      return created(pipeline_layout_of(NULL, 0, r, n));
   }
   if (IS("p-layout-dynamic-over") || IS("p-layout-dynamic-max")) {
      /* a device whose limits are not small fixed arrays (MoltenVK) is skipped */
      if (dynamic_ubo_max > 4096 || dynamic_ssbo_max > 4096) {
         printf("skip: dynamic buffer limits %u, %u\n", dynamic_ubo_max, dynamic_ssbo_max);
         return SKIP;
      }
      void *ubo = one_binding_layout(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, dynamic_ubo_max, VK_SHADER_STAGE_ALL);
      void *sbo = one_binding_layout(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, dynamic_ssbo_max, VK_SHADER_STAGE_ALL);
      if (!ubo || !sbo)
         return created(NULL);
      void *sets[3] = { ubo, sbo, ubo };
      return created(pipeline_layout_of(sets, IS("p-layout-dynamic-max") ? 2 : 3, NULL, 0));
   }
   return BROKEN;
}

static int case_pipeline(const char *c)
{
   unsigned needs = 0;
   if (IS("p-inline-spirv-odd") || IS("p-inline-spirv-ok") || IS("p-stage-null-module"))
      needs |= N_MAINT5;
   if (IS("p-robustness-bad"))
      needs |= N_ROBUST;
   if (IS("p-gfx-att-locations-far"))
      needs |= N_LOCALREAD;
   if (IS("p-gfx-sample-locations-far"))
      needs |= N_SAMPLELOC;
   setup(needs);
   if (IS("p-cache-garbage") || IS("p-cache-header"))
      return cache_case(IS("p-cache-header"));
   if (!strncmp(c, "p-layout-", 9))
      return case_pipeline_layout(c);
   struct world w = { 0 };
   make_world(&w, IS("p-ok") || IS("p-gfx-ok"));
   if (IS("p-ok") || IS("p-gfx-ok"))
      return WORKS;

   /* compute */
   if (!strncmp(c, "p-spec", 6) || !strncmp(c, "p-inline", 8) || !strncmp(c, "p-stage", 7) ||
       IS("p-compute-stage-wrong") || IS("p-robustness-bad") || IS("p-compute-feedback-far")) {
      void *mod = shader(spv_comp, sizeof(spv_comp));
      if (!mod)
         broken("compute module");
      static VkSpecializationMapEntry far_entry = { 0, 4096, 4 };
      static VkSpecializationInfo spec_far = { 1, &far_entry, 4, &spec_local_size };
      static VkSpecializationMapEntry wrap_entry = { 0, 0xfffffffcu, 8 };
      static VkSpecializationInfo spec_wrap = { 1, &wrap_entry, 4, &spec_local_size };
      static uint32_t odd[2];
      memcpy(odd, spv_comp, sizeof(odd));
      VkShaderModuleCreateInfo inl = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                       .codeSize = sizeof(spv_comp), .pCode = spv_comp };
      VkPipelineRobustnessCreateInfoEXT rob = { .sType = VK_STRUCTURE_TYPE_PIPELINE_ROBUSTNESS_CREATE_INFO_EXT,
                                                .storageBuffers = (VkPipelineRobustnessBufferBehaviorEXT)99 };
      VkPipelineCreationFeedback whole, stages[64];
      VkPipelineCreationFeedbackCreateInfo fb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO,
                                                  .pPipelineCreationFeedback = &whole,
                                                  .pipelineStageCreationFeedbackCount = 64,
                                                  .pPipelineStageCreationFeedbacks = stages };
      if (IS("p-spec-oob"))
         return created(compute_pipeline(w.layout, mod, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_far, NULL));
      if (IS("p-spec-wrap"))
         return created(compute_pipeline(w.layout, mod, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_wrap, NULL));
      if (IS("p-stage-null-module"))
         return created(compute_pipeline(w.layout, NULL, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
      if (IS("p-inline-spirv-ok"))
         return created(compute_pipeline(w.layout, NULL, &inl, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
      if (IS("p-inline-spirv-odd")) {
         inl.codeSize = 6;
         inl.pCode = odd;
         return created(compute_pipeline(w.layout, NULL, &inl, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
      }
      if (IS("p-compute-stage-wrong"))
         return created(compute_pipeline(w.layout, mod, NULL, VK_SHADER_STAGE_VERTEX_BIT, &spec_ok, NULL));
      if (IS("p-stage-bits-bad"))
         return created(compute_pipeline(w.layout, mod, NULL,
                                         (VkShaderStageFlagBits)(VK_SHADER_STAGE_COMPUTE_BIT | 0x40000000),
                                         &spec_ok, NULL));
      if (IS("p-robustness-bad"))
         return created(compute_pipeline(w.layout, mod, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, &rob));
      if (IS("p-compute-feedback-far"))
         return created(compute_pipeline(w.layout, mod, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, &fb));
      return BROKEN;
   }

   /* graphics */
   w.vert = shader(spv_vert, sizeof(spv_vert));
   w.frag = shader(spv_frag, sizeof(spv_frag));
   struct gfx g = { .rp = w.rp, .colors = 1, .vert = w.vert, .frag = w.frag };
   static VkDynamicState bad_dynamic[2] = { VK_DYNAMIC_STATE_VIEWPORT, (VkDynamicState)0x7fff0000 };
   static uint32_t locations[1 << 16];
   VkRenderingAttachmentLocationInfoKHR loc = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_LOCATION_INFO_KHR,
                                                .colorAttachmentCount = 1 << 16,
                                                .pColorAttachmentLocations = locations };
   static VkSampleLocationEXT sl_points[4096];
   VkPipelineSampleLocationsStateCreateInfoEXT sl = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_SAMPLE_LOCATIONS_STATE_CREATE_INFO_EXT, .sampleLocationsEnable = VK_TRUE,
      .sampleLocationsInfo = { .sType = VK_STRUCTURE_TYPE_SAMPLE_LOCATIONS_INFO_EXT,
                               .sampleLocationsPerPixel = VK_SAMPLE_COUNT_1_BIT, .sampleLocationGridSize = { 64, 64 },
                               .sampleLocationsCount = 4096, .pSampleLocations = sl_points } };
   if (IS("p-gfx-colors-max") || IS("p-gfx-colors-over") || IS("p-gfx-colors-32")) {
      g.rp = NULL;
      g.colors = IS("p-gfx-colors-max") ? lim.maxColorAttachments
                 : IS("p-gfx-colors-32") ? 32 : lim.maxColorAttachments + 1;
   } else if (IS("p-gfx-viewports-over") || IS("p-gfx-viewports-max") || IS("p-gfx-viewports-32")) {
      g.viewports = IS("p-gfx-viewports-max") ? lim.maxViewports
                    : IS("p-gfx-viewports-32") ? 32 : lim.maxViewports + 1;
   } else if (IS("p-gfx-vbinding-far")) {
      g.vbinding = 40;
      g.vlocation = 0;
   } else if (IS("p-gfx-vlocation-far")) {
      g.vlocation = 40;
   } else if (IS("p-gfx-vbinding-max")) {
      g.vbinding = lim.maxVertexInputBindings - 1;
      g.vlocation = lim.maxVertexInputAttributes - 1;
   } else if (IS("p-gfx-vstride-huge")) {
      g.vstride = 0x7fffffff;
   } else if (IS("p-gfx-samples-64")) {
      g.samples = VK_SAMPLE_COUNT_64_BIT;
   } else if (IS("p-gfx-samples-3")) {
      g.samples = (VkSampleCountFlagBits)3;
   } else if (IS("p-gfx-subpass-oob")) {
      g.subpass = 5;
   } else if (IS("p-gfx-blend-count")) {
      g.blend_count = 3; /* the render pass's subpass has 1 */
   } else if (IS("p-gfx-dynamic-bad")) {
      g.dynamic = bad_dynamic;
      g.dynamic_count = 2;
   } else if (IS("p-gfx-stage-bits-bad")) {
      g.vert_stage = (VkShaderStageFlagBits)0x40000000;
   } else if (IS("p-gfx-blend-factor-bad")) {
      g.src_factor = (VkBlendFactor)999;
   } else if (IS("p-gfx-compare-bad")) {
      g.depth_compare = (VkCompareOp)99;
   } else if (IS("p-gfx-cull-bad")) {
      g.cull = 7;
   } else if (IS("p-gfx-feedback-far") || IS("p-gfx-feedback-ok")) {
      g.feedback = true;
      g.feedback_count = IS("p-gfx-feedback-ok") ? 2 : 3;
   } else if (IS("p-gfx-att-locations-far")) {
      g.rp = NULL;
      g.next = &loc;
   } else if (IS("p-gfx-sample-locations-far")) {
      g.ms_next = &sl;
   } else {
      return BROKEN;
   }
   return created(graphics_pipeline(w.layout, &g));
}

/* ---------------- render passes, framebuffers, dynamic rendering ---------------- */
static int mv_case(uint32_t n, bool all_bits, bool dynamic)
{
   /* N views on an N-layer image (legal up to maxMultiviewViewCount) */
   const uint32_t layers = all_bits ? 1 : n;
   if (layers > lim.maxImageArrayLayers || layers > lim.maxFramebufferLayers) {
      printf("skip: %u layers\n", layers);
      return SKIP;
   }
   const uint32_t mask = n >= 32 ? 0xffffffffu : (1u << n) - 1;
   expect(n > max_views);
   void *v = view(image(64, 64, layers, CA_SA), layers);
   void *cmd = command_buffer();
   if (dynamic) {
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                        .imageView = (VkImageView)v,
                                        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                             .viewMask = mask, .colorAttachmentCount = 1, .pColorAttachments = &att };
      begin(cmd);
      struct vn_command_vkCmdBeginRendering b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderingInfo = &ri };
      step("vkCmdBeginRendering viewMask 0x%x", mask);
      D->dispatch_vkCmdBeginRendering(D, &b);
      if (!ended()) {
         struct vn_command_vkCmdEndRendering e = { .commandBuffer = (VkCommandBuffer)cmd };
         D->dispatch_vkCmdEndRendering(D, &e);
      }
      return end(cmd);
   }
   void *rp = render_pass(1, 1, 0, mask);
   if (!rp)
      return created(rp);
   void *views[1] = { v };
   void *fb = framebuffer(rp, views, 1, 64, 64, 1);
   if (!fb)
      return created(fb);
   begin(cmd);
   begin_pass(cmd, rp, fb, 64, 64);
   end_pass(cmd);
   return end(cmd);
}

static int colors_pass_case(uint32_t n)
{
   void *rp = render_pass(n, n, 0, 0);
   if (!rp)
      return created(rp);
   void *views[16];
   for (uint32_t i = 0; i < n; i++)
      views[i] = view(image(64, 64, 1, CA_SA), 1);
   void *fb = framebuffer(rp, views, n, 64, 64, 1);
   if (!fb)
      return created(fb);
   void *cmd = command_buffer();
   begin(cmd);
   begin_pass(cmd, rp, fb, 64, 64);
   end_pass(cmd);
   return end(cmd);
}

/* a render pass with two subpasses on one color attachment */
static void *two_subpass_pass(const void *next, uint32_t dep_src)
{
   VkAttachmentDescription att = { 0, FMT, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
                                   VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                   VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED,
                                   VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
   VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
   VkSubpassDescription sub[2] = {
      { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ref },
      { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ref } };
   VkSubpassDependency dep = { dep_src, 1, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                               VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                               VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, 0 };
   const uint64_t id = next_id++;
   VkRenderPass h = (VkRenderPass)(uintptr_t)id;
   VkRenderPassCreateInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .pNext = next,
                                   .attachmentCount = 1, .pAttachments = &att, .subpassCount = 2, .pSubpasses = sub,
                                   .dependencyCount = 1, .pDependencies = &dep };
   struct vn_command_vkCreateRenderPass cr = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
   step("vkCreateRenderPass 2 subpasses, dependency from %u", dep_src);
   D->dispatch_vkCreateRenderPass(D, &cr);
   last_ret = cr.ret;
   step("vkCreateRenderPass = %d", cr.ret);
   return cr.ret == VK_SUCCESS ? object(id) : NULL;
}

static int rendering_case(const char *c, struct world *w)
{
   VkRenderingAttachmentInfo att[16];
   const uint32_t n = IS("r-dyn-colors-over") ? lim.maxColorAttachments + 1 : 1;
   for (uint32_t i = 0; i < n && i < 16; i++)
      att[i] = (VkRenderingAttachmentInfo){ .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                            .imageView = (VkImageView)(i ? view(image(64, 64, 1, CA_SA), 1) : w->iv),
                                            .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                                            .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
   VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                          .layerCount = 1, .colorAttachmentCount = n, .pColorAttachments = att };
   if (IS("r-dyn-layers-over"))
      ri.layerCount = lim.maxFramebufferLayers + 1;
   else if (IS("r-dyn-resolve-null"))
      att[0].resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT;
   else if (IS("r-dyn-resolve-mode-bad"))
      att[0].resolveMode = (VkResolveModeFlagBits)0x40;
   else if (!IS("r-dyn-colors-over") && !IS("r-dyn-ok"))
      return BROKEN;
   begin(w->cmd);
   struct vn_command_vkCmdBeginRendering b = { .commandBuffer = (VkCommandBuffer)w->cmd, .pRenderingInfo = &ri };
   step("vkCmdBeginRendering colors %u layers %u resolve 0x%x", n, ri.layerCount, att[0].resolveMode);
   D->dispatch_vkCmdBeginRendering(D, &b);
   if (!ended()) {
      struct vn_command_vkCmdEndRendering e = { .commandBuffer = (VkCommandBuffer)w->cmd };
      step("vkCmdEndRendering");
      D->dispatch_vkCmdEndRendering(D, &e);
   }
   return end(w->cmd);
}

static int case_render_pass(const char *c)
{
   setup(IS("r-sample-loc-index-far") ? N_SAMPLELOC : 0);
   struct world w = { 0 };
   make_world(&w, false);
   if (IS("r-ok")) {
      begin(w.cmd);
      begin_pass(w.cmd, w.rp, w.fb, 64, 64);
      end_pass(w.cmd);
      return end(w.cmd);
   }
   if (IS("r-att-ref-oob"))
      return created(render_pass(1, 1, 5, 0));
   if (IS("r-att-ref-far"))
      return created(render_pass(1, 1, FAR_INDEX, 0));
   if (IS("r-colors-max"))
      return colors_pass_case(lim.maxColorAttachments);
   if (IS("r-colors-over"))
      return colors_pass_case(lim.maxColorAttachments + 1);
   if (IS("r-colors-16"))
      return colors_pass_case(16);
   if (IS("r-fb-fewer")) {
      void *fb = framebuffer(w.rp, NULL, 0, 64, 64, 1);
      if (!fb)
         return created(fb);
      begin(w.cmd);
      begin_pass(w.cmd, w.rp, fb, 64, 64);
      end_pass(w.cmd);
      return end(w.cmd);
   }
   if (IS("r-fb-huge")) {
      void *views[1] = { w.iv };
      return created(framebuffer(w.rp, views, 1, 1u << 30, 64, 1));
   }
   if (IS("r-begin-clear-short")) {
      begin(w.cmd);
      begin_pass_clear(w.cmd, w.rp, w.fb, 64, 64, 0);
      end_pass(w.cmd);
      return end(w.cmd);
   }
   if (IS("r-multiview-3"))
      return mv_case(3, false, false);
   if (IS("r-multiview-all"))
      return mv_case(32, true, false);
   if (IS("r-dyn-viewmask-all"))
      return mv_case(32, true, true);
   if (IS("r-mv-legal-max"))
      return mv_case(max_views, false, false);
   if (IS("r-mv-legal-max-dyn"))
      return mv_case(max_views, false, true);
   if (!strncmp(c, "r-mv-legal-", 11))
      return mv_case((uint32_t)atoi(c + 11), false, false);
   if (IS("r-mv-count-short")) {
      static const uint32_t masks[1] = { 1 };
      VkRenderPassMultiviewCreateInfo mv = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                                             .subpassCount = 1, .pViewMasks = masks };
      return created(two_subpass_pass(&mv, 0));
   }
   if (IS("r-dep-subpass-far"))
      return created(two_subpass_pass(NULL, FAR_INDEX));
   if (IS("r-two-subpasses-ok"))
      return created(two_subpass_pass(NULL, 0));
   if (IS("r-input-aspect-far")) {
      VkInputAttachmentAspectReference ref = { FAR_INDEX, 0, VK_IMAGE_ASPECT_COLOR_BIT };
      VkRenderPassInputAttachmentAspectCreateInfo ia = {
         .sType = VK_STRUCTURE_TYPE_RENDER_PASS_INPUT_ATTACHMENT_ASPECT_CREATE_INFO, .aspectReferenceCount = 1,
         .pAspectReferences = &ref };
      return created(two_subpass_pass(&ia, 0));
   }
   if (IS("r-sample-loc-index-far")) {
      VkAttachmentSampleLocationsEXT a = { FAR_INDEX, valid_sample_locations() };
      VkRenderPassSampleLocationsBeginInfoEXT sl = {
         .sType = VK_STRUCTURE_TYPE_RENDER_PASS_SAMPLE_LOCATIONS_BEGIN_INFO_EXT,
         .attachmentInitialSampleLocationsCount = 1, .pAttachmentInitialSampleLocations = &a };
      VkClearValue clear = { 0 };
      VkRenderPassBeginInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .pNext = &sl,
                                     .renderPass = (VkRenderPass)w.rp, .framebuffer = (VkFramebuffer)w.fb,
                                     .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1,
                                     .pClearValues = &clear };
      begin(w.cmd);
      struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = (VkCommandBuffer)w.cmd, .pRenderPassBegin = &info,
                                                   .contents = VK_SUBPASS_CONTENTS_INLINE };
      step("vkCmdBeginRenderPass with sample locations for attachment %u", FAR_INDEX);
      D->dispatch_vkCmdBeginRenderPass(D, &b);
      end_pass(w.cmd);
      return end(w.cmd);
   }
   if (!strncmp(c, "r-dyn-", 6))
      return rendering_case(c, &w);
   return BROKEN;
}

/* ---------------- descriptor set layouts, pools, sets, writes and copies ---------------- */
static int case_descriptor_layout(const char *c)
{
   VkDescriptorSetLayoutBinding b[4] = {
      { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL },
      { 1, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL },
      { 2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL },
      { 3, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL } };
   uint32_t n = 1;
   VkDescriptorSetLayoutCreateFlags flags = 0;
   const void *next = NULL;
   VkDescriptorBindingFlags bflags[4] = { 0 };
   VkDescriptorSetLayoutBindingFlagsCreateInfo bfi = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, .bindingCount = 1,
      .pBindingFlags = bflags };
   VkSampler samplers[2] = { (VkSampler)sampler(), VK_NULL_HANDLE };
   if (IS("d-layout-binding-far")) {
      b[0].binding = 0xffffffffu;
   } else if (IS("d-layout-binding-over")) {
      b[0].binding = 65536;
   } else if (IS("d-layout-binding-max")) {
      b[0].binding = 65535;
   } else if (IS("d-layout-type-bad")) {
      b[0].descriptorType = (VkDescriptorType)0x7fff;
   } else if (IS("d-layout-dynamic-300") || IS("d-layout-dynamic-over")) {
      b[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
      b[0].descriptorCount = IS("d-layout-dynamic-300") ? 300 : dynamic_ubo_max + 1;
      if (IS("d-layout-dynamic-300"))
         expect(300 > dynamic_ubo_max);
      else if (b[0].descriptorCount > 4096) {
         printf("skip: dynamic buffer limit %u\n", dynamic_ubo_max);
         return SKIP;
      }
   } else if (IS("d-layout-flags-short")) {
      n = 3;
      next = &bfi;
   } else if (IS("d-layout-null-immutable")) {
      b[0].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER;
      b[0].descriptorCount = 2;
      b[0].pImmutableSamplers = samplers;
   } else if (IS("d-layout-push-over") || IS("d-layout-push-max")) {
      flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR;
      b[0].descriptorCount = IS("d-layout-push-max") ? max_push_descriptors : max_push_descriptors + 1;
   } else if (IS("d-layout-variable-not-last")) {
      n = 2;
      bfi.bindingCount = 2;
      bflags[0] = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;
      next = &bfi;
   } else if (IS("d-layout-inline-odd") || IS("d-layout-inline-max")) {
      if (!max_inline_block)
         return SKIP;
      b[0].descriptorType = VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK;
      b[0].descriptorCount = IS("d-layout-inline-max") ? max_inline_block : 6;
   } else if (IS("d-layout-count-huge")) {
      b[0].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
      b[0].descriptorCount = 0x10000000u;
   } else {
      return BROKEN;
   }
   return created(set_layout_of(b, n, flags, next));
}

/* a layout with a variable-count binding of max descriptors, and n sets of it */
static int variable_case(const char *c)
{
   const VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 16, VK_SHADER_STAGE_ALL, NULL };
   const VkDescriptorBindingFlags f = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT;
   const VkDescriptorSetLayoutBindingFlagsCreateInfo bfi = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, .bindingCount = 1,
      .pBindingFlags = &f };
   void *dsl = set_layout_of(&b, 1, 0, &bfi);
   if (!dsl)
      return created(dsl);
   void *p = pool();
   uint32_t counts[2] = { 8, 8 };
   VkDescriptorSetVariableDescriptorCountAllocateInfo vc = {
      .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO, .descriptorSetCount = 1,
      .pDescriptorCounts = counts };
   if (IS("d-var-count-big"))
      counts[0] = 1 << 20;
   if (!IS("d-var-info-short"))
      return created(set_from(p, dsl, &vc));
   /* two sets, one count */
   const uint64_t id = next_id++;
   VkDescriptorSet h[2] = { (VkDescriptorSet)(uintptr_t)id, (VkDescriptorSet)(uintptr_t)next_id++ };
   VkDescriptorSetLayout layouts[2] = { (VkDescriptorSetLayout)dsl, (VkDescriptorSetLayout)dsl };
   VkDescriptorSetAllocateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .pNext = &vc,
                                        .descriptorPool = (VkDescriptorPool)p, .descriptorSetCount = 2,
                                        .pSetLayouts = layouts };
   struct vn_command_vkAllocateDescriptorSets a = { .device = DEVH, .pAllocateInfo = &info, .pDescriptorSets = h };
   step("vkAllocateDescriptorSets 2 sets, 1 variable count");
   D->dispatch_vkAllocateDescriptorSets(D, &a);
   last_ret = a.ret;
   return created(a.ret == VK_SUCCESS ? object(id) : NULL);
}

static int pool_case(const char *c)
{
   VkDescriptorPoolSize size = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, IS("d-pool-overflow") ? 1u << 27 : 1u << 20 };
   if (IS("d-pool-type-bad"))
      size = (VkDescriptorPoolSize){ (VkDescriptorType)0x7fff, 4 };
   const uint64_t id = next_id++;
   VkDescriptorPool h = (VkDescriptorPool)(uintptr_t)id;
   VkDescriptorPoolCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 4,
                                       .poolSizeCount = 1, .pPoolSizes = &size };
   struct vn_command_vkCreateDescriptorPool cp = { .device = DEVH, .pCreateInfo = &info, .pDescriptorPool = &h };
   step("vkCreateDescriptorPool type %d count %u", size.type, size.descriptorCount);
   D->dispatch_vkCreateDescriptorPool(D, &cp);
   last_ret = cp.ret;
   return created(cp.ret == VK_SUCCESS ? object(id) : NULL);
}

static int case_descriptor(const char *c)
{
   unsigned needs = 0;
   if (IS("d-null-buffer-nd") || IS("d-null-view-nd"))
      needs |= N_NULLDESC;
   if (!strncmp(c, "d-layout-push", 13))
      needs |= N_PUSHDESC;
   setup(needs);
   if (!strncmp(c, "d-layout-", 9))
      return case_descriptor_layout(c);
   if (!strncmp(c, "d-var-", 6))
      return variable_case(c);
   if (!strncmp(c, "d-pool-", 7))
      return pool_case(c);
   struct world w = { 0 };
   make_world(&w, false);
   VkDescriptorBufferInfo bi[2] = { { (VkBuffer)w.buf, 0, 256 }, { (VkBuffer)w.buf, 256, 256 } };
   VkDescriptorImageInfo ii = { (VkSampler)w.smp, (VkImageView)w.iv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
   VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)w.set,
                               .dstBinding = 0, .descriptorCount = 1,
                               .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = bi };
   uint8_t inline_data[16] = { 1 };
   VkWriteDescriptorSetInlineUniformBlock inl = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_INLINE_UNIFORM_BLOCK,
                                                  .dataSize = 16, .pData = inline_data };
   VkCopyDescriptorSet cp = { .sType = VK_STRUCTURE_TYPE_COPY_DESCRIPTOR_SET, .srcSet = (VkDescriptorSet)w.set,
                              .dstSet = (VkDescriptorSet)w.set, .descriptorCount = 1 };
   uint32_t n_copy = 0;
   if (IS("d-ok")) {
   } else if (IS("d-binding-oob")) {
      wr.dstBinding = 1000;
   } else if (IS("d-binding-far")) {
      wr.dstBinding = FAR_INDEX;
   } else if (IS("d-elem-far")) {
      wr.dstArrayElement = FAR_INDEX;
   } else if (IS("d-elem-next")) {
      wr.dstArrayElement = 1; /* past the binding's 1, into a binding of another type */
   } else if (IS("d-type-mismatch")) {
      wr.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
      wr.pImageInfo = &ii;
   } else if (IS("d-null-sampler")) {
      ii.sampler = VK_NULL_HANDLE;
      wr.dstBinding = 1;
      wr.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
      wr.pImageInfo = &ii;
   } else if (IS("d-null-view") || IS("d-null-view-nd")) {
      ii.imageView = VK_NULL_HANDLE;
      wr.dstBinding = 1;
      wr.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
      wr.pImageInfo = &ii;
   } else if (IS("d-null-buffer") || IS("d-null-buffer-nd")) {
      bi[0] = (VkDescriptorBufferInfo){ VK_NULL_HANDLE, 0, VK_WHOLE_SIZE };
   } else if (IS("d-range-past")) {
      bi[0].range = 1 << 20;
   } else if (IS("d-offset-past-whole")) {
      bi[0].offset = 1 << 20;
      bi[0].range = VK_WHOLE_SIZE;
   } else if (IS("d-dyn-elem-far")) {
      wr.dstBinding = 3;
      wr.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC;
      wr.dstArrayElement = FAR_INDEX;
   } else if (IS("d-inline-far") || IS("d-inline-ok") || IS("d-inline-size")) {
      if (!max_inline_block)
         return SKIP;
      wr.dstBinding = 5;
      wr.descriptorType = VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK;
      wr.descriptorCount = 16;
      wr.dstArrayElement = IS("d-inline-far") ? 0x10000000 : 0;
      if (IS("d-inline-size"))
         inl.dataSize = 4096; /* not the write's descriptorCount */
      wr.pNext = &inl;
      wr.pBufferInfo = NULL;
   } else if (IS("d-copy-far")) {
      cp.srcBinding = 0;
      cp.dstBinding = 2;
      cp.srcArrayElement = FAR_INDEX;
      n_copy = 1;
   } else if (IS("d-copy-ok")) {
      void *other = set_from(w.pool, w.dsl, NULL);
      cp.dstSet = (VkDescriptorSet)other;
      n_copy = 1;
   } else if (IS("d-consecutive-ok")) {
      const VkDescriptorSetLayoutBinding b[2] = { { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL },
                                                  { 1, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL } };
      void *dsl = set_layout_of(b, 2, 0, NULL);
      wr.dstSet = (VkDescriptorSet)set_from(w.pool, dsl, NULL);
      wr.descriptorCount = 2; /* binding 0, then binding 1 */
   } else {
      return BROKEN;
   }
   struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = n_copy ? 0 : 1,
                                                  .pDescriptorWrites = &wr, .descriptorCopyCount = n_copy,
                                                  .pDescriptorCopies = &cp };
   step("vkUpdateDescriptorSets binding %u elem %u type %d count %u copies %u", wr.dstBinding, wr.dstArrayElement,
        wr.descriptorType, wr.descriptorCount, n_copy);
   D->dispatch_vkUpdateDescriptorSets(D, &u);
   step("vkUpdateDescriptorSets done");
   return ended() ? FATAL : WORKS;
}

/* ---------------- command recording ---------------- */
static void bind_sets(void *cmd, void *layout, uint32_t first, void **sets, uint32_t n, const uint32_t *offsets,
                      uint32_t n_offsets)
{
   VkDescriptorSet s[64];
   for (uint32_t i = 0; i < n && i < 64; i++)
      s[i] = (VkDescriptorSet)sets[i];
   struct vn_command_vkCmdBindDescriptorSets b = {
      .commandBuffer = (VkCommandBuffer)cmd, .pipelineBindPoint = VK_PIPELINE_BIND_POINT_COMPUTE,
      .layout = (VkPipelineLayout)layout, .firstSet = first, .descriptorSetCount = n, .pDescriptorSets = s,
      .dynamicOffsetCount = n_offsets, .pDynamicOffsets = offsets };
   step("vkCmdBindDescriptorSets first %u count %u dynamic offsets %u", first, n, n_offsets);
   D->dispatch_vkCmdBindDescriptorSets(D, &b);
}

/* everything the world's pipelines use, bound (a draw or dispatch without it is invalid
 * usage: MoltenVK reads the unset state when it encodes) */
static void ready(void *cmd, struct world *w, VkPipelineBindPoint point)
{
   VkDescriptorBufferInfo ubo = { (VkBuffer)w->buf, 0, 256 }, ssbo = { (VkBuffer)w->buf, 256, 256 },
                          dyn = { (VkBuffer)w->buf, 512, 256 };
   VkDescriptorImageInfo cis = { (VkSampler)w->smp, (VkImageView)w->iv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
   VkWriteDescriptorSet wr[4] = {
      { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)w->set, .dstBinding = 0,
        .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &ubo },
      { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)w->set, .dstBinding = 1,
        .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &cis },
      { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)w->set, .dstBinding = 2,
        .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &ssbo },
      { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)w->set, .dstBinding = 3,
        .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, .pBufferInfo = &dyn } };
   struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = 4, .pDescriptorWrites = wr };
   step("vkUpdateDescriptorSets (the world's set)");
   D->dispatch_vkUpdateDescriptorSets(D, &u);
   VkDescriptorSet set = (VkDescriptorSet)w->set;
   const uint32_t off = 0;
   struct vn_command_vkCmdBindDescriptorSets b = { .commandBuffer = (VkCommandBuffer)cmd, .pipelineBindPoint = point,
                                                   .layout = (VkPipelineLayout)w->layout, .descriptorSetCount = 1,
                                                   .pDescriptorSets = &set, .dynamicOffsetCount = 1,
                                                   .pDynamicOffsets = &off };
   step("vkCmdBindDescriptorSets (the world's set)");
   D->dispatch_vkCmdBindDescriptorSets(D, &b);
   static uint8_t data[128];
   struct vn_command_vkCmdPushConstants p = { .commandBuffer = (VkCommandBuffer)cmd,
                                              .layout = (VkPipelineLayout)w->layout,
                                              .stageFlags = VK_SHADER_STAGE_ALL, .size = 128, .pValues = data };
   D->dispatch_vkCmdPushConstants(D, &p);
   if (point == VK_PIPELINE_BIND_POINT_GRAPHICS) {
      VkBuffer vb = (VkBuffer)w->buf;
      VkDeviceSize vo = 0;
      struct vn_command_vkCmdBindVertexBuffers v = { .commandBuffer = (VkCommandBuffer)cmd, .bindingCount = 1,
                                                     .pBuffers = &vb, .pOffsets = &vo };
      D->dispatch_vkCmdBindVertexBuffers(D, &v);
      VkViewport vp = { 0, 0, 64, 64, 0, 1 };
      struct vn_command_vkCmdSetViewport sv = { .commandBuffer = (VkCommandBuffer)cmd, .viewportCount = 1,
                                                .pViewports = &vp };
      D->dispatch_vkCmdSetViewport(D, &sv);
   }
}

static int sets_case(const char *c, struct world *w)
{
   static uint32_t offs[4096];
   void *set = w->set;
   if (IS("c-sets-ok"))
      bind_sets(w->cmd, w->layout, 0, &set, 1, offs, 1);
   else if (IS("c-sets-first-far"))
      bind_sets(w->cmd, w->layout, FAR_INDEX, &set, 1, offs, 1);
   else if (IS("c-dyn-offsets-many"))
      bind_sets(w->cmd, w->layout, 0, &set, 1, offs, 4096);
   else if (IS("c-sets-fewer-offsets"))
      bind_sets(w->cmd, w->layout, 0, &set, 1, NULL, 0);
   else if (IS("c-sets-layout-mismatch")) {
      /* the pipeline layout's set 0 has 2 dynamic buffers, the bound set's layout 1 */
      const VkDescriptorSetLayoutBinding b[2] = {
         { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_ALL, NULL },
         { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_ALL, NULL } };
      void *two = set_layout_of(b, 2, 0, NULL);
      void *layout = pipeline_layout_of(&two, 1, NULL, 0);
      void *one_l = set_layout_of(b, 1, 0, NULL);
      void *one = set_from(w->pool, one_l, NULL);
      bind_sets(w->cmd, layout, 0, &one, 1, offs, 2);
   } else if (IS("c-sets-max")) {
      void *dsl = one_binding_layout(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL);
      const uint32_t n = lim.maxBoundDescriptorSets > 32 ? 32 : lim.maxBoundDescriptorSets;
      void *dsls[32], *sets[32];
      for (uint32_t i = 0; i < n; i++)
         dsls[i] = dsl;
      void *layout = pipeline_layout_of(dsls, n, NULL, 0);
      if (!layout)
         return created(layout);
      for (uint32_t i = 0; i < n; i++)
         sets[i] = set_from(w->pool, dsl, NULL);
      bind_sets(w->cmd, layout, 0, sets, n, NULL, 0);
   } else {
      return BROKEN;
   }
   return end(w->cmd);
}

static int push_set_case(const char *c, struct world *w)
{
   const VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL };
   void *push = set_layout_of(&b, 1, VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR, NULL);
   void *plain = set_layout_of(&b, 1, 0, NULL);
   void *dsls[2] = { plain, push };
   void *layout = pipeline_layout_of(dsls, 2, NULL, 0);
   if (!push || !plain || !layout)
      broken("push descriptor layouts");
   VkDescriptorBufferInfo bi = { (VkBuffer)w->buf, 0, 256 };
   VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 0,
                               .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                               .pBufferInfo = &bi };
   uint32_t set = 1;
   if (IS("c-push-set-oob"))
      set = FAR_INDEX;
   else if (IS("c-push-set-not-push"))
      set = 0;
   else if (IS("c-push-set-binding-far"))
      wr.dstBinding = FAR_INDEX;
   struct vn_command_vkCmdPushDescriptorSet p = { .commandBuffer = (VkCommandBuffer)w->cmd,
                                                  .pipelineBindPoint = VK_PIPELINE_BIND_POINT_COMPUTE,
                                                  .layout = (VkPipelineLayout)layout, .set = set,
                                                  .descriptorWriteCount = 1, .pDescriptorWrites = &wr };
   step("vkCmdPushDescriptorSet set %u binding %u", set, wr.dstBinding);
   D->dispatch_vkCmdPushDescriptorSet(D, &p);
   return end(w->cmd);
}

static int execute_case(const char *c, struct world *w)
{
   void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
   void *sec2 = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
   if (begin_secondary(sec, NULL) != VK_SUCCESS)
      broken("secondary begin");
   if (IS("c-nested-self") || IS("c-execute-in-secondary")) {
      if (IS("c-execute-in-secondary") && begin_secondary(sec2, NULL) != VK_SUCCESS)
         broken("secondary begin");
      VkCommandBuffer inner = (VkCommandBuffer)(IS("c-nested-self") ? sec : sec2);
      if (IS("c-execute-in-secondary") && end(sec2) != WORKS)
         broken("secondary end");
      struct vn_command_vkCmdExecuteCommands e = { .commandBuffer = (VkCommandBuffer)sec, .commandBufferCount = 1,
                                                   .pCommandBuffers = &inner };
      step("vkCmdExecuteCommands in a secondary (%s)", c);
      D->dispatch_vkCmdExecuteCommands(D, &e);
   }
   int r = end(sec);
   if (r != WORKS)
      return r;
   begin(w->cmd);
   VkCommandBuffer target = (VkCommandBuffer)sec;
   if (IS("c-execute-primary")) {
      void *other = command_buffer();
      begin(other);
      target = (VkCommandBuffer)other;
   }
   struct vn_command_vkCmdExecuteCommands e = { .commandBuffer = (VkCommandBuffer)w->cmd, .commandBufferCount = 1,
                                                .pCommandBuffers = &target };
   step("vkCmdExecuteCommands in the primary (%s)", c);
   D->dispatch_vkCmdExecuteCommands(D, &e);
   step("vkCmdExecuteCommands done");
   return end(w->cmd);
}

static int inherit_case(const char *c)
{
   static uint32_t locations[1 << 16];
   VkFormat formats[64];
   for (int i = 0; i < 64; i++)
      formats[i] = FMT;
   VkRenderingAttachmentLocationInfoKHR loc = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_LOCATION_INFO_KHR,
                                                .colorAttachmentCount = 1 << 16,
                                                .pColorAttachmentLocations = locations };
   VkCommandBufferInheritanceRenderingInfo ri = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_RENDERING_INFO,
      .pNext = IS("c-inherit-locations-far") ? &loc : NULL,
      .colorAttachmentCount = IS("c-inherit-colors-over") ? lim.maxColorAttachments + 1 : 1,
      .pColorAttachmentFormats = formats, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
   void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
   begin_secondary(sec, &ri);
   return end(sec);
}

static int case_command(const char *c)
{
   unsigned needs = 0;
   if (!strncmp(c, "c-drawmulti", 11))
      needs |= N_MULTIDRAW;
   if (IS("c-vbuf-null-nd"))
      needs |= N_NULLDESC;
   if (!strncmp(c, "c-sample-locations", 18))
      needs |= N_SAMPLELOC;
   if (!strncmp(c, "c-att-locations", 15) || !strncmp(c, "c-input-indices", 15) ||
       IS("c-inherit-locations-far"))
      needs |= N_LOCALREAD;
   if (!strncmp(c, "c-push-set", 10))
      needs |= N_PUSHDESC;
   if (IS("c-sets2-first-far") || IS("c-push2-far"))
      needs |= N_MAINT6;
   if (IS("c-enum-logicop"))
      needs |= N_LOGICOP;
   if (IS("c-blend-enable-far"))
      needs |= N_BLENDEN;
   if (!strncmp(c, "c-nested", 8) || !strncmp(c, "c-execute", 9))
      needs |= N_NESTED;
   setup(needs);
   if (!strncmp(c, "c-inherit", 9))
      return inherit_case(c);
   struct world w = { 0 };
   const bool needs_pipe = !strncmp(c, "c-draw", 6) || !strncmp(c, "c-dispatch", 10) || IS("c-ok") ||
                           IS("c-bind-wrong-point") || IS("c-bind-point-bad") || !strncmp(c, "c-clear-att", 11);
   make_world(&w, needs_pipe);
   if (!strncmp(c, "c-nested", 8) || !strncmp(c, "c-execute", 9))
      return execute_case(c, &w);
   void *cmd = w.cmd;
   begin(cmd);
   if (!strncmp(c, "c-sets-", 7) || IS("c-dyn-offsets-many"))
      return sets_case(c, &w);
   if (!strncmp(c, "c-push-set", 10))
      return push_set_case(c, &w);
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   VkViewport vps[64];
   VkRect2D scs[64];
   for (int i = 0; i < 64; i++) {
      vps[i] = (VkViewport){ 0, 0, 64, 64, 0, 1 };
      scs[i] = (VkRect2D){ { 0, 0 }, { 64, 64 } };
   }
   const bool in_pass = !strncmp(c, "c-draw", 6) || IS("c-ok") || !strncmp(c, "c-clear-att", 11) ||
                        IS("c-bind-wrong-point");
   if (in_pass)
      begin_pass(cmd, w.rp, w.fb, 64, 64);

   if (IS("c-ok")) {
      bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w.gfx_pipe);
      ready(cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
      struct vn_command_vkCmdDraw d = { .commandBuffer = cb, .vertexCount = 3, .instanceCount = 1 };
      step("vkCmdDraw");
      D->dispatch_vkCmdDraw(D, &d);
   } else if (!strncmp(c, "c-push-", 7)) {
      static uint8_t data[1 << 16];
      uint32_t off = FAR32, size = 16;
      if (IS("c-push-near")) {
         off = lim.maxPushConstantsSize - 4;
         size = 8;
      } else if (IS("c-push-wrap")) {
         off = 0xffffff00u;
         size = 0x200;
      } else if (IS("c-push-max")) {
         off = 0;
         size = lim.maxPushConstantsSize;
      } else if (!IS("c-push-far")) {
         return BROKEN;
      }
      struct vn_command_vkCmdPushConstants p = { .commandBuffer = cb, .layout = (VkPipelineLayout)w.layout,
                                                 .stageFlags = VK_SHADER_STAGE_ALL, .offset = off, .size = size,
                                                 .pValues = data };
      step("vkCmdPushConstants offset 0x%x size 0x%x", off, size);
      D->dispatch_vkCmdPushConstants(D, &p);
   } else if (IS("c-push2-far")) {
      static uint8_t data[64];
      VkPushConstantsInfoKHR info = { .sType = VK_STRUCTURE_TYPE_PUSH_CONSTANTS_INFO_KHR,
                                      .layout = (VkPipelineLayout)w.layout, .stageFlags = VK_SHADER_STAGE_ALL,
                                      .offset = FAR32, .size = 16, .pValues = data };
      struct vn_command_vkCmdPushConstants2 p = { .commandBuffer = cb, .pPushConstantsInfo = &info };
      step("vkCmdPushConstants2 offset 0x%x", FAR32);
      D->dispatch_vkCmdPushConstants2(D, &p);
   } else if (IS("c-sets2-first-far")) {
      VkDescriptorSet s = (VkDescriptorSet)w.set;
      static uint32_t offs[4];
      VkBindDescriptorSetsInfoKHR info = { .sType = VK_STRUCTURE_TYPE_BIND_DESCRIPTOR_SETS_INFO_KHR,
                                           .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
                                           .layout = (VkPipelineLayout)w.layout, .firstSet = FAR_INDEX,
                                           .descriptorSetCount = 1, .pDescriptorSets = &s, .dynamicOffsetCount = 1,
                                           .pDynamicOffsets = offs };
      struct vn_command_vkCmdBindDescriptorSets2 b = { .commandBuffer = cb, .pBindDescriptorSetsInfo = &info };
      step("vkCmdBindDescriptorSets2 first %u", FAR_INDEX);
      D->dispatch_vkCmdBindDescriptorSets2(D, &b);
   } else if (!strncmp(c, "c-viewport", 10) || !strncmp(c, "c-scissor", 9)) {
      uint32_t first = FAR_INDEX, count = 1;
      if (IS("c-viewport-over")) {
         first = lim.maxViewports;
      } else if (IS("c-viewport-max")) {
         first = 0;
         count = lim.maxViewports;
      }
      if (!strncmp(c, "c-scissor", 9)) {
         struct vn_command_vkCmdSetScissor s = { .commandBuffer = cb, .firstScissor = first, .scissorCount = count,
                                                 .pScissors = scs };
         step("vkCmdSetScissor first %u count %u", first, count);
         D->dispatch_vkCmdSetScissor(D, &s);
      } else {
         struct vn_command_vkCmdSetViewport v = { .commandBuffer = cb, .firstViewport = first,
                                                  .viewportCount = count, .pViewports = vps };
         step("vkCmdSetViewport first %u count %u", first, count);
         D->dispatch_vkCmdSetViewport(D, &v);
      }
   } else if (IS("c-blend-enable-far")) {
      VkBool32 on = VK_TRUE;
      struct vn_command_vkCmdSetColorBlendEnableEXT b = { .commandBuffer = cb, .firstAttachment = FAR_INDEX,
                                                         .attachmentCount = 1, .pColorBlendEnables = &on };
      step("vkCmdSetColorBlendEnableEXT first %u", FAR_INDEX);
      D->dispatch_vkCmdSetColorBlendEnableEXT(D, &b);
   } else if (!strncmp(c, "c-vbuf", 6)) {
      VkBuffer bufs[64];
      VkDeviceSize offs[64];
      uint32_t first = 0, count = 1;
      for (int i = 0; i < 64; i++) {
         bufs[i] = (VkBuffer)w.buf;
         offs[i] = 0;
      }
      if (IS("c-vbuf-first-far"))
         first = FAR_INDEX;
      else if (IS("c-vbuf-offset-past"))
         offs[0] = 1 << 20;
      else if (IS("c-vbuf-max"))
         count = lim.maxVertexInputBindings > 64 ? 64 : lim.maxVertexInputBindings;
      else if (IS("c-vbuf-null") || IS("c-vbuf-null-nd"))
         bufs[0] = VK_NULL_HANDLE;
      else
         return BROKEN;
      struct vn_command_vkCmdBindVertexBuffers v = { .commandBuffer = cb, .firstBinding = first,
                                                     .bindingCount = count, .pBuffers = bufs, .pOffsets = offs };
      step("vkCmdBindVertexBuffers first %u count %u offset %llu", first, count, (unsigned long long)offs[0]);
      D->dispatch_vkCmdBindVertexBuffers(D, &v);
   } else if (!strncmp(c, "c-ibuf", 6)) {
      struct vn_command_vkCmdBindIndexBuffer b = { .commandBuffer = cb, .buffer = (VkBuffer)w.buf, .offset = 0,
                                                   .indexType = VK_INDEX_TYPE_UINT16 };
      if (IS("c-ibuf-type-bad"))
         b.indexType = (VkIndexType)0x7fff;
      else if (IS("c-ibuf-offset-past"))
         b.offset = 1 << 20;
      else if (!IS("c-ibuf-ok"))
         return BROKEN;
      step("vkCmdBindIndexBuffer type %d offset %llu", b.indexType, (unsigned long long)b.offset);
      D->dispatch_vkCmdBindIndexBuffer(D, &b);
   } else if (!strncmp(c, "c-copy-buffer", 13)) {
      VkBufferCopy r = { 0, 0, 4096 };
      if (IS("c-copy-buffer-past"))
         r = (VkBufferCopy){ 0, 0, 1 << 20 };
      else if (IS("c-copy-buffer-far"))
         r = (VkBufferCopy){ 1ull << 40, 0, 4096 };
      else if (IS("c-copy-buffer-wrap"))
         r = (VkBufferCopy){ 0xffffffffffff0000ull, 0, 0x20000 };
      struct vn_command_vkCmdCopyBuffer cpy = { .commandBuffer = cb, .srcBuffer = (VkBuffer)w.buf,
                                                .dstBuffer = (VkBuffer)w.buf2, .regionCount = 1, .pRegions = &r };
      step("vkCmdCopyBuffer src %llu size %llu", (unsigned long long)r.srcOffset, (unsigned long long)r.size);
      D->dispatch_vkCmdCopyBuffer(D, &cpy);
   } else if (IS("c-copy-b2i-level") || IS("c-copy-b2i-ok")) {
      VkBufferImageCopy r = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, IS("c-copy-b2i-level") ? 5 : 0, 0, 1 },
                              .imageExtent = { 64, 64, 1 } };
      struct vn_command_vkCmdCopyBufferToImage cpy = { .commandBuffer = cb, .srcBuffer = (VkBuffer)w.buf2,
                                                       .dstImage = (VkImage)w.img,
                                                       .dstImageLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                                       .regionCount = 1, .pRegions = &r };
      step("vkCmdCopyBufferToImage level %u", r.imageSubresource.mipLevel);
      D->dispatch_vkCmdCopyBufferToImage(D, &cpy);
   } else if (IS("c-blit-level") || IS("c-blit-ok") || IS("c-blit-layers")) {
      VkImageBlit r = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, IS("c-blit-level") ? 3 : 0,
                                            IS("c-blit-layers") ? 7 : 0, 1 },
                        .srcOffsets = { { 0, 0, 0 }, { 64, 64, 1 } },
                        .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                        .dstOffsets = { { 0, 0, 0 }, { 64, 64, 1 } } };
      struct vn_command_vkCmdBlitImage b = { .commandBuffer = cb, .srcImage = (VkImage)w.img,
                                             .srcImageLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                             .dstImage = (VkImage)w.img2,
                                             .dstImageLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                             .regionCount = 1, .pRegions = &r, .filter = VK_FILTER_LINEAR };
      step("vkCmdBlitImage src level %u layer %u", r.srcSubresource.mipLevel, r.srcSubresource.baseArrayLayer);
      D->dispatch_vkCmdBlitImage(D, &b);
   } else if (IS("c-copy-image-layer") || IS("c-copy-image-ok")) {
      VkImageCopy r = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, IS("c-copy-image-layer") ? 4 : 0, 1 },
                        .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .extent = { 64, 64, 1 } };
      struct vn_command_vkCmdCopyImage cpy = { .commandBuffer = cb, .srcImage = (VkImage)w.img,
                                               .srcImageLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                               .dstImage = (VkImage)w.img2,
                                               .dstImageLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                               .regionCount = 1, .pRegions = &r };
      step("vkCmdCopyImage src layer %u", r.srcSubresource.baseArrayLayer);
      D->dispatch_vkCmdCopyImage(D, &cpy);
   } else if (IS("c-clear-color-range") || IS("c-clear-color-remaining")) {
      VkClearColorValue col = { { 0 } };
      VkImageSubresourceRange r = { VK_IMAGE_ASPECT_COLOR_BIT, 7, 1, 9, 1 };
      if (IS("c-clear-color-remaining"))
         r = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0,
                                        VK_REMAINING_ARRAY_LAYERS };
      struct vn_command_vkCmdClearColorImage cl = { .commandBuffer = cb, .image = (VkImage)w.img,
                                                    .imageLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                                    .pColor = &col, .rangeCount = 1, .pRanges = &r };
      step("vkCmdClearColorImage level %u layer %u", r.baseMipLevel, r.baseArrayLayer);
      D->dispatch_vkCmdClearColorImage(D, &cl);
   } else if (!strncmp(c, "c-fill", 6) || !strncmp(c, "c-update", 8)) {
      if (!strncmp(c, "c-fill", 6)) {
         struct vn_command_vkCmdFillBuffer f = { .commandBuffer = cb, .dstBuffer = (VkBuffer)w.buf,
                                                 .dstOffset = 1 << 20, .size = 4096, .data = 7 };
         if (IS("c-fill-whole")) {
            f.dstOffset = 256;
            f.size = VK_WHOLE_SIZE;
         }
         step("vkCmdFillBuffer offset %llu size %llu", (unsigned long long)f.dstOffset, (unsigned long long)f.size);
         D->dispatch_vkCmdFillBuffer(D, &f);
      } else {
         static uint8_t data[65540];
         struct vn_command_vkCmdUpdateBuffer u = { .commandBuffer = cb, .dstBuffer = (VkBuffer)w.buf,
                                                   .dstOffset = 1 << 20, .dataSize = 4096, .pData = data };
         if (IS("c-update-big")) {
            u.dstOffset = 0;
            u.dataSize = 65540;
         }
         step("vkCmdUpdateBuffer offset %llu size %llu", (unsigned long long)u.dstOffset,
              (unsigned long long)u.dataSize);
         D->dispatch_vkCmdUpdateBuffer(D, &u);
      }
   } else if (!strncmp(c, "c-query-", 8)) {
      void *qp = query_pool(VK_QUERY_TYPE_OCCLUSION, 4);
      void *tp = query_pool(VK_QUERY_TYPE_TIMESTAMP, 4);
      if (IS("c-query-reset-far")) {
         struct vn_command_vkCmdResetQueryPool r = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp,
                                                     .firstQuery = FAR_INDEX, .queryCount = 4 };
         step("vkCmdResetQueryPool first %u", FAR_INDEX);
         D->dispatch_vkCmdResetQueryPool(D, &r);
      } else if (IS("c-query-begin-far")) {
         begin_pass(cmd, w.rp, w.fb, 64, 64);
         struct vn_command_vkCmdBeginQuery b = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp,
                                                 .query = FAR_INDEX };
         step("vkCmdBeginQuery %u of 4", FAR_INDEX);
         D->dispatch_vkCmdBeginQuery(D, &b);
         if (!ended()) {
            struct vn_command_vkCmdEndQuery e = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp,
                                                  .query = FAR_INDEX };
            D->dispatch_vkCmdEndQuery(D, &e);
         }
         end_pass(cmd);
      } else if (IS("c-query-timestamp-far")) {
         struct vn_command_vkCmdWriteTimestamp t = { .commandBuffer = cb,
                                                     .pipelineStage = VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                                                     .queryPool = (VkQueryPool)tp, .query = FAR_INDEX };
         step("vkCmdWriteTimestamp %u of 4", FAR_INDEX);
         D->dispatch_vkCmdWriteTimestamp(D, &t);
      } else if (IS("c-query-copy-past") || IS("c-query-copy-ok")) {
         struct vn_command_vkCmdCopyQueryPoolResults q = {
            .commandBuffer = cb, .queryPool = (VkQueryPool)qp, .firstQuery = 0, .queryCount = 4,
            .dstBuffer = (VkBuffer)w.buf, .dstOffset = IS("c-query-copy-ok") ? 65536 - 32 : 1 << 20, .stride = 8,
            .flags = VK_QUERY_RESULT_64_BIT };
         step("vkCmdCopyQueryPoolResults dst offset %llu", (unsigned long long)q.dstOffset);
         D->dispatch_vkCmdCopyQueryPoolResults(D, &q);
      } else {
         return BROKEN;
      }
   } else if (!strncmp(c, "c-draw-indirect", 15)) {
      bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w.gfx_pipe);
      ready(cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
      struct vn_command_vkCmdDrawIndirect d = { .commandBuffer = cb, .buffer = (VkBuffer)w.buf,
                                                .offset = IS("c-draw-indirect-ok") ? 65536 - 16 : 1 << 20,
                                                .drawCount = 1, .stride = 16 };
      step("vkCmdDrawIndirect offset %llu", (unsigned long long)d.offset);
      D->dispatch_vkCmdDrawIndirect(D, &d);
   } else if (!strncmp(c, "c-drawmulti", 11)) {
      bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w.gfx_pipe);
      ready(cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
      /* the decoder packs the array: 64 entries back to back, a guard page after them */
      VkMultiDrawInfoEXT *infos = guarded(64 * sizeof(VkMultiDrawInfoEXT));
      for (int i = 0; i < 64; i++)
         infos[i] = (VkMultiDrawInfoEXT){ 0, 3 };
      struct vn_command_vkCmdDrawMultiEXT d = { .commandBuffer = cb, .drawCount = 64, .pVertexInfo = infos,
                                                .instanceCount = 1, .stride = sizeof(VkMultiDrawInfoEXT) };
      if (IS("c-drawmulti-stride"))
         d.stride = 4096;
      else if (IS("c-drawmulti-null"))
         d.pVertexInfo = NULL;
      else if (!IS("c-drawmulti-ok"))
         return BROKEN;
      step("vkCmdDrawMultiEXT 64 draws, stride %u, %s", d.stride, d.pVertexInfo ? "array" : "NULL");
      D->dispatch_vkCmdDrawMultiEXT(D, &d);
   } else if (!strncmp(c, "c-dispatch", 10)) {
      bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, w.comp_pipe);
      ready(cmd, &w, VK_PIPELINE_BIND_POINT_COMPUTE);
      if (IS("c-dispatch-indirect-past")) {
         struct vn_command_vkCmdDispatchIndirect d = { .commandBuffer = cb, .buffer = (VkBuffer)w.buf,
                                                       .offset = 1 << 20 };
         step("vkCmdDispatchIndirect offset 1 MiB on 64 KiB");
         D->dispatch_vkCmdDispatchIndirect(D, &d);
      } else {
         struct vn_command_vkCmdDispatch d = { .commandBuffer = cb, .groupCountX = 1, .groupCountY = 1,
                                               .groupCountZ = 1 };
         if (IS("c-dispatch-huge"))
            d.groupCountX = lim.maxComputeWorkGroupCount[0] + 1;
         else if (IS("c-dispatch-max"))
            d.groupCountX = lim.maxComputeWorkGroupCount[0];
         else if (IS("c-dispatch-max-xyz"))
            d = (struct vn_command_vkCmdDispatch){ .commandBuffer = cb,
                                                    .groupCountX = lim.maxComputeWorkGroupCount[0],
                                                    .groupCountY = lim.maxComputeWorkGroupCount[1],
                                                    .groupCountZ = lim.maxComputeWorkGroupCount[2] };
         step("vkCmdDispatch %u x %u x %u", d.groupCountX, d.groupCountY, d.groupCountZ);
         D->dispatch_vkCmdDispatch(D, &d);
      }
   } else if (!strncmp(c, "c-clear-att", 11)) {
      VkClearAttachment a = { VK_IMAGE_ASPECT_COLOR_BIT, 0, { { { 1, 2, 3, 4 } } } };
      if (IS("c-clear-att-over"))
         a.colorAttachment = lim.maxColorAttachments;
      else if (IS("c-clear-att-far"))
         a.colorAttachment = FAR_INDEX;
      VkClearRect r = { { { 0, 0 }, { 64, 64 } }, 0, 1 };
      struct vn_command_vkCmdClearAttachments cl = { .commandBuffer = cb, .attachmentCount = 1, .pAttachments = &a,
                                                     .rectCount = 1, .pRects = &r };
      step("vkCmdClearAttachments color attachment %u", a.colorAttachment);
      D->dispatch_vkCmdClearAttachments(D, &cl);
   } else if (!strncmp(c, "c-barrier", 9)) {
      VkImageMemoryBarrier ib = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                                  .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
                                  .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                  .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = (VkImage)w.img,
                                  .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 5, 1, 9, 1 } };
      if (IS("c-barrier-remaining"))
         ib.subresourceRange = (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, VK_REMAINING_MIP_LEVELS, 0,
                                                          VK_REMAINING_ARRAY_LAYERS };
      if (IS("c-barrier2-range")) {
         VkImageMemoryBarrier2 ib2 = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                                       .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
                                       .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                       .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = (VkImage)w.img,
                                       .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 5, 1, 9, 1 } };
         VkDependencyInfo di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 1,
                                 .pImageMemoryBarriers = &ib2 };
         struct vn_command_vkCmdPipelineBarrier2 p = { .commandBuffer = cb, .pDependencyInfo = &di };
         step("vkCmdPipelineBarrier2 level 5 layer 9 of 1/1");
         D->dispatch_vkCmdPipelineBarrier2(D, &p);
      } else {
         struct vn_command_vkCmdPipelineBarrier p = { .commandBuffer = cb,
                                                      .srcStageMask = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                                      .dstStageMask = VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                                                      .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &ib };
         step("vkCmdPipelineBarrier level %u layer %u", ib.subresourceRange.baseMipLevel,
              ib.subresourceRange.baseArrayLayer);
         D->dispatch_vkCmdPipelineBarrier(D, &p);
      }
   } else if (!strncmp(c, "c-enum-", 7)) {
      if (IS("c-enum-cull")) {
         struct vn_command_vkCmdSetCullMode s = { .commandBuffer = cb, .cullMode = 7 };
         D->dispatch_vkCmdSetCullMode(D, &s);
      } else if (IS("c-enum-compare")) {
         struct vn_command_vkCmdSetDepthCompareOp s = { .commandBuffer = cb, .depthCompareOp = (VkCompareOp)99 };
         D->dispatch_vkCmdSetDepthCompareOp(D, &s);
      } else if (IS("c-enum-topology")) {
         struct vn_command_vkCmdSetPrimitiveTopology s = { .commandBuffer = cb,
                                                           .primitiveTopology = (VkPrimitiveTopology)99 };
         D->dispatch_vkCmdSetPrimitiveTopology(D, &s);
      } else if (IS("c-enum-stencil")) {
         struct vn_command_vkCmdSetStencilOp s = { .commandBuffer = cb, .faceMask = VK_STENCIL_FACE_FRONT_AND_BACK,
                                                   .failOp = VK_STENCIL_OP_KEEP, .passOp = VK_STENCIL_OP_KEEP,
                                                   .depthFailOp = VK_STENCIL_OP_KEEP,
                                                   .compareOp = (VkCompareOp)99 };
         D->dispatch_vkCmdSetStencilOp(D, &s);
      } else if (IS("c-enum-logicop")) {
         struct vn_command_vkCmdSetLogicOpEXT s = { .commandBuffer = cb, .logicOp = (VkLogicOp)99 };
         D->dispatch_vkCmdSetLogicOpEXT(D, &s);
      } else if (IS("c-enum-ok")) {
         struct vn_command_vkCmdSetCullMode s = { .commandBuffer = cb, .cullMode = VK_CULL_MODE_FRONT_AND_BACK };
         D->dispatch_vkCmdSetCullMode(D, &s);
         struct vn_command_vkCmdSetDepthCompareOp d = { .commandBuffer = cb, .depthCompareOp = VK_COMPARE_OP_ALWAYS };
         D->dispatch_vkCmdSetDepthCompareOp(D, &d);
      } else {
         return BROKEN;
      }
      step("%s done", c);
   } else if (IS("c-bind-point-bad")) {
      bind_pipeline(cmd, (VkPipelineBindPoint)7, w.comp_pipe);
   } else if (IS("c-bind-wrong-point")) {
      void *comp = shader(spv_comp, sizeof(spv_comp));
      void *pipe = compute_pipeline(w.layout, comp, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL);
      bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
      if (!ended()) {
         struct vn_command_vkCmdDraw d = { .commandBuffer = cb, .vertexCount = 3, .instanceCount = 1 };
         step("vkCmdDraw with a compute pipeline bound as graphics");
         D->dispatch_vkCmdDraw(D, &d);
      }
   } else if (!strncmp(c, "c-sample-locations", 18)) {
      static VkSampleLocationEXT pts[4096];
      VkSampleLocationsInfoEXT info = { .sType = VK_STRUCTURE_TYPE_SAMPLE_LOCATIONS_INFO_EXT,
                                        .sampleLocationsPerPixel = VK_SAMPLE_COUNT_1_BIT,
                                        .sampleLocationGridSize = { 64, 64 }, .sampleLocationsCount = 4096,
                                        .pSampleLocations = pts };
      if (IS("c-sample-locations-ok"))
         info = valid_sample_locations();
      struct vn_command_vkCmdSetSampleLocationsEXT s = { .commandBuffer = cb, .pSampleLocationsInfo = &info };
      step("vkCmdSetSampleLocationsEXT %u locations", info.sampleLocationsCount);
      D->dispatch_vkCmdSetSampleLocationsEXT(D, &s);
   } else if (!strncmp(c, "c-att-locations", 15) || !strncmp(c, "c-input-indices", 15)) {
      static uint32_t idx[1 << 16];
      const uint32_t n = !strcmp(c + 15, "-max") ? lim.maxColorAttachments : 1u << 16;
      for (uint32_t i = 0; i < n; i++)
         idx[i] = i < lim.maxColorAttachments ? i : VK_ATTACHMENT_UNUSED;
      if (!strncmp(c, "c-att-locations", 15)) {
         VkRenderingAttachmentLocationInfoKHR info = {
            .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_LOCATION_INFO_KHR, .colorAttachmentCount = n,
            .pColorAttachmentLocations = idx };
         struct vn_command_vkCmdSetRenderingAttachmentLocations s = { .commandBuffer = cb, .pLocationInfo = &info };
         step("vkCmdSetRenderingAttachmentLocations %u", n);
         D->dispatch_vkCmdSetRenderingAttachmentLocations(D, &s);
      } else {
         VkRenderingInputAttachmentIndexInfoKHR info = {
            .sType = VK_STRUCTURE_TYPE_RENDERING_INPUT_ATTACHMENT_INDEX_INFO_KHR, .colorAttachmentCount = n,
            .pColorAttachmentInputIndices = idx };
         struct vn_command_vkCmdSetRenderingInputAttachmentIndices s = { .commandBuffer = cb,
                                                                         .pInputAttachmentIndexInfo = &info };
         step("vkCmdSetRenderingInputAttachmentIndices %u", n);
         D->dispatch_vkCmdSetRenderingInputAttachmentIndices(D, &s);
      }
   } else {
      return BROKEN;
   }
   if (in_pass)
      end_pass(cmd);
   return end(cmd);
}

/* ---------------- host query calls and query pools ---------------- */
static int case_query(const char *c)
{
   setup(0);
   if (IS("q-pool-type-bad"))
      return created(query_pool_of((VkQueryType)0x7fff, 4));
   if (IS("q-pool-huge"))
      return created(query_pool_of(VK_QUERY_TYPE_TIMESTAMP, 1u << 30));
   if (IS("q-pool-large"))
      return created(query_pool_of(VK_QUERY_TYPE_TIMESTAMP, 1u << 16));
   void *qp = query_pool(VK_QUERY_TYPE_OCCLUSION, 4);
   if (IS("q-results-first-far") || IS("q-results-stride") || IS("q-ok")) {
      const bool far = IS("q-results-first-far"), stride = IS("q-results-stride");
      uint8_t *data = guarded(64);
      struct vn_command_vkGetQueryPoolResults g = {
         .device = DEVH, .queryPool = (VkQueryPool)qp, .firstQuery = far ? FAR_INDEX : 0, .queryCount = far ? 1 : 4,
         .dataSize = stride ? 64 : 32, .pData = data, .stride = stride ? 4096 : 8,
         .flags = VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_PARTIAL_BIT };
      step("vkGetQueryPoolResults first %u count %u stride %llu into %zu bytes", g.firstQuery, g.queryCount,
           (unsigned long long)g.stride, (size_t)g.dataSize);
      D->dispatch_vkGetQueryPoolResults(D, &g);
      step("vkGetQueryPoolResults = %d", g.ret);
      return ended() ? FATAL : (g.ret >= 0 ? WORKS : ERROR);
   }
   if (IS("q-reset-far") || IS("q-reset-ok")) {
      struct vn_command_vkResetQueryPool r = { .device = DEVH, .queryPool = (VkQueryPool)qp,
                                               .firstQuery = IS("q-reset-ok") ? 0 : FAR_INDEX, .queryCount = 4 };
      step("vkResetQueryPool first %u", r.firstQuery);
      D->dispatch_vkResetQueryPool(D, &r);
      return ended() ? FATAL : WORKS;
   }
   return BROKEN;
}

/* ---------------- the cases and what each must see ---------------- */
struct test_case {
   const char *name;
   int expect;
};

static const struct test_case cases[] = {
   /* pipelines, layouts, stages */
   { "p-ok", E_WORKS }, { "p-gfx-ok", E_WORKS }, { "p-cache-garbage", E_KEEP }, { "p-cache-header", E_KEEP },
   { "p-spec-oob", E_REFUSE }, { "p-spec-wrap", E_REFUSE },
   { "p-stage-null-module", E_REFUSE }, { "p-inline-spirv-odd", E_REFUSE }, { "p-inline-spirv-ok", E_WORKS },
   { "p-compute-stage-wrong", E_REFUSE }, { "p-stage-bits-bad", E_REFUSE }, { "p-robustness-bad", E_REFUSE },
   { "p-compute-feedback-far", E_REFUSE },
   { "p-gfx-colors-max", E_WORKS }, { "p-gfx-colors-over", E_REFUSE }, { "p-gfx-colors-32", E_REFUSE },
   { "p-gfx-viewports-max", E_WORKS }, { "p-gfx-viewports-over", E_REFUSE }, { "p-gfx-viewports-32", E_REFUSE },
   { "p-gfx-vbinding-max", E_KEEP }, { "p-gfx-vbinding-far", E_REFUSE }, { "p-gfx-vlocation-far", E_REFUSE },
   { "p-gfx-vstride-huge", E_REFUSE }, { "p-gfx-samples-64", E_REFUSE }, { "p-gfx-samples-3", E_REFUSE },
   { "p-gfx-subpass-oob", E_REFUSE }, { "p-gfx-blend-count", E_REFUSE }, { "p-gfx-dynamic-bad", E_REFUSE },
   { "p-gfx-stage-bits-bad", E_REFUSE }, { "p-gfx-blend-factor-bad", E_REFUSE }, { "p-gfx-compare-bad", E_REFUSE },
   { "p-gfx-cull-bad", E_REFUSE }, { "p-gfx-feedback-ok", E_WORKS }, { "p-gfx-feedback-far", E_REFUSE },
   { "p-gfx-att-locations-far", E_REFUSE }, { "p-gfx-sample-locations-far", E_REFUSE },
   { "p-layout-sets-max", E_WORKS }, { "p-layout-sets-over", E_REFUSE }, { "p-layout-sets-far", E_REFUSE },
   { "p-layout-push-ranges-ok", E_WORKS }, { "p-layout-push-ranges-far", E_REFUSE },
   { "p-layout-push-over", E_REFUSE }, { "p-layout-dynamic-max", E_WORKS }, { "p-layout-dynamic-over", E_REFUSE },
   /* render passes, framebuffers, dynamic rendering */
   { "r-ok", E_WORKS }, { "r-dyn-ok", E_WORKS }, { "r-two-subpasses-ok", E_WORKS },
   { "r-att-ref-oob", E_REFUSE }, { "r-att-ref-far", E_REFUSE },
   { "r-colors-max", E_WORKS }, { "r-colors-over", E_REFUSE }, { "r-colors-16", E_REFUSE },
   { "r-fb-fewer", E_REFUSE }, { "r-fb-huge", E_REFUSE }, { "r-begin-clear-short", E_REFUSE },
   { "r-multiview-3", E_WORKS }, { "r-multiview-all", E_CHILD }, { "r-dyn-viewmask-all", E_CHILD },
   { "r-mv-legal-2", E_CHILD }, { "r-mv-legal-4", E_CHILD }, { "r-mv-legal-8", E_CHILD },
   { "r-mv-legal-9", E_CHILD }, { "r-mv-legal-12", E_CHILD }, { "r-mv-legal-16", E_CHILD },
   { "r-mv-legal-32", E_CHILD }, { "r-mv-legal-max", E_CHILD }, { "r-mv-legal-max-dyn", E_CHILD },
   { "r-mv-count-short", E_REFUSE }, { "r-dep-subpass-far", E_REFUSE }, { "r-input-aspect-far", E_REFUSE },
   { "r-sample-loc-index-far", E_REFUSE },
   { "r-dyn-colors-over", E_REFUSE }, { "r-dyn-layers-over", E_REFUSE }, { "r-dyn-resolve-null", E_REFUSE },
   { "r-dyn-resolve-mode-bad", E_REFUSE },
   /* descriptor set layouts, pools, sets, writes, copies */
   { "d-layout-binding-max", E_WORKS }, { "d-layout-binding-over", E_REFUSE }, { "d-layout-binding-far", E_REFUSE },
   { "d-layout-type-bad", E_REFUSE }, { "d-layout-dynamic-300", E_CHILD },
   { "d-layout-dynamic-over", E_REFUSE }, { "d-layout-flags-short", E_REFUSE },
   { "d-layout-null-immutable", E_REFUSE }, { "d-layout-push-max", E_WORKS }, { "d-layout-push-over", E_REFUSE },
   { "d-layout-variable-not-last", E_REFUSE }, { "d-layout-inline-max", E_WORKS },
   { "d-layout-inline-odd", E_REFUSE }, { "d-layout-count-huge", E_REFUSE },
   { "d-pool-large", E_KEEP }, { "d-pool-overflow", E_REFUSE }, { "d-pool-type-bad", E_REFUSE },
   { "d-var-ok", E_WORKS }, { "d-var-count-big", E_REFUSE }, { "d-var-info-short", E_REFUSE },
   { "d-ok", E_WORKS }, { "d-consecutive-ok", E_WORKS }, { "d-copy-ok", E_WORKS }, { "d-inline-ok", E_WORKS },
   { "d-binding-oob", E_REFUSE }, { "d-binding-far", E_REFUSE }, { "d-elem-far", E_REFUSE },
   { "d-elem-next", E_REFUSE }, { "d-type-mismatch", E_REFUSE }, { "d-null-sampler", E_REFUSE },
   { "d-null-view", E_REFUSE }, { "d-null-view-nd", E_WORKS }, { "d-null-buffer", E_REFUSE },
   { "d-null-buffer-nd", E_WORKS }, { "d-range-past", E_REFUSE }, { "d-offset-past-whole", E_REFUSE },
   { "d-dyn-elem-far", E_REFUSE }, { "d-inline-far", E_REFUSE }, { "d-inline-size", E_REFUSE },
   { "d-copy-far", E_REFUSE },
   /* command recording */
   { "c-ok", E_WORKS }, { "c-push-max", E_WORKS }, { "c-push-far", E_REFUSE }, { "c-push-near", E_REFUSE },
   { "c-push-wrap", E_REFUSE }, { "c-push2-far", E_REFUSE },
   { "c-viewport-max", E_WORKS }, { "c-viewport-over", E_REFUSE }, { "c-viewport-far", E_REFUSE },
   { "c-scissor-far", E_REFUSE }, { "c-blend-enable-far", E_REFUSE },
   { "c-vbuf-max", E_WORKS }, { "c-vbuf-first-far", E_REFUSE }, { "c-vbuf-offset-past", E_REFUSE },
   { "c-vbuf-null", E_REFUSE }, { "c-vbuf-null-nd", E_WORKS },
   { "c-ibuf-ok", E_WORKS }, { "c-ibuf-type-bad", E_REFUSE }, { "c-ibuf-offset-past", E_REFUSE },
   { "c-sets-ok", E_WORKS }, { "c-sets-max", E_WORKS }, { "c-sets-first-far", E_REFUSE },
   { "c-sets2-first-far", E_REFUSE }, { "c-dyn-offsets-many", E_REFUSE }, { "c-sets-fewer-offsets", E_REFUSE },
   { "c-sets-layout-mismatch", E_REFUSE },
   { "c-push-set-ok", E_WORKS }, { "c-push-set-oob", E_REFUSE }, { "c-push-set-not-push", E_REFUSE },
   { "c-push-set-binding-far", E_REFUSE },
   { "c-copy-buffer-ok", E_WORKS }, { "c-copy-buffer-past", E_REFUSE }, { "c-copy-buffer-far", E_REFUSE },
   { "c-copy-buffer-wrap", E_REFUSE }, { "c-copy-b2i-ok", E_WORKS }, { "c-copy-b2i-level", E_REFUSE },
   { "c-copy-image-ok", E_WORKS }, { "c-copy-image-layer", E_REFUSE },
   { "c-blit-ok", E_WORKS }, { "c-blit-level", E_REFUSE }, { "c-blit-layers", E_REFUSE },
   { "c-clear-color-remaining", E_WORKS }, { "c-clear-color-range", E_REFUSE },
   { "c-fill-whole", E_WORKS }, { "c-fill-past", E_REFUSE }, { "c-update-past", E_REFUSE },
   { "c-update-big", E_REFUSE },
   { "c-query-copy-ok", E_WORKS }, { "c-query-reset-far", E_REFUSE }, { "c-query-begin-far", E_REFUSE },
   { "c-query-timestamp-far", E_REFUSE }, { "c-query-copy-past", E_REFUSE },
   { "c-draw-indirect-ok", E_WORKS }, { "c-draw-indirect-past", E_REFUSE },
   { "c-dispatch-max", E_WORKS }, { "c-dispatch-max-xyz", E_WORKS }, { "c-dispatch-huge", E_REFUSE }, { "c-dispatch-indirect-past", E_REFUSE },
   { "c-drawmulti-ok", E_WORKS }, { "c-drawmulti-stride", E_WORKS }, { "c-drawmulti-null", E_REFUSE },
   { "c-clear-att-ok", E_WORKS }, { "c-clear-att-over", E_REFUSE }, { "c-clear-att-far", E_REFUSE },
   { "c-barrier-remaining", E_WORKS }, { "c-barrier-range", E_REFUSE }, { "c-barrier2-range", E_REFUSE },
   { "c-enum-ok", E_WORKS }, { "c-enum-cull", E_REFUSE }, { "c-enum-compare", E_REFUSE },
   { "c-enum-topology", E_REFUSE }, { "c-enum-stencil", E_REFUSE }, { "c-enum-logicop", E_REFUSE },
   { "c-bind-point-bad", E_REFUSE }, { "c-bind-wrong-point", E_REFUSE },
   { "c-sample-locations-ok", E_WORKS }, { "c-sample-locations-far", E_REFUSE },
   { "c-att-locations-max", E_WORKS }, { "c-att-locations-far", E_REFUSE }, { "c-input-indices-far", E_REFUSE },
   { "c-inherit-ok", E_WORKS }, { "c-inherit-colors-over", E_REFUSE }, { "c-inherit-locations-far", E_REFUSE },
   { "c-execute-ok", E_WORKS }, { "c-execute-primary", E_REFUSE }, { "c-execute-in-secondary", E_REFUSE },
   { "c-nested-self", E_REFUSE },
   /* host query calls, query pools */
   { "q-ok", E_WORKS }, { "q-reset-ok", E_WORKS }, { "q-pool-large", E_KEEP }, { "q-results-first-far", E_REFUSE },
   { "q-results-stride", E_REFUSE }, { "q-reset-far", E_REFUSE }, { "q-pool-type-bad", E_REFUSE },
   { "q-pool-huge", E_REFUSE },
};
#define N_CASES (sizeof(cases) / sizeof(cases[0]))

static int run_case(const char *c)
{
   switch (c[0]) {
   case 'p': return case_pipeline(c);
   case 'r': return case_render_pass(c);
   case 'd': return case_descriptor(c);
   case 'c': return case_command(c);
   case 'q': return case_query(c);
   default: return BROKEN;
   }
}

/* ---------------- --time: microseconds per command through vkr ---------------- */
static double since(const struct timespec *t0)
{
   struct timespec t1;
   clock_gettime(CLOCK_MONOTONIC, &t1);
   return ((t1.tv_sec - t0->tv_sec) * 1e9 + (t1.tv_nsec - t0->tv_nsec)) / 1e3;
}

static int time_commands(int n)
{
   setup(0);
   struct world w = { 0 };
   make_world(&w, true);
   begin(w.cmd);
   const VkCommandBuffer cb = (VkCommandBuffer)w.cmd;
   static uint8_t data[64];
   struct timespec t0;
   double us[5];

   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      struct vn_command_vkCmdPushConstants p = { .commandBuffer = cb, .layout = (VkPipelineLayout)w.layout,
                                                 .stageFlags = VK_SHADER_STAGE_ALL, .offset = 0, .size = 64,
                                                 .pValues = data };
      D->dispatch_vkCmdPushConstants(D, &p);
   }
   us[0] = since(&t0) / n;
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      VkViewport vp = { 0, 0, 64, 64, 0, 1 };
      struct vn_command_vkCmdSetViewport v = { .commandBuffer = cb, .viewportCount = 1, .pViewports = &vp };
      D->dispatch_vkCmdSetViewport(D, &v);
   }
   us[1] = since(&t0) / n;
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      VkDescriptorBufferInfo bi = { (VkBuffer)w.buf, 0, 256 };
      VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)w.set,
                                  .dstBinding = 0, .descriptorCount = 1,
                                  .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &bi };
      struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = 1,
                                                     .pDescriptorWrites = &wr };
      D->dispatch_vkUpdateDescriptorSets(D, &u);
   }
   us[2] = since(&t0) / n;
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      VkDescriptorSet s = (VkDescriptorSet)w.set;
      const uint32_t off = 0;
      struct vn_command_vkCmdBindDescriptorSets b = {
         .commandBuffer = cb, .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
         .layout = (VkPipelineLayout)w.layout, .firstSet = 0, .descriptorSetCount = 1, .pDescriptorSets = &s,
         .dynamicOffsetCount = 1, .pDynamicOffsets = &off };
      D->dispatch_vkCmdBindDescriptorSets(D, &b);
   }
   us[3] = since(&t0) / n;
   begin_pass(w.cmd, w.rp, w.fb, 64, 64);
   bind_pipeline(w.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w.gfx_pipe);
   ready(w.cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      struct vn_command_vkCmdDraw d = { .commandBuffer = cb, .vertexCount = 3, .instanceCount = 1 };
      D->dispatch_vkCmdDraw(D, &d);
   }
   us[4] = since(&t0) / n;
   if (ended()) {
      printf("timing: the context ended while timing\n");
      return 1;
   }
   printf("timing: %d each, us per call through vkr: vkCmdPushConstants %.3f, vkCmdSetViewport %.3f, "
          "vkUpdateDescriptorSets %.3f, vkCmdBindDescriptorSets %.3f, vkCmdDraw %.3f\n",
          n, us[0], us[1], us[2], us[3], us[4]);
   fflush(stdout);
   _exit(0); /* nothing submitted, nothing destroyed */
}

/* ---------------- the parent: one child per case ---------------- */
static const char *outcome_name(int status)
{
   switch (status) {
   case WORKS: return "works";
   case ERROR: return "a VkResult error";
   case FATAL: return "the context ended";
   case SKIP: return "skipped";
   default: return "broken";
   }
}

static bool log_has(const char *path, const char *needle, char *line_out, size_t n)
{
   FILE *f = fopen(path, "r");
   char line[1024];
   bool found = false;
   while (f && !found && fgets(line, sizeof(line), f)) {
      if (strstr(line, needle)) {
         found = true;
         if (line_out)
            snprintf(line_out, n, "%s", line);
      }
   }
   if (f)
      fclose(f);
   return found;
}

int main(int argc, char **argv)
{
   setvbuf(stdout, NULL, _IOLBF, 0);
   if (argc == 2 && !strcmp(argv[1], "--list")) {
      for (size_t i = 0; i < N_CASES; i++)
         printf("%s\n", cases[i].name);
      return 0;
   }
   if (argc == 3 && !strcmp(argv[1], "--time"))
      return time_commands(atoi(argv[2]));
   if (argc == 2 && !strcmp(argv[1], "driver")) {
      instance_and_physical_device();
      printf("maxMultiviewViewCount told to the guest: %u\n", max_views);
      _exit(kosmickrisp ? ERROR : WORKS);
   }
   if (argc == 2) {
      const int status = run_case(argv[1]);
      printf("case end: %s\n", outcome_name(status));
      fflush(stdout);
      _exit(status); /* nothing destroyed, nothing submitted */
   }

   pid_t pid;
   int status;
   const char *driver_args[] = { argv[0], "driver", NULL };
   if (posix_spawn(&pid, argv[0], NULL, NULL, (char **)driver_args, environ) || waitpid(pid, &status, 0) < 0 ||
       !WIFEXITED(status) || (WEXITSTATUS(status) != WORKS && WEXITSTATUS(status) != ERROR)) {
      printf("FAIL: no Venus device to test\n");
      return 1;
   }
   const bool kk = WEXITSTATUS(status) == ERROR;
   const char *only = getenv("VENUS_COMMANDS_CASES");
   char log[] = "/tmp/venus-commands.XXXXXX";
   const int log_fd = mkstemp(log);
   if (log_fd < 0) {
      printf("FAIL: no file for the cases' output\n");
      return 1;
   }
   close(log_fd);
   int failures = 0, skipped = 0, run = 0;
   for (size_t i = 0; i < N_CASES; i++) {
      const struct test_case *tc = &cases[i];
      if (only) {
         char pad[128], hay[8192];
         snprintf(pad, sizeof(pad), " %s ", tc->name);
         snprintf(hay, sizeof(hay), " %s ", only);
         if (!strstr(hay, pad))
            continue;
      }
      run++;
      posix_spawn_file_actions_t fa;
      posix_spawn_file_actions_init(&fa);
      posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0600);
      posix_spawn_file_actions_adddup2(&fa, 1, 2);
      const char *args[] = { argv[0], tc->name, NULL };
      const int spawned = posix_spawn(&pid, argv[0], &fa, NULL, (char **)args, environ);
      posix_spawn_file_actions_destroy(&fa);
      if (spawned) {
         printf("FAIL: %s: not started\n", tc->name);
         failures++;
         continue;
      }
      /* a child that runs away (a host allocation a guest value asked for) is stopped */
      const char *why = NULL;
      for (int ms = 0;; ms += 20) {
         if (waitpid(pid, &status, WNOHANG) == pid)
            break;
         struct rusage_info_v4 ri;
         if (!why && !proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) &&
             ri.ri_phys_footprint > (1536ull << 20)) {
            why = "stopped at 1.5 GB";
            kill(pid, SIGKILL);
         }
         if (!why && ms > 60000) {
            why = "stopped after 60 s";
            kill(pid, SIGKILL);
         }
         usleep(20000);
      }
      char seen[96];
      int got = -1;
      if (why) {
         snprintf(seen, sizeof(seen), "%s", why);
      } else if (WIFSIGNALED(status)) {
         snprintf(seen, sizeof(seen), "the process ended (signal %d)", WTERMSIG(status));
      } else {
         got = WEXITSTATUS(status);
         snprintf(seen, sizeof(seen), "%s", outcome_name(got));
      }
      int want = tc->expect;
      if (want == E_CHILD)
         want = log_has(log, "expect: refuse", NULL, 0) ? E_REFUSE : E_WORKS;
      char refusal[1024] = "";
      const bool refused_line = log_has(log, " refused: ", refusal, sizeof(refusal));
      bool ok;
      if (got == SKIP) {
         ok = true;
         skipped++;
      } else if (want == E_REFUSE) {
         ok = got == FATAL && refused_line;
      } else if (want == E_WORKS) {
         ok = got == WORKS && !refused_line;
      } else {
         ok = (got == WORKS || got == ERROR) && !refused_line;
      }
      printf("%s: %s: %s%s\n", ok ? "ok" : "FAIL", tc->name, seen,
             want == E_REFUSE ? "" : refused_line ? " (refused where it must work)" : "");
      if (ok && want == E_REFUSE && got == FATAL) {
         const char *r = strstr(refusal, "vkr: ");
         printf("   %s", r ? r : refusal);
      }
      if (!ok) {
         char line[1024];
         FILE *f = fopen(log, "r");
         while (f && fgets(line, sizeof(line), f))
            printf("   | %s", line);
         if (f)
            fclose(f);
      }
      failures += !ok;
   }
   unlink(log);
   printf("%s: %d cases (%d skipped) on %s\n", failures ? "FAILED" : "all ok", run, skipped,
          kk ? "KosmicKrisp" : "MoltenVK");
   return failures != 0;
}
