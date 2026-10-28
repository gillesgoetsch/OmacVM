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
 * Surfaces with their real size (Chromium): Mesa's virgl gives a surface's
 * planes a guest buffer of one page when the Mac keeps their pixels (copy
 * transfers), so a plane's dma-buf says 4096 bytes. Chromium (Chrome, Brave,
 * Electron) converts each decoded frame into an ARGB surface of its own
 * (VA-API video processing) and, before it hands that back to VA-API, checks
 * every plane against its dma-buf's size ("Plane 0 is out of bounds: 8294400
 * > 4096"), then decodes on the CPU. So in Chromium's processes the shim asks
 * for surfaces that will be exported (memory type DRM_PRIME_2 without a
 * descriptor, as libva documents it): Mesa makes them shared, with a guest
 * buffer of the planes' size (1080p: 3.3 MB NV12, 8.3 MB ARGB). Only when the
 * Mac's runtime draws those ARGB frames (it says omacvm.vaexport=1 at start:
 * /run/omacvm/host.env); an older one shows them black, and then the CPU is
 * better. Other apps keep Mesa's one page. OMACVM_VA_EXPORT=1 or 0 overrides.
 * Chromium's decoders see a largest size of 1920 x 1920 (OMACVM_VA_MAX, 0:
 * none; encoders and video processing keep Mesa's) unless the Mac's runtime
 * decodes beside its GPU thread (omacvm.vadecasync=1, below): an older one
 * waited for every picture on that thread, and above 1080p Chrome's hardware
 * path then dropped far more frames than its CPU decoders (4K VP9 on an M2: 38 %
 * against 7 %). With the newer one there is no limit (4K: 6-7 % on the M2 and
 * on an M4 Max, the CPU 7-8 %). Only in Chromium's processes, also when
 * OMACVM_VA_EXPORT=1 forces the export hint elsewhere.
 *
 * Waiting for the picture (Chromium): the Mac's runtime decodes beside its GPU
 * thread (it says omacvm.vadecasync=1 at start): vaEndPicture returns at once
 * and the picture comes into the surface when the media engine is done. Chromium
 * converts each picture to ARGB right after decoding it; that conversion would
 * wait on the Mac's GPU thread for the picture, and every app's drawing with it.
 * So in Chromium's processes the shim waits after vaEndPicture on a decoding
 * context: an empty command with a fence on the display's DRM file, which the
 * Mac signals once every picture sent before it is in its planes. Chromium's
 * decoder thread waits instead of the Mac's GPU thread; at most 100 ms.
 * OMACVM_VA_DECODE_WAIT=1 or 0 overrides.
 *
 * Chromium's RGB frames fill their planes: Mesa rounds a surface's planes up
 * to 16 (a 320x180 surface has 192 rows), and Chrome shows the ARGB frames it
 * converts each decoded picture into by its own size, so the whole texture
 * lands in the frame's place: the picture squeezed into 180 of 192 rows, and
 * 12 rows nobody wrote (transparent) below it; a call's 320x180 tile lost its
 * bottom 6 %, 1080p 8 rows. In Chromium's processes the shim has the
 * conversion (VA-API video processing into such an RGB frame, for the whole
 * frame) fill the whole rounded texture; Chrome then puts every row of the
 * picture where it belongs. Mesa also takes the
 * source region in parts of the source surface's own size while it samples
 * the rounded planes (a 320x180 VP9 picture's 12 padding rows came along): the
 * source region is scaled to the picture's part of them. Chrome converts into
 * an import of its own frame (the dma-buf it exported): such an RGB import whose
 * buffer holds the rounded planes (Mesa made it) is imported at the rounded
 * size, so the conversion may draw all of it. Only 4:2:0 surfaces whose planes
 * are rounded get the source scaling (Mesa's own, and imports laid out so, as
 * Chrome's decoder's GBM buffers; an exact-size import keeps its region), and
 * only with a Mesa this was checked with (FILL_MESA_MAX; a newer one: off,
 * logged). OMACVM_VA_FILL=0 or 1 overrides.
 *
 * Limits: the Mac says in its video caps how many decoders and encoders a VM
 * should keep open at once. Past a somewhat higher limit of its own it gives
 * a new one nothing, and the guest cannot be told, so the video would stay
 * black. So the shim refuses vaCreateContext past the caps' number
 * (VA_STATUS_ERROR_MAX_NUM_EXCEEDED) and players and browsers decode (or
 * encode) that one on the CPU; an FFmpeg command that names a VA-API encoder
 * itself stops with that error. The Mac's extra room covers what the shim
 * cannot see: Mesa sends a closed context to the Mac only with the app's next
 * commands (the shim has freed its slot already), and apps that do not use
 * the shim.
 * Counting across processes: a context holds a slot, an OFD lock on one byte
 * of /dev/shm/omacvm-va-slots, so a process that quits or crashes frees its
 * slots. Firefox decodes in a sandbox that can neither open that file nor
 * lock; such a process counts only its own contexts, up to half the limit,
 * and the shared slots are the other half. The VM stays within the limit as
 * long as at most one such process decodes. OMACVM_VA_DEBUG=1 prints the
 * limits.
 *
 * Decoding into an imported surface: Mesa's virgl driver cannot decode into a surface
 * made from the app's memory (vaCreateSurfaces2 with a descriptor): such a surface has no
 * video buffer on the Mac, and Mesa's vaRenderPicture crashes the process (Chrome's GPU
 * process, 2026-10-27: virgl_encode_begin_frame on a NULL buffer). Encoding from such a
 * surface crashes the same way (vaEndPicture: begin_frame on the picture's surface). The
 * shim refuses vaBeginPicture on a decoding or encoding context whose target is such a
 * surface (VA_STATUS_ERROR_INVALID_SURFACE, logged at most every 10 s), and the context's
 * vaRenderPicture and vaEndPicture until its next picture begins in a surface Mesa made:
 * the app decodes (or encodes) that video on the CPU. Video processing into or from
 * imports stays as it is. The shim remembers every import until the app destroys it.
 * OMACVM_VA_IMPORT_GUARD=0 turns this off (tests).
 *
 * Images in another YUV layout: vaGetImage and vaPutImage between an NV12
 * surface and an I420 or YV12 image (or back) are done here on the CPU, a
 * plain reshuffle of the planes, so the picture is bit for bit the decoded
 * one. Mesa does these on the GPU through its video compositor, which goes
 * through RGB and resamples the chroma; on OmacVM it gave empty pictures
 * (FFmpeg's -vf hwdownload,format=yuv420p). Everything else is Mesa's.
 *
 * Built in the VM by install.sh; used through LIBVA_DRIVER_NAME=omacvm.
 * MIT, part of OmacVM.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
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
#include <va/va_vpp.h>

#ifndef MESA_DRIVER
#define MESA_DRIVER "/usr/lib/dri/virtio_gpu_drv_video.so"
#endif

static VAStatus (*mesa_query_surface_attributes)(VADriverContextP, VAConfigID,
                                                 VASurfaceAttrib *, unsigned int *);
static int export_sized(void);
static int chromium(void);
static int host_decodes_async(void);

/* Chromium's hardware decoding up to this many pixels wide and high (see the top);
 * OMACVM_VA_MAX=0: no limit; not set or not a number: none on a runtime that
 * decodes beside its GPU thread, else 1920. */
static int chromium_max(void)
{
    const char *env = getenv("OMACVM_VA_MAX");
    int dflt = host_decodes_async() ? 0 : 1920;
    char *end;
    unsigned long v;

    if (!env || !*env)
        return dflt;
    v = strtoul(env, &end, 10);
    if (*end)
        return dflt;
    return v > INT_MAX ? INT_MAX : (int)v;
}

/* A config's entry point (VAEntrypointVLD: decoding), 0 when Mesa does not say. */
static VAEntrypoint config_entrypoint(VADriverContextP ctx, VAConfigID config)
{
    VAProfile profile;
    VAEntrypoint entrypoint = 0;
    VAConfigAttrib *attribs;
    int n = 0;

    if (!ctx->vtable->vaQueryConfigAttributes)
        return 0;
    attribs = calloc(ctx->max_attributes > 0 ? ctx->max_attributes : 1, sizeof(*attribs));
    if (!attribs || ctx->vtable->vaQueryConfigAttributes(ctx, config, &profile, &entrypoint,
                                                         attribs, &n) != VA_STATUS_SUCCESS)
        entrypoint = 0;
    free(attribs);
    return entrypoint;
}

static VAStatus query_surface_attributes(VADriverContextP ctx, VAConfigID config,
                                         VASurfaceAttrib *attribs, unsigned int *num)
{
    VAStatus st = mesa_query_surface_attributes(ctx, config, attribs, num);
    unsigned int i, n = 0;
    int has_nv12 = 0, max = chromium_max();

    if (st != VA_STATUS_SUCCESS || !attribs)
        return st;
    if (export_sized() && chromium() && max && config_entrypoint(ctx, config) == VAEntrypointVLD)
        for (i = 0; i < *num; i++)
            if ((attribs[i].type == VASurfaceAttribMaxWidth ||
                 attribs[i].type == VASurfaceAttribMaxHeight) &&
                attribs[i].value.type == VAGenericValueTypeInteger &&
                attribs[i].value.value.i > max)
                attribs[i].value.value.i = max;
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

/* ---- Surfaces with their real size (see the top) ---- */

/* Chromium's browser process by name, its GPU and video decoder processes
 * (any Chromium or Electron app) by their --type= switch. */
static int chromium_process(void)
{
    char exe[PATH_MAX], args[4096];
    ssize_t n;
    int fd;

    n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n > 0) {
        exe[n] = 0;
        if (strstr(exe, "chrom") || strstr(exe, "brave") || strstr(exe, "electron"))
            return 1;
    }
    fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;
    n = read(fd, args, sizeof(args) - 1);
    close(fd);
    if (n <= 0)
        return 0;
    args[n] = 0;
    for (char *a = args; a < args + n; a += strlen(a) + 1)
        if (!strncmp(a, "--type=", 7))
            return 1;
    return 0;
}

/* The Mac's runtime says WHAT (a host.env line: "OMACVM_VAEXPORT=1\n"). */
static int host_says(const char *what)
{
    char line[256];
    const char *path = getenv("OMACVM_HOST_ENV");   /* tests */
    FILE *f = fopen(path && *path ? path : "/run/omacvm/host.env", "re");
    int yes = 0;

    if (!f)
        return 0;
    while (!yes && fgets(line, sizeof(line), f))
        yes = !strcmp(line, what);
    fclose(f);
    return yes;
}

/* The Mac's runtime draws VA-API's converted frames (see the top). */
static int host_draws_export(void)
{
    return host_says("OMACVM_VAEXPORT=1\n");
}

/* Decided once, at the driver's start: Chromium loads it before its sandbox
 * closes, and host.env cannot be read after that. */
static int chromium_on = -1;

static int chromium(void)
{
    if (chromium_on < 0)
        chromium_on = chromium_process();
    return chromium_on;
}

static int export_sized(void)
{
    static int on = -1;
    const char *env;

    if (on < 0) {
        int c = chromium();

        env = getenv("OMACVM_VA_EXPORT");
        on = env && *env ? *env == '1' : c && host_draws_export();
    }
    return on;
}

/* ---- Waiting for the picture (see the top) ---- */

/* The Mac's runtime decodes beside its GPU thread (read once, at the driver's start). */
static int host_decodes_async(void)
{
    static int on = -1;

    if (on < 0)
        on = host_says("OMACVM_VADECASYNC=1\n");
    return on;
}

static int decode_wait_on(void)
{
    static int on = -1;
    const char *env;

    if (on < 0) {
        int c = chromium();

        env = getenv("OMACVM_VA_DECODE_WAIT");
        on = env && *env ? *env == '1' : c && host_decodes_async();
    }
    return on;
}

/* Decoding and encoding contexts of this process (the kinds of Mesa's codecs on the Mac):
 * whether their vaEndPicture waits, and whether their picture was refused because its
 * surface is an import (see the top). The table grows: a context it missed would not be
 * guarded. */
enum { DEC, ENC, KINDS };
static pthread_mutex_t dec_lock = PTHREAD_MUTEX_INITIALIZER;
static struct codec_ctx {
    VADriverContextP drv;
    VAContextID id;
    int kind;                   /* DEC or ENC */
    int wait;                   /* vaEndPicture waits for the picture */
    int refused;                /* this picture was refused: no render or end */
} *codecs;
static unsigned ncodecs, codecs_room;

/* 0, or -1 when the table cannot grow */
static int codec_add(VADriverContextP ctx, VAContextID id, int kind, int wait)
{
    int ok = 0;

    pthread_mutex_lock(&dec_lock);
    if (ncodecs == codecs_room) {
        unsigned room = codecs_room ? 2 * codecs_room : 64;
        struct codec_ctx *more = realloc(codecs, room * sizeof(*more));

        if (more) {
            codecs = more;
            codecs_room = room;
        }
    }
    if (ncodecs < codecs_room)
        codecs[ncodecs++] = (struct codec_ctx){ ctx, id, kind, wait, 0 };
    else
        ok = -1;
    pthread_mutex_unlock(&dec_lock);
    return ok;
}

/* ID's record into *OUT (0: not a decoding or encoding context) */
static int codec_get(VADriverContextP ctx, VAContextID id, struct codec_ctx *out)
{
    int found = 0;

    pthread_mutex_lock(&dec_lock);
    for (unsigned i = 0; i < ncodecs && !found; i++)
        if (codecs[i].drv == ctx && codecs[i].id == id) {
            *out = codecs[i];
            found = 1;
        }
    pthread_mutex_unlock(&dec_lock);
    return found;
}

/* A picture of ID begins: refused or not. Its kind, -1 if ID is no such context. */
static int codec_begin(VADriverContextP ctx, VAContextID id, int refused)
{
    int kind = -1;

    pthread_mutex_lock(&dec_lock);
    for (unsigned i = 0; i < ncodecs && kind < 0; i++)
        if (codecs[i].drv == ctx && codecs[i].id == id) {
            codecs[i].refused = refused;
            kind = codecs[i].kind;
        }
    pthread_mutex_unlock(&dec_lock);
    return kind;
}

/* ID's entry gone (ALL: every context of CTX). */
static void codec_forget(VADriverContextP ctx, VAContextID id, int all)
{
    unsigned i = 0;

    pthread_mutex_lock(&dec_lock);
    while (i < ncodecs) {
        if (codecs[i].drv == ctx && (all || codecs[i].id == id)) {
            codecs[i] = codecs[--ncodecs];
            if (!all)
                break;
        } else {
            i++;
        }
    }
    pthread_mutex_unlock(&dec_lock);
}

/* An empty command (one VIRGL_CCMD_NOP) with a fence; waits for the fence. */
static void wait_for_host(VADriverContextP ctx)
{
    struct drm_state *drm = ctx->drm_state;
    uint32_t nop = 0;
    struct drm_virtgpu_execbuffer eb = {
        .flags = VIRTGPU_EXECBUF_FENCE_FD_OUT, .size = sizeof(nop),
        .command = (uintptr_t)&nop, .fence_fd = -1,
    };
    struct pollfd p;

    if (!drm || drm->fd < 0 || ioctl(drm->fd, DRM_IOCTL_VIRTGPU_EXECBUFFER, &eb) ||
        eb.fence_fd < 0)
        return;
    p = (struct pollfd){ .fd = eb.fence_fd, .events = POLLIN };
    while (poll(&p, 1, 100) < 0 && errno == EINTR)
        ;
    close(eb.fence_fd);
}

static VAStatus (*mesa_end_picture)(VADriverContextP, VAContextID);

static VAStatus end_picture(VADriverContextP ctx, VAContextID context)
{
    struct codec_ctx c;
    int known = codec_get(ctx, context, &c);
    VAStatus st;

    if (known && c.refused)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    st = mesa_end_picture(ctx, context);
    if (st == VA_STATUS_SUCCESS && known && c.wait)
        wait_for_host(ctx);
    return st;
}

/* ---- Surfaces: one record each ---- */

/* What the shim knows of each surface of this process: made from the app's memory (an import:
 * Mesa cannot decode into it), Mesa's layout (asked once, by an export) and, for Chromium's RGB
 * frames (see the top), whether a 4:2:0 surface has planes rounded up to 16 or an RGB import
 * was made at the rounded size. An ID that comes back is a new surface. The table grows and
 * forgets a surface only when the app destroys it: a forgotten import would be decoded into. */
enum { SURF_IMPORTED = 1, SURF_ROUNDED420 = 2, SURF_BUMPED = 4 };
static pthread_mutex_t surf_lock = PTHREAD_MUTEX_INITIALIZER;
static struct surf {
    VADriverContextP drv;
    VASurfaceID id;
    uint32_t flags;
    uint32_t fourcc;            /* Mesa's layout (0: not asked yet) */
    uint32_t width, height;     /* the size the app asked for (SURF_BUMPED: not Mesa's) */
} *surfs;
static unsigned nsurfs, surfs_room;

/* called with surf_lock held */
static struct surf *surf_find(VADriverContextP ctx, VASurfaceID id)
{
    for (unsigned i = 0; i < nsurfs; i++)
        if (surfs[i].drv == ctx && surfs[i].id == id)
            return &surfs[i];
    return NULL;
}

/* 0, or -1 when the table cannot grow (then none of the N is recorded) */
static int surf_add(VADriverContextP ctx, const VASurfaceID *ids, unsigned n, uint32_t w,
                    uint32_t h, uint32_t flags)
{
    int ok = 0;

    pthread_mutex_lock(&surf_lock);
    if (n > surfs_room - nsurfs) {
        unsigned room = surfs_room ? surfs_room : 256;
        struct surf *more;

        while (room - nsurfs < n && room < UINT_MAX / 2)
            room *= 2;
        more = room - nsurfs >= n ? realloc(surfs, (size_t)room * sizeof(*more)) : NULL;
        if (more) {
            surfs = more;
            surfs_room = room;
        } else {
            ok = -1;
        }
    }
    for (unsigned i = 0; !ok && i < n; i++) {
        struct surf *s = surf_find(ctx, ids[i]);

        if (!s)
            s = &surfs[nsurfs++];
        *s = (struct surf){ ctx, ids[i], flags, 0, w, h };
    }
    pthread_mutex_unlock(&surf_lock);
    return ok;
}

/* SURFACE's record into *OUT (0: none) */
static int surf_get(VADriverContextP ctx, VASurfaceID id, struct surf *out)
{
    struct surf *s;

    pthread_mutex_lock(&surf_lock);
    s = surf_find(ctx, id);
    if (s)
        *out = *s;
    pthread_mutex_unlock(&surf_lock);
    return s != NULL;
}

/* N IDs gone (N < 0: every surface of a display that closes). */
static void surf_forget(VADriverContextP ctx, const VASurfaceID *ids, int n)
{
    unsigned i = 0;

    pthread_mutex_lock(&surf_lock);
    while (i < nsurfs) {
        int hit = n < 0;

        for (int k = 0; k < n && !hit; k++)
            hit = surfs[i].id == ids[k];
        if (hit && surfs[i].drv == ctx) {
            surfs[i] = surfs[--nsurfs];
        } else {
            i++;
        }
    }
    pthread_mutex_unlock(&surf_lock);
}

static VAStatus (*mesa_create_surfaces2)(VADriverContextP, unsigned int, unsigned int,
                                         unsigned int, VASurfaceID *, unsigned int,
                                         VASurfaceAttrib *, unsigned int);
static VAStatus (*mesa_destroy_surfaces)(VADriverContextP, VASurfaceID *, int);

/* New surfaces into the table. An import that cannot be recorded is not handed out: it
 * would not be guarded. */
static VAStatus surf_record(VADriverContextP ctx, VASurfaceID *ids, unsigned n, uint32_t w,
                            uint32_t h, uint32_t flags)
{
    if (!surf_add(ctx, ids, n, w, h, flags) || !(flags & SURF_IMPORTED))
        return VA_STATUS_SUCCESS;
    if (mesa_destroy_surfaces)
        mesa_destroy_surfaces(ctx, ids, (int)n);
    return VA_STATUS_ERROR_ALLOCATION_FAILED;
}

static int import_rounded(VADriverContextP ctx, unsigned int format, unsigned int width,
                          unsigned int height, VASurfaceID *surfaces, VASurfaceAttrib *attribs,
                          unsigned int num_attribs, VAStatus *st);
static int fill_on(void);
static int import420_rounded(unsigned int width, unsigned int height, VASurfaceAttrib *attribs,
                             unsigned int num_attribs);

/* A new surface that Mesa allocates (no buffer of the app's, no memory type
 * of its own) gets the export hint added. */
static VAStatus create_surfaces_plain(VADriverContextP ctx, unsigned int format,
                                      unsigned int width, unsigned int height,
                                      VASurfaceID *surfaces, unsigned int num_surfaces,
                                      VASurfaceAttrib *attribs, unsigned int num_attribs);

static VAStatus create_surfaces2(VADriverContextP ctx, unsigned int format, unsigned int width,
                                 unsigned int height, VASurfaceID *surfaces,
                                 unsigned int num_surfaces, VASurfaceAttrib *attribs,
                                 unsigned int num_attribs)
{
    unsigned int i;
    uint32_t flags = 0;
    VAStatus st;

    if (num_surfaces == 1 && fill_on() &&
        import_rounded(ctx, format, width, height, surfaces, attribs, num_attribs, &st))
        return st;
    for (i = 0; attribs && i < num_attribs; i++)
        if (attribs[i].type == VASurfaceAttribExternalBufferDescriptor)
            flags = SURF_IMPORTED;
    st = create_surfaces_plain(ctx, format, width, height, surfaces, num_surfaces, attribs,
                               num_attribs);
    if (st != VA_STATUS_SUCCESS)
        return st;
    /* 4:2:0 surfaces with planes rounded up to 16 (see render_picture): Mesa's
     * own, and imports whose buffer is laid out that way (Chrome's decoder
     * imports its own GBM buffers) */
    if (fill_on() && (format & (VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10)) &&
        (!flags || (num_surfaces == 1 && import420_rounded(width, height, attribs, num_attribs))))
        flags |= SURF_ROUNDED420;
    return surf_record(ctx, surfaces, num_surfaces, width, height, flags);
}

/* Mesa's vaCreateSurfaces2, exportable at their real size where export_sized() says so. */
static VAStatus create_surfaces_plain(VADriverContextP ctx, unsigned int format,
                                      unsigned int width, unsigned int height,
                                      VASurfaceID *surfaces, unsigned int num_surfaces,
                                      VASurfaceAttrib *attribs, unsigned int num_attribs)
{
    VASurfaceAttrib list[32];
    unsigned int i;
    int plain = export_sized() && num_attribs < sizeof(list) / sizeof(list[0]) &&
                (attribs || !num_attribs);

    for (i = 0; plain && i < num_attribs; i++) {
        if (!(attribs[i].flags & VA_SURFACE_ATTRIB_SETTABLE))
            continue;
        if ((attribs[i].type == VASurfaceAttribMemoryType &&
             attribs[i].value.value.i != VA_SURFACE_ATTRIB_MEM_TYPE_VA) ||
            attribs[i].type == VASurfaceAttribExternalBufferDescriptor)
            plain = 0;
    }
    if (!plain)
        return mesa_create_surfaces2(ctx, format, width, height, surfaces, num_surfaces,
                                     attribs, num_attribs);
    if (num_attribs)
        memcpy(list, attribs, num_attribs * sizeof(*attribs));
    list[num_attribs] = (VASurfaceAttrib){
        .type = VASurfaceAttribMemoryType,
        .flags = VA_SURFACE_ATTRIB_SETTABLE,
        .value = { .type = VAGenericValueTypeInteger,
                   .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 },
    };
    return mesa_create_surfaces2(ctx, format, width, height, surfaces, num_surfaces, list,
                                 num_attribs + 1);
}

/* ---- Images in another YUV layout (see the top) ---- */

static VAStatus (*mesa_get_image)(VADriverContextP, VASurfaceID, int, int,
                                  unsigned int, unsigned int, VAImageID);
static VAStatus (*mesa_put_image)(VADriverContextP, VASurfaceID, VAImageID, int, int,
                                  unsigned int, unsigned int, int, int,
                                  unsigned int, unsigned int);
static int is_420(uint32_t fourcc)
{
    return fourcc == VA_FOURCC_NV12 || fourcc == VA_FOURCC_I420 || fourcc == VA_FOURCC_YV12;
}

/* A surface's layout as Mesa made it (0: not known), from Mesa's export the first time,
 * kept in its record. */
static uint32_t surface_fourcc(VADriverContextP ctx, VASurfaceID surface)
{
    VADRMPRIMESurfaceDescriptor desc;
    struct surf rec, *s;

    if (surf_get(ctx, surface, &rec) && rec.fourcc)
        return rec.fourcc;
    if (!ctx->vtable->vaExportSurfaceHandle)
        return 0;
    memset(&desc, 0, sizeof(desc));
    if (ctx->vtable->vaExportSurfaceHandle(ctx, surface, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                           VA_EXPORT_SURFACE_READ_ONLY |
                                           VA_EXPORT_SURFACE_SEPARATE_LAYERS,
                                           &desc) != VA_STATUS_SUCCESS)
        return 0;
    for (unsigned i = 0; i < desc.num_objects && i < 4; i++)
        close(desc.objects[i].fd);
    pthread_mutex_lock(&surf_lock);
    if ((s = surf_find(ctx, surface)))
        s->fourcc = desc.fourcc;
    pthread_mutex_unlock(&surf_lock);
    return desc.fourcc;
}

static VAStatus destroy_surfaces(VADriverContextP ctx, VASurfaceID *list, int n)
{
    surf_forget(ctx, list, n);
    return mesa_destroy_surfaces(ctx, list, n);
}

/* ---- Chromium's RGB frames fill their planes (see the top) ---- */

/* The fill relies on how Mesa rounds the planes and reads the source region,
 * checked up to this Mesa (major * 100 + minor); a newer one has the fill off
 * until it is checked again (OMACVM_VA_FILL=1 turns it on). */
#define FILL_MESA_MAX 2602
static int fill_mesa_ok = -1;

/* Mesa's vendor string, "Mesa Gallium driver 26.2.5 for virgl ..." (shim_init) */
static void fill_mesa_check(const char *vendor)
{
    int major = 0, minor = 0;

    if (fill_mesa_ok >= 0)
        return;
    fill_mesa_ok = vendor && sscanf(vendor, "Mesa Gallium driver %d.%d", &major, &minor) == 2 &&
                   major * 100 + minor <= FILL_MESA_MAX;
    if (!fill_mesa_ok && chromium())
        fprintf(stderr, "omacvm_drv_video: %s: not checked with this Mesa, call tiles not "
                "filled (OMACVM_VA_FILL=1 turns it on)\n", vendor ? vendor : "no vendor string");
}

static int fill_on(void)
{
    static int on = -1;
    const char *env;

    if (on < 0) {
        env = getenv("OMACVM_VA_FILL");
        on = env && *env ? *env == '1' : chromium() && fill_mesa_ok == 1;
    }
    return on;
}

static int is_rgb(uint32_t fourcc)
{
    return fourcc == VA_FOURCC_ARGB || fourcc == VA_FOURCC_ABGR || fourcc == VA_FOURCC_XRGB ||
           fourcc == VA_FOURCC_XBGR || fourcc == VA_FOURCC_RGBA || fourcc == VA_FOURCC_BGRA ||
           fourcc == VA_FOURCC_RGBX || fourcc == VA_FOURCC_BGRX;
}

/* The surface each context renders into (vaBeginPicture). */
static pthread_mutex_t tgt_lock = PTHREAD_MUTEX_INITIALIZER;
static struct tgt {
    VADriverContextP drv;
    VAContextID context;
    VASurfaceID target;
} tgts[64];
static unsigned ntgts;

static void target_set(VADriverContextP ctx, VAContextID context, VASurfaceID target)
{
    unsigned i;

    pthread_mutex_lock(&tgt_lock);
    for (i = 0; i < ntgts; i++)
        if (tgts[i].drv == ctx && tgts[i].context == context)
            break;
    if (i < ntgts || ntgts < sizeof(tgts) / sizeof(tgts[0])) {
        tgts[i] = (struct tgt){ ctx, context, target };
        if (i == ntgts)
            ntgts++;
    }
    pthread_mutex_unlock(&tgt_lock);
}

static VASurfaceID target_of(VADriverContextP ctx, VAContextID context)
{
    VASurfaceID target = VA_INVALID_SURFACE;

    pthread_mutex_lock(&tgt_lock);
    for (unsigned i = 0; i < ntgts; i++)
        if (tgts[i].drv == ctx && tgts[i].context == context)
            target = tgts[i].target;
    pthread_mutex_unlock(&tgt_lock);
    return target;
}

/* A context gone (ALL: every context of CTX). */
static void target_forget(VADriverContextP ctx, VAContextID context, int all)
{
    unsigned i = 0;

    pthread_mutex_lock(&tgt_lock);
    while (i < ntgts) {
        if (tgts[i].drv == ctx && (all || tgts[i].context == context))
            tgts[i] = tgts[--ntgts];
        else
            i++;
    }
    pthread_mutex_unlock(&tgt_lock);
}

/* A surface with flag WHAT in its record: its size as the app gave it. */
static int surf_size(VADriverContextP ctx, VASurfaceID id, uint32_t what, uint32_t *w,
                     uint32_t *h)
{
    struct surf s;

    if (!surf_get(ctx, id, &s) || !(s.flags & what))
        return 0;
    *w = s.width;
    *h = s.height;
    return 1;
}

/* A 4:2:0 import of WIDTH x HEIGHT (height not a multiple of 16): is its Y plane
 * rounded up to 16 rows (Mesa's GBM buffers), by the chroma plane's offset or, in
 * a buffer of its own, the Y buffer's size? An exact-size picture (a camera
 * frame) is not. */
static int import420_rounded(unsigned int width, unsigned int height, VASurfaceAttrib *attribs,
                             unsigned int num_attribs)
{
    uint64_t ah = (height + 15) & ~15u, rows = 0, pitch = 0;
    int mem = -1, k = -1;
    void *p;

    if (!(height & 15) || !width || !height || height > 16384 || !attribs)
        return 0;
    for (unsigned int i = 0; i < num_attribs; i++) {
        if (attribs[i].type == VASurfaceAttribMemoryType)
            mem = attribs[i].value.value.i;
        else if (attribs[i].type == VASurfaceAttribExternalBufferDescriptor)
            k = (int)i;
    }
    if (k < 0 || !(p = attribs[k].value.value.p))
        return 0;
    if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2) {
        const VADRMPRIMESurfaceDescriptor *d = p;
        uint32_t y_obj, c_obj, y_off, c_off;

        if (d->num_layers == 1 && d->layers[0].num_planes >= 2) {
            y_obj = d->layers[0].object_index[0];
            c_obj = d->layers[0].object_index[1];
            y_off = d->layers[0].offset[0];
            c_off = d->layers[0].offset[1];
            pitch = d->layers[0].pitch[0];
        } else if (d->num_layers >= 2 && d->layers[0].num_planes == 1) {
            y_obj = d->layers[0].object_index[0];
            c_obj = d->layers[1].object_index[0];
            y_off = d->layers[0].offset[0];
            c_off = d->layers[1].offset[0];
            pitch = d->layers[0].pitch[0];
        } else {
            return 0;
        }
        if (!pitch || y_obj >= d->num_objects || c_obj >= d->num_objects || y_obj >= 4)
            return 0;
        if (y_obj == c_obj && c_off > y_off) {
            rows = (c_off - y_off) / pitch;
        } else if (y_obj != c_obj) {
            off_t size = lseek(d->objects[y_obj].fd, 0, SEEK_END);

            lseek(d->objects[y_obj].fd, 0, SEEK_SET);
            if (size > (off_t)y_off)
                rows = ((uint64_t)size - y_off) / pitch;
        }
    } else if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME) {
        const VASurfaceAttribExternalBuffers *e = p;

        if (e->num_planes < 2 || !e->pitches[0] || e->offsets[1] <= e->offsets[0])
            return 0;
        pitch = e->pitches[0];
        rows = (e->offsets[1] - e->offsets[0]) / pitch;
    }
    if (getenv("OMACVM_VA_DEBUG"))
        fprintf(stderr, "omacvm_drv_video: 4:2:0 import %ux%u, Y plane %llu rows: %s\n", width,
                height, (unsigned long long)rows, rows >= ah ? "rounded" : "its own size");
    return rows >= ah;
}

