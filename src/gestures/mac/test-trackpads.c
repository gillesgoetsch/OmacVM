// Offline test (test.sh) of the trackpads and Magic Mice after macOS made
// their devices anew, as it does for the built-in trackpad at a wake from deep
// sleep (Power Nap's dark wakes too): the same Multitouch ID, a new IORegistry
// entry, and the old device, started with MTDeviceStart, still says it runs
// (MultitouchSupport tells only MTDeviceScheduleOnRunLoop's devices). The
// helper kept the old one and no trackpad frame came again (the M1 Max,
// 2026-10-22): no swipes, and two-finger scrolling went to the VM app as a
// mouse's. MultitouchSupport and the IORegistry are stand-ins here: made-up
// devices are listed (new objects at every list, as macOS does), started and
// stopped; what the guest gets is read from a socket pair. No permissions, no
// device, nothing posted.
#include <stdint.h>
// The helper's MultitouchSupport and IOKit calls, to the stand-ins below.
#define MTDeviceCreateList fakeCreateList
#define MTRegisterContactFrameCallback fakeRegister
#define MTUnregisterContactFrameCallback fakeUnregister
#define MTDeviceStart fakeStart
#define MTDeviceStop fakeStop
#define MTDeviceIsBuiltIn fakeIsBuiltIn
#define MTDeviceGetSensorSurfaceDimensions fakeDimensions
#define MTDeviceGetDeviceID fakeDeviceID
#define MTDeviceIsRunning fakeIsRunning
#define MTDeviceGetFamilyID fakeFamilyID
#define MTDeviceGetService fakeService
#define IORegistryEntryGetRegistryEntryID fakeEntryID
#define IORegistryEntrySearchCFProperty fakeSearch
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <fcntl.h>

// A device as MultitouchSupport hands it out: a CF object (here a CFData, so
// the helper may hold it with CFRetain) whose bytes say what it is.
typedef struct { uint64_t id, entry; int builtIn, w, h, family, running, starts, stops, callbacks; } Dev;
static Dev *D(MTDeviceRef d) { return (Dev *)CFDataGetMutableBytePtr((CFMutableDataRef)d); }
// The hardware macOS lists now (its IORegistry entries).
static Dev hw[4];
static int nHw, lists;
// Every device object handed out, kept here too, so the test can look at one
// the helper let go of (and count who else holds it).
static CFMutableArrayRef seen;

CFArrayRef fakeCreateList(void) {
  lists++;
  CFMutableArrayRef l = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  for (int i = 0; i < nHw; i++) {
    CFMutableDataRef d = CFDataCreateMutable(NULL, sizeof(Dev));
    CFDataSetLength(d, sizeof(Dev));
    *D(d) = hw[i];
    D(d)->running = D(d)->starts = D(d)->stops = D(d)->callbacks = 0;
    CFArrayAppendValue(l, d);
    CFArrayAppendValue(seen, d);
    CFRelease(d);
  }
  return l;
}
void fakeRegister(MTDeviceRef d, MTFrameCallback cb) { (void)cb; D(d)->callbacks++; }
void fakeUnregister(MTDeviceRef d, MTFrameCallback cb) { (void)cb; D(d)->callbacks--; }
static int failStarts;   // the next starts that fail (an IOReturn, as a busy device's)
int fakeStart(MTDeviceRef d, int mode) {
  (void)mode;
  if (failStarts) { failStarts--; return (int)0xe00002d6; }
  D(d)->running = 1; D(d)->starts++;
  return 0;
}
void fakeStop(MTDeviceRef d) { D(d)->running = 0; D(d)->stops++; }
bool fakeIsBuiltIn(MTDeviceRef d) { return D(d)->builtIn; }
int fakeDimensions(MTDeviceRef d, int *w, int *h) { *w = D(d)->w; *h = D(d)->h; return 0; }
int fakeDeviceID(MTDeviceRef d, uint64_t *id) { *id = D(d)->id; return 0; }
bool fakeIsRunning(MTDeviceRef d) { return D(d)->running; }
int fakeFamilyID(MTDeviceRef d, int *f) { *f = D(d)->family; return 0; }
io_service_t fakeService(MTDeviceRef d) { return (io_service_t)D(d)->entry; }
kern_return_t fakeEntryID(io_registry_entry_t s, uint64_t *e) { *e = s; return s ? KERN_SUCCESS : KERN_INVALID_ARGUMENT; }
CFTypeRef fakeSearch(io_registry_entry_t s, const io_name_t plane, CFStringRef key, CFAllocatorRef a, IOOptionBits o) {
  (void)s; (void)plane; (void)key; (void)a; (void)o; return NULL;
}

