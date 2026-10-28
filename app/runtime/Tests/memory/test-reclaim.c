/* Test for qemu-hvf-free-page-reclaim-reusable.patch (no VM): does a free
 * page report give the old pages back to macOS?
 *
 * omacvm_reclaim_backing() and omacvm_reclaim_release() (QEMU's worker
 * thread runs the second; here right after the first), taken from the
 * patched accel/hvf/hvf-all.c by test-reclaim.sh, run on guest RAM in the
 * state QEMU's is in: anonymous memory that a second map shares (the
 * hypervisor's: hv_vm_map), so XNU sees it shared and copy-delay, split into
 * many map entries by earlier reports. Each measured report gets an
 * observer: one more mapping of exactly that range, made just before the
 * report. After it the observer still reaches the range's old pages (QEMU's
 * own mapping no longer does): none may be left resident unless macOS may
 * take it (reusable), none compressed. Only pages macOS was compressing at
 * that very moment may stay (XNU skips a page in the compressor's queue; the
 * release advises again 20 ms later): up to 5 % of the reported pages,
 * counted apart. The pages next to each report keep their data; the reported
 * ones read 0, or, for every other report, what the guest wrote into the range
 * between QEMU's acknowledgement and the release.
 *
 *   test-reclaim [--hv] [--compressed SECONDS]
 *
 * Without --hv a second mapping of the region stands in for the hypervisor's
 * (mach_vm_remap, no copy: what XNU makes of hv_vm_map), and the helper's
 * hv_vm_unmap()/hv_vm_map() empty and remake that mapping's range. --hv uses
 * a real VM (Hypervisor.framework, no vCPU; the binary needs the hypervisor
 * entitlement): exit 2 when the Mac has no hypervisor for this process.
 * --compressed waits up to SECONDS for macOS to compress the region first (a
 * Mac short of memory does it in seconds; one with room may never), and then
 * the compressed pages must go too.
 *
 * Built two ways by test-reclaim.sh: the patch's helper (must pass; with
 * OMACVM_RECLAIM_REUSABLE=0 it must fail) and -DHELPER_MAIN (main's helper up
 * to 3.2.10, the replacement alone: must fail, so the test catches the leak).
 */
#include <Hypervisor/Hypervisor.h>
#include <assert.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

typedef uint64_t hwaddr;

#define RAM_IPA 0x40000000ull
#define RAM_SIZE (512ull << 20)
#define BLOCK (4ull << 20)
#define KB 1024ull
#define MB (1024ull * 1024ull)

static bool use_hv;
static uint8_t *ram;          /* QEMU's mapping of guest RAM */
static uint8_t *hvmap;        /* the stand-in for the hypervisor's mapping */
static size_t pg;

static void die(const char *what, kern_return_t kr)
{
    fprintf(stderr, "test-reclaim: %s failed: %s (%d)\n", what, mach_error_string(kr), kr);
    exit(1);
}

/* The hypervisor's side: real, or a second mapping of the same memory. */
static hv_return_t test_hv_vm_unmap(hv_ipa_t ipa, size_t size)
{
    if (use_hv) {
        return hv_vm_unmap(ipa, size);
    }
    /* The hypervisor's map is not QEMU's: its range stays taken (no hole
     * that the helper's own mappings could land in), only without the memory. */
    void *at = hvmap + (ipa - RAM_IPA);
    return mmap(at, size, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == at ? HV_SUCCESS : HV_ERROR;
}

static hv_return_t test_hv_vm_map(void *addr, hv_ipa_t ipa, size_t size, hv_memory_flags_t flags)
{
    if (use_hv) {
        return hv_vm_map(addr, ipa, size, flags);
    }
    mach_vm_address_t at = (mach_vm_address_t)(hvmap + (ipa - RAM_IPA));
    vm_prot_t cur, max;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &at, size, 0,
                                     VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                     (mach_vm_address_t)addr, FALSE, &cur, &max, VM_INHERIT_NONE);
    return kr == KERN_SUCCESS && at == (mach_vm_address_t)(hvmap + (ipa - RAM_IPA)) ? HV_SUCCESS : HV_ERROR;
}

