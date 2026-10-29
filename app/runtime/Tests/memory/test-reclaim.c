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
 *   test-reclaim --keeps
 *   test-reclaim --overflow
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
 * to 3.2.11, the replacement alone: must fail, so the test catches the leak).
 *
 * --keeps (the patch's helper): when macOS keeps the pages anyway, the move
 * aside stops for the run and the file OMACVM_RECLAIM_STATUS names says so
 * (the app then turns its give-back while macOS compresses off). The window
 * rule on numbers; then real pages: releases the advice works on (no word),
 * releases of memory a child process shares (XNU skips the advice there
 * without an error: the window rule must see it), and a read-only range
 * (madvise refuses it).
 *
 * --overflow (the patch's helper, QEMU's queue and worker, a second map): the
 * worker falls behind until its queue is full. No advice may run under the
 * BQL (here: while the test's thread reports): a range the worker has no
 * room for, or that cannot move aside, gets the new backing alone and is
 * counted; each report's hold covers all it did under the BQL; the run's
 * qemu.log line says "reported", what was not moved aside and why, and a
 * p99 no higher than the longest hold.
 */
#include <Hypervisor/Hypervisor.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
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
#if defined(HELPER_MAIN)
#define warn_report(...) (fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
#else
static unsigned warnings;    /* qemu.log lines the helper wrote */
#define warn_report(...) (warnings++, fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
#endif

#if defined(HELPER_MAIN)
/* main up to 3.2.11 (qemu-hvf-free-page-reclaim.patch): the replacement alone */
static const char *helper_name = "main's helper (MAP_FIXED alone)";
static bool omacvm_reclaim_on(void)
{
    return false;
}

static mach_vm_address_t omacvm_reclaim_backing(hwaddr gpa, void *host, size_t size, hv_memory_flags_t flags,
                                                bool aside)
{
    assert_hvf_ok(hv_vm_unmap(gpa, size));
    void *replacement = mmap(host, size, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(replacement == host);
    assert_hvf_ok(hv_vm_map(host, gpa, size, flags));
    return 0;
}
#else
static const char *helper_name = "the patch's helper";

/* What the patch's part needs from QEMU, for this test. */
typedef pthread_mutex_t QemuMutex;
typedef pthread_cond_t QemuCond;
typedef pthread_t QemuThread;
#define QEMU_THREAD_DETACHED 1
#define qemu_mutex_init(m) pthread_mutex_init((m), NULL)
#define qemu_mutex_lock(m) pthread_mutex_lock(m)
#define qemu_mutex_unlock(m) pthread_mutex_unlock(m)
#define qemu_cond_init(c) pthread_cond_init((c), NULL)
#define qemu_cond_wait(c, m) pthread_cond_wait((c), (m))
#define qemu_cond_signal(c) pthread_cond_signal(c)
#define NANOSECONDS_PER_SECOND 1000000000LL
#undef MIN
#undef MAX
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
typedef struct Notifier Notifier;
struct Notifier {
    void (*notify)(Notifier *n, void *data);
};

static void qemu_add_exit_notifier(Notifier *n)
{
    (void)n;
}

static int64_t get_clock(void)
{
    return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

/* --overflow: the worker does not run until the test starts it (the guest
 * reports faster than it releases). */
static bool hold_worker;
static void *(*held_worker)(void *);

static void qemu_thread_create(QemuThread *t, const char *name, void *(*fn)(void *), void *arg, int mode)
{
    if (hold_worker) {
        held_worker = fn;
        return;
    }
    pthread_create(t, NULL, fn, arg);
    pthread_detach(*t);
}

/* The test's thread holds "the BQL" while it reports (QEMU's main loop). */
static __thread bool in_bql;
static bool bql_locked(void)
{
    return in_bql;
}

/* qemu.log's info lines: the last one, for the --overflow checks. */
static pthread_mutex_t info_lock = PTHREAD_MUTEX_INITIALIZER;
static char last_info[1024];
#define info_report(...) do { \
        pthread_mutex_lock(&info_lock); \
        snprintf(last_info, sizeof(last_info), __VA_ARGS__); \
        fprintf(stderr, "%s\n", last_info); \
        pthread_mutex_unlock(&info_lock); \
    } while (0)

static void test_autofree(void *p)
{
    free(*(void **)p);
}
#define g_autofree __attribute__((cleanup(test_autofree)))
#define g_free free
static char *g_strdup_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static char *g_strdup_printf(const char *fmt, ...)
{
    va_list ap;
    char *s = NULL;
    va_start(ap, fmt);
    if (vasprintf(&s, fmt, ap) < 0) {
        s = NULL;
    }
    va_end(ap);
    return s;
}

/* madvise under "the BQL" is what the patch must never do; each one sleeps
 * 5 ms there, so a hold that misses it shows. */
static unsigned long advice_in_bql;
static int test_madvise(void *addr, size_t len, int advice)
{
    if (in_bql) {
        advice_in_bql++;
        usleep(5000);
    }
    return madvise(addr, len, advice);
}

/* --overflow: no room to move a range aside. */
static bool remap_fails;
static kern_return_t test_mach_vm_remap(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size,
                                        mach_vm_offset_t mask, int flags, vm_map_t src, mach_vm_address_t src_address,
                                        boolean_t copy, vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inherit)
{
    if (remap_fails) {
        return KERN_NO_SPACE;
    }
    return mach_vm_remap(target, address, size, mask, flags, src, src_address, copy, cur, max, inherit);
}

#define madvise test_madvise
#define mach_vm_remap test_mach_vm_remap
#include "reclaim.inc"
#undef madvise
#undef mach_vm_remap
#endif

static void fill(uint64_t off, uint64_t len, unsigned round);

/* A report as QEMU handles it: the new backing under the BQL, then the old
 * range's release (QEMU's worker thread does it; here right after). With
 * round > 0 the guest uses the range again in between (QEMU acknowledged the
 * report, the worker has not got to it yet): that data must stay. */
static void reclaim_using(uint64_t off, uint64_t len, unsigned round)
{
    mach_vm_address_t aside = omacvm_reclaim_backing(RAM_IPA + off, ram + off, len,
                                                     HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC,
                                                     omacvm_reclaim_on());
    if (round) {
        fill(off, len, round);
    }
#if !defined(HELPER_MAIN)
    if (aside) {
        omacvm_reclaim_release(aside, len, NULL);
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

#if !defined(HELPER_MAIN)
static const char *status_path;

static void expect(bool ok, const char *what)
{
    printf("  %s %s\n", ok ? "ok  " : "FAIL", what);
    failures += !ok;
}

/* The status file: "" when there is none. */
static const char *status_text(void)
{
    static char buf[512];
    int fd = open(status_path, O_RDONLY);
    ssize_t n = fd < 0 ? 0 : read(fd, buf, sizeof(buf) - 1);
    if (fd >= 0) {
        close(fd);
    }
    buf[n > 0 ? n : 0] = 0;
    return buf;
}

/* A new run: the fix on, nothing said yet. */
static void fresh_run(void)
{
    omacvm_reclaim_reusable = -1;
    omacvm_reclaim_kept = false;
    warnings = 0;
    unlink(status_path);
}

/* QEMU's worker on BLOCKS blocks of 4 MiB at host: each moved aside (as
 * omacvm_reclaim_backing does) and released, the window rule after each. */
static void worker_releases(uint8_t *host, unsigned blocks)
{
    OmacvmReclaimJudge judge = { 0, 0 };
    char why[128];
    for (unsigned b = 0; b < blocks; b++) {
        mach_vm_address_t aside = 0;
        vm_prot_t cur, max;
        kern_return_t kr = mach_vm_remap(mach_task_self(), &aside, BLOCK, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                         (mach_vm_address_t)(host + b * BLOCK), FALSE, &cur, &max, VM_INHERIT_NONE);
        if (kr != KERN_SUCCESS) {
            die("mach_vm_remap (aside)", kr);
        }
        void *fresh = mmap(host + b * BLOCK, BLOCK, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
        assert(fresh == host + b * BLOCK);
        OmacvmReclaimPages before, left = omacvm_reclaim_release(aside, BLOCK, &before);
        if (!omacvm_reclaim_takes(&judge, before, left, why, sizeof(why))) {
            omacvm_reclaim_keeps(why);
        }
    }
}

static uint8_t *filled(size_t len)
{
    uint8_t *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    for (size_t o = 0; o < len; o += KB) {
        *(volatile uint64_t *)(m + o) = o | 1;
    }
    return m;
}

static int keeps_test(void)
{
    static char path[] = "/tmp/omacvm-test-reclaim-status.XXXXXX";
    OmacvmReclaimJudge j = { 0, 0 };
    OmacvmReclaimPages held4 = { BLOCK, 0 }, none = { 0, 0 }, half4 = { BLOCK / 2, 0 }, quarter4 = { 0, BLOCK / 4 };
    char why[128] = "";
    bool ok;
    int fd = mkstemp(path);

    if (fd < 0) {
        perror("mkstemp");
        return 1;
    }
    close(fd);
    status_path = path;
    setenv("OMACVM_RECLAIM_STATUS", path, 1);
    printf("test-reclaim: --keeps: macOS keeping the pages stops the move aside and the app hears it\n");

    /* The window rule on numbers: 16 releases of 4 MiB held fill 64 MB. */
    ok = true;
    for (int i = 0; i < 16; i++) {
        ok = ok && omacvm_reclaim_takes(&j, held4, none, why, sizeof(why));
    }
    expect(ok && !j.held, "64 MB held, none left: the advice takes (the window starts again)");
    ok = true;
    for (int i = 0; i < 16; i++) {
        ok = ok && omacvm_reclaim_takes(&j, held4, quarter4, why, sizeof(why));
    }
    expect(ok, "a quarter left (compressed): still takes");
    for (int i = 0; i < 15; i++) {
        ok = ok && omacvm_reclaim_takes(&j, held4, half4, why, sizeof(why));
    }
    expect(ok, "half left, window not full yet (60 MB): no verdict");
    ok = omacvm_reclaim_takes(&j, held4, half4, why, sizeof(why));
    expect(!ok && strstr(why, "32 of 64 MB") != NULL, "half left over 64 MB: macOS keeps them, with the numbers");
    j = (OmacvmReclaimJudge) { 0, 0 };
    ok = true;
    for (int i = 0; i < 1000; i++) {
        ok = ok && omacvm_reclaim_takes(&j, none, none, why, sizeof(why));
    }
    expect(ok, "ranges the Mac never held (untouched): no verdict");

    /* Real pages the advice works on (one map, moved aside: copy-delay). */
    fresh_run();
    expect(omacvm_reclaim_on(), "a new run: on");
    uint8_t *works = filled(20 * BLOCK);
    worker_releases(works, 20);
    expect(omacvm_reclaim_on() && !omacvm_reclaim_kept && !warnings && !*status_text(),
           "80 MB released, the advice takes: still on, no line, no status file");
    munmap(works, 20 * BLOCK);

    /* Real pages a child process shares (copy-on-write since fork): XNU skips
     * the advice there and madvise says nothing. */
    fresh_run();
    uint8_t *shared = filled(20 * BLOCK);
    uint64_t skipped0 = sysctl_u64("vm.reusable_pages_shared");
    pid_t child = fork();
    if (child == 0) {
        for (;;) {
            pause();
        }
    }
    if (child < 0) {
        perror("fork");
        return 1;
    }
    worker_releases(shared, 20);
    uint64_t skipped1 = sysctl_u64("vm.reusable_pages_shared");
    kill(child, SIGKILL);
    waitpid(child, NULL, 0);
    munmap(shared, 20 * BLOCK);
    printf("  (XNU skipped shared pages %" PRIu64 " times meanwhile)\n", skipped1 - skipped0);
    expect(!omacvm_reclaim_on() && omacvm_reclaim_kept, "advice skipped without an error: the move aside stops");
    expect(warnings == 1, "  one qemu.log line");
    expect(strncmp(status_text(), "reclaim=keeps\nwhy=", 18) == 0 && strstr(status_text(), "MB the Mac held stayed"),
           "  the status file says reclaim=keeps and why");
    printf("  status file: %s", status_text());
    omacvm_reclaim_keeps("again");
    expect(warnings == 1 && !strstr(status_text(), "again"), "  said once a run");

    /* A range madvise refuses (read-only): at once, from the release itself. */
    fresh_run();
    expect(omacvm_reclaim_on(), "a new run: on");
    uint8_t *ro = filled(BLOCK);
    mprotect(ro, BLOCK, PROT_READ);
    mach_vm_address_t aside = 0;
    vm_prot_t cur, max;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &aside, BLOCK, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                     (mach_vm_address_t)ro, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        die("mach_vm_remap (read-only)", kr);
    }
    omacvm_reclaim_release(aside, BLOCK, NULL);
    munmap(ro, BLOCK);
    expect(!omacvm_reclaim_on() && warnings == 1 && strstr(status_text(), "why=madvise refused: "),
           "madvise refused: the move aside stops, one line, the status file says why");
    printf("  status file: %s", status_text());

    /* No status file named (an older app): the line only. */
    fresh_run();
    unsetenv("OMACVM_RECLAIM_STATUS");
    omacvm_reclaim_keeps("test");
    expect(!omacvm_reclaim_on() && warnings == 1 && !*status_text(), "no OMACVM_RECLAIM_STATUS: the qemu.log line only");
    unlink(path);
    if (failures) {
        printf("test-reclaim: FAILED (%u)\n", failures);
        return 1;
    }
    printf("test-reclaim: all ok\n");
    return 0;
}

/* One report of one block under "the BQL", as hvf_report_free_pages() and
 * the balloon make it: its hold as the patch counts it, and how long it
 * really kept the BQL. */
static void bql_report(uint64_t off, uint64_t len, int64_t *hold, int64_t *wall)
{
    int64_t t0;

    in_bql = true;
    t0 = get_clock();
    omacvm_reclaim_report(t0, RAM_IPA + off, ram + off, len, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC);
    *wall = get_clock() - t0;
    *hold = omacvm_reclaim_cur.ns;
    hvf_report_free_pages_done();
    in_bql = false;
}

/* Until the worker's queue is empty and it released at least want bytes. */
static bool worker_done(uint64_t want, int seconds)
{
    for (int i = 0; i < seconds * 10; i++) {
        pthread_mutex_lock(&omacvm_reclaim_w.lock);
        bool done = !omacvm_reclaim_w.count && omacvm_reclaim_w.released >= want;
        pthread_mutex_unlock(&omacvm_reclaim_w.lock);
        if (done) {
            return true;
        }
        usleep(100000);
    }
    return false;
}

/*
 * --overflow: the worker falls behind. It does not run until the test starts
 * it, so its queue fills (4096 ranges) and one more report comes: that range
 * must get the new backing alone, with no advice under the BQL, counted as
 * not moved aside. The worker then runs and releases what it was given; a
 * range that finds no room to move aside gets what the overflow got. Every
 * report's hold covers all it did under the BQL. The run's qemu.log line
 * says "reported", what was not moved aside and why, and its p99 is never
 * above the longest hold. Report i is page 2i; page 2i + 1 keeps its data.
 */
static int overflow_test(void)
{
    const uint64_t queue = OMACVM_RECLAIM_QUEUE, span = 2 * (queue + 3) * pg;
    int64_t hold, wall, gap = 0;
    unsigned long wrong = 0;
    uint64_t i;
    char line[1024];

    printf("test-reclaim: --overflow: the worker falls behind; nothing is advised under the BQL\n");
    ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (ram == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    mach_vm_address_t a = 0;
    vm_prot_t cur, max;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &a, RAM_SIZE, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                     (mach_vm_address_t)ram, FALSE, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        die("mach_vm_remap (hypervisor stand-in)", kr);
    }
    hvmap = (uint8_t *)a;
    fill(0, span, 0);
    unsetenv("OMACVM_RECLAIM_REUSABLE");
    unsetenv("OMACVM_RECLAIM_CHECK");

    hold_worker = true;
    for (i = 0; i < queue; i++) {
        bql_report(2 * i * pg, pg, &hold, &wall);
        gap = MAX(gap, wall - hold);
    }
    expect(held_worker && omacvm_reclaim_w.count == queue && !omacvm_reclaim_run.in_place,
           "4096 ranges moved aside wait for the worker, which does not run yet");
    bql_report(2 * queue * pg, pg, &hold, &wall);
    gap = MAX(gap, wall - hold);
    expect(omacvm_reclaim_run.in_place == pg && (omacvm_reclaim_run.why & OMACVM_RECLAIM_WHY_FULL) &&
           omacvm_reclaim_w.count == queue,
           "the queue full: the next range gets the new backing alone, counted (the worker's queue was full)");
    expect(!advice_in_bql, "  no advice under the BQL");

    hold_worker = false;
    pthread_t t;
    if (!held_worker || pthread_create(&t, NULL, held_worker, NULL)) {
        printf("FAIL: no worker to start\n");
        return 1;
    }
    pthread_detach(t);
    expect(worker_done(queue * pg, 60), "the worker, once it runs, releases all 4096 ranges");

    remap_fails = true;
    bql_report(2 * (queue + 1) * pg, pg, &hold, &wall);
    remap_fails = false;
    gap = MAX(gap, wall - hold);
    expect(omacvm_reclaim_run.in_place == 2 * pg && (omacvm_reclaim_run.why & OMACVM_RECLAIM_WHY_NOROOM) &&
           !advice_in_bql,
           "no room to move a range aside: the new backing alone, counted, no advice under the BQL");
    bql_report(2 * (queue + 2) * pg, pg, &hold, &wall);
    gap = MAX(gap, wall - hold);
    expect(worker_done((queue + 1) * pg, 10), "the next range with room goes to the worker again");

    printf("  (largest time under the BQL a report's hold missed: %.3f ms)\n", gap / 1e6);
    expect(gap < 2000000, "every report's hold covers all it did under the BQL");
    pthread_mutex_lock(&omacvm_reclaim_w.lock);
    uint64_t released = omacvm_reclaim_w.released;
    uint64_t left = omacvm_reclaim_w.left_resident + omacvm_reclaim_w.left_compressed;
    pthread_mutex_unlock(&omacvm_reclaim_w.lock);
    printf("  (the worker released %.1f MB, %.1f MB of it still held)\n", released / (double)MB, left / (double)MB);
    expect(released == (queue + 1) * pg && left * 20 <= released,
           "what the worker released is no longer held (up to 5 % on its way into the compressor)");
    for (i = 0; i < queue + 3; i++) {
        uint64_t given = 2 * i * pg, kept = given + pg;
        if (*(volatile uint64_t *)(ram + given) != 0 || *(volatile uint64_t *)(ram + kept) != word(kept, 0)) {
            wrong++;
        }
    }
    expect(!wrong, "every reported page reads 0, every page beside it keeps its data");

    omacvm_reclaim_log("this run", &omacvm_reclaim_run);
    pthread_mutex_lock(&info_lock);
    snprintf(line, sizeof(line), "%s", last_info);
    pthread_mutex_unlock(&info_lock);
    printf("  qemu.log: %s\n", line);
    double p99 = -1, longest = -1;
    const char *at = strstr(line, "p99 ");
    if (at) {
        sscanf(at, "p99 %lf ms, longest %lf ms", &p99, &longest);
    }
    expect(strstr(line, " MB reported in ") && !strstr(line, "back to the Mac"),
           "the run's line says MB reported (not \"back to the Mac\")");
    expect(strstr(line, "MB not moved aside (the worker's queue was full, no room to move them aside)") != NULL,
           "  and what was not moved aside, and why");
    char want[96];
    snprintf(want, sizeof(want), "this run the worker released %.0f MB, ", (queue + 1) * pg / (double)MB);
    expect(strstr(line, want) && strstr(line, " MB of it left on the Mac ("),
           "  and what the worker released and what of it is left on the Mac");
    expect(p99 >= 0 && longest >= 0 && p99 <= longest, "  its p99 is never above the longest hold");
    if (failures) {
        printf("test-reclaim: FAILED (%u)\n", failures);
        return 1;
    }
    printf("test-reclaim: all ok\n");
    return 0;
}
#endif

int main(int argc, char **argv)
{
    int wait_s = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--keeps") || !strcmp(argv[i], "--overflow")) {
#if defined(HELPER_MAIN)
            printf("test-reclaim: %s is for the patch's helper\n", argv[i]);
            return 2;
#else
            pg = (size_t)getpagesize();
            return argv[i][2] == 'k' ? keeps_test() : overflow_test();
#endif
        } else if (!strcmp(argv[i], "--hv")) {
            use_hv = true;
        } else if (!strcmp(argv[i], "--compressed") && i + 1 < argc) {
            wait_s = atoi(argv[++i]);
        } else {
            fprintf(stderr, "usage: test-reclaim [--hv] [--compressed SECONDS] | --keeps | --overflow\n");
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
