/* test-present-skip.sh --self-test: the vsync queue's code of ui/cocoa.m before omacvm-cocoa-present-skipped-last.patch (a drawn frame skipped with none queued after it never went on screen), as the test's extract takes it. Not used by QEMU. */
#define PRESENT_QUEUE 3
#define PRESENT_IDLE_S 0.25            /* no frame for this long: link stops */
#define PRESENT_INPUT_NS (150 * SCALE_MS)
#define PRESENT_CLOSE_S (1.25 / 24)    /* frames closer than this are paced */
typedef struct PresentFrame {
    IOSurfaceRef surf;
    GLint filter;
    double flushed;                     /* reached QEMU's present */
    bool linear;                        /* drawn in linear light (extra brightness) */
    OmacvmPTFrame *pt;                  /* tiled present: tile updates (surf NULL) */
} PresentFrame;
static struct {
    PresentFrame queue[PRESENT_QUEUE];  /* oldest first */
    int queued;
    int inflight;                       /* drawn, GPU not done yet */
    bool linked;                        /* frames wait for the link's tick */
    bool missed;                        /* the last tick had no frame */
    int close_frames;                   /* unlinked: close frames in a row */
    int extra;                          /* frames in a row that replaced
                                           the one before (slowed link) */
    double last_ready;                  /* the last frame the GPU finished */
    double period;                      /* the link's tick period */
    int max_hz, min_hz;                 /* the window's screen */
    double hz;                          /* the rate asked of the link */
    int slower;                         /* windows in a row that wanted less */
    double win_start;                   /* one-second window: start, */
    int win_ticks;                      /* ticks, */
    int win_min;                        /* fewest frames left after a tick, */
    int left_run;                       /* ticks in a row that left a frame */
    int win_late;                       /* refreshes that had no frame, */
    int win_frames;                     /* frames that came, */
    int win_extra;                      /* extra flushes that replaced one, */
    int win_flushes;                    /* the guest's flushes, */
    double win_first, win_last;         /* the first and the last, */
    double win_gap, win_gap2;           /* the two shortest gaps */
    bool merge;                         /* the guest draws faster than the link */
    unsigned ticks, shown, direct, repeats, merged, dropped, busy; /* trace */
    double wait_sum;
} present_sync = {
    .win_min = INT_MAX, .win_gap = INFINITY, .win_gap2 = INFINITY,
};
static void present_frame_put(PresentFrame *f)
{
    if (f->surf) {
        surface_put(f->surf);
    }
    if (f->pt) {
        if (f->pt->base) {
            surface_put(f->pt->base);
        }
        for (unsigned i = 0; i < f->pt->n; i++) {
            surface_put(f->pt->up[i].buf);
        }
        g_free(f->pt);
    }
    *f = (PresentFrame){ 0 };
}
static void present_frame_absorb(PresentFrame *newer, PresentFrame *older)
{
    if (!older->surf && !older->pt) {
        return;
    }
    if (!newer->pt) {
        present_frame_put(older);
        return;
    }
    OmacvmPTFrame whole = { .base = older->surf };
    OmacvmPTFrame *o = older->pt ? older->pt : &whole;
    bool had_base = newer->pt->base != NULL;
    void *freed[OMACVM_PT_MAX + 1];
    unsigned nf = omacvm_pt_absorb(newer->pt, o, freed);
    for (unsigned i = 0; i < nf; i++) {
        surface_put(freed[i]);
    }
    if (!had_base && newer->pt->base) {
        /* the whole frame is shown as OLDER would have shown it */
        newer->filter = older->filter;
        newer->linear = older->linear;
    }
    g_free(older->pt);
    *older = (PresentFrame){ 0 };
}
static PresentFrame present_pend;
static void present_frame_skip(PresentFrame *older, PresentFrame *next)
{
    if (present_tiles_on <= 0) {
        present_frame_put(older);
    } else if (next) {
        present_frame_absorb(next, older);
    } else {
        present_frame_absorb(older, &present_pend);
        present_pend = *older;
        *older = (PresentFrame){ 0 };
    }
}
static void present_window_reset(double now)
{
    present_sync.win_start = now;
    present_sync.win_ticks = 0;
    present_sync.win_min = INT_MAX;
    present_sync.win_late = 0;
    present_sync.win_frames = 0;
    present_sync.win_extra = 0;
    present_sync.win_flushes = 0;
    present_sync.win_first = present_sync.win_last = 0;
    present_sync.win_gap = present_sync.win_gap2 = INFINITY;
}
static void cocoa_gl_present_queue_frame(PresentFrame f)
{
    double now = CACurrentMediaTime();
    bool show = false, wake = false, faster = false;

    os_unfair_lock_lock(&present_lock);
    present_sync.inflight--;
    /* OmacVM, tiles: a frame skipped while none was queued comes along. */
    present_frame_absorb(&f, &present_pend);
    double gap = present_sync.last_ready > 0 ?
                 now - present_sync.last_ready : INFINITY;
    present_sync.last_ready = now;
    if (!present_sync.linked) {
        present_sync.close_frames =
            gap < PRESENT_CLOSE_S ? present_sync.close_frames + 1 : 0;
        if (present_fixed || present_sync.close_frames >= 2) {
            present_sync.linked = true;
            present_sync.missed = false;
            present_sync.hz = present_sync.max_hz;
            present_sync.slower = 0;
            present_sync.merge = false;
            present_window_reset(now);
            wake = true;
        } else {
            show = true;
            present_sync.direct++;
            trace_cocoa_present_direct(isfinite(gap) ? (int)(gap * 1000) : -1);
        }
    }
    if (present_sync.win_frames++) {
        if (gap < present_sync.win_gap) {
            present_sync.win_gap2 = present_sync.win_gap;
            present_sync.win_gap = gap;
        } else if (gap < present_sync.win_gap2) {
            present_sync.win_gap2 = gap;
        }
    } else {
        present_sync.win_first = now;
    }
    present_sync.win_last = now;
    if (!show) {
        PresentFrame *last = present_sync.queued ?
                             &present_sync.queue[present_sync.queued - 1] : NULL;
        /*
         * A link slower than the screen runs at the guest's measured rate:
         * a frame within half a tick of the last is an extra flush, not a
         * frame of its own, and replaces it (else it would push every
         * later frame back by a tick, or fill the queue).
         */
        bool slowed = present_sync.hz < present_sync.max_hz;
        if ((present_sync.merge || slowed) && last &&
            gap < present_sync.period / 2) {
            present_frame_skip(last, &f);
            present_sync.queued--;
            present_sync.merged++;
            present_sync.extra++;
            present_sync.win_extra += slowed;
        } else {
            present_sync.extra = 0;
            if (present_sync.queued == PRESENT_QUEUE) {
                present_frame_skip(&present_sync.queue[0], &present_sync.queue[1]);
                memmove(&present_sync.queue[0], &present_sync.queue[1],
                        sizeof(PresentFrame) * (PRESENT_QUEUE - 1));
                present_sync.queued--;
                present_sync.dropped++;
            }
        }
        present_sync.queue[present_sync.queued++] = f;
        /*
         * The guest draws faster than a slowed link (two extra frames in a
         * row, or a full queue): the full rate at once.
         */
        if (slowed && (present_sync.extra >= 2 ||
                       present_sync.queued == PRESENT_QUEUE)) {
            present_sync.hz = present_sync.max_hz;
            present_sync.slower = 0;
            present_sync.extra = 0;
            faster = true;
        }
    }
    trace_cocoa_present_frame(isfinite(gap) ? (int)(gap * 1e6) : -1,
                              present_sync.queued, present_sync.linked);
    os_unfair_lock_unlock(&present_lock);

    if (show) {
        present_frame_show(&f);
        present_frame_put(&f);
    }
    if (wake) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cocoa_gl_present_link_start();
        });
    } else if (faster) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cocoa_gl_present_link_rate();
        });
    }
}
static double present_wanted_hz(void)
{
    double max_hz = present_sync.max_hz;

    if (present_sync.win_frames < 3 ||
        present_sync.win_last <= present_sync.win_first) {
        return max_hz;
    }
    /* Extra flushes that replaced a frame are not frames of their own. */
    double fps = (present_sync.win_frames - 1 - present_sync.win_extra) /
                 (present_sync.win_last - present_sync.win_first);
    for (int k = 8; k >= 2; k--) {
        double r = max_hz / k;
        double m = r / fps;
        double whole = round(m);
        if (r < present_sync.min_hz || whole < 1 ||
            fabs(m - whole) > 0.03 * whole ||
            present_sync.win_gap2 < 0.5 / r) {
            continue;
        }
        return r;
    }
    return max_hz;
}
static bool cocoa_gl_present_vsync(double T)
{
    PresentFrame show = { 0 };
    int nstale = 0;
    bool input = present_input_first &&
                 qemu_clock_get_ns(QEMU_CLOCK_REALTIME) - qemu_input_last_event_ns() <
                 PRESENT_INPUT_NS;
    double now = CACurrentMediaTime();
    bool rate = false, idle = false;

    os_unfair_lock_lock(&present_lock);
    if (T > 0 && T < 0.1) {
        present_sync.period = T;
    }
    present_sync.win_ticks++;
    present_sync.ticks++;
    if (present_sync.queued) {
        /*
         * Input is coming: frames that wait behind a newer one are old news
         * (the newer answers the input). Show the newest at this refresh.
         */
        if (input && present_sync.queued > 1) {
            nstale = present_sync.queued - 1;
            /* newest first: each goes into the frames after it (tiles) */
            for (int i = nstale - 1; i >= 0; i--) {
                present_frame_skip(&present_sync.queue[i], &present_sync.queue[nstale]);
            }
            memmove(&present_sync.queue[0], &present_sync.queue[nstale],
                    sizeof(PresentFrame));
            present_sync.queued = 1;
            present_sync.dropped += nstale;
        }
        show = present_sync.queue[0];
        present_sync.queued--;
        memmove(&present_sync.queue[0], &present_sync.queue[1],
                sizeof(PresentFrame) * present_sync.queued);
        present_sync.shown++;
        present_sync.wait_sum += now - show.flushed;
        present_sync.win_min = MIN(present_sync.win_min, present_sync.queued);
        present_sync.missed = false;
        /*
         * OmacVM: a frame left over after every tick for a quarter second is
         * a refresh of delay the guest's timing does not need: skip it. A
         * guest a little faster than the display (its clock against the
         * Mac's) adds about a frame a second, and the once-a-second trim
         * below, which waits for a second without a late tick, only held
         * the queue where it was: a queue that once grew (an app starting,
         * a hiccup) kept its extra frames, 16.7 ms each at 60 Hz, for good.
         * The VM's frames come that steadily once virgl no longer stops the
         * vCPUs (OMACVM_GPU_UNLOCKED=1, ADR 0046); the app asks for this
         * with it (OMACVM_GL_TRIM=quarter). Without it: as before.
         */
        if (present_trim_quarter && present_sync.queued) {
            int quarter = present_sync.period > 0 ?
                          MAX(4, (int)lround(0.25 / present_sync.period)) : 15;
            if (++present_sync.left_run >= quarter) {
                present_frame_skip(&present_sync.queue[0], present_sync.queued > 1 ?
                                   &present_sync.queue[1] : NULL);
                present_sync.queued--;
                memmove(&present_sync.queue[0], &present_sync.queue[1],
                        sizeof(PresentFrame) * present_sync.queued);
                present_sync.dropped++;
                present_sync.left_run = 0;
            }
        } else {
            present_sync.left_run = 0;
        }
    } else {
        present_sync.left_run = 0;
        if (!present_sync.missed) {
            /* A refresh without a new frame right after one with. */
            present_sync.repeats++;
            present_sync.win_late++;
            present_sync.missed = true;
        }
        if (!present_sync.inflight &&
            now - present_sync.last_ready > PRESENT_IDLE_S) {
            present_sync.linked = false;
            present_sync.close_frames = 0;
            present_sync.merge = false;
            idle = true;
        }
    }
    double secs = now - present_sync.win_start;
    if (!idle && secs >= 1.0) {
        /*
         * If a frame was left over after every tick and none came late, the
         * queue holds a refresh of delay the guest's timing does not need
         * (the guest runs a little faster than the display, or a hiccup
         * filled it). Skip one frame to get the delay back down.
         */
        if (present_sync.win_min >= 1 && present_sync.win_min < INT_MAX &&
            !present_sync.win_late && present_sync.queued) {
            present_frame_skip(&present_sync.queue[0], present_sync.queued > 1 ?
                               &present_sync.queue[1] : NULL);
            present_sync.queued--;
            memmove(&present_sync.queue[0], &present_sync.queue[1],
                    sizeof(PresentFrame) * present_sync.queued);
            present_sync.dropped++;
        }
        /*
         * Merge close frames only while the guest draws clearly faster than
         * the link (e.g. 120 Hz guest, window just moved to a 60 Hz
         * screen). At the link's own rate two close frames are jitter: both
         * are real frames, and merging them would skip one.
         */
        present_sync.merge =
            present_sync.win_flushes > present_sync.win_ticks * 5 / 4;
        if (!present_fixed && present_sync.win_gap2 >= PRESENT_CLOSE_S &&
            !present_sync.queued && !present_sync.inflight) {
            /* Frames came one at a time for a second: no link. */
            present_sync.linked = false;
            present_sync.close_frames = 0;
            present_sync.merge = false;
            idle = true;
        } else if (present_sync.min_hz < present_sync.max_hz) {
            double want = present_wanted_hz();
            if (want < present_sync.hz - 0.5) {
                if (++present_sync.slower >= 2) {
                    present_sync.hz = want;
                    present_sync.slower = 0;
                    rate = true;
                }
            } else {
                present_sync.slower = 0;
                if (want > present_sync.hz + 0.5) {
                    present_sync.hz = want;
                    rate = true;
                }
            }
        }
        trace_cocoa_present_second((int)lround(present_sync.hz),
            T > 0 ? (int)lround(1 / T) : 0, present_sync.ticks,
            present_sync.win_frames, present_sync.shown, present_sync.direct,
            present_sync.shown ?
            (int)(present_sync.wait_sum * 1e6 / present_sync.shown) : 0);
        trace_cocoa_present_skips(present_sync.repeats, present_sync.merged,
                                  present_sync.dropped, present_sync.busy);
        present_sync.ticks = present_sync.shown = present_sync.direct = 0;
        present_sync.repeats = 0;
        present_sync.merged = present_sync.dropped = present_sync.busy = 0;
        present_sync.wait_sum = 0;
        present_window_reset(now);
    }
    os_unfair_lock_unlock(&present_lock);

    if (show.surf || show.pt) {
        present_frame_show(&show);
        present_frame_put(&show);
        /* The guest may have drawn while the queue was full. */
        qemu_bh_schedule(present_bh);
    }
    if (rate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cocoa_gl_present_link_rate();
        });
    }
    return !idle;
}
