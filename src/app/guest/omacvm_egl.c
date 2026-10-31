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
 * Its second job (ADR 0064): Ghostty 1.2 and newer need OpenGL 4.3, and the VM's GPU gives 4.1
 * (virgl on the Mac's OpenGL 4.1; Zink on the Mac's Vulkan only 2.1), so Ghostty opened no
 * window. In a process whose executable is named ghostty, and only there, glvnd gets a wrapper
 * for eglInitialize, where Mesa picks its driver: LIBGL_ALWAYS_SOFTWARE=1 while Mesa's
 * eglInitialize runs (llvmpipe, OpenGL 4.6, on the VM's CPU), removed again right after, so
 * the programs Ghostty starts keep the GPU (with the variable on Ghostty's command line instead,
 * eglinfo from its shell got llvmpipe). A LIBGL_ALWAYS_SOFTWARE,
 * MESA_LOADER_DRIVER_OVERRIDE or GALLIUM_DRIVER already set is left alone: that choice wins.
 * Set and removed under a mutex on every call, also when Mesa's call fails. Risk left: the
 * environment changes while another thread of Ghostty might read it (getenv is not safe against
 * setenv); GTK sets up EGL once per display, on its main thread, for the first window.
 * Ghostty on the GPU again (it then opens no window): LIBGL_ALWAYS_SOFTWARE=0.
 *
 * Ghostty on the Mac's GPU (ADR 0064's amendment, experimental, off by default): when the app
 * asks for it at this start (OmacVM.app's setting, sent only with Vulkan on KosmicKrisp: SMBIOS
 * omacvm.glzink=1, so host.env has OMACVM_GLZINK=1), no Venus context was lost in this boot
 * (/run/omacvm/gl-zink-off absent) and the person set none of the variables above nor
 * MESA_GL_VERSION_OVERRIDE, that eglInitialize gets MESA_LOADER_DRIVER_OVERRIDE=zink and
 * MESA_GL_VERSION_OVERRIDE=4.3 instead, the same way: Zink on Venus then claims 4.3 core
 * (KosmicKrisp has no transform feedback or geometry shaders; Ghostty 1.3.1 draws without
 * them). Mesa reads the version once per process, when its first display is set up
 * (version.c keeps it for every context), so it too is needed only for that call; its GLSL
 * version stays Zink's own (a GL override skips the clamp). Where Zink cannot start (MoltenVK,
 * no Venus) Mesa falls back to llvmpipe by itself. Both files are read only there. After Mesa's eglInitialize the library asks Mesa which driver it
 * took (eglGetDisplayDriverName), says it in one line on stderr and writes
 * $XDG_RUNTIME_DIR/omacvm/ghostty-gl ("PID ASKED GOT WHY", the last display set up), which
 * omacvm check reads. On Zink Mesa's dma-buf export answers yes without writing the fd (the
 * driver's fd query fails and egl_dri2.c ignores it), and GTK, which passes its array unset,
 * then made a texture of whatever was in it: a CRITICAL and a close of a bad fd every frame.
 * So for a display set up on Zink in a Ghostty process, eglQueryString(EGL_EXTENSIONS) leaves
 * out EGL_MESA_image_dma_buf_export (GTK then never tries; told no, it logged a warning every
 * frame instead), and eglExportDMABUFImageMESA, for apps that call it anyway (Ghostty 1.4),
 * sets the fds to -1 first and says no when plane 0 got none: they draw without the export,
 * as on any driver that has none.
 *
 * Kept small, and it fails open: if Mesa's library is missing or glvnd's vendor ABI is not
 * major 0, __egl_Main returns false and glvnd uses Mesa's own 50_mesa.json. The compositor
 * (Hyprland), Xwayland, Omarchy's shell (quickshell: the bar and Omarchy 4's lock screen),
 * hyprlock and the login screen run Mesa alone (they show no VA-API surfaces). Mesa thus
 * loads as two glvnd vendors in other processes; this one lists no devices (glvnd would list
 * every device twice), so displays opened on a device are Mesa's. Every process but Ghostty
 * gets Mesa's own eglInitialize, eglQueryString and eglExportDMABUFImageMESA.
 * One app: __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json; the VM:
 * delete the JSON file (Ghostty then opens no window again).
 *
 * Built in the VM by install.sh (/usr/local/lib/libEGL_omacvm.so.0). MIT, part of OmacVM.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <link.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <glvnd/libeglabi.h>

#ifndef MESA_EGL
#define MESA_EGL "libEGL_mesa.so.0"
#endif
/* What the Mac said at this start (omacvm-app-host), and the file a lost Venus context leaves
 * for the rest of the boot (one line "lost <time> <why>"); other paths for the tests. */
