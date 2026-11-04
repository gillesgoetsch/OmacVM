/*
 * test-hdr-sdr-tag: the rules of ui/omacvm-hdr-tag.h (ADR 0049, amended):
 * when PQ frames are tagged 1x and when untagged, and the headroom the
 * guest is told. Besides the plain cases, a model of a Mac: macOS raises
 * the panel's headroom to its most within 2 s while any untagged frame
 * shows and keeps it 5 s after; the guest fits its HDR into the headroom
 * it is told. It must show: SDR frames never untagged, HDR untagged within
 * a look, no lock (the guest told 1 forever) and no back and forth.
 * --self-test: the same model with older or simpler rules must fail
 * (3.2.22: never tagged; the guest told the current headroom; a 2 s hold).
 * Run by test-hdr-sdr-tag.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "omacvm-hdr-tag.h"

static int failures;
static bool quiet;

static void check(bool ok, const char *what)
{
    if (!ok) {
        if (!quiet) {
            fprintf(stderr, "test-hdr-sdr-tag: %s\n", what);
        }
        failures++;
    }
}

#define S(x) ((int64_t)((x) * 1e9))

enum rule { REAL, OLD_3222, NAIVE_GUEST, SHORT_HOLD };

typedef struct Model {
    enum rule rule;
    OmacvmHdrNeed n;
    OmacvmEdrHold h;
    double cur;             /* macOS's current headroom */
    double potential;
    int64_t untagged_ns;    /* the last time an untagged frame showed */
    int64_t open_ns;        /* need 1 -> 0 */
    double told;            /* what the guest was told (-1 nothing yet) */
    int downs, ups;         /* need 1 -> 0, 0 -> 1 */
    int64_t first_down;
    double cur_max_sdr;     /* the panel's headroom while only SDR showed */
} Model;

static void model_init(Model *m, enum rule r, double potential)
{
    memset(m, 0, sizeof(*m));
    m->rule = r;
    m->cur = 1.0;
    m->potential = potential;
    m->told = -1;
    m->first_down = -1;
    omacvm_hdr_need_reset(&m->n);
    m->h.held = -1;
    m->open_ns = -1;
}

static double need_now(Model *m)
{
    return m->rule == OLD_3222 ? 0 : m->n.need;
}

/* One 50 ms step of the Mac: what the panel's headroom does. */
static void mac_step(Model *m, int64_t t)
{
    double dt = 0.05;
    if (need_now(m) == 0) {
        m->untagged_ns = t;
        m->cur = fmin(m->potential, m->cur * pow(16.0, dt / 2.0));    /* 1 -> 16 in 2 s */
    } else if (t - m->untagged_ns >= S(5)) {
        m->cur = fmax(1.0, m->cur / pow(16.0, dt / 2.0));             /* after its 5 s hold */
    }
}

static void look(Model *m, double frame_peak, int64_t t)
{
    if (m->rule == OLD_3222) {
        return;
    }
    double was = m->n.need;
    if (m->rule == SHORT_HOLD) {
        m->n.peak = frame_peak;
        if (omacvm_hdr_is_hdr(frame_peak)) {
            m->n.hdr_ns = t;
            m->n.need = 0;
        } else if (m->n.need == 0 && t - m->n.hdr_ns >= S(2)) {
            m->n.need = 1;
        }
    } else {
        omacvm_hdr_need_peak(&m->n, frame_peak, t);
    }
    if (was != 0 && m->n.need == 0) {
        m->downs++;
        m->open_ns = t;
        if (m->first_down < 0) {
            m->first_down = t;
        }
    } else if (was == 0 && m->n.need != 0) {
        m->ups++;
    }
}

static void guest_send(Model *m, int64_t t)
{
    double v;
    bool nd = false;
    if (m->rule == NAIVE_GUEST || m->rule == OLD_3222) {
        v = omacvm_edr_value(m->cur, m->potential, false);
    } else {
        v = omacvm_edr_guest(&m->h, &nd, 7, m->cur, m->potential, false,
                             m->n.need > 0, m->open_ns, t);
    }
    if (omacvm_edr_moved(m->told, v)) {
        m->told = v;
    }
}

