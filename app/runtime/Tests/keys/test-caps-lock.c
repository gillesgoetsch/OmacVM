/*
 * The guest's Caps Lock follows the Mac's (#784, omacvm-cocoa-caps-lock-logic.patch).
 * A model guest and the QEMU and Linux behaviour around it:
 * - each press flips the guest's lock, unless its Caps Lock key does not lock
 *   (Compose, Escape), or Shift is held and Shift + Caps Lock is Compose
 *   (Omarchy 4.5's default omarchy:shift_caps_compose);
 * - the guest's LEDs (Caps Lock, Num Lock) follow some milliseconds later, in
 *   order; Linux passes on only LED changes, and QEMU's LED notifier hears each
 *   of them with the keyboard's whole LED mask;
 * - a restart inside the VM resets the device: QEMU drops events until the
 *   guest's driver is up again, the reset clears a lit LED mask (notifier), and
 *   the driver coming up is heard (notifier, LEDs unchanged), as patched by
 *   omacvm-virtio-input-leds-reset.patch;
 * - the UI adds its notifier at the first input event (omacvm_caps_start).
 * Runs the report's cases, the guards and seeded random runs through
 * ui/omacvm-capslock.h; QEMU's old rule (the presses it sent) must fail the
 * report and the Shift + Caps Lock case, and the start case must fail without
 * the notifier call at the driver's start.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "omacvm-capslock.h"

#define NUM_LED (1u << 1)       /* QEMU_NUM_LOCK_LED */

enum { LOCKS, NO_LOCK, SHIFT_COMPOSE };

typedef struct {
    int64_t at;
    uint32_t bit;
    bool on;
} LedChange;

typedef struct {
    bool lock, num;             /* the guest's Caps Lock and Num Lock */
    int key;                    /* LOCKS, NO_LOCK (Compose, Escape), SHIFT_COMPOSE */
    bool listening;             /* the guest's keyboard driver runs (virtio-input active) */
    uint32_t leds;              /* the LED mask the device has (Linux and QEMU agree) */
    int latency;                /* ms from a press to the LED */
    LedChange q[64];            /* LED changes on their way, in order */
    int nq;
    int presses;
} Guest;

static OmacVMCaps st;
static bool ui_started;         /* the UI has had its first input event (notifier added) */
static bool old_rule, old_sent;
static bool no_start_report;    /* without the notifier call at the driver's start */
static int64_t now;
static int fails, notified;

static void notify(Guest *g)
{
    notified++;
    if (!old_rule && ui_started) {
        omacvm_caps_leds(&st, g->leds, now);
    }
}

/* Linux: an LED write reaches the device only when it changes the LED. */
static void led_write(Guest *g, uint32_t bit, bool on)
{
    uint32_t to = on ? (g->leds | bit) : (g->leds & ~bit);
    if (to != g->leds) {
        g->leds = to;
        notify(g);
    }
}

static void guest_tick(Guest *g)
{
    while (g->nq > 0 && now >= g->q[0].at) {
        LedChange c = g->q[0];
        memmove(g->q, g->q + 1, (size_t)(--g->nq) * sizeof g->q[0]);
        led_write(g, c.bit, c.on);
    }
}

static void led_later(Guest *g, uint32_t bit, bool on)
{
    if (g->nq < (int)(sizeof g->q / sizeof g->q[0])) {
        g->q[g->nq++] = (LedChange){ now + g->latency, bit, on };
    }
}

static void guest_press(Guest *g, bool shift)
{
    g->presses++;
    if (!g->listening || g->key == NO_LOCK || (g->key == SHIFT_COMPOSE && shift)) {
        return;
    }
    g->lock = !g->lock;
    led_later(g, OMACVM_CAPS_LED, g->lock);
}

/* The guest loses its lock (a new session): its LED goes off too (heard only if it was on). */
static void guest_reset(Guest *g)
{
    g->lock = false;
    led_later(g, OMACVM_CAPS_LED, false);
}

/* Num Lock in the guest (Omarchy turns it on as the session starts; the Mac's Clear key). */
static void guest_num(Guest *g, bool on)
{
    g->num = on;
    led_later(g, NUM_LED, on);
}

/* A restart inside the VM: the device resets; a lit LED mask is cleared and heard. */
static void guest_stop(Guest *g)
{
    g->listening = false;
    g->lock = g->num = false;
    g->nq = 0;
    if (g->leds) {
        g->leds = 0;
        notify(g);
    }
}

/* The guest's driver comes up (DRIVER_OK): heard with the LEDs unchanged. */
static void guest_start(Guest *g)
{
    g->listening = true;
    if (!no_start_report) {
        notify(g);
    }
}

