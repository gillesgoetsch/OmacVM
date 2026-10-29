/*
 * OmacVM's EGL vendor library for OmacVM.app VMs (glvnd: /etc/glvnd/egl_vendor.d/10_omacvm.json,
 * ADR 0063): Mesa's EGL (libEGL_mesa.so.0) with one addition. A video decoder's VA-API surface
 * can be larger than the picture (H.264 1080p: 1920x1088), and VA-API carries no crop; the app
 * says the picture's size only in its EGL dma-buf import of the planes (Chrome on Wayland: one
 * NV12 image of 1920x1080; mpv: R8 1920x1080 and GR88 960x540), which Mesa's virgl does not
 * pass on to the Mac. So after Mesa made such an image, this library hands the import to
 * OmacVM's VA driver shim (omacvm_drv_video.c, omacvm_va_dmabuf_imported_v1), but only when
 * that shim is loaded in this process: the shim decides whether the planes are a surface of
 * its own and tells the Mac. Everything else is Mesa's, unchanged.
 *
 * Kept small, and it fails open: if Mesa's library is missing or glvnd's vendor ABI is not
 * major 0, __egl_Main returns false and glvnd uses Mesa's own 50_mesa.json. The compositor,
 * Xwayland, the lock screen and the login screen run Mesa alone (they show no VA-API
 * surfaces). Mesa thus loads as two glvnd vendors in other processes; this one lists no
 * devices (glvnd would list every device twice), so displays opened on a device are Mesa's.
 * One app: __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json; the VM:
 * delete the JSON file.
 *
 * Built in the VM by install.sh (/usr/local/lib/libEGL_omacvm.so.0). MIT, part of OmacVM.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <link.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <glvnd/libeglabi.h>

#ifndef MESA_EGL
#define MESA_EGL "libEGL_mesa.so.0"
#endif
#define SHIM "/omacvm_drv_video.so"

#define FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)

typedef void (*imported_fn)(uint32_t fourcc, uint32_t w, uint32_t h, unsigned int n,
                            const int *fds, const uint32_t *offsets);

static void *(*mesa_gpa)(const char *);
static PFNEGLCREATEIMAGEKHRPROC mesa_create_image_khr;
static PFNEGLCREATEIMAGEPROC mesa_create_image;
static imported_fn shim_entry;          /* found once, never dropped (the shim stays loaded) */
static unsigned long long searched;     /* objects loaded at the last search without a hit */

/* The video formats the shim takes (Y plane, UV plane, both) */
static int video_format(uint32_t f)
{
    return f == FOURCC('R', '8', ' ', ' ') || f == FOURCC('R', '1', '6', ' ') ||
           f == FOURCC('G', 'R', '8', '8') || f == FOURCC('G', 'R', '3', '2') ||
           f == FOURCC('N', 'V', '1', '2') || f == FOURCC('P', '0', '1', '0');
}

struct search {
    unsigned long long last, adds;
    char path[PATH_MAX];
};

static int find_shim(struct dl_phdr_info *info, size_t size, void *data)
{
    struct search *s = data;
    size_t n = info->dlpi_name ? strlen(info->dlpi_name) : 0, k = sizeof(SHIM) - 1;

    if (!s->adds && size >= offsetof(struct dl_phdr_info, dlpi_subs)) {
        s->adds = info->dlpi_adds;
        if (s->adds == s->last)
            return 1;   /* nothing loaded since the last search */
    }
    if (n > k && n < sizeof(s->path) && !strcmp(info->dlpi_name + n - k, SHIM)) {
        memcpy(s->path, info->dlpi_name, n + 1);
        return 1;
    }
    return 0;
}

/* The shim's entry point when the shim is loaded in this process (NULL: not, or too old). */
static imported_fn shim(void)
{
    imported_fn f = __atomic_load_n(&shim_entry, __ATOMIC_ACQUIRE);
    struct search s = { .last = __atomic_load_n(&searched, __ATOMIC_RELAXED) };
    void *lib;

    if (f)
        return f;
    dl_iterate_phdr(find_shim, &s);
    lib = s.path[0] ? dlopen(s.path, RTLD_NOW | RTLD_NOLOAD) : NULL;
    f = lib ? (imported_fn)dlsym(lib, "omacvm_va_dmabuf_imported_v1") : NULL;
    if (f)
        __atomic_store_n(&shim_entry, f, __ATOMIC_RELEASE);
    else
        __atomic_store_n(&searched, s.adds, __ATOMIC_RELAXED);
    return f;
}

struct import {
    uint32_t fourcc, w, h, off[4];
    int fd[4];
};

