/* The Mac's Vulkan driver never gets from Venus what it (Metal under it) ends the
 * process on (virgl-venus-linear-modifier-usage.patch, virgl-venus-image-limits.patch,
 * virgl-venus-view-limits.patch; ADR 0065).
 *
 * A real vkr context on the runtime's real driver. Every case goes through vkr's own
 * dispatch functions (ctx->dispatch, where the decoder hands over guest commands), with
 * arguments shaped as the decoder makes them: existing objects as vkr object pointers,
 * new ones named by an id. Each case runs in its own child process, so a driver that
 * ends the process ends that child only. Without the patches the probe cases end their
 * child (Zink's linear render target on KosmicKrisp first, #598) or reach the driver;
 * with them each is refused (an error, zeros, or the end of the app's context) and the
 * must-keep cases still create, bind and view. Object creation, queries and binds only:
 * no command buffer, nothing runs on the GPU (standards 14).
 *
 *   test-venus-image-limits              every case, one child each, then a summary
 *   test-venus-image-limits CASE         one case (what the children run)
 *   test-venus-image-limits --time N     microseconds per vkCreateImage through vkr
 *
 * The driver is vkr's choice from OMACVM_VULKAN_DRIVER (virgl-darwin-vulkan-beside.patch):
 * the binary sits in a lib/ folder beside the runtime's libvulkan.1.dylib and drivers,
 * with share/vulkan/icd.d next to it, as libvirglrenderer does in QEMU's runtime.
 * run-venus-limits.py builds that folder and runs this once per driver. */
#include <inttypes.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "vkr_buffer.h"
#include "vkr_context.h"
#include "vkr_device.h"
#include "vkr_device_memory.h"
#include "vkr_image.h"
#include "vkr_instance.h"
#include "vkr_physical_device.h"
#include "vkr_renderer.h"

extern char **environ;

/* what a case saw: the child's exit status */
enum { WORKS = 10, REFUSED = 11, FATAL = 12, SKIP = 13, BROKEN = 2 };
/* what a case must see */
enum { E_WORKS, E_REFUSED, E_FATAL, E_NOT_WORKS, E_REFUSED_KK };

static struct vkr_context *ctx;
static struct vn_dispatch_context *D;
static struct vkr_physical_device *pdev;
static struct vkr_device *dev;
static uint64_t next_id = 100;
static VkPhysicalDeviceProperties props;

#define S VK_IMAGE_USAGE_SAMPLED_BIT
#define TS VK_IMAGE_USAGE_TRANSFER_SRC_BIT
#define TD VK_IMAGE_USAGE_TRANSFER_DST_BIT
#define CA VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
#define IA VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT
#define ST VK_IMAGE_USAGE_STORAGE_BIT
#define BGRA VK_FORMAT_B8G8R8A8_UNORM
#define LIN VK_IMAGE_TILING_LINEAR
#define OPT VK_IMAGE_TILING_OPTIMAL
#define DRM VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT

static void broken(const char *what)
{
   printf("test setup: %s\n", what);
   exit(BROKEN);
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

/* instance, physical device and device through vkr's dispatch, as a guest makes them */
static void setup(void)
{
   static const struct vkr_renderer_callbacks cbs = { .retire_fence = retire };
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
   struct vkr_instance *instance = object(1);
   if (ci.ret != VK_SUCCESS || !instance)
      broken("vkCreateInstance");

   uint32_t count = 1;
   VkPhysicalDevice pdev_id = (VkPhysicalDevice)(uintptr_t)2;
   struct vn_command_vkEnumeratePhysicalDevices ep = {
      .instance = (VkInstance)instance, .pPhysicalDeviceCount = &count,
      .pPhysicalDevices = &pdev_id };
   D->dispatch_vkEnumeratePhysicalDevices(D, &ep);
   pdev = object(2);
   if ((ep.ret != VK_SUCCESS && ep.ret != VK_INCOMPLETE) || !pdev)
      broken("vkEnumeratePhysicalDevices");
   props = pdev->properties;

   const float priority = 1;
   const VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                       .queueCount = 1, .pQueuePriorities = &priority };
   const VkPhysicalDeviceFeatures features = { .samplerAnisotropy = VK_TRUE };
   /* vkGetDeviceImageSubresourceLayout and vkGetImageSubresourceLayout2 on a 1.3 driver */
   const char *maintenance5 = VK_KHR_MAINTENANCE_5_EXTENSION_NAME;
   bool has_maintenance5 = false;
   for (uint32_t i = 0; i < pdev->extension_count; i++)
      has_maintenance5 |= !strcmp(pdev->extensions[i].extensionName, maintenance5);
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
                              .enabledExtensionCount = has_maintenance5,
                              .ppEnabledExtensionNames = &maintenance5,
                              .pEnabledFeatures = &features };
   VkDevice device_id = (VkDevice)(uintptr_t)3;
   struct vn_command_vkCreateDevice cd = { .physicalDevice = (VkPhysicalDevice)pdev,
                                           .pCreateInfo = &dci, .pDevice = &device_id };
   D->dispatch_vkCreateDevice(D, &cd);
   dev = object(3);
   if (cd.ret != VK_SUCCESS || !dev)
      broken("vkCreateDevice");
}

static VkImageCreateInfo image_info(VkFormat format, VkImageTiling tiling, VkImageUsageFlags usage)
{
   return (VkImageCreateInfo){
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
      .format = format, .extent = { 64, 64, 1 }, .mipLevels = 1, .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = tiling, .usage = usage,
   };
}

/* vkCreateImage as the guest sends it; the vkr image, or NULL with *ret set */
static struct vkr_image *create_image(const VkImageCreateInfo *info, VkResult *ret)
{
   const uint64_t id = next_id++;
   VkImage handle = (VkImage)(uintptr_t)id;
   VkImageCreateInfo copy = *info; /* vkr changes the decoder's copy */
   struct vn_command_vkCreateImage a = { .device = (VkDevice)dev, .pCreateInfo = &copy,
                                         .pImage = &handle };
   printf("vkCreateImage ...\n");
   D->dispatch_vkCreateImage(D, &a);
   printf("vkCreateImage = %d\n", a.ret);
   *ret = a.ret;
   return a.ret == VK_SUCCESS ? object(id) : NULL;
}

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags want)
{
   const VkPhysicalDeviceMemoryProperties *mp = &pdev->memory_properties;
   for (uint32_t i = 0; i < mp->memoryTypeCount; i++)
      if ((bits & (1u << i)) && (mp->memoryTypes[i].propertyFlags & want) == want)
         return i;
   for (uint32_t i = 0; i < mp->memoryTypeCount; i++)
      if (bits & (1u << i))
         return i;
   return 0;
}

