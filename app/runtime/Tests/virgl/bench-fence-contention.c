/* Does a thread testing GL fences slow a GL render thread down on Apple's OpenGL? (ADR 0026)
 * Render thread (context A): small indexed draws with buffer/program/texture binds, like vrend in
 * WebGL Aquarium; a glFlush every 64 draws. Tester thread (context B, same share group) calls
 * glClientWaitSync(fence, 0, 0) on a signalled fence: none / spin (back to back, like the sync thread's
 * first 100 us) / 50us (mach_wait_until between tests, its naps) / 1ms. Modes interleaved, 12 rounds.
 * Valid GL only, a normal workload, so it may run on the GPU; take the bench lock.
 * Not a build-time test. Build: cc -O2 bench-fence-contention.c -framework OpenGL
 * Usage: bench-fence-contention [SECONDS per three rounds, default 3]. */
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static CGLContextObj ca, cb;
static GLsync fence;
static atomic_int mode, stop;
static atomic_ulong tests;
static mach_timebase_info_data_t tb;

static uint64_t ns(void) { return mach_absolute_time() * tb.numer / tb.denom; }

static void *tester(void *a)
{
    (void)a;
    CGLSetCurrentContext(cb);
    while (!atomic_load(&stop)) {
        int m = atomic_load(&mode);
        if (m == 0) { mach_wait_until(mach_absolute_time() + 1000000ull * tb.denom / tb.numer); continue; }
        glClientWaitSync(fence, 0, 0);
        atomic_fetch_add(&tests, 1);
        if (m == 2) mach_wait_until(mach_absolute_time() + 50000ull * tb.denom / tb.numer);
        if (m == 3) mach_wait_until(mach_absolute_time() + 1000000ull * tb.denom / tb.numer);
    }
    return NULL;
}

static GLuint sh(GLenum t, const char *s)
{
    GLuint o = glCreateShader(t); glShaderSource(o, 1, &s, NULL); glCompileShader(o); return o;
}

int main(int argc, char **argv)
{
    double secs = argc > 1 ? atof(argv[1]) : 3;
    mach_timebase_info(&tb);
    CGLPixelFormatAttribute at[] = { kCGLPFAAccelerated, kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, 0 };
    CGLPixelFormatObj pf; GLint n;
    if (CGLChoosePixelFormat(at, &pf, &n) || !pf) { fprintf(stderr, "no pixel format\n"); return 1; }
    CGLCreateContext(pf, NULL, &ca); CGLCreateContext(pf, ca, &cb);
    CGLSetCurrentContext(ca);
    GLuint fbo, tex[4], vao, vbo[8], ibo[8], prog[4];
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    GLuint rt; glGenTextures(1, &rt); glBindTexture(GL_TEXTURE_2D, rt);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
    glViewport(0, 0, 256, 256);
    glGenTextures(4, tex);
    for (int i = 0; i < 4; i++) {
        glBindTexture(GL_TEXTURE_2D, tex[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    }
    glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    float v[3 * 4 * 64]; unsigned short idx[6 * 64];
    for (int i = 0; i < 64; i++) {
        float x = (i % 8) / 8.0f - 1, y = (i / 8) / 8.0f - 1;
        float q[12] = { x, y, 0, x + .1f, y, 0, x, y + .1f, 0, x + .1f, y + .1f, 0 };
        memcpy(v + 12 * i, q, sizeof q);
        unsigned short k[6] = { 4 * i, 4 * i + 1, 4 * i + 2, 4 * i + 1, 4 * i + 3, 4 * i + 2 };
        memcpy(idx + 6 * i, k, sizeof k);
    }
    glGenBuffers(8, vbo); glGenBuffers(8, ibo);
    for (int i = 0; i < 8; i++) {
        glBindBuffer(GL_ARRAY_BUFFER, vbo[i]); glBufferData(GL_ARRAY_BUFFER, sizeof v, v, GL_STATIC_DRAW);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo[i]); glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
    }
    const char *vs = "#version 330\nlayout(location=0) in vec3 p; uniform vec4 o; out vec2 t;\n"
                     "void main(){ t = p.xy; gl_Position = vec4(p + o.xyz, 1.0); }\n";
    const char *fs[4] = {
        "#version 330\nin vec2 t; uniform sampler2D s; uniform vec4 c; out vec4 f; void main(){ f = texture(s, t) * c; }\n",
        "#version 330\nin vec2 t; uniform sampler2D s; uniform vec4 c; out vec4 f; void main(){ f = texture(s, t) + c; }\n",
        "#version 330\nin vec2 t; uniform sampler2D s; uniform vec4 c; out vec4 f; void main(){ f = c - texture(s, t); }\n",
        "#version 330\nin vec2 t; uniform sampler2D s; uniform vec4 c; out vec4 f; void main(){ f = c * c + texture(s, t); }\n" };
    GLint uo[4], uc[4];
    for (int i = 0; i < 4; i++) {
        prog[i] = glCreateProgram();
        glAttachShader(prog[i], sh(GL_VERTEX_SHADER, vs)); glAttachShader(prog[i], sh(GL_FRAGMENT_SHADER, fs[i]));
        glLinkProgram(prog[i]); uo[i] = glGetUniformLocation(prog[i], "o"); uc[i] = glGetUniformLocation(prog[i], "c");
    }
    fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); glFinish();
    pthread_t th; pthread_create(&th, NULL, tester, NULL);
    const char *names[] = { "none", "spin", "50us", "1ms" };
    double sum[4] = { 0 }, cnt[4] = { 0 }; unsigned long tsum[4] = { 0 };
    int order[] = { 0, 2, 1, 3, 3, 1, 2, 0, 0, 2, 1, 3 };
    for (int r = 0; r < 12; r++) {
        int m = order[r];
        atomic_store(&mode, m); atomic_store(&tests, 0);
        uint64_t t0 = ns(), draws = 0;
        while (ns() - t0 < secs * 1e9 / 3) {
            int k = draws % 8, p = draws % 4;
            glUseProgram(prog[p]);
            glBindBuffer(GL_ARRAY_BUFFER, vbo[k]);
            glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, 0); glEnableVertexAttribArray(0);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo[k]);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex[draws % 4]);
            glUniform4f(uo[p], (draws % 7) * .01f, 0, 0, 0); glUniform4f(uc[p], 1, .5f, .25f, 1);
            glDrawElements(GL_TRIANGLES, 6 * 64, GL_UNSIGNED_SHORT, 0);
            if (++draws % 64 == 0) glFlush();
        }
        glFinish();
        double dt = (ns() - t0) / 1e9;
        sum[m] += draws / dt; cnt[m]++; tsum[m] += atomic_load(&tests);
        printf("round %2d mode %-4s %8.0f draws/s, tester %7.0f tests/s\n", r, names[m], draws / dt, atomic_load(&tests) / dt);
    }
    atomic_store(&stop, 1); pthread_join(th, NULL);
    for (int m = 0; m < 4; m++)
        printf("mode %-4s mean %8.0f draws/s (%+.1f%% vs none), %.0f tests/s\n", names[m], sum[m] / cnt[m],
               100 * (sum[m] / cnt[m] / (sum[0] / cnt[0]) - 1), tsum[m] / (cnt[m] * secs / 3));
    return 0;
}
