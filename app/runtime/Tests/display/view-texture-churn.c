/* view-texture-churn: GPU memory per guest mode change, without a VM.
 *
 * Replays the host GL work of a guest switching its scanout between two sizes
 * and prints the process footprint after every switch, plus "IOAccelerator
 * (graphics)" from vmmap at the start and the end. Evidence for
 * qemu-cocoa-gl-view-flush.patch. Manual tool, not run by the build.
 *
 * It runs on the GPU (the leak is in Apple's GPU driver; the software renderer
 * does not show it), with valid GL calls only and no guest input (STANDARDS
 * 14), and stops when the footprint passes CAP_MB (default 2000). Run it on the
 * Mac mini, or on a Mac nobody is using; not while the user tests.
 *
 * PARTS, any of:
 *   s  surface switch on the view context, as cocoa_gl_switch does:
 *      glDeleteTextures + glTexImage2D(GL_RGB, GL_BGRA) from fresh surface memory
 *   u  surface update on the view context, as cocoa_gl_update: glTexSubImage2D
 *   f  glFlush on the view context after s and u (qemu-cocoa-gl-view-flush.patch)
 *   x  guest transfer of the whole dumb buffer into its texture on vrend's
 *      context, followed by a guest fence (glFenceSync + wait, which flushes)
 *   y  the same transfer without a fence: QEMU's 2D path uploads the new screen
 *      on vrend's own context (ctx0) on every mode change, and nothing flushes it
 *   z  glFlush on that context after y (virgl-control-queue-flush.patch)
 *   r  layer render: draw the scanout texture into a 2880x1800 FBO + glFlush
 * The view context is double-buffered like QEMU's NSOpenGLContext.
 *
 *   cc -O1 view-texture-churn.c -framework OpenGL -o churn
 *   ./churn s  3840 2160 2560 1440 30    # grows ~16 MB per switch (M4)
 *   ./churn sf 3840 2160 2560 1440 30    # flat
 *   ./churn s  2560 1600 1920 1200 30    # flat: small textures are not kept
 * Measured on the Mac mini M4, macOS 27 (first version: GL_RGBA uploads, single-
 * buffered view): s 8000x6000<->7000x5000 +166 MB per switch; sf flat; su 3840x2160
 * +63 MB per switch, suf flat; x and r flat. Raw output of later runs:
 * ~/omacvm-work/gpu-robust/results/view-texture-churn/.
 */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static CGLContextObj make_context(CGLContextObj share, int double_buffer)
{
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAColorSize, 24, kCGLPFAAccelerated,
        double_buffer ? kCGLPFADoubleBuffer : (CGLPixelFormatAttribute)0, 0
    };
    CGLPixelFormatObj pix = NULL;
    CGLContextObj ctx = NULL;
    GLint n = 0;

    if (CGLChoosePixelFormat(attrs, &pix, &n) || !pix ||
        CGLCreateContext(pix, share, &ctx)) {
        fprintf(stderr, "no GPU OpenGL context\n");
        exit(1);
    }
    CGLReleasePixelFormat(pix);
    return ctx;
}

static double footprint_mb(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return info.phys_footprint / 1048576.0;
}

/* The DIRTY column of "IOAccelerator (graphics)" in vmmap -summary, in MB. */
static double ioaccelerator_mb(void)
{
    char command[64], line[512], v[32], r[32], d[32];
    double mb = 0;
    FILE *p;

    snprintf(command, sizeof command, "vmmap -summary %d 2>/dev/null", getpid());
    p = popen(command, "r");
    while (p && fgets(line, sizeof line, p)) {
        if (strncmp(line, "IOAccelerator (graphics)", 24) == 0 &&
            sscanf(line + 24, "%31s %31s %31s", v, r, d) == 3) {
            char unit = d[strlen(d) - 1];
            mb = atof(d);
            mb = unit == 'G' ? mb * 1024 : unit == 'K' ? mb / 1024 :
                 unit == 'M' ? mb : mb / 1048576;
        }
    }
    if (p) {
        pclose(p);
    }
    return mb;
}

/* Surface memory as QEMU's qemu_memfd_alloc makes it on macOS. */
static void *surface_memory(size_t size)
{
    char name[] = "/tmp/view-texture-churn-XXXXXX";
    int fd = mkstemp(name);
    void *p;

    if (fd < 0) {
        perror("mkstemp");
        exit(1);
    }
    unlink(name);
    if (ftruncate(fd, size)) {
        perror("ftruncate");
        exit(1);
    }
    p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    return p;
}

static GLuint layer_program(void)
{
    const char *vs = "#version 150\nout vec2 uv;\nvoid main() {\n"
        "  vec2 p = vec2(gl_VertexID & 1, gl_VertexID >> 1);\n"
        "  uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n}\n";
    const char *fs = "#version 150\nin vec2 uv;\nuniform sampler2D t;\nout vec4 c;\n"
        "void main() { c = texture(t, uv); }\n";
    GLuint program = glCreateProgram();
    GLuint v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER);

    glShaderSource(v, 1, &vs, NULL);
    glCompileShader(v);
    glShaderSource(f, 1, &fs, NULL);
    glCompileShader(f);
    glAttachShader(program, v);
    glAttachShader(program, f);
    glLinkProgram(program);
    return program;
}

