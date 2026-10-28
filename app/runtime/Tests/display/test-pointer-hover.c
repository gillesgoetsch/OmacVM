/*
 * A move over the VM while another app is in front gives the guest only the
 * pointer's place (ui/omacvm-pointer-hover.h; the user's case of 2026-10-28:
 * full screen on the MacBook's display and an LG, the MacBook's display
 * switched to macOS, no pointer in the VM on the LG). Run by
 * test-pointer-hover.sh against the header the logic patch makes.
 */
#include <math.h>
#include <stdio.h>
#include "omacvm-pointer-hover.h"

static int fails;

static void check(const char *what, bool ok)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fails += !ok;
}

/* The user's case: the LG's window, a Mac app in front on the MacBook's display. */
static OmacVMHoverIn users_case(void)
{
    OmacVMHoverIn in = {
        .off = false, .absolute = true, .grabbed = false, .active = false, .move = true,
        .buttons = false, .touchid = false, .displays = 2, .full = true, .top = true,
    };
    return in;
}

/*
 * A small model of QEMU's window code for one event over a VM window, as
 * ui/cocoa.m wires it (omacvmHeadEvent, omacvmHover, grabMouse): which of
 * the VM's and the Mac's state each event changes.
 */
typedef struct Box { double x, y, w, h; } Box;

typedef struct Model {
    bool off;               /* OMACVM_POINTER_HOVER=0 */
    bool grabbed, active;
    bool our_key_window;    /* a window of ours is the key window */
    int cursor_hides;       /* the Mac's cursor hidden (a grab) */
    int places;             /* places the guest's tablet got */
    double x, y;            /* the last one, in the box around all outputs (0..1) */
    int keys;               /* keys the guest got */
} Model;

/* Virtual-1 on the MacBook's display (main window), Virtual-2 on the LG right of it. */
static const Box outputs[2] = { { 0, 0, 1728, 1117 }, { 1728, 0, 2560, 1440 } };
static const Box all = { 0, 0, 1728 + 2560, 1440 };

static void place(Model *m, int output, double u, double v)
{
    const Box *b = &outputs[output];

    m->x = (b->x + u * b->w - all.x) / all.w;
    m->y = (b->y + v * b->h - all.y) / all.h;
    m->places++;
}

/* A move (button < 0) or a click over output's window at (u, v) of it. */
static void event(Model *m, int output, double u, double v, int button)
{
    if (!m->grabbed) {
        if (button < 0 && !m->active) {
            OmacVMHoverIn in = users_case();

            in.off = m->off;
            if (omacvm_pointer_hover(&in)) {
                place(m, output, u, v);       /* omacvmHover: the place, nothing else */
            }
            return;
        }
        /* A click: macOS brings the app to the front first (acceptsFirstMouse). */
        m->active = true;
        m->our_key_window = true;
        m->grabbed = true;                    /* grabMouse */
        m->cursor_hides++;
    }
    place(m, output, u, v);
}

/* A key: to the guest only while it has the keyboard (isKeyboardCaptured). */
static void key(Model *m)
{
    if (m->grabbed || (m->active && m->our_key_window)) {
        m->keys++;
    }
}

static bool in_virtual2(const Model *m)
{
    double x = m->x * all.w, y = m->y * all.h;

    return x >= outputs[1].x && x <= outputs[1].x + outputs[1].w &&
           y >= outputs[1].y && y <= outputs[1].y + outputs[1].h;
}

