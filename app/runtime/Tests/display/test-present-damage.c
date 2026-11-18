/*
 * Tests for ui/omacvm-present-damage.h (partial present): which part of each
 * present surface is drawn. Built by test-present-damage.sh against the
 * header the logic patch makes. No QEMU, no GL.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "omacvm-present-damage.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void take_expect(OmacvmPresentDamage *d, unsigned i, int partial,
                        uint32_t x, uint32_t y, uint32_t w, uint32_t h, const char *what)
{
    OmacvmPDRect r;
    bool p = omacvm_pd_take(d, i, &r);
    CHECK(p == partial && r.x == x && r.y == y && r.w == w && r.h == h,
          "%s: surface %u: got %s %ux%u+%u+%u, want %s %ux%u+%u+%u", what, i,
          p ? "part" : "full", r.w, r.h, r.x, r.y, partial ? "part" : "full", w, h, x, y);
}

/*
 * The check mode's comparison, on pictures made here (BGRA, 4 bytes a pixel).
 * A small guest: three swapchain buffers shown in turn, a 6x6 pointer moving
 * along a row, and a window border column that buffer 1 holds one level
 * lighter than buffers 0 and 2 although the guest never reports it (what
 * Hyprland's buffers did on the M1 Max in 3.5.0's M1-1 rows). QEMU's side:
 * five surfaces (the vsync present) drawn by the rules above, so a surface
 * shows another buffer each time round. MISS drops the pointer's old place
 * from the guest's rects (a box that misses a change); HALF draws only the
 * left half of each box (the check's test fault).
 */
enum { SW = 96, SH = 48, PS = 6, BORDER_X = 40 };

static void px_set(uint8_t *p, uint32_t x, uint32_t y, uint32_t rgb)
{
    uint8_t *q = p + ((size_t)y * SW + x) * 4;
    q[0] = rgb & 0xff; q[1] = (rgb >> 8) & 0xff; q[2] = (rgb >> 16) & 0xff; q[3] = 0xff;
}

/* Guest buffer G as frame F shows it: background, border, pointer at F's place. */
static void guest_frame(uint8_t *p, unsigned g, unsigned f)
{
    for (uint32_t y = 0; y < SH; y++) {
        for (uint32_t x = 0; x < SW; x++) {
            px_set(p, x, y, 0x221d2b);
        }
        px_set(p, BORDER_X, y, g == 1 ? 0x1b1c29 : 0x1b1b28);
    }
    for (uint32_t y = 0; y < PS; y++) {
        for (uint32_t x = 0; x < PS; x++) {
            px_set(p, 4 + 7 * f + x, 20 + y, 0x000000);
        }
    }
}

static void copy_box(uint8_t *dst, const uint8_t *src, OmacvmPDRect r)
{
    for (uint32_t y = r.y; y < r.y + r.h; y++) {
        memcpy(dst + ((size_t)y * SW + r.x) * 4, src + ((size_t)y * SW + r.x) * 4, (size_t)r.w * 4);
    }
}

/* Runs the small guest for FRAMES frames; returns the most wrong pixels a check saw, *noisy the checks that differed. */
static uint64_t run_guest(int miss, int half, unsigned *noisy)
{
    static uint8_t g[3][SW * SH * 4], surf[5][SW * SH * 4];
    OmacvmPresentDamage d;
    uint64_t worst = 0;

    *noisy = 0;
    omacvm_pd_reset(&d, 5, SW, SH);
    for (unsigned f = 0; f < 11; f++) {
        unsigned b = f % 3, n = f % 5;
        guest_frame(g[b], b, f);
        if (f == 0) {
            omacvm_pd_add(&d, 0, 0, SW, SH);                    /* the first frame: all of it */
        } else {
            uint32_t was = 4 + 7 * (f - 1), now = 4 + 7 * f;    /* the pointer's old and new place */
            omacvm_pd_add(&d, miss ? now : was, 20, miss ? PS : now + PS - was, PS);
        }
        OmacvmPDRect r;
        if (omacvm_pd_take(&d, n, &r)) {
            if (half) {
                r.w /= 2;
            }
            copy_box(surf[n], g[b], r);
        } else {
            memcpy(surf[n], g[b], sizeof(surf[n]));
        }
        OmacvmPDCmp c = omacvm_pd_cmp(surf[n], g[b], SW, SH);
        worst = c.wrong > worst ? c.wrong : worst;
        *noisy += c.differ && !c.wrong;
    }
    return worst;
}

