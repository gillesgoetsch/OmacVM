/* vk-limits: Vulkan calls that ended the whole VM through the Mac's Vulkan driver up to
 * 3.2.13 (ADR 0065), from a program in the VM (Venus). One case per run; the caller runs
 * each in its own process and checks that QEMU lives on. Object creation, queries and
 * binds only: nothing is drawn or submitted.
 * Refused creates and queries come back as a VkResult (or zeros); a refused bind, view or
 * sampler ends this program's Venus context, and the guest's Mesa ends the program.
 * Build: cc -O1 -o vk-limits vk-limits.c -lvulkan
 * Usage: vk-limits CASE    (cases: see main) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static VkInstance inst;
static VkPhysicalDevice pd;
static VkDevice dev;

static int has_ext(const char *name)
{
   uint32_t n = 0;
   vkEnumerateDeviceExtensionProperties(pd, NULL, &n, NULL);
   VkExtensionProperties *e = calloc(n, sizeof(*e));
   vkEnumerateDeviceExtensionProperties(pd, NULL, &n, e);
   int found = 0;
   for (uint32_t i = 0; i < n; i++)
      found |= !strcmp(e[i].extensionName, name);
   free(e);
   return found;
}

static void init(void)
{
   VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                             .apiVersion = VK_API_VERSION_1_3 };
   VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                .pApplicationInfo = &app };
   uint32_t n = 1;
   if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS ||
       vkEnumeratePhysicalDevices(inst, &n, &pd) < 0 || !n) {
      printf("no Vulkan device\n");
      exit(2);
   }
   VkPhysicalDeviceProperties p;
   vkGetPhysicalDeviceProperties(pd, &p);
   fprintf(stderr, "device: %s\n", p.deviceName);
   const char *want[4];
   uint32_t nwant = 0;
   const char *exts[] = { "VK_EXT_image_drm_format_modifier", "VK_KHR_external_memory_fd",
                          "VK_EXT_external_memory_dma_buf" };
   for (unsigned i = 0; i < 3; i++)
      if (has_ext(exts[i]))
         want[nwant++] = exts[i];
   float prio = 1;
   VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                 .queueCount = 1, .pQueuePriorities = &prio };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
                              .enabledExtensionCount = nwant, .ppEnabledExtensionNames = want };
   if (vkCreateDevice(pd, &dci, NULL, &dev) != VK_SUCCESS) {
      printf("no device\n");
      exit(2);
   }
}

static VkImageCreateInfo image_info(VkFormat f, VkImageTiling t, VkImageUsageFlags u)
{
   return (VkImageCreateInfo){
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
      .format = f, .extent = { 64, 64, 1 }, .mipLevels = 1, .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = t, .usage = u,
   };
}

static uint32_t memory_type(uint32_t bits)
{
   for (uint32_t i = 0; i < 32; i++)
      if (bits & (1u << i))
         return i;
   return 0;
}

/* create, allocate, bind; prints each step; the image or 0 */
static VkImage make_image(const VkImageCreateInfo *info)
{
   VkImage img;
   printf("vkCreateImage ...\n");
   VkResult r = vkCreateImage(dev, info, NULL, &img);
   printf("vkCreateImage = %d\n", r);
   if (r != VK_SUCCESS)
      return VK_NULL_HANDLE;
   VkMemoryRequirements req;
   vkGetImageMemoryRequirements(dev, img, &req);
   VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                .allocationSize = req.size,
                                .memoryTypeIndex = memory_type(req.memoryTypeBits) };
   VkDeviceMemory mem;
   printf("vkAllocateMemory = %d\n", vkAllocateMemory(dev, &mai, NULL, &mem));
   printf("vkBindImageMemory ...\n");
   r = vkBindImageMemory(dev, img, mem, 0);
   /* a bind goes without waiting: a sync call shows whether the context lives */
   VkSubresourceLayout l = { 0 };
   VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
   if (info->tiling != VK_IMAGE_TILING_OPTIMAL)
      vkGetImageSubresourceLayout(dev, img, &sub, &l);
   printf("vkBindImageMemory = %d\n", r);
   return img;
}

static void modifier_image(VkImageUsageFlags usage)
{
   const uint64_t linear = 0; /* DRM_FORMAT_MOD_LINEAR */
   VkPhysicalDeviceImageDrmFormatModifierInfoEXT mod = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
      .drmFormatModifier = linear };
   VkPhysicalDeviceImageFormatInfo2 qi = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2, .pNext = &mod,
      .format = VK_FORMAT_B8G8R8A8_UNORM, .type = VK_IMAGE_TYPE_2D,
      .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, .usage = usage };
   VkImageFormatProperties2 qp = { .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2 };
   printf("query = %d\n", vkGetPhysicalDeviceImageFormatProperties2(pd, &qi, &qp));
   VkImageDrmFormatModifierListCreateInfoEXT list = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
      .drmFormatModifierCount = 1, .pDrmFormatModifiers = &linear };
   VkImageCreateInfo ii = image_info(VK_FORMAT_B8G8R8A8_UNORM,
                                     VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT, usage);
   ii.pNext = &list;
   make_image(&ii);
}

