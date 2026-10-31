/*
 * Copyright 2026 OmacVM contributors
 * SPDX-License-Identifier: MIT
 */

/* vkr_spirv.c (patches/virgl-venus-spirv-scan.patch, ADR 0065) on the CPU alone, under
 * AddressSanitizer and UndefinedBehaviorSanitizer; fuzz-venus-spirv.sh takes the scan's two
 * files out of the patch and builds this against them. No Vulkan driver, no GPU (STANDARDS
 * 14: fuzzed input never reaches a real driver).
 *  1. real modules (glslc and spirv-as output, sources below) scan with the entry points,
 *     workgroup sizes after specialization and descriptor bindings per entry point they have;
 *  2. the malformed modules that ended QEMU through the Mac's compilers are refused;
 *  3. mutations of the real modules (bit flips, words set to edge values, truncation,
 *     inserted, removed and copied words, opcodes and lengths changed) never fault and never
 *     read outside the code (each in an exactly sized heap block), and every summary answers
 *     the pipeline's questions (entry point, workgroup size, bindings) without a fault;
 *  4. a module at the id bound with 2^17 functions in a call chain and 2^17 decorations,
 *     constants and uses scans and walks in linear time.
 *   fuzz-venus-spirv [ITERATIONS [SEED]]   (default 200000, 1)
 *
 * Seeds (shaderc v2026.4, spirv-tools v2026.4; spirv-val clean for vulkan1.3):
 *   spec10 / spec16: glslc -fshader-stage=comp --target-env=vulkan1.0 / vulkan1.3 -O0 of
 *     #version 450
 *     layout(local_size_x_id = 0, local_size_y = 2, local_size_z_id = 1) in;
 *     layout(set = 0, binding = 0) buffer A { uint a[]; };
 *     layout(set = 2, binding = 3) uniform B { uint b; };
 *     layout(set = 5, binding = 1) buffer Unused { uint u[]; };
 *     layout(set = 1, binding = 0) uniform sampler2D tex;
 *     void main() { a[gl_GlobalInvocationID.x] = b + uint(texture(tex, vec2(0.0)).x); }
 *   (SPIR-V 1.0: a WorkgroupSize spec composite; 1.6: LocalSizeId, and glslang lists the
 *   unused set 5 in the entry point's interface, which a pipeline layout need not have)
 *   helper: glslc -fshader-stage=comp --target-env=vulkan1.0 -O0 of
 *     #version 450
 *     layout(local_size_x = 8, local_size_y = 4) in;
 *     layout(set = 3, binding = 7) buffer S { uint s[]; };
 *     void put(uint i) { s[i] = i; }
 *     void main() { put(gl_LocalInvocationIndex); }
 *   gfx_vert / gfx_frag: glslc --target-env=vulkan1.0 -O of
 *     layout(set = 0, binding = 0) uniform M { mat4 m; }; ... gl_Position = m * pos;
 *     layout(set = 1, binding = 2) uniform sampler2D t; ... color = texture(t, gl_FragCoord.xy);
 *   two: spirv-as --target-env vulkan1.0: GLCompute entry points "a" (LocalSize 4 1 1, a
 *     uniform block at set 3 binding 0) and "b" (LocalSize 2048 1 1, set 0 binding 1). */

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "vkr_spirv.h"

