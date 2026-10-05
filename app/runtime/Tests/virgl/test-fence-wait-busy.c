/* The sync thread's wait while the render thread runs commands (virgl-darwin-fence-wait-busy.patch):
 * a submit in progress, or one that ended less than the grace period ago, counts as busy; a waiting sync
 * thread wakes when the submit ends, or after at most FENCE_BUSY_NAP; an idle render thread does not
 * make it wait. No GL. */
#include "vrend/vrend_renderer.c"
#include <pthread.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL: %s\n", #c); return 1; } } while (0)

static mach_timebase_info_data_t tbi;
static uint64_t now_ns(void) { return mach_absolute_time() * tbi.numer / tbi.denom; }
static uint64_t ticks(uint64_t ns) { return ns * tbi.denom / tbi.numer; }
static void sleep_ns(uint64_t ns) { mach_wait_until(mach_absolute_time() + ticks(ns)); }

static uint64_t busy_for_ns, ended_at;
static void *render(void *arg)
{
   (void)arg;
   sleep_ns(busy_for_ns);
   ended_at = now_ns();
   vrend_renderer_submit_end();
   return NULL;
}

/* The render thread starts a submit, the sync thread waits; returns when the wait ended. */
static uint64_t wait_while_busy(uint64_t busy_ns)
{
   pthread_t t;
   busy_for_ns = busy_ns;
   vrend_renderer_submit_begin();
   uint64_t t0 = now_ns();
   pthread_create(&t, NULL, render, NULL);
   fence_wait_render(mach_absolute_time());
   uint64_t woke = now_ns();
   pthread_join(t, NULL);
   return woke - t0;
}

int main(void)
{
   mach_timebase_info(&tbi);
   CHECK(semaphore_create(mach_task_self(), &fence_busy_sem, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS);
   fence_busy_on = true;

   /* Idle from the start: not busy, no wait. */
   CHECK(!fence_render_busy(mach_absolute_time()));

   /* A submit in progress is busy; just after it ended too (grace); later not. */
   vrend_renderer_submit_begin();
   CHECK(fence_render_busy(mach_absolute_time()));
   vrend_renderer_submit_end();
   CHECK(fence_render_busy(mach_absolute_time()));
   sleep_ns(2 * FENCE_BUSY_GRACE_NS);
   CHECK(!fence_render_busy(mach_absolute_time()));

   /* A short submit: the waiter wakes when it ends, not on the 1 ms timer. */
   int early = 0;
   for (int i = 0; i < 20; i++) {
      uint64_t w = wait_while_busy(300000);
      CHECK(w >= 250000);                  /* not before the end */
      if (w < 700000)
         early++;
   }
   fprintf(stderr, "woken at the end of a 300 us submit: %d of 20\n", early);
   CHECK(early >= 15);
   sleep_ns(2 * FENCE_BUSY_GRACE_NS);

   /* A long submit: the waiter tests again after at most about 1 ms. */
   for (int i = 0; i < 5; i++) {
      uint64_t w = wait_while_busy(10000000);
      CHECK(w >= FENCE_BUSY_NAP_NS * 9 / 10 && w < 5000000);
      sleep_ns(10000000 + 2 * FENCE_BUSY_GRACE_NS);   /* let that submit end */
   }

   /* Ended just now: the waiter only sits out the rest of the grace period. */
   vrend_renderer_submit_begin();
   vrend_renderer_submit_end();
   uint64_t t0 = now_ns();
   fence_wait_render(mach_absolute_time());
   uint64_t w = now_ns() - t0;
   CHECK(w < FENCE_BUSY_GRACE_NS + 200000);
   CHECK(!fence_render_busy(mach_absolute_time()));

   /* No stray wake-up left behind for the next wait. */
   CHECK(!atomic_load(&fence_busy_waiting));
   fprintf(stderr, "PASS: fence waits follow the render thread's submits\n");
   return 0;
}