/*
 * Run the model for secs; content(t) is the brightest the guest's frames
 * would be (x SDR white), the guest fits it into what it was told.
 */
static void run(Model *m, double secs, double (*content)(double))
{
    int64_t next_look = 0, next_send = 0;
    for (int64_t t = 0; t <= S(secs); t += S(0.05)) {
        mac_step(m, t);
        double c = content(t / 1e9);
        double told = m->told > 0 ? m->told : 1.0;
        double frame = c > 1.0 ? fmin(c, told) : c;
        if (frame > 1.0 && frame < 1.0 + 1e-9) {
            frame = 1.0;
        }
        if (t >= next_look) {
            look(m, frame, t);
            next_look = t + OMACVM_HDR_LOOK_NS;
        }
        if (m->rule != OLD_3222 && m->rule != SHORT_HOLD) {
            omacvm_hdr_need_tick(&m->n, t);
        }
        if (t >= next_send) {
            guest_send(m, t);
            next_send = t + S(1);
        }
        if (c <= 1.0 && t > S(1) && (m->downs == 0)) {
            m->cur_max_sdr = fmax(m->cur_max_sdr, m->cur);
        }
    }
}

static double sdr_only(double t) { (void)t; return 1.0; }
static double video(double t) { return t >= 5 && t < 25 ? 4.0 : 1.0; }
static double scenes(double t)
{
    /* HDR video from 5 s to 65 s: 3 s bright (4x), 6 s dark (0.9x), again */
    if (t < 5 || t >= 65) {
        return 1.0;
    }
    return fmod(t - 5, 9) < 3 ? 4.0 : 0.9;
}

/* The model's checks; returns how many failed. */
static int model_checks(enum rule r)
{
    int before = failures;
    Model m;

    /* SDR only: frames stay tagged 1x, the panel stays at SDR. */
    model_init(&m, r, 16);
    run(&m, 30, sdr_only);
    check(m.downs == 0 && need_now(&m) == 1, "SDR frames were untagged");
    check(m.cur < 1.3, "the panel's headroom rose with SDR frames only");

    /* HDR video 5-25 s: untagged within a look and its result, once; 1x 10 s after. */
    model_init(&m, r, 16);
    run(&m, 24, video);
    check(m.downs == 1 && m.first_down >= S(5) && m.first_down <= S(5.6),
          "HDR frames were not untagged within a look");
    check(m.ups == 0 && need_now(&m) == 0, "HDR frames lost their headroom (a lock or back and forth)");
    check(m.told >= 15.9, "the guest was not told the panel's headroom while HDR showed");
    model_init(&m, r, 16);
    run(&m, 37, video);
    check(m.ups == 1 && need_now(&m) == 1, "frames not tagged 1x again 10 s after HDR ended");
    check(m.told >= 15.9, "the guest lost its headroom after HDR ended (it would be told 1)");

    /* Dark and bright scenes: one rise of the panel for the whole video. */
    model_init(&m, r, 16);
    run(&m, 64, scenes);
    check(m.downs == 1 && m.ups == 0, "dark scenes in an HDR video tagged the frames 1x again");
    return failures - before;
}

