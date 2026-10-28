// passbench: what one display-path pass costs on this Mac's OpenGL (Apple's GL on Metal), without a VM.
// It does QEMU's present (scanout texture -> IOSurface, as qemu-cocoa-gl-present-iosurface.patch) or the
// VideoToolbox plane copy (NV12 IOSurface -> R8/RG8 textures, as virgl-videotoolbox-decode.patch) at a fixed
// rate, offscreen (no window), and prints the GPU time it used (its own AGXDeviceUserClient AppUsage).
// Modes:
//   none       fence + flush only (the floor)
//   today      the present as shipped: clear, alpha masked, full-screen textured quad (flip)
//   noclear    full quad, no clear, alpha masked
//   nomask     full quad, no clear, no alpha mask
//   scissor    today's draw, scissored to RECT (no clear): a partial present by scissor
//   quad       a quad over RECT only (viewport = RECT), no clear, alpha masked
//   quadnm     the same without the alpha mask
//   blit       glBlitFramebuffer of RECT (no flip)
//   blitfull   glBlitFramebuffer of the whole frame (no flip)
//   blitflip   glBlitFramebuffer of the whole frame, flipped
//   flushes    RW scissored 8x8 draws per frame, each followed by glFlush (RH unused)
//   draws      the same RW draws with one flush at the end
//   nv12       the video copy: Y and UV planes of a WxH NV12 IOSurface into R8/RG8 textures (2 blits)
//   nv12edge   the same into planes rounded up to 16 as Mesa makes them, plus the edge-fill blits
//              (virgl-video-plane-edge.patch: up to 3 more blits per plane)
//   nv12draw   the same result as nv12edge in one draw per plane (texel coordinates clamped to the picture)
// Usage: passbench MODE W H HZ SECS [RW RH]   (RECT = RW x RH at the middle; default 64x64)
// Build: clang -O2 -fobjc-arc -framework OpenGL -framework IOSurface -framework CoreVideo -framework Foundation
//        -framework IOKit passbench.m -o passbench
#define GL_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#import <IOKit/IOKitLib.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/gl3.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NSURF 5

static uint64_t gpu_ns_self(void) {   // sum of accumulatedGPUTime of this pid's AGX user clients
    uint64_t sum = 0; io_iterator_t it; io_object_t o; char want[64];
    snprintf(want, sizeof want, "pid %d,", getpid());
    // User clients are not registered services: walk the registry.
    if (IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS)
        return 0;
    while ((o = IOIteratorNext(it))) {
        if (!IOObjectConformsTo(o, "AGXDeviceUserClient")) { IOObjectRelease(o); continue; }
        CFTypeRef cr = IORegistryEntryCreateCFProperty(o, CFSTR("IOUserClientCreator"), NULL, 0);
        char buf[256] = "";
        if (cr && CFGetTypeID(cr) == CFStringGetTypeID()) CFStringGetCString(cr, buf, sizeof buf, kCFStringEncodingUTF8);
        if (cr) CFRelease(cr);
        if (strncmp(buf, want, strlen(want)) == 0) {
            CFTypeRef u = IORegistryEntryCreateCFProperty(o, CFSTR("AppUsage"), NULL, 0);
            if (u && CFGetTypeID(u) == CFArrayGetTypeID()) {
                for (CFIndex i = 0; i < CFArrayGetCount(u); i++) {
                    CFDictionaryRef d = CFArrayGetValueAtIndex(u, i);
                    CFNumberRef n = CFDictionaryGetValue(d, CFSTR("accumulatedGPUTime"));
                    long long v = 0;
                    if (n) { CFNumberGetValue(n, kCFNumberLongLongType, &v); sum += (uint64_t)v; }
                }
            }
            if (u) CFRelease(u);
        }
        IOObjectRelease(o);
    }
    IOObjectRelease(it);
    return sum;
}

static GLuint shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type); glShaderSource(s, 1, &src, NULL); glCompileShader(s);
    GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[512]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "shader: %s\n", log); exit(1); }
    return s;
}

