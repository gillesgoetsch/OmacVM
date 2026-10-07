// Offline test of the Magic Mouse's gestures (test.sh): the model on its own
// with made-up frames (mouse-model.h), then the helper's real frame callback
// and event tap with made-up Magic Mouse frames and scroll events; what it
// sends the guest is read back from a socket pair. No permissions, no device,
// nothing posted.
//   a finger resting, slow sideways scrolling, up/down scrolling -> nothing
//   one finger flicked sideways                                 -> Back / Forward key, once per touch
//   two fingers sliding sideways                                -> four virtual fingers (workspace swipe),
//                                                                  macOS's scroll for them dropped
//   MouseSwipeFingers 3 (set while running)                     -> three from the next swipe; anything else: four
//   not captured, or a VM without gestures                      -> nothing, scrolling passes
// The setting is read from a throwaway domain (test.sh deletes it), never the
// installed Gestures' own.
#define GESTURES_DOMAIN CFSTR("org.omacvm.test.mouse-fingers")
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#include <fcntl.h>

static int fail, peer;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

// The user's Magic Mouse 2: 51.5 x 90.6 mm.
#define MW 51.52f
#define MH 90.56f

// --- the model, with its own clock ---
static int run1(MouseState *s, float x0, float y0, float x1, float y1, double t0, double dur, int frames, int *last) {
  int acts[8] = {0};
  for (int i = 0; i <= frames; i++) {
    float f = (float)i / (float)frames;
    MouseTouch c = { 7, x0 + (x1 - x0) * f, y0 + (y1 - y0) * f };
    int a = mouseFrame(s, &c, 1, t0 + dur * f);
    acts[a]++;
    if (a) *last = a;
  }
  return acts[MOUSE_BACK] + acts[MOUSE_FORWARD];
}

static void modelChecks(void) {
  MouseState s; mouseStateInit(&s);
  int last = 0;
  check(run1(&s, 25, 40, 25.3f, 40.2f, 0, 5, 450, &last) == 0, "model: a finger resting 5 s (tiny jitter): nothing");
  check(run1(&s, 25, 40, 37, 40, 5, 1.0, 90, &last) == 0, "model: slow sideways scrolling (12 mm in 1 s): nothing");
  mouseFrame(&s, NULL, 0, 6.1); mouseStateInit(&s);
  check(run1(&s, 25, 20, 26, 45, 7, 0.2, 18, &last) == 0, "model: fast up/down scrolling: nothing");
  mouseFrame(&s, NULL, 0, 7.3);
  // A finger that rested 3 s, then flicks right.
  last = 0;
  run1(&s, 20, 40, 20, 40, 8, 3, 270, &last);
  int n = run1(&s, 20, 40, 36, 41, 11, 0.15, 14, &last);
  check(n == 1 && last == MOUSE_BACK, "model: after resting 3 s, a flick to the right: Back, once");
  n = run1(&s, 36, 41, 18, 41, 11.2, 0.15, 14, &last);
  check(n == 0, "model: the same finger flicking back without lifting: nothing");
  mouseFrame(&s, NULL, 0, 11.5);
  last = 0;
  n = run1(&s, 36, 40, 20, 40, 12, 0.15, 14, &last);
  check(n == 1 && last == MOUSE_FORWARD, "model: lifted, then a flick to the left: Forward");
  mouseFrame(&s, NULL, 0, 12.3);

  // Two fingers sideways.
  int swipes = 0, ends = 0, other = 0; float maxdx = 0;
  for (int i = 0; i <= 30; i++) {
    float dx = 20.0f * (float)i / 30.0f;
    MouseTouch c[2] = { { 1, 15 + dx, 40 }, { 2, 30 + dx, 41 } };
    int a = mouseFrame(&s, c, 2, 13 + 0.01 * i);
    swipes += a == MOUSE_SWIPE; other += a == MOUSE_BACK || a == MOUSE_FORWARD;
    if (a == MOUSE_SWIPE && s.dx > maxdx) maxdx = s.dx;
  }
  // One finger lifts first, the other keeps moving: the swipe ends, no flick.
  for (int i = 0; i <= 10; i++) {
    MouseTouch c = { 2, 50 - 2.0f * (float)i, 41 };
    int a = mouseFrame(&s, &c, 1, 13.4 + 0.01 * i);
    ends += a == MOUSE_SWIPE_END; other += a == MOUSE_BACK || a == MOUSE_FORWARD;
  }
  ends += mouseFrame(&s, NULL, 0, 13.6) == MOUSE_SWIPE_END;
  check(swipes >= 24 && maxdx > 14 && maxdx < 17, "model: two fingers 20 mm sideways: a swipe from 4 mm on, following them");
  check(ends == 1 && other == 0, "model: one finger lifts first, the other moves on: the swipe ends once, no Back/Forward");
  // Two fingers along the mouse first: no swipe for that touch.
  swipes = 0;
  for (int i = 0; i <= 20; i++) {
    float d = (float)i;
    MouseTouch c[2] = { { 1, 15 + (i > 10 ? d : 0), 30 + (i <= 10 ? d : 10) }, { 2, 30 + (i > 10 ? d : 0), 31 + (i <= 10 ? d : 10) } };
    swipes += mouseFrame(&s, c, 2, 14 + 0.01 * i) == MOUSE_SWIPE;
  }
  mouseFrame(&s, NULL, 0, 14.5);
  check(swipes == 0, "model: two fingers scrolling along the mouse, then sideways: no swipe");

  check(isMagicMouseKind(0, 112, 0x0269, 5152, 9056), "kind: Magic Mouse 2 (family 112, product 0x0269)");
  check(isMagicMouseKind(0, 0, 0x030d, 0, 0) && isMagicMouseKind(0, 0, 0x0323, 0, 0),
        "kind: Magic Mouse (0x030d) and Magic Mouse USB-C (0x0323) by product");
  check(isMagicMouseKind(0, 0, 0, 5200, 9100), "kind: an unknown newer model by its shape");
  check(!isMagicMouseKind(1, 111, 0, 15600, 9600) && !isMagicMouseKind(0, 0, 0, 8000, 1000) &&
        !isMagicMouseKind(0, 0, 0x0324, 16000, 11500),
        "kind: not the built-in trackpad, a wide strip (Touch Bar), a Magic Trackpad");
}

