/* A fence's glFlush only when something needs it (virgl-fence-flush-on-need.patch).
 * No GL: the GL context callbacks are stubs that keep track of the "current" context,
 * and glFlush/glFenceSync are counted through libepoxy's function pointers. Each case
 * checks how many flushes happened and in which context each one ran (a flush in the
 * wrong context leaves the held work where it was):
 *  - a fence is held while its context goes on; QEMU's hop to ctx0 keeps it held;
 *  - another GL context made current (another guest context, the blitter, a sub
 *    context, ctx0 outside the hop) flushes the held one first, in its own context;
 *  - QEMU's virgl_renderer_flush_fences and the renderer calls flush it whatever is
 *    current (QEMU's own context in between), then make vrend's context current again;
 *  - the age limit; a destroyed context; a fence in ctx0 while another one holds;
 *  - another thread (the sync thread) neither flushes nor changes the render
 *    thread's view; a fence made on another thread is flushed at once;
 *  - OMACVM_VIRGL_FENCE_FLUSH=0 flushes every fence at once;
 *  - nothing held: asking costs no context switch. */
#include "vrend/vrend_renderer.c"

enum { NONE = 0, A = 1, B = 2, ZERO = 3, BLIT = 4, QEMU_VIEW = 5, SYNC = 6, A2 = 7, NCTX = 8 };
static int ids[NCTX];               /* fake context handles: &ids[n] */
#define CTX(n) ((virgl_gl_context)&ids[n])
static int current;                 /* the context really current on the render thread */
static int switches, destroyed_ctx;
static int flushes, flushed_in[64];
static int fence_syncs;

static int id_of(virgl_gl_context c)
{
   return c ? (int)((int *)c - ids) : NONE;
}

static int fake_make_current(virgl_gl_context ctx)
{
   current = id_of(ctx);
   switches++;
   return 0;
}
static void fake_destroy(virgl_gl_context ctx)
{
   destroyed_ctx = id_of(ctx);
}
static void APIENTRY fake_flush(void)
{
   if (flushes < 64)
      flushed_in[flushes] = current;
   flushes++;
}
static GLsync APIENTRY fake_fence_sync(GLenum cond, GLbitfield flags)
{
   (void)cond; (void)flags;
   fence_syncs++;
   return (GLsync)(uintptr_t)(0x1000 + fence_syncs);
}
static void APIENTRY fake_wait_sync(GLsync s, GLbitfield f, GLuint64 t)
{
   (void)s; (void)f; (void)t;
}
static void APIENTRY fake_delete_sync(GLsync s)
{
   (void)s;
}

static struct vrend_if_cbs cbs = {
   .make_current = fake_make_current,
   .make_current_surfaceless = fake_make_current,
   .destroy_gl_context = fake_destroy,
   .destroy_gl_context_surfaceless = fake_destroy,
};

static int failures;
static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

/* guest contexts with one sub context (one GL context) each */
static struct vrend_sub_context sub_a, sub_b, sub_zero, sub_a2;
static struct vrend_context ctx_a, ctx_b, ctx_zero;
static uint64_t fence_id;

static void reset_counts(void)
{
   flushes = 0;
   switches = 0;
   memset(flushed_in, 0, sizeof(flushed_in));
}

static void fence(void)
{
   check(vrend_renderer_create_fence(&ctx_zero, VIRGL_RENDERER_FENCE_FLAG_MERGEABLE,
                                     ++fence_id) == 0, "  fence made");
}

static void use(struct vrend_context *c)
{
   vrend_hw_switch_context(c, true);
}

static void init(const char *on, const char *us)
{
   if (on) setenv("OMACVM_VIRGL_FENCE_FLUSH", on, 1); else unsetenv("OMACVM_VIRGL_FENCE_FLUSH");
   if (us) setenv("OMACVM_VIRGL_FENCE_FLUSH_US", us, 1); else unsetenv("OMACVM_VIRGL_FENCE_FLUSH_US");
   fence_flush_init(&cbs);
   vrend_state.current_ctx = NULL;
   vrend_state.current_hw_ctx = NULL;
   current = NONE;
}