static int fail, peer;
static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

// What the guest got since the last call: counts of F lines with fingers, and A
// lines; lastW: the trackpad width in the last "O" line (its size).
static int lastW;
static void drain(int *f, int *a) {
  char buf[16384]; *f = *a = 0;
  for (;;) {
    ssize_t n = read(peer, buf, sizeof buf - 1);
    if (n <= 0) break;
    buf[n] = 0;
    for (char *l = buf; *l; ) {
      if (l[0] == 'F' && l[2] != '0') (*f)++;
      if (l[0] == 'A') (*a)++;
      if (l[0] == 'O') sscanf(l, "O %*d %d", &lastW);
      char *nl = strchr(l, '\n');
      if (!nl) break;
      l = nl + 1;
    }
  }
}

// Fingers on the trackpad: one frame with n fingers (moving a little each
// time) to whoever started the device macOS has for it now (hw[0]'s entry).
// A device object of an entry that is gone gets nothing, though it still says
// it runs: as on the M1 Max. dev: to that object instead (a stray frame).
// touchState, touchZ: each finger's state and pressure (a finger in contact
// with pressure, unless a test says otherwise).
static float step, touchZ = 0.5f;
static int touchState = 4;
static void touch(MTDeviceRef dev, int n) {
  MTTouch t[5]; memset(t, 0, sizeof t);
  step += 0.002f;
  for (int i = 0; i < n; i++) {
    t[i].state = touchState; t[i].zTotal = touchZ; t[i].pathIndex = i + 1;
    t[i].normalized.pos.x = 0.3f + 0.1f * (float)i + step; t[i].normalized.pos.y = 0.5f;
  }
  if (dev) { frameCb(dev, t, n, 0, 0); return; }
  for (CFIndex i = 0; i < CFArrayGetCount(seen); i++) {
    MTDeviceRef o = (MTDeviceRef)CFArrayGetValueAtIndex(seen, i);
    if (D(o)->running && D(o)->callbacks > 0 && D(o)->id == hw[0].id && D(o)->entry == hw[0].entry) frameCb(o, t, n, 0, 0);
  }
}

// A four-finger swipe on the trackpad (or from dev): the F lines the guest got.
static int swipeFrom(MTDeviceRef dev) {
  int f, a;
  drain(&f, &a);
  for (int i = 0; i < 12; i++) touch(dev, 4);
  touch(dev, 0);
  drain(&f, &a);
  return f;
}
static int swipe(void) { return swipeFrom(NULL); }
// The same: the trackpad width the guest scales the swipe for if it was told
// one with it (0: none, -1: the swipe did not reach the guest).
static int swipeWidth(MTDeviceRef dev) {
  int f, a;
  drain(&f, &a);
  lastW = 0;
  return swipeFrom(dev) >= 10 ? lastW : -1;
}

// A two-finger scroll on the trackpad through the event tap (Glide): the A
// lines the guest got, and the scroll events the VM app got instead.
static int scroll(int *passed) {
  MTDeviceRef dev = NULL;
  int f, a;
  drain(&f, &a);
  *passed = 0;
  usleep(300000);   // past the grace of the last frames (SCROLL_TOUCH_GRACE): only this touch counts
  for (int i = 0; i < 6; i++) {
    touch(dev, 2);
    CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, 0);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, i ? 2 : 1);
    CGEventSetDoubleValueField(e, kCGScrollWheelEventPointDeltaAxis1, -4);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventDeltaAxis1, -1);
    *passed += tapCb(NULL, kCGEventScrollWheel, e, NULL) != NULL;
    CFRelease(e);
  }
  touch(dev, 0);
  drain(&f, &a);
  return a;
}

