/*
 * OmacVM's VA-API driver shim for OmacVM.app: Mesa's virtio_gpu driver with
 * one change. Mesa's virgl driver offers I420 and YV12 surfaces for decoding
 * next to NV12; FFmpeg then picks I420 (it matches yuv420p), and Firefox
 * cannot show I420 surfaces, so it falls back to decoding on the CPU. This
 * shim loads Mesa's driver unchanged and hides I420/YV12 from the surface
 * formats, as drivers for real hardware do.
 *
 * AV1: the Mac decodes whole AV1 frames with their headers, which Chromium
 * sends; FFmpeg (Firefox, mpv) sends only tile data, which cannot work. So
 * AV1 is listed for Chromium-based browsers only (OMACVM_VA_AV1=1 or 0
 * overrides).
 *
 * Limits: the Mac keeps only so many decoders and encoders open at once per
 * VM and says how many in its video caps. Past that it gives a new one
 * nothing, and the guest cannot be told, so the video would stay black. So
 * the shim refuses vaCreateContext first (VA_STATUS_ERROR_MAX_NUM_EXCEEDED)
 * and players and browsers decode (or encode) that one on the CPU; an FFmpeg
 * command that names a VA-API encoder itself stops with that error.
 * Counting across processes: a context holds a slot, an OFD lock on one byte
 * of /dev/shm/omacvm-va-slots, so a process that quits or crashes frees its
 * slots. Firefox decodes in a sandbox that can neither open that file nor
 * lock; such a process counts only its own contexts, up to half the limit,
 * and the shared slots are the other half. The VM stays within the limit as
 * long as at most one such process decodes. OMACVM_VA_DEBUG=1 prints the
 * limits. Everything else is Mesa's.
 *
 * Built in the VM by install.sh; used through LIBVA_DRIVER_NAME=omacvm.
 * MIT, part of OmacVM.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <drm/virtgpu_drm.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>

#ifndef MESA_DRIVER
#define MESA_DRIVER "/usr/lib/dri/virtio_gpu_drv_video.so"
#endif

static VAStatus (*mesa_query_surface_attributes)(VADriverContextP, VAConfigID,
                                                 VASurfaceAttrib *, unsigned int *);

static VAStatus query_surface_attributes(VADriverContextP ctx, VAConfigID config,
                                         VASurfaceAttrib *attribs, unsigned int *num)
{
    VAStatus st = mesa_query_surface_attributes(ctx, config, attribs, num);
    unsigned int i, n = 0;
    int has_nv12 = 0;

    if (st != VA_STATUS_SUCCESS || !attribs)
        return st;
    for (i = 0; i < *num; i++)
        if (attribs[i].type == VASurfaceAttribPixelFormat &&
            attribs[i].value.value.i == VA_FOURCC_NV12)
            has_nv12 = 1;
    if (!has_nv12)
        return st;
    for (i = 0; i < *num; i++) {
        if (attribs[i].type == VASurfaceAttribPixelFormat &&
            (attribs[i].value.value.i == VA_FOURCC_I420 ||
             attribs[i].value.value.i == VA_FOURCC_YV12))
            continue;
        attribs[n++] = attribs[i];
    }
    *num = n;
    return st;
}

static VAStatus (*mesa_query_config_profiles)(VADriverContextP, VAProfile *, int *);

static int av1_allowed(void)
{
    const char *env = getenv("OMACVM_VA_AV1");
    char exe[PATH_MAX];
    ssize_t n;

    if (env && *env)
        return *env == '1';
    n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0)
        return 0;
    exe[n] = 0;
    return strstr(exe, "chrom") || strstr(exe, "brave") || strstr(exe, "electron");
}

static VAStatus query_config_profiles(VADriverContextP ctx, VAProfile *list, int *num)
{
    VAStatus st = mesa_query_config_profiles(ctx, list, num);
    int i, n = 0;

    if (st != VA_STATUS_SUCCESS || av1_allowed())
        return st;
    for (i = 0; i < *num; i++) {
        if (list[i] == VAProfileAV1Profile0 || list[i] == VAProfileAV1Profile1)
            continue;
        list[n++] = list[i];
    }
    *num = n;
    return st;
}

/* ---- Limits (see the top) ---- */

