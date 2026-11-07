/* Guest values in pipelines, render passes, descriptor sets, queries and vkCmd* parameters
 * stay inside what the Mac's Vulkan driver addresses (virgl-venus-command-limits.patch,
 * virgl-venus-descriptor-limits.patch, virgl-venus-render-pass-limits.patch,
 * virgl-venus-pipeline-limits.patch; ADR 0065, "Indices, counts and offsets"), and commands
 * come where Vulkan allows them, shaders are SPIR-V the compilers can take, copies stay
 * inside their images and buffers and attachments have formats the device renders to
 * (virgl-venus-command-state.patch, virgl-venus-spirv-scan.patch,
 * virgl-venus-copy-regions.patch, virgl-venus-pipeline-formats.patch); frees name objects of
 * their pool once, a submit's chained arrays fit its counts, dedicated memory outlives its
 * image or buffer in the driver, and a pass's image views live while it is open
 * (virgl-venus-pool-frees.patch, virgl-venus-submit-counts.patch,
 * virgl-venus-dedicated-memory.patch, virgl-venus-pass-views.patch); a ring and the
 * context's stream take turns on the app's objects, command buffers hold the views their
 * passes named and primaries the secondaries they executed (virgl-venus-ring-lock.patch,
 * virgl-venus-command-holds.patch, virgl-venus-secondary-holds.patch; the t- cases stop a
 * real ring with virgl-venus-test-pause.patch's hook), and no chain vkr checks has one
 * structure type twice (virgl-venus-chain-repeats.patch: the -repeat- cases); a texel
 * view of no element, a dynamic vertex stride and color blend states vkr counts as read or
 * ignored as Vulkan does, and refusal lines without 18446744073709551615
 * (virgl-venus-ignored-values.patch: case_ignored); no draw or dispatch uses a descriptor
 * set, and no indexed draw an index buffer, never bound since the begin
 * (virgl-venus-unset-state.patch: the u- cases, case_unset); a command buffer and a MoltenVK
 * batch open no more Metal passes than vkr's cap, below where Metal ends the process
 * (virgl-venus-encoder-cap.patch: the h-pass- cases, case_host), and recordings and objects
 * are charged for the Mac memory they take, the heaps reported are the apps' share and the
 * charge comes back at the teardown (virgl-venus-host-memory.patch: the other h- cases).
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
 * Objects, pipelines, descriptor writes and command RECORDING only: nothing recorded is
 * submitted (the s- cases submit a batch with no command buffer, only a semaphore signal,
 * and wait for the queue), and a child ends with _exit() right after its last call, so no
 * recorded command buffer is reset or destroyed (MoltenVK commits a prefilled Metal command
 * buffer then). Exceptions: c-state-destroyed-view-held-submit and c-probe-descriptor-view
 * submit one legal 64x64 clear pass (or a bound set and nothing else) on MoltenVK without
 * prefill and wait for the queue; the held reset, free and teardown cases skip MoltenVK
 * with prefill; c-state-secondary-held-*-submit submit a primary whose secondary holds one
 * barrier, on every driver, and the c-state-secondary-held- cases reset or free it
 * (-resubmit-ok submits it twice; virgl-venus-submit-state.patch refuses the submit or the
 * end of one whose secondary was recorded again, and s-submit-secondary, -recording and
 * -initial: built without that patch, those three hand the driver what it must not get);
 * c-state-end-failed-* and c-state-end-hook-* submit a primary (a fill of host-visible
 * memory and an R8_UINT resolve, or one barrier) on every driver and wait for the queue;
 * the u-ib-*-m6-ok cases submit their legal indexed draw (3 vertices at index 0, 64x64) on
 * MoltenVK and wait for the queue. Run with
 * MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1, MoltenVK encodes at vkEndCommandBuffer what
 * it otherwise encodes at vkQueueSubmit in QEMU, still without committing (standards 14).
 *
 *   test-venus-commands              every case, one child each, then a summary
 *   test-venus-commands CASE         one case (what the children run)
 *   test-venus-commands --list       the case names
 *   test-venus-commands --time N     microseconds per command through vkr
 *   test-venus-commands --ring-time N   the same through a ring and the context's stream
 *
 * The driver is vkr's choice from OMACVM_VULKAN_DRIVER, the binary sits beside the
 * runtime's loader and drivers (run-venus-limits.py builds that folder). */
#include <fcntl.h>
#include <inttypes.h>
#include <libproc.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "virgl_util.h"
#include "virglrenderer.h"
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
#include "vkr_queue.h"
#include "vkr_render_pass.h"
#include "vkr_renderer.h"

extern char **environ;

/* what a case saw: the child's exit status */
enum { WORKS = 10, ERROR = 11, FATAL = 12, SKIP = 13, ZOMBIES = 14, BROKEN = 2 };
/* what a case must see: refused (the context ends with a log line), kept (works or a
 * VkResult error, no refusal), works (no error, no refusal); the multiview and push
 * constant cases decide in the child from the device's limits ("expect:" line) */
enum { E_REFUSE, E_KEEP, E_WORKS, E_CHILD, E_PROBE };

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
   N_YCBCR = 1 << 11,    /* samplerYcbcrConversion (core 1.1) */
   N_MUTABLE = 1 << 12,  /* VK_EXT_mutable_descriptor_type */
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
/* glslc -fshader-stage=comp -O0 --target-env=vulkan1.0 / vulkan1.3 (shaderc v2026.4) of a
 * compute shader using set 0 binding 0 (storage buffer), set 1 binding 0 (combined image
 * sampler) and set 2 binding 3 (uniform buffer) and declaring set 5 binding 1 unused
 * (fuzz-venus-spirv.c, seeds spec10 and spec16); the 1.6 one lists set 5 in its entry
 * point's interface */
static const uint32_t spv_comp10[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000031, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0006000f, 0x00000005, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000f, 0x00060010, 0x00000004,
   0x00000011, 0x00000001, 0x00000002, 0x00000001, 0x00030003, 0x00000002, 0x000001c2, 0x000a0004,
   0x475f4c47, 0x4c474f4f, 0x70635f45, 0x74735f70, 0x5f656c79, 0x656e696c, 0x7269645f, 0x69746365,
   0x00006576, 0x00080004, 0x475f4c47, 0x4c474f4f, 0x6e695f45, 0x64756c63, 0x69645f65, 0x74636572,
   0x00657669, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000, 0x00030005, 0x00000008, 0x00000041,
   0x00040006, 0x00000008, 0x00000000, 0x00000061, 0x00030005, 0x0000000a, 0x00000000, 0x00080005,
   0x0000000f, 0x475f6c67, 0x61626f6c, 0x766e496c, 0x7461636f, 0x496e6f69, 0x00000044, 0x00030005,
   0x00000014, 0x00000042, 0x00040006, 0x00000014, 0x00000000, 0x00000062, 0x00030005, 0x00000016,
   0x00000000, 0x00030005, 0x0000001e, 0x00786574, 0x00040005, 0x0000002e, 0x73756e55, 0x00006465,
   0x00040006, 0x0000002e, 0x00000000, 0x00000075, 0x00030005, 0x00000030, 0x00000000, 0x00040047,
   0x00000007, 0x00000006, 0x00000004, 0x00030047, 0x00000008, 0x00000003, 0x00050048, 0x00000008,
   0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x0000000a, 0x00000021, 0x00000000, 0x00040047,
   0x0000000a, 0x00000022, 0x00000000, 0x00040047, 0x0000000f, 0x0000000b, 0x0000001c, 0x00030047,
   0x00000014, 0x00000002, 0x00050048, 0x00000014, 0x00000000, 0x00000023, 0x00000000, 0x00040047,
   0x00000016, 0x00000021, 0x00000003, 0x00040047, 0x00000016, 0x00000022, 0x00000002, 0x00040047,
   0x0000001e, 0x00000021, 0x00000000, 0x00040047, 0x0000001e, 0x00000022, 0x00000001, 0x00040047,
   0x00000029, 0x00000001, 0x00000000, 0x00040047, 0x0000002b, 0x00000001, 0x00000001, 0x00040047,
   0x0000002c, 0x0000000b, 0x00000019, 0x00040047, 0x0000002d, 0x00000006, 0x00000004, 0x00030047,
   0x0000002e, 0x00000003, 0x00050048, 0x0000002e, 0x00000000, 0x00000023, 0x00000000, 0x00040047,
   0x00000030, 0x00000021, 0x00000001, 0x00040047, 0x00000030, 0x00000022, 0x00000005, 0x00020013,
   0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00040015, 0x00000006, 0x00000020, 0x00000000,
   0x0003001d, 0x00000007, 0x00000006, 0x0003001e, 0x00000008, 0x00000007, 0x00040020, 0x00000009,
   0x00000002, 0x00000008, 0x0004003b, 0x00000009, 0x0000000a, 0x00000002, 0x00040015, 0x0000000b,
   0x00000020, 0x00000001, 0x0004002b, 0x0000000b, 0x0000000c, 0x00000000, 0x00040017, 0x0000000d,
   0x00000006, 0x00000003, 0x00040020, 0x0000000e, 0x00000001, 0x0000000d, 0x0004003b, 0x0000000e,
   0x0000000f, 0x00000001, 0x0004002b, 0x00000006, 0x00000010, 0x00000000, 0x00040020, 0x00000011,
   0x00000001, 0x00000006, 0x0003001e, 0x00000014, 0x00000006, 0x00040020, 0x00000015, 0x00000002,
   0x00000014, 0x0004003b, 0x00000015, 0x00000016, 0x00000002, 0x00040020, 0x00000017, 0x00000002,
   0x00000006, 0x00030016, 0x0000001a, 0x00000020, 0x00090019, 0x0000001b, 0x0000001a, 0x00000001,
   0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0003001b, 0x0000001c, 0x0000001b,
   0x00040020, 0x0000001d, 0x00000000, 0x0000001c, 0x0004003b, 0x0000001d, 0x0000001e, 0x00000000,
   0x00040017, 0x00000020, 0x0000001a, 0x00000002, 0x0004002b, 0x0000001a, 0x00000021, 0x00000000,
   0x0005002c, 0x00000020, 0x00000022, 0x00000021, 0x00000021, 0x00040017, 0x00000023, 0x0000001a,
   0x00000004, 0x00040032, 0x00000006, 0x00000029, 0x00000001, 0x0004002b, 0x00000006, 0x0000002a,
   0x00000002, 0x00040032, 0x00000006, 0x0000002b, 0x00000001, 0x00060033, 0x0000000d, 0x0000002c,
   0x00000029, 0x0000002a, 0x0000002b, 0x0003001d, 0x0000002d, 0x00000006, 0x0003001e, 0x0000002e,
   0x0000002d, 0x00040020, 0x0000002f, 0x00000002, 0x0000002e, 0x0004003b, 0x0000002f, 0x00000030,
   0x00000002, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005,
   0x00050041, 0x00000011, 0x00000012, 0x0000000f, 0x00000010, 0x0004003d, 0x00000006, 0x00000013,
   0x00000012, 0x00050041, 0x00000017, 0x00000018, 0x00000016, 0x0000000c, 0x0004003d, 0x00000006,
   0x00000019, 0x00000018, 0x0004003d, 0x0000001c, 0x0000001f, 0x0000001e, 0x00070058, 0x00000023,
   0x00000024, 0x0000001f, 0x00000022, 0x00000002, 0x00000021, 0x00050051, 0x0000001a, 0x00000025,
   0x00000024, 0x00000000, 0x0004006d, 0x00000006, 0x00000026, 0x00000025, 0x00050080, 0x00000006,
   0x00000027, 0x00000019, 0x00000026, 0x00060041, 0x00000017, 0x00000028, 0x0000000a, 0x0000000c,
   0x00000013, 0x0003003e, 0x00000028, 0x00000027, 0x000100fd, 0x00010038,
};
static const uint32_t spv_comp16[] = {
   0x07230203, 0x00010600, 0x000d000b, 0x00000034, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x000a000f, 0x00000005, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000d, 0x00000012, 0x00000019,
   0x00000021, 0x00000033, 0x0006014b, 0x00000004, 0x00000026, 0x00000007, 0x00000008, 0x00000009,
   0x00030003, 0x00000002, 0x000001c2, 0x000a0004, 0x475f4c47, 0x4c474f4f, 0x70635f45, 0x74735f70,
   0x5f656c79, 0x656e696c, 0x7269645f, 0x69746365, 0x00006576, 0x00080004, 0x475f4c47, 0x4c474f4f,
   0x6e695f45, 0x64756c63, 0x69645f65, 0x74636572, 0x00657669, 0x00040005, 0x00000004, 0x6e69616d,
   0x00000000, 0x00030005, 0x0000000b, 0x00000041, 0x00040006, 0x0000000b, 0x00000000, 0x00000061,
   0x00030005, 0x0000000d, 0x00000000, 0x00080005, 0x00000012, 0x475f6c67, 0x61626f6c, 0x766e496c,
   0x7461636f, 0x496e6f69, 0x00000044, 0x00030005, 0x00000017, 0x00000042, 0x00040006, 0x00000017,
   0x00000000, 0x00000062, 0x00030005, 0x00000019, 0x00000000, 0x00030005, 0x00000021, 0x00786574,
   0x00040005, 0x00000031, 0x73756e55, 0x00006465, 0x00040006, 0x00000031, 0x00000000, 0x00000075,
   0x00030005, 0x00000033, 0x00000000, 0x00040047, 0x00000007, 0x00000001, 0x00000000, 0x00040047,
   0x00000009, 0x00000001, 0x00000001, 0x00040047, 0x0000000a, 0x00000006, 0x00000004, 0x00030047,
   0x0000000b, 0x00000002, 0x00050048, 0x0000000b, 0x00000000, 0x00000023, 0x00000000, 0x00040047,
   0x0000000d, 0x00000021, 0x00000000, 0x00040047, 0x0000000d, 0x00000022, 0x00000000, 0x00040047,
   0x00000012, 0x0000000b, 0x0000001c, 0x00030047, 0x00000017, 0x00000002, 0x00050048, 0x00000017,
   0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x00000019, 0x00000021, 0x00000003, 0x00040047,
   0x00000019, 0x00000022, 0x00000002, 0x00040047, 0x00000021, 0x00000021, 0x00000000, 0x00040047,
   0x00000021, 0x00000022, 0x00000001, 0x00040047, 0x0000002d, 0x00000001, 0x00000000, 0x00040047,
   0x0000002e, 0x00000001, 0x00000001, 0x00040047, 0x00000030, 0x00000006, 0x00000004, 0x00030047,
   0x00000031, 0x00000002, 0x00050048, 0x00000031, 0x00000000, 0x00000023, 0x00000000, 0x00040047,
   0x00000033, 0x00000021, 0x00000001, 0x00040047, 0x00000033, 0x00000022, 0x00000005, 0x00020013,
   0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00040015, 0x00000006, 0x00000020, 0x00000000,
   0x00040032, 0x00000006, 0x00000007, 0x00000001, 0x0004002b, 0x00000006, 0x00000008, 0x00000002,
   0x00040032, 0x00000006, 0x00000009, 0x00000001, 0x0003001d, 0x0000000a, 0x00000006, 0x0003001e,
   0x0000000b, 0x0000000a, 0x00040020, 0x0000000c, 0x0000000c, 0x0000000b, 0x0004003b, 0x0000000c,
   0x0000000d, 0x0000000c, 0x00040015, 0x0000000e, 0x00000020, 0x00000001, 0x0004002b, 0x0000000e,
   0x0000000f, 0x00000000, 0x00040017, 0x00000010, 0x00000006, 0x00000003, 0x00040020, 0x00000011,
   0x00000001, 0x00000010, 0x0004003b, 0x00000011, 0x00000012, 0x00000001, 0x0004002b, 0x00000006,
   0x00000013, 0x00000000, 0x00040020, 0x00000014, 0x00000001, 0x00000006, 0x0003001e, 0x00000017,
   0x00000006, 0x00040020, 0x00000018, 0x00000002, 0x00000017, 0x0004003b, 0x00000018, 0x00000019,
   0x00000002, 0x00040020, 0x0000001a, 0x00000002, 0x00000006, 0x00030016, 0x0000001d, 0x00000020,
   0x00090019, 0x0000001e, 0x0000001d, 0x00000001, 0x00000000, 0x00000000, 0x00000000, 0x00000001,
   0x00000000, 0x0003001b, 0x0000001f, 0x0000001e, 0x00040020, 0x00000020, 0x00000000, 0x0000001f,
   0x0004003b, 0x00000020, 0x00000021, 0x00000000, 0x00040017, 0x00000023, 0x0000001d, 0x00000002,
   0x0004002b, 0x0000001d, 0x00000024, 0x00000000, 0x0005002c, 0x00000023, 0x00000025, 0x00000024,
   0x00000024, 0x00040017, 0x00000026, 0x0000001d, 0x00000004, 0x00040020, 0x0000002b, 0x0000000c,
   0x00000006, 0x00040032, 0x00000006, 0x0000002d, 0x00000001, 0x00040032, 0x00000006, 0x0000002e,
   0x00000001, 0x00060033, 0x00000010, 0x0000002f, 0x0000002d, 0x00000008, 0x0000002e, 0x0003001d,
   0x00000030, 0x00000006, 0x0003001e, 0x00000031, 0x00000030, 0x00040020, 0x00000032, 0x0000000c,
   0x00000031, 0x0004003b, 0x00000032, 0x00000033, 0x0000000c, 0x00050036, 0x00000002, 0x00000004,
   0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x00050041, 0x00000014, 0x00000015, 0x00000012,
   0x00000013, 0x0004003d, 0x00000006, 0x00000016, 0x00000015, 0x00050041, 0x0000001a, 0x0000001b,
   0x00000019, 0x0000000f, 0x0004003d, 0x00000006, 0x0000001c, 0x0000001b, 0x0004003d, 0x0000001f,
   0x00000022, 0x00000021, 0x00070058, 0x00000026, 0x00000027, 0x00000022, 0x00000025, 0x00000002,
   0x00000024, 0x00050051, 0x0000001d, 0x00000028, 0x00000027, 0x00000000, 0x0004006d, 0x00000006,
   0x00000029, 0x00000028, 0x00050080, 0x00000006, 0x0000002a, 0x0000001c, 0x00000029, 0x00060041,
   0x0000002b, 0x0000002c, 0x0000000d, 0x0000000f, 0x00000016, 0x0003003e, 0x0000002c, 0x0000002a,
   0x000100fd, 0x00010038,
};

static struct vkr_context *ctx;
/* the guest's names: the context's (an app's process name) and a compute stage's entry point;
 * the -ctl cases give them control bytes */
static const char *ctx_name = "test";
static const char *stage_name = "main";
static struct vn_dispatch_context *D;
static struct vkr_physical_device *pdev;
static struct vkr_device *dev;
static uint64_t next_id = 100;
static VkPhysicalDeviceProperties props;
static VkPhysicalDeviceLimits lim;
static bool kosmickrisp;
static bool moltenvk;
static unsigned have;            /* N_* the device was made with */
static uint32_t max_views;       /* maxMultiviewViewCount as vkr reports it to the guest */
static uint32_t max_push_descriptors, max_inline_block;
static uint32_t dynamic_ubo_max, dynamic_ssbo_max; /* the larger of the core and update-after-bind limits */
static VkSampleCountFlags sample_location_counts;
static VkExtent2D sample_location_grid;
static VkResult last_ret;
static bool have_indirect_count; /* drawIndirectCount on (the u-ib-*-indirect-count cases) */

#define DEVH ((VkDevice)dev)
#define FMT VK_FORMAT_R8G8B8A8_UNORM
static VkFormat rp_format = FMT; /* the attachments of render_pass() */
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
   ctx = vkr_context_create(1, retire, strlen(ctx_name), ctx_name);
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
   moltenvk = drv.driverID == VK_DRIVER_ID_MOLTENVK;
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
   VkPhysicalDeviceMutableDescriptorTypeFeaturesEXT mut = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MUTABLE_DESCRIPTOR_TYPE_FEATURES_EXT };
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
   QUERY(VK_EXT_MUTABLE_DESCRIPTOR_TYPE_EXTENSION_NAME, mut);
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
      { N_MUTABLE, VK_EXT_MUTABLE_DESCRIPTOR_TYPE_EXTENSION_NAME, mut.mutableDescriptorType },
   };
   if ((needs & N_YCBCR) && !f11.samplerYcbcrConversion) {
      printf("skip: the device has no samplerYcbcrConversion\n");
      fflush(stdout);
      _exit(SKIP);
   }
   const char *exts[16];
   uint32_t n_ext = 0;
   have = 0;
   for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
      if (!(needs & table[i].need))
         continue;
      if (!lists(table[i].ext) || !table[i].feature) {
         if (table[i].need == N_NESTED)
            continue; /* the case runs without it (vkr hides the extension) */
         printf("skip: the device has no %s%s\n", table[i].ext,
                !lists(table[i].ext) ? "" : table[i].need == N_NULLDESC ? " nullDescriptor" : " feature for it");
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
                                            .pNext = &e12, .multiview = f11.multiview,
                                            .samplerYcbcrConversion = (needs & N_YCBCR) != 0 };
   have_indirect_count = f12.drawIndirectCount;
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
   VkPhysicalDeviceMutableDescriptorTypeFeaturesEXT emut = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MUTABLE_DESCRIPTOR_TYPE_FEATURES_EXT,
      .mutableDescriptorType = VK_TRUE };
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
   ENABLE(N_MUTABLE, emut);
#undef ENABLE
   const float priority = 1;
   const VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
                                       .pQueuePriorities = &priority };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &e2,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
                              .enabledExtensionCount = n_ext, .ppEnabledExtensionNames = exts };
   const uint64_t device_object = dev ? next_id++ : 3;
   VkDevice device_id = (VkDevice)(uintptr_t)device_object;
   struct vn_command_vkCreateDevice cd = { .physicalDevice = (VkPhysicalDevice)pdev, .pCreateInfo = &dci,
                                           .pDevice = &device_id };
   D->dispatch_vkCreateDevice(D, &cd);
   dev = object(device_object);
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
      att[i] = (VkAttachmentDescription){ 0, rp_format, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
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
   const void *vi_next; /* chained on the vertex input state */
   const void *cb_next; /* chained on the color blend state */
   const VkDynamicState *dynamic;
   uint32_t dynamic_count;
   VkShaderStageFlagBits vert_stage;
   VkBlendFactor src_factor;
   VkCompareOp depth_compare;
   VkCullModeFlags cull;
   const VkSpecializationInfo *spec;
   uint32_t feedback_count; /* chain a creation feedback with this many stage entries */
   bool feedback;
   VkFormat color_format, depth_format; /* dynamic rendering's (0: FMT, none) */
   bool blend_null; /* the color blend state without its attachment array */
   bool discard;    /* rasterizerDiscardEnable VK_TRUE */
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
                                               .pNext = g->vi_next, .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &vb,
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
                                                 .lineWidth = 1, .rasterizerDiscardEnable = g->discard };
   VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                               .pNext = g->ms_next, .rasterizationSamples = g->samples ? g->samples : VK_SAMPLE_COUNT_1_BIT };
   VkPipelineDepthStencilStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
                                                .depthCompareOp = g->depth_compare };
   static VkPipelineColorBlendAttachmentState cba[64];
   for (int i = 0; i < 64; i++)
      cba[i] = (VkPipelineColorBlendAttachmentState){ .blendEnable = g->src_factor != 0, .colorWriteMask = 0xf,
                                                      .srcColorBlendFactor = g->src_factor };
   VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                              .pNext = g->cb_next, .attachmentCount = g->blend_count ? g->blend_count : g->colors,
                                              .pAttachments = g->blend_null ? NULL : cba };
   static VkFormat formats[64];
   for (int i = 0; i < 64; i++)
      formats[i] = g->color_format ? g->color_format : FMT;
   VkPipelineRenderingCreateInfo ri = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO, .pNext = g->next,
                                        .colorAttachmentCount = g->colors, .pColorAttachmentFormats = formats,
                                        .depthAttachmentFormat = g->depth_format };
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
                 .stage = stage, .module = (VkShaderModule)module, .pName = stage_name, .pSpecializationInfo = spec },
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

/* an imageless framebuffer of one attachment; NULL (with a skip line) where the driver has none */
static void *imageless_framebuffer(void *rp)
{
   const VkFormat fmt = FMT;
   VkFramebufferAttachmentImageInfo ai = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_ATTACHMENT_IMAGE_INFO,
                                           .usage = CA_SA, .width = 64, .height = 64, .layerCount = 1,
                                           .viewFormatCount = 1, .pViewFormats = &fmt };
   VkFramebufferAttachmentsCreateInfo ac = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_ATTACHMENTS_CREATE_INFO,
                                             .attachmentImageInfoCount = 1, .pAttachmentImageInfos = &ai };
   const uint64_t id = next_id++;
   VkFramebuffer fh = (VkFramebuffer)(uintptr_t)id;
   VkFramebufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .pNext = &ac,
                                    .flags = VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT,
                                    .renderPass = (VkRenderPass)rp, .attachmentCount = 1,
                                    .width = 64, .height = 64, .layers = 1 };
   struct vn_command_vkCreateFramebuffer cf = { .device = DEVH, .pCreateInfo = &info, .pFramebuffer = &fh };
   step("vkCreateFramebuffer (imageless)");
   D->dispatch_vkCreateFramebuffer(D, &cf);
   if (cf.ret != VK_SUCCESS || !object(id)) {
      printf("skip: no imageless framebuffer (%d)\n", cf.ret);
      return NULL;
   }
   return object(id);
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

/* the host's linear or optimal tiling features of a format include `feature` */
static bool format_has(VkFormat f, VkFormatFeatureFlags feature)
{
   VkFormatProperties p = { 0 };
   pdev->proc_table.GetPhysicalDeviceFormatProperties(pdev->base.handle.physical_device, f, &p);
   return (p.linearTilingFeatures | p.optimalTilingFeatures) & feature;
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

/* the SPIR-V scan (virgl-venus-spirv-scan.patch): malformed modules end the context at
 * vkCreateShaderModule (or a pipeline, for code inside the stage); a pipeline's entry point,
 * workgroup size and descriptor sets are checked against its stage and layout */
static int spirv_case(const char *c, struct world *w)
{
   static uint32_t code[4096];
   const size_t n = sizeof(spv_comp) / 4;
   memcpy(code, spv_comp, sizeof(spv_comp));
   if (IS("p-spirv-garbage")) {
      for (size_t i = 0; i < n; i++)
         code[i] = 0x9e3779b9u * (uint32_t)(i + 1);
      return created(shader(code, sizeof(spv_comp)));
   }
   if (IS("p-spirv-magic")) {
      code[0] = 0x03022307;
      return created(shader(code, sizeof(spv_comp)));
   }
   if (IS("p-spirv-bound")) {
      code[3] = 0x3fffffff;
      return created(shader(code, sizeof(spv_comp)));
   }
   /* the last instruction of 2 or more words: cut after its first word */
   size_t last = 0;
   for (size_t at = 5; at < n && (code[at] >> 16); at += code[at] >> 16) {
      if ((code[at] >> 16) >= 2)
         last = at;
   }
   if (IS("p-spirv-truncated"))
      return created(shader(code, (last + 1) * 4));
   if (IS("p-spirv-inline-garbage")) {
      for (size_t i = 5; i < n; i++)
         code[i] = 0x9e3779b9u * (uint32_t)(i + 1);
      VkShaderModuleCreateInfo inl = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                       .codeSize = sizeof(spv_comp), .pCode = code };
      return created(compute_pipeline(w->layout, NULL, &inl, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   if (IS("p-entry-name-ctl")) {
      /* the stage names an entry point with control bytes (vkr's reason quotes it) */
      stage_name = "main\r\x1b[2K\tok";
      void *mod = shader(code, sizeof(spv_comp));
      if (!mod)
         broken("module");
      return created(compute_pipeline(w->layout, mod, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   if (IS("p-entry-missing") || IS("p-ctx-name-ctl")) {
      /* the entry point's name "main" made "mbin": the stage's "main" is not in the module
       * (p-ctx-name-ctl: in a context whose name has control bytes, run_case) */
      for (size_t at = 5; at < n && (code[at] >> 16); at += code[at] >> 16) {
         if ((code[at] & 0xffff) == 15) {
            code[at + 3] = 0x6e69626d;
            break;
         }
      }
      void *mod = shader(code, sizeof(spv_comp));
      if (!mod)
         broken("module without main");
      return created(compute_pipeline(w->layout, mod, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   if (IS("p-stage-mismatch")) {
      /* a fragment shader's "main" as the compute stage */
      void *frag = shader(spv_frag, sizeof(spv_frag));
      if (!frag)
         broken("fragment module");
      return created(compute_pipeline(w->layout, frag, NULL, VK_SHADER_STAGE_COMPUTE_BIT, NULL, NULL));
   }
   void *comp = shader(spv_comp, sizeof(spv_comp));
   if (!comp)
      broken("compute module");
   if (IS("p-shader-layout-sets")) {
      /* the shader's set 0 binding 2 in a layout of no sets */
      void *empty = pipeline_layout_of(NULL, 0, NULL, 0);
      if (!empty)
         broken("empty layout");
      return created(compute_pipeline(empty, comp, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   if (IS("p-shader-layout-binding")) {
      /* set 0 has binding 0 only */
      void *dsl = one_binding_layout(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL);
      void *layout = dsl ? pipeline_layout_of(&dsl, 1, NULL, 0) : NULL;
      if (!layout)
         broken("one-binding layout");
      return created(compute_pipeline(layout, comp, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   if (!strncmp(c, "p-workgroup-", 12)) {
      /* the module's local_size_x_id 0, specialized (MoltenVK: Metal's assertion at 65536) */
      const uint32_t max = MIN2(lim.maxComputeWorkGroupSize[0], lim.maxComputeWorkGroupInvocations);
      spec_local_size = IS("p-workgroup-huge") ? 65536 : IS("p-workgroup-max") ? max : max + 1;
      step("workgroup %u x 1 x 1 (at most %u x .., %u in all)", spec_local_size, lim.maxComputeWorkGroupSize[0],
           lim.maxComputeWorkGroupInvocations);
      return created(compute_pipeline(w->layout, comp, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   if (!strncmp(c, "p-unused-set", 12)) {
      const bool v16 = IS("p-unused-set-ok-16");
      if (v16 && VK_API_VERSION_MINOR(props.apiVersion) < 3) {
         printf("skip: Vulkan 1.%u (SPIR-V 1.6 needs 1.3)\n", VK_API_VERSION_MINOR(props.apiVersion));
         return SKIP;
      }
      void *dsl[3] = { one_binding_layout(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_ALL),
                       one_binding_layout(VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_ALL), NULL };
      const VkDescriptorSetLayoutBinding ubo3 = { 3, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL };
      dsl[2] = set_layout_of(&ubo3, 1, 0, NULL);
      if (!dsl[0] || !dsl[1] || !dsl[2])
         broken("set layouts");
      /* "-missing": a layout without set 2, which the shader uses */
      void *layout = pipeline_layout_of(dsl, IS("p-unused-set-missing") ? 2 : 3, NULL, 0);
      void *mod = v16 ? shader(spv_comp16, sizeof(spv_comp16)) : shader(spv_comp10, sizeof(spv_comp10));
      if (!layout || !mod)
         broken("layout or module");
      return created(compute_pipeline(layout, mod, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   return BROKEN;
}

static int case_pipeline(const char *c)
{
   unsigned needs = 0;
   if (IS("p-inline-spirv-odd") || IS("p-inline-spirv-ok") || IS("p-stage-null-module") ||
       IS("p-spirv-inline-garbage"))
      needs |= N_MAINT5;
   if (IS("p-robustness-bad"))
      needs |= N_ROBUST;
   if (IS("p-gfx-att-locations-far"))
      needs |= N_LOCALREAD;
   if (!strncmp(c, "p-gfx-sample-locations-", 23))
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
   if (!strncmp(c, "p-spirv-", 8) || IS("p-entry-missing") || IS("p-entry-name-ctl") || IS("p-ctx-name-ctl") ||
       IS("p-stage-mismatch") ||
       !strncmp(c, "p-shader-layout-", 16) || !strncmp(c, "p-workgroup-", 12) || !strncmp(c, "p-unused-set", 12))
      return spirv_case(c, &w);

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
   /* LEGAL: the state chained with sampleLocationsEnable off and its locations left empty
    * (Vulkan reads them only while sample locations are on) */
   VkPipelineSampleLocationsStateCreateInfoEXT sl_off = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_SAMPLE_LOCATIONS_STATE_CREATE_INFO_EXT,
      .sampleLocationsInfo = { .sType = VK_STRUCTURE_TYPE_SAMPLE_LOCATIONS_INFO_EXT } };
   static VkDynamicState sl_enable_dynamic[1] = { VK_DYNAMIC_STATE_SAMPLE_LOCATIONS_ENABLE_EXT };
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
   } else if (IS("p-gfx-sample-locations-off")) {
      g.ms_next = &sl_off;
   } else if (IS("p-gfx-sample-locations-dyn-far")) {
      /* off in the pipeline, but switched on at draw time: Mesa copies the locations */
      sl.sampleLocationsEnable = VK_FALSE;
      g.ms_next = &sl;
      g.dynamic = sl_enable_dynamic;
      g.dynamic_count = 1;
   } else if (IS("p-gfx-format-bad")) {
      g.rp = NULL;
      g.color_format = (VkFormat)0x7fff;
   } else if (IS("p-gfx-format-r64")) {
      /* no Metal pixel format: KosmicKrisp ended in kk_lower_nir */
      g.rp = NULL;
      g.color_format = VK_FORMAT_R64G64B64A64_SFLOAT;
      expect(!format_has(g.color_format, VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT));
   } else if (IS("p-gfx-depth-format-color")) {
      g.rp = NULL;
      g.depth_format = FMT;
   } else if (IS("p-gfx-depth-format-ok")) {
      g.rp = NULL;
      g.depth_format = VK_FORMAT_D32_SFLOAT;
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

/* the clear values a begin must give (VUID-VkRenderPassBeginInfo-clearValueCount-00902): an
 * attachment counts when its loadOp clears, or its stencilLoadOp on a depth/stencil format */
static VkFormat ds_stencil_format(void)
{
   static const VkFormat formats[] = { VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT,
                                       VK_FORMAT_D16_UNORM_S8_UINT, VK_FORMAT_S8_UINT };
   for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
      VkFormatProperties p = { 0 };
      pdev->proc_table.GetPhysicalDeviceFormatProperties(pdev->base.handle.physical_device, formats[i], &p);
      if (p.optimalTilingFeatures & VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT)
         return formats[i];
   }
   return VK_FORMAT_UNDEFINED;
}

/* a view of a 64 x 64 depth/stencil image of `format` */
static void *ds_view(VkFormat format)
{
   const uint64_t id = next_id++, vid = next_id++;
   VkImage hd = (VkImage)(uintptr_t)id;
   VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                              .format = format, .extent = { 64, 64, 1 }, .mipLevels = 1, .arrayLayers = 1,
                              .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                              .usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT };
   struct vn_command_vkCreateImage c = { .device = DEVH, .pCreateInfo = &info, .pImage = &hd };
   D->dispatch_vkCreateImage(D, &c);
   struct vkr_image *img = object(id);
   if (c.ret != VK_SUCCESS || !img)
      broken("vkCreateImage (depth/stencil)");
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetImageMemoryRequirements r = { .device = DEVH, .image = (VkImage)img,
                                                       .pMemoryRequirements = &req };
   D->dispatch_vkGetImageMemoryRequirements(D, &r);
   struct vkr_device_memory *mem = allocate(req.size, memory_type(req.memoryTypeBits));
   struct vn_command_vkBindImageMemory b = { .device = DEVH, .image = (VkImage)img, .memory = (VkDeviceMemory)mem };
   D->dispatch_vkBindImageMemory(D, &b);
   if (b.ret != VK_SUCCESS)
      broken("vkBindImageMemory (depth/stencil)");
   VkImageView h = (VkImageView)(uintptr_t)vid;
   const VkImageAspectFlags aspects = format == VK_FORMAT_S8_UINT
                                         ? VK_IMAGE_ASPECT_STENCIL_BIT
                                         : VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT;
   VkImageViewCreateInfo vinfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = (VkImage)img,
                                   .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format,
                                   .subresourceRange = { aspects, 0, 1, 0, 1 } };
   struct vn_command_vkCreateImageView v = { .device = DEVH, .pCreateInfo = &vinfo, .pView = &h };
   D->dispatch_vkCreateImageView(D, &v);
   if (v.ret != VK_SUCCESS || !object(vid))
      broken("vkCreateImageView (depth/stencil)");
   return object(vid);
}

/* a pass of one attachment, a color one (FMT) or a depth/stencil one, with these load ops;
 * begun with no clear values and ended */
static int clear_rule_case(struct world *w, VkFormat format, VkAttachmentLoadOp load,
                           VkAttachmentLoadOp stencil_load)
{
   const bool ds = format != FMT;
   const VkImageLayout layout = ds ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
                                   : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
   VkAttachmentDescription att = { 0, format, VK_SAMPLE_COUNT_1_BIT, load, VK_ATTACHMENT_STORE_OP_STORE,
                                   stencil_load, VK_ATTACHMENT_STORE_OP_STORE, VK_IMAGE_LAYOUT_UNDEFINED, layout };
   VkAttachmentReference ref = { 0, layout };
   VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                .colorAttachmentCount = ds ? 0 : 1, .pColorAttachments = ds ? NULL : &ref,
                                .pDepthStencilAttachment = ds ? &ref : NULL };
   const uint64_t id = next_id++;
   VkRenderPass h = (VkRenderPass)(uintptr_t)id;
   VkRenderPassCreateInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1,
                                   .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
   struct vn_command_vkCreateRenderPass cr = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
   step("vkCreateRenderPass format %d, load op %d, stencil load op %d", format, load, stencil_load);
   D->dispatch_vkCreateRenderPass(D, &cr);
   void *rp = cr.ret == VK_SUCCESS ? object(id) : NULL;
   if (!rp)
      broken("render pass");
   void *views[1] = { ds ? ds_view(format) : w->iv };
   void *fb = framebuffer(rp, views, 1, 64, 64, 1);
   if (!fb)
      broken("framebuffer");
   begin(w->cmd);
   begin_pass_clear(w->cmd, rp, fb, 64, 64, 0);
   end_pass(w->cmd);
   return end(w->cmd);
}

/* LEGAL: a multiview pass (views 0 and 1) whose correlation mask names view 8, with
 * vkCreateRenderPass or vkCreateRenderPass2: no rule bounds a correlation mask by the view
 * count (only overlaps, VUID-VkRenderPassMultiviewCreateInfo-pCorrelationMasks-00841 and
 * VUID-VkRenderPassCreateInfo2-pCorrelatedViewMasks-03056), and the drivers only copy it */
static void *correlation_pass(bool two)
{
   static const uint32_t view_mask = 0x3, correlation = 0x100;
   const uint64_t id = next_id++;
   VkRenderPass h = (VkRenderPass)(uintptr_t)id;
   VkResult ret;
   if (!two) {
      VkAttachmentDescription att = { 0, FMT, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
                                      VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                      VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED,
                                      VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
      VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
      VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                   .colorAttachmentCount = 1, .pColorAttachments = &ref };
      VkRenderPassMultiviewCreateInfo mv = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                                             .subpassCount = 1, .pViewMasks = &view_mask,
                                             .correlationMaskCount = 1, .pCorrelationMasks = &correlation };
      VkRenderPassCreateInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .pNext = &mv,
                                      .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1,
                                      .pSubpasses = &sub };
      struct vn_command_vkCreateRenderPass c = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
      step("vkCreateRenderPass view mask 0x%x, correlation mask 0x%x", view_mask, correlation);
      D->dispatch_vkCreateRenderPass(D, &c);
      ret = c.ret;
   } else {
      VkAttachmentDescription2 att = { .sType = VK_STRUCTURE_TYPE_ATTACHMENT_DESCRIPTION_2, .format = FMT,
                                       .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                                       .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                       .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                       .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                       .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                                       .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
      VkAttachmentReference2 ref = { .sType = VK_STRUCTURE_TYPE_ATTACHMENT_REFERENCE_2, .attachment = 0,
                                     .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                     .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT };
      VkSubpassDescription2 sub = { .sType = VK_STRUCTURE_TYPE_SUBPASS_DESCRIPTION_2,
                                    .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .viewMask = view_mask,
                                    .colorAttachmentCount = 1, .pColorAttachments = &ref };
      VkRenderPassCreateInfo2 info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO_2, .attachmentCount = 1,
                                       .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub,
                                       .correlatedViewMaskCount = 1, .pCorrelatedViewMasks = &correlation };
      struct vn_command_vkCreateRenderPass2 c = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
      step("vkCreateRenderPass2 view mask 0x%x, correlated view mask 0x%x", view_mask, correlation);
      D->dispatch_vkCreateRenderPass2(D, &c);
      ret = c.ret;
   }
   last_ret = ret;
   step("vkCreateRenderPass%s = %d", two ? "2" : "", ret);
   return ret == VK_SUCCESS ? object(id) : NULL;
}

static int rendering_case(const char *c, struct world *w)
{
   VkRenderingAttachmentInfo att[16];
   const bool no_view = IS("r-dyn-resolve-no-view") || IS("r-dyn-resolve-no-view-target");
   const uint32_t n = IS("r-dyn-colors-over") ? lim.maxColorAttachments + 1 : no_view ? 2 : 1;
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
   else if (no_view) {
      /* LEGAL: a second color attachment without a view (unused) and a resolve mode set;
       * Vulkan asks for a resolve view only where the attachment has a view */
      att[1].imageView = VK_NULL_HANDLE;
      att[1].resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT;
      att[1].resolveImageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
      if (IS("r-dyn-resolve-no-view-target"))
         att[1].resolveImageView = (VkImageView)view(image(64, 64, 1, CA_SA), 1);
   } else if (!IS("r-dyn-colors-over") && !IS("r-dyn-ok"))
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
   if (IS("r-format-bad") || IS("r-format-r64")) {
      rp_format = IS("r-format-bad") ? (VkFormat)0x7fff : VK_FORMAT_R64G64B64A64_SFLOAT;
      if (IS("r-format-r64"))
         expect(!format_has(rp_format, VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
                                          VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT));
      return created(render_pass(1, 1, 0, 0));
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
   if (IS("r-fb-null-array")) {
      /* an absent array with a count: the decoder lets it through */
      const uint64_t id = next_id++;
      VkFramebuffer hd = (VkFramebuffer)(uintptr_t)id;
      VkFramebufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                       .renderPass = (VkRenderPass)w.rp, .attachmentCount = 1,
                                       .width = 64, .height = 64, .layers = 1 };
      struct vn_command_vkCreateFramebuffer f = { .device = DEVH, .pCreateInfo = &info, .pFramebuffer = &hd };
      step("vkCreateFramebuffer: 1 attachment, no array");
      D->dispatch_vkCreateFramebuffer(D, &f);
      last_ret = f.ret;
      return created(object(id));
   }
   if (IS("r-begin-null-array")) {
      void *fb = imageless_framebuffer(w.rp);
      if (!fb)
         return SKIP;
      VkRenderPassAttachmentBeginInfo ab = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_ATTACHMENT_BEGIN_INFO,
                                             .attachmentCount = 1 };
      VkClearValue clear = { 0 };
      VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .pNext = &ab,
                                   .renderPass = (VkRenderPass)w.rp, .framebuffer = (VkFramebuffer)fb,
                                   .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1,
                                   .pClearValues = &clear };
      struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = (VkCommandBuffer)w.cmd, .pRenderPassBegin = &bi,
                                                   .contents = VK_SUBPASS_CONTENTS_INLINE };
      begin(w.cmd);
      step("vkCmdBeginRenderPass: imageless, 1 attachment, no array");
      D->dispatch_vkCmdBeginRenderPass(D, &b);
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
   /* LEGAL: a color attachment's stencil load op is ignored, so it asks no clear value */
   if (IS("r-begin-clear-color-stencil"))
      return clear_rule_case(&w, FMT, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_LOAD_OP_CLEAR);
   if (IS("r-begin-clear-ds-stencil")) {
      const VkFormat ds = ds_stencil_format();
      if (ds == VK_FORMAT_UNDEFINED) {
         printf("skip: no depth/stencil format with stencil\n");
         return SKIP;
      }
      return clear_rule_case(&w, ds, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_LOAD_OP_CLEAR);
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
   if (IS("r-correlation-ok") || IS("r-correlation2-ok"))
      return created(correlation_pass(IS("r-correlation2-ok")));
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
   if (IS("r-unused-format-ok")) {
      /* LEGAL: an attachment no subpass uses may have a format without attachment features
       * (the feature VUIDs are on the references, e.g. VkSubpassDescription-pColorAttachments-
       * 02648): a compressed format the device samples; render pass, framebuffer, begin, end */
      static const VkFormat candidates[] = { VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK, VK_FORMAT_ASTC_4x4_UNORM_BLOCK,
                                             VK_FORMAT_BC1_RGBA_UNORM_BLOCK };
      VkFormat other = VK_FORMAT_UNDEFINED;
      for (uint32_t i = 0; i < 3 && !other; i++) {
         VkFormatProperties fp = { 0 };
         pdev->proc_table.GetPhysicalDeviceFormatProperties(pdev->base.handle.physical_device, candidates[i], &fp);
         const VkFormatFeatureFlags any = fp.linearTilingFeatures | fp.optimalTilingFeatures;
         if ((fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) &&
             !(any & (VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT)))
            other = candidates[i];
      }
      if (!other) {
         printf("skip: no sampled format without attachment features\n");
         return SKIP;
      }
      VkAttachmentDescription att[2] = {
         { 0, FMT, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_STORE,
           VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED,
           VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL },
         { 0, other, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
           VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
           VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL } };
      VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
      VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                   .colorAttachmentCount = 1, .pColorAttachments = &ref };
      const uint64_t id = next_id++;
      VkRenderPass h = (VkRenderPass)(uintptr_t)id;
      VkRenderPassCreateInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2,
                                      .pAttachments = att, .subpassCount = 1, .pSubpasses = &sub };
      struct vn_command_vkCreateRenderPass cr = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
      step("vkCreateRenderPass: attachment 1 of format %d, no subpass uses it", other);
      D->dispatch_vkCreateRenderPass(D, &cr);
      step("vkCreateRenderPass = %d", cr.ret);
      if (ended())
         return FATAL;
      if (cr.ret != VK_SUCCESS)
         return ERROR;
      const uint64_t iid = next_id++;
      VkImage ih = (VkImage)(uintptr_t)iid;
      VkImageCreateInfo iinfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                                  .format = other, .extent = { 64, 64, 1 }, .mipLevels = 1, .arrayLayers = 1,
                                  .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                                  .usage = VK_IMAGE_USAGE_SAMPLED_BIT };
      struct vn_command_vkCreateImage ci = { .device = DEVH, .pCreateInfo = &iinfo, .pImage = &ih };
      D->dispatch_vkCreateImage(D, &ci);
      struct vkr_image *cimg = object(iid);
      if (ci.ret != VK_SUCCESS || !cimg)
         broken("compressed image");
      VkMemoryRequirements req = { 0 };
      struct vn_command_vkGetImageMemoryRequirements r = { .device = DEVH, .image = (VkImage)cimg,
                                                           .pMemoryRequirements = &req };
      D->dispatch_vkGetImageMemoryRequirements(D, &r);
      struct vkr_device_memory *mem = allocate(req.size, memory_type(req.memoryTypeBits));
      struct vn_command_vkBindImageMemory bm = { .device = DEVH, .image = (VkImage)cimg, .memory = (VkDeviceMemory)mem };
      D->dispatch_vkBindImageMemory(D, &bm);
      const uint64_t vid = next_id++;
      VkImageView vh = (VkImageView)(uintptr_t)vid;
      VkImageViewCreateInfo vinfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = (VkImage)cimg,
                                      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = other,
                                      .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
      struct vn_command_vkCreateImageView cv = { .device = DEVH, .pCreateInfo = &vinfo, .pView = &vh };
      D->dispatch_vkCreateImageView(D, &cv);
      if (bm.ret != VK_SUCCESS || cv.ret != VK_SUCCESS || !object(vid))
         broken("compressed view");
      void *views[2] = { w.iv, object(vid) };
      void *fb = framebuffer(object(id), views, 2, 64, 64, 1);
      if (!fb)
         return created(fb);
      begin(w.cmd);
      begin_pass_clear(w.cmd, object(id), fb, 64, 64, 1);
      end_pass(w.cmd);
      return end(w.cmd);
   }
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
   if (IS("d-null-buffer-nd") || IS("d-null-view-nd") || IS("d-null-dynamic-nd"))
      needs |= N_NULLDESC;
   if (IS("d-planes-ok"))
      needs |= N_YCBCR;
   if (IS("d-mutable-ok"))
      needs |= N_MUTABLE;
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
   } else if (IS("d-null-dynamic-nd")) {
      /* LEGAL with nullDescriptor: a NULL buffer at offset 0, VK_WHOLE_SIZE in a dynamic uniform
       * and a dynamic storage buffer binding (VUID-VkDescriptorBufferInfo-buffer-02998/-02999
       * ask no more for any buffer type; KosmicKrisp gives it an empty range) */
      const VkDescriptorSetLayoutBinding b[2] = {
         { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_ALL, NULL },
         { 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1, VK_SHADER_STAGE_ALL, NULL } };
      VkDescriptorPoolSize sizes[2] = { { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1 },
                                        { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1 } };
      const uint64_t pid = next_id++;
      VkDescriptorPool ph = (VkDescriptorPool)(uintptr_t)pid;
      VkDescriptorPoolCreateInfo pinfo = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
                                           .poolSizeCount = 2, .pPoolSizes = sizes };
      struct vn_command_vkCreateDescriptorPool cpool = { .device = DEVH, .pCreateInfo = &pinfo,
                                                         .pDescriptorPool = &ph };
      D->dispatch_vkCreateDescriptorPool(D, &cpool);
      void *set = cpool.ret == VK_SUCCESS ? set_from(object(pid), set_layout_of(b, 2, 0, NULL), NULL) : NULL;
      if (!set)
         broken("dynamic buffer set");
      bi[0] = (VkDescriptorBufferInfo){ VK_NULL_HANDLE, 0, VK_WHOLE_SIZE };
      VkWriteDescriptorSet ubo = wr;
      ubo.dstSet = (VkDescriptorSet)set;
      ubo.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
      struct vn_command_vkUpdateDescriptorSets uu = { .device = DEVH, .descriptorWriteCount = 1,
                                                      .pDescriptorWrites = &ubo };
      step("vkUpdateDescriptorSets a NULL dynamic uniform buffer");
      D->dispatch_vkUpdateDescriptorSets(D, &uu);
      if (ended())
         return FATAL;
      wr.dstSet = (VkDescriptorSet)set;
      wr.dstBinding = 1;
      wr.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC;
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
   } else if (IS("d-consecutive-gap-ok") || IS("d-consecutive-zero-ok") || IS("d-copy-consecutive-ok")) {
      /* LEGAL: an update past its binding goes on in the next binding with descriptors; a
       * binding with none, and a number the layout lacks, are skipped whatever their type
       * (VUID-VkWriteDescriptorSet-descriptorCount-00317: "except those with a descriptorCount
       * of zero"). Layouts {0: UBO x2, 2: UBO x2} and {0: UBO x2, 1: SAMPLER x0, 2: UBO x2};
       * 4 descriptors from binding 0, element 0 (the copy: from a set of the second layout
       * into one of the first) */
      const VkDescriptorSetLayoutBinding gap[2] = { { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2, VK_SHADER_STAGE_ALL, NULL },
                                                    { 2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2, VK_SHADER_STAGE_ALL, NULL } };
      const VkDescriptorSetLayoutBinding zero[3] = { { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2, VK_SHADER_STAGE_ALL, NULL },
                                                     { 1, VK_DESCRIPTOR_TYPE_SAMPLER, 0, VK_SHADER_STAGE_FRAGMENT_BIT, NULL },
                                                     { 2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2, VK_SHADER_STAGE_ALL, NULL } };
      static VkDescriptorBufferInfo four[4];
      for (uint32_t i = 0; i < 4; i++)
         four[i] = (VkDescriptorBufferInfo){ (VkBuffer)w.buf, 256 * i, 256 };
      void *gap_set = set_from(w.pool, set_layout_of(gap, 2, 0, NULL), NULL);
      void *zero_set = set_from(w.pool, set_layout_of(zero, 3, 0, NULL), NULL);
      if (!gap_set || !zero_set)
         broken("consecutive sets");
      wr.pBufferInfo = four;
      if (IS("d-copy-consecutive-ok")) {
         /* the source written binding by binding (2 + 2), then copied in one go */
         VkWriteDescriptorSet src[2] = { wr, wr };
         src[0].dstSet = src[1].dstSet = (VkDescriptorSet)zero_set;
         src[0].descriptorCount = src[1].descriptorCount = 2;
         src[1].dstBinding = 2;
         src[1].pBufferInfo = four + 2;
         struct vn_command_vkUpdateDescriptorSets us = { .device = DEVH, .descriptorWriteCount = 2,
                                                         .pDescriptorWrites = src };
         step("vkUpdateDescriptorSets the copy's source, bindings 0 and 2");
         D->dispatch_vkUpdateDescriptorSets(D, &us);
         if (ended())
            return FATAL;
         cp.srcSet = (VkDescriptorSet)zero_set;
         cp.dstSet = (VkDescriptorSet)gap_set;
         cp.descriptorCount = 4;
         n_copy = 1;
      } else {
         wr.dstSet = (VkDescriptorSet)(IS("d-consecutive-gap-ok") ? gap_set : zero_set);
         wr.descriptorCount = 4;
      }
   } else if (IS("d-start-next-ok") || IS("d-copy-start-next-ok") || IS("d-start-past-all")) {
      /* LEGAL: an update whose first element lies past its binding starts in the next one
       * (VUID-VkWriteDescriptorSet-dstArrayElement-00321 counts the consecutive bindings);
       * {0: UBO x2, 1: UBO x2}: element 3 of binding 0 is element 1 of binding 1, elements 2
       * and 3 are binding 1's. Past every binding: refused. */
      const VkDescriptorSetLayoutBinding b[2] = { { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2, VK_SHADER_STAGE_ALL, NULL },
                                                  { 1, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2, VK_SHADER_STAGE_ALL, NULL } };
      void *dsl = set_layout_of(b, 2, 0, NULL);
      void *s0 = set_from(w.pool, dsl, NULL), *s1 = set_from(w.pool, dsl, NULL);
      if (!s0 || !s1)
         broken("consecutive sets");
      static VkDescriptorBufferInfo four[4];
      for (uint32_t i = 0; i < 4; i++)
         four[i] = (VkDescriptorBufferInfo){ (VkBuffer)w.buf, 256 * i, 256 };
      wr.dstSet = (VkDescriptorSet)s0;
      wr.pBufferInfo = four;
      if (IS("d-copy-start-next-ok")) {
         VkWriteDescriptorSet all = wr;
         all.descriptorCount = 4;
         struct vn_command_vkUpdateDescriptorSets us = { .device = DEVH, .descriptorWriteCount = 1,
                                                         .pDescriptorWrites = &all };
         step("vkUpdateDescriptorSets the copy's source, 4 from binding 0");
         D->dispatch_vkUpdateDescriptorSets(D, &us);
         if (ended())
            return FATAL;
         cp.srcSet = (VkDescriptorSet)s0;
         cp.srcArrayElement = 2; /* binding 1, element 0 */
         cp.dstSet = (VkDescriptorSet)s1;
         cp.descriptorCount = 2;
         n_copy = 1;
      } else {
         wr.dstArrayElement = IS("d-start-past-all") ? 4 : 3;
      }
   } else if (IS("d-planes-ok")) {
      /* LEGAL: one write over a binding whose immutable sampler has a 3-plane YCbCr conversion
       * and a binding of plain immutable samplers (VUID-VkWriteDescriptorSet-descriptorCount-
       * 00318 asks only that both have immutable samplers). KosmicKrisp's descriptors there
       * are 3 and 1 wide: written in one go at the first binding's stride, the last one landed
       * past the set; MoltenVK wrote all three with the first binding's layout. */
      const VkFormat yuv = VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM;
      if (!format_has(yuv, VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT)) {
         printf("skip: no sampled %d (3-plane) images\n", yuv);
         return SKIP;
      }
      const uint64_t cid = next_id++;
      VkSamplerYcbcrConversion ch = (VkSamplerYcbcrConversion)(uintptr_t)cid;
      VkSamplerYcbcrConversionCreateInfo cinfo = {
         .sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_CREATE_INFO, .format = yuv,
         .ycbcrModel = VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_709, .ycbcrRange = VK_SAMPLER_YCBCR_RANGE_ITU_NARROW,
         .xChromaOffset = VK_CHROMA_LOCATION_MIDPOINT, .yChromaOffset = VK_CHROMA_LOCATION_MIDPOINT,
         .chromaFilter = VK_FILTER_NEAREST };
      struct vn_command_vkCreateSamplerYcbcrConversion cc = { .device = DEVH, .pCreateInfo = &cinfo,
                                                              .pYcbcrConversion = &ch };
      step("vkCreateSamplerYcbcrConversion 3 planes");
      D->dispatch_vkCreateSamplerYcbcrConversion(D, &cc);
      if (cc.ret != VK_SUCCESS || !object(cid)) {
         printf("skip: no YCbCr conversion (%d)\n", cc.ret);
         return SKIP;
      }
      VkSamplerYcbcrConversionInfo conv = { .sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_INFO,
                                            .conversion = (VkSamplerYcbcrConversion)object(cid) };
      const uint64_t sid = next_id++;
      VkSampler sh = (VkSampler)(uintptr_t)sid;
      VkSamplerCreateInfo sinfo = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .pNext = &conv,
                                    .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST,
                                    .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                                    .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                                    .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE };
      struct vn_command_vkCreateSampler cs = { .device = DEVH, .pCreateInfo = &sinfo, .pSampler = &sh };
      step("vkCreateSampler with the conversion");
      D->dispatch_vkCreateSampler(D, &cs);
      if (cs.ret != VK_SUCCESS || !object(sid))
         broken("YCbCr sampler");
      VkSampler ycbcr = (VkSampler)object(sid), plain[2] = { (VkSampler)w.smp, (VkSampler)w.smp };
      const VkDescriptorSetLayoutBinding b[2] = {
         { 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_ALL, &ycbcr },
         { 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2, VK_SHADER_STAGE_ALL, plain } };
      void *dsl = set_layout_of(b, 2, 0, NULL);
      /* a pool of exactly this set (the 3-plane binding counts as the driver's descriptor
       * count of the format, + 2), so a write past the set is a write past the pool's
       * memory (MoltenVK's CPU copy is heap memory: libgmalloc sees it) */
      VkSamplerYcbcrConversionImageFormatProperties ycp = {
         .sType = VK_STRUCTURE_TYPE_SAMPLER_YCBCR_CONVERSION_IMAGE_FORMAT_PROPERTIES };
      VkImageFormatProperties2 ifp = { .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2, .pNext = &ycp };
      const VkPhysicalDeviceImageFormatInfo2 ifi = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
                                                     .format = yuv, .type = VK_IMAGE_TYPE_2D,
                                                     .tiling = VK_IMAGE_TILING_OPTIMAL,
                                                     .usage = VK_IMAGE_USAGE_SAMPLED_BIT };
      pdev->proc_table.GetPhysicalDeviceImageFormatProperties2(pdev->base.handle.physical_device, &ifi, &ifp);
      VkDescriptorPoolSize ysize = { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                                     MAX2(ycp.combinedImageSamplerDescriptorCount, 1) + 2 };
      const uint64_t ypid = next_id++;
      VkDescriptorPool yph = (VkDescriptorPool)(uintptr_t)ypid;
      VkDescriptorPoolCreateInfo ypinfo = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1,
                                            .poolSizeCount = 1, .pPoolSizes = &ysize };
      struct vn_command_vkCreateDescriptorPool ycpool = { .device = DEVH, .pCreateInfo = &ypinfo,
                                                          .pDescriptorPool = &yph };
      D->dispatch_vkCreateDescriptorPool(D, &ycpool);
      void *set = dsl && ycpool.ret == VK_SUCCESS ? set_from(object(ypid), dsl, NULL) : NULL;
      if (!set)
         return created(set);
      /* a 3-plane image and a view of it with the conversion, then two plain views */
      const uint64_t iid = next_id++;
      VkImage ih = (VkImage)(uintptr_t)iid;
      VkImageCreateInfo iinfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                                  .format = yuv, .extent = { 64, 64, 1 }, .mipLevels = 1, .arrayLayers = 1,
                                  .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                                  .usage = VK_IMAGE_USAGE_SAMPLED_BIT };
      struct vn_command_vkCreateImage ci = { .device = DEVH, .pCreateInfo = &iinfo, .pImage = &ih };
      D->dispatch_vkCreateImage(D, &ci);
      struct vkr_image *yimg = object(iid);
      if (ended())
         return FATAL;
      if (ci.ret != VK_SUCCESS || !yimg) {
         printf("skip: no 3-plane image (%d)\n", ci.ret);
         return SKIP;
      }
      VkMemoryRequirements req = { 0 };
      struct vn_command_vkGetImageMemoryRequirements r = { .device = DEVH, .image = (VkImage)yimg,
                                                           .pMemoryRequirements = &req };
      D->dispatch_vkGetImageMemoryRequirements(D, &r);
      struct vkr_device_memory *mem = allocate(req.size, memory_type(req.memoryTypeBits));
      struct vn_command_vkBindImageMemory bm = { .device = DEVH, .image = (VkImage)yimg, .memory = (VkDeviceMemory)mem };
      D->dispatch_vkBindImageMemory(D, &bm);
      if (bm.ret != VK_SUCCESS)
         broken("3-plane bind");
      const uint64_t vid = next_id++;
      VkImageView vh = (VkImageView)(uintptr_t)vid;
      VkImageViewCreateInfo vinfo = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .pNext = &conv,
                                      .image = (VkImage)yimg, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = yuv,
                                      .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
      struct vn_command_vkCreateImageView cv = { .device = DEVH, .pCreateInfo = &vinfo, .pView = &vh };
      D->dispatch_vkCreateImageView(D, &cv);
      if (ended())
         return FATAL;
      if (cv.ret != VK_SUCCESS || !object(vid)) {
         printf("skip: no 3-plane view (%d)\n", cv.ret);
         return SKIP;
      }
      static VkDescriptorImageInfo three[3];
      three[0] = (VkDescriptorImageInfo){ VK_NULL_HANDLE, (VkImageView)object(vid),
                                          VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
      three[1] = three[2] = (VkDescriptorImageInfo){ VK_NULL_HANDLE, (VkImageView)w.iv,
                                                     VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
      wr.dstSet = (VkDescriptorSet)set;
      wr.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
      wr.descriptorCount = 3;
      wr.pBufferInfo = NULL;
      wr.pImageInfo = three;
   } else if (IS("d-mutable-ok")) {
      /* LEGAL: one write of uniform buffers over two mutable bindings with other type lists
       * (their descriptors are as wide as the largest type each can hold) */
      static const VkDescriptorType wide[2] = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE };
      static const VkDescriptorType narrow[1] = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER };
      const VkMutableDescriptorTypeListEXT lists2[2] = { { 2, wide }, { 1, narrow } };
      const VkMutableDescriptorTypeCreateInfoEXT mut = {
         .sType = VK_STRUCTURE_TYPE_MUTABLE_DESCRIPTOR_TYPE_CREATE_INFO_EXT, .mutableDescriptorTypeListCount = 2,
         .pMutableDescriptorTypeLists = lists2 };
      const VkDescriptorSetLayoutBinding b[2] = { { 0, VK_DESCRIPTOR_TYPE_MUTABLE_EXT, 1, VK_SHADER_STAGE_ALL, NULL },
                                                  { 1, VK_DESCRIPTOR_TYPE_MUTABLE_EXT, 2, VK_SHADER_STAGE_ALL, NULL } };
      void *dsl = set_layout_of(b, 2, 0, &mut);
      if (!dsl)
         return created(dsl);
      VkDescriptorPoolSize size = { VK_DESCRIPTOR_TYPE_MUTABLE_EXT, 3 }; /* exactly the set */
      const VkMutableDescriptorTypeCreateInfoEXT pmut = {
         .sType = VK_STRUCTURE_TYPE_MUTABLE_DESCRIPTOR_TYPE_CREATE_INFO_EXT, .mutableDescriptorTypeListCount = 1,
         .pMutableDescriptorTypeLists = lists2 };
      const uint64_t pid = next_id++;
      VkDescriptorPool ph = (VkDescriptorPool)(uintptr_t)pid;
      VkDescriptorPoolCreateInfo pinfo = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .pNext = &pmut,
                                           .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &size };
      struct vn_command_vkCreateDescriptorPool cpool = { .device = DEVH, .pCreateInfo = &pinfo,
                                                         .pDescriptorPool = &ph };
      D->dispatch_vkCreateDescriptorPool(D, &cpool);
      void *set = cpool.ret == VK_SUCCESS ? set_from(object(pid), dsl, NULL) : NULL;
      if (!set)
         broken("mutable set");
      static VkDescriptorBufferInfo three_b[3];
      for (uint32_t i = 0; i < 3; i++)
         three_b[i] = (VkDescriptorBufferInfo){ (VkBuffer)w.buf, 256 * i, 256 };
      wr.dstSet = (VkDescriptorSet)set;
      wr.descriptorCount = 3;
      wr.pBufferInfo = three_b;
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

/* everything the world's pipelines use but its set (written, not bound): push constants
 * and, for graphics, the vertex buffer and viewport */
static void ready_except_set(void *cmd, struct world *w, VkPipelineBindPoint point)
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

/* the world's set, at `point` (one dynamic offset) */
static void bind_world_set(void *cmd, struct world *w, VkPipelineBindPoint point)
{
   VkDescriptorSet set = (VkDescriptorSet)w->set;
   const uint32_t off = 0;
   struct vn_command_vkCmdBindDescriptorSets b = { .commandBuffer = (VkCommandBuffer)cmd, .pipelineBindPoint = point,
                                                   .layout = (VkPipelineLayout)w->layout, .descriptorSetCount = 1,
                                                   .pDescriptorSets = &set, .dynamicOffsetCount = 1,
                                                   .pDynamicOffsets = &off };
   step("vkCmdBindDescriptorSets (the world's set) at point %d", point);
   D->dispatch_vkCmdBindDescriptorSets(D, &b);
}

/* everything the world's pipelines use, bound (a draw or dispatch without it is invalid
 * usage: MoltenVK reads the unset state when it encodes) */
static void ready(void *cmd, struct world *w, VkPipelineBindPoint point)
{
   ready_except_set(cmd, w, point);
   bind_world_set(cmd, w, point);
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
   if (IS("c-push-set-split-ok")) {
      /* LEGAL: one push over two bindings of a push layout (split per binding by vkr) */
      const VkDescriptorSetLayoutBinding two[2] = { { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL },
                                                    { 1, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL } };
      void *push2 = set_layout_of(two, 2, VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR, NULL);
      void *dsls2[2] = { plain, push2 };
      layout = push2 ? pipeline_layout_of(dsls2, 2, NULL, 0) : NULL;
      if (!layout)
         broken("two-binding push layout");
      static VkDescriptorBufferInfo bi2[2];
      bi2[0] = bi;
      bi2[1] = (VkDescriptorBufferInfo){ (VkBuffer)w->buf, 256, 256 };
      wr.pBufferInfo = bi2;
      wr.descriptorCount = 2;
   }
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

/* command buffer state (virgl-venus-command-state.patch): draws, dispatches, clears, passes,
 * queries and secondaries only where Vulkan allows them */
/* LEGAL (a 2-view pass, then a GPU profiler's timestamp, as an XR renderer may do): once a multiview
 * pass or rendering has ended, a timestamp or query takes one query again, here query 3 of 4.
 * The pass ends with vkCmdEndRenderPass, vkCmdEndRenderPass2 or vkCmdEndRendering. */
static int after_mv_case(const char *c, struct world *w)
{
   if (max_views < 2) {
      printf("skip: %u views\n", max_views);
      return SKIP;
   }
   void *cmd = w->cmd;
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   const bool query = IS("c-state-after-mv-query");
   void *qp = query_pool(query ? VK_QUERY_TYPE_OCCLUSION : VK_QUERY_TYPE_TIMESTAMP, 4);
   void *v = view(image(64, 64, 2, CA_SA), 2);
   if (IS("c-state-after-mv-dyn-timestamp")) {
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                        .imageView = (VkImageView)v,
                                        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                             .viewMask = 0x3, .colorAttachmentCount = 1, .pColorAttachments = &att };
      struct vn_command_vkCmdBeginRendering b = { .commandBuffer = cb, .pRenderingInfo = &ri };
      step("vkCmdBeginRendering viewMask 0x3");
      D->dispatch_vkCmdBeginRendering(D, &b);
      if (!ended()) {
         struct vn_command_vkCmdEndRendering e = { .commandBuffer = cb };
         step("vkCmdEndRendering");
         D->dispatch_vkCmdEndRendering(D, &e);
      }
   } else {
      void *rp = render_pass(1, 1, 0, 0x3);
      void *views[1] = { v };
      void *fb = rp ? framebuffer(rp, views, 1, 64, 64, 1) : NULL;
      if (!fb)
         broken("multiview framebuffer");
      if (IS("c-state-after-mv2-timestamp")) {
         VkClearValue clear = { 0 };
         VkRenderPassBeginInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                        .renderPass = (VkRenderPass)rp, .framebuffer = (VkFramebuffer)fb,
                                        .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1,
                                        .pClearValues = &clear };
         VkSubpassBeginInfo sbi = { .sType = VK_STRUCTURE_TYPE_SUBPASS_BEGIN_INFO,
                                    .contents = VK_SUBPASS_CONTENTS_INLINE };
         VkSubpassEndInfo sei = { .sType = VK_STRUCTURE_TYPE_SUBPASS_END_INFO };
         struct vn_command_vkCmdBeginRenderPass2 b = { .commandBuffer = cb, .pRenderPassBegin = &info,
                                                       .pSubpassBeginInfo = &sbi };
         step("vkCmdBeginRenderPass2 (2 views)");
         D->dispatch_vkCmdBeginRenderPass2(D, &b);
         if (!ended()) {
            struct vn_command_vkCmdEndRenderPass2 e = { .commandBuffer = cb, .pSubpassEndInfo = &sei };
            step("vkCmdEndRenderPass2");
            D->dispatch_vkCmdEndRenderPass2(D, &e);
         }
      } else {
         begin_pass(cmd, rp, fb, 64, 64);
         end_pass(cmd);
      }
   }
   if (ended())
      return end(cmd);
   if (query) {
      struct vn_command_vkCmdBeginQuery b = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp, .query = 3 };
      step("vkCmdBeginQuery 3 of 4 after the pass");
      D->dispatch_vkCmdBeginQuery(D, &b);
      if (!ended()) {
         struct vn_command_vkCmdEndQuery e = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp, .query = 3 };
         D->dispatch_vkCmdEndQuery(D, &e);
      }
   } else {
      struct vn_command_vkCmdWriteTimestamp t = { .commandBuffer = cb,
                                                  .pipelineStage = VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                                                  .queryPool = (VkQueryPool)qp, .query = 3 };
      step("vkCmdWriteTimestamp 3 of 4 after the pass");
      D->dispatch_vkCmdWriteTimestamp(D, &t);
   }
   return end(cmd);
}

/* An app that destroys the render pass or framebuffer while a pass of it is open (its command
 * buffer is invalid then): vkr must neither read the destroyed pass (vkr_cmd_state names it by
 * id and serial, never by pointer) nor let the driver read it (Mesa's vk_render_pass does at the
 * next subpass and the end), also when a new pass took the old id. The child runs with
 * MallocScribble=1 (main), so a read of freed memory finds 0x55 bytes and fails at once. */
static int destroyed_case(const char *c, struct world *w)
{
   void *cmd = w->cmd;
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   void *rp = two_subpass_pass(NULL, 0);
   void *views[1] = { w->iv };
   void *fb = rp ? framebuffer(rp, views, 1, 64, 64, 1) : NULL;
   if (!fb)
      broken("two-subpass framebuffer");
   const uint64_t rp_id = ((struct vkr_object *)rp)->id;
   begin_pass(cmd, rp, fb, 64, 64);
   if (IS("c-state-destroyed-fb-end")) {
      struct vn_command_vkDestroyFramebuffer d = { .device = DEVH, .framebuffer = (VkFramebuffer)fb };
      step("vkDestroyFramebuffer while its pass is open");
      D->dispatch_vkDestroyFramebuffer(D, &d);
   } else {
      struct vn_command_vkDestroyRenderPass d = { .device = DEVH, .renderPass = (VkRenderPass)rp };
      step("vkDestroyRenderPass while its pass is open");
      D->dispatch_vkDestroyRenderPass(D, &d);
   }
   if (IS("c-state-destroyed-id-reused")) {
      /* another two-subpass pass, made with the destroyed one's id */
      const uint64_t saved = next_id;
      next_id = rp_id;
      if (!two_subpass_pass(NULL, 0))
         broken("render pass with the old id");
      next_id = saved;
   }
   if (IS("c-state-destroyed-pass-next") || IS("c-state-destroyed-id-reused")) {
      struct vn_command_vkCmdNextSubpass ns = { .commandBuffer = cb, .contents = VK_SUBPASS_CONTENTS_INLINE };
      step("vkCmdNextSubpass");
      D->dispatch_vkCmdNextSubpass(D, &ns);
   }
   end_pass(cmd);
   return end(cmd);
}

/* the pass views cases (below, with the venus-624-c cases) */
static int views_case(const char *c, struct world *w);
static int held_case(const char *c, struct world *w, void *v);
static int secondary_case(const char *c, struct world *w);
static int secondary_again_case(const char *c, struct world *w);
static int end_failed_case(const char *c, struct world *w);

static int state_case(const char *c, struct world *w)
{
   void *cmd = w->cmd;
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   struct vn_command_vkCmdDraw draw = { .commandBuffer = cb, .vertexCount = 3, .instanceCount = 1 };
   struct vn_command_vkCmdDispatch disp = { .commandBuffer = cb, .groupCountX = 1, .groupCountY = 1,
                                            .groupCountZ = 1 };
   if (IS("c-state-not-begun")) {
      step("vkCmdDraw on a command buffer never begun");
      D->dispatch_vkCmdDraw(D, &draw);
      return end(cmd);
   }
   if (IS("c-state-execute-recording")) {
      /* a secondary still recording, executed */
      void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
      if (begin_secondary(sec, NULL) != VK_SUCCESS)
         broken("secondary begin");
      begin(cmd);
      VkCommandBuffer s = (VkCommandBuffer)sec;
      struct vn_command_vkCmdExecuteCommands e = { .commandBuffer = cb, .commandBufferCount = 1,
                                                   .pCommandBuffers = &s };
      step("vkCmdExecuteCommands of a secondary that still records");
      D->dispatch_vkCmdExecuteCommands(D, &e);
      return end(cmd);
   }
   if (IS("c-state-secondary-held-resubmit-ok") || IS("c-state-secondary-held-rerecord-ok") ||
       IS("c-state-secondary-held-rerecord-submit") || IS("c-state-secondary-held-reset-submit") ||
       IS("c-state-secondary-held-pool-reset-submit") || IS("c-state-secondary-held-free-pool-reset-submit") ||
       IS("c-state-secondary-held-rerecord-end"))
      return secondary_again_case(c, w);
   if (!strncmp(c, "c-state-end-failed-", 19) || !strncmp(c, "c-state-end-hook-", 17))
      return end_failed_case(c, w);
   begin(cmd);
   if (!strncmp(c, "c-state-after-mv", 16))
      return after_mv_case(c, w);
   if (!strncmp(c, "c-state-destroyed-view", 22))
      return views_case(c, w);
   if (!strncmp(c, "c-state-secondary-held-", 23))
      return secondary_case(c, w);
   if (!strncmp(c, "c-state-destroyed-", 18))
      return destroyed_case(c, w);
   if (IS("c-state-after-end")) {
      const int r = end(cmd);
      if (r != WORKS)
         return r;
      VkViewport vp = { 0, 0, 64, 64, 0, 1 };
      struct vn_command_vkCmdSetViewport sv = { .commandBuffer = cb, .viewportCount = 1, .pViewports = &vp };
      step("vkCmdSetViewport after vkEndCommandBuffer");
      D->dispatch_vkCmdSetViewport(D, &sv);
      return ended() ? FATAL : WORKS;
   }
   if (IS("c-state-draw-no-pipeline")) {
      begin_pass(cmd, w->rp, w->fb, 64, 64);
      ready(cmd, w, VK_PIPELINE_BIND_POINT_GRAPHICS);
      step("vkCmdDraw without a pipeline");
      D->dispatch_vkCmdDraw(D, &draw);
      end_pass(cmd);
   } else if (IS("c-state-draw-outside")) {
      bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w->gfx_pipe);
      ready(cmd, w, VK_PIPELINE_BIND_POINT_GRAPHICS);
      step("vkCmdDraw outside a render pass");
      D->dispatch_vkCmdDraw(D, &draw);
   } else if (IS("c-state-dispatch-no-pipeline")) {
      ready(cmd, w, VK_PIPELINE_BIND_POINT_COMPUTE);
      step("vkCmdDispatch without a pipeline");
      D->dispatch_vkCmdDispatch(D, &disp);
   } else if (IS("c-state-dispatch-inside")) {
      bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, w->comp_pipe);
      ready(cmd, w, VK_PIPELINE_BIND_POINT_COMPUTE);
      begin_pass(cmd, w->rp, w->fb, 64, 64);
      step("vkCmdDispatch inside a render pass");
      D->dispatch_vkCmdDispatch(D, &disp);
      end_pass(cmd);
   } else if (IS("c-state-clear-outside") || IS("c-state-clear-beyond")) {
      /* the world's pass has 1 color attachment */
      const bool beyond = IS("c-state-clear-beyond");
      if (beyond)
         begin_pass(cmd, w->rp, w->fb, 64, 64);
      VkClearAttachment a = { VK_IMAGE_ASPECT_COLOR_BIT, beyond ? 1 : 0, { { { 1, 2, 3, 4 } } } };
      VkClearRect r = { { { 0, 0 }, { 64, 64 } }, 0, 1 };
      struct vn_command_vkCmdClearAttachments cl = { .commandBuffer = cb, .attachmentCount = 1, .pAttachments = &a,
                                                     .rectCount = 1, .pRects = &r };
      step("vkCmdClearAttachments color %u, %s", a.colorAttachment, beyond ? "a pass of 1 color" : "no pass");
      D->dispatch_vkCmdClearAttachments(D, &cl);
      if (beyond)
         end_pass(cmd);
   } else if (IS("c-state-next-subpass") || IS("c-state-two-subpasses-ok")) {
      void *rp = w->rp, *fb = w->fb;
      if (IS("c-state-two-subpasses-ok")) {
         rp = two_subpass_pass(NULL, 0);
         void *views[1] = { w->iv };
         fb = rp ? framebuffer(rp, views, 1, 64, 64, 1) : NULL;
         if (!fb)
            broken("two-subpass framebuffer");
      }
      begin_pass(cmd, rp, fb, 64, 64);
      struct vn_command_vkCmdNextSubpass ns = { .commandBuffer = cb, .contents = VK_SUBPASS_CONTENTS_INLINE };
      step("vkCmdNextSubpass");
      D->dispatch_vkCmdNextSubpass(D, &ns);
      end_pass(cmd);
   } else if (IS("c-state-end-no-begin")) {
      end_pass(cmd);
   } else if (IS("c-state-begin-twice")) {
      begin_pass(cmd, w->rp, w->fb, 64, 64);
      if (!ended())
         begin_pass(cmd, w->rp, w->fb, 64, 64);
      end_pass(cmd);
   } else if (IS("c-state-end-in-pass")) {
      begin_pass(cmd, w->rp, w->fb, 64, 64);
   } else if (IS("c-state-end-query-views-past")) {
      /* an end without its begin at query 3 of 4 in a 2-view pass: KosmicKrisp makes one query
       * available per view, the second past the pool */
      if (max_views < 2) {
         printf("skip: %u views\n", max_views);
         return SKIP;
      }
      void *rp = render_pass(1, 1, 0, 0x3);
      void *v = view(image(64, 64, 2, CA_SA), 2);
      void *views[1] = { v };
      void *fb = rp ? framebuffer(rp, views, 1, 64, 64, 1) : NULL;
      void *qp = query_pool(VK_QUERY_TYPE_OCCLUSION, 4);
      if (!fb)
         broken("multiview framebuffer");
      begin_pass(cmd, rp, fb, 64, 64);
      struct vn_command_vkCmdEndQuery e = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp, .query = 3 };
      step("vkCmdEndQuery 3 of 4 in a 2-view pass");
      D->dispatch_vkCmdEndQuery(D, &e);
      end_pass(cmd);
   } else if (IS("c-state-query-views-ok") || IS("c-state-query-views-past")) {
      /* a 2-view pass takes 2 queries from the one begun: query 2 or 3 of 4 */
      if (max_views < 2) {
         printf("skip: %u views\n", max_views);
         return SKIP;
      }
      void *rp = render_pass(1, 1, 0, 0x3);
      void *v = view(image(64, 64, 2, CA_SA), 2);
      void *views[1] = { v };
      void *fb = rp ? framebuffer(rp, views, 1, 64, 64, 1) : NULL;
      void *qp = query_pool(VK_QUERY_TYPE_OCCLUSION, 4);
      if (!fb)
         broken("multiview framebuffer");
      begin_pass(cmd, rp, fb, 64, 64);
      const uint32_t q = IS("c-state-query-views-ok") ? 2 : 3;
      struct vn_command_vkCmdBeginQuery b = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp, .query = q };
      step("vkCmdBeginQuery %u of 4 in a 2-view pass", q);
      D->dispatch_vkCmdBeginQuery(D, &b);
      if (!ended()) {
         struct vn_command_vkCmdEndQuery e = { .commandBuffer = cb, .queryPool = (VkQueryPool)qp, .query = q };
         D->dispatch_vkCmdEndQuery(D, &e);
      }
      end_pass(cmd);
   } else {
      return BROKEN;
   }
   return end(cmd);
}

/* copy regions (virgl-venus-copy-regions.patch): the world's images are 64 x 64 RGBA8
 * (16384 bytes), its buffers 65536 bytes */
static int region_case(const char *c, struct world *w)
{
   void *cmd = w->cmd;
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   begin(cmd);
   if (!strncmp(c, "c-region-b2i-", 13) || !strncmp(c, "c-region-i2b-", 13)) {
      VkBufferImageCopy r = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                              .imageExtent = { 64, 64, 1 } };
      if (IS("c-region-b2i-max") || IS("c-region-i2b-max"))
         r.bufferOffset = 65536 - 16384; /* the last byte the copy names is the buffer's last */
      else if (IS("c-region-b2i-past") || IS("c-region-i2b-past"))
         r.bufferOffset = 65536 - 16384 + 4;
      else if (IS("c-region-b2i-rowlength"))
         r.bufferRowLength = 0x40000000u; /* 4 GiB per row */
      else if (IS("c-region-b2i-extent"))
         r.imageExtent.width = 65;
      else if (IS("c-region-b2i-offset"))
         r.imageOffset.x = -1;
      else if (IS("c-region-b2i-aspect"))
         r.imageSubresource.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
      else
         return BROKEN;
      if (!strncmp(c, "c-region-b2i-", 13)) {
         struct vn_command_vkCmdCopyBufferToImage cpy = { .commandBuffer = cb, .srcBuffer = (VkBuffer)w->buf2,
                                                          .dstImage = (VkImage)w->img,
                                                          .dstImageLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                                          .regionCount = 1, .pRegions = &r };
         step("vkCmdCopyBufferToImage offset %llu row %u extent %ux%u at %d", (unsigned long long)r.bufferOffset,
              r.bufferRowLength, r.imageExtent.width, r.imageExtent.height, r.imageOffset.x);
         D->dispatch_vkCmdCopyBufferToImage(D, &cpy);
      } else {
         struct vn_command_vkCmdCopyImageToBuffer cpy = { .commandBuffer = cb, .srcImage = (VkImage)w->img,
                                                          .srcImageLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                                          .dstBuffer = (VkBuffer)w->buf2, .regionCount = 1,
                                                          .pRegions = &r };
         step("vkCmdCopyImageToBuffer offset %llu", (unsigned long long)r.bufferOffset);
         D->dispatch_vkCmdCopyImageToBuffer(D, &cpy);
      }
   } else if (IS("c-region-image-past") || IS("c-region-image-max")) {
      const bool past = IS("c-region-image-past");
      VkImageCopy r = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                        .srcOffset = { past ? 32 : 0, 0, 0 },
                        .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                        .dstOffset = { past ? 0 : 32, 0, 0 }, .extent = { past ? 64 : 32, 64, 1 } };
      struct vn_command_vkCmdCopyImage cpy = { .commandBuffer = cb, .srcImage = (VkImage)w->img,
                                               .srcImageLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                               .dstImage = (VkImage)w->img2,
                                               .dstImageLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                               .regionCount = 1, .pRegions = &r };
      step("vkCmdCopyImage src x %d extent %u", r.srcOffset.x, r.extent.width);
      D->dispatch_vkCmdCopyImage(D, &cpy);
   } else if (IS("c-region-blit-past") || IS("c-region-blit-mirror")) {
      /* a mirrored blit names its corners in reverse (legal); one corner at 65 is past */
      const bool past = IS("c-region-blit-past");
      VkImageBlit r = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                        .srcOffsets = { { 64, 64, 0 }, { 0, 0, 1 } },
                        .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                        .dstOffsets = { { 0, 0, 0 }, { past ? 65 : 64, 64, 1 } } };
      struct vn_command_vkCmdBlitImage b = { .commandBuffer = cb, .srcImage = (VkImage)w->img,
                                             .srcImageLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                             .dstImage = (VkImage)w->img2,
                                             .dstImageLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                             .regionCount = 1, .pRegions = &r, .filter = VK_FILTER_NEAREST };
      step("vkCmdBlitImage dst corner x %d", r.dstOffsets[1].x);
      D->dispatch_vkCmdBlitImage(D, &b);
   } else {
      return BROKEN;
   }
   return end(cmd);
}

static int inherit_case(const char *c)
{
   static uint32_t locations[1 << 16];
   VkFormat formats[64];
   for (int i = 0; i < 64; i++)
      formats[i] = FMT;
   if (IS("c-inherit-format-bad"))
      formats[0] = (VkFormat)0x7fff;
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
                           !strncmp(c, "c-state-", 8) ||
                           IS("c-bind-wrong-point") || IS("c-bind-point-bad") || !strncmp(c, "c-clear-att", 11);
   make_world(&w, needs_pipe);
   if (!strncmp(c, "c-nested", 8) || !strncmp(c, "c-execute", 9))
      return execute_case(c, &w);
   if (!strncmp(c, "c-state-", 8))
      return state_case(c, &w);
   if (!strncmp(c, "c-region-", 9))
      return region_case(c, &w);
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

/* ---------------- venus-624-c: frees, submits, dedicated memory, pass views, size 0 ---------------- */
/* a command pool with n command buffers (ids out[0..n-1]); returns the pool */
static void *pool_with_buffers(uint32_t n, void **out)
{
   const uint64_t pid = next_id++;
   VkCommandPool ph = (VkCommandPool)(uintptr_t)pid;
   VkCommandPoolCreateInfo pinfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
   struct vn_command_vkCreateCommandPool cp = { .device = DEVH, .pCreateInfo = &pinfo, .pCommandPool = &ph };
   D->dispatch_vkCreateCommandPool(D, &cp);
   if (cp.ret != VK_SUCCESS || !object(pid))
      broken("vkCreateCommandPool");
   VkCommandBuffer h[4];
   uint64_t ids[4];
   for (uint32_t i = 0; i < n && i < 4; i++) {
      ids[i] = next_id++;
      h[i] = (VkCommandBuffer)(uintptr_t)ids[i];
   }
   VkCommandBufferAllocateInfo ainfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                         .commandPool = (VkCommandPool)object(pid),
                                         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = n };
   struct vn_command_vkAllocateCommandBuffers a = { .device = DEVH, .pAllocateInfo = &ainfo, .pCommandBuffers = h };
   D->dispatch_vkAllocateCommandBuffers(D, &a);
   if (a.ret != VK_SUCCESS)
      broken("vkAllocateCommandBuffers");
   for (uint32_t i = 0; i < n && i < 4; i++)
      out[i] = object(ids[i]);
   return object(pid);
}

static void free_buffers(void *pool, void **cmds, uint32_t n)
{
   VkCommandBuffer h[4];
   for (uint32_t i = 0; i < n && i < 4; i++)
      h[i] = (VkCommandBuffer)cmds[i];
   struct vn_command_vkFreeCommandBuffers f = { .device = DEVH, .commandPool = (VkCommandPool)pool,
                                                .commandBufferCount = n, .pCommandBuffers = h };
   step("vkFreeCommandBuffers %u", n);
   D->dispatch_vkFreeCommandBuffers(D, &f);
}

static void free_sets(void *pool, void **sets, uint32_t n)
{
   VkDescriptorSet h[4];
   for (uint32_t i = 0; i < n && i < 4; i++)
      h[i] = (VkDescriptorSet)sets[i];
   struct vn_command_vkFreeDescriptorSets f = { .device = DEVH, .descriptorPool = (VkDescriptorPool)pool,
                                                .descriptorSetCount = n, .pDescriptorSets = h };
   step("vkFreeDescriptorSets %u", n);
   D->dispatch_vkFreeDescriptorSets(D, &f);
}

/* LEGAL: two objects, NULL entries, a pool reset then a new set (VUID-vkFreeCommandBuffers-
 * pCommandBuffers-parent, vkFreeDescriptorSets-pDescriptorSets-parent, -00309 (each a valid
 * handle, freed once)); refused: an object named twice, one of another pool. Before the
 * pool-frees patch KosmicKrisp destroyed a set named twice twice (SIGSEGV in
 * kk_FreeDescriptorSets) and freed a command buffer of pool B into pool A (SIGSEGV at A's
 * destroy) */
static int case_frees(const char *c)
{
   setup(0);
   if (!strncmp(c, "f-cmds", 6)) {
      void *cmds[2], *other[1];
      void *pool = pool_with_buffers(2, cmds);
      if (IS("f-cmds-ok")) {
         free_buffers(pool, cmds, 2);
      } else if (IS("f-cmds-null-ok")) {
         void *two[2] = { cmds[0], NULL };
         free_buffers(pool, two, 2);
      } else if (IS("f-cmds-dup")) {
         void *two[2] = { cmds[0], cmds[0] };
         free_buffers(pool, two, 2);
      } else if (IS("f-cmds-other-pool")) {
         void *pool_b = pool_with_buffers(1, other);
         free_buffers(pool, other, 1);
         if (!ended()) {
            struct vn_command_vkDestroyCommandPool d = { .device = DEVH, .commandPool = (VkCommandPool)pool };
            step("vkDestroyCommandPool of the pool it was freed through");
            D->dispatch_vkDestroyCommandPool(D, &d);
            struct vn_command_vkDestroyCommandPool d2 = { .device = DEVH, .commandPool = (VkCommandPool)pool_b };
            step("vkDestroyCommandPool of its own pool");
            D->dispatch_vkDestroyCommandPool(D, &d2);
         }
      } else {
         return BROKEN;
      }
      return ended() ? FATAL : WORKS;
   }
   void *dsl = set_layout();
   void *pool_a = pool();
   void *s0 = set_from(pool_a, dsl, NULL), *s1 = set_from(pool_a, dsl, NULL);
   if (!s0 || !s1)
      broken("sets");
   if (IS("f-sets-ok")) {
      void *two[2] = { s0, s1 };
      free_sets(pool_a, two, 2);
   } else if (IS("f-sets-reset-ok")) {
      struct vn_command_vkResetDescriptorPool r = { .device = DEVH, .descriptorPool = (VkDescriptorPool)pool_a };
      step("vkResetDescriptorPool");
      D->dispatch_vkResetDescriptorPool(D, &r);
      void *s2 = set_from(pool_a, dsl, NULL);
      if (!s2)
         return ERROR;
      void *one[2] = { s2, NULL };
      free_sets(pool_a, one, 2);
   } else if (IS("f-sets-dup")) {
      void *two[2] = { s0, s0 };
      free_sets(pool_a, two, 2);
   } else if (IS("f-sets-other-pool")) {
      void *pool_b = pool();
      void *sb = set_from(pool_b, dsl, NULL);
      if (!sb)
         broken("set of pool B");
      void *one[1] = { sb };
      free_sets(pool_a, one, 1);
      /* the next set of pool A may now get pool B's memory range */
      if (!ended() && !set_from(pool_a, dsl, NULL))
         return ERROR;
   } else {
      return BROKEN;
   }
   return ended() ? FATAL : WORKS;
}

/* the device's queue, through vkGetDeviceQueue2 with the ring vkr asks for */
static struct vkr_queue *device_queue(void)
{
   const uint64_t id = next_id++;
   VkQueue h = (VkQueue)(uintptr_t)id;
   VkDeviceQueueTimelineInfoMESA timeline = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_TIMELINE_INFO_MESA,
                                              .ringIdx = 1 };
   VkDeviceQueueInfo2 info = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2, .pNext = &timeline };
   struct vn_command_vkGetDeviceQueue2 g = { .device = DEVH, .pQueueInfo = &info, .pQueue = &h };
   D->dispatch_vkGetDeviceQueue2(D, &g);
   struct vkr_queue *q = object(id);
   if (!q || ended())
      broken("vkGetDeviceQueue2");
   return q;
}

static void *binary_semaphore(void)
{
   const uint64_t id = next_id++;
   VkSemaphore h = (VkSemaphore)(uintptr_t)id;
   VkSemaphoreCreateInfo info = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
   struct vn_command_vkCreateSemaphore c = { .device = DEVH, .pCreateInfo = &info, .pSemaphore = &h };
   D->dispatch_vkCreateSemaphore(D, &c);
   if (c.ret != VK_SUCCESS || !object(id))
      broken("vkCreateSemaphore");
   return object(id);
}

/* submits with no command buffer, signalling one binary semaphore: nothing is recorded,
 * nothing runs but the signal (the review's STANDARDS 14 allowance: no command buffers, not
 * fuzzed, GPU restart watch on; the queue is waited for before the child ends).
 * LEGAL: 64 timeline values with binary semaphores alone (VUIDs VkSubmitInfo-pNext-03240 and
 * -03241 tie the counts only for timeline semaphores): MoltenVK wrote the 63 extra values past
 * its array of one (MVKQueue.mm), seen under libgmalloc. Refused: device group counts that
 * differ from the submit's (VUIDs VkDeviceGroupSubmitInfo-waitSemaphoreCount-00082 ...),
 * vkQueueBindSparse on a queue without sparse binding (VUID-vkQueueBindSparse-queuetype), and
 * a value struct chained twice (VUID-VkSubmitInfo-sType-unique, VUID-VkBindSparseInfo-sType-unique):
 * vkr fitted the first, MoltenVK used the second and wrote its 64 values past its array. */
static void record_secondary(void *sec, int barriers);
static int submit_one(void *cmd, const char *what);
static void color_barrier(void *cmd);

static int case_submit(const char *c)
{
   setup(0);
   /* only an ended primary is submitted (virgl-venus-submit-state.patch); one that records a
    * barrier: a secondary, a primary still recording, one never begun (before the queue:
    * submit_one gets it) */
   if (IS("s-submit-secondary") || IS("s-submit-recording") || IS("s-submit-initial")) {
      void *cmd = command_buffer_level(IS("s-submit-secondary") ? VK_COMMAND_BUFFER_LEVEL_SECONDARY
                                                                : VK_COMMAND_BUFFER_LEVEL_PRIMARY);
      if (IS("s-submit-secondary")) {
         record_secondary(cmd, 1);
      } else if (IS("s-submit-recording")) {
         begin(cmd);
         color_barrier(cmd);
      }
      return submit_one(cmd, c);
   }
   struct vkr_queue *q = device_queue();
   const VkQueue qh = (VkQueue)q;
   static uint64_t values[64], one[1];
   if (IS("s-bind-sparse") || IS("s-bind-sparse-chain-twice")) {
      const bool chain = IS("s-bind-sparse-chain-twice");
      VkTimelineSemaphoreSubmitInfo second = { .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO };
      VkTimelineSemaphoreSubmitInfo first = { .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
                                              .pNext = &second };
      VkBindSparseInfo info = { .sType = VK_STRUCTURE_TYPE_BIND_SPARSE_INFO, .pNext = &first };
      struct vn_command_vkQueueBindSparse b = { .queue = qh, .bindInfoCount = chain ? 1 : 0,
                                                .pBindInfo = chain ? &info : NULL };
      /* no Mac driver has a sparse family: marked here, to reach the chain's check */
      if (chain)
         pdev->queue_family_properties[q->family].queueFlags |= VK_QUEUE_SPARSE_BINDING_BIT;
      step("vkQueueBindSparse on a queue of family %u", q->family);
      D->dispatch_vkQueueBindSparse(D, &b);
      return ended() ? FATAL : (b.ret == VK_SUCCESS ? WORKS : ERROR);
   }
   VkSemaphore sem = (VkSemaphore)binary_semaphore();
   uint32_t indices[2] = { 0, 0 };
   VkTimelineSemaphoreSubmitInfo timeline = { .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
                                              .signalSemaphoreValueCount = 64, .pSignalSemaphoreValues = values };
   VkDeviceGroupSubmitInfo group = { .sType = VK_STRUCTURE_TYPE_DEVICE_GROUP_SUBMIT_INFO, .waitSemaphoreCount = 1,
                                     .pWaitSemaphoreDeviceIndices = indices, .signalSemaphoreCount = 1,
                                     .pSignalSemaphoreDeviceIndices = indices };
   VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .signalSemaphoreCount = 1,
                           .pSignalSemaphores = &sem };
   VkTimelineSemaphoreSubmitInfo fits = { .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
                                          .pNext = &timeline, .signalSemaphoreValueCount = 1,
                                          .pSignalSemaphoreValues = one };
   if (IS("s-submit-values-64"))
      submit.pNext = &timeline;
   else if (IS("s-submit-chain-twice"))
      submit.pNext = &fits;
   else if (IS("s-submit-group-counts"))
      submit.pNext = &group;
   else if (!IS("s-submit-ok"))
      return BROKEN;
   struct vn_command_vkQueueSubmit s = { .queue = qh, .submitCount = 1, .pSubmits = &submit };
   step("vkQueueSubmit: no command buffer, one binary semaphore signalled, chain %s", c);
   D->dispatch_vkQueueSubmit(D, &s);
   step("vkQueueSubmit = %d", s.ret);
   if (ended())
      return FATAL;
   /* the driver's own wait (vkr refuses vkQueueWaitIdle from a guest) */
   q->device->proc_table.QueueWaitIdle(q->base.handle.queue);
   step("the queue is idle");
   return s.ret == VK_SUCCESS ? WORKS : ERROR;
}

/* an image not bound yet (flags: create flags), size x size */
static struct vkr_image *image_unbound_size(VkImageCreateFlags flags, VkFormat format, VkImageUsageFlags usage,
                                            uint32_t size)
{
   const uint64_t id = next_id++;
   VkImage hd = (VkImage)(uintptr_t)id;
   VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .flags = flags,
                              .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = { size, size, 1 },
                              .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                              .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = usage };
   struct vn_command_vkCreateImage c = { .device = DEVH, .pCreateInfo = &info, .pImage = &hd };
   D->dispatch_vkCreateImage(D, &c);
   struct vkr_image *img = object(id);
   if (c.ret != VK_SUCCESS || !img)
      broken("vkCreateImage");
   return img;
}

static struct vkr_image *image_unbound(VkImageCreateFlags flags, VkFormat format, VkImageUsageFlags usage)
{
   return image_unbound_size(flags, format, usage, 64);
}

static struct vkr_buffer *buffer_unbound(VkDeviceSize size)
{
   const uint64_t id = next_id++;
   VkBuffer h = (VkBuffer)(uintptr_t)id;
   VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                               .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
   struct vn_command_vkCreateBuffer c = { .device = DEVH, .pCreateInfo = &info, .pBuffer = &h };
   D->dispatch_vkCreateBuffer(D, &c);
   struct vkr_buffer *buf = object(id);
   if (c.ret != VK_SUCCESS || !buf)
      broken("vkCreateBuffer");
   return buf;
}

static VkMemoryRequirements requirements_of(struct vkr_image *img, struct vkr_buffer *buf)
{
   VkMemoryRequirements req = { 0 };
   if (img) {
      struct vn_command_vkGetImageMemoryRequirements r = { .device = DEVH, .image = (VkImage)img,
                                                           .pMemoryRequirements = &req };
      D->dispatch_vkGetImageMemoryRequirements(D, &r);
   } else {
      struct vn_command_vkGetBufferMemoryRequirements r = { .device = DEVH, .buffer = (VkBuffer)buf,
                                                            .pMemoryRequirements = &req };
      D->dispatch_vkGetBufferMemoryRequirements(D, &r);
   }
   return req;
}

/* memory with this chain; NULL once a refusal ended the context */
static struct vkr_device_memory *chained_memory(const void *chain, const VkMemoryRequirements *req)
{
   const uint64_t id = next_id++;
   VkDeviceMemory h = (VkDeviceMemory)(uintptr_t)id;
   VkMemoryAllocateInfo info = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = chain,
                                 .allocationSize = req->size, .memoryTypeIndex = memory_type(req->memoryTypeBits) };
   struct vn_command_vkAllocateMemory a = { .device = DEVH, .pAllocateInfo = &info, .pMemory = &h };
   step("vkAllocateMemory %llu bytes, dedicated", (unsigned long long)req->size);
   D->dispatch_vkAllocateMemory(D, &a);
   if (ended())
      return NULL;
   if (a.ret != VK_SUCCESS || !object(id))
      broken("dedicated vkAllocateMemory");
   return object(id);
}

/* memory dedicated to the image or the buffer (VkMemoryDedicatedAllocateInfo), of its size */
static struct vkr_device_memory *dedicated_memory(struct vkr_image *img, struct vkr_buffer *buf)
{
   const VkMemoryRequirements req = requirements_of(img, buf);
   VkMemoryDedicatedAllocateInfo ded = { .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
                                         .image = (VkImage)img, .buffer = (VkBuffer)buf };
   return chained_memory(&ded, &req);
}

static VkResult bind_image_at(struct vkr_image *img, struct vkr_device_memory *mem)
{
   struct vn_command_vkBindImageMemory b = { .device = DEVH, .image = (VkImage)img, .memory = (VkDeviceMemory)mem };
   step("vkBindImageMemory");
   D->dispatch_vkBindImageMemory(D, &b);
   return b.ret;
}

static void destroy_image(struct vkr_image *img)
{
   struct vn_command_vkDestroyImage d = { .device = DEVH, .image = (VkImage)img };
   step("vkDestroyImage");
   D->dispatch_vkDestroyImage(D, &d);
}

static void free_memory(struct vkr_device_memory *mem)
{
   struct vn_command_vkFreeMemory f = { .device = DEVH, .memory = (VkDeviceMemory)mem };
   step("vkFreeMemory");
   D->dispatch_vkFreeMemory(D, &f);
}

/* LEGAL: memory dedicated to an image or buffer that is destroyed before it is bound, then
 * the memory freed (MoltenVK kept the target in the memory and wrote to it at the free:
 * freed memory, seen under libgmalloc), also when the app's context ends in between; bound,
 * then destroyed and freed. Refused (the bind ends the context): another image on memory
 * dedicated to one (VUID-vkBindImageMemory-memory-02628), a buffer on memory dedicated to an
 * image (VUID-vkBindBufferMemory-memory-10925). Two ALIAS_BIT images on such memory with
 * the same create info are what guest Mesa binds for VkBindImageMemorySwapchainInfoKHR: the
 * x-dedicated-alias cases (case_alias). Refused at the
 * allocation (the chain names one thing for vkr and another for MoltenVK, whose loop keeps
 * the last, VUID-VkMemoryAllocateInfo-sType-unique): a dedicated struct chained twice, the
 * first naming image A or nothing, then image B destroyed before the free; a target of
 * another device. */
static int case_alias(const char *c);

static int case_dedicated(const char *c)
{
   if (!strncmp(c, "x-dedicated-alias", 17))
      return case_alias(c);
   setup(0);
   const VkImageUsageFlags usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
   if (IS("x-dedicated-chain-twice") || IS("x-dedicated-chain-null")) {
      struct vkr_image *a = image_unbound(0, FMT, usage), *b = image_unbound(0, FMT, usage);
      const VkMemoryRequirements req = requirements_of(b, NULL);
      VkMemoryDedicatedAllocateInfo second = { .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
                                               .image = (VkImage)b };
      VkMemoryDedicatedAllocateInfo first = { .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
                                              .pNext = &second,
                                              .image = IS("x-dedicated-chain-twice") ? (VkImage)a : VK_NULL_HANDLE };
      struct vkr_device_memory *mem = chained_memory(&first, &req);
      if (!mem)
         return FATAL;
      destroy_image(b);
      free_memory(mem);
      return ended() ? FATAL : WORKS;
   }
   if (IS("x-dedicated-other-device")) {
      struct vkr_image *a = image_unbound(0, FMT, usage);
      const VkMemoryRequirements req = requirements_of(a, NULL);
      setup_device(0);
      VkMemoryDedicatedAllocateInfo ded = { .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
                                            .image = (VkImage)a };
      chained_memory(&ded, &req);
      return ended() ? FATAL : WORKS;
   }
   if (IS("x-dedicated-buffer-unbound-ok")) {
      struct vkr_buffer *buf = buffer_unbound(65536);
      struct vkr_device_memory *mem = dedicated_memory(NULL, buf);
      struct vn_command_vkDestroyBuffer d = { .device = DEVH, .buffer = (VkBuffer)buf };
      step("vkDestroyBuffer before any bind");
      D->dispatch_vkDestroyBuffer(D, &d);
      free_memory(mem);
      return ended() ? FATAL : WORKS;
   }
   struct vkr_image *a = image_unbound(0, FMT, usage);
   struct vkr_device_memory *mem = dedicated_memory(a, NULL);
   if (IS("x-dedicated-bound-ok")) {
      if (bind_image_at(a, mem) != VK_SUCCESS)
         return ended() ? FATAL : ERROR;
      destroy_image(a);
      free_memory(mem);
   } else if (IS("x-dedicated-unbound-ok")) {
      destroy_image(a);
      free_memory(mem);
   } else if (IS("x-dedicated-context-end-ok")) {
      step("the context ends with the image unbound");
      vkr_context_destroy(ctx);
      step("the context is gone");
      return WORKS;
   } else if (IS("x-dedicated-other")) {
      struct vkr_image *b = image_unbound(0, FMT, usage);
      bind_image_at(b, mem);
      if (!ended()) {
         free_memory(mem);
         destroy_image(b);
      }
   } else if (IS("x-dedicated-buffer-to-image")) {
      struct vkr_buffer *buf = buffer_unbound(4096);
      struct vn_command_vkBindBufferMemory b = { .device = DEVH, .buffer = (VkBuffer)buf,
                                                 .memory = (VkDeviceMemory)mem };
      step("vkBindBufferMemory to memory dedicated to an image");
      D->dispatch_vkBindBufferMemory(D, &b);
   } else {
      return BROKEN;
   }
   return ended() ? FATAL : WORKS;
}

/* LEGAL controls: a 0-byte vkAllocateMemory of device-local and host-visible memory; both
 * drivers live through it (an error or a 0-byte allocation), vkr passes it on */
static int case_memory(const char *c)
{
   setup(0);
   const VkPhysicalDeviceMemoryProperties *mp = &pdev->memory_properties;
   const VkMemoryPropertyFlags want =
      IS("m-alloc0-host") ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
   uint32_t type = UINT32_MAX;
   for (uint32_t i = 0; i < mp->memoryTypeCount && type == UINT32_MAX; i++)
      if ((mp->memoryTypes[i].propertyFlags & want) == want)
         type = i;
   if (type == UINT32_MAX)
      return SKIP;
   const uint64_t id = next_id++;
   VkDeviceMemory h = (VkDeviceMemory)(uintptr_t)id;
   VkMemoryAllocateInfo info = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = 0,
                                 .memoryTypeIndex = type };
   struct vn_command_vkAllocateMemory a = { .device = DEVH, .pAllocateInfo = &info, .pMemory = &h };
   step("vkAllocateMemory 0 bytes of type %u", type);
   D->dispatch_vkAllocateMemory(D, &a);
   step("vkAllocateMemory = %d", a.ret);
   if (ended())
      return FATAL;
   if (a.ret != VK_SUCCESS)
      return ERROR;
   free_memory(object(id));
   return ended() ? FATAL : WORKS;
}

/* the image views of an open pass destroyed while it records: refused at the begin (a
 * framebuffer's), the next subpass and the end (Mesa's vk_render_pass reads them there, and
 * KosmicKrisp a rendering's at its end); destroyed after the command buffer ended, another
 * one records a pass (MallocScribble as the destroyed-pass cases) */
static void destroy_view(void *v)
{
   struct vn_command_vkDestroyImageView d = { .device = DEVH, .imageView = (VkImageView)v };
   step("vkDestroyImageView");
   D->dispatch_vkDestroyImageView(D, &d);
}

static int views_case(const char *c, struct world *w)
{
   void *cmd = w->cmd;
   void *v = view(w->img, 1);
   void *views[1] = { v };
   if (!strncmp(c, "c-state-destroyed-view-held-", 28))
      return held_case(c, w, v);
   /* LEGAL: with no resolve the resolve view is ignored, destroying it changes nothing */
   const bool ignored = IS("c-state-destroyed-view-resolve-none-ok");
   if (IS("c-state-destroyed-view-rendering") || ignored) {
      void *other = ignored ? view(w->img, 1) : NULL;
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                        .imageView = (VkImageView)v, .resolveImageView = (VkImageView)other,
                                        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                                        .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                             .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
      struct vn_command_vkCmdBeginRendering b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderingInfo = &ri };
      step("vkCmdBeginRendering");
      D->dispatch_vkCmdBeginRendering(D, &b);
      destroy_view(ignored ? other : v);
      if (!ended()) {
         struct vn_command_vkCmdEndRendering e = { .commandBuffer = (VkCommandBuffer)cmd };
         step("vkCmdEndRendering");
         D->dispatch_vkCmdEndRendering(D, &e);
      }
      return end(cmd);
   }
   if (IS("c-state-destroyed-view-imageless")) {
      void *fb = imageless_framebuffer(w->rp);
      if (!fb)
         return SKIP;
      VkImageView vh = (VkImageView)v;
      VkRenderPassAttachmentBeginInfo ab = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_ATTACHMENT_BEGIN_INFO,
                                             .attachmentCount = 1, .pAttachments = &vh };
      VkClearValue clear = { 0 };
      VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .pNext = &ab,
                                   .renderPass = (VkRenderPass)w->rp, .framebuffer = (VkFramebuffer)fb,
                                   .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1,
                                   .pClearValues = &clear };
      struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderPassBegin = &bi,
                                                   .contents = VK_SUBPASS_CONTENTS_INLINE };
      step("vkCmdBeginRenderPass (imageless)");
      D->dispatch_vkCmdBeginRenderPass(D, &b);
      destroy_view(v);
      end_pass(cmd);
      return end(cmd);
   }
   const bool next = IS("c-state-destroyed-view-next");
   void *rp = next ? two_subpass_pass(NULL, 0) : w->rp;
   void *fb = rp ? framebuffer(rp, views, 1, 64, 64, 1) : NULL;
   if (!fb)
      broken("framebuffer of a fresh view");
   if (IS("c-state-destroyed-view-begin")) {
      destroy_view(v);
      begin_pass(cmd, rp, fb, 64, 64);
      end_pass(cmd);
      return end(cmd);
   }
   begin_pass(cmd, rp, fb, 64, 64);
   if (IS("c-state-destroyed-view-after-ok")) {
      /* the command buffer ended first (destroying a view a recording one uses makes it
       * invalid), then another records a pass */
      end_pass(cmd);
      const int r = end(cmd);
      if (r != WORKS)
         return r;
      destroy_view(v);
      void *cmd2 = command_buffer();
      begin(cmd2);
      begin_pass(cmd2, w->rp, w->fb, 64, 64);
      end_pass(cmd2);
      return end(cmd2);
   }
   destroy_view(v);
   if (next && !ended()) {
      struct vn_command_vkCmdNextSubpass ns = { .commandBuffer = (VkCommandBuffer)cmd,
                                                .contents = VK_SUBPASS_CONTENTS_INLINE };
      step("vkCmdNextSubpass");
      D->dispatch_vkCmdNextSubpass(D, &ns);
   } else if (!IS("c-state-destroyed-view-end")) {
      return BROKEN;
   }
   end_pass(cmd);
   return end(cmd);
}

/* ---------------- held views (virgl-venus-command-holds.patch) ---------------- */

/* a 64x64 color image of `samples` and a view of it (MSAA: an attachment only) */
static void *ms_view(VkSampleCountFlagBits samples)
{
   const uint64_t id = next_id++;
   VkImage hd = (VkImage)(uintptr_t)id;
   VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                              .format = FMT, .extent = { 64, 64, 1 }, .mipLevels = 1, .arrayLayers = 1,
                              .samples = samples, .tiling = VK_IMAGE_TILING_OPTIMAL,
                              .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT };
   struct vn_command_vkCreateImage c = { .device = DEVH, .pCreateInfo = &info, .pImage = &hd };
   D->dispatch_vkCreateImage(D, &c);
   struct vkr_image *img = object(id);
   if (c.ret != VK_SUCCESS || !img)
      broken("vkCreateImage (MSAA)");
   const VkMemoryRequirements req = requirements_of(img, NULL);
   if (bind_image_at(img, allocate(req.size, memory_type(req.memoryTypeBits))) != VK_SUCCESS)
      broken("vkBindImageMemory (MSAA)");
   return view(img, 1);
}

/* a pass of a 4x color attachment (0) resolved into a 1x one (1), with a self-dependency
 * (barriers inside it are legal) */
static void *ms_pass(void)
{
   VkAttachmentDescription att[2] = {
      { 0, FMT, VK_SAMPLE_COUNT_4_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_DONT_CARE,
        VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL },
      { 0, FMT, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_STORE,
        VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL } };
   VkAttachmentReference color = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL },
                         resolve = { 1, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
   VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
                                .pColorAttachments = &color, .pResolveAttachments = &resolve };
   VkSubpassDependency self = { 0, 0, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                VK_ACCESS_COLOR_ATTACHMENT_READ_BIT, VK_DEPENDENCY_BY_REGION_BIT };
   const uint64_t id = next_id++;
   VkRenderPass h = (VkRenderPass)(uintptr_t)id;
   VkRenderPassCreateInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2,
                                   .pAttachments = att, .subpassCount = 1, .pSubpasses = &sub,
                                   .dependencyCount = 1, .pDependencies = &self };
   struct vn_command_vkCreateRenderPass c = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
   step("vkCreateRenderPass: 4x color resolved into 1x");
   D->dispatch_vkCreateRenderPass(D, &c);
   if (c.ret != VK_SUCCESS || !object(id))
      broken("vkCreateRenderPass (MSAA)");
   return object(id);
}

/* a memory barrier between color attachment writes and reads (inside a pass: by region) */
static void color_barrier(void *cmd)
{
   if (ended())
      return;
   VkMemoryBarrier2 mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
                           .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                           .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                           .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                           .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT };
   VkDependencyInfo dep = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                            .dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT, .memoryBarrierCount = 1,
                            .pMemoryBarriers = &mb };
   struct vn_command_vkCmdPipelineBarrier2 b = { .commandBuffer = (VkCommandBuffer)cmd, .pDependencyInfo = &dep };
   step("vkCmdPipelineBarrier2 (color writes to reads, by region)");
   D->dispatch_vkCmdPipelineBarrier2(D, &b);
}

static void reset_command_buffer(void *cmd)
{
   struct vn_command_vkResetCommandBuffer r = { .commandBuffer = (VkCommandBuffer)cmd };
   step("vkResetCommandBuffer");
   D->dispatch_vkResetCommandBuffer(D, &r);
   step("vkResetCommandBuffer = %d", r.ret);
}

/* zombies of the device: objects destroyed while a command buffer held them (-1: this vkr
 * has no holds) */
static int zombies(void)
{
#ifdef VKR_COMMAND_HOLDS
   return (int)list_length(&dev->zombies);
#else
   return -1;
#endif
}

/* The app destroys image views (and their image, memory, framebuffer, render pass) that a
 * command buffer named: the command buffer becomes invalid (legal) and vkr keeps the
 * driver's objects until the command buffer is reset, begun again or freed.
 *   -rendering-barrier, -pass-barrier: a 4x pass resolving into a 1x view; the resolve
 *     view is destroyed inside it, then a barrier: KosmicKrisp's barrier with samples > 1
 *     applies the pass's store ops and reads the resolve view (kk_cmd_buffer.c). Refused at
 *     the pass's end (the view is gone from vkr's table), as with -end.
 *   -submit: recorded, ended, the view destroyed, then submitted and waited for: MoltenVK
 *     encodes at the submit (MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS) and reads the view's
 *     object then. MoltenVK only, not with prefill (its encode was at the end), not on
 *     KosmicKrisp (it encodes while recording and its pending reads are the GPU's).
 *   -reset-ok, -begin-ok, -free-ok: LEGAL: recorded, ended, the view destroyed, then the
 *     command buffer reset, begun again or freed; with holds the view is a zombie until then.
 *   -image-memory-ok: LEGAL: the view, its image and the image's memory go, then a reset.
 *   -teardown-ok: LEGAL: view, framebuffer and render pass destroyed, then the context ends.
 *   -control-ok: the view destroyed after a reset is destroyed at once (no zombie).
 * The reset, free and teardown cases skip MoltenVK with prefill (its reset commits the
 * prefilled Metal command buffer: GPU work on a view vkr without holds destroyed). */
static int held_case(const char *c, struct world *w, void *v)
{
   void *cmd = w->cmd;
   const bool prefill = getenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS") != NULL;
   if (IS("c-state-destroyed-view-held-rendering-barrier")) {
      void *msv = ms_view(VK_SAMPLE_COUNT_4_BIT);
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                        .imageView = (VkImageView)msv, .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT, .resolveImageView = (VkImageView)v,
                                        .resolveImageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                             .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
      struct vn_command_vkCmdBeginRendering b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderingInfo = &ri };
      step("vkCmdBeginRendering: 4x resolved into the view");
      D->dispatch_vkCmdBeginRendering(D, &b);
      destroy_view(v);
      color_barrier(cmd);
      if (!ended()) {
         struct vn_command_vkCmdEndRendering e = { .commandBuffer = (VkCommandBuffer)cmd };
         step("vkCmdEndRendering");
         D->dispatch_vkCmdEndRendering(D, &e);
      }
      return end(cmd);
   }
   if (IS("c-state-destroyed-view-held-pass-barrier")) {
      void *rp = ms_pass();
      void *att[2] = { ms_view(VK_SAMPLE_COUNT_4_BIT), v };
      void *fb = framebuffer(rp, att, 2, 64, 64, 1);
      if (!fb)
         broken("framebuffer (MSAA)");
      begin_pass_clear(cmd, rp, fb, 64, 64, 1);
      destroy_view(v);
      color_barrier(cmd);
      end_pass(cmd);
      return end(cmd);
   }

   /* -image-memory-ok: a view of an image whose memory the case frees */
   struct vkr_image *img = NULL;
   struct vkr_device_memory *mem = NULL;
   if (IS("c-state-destroyed-view-held-image-memory-ok")) {
      img = image_unbound(0, FMT, CA_SA);
      const VkMemoryRequirements req = requirements_of(img, NULL);
      mem = allocate(req.size, memory_type(req.memoryTypeBits));
      if (bind_image_at(img, mem) != VK_SUCCESS)
         broken("vkBindImageMemory");
      v = view(img, 1);
   }

   /* recorded and ended: a pass on a framebuffer of the view */
   void *rp = render_pass(1, 1, 0, 0);
   void *views[1] = { v };
   void *fb = rp ? framebuffer(rp, views, 1, 64, 64, 1) : NULL;
   if (!fb)
      broken("framebuffer of a fresh view");
   begin_pass(cmd, rp, fb, 64, 64);
   end_pass(cmd);
   int r = end(cmd);
   if (r != WORKS)
      return r;

   if (IS("c-state-destroyed-view-held-submit")) {
      if (kosmickrisp || prefill) {
         printf("skip: %s\n", kosmickrisp ? "KosmicKrisp encodes while recording (its pending reads are the GPU's)"
                                          : "MoltenVK with prefill encoded at the end");
         return SKIP;
      }
      destroy_view(v);
      struct vkr_queue *q = device_queue();
      VkCommandBuffer cb = (VkCommandBuffer)cmd;
      VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
                              .pCommandBuffers = &cb };
      struct vn_command_vkQueueSubmit s = { .queue = (VkQueue)q, .submitCount = 1, .pSubmits = &submit };
      step("vkQueueSubmit of the command buffer whose view was destroyed (a 64x64 clear)");
      D->dispatch_vkQueueSubmit(D, &s);
      step("vkQueueSubmit = %d", s.ret);
      if (ended())
         return FATAL;
      q->device->proc_table.QueueWaitIdle(q->base.handle.queue);
      step("the queue is idle");
      return s.ret == VK_SUCCESS ? WORKS : ERROR;
   }
   if (prefill) {
      printf("skip: MoltenVK with prefill commits its Metal command buffer at a reset\n");
      return SKIP;
   }
   if (IS("c-state-destroyed-view-held-control-ok")) {
      reset_command_buffer(cmd);
      destroy_view(v);
      step("zombies after the reset and the destroy: %d", zombies());
      return zombies() > 0 ? ERROR : WORKS;
   }
   destroy_view(v);
   step("zombies after the destroy: %d", zombies());
   if (zombies() == 0)
      return ERROR;
   if (IS("c-state-destroyed-view-held-image-memory-ok")) {
      destroy_image(img);
      free_memory(mem);
      reset_command_buffer(cmd);
   } else if (IS("c-state-destroyed-view-held-reset-ok")) {
      reset_command_buffer(cmd);
   } else if (IS("c-state-destroyed-view-held-begin-ok")) {
      begin(cmd);
      r = end(cmd);
      if (r != WORKS)
         return r;
   } else if (IS("c-state-destroyed-view-held-free-ok")) {
      struct vkr_command_buffer *cbo = cmd;
      VkCommandBuffer cb = (VkCommandBuffer)cmd;
      struct vn_command_vkFreeCommandBuffers f = { .device = DEVH, .commandPool = (VkCommandPool)cbo->pool,
                                                   .commandBufferCount = 1, .pCommandBuffers = &cb };
      step("vkFreeCommandBuffers");
      D->dispatch_vkFreeCommandBuffers(D, &f);
   } else if (IS("c-state-destroyed-view-held-teardown-ok")) {
      struct vn_command_vkDestroyFramebuffer df = { .device = DEVH, .framebuffer = (VkFramebuffer)fb };
      struct vn_command_vkDestroyRenderPass dr = { .device = DEVH, .renderPass = (VkRenderPass)rp };
      step("vkDestroyFramebuffer, vkDestroyRenderPass");
      D->dispatch_vkDestroyFramebuffer(D, &df);
      D->dispatch_vkDestroyRenderPass(D, &dr);
      if (ended())
         return FATAL;
      step("the context ends with the command buffer recorded");
      vkr_context_destroy(ctx);
      step("the context is gone");
      return WORKS;
   } else {
      return BROKEN;
   }
   if (ended())
      return FATAL;
   step("zombies now: %d", zombies());
   return zombies() > 0 ? ERROR : WORKS;
}

/* PROBE (no fix here): a view written into a descriptor set the command buffer binds, the
 * view destroyed (a stale descriptor nothing uses is legal), then the command buffer
 * submitted: whether MoltenVK reads the view at the bind or the submit. MoltenVK only (not
 * with prefill); the outcome is printed, not judged. */
static int descriptor_probe(struct world *w)
{
   const bool prefill = getenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS") != NULL;
   if (kosmickrisp || prefill) {
      printf("skip: MoltenVK only, without prefill\n");
      return SKIP;
   }
   void *cmd = w->cmd;
   void *v = view(w->img, 1);
   VkDescriptorImageInfo cis = { (VkSampler)w->smp, (VkImageView)v, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
   VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)w->set,
                               .dstBinding = 1, .descriptorCount = 1,
                               .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &cis };
   struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = 1, .pDescriptorWrites = &wr };
   step("vkUpdateDescriptorSets: the view at binding 1");
   D->dispatch_vkUpdateDescriptorSets(D, &u);
   begin(cmd);
   uint32_t offset = 0;
   bind_sets(cmd, w->layout, 0, &w->set, 1, &offset, 1);
   int r = end(cmd);
   if (r != WORKS)
      return r;
   destroy_view(v);
   struct vkr_queue *q = device_queue();
   VkCommandBuffer cb = (VkCommandBuffer)cmd;
   VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
   struct vn_command_vkQueueSubmit s = { .queue = (VkQueue)q, .submitCount = 1, .pSubmits = &submit };
   step("vkQueueSubmit: the set bound, its view destroyed, nothing dispatched");
   D->dispatch_vkQueueSubmit(D, &s);
   step("vkQueueSubmit = %d", s.ret);
   if (ended())
      return FATAL;
   q->device->proc_table.QueueWaitIdle(q->base.handle.queue);
   step("the queue is idle");
   return s.ret == VK_SUCCESS ? WORKS : ERROR;
}

/* A primary executes a secondary, then the app frees the secondary or destroys its pool
 * (invalid for the primary, legal to do): MoltenVK's vkCmdExecuteCommands keeps the
 * secondary's pointer (MVKCmdExecuteCommands) and reads it when it encodes the primary at
 * vkQueueSubmit; its pool's destroy frees it (a free alone hands it back to the pool,
 * reset). With virgl-venus-secondary-holds.patch the primary holds the secondary until it
 * is reset, begun again or freed: the freed secondary is a zombie, and so is its destroyed
 * pool, until then.
 *   -free-submit, -pool-submit: the secondary freed (and its pool destroyed), then the
 *     primary submitted and waited for (a barrier: legal GPU work).
 *   -reset-ok, -free-primary-ok: LEGAL: then the primary reset or freed: no zombie left.
 *   -same-pool-ok: LEGAL: both in one pool, the secondary freed, the pool destroyed.
 *   -teardown-ok: LEGAL: the context ends with the zombies.
 *   -control-ok: the secondary freed after the primary's reset goes at once. */
static void *command_buffer_in(void *pool, VkCommandBufferLevel level)
{
   const uint64_t cid = next_id++;
   VkCommandBuffer ch = (VkCommandBuffer)(uintptr_t)cid;
   VkCommandBufferAllocateInfo ainfo = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                         .commandPool = (VkCommandPool)pool, .level = level,
                                         .commandBufferCount = 1 };
   struct vn_command_vkAllocateCommandBuffers a = { .device = DEVH, .pAllocateInfo = &ainfo, .pCommandBuffers = &ch };
   D->dispatch_vkAllocateCommandBuffers(D, &a);
   if (a.ret != VK_SUCCESS || !object(cid))
      broken("vkAllocateCommandBuffers");
   return object(cid);
}

static void free_command_buffer(void *cmd)
{
   struct vkr_command_buffer *cbo = cmd;
   VkCommandBuffer cb = (VkCommandBuffer)cmd;
   struct vn_command_vkFreeCommandBuffers f = { .device = DEVH, .commandPool = (VkCommandPool)cbo->pool,
                                                .commandBufferCount = 1, .pCommandBuffers = &cb };
   step("vkFreeCommandBuffers");
   D->dispatch_vkFreeCommandBuffers(D, &f);
}

static void destroy_command_pool(void *pool)
{
   struct vn_command_vkDestroyCommandPool d = { .device = DEVH, .commandPool = (VkCommandPool)pool };
   step("vkDestroyCommandPool");
   D->dispatch_vkDestroyCommandPool(D, &d);
}

static int secondary_case(const char *c, struct world *w)
{
   void *cmd = w->cmd;
   const bool same = IS("c-state-secondary-held-same-pool-ok");
   void *sec = same ? command_buffer_in(((struct vkr_command_buffer *)cmd)->pool,
                                        VK_COMMAND_BUFFER_LEVEL_SECONDARY)
                    : command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
   void *pool = ((struct vkr_command_buffer *)sec)->pool;
   if (begin_secondary(sec, NULL) != VK_SUCCESS)
      broken("secondary begin");
   color_barrier(sec);
   int r = end(sec);
   if (r != WORKS)
      return r;
   VkCommandBuffer s = (VkCommandBuffer)sec;
   struct vn_command_vkCmdExecuteCommands e = { .commandBuffer = (VkCommandBuffer)cmd, .commandBufferCount = 1,
                                                .pCommandBuffers = &s };
   step("vkCmdExecuteCommands of the secondary");
   D->dispatch_vkCmdExecuteCommands(D, &e);
   r = end(cmd);
   if (r != WORKS)
      return r;

   if (IS("c-state-secondary-held-control-ok")) {
      reset_command_buffer(cmd);
      free_command_buffer(sec);
      step("zombies after the reset and the free: %d", zombies());
      return ended() ? FATAL : zombies() > 0 ? ZOMBIES : WORKS;
   }
   if (same) {
      free_command_buffer(sec);
      step("zombies after the free: %d", zombies());
      if (zombies() != 1)
         return ended() ? FATAL : ZOMBIES;
      destroy_command_pool(pool);
      step("zombies after the pool's destroy: %d", zombies());
      return ended() ? FATAL : zombies() > 0 ? ZOMBIES : WORKS;
   }
   /* the submit cases submit whatever vkr kept (the driver's read is what they test), then
    * judge the zombies */
   const bool submit = IS("c-state-secondary-held-free-submit") || IS("c-state-secondary-held-pool-submit");
   free_command_buffer(sec);
   int z = zombies();
   step("zombies after the free: %d", z);
   if (z != 1 && !submit)
      return ended() ? FATAL : ZOMBIES;
   if (!IS("c-state-secondary-held-free-submit")) {
      destroy_command_pool(pool);
      z = zombies();
      step("zombies after the pool's destroy: %d", z);
      if (z != 2 && !submit)
         return ended() ? FATAL : ZOMBIES;
   }
   if (submit) {
      const int want = IS("c-state-secondary-held-free-submit") ? 1 : 2;
      struct vkr_queue *q = device_queue();
      VkCommandBuffer cb = (VkCommandBuffer)cmd;
      VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
                              .pCommandBuffers = &cb };
      struct vn_command_vkQueueSubmit qs = { .queue = (VkQueue)q, .submitCount = 1, .pSubmits = &submit };
      step("vkQueueSubmit of the primary whose secondary was freed");
      D->dispatch_vkQueueSubmit(D, &qs);
      step("vkQueueSubmit = %d", qs.ret);
      if (ended())
         return FATAL;
      q->device->proc_table.QueueWaitIdle(q->base.handle.queue);
      step("the queue is idle; zombies: %d (want %d)", z, want);
      return qs.ret != VK_SUCCESS ? ERROR : z != want ? ZOMBIES : WORKS;
   }
   if (IS("c-state-secondary-held-reset-ok")) {
      reset_command_buffer(cmd);
   } else if (IS("c-state-secondary-held-free-primary-ok")) {
      free_command_buffer(cmd);
   } else if (IS("c-state-secondary-held-teardown-ok")) {
      step("the context ends with the primary recorded");
      vkr_context_destroy(ctx);
      step("the context is gone");
      return WORKS;
   } else {
      return BROKEN;
   }
   if (ended())
      return FATAL;
   step("zombies now: %d", zombies());
   return zombies() > 0 ? ZOMBIES : WORKS;
}

/* ---------------- secondaries recorded again (virgl-venus-submit-state.patch) ----------------
 * A primary P executes a secondary S that records one barrier.
 *   -resubmit-ok: TOLERATED: P reusable (no ONE_TIME_SUBMIT), S freed (a zombie), P submitted
 *     twice, each waited for: KosmicKrisp replays S's commands at the 2nd submit. Vulkan
 *     calls P invalid once S is freed; vkr allows it on purpose (the hold keeps it
 *     memory-safe).
 *   -rerecord-submit, -reset-submit, -pool-reset-submit, -free-pool-reset-submit: after P's
 *     end S is begun again (two barriers), reset, its pool reset, or freed and then its pool
 *     reset; P's submit is refused (Vulkan: P is invalid; MoltenVK encodes S's new content
 *     past what vkr weighed at the execute, KosmicKrisp replays it at a 2nd submit).
 *   -rerecord-end: S begun again before P's end: the end is refused (MoltenVK with prefill
 *     encodes S there).
 *   -rerecord-ok: LEGAL: S recorded again, P's pool reset, P recorded again, submitted and
 *     waited for. */
static void record_secondary(void *sec, int barriers)
{
   if (begin_secondary(sec, NULL) != VK_SUCCESS)
      broken("secondary begin");
   for (int i = 0; i < barriers; i++)
      color_barrier(sec);
   if (end(sec) != WORKS)
      broken("secondary end");
}

static void reset_command_pool(void *pool)
{
   struct vn_command_vkResetCommandPool r = { .device = DEVH, .commandPool = (VkCommandPool)pool };
   step("vkResetCommandPool");
   D->dispatch_vkResetCommandPool(D, &r);
   step("vkResetCommandPool = %d", r.ret);
}

static void begin_flags(void *cmd, VkCommandBufferUsageFlags flags)
{
   VkCommandBufferBeginInfo info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = flags };
   struct vn_command_vkBeginCommandBuffer b = { .commandBuffer = (VkCommandBuffer)cmd, .pBeginInfo = &info };
   step("vkBeginCommandBuffer (flags 0x%x)", flags);
   D->dispatch_vkBeginCommandBuffer(D, &b);
   if (b.ret != VK_SUCCESS)
      broken("vkBeginCommandBuffer");
}

static void execute_secondary(void *cmd, void *sec)
{
   VkCommandBuffer s = (VkCommandBuffer)sec;
   struct vn_command_vkCmdExecuteCommands e = { .commandBuffer = (VkCommandBuffer)cmd, .commandBufferCount = 1,
                                                .pCommandBuffers = &s };
   step("vkCmdExecuteCommands of the secondary");
   D->dispatch_vkCmdExecuteCommands(D, &e);
}

/* one submit of CMD, waited for with the driver's own wait (vkr refuses vkQueueWaitIdle) */
static VkResult submit_ret; /* the driver's vkQueueSubmit result of the last submit_one */
static int submit_one(void *cmd, const char *what)
{
   static struct vkr_queue *q; /* vkr gives a queue once */
   if (!q)
      q = device_queue();
   VkCommandBuffer cb = (VkCommandBuffer)cmd;
   VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
                           .pCommandBuffers = &cb };
   struct vn_command_vkQueueSubmit qs = { .queue = (VkQueue)q, .submitCount = 1, .pSubmits = &submit };
   step("vkQueueSubmit of %s", what);
   D->dispatch_vkQueueSubmit(D, &qs);
   step("vkQueueSubmit = %d", qs.ret);
   submit_ret = qs.ret;
   if (ended())
      return FATAL;
   q->device->proc_table.QueueWaitIdle(q->base.handle.queue);
   step("the queue is idle");
   return qs.ret == VK_SUCCESS ? WORKS : ERROR;
}

static int secondary_again_case(const char *c, struct world *w)
{
   void *cmd = w->cmd;
   const bool reusable = IS("c-state-secondary-held-resubmit-ok");
   begin_flags(cmd, reusable ? 0 : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
   void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
   void *pool = ((struct vkr_command_buffer *)sec)->pool;
   record_secondary(sec, 1);
   execute_secondary(cmd, sec);
   if (IS("c-state-secondary-held-rerecord-end")) {
      record_secondary(sec, 2);
      return end(cmd);
   }
   int r = end(cmd);
   if (r != WORKS)
      return r;
   if (reusable) {
      free_command_buffer(sec);
      step("zombies after the free: %d", zombies());
      r = submit_one(cmd, "the reusable primary (1st)");
      return r != WORKS ? r : submit_one(cmd, "the reusable primary (2nd: KosmicKrisp replays the secondary)");
   }
   if (IS("c-state-secondary-held-rerecord-submit") || IS("c-state-secondary-held-rerecord-ok")) {
      record_secondary(sec, 2);
   } else if (IS("c-state-secondary-held-reset-submit")) {
      reset_command_buffer(sec);
   } else if (IS("c-state-secondary-held-pool-reset-submit")) {
      reset_command_pool(pool);
   } else if (IS("c-state-secondary-held-free-pool-reset-submit")) {
      free_command_buffer(sec);
      step("zombies after the free: %d", zombies());
      reset_command_pool(pool);
   } else {
      return BROKEN;
   }
   if (ended())
      return FATAL;
   if (IS("c-state-secondary-held-rerecord-ok")) {
      reset_command_pool(((struct vkr_command_buffer *)cmd)->pool);
      begin_flags(cmd, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
      execute_secondary(cmd, sec);
      if ((r = end(cmd)) != WORKS)
         return r;
   }
   return submit_one(cmd, "the primary");
}

/* ---------------- a driver end that failed (virgl-venus-submit-state.patch) ----------------
 * The guest's Venus driver ends a command buffer without a reply, so it never sees the
 * driver's vkEndCommandBuffer result: vkr counts a buffer as ended from the guest's call.
 * MoltenVK's end fails (VK_ERROR_FEATURE_NOT_PRESENT) when it could not record one command,
 * e.g. vkCmdResolveImage of an integer format (Metal resolves none): it then skips such a
 * primary at the submit (MVKCommandBuffer::canExecute) and encodes such a secondary without
 * that command. KosmicKrisp records these.
 *   -failed-submit-ok, -failed-resubmit-ok: LEGAL (dEQP-VK renderpasses.*.self_dep_*_ms): a
 *     primary fills 256 bytes of host-visible memory and resolves a 4-sample R8_UINT image,
 *     is submitted (twice: reusable) and waited for. MoltenVK: its end fails and the fill
 *     never runs; KosmicKrisp: the fill runs. The first version of the patch (#706) refused
 *     this submit on MoltenVK ("was not ended") and the app hung.
 *   -failed-secondary-ok: LEGAL: the fill and the resolve in a secondary the primary
 *     executes: the fill runs on both drivers.
 *   -failed-reset-submit, -failed-rebegin-submit: an end made to fail (the hook below),
 *     then a reset (or a begin), then the submit: refused ("was not ended", "still
 *     records"), on every driver.
 *   -hook-submit, -hook-secondary: an end made to fail (VK_ERROR_OUT_OF_HOST_MEMORY) with
 *     vkr_test_end_result_hook (no legal recording fails on demand; KosmicKrisp's ends
 *     fail only out of memory): MoltenVK goes on (submit and wait); any other driver
 *     refuses the submit, or the vkCmdExecuteCommands of the secondary.
 *   -hook-reset-ok: LEGAL: an end made to fail, the buffer reset and recorded again: its
 *     submit works on every driver. */
static VkResult end_inject; /* the next end's result, once (VK_SUCCESS: the driver's) */

static VkResult end_hook(VkResult result)
{
   if (end_inject == VK_SUCCESS)
      return result;
   step("the test hook makes the driver's end result %d into %d", result, end_inject);
   result = end_inject;
   end_inject = VK_SUCCESS;
   return result;
}

/* a 64x64 R8_UINT image with SAMPLES, bound (NULL: the device cannot make it) */
static struct vkr_image *uint_image(VkSampleCountFlagBits samples, VkImageUsageFlags usage)
{
   VkImageFormatProperties ip = { 0 };
   if (pdev->proc_table.GetPhysicalDeviceImageFormatProperties(
          pdev->base.handle.physical_device, VK_FORMAT_R8_UINT, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
          usage, 0, &ip) != VK_SUCCESS ||
       !(ip.sampleCounts & samples))
      return NULL;
   const uint64_t id = next_id++;
   VkImage hd = (VkImage)(uintptr_t)id;
   VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                              .format = VK_FORMAT_R8_UINT, .extent = { 64, 64, 1 }, .mipLevels = 1,
                              .arrayLayers = 1, .samples = samples, .tiling = VK_IMAGE_TILING_OPTIMAL,
                              .usage = usage };
   struct vn_command_vkCreateImage c = { .device = DEVH, .pCreateInfo = &info, .pImage = &hd };
   D->dispatch_vkCreateImage(D, &c);
   struct vkr_image *img = object(id);
   if (c.ret != VK_SUCCESS || !img)
      broken("vkCreateImage (R8_UINT)");
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetImageMemoryRequirements r = { .device = DEVH, .image = (VkImage)img,
                                                       .pMemoryRequirements = &req };
   D->dispatch_vkGetImageMemoryRequirements(D, &r);
   struct vkr_device_memory *mem = allocate(req.size, memory_type(req.memoryTypeBits));
   struct vn_command_vkBindImageMemory b = { .device = DEVH, .image = (VkImage)img,
                                             .memory = (VkDeviceMemory)mem };
   D->dispatch_vkBindImageMemory(D, &b);
   if (b.ret != VK_SUCCESS)
      broken("vkBindImageMemory (R8_UINT)");
   return img;
}

/* 256 bytes of host-visible, coherent memory, mapped by the test through the driver and
 * set to 0, bound to a buffer */
static struct vkr_buffer *mapped_buffer(volatile uint32_t **words)
{
   const uint64_t id = next_id++;
   VkBuffer h = (VkBuffer)(uintptr_t)id;
   VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 256,
                               .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
   struct vn_command_vkCreateBuffer c = { .device = DEVH, .pCreateInfo = &info, .pBuffer = &h };
   D->dispatch_vkCreateBuffer(D, &c);
   struct vkr_buffer *buf = object(id);
   if (c.ret != VK_SUCCESS || !buf)
      broken("vkCreateBuffer");
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetBufferMemoryRequirements r = { .device = DEVH, .buffer = (VkBuffer)buf,
                                                        .pMemoryRequirements = &req };
   D->dispatch_vkGetBufferMemoryRequirements(D, &r);
   const VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
   const VkPhysicalDeviceMemoryProperties *mp = &pdev->memory_properties;
   uint32_t type = 0;
   while (type < mp->memoryTypeCount &&
          (!(req.memoryTypeBits & (1u << type)) || (mp->memoryTypes[type].propertyFlags & want) != want))
      type++;
   if (type == mp->memoryTypeCount)
      broken("no host-visible coherent memory type for a buffer");
   struct vkr_device_memory *mem = allocate(req.size, type);
   struct vn_command_vkBindBufferMemory b = { .device = DEVH, .buffer = (VkBuffer)buf,
                                              .memory = (VkDeviceMemory)mem };
   D->dispatch_vkBindBufferMemory(D, &b);
   if (b.ret != VK_SUCCESS)
      broken("vkBindBufferMemory");
   void *p = NULL;
   if (dev->proc_table.MapMemory(dev->base.handle.device, mem->base.handle.device_memory, 0, VK_WHOLE_SIZE, 0,
                                 &p) != VK_SUCCESS || !p)
      broken("vkMapMemory (the test's own)");
   memset(p, 0, 256);
   *words = p;
   return buf;
}

/* into CMD: a fill of BUF with 0x5a5a5a5a, the two images to GENERAL, the resolve 4x -> 1x */
static void record_fill_resolve(void *cmd, struct vkr_buffer *buf, struct vkr_image *ms, struct vkr_image *one)
{
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   struct vn_command_vkCmdFillBuffer f = { .commandBuffer = cb, .dstBuffer = (VkBuffer)buf, .dstOffset = 0,
                                           .size = 256, .data = 0x5a5a5a5a };
   step("vkCmdFillBuffer 256 bytes of host-visible memory");
   D->dispatch_vkCmdFillBuffer(D, &f);
   VkImageMemoryBarrier2 ib[2];
   for (int i = 0; i < 2; i++)
      ib[i] = (VkImageMemoryBarrier2){ .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                                       .srcStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                       .dstStageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
                                       .dstAccessMask = VK_ACCESS_2_TRANSFER_READ_BIT |
                                                        VK_ACCESS_2_TRANSFER_WRITE_BIT,
                                       .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED, .newLayout = VK_IMAGE_LAYOUT_GENERAL,
                                       .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                       .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                       .image = (VkImage)(i ? one : ms),
                                       .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
   VkDependencyInfo di = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .imageMemoryBarrierCount = 2,
                           .pImageMemoryBarriers = ib };
   struct vn_command_vkCmdPipelineBarrier2 p = { .commandBuffer = cb, .pDependencyInfo = &di };
   step("vkCmdPipelineBarrier2: both images to GENERAL");
   D->dispatch_vkCmdPipelineBarrier2(D, &p);
   VkImageResolve reg = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                          .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .extent = { 64, 64, 1 } };
   struct vn_command_vkCmdResolveImage rs = { .commandBuffer = cb, .srcImage = (VkImage)ms,
                                              .srcImageLayout = VK_IMAGE_LAYOUT_GENERAL, .dstImage = (VkImage)one,
                                              .dstImageLayout = VK_IMAGE_LAYOUT_GENERAL, .regionCount = 1,
                                              .pRegions = &reg };
   step("vkCmdResolveImage R8_UINT 4x -> 1x");
   D->dispatch_vkCmdResolveImage(D, &rs);
}

/* the guest's end: the driver's result is only printed (the guest never sees it) */
static VkResult end_any(void *cmd)
{
   step("vkEndCommandBuffer");
   struct vn_command_vkEndCommandBuffer e = { .commandBuffer = (VkCommandBuffer)cmd };
   D->dispatch_vkEndCommandBuffer(D, &e);
   step("vkEndCommandBuffer = %d (the driver's)", e.ret);
   return e.ret;
}

static int end_failed_case(const char *c, struct world *w)
{
   void *cmd = w->cmd;
   vkr_test_end_result_hook = end_hook;
   if (!strncmp(c, "c-state-end-hook-", 17)) {
      const bool sec_case = IS("c-state-end-hook-secondary");
      if (!IS("c-state-end-hook-reset-ok"))
         expect(!moltenvk);
      begin_flags(cmd, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
      if (sec_case) {
         void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
         if (begin_secondary(sec, NULL) != VK_SUCCESS)
            broken("secondary begin");
         color_barrier(sec);
         end_inject = VK_ERROR_OUT_OF_HOST_MEMORY;
         end_any(sec);
         execute_secondary(cmd, sec);
         if (ended())
            return FATAL;
      } else {
         color_barrier(cmd);
         end_inject = VK_ERROR_OUT_OF_HOST_MEMORY;
      }
      if (IS("c-state-end-hook-reset-ok")) {
         end_any(cmd);
         reset_command_buffer(cmd);
         begin_flags(cmd, VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
         color_barrier(cmd);
      }
      const VkResult r = end_any(cmd);
      if (ended())
         return FATAL;
      if (r != (IS("c-state-end-hook-submit") ? VK_ERROR_OUT_OF_HOST_MEMORY : VK_SUCCESS))
         return ERROR;
      return submit_one(cmd, "the primary");
   }
   if (IS("c-state-end-failed-reset-submit") || IS("c-state-end-failed-rebegin-submit")) {
      begin_flags(cmd, 0);
      color_barrier(cmd);
      end_inject = VK_ERROR_OUT_OF_HOST_MEMORY;
      end_any(cmd);
      if (IS("c-state-end-failed-reset-submit")) {
         reset_command_buffer(cmd);
      } else {
         begin_flags(cmd, 0);
         color_barrier(cmd);
      }
      return submit_one(cmd, "the primary");
   }
   /* the fill and the integer resolve */
   struct vkr_image *ms = uint_image(VK_SAMPLE_COUNT_4_BIT,
                                     VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
   struct vkr_image *one = uint_image(VK_SAMPLE_COUNT_1_BIT,
                                      VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT);
   if (!ms || !one) {
      printf("skip: no 4-sample R8_UINT color attachment\n");
      return SKIP;
   }
   volatile uint32_t *words = NULL;
   struct vkr_buffer *buf = mapped_buffer(&words);
   const bool sec_case = IS("c-state-end-failed-secondary-ok");
   const bool twice = IS("c-state-end-failed-resubmit-ok");
   VkResult r;
   begin_flags(cmd, twice ? 0 : VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT);
   if (sec_case) {
      void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
      if (begin_secondary(sec, NULL) != VK_SUCCESS)
         broken("secondary begin");
      record_fill_resolve(sec, buf, ms, one);
      const VkResult rs = end_any(sec);
      execute_secondary(cmd, sec);
      r = end_any(cmd);
      step("the secondary's end %d, the primary's %d", rs, r);
   } else {
      record_fill_resolve(cmd, buf, ms, one);
      r = end_any(cmd);
   }
   if (ended())
      return FATAL;
   /* MoltenVK skips a primary whose end failed (what it encodes runs in full otherwise),
    * still signals the submit's fence and semaphores, and returns the end's error from
    * vkQueueSubmit too (the guest's Venus driver submits without a reply as well) */
   const bool skipped = moltenvk && r != VK_SUCCESS;
   int s = submit_one(cmd, "the primary");
   if (s == ERROR && skipped && submit_ret == r)
      s = WORKS;
   if (s == WORKS && twice) {
      s = submit_one(cmd, "the primary again (reusable)");
      if (s == ERROR && skipped && submit_ret != VK_SUCCESS)
         s = WORKS;
   }
   if (s != WORKS)
      return s;
   const uint32_t got = words[0];
   step("the fill's first word: 0x%08x (%s)", got,
        skipped ? "MoltenVK skips a primary whose end failed: 0 expected" : "0x5a5a5a5a expected");
   /* vkr says so once per app */
   int lines = 0;
   for (const char *l = log_text; (l = strstr(l, "could not record a command buffer")); l++)
      lines++;
   step("'could not record a command buffer' lines: %d", lines);
   return got == (skipped ? 0u : 0x5a5a5a5au) && lines == (skipped ? 1 : 0) ? WORKS : ERROR;
}

/* ---------------- a swapchain's memory (virgl-venus-alias-memory.patch) ----------------
 * LEGAL, what guest Mesa sends for an app's image bound with VkBindImageMemorySwapchainInfoKHR:
 * image B, made from the swapchain's create info (ALIAS_BIT, VUID-VkImageSwapchainCreateInfoKHR-
 * swapchain-00995), bound to the memory M dedicated to the swapchain's image A at offset 0.
 * MoltenVK binds B without counting it in M and locks M when B is destroyed: M freed first
 * (destroying the swapchain before B breaks no VUID) was a freed-mutex lock (SIGABRT, under
 * libgmalloc SIGSEGV). So B holds M: a freed M is a zombie until B's driver destroy.
 *   x-dedicated-alias: bind B, free M (a zombie), destroy B (none left)
 *   -b-first-ok: B destroyed before M's free and A's destroy (the order before the fix)
 *   -free-a-b: free M, destroy A, then B
 *   -context-end: M freed, the context ends with A and B
 *   -held: a view of B a command buffer's rendering names; free M, destroy the view and B
 *     (B, M and the view zombies), then the command buffer's free lets go of all three
 *   -own-dedicated: B is itself the target of memory M2: B's driver destroy waits for M2's
 *     free, and M's for that destroy
 *   -bind2: two such images in one vkBindImageMemory2
 * Refused: -half (A without ALIAS_BIT, VUID 02628), -params, -params-usage, -params-flags (B
 * unlike A: the extent, a usage bit, MUTABLE_FORMAT: MoltenVK draws B from A's texture),
 * -twice (B bound again, VUID-VkBindImageMemoryInfo-image-07460), -bind2-twice (B twice in
 * one call, VUID-vkBindImageMemory2-pBindInfos-04006). */
/* a wrong count is told at the end: the case goes on, so a vkr without the hold reaches the
 * driver's destroy of B (MoltenVK's freed-mutex lock) */
static bool alias_bad;
static void alias_zombies(int want, const char *when)
{
   const int z = zombies();
   step("zombies %s: %d (want %d)", when, z, want);
   alias_bad |= z != want;
}

static int alias_end(void)
{
   return ended() ? FATAL : alias_bad ? ZOMBIES : WORKS;
}

static int case_alias(const char *c)
{
   setup(0);
   const bool held = IS("x-dedicated-alias-held");
   const VkImageUsageFlags usage = held ? CA_SA : VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
   const VkImageCreateFlags alias = VK_IMAGE_CREATE_ALIAS_BIT;
   struct vkr_image *a = image_unbound(IS("x-dedicated-alias-half") ? 0 : alias, FMT, usage);
   struct vkr_device_memory *mem = dedicated_memory(a, NULL);
   if (!mem)
      return FATAL;

   VkImageCreateFlags bflags = alias;
   VkImageUsageFlags busage = usage;
   uint32_t bsize = 64;
   if (IS("x-dedicated-alias-params"))
      bsize = 32;
   else if (IS("x-dedicated-alias-params-usage"))
      busage |= VK_IMAGE_USAGE_STORAGE_BIT;
   else if (IS("x-dedicated-alias-params-flags"))
      bflags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
   struct vkr_image *b = image_unbound_size(bflags, FMT, busage, bsize);

   if (IS("x-dedicated-alias-bind2") || IS("x-dedicated-alias-bind2-twice")) {
      const bool twice = IS("x-dedicated-alias-bind2-twice");
      struct vkr_image *b2 = twice ? b : image_unbound(alias, FMT, usage);
      VkBindImageMemoryInfo binds[2] = {
         { .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO, .image = (VkImage)b, .memory = (VkDeviceMemory)mem },
         { .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO, .image = (VkImage)b2, .memory = (VkDeviceMemory)mem },
      };
      struct vn_command_vkBindImageMemory2 bi = { .device = DEVH, .bindInfoCount = 2, .pBindInfos = binds };
      step("vkBindImageMemory2: two images to memory dedicated to another");
      D->dispatch_vkBindImageMemory2(D, &bi);
      if (ended())
         return FATAL;
      if (bi.ret != VK_SUCCESS)
         return ERROR;
      free_memory(mem);
      alias_zombies(1, "after the free");
      destroy_image(b);
      alias_zombies(1, "after the first image's destroy");
      if (b2 != b)
         destroy_image(b2);
      destroy_image(a);
      alias_zombies(0, "at the end");
      return alias_end();
   }

   /* B's own dedicated memory, never bound (legal) */
   struct vkr_device_memory *own = IS("x-dedicated-alias-own-dedicated") ? dedicated_memory(b, NULL) : NULL;
   if (ended())
      return FATAL;
   if (bind_image_at(b, mem) != VK_SUCCESS)
      return ended() ? FATAL : ERROR;
   if (IS("x-dedicated-alias-twice")) {
      bind_image_at(b, mem);
      return ended() ? FATAL : WORKS;
   }
   if (IS("x-dedicated-alias-b-first-ok")) {
      destroy_image(b);
      free_memory(mem);
      destroy_image(a);
      alias_zombies(0, "at the end");
      return alias_end();
   }
   void *v = NULL, *cmd = NULL;
   if (held) {
      v = view(b, 1);
      cmd = command_buffer();
      begin(cmd);
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                        .imageView = (VkImageView)v,
                                        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                             .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
      struct vn_command_vkCmdBeginRendering br = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderingInfo = &ri };
      step("vkCmdBeginRendering into a view of B");
      D->dispatch_vkCmdBeginRendering(D, &br);
      if (ended())
         return FATAL;
      struct vn_command_vkCmdEndRendering er = { .commandBuffer = (VkCommandBuffer)cmd };
      D->dispatch_vkCmdEndRendering(D, &er);
      const int r = end(cmd);
      if (r != WORKS)
         return r;
   }
   free_memory(mem);
   alias_zombies(1, "after the free of A's memory");
   if (IS("x-dedicated-alias-context-end")) {
      step("the context ends with A and B");
      vkr_context_destroy(ctx);
      step("the context is gone");
      return alias_bad ? ZOMBIES : WORKS;
   }
   if (IS("x-dedicated-alias-free-a-b")) {
      destroy_image(a);
      alias_zombies(1, "after A's destroy");
   }
   if (held)
      destroy_view(v);
   destroy_image(b);
   if (held) {
      alias_zombies(3, "after the view's and B's destroy");
      free_command_buffer(cmd);
   } else if (own) {
      alias_zombies(1, "after B's destroy (its memory alive)");
      free_memory(own);
   }
   alias_zombies(0, "after B's destroy");
   if (!IS("x-dedicated-alias-free-a-b"))
      destroy_image(a);
   if (IS("x-dedicated-alias") || IS("x-dedicated-alias-free-a-b") || held || own)
      return alias_end();
   return BROKEN;
}

/* ---------------- two threads on one context (virgl-venus-ring-lock.patch) ----------------
 * A real ring (vkCreateRingMESA on shared memory, its own thread) runs one guest call that
 * the test hook (virgl-venus-test-pause.patch) stops between vkr's reads and the driver's
 * call; meanwhile the context's own stream (QEMU's thread in the VM) sends another call,
 * encoded as the guest does. With one dispatch lock per context a ring's batch and the
 * stream's call never overlap, except where a pipeline call gives the lock up with its
 * objects pinned. */
#define RING_RES 900
#define NEST_RES 901
#define EXPORT_RES 902
#define RING_ID 77
#define RING_SIZE 32768u
#define PAUSE_MS 1000
#define ID(o) (((struct vkr_object *)(o))->id)

static uint8_t enc[RING_SIZE];
static size_t enc_n;

struct test_ring {
   uint64_t id;
   uint32_t res;
   uint8_t *mem;
   uint32_t tail;
   uint64_t idle_ns; /* how long it polls before it waits for a notify */
};
/* ring 1 (the compile thread's in --ring-time) is never notified: it polls for 10 s */
static struct test_ring rings[2] = { { RING_ID, RING_RES, NULL, 0, 1000000 },
                                     { RING_ID + 1, RING_RES + 10, NULL, 0, 10000000000ull } };
#define ring_mem (rings[0].mem)
#define ring_tail (rings[0].tail)

static void e_put(const void *p, size_t n)
{
   const size_t padded = (n + 3) & ~(size_t)3;
   if (enc_n + padded > sizeof(enc))
      broken("encoder full");
   memcpy(enc + enc_n, p, n);
   memset(enc + enc_n + n, 0, padded - n);
   enc_n += padded;
}
static void e_u32(uint32_t v) { e_put(&v, 4); }
static void e_i32(int32_t v) { e_put(&v, 4); }
static void e_u64(uint64_t v) { e_put(&v, 8); }
static void e_cmd(VkCommandTypeEXT type)
{
   e_i32(type);
   e_u32(0); /* no reply */
}

/* the encoded calls through the context's own stream */
static bool e_submit(void)
{
   const bool ok = vkr_context_submit_cmd(ctx, enc, enc_n);
   enc_n = 0;
   return ok;
}

static double ms_now(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void *shm_resource(uint32_t res_id, uint64_t size)
{
   struct virgl_context_blob blob;
   if (!vkr_context_create_resource(ctx, res_id, 0, size, VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE, &blob))
      broken("shared memory resource");
   close(blob.u.fd);
   return vkr_context_get_resource(ctx, res_id)->u.data;
}

/* a ring: head 0, tail 4, status 8, buffer 64 + RING_SIZE */
static void ring_start_n(struct test_ring *r)
{
   r->mem = shm_resource(r->res, 64 + RING_SIZE);
   e_cmd(VK_COMMAND_TYPE_vkCreateRingMESA_EXT);
   e_u64(r->id);
   e_u64(1);
   e_i32(VK_STRUCTURE_TYPE_RING_CREATE_INFO_MESA);
   e_u64(0);
   e_u32(0);
   e_u32(r->res);
   e_u64(0);
   e_u64(64 + RING_SIZE);
   e_u64(r->idle_ns);
   e_u64(0);
   e_u64(4);
   e_u64(8);
   e_u64(64);
   e_u64(RING_SIZE);
   e_u64(64 + RING_SIZE);
   e_u64(0);
   if (!e_submit() || ended())
      broken("vkCreateRingMESA");
   step("ring %llu runs", (unsigned long long)r->id);
}

static void ring_start(void)
{
   ring_start_n(&rings[0]);
}

/* bytes of the encoder into the ring (no notify) */
static void ring_put(struct test_ring *r, const uint8_t *bytes, size_t n)
{
   for (size_t i = 0; i < n; i++)
      r->mem[64 + ((r->tail + i) & (RING_SIZE - 1))] = bytes[i];
   r->tail += (uint32_t)n;
   atomic_store_explicit((_Atomic uint32_t *)(void *)(r->mem + 4), r->tail, memory_order_release);
}

/* the ring's head (how far it read) */
static uint32_t ring_head(const struct test_ring *r)
{
   return atomic_load_explicit((_Atomic uint32_t *)(void *)r->mem, memory_order_acquire);
}

/* what is encoded goes into the ring, its tail moves and the ring is woken through the
 * context's stream; returns the ring position after it */
static uint32_t ring_write_n(struct test_ring *r)
{
   ring_put(r, enc, enc_n);
   enc_n = 0;
   e_cmd(VK_COMMAND_TYPE_vkNotifyRingMESA_EXT);
   e_u64(r->id);
   e_u32(r->tail);
   e_u32(0);
   e_submit();
   return r->tail;
}

static uint32_t ring_write(void)
{
   return ring_write_n(&rings[0]);
}

/* the ring read everything written, or stopped (its fatal bit) */
static bool ring_done_n(const struct test_ring *r, int ms)
{
   for (int i = 0; i < ms * 10; i++) {
      const uint32_t status =
         atomic_load_explicit((_Atomic uint32_t *)(void *)(r->mem + 8), memory_order_acquire);
      if (ring_head(r) == r->tail || (status & VK_RING_STATUS_FATAL_BIT_MESA))
         return true;
      usleep(100);
   }
   return false;
}

static bool ring_done(int ms)
{
   return ring_done_n(&rings[0], ms);
}

/* the test hook: the first thread to reach pause_at stops there until resumed, at most
 * PAUSE_MS */
static const char *pause_at;
static atomic_int paused, resumed;

static void pause_hook(const char *where)
{
   if (!pause_at || strcmp(where, pause_at) || atomic_exchange(&paused, 1))
      return;
   printf("step: paused at \"%s\"\n", where);
   for (int i = 0; i < PAUSE_MS && !atomic_load(&resumed); i++)
      usleep(1000);
   printf("step: going on from \"%s\"\n", where);
}

static bool wait_paused(void)
{
   for (int i = 0; i < 5000 && !atomic_load(&paused); i++)
      usleep(1000);
   return atomic_load(&paused);
}

static void e_destroy(VkCommandTypeEXT type, uint64_t object_id)
{
   e_cmd(type);
   e_u64(dev->base.id);
   e_u64(object_id);
   e_u64(0);
}

static void e_compute_pipeline(uint64_t cache_id, uint64_t layout_id, uint64_t module_id, uint64_t pipe_id)
{
   e_cmd(VK_COMMAND_TYPE_vkCreateComputePipelines_EXT);
   e_u64(dev->base.id);
   e_u64(cache_id);
   e_u32(1);
   e_u64(1);
   e_i32(VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO);
   e_u64(0);
   e_u32(0);
   e_i32(VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO);
   e_u64(0);
   e_u32(0);
   e_u32(VK_SHADER_STAGE_COMPUTE_BIT);
   e_u64(module_id);
   e_u64(5);
   e_put("main", 5);
   e_u64(0);
   e_u64(layout_id);
   e_u64(0);
   e_i32(-1);
   e_u64(0);
   e_u64(1);
   e_u64(pipe_id);
}

static void e_create_buffer(uint64_t id)
{
   e_cmd(VK_COMMAND_TYPE_vkCreateBuffer_EXT);
   e_u64(dev->base.id);
   e_u64(1);
   e_i32(VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
   e_u64(0);
   e_u32(0);
   e_u64(256);
   e_u32(VK_BUFFER_USAGE_TRANSFER_DST_BIT);
   e_i32(VK_SHARING_MODE_EXCLUSIVE);
   e_u32(0);
   e_u64(0);
   e_u64(0);
   e_u64(1);
   e_u64(id);
}

static void e_fill(void *cmd, struct vkr_buffer *buf)
{
   e_cmd(VK_COMMAND_TYPE_vkCmdFillBuffer_EXT);
   e_u64(ID(cmd));
   e_u64(ID(buf));
   e_u64(0);
   e_u64(256);
   e_u32(7);
}

static void *pipeline_cache(void)
{
   const uint64_t id = next_id++;
   VkPipelineCache h = (VkPipelineCache)(uintptr_t)id;
   VkPipelineCacheCreateInfo info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO };
   struct vn_command_vkCreatePipelineCache c = { .device = DEVH, .pCreateInfo = &info, .pPipelineCache = &h };
   D->dispatch_vkCreatePipelineCache(D, &c);
   if (c.ret != VK_SUCCESS || !object(id))
      broken("vkCreatePipelineCache");
   return object(id);
}

/* host-visible memory (a blob QEMU may export) */
static struct vkr_device_memory *visible_memory(void)
{
   const VkPhysicalDeviceMemoryProperties *mp = &pdev->memory_properties;
   for (uint32_t i = 0; i < mp->memoryTypeCount; i++)
      if (mp->memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
         return allocate(65536, i);
   broken("no host-visible memory type");
   return NULL;
}

static struct vkr_device_memory *export_mem;
static bool export_ok;

static void *export_thread(void *arg)
{
   (void)arg;
   struct virgl_context_blob blob;
   step("QEMU's thread: a blob of memory %llu", (unsigned long long)ID(export_mem));
   export_ok = vkr_context_create_resource(ctx, EXPORT_RES, ID(export_mem), 65536,
                                           VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE, &blob);
   step("QEMU's thread: blob %s", export_ok ? "made" : "not made");
   return NULL;
}

static void *watchdog(void *arg)
{
   const int ms = (int)(intptr_t)arg;
   usleep(ms * 1000);
   printf("step: still waiting after %d ms: a deadlock\n", ms);
   fflush(stdout);
   _exit(BROKEN);
}

/* t- cases: a ring stopped inside one call while the context's stream sends another.
 *   -pipeline-destroy-layout, -pipeline-destroy-module, -cache-data-destroy: a pipeline call
 *     (vkCreateComputePipelines, vkGetPipelineCacheData) runs in the driver without the
 *     lock; the stream destroys an object it names: refused (an app must not destroy what
 *     another thread's call uses; spec "Threading Behavior", object lifetime). Before the
 *     fix vkr and the driver read the destroyed object.
 *   -same-id: the stream makes a buffer with the id the paused create named for its
 *     pipeline: refused when the create adds it (the guest named one id twice), the new
 *     pipeline destroyed. Before: vkr_context_add_object's assert.
 *   -command-free-buffer, -same-command-buffer, -export-free-memory: the ring (or QEMU's
 *     blob export) is stopped inside a call that holds the lock (vkCmdFillBuffer; the
 *     export); the stream's vkDestroyBuffer, vkCmdFillBuffer on the same command buffer,
 *     vkFreeMemory must wait for it (>= PAUSE_MS / 2). LEGAL apart from -command-free-buffer
 *     and -same-command-buffer (invalid usage that must not crash). Before: no wait.
 *   -wait-ring-nested-ok: the ring waits in vkWaitVirtqueueSeqnoMESA, then makes and
 *     destroys 100 buffers; the stream, inside vkExecuteCommandStreamsMESA (which takes the
 *     lock), submits that seqno and waits in vkWaitRingSeqnoMESA for the ring's end: both
 *     waits give the lock up, else a deadlock (stopped after 5 s).
 *   -compile-no-delay-ok: with a pipeline create paused, the stream's unrelated
 *     vkDestroyBuffer takes < 1 ms (median of 3).
 *   -teardown-paused-ok: the context ends while the ring is paused in a create: within 15 s. */
static int case_threads(const char *c)
{
   setup(0);
   struct world w;
   make_world(&w, true);
   vkr_test_pause_hook = pause_hook;
   ring_start();
   if (IS("t-pipeline-destroy-layout") || IS("t-pipeline-destroy-module") || IS("t-same-id") ||
       IS("t-compile-no-delay-ok") || IS("t-teardown-paused-ok")) {
      const uint64_t pipe = next_id++;
      pause_at = "pipeline";
      e_compute_pipeline(0, ID(w.layout), ID(w.comp), pipe);
      ring_write();
      if (!wait_paused())
         broken("the ring did not reach vkCreateComputePipelines's pause");
      if (IS("t-teardown-paused-ok")) {
         const double t0 = ms_now();
         pthread_t wd;
         pthread_create(&wd, NULL, watchdog, (void *)(intptr_t)30000);
         step("the context ends while the ring is paused");
         vkr_context_destroy(ctx);
         const double dt = ms_now() - t0;
         step("the context is gone after %.1f ms", dt);
         /* the pause (<= PAUSE_MS plus sleep overshoot) and a device's teardown; a build Mac
          * under load took 4.4 s (M1 Max, background QoS): a deadlock never ends */
         return dt < 15000 ? WORKS : ERROR;
      }
      if (IS("t-compile-no-delay-ok")) {
         double took[3];
         for (int i = 0; i < 3; i++) {
            struct vkr_buffer *b = buffer(256);
            const uint64_t id = ID(b);
            e_destroy(VK_COMMAND_TYPE_vkDestroyBuffer_EXT, id);
            const double t0 = ms_now();
            e_submit();
            took[i] = ms_now() - t0;
            if (object(id))
               broken("the stream's vkDestroyBuffer did not destroy the buffer");
         }
         const double a = took[0], b = took[1], m = took[2];
         const double median = a > b ? (b > m ? b : (a > m ? m : a)) : (a > m ? a : (b > m ? m : b));
         step("vkDestroyBuffer beside the paused create: %.3f, %.3f, %.3f ms (median %.3f)", took[0], took[1],
              took[2], median);
         atomic_store(&resumed, 1);
         if (!ring_done(10000))
            broken("the ring did not finish");
         return ended() ? FATAL : median < 1.0 ? WORKS : ERROR;
      }
      if (IS("t-same-id")) {
         step("the stream makes a buffer with the pipeline's id %llu", (unsigned long long)pipe);
         e_create_buffer(pipe);
      } else {
         const bool layout = IS("t-pipeline-destroy-layout");
         step("the stream destroys the create's %s", layout ? "pipeline layout" : "shader module");
         e_destroy(layout ? VK_COMMAND_TYPE_vkDestroyPipelineLayout_EXT : VK_COMMAND_TYPE_vkDestroyShaderModule_EXT,
                   layout ? ID(w.layout) : ID(w.comp));
      }
      e_submit();
      atomic_store(&resumed, 1);
      if (!ring_done(10000))
         broken("the ring did not finish");
      step("the ring is done: the pipeline %s", object(pipe) && ((struct vkr_object *)object(pipe))->type ==
                                                                    VK_OBJECT_TYPE_PIPELINE ? "was added" : "is not there");
      return ended() ? FATAL : WORKS;
   }
   if (IS("t-cache-data-destroy")) {
      void *cache = pipeline_cache();
      pause_at = "cache-data";
      e_cmd(VK_COMMAND_TYPE_vkGetPipelineCacheData_EXT);
      e_u64(dev->base.id);
      e_u64(ID(cache));
      e_u64(1);
      e_u64(0);
      e_u64(0);
      ring_write();
      if (!wait_paused())
         broken("the ring did not reach vkGetPipelineCacheData's pause");
      step("the stream destroys the cache");
      e_destroy(VK_COMMAND_TYPE_vkDestroyPipelineCache_EXT, ID(cache));
      e_submit();
      atomic_store(&resumed, 1);
      if (!ring_done(10000))
         broken("the ring did not finish");
      return ended() ? FATAL : WORKS;
   }
   if (IS("t-command-free-buffer") || IS("t-same-command-buffer") || IS("t-export-free-memory")) {
      pthread_t qemu;
      if (IS("t-export-free-memory")) {
         export_mem = visible_memory();
         pause_at = "export";
         pthread_create(&qemu, NULL, export_thread, NULL);
      } else {
         begin(w.cmd);
         pause_at = "command";
         e_fill(w.cmd, w.buf);
         ring_write();
      }
      if (!wait_paused())
         broken("no pause reached");
      if (IS("t-command-free-buffer"))
         e_destroy(VK_COMMAND_TYPE_vkDestroyBuffer_EXT, ID(w.buf));
      else if (IS("t-same-command-buffer"))
         e_fill(w.cmd, w.buf2);
      else
         e_destroy(VK_COMMAND_TYPE_vkFreeMemory_EXT, ID(export_mem));
      const double t0 = ms_now();
      e_submit();
      const double dt = ms_now() - t0;
      step("the stream's call took %.1f ms beside the paused call", dt);
      if (IS("t-export-free-memory"))
         pthread_join(qemu, NULL);
      else if (!ring_done(10000))
         broken("the ring did not finish");
      if (ended())
         return FATAL;
      return dt >= PAUSE_MS / 2 ? WORKS : ERROR;
   }
   if (IS("t-wait-ring-nested-ok")) {
      /* the ring waits for the stream's virtqueue seqno 6 (giving the lock up), then makes
       * and destroys 100 buffers (needing it again); the stream, holding the lock in
       * vkExecuteCommandStreamsMESA, submits seqno 6 and waits for the ring's end */
      e_cmd(VK_COMMAND_TYPE_vkWaitVirtqueueSeqnoMESA_EXT);
      e_u64(6);
      for (int i = 0; i < 100; i++) {
         const uint64_t id = next_id++;
         e_create_buffer(id);
         e_destroy(VK_COMMAND_TYPE_vkDestroyBuffer_EXT, id);
      }
      const uint32_t seqno = ring_write();
      usleep(100000);
      const uint32_t head = atomic_load_explicit((_Atomic uint32_t *)(void *)ring_mem, memory_order_acquire);
      step("the ring waits for virtqueue seqno 6 at %u of %u", head, seqno);
      if (head == seqno)
         broken("the ring did not wait for the virtqueue seqno");
      uint8_t *nest = shm_resource(NEST_RES, 4096);
      e_cmd(VK_COMMAND_TYPE_vkSubmitVirtqueueSeqnoMESA_EXT);
      e_u64(RING_ID);
      e_u64(6);
      e_cmd(VK_COMMAND_TYPE_vkWaitRingSeqnoMESA_EXT);
      e_u64(RING_ID);
      e_u64(seqno);
      memcpy(nest, enc, enc_n);
      const size_t n = enc_n;
      enc_n = 0;
      e_cmd(VK_COMMAND_TYPE_vkExecuteCommandStreamsMESA_EXT);
      e_u32(1);
      e_u64(1);
      e_u32(NEST_RES);
      e_u64(0);
      e_u64(n);
      e_u64(0);
      e_u32(0);
      e_u64(0);
      e_u32(0);
      pthread_t wd;
      pthread_create(&wd, NULL, watchdog, (void *)(intptr_t)5000);
      const double t0 = ms_now();
      step("vkExecuteCommandStreamsMESA { vkSubmitVirtqueueSeqnoMESA(6), vkWaitRingSeqnoMESA(%u) }", seqno);
      const bool ok = e_submit();
      const uint32_t after = atomic_load_explicit((_Atomic uint32_t *)(void *)ring_mem, memory_order_acquire);
      step("the wait returned after %.1f ms (%s), the ring at %u of %u", ms_now() - t0, ok ? "ok" : "failed",
           after, seqno);
      return ended() ? FATAL : ok && after == seqno ? WORKS : ERROR;
   }
   return BROKEN;
}

/* --ring-time N: guest calls through a real ring and the context's stream, the way the VM
 * sends them, so the dispatch lock (virgl-venus-ring-lock.patch) and the holds are in what
 * is timed: N vkCmdDraw through ring 0 (in batches of 512, as one command buffer records),
 * then the same with ring 1 making and destroying compute pipelines all the time (a compile
 * thread beside the main ring), and N vkGetBufferMemoryRequirements with a reply through the
 * context's stream. Prints microseconds per call. Nothing is submitted. */
static atomic_int compile_stop;
static atomic_int compiled;
static struct world *timed_world;

static void *compile_ring(void *arg)
{
   (void)arg;
   static uint8_t local[RING_SIZE];
   struct test_ring *r = &rings[1];
   while (!atomic_load(&compile_stop)) {
      /* the encoder is the main thread's: this thread encodes by hand into its own buffer */
      size_t n = 0;
#define L32(v) do { const uint32_t _v = (v); memcpy(local + n, &_v, 4); n += 4; } while (0)
#define L64(v) do { const uint64_t _v = (v); memcpy(local + n, &_v, 8); n += 8; } while (0)
      const uint64_t pipe = 1000000 + (uint64_t)atomic_fetch_add(&compiled, 1);
      L32(VK_COMMAND_TYPE_vkCreateComputePipelines_EXT); L32(0);
      L64(dev->base.id); L64(0); L32(1); L64(1);
      L32(VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO); L64(0); L32(0);
      L32(VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO); L64(0); L32(0);
      L32(VK_SHADER_STAGE_COMPUTE_BIT); L64(ID(timed_world->comp));
      L64(5); memcpy(local + n, "main\0\0\0\0", 8); n += 8;
      L64(0); L64(ID(timed_world->layout)); L64(0); L32((uint32_t)-1); L64(0); L64(1); L64(pipe);
      L32(VK_COMMAND_TYPE_vkDestroyPipeline_EXT); L32(0); L64(dev->base.id); L64(pipe); L64(0);
#undef L32
#undef L64
      ring_put(r, local, n);
      /* the ring polls its tail while busy; wake it in case it went idle */
      while (ring_head(r) != r->tail && !atomic_load(&compile_stop))
         usleep(50);
   }
   return NULL;
}

static double draws_through_ring(void *cmd, int n)
{
   const double t0 = ms_now();
   for (int done = 0; done < n;) {
      const int batch = n - done < 512 ? n - done : 512;
      for (int i = 0; i < batch; i++) {
         e_cmd(VK_COMMAND_TYPE_vkCmdDraw_EXT);
         e_u64(ID(cmd));
         e_u32(3);
         e_u32(1);
         e_u32(0);
         e_u32(0);
      }
      ring_write();
      if (!ring_done(10000))
         broken("the ring did not finish its draws");
      done += batch;
   }
   return (ms_now() - t0) * 1000.0 / n;
}

static int ring_time(int n)
{
   setup(0);
   struct world w = { 0 };
   make_world(&w, true);
   timed_world = &w;
   ring_start();
   ring_start_n(&rings[1]);
   begin(w.cmd);
   begin_pass(w.cmd, w.rp, w.fb, 64, 64);
   bind_pipeline(w.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w.gfx_pipe);
   ready(w.cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
   const double alone = draws_through_ring(w.cmd, n);
   pthread_t t;
   pthread_create(&t, NULL, compile_ring, NULL);
   while (atomic_load(&compiled) < 2)
      usleep(100);
   const int before = atomic_load(&compiled);
   const double beside = draws_through_ring(w.cmd, n);
   const int made = atomic_load(&compiled) - before;
   atomic_store(&compile_stop, 1);
   pthread_join(t, NULL);
   ring_done_n(&rings[1], 10000);
   /* a call with a reply through the context's stream */
   uint8_t *reply_mem = shm_resource(EXPORT_RES + 1, 4096);
   (void)reply_mem;
   e_cmd(VK_COMMAND_TYPE_vkSetReplyCommandStreamMESA_EXT);
   e_u64(1);
   e_u32(EXPORT_RES + 1);
   e_u64(0);
   e_u64(4096);
   e_submit();
   const double t0 = ms_now();
   for (int i = 0; i < n; i++) {
      e_cmd(VK_COMMAND_TYPE_vkSeekReplyCommandStreamMESA_EXT);
      e_u64(0);
      e_i32(VK_COMMAND_TYPE_vkGetBufferMemoryRequirements_EXT);
      e_u32(VK_COMMAND_GENERATE_REPLY_BIT_EXT);
      e_u64(dev->base.id);
      e_u64(ID(w.buf));
      e_u64(1);
      e_submit();
   }
   const double reply_us = (ms_now() - t0) * 1000.0 / n;
   if (ended()) {
      printf("timing: the context ended while timing\n");
      return 1;
   }
   printf("ring-time: %d each, us per call: vkCmdDraw through a ring %.3f, the same beside a compile ring "
          "%.3f (%d pipelines made meanwhile), vkGetBufferMemoryRequirements with a reply through the "
          "context's stream %.3f\n", n, alone, beside, made, reply_us);
   fflush(stdout);
   _exit(0);
}

/* ---------------- the cases and what each must see ---------------- */
/* ---------------- a structure type twice in a chain ----------------
 * VUID-<struct>-sType-unique; each struct alone is legal. vkr's checks read the first of a
 * type, the drivers the last (virgl-venus-chain-repeats.patch). r-repeat-multiview: Mesa's
 * vk_common_CreateRenderPass (KosmicKrisp) keeps the second struct, 9 views, and Metal ended
 * the process at the pass's begin; r-repeat-multiview-short: Mesa reads the second struct's
 * masks for both subpasses, past its one-mask array (guarded memory); r-repeat-attachment-
 * begin: MoltenVK's begin keeps the second attachment info, which has no views, and reads
 * the pass's one attachment from it. The -two-types-ok cases have the same structs once
 * (beside a second type where the chain takes one). */
static void *one_subpass_pass(const void *next)
{
   VkAttachmentDescription att = { 0, FMT, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR,
                                   VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                   VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED,
                                   VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
   VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
   VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1,
                                .pColorAttachments = &ref };
   const uint64_t id = next_id++;
   VkRenderPass h = (VkRenderPass)(uintptr_t)id;
   VkRenderPassCreateInfo info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .pNext = next,
                                   .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
   struct vn_command_vkCreateRenderPass cr = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
   step("vkCreateRenderPass 1 subpass, a chain");
   D->dispatch_vkCreateRenderPass(D, &cr);
   last_ret = cr.ret;
   step("vkCreateRenderPass = %d", cr.ret);
   return cr.ret == VK_SUCCESS ? object(id) : NULL;
}

/* a pass of one attachment on view v, begun with next on the begin info, ended */
static int pass_on(void *rp, void *v, const void *begin_next, bool imageless)
{
   void *views[1] = { v };
   void *fb = imageless ? imageless_framebuffer(rp) : framebuffer(rp, views, 1, 64, 64, 1);
   if (!fb)
      return imageless ? SKIP : created(fb);
   void *cmd = command_buffer();
   begin(cmd);
   VkClearValue clear = { 0 };
   VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .pNext = begin_next,
                                .renderPass = (VkRenderPass)rp, .framebuffer = (VkFramebuffer)fb,
                                .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1, .pClearValues = &clear };
   struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderPassBegin = &bi,
                                                .contents = VK_SUBPASS_CONTENTS_INLINE };
   step("vkCmdBeginRenderPass, a chain on the begin info");
   D->dispatch_vkCmdBeginRenderPass(D, &b);
   end_pass(cmd);
   return end(cmd);
}

static int case_repeat(const char *c)
{
   unsigned needs = 0;
   if (IS("p-repeat-inline-spirv") || IS("d-repeat-buffer-view"))
      needs |= N_MAINT5;
   if (IS("p-repeat-gfx-ms"))
      needs |= N_SAMPLELOC;
   setup(needs);
   struct world w = { 0 };
   make_world(&w, c[0] == 'p');

   if (IS("r-repeat-multiview") || IS("r-repeat-two-types-ok")) {
      if (9 > lim.maxImageArrayLayers || 9 > lim.maxFramebufferLayers) {
         printf("skip: 9 layers\n");
         return SKIP;
      }
      static const uint32_t one = 0x1, nine = 0x1ff;
      VkRenderPassMultiviewCreateInfo mv2 = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                                              .subpassCount = 1, .pViewMasks = &nine };
      VkRenderPassInputAttachmentAspectCreateInfo ia = {
         .sType = VK_STRUCTURE_TYPE_RENDER_PASS_INPUT_ATTACHMENT_ASPECT_CREATE_INFO };
      VkRenderPassMultiviewCreateInfo mv1 = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                                              .pNext = IS("r-repeat-multiview") ? (const void *)&mv2 : &ia,
                                              .subpassCount = 1, .pViewMasks = &one };
      void *rp = one_subpass_pass(&mv1);
      if (!rp)
         return created(rp);
      return pass_on(rp, view(image(64, 64, 9, CA_SA), 9), NULL, false);
   }
   if (IS("r-repeat-multiview-short")) {
      static const uint32_t masks[2] = { 1, 1 };
      uint32_t *short_masks = guarded(sizeof(uint32_t));
      short_masks[0] = 1;
      VkRenderPassMultiviewCreateInfo mv2 = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                                              .subpassCount = 1, .pViewMasks = short_masks };
      VkRenderPassMultiviewCreateInfo mv1 = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_MULTIVIEW_CREATE_INFO,
                                              .pNext = &mv2, .subpassCount = 2, .pViewMasks = masks };
      return created(two_subpass_pass(&mv1, 0));
   }
   if (IS("r-repeat-attachment-begin")) {
      VkImageView one = (VkImageView)w.iv;
      VkRenderPassAttachmentBeginInfo ab2 = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_ATTACHMENT_BEGIN_INFO };
      VkRenderPassAttachmentBeginInfo ab1 = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_ATTACHMENT_BEGIN_INFO,
                                              .pNext = &ab2, .attachmentCount = 1, .pAttachments = &one };
      return pass_on(w.rp, NULL, &ab1, true);
   }
   if (IS("r-repeat-begin") || IS("r-repeat-begin-two-types-ok")) {
      /* device group begin infos (core 1.1), device mask 1, no areas */
      VkDeviceGroupRenderPassBeginInfo g2 = { .sType = VK_STRUCTURE_TYPE_DEVICE_GROUP_RENDER_PASS_BEGIN_INFO,
                                              .deviceMask = 1 };
      VkImageView one = (VkImageView)w.iv;
      VkRenderPassAttachmentBeginInfo ab = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_ATTACHMENT_BEGIN_INFO,
                                             .attachmentCount = 1, .pAttachments = &one };
      VkDeviceGroupRenderPassBeginInfo g1 = { .sType = VK_STRUCTURE_TYPE_DEVICE_GROUP_RENDER_PASS_BEGIN_INFO,
                                              .pNext = IS("r-repeat-begin") ? (const void *)&g2 : &ab,
                                              .deviceMask = 1 };
      return pass_on(w.rp, w.iv, &g1, IS("r-repeat-begin-two-types-ok"));
   }
   if (IS("r-repeat-pass2-subpass")) {
      /* depth/stencil resolve infos with no resolve (core 1.2) */
      VkSubpassDescriptionDepthStencilResolve r2 = {
         .sType = VK_STRUCTURE_TYPE_SUBPASS_DESCRIPTION_DEPTH_STENCIL_RESOLVE };
      VkSubpassDescriptionDepthStencilResolve r1 = r2;
      r1.pNext = &r2;
      VkAttachmentDescription2 att = { .sType = VK_STRUCTURE_TYPE_ATTACHMENT_DESCRIPTION_2, .format = FMT,
                                       .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                                       .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                                       .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                       .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
                                       .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
      VkAttachmentReference2 ref = { .sType = VK_STRUCTURE_TYPE_ATTACHMENT_REFERENCE_2, .attachment = 0,
                                     .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                     .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT };
      VkSubpassDescription2 sub = { .sType = VK_STRUCTURE_TYPE_SUBPASS_DESCRIPTION_2, .pNext = &r1,
                                    .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                    .colorAttachmentCount = 1, .pColorAttachments = &ref };
      const uint64_t id = next_id++;
      VkRenderPass h = (VkRenderPass)(uintptr_t)id;
      VkRenderPassCreateInfo2 info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO_2, .attachmentCount = 1,
                                       .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
      struct vn_command_vkCreateRenderPass2 cr = { .device = DEVH, .pCreateInfo = &info, .pRenderPass = &h };
      step("vkCreateRenderPass2, two depth/stencil resolve infos on the subpass");
      D->dispatch_vkCreateRenderPass2(D, &cr);
      last_ret = cr.ret;
      return created(cr.ret == VK_SUCCESS ? object(id) : NULL);
   }
   if (IS("r-repeat-framebuffer")) {
      const VkFormat fmt = FMT;
      VkFramebufferAttachmentImageInfo ai = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_ATTACHMENT_IMAGE_INFO,
                                              .usage = CA_SA, .width = 64, .height = 64, .layerCount = 1,
                                              .viewFormatCount = 1, .pViewFormats = &fmt };
      VkFramebufferAttachmentsCreateInfo ac2 = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_ATTACHMENTS_CREATE_INFO,
                                                 .attachmentImageInfoCount = 1, .pAttachmentImageInfos = &ai };
      VkFramebufferAttachmentsCreateInfo ac1 = ac2;
      ac1.pNext = &ac2;
      const uint64_t id = next_id++;
      VkFramebuffer fh = (VkFramebuffer)(uintptr_t)id;
      VkFramebufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .pNext = &ac1,
                                       .flags = VK_FRAMEBUFFER_CREATE_IMAGELESS_BIT, .renderPass = (VkRenderPass)w.rp,
                                       .attachmentCount = 1, .width = 64, .height = 64, .layers = 1 };
      struct vn_command_vkCreateFramebuffer cf = { .device = DEVH, .pCreateInfo = &info, .pFramebuffer = &fh };
      step("vkCreateFramebuffer (imageless), two attachment infos");
      D->dispatch_vkCreateFramebuffer(D, &cf);
      last_ret = cf.ret;
      return created(cf.ret == VK_SUCCESS ? object(id) : NULL);
   }
   if (IS("r-repeat-rendering")) {
      VkDeviceGroupRenderPassBeginInfo g2 = { .sType = VK_STRUCTURE_TYPE_DEVICE_GROUP_RENDER_PASS_BEGIN_INFO,
                                              .deviceMask = 1 };
      VkDeviceGroupRenderPassBeginInfo g1 = g2;
      g1.pNext = &g2;
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                        .imageView = (VkImageView)w.iv,
                                        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .pNext = &g1,
                             .renderArea = { { 0, 0 }, { 64, 64 } }, .layerCount = 1, .colorAttachmentCount = 1,
                             .pColorAttachments = &att };
      begin(w.cmd);
      struct vn_command_vkCmdBeginRendering b = { .commandBuffer = (VkCommandBuffer)w.cmd, .pRenderingInfo = &ri };
      step("vkCmdBeginRendering, two device group infos");
      D->dispatch_vkCmdBeginRendering(D, &b);
      if (!ended()) {
         struct vn_command_vkCmdEndRendering e = { .commandBuffer = (VkCommandBuffer)w.cmd };
         D->dispatch_vkCmdEndRendering(D, &e);
      }
      return end(w.cmd);
   }
   if (IS("c-repeat-inheritance")) {
      VkFormat formats[1] = { FMT };
      VkCommandBufferInheritanceRenderingInfo r2 = {
         .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_RENDERING_INFO, .colorAttachmentCount = 1,
         .pColorAttachmentFormats = formats, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
      VkCommandBufferInheritanceRenderingInfo r1 = r2;
      r1.pNext = &r2;
      void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
      begin_secondary(sec, &r1);
      return end(sec);
   }
   if (IS("d-repeat-layout") || IS("d-repeat-two-types-ok")) {
      const VkDescriptorSetLayoutBinding b = { 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL };
      const VkDescriptorBindingFlags none = 0;
      VkDescriptorSetLayoutBindingFlagsCreateInfo f2 = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO, .bindingCount = 1,
         .pBindingFlags = &none };
      VkDescriptorSetLayoutBindingFlagsCreateInfo f1 = f2;
      f1.pNext = &f2;
      if (IS("d-repeat-layout"))
         return created(set_layout_of(&b, 1, 0, &f1));
      /* the control: binding flags on the layout, a variable count info on the allocation */
      void *dsl = set_layout_of(&b, 1, 0, &f2);
      if (!dsl)
         return created(dsl);
      VkDescriptorSetVariableDescriptorCountAllocateInfo v = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO };
      return created(set_from(w.pool, dsl, &v));
   }
   if (IS("d-repeat-alloc")) {
      VkDescriptorSetVariableDescriptorCountAllocateInfo v2 = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO };
      VkDescriptorSetVariableDescriptorCountAllocateInfo v1 = v2;
      v1.pNext = &v2;
      return created(set_from(w.pool, w.dsl, &v1));
   }
   if (IS("d-repeat-pool")) {
      VkDescriptorPoolSize size = { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 4 };
      VkDescriptorPoolInlineUniformBlockCreateInfo i2 = {
         .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_INLINE_UNIFORM_BLOCK_CREATE_INFO };
      VkDescriptorPoolInlineUniformBlockCreateInfo i1 = i2;
      i1.pNext = &i2;
      const uint64_t id = next_id++;
      VkDescriptorPool h = (VkDescriptorPool)(uintptr_t)id;
      VkDescriptorPoolCreateInfo info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .pNext = &i1,
                                          .maxSets = 4, .poolSizeCount = 1, .pPoolSizes = &size };
      struct vn_command_vkCreateDescriptorPool cp = { .device = DEVH, .pCreateInfo = &info, .pDescriptorPool = &h };
      step("vkCreateDescriptorPool, two inline block infos");
      D->dispatch_vkCreateDescriptorPool(D, &cp);
      last_ret = cp.ret;
      return created(cp.ret == VK_SUCCESS ? object(id) : NULL);
   }
   if (IS("d-repeat-write")) {
      if (!max_inline_block) {
         printf("skip: no inline uniform blocks\n");
         return SKIP;
      }
      uint8_t data[16] = { 1 };
      VkWriteDescriptorSetInlineUniformBlock i2 = {
         .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_INLINE_UNIFORM_BLOCK, .dataSize = 16, .pData = data };
      VkWriteDescriptorSetInlineUniformBlock i1 = i2;
      i1.pNext = &i2;
      VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = &i1,
                                  .dstSet = (VkDescriptorSet)w.set, .dstBinding = 5, .descriptorCount = 16,
                                  .descriptorType = VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK };
      struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = 1,
                                                     .pDescriptorWrites = &wr };
      step("vkUpdateDescriptorSets, two inline block data infos");
      D->dispatch_vkUpdateDescriptorSets(D, &u);
      return ended() ? FATAL : WORKS;
   }
   if (IS("d-repeat-buffer")) {
      VkExternalMemoryBufferCreateInfo e2 = { .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO };
      VkExternalMemoryBufferCreateInfo e1 = e2;
      e1.pNext = &e2;
      const uint64_t id = next_id++;
      VkBuffer h = (VkBuffer)(uintptr_t)id;
      VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .pNext = &e1, .size = 4096,
                                  .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT };
      struct vn_command_vkCreateBuffer cb = { .device = DEVH, .pCreateInfo = &info, .pBuffer = &h };
      step("vkCreateBuffer, two external memory infos");
      D->dispatch_vkCreateBuffer(D, &cb);
      last_ret = cb.ret;
      return created(cb.ret == VK_SUCCESS ? object(id) : NULL);
   }
   if (IS("d-repeat-buffer-view")) {
      /* a texel buffer and a view of it with usage flags 2 twice (maintenance5) */
      const uint64_t bid = next_id++;
      VkBuffer bh = (VkBuffer)(uintptr_t)bid;
      VkBufferCreateInfo binfo = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 65536,
                                   .usage = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT };
      struct vn_command_vkCreateBuffer cb = { .device = DEVH, .pCreateInfo = &binfo, .pBuffer = &bh };
      D->dispatch_vkCreateBuffer(D, &cb);
      struct vkr_buffer *buf = object(bid);
      if (cb.ret != VK_SUCCESS || !buf)
         broken("texel buffer");
      VkMemoryRequirements req = { 0 };
      struct vn_command_vkGetBufferMemoryRequirements r = { .device = DEVH, .buffer = (VkBuffer)buf,
                                                           .pMemoryRequirements = &req };
      D->dispatch_vkGetBufferMemoryRequirements(D, &r);
      struct vn_command_vkBindBufferMemory bm = { .device = DEVH, .buffer = (VkBuffer)buf,
                                                  .memory = (VkDeviceMemory)allocate(req.size, memory_type(req.memoryTypeBits)) };
      D->dispatch_vkBindBufferMemory(D, &bm);
      if (bm.ret != VK_SUCCESS)
         broken("texel buffer memory");
      VkBufferUsageFlags2CreateInfo u2 = { .sType = VK_STRUCTURE_TYPE_BUFFER_USAGE_FLAGS_2_CREATE_INFO,
                                           .usage = VK_BUFFER_USAGE_2_UNIFORM_TEXEL_BUFFER_BIT };
      VkBufferUsageFlags2CreateInfo u1 = u2;
      u1.pNext = &u2;
      const uint64_t id = next_id++;
      VkBufferView h = (VkBufferView)(uintptr_t)id;
      VkBufferViewCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .pNext = &u1,
                                      .buffer = (VkBuffer)buf, .format = VK_FORMAT_R32_UINT, .range = 256 };
      struct vn_command_vkCreateBufferView cv = { .device = DEVH, .pCreateInfo = &info, .pView = &h };
      step("vkCreateBufferView, two usage flags 2 infos");
      D->dispatch_vkCreateBufferView(D, &cv);
      last_ret = cv.ret;
      return created(cv.ret == VK_SUCCESS ? object(id) : NULL);
   }
   if (IS("d-repeat-sampler")) {
      VkSamplerReductionModeCreateInfo r2 = { .sType = VK_STRUCTURE_TYPE_SAMPLER_REDUCTION_MODE_CREATE_INFO,
                                              .reductionMode = VK_SAMPLER_REDUCTION_MODE_WEIGHTED_AVERAGE };
      VkSamplerReductionModeCreateInfo r1 = r2;
      r1.pNext = &r2;
      const uint64_t id = next_id++;
      VkSampler h = (VkSampler)(uintptr_t)id;
      VkSamplerCreateInfo info = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, .pNext = &r1,
                                   .magFilter = VK_FILTER_LINEAR, .minFilter = VK_FILTER_LINEAR, .maxLod = 1 };
      struct vn_command_vkCreateSampler cs = { .device = DEVH, .pCreateInfo = &info, .pSampler = &h };
      step("vkCreateSampler, two reduction mode infos");
      D->dispatch_vkCreateSampler(D, &cs);
      last_ret = cs.ret;
      return created(cs.ret == VK_SUCCESS ? object(id) : NULL);
   }
   if (IS("p-repeat-inline-spirv")) {
      /* two SPIR-V modules chained into the stage: vkr scans the first only */
      VkShaderModuleCreateInfo m2 = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                      .codeSize = sizeof(spv_comp), .pCode = spv_comp };
      VkShaderModuleCreateInfo m1 = m2;
      m1.pNext = &m2;
      return created(compute_pipeline(w.layout, NULL, &m1, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL));
   }
   VkPipelineCreationFeedback whole1, whole2;
   VkPipelineCreationFeedbackCreateInfo fb2 = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO,
                                                .pPipelineCreationFeedback = &whole2 };
   VkPipelineCreationFeedbackCreateInfo fb1 = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CREATION_FEEDBACK_CREATE_INFO,
                                                .pNext = &fb2, .pPipelineCreationFeedback = &whole1 };
   if (IS("p-repeat-compute"))
      return created(compute_pipeline(w.layout, w.comp, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, &fb1));
   struct gfx g = { .rp = w.rp, .colors = 1, .vert = w.vert, .frag = w.frag };
   if (IS("p-repeat-gfx")) {
      g.feedback = true;
      g.next = &fb2; /* after the feedback info graphics_pipeline() chains first */
   } else if (IS("p-repeat-gfx-two-types-ok")) {
      g.feedback = true; /* a feedback info once; a divisor info once on the vertex input */
   }
   VkPipelineVertexInputDivisorStateCreateInfo d2 = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_DIVISOR_STATE_CREATE_INFO };
   VkPipelineVertexInputDivisorStateCreateInfo d1 = d2;
   d1.pNext = &d2;
   if (IS("p-repeat-gfx-vertex"))
      g.vi_next = &d1;
   if (IS("p-repeat-gfx-two-types-ok"))
      g.vi_next = &d2;
   VkPipelineSampleLocationsStateCreateInfoEXT s2 = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_SAMPLE_LOCATIONS_STATE_CREATE_INFO_EXT };
   VkPipelineSampleLocationsStateCreateInfoEXT s1 = s2;
   s1.pNext = &s2;
   if (IS("p-repeat-gfx-ms"))
      g.ms_next = &s1;
   VkPipelineColorWriteCreateInfoEXT cw2 = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_WRITE_CREATE_INFO_EXT };
   VkPipelineColorWriteCreateInfoEXT cw1 = cw2;
   cw1.pNext = &cw2;
   if (IS("p-repeat-gfx-blend"))
      g.cb_next = &cw1;
   return created(graphics_pipeline(w.layout, &g));
}

/* ---------------- values Vulkan ignores (virgl-venus-ignored-values.patch) ----------------
 * d-texel-*: a texel buffer view of the whole size with less than one texel after its
 * offset (LEGAL: VUID-VkBufferViewCreateInfo-offset-00925, -range-04059; both Mac drivers end
 * the process in Metal on it, "MTLTextureDescriptor has width of zero"). With nullDescriptor
 * on (-nd) vkr makes it a view without a driver view: written into a set (-nd), pushed
 * (-push), copied from one set into another (-copy), and alive when the context ends
 * (-teardown), each with a dispatch recorded; d-texel-empty: without nullDescriptor it stays
 * refused, with its reason; -misaligned: the offset rule still holds.
 * p-gfx-vstride-dynamic: LEGAL: a pipeline stride past maxVertexInputBindingStride while the
 * stride is dynamic (VUID-VkVertexInputBindingDescription-stride-00619 does not apply);
 * -bind: with vkCmdBindVertexBuffers2 at stride 16 and a draw recorded.
 * p-gfx-blend-*: a color blend state whose array or count the drivers read: no array (Mesa
 * and MoltenVK end the process), a count past the colors (MoltenVK reads past its formats).
 * Neither Mac driver has the extendedDynamicState3 blend features, so the dynamic blend
 * states never make them ignored here. -discard-ok: LEGAL, rasterization off, the state is
 * ignored; -dyn-ok: the count matches (vkr refuses nothing it did before).
 * c-null-text-*: refusal lines say "the whole size" and "no buffer". */
static void *texel_buffer(VkDeviceSize size)
{
   const uint64_t id = next_id++;
   VkBuffer h = (VkBuffer)(uintptr_t)id;
   VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                               .usage = VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT };
   struct vn_command_vkCreateBuffer c = { .device = DEVH, .pCreateInfo = &info, .pBuffer = &h };
   D->dispatch_vkCreateBuffer(D, &c);
   struct vkr_buffer *buf = object(id);
   if (c.ret != VK_SUCCESS || !buf)
      broken("texel buffer");
   VkMemoryRequirements req = { 0 };
   struct vn_command_vkGetBufferMemoryRequirements r = { .device = DEVH, .buffer = (VkBuffer)buf,
                                                        .pMemoryRequirements = &req };
   D->dispatch_vkGetBufferMemoryRequirements(D, &r);
   struct vn_command_vkBindBufferMemory bm = { .device = DEVH, .buffer = (VkBuffer)buf,
                                               .memory = (VkDeviceMemory)allocate(req.size, memory_type(req.memoryTypeBits)) };
   D->dispatch_vkBindBufferMemory(D, &bm);
   if (bm.ret != VK_SUCCESS)
      broken("texel buffer memory");
   return buf;
}

/* a whole-size RGBA32F (16-byte texel) view `left` bytes before the end of its buffer, at
 * offset `offset`; NULL when vkr refused it */
static void *texel_view(VkDeviceSize offset, VkDeviceSize left)
{
   void *buf = texel_buffer(offset + left);
   const uint64_t id = next_id++;
   VkBufferView h = (VkBufferView)(uintptr_t)id;
   VkBufferViewCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_VIEW_CREATE_INFO, .buffer = (VkBuffer)buf,
                                   .format = VK_FORMAT_R32G32B32A32_SFLOAT, .offset = offset,
                                   .range = VK_WHOLE_SIZE };
   struct vn_command_vkCreateBufferView cv = { .device = DEVH, .pCreateInfo = &info, .pView = &h };
   step("vkCreateBufferView the whole size at %" PRIu64 ", %" PRIu64 " bytes left (16-byte texels)",
        offset, left);
   D->dispatch_vkCreateBufferView(D, &cv);
   last_ret = cv.ret;
   step("vkCreateBufferView = %d", cv.ret);
   return cv.ret == VK_SUCCESS && !ended() ? object(id) : NULL;
}

static int texel_ignored_case(const char *c)
{
   const bool push = IS("d-texel-empty-push");
   setup((IS("d-texel-empty") ? 0 : N_NULLDESC) | (push ? N_PUSHDESC : 0));
   struct world w = { 0 };
   make_world(&w, true);
   const VkDeviceSize align = MAX2(lim.minTexelBufferOffsetAlignment, 16);
   void *view;
   if (IS("d-texel-one-nd"))
      view = texel_view(align, 16);
   else if (IS("d-texel-empty-nd-misaligned"))
      view = texel_view(align + 4, 8);
   else
      view = texel_view(align, 8);
   if (!view)
      return created(NULL);
   if (IS("d-texel-empty") || IS("d-texel-empty-nd-misaligned"))
      return WORKS;
   /* set 1: the texel buffer, beside the world's set 0 (what the compute shader reads) */
   const VkDescriptorSetLayoutBinding tb = { 0, VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1, VK_SHADER_STAGE_ALL, NULL };
   void *tdsl = set_layout_of(&tb, 1, push ? VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR : 0, NULL);
   void *dsls[2] = { w.dsl, tdsl };
   const VkPushConstantRange range = { VK_SHADER_STAGE_ALL, 0, 128 };
   void *layout = tdsl ? pipeline_layout_of(dsls, 2, &range, 1) : NULL;
   void *pipe = layout ? compute_pipeline(layout, w.comp, NULL, VK_SHADER_STAGE_COMPUTE_BIT, &spec_ok, NULL) : NULL;
   if (!pipe)
      broken("texel layout and pipeline");
   VkBufferView vh = (VkBufferView)view;
   VkWriteDescriptorSet wr = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstBinding = 0,
                               .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER,
                               .pTexelBufferView = &vh };
   void *set = NULL;
   if (!push) {
      VkDescriptorPoolSize size = { VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 2 };
      const uint64_t pid = next_id++;
      VkDescriptorPool ph = (VkDescriptorPool)(uintptr_t)pid;
      VkDescriptorPoolCreateInfo pinfo = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 2,
                                           .poolSizeCount = 1, .pPoolSizes = &size };
      struct vn_command_vkCreateDescriptorPool cpool = { .device = DEVH, .pCreateInfo = &pinfo,
                                                         .pDescriptorPool = &ph };
      D->dispatch_vkCreateDescriptorPool(D, &cpool);
      void *tpool = cpool.ret == VK_SUCCESS ? object(pid) : NULL;
      set = tpool ? set_from(tpool, tdsl, NULL) : NULL;
      void *set2 = tpool ? set_from(tpool, tdsl, NULL) : NULL;
      if (!set || !set2)
         broken("texel sets");
      wr.dstSet = (VkDescriptorSet)set;
      struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = 1,
                                                     .pDescriptorWrites = &wr };
      step("vkUpdateDescriptorSets the view");
      D->dispatch_vkUpdateDescriptorSets(D, &u);
      if (ended())
         return FATAL;
      if (IS("d-texel-empty-copy")) {
         VkCopyDescriptorSet cp = { .sType = VK_STRUCTURE_TYPE_COPY_DESCRIPTOR_SET, .srcSet = (VkDescriptorSet)set,
                                    .dstSet = (VkDescriptorSet)set2, .descriptorCount = 1 };
         struct vn_command_vkUpdateDescriptorSets uc = { .device = DEVH, .descriptorCopyCount = 1,
                                                         .pDescriptorCopies = &cp };
         step("vkUpdateDescriptorSets a copy of it into a second set");
         D->dispatch_vkUpdateDescriptorSets(D, &uc);
         if (ended())
            return FATAL;
         set = set2;
      }
      if (IS("d-texel-empty-teardown")) {
         step("the context ends with the view alive");
         vkr_context_destroy(ctx);
         step("the context is gone");
         return WORKS;
      }
   }
   begin(w.cmd);
   bind_pipeline(w.cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
   ready(w.cmd, &w, VK_PIPELINE_BIND_POINT_COMPUTE);
   if (push) {
      struct vn_command_vkCmdPushDescriptorSet p = { .commandBuffer = (VkCommandBuffer)w.cmd,
                                                     .pipelineBindPoint = VK_PIPELINE_BIND_POINT_COMPUTE,
                                                     .layout = (VkPipelineLayout)layout, .set = 1,
                                                     .descriptorWriteCount = 1, .pDescriptorWrites = &wr };
      step("vkCmdPushDescriptorSet the view");
      D->dispatch_vkCmdPushDescriptorSet(D, &p);
   } else {
      bind_sets(w.cmd, layout, 1, &set, 1, NULL, 0);
   }
   struct vn_command_vkCmdDispatch d = { .commandBuffer = (VkCommandBuffer)w.cmd, .groupCountX = 1,
                                         .groupCountY = 1, .groupCountZ = 1 };
   step("vkCmdDispatch 1 x 1 x 1");
   D->dispatch_vkCmdDispatch(D, &d);
   const int r = end(w.cmd);
   if (r != WORKS || !IS("d-texel-empty-nd"))
      return r;
   struct vn_command_vkDestroyBufferView dv = { .device = DEVH, .bufferView = vh };
   step("vkDestroyBufferView");
   D->dispatch_vkDestroyBufferView(D, &dv);
   return ended() ? FATAL : WORKS;
}

static int case_ignored(const char *c)
{
   if (!strncmp(c, "d-texel-", 8))
      return texel_ignored_case(c);
   setup(0);
   struct world w = { 0 };
   make_world(&w, true);
   if (!strncmp(c, "c-null-text-", 12)) {
      begin(w.cmd);
      const VkCommandBuffer cb = (VkCommandBuffer)w.cmd;
      if (IS("c-null-text-bind2")) {
         VkBuffer none = VK_NULL_HANDLE;
         VkDeviceSize off = 0, size = VK_WHOLE_SIZE, stride = 16;
         struct vn_command_vkCmdBindVertexBuffers2 b = { .commandBuffer = cb, .bindingCount = 1, .pBuffers = &none,
                                                         .pOffsets = &off, .pSizes = &size, .pStrides = &stride };
         step("vkCmdBindVertexBuffers2 no buffer, the whole size (nullDescriptor off)");
         D->dispatch_vkCmdBindVertexBuffers2(D, &b);
      } else if (IS("c-null-text-barrier")) {
         VkBufferMemoryBarrier bb = { .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
                                      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                                      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .size = VK_WHOLE_SIZE };
         struct vn_command_vkCmdPipelineBarrier p = { .commandBuffer = cb,
                                                      .srcStageMask = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                                                      .dstStageMask = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                                                      .bufferMemoryBarrierCount = 1, .pBufferMemoryBarriers = &bb };
         step("vkCmdPipelineBarrier a buffer barrier naming no buffer");
         D->dispatch_vkCmdPipelineBarrier(D, &p);
      } else if (IS("c-null-text-fill")) {
         struct vn_command_vkCmdFillBuffer f = { .commandBuffer = cb, .dstBuffer = (VkBuffer)w.buf,
                                                 .dstOffset = 65536, .size = VK_WHOLE_SIZE };
         step("vkCmdFillBuffer the whole size at the end of a 65536-byte buffer");
         D->dispatch_vkCmdFillBuffer(D, &f);
      } else {
         return BROKEN;
      }
      return end(w.cmd);
   }
   /* graphics: the world's pass has 1 color */
   struct gfx g = { .rp = w.rp, .colors = 1, .vert = w.vert, .frag = w.frag };
   static VkDynamicState blend3[4] = { VK_DYNAMIC_STATE_COLOR_BLEND_ENABLE_EXT, VK_DYNAMIC_STATE_COLOR_BLEND_EQUATION_EXT,
                                       VK_DYNAMIC_STATE_COLOR_WRITE_MASK_EXT, VK_DYNAMIC_STATE_COLOR_BLEND_ADVANCED_EXT };
   static VkDynamicState stride_dynamic[1] = { VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE };
   static VkDynamicState discard_dynamic[1] = { VK_DYNAMIC_STATE_RASTERIZER_DISCARD_ENABLE };
   if (IS("p-gfx-vstride-dynamic") || IS("p-gfx-vstride-dynamic-bind")) {
      if (lim.maxVertexInputBindingStride > 0xfffffffbu)
         return SKIP;
      g.vstride = lim.maxVertexInputBindingStride + 4;
      g.dynamic = stride_dynamic;
      g.dynamic_count = 1;
   } else if (IS("p-gfx-blend-null")) {
      g.blend_null = true;
   } else if (IS("p-gfx-blend-null-dyn")) {
      g.rp = NULL;
      g.colors = 2;
      g.blend_count = 1;
      g.blend_null = true;
      g.dynamic = blend3;
      g.dynamic_count = 3;
   } else if (IS("p-gfx-blend-more-dyn")) {
      g.blend_count = 3;
      g.dynamic = blend3;
      g.dynamic_count = 3;
   } else if (IS("p-gfx-blend-dyn-ok")) {
      g.dynamic = blend3;
      g.dynamic_count = 3;
   } else if (IS("p-gfx-blend-discard-ok")) {
      g.blend_null = true;
      g.discard = true;
   } else if (IS("p-gfx-blend-discard-dyn")) {
      g.blend_null = true;
      g.discard = true;
      g.dynamic = discard_dynamic;
      g.dynamic_count = 1;
   } else {
      return BROKEN;
   }
   void *pipe = graphics_pipeline(w.layout, &g);
   if (!IS("p-gfx-vstride-dynamic-bind") || !pipe)
      return created(pipe);
   begin(w.cmd);
   begin_pass(w.cmd, w.rp, w.fb, 64, 64);
   bind_pipeline(w.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
   ready(w.cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
   VkBuffer vb = (VkBuffer)w.buf;
   VkDeviceSize off = 0, size = VK_WHOLE_SIZE, stride = 16;
   struct vn_command_vkCmdBindVertexBuffers2 b = { .commandBuffer = (VkCommandBuffer)w.cmd, .bindingCount = 1,
                                                   .pBuffers = &vb, .pOffsets = &off, .pSizes = &size,
                                                   .pStrides = &stride };
   step("vkCmdBindVertexBuffers2 stride 16");
   D->dispatch_vkCmdBindVertexBuffers2(D, &b);
   struct vn_command_vkCmdDraw draw = { .commandBuffer = (VkCommandBuffer)w.cmd, .vertexCount = 3,
                                        .instanceCount = 1 };
   step("vkCmdDraw 3");
   D->dispatch_vkCmdDraw(D, &draw);
   end_pass(w.cmd);
   return end(w.cmd);
}

/* ---------------- state a draw or dispatch never set (virgl-venus-unset-state.patch) ----------------
 * MoltenVK reads, when it encodes (at the submit, or at the end with prefill), the set at
 * each set the bound pipeline's shaders use and the index buffer of an indexed draw: one
 * never bound is a NULL slot, SIGSEGV (the M1 probes, work/v624-unset). Refused (Vulkan
 * does not allow them): u-set-unset (a draw, the world's fragment shader uses set 0,
 * nothing bound: VUID-vkCmdDraw-None-08600), -second-unset (a vertex shader of sets 0 and
 * 1, set 0 bound), -unset-dispatch, -second-unset-dispatch (a compute shader of sets 0, 1
 * and 2, sets 0 and 1 bound), -other-point (the set bound at the compute point, then a
 * draw), -secondary (a secondary inherits no state: the primary's set does not count);
 * u-ib-unset* (each of the four indexed draws without an index buffer, maintenance6 off:
 * -None-07312). LEGAL, taken: u-set-*-ok: a set only in the layout, a set only listed in a
 * SPIR-V 1.6 interface (vkr counts what a reached function uses: fewer sets than Vulkan's
 * static use), sets bound before the pipeline and kept over a second pipeline, a push, the
 * *2 binds by stage (graphics, compute, both at once), a push2; u-ib-*-m6-ok: maintenance6
 * on, the NULL index buffer bound or none at all (vkr binds the NULL one), each indexed
 * entry, then (MoltenVK) submitted and waited for: 3 vertices at index 0, a legal draw;
 * u-ib-bound-ok. Kept (invalid, but no driver reads it when it encodes, so vkr lets it
 * through): u-set-execute-kept (a dispatch after vkCmdExecuteCommands on the primary's
 * bindings), u-pc-unset-kept (push constants never set), u-vb-unset-kept (a vertex buffer
 * the vertex shader reads, never bound).
 *
 * glslc --target-env=vulkan1.0 (shaderc v2026.4), spirv-val clean
 * (work/v624-unset/build/shaders): a vertex shader using set 0 and set 1 (a uniform buffer
 * at binding 0 each, read only past vertex 1000000) and a fragment shader of no set. */
static const uint32_t spv_u_vs_set01[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000042, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0007000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000c, 0x00000021, 0x00030003,
   0x00000002, 0x000001c2, 0x000a0004, 0x475f4c47, 0x4c474f4f, 0x70635f45, 0x74735f70, 0x5f656c79,
   0x656e696c, 0x7269645f, 0x69746365, 0x00006576, 0x00080004, 0x475f4c47, 0x4c474f4f, 0x6e695f45,
   0x64756c63, 0x69645f65, 0x74636572, 0x00657669, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000,
   0x00030005, 0x00000009, 0x00000070, 0x00060005, 0x0000000c, 0x565f6c67, 0x65747265, 0x646e4978,
   0x00007865, 0x00060005, 0x0000001f, 0x505f6c67, 0x65567265, 0x78657472, 0x00000000, 0x00060006,
   0x0000001f, 0x00000000, 0x505f6c67, 0x7469736f, 0x006e6f69, 0x00070006, 0x0000001f, 0x00000001,
   0x505f6c67, 0x746e696f, 0x657a6953, 0x00000000, 0x00070006, 0x0000001f, 0x00000002, 0x435f6c67,
   0x4470696c, 0x61747369, 0x0065636e, 0x00070006, 0x0000001f, 0x00000003, 0x435f6c67, 0x446c6c75,
   0x61747369, 0x0065636e, 0x00030005, 0x00000021, 0x00000000, 0x00030005, 0x00000032, 0x00003055,
   0x00040006, 0x00000032, 0x00000000, 0x00000076, 0x00030005, 0x00000034, 0x00003075, 0x00030005,
   0x00000038, 0x00003155, 0x00040006, 0x00000038, 0x00000000, 0x00000076, 0x00030005, 0x0000003a,
   0x00003175, 0x00040047, 0x0000000c, 0x0000000b, 0x0000002a, 0x00030047, 0x0000001f, 0x00000002,
   0x00050048, 0x0000001f, 0x00000000, 0x0000000b, 0x00000000, 0x00050048, 0x0000001f, 0x00000001,
   0x0000000b, 0x00000001, 0x00050048, 0x0000001f, 0x00000002, 0x0000000b, 0x00000003, 0x00050048,
   0x0000001f, 0x00000003, 0x0000000b, 0x00000004, 0x00030047, 0x00000032, 0x00000002, 0x00050048,
   0x00000032, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x00000034, 0x00000021, 0x00000000,
   0x00040047, 0x00000034, 0x00000022, 0x00000000, 0x00030047, 0x00000038, 0x00000002, 0x00050048,
   0x00000038, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x0000003a, 0x00000021, 0x00000000,
   0x00040047, 0x0000003a, 0x00000022, 0x00000001, 0x00020013, 0x00000002, 0x00030021, 0x00000003,
   0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000002,
   0x00040020, 0x00000008, 0x00000007, 0x00000007, 0x00040015, 0x0000000a, 0x00000020, 0x00000001,
   0x00040020, 0x0000000b, 0x00000001, 0x0000000a, 0x0004003b, 0x0000000b, 0x0000000c, 0x00000001,
   0x0004002b, 0x0000000a, 0x0000000e, 0x00000001, 0x0004002b, 0x00000006, 0x00000011, 0x40000000,
   0x0004002b, 0x00000006, 0x00000013, 0x3f800000, 0x00040017, 0x0000001b, 0x00000006, 0x00000004,
   0x00040015, 0x0000001c, 0x00000020, 0x00000000, 0x0004002b, 0x0000001c, 0x0000001d, 0x00000001,
   0x0004001c, 0x0000001e, 0x00000006, 0x0000001d, 0x0006001e, 0x0000001f, 0x0000001b, 0x00000006,
   0x0000001e, 0x0000001e, 0x00040020, 0x00000020, 0x00000003, 0x0000001f, 0x0004003b, 0x00000020,
   0x00000021, 0x00000003, 0x0004002b, 0x0000000a, 0x00000022, 0x00000000, 0x0004002b, 0x00000006,
   0x00000024, 0x3f000000, 0x0004002b, 0x00000006, 0x00000026, 0x00000000, 0x00040020, 0x0000002a,
   0x00000003, 0x0000001b, 0x0004002b, 0x0000000a, 0x0000002d, 0x000f4240, 0x00020014, 0x0000002e,
   0x0003001e, 0x00000032, 0x0000001b, 0x00040020, 0x00000033, 0x00000002, 0x00000032, 0x0004003b,
   0x00000033, 0x00000034, 0x00000002, 0x00040020, 0x00000035, 0x00000002, 0x0000001b, 0x0003001e,
   0x00000038, 0x0000001b, 0x00040020, 0x00000039, 0x00000002, 0x00000038, 0x0004003b, 0x00000039,
   0x0000003a, 0x00000002, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8,
   0x00000005, 0x0004003b, 0x00000008, 0x00000009, 0x00000007, 0x0004003d, 0x0000000a, 0x0000000d,
   0x0000000c, 0x000500c7, 0x0000000a, 0x0000000f, 0x0000000d, 0x0000000e, 0x0004006f, 0x00000006,
   0x00000010, 0x0000000f, 0x00050085, 0x00000006, 0x00000012, 0x00000010, 0x00000011, 0x00050083,
   0x00000006, 0x00000014, 0x00000012, 0x00000013, 0x0004003d, 0x0000000a, 0x00000015, 0x0000000c,
   0x000500c3, 0x0000000a, 0x00000016, 0x00000015, 0x0000000e, 0x0004006f, 0x00000006, 0x00000017,
   0x00000016, 0x00050085, 0x00000006, 0x00000018, 0x00000017, 0x00000011, 0x00050083, 0x00000006,
   0x00000019, 0x00000018, 0x00000013, 0x00050050, 0x00000007, 0x0000001a, 0x00000014, 0x00000019,
   0x0003003e, 0x00000009, 0x0000001a, 0x0004003d, 0x00000007, 0x00000023, 0x00000009, 0x0005008e,
   0x00000007, 0x00000025, 0x00000023, 0x00000024, 0x00050051, 0x00000006, 0x00000027, 0x00000025,
   0x00000000, 0x00050051, 0x00000006, 0x00000028, 0x00000025, 0x00000001, 0x00070050, 0x0000001b,
   0x00000029, 0x00000027, 0x00000028, 0x00000026, 0x00000013, 0x00050041, 0x0000002a, 0x0000002b,
   0x00000021, 0x00000022, 0x0003003e, 0x0000002b, 0x00000029, 0x0004003d, 0x0000000a, 0x0000002c,
   0x0000000c, 0x000500ad, 0x0000002e, 0x0000002f, 0x0000002c, 0x0000002d, 0x000300f7, 0x00000031,
   0x00000000, 0x000400fa, 0x0000002f, 0x00000030, 0x00000031, 0x000200f8, 0x00000030, 0x00050041,
   0x00000035, 0x00000036, 0x00000034, 0x00000022, 0x0004003d, 0x0000001b, 0x00000037, 0x00000036,
   0x00050041, 0x00000035, 0x0000003b, 0x0000003a, 0x00000022, 0x0004003d, 0x0000001b, 0x0000003c,
   0x0000003b, 0x00050081, 0x0000001b, 0x0000003d, 0x00000037, 0x0000003c, 0x00050041, 0x0000002a,
   0x0000003e, 0x00000021, 0x00000022, 0x0004003d, 0x0000001b, 0x0000003f, 0x0000003e, 0x00050081,
   0x0000001b, 0x00000040, 0x0000003f, 0x0000003d, 0x00050041, 0x0000002a, 0x00000041, 0x00000021,
   0x00000022, 0x0003003e, 0x00000041, 0x00000040, 0x000200f9, 0x00000031, 0x000200f8, 0x00000031,
   0x000100fd, 0x00010038,
};
static const uint32_t spv_u_fs[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x0000000e, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0006000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x00000009, 0x00030010, 0x00000004,
   0x00000007, 0x00030003, 0x00000002, 0x000001c2, 0x000a0004, 0x475f4c47, 0x4c474f4f, 0x70635f45,
   0x74735f70, 0x5f656c79, 0x656e696c, 0x7269645f, 0x69746365, 0x00006576, 0x00080004, 0x475f4c47,
   0x4c474f4f, 0x6e695f45, 0x64756c63, 0x69645f65, 0x74636572, 0x00657669, 0x00040005, 0x00000004,
   0x6e69616d, 0x00000000, 0x00030005, 0x00000009, 0x0000006f, 0x00040047, 0x00000009, 0x0000001e,
   0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006,
   0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008, 0x00000003,
   0x00000007, 0x0004003b, 0x00000008, 0x00000009, 0x00000003, 0x0004002b, 0x00000006, 0x0000000a,
   0x3f800000, 0x0004002b, 0x00000006, 0x0000000b, 0x3f000000, 0x0004002b, 0x00000006, 0x0000000c,
   0x3e800000, 0x0007002c, 0x00000007, 0x0000000d, 0x0000000a, 0x0000000b, 0x0000000c, 0x0000000a,
   0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0003003e,
   0x00000009, 0x0000000d, 0x000100fd, 0x00010038,
};

static void *u_layout(VkDescriptorType type, uint32_t binding, VkDescriptorSetLayoutCreateFlags flags)
{
   const VkDescriptorSetLayoutBinding b = { binding, type, 1, VK_SHADER_STAGE_ALL, NULL };
   void *l = set_layout_of(&b, 1, flags, NULL);
   if (!l)
      broken("set layout");
   return l;
}

/* the one write of a u_layout set (a buffer at 1024, or the world's image and sampler) */
static VkWriteDescriptorSet u_write(struct world *w, void *set, VkDescriptorType type, uint32_t binding)
{
   static VkDescriptorBufferInfo bi;
   static VkDescriptorImageInfo ii;
   bi = (VkDescriptorBufferInfo){ (VkBuffer)w->buf, 1024, 256 };
   ii = (VkDescriptorImageInfo){ (VkSampler)w->smp, (VkImageView)w->iv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
   const bool image = type == VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
   return (VkWriteDescriptorSet){ .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = (VkDescriptorSet)set,
                                  .dstBinding = binding, .descriptorCount = 1, .descriptorType = type,
                                  .pBufferInfo = image ? NULL : &bi, .pImageInfo = image ? &ii : NULL };
}

/* a set of a u_layout from the world's pool, written */
static void *u_set(struct world *w, void *dsl, VkDescriptorType type, uint32_t binding)
{
   void *set = set_from(w->pool, dsl, NULL);
   if (!set)
      broken("set");
   VkWriteDescriptorSet wr = u_write(w, set, type, binding);
   struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = 1, .pDescriptorWrites = &wr };
   D->dispatch_vkUpdateDescriptorSets(D, &u);
   return set;
}

static void u_bind(void *cmd, VkPipelineBindPoint point, void *layout, uint32_t first, void **sets, uint32_t n)
{
   VkDescriptorSet s[8];
   for (uint32_t i = 0; i < n && i < 8; i++)
      s[i] = (VkDescriptorSet)sets[i];
   struct vn_command_vkCmdBindDescriptorSets b = { .commandBuffer = (VkCommandBuffer)cmd, .pipelineBindPoint = point,
                                                   .layout = (VkPipelineLayout)layout, .firstSet = first,
                                                   .descriptorSetCount = n, .pDescriptorSets = s };
   step("vkCmdBindDescriptorSets point %d sets %u + %u", point, first, n);
   D->dispatch_vkCmdBindDescriptorSets(D, &b);
}

static void u_draw(void *cmd)
{
   struct vn_command_vkCmdDraw d = { .commandBuffer = (VkCommandBuffer)cmd, .vertexCount = 3, .instanceCount = 1 };
   step("vkCmdDraw 3");
   D->dispatch_vkCmdDraw(D, &d);
}

static void u_dispatch(void *cmd)
{
   struct vn_command_vkCmdDispatch d = { .commandBuffer = (VkCommandBuffer)cmd, .groupCountX = 1, .groupCountY = 1,
                                         .groupCountZ = 1 };
   step("vkCmdDispatch 1 x 1 x 1");
   D->dispatch_vkCmdDispatch(D, &d);
}

/* the world's set by vkCmdBindDescriptorSets2 for `stages` */
static void u_bind2(void *cmd, struct world *w, VkShaderStageFlags stages)
{
   VkDescriptorSet set = (VkDescriptorSet)w->set;
   const uint32_t off = 0;
   VkBindDescriptorSetsInfo info = { .sType = VK_STRUCTURE_TYPE_BIND_DESCRIPTOR_SETS_INFO, .stageFlags = stages,
                                     .layout = (VkPipelineLayout)w->layout, .descriptorSetCount = 1,
                                     .pDescriptorSets = &set, .dynamicOffsetCount = 1, .pDynamicOffsets = &off };
   struct vn_command_vkCmdBindDescriptorSets2 b = { .commandBuffer = (VkCommandBuffer)cmd,
                                                    .pBindDescriptorSetsInfo = &info };
   step("vkCmdBindDescriptorSets2 stages 0x%x", stages);
   D->dispatch_vkCmdBindDescriptorSets2(D, &b);
}

/* the submit of a recorded command buffer, and the driver's own wait (vkr refuses
 * vkQueueWaitIdle from a guest) */
static int u_submit(void *cmd)
{
   struct vkr_queue *q = device_queue();
   VkCommandBuffer cb = (VkCommandBuffer)cmd;
   VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
   struct vn_command_vkQueueSubmit s = { .queue = (VkQueue)q, .submitCount = 1, .pSubmits = &submit };
   step("vkQueueSubmit");
   D->dispatch_vkQueueSubmit(D, &s);
   step("vkQueueSubmit = %d", s.ret);
   if (ended())
      return FATAL;
   q->device->proc_table.QueueWaitIdle(q->base.handle.queue);
   step("the queue is idle");
   return s.ret == VK_SUCCESS ? WORKS : ERROR;
}

static int unset_set_case(const char *c)
{
   unsigned needs = 0;
   if (strstr(c, "-push"))
      needs |= N_PUSHDESC;
   if (strstr(c, "-bind2") || strstr(c, "-push2"))
      needs |= N_MAINT6;
   setup(needs);
   struct world w = { 0 };
   make_world(&w, true);
   void *cmd = w.cmd;
   const VkPipelineBindPoint G = VK_PIPELINE_BIND_POINT_GRAPHICS, C = VK_PIPELINE_BIND_POINT_COMPUTE;
   const VkPushConstantRange push = { VK_SHADER_STAGE_ALL, 0, 128 };
   void *ubo = u_layout(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 0, 0);
   /* the vertex shader of sets 0 and 1 (set 1: a plain or a push layout) */
   void *vs01_pipe = NULL, *vs01_layout = NULL, *set0 = NULL;
   if (IS("u-set-second-unset") || IS("u-set-push-ok") || IS("u-set-push2-ok")) {
      void *dsls[2] = { ubo, IS("u-set-second-unset") ? ubo
                                                      : u_layout(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 0,
                                                                 VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT_KHR) };
      vs01_layout = pipeline_layout_of(dsls, 2, NULL, 0);
      const struct gfx g = { .rp = w.rp, .colors = 1, .vert = shader(spv_u_vs_set01, sizeof(spv_u_vs_set01)),
                             .frag = shader(spv_u_fs, sizeof(spv_u_fs)) };
      vs01_pipe = vs01_layout && g.vert && g.frag ? graphics_pipeline(vs01_layout, &g) : NULL;
      if (!vs01_pipe)
         broken("the pipeline of sets 0 and 1");
      set0 = u_set(&w, ubo, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 0);
   }
   begin(cmd);
   if (IS("u-set-unset") || IS("u-set-other-point")) {
      begin_pass(cmd, w.rp, w.fb, 64, 64);
      bind_pipeline(cmd, G, w.gfx_pipe);
      ready_except_set(cmd, &w, G);
      if (IS("u-set-other-point"))
         bind_world_set(cmd, &w, C);
      u_draw(cmd);
      end_pass(cmd);
   } else if (vs01_pipe) {
      begin_pass(cmd, w.rp, w.fb, 64, 64);
      bind_pipeline(cmd, G, vs01_pipe);
      u_bind(cmd, G, vs01_layout, 0, &set0, 1);
      if (!IS("u-set-second-unset")) {
         VkWriteDescriptorSet wr = u_write(&w, NULL, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 0);
         if (IS("u-set-push-ok")) {
            struct vn_command_vkCmdPushDescriptorSet p = { .commandBuffer = (VkCommandBuffer)cmd, .pipelineBindPoint = G,
                                                           .layout = (VkPipelineLayout)vs01_layout, .set = 1,
                                                           .descriptorWriteCount = 1, .pDescriptorWrites = &wr };
            step("vkCmdPushDescriptorSet set 1");
            D->dispatch_vkCmdPushDescriptorSet(D, &p);
         } else {
            VkPushDescriptorSetInfo info = { .sType = VK_STRUCTURE_TYPE_PUSH_DESCRIPTOR_SET_INFO,
                                             .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
                                             .layout = (VkPipelineLayout)vs01_layout, .set = 1,
                                             .descriptorWriteCount = 1, .pDescriptorWrites = &wr };
            struct vn_command_vkCmdPushDescriptorSet2 p = { .commandBuffer = (VkCommandBuffer)cmd,
                                                            .pPushDescriptorSetInfo = &info };
            step("vkCmdPushDescriptorSet2 set 1, the vertex stage");
            D->dispatch_vkCmdPushDescriptorSet2(D, &p);
         }
      }
      u_draw(cmd);
      end_pass(cmd);
   } else if (IS("u-set-declared-ok")) {
      /* set 1 in the layout, no shader uses it */
      void *dsls[2] = { w.dsl, ubo };
      void *layout = pipeline_layout_of(dsls, 2, &push, 1);
      const struct gfx g = { .rp = w.rp, .colors = 1, .vert = w.vert, .frag = w.frag };
      void *pipe = layout ? graphics_pipeline(layout, &g) : NULL;
      if (!pipe)
         broken("the pipeline of 2 sets");
      begin_pass(cmd, w.rp, w.fb, 64, 64);
      bind_pipeline(cmd, G, pipe);
      ready(cmd, &w, G);
      u_draw(cmd);
      end_pass(cmd);
   } else if (IS("u-set-rebind-ok")) {
      /* the sets before any pipeline, then two pipelines of the same layout */
      const struct gfx g = { .rp = w.rp, .colors = 1, .vert = w.vert, .frag = w.frag };
      void *second = graphics_pipeline(w.layout, &g);
      if (!second)
         broken("a second pipeline");
      begin_pass(cmd, w.rp, w.fb, 64, 64);
      ready(cmd, &w, G);
      bind_pipeline(cmd, G, w.gfx_pipe);
      u_draw(cmd);
      bind_pipeline(cmd, G, second);
      u_draw(cmd);
      end_pass(cmd);
   } else if (IS("u-set-bind2-ok")) {
      begin_pass(cmd, w.rp, w.fb, 64, 64);
      bind_pipeline(cmd, G, w.gfx_pipe);
      ready_except_set(cmd, &w, G);
      u_bind2(cmd, &w, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT);
      u_draw(cmd);
      end_pass(cmd);
   } else if (IS("u-set-bind2-dispatch-ok")) {
      bind_pipeline(cmd, C, w.comp_pipe);
      ready_except_set(cmd, &w, C);
      u_bind2(cmd, &w, VK_SHADER_STAGE_COMPUTE_BIT);
      u_dispatch(cmd);
   } else if (IS("u-set-bind2-both-ok")) {
      /* one bind for both points */
      u_bind2(cmd, &w, VK_SHADER_STAGE_ALL);
      bind_pipeline(cmd, C, w.comp_pipe);
      ready_except_set(cmd, &w, C);
      u_dispatch(cmd);
      begin_pass(cmd, w.rp, w.fb, 64, 64);
      bind_pipeline(cmd, G, w.gfx_pipe);
      ready_except_set(cmd, &w, G);
      u_draw(cmd);
      end_pass(cmd);
   } else if (IS("u-set-unset-dispatch")) {
      bind_pipeline(cmd, C, w.comp_pipe);
      ready_except_set(cmd, &w, C);
      u_dispatch(cmd);
   } else if (IS("u-set-second-unset-dispatch") || IS("u-set-interface-only-ok")) {
      /* sets 0 (storage buffer 0), 1 (combined image sampler 0), 2 (uniform buffer 3); the
       * 1.6 shader also lists set 5 (storage buffer 1) in its interface, used nowhere */
      const bool iface = IS("u-set-interface-only-ok");
      void *ssbo0 = u_layout(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 0, 0);
      void *cis0 = u_layout(VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 0, 0);
      void *ubo3 = u_layout(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 3, 0);
      void *dsls[6] = { ssbo0, cis0, ubo3, ubo, ubo, u_layout(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, 0) };
      void *layout = pipeline_layout_of(dsls, iface ? 6 : 3, NULL, 0);
      void *module = iface ? shader(spv_comp16, sizeof(spv_comp16)) : shader(spv_comp10, sizeof(spv_comp10));
      void *pipe = layout && module ? compute_pipeline(layout, module, NULL, VK_SHADER_STAGE_COMPUTE_BIT, NULL, NULL)
                                    : NULL;
      if (!pipe)
         broken("the pipeline of sets 0, 1, 2");
      void *sets[3] = { u_set(&w, ssbo0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 0),
                        u_set(&w, cis0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 0),
                        u_set(&w, ubo3, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 3) };
      bind_pipeline(cmd, C, pipe);
      u_bind(cmd, C, layout, 0, sets, iface ? 3 : 2);
      u_dispatch(cmd);
   } else if (IS("u-set-secondary")) {
      /* the primary binds the set; a secondary binds the pipeline and dispatches */
      ready(cmd, &w, C);
      void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
      if (begin_secondary(sec, NULL) != VK_SUCCESS)
         broken("secondary begin");
      bind_pipeline(sec, C, w.comp_pipe);
      ready_except_set(sec, &w, C);
      u_dispatch(sec);
      return end(sec);
   } else if (IS("u-set-execute-kept")) {
      void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
      if (begin_secondary(sec, NULL) != VK_SUCCESS || end(sec) != WORKS)
         broken("an empty secondary");
      bind_pipeline(cmd, C, w.comp_pipe);
      ready(cmd, &w, C);
      VkCommandBuffer s = (VkCommandBuffer)sec;
      struct vn_command_vkCmdExecuteCommands e = { .commandBuffer = (VkCommandBuffer)cmd, .commandBufferCount = 1,
                                                   .pCommandBuffers = &s };
      step("vkCmdExecuteCommands (an empty secondary)");
      D->dispatch_vkCmdExecuteCommands(D, &e);
      u_dispatch(cmd);
   } else if (IS("u-pc-unset-kept") || IS("u-vb-unset-kept")) {
      begin_pass(cmd, w.rp, w.fb, 64, 64);
      bind_pipeline(cmd, G, w.gfx_pipe);
      bind_world_set(cmd, &w, G);
      if (IS("u-pc-unset-kept")) {
         VkBuffer vb = (VkBuffer)w.buf;
         VkDeviceSize vo = 0;
         struct vn_command_vkCmdBindVertexBuffers v = { .commandBuffer = (VkCommandBuffer)cmd, .bindingCount = 1,
                                                        .pBuffers = &vb, .pOffsets = &vo };
         D->dispatch_vkCmdBindVertexBuffers(D, &v);
      } else {
         static uint8_t data[128];
         struct vn_command_vkCmdPushConstants p = { .commandBuffer = (VkCommandBuffer)cmd,
                                                    .layout = (VkPipelineLayout)w.layout,
                                                    .stageFlags = VK_SHADER_STAGE_ALL, .size = 128, .pValues = data };
         D->dispatch_vkCmdPushConstants(D, &p);
      }
      u_draw(cmd);
      end_pass(cmd);
   } else {
      return BROKEN;
   }
   return end(cmd);
}

/* an indexed draw of the entry the name ends in (-indirect, -indirect-count, -multi, else
 * vkCmdDrawIndexed): 3 indices, one instance; the indirect ones read `ind` (a command at
 * 0, a count of 1 at 256) */
static void u_draw_indexed(const char *c, void *cmd, void *ind)
{
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   if (strstr(c, "-indirect-count")) {
      struct vn_command_vkCmdDrawIndexedIndirectCount d = { .commandBuffer = cb, .buffer = (VkBuffer)ind,
                                                             .countBuffer = (VkBuffer)ind, .countBufferOffset = 256,
                                                             .maxDrawCount = 1, .stride = 20 };
      step("vkCmdDrawIndexedIndirectCount");
      D->dispatch_vkCmdDrawIndexedIndirectCount(D, &d);
   } else if (strstr(c, "-indirect")) {
      struct vn_command_vkCmdDrawIndexedIndirect d = { .commandBuffer = cb, .buffer = (VkBuffer)ind, .drawCount = 1,
                                                        .stride = 20 };
      step("vkCmdDrawIndexedIndirect");
      D->dispatch_vkCmdDrawIndexedIndirect(D, &d);
   } else if (strstr(c, "-multi")) {
      static VkMultiDrawIndexedInfoEXT info = { 0, 3, 0 };
      struct vn_command_vkCmdDrawMultiIndexedEXT d = { .commandBuffer = cb, .drawCount = 1, .pIndexInfo = &info,
                                                        .instanceCount = 1, .stride = sizeof(info) };
      step("vkCmdDrawMultiIndexedEXT 1 draw");
      D->dispatch_vkCmdDrawMultiIndexedEXT(D, &d);
   } else {
      struct vn_command_vkCmdDrawIndexed d = { .commandBuffer = cb, .indexCount = 3, .instanceCount = 1 };
      step("vkCmdDrawIndexed 3");
      D->dispatch_vkCmdDrawIndexed(D, &d);
   }
}

static int unset_index_case(const char *c)
{
   const bool m6 = strstr(c, "-m6") != NULL;
   setup((m6 ? N_MAINT6 : 0) | (strstr(c, "-multi") ? N_MULTIDRAW : 0));
   if (strstr(c, "-indirect-count") && !have_indirect_count) {
      printf("skip: the device has no drawIndirectCount\n");
      return SKIP;
   }
   struct world w = { 0 };
   make_world(&w, true);
   void *cmd = w.cmd;
   const VkCommandBuffer cb = (VkCommandBuffer)cmd;
   void *ind = buffer(4096);
   begin(cmd);
   /* the indirect command (3 indices, one instance) and its count, before the pass */
   static const uint32_t command[5] = { 3, 1, 0, 0, 0 }, count = 1;
   struct vn_command_vkCmdUpdateBuffer u1 = { .commandBuffer = cb, .dstBuffer = (VkBuffer)ind, .dataSize = 20,
                                              .pData = command };
   D->dispatch_vkCmdUpdateBuffer(D, &u1);
   struct vn_command_vkCmdUpdateBuffer u2 = { .commandBuffer = cb, .dstBuffer = (VkBuffer)ind, .dstOffset = 256,
                                              .dataSize = 4, .pData = &count };
   D->dispatch_vkCmdUpdateBuffer(D, &u2);
   VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                          .dstAccessMask = VK_ACCESS_INDIRECT_COMMAND_READ_BIT };
   struct vn_command_vkCmdPipelineBarrier b = { .commandBuffer = cb, .srcStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
                                                .dstStageMask = VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
                                                .memoryBarrierCount = 1, .pMemoryBarriers = &mb };
   D->dispatch_vkCmdPipelineBarrier(D, &b);
   begin_pass(cmd, w.rp, w.fb, 64, 64);
   bind_pipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w.gfx_pipe);
   ready(cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
   if (IS("u-ib-null-m6-ok") || IS("u-ib-bound-ok")) {
      struct vn_command_vkCmdBindIndexBuffer ib = { .commandBuffer = cb,
                                                    .buffer = IS("u-ib-bound-ok") ? (VkBuffer)w.buf : VK_NULL_HANDLE,
                                                    .indexType = VK_INDEX_TYPE_UINT32 };
      step("vkCmdBindIndexBuffer %s", ib.buffer ? "a buffer" : "VK_NULL_HANDLE");
      D->dispatch_vkCmdBindIndexBuffer(D, &ib);
   }
   u_draw_indexed(c, cmd, ind);
   end_pass(cmd);
   const int r = end(cmd);
   if (r != WORKS || !m6)
      return r;
   if (kosmickrisp) {
      printf("note: recorded only on KosmicKrisp (MoltenVK submits it)\n");
      return WORKS;
   }
   return u_submit(cmd);
}

static int case_unset(const char *c)
{
   return !strncmp(c, "u-ib-", 5) ? unset_index_case(c) : unset_set_case(c);
}

/* ---------------- host memory: Metal passes, recordings, objects, heaps (h-) ----------------
 * virgl-venus-encoder-cap.patch, virgl-venus-host-memory.patch, ADR 0065. Metal ends the
 * process at about 98304 passes in one Metal command buffer (KosmicKrisp while recording,
 * MoltenVK when it encodes); recordings and objects cost the Mac memory vkr did not count.
 * Each case sets its budget and caps before the setup (OMACVM_GPU_MEMORY_MB,
 * OMACVM_VENUS_HOST_MB, OMACVM_VENUS_ENCODER_CAP: the tests' 1024 makes the legal maximum
 * small enough to charge). Refused: the context ends with a refusal line. */
/* a real module of Tests/virgl/spirv-corpus/pass (VENUS_SPIRV_CORPUS, else beside this
 * file): its bytes in OUT */
static size_t corpus_module(const char *name, uint32_t *out, size_t max)
{
   char path[2048];
   const char *dir = getenv("VENUS_SPIRV_CORPUS");
   const char *slash = strrchr(__FILE__, '/');
   if (dir)
      snprintf(path, sizeof(path), "%s/%s", dir, name);
   else
      snprintf(path, sizeof(path), "%.*s/spirv-corpus/pass/%s", slash ? (int)(slash - __FILE__) : 1,
               slash ? __FILE__ : ".", name);
   FILE *f = fopen(path, "rb");
   if (!f)
      broken(path);
   const size_t n = fread(out, 1, max, f);
   fclose(f);
   if (!n || n % 4 || n == max)
      broken("a corpus module of a size this test does not take");
   return n;
}

/* a pipeline cache made from DATA (NULL: an empty one); NULL when refused */
static void *cache_made(const void *data, size_t bytes)
{
   const uint64_t id = next_id++;
   VkPipelineCache h = (VkPipelineCache)(uintptr_t)id;
   VkPipelineCacheCreateInfo info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO,
                                      .initialDataSize = bytes, .pInitialData = data };
   struct vn_command_vkCreatePipelineCache c = { .device = DEVH, .pCreateInfo = &info, .pPipelineCache = &h };
   D->dispatch_vkCreatePipelineCache(D, &c);
   last_ret = c.ret;
   return c.ret == VK_SUCCESS ? object(id) : NULL;
}

/* the driver's own data of CACHE (vkGetPipelineCacheData) into OUT: its size */
static size_t cache_data(void *cache, uint8_t *out, size_t max)
{
   size_t bytes = 0;
   struct vn_command_vkGetPipelineCacheData g = { .device = DEVH, .pipelineCache = (VkPipelineCache)cache,
                                                  .pDataSize = &bytes };
   D->dispatch_vkGetPipelineCacheData(D, &g);
   if (g.ret != VK_SUCCESS || !bytes || bytes > max)
      broken("vkGetPipelineCacheData (size)");
   /* fresh arguments: vkr replaced the handles of the first call's */
   struct vn_command_vkGetPipelineCacheData g2 = { .device = DEVH, .pipelineCache = (VkPipelineCache)cache,
                                                   .pDataSize = &bytes, .pData = out };
   D->dispatch_vkGetPipelineCacheData(D, &g2);
   if (g2.ret != VK_SUCCESS)
      broken("vkGetPipelineCacheData");
   return bytes;
}

static void h_env(const char *budget_mb, const char *host_mb, const char *cap)
{
   setenv("OMACVM_GPU_MEMORY_RESERVE_MB", "0", 1);
   if (budget_mb)
      setenv("OMACVM_GPU_MEMORY_MB", budget_mb, 1);
   if (host_mb)
      setenv("OMACVM_VENUS_HOST_MB", host_mb, 1);
   if (cap)
      setenv("OMACVM_VENUS_ENCODER_CAP", cap, 1);
}

static struct vkr_image *h_image(uint32_t w, uint32_t h, uint32_t levels, uint32_t layers)
{
   const uint64_t id = next_id++;
   VkImage hd = (VkImage)(uintptr_t)id;
   VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
                              .format = FMT, .extent = { w, h, 1 }, .mipLevels = levels, .arrayLayers = layers,
                              .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = CA_SA };
   struct vn_command_vkCreateImage c = { .device = DEVH, .pCreateInfo = &info, .pImage = &hd };
   D->dispatch_vkCreateImage(D, &c);
   struct vkr_image *img = object(id);
   if (c.ret != VK_SUCCESS || !img)
      broken("vkCreateImage (levels, layers)");
   const VkMemoryRequirements req = requirements_of(img, NULL);
   if (bind_image_at(img, allocate(req.size, memory_type(req.memoryTypeBits))) != VK_SUCCESS)
      broken("vkBindImageMemory (levels, layers)");
   return img;
}

/* n clears of LEVELS levels (REMAINING when levels is 0) and every layer, quietly; stops
 * at a refusal */
static void h_clears(void *cmd, struct vkr_image *img, uint32_t n, uint32_t levels)
{
   const VkClearColorValue color = { { 0, 0, 0, 1 } };
   for (uint32_t i = 0; i < n && !ended(); i++) {
      const VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0,
                                              levels ? levels : VK_REMAINING_MIP_LEVELS, 0,
                                              VK_REMAINING_ARRAY_LAYERS };
      struct vn_command_vkCmdClearColorImage c = { .commandBuffer = (VkCommandBuffer)cmd, .image = (VkImage)img,
                                                   .imageLayout = VK_IMAGE_LAYOUT_GENERAL, .pColor = &color,
                                                   .rangeCount = 1, .pRanges = &range };
      D->dispatch_vkCmdClearColorImage(D, &c);
   }
   step("%u clears of %u levels recorded%s", n, levels, ended() ? " (the context ended)" : "");
}

static void h_passes(void *cmd, void *rp, void *fb, uint32_t n, bool rendering, void *v)
{
   for (uint32_t i = 0; i < n && !ended(); i++) {
      if (rendering) {
         VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                           .imageView = (VkImageView)v,
                                           .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                           .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                                           .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
         VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                                .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
         struct vn_command_vkCmdBeginRendering b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderingInfo = &ri };
         D->dispatch_vkCmdBeginRendering(D, &b);
         if (ended())
            break;
         struct vn_command_vkCmdEndRendering e = { .commandBuffer = (VkCommandBuffer)cmd };
         D->dispatch_vkCmdEndRendering(D, &e);
      } else {
         VkClearValue clear = { 0 };
         VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                      .renderPass = (VkRenderPass)rp, .framebuffer = (VkFramebuffer)fb,
                                      .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1,
                                      .pClearValues = &clear };
         struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderPassBegin = &bi,
                                                      .contents = VK_SUBPASS_CONTENTS_INLINE };
         D->dispatch_vkCmdBeginRenderPass(D, &b);
         if (ended())
            break;
         struct vn_command_vkCmdEndRenderPass e = { .commandBuffer = (VkCommandBuffer)cmd };
         D->dispatch_vkCmdEndRenderPass(D, &e);
      }
   }
   step("%u %s recorded%s", n, rendering ? "renderings" : "render passes", ended() ? " (the context ended)" : "");
}

static void h_fills(void *cmd, struct vkr_buffer *buf, uint32_t n)
{
   uint32_t i = 0;
   for (; i < n && !ended(); i++) {
      struct vn_command_vkCmdFillBuffer f = { .commandBuffer = (VkCommandBuffer)cmd, .dstBuffer = (VkBuffer)buf,
                                              .size = 256, .data = 7 };
      D->dispatch_vkCmdFillBuffer(D, &f);
   }
   step("%u fills recorded%s", i, ended() ? " (the context ended)" : "");
}

/* a real submit of the command buffers in one batch, and the driver's wait */
static int h_submit(void **cmds, uint32_t n)
{
   struct vkr_queue *q = device_queue();
   VkCommandBuffer hs[8];
   for (uint32_t i = 0; i < n; i++)
      hs[i] = (VkCommandBuffer)cmds[i];
   VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = n, .pCommandBuffers = hs };
   struct vn_command_vkQueueSubmit s = { .queue = (VkQueue)q, .submitCount = 1, .pSubmits = &si };
   step("vkQueueSubmit: one batch of %u command buffers", n);
   D->dispatch_vkQueueSubmit(D, &s);
   step("vkQueueSubmit = %d", s.ret);
   if (ended())
      return FATAL;
   q->device->proc_table.QueueWaitIdle(q->base.handle.queue);
   step("the queue is idle");
   return s.ret == VK_SUCCESS ? WORKS : ERROR;
}

static bool h_prefill(void)
{
   return !kosmickrisp && getenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS");
}

/* Metal passes per command buffer and per MoltenVK batch (virgl-venus-encoder-cap.patch) */
static int case_host_passes(const char *c)
{
   const bool tight = strstr(c, "-default") == NULL;
   /* the default cap with room to charge it (a pass charges 184 KB); else a cap of 1024 */
   if (tight)
      h_env("1024", "1024", "1024");
   else
      h_env("8192", "4096", NULL);
   setup(0);
   const uint32_t cap = tight ? 1024 : 16384;
   void *cmd = command_buffer();
   begin(cmd);
   if (IS("h-pass-clear-max-ok") || IS("h-pass-clear-over") || IS("h-pass-default-max-ok") ||
       IS("h-pass-default-over") || IS("h-pass-default-past-metal")) {
      const uint32_t n = IS("h-pass-default-past-metal") ? 100000 : strstr(c, "-over") ? cap + 1 : cap;
      h_clears(cmd, image(64, 64, 1, CA_SA), n, 1);
      return end(cmd);
   }
   if (IS("h-pass-levels-ok") || IS("h-pass-levels-over")) {
      /* 15 levels (REMAINING): 68 x 15 = 1020, 69 x 15 = 1035 */
      h_clears(cmd, h_image(16384, 1, 15, 1), IS("h-pass-levels-ok") ? 68 : 69, 0);
      return end(cmd);
   }
   if (IS("h-pass-layers-ok")) {
      /* one layered pass per clear: 1024 clears of 2048 layers */
      h_clears(cmd, h_image(64, 64, 1, 2048), cap, 1);
      return end(cmd);
   }
   if (IS("h-pass-render-passes-over") || IS("h-pass-renderings-over") || IS("h-pass-render-passes-ok")) {
      void *rp = render_pass(1, 1, 0, 0);
      void *v = view(image(64, 64, 1, CA_SA), 1);
      void *fb = framebuffer(rp, &v, 1, 64, 64, 1);
      if (!rp || !fb)
         broken("pass");
      h_passes(cmd, rp, fb, IS("h-pass-render-passes-ok") ? cap : cap + 1, IS("h-pass-renderings-over"), v);
      return end(cmd);
   }
   if (IS("h-pass-blits-over")) {
      struct vkr_image *a = image(64, 64, 1, CA_SA), *b = image(64, 64, 1, CA_SA);
      const VkImageSubresourceLayers l = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
      const VkImageBlit r[2] = { { l, { { 0, 0, 0 }, { 64, 64, 1 } }, l, { { 0, 0, 0 }, { 32, 32, 1 } } },
                                 { l, { { 0, 0, 0 }, { 64, 64, 1 } }, l, { { 0, 0, 0 }, { 16, 16, 1 } } } };
      /* 512 blits of 2 regions fit, the 513th does not */
      for (uint32_t i = 0; i < cap / 2 + 1 && !ended(); i++) {
         struct vn_command_vkCmdBlitImage bl = { .commandBuffer = (VkCommandBuffer)cmd, .srcImage = (VkImage)a,
                                                 .srcImageLayout = VK_IMAGE_LAYOUT_GENERAL, .dstImage = (VkImage)b,
                                                 .dstImageLayout = VK_IMAGE_LAYOUT_GENERAL, .regionCount = 2,
                                                 .pRegions = r, .filter = VK_FILTER_LINEAR };
         D->dispatch_vkCmdBlitImage(D, &bl);
      }
      return end(cmd);
   }
   if (IS("h-pass-split-barriers")) {
      /* by-region barriers inside one pass: KosmicKrisp splits a multisampled pass at each
       * (counted on KosmicKrisp, which vkr cannot tell apart from a 1x pass); MoltenVK does
       * not split */
      expect(kosmickrisp);
      void *rp = ms_pass();
      void *v[2] = { ms_view(VK_SAMPLE_COUNT_4_BIT), ms_view(VK_SAMPLE_COUNT_1_BIT) };
      void *fb = framebuffer(rp, v, 2, 64, 64, 1);
      VkClearValue clear[2] = { 0 };
      VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = (VkRenderPass)rp,
                                   .framebuffer = (VkFramebuffer)fb, .renderArea = { { 0, 0 }, { 64, 64 } },
                                   .clearValueCount = 2, .pClearValues = clear };
      struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = (VkCommandBuffer)cmd, .pRenderPassBegin = &bi,
                                                   .contents = VK_SUBPASS_CONTENTS_INLINE };
      D->dispatch_vkCmdBeginRenderPass(D, &b);
      for (uint32_t i = 0; i < cap && !ended(); i++) {
         VkMemoryBarrier2 mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
                                 .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                                 .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                                 .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                                 .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT };
         VkDependencyInfo dep = { .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                                  .dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT, .memoryBarrierCount = 1,
                                  .pMemoryBarriers = &mb };
         struct vn_command_vkCmdPipelineBarrier2 pb = { .commandBuffer = (VkCommandBuffer)cmd, .pDependencyInfo = &dep };
         D->dispatch_vkCmdPipelineBarrier2(D, &pb);
      }
      end_pass(cmd);
      return end(cmd);
   }
   if (IS("h-pass-secondary-ok") || IS("h-pass-secondary-over")) {
      /* two secondaries of 500 clears (ok: 1000 in the primary) or 600 (1200) */
      struct vkr_image *img = image(64, 64, 1, CA_SA);
      VkCommandBuffer s[2];
      for (int k = 0; k < 2; k++) {
         void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
         if (begin_secondary(sec, NULL) != VK_SUCCESS)
            broken("secondary begin");
         h_clears(sec, img, IS("h-pass-secondary-ok") ? 500 : 600, 1);
         const int r = end(sec);
         if (r != WORKS)
            return r;
         s[k] = (VkCommandBuffer)sec;
      }
      struct vn_command_vkCmdExecuteCommands e = { .commandBuffer = (VkCommandBuffer)cmd, .commandBufferCount = 2,
                                                   .pCommandBuffers = s };
      step("vkCmdExecuteCommands of the two secondaries");
      D->dispatch_vkCmdExecuteCommands(D, &e);
      return end(cmd);
   }
   if (IS("h-pass-batch-ok") || IS("h-pass-batch-over")) {
      /* a real submit: one batch of 2 x 1000 (ok: 2000 <= 2 x 1024) or 3 x 700 (2100) clears;
       * MoltenVK encodes a batch into one Metal command buffer, KosmicKrisp has one each */
      const bool over = IS("h-pass-batch-over");
      if (h_prefill())
         return SKIP;
      expect(over && !kosmickrisp);
      struct vkr_image *img = image(64, 64, 1, CA_SA);
      void *cmds[3] = { cmd, command_buffer(), command_buffer() };
      const uint32_t n = over ? 3 : 2;
      for (uint32_t i = 0; i < n; i++) {
         if (i)
            begin(cmds[i]);
         h_clears(cmds[i], img, over ? 700 : 1000, 1);
         const int r = end(cmds[i]);
         if (r != WORKS)
            return r;
      }
      return h_submit(cmds, n);
   }
   return BROKEN;
}

/* the draw-split cases' shaders (glslc --target-env=vulkan1.0 -O; sources in the comments): a
 * vertex shader with no inputs, its flat-output twin, a plain and a flat fragment shader, a
 * tessellation control and evaluation pair */
/* #version 450 void main() { gl_Position = vec4(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1), 0.0, 1.0); } */
static const uint32_t spv_split_plain_vert[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x0000001e, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0007000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000d, 0x00000011, 0x00030047,
   0x0000000b, 0x00000002, 0x00050048, 0x0000000b, 0x00000000, 0x0000000b, 0x00000000, 0x00050048,
   0x0000000b, 0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x0000000b, 0x00000002, 0x0000000b,
   0x00000003, 0x00050048, 0x0000000b, 0x00000003, 0x0000000b, 0x00000004, 0x00040047, 0x00000011,
   0x0000000b, 0x0000002a, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
   0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040015, 0x00000008,
   0x00000020, 0x00000000, 0x0004002b, 0x00000008, 0x00000009, 0x00000001, 0x0004001c, 0x0000000a,
   0x00000006, 0x00000009, 0x0006001e, 0x0000000b, 0x00000007, 0x00000006, 0x0000000a, 0x0000000a,
   0x00040020, 0x0000000c, 0x00000003, 0x0000000b, 0x0004003b, 0x0000000c, 0x0000000d, 0x00000003,
   0x00040015, 0x0000000e, 0x00000020, 0x00000001, 0x0004002b, 0x0000000e, 0x0000000f, 0x00000000,
   0x00040020, 0x00000010, 0x00000001, 0x0000000e, 0x0004003b, 0x00000010, 0x00000011, 0x00000001,
   0x0004002b, 0x0000000e, 0x00000013, 0x00000001, 0x0004002b, 0x00000006, 0x00000019, 0x00000000,
   0x0004002b, 0x00000006, 0x0000001a, 0x3f800000, 0x00040020, 0x0000001c, 0x00000003, 0x00000007,
   0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003d,
   0x0000000e, 0x00000012, 0x00000011, 0x000500c7, 0x0000000e, 0x00000014, 0x00000012, 0x00000013,
   0x0004006f, 0x00000006, 0x00000015, 0x00000014, 0x000500c3, 0x0000000e, 0x00000017, 0x00000012,
   0x00000013, 0x0004006f, 0x00000006, 0x00000018, 0x00000017, 0x00070050, 0x00000007, 0x0000001b,
   0x00000015, 0x00000018, 0x00000019, 0x0000001a, 0x00050041, 0x0000001c, 0x0000001d, 0x0000000d,
   0x0000000f, 0x0003003e, 0x0000001d, 0x0000001b, 0x000100fd, 0x00010038,
};
/* #version 450 layout(location = 0) flat out int v; void main() { v = gl_VertexIndex; gl_Position = vec4(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1), 0.0, 1.0); } */
static const uint32_t spv_split_flat_vert[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000021, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0008000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x00000008, 0x0000000a, 0x00000013,
   0x00030047, 0x00000008, 0x0000000e, 0x00040047, 0x00000008, 0x0000001e, 0x00000000, 0x00040047,
   0x0000000a, 0x0000000b, 0x0000002a, 0x00030047, 0x00000011, 0x00000002, 0x00050048, 0x00000011,
   0x00000000, 0x0000000b, 0x00000000, 0x00050048, 0x00000011, 0x00000001, 0x0000000b, 0x00000001,
   0x00050048, 0x00000011, 0x00000002, 0x0000000b, 0x00000003, 0x00050048, 0x00000011, 0x00000003,
   0x0000000b, 0x00000004, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00040015,
   0x00000006, 0x00000020, 0x00000001, 0x00040020, 0x00000007, 0x00000003, 0x00000006, 0x0004003b,
   0x00000007, 0x00000008, 0x00000003, 0x00040020, 0x00000009, 0x00000001, 0x00000006, 0x0004003b,
   0x00000009, 0x0000000a, 0x00000001, 0x00030016, 0x0000000c, 0x00000020, 0x00040017, 0x0000000d,
   0x0000000c, 0x00000004, 0x00040015, 0x0000000e, 0x00000020, 0x00000000, 0x0004002b, 0x0000000e,
   0x0000000f, 0x00000001, 0x0004001c, 0x00000010, 0x0000000c, 0x0000000f, 0x0006001e, 0x00000011,
   0x0000000d, 0x0000000c, 0x00000010, 0x00000010, 0x00040020, 0x00000012, 0x00000003, 0x00000011,
   0x0004003b, 0x00000012, 0x00000013, 0x00000003, 0x0004002b, 0x00000006, 0x00000014, 0x00000000,
   0x0004002b, 0x00000006, 0x00000016, 0x00000001, 0x0004002b, 0x0000000c, 0x0000001c, 0x00000000,
   0x0004002b, 0x0000000c, 0x0000001d, 0x3f800000, 0x00040020, 0x0000001f, 0x00000003, 0x0000000d,
   0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003d,
   0x00000006, 0x0000000b, 0x0000000a, 0x0003003e, 0x00000008, 0x0000000b, 0x000500c7, 0x00000006,
   0x00000017, 0x0000000b, 0x00000016, 0x0004006f, 0x0000000c, 0x00000018, 0x00000017, 0x000500c3,
   0x00000006, 0x0000001a, 0x0000000b, 0x00000016, 0x0004006f, 0x0000000c, 0x0000001b, 0x0000001a,
   0x00070050, 0x0000000d, 0x0000001e, 0x00000018, 0x0000001b, 0x0000001c, 0x0000001d, 0x00050041,
   0x0000001f, 0x00000020, 0x00000013, 0x00000014, 0x0003003e, 0x00000020, 0x0000001e, 0x000100fd,
   0x00010038,
};
/* #version 450 layout(location = 0) out vec4 c; void main() { c = vec4(0.0, 1.0, 0.0, 1.0); } */
static const uint32_t spv_split_plain_frag[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x0000000d, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0006000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x00000009, 0x00030010, 0x00000004,
   0x00000007, 0x00040047, 0x00000009, 0x0000001e, 0x00000000, 0x00020013, 0x00000002, 0x00030021,
   0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
   0x00000004, 0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003b, 0x00000008, 0x00000009,
   0x00000003, 0x0004002b, 0x00000006, 0x0000000a, 0x00000000, 0x0004002b, 0x00000006, 0x0000000b,
   0x3f800000, 0x0007002c, 0x00000007, 0x0000000c, 0x0000000a, 0x0000000b, 0x0000000a, 0x0000000b,
   0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0003003e,
   0x00000009, 0x0000000c, 0x000100fd, 0x00010038,
};
/* #version 450 layout(location = 0) flat in int v; layout(location = 0) out vec4 c; void main() { c = vec4(float(v)); } */
static const uint32_t spv_split_flat_frag[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000010, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0007000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x00000009, 0x0000000c, 0x00030010,
   0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001e, 0x00000000, 0x00030047, 0x0000000c,
   0x0000000e, 0x00040047, 0x0000000c, 0x0000001e, 0x00000000, 0x00020013, 0x00000002, 0x00030021,
   0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006,
   0x00000004, 0x00040020, 0x00000008, 0x00000003, 0x00000007, 0x0004003b, 0x00000008, 0x00000009,
   0x00000003, 0x00040015, 0x0000000a, 0x00000020, 0x00000001, 0x00040020, 0x0000000b, 0x00000001,
   0x0000000a, 0x0004003b, 0x0000000b, 0x0000000c, 0x00000001, 0x00050036, 0x00000002, 0x00000004,
   0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003d, 0x0000000a, 0x0000000d, 0x0000000c,
   0x0004006f, 0x00000006, 0x0000000e, 0x0000000d, 0x00070050, 0x00000007, 0x0000000f, 0x0000000e,
   0x0000000e, 0x0000000e, 0x0000000e, 0x0003003e, 0x00000009, 0x0000000f, 0x000100fd, 0x00010038,
};
/* #version 450 layout(vertices = 3) out; void main() { gl_out[gl_InvocationID].gl_Position = gl_in[gl_InvocationID].gl_Position; gl_TessLevelOuter[0] = 1.0; gl_TessLevelOuter[1] = 1.0; gl_TessLevelOuter[2] = 1.0; gl_TessLevelInner[0] = 1.0; } */
static const uint32_t spv_split_t_tesc[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000030, 0x00000000, 0x00020011, 0x00000003, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x000a000f, 0x00000001, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000f, 0x00000012, 0x00000019,
   0x00000023, 0x0000002e, 0x00040010, 0x00000004, 0x0000001a, 0x00000003, 0x00030047, 0x0000000b,
   0x00000002, 0x00050048, 0x0000000b, 0x00000000, 0x0000000b, 0x00000000, 0x00050048, 0x0000000b,
   0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x0000000b, 0x00000002, 0x0000000b, 0x00000003,
   0x00050048, 0x0000000b, 0x00000003, 0x0000000b, 0x00000004, 0x00040047, 0x00000012, 0x0000000b,
   0x00000008, 0x00030047, 0x00000015, 0x00000002, 0x00050048, 0x00000015, 0x00000000, 0x0000000b,
   0x00000000, 0x00050048, 0x00000015, 0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x00000015,
   0x00000002, 0x0000000b, 0x00000003, 0x00050048, 0x00000015, 0x00000003, 0x0000000b, 0x00000004,
   0x00040047, 0x00000023, 0x0000000b, 0x0000000b, 0x00030047, 0x00000023, 0x0000000f, 0x00040047,
   0x0000002e, 0x0000000b, 0x0000000c, 0x00030047, 0x0000002e, 0x0000000f, 0x00020013, 0x00000002,
   0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007,
   0x00000006, 0x00000004, 0x00040015, 0x00000008, 0x00000020, 0x00000000, 0x0004002b, 0x00000008,
   0x00000009, 0x00000001, 0x0004001c, 0x0000000a, 0x00000006, 0x00000009, 0x0006001e, 0x0000000b,
   0x00000007, 0x00000006, 0x0000000a, 0x0000000a, 0x0004002b, 0x00000008, 0x0000000c, 0x00000003,
   0x0004001c, 0x0000000d, 0x0000000b, 0x0000000c, 0x00040020, 0x0000000e, 0x00000003, 0x0000000d,
   0x0004003b, 0x0000000e, 0x0000000f, 0x00000003, 0x00040015, 0x00000010, 0x00000020, 0x00000001,
   0x00040020, 0x00000011, 0x00000001, 0x00000010, 0x0004003b, 0x00000011, 0x00000012, 0x00000001,
   0x0004002b, 0x00000010, 0x00000014, 0x00000000, 0x0006001e, 0x00000015, 0x00000007, 0x00000006,
   0x0000000a, 0x0000000a, 0x0004002b, 0x00000008, 0x00000016, 0x00000020, 0x0004001c, 0x00000017,
   0x00000015, 0x00000016, 0x00040020, 0x00000018, 0x00000001, 0x00000017, 0x0004003b, 0x00000018,
   0x00000019, 0x00000001, 0x00040020, 0x0000001b, 0x00000001, 0x00000007, 0x00040020, 0x0000001e,
   0x00000003, 0x00000007, 0x0004002b, 0x00000008, 0x00000020, 0x00000004, 0x0004001c, 0x00000021,
   0x00000006, 0x00000020, 0x00040020, 0x00000022, 0x00000003, 0x00000021, 0x0004003b, 0x00000022,
   0x00000023, 0x00000003, 0x0004002b, 0x00000006, 0x00000024, 0x3f800000, 0x00040020, 0x00000025,
   0x00000003, 0x00000006, 0x0004002b, 0x00000010, 0x00000027, 0x00000001, 0x0004002b, 0x00000010,
   0x00000029, 0x00000002, 0x0004002b, 0x00000008, 0x0000002b, 0x00000002, 0x0004001c, 0x0000002c,
   0x00000006, 0x0000002b, 0x00040020, 0x0000002d, 0x00000003, 0x0000002c, 0x0004003b, 0x0000002d,
   0x0000002e, 0x00000003, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8,
   0x00000005, 0x0004003d, 0x00000010, 0x00000013, 0x00000012, 0x00060041, 0x0000001b, 0x0000001c,
   0x00000019, 0x00000013, 0x00000014, 0x0004003d, 0x00000007, 0x0000001d, 0x0000001c, 0x00060041,
   0x0000001e, 0x0000001f, 0x0000000f, 0x00000013, 0x00000014, 0x0003003e, 0x0000001f, 0x0000001d,
   0x00050041, 0x00000025, 0x00000026, 0x00000023, 0x00000014, 0x0003003e, 0x00000026, 0x00000024,
   0x00050041, 0x00000025, 0x00000028, 0x00000023, 0x00000027, 0x0003003e, 0x00000028, 0x00000024,
   0x00050041, 0x00000025, 0x0000002a, 0x00000023, 0x00000029, 0x0003003e, 0x0000002a, 0x00000024,
   0x00050041, 0x00000025, 0x0000002f, 0x0000002e, 0x00000014, 0x0003003e, 0x0000002f, 0x00000024,
   0x000100fd, 0x00010038,
};
/* #version 450 layout(triangles) in; void main() { gl_Position = gl_TessCoord.x * gl_in[0].gl_Position + gl_TessCoord.y * gl_in[1].gl_Position + gl_TessCoord.z * gl_in[2].gl_Position; } */
static const uint32_t spv_split_t_tese[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000031, 0x00000000, 0x00020011, 0x00000003, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0008000f, 0x00000002, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000d, 0x00000012, 0x0000001b,
   0x00030010, 0x00000004, 0x00000016, 0x00030010, 0x00000004, 0x00000001, 0x00030010, 0x00000004,
   0x00000005, 0x00030047, 0x0000000b, 0x00000002, 0x00050048, 0x0000000b, 0x00000000, 0x0000000b,
   0x00000000, 0x00050048, 0x0000000b, 0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x0000000b,
   0x00000002, 0x0000000b, 0x00000003, 0x00050048, 0x0000000b, 0x00000003, 0x0000000b, 0x00000004,
   0x00040047, 0x00000012, 0x0000000b, 0x0000000d, 0x00030047, 0x00000017, 0x00000002, 0x00050048,
   0x00000017, 0x00000000, 0x0000000b, 0x00000000, 0x00050048, 0x00000017, 0x00000001, 0x0000000b,
   0x00000001, 0x00050048, 0x00000017, 0x00000002, 0x0000000b, 0x00000003, 0x00050048, 0x00000017,
   0x00000003, 0x0000000b, 0x00000004, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
   0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040015,
   0x00000008, 0x00000020, 0x00000000, 0x0004002b, 0x00000008, 0x00000009, 0x00000001, 0x0004001c,
   0x0000000a, 0x00000006, 0x00000009, 0x0006001e, 0x0000000b, 0x00000007, 0x00000006, 0x0000000a,
   0x0000000a, 0x00040020, 0x0000000c, 0x00000003, 0x0000000b, 0x0004003b, 0x0000000c, 0x0000000d,
   0x00000003, 0x00040015, 0x0000000e, 0x00000020, 0x00000001, 0x0004002b, 0x0000000e, 0x0000000f,
   0x00000000, 0x00040017, 0x00000010, 0x00000006, 0x00000003, 0x00040020, 0x00000011, 0x00000001,
   0x00000010, 0x0004003b, 0x00000011, 0x00000012, 0x00000001, 0x0004002b, 0x00000008, 0x00000013,
   0x00000000, 0x00040020, 0x00000014, 0x00000001, 0x00000006, 0x0006001e, 0x00000017, 0x00000007,
   0x00000006, 0x0000000a, 0x0000000a, 0x0004002b, 0x00000008, 0x00000018, 0x00000020, 0x0004001c,
   0x00000019, 0x00000017, 0x00000018, 0x00040020, 0x0000001a, 0x00000001, 0x00000019, 0x0004003b,
   0x0000001a, 0x0000001b, 0x00000001, 0x00040020, 0x0000001c, 0x00000001, 0x00000007, 0x0004002b,
   0x0000000e, 0x00000022, 0x00000001, 0x0004002b, 0x00000008, 0x00000027, 0x00000002, 0x0004002b,
   0x0000000e, 0x0000002a, 0x00000002, 0x00040020, 0x0000002f, 0x00000003, 0x00000007, 0x00050036,
   0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x00050041, 0x00000014,
   0x00000015, 0x00000012, 0x00000013, 0x0004003d, 0x00000006, 0x00000016, 0x00000015, 0x00060041,
   0x0000001c, 0x0000001d, 0x0000001b, 0x0000000f, 0x0000000f, 0x0004003d, 0x00000007, 0x0000001e,
   0x0000001d, 0x0005008e, 0x00000007, 0x0000001f, 0x0000001e, 0x00000016, 0x00050041, 0x00000014,
   0x00000020, 0x00000012, 0x00000009, 0x0004003d, 0x00000006, 0x00000021, 0x00000020, 0x00060041,
   0x0000001c, 0x00000023, 0x0000001b, 0x00000022, 0x0000000f, 0x0004003d, 0x00000007, 0x00000024,
   0x00000023, 0x0005008e, 0x00000007, 0x00000025, 0x00000024, 0x00000021, 0x00050081, 0x00000007,
   0x00000026, 0x0000001f, 0x00000025, 0x00050041, 0x00000014, 0x00000028, 0x00000012, 0x00000027,
   0x0004003d, 0x00000006, 0x00000029, 0x00000028, 0x00060041, 0x0000001c, 0x0000002b, 0x0000001b,
   0x0000002a, 0x0000000f, 0x0004003d, 0x00000007, 0x0000002c, 0x0000002b, 0x0005008e, 0x00000007,
   0x0000002d, 0x0000002c, 0x00000029, 0x00050081, 0x00000007, 0x0000002e, 0x00000026, 0x0000002d,
   0x00050041, 0x0000002f, 0x00000030, 0x0000000d, 0x0000000f, 0x0003003e, 0x00000030, 0x0000002e,
   0x000100fd, 0x00010038,
};

/* ---- draws and state changes that split a Metal pass (virgl-venus-encoder-cap.patch) ---- */
static struct {
   bool u8, last, cond, sl, lr, list_restart, robust2, tess;
} split;

/* a second device with what the draw-split cases need (robust: robustBufferAccess and
 * robustBufferAccess2 on); it replaces the case's device */
static void split_device(bool robust)
{
   VkPhysicalDevice host = pdev->base.handle.physical_device;
   VkPhysicalDeviceIndexTypeUint8FeaturesKHR u8 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_INDEX_TYPE_UINT8_FEATURES_KHR };
   VkPhysicalDeviceProvokingVertexFeaturesEXT pv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT };
   VkPhysicalDeviceConditionalRenderingFeaturesEXT cr = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CONDITIONAL_RENDERING_FEATURES_EXT };
   VkPhysicalDeviceDynamicRenderingLocalReadFeaturesKHR lr = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES_KHR };
   VkPhysicalDevicePrimitiveTopologyListRestartFeaturesEXT lrs = {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRIMITIVE_TOPOLOGY_LIST_RESTART_FEATURES_EXT };
   VkPhysicalDeviceRobustness2FeaturesEXT r2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT };
   VkPhysicalDeviceVulkan13Features f13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
   VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f13 };
   const char *exts[8];
   uint32_t n_ext = 0;
   void **tail = &f13.pNext;
#define SPLIT_EXT(name, s)                                                                \
   if (lists(name)) {                                                                     \
      *tail = &(s);                                                                       \
      tail = &(s).pNext;                                                                  \
      exts[n_ext++] = name;                                                               \
   }
   SPLIT_EXT(VK_KHR_INDEX_TYPE_UINT8_EXTENSION_NAME, u8)
   else SPLIT_EXT(VK_EXT_INDEX_TYPE_UINT8_EXTENSION_NAME, u8)
   SPLIT_EXT(VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME, pv)
   SPLIT_EXT(VK_EXT_CONDITIONAL_RENDERING_EXTENSION_NAME, cr)
   SPLIT_EXT(VK_KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME, lr)
   SPLIT_EXT(VK_EXT_PRIMITIVE_TOPOLOGY_LIST_RESTART_EXTENSION_NAME, lrs)
   SPLIT_EXT(VK_EXT_ROBUSTNESS_2_EXTENSION_NAME, r2)
#undef SPLIT_EXT
   split.sl = lists(VK_EXT_SAMPLE_LOCATIONS_EXTENSION_NAME);
   if (split.sl)
      exts[n_ext++] = VK_EXT_SAMPLE_LOCATIONS_EXTENSION_NAME;
   pdev->proc_table.GetPhysicalDeviceFeatures2(host, &f2);
   /* only what the cases use */
   pv.transformFeedbackPreservesProvokingVertex = VK_FALSE;
   cr.inheritedConditionalRendering = VK_FALSE;
   lrs.primitiveTopologyPatchListRestart = VK_FALSE;
   r2.robustImageAccess2 = VK_FALSE;
   r2.robustBufferAccess2 = robust && f2.features.robustBufferAccess && r2.robustBufferAccess2;
   split.u8 = u8.indexTypeUint8, split.last = pv.provokingVertexLast, split.cond = cr.conditionalRendering;
   split.lr = lr.dynamicRenderingLocalRead, split.list_restart = lrs.primitiveTopologyListRestart;
   split.robust2 = r2.robustBufferAccess2, split.tess = f2.features.tessellationShader;
   VkPhysicalDeviceVulkan13Features e13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
                                            .pNext = f13.pNext, .dynamicRendering = f13.dynamicRendering,
                                            .synchronization2 = f13.synchronization2 };
   VkPhysicalDeviceFeatures2 e2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &e13 };
   e2.features.tessellationShader = f2.features.tessellationShader;
   e2.features.robustBufferAccess = split.robust2;
   const float priority = 1;
   const VkDeviceQueueCreateInfo q = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueCount = 1,
                                       .pQueuePriorities = &priority };
   VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .pNext = &e2,
                              .queueCreateInfoCount = 1, .pQueueCreateInfos = &q,
                              .enabledExtensionCount = n_ext, .ppEnabledExtensionNames = exts };
   const uint64_t device_object = next_id++;
   VkDevice device_id = (VkDevice)(uintptr_t)device_object;
   struct vn_command_vkCreateDevice cd = { .physicalDevice = (VkPhysicalDevice)pdev, .pCreateInfo = &dci,
                                           .pDevice = &device_id };
   D->dispatch_vkCreateDevice(D, &cd);
   if (cd.ret != VK_SUCCESS || !object(device_object))
      broken("vkCreateDevice (draw splits)");
   dev = object(device_object);
   step("draw-split device: u8 %d, last %d, conditional %d, sample locations %d, local read %d, list "
        "restart %d, robust2 %d, tessellation %d",
        split.u8, split.last, split.cond, split.sl, split.lr, split.list_restart, split.robust2, split.tess);
}

struct split_pipe {
   VkPrimitiveTopology topology;
   bool flat, tess, last, restart_dynamic, sl, rendering;
};

static void *split_pipeline(void *layout, void *rp, const struct split_pipe *o)
{
   void *vs = o->flat ? shader(spv_split_flat_vert, sizeof(spv_split_flat_vert))
                      : shader(spv_split_plain_vert, sizeof(spv_split_plain_vert));
   void *fs = o->flat ? shader(spv_split_flat_frag, sizeof(spv_split_flat_frag))
                      : shader(spv_split_plain_frag, sizeof(spv_split_plain_frag));
   void *tc = o->tess ? shader(spv_split_t_tesc, sizeof(spv_split_t_tesc)) : NULL;
   void *te = o->tess ? shader(spv_split_t_tese, sizeof(spv_split_t_tese)) : NULL;
   if (!vs || !fs || (o->tess && (!tc || !te)))
      broken("draw-split shaders");
   VkPipelineShaderStageCreateInfo st[4] = {
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT,
        .module = (VkShaderModule)vs, .pName = "main" },
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = (VkShaderModule)fs, .pName = "main" },
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT,
        .module = (VkShaderModule)tc, .pName = "main" },
      { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT, .module = (VkShaderModule)te, .pName = "main" } };
   VkPipelineVertexInputStateCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
   VkPipelineInputAssemblyStateCreateInfo ia = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                                                 .topology = o->tess ? VK_PRIMITIVE_TOPOLOGY_PATCH_LIST : o->topology };
   VkPipelineTessellationStateCreateInfo ts = { .sType = VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO,
                                                .patchControlPoints = 3 };
   VkViewport vp0 = { 0, 0, 64, 64, 0, 1 };
   VkRect2D sc0 = { { 0, 0 }, { 64, 64 } };
   VkPipelineViewportStateCreateInfo vp = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                                            .viewportCount = 1, .pViewports = &vp0, .scissorCount = 1,
                                            .pScissors = &sc0 };
   VkPipelineRasterizationProvokingVertexStateCreateInfoEXT pvs = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT,
      .provokingVertexMode = VK_PROVOKING_VERTEX_MODE_LAST_VERTEX_EXT };
   VkPipelineRasterizationStateCreateInfo rs = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                                                 .pNext = o->last ? &pvs : NULL, .polygonMode = VK_POLYGON_MODE_FILL,
                                                 .lineWidth = 1 };
   VkSampleLocationsInfoEXT sli = valid_sample_locations();
   VkPipelineSampleLocationsStateCreateInfoEXT sls = {
      .sType = VK_STRUCTURE_TYPE_PIPELINE_SAMPLE_LOCATIONS_STATE_CREATE_INFO_EXT, .sampleLocationsEnable = VK_TRUE,
      .sampleLocationsInfo = sli };
   VkPipelineMultisampleStateCreateInfo ms = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                                               .pNext = o->sl ? &sls : NULL,
                                               .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
   VkPipelineColorBlendAttachmentState cba = { .colorWriteMask = 0xf };
   VkPipelineColorBlendStateCreateInfo cb = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                                              .attachmentCount = 1, .pAttachments = &cba };
   VkDynamicState dyn[2];
   uint32_t nd = 0;
   if (o->restart_dynamic)
      dyn[nd++] = VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE;
   if (o->sl)
      dyn[nd++] = VK_DYNAMIC_STATE_SAMPLE_LOCATIONS_EXT;
   VkPipelineDynamicStateCreateInfo ds = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
                                           .dynamicStateCount = nd, .pDynamicStates = dyn };
   VkFormat fmt = FMT;
   VkPipelineRenderingCreateInfo ri = { .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
                                        .colorAttachmentCount = 1, .pColorAttachmentFormats = &fmt };
   const uint64_t id = next_id++;
   VkPipeline h = (VkPipeline)(uintptr_t)id;
   VkGraphicsPipelineCreateInfo info = {
      .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = o->rendering ? &ri : NULL,
      .stageCount = o->tess ? 4 : 2, .pStages = st, .pVertexInputState = &vi, .pInputAssemblyState = &ia,
      .pTessellationState = o->tess ? &ts : NULL, .pViewportState = &vp, .pRasterizationState = &rs,
      .pMultisampleState = &ms, .pColorBlendState = &cb, .pDynamicState = nd ? &ds : NULL,
      .layout = (VkPipelineLayout)layout, .renderPass = o->rendering ? NULL : (VkRenderPass)rp };
   struct vn_command_vkCreateGraphicsPipelines c = { .device = DEVH, .createInfoCount = 1, .pCreateInfos = &info,
                                                     .pPipelines = &h };
   step("vkCreateGraphicsPipelines (draw split): topology %d, flat %d, tess %d, last %d", ia.topology, o->flat,
        o->tess, o->last);
   D->dispatch_vkCreateGraphicsPipelines(D, &c);
   if (c.ret != VK_SUCCESS || !object(id))
      broken("draw-split pipeline");
   return object(id);
}

/* h-pass-draw-KIND: a pass and as many draws of the kind as the cap (1024) in one command
 * buffer: the draws that split the pass on the driver (the M1 probes,
 * work/v624-hostmem/fix) take it past the cap, the others fit. KosmicKrisp unrolls or
 * predicates in a compute pass first (fan, u8, strip16: 16-bit strips with restart off,
 * list-restart, flat-last: flat inputs with the last vertex provoking, pred, robust-indirect:
 * counted on any macOS); on both drivers each tessellated draw and each sample-location or
 * attachment-location change in a pass splits. Fit on both: list16, strip16-restart,
 * strip32, flat-first, robust-plain. h-pass-3d-*: a clear of a 3D image is one pass,
 * whatever its depth. */
static int case_host_draws(const char *c)
{
   h_env("1024", "1024", "1024");
   setup(0);
   const uint32_t cap = 1024;
   if (IS("h-pass-3d-ok") || IS("h-pass-3d-over")) {
      /* a 64 x 64 x 256 3D image, one level: 1024 clears fit, 1025 do not (the M1: 16384
       * clears of a 2048-deep one recorded, 6072 B each) */
      const uint64_t id = next_id++;
      VkImage hd = (VkImage)(uintptr_t)id;
      VkImageCreateInfo info = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_3D,
                                 .format = FMT, .extent = { 64, 64, 256 }, .mipLevels = 1, .arrayLayers = 1,
                                 .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                                 .usage = CA_SA };
      struct vn_command_vkCreateImage ci = { .device = DEVH, .pCreateInfo = &info, .pImage = &hd };
      D->dispatch_vkCreateImage(D, &ci);
      struct vkr_image *img = object(id);
      if (ci.ret != VK_SUCCESS || !img)
         broken("vkCreateImage (3D)");
      const VkMemoryRequirements req = requirements_of(img, NULL);
      if (bind_image_at(img, allocate(req.size, memory_type(req.memoryTypeBits))) != VK_SUCCESS)
         broken("bind (3D)");
      void *cmd = command_buffer();
      begin(cmd);
      h_clears(cmd, img, IS("h-pass-3d-ok") ? cap : cap + 1, 1);
      return end(cmd);
   }
#define K(x) IS("h-pass-draw-" x)
   const bool robust = K("robust-indirect") || K("robust-plain");
   split_device(robust);
   if (((K("u8")) && !split.u8) || (K("flat-last") && !split.last) || (K("pred") && !split.cond) ||
       ((K("sample-locations")) && !split.sl) || (K("attachment-locations") && !split.lr) ||
       (K("list-restart") && !split.list_restart) || (K("tess") && !split.tess) || (robust && !split.robust2)) {
      printf("skip: the device lacks the feature\n");
      return SKIP;
   }
   const bool counted = K("tess") || K("sample-locations") || K("attachment-locations") ||
                        (kosmickrisp && (K("fan") || K("u8") || K("strip16") || K("list-restart") ||
                                         K("flat-last") || K("pred") || K("robust-indirect")));
   expect(counted);
   struct world w = { 0 };
   make_world(&w, false);
   struct vkr_buffer *ib = buffer(1u << 16);
   struct split_pipe o = { .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
   bool indexed = false, indirect = false;
   VkIndexType itype = VK_INDEX_TYPE_UINT16;
   if (K("fan"))
      o.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN;
   else if (K("u8"))
      indexed = true, itype = VK_INDEX_TYPE_UINT8_KHR;
   else if (K("strip16") || K("strip16-restart") || K("strip32"))
      indexed = true, o.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP, o.restart_dynamic = true,
      itype = K("strip32") ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16;
   else if (K("list-restart") || K("list16"))
      indexed = true, o.restart_dynamic = true;
   else if (K("flat-last"))
      o.flat = true, o.last = true;
   else if (K("flat-first"))
      o.flat = true;
   else if (K("robust-indirect"))
      indexed = true, indirect = true;
   else if (K("robust-plain"))
      indexed = true;
   else if (K("tess"))
      o.tess = true;
   else if (K("sample-locations"))
      o.sl = true;
   else if (K("attachment-locations"))
      o.rendering = true;
   void *pipe = split_pipeline(w.layout, w.rp, &o);
   begin(w.cmd);
   if (o.rendering) {
      VkRenderingAttachmentInfo att = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                                        .imageView = (VkImageView)w.iv,
                                        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                                        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE };
      VkRenderingInfo ri = { .sType = VK_STRUCTURE_TYPE_RENDERING_INFO, .renderArea = { { 0, 0 }, { 64, 64 } },
                             .layerCount = 1, .colorAttachmentCount = 1, .pColorAttachments = &att };
      struct vn_command_vkCmdBeginRendering br = { .commandBuffer = (VkCommandBuffer)w.cmd, .pRenderingInfo = &ri };
      D->dispatch_vkCmdBeginRendering(D, &br);
   } else {
      begin_pass(w.cmd, w.rp, w.fb, 64, 64);
   }
   bind_pipeline(w.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
   if (indexed) {
      struct vn_command_vkCmdBindIndexBuffer b = { .commandBuffer = (VkCommandBuffer)w.cmd, .buffer = (VkBuffer)ib,
                                                   .indexType = itype };
      D->dispatch_vkCmdBindIndexBuffer(D, &b);
   }
   if (o.restart_dynamic) {
      struct vn_command_vkCmdSetPrimitiveRestartEnable pr = {
         .commandBuffer = (VkCommandBuffer)w.cmd, .primitiveRestartEnable = K("strip16-restart") || K("list-restart") };
      D->dispatch_vkCmdSetPrimitiveRestartEnable(D, &pr);
   }
   if (K("pred")) {
      VkConditionalRenderingBeginInfoEXT cri = { .sType = VK_STRUCTURE_TYPE_CONDITIONAL_RENDERING_BEGIN_INFO_EXT,
                                                 .buffer = (VkBuffer)w.buf };
      struct vn_command_vkCmdBeginConditionalRenderingEXT bc = { .commandBuffer = (VkCommandBuffer)w.cmd,
                                                                 .pConditionalRenderingBegin = &cri };
      D->dispatch_vkCmdBeginConditionalRenderingEXT(D, &bc);
   }
   uint32_t i = 0;
   for (; i < cap && !ended(); i++) {
      if (K("sample-locations")) {
         VkSampleLocationsInfoEXT sli = valid_sample_locations();
         VkSampleLocationEXT l[64];
         for (uint32_t k = 0; k < sli.sampleLocationsCount && k < 64; k++)
            l[k] = (VkSampleLocationEXT){ (i & 1) ? 0.25f : 0.75f, 0.5f };
         sli.pSampleLocations = l;
         struct vn_command_vkCmdSetSampleLocationsEXT s = { .commandBuffer = (VkCommandBuffer)w.cmd,
                                                            .pSampleLocationsInfo = &sli };
         D->dispatch_vkCmdSetSampleLocationsEXT(D, &s);
      } else if (K("attachment-locations")) {
         uint32_t locs[1] = { (i & 1) ? VK_ATTACHMENT_UNUSED : 0 };
         VkRenderingAttachmentLocationInfoKHR li = { .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_LOCATION_INFO_KHR,
                                                     .colorAttachmentCount = 1, .pColorAttachmentLocations = locs };
         struct vn_command_vkCmdSetRenderingAttachmentLocations s = { .commandBuffer = (VkCommandBuffer)w.cmd,
                                                                      .pLocationInfo = &li };
         D->dispatch_vkCmdSetRenderingAttachmentLocations(D, &s);
      }
      if (indirect) {
         struct vn_command_vkCmdDrawIndexedIndirect d = { .commandBuffer = (VkCommandBuffer)w.cmd,
                                                          .buffer = (VkBuffer)w.buf, .drawCount = 1,
                                                          .stride = sizeof(VkDrawIndexedIndirectCommand) };
         D->dispatch_vkCmdDrawIndexedIndirect(D, &d);
      } else if (indexed) {
         struct vn_command_vkCmdDrawIndexed d = { .commandBuffer = (VkCommandBuffer)w.cmd, .indexCount = 3,
                                                  .instanceCount = 1 };
         D->dispatch_vkCmdDrawIndexed(D, &d);
      } else {
         struct vn_command_vkCmdDraw d = { .commandBuffer = (VkCommandBuffer)w.cmd, .vertexCount = 3,
                                           .instanceCount = 1 };
         D->dispatch_vkCmdDraw(D, &d);
      }
   }
   step("%u draws recorded%s", i, ended() ? " (the context ended)" : "");
#undef K
   if (ended())
      return FATAL;
   if (IS("h-pass-draw-pred")) {
      struct vn_command_vkCmdEndConditionalRenderingEXT ec = { .commandBuffer = (VkCommandBuffer)w.cmd };
      D->dispatch_vkCmdEndConditionalRenderingEXT(D, &ec);
   }
   if (o.rendering) {
      struct vn_command_vkCmdEndRendering e = { .commandBuffer = (VkCommandBuffer)w.cmd };
      D->dispatch_vkCmdEndRendering(D, &e);
   } else {
      end_pass(w.cmd);
   }
   return end(w.cmd);
}

/* recordings, objects, heaps, the temp pool and the charge's return
 * (virgl-venus-host-memory.patch) */
static int case_host_memory(const char *c)
{
   if (IS("h-temp-big")) {
      setup(0);
      /* one 256 MB command: the decoder kept it for the context's next commands */
      void *t = vkr_cs_decoder_alloc_temp(&ctx->decoder, 256u << 20);
      if (!t)
         broken("temp");
      vkr_cs_decoder_reset(&ctx->decoder);
      const size_t kept = ctx->decoder.temp_pool.total_size;
      step("temp pool after the reset: %zu MB", kept >> 20);
      void *small = vkr_cs_decoder_alloc_temp(&ctx->decoder, 4096);
      vkr_cs_decoder_reset(&ctx->decoder);
      return small && kept <= (16u << 20) ? WORKS : ERROR;
   }
   if (IS("h-heap")) {
      setup(0);
      const uint64_t apps = virgl_gpu_budget_apps_limit();
      struct vkr_device_memory *mem = allocate(64u << 20, memory_type(~0u));
      (void)mem;
      VkPhysicalDeviceMemoryProperties mp = { 0 };
      struct vn_command_vkGetPhysicalDeviceMemoryProperties g1 = { .physicalDevice = (VkPhysicalDevice)pdev,
                                                                  .pMemoryProperties = &mp };
      D->dispatch_vkGetPhysicalDeviceMemoryProperties(D, &g1);
      VkPhysicalDeviceMemoryBudgetPropertiesEXT bp = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT };
      VkPhysicalDeviceMemoryProperties2 mp2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2,
                                                .pNext = lists(VK_EXT_MEMORY_BUDGET_EXTENSION_NAME) ? &bp : NULL };
      struct vn_command_vkGetPhysicalDeviceMemoryProperties2 g2 = { .physicalDevice = (VkPhysicalDevice)pdev,
                                                                   .pMemoryProperties = &mp2 };
      D->dispatch_vkGetPhysicalDeviceMemoryProperties2(D, &g2);
      VkPhysicalDeviceMaintenance3Properties m3 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_3_PROPERTIES };
      VkPhysicalDeviceMaintenance4Properties m4 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_4_PROPERTIES,
                                                    .pNext = &m3 };
      VkPhysicalDeviceProperties2 p2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &m4 };
      struct vn_command_vkGetPhysicalDeviceProperties2 gp = { .physicalDevice = (VkPhysicalDevice)pdev, .pProperties = &p2 };
      D->dispatch_vkGetPhysicalDeviceProperties2(D, &gp);
      bool ok = mp.memoryHeapCount && mp2.memoryProperties.memoryHeapCount;
      uint64_t heap = 0;
      for (uint32_t i = 0; i < mp.memoryHeapCount; i++) {
         const uint64_t s1 = mp.memoryHeaps[i].size, s2 = mp2.memoryProperties.memoryHeaps[i].size;
         step("heap %u: %" PRIu64 " MB (vkGetPhysicalDeviceMemoryProperties), %" PRIu64
              " MB (...2), apps' share %" PRIu64 " MB, budget %" PRIu64 " MB, usage %" PRIu64 " MB", i,
              s1 >> 20, s2 >> 20, apps >> 20, (uint64_t)bp.heapBudget[i] >> 20, (uint64_t)bp.heapUsage[i] >> 20);
         ok = ok && s1 <= apps && s2 <= apps && s1 == s2;
         if (mp2.pNext)
            ok = ok && bp.heapBudget[i] && bp.heapBudget[i] <= s2 && bp.heapUsage[i] >= (64u << 20) &&
                 bp.heapUsage[i] < (1u << 30);
         heap = s1 > heap ? s1 : heap;
      }
      step("maxMemoryAllocationSize %" PRIu64 " MB, maxBufferSize %" PRIu64 " MB", (uint64_t)m3.maxMemoryAllocationSize >> 20,
           (uint64_t)m4.maxBufferSize >> 20);
      ok = ok && m3.maxMemoryAllocationSize <= heap && m4.maxBufferSize <= heap;
      return ended() ? FATAL : ok ? WORKS : ERROR;
   }
   if (IS("h-zink-frame-ok")) {
      /* a Zink-like frame: 2000 passes of 5 draws each, a barrier between them, at the
       * default caps and budget */
      setup(0);
      struct world w = { 0 };
      make_world(&w, true);
      begin(w.cmd);
      bind_pipeline(w.cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, w.gfx_pipe);
      ready(w.cmd, &w, VK_PIPELINE_BIND_POINT_GRAPHICS);
      for (int p = 0; p < 2000 && !ended(); p++) {
         VkClearValue clear = { 0 };
         VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                      .renderPass = (VkRenderPass)w.rp, .framebuffer = (VkFramebuffer)w.fb,
                                      .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1,
                                      .pClearValues = &clear };
         struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = (VkCommandBuffer)w.cmd, .pRenderPassBegin = &bi,
                                                      .contents = VK_SUBPASS_CONTENTS_INLINE };
         D->dispatch_vkCmdBeginRenderPass(D, &b);
         for (int d = 0; d < 5; d++) {
            struct vn_command_vkCmdDraw dr = { .commandBuffer = (VkCommandBuffer)w.cmd, .vertexCount = 3,
                                               .instanceCount = 1 };
            D->dispatch_vkCmdDraw(D, &dr);
         }
         struct vn_command_vkCmdEndRenderPass e = { .commandBuffer = (VkCommandBuffer)w.cmd };
         D->dispatch_vkCmdEndRenderPass(D, &e);
         VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                                .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                .dstAccessMask = VK_ACCESS_SHADER_READ_BIT };
         struct vn_command_vkCmdPipelineBarrier pb = { .commandBuffer = (VkCommandBuffer)w.cmd,
                                                       .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                                       .dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                                       .memoryBarrierCount = 1, .pMemoryBarriers = &mb };
         D->dispatch_vkCmdPipelineBarrier(D, &pb);
      }
      return end(w.cmd);
   }
   if (IS("h-obj-cache-size") || IS("h-obj-cache-again-ok")) {
      /* a pipeline cache's charge grows with its initial data: the driver's own data of a
       * cache with real compute pipelines in it (one shader, 32 work group sizes) given to 50
       * new caches, each charged its data on top of the 20 KB and all of it back at their
       * destroy; again: 2000 made and destroyed, under an 8 MB account. Only data the driver
       * wrote reaches it (STANDARDS 14b). */
      const bool again = IS("h-obj-cache-again-ok");
      h_env("256", again ? "8" : "64", NULL);
      setup(0);
      void *layout = pipeline_layout(set_layout());
      void *comp = shader(spv_comp, sizeof(spv_comp));
      void *first = cache_made(NULL, 0);
      if (!comp || !first)
         broken("shader module, pipeline cache");
      for (uint32_t size = 1; size <= 32; size++) {
         spec_local_size = size;
         const uint64_t id = next_id++;
         VkPipeline h = (VkPipeline)(uintptr_t)id;
         VkComputePipelineCreateInfo info = {
            .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT,
                       .module = (VkShaderModule)comp, .pName = "main", .pSpecializationInfo = &spec_ok },
            .layout = (VkPipelineLayout)layout };
         struct vn_command_vkCreateComputePipelines c = { .device = DEVH, .pipelineCache = (VkPipelineCache)first,
                                                          .createInfoCount = 1, .pCreateInfos = &info,
                                                          .pPipelines = &h };
         D->dispatch_vkCreateComputePipelines(D, &c);
         if (c.ret != VK_SUCCESS || !object(id))
            broken("vkCreateComputePipelines with a cache");
         struct vn_command_vkDestroyPipeline d = { .device = DEVH, .pipeline = (VkPipeline)object(id) };
         D->dispatch_vkDestroyPipeline(D, &d);
      }
      spec_local_size = 64;
      static uint8_t data[4 << 20];
      const size_t bytes = cache_data(first, data, sizeof(data));
      const uint64_t before = virgl_gpu_budget_in_use();
      static void *caches[50];
      const int n = again ? 2000 : 50;
      int i = 0;
      for (; i < n && !ended(); i++) {
         void *cache = cache_made(data, bytes);
         if (!cache)
            return ended() ? FATAL : ERROR;
         if (again) {
            struct vn_command_vkDestroyPipelineCache d = { .device = DEVH, .pipelineCache = (VkPipelineCache)cache };
            D->dispatch_vkDestroyPipelineCache(D, &d);
         } else {
            caches[i] = cache;
         }
      }
      const uint64_t kept = virgl_gpu_budget_in_use();
      for (int k = 0; !again && k < i && !ended(); k++) {
         struct vn_command_vkDestroyPipelineCache d = { .device = DEVH, .pipelineCache = (VkPipelineCache)caches[k] };
         D->dispatch_vkDestroyPipelineCache(D, &d);
      }
      const uint64_t after = virgl_gpu_budget_in_use();
      const uint64_t each = kept > before && i ? (kept - before) / (uint64_t)i : 0;
      step("%d caches made from %zu B of the driver's data: %" PRIu64 " B charged a cache, %" PRIu64
           " KB in use before, %" PRIu64 " KB after the destroys%s", i, bytes, each, before >> 10, after >> 10,
           ended() ? " (the context ended)" : "");
      if (ended())
         return FATAL;
      return after <= before && (again || each >= (20u << 10) + bytes) ? WORKS : ERROR;
   }
   if (IS("h-obj-module-size") || IS("h-obj-module-again-ok")) {
      /* a module's charge grows with its code (both drivers keep a copy, vkr its scan): the
       * corpus' largest real module (DXVK, 68496 B; 4 KB a module before), 200 kept or 2000
       * made and destroyed again, under an 8 MB account */
      h_env("256", "8", NULL);
      setup(0);
      static uint32_t code[1 << 16];
      const size_t bytes = corpus_module("dxvk-d3d11-004.spv", code, sizeof(code));
      const bool again = IS("h-obj-module-again-ok");
      int i = 0;
      for (; i < (again ? 2000 : 200) && !ended(); i++) {
         void *m = shader(code, bytes);
         if (!m)
            return ended() ? FATAL : ERROR;
         if (again) {
            struct vn_command_vkDestroyShaderModule d = { .device = DEVH, .shaderModule = (VkShaderModule)m };
            D->dispatch_vkDestroyShaderModule(D, &d);
         }
      }
      step("%d modules of %zu B made%s", i, bytes, ended() ? " (the context ended)" : "");
      return ended() ? FATAL : WORKS;
   }
   h_env("256", NULL, NULL);
   const uint64_t before = virgl_gpu_budget_in_use();
   setup(0);
   if (IS("h-rec-fills") || IS("h-rec-updates")) {
      /* one command buffer, never ended: KosmicKrisp held 2423 B per fill, an update's 64 KB
       * x 1.28 (2 GB in under 0.6 s) */
      void *cmd = command_buffer();
      begin(cmd);
      struct vkr_buffer *buf = buffer(1u << 20);
      if (IS("h-rec-fills")) {
         h_fills(cmd, buf, 4000000);
      } else {
         static uint8_t data[65536];
         uint32_t i = 0;
         for (; i < 200000 && !ended(); i++) {
            struct vn_command_vkCmdUpdateBuffer u = { .commandBuffer = (VkCommandBuffer)cmd, .dstBuffer = (VkBuffer)buf,
                                                      .dataSize = sizeof(data), .pData = data };
            D->dispatch_vkCmdUpdateBuffer(D, &u);
         }
         step("%u updates of 64 KB recorded%s", i, ended() ? " (the context ended)" : "");
      }
      return ended() ? FATAL : WORKS;
   }
   if (IS("h-rec-reuse-ok") || IS("h-rec-spare-ok")) {
      /* 200 recordings of 20000 fills (KosmicKrisp: 70 MB each) in one command buffer, reset
       * between; or each in a new command buffer of the pool, the last one freed: the
       * charge stays at the most one recording took */
      const bool spare = IS("h-rec-spare-ok");
      void *pool = NULL, *cmds[4];
      pool = pool_with_buffers(1, cmds);
      struct vkr_buffer *buf = buffer(1u << 20);
      void *cmd = cmds[0];
      uint64_t first = 0;
      for (int i = 0; i < 200 && !ended(); i++) {
         begin(cmd);
         h_fills(cmd, buf, 20000);
         if (end(cmd) != WORKS)
            break;
         if (!i)
            first = virgl_gpu_budget_in_use();
         if (spare) {
            free_command_buffer(cmd);
            cmd = command_buffer_in(pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY);
         } else {
            reset_command_buffer(cmd);
         }
      }
      const uint64_t last = virgl_gpu_budget_in_use();
      step("charged after the first recording %" PRIu64 " KB, after the last %" PRIu64 " KB", first >> 10, last >> 10);
      if (ended())
         return FATAL;
      /* a new command buffer charges 40 KB itself */
      return last <= first + (64u << 10) ? WORKS : ERROR;
   }
   if (IS("h-obj-events") || IS("h-obj-events-again-ok")) {
      /* KosmicKrisp held 18366 B per event (1148 MB in 0.47 s) */
      const bool again = IS("h-obj-events-again-ok");
      const uint32_t n = again ? 4000 : 2000000;
      static uint64_t ids[4000];
      uint32_t i = 0;
      for (int round = 0; round < (again ? 3 : 1) && !ended(); round++) {
         for (i = 0; i < n && !ended(); i++) {
            const uint64_t id = next_id++;
            VkEvent h = (VkEvent)(uintptr_t)id;
            VkEventCreateInfo info = { .sType = VK_STRUCTURE_TYPE_EVENT_CREATE_INFO };
            struct vn_command_vkCreateEvent ce = { .device = DEVH, .pCreateInfo = &info, .pEvent = &h };
            D->dispatch_vkCreateEvent(D, &ce);
            if (ce.ret != VK_SUCCESS)
               return ended() ? FATAL : ERROR;
            if (again)
               ids[i] = id;
         }
         step("%u events made in round %d%s", i, round, ended() ? " (the context ended)" : "");
         for (uint32_t k = 0; again && k < i && !ended(); k++) {
            struct vn_command_vkDestroyEvent de = { .device = DEVH, .event = (VkEvent)object(ids[k]) };
            D->dispatch_vkDestroyEvent(D, &de);
         }
      }
      return ended() ? FATAL : WORKS;
   }
   if (IS("h-release-secondary-ok")) {
      /* a primary records a barrier; a secondary of a second pool, executed in it, is freed
       * and its pool destroyed (two zombies); the primary's reset lets both go: the charge
       * is back where it was before the second pool, while the context lives (#676, #700) */
      void *cmd = command_buffer();
      begin(cmd);
      color_barrier(cmd);
      const uint64_t s0 = virgl_gpu_budget_in_use();
      void *sec = command_buffer_level(VK_COMMAND_BUFFER_LEVEL_SECONDARY);
      void *pool = ((struct vkr_command_buffer *)sec)->pool;
      record_secondary(sec, 1);
      execute_secondary(cmd, sec);
      if (end(cmd) != WORKS)
         return ended() ? FATAL : ERROR;
      free_command_buffer(sec);
      destroy_command_pool(pool);
      const int z = zombies();
      const uint64_t held = virgl_gpu_budget_in_use();
      reset_command_buffer(cmd);
      const uint64_t s1 = virgl_gpu_budget_in_use();
      step("charged %" PRIu64 " B before the second pool, %" PRIu64 " B with %d zombies, %" PRIu64
           " B after the primary's reset (%d zombies)", s0, held, z, s1, zombies());
      if (ended())
         return FATAL;
      return z == 2 && zombies() == 0 && held > s0 && s1 == s0 ? WORKS : ERROR;
   }
   if (IS("h-release-end") || IS("h-release-fatal")) {
      /* objects, a recording, a held view destroyed (a zombie) and a pool's spare; then the
       * context's teardown: every charge comes back. fatal: after a refusal (budget) */
      if (h_prefill())
         return SKIP; /* the teardown commits a prefilled recording */
      const uint64_t setup_charge = virgl_gpu_budget_in_use();
      struct world w = { 0 };
      make_world(&w, false);
      void *pool = NULL, *cmds[4];
      pool = pool_with_buffers(2, cmds);
      begin(cmds[0]);
      h_fills(cmds[0], w.buf, 5000);
      begin(cmds[1]);
      h_fills(cmds[1], w.buf, 5000);
      end(cmds[1]);
      free_command_buffer(cmds[1]);
      /* a view a pass names, destroyed while the command buffer holds it */
      void *v = view(w.img, 1);
      void *fb = framebuffer(w.rp, &v, 1, 64, 64, 1);
      begin(w.cmd);
      begin_pass(w.cmd, w.rp, fb, 64, 64);
      end_pass(w.cmd);
      destroy_view(v);
      for (int i = 0; i < 100; i++) {
         VkEventCreateInfo info = { .sType = VK_STRUCTURE_TYPE_EVENT_CREATE_INFO };
         VkEvent h = (VkEvent)(uintptr_t)next_id++;
         struct vn_command_vkCreateEvent ce = { .device = DEVH, .pCreateInfo = &info, .pEvent = &h };
         D->dispatch_vkCreateEvent(D, &ce);
      }
      const uint64_t during = virgl_gpu_budget_in_use();
      if (IS("h-release-fatal"))
         h_fills(cmds[0], w.buf, 4000000);
      step("zombies %d, charged before the setup %" PRIu64 " KB, after it %" PRIu64 " KB, with the objects %" PRIu64
           " KB, context ended %d", zombies(), before >> 10, setup_charge >> 10, during >> 10, ended());
      if (IS("h-release-fatal") && !ended())
         return ERROR;
      (void)pool;
      vkr_context_destroy(ctx);
      const uint64_t after = virgl_gpu_budget_in_use();
      step("charged after the teardown %" PRIu64 " KB", after >> 10);
      if (log_len && strstr(log_text, "still charged"))
         return ERROR;
      /* the objects charged (more than 400 KB: 100 events alone are 2000 KB) and all came back */
      return during > setup_charge + (400u << 10) && after == before ? (IS("h-release-fatal") ? FATAL : WORKS)
                                                                      : ERROR;
   }
   return BROKEN;
}

static int case_host(const char *c)
{
   if (!strncmp(c, "h-pass-draw-", 12) || !strncmp(c, "h-pass-3d-", 10))
      return case_host_draws(c);
   return !strncmp(c, "h-pass-", 7) ? case_host_passes(c) : case_host_memory(c);
}

struct test_case {
   const char *name;
   int expect;
   /* E_REFUSE: a text its refusal line must have (NULL: any) */
   const char *line;
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
   { "p-gfx-sample-locations-off", E_WORKS }, { "p-gfx-sample-locations-dyn-far", E_REFUSE },
   { "p-layout-sets-max", E_WORKS }, { "p-layout-sets-over", E_REFUSE }, { "p-layout-sets-far", E_REFUSE },
   { "p-layout-push-ranges-ok", E_WORKS }, { "p-layout-push-ranges-far", E_REFUSE },
   { "p-layout-push-over", E_REFUSE }, { "p-layout-dynamic-max", E_WORKS }, { "p-layout-dynamic-over", E_REFUSE },
   /* SPIR-V, entry points, workgroups, shader descriptor sets, attachment formats (PR-B) */
   { "p-spirv-garbage", E_REFUSE }, { "p-spirv-magic", E_REFUSE }, { "p-spirv-bound", E_REFUSE },
   { "p-spirv-truncated", E_REFUSE }, { "p-spirv-inline-garbage", E_REFUSE },
   { "p-entry-missing", E_REFUSE }, { "p-stage-mismatch", E_REFUSE },
   /* guest names with control bytes: each becomes a space, the line stays whole */
   { "p-entry-name-ctl", E_REFUSE, "no entry point \"main  [2K ok\"" },
   { "p-ctx-name-ctl", E_REFUSE, "te [2K  st X: vkCreateComputePipelines refused: " },
   { "p-shader-layout-sets", E_REFUSE }, { "p-shader-layout-binding", E_REFUSE },
   { "p-unused-set-ok", E_WORKS }, { "p-unused-set-ok-16", E_WORKS }, { "p-unused-set-missing", E_REFUSE },
   { "p-workgroup-max", E_WORKS }, { "p-workgroup-over", E_REFUSE }, { "p-workgroup-huge", E_REFUSE },
   { "p-gfx-format-bad", E_REFUSE }, { "p-gfx-format-r64", E_CHILD }, { "p-gfx-depth-format-color", E_REFUSE },
   { "p-gfx-depth-format-ok", E_WORKS },
   /* render passes, framebuffers, dynamic rendering */
   { "r-ok", E_WORKS }, { "r-dyn-ok", E_WORKS }, { "r-two-subpasses-ok", E_WORKS },
   { "r-att-ref-oob", E_REFUSE }, { "r-att-ref-far", E_REFUSE },
   { "r-colors-max", E_WORKS }, { "r-colors-over", E_REFUSE }, { "r-colors-16", E_REFUSE },
   { "r-fb-fewer", E_REFUSE }, { "r-fb-huge", E_REFUSE }, { "r-begin-clear-short", E_REFUSE },
   { "r-fb-null-array", E_REFUSE }, { "r-begin-null-array", E_REFUSE },
   { "r-multiview-3", E_WORKS }, { "r-multiview-all", E_CHILD }, { "r-dyn-viewmask-all", E_CHILD },
   { "r-mv-legal-2", E_CHILD }, { "r-mv-legal-4", E_CHILD }, { "r-mv-legal-8", E_CHILD },
   { "r-mv-legal-9", E_CHILD }, { "r-mv-legal-12", E_CHILD }, { "r-mv-legal-16", E_CHILD },
   { "r-mv-legal-32", E_CHILD }, { "r-mv-legal-max", E_CHILD }, { "r-mv-legal-max-dyn", E_CHILD },
   { "r-mv-count-short", E_REFUSE }, { "r-dep-subpass-far", E_REFUSE }, { "r-input-aspect-far", E_REFUSE },
   { "r-correlation-ok", E_WORKS }, { "r-correlation2-ok", E_WORKS },
   { "r-sample-loc-index-far", E_REFUSE },
   { "r-dyn-colors-over", E_REFUSE }, { "r-dyn-layers-over", E_REFUSE }, { "r-dyn-resolve-null", E_REFUSE },
   { "r-dyn-resolve-no-view", E_WORKS }, { "r-dyn-resolve-no-view-target", E_WORKS },
   { "r-begin-clear-color-stencil", E_WORKS }, { "r-begin-clear-ds-stencil", E_REFUSE },
   { "r-dyn-resolve-mode-bad", E_REFUSE }, { "r-format-bad", E_REFUSE }, { "r-format-r64", E_CHILD },
   { "r-unused-format-ok", E_WORKS },
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
   { "d-consecutive-gap-ok", E_WORKS }, { "d-consecutive-zero-ok", E_WORKS }, { "d-copy-consecutive-ok", E_WORKS },
   { "d-binding-oob", E_REFUSE }, { "d-binding-far", E_REFUSE }, { "d-elem-far", E_REFUSE },
   { "d-elem-next", E_REFUSE }, { "d-type-mismatch", E_REFUSE }, { "d-null-sampler", E_REFUSE },
   { "d-null-view", E_REFUSE }, { "d-null-view-nd", E_WORKS }, { "d-null-buffer", E_REFUSE, "no buffer (the device's nullDescriptor is off)" },
   { "d-null-buffer-nd", E_WORKS }, { "d-null-dynamic-nd", E_WORKS }, { "d-range-past", E_REFUSE },
   { "d-offset-past-whole", E_REFUSE },
   { "d-dyn-elem-far", E_REFUSE }, { "d-inline-far", E_REFUSE }, { "d-inline-size", E_REFUSE },
   { "d-copy-far", E_REFUSE },
   { "d-start-next-ok", E_WORKS }, { "d-copy-start-next-ok", E_WORKS }, { "d-start-past-all", E_REFUSE },
   { "d-planes-ok", E_WORKS }, { "d-mutable-ok", E_WORKS },
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
   { "c-push-set-binding-far", E_REFUSE }, { "c-push-set-split-ok", E_WORKS },
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
   { "c-nested-self", E_REFUSE }, { "c-inherit-format-bad", E_REFUSE },
   /* command buffer state, copy regions (PR-B) */
   { "c-state-not-begun", E_REFUSE }, { "c-state-after-end", E_REFUSE }, { "c-state-execute-recording", E_REFUSE },
   { "c-state-draw-no-pipeline", E_REFUSE }, { "c-state-draw-outside", E_REFUSE },
   { "c-state-dispatch-no-pipeline", E_REFUSE }, { "c-state-dispatch-inside", E_REFUSE },
   { "c-state-clear-outside", E_REFUSE }, { "c-state-clear-beyond", E_REFUSE },
   { "c-state-next-subpass", E_REFUSE }, { "c-state-two-subpasses-ok", E_WORKS },
   { "c-state-end-no-begin", E_REFUSE }, { "c-state-begin-twice", E_REFUSE }, { "c-state-end-in-pass", E_REFUSE },
   { "c-state-query-views-ok", E_WORKS }, { "c-state-query-views-past", E_REFUSE },
   { "c-state-after-mv-timestamp", E_WORKS }, { "c-state-after-mv-query", E_WORKS },
   { "c-state-after-mv2-timestamp", E_WORKS }, { "c-state-after-mv-dyn-timestamp", E_WORKS },
   { "c-state-destroyed-pass-next", E_REFUSE }, { "c-state-destroyed-pass-end", E_REFUSE },
   { "c-state-destroyed-fb-end", E_REFUSE }, { "c-state-destroyed-id-reused", E_REFUSE },
   { "c-state-end-query-views-past", E_REFUSE },
   { "c-state-destroyed-view-begin", E_REFUSE }, { "c-state-destroyed-view-next", E_REFUSE },
   { "c-state-destroyed-view-end", E_REFUSE }, { "c-state-destroyed-view-imageless", E_REFUSE },
   { "c-state-destroyed-view-rendering", E_REFUSE }, { "c-state-destroyed-view-after-ok", E_WORKS },
   { "c-state-destroyed-view-resolve-none-ok", E_WORKS },
   /* command buffers hold what their passes named (virgl-venus-command-holds.patch) */
   { "c-state-destroyed-view-held-rendering-barrier", E_REFUSE, "was destroyed" },
   { "c-state-destroyed-view-held-pass-barrier", E_REFUSE, "was destroyed" },
   { "c-state-destroyed-view-held-submit", E_KEEP },
   { "c-state-destroyed-view-held-reset-ok", E_WORKS }, { "c-state-destroyed-view-held-begin-ok", E_WORKS },
   { "c-state-destroyed-view-held-free-ok", E_WORKS }, { "c-state-destroyed-view-held-image-memory-ok", E_WORKS },
   { "c-state-destroyed-view-held-teardown-ok", E_WORKS }, { "c-state-destroyed-view-held-control-ok", E_WORKS },
   /* primaries hold the secondaries they executed (virgl-venus-secondary-holds.patch) */
   { "c-state-secondary-held-free-submit", E_WORKS }, { "c-state-secondary-held-pool-submit", E_WORKS },
   { "c-state-secondary-held-reset-ok", E_WORKS }, { "c-state-secondary-held-free-primary-ok", E_WORKS },
   { "c-state-secondary-held-same-pool-ok", E_WORKS }, { "c-state-secondary-held-teardown-ok", E_WORKS },
   { "c-state-secondary-held-control-ok", E_WORKS },
   /* a secondary recorded again after its primary executed it (virgl-venus-submit-state.patch) */
   { "c-state-secondary-held-resubmit-ok", E_WORKS }, { "c-state-secondary-held-rerecord-ok", E_WORKS },
   { "c-state-secondary-held-rerecord-submit", E_REFUSE, "recorded again" },
   { "c-state-secondary-held-reset-submit", E_REFUSE, "recorded again" },
   { "c-state-secondary-held-pool-reset-submit", E_REFUSE, "recorded again" },
   { "c-state-secondary-held-free-pool-reset-submit", E_REFUSE, "recorded again" },
   { "c-state-secondary-held-rerecord-end", E_REFUSE, "recorded again" },
   /* a driver end that failed; ended from the guest's call (virgl-venus-submit-state.patch) */
   { "c-state-end-failed-submit-ok", E_WORKS }, { "c-state-end-failed-resubmit-ok", E_WORKS },
   { "c-state-end-failed-secondary-ok", E_WORKS },
   { "c-state-end-failed-reset-submit", E_REFUSE, "was not ended" },
   { "c-state-end-failed-rebegin-submit", E_REFUSE, "still records" },
   { "c-state-end-hook-submit", E_CHILD, "could not record it" },
   { "c-state-end-hook-secondary", E_CHILD, "could not record it" },
   { "c-state-end-hook-reset-ok", E_WORKS },
   { "c-probe-descriptor-view", E_PROBE },
   { "c-region-b2i-max", E_WORKS }, { "c-region-b2i-past", E_REFUSE }, { "c-region-b2i-rowlength", E_REFUSE },
   { "c-region-b2i-extent", E_REFUSE }, { "c-region-b2i-offset", E_REFUSE }, { "c-region-b2i-aspect", E_REFUSE },
   { "c-region-i2b-max", E_WORKS }, { "c-region-i2b-past", E_REFUSE },
   { "c-region-image-max", E_WORKS }, { "c-region-image-past", E_REFUSE },
   { "c-region-blit-mirror", E_WORKS }, { "c-region-blit-past", E_REFUSE },
   /* host query calls, query pools */
   { "q-ok", E_WORKS }, { "q-reset-ok", E_WORKS }, { "q-pool-large", E_KEEP }, { "q-results-first-far", E_REFUSE },
   { "q-results-stride", E_REFUSE }, { "q-reset-far", E_REFUSE }, { "q-pool-type-bad", E_REFUSE },
   { "q-pool-huge", E_REFUSE },
   /* pool frees, submit counts, dedicated memory, size-0 memory (venus-624-c) */
   { "f-cmds-ok", E_WORKS }, { "f-cmds-null-ok", E_WORKS }, { "f-cmds-dup", E_REFUSE, "named twice" },
   { "f-cmds-other-pool", E_REFUSE, "of another pool" }, { "f-sets-ok", E_WORKS }, { "f-sets-reset-ok", E_WORKS },
   { "f-sets-dup", E_REFUSE, "named twice" }, { "f-sets-other-pool", E_REFUSE, "of another pool" },
   { "s-submit-secondary", E_REFUSE, "is a secondary" }, { "s-submit-recording", E_REFUSE, "still records" },
   { "s-submit-initial", E_REFUSE, "was not ended" },
   { "s-submit-ok", E_WORKS }, { "s-submit-values-64", E_WORKS },
   { "s-submit-group-counts", E_REFUSE, "device group counts" }, { "s-bind-sparse", E_REFUSE, "no sparse binding" },
   { "s-submit-chain-twice", E_REFUSE, "chained twice" }, { "s-bind-sparse-chain-twice", E_REFUSE, "chained twice" },
   { "x-dedicated-bound-ok", E_WORKS }, { "x-dedicated-unbound-ok", E_WORKS },
   { "x-dedicated-buffer-unbound-ok", E_WORKS }, { "x-dedicated-context-end-ok", E_WORKS },
   { "x-dedicated-other", E_REFUSE, "dedicated to another" },
   { "x-dedicated-alias-half", E_REFUSE, "dedicated to another" },
   /* a swapchain's memory (virgl-venus-alias-memory.patch) */
   { "x-dedicated-alias", E_WORKS }, { "x-dedicated-alias-b-first-ok", E_WORKS },
   { "x-dedicated-alias-free-a-b", E_WORKS }, { "x-dedicated-alias-context-end", E_WORKS },
   { "x-dedicated-alias-held", E_WORKS }, { "x-dedicated-alias-own-dedicated", E_WORKS },
   { "x-dedicated-alias-bind2", E_WORKS },
   { "x-dedicated-alias-params", E_REFUSE, "unlike the image" },
   { "x-dedicated-alias-params-usage", E_REFUSE, "unlike the image" },
   { "x-dedicated-alias-params-flags", E_REFUSE, "unlike the image" },
   { "x-dedicated-alias-twice", E_REFUSE, "bound already" },
   { "x-dedicated-alias-bind2-twice", E_REFUSE, "named twice" },
   { "x-dedicated-chain-twice", E_REFUSE, "chained twice" }, { "x-dedicated-chain-null", E_REFUSE, "chained twice" },
   { "x-dedicated-other-device", E_REFUSE, "another device" },
   { "x-dedicated-buffer-to-image", E_REFUSE, "dedicated to another" },
   { "m-alloc0-device", E_KEEP }, { "m-alloc0-host", E_KEEP },
   /* two threads on one context: a ring and the context's stream (virgl-venus-ring-lock.patch) */
   { "t-pipeline-destroy-layout", E_REFUSE, "another thread uses it" },
   { "t-pipeline-destroy-module", E_REFUSE, "another thread uses it" },
   { "t-cache-data-destroy", E_REFUSE, "another thread uses it" },
   { "t-same-id", E_REFUSE, "taken" },
   { "t-command-free-buffer", E_WORKS }, { "t-same-command-buffer", E_WORKS }, { "t-export-free-memory", E_WORKS },
   { "t-wait-ring-nested-ok", E_WORKS }, { "t-compile-no-delay-ok", E_WORKS }, { "t-teardown-paused-ok", E_WORKS },
   /* a structure type twice in a chain (virgl-venus-chain-repeats.patch) */
   { "r-repeat-multiview", E_REFUSE, "twice in the chain of VkRenderPassCreateInfo" },
   { "r-repeat-multiview-short", E_REFUSE, "twice in the chain of VkRenderPassCreateInfo" },
   { "r-repeat-attachment-begin", E_REFUSE, "twice in the chain of VkRenderPassBeginInfo" },
   { "r-repeat-begin", E_REFUSE, "twice in the chain of VkRenderPassBeginInfo" },
   { "r-repeat-pass2-subpass", E_REFUSE, "twice in the chain of VkSubpassDescription2" },
   { "r-repeat-framebuffer", E_REFUSE, "twice in the chain of VkFramebufferCreateInfo" },
   { "r-repeat-rendering", E_REFUSE, "twice in the chain of VkRenderingInfo" },
   { "r-repeat-two-types-ok", E_WORKS }, { "r-repeat-begin-two-types-ok", E_WORKS },
   { "c-repeat-inheritance", E_REFUSE, "twice in the chain of VkCommandBufferInheritanceInfo" },
   { "d-repeat-layout", E_REFUSE, "twice in the chain of VkDescriptorSetLayoutCreateInfo" },
   { "d-repeat-write", E_REFUSE, "twice in the chain of VkWriteDescriptorSet" },
   { "d-repeat-alloc", E_REFUSE, "twice in the chain of VkDescriptorSetAllocateInfo" },
   { "d-repeat-pool", E_REFUSE, "twice in the chain of VkDescriptorPoolCreateInfo" },
   { "d-repeat-buffer", E_REFUSE, "twice in the chain of VkBufferCreateInfo" },
   { "d-repeat-buffer-view", E_REFUSE, "twice in the chain of VkBufferViewCreateInfo" },
   { "d-repeat-sampler", E_REFUSE, "twice in the chain of VkSamplerCreateInfo" },
   { "d-repeat-two-types-ok", E_WORKS },
   { "p-repeat-inline-spirv", E_REFUSE, "twice in the chain of VkPipelineShaderStageCreateInfo" },
   { "p-repeat-gfx", E_REFUSE, "twice in the chain of VkGraphicsPipelineCreateInfo" },
   { "p-repeat-gfx-vertex", E_REFUSE, "twice in the chain of VkPipelineVertexInputStateCreateInfo" },
   { "p-repeat-gfx-ms", E_REFUSE, "twice in the chain of VkPipelineMultisampleStateCreateInfo" },
   { "p-repeat-gfx-blend", E_REFUSE, "twice in the chain of VkPipelineColorBlendStateCreateInfo" },
   { "p-repeat-compute", E_REFUSE, "twice in the chain of VkComputePipelineCreateInfo" },
   { "p-repeat-gfx-two-types-ok", E_WORKS },
   /* values Vulkan ignores, refusal texts (virgl-venus-ignored-values.patch) */
   { "d-texel-empty-nd", E_WORKS }, { "d-texel-one-nd", E_WORKS }, { "d-texel-empty-push", E_WORKS },
   { "d-texel-empty-copy", E_WORKS }, { "d-texel-empty-teardown", E_WORKS },
   { "d-texel-empty", E_REFUSE, "fewer than one 16-byte texel (a view of no texel needs nullDescriptor)" },
   { "d-texel-empty-nd-misaligned", E_REFUSE, "not aligned" },
   { "p-gfx-vstride-dynamic", E_WORKS }, { "p-gfx-vstride-dynamic-bind", E_WORKS },
   { "p-gfx-blend-null", E_REFUSE, "1 attachments (no array) for 1 colors" },
   { "p-gfx-blend-null-dyn", E_REFUSE, "1 attachments (no array) for 2 colors" },
   { "p-gfx-blend-more-dyn", E_REFUSE, "3 attachments for 1 colors" },
   { "p-gfx-blend-dyn-ok", E_WORKS }, { "p-gfx-blend-discard-ok", E_WORKS },
   { "p-gfx-blend-discard-dyn", E_REFUSE, "(no array)" },
   { "c-null-text-bind2", E_REFUSE, "binding 0: the whole size at 0, no buffer, stride 16" },
   { "c-null-text-barrier", E_REFUSE, "buffer barrier 0: the whole size at 0, no buffer" },
   { "c-null-text-fill", E_REFUSE, "the whole size at 65536 of a 65536-byte buffer" },
   /* state a draw or dispatch never set (virgl-venus-unset-state.patch) */
   { "u-set-unset", E_REFUSE, "uses set 0, but no set was bound there since vkBeginCommandBuffer (VUID-vkCmdDraw-None-08600)" },
   { "u-set-second-unset", E_REFUSE, "uses set 1, but no set was bound" },
   { "u-set-unset-dispatch", E_REFUSE, "uses set 0, but no set was bound there since vkBeginCommandBuffer (VUID-vkCmdDispatch-None-08600)" },
   { "u-set-second-unset-dispatch", E_REFUSE, "uses set 2, but no set was bound" },
   { "u-set-other-point", E_REFUSE, "uses set 0, but no set was bound" },
   { "u-set-secondary", E_REFUSE, "uses set 0, but no set was bound" },
   { "u-ib-unset", E_REFUSE, "no index buffer bound since vkBeginCommandBuffer (maintenance6 is off: VUID-vkCmdDrawIndexed-None-07312)" },
   { "u-ib-unset-indirect", E_REFUSE, "VUID-vkCmdDrawIndexedIndirect-None-07312" },
   { "u-ib-unset-indirect-count", E_REFUSE, "VUID-vkCmdDrawIndexedIndirectCount-None-07312" },
   { "u-ib-unset-multi", E_REFUSE, "VUID-vkCmdDrawMultiIndexedEXT-None-07312" },
   { "u-set-declared-ok", E_WORKS }, { "u-set-interface-only-ok", E_WORKS }, { "u-set-rebind-ok", E_WORKS },
   { "u-set-push-ok", E_WORKS }, { "u-set-push2-ok", E_WORKS }, { "u-set-bind2-ok", E_WORKS },
   { "u-set-bind2-dispatch-ok", E_WORKS }, { "u-set-bind2-both-ok", E_WORKS },
   { "u-ib-null-m6-ok", E_WORKS }, { "u-ib-unset-m6-ok", E_WORKS }, { "u-ib-unset-m6-indirect-ok", E_WORKS },
   { "u-ib-unset-m6-indirect-count-ok", E_WORKS }, { "u-ib-unset-m6-multi-ok", E_WORKS }, { "u-ib-bound-ok", E_WORKS },
   { "u-set-execute-kept", E_WORKS }, { "u-pc-unset-kept", E_WORKS }, { "u-vb-unset-kept", E_WORKS },
   /* host memory (virgl-venus-encoder-cap.patch, virgl-venus-host-memory.patch) */
   { "h-pass-clear-max-ok", E_WORKS }, { "h-pass-clear-over", E_REFUSE, "Metal passes" },
   { "h-pass-default-max-ok", E_WORKS }, { "h-pass-default-over", E_REFUSE, "Metal passes" },
   { "h-pass-default-past-metal", E_REFUSE, "Metal passes" },
   { "h-pass-levels-ok", E_WORKS }, { "h-pass-levels-over", E_REFUSE, "Metal passes" },
   { "h-pass-layers-ok", E_WORKS }, { "h-pass-render-passes-ok", E_WORKS },
   { "h-pass-render-passes-over", E_REFUSE, "Metal passes" }, { "h-pass-renderings-over", E_REFUSE, "Metal passes" },
   { "h-pass-blits-over", E_REFUSE, "Metal passes" }, { "h-pass-split-barriers", E_CHILD },
   { "h-pass-secondary-ok", E_WORKS }, { "h-pass-secondary-over", E_REFUSE, "Metal passes" },
   { "h-pass-batch-ok", E_WORKS }, { "h-pass-batch-over", E_CHILD },
   /* draws and state changes that split a pass (fix-700) */
   { "h-pass-draw-fan", E_CHILD }, { "h-pass-draw-u8", E_CHILD }, { "h-pass-draw-strip16", E_CHILD },
   { "h-pass-draw-list-restart", E_CHILD }, { "h-pass-draw-flat-last", E_CHILD }, { "h-pass-draw-pred", E_CHILD },
   { "h-pass-draw-robust-indirect", E_CHILD }, { "h-pass-draw-tess", E_CHILD },
   { "h-pass-draw-sample-locations", E_CHILD }, { "h-pass-draw-attachment-locations", E_CHILD },
   { "h-pass-draw-list16", E_CHILD }, { "h-pass-draw-strip16-restart", E_CHILD }, { "h-pass-draw-strip32", E_CHILD },
   { "h-pass-draw-flat-first", E_CHILD }, { "h-pass-draw-robust-plain", E_CHILD },
   { "h-pass-3d-ok", E_WORKS }, { "h-pass-3d-over", E_REFUSE, "Metal passes" },
   { "h-rec-fills", E_REFUSE, "host memory" }, { "h-rec-updates", E_REFUSE, "host memory" },
   { "h-rec-reuse-ok", E_WORKS }, { "h-rec-spare-ok", E_WORKS },
   { "h-obj-events", E_REFUSE, "host memory" }, { "h-obj-events-again-ok", E_WORKS },
   { "h-obj-module-size", E_REFUSE, "host memory" }, { "h-obj-module-again-ok", E_WORKS },
   { "h-obj-cache-size", E_WORKS }, { "h-obj-cache-again-ok", E_WORKS },
   { "h-release-end", E_WORKS }, { "h-release-fatal", E_REFUSE, "host memory" },
   { "h-release-secondary-ok", E_WORKS },
   { "h-heap", E_WORKS }, { "h-temp-big", E_WORKS }, { "h-zink-frame-ok", E_WORKS },
};
#define N_CASES (sizeof(cases) / sizeof(cases[0]))

static int run_case(const char *c)
{
   /* a context name with control bytes, a newline too: the refusal line stays one line */
   if (IS("p-ctx-name-ctl"))
      ctx_name = "te\x1b[2K\r\tst\nX";
   if (IS("c-probe-descriptor-view")) {
      setup(0);
      struct world w;
      make_world(&w, false);
      return descriptor_probe(&w);
   }
   if (strstr(c, "-repeat-"))
      return case_repeat(c);
   if (!strncmp(c, "d-texel-", 8) || !strncmp(c, "p-gfx-vstride-dynamic", 21) ||
       !strncmp(c, "p-gfx-blend-null", 16) || !strncmp(c, "p-gfx-blend-more-dyn", 20) ||
       !strncmp(c, "p-gfx-blend-dyn-", 16) || !strncmp(c, "p-gfx-blend-discard-", 20) ||
       !strncmp(c, "c-null-text-", 12))
      return case_ignored(c);
   switch (c[0]) {
   case 'p': return case_pipeline(c);
   case 'r': return case_render_pass(c);
   case 'd': return case_descriptor(c);
   case 'c': return case_command(c);
   case 'q': return case_query(c);
   case 'f': return case_frees(c);
   case 's': return case_submit(c);
   case 'x': return case_dedicated(c);
   case 'm': return case_memory(c);
   case 't': return case_threads(c);
   case 'u': return case_unset(c);
   case 'h': return case_host(c);
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
   double us[8];

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
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < n; i++) {
      VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
                             .dstAccessMask = VK_ACCESS_SHADER_READ_BIT };
      struct vn_command_vkCmdPipelineBarrier b = { .commandBuffer = cb,
                                                   .srcStageMask = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                                                   .dstStageMask = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                                                   .memoryBarrierCount = 1, .pMemoryBarriers = &mb };
      D->dispatch_vkCmdPipelineBarrier(D, &b);
   }
   us[5] = since(&t0) / n;
   /* one vkUpdateDescriptorSets of 1000 writes (n / 100 times); vkr turns the handles in the
      writes into the driver's in place, so each round gets fresh writes (filled untimed) */
   static VkWriteDescriptorSet many[1000];
   static VkDescriptorBufferInfo many_bi[1000];
   const int rounds = n / 100 > 0 ? n / 100 : 1;
   double total = 0;
   for (int i = 0; i < rounds; i++) {
      for (int j = 0; j < 1000; j++) {
         many_bi[j] = (VkDescriptorBufferInfo){ (VkBuffer)w.buf, 0, 256 };
         many[j] = (VkWriteDescriptorSet){ .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                                           .dstSet = (VkDescriptorSet)w.set, .dstBinding = 0,
                                           .descriptorCount = 1,
                                           .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                                           .pBufferInfo = &many_bi[j] };
      }
      struct vn_command_vkUpdateDescriptorSets u = { .device = DEVH, .descriptorWriteCount = 1000,
                                                     .pDescriptorWrites = many };
      clock_gettime(CLOCK_MONOTONIC, &t0);
      D->dispatch_vkUpdateDescriptorSets(D, &u);
      total += since(&t0);
   }
   us[6] = total / rounds;
   /* a pass is an encoder in KosmicKrisp's Metal command buffer: n / 10 of them */
   const int passes = n / 10 > 0 ? n / 10 : 1;
   clock_gettime(CLOCK_MONOTONIC, &t0);
   for (int i = 0; i < passes; i++) {
      VkClearValue clear = { 0 };
      VkRenderPassBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                                   .renderPass = (VkRenderPass)w.rp, .framebuffer = (VkFramebuffer)w.fb,
                                   .renderArea = { { 0, 0 }, { 64, 64 } }, .clearValueCount = 1,
                                   .pClearValues = &clear };
      struct vn_command_vkCmdBeginRenderPass b = { .commandBuffer = cb, .pRenderPassBegin = &bi,
                                                   .contents = VK_SUBPASS_CONTENTS_INLINE };
      D->dispatch_vkCmdBeginRenderPass(D, &b);
      struct vn_command_vkCmdEndRenderPass e = { .commandBuffer = cb };
      D->dispatch_vkCmdEndRenderPass(D, &e);
   }
   us[7] = since(&t0) / passes;
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
          "vkUpdateDescriptorSets %.3f, vkCmdBindDescriptorSets %.3f, vkCmdDraw %.3f, "
          "vkCmdPipelineBarrier %.3f, vkUpdateDescriptorSets of 1000 writes %.3f, "
          "vkCmdBeginRenderPass+vkCmdEndRenderPass %.3f\n",
          n, us[0], us[1], us[2], us[3], us[4], us[5], us[6], us[7]);
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
   case ZOMBIES: return "a wrong zombie count";
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
   if (argc == 3 && !strcmp(argv[1], "--ring-time"))
      return ring_time(atoi(argv[2]));
   if (argc == 2 && !strcmp(argv[1], "driver")) {
      instance_and_physical_device();
      printf("maxMultiviewViewCount told to the guest: %u\n", max_views);
      _exit(kosmickrisp ? ERROR : WORKS);
   }
   if (argc == 2) {
      /* the destroyed-object and two-thread cases: macOS's malloc fills freed memory with
       * 0x55 bytes, so a read of a destroyed object faults at once instead of finding its
       * old values */
      if ((!strncmp(argv[1], "c-state-destroyed-", 18) || !strncmp(argv[1], "t-", 2)) &&
          !getenv("MallocScribble")) {
         setenv("MallocScribble", "1", 1);
         setenv("MallocNanoZone", "0", 1);
         execv(argv[0], argv);
         printf("test setup: execv with MallocScribble failed\n");
         _exit(BROKEN);
      }
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
      /* a refusal is one line: no byte below 0x20 but its own newline */
      bool clean = true;
      for (const char *r = refusal; *r; r++)
         clean = clean && ((unsigned char)*r >= 0x20 || (*r == '\n' && !r[1]));
      bool ok;
      if (got == SKIP) {
         ok = true;
         skipped++;
      } else if (want == E_PROBE) {
         ok = true;
         printf("probe: %s: %s%s\n", tc->name, seen, refused_line ? " (a refusal line)" : "");
      } else if (want == E_REFUSE) {
         ok = got == FATAL && refused_line && clean && (!tc->line || strstr(refusal, tc->line));
      } else if (want == E_WORKS) {
         ok = got == WORKS && !refused_line;
      } else {
         ok = (got == WORKS || got == ERROR) && !refused_line;
      }
      printf("%s: %s: %s%s\n", ok ? "ok" : "FAIL", tc->name, seen,
             want != E_REFUSE ? (refused_line ? " (refused where it must work)" : "")
             : !clean ? " (control bytes in the refusal line)"
             : refused_line && tc->line && !strstr(refusal, tc->line) ? " (not the refusal line it must be)" : "");
      if (ok && want == E_REFUSE && got == FATAL) {
         const char *r = strstr(refusal, "vkr: ");
         printf("   %s", r ? r : refusal);
      }
      char skip[256];
      if (got == SKIP && log_has(log, "skip: ", skip, sizeof(skip)))
         printf("   %s", strstr(skip, "skip: "));
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
