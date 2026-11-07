/*
 * Copyright 2026 OmacVM contributors
 * SPDX-License-Identifier: MIT
 */

/* vkr_spirv_validate.c and vkr_spirv.c's Function and Private element count, Workgroup
 * bytes, interface locations and type cost (patches/virgl-venus-spirv-validate.patch, virgl-venus-spirv-scan.patch,
 * spirv-tools-val-*.patch, ADR 0065) on the CPU alone: no Vulkan driver, no GPU.
 * test-venus-spirv-validate.sh builds it against the pinned SPIRV-Tools, also under
 * AddressSanitizer, and runs, each module under a 512 MB footprint cap (STANDARDS 14c):
 *   pass PROFILE FILE...     every module passes the scan, the interface limits, spirv-val,
 *                            the element cap and the Workgroup bytes, and with a FILE.lay
 *                            beside it vkr's pipeline checks; a module of a SPIR-V version
 *                            past the target's is refused by spirv-val instead
 *   refuse PROFILE FILE...   every module is refused by one of them (each crashed a Mac
 *                            driver: KosmicKrisp or MoltenVK ended the process or hung; or
 *                            took spirv-val past 512 MB, 2 s or the process)
 * FILE.lay: the pipeline the module was made into ("stage comp", "entry main", "bind SET
 * BINDING TYPE COUNT" for each layout binding), checked as vkr_stage_shader_ok does: the
 * entry point for the stage, the workgroup size inside an Apple GPU's limits (1024 per
 * axis, 1024 in all), every set and binding the entry point's functions use in the
 * layout.
 *   run PROFILE FILE...      every module through all of them, no expectation (under
 *                            AddressSanitizer: the validator on hostile input)
 *   time PROFILE REPS FILE...  microseconds per spirv-val run (cache off), median of REPS
 *   units FILE               targets (their interface limits from the drivers' own), the
 *                            cache (hits, LRU order, eviction, threads) on a module that
 *                            passes, the Function and Private element cases, the Workgroup
 *                            bytes, the variables one entry point gets, the interface
 *                            locations of each model, the
 *                            type cost and explicit layout per storage class
 * PROFILE: kk or mvk (what the 3.2.20 drivers report on an M4: Vulkan 1.4, scalar and
 * standard layouts, LocalSizeId, relaxed layout; KosmicKrisp also scalar workgroup
 * layout), mvk11 (MoltenVK under an app that asks for Vulkan 1.0 or 1.1: its device then
 * reports 1.1, with VK_KHR_spirv_1_4), or the plain targets 1.1, 1.1spv1.4, 1.2, 1.3, 1.4. */

#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <spirv-tools/libspirv.h>

#include "vkr_spirv.h"
#include "vkr_spirv_validate.h"

/* maxComputeSharedMemorySize of both Mac drivers on an M4 (out2/limits-*.txt) */
#define SHARED_MAX 32768u

#define API(major, minor) (((uint32_t)(major) << 22) | ((uint32_t)(minor) << 12))

static int failures;

#define CHECK(cond, ...)                                                                     \
   do {                                                                                      \
      if (!(cond)) {                                                                         \
         printf("FAIL: " __VA_ARGS__);                                                       \
         printf("\n");                                                                       \
         failures++;                                                                         \
      }                                                                                      \
   } while (0)

/* the interface limits both drivers report on an M4 (out2/limits-*.txt; MoltenVK: 124
 * components, no geometry shaders), as VkPhysicalDeviceLimits gives them to
 * vkr_physical_device_init_spirv_target */
static const struct vkr_spirv_device_io
   kk_io = { 32, 128, 128, 128, 120, 128, 128, 128, 128, 128, 8 },
   mvk_io = { 31, 124, 124, 124, 120, 124, 124, 0, 0, 124, 8 };

static bool
profile(const char *name, struct vkr_spirv_target *t)
{
   const uint32_t common = VKR_SPIRV_SCALAR_LAYOUT | VKR_SPIRV_STD_UNIFORM_LAYOUT |
                           VKR_SPIRV_LOCAL_SIZE_ID | VKR_SPIRV_RELAXED_LAYOUT;
   if (!strcmp(name, "kk"))
      return vkr_spirv_target_init(t, API(1, 4), true,
                                   common | VKR_SPIRV_WORKGROUP_SCALAR_LAYOUT |
                                      VKR_SPIRV_INTERFACE_GLOBALS,
                                   &kk_io);
   if (!strcmp(name, "mvk") || !strcmp(name, "mvk11"))
      return vkr_spirv_target_init(t, name[3] ? API(1, 1) : API(1, 4), true, common, &mvk_io);
   if (!strcmp(name, "1.1"))
      return vkr_spirv_target_init(t, API(1, 1), false, 0, NULL);
   if (!strcmp(name, "1.1spv1.4"))
      return vkr_spirv_target_init(t, API(1, 1), true, 0, NULL);
   if (!strcmp(name, "1.2"))
      return vkr_spirv_target_init(t, API(1, 2), true, 0, NULL);
   if (!strcmp(name, "1.3"))
      return vkr_spirv_target_init(t, API(1, 3), true, 0, NULL);
   if (!strcmp(name, "1.4"))
      return vkr_spirv_target_init(t, API(1, 4), true, 0, NULL);
   return false;
}

static uint32_t *
load(const char *path, size_t *bytes)
{
   FILE *f = fopen(path, "rb");
   if (!f)
      return NULL;
   fseek(f, 0, SEEK_END);
   const long n = ftell(f);
   fseek(f, 0, SEEK_SET);
   uint32_t *w = n > 0 ? malloc((size_t)n) : NULL;
   if (w && fread(w, 1, (size_t)n, f) != (size_t)n) {
      free(w);
      w = NULL;
   }
   fclose(f);
   *bytes = w ? (size_t)n : 0;
   return w;
}

/* the newest SPIR-V version a target takes (word 1 of a module) */
static uint32_t
target_spirv(const struct vkr_spirv_target *t)
{
   return t->env == SPV_ENV_VULKAN_1_1             ? 0x10300
          : t->env == SPV_ENV_VULKAN_1_1_SPIRV_1_4 ? 0x10400
          : t->env == SPV_ENV_VULKAN_1_2           ? 0x10500
                                                   : 0x10600;
}

/* scan, the interface limits and spirv-val, element cap and Workgroup bytes (no
 * specialization: the defaults), pipeline checks: 0 passed, else which refused (BY_UNSAFE:
 * before spirv-val read it, or an exception inside it) */
enum { PASSED, BY_SCAN, BY_VALIDATOR, BY_ELEMENTS, BY_PIPELINE, BY_UNSAFE };

/* vkr_spirv_validate after the scan, as vkr calls it (a module the scan refuses is checked
 * with an empty summary: no interface variables) */
static bool
validate(const struct vkr_spirv_target *t, const uint32_t *code, size_t bytes, char *why,
         size_t why_size, bool *unsafe)
{
   static const struct vkr_spirv_info empty;
   char scan_why[64];
   struct vkr_spirv_info *info = vkr_spirv_scan(code, bytes, scan_why, sizeof(scan_why));
   const bool ok = vkr_spirv_validate(t, info ? info : &empty, code, bytes, why, why_size, unsafe);
   vkr_spirv_free(info);
   return ok;
}

/* the footprint cap (STANDARDS 14c): a thread reads the process's phys_footprint every 10 ms;
 * past CAP_MB it names the module and ends the process. The largest rise over one module
 * and the largest footprint are reported. */
#define CAP_MB 512
static const char *volatile current = "-";
static volatile uint64_t peak;

static uint64_t
footprint(void)
{
   task_vm_info_data_t vi;
   mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
   return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) == KERN_SUCCESS
             ? vi.phys_footprint
             : 0;
}

static void *
capper(void *arg)
{
   (void)arg;
   for (;;) {
      const uint64_t f = footprint();
      if (f > peak)
         peak = f;
      if (f > (uint64_t)CAP_MB << 20) {
         char m[512];
         const int l = snprintf(m, sizeof(m), "FAIL: %s took the process past %d MB\n",
                                (const char *)current, CAP_MB);
         write(1, m, (size_t)l);
         _exit(3);
      }
      usleep(10000);
   }
   return NULL;
}

struct layout {
   bool have;
   uint32_t model;
   char entry[64];
   uint32_t n, set[256], binding[256];
};