static struct vkr_device_memory *allocate(VkDeviceSize size, uint32_t type)
{
   const uint64_t id = next_id++;
   VkDeviceMemory handle = (VkDeviceMemory)(uintptr_t)id;
   VkMemoryAllocateInfo info = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 .allocationSize = size, .memoryTypeIndex = type };
   struct vn_command_vkAllocateMemory a = { .device = (VkDevice)dev, .pAllocateInfo = &info,
                                            .pMemory = &handle };
   D->dispatch_vkAllocateMemory(D, &a);
   printf("vkAllocateMemory(%" PRIu64 ", type %u) = %d\n", size, type, a.ret);
   return a.ret == VK_SUCCESS ? object(id) : NULL;
}

static VkMemoryRequirements image_requirements(struct vkr_image *image)
{
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetImageMemoryRequirements a = {
      .device = (VkDevice)dev, .image = (VkImage)image, .pMemoryRequirements = &req };
   D->dispatch_vkGetImageMemoryRequirements(D, &a);
   return req;
}

static VkResult bind_image(struct vkr_image *image, struct vkr_device_memory *mem,
                           VkDeviceSize offset, const void *next)
{
   VkBindImageMemoryInfo info = { .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
                                  .pNext = next, .image = (VkImage)image,
                                  .memory = (VkDeviceMemory)mem, .memoryOffset = offset };
   struct vn_command_vkBindImageMemory2 a = { .device = (VkDevice)dev, .bindInfoCount = 1,
                                              .pBindInfos = &info };
   printf("vkBindImageMemory2(offset %" PRIu64 ") ...\n", offset);
   D->dispatch_vkBindImageMemory2(D, &a);
   printf("vkBindImageMemory2 = %d%s\n", a.ret, vkr_context_get_fatal(ctx) ? " (context ended)" : "");
   return a.ret;
}

/* create, allocate what it asks for (+ extra) and bind at offset: what the guest does */
static int image_case(VkImageCreateInfo info, VkDeviceSize extra, VkDeviceSize offset,
                      VkDeviceSize memory_size)
{
   VkResult ret;
   struct vkr_image *image = create_image(&info, &ret);
   if (!image)
      return ret == VK_ERROR_FORMAT_NOT_SUPPORTED && !vkr_context_get_fatal(ctx) ? REFUSED
                                                                                   : BROKEN;
   const VkMemoryRequirements req = image_requirements(image);
   printf("requirements: size %" PRIu64 " alignment %" PRIu64 " types 0x%x\n", req.size,
          req.alignment, req.memoryTypeBits);
   struct vkr_device_memory *mem = allocate(
      memory_size ? memory_size : req.size + extra,
      memory_type(req.memoryTypeBits, info.tiling == LIN ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT : 0));
   if (!mem)
      return BROKEN;
   ret = bind_image(image, mem, offset, NULL);
   if (vkr_context_get_fatal(ctx))
      return FATAL;
   return ret == VK_SUCCESS ? WORKS : BROKEN;
}

static int create_case(VkImageCreateInfo info)
{
   return image_case(info, 0, 0, 0);
}

/* the emulated LINEAR DRM modifier with a dma-buf, as Mesa's WSI and Zink ask for it */
static int modifier_case(VkImageUsageFlags usage)
{
   static const uint64_t linear = 0; /* DRM_FORMAT_MOD_LINEAR */
   VkImageDrmFormatModifierListCreateInfoEXT list = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
      .drmFormatModifierCount = 1, .pDrmFormatModifiers = &linear };
   VkExternalMemoryImageCreateInfo ext = {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO, .pNext = &list,
      .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT };
   VkImageCreateInfo info = image_info(BGRA, DRM, usage);
   info.pNext = &ext;
   return create_case(info);
}

/* the host's own limits for a format (the maximum passes, one more is refused) */
static VkImageFormatProperties host_limits(VkFormat format, VkImageType type, VkImageUsageFlags usage)
{
   VkImageFormatProperties p = { 0 };
   pdev->proc_table.GetPhysicalDeviceImageFormatProperties(
      pdev->base.handle.physical_device, format, type, OPT, usage, 0, &p);
   return p;
}

/* vkGetPhysicalDeviceImageFormatProperties2 as the guest asks */
static int query_case(VkFormat format, VkImageType type, VkImageTiling tiling,
                      VkImageUsageFlags usage, const void *next)
{
   VkPhysicalDeviceImageFormatInfo2 info = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .pNext = next,
      .format = format, .type = type, .tiling = tiling, .usage = usage };
   VkImageFormatProperties2 out = { .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 };
   struct vn_command_vkGetPhysicalDeviceImageFormatProperties2 a = {
      .physicalDevice = (VkPhysicalDevice)pdev, .pImageFormatInfo = &info,
      .pImageFormatProperties = &out };
   printf("vkGetPhysicalDeviceImageFormatProperties2 ...\n");
   D->dispatch_vkGetPhysicalDeviceImageFormatProperties2(D, &a);
   printf("vkGetPhysicalDeviceImageFormatProperties2 = %d (max levels %u)\n", a.ret,
          out.imageFormatProperties.maxMipLevels);
   if (vkr_context_get_fatal(ctx))
      return FATAL;
   return a.ret == VK_SUCCESS ? WORKS : a.ret == VK_ERROR_FORMAT_NOT_SUPPORTED ? REFUSED : BROKEN;
}

static int zink_query_case(void)
{
   VkPhysicalDeviceImageDrmFormatModifierInfoEXT mod = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
      .drmFormatModifier = 0 };
   return query_case(BGRA, VK_IMAGE_TYPE_2D, DRM, S | TS | TD | CA | IA, &mod);
}

static int sparse_case(VkSampleCountFlagBits samples)
{
   VkPhysicalDeviceSparseImageFormatInfo2 info = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SPARSE_IMAGE_FORMAT_INFO_2, .format = BGRA,
      .type = VK_IMAGE_TYPE_2D, .samples = samples, .usage = S, .tiling = OPT };
   uint32_t count = 99;
   struct vn_command_vkGetPhysicalDeviceSparseImageFormatProperties2 a = {
      .physicalDevice = (VkPhysicalDevice)pdev, .pFormatInfo = &info, .pPropertyCount = &count };
   D->dispatch_vkGetPhysicalDeviceSparseImageFormatProperties2(D, &a);
   printf("sparse properties: %u\n", count);
   return count ? WORKS : REFUSED;
}

