// Magic Mouse gestures for the VM: what a Magic Mouse's touches mean, frame by
// frame. No device, no AppKit, so test-mouse.c checks it with made-up frames.
//
// A Magic Mouse's surface reports every finger on it, also a finger that just
// rests there while the hand moves or clicks the mouse (it does not move on the
// surface then). Two gestures are taken out of that:
//   * two fingers sliding sideways: a workspace swipe. It follows the fingers
//     (MOUSE_SWIPE with the travel in mm) until they lift (MOUSE_SWIPE_END).
//   * one finger flicked sideways: back or forward, once per touch. Slow
//     sideways movement and up/down movement stay scrolling.
// Scrolling itself is not touched here: macOS turns the same touches into
// scroll events, which go to the VM app as before.
#ifndef OMACVM_MOUSE_MODEL_H
#define OMACVM_MOUSE_MODEL_H
#include <math.h>
#include <string.h>

// One finger on the mouse, in mm on its surface: x across the mouse (left to
// right), y along it.
typedef struct { int id; float x, y; } MouseTouch;

enum { MOUSE_NONE, MOUSE_SWIPE, MOUSE_SWIPE_END, MOUSE_BACK, MOUSE_FORWARD };

#define MOUSE_SWIPE_START_MM 4.0f    // two fingers: sideways travel that makes a swipe
#define MOUSE_SWIPE_RATIO 2.0f       // ... and it must be this much more sideways than along
#define MOUSE_FLICK_MM 12.0f         // one finger: sideways travel within MOUSE_FLICK_TIME
#define MOUSE_FLICK_TIME 0.35        // s
#define MOUSE_FLICK_RATIO 2.5f
#define MOUSE_HIST 64

typedef struct {
  int n;                 // fingers in the last frame
  int two;               // 2+ fingers since all last lifted: no flick until they all lift
  int blocked;           // these two fingers moved some other way: no swipe until they lift
  int swiping;           // a two-finger swipe under way
  float sx, sy;          // the two fingers' centre when they came down
  float ax;              // the centre when the swipe began
  float dx;              // the swipe's travel since then (mm)
  int fired;             // this one-finger touch flicked already
  int oneId;
  struct { double t; float x, y; } hist[MOUSE_HIST];
  int nh;
} MouseState;

static inline void mouseStateInit(MouseState *s) { memset(s, 0, sizeof *s); s->oneId = -1; }

// One frame with k fingers (c[0..k-1]) at time now (s). Returns what it means.
static inline int mouseFrame(MouseState *s, const MouseTouch *c, int k, double now) {
  if (k <= 0) {
    int was = s->swiping;
    mouseStateInit(s);
    return was ? MOUSE_SWIPE_END : MOUSE_NONE;
  }
  if (k >= 2) {
    float cx = (c[0].x + c[1].x) / 2, cy = (c[0].y + c[1].y) / 2;
    if (s->n < 2) { s->sx = cx; s->sy = cy; s->blocked = 0; }   // (again) two fingers down
    s->n = k; s->two = 1; s->nh = 0;
    if (s->swiping) { s->dx = cx - s->ax; return MOUSE_SWIPE; }
    if (s->blocked) return MOUSE_NONE;
    float dx = cx - s->sx, dy = cy - s->sy;
    if (fabsf(dx) >= MOUSE_SWIPE_START_MM && fabsf(dx) >= MOUSE_SWIPE_RATIO * fabsf(dy)) {
      s->swiping = 1; s->ax = cx; s->dx = 0;
      return MOUSE_SWIPE;
    }
    if (hypotf(dx, dy) >= MOUSE_SWIPE_START_MM) s->blocked = 1;   // along the mouse: not a swipe
    return MOUSE_NONE;
  }
  // One finger.
  s->n = 1;
  if (s->swiping) { s->swiping = 0; return MOUSE_SWIPE_END; }   // one of the two lifted
  if (s->two || s->fired) return MOUSE_NONE;
  if (c[0].id != s->oneId) { s->oneId = c[0].id; s->nh = 0; }
  // The last MOUSE_FLICK_TIME of this finger: a resting finger may lie on the
  // mouse for minutes before it flicks.
  int drop = 0;
  while (drop < s->nh && now - s->hist[drop].t > MOUSE_FLICK_TIME) drop++;
  if (s->nh == MOUSE_HIST && drop == 0) drop = 1;
  if (drop) { memmove(s->hist, s->hist + drop, sizeof s->hist[0] * (size_t)(s->nh - drop)); s->nh -= drop; }
  s->hist[s->nh].t = now; s->hist[s->nh].x = c[0].x; s->hist[s->nh].y = c[0].y; s->nh++;
  float dx = c[0].x - s->hist[0].x, dy = c[0].y - s->hist[0].y;
  if (fabsf(dx) >= MOUSE_FLICK_MM && fabsf(dx) >= MOUSE_FLICK_RATIO * fabsf(dy)) {
    s->fired = 1;   // once per touch: the way back without lifting is no flick
    // As macOS's "Swipe between pages": the finger pulls the page, so a flick
    // to the right shows the page before.
    return dx > 0 ? MOUSE_BACK : MOUSE_FORWARD;
  }
  return MOUSE_NONE;
}

// Which multi-touch device is a Magic Mouse. MultitouchSupport's family id is
// 112 for the Magic Mouse and Magic Mouse 2 (seen: Magic Mouse 2, product
// 0x0269); the HID product ids are those Linux's hid-magicmouse knows (Magic
// Mouse 0x030d, Magic Mouse 2 0x0269, Magic Mouse USB-C 0x0323). A device
// with neither (a newer model) still counts by its shape: not built in, a
// surface under 100 mm wide and longer than wide (a trackpad is wider than
// long, as is a Touch Bar).
static inline int isMagicMouseKind(int builtIn, int family, int product, int w, int h) {
  if (builtIn) return 0;
  if (family == 112) return 1;
  if (product == 0x030d || product == 0x0269 || product == 0x0323) return 1;
  return w > 0 && w < 10000 && h > w;
}
#endif
