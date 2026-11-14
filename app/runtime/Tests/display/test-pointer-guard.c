/*
 * Unit test for ui/omacvm-pointer-guard.h (the full-screen pointer guard).
 *
 * A small model of macOS stands in for the window server: an attached cursor
 * moves by each motion (and stops at the displays' outer edges), a detached
 * one stays put, and a warp's distance comes back in the next event's delta
 * (what SDL and GLFW correct for on macOS). The guest sees the guard's place
 * while the cursor is held, else the event's location.
 *
 * Checks: a stream of deltas moves the guest's pointer by exactly those deltas
 * in the centre, near a corner, along the Dock's edge, across the zone's
 * border and across a shared display edge (mouse and trackpad sized steps);
 * the same event handed over twice moves it once; the Mac's cursor never gets
 * within the gap of a corner or the Dock's edge; it is put back at the
 * pointer's place when the guard lets go; events queued before the let-go
 * don't jump back to the held cursor; with the Mac's cursor as the visible
 * pointer (follow) it follows at the same speed; the guard's place maps into
 * our windows (top row, notch strip, externals). And the old guard (a warp
 * on every event) is shown to race: its steps add up.
 *
 * cc -Wall -Werror -I<qemu>/ui test-pointer-guard.c -o t && ./t
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "omacvm-pointer-guard.h"

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: ", __FILE__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while (0)

/* The model of macOS. */
typedef struct Mac {
    OmacVMGuardScreens s;
    double x, y;        /* the cursor */
    bool attached;
    double wdx, wdy;    /* warp distance the next event carries */
    double time;
} Mac;

typedef struct Ev {
    double time, lx, ly, dx, dy;
} Ev;

/* The mouse moved by (ax, ay) (macOS's accelerated motion): the event it makes. */
static Ev mac_motion(Mac *m, double ax, double ay)
{
    Ev e;

    if (m->attached) {
        double nx = m->x + ax, ny = m->y + ay;
        int d = omacvm_guard_display_at(&m->s, nx, ny);

        if (d < 0) {
            d = omacvm_guard_display_at(&m->s, m->x, m->y);
        }
        omacvm_guard_fit(&m->s, d, &nx, &ny, 0);
        m->x = nx;
        m->y = ny;
    }
    m->time += 1.0 / 120;
    e.time = m->time;
    e.lx = m->x;
    e.ly = m->y;
    e.dx = ax + m->wdx;
    e.dy = ay + m->wdy;
    m->wdx = m->wdy = 0;
    return e;
}

static void mac_warp(Mac *m, double x, double y)
{
    m->wdx += x - m->x;
    m->wdy += y - m->y;
    m->x = x;
    m->y = y;
}

/*
 * A button pressed or let go: an event at the cursor with no motion. It does
 * not carry a warp's distance; the next motion does.
 */
static Ev mac_button(Mac *m)
{
    Ev e;

    m->time += 1.0 / 120;
    e.time = m->time;
    e.lx = m->x;
    e.ly = m->y;
    e.dx = e.dy = 0;
    return e;
}

/* ui/cocoa.m lets go (ungrab, another Space): the model does what the step says. */
static void mac_let_go(Mac *m, OmacVMGuard *g)
{
    OmacVMGuardStep st;

    memset(&st, 0, sizeof(st));
    omacvm_guard_release(g, &m->s, &st);
    if (st.warp) {
        mac_warp(m, st.wx, st.wy);
    }
    if (st.attach) {
        m->attached = true;
    }
}

/* The guard handles one event, the model does what it says; the guest's place. */
static void handle(Mac *m, OmacVMGuard *g, const Ev *e, double *gx, double *gy)
{
    OmacVMGuardStep st;

    omacvm_guard_event(g, &m->s, e->time, e->lx, e->ly, e->dx, e->dy,
                       m->x, m->y, &st);
    if (st.warp) {
        mac_warp(m, st.wx, st.wy);
    }
    if (st.detach) {
        m->attached = false;
    }
    if (st.attach) {
        m->attached = true;
    }
    *gx = st.place ? g->x : e->lx;
    *gy = st.place ? g->y : e->ly;
}