static MTDeviceRef padDev(void) { return nPads ? pads[0].dev : NULL; }
static MTDeviceRef mouseDev(void) { return nMice ? mice[0].dev : NULL; }

int main(void) {
  seen = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  // A full-screen VM in front, captured, that wants gestures and scroll momentum.
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { perror("socketpair"); return 1; }
  peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1; clients[0].glide = 1; clients[0].target = 1;
  strcpy(clients[0].ip, "192.168.77.2");
  frontNet = NET_APP; capturing = 1; trackpad = 1;
  scrollStateInit(&scrollSt);
  int passed;

  // The M1 Max's built-in trackpad as macOS lists it at start (boot's entry).
  hw[0] = (Dev){ .id = 0x200000000000033, .entry = 0xc11, .builtIn = 1, .w = 12400, .h = 7600 };
  nHw = 1;
  startTrackpads();
  MTDeviceRef first = padDev();
  check(nPads == 1 && first && D(first)->running && D(first)->callbacks == 1, "start: the built-in trackpad taken");
  check(swipe() >= 10, "start: a four-finger swipe reaches the guest (F lines)");
  check(scroll(&passed) == 6 && passed == 0, "start: two-finger scrolling goes to the guest (A), not the VM app");

  // The 10 s look with nothing changed: macOS lists a new object for the same device.
  startTrackpads(); startTrackpads();
  check(padDev() == first && D(first)->starts == 1 && nPads == 1, "the 10 s look, device unchanged: not taken again");

  // A wake from deep sleep: macOS makes the trackpad's device anew (a new,
  // higher IORegistry entry, the same Multitouch ID). The old one is gone but
  // still says it runs (its frames never come again).
  hw[0].entry = 0x192f;
  startTrackpads();
  MTDeviceRef woke = padDev();
  check(nPads == 1 && woke != first && woke && D(woke)->entry == 0x192f && D(woke)->running && D(woke)->callbacks == 1,
        "after a wake (a new device for the same trackpad): the new one taken");
  check(D(first)->stops == 1 && D(first)->callbacks == 0 && !D(first)->running, "after a wake: the old one let go");
  check(swipe() >= 10, "after a wake: four-finger swipes reach the guest again (F lines)");
  check(scroll(&passed) == 6 && passed == 0, "after a wake: two-finger scrolling goes to the guest again, not the VM app");
  check(swipeFrom(first) == 0, "after a wake: a stray frame from the old device is not taken");
  // The helper holds only what it uses: the old device and every list are let go.
  check(CFGetRetainCount(first) == 1, "after a wake: the old device is not held (no leak per wake)");
  check(CFGetRetainCount(woke) == 2, "after a wake: the new device held once");

  // The old one still listed for a moment next to the new one: never taken back.
  hw[1] = hw[0]; hw[1].entry = 0xc11; nHw = 2;
  startTrackpads();
  check(padDev() == woke && nPads == 1 && D(woke)->stops == 0, "the old device still listed beside the new: the new one stays");
  nHw = 1;

  // Wake after wake (six on the M1 Max that evening): each new device taken.
  uint64_t entries[] = { 0x199b, 0x1a20, 0x1a8c, 0x1b0b };
  int each = 1;
  for (int i = 0; i < 4; i++) {
    MTDeviceRef before = padDev();
    hw[0].entry = entries[i];
    startTrackpads();
    each &= padDev() != before && D(padDev())->entry == entries[i] && D(before)->stops == 1 && CFGetRetainCount(before) == 1;
  }
  check(each && nPads == 1 && swipe() >= 10, "four more wakes: each new device taken, each old one let go");

  // A start that did not take (same device, not running): taken again, as before.
  MTDeviceRef stuck = padDev();
  D(stuck)->running = 0;
  startTrackpads();
  check(padDev() != stuck && D(padDev())->entry == 0x1b0b && D(padDev())->running, "same device, not running: taken again (as before)");

  // MultitouchSupport does not start the new device (busy): not running, so the next look takes it again.
  hw[0].entry = 0x1c00;
  failStarts = 1;
  startTrackpads();
  check(D(padDev())->entry == 0x1c00 && !D(padDev())->running && swipe() == 0, "a new device that did not start: not running");
  startTrackpads();
  check(D(padDev())->entry == 0x1c00 && D(padDev())->running && swipe() >= 10, "... taken again at the next look, and its frames come");

  // macOS says it added a multi-touch device: looked for 1 s later, once for a burst.
  hw[0].entry = 0x1d5b;
  int before = lists;
  multitouchAdded(NULL, 0); multitouchAdded(NULL, 0); multitouchAdded(NULL, 0);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
  check(lists == before && D(padDev())->entry != 0x1d5b, "macOS added a device: not looked for at once (it may be busy)");
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
  check(lists == before + 1 && D(padDev())->entry == 0x1d5b && swipe() >= 10,
        "macOS added a device: looked for 1 s later, once, and the new trackpad taken");

  // A Magic Mouse made anew (a wake, or connected again): the same.
  hw[1] = (Dev){ .id = 0x44, .entry = 0x2000, .builtIn = 0, .w = 5150, .h = 9050, .family = 112 };
  nHw = 2;
  startTrackpads();
  MTDeviceRef mouse = mouseDev();
  check(nMice == 1 && mouse && D(mouse)->running && D(mouse)->callbacks == 1, "Magic Mouse taken");
  startTrackpads();
  check(mouseDev() == mouse && D(mouse)->starts == 1, "Magic Mouse, device unchanged: not taken again");
  hw[1].entry = 0x2100;
  startTrackpads();
  check(nMice == 1 && mouseDev() != mouse && D(mouseDev())->running && D(mouse)->stops == 1 && D(mouse)->callbacks == 0 &&
        CFGetRetainCount(mouse) == 1, "Magic Mouse made anew: the new one taken, the old one let go");

  // A permission taken away (stopTrackpads): every device let go and not held.
  MTDeviceRef p = padDev(), m = mouseDev();
  stopTrackpads();
  check(nPads == 0 && nMice == 0 && !D(p)->running && !D(m)->running && CFGetRetainCount(p) == 1 && CFGetRetainCount(m) == 1,
        "permission taken away: every device let go and not held");
  startTrackpads();
  check(nPads == 1 && nMice == 1 && swipe() >= 10, "permission back: taken again");

  // A Magic Trackpad next to the built-in one, touched last before the Mac
  // slept; the wake makes the built-in one's device anew. The guest still
  // scales for the Magic Trackpad: the built-in one, touched next, tells it
  // its size ("O"), as at any change of trackpad.
  hw[2] = (Dev){ .id = 0x55, .entry = 0x3000, .builtIn = 0, .w = 16000, .h = 11500 };
  nHw = 3;
  startTrackpads();
  MTDeviceRef magic = NULL;
  for (int i = 0; i < nPads; i++) if (D(pads[i].dev)->id == 0x55) magic = pads[i].dev;
  check(nPads == 2 && magic && D(magic)->running, "a Magic Trackpad next to the built-in one: taken");
  check(swipeWidth(magic) == 16000, "the Magic Trackpad touched: the guest scales for it (160 mm)");
  hw[0].entry = 0x1e00;
  startTrackpads();
  check(nPads == 2 && D(padDev())->entry == 0x1e00, "a wake beside a Magic Trackpad: the built-in one's new device taken");
  check(swipeWidth(NULL) == 12400, "... touched next, the guest scales for the built-in one again (124 mm)");
  check(swipeWidth(magic) == 16000, "... and for the Magic Trackpad when it is touched again");

  // The M5 MacBook Pro's trackpad: most fingers in contact read zTotal 0
  // (#838). They count; a hovering finger without pressure does not.
  touchZ = 0.0f;
  check(swipeWidth(NULL) == 12400, "fingers in contact with zTotal 0 (the M5's trackpad): a four-finger swipe reaches the guest");
  touchState = 2;
  check(swipe() == 0, "hovering fingers with zTotal 0: not counted");
  touchState = 4; touchZ = 0.5f;

  printf("%s\n", fail ? "FAIL trackpads" : "ok   trackpads: a device macOS made anew (a wake) is taken, the old one let go");
  return fail;
}
