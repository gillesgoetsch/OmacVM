/*
 * 3.2.16's decisions behind the API of ui/omacvm-present-volatile.h, for
 * test-present-volatile.sh --self-test: every surface is kept while the
 * window is out of sight, so the rule's checks must fail with it. Not used
 * by QEMU.
 */
#ifndef OMACVM_PRESENT_VOLATILE_STUB_H
#define OMACVM_PRESENT_VOLATILE_STUB_H

#include <stdbool.h>
#include <stdint.h>

#define OMACVM_PV_SURFACES 8
#define OMACVM_PV_AFTER_MS 2000

typedef struct OmacvmPresentVolatile {
    bool off, away;
    int64_t away_ms;
    unsigned n;
    bool vol[OMACVM_PV_SURFACES];
    unsigned made, emptied;
} OmacvmPresentVolatile;

static inline void omacvm_pv_reset(OmacvmPresentVolatile *v, unsigned n) { v->n = n; }
static inline void omacvm_pv_sight(OmacvmPresentVolatile *v, bool seen, int64_t now_ms)
{
    v->away = !seen;
    (void)now_ms;
}
static inline bool omacvm_pv_idle(const OmacvmPresentVolatile *v) { (void)v; return true; }
/* 3.2.16: all five stay, out of sight too. */
static inline int omacvm_pv_step(const OmacvmPresentVolatile *v, unsigned i, bool busy, int64_t now_ms)
{
    (void)v; (void)i; (void)busy; (void)now_ms;
    return 0;
}
static inline void omacvm_pv_made(OmacvmPresentVolatile *v, unsigned i, bool ok) { (void)v; (void)i; (void)ok; }
static inline bool omacvm_pv_needed(const OmacvmPresentVolatile *v, unsigned i) { (void)v; (void)i; return false; }
static inline bool omacvm_pv_back(OmacvmPresentVolatile *v, unsigned i, bool emptied)
{
    (void)v; (void)i;
    return emptied;
}

#endif
