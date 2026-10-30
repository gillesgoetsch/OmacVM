/*
 * test-present-tiles-gl: the tiled present's tile draw on a GL renderer
 * (omacvm-cocoa-present-tiles.patch, cocoa_gl_present_tiles, with the tile
 * program from ui/omacvm-present-tiles.h). A fixed frame (a pattern, not
 * fuzzing: STANDARDS 14) is drawn whole with QEMU's blit, as the whole
 * surfaces get it, and each of its tiles into an IOSurface of the tile's
 * size, as the tiled present draws them. Every tile must equal its part of
 * the whole frame, pixel for pixel (colour; the window ignores alpha), at
 * 5120x2880, 6016x3384, 4480x2520 and 3024x1964 (8-bit surfaces, both
 * flips; with --gpu also 6144x4096, the largest grid, which takes over 1 GB
 * on the software renderer), and at 5120x2880 in half-float surfaces from a
 * 10-bit frame (the HDR path). Each texel of the 8-bit frame carries its own x (one
 * pass) or y (the other), so a wrong tile says which frame pixels it shows.
 *
 * Apple's OpenGL (4.1 on Metal) squeezes a viewport that starts more than
 * 4096 pixels outside its target. 3.2.14 drew every tile as the frame's
 * quad moved by -x, -y, so on Apple's GPUs the tiles right of x 4096 came
 * out squeezed (5120x2880: 36 of 240 on an M1 Max). The software renderer
 * draws that right, so the difference shows only on a GPU.
 *
 *   test-present-tiles-gl                  Apple's software renderer (CI, the runtime build)
 *   test-present-tiles-gl --gpu            the Mac's GPU (rows on a test Mac); first runs
 *                                          3.2.14's draw at 5120x2880 and says what it gives
 *   test-present-tiles-gl --gpu --before   3.2.14's draw as the one tested (fails on Apple's GPUs)
 * Exit 0: every tile of the tested draw equals the whole frame; 1: not; 2: no GL or a usage error.
 *   cc -fobjc-arc -I<folder with omacvm-present-tiles.h> test-present-tiles-gl.m \
 *      -framework Foundation -framework OpenGL -framework IOSurface
 */
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLIOSurface.h>
#import <IOSurface/IOSurface.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "omacvm-present-tiles.h"

/* QEMU's blit (ui/shader/texture-blit.vert, -flip.vert, .frag) as ui/shader.c builds it on desktop GL. */
static const char *qemu_vert =
    "#version 140\n"
    "in vec2  in_position;\n"
    "out vec2 ex_tex_coord;\n"
    "void main(void) {\n"
    "    gl_Position = vec4(in_position, 0.0, 1.0);\n"
    "    ex_tex_coord = vec2(1.0 + in_position.x, 1.0 - in_position.y) * 0.5;\n"
    "}\n";
static const char *qemu_vert_flip =
    "#version 140\n"
    "in vec2  in_position;\n"
    "out vec2 ex_tex_coord;\n"
    "void main(void) {\n"
    "    gl_Position = vec4(in_position, 0.0, 1.0);\n"
    "    ex_tex_coord = vec2(1.0 + in_position.x, 1.0 + in_position.y) * 0.5;\n"
    "}\n";
static const char *qemu_frag =
    "#version 140\n"
    "uniform sampler2D image;\n"
    "in  mediump vec2 ex_tex_coord;\n"
    "out mediump vec4 out_frag_color;\n"
    "void main(void) {\n"
    "     out_frag_color = texture(image, ex_tex_coord);\n"
    "}\n";

static GLuint qemu_prog[2], qemu_vao;   /* QEMU's blit: plain, flip; its quad */
static GLuint tile_prog, tile_vao;      /* the tile program and its own quad (present_tile_program) */
static GLint tile_u_rect, tile_u_flip;
static GLuint fbo;
static bool before;                     /* the draw tested: 3.2.14's instead of the tile program */
static CGLContextObj ctx;

static GLuint compile(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    GLint ok = 0;
    char log[1024] = "";

    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "test-present-tiles-gl: a shader does not compile: %s\n", log);
        exit(1);
    }
    return s;
}

static GLuint link_program(const char *vs, const char *fs, bool loc0)
{
    GLuint p = glCreateProgram();
    GLint ok = 0;

    glAttachShader(p, compile(GL_VERTEX_SHADER, vs));
    glAttachShader(p, compile(GL_FRAGMENT_SHADER, fs));
    if (loc0) {
        glBindAttribLocation(p, 0, "in_position");
    }
    glLinkProgram(p);
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        fprintf(stderr, "test-present-tiles-gl: a program does not link\n");
        exit(1);
    }
    return p;
}

