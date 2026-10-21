// mtllaunch: the Mac's own cost of one small GPU job through Metal (the reference for vklaunch/cllaunch).
//   sync   one dispatch (64 threads add 1 to a buffer) in its own command buffer, commit + waitUntilCompleted, N times
//   rec64  64 dispatches (barrier between) recorded, commit + wait, N/4 times
//   batch  1000 dispatches in one command buffer (per dispatch)
// Build: cc -O2 -fobjc-arc -o mtllaunch mtllaunch.m -framework Metal -framework Foundation
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdlib.h>
#include <time.h>

static double now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void report(const char *mode, const char *dev, double *v, int n, double per) {
  qsort(v, n, sizeof *v, cmpd);
  printf("{\"test\":\"mtllaunch\",\"mode\":\"%s\",\"device\":\"%s\",\"n\":%d,\"median_us\":%.2f,\"p10_us\":%.2f,\"p90_us\":%.2f}\n",
         mode, dev, n, v[n / 2] / per, v[n / 10] / per, v[n * 9 / 10] / per);
  fflush(stdout);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    int N = argc > 1 ? atoi(argv[1]) : 2000;
    if (N < 1) { fprintf(stderr, "N must be 1 or more\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"kernel void inc(device uint *v [[buffer(0)]], uint i [[thread_position_in_grid]]) { v[i] += 1u; }"
                                           options:nil error:&err];
    if (!lib) { fprintf(stderr, "%s\n", err.description.UTF8String); return 1; }
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"inc"] error:&err];
    id<MTLBuffer> buf = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    memset(buf.contents, 0, 256);
    id<MTLCommandQueue> q = [dev newCommandQueue];
    const char *dn = dev.name.UTF8String;
    /* v holds N sync times, max(N / 4, 50) rec64 times and 20 batch times */
    double *v = malloc(sizeof(double) * (N > 50 ? N : 50));
    unsigned long long expect = 0;
    void (^run)(int) = ^(int k) {
      @autoreleasepool {
        id<MTLCommandBuffer> cb = [q commandBufferWithUnretainedReferences];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps]; [enc setBuffer:buf offset:0 atIndex:0];
        for (int j = 0; j < k; j++) {
          if (j) [enc memoryBarrierWithScope:MTLBarrierScopeBuffers];
          [enc dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        }
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
      }
    };
    for (int i = 0; i < 50; i++) { run(1); expect++; }
    for (int i = 0; i < N; i++) { double t = now_us(); run(1); v[i] = now_us() - t; expect++; }
    report("sync", dn, v, N, 1);
    int M = N / 4 > 50 ? N / 4 : 50;
    for (int i = 0; i < M; i++) { double t = now_us(); run(64); v[i] = now_us() - t; expect += 64; }
    report("rec64", dn, v, M, 1);
    for (int i = 0; i < 20; i++) { double t = now_us(); run(1000); v[i] = now_us() - t; expect += 1000; }
    report("batch", dn, v, 20, 1000);
    uint32_t *m = buf.contents; int bad = 0; for (int i = 0; i < 64; i++) if (m[i] != (uint32_t)expect) bad++;
    printf("{\"test\":\"mtllaunch\",\"mode\":\"check\",\"device\":\"%s\",\"expect\":%llu,\"got\":%u,\"ok\":%s}\n", dn, expect, m[0], bad ? "false" : "true");
    return bad ? 2 : 0;
  }
}
