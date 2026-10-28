/*
 * 3.2.10's decisions behind the API of ui/omacvm-fullpanel-retake.h, for
 * test-fullpanel-retake.sh --self-test: the user's rows must fail with them
 * (the strip stays below the notch). Not used by QEMU.
 */
#ifndef OMACVM_FULLPANEL_RETAKE_STUB_H
#define OMACVM_FULLPANEL_RETAKE_STUB_H

#include <stdbool.h>
#include <stddef.h>

#include "omacvm-fullpanel.h"

#define OMACVM_FP_RETAKE_TRIES 3
#define OMACVM_FP_RETAKE_CHECK_S 2.0
#define OMACVM_FP_BAND_SLACK 8.0
/* 3.2.10's claim waited for -screenChanged:'s resume (!released). */
#define OMACVM_FP_CLAIMS_WAIT_FOR_RESUME 1

static inline bool omacvm_fp_inside(OmacVMFPRect f, OmacVMFPRect d)
{
    return f.x >= d.x - 0.5 && f.y >= d.y - 0.5 &&
           f.x + f.w <= d.x + d.w + 0.5 && f.y + f.h <= d.y + d.h + 0.5;
}

typedef enum {
    OMACVM_FP_FRAME_COVERS,
    OMACVM_FP_FRAME_DISPLACED,
    OMACVM_FP_FRAME_LOST,
    OMACVM_FP_FRAME_WAIT,
} OmacVMFPFrameKind;

/* 3.2.10: omacvm_fp_lost(accepted, true, covers, display_unchanged). */
static inline OmacVMFPFrameKind omacvm_fp_frame_kind(bool covers, bool inside, bool display_live,
                                                     bool same_display, bool changing)
{
    (void)inside;
    (void)display_live;
    (void)changing;
    if (covers) {
        return OMACVM_FP_FRAME_COVERS;
    }
    return omacvm_fp_lost(true, true, covers, same_display) ? OMACVM_FP_FRAME_LOST
                                                            : OMACVM_FP_FRAME_WAIT;
}

static inline bool omacvm_fp_lost_to_display_change(bool lost, double since, bool display_changed)
{
    (void)lost;
    (void)since;
    (void)display_changed;
    return false;
}

static inline bool omacvm_fp_claims(bool inside, bool armed, bool rejected, bool lost,
                                    bool menu_failed, bool notch)
{
    return inside && armed && !rejected && !lost && !menu_failed && notch;
}

static inline bool omacvm_fp_band_kept(OmacVMFPRect frame, OmacVMFPRect display, double notch)
{
    (void)frame;
    (void)display;
    (void)notch;
    return false;
}

typedef struct {
    bool inside, armed, entered, rejected, lost, display_changed, given_up;
    int tries;
    bool tried_this_settle, pending, notch, covers, band_kept, display_live, same_size;
    bool on_space, visible, in_place, locked, moving, menu_bar_in_the_way, parts, reshape;
    bool appkit_band;
} OmacVMFPRetakeFacts;

typedef enum {
    OMACVM_FP_RETAKE_NOW,
    OMACVM_FP_RETAKE_WAIT,
    OMACVM_FP_RETAKE_NO,
    OMACVM_FP_RETAKE_GIVE_UP,
} OmacVMFPRetake;

/* 3.2.10 never laid a full screen out again. */
static inline OmacVMFPRetake omacvm_fp_retake(OmacVMFPRetakeFacts f, const char **why)
{
    (void)f;
    if (why) {
        *why = "3.2.10 has no retake";
    }
    return OMACVM_FP_RETAKE_NO;
}

static inline bool omacvm_fp_retake_final(int tries)
{
    return tries >= OMACVM_FP_RETAKE_TRIES;
}

#endif
