/*
 * va-shim-logical: OmacVM's VA driver shim (omacvm_drv_video.c, "Pictures at their own size")
 * tells the Mac's runtime each video surface's own size. Built twice by va-shim-logical.sh:
 * with -DSTUB_DRIVER as a stand-in for Mesa's driver (surfaces whose planes are files: an
 * export hands out the same files again; video processing records the regions it gets), and
 * as the program that loads the shim against it. The program's own ioctl() stands in for the
 * virtio-gpu kernel driver: PRIME_FD_TO_HANDLE gives one handle per file, RESOURCE_INFO the
 * Mac's resource 1000 + handle, EXECBUFFER reads the NOPs' payloads ("OMLS", version 1,
 * resource/width/height) as the Mac does, or refuses with EPERM (a sandbox).
 *   va-shim-logical SHIM STUB declare|none|refused [ARGS...]
 * declare: Mesa's own 4:2:0 surfaces whose size is not a multiple of 16 are declared (Y W x H,
 * UV half rounded up; NV12 and P010), 8 entries per NOP, one submit per vaCreateSurfaces2 and
 * no fence; 1280x720, RGB surfaces and imports are not; an import of a declared surface counts
 * as declared at that surface's size, whatever size it asks for. Video processing (any process)
 * from a declared source gets its region scaled by the size Mesa takes it in parts of (its own
 * surface: rounded up to 16; an import: the size asked) over the declared size, since the Mac
 * scales again: Mesa's own 320x180 -> 320x192 (the stand-in models Mesa's compositor:
 * region / Mesa's size, then the Mac: x declared / texture size). vaGetImage into another format
 * from a declared surface reads an import of it at the picture's size (Mesa's converting path),
 * into the surface's own format the surface itself. With Chromium's fill (OMACVM_VA_FILL=1 or
 * --type=), an undeclared rounded source is scaled as before.
 * The app's EGL imports (omacvm_egl.c calls the shim's omacvm_va_dmabuf_imported_v1): planes of
 * a surface the app exported through the shim are declared at the import's size when it
 * changes: Chrome's NV12 import of a 1920x1088 surface at 1920x1080 (Y and UV in one submit),
 * mpv's R8 + GR88 imports after an export per frame (the resources looked up at the first
 * export only), HEVC's 1000x568 surface shown at 1000x562; nothing for an unknown dma-buf, an
 * offset, a plane of the wrong kind, a size past Mesa's plane, a full-size import of a plane
 * never declared, or after vaTerminate; 10-bit planes too (R16 + GR1616, one P010 image). A
 * converting vaGetImage of the whole 1920x1088 surface reads its 1080 rows (Mesa, like the
 * stand-in, refuses a region past the surface), and video processing from it, or from a VA
 * import made before the EGL import, is scaled by 1088/1080.
 * none: nothing is sent (no ioctl at all), regions and images as before. refused: the submit
 * fails, nothing counts as declared, regions as before, one line said, and later surfaces send
 * nothing.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <drm/drm.h>
#include <drm/virtgpu_drm.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>
#include <va/va_vpp.h>

#ifdef STUB_DRIVER
VARectangle seen_src;
int seen_null;                  /* the source region was NULL */
unsigned seen_b[2];             /* the size Mesa took the source region in parts of */
int renders;
/* the last vaGetImage: the surface's size in Mesa (B), its region, converted or not */
unsigned got_b[2], got_region[4], got_imported;
int got_convert, get_calls, destroyed;

static struct surface {
    unsigned format, width, height, fourcc;
    int fd[2];          /* Mesa's own: the planes' files */
    int imported;
} surfaces[96];
static unsigned nsurfaces;
static struct buf { VABufferType type; unsigned size; void *data; } bufs[16];
static unsigned nbufs;

/* a plane's file of BYTES (Mesa's planes: rounded up to 16) */
static int plane_file(unsigned bytes)
{
    char path[] = "/tmp/va-shim-logical-XXXXXX";
    int fd = mkstemp(path);

    unlink(path);
    if (fd >= 0 && ftruncate(fd, bytes)) { }
    return fd;
}

static VAStatus create_surfaces2(VADriverContextP ctx, unsigned int format, unsigned int w,
                                 unsigned int h, VASurfaceID *s, unsigned int n,
                                 VASurfaceAttrib *a, unsigned int na)
{
    int imported = 0;
    unsigned fourcc = format == VA_RT_FORMAT_RGB32 ? VA_FOURCC_ARGB :
                      format == VA_RT_FORMAT_YUV420_10 ? VA_FOURCC_P010 : VA_FOURCC_NV12;
    (void)ctx;
    for (unsigned k = 0; k < na; k++)
        imported |= a[k].type == VASurfaceAttribExternalBufferDescriptor;
    for (unsigned i = 0; i < n; i++) {
        if (nsurfaces >= 96)
            return VA_STATUS_ERROR_ALLOCATION_FAILED;
        struct surface *x = &surfaces[nsurfaces];
        *x = (struct surface){ format, w, h, fourcc, { -1, -1 }, imported };
        if (!imported) {
            unsigned aw = (w + 15) & ~15u, ah = (h + 15) & ~15u;
            x->fd[0] = plane_file(aw * ah * (fourcc == VA_FOURCC_ARGB ? 4 : 1));
            if (fourcc != VA_FOURCC_ARGB)
                x->fd[1] = plane_file(aw * ah / 2);
        }
        s[i] = nsurfaces++;
    }
    return VA_STATUS_SUCCESS;
}