enum { DEC, ENC, KINDS };
static const char *const kind_name[KINDS] = { "decoders", "encoders" };

/* The virgl caps (capset 2) as the host sends them. The struct only grows at
 * its end (virgl protocol), so these offsets stay. Per video cap, OmacVM's
 * host puts the limit for that entrypoint into the top 8 of the 20 reserved
 * bits of the 4th word; 0 (any other host) means no limit is said. */
#define CAPS_SIZE 1408          /* sizeof(union virgl_caps) */
#define CAPS_NUM_VIDEO 856      /* offsetof(struct virgl_caps_v2, num_video_caps) */
#define CAPS_VIDEO 860          /* offsetof(struct virgl_caps_v2, video_caps), 16 bytes each */
#define PIPE_ENTRYPOINT_BITSTREAM 1
#define PIPE_ENTRYPOINT_ENCODE 4

#define SLOTS_FILE "/dev/shm/omacvm-va-slots"
#define SLOTS_KIND_STRIDE 256   /* encoders' bytes start here */

static pthread_mutex_t lim_lock = PTHREAD_MUTEX_INITIALIZER;
static int lim_read;            /* the host's caps were read */
static unsigned limit[KINDS];   /* per VM; 0 = none said */
static int slots_fd = -1;       /* the shared slots */
static int slots_ok;            /* ... usable: else this process counts on its own */
static unsigned own[KINDS];     /* contexts counted in this process only */
static struct held {
    VADriverContextP drv;
    VAContextID id;
    int kind;
    int slot;                   /* byte in SLOTS_FILE, or -1 (counted in own[]) */
} held[2 * 256];                /* limits are 8 bits: at most 255 each */
static unsigned nheld;

static VAStatus (*mesa_create_context)(VADriverContextP, VAConfigID, int, int, int,
                                       VASurfaceID *, int, VAContextID *);
static VAStatus (*mesa_destroy_context)(VADriverContextP, VAContextID);
static VAStatus (*mesa_terminate)(VADriverContextP);