static void attrib(struct import *im, EGLAttrib key, EGLAttrib v)
{
    static const EGLAttrib fd[4] = { EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
                                     EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT };
    static const EGLAttrib off[4] = { EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT,
                                      EGL_DMA_BUF_PLANE2_OFFSET_EXT, EGL_DMA_BUF_PLANE3_OFFSET_EXT };
    uint32_t u = v < 0 || v > UINT32_MAX ? 0 : (uint32_t)v;

    if (key == EGL_WIDTH)
        im->w = u;
    else if (key == EGL_HEIGHT)
        im->h = u;
    else if (key == EGL_LINUX_DRM_FOURCC_EXT)
        im->fourcc = u;
    for (int p = 0; p < 4; p++) {
        if (key == fd[p])
            im->fd[p] = v < 0 || v > INT_MAX ? -1 : (int)v;
        else if (key == off[p])
            im->off[p] = u;
    }
}

/* After Mesa made the image: a video format to the shim, when it is loaded here. */
static void imported(const struct import *im)
{
    imported_fn f;
    unsigned int n = 0;

    if (!im->w || !im->h || !video_format(im->fourcc) || !(f = shim()))
        return;
    while (n < 4 && im->fd[n] >= 0)
        n++;
    if (n)
        f(im->fourcc, im->w, im->h, n, im->fd, im->off);
}

static EGLImageKHR create_image_khr(EGLDisplay dpy, EGLContext ctx, EGLenum target,
                                    EGLClientBuffer buffer, const EGLint *attribs)
{
    EGLImageKHR img = mesa_create_image_khr(dpy, ctx, target, buffer, attribs);
    struct import im = { .fd = { -1, -1, -1, -1 } };

    if (img == EGL_NO_IMAGE_KHR || target != EGL_LINUX_DMA_BUF_EXT || !attribs)
        return img;
    for (int i = 0; attribs[i] != EGL_NONE && i < 256; i += 2)
        attrib(&im, attribs[i], attribs[i + 1]);
    imported(&im);
    return img;
}

static EGLImage create_image(EGLDisplay dpy, EGLContext ctx, EGLenum target,
                             EGLClientBuffer buffer, const EGLAttrib *attribs)
{
    EGLImage img = mesa_create_image(dpy, ctx, target, buffer, attribs);
    struct import im = { .fd = { -1, -1, -1, -1 } };

    if (img == EGL_NO_IMAGE || target != EGL_LINUX_DMA_BUF_EXT || !attribs)
        return img;
    for (int i = 0; attribs[i] != EGL_NONE && i < 256; i += 2)
        attrib(&im, attribs[i], attribs[i + 1]);
    imported(&im);
    return img;
}

/* glvnd asks the vendor for every EGL function it dispatches to it, these two included. */
static void *get_proc_address(const char *name)
{
    void *p;

    /* Mesa's own vendor lists the devices (glvnd keeps no list per vendor) */
    if (!strcmp(name, "eglQueryDevicesEXT"))
        return NULL;
    p = mesa_gpa(name);
    if (p && !strcmp(name, "eglCreateImageKHR")) {
        __atomic_store_n(&mesa_create_image_khr, (PFNEGLCREATEIMAGEKHRPROC)p, __ATOMIC_RELEASE);
        return (void *)create_image_khr;
    }
    if (p && !strcmp(name, "eglCreateImage")) {
        __atomic_store_n(&mesa_create_image, (PFNEGLCREATEIMAGEPROC)p, __ATOMIC_RELEASE);
        return (void *)create_image;
    }
    return p;
}

/* The compositor, Xwayland, the lock and login screens (see the top) */
static int desktop_process(void)
{
    char exe[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    const char *b;

    if (n <= 0)
        return 0;
    exe[n] = 0;
    b = strrchr(exe, '/');
    b = b ? b + 1 : exe;
    return !strcmp(b, "Hyprland") || !strcmp(b, "Xwayland") || !strcmp(b, "hyprlock") ||
           !strncmp(b, "sddm-greeter", 12);
}

__attribute__((visibility("default")))
EGLBoolean __egl_Main(uint32_t version, const __EGLapiExports *exports, __EGLvendorInfo *vendor,
                      __EGLapiImports *imports)
{
    __PFNEGLMAINPROC mesa_main;
    void *mesa;

    if (EGL_VENDOR_ABI_GET_MAJOR_VERSION(version) != 0 || desktop_process())
        return EGL_FALSE;
    mesa = dlopen(MESA_EGL, RTLD_NOW | RTLD_LOCAL);
    mesa_main = mesa ? (__PFNEGLMAINPROC)dlsym(mesa, __EGL_MAIN_PROTO_NAME) : NULL;
    if (!mesa_main || !mesa_main(version, exports, vendor, imports) || !imports->getProcAddress)
        return EGL_FALSE;
    mesa_gpa = imports->getProcAddress;
    imports->getProcAddress = get_proc_address;
    return EGL_TRUE;
}
