/*
 * Tests for ui/omacvm-present-volatile.h: the window's spare present surfaces
 * volatile while it is out of sight. Built by test-present-volatile.sh
 * against the header the logic patch makes (or, with --self-test, against
 * test-present-volatile-stub.h: 3.2.16 keeps every surface, so this fails).
 * Plays the window and Core Animation: which surface the layer shows, which
 * ones macOS empties. No QEMU, no IOSurface, no GL.
 */
#include <stdio.h>
#include <string.h>
#include "omacvm-present-volatile.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); \
    printf(__VA_ARGS__); printf("\n"); } else { printf("ok   "); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* The surfaces as macOS sees them. */
static bool vol[OMACVM_PV_SURFACES];     /* volatile at macOS */
static bool emptied[OMACVM_PV_SURFACES]; /* macOS took its pages */
static bool busy[OMACVM_PV_SURFACES];    /* Core Animation shows or reads it */
static bool full[OMACVM_PV_SURFACES];    /* QEMU draws it whole next */
static bool refuse;                      /* macOS refuses volatile */
static int calls;                        /* IOSurfaceSetPurgeable calls */

static void make(OmacvmPresentVolatile *v, unsigned i)
{
    calls++;
    if (!refuse) {
        vol[i] = true;
    }
    omacvm_pv_made(v, i, !refuse);
}

static void back(OmacvmPresentVolatile *v, unsigned i)
{
    calls++;
    bool e = vol[i] && emptied[i];
    vol[i] = false;
    emptied[i] = false;
    if (omacvm_pv_back(v, i, e)) {
        full[i] = true;
    }
}

/* What ui/cocoa.m does at each refresh tick and present. */
static void look(OmacvmPresentVolatile *v, bool seen, int64_t now)
{
    omacvm_pv_sight(v, seen, now);
    if (omacvm_pv_idle(v)) {
        return;
    }
    for (unsigned i = 0; i < v->n; i++) {
        int s = omacvm_pv_step(v, i, busy[i], now);
        if (s > 0) {
            make(v, i);
            if (v->off) {
                /* refused: every volatile one back, the rule stops */
                for (unsigned k = 0; k < v->n; k++) {
                    if (omacvm_pv_step(v, k, busy[k], now) < 0) {
                        back(v, k);
                    }
                }
                return;
            }
        } else if (s < 0) {
            back(v, i);
        }
    }
}

/* A frame drawn into surface I (in sight): non-volatile first. */
static void draw(OmacvmPresentVolatile *v, unsigned i)
{
    if (omacvm_pv_needed(v, i)) {
        back(v, i);
    }
    full[i] = false;
}

static unsigned count(const bool *a, unsigned n)
{
    unsigned c = 0;
    for (unsigned i = 0; i < n; i++) {
        c += a[i];
    }
    return c;
}

static void fresh(OmacvmPresentVolatile *v, unsigned n)
{
    memset(v, 0, sizeof(*v));
    memset(vol, 0, sizeof(vol));
    memset(emptied, 0, sizeof(emptied));
    memset(busy, 0, sizeof(busy));
    memset(full, 0, sizeof(full));
    refuse = false;
    calls = 0;
    omacvm_pv_reset(v, n);
}

int main(void)
{
    OmacvmPresentVolatile v;

    /* 5 surfaces (vsync), the layer shows surface 2. Out of sight. */
    fresh(&v, 5);
    busy[2] = true;
    look(&v, true, 0);
    CHECK(count(vol, 5) == 0 && calls == 0, "in sight: none volatile, no calls (%u, %d)", count(vol, 5), calls);
    look(&v, false, 1000);
    look(&v, false, 2500);
    CHECK(count(vol, 5) == 0, "out of sight 1.5 s: none volatile yet (%u)", count(vol, 5));
    look(&v, false, 3000);
    CHECK(count(vol, 5) == 4 && !vol[2], "out of sight 2 s: 4 of 5 volatile, not the one shown (%u, shown %d)",
          count(vol, 5), vol[2]);
    calls = 0;
    look(&v, false, 3500);
    CHECK(calls == 0, "still out of sight: nothing asked again (%d calls)", calls);

    /* In sight again: none volatile; the one macOS emptied is drawn whole. */
    emptied[0] = true;
    look(&v, true, 10000);
    CHECK(count(vol, 5) == 0, "in sight again: none volatile (%u)", count(vol, 5));
    CHECK(full[0] && count(full, 5) == 1, "the surface macOS emptied is drawn whole, only it (%d, %u)",
          full[0], count(full, 5));
    CHECK(v.made == 4 && v.emptied == 1, "counts for the log: 4 made volatile, 1 emptied (%u, %u)", v.made, v.emptied);
    calls = 0;
    look(&v, true, 10500);
    CHECK(calls == 0 && omacvm_pv_idle(&v), "in sight, nothing volatile: idle, no calls (%d)", calls);

    /* Taken for a frame while still volatile (a frame before the tick): non-volatile first. */
    look(&v, false, 20000);
    look(&v, false, 22000);
    CHECK(vol[0] && vol[1], "away again: volatile again (%d %d)", vol[0], vol[1]);
    emptied[1] = true;
    draw(&v, 1);
    CHECK(!vol[1] && !full[1], "a frame into surface 1: made non-volatile first, then drawn (%d)", vol[1]);
    CHECK(v.emptied == 1, "... and counted as emptied (%u)", v.emptied);
    look(&v, true, 23000);

    /* Away less than 2 s: nothing. */
    fresh(&v, 5);
    busy[0] = true;
    look(&v, false, 0);
    look(&v, false, 1900);
    look(&v, true, 1950);
    look(&v, true, 4000);
    CHECK(count(vol, 5) == 0 && calls == 0, "away 1.9 s: none volatile, no calls (%u, %d)", count(vol, 5), calls);

    /* Core Animation still reads two of them (a frame queued for the display): only the others. */
    fresh(&v, 5);
    busy[3] = busy[4] = true;
    look(&v, false, 0);
    look(&v, false, 2000);
    CHECK(count(vol, 5) == 3 && !vol[3] && !vol[4], "two busy: the other 3 volatile (%u)", count(vol, 5));
    busy[4] = false;
    look(&v, false, 2500);
    CHECK(count(vol, 5) == 4 && vol[4], "one lets go: it goes volatile at the next look (%u)", count(vol, 5));

    /* Without vsync: 3 surfaces, 2 of them volatile. */
    fresh(&v, 3);
    busy[0] = true;
    look(&v, false, 0);
    look(&v, false, 2000);
    CHECK(count(vol, 3) == 2, "3 surfaces: 2 of 3 volatile (%u)", count(vol, 3));

    /* Surfaces made again (a new size): none volatile, nothing to wake. */
    omacvm_pv_reset(&v, 5);
    CHECK(!omacvm_pv_needed(&v, 1) && !omacvm_pv_needed(&v, 2), "new surfaces: none volatile");

    /* Switched off (OMACVM_PRESENT_VOLATILE=0, OMACVM_PRESENT_HIDDEN): none, no calls. */
    fresh(&v, 5);
    v.off = true;
    look(&v, false, 0);
    look(&v, false, 60000);
    CHECK(count(vol, 5) == 0 && calls == 0, "off: none volatile, no calls (%u, %d)", count(vol, 5), calls);

    /* macOS refuses: one call, the rule stops for the run, nothing stays volatile. */
    fresh(&v, 5);
    busy[2] = true;
    refuse = true;
    look(&v, false, 0);
    look(&v, false, 2000);
    CHECK(v.off && calls == 1 && count(vol, 5) == 0, "refused: off for the run after one call (%d calls, %u)",
          calls, count(vol, 5));
    look(&v, false, 9000);
    look(&v, true, 9500);
    CHECK(calls == 1, "refused: never asked again (%d calls)", calls);

    /* Refused after some went volatile (e.g. a surface kind macOS will not purge): those come back. */
    fresh(&v, 5);
    busy[2] = true;
    look(&v, false, 0);
    look(&v, false, 2000);
    refuse = true;
    v.vol[0] = false;            /* surface 0 asked again (as if it had come back) */
    vol[0] = false;
    look(&v, false, 2500);
    CHECK(v.off && count(vol, 5) == 0, "refused later: every volatile surface back (%u)", count(vol, 5));

    printf("%s\n", fails ? "test-present-volatile: FAIL" : "test-present-volatile: all ok");
    return fails ? 1 : 0;
}
