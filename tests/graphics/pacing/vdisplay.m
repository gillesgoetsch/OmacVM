// vdisplay W H HZ SECONDS: a virtual display (CGVirtualDisplay, private API) for pacing tests at
// refresh rates no real display here has (e.g. 144 Hz). Lives for SECONDS, prints its display id.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain) dispatch_queue_t queue; @property(retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh; @property CGSize sizeInMillimeters;
@property unsigned int productID, vendorID, serialNum;
@property(copy) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain) NSArray *modes; @property unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property(readonly) unsigned int displayID;
@end
int main(int argc, char **argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    unsigned w = atoi(argv[1]), h = atoi(argv[2]); double hz = atof(argv[3]); double secs = atof(argv[4]);
    CGVirtualDisplayDescriptor *d = [[CGVirtualDisplayDescriptor alloc] init];
    d.queue = dispatch_get_main_queue(); d.name = [NSString stringWithFormat:@"OmacVM pacing %.0f Hz", hz];
    d.maxPixelsWide = w * 2; d.maxPixelsHigh = h * 2; d.sizeInMillimeters = CGSizeMake(600, 340);
    /* A new serial each time: macOS keeps a saved arrangement per display set (STANDARDS 32). */
    d.productID = 0x1234; d.vendorID = 0x3456; d.serialNum = arc4random() | 1;
    CGVirtualDisplay *v = [[CGVirtualDisplay alloc] initWithDescriptor:d];
    CGVirtualDisplaySettings *s = [[CGVirtualDisplaySettings alloc] init];
    s.hiDPI = 1;
    s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:hz]];
    if (![v applySettings:s]) { fprintf(stderr, "applySettings failed\n"); return 1; }
    printf("display %u\n", v.displayID); fflush(stdout);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
  }
  return 0;
}