// --- the helper's own callback and tap ---
// What the guest got since the last call.
// f3: finger lines (any count); nf: the count in them (-1: none, 0: mixed or malformed).
typedef struct { int f3, f0, back, fwd, other, nf; float firstX, lastX; } Got;
static Got drain(void) {
  Got g = { 0, 0, 0, 0, 0, -1, -1, -1 };
  static char acc[1 << 16]; size_t n = 0;
  for (;;) {
    ssize_t r = read(peer, acc + n, sizeof acc - 1 - n);
    if (r <= 0) break;
    n += (size_t)r;
  }
  acc[n] = 0;
  for (char *l = acc; *l; ) {
    char *nl = strchr(l, '\n'); if (nl) *nl = 0;
    int id, nf, at; float x;
    if (sscanf(l, "F %d %n", &nf, &at) == 1 && nf > 0 && sscanf(l + at, "%d %f", &id, &x) == 2 && id == MOUSE_FINGER_ID) {
      int words = 0;
      for (char *w = strtok(l + at, " "); w; w = strtok(NULL, " ")) words++;
      g.nf = (g.nf == -1 || g.nf == nf) && words == 4 * nf ? nf : 0;
      g.f3++; if (g.firstX < 0) g.firstX = x; g.lastX = x;
    } else if (!strcmp(l, "F 0")) g.f0++;
    else if (!strcmp(l, "K 158 1") || !strcmp(l, "K 158 0")) g.back++;
    else if (!strcmp(l, "K 159 1") || !strcmp(l, "K 159 0")) g.fwd++;
    else if (*l) g.other++;
    if (!nl) break;
    l = nl + 1;
  }
  return g;
}

// One Magic Mouse frame: k fingers at (x, y) mm, 1.5 mm apart sideways... as given.
static void frame(MTDeviceRef dev, int k, const float *xs, const float *ys) {
  MTTouch t[4]; memset(t, 0, sizeof t);
  for (int i = 0; i < k; i++) {
    t[i].state = 4; t[i].zTotal = 0.3f; t[i].pathIndex = i + 1;
    t[i].normalized.pos.x = xs[i] / MW; t[i].normalized.pos.y = ys[i] / MH;
  }
  mouseFrameCb(dev, t, k, 0, 0);
}
// Real time (the helper's clock): 2 ms a frame, so a busy CI runner that
// oversleeps a lot still stays well inside MOUSE_FLICK_TIME (10 ms frames
// went past it there now and then).
static void flick(MTDeviceRef dev, float from, float to) {
  for (int i = 0; i <= 12; i++) {
    float x = from + (to - from) * (float)i / 12.0f, y = 45;
    frame(dev, 1, &x, &y);
    usleep(2000);
  }
  frame(dev, 0, NULL, NULL);
}
// Two fingers sideways by dx mm; scrolls: macOS's scroll events in between, how many passed.
static int swipe(MTDeviceRef dev, float dx) {
  int passed = 0;
  for (int i = 0; i <= 20; i++) {
    float o = dx * (float)i / 20.0f, xs[2] = { 15 + o, 32 + o }, ys[2] = { 40, 41 };
    frame(dev, 2, xs, ys);
    CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, 0, 3);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventScrollPhase, i ? 2 : 1);
    if (tapCb(NULL, kCGEventScrollWheel, e, NULL)) passed++;
    CFRelease(e);
  }
  frame(dev, 0, NULL, NULL);
  return passed;
}
static int scrollPasses(void) {
  CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, -4);
  CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
  int ok = tapCb(NULL, kCGEventScrollWheel, e, NULL) != NULL;
  CFRelease(e);
  return ok;
}
static void addMouse(MTDeviceRef dev) {
  mice[nMice].dev = dev; mice[nMice].id = (uint64_t)(uintptr_t)dev; mice[nMice].w = 5152; mice[nMice].h = 9056;
  mouseStateInit(&mice[nMice].st);
  nMice++;
}