static void
load_layout(const char *spv, struct layout *l)
{
   char path[1024], line[256], stage[16];
   memset(l, 0, sizeof(*l));
   snprintf(path, sizeof(path), "%.*s.lay", (int)(strlen(spv) - 4), spv);
   FILE *f = fopen(path, "r");
   if (!f)
      return;
   static const char *const models[] = { "vert", "tesc", "tese", "geom", "frag", "comp" };
   l->have = true;
   l->model = UINT32_MAX;
   while (fgets(line, sizeof(line), f)) {
      uint32_t a, b, c, d;
      if (sscanf(line, "stage %15s", stage) == 1) {
         for (uint32_t i = 0; i < 6; i++) {
            if (!strcmp(stage, models[i]))
               l->model = i;
         }
      } else if (sscanf(line, "entry %63s", l->entry) == 1) {
      } else if (sscanf(line, "bind %u %u %u %u", &a, &b, &c, &d) == 4 && l->n < 256) {
         l->set[l->n] = a;
         l->binding[l->n++] = b;
      }
   }
   fclose(f);
   /* "stage none": a stage the harness did not make a pipeline of (geometry) */
   l->have = l->model != UINT32_MAX;
}

static bool
layout_has(const void *data, uint32_t set, uint32_t binding)
{
   const struct layout *l = data;
   for (uint32_t i = 0; i < l->n; i++) {
      if (l->set[i] == set && l->binding[i] == binding)
         return true;
   }
   return false;
}

static int
check_module(const struct vkr_spirv_target *t, const char *path, const uint32_t *code,
             size_t bytes, char *why, size_t why_size)
{
   struct vkr_spirv_info *info = vkr_spirv_scan(code, bytes, why, why_size);
   if (!info)
      return BY_SCAN;
   int r = PASSED;
   struct layout l;
   load_layout(path, &l);
   const struct vkr_spirv_entry *e = l.have ? vkr_spirv_entry(info, l.entry, l.model) : NULL;
   uint32_t size[3], set, binding;
   bool unsafe = false;
   /* the elements and Workgroup bytes as vkr_stage_shader_ok counts them for the layout's
    * entry point, else for each entry point (a pipeline may pick any): the most */
   const bool by_interface = t->options & VKR_SPIRV_INTERFACE_GLOBALS;
   uint64_t elements = 0, shared = 0;
   bool counted = true;
   for (uint32_t i = 0; i < info->entry_count && counted; i++) {
      const struct vkr_spirv_entry *at = e ? e : &info->entries[i];
      uint64_t a = 0, b = 0;
      counted = vkr_spirv_function_elements(info, at, by_interface, NULL, NULL, &a) &&
                vkr_spirv_workgroup_bytes(info, at, by_interface, NULL, NULL, &b);
      elements = a > elements ? a : elements;
      shared = b > shared ? b : shared;
      if (e)
         break;
   }
   if (!vkr_spirv_validate(t, info, code, bytes, why, why_size, &unsafe)) {
      r = unsafe ? BY_UNSAFE : BY_VALIDATOR;
   } else if (!counted || elements > VKR_SPIRV_MAX_FUNCTION_ELEMENTS) {
      snprintf(why, why_size, "Function and Private variables of %llu elements",
               (unsigned long long)elements);
      r = BY_ELEMENTS;
   } else if (shared > SHARED_MAX) {
      snprintf(why, why_size, "Workgroup variables of %llu bytes", (unsigned long long)shared);
      r = BY_ELEMENTS;
   } else if (l.have && !e) {
      snprintf(why, why_size, "no entry point %s for the stage", l.entry);
      r = BY_PIPELINE;
   } else if (e && l.model == 5 &&
              (!vkr_spirv_workgroup_size(info, e, NULL, NULL, size) || !size[0] || !size[1] ||
               !size[2] || size[0] > 1024 || size[1] > 1024 || size[2] > 1024 ||
               (uint64_t)size[0] * size[1] * size[2] > 1024)) {
      snprintf(why, why_size, "a workgroup of %u x %u x %u", size[0], size[1], size[2]);
      r = BY_PIPELINE;
   } else if (e && !vkr_spirv_bindings_ok(info, e, layout_has, &l, &set, &binding)) {
      snprintf(why, why_size, "set %u binding %u not in the layout", set, binding);
      r = BY_PIPELINE;
   }
   vkr_spirv_free(info);
   return r;
}

static int
corpus(int want, const char *prof, int argc, char **argv)
{
   struct vkr_spirv_target t;
   if (!profile(prof, &t)) {
      printf("FAIL: profile %s\n", prof);
      return 1;
   }
   unsigned counts[6] = { 0 }, newer = 0;
   pthread_t cap;
   pthread_create(&cap, NULL, capper, NULL);
   uint64_t most = 0, top = 0;
   const char *most_at = "-";
   for (int i = 0; i < argc; i++) {
      size_t bytes;
      uint32_t *code = load(argv[i], &bytes);
      char why[256] = "";
      current = argv[i];
      const uint64_t before = footprint();
      peak = before;
      const int r = code ? check_module(&t, argv[i], code, bytes, why, sizeof(why)) : BY_SCAN;
      usleep(1000);
      top = peak > top ? peak : top;
      if (peak > before && peak - before > most) {
         most = peak - before;
         most_at = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];
      }
      counts[r]++;
      /* SPIR-V past the target's version (an app told Vulkan 1.1 sends 1.5): spirv-val's */
      const bool too_new = code && bytes >= 8 && code[1] > target_spirv(&t);
      newer += too_new && r == BY_VALIDATOR;
      if (want == 1 && too_new)
         CHECK(r == BY_VALIDATOR && strstr(why, "version"), "%s %s (SPIR-V 0x%x): %s", prof,
               argv[i], code[1], r == PASSED ? "passed" : why);
      else if (want == 1)
         CHECK(r == PASSED, "%s %s refused: %s", prof, argv[i], code ? why : "unreadable");
      else if (want == 0)
         CHECK(r != PASSED, "%s %s passed (a Mac driver ended the process on it)", prof, argv[i]);
      free(code);
   }
   printf("%s %s: %d modules; passed %u, refused by the scan %u, by spirv-val %u (%u of a "
          "newer SPIR-V than the target's), before it or by an exception in it %u, by the element "
          "or Workgroup byte cap %u, by the pipeline checks %u; largest rise %llu KB (%s), at most "
          "%llu MB in all (cap %d MB)\n",
          want == 1 ? "pass" : want == 0 ? "refuse" : "run", prof, argc, counts[PASSED], counts[BY_SCAN],
          counts[BY_VALIDATOR], newer, counts[BY_UNSAFE], counts[BY_ELEMENTS], counts[BY_PIPELINE],
          (unsigned long long)(most >> 10), most_at, (unsigned long long)(top >> 20), CAP_MB);
   return failures != 0;
}

