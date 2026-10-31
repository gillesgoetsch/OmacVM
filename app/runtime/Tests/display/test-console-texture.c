/*
 * Test for qemu-cocoa-gl-console-texture-lazy.patch: a console's GL texture
 * is made when it is first drawn, not at every switch.
 *
 * test-console-texture.sh takes the display listeners' texture functions from
 * a ui/cocoa.m (cocoa_gl_update, cocoa_gl_switch, the extra displays'
 * omacvm_head_gfx_update and omacvm_head_gfx_switch, the boot logo's
 * omacvm_splash_wanted, and with the patch omacvm_console_tex_*) and QEMU's
 * texture helpers from ui/console-gl.c, and builds them here with a GL stub
 * that counts the bytes each glTexImage2D / glTexSubImage2D uploads. Then
 * the listener calls of a set scanout run in order, as QEMU makes them:
 *   - a GL scanout (virgl): switch to a new surface, the scanout texture,
 *     display off (the placeholder and its full update) and on again:
 *     nothing uploaded (3.2.16: W x H x 4 at every switch);
 *   - the placeholder with the boot logo off: one upload at its size;
 *   - a 2D surface (firmware, boot console): nothing at the switch, one
 *     whole upload at its first update, then only the updated boxes; or
 *     one whole upload at a present before any update.
 * The same for an extra display's listener, and OMACVM_CONSOLE_TEXTURE=eager
 * (the old way: at every switch). No QEMU, no GL, no display.
 *
 *   cc -fblocks -DHAVE_TEX_READY=0|1 -IDIR test-console-texture.c -o t && ./t [lazy|eager|old]
 *   lazy (default): every check; eager: OMACVM_CONSOLE_TEXTURE=eager uploads at
 *   the switch; old: the code before the patch (the sh wants it to fail).
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <assert.h>

/* ---- GL stub ---------------------------------------------------------- */
typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
#define GL_TEXTURE_2D 0x0DE1
#define GL_UNSIGNED_BYTE 0x1401
#define GL_RGB 0x1907
#define GL_RGBA 0x1908
#define GL_BGRA_EXT 0x80E1
#define GL_UNSIGNED_SHORT_5_6_5 0x8363
#define GL_UNPACK_ROW_LENGTH_EXT 0x0CF2
#define GL_TEXTURE_SWIZZLE_A 0x8E45
#define GL_ONE 1
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_LINEAR 0x2601

static uint64_t up_bytes;      /* bytes uploaded since the last reset */
static unsigned up_whole;      /* glTexImage2D calls with data */
static unsigned tex_live;      /* textures made and not deleted */
static GLuint tex_next = 1;
static GLint row_length;

static void glGenTextures(GLsizei n, GLuint *t) { for (GLsizei i = 0; i < n; i++) { t[i] = tex_next++; tex_live++; } }
static void glDeleteTextures(GLsizei n, const GLuint *t) { (void)t; tex_live -= (unsigned)n; }
static void glEnable(GLenum c) { (void)c; }
static void glBindTexture(GLenum t, GLuint id) { (void)t; (void)id; }
static void glTexParameteri(GLenum t, GLenum p, GLint v) { (void)t; (void)p; (void)v; }
static void glPixelStorei(GLenum p, GLint v) { if (p == GL_UNPACK_ROW_LENGTH_EXT) row_length = v; }
static void glTexImage2D(GLenum t, GLint l, GLint ifmt, GLsizei w, GLsizei h, GLint b, GLenum f, GLenum ty,
                         const void *data)
{
    (void)t; (void)l; (void)ifmt; (void)b; (void)f; (void)ty;
    if (data) {
        up_bytes += (uint64_t)w * h * 4;
        up_whole++;
    }
}
static void glTexSubImage2D(GLenum t, GLint l, GLint x, GLint y, GLsizei w, GLsizei h, GLenum f, GLenum ty,
                            const void *data)
{
    (void)t; (void)l; (void)x; (void)y; (void)f; (void)ty; (void)data;
    up_bytes += (uint64_t)w * h * 4;
}
static int epoxy_is_desktop_gl(void) { return 1; }

/* ---- QEMU stand-ins ----------------------------------------------------- */
#define QEMU_IS_ALIGNED(n, m) (((n) % (m)) == 0)
typedef enum { PIXMAN_BE_b8g8r8x8 = 1, PIXMAN_BE_b8g8r8a8, PIXMAN_BE_x8r8g8b8, PIXMAN_BE_a8r8g8b8,
               PIXMAN_r5g6b5 } pixman_format_code_t;
