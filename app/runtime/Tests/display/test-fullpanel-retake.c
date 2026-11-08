/*
 * FullPanel after a display change (ui/omacvm-fullpanel-retake.h,
 * omacvm-cocoa-fullpanel-retake.patch): the rules, and the user's qemu.log
 * (M4 Max, OmacVM 3.2.9, 2026-10-28: the built-in XDR 1728x1117 with an LG
 * UltraFine 5K above it; unplug, replug, sleep; the strip beside the notch
 * stayed away until full screen was entered again) replayed through a C copy
 * of the window's FullPanel state (OmacVMFullPanelState in ui/cocoa.m,
 * method by method: willEnterFullScreen, verify:, frameChanged:,
 * screenChanged:, comeBack/checkReturn, engage, retake:, retakeAsk:,
 * retakeAgain, retakeNewChange, retakeExpired, retakeGiveUp:, and the
 * late arm of omacvm-cocoa-fullpanel-late-arm.patch: lateFits, a late
 * willEnterFullScreen, #716) that decides with the headers' rules. AppKit is modelled from the log:
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
#include "omacvm-fullpanel-late.h"
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
/* The same panel with a taller band than the housing's (+ OMACVM_FP_BAND_SLACK): a macOS that keeps more. */
static const Disp BUILTIN_TALL = { "built-in, a 44 pt band", { 0, 0, 1728, 1117 }, 32, 44 };
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
    bool late;                /* armed late (omacvm-cocoa-fullpanel-late-arm.patch) */
    bool panel_given;         /* OMACVM_FULLPANEL_PANEL */
    double panel_w, panel_h;
    bool displaced, display_changed, tracking, covered_logged;
    bool retake_pending, retake_given_up, lost_tile;
    bool reask_due;           /* -retakeAgain is queued */
    double lost_at;
    int retake_tries, retake_reasks;
    bool retake_tried;        /* a try in this full screen: retake_settle is its settle */
    unsigned retake_settle;
    OmacVMFPRect accepted_display;
    /* Lines. */
    int n_covered, n_lost, n_displaced, n_moved, n_taken, n_tries, n_not_back, n_give_up, n_reasks;
    int n_resumed, n_stale;
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

/* -lateFits: a late full screen on a display of this start's panel size. */
static bool fits(St *s)
{
#ifdef OMACVM_RETAKE_STUB
    (void)s;
    return true;
#else
    return omacvm_fp_late_fits(s->late, s->panel_given, s->panel_w, s->panel_h, s->screen->f.w,
                               s->screen->f.h);
#endif
}

static bool claims(St *s)
{
    return omacvm_fp_claims(s->inside, s->armed, s->rejected, s->lost, false, notch(s)) &&
           !(OMACVM_FP_CLAIMS_WAIT_FOR_RESUME && s->released) && fits(s);
}

static void release_state(St *s)
{
    s->tracking = false;
    s->retake_pending = false;
    s->reask_due = false;
}

