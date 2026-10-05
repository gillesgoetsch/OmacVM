/* Replays fuzz inputs without libFuzzer, so every runtime build runs them:
 * fuzz-replay FILE... (each input once, in a fresh context, as the fuzzer does). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv)
{
   LLVMFuzzerInitialize(&argc, &argv);
   for (int i = 1; i < argc; i++) {
      FILE *f = fopen(argv[i], "rb");
      if (!f) {
         printf("FAIL: cannot read %s\n", argv[i]);
         return 1;
      }
      static uint8_t data[1 << 20];
      size_t size = fread(data, 1, sizeof(data), f);
      fclose(f);
      LLVMFuzzerTestOneInput(data, size);
      printf("ok: %s\n", argv[i]);
   }
   printf("fuzz regressions: %d inputs replayed\n", argc - 1);
   return 0;
}