int main(int argc, char **argv)
{
    if (argc < 7) {
        fprintf(stderr, "usage: %s PARTS W1 H1 W2 H2 SWITCHES [CAP_MB]\n", argv[0]);
        return 2;
    }
    const char *parts = argv[1];
    const int w[2] = { atoi(argv[2]), atoi(argv[4]) };
    const int h[2] = { atoi(argv[3]), atoi(argv[5]) };
    const int switches = atoi(argv[6]);
    const double cap = argc > 7 ? atof(argv[7]) : 2000;
    const int S = !!strchr(parts, 's'), U = !!strchr(parts, 'u'),
              F = !!strchr(parts, 'f'), X = !!strchr(parts, 'x'),
              Y = !!strchr(parts, 'y'), Z = !!strchr(parts, 'z'),
              R = !!strchr(parts, 'r');

    for (int i = 0; i < 2; i++) {
        if (w[i] < 1 || h[i] < 1 || w[i] > 8192 || h[i] > 8192) {
            fprintf(stderr, "sizes must be 1..8192\n");
            return 2;
        }
    }

    CGLContextObj view = make_context(NULL, 1);
    CGLContextObj ctx0 = make_context(view, 0);
    CGLContextObj layer = make_context(view, 0);

    /* The guest's two dumb buffers as renderer textures, made once. */
    GLuint scanout[2];
    void *guest[2];
    CGLSetCurrentContext(ctx0);
    glGenTextures(2, scanout);
    for (int i = 0; i < 2; i++) {
        size_t size = (size_t)w[i] * h[i] * 4;
        glBindTexture(GL_TEXTURE_2D, scanout[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w[i], h[i], 0, GL_BGRA, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        guest[i] = malloc(size);
        memset(guest[i], i ? 0x30 : 0xc0, size);
    }
    glFlush();

    /* The layer draws into a window-sized FBO. */
    GLuint fbo, rb, vao, program;
    CGLSetCurrentContext(layer);
    glGenFramebuffers(1, &fbo);
    glGenRenderbuffers(1, &rb);
    glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 2880, 1800);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    glGenVertexArrays(1, &vao);
    program = layer_program();
    glFlush();
    CGLSetCurrentContext(NULL);

    GLuint surface_texture = 0;
    void *surface = NULL;
    size_t surface_size = 0;
    printf("parts=%s %dx%d<->%dx%d start: footprint %.0f MB, IOAccelerator %.0f MB\n",
           parts, w[0], h[0], w[1], h[1], footprint_mb(), ioaccelerator_mb());

    for (int i = 0; i < switches; i++) {
        const int k = i & 1;

        if (S) {
            size_t size = (size_t)w[k] * h[k] * 4;
            void *next = surface_memory(size);
            CGLSetCurrentContext(view);
            if (surface_texture) {
                glDeleteTextures(1, &surface_texture);
            }
            glGenTextures(1, &surface_texture);
            glBindTexture(GL_TEXTURE_2D, surface_texture);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, w[k]);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, w[k], h[k], 0, GL_BGRA, GL_UNSIGNED_BYTE, next);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            if (F) {
                glFlush();
            }
            CGLSetCurrentContext(NULL);
            if (surface) {
                munmap(surface, surface_size);
            }
            surface = next;
            surface_size = size;
        }
        if (U && surface_texture) {
            CGLSetCurrentContext(view);
            glBindTexture(GL_TEXTURE_2D, surface_texture);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, w[k]);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w[k], h[k], GL_BGRA, GL_UNSIGNED_BYTE, surface);
            if (F) {
                glFlush();
            }
            CGLSetCurrentContext(NULL);
        }
        if (X) {
            CGLSetCurrentContext(ctx0);
            glBindTexture(GL_TEXTURE_2D, scanout[k]);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, w[k]);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w[k], h[k], GL_BGRA, GL_UNSIGNED_BYTE, guest[k]);
            GLsync sync = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
            glClientWaitSync(sync, GL_SYNC_FLUSH_COMMANDS_BIT, 2000000000ull);
            glDeleteSync(sync);
            CGLSetCurrentContext(NULL);
        }
        if (Y) {
            CGLSetCurrentContext(ctx0);
            glBindTexture(GL_TEXTURE_2D, scanout[k]);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, w[k]);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w[k], h[k], GL_BGRA, GL_UNSIGNED_BYTE, guest[k]);
            if (Z) {
                glFlush();
            }
            CGLSetCurrentContext(NULL);
        }
        if (R) {
            CGLSetCurrentContext(layer);
            glBindFramebuffer(GL_FRAMEBUFFER, fbo);
            glViewport(0, 0, 2880, 1800);
            glUseProgram(program);
            glBindVertexArray(vao);
            glBindTexture(GL_TEXTURE_2D, scanout[k]);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            glFlush();
            CGLSetCurrentContext(NULL);
        }

        double footprint = footprint_mb();
        printf("switch %d %dx%d: footprint %.0f MB\n", i + 1, w[k], h[k], footprint);
        fflush(stdout);
        if (footprint > cap) {
            printf("stopped: footprint above %.0f MB\n", cap);
            break;
        }
    }
    usleep(500000);
    printf("end: footprint %.0f MB, IOAccelerator %.0f MB\n", footprint_mb(), ioaccelerator_mb());
    return 0;
}
