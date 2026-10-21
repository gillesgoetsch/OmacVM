/* cllaunch: the cost of one small GPU job through OpenCL, end to end (the twin of vklaunch).
 *   sync   enqueue one kernel (64 work items add 1 to a buffer) + clFinish, N times
 *   batch  1000 enqueues, one clFinish (per launch)
 * Prints JSON lines (median, p10, p90 microseconds) and checks the buffer.
 * Usage: cllaunch [N=2000] [platform index]
 * Build: Linux cc -O2 -o cllaunch cllaunch.c -lOpenCL; macOS cc -O2 -o cllaunch cllaunch.c -framework OpenCL
 */
#define CL_TARGET_OPENCL_VERSION 120
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef __APPLE__
#include <OpenCL/opencl.h>
#else
#include <CL/cl.h>
#endif

#define CK(x) do { cl_int r_ = (x); if (r_ != CL_SUCCESS) { fprintf(stderr, "%s failed: %d (line %d)\n", #x, r_, __LINE__); exit(1); } } while (0)
static double now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static void report(const char *mode, const char *dev, double *v, int n, double per) {
  qsort(v, n, sizeof *v, cmpd);
  printf("{\"test\":\"cllaunch\",\"mode\":\"%s\",\"device\":\"%s\",\"n\":%d,\"median_us\":%.2f,\"p10_us\":%.2f,\"p90_us\":%.2f}\n",
         mode, dev, n, v[n / 2] / per, v[n / 10] / per, v[n * 9 / 10] / per);
  fflush(stdout);
}
static const char *src = "kernel void inc(global uint *v) { v[get_global_id(0)] += 1u; }";

int main(int argc, char **argv) {
  int N = argc > 1 ? atoi(argv[1]) : 2000, pw = argc > 2 ? atoi(argv[2]) : -1;
  if (N < 1) { fprintf(stderr, "N must be 1 or more\n"); return 2; }
  cl_uint np = 0; CK(clGetPlatformIDs(0, NULL, &np));
  cl_platform_id ps[8]; if (np > 8) np = 8; CK(clGetPlatformIDs(np, ps, NULL));
  cl_device_id d = NULL; char name[256] = "", pname[128] = "";
  for (cl_uint i = 0; i < np && !d; i++) {
    if (pw >= 0 && (int)i != pw) continue;
    cl_uint nd = 0;
    if (clGetDeviceIDs(ps[i], CL_DEVICE_TYPE_GPU, 1, &d, &nd) != CL_SUCCESS || !nd) d = NULL;
    else clGetPlatformInfo(ps[i], CL_PLATFORM_NAME, sizeof pname, pname, NULL);
  }
  if (!d) { fprintf(stderr, "no GPU device\n"); return 1; }
  clGetDeviceInfo(d, CL_DEVICE_NAME, sizeof name, name, NULL);
  char label[400]; snprintf(label, sizeof label, "%s / %s", pname, name);
  for (char *c = label; *c; c++) if (*c == '"' || *c == '\\') *c = ' ';
  cl_int e; cl_context ctx = clCreateContext(NULL, 1, &d, NULL, NULL, &e); CK(e);
  cl_command_queue q = clCreateCommandQueue(ctx, d, 0, &e); CK(e);
  cl_program p = clCreateProgramWithSource(ctx, 1, &src, NULL, &e); CK(e);
  if (clBuildProgram(p, 1, &d, "", NULL, NULL) != CL_SUCCESS) {
    char log[4096] = ""; clGetProgramBuildInfo(p, d, CL_PROGRAM_BUILD_LOG, sizeof log, log, NULL); fprintf(stderr, "build: %s\n", log); return 1;
  }
  cl_kernel k = clCreateKernel(p, "inc", &e); CK(e);
  uint32_t zero[64] = {0};
  cl_mem buf = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, sizeof zero, zero, &e); CK(e);
  CK(clSetKernelArg(k, 0, sizeof buf, &buf));
  size_t g = 64, l = 64; uint64_t expect = 0;
  double *v = malloc(sizeof(double) * (N > 20 ? N : 20));
  for (int i = 0; i < 50; i++) { CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clFinish(q)); expect++; }
  for (int i = 0; i < N; i++) {
    double t = now_us();
    CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL)); CK(clFinish(q));
    v[i] = now_us() - t; expect++;
  }
  report("sync", label, v, N, 1);
  for (int i = 0; i < 20; i++) {
    double t = now_us();
    for (int j = 0; j < 1000; j++) CK(clEnqueueNDRangeKernel(q, k, 1, NULL, &g, &l, 0, NULL, NULL));
    CK(clFinish(q)); v[i] = now_us() - t; expect += 1000;
  }
  report("batch", label, v, 20, 1000);
  uint32_t out[64]; CK(clEnqueueReadBuffer(q, buf, CL_TRUE, 0, sizeof out, out, 0, NULL, NULL));
  int bad = 0; for (int i = 0; i < 64; i++) if (out[i] != (uint32_t)expect) bad++;
  printf("{\"test\":\"cllaunch\",\"mode\":\"check\",\"device\":\"%s\",\"expect\":%llu,\"got\":%u,\"ok\":%s}\n", label,
         (unsigned long long)expect, out[0], bad ? "false" : "true");
  return bad ? 2 : 0;
}
