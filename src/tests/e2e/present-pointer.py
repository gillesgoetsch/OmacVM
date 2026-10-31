#!/usr/bin/python3 -I
# present-pointer.py SECS [HZ] (root, in a test VM; present-locked.sh): a uinput mouse that keeps the
# pointer in the top right of the screen for SECS, where 3.2.14 squeezed the tiles (#637): each round
# it goes to the top-right corner (a large move clamps there), then sweeps left about 700 px and back
# with a small up and down, HZ moves a second (default 60). Guest input only, none on the Mac.
# Prints "moves N in S s".
import fcntl, math, os, struct, sys, time

secs = float(sys.argv[1])
hz = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
EV_SYN, EV_KEY, EV_REL, REL_X, REL_Y, BTN_LEFT = 0, 1, 2, 0, 1, 0x110
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
for bit, val in ((UI_SET_EVBIT, EV_KEY), (UI_SET_EVBIT, EV_REL), (UI_SET_KEYBIT, BTN_LEFT),
                 (UI_SET_RELBIT, REL_X), (UI_SET_RELBIT, REL_Y)):
    fcntl.ioctl(fd, bit, val)
# struct uinput_user_dev: name[80], input_id (bustype, vendor, product, version), ff_effects_max, abs arrays
os.write(fd, b"omacvm present test mouse".ljust(80, b"\0") + struct.pack("<HHHHI", 3, 0x1234, 0x5679, 1, 0)
         + b"\0" * (64 * 4 * 4))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1)


def ev(t, c, v):
    s = time.time()
    os.write(fd, struct.pack("<qqHHi", int(s), int((s % 1) * 1e6), t, c, v))


def move(dx, dy):
    ev(EV_REL, REL_X, dx)
    ev(EV_REL, REL_Y, dy)
    ev(EV_SYN, 0, 0)


t0 = time.time()
n = 0
try:
    while time.time() - t0 < secs:
        for _ in range(4):              # to the top-right corner
            move(4000, -4000)
            n += 1
            time.sleep(1 / hz)
        for k in range(240):            # 4 s: left and back, a little down and up
            dy = int(round(3 * math.sin(k * 2 * math.pi / 60)))
            move(-6 if k < 120 else 6, dy + (2 if k < 120 else -2))
            n += 1
            time.sleep(1 / hz)
            if time.time() - t0 >= secs:
                break
finally:
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)
print("moves %d in %.0f s" % (n, time.time() - t0))
