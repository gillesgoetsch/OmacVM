/*
 * The guest's Caps Lock follows the Mac's (#784, omacvm-cocoa-caps-lock-logic.patch).
 * A model guest: each press flips its lock (or not, when its Caps Lock key does not
 * lock), its LED shows the lock some milliseconds later and QEMU's LED notifier
 * passes each change on, a new session or a restart clears both. Runs the report's cases, the guards, and a seeded random run through
 * ui/omacvm-capslock.h, and through QEMU's old rule (the presses it sent), which must
 * fail the report's cases.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "omacvm-capslock.h"

typedef struct {
    bool lock, led, locks;      /* locks: the Caps Lock key locks (no Compose etc.) */
    bool listening;             /* the guest's keyboard driver runs (virtio-input active) */
    int latency;                /* ms from a press to the LED */
    int64_t led_at;             /* a LED change on its way, at this time (0: none) */
    bool led_to;
    int presses;
} Guest;

static OmacVMCaps st;
static bool old_rule, old_sent;
static int64_t now;
static int fails;

static void guest_tick(Guest *g)
{
    if (g->led_at && now >= g->led_at) {
        g->led = g->led_to;
        g->led_at = 0;
        if (!old_rule) {
            omacvm_caps_led(&st, g->led, now);   /* QEMU's LED notifier */
        }
    }
}

static void guest_press(Guest *g)
{
    g->presses++;
    if (!g->locks || !g->listening) {
        return;
    }
    g->lock = !g->lock;
    g->led_at = now + g->latency;
    g->led_to = g->lock;
}

/* The guest loses its lock (a new session, a restart): the LED goes off too. */
static void guest_reset(Guest *g)
{
    g->lock = false;
    g->led_at = now + g->latency;
    g->led_to = false;
}

/* A restart inside the VM: the device resets (QEMU clears its LEDs and tells the
   notifier), nothing listens until the guest's driver starts again. */
static void guest_stop(Guest *g)
{
    g->listening = false;
    g->lock = false;
    g->led = false;
    g->led_at = 0;
    if (!old_rule) {
        omacvm_caps_led(&st, false, now);
    }
}

/* The guest's keyboard driver starts: the notifier hears it, the LEDs as they are. */
static void guest_start(Guest *g)
{
    g->listening = true;
    if (!old_rule) {
        omacvm_caps_led(&st, g->led, now);
    }
}

/* One input event with the Mac's flag, at the current time. */
static void ev(Guest *g, bool mac)
{
    guest_tick(g);
    bool press;
    if (old_rule) {
        press = mac != old_sent;
        if (press) {
            old_sent = mac;
        }
    } else {
        press = omacvm_caps_step(&st, mac, now);
    }
    if (press) {
        guest_press(g);
    }
}

static void wait_ms(Guest *g, int ms)
{
    for (int i = 0; i < ms; i++) {
        now++;
        guest_tick(g);
    }
}

static void fresh(Guest *g, int latency, bool locks)
{
    memset(g, 0, sizeof(*g));
    g->latency = latency;
    g->locks = locks;
    g->listening = true;
    memset(&st, 0, sizeof(st));
    old_sent = false;
    now = 100000;
}

static void check(bool ok, const char *what)
{
    if (!ok) {
        fails++;
    }
    if (!old_rule || !ok) {
        printf("%s %s%s\n", ok ? "ok  " : "FAIL", old_rule ? "(old rule) " : "", what);
    }
}

/* The report: Caps Lock on, the guest loses it, Caps Lock off on the Mac. */
static bool report_case(void (*lose)(Guest *))
{
    Guest g;
    fresh(&g, 15, true);
    ev(&g, true);                     /* Caps Lock on */
    wait_ms(&g, 700);
    ev(&g, true);
    lose(&g);
    wait_ms(&g, 700);
    ev(&g, true);                     /* the next key or pointer move in the VM */
    wait_ms(&g, 700);
    ev(&g, true);
    bool on_ok = g.lock;
    ev(&g, false);                    /* Caps Lock off on the Mac */
    wait_ms(&g, 700);
    ev(&g, false);
    return on_ok && !g.lock && !g.led;
}

