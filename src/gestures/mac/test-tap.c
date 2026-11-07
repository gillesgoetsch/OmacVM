// Offline test of when the helper creates its event tap again (test.sh): no
// permissions, no real tap. CGEventTapCreate is a stand-in that returns a
// plain Mach port, so installTap's swap (new tap in, old one out) and the
// re-arm rules run as they do in the helper. The permissions are made up
// too (permFn), and so are the trackpads (stopDeviceFn): a permission taken
// away removes the tap and lets go of them at once, and nothing enables or
// creates a tap again until it is back (issue #192).
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
// shareKeyboard (#350) is read from a throwaway domain (test.sh), never the app's.
#ifndef SHARE_KEYBOARD_DOMAIN
#error "build with -DSHARE_KEYBOARD_DOMAIN=CFSTR(\"<throwaway domain>\")"
#endif
static int created, failNext, enabled = 1;
static CGEventTapPlacement lastPlace = (CGEventTapPlacement)-1;
static CFMachPortRef fakeTapCreate(CGEventTapLocation l, CGEventTapPlacement p, CGEventTapOptions o, CGEventMask m,
                                   CGEventTapCallBack cb, void *u) {
  (void)l; (void)o; (void)m; (void)cb; (void)u;
  if (failNext) return NULL;
  lastPlace = p;
  created++;
  enabled = 1;   // a new tap is enabled
  return CFMachPortCreate(NULL, NULL, NULL, NULL);
}
static bool fakeIsEnabled(CFMachPortRef t) { (void)t; return enabled; }
static void fakeEnable(CFMachPortRef t, bool on) { (void)t; enabled = on; }
#define CGEventTapCreate fakeTapCreate
#define CGEventTapIsEnabled fakeIsEnabled
#define CGEventTapEnable fakeEnable
#define main helper_main
#include "omacvm-gestures.c"
#undef main

static int fail;
static int fakeQemu(pid_t pid) { return pid != 1200; }   // 1200: OmacVM.app's launcher
static int perm = PERM_AX | PERM_IM;
static int fakePerm(void) { return perm; }
static double clockNow = 1000;
static double fakeNow(void) { return clockNow; }
static int stopped;
static void fakeStopDevice(MTDeviceRef d, MTFrameCallback cb) { (void)d; (void)cb; stopped++; }
static void drain(void) { for (int i = 0; i < 5; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false); }
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