#define hv_vm_unmap test_hv_vm_unmap
#define hv_vm_map test_hv_vm_map
#define assert_hvf_ok(expr) do { \
        hv_return_t r_ = (expr); \
        if (r_ != HV_SUCCESS) { fprintf(stderr, "test-reclaim: %s = 0x%x\n", #expr, r_); abort(); } \
    } while (0)
#define trace_hvf_vm_unmap(...) ((void)0)
#define trace_hvf_vm_map(...) ((void)0)
#define error_report(...) (fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
#define warn_report(...) (fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))

#if defined(HELPER_MAIN)
/* main up to 3.2.10 (qemu-hvf-free-page-reclaim.patch): the replacement alone */
static const char *helper_name = "main's helper (MAP_FIXED alone)";
static mach_vm_address_t omacvm_reclaim_backing(hwaddr gpa, void *host, size_t size, hv_memory_flags_t flags)
{
    assert_hvf_ok(hv_vm_unmap(gpa, size));
    void *replacement = mmap(host, size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(replacement == host);
    assert_hvf_ok(hv_vm_map(host, gpa, size, flags));
    return 0;
}
#else
static const char *helper_name = "the patch's helper";
#include "reclaim.inc"
#endif

static void fill(uint64_t off, uint64_t len, unsigned round);

/* A report as QEMU handles it: the new backing under the BQL, then the old
 * range's release (QEMU's worker thread does it; here right after). With
 * round > 0 the guest uses the range again in between (QEMU acknowledged the
 * report, the worker has not got to it yet): that data must stay. */
static void reclaim_using(uint64_t off, uint64_t len, unsigned round)
{
    mach_vm_address_t aside = omacvm_reclaim_backing(RAM_IPA + off, ram + off, len,
                                                     HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC);
    if (round) {
        fill(off, len, round);
    }
#if !defined(HELPER_MAIN)
    if (aside) {
        omacvm_reclaim_release(aside, len, true, NULL);
    }
#else
    (void)aside;
#endif
}

static void reclaim(uint64_t off, uint64_t len)
{
    reclaim_using(off, len, 0);
}

/* Data: one word per 1 KiB, from the page's guest address and a round. */
static uint64_t word(uint64_t off, unsigned round)
{
    uint64_t x = (RAM_IPA + off) * 0x9e3779b97f4a7c15ull ^ ((uint64_t)round << 56);
    x ^= x >> 29;
    return x | 1;   /* never 0: a page given back reads 0 */
}

static void fill(uint64_t off, uint64_t len, unsigned round)
{
    for (uint64_t o = off; o < off + len; o += KB) {
        *(volatile uint64_t *)(ram + o) = word(o, round);
    }
}

static uint8_t *round_of;     /* per 16 KiB page: the round its data is from, 0xff = given back */

static unsigned long check_data(void)
{
    unsigned long bad = 0;
    for (uint64_t p = 0; p < RAM_SIZE / pg; p++) {
        for (uint64_t o = p * pg; o < (p + 1) * pg; o += KB) {
            uint64_t v = *(volatile uint64_t *)(ram + o);
            uint64_t want = round_of[p] == 0xff ? 0 : word(o, round_of[p]);
            if (v != want) {
                if (bad++ < 5) {
                    fprintf(stderr, "  data: offset 0x%llx reads 0x%llx, want 0x%llx\n",
                            (unsigned long long)o, (unsigned long long)v, (unsigned long long)want);
                }
                break;
            }
        }
    }
    return bad;
}

/* XNU's view of the map entries over [off, off + len) of QEMU's mapping. */
static bool entries_shared(uint64_t off, uint64_t len, unsigned *min_ref, unsigned *nent)
{
    mach_vm_address_t a = (mach_vm_address_t)(ram + off), end = a + len;
    bool ok = true;
    *min_ref = ~0u;
    *nent = 0;
    while (a < end) {
        mach_vm_address_t r = a;
        mach_vm_size_t sz = 0;
        natural_t depth = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = mach_vm_region_recurse(mach_task_self(), &r, &sz, &depth,
                                                  (vm_region_recurse_info_t)&info, &cnt);
        if (kr != KERN_SUCCESS) {
            die("mach_vm_region_recurse", kr);
        }
        if (r > a) {
            fprintf(stderr, "  hole at 0x%llx\n", (unsigned long long)(a - (mach_vm_address_t)ram));
            return false;
        }
        (*nent)++;
        if (info.share_mode != SM_TRUESHARED || info.ref_count < 2) {
            if (ok) {
                fprintf(stderr, "  entry at 0x%llx: share mode %u ref %u (want %u, >= 2)\n",
                        (unsigned long long)(r - (mach_vm_address_t)ram), info.share_mode,
                        info.ref_count, SM_TRUESHARED);
            }
            ok = false;
        }
        if (info.ref_count < *min_ref) {
            *min_ref = info.ref_count;
        }
        a = r + sz;
    }
    return ok;
}

typedef struct {
    unsigned long present, reusable, out, held;   /* pages */
} Pages;

#define OUT(d) ((d) & VM_PAGE_QUERY_PAGE_PAGED_OUT)
#define HELD(d) (((d) & VM_PAGE_QUERY_PAGE_PRESENT) && !((d) & VM_PAGE_QUERY_PAGE_REUSABLE))

static int *query(mach_vm_address_t a, uint64_t len, Pages *p)
{
    mach_vm_size_t n = len / pg;
    int *disp = calloc(n, sizeof *disp);
    mach_vm_size_t cnt = n;
    kern_return_t kr = mach_vm_page_range_query(mach_task_self(), a, len, (mach_vm_address_t)disp, &cnt);
    if (kr != KERN_SUCCESS) {
        die("mach_vm_page_range_query", kr);
    }
    memset(p, 0, sizeof *p);
    for (mach_vm_size_t i = 0; i < cnt; i++) {
        if (OUT(disp[i])) {
            p->out++;
        }
        if (disp[i] & VM_PAGE_QUERY_PAGE_PRESENT) {
            p->present++;
            if (disp[i] & VM_PAGE_QUERY_PAGE_REUSABLE) {
                p->reusable++;
            } else {
                p->held++;
            }
        }
    }
    return disp;
}

static uint64_t sysctl_u64(const char *name)
{
    uint64_t v = 0;
    size_t l = sizeof v;
    if (sysctlbyname(name, &v, &l, NULL, 0)) {
        return 0;
    }
    return l == 4 ? (uint32_t)v : v;
}

static unsigned failures;
static Pages sum_before, sum_after;
static unsigned reports;
static unsigned long reported_pages, kept_compressed, in_flight;

/* One free page report of [off, off + len), with its observer. Every other
 * report, the guest writes the range again before the release. */
static void report(uint64_t off, uint64_t len, const char *what)
{
    unsigned reuse = reports % 2 ? 2 : 0;
    unsigned min_ref, nent;
    vm_prot_t cur, max;
    mach_vm_address_t obs = 0;

    if (!entries_shared(off, len, &min_ref, &nent)) {
        fprintf(stderr, "FAIL %s: guest RAM is not in QEMU's state (shared with a second map)\n", what);
        failures++;
    }
    kern_return_t kr = mach_vm_remap(mach_task_self(), &obs, len, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                     (mach_vm_address_t)(ram + off), FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        die("mach_vm_remap (observer)", kr);
    }
    Pages b, a;
    int *before = query(obs, len, &b);
    reclaim_using(off, len, reuse);
    int *after = query(obs, len, &a);
    mach_vm_deallocate(mach_task_self(), obs, len);
    if (reuse) {   /* what the guest wrote since must not be up for grabs */
        Pages now;
        free(query((mach_vm_address_t)(ram + off), len, &now));
        if (now.reusable) {
            printf("FAIL %s: %lu pages the guest wrote after the report are marked reusable: LEFT ON THE MAC\n",
                   what, now.reusable);
            failures++;
        }
    }
    /* A page compressed before the report must be gone. One resident before
     * and still on the Mac after was on its way into the compressor (macOS
     * skips pages it is compressing at that moment): counted apart. */
    unsigned long kept = 0, flight = 0;
    for (uint64_t i = 0; i < len / pg; i++) {
        if (OUT(before[i]) && (OUT(after[i]) || HELD(after[i]))) {
            kept++;
        } else if (OUT(after[i]) || HELD(after[i])) {
            flight++;
        }
    }
    free(before);
    free(after);
    kept_compressed += kept;
    in_flight += flight;
    for (uint64_t p = off / pg; p < (off + len) / pg; p++) {
        round_of[p] = reuse ? reuse : 0xff;
    }
    reports++;
    reported_pages += len / pg;
    sum_before.present += b.present;
    sum_before.out += b.out;
    sum_after.held += a.held;
    sum_after.reusable += a.reusable;
    sum_after.out += a.out;
    printf("  %-34s %5llu KiB, %u entries, ref >= %u: before %lu resident %lu compressed; "
           "after %lu held %lu reusable %lu compressed  %s\n",
           what, (unsigned long long)(len / KB), nent, min_ref, b.present, b.out, a.held, a.reusable, a.out,
           kept ? "LEFT ON THE MAC" : flight ? "ok, some were on their way into the compressor" : "ok");
}

int main(int argc, char **argv)
{
    int wait_s = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hv")) {
            use_hv = true;
        } else if (!strcmp(argv[i], "--compressed") && i + 1 < argc) {
            wait_s = atoi(argv[++i]);
        } else {
            fprintf(stderr, "usage: test-reclaim [--hv] [--compressed SECONDS]\n");
            return 2;
        }
    }
    pg = (size_t)getpagesize();
    round_of = calloc(RAM_SIZE / pg, 1);
    printf("test-reclaim: %s, %s, page %zu KiB\n", helper_name,
           use_hv ? "a real hypervisor map" : "a second map standing in for the hypervisor's", pg / 1024);

    ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (ram == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    fill(0, RAM_SIZE, 0);   /* the guest used all of it */

    if (use_hv) {
        hv_return_t r = hv_vm_create(NULL);
        if (r != HV_SUCCESS) {
            printf("test-reclaim: SKIP --hv: hv_vm_create = 0x%x (no hypervisor for this process)\n", r);
            return 2;
        }
        assert_hvf_ok(hv_vm_map(ram, RAM_IPA, RAM_SIZE, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));
    } else {
        mach_vm_address_t a = 0;
        vm_prot_t cur, max;
        kern_return_t kr = mach_vm_remap(mach_task_self(), &a, RAM_SIZE, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                         (mach_vm_address_t)ram, FALSE, &cur, &max, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
            die("mach_vm_remap (hypervisor stand-in)", kr);
        }
        hvmap = (uint8_t *)a;
    }

    /* Before any observer: the hypervisor's map alone makes guest RAM shared. */
    unsigned min_ref, nent;
    if (!entries_shared(0, RAM_SIZE, &min_ref, &nent)) {
        fprintf(stderr, "FAIL: guest RAM is not shared with the hypervisor's map\n");
        failures++;
    }
    printf("  guest RAM: %u entries, all shared (true share), ref >= %u\n", nent, min_ref);

    /* Earlier reports split guest RAM into many entries; the guest used
     * those ranges again since (round 1): blocks 0, 8, 16, ... and two
     * halves of block 4 reported apart. */
    for (uint64_t b = 0; b < RAM_SIZE / BLOCK; b += 8) {
        reclaim(b * BLOCK, BLOCK);
        fill(b * BLOCK, BLOCK, 1);
        memset(round_of + b * BLOCK / pg, 1, BLOCK / pg);
    }
    for (uint64_t h = 0; h < 2; h++) {
        uint64_t off = 4 * BLOCK + h * BLOCK / 2;
        reclaim(off, BLOCK / 2);
        fill(off, BLOCK / 2, 1);
        memset(round_of + off / pg, 1, BLOCK / 2 / pg);
    }

    if (!entries_shared(0, RAM_SIZE, &min_ref, &nent)) {
        fprintf(stderr, "FAIL: guest RAM is not shared after the earlier reports\n");
        failures++;
    }
    printf("  after earlier reports: %u entries, all shared (true share), ref >= %u\n", nent, min_ref);

    if (wait_s > 0) {
        task_vm_info_data_t ti;
        for (int t = 0; t <= wait_s; t += 2) {
            mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
            task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&ti, &c);
            if (ti.compressed >= RAM_SIZE * 9 / 10 || t == wait_s) {
                break;
            }
            sleep(2);
        }
        printf("  compressed by macOS before the reports: %llu of %llu MB\n",
               (unsigned long long)(ti.compressed / MB), (unsigned long long)(RAM_SIZE / MB));
    }

    uint64_t shared0 = sysctl_u64("vm.reusable_pages_shared");
    /* Reports as Linux sends them: power-of-two blocks of 256 KiB to 4 MiB. */
    for (uint64_t b = 3; b < RAM_SIZE / BLOCK; b += 8) {
        report(b * BLOCK, BLOCK, "4 MiB in an untouched part");
    }
    report(4 * BLOCK, BLOCK, "4 MiB over two earlier reports");
    report(8 * BLOCK + MB, 256 * KB, "256 KiB inside an earlier report");
    report(16 * BLOCK + 2 * MB, 2 * MB, "2 MiB inside an earlier report");
    report(5 * BLOCK + 512 * KB, 512 * KB, "512 KiB next to an earlier one");
    report(31 * BLOCK, BLOCK, "4 MiB before a 128 MiB boundary");
    report(33 * BLOCK, 1 * MB, "1 MiB after an earlier report");
    uint64_t shared1 = sysctl_u64("vm.reusable_pages_shared");

    unsigned long bad = check_data();
    printf("test-reclaim: %u reports, %lu pages: %lu resident + %lu compressed before; "
           "after %lu held, %lu reusable, %lu compressed; neighbours: %lu pages wrong; "
           "XNU skipped shared pages %llu times meanwhile (all processes)\n",
           reports, reported_pages, sum_before.present,
           sum_before.out, sum_after.held, sum_after.reusable, sum_after.out, bad,
           (unsigned long long)(shared1 - shared0));
    /* Compressed copies must all go; of the resident pages, only those macOS
     * was compressing at that moment may stay (up to 5 %: a Mac short of
     * memory; main's helper leaves all of them). */
    if (kept_compressed) {
        fprintf(stdout, "FAIL: %lu compressed pages stayed compressed: LEFT ON THE MAC\n", kept_compressed);
        failures++;
    }
    if (in_flight * 20 > reported_pages) {
        fprintf(stdout, "FAIL: %lu of %lu pages stayed on the Mac: LEFT ON THE MAC\n", in_flight, reported_pages);
        failures++;
    } else if (in_flight) {
        printf("test-reclaim: %lu pages (%.1f %%) were on their way into the compressor during their report "
               "and stayed (allowed up to 5 %%)\n", in_flight, 100.0 * in_flight / reported_pages);
    }
    if (bad) {
        fprintf(stderr, "FAIL: %lu pages lost or kept data they should not have\n", bad);
        failures++;
    }
    if (use_hv) {
        hv_vm_destroy();
    }
    if (failures) {
        printf("test-reclaim: FAILED (%u)\n", failures);
        return 1;
    }
    printf("test-reclaim: all ok\n");
    return 0;
}
