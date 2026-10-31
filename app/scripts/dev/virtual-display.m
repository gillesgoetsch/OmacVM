// A virtual Mac display for testing OmacVM.app's external displays without a
// monitor (CoreGraphics' private CGVirtualDisplay, as BetterDisplay and
// Chromium's tests use it). The display exists while this process runs:
// killing it is unplugging it.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//     virtual-display.m -o virtual-display
//   ./virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y | --main] [--name NAME] [--serial N]
//                     [--max-seconds S] [--while-locked [--unlock-note NAME] [--kill-app PATH] [--dry-run]]
//   ./virtual-display --list | --lock-state | --post-note NAME
//
// WIDTHxHEIGHT is the size in points; --hidpi gives it 2x pixels (Retina).
// --at puts its top-left corner at X,Y in the Mac's display arrangement
// (points, origin at the main display's top-left). --main makes it the main
// display (the menu bar): the whole arrangement moves so that it sits at
// the origin. --serial gives it that serial number (default: the pid; the
// same serial is the same monitor to macOS). Prints "id=<display id>"
// once the display is up. --max-seconds: it goes by itself after S seconds.
//
// While it runs (#428: a display that goes for a moment):
//   kill -USR1  unplugs it (the process stays)   prints "state=off"
//   kill -USR2  plugs the same display in again  prints "state=on id=<display id>"
//   kill -HUP   to a 1 x 1 mode and back (macOS shows a waking display like
//               that for a few seconds)          prints "state=tiny ..." / "state=on ..."
//
// --while-locked: only for a Mac nobody is at (src/tests/e2e/present-locked.sh).
// A window on this display cannot be seen while the session is locked; once
// someone unlocks, macOS would move it to their display. So it refuses to start
// unless the session is locked (CoreGraphics' session and the IORegistry's
// console user both say so; exit 3), and it ends when the session unlocks
// (macOS's com.apple.screenIsUnlocked notice, or the lock read every 0.5 s),
// when the process that started it ends, or after --max-seconds (default 2700
// with --while-locked). Before the display goes, every process run from inside
// --kill-app PATH (the test app, org.omacvm.app.test only) is killed, so none of
// its windows reaches a real display. Prints "killed=N" (with --kill-app) and
// "quit=WHY", then exits: 0 stopped (TERM, INT), 4 unlocked, 5 the parent
// ended, 6 lifetime over.
// Tests: --unlock-note NAME listens for NAME instead of macOS's notice, which
// nobody else may post (the person's app and QEMU's lock watch listen to it);
// --post-note NAME posts such a notice (org.omacvm.test.* only). --dry-run makes
// no display and reads the lock from OMACVM_TEST_LOCKED (1, 0, or file:PATH
// whose first character is 1 while "locked"); that variable is refused
// without --dry-run.
// --list: every online display, one line each (id, built-in, main, active,
// asleep, vendor, model, serial, bounds in points, mode in pixels, refresh).
// --lock-state: "cg=yes|no|nosession io=yes|no|noconsole"; exit 0 when both say locked.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static void quit(int sig) { exit(0); }

static unsigned w, h, serial;
static BOOL hidpi, place, makeMain, tiny;
static int x, y;
static NSString *name;
static CGVirtualDisplay *display;

#define USAGE "usage: virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y | --main] [--name NAME] [--serial N] " \
              "[--max-seconds S] [--while-locked [--unlock-note NAME] [--kill-app PATH] [--dry-run]]\n" \
              "       virtual-display --list | --lock-state | --post-note NAME\n"

static BOOL apply(unsigned mw, unsigned mh)
{
    CGVirtualDisplaySettings *s = [[CGVirtualDisplaySettings alloc] init];
    s.hiDPI = hidpi && mw > 1;
    // The mode is in points; with hiDPI macOS backs it with 2x pixels.
    s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:mw height:mh refreshRate:60]];
    return [display applySettings:s];
}

