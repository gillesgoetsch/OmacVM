/*
 * FullPanel after a display change (ui/omacvm-fullpanel-retake.h,
 * omacvm-cocoa-fullpanel-retake.patch): the rules, and the user's qemu.log
 * (M4 Max, OmacVM 3.2.9, 2026-10-28: the built-in XDR 1728x1117 with an LG
 * UltraFine 5K above it; unplug, replug, sleep; the strip beside the notch
 * stayed away until full screen was entered again) replayed through a C copy
 * of the window's FullPanel state (OmacVMFullPanelState in ui/cocoa.m,
 * method by method: willEnterFullScreen, verify:, frameChanged:,
 * screenChanged:, comeBack/checkReturn, engage, retake:, retakeExpired)
 * that decides with the header's rules. AppKit is modelled from the log:
 * its full-screen layout asks the reservation (its own yes only when the
 * Space's display has a camera housing; FullPanel's answer no while the
 * window claims the strip) and keeps the menu bar's band when the answer
 * stays yes.
 *
 * Built against the real header (test-fullpanel-retake.sh), every row must
 * pass. Built with -DOMACVM_RETAKE_STUB against 3.2.10's decisions
 * (test-fullpanel-retake-stub.h, --self-test), the user's rows must fail.
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#ifdef OMACVM_RETAKE_STUB
#include "test-fullpanel-retake-stub.h"
#else
#include "omacvm-fullpanel-retake.h"
#endif

#ifndef OMACVM_FP_CLAIMS_WAIT_FOR_RESUME
#define OMACVM_FP_CLAIMS_WAIT_FOR_RESUME 0
#endif

typedef struct {
    const char *name;
    OmacVMFPRect f;
    double notch;       /* NSScreen's safeAreaInsets.top */
    double band;        /* the menu bar's band AppKit keeps free (_revealedMenuBarHeight) */
} Disp;

/* As in the user's log: the built-in is main at 0,0, the LG above it. */
static const Disp BUILTIN = { "built-in", { 0, 0, 1728, 1117 }, 32, 33 };
static const Disp BUILTIN_BIG = { "built-in at 2056x1329", { 0, 0, 2056, 1329 }, 38, 39 };
static const Disp BUILTIN_SMALL = { "built-in at 1512x982", { 0, 0, 1512, 982 }, 28, 29 };
static const Disp LG = { "LG 5K", { 0, 0, 2560, 1440 }, 0, 0 };
static const Disp STANDIN = { "1920x1080 stand-in", { 0, 0, 1920, 1080 }, 0, 0 };
static const Disp SMALL = { "1280x800 external", { 0, 0, 1280, 800 }, 0, 0 };

/* What omacvm check reads last (src/cmd/check.sh). */
enum { CHECK_NONE, CHECK_COVERED, CHECK_LOST, CHECK_NORMAL, CHECK_NOT_BACK };

typedef struct {
    /* The window (AppKit) and its display. */
    OmacVMFPRect frame;
    const Disp *screen;       /* [window screen]: NSScreen, can be stale */
    const Disp *space;        /* the display AppKit's full-screen Space is on */
    bool full, key, on_space, visible, in_place;
    bool screen_live;         /* CoreGraphics: that NSScreen's display is on and awake */
    bool screen_same_size;    /* CoreGraphics' size of it is the accepted one / NSScreen's */
    /* The Mac. */
    bool locked;              /* the display updates' lock (locked, asleep, another user) */
    bool due;                 /* a display update is due (a screen change asked for one) */
    bool moving;              /* a display's window moves into or out of full screen */
    bool menu_bar_shown;      /* "Always show the menu bar" without Keep the Dock away */
    bool reshape;             /* AppKit's tile relayout is there */
    bool reshape_works;       /* it lays the window out (macOS 27: not while a flag is set) */
    double now;
    unsigned settles;
    /* OmacVMFullPanelState */
    bool inside, armed, entered, accepted, rejected, lost, released;
    bool displaced, display_changed, tracking, covered_logged;
    bool retake_pending, retake_given_up;
    double lost_at;
    int retake_tries;
    unsigned retake_settle;
    OmacVMFPRect accepted_display;
    /* Lines. */
    int n_covered, n_lost, n_displaced, n_moved, n_taken, n_tries, n_not_back, n_give_up;
    int check;
} St;

static bool verbose;