static void check_compare(void)
{
    static uint8_t a[SW * SH * 4], b[SW * SH * 4];
    OmacvmPDCmp c;

    guest_frame(a, 0, 0);
    memcpy(b, a, sizeof(b));
    c = omacvm_pd_cmp(a, b, SW, SH);
    CHECK(c.differ == 0 && c.wrong == 0 && c.max == 0, "same picture: differ %llu wrong %llu",
          (unsigned long long)c.differ, (unsigned long long)c.wrong);

    b[3] ^= 0x5a;                                           /* alpha: the window ignores it */
    c = omacvm_pd_cmp(a, b, SW, SH);
    CHECK(c.differ == 0, "alpha alone: differ %llu", (unsigned long long)c.differ);

    px_set(b, 10, 5, 0x1b1c29);                             /* one level, as on the M1 */
    px_set(a, 10, 5, 0x1b1b28);
    c = omacvm_pd_cmp(a, b, SW, SH);
    CHECK(c.differ == 1 && c.wrong == 0 && c.max == 1 && c.box.x == 10 && c.box.y == 5 &&
          c.box.w == 1 && c.box.h == 1, "one level: differ %llu wrong %llu max %u box %ux%u+%u+%u",
          (unsigned long long)c.differ, (unsigned long long)c.wrong, c.max, c.box.w, c.box.h, c.box.x, c.box.y);

    px_set(b, 11, 5, 0x221d2d);                             /* two levels: still the guest's rounding */
    px_set(b, 30, 7, 0x221d2e);                             /* three: wrong */
    c = omacvm_pd_cmp(a, b, SW, SH);
    CHECK(c.differ == 3 && c.wrong == 1 && c.max == 3 && c.box.x == 30 && c.box.y == 7 &&
          c.box.w == 1 && c.box.h == 1, "levels 1, 2, 3: differ %llu wrong %llu max %u box %ux%u+%u+%u",
          (unsigned long long)c.differ, (unsigned long long)c.wrong, c.max, c.box.w, c.box.h, c.box.x, c.box.y);

    px_set(b, 50, 40, 0x000000);                            /* a stale pointer pixel */
    c = omacvm_pd_cmp(a, b, SW, SH);
    CHECK(c.wrong == 2 && c.box.x == 30 && c.box.y == 7 && c.box.w == 21 && c.box.h == 34,
          "two wrong pixels: wrong %llu box %ux%u+%u+%u", (unsigned long long)c.wrong,
          c.box.w, c.box.h, c.box.x, c.box.y);

    /* The guest's buffers a level apart where it reported nothing: no wrong
     * pixel, but frames that differ (an exact comparison called them bad). */
    unsigned noisy;
    uint64_t worst = run_guest(0, 0, &noisy);
    CHECK(worst == 0, "right boxes over buffers a level apart: %llu wrong pixels", (unsigned long long)worst);
    CHECK(noisy > 0, "the small guest's buffers should disagree by a level somewhere (%u checks)", noisy);
    /* A box that misses the pointer's old place, and the half-box fault: caught. */
    worst = run_guest(1, 0, &noisy);
    CHECK(worst >= PS * PS / 2, "a box that misses the old pointer: %llu wrong pixels", (unsigned long long)worst);
    worst = run_guest(0, 1, &noisy);
    CHECK(worst > 0, "the half-box fault: %llu wrong pixels", (unsigned long long)worst);
}