/* -retakeNewChange: a display change took the strip, its own tries (the settle of the last try stays). */
static void new_change(St *s)
{
    s->display_changed = true;
    s->retake_tries = s->retake_reasks = 0;
    s->retake_given_up = false;
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
        s->late = false;
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
        bool tile = omacvm_fp_tile(s->frame, s->screen->f);
        bool within = omacvm_fp_inside(s->frame, s->screen->f);

        switch (omacvm_fp_frame_kind(covers(s), within, s->screen_live, same_display(s),
                                     s->display_changed, tile)) {
        case OMACVM_FP_FRAME_COVERS:
            s->accepted_display = s->screen->f;
            s->displaced = false;
            break;
        case OMACVM_FP_FRAME_DISPLACED:
            if (!s->displaced) {
                s->displaced = true;
                new_change(s);
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
            s->lost_tile = tile;
            release_state(s);
            s->n_lost++;
            say(s, CHECK_LOST, "strip lost: frame (%.0f %.0f %.0fx%.0f) on display %.0fx%.0f",
                s->frame.x, s->frame.y, s->frame.w, s->frame.h, s->screen->f.w, s->screen->f.h);
            return;
        case OMACVM_FP_FRAME_WAIT:
            if (within && s->screen_live) {
                s->displaced = false;
            }
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
                                                    !same_display(s), s->lost_tile)) {
        s->lost = false;
        s->displaced = true;
        new_change(s);
        s->covered_logged = false;
        s->n_moved++;
        say(s, CHECK_NONE, "display change: the strip lost %.1f s ago went with it", s->now - s->lost_at);
    }
    if (omacvm_fp_screen_releases(s->armed && s->inside, s->full, notch(s), s->released)) {
        s->released = true;
        new_change(s);
        release_state(s);
        say(s, CHECK_NORMAL, "the full screen is on a display without a camera housing: normal full screen there");
    } else if (s->late && !s->rejected && omacvm_fp_screen_resumes(s->released, s->full, notch(s)) &&
               !fits(s)) {
        s->rejected = true;
        s->released = s->displaced = false;
        s->n_stale++;
        say(s, CHECK_NORMAL, "the MacBook's display is %.0fx%.0f now, this start's notch was measured at %.0fx%.0f: normal full screen",
            s->screen->f.w, s->screen->f.h, s->panel_w, s->panel_h);
    } else if (omacvm_fp_screen_resumes(s->released, s->full, notch(s))) {
        s->released = s->displaced = false;
        s->covered_logged = false;
        s->n_resumed++;
        say(s, CHECK_NONE, "display change: the full screen is on a display with a camera housing again");
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

/* -retakeFacts and -retakeAsk: */
static void ask(St *s, const char *why)
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
        .tried_this_settle = s->retake_tried && s->retake_settle == s->settles,
        .pending = s->retake_pending,
    };
    const char *reason = "";
    OmacVMFPRetake r;

    if (f.inside && f.armed && f.entered && f.display_changed) {
        f.notch = notch(s);
        f.covers = covers(s);
        f.band_kept = omacvm_fp_band_kept(s->frame, s->screen->f, s->screen->notch);
        f.band_tall = omacvm_fp_band_tall(s->frame, s->screen->f, s->screen->notch);
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
    if (omacvm_fp_retake_reask(f, r, s->retake_reasks)) {
        s->reask_due = true;
        return;
    }
    if (r != OMACVM_FP_RETAKE_NOW) {
        return;
    }
    s->retake_tries++;
    s->retake_tried = true;
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

/* -retake: a trigger asks (a queued ask again is dropped, its count starts again). */
static void retake(St *s, const char *why)
{
    s->reask_due = false;
    s->retake_reasks = 0;
    ask(s, why);
}

/* OMACVM_FP_RETAKE_REASK_S later, no trigger in between: -retakeAgain. */
static void later(St *s)
{
    if (!s->reask_due) {
        return;
    }
    s->reask_due = false;
    s->retake_reasks++;
    s->n_reasks++;
    ask(s, "a moment later");
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

/* The built-in (d) comes back. order 0: NSWindowDidChangeScreen first; 1: AppKit's band layout first; 2: both stale. */
static void builtin_back_to(St *s, int order, const Disp *d)
{
    s->space = d;
    layout(s, false, NULL);                /* "area 1728x1117 on a 1920x1080 display" */
    if (order == 0) {
        s->screen = d;
        screen_changed(s, true);
        layout(s, true, NULL);
    } else if (order == 1) {
        s->screen = d;
        layout(s, true, NULL);
        screen_changed(s, true);
    } else {
        layout(s, true, NULL);             /* asked while NSScreen still named the stand-in */
        s->screen = d;
        screen_changed(s, true);
    }
}

static void builtin_back(St *s, int order)
{
    builtin_back_to(s, order, &BUILTIN);
}

/*
 * AppKit asks the reservation while NSScreen still names the old display,
 * NSWindowDidChangeScreen comes, then the resize (review of #602: after a
 * full screen released on a display without a housing).
 */
static void layout_after_screen_change(St *s, bool appkit_yes, const Disp *now)
{
    bool keeps = appkit_yes && !claims(s);
    OmacVMFPRect f = s->space->f;

    if (keeps) {
        f.h -= s->space->band;
    }
    s->screen = now;
    screen_changed(s, true);
    s->frame = f;
    if (verbose) {
        printf("     | AppKit: %.0f %.0f %.0fx%.0f after the screen change (answer %s)\n", f.x, f.y, f.w,
               f.h, keeps ? "yes" : "no");
    }
    frame_changed(s);
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

#ifndef OMACVM_RETAKE_STUB
/*
 * #716: the VM started with the lid closed (an external display only): the
 * main window's willEnterFullScreen on a display without a housing, then
 * didEnterFullScreen (omacvm-cocoa-fullpanel-late-arm.patch). The panel this
 * start's notch was measured on: the built-in's.
 */
static void start_late(St *s, const Disp *d, bool main_window, bool menu_bar_shown)
{
    OmacVMFPFallback here, with_housing;

    memset(s, 0, sizeof(*s));
    s->screen = s->space = d;
    s->frame = (OmacVMFPRect){ 224, 102, 1280, 752 };
    s->key = s->on_space = s->visible = s->in_place = true;
    s->screen_live = s->screen_same_size = true;
    s->reshape = s->reshape_works = true;
    s->menu_bar_shown = menu_bar_shown;
    s->panel_given = true;
    s->panel_w = BUILTIN.f.w;
    s->panel_h = BUILTIN.f.h;
    s->now = 1;
    /* willEnterFullScreen */
    s->inside = true;
    here = omacvm_fp_fallback(notch(s), s->menu_bar_shown, notch(s), true);
    with_housing = here == OMACVM_FP_NO_NOTCH && main_window ? omacvm_fp_fallback(1, s->menu_bar_shown, true, true)
                                                             : here;
    switch (omacvm_fp_entry(here, with_housing, main_window)) {
    case OMACVM_FP_ENTRY_NORMAL:
        say(s, CHECK_NORMAL, "%s: normal full screen",
            omacvm_fp_fallback_text(omacvm_fp_entry_why(here, with_housing, main_window)));
        s->full = true;
        layout(s, notch(s), NULL);
        return;
    case OMACVM_FP_ENTRY_LATE:
        s->armed = s->late = s->released = true;
        new_change(s);
        say(s, CHECK_NONE, "in full screen on a display without a camera housing: the strip once on the MacBook's display");
        break;
    case OMACVM_FP_ENTRY_ARM:
        s->armed = true;
        break;
    }
    s->full = true;
    layout(s, notch(s), NULL);    /* AppKit's own yes only with a housing */
    /* didEnterFullScreen */
    verify(s, true);
    if (omacvm_fp_entered(s->armed, s->accepted, s->late)) {
        s->entered = true;
        engage(s);
    }
}

/*
 * The lid opened and the external display unplugged: the Space on the
 * built-in (d). order 0: NSWindowDidChangeScreen first, then AppKit's layout
 * (the claim: the whole display); 1: AppKit asks the reservation while
 * NSScreen still names the external display (it keeps the band), then
 * NSWindowDidChangeScreen.
 */
static void lid_opened(St *s, int order, const Disp *d)
{
    s->space = d;
    if (order == 0) {
        s->screen = d;
        screen_changed(s, true);
        layout(s, true, NULL);
    } else {
        layout(s, true, NULL);
        s->screen = d;
        screen_changed(s, true);
    }
}

/* Hours on the external display: settles, sleep and wake, Mission Control, other screen changes. */
static void on_the_external(St *s)
{
    for (int i = 0; i < 3; i++) {
        settle(s);
        s->screen_live = false;                 /* asleep */
        s->locked = true;
        screen_changed(s, false);
        layout(s, false, NULL);
        s->screen_live = true;                  /* awake */
        s->locked = false;
        screen_changed(s, false);
        layout(s, false, NULL);
        settle(s);
        s->on_space = s->key = false;           /* Mission Control, another Space */
        come_back(s);
        s->on_space = s->key = true;
        come_back(s);
        heads_done(s);
        later(s);
    }
}

static bool quiet(St *s)
{
    return s->n_displaced == 0 && s->n_lost == 0 && s->n_moved == 0 && s->n_not_back == 0 &&
           s->n_give_up == 0 && s->n_tries == 0 && s->n_resumed == 0 && s->n_covered == 0 &&
           s->retake_tries == 0 && !s->retake_given_up && s->check == CHECK_NONE;
}

static void late_rows(void)
{
    St s;

    start_late(&s, &LG, true, false);
    row(&s, "late (#716): the lid closed at the start, normal full screen on the LG, armed late, entered",
        s.armed && s.late && s.released && s.entered && !s.accepted && !s.tracking && quiet(&s),
        "armed %d late %d entered %d accepted %d check %d", s.armed, s.late, s.entered, s.accepted, s.check);
    on_the_external(&s);
    row(&s, "late: quiet on the LG through settles, sleep, Mission Control (no line check warns about, no try used)",
        quiet(&s) && s.late && s.released, "displaced %d lost %d not back %d give up %d tries %d check %d",
        s.n_displaced, s.n_lost, s.n_not_back, s.n_give_up, s.retake_tries, s.check);

    /* (a) AppKit lays it out at full height on the built-in: accepted, no try. */
    lid_opened(&s, 0, &BUILTIN);
    row(&s, "late, the lid opened (screen change first): the whole display at once, no try",
        back(&s) && s.n_tries == 0 && s.n_taken == 0 && !s.late && s.n_resumed == 1,
        "check %d tries %d taken %d late %d", s.check, s.n_tries, s.n_taken, s.late);
    /* (c) Split View after that: lost, as any full screen. */
    s.now = 50;
    s.frame = (OmacVMFPRect){ 0, 0, 864, 1084 };
    frame_changed(&s);
    settle(&s);
    row(&s, "late, then Split View: strip lost (a tile), nothing tried",
        s.lost && s.n_lost == 1 && s.check == CHECK_LOST && s.n_tries == 0, "lost %d check %d tries %d", s.lost,
        s.check, s.n_tries);

    /* (b) AppKit keeps the band (asked while NSScreen named the LG): one try at the settle, taken again. */
    start_late(&s, &LG, true, false);
    on_the_external(&s);
    lid_opened(&s, 1, &BUILTIN);
    row(&s, "late, AppKit keeps the band on arrival: nothing yet (the displays move)", !covers(&s) &&
        s.n_tries == 0 && !s.retake_given_up, "covers %d tries %d", covers(&s), s.n_tries);
    settle(&s);
    row(&s, "... the displays settled: one try, 'strip taken again', the strip back",
        back(&s) && s.n_tries == 1 && s.n_taken == 1 && s.retake_tries == 1, "check %d tries %d taken %d",
        s.check, s.n_tries, s.n_taken);
    /* (c) A later display change: its own line and tries. */
    builtin_leaves(&s, false);
    builtin_back(&s, 2);
    settle(&s);
    row(&s, "late, taken, then a display change: 'display change:' and its own tries, the strip back",
        back(&s) && s.n_displaced == 1 && s.retake_tries == 1 && s.n_tries == 2, "check %d displaced %d tries %d",
        s.check, s.n_displaced, s.n_tries);

    /* AppKit keeps the band for good: the 3 tries were all left on arrival. */
    start_late(&s, &LG, true, false);
    on_the_external(&s);
    s.reshape_works = false;
    lid_opened(&s, 1, &BUILTIN);
    for (int i = 0; i < 4; i++) {
        settle(&s);
    }
    row(&s, "late, AppKit keeps the band for good: 3 tries, then 'strip not back'",
        s.n_tries == 3 && s.retake_given_up && s.check == CHECK_NOT_BACK, "tries %d given up %d check %d",
        s.n_tries, s.retake_given_up, s.check);

    /* The lid shut again before the strip came back, then opened: the strip back. */
    start_late(&s, &LG, true, false);
    lid_opened(&s, 1, &BUILTIN);
    s.space = &LG;
    s.screen = &LG;
    screen_changed(&s, true);
    layout(&s, false, NULL);
    lid_opened(&s, 1, &BUILTIN);
    settle(&s);
    row(&s, "late, the lid shut and opened again before the strip came back: the strip back",
        back(&s) && s.n_tries == 1, "check %d tries %d", s.check, s.n_tries);

    /* The built-in at another size than this start's notch: normal full screen, said, never tried. */
    start_late(&s, &LG, true, false);
    lid_opened(&s, 1, &BUILTIN_BIG);
    settle(&s);
    screen_changed(&s, false);
    settle(&s);
    row(&s, "late, the built-in at another size than the notch measured: normal full screen, said once, no try",
        s.rejected && !covers(&s) && s.n_stale == 1 && s.n_tries == 0 && s.n_resumed == 0 &&
        s.check == CHECK_NORMAL, "rejected %d stale %d tries %d resumed %d check %d", s.rejected, s.n_stale,
        s.n_tries, s.n_resumed, s.check);
    /* No panel given (an older app): any size fits. */
    start_late(&s, &LG, true, false);
    s.panel_given = false;
    lid_opened(&s, 0, &BUILTIN_BIG);
    row(&s, "late, no panel size given: the strip on the built-in", covers(&s) && s.tracking &&
        s.check == CHECK_COVERED, "covers %d check %d", covers(&s), s.check);

    /* The other displays' windows (made again per display): normal full screen there, as before. */
    start_late(&s, &LG, false, false);
    row(&s, "a head window on a display without a housing: not armed (normal full screen)",
        !s.armed && !s.late && !s.entered && s.check == CHECK_NORMAL, "armed %d late %d", s.armed, s.late);
    /* The menu bar always shown (Keep the Dock away off): not armed, the line names the menu bar. */
    start_late(&s, &LG, true, true);
    row(&s, "late with the menu bar always shown: not armed, normal full screen", !s.armed && !s.late &&
        s.check == CHECK_NORMAL, "armed %d late %d", s.armed, s.late);
    lid_opened(&s, 0, &BUILTIN);
    settle(&s);
    row(&s, "... on the built-in later: nothing taken, nothing tried", !covers(&s) && s.n_tries == 0 &&
        s.n_covered == 0, "covers %d tries %d", covers(&s), s.n_tries);
}
#endif

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

    /*
     * NSScreen goes with the Space to the LG at once (no stale frame: released, no
     * "display change" line). Back: AppKit asks the reservation while NSScreen still
     * names the LG (its yes kept: the band), NSWindowDidChangeScreen (the resume) comes
     * before the 1728x1084 resize. c6b80695 took that for Split View for good.
     */
    start(&s);
    s.space = &LG;
    s.screen = &LG;
    screen_changed(&s, true);
    layout(&s, false, NULL);
    s.space = &BUILTIN;
    layout_after_screen_change(&s, true, &BUILTIN);
    row(&s, "NSScreen went with the Space to the LG; back, the band after the resume: no strip lost",
        !s.lost && s.n_lost == 0 && s.display_changed && s.check == CHECK_NORMAL, "lost %d check %d",
        s.n_lost, s.check);
    settle(&s);
    row(&s, "... the strip back at the settle", back(&s) && s.n_lost == 0 && s.n_tries == 1,
        "check %d lost %d tries %d", s.check, s.n_lost, s.n_tries);

    /* A real Split View, the display asleep 1 s later (screen parameters): stays lost. */
    start(&s);
    s.now = 10;
    s.frame = (OmacVMFPRect){ 0, 0, 864, 1084 };
    frame_changed(&s);
    s.now = 11;
    s.screen_live = false;
    screen_changed(&s, false);
    s.screen_live = true;
    settle(&s);
    row(&s, "Split View, the display asleep 1 s later: stays lost (a tile is no display change)",
        s.lost && s.n_moved == 0 && s.n_tries == 0 && !claims(&s), "lost %d moved %d tries %d", s.lost,
        s.n_moved, s.n_tries);
    /* ... and NSWindowDidChangeScreen 1 s after a Split View. */
    start(&s);
    s.now = 10;
    s.frame = (OmacVMFPRect){ 864, 0, 864, 1084 };
    frame_changed(&s);
    s.now = 11;
    screen_changed(&s, true);
    row(&s, "Split View, the window's screen changed 1 s later: stays lost", s.lost && s.n_moved == 0,
        "lost %d moved %d", s.lost, s.n_moved);

    /* Split View while a display change still keeps the band: lost, never tried. */
    start(&s);
    builtin_leaves(&s, true);
    s.locked = true;
    builtin_back(&s, 2);
    s.frame = (OmacVMFPRect){ 0, 0, 864, 1084 };
    frame_changed(&s);
    s.locked = false;
    settle(&s);
    row(&s, "Split View while a display change is pending: lost, nothing tried",
        s.lost && s.n_lost == 1 && s.n_tries == 0 && !claims(&s), "lost %d tries %d", s.lost, s.n_tries);

    /* A wait no trigger ends: WindowServer still moves the window at the settle. */
    start(&s);
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    s.in_place = false;
    settle(&s);
    row(&s, "WindowServer still moves the window at the settle: nothing tried, asked again later",
        s.n_tries == 0 && s.reask_due, "tries %d reask %d", s.n_tries, s.reask_due);
    s.in_place = true;
    later(&s);
    row(&s, "... in place 0.5 s later, no trigger in between: the strip back",
        back(&s) && s.n_tries == 1 && s.n_reasks == 1, "check %d tries %d reasks %d", s.check, s.n_tries,
        s.n_reasks);

    /* ... not visible yet. */
    start(&s);
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    s.visible = false;
    settle(&s);
    s.visible = true;
    later(&s);
    row(&s, "not visible yet at the settle: the strip back 0.5 s later", back(&s) && s.n_tries == 1,
        "check %d tries %d", s.check, s.n_tries);

    /* ... a display's window still moving, and its full screen never reports done. */
    start(&s);
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    s.moving = true;
    settle(&s);
    s.moving = false;
    later(&s);
    row(&s, "a display's window still moving at the settle: the strip back 0.5 s later",
        back(&s) && s.n_tries == 1, "check %d tries %d", s.check, s.n_tries);

    /* Asked again at most 3 times after a trigger; the next trigger asks afresh. */
    start(&s);
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    s.in_place = false;
    settle(&s);
    for (int i = 0; i < 6; i++) {
        later(&s);
    }
    row(&s, "WindowServer never in place: asked again 3 times, then quiet, nothing tried or given up",
        s.n_reasks == OMACVM_FP_RETAKE_TRIES && !s.reask_due && s.n_tries == 0 && s.n_give_up == 0,
        "reasks %d due %d tries %d give up %d", s.n_reasks, s.reask_due, s.n_tries, s.n_give_up);
    s.in_place = true;
    come_back(&s);
    row(&s, "... back on its Space later: the strip back", back(&s) && s.n_tries == 1, "check %d tries %d",
        s.check, s.n_tries);

    /* Not asked again for what a trigger ends: locked (the settle after the unlock), another Space. */
    start(&s);
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    s.on_space = false;
    settle(&s);
    row(&s, "on another Space: not asked again (the return asks)", !s.reask_due && s.n_tries == 0,
        "due %d tries %d", s.reask_due, s.n_tries);

    /* A full screen kept for days: every display change gets its tries. */
    start(&s);
    for (int i = 0; i < 4; i++) {
        builtin_leaves(&s, true);
        builtin_back(&s, 2);
        settle(&s);
    }
    row(&s, "four display changes in one full screen: the strip back each time (3 tries each)",
        back(&s) && s.n_tries == 4 && s.n_taken == 4 && s.n_give_up == 0, "check %d tries %d give up %d",
        s.check, s.n_tries, s.n_give_up);
    /* ... while one that AppKit never gives back still ends after 3 tries. */
    s.reshape_works = false;
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    for (int i = 0; i < 5; i++) {
        settle(&s);
    }
    row(&s, "... the fifth kept below the notch by AppKit: 3 tries, then 'strip not back'",
        s.n_tries == 7 && s.retake_given_up && s.check == CHECK_NOT_BACK, "tries %d given up %d check %d",
        s.n_tries, s.retake_given_up, s.check);

    /*
     * Tries per display change: after "strip not back" for good, a later display change in the
     * same full screen gets its own (e6b7d292 started them again only once the strip was covered).
     */
    start(&s);
    s.reshape_works = false;
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    for (int i = 0; i < 4; i++) {
        settle(&s);
    }
    s.reshape_works = true;
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    settle(&s);
    row(&s, "after 'strip not back' for good, the next display change (lid shut, opened): its own tries, the strip back",
        back(&s) && s.n_tries == 4 && s.n_taken == 1, "check %d tries %d taken %d given up %d", s.check,
        s.n_tries, s.n_taken, s.retake_given_up);

    /* The same with a display change NSScreen never sees (the built-in asleep and back), twice. */
    start(&s);
    s.reshape_works = false;
    for (int c = 0; c < 2; c++) {
        s.screen_live = false;
        layout(&s, false, &(OmacVMFPRect){ 0, -323, 2560, 1440 });
        s.screen_live = true;
        layout(&s, true, &(OmacVMFPRect){ 0, 0, 1728, 1084 });   /* below the band, AppKit's tile from before */
        for (int i = 0; i < 4; i++) {
            settle(&s);
        }
        s.reshape_works = true;
    }
    row(&s, "the built-in asleep and back twice (no screen change), 3 tries kept the band the first time: the strip back the second",
        back(&s) && s.n_displaced == 2 && s.n_tries == 4, "check %d displaced %d tries %d", s.check,
        s.n_displaced, s.n_tries);

    /* Still one try per settle: a new display change in the settle of the last try waits for the next. */
    start(&s);
    s.reshape_works = false;
    builtin_leaves(&s, true);
    builtin_back(&s, 2);
    for (int i = 0; i < 3; i++) {
        settle(&s);
    }
    s.reshape_works = true;
    s.screen_live = false;
    layout(&s, false, &(OmacVMFPRect){ 0, -323, 2560, 1440 });
    s.screen_live = true;
    layout(&s, true, &(OmacVMFPRect){ 0, 0, 1728, 1084 });
    come_back(&s);
    row(&s, "a new display change in the settle of the last try: nothing tried before the displays settle again",
        s.n_tries == 3 && s.n_displaced == 2 && !covers(&s), "tries %d displaced %d covers %d", s.n_tries,
        s.n_displaced, covers(&s));
    settle(&s);
    row(&s, "... the next settle: its first try, the strip back", back(&s) && s.n_tries == 4,
        "check %d tries %d", s.check, s.n_tries);

    /* A band taller than the housing's (+ 8 pt): no try, and the line says so (check: not back). */
    start(&s);
    s.screen = s.space = &BUILTIN_TALL;
    s.accepted_display = BUILTIN_TALL.f;
    builtin_leaves(&s, true);
    builtin_back_to(&s, 2, &BUILTIN_TALL);
    settle(&s);
    settle(&s);
    row(&s, "a band taller than the camera housing after a display change: nothing tried, 'strip not back' says why",
        s.n_tries == 0 && s.n_give_up == 1 && s.check == CHECK_NOT_BACK && !covers(&s),
        "tries %d give up %d check %d", s.n_tries, s.n_give_up, s.check);
    /* ... while the displays still settle: no line yet (only once they did). */
    start(&s);
    s.screen = s.space = &BUILTIN_TALL;
    builtin_leaves(&s, true);
    s.locked = true;
    builtin_back_to(&s, 2, &BUILTIN_TALL);
    settle(&s);
    s.moving = true;
    s.locked = false;
    settle(&s);
    row(&s, "a taller band while locked or the displays' windows move: no line yet", s.n_give_up == 0 &&
        s.n_tries == 0, "give up %d tries %d", s.n_give_up, s.n_tries);
    heads_done(&s);
    row(&s, "... once they are in place: 'strip not back' says why", s.n_give_up == 1 && s.n_tries == 0 &&
        s.check == CHECK_NOT_BACK, "give up %d tries %d check %d", s.n_give_up, s.n_tries, s.check);
#ifndef OMACVM_RETAKE_STUB
    late_rows();
#endif
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

    /* A Split View tile's shape: inside, on the bottom edge, narrower; also while animating into it. */
    CHECK(omacvm_fp_tile((OmacVMFPRect){ 0, 0, 864, 1084 }, d));
    CHECK(omacvm_fp_tile((OmacVMFPRect){ 864, 0, 864, 1084 }, d));
    CHECK(omacvm_fp_tile((OmacVMFPRect){ 100, 0, 1500, 1100 }, d));
    CHECK(!omacvm_fp_tile((OmacVMFPRect){ 0, 0, 1728, 1084 }, d));
    CHECK(!omacvm_fp_tile(d, d));
    CHECK(!omacvm_fp_tile((OmacVMFPRect){ 0, 317, 1280, 800 }, d));
    CHECK(!omacvm_fp_tile((OmacVMFPRect){ 0, -323, 2560, 1440 }, d));

    /* covers, inside, display live, same display, a display change in this full screen, tile */
    CHECK(omacvm_fp_frame_kind(true, true, true, true, false, false) == OMACVM_FP_FRAME_COVERS);
    CHECK(omacvm_fp_frame_kind(true, false, false, false, true, false) == OMACVM_FP_FRAME_COVERS);
    CHECK(omacvm_fp_frame_kind(false, false, true, true, false, false) == OMACVM_FP_FRAME_DISPLACED);
    CHECK(omacvm_fp_frame_kind(false, true, false, true, false, false) == OMACVM_FP_FRAME_DISPLACED);
    CHECK(omacvm_fp_frame_kind(false, true, false, true, false, true) == OMACVM_FP_FRAME_DISPLACED);
    CHECK(omacvm_fp_frame_kind(false, false, false, false, false, false) == OMACVM_FP_FRAME_DISPLACED);
    CHECK(omacvm_fp_frame_kind(false, false, true, false, false, false) == OMACVM_FP_FRAME_WAIT);
    CHECK(omacvm_fp_frame_kind(false, true, true, false, false, false) == OMACVM_FP_FRAME_WAIT);
    CHECK(omacvm_fp_frame_kind(false, true, true, false, true, true) == OMACVM_FP_FRAME_WAIT);
    CHECK(omacvm_fp_frame_kind(false, true, true, true, false, false) == OMACVM_FP_FRAME_LOST);
    CHECK(omacvm_fp_frame_kind(false, true, true, true, false, true) == OMACVM_FP_FRAME_LOST);
    /* The band after a display change (also released, the resume before the resize): no Split View. */
    CHECK(omacvm_fp_frame_kind(false, true, true, true, true, false) == OMACVM_FP_FRAME_WAIT);
    /* A tile is Split View's, also while a display change is on its way. */
    CHECK(omacvm_fp_frame_kind(false, true, true, true, true, true) == OMACVM_FP_FRAME_LOST);

    CHECK(omacvm_fp_lost_to_display_change(true, 0, true, false));
    CHECK(omacvm_fp_lost_to_display_change(true, OMACVM_DS_MAX_WAIT_S, true, false));
    CHECK(!omacvm_fp_lost_to_display_change(true, OMACVM_DS_MAX_WAIT_S + 0.1, true, false));
    CHECK(!omacvm_fp_lost_to_display_change(true, 1, false, false));
    CHECK(!omacvm_fp_lost_to_display_change(false, 1, true, false));
    CHECK(!omacvm_fp_lost_to_display_change(true, -1, true, false));
    /* A real Split View is never turned into a display change (the display asleep right after). */
    CHECK(!omacvm_fp_lost_to_display_change(true, 0, true, true));
    CHECK(!omacvm_fp_lost_to_display_change(true, 1, true, true));

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
    /* A taller band: the same shape, more than the housing + OMACVM_FP_BAND_SLACK. */
    CHECK(omacvm_fp_band((OmacVMFPRect){ 0, 0, 1728, 1084 }, d) == 33);
    CHECK(omacvm_fp_band((OmacVMFPRect){ 0, 0, 864, 1084 }, d) < 0);
    CHECK(omacvm_fp_band((OmacVMFPRect){ 0, -323, 2560, 1440 }, d) < 0);
    CHECK(omacvm_fp_band_tall((OmacVMFPRect){ 0, 0, 1728, 1073 }, d, 32));
    CHECK(omacvm_fp_band_tall((OmacVMFPRect){ 0, 0, 1728, 1000 }, d, 32));
    CHECK(!omacvm_fp_band_tall((OmacVMFPRect){ 0, 0, 1728, 1077 }, d, 32));
    CHECK(!omacvm_fp_band_tall((OmacVMFPRect){ 0, 0, 1728, 1084 }, d, 32));
    CHECK(!omacvm_fp_band_tall(d, d, 32));
    CHECK(!omacvm_fp_band_tall((OmacVMFPRect){ 0, 0, 864, 1000 }, d, 32));
    CHECK(!omacvm_fp_band_tall((OmacVMFPRect){ 0, 33, 1728, 1000 }, d, 32));
    CHECK(!omacvm_fp_band_tall((OmacVMFPRect){ 0, -323, 2560, 1440 }, d, 32));

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
    /* Below a taller band: no try, said once settled (not while it still moves or is locked). */
    f = now;
    f.band_kept = false;
    f.band_tall = true;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_GIVE_UP && !strcmp(why, OMACVM_FP_WHY_BAND_TALL));
    f.locked = true;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_WAIT);
    f.locked = false;
    f.moving = true;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_WAIT);
    f.moving = false;
    f.in_place = false;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_WAIT);
    f.in_place = true;
    f.menu_bar_in_the_way = true;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_GIVE_UP && !strcmp(why, "menu bar always shown"));
    f = now;
    f.band_tall = true;
    f.lost = true;
    CHECK(omacvm_fp_retake(f, &why) == OMACVM_FP_RETAKE_NO);
    CHECK(omacvm_fp_retake(now, NULL) == OMACVM_FP_RETAKE_NOW);
    CHECK(!omacvm_fp_retake_final(OMACVM_FP_RETAKE_TRIES - 1) && omacvm_fp_retake_final(OMACVM_FP_RETAKE_TRIES));

    /* Ask again after a wait that ends by itself: WindowServer, the displays' windows, not visible yet. */