static void say(St *s, int check, const char *fmt, ...)
{
    va_list ap;

    if (check != CHECK_NONE) {
        s->check = check;
    }
    if (!verbose) {
        return;
    }
    printf("     | ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
}

static bool notch(St *s) { return s->screen->notch > 0; }

static bool covers(St *s) { return omacvm_fp_rect_equal(s->frame, s->screen->f); }

static bool same_display(St *s)
{
    return omacvm_fp_rect_equal(s->screen->f, s->accepted_display) && s->screen_same_size;
}

static bool claims(St *s)
{
    return omacvm_fp_claims(s->inside, s->armed, s->rejected, s->lost, false, notch(s)) &&
           !(OMACVM_FP_CLAIMS_WAIT_FOR_RESUME && s->released);
}

static void release_state(St *s)
{
    s->tracking = false;
    s->retake_pending = false;
}

static void come_back(St *s);
static void retake(St *s, const char *why);

static bool engage(St *s)
{
    if (!(s->armed && s->accepted && s->inside && !s->lost && !s->released && !s->rejected &&
          s->full && s->on_space && covers(s) && notch(s))) {
        return false;
    }
    s->tracking = true;
    if (s->retake_pending) {
        s->retake_pending = false;
        s->n_taken++;
        say(s, CHECK_NONE, "strip taken again after a display change (try %d of %d)",
            s->retake_tries, OMACVM_FP_RETAKE_TRIES);
    }
    s->displaced = s->display_changed = false;
    if (!s->covered_logged) {
        s->covered_logged = true;
        s->n_covered++;
        say(s, CHECK_COVERED, "strip covered: display %.0fx%.0f", s->screen->f.w, s->screen->f.h);
    }
    return true;
}

static void verify(St *s, bool definitive)
{
    OmacVMFPVerdict v;

    if (!s->armed || s->rejected || (s->accepted && !definitive)) {
        return;
    }
    v = omacvm_fp_verdict(claims(s), s->full, covers(s), notch(s), definitive);
    if (v == OMACVM_FP_PENDING || (v == OMACVM_FP_ACCEPTED && s->accepted)) {
        return;
    }
    if (v == OMACVM_FP_ACCEPTED) {
        s->accepted = true;
        s->accepted_display = s->screen->f;
        return;
    }
    s->accepted = false;
    s->rejected = true;
    release_state(s);
    say(s, CHECK_NONE, "AppKit kept its own layout: normal full screen for this one");
}

static void frame_changed(St *s)
{
    if (!s->armed || !s->inside || !s->full) {
        return;
    }
    if (!s->accepted) {
        verify(s, false);
    } else if (s->entered && !s->lost && !s->released) {
        switch (omacvm_fp_frame_kind(covers(s), omacvm_fp_inside(s->frame, s->screen->f),
                                     s->screen_live, same_display(s), s->displaced)) {
        case OMACVM_FP_FRAME_COVERS:
            s->accepted_display = s->screen->f;
            s->displaced = false;
            break;
        case OMACVM_FP_FRAME_DISPLACED:
            if (!s->displaced) {
                s->displaced = s->display_changed = true;
                release_state(s);
                s->covered_logged = false;
                s->n_displaced++;
                say(s, CHECK_NONE, "display change: frame (%.0f %.0f %.0fx%.0f) on display %.0fx%.0f, %s",
                    s->frame.x, s->frame.y, s->frame.w, s->frame.h, s->screen->f.w, s->screen->f.h,
                    s->screen_live ? "laid out for another display" : "that display is off or asleep");
            }
            return;
        case OMACVM_FP_FRAME_LOST:
            s->lost = true;
            s->lost_at = s->now;
            release_state(s);
            s->n_lost++;
            say(s, CHECK_LOST, "strip lost: frame (%.0f %.0f %.0fx%.0f) on display %.0fx%.0f",
                s->frame.x, s->frame.y, s->frame.w, s->frame.h, s->screen->f.w, s->screen->f.h);
            return;
        case OMACVM_FP_FRAME_WAIT:
            break;
        }
    }
    come_back(s);
}

/* window_screen: NSWindowDidChangeScreen (else the screen parameters changed). */
static void screen_changed(St *s, bool window_screen)
{
    s->due = true;    /* QEMU's handlers ask the display update for one */
    if (s->lost && omacvm_fp_lost_to_display_change(true, s->now - s->lost_at,
                                                    window_screen || !s->screen_live ||
                                                    !same_display(s))) {
        s->lost = false;
        s->displaced = s->display_changed = true;
        s->covered_logged = false;
        s->n_moved++;
        say(s, CHECK_NONE, "display change: the strip lost %.1f s ago went with it", s->now - s->lost_at);
    }
    if (omacvm_fp_screen_releases(s->armed && s->inside, s->full, notch(s), s->released)) {
        s->released = true;
        s->display_changed = true;
        release_state(s);
        say(s, CHECK_NORMAL, "the full screen is on a display without a camera housing: normal full screen there");
    } else if (omacvm_fp_screen_resumes(s->released, s->full, notch(s))) {
        s->released = false;
        s->covered_logged = false;
        come_back(s);
    } else if (s->full) {
        come_back(s);
    }
}

/* comeBack + checkReturn (WindowServer as in_place says; the 2 s pass at once). */
static void come_back(St *s)
{
    if (!s->armed || !s->inside || s->rejected || s->lost || s->released || !s->full) {
        return;
    }
    if (!s->accepted) {
        verify(s, false);
    }
    if (omacvm_fp_return_ready(covers(s), s->on_space, s->key, s->in_place ? 1 : 0,
                               OMACVM_FP_RETURN_CHECKS)) {
        engage(s);
        return;
    }
    if (s->display_changed && !s->retake_pending && s->in_place && s->on_space && !covers(s)) {
        retake(s, "back on its Space");
    }
}

/*
 * AppKit lays the full-screen tile out for its Space's display: it asks
 * the reservation (appkit_yes: its own answer) and keeps the band unless
 * FullPanel's answer is no. at: the frame when AppKit's coordinates are
 * stale (else the Space's display, less the band).
 */
static void layout(St *s, bool appkit_yes, const OmacVMFPRect *at)
{
    bool keeps = appkit_yes && !claims(s);
    OmacVMFPRect f = at ? *at : s->space->f;

    if (!at && keeps) {
        f.h -= s->space->band;
    }
    s->frame = f;
    if (verbose) {
        printf("     | AppKit: %.0f %.0f %.0fx%.0f, NSScreen %s (AppKit %s, answer %s)\n",
               f.x, f.y, f.w, f.h, s->screen->name, appkit_yes ? "yes" : "no", keeps ? "yes" : "no");
    }
    frame_changed(s);
}

static void give_up(St *s, const char *reason)
{
    if (s->retake_given_up) {
        return;
    }
    s->retake_given_up = true;
    s->n_give_up++;
    say(s, CHECK_NOT_BACK, "strip not back after a display change (%s): normal full screen until the next one",
        reason);
}

static void retake_expired(St *s)
{
    bool last;

    if (!s->retake_pending) {
        return;
    }
    s->retake_pending = false;
    if (covers(s)) {
        s->n_taken++;
        s->displaced = s->display_changed = false;
        say(s, CHECK_NONE, "strip taken again (try %d of %d); covered once the window is in front",
            s->retake_tries, OMACVM_FP_RETAKE_TRIES);
        return;
    }
    last = omacvm_fp_retake_final(s->retake_tries);
    s->retake_given_up = last;
    s->n_not_back++;
    say(s, CHECK_NOT_BACK, "strip not back after a display change (AppKit kept the band, try %d of %d): normal full screen %s",
        s->retake_tries, OMACVM_FP_RETAKE_TRIES, last ? "until the next one" : "for now");
}

/* -retakeFacts and -retake: */
static void retake(St *s, const char *why)
{
    OmacVMFPRetakeFacts f = {
        .inside = s->inside && s->full,
        .armed = s->armed,
        .entered = s->entered,
        .rejected = s->rejected,
        .lost = s->lost,
        .display_changed = s->display_changed,
        .given_up = s->retake_given_up,
        .tries = s->retake_tries,
        .tried_this_settle = s->retake_tries > 0 && s->retake_settle == s->settles,
        .pending = s->retake_pending,
    };
    const char *reason = "";
    OmacVMFPRetake r;

    if (f.inside && f.armed && f.entered && f.display_changed) {
        f.notch = notch(s);
        f.covers = covers(s);
        f.band_kept = omacvm_fp_band_kept(s->frame, s->screen->f, s->screen->notch);
        f.display_live = s->screen_live;
        f.same_size = s->screen_same_size;
        f.on_space = s->on_space;
        f.visible = s->visible;
        f.in_place = s->in_place;
        f.locked = s->locked;
        f.moving = s->due || s->moving;
        f.menu_bar_in_the_way = s->menu_bar_shown;
        f.parts = true;
        f.reshape = s->reshape;
        f.appkit_band = true;
    }
    r = omacvm_fp_retake(f, &reason);
    if (r == OMACVM_FP_RETAKE_NOW) {
        f.appkit_band = s->space->notch > 0;
        r = omacvm_fp_retake(f, &reason);
    }
    if (verbose && r != OMACVM_FP_RETAKE_NOW) {
        printf("     | (%s: %s: %s)\n", why, r == OMACVM_FP_RETAKE_WAIT ? "wait" :
               r == OMACVM_FP_RETAKE_NO ? "no" : "give up", reason);
    }
    if (r == OMACVM_FP_RETAKE_GIVE_UP) {
        give_up(s, reason);
        return;
    }
    if (r != OMACVM_FP_RETAKE_NOW) {
        return;
    }
    s->retake_tries++;
    s->retake_settle = s->settles;
    s->retake_pending = true;
    s->n_tries++;
    say(s, CHECK_NONE, "below the notch after a display change (%s): AppKit lays the window out again (try %d of %d)",
        why, s->retake_tries, OMACVM_FP_RETAKE_TRIES);
    if (s->reshape_works) {
        layout(s, s->space->notch > 0, NULL);
    }
    come_back(s);
    retake_expired(s);
}

/* omacvm_ds_fired's RUN, the update done, nothing due (retry <= 0). */
static void settle(St *s)
{
    if (s->locked) {
        return;
    }
    s->due = false;
    s->settles++;
    if (verbose) {
        printf("     | displays settled\n");
    }
    retake(s, "the displays settled");
}

/* The head delegate, the displays' windows in full screen. */
static void heads_done(St *s)
{
    s->moving = false;
    retake(s, "the displays' windows are in place");
}

static void start(St *s)
{
    memset(s, 0, sizeof(*s));
    s->screen = s->space = &BUILTIN;
    s->frame = (OmacVMFPRect){ 224, 102, 1280, 752 };
    s->key = s->on_space = s->visible = s->in_place = true;
    s->screen_live = s->screen_same_size = true;
    s->reshape = s->reshape_works = true;
    s->now = 1;
    /* willEnterFullScreen */
    s->inside = true;
    if (omacvm_fp_fallback(notch(s), s->menu_bar_shown, notch(s), true) != OMACVM_FP_OK) {
        return;
    }
    s->armed = true;
    s->full = true;
    layout(s, true, NULL);
    /* didEnterFullScreen */
    verify(s, true);
    if (s->armed && s->accepted) {
        s->entered = true;
        engage(s);
    }
}

/* The built-in leaves the display set: AppKit lays the window out for the LG first. */
static void builtin_leaves(St *s, bool cg_knows)
{
    const OmacVMFPRect stale = { 0, -323, 2560, 1440 };   /* 1117 - 1440 */

    s->space = &LG;
    s->screen_live = !cg_knows;
    layout(s, false, &stale);
    s->screen = &LG;
    s->screen_live = true;
    screen_changed(s, true);
    layout(s, false, NULL);
}

/* The built-in comes back. order 0: NSWindowDidChangeScreen first; 1: AppKit's band layout first; 2: both stale. */
static void builtin_back(St *s, int order)
{
    s->space = &BUILTIN;
    layout(s, false, NULL);                /* "area 1728x1117 on a 1920x1080 display" */
    if (order == 0) {
        s->screen = &BUILTIN;
        screen_changed(s, true);
        layout(s, true, NULL);
    } else if (order == 1) {
        s->screen = &BUILTIN;
        layout(s, true, NULL);
        screen_changed(s, true);
    } else {
        layout(s, true, NULL);             /* asked while NSScreen still named the stand-in */
        s->screen = &BUILTIN;
        screen_changed(s, true);
    }
}

static int failures;

static void row(St *s, const char *name, bool ok, const char *fmt, ...)
{
    va_list ap;

    if (ok) {
        printf("ok   %s\n", name);
        return;
    }
    failures++;
    printf("FAIL %s: ", name);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf(" (frame %.0f %.0f %.0fx%.0f on %s, lost %d released %d tries %d)\n", s->frame.x, s->frame.y,
           s->frame.w, s->frame.h, s->screen->name, s->lost, s->released, s->retake_tries);
}

/* The strip is the window's again on the built-in, and omacvm check says so. */
static bool back(St *s)
{
    return s->screen == &BUILTIN && covers(s) && s->tracking && s->check == CHECK_COVERED && !s->lost;
}

/* The user's sequence (qemu.log): the LG gone with the built-in, a stand-in, locked, the built-in back. */
static void users_log(St *s, int order)
{
    start(s);
    builtin_leaves(s, false);
    s->space = &STANDIN;
    layout(s, false, NULL);               /* "area 1920x1080 on a 2560x1440 display" */
    s->screen = &STANDIN;
    screen_changed(s, true);
    s->locked = true;                     /* "no window changes while locked or asleep" */
    builtin_back(s, order);
    s->locked = false;                    /* "windows follow the displays again" */
    settle(s);
}

static void rows(void)
{
    St s;
    static const char *orders[] = { "the screen change first", "AppKit's band layout first",
                                    "both stale" };

    for (int o = 0; o < 3; o++) {
        char name[160];
        snprintf(name, sizeof(name), "the user's log (%s): the strip back on the built-in", orders[o]);
        users_log(&s, o);
        row(&s, name, back(&s) && s.n_lost == 0 && s.n_displaced == 1 &&
            s.n_tries == (o == 2 ? 1 : 0) && s.n_taken == (o == 2 ? 1 : 0),
            "covered %d, check %d, lost %d, displaced %d, tries %d, taken %d", covers(&s), s.check,
            s.n_lost, s.n_displaced, s.n_tries, s.n_taken);
    }

    /* The same with CoreGraphics knowing the built-in is off before AppKit's layout. */
    start(&s);
    builtin_leaves(&s, true);
    s.locked = true;
    builtin_back(&s, 2);
    s.locked = false;
    settle(&s);
    row(&s, "the user's log, CoreGraphics first: the strip back", back(&s) && s.n_lost == 0,
        "check %d lost %d", s.check, s.n_lost);

    /* Lid shut with the LG on: the Space stays on the LG (no housing there). */
    start(&s);
    builtin_leaves(&s, true);
    settle(&s);
    row(&s, "lid shut: normal full screen on the LG, nothing tried",
        s.released && !s.lost && s.n_tries == 0 && s.check == CHECK_NORMAL && s.n_lost == 0,
        "check %d tries %d", s.check, s.n_tries);
    /* ... and opened: the Space back on the built-in. */
    builtin_back(&s, 2);
    settle(&s);
    row(&s, "lid opened again: the strip back", back(&s) && s.n_tries == 1, "check %d tries %d", s.check,
        s.n_tries);

    /* Displays wake, the LG first: AppKit lays the window out for it while the built-in sleeps. */
    start(&s);
    s.locked = true;
    s.space = &LG;
    s.screen_live = false;
    layout(&s, false, &(OmacVMFPRect){ 0, -323, 2560, 1440 });
    s.screen_live = true;
    s.space = &BUILTIN;
    layout(&s, true, NULL);
    s.locked = false;
    settle(&s);
    row(&s, "displays wake with the LG first: the strip back", back(&s) && s.n_lost == 0,
        "check %d lost %d", s.check, s.n_lost);

    /* A smaller external display the only one, NSScreen still the built-in's (frame inside it). */
    start(&s);
    s.space = &SMALL;
    s.screen_live = false;
    layout(&s, false, &(OmacVMFPRect){ 0, 317, 1280, 800 });
    s.screen = &SMALL;
    s.screen_live = true;
    screen_changed(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    row(&s, "a smaller external display while NSScreen is stale: a display change, the strip back",
        back(&s) && s.n_lost == 0 && s.n_displaced == 1, "check %d lost %d displaced %d", s.check,
        s.n_lost, s.n_displaced);

    /* A2: taken as lost (inside a display that looked unchanged), the display change a moment later. */
    start(&s);
    s.now = 10;
    s.frame = (OmacVMFPRect){ 0, 0, 1728, 1084 };
    frame_changed(&s);
    s.now = 11;
    s.space = &LG;
    s.screen = &LG;
    screen_changed(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    row(&s, "lost, then the display changed within 3 s: a display change, the strip back",
        back(&s) && s.n_lost == 1 && s.n_moved == 1, "check %d lost %d moved %d", s.check, s.n_lost,
        s.n_moved);

    /* Not within 3 s: stays lost (Split View). */
    start(&s);
    s.now = 10;
    s.frame = (OmacVMFPRect){ 0, 0, 1728, 1084 };
    frame_changed(&s);
    s.now = 14.5;
    s.space = &LG;
    s.screen = &LG;
    screen_changed(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    row(&s, "lost, a display change 4.5 s later: stays lost, nothing tried",
        s.lost && s.n_moved == 0 && s.n_tries == 0 && !covers(&s), "lost %d moved %d tries %d", s.lost,
        s.n_moved, s.n_tries);

    /* Split View: a tile inside the display; a later display change and settle change nothing. */
    start(&s);
    s.now = 10;
    s.frame = (OmacVMFPRect){ 0, 0, 864, 1084 };
    frame_changed(&s);
    s.now = 20;
    screen_changed(&s, false);
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    settle(&s);
    row(&s, "Split View stays lost after a later display change (never taken again)",
        s.lost && s.n_tries == 0 && s.n_moved == 0 && !covers(&s), "lost %d tries %d moved %d", s.lost,
        s.n_tries, s.n_moved);

    /* A screen-parameters change (the Dock) right after a Split View: stays lost. */
    start(&s);
    s.now = 10;
    s.frame = (OmacVMFPRect){ 864, 0, 864, 1084 };
    frame_changed(&s);
    s.now = 10.5;
    screen_changed(&s, false);
    settle(&s);
    row(&s, "Split View, the screen parameters change 0.5 s later (same display): stays lost",
        s.lost && s.n_moved == 0 && s.n_tries == 0, "lost %d moved %d", s.lost, s.n_moved);

    /* "Always show the menu bar" turned on without Keep the Dock away: no try, the line says why. */
    start(&s);
    s.menu_bar_shown = true;
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    settle(&s);
    row(&s, "menu bar always shown: nothing tried, said once",
        s.n_tries == 0 && s.n_give_up == 1 && s.check == CHECK_NOT_BACK, "tries %d give up %d check %d",
        s.n_tries, s.n_give_up, s.check);

    /* AppKit's Space still on a display without a housing: wait. */
    start(&s);
    builtin_leaves(&s, true);
    s.screen = &BUILTIN;
    s.frame = (OmacVMFPRect){ 0, 0, 1728, 1084 };
    screen_changed(&s, true);
    settle(&s);
    row(&s, "AppKit has the Space on a display without a housing: nothing tried", s.n_tries == 0 &&
        s.n_give_up == 0, "tries %d give up %d", s.n_tries, s.n_give_up);
    s.space = &BUILTIN;
    settle(&s);
    row(&s, "... the Space on the built-in at the next settle: the strip back", back(&s) && s.n_tries == 1,
        "check %d tries %d", s.check, s.n_tries);

    /* An external display's window (no housing): never. */
    start(&s);
    builtin_leaves(&s, true);
    settle(&s);
    settle(&s);
    row(&s, "a full screen on an external display: nothing tried", s.n_tries == 0 && s.n_give_up == 0,
        "tries %d give up %d", s.n_tries, s.n_give_up);

    /* Locked, then the displays' windows still moving: wait; the head delegate's turn takes it. */
    start(&s);
    builtin_leaves(&s, true);
    s.locked = true;
    builtin_back(&s, 2);
    settle(&s);
    row(&s, "locked: nothing tried", s.n_tries == 0 && !covers(&s), "tries %d", s.n_tries);
    s.locked = false;
    s.moving = true;
    settle(&s);
    row(&s, "a display's window still moves: nothing tried", s.n_tries == 0, "tries %d", s.n_tries);
    heads_done(&s);
    row(&s, "the displays' windows in place: the strip back", back(&s) && s.n_tries == 1,
        "check %d tries %d", s.check, s.n_tries);

    /* Another Space while the displays settled: back on its Space takes it. */
    start(&s);
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    s.on_space = false;
    settle(&s);
    row(&s, "on another Space while the displays settled: nothing tried", s.n_tries == 0,
        "tries %d", s.n_tries);
    s.on_space = true;
    come_back(&s);
    row(&s, "back on its Space: the strip back", back(&s) && s.n_tries == 1, "check %d tries %d",
        s.check, s.n_tries);

    /* AppKit keeps the band through every try: 3 tries, one per settle, then said for good. */
    start(&s);
    s.reshape_works = false;
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    come_back(&s);
    row(&s, "one try per settle (a return in the same settle tries nothing)", s.n_tries == 1,
        "tries %d", s.n_tries);
    settle(&s);
    settle(&s);
    settle(&s);
    settle(&s);
    row(&s, "AppKit keeps the band: 3 tries, then 'strip not back' for good",
        s.n_tries == 3 && s.n_not_back == 3 && s.retake_given_up && s.check == CHECK_NOT_BACK,
        "tries %d not back %d given up %d", s.n_tries, s.n_not_back, s.retake_given_up);

    /* AppKit's tile relayout not there (another macOS): said once, nothing tried. */
    start(&s);
    s.reshape = false;
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    settle(&s);
    row(&s, "selector missing: nothing tried, said once", s.n_tries == 0 && s.n_give_up == 1 &&
        s.check == CHECK_NOT_BACK, "tries %d give up %d", s.n_tries, s.n_give_up);

    /* A larger display mode: CoreGraphics has it first, AppKit's frame is not inside the old NSScreen. */
    start(&s);
    s.screen_same_size = false;
    s.space = &BUILTIN_BIG;
    layout(&s, true, NULL);
    s.screen = &BUILTIN_BIG;
    s.screen_same_size = true;
    screen_changed(&s, false);
    layout(&s, true, NULL);
    settle(&s);
    row(&s, "a larger display mode: no display change, no strip lost, covered",
        covers(&s) && s.tracking && s.n_displaced == 0 && s.n_lost == 0 && s.n_tries == 0,
        "displaced %d lost %d tries %d", s.n_displaced, s.n_lost, s.n_tries);

    /* A smaller display mode (inside the old frame). */
    start(&s);
    s.screen_same_size = false;
    s.space = &BUILTIN_SMALL;
    layout(&s, true, NULL);
    s.screen = &BUILTIN_SMALL;
    s.screen_same_size = true;
    screen_changed(&s, false);
    layout(&s, true, NULL);
    row(&s, "a smaller display mode: no strip lost, covered",
        covers(&s) && s.tracking && s.n_displaced == 0 && s.n_lost == 0,
        "displaced %d lost %d", s.n_displaced, s.n_lost);
}

#ifndef OMACVM_RETAKE_STUB
static int checks;

#define CHECK(c) do { checks++; if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

/* The rules on their own. */
static void rules(void)
{
    OmacVMFPRect d = BUILTIN.f;
    OmacVMFPRetakeFacts now = {
        .inside = true, .armed = true, .entered = true, .display_changed = true, .notch = true,
        .band_kept = true, .display_live = true, .same_size = true, .on_space = true,
        .visible = true, .in_place = true, .parts = true, .reshape = true, .appkit_band = true,
    };
    OmacVMFPRetakeFacts f;
    const char *why = NULL;

    CHECK(omacvm_fp_inside((OmacVMFPRect){ 0, 0, 1728, 1084 }, d));
    CHECK(!omacvm_fp_inside((OmacVMFPRect){ 0, -323, 2560, 1440 }, d));
    CHECK(omacvm_fp_inside((OmacVMFPRect){ 0, 317, 1280, 800 }, d));

    CHECK(omacvm_fp_frame_kind(true, true, true, true, false) == OMACVM_FP_FRAME_COVERS);
    CHECK(omacvm_fp_frame_kind(true, false, false, false, true) == OMACVM_FP_FRAME_COVERS);
    CHECK(omacvm_fp_frame_kind(false, false, true, true, false) == OMACVM_FP_FRAME_DISPLACED);
    CHECK(omacvm_fp_frame_kind(false, true, false, true, false) == OMACVM_FP_FRAME_DISPLACED);
    CHECK(omacvm_fp_frame_kind(false, false, false, false, false) == OMACVM_FP_FRAME_DISPLACED);
    CHECK(omacvm_fp_frame_kind(false, false, true, false, false) == OMACVM_FP_FRAME_WAIT);
    CHECK(omacvm_fp_frame_kind(false, true, true, false, false) == OMACVM_FP_FRAME_WAIT);
    CHECK(omacvm_fp_frame_kind(false, true, true, true, false) == OMACVM_FP_FRAME_LOST);
    CHECK(omacvm_fp_frame_kind(false, true, true, true, true) == OMACVM_FP_FRAME_WAIT);

    CHECK(omacvm_fp_lost_to_display_change(true, 0, true));
    CHECK(omacvm_fp_lost_to_display_change(true, OMACVM_DS_MAX_WAIT_S, true));
    CHECK(!omacvm_fp_lost_to_display_change(true, OMACVM_DS_MAX_WAIT_S + 0.1, true));
    CHECK(!omacvm_fp_lost_to_display_change(true, 1, false));
    CHECK(!omacvm_fp_lost_to_display_change(false, 1, true));
    CHECK(!omacvm_fp_lost_to_display_change(true, -1, true));

    CHECK(omacvm_fp_claims(true, true, false, false, false, true));
    CHECK(!omacvm_fp_claims(true, true, true, false, false, true));
    CHECK(!omacvm_fp_claims(true, true, false, true, false, true));
    CHECK(!omacvm_fp_claims(true, true, false, false, true, true));
    CHECK(!omacvm_fp_claims(true, true, false, false, false, false));
    CHECK(!omacvm_fp_claims(false, true, false, false, false, true));
    CHECK(!omacvm_fp_claims(true, false, false, false, false, true));

    /* The band below the notch on every notched MacBook size; never a tile, never the whole display. */
    CHECK(omacvm_fp_band_kept((OmacVMFPRect){ 0, 0, 1728, 1084 }, d, 32));
    CHECK(omacvm_fp_band_kept((OmacVMFPRect){ 0, 0, 1470, 919 }, (OmacVMFPRect){ 0, 0, 1470, 956 }, 32));
    CHECK(omacvm_fp_band_kept((OmacVMFPRect){ 0, 0, 1800, 1131 }, (OmacVMFPRect){ 0, 0, 1800, 1169 }, 38));
    CHECK(!omacvm_fp_band_kept(d, d, 32));
    CHECK(!omacvm_fp_band_kept((OmacVMFPRect){ 0, 0, 864, 1084 }, d, 32));
    CHECK(!omacvm_fp_band_kept((OmacVMFPRect){ 864, 0, 864, 1084 }, d, 32));
    CHECK(!omacvm_fp_band_kept((OmacVMFPRect){ 0, 0, 1728, 1000 }, d, 32));
    CHECK(!omacvm_fp_band_kept((OmacVMFPRect){ 0, 33, 1728, 1084 }, d, 32));
    CHECK(!omacvm_fp_band_kept((OmacVMFPRect){ 0, -323, 2560, 1440 }, d, 32));
    CHECK(!omacvm_fp_band_kept((OmacVMFPRect){ 0, 0, 1728, 1084 }, d, 0) || 33 <= OMACVM_FP_BAND_SLACK);

    CHECK(omacvm_fp_retake(now, &why) == OMACVM_FP_RETAKE_NOW);
#define RETAKE(field, value, want) do { f = now; f.field = value; \
        CHECK(omacvm_fp_retake(f, &why) == want && why && why[0]); } while (0)
    RETAKE(inside, false, OMACVM_FP_RETAKE_NO);
    RETAKE(armed, false, OMACVM_FP_RETAKE_NO);
    RETAKE(entered, false, OMACVM_FP_RETAKE_NO);
    RETAKE(rejected, true, OMACVM_FP_RETAKE_NO);
    RETAKE(lost, true, OMACVM_FP_RETAKE_NO);
    RETAKE(display_changed, false, OMACVM_FP_RETAKE_NO);
    RETAKE(given_up, true, OMACVM_FP_RETAKE_NO);
    RETAKE(notch, false, OMACVM_FP_RETAKE_NO);
    RETAKE(covers, true, OMACVM_FP_RETAKE_NO);
    RETAKE(band_kept, false, OMACVM_FP_RETAKE_NO);
    RETAKE(locked, true, OMACVM_FP_RETAKE_WAIT);
    RETAKE(display_live, false, OMACVM_FP_RETAKE_WAIT);
    RETAKE(same_size, false, OMACVM_FP_RETAKE_WAIT);
    RETAKE(moving, true, OMACVM_FP_RETAKE_WAIT);
    RETAKE(on_space, false, OMACVM_FP_RETAKE_WAIT);
    RETAKE(visible, false, OMACVM_FP_RETAKE_WAIT);
    RETAKE(in_place, false, OMACVM_FP_RETAKE_WAIT);
    RETAKE(pending, true, OMACVM_FP_RETAKE_WAIT);
    RETAKE(appkit_band, false, OMACVM_FP_RETAKE_WAIT);
    RETAKE(tried_this_settle, true, OMACVM_FP_RETAKE_WAIT);
    RETAKE(menu_bar_in_the_way, true, OMACVM_FP_RETAKE_GIVE_UP);
    RETAKE(parts, false, OMACVM_FP_RETAKE_GIVE_UP);
    RETAKE(reshape, false, OMACVM_FP_RETAKE_GIVE_UP);
    RETAKE(tries, OMACVM_FP_RETAKE_TRIES, OMACVM_FP_RETAKE_GIVE_UP);
    RETAKE(tries, OMACVM_FP_RETAKE_TRIES - 1, OMACVM_FP_RETAKE_NOW);
    /* Split View wins over everything (never taken again), locked over a missing part. */
    f = now;
    f.lost = true;
    f.menu_bar_in_the_way = true;
    f.reshape = false;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_NO);
    f = now;
    f.locked = true;
    f.reshape = false;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_WAIT);
    f = now;
    f.reshape = false;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_GIVE_UP && !strcmp(why, "selector missing"));
    f = now;
    f.menu_bar_in_the_way = true;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_GIVE_UP && !strcmp(why, "menu bar always shown"));
    f = now;
    f.tries = OMACVM_FP_RETAKE_TRIES;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_GIVE_UP && !strcmp(why, "AppKit kept the band"));
    CHECK(omacvm_fp_retake(now, NULL) == OMACVM_FP_RETAKE_NOW);
    CHECK(!omacvm_fp_retake_final(OMACVM_FP_RETAKE_TRIES - 1) && omacvm_fp_retake_final(OMACVM_FP_RETAKE_TRIES));
    printf("ok   %d rule checks\n", checks);
}
#endif

int main(int argc, char **argv)
{
    verbose = argc > 1 && !strcmp(argv[1], "-v");
#ifndef OMACVM_RETAKE_STUB
    rules();
#endif
    rows();
    if (failures) {
        printf("test-fullpanel-retake: %d failed\n", failures);
        return 1;
    }
    printf("test-fullpanel-retake: all passed\n");
    return 0;
}
