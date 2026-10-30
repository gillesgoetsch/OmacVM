/*
 * Tiled present rules (ui/omacvm-present-tiles.h): the grid, which tiles a
 * changed box touches, that frames skipped in the present queue lose
 * nothing (their updates go into the frame after them), and that the tile
 * program's texture coordinates put every fragment of a tile on the centre
 * of the frame texel the whole frame's blit samples there. No QEMU, no
 * display, no GL (the shader itself: test-present-tiles-gl.m).
 *   cc -std=c11 -Wall -Wextra -Werror -I<dir with omacvm-present-tiles.h> test-present-tiles.c
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "omacvm-present-tiles.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/*
 * A frame's "buffers" are ints: frame index * 1000 + tile (or 999 for its
 * whole frame), so what shows where tells which frame drew it.
 */
static void *buf(int frame, int tile) { return (void *)(intptr_t)(frame * 1000 + tile + 1); }
static int buf_frame(void *b) { return (int)(((intptr_t)b - 1) / 1000); }

/* What a tile of the window shows: the frame that drew it last (tile or whole). */
typedef struct Screen {
    int base;                       /* frame of the whole frame shown, -1 none */
    int tile[OMACVM_PT_MAX];        /* frame of the tile shown, -1 hidden */
} Screen;

static void screen_init(Screen *s)
{
    s->base = -1;
    for (unsigned t = 0; t < OMACVM_PT_MAX; t++) {
        s->tile[t] = -1;
    }
}

/* As cocoa_gl_present_show_tiles / cocoa_gl_present_show put a frame on the layers. */
static void screen_show(Screen *s, const OmacvmPTFrame *f)
{
    if (f->base) {
        s->base = buf_frame(f->base);
        for (unsigned t = 0; t < OMACVM_PT_MAX; t++) {
            s->tile[t] = -1;
        }
    }
    for (unsigned i = 0; i < f->n; i++) {
        s->tile[f->up[i].tile] = buf_frame(f->up[i].buf);
    }
}

/* What tile T shows: the version of its pixels (the newest frame that drew them). */
static int screen_version(const Screen *s, unsigned t)
{
    return s->tile[t] >= 0 ? s->tile[t] : s->base;
}

static unsigned rnd(unsigned *seed) { *seed = *seed * 1103515245u + 12345u; return (*seed >> 16) & 0x7fff; }

static void test_grid(void)
{
    OmacvmPTGrid g = omacvm_pt_grid(3024, 1896);
    CHECK(g.cols == 12 && g.rows == 8, "3024x1896: %u x %u tiles", g.cols, g.rows);
    uint32_t x, y, w, h;
    omacvm_pt_rect(&g, 11, &x, &y, &w, &h);
    CHECK(x == 2816 && y == 0 && w == 208 && h == 256, "last column %u,%u %ux%u", x, y, w, h);
    omacvm_pt_rect(&g, 95, &x, &y, &w, &h);
    CHECK(x == 2816 && y == 1792 && w == 208 && h == 104, "last tile %u,%u %ux%u", x, y, w, h);
    g = omacvm_pt_grid(6144, 4096);
    CHECK(g.cols == 24 && g.rows == 16, "6144x4096: %u x %u", g.cols, g.rows);
    g = omacvm_pt_grid(6145, 100);
    CHECK(g.cols == 0, "a frame too wide has no grid");
    g = omacvm_pt_grid(100, 4097);
    CHECK(g.cols == 0, "a frame too tall has no grid");
    g = omacvm_pt_grid(0, 100);
    CHECK(g.cols == 0, "an empty frame has no grid");
    g = omacvm_pt_grid(1, 1);
    omacvm_pt_rect(&g, 0, &x, &y, &w, &h);
    CHECK(g.cols == 1 && w == 1 && h == 1, "1x1: one tile of 1x1");
    /* every pixel of an odd-sized frame is in exactly one tile */
    g = omacvm_pt_grid(1000, 700);
    long area = 0;
    for (unsigned t = 0; t < g.cols * g.rows; t++) {
        omacvm_pt_rect(&g, t, &x, &y, &w, &h);
        CHECK(x + w <= 1000 && y + h <= 700, "tile %u inside the frame", t);
        area += (long)w * h;
    }
    CHECK(area == 1000L * 700, "the tiles cover the frame once (%ld)", area);
}