int main(void) {
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  isQemuFn = fakeQemu;
  permFn = fakePerm;
  nowFn = fakeNow;
  stopDeviceFn = fakeStopDevice;
  trackpad = 0;   // startTrackpads would open this Mac's real trackpad
  perm = PERM_IM;
  check(!installTap() && created == 0 && !tapPort, "no tap without Accessibility (Input Monitoring alone)");
  perm = PERM_AX | PERM_IM;
  check(installTap() && created == 1, "the first tap");
  CFMachPortRef first = tapPort; CFRetain(first);
  // Front app, network, full screen, title, window, other: as updateCapture finds them.
  frontChanged(500, -1, 0, "", 0, 0);                    // Terminal
  check(created == 1, "no new tap for an app that is no VM");
  frontChanged(600, NET_APP, 1, "Omarchy", 0, 0);          // an OmacVM VM goes full screen
  check(created == 2, "new tap when an OmacVM VM comes to the front");
  check(!CFMachPortIsValid(first) && CFMachPortIsValid(tapPort), "the old tap is gone, the new one live");
  CFRelease(first);
  frontChanged(600, NET_APP, 1, "Omarchy", 0, 0);
  frontChanged(600, NET_APP, 1, "Omarchy", 0, 0);
  check(created == 2, "not again while the same VM stays in front (checked every 0.2 s)");
  frontChanged(700, NET_APP, 1, "Work", 0, 0);             // straight to a second VM (another QEMU)
  check(created == 3, "new tap for a second OmacVM VM, straight from the first");
  frontChanged(700, NET_APP, 0, "", 0, 0);                 // its window left full screen
  frontChanged(800, NET_APP, 1, "Omarchy", 0, 0);          // the app was restarted: a new QEMU
  check(created == 4, "new tap after OmacVM.app was restarted");
  frontChanged(500, -1, 0, "", 0, 0);
  CFMachPortInvalidate(tapPort);                     // macOS took it away
  frontChanged(800, NET_APP, 1, "Omarchy", 0, 0);
  check(created == 5 && CFMachPortIsValid(tapPort), "new tap when macOS invalidated ours");
  // Disabled (#290): removed, never enabled again; a new one after the hold-off.
  enabled = 0;
  frontChanged(800, NET_APP, 1, "Omarchy", 0, 0);         // the same VM stays in front
  check(!tapPort && !enabled && created == 5, "a disabled tap is removed, not enabled again");
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(950, NET_APP, 1, "Omarchy", 0, 0);
  check(!tapPort && created == 5, "no new tap during the 2 s hold-off, not even for another VM");
  clockNow += 2.1; enabled = 1;
  tapBack();
  check(tapPort && created == 6, "a new tap after the hold-off");
  created = 5;   // (the counts below as before)
  // Permission taken away: the old tap stays.
  failNext = 1;
  CFMachPortRef keep = tapPort;
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1000, NET_APP, 1, "Omarchy", 0, 0);
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1001, NET_APP, 1, "Omarchy", 0, 0);
  check(tapPort == keep && CFMachPortIsValid(keep), "a failed re-creation keeps the old tap");
  failNext = 0;
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1002, NET_APP, 1, "Omarchy", 0, 0);
  check(created == 6 && tapPort != keep, "works again once permitted");
  // An OmacVM VM in a window: its tap too (the escape combo is ours there).
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1100, NET_APP, 0, "", 0, 0);
  check(created == 7, "new tap when an OmacVM VM window comes to the front");
  frontChanged(1100, NET_APP, 1, "Omarchy", 0, 0);
  frontChanged(1100, NET_APP, 0, "", 0, 0);
  check(created == 7, "not again when that VM goes full screen and back (the same QEMU)");
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1200, NET_APP, 0, "", 0, 0);
  check(created == 7, "no new tap for OmacVM.app's launcher window");

  // ---- issue #192: Accessibility taken away while a VM is captured ----
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1300, NET_APP, 1, "Omarchy", 0, 0);
  check(capturing && created == 8, "capturing a full-screen OmacVM VM");
  static int devs[3];
  pads[0].dev = &devs[0]; pads[1].dev = &devs[1]; nPads = 2; activePad = 0;
  mice[0].dev = &devs[2]; nMice = 1;
  CFMachPortRef old = tapPort; CFRunLoopSourceRef oldSource = tapSource;
  CFRetain(old); CFRetain(oldSource);
  checkPermissions();
  check(tapPort == old, "nothing happens while every permission is there");
  perm = PERM_IM;
  checkPermissions();
  check(!tapPort && !tapSource && !CFMachPortIsValid(old) && !CFRunLoopSourceIsValid(oldSource) &&
        !CFRunLoopContainsSource(CFRunLoopGetMain(), oldSource, kCFRunLoopCommonModes),
        "Accessibility taken away: the tap and its run-loop source are gone at once");
  CFRelease(old); CFRelease(oldSource);
  check(inputPaused && !capturing, "... capture off");
  check(stopped == 3 && nPads == 0 && nMice == 0 && activePad == -1, "... both trackpads and the Magic Mouse let go");
  check(frameCb(&devs[0], NULL, 0, 0, 0) == 0 && activePad == -1, "... a late frame from a trackpad let go changes nothing");
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1301, NET_APP, 1, "Omarchy", 0, 0);   // another VM comes to the front
  frontChanged(1301, NET_APP, 1, "Omarchy", 0, 0);
  checkPermissions();
  check(!tapPort && created == 8 && !capturing, "no tap and no capture while it is missing (a VM in front, the checks)");
  perm = PERM_AX | PERM_IM;
  checkPermissions();
  check(tapPort && created == 9 && !inputPaused, "Accessibility back: a new tap");
  frontChanged(1301, NET_APP, 1, "Omarchy", 0, 0);
  check(capturing, "... and capture again");

  // macOS disables the tap (timeout): never enabled again; removed after the
  // callback, a new one after the hold-off; the third in 10 minutes parks it.
  CGEventRef ev = CGEventCreate(NULL);
  clockNow += 1000;   // the strikes above are forgotten
  int c = created;
  enabled = 0;
  tapCb(NULL, kCGEventTapDisabledByTimeout, ev, NULL);
  check(!enabled && tapPort, "disabled by timeout: not enabled again in the callback");
  drain();
  check(!tapPort && !inputPaused && capturing, "... removed right after it (trackpads and capture stay)");
  clockNow += 2.1; enabled = 1; tapBack();
  check(tapPort && created == c + 1, "... a new one after 2 s");
  enabled = 0;
  tapCb(NULL, kCGEventTapDisabledByUserInput, ev, NULL);
  drain();
  clockNow += 2.1; tapBack();
  check(!tapPort && created == c + 1, "disabled again: no new one after 2 s");
  clockNow += 28; enabled = 1; tapBack();
  check(tapPort && created == c + 2, "... after 30 s");
  enabled = 0;
  tapCb(NULL, kCGEventTapDisabledByTimeout, ev, NULL);
  drain();
  check(!tapPort && tapParked && inputPaused && !capturing, "the third in 10 minutes: parked, trackpads let go, capture off");
  clockNow += 3600; enabled = 1; tapBack(); checkPermissions();
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1302, NET_APP, 1, "Omarchy", 0, 0);
  check(!tapPort && created == c + 2, "... no tap while parked, an hour later, with a VM in front");
  tapPolicyReset(); checkPermissions();   // what accessibilityChanged does
  frontChanged(1302, NET_APP, 1, "Omarchy", 0, 0);
  check(tapPort && created == c + 3 && !inputPaused && capturing, "the Accessibility list changed: a new tap, capture again");
  // Disabled while Accessibility is gone: it goes, waiting for the permission.
  enabled = 0;
  perm = PERM_IM;
  tapCb(NULL, kCGEventTapDisabledByTimeout, ev, NULL);
  check(!enabled, "disabled by timeout, Accessibility gone: not enabled again");
  drain();
  check(!tapPort && inputPaused && !capturing, "... and the tap removed right after the callback");
  enabled = 1;
  perm = PERM_AX | PERM_IM;
  checkPermissions();
  frontChanged(1302, NET_APP, 1, "Omarchy", 0, 0);
  check(tapPort && created == c + 4 && capturing, "back again");
  created = 10;   // (the counts below as before)
  // The watchdog's step: ask, wait up to a second, then stalled.
  double asked = 0;
  check(watchStep(5.0, &asked) == 1 && watchStep(5.5, &asked) == 0 && watchStep(6.0, &asked) == 0 &&
        watchStep(6.01, &asked) == 2, "watchdog: asks, waits a second, then disables");
  asked = 0;
  check(watchStep(7.0, &asked) == 1, "watchdog: answered, asks again");
  // The capture check finds it disabled while Accessibility is gone.
  enabled = 0;
  perm = 0;
  frontChanged(1301, NET_APP, 1, "Omarchy", 0, 0);
  check(!enabled && !tapPort && !capturing, "a disabled tap found by the capture check without Accessibility: removed, not enabled");
  enabled = 1;
  CFRelease(ev);

  // Input Monitoring taken away (Accessibility stays): the tap made with both
  // goes; the next one is made with Accessibility alone and stays.
  perm = PERM_AX | PERM_IM;
  checkPermissions();
  check(tapPort && created == 11, "a tap with both permissions");
  perm = PERM_AX;
  checkPermissions();
  check(!tapPort && inputPaused, "Input Monitoring taken away: that tap goes");
  checkPermissions();
  check(tapPort && created == 12 && !inputPaused, "... a new one with Accessibility alone");
  checkPermissions();
  check(tapPort && created == 12, "... which stays without Input Monitoring");
  // A VM comes to the front just after Accessibility went (before a check saw it).
  frontChanged(500, -1, 0, "", 0, 0);
  perm = PERM_IM;
  frontChanged(1400, NET_APP, 1, "Omarchy", 0, 0);
  check(created == 12 && !tapPort && inputPaused && !capturing,
        "a VM comes to the front just after Accessibility went: no new tap, the old one goes");

  // "Control the computer" (CGPreflightPostEventAccess: what macOS checks
  // before it takes the events an active tap hands back) taken away while
  // Accessibility stays: the tap goes and none is made until it is back.
  perm = PERM_AX | PERM_IM | PERM_POST;
  checkPermissions();
  check(tapPort && created == 13 && !inputPaused, "a tap made with 'control the computer' too");
  perm = PERM_AX | PERM_IM;
  checkPermissions();
  check(!tapPort && inputPaused, "'control the computer' taken away, Accessibility still there: the tap goes");
  checkPermissions();
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1500, NET_APP, 1, "Omarchy", 0, 0);
  check(!tapPort && created == 13 && inputPaused && !capturing, "... and no tap is made while it is missing");
  perm = PERM_AX | PERM_IM | PERM_POST;
  checkPermissions();
  check(tapPort && created == 14 && !inputPaused, "... back with it");

  // Keyboard sharing apps (#350): OmacVM.app's hidden shareKeyboard puts the
  // tap at the end of the chain, read whenever a tap is made.
  check(lastPlace == kCGHeadInsertEventTap, "shareKeyboard not set: the tap at the head of the chain");
  CFPreferencesSetAppValue(CFSTR("shareKeyboard"), kCFBooleanTrue, SHARE_KEYBOARD_DOMAIN);
  CFPreferencesAppSynchronize(SHARE_KEYBOARD_DOMAIN);
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1600, NET_APP, 1, "Omarchy", 0, 0);
  check(tapPort && created == 15 && lastPlace == kCGTailAppendEventTap,
        "shareKeyboard true: the next tap at the end of the chain");
  CFPreferencesSetAppValue(CFSTR("shareKeyboard"), kCFBooleanFalse, SHARE_KEYBOARD_DOMAIN);
  CFPreferencesAppSynchronize(SHARE_KEYBOARD_DOMAIN);
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1700, NET_APP, 1, "Omarchy", 0, 0);
  check(tapPort && created == 16 && lastPlace == kCGHeadInsertEventTap, "shareKeyboard false: at the head again");
  CFPreferencesSetAppValue(CFSTR("shareKeyboard"), CFSTR("no"), SHARE_KEYBOARD_DOMAIN);
  CFPreferencesAppSynchronize(SHARE_KEYBOARD_DOMAIN);
  frontChanged(500, -1, 0, "", 0, 0);
  frontChanged(1800, NET_APP, 1, "Omarchy", 0, 0);
  check(tapPort && lastPlace == kCGHeadInsertEventTap, "shareKeyboard \"no\" (a string): at the head");
  CFPreferencesSetAppValue(CFSTR("shareKeyboard"), NULL, SHARE_KEYBOARD_DOMAIN);
  CFPreferencesAppSynchronize(SHARE_KEYBOARD_DOMAIN);

  return fail;
}
