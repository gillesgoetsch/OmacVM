/*
 * va-shim-import-decode: OmacVM's VA driver shim (omacvm_drv_video.c, "Decoding into an
 * imported surface") at vaBeginPicture. Built twice by va-shim-import-decode.sh: with
 * -DSTUB_DRIVER as a stand-in for Mesa's driver (config 0 decodes, 1 is video processing,
 * 2 encodes; surface and context IDs that were freed come back first, as in Mesa's handle
 * table) that counts every picture begun on a decoding context into an imported surface
 * (where Mesa's virgl driver crashes), and as the program that loads the shim against it.
 *   va-shim-import-decode SHIM STUB [ARGS...]
 * A decoding context refuses an imported target (DRM_PRIME_2 or the older DRM_PRIME
 * descriptor) with VA_STATUS_ERROR_INVALID_SURFACE before Mesa sees it, in every process;
 * Mesa's own surfaces decode; video processing and encoding take imports as before; an ID
 * that comes back for a surface or context of the other kind is that kind.
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

#ifdef STUB_DRIVER
int into_import;      /* pictures begun on a decoding context into an import (Mesa crashes) */
int begun;            /* every picture Mesa saw begin */

static int imported[64], context_config[64];
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
        if (s[i] < 64)
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
    if (*context < 64)
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
    if (c < 64 && t < 64 && context_config[c] == 0 && imported[t])
        into_import++;
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
    return VA_STATUS_SUCCESS;
}
#else
static int failed;
static struct VADriverVTable vt;
static struct VADriverContext dc;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failed |= !ok;
}

/* an NV12 320x180 picture from a dma-buf (a file), as Chrome imports a frame of its pool:
 * the DRM_PRIME_2 descriptor, or (legacy) the DRM_PRIME external buffers */
static VASurfaceID import_nv12(int legacy)
{
    char path[] = "/tmp/va-shim-import-XXXXXX";
    int fd = mkstemp(path);
    VADRMPRIMESurfaceDescriptor d;
    VASurfaceAttribExternalBuffers e;
    uintptr_t handle;
    VASurfaceAttrib a[2];
    VASurfaceID s = VA_INVALID_SURFACE;

    unlink(path);
    if (fd < 0 || ftruncate(fd, 320 * 192 * 3 / 2))
        return s;
    memset(&d, 0, sizeof(d));
    memset(&e, 0, sizeof(e));
    d.fourcc = VA_FOURCC_NV12;
    d.width = 320;
    d.height = 180;
    d.num_objects = 1;
    d.objects[0].fd = fd;
    d.objects[0].size = 320 * 192 * 3 / 2;
    d.num_layers = 1;
    d.layers[0].drm_format = 0x3231564e;   /* NV12 */
    d.layers[0].num_planes = 2;
    d.layers[0].pitch[0] = d.layers[0].pitch[1] = 320;
    d.layers[0].offset[1] = 320 * 192;
    handle = (uintptr_t)fd;
    e.pixel_format = VA_FOURCC_NV12;
    e.width = 320;
    e.height = 180;
    e.data_size = 320 * 192 * 3 / 2;
    e.num_planes = 2;
    e.pitches[0] = e.pitches[1] = 320;
    e.offsets[1] = 320 * 192;
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
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, 180, &s, 1, a, 2);
    close(fd);
    return s;
}

int main(int argc, char **argv)
{
    VAStatus (*init)(VADriverContextP);
    int *into_import, *begun;
    char what[200];

    if (argc < 3)
        return 2;
    void *stub = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!stub || !shim) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    into_import = dlsym(stub, "into_import");
    begun = dlsym(stub, "begun");
    init = (VAStatus (*)(VADriverContextP))dlsym(shim, "__vaDriverInit_1_20");
    dc.vtable = &vt;
    dc.max_attributes = 4;
    if (!into_import || !begun || !init || init(&dc) != VA_STATUS_SUCCESS) {
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

    VAStatus st = vt.vaBeginPicture(&dc, dec, own);
    check(st == VA_STATUS_SUCCESS && *begun == 1, "decoding into Mesa's own surface: begun");
    st = vt.vaBeginPicture(&dc, dec, imp2);
    snprintf(what, sizeof(what), "decoding into a DRM_PRIME_2 import: status %d (refused: %d), "
             "Mesa saw %d such picture(s)", st, VA_STATUS_ERROR_INVALID_SURFACE, *into_import);
    check(st == VA_STATUS_ERROR_INVALID_SURFACE && *into_import == 0, what);
    st = vt.vaBeginPicture(&dc, dec, imp1);
    snprintf(what, sizeof(what), "decoding into a DRM_PRIME import: status %d, Mesa saw %d", st,
             *into_import);
    check(st == VA_STATUS_ERROR_INVALID_SURFACE && *into_import == 0, what);
    int before = *begun;
    st = vt.vaBeginPicture(&dc, proc, imp2);
    check(st == VA_STATUS_SUCCESS && *begun == before + 1,
          "video processing into an import: begun (Chrome's conversion)");
    st = vt.vaBeginPicture(&dc, enc, imp1);
    check(st == VA_STATUS_SUCCESS && *begun == before + 2, "encoding from an import: begun");

    /* the import's ID comes back for a surface of Mesa's own: it decodes */
    vt.vaDestroySurfaces(&dc, &imp2, 1);
    VASurfaceID again;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, 180, &again, 1, NULL, 0);
    st = vt.vaBeginPicture(&dc, dec, again);
    snprintf(what, sizeof(what), "an import's ID (%u) back for Mesa's own surface (%u): begun",
             imp2, again);
    check(again == imp2 && st == VA_STATUS_SUCCESS, what);
    /* and an own surface's ID back for an import: refused */
    vt.vaDestroySurfaces(&dc, &own, 1);
    VASurfaceID imp_again = import_nv12(0);
    st = vt.vaBeginPicture(&dc, dec, imp_again);
    snprintf(what, sizeof(what), "an own surface's ID (%u) back for an import (%u): refused",
             own, imp_again);
    check(imp_again == own && st == VA_STATUS_ERROR_INVALID_SURFACE && *into_import == 0, what);

    /* the decoder's ID comes back for video processing: imports go through */
    vt.vaDestroyContext(&dc, dec);
    VAContextID proc2;
    vt.vaCreateContext(&dc, 1, 320, 180, 0, NULL, 0, &proc2);
    st = vt.vaBeginPicture(&dc, proc2, imp1);
    snprintf(what, sizeof(what), "a decoder's ID (%u) back for video processing (%u): begun",
             dec, proc2);
    check(proc2 == dec && st == VA_STATUS_SUCCESS, what);

    /* a display that closes forgets its surfaces and contexts */
    vt.vaTerminate(&dc);
    check(*into_import == 0, "Mesa never began a picture of a decoder in an import");
    if (failed) {
        printf("va-shim-import-decode: FAILED\n");
        return 1;
    }
    return 0;
}
#endif
