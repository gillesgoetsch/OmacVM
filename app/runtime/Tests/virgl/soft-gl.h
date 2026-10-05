/* OpenGL contexts for the virgl tests and the fuzzer: Apple's software renderer only.
 *
 * These programs feed virglrenderer invalid or random command streams. On 2026-10-04 the
 * fuzzer ran on the Mac's GPU: a stream made the GPU read an unmapped address (BIF0 page
 * fault), the GPU reset hung WindowServer and macOS panicked. Invalid input must never
 * reach the real GPU, so every context here asks CGL for the Apple Software Renderer
 * (kCGLRendererGenericFloatID, OpenGL 4.1 core like the GPU) and soft_gl_require() stops
 * the program when the current context is anything else. */
#ifndef SOFT_GL_H
#define SOFT_GL_H

#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* glGetString without including GL headers that clash with the tests' own. */
const unsigned char *glGetString(unsigned int name);
#define SOFT_GL_RENDERER 0x1F01 /* GL_RENDERER */
#define SOFT_GL_NAME "Apple Software Renderer"

static CGLContextObj soft_gl_context(CGLContextObj share)
{
   CGLPixelFormatAttribute attrs[] = {
      kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
      kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID,
      0
   };
   CGLPixelFormatObj pix = NULL;
   CGLContextObj ctx = NULL;
   GLint n = 0;
   if (CGLChoosePixelFormat(attrs, &pix, &n) || !pix)
      return NULL;
   CGLCreateContext(pix, share, &ctx);
   CGLReleasePixelFormat(pix);
   return ctx;
}

/* Call with a context current: exits unless it is the software renderer. */
static void soft_gl_require(void)
{
   const char *name = (const char *)glGetString(SOFT_GL_RENDERER);
   if (!name || strcmp(name, SOFT_GL_NAME)) {
      fprintf(stderr, "refusing to run: OpenGL renderer is \"%s\", not \"%s\"; invalid "
              "input must not reach the GPU\n", name ? name : "(none)", SOFT_GL_NAME);
      exit(2);
   }
}

#endif
