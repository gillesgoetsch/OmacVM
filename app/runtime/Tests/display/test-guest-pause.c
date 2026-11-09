/*
 * Pause drawing while hidden (omacvm-guest-pause.h, from
 * omacvm-cocoa-guest-pause-logic.patch): when the guest is told that the
 * VM's window is out of sight and seen again, and when the window keeps its
 * last picture. test-guest-pause.sh builds it against the patch.
 */
#include <stdio.h>
#include "omacvm-guest-pause.h"

static int fails;
static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        fails++;
    }
}

static OmacVMGuestPause fresh(void)
{
    return (OmacVMGuestPause){ .seen = true };
}

int main(void)
{
    OmacVMGuestPause p = fresh();

    /* Switch off: nothing is ever told, whatever the window does. */
    check(omacvm_gp_feed(&p, false, false, 10) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0 &&
          omacvm_gp_due(&p, 100) == OMACVM_GP_NONE && !p.hold,
          "switch off: an unseen window changes nothing");

    /* Out of sight: told only after OMACVM_GP_AFTER_S. */
    p = fresh();
    check(omacvm_gp_feed(&p, true, false, 10) == OMACVM_GP_NONE, "out of sight: nothing told at once");
    check(omacvm_gp_due_at(&p) == 10 + OMACVM_GP_AFTER_S, "... due after OMACVM_GP_AFTER_S");
    check(omacvm_gp_due(&p, 11) == OMACVM_GP_NONE, "... not before");
    check(omacvm_gp_feed(&p, true, false, 11.5) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 12,
          "... another 'out of sight' does not move the time");
    check(omacvm_gp_due(&p, 12) == OMACVM_GP_UNSEEN && p.told && p.hold, "... then the guest is told unseen");
    check(omacvm_gp_due(&p, 13) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0, "... once");
    check(omacvm_gp_feed(&p, true, false, 20) == OMACVM_GP_NONE, "... still out of sight: nothing new");

    /* While told: the window keeps its last picture when the guest has no scanout. */
    check(omacvm_gp_keep(&p, false, 20), "told: no guest scanout: keep the last picture");
    check(!omacvm_gp_keep(&p, true, 20), "told: a guest scanout is drawn");
    check(omacvm_gp_frame(&p) == 0, "told: a frame (a guest that kept drawing) does not end the hold");

    /* Seen again: told at once; the hold until the first frame, at most OMACVM_GP_HOLD_S. */
    check(omacvm_gp_feed(&p, true, true, 30) == OMACVM_GP_SEEN && !p.told && p.paused_s == 18,
          "seen again: told at once (paused 18 s)");
    check(p.hold && omacvm_gp_keep(&p, false, 30.5), "... the last picture is kept while the guest's display is off");
    check(omacvm_gp_frame(&p) == 1 && !p.hold && !omacvm_gp_keep(&p, false, 30.6),
          "... the guest's first frame ends the hold");
    check(omacvm_gp_frame(&p) == 2 && omacvm_gp_frame(&p) == 3 && omacvm_gp_frame(&p) == 0,
          "... frames counted up to 3 (the log)");
    check(omacvm_gp_feed(&p, true, true, 31) == OMACVM_GP_NONE, "... seen again: nothing more to tell");

    /* No frame from the guest after "seen" (an older agent, a guest that went away): the hold ends. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_due(&p, OMACVM_GP_AFTER_S);
    omacvm_gp_feed(&p, true, true, 10);
    check(omacvm_gp_keep(&p, false, 10 + OMACVM_GP_HOLD_S), "no frame yet: kept up to OMACVM_GP_HOLD_S");
    check(!omacvm_gp_keep(&p, false, 10 + OMACVM_GP_HOLD_S + 0.01) && !p.hold, "... not after it");

    /* A short look away: never told. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 5);
    check(omacvm_gp_feed(&p, true, true, 5 + OMACVM_GP_AFTER_S - 0.1) == OMACVM_GP_NONE &&
          omacvm_gp_due(&p, 100) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0 && !p.hold,
          "back within OMACVM_GP_AFTER_S: the guest is never told");
    omacvm_gp_feed(&p, true, false, 50);
    check(omacvm_gp_due_at(&p) == 50 + OMACVM_GP_AFTER_S, "... the next time away counts from then");

    /* The switch goes off while told: seen at once; on again while out of sight: counts anew. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_due(&p, 3);
    check(omacvm_gp_feed(&p, false, false, 4) == OMACVM_GP_SEEN, "switch off while told: the guest draws again at once");
    check(omacvm_gp_due(&p, 100) == OMACVM_GP_NONE, "... and is not told unseen while off");
    check(omacvm_gp_feed(&p, true, false, 10) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 10 + OMACVM_GP_AFTER_S,
          "switch on again while out of sight: told after OMACVM_GP_AFTER_S from then");
    check(omacvm_gp_due(&p, 10 + OMACVM_GP_AFTER_S) == OMACVM_GP_UNSEEN, "... then told");

    /* The switch turned on while the window is seen: nothing to tell. */
    p = fresh();
    check(omacvm_gp_feed(&p, true, true, 1) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0,
          "switch on, window seen: nothing");

    /* The switch off while a pending "unseen" waits: it never comes. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_feed(&p, false, false, 1);
    check(omacvm_gp_due(&p, 5) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0, "switch off before it was due: never told");

    /* Again, in case the guest did not get it: the lease while told, "seen" until its first frame. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_due(&p, 2);
    check(omacvm_gp_again_at(&p) == 2 + OMACVM_GP_LEASE_S && omacvm_gp_again(&p, 2 + OMACVM_GP_LEASE_S - 0.1) == OMACVM_GP_NONE,
          "told: the lease is due OMACVM_GP_LEASE_S after the last word");
    check(omacvm_gp_again(&p, 2 + OMACVM_GP_LEASE_S) == OMACVM_GP_UNSEEN && omacvm_gp_again_at(&p) == 2 + 2 * OMACVM_GP_LEASE_S,
          "... then \"unseen\" again, the next one a lease later");
    omacvm_gp_feed(&p, true, true, 20);
    check(omacvm_gp_again_at(&p) == 20 + OMACVM_GP_RESEND_S && omacvm_gp_again(&p, 20.1) == OMACVM_GP_NONE,
          "seen: \"seen\" again after OMACVM_GP_RESEND_S, not before");
    check(omacvm_gp_again(&p, 20 + OMACVM_GP_RESEND_S) == OMACVM_GP_SEEN, "... then \"seen\" again (a lost line)");
    omacvm_gp_frame(&p);
    check(omacvm_gp_again_at(&p) == 0 && omacvm_gp_again(&p, 21) == OMACVM_GP_NONE, "... until the guest's first frame");
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_due(&p, 2);
    omacvm_gp_feed(&p, true, true, 10);
    double t = 10;
    int n = 0;
    while (omacvm_gp_again_at(&p) > 0 && n < 100) {
        t = omacvm_gp_again_at(&p);
        n += omacvm_gp_again(&p, t) == OMACVM_GP_SEEN;
    }
    check(n > 0 && t < 10 + OMACVM_GP_RESEND_FOR_S, "no frame ever: \"seen\" again only for OMACVM_GP_RESEND_FOR_S");
    p = fresh();
    check(omacvm_gp_again_at(&p) == 0 && omacvm_gp_again(&p, 100) == OMACVM_GP_NONE, "never told: nothing again");

    /* Never paused: no hold, frames are not counted. */
    p = fresh();
    check(!omacvm_gp_keep(&p, false, 1) && omacvm_gp_frame(&p) == 0, "never paused: nothing kept, nothing counted");

    /* qemu.log: a line when the word or what became of it changes, never for the lease or a repeated "seen". */
    OmacVMGpLog l = { 0 };
    check(omacvm_gp_log(&l, OMACVM_GP_NONE, OMACVM_GP_SENT, 1) == OMACVM_GP_QUIET, "log: nothing to say, no line");
    check(omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_SENT, 1) == OMACVM_GP_SAY, "log: \"unseen\" sent: a line");
    n = 0;
    for (t = 6; t < 3600; t += OMACVM_GP_LEASE_S) {
        n += omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_SENT, t) != OMACVM_GP_QUIET;
    }
    check(n == 0, "log: an hour of leases: no more lines");
    check(omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_NO_CHANNEL, 3600) == OMACVM_GP_SAY &&
          omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_NO_CHANNEL, 3605) == OMACVM_GP_QUIET,
          "log: the lease dropped (channel closed): one line, then quiet");
    check(omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_SENT, 3610) == OMACVM_GP_SAY,
          "log: sent again after the channel came back: a line");
    check(omacvm_gp_log(&l, OMACVM_GP_SEEN, OMACVM_GP_SENT, 3620) == OMACVM_GP_SAY, "log: \"seen\" sent: a line");
    n = 0;
    for (t = 3620; t < 3625; t += OMACVM_GP_RESEND_S) {
        n += omacvm_gp_log(&l, OMACVM_GP_SEEN, OMACVM_GP_SENT, t) != OMACVM_GP_QUIET;
    }
    check(n == 0, "log: \"seen\" said again until the first frame: no more lines");
    check(omacvm_gp_log(&l, OMACVM_GP_SEEN, OMACVM_GP_NOT_TAKEN, 3626) == OMACVM_GP_SAY,
          "log: a line the channel did not take: a line");

    /* A window going in and out of sight all the time: at most OMACVM_GP_LOG_MAX lines in OMACVM_GP_LOG_EVERY_S. */
    l = (OmacVMGpLog){ 0 };
    unsigned said = 0, last = 0;
    for (t = 0; t < OMACVM_GP_LOG_EVERY_S - 1; t += 3) {
        OmacVMGpSay s = omacvm_gp_log(&l, (int)(t / 3) % 2 ? OMACVM_GP_SEEN : OMACVM_GP_UNSEEN, OMACVM_GP_SENT, t);
        said += s != OMACVM_GP_QUIET;
        last += s == OMACVM_GP_SAY_LAST;
    }
    check(said == OMACVM_GP_LOG_MAX && last == 1, "log: flapping: OMACVM_GP_LOG_MAX lines, the last says the rest are left out");
    /* A change while capped is left out, not kept as said: the lease repeats it, and it is said once the cap ends. */
    check(omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_NO_CHANNEL, OMACVM_GP_LOG_EVERY_S - 0.5) == OMACVM_GP_QUIET,
          "log: capped: a new reason is left out");
    check(omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_NO_CHANNEL, OMACVM_GP_LOG_EVERY_S + 1) == OMACVM_GP_SAY,
          "log: the lease after the cap: the reason left out is said");
    check(omacvm_gp_log(&l, OMACVM_GP_UNSEEN, OMACVM_GP_NO_CHANNEL, OMACVM_GP_LOG_EVERY_S + 6) == OMACVM_GP_QUIET,
          "log: and then quiet again");
    return fails ? 1 : 0;
}