/* One input event with the Mac's flag and Shift as the guest has it, now. */
static void ev2(Guest *g, bool mac, bool shift)
{
    guest_tick(g);
    bool press;
    if (old_rule) {
        press = mac != old_sent;
        if (press) {
            old_sent = mac;
        }
    } else {
        if (!ui_started) {
            omacvm_caps_start(&st, g->leds);
            ui_started = true;
        }
        press = omacvm_caps_step(&st, mac, shift, now);
    }
    if (press) {
        guest_press(g, shift);
    }
}

static void ev(Guest *g, bool mac)
{
    ev2(g, mac, false);
}

static void wait_ms(Guest *g, int ms)
{
    for (int i = 0; i < ms; i++) {
        now++;
        guest_tick(g);
    }
}

static void fresh(Guest *g, int latency, int key)
{
    memset(g, 0, sizeof(*g));
    g->latency = latency;
    g->key = key;
    g->listening = true;
    memset(&st, 0, sizeof(st));
    ui_started = false;
    old_sent = false;
    now = 100000;
    notified = 0;
}

static void check(bool ok, const char *what)
{
    if (!ok) {
        fails++;
    }
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
}

/* The report: Caps Lock on, the guest loses it, Caps Lock off on the Mac. */
static bool report_case(void)
{
    Guest g;
    fresh(&g, 15, LOCKS);
    ev(&g, true);                     /* Caps Lock on */
    wait_ms(&g, 700);
    ev(&g, true);
    guest_reset(&g);                  /* a new session */
    wait_ms(&g, 700);
    ev(&g, true);                     /* the next key or pointer move in the VM */
    wait_ms(&g, 700);
    ev(&g, true);
    bool on_ok = g.lock;
    ev(&g, false);                    /* Caps Lock off on the Mac */
    wait_ms(&g, 700);
    ev(&g, false);
    return on_ok && !g.lock && (g.leds & OMACVM_CAPS_LED) == 0;
}

/* QEMU started with the Mac's Caps Lock on: events (and presses) before the
   guest's driver is up; Num Lock on at the session start or not. */
static bool boot_case(bool numlock)
{
    Guest g;
    fresh(&g, 15, LOCKS);
    g.listening = false;
    for (int i = 0; i < 20; i++) {
        wait_ms(&g, 100);
        ev(&g, true);
    }
    guest_start(&g);
    wait_ms(&g, 3000);
    if (numlock) {
        guest_num(&g, true);
    }
    wait_ms(&g, 200);
    ev(&g, true);
    wait_ms(&g, 100);
    ev(&g, true);
    bool on = g.lock;
    ev(&g, false);
    wait_ms(&g, 100);
    ev(&g, false);
    return on && !g.lock && g.presses <= 3;
}

/* Omarchy 4.5: Shift + Caps Lock on the Mac (Compose in the guest, the Mac's flag
   flips), then a plain Caps Lock (the Mac's off): the guest's lock stays off. */
static bool shift_compose_case(void)
{
    Guest g;
    fresh(&g, 15, SHIFT_COMPOSE);
    ev(&g, false);
    ev2(&g, false, true);             /* Shift down */
    ev2(&g, true, true);              /* Caps Lock with Shift: the Mac's flag on */
    wait_ms(&g, 50);
    ev2(&g, true, false);             /* Shift up */
    for (int i = 0; i < 30; i++) {    /* the composed character, pointer moves */
        wait_ms(&g, 40);
        ev(&g, true);
    }
    bool off_composing = !g.lock;
    ev(&g, false);                    /* Caps Lock: the Mac's off */
    wait_ms(&g, 100);
    ev(&g, false);
    bool off = !g.lock;
    ev(&g, true);                     /* Caps Lock: the Mac's on */
    wait_ms(&g, 100);
    ev(&g, true);
    bool on = g.lock;
    ev(&g, false);
    wait_ms(&g, 100);
    ev(&g, false);
    return off_composing && off && on && !g.lock;
}