#ifndef HOST_ENV
#define HOST_ENV "/run/omacvm/host.env"
#endif
#ifndef GL_ZINK_OFF
#define GL_ZINK_OFF "/run/omacvm/gl-zink-off"
#endif
#define SHIM "/omacvm_drv_video.so"

#define FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)

typedef void (*imported_fn)(uint32_t fourcc, uint32_t w, uint32_t h, unsigned int n,
                            const int *fds, const uint32_t *offsets);

static void *(*mesa_gpa)(const char *);
static PFNEGLCREATEIMAGEKHRPROC mesa_create_image_khr;
static PFNEGLCREATEIMAGEPROC mesa_create_image;
static PFNEGLINITIALIZEPROC mesa_initialize;
typedef const char *(*driver_name_fn)(EGLDisplay dpy);
typedef EGLBoolean (*export_fn)(EGLDisplay dpy, EGLImageKHR image, int *fds, EGLint *strides, EGLint *offsets);
typedef EGLBoolean (*export_query_fn)(EGLDisplay dpy, EGLImageKHR image, int *fourcc, int *planes,
                                      EGLuint64KHR *modifiers);
static export_fn mesa_export;
static export_query_fn mesa_export_query;
static PFNEGLQUERYSTRINGPROC mesa_query_string;
static int ghostty_gl;                  /* this process is Ghostty: its driver is picked here (see the top) */
static int on_zink;                     /* ... and a display of it was set up on Zink */
static pthread_mutex_t env_lock = PTHREAD_MUTEX_INITIALIZER;
/* Ghostty's displays set up on Zink, with Mesa's extension string and the copy without the
 * dma-buf export (made once per string: kept for the process, as Mesa keeps its own) */
#define ZINK_DISPLAYS 8
static struct { EGLDisplay dpy; const char *mesa; char *ours; } zink_dpy[ZINK_DISPLAYS];
static pthread_mutex_t zink_lock = PTHREAD_MUTEX_INITIALIZER;
#define EXPORT_EXT "EGL_MESA_image_dma_buf_export"
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

/* host.env has this line (as the VA shim reads it) */
static int host_says(const char *what)
{
    char line[256];
    FILE *f = fopen(HOST_ENV, "re");
    int yes = 0;

    if (!f)
        return 0;
    while (!yes && fgets(line, sizeof(line), f))
        yes = !strcmp(line, what);
    fclose(f);
    return yes;
}

/* What Ghostty's eglInitialize gets, and why (the record's last word, omacvm check's reason). */
enum ask { ASK_OWN, ASK_LLVMPIPE, ASK_ZINK };

static enum ask ghostty_ask(const char **why)
{
    static const char *const own[] = { "LIBGL_ALWAYS_SOFTWARE", "MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER" };

    for (size_t i = 0; i < sizeof(own) / sizeof(own[0]); i++)
        if (getenv(own[i])) {
            *why = own[i];      /* the person's choice wins */
            return ASK_OWN;
        }
    if (!host_says("OMACVM_GLZINK=1\n"))
        *why = "nomarker";      /* the app's setting off, or no Vulkan on KosmicKrisp at this start */
    else if (!access(GL_ZINK_OFF, F_OK))
        *why = "zinkoff";       /* a Venus context was lost in this boot */
    else if (getenv("MESA_GL_VERSION_OVERRIDE"))
        *why = "glversion";     /* the person's own version: llvmpipe, as before */
    else {
        *why = "setting";
        return ASK_ZINK;
    }
    return ASK_LLVMPIPE;
}