int main(int argc, char **argv)
{
    bool self = argc > 1 && !strcmp(argv[1], "--self-test");
    bool nd = false;

    if (self) {
        /* Older or simpler rules fail the model's checks. */
        quiet = true;
        int old = model_checks(OLD_3222), naive = model_checks(NAIVE_GUEST),
            hold = model_checks(SHORT_HOLD);
        quiet = false;
        failures = 0;
        check(old > 0, "the model passes 3.2.22 (frames never tagged)");
        check(naive > 0, "the model passes a guest told the current headroom");
        check(hold > 0, "the model passes a 2 s hold");
        if (failures) {
            return 1;
        }
        printf("test-hdr-sdr-tag: self-test ok (3.2.22 %d, current-headroom guest %d, 2 s hold %d checks fail)\n",
               old, naive, hold);
        return 0;
    }

    /* PQ codes: 594 is SDR white (203 nits), 599 still SDR, 600 HDR; 1000 nits = 4.93x. */
    check(fabs(omacvm_hdr_pq_units(594 / 1023.0) - 1.0) < 0.005, "PQ 594 is not SDR white");
    check(!omacvm_hdr_is_hdr(omacvm_hdr_pq_units(594 / 1023.0)), "SDR white counts as HDR");
    check(!omacvm_hdr_is_hdr(omacvm_hdr_pq_units(599 / 1023.0)), "PQ 599 counts as HDR");
    check(omacvm_hdr_is_hdr(omacvm_hdr_pq_units(600 / 1023.0)), "PQ 600 counts as SDR");
    check(fabs(omacvm_hdr_pq_units(0.7518) - 4.925) < 0.01, "PQ 1000 nits is not 4.93x");
    check(omacvm_hdr_pq_units(0) == 0 && !omacvm_hdr_is_hdr(0), "black is not 0 or counts as HDR");
    check(omacvm_hdr_pq_units(2.0) == omacvm_hdr_pq_units(1.0), "a value above 1 is not 10000 nits");
    /* The safe side (the old behaviour, untagged) for what cannot be read. */
    check(omacvm_hdr_is_hdr(NAN) && omacvm_hdr_is_hdr(-0.5) && omacvm_hdr_is_hdr(INFINITY) &&
          omacvm_hdr_is_hdr(omacvm_hdr_pq_units(NAN)) && omacvm_hdr_is_hdr(omacvm_hdr_pq_units(-1)),
          "NaN, negative or huge peaks count as SDR");

    /* The need: 1x from the start, 0 at once on HDR, 1x 10 s after the last HDR look. */
    OmacvmHdrNeed n;
    omacvm_hdr_need_reset(&n);
    check(n.need == 1 && omacvm_hdr_need_due(&n) == -1, "PQ frames do not start at 1x");
    check(!omacvm_hdr_need_peak(&n, 1.0, S(1)) && n.need == 1, "SDR untags");
    check(omacvm_hdr_need_peak(&n, 4.93, S(2)) && n.need == 0, "HDR does not untag at once");
    check(omacvm_hdr_need_due(&n) == S(12), "the hold does not end 10 s after the last HDR look");
    check(!omacvm_hdr_need_peak(&n, 4.93, S(3)) && omacvm_hdr_need_due(&n) == S(13), "HDR again does not move the hold");
    check(!omacvm_hdr_need_peak(&n, 1.0, S(12.9)) && n.need == 0, "1x before the hold is over");
    check(!omacvm_hdr_need_tick(&n, S(12.99)) && n.need == 0, "1x before the hold is over (time only)");
    check(omacvm_hdr_need_tick(&n, S(13)) && n.need == 1, "not 1x when the hold is over (time only)");
    omacvm_hdr_need_reset(&n);
    omacvm_hdr_need_peak(&n, 2.0, S(1));
    check(!omacvm_hdr_need_tick(&n, S(30)) && n.need == 0, "a still HDR frame lost its headroom");
    check(omacvm_hdr_need_peak(&n, 0.5, S(30)) && n.need == 1, "SDR after a long HDR frame is not 1x");
    omacvm_hdr_need_reset(&n);
    check(omacvm_hdr_need_peak(&n, NAN, S(1)) && n.need == 0, "an unreadable peak does not untag");

    /* The guest's headroom. */
    OmacvmEdrHold h = { .held = -1 };
    double v;
    /* Tagged before anything was untagged: the display's most, capped at 16. */
    v = omacvm_edr_guest(&h, &nd, 1, 1.2, 16, false, true, -1, S(0));
    check(v == 16 && !nd, "tagged at start: not the display's most");
    check(omacvm_edr_guest(&h, &nd, 1, 1.0, 24, false, true, -1, S(0)) == 16, "more than 16");
    check(nd, "a new most of the display is not a new display");
    nd = false;
    omacvm_edr_guest(&h, &nd, 1, 1.0, 16, false, true, -1, S(0));
    /* Untagged at 10 s: not less than 16 while macOS ramps, at most 3 s. */
    check(omacvm_edr_guest(&h, &nd, 1, 1.4, 16, false, false, S(10), S(10.2)) == 16,
          "the guest is told the ramp's start");
    check(omacvm_edr_guest(&h, &nd, 1, 5.0, 16, false, false, S(10), S(12.9)) == 16,
          "the guest is told the ramp before 3 s");
    check(omacvm_edr_guest(&h, &nd, 1, 5.0, 16, false, false, S(10), S(13)) == 5,
          "the guest is not told the current headroom after 3 s");
    check(omacvm_edr_guest(&h, &nd, 1, 6.0, 16, false, false, S(10), S(14)) == 6,
          "the guest does not follow the current headroom once settled");
    /* Tagged again: what it had (6), not the 1.2 the panel falls to. */
    check(omacvm_edr_guest(&h, &nd, 1, 1.2, 16, false, true, S(10), S(30)) == 6,
          "tagged again: the guest is not told what it had");
    /* Untagged again: settled as soon as the current headroom reaches the held one. */
    check(omacvm_edr_guest(&h, &nd, 1, 2.0, 16, false, false, S(40), S(40.5)) == 6, "the second ramp");
    check(omacvm_edr_guest(&h, &nd, 1, 7.0, 16, false, false, S(40), S(41)) == 7,
          "not settled when the current headroom reached the held one");
    /* A panel that has no headroom now (1.0): sent, but never held. */
    check(omacvm_edr_guest(&h, &nd, 1, 1.0, 16, false, false, S(40), S(50)) == 1.0, "a panel at 1.0");
    check(omacvm_edr_guest(&h, &nd, 1, 1.0, 16, false, true, S(40), S(70)) == 7,
          "a panel at 1.0 was held (the guest would never ask again)");
    /* Another display (potential 2): its own value, never above its most, the held 7 forgotten. */
    nd = false;
    check(omacvm_edr_guest(&h, &nd, 2, 1.0, 2.0, false, true, S(40), S(80)) == 2.0 && nd,
          "another display: not its own most, or not noticed");
    nd = false;
    check(omacvm_edr_guest(&h, &nd, 1, 1.0, 16, false, true, S(40), S(90)) == 16 && nd,
          "back on the first display: the other display's value held");
    /* Held above a new display's most is capped (same key, the most went down a little). */
    OmacvmEdrHold h2 = { .held = -1 };
    omacvm_edr_guest(&h2, &nd, 3, 1.0, 4.0, false, false, S(0), S(5));
    check(h2.held == -1, "SDR headroom held");
    omacvm_edr_guest(&h2, &nd, 3, 4.0, 4.0, false, false, S(0), S(6));
    check(omacvm_edr_guest(&h2, &nd, 3, 1.0, 4.0, false, true, S(0), S(7)) == 4.0, "held value lost");
    /* use_potential (OMACVM_GL_EDR_HEADROOM=potential) while untagged: the most. */
    OmacvmEdrHold h3 = { .held = -1 };
    check(omacvm_edr_guest(&h3, &nd, 4, 1.0, 8.0, true, false, S(0), S(5)) == 8.0, "potential not used");

    model_checks(REAL);

    if (failures) {
        fprintf(stderr, "test-hdr-sdr-tag: %d failed\n", failures);
        return 1;
    }
    printf("test-hdr-sdr-tag: ok\n");
    return 0;
}