static double
now_us(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
   return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static int
cmp_double(const void *a, const void *b)
{
   const double x = *(const double *)a, y = *(const double *)b;
   return x < y ? -1 : x > y;
}

static int
timing(const char *prof, int reps, int argc, char **argv)
{
   struct vkr_spirv_target t;
   if (!profile(prof, &t) || reps < 1)
      return 1;
   double *v = calloc((size_t)reps, sizeof(*v));
   for (int i = 0; i < argc && v; i++) {
      size_t bytes;
      uint32_t *code = load(argv[i], &bytes);
      char why[256];
      bool ok = false;
      for (int r = 0; code && r < reps; r++) {
         vkr_spirv_cache_reset();
         struct vkr_spirv_info *info = vkr_spirv_scan(code, bytes, why, sizeof(why));
         const double t0 = now_us();
         ok = info && vkr_spirv_validate(&t, info, code, bytes, why, sizeof(why), NULL);
         v[r] = now_us() - t0;
         vkr_spirv_free(info);
      }
      if (code) {
         qsort(v, (size_t)reps, sizeof(*v), cmp_double);
         printf("%s\t%zu\t%.1f\t%.1f\t%s\n", argv[i], bytes, v[reps / 2], v[reps - 1], ok ? "valid" : why);
      }
      free(code);
   }
   free(v);
   return 0;
}

/* --- units: the cache --- */

/* a module with another id bound is another key, and as valid when the bound is larger */
static uint32_t *
variant(const uint32_t *code, size_t bytes, uint32_t extra)
{
   uint32_t *w = malloc(bytes);
   memcpy(w, code, bytes);
   w[3] += extra;
   return w;
}

struct thread_arg {
   const struct vkr_spirv_target *t;
   uint32_t **mods;
   size_t bytes;
   int count, rounds, bad;
};

static void *
thread_main(void *p)
{
   struct thread_arg *a = p;
   char why[256];
   for (int r = 0; r < a->rounds; r++) {
      for (int i = 0; i < a->count; i++)
         a->bad += !validate(a->t, a->mods[(i + r) % a->count], a->bytes, why, sizeof(why), NULL);
   }
   return NULL;
}

static void
cache_units(const uint32_t *code, size_t bytes)
{
   struct vkr_spirv_target t, t2;
   profile("kk", &t);
   profile("mvk", &t2);
   struct vkr_spirv_cache_stats s;
   char why[256];
   vkr_spirv_cache_reset();
   CHECK(validate(&t, code, bytes, why, sizeof(why), NULL), "cache: the module is valid: %s", why);
   CHECK(validate(&t, code, bytes, why, sizeof(why), NULL), "cache: again");
   CHECK(validate(&t2, code, bytes, why, sizeof(why), NULL), "cache: other target");
   vkr_spirv_cache_stats(&s);
   CHECK(s.hits == 1 && s.misses == 2 && s.entries == 2,
         "cache: one hit, a miss per target (hits %llu misses %llu entries %u)",
         (unsigned long long)s.hits, (unsigned long long)s.misses, s.entries);

   /* 4096 + 100 keys: 100 evictions, the oldest gone, the newest kept */
   vkr_spirv_cache_reset();
   enum { N = 4096 + 100 };
   for (uint32_t i = 0; i < N; i++) {
      uint32_t *w = variant(code, bytes, i);
      CHECK(validate(&t, w, bytes, why, sizeof(why), NULL), "cache: variant %u: %s", i, why);
      free(w);
   }
   vkr_spirv_cache_stats(&s);
   CHECK(s.entries == 4096 && s.evictions == 100 && s.misses == N,
         "cache: bounded at 4096 (entries %u evictions %llu misses %llu)", s.entries,
         (unsigned long long)s.evictions, (unsigned long long)s.misses);
   uint32_t *newest = variant(code, bytes, N - 1), *oldest = variant(code, bytes, 0);
   validate(&t, newest, bytes, why, sizeof(why), NULL);
   vkr_spirv_cache_stats(&s);
   CHECK(s.hits == 1, "cache: the newest is kept");
   validate(&t, oldest, bytes, why, sizeof(why), NULL);
   vkr_spirv_cache_stats(&s);
   CHECK(s.hits == 1 && s.misses == N + 1, "cache: the oldest went first");
   free(newest);
   free(oldest);

   /* a recently used entry survives the evictions that a new one causes (LRU, not FIFO) */
   vkr_spirv_cache_reset();
   for (uint32_t i = 0; i < 4096; i++) {
      uint32_t *w = variant(code, bytes, i);
      validate(&t, w, bytes, why, sizeof(why), NULL);
      free(w);
   }
   uint32_t *first = variant(code, bytes, 0);
   validate(&t, first, bytes, why, sizeof(why), NULL); /* used again: now the newest */
   uint32_t *more = variant(code, bytes, 5000);
   validate(&t, more, bytes, why, sizeof(why), NULL); /* evicts variant 1 */
   vkr_spirv_cache_stats(&s);
   const uint64_t hits = s.hits;
   validate(&t, first, bytes, why, sizeof(why), NULL);
   vkr_spirv_cache_stats(&s);
   CHECK(s.hits == hits + 1, "cache: a used entry is kept over an older one");
   free(first);
   free(more);

   /* refusals are not kept */
   vkr_spirv_cache_reset();
   uint32_t *bad = variant(code, bytes, 0);
   bad[3] = 1; /* every id past the bound: spirv-val refuses */
   CHECK(!validate(&t, bad, bytes, why, sizeof(why), NULL), "cache: an id bound of 1 is refused");
   CHECK(!validate(&t, bad, bytes, why, sizeof(why), NULL), "cache: and refused again");
   vkr_spirv_cache_stats(&s);
   CHECK(s.entries == 0 && s.hits == 0, "cache: no refusal kept (entries %u)", s.entries);
   free(bad);

   /* past the size cap: refused unread */
   static const struct vkr_spirv_info empty;
   bool unsafe = false;
   CHECK(!vkr_spirv_validate(&t, &empty, code, VKR_SPIRV_MAX_CODE_SIZE + 4, why, sizeof(why),
                             &unsafe) &&
            strstr(why, "at most") && unsafe,
         "cache: a module past the size cap is refused unread (%s)", why);

   /* 8 threads on 64 keys at once: every call answered, counts add up */
   vkr_spirv_cache_reset();
   enum { THREADS = 8, KEYS = 64, ROUNDS = 40 };
   uint32_t *mods[KEYS];
   for (int i = 0; i < KEYS; i++)
      mods[i] = variant(code, bytes, (uint32_t)i);
   pthread_t th[THREADS];
   struct thread_arg args[THREADS];
   for (int i = 0; i < THREADS; i++) {
      args[i] = (struct thread_arg){ &t, mods, bytes, KEYS, ROUNDS, 0 };
      pthread_create(&th[i], NULL, thread_main, &args[i]);
   }
   int bad_calls = 0;
   for (int i = 0; i < THREADS; i++) {
      pthread_join(th[i], NULL);
      bad_calls += args[i].bad;
   }
   vkr_spirv_cache_stats(&s);
   CHECK(!bad_calls && s.hits + s.misses == (uint64_t)THREADS * KEYS * ROUNDS && s.entries == KEYS,
         "cache: threads (refused %d, hits %llu + misses %llu, entries %u)", bad_calls,
         (unsigned long long)s.hits, (unsigned long long)s.misses, s.entries);
   for (int i = 0; i < KEYS; i++)
      free(mods[i]);
}

static void
target_units(void)
{
   struct vkr_spirv_target t;
   char text[128];
   CHECK(!vkr_spirv_target_init(&t, API(1, 0), true, 0, NULL), "target: Vulkan 1.0 has none");
   static const struct {
      uint32_t api;
      bool spv14;
      const char *want;
   } cases[] = {
      { API(1, 1), false, "SPIR-V 1.3 (under Vulkan 1.1 semantics)" },
      { API(1, 1), true, "SPIR-V 1.4 (under Vulkan 1.1 semantics)" },
      { API(1, 2), false, "SPIR-V 1.5 (under Vulkan 1.2 semantics)" },
      { API(1, 3), false, "SPIR-V 1.6 (under Vulkan 1.3 semantics)" },
      { API(1, 4), false, "SPIR-V 1.6 (under Vulkan 1.4 semantics)" },
      { API(1, 9), false, "SPIR-V 1.6 (under Vulkan 1.4 semantics)" },
   };
   for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
      CHECK(vkr_spirv_target_init(&t, cases[i].api | 363, cases[i].spv14, 0, NULL), "target %u", i);
      vkr_spirv_target_text(&t, text, sizeof(text));
      CHECK(!strcmp(text, cases[i].want), "target %u: %s, want %s", i, text, cases[i].want);
   }
   vkr_spirv_target_init(&t, API(1, 4), true, VKR_SPIRV_SCALAR_LAYOUT | VKR_SPIRV_RELAXED_LAYOUT,
                         NULL);
   vkr_spirv_target_text(&t, text, sizeof(text));
   CHECK(strstr(text, " scalar") && strstr(text, " relaxed") && !strstr(text, " std"), "target text: %s", text);

   /* the interface limits from the device's (vkr_physical_device_init_spirv_target): its
    * components / 4, a stage it lacks (MoltenVK's geometry, 0 components) Vulkan's minimum,
    * no device all of Vulkan's minimums */
   static const struct {
      const char *name;
      const struct vkr_spirv_device_io *device;
      struct vkr_spirv_io_limits want;
   } io_cases[] = {
      { "kk", &kk_io, { 32, 32, 32, 32, 30, 32, 32, 32, 32, 32, 8 } },
      { "mvk", &mvk_io, { 31, 31, 31, 31, 30, 31, 31, 16, 16, 31, 8 } },
      { "none", NULL, { 16, 16, 16, 16, 30, 16, 16, 16, 16, 16, 4 } },
   };
   for (unsigned i = 0; i < sizeof(io_cases) / sizeof(io_cases[0]); i++) {
      CHECK(vkr_spirv_target_init(&t, API(1, 4), true, 0, io_cases[i].device), "target io %s",
            io_cases[i].name);
      CHECK(!memcmp(&t.io, &io_cases[i].want, sizeof(t.io)),
            "target io %s: geometry in %u out %u, vertex in %u out %u, fragment out %u",
            io_cases[i].name, t.io.geometry_in, t.io.geometry_out, t.io.vertex_in,
            t.io.vertex_out, t.io.fragment_out);
   }
}

/* --- units: Function and Private elements, Workgroup bytes --- */

/* a compute module with Function and Private variables of the types the caller adds */
struct mod {
   uint32_t w[512];
   uint32_t n, next;
};

static void
op(struct mod *m, uint32_t code, uint32_t count, const uint32_t *words)
{
   m->w[m->n++] = (count + 1) << 16 | code;
   memcpy(&m->w[m->n], words, count * 4);
   m->n += count;
}

