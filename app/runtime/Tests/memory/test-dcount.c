/* Test for qemu-hvf-own-view-sweep.patch (no VM): does Activity Monitor
 * count guest RAM once after a sweep, do QEMU and the guest still see the
 * same memory, and does a sweep that would not do what ADR 0066 expects turn
 * itself off instead of stopping QEMU?
 *
 * The sweep's part of the patched accel/hvf/hvf-all.c (omacvm-sweep: begin
 * ... end) and the free page reclaim's (omacvm-reclaim), taken out by
 * test-dcount.sh, run on guest RAM in the state QEMU's is in: anonymous
 * memory the hypervisor's map shares (a real hv_vm_map with --hv, else a
 * second mapping of this process, mach_vm_remap without copy: XNU counts
 * both the same way). The guest is a tiny vCPU program (--hv) or the second
 * mapping. "held" is what the Mac holds of guest RAM, counted once (mincore
 * over QEMU's view: resident + compressed); "footprint" is this process's
 * phys_footprint, Activity Monitor's Memory.
 *
 *   test-dcount [--hv]             the sweep's rows (below)
 *   test-dcount [--hv] --predicate which RAM blocks a report may replace and the sweep may remap
 *   test-dcount [--hv] CASE        a remap that does not do what ADR 0066 expects, made so by
 *                                  the sweep's own test hook (omacvm_sweep_test_*, as
 *                                  OMACVM_TEST_SWEEP_DIVERGE in QEMU):
 *     --canary    the trial's remap gives QEMU's view new memory: the sweep is off ("off (why)"),
 *                 guest RAM never remapped, the trial's memory gone, one memory both ways
 *     --diverge   the first pass's first chunk the same: mapped back, the sweep stopped, QEMU runs
 *     --chunk     the same in a later pass, chunk 2, while a thread preads and pwrites guest RAM
 *     --spare     the spare of chunk 2 differs: the sweep stops before that chunk is remapped
 *     --hole      chunk 2's remap leaves a hole and fails: mapped back around and into the hole
 *     --unmapped  and mapping back fails too: QEMU stops (abort), the only abort left
 *     --dip       chunk 2 reads private once after its remap (a reference count read low): fine
 *     --hang      the trial's remap waits past the time limit: off; the trial's memory goes later
 *
 * Rows: before the machine starts, the trial on scratch memory passes and
 * leaves nothing behind. QEMU writes 1 GB (a disk read), the guest reads it:
 * footprint about twice held (else this Mac does not count it twice: SKIP).
 * Pass 1 while a thread reads and writes a file into and out of guest RAM
 * (pread/pwrite, buffered and F_NOCACHE: QEMU's disk thread pool), with a
 * free page report between chunks in a chunk already swept and in one not
 * yet swept, their moves aside released only after the pass, and the
 * replaced ranges touched by neither side until after it. Then a clean pass
 * 2: footprint within 1 % of held, every page right as the guest sees it,
 * and after it QEMU's writes seen by the guest and the guest's by QEMU (the
 * replaced ranges too). Then: a pass is skipped while the footprint grew
 * less than 64 MB, twice in a row at most; a chunk with an entry that has no
 * object yet, or is copy-on-write, stays as it is (counted, one line), the
 * rest is remapped; a failed remap stops the sweep for the run (one line),
 * QEMU's view unchanged; the hour's and the run's qemu.log lines.
 *
 * Built three ways by test-dcount.sh and by hand: the patch's sweep (must
 * pass), -DSWEEP_MAIN (no sweep, as up to 3.2.16: must fail with "COUNTED
 * TWICE"), and -DSWEEP_OLD (3.2.17's sweep, sweep.inc, with the hook,
 * sweep-test.inc, around its calls: --diverge, --chunk, --hole and --dip
 * must fail there, the first pass's by stopping QEMU).
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
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

typedef uint64_t hwaddr;

#define KB 1024ull
#define MB (1024ull * 1024ull)
#define RAM_IPA 0x40000000ull
#define CODE_IPA 0x10000ull
#define STRIDE (4 * KB)               /* one word every 4 KiB, guest and QEMU alike */

static bool use_hv;
static uint64_t ram_size = 1024 * MB;
static uint8_t *ram;                  /* QEMU's view of guest RAM */
static uint8_t *hvmap;                /* the stand-in for the hypervisor's mapping */
static size_t pg;
static hv_vcpu_t vcpu;
static hv_vcpu_exit_t *vexit;

static void die(const char *what, long r)
{
    fprintf(stderr, "test-dcount: %s failed: 0x%lx\n", what, r);
    exit(1);
}

/* The hypervisor's side: real, or a second mapping of the same memory (test-reclaim.c's stand-in). */
static hv_return_t test_hv_vm_unmap(hv_ipa_t ipa, size_t size)
{
    if (use_hv) {
        return hv_vm_unmap(ipa, size);
    }
    void *at = hvmap + (ipa - RAM_IPA);
    return mmap(at, size, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == at ? HV_SUCCESS : HV_ERROR;
}

static kern_return_t real_remap(mach_vm_address_t *at, mach_vm_size_t size, int flags, mach_vm_address_t from,
                                boolean_t copy, vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inherit)
{
    return mach_vm_remap(mach_task_self(), at, size, 0, flags, mach_task_self(), from, copy, cur, max, inherit);
}

static hv_return_t test_hv_vm_map(void *addr, hv_ipa_t ipa, size_t size, hv_memory_flags_t flags)
{
    if (use_hv) {
        return hv_vm_map(addr, ipa, size, flags);
    }
    mach_vm_address_t at = (mach_vm_address_t)(hvmap + (ipa - RAM_IPA));
    vm_prot_t cur, max;
    kern_return_t kr = real_remap(&at, size, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, (mach_vm_address_t)addr,
                                  FALSE, &cur, &max, VM_INHERIT_NONE);
    return kr == KERN_SUCCESS && at == (mach_vm_address_t)(hvmap + (ipa - RAM_IPA)) ? HV_SUCCESS : HV_ERROR;
}

#define hv_vm_unmap test_hv_vm_unmap
#define hv_vm_map test_hv_vm_map
#define assert_hvf_ok(expr) do { \
        hv_return_t r_ = (expr); \
        if (r_ != HV_SUCCESS) { fprintf(stderr, "test-dcount: %s = 0x%x\n", #expr, r_); abort(); } \
    } while (0)
#define trace_hvf_vm_unmap(...) ((void)0)
#define trace_hvf_vm_map(...) ((void)0)

/* qemu.log: every line, and the last info line, for the checks. */
static unsigned warnings, errors;
static char last_info[1024], last_warn[1024];
#define info_report(...) (snprintf(last_info, sizeof(last_info), __VA_ARGS__), \
                          fprintf(stderr, "  qemu.log: %s\n", last_info))
#define warn_report(...) (warnings++, snprintf(last_warn, sizeof(last_warn), __VA_ARGS__), \
                          fprintf(stderr, "  qemu.log: %s\n", last_warn))