/* vkGetDeviceImageMemoryRequirements: size 0 = refused */
static int devreq_case(VkImageCreateInfo info)
{
   VkDeviceImageMemoryRequirements dr = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_IMAGE_MEMORY_REQUIREMENTS, .pCreateInfo = &info };
   VkMemoryRequirements2 mr = { .sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2 };
   struct vn_command_vkGetDeviceImageMemoryRequirements a = {
      .device = (VkDevice)dev, .pInfo = &dr, .pMemoryRequirements = &mr };
   printf("vkGetDeviceImageMemoryRequirements ...\n");
   D->dispatch_vkGetDeviceImageMemoryRequirements(D, &a);
   printf("size %" PRIu64 "\n", mr.memoryRequirements.size);
   return mr.memoryRequirements.size ? WORKS : REFUSED;
}

static int devreq_modifier_case(VkImageUsageFlags usage)
{
   static const uint64_t linear = 0;
   VkImageDrmFormatModifierListCreateInfoEXT list = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
      .drmFormatModifierCount = 1, .pDrmFormatModifiers = &linear };
   VkImageCreateInfo info = image_info(BGRA, DRM, usage);
   info.pNext = &list;
   return devreq_case(info);
}

static int devlayout_case(uint32_t level)
{
   VkImageCreateInfo info = image_info(BGRA, LIN, S | TS | TD);
   VkImageSubresource2 sub = { .sType = VK_STRUCTURE_TYPE_IMAGE_SUBRESOURCE_2,
                               .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, level, 0 } };
   VkDeviceImageSubresourceInfo di = { .sType = VK_STRUCTURE_TYPE_DEVICE_IMAGE_SUBRESOURCE_INFO,
                                       .pCreateInfo = &info, .pSubresource = &sub };
   VkSubresourceLayout2 out = { .sType = VK_STRUCTURE_TYPE_SUBRESOURCE_LAYOUT_2 };
   struct vn_command_vkGetDeviceImageSubresourceLayout a = { .device = (VkDevice)dev,
                                                             .pInfo = &di, .pLayout = &out };
   D->dispatch_vkGetDeviceImageSubresourceLayout(D, &a);
   printf("row pitch %" PRIu64 "\n", out.subresourceLayout.rowPitch);
   return out.subresourceLayout.rowPitch ? WORKS : REFUSED;
}

/* a made and bound image, for the bind, layout and view cases */
static struct vkr_image *made_image(VkImageCreateInfo info)
{
   VkResult ret;
   struct vkr_image *image = create_image(&info, &ret);
   if (!image)
      broken("the case's image was not made");
   const VkMemoryRequirements req = image_requirements(image);
   struct vkr_device_memory *mem = allocate(
      req.size, memory_type(req.memoryTypeBits,
                            info.tiling == LIN ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT : 0));
   if (!mem || bind_image(image, mem, 0, NULL) != VK_SUCCESS)
      broken("the case's image was not bound");
   return image;
}

static int layout_case(VkImageAspectFlags aspect, uint32_t level, uint32_t layer, int modifier)
{
   struct vkr_image *image;
   if (modifier) {
      static const uint64_t linear = 0;
      VkImageDrmFormatModifierListCreateInfoEXT list = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
         .drmFormatModifierCount = 1, .pDrmFormatModifiers = &linear };
      VkImageCreateInfo info = image_info(BGRA, DRM, S | TS | TD | CA);
      info.pNext = &list;
      image = made_image(info);
   } else {
      image = made_image(image_info(BGRA, LIN, S | TS | TD));
   }
   const VkImageSubresource sub = { aspect, level, layer };
   VkSubresourceLayout out = { 0 };
   struct vn_command_vkGetImageSubresourceLayout a = {
      .device = (VkDevice)dev, .image = (VkImage)image, .pSubresource = &sub, .pLayout = &out };
   printf("vkGetImageSubresourceLayout(aspect 0x%x level %u layer %u) ...\n", aspect, level, layer);
   D->dispatch_vkGetImageSubresourceLayout(D, &a);
   printf("row pitch %" PRIu64 "\n", out.rowPitch);
   return out.rowPitch ? WORKS : REFUSED;
}

static int reqs_plane_case(void)
{
   struct vkr_image *image = made_image(image_info(BGRA, OPT, S));
   VkImagePlaneMemoryRequirementsInfo plane = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_PLANE_MEMORY_REQUIREMENTS_INFO,
      .planeAspect = VK_IMAGE_ASPECT_PLANE_1_BIT };
   VkImageMemoryRequirementsInfo2 info = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2,
                                           .pNext = &plane, .image = (VkImage)image };
   VkMemoryRequirements2 out = { .sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2 };
   struct vn_command_vkGetImageMemoryRequirements2 a = {
      .device = (VkDevice)dev, .pInfo = &info, .pMemoryRequirements = &out };
   D->dispatch_vkGetImageMemoryRequirements2(D, &a);
   printf("size %" PRIu64 "\n", out.memoryRequirements.size);
   return out.memoryRequirements.size ? WORKS : REFUSED;
}