#define REASK(field, value, want) do { f = now; f.field = value; \
        CHECK(omacvm_fp_retake_reask(f, omacvm_fp_retake(f, NULL), 0) == want); } while (0)
    REASK(in_place, false, true);
    REASK(moving, true, true);
    REASK(visible, false, true);
    /* Not for what a trigger or the check ends, nor for a now, a no or a give up. */
    REASK(locked, true, false);
    REASK(display_live, false, false);
    REASK(same_size, false, false);
    REASK(on_space, false, false);
    REASK(pending, true, false);
    REASK(appkit_band, false, false);
    REASK(tried_this_settle, true, false);
    REASK(lost, true, false);
    REASK(covers, true, false);
    REASK(reshape, false, false);
    REASK(given_up, true, false);
    CHECK(!omacvm_fp_retake_reask(now, OMACVM_FP_RETAKE_NOW, 0));
    /* At most OMACVM_FP_RETAKE_TRIES times after a trigger. */
    f = now;
    f.in_place = false;
    CHECK(omacvm_fp_retake_reask(f, OMACVM_FP_RETAKE_WAIT, OMACVM_FP_RETAKE_TRIES - 1));
    CHECK(!omacvm_fp_retake_reask(f, OMACVM_FP_RETAKE_WAIT, OMACVM_FP_RETAKE_TRIES));
    CHECK(!omacvm_fp_retake_reask(f, OMACVM_FP_RETAKE_WAIT, -1));
    /* moving is asked again also when the window is on another Space (it waits there next time). */
    f = now;
    f.moving = true;
    f.on_space = false;
    CHECK(omacvm_fp_retake_reask(f, omacvm_fp_retake(f, NULL), 0));
    CHECK(OMACVM_FP_RETAKE_REASK_S > 0 && OMACVM_FP_RETAKE_REASK_S < OMACVM_FP_RETAKE_CHECK_S);
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
