// The MacBook's built-in display gone for a while and back, as when its lid
// is shut with an external display on and opened again (the user's M4 Max,
// 2026-10-28: the strip beside the notch stayed away after that). For
// src/tests/e2e/display-unplug.sh (case fullpanel-builtin, --builtin-off) on
// a notched test Mac with another display on (a virtual one will do),
// unlocked and nobody at it.
//
//   clang -fobjc-arc -framework AppKit -framework CoreGraphics \
//     builtin-display.m -o builtin-display
//   ./builtin-display mode           the built-in's id, mode, frame, notch (reads only)
//   ./builtin-display off SECONDS    the built-in off for SECONDS (1-120), then on again
//   ./builtin-display on ID          display ID on (for the session), e.g. a built-in left off
//
// The built-in goes off kCGConfigureForAppOnly. That alone did not bring it
// back on the M1 Max on 2026-11-08 (display-unplug.sh killed "off 120" and it
// stayed off 04:44-04:50; on again with CGSConfigureDisplayEnabled for the
// session, the way "on" does it). So "off" turns it on itself at the end
// and on SIGTERM, SIGINT and SIGHUP, waits up to 5 s for it in the active
// list, tries once more for the session, and says loudly and exits 7 when
// it is still off. A SIGKILL leaves it to the caller: `on ID` (an off
// display is not even online, so the caller keeps the id from "mode").
// Refuses when the built-in is the only active display. Prints the
// built-in's mode before and after: a test that sees it change says so and
// leaves it (macOS keeps a mode per set of displays).
//
// --dry-run[=ok|stuck|session] after the command: no display is changed; a
// made-up built-in (id 1, beside one other display) that comes back (ok),
// never comes back (stuck) or only for the session (session). For the tests
// (src/tests/e2e-builtin-display.sh). With OMACVM_BDISP_DRY_ONLY set, "off"
// and "on" without --dry-run are refused (exit 9).
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <signal.h>

typedef CGError (*EnableFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);

enum { REAL, DRY_OK, DRY_STUCK, DRY_SESSION };
static int dry = REAL;
static bool dry_on = true;
static EnableFn enable_fn;

static CGDirectDisplayID builtin(uint32_t *active_count)
{
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    CGDirectDisplayID b = 0;

    if (dry) {
        *active_count = dry_on ? 2 : 1;
        return dry_on ? 1 : 0;
    }
    CGGetActiveDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayIsBuiltin(ids[i])) {
            b = ids[i];
        }
    }
    *active_count = n;
    return b;
}

static bool is_active(CGDirectDisplayID id)
{
    CGDirectDisplayID ids[16];
    uint32_t n = 0;

    if (dry) {
        return id == 1 && dry_on;
    }
    CGGetActiveDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        if (ids[i] == id) {
            return true;
        }
    }
    return false;
}