/* binds the guest must not make: past the end, unaligned, too small, another memory type */
static int bind_case(const char *kind)
{
   /* 256 KB: a quarter of it is still more than vkr's page rounding of an allocation */
   VkImageCreateInfo info = image_info(BGRA, LIN, S | TS | TD);
   info.extent = (VkExtent3D){ 256, 256, 1 };
   VkResult ret;
   struct vkr_image *image = create_image(&info, &ret);
   if (!image)
      broken("the case's image was not made");
   const VkMemoryRequirements req = image_requirements(image);
   const uint32_t type = memory_type(req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
   struct vkr_device_memory *mem = NULL;
   VkDeviceSize offset = 0;
   VkBindImagePlaneMemoryInfo plane = { .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_PLANE_MEMORY_INFO,
                                        .planeAspect = VK_IMAGE_ASPECT_PLANE_0_BIT };
   const void *next = NULL;
   if (!strcmp(kind, "past-end")) {
      mem = allocate(req.size, type);
      offset = req.alignment;
   } else if (!strcmp(kind, "unaligned")) {
      mem = allocate(req.size + 2 * req.alignment, type);
      offset = req.alignment > 8 ? req.alignment / 2 : 4;
   } else if (!strcmp(kind, "small")) {
      mem = allocate(req.size / 4, type);
   } else if (!strcmp(kind, "plane-info")) {
      mem = allocate(req.size, type);
      next = &plane;
   } else if (!strcmp(kind, "wrong-type")) {
      uint32_t t = 0;
      while (t < pdev->memory_properties.memoryTypeCount && (req.memoryTypeBits & (1u << t)))
         t++;
      if (t == pdev->memory_properties.memoryTypeCount) {
         printf("skip: every memory type fits (0x%x)\n", req.memoryTypeBits);
         return SKIP;
      }
      mem = allocate(req.size, t);
   }
   if (!mem)
      broken("no memory for the case");
   ret = bind_image(image, mem, offset, next);
   if (vkr_context_get_fatal(ctx))
      return FATAL;
   return ret == VK_SUCCESS ? WORKS : BROKEN;
}

static int disjoint_case(void)
{
   VkImageCreateInfo info = image_info(VK_FORMAT_G8_B8R8_2PLANE_420_UNORM, OPT, S);
   info.flags = VK_IMAGE_CREATE_DISJOINT_BIT;
   VkResult ret;
   struct vkr_image *image = create_image(&info, &ret);
   if (!image)
      return REFUSED;
   struct vkr_device_memory *mem = allocate(1 << 20, 0);
   if (!mem)
      broken("no memory for the case");
   ret = bind_image(image, mem, 0, NULL);
   return vkr_context_get_fatal(ctx) ? FATAL : ret == VK_SUCCESS ? WORKS : BROKEN;
}

/* vkCreateImageView of an image made from info */
static int view_case(VkImageCreateInfo info, VkImageViewType type, VkFormat format,
                     VkImageSubresourceRange range)
{
   struct vkr_image *image = made_image(info);
   VkImageViewCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                                .image = (VkImage)image, .viewType = type, .format = format,
                                .subresourceRange = range };
   const uint64_t id = next_id++;
   VkImageView handle = (VkImageView)(uintptr_t)id;
   struct vn_command_vkCreateImageView a = { .device = (VkDevice)dev, .pCreateInfo = &vi,
                                             .pView = &handle };
   printf("vkCreateImageView ...\n");
   D->dispatch_vkCreateImageView(D, &a);
   printf("vkCreateImageView = %d%s\n", a.ret, vkr_context_get_fatal(ctx) ? " (context ended)" : "");
   if (vkr_context_get_fatal(ctx))
      return FATAL;
   return a.ret == VK_SUCCESS && object(id) ? WORKS : BROKEN;
}

#define COLOR(base_level, levels, base_layer, layers)                                       \
   ((VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, base_level, levels, base_layer, layers })

static VkImageCreateInfo with(VkImageCreateInfo info, VkImageCreateFlags flags, uint32_t layers,
                              uint32_t depth)
{
   info.flags = flags;
   info.arrayLayers = layers;
   if (depth > 1) {
      info.imageType = VK_IMAGE_TYPE_3D;
      info.extent.depth = depth;
   }
   return info;
}

/* a texel buffer view of a bound buffer */
static int texel_case(VkBufferUsageFlags usage, VkDeviceSize size, VkFormat format,
                      VkDeviceSize offset, VkDeviceSize range)
{
   const uint64_t id = next_id++;
   VkBuffer handle = (VkBuffer)(uintptr_t)id;
   VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                             .usage = usage };
   struct vn_command_vkCreateBuffer cb = { .device = (VkDevice)dev, .pCreateInfo = &bi,
                                           .pBuffer = &handle };
   D->dispatch_vkCreateBuffer(D, &cb);
   struct vkr_buffer *buffer = object(id);
   if (cb.ret != VK_SUCCESS || !buffer)
      broken("vkCreateBuffer");
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetBufferMemoryRequirements gr = {
      .device = (VkDevice)dev, .buffer = (VkBuffer)buffer, .pMemoryRequirements = &req };
   D->dispatch_vkGetBufferMemoryRequirements(D, &gr);
   struct vkr_device_memory *mem = allocate(req.size, memory_type(req.memoryTypeBits, 0));
   if (!mem)
      broken("no memory for the buffer");
   struct vn_command_vkBindBufferMemory bb = { .device = (VkDevice)dev, .buffer = (VkBuffer)buffer,
                                               .memory = (VkDeviceMemory)mem };
   D->dispatch_vkBindBufferMemory(D, &bb);
   if (bb.ret != VK_SUCCESS)
      broken("vkBindBufferMemory");
   VkBufferViewCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO,
                                 .buffer = (VkBuffer)buffer, .format = format,
                                 .offset = offset, .range = range };
   const uint64_t view_id = next_id++;
   VkBufferView view = (VkBufferView)(uintptr_t)view_id;
   struct vn_command_vkCreateBufferView a = { .device = (VkDevice)dev, .pCreateInfo = &vi,
                                              .pView = &view };
   printf("vkCreateBufferView(offset %" PRIu64 " range %" PRIu64 ") ...\n", offset, range);
   D->dispatch_vkCreateBufferView(D, &a);
   printf("vkCreateBufferView = %d%s\n", a.ret, vkr_context_get_fatal(ctx) ? " (context ended)" : "");
   if (vkr_context_get_fatal(ctx))
      return FATAL;
   return a.ret == VK_SUCCESS && object(view_id) ? WORKS : BROKEN;
}

static int sampler_case(VkSamplerCreateInfo si)
{
   si.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
   const uint64_t id = next_id++;
   VkSampler handle = (VkSampler)(uintptr_t)id;
   struct vn_command_vkCreateSampler a = { .device = (VkDevice)dev, .pCreateInfo = &si,
                                           .pSampler = &handle };
   printf("vkCreateSampler ...\n");
   D->dispatch_vkCreateSampler(D, &a);
   printf("vkCreateSampler = %d%s\n", a.ret, vkr_context_get_fatal(ctx) ? " (context ended)" : "");
   if (vkr_context_get_fatal(ctx))
      return FATAL;
   return a.ret == VK_SUCCESS && object(id) ? WORKS : BROKEN;
}

static const VkSamplerCreateInfo base_sampler = {
   .magFilter = VK_FILTER_LINEAR, .minFilter = VK_FILTER_LINEAR,
   .mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR,
   .addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT, .addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT,
   .addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT, .maxLod = 4,
   .borderColor = VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
};

/* The driver must never be called for a refused description (the verdict depends on the
 * device and the description only), and the guest's later use of the handle it named
 * ends the context: the guest's Mesa sends a create without waiting when the same
 * description is in its requirements cache. */
static unsigned host_creates, host_binds;
static PFN_vkCreateImage real_create_image;
static PFN_vkBindImageMemory real_bind_image;

static VKAPI_ATTR VkResult VKAPI_CALL counted_create_image(VkDevice d, const VkImageCreateInfo *i,
                                                           const VkAllocationCallbacks *a, VkImage *o)
{
   host_creates++;
   return real_create_image(d, i, a, o);
}

static VKAPI_ATTR VkResult VKAPI_CALL counted_bind_image(VkDevice d, VkImage i, VkDeviceMemory m,
                                                         VkDeviceSize o)
{
   host_binds++;
   return real_bind_image(d, i, m, o);
}

