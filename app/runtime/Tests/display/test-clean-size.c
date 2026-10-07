/*
 * Unit test for ui/omacvm-clean-size.h (the guest's size, picked so
 * Omarchy's scale presets fit).
 *
 * Omarchy's panel is modelled the way the header says it works (presets
 * rounded up to scales Hyprland takes); the real Macs' full-screen areas
 * below the notch are checked by name, then every height and every window
 * size on the 20 point steps.
 *
 * cc -Wall -Werror -I<qemu>/ui test-clean-size.c -o t && ./t
 */
#include <stdio.h>
#include <string.h>

#include "omacvm-clean-size.h"

static int failures, checks;

#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: ", __FILE__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while (0)

/* The panel as text, "1 1.25 2" (for messages). */
static const char *panel_text(uint32_t w, uint32_t h)
{
    static char buf[128];
    uint32_t out[OMACVM_SCALE_PRESETS];
    int n = omacvm_scale_panel(w, h, out, NULL), len = 0;

    buf[0] = 0;
    for (int i = 0; i < n; i++) {
        len += snprintf(buf + len, sizeof(buf) - len, "%s%g", i ? " " : "",
                        out[i] / 120.0);
    }
    return buf;
}

static bool panel_has(uint32_t w, uint32_t h, uint32_t lo, uint32_t hi)
{
    uint32_t out[OMACVM_SCALE_PRESETS];
    int n = omacvm_scale_panel(w, h, out, NULL);

    for (int i = 0; i < n; i++) {
        if (out[i] >= lo && out[i] <= hi) {
            return true;
        }
    }
    return false;
}

static void panel_is(uint32_t w, uint32_t h, const char *want)
{
    const char *got = panel_text(w, h);

    CHECK(!strcmp(got, want), "panel %ux%u: %s, want %s", w, h, got, want);
}

static void full_is(double w, double h, double k, uint32_t ww, uint32_t wh)
{
    OmacVMSize s = omacvm_clean_size(w, h, k, true);

    CHECK(s.w == ww && s.h == wh, "full screen %gx%g at %gx: %ux%u, want %ux%u",
          w, h, k, s.w, s.h, ww, wh);
}