static void show(const char *when)
{
    uint32_t n;
    CGDirectDisplayID b = builtin(&n);
    double notch = 0;

    if (dry) {
        printf(b ? "%s builtin=1 mode=1512x982 dry-run active=%u\n" : "%s builtin=none active=%u\n", when, n);
        fflush(stdout);
        return;
    }
    for (NSScreen *s in [NSScreen screens]) {
        if ([[[s deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue] == b) {
            notch = [s safeAreaInsets].top;
        }
    }
    if (!b) {
        printf("%s builtin=none active=%u\n", when, n);
        fflush(stdout);
        return;
    }
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(b);
    CGRect r = CGDisplayBounds(b);
    printf("%s builtin=%u mode=%zux%zu px=%zux%zu bounds=%.0f,%.0f %.0fx%.0f notch=%.0f active=%u\n", when, b,
           m ? CGDisplayModeGetWidth(m) : 0, m ? CGDisplayModeGetHeight(m) : 0,
           m ? CGDisplayModeGetPixelWidth(m) : 0, m ? CGDisplayModeGetPixelHeight(m) : 0,
           r.origin.x, r.origin.y, r.size.width, r.size.height, notch, n);
    if (m) {
        CGDisplayModeRelease(m);
    }
    fflush(stdout);
}

// Display ID on or off; 0 when the change was made.
static int set_enabled(CGDirectDisplayID id, bool on, CGConfigureOption how)
{
    CGDisplayConfigRef cfg;

    if (dry) {
        printf("dry-run: display %u %s (%s)\n", id, on ? "on" : "off", how == kCGConfigureForSession ? "session" : "app only");
        if (!on) {
            dry_on = false;
        } else if (dry == DRY_OK || (dry == DRY_SESSION && how == kCGConfigureForSession)) {
            dry_on = true;
        }
        return 0;
    }
    if (CGBeginDisplayConfiguration(&cfg)) {
        return 1;
    }
    if (enable_fn(cfg, id, on)) {
        CGCancelDisplayConfiguration(cfg);
        return 1;
    }
    return CGCompleteDisplayConfiguration(cfg, how) ? 1 : 0;
}

static bool wait_active(CGDirectDisplayID id, double secs)
{
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];

    while (!is_active(id)) {
        if ([end timeIntervalSinceNow] <= 0) {
            return false;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    }
    return true;
}

// Display ID on again and seen in the active list; else a loud line and false.
static bool turn_on(CGDirectDisplayID id, bool app_only_first)
{
    if (app_only_first) {
        if (set_enabled(id, true, kCGConfigureForAppOnly)) {
            fprintf(stderr, "could not turn display %u on (app only): trying for the session\n", id);
        } else if (wait_active(id, 5)) {
            return true;
        } else {
            fprintf(stderr, "display %u not back 5 s after turning it on (app only): trying for the session\n", id);
        }
    }
    if (!set_enabled(id, true, kCGConfigureForSession) && wait_active(id, 5)) {
        return true;
    }
    fprintf(stderr, "\n*** THE DISPLAY %u IS STILL OFF: builtin-display on %u, or close the lid and open it ***\n\n", id, id);
    return false;
}

static dispatch_source_t on_signal(int sig, void (^handler)(void))
{
    signal(sig, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, handler);
    dispatch_resume(src);
    return src;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc >= 2 && !strncmp(argv[argc - 1], "--dry-run", 9)) {
            const char *how = argv[argc - 1] + 9;
            dry = !*how || !strcmp(how, "=ok") ? DRY_OK : !strcmp(how, "=stuck") ? DRY_STUCK
                : !strcmp(how, "=session") ? DRY_SESSION : -1;
            if (dry < 0) {
                fprintf(stderr, "--dry-run=ok|stuck|session\n");
                return 2;
            }
            argc--;
        }
        if (argc == 2 && !strcmp(argv[1], "mode")) {
            show("now");
            return 0;
        }
        if (argc != 3 || (strcmp(argv[1], "off") && strcmp(argv[1], "on"))) {
            fprintf(stderr, "usage: builtin-display mode | off SECONDS | on ID [--dry-run[=ok|stuck|session]]\n");
            return 2;
        }
        if (!dry && getenv("OMACVM_BDISP_DRY_ONLY")) {
            fprintf(stderr, "refused: OMACVM_BDISP_DRY_ONLY is set (a test): only --dry-run\n");
            return 9;
        }
        if (!dry) {
            void *sl = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
            enable_fn = sl ? (EnableFn)dlsym(sl, "CGSConfigureDisplayEnabled") : NULL;
            if (!enable_fn) {
                fprintf(stderr, "CGSConfigureDisplayEnabled is not there\n");
                return 4;
            }
        }
        if (!strcmp(argv[1], "on")) {
            char *e;
            unsigned long id = strtoul(argv[2], &e, 10);
            if (!*argv[2] || *e || !id || id > UINT32_MAX) {
                fprintf(stderr, "ID: a display id (builtin=ID in \"mode\")\n");
                return 2;
            }
            if (dry) {
                dry_on = false;   // as left off
            }
            if (!turn_on((CGDirectDisplayID)id, false)) {
                return 7;
            }
            show("after");
            return 0;
        }

        int secs = atoi(argv[2]);
        uint32_t n;
        CGDirectDisplayID b;

        if (secs < 1 || secs > 120) {
            fprintf(stderr, "SECONDS: 1-120\n");
            return 2;
        }
        b = builtin(&n);
        if (!b || n < 2) {
            fprintf(stderr, "refused: no built-in display, or it is the only active one (%u)\n", n);
            return 3;
        }
        // From here a stop by signal turns the built-in on again before the end.
        __block int stopped = 0;
        dispatch_source_t s1 = on_signal(SIGTERM, ^{ stopped = SIGTERM; });
        dispatch_source_t s2 = on_signal(SIGINT, ^{ stopped = SIGINT; });
        dispatch_source_t s3 = on_signal(SIGHUP, ^{ stopped = SIGHUP; });
        show("before");
        if (set_enabled(b, false, kCGConfigureForAppOnly)) {
            fprintf(stderr, "could not turn the built-in off\n");
            return 5;
        }
        printf("off %d s\n", secs);
        fflush(stdout);
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
        while (!stopped && [end timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        if (stopped) {
            printf("stopped (signal %d): the built-in on again\n", stopped);
            fflush(stdout);
        }
        if (!turn_on(b, true)) {
            return 7;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:dry ? 0 : 3]];
        show("after");
        (void)s1, (void)s2, (void)s3;
    }
    return 0;
}