/* Does the dma-buf FD hold OFFSET + PITCH x ROWS bytes? */
static int buffer_holds(int fd, uint64_t offset, uint64_t pitch, uint64_t rows)
{
    off_t size = lseek(fd, 0, SEEK_END);

    lseek(fd, 0, SEEK_SET);
    return size > 0 && offset + pitch * rows <= (uint64_t)size;
}

/* An RGB import of WIDTH x HEIGHT (not a multiple of 16) whose buffer holds the rounded
 * planes: made at the rounded size (1 = done, *ST Mesa's answer; 0 = not such an import). */
static int import_rounded(VADriverContextP ctx, unsigned int format, unsigned int width,
                          unsigned int height, VASurfaceID *surfaces, VASurfaceAttrib *attribs,
                          unsigned int num_attribs, VAStatus *st)
{
    VASurfaceAttrib list[32];
    VADRMPRIMESurfaceDescriptor d2;
    VASurfaceAttribExternalBuffers e2;
    unsigned int aw = (width + 15) & ~15u, ah = (height + 15) & ~15u, i;
    int mem = -1, k = -1;
    void *p;

    if (!(format & VA_RT_FORMAT_RGB32) || !((width | height) & 15) || !width || !height ||
        width > 16384 || height > 16384 || !attribs || num_attribs > 32)
        return 0;
    for (i = 0; i < num_attribs; i++) {
        if (attribs[i].type == VASurfaceAttribMemoryType)
            mem = attribs[i].value.value.i;
        else if (attribs[i].type == VASurfaceAttribExternalBufferDescriptor)
            k = (int)i;
    }
    if (k < 0 || !(p = attribs[k].value.value.p))
        return 0;
    memcpy(list, attribs, num_attribs * sizeof(*attribs));
    if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2) {
        const VADRMPRIMESurfaceDescriptor *d = p;
        uint32_t obj = d->layers[0].object_index[0];

        if (!is_rgb(d->fourcc) || d->width != width || d->height != height ||
            d->num_layers != 1 || d->layers[0].num_planes != 1 || !d->num_objects ||
            d->num_objects > 4 || obj >= d->num_objects || d->layers[0].pitch[0] < aw * 4 ||
            !buffer_holds(d->objects[obj].fd, d->layers[0].offset[0], d->layers[0].pitch[0], ah))
            return 0;
        d2 = *d;
        d2.width = aw;
        d2.height = ah;
        list[k].value.value.p = &d2;
    } else if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME) {
        const VASurfaceAttribExternalBuffers *e = p;

        if (!is_rgb(e->pixel_format) || e->width != width || e->height != height ||
            e->num_planes != 1 || !e->num_buffers || !e->buffers || e->pitches[0] < aw * 4 ||
            !buffer_holds((int)e->buffers[0], e->offsets[0], e->pitches[0], ah))
            return 0;
        e2 = *e;
        e2.width = aw;
        e2.height = ah;
        list[k].value.value.p = &e2;
    } else {
        return 0;
    }
    *st = mesa_create_surfaces2(ctx, format, aw, ah, surfaces, 1, list, num_attribs);
    if (*st != VA_STATUS_SUCCESS) {
        *st = mesa_create_surfaces2(ctx, format, width, height, surfaces, 1, attribs, num_attribs);
        if (*st == VA_STATUS_SUCCESS)
            *st = surf_record(ctx, surfaces, 1, width, height, SURF_IMPORTED);
        return 1;
    }
    *st = surf_record(ctx, surfaces, 1, width, height, SURF_IMPORTED | SURF_BUMPED);
    return 1;
}

