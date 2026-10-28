// window-census [PID]: the Mac's displays and Spaces, and PID's windows, for
// tests that count them (#428: a display gone while locked left OmacVM's QEMU
// making full-screen Spaces in a loop). No pixels are read (no Screen
// Recording needed). The Spaces come from SkyLight's private
// CGSCopyManagedDisplaySpaces (as yabai reads them).
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//     -F/System/Library/PrivateFrameworks -framework SkyLight window-census.m -o window-census
//   ./window-census [PID]
//
// Prints, one per line:
//   display ID main|- active|inactive asleep? X,Y WxH
//   builtin ID                            (the Mac's built-in display, when online)
//   spaces N fullscreen F                 (all displays)
//   current ID SPACE TYPE                 (each display's current Space: its id, 4 = full screen;
//                                          ID the display's, or SkyLight's name for it, e.g. Main)
//   windows N layer0 L big B              (PID's: all, layer 0, layer 0 >= 100x100)
//   window NUMBER onscreen|offscreen alpha A X,Y WxH display ID   (each big one)
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

extern int CGSMainConnectionID(void);
extern CFArrayRef CGSCopyManagedDisplaySpaces(int cid);
/* ColorSync's (it was CoreGraphics'): the UUID SkyLight names a display by; looked up at run time. */
typedef CFUUIDRef (*DisplayUUIDFn)(uint32_t display);

int main(int argc, const char **argv)
{
    @autoreleasepool {
        CGDirectDisplayID ids[16];
        uint32_t n = 0;
        CGGetOnlineDisplayList(16, ids, &n);
        for (uint32_t i = 0; i < n; i++) {
            CGRect b = CGDisplayBounds(ids[i]);
            printf("display %u %s %s%s %.0f,%.0f %.0fx%.0f\n", ids[i],
                   CGDisplayIsMain(ids[i]) ? "main" : "-",
                   CGDisplayIsActive(ids[i]) ? "active" : "inactive",
                   CGDisplayIsAsleep(ids[i]) ? " asleep" : "",
                   b.origin.x, b.origin.y, b.size.width, b.size.height);
        }
        for (uint32_t i = 0; i < n; i++) {
            if (CGDisplayIsBuiltin(ids[i])) {
                printf("builtin %u\n", ids[i]);
            }
        }

        int spaces = 0, full = 0;
        NSArray *displays = CFBridgingRelease(CGSCopyManagedDisplaySpaces(CGSMainConnectionID()));
        for (NSDictionary *d in displays) {
            for (NSDictionary *s in d[@"Spaces"]) {
                spaces++;
                full += [s[@"type"] intValue] == 4;   // 4: a full-screen Space
            }
        }
        printf("spaces %d fullscreen %d\n", spaces, full);
        void *colorsync = dlopen("/System/Library/Frameworks/ColorSync.framework/ColorSync", RTLD_LAZY);
        DisplayUUIDFn uuid_of = colorsync ? (DisplayUUIDFn)dlsym(colorsync, "CGDisplayCreateUUIDFromDisplayID") : NULL;
        for (NSDictionary *d in displays) {
            NSDictionary *cur = d[@"Current Space"];
            NSString *name = [d[@"Display Identifier"] description];
            for (uint32_t i = 0; i < n; i++) {
                CFUUIDRef u = uuid_of ? uuid_of(ids[i]) : NULL;
                NSString *us = u ? CFBridgingRelease(CFUUIDCreateString(NULL, u)) : nil;
                if (u) {
                    CFRelease(u);
                }
                if ((us && [us caseInsensitiveCompare:name] == NSOrderedSame) ||
                    ([name isEqualToString:@"Main"] && CGDisplayIsMain(ids[i]))) {
                    name = [NSString stringWithFormat:@"%u", ids[i]];
                    break;
                }
            }
            printf("current %s %lld %d\n", [name UTF8String], [cur[@"id64"] longLongValue],
                   [cur[@"type"] intValue]);
        }

        if (argc < 2) {
            return 0;
        }
        int pid = atoi(argv[1]), all = 0, layer0 = 0, big = 0;
        NSMutableArray *bigs = [NSMutableArray array];
        NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
        for (NSDictionary *w in list) {
            if ([w[(id)kCGWindowOwnerPID] intValue] != pid) {
                continue;
            }
            all++;
            if ([w[(id)kCGWindowLayer] intValue] != 0) {
                continue;
            }
            layer0++;
            CGRect r;
            CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)w[(id)kCGWindowBounds], &r);
            if (r.size.width < 100 || r.size.height < 100) {
                continue;
            }
            big++;
            CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
            CGDirectDisplayID on = 0;
            uint32_t k = 0;
            CGGetDisplaysWithPoint(c, 1, &on, &k);
            [bigs addObject:[NSString stringWithFormat:@"window %d %s alpha %.2f %.0f,%.0f %.0fx%.0f display %u",
                             [w[(id)kCGWindowNumber] intValue],
                             [w[(id)kCGWindowIsOnscreen] boolValue] ? "onscreen" : "offscreen",
                             [w[(id)kCGWindowAlpha] doubleValue],
                             r.origin.x, r.origin.y, r.size.width, r.size.height, k ? on : 0]];
        }
        printf("windows %d layer0 %d big %d\n", all, layer0, big);
        for (NSString *s in bigs) {
            printf("%s\n", [s UTF8String]);
        }
    }
    return 0;
}