#define OP(m, code, ...)                                                                     \
   do {                                                                                      \
      const uint32_t w_[] = { __VA_ARGS__ };                                                 \
      op(m, code, sizeof(w_) / 4, w_);                                                       \
   } while (0)

enum { T_VOID = 1, T_FN, T_UINT, T_ULONG, F_MAIN, LBL, FIRST_FREE };

static void
mod_begin(struct mod *m)
{
   memset(m, 0, sizeof(*m));
   const uint32_t head[] = { 0x07230203, 0x00010600, 0, 0, 0 };
   memcpy(m->w, head, sizeof(head));
   m->n = 5;
   m->next = FIRST_FREE;
   OP(m, 17, 1);                                        /* OpCapability Shader */
   OP(m, 17, 11);                                       /* OpCapability Int64 */
   OP(m, 14, 0, 1);                                     /* OpMemoryModel Logical GLSL450 */
   OP(m, 15, 5, F_MAIN, 0x6e69616d, 0);                 /* OpEntryPoint GLCompute "main" */
   OP(m, 16, F_MAIN, 17, 1, 1, 1);                      /* OpExecutionMode LocalSize 1 1 1 */
   OP(m, 19, T_VOID);                                   /* OpTypeVoid */
   OP(m, 33, T_FN, T_VOID);                             /* OpTypeFunction */
   OP(m, 21, T_UINT, 32, 0);                            /* OpTypeInt 32 */
   OP(m, 21, T_ULONG, 64, 0);                           /* OpTypeInt 64 */
}

static uint32_t
mod_const(struct mod *m, uint32_t value)
{
   const uint32_t id = m->next++;
   OP(m, 43, T_UINT, id, value);
   return id;
}

static uint32_t
mod_array(struct mod *m, uint32_t elem, uint32_t length_id)
{
   const uint32_t id = m->next++;
   OP(m, 28, id, elem, length_id);
   return id;
}

/* the function with one Function variable of each type in vars (0 ends) */
static void
mod_end(struct mod *m, const uint32_t *vars, uint32_t private_type)
{
   uint32_t ptr[8] = { 0 }, n = 0;
   for (; vars[n]; n++) {
      ptr[n] = m->next++;
      OP(m, 32, ptr[n], 7, vars[n]); /* OpTypePointer Function */
   }
   if (private_type) {
      const uint32_t p = m->next++, v = m->next++;
      OP(m, 32, p, 6, private_type);
      OP(m, 59, p, v, 6); /* OpVariable Private */
   }
   OP(m, 54, T_VOID, F_MAIN, 0, T_FN); /* OpFunction */
   OP(m, 248, LBL);                    /* OpLabel */
   for (uint32_t i = 0; i < n; i++)
      OP(m, 59, ptr[i], m->next++, 7); /* OpVariable Function */
   OP(m, 253);                         /* OpReturn */
   OP(m, 56);                          /* OpFunctionEnd */
   m->w[3] = m->next;
}

struct spec {
   uint32_t id, value;
   bool given;
};

static bool
spec_lookup(const void *data, uint32_t spec_id, uint32_t *value)
{
   const struct spec *s = data;
   if (!s->given || s->id != spec_id)
      return false;
   *value = s->value;
   return true;
}

static void
elements_case(const char *name, struct mod *m, const struct spec *spec, bool want_ok, uint64_t want)
{
   char why[192];
   struct vkr_spirv_info *info = vkr_spirv_scan(m->w, m->n * 4, why, sizeof(why));
   CHECK(info, "elements %s: scan: %s", name, why);
   if (!info)
      return;
   uint64_t n = 0;
   const bool ok =
      vkr_spirv_function_elements(info, NULL, false, spec ? spec_lookup : NULL, spec, &n);
   CHECK(ok == want_ok && (!ok || n == want), "elements %s: %s %llu, want %s %llu", name,
         ok ? "ok" : "unknown", (unsigned long long)n, want_ok ? "ok" : "unknown",
         (unsigned long long)want);
   vkr_spirv_free(info);
}

static void
elements_units(void)
{
   struct mod m;
   const uint64_t cap = VKR_SPIRV_MAX_FUNCTION_ELEMENTS;

   /* uint[1024][1024]: 2^20, the cap itself; [1024][1025] one row past it */
   mod_begin(&m);
   uint32_t k = mod_const(&m, 1024), a = mod_array(&m, T_UINT, k);
   mod_end(&m, (uint32_t[]){ mod_array(&m, a, k), 0 }, 0);
   elements_case("nested-cap", &m, NULL, true, cap);
   mod_begin(&m);
   k = mod_const(&m, 1024);
   a = mod_array(&m, T_UINT, k);
   mod_end(&m, (uint32_t[]){ mod_array(&m, a, mod_const(&m, 1025)), 0 }, 0);
   elements_case("nested-over", &m, NULL, true, cap + 1024);

   /* struct { uint[2^19]; uint[2^19]; } and two variables of uint[2^19] + 1 */
   mod_begin(&m);
   a = mod_array(&m, T_UINT, mod_const(&m, 1u << 19));
   uint32_t st = m.next++;
   OP(&m, 30, st, a, a);
   mod_end(&m, (uint32_t[]){ st, 0 }, 0);
   elements_case("struct-cap", &m, NULL, true, cap);
   mod_begin(&m);
   a = mod_array(&m, T_UINT, mod_const(&m, 1u << 19));
   mod_end(&m, (uint32_t[]){ a, a, T_UINT, 0 }, 0);
   elements_case("two-vars", &m, NULL, true, cap + 1);

   /* a spec constant length: its default, then what the pipeline gives */
   mod_begin(&m);
   uint32_t sc = m.next++;
   OP(&m, 71, sc, 1, 7); /* OpDecorate SpecId 7 */
   OP(&m, 50, T_UINT, sc, 4);
   a = mod_array(&m, T_UINT, sc);
   mod_end(&m, (uint32_t[]){ mod_array(&m, a, mod_const(&m, 1u << 18)), 0 }, 0);
   elements_case("spec-default", &m, NULL, true, 4u << 18);
   elements_case("spec-given", &m, &(struct spec){ 7, 8, true }, true, 8u << 18);
   elements_case("spec-other-id", &m, &(struct spec){ 8, 8, true }, true, 4u << 18);
   elements_case("spec-huge", &m, &(struct spec){ 7, 0xffffffff, true }, true,
                 0xffffffffull << 18);

   /* a length the scan cannot know: a spec constant operation; a 64-bit spec constant */
   mod_begin(&m);
   uint32_t op_id = m.next++;
   OP(&m, 52, T_UINT, op_id, 128 /* IAdd */, mod_const(&m, 1), mod_const(&m, 2));
   mod_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, op_id), 0 }, 0);
   elements_case("spec-op", &m, NULL, false, 0);
   mod_begin(&m);
   sc = m.next++;
   OP(&m, 71, sc, 1, 3);
   OP(&m, 50, T_ULONG, sc, 16, 0);
   mod_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, sc), 0 }, 0);
   elements_case("spec-64", &m, NULL, false, 0);

   /* a 64-bit constant length keeps its upper word: 2^32 + 1 */
   mod_begin(&m);
   uint32_t c64 = m.next++;
   OP(&m, 43, T_ULONG, c64, 1, 1);
   mod_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, c64), 0 }, 0);
   elements_case("const-64", &m, NULL, true, (1ull << 32) + 1);

   /* uint[2^32-1] (the module that took KosmicKrisp to 9 GB) and a product past 2^64 */
   mod_begin(&m);
   const uint32_t big = mod_const(&m, 0xffffffff);
   a = mod_array(&m, T_UINT, big);
   mod_end(&m, (uint32_t[]){ a, 0 }, 0);
   elements_case("uint-2e32", &m, NULL, true, 0xffffffffull);
   mod_begin(&m);
   const uint32_t b2 = mod_const(&m, 0xffffffff);
   a = mod_array(&m, T_UINT, b2);
   a = mod_array(&m, a, b2);
   a = mod_array(&m, a, b2);
   mod_end(&m, (uint32_t[]){ a, a, 0 }, 0);
   elements_case("saturates", &m, NULL, true, UINT64_MAX);

   /* 70 levels of uint[2]: past the nesting the count follows */
   mod_begin(&m);
   k = mod_const(&m, 2);
   a = T_UINT;
   for (int i = 0; i < 70; i++)
      a = mod_array(&m, a, k);
   mod_end(&m, (uint32_t[]){ a, 0 }, 0);
   elements_case("deep", &m, NULL, false, 0);

   /* a struct that names itself (invalid, but the scan sees it before spirv-val) */
   mod_begin(&m);
   st = m.next++;
   OP(&m, 30, st, st);
   mod_end(&m, (uint32_t[]){ st, 0 }, 0);
   elements_case("loop", &m, NULL, false, 0);

   /* Private arrays count with the Function ones (a Private uint[2^32-1] passed the scan and
    * spirv-val); pointees of pointers do not */
   mod_begin(&m);
   a = mod_array(&m, T_UINT, mod_const(&m, 1u << 24));
   mod_end(&m, (uint32_t[]){ T_UINT, 0 }, a);
   elements_case("private", &m, NULL, true, (1u << 24) + 1);
   mod_begin(&m);
   a = mod_array(&m, T_UINT, mod_const(&m, 0xffffffff));
   mod_end(&m, (uint32_t[]){ 0 }, a);
   elements_case("private-2e32", &m, NULL, true, 0xffffffffull);

   /* no Function variables at all */
   mod_begin(&m);
   mod_end(&m, (uint32_t[]){ 0 }, 0);
   elements_case("none", &m, NULL, true, 0);
}

