#!/usr/bin/env python3
"""replay.py MODE [ARGS] (root, in a TEST VM only, never a VM someone uses): the guest side of the Mac's
trackpad lines, without a person at the trackpad (3.4.1: a pinch started with a right click on Omarchy 4.5).

Loads the installed daemon (/usr/local/bin/omacvm-gestures) as a module and feeds its own handle() the lines the
Mac's Gestures sends (F, O, A, W, P), ticking pad.flush()/glide.idle() every 2 ms as its run() loop does. Its own
make_device() makes the virtual trackpad ("Apple Inc. Magic Trackpad (OmacVM)"), so Hyprland's per-device
settings apply as to the real one. Stop the service first (`systemctl stop omacvm-gestures`: one such trackpad).

  pinch N PRE_MS       N pinches (spread out = zoom in): two fingers down, PRE_MS of small spread before macOS's
                       magnify ("P", as the helper sends it at macOS's first magnify event), then 400 ms of spread
  scroll N             N two-finger scrolls (fingers moving up, macOS's "A" while touching, "W" momentum after)
  hold2 N HOLD_MS      N times two still fingers for HOLD_MS (a two-finger click's fingers), 1.5 s apart
  tap3 N               N three-finger taps: three still fingers 80 ms, 1.5 s apart
  swipe N FINGERS L|R  N sideways swipes with FINGERS (3 or 4), fingers going left or right: 300 ms, a third of the pad
Scroll momentum on (the user's features) unless OMACVM_FEATURE_scroll_momentum=off is given.

What to watch (the pointer over a browser with pinch.html beside this file open: its console lines "PC ..."):
  libinput debug-events --enable-tap|--disable-tap   (libinput-tools; its own libinput context, so give it the
      tap setting Hyprland has for the trackpad). Before 3.4.1 on Omarchy 4.5 (tap on), `replay.py pinch 3 80`
      shows POINTER_BUTTON BTN_RIGHT pressed just before each GESTURE_PINCH_BEGIN and the page gets a
      contextmenu; with tap_to_click = false no button, GESTURE_PINCH_BEGIN/UPDATE still, and the page zooms.
"""
import importlib.machinery
import importlib.util
import os
import sys
import time

os.environ.setdefault("OMACVM_FEATURE_gestures", "on")
os.environ.setdefault("OMACVM_FEATURE_scroll_momentum", "on")
loader = importlib.machinery.SourceFileLoader("omg", "/usr/local/bin/omacvm-gestures")
spec = importlib.util.spec_from_loader("omg", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)


class NoKeys:
    def key(self, *a):
        pass

    def release(self):
        pass


ui = m.make_device()
pad = m.Touchpad(ui)
glide = m.Glide(pad)
keys = NoKeys()
FRAME = 0.008       # the Mac's trackpad frames, ~120 Hz


def tick(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        pad.flush()
        glide.idle()
        time.sleep(0.002)


def send(line):
    m.handle(line.encode().split(), pad, keys, glide)


def two(x0, y0, x1, y1):
    send(f"F 2 1 {x0:.5f} {y0:.5f} 0.500 2 {x1:.5f} {y1:.5f} 0.500")


def pinch(pre_ms):
    r = 0.10
    steps = max(1, round(pre_ms / 1000 / FRAME))
    for i in range(steps):             # before macOS calls it a pinch: a little spread
        r1 = r + 0.008 * i / steps
        two(0.5 - r1, 0.5, 0.5 + r1, 0.5)
        tick(FRAME)
    r += 0.008
    send("P")
    for i in range(50):                 # the pinch itself: 400 ms of spread
        r1 = r + 0.15 * (i + 1) / 50
        two(0.5 - r1, 0.5, 0.5 + r1, 0.5)
        tick(FRAME)
    send("F 0")
    tick(1.2)


def scroll():
    y = 0.70
    for i in range(30):                  # 240 ms, fingers moving up 0.25 of the pad
        y -= 0.25 / 30
        two(0.42, y, 0.58, y)
        send("A 0.00 -9.00")
        tick(FRAME)
    send("F 0")
    v = -9.0
    for i in range(40):                   # macOS's momentum, decaying
        v *= 0.9
        send(f"W 0.00 {v:.2f}")
        tick(0.016)
    tick(1.0)


def hold2(hold_ms):
    steps = max(1, round(hold_ms / 1000 / FRAME))
    print(f"{time.time():.3f} down", flush=True)      # the Mac side clicks the right button now (QMP)
    for i in range(steps):
        two(0.42, 0.5, 0.58, 0.5)
        tick(FRAME)
    send("F 0")
    tick(1.5)


def many(n, x0, dx, y=0.5, ms=300):
    steps = max(1, round(ms / 1000 / FRAME))
    for i in range(steps + 1):
        x = x0 + dx * i / steps
        send(f"F {n} " + " ".join(f"{k + 1} {x + 0.06 * k:.5f} {y + 0.02 * (k % 2):.5f} 0.500" for k in range(n)))
        tick(FRAME)
    send("F 0")


def tap3():
    for i in range(10):              # 80 ms still
        send("F 3 1 0.40000 0.50000 0.500 2 0.48000 0.52000 0.500 3 0.56000 0.50000 0.500")
        tick(FRAME)
    send("F 0")
    tick(1.5)


def swipe(fingers, way):
    if way == "L":
        many(fingers, 0.55, -0.33)      # fingers going left
    else:
        many(fingers, 0.22, 0.33)       # fingers going right
    tick(1.5)


def main():
    mode = sys.argv[1]
    n = int(sys.argv[2])
    send("O 1 15600 9600")
    tick(1.5)           # libinput and Hyprland take the new device
    wait = os.environ.get("PC_WAIT_FILE")      # a device made before a change, used after it
    if wait:
        print(f"{time.time():.3f} device up, waiting for {wait}", flush=True)
        while not os.path.exists(wait):
            tick(0.2)
    print(f"{time.time():.3f} replay {mode} start (scroll momentum {'on' if m.GLIDE_ON else 'off'})", flush=True)
    for k in range(n):
        t = time.time()
        if mode == "pinch":
            pinch(float(sys.argv[3]))
        elif mode == "scroll":
            scroll()
        elif mode == "hold2":
            hold2(float(sys.argv[3]))
        elif mode == "tap3":
            tap3()
        elif mode == "swipe":
            swipe(int(sys.argv[3]), sys.argv[4])
        print(f"{t:.3f} {mode} {k + 1}", flush=True)
    tick(0.5)
    ui.close()


if __name__ == "__main__":
    main()
