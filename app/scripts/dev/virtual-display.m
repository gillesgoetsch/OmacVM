// A virtual Mac display for testing OmacVM.app's external displays without a
// monitor (CoreGraphics' private CGVirtualDisplay, as BetterDisplay and
// Chromium's tests use it). The display exists while this process runs:
// killing it is unplugging it.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//     virtual-display.m -o virtual-display
//   ./virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y] [--name NAME]
//
// WIDTHxHEIGHT is the size in points; --hidpi gives it 2x pixels (Retina).
// --at puts its top-left corner at X,Y in the Mac's display arrangement
// (points, origin at the main display's top-left). Prints "id=<display id>"
// once the display is up.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <signal.h>

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

int main(int argc, const char **argv)
{
    @autoreleasepool {
        unsigned w = 0, h = 0;
        BOOL hidpi = NO, place = NO;
        int x = 0, y = 0;
        NSString *name = @"OmacVM Test Display";
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--hidpi")) {
                hidpi = YES;
            } else if (!strcmp(argv[i], "--at") && i + 1 < argc) {
                place = sscanf(argv[++i], "%d,%d", &x, &y) == 2;
            } else if (!strcmp(argv[i], "--name") && i + 1 < argc) {
                name = [NSString stringWithUTF8String:argv[++i]];
            } else if (sscanf(argv[i], "%ux%u", &w, &h) != 2) {
                fprintf(stderr, "usage: virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y] [--name NAME]\n");
                return 2;
            }
        }
        if (!w || !h) {
            fprintf(stderr, "usage: virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y] [--name NAME]\n");
            return 2;
        }
        unsigned k = hidpi ? 2 : 1;
        CGVirtualDisplayDescriptor *d = [[CGVirtualDisplayDescriptor alloc] init];
        d.queue = dispatch_get_main_queue();
        d.name = name;
        d.maxPixelsWide = w * k;
        d.maxPixelsHigh = h * k;
        // About 110 points per inch, like a normal desktop monitor.
        d.sizeInMillimeters = CGSizeMake(w * 25.4 / 110.0, h * 25.4 / 110.0);
        d.vendorID = 0x0ac7;  // made up
        d.productID = 0x1234 + (getpid() & 0xff);
        d.serialNum = getpid();
        d.terminationHandler = ^(id a, CGVirtualDisplay *b) { exit(0); };
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        if (!display) {
            fprintf(stderr, "virtual-display: could not create the display\n");
            return 1;
        }
        CGVirtualDisplaySettings *s = [[CGVirtualDisplaySettings alloc] init];
        s.hiDPI = hidpi;
        // The mode is in points; with hiDPI macOS backs it with 2x pixels.
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        if (![display applySettings:s]) {
            fprintf(stderr, "virtual-display: settings refused\n");
            return 1;
        }
        CGDirectDisplayID id = display.displayID;
        if (place) {
            // The new display needs a moment before it can be placed.
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            CGDisplayConfigRef config;
            if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
                CGConfigureDisplayOrigin(config, id, x, y);
                CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            }
        }
        signal(SIGTERM, quit);
        signal(SIGINT, quit);
        printf("id=%u\n", id);
        fflush(stdout);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