// MouseSwipeFingers as the app (or defaults write) stores it, changed while
// the helper runs.
static void setFingers(CFPropertyListRef v) {
  CFPreferencesSetAppValue(CFSTR("MouseSwipeFingers"), v, GESTURES_DOMAIN);
  CFPreferencesAppSynchronize(GESTURES_DOMAIN);
}
static int swipeFingers(MTDeviceRef dev) {
  swipe(dev, 18);
  Got g = drain();
  usleep((useconds_t)((MOUSE_SWIPE_HOLD + 0.1) * 1e6));
  return g.f3 >= 14 && g.f0 == 1 && g.lastX > g.firstX + 0.1f ? g.nf : -2;
}
static void fingerSettingChecks(MTDeviceRef dev) {
  int three = 3, four = 4, five = 5, zero = 0; double half = 3.5;
  CFNumberRef n3 = CFNumberCreate(NULL, kCFNumberIntType, &three), n4 = CFNumberCreate(NULL, kCFNumberIntType, &four),
              n5 = CFNumberCreate(NULL, kCFNumberIntType, &five), n0 = CFNumberCreate(NULL, kCFNumberIntType, &zero),
              nh = CFNumberCreate(NULL, kCFNumberDoubleType, &half);
  check(mouseFingersOf(NULL) == 4 && mouseFingersOf(n3) == 3 && mouseFingersOf(n4) == 4 && mouseFingersOf(CFSTR("3")) == 3 &&
        mouseFingersOf(CFSTR("4")) == 4, "setting: not set 4; 3 and 4 as numbers or text");
  check(mouseFingersOf(n5) == 4 && mouseFingersOf(n0) == 4 && mouseFingersOf(nh) == 4 && mouseFingersOf(CFSTR("three")) == 4 &&
        mouseFingersOf(CFSTR(" 3")) == 4 && mouseFingersOf(kCFBooleanTrue) == 4,
        "setting: 5, 0, 3.5, \"three\", \" 3\", true: 4");

  setFingers(n3);
  check(swipeFingers(dev) == 3, "VM: MouseSwipeFingers set to 3 while running: the next swipe has three virtual fingers");
  setFingers(CFSTR("3"));
  check(swipeFingers(dev) == 3, "VM: MouseSwipeFingers \"3\" (defaults write without -int): three");
  setFingers(n4);
  check(swipeFingers(dev) == 4, "VM: back to 4: four");
  setFingers(n5);
  check(swipeFingers(dev) == 4, "VM: MouseSwipeFingers 5: four");
  setFingers(CFSTR("three"));
  check(swipeFingers(dev) == 4, "VM: MouseSwipeFingers \"three\": four");

  // Changed in the middle of a swipe: that swipe keeps its count (the guest
  // never sees fingers added or lifted), the next one takes the new one.
  setFingers(n3);
  for (int i = 0; i <= 10; i++) { float o = 18.0f * (float)i / 20.0f, xs[2] = { 15 + o, 32 + o }, ys[2] = { 40, 41 }; frame(dev, 2, xs, ys); }
  setFingers(n4);
  for (int i = 11; i <= 20; i++) { float o = 18.0f * (float)i / 20.0f, xs[2] = { 15 + o, 32 + o }, ys[2] = { 40, 41 }; frame(dev, 2, xs, ys); }
  frame(dev, 0, NULL, NULL);
  Got g = drain();
  usleep((useconds_t)((MOUSE_SWIPE_HOLD + 0.1) * 1e6));
  check(g.f3 >= 10 && g.f0 == 1 && g.nf == 3, "VM: set from 3 to 4 during a swipe: that swipe stays at three");
  check(swipeFingers(dev) == 4, "... and the next swipe has four");

  setFingers(NULL);
  check(swipeFingers(dev) == 4, "VM: MouseSwipeFingers deleted: four");
  CFRelease(n3); CFRelease(n4); CFRelease(n5); CFRelease(n0); CFRelease(nh);
}

