/*
 * va-shim-import-decode: OmacVM's VA driver shim (omacvm_drv_video.c, "Decoding into an
 * imported surface") at vaBeginPicture, vaRenderPicture and vaEndPicture. Built twice by
 * va-shim-import-decode.sh: with -DSTUB_DRIVER as a stand-in for Mesa's driver (config 0
 * decodes, 1 is video processing, 2 encodes; surface and context IDs that were freed come
 * back first, as in Mesa's handle table) that counts every picture begun on a decoding or
 * encoding context in an imported surface (where Mesa's virgl driver crashes) and every
 * vaRenderPicture and vaEndPicture it gets, and as the program that loads the shim against it.
 *   va-shim-import-decode SHIM STUB on|off [ARGS...]
 * on: a decoding or encoding context refuses an imported target (DRM_PRIME_2 or the older
 * DRM_PRIME descriptor, also an RGB import the fill makes at the rounded size) with
 * VA_STATUS_ERROR_INVALID_SURFACE before Mesa sees it, in every process, and its
 * vaRenderPicture and vaEndPicture until a picture begins in a surface Mesa made; Mesa's own
 * surfaces decode and encode; video processing takes imports as before; an ID that comes back
 * for a surface or context of the other kind is that kind; 2000 live imports and 200 decoders
 * are all still known. off (OMACVM_VA_IMPORT_GUARD=0): Mesa gets the import.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>

#define MAX_IDS 4096

#ifdef STUB_DRIVER
int into_import;      /* pictures begun on a decoding or encoding context in an import (Mesa crashes) */
int begun;            /* every picture Mesa saw begin */
int renders, ends;    /* every vaRenderPicture / vaEndPicture Mesa got */

static int imported[MAX_IDS], context_config[MAX_IDS];
static VASurfaceID free_surface = VA_INVALID_SURFACE;
static VAContextID free_context = VA_INVALID_ID;
static VASurfaceID next_surface;
static VAContextID next_context;

