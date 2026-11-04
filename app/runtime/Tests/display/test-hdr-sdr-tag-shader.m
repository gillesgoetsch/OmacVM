/*
 * test-hdr-sdr-tag-shader: the peak shader of ui/omacvm-hdr-tag.h on
 * Apple's software GL renderer only (never a real GPU: STANDARDS 14), core
 * profile as QEMU's present context, in its two passes into R32F targets
 * as ui/cocoa.m runs it. A 10-bit frame (GL_RGB10_A2, the guest's PQ
 * scanout) of SDR white (594) with one pixel of PQ 1000 nits (770) in any
 * channel, anywhere (edges and corners of the blocks, the last pixel),
 * must read back exactly 770; an all-SDR frame exactly 594; black 0.
 *   cc -fobjc-arc -I<folder with omacvm-hdr-tag.h> test-hdr-sdr-tag-shader.m -framework OpenGL
 */
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "omacvm-hdr-tag.h"

static int failures;
static GLuint prog, vao, fbo;
static GLint u_size;

static GLuint shader(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    GLint ok = 0;
    char log[1024] = "";

    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "test-hdr-sdr-tag-shader: does not compile: %s\n", log);
        failures++;
    }
    return s;
}

static GLuint target(int w, int h)
{
    GLuint t;

    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, w, h, 0, GL_RED, GL_FLOAT, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return t;
}

/* One pass: src (w x h) into dst (its block size). */
static void pass(GLuint src, int w, int h, GLuint dst)
{
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, dst, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "test-hdr-sdr-tag-shader: no R32F target\n");
        failures++;
    }
    glViewport(0, 0, omacvm_hdr_blocks(w), omacvm_hdr_blocks(h));
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, src);
    /* as ui/cocoa.m: a texture with no mipmaps is complete only without a mipmap filter */
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glUseProgram(prog);
    glUniform2i(u_size, w, h);
    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

/* The frame's highest code, as ui/cocoa.m reads it. */
static int peak_code(GLuint src, int w, int h)
{
    int w1 = omacvm_hdr_blocks(w), h1 = omacvm_hdr_blocks(h);
    int w2 = omacvm_hdr_blocks(w1), h2 = omacvm_hdr_blocks(h1);
    GLuint t1 = target(w1, h1), t2 = target(w2, h2);
    float *out = calloc((size_t)w2 * h2, sizeof(*out));

    pass(src, w, h, t1);
    pass(t1, w1, h1, t2);
    glReadPixels(0, 0, w2, h2, GL_RED, GL_FLOAT, out);
    double m = omacvm_hdr_max(out, (size_t)w2 * h2);
    free(out);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteTextures(1, &t1);
    glDeleteTextures(1, &t2);
    return (int)lround(m * 1023);
}

/* A w x h 10-bit frame of code base, one pixel (x, y) of code dot in channel ch. */
static int frame_peak(int w, int h, int base, int x, int y, int ch, int dot)
{
    uint32_t *px = malloc((size_t)w * h * sizeof(*px));
    uint32_t b = base | (uint32_t)base << 10 | (uint32_t)base << 20 | 3u << 30;
    GLuint t;

    for (size_t i = 0; i < (size_t)w * h; i++) {
        px[i] = b;
    }
    if (x >= 0) {
        uint32_t *p = &px[(size_t)y * w + x];
        *p = (*p & ~(0x3ffu << (10 * ch))) | (uint32_t)dot << (10 * ch);
    }
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB10_A2, w, h, 0, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, px);
    free(px);
    int got = peak_code(t, w, h);
    glDeleteTextures(1, &t);
    return got;
}

static void expect(int got, int want, const char *what, int w, int h, int x, int y)
{
    if (got != want) {
        fprintf(stderr, "test-hdr-sdr-tag-shader: %s %dx%d at %d,%d: code %d, not %d\n",
                what, w, h, x, y, got, want);
        failures++;
    }
}

int main(void)
{
    @autoreleasepool {
        CGLPixelFormatAttribute attrs[] = {
            kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID,
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            0
        };
        CGLPixelFormatObj pf;
        CGLContextObj ctx;
        GLint n;

        if (CGLChoosePixelFormat(attrs, &pf, &n) != kCGLNoError || !pf ||
            CGLCreateContext(pf, NULL, &ctx) != kCGLNoError) {
            fprintf(stderr, "test-hdr-sdr-tag-shader: no software GL context\n");
            return 1;
        }
        CGLDestroyPixelFormat(pf);
        CGLSetCurrentContext(ctx);

        GLuint vs = shader(GL_VERTEX_SHADER, OMACVM_HDR_PEAK_VERT);
        GLuint fs = shader(GL_FRAGMENT_SHADER, OMACVM_HDR_PEAK_FRAG);
        GLint ok = 0;
        prog = glCreateProgram();
        glAttachShader(prog, vs);
        glAttachShader(prog, fs);
        glBindAttribLocation(prog, 0, "in_position");
        glLinkProgram(prog);
        glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (!ok || failures) {
            fprintf(stderr, "test-hdr-sdr-tag-shader: the program does not link\n");
            return 1;
        }
        glUseProgram(prog);
        glUniform1i(glGetUniformLocation(prog, "image"), 0);
        u_size = glGetUniformLocation(prog, "size");
        static const GLfloat quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
        GLuint vbo;
        glGenVertexArrays(1, &vao);
        glBindVertexArray(vao);
        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
        glEnableVertexAttribArray(0);
        glGenFramebuffers(1, &fbo);

        static const int sizes[][2] = {
            { 1, 1 }, { 16, 16 }, { 17, 1 }, { 4097, 1 }, { 1, 4097 }, { 257, 255 },
            { 3456, 2234 }, { 5120, 2880 },
        };
        int checked = 0;
        for (unsigned s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
            int w = sizes[s][0], h = sizes[s][1];
            /* corners, the last pixel, block edges and an odd place */
            int spots[][2] = {
                { 0, 0 }, { w - 1, h - 1 }, { w - 1, 0 }, { 0, h - 1 },
                { MIN(15, w - 1), MIN(16, h - 1) }, { w / 2 | 1, h / 3 | 1 },
                { MIN(255, w - 1), MIN(256, h - 1) },
            };
            expect(frame_peak(w, h, 594, -1, 0, 0, 0), 594, "all SDR white", w, h, -1, -1);
            for (unsigned k = 0; k < sizeof(spots) / sizeof(spots[0]); k++) {
                int x = MIN(MAX(spots[k][0], 0), w - 1), y = MIN(MAX(spots[k][1], 0), h - 1);
                expect(frame_peak(w, h, 594, x, y, k % 3, 770), 770, "one HDR pixel", w, h, x, y);
                checked++;
            }
        }
        expect(frame_peak(64, 64, 0, -1, 0, 0, 0), 0, "black", 64, 64, -1, -1);
        expect(frame_peak(64, 64, 0, 63, 63, 2, 1023), 1023, "10000 nits in blue", 64, 64, 63, 63);
        if (failures) {
            fprintf(stderr, "test-hdr-sdr-tag-shader: %d failed\n", failures);
            return 1;
        }
        printf("test-hdr-sdr-tag-shader: ok (%d frames with one HDR pixel, 8 sizes up to 5120x2880)\n",
               checked);
    }
    return 0;
}