static void test_tiles(void)
{
    OmacvmPTGrid g = omacvm_pt_grid(3024, 1896);
    unsigned out[OMACVM_PT_MAX];
    int n = omacvm_pt_tiles(&g, 10, 10, 20, 20, out, 12);
    CHECK(n == 1 && out[0] == 0, "a small box in tile 0: %d", n);
    n = omacvm_pt_tiles(&g, 250, 250, 10, 10, out, 12);
    CHECK(n == 4 && out[0] == 0 && out[1] == 1 && out[2] == 12 && out[3] == 13, "a box on a corner: 4 tiles (%d)", n);
    n = omacvm_pt_tiles(&g, 256, 256, 256, 256, out, 12);
    CHECK(n == 1 && out[0] == 13, "a box exactly on tile 13: %d %u", n, out[0]);
    n = omacvm_pt_tiles(&g, 0, 0, 3024, 1896, out, 12);
    CHECK(n == -1, "the whole frame is more than 12 tiles: %d", n);
    n = omacvm_pt_tiles(&g, 0, 0, 3024, 1896, out, OMACVM_PT_MAX);
    CHECK(n == 96, "the whole frame with room: 96 tiles (%d)", n);
    n = omacvm_pt_tiles(&g, 5, 5, 0, 10, out, 12);
    CHECK(n == 0, "an empty box: no tiles (%d)", n);
    n = omacvm_pt_tiles(&g, 3024, 0, 10, 10, out, 12);
    CHECK(n == 0, "a box right of the frame: no tiles (%d)", n);
    n = omacvm_pt_tiles(&g, 3000, 1890, 0xffffffffu, 0xffffffffu, out, 12);
    CHECK(n == 1 && out[0] == 95, "a box that overflows is clipped: %d", n);
    OmacvmPTGrid none = omacvm_pt_grid(7000, 100);
    n = omacvm_pt_tiles(&none, 0, 0, 10, 10, out, 12);
    CHECK(n == 0, "no grid: no tiles (%d)", n);
}

/*
 * The tile program (OMACVM_PT_VERT) at fragment I, J of a TW x TH tile: the
 * quad's corners interpolated at the fragment's centre give
 * u = (I + 0.5) / TW, v = (J + 0.5) / TH; its texture coordinate is
 * RECT.xy + (u, v) * RECT.zw, the second one as 1 - that without the flip.
 * The whole frame's blit (QEMU's, viewport over the whole surface) samples
 * at frame pixel X + I, Y + J: s = (X + I + 0.5) / FW, and t = (Y + J + 0.5)
 * / FH with the flip, 1 - that without. They must agree to 1/1000 of a
 * texel (a slip of half a texel would still pick the right texel at most
 * places with NEAREST, so a floor check alone would hide it). s depends
 * on the column only and t on the row only, so every column and every row
 * of every tile covers every fragment.
 */