#define error_report(...) (errors++, fprintf(stderr, "  qemu.log: "), fprintf(stderr, __VA_ARGS__), \
                           fputc('\n', stderr))

/* What the patch's parts need from QEMU, for this test. */
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
static void qemu_thread_create(QemuThread *t, const char *name, void *(*fn)(void *), void *arg, int mode)
{
    pthread_create(t, NULL, fn, arg);
    pthread_detach(*t);
}
static bool bql_locked(void)
{
    return true;
}
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

#define g_new0(type, n) ((type *)calloc((n), sizeof(type)))
#define g_usleep(us) usleep((useconds_t)(us))
#define qemu_mutex_destroy(m) pthread_mutex_destroy(m)
#define qemu_cond_destroy(c) pthread_cond_destroy(c)
static bool qemu_cond_timedwait(QemuCond *c, QemuMutex *m, int ms)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += ms / 1000;
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec++;
        ts.tv_nsec -= 1000000000L;
    }
    return pthread_cond_timedwait(c, m, &ts) == 0;
}
/* QEMU's allocation of RAM blocks (qemu_ram_mmap: the block, then a guard page). */
static void *qemu_anon_ram_alloc(size_t size, uint64_t *align, bool shared, bool noreserve)
{
    uint8_t *p = mmap(NULL, size + 16 * KB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        return NULL;
    }
    mprotect(p + size, 16 * KB, PROT_NONE);
    *align = 16 * KB;
    return p;
}
static void qemu_anon_ram_free(void *p, size_t size)
{
    munmap(p, size + 16 * KB);
}

/* QEMU's memory types, as far as omacvm_ram_private() looks at them. */
#define RAM_PREALLOC (1 << 0)
#define RAM_SHARED (1 << 1)
typedef struct RAMBlock {
    int fd;
    uint32_t flags;
} RAMBlock;
typedef struct MemoryRegion {
    bool ram, ram_device, readonly, rom_device;
    uint8_t dirty_log_mask;
    RAMBlock *ram_block;
} MemoryRegion;
static bool memory_region_is_ram(MemoryRegion *mr)
{
    return mr->ram;
}
static bool memory_region_is_ram_device(MemoryRegion *mr)
{
    return mr->ram_device;
}
static uint8_t memory_region_get_dirty_log_mask(MemoryRegion *mr)
{
    return mr->dirty_log_mask;
}

/* The sweep's remaps over QEMU's view (VM_FLAGS_OVERWRITE): counted per chunk of guest RAM, made to fail on
 * demand (no room), and never across a hole (that raises EXC_GUARD: counted and refused here instead). */
enum { REMAP_REAL, REMAP_FAIL };
static int remap_mode = REMAP_REAL;
static unsigned long sweep_remaps, ram_remaps, gap_remaps, chunk_remaps[64];
static bool has_gap(mach_vm_address_t at, mach_vm_size_t size)
{
    for (mach_vm_address_t a = at; a < at + size;) {
        mach_vm_address_t start = a;
        mach_vm_size_t len = 0;
        natural_t depth = 0;
        vm_region_submap_short_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
        if (mach_vm_region_recurse(mach_task_self(), &start, &len, &depth, (vm_region_recurse_info_t)&info,
                                   &count) != KERN_SUCCESS || start > a) {
            return true;
        }
        a = start + len;
    }
    return false;
}
static kern_return_t test_mach_vm_remap(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size,
                                        mach_vm_offset_t mask, int flags, vm_map_t src, mach_vm_address_t src_address,
                                        boolean_t copy, vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inherit)
{
    if (flags & VM_FLAGS_OVERWRITE) {
        sweep_remaps++;
        if (*address >= (mach_vm_address_t)ram && *address < (mach_vm_address_t)ram + ram_size) {
            ram_remaps++;
            chunk_remaps[(*address - (mach_vm_address_t)ram) >> 27]++;
        }
        if (has_gap(*address, size)) {
            gap_remaps++;
            return KERN_INVALID_ADDRESS;
        }
        if (remap_mode == REMAP_FAIL) {
            return KERN_NO_SPACE;
        }
    }
    return mach_vm_remap(target, address, size, mask, flags, src, src_address, copy, cur, max, inherit);
}
#define mach_vm_remap test_mach_vm_remap
#include "reclaim.inc"
#if defined(SWEEP_MAIN)
/* main up to 3.2.16: no sweep. */
static const char *sweep_name = "main (no sweep)";
typedef struct OmacvmSweepStats {
    uint64_t passes, idle, chunks, less, left, left_bytes;
    int64_t longest_ns;
} OmacvmSweepStats;
typedef struct OmacvmSweep {
    uint64_t at, size;
    bool stopped;
    OmacvmSweepStats run;
} OmacvmSweep;
static void omacvm_sweep_setup(OmacvmSweep *s, void *host, uint64_t size, int64_t period_s, bool check, int64_t now)
{
    memset(s, 0, sizeof(*s));
    s->size = size;
    s->at = size;
}
static int64_t omacvm_sweep_step(OmacvmSweep *s, int64_t now, bool usable)
{
    s->run.passes++;    /* a "pass" that does nothing */
    return 300 * NANOSECONDS_PER_SECOND;
}
#elif defined(SWEEP_OLD)
/* 3.2.17's sweep (no trial, no spare), with this sweep's test hook around its calls. */
static const char *sweep_name = "3.2.17's sweep";
#define OMACVM_SWEEP_CHUNK (128ull << 20)
#include "sweep-test.inc"
#undef mach_vm_remap
#define mach_vm_remap omacvm_sweep_test_remap
#define mach_vm_region_recurse omacvm_sweep_test_region
#include "sweep.inc"
#undef mach_vm_region_recurse
#else
#include "sweep.inc"
static const char *sweep_name = "the patch's sweep";
#endif
#undef mach_vm_remap
#define TRIAL_IPA 0x800000000ull       /* the trial's scratch memory for the hypervisor (--hv): 32 GB */