/* The Mac's cursor is never within the gap of a corner or the Dock's edge (bottom). */
static void check_cursor(const Mac *m, const char *what)
{
    for (int i = 0; i < m->s.ndisplays; i++) {
        const OmacVMRect *r = &m->s.displays[i];
        double minx = r->x, maxx = r->x + r->w - 1;
        double miny = r->y, maxy = r->y + r->h - 1;

        if (!omacvm_guard_in(r, m->x, m->y)) {
            continue;
        }
        bool outl = omacvm_guard_display_at(&m->s, minx - 1, m->y) < 0;
        bool outr = omacvm_guard_display_at(&m->s, maxx + 1, m->y) < 0;
        bool outt = omacvm_guard_display_at(&m->s, m->x, miny - 1) < 0;
        bool outb = omacvm_guard_display_at(&m->s, m->x, maxy + 1) < 0;
        bool nearx = (outl && m->x < minx + OMACVM_GUARD_GAP) ||
                     (outr && m->x > maxx - OMACVM_GUARD_GAP);
        bool neary = (outt && m->y < miny + OMACVM_GUARD_GAP) ||
                     (outb && m->y > maxy - OMACVM_GUARD_GAP);

        CHECK(!(nearx && neary), "%s: Mac cursor in a corner at %.1f,%.1f", what, m->x, m->y);
        CHECK(!(outb && m->y > maxy - OMACVM_GUARD_GAP),
              "%s: Mac cursor on the Dock's edge at %.1f,%.1f", what, m->x, m->y);
    }
}

/*
 * Moves n times by (ax, ay) from where the cursor is; every step of the
 * guest's pointer must be the motion, except where an outer edge stops it.
 */
static void run_steps(Mac *m, OmacVMGuard *g, int n, double ax, double ay,
                      int twice, const char *what)
{
    double px = m->x, py = m->y, gx, gy;

    if (g->held) {
        px = g->x;
        py = g->y;
    }
    for (int i = 0; i < n; i++) {
        Ev e = mac_motion(m, ax, ay);
        int d0 = omacvm_guard_display_at(&m->s, px, py);
        double ex = px + ax, ey = py + ay;

        handle(m, g, &e, &gx, &gy);
        if (twice) {
            handle(m, g, &e, &gx, &gy);
        }
        /* Where the motion takes it, stopped at an outer edge. */
        if (omacvm_guard_display_at(&m->s, ex, ey) >= 0) {
            d0 = omacvm_guard_display_at(&m->s, ex, ey);
        }
        omacvm_guard_fit(&m->s, d0, &ex, &ey, 0);
        CHECK(fabs(gx - ex) < 1e-9 && fabs(gy - ey) < 1e-9,
              "%s: step %d to %.3f,%.3f, expected %.3f,%.3f (held %d)",
              what, i, gx, gy, ex, ey, g->held);
        check_cursor(m, what);
        if (g->follow && g->held) {
            /* The visible cursor is where the pointer is (one event behind at most). */
            double tx = gx, ty = gy;
            int d = omacvm_guard_display_at(&m->s, tx, ty);

            omacvm_guard_fit(&m->s, d, &tx, &ty, OMACVM_GUARD_GAP);
            CHECK(fabs(m->x - tx) <= fabs(ax) + 1 && fabs(m->y - ty) <= fabs(ay) + 1,
                  "%s: step %d: the shown cursor at %.1f,%.1f, the pointer at %.1f,%.1f",
                  what, i, m->x, m->y, gx, gy);
        }
        px = gx;
        py = gy;
    }
}

static const OmacVMRect macbook = { 0, 0, 1728, 1117 };
static const OmacVMRect two[2] = { { 0, 0, 1728, 1117 }, { 1728, -200, 1920, 1080 } };

static Mac mac_at(const OmacVMRect *d, int nd, const OmacVMRect *ours, int no,
                  double x, double y)
{
    Mac m;

    memset(&m, 0, sizeof(m));
    m.s.displays = d;
    m.s.ndisplays = nd;
    m.s.ours = ours;
    m.s.nours = no;
    m.s.dock_edge = OMACVM_DOCK_BOTTOM;
    m.x = x;
    m.y = y;
    m.attached = true;
    return m;
}