int main(void)
{
    OmacvmPresentDamage d;

    /* New surfaces: every first draw is a full one. */
    omacvm_pd_reset(&d, 3, 2940, 1840);
    omacvm_pd_add(&d, 10, 10, 20, 20);
    for (unsigned i = 0; i < 3; i++) {
        take_expect(&d, i, 0, 0, 0, 2940, 1840, "first draws");
    }

    /* A pointer move: each surface draws only the rect, and keeps the ones it
     * missed while the others were drawn (merged and skipped frames too). */
    omacvm_pd_add(&d, 100, 200, 32, 32);                 /* A */
    take_expect(&d, 0, 1, 100, 200, 32, 32, "A");
    omacvm_pd_add(&d, 140, 210, 32, 32);                 /* B */
    take_expect(&d, 1, 1, 100, 200, 72, 42, "A+B");
    omacvm_pd_add(&d, 2000, 1000, 10, 10);               /* C */
    take_expect(&d, 2, 1, 100, 200, 1910, 810, "A+B+C");
    take_expect(&d, 0, 1, 140, 210, 1870, 800, "B+C (surface 0 had A)");
    take_expect(&d, 1, 1, 2000, 1000, 10, 10, "C (surface 1 had A, B)");
    take_expect(&d, 2, 1, 0, 0, 0, 0, "nothing since its last draw");

    /* Rects from the guest are clipped to the frame; past it, or empty: nothing. */
    omacvm_pd_add(&d, 2930, 1830, 0xffffffffu, 0xffffffffu);
    take_expect(&d, 0, 1, 2930, 1830, 10, 10, "clipped at the frame's edge, no overflow");
    omacvm_pd_add(&d, 2940, 0, 10, 10);
    omacvm_pd_add(&d, 0, 1840, 10, 10);
    omacvm_pd_add(&d, 5, 5, 0, 10);
    omacvm_pd_add(&d, 5, 5, 10, 0);
    take_expect(&d, 0, 1, 0, 0, 0, 0, "rects outside or empty add nothing");

    /* The whole plane (kernels before 7.4 on every flip), or most of it: full. */
    omacvm_pd_add(&d, 0, 0, 2940, 1840);
    take_expect(&d, 0, 0, 0, 0, 2940, 1840, "the whole plane");
    CHECK(d.last == OMACVM_PD_FULL_BIG, "the whole plane: why %d, want big", d.last);
    omacvm_pd_add(&d, 0, 0, 2940, 1400);
    take_expect(&d, 0, 0, 0, 0, 2940, 1840, "three quarters or more");
    CHECK(d.last == OMACVM_PD_FULL_BIG, "three quarters: why %d, want big", d.last);
    omacvm_pd_add(&d, 0, 0, 2940, 1370);
    take_expect(&d, 0, 1, 0, 0, 2940, 1370, "under three quarters: still in part");
    CHECK(d.last == OMACVM_PD_PART, "under three quarters: why %d, want part", d.last);

    /* Another frame size: full, and old rects count no more. */
    omacvm_pd_reset(&d, 3, 2940, 1840);
    for (unsigned i = 0; i < 3; i++) {
        omacvm_pd_take(&d, i, &(OmacvmPDRect){ 0 });
    }
    omacvm_pd_add(&d, 10, 10, 10, 10);
    omacvm_pd_frame(&d, 2940, 1840);
    take_expect(&d, 0, 1, 10, 10, 10, 10, "same size: rects kept");
    omacvm_pd_frame(&d, 3024, 1964);
    omacvm_pd_add(&d, 10, 10, 10, 10);
    take_expect(&d, 1, 0, 0, 0, 3024, 1964, "new size: full");
    take_expect(&d, 1, 1, 0, 0, 0, 0, "then up to date");

    /* All full on request (colour path, boot logo, a new scanout buffer). */
    omacvm_pd_add(&d, 10, 10, 10, 10);
    omacvm_pd_all_full(&d);
    for (unsigned i = 0; i < 3; i++) {
        take_expect(&d, i, 0, 0, 0, 3024, 1964, "all full");
        CHECK(d.last == OMACVM_PD_FULL_ASKED, "all full %u: why %d, want asked", i, d.last);
    }

    /* A surface number past the ones in use: full; a count past the array: capped. */
    take_expect(&d, 3, 0, 0, 0, 3024, 1964, "surface past the count");
    CHECK(d.last == OMACVM_PD_FULL_PAST, "past the count: why %d, want past", d.last);
    omacvm_pd_reset(&d, 100, 64, 64);
    CHECK(d.n == OMACVM_PD_SURFACES, "count capped at %d, got %u", OMACVM_PD_SURFACES, d.n);

    /* Five surfaces (vsync present), a typing line: each draw only the line. */
    omacvm_pd_reset(&d, 5, 2940, 1840);
    for (unsigned i = 0; i < 5; i++) {
        omacvm_pd_take(&d, i, &(OmacvmPDRect){ 0 });
    }
    for (unsigned f = 0; f < 10; f++) {
        omacvm_pd_add(&d, 300 + 9 * f, 900, 9, 18);
        OmacvmPDRect r;
        bool p = omacvm_pd_take(&d, f % 5, &r);
        uint32_t first = f < 5 ? 0 : f - 4;   /* the oldest key this surface missed */
        CHECK(p && r.y == 900 && r.h == 18 && r.x == 300 + 9 * first && r.w == 9 * (f - first + 1),
              "typing frame %u: got %ux%u+%u+%u", f, r.w, r.h, r.x, r.y);
    }

    check_compare();

    if (fails) {
        printf("%d checks failed\n", fails);
        return 1;
    }
    printf("ok   partial present: rects per surface, clipping, full draws, the check's comparison\n");
    return 0;
}