static void test_tex_rect(void)
{
    static const uint32_t sizes[][2] = {
        { 5120, 2880 }, { 6016, 3384 }, { 6144, 4096 }, { 4480, 2520 }, { 3024, 1964 },
    };
    CHECK(strstr(OMACVM_PT_VERT, "vec2 c = rect.xy + (in_position + 1.0) * 0.5 * rect.zw;") &&
          strstr(OMACVM_PT_VERT, "ex_tex_coord = vec2(c.x, yflip > 0.5 ? c.y : 1.0 - c.y);") &&
          strstr(OMACVM_PT_VERT, "gl_Position = vec4(in_position, 0.0, 1.0);"),
          "the shader computes what this test checks");
    CHECK(strstr(OMACVM_PT_FRAG, "out_frag_color = texture(image, ex_tex_coord);") != NULL,
          "the fragment shader is QEMU's blit");
    double worst = 0;
    long fragments = 0;
    for (unsigned k = 0; k < sizeof(sizes) / sizeof(sizes[0]); k++) {
        OmacvmPTGrid g = omacvm_pt_grid(sizes[k][0], sizes[k][1]);
        CHECK(g.cols > 0, "%ux%u has a grid", g.fw, g.fh);
        for (unsigned t = 0; t < g.cols * g.rows; t++) {
            uint32_t x, y, tw, th;
            float r[4];
            omacvm_pt_rect(&g, t, &x, &y, &tw, &th);
            omacvm_pt_tex_rect(&g, t, r);
            int bad = 0;
            for (uint32_t i = 0; i < tw; i++) {
                float u = (i + 0.5f) / (float)tw;
                float c = r[0] + u * r[2];
                double e = fabs((double)c * g.fw - (x + i + 0.5));
                worst = e > worst ? e : worst;
                bad += e > 1e-3;
            }
            for (int flip = 0; flip < 2; flip++) {
                for (uint32_t j = 0; j < th; j++) {
                    float v = (j + 0.5f) / (float)th;
                    float c = r[1] + v * r[3];
                    float tc = flip ? c : 1.0f - c;
                    double want = flip ? (y + j + 0.5) / g.fh : 1.0 - (y + j + 0.5) / g.fh;
                    double e = fabs(((double)tc - want) * g.fh);
                    worst = e > worst ? e : worst;
                    bad += e > 1e-3;
                }
            }
            fragments += (long)tw * th;
            CHECK(!bad, "%ux%u tile %u (x %u, y %u): %d columns or rows off their texel's centre",
                  g.fw, g.fh, t, x, y, bad);
        }
    }
    CHECK(fragments == 5120L * 2880 + 6016L * 3384 + 6144L * 4096 + 4480L * 2520 + 3024L * 1964,
          "every fragment of every tile (%ld)", fragments);
    printf("test-present-tiles: tile texture coordinates: %ld fragments, both flips, worst %.6f texel\n",
           fragments, worst);
}

static void test_absorb_cases(void)
{
    void *freed[OMACVM_PT_MAX + 1];
    OmacvmPTFrame a = { 0 }, b = { 0 };
    /* tiles over tiles: the newer one's tile wins, the older's other tiles move along */
    a.up[a.n++] = (OmacvmPTUpdate){ 3, buf(1, 3) };
    a.up[a.n++] = (OmacvmPTUpdate){ 4, buf(1, 4) };
    b.up[b.n++] = (OmacvmPTUpdate){ 4, buf(2, 4) };
    unsigned nf = omacvm_pt_absorb(&b, &a, freed);
    CHECK(nf == 1 && freed[0] == buf(1, 4), "the older tile 4 goes (%u)", nf);
    CHECK(b.n == 2 && a.n == 0 && !a.base, "tile 3 moves to the newer frame");
    int has3 = 0;
    for (unsigned i = 0; i < b.n; i++) {
        has3 |= b.up[i].tile == 3 && b.up[i].buf == buf(1, 3);
        CHECK(b.up[i].tile != 4 || b.up[i].buf == buf(2, 4), "tile 4 is the newer one's");
    }
    CHECK(has3, "tile 3 kept");
    /* a whole frame skipped: the next tiles frame takes it over */
    OmacvmPTFrame w = { .base = buf(3, 999) }, t = { 0 };
    t.up[t.n++] = (OmacvmPTUpdate){ 7, buf(4, 7) };
    nf = omacvm_pt_absorb(&t, &w, freed);
    CHECK(nf == 0 && t.base == buf(3, 999) && t.n == 1, "the whole frame is shown with the tiles");
    /* a whole newer frame covers all */
    OmacvmPTFrame w2 = { .base = buf(5, 999) };
    nf = omacvm_pt_absorb(&w2, &t, freed);
    CHECK(nf == 2 && w2.n == 0 && w2.base == buf(5, 999), "a whole frame frees everything older (%u)", nf);
}