int main(void)
{
    /* The panel itself (what the user saw). */
    panel_is(2940, 1846, "1 2");                       /* Air, before */
    panel_is(2940, 1840, "1 1.25 1.66667 2 3.33333 4");
    panel_is(3456, 2160, "1 1.33333 1.6 2 3 4");       /* 16-inch */
    panel_is(3024, 1890, "1 1.35 1.75 2 3 4.2");       /* 14-inch, before */
    panel_is(2560, 1440, "1 1.25 1.6 2 3.2 4");
    panel_is(1920, 1080, "1 1.25 1.6 2 3 4");

    /* Full screen below the notch, the real Macs at their default sizes. */
    full_is(2940, 1846, 2, 2940, 1840);   /* Air 13 (1470x923 pt) */
    full_is(2880, 1798, 2, 2880, 1792);   /* Air 15 (1440x899 pt) */
    full_is(3024, 1890, 2, 3024, 1888);   /* MacBook Pro 14 */
    full_is(3456, 2160, 2, 3456, 2160);   /* MacBook Pro 16: as it is */
    full_is(3420, 2082, 2, 3420, 2080);   /* Air 13 at 1710x1107 */
    /*
     * Displays without a notch: ui/cocoa.m never asks for a cut there (a
     * 4.5K iMac at 4480x2520 would lose 4 points only to get 3.2 for
     * 3.33). These fit already anyway: nothing cut.
     */
    full_is(2560, 1600, 2, 2560, 1600);
    full_is(5120, 2880, 2, 5120, 2880);
    full_is(3840, 2160, 2, 3840, 2160);
    full_is(2560, 1440, 1, 2560, 1440);
    full_is(1920, 1080, 1, 1920, 1080);
    /* The step first (half pixels, odd sizes), as before. */
    full_is(2941, 1847.5, 2, 2940, 1840);
    full_is(2560.5, 1440.5, 1, 2560, 1440);

    /* A window: the view's own size, as before. */
    {
        OmacVMSize s = omacvm_clean_size(2940, 1846, 2, false);
        CHECK(s.w == 2940 && s.h == 1846, "window 2940x1846: %ux%u", s.w, s.h);
        s = omacvm_clean_size(2941, 1847, 2, false);
        CHECK(s.w == 2940 && s.h == 1846, "window 2941x1847: %ux%u", s.w, s.h);
        s = omacvm_clean_size(1001, 701, 1.5, false);
        CHECK(s.w == 999 && s.h == 699, "window at 1.5x: %ux%u", s.w, s.h);
        s = omacvm_clean_size(0, 1, 2, false);
        CHECK(s.w == 2 && s.h == 2, "empty view: %ux%u", s.w, s.h);
    }

    /*
     * Every height from 600 to 2400 pixels at the notch Macs' widths, 1x and
     * 2x: never more than 6 points cut, the step kept (2 stays at 2x), never
     * fewer presets than uncut, the width as it is.
     */
    {
        static const uint32_t widths[] = { 2940, 2880, 3024, 3456, 3420, 2560, 1512 };
        int worse = 0, cut_bad = 0, step_bad = 0;

        for (int k = 1; k <= 2; k++) {
            for (size_t i = 0; i < sizeof(widths) / sizeof(widths[0]); i++) {
                for (uint32_t h = 600; h <= 2400; h += k) {
                    uint32_t out[OMACVM_SCALE_PRESETS];
                    OmacVMSize s = omacvm_clean_size(widths[i], h, k, true);
                    uint32_t cut = h - s.h;

                    cut_bad += s.w != widths[i] || s.h > h || cut > (uint32_t)(OMACVM_TRIM_MAX_PT * k);
                    step_bad += s.h % k != 0;
                    worse += omacvm_scale_panel(s.w, s.h, out, NULL) <
                             omacvm_scale_panel(widths[i], h, out, NULL);
                    if (k == 2 && !panel_has(s.w, s.h, 240, 240)) {
                        step_bad++;
                    }
                }
            }
        }
        CHECK(!cut_bad, "%d heights cut wrong (more than 6 points, or the width)", cut_bad);
        CHECK(!step_bad, "%d heights off the step (or 2x gone at 2x)", step_bad);
        CHECK(!worse, "%d heights with fewer presets than uncut", worse);
    }

    /* The notch Macs get a 1.25-ish and a 1.6-ish preset back. */
    {
        static const uint32_t areas[][2] = {
            { 2940, 1846 }, { 2880, 1798 }, { 3024, 1890 }, { 3456, 2160 },
            { 3420, 2082 }, { 2560, 1600 },
        };

        for (size_t i = 0; i < sizeof(areas) / sizeof(areas[0]); i++) {
            OmacVMSize s = omacvm_clean_size(areas[i][0], areas[i][1], 2, true);

            CHECK(panel_has(s.w, s.h, 150, 165), "%ux%u: no 1.25-1.37 (%s)",
                  s.w, s.h, panel_text(s.w, s.h));
            CHECK(panel_has(s.w, s.h, 192, 200), "%ux%u: no 1.6-1.67 (%s)",
                  s.w, s.h, panel_text(s.w, s.h));
        }
    }

    /*
     * The black rows when a frame is shown at the top of the full-screen
     * view: only a frame as wide and at most 6 points shorter.
     */
    CHECK(omacvm_top_band(2940, 1846, 2940, 1840, 2) == 6, "Air: %u",
          omacvm_top_band(2940, 1846, 2940, 1840, 2));
    CHECK(omacvm_top_band(2940, 1846, 2940, 1846, 2) == 0, "same size: filled");
    CHECK(omacvm_top_band(2940, 1846, 2932, 1840, 2) == 0, "other width: filled");
    CHECK(omacvm_top_band(2940, 1846, 2940, 1834, 2) == 12, "6 points: at the top");
    CHECK(omacvm_top_band(2940, 1846, 2940, 1832, 2) == 0, "7 points: filled");
    CHECK(omacvm_top_band(2940, 1846, 2940, 1900, 2) == 0, "taller: filled");
    CHECK(omacvm_top_band(2940, 1846, 0, 0, 2) == 0, "no frame");
    CHECK(omacvm_top_band(1920, 1080, 1920, 1074, 1) == 6, "1x, 6 rows");
    CHECK(omacvm_top_band(1920, 1080, 1920, 1073, 1) == 0, "1x, 7 rows: filled");

    /* Every full-screen pick is shown at the top, its cut black below. */
    {
        static const uint32_t areas[][2] = {
            { 2940, 1846 }, { 2880, 1798 }, { 3024, 1890 }, { 3456, 2160 },
            { 3420, 2082 }, { 4112, 2572 },
        };

        for (size_t i = 0; i < sizeof(areas) / sizeof(areas[0]); i++) {
            OmacVMSize s = omacvm_clean_size(areas[i][0], areas[i][1], 2, true);
            uint32_t band = omacvm_top_band(areas[i][0], areas[i][1], s.w, s.h, 2);

            CHECK(band == areas[i][1] - s.h, "%ux%u -> %ux%u: %u black rows",
                  areas[i][0], areas[i][1], s.w, s.h, band);
        }
    }

    /* The window's steps. */
    CHECK(omacvm_window_step(1087.5) == 1080, "1087.5 -> %g", omacvm_window_step(1087.5));
    CHECK(omacvm_window_step(1080) == 1080, "1080 -> %g", omacvm_window_step(1080));
    CHECK(omacvm_window_step(39.9) == 20, "39.9 -> %g", omacvm_window_step(39.9));
    CHECK(omacvm_window_step(5) == 20, "5 -> %g", omacvm_window_step(5));

    /*
     * Every window on the steps, 300 to 2000 points: at 2x 1.25, 1.6 and 2
     * fit exactly; at 1x 1.25 and 2 do, and 1.6 becomes at most 1.67.
     */
    {
        int bad = 0;

        for (uint32_t w = 300; w <= 2000; w += OMACVM_WINDOW_STEP_PT) {
            for (uint32_t h = 300; h <= 1400; h += OMACVM_WINDOW_STEP_PT) {
                OmacVMSize s2 = omacvm_clean_size(w * 2, h * 2, 2, false);
                OmacVMSize s1 = omacvm_clean_size(w, h, 1, false);

                if (!panel_has(s2.w, s2.h, 150, 150) || !panel_has(s2.w, s2.h, 192, 192) ||
                    !panel_has(s2.w, s2.h, 240, 240) || !panel_has(s1.w, s1.h, 150, 150) ||
                    !panel_has(s1.w, s1.h, 192, 200) || !panel_has(s1.w, s1.h, 240, 240)) {
                    if (!bad++) {
                        printf("  first: %ux%u pt: 2x %s, 1x %s\n", w, h,
                               panel_text(s2.w, s2.h), panel_text(s1.w, s1.h));
                    }
                }
            }
        }
        CHECK(!bad, "%d window sizes on the steps miss a preset", bad);
    }

    printf("test-clean-size: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