/* the size Mesa takes a region in parts of: its own surface's buffer is rounded up to 16
 * (vl_video_buffer_create), an import's is the size asked (vl_video_buffer_create_ex2) */
static void mesa_size(VASurfaceID s, unsigned b[2])
{
    b[0] = surfaces[s].imported ? surfaces[s].width : (surfaces[s].width + 15) & ~15u;
    b[1] = surfaces[s].imported ? surfaces[s].height : (surfaces[s].height + 15) & ~15u;
}

/* Mesa's export: one object per plane (the same files each time), a layer each, or one layer
 * of both planes (composed) */
static VAStatus export_surface(VADriverContextP ctx, VASurfaceID s, uint32_t mem, uint32_t flags,
                               void *descriptor)
{
    VADRMPRIMESurfaceDescriptor *d = descriptor;
    (void)ctx; (void)mem;
    if (s >= nsurfaces || surfaces[s].fd[0] < 0)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    memset(d, 0, sizeof(*d));
    d->fourcc = surfaces[s].fourcc;
    d->width = surfaces[s].width;
    d->height = surfaces[s].height;
    d->num_objects = surfaces[s].fd[1] >= 0 ? 2 : 1;
    d->num_layers = flags & VA_EXPORT_SURFACE_COMPOSED_LAYERS ? 1 : d->num_objects;
    for (unsigned i = 0; i < d->num_objects; i++) {
        d->objects[i].fd = dup(surfaces[s].fd[i]);
        if (d->num_layers == 1) {
            d->layers[0].num_planes = d->num_objects;
            d->layers[0].object_index[i] = i;
        } else {
            d->layers[i].num_planes = 1;
            d->layers[i].object_index[0] = i;
        }
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_surfaces(VADriverContextP ctx, VASurfaceID *s, int n)
{
    (void)ctx; (void)s;
    destroyed += n;
    return VA_STATUS_SUCCESS;
}

static struct { VAImageID id; unsigned fourcc; } images[16];
static unsigned nimages;

static VAStatus create_image(VADriverContextP ctx, VAImageFormat *f, int w, int h, VAImage *img)
{
    (void)ctx;
    if (nimages >= 16)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    memset(img, 0, sizeof(*img));
    img->image_id = 100 + nimages;
    img->format = *f;
    img->width = w;
    img->height = h;
    images[nimages].id = img->image_id;
    images[nimages++].fourcc = f->fourcc;
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_image(VADriverContextP ctx, VAImageID id) { (void)ctx; (void)id; return VA_STATUS_SUCCESS; }

/* Mesa's vaGetImage: into another format through its compositor (the region in parts of the
 * surface's Mesa size), into the same one a copy of the texels */
static VAStatus get_image(VADriverContextP ctx, VASurfaceID s, int x, int y, unsigned int w,
                          unsigned int h, VAImageID id)
{
    (void)ctx;
    if (s >= nsurfaces || id < 100 || id - 100 >= nimages)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    if (x < 0 || y < 0 || x + w > surfaces[s].width || y + h > surfaces[s].height)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    mesa_size(s, got_b);
    got_region[0] = x, got_region[1] = y, got_region[2] = w, got_region[3] = h;
    got_imported = surfaces[s].imported;
    got_convert = images[id - 100].fourcc != surfaces[s].fourcc;
    get_calls++;
    return VA_STATUS_SUCCESS;
}

static VAStatus put_image(VADriverContextP ctx, VASurfaceID s, VAImageID id, int sx, int sy,
                          unsigned int sw, unsigned int sh, int dx, int dy, unsigned int dw,
                          unsigned int dh)
{
    (void)ctx; (void)s; (void)id; (void)sx; (void)sy; (void)sw; (void)sh; (void)dx; (void)dy;
    (void)dw; (void)dh;
    return VA_STATUS_SUCCESS;
}

static VAStatus query_config_attributes(VADriverContextP ctx, VAConfigID config, VAProfile *profile,
                                        VAEntrypoint *entrypoint, VAConfigAttrib *a, int *n)
{
    (void)ctx; (void)a;
    *profile = config ? VAProfileNone : VAProfileVP9Profile0;
    *entrypoint = config ? VAEntrypointVideoProc : VAEntrypointVLD;
    *n = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int w, int h, int flag,
                               VASurfaceID *t, int nt, VAContextID *context)
{
    static VAContextID next;
    (void)ctx; (void)config; (void)w; (void)h; (void)flag; (void)t; (void)nt;
    *context = next++;
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_context(VADriverContextP ctx, VAContextID c) { (void)ctx; (void)c; return VA_STATUS_SUCCESS; }
static VAStatus terminate(VADriverContextP ctx) { (void)ctx; return VA_STATUS_SUCCESS; }

static VAStatus create_buffer(VADriverContextP ctx, VAContextID c, VABufferType type, unsigned int size,
                              unsigned int num, void *data, VABufferID *id)
{
    (void)ctx; (void)c;
    if (nbufs >= 16)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    bufs[nbufs] = (struct buf){ type, size * num, calloc(1, size * num) };
    if (data)
        memcpy(bufs[nbufs].data, data, size * num);
    *id = nbufs++;
    return VA_STATUS_SUCCESS;
}

static VAStatus buffer_info(VADriverContextP ctx, VABufferID id, VABufferType *type, unsigned int *size,
                            unsigned int *num)
{
    (void)ctx;
    if (id >= nbufs)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    *type = bufs[id].type;
    *size = bufs[id].size;
    *num = 1;
    return VA_STATUS_SUCCESS;
}

static VAStatus map_buffer(VADriverContextP ctx, VABufferID id, void **p)
{
    (void)ctx;
    if (id >= nbufs)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    *p = bufs[id].data;
    return VA_STATUS_SUCCESS;
}

static VAStatus unmap_buffer(VADriverContextP ctx, VABufferID id) { (void)ctx; (void)id; return VA_STATUS_SUCCESS; }
static VAStatus begin_picture(VADriverContextP ctx, VAContextID c, VASurfaceID t) { (void)ctx; (void)c; (void)t; return VA_STATUS_SUCCESS; }

static VAStatus render_picture(VADriverContextP ctx, VAContextID c, VABufferID *ids, int n)
{
    (void)ctx; (void)c;
    for (int i = 0; i < n; i++) {
        if (ids[i] >= nbufs || bufs[ids[i]].type != VAProcPipelineParameterBufferType)
            continue;
        const VAProcPipelineParameterBuffer *pp = bufs[ids[i]].data;
        seen_src = pp->surface_region ? *pp->surface_region : (VARectangle){ 0, 0, 0, 0 };
        seen_null = !pp->surface_region;
        if (pp->surface < nsurfaces)
            mesa_size(pp->surface, seen_b);
        renders++;
    }
    return VA_STATUS_SUCCESS;
}

VAStatus __vaDriverInit_1_20(VADriverContextP ctx)
{
    ctx->str_vendor = "Mesa Gallium driver 26.2.5 for virgl (stand-in)";
    ctx->vtable->vaCreateSurfaces2 = create_surfaces2;
    ctx->vtable->vaExportSurfaceHandle = export_surface;
    ctx->vtable->vaQueryConfigAttributes = query_config_attributes;
    ctx->vtable->vaCreateContext = create_context;
    ctx->vtable->vaDestroyContext = destroy_context;
    ctx->vtable->vaTerminate = terminate;
    ctx->vtable->vaCreateBuffer = create_buffer;
    ctx->vtable->vaBufferInfo = buffer_info;
    ctx->vtable->vaMapBuffer = map_buffer;
    ctx->vtable->vaUnmapBuffer = unmap_buffer;
    ctx->vtable->vaBeginPicture = begin_picture;
    ctx->vtable->vaRenderPicture = render_picture;
    ctx->vtable->vaDestroySurfaces = destroy_surfaces;
    ctx->vtable->vaCreateImage = create_image;
    ctx->vtable->vaDestroyImage = destroy_image;
    ctx->vtable->vaGetImage = get_image;
    ctx->vtable->vaPutImage = put_image;
    return VA_STATUS_SUCCESS;
}
#else
/* ---- the kernel's side (this program's ioctl) ---- */
static int refuse;              /* EXECBUFFER fails with EPERM */
static int ioctls, submits, nops, fenced, bad, lookups;
static struct decl { uint32_t res, w, h; } decls[256];
static unsigned ndecls;
static ino_t handles[256];      /* handle - 1 -> the file */
static unsigned nhandles;

static uint32_t handle_of(int fd)
{
    struct stat st;

    if (fstat(fd, &st))
        return 0;
    for (unsigned i = 0; i < nhandles; i++)
        if (handles[i] == st.st_ino)
            return i + 1;
    if (nhandles >= 256)
        return 0;
    handles[nhandles++] = st.st_ino;
    return nhandles;
}

int ioctl(int fd, unsigned long request, ...)
{
    va_list ap;
    void *arg;

    (void)fd;
    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);
    ioctls++;
    lookups += request == DRM_IOCTL_PRIME_FD_TO_HANDLE || request == DRM_IOCTL_VIRTGPU_RESOURCE_INFO;
    if (request == DRM_IOCTL_PRIME_FD_TO_HANDLE) {
        struct drm_prime_handle *ph = arg;
        ph->handle = handle_of(ph->fd);
        if (!ph->handle) {
            errno = EINVAL;
            return -1;
        }
        return 0;
    }
    if (request == DRM_IOCTL_VIRTGPU_RESOURCE_INFO) {
        struct drm_virtgpu_resource_info *ri = arg;
        if (!ri->bo_handle || ri->bo_handle > nhandles) {
            errno = ENOENT;
            return -1;
        }
        ri->res_handle = 1000 + ri->bo_handle;
        return 0;
    }
    if (request == DRM_IOCTL_VIRTGPU_EXECBUFFER) {
        struct drm_virtgpu_execbuffer *eb = arg;
        if (refuse) {
            errno = EPERM;
            return -1;
        }
        const uint32_t *c = (const uint32_t *)(uintptr_t)eb->command;
        unsigned n = eb->size / 4, i = 0;
        submits++;
        fenced += !!(eb->flags & VIRTGPU_EXECBUF_FENCE_FD_OUT);
        while (i < n) {
            uint32_t len = c[i] >> 16, cmd = c[i] & 0xff;
            if (cmd != 0 || i + 1 + len > n || len < 2 || c[i + 1] != 0x534c4d4fu ||
                c[i + 2] != 1 || (len - 2) % 3 || (len - 2) / 3 > 8) {
                bad++;
                break;
            }
            nops++;
            for (uint32_t k = 0; k < (len - 2) / 3 && ndecls < 256; k++)
                decls[ndecls++] = (struct decl){ c[i + 3 + 3 * k], c[i + 4 + 3 * k], c[i + 5 + 3 * k] };
            i += 1 + len;
        }
        return 0;
    }
    errno = ENOTTY;   /* GET_CAPS: an older host, no limits */
    return -1;
}

static int failed;
static struct VADriverVTable vt;

static int *dlsym_int(void *lib, const char *name)
{
    static int none;
    int *p = dlsym(lib, name);
    return p ? p : &none;
}
static struct VADriverContext dc;
static struct drm_state drm;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failed |= !ok;
}

/* the Mac's resource of SURFACE's plane P (by its export, as the shim does) */
static uint32_t res_of(VASurfaceID s, int p)
{
    VADRMPRIMESurfaceDescriptor d;
    uint32_t h = 0;

    if (vt.vaExportSurfaceHandle(&dc, s, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                 VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d) != VA_STATUS_SUCCESS)
        return 0;
    if ((unsigned)p < d.num_objects)
        h = handle_of(d.objects[p].fd);
    for (unsigned i = 0; i < d.num_objects; i++)
        close(d.objects[i].fd);
    return h ? 1000 + h : 0;
}

/* the size declared for resource RES (last one wins), 0x0: none */
static void declared(uint32_t res, uint32_t *w, uint32_t *h)
{
    *w = *h = 0;
    for (unsigned i = 0; i < ndecls; i++)
        if (decls[i].res == res) {
            *w = decls[i].w;
            *h = decls[i].h;
        }
}

static void expect_plane(const char *name, VASurfaceID s, int p, uint32_t w, uint32_t h)
{
    uint32_t gw, gh;
    char what[200];

    declared(res_of(s, p), &gw, &gh);
    snprintf(what, sizeof(what), "%s, %s plane: declared %ux%u (expected %ux%u)", name,
             p ? "UV" : "Y", gw, gh, w, h);
    check(gw == w && gh == h, what);
}

/* an NV12 picture of 320 x H imported from FD (Y plane) and FD2 (UV), or from FD alone with
 * the UV plane after ROWS rows */
static VASurfaceID import_nv12(int fd, int fd2, unsigned rows, unsigned h)
{
    VADRMPRIMESurfaceDescriptor d;
    VASurfaceAttrib a[2];
    VASurfaceID s = VA_INVALID_SURFACE;

    memset(&d, 0, sizeof(d));
    d.fourcc = VA_FOURCC_NV12;
    d.width = 320;
    d.height = h;
    d.num_objects = fd2 >= 0 ? 2 : 1;
    d.objects[0].fd = fd;
    d.objects[1].fd = fd2;
    d.num_layers = 1;
    d.layers[0].drm_format = 0x3231564e;   /* NV12 */
    d.layers[0].num_planes = 2;
    d.layers[0].pitch[0] = d.layers[0].pitch[1] = 320;
    d.layers[0].object_index[1] = fd2 >= 0 ? 1 : 0;
    d.layers[0].offset[1] = fd2 >= 0 ? 0 : 320 * rows;
    a[0] = (VASurfaceAttrib){ .type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypeInteger,
                                         .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 } };
    a[1] = (VASurfaceAttrib){ .type = VASurfaceAttribExternalBufferDescriptor,
                              .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypePointer, .value.p = &d } };
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, h, &s, 1, a, 2);
    return s;
}