typedef struct DisplaySurface {
    int w, h;
    bool placeholder;
    GLuint texture;
    uint8_t px[4];             /* the data pointer only (never read) */
} DisplaySurface;
static int surface_width(DisplaySurface *s) { return s->w; }
static int surface_height(DisplaySurface *s) { return s->h; }
static int surface_stride(DisplaySurface *s) { return s->w * 4; }
static int surface_bytes_per_pixel(DisplaySurface *s) { (void)s; return 4; }
static pixman_format_code_t surface_format(DisplaySurface *s) { (void)s; return PIXMAN_BE_x8r8g8b8; }
static void *surface_data(DisplaySurface *s) { return s->px; }
static bool surface_is_placeholder(DisplaySurface *s) { return s->placeholder; }
typedef struct QemuGLShader { int unused; } QemuGLShader;
static QemuGLShader shader;
static struct { QemuGLShader *gls; } dgc = { &shader };
typedef struct DisplayChangeListener { int unused; } DisplayChangeListener;
typedef struct { GLuint id; } DisplayGLTexture;
typedef DisplayGLTexture (*DisplayGLTextureBorrower)(uint32_t id);
static DisplayGLTexture borrow_stub(uint32_t id) { return (DisplayGLTexture){ id }; }

static char last_info[256], ct_line[256];   /* the last qemu.log line, the console texture's */
static void info_report(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(last_info, sizeof(last_info), fmt, ap);
    va_end(ap);
    if (strstr(last_info, "console texture:")) {
        memcpy(ct_line, last_info, sizeof(ct_line));
    }
}

typedef void *CGLContextObj;
static CGLContextObj current_ctx;
static CGLContextObj CGLGetCurrentContext(void) { return current_ctx; }
static void CGLSetCurrentContext(CGLContextObj c) { current_ctx = c; }
typedef void (^CodeBlock)(void);
static unsigned ctx_uses;
static void with_gl_view_ctx(CodeBlock block)
{
    ctx_uses++;
    current_ctx = (CGLContextObj)&ctx_uses;
    block();
    current_ctx = NULL;
}

/* The main listener's state in ui/cocoa.m. */
static DisplaySurface *surface;
static DisplayGLTextureBorrower gl_scanout_borrow;
static bool gl_dirty, omacvm_hold_dirty;
static int omacvm_splash_on = -1;
static void cocoa_refresh_activity(void) {}
static void omacvm_splash_update(void) {}
static void omacvm_gp_guest_frame(void) {}
static void cocoa_switch(DisplayChangeListener *dcl, DisplaySurface *new_surface) { (void)dcl; surface = new_surface; }

/* An extra display's listener (only the fields the texture code uses; the listener first). */
typedef struct OmacVMHead {
    DisplayChangeListener dcl;
    DisplaySurface *surface;
    DisplayGLTextureBorrower borrow;
    bool dirty;
} OmacVMHead;

#include "texture-code.inc"    /* console-gl.c's texture helpers, then cocoa.m's listeners */

/* ---- the sequences ------------------------------------------------------ */
static int fails;
#define W 5120
#define H 2880
#define WHOLE ((uint64_t)W * H * 4)

static void expect(const char *what, uint64_t want_bytes, uint64_t got)
{
    bool ok = got == want_bytes;
    printf("%s %-72s %llu bytes (want %llu)\n", ok ? "ok  " : "FAIL", what,
           (unsigned long long)got, (unsigned long long)want_bytes);
    fails += !ok;
}

static void reset(void) { up_bytes = 0; up_whole = 0; }

/* A reader on QEMU's thread (the present's branch without a GL scanout). */
static bool present_reader(DisplaySurface *s)
{
#if HAVE_TEX_READY
    return omacvm_console_tex_ready(s, false);
#else
    return s && s->texture;
#endif
}

static DisplaySurface *make(int w, int h, bool placeholder)
{
    DisplaySurface *s = calloc(1, sizeof(*s));
    s->w = w;
    s->h = h;
    s->placeholder = placeholder;
    return s;
}

/* qemu_console_set_surface(): the switch, then a full update only for the placeholder. */
static void main_set(DisplaySurface *s)
{
    cocoa_gl_switch(NULL, s);
    if (s->placeholder) {
        cocoa_gl_update(NULL, 0, 0, s->w, s->h);
    }
}

static void head_set(OmacVMHead *hd, DisplaySurface *s)
{
    omacvm_head_gfx_switch(&hd->dcl, s);
    if (s->placeholder) {
        omacvm_head_gfx_update(&hd->dcl, 0, 0, s->w, s->h);
    }
}

static void expect_true(const char *what, bool got)
{
    printf("%s %s\n", got ? "ok  " : "FAIL", what);
    fails += !got;
}

