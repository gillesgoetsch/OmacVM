// Copyright 2026 OmacVM contributors
// SPDX-License-Identifier: MIT
//
// The SPIR-V extensions Venus offers through its Vulkan extensions are ones the runtime's
// SPIRV-Tools knows (virgl-venus-spirv-validate.patch, #624). spirv-val only warns on an
// OpExtension it does not know, then refuses the module at the first instruction or
// capability of it: a real module of a newer extension would end its app. For each SPIR-V
// extension in venus-spirv-extensions.tsv (vk.xml's <spirvextensions> for each Vulkan
// extension vkr_common.c's table offers) a module declaring it is validated and must give
// no "unrecognized extension" message.
//   test-venus-spirv-extensions venus-spirv-extensions.tsv
#include <spirv-tools/libspirv.hpp>

#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

int
main(int argc, char **argv)
{
   if (argc != 2)
      return 2;
   std::ifstream in(argv[1]);
   std::set<std::string> names;
   std::string line;
   unsigned rows = 0;
   while (std::getline(in, line)) {
      if (line.empty() || line[0] == '#')
         continue;
      rows++;
      std::istringstream fields(line);
      std::string vk, spv;
      std::getline(fields, vk, '\t');
      std::getline(fields, spv, '\t');
      std::istringstream list(spv);
      std::string name;
      while (std::getline(list, name, ',')) {
         if (name != "-" && !name.empty())
            names.insert(name);
      }
   }
   if (rows < 100) {
      std::printf("FAIL: %s has %u rows\n", argv[1], rows);
      return 1;
   }
   int failures = 0;
   for (const std::string &name : names) {
      const std::string text = "OpCapability Shader\nOpExtension \"" + name +
                               "\"\nOpMemoryModel Logical GLSL450\n"
                               "OpEntryPoint GLCompute %main \"main\"\n"
                               "OpExecutionMode %main LocalSize 1 1 1\n"
                               "%void = OpTypeVoid\n%fn = OpTypeFunction %void\n"
                               "%main = OpFunction %void None %fn\n%l = OpLabel\nOpReturn\n"
                               "OpFunctionEnd\n";
      spvtools::SpirvTools tools(SPV_ENV_VULKAN_1_4);
      std::string messages;
      tools.SetMessageConsumer([&](spv_message_level_t, const char *, const spv_position_t &,
                                   const char *m) { messages += m; });
      std::vector<uint32_t> binary;
      if (!tools.Assemble(text, &binary)) {
         std::printf("FAIL: %s: the test module does not assemble: %s\n", name.c_str(),
                     messages.c_str());
         failures++;
         continue;
      }
      tools.Validate(binary);
      if (messages.find("nrecognized extension") != std::string::npos) {
         std::printf("FAIL: SPIRV-Tools does not know %s (vkr offers it: hide its Vulkan "
                     "extension or update SPIRV-Tools)\n",
                     name.c_str());
         failures++;
      }
   }
   std::printf("extensions: %s: %zu SPIR-V extensions of %u offered Vulkan extensions\n",
               failures ? "FAIL" : "SPIRV-Tools knows all", names.size(), rows);
   return failures != 0;
}