static const uint32_t seed_spec10[] = {
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
static const uint32_t seed_spec16[] = {
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
static const uint32_t seed_helper[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000020, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0006000f, 0x00000005, 0x00000004, 0x6e69616d, 0x00000000, 0x00000017, 0x00060010, 0x00000004,
   0x00000011, 0x00000008, 0x00000004, 0x00000001, 0x00030003, 0x00000002, 0x000001c2, 0x000a0004,
   0x475f4c47, 0x4c474f4f, 0x70635f45, 0x74735f70, 0x5f656c79, 0x656e696c, 0x7269645f, 0x69746365,
   0x00006576, 0x00080004, 0x475f4c47, 0x4c474f4f, 0x6e695f45, 0x64756c63, 0x69645f65, 0x74636572,
   0x00657669, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000, 0x00040005, 0x0000000a, 0x28747570,
   0x003b3175, 0x00030005, 0x00000009, 0x00000069, 0x00030005, 0x0000000d, 0x00000053, 0x00040006,
   0x0000000d, 0x00000000, 0x00000073, 0x00030005, 0x0000000f, 0x00000000, 0x00080005, 0x00000017,
   0x4c5f6c67, 0x6c61636f, 0x6f766e49, 0x69746163, 0x6e496e6f, 0x00786564, 0x00040005, 0x00000018,
   0x61726170, 0x0000006d, 0x00040047, 0x0000000c, 0x00000006, 0x00000004, 0x00030047, 0x0000000d,
   0x00000003, 0x00050048, 0x0000000d, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x0000000f,
   0x00000021, 0x00000007, 0x00040047, 0x0000000f, 0x00000022, 0x00000003, 0x00040047, 0x00000017,
   0x0000000b, 0x0000001d, 0x00040047, 0x0000001f, 0x0000000b, 0x00000019, 0x00020013, 0x00000002,
   0x00030021, 0x00000003, 0x00000002, 0x00040015, 0x00000006, 0x00000020, 0x00000000, 0x00040020,
   0x00000007, 0x00000007, 0x00000006, 0x00040021, 0x00000008, 0x00000002, 0x00000007, 0x0003001d,
   0x0000000c, 0x00000006, 0x0003001e, 0x0000000d, 0x0000000c, 0x00040020, 0x0000000e, 0x00000002,
   0x0000000d, 0x0004003b, 0x0000000e, 0x0000000f, 0x00000002, 0x00040015, 0x00000010, 0x00000020,
   0x00000001, 0x0004002b, 0x00000010, 0x00000011, 0x00000000, 0x00040020, 0x00000014, 0x00000002,
   0x00000006, 0x00040020, 0x00000016, 0x00000001, 0x00000006, 0x0004003b, 0x00000016, 0x00000017,
   0x00000001, 0x00040017, 0x0000001b, 0x00000006, 0x00000003, 0x0004002b, 0x00000006, 0x0000001c,
   0x00000008, 0x0004002b, 0x00000006, 0x0000001d, 0x00000004, 0x0004002b, 0x00000006, 0x0000001e,
   0x00000001, 0x0006002c, 0x0000001b, 0x0000001f, 0x0000001c, 0x0000001d, 0x0000001e, 0x00050036,
   0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003b, 0x00000007,
   0x00000018, 0x00000007, 0x0004003d, 0x00000006, 0x00000019, 0x00000017, 0x0003003e, 0x00000018,
   0x00000019, 0x00050039, 0x00000002, 0x0000001a, 0x0000000a, 0x00000018, 0x000100fd, 0x00010038,
   0x00050036, 0x00000002, 0x0000000a, 0x00000000, 0x00000008, 0x00030037, 0x00000007, 0x00000009,
   0x000200f8, 0x0000000b, 0x0004003d, 0x00000006, 0x00000012, 0x00000009, 0x0004003d, 0x00000006,
   0x00000013, 0x00000009, 0x00060041, 0x00000014, 0x00000015, 0x0000000f, 0x00000011, 0x00000012,
   0x0003003e, 0x00000015, 0x00000013, 0x000100fd, 0x00010038,
};
static const uint32_t seed_gfx_vert[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x0000001d, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0007000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000d, 0x00000018, 0x00030047,
   0x0000000b, 0x00000002, 0x00050048, 0x0000000b, 0x00000000, 0x0000000b, 0x00000000, 0x00050048,
   0x0000000b, 0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x0000000b, 0x00000002, 0x0000000b,
   0x00000003, 0x00050048, 0x0000000b, 0x00000003, 0x0000000b, 0x00000004, 0x00030047, 0x00000011,
   0x00000002, 0x00040048, 0x00000011, 0x00000000, 0x00000005, 0x00050048, 0x00000011, 0x00000000,
   0x00000007, 0x00000010, 0x00050048, 0x00000011, 0x00000000, 0x00000023, 0x00000000, 0x00040047,
   0x00000013, 0x00000021, 0x00000000, 0x00040047, 0x00000013, 0x00000022, 0x00000000, 0x00040047,
   0x00000018, 0x0000001e, 0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
   0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040015,
   0x00000008, 0x00000020, 0x00000000, 0x0004002b, 0x00000008, 0x00000009, 0x00000001, 0x0004001c,
   0x0000000a, 0x00000006, 0x00000009, 0x0006001e, 0x0000000b, 0x00000007, 0x00000006, 0x0000000a,
   0x0000000a, 0x00040020, 0x0000000c, 0x00000003, 0x0000000b, 0x0004003b, 0x0000000c, 0x0000000d,
   0x00000003, 0x00040015, 0x0000000e, 0x00000020, 0x00000001, 0x0004002b, 0x0000000e, 0x0000000f,
   0x00000000, 0x00040018, 0x00000010, 0x00000007, 0x00000004, 0x0003001e, 0x00000011, 0x00000010,
   0x00040020, 0x00000012, 0x00000002, 0x00000011, 0x0004003b, 0x00000012, 0x00000013, 0x00000002,
   0x00040020, 0x00000014, 0x00000002, 0x00000010, 0x00040020, 0x00000017, 0x00000001, 0x00000007,
   0x0004003b, 0x00000017, 0x00000018, 0x00000001, 0x00040020, 0x0000001b, 0x00000003, 0x00000007,
   0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x00050041,
   0x00000014, 0x00000015, 0x00000013, 0x0000000f, 0x0004003d, 0x00000010, 0x00000016, 0x00000015,
   0x0004003d, 0x00000007, 0x00000019, 0x00000018, 0x00050091, 0x00000007, 0x0000001a, 0x00000016,
   0x00000019, 0x00050041, 0x0000001b, 0x0000001c, 0x0000000d, 0x0000000f, 0x0003003e, 0x0000001c,
   0x0000001a, 0x000100fd, 0x00010038,
};
static const uint32_t seed_gfx_frag[] = {
   0x07230203, 0x00010000, 0x000d000b, 0x00000015, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
   0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
   0x0007000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x00000009, 0x00000010, 0x00030010,
   0x00000004, 0x00000007, 0x00040047, 0x00000009, 0x0000001e, 0x00000000, 0x00040047, 0x0000000d,
   0x00000021, 0x00000002, 0x00040047, 0x0000000d, 0x00000022, 0x00000001, 0x00040047, 0x00000010,
   0x0000000b, 0x0000000f, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016,
   0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020, 0x00000008,
   0x00000003, 0x00000007, 0x0004003b, 0x00000008, 0x00000009, 0x00000003, 0x00090019, 0x0000000a,
   0x00000006, 0x00000001, 0x00000000, 0x00000000, 0x00000000, 0x00000001, 0x00000000, 0x0003001b,
   0x0000000b, 0x0000000a, 0x00040020, 0x0000000c, 0x00000000, 0x0000000b, 0x0004003b, 0x0000000c,
   0x0000000d, 0x00000000, 0x00040020, 0x0000000f, 0x00000001, 0x00000007, 0x0004003b, 0x0000000f,
   0x00000010, 0x00000001, 0x00040017, 0x00000011, 0x00000006, 0x00000002, 0x00050036, 0x00000002,
   0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003d, 0x0000000b, 0x0000000e,
   0x0000000d, 0x0004003d, 0x00000007, 0x00000012, 0x00000010, 0x0007004f, 0x00000011, 0x00000013,
   0x00000012, 0x00000012, 0x00000000, 0x00000001, 0x00050057, 0x00000007, 0x00000014, 0x0000000e,
   0x00000013, 0x0003003e, 0x00000009, 0x00000014, 0x000100fd, 0x00010038,
};
static const uint32_t seed_two[] = {
   0x07230203, 0x00010000, 0x00070000, 0x00000013, 0x00000000, 0x00020011, 0x00000001, 0x0003000e,
   0x00000000, 0x00000001, 0x0004000f, 0x00000005, 0x00000001, 0x00000061, 0x0004000f, 0x00000005,
   0x00000002, 0x00000062, 0x00060010, 0x00000001, 0x00000011, 0x00000004, 0x00000001, 0x00000001,
   0x00060010, 0x00000002, 0x00000011, 0x00000800, 0x00000001, 0x00000001, 0x00030047, 0x00000003,
   0x00000002, 0x00050048, 0x00000003, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x00000004,
   0x00000022, 0x00000003, 0x00040047, 0x00000004, 0x00000021, 0x00000000, 0x00040047, 0x00000005,
   0x00000022, 0x00000000, 0x00040047, 0x00000005, 0x00000021, 0x00000001, 0x00020013, 0x00000006,
   0x00030021, 0x00000007, 0x00000006, 0x00040015, 0x00000008, 0x00000020, 0x00000000, 0x00040015,
   0x00000009, 0x00000020, 0x00000001, 0x0004002b, 0x00000009, 0x0000000a, 0x00000000, 0x0003001e,
   0x00000003, 0x00000008, 0x00040020, 0x0000000b, 0x00000002, 0x00000003, 0x00040020, 0x0000000c,
   0x00000002, 0x00000008, 0x0004003b, 0x0000000b, 0x00000004, 0x00000002, 0x0004003b, 0x0000000b,
   0x00000005, 0x00000002, 0x00050036, 0x00000006, 0x00000001, 0x00000000, 0x00000007, 0x000200f8,
   0x0000000d, 0x00050041, 0x0000000c, 0x0000000e, 0x00000004, 0x0000000a, 0x0004003d, 0x00000008,
   0x0000000f, 0x0000000e, 0x000100fd, 0x00010038, 0x00050036, 0x00000006, 0x00000002, 0x00000000,
   0x00000007, 0x000200f8, 0x00000010, 0x00050041, 0x0000000c, 0x00000011, 0x00000005, 0x0000000a,
   0x0004003d, 0x00000008, 0x00000012, 0x00000011, 0x000100fd, 0x00010038,
};

#define LEN(a) (sizeof(a) / sizeof((a)[0]))

static const struct {
   const char *name;
   const uint32_t *words;
   size_t count;
} seeds[] = {
   { "spec10", seed_spec10, LEN(seed_spec10) },     { "spec16", seed_spec16, LEN(seed_spec16) },
   { "helper", seed_helper, LEN(seed_helper) },     { "gfx_vert", seed_gfx_vert, LEN(seed_gfx_vert) },
   { "gfx_frag", seed_gfx_frag, LEN(seed_gfx_frag) }, { "two", seed_two, LEN(seed_two) },
};

static int failures;

static void
check(bool ok, const char *what)
{
   if (!ok) {
      printf("FAIL %s\n", what);
      failures++;
   }
}

/* the scan of a copy in a heap block of exactly `bytes` bytes (reads past it fault) */
static struct vkr_spirv_info *
scan_copy(const uint32_t *words, size_t bytes, char *why, size_t why_size)
{
   void *copy = malloc(bytes ? bytes : 1);
   if (bytes)
      memcpy(copy, words, bytes);
   struct vkr_spirv_info *info = vkr_spirv_scan(copy, bytes, why, why_size);
   free(copy);
   return info;
}

/* specialization: SpecId 0 -> spec[0], SpecId 1 -> spec[1] */
static bool
lookup(const void *data, uint32_t spec_id, uint32_t *value)
{
   const uint32_t *spec = data;
   if (!spec || spec_id > 1)
      return false;
   *value = spec[spec_id];
   return true;
}

struct seen {
   uint32_t n;
   uint32_t pairs[16][2];
   uint32_t refuse_after; /* refuse the binding after this many, UINT32_MAX for none */
};

static bool
record(const void *data, uint32_t set, uint32_t binding)
{
   struct seen *s = (struct seen *)data;
   for (uint32_t i = 0; i < s->n && i < 16; i++) {
      if (s->pairs[i][0] == set && s->pairs[i][1] == binding)
         return true;
   }
   if (s->n == s->refuse_after)
      return false;
   if (s->n < 16) {
      s->pairs[s->n][0] = set;
      s->pairs[s->n][1] = binding;
   }
   s->n++;
   return true;
}

/* the entry's bindings are exactly `want` (pairs, any order) */
static bool
bindings_are(const struct vkr_spirv_info *info, const struct vkr_spirv_entry *e, uint32_t count,
             const uint32_t want[][2])
{
   struct seen s = { .refuse_after = UINT32_MAX };
   uint32_t set, binding;
   if (!vkr_spirv_bindings_ok(info, e, record, &s, &set, &binding) || s.n != count)
      return false;
   for (uint32_t i = 0; i < count; i++) {
      bool found = false;
      for (uint32_t j = 0; j < s.n && j < 16; j++)
         found |= s.pairs[j][0] == want[i][0] && s.pairs[j][1] == want[i][1];
      if (!found)
         return false;
   }
   return true;
}

static bool
size_is(const struct vkr_spirv_info *info, const struct vkr_spirv_entry *e, const uint32_t *spec,
        uint32_t x, uint32_t y, uint32_t z)
{
   uint32_t size[3];
   return vkr_spirv_workgroup_size(info, e, lookup, spec, size) && size[0] == x && size[1] == y &&
          size[2] == z;
}

static void
part_seeds(void)
{
   char why[192];
   static const uint32_t spec[2] = { 64, 4 };
   for (size_t i = 0; i < LEN(seeds); i++) {
      struct vkr_spirv_info *info = scan_copy(seeds[i].words, seeds[i].count * 4, why, sizeof(why));
      if (!info) {
         printf("FAIL seed %s refused: %s\n", seeds[i].name, why);
         failures++;
         continue;
      }
      const char *n = seeds[i].name;
      if (!strcmp(n, "spec10") || !strcmp(n, "spec16")) {
         const struct vkr_spirv_entry *e = vkr_spirv_entry(info, "main", 5);
         static const uint32_t want[][2] = { { 0, 0 }, { 2, 3 }, { 1, 0 } };
         check(e && size_is(info, e, NULL, 1, 2, 1), "spec: default workgroup 1 x 2 x 1");
         check(e && size_is(info, e, spec, 64, 2, 4), "spec: specialized workgroup 64 x 2 x 4");
         check(e && bindings_are(info, e, 3, want), "spec: sets 0, 2, 1 used, unused set 5 not");
         check(!vkr_spirv_entry(info, "main", 0) && !vkr_spirv_entry(info, "mai", 5),
               "spec: no vertex main, no \"mai\"");
      } else if (!strcmp(n, "helper")) {
         const struct vkr_spirv_entry *e = vkr_spirv_entry(info, "main", 5);
         static const uint32_t want[][2] = { { 3, 7 } };
         check(e && size_is(info, e, spec, 8, 4, 1), "helper: workgroup 8 x 4 x 1");
         check(e && bindings_are(info, e, 1, want), "helper: set 3 binding 7 through a call");
      } else if (!strcmp(n, "gfx_vert") || !strcmp(n, "gfx_frag")) {
         const bool vert = !strcmp(n, "gfx_vert");
         const struct vkr_spirv_entry *e = vkr_spirv_entry(info, "main", vert ? 0 : 4);
         static const uint32_t want_v[][2] = { { 0, 0 } }, want_f[][2] = { { 1, 2 } };
         check(e && bindings_are(info, e, 1, vert ? want_v : want_f), "gfx: its one binding");
      } else if (!strcmp(n, "two")) {
         const struct vkr_spirv_entry *a = vkr_spirv_entry(info, "a", 5), *b = vkr_spirv_entry(info, "b", 5);
         static const uint32_t want_a[][2] = { { 3, 0 } }, want_b[][2] = { { 0, 1 } };
         check(a && b && a != b, "two: entry points a and b");
         check(a && size_is(info, a, NULL, 4, 1, 1) && b && size_is(info, b, NULL, 2048, 1, 1),
               "two: workgroups 4 and 2048 (the pipeline refuses 2048, not the scan)");
         check(a && bindings_are(info, a, 1, want_a) && b && bindings_are(info, b, 1, want_b),
               "two: each entry point its own set");
         struct seen s = { .refuse_after = 0 };
         uint32_t set = 0, binding = 0;
         check(a && !vkr_spirv_bindings_ok(info, a, record, &s, &set, &binding) && set == 3 && binding == 0,
               "two: a refused binding comes back");
      }
      vkr_spirv_free(info);
   }
}

/* `bytes` of words is refused for the reason `expect` */
static void
refused_words(const char *what, const uint32_t *w, size_t bytes, const char *expect)
{
   char why[192] = "";
   struct vkr_spirv_info *info = scan_copy(w, bytes, why, sizeof(why));
   if (info) {
      printf("FAIL %s: accepted\n", what);
      failures++;
      vkr_spirv_free(info);
   } else if (!strstr(why, expect)) {
      printf("FAIL %s: refused as \"%s\", not \"%s\"\n", what, why, expect);
      failures++;
   }
}

/* a copy of a seed with word `at` replaced, cut to `bytes`, is refused for `expect` */
static void
refused(const char *what, const uint32_t *base, size_t count, size_t at, uint32_t value, size_t bytes,
        const char *expect)
{
   uint32_t *w = malloc(count * 4 + 4);
   memcpy(w, base, count * 4);
   if (at < count)
      w[at] = value;
   refused_words(what, w, bytes, expect);
   free(w);
}

/* the word index of the first instruction with opcode `op`, or 0 */
static size_t
find_op(const uint32_t *w, size_t count, uint32_t op)
{
   for (size_t at = 5; at < count && (w[at] >> 16);) {
      if ((w[at] & 0xffff) == op)
         return at;
      at += w[at] >> 16;
   }
   return 0;
}

static void
part_refusals(void)
{
   const uint32_t *s = seed_helper;
   const size_t n = LEN(seed_helper), bytes = n * 4;
   char why[192];
   check(!vkr_spirv_scan(NULL, 0, why, sizeof(why)), "NULL code refused");
   const char *shortw = "shorter than its header or not whole words";
   refused("empty", s, n, n, 0, 0, shortw);
   refused("3 bytes", s, n, n, 0, 3, shortw);
   refused("a header of 4 words", s, n, n, 0, 16, shortw);
   refused("not whole words", s, n, n, 0, bytes - 2, shortw);
   refused("bad magic", s, n, 0, 0x03022307, bytes, "not SPIR-V (magic)");
   refused("version 2.0", s, n, 1, 0x00020000, bytes, "an unknown SPIR-V version");
   refused("version 1.7", s, n, 1, 0x00010700, bytes, "an unknown SPIR-V version");
   refused("id bound 0", s, n, 3, 0, bytes, "id bound");
   refused("id bound 0x3fffffff (KosmicKrisp's crash)", s, n, 3, 0x3fffffff, bytes, "id bound");
   refused("id bound past the cap", s, n, 3, VKR_SPIRV_MAX_BOUND + 1, bytes, "id bound");
   refused("schema 1", s, n, 4, 1, bytes, "schema");
   refused("an instruction of 0 words", s, n, 5, 0x00000011, bytes, "past the end of the code");
   refused("an instruction past the end", s, n, n - 1, 0x00020038, bytes, "past the end of the code");
   const size_t entry = find_op(s, n, 15), entry_len = s[entry] >> 16;
   check(entry != 0 && entry_len > 5, "helper has an entry point with an interface");
   /* the entry point turned into an OpNop of its size: no entry point */
   refused("no entry point", s, n, entry, s[entry] & 0xffff0000u, bytes, "no entry point");
   refused("an entry point's function past the bound", s, n, entry + 2, s[3], bytes,
           "an entry point without a function or name");
   {
      /* "main" and its NUL word, then the interface: no zero byte to the instruction's end */
      uint32_t *w = malloc(bytes);
      memcpy(w, s, bytes);
      for (size_t i = entry + 4; i < entry + entry_len; i++)
         w[i] = 0x41414141;
      refused_words("an entry point name without its end", w, bytes, "name that does not end");
      free(w);
   }
   const size_t mode = find_op(s, n, 16);
   refused("a LocalSize of two values", s, n, mode, (s[mode] & 0xffff) | (5u << 16), bytes,
           "a workgroup size without three values");
   const size_t comp = find_op(seed_spec10, LEN(seed_spec10), 51);
   check(comp != 0, "spec10 has a spec composite");
   {
      /* spec10's WorkgroupSize composite cut to two values, an OpNop after it */
      uint32_t *w = malloc(sizeof(seed_spec10));
      memcpy(w, seed_spec10, sizeof(seed_spec10));
      w[comp] = (5u << 16) | 51;
      w[comp + 5] = (1u << 16) | 0;
      refused_words("a WorkgroupSize of two values", w, sizeof(seed_spec10), "WorkgroupSize");
      free(w);
   }
}

static uint64_t rng;

static uint32_t
next(void)
{
   rng ^= rng >> 12;
   rng ^= rng << 25;
   rng ^= rng >> 27;
   return (uint32_t)((rng * 0x2545F4914F6CDD1Dull) >> 32);
}

static uint32_t
pick(uint32_t n)
{
   return n ? next() % n : 0;
}

static const uint32_t ops[] = { 0, 15, 16, 43, 44, 50, 51, 54, 56, 57, 59, 60, 61, 62, 63, 64, 65,
                                66, 67, 68, 71, 83, 169, 228, 234, 245, 319, 331, 401, 4457, 6035 };

static uint32_t
interesting(uint32_t bound)
{
   static const uint32_t v[] = { 0, 1, 2, 3, 4, 5, 6, 17, 25, 33, 34, 38, 0xffff, 0x10000,
                                 0x7fffffff, 0x80000000, 0xfffffffe, 0xffffffff, 0x07230203 };
   switch (pick(4)) {
   case 0:
      return v[pick(LEN(v))];
   case 1:
      return bound - 1 + pick(3);
   case 2:
      return (pick(8) << 16) | ops[pick(LEN(ops))];
   default:
      return 1 + pick(bound ? bound : 1);
   }
}

static void
use_summary(const struct vkr_spirv_info *info)
{
   const uint32_t spec[2] = { next(), next() };
   for (uint32_t i = 0; i < info->entry_count; i++) {
      const struct vkr_spirv_entry *e = &info->entries[i];
      const char *name = info->names + e->name;
      if (vkr_spirv_entry(info, name, e->model) == NULL) {
         printf("FAIL an entry point \"%s\" not found by its own name\n", name);
         failures++;
      }
      uint32_t size[3], set, binding;
      vkr_spirv_workgroup_size(info, e, lookup, pick(2) ? spec : NULL, size);
      struct seen s = { .refuse_after = pick(3) ? UINT32_MAX : pick(4) };
      vkr_spirv_bindings_ok(info, e, record, &s, &set, &binding);
   }
}

static void
part_mutations(uint32_t iterations)
{
   uint32_t accepted = 0;
   uint32_t *w = malloc((4096 + 64) * 4);
   for (uint32_t it = 0; it < iterations; it++) {
      const size_t si = pick(LEN(seeds));
      size_t n = seeds[si].count;
      memcpy(w, seeds[si].words, n * 4);
      const uint32_t bound = w[3];
      for (uint32_t m = 1 + pick(8); m; m--) {
         const size_t at = pick((uint32_t)n);
         switch (pick(9)) {
         case 0:
            if (n)
               w[at] ^= 1u << pick(32);
            break;
         case 1:
            if (n)
               w[at] = interesting(bound);
            break;
         case 2:
            if (n)
               w[at] = next();
            break;
         case 3:
            n = pick((uint32_t)n + 1);
            break;
         case 4:
            if (n < 4096) {
               memmove(&w[at + 1], &w[at], (n - at) * 4);
               w[at] = interesting(bound);
               n++;
            }
            break;
         case 5:
            if (n) {
               memmove(&w[at], &w[at + 1], (n - at - 1) * 4);
               n--;
            }
            break;
         case 6: {
            const size_t from = pick((uint32_t)n), len = pick(16);
            if (n && from + len <= n && at + len <= n)
               memmove(&w[at], &w[from], len * 4);
            break;
         }
         case 7:
         case 8: {
            /* an instruction header: its opcode, or its length */
            size_t h = 5, target = pick(64);
            while (target-- && h < n && (w[h] >> 16) && h + (w[h] >> 16) < n)
               h += w[h] >> 16;
            if (h < n) {
               if (m & 1)
                  w[h] = (w[h] & 0xffff0000u) | ops[pick(LEN(ops))];
               else
                  w[h] = (w[h] & 0xffffu) | ((uint32_t)pick(12) << 16);
            }
            break;
         }
         }
      }
      char why[192];
      const size_t bytes = n * 4 - (pick(16) ? 0 : (n ? 1 + pick(3) : 0));
      struct vkr_spirv_info *info = scan_copy(w, bytes, why, sizeof(why));
      if (info) {
         accepted++;
         use_summary(info);
         vkr_spirv_free(info);
      }
   }
   free(w);
   printf("mutations: %u, accepted %u, refused %u\n", iterations, accepted, iterations - accepted);
}

/* header, one entry point, then the joined kinds at scale; returns the word count */
static size_t
build_big(uint32_t *w, uint32_t functions, uint32_t extra)
{
   size_t n = 0;
   const uint32_t bound = VKR_SPIRV_MAX_BOUND;
   w[n++] = 0x07230203;
   w[n++] = 0x00010000;
   w[n++] = 0;
   w[n++] = bound;
   w[n++] = 0;
   /* OpEntryPoint GLCompute %1 "main" */
   w[n++] = (5u << 16) | 15;
   w[n++] = 5;
   w[n++] = 1;
   memcpy(&w[n], "main\0\0\0", 8);
   n += 2;
   /* SpecId and DescriptorSet decorations, spec constants (ids from 2^19 up) */
   for (uint32_t i = 0; i < extra; i++) {
      const uint32_t id = (1u << 19) + i;
      w[n++] = (4u << 16) | 71;
      w[n++] = id;
      w[n++] = i & 1 ? 34 : 1;
      w[n++] = i;
      w[n++] = (4u << 16) | 50;
      w[n++] = 3;
      w[n++] = id;
      w[n++] = i;
   }
   /* functions 1.. each calling the next and loading from a descriptor variable */
   for (uint32_t f = 1; f <= functions; f++) {
      w[n++] = (5u << 16) | 54;
      w[n++] = 2;
      w[n++] = f;
      w[n++] = 0;
      w[n++] = 4;
      if (f < functions) {
         w[n++] = (4u << 16) | 57;
         w[n++] = 2;
         w[n++] = (1u << 18) + f;
         w[n++] = f + 1;
      }
      w[n++] = (4u << 16) | 61;
      w[n++] = 2;
      w[n++] = (1u << 18) + (1u << 17) + f;
      w[n++] = (1u << 19) + 1 + 2 * (f % (extra / 2));
      w[n++] = (1u << 16) | 56;
   }
   return n;
}

static void
part_scale(void)
{
   const uint32_t functions = 1u << 17, extra = 1u << 17;
   uint32_t *w = malloc(((size_t)extra * 8 + (size_t)functions * 14 + 16) * 4);
   const size_t n = build_big(w, functions, extra);
   char why[192];
   const clock_t t0 = clock();
   struct vkr_spirv_info *info = scan_copy(w, n * 4, why, sizeof(why));
   const clock_t t1 = clock();
   const struct vkr_spirv_entry *e = info ? vkr_spirv_entry(info, "main", 5) : NULL;
   struct seen s = { .refuse_after = UINT32_MAX };
   uint32_t set, binding;
   const bool walked = e && vkr_spirv_bindings_ok(info, e, record, &s, &set, &binding);
   const clock_t t2 = clock();
   const double scan_s = (double)(t1 - t0) / CLOCKS_PER_SEC, walk_s = (double)(t2 - t1) / CLOCKS_PER_SEC;
   printf("scale: %zu words, %u functions: scan %.3f s, walk %.3f s, %u bindings\n", n, functions,
          scan_s, walk_s, s.n);
   check(info && walked, "scale: the big module scans and walks");
   check(scan_s < 10 && walk_s < 10, "scale: under 10 s each (sanitized build)");
   vkr_spirv_free(info);
   free(w);
}

int
main(int argc, char **argv)
{
   const uint32_t iterations = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 0) : 200000;
   rng = argc > 2 ? strtoull(argv[2], NULL, 0) : 1;
   if (!rng)
      rng = 1;
   part_seeds();
   part_refusals();
   part_mutations(iterations);
   part_scale();
   printf("%s (%d failures)\n", failures ? "FAIL" : "ok", failures);
   return failures ? 1 : 0;
}