static VAStatus (*mesa_begin_picture)(VADriverContextP, VAContextID, VASurfaceID);
static VAStatus (*mesa_render_picture)(VADriverContextP, VAContextID, VABufferID *, int);

/* Decoding into an imported surface (see the top). */
static int import_guard_on(void)
{
    static int on = -1;
    const char *env;

    if (on < 0) {
        env = getenv("OMACVM_VA_IMPORT_GUARD");
        on = !(env && *env == '0');
    }
    return on;
}

/* A refusal goes to stderr: the first at once, then at most every 10 s with how many
 * there were since. */
static void say_import_refused(int kind)
{
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static struct timespec last;
    static unsigned since;
    struct timespec now;

    clock_gettime(CLOCK_MONOTONIC, &now);
    pthread_mutex_lock(&lock);
    if (last.tv_sec && now.tv_sec - last.tv_sec < 10) {
        since++;
    } else {
        fprintf(stderr, "omacvm_drv_video: refused %s a surface made from the app's memory "
                "(Mesa's virgl driver would crash there); the app %s that video on the CPU",
                kind == ENC ? "encoding from" : "decoding into",
                kind == ENC ? "encodes" : "decodes");
        if (since)
            fprintf(stderr, " (%u more refused in the last %ld s)", since,
                    (long)(now.tv_sec - last.tv_sec));
        fputc('\n', stderr);
        last = now;
        since = 0;
    }
    pthread_mutex_unlock(&lock);
}