int main(void) {
  modelChecks();
  setFingers(NULL);   // a run that was stopped may have left it

  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { perror("socketpair"); return 1; }
  peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1; clients[0].glide = 0; clients[0].target = 1;
  strcpy(clients[0].ip, "127.0.0.1");
  frontNet = NET_APP; capturing = 1; trackpad = 1;
  scrollStateInit(&scrollSt);
  MTDeviceRef mouse = (MTDeviceRef)(uintptr_t)0x3003, mouse2 = (MTDeviceRef)(uintptr_t)0x4004;
  addMouse(mouse);

  // A resting finger and up/down scrolling: nothing to the guest, scrolling passes.
  for (int i = 0; i < 50; i++) { float x = 25, y = 40 + 0.3f * (float)i; frame(mouse, 1, &x, &y); }
  frame(mouse, 0, NULL, NULL);
  Got g = drain();
  check(g.f3 + g.f0 + g.back + g.fwd + g.other == 0 && scrollPasses(), "VM: one finger scrolling: nothing to the guest, scroll to the VM app");

  flick(mouse, 18, 36);
  g = drain();
  check(g.back == 2 && g.fwd == 0 && g.other == 0, "VM: one-finger flick right: Back pressed and let go on the guest's keyboard");
  flick(mouse, 36, 18);
  g = drain();
  check(g.fwd == 2 && g.back == 0, "VM: one-finger flick left: Forward");

  int passed = swipe(mouse, 18);
  g = drain();
  check(g.f3 >= 14 && g.f0 == 1 && g.back + g.fwd == 0 && g.nf == 4,
        "VM: two-finger swipe, MouseSwipeFingers not set: four virtual fingers, then lifted (F 0)");
  check(g.lastX > g.firstX + 0.1f, "VM: the virtual fingers move the way the mouse fingers went (right)");
  check(passed <= 5, "VM: macOS's scrolling for the swipe is dropped (only before it was a swipe)");
  check(!scrollPasses(), "VM: macOS's scroll right after the swipe (its momentum) is dropped too");
  usleep((useconds_t)((MOUSE_SWIPE_HOLD + 0.1) * 1e6));
  check(scrollPasses(), "VM: half a second later scrolling passes again");
  passed = swipe(mouse, -18);
  g = drain();
  check(g.f3 >= 14 && g.lastX < g.firstX - 0.1f, "VM: two-finger swipe left: the virtual fingers move left");
  usleep((useconds_t)((MOUSE_SWIPE_HOLD + 0.1) * 1e6));

  fingerSettingChecks(mouse);

  // A second Magic Mouse (connected later): its own touches.
  addMouse(mouse2);
  flick(mouse2, 36, 18);
  g = drain();
  check(g.fwd == 2, "VM: a second Magic Mouse: its flick counts too");

  // With scroll momentum on (Glide): the same, and its scroll is not sent as "A"/"W".
  clients[0].glide = 1;
  swipe(mouse, 18);
  g = drain();
  check(g.f3 >= 14 && g.f0 == 1 && g.other == 0, "VM with scroll momentum: the swipe the same, no A/W lines");
  usleep((useconds_t)((MOUSE_SWIPE_HOLD + 0.1) * 1e6));
  clients[0].glide = 0;

  // Not captured (macOS in front, the VM in a window, after the escape combo).
  capturing = 0;
  flick(mouse, 18, 36);
  passed = swipe(mouse, 18);
  g = drain();
  check(g.f3 + g.f0 + g.back + g.fwd == 0 && passed == 21 && scrollPasses(),
        "not captured: nothing to the guest, macOS keeps the scrolling");
  // A VM with gestures off.
  capturing = 1; clients[0].gestures = 0;
  flick(mouse, 18, 36);
  passed = swipe(mouse, 18);
  g = drain();
  check(g.f3 + g.f0 + g.back + g.fwd == 0 && passed == 21, "VM with gestures off: nothing to the guest");

  printf("%s\n", fail ? "FAIL magic mouse" : "ok   magic mouse: swipes and flicks reach the VM, scrolling stays");
  return fail;
}