static GLuint quad(GLint loc)
{
    static const GLfloat corners[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
    GLuint vao, vbo;

    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(corners), corners, GL_STATIC_DRAW);
    glVertexAttribPointer(loc, 2, GL_FLOAT, GL_FALSE, 0, 0);
    glEnableVertexAttribArray(loc);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindVertexArray(0);
    return vao;
}

static void programs(void)
{
    /* QEMU's: one quad for both programs, at the plain one's location (qemu_gl_init_texture_blit) */
    qemu_prog[0] = link_program(qemu_vert, qemu_frag, false);
    qemu_prog[1] = link_program(qemu_vert_flip, qemu_frag, false);
    qemu_vao = quad(glGetAttribLocation(qemu_prog[0], "in_position"));
    /* the tile program, as present_tile_program makes it */
    tile_prog = link_program(OMACVM_PT_VERT, OMACVM_PT_FRAG, true);
    glUseProgram(tile_prog);
    glUniform1i(glGetUniformLocation(tile_prog, "image"), 0);
    tile_u_rect = glGetUniformLocation(tile_prog, "rect");
    tile_u_flip = glGetUniformLocation(tile_prog, "yflip");
    glUseProgram(0);
    tile_vao = quad(0);
    glGenFramebuffers(1, &fbo);
}

/* An IOSurface as a rectangle texture, as cocoa_gl_present_tile_buf makes the tile surfaces. */
typedef struct Target {
    IOSurfaceRef s;
    GLuint tex;
    uint32_t w, h;
    bool half;
} Target;

static void target_make(Target *t, uint32_t w, uint32_t h, bool half)
{
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(w),
        (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: half ? @8 : @4,
        (id)kIOSurfacePixelFormat: @(half ? 'RGhA' : 'BGRA'),
    };
    t->s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!t->s) {
        fprintf(stderr, "test-present-tiles-gl: no IOSurface %ux%u\n", w, h);
        exit(2);
    }
    glGenTextures(1, &t->tex);
    glBindTexture(GL_TEXTURE_RECTANGLE, t->tex);
    if (CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE, half ? GL_RGBA16F : GL_RGBA, w, h,
                               half ? GL_RGBA : GL_BGRA,
                               half ? GL_HALF_FLOAT : GL_UNSIGNED_INT_8_8_8_8_REV,
                               t->s, 0) != kCGLNoError) {
        fprintf(stderr, "test-present-tiles-gl: CGLTexImageIOSurface2D %ux%u failed\n", w, h);
        exit(2);
    }
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);
    t->w = w;
    t->h = h;
    t->half = half;
}

static void target_free(Target *t)
{
    if (t->s) {
        glDeleteTextures(1, &t->tex);
        CFRelease(t->s);
    }
    memset(t, 0, sizeof(*t));
}

/*
 * The frame: an 8-bit texel carries its own x (axis 0) or y (axis 1) in
 * R + 256 G, with B a mark (0 = nothing drawn there); a 10-bit texel
 * carries x and y (R x, G y, B their high bits).
 */
static GLuint frame(uint32_t fw, uint32_t fh, int axis, bool ten)
{
    uint32_t *p = malloc((size_t)fw * fh * 4);
    GLuint t;

    for (uint32_t y = 0; y < fh; y++) {
        for (uint32_t x = 0; x < fw; x++) {
            uint32_t v = axis ? y : x;
            p[(size_t)y * fw + x] = ten ?
                (x & 0x3ff) | (y & 0x3ff) << 10 | ((x >> 10) | (y >> 10) << 3) << 20 | 1u << 30 :
                (v & 0xff) | (v >> 8) << 8 | (axis ? 0xa5u : 0x5au) << 16 | 0x33u << 24;
        }
    }
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexImage2D(GL_TEXTURE_2D, 0, ten ? GL_RGB10_A2 : GL_RGBA8, fw, fh, 0, GL_RGBA,
                 ten ? GL_UNSIGNED_INT_2_10_10_10_REV : GL_UNSIGNED_BYTE, p);
    glBindTexture(GL_TEXTURE_2D, 0);
    free(p);
    return t;
}

static void source(GLuint src)
{
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, src);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
}

static void attach(Target *t)
{
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, t->tex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "test-present-tiles-gl: a %ux%u target is not complete\n", t->w, t->h);
        exit(2);
    }
}