static CGDirectDisplayID plug(void)
{
    unsigned k = hidpi ? 2 : 1;
    CGVirtualDisplayDescriptor *d = [[CGVirtualDisplayDescriptor alloc] init];
    d.queue = dispatch_get_main_queue();
    d.name = name;
    d.maxPixelsWide = w * k;
    d.maxPixelsHigh = h * k;
    // About 110 points per inch, like a normal desktop monitor.
    d.sizeInMillimeters = CGSizeMake(w * 25.4 / 110.0, h * 25.4 / 110.0);
    d.vendorID = 0x0ac7;  // made up
    d.productID = 0x1234 + (serial & 0xff);
    d.serialNum = serial;
    d.terminationHandler = ^(id a, CGVirtualDisplay *b) { exit(0); };
    display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
    if (!display) {
        fprintf(stderr, "virtual-display: could not create the display\n");
        return 0;
    }
    if (!apply(w, h)) {
        fprintf(stderr, "virtual-display: settings refused\n");
        return 0;
    }
    CGDirectDisplayID id = display.displayID;
    if (makeMain) {
        // The main display is the one at (0,0): move every display by this one's place.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        CGRect self_ = CGDisplayBounds(id);
        CGDirectDisplayID all[16];
        uint32_t n = 0;
        CGDisplayConfigRef config;
        if (CGGetOnlineDisplayList(16, all, &n) == kCGErrorSuccess &&
            CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            for (uint32_t i = 0; i < n; i++) {
                CGRect b = CGDisplayBounds(all[i]);
                CGConfigureDisplayOrigin(config, all[i], (int32_t)(b.origin.x - self_.origin.x),
                                         (int32_t)(b.origin.y - self_.origin.y));
            }
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
    }
    if (place) {
        // The new display needs a moment before it can be placed.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(config, id, x, y);
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
    }
    return id;
}

static void state(const char *what)
{
    CGDirectDisplayID id = display ? display.displayID : 0;
    // macOS takes a moment to show the change.
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    CGRect b = id ? CGDisplayBounds(id) : CGRectZero;
    printf("state=%s id=%u active=%d size=%.0fx%.0f\n", what, id,
           id ? (int)CGDisplayIsActive(id) : 0, b.size.width, b.size.height);
    fflush(stdout);
}

static dispatch_source_t on_signal(int sig, void (^handler)(void))
{
    signal(sig, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0,
                                                   dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, handler);
    dispatch_resume(src);
    return src;
}

// --list: every online display.
static void list_displays(void)
{
    CGDirectDisplayID ids[32];
    uint32_t n = 0;
    CGGetOnlineDisplayList(32, ids, &n);
    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID id = ids[i];
        CGRect b = CGDisplayBounds(id);
        size_t pw = 0, ph = 0;
        double hz = 0;
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(id);
        if (m) {
            pw = CGDisplayModeGetPixelWidth(m);
            ph = CGDisplayModeGetPixelHeight(m);
            hz = CGDisplayModeGetRefreshRate(m);
            CGDisplayModeRelease(m);
        }
        printf("display %u builtin=%d main=%d active=%d asleep=%d vendor=0x%x model=0x%x serial=0x%x "
               "bounds=%.0f,%.0f,%.0fx%.0f px=%zux%zu hz=%.0f\n",
               id, CGDisplayIsBuiltin(id), CGDisplayIsMain(id), CGDisplayIsActive(id), CGDisplayIsAsleep(id),
               CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id),
               b.origin.x, b.origin.y, b.size.width, b.size.height, pw, ph, hz);
    }
}

// The session's lock, from CoreGraphics: "yes", "no", or "nosession".
static const char *lock_cg(void)
{
    NSDictionary *d = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    if (!d) {
        return "nosession";
    }
    return [d[@"CGSSessionScreenIsLocked"] boolValue] ? "yes" : "no";
}

// The same from the IORegistry's console user (IOConsoleUsers): "yes", "no",
// or "noconsole" (nobody on the console: the login window, a user switch).
// IOKit is looked up at run time, so the build line stays the same.
static const char *lock_io(void)
{
    typedef mach_port_t (*RootFn)(mach_port_t);
    typedef CFTypeRef (*PropFn)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t);
    typedef int (*ReleaseFn)(mach_port_t);
    static RootFn root_of;
    static PropFn prop_of;
    static ReleaseFn release;
    if (!root_of) {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        root_of = iokit ? (RootFn)dlsym(iokit, "IORegistryGetRootEntry") : NULL;
        prop_of = iokit ? (PropFn)dlsym(iokit, "IORegistryEntryCreateCFProperty") : NULL;
        release = iokit ? (ReleaseFn)dlsym(iokit, "IOObjectRelease") : NULL;
        if (!root_of || !prop_of || !release) {
            root_of = NULL;
            return "noconsole";
        }
    }
    mach_port_t root = root_of(MACH_PORT_NULL);
    if (!root) {
        return "noconsole";
    }
    NSArray *users = CFBridgingRelease(prop_of(root, CFSTR("IOConsoleUsers"), kCFAllocatorDefault, 0));
    release(root);
    for (NSDictionary *u in users) {
        if ([u isKindOfClass:[NSDictionary class]] && [u[@"kCGSSessionOnConsoleKey"] boolValue]) {
            return [u[@"CGSSessionScreenIsLocked"] boolValue] ? "yes" : "no";
        }
    }
    return "noconsole";
}

static BOOL real_locked(void) { return !strcmp(lock_cg(), "yes") && !strcmp(lock_io(), "yes"); }