/* ---- the guest: a vCPU program (--hv) or the second mapping ----
 * x0 = start IPA, x1 = end, x2 = stride, x5 = op: 0 write x0 + x6, 1 read,
 * 2 verify == x0 + x6, 3 verify == 0; then hvc #0. A bad word: hvc #1, x0 = its IPA. */
static const uint32_t prog[] = {
    0xF10000BF, /*  0 cmp x5, #0            */
    0x54000140, /*  4 b.eq write (44)       */
    0xF10004BF, /*  8 cmp x5, #1            */
    0x54000160, /* 12 b.eq read (56)        */
    0xF9400003, /* 16 ldr x3, [x0]          */
    0x8B060004, /* 20 add x4, x0, x6        */
    0xF1000CBF, /* 24 cmp x5, #3            */
    0x9A8403E4, /* 28 csel x4, xzr, x4, eq  */
    0xEB04007F, /* 32 cmp x3, x4            */
    0x54000141, /* 36 b.ne bad (76)         */
    0x14000005, /* 40 b next (60)           */
    0x8B060004, /* 44 write: add x4, x0, x6 */
    0xF9000004, /* 48 str x4, [x0]          */
    0x14000002, /* 52 b next (60)           */
    0xF9400003, /* 56 read: ldr x3, [x0]    */
    0x8B020000, /* 60 next: add x0, x0, x2  */
    0xEB01001F, /* 64 cmp x0, x1            */
    0x54FFFDE3, /* 68 b.lo top (0)          */
    0xD4000002, /* 72 hvc #0                */
    0xD4000022, /* 76 bad: hvc #1           */
};
enum { G_WRITE, G_READ, G_VERIFY, G_ZERO };

static uint64_t value(uint64_t off, uint64_t salt)
{
    return RAM_IPA + off + salt;
}

/* The guest does op over [from, to). false: a word was not as it should be. */
static bool guest(int op, uint64_t from, uint64_t to, uint64_t salt)
{
    if (!use_hv) {
        for (uint64_t o = from; o < to; o += STRIDE) {
            volatile uint64_t *p = (volatile uint64_t *)(hvmap + o);
            if (op == G_WRITE) {
                *p = value(o, salt);
            } else if (op == G_READ) {
                (void)*p;
            } else if (*p != (op == G_ZERO ? 0 : value(o, salt))) {
                fprintf(stderr, "  guest: +0x%llx reads 0x%llx\n", (unsigned long long)o, (unsigned long long)*p);
                return false;
            }
        }
        return true;
    }
    hv_vcpu_set_reg(vcpu, HV_REG_PC, CODE_IPA);
    hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3c5);
    hv_vcpu_set_reg(vcpu, HV_REG_X0, RAM_IPA + from);
    hv_vcpu_set_reg(vcpu, HV_REG_X1, RAM_IPA + to);
    hv_vcpu_set_reg(vcpu, HV_REG_X2, STRIDE);
    hv_vcpu_set_reg(vcpu, HV_REG_X5, (uint64_t)op);
    hv_vcpu_set_reg(vcpu, HV_REG_X6, salt);
    for (;;) {
        hv_return_t r = hv_vcpu_run(vcpu);
        if (r != HV_SUCCESS) {
            die("hv_vcpu_run", r);
        }
        if (vexit->reason == HV_EXIT_REASON_EXCEPTION) {
            uint64_t ec = (vexit->exception.syndrome >> 26) & 0x3f, x0;
            if (ec == 0x16) {
                if ((vexit->exception.syndrome & 0xffff) == 0) {
                    return true;
                }
                hv_vcpu_get_reg(vcpu, HV_REG_X0, &x0);
                fprintf(stderr, "  guest: IPA 0x%llx is not as it should be\n", (unsigned long long)x0);
                return false;
            }
            die("guest exception", (long)vexit->exception.syndrome);
        }
        if (vexit->reason == HV_EXIT_REASON_CANCELED || vexit->reason == HV_EXIT_REASON_VTIMER_ACTIVATED) {
            continue;
        }
        die("guest exit", vexit->reason);
    }
}

/* QEMU's side over [from, to): write, or verify (salt; zero). */
static void qemu_write(uint64_t from, uint64_t to, uint64_t salt)
{
    for (uint64_t o = from; o < to; o += STRIDE) {
        *(volatile uint64_t *)(ram + o) = value(o, salt);
    }
}

/* QEMU reads [from, to) (a disk write out of guest RAM): its mapping touches every page again. */
static void qemu_read(uint64_t from, uint64_t to)
{
    for (uint64_t o = from; o < to; o += STRIDE) {
        (void)*(volatile uint64_t *)(ram + o);
    }
}

static bool qemu_verify(uint64_t from, uint64_t to, uint64_t salt, bool zero)
{
    for (uint64_t o = from; o < to; o += STRIDE) {
        uint64_t v = *(volatile uint64_t *)(ram + o);
        if (v != (zero ? 0 : value(o, salt))) {
            fprintf(stderr, "  QEMU: +0x%llx reads 0x%llx\n", (unsigned long long)o, (unsigned long long)v);
            return false;
        }
    }
    return true;
}

static uint64_t footprint(void)
{
    task_vm_info_data_t ti;
    mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&ti, &c);
    return ti.phys_footprint;
}

