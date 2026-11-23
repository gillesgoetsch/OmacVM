/* The capability bits the guest is told (capset 2) and the command Mesa 26.3 sends behind
 * upstream's bit 19, through the public renderer API on Apple's software renderer (soft-gl.h,
 * never the GPU):
 *  - bit 19 is upstream's VIRGL_CAP_V2_QUERY_FORMAT_MODIFIER (virglrenderer 652e8d8b, Mesa
 *    26.3), set upstream only by a renderer with GBM and Venus interop; bit 18
 *    (RESOURCE_LAYOUT) only with GBM. This build has no GBM: neither is set. The macOS tap
 *    set 19 for its own CORE_PROFILE_ONLY; Mesa 26.3 took it for the modifier query and sent
 *    GET_PIPE_RESOURCE_LAYOUT for every shared texture, which this build refuses, so every GL
 *    context of the desktop was lost (virgl-caps-format-modifier-bit.patch);
 *  - bits 20..29 are upstream's next ones: none is set (a private bit there is the same trap
 *    again); OmacVM's own bit is 30;
 *  - GET_PIPE_RESOURCE_LAYOUT as Mesa 26.3 encodes it, too short, too long or with unknown
 *    handles: refused, nothing written into the guest's buffer, the context is lost (status
 *    GUILTY) and another context keeps working. */
#include <OpenGL/OpenGL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include "soft-gl.h"
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"

enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2 };

static CGLContextObj main_ctx;
static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   (void)fence;
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
   return soft_gl_context(main_ctx);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie;
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

/* The guest buffers: guest memory with 16 guard bytes on each side. */
#define OUT_SIZE 256
static uint8_t out_backing[OUT_SIZE + 32];
static uint32_t status[16];

static int out_untouched(void)
{
   for (unsigned i = 0; i < sizeof(out_backing); i++)
      if (out_backing[i] != 0xa5)
         return 0;
   return 1;
}

