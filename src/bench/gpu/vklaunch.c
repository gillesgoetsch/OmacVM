/* vklaunch: the cost of one small GPU job through Vulkan, end to end.
 *
 * One compute shader (64 threads add 1 to a buffer). Three ways:
 *   sync   one pre-recorded dispatch: submit + wait for its fence, N times (the round trip:
 *          submit, the GPU starts and ends it, the CPU sees the fence)
 *   rec64  record 64 dispatches with a barrier between each (like one small llama.cpp graph),
 *          submit, wait; N times (adds recording through the driver)
 *   batch  1000 dispatches in one command buffer, one submit + wait (GPU throughput per launch)
 *   poll   as sync, but spins on vkGetFenceStatus instead of vkWaitForFences (no sleep/wake-up of the waiter)
 *   submit one dispatch per submit, no fence: the cost of vkQueueSubmit alone (one wait at the end)
 * Prints one JSON line per mode: median, p10, p90 microseconds per round trip (batch: per dispatch).
 * Checks the buffer at the end (every add happened).
 * Usage: vklaunch [N=2000] [device index]
 * Build: Linux  cc -O2 -o vklaunch vklaunch.c -lvulkan
 *        macOS  cc -O2 -I<vulkan headers> -o vklaunch vklaunch.c <libvulkan.1.dylib>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>
#include "inc_spv.h"

#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s failed: %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)

static double now_us(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void report(const char *mode, const char *dev, double *v, int n, double per) {
  qsort(v, n, sizeof *v, cmpd);
  printf("{\"test\":\"vklaunch\",\"mode\":\"%s\",\"device\":\"%s\",\"n\":%d,\"median_us\":%.2f,\"p10_us\":%.2f,\"p90_us\":%.2f}\n",
         mode, dev, n, v[n / 2] / per, v[n / 10] / per, v[n * 9 / 10] / per);
  fflush(stdout);
}

int main(int argc, char **argv) {
  int N = argc > 1 ? atoi(argv[1]) : 2000, want = argc > 2 ? atoi(argv[2]) : -1;
  if (N < 1) { fprintf(stderr, "N must be 1 or more\n"); return 2; }
  VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
  const char *exts[] = { "VK_KHR_portability_enumeration" };
  VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai };
#ifdef __APPLE__
  ici.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR; ici.enabledExtensionCount = 1; ici.ppEnabledExtensionNames = exts;
#else
  (void)exts;
#endif
  VkInstance inst; CK(vkCreateInstance(&ici, NULL, &inst));
  uint32_t nd = 8; VkPhysicalDevice pds[8]; CK(vkEnumeratePhysicalDevices(inst, &nd, pds));
  int pick = -1; VkPhysicalDeviceProperties pp;
  for (uint32_t i = 0; i < nd; i++) {
    vkGetPhysicalDeviceProperties(pds[i], &pp);
    if (want >= 0 ? (int)i == want : pp.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU) { pick = i; break; }
  }
  if (pick < 0) { fprintf(stderr, "no GPU device\n"); return 1; }
  VkPhysicalDevice pd = pds[pick]; vkGetPhysicalDeviceProperties(pd, &pp);
  uint32_t nq = 16; VkQueueFamilyProperties qf[16]; vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
  uint32_t qi = 0; while (qi < nq && !(qf[qi].queueFlags & VK_QUEUE_COMPUTE_BIT)) qi++;
  float prio = 1.0f;
  VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = qi, .queueCount = 1, .pQueuePriorities = &prio };
  const char *dexts[] = { "VK_KHR_portability_subset" };
  uint32_t nde = 0; vkEnumerateDeviceExtensionProperties(pd, NULL, &nde, NULL);
  VkExtensionProperties *de = calloc(nde, sizeof *de); vkEnumerateDeviceExtensionProperties(pd, NULL, &nde, de);
  int port = 0; for (uint32_t i = 0; i < nde; i++) if (!strcmp(de[i].extensionName, dexts[0])) port = 1;
  VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
                             .enabledExtensionCount = port, .ppEnabledExtensionNames = dexts };
  VkDevice dev; CK(vkCreateDevice(pd, &dci, NULL, &dev));
  VkQueue q; vkGetDeviceQueue(dev, qi, 0, &q);

  /* a host-visible buffer of 64 uints */
  VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 256, .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
  VkBuffer buf; CK(vkCreateBuffer(dev, &bci, NULL, &buf));
  VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, buf, &mr);
  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
  uint32_t mt = 0; VkMemoryPropertyFlags wantf = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
  while (mt < mp.memoryTypeCount && !((mr.memoryTypeBits >> mt & 1) && (mp.memoryTypes[mt].propertyFlags & wantf) == wantf)) mt++;
  VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = mt };
  VkDeviceMemory mem; CK(vkAllocateMemory(dev, &mai, NULL, &mem)); CK(vkBindBufferMemory(dev, buf, mem, 0));
  uint32_t *map; CK(vkMapMemory(dev, mem, 0, 256, 0, (void **)&map)); memset(map, 0, 256);

  VkShaderModuleCreateInfo smi = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = sizeof inc_spv, .pCode = inc_spv };
  VkShaderModule sm; CK(vkCreateShaderModule(dev, &smi, NULL, &sm));
  VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, NULL };
  VkDescriptorSetLayoutCreateInfo dli = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &b };
  VkDescriptorSetLayout dsl; CK(vkCreateDescriptorSetLayout(dev, &dli, NULL, &dsl));
  VkPipelineLayoutCreateInfo pli = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl };
  VkPipelineLayout pl; CK(vkCreatePipelineLayout(dev, &pli, NULL, &pl));
  VkComputePipelineCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
    .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = sm, .pName = "main" },
    .layout = pl };
  VkPipeline pipe; CK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi, NULL, &pipe));
  VkDescriptorPoolSize ps = { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1 };
  VkDescriptorPoolCreateInfo dpi = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &ps };
  VkDescriptorPool dp; CK(vkCreateDescriptorPool(dev, &dpi, NULL, &dp));
  VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &dsl };
  VkDescriptorSet ds; CK(vkAllocateDescriptorSets(dev, &dsai, &ds));
  VkDescriptorBufferInfo dbi = { buf, 0, 256 };
  VkWriteDescriptorSet w = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi };
  vkUpdateDescriptorSets(dev, 1, &w, 0, NULL);

  VkCommandPoolCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = qi };
  VkCommandPool cp; CK(vkCreateCommandPool(dev, &cpci, NULL, &cp));
  VkCommandBufferAllocateInfo cbai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
  VkCommandBuffer cb; CK(vkAllocateCommandBuffers(dev, &cbai, &cb));
  VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
  VkFence fence; CK(vkCreateFence(dev, &fci, NULL, &fence));
  VkCommandBufferBeginInfo cbbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
  VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT };
  VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
  uint64_t expect = 0;
  /* v holds N sync/poll/submit times, max(N / 4, 50) rec64 times and 20 batch times */
  double *v = malloc(sizeof(double) * (N > 50 ? N : 50));
