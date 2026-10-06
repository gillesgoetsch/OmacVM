// globe-probe: what macOS does with the globe key code (179) and its shortcut
// 188 (omacvm-cocoa-globe-key.patch). A manual tool for a test Mac, never the
// user's: "set", "hold" and "recv ... post" change macOS's state or post keys.
//   cc -fobjc-arc -framework AppKit -framework Carbon globe-probe.m -o globe-probe
//   state            hot key 188: enabled? key? ; screen locked? front app
//   set 0|1          switch hot key 188 off/on (this process's call) and exit
//   hold <s>         switch it off, sleep, exit WITHOUT switching it on (exit restore test)
//   activate <pid>   bring that app to the front
//   post             post 179 down/up at the HID level (to whatever is in front)
//   recv <s> [post]  a small window in front logging key events; with "post" it
//                    posts 179 down/up at the HID level after 1 s; lists new windows
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <dlfcn.h>

typedef int32_t (*IsFn)(int);
typedef int32_t (*SetFn)(int, bool);
typedef int32_t (*GetFn)(int, unichar *, unsigned short *, uint32_t *);
static IsFn isOn; static SetFn setOn; static GetFn getVal;

static void load(void) {
  isOn = (IsFn)dlsym(RTLD_DEFAULT, "SLSIsSymbolicHotKeyEnabled");
  setOn = (SetFn)dlsym(RTLD_DEFAULT, "SLSSetSymbolicHotKeyEnabled");
  getVal = (GetFn)dlsym(RTLD_DEFAULT, "SLSGetSymbolicHotKeyValue");
  if (!isOn) isOn = (IsFn)dlsym(RTLD_DEFAULT, "CGSIsSymbolicHotKeyEnabled");
  if (!setOn) setOn = (SetFn)dlsym(RTLD_DEFAULT, "CGSSetSymbolicHotKeyEnabled");
  if (!getVal) getVal = (GetFn)dlsym(RTLD_DEFAULT, "CGSGetSymbolicHotKeyValue");
}

static void state(void) {
  unichar ch = 0; unsigned short kc = 0; uint32_t mods = 0;
  int32_t e = getVal ? getVal(188, &ch, &kc, &mods) : -1;
  printf("hotkey188 enabled=%d value err=%d char=%u keycode=%u mods=0x%x\n", isOn ? (int)isOn(188) : -1, e, ch, kc, mods);
  CFDictionaryRef s = CGSessionCopyCurrentDictionary();
  CFBooleanRef locked = s ? CFDictionaryGetValue(s, CFSTR("CGSSessionScreenIsLocked")) : NULL;
  printf("screenLocked=%d front=%s\n", locked ? CFBooleanGetValue(locked) : 0,
         [[[[NSWorkspace sharedWorkspace] frontmostApplication] localizedName] UTF8String] ?: "?");
  if (s) CFRelease(s);
}

static NSSet *windowOwners(void) {
  NSMutableSet *o = [NSMutableSet set];
  CFArrayRef w = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  for (NSDictionary *d in (__bridge NSArray *)w) {
    [o addObject:[NSString stringWithFormat:@"%@[%@] layer %@", d[(id)kCGWindowOwnerName], d[(id)kCGWindowOwnerPID], d[(id)kCGWindowLayer]]];
  }
  if (w) CFRelease(w);
  return o;
}

static void post179(void) {
  for (int down = 1; down >= 0; down--) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, 179, down);
    CGEventSetFlags(e, 0);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    usleep(30000);
  }
  printf("posted 179 down/up\n"); fflush(stdout);
}

@interface V : NSView @end
@implementation V
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { printf("APP keyDown %u flags 0x%lx\n", [e keyCode], (unsigned long)[e modifierFlags]); fflush(stdout); }
- (void)keyUp:(NSEvent *)e { printf("APP keyUp %u\n", [e keyCode]); fflush(stdout); }
- (void)flagsChanged:(NSEvent *)e { printf("APP flagsChanged %u flags 0x%lx\n", [e keyCode], (unsigned long)[e modifierFlags]); fflush(stdout); }
@end

@interface App : NSApplication @end
@implementation App
- (void)sendEvent:(NSEvent *)e {
  if ([e type] == NSEventTypeKeyDown || [e type] == NSEventTypeKeyUp || [e type] == NSEventTypeFlagsChanged)
    printf("sendEvent type %lu key %u\n", (unsigned long)[e type], [e keyCode]);
  fflush(stdout);
  [super sendEvent:e];
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    load();
    if (argc < 2) { fprintf(stderr, "usage\n"); return 64; }
    NSString *cmd = @(argv[1]);
    if ([cmd isEqual:@"state"]) { state(); return 0; }
    if ([cmd isEqual:@"set"] && argc > 2) { int r = setOn(188, atoi(argv[2]) != 0); printf("set -> %d\n", r); state(); return 0; }
    if ([cmd isEqual:@"activate"] && argc > 2) {
      NSRunningApplication *a = [NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])];
      BOOL ok = [a activateWithOptions:NSApplicationActivateAllWindows];
      printf("activate %s: %d\n", argv[2], ok); return ok ? 0 : 1;
    }
    if ([cmd isEqual:@"post"]) { post179(); return 0; }
    if ([cmd isEqual:@"hold"] && argc > 2) { setOn(188, false); state(); fflush(stdout); sleep(atoi(argv[2])); printf("exiting without restore\n"); return 0; }
    if ([cmd isEqual:@"recv"] && argc > 2) {
      double secs = atof(argv[2]); BOOL post = argc > 3 && !strcmp(argv[3], "post");
      [App sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 400, 200)
                                                styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
      [w setTitle:@"globe-probe"];
      V *v = [[V alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
      [w setContentView:v]; [w makeKeyAndOrderFront:nil]; [w makeFirstResponder:v];
      [NSApp activateIgnoringOtherApps:YES];
      __block NSSet *before = nil;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        state(); before = windowOwners();
        if (post) post179();
      });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((secs - 0.3) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSMutableSet *now = [windowOwners() mutableCopy]; [now minusSet:before ?: [NSSet set]];
        for (NSString *s in now) printf("NEW WINDOW %s\n", [s UTF8String]);
        if (![now count]) printf("no new windows\n");
        fflush(stdout); exit(0);
      });
      [NSApp run];
    }
    return 0;
  }
}