/* an NV12 picture of W x H imported from the planes' files FD (Y) and FD2 (UV) */
static VASurfaceID import_planes(int fd, int fd2, unsigned w, unsigned h)
{
    VADRMPRIMESurfaceDescriptor d;
    VASurfaceAttrib a[2];
    VASurfaceID s = VA_INVALID_SURFACE;

    memset(&d, 0, sizeof(d));
    d.fourcc = VA_FOURCC_NV12;
    d.width = w;
    d.height = h;
    d.num_objects = 2;
    d.objects[0].fd = fd;
    d.objects[1].fd = fd2;
    d.num_layers = 2;
    d.layers[0].drm_format = 0x20203852;   /* R8 */
    d.layers[0].num_planes = 1;
    d.layers[0].pitch[0] = (w + 15) & ~15u;
    d.layers[1].drm_format = 0x38385247;   /* GR88 */
    d.layers[1].num_planes = 1;
    d.layers[1].object_index[0] = 1;
    d.layers[1].pitch[0] = (w + 15) & ~15u;
    a[0] = (VASurfaceAttrib){ .type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypeInteger,
                                         .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 } };
    a[1] = (VASurfaceAttrib){ .type = VASurfaceAttribExternalBufferDescriptor,
                              .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypePointer, .value.p = &d } };
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, w, h, &s, 1, a, 2);
    return s;
}

