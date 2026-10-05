/* Test for qemu-cocoa-gl-view-flush.patch: with_gl_view_ctx(), taken from the
 * patched ui/cocoa.m by the build, must leave no texture work unflushed on
 * QEMU's view context.
 *
 * Why: nothing else flushes that context, and Apple's GL keeps the memory of
 * large textures made, deleted or uploaded there until it is flushed. Every
 * guest mode change (cocoa_gl_switch) left a whole screen texture behind; a
 * guest switching modes in a loop used up the Mac's memory.
 *
 * The test counts every texture allocation and upload made inside
 * with_gl_view_ctx() and clears the count when glFlush() runs on the view
 * context. After each call the count must be 0. The leak itself only shows on
 * the GPU driver (Tests/display/view-texture-churn.c measures it); this test
 * runs on Apple's software renderer only and needs no VM.
 *
 *   awk '/^static void with_gl_view_ctx\(CodeBlock block\)$/,/^}$/' \
 *     ui/cocoa.m > DIR/with-gl-view-ctx.inc
 *   cc -fblocks -IDIR test-gl-view-flush.c -framework OpenGL -o t && ./t
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>

#include "../virgl/soft-gl.h"

typedef void (^CodeBlock)(void);
typedef void *QEMUGLContext;
static QEMUGLContext gl_view_ctx;

/* Texture allocations and uploads on the view context since its last flush. */
static int unflushed;

static __attribute__((unused)) void counted_flush(void)
{
    if (CGLGetCurrentContext() == (CGLContextObj)gl_view_ctx) {
        unflushed = 0;
    }
    glFlush();
}

#define glFlush counted_flush
#include "with-gl-view-ctx.inc"
#undef glFlush

static int failures;

static void check(int i, const char *what)
{
    GLenum err;

    if (unflushed) {
        fprintf(stderr, "FAIL switch %d: %s left %d texture operation(s) unflushed on the "
                "view context\n", i, what, unflushed);
        failures++;
    }
    if (CGLGetCurrentContext() != NULL) {
        fprintf(stderr, "FAIL switch %d: %s left a context current\n", i, what);
        failures++;
    }
    CGLSetCurrentContext((CGLContextObj)gl_view_ctx);
    err = glGetError();
    CGLSetCurrentContext(NULL);
    if (err != GL_NO_ERROR) {
        fprintf(stderr, "FAIL switch %d: %s: GL error 0x%x\n", i, what, err);
        failures++;
    }
    unflushed = 0;
}

int main(void)
{
    static unsigned char pixels[320 * 200 * 4];
    __block GLuint texture = 0;

    gl_view_ctx = soft_gl_context(NULL);
    if (!gl_view_ctx) {
        fprintf(stderr, "no software renderer context\n");
        return 1;
    }
    CGLSetCurrentContext((CGLContextObj)gl_view_ctx);
    soft_gl_require();
    CGLSetCurrentContext(NULL);

    for (int i = 0; i < 64; i++) {
        const int w = (i & 1) ? 320 : 256, h = (i & 1) ? 200 : 160;

        /* cocoa_gl_switch: the old surface texture goes, the new one comes. */
        with_gl_view_ctx(^{
            if (texture) {
                glDeleteTextures(1, &texture);
                unflushed++;
            }
            glGenTextures(1, &texture);
            glBindTexture(GL_TEXTURE_2D, texture);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, w);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            unflushed++;
        });
        check(i, "surface switch");

        /* cocoa_gl_update: a dirty rectangle of the surface is uploaded. */
        with_gl_view_ctx(^{
            glBindTexture(GL_TEXTURE_2D, texture);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, w);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            unflushed++;
        });
        check(i, "surface update");
    }

    if (failures) {
        fprintf(stderr, "test-gl-view-flush: %d failure(s)\n", failures);
        return 1;
    }
    printf("test-gl-view-flush: ok (64 switches + 64 updates, nothing left unflushed)\n");
    return 0;
}
