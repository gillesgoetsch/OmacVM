/* Cost of vrend's index read-back (virgl-draw-range-checks.patch: glGetBufferSubData and a
 * scan for the largest index before each indexed draw), for small and large index buffers.
 * Valid draws only, a normal GL workload, so it may run on the GPU; take the bench lock.
 * Not a build-time test. Build: cc -O2 bench-index-readback.c -framework OpenGL
 * Usage: bench-index-readback INDICES DRAWS [soft]; prints one JSON line (ms per draw,
 * third of three rounds; run it three times for a median). Numbers: ADR 0017. */
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>

static double now(void)
{
   static mach_timebase_info_data_t tb;
   if (!tb.denom)
      mach_timebase_info(&tb);
   return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6;
}

int main(int argc, char **argv)
{
   long ni = argc > 1 ? atol(argv[1]) : 6000, draws = argc > 2 ? atol(argv[2]) : 1000;
   int soft = argc > 3;
   CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                   soft ? kCGLPFARendererID : 0, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID, 0 };
   CGLPixelFormatObj p = 0; GLint n = 0; CGLContextObj c = 0;
   CGLChoosePixelFormat(a, &p, &n); CGLCreateContext(p, 0, &c); CGLSetCurrentContext(c);
   GLuint fbo, tex;
   glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
   glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 512, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0);
   glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0); glViewport(0, 0, 512, 512);
   const char *vs = "#version 410\nlayout(location=0) in vec2 p; void main(){gl_Position=vec4(p*0.01,0,1);}";
   const char *fs = "#version 410\nout vec4 c; void main(){c=vec4(1);}";
   GLuint pr = glCreateProgram(), v = glCreateShader(GL_VERTEX_SHADER), f = glCreateShader(GL_FRAGMENT_SHADER);
   glShaderSource(v, 1, &vs, 0); glCompileShader(v); glShaderSource(f, 1, &fs, 0); glCompileShader(f);
   glAttachShader(pr, v); glAttachShader(pr, f); glLinkProgram(pr); glUseProgram(pr);
   GLuint vao, vb, ib; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
   enum { NV = 65536 };
   float *vd = malloc(NV * 8); for (int i = 0; i < NV * 2; i++) vd[i] = (i % 7) * 0.1f;
   unsigned *id = malloc(ni * 4); for (long i = 0; i < ni; i++) id[i] = (unsigned)((i * 31) % NV);
   glGenBuffers(1, &vb); glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, NV * 8, vd, GL_STATIC_DRAW);
   glVertexAttribPointer(0, 2, GL_FLOAT, 0, 8, 0); glEnableVertexAttribArray(0);
   glGenBuffers(1, &ib); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ib); glBufferData(GL_ELEMENT_ARRAY_BUFFER, ni * 4, id, GL_STATIC_DRAW);
   unsigned *rb = malloc(ni * 4);
   double t[2];
   unsigned mx = 0;
   for (int round = 0; round < 3; round++) {
      for (int mode = 0; mode < 2; mode++) {
         glFinish(); double t0 = now();
         for (long d = 0; d < draws; d++) {
            if (mode) {
               glBindBuffer(GL_COPY_READ_BUFFER, ib);
               glGetBufferSubData(GL_COPY_READ_BUFFER, 0, ni * 4, rb);
               for (long i = 0; i < ni; i++) if (rb[i] > mx) mx = rb[i];
            }
            glDrawElements(GL_TRIANGLES, (GLsizei)(ni - ni % 3), GL_UNSIGNED_INT, 0);
            if (d % 100 == 99) glFlush();
         }
         glFinish(); t[mode] = (now() - t0) / draws;
      }
      if (round == 2)
         printf("{\"indices\": %ld, \"bytes\": %ld, \"draws\": %ld, \"plain_ms\": %.4f, \"readback_ms\": %.4f, \"extra_ms\": %.4f, \"renderer\": \"%s\", \"max\": %u}\n",
                ni, ni * 4, draws, t[0], t[1], t[1] - t[0], glGetString(GL_RENDERER), mx);
   }
   return 0;
}