// --while-locked
static BOOL whileLocked, dryRun, finishing;
static double maxSeconds = -1;
static NSString *unlockNote = @"com.apple.screenIsUnlocked";
static char killApp[PATH_MAX];
static const char *testLocked;   // OMACVM_TEST_LOCKED (with --dry-run only)
static pid_t parent0;
static CFAbsoluteTime started;

static BOOL session_locked(void)
{
    if (!dryRun) {
        return real_locked();
    }
    if (!strncmp(testLocked, "file:", 5)) {
        FILE *f = fopen(testLocked + 5, "r");
        int c = f ? fgetc(f) : EOF;
        if (f) {
            fclose(f);
        }
        return c == '1';
    }
    return !strcmp(testLocked, "1");
}

// Every process run from inside the test app, killed; waits up to 0.5 s for
// them to be gone (their windows go with them). Returns how many.
static int kill_app(void)
{
    if (!killApp[0]) {
        return 0;
    }
    size_t len = strlen(killApp);
    int cap = proc_listallpids(NULL, 0);
    if (cap <= 0) {
        return 0;
    }
    cap += 64;
    pid_t *pids = calloc((size_t)cap, sizeof(pid_t));
    int n = pids ? proc_listallpids(pids, cap * (int)sizeof(pid_t)) : 0;
    pid_t gone[256];
    int k = 0;
    for (int i = 0; i < n; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (pids[i] <= 1 || pids[i] == getpid() || proc_pidpath(pids[i], path, sizeof(path)) <= 0) {
            continue;
        }
        if (!strncmp(path, killApp, len) && path[len] == '/' && kill(pids[i], SIGKILL) == 0 && k < 256) {
            gone[k++] = pids[i];
        }
    }
    free(pids);
    for (int t = 0; t < 50; t++) {
        int left = 0;
        for (int j = 0; j < k; j++) {
            left += kill(gone[j], 0) == 0;
        }
        if (!left) {
            break;
        }
        usleep(10000);
    }
    return k;
}

// The end of a --while-locked run: the test app first, then the display.
static void finish(const char *why, int code)
{
    if (finishing) {
        return;
    }
    finishing = YES;
    if (killApp[0]) {
        printf("killed=%d\n", kill_app());
        fflush(stdout);
    }
    display = nil;   // released: unplugged
    printf("quit=%s\n", why);
    fflush(stdout);
    exit(code);
}