/* a compute module with a Workgroup variable of each type in vars (0 ends); block: their
 * types are decorated Block (they alias) */
static void
shared_end(struct mod *m, const uint32_t *vars, bool block)
{
   uint32_t ptr[8] = { 0 }, n = 0;
   for (; vars[n]; n++) {
      ptr[n] = m->next++;
      if (block)
         OP(m, 71, vars[n], 2); /* OpDecorate Block */
      OP(m, 32, ptr[n], 4, vars[n]); /* OpTypePointer Workgroup */
   }
   for (uint32_t i = 0; i < n; i++)
      OP(m, 59, ptr[i], m->next++, 4); /* OpVariable Workgroup */
   OP(m, 54, T_VOID, F_MAIN, 0, T_FN);
   OP(m, 248, LBL);
   OP(m, 253);
   OP(m, 56);
   m->w[3] = m->next;
}

static void
bytes_case(const char *name, struct mod *m, const struct spec *spec, bool want_ok, uint64_t want)
{
   char why[192];
   struct vkr_spirv_info *info = vkr_spirv_scan(m->w, m->n * 4, why, sizeof(why));
   CHECK(info, "bytes %s: scan: %s", name, why);
   if (!info)
      return;
   uint64_t n = 0;
   const bool ok =
      vkr_spirv_workgroup_bytes(info, NULL, false, spec ? spec_lookup : NULL, spec, &n);
   CHECK(ok == want_ok && (!ok || n == want), "bytes %s: %s %llu, want %s %llu", name,
         ok ? "ok" : "unknown", (unsigned long long)n, want_ok ? "ok" : "unknown",
         (unsigned long long)want);
   vkr_spirv_free(info);
}

static void
bytes_units(void)
{
   struct mod m;
   /* uint[8192]: 32 KB, maxComputeSharedMemorySize itself; uint[8193] 4 bytes past it */
   mod_begin(&m);
   shared_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, mod_const(&m, 8192)), 0 }, false);
   bytes_case("uint-8192", &m, NULL, true, SHARED_MAX);
   mod_begin(&m);
   shared_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, mod_const(&m, 8193)), 0 }, false);
   bytes_case("uint-8193", &m, NULL, true, SHARED_MAX + 4);

   /* uint64_t[2048] + uvec4[1024] + uint: the variables add up */
   mod_begin(&m);
   uint32_t v4 = m.next++;
   OP(&m, 23, v4, T_UINT, 4); /* OpTypeVector uint 4 */
   uint32_t a = mod_array(&m, T_ULONG, mod_const(&m, 2048)), b = mod_array(&m, v4, mod_const(&m, 1024));
   shared_end(&m, (uint32_t[]){ a, b, T_UINT, 0 }, false);
   bytes_case("sum", &m, NULL, true, 16384 + 16384 + 4);

   /* struct { uint; uint64_t; mat2x4 of uint }[100]: no padding, 4 + 8 + 32 a struct */
   mod_begin(&m);
   v4 = m.next++;
   OP(&m, 23, v4, T_UINT, 4);
   const uint32_t mat = m.next++, st = m.next++;
   OP(&m, 24, mat, v4, 2); /* OpTypeMatrix 2 columns */
   OP(&m, 30, st, T_UINT, T_ULONG, mat);
   shared_end(&m, (uint32_t[]){ mod_array(&m, st, mod_const(&m, 100)), 0 }, false);
   bytes_case("struct", &m, NULL, true, 4400);

   /* two Block structs of uint[8192] alias each other: 32 KB, not 64 */
   mod_begin(&m);
   a = mod_array(&m, T_UINT, mod_const(&m, 8192));
   const uint32_t s1 = m.next++, s2 = m.next++;
   OP(&m, 30, s1, a);
   OP(&m, 30, s2, a);
   shared_end(&m, (uint32_t[]){ s1, s2, 0 }, true);
   bytes_case("blocks-alias", &m, NULL, true, SHARED_MAX);

   /* a spec constant length (clspv's local arrays): its default, then the pipeline's */
   mod_begin(&m);
   uint32_t sc = m.next++;
   OP(&m, 71, sc, 1, 5); /* OpDecorate SpecId 5 */
   OP(&m, 50, T_UINT, sc, 16);
   shared_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, sc), 0 }, false);
   bytes_case("spec-default", &m, NULL, true, 64);
   bytes_case("spec-given", &m, &(struct spec){ 5, 16384, true }, true, 65536);

   /* a length from a spec constant operation (glslang's shared x[gl_WorkGroupSize.x]):
    * counted once, not refused */
   mod_begin(&m);
   const uint32_t op_id = m.next++;
   OP(&m, 52, T_UINT, op_id, 128 /* IAdd */, mod_const(&m, 1), mod_const(&m, 2));
   shared_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, op_id), 0 }, false);
   bytes_case("spec-op", &m, NULL, true, 4);

   /* uint[2^32-1] (passed the scan and spirv-val before this check) */
   mod_begin(&m);
   shared_end(&m, (uint32_t[]){ mod_array(&m, T_UINT, mod_const(&m, 0xffffffff)), 0 }, false);
   bytes_case("uint-2e32", &m, NULL, true, 4ull * 0xffffffff);

   /* 70 levels of uint[2]; and none at all */
   mod_begin(&m);
   const uint32_t k = mod_const(&m, 2);
   a = T_UINT;
   for (int i = 0; i < 70; i++)
      a = mod_array(&m, a, k);
   shared_end(&m, (uint32_t[]){ a, 0 }, false);
   bytes_case("deep", &m, NULL, false, 0);
   mod_begin(&m);
   shared_end(&m, (uint32_t[]){ 0 }, false);
   bytes_case("none", &m, NULL, true, 0);
}

/* --- units: interface locations and type cost --- */

/* a module of one entry point of `model` whose interface is IO_FIRST.. (the variables the
 * caller adds with io_var) */
enum { IO_FIRST = 200, IO_MAX = 8 };

struct iomod {
   struct mod m;
   uint32_t model, vars;
   uint32_t decos[64], ndecos; /* words of OpDecorate instructions, kept for the front */
};

static void
io_begin(struct iomod *io, uint32_t model)
{
   memset(io, 0, sizeof(*io));
   io->model = model;
   io->m.next = FIRST_FREE;
}

/* the types go into a buffer that io_end puts after the module's head */
static uint32_t
io_type(struct iomod *io, uint32_t code, uint32_t a, uint32_t b)
{
   const uint32_t id = io->m.next++;
   if (code == 30 && !a) /* an empty struct */
      OP(&io->m, 30, id);
   else if (code == 30 && !b)
      OP(&io->m, 30, id, a);
   else
      OP(&io->m, code, id, a, b);
   return id;
}

static uint32_t
io_const(struct iomod *io, uint32_t value)
{
   const uint32_t id = io->m.next++;
   OP(&io->m, 43, T_UINT, id, value);
   return id;
}

/* an Input (1) or Output (3) variable of `type` at `location` (UINT32_MAX: none); `deco` one
 * more decoration of it (0: none) */
static uint32_t
io_var(struct iomod *io, uint32_t storage, uint32_t type, uint32_t location, uint32_t deco)
{
   const uint32_t id = IO_FIRST + io->vars++, ptr = io->m.next++;
   OP(&io->m, 32, ptr, storage, type);
   OP(&io->m, 59, ptr, id, storage);
   if (location != UINT32_MAX) {
      const uint32_t d[] = { (4 << 16) | 71, id, 30, location };
      memcpy(&io->decos[io->ndecos], d, sizeof(d));
      io->ndecos += 4;
   }
   if (deco) {
      const uint32_t d[] = { (3 << 16) | 71, id, deco };
      memcpy(&io->decos[io->ndecos], d, sizeof(d));
      io->ndecos += 3;
   }
   return id;
}

