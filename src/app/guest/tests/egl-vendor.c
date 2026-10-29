/*
 * egl-vendor: OmacVM's EGL vendor library (omacvm_egl.c) against a stand-in for Mesa's EGL vendor
 * library and one for the VA driver shim. Built three times by egl-vendor.sh: -DSTUB_MESA (Mesa's
 * __egl_Main and getProcAddress; its eglCreateImage(KHR) make an image unless told to fail),
 * -DSTUB_SHIM (omacvm_va_dmabuf_imported_v1, counting its calls), and the program that calls the
 * library's __egl_Main as glvnd does.
 *   egl-vendor WRAPPER MESA SHIM main|ghostty|nomesa|abi1|desktop
 * main: dma-buf imports in a video format reach the shim once each, through eglCreateImageKHR
 * and eglCreateImage, with the import's size; nothing before the shim is loaded (and no crash),
 * for an AB24 import, for another target or when Mesa makes no image; every other name, and
 * eglInitialize, is Mesa's own pointer; eglQueryDevicesEXT is not offered (Mesa's own vendor
 * lists the devices). Run as egl-vendor, foot and chromium.
 * ghostty: run as an exe named ghostty: eglInitialize is wrapped; Mesa's stand-in sees
 * LIBGL_ALWAYS_SOFTWARE=1 during its eglInitialize and the variable is gone afterwards, also on a
 * second call, when Mesa's call fails and from two threads at once; a LIBGL_ALWAYS_SOFTWARE,
 * MESA_LOADER_DRIVER_OVERRIDE or GALLIUM_DRIVER already set is left as it is.
 * nomesa: no Mesa library: __egl_Main is false. abi1: glvnd's vendor ABI 1.x: false, Mesa not
 * loaded. desktop: run as an exe named as one of the desktop's processes (Hyprland, Xwayland,
 * quickshell, hyprlock, sddm-greeter-qt6): false, Mesa not loaded.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <glvnd/libeglabi.h>

#if defined(STUB_MESA)
int calls_main, fail_next;
static EGLImageKHR create_image_khr(EGLDisplay d, EGLContext c, EGLenum t, EGLClientBuffer b,
                                   const EGLint *a)
{
    (void)d; (void)c; (void)t; (void)b; (void)a;
    return fail_next ? EGL_NO_IMAGE_KHR : (EGLImageKHR)(uintptr_t)0x1234;
}
static EGLImage create_image(EGLDisplay d, EGLContext c, EGLenum t, EGLClientBuffer b,
                             const EGLAttrib *a)
{
    (void)d; (void)c; (void)t; (void)b; (void)a;
    return fail_next ? EGL_NO_IMAGE : (EGLImage)(uintptr_t)0x5678;
}
/* eglInitialize: what LIBGL_ALWAYS_SOFTWARE was at the end of each call ("-": not set) */
int fail_init, slow_init;
unsigned init_calls;
char init_saw[16][8];
static EGLBoolean initialize(EGLDisplay d, EGLint *a, EGLint *b)
{
    unsigned i = __atomic_fetch_add(&init_calls, 1, __ATOMIC_RELAXED);
    const char *v;

    (void)d; (void)a; (void)b;
    if (slow_init)
        usleep(100000);
    v = getenv("LIBGL_ALWAYS_SOFTWARE");
    if (i < 16)
        snprintf(init_saw[i], sizeof(init_saw[i]), "%s", v ? v : "-");
    return fail_init ? EGL_FALSE : EGL_TRUE;
}
static EGLBoolean query_devices(EGLint m, EGLDeviceEXT *d, EGLint *n) { (void)m; (void)d; *n = 1; return EGL_TRUE; }
void *stub_gpa(const char *name)
{
    if (!strcmp(name, "eglCreateImageKHR"))
        return (void *)create_image_khr;
    if (!strcmp(name, "eglCreateImage"))
        return (void *)create_image;
    if (!strcmp(name, "eglInitialize"))
        return (void *)initialize;
    if (!strcmp(name, "eglQueryDevicesEXT"))
        return (void *)query_devices;
    return NULL;
}
EGLBoolean __egl_Main(uint32_t version, const __EGLapiExports *exports, __EGLvendorInfo *vendor,
                      __EGLapiImports *imports)
{
    (void)exports; (void)vendor;
    calls_main++;
    if (EGL_VENDOR_ABI_GET_MAJOR_VERSION(version) != 0)
        return EGL_FALSE;
    imports->getProcAddress = stub_gpa;
    return EGL_TRUE;
}
#elif defined(STUB_SHIM)
unsigned calls, last_n;
uint32_t last_fourcc, last_w, last_h;
void omacvm_va_dmabuf_imported_v1(uint32_t fourcc, uint32_t w, uint32_t h, unsigned int n,
                                  const int *fds, const uint32_t *offsets)
{
    (void)fds; (void)offsets;
    calls++;
    last_fourcc = fourcc, last_w = w, last_h = h, last_n = n;
}
#else
#define FCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)
static int failed;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failed |= !ok;
}