int main(void)
{
    OmacVMGuard g;
    Mac m;
    double gx, gy;

    /* Centre: the guard does nothing, macOS moves the cursor. */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 700, 500);
    run_steps(&m, &g, 100, 2, 1, 0, "centre");
    CHECK(!g.held, "centre: held");

    /* Into the top-right corner and along both edges (mouse sized steps). */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 1300, 450);
    run_steps(&m, &g, 200, 3, -2.5, 0, "to the top-right corner");
    CHECK(g.held, "corner: not held");
    CHECK(g.x == 1727 && g.y == 0, "corner: the pointer stops at %.1f,%.1f, not the corner", g.x, g.y);
    run_steps(&m, &g, 150, -4, 0, 0, "along the top edge, out of the zone");
    CHECK(!g.held, "top edge: still held out of the zone");
    run_steps(&m, &g, 150, 4, 0.5, 0, "back into the zone");

    /* Trackpad sized steps across the zone's border, back and forth. */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 300, 850);
    for (int k = 0; k < 6; k++) {
        run_steps(&m, &g, 400, 0, 0.37, 0, "trackpad down into the Dock zone");
        run_steps(&m, &g, 400, 0.05, -0.37, 0, "trackpad up out of it");
    }

    /* Along the Dock's edge, the whole width, each event handed over twice. */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 300, 1000);
    run_steps(&m, &g, 2, 0, 1, 1, "into the Dock zone, twice each");
    run_steps(&m, &g, 600, 2.5, 0.2, 1, "along the Dock's edge, twice each");

    /* Across a shared edge to the next display (both full screen) and back. */
    memset(&g, 0, sizeof(g));
    m = mac_at(two, 2, two, 2, 1600, 1000);
    run_steps(&m, &g, 120, 3, 0.5, 0, "across the shared edge in the Dock zone");
    run_steps(&m, &g, 120, -3, -0.5, 0, "back across it");
    memset(&g, 0, sizeof(g));
    m = mac_at(two, 2, two, 2, 1500, 100);
    run_steps(&m, &g, 200, 2, -1, 0, "over the top-right corner to the external");

    /* A flick onto the corner in one event: off it at once, then no jump. */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 864, 558);
    {
        Ev e = mac_motion(&m, 2000, -2000);

        handle(&m, &g, &e, &gx, &gy);
        CHECK(g.held && gx == 1727 && gy == 0, "flick: pointer %.1f,%.1f", gx, gy);
        CHECK(m.x == 1727 - OMACVM_GUARD_GAP && m.y == OMACVM_GUARD_GAP,
              "flick: Mac cursor left at %.1f,%.1f", m.x, m.y);
    }
    run_steps(&m, &g, 50, -1, 1, 0, "after the flick");

    /* An event made before that warp (queued) carries no warp distance. */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 864, 558);
    {
        Ev e1 = mac_motion(&m, 2000, 2000);
        Ev e2 = mac_motion(&m, -1, -1);   /* made before the guard saw e1 */

        handle(&m, &g, &e1, &gx, &gy);
        handle(&m, &g, &e2, &gx, &gy);
        CHECK(gx == 1726 && gy == 1115, "queued: pointer %.1f,%.1f", gx, gy);
    }
    run_steps(&m, &g, 50, -1, -1, 0, "after the queued event");

    /* Letting go: the Mac's cursor comes back where the pointer is. */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 1500, 250);
    run_steps(&m, &g, 60, 1, -1, 0, "into the corner zone");
    CHECK(g.held && g.x == 1560 && g.y == 190, "release: pointer %.1f,%.1f held %d", g.x, g.y, g.held);
    {
        OmacVMGuardStep st;

        memset(&st, 0, sizeof(st));
        omacvm_guard_release(&g, &m.s, &st);
        CHECK(st.warp && st.attach && st.wx == 1560 && st.wy == 190 && !g.held,
              "release: warp %d to %.1f,%.1f", st.warp, st.wx, st.wy);
    }
    /* Let go on the corner itself: the Mac's cursor goes the gap off it. */
    memset(&g, 0, sizeof(g));
    m = mac_at(&macbook, 1, &macbook, 1, 1600, 100);
    run_steps(&m, &g, 200, 2, -2, 0, "onto the corner");
    {
        OmacVMGuardStep st;

        omacvm_guard_release(&g, &m.s, &st);
        CHECK(st.wx == 1727 - OMACVM_GUARD_GAP && st.wy == OMACVM_GUARD_GAP,
              "release on the corner: warp to %.1f,%.1f", st.wx, st.wy);
    }

    /* The notch strip (above the window) is macOS's: let go there. */
    {
        static const OmacVMRect below = { 0, 32, 1728, 1085 };

        memset(&g, 0, sizeof(g));
        m = mac_at(&macbook, 1, &below, 1, 100, 300);
        run_steps(&m, &g, 130, 0, -2.5, 0, "up into the strip");
        CHECK(!g.held && m.attached, "strip: still held");
    }

    /*
     * The window below the strip (MacBook Air, full screen via Omanotch:
     * display 1470x956, window from y 33): along the bottom edge from the
     * middle into both bottom corners, with the motion a mouse gives (5.964
     * points along per event). The guard's place reaches each corner and maps
     * to the window's bottom row: the window's origin is not in the maths
     * for x. (The 3.4.6 rows stopped 34 px short there: their injector's
     * events kept only the whole points of each delta, 5 of 5.964.)
     */
    {
        static const OmacVMRect air = { 0, 0, 1470, 956 };
        static const OmacVMRect below = { 0, 33, 1470, 923 };
        double wx, wy;
        int i;

        for (int dir = -1; dir <= 1; dir += 2) {
            memset(&g, 0, sizeof(g));
            m = mac_at(&air, 1, &below, 1, 735, 656);
            run_steps(&m, &g, 67, 0, 5.97, 0, "below the strip: down into the Dock zone");
            run_steps(&m, &g, 140, dir * 5.964, 0.457, 0,
                      "below the strip: along the bottom edge into a corner");
            i = omacvm_guard_window_point(&m.s, g.x, g.y, &wx, &wy);
            CHECK(g.held && g.x == (dir > 0 ? 1469 : 0) && g.y == 955,
                  "below the strip (%+d): pointer %.1f,%.1f held %d, not the corner",
                  dir, g.x, g.y, g.held);
            CHECK(i == 0 && wx == (dir > 0 ? 1469 : 0) && wy == 1,
                  "below the strip (%+d): window %d at %.1f,%.1f, not its bottom corner",
                  dir, i, wx, wy);
        }
    }

    /*
     * Known limit (kept on purpose, see docs/troubleshooting.md): the strip
     * is the Mac's menu-bar area, not our window. Moving up-left from the
     * window, the guard lets go at the window's top edge, and the Mac's
     * cursor goes on into the display's top-left corner, so a hot corner set
     * there can fire. Guarding the strip's corners would need an event tap
     * after ui/cocoa.m lets go of the pointer; if that is built, this check
     * turns into the corner check above.
     */
    {
        static const OmacVMRect air = { 0, 0, 1470, 956 };
        static const OmacVMRect below = { 0, 33, 1470, 923 };

        memset(&g, 0, sizeof(g));
        m = mac_at(&air, 1, &below, 1, 300, 300);
        for (int i = 0; i < 200; i++) {
            Ev e = mac_motion(&m, -1.5, -2.5);

            handle(&m, &g, &e, &gx, &gy);
        }
        CHECK(!g.held && m.attached && m.x == 0 && m.y == 0,
              "strip corner (known limit): held %d attached %d, Mac cursor %.1f,%.1f",
              g.held, m.attached, m.x, m.y);
    }

    /*
     * Events made while held but handled after the let-go (queued) are at the
     * held cursor's place: they move the pointer by their delta, no jump back
     * to that place (review of RC5: 1526 -> 1700 -> 1524 there).
     */
    for (int follow = 0; follow < 2; follow++) {
        double max_step = 0, ox, oy;

        memset(&g, 0, sizeof(g));
        g.follow = follow;
        m = mac_at(&macbook, 1, &macbook, 1, 1700, 260);
        run_steps(&m, &g, 40, 0, -2, 0, "up into the top-right zone");
        CHECK(g.held, "queued after let-go: not held");
        run_steps(&m, &g, 85, -2, 0, 0, "left to the zone's border");
        CHECK(g.held && g.x == 1530, "queued after let-go: pointer %.1f,%.1f", g.x, g.y);
        ox = g.x;
        oy = g.y;
        {
            Ev e[4];

            e[0] = mac_motion(&m, -3, 0);   /* takes it out of the zone */
            e[1] = mac_motion(&m, -2, 0);   /* made before the let-go */
            e[2] = mac_motion(&m, -2, 0);
            for (int i = 0; i < 3; i++) {
                handle(&m, &g, &e[i], &gx, &gy);
                CHECK(!g.held, "queued after let-go: held again at event %d (%.1f,%.1f)",
                      i, gx, gy);
                max_step = fmax(max_step, fmax(fabs(gx - ox), fabs(gy - oy)));
                ox = gx;
                oy = gy;
            }
            CHECK(gx == 1523 && gy == oy, "queued after let-go: pointer %.1f,%.1f", gx, gy);
            for (int i = 0; i < 50; i++) {
                e[3] = mac_motion(&m, -2, 0);
                handle(&m, &g, &e[3], &gx, &gy);
                max_step = fmax(max_step, fmax(fabs(gx - ox), fabs(gy - oy)));
                ox = gx;
                oy = gy;
            }
        }
        CHECK(max_step <= 3 && !g.held && m.attached,
              "queued after let-go (follow %d): a step of %.1f points", follow, max_step);
    }

    /* Follow: let go while a warp is in flight; the queued events are at the place before it. */
    {
        Ev e[3];

        memset(&g, 0, sizeof(g));
        g.follow = true;
        m = mac_at(&macbook, 1, &macbook, 1, 1700, 260);
        run_steps(&m, &g, 40, 0, -2, 0, "follow: up into the top-right zone");
        run_steps(&m, &g, 84, -2, 0, 0, "follow: left near the zone's border");
        CHECK(g.held && g.x == 1532, "follow, in flight: pointer %.1f,%.1f", g.x, g.y);
        e[0] = mac_motion(&m, -2, 0);   /* still in the zone: a follow warp */
        e[1] = mac_motion(&m, -3, 0);   /* out of it, made before that warp */
        e[2] = mac_motion(&m, -2, 0);
        for (int i = 0; i < 3; i++) {
            handle(&m, &g, &e[i], &gx, &gy);
        }
        CHECK(!g.held && gx == 1525, "follow, in flight: pointer %.1f,%.1f held %d",
              gx, gy, g.held);
    }

    /*
     * A click on an external display's window near its top-left corner (the
     * bar's workspace buttons): the click makes that window key, the main
     * window gives it back, and ui/cocoa.m lets go and grabs again in
     * between. The button press was made while held (at the held cursor),
     * the release after the let-go's warp (at the pointer's place, where it
     * takes hold again), and the next motion carries that warp's distance.
     * The pointer must not move at the click nor jump at the next motion
     * (3.2.3: it jumped by the way from the held cursor to the click, the
     * distance from the click before, reported by the user). Below the
     * top edge and on it (the gap: the let-go's warp is 3 points off it).
     * With follow the cursor is at the pointer: the release is at the held
     * cursor's place, and the next motion takes hold.
     */
    for (int run = 0; run < 4; run++) {
        static const OmacVMRect beside[2] = { { 0, 0, 1512, 982 }, { 1512, 0, 1352, 845 } };
        int follow = run & 1, top = run >> 1;

        memset(&g, 0, sizeof(g));
        g.follow = follow;
        m = mac_at(beside, 2, beside, 2, 1512 + 400, 300);
        run_steps(&m, &g, top ? 160 : 130, -2, -2, 0, "external: up into its top-left zone");
        CHECK(g.held && g.y == (top ? 0 : 40), "external click: held %d at %.1f,%.1f",
              g.held, g.x, g.y);
        for (int k = 0; k < 3; k++) {
            double x0, y0;
            Ev down, up;

            run_steps(&m, &g, 10, 1, 0, 0, "external: to the next button");
            x0 = g.x;
            y0 = g.y;
            down = mac_button(&m);
            mac_let_go(&m, &g);
            handle(&m, &g, &down, &gx, &gy);
            CHECK(gx == x0 && gy == y0, "external click %d (follow %d, top %d): pressed at "
                  "%.1f,%.1f, the pointer was at %.1f,%.1f", k, follow, top, gx, gy, x0, y0);
            up = mac_button(&m);
            handle(&m, &g, &up, &gx, &gy);
            CHECK(gx == x0 && gy == y0 && (g.held || follow),
                  "external click %d (follow %d, top %d): let go at %.1f,%.1f, the pointer "
                  "was at %.1f,%.1f (held %d)", k, follow, top, gx, gy, x0, y0, g.held);
            run_steps(&m, &g, 5, 1, 0, 0, "external: on after the click");
        }
    }

    /*
     * The let-go's warp is taken out of a motion only, never out of a button
     * (it carries none): a click after another kind of let-go (another
     * Space, Command-Tab and back) without moving, and a second click right
     * after a hold taken by a button (no let-go, the main window stays key),
     * land where the pointer is, and so does the motion after them.
     */
    for (int run = 0; run < 4; run++) {
        static const OmacVMRect beside[2] = { { 0, 0, 1512, 982 }, { 1512, 0, 1352, 845 } };
        int follow = run & 1, second = run >> 1;
        double x0, y0;
        Ev down, up;

        memset(&g, 0, sizeof(g));
        g.follow = follow;
        m = mac_at(beside, 2, beside, 2, 1512 + 400, 300);
        run_steps(&m, &g, 130, -2, -2, 0, "button: up into the external's top-left zone");
        run_steps(&m, &g, 10, 1, 0, 0, "button: to a button");
        if (second) {
            /* A click on the external's window: let go, taken again by the release. */
            down = mac_button(&m);
            mac_let_go(&m, &g);
            handle(&m, &g, &down, &gx, &gy);
            up = mac_button(&m);
            handle(&m, &g, &up, &gx, &gy);
        } else {
            mac_let_go(&m, &g);
        }
        for (int k = 0; k < 2; k++) {
            x0 = g.x;
            y0 = g.y;
            down = mac_button(&m);
            handle(&m, &g, &down, &gx, &gy);
            CHECK(fabs(gx - x0) < 0.5 && fabs(gy - y0) < 0.5,
                  "button %d (follow %d, second %d): pressed at %.1f,%.1f, the pointer was at "
                  "%.1f,%.1f", k, follow, second, gx, gy, x0, y0);
            up = mac_button(&m);
            handle(&m, &g, &up, &gx, &gy);
            CHECK(fabs(gx - x0) < 0.5 && fabs(gy - y0) < 0.5,
                  "button %d (follow %d, second %d): let go at %.1f,%.1f, the pointer was at "
                  "%.1f,%.1f", k, follow, second, gx, gy, x0, y0);
        }
        run_steps(&m, &g, 5, 1, 0, 0, "button: on after the clicks");
    }

    /*
     * Let go (Ctrl+Alt+G, another app) while held, then the mouse moves where
     * the guard does not see it (ungrabbed): that motion carried the let-go's
     * warp. A click back into the VM in a corner zone takes hold at the click,
     * and the motion after it is the mouse's own.
     */
    for (int follow = 0; follow < 2; follow++) {
        memset(&g, 0, sizeof(g));
        g.follow = follow;
        m = mac_at(&macbook, 1, &macbook, 1, 100, 100);
        run_steps(&m, &g, 1, -5, -5, 0, "unseen: into the top-left zone");
        run_steps(&m, &g, 5, 10, 0, 0, "unseen: held");
        mac_let_go(&m, &g);
        for (int i = 0; i < 30; i++) {
            mac_motion(&m, -3, -1.5);
        }
        for (int k = 0; k < 2; k++) {
            Ev e = mac_button(&m);
            double x0 = e.lx, y0 = e.ly;

            handle(&m, &g, &e, &gx, &gy);
            CHECK(fabs(gx - x0) < 0.5 && fabs(gy - y0) < 0.5,
                  "unseen (follow %d): button %d at %.1f,%.1f, clicked at %.1f,%.1f",
                  follow, k, gx, gy, x0, y0);
        }
        run_steps(&m, &g, 5, 1, 0, 0, "unseen: on after the click");
    }

    /*
     * A hold taken by a button puts the let-go's warp in flight without
     * moving the cursor. A let-go right after it (no motion between: another
     * Space, a display change) must count that warp in its own: the next
     * motion carries both (the model's pending distance).
     */
    {
        static const OmacVMRect beside[2] = { { 0, 0, 1512, 982 }, { 1512, 0, 1352, 845 } };
        Ev down, up;

        memset(&g, 0, sizeof(g));
        m = mac_at(beside, 2, beside, 2, 1512 + 400, 300);
        run_steps(&m, &g, 130, -2, -2, 0, "twice: up into the external's top-left zone");
        run_steps(&m, &g, 10, 1, 0, 0, "twice: to a button");
        down = mac_button(&m);
        mac_let_go(&m, &g);
        handle(&m, &g, &down, &gx, &gy);
        up = mac_button(&m);
        handle(&m, &g, &up, &gx, &gy);
        CHECK(g.held && g.warp_pending, "twice: the release took hold (held %d, pending %d)",
              g.held, g.warp_pending);
        mac_let_go(&m, &g);
        CHECK(g.let_go_warp && fabs(g.lwdx - m.wdx) < 1e-9 && fabs(g.lwdy - m.wdy) < 1e-9,
              "twice: the let-go counts %.1f,%.1f in flight, the next motion carries %.1f,%.1f",
              g.lwdx, g.lwdy, m.wdx, m.wdy);
    }

    /*
     * The external click again, but the mouse moves on before the button's
     * release is handled (a busy main thread): two motions are queued behind
     * it, made after the let-go's warp, with the cursor attached. The first
     * carries the warp. Neither may jump: the release does not take hold,
     * the motions come at the cursor's place (at most the gap off the top
     * edge) and the first of them takes hold.
     */
    for (int run = 0; run < 4; run++) {
        static const OmacVMRect beside[2] = { { 0, 0, 1512, 982 }, { 1512, 0, 1352, 845 } };
        int follow = run & 1, top = run >> 1;
        double x0, y0;
        Ev down, up, mv[2];

        memset(&g, 0, sizeof(g));
        g.follow = follow;
        m = mac_at(beside, 2, beside, 2, 1512 + 400, 300);
        run_steps(&m, &g, top ? 160 : 130, -2, -2, 0, "queued: up into the external's top-left zone");
        run_steps(&m, &g, 10, 1, 0, 0, "queued: to a button");
        x0 = g.x;
        y0 = g.y;
        down = mac_button(&m);
        mac_let_go(&m, &g);
        handle(&m, &g, &down, &gx, &gy);
        up = mac_button(&m);
        mv[0] = mac_motion(&m, 2, 1);
        mv[1] = mac_motion(&m, 2, 1);
        handle(&m, &g, &up, &gx, &gy);
        CHECK(fabs(gx - x0) < 0.5 && fabs(gy - y0) < 0.5,
              "queued (follow %d, top %d): let go at %.1f,%.1f, the pointer was at %.1f,%.1f",
              follow, top, gx, gy, x0, y0);
        for (int k = 0; k < 2; k++) {
            double ex = x0 + 2 * (k + 1), ey = y0 + (k + 1);

            handle(&m, &g, &mv[k], &gx, &gy);
            CHECK(fabs(gx - ex) < 0.5 && fabs(gy - ey) <= OMACVM_GUARD_GAP + 0.5,
                  "queued (follow %d, top %d): motion %d to %.1f,%.1f, expected %.1f,%.1f",
                  follow, top, k, gx, gy, ex, ey);
        }
        run_steps(&m, &g, 5, 1, 0, 0, "queued: on after the motions");
    }

    /*
     * The debug log's hint (OMACVM_POINTER_DEBUG=1 in ui/cocoa.m): the motion
     * after the user's click says it had the let-go's warp taken out, by the
     * distance it carried; the motion after it does not.
     */
    {
        static const OmacVMRect beside[2] = { { 0, 0, 1512, 982 }, { 1512, 0, 1352, 845 } };
        OmacVMGuardStep st;
        Ev down, up, e;
        double cdx, cdy;

        memset(&g, 0, sizeof(g));
        m = mac_at(beside, 2, beside, 2, 1512 + 400, 300);
        run_steps(&m, &g, 130, -2, -2, 0, "debug: up into the external's top-left zone");
        run_steps(&m, &g, 10, 1, 0, 0, "debug: to a button");
        down = mac_button(&m);
        mac_let_go(&m, &g);
        handle(&m, &g, &down, &gx, &gy);
        up = mac_button(&m);
        handle(&m, &g, &up, &gx, &gy);
        cdx = m.wdx;
        cdy = m.wdy;
        for (int k = 0; k < 2; k++) {
            e = mac_motion(&m, 1, 0);
            omacvm_guard_event(&g, &m.s, e.time, e.lx, e.ly, e.dx, e.dy, m.x, m.y, &st);
            CHECK(st.let_go_out == (k == 0) &&
                  (k || (fabs(st.ldx - cdx) < 1e-9 && fabs(st.ldy - cdy) < 1e-9)),
                  "debug: motion %d says let-go out %d (%.1f,%.1f), carried %.1f,%.1f",
                  k, st.let_go_out, st.ldx, st.ldy, k ? 0.0 : cdx, k ? 0.0 : cdy);
        }
    }

    /* The Mac's cursor shown (show-cursor=on): it follows, at the same speed. */
    memset(&g, 0, sizeof(g));
    g.follow = true;
    m = mac_at(&macbook, 1, &macbook, 1, 1300, 450);
    run_steps(&m, &g, 200, 3, -2.5, 0, "follow: to the top-right corner");
    CHECK(g.held && g.x == 1727 && g.y == 0, "follow: corner %.1f,%.1f", g.x, g.y);
    CHECK(m.x == 1727 - OMACVM_GUARD_GAP && m.y == OMACVM_GUARD_GAP,
          "follow: shown cursor at %.1f,%.1f, not the gap off the corner", m.x, m.y);
    run_steps(&m, &g, 150, -4, 0, 0, "follow: along the top edge, out of the zone");
    memset(&g, 0, sizeof(g));
    g.follow = true;
    m = mac_at(&macbook, 1, &macbook, 1, 300, 1000);
    run_steps(&m, &g, 2, 0, 1, 1, "follow: into the Dock zone, twice each");
    run_steps(&m, &g, 600, 2.5, 0.2, 1, "follow: along the Dock's edge, twice each");
    memset(&g, 0, sizeof(g));
    g.follow = true;
    m = mac_at(&macbook, 1, &macbook, 1, 300, 850);
    for (int k = 0; k < 3; k++) {
        run_steps(&m, &g, 400, 0, 0.37, 0, "follow: trackpad into the Dock zone");
        run_steps(&m, &g, 400, 0.05, -0.37, 0, "follow: trackpad out of it");
    }
    memset(&g, 0, sizeof(g));
    g.follow = true;
    m = mac_at(two, 2, two, 2, 1500, 100);
    run_steps(&m, &g, 200, 2, -1, 0, "follow: over the top-right corner to the external");
    /* Follow with a queued event: one warp in flight, its distance taken out once. */
    memset(&g, 0, sizeof(g));
    g.follow = true;
    m = mac_at(&macbook, 1, &macbook, 1, 300, 1000);
    run_steps(&m, &g, 3, 0, 1, 0, "follow: into the Dock zone");
    {
        Ev e1 = mac_motion(&m, 5, 0);
        Ev e2 = mac_motion(&m, 5, 0);   /* made before the warp e1 asks for */
        double x0 = g.x;

        handle(&m, &g, &e1, &gx, &gy);
        handle(&m, &g, &e2, &gx, &gy);
        CHECK(gx == x0 + 10, "follow, queued: pointer %.1f, expected %.1f", gx, x0 + 10);
    }
    run_steps(&m, &g, 100, 5, 0, 0, "follow: after the queued event");

    /*
     * The guard's place in our windows (ui/cocoa.m sends it to the guest from
     * there): the top row counts (the guard stops the pointer on it; RC5 sent
     * the held cursor's place instead), AppKit's frames convert to the
     * guard's space, and a place in none of them is -1 (no position sent).
     */
    {
        const double top = 1117;    /* NSMaxY of the main display's frame */
        OmacVMRect wins[3];
        OmacVMGuardScreens s;
        double wx, wy;
        int i;

        /* The MacBook below the notch strip, an external above to the right. */
        wins[0] = omacvm_guard_rect_from_cocoa(top, 0, 0, 1728, 1085);
        wins[1] = omacvm_guard_rect_from_cocoa(top, 1728, 237, 1920, 1080);
        /* A second MacBook-style window over the whole display. */
        wins[2] = omacvm_guard_rect_from_cocoa(top, -1728, 0, 1728, 1117);
        CHECK(wins[0].x == 0 && wins[0].y == 32 && wins[0].h == 1085,
              "frame below the notch: %.0f,%.0f %.0fx%.0f", wins[0].x, wins[0].y,
              wins[0].w, wins[0].h);
        CHECK(wins[1].x == 1728 && wins[1].y == -200, "external frame: %.0f,%.0f",
              wins[1].x, wins[1].y);
        memset(&s, 0, sizeof(s));
        s.ours = wins;
        s.nours = 3;

        i = omacvm_guard_window_point(&s, 1727, 32, &wx, &wy);
        CHECK(i == 0 && wx == 1727 && wy == 1085,
              "top row below the notch: window %d at %.1f,%.1f", i, wx, wy);
        i = omacvm_guard_window_point(&s, 1727, 31.5, &wx, &wy);
        CHECK(i == -1, "the notch strip is not ours: window %d", i);
        i = omacvm_guard_window_point(&s, 1728 + 1919, -200, &wx, &wy);
        CHECK(i == 1 && wx == 1919 && wy == 1080,
              "external top-right corner: window %d at %.1f,%.1f", i, wx, wy);
        i = omacvm_guard_window_point(&s, 1728, 879, &wx, &wy);
        CHECK(i == 1 && wx == 0 && wy == 1, "external bottom row: window %d at %.1f,%.1f",
              i, wx, wy);
        i = omacvm_guard_window_point(&s, 1728, 880, &wx, &wy);
        CHECK(i == -1, "below the external: window %d", i);
        i = omacvm_guard_window_point(&s, -1728, 0, &wx, &wy);
        CHECK(i == 2 && wx == 0 && wy == 1117, "top-left corner: window %d at %.1f,%.1f",
              i, wx, wy);
        i = omacvm_guard_window_point(&s, 0, 1116, &wx, &wy);
        CHECK(i == 0 && wx == 0 && wy == 1, "bottom-left: window %d at %.1f,%.1f", i, wx, wy);

        /* Where the guard stops a pointer pushed up into a top corner maps there. */
        memset(&g, 0, sizeof(g));
        m = mac_at(two, 2, wins, 2, 3500, 100);
        m.s.ours = wins;
        run_steps(&m, &g, 200, 2, -2, 0, "external: into its top-right corner");
        i = omacvm_guard_window_point(&m.s, g.x, g.y, &wx, &wy);
        CHECK(g.held && i == 1 && wx == 1919 && wy == 1080,
              "external corner: pointer %.1f,%.1f -> window %d at %.1f,%.1f",
              g.x, g.y, i, wx, wy);
    }

    /*
     * The old guard (2.8.0 to 2.9.0 RC4) through the same model: while held it
     * added the event's delta and warped the cursor there, every event. Along
     * the Dock's edge the steps add up.
     */
    {
        double px = 0, py = 0, step = 0;
        bool held = false;

        m = mac_at(&macbook, 1, &macbook, 1, 300, 1000);
        for (int i = 0; i < 20; i++) {
            Ev e = mac_motion(&m, 2, 0);
            double ox = held ? px : e.lx;

            if (held) {
                px += e.dx;
                py += e.dy;
            } else {
                px = e.lx;
                py = e.ly;
            }
            if (omacvm_guard_fit(&m.s, 0, &px, &py, OMACVM_GUARD_GAP)) {
                held = true;
                m.attached = false;
                mac_warp(&m, px, py);
            }
            step = px - ox;
        }
        printf("old guard: 20th step %.0f points for a 2 point motion (%.0fx)\n",
               step, step / 2);
        CHECK(step >= 38, "the model does not show the old race");
    }

    if (failures) {
        printf("test-pointer-guard: %d failures\n", failures);
        return 1;
    }
    printf("test-pointer-guard: ok\n");
    return 0;
}
