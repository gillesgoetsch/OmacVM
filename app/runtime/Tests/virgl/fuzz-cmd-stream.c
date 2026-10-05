/* libFuzzer harness: guest command streams into a virgl context on Apple's software
 * OpenGL renderer (soft-gl.h: never on the GPU).
 * Each input is one SUBMIT_3D buffer for a fresh context that has already named a
 * reset status buffer (VIRGL_CCMD_SET_RESET_STATUS_BUFFER), so the decoder, the
 * refused-shader path and the context-loss report all see guest-controlled data.
 * Resources: 1 = that guest-memory buffer, 2 = a GL buffer (stream output), 3 = a
 * 64x64 colour buffer.
 * Beyond ASan: the 16 bytes on each side of the guest's buffer are never written
 * (the host may write inside it: transfers and query results name it too).
 * Build and run: fuzz-cmd-stream.sh (needs Homebrew llvm@22 for libFuzzer). */
#include <OpenGL/OpenGL.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

#ifndef VIRGL_SET_RESET_STATUS_BUFFER_SIZE
/* Fuzzing a tree without virgl-context-loss-report.patch (to compare). */
#define VIRGL_CCMD_SET_RESET_STATUS_BUFFER VIRGL_MAX_COMMANDS
#define VIRGL_SET_RESET_STATUS_BUFFER_SIZE 1
#endif

static CGLContextObj main_ctx;
static int cookie;
static uint32_t ctx_id;

static CGLContextObj new_context(CGLContextObj share)
{
   return soft_gl_context(share);
}

static void write_fence(void *c, uint32_t f)
{
   (void)c;
   (void)f;
}

static virgl_renderer_gl_context create_gl_context(void *c, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)c;
   (void)scanout;
   (void)param;
   /* QEMU (ui/cocoa) shares every context with its view's context, the first one too. */
   return new_context(main_ctx);
}

static void destroy_gl_context(void *c, virgl_renderer_gl_context ctx)
{
   (void)c;
   CGLDestroyContext(ctx);
}

static int make_current(void *c, int scanout, virgl_renderer_gl_context ctx)
{
   (void)c;
   (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
};

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
   (void)argc;
   (void)argv;
   main_ctx = new_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx))
      abort();
   soft_gl_require();
   if (virgl_renderer_init(&cookie, 0, &callbacks))
      abort();
   return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
   /* 16 guard bytes on each side of the 64-byte status buffer. */
   uint8_t backing[96];
   memset(backing, 0xa5, sizeof(backing));
   memset(backing + 16, 0, 64);
   struct iovec iov = { backing + 16, 64 };
   struct virgl_renderer_resource_create_args args = {
      .handle = 1, .target = 0 /* PIPE_BUFFER */, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_CUSTOM, .width = 64, .height = 1, .depth = 1, .array_size = 1,
   };

   ctx_id++;
   if (virgl_renderer_context_create(ctx_id, 4, "fuzz"))
      abort();
   virgl_renderer_resource_create(&args, NULL, 0);
   virgl_renderer_resource_attach_iov(1, &iov, 1);
   virgl_renderer_ctx_attach_resource(ctx_id, 1);
   /* A GL buffer (created for stream output; vrend binds it as any buffer) and a
    * 64x64 colour buffer, so streams can draw and record transform feedback. */
   struct virgl_renderer_resource_create_args buf_args = {
      .handle = 2, .target = 0 /* PIPE_BUFFER */, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_STREAM_OUTPUT,
      .width = 4096, .height = 1, .depth = 1, .array_size = 1,
   };
   struct virgl_renderer_resource_create_args rt_args = {
      .handle = 3, .target = 2 /* PIPE_TEXTURE_2D */, .format = VIRGL_FORMAT_B8G8R8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET | VIRGL_BIND_SAMPLER_VIEW, .width = 64, .height = 64,
      .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&buf_args, NULL, 0);
   virgl_renderer_resource_create(&rt_args, NULL, 0);
   virgl_renderer_ctx_attach_resource(ctx_id, 2);
   virgl_renderer_ctx_attach_resource(ctx_id, 3);
   uint32_t setup[2] = {
      VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0, VIRGL_SET_RESET_STATUS_BUFFER_SIZE), 1
   };
   virgl_renderer_submit_cmd(setup, ctx_id, 2);

   size_t words = size / 4;
   if (words) {
      uint32_t *cmds = malloc(words * 4);
      memcpy(cmds, data, words * 4);
      virgl_renderer_submit_cmd(cmds, ctx_id, words);
      free(cmds);
   }

   for (int i = 0; i < 16; i++)
      if (backing[i] != 0xa5 || backing[80 + i] != 0xa5)
         abort();

   virgl_renderer_ctx_detach_resource(ctx_id, 1);
   virgl_renderer_ctx_detach_resource(ctx_id, 2);
   virgl_renderer_ctx_detach_resource(ctx_id, 3);
   virgl_renderer_resource_detach_iov(1, NULL, NULL);
   virgl_renderer_resource_unref(1);
   virgl_renderer_context_destroy(ctx_id);
   virgl_renderer_resource_unref(2);
   virgl_renderer_resource_unref(3);
   return 0;
}