int main(void)
{
    OmacVMHoverIn in;

    /* The rule. */
    in = users_case();
    check("the user's case: the LG's window, a Mac app in front: the place goes to the guest",
          omacvm_pointer_hover(&in));
    in.displays = 5;
    check("five displays: the same", omacvm_pointer_hover(&in));

    in = users_case(); in.off = true;
    check("OMACVM_POINTER_HOVER=0: dropped, as before", !omacvm_pointer_hover(&in));
    in = users_case(); in.absolute = false;
    check("a relative pointer (no tablet yet): dropped", !omacvm_pointer_hover(&in));
    in = users_case(); in.grabbed = true;
    check("the VM has the pointer: not this path (the normal one)", !omacvm_pointer_hover(&in));
    in = users_case(); in.active = true;
    check("OmacVM in front: not this path (the normal one)", !omacvm_pointer_hover(&in));
    in = users_case(); in.move = false;
    check("a click: not this path (it takes the pointer)", !omacvm_pointer_hover(&in));
    in = users_case(); in.buttons = true;
    check("a drag that started in a Mac app: dropped", !omacvm_pointer_hover(&in));
    in = users_case(); in.touchid = true;
    check("Touch ID's panel up: dropped", !omacvm_pointer_hover(&in));
    in = users_case(); in.displays = 1;
    check("one display: dropped, as before", !omacvm_pointer_hover(&in));
    in = users_case(); in.displays = 0;
    check("no display known: dropped", !omacvm_pointer_hover(&in));
    in = users_case(); in.full = false;
    check("a window not in full screen: dropped", !omacvm_pointer_hover(&in));
    in = users_case(); in.top = false;
    check("another window above it under the pointer: dropped", !omacvm_pointer_hover(&in));

    /* The switch. */
    check("OMACVM_POINTER_HOVER unset: on", !omacvm_pointer_hover_off(NULL));
    check("OMACVM_POINTER_HOVER=0: off", omacvm_pointer_hover_off("0"));
    check("OMACVM_POINTER_HOVER=1: on", !omacvm_pointer_hover_off("1"));
    check("OMACVM_POINTER_HOVER empty: on", !omacvm_pointer_hover_off(""));

    /* The debug line at most every OMACVM_HOVER_LOG_S. */
    {
        double last = -1;

        check("the first hover: a line", omacvm_hover_log_due(100.0, &last));
        check("a second later: none", !omacvm_hover_log_due(101.0, &last));
        check("just under the period: none", !omacvm_hover_log_due(100.0 + OMACVM_HOVER_LOG_S - 0.01, &last));
        check("after the period: a line", omacvm_hover_log_due(100.0 + OMACVM_HOVER_LOG_S, &last));
        check("at time 0 (never logged): a line", omacvm_hover_log_due(0.0, &(double){ -1 }));
    }

    /* The user's steps. */
    {
        Model m = { 0 };

        /* A Mac app in front on the MacBook's display; three moves over the LG's window. */
        event(&m, 1, 0.10, 0.20, -1);
        event(&m, 1, 0.50, 0.50, -1);
        event(&m, 1, 0.90, 0.80, -1);
        check("three moves over the LG: three places for the guest", m.places == 3);
        check("the last one inside Virtual-2", in_virtual2(&m));
        check("the VM did not take the pointer", !m.grabbed);
        check("the Mac's cursor was not hidden", m.cursor_hides == 0);
        key(&m);
        check("a key typed meanwhile is the Mac app's: none to the guest", m.keys == 0);
        event(&m, 1, 0.5, 0.5, 0);
        check("a click takes the pointer (and OmacVM comes to the front)", m.grabbed && m.active);
        key(&m);
        check("then keys go to the guest", m.keys == 1);
    }
    {
        Model m = { .off = true };

        event(&m, 1, 0.10, 0.20, -1);
        event(&m, 1, 0.50, 0.50, -1);
        check("OMACVM_POINTER_HOVER=0: moves give the guest nothing (as in 3.2.10)", m.places == 0);
        event(&m, 1, 0.5, 0.5, 0);
        check("OMACVM_POINTER_HOVER=0: a click still takes the pointer", m.grabbed && m.places == 1);
    }

    printf("%s\n", fails ? "test-pointer-hover: FAILED" : "test-pointer-hover: all ok");
    return fails != 0;
}