static void
io_decorate(struct iomod *io, uint32_t id, uint32_t deco, uint32_t value)
{
   const uint32_t d[] = { (4 << 16) | 71, id, deco, value };
   memcpy(&io->decos[io->ndecos], d, sizeof(d));
   io->ndecos += 4;
}

/* a decoration without a value (Block, Patch) */
static void
io_flag(struct iomod *io, uint32_t id, uint32_t deco)
{
   const uint32_t d[] = { (3 << 16) | 71, id, deco };
   memcpy(&io->decos[io->ndecos], d, sizeof(d));
   io->ndecos += 3;
}

static void
io_member_builtin(struct iomod *io, uint32_t st, uint32_t member)
{
   const uint32_t d[] = { (5 << 16) | 72, st, member, 11, 3 /* ClipDistance */ };
   memcpy(&io->decos[io->ndecos], d, sizeof(d));
   io->ndecos += 5;
}

/* the whole module into out (words) */
static uint32_t
io_end(struct iomod *io, uint32_t *out)
{
   struct mod h;
   memset(&h, 0, sizeof(h));
   const uint32_t head[] = { 0x07230203, 0x00010600, 0, 0, 0 };
   memcpy(h.w, head, sizeof(head));
   h.n = 5;
   OP(&h, 17, 1);
   OP(&h, 14, 0, 1);
   h.w[h.n++] = (5 + io->vars) << 16 | 15; /* OpEntryPoint model %main "main" vars... */
   h.w[h.n++] = io->model;
   h.w[h.n++] = F_MAIN;
   h.w[h.n++] = 0x6e69616d;
   h.w[h.n++] = 0;
   for (uint32_t i = 0; i < io->vars; i++)
      h.w[h.n++] = IO_FIRST + i;
   memcpy(&h.w[h.n], io->decos, io->ndecos * 4);
   h.n += io->ndecos;
   OP(&h, 19, T_VOID);
   OP(&h, 33, T_FN, T_VOID);
   OP(&h, 21, T_UINT, 32, 0);
   OP(&h, 21, T_ULONG, 64, 0);
   memcpy(out, h.w, h.n * 4);
   memcpy(&out[h.n], io->m.w, io->m.n * 4);
   uint32_t n = h.n + io->m.n;
   const uint32_t tail[] = { (5 << 16) | 54, T_VOID, F_MAIN, 0, T_FN, (2 << 16) | 248, LBL,
                             (1 << 16) | 253, (1 << 16) | 56 };
   memcpy(&out[n], tail, sizeof(tail));
   n += sizeof(tail) / 4;
   out[3] = IO_FIRST + IO_MAX;
   return n;
}

static void
io_case(const char *name, struct iomod *io, const char *prof, const struct spec *spec, bool want)
{
   uint32_t w[1024];
   const uint32_t n = io_end(io, w);
   struct vkr_spirv_target t;
   profile(prof, &t);
   char why[256] = "";
   struct vkr_spirv_info *info = vkr_spirv_scan(w, n * 4, why, sizeof(why));
   CHECK(info, "interface %s: scan: %s", name, why);
   if (!info)
      return;
   const bool ok = vkr_spirv_interface_ok(info, &t.io, spec ? spec_lookup : NULL, spec, why, sizeof(why));
   CHECK(ok == want, "interface %s (%s): %s, want %s (%s)", name, prof, ok ? "ok" : "refused",
         want ? "ok" : "refused", why);
   /* and through vkr_spirv_validate, before spirv-val (without specialization) */
   if (!spec && !want) {
      bool unsafe = false;
      CHECK(!vkr_spirv_validate(&t, info, w, n * 4, why, sizeof(why), &unsafe) && unsafe &&
               strstr(why, "06272"),
            "interface %s: vkr_spirv_validate refuses it before spirv-val (%s)", name, why);
   }
   vkr_spirv_free(info);
}

static void
interface_units(void)
{
   struct iomod io;
   enum { VERTEX = 0, TESS_CONTROL = 1, GEOMETRY = 3, FRAGMENT = 4, IN = 1, OUT = 3 };
   /* a fragment shader's vec4 inputs: 32 locations from 0 are the limit */
   for (uint32_t len = 31; len <= 33; len++) {
      for (uint32_t at = 0; at <= 1; at++) {
         io_begin(&io, FRAGMENT);
         uint32_t f = io.m.next++;
         OP(&io.m, 22, f, 32);
         const uint32_t v4 = io_type(&io, 23, f, 4);
         io_var(&io, IN, io_type(&io, 28, v4, io_const(&io, len)), at, 0);
         char name[64];
         snprintf(name, sizeof(name), "frag-in-vec4[%u]-at-%u", len, at);
         io_case(name, &io, "kk", NULL, len + at <= 32);
         io_case(name, &io, "mvk", NULL, len + at <= 31);
      }
   }
   /* the 304-byte module valfuzz found: an Input struct of uint[2^32-1] (spirv-val past 512
    * MB), the same as a Block member, an array of empty structs, nested arrays */
   io_begin(&io, FRAGMENT);
   io_var(&io, IN, io_type(&io, 30, io_type(&io, 28, T_UINT, io_const(&io, 0xffffffff)), 0), 0, 0);
   io_case("struct-uint-2e32", &io, "kk", NULL, false);
   io_begin(&io, FRAGMENT);
   uint32_t st = io_type(&io, 30, io_type(&io, 28, T_UINT, io_const(&io, 16777220)), 0);
   io_flag(&io, st, 2 /* Block */);
   io_var(&io, IN, st, UINT32_MAX, 0);
   io_case("block-member", &io, "kk", NULL, false);
   io_begin(&io, FRAGMENT);
   io_var(&io, IN, io_type(&io, 28, io_type(&io, 30, 0, 0), io_const(&io, 0xffffffff)), 0, 0);
   io_case("empty-structs", &io, "kk", NULL, false);
   io_begin(&io, FRAGMENT);
   uint32_t k = io_const(&io, 65536);
   io_var(&io, IN, io_type(&io, 28, io_type(&io, 28, T_UINT, k), k), 0, 0);
   io_case("nested-2e32", &io, "kk", NULL, false);
   /* fragment outputs: maxFragmentOutputAttachments (8) */
   for (uint32_t len = 8; len <= 9; len++) {
      io_begin(&io, FRAGMENT);
      io_var(&io, OUT, io_type(&io, 28, T_UINT, io_const(&io, len)), 0, 0);
      io_case(len == 8 ? "frag-out-8" : "frag-out-9", &io, "kk", NULL, len == 8);
   }
   /* 64-bit vectors of 3 or 4 take two locations; a matrix one per column */
   for (uint32_t len = 16; len <= 17; len++) {
      io_begin(&io, VERTEX);
      const uint32_t d4 = io_type(&io, 23, T_ULONG, 4);
      io_var(&io, IN, io_type(&io, 28, d4, io_const(&io, len)), 0, 0);
      io_case(len == 16 ? "u64vec4[16]" : "u64vec4[17]", &io, "kk", NULL, len == 16);
   }
   for (uint32_t len = 8; len <= 9; len++) {
      io_begin(&io, VERTEX);
      uint32_t f = io.m.next++;
      OP(&io.m, 22, f, 32);
      const uint32_t mat = io_type(&io, 24, io_type(&io, 23, f, 4), 4);
      io_var(&io, OUT, io_type(&io, 28, mat, io_const(&io, len)), 0, 0);
      io_case(len == 8 ? "mat4[8]" : "mat4[9]", &io, "kk", NULL, len == 8);
   }
   /* a geometry input's outer array is per vertex: struct { uint[32] }[3] fits, [33] not;
    * MoltenVK has no geometry shaders (limit 0) */
   for (uint32_t len = 32; len <= 33; len++) {
      io_begin(&io, GEOMETRY);
      st = io_type(&io, 30, io_type(&io, 28, T_UINT, io_const(&io, len)), 0);
      io_var(&io, IN, io_type(&io, 28, st, io_const(&io, 3)), 0, 0);
      io_case(len == 32 ? "geom-in-32" : "geom-in-33", &io, "kk", NULL, len == 32);
      io_case(len == 32 ? "geom-in-32" : "geom-in-33", &io, "mvk", NULL, false);
   }
   /* tessellation control: per-vertex outputs arrayed, patch ones at most 30 */
   for (uint32_t len = 30; len <= 31; len++) {
      io_begin(&io, TESS_CONTROL);
      io_var(&io, OUT, io_type(&io, 28, T_UINT, io_const(&io, len)), 0, 15 /* Patch */);
      io_case(len == 30 ? "tcs-patch-30" : "tcs-patch-31", &io, "kk", NULL, len == 30);
   }
   io_begin(&io, TESS_CONTROL);
   io_var(&io, OUT, io_type(&io, 28, io_type(&io, 28, T_UINT, io_const(&io, 32)), io_const(&io, 32)),
          0, 0);
   io_case("tcs-per-vertex-32x32", &io, "kk", NULL, true);
   /* built-ins are not counted: a variable and a block with a BuiltIn member */
   io_begin(&io, VERTEX);
   io_decorate(&io, io_var(&io, OUT, io_type(&io, 28, T_UINT, io_const(&io, 1000)), UINT32_MAX, 0),
               11 /* BuiltIn */, 3 /* ClipDistance */);
   io_case("builtin-var", &io, "kk", NULL, true);
   io_begin(&io, VERTEX);
   st = io_type(&io, 30, io_type(&io, 28, T_UINT, io_const(&io, 1000)), 0);
   io_member_builtin(&io, st, 0);
   io_var(&io, OUT, st, UINT32_MAX, 0);
   io_case("builtin-block", &io, "kk", NULL, true);
   /* a length from a SpecId: once for the module (as spirv-val counts it), the
    * specialized value for a pipeline */
   io_begin(&io, FRAGMENT);
   uint32_t sc = io.m.next++;
   io_decorate(&io, sc, 1 /* SpecId */, 3);
   OP(&io.m, 50, T_UINT, sc, 64);
   io_var(&io, IN, io_type(&io, 28, T_UINT, sc), 0, 0);
   io_case("spec-module", &io, "kk", NULL, true);
   io_case("spec-8", &io, "kk", &(struct spec){ 3, 8, true }, true);
   io_case("spec-33", &io, "kk", &(struct spec){ 3, 33, true }, false);
   io_case("spec-default-64", &io, "kk", &(struct spec){ 4, 8, true }, false);
}