int main(int argc, char **argv) {
    @autoreleasepool {
    if (argc < 6) { fprintf(stderr, "usage: passbench MODE W H HZ SECS [RW RH]\n"); return 2; }
    const char *mode = argv[1];
    int W = atoi(argv[2]), H = atoi(argv[3]), hz = atoi(argv[4]); double secs = atof(argv[5]);
    int RW = argc > 6 ? atoi(argv[6]) : 64, RH = argc > 7 ? atoi(argv[7]) : 64;
    int RX = (W - RW) / 2, RY = (H - RH) / 2;

    CGLPixelFormatAttribute at[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
        kCGLPFAAccelerated, kCGLPFANoRecovery, kCGLPFAAllowOfflineRenderers, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLContextObj cx;
    if (CGLChoosePixelFormat(at, &pf, &npf) || !pf || CGLCreateContext(pf, NULL, &cx)) { fprintf(stderr, "no GL\n"); return 1; }
    CGLSetCurrentContext(cx);

    bool video = strncmp(mode, "nv12", 4) == 0;
    bool edge = strcmp(mode, "nv12") != 0;   // planes rounded to 16
    int PW = edge ? (W + 15) / 16 * 16 : W, PH = edge ? (H + 15) / 16 * 16 : H;
    // Present targets: BGRA IOSurfaces bound as rectangle textures, as QEMU's present.
    IOSurfaceRef surf[NSURF]; GLuint stex[NSURF]; GLuint fbo, rfbo;
    glGenFramebuffers(1, &fbo); glGenFramebuffers(1, &rfbo);
    GLuint src = 0;
    CVPixelBufferRef pix[NSURF] = { 0 }; GLuint ytex = 0, uvtex = 0;
    if (!video) {
        for (int i = 0; i < NSURF; i++) {
            NSDictionary *p = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
                                 (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
            surf[i] = IOSurfaceCreate((__bridge CFDictionaryRef)p);
            glGenTextures(1, &stex[i]); glBindTexture(GL_TEXTURE_RECTANGLE, stex[i]);
            if (CGLTexImageIOSurface2D(cx, GL_TEXTURE_RECTANGLE, GL_RGBA, W, H, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, surf[i], 0)) {
                fprintf(stderr, "CGLTexImageIOSurface2D failed\n"); return 1;
            }
        }
        // The guest's scanout: an RGBA8 2D texture with a pattern (the content does not matter much).
        uint32_t *px = malloc((size_t)W * H * 4);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) px[(size_t)y * W + x] = 0xff000000u | (x * 2654435761u ^ y * 40503u);
        glGenTextures(1, &src); glBindTexture(GL_TEXTURE_2D, src);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, px); free(px);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    } else {
        // VideoToolbox's frames: NV12 IOSurfaces from a pool (here NSURF of them, filled once).
        NSDictionary *a = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        for (int i = 0; i < NSURF; i++) {
            CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, (__bridge CFDictionaryRef)a, &pix[i]);
            CVPixelBufferLockBaseAddress(pix[i], 0);
            for (int pl = 0; pl < 2; pl++) memset(CVPixelBufferGetBaseAddressOfPlane(pix[i], pl), 0x40 + 16 * i + pl,
                                                  CVPixelBufferGetBytesPerRowOfPlane(pix[i], pl) * CVPixelBufferGetHeightOfPlane(pix[i], pl));
            CVPixelBufferUnlockBaseAddress(pix[i], 0);
        }
        // The guest's VA surface planes (Mesa rounds to 16; here exact).
        glGenTextures(1, &ytex); glBindTexture(GL_TEXTURE_2D, ytex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, PW, PH, 0, GL_RED, GL_UNSIGNED_BYTE, NULL);
        glGenTextures(1, &uvtex); glBindTexture(GL_TEXTURE_2D, uvtex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RG8, PW / 2, PH / 2, 0, GL_RG, GL_UNSIGNED_BYTE, NULL);
    }

    // QEMU's texture blit shader (ui/shader: a full-screen quad, flip in the vertex shader).
    const char *vs = "#version 150\nin vec2 in_position;\nout vec2 ex_tex_coord;\nuniform bool flip;\n"
        "void main(void){ gl_Position = vec4(in_position,0.0,1.0);\n"
        " ex_tex_coord = vec2(1.0 + in_position.x, flip ? 1.0 - in_position.y : 1.0 + in_position.y) * 0.5; }\n";
    const char *fs = "#version 150\nuniform sampler2D image;\nin vec2 ex_tex_coord;\nout vec4 out_color;\n"
        "void main(void){ out_color = texture(image, ex_tex_coord); }\n";
    GLuint prog = glCreateProgram();
    glAttachShader(prog, shader(GL_VERTEX_SHADER, vs)); glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs));
    glBindAttribLocation(prog, 0, "in_position"); glLinkProgram(prog); glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "flip"), 1);
    GLuint vao, vbo; static const GLfloat quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
    glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
    // nv12draw: one pass per plane, the picture's last row/column repeated past it (clamped texel coordinates).
    const char *vs2 = "#version 150\nin vec2 in_position;\nvoid main(void){ gl_Position = vec4(in_position,0.0,1.0); }\n";
    const char *fs2 = "#version 150\nuniform sampler2DRect pic;\nuniform vec2 last;\nout vec4 out_color;\n"
        "void main(void){ out_color = texture(pic, min(gl_FragCoord.xy, last)); }\n";
    GLuint prog2 = glCreateProgram();
    glAttachShader(prog2, shader(GL_VERTEX_SHADER, vs2)); glAttachShader(prog2, shader(GL_FRAGMENT_SHADER, fs2));
    glBindAttribLocation(prog2, 0, "in_position"); glLinkProgram(prog2);
    GLint last_loc = glGetUniformLocation(prog2, "last");
    if (!strcmp(mode, "nv12draw")) glUseProgram(prog2);
    if (glGetError()) { fprintf(stderr, "GL setup error\n"); return 1; }

    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    uint64_t period = (uint64_t)(1e9 / hz) * tb.denom / tb.numer;
    // Warm up 1 s, then measure.
    int frames = 0, waits_max_us = 0; double wait_sum_us = 0;
    uint64_t t0 = 0, g0 = 0, next = mach_absolute_time();
    int total = (int)((secs + 1) * hz);
    for (int f = 0; f < total; f++) {
        if (f == hz) { t0 = mach_absolute_time(); g0 = gpu_ns_self(); frames = 0; wait_sum_us = 0; waits_max_us = 0; }
        int n = f % NSURF;
        if (!video) {
            glBindFramebuffer(GL_FRAMEBUFFER, fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, stex[n], 0);
            glViewport(0, 0, W, H); glDisable(GL_BLEND); glDisable(GL_SCISSOR_TEST);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, src);
            if (!strcmp(mode, "today")) {
                glColorMask(1, 1, 1, 1); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
                glColorMask(1, 1, 1, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glColorMask(1, 1, 1, 1);
            } else if (!strcmp(mode, "noclear")) {
                glColorMask(1, 1, 1, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glColorMask(1, 1, 1, 1);
            } else if (!strcmp(mode, "nomask")) {
                glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            } else if (!strcmp(mode, "flushes") || !strcmp(mode, "draws")) {
                // RW small draws (RECT 8x8 at the middle) per frame; "flushes": a glFlush after each one.
                glEnable(GL_SCISSOR_TEST); glScissor(RX, RY, 8, 8);
                for (int k = 0; k < RW; k++) { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); if (mode[0] == 'f') glFlush(); }
                glDisable(GL_SCISSOR_TEST);
            } else if (!strcmp(mode, "scissor")) {
                glEnable(GL_SCISSOR_TEST); glScissor(RX, RY, RW, RH);
                glColorMask(1, 1, 1, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glColorMask(1, 1, 1, 1);
                glDisable(GL_SCISSOR_TEST);
            } else if (!strcmp(mode, "quad") || !strcmp(mode, "quadnm")) {
                // The same texels as the full draw would put there: viewport = RECT, texture coordinates of RECT.
                glViewport(RX, RY, RW, RH);
                glEnable(GL_SCISSOR_TEST); glScissor(RX, RY, RW, RH);
                if (!strcmp(mode, "quad")) glColorMask(1, 1, 1, 0);
                glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glColorMask(1, 1, 1, 1);
                glDisable(GL_SCISSOR_TEST);
            } else if (!strncmp(mode, "blit", 4)) {
                glBindFramebuffer(GL_READ_FRAMEBUFFER, rfbo);
                glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, src, 0);
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
                if (!strcmp(mode, "blit"))
                    glBlitFramebuffer(RX, RY, RX + RW, RY + RH, RX, RY, RX + RW, RY + RH, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                else if (!strcmp(mode, "blitflip"))
                    glBlitFramebuffer(0, 0, W, H, 0, H, W, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                else
                    glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            } else if (strcmp(mode, "none")) { fprintf(stderr, "unknown mode %s\n", mode); return 2; }
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
        } else {
            // As blit_pixbuf_to_video_buffer: new rectangle textures and FBOs per frame, one blit per plane.
            IOSurfaceRef s = CVPixelBufferGetIOSurface(pix[n]);
            GLuint t[2], fb[2]; glGenTextures(2, t); glGenFramebuffers(2, fb);
            for (int pl = 0; pl < 2; pl++) {
                GLsizei pw = (GLsizei)IOSurfaceGetWidthOfPlane(s, pl), ph = (GLsizei)IOSurfaceGetHeightOfPlane(s, pl);
                glBindTexture(GL_TEXTURE_RECTANGLE, t[pl]);
                CGLTexImageIOSurface2D(cx, GL_TEXTURE_RECTANGLE, pl ? GL_RG8 : GL_R8, pw, ph, pl ? GL_RG : GL_RED,
                                       GL_UNSIGNED_BYTE, s, pl);
                GLint qw = pl ? PW / 2 : PW, qh = pl ? PH / 2 : PH;   // the guest's plane
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fb[1]);
                glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, pl ? uvtex : ytex, 0);
                if (!strcmp(mode, "nv12draw")) {
                    glViewport(0, 0, qw, qh);
                    glUniform2f(last_loc, pw - 0.5f, ph - 0.5f);
                    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
                } else {
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, fb[0]);
                    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, t[pl], 0);
                    glBlitFramebuffer(0, 0, pw, ph, 0, 0, pw, ph, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    if (edge) {   // as blit_edge()
                        if (ph < qh) glBlitFramebuffer(0, ph - 1, pw, ph, 0, ph, pw, qh, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                        if (pw < qw) glBlitFramebuffer(pw - 1, 0, pw, ph, pw, 0, qw, ph, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                        if (pw < qw && ph < qh) glBlitFramebuffer(pw - 1, ph - 1, pw, ph, pw, ph, qw, qh, GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    }
                }
            }
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            glDeleteFramebuffers(2, fb); glDeleteTextures(2, t);
        }
        GLsync sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        glFlush();
        uint64_t w0 = mach_absolute_time();
        while (glClientWaitSync(sync, 0, 0) == GL_TIMEOUT_EXPIRED) usleep(100);
        glDeleteSync(sync);
        double wus = (double)(mach_absolute_time() - w0) * tb.numer / tb.denom / 1000.0;
        wait_sum_us += wus; if (wus > waits_max_us) waits_max_us = (int)wus;
        frames++;
        if (glGetError()) { fprintf(stderr, "GL error in frame %d\n", f); return 1; }
        next += period; mach_wait_until(next);
    }
    double el = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9;
    uint64_t g1 = gpu_ns_self();
    printf("{\"mode\": \"%s\", \"w\": %d, \"h\": %d, \"hz\": %d, \"rect\": \"%dx%d\", \"frames\": %d, \"secs\": %.2f, "
           "\"gpu_ms_per_s\": %.2f, \"gpu_us_per_frame\": %.1f, \"fence_wait_us_mean\": %.0f, \"fence_wait_us_max\": %d}\n",
           mode, W, H, hz, RW, RH, frames, el, (g1 - g0) / el / 1e6, (g1 - g0) / 1e3 / frames, wait_sum_us / frames, waits_max_us);
    }
    return 0;
}