static void cases(void)
{
    Guest g;
    char what[200];

    fresh(&g, 15, LOCKS);
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

    check(report_case(),
          "#784: the guest loses its lock (new session) with the Mac's on: put back at the next event, and off with the Mac's");

    check(boot_case(false), "Caps Lock on while QEMU starts (presses lost), no Num Lock in the guest: "
          "on at the first event after its driver starts, off with the Mac's");
    check(boot_case(true), "... the same with Num Lock on at the session start");
    no_start_report = true;
    bool without = boot_case(false);
    no_start_report = false;
    check(!without, "... and without the notifier call at the driver's start it fails (the test sees it)");

    /* #784 C5: a restart inside the VM with the Mac's on, events during the
       restart, the session comes up with its lock off (and Num Lock on or not). */
    for (int num = 0; num <= 1; num++) {
        fresh(&g, 15, LOCKS);
        if (num) {
            guest_num(&g, true);
        }
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
        if (num) {
            guest_num(&g, true);
        }
        wait_ms(&g, 700);
        ev(&g, true);
        wait_ms(&g, 700);
        ev(&g, true);
        bool on_after = g.lock;
        ev(&g, false);
        wait_ms(&g, 700);
        ev(&g, false);
        snprintf(what, sizeof what, "a restart inside the VM with the Mac's on (events during it, Num Lock %s): "
                 "on after the session starts, off with the Mac's", num ? "on" : "off");
        check(on_after && !g.lock, what);
    }

    /* A Caps Lock key that does not lock, across a restart: at most one more press. */
    fresh(&g, 15, NO_LOCK);
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
    fresh(&g, 15, NO_LOCK);
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

    /* Num Lock changes say nothing about Caps Lock: with Caps Lock as Compose and
       the Mac's on, Num Lock on at the session start, the Clear key on and off,
       a restart with Num Lock on: no press for them. */
    fresh(&g, 15, NO_LOCK);
    ev(&g, true);
    wait_ms(&g, 700);
    ev(&g, true);
    int p0 = g.presses;
    guest_num(&g, true);
    for (int i = 0; i < 6; i++) {
        wait_ms(&g, 300);
        ev(&g, true);
        guest_num(&g, !g.num);
    }
    wait_ms(&g, 300);
    ev(&g, true);
    int p1 = g.presses;
    guest_num(&g, true);
    wait_ms(&g, 100);
    ev(&g, true);
    guest_stop(&g);
    for (int i = 0; i < 20; i++) {
        wait_ms(&g, 100);
        ev(&g, true);
    }
    int p2 = g.presses;
    check(p0 == 1 && p1 == p0 && p2 == p1 && notified >= 8,
          "Caps Lock as Compose, the Mac's on: Num Lock changes (session start, Clear key, a restart's reset) "
          "send no press");

    /* Set in the guest (another keyboard) with the Mac's off: kept until the Mac's flag changes. */
    fresh(&g, 15, LOCKS);
    ev(&g, false);
    g.lock = true;
    led_later(&g, OMACVM_CAPS_LED, true);
    for (int i = 0; i < 100; i++) {
        wait_ms(&g, 20);
        ev(&g, false);
    }
    check(g.presses == 0 && g.lock, "Caps Lock set in the guest by another keyboard: kept, no press on 100 events");
    guest_num(&g, true);
    wait_ms(&g, 30);
    ev(&g, false);
    check(g.presses == 0 && g.lock, "... Num Lock on: still kept");
    ev(&g, true);
    wait_ms(&g, 30);
    ev(&g, true);
    check(g.presses == 0 && g.lock, "... the Mac's on as well: no press (already on)");
    ev(&g, false);
    wait_ms(&g, 30);
    ev(&g, false);
    check(g.presses == 1 && !g.lock, "... the Mac's off: one press, off");

    /* Our presses answered, then the lock set in the guest between two events:
       kept; the Mac's on and off follow. */
    fresh(&g, 3, LOCKS);
    ev(&g, true);
    wait_ms(&g, 600);
    ev(&g, false);
    wait_ms(&g, 10);
    g.lock = true;
    led_later(&g, OMACVM_CAPS_LED, true);
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
        fresh(&g, lat, LOCKS);
        ev(&g, true);
        wait_ms(&g, 60);
        ev(&g, false);
        for (int i = 0; i < 100; i++) {
            wait_ms(&g, 10);
            ev(&g, false);
        }
        snprintf(what, sizeof what, "on and off within 60 ms, LED after %d ms: two presses, off", lat);
        check(g.presses == 2 && !g.lock, what);
    }

    /* A stalled guest: its LED answers after 800 ms, taken as its own lock. */
    fresh(&g, 800, LOCKS);
    ev(&g, true);
    for (int i = 0; i < 20; i++) {
        wait_ms(&g, 100);
        ev(&g, true);
    }
    bool on_late = g.lock && g.presses == 1;
    ev(&g, false);
    for (int i = 0; i < 20; i++) {
        wait_ms(&g, 100);
        ev(&g, false);
    }
    check(on_late && !g.lock && g.presses == 2, "LED after 800 ms (a stalled guest): one press each way, in step");

    /* Omarchy 4.5's Shift + Caps Lock = Compose. */
    check(shift_compose_case(), "Shift + Caps Lock as Compose (the Mac's flag on, the guest's lock not), "
          "then Caps Lock: the guest's lock stays off with the Mac's off, then on and off with the Mac's");
    fresh(&g, 15, SHIFT_COMPOSE);
    ev2(&g, false, true);
    ev2(&g, true, true);
    for (int i = 0; i < 100; i++) {
        wait_ms(&g, 25);
        ev2(&g, true, i < 10);
    }
    check(g.presses == 1 && !g.lock, "... no second press while the Mac's light stays on");
    fresh(&g, 15, LOCKS);
    ev2(&g, false, true);
    ev2(&g, true, true);
    wait_ms(&g, 100);
    ev(&g, true);
    bool shift_locks = g.lock;
    ev(&g, false);
    wait_ms(&g, 100);
    ev(&g, false);
    check(shift_locks && !g.lock && g.presses == 2, "Shift + Caps Lock in a guest where it locks: on, then off with the Mac's");
}