static int post_note(const char *note)
{
    if (strncmp(note, "org.omacvm.test.", 16) != 0) {
        fprintf(stderr, "virtual-display: --post-note posts only test notices (org.omacvm.test.*)\n");
        return 2;
    }
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:[NSString stringWithUTF8String:note]
                                                                   object:nil
                                                                 userInfo:nil
                                                       deliverImmediately:YES];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    return 0;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        name = @"OmacVM Test Display";
        serial = (unsigned)getpid();
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--list") && argc == 2) {
                list_displays();
                return 0;
            } else if (!strcmp(argv[i], "--lock-state") && argc == 2) {
                const char *cg = lock_cg(), *io = lock_io();
                printf("cg=%s io=%s\n", cg, io);
                return !strcmp(cg, "yes") && !strcmp(io, "yes") ? 0 : 1;
            } else if (!strcmp(argv[i], "--post-note") && i + 1 < argc && argc == 3) {
                return post_note(argv[i + 1]);
            } else if (!strcmp(argv[i], "--hidpi")) {
                hidpi = YES;
            } else if (!strcmp(argv[i], "--main")) {
                makeMain = YES;
            } else if (!strcmp(argv[i], "--while-locked")) {
                whileLocked = YES;
            } else if (!strcmp(argv[i], "--dry-run")) {
                dryRun = YES;
            } else if (!strcmp(argv[i], "--at") && i + 1 < argc) {
                place = sscanf(argv[++i], "%d,%d", &x, &y) == 2;
            } else if (!strcmp(argv[i], "--name") && i + 1 < argc) {
                name = [NSString stringWithUTF8String:argv[++i]];
            } else if (!strcmp(argv[i], "--serial") && i + 1 < argc) {
                serial = (unsigned)strtoul(argv[++i], NULL, 0);
            } else if (!strcmp(argv[i], "--max-seconds") && i + 1 < argc) {
                maxSeconds = strtod(argv[++i], NULL);
            } else if (!strcmp(argv[i], "--unlock-note") && i + 1 < argc) {
                unlockNote = [NSString stringWithUTF8String:argv[++i]];
            } else if (!strcmp(argv[i], "--kill-app") && i + 1 < argc) {
                if (!realpath(argv[++i], killApp)) {
                    fprintf(stderr, "virtual-display: --kill-app %s: no such app\n", argv[i]);
                    return 2;
                }
            } else if (sscanf(argv[i], "%ux%u", &w, &h) != 2) {
                fprintf(stderr, USAGE);
                return 2;
            }
        }
        if (!w || !h) {
            fprintf(stderr, USAGE);
            return 2;
        }
        testLocked = getenv("OMACVM_TEST_LOCKED");
        if (testLocked && !dryRun) {
            fprintf(stderr, "virtual-display: OMACVM_TEST_LOCKED only with --dry-run\n");
            return 2;
        }
        if ((dryRun || killApp[0] || ![unlockNote isEqualToString:@"com.apple.screenIsUnlocked"]) && !whileLocked) {
            fprintf(stderr, "virtual-display: --dry-run, --kill-app and --unlock-note go with --while-locked\n");
            return 2;
        }
        if (dryRun && !testLocked) {
            fprintf(stderr, "virtual-display: --dry-run reads the lock from OMACVM_TEST_LOCKED (1, 0 or file:PATH)\n");
            return 2;
        }
        if (killApp[0]) {
            NSString *plist = [NSString stringWithFormat:@"%s/Contents/Info.plist", killApp];
            NSString *bid = [NSDictionary dictionaryWithContentsOfFile:plist][@"CFBundleIdentifier"];
            if (![bid isEqual:@"org.omacvm.app.test"]) {
                fprintf(stderr, "virtual-display: --kill-app takes only the test app (org.omacvm.app.test), not %s\n",
                        bid ? [bid UTF8String] : "a bundle without an id");
                return 2;
            }
        }
        if (whileLocked) {
            parent0 = getppid();
            if (parent0 <= 1) {
                fprintf(stderr, "virtual-display: --while-locked needs the process that starts it to stay (it ends with it)\n");
                return 2;
            }
            if (!session_locked()) {
                fprintf(stderr, "virtual-display: the session is not locked (cg=%s io=%s): no display\n",
                        dryRun ? "test" : lock_cg(), dryRun ? "test" : lock_io());
                return 3;
            }
            if (maxSeconds < 0) {
                maxSeconds = 2700;
            }
        }
        started = CFAbsoluteTimeGetCurrent();
        CGDirectDisplayID id = 0;
        if (!dryRun) {
            id = plug();
            if (!id) {
                return 1;
            }
        }
        dispatch_source_t s1 = on_signal(SIGUSR1, ^{
            display = nil;   // released: unplugged
            tiny = NO;
            state("off");
        });
        dispatch_source_t s2 = on_signal(SIGUSR2, ^{
            if (!display && !dryRun && plug()) {
                state("on");
            }
        });
        dispatch_source_t s3 = on_signal(SIGHUP, ^{
            if (!display) {
                return;
            }
            tiny = !tiny;
            if (!apply(tiny ? 1 : w, tiny ? 1 : h)) {
                fprintf(stderr, "virtual-display: %s mode refused\n", tiny ? "1 x 1" : "its");
                tiny = !tiny;
            }
            state(tiny ? "tiny" : "on");
        });
        (void)s1; (void)s2; (void)s3;
        dispatch_source_t t = nil, pe = nil, st = nil, si = nil;
        if (whileLocked) {
            [[NSDistributedNotificationCenter defaultCenter] addObserverForName:unlockNote
                                                                         object:nil
                                                                          queue:[NSOperationQueue mainQueue]
                                                                     usingBlock:^(NSNotification *note) {
                finish("unlocked how=notice", 4);
            }];
            // The lock read again every 0.5 s (a notice can be missed), the parent, the lifetime.
            t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 2,
                                      NSEC_PER_SEC / 50);
            dispatch_source_set_event_handler(t, ^{
                if (!session_locked()) {
                    finish("unlocked how=poll", 4);
                } else if (getppid() != parent0) {
                    finish("parent gone", 5);
                } else if (CFAbsoluteTimeGetCurrent() - started >= maxSeconds) {
                    finish("lifetime", 6);
                }
            });
            dispatch_resume(t);
            pe = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent0, DISPATCH_PROC_EXIT,
                                        dispatch_get_main_queue());
            dispatch_source_set_event_handler(pe, ^{ finish("parent gone", 5); });
            dispatch_resume(pe);
            st = on_signal(SIGTERM, ^{ finish("stopped", 0); });
            si = on_signal(SIGINT, ^{ finish("stopped", 0); });
        } else {
            signal(SIGTERM, quit);
            signal(SIGINT, quit);
            if (maxSeconds > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(maxSeconds * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ exit(0); });
            }
        }
        (void)t; (void)pe; (void)st; (void)si;
        if (dryRun) {
            printf("id=0 dry-run\n");
        } else {
            printf("id=%u\n", id);
        }
        fflush(stdout);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