static void lose_session(Guest *g) { guest_reset(g); }

static void cases(void)
{
    Guest g;

    fresh(&g, 15, true);
    ev(&g, false);
    check(g.presses == 0, "the Mac's Caps Lock off at the start: no press");
    ev(&g, true);
    wait_ms(&g, 20);
    ev(&g, true);
    check(g.presses == 1 && g.lock, "Caps Lock on: one press, the guest's lock on");
    for (int i = 0; i < 50; i++) {
        wait_ms(&g, 7);
        ev(&g, true);
    }
    check(g.presses == 1, "... the same flag on 50 events: no second press");
    ev(&g, false);
    ev(&g, false);
    wait_ms(&g, 20);
    ev(&g, false);
    check(g.presses == 2 && !g.lock, "Caps Lock off: one press, the guest's lock off");

    check(report_case(lose_session),
          "#784: the guest loses its lock (new session, restart) with the Mac's on: "
          "put back at the next event, and off with the Mac's");

    /* Caps Lock on while the guest is starting: the presses go nowhere; as the
       guest's keyboard starts, the next event puts the lock on. */
    fresh(&g, 15, true);
    g.listening = false;
    for (int i = 0; i < 20; i++) {
        wait_ms(&g, 100);
        ev(&g, true);
    }
    guest_start(&g);
    wait_ms(&g, 200);
    ev(&g, true);
    wait_ms(&g, 100);
    ev(&g, true);
    check(g.lock && g.presses <= 3, "Caps Lock on while the guest starts (presses lost): on at the first event after its keyboard starts");

    /* #784 C5 on the Mac mini: a restart inside the VM with the Mac's on, events
       during the restart, the session comes up with its lock off. */
    fresh(&g, 15, true);
    ev(&g, true);
    wait_ms(&g, 700);
    guest_stop(&g);
    for (int i = 0; i < 30; i++) {
        wait_ms(&g, 100);
        ev(&g, true);
    }
    guest_start(&g);
    wait_ms(&g, 300);
    ev(&g, true);              /* the kernel's console takes the lock ... */
    wait_ms(&g, 700);
    guest_reset(&g);           /* ... the desktop session starts with it off */
    wait_ms(&g, 700);
    ev(&g, true);
    wait_ms(&g, 700);
    ev(&g, true);
    bool on_after = g.lock;
    ev(&g, false);
    wait_ms(&g, 700);
    ev(&g, false);
    check(on_after && !g.lock, "a restart inside the VM with the Mac's on (events during it): on after the session starts, off with the Mac's");

    /* A Caps Lock key that does not lock, across a restart: at most one more press. */
    fresh(&g, 15, false);
    ev(&g, true);
    wait_ms(&g, 700);
    guest_stop(&g);
    wait_ms(&g, 3000);
    guest_start(&g);
    for (int i = 0; i < 100; i++) {
        wait_ms(&g, 50);
        ev(&g, true);
    }
    check(g.presses <= 2, "Caps Lock as Compose, a restart inside the VM: at most one more press for it");

    /* The guest's Caps Lock key does not lock (Compose, Escape): its LED never moves. */
    fresh(&g, 15, false);
    ev(&g, true);
    for (int i = 0; i < 400; i++) {
        wait_ms(&g, 25);
        ev(&g, true);
    }
    check(g.presses == 1, "Caps Lock as Compose in the guest: one press for the Mac's change, none on 400 more events");
    ev(&g, false);
    for (int i = 0; i < 100; i++) {
        wait_ms(&g, 25);
        ev(&g, false);
    }
    check(g.presses == 2, "... and one for the change back");

    /* Set in the guest (another keyboard) with the Mac's off: kept until the Mac's flag changes. */
    fresh(&g, 15, true);
    ev(&g, false);
    g.lock = true;
    g.led_at = now + 15;
    g.led_to = true;
    for (int i = 0; i < 100; i++) {
        wait_ms(&g, 20);
        ev(&g, false);
    }
    check(g.presses == 0 && g.lock, "Caps Lock set in the guest by another keyboard: kept, no press on 100 events");
    ev(&g, true);
    wait_ms(&g, 30);
    ev(&g, true);
    check(g.presses == 0 && g.lock, "... the Mac's on as well: no press (already on)");
    ev(&g, false);
    wait_ms(&g, 30);
    ev(&g, false);
    check(g.presses == 1 && !g.lock, "... the Mac's off: one press, off");

    /* #784 on the Mac mini: our presses answered, then the lock set in the guest
       between two events: kept; the Mac's on and off follow. */
    fresh(&g, 3, true);
    ev(&g, true);
    wait_ms(&g, 600);
    ev(&g, false);
    wait_ms(&g, 10);
    g.lock = true;
    g.led_at = now + 3;
    g.led_to = true;
    wait_ms(&g, 600);
    for (int i = 0; i < 5; i++) {
        wait_ms(&g, 100);
        ev(&g, false);
    }
    bool kept = g.lock;
    ev(&g, true);
    wait_ms(&g, 600);
    bool on = g.lock;
    ev(&g, false);
    wait_ms(&g, 600);
    check(kept && on && !g.lock && g.presses == 3,
          "our presses answered, then the lock set in the guest: kept, on with the Mac's on, off with the Mac's off");

    /* Two changes faster than the LED: no extra press while ours are on their way. */
    for (int lat = 5; lat <= 450; lat += 445) {
        fresh(&g, lat, true);
        ev(&g, true);
        wait_ms(&g, 60);
        ev(&g, false);
        for (int i = 0; i < 100; i++) {
            wait_ms(&g, 10);
            ev(&g, false);
        }
        char what[160];
        snprintf(what, sizeof what, "on and off within 60 ms, LED after %d ms: two presses, off", lat);
        check(g.presses == 2 && !g.lock, what);
    }
}

