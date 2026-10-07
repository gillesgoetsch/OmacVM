/* Held fences (virgl-fence-flush-on-need.patch) through the public renderer API, the way
 * QEMU drives it on the Mac: CGL core contexts (no window), the sync thread with async
 * fence callbacks, virgl_renderer_force_ctx_0() before every command,
 * virgl_renderer_flush_fences() before every command that is not a command buffer and when
 * the queue ends. Clears and copies of 16x16 colour buffers, read back:
 *  1. a fence after a command buffer is held (not signalled while nothing asks), and
 *     signals once QEMU asks;
 *  2. work held in one context is seen by another (a copy in context 2 of what context 1
 *     cleared, both before the held fence was flushed);
 *  3. a context destroyed with a held fence: the fence still signals;
 *  4. 50 command buffers with a fence each and QEMU's hop between them: all signal after
 *     one flush, and the colour is the last one;
 *  5. a read-back (transfer) right after a held clear reads the clear.
 * The renderer calls that flush on their own are checked by check_fence_flush_entries
 * in run-regressions.py.
 * With OMACVM_VIRGL_FENCE_FLUSH=0 every fence is flushed at once (case 1 then signals
 * without being asked). */
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/uio.h>
#include <OpenGL/gl3.h>
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"
#define CGL_CONTEXT_RENDERER_CALLBACKS
#include "cgl-context.h"

enum { TEST_TEXTURE_2D = 2, TEST_CLEAR_COLOR0 = 1 << 2 };
enum { RED = 0xff0000ff, GREEN = 0xff00ff00, BLUE = 0xffff0000 };

static int failures;
static atomic_uint last_fence;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static void record_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   unsigned seen = atomic_load(&last_fence);
   while (fence > seen && !atomic_compare_exchange_weak(&last_fence, &seen, fence))
      ;
}

static uint64_t now_ms(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

/* the sync thread reports the fence within ms milliseconds; with poll, QEMU's 1 ms
 * fence timer runs meanwhile (it hands held fences to the GPU) */
static int fence_signals_poll(uint32_t fence, unsigned ms, int poll)
{
   uint64_t end = now_ms() + ms;
   while (atomic_load(&last_fence) < fence) {
      if (now_ms() > end)
         return 0;
      if (poll)
         virgl_renderer_poll();
      struct timespec t = { 0, 1000000 };
      nanosleep(&t, NULL);
   }
   return 1;
}

static int fence_signals(uint32_t fence, unsigned ms)
{
   return fence_signals_poll(fence, ms, 1);
}

struct cmds { uint32_t dw[256]; unsigned n; };
static void emit(struct cmds *c, uint32_t v) { c->dw[c->n++] = v; }
static void emit_float(struct cmds *c, float f)
{
   union { float f; uint32_t u; } v = { f };
   emit(c, v.u);
}

/* surface `surf` on resource `res`, bound as the only colour buffer */
static void emit_target(struct cmds *c, uint32_t surf, uint32_t res)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(c, surf);
   emit(c, res);
   emit(c, VIRGL_FORMAT_R8G8B8A8_UNORM);
   emit(c, 0);
   emit(c, 0);
   emit(c, VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(c, 1);
   emit(c, 0);
   emit(c, surf);
}

static void emit_clear(struct cmds *c, uint32_t rgba)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(c, TEST_CLEAR_COLOR0);
   for (int i = 0; i < 4; i++)
      emit_float(c, ((rgba >> (8 * i)) & 0xff) / 255.0f);
   emit(c, 0);
   emit(c, 0);
   emit(c, 0);
}

static void emit_copy(struct cmds *c, uint32_t dst, uint32_t src)
{
   emit(c, VIRGL_CMD0(VIRGL_CCMD_RESOURCE_COPY_REGION, 0, VIRGL_CMD_RESOURCE_COPY_REGION_SIZE));
   emit(c, dst);
   emit(c, 0);                      /* level */
   emit(c, 0); emit(c, 0); emit(c, 0);
   emit(c, src);
   emit(c, 0);
   emit(c, 0); emit(c, 0); emit(c, 0);
   emit(c, 16); emit(c, 16); emit(c, 1);
}

/* QEMU: one SUBMIT_3D and its fence */
static void submit(int ctx_id, struct cmds *c, uint32_t fence)
{
   virgl_renderer_force_ctx_0();
   check(virgl_renderer_submit_cmd(c->dw, ctx_id, c->n) == 0, "  command buffer");
   c->n = 0;
   if (fence)
      virgl_renderer_create_fence(fence, ctx_id);
}

/* QEMU: a TRANSFER_FROM_HOST_3D (not a command buffer: QEMU asks first) */
static uint32_t read_pixel(uint32_t res, int ctx_id)
{
   static uint32_t pixels[16 * 16];
   memset(pixels, 0, sizeof(pixels));
   struct iovec iov = { pixels, sizeof(pixels) };
   struct virgl_box box = { 0, 0, 0, 16, 16, 1 };
   virgl_renderer_flush_fences();
   virgl_renderer_force_ctx_0();
   if (virgl_renderer_transfer_read_iov(res, ctx_id, 0, 16 * 4, 0, &box, 0, &iov, 1))
      return ~0u;
   return pixels[8 * 16 + 8];
}