#define RECORD(k) do { CK(vkBeginCommandBuffer(cb, &cbbi)); vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe); \
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL); \
    for (int j_ = 0; j_ < (k); j_++) { if (j_) vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mb, 0, NULL, 0, NULL); \
      vkCmdDispatch(cb, 1, 1, 1); } CK(vkEndCommandBuffer(cb)); } while (0)
#define RUN() do { CK(vkQueueSubmit(q, 1, &si, fence)); CK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX)); CK(vkResetFences(dev, 1, &fence)); } while (0)

  /* sync: warm up, then N round trips */
  RECORD(1);
  for (int i = 0; i < 50; i++) { RUN(); expect++; }
  for (int i = 0; i < N; i++) { double t = now_us(); RUN(); v[i] = now_us() - t; expect++; }
  report("sync", pp.deviceName, v, N, 1);
  /* rec64: record + submit + wait */
  int M = N / 4 > 50 ? N / 4 : 50;
  for (int i = 0; i < M; i++) { double t = now_us(); CK(vkResetCommandBuffer(cb, 0)); RECORD(64); RUN(); v[i] = now_us() - t; expect += 64; }
  report("rec64", pp.deviceName, v, M, 1);
  /* batch: 1000 dispatches, one submit; per dispatch */
  CK(vkResetCommandBuffer(cb, 0)); RECORD(1000);
  int B = 20;
  for (int i = 0; i < B; i++) { double t = now_us(); RUN(); v[i] = now_us() - t; expect += 1000; }
  report("batch", pp.deviceName, v, B, 1000);
  /* poll: as sync, the fence is polled */
  CK(vkResetCommandBuffer(cb, 0)); RECORD(1);
  for (int i = 0; i < N; i++) {
    double t = now_us(); CK(vkQueueSubmit(q, 1, &si, fence));
    VkResult r; while ((r = vkGetFenceStatus(dev, fence)) == VK_NOT_READY) {}
    CK(r); CK(vkResetFences(dev, 1, &fence)); v[i] = now_us() - t; expect++;
  }
  report("poll", pp.deviceName, v, N, 1);
  /* submit: no fence, timed per submit (the buffer may be pending: simultaneous use); one wait at the end */
  CK(vkResetCommandBuffer(cb, 0)); cbbi.flags = VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT; RECORD(1);
  for (int i = 0; i < N; i++) { double t = now_us(); CK(vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE)); v[i] = now_us() - t; expect++; }
  CK(vkQueueWaitIdle(q));
  report("submit", pp.deviceName, v, N, 1);
  int bad = 0; for (int i = 0; i < 64; i++) if (map[i] != (uint32_t)expect) bad++;
  printf("{\"test\":\"vklaunch\",\"mode\":\"check\",\"device\":\"%s\",\"expect\":%llu,\"got\":%u,\"ok\":%s}\n", pp.deviceName,
         (unsigned long long)expect, map[0], bad ? "false" : "true");
  vkDeviceWaitIdle(dev);
  return bad ? 2 : 0;
}