/* --- units: explicit layout on Function, Private, Workgroup and UniformConstant types --- */

/* naga (wgpu) puts Offset and ArrayStride on every struct and array type, also on the types
 * of Function variables, in SPIR-V 1.6 too (#710, gfx-rs/wgpu#7696). The spec allows that
 * up to SPIR-V 1.4, and spirv-tools-val-function-private-layout.patch allows it at every
 * version for Function and Private; Workgroup without the capability and UniformConstant
 * stay refused (VUID-StandaloneSpirv-None-10684). */
static const char layout_head[] =
   "OpCapability Shader\n"
   "OpMemoryModel Logical GLSL450\n";
static const char layout_types[] =
   "%void = OpTypeVoid\n"
   "%fn = OpTypeFunction %void\n"
   "%float = OpTypeFloat 32\n"
   "%v4 = OpTypeVector %float 4\n"
   "%uint = OpTypeInt 32 0\n"
   "%c4 = OpConstant %uint 4\n"
   "%S = OpTypeStruct %v4 %v4\n"
   "%A = OpTypeArray %v4 %c4\n";

static void
layout_case(const char *name, const char *prof, spv_target_env env, const char *decorations,
            const char *globals, const char *locals, const char *interface, bool want_ok,
            const char *want_why)
{
   char text[2048], why[512];
   snprintf(text, sizeof(text),
            "%sOpEntryPoint GLCompute %%main \"main\"%s\n"
            "OpExecutionMode %%main LocalSize 1 1 1\n%s%s%s"
            "%%main = OpFunction %%void None %%fn\n%%l = OpLabel\n%s"
            "OpReturn\nOpFunctionEnd\n",
            layout_head, interface, decorations, layout_types, globals, locals);
   spv_context ctx = spvContextCreate(env);
   spv_binary bin = NULL;
   spv_diagnostic diag = NULL;
   const bool assembled = spvTextToBinary(ctx, text, strlen(text), &bin, &diag) == SPV_SUCCESS;
   CHECK(assembled, "layout %s: assembles: %s", name, diag ? diag->error : "?");
   if (assembled) {
      struct vkr_spirv_target t;
      profile(prof, &t);
      bool unsafe = false;
      const bool ok = validate(&t, bin->code, bin->wordCount * 4, why, sizeof(why), &unsafe);
      CHECK(ok == want_ok && (ok || !want_why || strstr(why, want_why)),
            "layout %s (%s): %s, want %s %s", name, prof, ok ? "passed" : why,
            want_ok ? "passed" : "refused with", want_why ? want_why : "");
   }
   spvBinaryDestroy(bin);
   spvDiagnosticDestroy(diag);
   spvContextDestroy(ctx);
}

static void
layout_units(void)
{
   static const char offset[] = "OpMemberDecorate %S 0 Offset 0\nOpMemberDecorate %S 1 Offset 16\n";
   static const char stride[] = "OpDecorate %A ArrayStride 16\n";
   static const char fn_s[] = "%pS = OpTypePointer Function %S\n";
   static const char fn_var[] = "%v = OpVariable %pS Function\n";
   static const char *const profiles[] = { "kk", "mvk" };
   for (int i = 0; i < 2; i++) {
      const char *p = profiles[i];
      /* Zed's prepare_gradient_color: `var result = GradientColor();`, a struct with Offset */
      layout_case("function-offset-1.6", p, SPV_ENV_UNIVERSAL_1_6, offset, fn_s, fn_var, "", true,
                  NULL);
      layout_case("function-offset-1.4", p, SPV_ENV_UNIVERSAL_1_4, offset, fn_s, fn_var, "", true,
                  NULL);
      layout_case("private-offset-1.6", p, SPV_ENV_UNIVERSAL_1_6, offset,
                  "%pS = OpTypePointer Private %S\n%v = OpVariable %pS Private\n", "", " %v", true,
                  NULL);
      layout_case("function-stride-1.6", p, SPV_ENV_UNIVERSAL_1_6, stride,
                  "%pA = OpTypePointer Function %A\n", "%v = OpVariable %pA Function\n", "", true,
                  NULL);
      /* Workgroup takes layout only with WorkgroupMemoryExplicitLayoutKHR */
      layout_case("workgroup-offset-1.6", p, SPV_ENV_UNIVERSAL_1_6, offset,
                  "%pS = OpTypePointer Workgroup %S\n%v = OpVariable %pS Workgroup\n", "", " %v",
                  false, "VUID-StandaloneSpirv-None-10684");
      layout_case("workgroup-offset-1.4", p, SPV_ENV_UNIVERSAL_1_4, offset,
                  "%pS = OpTypePointer Workgroup %S\n%v = OpVariable %pS Workgroup\n", "", " %v",
                  false, "VUID-StandaloneSpirv-None-10684");
      /* UniformConstant never takes layout: an image array with ArrayStride */
      layout_case("uniformconstant-stride-1.6", p, SPV_ENV_UNIVERSAL_1_6,
                  "OpDecorate %I ArrayStride 8\nOpDecorate %v DescriptorSet 0\n"
                  "OpDecorate %v Binding 0\n",
                  "%img = OpTypeImage %float 2D 0 0 0 1 Unknown\n%I = OpTypeArray %img %c4\n"
                  "%pI = OpTypePointer UniformConstant %I\n%v = OpVariable %pI UniformConstant\n",
                  "", " %v", false, "VUID-StandaloneSpirv-None-10684");
   }
   /* MoltenVK under a Vulkan 1.1 app takes SPIR-V up to 1.4: 1.5 and 1.6 stay too new
    * (spirv-val: "Invalid SPIR-V binary version 1.6 for target environment ...") */
   layout_case("function-offset-1.6", "mvk11", SPV_ENV_UNIVERSAL_1_6, offset, fn_s, fn_var, "",
               false, "version");
   layout_case("function-offset-1.5", "mvk11", SPV_ENV_UNIVERSAL_1_5, offset, fn_s, fn_var, "",
               false, "version");
   layout_case("function-offset-1.4", "mvk11", SPV_ENV_UNIVERSAL_1_4, offset, fn_s, fn_var, "",
               true, NULL);
}

/* --- units: the variables of one entry point --- */

/* SPIR-V `version` with two compute entry points "a" and "b". Each calls a function with a
 * Function uint[fn_len] and has a Private uint[priv_len] and a Workgroup uint[shared_len]
 * of its own (in its interface from SPIR-V 1.4, as there every global it uses must be); a
 * function no entry point reaches has a Function uint[2^32-1]. ids: entry points at e[2]. */