/* the app exports S as Chrome (separate layers) or mpv (COMPOSED) do: the planes' files into FD
 * (closed by the caller) */
static void app_export(VASurfaceID s, int composed, int fd[2])
{
    VADRMPRIMESurfaceDescriptor d;

    fd[0] = fd[1] = -1;
    memset(&d, 0, sizeof(d));
    if (vt.vaExportSurfaceHandle(&dc, s, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                 VA_EXPORT_SURFACE_READ_ONLY | (composed ?
                                 VA_EXPORT_SURFACE_COMPOSED_LAYERS :
                                 VA_EXPORT_SURFACE_SEPARATE_LAYERS), &d) != VA_STATUS_SUCCESS ||
        d.num_objects != 2)
        return;
    fd[0] = d.objects[0].fd;
    fd[1] = d.objects[1].fd;
}

#define FCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)
typedef void (*imported_fn)(uint32_t fourcc, uint32_t w, uint32_t h, unsigned int n,
                            const int *fds, const uint32_t *offsets);
static void no_entry(uint32_t f, uint32_t w, uint32_t h, unsigned int n, const int *fds,
                     const uint32_t *o) { (void)f; (void)w; (void)h; (void)n; (void)fds; (void)o; }
static imported_fn imported = no_entry;

/* the app's EGL import of FOURCC W x H from N files FD at offset OFF (0 or more): the ioctls it
 * caused */