static void view(VkImageCreateInfo ii, VkImageViewType type, VkFormat format,
                 VkImageSubresourceRange range)
{
   VkImage img = make_image(&ii);
   if (!img)
      exit(1);
   VkImageViewCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img,
                                .viewType = type, .format = format, .subresourceRange = range };
   VkImageView v;
   printf("vkCreateImageView ...\n");
   printf("vkCreateImageView = %d\n", vkCreateImageView(dev, &vi, NULL, &v));
   printf("vkDeviceWaitIdle = %d\n", vkDeviceWaitIdle(dev));
}

#define S VK_IMAGE_USAGE_SAMPLED_BIT
#define TS VK_IMAGE_USAGE_TRANSFER_SRC_BIT
#define TD VK_IMAGE_USAGE_TRANSFER_DST_BIT
#define CA VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
#define IA VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT
#define BGRA VK_FORMAT_B8G8R8A8_UNORM
#define OPT VK_IMAGE_TILING_OPTIMAL
#define IS(n) (!strcmp(c, n))

int main(int argc, char **argv)
{
   if (argc != 2)
      return 64;
   const char *c = argv[1];
   setvbuf(stdout, NULL, _IOLBF, 0);
   init();
   VkImageCreateInfo ii = image_info(BGRA, OPT, S);
   const VkImageSubresourceRange one = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
   if (IS("zink")) { /* Zink's shared render target: the LINEAR modifier, COLOR + INPUT */
      modifier_image(S | TS | TD | CA | IA);
   } else if (IS("wsi")) { /* a window buffer: must keep working */
      modifier_image(S | TS | TD | CA);
   } else if (IS("mip-too-many")) {
      ii.extent = (VkExtent3D){ 1, 1, 1 };
      ii.mipLevels = 5;
      make_image(&ii);
   } else if (IS("too-wide")) {
      ii.extent = (VkExtent3D){ 65536, 1, 1 };
      make_image(&ii);
   } else if (IS("samples-64")) {
      ii.usage = CA;
      ii.samples = VK_SAMPLE_COUNT_64_BIT;
      make_image(&ii);
   } else if (IS("unknown-format")) {
      ii.format = VK_FORMAT_R64G64B64A64_SFLOAT;
      make_image(&ii);
   } else if (IS("devreq-mip-too-many")) {
      ii.extent = (VkExtent3D){ 1, 1, 1 };
      ii.mipLevels = 5;
      VkDeviceImageMemoryRequirements dr = {
         .sType = VK_STRUCTURE_TYPE_DEVICE_IMAGE_MEMORY_REQUIREMENTS, .pCreateInfo = &ii };
      VkMemoryRequirements2 mr = { .sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2 };
      vkGetDeviceImageMemoryRequirements(dev, &dr, &mr);
      printf("size %llu\n", (unsigned long long)mr.memoryRequirements.size);
   } else if (IS("view-levels")) {
      view(ii, VK_IMAGE_VIEW_TYPE_2D, BGRA,
           (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 3, 0, 1 });
   } else if (IS("view-cube5")) {
      ii.flags = VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT;
      ii.arrayLayers = 12;
      view(ii, VK_IMAGE_VIEW_TYPE_CUBE, BGRA,
           (VkImageSubresourceRange){ VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 5 });
   } else if (IS("view-format-size")) {
      ii.flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
      view(ii, VK_IMAGE_VIEW_TYPE_2D, VK_FORMAT_R32G32B32A32_SFLOAT, one);
   } else if (IS("view-ok")) { /* must keep working */
      view(ii, VK_IMAGE_VIEW_TYPE_2D, BGRA, one);
   } else if (IS("sampler-bad-filter")) {
      VkSamplerCreateInfo si = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .magFilter = 7,
                                 .maxLod = 1 };
      VkSampler s;
      printf("vkCreateSampler = %d\n", vkCreateSampler(dev, &si, NULL, &s));
      printf("vkDeviceWaitIdle = %d\n", vkDeviceWaitIdle(dev));
   } else if (IS("texel-wide")) {
      VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                .size = (1ull << 28) + 65536,
                                .usage = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT };
      VkBuffer buf;
      printf("vkCreateBuffer = %d\n", vkCreateBuffer(dev, &bi, NULL, &buf));
      VkMemoryRequirements req;
      vkGetBufferMemoryRequirements(dev, buf, &req);
      VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                   .allocationSize = req.size,
                                   .memoryTypeIndex = memory_type(req.memoryTypeBits) };
      VkDeviceMemory mem;
      printf("vkAllocateMemory = %d\n", vkAllocateMemory(dev, &mai, NULL, &mem));
      printf("vkBindBufferMemory = %d\n", vkBindBufferMemory(dev, buf, mem, 0));
      VkBufferViewCreateInfo bv = { .sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO,
                                    .buffer = buf, .format = VK_FORMAT_R8_UNORM,
                                    .range = VK_WHOLE_SIZE };
      VkBufferView v;
      printf("vkCreateBufferView = %d\n", vkCreateBufferView(dev, &bv, NULL, &v));
      printf("vkDeviceWaitIdle = %d\n", vkDeviceWaitIdle(dev));
   } else {
      fprintf(stderr, "unknown case %s\n", c);
      return 64;
   }
   printf("alive\n");
   return 0;
}