static int refused_then_used_case(void)
{
   real_create_image = dev->proc_table.CreateImage;
   real_bind_image = dev->proc_table.BindImageMemory;
   dev->proc_table.CreateImage = counted_create_image;
   dev->proc_table.BindImageMemory = counted_bind_image;

   VkImageCreateInfo info = image_info(BGRA, OPT, S);
   info.extent = (VkExtent3D){ 1, 1, 1 };
   info.mipLevels = 5;
   VkResult first = VK_SUCCESS, second = VK_SUCCESS;
   const uint64_t id = next_id;
   if (create_image(&info, &first) || create_image(&info, &second) ||
       first != VK_ERROR_FORMAT_NOT_SUPPORTED || second != first) {
      printf("the same description was not refused twice the same way (%d, %d)\n", first, second);
      return BROKEN;
   }
   struct vkr_device_memory *mem = allocate(1 << 16, 0);
   if (!mem)
      broken("no memory for the case");

   /* vkBindImageMemory(device 3, image <first refused id>, memory, 0) as the guest encodes
    * it, through the decoder: the image id names no object */
   struct {
      int32_t type;
      uint32_t flags;
      uint64_t device, image, memory, offset;
   } cmd = { VK_COMMAND_TYPE_vkBindImageMemory_EXT, 0, 3, id, mem->base.id, 0 };
   const bool ok = vkr_context_submit_cmd(ctx, &cmd, sizeof(cmd));
   printf("driver calls: vkCreateImage %u, vkBindImageMemory %u; submit %s, context %s\n",
          host_creates, host_binds, ok ? "ok" : "refused", vkr_context_get_fatal(ctx) ? "ended" : "lives");
   if (host_creates || host_binds || ok)
      return BROKEN;
   return vkr_context_get_fatal(ctx) ? FATAL : BROKEN;
}

struct test_case {
   const char *name;
   int expect;
};

static const struct test_case cases[] = {
   /* the bug and the root cause (#598): Zink's linear render target */
   { "zink-linear", E_REFUSED_KK },
   { "zink-query", E_REFUSED_KK },
   /* must keep working: window buffers, plain linear colour images */
   { "wsi-linear", E_WORKS },
   { "linear-ca", E_WORKS },
   /* image descriptions Metal cannot make */
   { "linear-mip2", E_REFUSED },
   { "linear-layers2", E_REFUSED },
   { "linear-ms4", E_REFUSED },
   { "linear-3d", E_NOT_WORKS },
   { "linear-d32", E_REFUSED },
   { "linear-bc1", E_REFUSED_KK },
   { "mip-too-many", E_REFUSED },
   { "too-wide", E_REFUSED },
   { "unknown-format", E_REFUSED },
   { "bad-type", E_REFUSED },
   { "bad-tiling", E_REFUSED },
   { "drm-no-list", E_REFUSED },
   { "bad-samples", E_REFUSED },
   { "samples-64", E_REFUSED },
   { "zero-extent", E_REFUSED },
   { "zero-layers", E_REFUSED },
   { "2d-depth4", E_REFUSED },
   { "1d-height4", E_REFUSED },
   { "cube-5layers", E_REFUSED },
   { "cube-nonsquare", E_REFUSED },
   { "layers-too-many", E_REFUSED },
   { "3d-too-deep", E_REFUSED },
   { "unknown-flag", E_REFUSED },
   { "usage-0", E_REFUSED },
   /* must keep working: the driver's maximum, ordinary images */
   { "max-wide", E_WORKS },
   { "max-layers", E_WORKS },
   { "opt-2d", E_WORKS },
   { "opt-mips", E_WORKS },
   { "opt-array", E_WORKS },
   { "opt-cube", E_WORKS },
   { "opt-3d", E_WORKS },
   { "opt-ms4", E_WORKS },
   { "opt-d32", E_WORKS },
   { "srgb-storage", E_WORKS },
   { "bc1-block", E_WORKS },
   /* queries that take an image description */
   { "devreq-mip-too-many", E_REFUSED },
   { "devreq-linear-d32", E_REFUSED },
   { "devreq-zink", E_REFUSED_KK },
   { "devreq-wsi", E_WORKS },
   { "devreq-ok", E_WORKS },
   { "devlayout-level", E_REFUSED },
   { "devlayout-ok", E_WORKS },
   { "q-bad-type", E_REFUSED },
   { "q-bad-tiling", E_REFUSED },
   { "q-drm-no-struct", E_REFUSED },
   { "q-ok", E_WORKS },
   { "sparse-bad-samples", E_REFUSED },
   /* binds */
   { "bind-past-end", E_FATAL },
   { "bind-unaligned", E_FATAL },
   { "bind-small", E_FATAL },
   { "bind-plane-info", E_FATAL },
   { "bind-wrong-type", E_FATAL },
   { "bind-disjoint-no-plane", E_NOT_WORKS },
   /* layouts and requirements of a subresource */
   { "layout-plane1", E_REFUSED },
   { "layout-plane2", E_REFUSED },
   { "layout-level5", E_REFUSED },
   { "layout-layer3", E_REFUSED },
   { "layout-ok", E_WORKS },
   { "layout-memory-plane0", E_WORKS },
   { "reqs-plane1", E_REFUSED },
   /* image views */
   { "view-levels", E_FATAL },
   { "view-layers", E_FATAL },
   { "view-cube5", E_FATAL },
   { "view-cubearray8", E_FATAL },
   { "view-format-size", E_FATAL },
   { "view-unknown-format", E_FATAL },
   { "view-bad-type", E_FATAL },
   { "view-3d-of-2d", E_FATAL },
   { "view-3d-levels", E_FATAL },
   { "view-2d-of-3d-slice9", E_FATAL },
   { "view-2d", E_WORKS },
   { "view-remaining", E_WORKS },
   { "view-cube", E_WORKS },
   { "view-cubearray12", E_WORKS },
   { "view-cube-no-flag", E_WORKS },
   { "view-2d-of-3d", E_WORKS },
   { "view-srgb-mutable", E_WORKS },
   { "view-srgb-plain", E_WORKS },
   { "view-r32-mutable", E_WORKS },
   { "view-bc1-block", E_WORKS },
   /* texel buffer views */
   { "tview-wide", E_FATAL },
   { "tview-unknown-format", E_FATAL },
   { "tview-past", E_FATAL },
   { "tview-range-past", E_FATAL },
   { "tview-range-odd", E_FATAL },
   { "tview-no-usage", E_FATAL },
   { "tview-offset4", E_FATAL },
   { "tview-ok", E_WORKS },
   { "tview-min-offset", E_WORKS },
   { "tview-whole", E_WORKS },
   /* samplers */
   { "sampler-bad-filter", E_FATAL },
   { "sampler-bad-address", E_FATAL },
   { "sampler-bad-border", E_FATAL },
   { "sampler-ok", E_WORKS },
   { "sampler-aniso17", E_WORKS },
   { "sampler-lod-huge", E_WORKS },
   /* a refused description: never the driver, its handle's use ends the context */
   { "refused-then-used", E_FATAL },
};