static void clear(void)
{
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE);
}

/* A whole frame, as cocoa_gl_present draws one (and =check its reference): QEMU's blit over all of it. */
static void draw_whole(GLuint src, Target *t, bool flip)
{
    attach(t);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    source(src);
    glViewport(0, 0, t->w, t->h);
    clear();
    glUseProgram(qemu_prog[flip]);
    glBindVertexArray(qemu_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
}

/* Tile T of grid G into its surface, as cocoa_gl_present_tiles draws it (its GL calls; before: 3.2.14's). */
static void draw_tile(GLuint src, const OmacvmPTGrid *g, unsigned t, Target *tt, bool flip)
{
    uint32_t x, y, tw, th;
    GLfloat rect[4];

    omacvm_pt_rect(g, t, &x, &y, &tw, &th);
    attach(tt);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    source(src);
    if (before) {
        glViewport(-(GLint)x, -(GLint)y, g->fw, g->fh);
        clear();
        glUseProgram(qemu_prog[flip]);
        glBindVertexArray(qemu_vao);
    } else {
        glUseProgram(tile_prog);
        glUniform1f(tile_u_flip, flip ? 1.0f : 0.0f);
        glBindVertexArray(tile_vao);
        omacvm_pt_tex_rect(g, t, rect);
        glViewport(0, 0, tw, th);
        clear();
        glUniform4fv(tile_u_rect, 1, rect);
    }
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
}

/* W x H pixels of T at X, Y (rows from its first) into OUT, at the surface's own precision. */
static void read_back(Target *t, uint32_t x, uint32_t y, uint32_t w, uint32_t h, void *out)
{
    attach(t);
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(x, y, w, h, t->half ? GL_RGBA : GL_BGRA,
                 t->half ? GL_HALF_FLOAT : GL_UNSIGNED_INT_8_8_8_8_REV, out);
}

/* The x or y an 8-bit pixel (B, G, R, A in memory) carries, -1 when nothing was drawn there. */
static long carried(const uint8_t *px)
{
    return px[0] == 0x5a || px[0] == 0xa5 ? (long)px[2] | (long)px[1] << 8 : -1;
}

/* Every tile of a FW x FH frame against the whole frame. Returns how many differ. */
static int frame_test(uint32_t fw, uint32_t fh, bool flip, bool half)
{
    OmacvmPTGrid g = omacvm_pt_grid(fw, fh);
    unsigned n = g.cols * g.rows;
    size_t px = half ? 8 : 4, colour = half ? 6 : 3;
    uint8_t *ref = malloc((size_t)fw * fh * px), *tb = malloc((size_t)OMACVM_PT_SIZE * OMACVM_PT_SIZE * px);
    long *first = calloc(n, sizeof(long)), *last = calloc(n, sizeof(long));
    uint64_t *diff = calloc(n, sizeof(uint64_t));
    Target whole = { 0 }, tiles[4] = { { 0 } };
    int bad = 0, shown = 0;

    target_make(&whole, fw, fh, half);
    for (int axis = 0; axis < (half ? 1 : 2); axis++) {
        GLuint src = frame(fw, fh, axis, half);
        draw_whole(src, &whole, flip);
        read_back(&whole, 0, 0, fw, fh, ref);
        for (unsigned t = 0; t < n; t++) {
            uint32_t x, y, tw, th;
            omacvm_pt_rect(&g, t, &x, &y, &tw, &th);
            /* one surface per tile size: full, last column, last row, the corner */
            Target *tt = &tiles[(tw < OMACVM_PT_SIZE) | (th < OMACVM_PT_SIZE) << 1];
            if (!tt->s) {
                target_make(tt, tw, th, half);
            }
            draw_tile(src, &g, t, tt, flip);
            read_back(tt, 0, 0, tw, th, tb);
            for (uint32_t j = 0; j < th; j++) {
                for (uint32_t i = 0; i < tw; i++) {
                    diff[t] += memcmp(tb + ((size_t)j * tw + i) * px,
                                      ref + ((size_t)(y + j) * fw + x + i) * px, colour) != 0;
                }
            }
            if (axis == 0 && !half) {
                first[t] = carried(tb);
                last[t] = carried(tb + (size_t)(tw - 1) * px);
            }
        }
        glDeleteTextures(1, &src);
    }
    for (unsigned t = 0; t < n; t++) {
        bad += diff[t] != 0;
    }
    printf("  %ux%u (%ux%u tiles), %s, flip %d, %s: %d of %u tiles differ from the whole frame\n",
           fw, fh, g.cols, g.rows, half ? "half-float from 10-bit" : "8-bit", flip,
           before ? "3.2.14's draw (the frame's quad moved by -x, -y)" : "tile program (viewport in the tile)",
           bad, n);
    for (unsigned t = 0; t < n; t++) {
        if (diff[t] && shown++ < 12) {
            uint32_t x, y, tw, th;
            omacvm_pt_rect(&g, t, &x, &y, &tw, &th);
            if (half) {
                printf("    tile c%u r%u (x %u, y %u): %llu pixels differ\n", t % g.cols, t / g.cols,
                       x, y, (unsigned long long)diff[t]);
            } else {
                printf("    tile c%u r%u (x %u, y %u): %llu values differ; it shows frame x %ld..%ld "
                       "(whole: %u..%u)\n", t % g.cols, t / g.cols, x, y,
                       (unsigned long long)diff[t], first[t], last[t], x, x + tw - 1);
            }
        }
    }
    target_free(&whole);
    for (int i = 0; i < 4; i++) {
        target_free(&tiles[i]);
    }
    free(ref);
    free(tb);
    free(first);
    free(last);
    free(diff);
    return bad;
}

int main(int argc, char **argv)
{
    bool gpu = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--gpu")) {
            gpu = true;
        } else if (!strcmp(argv[i], "--before")) {
            before = true;
        } else {
            fprintf(stderr, "usage: test-present-tiles-gl [--gpu [--before]]\n");
            return 2;
        }
    }
    if (before && !gpu) {
        /* on the software renderer 3.2.14's draw left whole tiles empty at random (not chased) */
        fprintf(stderr, "test-present-tiles-gl: --before needs --gpu\n");
        return 2;
    }
    @autoreleasepool {
        CGLPixelFormatAttribute sw[] = {
            kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID,
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            0
        };
        CGLPixelFormatAttribute hw[] = {
            kCGLPFAAccelerated,
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            0
        };
        CGLPixelFormatObj pf;
        GLint np;

        if (CGLChoosePixelFormat(gpu ? hw : sw, &pf, &np) != kCGLNoError || !pf ||
            CGLCreateContext(pf, NULL, &ctx) != kCGLNoError) {
            fprintf(stderr, "test-present-tiles-gl: no %s GL context\n", gpu ? "GPU" : "software");
            return 2;
        }
        CGLDestroyPixelFormat(pf);
        CGLSetCurrentContext(ctx);
        printf("test-present-tiles-gl: %s | %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
        programs();

        static const uint32_t sizes[][2] = {
            { 5120, 2880 },     /* 5K full screen (the user's LG UltraFine 5K) */
            { 6016, 3384 },     /* 6K (Pro Display XDR) */
            { 4480, 2520 },     /* the 24-inch iMac */
            { 3024, 1964 },     /* MacBook Pro 14-inch: no tile past x 4096 */
            { 6144, 4096 },     /* the largest grid: --gpu only */
        };
        unsigned nsizes = sizeof(sizes) / sizeof(sizes[0]) - !gpu;
        if (gpu && !before) {
            before = true;
            int b = frame_test(5120, 2880, false, false);
            before = false;
            if (b) {
                printf("before: 3.2.14's draw: %d of 240 tiles differ at 5120x2880 on this GPU\n", b);
            } else {
                printf("before: 3.2.14's draw: no tile differs at 5120x2880: this driver does not show "
                       "the squeeze, so this run makes no before/after claim\n");
            }
        }
        int bad = 0, runs = 0;
        for (unsigned i = 0; i < nsizes; i++) {
            for (int flip = 0; flip < 2; flip++) {
                bad += frame_test(sizes[i][0], sizes[i][1], flip, false) != 0;
                runs++;
            }
        }
        for (int flip = 0; flip < 2; flip++) {
            bad += frame_test(5120, 2880, flip, true) != 0;
            runs++;
        }
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(ctx);
        if (bad) {
            printf("test-present-tiles-gl: FAIL: %s: tiles differ from the whole frame in %d of %d runs\n",
                   before ? "3.2.14's draw" : "the tile program", bad, runs);
            return 1;
        }
        printf("test-present-tiles-gl: %s: every tile equals the whole frame (%u sizes, both flips, "
               "8-bit and half-float; %d runs)\n", before ? "3.2.14's draw" : "the tile program",
               nsizes, runs);
    }
    return 0;
}