static VAStatus create_surfaces2(VADriverContextP ctx, unsigned int format, unsigned int w,
                                 unsigned int h, VASurfaceID *s, unsigned int n,
                                 VASurfaceAttrib *a, unsigned int na)
{
    int imp = 0;
    (void)ctx; (void)format; (void)w; (void)h;
    for (unsigned k = 0; k < na; k++)
        imp |= a[k].type == VASurfaceAttribExternalBufferDescriptor;
    for (unsigned i = 0; i < n; i++) {
        if (free_surface != VA_INVALID_SURFACE) {
            s[i] = free_surface;
            free_surface = VA_INVALID_SURFACE;
        } else {
            s[i] = next_surface++;
        }
        if (s[i] < MAX_IDS)
            imported[s[i]] = imp;
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_surfaces(VADriverContextP ctx, VASurfaceID *s, int n)
{
    (void)ctx;
    if (n > 0)
        free_surface = s[0];
    return VA_STATUS_SUCCESS;
}

static VAStatus query_config_attributes(VADriverContextP ctx, VAConfigID config, VAProfile *profile,
                                        VAEntrypoint *entrypoint, VAConfigAttrib *a, int *n)
{
    (void)ctx; (void)a;
    if (config > 2)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    *profile = config == 1 ? VAProfileNone : VAProfileH264Main;
    *entrypoint = config == 0 ? VAEntrypointVLD : config == 1 ? VAEntrypointVideoProc :
                  VAEntrypointEncSlice;
    *n = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int w, int h, int flag,
                               VASurfaceID *t, int nt, VAContextID *context)
{
    (void)ctx; (void)w; (void)h; (void)flag; (void)t; (void)nt;
    if (free_context != VA_INVALID_ID) {
        *context = free_context;
        free_context = VA_INVALID_ID;
    } else {
        *context = next_context++;
    }
    if (*context < MAX_IDS)
        context_config[*context] = (int)config;
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_context(VADriverContextP ctx, VAContextID c)
{
    (void)ctx;
    free_context = c;
    return VA_STATUS_SUCCESS;
}

static VAStatus terminate(VADriverContextP ctx) { (void)ctx; return VA_STATUS_SUCCESS; }

static VAStatus begin_picture(VADriverContextP ctx, VAContextID c, VASurfaceID t)
{
    (void)ctx;
    begun++;
    if (c < MAX_IDS && t < MAX_IDS && context_config[c] != 1 && imported[t])
        into_import++;
    return VA_STATUS_SUCCESS;
}

static VAStatus render_picture(VADriverContextP ctx, VAContextID c, VABufferID *b, int n)
{
    (void)ctx; (void)c; (void)b; (void)n;
    renders++;
    return VA_STATUS_SUCCESS;
}

static VAStatus end_picture(VADriverContextP ctx, VAContextID c)
{
    (void)ctx; (void)c;
    ends++;
    return VA_STATUS_SUCCESS;
}

VAStatus __vaDriverInit_1_20(VADriverContextP ctx)
{
    ctx->str_vendor = "Mesa Gallium driver 26.2.5 for virgl (stand-in)";
    ctx->vtable->vaCreateSurfaces2 = create_surfaces2;
    ctx->vtable->vaDestroySurfaces = destroy_surfaces;
    ctx->vtable->vaQueryConfigAttributes = query_config_attributes;
    ctx->vtable->vaCreateContext = create_context;
    ctx->vtable->vaDestroyContext = destroy_context;
    ctx->vtable->vaTerminate = terminate;
    ctx->vtable->vaBeginPicture = begin_picture;
    ctx->vtable->vaRenderPicture = render_picture;
    ctx->vtable->vaEndPicture = end_picture;
    return VA_STATUS_SUCCESS;
}
#else
static int failed;
static struct VADriverVTable vt;
static struct VADriverContext dc;
static int *into_import, *begun, *renders, *ends;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failed |= !ok;
}

/* a W x H picture from a dma-buf (a file) of ROWS rows, as Chrome imports a frame of its
 * pool: the DRM_PRIME_2 descriptor, or (legacy) the DRM_PRIME external buffers; NV12, or
 * ARGB (format VA_RT_FORMAT_RGB32) */
static VASurfaceID import_frame(int legacy, int rgb, unsigned w, unsigned h, unsigned rows)
{
    char path[] = "/tmp/va-shim-import-XXXXXX";
    int fd = mkstemp(path);
    unsigned pitch = rgb ? w * 4 : w, size = rgb ? pitch * rows : pitch * rows * 3 / 2;
    VADRMPRIMESurfaceDescriptor d;
    VASurfaceAttribExternalBuffers e;
    uintptr_t handle;
    VASurfaceAttrib a[2];
    VASurfaceID s = VA_INVALID_SURFACE;

    unlink(path);
    if (fd < 0 || ftruncate(fd, size))
        return s;
    memset(&d, 0, sizeof(d));
    memset(&e, 0, sizeof(e));
    d.fourcc = rgb ? VA_FOURCC_ARGB : VA_FOURCC_NV12;
    d.width = w;
    d.height = h;
    d.num_objects = 1;
    d.objects[0].fd = fd;
    d.objects[0].size = size;
    d.num_layers = 1;
    d.layers[0].drm_format = rgb ? 0x34325241 : 0x3231564e;   /* AR24, NV12 */
    d.layers[0].num_planes = rgb ? 1 : 2;
    d.layers[0].pitch[0] = d.layers[0].pitch[1] = pitch;
    d.layers[0].offset[1] = rgb ? 0 : pitch * rows;
    handle = (uintptr_t)fd;
    e.pixel_format = d.fourcc;
    e.width = w;
    e.height = h;
    e.data_size = size;
    e.num_planes = rgb ? 1 : 2;
    e.pitches[0] = e.pitches[1] = pitch;
    e.offsets[1] = rgb ? 0 : pitch * rows;
    e.buffers = &handle;
    e.num_buffers = 1;
    a[0] = (VASurfaceAttrib){ .type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypeInteger,
                                         .value.i = legacy ? VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME :
                                                             VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 } };
    a[1] = (VASurfaceAttrib){ .type = VASurfaceAttribExternalBufferDescriptor,
                              .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypePointer,
                                         .value.p = legacy ? (void *)&e : (void *)&d } };
    vt.vaCreateSurfaces2(&dc, rgb ? VA_RT_FORMAT_RGB32 : VA_RT_FORMAT_YUV420, w, h, &s, 1, a, 2);
    close(fd);
    return s;
}

static VASurfaceID import_nv12(int legacy) { return import_frame(legacy, 0, 320, 180, 192); }

/* a picture on CONTEXT in TARGET, begun, rendered and ended: are all three refused (and
 * none of them reached Mesa) or all three passed on? */
static void picture(VAContextID context, VASurfaceID target, int refused, const char *what)
{
    int b = *begun, r = *renders, e = *ends;
    VABufferID buf = 0;
    VAStatus sb = vt.vaBeginPicture(&dc, context, target);
    VAStatus sr = vt.vaRenderPicture(&dc, context, &buf, 1);
    VAStatus se = vt.vaEndPicture(&dc, context);
    char line[300];

    snprintf(line, sizeof(line), "%s: begin/render/end status %d/%d/%d, Mesa got %d/%d/%d "
             "(expected: %s)", what, sb, sr, se, *begun - b, *renders - r, *ends - e,
             refused ? "all refused, Mesa nothing" : "all passed on");
    if (refused)
        check(sb == VA_STATUS_ERROR_INVALID_SURFACE && sr == VA_STATUS_ERROR_INVALID_SURFACE &&
              se == VA_STATUS_ERROR_INVALID_SURFACE && *begun == b && *renders == r &&
              *ends == e, line);
    else
        check(sb == VA_STATUS_SUCCESS && sr == VA_STATUS_SUCCESS && se == VA_STATUS_SUCCESS &&
              *begun == b + 1 && *renders == r + 1 && *ends == e + 1, line);
}