static void
two_entries(struct mod *m, uint32_t version, uint32_t fn_len, uint32_t priv_len,
            uint32_t shared_len, uint32_t e[2])
{
   memset(m, 0, sizeof(*m));
   const uint32_t head[] = { 0x07230203, version, 0, 0, 0 };
   memcpy(m->w, head, sizeof(head));
   m->n = 5;
   m->next = FIRST_FREE;
   uint32_t f[2], h[2], priv[2], shared[2];
   for (int i = 0; i < 2; i++) {
      f[i] = m->next++;
      h[i] = m->next++;
      priv[i] = m->next++;
      shared[i] = m->next++;
      e[i] = f[i];
   }
   const uint32_t dead = m->next++;
   OP(m, 17, 1);    /* OpCapability Shader */
   OP(m, 14, 0, 1); /* OpMemoryModel Logical GLSL450 */
   for (int i = 0; i < 2; i++) {
      if (version >= 0x10400)
         OP(m, 15, 5, f[i], 0x61 + (uint32_t)i, priv[i], shared[i]); /* OpEntryPoint GLCompute */
      else
         OP(m, 15, 5, f[i], 0x61 + (uint32_t)i);
   }
   for (int i = 0; i < 2; i++)
      OP(m, 16, f[i], 17, 1, 1, 1); /* LocalSize 1 1 1 */
   OP(m, 19, T_VOID);
   OP(m, 33, T_FN, T_VOID);
   OP(m, 21, T_UINT, 32, 0);
   const uint32_t fn_arr = mod_array(m, T_UINT, mod_const(m, fn_len));
   const uint32_t priv_arr = mod_array(m, T_UINT, mod_const(m, priv_len));
   const uint32_t shared_arr = mod_array(m, T_UINT, mod_const(m, shared_len));
   const uint32_t huge = mod_array(m, T_UINT, mod_const(m, 0xffffffff));
   const uint32_t p_fn = m->next++, p_huge = m->next++, p_priv = m->next++, p_shared = m->next++;
   OP(m, 32, p_fn, 7, fn_arr); /* OpTypePointer Function */
   OP(m, 32, p_huge, 7, huge);
   OP(m, 32, p_priv, 6, priv_arr);     /* Private */
   OP(m, 32, p_shared, 4, shared_arr); /* Workgroup */
   for (int i = 0; i < 2; i++) {
      OP(m, 59, p_priv, priv[i], 6);     /* OpVariable Private */
      OP(m, 59, p_shared, shared[i], 4); /* OpVariable Workgroup */
   }
   for (int i = 0; i < 2; i++) {
      OP(m, 54, T_VOID, f[i], 0, T_FN);
      OP(m, 248, m->next++);
      OP(m, 57, T_VOID, m->next++, h[i]); /* OpFunctionCall */
      OP(m, 62, priv[i], mod_const(m, 0)); /* OpStore (uses the Private one) */
      OP(m, 253);
      OP(m, 56);
      OP(m, 54, T_VOID, h[i], 0, T_FN);
      OP(m, 248, m->next++);
      OP(m, 59, p_fn, m->next++, 7); /* OpVariable Function */
      OP(m, 253);
      OP(m, 56);
   }
   OP(m, 54, T_VOID, dead, 0, T_FN);
   OP(m, 248, m->next++);
   OP(m, 59, p_huge, m->next++, 7);
   OP(m, 253);
   OP(m, 56);
   m->w[3] = m->next;
}

static void
entry_case(const char *name, uint32_t version, bool entry_a, bool by_interface, uint64_t want_elements,
           uint64_t want_bytes)
{
   struct mod m;
   uint32_t e[2];
   two_entries(&m, version, 600000, 1000, 6144, e);
   char why[192];
   struct vkr_spirv_info *info = vkr_spirv_scan(m.w, m.n * 4, why, sizeof(why));
   CHECK(info, "entry %s: scan: %s", name, why);
   if (!info)
      return;
   const struct vkr_spirv_entry *entry = entry_a ? vkr_spirv_entry(info, "a", 5) : NULL;
   CHECK(!entry_a || (entry && entry->function == e[0]), "entry %s: no entry point a", name);
   uint64_t n = 0, b = 0;
   const bool ok = vkr_spirv_function_elements(info, entry, by_interface, NULL, NULL, &n) &&
                   vkr_spirv_workgroup_bytes(info, entry, by_interface, NULL, NULL, &b);
   CHECK(ok && n == want_elements && b == want_bytes,
         "entry %s: %llu elements and %llu bytes, want %llu and %llu", name,
         (unsigned long long)n, (unsigned long long)b, (unsigned long long)want_elements,
         (unsigned long long)want_bytes);
   vkr_spirv_free(info);
}

static void
entry_units(void)
{
   /* the module: both helpers' Function uint[600000] (over the cap together), the dead
    * function's uint[2^32-1], both Private uint[1000], both Workgroup uint[6144] (48 KB) */
   const uint64_t dead = 0xffffffffull;
   entry_case("module", 0x10600, false, false, 1200000 + dead + 2000, 49152);
   /* entry point a on MoltenVK: its helper's Function variable (not b's, not the dead
    * function's), every Private and Workgroup variable (SPIRV-Cross declares each in it) */
   entry_case("a-mvk", 0x10600, true, false, 600000 + 2000, 49152);
   /* on KosmicKrisp from SPIR-V 1.4: only the globals in its interface */
   entry_case("a-kk", 0x10600, true, true, 600000 + 1000, 24576);
   /* before SPIR-V 1.4 the interface lists no globals: all of them */
   entry_case("a-kk-1.3", 0x10300, true, true, 600000 + 2000, 49152);
}

/* a struct of two of the previous one, `depth` deep, as a Private variable */
static uint32_t
dag_module(uint32_t depth, uint32_t *w)
{
   struct mod m;
   mod_begin(&m);
   uint32_t t = m.next++;
   OP(&m, 30, t, T_UINT);
   for (uint32_t i = 0; i < depth; i++) {
      const uint32_t n = m.next++;
      OP(&m, 30, n, t, t);
      t = n;
   }
   mod_end(&m, (uint32_t[]){ 0 }, t);
   memcpy(w, m.w, m.n * 4);
   return m.n;
}

static void
cost_units(void)
{
   uint32_t w[512];
   char why[192];
   /* 2^19 paths: under the cost; 2^31: refused before spirv-val reads it (it walked such a
    * type for each struct and each use, 30 deep past 20 s) */
   uint32_t n = dag_module(18, w);
   struct vkr_spirv_info *info = vkr_spirv_scan(w, n * 4, why, sizeof(why));
   CHECK(info && info->type_cost < VKR_SPIRV_MAX_TYPE_COST, "cost: depth 18 passes the scan (%s)",
         info ? "" : why);
   if (info) {
      struct vkr_spirv_target t;
      profile("kk", &t);
      const double t0 = now_us();
      CHECK(vkr_spirv_validate(&t, info, w, n * 4, why, sizeof(why), NULL), "cost: depth 18 valid: %s",
            why);
      printf("cost: a struct DAG of depth 18 costs %llu, spirv-val %.0f us\n",
             (unsigned long long)info->type_cost, now_us() - t0);
   }
   vkr_spirv_free(info);
   n = dag_module(30, w);
   info = vkr_spirv_scan(w, n * 4, why, sizeof(why));
   CHECK(info, "cost: depth 30 scans (%s)", why);
   if (info) {
      struct vkr_spirv_target t;
      profile("kk", &t);
      bool unsafe = false;
      CHECK(!vkr_spirv_validate(&t, info, w, n * 4, why, sizeof(why), &unsafe) && unsafe &&
               strstr(why, "too costly"),
            "cost: depth 30 is refused before spirv-val (%s)", why);
   }
   vkr_spirv_free(info);
}

int
main(int argc, char **argv)
{
   if (argc >= 3 && (!strcmp(argv[1], "pass") || !strcmp(argv[1], "refuse") || !strcmp(argv[1], "run")))
      return corpus(!strcmp(argv[1], "pass") ? 1 : !strcmp(argv[1], "refuse") ? 0 : 2, argv[2],
                    argc - 3, argv + 3);
   if (argc >= 4 && !strcmp(argv[1], "time"))
      return timing(argv[2], atoi(argv[3]), argc - 4, argv + 4);
   if (argc == 3 && !strcmp(argv[1], "units")) {
      size_t bytes;
      uint32_t *code = load(argv[2], &bytes);
      if (!code) {
         printf("FAIL: %s unreadable\n", argv[2]);
         return 1;
      }
      target_units();
      cache_units(code, bytes);
      elements_units();
      bytes_units();
      interface_units();
      entry_units();
      cost_units();
      layout_units();
      free(code);
      printf("units: %s\n", failures ? "FAIL" : "all ok");
      return failures != 0;
   }
   fprintf(stderr, "usage: %s pass|refuse|run PROFILE FILE... | time PROFILE REPS FILE... | units FILE\n",
           argv[0]);
   return 2;
}