#define IS(n) (!strcmp(name, n))

static int run_case(const char *name)
{
   setup();
   VkImageCreateInfo info = image_info(BGRA, OPT, S);
   VkSamplerCreateInfo si = base_sampler;

   if (IS("zink-linear"))
      return modifier_case(S | TS | TD | CA | IA);
   if (IS("zink-query"))
      return zink_query_case();
   if (IS("wsi-linear"))
      return modifier_case(S | TS | TD | CA);
   if (IS("linear-ca"))
      return create_case(image_info(BGRA, LIN, S | TS | TD | CA));
   if (IS("linear-mip2") || IS("linear-layers2") || IS("linear-3d")) {
      info = image_info(BGRA, LIN, S | TS | TD);
      if (IS("linear-mip2"))
         info.mipLevels = 2;
      else if (IS("linear-layers2"))
         info.arrayLayers = 2;
      else
         info = with(info, 0, 1, 2);
      return create_case(info);
   }
   if (IS("linear-ms4")) {
      info = image_info(BGRA, LIN, S | CA);
      info.samples = VK_SAMPLE_COUNT_4_BIT;
      return create_case(info);
   }
   if (IS("linear-d32"))
      return create_case(image_info(VK_FORMAT_D32_SFLOAT, LIN, S));
   if (IS("linear-bc1"))
      return create_case(image_info(VK_FORMAT_BC1_RGBA_UNORM_BLOCK, LIN, S));
   if (IS("mip-too-many")) {
      info.extent = (VkExtent3D){ 1, 1, 1 };
      info.mipLevels = 5;
      return create_case(info);
   }
   if (IS("too-wide") || IS("max-wide")) {
      const uint32_t max = host_limits(BGRA, VK_IMAGE_TYPE_2D, S).maxExtent.width;
      info.extent = (VkExtent3D){ IS("too-wide") ? max + 1 : max, 1, 1 };
      printf("width %u (the driver's maximum %u)\n", info.extent.width, max);
      return create_case(info);
   }
   if (IS("unknown-format"))
      return create_case(image_info(VK_FORMAT_R64G64B64A64_SFLOAT, OPT, S));
   if (IS("bad-type")) {
      info.imageType = 3;
      return create_case(info);
   }
   if (IS("bad-tiling")) {
      info.tiling = 5;
      return create_case(info);
   }
   if (IS("drm-no-list")) {
      info.tiling = DRM;
      return create_case(info);
   }
   if (IS("bad-samples") || IS("samples-64")) {
      info.usage = CA;
      info.samples = IS("bad-samples") ? 3 : VK_SAMPLE_COUNT_64_BIT;
      return create_case(info);
   }
   if (IS("zero-extent")) {
      info.extent.width = 0;
      return create_case(info);
   }
   if (IS("zero-layers")) {
      info.arrayLayers = 0;
      return create_case(info);
   }
   if (IS("2d-depth4")) {
      info.extent.depth = 4;
      return create_case(info);
   }
   if (IS("1d-height4")) {
      info.imageType = VK_IMAGE_TYPE_1D;
      info.extent.height = 4;
      return create_case(info);
   }
   if (IS("cube-5layers"))
      return create_case(with(info, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, 5, 1));
   if (IS("cube-nonsquare")) {
      info = with(info, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, 6, 1);
      info.extent.height = 32;
      return create_case(info);
   }
   if (IS("layers-too-many") || IS("max-layers")) {
      const uint32_t max = host_limits(BGRA, VK_IMAGE_TYPE_2D, S).maxArrayLayers;
      info.extent = (VkExtent3D){ 1, 1, 1 };
      info.arrayLayers = IS("layers-too-many") ? max + 1 : max;
      printf("layers %u (the driver's maximum %u)\n", info.arrayLayers, max);
      return create_case(info);
   }
   if (IS("3d-too-deep")) {
      const uint32_t max = host_limits(BGRA, VK_IMAGE_TYPE_3D, S).maxExtent.depth;
      info.imageType = VK_IMAGE_TYPE_3D;
      info.extent = (VkExtent3D){ 4, 4, max + 1 };
      return create_case(info);
   }
   if (IS("unknown-flag")) {
      info.flags = 0x40000000;
      return create_case(info);
   }
   if (IS("usage-0")) {
      info.usage = 0;
      return create_case(info);
   }
   if (IS("opt-2d"))
      return create_case(image_info(BGRA, OPT, S | TD | CA));
   if (IS("opt-mips")) {
      info.extent = (VkExtent3D){ 256, 256, 1 };
      info.mipLevels = 9;
      return create_case(info);
   }
   if (IS("opt-array"))
      return create_case(with(info, 0, 6, 1));
   if (IS("opt-cube"))
      return create_case(with(info, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, 6, 1));
   if (IS("opt-3d"))
      return create_case(with(info, 0, 1, 16));
   if (IS("opt-ms4")) {
      info.usage = CA;
      info.samples = VK_SAMPLE_COUNT_4_BIT;
      return create_case(info);
   }
   if (IS("opt-d32"))
      return create_case(image_info(VK_FORMAT_D32_SFLOAT, OPT,
                                    S | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT));
   if (IS("srgb-storage")) {
      info = image_info(VK_FORMAT_R8G8B8A8_SRGB, OPT, S | ST);
      info.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT | VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
      return create_case(info);
   }
   if (IS("bc1-block")) {
      info = image_info(VK_FORMAT_BC1_RGBA_UNORM_BLOCK, OPT, S);
      info.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT |
                   VK_IMAGE_CREATE_BLOCK_TEXEL_VIEW_COMPATIBLE_BIT | VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
      return create_case(info);
   }
   if (IS("devreq-mip-too-many")) {
      info.extent = (VkExtent3D){ 1, 1, 1 };
      info.mipLevels = 5;
      return devreq_case(info);
   }
   if (IS("devreq-linear-d32"))
      return devreq_case(image_info(VK_FORMAT_D32_SFLOAT, LIN, S));
   if (IS("devreq-zink"))
      return devreq_modifier_case(S | TS | TD | CA | IA);
   if (IS("devreq-wsi"))
      return devreq_modifier_case(S | TS | TD | CA);
   if (IS("devreq-ok"))
      return devreq_case(info);
   if (IS("devlayout-level"))
      return devlayout_case(3);
   if (IS("devlayout-ok"))
      return devlayout_case(0);
   if (IS("q-bad-type"))
      return query_case(BGRA, 3, OPT, S, NULL);
   if (IS("q-bad-tiling"))
      return query_case(BGRA, VK_IMAGE_TYPE_2D, 5, S, NULL);
   if (IS("q-drm-no-struct"))
      return query_case(BGRA, VK_IMAGE_TYPE_2D, DRM, S, NULL);
   if (IS("q-ok"))
      return query_case(BGRA, VK_IMAGE_TYPE_2D, OPT, S, NULL);
   if (IS("sparse-bad-samples"))
      return sparse_case(3);
   if (!strncmp(name, "bind-", 5) && !IS("bind-disjoint-no-plane"))
      return bind_case(name + 5);
   if (IS("bind-disjoint-no-plane"))
      return disjoint_case();
   if (IS("layout-plane1"))
      return layout_case(VK_IMAGE_ASPECT_PLANE_1_BIT, 0, 0, 0);
   if (IS("layout-plane2"))
      return layout_case(VK_IMAGE_ASPECT_PLANE_2_BIT, 0, 0, 0);
   if (IS("layout-level5"))
      return layout_case(VK_IMAGE_ASPECT_COLOR_BIT, 5, 0, 0);
   if (IS("layout-layer3"))
      return layout_case(VK_IMAGE_ASPECT_COLOR_BIT, 0, 3, 0);
   if (IS("layout-ok"))
      return layout_case(VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 0);
   if (IS("layout-memory-plane0"))
      return layout_case(VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT, 0, 0, 1);
   if (IS("reqs-plane1"))
      return reqs_plane_case();
   if (IS("view-levels"))
      return view_case(info, VK_IMAGE_VIEW_TYPE_2D, BGRA, COLOR(0, 3, 0, 1));
   if (IS("view-layers"))
      return view_case(info, VK_IMAGE_VIEW_TYPE_2D_ARRAY, BGRA, COLOR(0, 1, 0, 4));
   if (IS("view-cube5"))
      return view_case(with(info, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, 12, 1),
                       VK_IMAGE_VIEW_TYPE_CUBE, BGRA, COLOR(0, 1, 0, 5));
   if (IS("view-cubearray8"))
      return view_case(with(info, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, 12, 1),
                       VK_IMAGE_VIEW_TYPE_CUBE_ARRAY, BGRA, COLOR(0, 1, 0, 8));
   if (IS("view-format-size"))
      return view_case(with(info, VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT, 1, 1), VK_IMAGE_VIEW_TYPE_2D,
                       VK_FORMAT_R32G32B32A32_SFLOAT, COLOR(0, 1, 0, 1));
   if (IS("view-unknown-format"))
      return view_case(with(info, VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT, 1, 1), VK_IMAGE_VIEW_TYPE_2D,
                       VK_FORMAT_R64G64B64A64_SFLOAT, COLOR(0, 1, 0, 1));
   if (IS("view-bad-type"))
      return view_case(info, 7, BGRA, COLOR(0, 1, 0, 1));
   if (IS("view-3d-of-2d"))
      return view_case(info, VK_IMAGE_VIEW_TYPE_3D, BGRA, COLOR(0, 1, 0, 1));
   if (IS("view-3d-levels"))
      return view_case(with(info, 0, 1, 4), VK_IMAGE_VIEW_TYPE_3D, BGRA, COLOR(0, 3, 0, 1));
   if (IS("view-2d-of-3d-slice9"))
      return view_case(with(info, VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT, 1, 4),
                       VK_IMAGE_VIEW_TYPE_2D, BGRA, COLOR(0, 1, 9, 1));
   if (IS("view-2d"))
      return view_case(info, VK_IMAGE_VIEW_TYPE_2D, BGRA, COLOR(0, 1, 0, 1));
   if (IS("view-remaining")) {
      info = with(info, 0, 6, 1);
      info.mipLevels = 7;
      return view_case(info, VK_IMAGE_VIEW_TYPE_2D_ARRAY, BGRA,
                       COLOR(2, VK_REMAINING_MIP_LEVELS, 1, VK_REMAINING_ARRAY_LAYERS));
   }
   if (IS("view-cube"))
      return view_case(with(info, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, 6, 1),
                       VK_IMAGE_VIEW_TYPE_CUBE, BGRA, COLOR(0, 1, 0, 6));
   if (IS("view-cubearray12"))
      return view_case(with(info, VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT, 12, 1),
                       VK_IMAGE_VIEW_TYPE_CUBE_ARRAY, BGRA, COLOR(0, 1, 0, 12));
   if (IS("view-cube-no-flag"))
      return view_case(with(info, 0, 6, 1), VK_IMAGE_VIEW_TYPE_CUBE, BGRA, COLOR(0, 1, 0, 6));
   if (IS("view-2d-of-3d"))
      return view_case(with(info, VK_IMAGE_CREATE_2D_ARRAY_COMPATIBLE_BIT, 1, 4),
                       VK_IMAGE_VIEW_TYPE_2D, BGRA, COLOR(0, 1, 2, 1));
   if (IS("view-srgb-mutable"))
      return view_case(with(info, VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT, 1, 1), VK_IMAGE_VIEW_TYPE_2D,
                       VK_FORMAT_B8G8R8A8_SRGB, COLOR(0, 1, 0, 1));
   if (IS("view-srgb-plain"))
      return view_case(info, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_B8G8R8A8_SRGB, COLOR(0, 1, 0, 1));
   if (IS("view-r32-mutable"))
      return view_case(with(info, VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT, 1, 1), VK_IMAGE_VIEW_TYPE_2D,
                       VK_FORMAT_R32_UINT, COLOR(0, 1, 0, 1));
   if (IS("view-bc1-block")) {
      info = image_info(VK_FORMAT_BC1_RGBA_UNORM_BLOCK, OPT, S);
      info.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT |
                   VK_IMAGE_CREATE_BLOCK_TEXEL_VIEW_COMPATIBLE_BIT | VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
      return view_case(info, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R32G32_UINT, COLOR(0, 1, 0, 1));
   }
   const VkBufferUsageFlags UT = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT;
   const VkFormat RGBA = VK_FORMAT_R8G8B8A8_UNORM;
   if (IS("tview-wide"))
      return texel_case(UT, (1ull << 28) + 65536, VK_FORMAT_R8_UNORM, 0, VK_WHOLE_SIZE);
   if (IS("tview-unknown-format"))
      return texel_case(UT, 65536, VK_FORMAT_R64G64B64A64_SFLOAT, 0, VK_WHOLE_SIZE);
   if (IS("tview-past"))
      return texel_case(UT, 65536, RGBA, 1 << 20, 256);
   if (IS("tview-range-past"))
      return texel_case(UT, 65536, RGBA, 0, 1 << 20);
   if (IS("tview-range-odd"))
      return texel_case(UT, 65536, RGBA, 0, 6);
   if (IS("tview-no-usage"))
      return texel_case(VK_BUFFER_USAGE_TRANSFER_SRC_BIT, 65536, RGBA, 0, 256);
   if (IS("tview-offset4"))
      return texel_case(UT, 65536, RGBA, 4, 256);
   if (IS("tview-ok"))
      return texel_case(UT, 65536, RGBA, 0, 256);
   if (IS("tview-min-offset"))
      return texel_case(UT, 65536, RGBA, props.limits.minTexelBufferOffsetAlignment, 256);
   if (IS("tview-whole"))
      return texel_case(UT, 65538, RGBA, 0, VK_WHOLE_SIZE);
   if (IS("sampler-bad-filter")) {
      si.magFilter = 7;
      return sampler_case(si);
   }
   if (IS("sampler-bad-address")) {
      si.addressModeU = 99;
      return sampler_case(si);
   }
   if (IS("sampler-bad-border")) {
      si.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
      si.borderColor = 99;
      return sampler_case(si);
   }
   if (IS("sampler-ok"))
      return sampler_case(si);
   if (IS("sampler-aniso17")) {
      si.anisotropyEnable = VK_TRUE;
      si.maxAnisotropy = 17;
      return sampler_case(si);
   }
   if (IS("sampler-lod-huge")) {
      si.mipLodBias = 1e9f;
      si.minLod = -1e9f;
      si.maxLod = 1e9f;
      return sampler_case(si);
   }
   if (IS("refused-then-used"))
      return refused_then_used_case();
   if (IS("driver")) {
      VkPhysicalDeviceDriverProperties drv = {
         .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
      VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
                                         .pNext = &drv };
      pdev->proc_table.GetPhysicalDeviceProperties2(pdev->base.handle.physical_device, &p2);
      printf("driver: %s (id %d) on %s\n", drv.driverName, drv.driverID, props.deviceName);
      return drv.driverID == VK_DRIVER_ID_MOLTENVK ? WORKS : REFUSED;
   }
   printf("unknown case %s\n", name);
   return BROKEN;
}