/*
 * Random frame streams: each frame changes a random box (or is a whole
 * frame); random frames are skipped the way the present queue skips them
 * (into the frame after, or held for the next one). What the window shows
 * after the last frame must be what showing every frame shows, and every
 * buffer is shown or freed exactly once.
 */
static void test_streams(void)
{
    OmacvmPTGrid g = omacvm_pt_grid(1000, 700);
    unsigned seed = 1;
    for (int run = 0; run < 2000; run++) {
        enum { N = 40 };
        static OmacvmPTFrame fr[N];
        Screen truth, shown;
        screen_init(&truth);
        screen_init(&shown);
        long made = 0;
        for (int k = 0; k < N; k++) {
            memset(&fr[k], 0, sizeof fr[k]);
            fr[k].grid = g;
            if (k == 0 || rnd(&seed) % 6 == 0) {
                fr[k].base = buf(k, 999);
                made++;
            } else {
                unsigned tl[OMACVM_PT_FRAME_MAX];
                uint32_t x = rnd(&seed) % 1000, y = rnd(&seed) % 700;
                int n = omacvm_pt_tiles(&g, x, y, 1 + rnd(&seed) % 400, 1 + rnd(&seed) % 300, tl, OMACVM_PT_FRAME_MAX);
                if (n <= 0) {
                    fr[k].base = buf(k, 999);   /* too many tiles: a whole frame */
                    made++;
                } else {
                    for (int i = 0; i < n; i++) {
                        fr[k].up[fr[k].n++] = (OmacvmPTUpdate){ tl[i], buf(k, (int)tl[i]) };
                        made++;
                    }
                }
            }
            screen_show(&truth, &fr[k]);
        }
        /* the queue: frames come in order; some are skipped */
        OmacvmPTFrame pend = { 0 };
        long freed_n = 0, shown_n = 0;
        void *freed[OMACVM_PT_MAX + 1];
        int k = 0;
        while (k < N) {
            /* a frame skipped right away goes into pend (nothing queued after it) */
            if (k < N - 1 && rnd(&seed) % 4 == 0) {
                freed_n += omacvm_pt_absorb(&fr[k], &pend, freed);
                pend = fr[k];
                memset(&fr[k], 0, sizeof fr[k]);
                k++;
                continue;
            }
            /* or two in the queue, the older skipped into the newer */
            freed_n += omacvm_pt_absorb(&fr[k], &pend, freed);
            memset(&pend, 0, sizeof pend);
            if (k < N - 1 && rnd(&seed) % 3 == 0) {
                freed_n += omacvm_pt_absorb(&fr[k + 1], &fr[k], freed);
                k++;
                continue;   /* fr[k] (the newer) is shown next round */
            }
            screen_show(&shown, &fr[k]);
            shown_n += (fr[k].base ? 1 : 0) + fr[k].n;
            k++;
        }
        for (unsigned t = 0; t < g.cols * g.rows; t++) {
            int a = screen_version(&truth, t), b = screen_version(&shown, t);
            if (a != b) {
                CHECK(0, "run %d: tile %u shows frame %d, should %d", run, t, b, a);
                break;
            }
        }
        /*
         * Every buffer made is shown or freed; a shown one may be freed
         * later only by the layer (not counted), so shown + freed == made.
         */
        CHECK(shown_n + freed_n == made, "run %d: %ld made, %ld shown + %ld freed", run, made, shown_n, freed_n);
        if (fails > 20) {
            return;
        }
    }
}

int main(void)
{
    test_grid();
    test_tiles();
    test_tex_rect();
    test_absorb_cases();
    test_streams();
    if (fails) {
        printf("test-present-tiles: %d FAILED\n", fails);
        return 1;
    }
    printf("test-present-tiles: grid, boxes, tile texture coordinates, skipped frames (2000 random streams) ok\n");
    return 0;
}