/* OMACVM_CONSOLE_TEXTURE=eager: at every switch, as 3.2.16. */
static int eager_mode(void)
{
    setenv("OMACVM_CONSOLE_TEXTURE", "eager", 1);
    surface = make(640, 480, true);
    reset();
    main_set(make(W, H, false));
    gl_scanout_borrow = borrow_stub;
    expect("eager: switch to 5120x2880 uploads it (as 3.2.16)", WHOLE, up_bytes);
    expect_true("eager: says so in qemu.log", strstr(ct_line, "at every switch (OMACVM_CONSOLE_TEXTURE=eager)") != NULL);
    printf("%s\n", fails ? "eager: FAIL" : "eager: all ok");
    return fails ? 1 : 0;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "lazy";
    if (!strcmp(mode, "eager")) {
        return eager_mode();
    }
    unsetenv("OMACVM_CONSOLE_TEXTURE");
    setenv("OMACVM_BOOT_SPLASH", "1", 1);

    /* (a) GL scanout (virgl): a mode set, then display off and on, 3 times. */
    surface = make(640, 480, true);
    reset();
    main_set(make(W, H, false));             /* qemu_console_resize */
    gl_scanout_borrow = borrow_stub;         /* qemu_console_gl_scanout_texture */
    expect("GL scanout: switch to 5120x2880, scanout texture", 0, up_bytes);
    reset();
    for (int i = 0; i < 3; i++) {
        main_set(make(W, H, true));          /* set_scanout 0: the placeholder at the old size */
        gl_scanout_borrow = NULL;            /* ... scanout disable */
        main_set(make(W, H, false));         /* display on: resize */
        gl_scanout_borrow = borrow_stub;
    }
    expect("GL scanout: 3 display off/on cycles at 5120x2880 (boot logo on)", 0, up_bytes);

    /* (b) the placeholder without the boot logo (OMACVM_BOOT_SPLASH=0): drawn, so one upload. */
    omacvm_splash_on = -1;
    setenv("OMACVM_BOOT_SPLASH", "0", 1);
    gl_scanout_borrow = NULL;
    reset();
    main_set(make(640, 480, true));
    expect("placeholder, boot logo off: one 640x480 upload", 640 * 480 * 4, up_bytes);
    expect_true("placeholder, boot logo off: the present has it to draw", present_reader(surface));
    omacvm_splash_on = -1;
    setenv("OMACVM_BOOT_SPLASH", "1", 1);
    reset();
    main_set(make(640, 480, true));
    expect("placeholder, boot logo on: nothing", 0, up_bytes);

    /* (c) a 2D surface (firmware, boot console): whole at its first update, then the boxes. */
    reset();
    main_set(make(1920, 1080, false));
    expect("2D: switch to 1920x1080", 0, up_bytes);
    reset();
    cocoa_gl_update(NULL, 10, 10, 100, 50);
    expect("2D: first update (100x50): one whole 1920x1080 upload", 1920ull * 1080 * 4, up_bytes);
    reset();
    cocoa_gl_update(NULL, 10, 10, 100, 50);
    expect("2D: next update: only the 100x50 box", 100 * 50 * 4, up_bytes);
    reset();
    main_set(make(1920, 1080, false));
    expect("2D: switch again", 0, up_bytes);
    bool drawn = present_reader(surface);
    expect("2D: a present before any update: one whole upload", 1920ull * 1080 * 4, up_bytes);
    expect_true("2D: ... and the present draws it", drawn);
    reset();
    cocoa_gl_update(NULL, 0, 0, 8, 8);
    expect("2D: then the update: only its 8x8 box", 8 * 8 * 4, up_bytes);

    /* (d) an extra display's listener: the same rules. */
    OmacVMHead hd = { .surface = make(640, 480, true) };
    reset();
    head_set(&hd, make(W, H, false));
    hd.borrow = borrow_stub;
    head_set(&hd, make(W, H, true));
    hd.borrow = NULL;
    head_set(&hd, make(W, H, false));
    hd.borrow = borrow_stub;
    expect("extra display, GL scanout: switch, display off and on", 0, up_bytes);
    hd.borrow = NULL;
    reset();
    head_set(&hd, make(1920, 1080, false));
    expect("extra display, 2D: switch", 0, up_bytes);
    omacvm_head_gfx_update(&hd.dcl, 0, 0, 16, 16);
    expect("extra display, 2D: one whole upload at the first update", 1920ull * 1080 * 4, up_bytes);

    expect_true("qemu.log says how the console texture is made", strstr(ct_line, "made when first drawn") != NULL);

    if (fails) {
        printf("%d check(s) failed%s\n", fails, !strcmp(mode, "old") ? " (the code before the patch)" : "");
    } else {
        printf("all ok\n");
    }
    return fails ? 1 : 0;
}
