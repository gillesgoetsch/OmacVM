// Offline test of the escape combo (test.sh): Ctrl+Option+Esc in the VM
// moves the display under the pointer one Space toward the one it showed
// before the VM, with macOS's own "Move left/right a space" shortcut (as the
// user set it in com.apple.symbolichotkeys); in macOS back into the VM. Each
// move is checked: not moved or the shortcut off -> a Dock swipe (macOS 15
// ignores the shortcut from the notched display's full-screen Space); still
// not moved, or no Spaces information -> a log line, nothing else (no notice
// in Omarchy, never Mission Control). The VM is never taken out of full screen and
// never hidden. Swipe out to macOS (#342): "X left|right" from the guest in
// front moves the same way, only to that side, silently nothing without a
// Space there. Drives the helper's own
// tapCb with made-up key events and its capture logic (frontChanged) with
// made-up front apps, against a made-up world of displays and Spaces whose
// "macOS" acts on the user's binding: the window server is not asked,
// nothing is posted, swiped or activated. No permissions, no VM.
#define main helper_main
#include "omacvm-gestures.c"
#undef main
#define HOTKEY_MISSION_CONTROL 32   // Ctrl+Up: the helper must never post it
#include <fcntl.h>
#include <sys/wait.h>

static int fail, peer;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) fail = 1;
}

// ---- the made-up world ----
typedef struct { CGDirectDisplayID id; CGRect b; uint64_t sp[8]; int n; uint64_t cur; } World;
static World world[2];
static int nWorld;
#define MAX_SPACE_ID 512
static pid_t owner[MAX_SPACE_ID];        // the app that is in front when this Space shows
static CGWindowID winOn[MAX_SPACE_ID];   // its window there
static pid_t hiddenPid;                  // the app hidden now (its windows are off screen)
static pid_t front, finder;
static CGPoint pointer;
static int keysIgnored;       // the Space shortcut reaches nothing (a VM app took it)
static int refuse, hidden, all, vmAlive = 1;
static int went, keys, spaceKeys, mcKeys, swipes, swipeMoves, signSaves;
static CGDirectDisplayID movedOn[4];
static pid_t wentTo; static CGWindowID wentWin;
static Hotkey lastKey;
static CFMutableDictionaryRef binding;   // the user's com.apple.symbolichotkeys (NULL: never changed)
static int mcWhileHeld;                  // Mission Control's key posted while the combo's keys were down
// mcSim: "macOS" shows Mission Control on its key: Desktop 1 listed as shown,
// the app in front kept; the key again closes it, back to the Space it came from.
static int mcSim, mcShown; static double mcLate; static uint64_t mcFrom;   // mcLate: closing lands this many verify periods late
static int fakeMCOpen(void) { return mcShown; }
static int heldPolls, heldAsked;         // the combo's keys still down for this many looks

static World *worldOf(CGDirectDisplayID id) {
  for (int i = 0; i < nWorld; i++) if (world[i].id == id) return &world[i];
  return NULL;
}
static int idx(World *w, uint64_t s) { for (int i = 0; i < w->n; i++) if (w->sp[i] == s) return i; return -1; }

static int fakeSpaces(DisplaySpaces *out, int cap) {
  int k = 0;
  for (int i = 0; i < nWorld && k < cap; i++, k++) {
    memset(&out[k], 0, sizeof out[k]);
    out[k].id = world[i].id; out[k].bounds = world[i].b; out[k].current = world[i].cur; out[k].n = world[i].n;
    memcpy(out[k].spaces, world[i].sp, sizeof world[i].sp);
  }
  return k;
}
static uint64_t fakeWindowSpace(CGWindowID win) {
  for (int s = 0; s < MAX_SPACE_ID; s++) if (win && winOn[s] == win) return (uint64_t)s;
  return 0;
}
// macOS acts on the display the pointer is on.
static World *underPointer(void) {
  for (int i = 0; i < nWorld; i++) if (CGRectContainsPoint(world[i].b, pointer)) return &world[i];
  return NULL;
}
// qemuGivesBack: OmacVM.app's QEMU puts the Mac's cursor back where the
// guest's pointer is (guestPointer) once a display's Space changed: the next
// warp after a Space change ends there.
static int qemuGivesBack, giveBackDue; static CGPoint guestPointer;
static void moveSpace(World *w, int dir) {
  if (!w) return;
  int i = idx(w, w->cur), j = i + dir;
  if (i < 0 || j < 0 || j >= w->n) return;   // the edge: nothing
  w->cur = w->sp[j];
  giveBackDue = qemuGivesBack;
  // With "Displays have separate Spaces" off, every display shows it.
  for (int k = 0; k < nWorld; k++) if (&world[k] != w && idx(&world[k], w->sp[j]) >= 0 && world[k].sp[0] == w->sp[0]) world[k].cur = w->cur;
  if (owner[w->cur] && owner[w->cur] != finder) front = owner[w->cur];
}
static int warps;
static void fakeWarp(CGPoint p) { warps++; pointer = giveBackDue ? guestPointer : p; giveBackDue = 0; }
static int same(Hotkey a, Hotkey b) { return a.enabled && b.enabled && a.keycode == b.keycode && a.flags == b.flags; }
// "macOS": the key is one of the user's Space shortcuts (as set now) -> that move.
static double lateKeys;   // macOS moves the Space only this many verify periods after the key
// lateKeys < 0: macOS moves it only when the test says so (landHeld), after
// every look, however slow the runner's timers are.
static World *heldWorld; static int heldDir, heldMove;
static int fakeKey(Hotkey k) {
  keys++; lastKey = k;
  Hotkey l = hotkeyFrom(binding, HOTKEY_SPACE_LEFT), r = hotkeyFrom(binding, HOTKEY_SPACE_RIGHT);
  Hotkey mc = hotkeyFrom(binding, HOTKEY_MISSION_CONTROL);
  World *w = underPointer();
  if (same(k, l) || same(k, r)) {
    if (spaceKeys < 4) movedOn[spaceKeys] = w ? w->id : 0;
    spaceKeys++;
    int dir = same(k, l) ? -1 : 1;
    if (!keysIgnored && lateKeys < 0) { heldMove = 1; heldWorld = w; heldDir = dir; }
    else if (!keysIgnored && lateKeys) {
      pendingSteps++;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(lateKeys * verifyAfter * NSEC_PER_SEC) + 3 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{ pendingSteps--; moveSpace(w, dir); });
    } else if (!keysIgnored) moveSpace(w, dir);
  } else if (same(k, mc)) {
    mcKeys++; if (heldPolls > 0) mcWhileHeld++;
    if (mcSim && w && !mcShown) { mcShown = 1; mcFrom = w->cur; w->cur = w->sp[0]; }
    else if (mcSim && w && mcShown && mcLate) {
      mcShown = 0; pendingSteps++;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(mcLate * verifyAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pendingSteps--; w->cur = mcFrom; if (owner[w->cur] && owner[w->cur] != finder) front = owner[w->cur]; });
    }
    else if (mcSim && w && mcShown) { mcShown = 0; w->cur = mcFrom; if (owner[w->cur] && owner[w->cur] != finder) front = owner[w->cur]; }
  }
  return 1;
}
// "macOS": a Dock swipe moves the display only when swipeMoves is set (the
// user's MacBook on macOS 15); its sign as the helper has it now.
static int fakeSwipe(CGDirectDisplayID id, CGRect b, int dir) {
  (void)b; swipes++;
  if (swipeMoves) moveSpace(worldOf(id), dir * swipeSign > 0 ? 1 : -1);
  return 1;
}
static void fakeSaveSign(void) { signSaves++; }   // never the real settings
static int mcApps;
static int fakeMissionApp(void) {   // never the real Mission Control
  mcApps++;
  World *w = underPointer();
  if (mcSim && w && mcShown) { mcShown = 0; w->cur = mcFrom; if (owner[w->cur] && owner[w->cur] != finder) front = owner[w->cur]; }
  return 1;
}
static CFDictionaryRef fakeHotkeys(void) { return binding ? CFRetain(binding) : NULL; }
static CGEventFlags fakeHeld(void) {
  heldAsked++;
  if (heldPolls > 0) { heldPolls--; return kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand; }
  return 0;
}
static CGPoint fakePointer(void) { return pointer; }
// The VM's on-screen windows: full screen on each display that shows its Space.
static int fakeVMWindows(pid_t pid, CGRect *out, int cap) {
  int k = 0;
  if (pid == hiddenPid) return 0;
  for (int i = 0; i < nWorld && k < cap; i++) if (owner[world[i].cur] == pid) out[k++] = world[i].b;
  return k;
}
static pid_t fakeTopApp(CGRect b, pid_t skip, CGWindowID *win) {
  for (int i = 0; i < nWorld; i++)
    if (CGRectEqualToRect(world[i].b, b) && owner[world[i].cur] != skip) {
      *win = winOn[world[i].cur];
      return owner[world[i].cur];
    }
  return 0;
}
// Activation: the app comes to the front, its window's Space shows.
static int fakeActivate(pid_t pid, CGWindowID win) {
  wentTo = pid; wentWin = win; went++;
  if (refuse) return 0;
  front = pid;
  if (pid == hiddenPid) hiddenPid = 0;   // activation unhides
  uint64_t s = fakeWindowSpace(win);
  for (int i = 0; s && i < nWorld; i++) if (idx(&world[i], s) >= 0) world[i].cur = s;
  return 1;
}
// All the VM's windows on any Space (one per display in full screen).
static int fakeAllVMWindows(pid_t pid, CGWindowID *out, int cap) {
  int k = 0;
  for (int sp = 0; sp < MAX_SPACE_ID && k < cap; sp++) if (owner[sp] == pid && winOn[sp]) out[k++] = winOn[sp];
  return k;
}
// The guest's answer to "Q" (the escape combo asks which display has the
// VM's focus): this line at once, NULL for none (a guest from before 3.1.32).
static const char *focusReply; static int asks;
static void fakeAskFocus(void) { asks++; if (focusReply) guestLine(clients[0].fd, clients[0].gen, focusReply); }
static int fakeHide(pid_t pid) { hidden++; hiddenPid = pid; if (front == pid) front = finder; return 1; }
static pid_t fakeFront(void) { return front; }
static pid_t fakeFinder(void) { return finder; }
static int fakeAll(void) { return all; }
static int fakeVMWindow(pid_t pid, CGWindowID win) { (void)win; return vmAlive && alive(pid); }
static int soOn;   // the made-up SwipeOut setting
static int fakeSwipeOut(void) { return soOn; }
// A guest's reader (readGuest) on its own thread, as greet() runs it.
typedef struct { int rd, fd; unsigned gen; volatile int done; } ReaderArg;
static void *readerThread(void *a) { ReaderArg *r = a; readGuest(r->rd, r->fd, r->gen); r->done = 1; return NULL; }
static pid_t launcher;   // OmacVM.app's launcher: the VMs' process name, but no QEMU
static int fakeIsQemu(pid_t pid) { return pid != launcher; }

// ---- swipe out that follows the fingers: a made-up trackpad, Magic Mouse and Dock ----
static void settleSteps(void);
static int fakePadDev, fakeMouseDev;
static double clk;                     // the takeover's clock (8 ms a frame)
static double fakeClock(void) { return clk; }
static int fakeHidOff(void) { return 0; }
typedef struct { int phase; double p, v; } DockEv;
static DockEv dockEv[1024];
static int nDockEv;
static int dockFollow = 1;   // "macOS": a finished swipe moves the Space under it
static int dockSign = 1;     // -1: a macOS that reads the progress the other way (a MacBook Pro on 15.7)
static int fakeDockPost(int phase, double progress, double speed, CGPoint at) {
  if (nDockEv < 1024) dockEv[nDockEv++] = (DockEv){ phase, progress, speed };
  if (phase == kSwipeEnded && dockFollow)
    for (int i = 0; i < nWorld; i++) if (CGRectContainsPoint(world[i].b, at)) moveSpace(&world[i], progress * dockSign < 0 ? 1 : -1);
  return 1;
}
static int dockLast(void) { return nDockEv ? dockEv[nDockEv - 1].phase : 0; }
static int dockCount(int phase) { int n = 0; for (int i = 0; i < nDockEv; i++) n += dockEv[i].phase == phase; return n; }

// One trackpad frame: k fingers side by side around x (0..1 of the width), y (up).
static void pad(int k, double x, double y) {
  MTTouch t[8]; memset(t, 0, sizeof t);
  for (int i = 0; i < k; i++) {
    t[i].pathIndex = 3 + i; t[i].state = 4; t[i].zTotal = 0.5f;
    t[i].normalized.pos.x = (float)(x - 0.05 * (k - 1) / 2 + 0.05 * i); t[i].normalized.pos.y = (float)y;
  }
  frameCb((MTDeviceRef)&fakePadDev, t, k, 0, 0);
  clk += 0.008;
}
// k fingers at x, x + 0.06, ... (each keeps its place when another comes down).
static void padAt(int k, double x) {
  MTTouch t[8]; memset(t, 0, sizeof t);
  for (int i = 0; i < k; i++) {
    t[i].pathIndex = 3 + i; t[i].state = 4; t[i].zTotal = 0.5f;
    t[i].normalized.pos.x = (float)(x + 0.06 * i); t[i].normalized.pos.y = 0.5f;
  }
  frameCb((MTDeviceRef)&fakePadDev, t, k, 0, 0);
  clk += 0.008;
}
// A four-finger swipe as a hand makes it: three fingers come down, the 4th a
// frame later, then all of them move from x0 to x1.
static void padFour(double x0, double x1, int steps) {
  padAt(3, x0); padAt(4, x0);
  for (int s = 1; s <= steps; s++) padAt(4, x0 + (x1 - x0) * s / steps);
}
// k fingers from x0 to x1 (y0 to y1) in steps frames of 8 ms.
static void padMove(int k, double x0, double x1, double y0, double y1, int steps) {
  for (int s = 0; s <= steps; s++) pad(k, x0 + (x1 - x0) * s / steps, y0 + (y1 - y0) * s / steps);
}
static void padSwipe(int k, double x0, double x1, int steps) { padMove(k, x0, x1, 0.5, 0.5, steps); }
static void padLift(void) { pad(0, 0, 0); settleSteps(); }
// One Magic Mouse frame: two fingers at x (0..1 across the mouse).
static void mouse2(double x) {
  MTTouch t[2]; memset(t, 0, sizeof t);
  for (int i = 0; i < 2; i++) {
    t[i].pathIndex = 7 + i; t[i].state = 4; t[i].zTotal = 0.5f;
    t[i].normalized.pos.x = (float)(x + 0.15 * i); t[i].normalized.pos.y = 0.5f;
  }
  mouseFrameCb((MTDeviceRef)&fakeMouseDev, t, 2, 0, 0);
  clk += 0.008;
}
static void mouseLift(void) { mouseFrameCb((MTDeviceRef)&fakeMouseDev, NULL, 0, 0, 0); clk += 0.008; settleSteps(); }
// What the guest got since the last look: finger frames, lifts ("F 0") and
// the other lines (joined by '|').
static int gotFrames, gotLifts;
static char gotOther[512];
static void guestGot(void) {
  static char buf[262144];
  size_t n = 0; ssize_t r;
  usleep(2000);
  while (n < sizeof buf - 1 && (r = read(peer, buf + n, sizeof buf - 1 - n)) > 0) n += (size_t)r;
  buf[n] = 0;
  gotFrames = gotLifts = 0; gotOther[0] = 0;
  for (char *s = buf, *l; (l = strsep(&s, "\n"));) {
    if (!l[0]) continue;
    if (!strcmp(l, "F 0")) gotLifts++;
    else if (!strncmp(l, "F ", 2)) gotFrames++;
    else { strlcat(gotOther, l, sizeof gotOther); strlcat(gotOther, "|", sizeof gotOther); }
  }
}

