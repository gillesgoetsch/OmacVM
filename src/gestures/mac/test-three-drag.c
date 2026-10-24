// Offline test of macOS's Three Finger Drag (test.sh): the setting is read
// from a throwaway domain (test.sh names it per run and deletes it), never
// macOS's own; made-up trackpad frames and gesture events go through the
// helper's real frame callback and event tap, and what it sends the guest is
// read back from a socket pair. No permissions, no device, nothing posted.
//   off (not set, the default)  -> three and four fingers go to the VM, macOS's gesture events dropped
//   on (set while running)      -> three fingers stay macOS's (nothing to the guest, its events pass),
//                                  four still go to the VM; a swipe out only with four
//   off again                   -> three fingers go to the VM again
#ifndef THREE_DRAG_DOMAIN
#define THREE_DRAG_DOMAIN "org.omacvm.test.three-drag"
#endif
#define THREE_DRAG_DOMAINS { CFSTR(THREE_DRAG_DOMAIN) }
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

// What the guest got since the last call: finger frames with n > 0 per
// finger count (frames[n]), and how many "F 0" (a touch over).
static int frames[8], ends;
static void drain(void) {
  memset(frames, 0, sizeof frames); ends = 0;
  char buf[16384];
  for (;;) {
    ssize_t n = read(peer, buf, sizeof buf - 1);
    if (n <= 0) break;
    buf[n] = 0;
    for (char *l = buf; *l; ) {
      int k;
      if (sscanf(l, "F %d", &k) == 1) { if (k == 0) ends++; else if (k < 8) frames[k]++; }
      char *nl = strchr(l, '\n');
      if (!nl) break;
      l = nl + 1;
    }
  }
}

static MTDeviceRef pad = (MTDeviceRef)(uintptr_t)0x1001;
// One trackpad frame with n fingers, moved a little to the left each time.
static void touch(int n, int step) {
  MTTouch t[5]; memset(t, 0, sizeof t);
  for (int i = 0; i < n; i++) {
    t[i].state = 4; t[i].zTotal = 0.5f; t[i].pathIndex = i + 1;
    t[i].normalized.pos.x = 0.5f + 0.08f * (float)i - 0.01f * (float)step; t[i].normalized.pos.y = 0.5f;
  }
  frameCb(pad, t, n, 0, 0);
}
static void swipe(int n) { for (int i = 0; i < 10; i++) touch(n, i); touch(0, 0); }

// A gesture event from macOS (NSEventTypeGesture) through the tap: 1 = passed on.
static int gestureEvent(void) {
  CGEventRef e = CGEventCreate(NULL);
  CGEventSetType(e, (CGEventType)29);
  CGEventRef out = tapCb(NULL, (CGEventType)29, e, NULL);
  CFRelease(e);
  return out != NULL;
}

static void setDrag(int on) {
  CFPreferencesSetAppValue(CFSTR("TrackpadThreeFingerDrag"), on < 0 ? NULL : on ? kCFBooleanTrue : kCFBooleanFalse,
                           CFSTR(THREE_DRAG_DOMAIN));
  CFPreferencesAppSynchronize(CFSTR(THREE_DRAG_DOMAIN));
  threeDragLook();
}

int main(void) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { perror("socketpair"); return 1; }
  peer = sv[1]; fcntl(peer, F_SETFL, O_NONBLOCK);
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  clients[0].fd = sv[0]; clients[0].net = NET_APP; clients[0].gestures = 1; clients[0].target = 1;
  strcpy(clients[0].ip, "127.0.0.1");
  frontNet = NET_APP; capturing = 1; trackpad = 1;
  scrollStateInit(&scrollSt);
  pads[0].dev = pad; pads[0].id = 1; pads[0].w = 15600; pads[0].h = 9600; nPads = 1; activePad = 0;
  threeDragEvery = 0;

  // 1. Not set (a Mac that never chose a dragging style): as before.
  setDrag(-1);
  check(threeDrag == 0, "not set: off");
  swipe(3); drain();
  check(frames[3] == 10 && ends == 1, "off: a three-finger swipe goes to the VM");
  swipe(4); drain();
  check(frames[4] == 10 && ends == 1, "off: a four-finger swipe goes to the VM");
  touch(3, 0);
  check(!gestureEvent(), "off: macOS's gesture event for three fingers is dropped (the VM's swipe)");
  touch(0, 0); drain();

  // 2. Three Finger Drag turned on while it runs: read at the next look.
  setDrag(1);
  check(threeDrag == 1, "on: read live");
  swipe(3); drain();
  check(frames[3] == 0 && ends == 0, "on: three fingers send the VM nothing (macOS's drag)");
  touch(3, 0);
  check(gestureEvent(), "on: macOS's gesture events for three fingers pass");
  touch(0, 0);
  swipe(4); drain();
  check(frames[4] == 10 && ends == 1, "on: a four-finger swipe still goes to the VM");
  touch(4, 0);
  check(!gestureEvent(), "on: macOS's gesture event for four fingers is dropped");
  touch(0, 0); drain();
  // Four fingers, then one lifts: the guest's touch ends, the three are macOS's.
  for (int i = 0; i < 5; i++) touch(4, i);
  for (int i = 5; i < 10; i++) touch(3, i);
  touch(0, 0); drain();
  check(frames[4] == 5 && frames[3] == 0 && ends == 1, "on: four then three fingers: the guest's touch ends at three");

  // 3. Swipe out to macOS: only with a finger count the guest has and that is not the drag.
  swipeOut = 1;
  clients[0].edgeKnown = 1; clients[0].edge[0] = -1; clients[0].edge[1] = 1;
  clients[0].waysKnown = 1; clients[0].ways[0] = clients[0].ways[1] = 1u << 3 | 1u << 4;
  takeDisp.ok = 1; takeDisp.left = takeDisp.right = 1;
  int sl, sr;
  takeSides(&sl, &sr, 3, 1);
  check(!sl && !sr, "on: no swipe out with three fingers");
  takeSides(&sl, &sr, 4, 1);
  check(sl && sr, "on: swipe out with four fingers");
  takeSides(&sl, &sr, 3, 0);
  check(sl && sr, "on: a Magic Mouse's swipe as three fingers still goes out (no drag there)");
  setDrag(0);
  takeSides(&sl, &sr, 3, 1);
  check(sl && sr, "off: swipe out with three fingers");
  swipeOut = 0; takeDisp.ok = 0;

  // 4. Off again (System Settings writes false): three fingers are the VM's again.
  check(threeDrag == 0, "off again: read live");
  swipe(3); drain();
  check(frames[3] == 10 && ends == 1, "off again: a three-finger swipe goes to the VM");

  setDrag(-1);
  printf("%s\n", fail ? "FAIL three-drag" : "ok   three-drag: three fingers stay macOS's only with its Three Finger Drag");
  return fail;
}