/* Random: Mac changes, events, new sessions, Num Lock changes, restarts inside the
   VM, LED latencies 2..900 ms (above OMACVM_CAPS_SETTLE_MS: a stalled guest). After
   two quiet seconds with an event each the guest's lock is the Mac's. */
static void random_run(unsigned seed)
{
    Guest g;
    srand(seed);
    fresh(&g, 2 + rand() % 899, LOCKS);
    bool mac = false;
    int bad = 0, rounds = 3000, extra = 0;
    for (int r = 0; r < rounds; r++) {
        int presses0 = g.presses;
        int what = rand() % 12;
        if (what < 4) {
            mac = !mac;
        } else if (what == 4) {
            guest_reset(&g);
        } else if (what == 5) {
            guest_num(&g, !g.num);
        } else if (what == 6) {
            guest_stop(&g);
            for (int i = 0; i < 1 + rand() % 5; i++) {
                wait_ms(&g, rand() % 500);
                ev(&g, mac);
            }
            guest_start(&g);
            if (rand() % 2) {
                guest_num(&g, true);
            }
        }
        int n = 1 + rand() % 5;
        for (int i = 0; i < n; i++) {
            wait_ms(&g, rand() % 200);
            ev(&g, mac);
        }
        wait_ms(&g, 2000);
        ev(&g, mac);
        wait_ms(&g, 2000);
        ev(&g, mac);
        if (g.lock != mac) {
            bad++;
        }
        if (g.presses - presses0 > 4) {
            extra++;
        }
    }
    char what[200];
    snprintf(what, sizeof what, "random run (seed %u, LED after %d ms): the guest's lock is the Mac's after every quiet "
             "time (%d of %d wrong, %d rounds with more than 4 presses)", seed, g.latency, bad, rounds, extra);
    check(bad == 0 && extra == 0, what);
}

/* Random, Caps Lock as Compose: exactly one press per change of the Mac's flag,
   whatever Num Lock does. */
static void random_no_lock(unsigned seed)
{
    Guest g;
    srand(seed);
    fresh(&g, 2 + rand() % 899, NO_LOCK);
    bool mac = false;
    int changes = 0;
    for (int r = 0; r < 2000; r++) {
        int what = rand() % 4;
        if (what == 0) {
            mac = !mac;
            changes++;
        } else if (what == 1) {
            guest_num(&g, !g.num);
        }
        for (int i = 0; i < 1 + rand() % 4; i++) {
            wait_ms(&g, rand() % 300);
            ev(&g, mac);
        }
    }
    char what[200];
    snprintf(what, sizeof what, "random run, Caps Lock as Compose (seed %u): one press per change of the Mac's flag "
             "(%d presses, %d changes)", seed, g.presses, changes);
    check(g.presses == changes, what);
}

int main(void)
{
    cases();
    for (unsigned s = 1; s <= 8; s++) {
        random_run(s);
    }
    for (unsigned s = 1; s <= 4; s++) {
        random_no_lock(s);
    }
    if (fails) {
        printf("test-caps-lock: %d failed\n", fails);
        return 1;
    }
    /* QEMU's old rule must fail the report and the Shift + Caps Lock case. */
    old_rule = true;
    bool old_report = report_case(), old_shift = shift_compose_case();
    old_rule = false;
    if (old_report || old_shift) {
        printf("FAIL the old rule passes the report's case (%d) or Shift + Caps Lock (%d): the test does not see them\n",
               old_report, old_shift);
        return 1;
    }
    printf("ok   the old rule (QEMU's own presses) fails the report's case and Shift + Caps Lock, as reported\n");
    printf("test-caps-lock: all passed\n");
    return 0;
}