static void read_limits(VADriverContextP ctx)
{
    struct drm_state *drm = ctx->drm_state;
    uint32_t caps[CAPS_SIZE / 4] = { 0 };
    struct drm_virtgpu_get_caps args = { .cap_set_id = 2, .cap_set_ver = 0,
                                         .addr = (uintptr_t)caps, .size = sizeof(caps) };
    uint32_t i, n;

    if (!drm || drm->fd < 0 || ioctl(drm->fd, DRM_IOCTL_VIRTGPU_GET_CAPS, &args))
        return;
    lim_read = 1;
    n = caps[CAPS_NUM_VIDEO / 4];
    for (i = 0; i < n && i < 32; i++) {
        const uint32_t *v = &caps[(CAPS_VIDEO + 16 * i) / 4];
        unsigned entrypoint = (v[0] >> 8) & 0xff, max = v[3] >> 24;
        int k = entrypoint == PIPE_ENTRYPOINT_BITSTREAM ? DEC :
                entrypoint == PIPE_ENTRYPOINT_ENCODE ? ENC : -1;
        if (k >= 0 && max && (!limit[k] || max < limit[k]))
            limit[k] = max;
    }
    if (!limit[DEC] && !limit[ENC]) {
        if (getenv("OMACVM_VA_DEBUG"))
            fprintf(stderr, "omacvm_drv_video: the Mac says no limit (an older OmacVM)\n");
        return;
    }
    /* Opened before a sandbox closes in where it can (Chrome); Firefox's
     * decoding process cannot, and then counts on its own. Not O_CREAT on an
     * existing file: another user's file in /dev/shm would be refused. */
    slots_fd = open(SLOTS_FILE, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (slots_fd < 0 && errno == ENOENT) {
        slots_fd = open(SLOTS_FILE, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0666);
        if (slots_fd >= 0)
            fchmod(slots_fd, 0666);
        else if (errno == EEXIST)
            slots_fd = open(SLOTS_FILE, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    }
    slots_ok = slots_fd >= 0;
    if (getenv("OMACVM_VA_DEBUG"))
        fprintf(stderr, "omacvm_drv_video: the Mac keeps at most %u decoders and %u encoders "
                "open per VM (0: none said); this process %s\n", limit[DEC], limit[ENC],
                slots_ok ? "shares the count through " SLOTS_FILE : "counts on its own");
}

/* Shared slots are half the limit (rounded up), a process counting on its
 * own gets the other half. */
static unsigned shared_slots(int k) { return limit[k] - limit[k] / 2; }
static unsigned own_budget(int k) { return limit[k] / 2; }

/* A free shared slot (locked for this context), -1 if all are taken, -2 if
 * locks do not work here. Called with lim_lock held, like everything that
 * touches the state above. */
static int take_slot(int k)
{
    unsigned s, i;

    for (s = 0; s < shared_slots(k); s++) {
        struct flock fl = { .l_type = F_WRLCK, .l_whence = SEEK_SET,
                            .l_start = k * SLOTS_KIND_STRIDE + s, .l_len = 1 };
        /* OFD locks belong to the open file, so this process's own slots do
         * not conflict: skip them by hand. */
        for (i = 0; i < nheld; i++)
            if (held[i].kind == k && held[i].slot == (int)s)
                break;
        if (i < nheld)
            continue;
        if (fcntl(slots_fd, F_OFD_SETLK, &fl) == 0)
            return s;
        if (errno != EAGAIN && errno != EACCES)
            return -2;
    }
    return -1;
}

static void give_back(int k, int slot)
{
    if (slot >= 0) {
        struct flock fl = { .l_type = F_UNLCK, .l_whence = SEEK_SET,
                            .l_start = k * SLOTS_KIND_STRIDE + slot, .l_len = 1 };
        fcntl(slots_fd, F_OFD_SETLK, &fl);
    } else if (own[k]) {
        own[k]--;
    }
}

/* Decoder, encoder, or neither (video processing makes no codec on the Mac). */
static int config_kind(VADriverContextP ctx, VAConfigID config)
{
    VAProfile profile;
    VAEntrypoint entrypoint;
    VAConfigAttrib *attribs;
    int n = 0, k = -1;

    if (!ctx->vtable->vaQueryConfigAttributes)
        return -1;
    attribs = calloc(ctx->max_attributes > 0 ? ctx->max_attributes : 1, sizeof(*attribs));
    if (attribs && ctx->vtable->vaQueryConfigAttributes(ctx, config, &profile, &entrypoint,
                                                        attribs, &n) == VA_STATUS_SUCCESS)
        k = entrypoint == VAEntrypointVLD ? DEC :
            entrypoint == VAEntrypointEncSlice || entrypoint == VAEntrypointEncSliceLP ||
            entrypoint == VAEntrypointEncPicture ? ENC : -1;
    free(attribs);
    return k;
}

/* A refusal goes to stderr: the first at once, then at most every 10 s with
 * how many there were since. */
static void say_refused(int k, int shared)
{
    static struct timespec last[KINDS];
    static unsigned since[KINDS];
    struct timespec now;

    clock_gettime(CLOCK_MONOTONIC, &now);
    if (last[k].tv_sec && now.tv_sec - last[k].tv_sec < 10) {
        since[k]++;
        return;
    }
    if (shared)
        fprintf(stderr, "omacvm_drv_video: the VM's %u hardware video %s are in use (the Mac "
                "keeps %u open per VM); refused this one (players and browsers use the CPU "
                "then)", shared_slots(k), kind_name[k], limit[k]);
    else
        fprintf(stderr, "omacvm_drv_video: this process has its %u hardware video %s open "
                "(half the Mac's %u per VM); refused this one (players and browsers use the "
                "CPU then)", own_budget(k), kind_name[k], limit[k]);
    if (since[k])
        fprintf(stderr, " (%u more refused in the last %ld s)", since[k],
                (long)(now.tv_sec - last[k].tv_sec));
    fputc('\n', stderr);
    last[k] = now;
    since[k] = 0;
}

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int width, int height,
                               int flag, VASurfaceID *targets, int num_targets,
                               VAContextID *context)
{
    int k = config_kind(ctx, config), slot = -1;
    VAStatus st;

    pthread_mutex_lock(&lim_lock);
    if (!lim_read)
        read_limits(ctx);
    if (k < 0 || !limit[k]) {
        pthread_mutex_unlock(&lim_lock);
        return mesa_create_context(ctx, config, width, height, flag, targets, num_targets, context);
    }
    if (slots_ok) {
        slot = take_slot(k);
        if (slot == -2) {
            /* Locks refused (a sandbox): count on our own from now on. Slots
             * this process holds stay held (closing the file would drop them). */
            fprintf(stderr, "omacvm_drv_video: cannot lock %s here, counting this process's "
                    "video contexts on its own\n", SLOTS_FILE);
            slots_ok = 0;
        } else if (slot == -1) {
            say_refused(k, 1);
            pthread_mutex_unlock(&lim_lock);
            return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
        }
    }
    if (slot < 0) {
        if (own[k] >= own_budget(k)) {
            say_refused(k, 0);
            pthread_mutex_unlock(&lim_lock);
            return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
        }
        own[k]++;
        slot = -1;
    }
    pthread_mutex_unlock(&lim_lock);

    st = mesa_create_context(ctx, config, width, height, flag, targets, num_targets, context);

    pthread_mutex_lock(&lim_lock);
    if (st == VA_STATUS_SUCCESS && nheld < sizeof(held) / sizeof(held[0]))
        held[nheld++] = (struct held){ ctx, *context, k, slot };
    else
        give_back(k, slot);
    pthread_mutex_unlock(&lim_lock);
    return st;
}

static void release(VADriverContextP ctx, VAContextID id, int all)
{
    unsigned i = 0;

    pthread_mutex_lock(&lim_lock);
    while (i < nheld) {
        if (held[i].drv == ctx && (all || held[i].id == id)) {
            give_back(held[i].kind, held[i].slot);
            held[i] = held[--nheld];
            if (!all)
                break;
        } else {
            i++;
        }
    }
    pthread_mutex_unlock(&lim_lock);
}

/* The slot is given back first: once Mesa frees the context, another thread
 * may get the same ID for a new one. */
static VAStatus destroy_context(VADriverContextP ctx, VAContextID context)
{
    release(ctx, context, 0);
    return mesa_destroy_context(ctx, context);
}

/* A display closed with contexts still open frees their slots too. */
static VAStatus terminate(VADriverContextP ctx)
{
    release(ctx, 0, 1);
    return mesa_terminate(ctx);
}

typedef VAStatus (*init_fn)(VADriverContextP);

static VAStatus shim_init(VADriverContextP ctx)
{
    static void *mesa;
    char name[32];
    init_fn init = NULL;
    VAStatus st;
    int minor;

    if (!mesa)
        mesa = dlopen(MESA_DRIVER, RTLD_NOW | RTLD_GLOBAL);
    if (!mesa)
        return VA_STATUS_ERROR_UNKNOWN;
    for (minor = 99; minor >= 0 && !init; minor--) {
        snprintf(name, sizeof(name), "__vaDriverInit_1_%d", minor);
        init = (init_fn)dlsym(mesa, name);
    }
    if (!init)
        return VA_STATUS_ERROR_UNKNOWN;
    st = init(ctx);
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaQuerySurfaceAttributes) {
        mesa_query_surface_attributes = ctx->vtable->vaQuerySurfaceAttributes;
        ctx->vtable->vaQuerySurfaceAttributes = query_surface_attributes;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaQueryConfigProfiles) {
        mesa_query_config_profiles = ctx->vtable->vaQueryConfigProfiles;
        ctx->vtable->vaQueryConfigProfiles = query_config_profiles;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaCreateContext &&
        ctx->vtable->vaDestroyContext && ctx->vtable->vaTerminate) {
        mesa_create_context = ctx->vtable->vaCreateContext;
        mesa_destroy_context = ctx->vtable->vaDestroyContext;
        mesa_terminate = ctx->vtable->vaTerminate;
        ctx->vtable->vaCreateContext = create_context;
        ctx->vtable->vaDestroyContext = destroy_context;
        ctx->vtable->vaTerminate = terminate;
        pthread_mutex_lock(&lim_lock);
        if (!lim_read)
            read_limits(ctx);
        pthread_mutex_unlock(&lim_lock);
    }
    return st;
}

/* libva looks for its own minor version first, then older ones. */
#define INIT(m) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx); \
    __attribute__((visibility("default"))) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx) { return shim_init(ctx); }
INIT(20) INIT(21) INIT(22) INIT(23) INIT(24) INIT(25) INIT(26) INIT(27) INIT(28)
INIT(29) INIT(30) INIT(31) INIT(32)