/* One case in a fresh context: the status buffer named first, then CMD (WORDS dwords). */
static void layout_case(uint32_t ctx_id, const uint32_t *cmd, unsigned words, const char *what)
{
   char line[160];
   memset(out_backing, 0xa5, sizeof(out_backing));
   memset(status, 0, sizeof(status));
   if (virgl_renderer_context_create(ctx_id, 6, "layout")) {
      check(0, "context created");
      return;
   }
   virgl_renderer_ctx_attach_resource(ctx_id, 1);
   virgl_renderer_ctx_attach_resource(ctx_id, 2);
   virgl_renderer_ctx_attach_resource(ctx_id, 3);
   uint32_t setup[2] = {
      VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0, VIRGL_SET_RESET_STATUS_BUFFER_SIZE), 1
   };
   virgl_renderer_submit_cmd(setup, ctx_id, 2);
   uint32_t *copy = malloc(words * 4);
   memcpy(copy, cmd, words * 4);
   int r = virgl_renderer_submit_cmd(copy, ctx_id, words);
   free(copy);
   /* A command cut by the end of the stream ends the submit with 0, its context lost. */
   snprintf(line, sizeof(line), "%s: refused (%d), context lost, guest buffer untouched", what, r);
   check(status[0] == VIRGL_RESET_STATUS_GUILTY && out_untouched(), line);
   virgl_renderer_ctx_detach_resource(ctx_id, 1);
   virgl_renderer_ctx_detach_resource(ctx_id, 2);
   virgl_renderer_ctx_detach_resource(ctx_id, 3);
   virgl_renderer_context_destroy(ctx_id);
}

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   static int cookie;
   if (virgl_renderer_init(&cookie, 0, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }

   uint32_t max_ver = 0, max_size = 0;
   virgl_renderer_get_cap_set(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, &max_ver, &max_size);
   union virgl_caps *caps = calloc(1, max_size > sizeof(*caps) ? max_size : sizeof(*caps));
   virgl_renderer_fill_caps(2 /* VIRTIO_GPU_CAPSET_VIRGL2 */, max_ver, caps);
   uint32_t bits = caps->v2.capability_bits_v2;
   printf("capability_bits_v2 0x%08x\n", bits);
   check(!(bits & (1u << 19)),
         "bit 19 (upstream QUERY_FORMAT_MODIFIER, needs GBM) is not set");
   check(!(bits & (1u << 18)), "bit 18 (upstream RESOURCE_LAYOUT, needs GBM) is not set");
   check(!(bits & 0x3ff00000u), "bits 20..29 (upstream's next ones) are not set");
   check(bits & VIRGL_CAP_V2_RESET_STATUS_BUFFER, "OmacVM's bit 30 (reset status buffer) is set");
   free(caps);

   /* 1: the status buffer; 2: the layout's out buffer, as Mesa 26.3 makes it (a staging
    * PIPE_BUFFER, VIRGL_BIND_CUSTOM, guest memory); 3: a shared 2D texture. */
   struct iovec status_iov = { status, sizeof(status) };
   struct virgl_renderer_resource_create_args status_args = {
      .handle = 1, .target = TEST_PIPE_BUFFER, .format = VIRGL_FORMAT_R8_UNORM,
      .bind = VIRGL_BIND_CUSTOM, .width = sizeof(status), .height = 1, .depth = 1,
      .array_size = 1,
   };
   struct iovec out_iov = { out_backing + 16, OUT_SIZE };
   struct virgl_renderer_resource_create_args out_args = status_args;
   out_args.handle = 2;
   out_args.width = OUT_SIZE;
   struct virgl_renderer_resource_create_args tex_args = {
      .handle = 3, .target = TEST_PIPE_TEXTURE_2D, .format = VIRGL_FORMAT_B8G8R8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET | VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_SHARED,
      .width = 64, .height = 64, .depth = 1, .array_size = 1,
   };
   memset(out_backing, 0xa5, sizeof(out_backing));
   check(!virgl_renderer_resource_create(&status_args, NULL, 0) &&
         !virgl_renderer_resource_attach_iov(1, &status_iov, 1) &&
         !virgl_renderer_resource_create(&out_args, NULL, 0) &&
         !virgl_renderer_resource_attach_iov(2, &out_iov, 1) &&
         !virgl_renderer_resource_create(&tex_args, NULL, 0), "resources created");

   /* Mesa 26.3's virgl_encoder_get_layout(): out buffer, then the texture. */
   const uint32_t mesa263[] = {
      VIRGL_CMD0(VIRGL_CCMD_GET_PIPE_RESOURCE_LAYOUT, 0, VIRGL_RESOURCE_LAYOUT_SIZE), 2, 3
   };
   layout_case(10, mesa263, 3, "GET_PIPE_RESOURCE_LAYOUT as Mesa 26.3 sends it");
   const uint32_t empty[] = { VIRGL_CMD0(VIRGL_CCMD_GET_PIPE_RESOURCE_LAYOUT, 0, 0) };
   layout_case(11, empty, 1, "no handles");
   const uint32_t one[] = { VIRGL_CMD0(VIRGL_CCMD_GET_PIPE_RESOURCE_LAYOUT, 0, 1), 2 };
   layout_case(12, one, 2, "one handle");
   /* says 2 dwords, the stream ends after 1: the decoder must not read past it */
   const uint32_t cut[] = { VIRGL_CMD0(VIRGL_CCMD_GET_PIPE_RESOURCE_LAYOUT, 0, 2), 2 };
   layout_case(13, cut, 2, "stream ends inside the command");
   const uint32_t unknown[] = {
      VIRGL_CMD0(VIRGL_CCMD_GET_PIPE_RESOURCE_LAYOUT, 0, 2), 0xdeadbeef, 0
   };
   layout_case(14, unknown, 3, "unknown handles");
   const uint32_t swapped[] = {
      VIRGL_CMD0(VIRGL_CCMD_GET_PIPE_RESOURCE_LAYOUT, 0, 2), 3, 2
   };
   layout_case(15, swapped, 3, "the texture as out buffer");
   const uint32_t longer[] = {
      VIRGL_CMD0(VIRGL_CCMD_GET_PIPE_RESOURCE_LAYOUT, 0, 5), 2, 3, 0xffffffff, 0xffffffff, 0
   };
   layout_case(16, longer, 6, "longer than its two handles");

   /* the renderer goes on: a new context takes and runs a command */
   check(!virgl_renderer_context_create(20, 5, "after"), "a context after the refused ones");
   virgl_renderer_ctx_attach_resource(20, 1);
   memset(status, 0, sizeof(status));
   uint32_t named[2] = {
      VIRGL_CMD0(VIRGL_CCMD_SET_RESET_STATUS_BUFFER, 0, VIRGL_SET_RESET_STATUS_BUFFER_SIZE), 1
   };
   check(virgl_renderer_submit_cmd(named, 20, 2) == 0 && status[0] == 0,
         "it runs a command and stays alive");
   virgl_renderer_ctx_detach_resource(20, 1);
   virgl_renderer_context_destroy(20);

   virgl_renderer_resource_detach_iov(1, NULL, NULL);
   virgl_renderer_resource_detach_iov(2, NULL, NULL);
   virgl_renderer_resource_unref(1);
   virgl_renderer_resource_unref(2);
   virgl_renderer_resource_unref(3);
   virgl_renderer_cleanup(&cookie);
   printf("%s\n", failures ? "caps format modifier: FAILED"
                           : "caps format modifier: all checks passed");
   return failures != 0;
}