// The user's shortcut table: one entry.
static void setKey(int id, CFTypeRef enabled, int64_t code, int64_t mods) {
  if (!binding) binding = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  int64_t ch = 65535;
  CFNumberRef p[3] = { CFNumberCreate(NULL, kCFNumberSInt64Type, &ch), CFNumberCreate(NULL, kCFNumberSInt64Type, &code),
                       CFNumberCreate(NULL, kCFNumberSInt64Type, &mods) };
  CFArrayRef params = CFArrayCreate(NULL, (const void **)p, 3, &kCFTypeArrayCallBacks);
  const void *vk[] = { CFSTR("parameters"), CFSTR("type") }, *vv[] = { params, CFSTR("standard") };
  CFDictionaryRef value = CFDictionaryCreate(NULL, vk, vv, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  const void *ek[] = { CFSTR("enabled"), CFSTR("value") }, *ev[] = { enabled, value };
  CFDictionaryRef entry = CFDictionaryCreate(NULL, ek, ev, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  char name[16]; snprintf(name, sizeof name, "%d", id);
  CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
  CFDictionarySetValue(binding, key, entry);
  CFRelease(key); CFRelease(entry); CFRelease(value); CFRelease(params);
  for (int i = 0; i < 3; i++) CFRelease(p[i]);
}
static void unsetKeys(void) { if (binding) CFRelease(binding); binding = NULL; }

// What the guest got since the last call, lines joined by '|'.
static const char *sent(void) {
  static char out[256];
  out[0] = 0; usleep(2000);
  ssize_t n = read(peer, out, sizeof out - 1);
  out[n > 0 ? n : 0] = 0;
  for (char *c = out; *c; c++) if (*c == '\n') *c = '|';
  return out;
}

static CGEventRef key(int down, CGEventFlags f, int64_t state, int repeat) {
  CGEventRef e = CGEventCreateKeyboardEvent(NULL, ESC_KEYCODE, down);
  CGEventSetFlags(e, f);
  CGEventSetIntegerValueField(e, kCGEventSourceStateID, state);
  if (repeat) CGEventSetIntegerValueField(e, kCGKeyboardEventAutorepeat, 1);
  return e;
}

// Runs the main queue until the combo's steps are all done (a slow CI
// machine takes longer than this Mac), at most 5 s.
static void settleSteps(void) {
  for (int i = 0; i < 250 && (i < 2 || pendingSteps > 0); i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
}

// Press and release; 1 if both were eaten, 0 if both passed, -1 mixed. Runs
// the main queue so the moves, their checks and the fallbacks happen.
static int press(CGEventFlags f, int64_t state, int repeat) {
  went = hidden = keys = spaceKeys = mcKeys = swipes = 0;
  CGEventRef d = key(1, f, state, repeat), u = key(0, f, state, 0);
  CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL), ru = tapCb(NULL, kCGEventKeyUp, u, NULL);
  CFRelease(d); CFRelease(u);
  settleSteps();
  return !rd && !ru ? 1 : rd && ru ? 0 : -1;
}

// What the capture check would find now (front app, its full-screen window).
static void settle(pid_t vm, int net) {
  if (front == vm) frontChanged(vm, net, 1, "Omarchy", vmWin, 0);
  else frontChanged(front, -1, 0, "", front == finder ? 0 : winOn[world[0].cur], 1);
}

// The VM full screen in front on display 1's Space s, captured; nothing pending.
static void inVM(pid_t vm, uint64_t s) {
  front = vm; world[0].cur = s;
  frontChanged(vm, NET_APP, 1, "Omarchy", winOn[s], 0); sent();
}

static pid_t child(void) { pid_t p = fork(); if (p == 0) { pause(); _exit(0); } return p; }
static void end(pid_t p) { kill(p, SIGKILL); waitpid(p, NULL, 0); }

static void layout(int displays, const uint64_t *a, int na, const uint64_t *b, int nb) {
  nWorld = displays;
  memset(world, 0, sizeof world);
  world[0].id = 1; world[0].b = CGRectMake(0, 0, 2560, 1440);
  memcpy(world[0].sp, a, sizeof *a * (size_t)na); world[0].n = na;
  if (displays > 1) {
    world[1].id = 2; world[1].b = CGRectMake(2560, 0, 1920, 1200);
    memcpy(world[1].sp, b, sizeof *b * (size_t)nb); world[1].n = nb;
  }
  memset(left, 0, sizeof left);
  memset(cameFrom, 0, sizeof cameFrom);
}

int main(void) {
  activateFn = fakeActivate; finderFn = fakeFinder; frontFn = fakeFront; vmWindowFn = fakeVMWindow;
  spacesFn = fakeSpaces; windowSpaceFn = fakeWindowSpace; pointerFn = fakePointer;
  vmWindowsFn = fakeVMWindows; vmAllWindowsFn = fakeAllVMWindows; askFocusFn = fakeAskFocus; focusWait = 0.05; topAppFn = fakeTopApp; hideFn = fakeHide; escapeAllFn = fakeAll;
  warpFn = fakeWarp; warpSettle = 0; isQemuFn = fakeIsQemu;
  hotkeysFn = fakeHotkeys; keyFn = fakeKey; heldFn = fakeHeld;
  swipeFn = fakeSwipe; saveSignFn = fakeSaveSign; swipeOutFn = fakeSwipeOut; swipeOutEvery = 0; swipeOutGap = 0;
  verifyAfter = 0.01; cameFromEvery = 0; doublePress = 0; missionAppFn = fakeMissionApp; missionControlOpenFn = fakeMCOpen;
  mcClosing = 0;
  initKeymap();
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  int sv[2]; socketpair(AF_UNIX, SOCK_STREAM, 0, sv); peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1;
  snprintf(clients[0].name, sizeof clients[0].name, "Omarchy");
  snprintf(clients[0].ip, sizeof clients[0].ip, "127.0.0.1");
  const CGEventFlags C = kCGEventFlagMaskControl, O = kCGEventFlagMaskAlternate, M = kCGEventFlagMaskCommand;
  const CGEventFlags S = kCGEventFlagMaskShift;
  const CGEventFlags K = C | O;   // the escape combo (3.0.0); C|O|M is the old one, kept through 3.0.x
  const CGEventFlags FN = kCGEventFlagMaskSecondaryFn, PAD = kCGEventFlagMaskNumericPad;
  const int64_t HID = kCGEventSourceStateHIDSystemState, POSTED = kCGEventSourceStateCombinedSessionState;
  pid_t terminal = child(), vm = child(), parallels = child(), safari = child();
  finder = child();

  // ---- The user's binding, as macOS keeps it ----
  Hotkey h = hotkeyFrom(NULL, HOTKEY_SPACE_LEFT);
  check(h.enabled && h.keycode == 123 && h.flags == (C | FN), "binding: never changed: Move left a space is Ctrl+Left, on");
  h = hotkeyFrom(NULL, HOTKEY_SPACE_RIGHT);
  check(h.enabled && h.keycode == 124, "binding: ... Move right a space Ctrl+Right");
  h = hotkeyFrom(NULL, HOTKEY_MISSION_CONTROL);
  check(h.enabled && h.keycode == 126, "binding: ... Mission Control Ctrl+Up");
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanTrue, 123, 8650752);   // as the mini has it
  h = hotkeyFrom(binding, HOTKEY_SPACE_LEFT);
  check(h.enabled && h.keycode == 123 && h.flags == (C | FN), "binding: the mini's 79 (123, 8650752): Ctrl+Left, on");
  int one = 1, zero = 0;
  CFNumberRef n1 = CFNumberCreate(NULL, kCFNumberIntType, &one), n0 = CFNumberCreate(NULL, kCFNumberIntType, &zero);
  setKey(HOTKEY_SPACE_LEFT, n0, 123, 8650752);
  check(!hotkeyFrom(binding, HOTKEY_SPACE_LEFT).enabled, "binding: enabled = 0 (a number): off");
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanFalse, 123, 8650752);
  check(!hotkeyFrom(binding, HOTKEY_SPACE_LEFT).enabled, "binding: enabled = false: off");
  setKey(HOTKEY_SPACE_LEFT, n1, 65535, 0);
  check(!hotkeyFrom(binding, HOTKEY_SPACE_LEFT).enabled, "binding: no key set (65535): off");
  setKey(HOTKEY_SPACE_LEFT, n1, 33, 0x180000);   // Option+Cmd+[
  h = hotkeyFrom(binding, HOTKEY_SPACE_LEFT);
  check(h.enabled && h.keycode == 33 && h.flags == (O | M), "binding: changed to Option+Cmd+[: that key, those modifiers");
  check(hotkeyFrom(binding, HOTKEY_SPACE_RIGHT).enabled && hotkeyFrom(binding, HOTKEY_SPACE_RIGHT).keycode == 124,
        "binding: ... the right one not listed: still the default");
  CFMutableDictionaryRef odd = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(odd, CFSTR("79"), CFSTR("junk"));
  check(hotkeyFrom(odd, HOTKEY_SPACE_LEFT).keycode == 123 && hotkeyFrom((CFDictionaryRef)CFSTR("x"), 79).keycode == 123,
        "binding: junk in the file: the default");
  CFRelease(odd);
  unsetKeys();

  // ---- The posted key: the shape macOS gets from a keyboard, marked as ours ----
  h = hotkeyFrom(NULL, HOTKEY_SPACE_LEFT);
  CGEventRef kd = hotkeyEvent(h, 1), ku = hotkeyEvent(h, 0);
  check(kd && ku && CGEventGetType(kd) == kCGEventKeyDown && CGEventGetType(ku) == kCGEventKeyUp,
        "posted key: a key down, then a key up");
  check(CGEventGetIntegerValueField(kd, kCGKeyboardEventKeycode) == 123 && CGEventGetIntegerValueField(ku, kCGKeyboardEventKeycode) == 123,
        "posted key: ... the binding's key (123, Left)");
  check((CGEventGetFlags(kd) & HOTKEY_MODS) == (C | FN | PAD) && (CGEventGetFlags(ku) & HOTKEY_MODS) == (C | FN | PAD),
        "posted key: ... Ctrl + fn + keypad (an arrow key, as the keyboard sends it), no Option/Cmd");
  check(CGEventGetIntegerValueField(kd, kCGEventSourceUserData) == OMACVM_KEY_MARKER &&
        CGEventGetIntegerValueField(ku, kCGEventSourceUserData) == OMACVM_KEY_MARKER, "posted key: ... with our marker");
  CFRelease(kd); CFRelease(ku);
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanTrue, 33, 0x180000);
  kd = hotkeyEvent(hotkeyFrom(binding, HOTKEY_SPACE_LEFT), 1);
  check(CGEventGetIntegerValueField(kd, kCGKeyboardEventKeycode) == 33 && (CGEventGetFlags(kd) & HOTKEY_MODS) == (O | M),
        "posted key: a changed binding: its key and modifiers, no fn (not an arrow)");
  // Our tap lets it through even while it would take Cmd keys for the VM.
  frontNet = NET_APP; capturing = 1;
  pthread_mutex_lock(&sendLock); clients[0].target = 1; pthread_mutex_unlock(&sendLock);
  check(tapCb(NULL, kCGEventKeyDown, kd, NULL) == kd && !strcmp(sent(), ""), "posted key: our tap lets it through (no Super to the VM)");
  CGEventRef plain = CGEventCreateKeyboardEvent(NULL, 33, 1);
  CGEventSetFlags(plain, O | M);
  check(tapCb(NULL, kCGEventKeyDown, plain, NULL) == NULL, "... the same keys from the keyboard while captured: the VM's (Super)");
  CGEventRef plainUp = CGEventCreateKeyboardEvent(NULL, 33, 0);
  tapCb(NULL, kCGEventKeyUp, plainUp, NULL); sent();
  CFRelease(kd); CFRelease(plain); CFRelease(plainUp);
  capturing = 0;
  unsetKeys();

  // ---- A Mac mini with one display: Desktop 1 (Terminal), the VM's full-screen Space ----
  const uint64_t mini[] = { 101, 102 };
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
  pointer = CGPointMake(1000, 700);
  front = terminal; world[0].cur = 101;
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(K, HID, 0) == 0 && !went && !keys, "in macOS before any VM: the combo passes, nothing happens");
  front = vm; world[0].cur = 102;
  frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);
  check(!strcmp(sent(), "S on|"), "VM full screen in front: captured");

  check(press(K, HID, 0) == 1, "mini: combo in the VM: eaten (down and up)");
  check(!strcmp(sent(), "S esc ctrl-opt|") && !capturing, "... Omarchy lets go (S esc ctrl-opt), capture off at once");
  check(spaceKeys == 1 && lastKey.keycode == 123 && world[0].cur == 101, "... macOS's Move left a space (Ctrl+Left): Desktop 1");
  check(!mcKeys, "... no Mission Control");
  check(front == terminal && !went && !hidden, "... the keyboard is Terminal's (no app switch), the VM not hidden");
  settle(vm, NET_APP);
  check(!escaped && !strcmp(sent(), ""), "on Desktop 1: nothing more sent, capture re-arms");

  check(press(K, HID, 0) == 1, "mini: combo in macOS: eaten");
  check(spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 102 && front == vm && !went,
        "... Move right a space: back to the VM, which has the keyboard");
  settle(vm, NET_APP);
  check(capturing && !strcmp(sent(), "S on|"), "... and it is captured again");

  // The combo's keys still down: the shortcut waits until they are up.
  heldPolls = 5; heldAsked = 0;
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 101 && heldAsked >= 6,
        "keys still held: the shortcut goes once they are up");
  sent(); settle(vm, NET_APP);
  heldPolls = 1000; heldAsked = 0;
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 102 && heldAsked == 50,
        "... held on and on: after 1 s it goes anyway");
  heldPolls = 0;
  settle(vm, NET_APP); sent();

  // A changed binding: the user's own keys are posted.
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanTrue, 33, 0x180000);
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && lastKey.keycode == 33 && lastKey.flags == (O | M) && world[0].cur == 101,
        "binding changed to Option+Cmd+[: that is what is posted, it moves");
  unsetKeys(); sent(); settle(vm, NET_APP); inVM(vm, 102);

  // ---- Toward the Space the user came from ----
  const uint64_t three[] = { 101, 102, 103 };
  layout(1, three, 3, NULL, 0);
  owner[103] = safari; winOn[103] = 33;
  front = safari; world[0].cur = 103; settle(vm, NET_APP);   // Safari's Space before the VM
  inVM(vm, 102);
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 103 && front == safari,
        "came from the Space on the right (Safari): Move right a space, back to it");
  settle(vm, NET_APP); sent();
  check(press(K, HID, 0) == 1 && lastKey.keycode == 123 && world[0].cur == 102 && front == vm, "... and back in: Move left");
  settle(vm, NET_APP); sent();
  front = terminal; world[0].cur = 101; settle(vm, NET_APP);   // now from Terminal's, on the left
  inVM(vm, 102);
  check(press(K, HID, 0) == 1 && lastKey.keycode == 123 && world[0].cur == 101 && front == terminal,
        "came from the Space on the left (Terminal): Move left a space");
  settle(vm, NET_APP); sent();
  // Unknown (the helper started with the VM in front): left, else right.
  memset(cameFrom, 0, sizeof cameFrom); inVM(vm, 102);
  check(press(K, HID, 0) == 1 && lastKey.keycode == 123 && world[0].cur == 101, "not known where from: left");
  settle(vm, NET_APP); sent();
  const uint64_t vmFirst[] = { 102, 101 };
  layout(1, vmFirst, 2, NULL, 0);
  inVM(vm, 102);
  check(press(K, HID, 0) == 1 && lastKey.keycode == 124 && world[0].cur == 101, "... the VM's Space the first one: right");
  settle(vm, NET_APP); sent();
  DisplaySpaces d = { .n = 4, .spaces = { 1, 2, 3, 4 }, .current = 2 };
  check(leaveDir(&d, 4) == 1 && leaveDir(&d, 1) == -1 && leaveDir(&d, 2) == -1 && leaveDir(&d, 9) == -1 && leaveDir(&d, 0) == -1,
        "plan: toward where from (two away: one step that way); from = the VM's, gone or unknown: left");
  d.current = 1;
  check(leaveDir(&d, 0) == 1, "plan: ... from the first Space: right");
  d.n = 1;
  check(leaveDir(&d, 0) == 0, "plan: a single Space: no move");

  // ---- Checked; no way out -> nothing (a log line, no notice); never out
  // of full screen, never hidden, never Mission Control ----
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; owner[102] = vm;
  front = terminal; world[0].cur = 101; settle(vm, NET_APP); inVM(vm, 102);
  // The shortcut reaches nothing (an old VM runtime took it, macOS 27 on the mini).
  keysIgnored = 1;
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && swipes == 2 && world[0].cur == 102,
        "shortcut did not move, nor the swipe (both ways): the VM's Space stays");
  check(!strcmp(sent(), "S esc ctrl-opt|"), "... no notice in Omarchy (no N line)");
  check(!mcKeys && !hidden && !went && keys == 1, "... no Mission Control, nothing hidden, no app switch, one key only");
  check(!capturing && escaped, "... capture off (the trackpad and keys are macOS's, as after any escape)");
  int r = press(K, HID, 0); const char *got = sent();
  check(r == 1 && capturing && !keys && !strcmp(got, "S on|"), "... the combo again there: captured again, nothing moves");
  // Back in, the shortcut ignored: the VM's window to the front (its Space shows).
  keysIgnored = 0;
  press(K, HID, 0); sent(); settle(vm, NET_APP); sent();
  check(world[0].cur == 101 && front == terminal, "(out again with the shortcut working)");
  keysIgnored = 1;
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && went >= 1 && wentTo == vm && world[0].cur == 102 && front == vm,
        "back in, the shortcut did not move: the VM's window to the front instead");
  keysIgnored = 0;
  settle(vm, NET_APP); sent();
  // macOS 15 from the notched display's full-screen Space (user's log, 10:13-10:18):
  // the shortcut does nothing, the Dock swipe moves it. Out, no Mission Control.
  keysIgnored = 1; swipeMoves = 1;
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && swipes == 1 && world[0].cur == 101 && !mcKeys && !hidden &&
        !strcmp(sent(), "S esc ctrl-opt|"), "shortcut ignored, the Dock swipe moves out: one swipe, no notice, no Mission Control");
  check(!capturing && escaped, "... capture off");
  keysIgnored = 0; swipeMoves = 0;
  settle(vm, NET_APP); sent();
  press(K, HID, 0); sent(); settle(vm, NET_APP); sent();
  check(world[0].cur == 102 && front == vm, "... and back in with the shortcut");
  // The swipe goes the other way at first (sign not known): learned, kept, out.
  keysIgnored = 1; swipeMoves = 1; swipeSign = -1; signSaves = 0;
  check(press(K, HID, 0) == 1 && world[0].cur == 101 && swipeSign == 1 && signSaves == 1 && !mcKeys,
        "the swipe bounced at the edge: the other direction lands and is kept");
  keysIgnored = 0; swipeMoves = 0; sent();
  settle(vm, NET_APP); sent(); press(K, HID, 0); sent(); settle(vm, NET_APP); sent();
  // The shortcut off: nothing posted, no notice.
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanFalse, 123, 8650752);
  check(press(K, HID, 0) == 1 && !keys && swipes == 2 && world[0].cur == 102 && !mcKeys && !hidden && !went,
        "Move left a space off: no key posted, the swipe does not move either, no Mission Control");
  check(!strcmp(sent(), "S esc ctrl-opt|"), "... no notice in Omarchy");
  press(K, HID, 0); sent(); unsetKeys(); inVM(vm, 102);
  // Every shortcut off, Mission Control's too: still nothing.
  setKey(HOTKEY_SPACE_LEFT, kCFBooleanFalse, 123, 8650752); setKey(HOTKEY_SPACE_RIGHT, kCFBooleanFalse, 124, 8650752);
  setKey(HOTKEY_MISSION_CONTROL, kCFBooleanFalse, 126, 8650752);
  check(press(K, HID, 0) == 1 && !keys && world[0].cur == 102 && !hidden && !went &&
        !strcmp(sent(), "S esc ctrl-opt|"), "every shortcut off: nothing, no notice");
  unsetKeys();
  press(K, HID, 0); sent(); inVM(vm, 102);

  // The Mac mini at 12:58 and 15:25: nothing moved and Finder had no window.
  end(terminal); terminal = child(); owner[101] = terminal;   // the app from before has quit
  keysIgnored = 1;
  check(press(K, HID, 0) == 1 && !mcKeys && !went && !hidden && world[0].cur == 102,
        "mini, nothing moves (the app from before has quit): not Finder, not hidden, no Mission Control");
  keysIgnored = 0;
  press(K, HID, 0); sent(); inVM(vm, 102);

  // No Spaces information (an older or newer macOS without the call): nothing.
  int saveN = nWorld; nWorld = 0;
  check(press(K, HID, 0) == 1 && !spaceKeys && !mcKeys && !went && !hidden && !strcmp(sent(), "S esc ctrl-opt|"),
        "no Spaces information: nothing, no notice");
  nWorld = saveN;
  press(K, HID, 0); sent(); inVM(vm, 102);

  // ---- A MacBook and an external display, the VM full screen on both ----
  const uint64_t inner[] = { 201, 202 }, outer[] = { 301, 302 };
  layout(2, inner, 2, outer, 2);
  owner[201] = terminal; winOn[201] = 11; owner[202] = vm; winOn[202] = 22;
  owner[301] = safari; winOn[301] = 44; owner[302] = vm; winOn[302] = 23;
  world[0].cur = 202; world[1].cur = 302; front = vm;
  pointer = CGPointMake(3000, 600);   // on the external display
  settle(vm, NET_APP); sent();
  owner[301] = finder;   // the external's desktop shows no app: Finder
  warps = 0;
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 2 && !warps,
        "two displays: only the display under the pointer moves (no warp needed)");
  check(world[1].cur == 301 && world[0].cur == 202, "... the external shows its desktop, the MacBook still the VM");
  check(went == 1 && wentTo == finder && front == finder && !hidden, "... the keyboard follows the pointer (Finder, the desktop there)");
  settle(vm, NET_APP);
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 2 && world[1].cur == 302, "... the combo there moves it back");
  check(front == vm, "... and the VM has the keyboard");
  settle(vm, NET_APP); sent();
  owner[301] = safari;

  // The pointer on a display without the VM: nothing moves, the keyboard goes there.
  world[1].cur = 301;
  check(press(K, HID, 0) == 1 && !keys && went == 1 && wentTo == safari && wentWin == 44 && world[0].cur == 202,
        "pointer on a display without the VM: no move, the keyboard goes to what it shows");
  sent(); settle(vm, NET_APP);
  world[1].cur = 302; front = vm; settle(vm, NET_APP); sent();

  // "Swipe all monitors": macOS moves the pointer's display only, so the
  // pointer visits the other display for its shortcut and comes back.
  all = 1; warps = 0;
  CGPoint before = pointer;
  check(press(K, HID, 0) == 1 && spaceKeys == 2 && world[0].cur == 201 && world[1].cur == 301, "all: both displays move out of the VM");
  check(movedOn[0] != movedOn[1] && warps == 2 && pointer.x == before.x && pointer.y == before.y,
        "all: ... one shortcut on each display (the pointer went there and back)");
  sent(); settle(vm, NET_APP);
  check(press(K, HID, 0) == 1 && spaceKeys == 2 && world[0].cur == 202 && world[1].cur == 302 && front == vm,
        "all: ... and both back into it");
  settle(vm, NET_APP); sent();
  // Neither display moves: nothing, no notice.
  keysIgnored = 1;
  check(press(K, HID, 0) == 1 && spaceKeys == 2 && world[0].cur == 202 && world[1].cur == 302 && !mcKeys &&
        !strcmp(sent(), "S esc ctrl-opt|"), "all, the shortcut ignored: nothing moves, no notice");
  keysIgnored = 0;
  press(K, HID, 0); sent(); front = vm; world[0].cur = 202; world[1].cur = 302; settle(vm, NET_APP); sent();
  all = 0;

  // "Displays have separate Spaces" off: one list of Spaces for both displays.
  const uint64_t shared[] = { 401, 402 };
  layout(2, shared, 2, shared, 2);
  owner[401] = terminal; winOn[401] = 11; owner[402] = vm; winOn[402] = 22;
  world[0].cur = world[1].cur = 402; front = vm; all = 1;
  settle(vm, NET_APP); sent();
  check(press(K, HID, 0) == 1 && spaceKeys == 1, "Spaces shared by the displays, all: one shortcut, not two");
  sent(); settle(vm, NET_APP);
  all = 0;

  // ---- The VM full screen on both displays (OmacVM.app: its main window on
  // the MacBook, a second window on the external, each its own Space); the
  // external left by hand (a swipe), so the combo did not note where from.
  // In macOS with the pointer on the external, the combo goes back into the
  // VM's Space there, not the main window's (that display stays as it is) ----
  {
    const uint64_t mbp[] = { 211, 212 }, ext[] = { 311, 312 };
    layout(2, mbp, 2, ext, 2);
    owner[211] = terminal; winOn[211] = 11; owner[212] = vm; winOn[212] = 27;
    owner[311] = safari; winOn[311] = 44; owner[312] = vm; winOn[312] = 28;
    world[0].cur = 212; world[1].cur = 312; front = vm; pointer = CGPointMake(3000, 600);
    frontChanged(vm, NET_APP, 1, "Omarchy", 27, 0); sent();
    world[1].cur = 311; front = safari;   // swiped out on the external
    frontChanged(safari, -1, 0, "", 44, 1); sent();
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && lastKey.keycode == 124 && movedOn[0] == 2,
          "external left by hand: the combo there moves the external back (Move right a space)");
    check(world[1].cur == 312 && world[0].cur == 212 && front == vm, "... into the VM's Space on the external; the MacBook as it was");
    frontChanged(vm, NET_APP, 1, "Omarchy", 27, 0); sent();
    // The VM's Space on the external not beside the one shown: its window
    // there to the front (macOS shows its Space), not the main window.
    const uint64_t ext3[] = { 311, 313, 312 };
    layout(2, mbp, 2, ext3, 3);
    owner[313] = finder;
    world[0].cur = 211; world[1].cur = 311; front = safari; pointer = CGPointMake(3000, 600);
    frontChanged(safari, -1, 0, "", 44, 1); sent(); wentTo = 0; wentWin = 0;
    check(press(K, HID, 0) == 1 && !spaceKeys && wentTo == vm && wentWin == 28 && world[1].cur == 312,
          "... two Spaces away: the VM's window on the external to the front, not the main window");
    check(world[0].cur == 211, "... the MacBook stays on its desktop");
    frontChanged(vm, NET_APP, 1, "Omarchy", 27, 0); sent();
    // Left by the combo: as before, back to the Space it left.
    world[0].cur = 212; world[1].cur = 312; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 27, 0); sent();
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[1].cur == 313 && world[0].cur == 212,
          "the combo on the external: out there only (one Space toward where it came from)");
    settle(vm, NET_APP); sent();
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[1].cur == 312 && world[0].cur == 212 && front == vm, "... and back in there");
    settle(vm, NET_APP); sent();
    owner[313] = 0;
  }

  // ---- "Focused monitor" with the VM on both displays: the display with the
  // VM's own focus (Hyprland's focused output, which the guest says on "Q"),
  // not the one the Mac's pointer was left on (Omarchy does not warp the
  // pointer when the focus moves by keyboard) ----
  {
    const uint64_t mbp[] = { 221, 222 }, ext[] = { 321, 322 };
    layout(2, mbp, 2, ext, 2);
    owner[221] = terminal; winOn[221] = 11; owner[222] = vm; winOn[222] = 29;
    owner[321] = safari; winOn[321] = 44; owner[322] = vm; winOn[322] = 30;
    world[0].cur = 221; world[1].cur = 321; front = terminal; pointer = CGPointMake(1000, 700);
    frontChanged(terminal, -1, 0, "", 11, 1); sent();
    world[0].cur = 222; world[1].cur = 322; front = vm;
    frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent();
    // The real question goes over the connection as "Q".
    askFocus();
    check(!strcmp(sent(), "Q|"), "focus: the question to the guest is \"Q\"");
    focusReply = "D 2560 0 1920 1200"; asks = 0; warps = 0;   // Hyprland's focus on the external
    check(press(K, HID, 0) == 1 && asks == 1 && spaceKeys == 1 && movedOn[0] == 2,
          "focus on the external, pointer on the MacBook: the external moves out");
    check(world[1].cur == 321 && world[0].cur == 222 && warps == 2, "... the MacBook stays on the VM (the pointer went there and back)");
    settle(vm, NET_APP); sent();
    // Back in from macOS: where the pointer is (macOS's focus), as before: the
    // pointer is on the MacBook, which shows the VM, so the external comes back.
    front = safari; frontChanged(safari, -1, 0, "", 44, 1); sent();
    world[1].cur = 322; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent();
    focusReply = "D -"; asks = 0;
    check(press(K, HID, 0) == 1 && asks == 1 && spaceKeys == 1 && movedOn[0] == 1 && world[0].cur == 221 && world[1].cur == 322,
          "the guest does not know (\"D -\"): the pointer's display, as before");
    sent(); front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
    world[0].cur = 222; world[1].cur = 322; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent(); warps = 0;
    focusReply = "D 0 0 2560 1440";
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 1 && world[0].cur == 221 && !warps,
          "focus where the pointer is: that display, no detour");
    sent(); front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
    world[0].cur = 222; world[1].cur = 322; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent(); warps = 0;
    focusReply = "D 9000 9000 100 100";
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 1 && world[1].cur == 322,
          "a place on no display of the VM: the pointer's display");
    sent(); front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
    world[0].cur = 222; world[1].cur = 322; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent(); warps = 0;
    focusReply = "D 1 2 x"; 
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 1, "junk for an answer: not taken, the pointer's display after the wait");
    sent(); front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
    world[0].cur = 222; world[1].cur = 322; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent(); warps = 0;
    // No answer (a guest from before 3.1.32): the pointer's display after the
    // wait, and that guest is not waited for again.
    check(clients[0].focusSilent, "... junk counts as no answer");
    focusReply = NULL; asks = 0; clients[0].focusSilent = 0;
    double t0 = monoNow();
    check(press(K, HID, 0) == 1 && asks == 1 && spaceKeys == 1 && movedOn[0] == 1 && monoNow() - t0 >= focusWait,
          "no answer: the pointer's display, after waiting focusWait");
    check(clients[0].focusSilent, "... that guest is not waited for again");
    sent(); front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
    world[0].cur = 222; world[1].cur = 322; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent(); warps = 0;
    focusReply = "D 2560 0 1920 1200";
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && movedOn[0] == 2 && !clients[0].focusSilent,
          "... until it answers again: then its focus counts");
    sent(); front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
    world[0].cur = 222; world[1].cur = 322; front = vm; frontChanged(vm, NET_APP, 1, "Omarchy", 29, 0); sent();
    // Pressed again while the question is open: back in the VM, nothing moves.
    focusReply = NULL; clients[0].focusSilent = 0; focusWait = 0.3; spaceKeys = 0;
    CGEventRef fd1 = key(1, K, HID, 0), fu1 = key(0, K, HID, 0);
    tapCb(NULL, kCGEventKeyDown, fd1, NULL); tapCb(NULL, kCGEventKeyUp, fu1, NULL);
    CFRelease(fd1); CFRelease(fu1);
    for (int i = 0; i < 4; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
    fd1 = key(1, K, HID, 0); fu1 = key(0, K, HID, 0);
    tapCb(NULL, kCGEventKeyDown, fd1, NULL); tapCb(NULL, kCGEventKeyUp, fu1, NULL);
    CFRelease(fd1); CFRelease(fu1);
    settleSteps();
    check(capturing && !spaceKeys && world[0].cur == 222 && world[1].cur == 322, "pressed again while asking: back in the VM, nothing moves");
    focusWait = 0.05; clients[0].focusSilent = 0; sent();
    // "All monitors": no question, both move.
    all = 1; asks = 0; focusReply = "D 2560 0 1920 1200";
    check(press(K, HID, 0) == 1 && !asks && spaceKeys == 2 && world[0].cur == 221 && world[1].cur == 321,
          "all monitors: no question, both displays move");
    sent(); settle(vm, NET_APP); press(K, HID, 0); sent(); all = 0;
    // The VM on one display only: no question (the pointer says it).
    world[0].cur = 221; world[1].cur = 322; front = vm; pointer = CGPointMake(3000, 600);
    frontChanged(vm, NET_APP, 1, "Omarchy", 30, 0); sent(); asks = 0;
    check(press(K, HID, 0) == 1 && !asks && spaceKeys == 1 && world[1].cur == 321, "the VM on one display: no question");
    sent(); settle(vm, NET_APP); sent();
    focusReply = NULL;
  }

  // ---- "All monitors" with OmacVM.app's QEMU, which puts the cursor back
  // where the guest's pointer is once a display's Space changed: the other
  // display's move goes first, the pointer's display's last (the mini, two
  // virtual displays: the second display stayed on the VM, or out of it) ----
  {
    const uint64_t mbp[] = { 231, 232 }, ext[] = { 331, 332 };
    layout(2, mbp, 2, ext, 2);
    owner[231] = terminal; winOn[231] = 11; owner[232] = vm; winOn[232] = 31;
    owner[331] = safari; winOn[331] = 44; owner[332] = vm; winOn[332] = 32;
    world[0].cur = 231; world[1].cur = 331; front = terminal; pointer = guestPointer = CGPointMake(1000, 700);
    frontChanged(terminal, -1, 0, "", 11, 1); sent();
    world[0].cur = 232; world[1].cur = 332; front = vm;
    frontChanged(vm, NET_APP, 1, "Omarchy", 31, 0); sent();
    all = 1; qemuGivesBack = 1; giveBackDue = 0; swipeMoves = 0;
    check(press(K, HID, 0) == 1 && spaceKeys == 2 && movedOn[0] == 2 && movedOn[1] == 1,
          "all, QEMU's cursor give-back: the external's move first, then the pointer's display");
    check(world[0].cur == 231 && world[1].cur == 331 && !swipes, "... both out with macOS's shortcut, no swipe needed");
    sent(); front = safari; frontChanged(safari, -1, 0, "", 44, 1); sent(); giveBackDue = 0;
    check(press(K, HID, 0) == 1 && spaceKeys == 2 && world[0].cur == 232 && world[1].cur == 332 && front == vm,
          "... and both back into the VM");
    settle(vm, NET_APP); sent();
    all = 0; qemuGivesBack = 0; giveBackDue = 0;
  }

  // ---- Not the real keyboard, a held key, other combos: as before ----
  front = finder; world[0].cur = 401; world[1].cur = 401;
  frontChanged(finder, -1, 0, "", 0, 1); sent();
  check(press(K, POSTED, 0) == 0 && !went && !keys, "combo posted by an app in macOS: passes, nothing happens");
  check(press(K, HID, 1) == -1 && !went && !keys, "a held combo (autorepeat): its repeats eaten, nothing happens");
  check(press(O|M, HID, 0) == 0 && !went, "Option+Cmd+Esc (Force Quit) passes");
  check(press(C|M, HID, 0) == 0 && !went, "Ctrl+Cmd+Esc passes");

  // ---- The old combo (Ctrl+Option+Cmd+Esc, kept through 3.0.x) and exact modifiers ----
  check(escapeCombo(ESC_KEYCODE, C|O) == ESC_NEW && escapeCombo(ESC_KEYCODE, C|O|M) == ESC_OLD,
        "Ctrl+Option+Esc is the combo; Ctrl+Option+Cmd+Esc the old one");
  check(escapeCombo(ESC_KEYCODE, C|O|S) == ESC_NONE && escapeCombo(ESC_KEYCODE, C|O|M|S) == ESC_NONE,
        "... with Shift neither is (VoiceOver's VO+Shift+Esc stays VoiceOver's)");
  check(escapeCombo(ESC_KEYCODE, C) == ESC_NONE && escapeCombo(ESC_KEYCODE, O) == ESC_NONE &&
        escapeCombo(ESC_KEYCODE, O|M) == ESC_NONE && escapeCombo(ESC_KEYCODE, C|M) == ESC_NONE &&
        escapeCombo(ESC_KEYCODE, 0) == ESC_NONE && escapeCombo(48, C|O) == ESC_NONE,
        "... Ctrl+Esc, Option+Esc, Force Quit, Ctrl+Cmd+Esc, Esc, Ctrl+Option+Tab are not");
  check(escapeCombo(ESC_KEYCODE, C|O|kCGEventFlagMaskAlphaShift|kCGEventFlagMaskNonCoalesced) == ESC_NEW,
        "... Caps Lock on (and the event's own bits) do not matter");
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
  pointer = CGPointMake(1000, 700); front = terminal; world[0].cur = 101;
  frontChanged(terminal, -1, 0, "", 11, 1);
  inVM(vm, 102);
  check(press(C|O|M, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 101 && front == terminal && !hidden,
        "old combo in the VM: moves out the same way");
  check(!strcmp(sent(), "S esc ctrl-opt-cmd|") && !capturing, "... Omarchy is told it was the old one (it shows the new one once)");
  settle(vm, NET_APP);
  check(press(C|O|M, HID, 0) == 1 && world[0].cur == 102 && front == vm, "... in macOS it goes back in");
  settle(vm, NET_APP); sent();
  check(press(K, HID, 0) == 1 && !strcmp(sent(), "S esc ctrl-opt|") && world[0].cur == 101,
        "... the new one after it says ctrl-opt again");
  settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); sent();
  check(press(C|O|S, HID, 0) == 0 && capturing && world[0].cur == 102 && !strcmp(sent(), ""),
        "in the VM, Ctrl+Option+Shift+Esc: goes to the VM, nothing moves");
  press(C|O|M|S, HID, 0);
  check(capturing && world[0].cur == 102 && !spaceKeys && !strstr(sent(), "S esc"),
        "... Ctrl+Option+Cmd+Shift+Esc: the VM's too (as a Super chord), nothing moves");
  check(press(C|O|M, POSTED, 0) == 0 && capturing && world[0].cur == 102, "old combo posted by an app: passes");
  check(press(C|O|M, HID, 1) == -1 && capturing && world[0].cur == 102, "old combo held (autorepeat): its repeats eaten, nothing happens");
  sent();
  front = finder; world[0].cur = 401;
  frontChanged(finder, -1, 0, "", 0, 1); sent();

  // QEMU's tap ahead of ours took the combo's Esc up (Ctrl let go first): the
  // next plain Esc in macOS keeps its up.
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
  pointer = CGPointMake(1000, 700); front = terminal; world[0].cur = 101;
  frontChanged(terminal, -1, 0, "", 11, 1);
  inVM(vm, 102);
  {
    went = hidden = keys = spaceKeys = mcKeys = swipes = 0;
    CGEventRef d = key(1, K, HID, 0), rd = tapCb(NULL, kCGEventKeyDown, d, NULL);
    CFRelease(d); settleSteps();
    check(!rd && world[0].cur == 101 && !capturing, "combo down, its up taken by QEMU's tap: moved out");
  }
  settle(vm, NET_APP); sent();
  check(press(0, HID, 0) == 0, "... a plain Esc in macOS after it: down and up both pass");
  check(press(K, HID, 0) == 1 && world[0].cur == 102 && front == vm, "... the combo still takes it back in");
  settle(vm, NET_APP); sent();
  front = finder; world[0].cur = 401;
  frontChanged(finder, -1, 0, "", 0, 1); sent();

  // ---- Parallels: the same way out and back; no Mission Control either ----
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = parallels; winOn[102] = 55;
  pointer = CGPointMake(1000, 700); world[0].cur = 101; front = terminal;
  frontChanged(terminal, -1, 0, "", 11, 1);
  world[0].cur = 102; front = parallels;
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 101 && front == terminal, "Parallels VM: moved out");
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[0].cur == 102 && front == parallels, "... and into the Parallels VM again");
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();
  keysIgnored = 1;
  check(press(K, HID, 0) == 1 && !mcKeys && world[0].cur == 102 && !hidden,
        "Parallels, nothing moves: no Mission Control, nothing hidden");
  keysIgnored = 0;
  press(K, HID, 0); frontChanged(parallels, 0, 1, "Omarchy", 55, 0); sent();

  // The same VM app in front in a window (it left full screen): the combo is the VM's, as before.
  frontChanged(parallels, 0, 0, "", 55, 0);
  check(press(K, HID, 0) == 0 && !went && !keys, "the VM's app in front in a window: the combo passes to it");

  // Parallels outlives its VM: its window gone, the combo in macOS is macOS's again.
  front = terminal; world[0].cur = 101;
  frontChanged(parallels, 0, 1, "Omarchy", 55, 0); frontChanged(terminal, -1, 0, "", 11, 1); sent();
  vmAlive = 0;
  check(press(K, HID, 0) == 0 && !went && !keys, "the VM's window is gone (app still running): the combo passes");
  vmAlive = 1;

  // The VM has quit: the combo in macOS is macOS's again.
  end(parallels);
  check(press(K, HID, 0) == 0 && !went && !keys, "the last VM has quit: the combo passes in macOS");

  // Back in when the VM's Space is not right beside: its window to the front.
  const uint64_t far[] = { 101, 103, 102 };
  layout(1, far, 3, NULL, 0);
  owner[101] = terminal; owner[103] = safari; owner[102] = vm; winOn[102] = 22;
  front = terminal; world[0].cur = 101; settle(vm, NET_APP);
  inVM(vm, 102);
  frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; world[0].cur = 101; sent();
  check(press(K, HID, 0) == 1 && !keys && went >= 1 && wentTo == vm && world[0].cur == 102,
        "in macOS, the VM's Space two away: its window to the front (no shortcut)");
  settle(vm, NET_APP); sent();
  frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; world[0].cur = 101; escaped = 0;
  layout(1, mini, 2, NULL, 0);
  owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;

  // ---- An OmacVM VM in a window with the keyboard: the combo gives it to
  // the app from before; in macOS it brings that window back ----
  pid_t winvm = child();
  front = winvm;
  frontChanged(winvm, NET_APP, 0, "", 77, 0); sent();
  check(press(K, HID, 0) == 1 && went == 1 && wentTo == terminal && wentWin == 11 && front == terminal && !keys,
        "VM in a window: the combo gives the keyboard to the app from before (Terminal), no Space move");
  check(!capturing && !strcmp(sent(), ""), "... nothing sent to the guest");
  check(leftWinPid == winvm && leftWinWin == 77, "... and that window is remembered");
  frontChanged(terminal, -1, 0, "", 11, 1);
  check(press(K, HID, 0) == 1 && went == 1 && wentTo == winvm && wentWin == 77 && front == winvm,
        "in macOS: the combo brings the VM window back, with the keyboard");
  frontChanged(winvm, NET_APP, 0, "", 77, 0);
  check(!leftWinPid, "... in it again: forgotten");
  check(press(K, HID, 1) == -1 && !went && !leftWinPid && front == winvm, "VM in a window: a held combo (autorepeat): its repeats eaten, nothing happens");
  check(press(K, POSTED, 0) == 0 && !leftWinPid && front == winvm, "VM in a window: a posted combo passes, not remembered");
  // The switch refused: the VM's app is hidden, macOS has the keyboard (a window, not full screen).
  refuse = 1;
  check(press(K, HID, 0) == 1 && hidden == 1 && front != winvm, "VM in a window, the switch refused: hidden (never a trap)");
  refuse = 0;
  frontChanged(front, -1, 0, "", 0, 1);
  check(press(K, HID, 0) == 1 && wentTo == winvm && front == winvm, "... the combo brings it back");
  frontChanged(winvm, NET_APP, 0, "", 77, 0);
  // Left with a click (no combo): the combo in macOS is not the window's.
  front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
  wentTo = 0;
  check(press(K, HID, 0) >= 0 && wentTo != winvm && !leftWinPid, "a VM window left with a click: the combo does not take it back");
  sent(); front = terminal; world[0].cur = 101; frontChanged(terminal, -1, 0, "", 11, 1);
  // The window left by the combo, then a full-screen VM entered: that one is the newer.
  front = winvm; frontChanged(winvm, NET_APP, 0, "", 77, 0);
  press(K, HID, 0);
  check(leftWinPid == winvm, "window left by the combo");
  front = vm; world[0].cur = 102; frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
  check(!leftWinPid, "... then a full-screen VM in front: the window is no longer the way back");
  frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; world[0].cur = 101; sent(); escaped = 0;
  // The launcher (OmacVM.app's start window) has the VMs' name, but is no VM.
  launcher = child(); front = launcher;
  frontChanged(launcher, NET_APP, 0, "", 88, 0);
  check(!winVMPid, "OmacVM.app's launcher in front: no VM window");
  front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
  // The window gone (VM quit): the combo in macOS is not the window's.
  front = winvm; frontChanged(winvm, NET_APP, 0, "", 77, 0); press(K, HID, 0);
  front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
  end(winvm);
  check(press(K, HID, 0) == 0 || wentTo != winvm, "the VM window's VM has quit: the combo does not go there");
  end(launcher); launcher = 0;

  // ---- A MacBook display on a desktop Space (Terminal), the VM's own Space
  // on the external: the Space move, never hidden (no notch cover any more) ----
  {
    const uint64_t mbp[] = { 451, 452 }, ext[] = { 461, 462 };
    layout(2, mbp, 2, ext, 2);
    owner[451] = terminal; winOn[451] = 11; owner[452] = safari; winOn[452] = 33;
    owner[461] = terminal; winOn[461] = 11; owner[462] = vm; winOn[462] = 23;
    world[0].cur = 451; world[1].cur = 461; front = terminal; pointer = CGPointMake(3000, 600);
    frontChanged(terminal, -1, 0, "", 11, 1);
    world[1].cur = 462; front = vm;
    frontChanged(vm, NET_APP, 1, "Omarchy", 23, 0); sent();
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[1].cur == 461 && !hidden && !mcKeys,
          "native full screen next to a desktop Space: the Space move, not hidden");
    sent(); frontChanged(terminal, -1, 0, "", 11, 1);
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && world[1].cur == 462 && front == vm && !hidden, "... and back in by a Space move");
    frontChanged(vm, NET_APP, 1, "Omarchy", 23, 0); sent();
    // A window of the VM's app that covers a whole display on a desktop Space
    // (the old notch cover): the same Space move, no hide.
    owner[451] = vm; winOn[451] = 24; world[0].cur = 451; pointer = CGPointMake(1000, 700);
    frontChanged(vm, NET_APP, 1, "Omarchy", 24, 0); sent();
    check(press(K, HID, 0) == 1 && !hidden && !mcKeys && spaceKeys == 1, "a VM window over a desktop Space: never hidden");
    sent(); frontChanged(terminal, -1, 0, "", 11, 1); front = terminal; escaped = 0;
  }

  // ---- The user's 10:13 case: three desktops and the VM's Space between
  // them; macOS's Space slide lands after the first look. One key, one Space:
  // the neighbour the user came from, never the first desktop ----
  {
    const uint64_t desks[] = { 501, 502, 503, 504 };   // Desktop 1, Desktop 2, the VM, Desktop 3
    layout(1, desks, 4, NULL, 0);
    owner[501] = terminal; winOn[501] = 11; owner[502] = safari; winOn[502] = 33;
    owner[503] = vm; winOn[503] = 25; owner[504] = finder;
    pointer = CGPointMake(1000, 700);
    front = safari; world[0].cur = 502; settle(vm, NET_APP);   // came from Desktop 2
    inVM(vm, 503);
    lateKeys = 1.5;
    int r2 = press(K, HID, 0); const char *got2 = sent();
    check(r2 == 1 && spaceKeys == 1 && keys == 1 && !swipes && world[0].cur == 502,
          "Space change lands late: one shortcut, no swipe after it, on the neighbour (Desktop 2), not Desktop 1");
    check(!strstr(got2, "space-unchanged") && !mcKeys && !hidden, "... no 'did not change' notice, no Mission Control, not hidden");
    settle(vm, NET_APP); sent();
    r2 = press(K, HID, 0); sent();
    check(r2 == 1 && spaceKeys == 1 && world[0].cur == 503 && front == vm, "... the combo again: one Space back, into the VM");
    settle(vm, NET_APP); sent();
    // Came from Desktop 3 on the right: one step right, late as well.
    front = finder; world[0].cur = 504; settle(vm, NET_APP);
    inVM(vm, 503);
    r2 = press(K, HID, 0); sent();
    check(r2 == 1 && spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 504, "came from the right: one step right");
    settle(vm, NET_APP); sent();
    r2 = press(K, HID, 0); sent();
    check(r2 == 1 && spaceKeys == 1 && world[0].cur == 503, "... and back in");
    // Too late (never lands within the looks): no notice, still one key.
    // The slide lands only after the press is done (a fixed delay failed on a
    // slow CI runner: its timers stretched the looks past it).
    settle(vm, NET_APP); sent();
    front = safari; world[0].cur = 502; settle(vm, NET_APP); inVM(vm, 503);
    lateKeys = -1; int sm = swipeMoves; swipeMoves = 0;
    r2 = press(K, HID, 0); got2 = sent();
    check(r2 == 1 && spaceKeys == 1 && !strstr(got2, "N "), "lands only after every look (the swipe does nothing): no notice, one key");
    swipeMoves = sm;
    if (heldMove) { heldMove = 0; moveSpace(heldWorld, heldDir); }
    settleSteps();
    check(world[0].cur == 502, "... (and macOS's own slide still ends one Space over)");
    lateKeys = 0;
    sent(); frontChanged(safari, -1, 0, "", 33, 1); front = safari; escaped = 0;
  }

  // ---- Pressed twice within doublePress: Mission Control; once: never ----
  {
    const uint64_t desks[] = { 471, 472, 473 };   // Desktop 1, Desktop 2, the VM
    layout(1, desks, 3, NULL, 0);
    owner[471] = terminal; winOn[471] = 11; owner[472] = safari; winOn[472] = 33; owner[473] = vm; winOn[473] = 26;
    pointer = CGPointMake(1000, 700);
    front = safari; world[0].cur = 472; settle(vm, NET_APP); inVM(vm, 473);
    doublePress = 0.4; mcApps = 0; lastComboAt = -1;
    // Ctrl+Option held, Esc tapped twice: the first press's move waits for
    // the keys to come up, the second one drops it.
    heldPolls = 5;
    went = hidden = keys = spaceKeys = mcKeys = swipes = 0;
    for (int t = 0; t < 2; t++) {
      CGEventRef d = key(1, K, HID, 0), u = key(0, K, HID, 0);
      CGEventRef rd = tapCb(NULL, kCGEventKeyDown, d, NULL), ru = tapCb(NULL, kCGEventKeyUp, u, NULL);
      check(!rd && !ru, t ? "double press: the second Esc is eaten too" : "double press: the first Esc is eaten");
      CFRelease(d); CFRelease(u);
    }
    settleSteps();
    check(mcKeys == 1 && spaceKeys == 0 && !swipes && world[0].cur == 473,
          "double press (keys still down): Mission Control (macOS's Ctrl+Up), no Space move from the first press");
    check(!capturing && escaped, "... capture off (Mission Control is macOS's)");
    check(!mcWhileHeld && !heldPolls, "... Mission Control's key only once Ctrl and Option are up");
    sent();
    // Released between the presses: the first press has moved one Space; the
    // second opens Mission Control and moves nothing more.
    escaped = 0; front = vm; world[0].cur = 473; frontChanged(vm, NET_APP, 1, "Omarchy", 26, 0); sent();
    heldPolls = 0; lastComboAt = -1;
    int r3 = press(K, HID, 0);
    check(r3 == 1 && spaceKeys == 1 && world[0].cur == 472 && !mcKeys, "first press: one Space (Desktop 2), no Mission Control");
    r3 = press(K, HID, 0);
    check(r3 == 1 && mcKeys == 1 && spaceKeys == 0 && world[0].cur == 472, "... a second press right after: Mission Control, no other move");
    // Mission Control's shortcut off: the Mission Control app.
    setKey(HOTKEY_MISSION_CONTROL, kCFBooleanFalse, 126, 8650752);
    escaped = 0; front = vm; world[0].cur = 473; frontChanged(vm, NET_APP, 1, "Omarchy", 26, 0); sent(); lastComboAt = -1;
    press(K, HID, 0); r3 = press(K, HID, 0);
    check(r3 == 1 && mcApps == 1 && !mcKeys, "Mission Control's shortcut off: the app opens it");
    unsetKeys();
    // Apart (more than doublePress): two single presses, out and back in.
    escaped = 0; front = vm; world[0].cur = 473; frontChanged(vm, NET_APP, 1, "Omarchy", 26, 0); sent(); lastComboAt = -1;
    press(K, HID, 0); usleep(450000); settle(vm, NET_APP); sent();
    r3 = press(K, HID, 0);
    check(r3 == 1 && !mcKeys && world[0].cur == 473, "two presses 0.45 s apart: out, then back in, no Mission Control");
    doublePress = 0; sent(); settle(vm, NET_APP); sent();
    // Ctrl+Option still held, Esc pressed again after doublePress but before
    // the first press's move went out (it waits for the keys to come up):
    // back to the VM (capture on), and that move is dropped. Before: capture
    // on, then the move out ran anyway (the user's log, 2026-10-22 16:05).
    escaped = 0; front = vm; world[0].cur = 473; frontChanged(vm, NET_APP, 1, "Omarchy", 26, 0); sent(); lastComboAt = -1;
    heldPolls = 30; keys = spaceKeys = mcKeys = swipes = 0;
    CGEventRef d1 = key(1, K, HID, 0), u1 = key(0, K, HID, 0);
    tapCb(NULL, kCGEventKeyDown, d1, NULL); tapCb(NULL, kCGEventKeyUp, u1, NULL);
    CFRelease(d1); CFRelease(u1);
    for (int i = 0; i < 5; i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);   // the move waits for the keys
    check(!capturing && escaped && !spaceKeys && heldPolls > 0, "pressed again, keys held: the first press's move still waits");
    d1 = key(1, K, HID, 0); u1 = key(0, K, HID, 0);
    tapCb(NULL, kCGEventKeyDown, d1, NULL); tapCb(NULL, kCGEventKeyUp, u1, NULL);
    CFRelease(d1); CFRelease(u1);
    heldPolls = 0; settleSteps();
    check(capturing && !escaped && !spaceKeys && !swipes && !mcKeys && world[0].cur == 473,
          "... the second press: back in the VM (capture on), the first press's move dropped");
    check(!strcmp(sent(), "S esc ctrl-opt|S on|"), "... the guest lets go, then takes the keys again");
    // The next press works as before.
    r3 = press(K, HID, 0);
    check(r3 == 1 && spaceKeys == 1 && world[0].cur == 472, "... and the next press moves out as before");
    sent(); settle(vm, NET_APP); sent();
  }

  // ---- After Mission Control + Esc on Desktop 1, the VM's app still in
  // front (it shows no window there): one press back into the VM, not "out
  // of a window" to Finder (air-matrix O4: it took three presses) ----
  {
    layout(1, mini, 2, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
    pointer = CGPointMake(1000, 700);
    front = terminal; world[0].cur = 101; settle(vm, NET_APP); inVM(vm, 102);
    doublePress = 0.4; lastComboAt = -1; heldPolls = 5;
    for (int t = 0; t < 2; t++) {
      CGEventRef d = key(1, K, HID, 0), u = key(0, K, HID, 0);
      tapCb(NULL, kCGEventKeyDown, d, NULL); tapCb(NULL, kCGEventKeyUp, u, NULL);
      CFRelease(d); CFRelease(u);
    }
    settleSteps();
    check(mcKeys == 1 && !capturing && escaped, "O4: double press in the VM: Mission Control, capture off");
    sent(); doublePress = 0; heldPolls = 0;
    // Esc in Mission Control: Desktop 1 shows, macOS keeps the VM's app in front.
    world[0].cur = 101; front = vm;
    frontChanged(vm, NET_APP, 0, "", 0, 0);
    check(!winVMPid && vmOffSpace && !capturing && !escaped, "O4: the VM's app in front, no window on Desktop 1: no VM in a window");
    wentTo = 0;
    check(press(K, HID, 0) == 1 && spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 102 && front == vm,
          "O4: one press: back into the VM's Space (Move right a space)");
    check(wentTo != finder && wentTo != terminal && !leftWinPid, "O4: ... the keyboard not given to Finder or Terminal");
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);
    check(capturing && !vmOffSpace && !strcmp(sent(), "S on|"), "O4: ... captured again");
    // The same, the Space not beside it: its window to the front.
    const uint64_t far2[] = { 101, 103, 102 };
    layout(1, far2, 3, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[103] = safari; winOn[103] = 33; owner[102] = vm; winOn[102] = 22;
    world[0].cur = 101; front = vm; frontChanged(vm, NET_APP, 0, "", 0, 0); sent();
    check(press(K, HID, 0) == 1 && !keys && wentTo == vm && world[0].cur == 102, "O4: the VM's Space two away: its window to the front");
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    // A real window of the VM's app on this Space (it left full screen): still a VM in a window.
    world[0].cur = 101; front = vm; frontChanged(vm, NET_APP, 0, "", 22, 0); sent();
    check(winVMPid == vm && !vmOffSpace, "O4: the VM's app with a window on this Space: a VM in a window, as before");
    wentTo = 0;
    check(press(K, HID, 0) == 1 && wentTo == terminal && !keys, "O4: ... the combo gives the keyboard to the app from before");
    sent(); leftWinPid = 0; front = terminal; world[0].cur = 101; frontChanged(terminal, -1, 0, "", 11, 1); sent(); escaped = 0;
    layout(1, mini, 2, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
  }

  // ---- The combo once more while Mission Control (from the double press) is
  // still open: Mission Control closes, back in the VM (Mission Control
  // ignores the Space shortcut and app switches) ----
  {
    layout(1, mini, 2, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
    pointer = CGPointMake(1000, 700);
    front = terminal; world[0].cur = 101; settle(vm, NET_APP); inVM(vm, 102);
    mcSim = 1; mcShown = 0; doublePress = 0.4; lastComboAt = -1; heldPolls = 5;
    for (int t = 0; t < 2; t++) {
      CGEventRef d = key(1, K, HID, 0), u = key(0, K, HID, 0);
      tapCb(NULL, kCGEventKeyDown, d, NULL); tapCb(NULL, kCGEventKeyUp, u, NULL);
      CFRelease(d); CFRelease(u);
    }
    settleSteps();
    check(mcShown && world[0].cur == 101 && front == vm, "MC open: Desktop 1 listed as shown, the VM's app still in front");
    sent(); doublePress = 0; heldPolls = 0;
    frontChanged(vm, NET_APP, 0, "", 0, 0);
    wentTo = 0;
    check(press(K, HID, 0) == 1 && mcKeys == 1 && !mcShown && !spaceKeys && world[0].cur == 102 && front == vm,
          "MC open, the combo: Mission Control closed with its shortcut, back on the VM's Space (no Space key)");
    check(wentTo != finder && wentTo != terminal && !leftWinPid, "... the keyboard not given to Finder or Terminal");
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0);
    check(capturing && !strcmp(sent(), "S on|"), "... captured again");
    // MC open, macOS says the VM's window shows there (a thumbnail): not "a VM in a window".
    mcShown = 1; mcFrom = 102; world[0].cur = 101; escaped = 0; capturing = 0;
    frontChanged(vm, NET_APP, 0, "", 22, 0); sent();
    check(winVMPid == vm, "MC open, the VM's window listed on screen: taken for a VM in a window (as macOS says)");
    wentTo = 0;
    check(press(K, HID, 0) == 1 && mcKeys == 1 && !mcShown && world[0].cur == 102 && wentTo != terminal && !leftWinPid,
          "... the combo still closes Mission Control, back in the VM (not out of a window)");
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    // Mission Control opened from Desktop 1 (Terminal in front): closed, then the Space move in.
    mcShown = 1; mcFrom = 101; world[0].cur = 101; front = terminal; escaped = 0;
    frontChanged(terminal, -1, 0, "", 11, 1); sent();
    check(press(K, HID, 0) == 1 && mcKeys == 1 && !mcShown && spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 102,
          "MC opened from Desktop 1: closed, then Move right a space into the VM");
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    // Closing lands late (1.6 verify periods): waited for, no Space move after it.
    const uint64_t mid[] = { 101, 102, 103 };   // Desktop 1, the VM, Desktop 2
    layout(1, mid, 3, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22; owner[103] = safari; winOn[103] = 33;
    mcShown = 1; mcFrom = 102; mcLate = 1.6; world[0].cur = 101; front = vm; escaped = 0;
    frontChanged(vm, NET_APP, 0, "", 0, 0); sent();
    check(press(K, HID, 0) == 1 && mcKeys == 1 && !spaceKeys && world[0].cur == 102,
          "MC closing lands late: waited for, no Space move after it (not one Space too far)");
    mcLate = 0;
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    layout(1, mini, 2, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22;
    // Mission Control's shortcut off: the app closes it.
    setKey(HOTKEY_MISSION_CONTROL, kCFBooleanFalse, 126, 8650752);
    mcShown = 1; mcFrom = 102; world[0].cur = 101; front = vm; escaped = 0; mcApps = 0;
    frontChanged(vm, NET_APP, 0, "", 0, 0); sent();
    check(press(K, HID, 0) == 1 && mcApps == 1 && !mcKeys && !mcShown && world[0].cur == 102, "MC open, its shortcut off: the app closes it");
    unsetKeys();
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    // A plain Esc in Mission Control with the VM's app (QEMU) in front: QEMU
    // would take it for the VM; Mission Control's shortcut closes it instead.
    mcShown = 1; mcFrom = 102; world[0].cur = 101; front = vm; escaped = 0;
    frontChanged(vm, NET_APP, 0, "", 0, 0); sent();
    check(press(0, HID, 0) == 1 && mcKeys == 1 && !mcShown && world[0].cur == 102 && !spaceKeys && !strcmp(sent(), ""),
          "MC open, VM's app in front, Esc: eaten (down and up), Mission Control closed, back on the VM's Space");
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    // Esc held in Mission Control: its repeats and its up are eaten too (none reach the VM).
    mcShown = 1; mcFrom = 102; world[0].cur = 101; front = vm; escaped = 0; mcClosedAt = -1;
    frontChanged(vm, NET_APP, 0, "", 0, 0); sent();
    {
      CGEventRef d = key(1, 0, HID, 0), r1 = key(1, 0, HID, 1), r2 = key(1, 0, HID, 1), u = key(0, 0, HID, 0);
      CGEventRef a1 = tapCb(NULL, kCGEventKeyDown, d, NULL), a2 = tapCb(NULL, kCGEventKeyDown, r1, NULL);
      CGEventRef a3 = tapCb(NULL, kCGEventKeyDown, r2, NULL), a4 = tapCb(NULL, kCGEventKeyUp, u, NULL);
      CFRelease(d); CFRelease(r1); CFRelease(r2); CFRelease(u);
      mcKeys = 0; settleSteps();
      check(!a1 && !a2 && !a3 && !a4 && mcKeys == 1 && !mcShown, "MC open, Esc held: down, repeats and up all eaten, closed once");
      check(press(0, HID, 0) == 0, "... the next Esc is the VM's again");
    }
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    // Closed by us and still listed while it closes: no second close (that would open it again).
    mcShown = 1; mcFrom = 102; world[0].cur = 101; front = vm; escaped = 0; mcClosedAt = -1; mcLate = 3;
    frontChanged(vm, NET_APP, 0, "", 0, 0); sent();
    mcClosing = 5;
    press(0, HID, 0);   // Esc: closes it; macOS still lists it for a while
    mcShown = 1;        // ... as the Dock's window is still there
    int k1 = mcKeys;
    press(K, HID, 0);
    check(k1 == 1 && mcKeys == 0, "MC closing (still listed), the combo right after: no second Mission Control key");
    mcShown = 0; mcLate = 0; mcClosing = 0; settleSteps();
    frontChanged(vm, NET_APP, 1, "Omarchy", 22, 0); sent();
    // ... with another app in front, Mission Control gets the Esc itself.
    mcShown = 1; mcFrom = 102; world[0].cur = 101; front = terminal; escaped = 0;
    frontChanged(terminal, -1, 0, "", 11, 1); sent();
    check(press(0, HID, 0) == 0 && !mcKeys && mcShown, "MC open, Terminal in front, Esc: passes (macOS's)");
    mcShown = 0;
    // No Mission Control: an Esc in the VM's window, or with the VM's app in front, is the VM's.
    world[0].cur = 101; front = vm; frontChanged(vm, NET_APP, 0, "", 0, 0); sent();
    check(press(0, HID, 0) == 0 && !mcKeys, "no MC, the VM's app in front, Esc: passes (the VM's)");
    check(press(S, HID, 0) == 0 && !mcKeys, "... Shift+Esc too");
    mcShown = 1;
    check(press(S, HID, 0) == 0 && !mcKeys && mcShown, "MC open, Shift+Esc: passes, Mission Control stays");
    check(press(0, POSTED, 0) == 0 && !mcKeys && mcShown, "MC open, a posted Esc: passes");
    mcShown = 0;
    // A posted combo in Mission Control: passes, nothing closed.
    mcShown = 1; mcFrom = 102; world[0].cur = 101; front = terminal; escaped = 0;
    frontChanged(terminal, -1, 0, "", 11, 1); sent();
    check(press(K, POSTED, 0) == 0 && !mcKeys && mcShown, "MC open, a posted combo: passes, Mission Control stays");
    // No VM to go back to (its window gone): the combo in Mission Control is macOS's.
    vmAlive = 0;
    check(press(K, HID, 0) == 0 && !mcKeys && mcShown, "MC open, no VM to go back to: the combo passes");
    vmAlive = 1; mcShown = 0; mcSim = 0;
    world[0].cur = 101; front = terminal; frontChanged(terminal, -1, 0, "", 11, 1); sent(); escaped = 0;
  }

  // ---- Swipe out to macOS (#342): "X left|right" from the guest in front ----
  {
    const uint64_t three3[] = { 101, 102, 103 };
    layout(1, three3, 3, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22; owner[103] = safari; winOn[103] = 33;
    pointer = CGPointMake(1000, 700); front = terminal; world[0].cur = 101;
    frontChanged(terminal, -1, 0, "", 11, 1); sent();
    inVM(vm, 102);
    unsigned g0 = clients[0].gen;
    soOn = 0; swipeOutLook();
    check(!strcmp(sent(), "X off|") && swipeOut == 0, "swipe out: the setting read (off): every guest is told X off");
    swipeOutLook();
    check(!strcmp(sent(), ""), "swipe out: ... no change, nothing sent");
    guestLine(clients[0].fd, g0, "X left"); keys = spaceKeys = 0; settleSteps();
    check(!keys && world[0].cur == 102 && capturing && !strcmp(sent(), ""), "swipe out: setting off: X left ignored, nothing moves");
    soOn = 1; swipeOutLook();
    check(!strcmp(sent(), "X on 2|") && swipeOut == 1, "swipe out: turned on: X on 2 to every guest (this helper follows the fingers)");
    keys = spaceKeys = went = hidden = mcKeys = 0;
    guestLine(clients[0].fd, g0, "X left"); settleSteps();
    check(spaceKeys == 1 && lastKey.keycode == 123 && world[0].cur == 101 && front == terminal,
          "swipe out: X left: macOS's Move left a space, out to the Space on the left");
    check(!strcmp(sent(), "S esc ctrl-opt|") && !capturing && escaped && !mcKeys && !hidden,
          "swipe out: ... the guest lets go (S esc), capture off, no notice, no Mission Control, not hidden");
    settle(vm, NET_APP); sent();
    check(press(K, HID, 0) == 1 && world[0].cur == 102 && front == vm, "swipe out: ... the combo in macOS goes back into the VM");
    settle(vm, NET_APP); sent();
    keys = spaceKeys = 0;
    guestLine(clients[0].fd, g0, "X right"); settleSteps();
    check(spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 103 && front == safari,
          "swipe out: X right: Move right a space, out to the Space on the right");
    sent(); settle(vm, NET_APP); sent();
    check(press(K, HID, 0) == 1 && world[0].cur == 102 && front == vm, "swipe out: ... and back in with the combo");
    settle(vm, NET_APP); sent();
    // No Space on that side: nothing at all (not even a notice); capture stays.
    const uint64_t last[] = { 101, 102 };
    layout(1, last, 2, NULL, 0); world[0].cur = 102; settle(vm, NET_APP); sent();
    keys = swipes = 0;
    guestLine(clients[0].fd, g0, "X right"); settleSteps();
    check(!keys && !swipes && world[0].cur == 102 && capturing && !strcmp(sent(), ""),
          "swipe out: no Space on the right: nothing (no key, no swipe, no notice), still captured");
    const uint64_t first[] = { 102, 101 };
    layout(1, first, 2, NULL, 0); world[0].cur = 102; settle(vm, NET_APP); sent();
    guestLine(clients[0].fd, g0, "X left"); settleSteps();
    check(!keys && !swipes && world[0].cur == 102 && capturing && !strcmp(sent(), ""),
          "swipe out: no Space on the left: nothing");
    layout(1, three3, 3, NULL, 0); world[0].cur = 102; settle(vm, NET_APP); sent();
    // Only the VM in front, captured; a gone or an older connection: nothing.
    pthread_mutex_lock(&sendLock); clients[0].target = 0; pthread_mutex_unlock(&sendLock);
    guestLine(clients[0].fd, g0, "X left"); settleSteps();
    check(!keys && world[0].cur == 102, "swipe out: from a VM that is not the one in front: ignored");
    pthread_mutex_lock(&sendLock); clients[0].target = 1; pthread_mutex_unlock(&sendLock);
    guestLine(clients[0].fd, g0 + 1, "X left"); settleSteps();
    check(!keys && world[0].cur == 102, "swipe out: from an older connection of that fd: ignored");
    capturing = 0;
    guestLine(clients[0].fd, g0, "X left"); settleSteps();
    check(!keys && world[0].cur == 102, "swipe out: not captured: ignored");
    capturing = 1;
    const char *junk[] = { "X up", "X", "X left now", "Y left", "x left", "" };
    for (int i = 0; i < 6; i++) guestLine(clients[0].fd, g0, junk[i]);
    settleSteps();
    check(!keys && world[0].cur == 102 && capturing, "swipe out: other lines (X up, X, X left now, Y left, ...): nothing");
    // At most one a second.
    swipeOutGap = 10; swipeOutAt = -1;
    guestLine(clients[0].fd, g0, "X left"); settleSteps(); sent(); settle(vm, NET_APP); sent();
    press(K, HID, 0); settle(vm, NET_APP); sent();
    keys = 0;
    guestLine(clients[0].fd, g0, "X right"); settleSteps();
    check(world[0].cur == 102 && !keys, "swipe out: a second one within the gap: ignored");
    swipeOutGap = 0;
    // Two displays, the VM on both: the pointer's display, or both with "all".
    const uint64_t in2[] = { 201, 202 }, out2[] = { 301, 302 };
    layout(2, in2, 2, out2, 2);
    owner[201] = terminal; winOn[201] = 11; owner[202] = vm; winOn[202] = 22;
    owner[301] = safari; winOn[301] = 44; owner[302] = vm; winOn[302] = 23;
    world[0].cur = 202; world[1].cur = 302; front = vm; pointer = CGPointMake(3000, 600);
    settle(vm, NET_APP); sent();
    keys = spaceKeys = 0;
    guestLine(clients[0].fd, g0, "X left"); settleSteps();
    check(spaceKeys == 1 && movedOn[0] == 2 && world[1].cur == 301 && world[0].cur == 202,
          "swipe out, two displays: only the pointer's display moves (EscapeSwipe default)");
    sent(); settle(vm, NET_APP); press(K, HID, 0); sent(); settle(vm, NET_APP); sent();
    all = 1; keys = spaceKeys = 0;
    guestLine(clients[0].fd, g0, "X left"); settleSteps();
    check(spaceKeys == 2 && world[0].cur == 201 && world[1].cur == 301, "swipe out, EscapeSwipe all: both displays move");
    sent(); settle(vm, NET_APP); press(K, HID, 0); sent(); settle(vm, NET_APP); sent();
    all = 0;
    // The guest's own reader: lines in pieces, a too long one skipped, then
    // closing the client here ends the reader.
    layout(1, three3, 3, NULL, 0); world[0].cur = 102; front = vm; pointer = CGPointMake(1000, 700);
    settle(vm, NET_APP); sent();
    int rp[2]; socketpair(AF_UNIX, SOCK_STREAM, 0, rp);
    int save0 = clients[0].fd; clients[0].fd = rp[0];
    ReaderArg ra = { dup(rp[0]), rp[0], g0, 0 };
    pthread_t th; pthread_create(&th, NULL, readerThread, &ra);
    char longLine[600]; memset(longLine, 'X', sizeof longLine); longLine[sizeof longLine - 1] = '\n';
    write(rp[1], longLine, sizeof longLine);
    write(rp[1], "X le", 4); usleep(30000); write(rp[1], "ft\n", 3);
    keys = spaceKeys = 0;
    for (int i = 0; i < 50 && world[0].cur == 102; i++) settleSteps();
    check(spaceKeys == 1 && world[0].cur == 101, "swipe out: a real connection: \"X left\" in two pieces after a too long line: out");
    closeClient(rp[0]); clients[0].fd = save0;
    for (int i = 0; i < 100 && !ra.done; i++) usleep(20000);
    check(ra.done, "swipe out: closing the client ends its reader");
    pthread_join(th, NULL); close(rp[1]);
    settle(vm, NET_APP); sent(); press(K, HID, 0); settle(vm, NET_APP); sent();
    soOn = 0; swipeOutLook(); sent();
  }

  // ---- Swipe out that follows the fingers ("X on 2", "E"): made-up trackpad frames, a made-up Dock ----
  {
    int big = 1 << 18;
    setsockopt(clients[0].fd, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
    setsockopt(peer, SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
    dockPostFn = fakeDockPost; takeClockFn = fakeClock; hidSwipeFn = fakeHidOff;
    pthread_mutex_lock(&padLock);
    pads[0].dev = (MTDeviceRef)&fakePadDev; pads[0].id = 77; pads[0].w = 15600; pads[0].h = 9600; pads[0].fingers = 0;
    nPads = 1; activePad = 0; tpW = 15600; tpH = 9600;
    pthread_mutex_unlock(&padLock);
    const uint64_t three3[] = { 101, 102, 103 };
    layout(1, three3, 3, NULL, 0);
    owner[101] = terminal; winOn[101] = 11; owner[102] = vm; winOn[102] = 22; owner[103] = safari; winOn[103] = 33;
    pointer = CGPointMake(1000, 700); front = terminal; world[0].cur = 101;
    frontChanged(terminal, -1, 0, "", 11, 1); sent();
    inVM(vm, 102); guestGot();
    unsigned g0 = clients[0].gen;
    soOn = 1; swipeOutLook(); guestGot();
    check(!strcmp(gotOther, "X on 2|"), "follow: X on 2 to the guest");
    guestLine(clients[0].fd, g0, "E right left");
    check(clients[0].edgeKnown && clients[0].edge[0] == 1 && clients[0].edge[1] == -1, "follow: E right left kept (fingers left: the Space on the right)");
    takeLook();
    check(takeDisp.ok && takeDisp.left && takeDisp.right && takeDisp.n == 3 && takeDisp.vmSpace == 102,
          "follow: the capture check knows the pointer's display: the VM's Space 102 of 3, one on each side");

    // Out to the right with the fingers: held back, then macOS's own swipe.
    nDockEv = 0; keys = spaceKeys = 0;
    padSwipe(3, 0.6, 0.3, 30);
    int mono = 1;
    for (int i = 2; i < nDockEv; i++) if (dockEv[i].phase == kSwipeChanged && dockEv[i].p > dockEv[i - 1].p + 1e-9) mono = 0;
    check(nDockEv > 20 && dockEv[0].phase == kSwipeBegan && dockEv[1].phase == kSwipeChanged && mono && fabs(dockEv[nDockEv - 1].p + 0.9) < 0.01,
          "follow: fingers left at the edge: macOS's swipe begins and follows them toward the right (0.3 of the width = 0.6 of a Space, 0.9 in the Dock's units at 3 Spaces)");
    guestGot();
    check(gotFrames == 0 && gotLifts == 0 && capturing, "follow: ... the guest gets none of it; still captured while the fingers are down");
    padLift();
    guestGot();
    check(dockLast() == kSwipeEnded && world[0].cur == 103 && front == safari && !keys,
          "follow: the lift: finished (Ended), out to the Space on the right, no shortcut key");
    check(!capturing && !strcmp(gotOther, "S esc ctrl-opt|") && gotFrames == 0, "follow: ... capture off, the guest lets go (S esc), no frames");
    settle(vm, NET_APP); guestGot();
    check(press(K, HID, 0) == 1 && world[0].cur == 102 && front == vm, "follow: ... the combo in macOS goes back into the VM");
    settle(vm, NET_APP); guestGot(); takeLook();

    // Pulled back halfway: back into the VM.
    nDockEv = 0;
    padSwipe(3, 0.6, 0.4, 20); padSwipe(3, 0.4, 0.55, 10); padLift(); guestGot();
    check(dockLast() == kSwipeCancelled && !dockCount(kSwipeEnded) && world[0].cur == 102 && capturing && gotFrames == 0 && !gotOther[0],
          "follow: pulled back halfway: Cancelled, still in the VM and captured, the guest got nothing");
    int held = takeOn(); clk += 0.7;
    check(held && !takeOn(), "follow: ... the capture check waits while macOS slides the VM's Space back (0.6 s)");
    // Slow and short, then still: back.
    nDockEv = 0;
    padSwipe(3, 0.6, 0.5, 40); for (int i = 0; i < 10; i++) pad(3, 0.5, 0.5);
    padLift(); guestGot();
    check(dockLast() == kSwipeCancelled && world[0].cur == 102 && capturing, "follow: slow and under half a Space, then still: back");
    // Slow past half a Space: finished.
    nDockEv = 0;
    padSwipe(3, 0.7, 0.4, 60); for (int i = 0; i < 10; i++) pad(3, 0.4, 0.5);
    padLift(); guestGot();
    check(dockLast() == kSwipeEnded && world[0].cur == 103, "follow: slow past half a Space, then still: finished");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    // A flick: short and fast.
    nDockEv = 0;
    padSwipe(3, 0.6, 0.55, 4); padLift(); guestGot();
    check(dockLast() == kSwipeEnded && world[0].cur == 103, "follow: a flick (5 % of the width in 32 ms): finished");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    // The other edge: fingers right = the Space on the left.
    nDockEv = 0;
    padSwipe(4, 0.3, 0.6, 30); padLift(); guestGot();
    check(dockEv[nDockEv - 1].p > 0.85 && dockLast() == kSwipeEnded && world[0].cur == 101 && front == terminal && gotFrames == 0,
          "follow: four fingers right: out to the Space on the left with the fingers");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();

    // Hyprland's: the other way, up and down, a tap.
    guestLine(clients[0].fd, g0, "E right -");
    nDockEv = 0;
    padSwipe(3, 0.3, 0.6, 30); padLift(); guestGot();
    check(!nDockEv && gotFrames == 31 && gotLifts == 1 && world[0].cur == 102,
          "follow: E right -, fingers right (a workspace swipe here): every frame to the guest (the held ones too), no Dock swipe");
    guestLine(clients[0].fd, g0, "E right left");
    padMove(3, 0.5, 0.5, 0.3, 0.7, 20); padLift(); guestGot();
    check(!nDockEv && gotFrames == 21 && gotLifts == 1, "follow: up and down: all of it to the guest");
    pad(3, 0.5, 0.5); pad(3, 0.5, 0.5); pad(3, 0.5, 0.5); padLift(); guestGot();
    check(!nDockEv && gotFrames == 3 && gotLifts == 1, "follow: a three-finger tap: to the guest (held, then all at once)");
    // Spread apart (a pinch): the guest's.
    for (int s = 0; s <= 10; s++) {
      MTTouch t[3]; memset(t, 0, sizeof t);
      for (int i = 0; i < 3; i++) {
        t[i].pathIndex = 3 + i; t[i].state = 4; t[i].zTotal = 0.5f;
        t[i].normalized.pos.x = (float)(0.5 + (i - 1) * (0.05 + 0.006 * s)); t[i].normalized.pos.y = 0.5f;
      }
      frameCb((MTDeviceRef)&fakePadDev, t, 3, 0, 0); clk += 0.008;
    }
    padLift(); guestGot();
    check(!nDockEv && gotFrames == 11 && gotLifts == 1, "follow: three fingers spreading apart (no way yet): the guest's");
    for (int i = 0; i < 40; i++) pad(3, 0.5, 0.5);
    padSwipe(3, 0.5, 0.2, 20); padLift(); guestGot();
    check(!nDockEv && gotFrames == 61 && world[0].cur == 102, "follow: fingers resting first (over 0.25 s), then a swipe: the guest's");

    // No Space on that side: the guest's swipe, nothing else.
    const uint64_t last2[] = { 101, 102 };
    layout(1, last2, 2, NULL, 0); world[0].cur = 102; settle(vm, NET_APP); guestGot(); takeLook();
    check(takeDisp.ok && takeDisp.left && !takeDisp.right, "follow: the VM's Space is the last: no Space on the right");
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(!nDockEv && gotFrames == 31 && world[0].cur == 102 && capturing, "follow: fingers left, no Space on the right: the guest's swipe, nothing moves");
    layout(1, three3, 3, NULL, 0); world[0].cur = 102; settle(vm, NET_APP); guestGot(); takeLook();

    // A guest that never said where swipes go (3.1.0-3.1.5): frames as always.
    clients[0].edgeKnown = 0; takeLook();
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(!nDockEv && gotFrames == 31 && !takeDisp.ok, "follow: no E from the guest: every frame to it at once, no Dock swipe");
    guestLine(clients[0].fd, g0, "E right left"); takeLook();
    // Malformed: kept as it was.
    const char *bad[] = { "E right", "E up left", "E right left now", "E  ", "e right left", "E right-left" };
    for (int i = 0; i < 6; i++) guestLine(clients[0].fd, g0, bad[i]);
    check(clients[0].edge[0] == 1 && clients[0].edge[1] == -1, "follow: malformed E lines: ignored");
    guestLine(clients[0].fd, g0 + 1, "E - -");
    check(clients[0].edge[0] == 1, "follow: an E from an older connection of that fd: ignored");

    // Setting off: nothing taken, the guest hears X off.
    soOn = 0; swipeOutLook(); guestGot();
    check(!strcmp(gotOther, "X off|") && !clients[0].edgeKnown, "follow: SwipeOut off: X off, what the guest said is forgotten");
    takeLook(); padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(!nDockEv && gotFrames == 31 && world[0].cur == 102, "follow: SwipeOut off: the swipe is the guest's");
    soOn = 1; swipeOutLook(); guestGot(); guestLine(clients[0].fd, g0, "E right left"); takeLook();

    // Two fingers first (scroll momentum): the guest's touch is let go when the swipe is taken.
    clients[0].glide = 1;
    pad(2, 0.6, 0.5); pad(2, 0.6, 0.5);
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(gotFrames == 2 && gotLifts == 1 && world[0].cur == 103, "follow: a third finger on a two-finger touch: the guest's touch let go (F 0), then out");
    clients[0].glide = 0;
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();

    // The capture ends during the swipe: macOS's swipe goes back.
    nDockEv = 0;
    padSwipe(3, 0.6, 0.45, 15);
    front = terminal; frontChanged(terminal, -1, 0, "", 11, 1);
    pad(3, 0.4, 0.5); padLift(); guestGot();
    check(dockLast() == kSwipeCancelled && world[0].cur == 102 && !dockCount(kSwipeEnded), "follow: capture ends during the swipe: Cancelled, no move");
    front = vm; settle(vm, NET_APP); guestGot(); takeLook();

    // A Magic Mouse's two-finger swipe: the same.
    pthread_mutex_lock(&mouseLock);
    mice[0].dev = (MTDeviceRef)&fakeMouseDev; mice[0].id = 88; mice[0].w = 5150; mice[0].h = 9050; mice[0].sent = 0;
    mouseStateInit(&mice[0].st); takeReset(&mice[0].take); nMice = 1;
    pthread_mutex_unlock(&mouseLock);
    nDockEv = 0;
    for (int i = 0; i <= 20; i++) mouse2(0.3 + 0.02 * i);
    guestGot();
    check(nDockEv > 10 && dockEv[0].phase == kSwipeBegan && gotFrames == 0, "follow: Magic Mouse, two fingers right at the edge: macOS's swipe, nothing to the guest");
    mouseLift(); guestGot();
    check(dockLast() == kSwipeEnded && world[0].cur == 101 && gotFrames == 0 && gotLifts == 0, "follow: ... out to the Space on the left");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    guestLine(clients[0].fd, g0, "E right -");
    nDockEv = 0;
    for (int i = 0; i <= 20; i++) mouse2(0.3 + 0.02 * i);
    mouseLift(); guestGot();
    check(!nDockEv && gotFrames > 10 && gotLifts == 1, "follow: Magic Mouse, the guest's way: virtual fingers to the guest as before");
    guestLine(clients[0].fd, g0, "E right left");

    // macOS does not follow (a finished swipe does not change the Space): the one step after
    // all; twice in a row: the one step from then on, no Dock swipe.
    dockFollow = 0; nDockEv = 0; keys = spaceKeys = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(dockLast() == kSwipeEnded && spaceKeys == 1 && lastKey.keycode == 124 && world[0].cur == 103 && dockFollows && !dockMisses &&
          missFlipped && swipeSign == -1 && gotFrames == 0,
          "follow: finished but the Space did not change: one step with macOS's shortcut; the next one tries the other direction");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.6, 0.55, 4); padLift(); guestGot();
    check(dockEv[nDockEv - 1].phase == kSwipeEnded && spaceKeys == 1 && world[0].cur == 103 && dockFollows && dockMisses == 1 &&
          !missFlipped && swipeSign == 1, "follow: ... again (a flick), the other direction misses too: one step, the direction as it was");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(dockLast() == kSwipeEnded && spaceKeys == 1 && world[0].cur == 103 && !dockFollows && swipeSign == 1,
          "follow: ... a third: one step, and so from now on");
    dockFollow = 1;
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(!nDockEv && spaceKeys == 1 && world[0].cur == 103, "follow: the next swipe: no Dock swipe, the one step at the lift");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.6, 0.57, 20); padLift(); guestGot();
    check(!nDockEv && !spaceKeys && world[0].cur == 102 && capturing, "follow: ... a short one (3 % of the width): nothing");
    dockFollows = 1; dockMisses = 0;
    // Finished, but the Space did not change: the one step.
    dockFollow = 0; nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(dockLast() == kSwipeEnded && spaceKeys == 1 && world[0].cur == 103 && dockFollows && !dockMisses && missFlipped,
          "follow: finished but the Space did not change: one step with the shortcut after all (one miss, the other direction next)");
    dockFollow = 1;
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    int saves0 = signSaves;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(world[0].cur == 101 && !missFlipped && swipeSign == 1 && signSaves == saves0 + 1 && dockFollows,
          "follow: ... the other direction lands on the other side (this macOS reads it as before): the direction learned back, kept");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(world[0].cur == 103 && dockMisses == 0 && dockFollows, "follow: ... the next one macOS follows: the misses start again");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();

    // macOS 26 and older read the progress from fields they do not document; a MacBook Pro on
    // 15.7 reads it the other way (user, 2026-10-17: "sometimes it even swipes into the false
    // direction first"). The escape combo's learned way counts for the swipe that follows the fingers.
    dockSign = -1; swipeSign = -1; nDockEv = 0; spaceKeys = 0; saves0 = signSaves;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(world[0].cur == 103 && !spaceKeys && dockEv[nDockEv - 1].phase == kSwipeEnded && dockEv[nDockEv - 1].p > 0 && signSaves == saves0,
          "follow, macOS 15 (learned way -1): out to the right with the fingers, the progress the other way, no shortcut");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    // Not learned yet: macOS goes the other way once, the way is learned and kept.
    swipeSign = 1; nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(world[0].cur == 101 && swipeSign == -1 && signSaves == saves0 + 1 && dockFollows,
          "follow, macOS 15 (not learned): macOS went to the left instead: the direction learned");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(world[0].cur == 103 && swipeSign == -1, "follow, macOS 15: ... the next swipe goes to the right with the fingers");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    // A miss first (the wrong way only bounced): the other direction is tried, lands and is kept.
    swipeSign = 1; dockFollow = 0; nDockEv = 0; spaceKeys = 0; saves0 = signSaves;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(spaceKeys == 1 && world[0].cur == 103 && missFlipped && swipeSign == -1, "follow, macOS 15: a miss: one step, the other direction next");
    dockFollow = 1;
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(world[0].cur == 103 && !spaceKeys && !missFlipped && swipeSign == -1 && signSaves == saves0 + 1,
          "follow, macOS 15: ... the other direction lands with the fingers: learned and kept");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    dockSign = 1; swipeSign = 1;

    // The fingers the guest switches workspaces with (user, 2026-10-14: "3 finger is for window tiling,
    // and 4 for workspace swiping"): "G", Hyprland's gestures.
    nDockEv = 0;
    padFour(0.5, 0.25, 30); padLift(); guestGot();
    check(dockLast() == kSwipeEnded && world[0].cur == 103 && gotFrames == 0,
          "fingers: four fingers that come down one after the other (no G: any 3+): out with the fingers (a 4th finger is no pinch)");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    const char *badG[] = { "G", "G 1lr", "G 4", "G 4x", "G 10lr", "G 4lr,3l", "G -lr", "G 4lr  3l x" };
    for (int i = 0; i < 8; i++) guestLine(clients[0].fd, g0, badG[i]);
    check(!clients[0].waysKnown, "fingers: malformed G lines: ignored");
    guestLine(clients[0].fd, g0, "G 4lr");
    check(clients[0].waysKnown && clients[0].ways[0] == 1u << 4 && clients[0].ways[1] == 1u << 4, "fingers: G 4lr kept");
    nDockEv = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(!nDockEv && gotFrames == 31 && world[0].cur == 102 && capturing,
          "fingers: G 4lr, three fingers out at the edge: the guest's (they tile there), no swipe out");
    nDockEv = 0;
    padFour(0.5, 0.25, 30); padLift(); guestGot();
    check(dockLast() == kSwipeEnded && world[0].cur == 103 && gotFrames == 0, "fingers: G 4lr, four fingers (one after the other): out with the fingers");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    guestLine(clients[0].fd, g0, "G 4l");
    nDockEv = 0;
    padFour(0.3, 0.55, 30); padLift(); guestGot();
    check(!nDockEv && world[0].cur == 102 && gotFrames > 30, "fingers: G 4l (4 fingers right do something else): four fingers right: the guest's");
    guestLine(clients[0].fd, g0, "G -");
    nDockEv = 0;
    padFour(0.5, 0.25, 30); padLift(); guestGot();
    check(!nDockEv && world[0].cur == 102 && gotFrames > 30, "fingers: G - (no workspace swipe set): nothing is the Mac's");
    guestLine(clients[0].fd, g0, "G 3lr 4lr");
    nDockEv = 0;
    padSwipe(3, 0.6, 0.3, 30); padLift(); guestGot();
    check(dockLast() == kSwipeEnded && world[0].cur == 103, "fingers: G 3lr 4lr: three fingers out as before");
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot(); takeLook();
    guestLine(clients[0].fd, g0, "G 3lr");
    nDockEv = 0;
    for (int i = 0; i <= 20; i++) mouse2(0.3 + 0.02 * i);
    mouseLift(); guestGot();
    check(!nDockEv && gotFrames > 10 && world[0].cur == 102,
          "fingers: G 3lr, a Magic Mouse sending four virtual fingers (MouseSwipeFingers): its swipe stays the guest's");
    soOn = 0; swipeOutLook(); guestGot();
    check(!clients[0].waysKnown, "fingers: SwipeOut off: what the guest said is forgotten (G too)");
    soOn = 1; swipeOutLook(); guestGot(); guestLine(clients[0].fd, g0, "E right left"); takeLook();

    // Two displays with "all": the fingers' display follows them, the other one the shortcut.
    const uint64_t in2[] = { 201, 202 }, out2[] = { 301, 302 };
    layout(2, in2, 2, out2, 2);
    owner[201] = terminal; winOn[201] = 11; owner[202] = vm; winOn[202] = 22;
    owner[301] = safari; winOn[301] = 44; owner[302] = vm; winOn[302] = 23;
    world[0].cur = 202; world[1].cur = 302; front = vm; pointer = CGPointMake(3000, 600); all = 1;
    settle(vm, NET_APP); guestGot(); takeLook();
    check(takeDisp.ok && takeDisp.id == 2 && takeDisp.left && !takeDisp.right, "follow, two displays: the pointer's display 2, a Space on its left");
    nDockEv = 0; spaceKeys = 0;
    padSwipe(3, 0.3, 0.6, 30); padLift(); guestGot();
    check(world[1].cur == 301 && world[0].cur == 201 && spaceKeys == 1 && movedOn[0] == 1,
          "follow, EscapeSwipe all: display 2 with the fingers, display 1 one step with the shortcut");
    all = 0;
    settle(vm, NET_APP); press(K, HID, 0); settle(vm, NET_APP); guestGot();
    dockPostFn = dockPost; takeClockFn = monoNow; hidSwipeFn = hidSwipeOS;
    pthread_mutex_lock(&padLock); nPads = 0; activePad = -1; pthread_mutex_unlock(&padLock);
    pthread_mutex_lock(&mouseLock); nMice = 0; pthread_mutex_unlock(&mouseLock);
    soOn = 0; swipeOutLook(); guestGot();
  }

  // ---- the swipe model on its own (swipe-take.h) ----
  {
    check(takeCommit(0.6, 0) && !takeCommit(0.4, 0.2) && takeCommit(0.1, 1.0) && !takeCommit(0.04, 3) && !takeCommit(0.9, -0.5),
          "model: past half a Space finishes; under it only a flick; going back never");
    SwipeTake s; takeReset(&s);
    double t = 0;
    check(takeFrame(&s, 3, 1, -1, 1, -1, 0, 0, 0.5, t) == TK_HOLD, "model: three fingers at an edge: held");
    int r = TK_HOLD;
    for (int i = 0; i < 40 && r == TK_HOLD; i++) r = takeFrame(&s, 3, 1, -1, 1, -1, 0, 0, 0.5, t += 0.008);
    check(r == TK_FLUSH && s.state == TAKE_PASS, "model: resting longer than 0.25 s: the guest's");
    takeReset(&s);
    takeFrame(&s, 3, 1, 0, 1, 0, -0.01, 0, 0.5, t);
    check(takeFrame(&s, 3, 1, 0, 1, 0, -0.015, 0, 0.5, t += 0.008) == TK_BEGIN && s.toward == 1 && fabs(s.progress - 0.025 / 0.5) < 1e-9,
          "model: 2.5 % of the width to the left: taken, from where the fingers are");
    takeFrame(&s, 3, 0, 0, 0, 0, 0.05, 0, 0.5, t += 0.008);
    check(s.progress == 0 && s.state == TAKE_TAKEN, "model: back past the start: the VM's Space, not further");
    check(takeFrame(&s, 2, 0, 0, 0, 0, 0, 0, 0.5, t += 0.008) == TK_END && !s.commit && s.state == TAKE_DONE, "model: one finger up: the end, back");
    check(takeFrame(&s, 3, 1, -1, 1, -1, -0.2, 0, 0.5, t += 0.008) == TK_DROP && takeFrame(&s, 0, 0, 0, 0, 0, 0, 0, 0.5, t) == TK_DROP && s.state == TAKE_IDLE,
          "model: after the end nothing until every finger is up");
    check(takeFrame(&s, 3, 0, 0, 0, 0, 0, 0, 0.5, t) == TK_FORWARD && s.state == TAKE_PASS, "model: no way out either way: the guest's at once");
    takeReset(&s);
    check(takeFrame(&s, 3, 1, -1, 0, 0, 0, 0, 0.5, t) == TK_HOLD, "model: an edge, but 3 fingers do not switch workspaces: held (a 4th may come)");
    takeFrame(&s, 4, 1, -1, 1, -1, -0.01, 0, 0.5, t += 0.008);
    check(takeFrame(&s, 4, 1, -1, 1, -1, -0.015, 0, 0.5, t += 0.008) == TK_BEGIN, "model: ... the 4th finger down, then the way: taken (4 fingers switch)");
    takeReset(&s);
    takeFrame(&s, 3, 1, -1, 0, 0, -0.01, 0, 0.5, t);
    check(takeFrame(&s, 3, 1, -1, 0, 0, -0.015, 0, 0.5, t += 0.008) == TK_FLUSH && s.state == TAKE_PASS,
          "model: ... three fingers going out: the guest's (they do something else there)");
  }

  // ---- the Dock's swipe events (as macOS 26 and older read them, and as macOS 27 does) ----
  {
    CGPoint at = CGPointMake(100, 200);
    CGEventRef extra, e = dockSwipeEvent(0, kSwipeChanged, -0.75, 0, at, &extra);
    float f = -0.75f; uint32_t bits; memcpy(&bits, &f, sizeof bits);
    check(e && extra && CGEventGetIntegerValueField(e, 55) == 30 && CGEventGetIntegerValueField(e, 110) == 23 &&
          CGEventGetIntegerValueField(e, 132) == kSwipeChanged && CGEventGetIntegerValueField(e, 134) == kSwipeChanged &&
          CGEventGetDoubleValueField(e, 124) == -0.75 && (uint32_t)CGEventGetIntegerValueField(e, 135) == bits &&
          CGEventGetIntegerValueField(e, 123) == 1 && CGEventGetIntegerValueField(extra, 55) == 29,
          "events (fields): Changed at -0.75: the Dock's swipe, phase, progress (also as a float's bits), horizontal, plus the gesture event");
    CFRelease(e); CFRelease(extra);
    e = dockSwipeEvent(0, kSwipeEnded, -1.2, -3.5, at, &extra);
    check(e && CGEventGetIntegerValueField(e, 132) == kSwipeEnded && CGEventGetDoubleValueField(e, 129) == -3.5, "events (fields): Ended carries the speed");
    CFRelease(e); CFRelease(extra);
    HIDEventRef (*copyHID)(CGEventRef) = (HIDEventRef (*)(CGEventRef))dlsym(RTLD_DEFAULT, "SLEventCopyIOHIDEvent");
    uint32_t (*hidType)(HIDEventRef) = (uint32_t (*)(HIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    CFIndex (*hidInt)(HIDEventRef, uint32_t) = (CFIndex (*)(HIDEventRef, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventGetIntegerValue");
    double (*hidFloat)(HIDEventRef, uint32_t) = (double (*)(HIDEventRef, uint32_t))dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    uint32_t (*hidPhase)(HIDEventRef) = (uint32_t (*)(HIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetPhase");
    CFArrayRef (*hidKids)(HIDEventRef) = (CFArrayRef (*)(HIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
    if (!lookUpHID() || !copyHID || !hidType || !hidInt || !hidFloat || !hidPhase || !hidKids) {
      printf("ok   events (IOHIDEvent): not on this macOS, skipped\n");
    } else {
      e = dockSwipeEvent(1, kSwipeChanged, -0.75, 0, at, &extra);
      HIDEventRef h = e ? copyHID(e) : NULL;
      check(e && !extra && CGEventGetType(e) == 30 && h && hidType(h) == 23 && hidInt(h, HID_FIELD(23, 1)) == 1 &&
            hidInt(h, HID_FIELD(23, 5)) == 3 && hidFloat(h, HID_FIELD(23, 2)) == -0.75 && hidPhase(h) == kSwipeChanged,
            "events (IOHIDEvent, macOS 27): a type-30 event carrying a Dock swipe: horizontal, the Dock's flavor, progress, phase");
      if (h) CFRelease(h);
      if (e) CFRelease(e);
      e = dockSwipeEvent(1, kSwipeCancelled, 0.4, 2.5, at, &extra);
      h = e ? copyHID(e) : NULL;
      CFArrayRef kids = h ? hidKids(h) : NULL;
      HIDEventRef v = kids && CFArrayGetCount(kids) == 1 ? CFArrayGetValueAtIndex(kids, 0) : NULL;
      check(h && hidPhase(h) == kSwipeCancelled && v && hidType(v) == 9 && hidFloat(v, HID_FIELD(9, 0)) == 2.5,
            "events (IOHIDEvent): Cancelled carries the speed as a velocity event");
      if (h) CFRelease(h);
      if (e) CFRelease(e);
    }
  }

  // Which apps the combo goes back to.
  check(isOther(terminal, -1, "Terminal", 1), "back to: a regular app");
  check(!isOther(terminal, -1, "Raycast", 0), "... not an accessory app (Raycast, Alfred, Spotlight, a quick panel)");
  check(!isOther(terminal, -1, "loginwindow", 1) && !isOther(vm, NET_APP, "OmacVM", 1), "... not the lock screen, not a VM app");

  // The plan on its own.
  DisplaySpaces p = { .n = 3, .spaces = { 1, 2, 3 }, .current = 2 };
  check(stepOut(&p) == -1, "plan: out of a Space in the middle (not known where from): to the left");
  p.current = 1;
  check(stepOut(&p) == 1, "plan: out of the first Space: to the right");
  check(stepToward(&p, 2) == 1 && stepToward(&p, 3) == 0 && stepToward(&p, 9) == 0,
        "plan: back only to a Space right beside (else the VM's window)");

  CFRelease(n0); CFRelease(n1);
  end(terminal); end(vm); end(safari); end(finder);
  return fail;
}
