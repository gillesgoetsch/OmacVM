/* Test for qemu-darwin-surface-memory.patch (no VM): a display surface's
 * memory as the patched QEMU source makes and frees it. ui/qemu-pixman.c's
 * shareable alloc/free/destroy/new and util/memfd.c's qemu_memfd_alloc/free
 * are taken from the source by test-surface-memory.sh; pixman is QEMU's own
 * pixman-minimal.h. mkstemp, unlink, ftruncate, close and munmap are
 * stand-ins that record each call; close() takes CLOSE_MS (argument 1;
 * 2200: the 2.2 s close() on the swapping mini, 2026-10-28 13:33), as a
 * file delete that waits on the disk.
 *
 *   test-surface-memory CLOSE_MS memory|file
 *
 * memory (the default; QEMU makes and frees surfaces with the BQL held):
 *   new:   a 5120x2880 surface makes no file (no mkstemp/ftruncate/unlink),
 *          its handle is SHAREABLE_NONE, its pixels read zero and take writes;
 *   free:  the last unref calls no close(), unmaps the size once and returns
 *          within 1000 ms with the slow close() stand-in;
 *   churn: 300 surfaces made and freed (fast mode changes): no fd and no
 *          memory left behind (open fds, phys_footprint within 8 MB).
 * file (OMACVM_SURFACE_MEMORY=file, QEMU's temp file):
 *   new:   mkstemp, a handle >= 0; free: close() and that fd is gone;
 *   churn: 20 surfaces, no fd left.
 */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define CONFIG_DARWIN 1
/* the few glib calls of these functions */
#define g_new0(T, n) ((T *)calloc((n), sizeof(T)))
#define g_malloc0(n) calloc(1, (n))
#define g_free(p) free(p)
#define DIV_ROUND_UP(n, d) (((n) + (d) - 1) / (d))
typedef char gchar;
#define GINT_TO_POINTER(i) ((void *)(intptr_t)(i))
#define GPOINTER_TO_INT(p) ((int)(intptr_t)(p))
#define g_return_val_if_fail(e, v) do { if (!(e)) return (v); } while (0)
static const char *g_get_tmp_dir(void) { const char *t = getenv("TMPDIR"); return t && *t ? t : "/tmp"; }
static char *g_strdup_printf(const char *fmt, ...)
{
    char *s = NULL;
    va_list ap;
    va_start(ap, fmt);
    if (vasprintf(&s, fmt, ap) < 0) s = NULL;
    va_end(ap);
    return s;
}
#define likely(x) __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

/* QEMU's Error API, as far as these functions use it */
typedef struct Error { char msg[256]; } Error;
#define ERRP_GUARD() do { } while (0)
static void error_setg_impl(Error **errp, const char *fmt, ...)
{
    if (errp && *errp == NULL) {
        static Error e;
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(e.msg, sizeof e.msg, fmt, ap);
        va_end(ap);
        *errp = &e;
    }
}
#define error_setg(errp, ...) error_setg_impl(errp, __VA_ARGS__)
#define error_setg_errno(errp, err, ...) ((void)(err), error_setg_impl(errp, __VA_ARGS__))
static void error_report(const char *fmt, ...) { (void)fmt; }

#include "pixman-minimal.h"
#include "qemu-pixman-shareable.inc"   /* typedef + SHAREABLE_* from include/ui/qemu-pixman.h */

/* stand-ins: record every call that touches the file system */
static char calls[4096];
static int close_ms;
static void note(const char *c) { strlcat(calls, c, sizeof calls); strlcat(calls, " ", sizeof calls); }
static int si_mkstemp(char *t) { note("mkstemp"); return mkstemp(t); }
static int si_unlink(const char *p) { note("unlink"); return unlink(p); }
static int si_ftruncate(int fd, off_t n) { note("ftruncate"); return ftruncate(fd, n); }
static int si_close(int fd)
{
    struct timespec ts = { close_ms / 1000, (long)(close_ms % 1000) * 1000000L };
    note("close");
    nanosleep(&ts, NULL);
    return close(fd);
}
static size_t unmapped;
static int si_munmap(void *p, size_t n) { note("munmap"); unmapped = n; return munmap(p, n); }
static int qemu_memfd_create(const char *name, size_t size, bool hugetlb, uint64_t hs, unsigned int seals,
                             Error **errp)
{
    (void)name; (void)size; (void)hugetlb; (void)hs; (void)seals; (void)errp;
    errno = ENOSYS;
    return -1;   /* macOS: no memfd (util/memfd.c without CONFIG_LINUX) */
}
#define mkstemp(t) si_mkstemp(t)
#define unlink(p) si_unlink(p)
#define ftruncate(fd, n) si_ftruncate(fd, n)
#define close(fd) si_close(fd)
#define munmap(p, n) si_munmap(p, n)
#include "memfd-alloc-free.inc"        /* qemu_memfd_alloc, qemu_memfd_free from util/memfd.c */
#include "pixman-shareable.inc"        /* from ui/qemu-pixman.c */
#undef close
#undef munmap
#undef mkstemp
#undef unlink
#undef ftruncate