int main(int argc, char **argv)
{
    VAStatus (*init)(VADriverContextP);
    char what[200];

    if (argc < 4)
        return 2;
    void *stub = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!stub || !shim) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    into_import = dlsym(stub, "into_import");
    begun = dlsym(stub, "begun");
    renders = dlsym(stub, "renders");
    ends = dlsym(stub, "ends");
    init = (VAStatus (*)(VADriverContextP))dlsym(shim, "__vaDriverInit_1_20");
    dc.vtable = &vt;
    dc.max_attributes = 4;
    if (!into_import || !begun || !renders || !ends || !init || init(&dc) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "the shim did not load the stand-in driver\n");
        return 2;
    }

    VASurfaceID own, imp2, imp1;
    VAContextID dec, proc, enc;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, 180, &own, 1, NULL, 0);
    imp2 = import_nv12(0);
    imp1 = import_nv12(1);
    vt.vaCreateContext(&dc, 0, 320, 180, 0, NULL, 0, &dec);
    vt.vaCreateContext(&dc, 1, 320, 180, 0, NULL, 0, &proc);
    vt.vaCreateContext(&dc, 2, 320, 180, 0, NULL, 0, &enc);

    if (!strcmp(argv[3], "off")) {
        /* the switch: Mesa gets the import (and would crash) */
        VAStatus st = vt.vaBeginPicture(&dc, dec, imp2);
        snprintf(what, sizeof(what), "guard off: decoding into an import reaches Mesa (status %d, "
                 "Mesa saw %d)", st, *into_import);
        check(st == VA_STATUS_SUCCESS && *into_import == 1, what);
        vt.vaTerminate(&dc);
        return failed;
    }

    picture(dec, own, 0, "decoding into Mesa's own surface");
    picture(dec, imp2, 1, "decoding into a DRM_PRIME_2 import");
    picture(dec, imp1, 1, "decoding into a DRM_PRIME import");
    picture(dec, own, 0, "the same decoder, next picture in Mesa's own surface again");
    picture(proc, imp2, 0, "video processing into an import (Chrome's conversion)");
    picture(enc, imp1, 1, "encoding from an import");
    picture(enc, own, 0, "encoding from Mesa's own surface");

    /* the import's ID comes back for a surface of Mesa's own: it decodes */
    vt.vaDestroySurfaces(&dc, &imp2, 1);
    VASurfaceID again;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, 180, &again, 1, NULL, 0);
    snprintf(what, sizeof(what), "an import's ID (%u) back for Mesa's own surface (%u)", imp2, again);
    check(again == imp2, what);
    picture(dec, again, 0, what);
    /* and an own surface's ID back for an import: refused */
    vt.vaDestroySurfaces(&dc, &own, 1);
    VASurfaceID imp_again = import_nv12(0);
    snprintf(what, sizeof(what), "an own surface's ID (%u) back for an import (%u)", own, imp_again);
    check(imp_again == own, what);
    picture(dec, imp_again, 1, what);

    /* the decoder's ID comes back for video processing: imports go through */
    vt.vaDestroyContext(&dc, dec);
    VAContextID proc2;
    vt.vaCreateContext(&dc, 1, 320, 180, 0, NULL, 0, &proc2);
    snprintf(what, sizeof(what), "a decoder's ID (%u) back for video processing (%u)", dec, proc2);
    check(proc2 == dec, what);
    picture(proc2, imp1, 0, what);

    /* an RGB import the fill makes at the rounded size (Chrome's ARGB frames): known too */
    VASurfaceID rgb = import_frame(0, 1, 320, 180, 192);
    picture(enc, rgb, 1, "encoding from an ARGB import (made at the rounded size where the fill is on)");

    /* 2000 imports alive at once (a call's tiles and pools): the first is still known */
    static VASurfaceID many[2000];
    for (int i = 0; i < 2000; i++)
        many[i] = import_nv12(i & 1);
    picture(enc, many[0], 1, "the first of 2000 live imports");
    picture(enc, many[1999], 1, "the last of 2000 live imports");

    /* 200 decoders at once: the last one is guarded too */
    static VAContextID decs[200];
    for (int i = 0; i < 200; i++)
        vt.vaCreateContext(&dc, 0, 320, 180, 0, NULL, 0, &decs[i]);
    picture(decs[199], imp1, 1, "the 200th decoder into an import");
    picture(decs[199], again, 0, "the 200th decoder into Mesa's own surface");

    /* a display that closes forgets its surfaces and contexts */
    vt.vaTerminate(&dc);
    snprintf(what, sizeof(what), "Mesa never began a decoder's or encoder's picture in an import "
             "(%d)", *into_import);
    check(*into_import == 0, what);
    if (failed) {
        printf("va-shim-import-decode: FAILED\n");
        return 1;
    }
    return 0;
}
#endif