/* microseconds per vkCreateImage + vkDestroyImage through vkr (with the checks), and
 * per run of the host calls the checks add (the format query, and the requirements query
 * at create); without the checks a create costs the difference */
static int time_creates(int n)
{
   setup();
   const VkImageCreateInfo info = image_info(BGRA, OPT, S | TD | CA);
   struct timespec t0, t1;
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      VkResult ret;
      struct vkr_image *image = create_image(&info, &ret);
      if (!image)
         broken("a create failed while timing");
      struct vn_command_vkDestroyImage d = { .device = (VkDevice)dev, .image = (VkImage)image };
      D->dispatch_vkDestroyImage(D, &d);
   }
   clock_gettime(CLOCK_MONOTONIC, &t1);
   const double with = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / 1e3 / n;

   const VkPhysicalDeviceImageFormatInfo2 q = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .format = info.format,
      .type = info.imageType, .tiling = info.tiling, .usage = info.usage };
   VkImage host_image;
   dev->proc_table.CreateImage(dev->base.handle.device, &info, NULL, &host_image);
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      VkImageFormatProperties2 p = { .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 };
      pdev->proc_table.GetPhysicalDeviceImageFormatProperties2(pdev->base.handle.physical_device, &q, &p);
      const VkImageMemoryRequirementsInfo2 ri = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2, .image = host_image };
      VkMemoryRequirements2 r = { .sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2 };
      dev->proc_table.GetImageMemoryRequirements2(dev->base.handle.device, &ri, &r);
   }
   clock_gettime(CLOCK_MONOTONIC, &t1);
   const double checks = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / 1e3 / n;
   dev->proc_table.DestroyImage(dev->base.handle.device, host_image, NULL);
   printf("timing: %d creates: %.2f us per vkCreateImage+vkDestroyImage through vkr, "
          "%.2f us of it the checks' host calls (format query + requirements), "
          "%.2f us without them\n", n, with, checks, with - checks);
   return 0;
}

