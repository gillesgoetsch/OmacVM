/* The rules of the restart backoff (virgl-venus-device-lost-backoff.patch,
 * src/venus/vkr_restart_guard.h): how long new Venus devices wait after the Mac's driver
 * lost one, how reports of one restart count once, the doubling, the cap and the reset.
 * No GPU, no vkr: CI and the runtime build run it (test-venus-restart-guard.sh). */
#include <stdio.h>
#include <stdint.h>
#include "vkr_restart_guard.h"

#define S VKR_RESTART_GUARD_SEC

static int failures;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

int main(void)
{
   struct vkr_restart_guard g = {0};
   const uint64_t t0 = 1000 * S;

   check(vkr_restart_guard_wait_ns(&g, t0) == 0, "no lost device yet: devices are made");

   /* the first restart: 10 s */
   check(vkr_restart_guard_lost(&g, t0), "first report counts");
   check(g.strikes == 1, "one restart counted");
   check(vkr_restart_guard_wait_ns(&g, t0) == 10 * S, "new devices wait 10 s");
   check(vkr_restart_guard_wait_ns(&g, t0 + 4 * S) == 6 * S, "4 s later: 6 s left");
   check(vkr_restart_guard_wait_ns(&g, t0 + 10 * S) == 0, "10 s later: devices are made again");

   /* one restart, seen by every queue, fence and context: counts once */
   check(!vkr_restart_guard_lost(&g, t0 + S / 2), "a report 0.5 s later is the same restart");
   check(!vkr_restart_guard_lost(&g, t0 + S + S / 2), "a report 1.5 s later is the same restart");
   check(g.strikes == 1, "still one restart");
   check(vkr_restart_guard_wait_ns(&g, t0 + 9 * S) == 1 * S, "the same restart does not move the wait");

   /* reports that keep coming do not stretch the window: 2 s from the counted one */
   check(vkr_restart_guard_lost(&g, t0 + 2 * S), "2 s after the counted one: a new restart");
   check(g.strikes == 2, "two restarts");
   check(vkr_restart_guard_wait_ns(&g, t0 + 2 * S) == 20 * S, "second restart: 20 s");

   /* doubling to the cap */
   uint64_t t = t0 + 100 * S;
   for (int i = 3; i <= 12; i++, t += 700 * S)
      vkr_restart_guard_lost(&g, t);
   check(g.strikes == 12, "twelve restarts, each within 30 min of the last");
   check(vkr_restart_guard_hold_ns(3) == 40 * S && vkr_restart_guard_hold_ns(6) == 320 * S,
         "40 s at the third, 320 s at the sixth");
   check(vkr_restart_guard_hold_ns(7) == 600 * S, "the seventh is capped at 10 min (not 640 s)");
   check(vkr_restart_guard_hold_ns(UINT32_MAX) == 600 * S, "no overflow at any count: 10 min");
   check(vkr_restart_guard_wait_ns(&g, t - 700 * S) == 600 * S, "the last one waits 10 min");

   /* 30 min without a lost device: back to 10 s */
   t += 1800 * S;
   check(vkr_restart_guard_lost(&g, t), "a restart after 30 min quiet counts");
   check(g.strikes == 1, "and starts again at one");
   check(vkr_restart_guard_wait_ns(&g, t) == 10 * S, "10 s again");

   /* just under 30 min: keeps doubling */
   struct vkr_restart_guard h = {0};
   vkr_restart_guard_lost(&h, t0);
   vkr_restart_guard_lost(&h, t0 + 1799 * S);
   check(h.strikes == 2 && vkr_restart_guard_wait_ns(&h, t0 + 1799 * S) == 20 * S,
         "29 min 59 s after the last: the second restart, 20 s");

   /* a clock that goes back (it is CLOCK_MONOTONIC, but the rules do not rely on it) */
   struct vkr_restart_guard k = {0};
   vkr_restart_guard_lost(&k, t0);
   check(vkr_restart_guard_lost(&k, t0 - 5 * S) && k.strikes == 2, "an earlier time counts, no wrap");
   check(vkr_restart_guard_wait_ns(&k, t0 - 5 * S) == 20 * S, "and waits from that time");

   printf("%s\n", failures ? "FAIL" : "all ok");
   return failures ? 1 : 0;
}