static int other_thread_case;
static int other_thread(void *arg)
{
   (void)arg;
   if (other_thread_case == 0) {
      /* the sync thread makes its own context current */
      vrend_clicbs->make_current_surfaceless(CTX(SYNC));
   } else {
      vrend_renderer_create_fence(&ctx_zero, 0, ++fence_id);
   }
   return 0;
}
static void run_on_other_thread(int which)
{
   thrd_t t;
   other_thread_case = which;
   int saved = current;
   thrd_create(&t, other_thread, NULL);
   thrd_join(t, NULL);
   current = saved; /* the fake "current" is global; a thread's own one is its business */
}

int main(void)
{
   setvbuf(stdout, NULL, _IONBF, 0);
   epoxy_glFlush = fake_flush;
   epoxy_glFenceSync = fake_fence_sync;
   epoxy_glWaitSync = fake_wait_sync;
   epoxy_glDeleteSync = fake_delete_sync;
   list_inithead(&vrend_state.fence_list);
   list_inithead(&vrend_state.fence_wait_list);
   vrend_state.sync_thread = false;

   sub_a.gl_context = CTX(A);
   sub_a2.gl_context = CTX(A2);
   sub_b.gl_context = CTX(B);
   sub_zero.gl_context = CTX(ZERO);
   ctx_a.sub = &sub_a;  ctx_a.ctx_id = 1;
   ctx_b.sub = &sub_b;  ctx_b.ctx_id = 2;
   ctx_zero.sub = &sub_zero; ctx_zero.ctx_id = 0;
   vrend_state.ctx0 = &ctx_zero;

   init(NULL, "1000000");   /* 1 s: no age flush unless a case wants one */

   printf("1: held while the same context goes on; QEMU's hop to ctx0 keeps it held\n");
   vrend_renderer_force_ctx_0();
   use(&ctx_a);
   reset_counts();
   fence();
   check(flushes == 0, "fence after a command buffer: no flush");
   vrend_renderer_force_ctx_0();
   check(current == ZERO && flushes == 0, "hop to ctx0: no flush");
   use(&ctx_a);
   fence();
   check(flushes == 0 && fence_flush.stats.held == 2, "next command buffer of the same context: still held (2 held)");

   printf("2: another guest context flushes the held one, in its own context\n");
   vrend_renderer_force_ctx_0();
   reset_counts();
   use(&ctx_b);
   check(flushes == 1 && flushed_in[0] == A, "switch to B: one flush, in A");
   check(current == B && !fence_flush.gl, "B current, nothing held");
   fence();                              /* held in B */
   reset_counts();
   vrend_clicbs->make_current_surfaceless(CTX(A));
   check(flushes == 1 && flushed_in[0] == B && current == A, "surfaceless switch to A: one flush, in B");
   vrend_clicbs->make_current(CTX(B));

   printf("3: QEMU asks between commands, with its own context current\n");
   fence();                              /* held in B */
   vrend_renderer_force_ctx_0();         /* next command: hop */
   current = QEMU_VIEW;                  /* QEMU's display made its own context current */
   reset_counts();
   vrend_renderer_flush_fences();
   check(flushes == 1 && flushed_in[0] == B, "flush_fences: one flush, in B (not QEMU's context)");
   check(current == ZERO, "vrend's last context (ctx0) current again");
   reset_counts();
   vrend_renderer_flush_fences();
   check(flushes == 0 && switches == 0, "nothing held: no flush, no context switch");

   printf("4: ctx0 made current outside the hop flushes\n");
   use(&ctx_a);
   fence();
   reset_counts();
   vrend_hw_switch_context(&ctx_zero, true);
   check(flushes == 1 && flushed_in[0] == A, "ctx0 for real work: one flush, in A");

   printf("5: a sub context switch and the blitter flush\n");
   use(&ctx_a);
   fence();
   reset_counts();
   ctx_a.sub = &sub_a2;                  /* the guest's SET_SUB_CTX (vrend_renderer_set_sub_ctx) */
   vrend_clicbs->make_current(sub_a2.gl_context);
   check(flushes == 1 && flushed_in[0] == A && current == A2, "sub context switch: one flush, in the old one");
   ctx_a.sub = &sub_a;
   vrend_clicbs->make_current(sub_a.gl_context);
   fence();
   reset_counts();
   vrend_sync_make_current(CTX(BLIT));
   check(flushes == 1 && flushed_in[0] == A && current == BLIT, "blitter: one flush, in A, then the blitter");
   vrend_sync_make_current(CTX(A));

   printf("6: the age limit\n");
   fence_flush.max_age_ns = 1000000;     /* 1 ms */
   reset_counts();
   fence();
   check(flushes == 0, "first fence held");
   struct timespec ms = { 0, 2000000 };
   nanosleep(&ms, NULL);
   fence();
   check(flushes == 1 && flushed_in[0] == A && !fence_flush.gl, "fence 2 ms after the first held one: flushed, in A");
   fence_flush.max_age_ns = 1000000000ull;

   printf("7: a context destroyed with a held fence\n");
   fence();
   vrend_renderer_force_ctx_0();
   reset_counts();
   destroyed_ctx = NONE;
   vrend_clicbs->destroy_gl_context(CTX(A));
   check(flushes == 1 && flushed_in[0] == A, "destroy: one flush, in A");
   check(destroyed_ctx == A && current == ZERO && !fence_flush.gl, "then destroyed; ctx0 current again");
   fence_flush.cur = CTX(ZERO);

   printf("8: a fence in ctx0 while another context holds\n");
   use(&ctx_b);
   fence();
   vrend_renderer_force_ctx_0();
   reset_counts();
   fence();                              /* a command buffer that never switched */
   check(flushes == 2 && flushed_in[0] == B && flushed_in[1] == ZERO,
         "two flushes: the older (B) first, then ctx0");
   check(current == ZERO && !fence_flush.gl, "ctx0 current, nothing held");

   printf("9: other threads\n");
   use(&ctx_b);
   fence();
   reset_counts();
   run_on_other_thread(0);
   check(flushes == 0 && fence_flush.cur == CTX(B) && fence_flush.gl == CTX(B),
         "sync thread's make-current: no flush, render thread's view kept");
   run_on_other_thread(1);
   check(flushes == 1 && fence_flush.gl == CTX(B), "fence made on another thread: flushed at once, B still held");
   vrend_renderer_flush_fences();

   printf("10: nothing made current yet\n");
   init(NULL, NULL);
   check(fence_flush.max_age_ns == 2000000, "default age limit 2000 us");
   reset_counts();
   fence();
   check(flushes == 1, "fence with no known context: flushed at once");

   printf("11: OMACVM_VIRGL_FENCE_FLUSH=0\n");
   init("0", NULL);
   vrend_renderer_force_ctx_0();
   use(&ctx_a);
   reset_counts();
   fence();
   fence();
   check(flushes == 2 && flushed_in[0] == A && flushed_in[1] == A, "every fence flushed at once");
   vrend_renderer_force_ctx_0();
   use(&ctx_b);
   check(flushes == 2, "and nothing held for a switch");

   printf("12: bad OMACVM_VIRGL_FENCE_FLUSH_US values fall back to 2000\n");
   const char *bad[] = { "", "abc", "0", "12x", "2000000" };
   for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
      init(NULL, bad[i]);
      check(fence_flush.max_age_ns == 2000000 && fence_flush.on, bad[i]);
   }
   init(NULL, "500");
   check(fence_flush.max_age_ns == 500000, "500 us taken");

   if (failures) {
      printf("fence flush: %d FAILED\n", failures);
      return 1;
   }
   printf("fence flush: all checks passed\n");
   return 0;
}