static const char *outcome_name(int status)
{
   switch (status) {
   case WORKS: return "works";
   case REFUSED: return "refused";
   case FATAL: return "context ended";
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
      const int status = run_case(argv[1]);
      fflush(stdout);
      /* no cleanup: the process ends here, the driver's objects with it */
      _exit(status);
   }

   /* the driver first: KosmicKrisp must refuse Zink's image, MoltenVK may make it */
   int kk = -1, failures = 0;
   const char *driver_args[] = { argv[0], "driver", NULL };
   pid_t pid;
   int status;
   if (posix_spawn(&pid, argv[0], NULL, NULL, (char **)driver_args, environ) ||
       waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) ||
       (WEXITSTATUS(status) != WORKS && WEXITSTATUS(status) != REFUSED)) {
      printf("FAIL: no Venus device to test\n");
      return 1;
   }
   kk = WEXITSTATUS(status) == REFUSED;
   /* each child writes to one file; printed only when its case fails */
   char log[] = "/tmp/venus-limits.XXXXXX";
   const int log_fd = mkstemp(log);
   if (log_fd < 0) {
      printf("FAIL: no file for the cases' output\n");
      return 1;
   }
   posix_spawn_file_actions_t to_log;
   posix_spawn_file_actions_init(&to_log);
   posix_spawn_file_actions_adddup2(&to_log, log_fd, 1);
   posix_spawn_file_actions_adddup2(&to_log, log_fd, 2);
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
      case E_WORKS: ok = got == WORKS; break;
      case E_REFUSED: ok = got == REFUSED; break;
      case E_FATAL: ok = got == FATAL || got == SKIP; break;
      case E_NOT_WORKS: ok = got == REFUSED || got == FATAL; break;
      default: /* E_REFUSED_KK */
         ok = kk ? got == REFUSED : (got == REFUSED || got == WORKS || got == FATAL);
         break;
      }
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
   printf("%s: %zu cases on %s\n", failures ? "FAILED" : "all ok", sizeof(cases) / sizeof(cases[0]),
          kk ? "KosmicKrisp" : "MoltenVK");
   return failures != 0;
}