/* One word of Mesa's driver name for the record ("?" when unknown) */
static void word(char *out, size_t size, const char *s)
{
    size_t n = 0;

    for (; s && *s && n + 1 < size; s++)
        if ((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9') || *s == '_')
            out[n++] = *s;
    if (!n)
        out[n++] = '?';
    out[n] = 0;
}

/* $XDG_RUNTIME_DIR/omacvm/ghostty-gl: "PID ASKED GOT WHY", the last display set up */
static void record(const char *asked, const char *got, const char *why)
{
    const char *run = getenv("XDG_RUNTIME_DIR");
    char dir[PATH_MAX], line[160];
    int d, fd, n;

    if (!run || run[0] != '/' || snprintf(dir, sizeof(dir), "%s/omacvm", run) >= (int)sizeof(dir))
        return;
    if (mkdir(dir, 0700) && errno != EEXIST)
        return;
    d = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (d < 0)
        return;
    n = snprintf(line, sizeof(line), "%d %s %s %s\n", (int)getpid(), asked, got, why);
    fd = openat(d, "ghostty-gl.new", O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd >= 0) {
        int ok = n > 0 && n < (int)sizeof(line) && write(fd, line, (size_t)n) == n;
        close(fd);
        if (!ok || renameat(d, "ghostty-gl.new", d, "ghostty-gl"))
            unlinkat(d, "ghostty-gl.new", 0);
    }
    close(d);
}

/* A display of Ghostty set up on Zink (its extension string leaves out the export) */
static void zink_display(EGLDisplay dpy)
{
    int i;

    pthread_mutex_lock(&zink_lock);
    for (i = 0; i < ZINK_DISPLAYS && zink_dpy[i].dpy && zink_dpy[i].dpy != dpy; i++)
        ;
    if (i < ZINK_DISPLAYS && !zink_dpy[i].dpy)
        zink_dpy[i].dpy = dpy;
    pthread_mutex_unlock(&zink_lock);
}

/* s without the word EXPORT_EXT, or NULL (no memory) */
static char *without_export(const char *s)
{
    size_t n = strlen(s), k = sizeof(EXPORT_EXT) - 1, o = 0;
    char *r = malloc(n + 1);

    if (!r)
        return NULL;
    for (const char *p = s; *p;) {
        const char *e = p;
        while (*e && *e != ' ')
            e++;
        if ((size_t)(e - p) != k || strncmp(p, EXPORT_EXT, k)) {
            if (o)
                r[o++] = ' ';
            memcpy(r + o, p, (size_t)(e - p));
            o += (size_t)(e - p);
        }
        p = *e ? e + 1 : e;
    }
    r[o] = 0;
    return r;
}

/* Ghostty only: a display on Zink names no dma-buf export (see the top) */
static const char *query_string(EGLDisplay dpy, EGLint name)
{
    PFNEGLQUERYSTRINGPROC f = __atomic_load_n(&mesa_query_string, __ATOMIC_ACQUIRE);
    const char *s = f(dpy, name), *r = s;

    if (!s || name != EGL_EXTENSIONS || dpy == EGL_NO_DISPLAY || !__atomic_load_n(&on_zink, __ATOMIC_ACQUIRE))
        return s;
    pthread_mutex_lock(&zink_lock);
    for (int i = 0; i < ZINK_DISPLAYS && zink_dpy[i].dpy; i++) {
        if (zink_dpy[i].dpy != dpy)
            continue;
        if (zink_dpy[i].mesa != s) {   /* first time, or Mesa made a new string (set up again) */
            char *ours = without_export(s);
            if (ours) {
                zink_dpy[i].ours = ours;   /* an earlier copy stays: the app may still hold it */
                zink_dpy[i].mesa = s;
            }
        }
        if (zink_dpy[i].mesa == s && zink_dpy[i].ours)
            r = zink_dpy[i].ours;
        break;
    }
    pthread_mutex_unlock(&zink_lock);
    return r;
}

/* Ghostty only: Mesa reads LIBGL_ALWAYS_SOFTWARE and MESA_LOADER_DRIVER_OVERRIDE in
 * eglInitialize, where it picks its driver; the variables are there for that call alone, unless
 * a driver was chosen already (see the top). Then Mesa's own answer is recorded. */
static EGLBoolean initialize_ghostty(EGLDisplay dpy, EGLint *major, EGLint *minor)
{
    PFNEGLINITIALIZEPROC f = __atomic_load_n(&mesa_initialize, __ATOMIC_ACQUIRE);
    driver_name_fn name = (driver_name_fn)mesa_gpa("eglGetDisplayDriverName");
    const char *why = "", *asked;
    char got[32];
    EGLBoolean ok;
    enum ask a;

    pthread_mutex_lock(&env_lock);
    a = ghostty_ask(&why);
    if (a == ASK_ZINK && setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 0))
        a = ASK_OWN, why = "nomemory";
    else if (a == ASK_ZINK && setenv("MESA_GL_VERSION_OVERRIDE", "4.3", 0)) {
        unsetenv("MESA_LOADER_DRIVER_OVERRIDE");
        a = ASK_OWN, why = "nomemory";
    } else if (a == ASK_LLVMPIPE && setenv("LIBGL_ALWAYS_SOFTWARE", "1", 0))
        a = ASK_OWN, why = "nomemory";
    ok = f(dpy, major, minor);
    if (a == ASK_ZINK) {
        unsetenv("MESA_LOADER_DRIVER_OVERRIDE");
        unsetenv("MESA_GL_VERSION_OVERRIDE");
    } else if (a == ASK_LLVMPIPE)
        unsetenv("LIBGL_ALWAYS_SOFTWARE");
    pthread_mutex_unlock(&env_lock);
    if (!ok)
        return ok;
    asked = a == ASK_ZINK ? "zink" : a == ASK_LLVMPIPE ? "llvmpipe" : "own";
    word(got, sizeof(got), name ? name(dpy) : NULL);
    if (!strcmp(got, "zink") || (a == ASK_ZINK && !strcmp(got, "?"))) {
        zink_display(dpy);
        __atomic_store_n(&on_zink, 1, __ATOMIC_RELEASE);
    }
    fprintf(stderr, "OmacVM: Ghostty's OpenGL: asked %s (%s), Mesa's driver %s\n", asked, why, got);
    record(asked, got, why);
    return ok;
}

/* Ghostty on Zink only: Mesa says yes but leaves the fds as they were when the driver gives
 * none (see the top); then no, with every fd it did give closed. */
static EGLBoolean export_dmabuf(EGLDisplay dpy, EGLImageKHR image, int *fds, EGLint *strides, EGLint *offsets)
{
    export_fn f = __atomic_load_n(&mesa_export, __ATOMIC_ACQUIRE);
    export_query_fn q = __atomic_load_n(&mesa_export_query, __ATOMIC_ACQUIRE);
    static int said;
    int planes = 0;
    EGLBoolean ok;

    if (!fds || !q || !__atomic_load_n(&on_zink, __ATOMIC_ACQUIRE) ||
        !q(dpy, image, NULL, &planes, NULL) || planes < 1 || planes > 4)
        return f(dpy, image, fds, strides, offsets);
    for (int i = 0; i < planes; i++)
        fds[i] = -1;
    ok = f(dpy, image, fds, strides, offsets);
    if (!ok || fds[0] >= 0)
        return ok;
    for (int i = 1; i < planes; i++)
        if (fds[i] >= 0) {
            close(fds[i]);
            fds[i] = -1;
        }
    if (!__atomic_exchange_n(&said, 1, __ATOMIC_RELAXED))
        fprintf(stderr, "OmacVM: Mesa exported no dma-buf fd (Zink): said no, drawn without it\n");
    return EGL_FALSE;
}

/* glvnd asks the vendor for every EGL function it dispatches to it, these included. */
static void *get_proc_address(const char *name)
{
    void *p;

    /* Mesa's own vendor lists the devices (glvnd keeps no list per vendor) */
    if (!strcmp(name, "eglQueryDevicesEXT"))
        return NULL;
    p = mesa_gpa(name);
    if (p && ghostty_gl && !strcmp(name, "eglInitialize")) {
        __atomic_store_n(&mesa_initialize, (PFNEGLINITIALIZEPROC)p, __ATOMIC_RELEASE);
        return (void *)initialize_ghostty;
    }
    if (p && ghostty_gl && !strcmp(name, "eglQueryString")) {
        __atomic_store_n(&mesa_query_string, (PFNEGLQUERYSTRINGPROC)p, __ATOMIC_RELEASE);
        return (void *)query_string;
    }
    if (p && ghostty_gl && !strcmp(name, "eglExportDMABUFImageMESA")) {
        __atomic_store_n(&mesa_export_query, (export_query_fn)mesa_gpa("eglExportDMABUFImageQueryMESA"), __ATOMIC_RELEASE);
        __atomic_store_n(&mesa_export, (export_fn)p, __ATOMIC_RELEASE);
        return (void *)export_dmabuf;
    }
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

/* The name of this process's executable (/proc/self/exe), "" when unknown; exe holds it. */
static const char *program(char *exe, size_t size)
{
    ssize_t n = readlink("/proc/self/exe", exe, size - 1);
    const char *b;

    if (n <= 0)
        return "";
    exe[n] = 0;
    b = strrchr(exe, '/');
    return b ? b + 1 : exe;
}

/* The compositor, Xwayland, Omarchy's shell and the lock and login screens (see the top) */
static int desktop_process(const char *b)
{
    return !strcmp(b, "Hyprland") || !strcmp(b, "Xwayland") || !strcmp(b, "quickshell") ||
           !strcmp(b, "hyprlock") || !strncmp(b, "sddm-greeter", 12);
}

__attribute__((visibility("default")))
EGLBoolean __egl_Main(uint32_t version, const __EGLapiExports *exports, __EGLvendorInfo *vendor,
                      __EGLapiImports *imports)
{
    __PFNEGLMAINPROC mesa_main;
    char exe[PATH_MAX];
    const char *name = program(exe, sizeof(exe));
    void *mesa;

    if (EGL_VENDOR_ABI_GET_MAJOR_VERSION(version) != 0 || desktop_process(name))
        return EGL_FALSE;
    mesa = dlopen(MESA_EGL, RTLD_NOW | RTLD_LOCAL);
    mesa_main = mesa ? (__PFNEGLMAINPROC)dlsym(mesa, __EGL_MAIN_PROTO_NAME) : NULL;
    if (!mesa_main || !mesa_main(version, exports, vendor, imports) || !imports->getProcAddress)
        return EGL_FALSE;
    mesa_gpa = imports->getProcAddress;
    ghostty_gl = !strcmp(name, "ghostty");
    imports->getProcAddress = get_proc_address;
    return EGL_TRUE;
}
