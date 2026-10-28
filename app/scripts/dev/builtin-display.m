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
//   ./builtin-display off SECONDS    the built-in off for SECONDS (1-60), then on again
//
// The change is made kCGConfigureForAppOnly: macOS puts it back when this
// process ends, also when it is killed. Refuses when the built-in is the
// only active display. Prints the built-in's mode before and after: a test
// that sees it change says so and leaves it (macOS keeps a mode per set of
// displays).
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>

typedef CGError (*EnableFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);

static CGDirectDisplayID builtin(uint32_t *active_count)
{
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    CGDirectDisplayID b = 0;

    CGGetActiveDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayIsBuiltin(ids[i])) {
            b = ids[i];
        }
    }
    *active_count = n;
    return b;
}

static void show(const char *when)
{
    uint32_t n;
    CGDirectDisplayID b = builtin(&n);
    double notch = 0;

    for (NSScreen *s in [NSScreen screens]) {
        if ([[[s deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue] == b) {
            notch = [s safeAreaInsets].top;
        }
    }
    if (!b) {
        printf("%s builtin=none active=%u\n", when, n);
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

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc >= 2 && !strcmp(argv[1], "mode")) {
            show("now");
            return 0;
        }
        if (argc < 3 || strcmp(argv[1], "off")) {
            fprintf(stderr, "usage: builtin-display mode | off SECONDS\n");
            return 2;
        }
        int secs = atoi(argv[2]);
        uint32_t n;
        CGDirectDisplayID b = builtin(&n);
        void *sl = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        EnableFn enable = sl ? (EnableFn)dlsym(sl, "CGSConfigureDisplayEnabled") : NULL;
        CGDisplayConfigRef cfg;

        if (secs < 1 || secs > 60) {
            fprintf(stderr, "SECONDS: 1-60\n");
            return 2;
        }
        if (!b || n < 2) {
            fprintf(stderr, "refused: no built-in display, or it is the only active one (%u)\n", n);
            return 3;
        }
        if (!enable) {
            fprintf(stderr, "CGSConfigureDisplayEnabled is not there\n");
            return 4;
        }
        show("before");
        if (CGBeginDisplayConfiguration(&cfg) || enable(cfg, b, false) ||
            CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly)) {
            fprintf(stderr, "could not turn the built-in off\n");
            return 5;
        }
        printf("off %d s\n", secs);
        fflush(stdout);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
        if (CGBeginDisplayConfiguration(&cfg) || enable(cfg, b, true) ||
            CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly)) {
            fprintf(stderr, "could not turn the built-in on: exiting puts it back\n");
            return 6;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
        show("after");
    }
    return 0;
}