static int fill_hooked;         /* render_picture's fill is on (shim_init) */

/* A decoding or encoding context whose picture's surface is an import: refused, and its
 * vaRenderPicture and vaEndPicture with it (see the top). */
static VAStatus begin_picture(VADriverContextP ctx, VAContextID context, VASurfaceID target)
{
    struct surf s;
    int imported = import_guard_on() && surf_get(ctx, target, &s) && (s.flags & SURF_IMPORTED);
    int kind = codec_begin(ctx, context, imported);
    VAStatus st;

    if (imported && kind >= 0) {
        say_import_refused(kind);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    st = mesa_begin_picture(ctx, context, target);
    if (st == VA_STATUS_SUCCESS && fill_hooked)
        target_set(ctx, context, target);
    return st;
}

/* One rectangle of an app's video processing, rewritten for Mesa (see the top):
 * the app's size W x H, its planes rounded up to 16. */
static void region_scaled(const VARectangle *r, uint32_t w, uint32_t h, VARectangle *out)
{
    uint32_t aw = (w + 15) & ~15u, ah = (h + 15) & ~15u;
    VARectangle in = r ? *r : (VARectangle){ .x = 0, .y = 0, .width = (uint16_t)w, .height = (uint16_t)h };

    /* Mesa takes a source region in parts of the surface's own size but samples the
     * rounded planes: the picture's part of them is W/AW x H/AH */
    out->x = (int16_t)(((int64_t)in.x * w + aw / 2) / aw);
    out->y = (int16_t)(((int64_t)in.y * h + ah / 2) / ah);
    out->width = (uint16_t)(((uint64_t)in.width * w + aw / 2) / aw);
    out->height = (uint16_t)(((uint64_t)in.height * h + ah / 2) / ah);
}

/* Video processing (Chromium) from or into a surface whose size is not a multiple
 * of 16: the source region is scaled to the picture's part of the rounded planes,
 * and a whole RGB destination becomes its rounded planes' size, so Chrome's
 * sampling of the whole destination puts every row where it belongs. The app's
 * buffer gets its own regions back afterwards. */
static VAStatus render_picture(VADriverContextP ctx, VAContextID context, VABufferID *buffers,
                               int num)
{
    struct {
        VAProcPipelineParameterBuffer *pp;
        const VARectangle *out, *src;
        VABufferID id;
        VARectangle src_rect;
    } m[8];
    VARectangle full;
    VASurfaceID target;
    uint32_t w = 0, h = 0, fourcc = 0;
    int i, n = 0, fill = 0;
    VAStatus st;

    target = target_of(ctx, context);
    /* only an import made at the rounded size (its planes are there for the
     * conversion to fill); the app asks for its own size. The table first: an
     * export per decoding target is not needed. */
    if (target != VA_INVALID_SURFACE && ctx->vtable->vaBufferInfo &&
        surf_size(ctx, target, SURF_BUMPED, &w, &h)) {
        fourcc = surface_fourcc(ctx, target);
        fill = is_rgb(fourcc) && w && h && w <= 16384 && h <= 16384 && ((w | h) & 15);
    }
    full = (VARectangle){ .x = 0, .y = 0, .width = (uint16_t)((w + 15) & ~15u),
                          .height = (uint16_t)((h + 15) & ~15u) };
    for (i = 0; target != VA_INVALID_SURFACE && ctx->vtable->vaBufferInfo && i < num && n < 8; i++) {
        VABufferType type;
        unsigned int size = 0, count = 0;
        void *data = NULL;
        VAProcPipelineParameterBuffer *pp;
        uint32_t sw = 0, sh = 0;
        int src_fix, out_fix;

        if (ctx->vtable->vaBufferInfo(ctx, buffers[i], &type, &size, &count) !=
                VA_STATUS_SUCCESS || type != VAProcPipelineParameterBufferType ||
            size < sizeof(*pp))
            continue;
        if (ctx->vtable->vaMapBuffer(ctx, buffers[i], &data) != VA_STATUS_SUCCESS || !data)
            continue;
        pp = data;
        /* only 4:2:0 surfaces with rounded planes: an exact-size import keeps its region */
        src_fix = surf_size(ctx, pp->surface, SURF_ROUNDED420, &sw, &sh) && sw && sh &&
                  sw <= 16384 && sh <= 16384 && ((sw | sh) & 15);
        out_fix = fill && (!pp->output_region ||
                           (!pp->output_region->x && !pp->output_region->y &&
                            pp->output_region->width == w && pp->output_region->height == h));
        if (!src_fix && !out_fix) {
            ctx->vtable->vaUnmapBuffer(ctx, buffers[i]);
            continue;
        }
        m[n].pp = pp;
        m[n].out = pp->output_region;
        m[n].src = pp->surface_region;
        m[n].id = buffers[i];
        if (src_fix) {
            region_scaled(pp->surface_region, sw, sh, &m[n].src_rect);
            pp->surface_region = &m[n].src_rect;
        }
        if (out_fix)
            pp->output_region = &full;
        n++;
    }
    st = mesa_render_picture(ctx, context, buffers, num);
    for (i = 0; i < n; i++) {
        m[i].pp->output_region = m[i].out;
        m[i].pp->surface_region = m[i].src;
        ctx->vtable->vaUnmapBuffer(ctx, m[i].id);
    }
    return st;
}

/* Every vaRenderPicture: none for a refused picture (see the top), the fill where it is on. */
static VAStatus render_checked(VADriverContextP ctx, VAContextID context, VABufferID *buffers,
                               int num)
{
    struct codec_ctx c;

    if (codec_get(ctx, context, &c) && c.refused)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    return fill_hooked ? render_picture(ctx, context, buffers, num) :
                         mesa_render_picture(ctx, context, buffers, num);
}

/* Where an image's planes are: Y, and U and V with their step (2 in NV12). */
struct planes {
    uint8_t *y, *u, *v;
    unsigned ypitch, cpitch, step;
};

static int planes_of(const VAImage *img, uint8_t *base, struct planes *p)
{
    p->y = base + img->offsets[0];
    p->ypitch = img->pitches[0];
    p->cpitch = img->pitches[1];
    switch (img->format.fourcc) {
    case VA_FOURCC_NV12:
        p->u = base + img->offsets[1];
        p->v = p->u + 1;
        p->step = 2;
        return 1;
    case VA_FOURCC_I420:
        p->u = base + img->offsets[1];
        p->v = base + img->offsets[2];
        break;
    case VA_FOURCC_YV12:
        p->v = base + img->offsets[1];
        p->u = base + img->offsets[2];
        break;
    default:
        return 0;
    }
    p->step = 1;
    /* Both chroma planes share a pitch in Mesa's images; refuse otherwise. */
    return img->pitches[2] == img->pitches[1];
}

static void copy_420(const struct planes *s, const struct planes *d, unsigned w, unsigned h)
{
    unsigned x, r, cw = (w + 1) / 2, ch = (h + 1) / 2;

    for (r = 0; r < h; r++)
        memcpy(d->y + r * d->ypitch, s->y + r * s->ypitch, w);
    for (r = 0; r < ch; r++) {
        const uint8_t *su = s->u + r * s->cpitch, *sv = s->v + r * s->cpitch;
        uint8_t *du = d->u + r * d->cpitch, *dv = d->v + r * d->cpitch;

        for (x = 0; x < cw; x++) {
            du[x * d->step] = su[x * s->step];
            dv[x * d->step] = sv[x * s->step];
        }
    }
}

/* Copies w x h from image `from` to image `to` (other 4:2:0 layout) at 0,0. */
static VAStatus convert_image(VADriverContextP ctx, const VAImage *from, const VAImage *to,
                              unsigned w, unsigned h)
{
    void *src = NULL, *dst = NULL;
    struct planes sp, dp;
    VAStatus st;

    if (w > from->width || h > from->height || w > to->width || h > to->height)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    st = ctx->vtable->vaMapBuffer(ctx, from->buf, &src);
    if (st != VA_STATUS_SUCCESS)
        return st;
    st = ctx->vtable->vaMapBuffer(ctx, to->buf, &dst);
    if (st == VA_STATUS_SUCCESS) {
        if (planes_of(from, src, &sp) && planes_of(to, dst, &dp))
            copy_420(&sp, &dp, w, h);
        else
            st = VA_STATUS_ERROR_OPERATION_FAILED;
        ctx->vtable->vaUnmapBuffer(ctx, to->buf);
    }
    ctx->vtable->vaUnmapBuffer(ctx, from->buf);
    return st;
}

/* The app's 4:2:0 images by ID (vaGetImage and vaPutImage name only the ID):
 * recorded at vaCreateImage, dropped at vaDestroyImage. */
static VAStatus (*mesa_create_image)(VADriverContextP, VAImageFormat *, int, int, VAImage *);
static VAStatus (*mesa_destroy_image)(VADriverContextP, VAImageID);
static pthread_mutex_t img_lock = PTHREAD_MUTEX_INITIALIZER;
static struct img {
    VADriverContextP drv;
    VAImage image;
} imgs[256];
static unsigned nimgs;

static VAStatus create_image(VADriverContextP ctx, VAImageFormat *format, int width,
                             int height, VAImage *image)
{
    VAStatus st = mesa_create_image(ctx, format, width, height, image);

    if (st == VA_STATUS_SUCCESS && is_420(image->format.fourcc)) {
        pthread_mutex_lock(&img_lock);
        if (nimgs < sizeof(imgs) / sizeof(imgs[0]))
            imgs[nimgs++] = (struct img){ ctx, *image };
        pthread_mutex_unlock(&img_lock);
    }
    return st;
}

static void forget_image(VADriverContextP ctx, VAImageID id, int all)
{
    unsigned i = 0;

    pthread_mutex_lock(&img_lock);
    while (i < nimgs) {
        if (imgs[i].drv == ctx && (all || imgs[i].image.image_id == id))
            imgs[i] = imgs[--nimgs];
        else
            i++;
    }
    pthread_mutex_unlock(&img_lock);
}

static VAStatus destroy_image(VADriverContextP ctx, VAImageID id)
{
    forget_image(ctx, id, 0);
    return mesa_destroy_image(ctx, id);
}

static int find_image(VADriverContextP ctx, VAImageID id, VAImage *out)
{
    unsigned i;
    int found = 0;

    pthread_mutex_lock(&img_lock);
    for (i = 0; i < nimgs && !found; i++)
        if (imgs[i].drv == ctx && imgs[i].image.image_id == id) {
            *out = imgs[i].image;
            found = 1;
        }
    pthread_mutex_unlock(&img_lock);
    return found;
}

/* A temporary image in the surface's own layout. Not recorded: the shim's
 * own wrappers never see it. */
static VAStatus temp_image(VADriverContextP ctx, uint32_t fourcc, int w, int h, VAImage *img)
{
    VAImageFormat f = { .fourcc = fourcc, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12 };

    return mesa_create_image(ctx, &f, w, h, img);
}

/* The surface's layout when it and the image are different 4:2:0 layouts
 * (the case done here), else 0 (Mesa's own path). */
static uint32_t other_layout(VADriverContextP ctx, VASurfaceID surface, VAImageID id,
                             VAImage *image)
{
    uint32_t s;

    if (!find_image(ctx, id, image))
        return 0;
    s = surface_fourcc(ctx, surface);
    return is_420(s) && s != image->format.fourcc ? s : 0;
}

static VAStatus get_image(VADriverContextP ctx, VASurfaceID surface, int x, int y,
                          unsigned int width, unsigned int height, VAImageID id)
{
    VAImage image, tmp;
    uint32_t s = other_layout(ctx, surface, id, &image);
    VAStatus st;

    if (!s)
        return mesa_get_image(ctx, surface, x, y, width, height, id);
    st = temp_image(ctx, s, image.width, image.height, &tmp);
    if (st != VA_STATUS_SUCCESS)
        return st;
    st = mesa_get_image(ctx, surface, x, y, width, height, tmp.image_id);
    if (st == VA_STATUS_SUCCESS)
        st = convert_image(ctx, &tmp, &image, width, height);
    mesa_destroy_image(ctx, tmp.image_id);
    return st;
}

/* Only a 1:1 copy is done here; a scaled put stays Mesa's. */
static VAStatus put_image(VADriverContextP ctx, VASurfaceID surface, VAImageID id,
                          int src_x, int src_y, unsigned int src_w, unsigned int src_h,
                          int dst_x, int dst_y, unsigned int dst_w, unsigned int dst_h)
{
    VAImage image, tmp;
    uint32_t s = src_x == 0 && src_y == 0 && src_w == dst_w && src_h == dst_h ?
                 other_layout(ctx, surface, id, &image) : 0;
    VAStatus st;

    if (!s)
        return mesa_put_image(ctx, surface, id, src_x, src_y, src_w, src_h,
                              dst_x, dst_y, dst_w, dst_h);
    st = temp_image(ctx, s, image.width, image.height, &tmp);
    if (st != VA_STATUS_SUCCESS)
        return st;
    st = convert_image(ctx, &image, &tmp, src_w, src_h);
    if (st == VA_STATUS_SUCCESS)
        st = mesa_put_image(ctx, surface, tmp.image_id, 0, 0, src_w, src_h,
                            dst_x, dst_y, dst_w, dst_h);
    mesa_destroy_image(ctx, tmp.image_id);
    return st;
}

/* ---- Limits (see the top) ---- */

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
    VAEntrypoint entrypoint = config_entrypoint(ctx, config);

    return entrypoint == VAEntrypointVLD ? DEC :
           entrypoint == VAEntrypointEncSlice || entrypoint == VAEntrypointEncSliceLP ||
           entrypoint == VAEntrypointEncPicture ? ENC : -1;
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

static VAStatus create_context_limited(VADriverContextP ctx, VAConfigID config, int width,
                                       int height, int flag, VASurfaceID *targets,
                                       int num_targets, VAContextID *context)
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

static VAStatus destroy_context(VADriverContextP ctx, VAContextID context);

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int width, int height,
                               int flag, VASurfaceID *targets, int num_targets,
                               VAContextID *context)
{
    VAStatus st = create_context_limited(ctx, config, width, height, flag, targets,
                                         num_targets, context);
    int k;

    if (st != VA_STATUS_SUCCESS || (k = config_kind(ctx, config)) < 0)
        return st;
    /* a decoder or encoder the shim cannot record would not be guarded: none */
    if (codec_add(ctx, *context, k, k == DEC && decode_wait_on()) < 0) {
        destroy_context(ctx, *context);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
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
    codec_forget(ctx, context, 0);
    target_forget(ctx, context, 0);
    return mesa_destroy_context(ctx, context);
}

/* A display closed with contexts still open frees their slots too. */
static VAStatus terminate(VADriverContextP ctx)
{
    release(ctx, 0, 1);
    codec_forget(ctx, 0, 1);
    target_forget(ctx, 0, 1);
    surf_forget(ctx, NULL, -1);
    forget_image(ctx, 0, 1);
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
    if (st == VA_STATUS_SUCCESS)
        fill_mesa_check(ctx->str_vendor);
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaQuerySurfaceAttributes) {
        mesa_query_surface_attributes = ctx->vtable->vaQuerySurfaceAttributes;
        ctx->vtable->vaQuerySurfaceAttributes = query_surface_attributes;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaQueryConfigProfiles) {
        mesa_query_config_profiles = ctx->vtable->vaQueryConfigProfiles;
        ctx->vtable->vaQueryConfigProfiles = query_config_profiles;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaCreateSurfaces2) {
        export_sized();
        host_decodes_async();
        mesa_create_surfaces2 = ctx->vtable->vaCreateSurfaces2;
        ctx->vtable->vaCreateSurfaces2 = create_surfaces2;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaCreateContext &&
        ctx->vtable->vaDestroyContext && ctx->vtable->vaTerminate) {
        mesa_create_context = ctx->vtable->vaCreateContext;
        mesa_destroy_context = ctx->vtable->vaDestroyContext;
        mesa_terminate = ctx->vtable->vaTerminate;
        ctx->vtable->vaCreateContext = create_context;
        ctx->vtable->vaDestroyContext = destroy_context;
        ctx->vtable->vaTerminate = terminate;
        /* read now: Chromium's sandbox closes later */
        if (ctx->vtable->vaEndPicture && (decode_wait_on() || import_guard_on())) {
            mesa_end_picture = ctx->vtable->vaEndPicture;
            ctx->vtable->vaEndPicture = end_picture;
        }
        pthread_mutex_lock(&lim_lock);
        if (!lim_read)
            read_limits(ctx);
        pthread_mutex_unlock(&lim_lock);
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaDestroySurfaces) {
        mesa_destroy_surfaces = ctx->vtable->vaDestroySurfaces;
        ctx->vtable->vaDestroySurfaces = destroy_surfaces;
    }
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaGetImage &&
        ctx->vtable->vaPutImage && ctx->vtable->vaCreateImage && ctx->vtable->vaDestroyImage &&
        ctx->vtable->vaMapBuffer && ctx->vtable->vaUnmapBuffer) {
        mesa_get_image = ctx->vtable->vaGetImage;
        mesa_put_image = ctx->vtable->vaPutImage;
        mesa_create_image = ctx->vtable->vaCreateImage;
        mesa_destroy_image = ctx->vtable->vaDestroyImage;
        ctx->vtable->vaGetImage = get_image;
        ctx->vtable->vaPutImage = put_image;
        ctx->vtable->vaCreateImage = create_image;
        ctx->vtable->vaDestroyImage = destroy_image;
    }
    /* every process: no decoding into or encoding from an import (needs the context and
     * surface records); the fill needs vaExportSurfaceHandle (surface_fourcc) and the
     * buffer calls */
    if (st == VA_STATUS_SUCCESS && ctx->vtable && ctx->vtable->vaBeginPicture &&
        ctx->vtable->vaRenderPicture && ctx->vtable->vaDestroyContext == destroy_context &&
        ctx->vtable->vaCreateSurfaces2 == create_surfaces2) {
        fill_hooked = fill_on() && ctx->vtable->vaBufferInfo && ctx->vtable->vaMapBuffer &&
                      ctx->vtable->vaUnmapBuffer && ctx->vtable->vaExportSurfaceHandle;
        mesa_begin_picture = ctx->vtable->vaBeginPicture;
        mesa_render_picture = ctx->vtable->vaRenderPicture;
        ctx->vtable->vaBeginPicture = begin_picture;
        ctx->vtable->vaRenderPicture = render_checked;
    }
    return st;
}

/* libva looks for its own minor version first, then older ones. */
#define INIT(m) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx); \
    __attribute__((visibility("default"))) VAStatus __vaDriverInit_1_##m(VADriverContextP ctx) { return shim_init(ctx); }
INIT(20) INIT(21) INIT(22) INIT(23) INIT(24) INIT(25) INIT(26) INIT(27) INIT(28)
INIT(29) INIT(30) INIT(31) INIT(32)