/* Random: Mac changes, events, guest resets, LED latencies 2..400 ms. After a quiet
   second and one more event the guest's lock is the Mac's. */
static void random_run(unsigned seed)
{
    Guest g;
    srand(seed);
    fresh(&g, 2 + rand() % 399, true);
    bool mac = false;
    int bad = 0, rounds = 3000, extra = 0;
    for (int r = 0; r < rounds; r++) {
        int presses0 = g.presses;
        int what = rand() % 10;
        if (what < 4) {
            mac = !mac;
        } else if (what == 4) {
            guest_reset(&g);
        }
        int n = 1 + rand() % 5;
        for (int i = 0; i < n; i++) {
            wait_ms(&g, rand() % 200);
            ev(&g, mac);
        }
        wait_ms(&g, 1000);
        ev(&g, mac);
        wait_ms(&g, 1000);
        ev(&g, mac);
        if (g.lock != mac) {
            bad++;
        }
        if (g.presses - presses0 > 3) {
            extra++;
        }
    }
    char what[160];
    snprintf(what, sizeof what, "random run (seed %u, LED after %d ms): the guest's lock is the Mac's after every quiet second "
             "(%d of %d wrong, %d rounds with more than 3 presses)", seed, g.latency, bad, rounds, extra);
    check(bad == 0 && extra == 0, what);
}

int main(void)
{
    cases();
    for (unsigned s = 1; s <= 8; s++) {
        random_run(s);
    }
    if (fails) {
        printf("test-caps-lock: %d failed\n", fails);
        return 1;
    }
    /* QEMU's old rule must fail the report. */
    old_rule = true;
    bool old_ok = report_case(lose_session);
    old_rule = false;
    if (old_ok) {
        printf("FAIL the old rule passes the report's case: the test does not see #784\n");
        return 1;
    }
    printf("ok   the old rule (QEMU's own presses) fails the report's case, as reported\n");
    printf("test-caps-lock: all passed\n");
    return 0;
}