/* What the Mac holds of guest RAM, counted once: mincore over QEMU's view. */
static uint64_t held(void)
{
    size_t n = ram_size / pg, h = 0;
    char *v = malloc(n);
    if (mincore(ram, ram_size, v) == 0) {
        for (size_t i = 0; i < n; i++) {
            h += (v[i] & (MINCORE_INCORE | MINCORE_PAGED_OUT)) != 0;
        }
    }
    free(v);
    return h * pg;
}

static int fails;
static void row(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void row(bool ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("  %s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
    fails += !ok;
}

/* ---- the disk thread pool: pread/pwrite into and out of guest RAM ---- */
#define IO_OFF (640 * MB)
#define IO_LEN (64 * MB)
#define IO_SALT 7
static char io_in[1024], io_out[1024];
static atomic_bool io_stop;
static atomic_ulong io_rounds, io_bad;
static uint8_t *io_want, *io_back;
static pthread_t io;

static void *io_thread(void *arg)
{
    int in = open(io_in, O_RDONLY), out = open(io_out, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (in < 0 || out < 0) {
        io_bad++;
        return NULL;
    }
    for (unsigned long round = 0; !atomic_load(&io_stop); round++) {
        bool direct = round & 1;            /* buffered (QEMU's cache=writeback), then F_NOCACHE */
        fcntl(in, F_NOCACHE, direct);
        fcntl(out, F_NOCACHE, direct);
        if (pread(in, ram + IO_OFF, IO_LEN, 0) != (ssize_t)IO_LEN ||
            memcmp(ram + IO_OFF, io_want, IO_LEN) ||
            pwrite(out, ram + IO_OFF, IO_LEN, 0) != (ssize_t)IO_LEN ||
            pread(out, io_back, IO_LEN, 0) != (ssize_t)IO_LEN ||
            memcmp(io_back, io_want, IO_LEN)) {
            io_bad++;
        }
        io_rounds++;
    }
    close(in);
    close(out);
    return NULL;
}

/* The thread starts and has done two rounds. */
static void io_start(void)
{
    /* mmap, not malloc: freed, they leave the footprint at once (malloc may keep big blocks) */
    io_want = mmap(NULL, IO_LEN, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    io_back = mmap(NULL, IO_LEN, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    for (uint64_t o = 0; o < IO_LEN; o += 8) {
        *(uint64_t *)(io_want + o) = (o % STRIDE) ? 0x5a5a5a5a5a5a5a5aull : value(IO_OFF + o, IO_SALT);
    }
    int fd = open(io_in, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0 || write(fd, io_want, IO_LEN) != (ssize_t)IO_LEN) {
        die("writing the I/O file", errno);
    }
    close(fd);
    atomic_store(&io_stop, false);
    io_rounds = 0;
    pthread_create(&io, NULL, io_thread, NULL);
    while (io_rounds < 2) {
        usleep(1000);
    }
}

/* Stops it; the rounds it did. */
static unsigned long io_end(void)
{
    unsigned long rounds = io_rounds;
    atomic_store(&io_stop, true);
    pthread_join(io, NULL);
    munmap(io_want, IO_LEN);
    munmap(io_back, IO_LEN);
    return rounds;
}

/* Steps of the sweep until one more pass is done (or it stops); a callback after each chunk. Fake clock. */
static int64_t clock_now;
static void run_pass(OmacvmSweep *s, void (*after_chunk)(unsigned chunk))
{
    uint64_t passes = s->run.passes;
    unsigned chunk = 0;
    for (int i = 0; i < 4096 && s->run.passes == passes; i++) {
        int64_t next = omacvm_sweep_step(s, clock_now, true);
        if (next < 0) {
            return;
        }
        if (s->at < s->size || s->run.passes != passes) {
            if (after_chunk) {
                after_chunk(chunk);
            }
            chunk++;
        }
        clock_now += next;
        if (next < NANOSECONDS_PER_SECOND) {
            usleep((useconds_t)(next / 1000));   /* the gap between chunks is real: other threads run */
        }
    }
}

/* Two free page reports in pass 1: one in a chunk already swept, one in a chunk not swept yet. */
#define REP1 (130 * MB)       /* chunk 1 */
#define REP2 (390 * MB)       /* chunk 3 */
#define REP_LEN (4 * MB)
static mach_vm_address_t aside1, aside2;
static void report_between(unsigned chunk)
{
    if (chunk != 2) {
        return;
    }
    hv_memory_flags_t f = HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC;
    aside1 = omacvm_reclaim_backing(RAM_IPA + REP1, ram + REP1, REP_LEN, f, true);
    aside2 = omacvm_reclaim_backing(RAM_IPA + REP2, ram + REP2, REP_LEN, f, true);
    printf("  (free page reports at +130 MB and +390 MB after chunk 2: moved aside %s, released after the pass)\n",
           aside1 && aside2 ? "both" : "NOT");
}

static bool verify_all(uint64_t salt)
{
    /* every page as the guest sees it: the replaced ranges read 0, the I/O range the file */
    struct { uint64_t from, to, salt; int op; } seg[] = {
        { 0, REP1, salt, G_VERIFY }, { REP1, REP1 + REP_LEN, 0, G_ZERO },
        { REP1 + REP_LEN, REP2, salt, G_VERIFY }, { REP2, REP2 + REP_LEN, 0, G_ZERO },
        { REP2 + REP_LEN, IO_OFF, salt, G_VERIFY }, { IO_OFF, IO_OFF + IO_LEN, IO_SALT, G_VERIFY },
        { IO_OFF + IO_LEN, ram_size, salt, G_VERIFY },
    };
    for (size_t i = 0; i < sizeof(seg) / sizeof(seg[0]); i++) {
        if (!guest(seg[i].op, seg[i].from, seg[i].to, seg[i].salt)) {
            return false;
        }
    }
    return true;
}

/* One memory both ways: QEMU writes the first half, the guest sees it; the guest writes the second, QEMU sees it. */
static bool both_ways(uint64_t salt)
{
    qemu_write(0, ram_size / 2, salt);
    if (!guest(G_VERIFY, 0, ram_size / 2, salt)) {
        return false;
    }
    guest(G_WRITE, ram_size / 2, ram_size, salt + 1);
    return qemu_verify(ram_size / 2, ram_size, salt + 1, false);
}

static double ratio(uint64_t fp, uint64_t base, uint64_t h)
{
    return h ? (double)(fp > base ? fp - base : 0) / (double)h : 0;
}

/* Is nothing mapped in [at, at + len)? */
static bool unmapped(mach_vm_address_t at, mach_vm_size_t len)
{
    mach_vm_address_t start = at;
    mach_vm_size_t size = 0;
    natural_t depth = 0;
    vm_region_submap_short_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;
    return mach_vm_region_recurse(mach_task_self(), &start, &size, &depth, (vm_region_recurse_info_t)&info,
                                  &count) != KERN_SUCCESS || start >= at + len;
}

#if !defined(SWEEP_MAIN) && !defined(SWEEP_OLD)
/* Before the machine starts: the trial. ok: it passed and left nothing behind (its memory, the hypervisor's
 * map of it, its footprint). */
static bool trial(OmacvmSweep *s, int64_t limit_ms, char *why, size_t whylen, bool *gone)
{
    uint64_t before = footprint();
    unsigned long remaps = ram_remaps;
    bool ok = omacvm_sweep_canary(s, use_hv ? TRIAL_IPA : 0, limit_ms, why, whylen);
    for (int i = 0; i < 5000 && __atomic_load_n(&omacvm_sweep_trials, __ATOMIC_SEQ_CST); i++) {
        usleep(1000);                   /* a late trial (past the time limit) ends on its own */
    }
    *gone = !__atomic_load_n(&omacvm_sweep_trials, __ATOMIC_SEQ_CST) && ram_remaps == remaps &&
            footprint() < before + 4 * MB &&
            (!omacvm_sweep_test.at || unmapped(omacvm_sweep_test.at, OMACVM_SWEEP_TRIAL));
    if (use_hv && *gone) {
        /* the hypervisor's map of the trial's memory is gone: its IPA maps again */
        void *pg_ = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        *gone = hv_vm_map(pg_, TRIAL_IPA, pg, HV_MEMORY_READ) == HV_SUCCESS &&
                hv_vm_unmap(TRIAL_IPA, pg) == HV_SUCCESS;
        munmap(pg_, pg);
    }
    return ok;
}
#endif

static int rows(void)
{
    OmacvmSweep s;
    uint64_t base, fp, h;

    printf("test-dcount: %s, guest RAM %llu MB, %s\n", sweep_name, (unsigned long long)(ram_size / MB),
           use_hv ? "a real hv_vm_map and vCPU" : "a second mapping for the hypervisor's");
    omacvm_sweep_setup(&s, ram, ram_size, 300, true, clock_now);
#if !defined(SWEEP_MAIN) && !defined(SWEEP_OLD)
    /* The trial, before the machine starts. */
    char tw[512];
    bool gone;
    bool passed = trial(&s, OMACVM_SWEEP_TRIAL_MS, tw, sizeof(tw), &gone);
    row(passed && s.mode == SM_TRUESHARED, "the trial on scratch memory passes before the machine starts (%s, "
        "share mode %d, %.1f ms)%s%s", s.trial_hv ? "mapped by the hypervisor" : "a second mapping", s.mode,
        s.trial_ns / 1e6, passed ? "" : ": ", passed ? "" : tw);
    row(gone, "  and leaves nothing behind (its memory, %sthe footprint as before)",
        use_hv ? "the hypervisor's map of it, " : "");
    if (!passed) {
        return 1;
    }
#endif
    base = footprint();
    /* A disk read: QEMU writes every page, then the guest reads it. */
    qemu_write(0, ram_size, 1);
    if (!guest(G_VERIFY, 0, ram_size, 1)) {
        row(false, "the guest reads what QEMU wrote");
        return 1;
    }
    fp = footprint();
    h = held();
    printf("  QEMU wrote %llu MB, the guest read it: footprint %llu MB (%llu MB beside guest RAM), held %llu MB\n",
           (unsigned long long)(ram_size / MB), (unsigned long long)((fp - base) / MB), (unsigned long long)(base / MB),
           (unsigned long long)(h / MB));
    if (ratio(fp, base, h) < 1.9) {
        printf("test-dcount: SKIP: this Mac counts the pages once already (footprint %.2fx held)\n", ratio(fp, base, h));
        return 2;
    }
    row(true, "counted twice before a sweep: footprint %.2fx held", ratio(fp, base, h));

    /* Pass 1, under load: the disk thread pool's reads and writes, two free page reports between chunks. */
    io_start();
    run_pass(&s, report_between);
    unsigned long rounds = io_end();
    if (aside1) {
        omacvm_reclaim_release(aside1, REP_LEN, NULL);
    }
    if (aside2) {
        omacvm_reclaim_release(aside2, REP_LEN, NULL);
    }
    row(s.run.passes == 1 && !s.stopped, "pass 1 done (%llu chunks remapped)", (unsigned long long)s.run.chunks);
    row(io_bad == 0 && rounds >= 3, "pread/pwrite into and out of guest RAM during pass 1: %lu rounds, %lu bad",
        rounds, (unsigned long)io_bad);
    row(verify_all(1), "after pass 1 the guest sees every page right (replaced ranges 0, the file's data)");

    /* Pass 2, clean: QEMU reads 256 MB first (a disk write), so the footprint grew and the pass runs. */
    row(qemu_verify(0, REP1, 1, false) && qemu_verify(REP1 + REP_LEN, 256 * MB, 1, false),
        "QEMU reads 256 MB (a disk write): what the guest has");
    run_pass(&s, NULL);
    fp = footprint();
    h = held();
    double r = ratio(fp, base, h);
    row(s.run.passes == 2 && r <= 1.01 && r >= 0.99, "after pass 2: footprint %llu MB beside the rest for %llu MB held "
        "(%.3fx)%s", (unsigned long long)((fp - base) / MB), (unsigned long long)(h / MB), r,
        r > 1.01 ? ": COUNTED TWICE" : "");
#if !defined(SWEEP_MAIN)
    printf("  sweep: %llu chunks, Activity Monitor %llu MB less, longest chunk %.2f ms\n",
           (unsigned long long)s.run.chunks, (unsigned long long)(s.run.less / MB), s.run.longest_ns / 1e6);
    row(s.run.longest_ns < 200 * 1000000LL, "no chunk held the main lock 200 ms or more (longest %.2f ms)",
        s.run.longest_ns / 1e6);
#endif
    row(verify_all(1), "after pass 2 the guest sees every page right");

    /* One memory both ways after the sweep, the replaced ranges (never touched until now) too. */
    qemu_write(0, ram_size / 2, 3);
    row(guest(G_VERIFY, 0, ram_size / 2, 3), "QEMU writes 512 MB after the sweep: the guest sees it");
    guest(G_WRITE, ram_size / 2, ram_size, 4);
    row(qemu_verify(ram_size / 2, ram_size, 4, false), "the guest writes 512 MB: QEMU sees it");
    qemu_write(REP2, REP2 + REP_LEN, 5);
    row(guest(G_VERIFY, REP2, REP2 + REP_LEN, 5), "a replaced range swept untouched: QEMU's write seen by the guest");
    guest(G_WRITE, REP1, REP1 + REP_LEN, 6);
    row(qemu_verify(REP1, REP1 + REP_LEN, 6, false), "a replaced range swept untouched: the guest's write seen by QEMU");
#if defined(SWEEP_MAIN) || defined(SWEEP_OLD)
    return fails ? 1 : 0;
#else
    /* Idle: a pass is skipped while the footprint grew less than 64 MB, twice in a row at most (free page reports
     * can shrink the footprint while QEMU's touches grow it): the third look runs one. */
    run_pass(&s, NULL);   /* the writes above grew it: this pass runs */
    uint64_t passes = s.run.passes, chunks = s.run.chunks, idle = s.run.idle;
    int64_t next = omacvm_sweep_step(&s, clock_now, true), next2 = omacvm_sweep_step(&s, clock_now, true);
    row(next == s.period_ns && next2 == s.period_ns && s.run.idle == idle + 2 && s.run.chunks == chunks &&
        s.run.passes == passes, "a pass is skipped while the footprint grew less than 64 MB (next look in %lld s), twice",
        (long long)(next / NANOSECONDS_PER_SECOND));
    next = omacvm_sweep_step(&s, clock_now, true);
    row(next == OMACVM_SWEEP_GAP_NS && s.run.chunks == chunks + 1 && s.run.idle == idle + 2,
        "the third look runs a pass all the same");
    run_pass(&s, NULL);
    clock_now += s.period_ns;

    /* Chunks that must stay as they are: no object yet (chunk 7), copy-on-write (chunk 6). */
    uint64_t empty = 7 * 128 * MB + 8 * MB, cow = 6 * 128 * MB + 8 * MB;
    assert_hvf_ok(hv_vm_unmap(RAM_IPA + empty, REP_LEN));
    mmap(ram + empty, REP_LEN, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    assert_hvf_ok(hv_vm_unmap(RAM_IPA + cow, REP_LEN));
    uint8_t *src = mmap(NULL, REP_LEN, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    memset(src, 0x77, REP_LEN);
    mach_vm_address_t at = (mach_vm_address_t)(ram + cow);
    vm_prot_t cur, max;
    if (real_remap(&at, REP_LEN, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, (mach_vm_address_t)src, TRUE, &cur, &max,
                   VM_INHERIT_COPY) != KERN_SUCCESS) {
        die("a copy-on-write entry", 0);
    }
    qemu_read(0, 256 * MB);                             /* the footprint grows: the next pass runs */
    unsigned w = warnings;
    chunks = s.run.chunks;
    run_pass(&s, NULL);
    row(s.run.left == 2 && s.run.chunks == chunks + 6 && warnings == w + 1 && strstr(last_warn, "stays as it is"),
        "a chunk with an entry without an object, and one copy-on-write, stay as they are: %llu left, %llu remapped, "
        "one line", (unsigned long long)s.run.left, (unsigned long long)(s.run.chunks - chunks));
    row(*(volatile uint8_t *)(ram + cow) == 0x77 && *(volatile uint64_t *)(ram + empty) == 0,
        "QEMU's view of both is as it was");
    /* put them back as a report leaves a range: new memory, mapped for the guest */
    mmap(ram + cow, REP_LEN, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    assert_hvf_ok(hv_vm_map(ram + cow, RAM_IPA + cow, REP_LEN, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));
    assert_hvf_ok(hv_vm_map(ram + empty, RAM_IPA + empty, REP_LEN, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC));

    /* A failed remap stops the sweep for the run; QEMU's view stays. */
    qemu_read(0, 256 * MB);
    remap_mode = REMAP_FAIL;
    w = warnings;
    run_pass(&s, NULL);
    remap_mode = REMAP_REAL;
    unsigned long before = sweep_remaps;
    next = omacvm_sweep_step(&s, clock_now + s.period_ns, true);
    row(s.stopped && next == -1 && sweep_remaps == before && warnings == w + 1 &&
        strstr(last_warn, "stopped for this run: a remap at +0 MB failed"),
        "a failed remap stops the sweep for the run, one line");
    row(guest(G_VERIFY, 0, REP1, 3) && qemu_verify(ram_size / 2, ram_size / 2 + 64 * MB, 4, false),
        "after it QEMU and the guest still see the same memory");
    row(gap_remaps == 0, "no remap over a hole in QEMU's view (EXC_GUARD) all along");

    /* qemu.log: the hour's line from the sweep's own timer, the run's line at exit. */
    char why[1024];
    omacvm_sweep_log(&s, "this run", &s.run);
    snprintf(why, sizeof(why), "%s", last_info);
    row(strstr(why, "OmacVM: own-view sweep this run: ") && strstr(why, " passes over 1024 MB of guest RAM, ") &&
        strstr(why, " skipped (QEMU's footprint grew less than 64 MB), ") && strstr(why, "; Activity Monitor ") &&
        strstr(why, "MB less; main lock per chunk p99 ") && strstr(why, "2 chunks (256 MB) left as they were") &&
        strstr(why, "; stopped: a remap at +0 MB failed") && !strstr(why, "mapped back"), "the run's qemu.log line");
    OmacvmSweep t;
    omacvm_sweep_setup(&t, ram, ram_size, 300, false, 0);
    t.footprint_after = footprint();
    omacvm_sweep_step(&t, 3599 * NANOSECONDS_PER_SECOND, true);
    last_info[0] = 0;
    omacvm_sweep_step(&t, 3600 * NANOSECONDS_PER_SECOND, true);
    row(strstr(last_info, "OmacVM: own-view sweep in the last hour: 0 passes over 1024 MB of guest RAM, 1 skipped") != NULL,
        "an hour after the start: the hour's line, from the sweep's own timer");
    row(omacvm_sweep_period(NULL) == 300 && omacvm_sweep_period("0") == 0 && omacvm_sweep_period("60") == 60 &&
        omacvm_sweep_period("2") == 10 && omacvm_sweep_period("x") == 300 && omacvm_sweep_period("-5") == 300,
        "OMACVM_DCOUNT_SWEEP: unset 300 s, 0 off, seconds for tests (10 at least), else 300 s");
    return fails ? 1 : 0;
#endif
}

#if !defined(SWEEP_MAIN)
/*
 * A remap that does not do what ADR 0066 expects (the sweep's test hook). QEMU's side: the trial (unless
 * --canary or --hang make it fail, or 3.2.17's sweep has none), then passes; the chunk the hook acts on is
 * chunk 2 (from 256 MB), or chunk 0 for --diverge. Exit 0: the sweep did what it must; 1: not.
 */
static int divergence(const char *mode)
{
    OmacvmSweep s;
    uint64_t chunk = !strcmp(mode, "--diverge") ? 0 : 2 * OMACVM_SWEEP_CHUNK;
    char why[512] = "";
    (void)why;
    bool later = !strcmp(mode, "--chunk"), stopping = true;
    int what = !strcmp(mode, "--canary") ? OMACVM_SWEEP_TEST_CANARY :
               !strcmp(mode, "--diverge") || later ? OMACVM_SWEEP_TEST_CHUNK :
               !strcmp(mode, "--spare") ? OMACVM_SWEEP_TEST_SPARE : !strcmp(mode, "--hole") ? OMACVM_SWEEP_TEST_HOLE :
               !strcmp(mode, "--unmapped") ? OMACVM_SWEEP_TEST_UNMAPPED : !strcmp(mode, "--dip") ? OMACVM_SWEEP_TEST_DIP :
               !strcmp(mode, "--hang") ? OMACVM_SWEEP_TEST_HANG : -1;

    if (what < 0) {
        fprintf(stderr, "test-dcount: unknown case %s\n", mode);
        return 2;
    }
    printf("test-dcount %s: %s, guest RAM %llu MB, %s\n", mode, sweep_name, (unsigned long long)(ram_size / MB),
           use_hv ? "a real hv_vm_map and vCPU" : "a second mapping for the hypervisor's");
    qemu_write(0, ram_size, 1);
    if (!guest(G_VERIFY, 0, ram_size, 1)) {
        row(false, "the guest reads what QEMU wrote");
        return 1;
    }
    omacvm_sweep_setup(&s, ram, ram_size, 300, false, 0);
    omacvm_sweep_test.what = what;
#if !defined(SWEEP_OLD)
    bool gone;
    if (what == OMACVM_SWEEP_TEST_CANARY || what == OMACVM_SWEEP_TEST_HANG) {
        omacvm_sweep_test.hang_ms = 700;
        bool on = trial(&s, what == OMACVM_SWEEP_TEST_HANG ? 200 : OMACVM_SWEEP_TRIAL_MS, why, sizeof(why), &gone);
        printf("  qemu.log: OmacVM: own-view sweep: %s%s%s\n", on ? "on" : "off (", on ? "" : why, on ? "" : ")");
        bool said = what == OMACVM_SWEEP_TEST_HANG ?
                    strstr(why, "a trial remap on scratch memory took longer than 200 ms") != NULL :
                    strstr(why, "a trial remap on scratch memory: ") && strstr(why, "; mapped back");
        row(!on && said && s.mode == -1,
            "the sweep is off for the run, with why (the start line's \"off (...)\")");
        row(gone, "the trial left nothing behind (its memory, %sthe footprint as before)%s",
            use_hv ? "the hypervisor's map of it, " : "", what == OMACVM_SWEEP_TEST_HANG ? ", once it ended" : "");
        row(ram_remaps == 0, "no remap of guest RAM (QEMU starts no timer)");
        row(both_ways(3), "QEMU and the guest see the same memory both ways");
        return fails ? 1 : 0;
    }
    if (!trial(&s, OMACVM_SWEEP_TRIAL_MS, why, sizeof(why), &gone)) {
        row(false, "the trial passes: %s", why);
        return 1;
    }
#endif
    if (later) {
        run_pass(&s, NULL);             /* pass 1 as it should be */
        qemu_read(0, 256 * MB);         /* the footprint grows: pass 2 runs */
        io_start();
    }
    omacvm_sweep_test.at = (mach_vm_address_t)ram + chunk;
    unsigned w = warnings;
    run_pass(&s, NULL);
    unsigned long rounds = later ? io_end() : 0;
    unsigned long at_chunk = chunk_remaps[chunk >> 27];
    switch (what) {
    case OMACVM_SWEEP_TEST_CHUNK:
    case OMACVM_SWEEP_TEST_HOLE:
#if !defined(SWEEP_OLD)
        row(s.run.mapped_back == 1, "the chunk is mapped back (%llu)", (unsigned long long)s.run.mapped_back);
#endif
        row(s.stopped && warnings == w + 1 && strstr(last_warn, "stopped for this run: mapped back after ") &&
            strstr(last_warn, " us: the remap at +") && strstr(last_warn, "may have gone wrong"),
            "the sweep stops for the run, one line: mapped back after so many us");
        if (what == OMACVM_SWEEP_TEST_HOLE) {
            row(gap_remaps == 0, "mapped back around the hole and into it, never over it (EXC_GUARD)");
        }
        break;
    case OMACVM_SWEEP_TEST_SPARE:
        row(s.stopped && strstr(last_warn, "stopped for this run: no spare mapping of the chunk at +256 MB"),
            "the sweep stops for the run: no spare to map back from");
        row(at_chunk == 0 && s.run.chunks == 2, "before that chunk is remapped (%lu remaps of it, %llu chunks before)",
            at_chunk, (unsigned long long)s.run.chunks);
        break;
    case OMACVM_SWEEP_TEST_DIP:
        stopping = false;
        row(!s.stopped && s.run.passes == 1 && s.run.chunks == ram_size / OMACVM_SWEEP_CHUNK && s.run.left == 0 &&
            warnings == w, "a chunk read private once after its remap: the pass goes on (%llu chunks), no line",
            (unsigned long long)s.run.chunks);
        break;
    case OMACVM_SWEEP_TEST_UNMAPPED:
        printf("test-dcount %s: QEMU ran on (%s)\n", mode, s.stopped ? s.why : "the sweep too");
        return 1;
    }
    if (later) {
        row(io_bad == 0 && rounds >= 2, "pread/pwrite into and out of guest RAM during that pass: %lu rounds, %lu bad",
            rounds, (unsigned long)io_bad);
    }
    /* every page as the guest sees it: what QEMU wrote, the I/O range the file */
    row(guest(G_VERIFY, 0, later ? IO_OFF : ram_size, 1) &&
        (!later || (guest(G_VERIFY, IO_OFF, IO_OFF + IO_LEN, IO_SALT) && guest(G_VERIFY, IO_OFF + IO_LEN, ram_size, 1))),
        "the guest's memory is as it was");
    row(both_ways(3), "QEMU and the guest see the same memory both ways (the chunk's page 1 MB in too)");
    if (stopping) {
        row(omacvm_sweep_step(&s, clock_now + s.period_ns, true) == -1, "no further pass");
    }
    return fails ? 1 : 0;
}
#endif

#if !defined(SWEEP_MAIN) && !defined(SWEEP_OLD)
/* --predicate: which blocks a free page report may replace and the sweep may remap. */
static int predicate(void)
{
    RAMBlock anon = { -1, 0 }, ptr = { -1, RAM_PREALLOC }, shared = { -1, RAM_SHARED }, file = { 5, 0 };
    struct { const char *what; MemoryRegion mr; bool want; } rows_[] = {
        { "main RAM (QEMU's private anonymous memory)", { .ram = true, .ram_block = &anon }, true },
        { "the Venus host memory window's blobs (memory_region_init_ram_ptr: RAM_PREALLOC)",
          { .ram = true, .ram_block = &ptr }, false },
        { "pflash (a ROM device)", { .ram = true, .rom_device = true, .ram_block = &anon }, false },
        { "ROM (read-only RAM)", { .ram = true, .readonly = true, .ram_block = &anon }, false },
        { "shared memory (RAM_SHARED)", { .ram = true, .ram_block = &shared }, false },
        { "a file-backed block", { .ram = true, .ram_block = &file }, false },
        { "a RAM device (ram_device)", { .ram = true, .ram_device = true, .ram_block = &anon }, false },
        { "main RAM while dirty logging write-protects it", { .ram = true, .dirty_log_mask = 1, .ram_block = &anon }, false },
        { "an I/O region (not RAM)", { .ram = false, .ram_block = NULL }, false },
        { "RAM without a block", { .ram = true, .ram_block = NULL }, false },
    };
    printf("test-dcount --predicate: omacvm_ram_private()\n");
    for (size_t i = 0; i < sizeof(rows_) / sizeof(rows_[0]); i++) {
        bool got = omacvm_ram_private(&rows_[i].mr);
        row(got == rows_[i].want, "%s: %s", rows_[i].what, got ? "swept and replaced" : "never touched");
    }
    return fails ? 1 : 0;
}
#endif

int main(int argc, char **argv)
{
    const char *mode = "";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hv")) {
            use_hv = true;
        } else {
            mode = argv[i];
        }
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    pg = (size_t)getpagesize();
#if !defined(SWEEP_MAIN) && !defined(SWEEP_OLD)
    if (!strcmp(mode, "--predicate")) {
        return predicate();
    }
#endif
    const char *tmp = getenv("TEST_DCOUNT_DIR");
    snprintf(io_in, sizeof(io_in), "%s/io-in", tmp ? tmp : ".");
    snprintf(io_out, sizeof(io_out), "%s/io-out", tmp ? tmp : ".");
    ram = mmap(NULL, ram_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (ram == MAP_FAILED) {
        die("mmap", errno);
    }
    if (use_hv) {
        hv_return_t r = hv_vm_create(NULL);
        if (r != HV_SUCCESS) {
            printf("SKIP --hv: no hypervisor for this process (hv_vm_create 0x%x)\n", r);
            return 2;
        }
        uint32_t *code = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        memcpy(code, prog, sizeof(prog));
        if ((r = hv_vm_map(code, CODE_IPA, pg, HV_MEMORY_READ | HV_MEMORY_EXEC)) ||
            (r = hv_vm_map(ram, RAM_IPA, ram_size, HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)) ||
            (r = hv_vcpu_create(&vcpu, &vexit, NULL))) {
            die("the hypervisor's map", r);
        }
    } else {
        mach_vm_address_t a = 0;
        vm_prot_t cur, max;
        if (real_remap(&a, ram_size, VM_FLAGS_ANYWHERE, (mach_vm_address_t)ram, FALSE, &cur, &max, VM_INHERIT_NONE)) {
            die("the second mapping", 0);
        }
        hvmap = (uint8_t *)a;
    }
#if defined(SWEEP_MAIN)
    (void)mode;
#else
    if (*mode) {
        int rc = divergence(mode);
        printf("test-dcount %s: %s\n", mode, rc == 0 ? "all ok" : "FAILED");
        return rc;
    }
#endif
    int rc = rows();
    printf("test-dcount: %s\n", rc == 0 ? "all ok" : rc == 2 ? "skipped" : "FAILED");
    return rc;
}