static int egl_import(uint32_t fourcc, uint32_t w, uint32_t h, unsigned n, const int *fd,
                      uint32_t off)
{
    uint32_t offs[2] = { off, off };
    int before = ioctls;

    imported(fourcc, w, h, n, fd, offs);
    return ioctls - before;
}

int main(int argc, char **argv)
{
    VAStatus (*init)(VADriverContextP);
    VARectangle *seen_src;
    int *renders, *seen_null;
    unsigned *seen_b;
    char what[200];

    if (argc < 4)
        return 2;
    const char *mode = argv[3];
    int declare = !strcmp(mode, "declare");
    refuse = !strcmp(mode, "refused");
    void *stub = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!stub || !shim) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    seen_src = dlsym(stub, "seen_src");
    renders = dlsym(stub, "renders");
    seen_null = dlsym(stub, "seen_null");
    seen_b = dlsym(stub, "seen_b");
    init = (VAStatus (*)(VADriverContextP))dlsym(shim, "__vaDriverInit_1_20");
    drm.fd = open("/dev/null", O_RDWR);
    dc.vtable = &vt;
    dc.drm_state = &drm;
    dc.max_attributes = 4;
    if (!seen_src || !renders || !seen_null || !seen_b || !init || init(&dc) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "the shim did not load the stand-in driver\n");
        return 2;
    }
    int ioctls_at_start = ioctls;

    /* Mesa's own surfaces */
    VASurfaceID s1080, s480, s720, sp010, sargb, s180, many[20];
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 1920, 1080, &s1080, 1, NULL, 0);
    int submits_1080 = submits;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 854, 480, &s480, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 1280, 720, &s720, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420_10, 1920, 1080, &sp010, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_RGB32, 320, 180, &sargb, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, 180, &s180, 1, NULL, 0);
    int submits_before_many = submits, nops_before_many = nops;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 640, 360, many, 20, NULL, 0);
    int many_submits = submits - submits_before_many, many_nops = nops - nops_before_many;

    if (declare) {
        check(submits_1080 == 1 && !fenced && !bad, "one submit for the first surface, no fence, "
              "every NOP as the Mac reads it");
        expect_plane("1920x1080", s1080, 0, 1920, 1080);
        expect_plane("1920x1080", s1080, 1, 960, 540);
        expect_plane("854x480", s480, 0, 854, 480);
        expect_plane("854x480", s480, 1, 427, 240);
        expect_plane("1280x720 (a multiple of 16)", s720, 0, 0, 0);
        expect_plane("1280x720 (a multiple of 16)", s720, 1, 0, 0);
        expect_plane("P010 1920x1080", sp010, 0, 1920, 1080);
        expect_plane("P010 1920x1080", sp010, 1, 960, 540);
        expect_plane("ARGB 320x180 (RGB keeps its rounded size)", sargb, 0, 0, 0);
        expect_plane("320x180", s180, 0, 320, 180);
        expect_plane("640x360, 20 at once (last)", many[19], 1, 320, 180);
        snprintf(what, sizeof(what), "20 surfaces at once: %d submit(s), %d NOPs (40 entries, 8 "
                 "each)", many_submits, many_nops);
        check(many_submits == 1 && many_nops == 5, what);
    } else {
        snprintf(what, sizeof(what), "nothing declared (%u entries; %d ioctls besides the "
                 "start's)", ndecls, ioctls - ioctls_at_start);
        check(!ndecls && (refuse || ioctls == ioctls_at_start), what);
    }

    /* imports: a camera frame of its own size (never declared), an import of the declared
     * 320x180 surface (Chrome converts imports of its decoder's surfaces), a GBM-like buffer
     * of 192 rows that nobody declared */
    unsigned before = ndecls;
    char path[] = "/tmp/va-shim-logical-XXXXXX";
    int cam = mkstemp(path);
    unlink(path);
    if (ftruncate(cam, 320 * 180 * 3 / 2)) { }
    VASurfaceID icam = import_nv12(cam, -1, 180, 180);
    VADRMPRIMESurfaceDescriptor own;
    own.objects[0].fd = own.objects[1].fd = -1;
    vt.vaExportSurfaceHandle(&dc, s180, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                             VA_EXPORT_SURFACE_SEPARATE_LAYERS, &own);
    VASurfaceID iown = import_nv12(own.objects[0].fd, own.objects[1].fd, 0, 180);
    VASurfaceID iown192 = import_nv12(own.objects[0].fd, own.objects[1].fd, 0, 192);
    char path2[] = "/tmp/va-shim-logical-XXXXXX";
    int gbm = mkstemp(path2);
    unlink(path2);
    if (ftruncate(gbm, 320 * 192 * 3 / 2)) { }
    VASurfaceID igbm = import_nv12(gbm, -1, 192, 180);
    check(ndecls == before, "imports declare nothing");

    /* Video processing: the source region Mesa gets. Chromium's fill is on with OMACVM_VA_FILL=1
     * or in a Chromium process (--type=), as the shim decides. */
    const char *fe = getenv("OMACVM_VA_FILL");
    int fill = fe && *fe ? *fe == '1' : argc > 4 && !strncmp(argv[4], "--type=", 7);
    VAContextID proc;
    VABufferID buf;
    VAProcPipelineParameterBuffer pp, *app = NULL;
    VARectangle in = { 0, 0, 320, 180 }, scaled = { 0, 0, 320, 169 }, up = { 0, 0, 320, 192 },
                crop = { 0, 90, 320, 90 }, crop_up = { 0, 96, 320, 96 },
                in480 = { 0, 0, 854, 480 }, up480 = { 0, 0, 864, 480 }, in720 = { 0, 0, 1280, 720 };
    memset(&pp, 0, sizeof(pp));
    vt.vaCreateContext(&dc, 1, 320, 180, 0, NULL, 0, &proc);
    vt.vaCreateBuffer(&dc, proc, VAProcPipelineParameterBufferType, sizeof(pp), 1, &pp, &buf);
    vt.vaMapBuffer(&dc, buf, (void **)&app);
    struct { const char *name; VASurfaceID src; const VARectangle *region; VARectangle want; } cases[] = {
        { "Mesa's own 320x180", s180, &in, declare ? up : fill ? scaled : in },
        { "Mesa's own 320x180, no region", s180, NULL, declare ? up : fill ? scaled : (VARectangle){ 0, 0, 0, 0 } },
        { "Mesa's own 320x180, rows 90-179", s180, &crop, declare ? crop_up : fill ? (VARectangle){ 0, 84, 320, 84 } : crop },
        { "Mesa's own 854x480", s480, &in480, declare ? up480 : fill ? (VARectangle){ 0, 0, 844, 480 } : in480 },
        { "Mesa's own 1280x720 (a multiple of 16)", s720, &in720, in720 },
        { "an import of the 320x180 at its size", iown, &in, declare ? in : fill ? scaled : in },
        { "an import of the 320x180 at 320x192", iown192, &in, declare ? up : in },
        { "a 192-row import nobody declared", igbm, &in, fill ? scaled : in },
        { "a camera frame of its own size", icam, &in, in },
    };
    for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        app->surface = cases[c].src;
        app->surface_region = cases[c].region;
        app->output_region = NULL;
        vt.vaBeginPicture(&dc, proc, sargb);
        vt.vaRenderPicture(&dc, proc, &buf, 1);
        int null_ok = cases[c].region || cases[c].want.width || *seen_null;
        snprintf(what, sizeof(what), "video processing from %s: Mesa got source %d,%d %ux%u "
                 "(expected %d,%d %ux%u)", cases[c].name, seen_src->x, seen_src->y, seen_src->width,
                 seen_src->height, cases[c].want.x, cases[c].want.y, cases[c].want.width,
                 cases[c].want.height);
        check(!memcmp(seen_src, &cases[c].want, sizeof(VARectangle)) && null_ok &&
              app->surface_region == cases[c].region, what);
    }
    /* what the Mac samples for Mesa's own 1920x1080 picture, the whole of it: the region over
     * Mesa's size, times the declared size over the texture's (1088), in texture rows */
    app->surface = s1080;
    VARectangle in1080 = { 0, 0, 1920, 1080 };
    app->surface_region = &in1080;
    vt.vaBeginPicture(&dc, proc, sargb);
    vt.vaRenderPicture(&dc, proc, &buf, 1);
    double rows = (double)seen_src->height / seen_b[1] * (declare ? 1080.0 / 1088.0 : 1.0) * 1088.0;
    snprintf(what, sizeof(what), "video processing from Mesa's own 1920x1080: the Mac samples "
             "%.2f texture rows (the picture: 1080)", rows);
    /* (Chromium's fill without declarations scales Mesa's own sources as it scales imports;
     * Chrome converts only imports, so that case is left as it was) */
    if (declare || !fill)
        check(rows > 1079.5 && rows < 1080.5, what);

    /* vaGetImage: into another format (Mesa converts: the region in parts of Mesa's size), into
     * the surface's own format (the texels) */
    VAImageFormat bgra = { .fourcc = VA_FOURCC_BGRA, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 32 };
    VAImageFormat nv12 = { .fourcc = VA_FOURCC_NV12, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12 };
    VAImage ib, in12;
    vt.vaCreateImage(&dc, &bgra, 320, 180, &ib);
    vt.vaCreateImage(&dc, &nv12, 320, 180, &in12);
    int d0 = *dlsym_int(stub, "destroyed"), g0 = *dlsym_int(stub, "get_calls");
    VAStatus gst = vt.vaGetImage(&dc, s180, 0, 0, 320, 180, ib.image_id);
    unsigned *gb = dlsym(stub, "got_b"), *gimp = dlsym(stub, "got_imported");
    int *gconv = dlsym(stub, "got_convert");
    snprintf(what, sizeof(what), "vaGetImage BGRA from Mesa's own 320x180: Mesa converted from a "
             "%s surface of %ux%u (expected %s)", *gimp ? "imported" : "Mesa's", gb[0], gb[1],
             declare ? "an import of 320x180, destroyed after" : "the surface, 320x192");
    check(gst == VA_STATUS_SUCCESS && *gconv && *dlsym_int(stub, "get_calls") == g0 + 1 &&
          (declare ? *gimp && gb[0] == 320 && gb[1] == 180 && *dlsym_int(stub, "destroyed") == d0 + 1 :
                     !*gimp && gb[1] == 192 && *dlsym_int(stub, "destroyed") == d0), what);
    gst = vt.vaGetImage(&dc, s180, 0, 0, 320, 180, in12.image_id);
    check(gst == VA_STATUS_SUCCESS && !*gconv && !*gimp && gb[1] == 192,
          "vaGetImage NV12 from Mesa's own 320x180: the surface itself (its texels)");
    gst = vt.vaGetImage(&dc, s720, 0, 0, 320, 180, ib.image_id);
    check(gst == VA_STATUS_SUCCESS && *gconv && !*gimp,
          "vaGetImage BGRA from Mesa's own 1280x720 (not declared): the surface itself");

    /* ---- the app's EGL imports ---- */
    void *entry = dlsym(shim, "omacvm_va_dmabuf_imported_v1");
    check(entry != NULL, "the shim has omacvm_va_dmabuf_imported_v1 (omacvm_egl.c calls it)");
    if (entry)
        imported = (imported_fn)entry;
    const uint32_t NV12 = FCC('N', 'V', '1', '2'), R8 = FCC('R', '8', ' ', ' '),
                   GR88 = FCC('G', 'R', '8', '8');
    VASurfaceID c1, c2, hevc, full, early;
    int f1[2], f2[2], fh[2], ff[2], fx[2], n;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 1920, 1088, &c1, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 1920, 1088, &c2, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 1000, 568, &hevc, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 1920, 1088, &full, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 1920, 1088, &early, 1, NULL, 0);
    unsigned dx0 = ndecls;
    int s0 = submits;

    /* (a) Chrome: a separate-layer export, then one NV12 image at the picture's size */
    app_export(c1, 0, f1);
    int sa = submits;
    unsigned da = ndecls;
    n = egl_import(NV12, 1920, 1080, 2, f1, 0);
    int sa1 = submits - sa;
    unsigned da1 = ndecls - da;
    n += egl_import(NV12, 1920, 1080, 2, f1, 0);
    snprintf(what, sizeof(what), "Chrome: NV12 import of a 1920x1088 surface at 1920x1080: %d "
             "submit(s), %u entries, then the same import again: %d more ioctl(s)",
             sa1, da1, n - (sa1 > 0));
    if (declare) {
        check(sa1 == 1 && da1 == 2 && n == 1 && !bad, what);
        expect_plane("Chrome's 1920x1088 at 1920x1080", c1, 0, 1920, 1080);
        expect_plane("Chrome's 1920x1088 at 1920x1080", c1, 1, 960, 540);
    }

    /* (b) mpv: an export (composed) and R8 + GR88 imports per frame */
    int lk0 = lookups, lk1 = 0;
    unsigned db = ndecls;
    for (int frame = 0; frame < 3; frame++) {
        app_export(c2, 1, f2);
        if (!frame)
            lk1 = lookups - lk0;
        egl_import(R8, 1920, 1080, 1, &f2[0], 0);
        egl_import(GR88, 960, 540, 1, &f2[1], 0);
        close(f2[0]);
        close(f2[1]);
    }
    snprintf(what, sizeof(what), "mpv: 3 frames of an export + R8 1920x1080 + GR88 960x540: %u "
             "entries, resource lookups %d at the first export, %d after", ndecls - db, lk1,
             lookups - lk0 - lk1);
    if (declare) {
        check(ndecls - db == 2 && lk1 == 4 && lookups - lk0 == lk1, what);
        expect_plane("mpv's 1920x1088 at 1920x1080", c2, 0, 1920, 1080);
        expect_plane("mpv's 1920x1088 at 1920x1080", c2, 1, 960, 540);
    }

    /* (c) HEVC: a 1000x568 surface (declared when made) shown at 1000x562 */
    app_export(hevc, 0, fh);
    int sc = submits;
    egl_import(NV12, 1000, 562, 2, fh, 0);
    snprintf(what, sizeof(what), "HEVC: NV12 import of the 1000x568 surface at 1000x562: %d "
             "submit(s)", submits - sc);
    if (declare) {
        check(submits - sc == 1, what);
        expect_plane("HEVC 1000x568 at 1000x562", hevc, 0, 1000, 562);
        expect_plane("HEVC 1000x568 at 1000x562", hevc, 1, 500, 281);
    }

    /* (d) nothing at all for what is not such an import */
    char path3[] = "/tmp/va-shim-logical-XXXXXX";
    int other[2] = { mkstemp(path3), -1 };
    unlink(path3);
    other[1] = dup(other[0]);
    app_export(full, 0, ff);
    struct { const char *name; uint32_t fourcc, w, h; unsigned n; const int *fd; uint32_t off; } no[] = {
        { "a dma-buf the shim does not know", NV12, 1920, 1000, 2, other, 0 },
        { "R8 of a dma-buf the shim does not know", R8, 1920, 1000, 1, other, 0 },
        { "an offset other than 0", R8, 1920, 1000, 1, f1, 4096 },
        { "R8 of the UV plane", R8, 960, 500, 1, &f1[1], 0 },
        { "GR88 of the Y plane", GR88, 960, 500, 1, &f1[0], 0 },
        { "a size past Mesa's plane (1920x1104)", R8, 1920, 1104, 1, f1, 0 },
        { "a size past Mesa's UV plane (976x544)", GR88, 976, 544, 1, &f1[1], 0 },
        { "an NV12 image of only the Y plane", NV12, 1920, 1000, 1, f1, 0 },
        { "a full-size import of a 1920x1088 surface never declared", NV12, 1920, 1088, 2, ff, 0 },
        { "an AB24 import of the planes", FCC('A', 'B', '2', '4'), 1920, 1000, 2, f1, 0 },
    };
    for (unsigned i = 0; i < sizeof(no) / sizeof(no[0]); i++) {
        snprintf(what, sizeof(what), "no ioctl for %s", no[i].name);
        check(egl_import(no[i].fourcc, no[i].w, no[i].h, no[i].n, no[i].fd, no[i].off) == 0, what);
    }

    /* (f) a converting vaGetImage of the whole 1920x1088 surface shown at 1920x1080 */
    VAImage ib2;
    vt.vaCreateImage(&dc, &bgra, 1920, 1088, &ib2);
    gst = vt.vaGetImage(&dc, c1, 0, 0, 1920, 1088, ib2.image_id);
    unsigned *greg = dlsym(stub, "got_region");
    snprintf(what, sizeof(what), "vaGetImage BGRA 0,0 1920x1088 of the 1920x1088 surface shown at "
             "1920x1080: status %d, Mesa converted %u,%u %ux%u of a%s surface of %ux%u", gst,
             greg[0], greg[1], greg[2], greg[3], *gimp ? "n imported" : "", gb[0], gb[1]);
    if (declare)
        check(gst == VA_STATUS_SUCCESS && *gconv && *gimp && gb[0] == 1920 && gb[1] == 1080 &&
              !greg[0] && !greg[1] && greg[2] == 1920 && greg[3] == 1080, what);
    else
        check(gst == VA_STATUS_SUCCESS && !*gimp && gb[1] == 1088, what);

    /* (g) video processing from it, and from a VA import of a surface made before its EGL
     * import: the Mac samples the picture's 1080 rows */
    app_export(early, 0, fx);
    VASurfaceID iearly = import_planes(fx[0], fx[1], 1920, 1088);
    egl_import(NV12, 1920, 1080, 2, fx, 0);
    struct { const char *name; VASurfaceID src; } vpp[] = {
        { "the 1920x1088 surface shown at 1920x1080", c1 },
        { "a VA import (made before the EGL import) of a 1920x1088 surface shown at 1920x1080", iearly },
    };
    for (unsigned i = 0; i < sizeof(vpp) / sizeof(vpp[0]); i++) {
        app->surface = vpp[i].src;
        app->surface_region = &in1080;
        vt.vaBeginPicture(&dc, proc, sargb);
        vt.vaRenderPicture(&dc, proc, &buf, 1);
        rows = (double)seen_src->height / seen_b[1] * (declare ? 1080.0 : 1088.0);
        snprintf(what, sizeof(what), "video processing from %s: the Mac samples %.2f of its %s rows",
                 vpp[i].name, rows, declare ? "1080" : "1088");
        check(declare ? rows > 1079.5 && rows < 1080.5 : seen_src->height == 1080, what);
    }
    if (declare) {
        snprintf(what, sizeof(what), "EGL imports: %u entries in %d submit(s), every NOP as the Mac "
                 "reads it, no fence", ndecls - dx0, submits - s0);
        check(!bad && !fenced, what);
    }

    /* (i) 10-bit: mpv's R16 + GR1616 imports of a P010 surface, Chrome's one P010 image */
    const uint32_t R16 = FCC('R', '1', '6', ' '), GR32 = FCC('G', 'R', '3', '2'),
                   P010 = FCC('P', '0', '1', '0');
    VASurfaceID t1, t2;
    int g1[2], g2[2];
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420_10, 1920, 1088, &t1, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420_10, 1920, 1088, &t2, 1, NULL, 0);
    app_export(t1, 1, g1);
    int si = submits;
    egl_import(R16, 1920, 1080, 1, &g1[0], 0);
    egl_import(GR32, 960, 540, 1, &g1[1], 0);
    app_export(t2, 0, g2);
    egl_import(P010, 1920, 1080, 2, g2, 0);
    snprintf(what, sizeof(what), "10-bit: R16 + GR1616 imports and one P010 image of 1920x1088 "
             "surfaces at 1920x1080: %d submit(s)", submits - si);
    if (declare) {
        check(submits - si == 3 && !bad, what);
        expect_plane("P010 1920x1088 at R16 1920x1080", t1, 0, 1920, 1080);
        expect_plane("P010 1920x1088 at GR1616 960x540", t1, 1, 960, 540);
        expect_plane("P010 1920x1088 as one P010 image of 1920x1080", t2, 0, 1920, 1080);
        expect_plane("P010 1920x1088 as one P010 image of 1920x1080", t2, 1, 960, 540);
    }

    /* (h) vaTerminate, then an import of the old dma-bufs: nothing */
    vt.vaTerminate(&dc);
    n = egl_import(NV12, 1920, 1000, 2, f1, 0);
    check(n == 0, "no ioctl for an import after vaTerminate");

    if (!declare) {
        snprintf(what, sizeof(what), "nothing declared at all (%u entries; %d resource lookups, %d "
                 "submits)", ndecls, lookups, submits);
        check(!ndecls && (refuse || (!lookups && !submits)), what);
    }
    if (failed) {
        printf("va-shim-logical (%s): FAILED\n", mode);
        return 1;
    }
    return 0;
}
#endif
