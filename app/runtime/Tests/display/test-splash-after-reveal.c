/*
 * The start animation waits until the window shows
 * (omacvm-cocoa-splash-after-reveal.patch, ui/omacvm-intro-clock.h):
 *
 * - display-link frames at 60 Hz from the moment the window opens; the
 *   window shows after 0 s (a window), 0.4 s (a full-screen start on the
 *   Mac mini), 2 s, 4 s (the full-screen start's safety net) and 6 s (a
 *   slow way into full screen, longer than the whole animation);
 * - what the user sees from then on: OMACVM first, still, for the whole
 *   hold (INTRO_HOLD), then the whole morph, the end INTRO_END after the
 *   window showed; every frame before that is OMACVM at 0 s;
 * - the old clock (from the first frame, shown or not) fails these checks
 *   for a late window: the checks catch the bug the user saw;
 * - on the panels of "Full screen including notch" (FullPanel: the window
 *   covers the whole display, the strip beside the camera housing too) every
 *   cell of every frame lies inside the panel and below the strip.
 *
 * build-qemu-gpu-runtime.sh builds it with -I the patched ui/.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define g_new0(T, n) ((T *)calloc((n), sizeof(T)))

#include "omacvm-splash.h"
#include "omacvm-intro-clock.h"

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "test-splash-after-reveal: FAIL: " __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        failures++; \
    } \
} while (0)

#define HZ 60.0
#define OPENED 1000.0   /* the window opens (s, CACurrentMediaTime's clock) */

/* The clock before the fix: from the first frame, shown or not. */
static double old_clock(double frame, int shown, double *start)
{
    (void)shown;
    if (*start <= 0) {
        *start = frame;
    }
    return frame - *start;
}

typedef double (*Clock)(double, int, double *);

/*
 * The window shows `shown_after` s after it opened: what does the user see?
 * Returns a description of the first problem, NULL when the user sees the
 * whole animation.
 */
static const char *watch(Clock clock, double shown_after, char *why, size_t len)
{
    double start = 0, hold = 0, morph = 0, end_at = -1;
    bool first_seen = true;

    for (int i = 0; i < (int)(20 * HZ); i++) {
        double frame = OPENED + i / HZ;
        bool shown = frame >= OPENED + shown_after - 1e-9;
        double t = clock(frame, shown, &start);

        if (!shown) {
            if (t != 0) {
                snprintf(why, len, "a frame at %.2f s, window not shown yet, is at %.2f s of the animation",
                         i / HZ, t);
                return why;
            }
            continue;
        }
        if (first_seen) {
            first_seen = false;
            if (t != 0) {
                snprintf(why, len, "the first frame the user sees is at %.2f s of the animation, not OMACVM",
                         t);
                return why;
            }
        }
        if (t < INTRO_HOLD) {
            hold += 1 / HZ;
        } else if (t < INTRO_END) {
            morph += 1 / HZ;
        } else if (end_at < 0) {
            end_at = i / HZ;
        }
    }
    if (hold < INTRO_HOLD - 1 / HZ - 1e-9) {
        snprintf(why, len, "OMACVM shows %.2f s of its %.2f s hold", hold, (double)INTRO_HOLD);
        return why;
    }
    if (morph < INTRO_END - INTRO_HOLD - 2 / HZ) {
        snprintf(why, len, "the morph shows %.2f s of its %.2f s", morph, (double)(INTRO_END - INTRO_HOLD));
        return why;
    }
    if (fabs(end_at - (shown_after + INTRO_END)) > 1.5 / HZ) {
        snprintf(why, len, "the animation ends %.2f s after the window opened, not %.2f s",
                 end_at, shown_after + INTRO_END);
        return why;
    }
    return NULL;
}

/* FullPanel panels (pixels): the logo's cells inside, below the strip. */
static void panel(const char *name, int w, int h, int strip)
{
    IntroCell buf[INTRO_MAX];
    double glow;
    IntroGeom g = omacvm_intro_geom(w, h);

    for (double t = 0; t <= INTRO_END + 1e-9; t += 1 / HZ) {
        int n = omacvm_intro_cells(t, buf, &glow);
        CHECK(n > 0, "%s: no cells at %.2f s", name, t);
        for (int i = 0; i < n; i++) {
            double e[4];
            omacvm_intro_rect(&g, &buf[i], e);
            if (e[0] < 0 || e[2] > w || e[1] < strip || e[3] > h) {
                CHECK(false, "%s %dx%d: a cell at %.2f s lies at (%.0f %.0f %.0f %.0f), outside the panel below the %d px strip",
                      name, w, h, t, e[0], e[1], e[2], e[3], strip);
                return;
            }
        }
    }
}

int main(void)
{
    static const double after[] = { 0, 0.4, 2, 4, 6 };
    char why[256];
    const char *bad;

    for (size_t i = 0; i < sizeof(after) / sizeof(after[0]); i++) {
        bad = watch(omacvm_intro_clock, after[i], why, sizeof(why));
        CHECK(!bad, "window shown after %.1f s: %s", after[i], bad);
    }
    /* The old clock: fine for a window that shows at once, not for a late one. */
    CHECK(!watch(old_clock, 0, why, sizeof(why)), "the old clock fails a window that shows at once (the harness is wrong)");
    CHECK(watch(old_clock, 0.4, why, sizeof(why)), "the harness misses the old clock's lost hold (0.4 s)");
    CHECK(watch(old_clock, 6, why, sizeof(why)), "the harness misses the old clock's lost animation (6 s)");

    /* Once it runs, the clock does not stop (the window hidden again later, say). */
    {
        double start = 0;
        omacvm_intro_clock(OPENED + 1, 1, &start);
        CHECK(fabs(omacvm_intro_clock(OPENED + 2, 0, &start) - 1) < 1e-9,
              "the clock stops when shown goes back to 0");
    }

    /* MacBook Air 13" (1470x956 pt, strip 34 pt), Air 15", Pro 14", Pro 16" at 2x. */
    panel("Air 13", 2940, 1912, 68);
    panel("Air 15", 2880, 1864, 68);
    panel("Pro 14", 3024, 1964, 76);
    panel("Pro 16", 3456, 2234, 76);

    if (failures) {
        fprintf(stderr, "test-splash-after-reveal: %d failure(s)\n", failures);
        return 1;
    }
    printf("test-splash-after-reveal: ok (windows shown after 0 to 6 s see the whole animation; FullPanel panels)\n");
    return 0;
}