static PFNEGLINITIALIZEPROC init;
static unsigned *init_calls;
static char (*init_saw)[8];

static const char *env(const char *name)
{
    const char *v = getenv(name);
    return v ? v : "-";
}

/* One eglInitialize through the library: what Mesa's stand-in saw, and the variable afterwards */
static void init_once(const char *what, EGLBoolean want, const char *want_saw, const char *want_after)
{
    char line[300];
    unsigned i = *init_calls;
    EGLint major, minor;
    EGLBoolean r = init(EGL_NO_DISPLAY, &major, &minor);
    const char *saw = *init_calls == i + 1 && i < 16 ? init_saw[i] : "?";

    snprintf(line, sizeof(line), "%s: Mesa's eglInitialize %s with LIBGL_ALWAYS_SOFTWARE=%s, afterwards %s",
             what, r ? "true" : "false", saw, env("LIBGL_ALWAYS_SOFTWARE"));
    check(r == want && !strcmp(saw, want_saw) && !strcmp(env("LIBGL_ALWAYS_SOFTWARE"), want_after), line);
}

static void *init_thread(void *arg)
{
    EGLint major, minor;

    (void)arg;
    init(EGL_NO_DISPLAY, &major, &minor);
    return NULL;
}

/* An exe named ghostty: Mesa's CPU renderer for its eglInitialize, nothing left behind */
static int ghostty(void *mesa, void *(*gpa)(const char *))
{
    void *(*mesa_gpa)(const char *) = (void *(*)(const char *))dlsym(mesa, "stub_gpa");
    int *fail_init = dlsym(mesa, "fail_init"), *slow_init = dlsym(mesa, "slow_init");
    char what[200];

    init_calls = dlsym(mesa, "init_calls");
    init_saw = dlsym(mesa, "init_saw");
    if (!mesa_gpa || !fail_init || !slow_init || !init_calls || !init_saw) {
        fprintf(stderr, "no stand-in Mesa: %s\n", dlerror());
        return 2;
    }
    init = (PFNEGLINITIALIZEPROC)gpa("eglInitialize");
    check(init && (void *)init != mesa_gpa("eglInitialize"), "ghostty: eglInitialize is wrapped");
    if (!init || (void *)init == mesa_gpa("eglInitialize"))
        return 1;
    check(gpa("eglCreateImageKHR") && gpa("eglCreateImageKHR") != mesa_gpa("eglCreateImageKHR") &&
          !gpa("eglQueryDevicesEXT") && !gpa("eglNoSuchThing"),
          "ghostty: video imports wrapped as in every app, no device list");
    unsetenv("LIBGL_ALWAYS_SOFTWARE");
    unsetenv("MESA_LOADER_DRIVER_OVERRIDE");
    unsetenv("GALLIUM_DRIVER");
    init_once("first call", EGL_TRUE, "1", "-");
    init_once("second call", EGL_TRUE, "1", "-");
    *fail_init = 1;
    init_once("Mesa's call fails", EGL_FALSE, "1", "-");
    *fail_init = 0;
    setenv("LIBGL_ALWAYS_SOFTWARE", "0", 1);
    init_once("LIBGL_ALWAYS_SOFTWARE=0 set before", EGL_TRUE, "0", "0");
    unsetenv("LIBGL_ALWAYS_SOFTWARE");
    setenv("MESA_LOADER_DRIVER_OVERRIDE", "zink", 1);
    init_once("MESA_LOADER_DRIVER_OVERRIDE=zink set before", EGL_TRUE, "-", "-");
    check(!strcmp(env("MESA_LOADER_DRIVER_OVERRIDE"), "zink"), "MESA_LOADER_DRIVER_OVERRIDE kept");
    unsetenv("MESA_LOADER_DRIVER_OVERRIDE");
    setenv("GALLIUM_DRIVER", "softpipe", 1);
    init_once("GALLIUM_DRIVER=softpipe set before", EGL_TRUE, "-", "-");
    check(!strcmp(env("GALLIUM_DRIVER"), "softpipe"), "GALLIUM_DRIVER kept");
    unsetenv("GALLIUM_DRIVER");

    /* two threads at once (Mesa takes 100 ms): each call sees the variable to its end */
    pthread_t t[2];
    unsigned i = *init_calls;
    *slow_init = 1;
    for (int k = 0; k < 2; k++) {
        pthread_create(&t[k], NULL, init_thread, NULL);
        usleep(20000);
    }
    for (int k = 0; k < 2; k++)
        pthread_join(t[k], NULL);
    *slow_init = 0;
    snprintf(what, sizeof(what), "two threads at once: Mesa saw LIBGL_ALWAYS_SOFTWARE=%s and =%s, afterwards %s",
             init_saw[i], init_saw[i + 1], env("LIBGL_ALWAYS_SOFTWARE"));
    check(*init_calls == i + 2 && !strcmp(init_saw[i], "1") && !strcmp(init_saw[i + 1], "1") &&
          !strcmp(env("LIBGL_ALWAYS_SOFTWARE"), "-"), what);
    return failed;
}