static int fails;
static void check(bool ok, const char *what, const char *detail)
{
    printf("%s %s%s%s\n", ok ? "ok  " : "FAIL", what, detail && *detail ? ": " : "", detail ? detail : "");
    fails += !ok;
}
static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_UPTIME_RAW, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}
static int open_fds(void)
{
    int n = 0;
    for (int fd = 0; fd < 4096; fd++) {
        n += fcntl(fd, F_GETFD) != -1;
    }
    return n;
}
static uint64_t footprint(void)
{
    task_vm_info_data_t i;
    mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&i, &c) == KERN_SUCCESS ? i.phys_footprint : 0;
}
static bool has(const char *s, const char *call) { return strstr(s, call) != NULL; }

int main(int argc, char **argv)
{
    const int w = 5120, h = 2880;
    bool file = argc > 2 && strcmp(argv[2], "file") == 0;
    pixman_image_t *img = NULL;
    qemu_pixman_shareable handle = SHAREABLE_NONE;
    Error *err = NULL;
    char d[256];

    close_ms = argc > 1 ? atoi(argv[1]) : 2200;
    printf("%s mode, close() %d ms\n", file ? "file" : "memory", close_ms);
    /* new */
    calls[0] = 0;
    int fds0 = open_fds();
    bool made = qemu_pixman_image_new_shareable(&img, &handle, "displaysurface", PIXMAN_x8r8g8b8, w, h, 0, &err);
    check(made && img, "new: a 5120x2880 surface", err ? err->msg : "");
    if (!made) return 1;
    snprintf(d, sizeof d, "calls '%s'", calls);
    if (file) {
        check(has(calls, "mkstemp") && has(calls, "ftruncate"), "new: a temp file (OMACVM_SURFACE_MEMORY=file)", d);
    } else {
        check(!has(calls, "mkstemp") && !has(calls, "ftruncate") && !has(calls, "unlink"), "new: no file made", d);
    }
    snprintf(d, sizeof d, "handle %d", (int)handle);
    check(file ? handle >= 0 : handle == SHAREABLE_NONE, file ? "new: the file is the share handle" : "new: no share handle", d);
    uint32_t *px = pixman_image_get_data(img);
    size_t words = (size_t)pixman_image_get_stride(img) / 4 * h;
    bool zero = true;
    for (size_t i = 0; i < words; i += 997) zero &= px[i] == 0;
    px[0] = 0x11223344; px[words - 1] = 0x55667788;
    check(zero && px[0] == 0x11223344 && px[words - 1] == 0x55667788, "new: pixels zero, writable", "");
    /* free (the last unref runs the destroy function) */
    calls[0] = 0;
    size_t bytes = (size_t)pixman_image_get_stride(img) * h;
    double t0 = now_ms();
    pixman_image_unref(img);
    double took = now_ms() - t0;
    snprintf(d, sizeof d, "calls '%s', %.1f ms, munmap %zu bytes", calls, took, unmapped);
    bool munmap_once = has(calls, "munmap") && !has(strstr(calls, "munmap") + 1, "munmap") && unmapped == bytes;
    if (file) {
        check(munmap_once && has(calls, "close"), "free: munmap and close()", d);
        snprintf(d, sizeof d, "fd %d %s, fds %d -> %d", (int)handle,
                 fcntl(handle, F_GETFD) == -1 ? "closed" : "still open", fds0, open_fds());
        check(fcntl(handle, F_GETFD) == -1 && open_fds() == fds0, "free: no fd left", d);
    } else {
        check(!has(calls, "close"), "free: no close()", d);
        check(munmap_once && took < 1000, "free: munmap once, < 1000 ms", d);
    }
    /* churn */
    int n = file ? 20 : 300;
    fds0 = open_fds();
    uint64_t fp0 = footprint();
    close_ms = 0;
    for (int i = 0; i < n; i++) {
        int ww = i % 2 ? 3456 : 5120, hh = i % 2 ? 2234 : 2880;
        if (!qemu_pixman_image_new_shareable(&img, &handle, "displaysurface", PIXMAN_x8r8g8b8, ww, hh, 0, &err)) {
            check(false, "churn: new", err ? err->msg : "");
            break;
        }
        ((volatile uint32_t *)pixman_image_get_data(img))[0] = 1;
        pixman_image_unref(img);
    }
    int fds1 = open_fds();
    uint64_t fp1 = footprint();
    snprintf(d, sizeof d, "fds %d -> %d, footprint %.1f -> %.1f MB", fds0, fds1, fp0 / 1048576.0, fp1 / 1048576.0);
    char what[64];
    snprintf(what, sizeof what, "churn: %d surfaces, nothing left behind", n);
    check(fds1 == fds0 && fp1 < fp0 + 8 * 1048576ull, what, d);
    printf("test-surface-memory (%s): %s\n", file ? "file" : "memory", fails ? "FAILED" : "all ok");
    return fails ? 1 : 0;
}
