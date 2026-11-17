/*
 * Tests for ui/omacvm-present-damage.h (partial present): which part of each
 * present surface is drawn. Built by test-present-damage.sh against the
 * header the logic patch makes. No QEMU, no GL.
 */
#include <stdio.h>
#include <stdlib.h>
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

    if (fails) {
        printf("%d checks failed\n", fails);
        return 1;
    }
    printf("ok   partial present: rects per surface, clipping, full draws\n");
    return 0;
}
