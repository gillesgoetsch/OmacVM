/* Test for qemu-hvf-own-view-sweep.patch (no VM): does Activity Monitor
 * count guest RAM once after a sweep, and do QEMU and the guest still see
 * the same memory?
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
 *   test-dcount [--hv]       the sweep's rows (below)
 *   test-dcount --diverge    a remap that changes QEMU's view in the first pass: QEMU must stop (abort)
 *   test-dcount --predicate  which RAM blocks a report may replace and the sweep may remap
 *
 * Rows: QEMU writes 1 GB (a disk read), the guest reads it: footprint about
 * twice held (else this Mac does not count it twice: SKIP). Pass 1 while a
 * thread reads and writes a file into and out of guest RAM (pread/pwrite,
 * buffered and F_NOCACHE: QEMU's disk thread pool), with a free page report
 * between chunks in a chunk already swept and in one not yet swept, their
 * moves aside released only after the pass, and the replaced ranges
 * touched by neither side until after it. Then a clean pass 2: footprint
 * within 1 % of held, every page right as the guest sees it, and after it
 * QEMU's writes seen by the guest and the guest's by QEMU (the replaced
 * ranges too). Then: a pass is skipped while the footprint grew less than
 * 64 MB; a chunk with an entry that has no object yet, or is copy-on-write,
 * stays as it is (counted, one line), the rest is remapped; a failed remap
 * stops the sweep for the run (one line), QEMU's view unchanged; the hour's
 * and the run's qemu.log lines.
 *
 * Built two ways by test-dcount.sh: the patch's sweep (must pass) and
 * -DSWEEP_MAIN (no sweep, as up to 3.2.16: must fail with "COUNTED TWICE").
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

/* The sweep's remaps (VM_FLAGS_OVERWRITE) on demand: fail (no room), or change QEMU's view after the remap. */
enum { REMAP_REAL, REMAP_FAIL, REMAP_DIVERGE };
static int remap_mode = REMAP_REAL;
static unsigned long sweep_remaps;
static kern_return_t test_mach_vm_remap(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size,
                                        mach_vm_offset_t mask, int flags, vm_map_t src, mach_vm_address_t src_address,
                                        boolean_t copy, vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inherit)
{
    kern_return_t kr;

    if (flags & VM_FLAGS_OVERWRITE) {
        sweep_remaps++;
        if (remap_mode == REMAP_FAIL) {
            return KERN_NO_SPACE;
        }
    }
    kr = mach_vm_remap(target, address, size, mask, flags, src, src_address, copy, cur, max, inherit);
    if (kr == KERN_SUCCESS && (flags & VM_FLAGS_OVERWRITE) && remap_mode == REMAP_DIVERGE) {
        /* What a remap of a copy-on-write entry does: QEMU's view gets memory of its own. */
        mmap((void *)*address, pg, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0);
    }
    return kr;
}
#define mach_vm_remap test_mach_vm_remap
#include "reclaim.inc"
#if !defined(SWEEP_MAIN)
#include "sweep.inc"
static const char *sweep_name = "the patch's sweep";
#else
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
#endif
#undef mach_vm_remap

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

static double ratio(uint64_t fp, uint64_t base, uint64_t h)
{
    return h ? (double)(fp > base ? fp - base : 0) / (double)h : 0;
}

static int rows(void)
{
    OmacvmSweep s;
    pthread_t io;
    uint64_t base, fp, h;

    printf("test-dcount: %s, guest RAM %llu MB, %s\n", sweep_name, (unsigned long long)(ram_size / MB),
           use_hv ? "a real hv_vm_map and vCPU" : "a second mapping for the hypervisor's");
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
    pthread_create(&io, NULL, io_thread, NULL);
    while (io_rounds < 2) {
        usleep(1000);
    }
    omacvm_sweep_setup(&s, ram, ram_size, 300, true, clock_now);
    run_pass(&s, report_between);
    unsigned long rounds = io_rounds;
    atomic_store(&io_stop, true);
    pthread_join(io, NULL);
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
    munmap(io_want, IO_LEN);
    munmap(io_back, IO_LEN);
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
#if defined(SWEEP_MAIN)
    return fails ? 1 : 0;
#else
    /* Idle: a pass is skipped while the footprint grew less than 64 MB. */
    run_pass(&s, NULL);   /* the writes above grew it: this pass runs */
    uint64_t passes = s.run.passes, chunks = s.run.chunks, idle = s.run.idle;
    int64_t next = omacvm_sweep_step(&s, clock_now, true);
    row(next == s.period_ns && s.run.idle == idle + 1 && s.run.chunks == chunks && s.run.passes == passes,
        "a pass is skipped while the footprint grew less than 64 MB (next look in %lld s)",
        (long long)(next / NANOSECONDS_PER_SECOND));
    clock_now += next;

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

    /* qemu.log: the hour's line from the sweep's own timer, the run's line at exit. */
    char why[1024];
    omacvm_sweep_log(&s, "this run", &s.run);
    snprintf(why, sizeof(why), "%s", last_info);
    row(strstr(why, "OmacVM: own-view sweep this run: ") && strstr(why, " passes over 1024 MB of guest RAM, ") &&
        strstr(why, " skipped (QEMU's footprint grew less than 64 MB), ") && strstr(why, "; Activity Monitor ") &&
        strstr(why, "MB less; main lock per chunk p99 ") && strstr(why, "2 chunks (256 MB) left as they were") &&
        strstr(why, "; stopped: a remap at +0 MB failed"), "the run's qemu.log line");
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
/* --diverge: a remap that leaves QEMU's view other memory than the guest's, in the first pass: QEMU stops. */
static int diverge(void)
{
    OmacvmSweep s;
    qemu_write(0, ram_size, 1);
    guest(G_VERIFY, 0, ram_size, 1);
    omacvm_sweep_setup(&s, ram, ram_size, 300, false, 0);
    remap_mode = REMAP_DIVERGE;
    run_pass(&s, NULL);
    printf("test-dcount --diverge: the sweep went on (%llu chunks)\n", (unsigned long long)s.run.chunks);
    return 1;
}

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
#if defined(SWEEP_MAIN)
    (void)mode;
#else
    if (!strcmp(mode, "--predicate")) {
        return predicate();
    }
    if (!strcmp(mode, "--diverge")) {
        ram_size = 256 * MB;
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
#if !defined(SWEEP_MAIN)
    if (!strcmp(mode, "--diverge")) {
        return diverge();
    }
#endif
    int rc = rows();
    printf("test-dcount: %s\n", rc == 0 ? "all ok" : rc == 2 ? "skipped" : "FAILED");
    return rc;
}