static void check_pixel(uint32_t res, int ctx_id, uint32_t want, const char *what)
{
   char text[200];
   uint32_t got = read_pixel(res, ctx_id);
   snprintf(text, sizeof(text), "%s (0x%08x, expected 0x%08x)", what, got, want);
   check(got == want, text);
}

static void colour_buffer(uint32_t handle)
{
   struct virgl_renderer_resource_create_args args = {
      .handle = handle, .target = TEST_TEXTURE_2D, .format = VIRGL_FORMAT_R8G8B8A8_UNORM,
      .bind = VIRGL_BIND_RENDER_TARGET | VIRGL_BIND_SAMPLER_VIEW, .width = 16, .height = 16,
      .depth = 1, .array_size = 1,
   };
   check(!virgl_renderer_resource_create(&args, NULL, 0), "colour buffer");
}

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   const char *env = getenv("OMACVM_VIRGL_FENCE_FLUSH");
   int held = !(env && !strcmp(env, "0"));
   printf("%s\n", held ? "fences held until needed" : "OMACVM_VIRGL_FENCE_FLUSH=0: every fence flushed");
   if (!cgl_init_renderer_main()) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   static int cookie;
   cgl_renderer_callbacks.write_fence = record_fence;
   if (virgl_renderer_init(&cookie, VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB,
                           &cgl_renderer_callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   check(!virgl_renderer_context_create(1, 2, "c1"), "context 1");
   check(!virgl_renderer_context_create(2, 2, "c2"), "context 2");
   colour_buffer(5);
   colour_buffer(7);
   virgl_renderer_ctx_attach_resource(1, 5);
   virgl_renderer_ctx_attach_resource(2, 5);
   virgl_renderer_ctx_attach_resource(2, 7);
   struct cmds c = { .n = 0 };

   printf("1: a held fence signals when QEMU asks\n");
   emit_target(&c, 10, 5);
   emit_clear(&c, RED);
   submit(1, &c, 1);
   int early = fence_signals_poll(1, 300, 0);
   if (held)
      check(!early, "fence 1 not signalled in 300 ms while nothing asks (held)");
   else
      check(early, "fence 1 signalled without being asked");
   virgl_renderer_flush_fences();      /* QEMU: the queue is empty */
   check(fence_signals_poll(1, 2000, 0), "fence 1 signalled once asked");
   emit_clear(&c, RED);
   submit(1, &c, 2);
   check(fence_signals(2, 2000), "a held fence also signals through QEMU's fence timer (poll)");

   printf("2: work held in context 1 is seen by context 2\n");
   emit_clear(&c, GREEN);
   submit(1, &c, 3);
   emit_copy(&c, 7, 5);
   submit(2, &c, 4);
   virgl_renderer_flush_fences();
   check(fence_signals(4, 2000), "fences 3 and 4 signalled");
   check_pixel(7, 2, GREEN, "context 2's copy has context 1's green");
   check_pixel(5, 1, GREEN, "context 1's buffer is green");

   printf("3: a context destroyed with a held fence\n");
   check(!virgl_renderer_context_create(3, 2, "c3"), "context 3");
   virgl_renderer_ctx_attach_resource(3, 7);
   emit_target(&c, 11, 7);
   emit_clear(&c, BLUE);
   submit(3, &c, 5);
   virgl_renderer_ctx_detach_resource(3, 7);
   virgl_renderer_force_ctx_0();
   virgl_renderer_context_destroy(3);
   virgl_renderer_flush_fences();
   check(fence_signals(5, 2000), "fence 5 signalled after its context went");
   check_pixel(7, 2, BLUE, "its clear is there");

   printf("4: 50 command buffers, a fence each, QEMU's hop between them\n");
   static const uint32_t colours[] = { RED, GREEN, BLUE };
   for (uint32_t i = 0; i < 50; i++) {
      emit_clear(&c, colours[i % 3]);
      submit(1, &c, 6 + i);
   }
   virgl_renderer_flush_fences();
   check(fence_signals(55, 2000), "fence 55 signalled");
   check_pixel(5, 1, colours[49 % 3], "the last clear's colour");

   printf("5: a read-back right after a held clear\n");
   emit_clear(&c, RED);
   submit(1, &c, 56);
   check_pixel(5, 1, RED, "read-back sees the held clear");
   check(fence_signals(56, 2000), "fence 56 signalled");


   virgl_renderer_ctx_detach_resource(1, 5);
   virgl_renderer_ctx_detach_resource(2, 5);
   virgl_renderer_ctx_detach_resource(2, 7);
   virgl_renderer_context_destroy(1);
   virgl_renderer_context_destroy(2);
   virgl_renderer_resource_unref(5);
   virgl_renderer_resource_unref(7);
   virgl_renderer_cleanup(&cookie);
   if (failures) {
      printf("fence flush (GL): %d FAILED\n", failures);
      return 1;
   }
   printf("fence flush (GL): all checks passed\n");
   return 0;
}