int main(int argc, char **argv)
{
    __EGLapiImports imports;
    __EGLapiExports exports;
    char what[200];

    if (argc < 5)
        return 2;
    const char *mode = argv[4];
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    __PFNEGLMAINPROC egl_main = lib ? (__PFNEGLMAINPROC)dlsym(lib, "__egl_Main") : NULL;
    if (!egl_main) {
        fprintf(stderr, "no __egl_Main in %s: %s\n", argv[1], dlerror());
        return 2;
    }
    memset(&imports, 0, sizeof(imports));
    memset(&exports, 0, sizeof(exports));
    uint32_t abi = !strcmp(mode, "abi1") ? 1u << 16 : EGL_VENDOR_ABI_VERSION;
    EGLBoolean ok = egl_main(abi, &exports, NULL, &imports);
    void *mesa = dlopen(argv[2], RTLD_NOW | RTLD_NOLOAD);

    if (!strcmp(mode, "ghostty")) {
        check(ok && mesa && imports.getProcAddress, "ghostty: __egl_Main loads Mesa's and says yes");
        return ok && mesa && imports.getProcAddress ? ghostty(mesa, imports.getProcAddress) : 1;
    }
    if (strcmp(mode, "main")) {
        const char *exe = strrchr(argv[0], '/');

        snprintf(what, sizeof(what), "%s (%s): __egl_Main says %s, Mesa %s", mode, exe ? exe + 1 : argv[0],
                 ok ? "yes" : "no (glvnd uses 50_mesa.json)", mesa ? "loaded" : "not loaded");
        check(!ok && (!strcmp(mode, "nomesa") || !mesa), what);
        return failed;
    }
    check(ok && mesa && imports.getProcAddress, "__egl_Main loads Mesa's and says yes");
    if (!ok || !mesa || !imports.getProcAddress)
        return 1;
    void *(*gpa)(const char *) = imports.getProcAddress;
    void *(*mesa_gpa)(const char *) = (void *(*)(const char *))dlsym(mesa, "stub_gpa");
    int *fail_next = dlsym(mesa, "fail_next");
    PFNEGLCREATEIMAGEKHRPROC cik = (PFNEGLCREATEIMAGEKHRPROC)gpa("eglCreateImageKHR");
    PFNEGLCREATEIMAGEPROC ci = (PFNEGLCREATEIMAGEPROC)gpa("eglCreateImage");

    check(cik && ci && (void *)cik != mesa_gpa("eglCreateImageKHR") &&
          (void *)ci != mesa_gpa("eglCreateImage"), "eglCreateImageKHR and eglCreateImage are wrapped");
    check(gpa("eglInitialize") == mesa_gpa("eglInitialize") && !gpa("eglNoSuchThing"),
          "eglInitialize and every other name are Mesa's own pointers");
    check(!gpa("eglQueryDevicesEXT"), "eglQueryDevicesEXT is not offered (Mesa's own vendor lists the devices)");

    const EGLint nv12[] = { EGL_WIDTH, 1920, EGL_HEIGHT, 1080,
                            EGL_LINUX_DRM_FOURCC_EXT, (EGLint)FCC('N', 'V', '1', '2'),
                            EGL_DMA_BUF_PLANE0_FD_EXT, 0, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
                            EGL_DMA_BUF_PLANE0_PITCH_EXT, 1920,
                            EGL_DMA_BUF_PLANE1_FD_EXT, 1, EGL_DMA_BUF_PLANE1_OFFSET_EXT, 0,
                            EGL_DMA_BUF_PLANE1_PITCH_EXT, 1920, EGL_NONE };
    const EGLAttrib nv12_core[] = { EGL_WIDTH, 1920, EGL_HEIGHT, 1080,
                                    EGL_LINUX_DRM_FOURCC_EXT, FCC('N', 'V', '1', '2'),
                                    EGL_DMA_BUF_PLANE0_FD_EXT, 0, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
                                    EGL_DMA_BUF_PLANE1_FD_EXT, 1, EGL_DMA_BUF_PLANE1_OFFSET_EXT, 0,
                                    EGL_NONE };
    const EGLint r8[] = { EGL_WIDTH, 854, EGL_HEIGHT, 480,
                          EGL_LINUX_DRM_FOURCC_EXT, (EGLint)FCC('R', '8', ' ', ' '),
                          EGL_DMA_BUF_PLANE0_FD_EXT, 0, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0, EGL_NONE };
    const EGLint ab24[] = { EGL_WIDTH, 1920, EGL_HEIGHT, 1080,
                            EGL_LINUX_DRM_FOURCC_EXT, (EGLint)FCC('A', 'B', '2', '4'),
                            EGL_DMA_BUF_PLANE0_FD_EXT, 0, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0, EGL_NONE };

    /* the shim not loaded: Mesa's image, nothing else */
    EGLImageKHR img = cik(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, nv12);
    check(img == (EGLImageKHR)(uintptr_t)0x1234, "an NV12 import with no shim loaded: Mesa's image, no crash");

    void *shim = dlopen(argv[3], RTLD_NOW | RTLD_LOCAL);
    unsigned *calls = shim ? dlsym(shim, "calls") : NULL, *n = shim ? dlsym(shim, "last_n") : NULL;
    uint32_t *w = shim ? dlsym(shim, "last_w") : NULL, *h = shim ? dlsym(shim, "last_h") : NULL;
    uint32_t *fourcc = shim ? dlsym(shim, "last_fourcc") : NULL;
    if (!calls || !n || !w || !h || !fourcc) {
        fprintf(stderr, "no stand-in shim: %s\n", dlerror());
        return 2;
    }
    check(*calls == 0, "nothing was handed on before the shim was loaded");

    img = cik(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, nv12);
    snprintf(what, sizeof(what), "eglCreateImageKHR NV12 1920x1080: the shim got %u call(s), %c%c%c%c "
             "%ux%u, %u planes", *calls, *fourcc & 0xff, *fourcc >> 8 & 0xff, *fourcc >> 16 & 0xff,
             *fourcc >> 24, *w, *h, *n);
    check(img == (EGLImageKHR)(uintptr_t)0x1234 && *calls == 1 && *fourcc == FCC('N', 'V', '1', '2') &&
          *w == 1920 && *h == 1080 && *n == 2, what);
    EGLImage img2 = ci(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, nv12_core);
    snprintf(what, sizeof(what), "eglCreateImage NV12 1920x1080: the shim got %u more call(s), %ux%u",
             *calls - 1, *w, *h);
    check(img2 == (EGLImage)(uintptr_t)0x5678 && *calls == 2 && *w == 1920 && *h == 1080 && *n == 2, what);
    cik(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, r8);
    check(*calls == 3 && *w == 854 && *h == 480 && *n == 1, "an R8 import of 854x480 (mpv's Y plane) is handed on");
    cik(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, ab24);
    check(*calls == 3, "an AB24 import (a window's buffer) is not");
    cik(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_GL_TEXTURE_2D_KHR, NULL, nv12);
    check(*calls == 3, "another target is not");
    *fail_next = 1;
    img = cik(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, nv12);
    img2 = ci(EGL_NO_DISPLAY, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, nv12_core);
    check(img == EGL_NO_IMAGE_KHR && img2 == EGL_NO_IMAGE && *calls == 3,
          "no image from Mesa: nothing handed on, Mesa's answer back");
    return failed;
}
#endif
