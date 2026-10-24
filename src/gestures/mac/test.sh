#!/bin/bash
# Offline test (no VM, no permissions) of the Mac helper's own handshake and
# choice (test-gestures.c) against the guest daemon's own run() (omacvm-gestures):
# 1. An OmacVM.app VM on its fast network (192.168.77.1) counts as the app's,
#    never UTM's, and a UTM VM never as the app's.
# 2. An app VM on the fast network as in the VM: the gateway is 192.168.77.1,
#    so it connects there and both proofs name 192.168.77.1. Then the app moves
#    it to the user network (the gateway becomes 10.0.2.2): it connects again
#    within seconds, on keepalive, and the Mac drops its old connection.
#    A guest's connection that ends (closed by the VM, or reset: keepalive
#    during the Mac's sleep) is dropped at once and logged (2c).
# 3. The default gateway: the card with a link, lowest metric, the same in
#    Gestures, the Bridge client and the guest check.
# 4. The event tap is created again when another OmacVM VM (a new QEMU, whose
#    own tap sits ahead of ours) comes to the front, and when macOS invalidated
#    it; a failed re-creation keeps the old tap and is logged once. Accessibility
#    (or Input Monitoring) taken away: the tap and its run-loop source go and
#    the trackpads are let go at once, nothing enables or creates a tap again
#    until it is back (issue #192). A tap macOS (or the watchdog) disabled is
#    removed, never enabled again; a new one after 2 s, then 30 s; the third
#    in 10 minutes parks it until the Accessibility list changes (#290).
#    OmacVM.app's hidden shareKeyboard puts it at the end of the chain (#350)
#    (test-tap.c).
# 5. Ctrl+Option+Esc (and the old Ctrl+Option+Cmd+Esc, exact modifiers only): in the VM the display under the pointer moves out
#    with macOS's own Space shortcut as the user set it (or every display
#    with "all"), toward the Space it came from; in macOS back in; not moved
#    or the shortcut off -> a Dock swipe; still not moved, or no Spaces
#    information -> a notice in Omarchy, nothing else (never Mission
#    Control); never out of full screen, never hidden; the keyboard follows the pointer's display; pressed in
#    Mission Control (after the double press) it closes it and goes back into the VM; with the VM on
#    two displays "Focused monitor" is the display with the VM's own focus (the guest answers "Q"
#    with "D", test-focus.py), else the pointer's, and back in also on a display that shows a
#    second VM window; a second press before the move out drops it; the posted key's
#    shape and marker (test-escape.c, a made-up world of displays and Spaces:
#    nothing posted, swiped or activated). The marker is the same in
#    Gestures, the Bridge and QEMU's patch. The guest names the combo pressed,
#    and after the old one the new one, once per VM; no other notice (test-escape-notice.py).
#    Swipe out to macOS (#342): with a guest that says where swipes go ("E", after
#    "X on 2") a swipe out at the VM's edge is the Mac's: held back from the guest
#    until its way is clear, then macOS's own Space swipe follows the fingers (a
#    made-up Dock: Began, Changed..., Ended or Cancelled at the lift: pulled back,
#    slow, flick), the Magic Mouse's too; inward, up and down, a tap, a pinch, no
#    Space on that side, the setting off or a guest that says nothing: the guest's;
#    macOS not following: the one step at the lift; the Dock swipe's events as
#    macOS 26 and 27 read them (swipe-take.h, test-escape.c); only the finger counts the
#    guest switches workspaces with ("G", Hyprland's gestures: 4 fingers with 3 given to
#    tiling), four fingers coming down one after the other are no pinch. "X left|right" from a
#    guest of 3.1.0-3.1.5 still moves in one step. The guest says "E" at once and on
#    every workspace change from Hyprland's event socket (test-swipe-out.py, a
#    made-up Hyprland), or decides at the lift for an older Mac; the lines go over
#    the real connection (2b).
# 6. Scroll momentum takes only a trackpad's scrolling (built-in or Magic
#    Trackpad, also one connected later): wheel mice, smooth-scrolling mice and
#    a Magic Mouse go to the VM app one to one (test-scroll.c, made-up events
#    and trackpad frames through the real callbacks).
# 7. A Magic Mouse in the captured VM: two fingers sideways = a workspace swipe
#    (four virtual fingers, or three with MouseSwipeFingers 3, read at each
#    swipe's start; anything else four), macOS's scroll for them dropped; one finger
#    flicked sideways = Back/Forward; a resting finger and scrolling = nothing
#    extra (test-mouse.c, made-up Magic Mouse frames through the real callback).
# 8. Each Gestures takes only its own OmacVM app's VMs: the normal one
#    OmacVM.app's, the test identity's OmacVM Test.app's, both a development
#    build's QEMU; the combo in the other app's VM is passed on (test-identity.c).
# 9. A permission missing at start: the helper clears its own entry for it,
#    once per build (one macOS kept for another build's signature), never one
#    it has (#306, test-tcc.c).
# 10. The wait for the permissions at start runs on the run loop: a grant given
#    while it waits makes the tap and starts the listener without a restart;
#    when only a new process gets it, the helper starts again, once (#330,
#    test-wait.c).
# 11. A trackpad or Magic Mouse whose device macOS made anew (a wake from deep
#    sleep; connected again) is taken, from the next look or 1 s after macOS
#    adds it, and the old one let go and not held; the same device listed again
#    is not; beside a Magic Trackpad touched last, the built-in one's new device
#    does not take over, so the guest hears its size when it is touched next
#    (test-trackpads.c, made-up devices).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
# A process and what it started (the guest runs python3 in a subshell).
killtree() { local p; for p in "$@"; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done; }
# Its own settings domain per run: two runs at once on one Mac (CI) keep apart.
MOUSE_DOMAIN=org.omacvm.test.mouse-fingers.$$
SHARE_DOMAIN=org.omacvm.test.share-keyboard.$$
trap 'killtree ${PIDS:-}; rm -rf "$T"; defaults delete "$MOUSE_DOMAIN" >/dev/null 2>&1 || true; defaults delete "$SHARE_DOMAIN" >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/$SHARE_DOMAIN.plist"' EXIT
trap 'exit 130' INT TERM
clang -O1 -Wall -Wno-unused-function -o "$T/test-gestures" "$HERE/test-gestures.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
# One token, as the Mac's Bridge and the guests share it.
TOKEN=$(openssl rand -hex 24)
mkdir -p "$T/mac/Library/Application Support/omacvm-bridge" "$T/vm"
echo "$TOKEN" > "$T/mac/Library/Application Support/omacvm-bridge/token"
echo "$TOKEN" > "$T/vm/token"
# The guest daemon, loaded with stand-ins for what a Mac lacks: evdev, the VM's
# routing table (the file $T/gw), and its addresses (both Mac addresses reach
# the test's listener on 127.0.0.1). once: one run(); loop: serve(), main()'s loop.
cat > "$T/guest.py" <<'PY'
import importlib.machinery, importlib.util, itertools, socket, sys, threading, time, types
# Apple's python3 (3.9) on macOS has no name for TCP_KEEPALIVE (netinet/tcp.h: 0x10).
if sys.platform == "darwin" and not hasattr(socket, "TCP_KEEPALIVE"):
    socket.TCP_KEEPALIVE = 0x10
n = itertools.count(1)
class Any(int):
    def __getattr__(self, name): return Any(next(n))
    def __call__(self, *a, **k): return Any(next(n))
ev = types.ModuleType("evdev")
ev.__getattr__ = lambda name: Any(next(n))
sys.modules["evdev"] = ev
import os, struct
src, token, gw, mode, port = sys.argv[1:6]
loader = importlib.machinery.SourceFileLoader("g", src)
spec = importlib.util.spec_from_loader("g", loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)
g.bridge_token = lambda: open(token).read().strip()   # the VM user's token file
g.default_gateway = lambda: open(gw).read().strip()
real = socket.create_connection
conns = []
def connect(addr, *a, **k):
    print(f"guest: connect {addr[0]}", flush=True)
    conns.append(real(("127.0.0.1", int(port)), *a, **k))
    return conns[-1]
g.socket.create_connection = connect
setka = g.keepalive
def keepalive(s):
    setka(s)
    idle = getattr(socket, "TCP_KEEPIDLE", None) or socket.TCP_KEEPALIVE
    print("guest: keepalive", s.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE) != 0,
          s.getsockopt(socket.IPPROTO_TCP, idle), s.getsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL),
          s.getsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT), flush=True)
g.keepalive = keepalive
class Stub:
    pending = held = None
    touch = types.SimpleNamespace(down=False)
    def __getattr__(self, name): return lambda *a, **k: None
if mode == "swipe":
    # Swipe out: once the Mac says "X on 2", where swipes go ("E", as the
    # daemon's watcher says it), and a swipe past the first workspace the way
    # daemons from 3.1.0-3.1.5 say it ("X left").
    real_set = g.SWIPE.set
    def set_(on, version=1):
        real_set(on, version)
        print(f"guest: swipe out {'on' if on else 'off'} {version}", flush=True)
        if on:
            g.SWIPE.send(b"G 4lr\n")
            g.SWIPE.send(b"E right left\n")
            g.SWIPE.send(b"X left\n")
    g.SWIPE.set = set_
    g.hypr_socket = lambda: None   # no Hyprland here: the watcher has nothing to say
# once: one run() for 1.5 s, then the process ends (its connection closes);
# reset: the same, reset (RST) once connected; hold, swipe: until the Mac closes it.
if mode in ("once", "reset", "hold", "swipe"):
    t = threading.Thread(target=lambda: g.run(Stub(), Stub(), Stub()), daemon=True)
    t.start()
    if mode == "reset":
        g.CONNECTED.wait(5); time.sleep(0.5)
        conns[-1].setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        os._exit(0)
    t.join(1.5 if mode == "once" else 20)
else:
    g.serve(Stub(), Stub(), Stub())   # main()'s own retry loop
PY
# mac OUT ITEM...: the helper's side (see test-gestures.c), at most 20 s.
mac() {
  local out=$1; shift
  rm -f "$T/port"
  HOME=$T/mac "$T/test-gestures" "$T/port" "$@" > "$out" 2>> "$T/err" &
  MAC=$!; PIDS="$MAC"
  ( sleep 20; kill "$MAC" 2>/dev/null ) &   # a guest that never connects must not hang the test
  for _ in $(seq 50); do [[ -s $T/port ]] && break; sleep 0.1; done
  PORT=$(cat "$T/port")
}
# guest NAME TYPE GATEWAY MODE [ENV...]: the guest daemon's handshake, as in the VM.
guest() {
  local name=$1 type=$2; echo "$3" > "$T/gw"
  env HOME="$T/vm" OMACVM_HOST=10.0.2.2 OMACVM_GESTURES_PORT="$PORT" OMACVM_VM_TYPE="$type" \
    OMACVM_VM_NAME_B64="$(printf '%s' "$name" | base64)" "${@:5}" \
    python3 "$T/guest.py" "$HERE/../guest/omacvm-gestures" "$T/vm/token" "$T/gw" "$4" "$PORT"
}
fail=0
expect() { if grep -qxF "$2" "$1"; then echo "ok   $2"; else echo "FAIL $2" >&2; fail=1; fi; }
reject() { if grep -qxF "$2" "$1"; then echo "FAIL not: $2" >&2; fail=1; else echo "ok   not: $2"; fi; }

# 1. Which VM gets them: an app VM on the fast network's listener, a UTM VM on UTM's
#    (both stay connected until the Mac side is done).
mac "$T/out" 4 1   # NET_APP_FAST, NET_UTM
guest "App VM" app "" hold OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest1" 2>&1 &
G1=$!; PIDS="$MAC $G1"
for _ in $(seq 100); do grep -q "^accepted 1" "$T/out" && break; sleep 0.1; done
guest "UTM VM" utm "" hold OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest2" 2>&1 &
G2=$!; PIDS="$MAC $G1 $G2"
wait "$MAC" || { cat "$T/err" "$T/guest1" "$T/guest2" >&2; exit 1; }
killtree "$G1" "$G2"; wait "$G1" "$G2" 2>/dev/null || true
expect "$T/out" "client App VM: app"
expect "$T/out" "client UTM VM: utm"
expect "$T/out" "UTM in front, title Windows: UTM VM"   # no name match: every UTM VM, never the app VM
expect "$T/out" "UTM in front, title UTM VM: UTM VM"
expect "$T/out" "app in front, title App VM: App VM"
expect "$T/out" "app in front, title App VM, app VM gone:"

# The VM's default gateway: the card whose link is up, lowest metric (the
# vmnet card's route, link just taken down, is still listed first).
mkdir -p "$T/sys/enp0s2" "$T/sys/enp1s0"
echo 0 > "$T/sys/enp0s2/carrier"; echo 1 > "$T/sys/enp1s0/carrier"
printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n%s\n%s\n%s\n' \
  "enp0s2	00000000	014DA8C0	0003	0	0	100	00000000" \
  "enp0s2	004DA8C0	00000000	0001	0	0	100	00FFFFFF" \
  "enp1s0	00000000	0202000A	0003	0	0	101	00000000" > "$T/route"
gw() {
  python3 - "$HERE/../guest/omacvm-gestures" "$T/route" "$T/sys" <<'PY'
import importlib.machinery, importlib.util, itertools, sys, types
n = itertools.count(1)
class Any(int):
    def __getattr__(self, name): return Any(next(n))
    def __call__(self, *a, **k): return Any(next(n))
ev = types.ModuleType("evdev")
ev.__getattr__ = lambda name: Any(next(n))
sys.modules["evdev"] = ev
loader = importlib.machinery.SourceFileLoader("g", sys.argv[1])
g = importlib.util.module_from_spec(importlib.util.spec_from_loader("g", loader))
loader.exec_module(g)
g.ROUTES, g.SYS_NET = sys.argv[2], sys.argv[3]
print(g.default_gateway())
PY
}
[[ $(gw) == 10.0.2.2 ]] && echo "ok   gateway: the card with a link (user network) over the vmnet card just taken down" ||
  { echo "FAIL gateway: $(gw)" >&2; fail=1; }
echo 1 > "$T/sys/enp0s2/carrier"
[[ $(gw) == 192.168.77.1 ]] && echo "ok   gateway: both cards up, the lower metric (fast network)" || { echo "FAIL gateway: $(gw)" >&2; fail=1; }
# The Bridge client and the guest check pick it the same way (their
# default_gateway(), with `ip` showing the same table).
mkdir -p "$T/bin"
cat > "$T/bin/ip" <<'SH'
#!/bin/sh
echo "default via 192.168.77.1 dev enp0s2 proto dhcp src 192.168.77.2 metric 100"
echo "default via 10.0.2.2 dev enp1s0 proto dhcp src 10.0.2.15 metric 101"
SH
chmod +x "$T/bin/ip"
for f in "$HERE/../../bridge/guest/omacvm-bridge" "$HERE/../../guest/check.sh"; do
  fn=$(sed -n '/^default_gateway() {/,/^}/p' "$f")
  bgw() { PATH="$T/bin:$PATH" bash -c "SYS_NET='$T/sys'; $fn"'
default_gateway'; }
  echo 0 > "$T/sys/enp0s2/carrier"; a=$(bgw)
  echo 1 > "$T/sys/enp0s2/carrier"; b=$(bgw)
  if [[ $a == 10.0.2.2 && $b == 192.168.77.1 ]]; then echo "ok   gateway: $(basename "$f") picks it the same way"
  else echo "FAIL gateway in $(basename "$f"): $a / $b" >&2; fail=1; fi
done

# 2. The fast network as in the VM, then the move to the user network.
mac "$T/out2" 4,192.168.77.1,192.168.77.2 3   # first on 192.168.77.1 from the VM's lease, then via 127.0.0.1
guest "App VM" app 192.168.77.1 loop > "$T/guest3" 2>&1 &
GUEST=$!; PIDS="$MAC $GUEST"
for _ in $(seq 100); do grep -q "^accepted 1" "$T/out2" && break; sleep 0.1; done
expect "$T/out2" "accepted 1"
grep -q "connected to 192.168.77.1:" "$T/guest3" && grep -q "guest connected: 192.168.77.2 .*on its fast network" "$T/out2" &&
  echo "ok   both proofs named 192.168.77.1: the Mac took it as the app's fast network" ||
  { echo "FAIL the handshake on 192.168.77.1" >&2; fail=1; }
expect "$T/guest3" "guest: connect 192.168.77.1"
expect "$T/guest3" "guest: keepalive True 5 2 3"
t0=$(date +%s)
echo 10.0.2.2 > "$T/gw"   # the app moved the VM: its default gateway changed
wait "$MAC" || true
took=$(( $(date +%s) - t0 ))
killtree "$GUEST"; wait "$GUEST" 2>/dev/null || true
expect "$T/guest3" "guest: connect 10.0.2.2"
expect "$T/out2" "accepted 2"
if (( took <= 4 )); then echo "ok   connected again ${took} s after the switch"; else echo "FAIL connected again only after ${took} s" >&2; fail=1; fi
expect "$T/out2" "live App VM 127.0.0.1"         # one connection: the old one was dropped
reject "$T/out2" "live App VM 192.168.77.2"
# 2c. The guest's connection ends: closed by the VM (it stopped), or reset (keepalive
#     while the Mac slept): dropped at once and said so, not kept until a send fails.
TEST_WAIT_GONE=1 mac "$T/out6" 3
guest "App VM" app "" once OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest6" 2>&1 || true
wait "$MAC" || true
expect "$T/out6" "accepted 1"
grep -q "guest disconnected: 127.0.0.1 (closed by the VM)" "$T/out6" && echo "ok   a connection the VM closed: dropped and logged" ||
  { echo "FAIL a connection the VM closed: not logged" >&2; fail=1; }
reject "$T/out6" "live App VM 127.0.0.1"
TEST_WAIT_GONE=1 mac "$T/out7" 3
guest "App VM" app "" reset OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest7" 2>&1 || true
wait "$MAC" || true
grep -q "guest disconnected: 127.0.0.1 (connection reset)" "$T/out7" && echo "ok   a connection reset: dropped and logged" ||
  { echo "FAIL a connection reset: not logged" >&2; cat "$T/out7" >&2; fail=1; }
reject "$T/out7" "live App VM 127.0.0.1"
# 2b. Swipe out to macOS (#342): with it on the guest hears "X on 2" with the Mac's
#     hello; where its swipes go ("E") is kept with its connection, and its "X left"
#     (daemons 3.1.0-3.1.5) is read and acted on by the Mac (no VM in front here:
#     ignored, and said so); with it off the guest never hears "X on".
TEST_SWIPE_OUT=1 mac "$T/out4" 3
guest "App VM" app "" swipe OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest4" 2>&1 || true
wait "$MAC" || true
expect "$T/guest4" "guest: swipe out on 2"
grep -q 'swipe out to the left from "App VM": its VM is not the one in front: ignored' "$T/out4" &&
  echo "ok   swipe out: the guest's X left reached the Mac over its connection (and was checked)" ||
  { echo "FAIL swipe out: the Mac did not read the guest's X left" >&2; cat "$T/out4" >&2; fail=1; }
expect "$T/out4" "edges App VM 1 -1 ways 10 10"   # its "E right left" and "G 4lr", kept with its connection
# ... the same on the other three routes (each on its own network's address).
for r in "parallels 0 10.211.55.2" "utm 1 192.168.64.1" "fusion 2 172.16.5.1"; do
  set -- $r
  TEST_SWIPE_OUT=1 mac "$T/out-$1" "$2,$3"
  guest "$1 VM" "$1" "" swipe OMACVM_HOST="$3" > "$T/guest-$1" 2>&1 || true
  wait "$MAC" || true
  expect "$T/guest-$1" "guest: swipe out on 2"
  expect "$T/out-$1" "edges $1 VM 1 -1 ways 10 10"
done
mac "$T/out5" 3
guest "App VM" app "" swipe OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest5" 2>&1 || true
wait "$MAC" || true
reject "$T/guest5" "guest: swipe out on"
# 4. The event tap after a VM app (re)starts; its place with shareKeyboard (a throwaway domain).
clang -O1 -Wall -Wno-unused-function "-DSHARE_KEYBOARD_DOMAIN=CFSTR(\"$SHARE_DOMAIN\")" -o "$T/test-tap" "$HERE/test-tap.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-tap" > "$T/tap" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/tap"
n=$(grep -c "cannot create the event tap again" "$T/tap" || true)
if [[ $n == 1 ]]; then echo "ok   a failed re-creation is logged once (two tries)"; else echo "FAIL logged $n times" >&2; fail=1; fi
# 5. The escape combo's way out and back.
clang -O1 -Wall -Wno-unused-function -o "$T/test-escape" "$HERE/test-escape.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-escape" > "$T/escape" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/escape"
REPO=$(cd "$HERE/../../.." && pwd)
m_gest=$(sed -n 's/^#define OMACVM_KEY_MARKER \(0x[0-9A-Fa-f]*\).*/\1/p' "$HERE/omacvm-gestures.c")
m_bridge=$(sed -n 's/.*static let marker: Int64 = \(0x[0-9A-Fa-f_]*\).*/\1/p' "$REPO/src/bridge/mac/vm-keys.swift" | tr -d _)
m_qemu=$(sed -n 's/^+#define OMACVM_MAC_KEY_MARKER \(0x[0-9A-Fa-f]*\).*/\1/p' "$REPO/app/runtime/patches/omacvm-cocoa-keys-for-macos.patch")
if [[ -n $m_gest && $(( m_gest )) == $(( m_bridge )) && $(( m_gest )) == $(( m_qemu )) ]]; then
  echo "ok   one key marker in Gestures, the Bridge and QEMU's patch ($m_gest)"
else
  echo "FAIL key markers differ: Gestures '$m_gest', Bridge '$m_bridge', QEMU '$m_qemu'" >&2; fail=1
fi
# The guest's notice for "S esc <keys>": none, but the old combo names the new one once per VM.
python3 "$HERE/../guest/test-escape-notice.py" "$HERE/../guest/omacvm-gestures" > "$T/notice" 2>&1 || fail=1
grep -E '^(ok|FAIL|skip) ' "$T/notice"
# Swipe out to macOS in the guest, against a made-up Hyprland (#342).
python3 "$HERE/../guest/test-swipe-out.py" "$HERE/../guest/omacvm-gestures" > "$T/swipe-out" 2>&1 || fail=1
grep -E '^(ok|FAIL|skip) ' "$T/swipe-out"
# The escape combo's question: Hyprland's focused output, where it sits on the Mac.
python3 "$HERE/../guest/test-focus.py" "$HERE/../guest/omacvm-gestures" > "$T/focus" 2>&1 || fail=1
grep -E '^(ok|FAIL|skip) ' "$T/focus"
# The guest's reconnects without the Mac's helper: 2 s, then 10 s, one log line per outage.
python3 "$HERE/../guest/test-retry.py" "$HERE/../guest/omacvm-gestures" > "$T/retry" 2>&1 || fail=1
grep -E '^(ok|FAIL|skip) ' "$T/retry"
# ... and install.sh's gesture lines: only for a count with no sideways gesture yet.
bash "$HERE/../guest/test-install-gestures.sh" > "$T/install-gestures" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/install-gestures"
# The pointer at rest over a full-screen VM: 0.5 s looks with the rest tap, else 20 Hz (cursor-rest.h).
clang -O1 -Wall -o "$T/test-cursor-rest" "$HERE/test-cursor-rest.c" && "$T/test-cursor-rest" > "$T/cursor-rest" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/cursor-rest"
# 6. Which scrolling scroll momentum takes.
clang -O1 -Wall -Wno-unused-function -o "$T/test-scroll" "$HERE/test-scroll.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-scroll" > "$T/scroll" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/scroll"
# 7. The Magic Mouse's gestures (its setting in a throwaway domain, deleted after).
clang -O1 -Wall -Wno-unused-function "-DGESTURES_DOMAIN=CFSTR(\"$MOUSE_DOMAIN\")" -o "$T/test-mouse" "$HERE/test-mouse.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-mouse" > "$T/mouse" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/mouse"
# 8. Whose VM: this identity's app or the other one's.
clang -O1 -Wall -Wno-unused-function -o "$T/test-identity" "$HERE/test-identity.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-identity" > "$T/identity" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/identity"
# 9. Permission entries macOS kept for another build: cleared once per build, only the missing ones (#306).
clang -O1 -Wall -Wno-unused-function -o "$T/test-tcc" "$HERE/test-tcc.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-tcc" > "$T/tcc" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/tcc"
# 10. The wait for the permissions at start: on the run loop, a grant seen without a restart; a new process
#     that may while this one may not: started again once, through its LaunchAgent or open (#330).
clang -O1 -Wall -Wno-unused-function -o "$T/test-wait" "$HERE/test-wait.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-wait" > "$T/wait" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/wait"
# 11. Devices macOS made anew: a wake from deep sleep makes the built-in trackpad's.
clang -O1 -Wall -Wno-unused-function -o "$T/test-trackpads" "$HERE/test-trackpads.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-trackpads" > "$T/trackpads" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/trackpads"
n=$(grep -c "trackpad: built-in again, 124 x 76 mm" "$T/trackpads" || true)
if [[ $n == 7 ]]; then echo "ok   each new device for the trackpad is logged (trackpad: built-in again)"; else echo "FAIL logged $n times, want 7" >&2; fail=1; fi
n=$(grep -c "MultitouchSupport did not start the built-in trackpad (0xe00002d6)" "$T/trackpads" || true)
if [[ $n == 1 ]]; then echo "ok   a start that failed is logged"; else echo "FAIL a failed start logged $n times, want 1" >&2; fail=1; fi
(( fail == 0 )) || { cat "$T/out" "$T/out2" "$T/err" "$T/guest3" "$T/identity" >&2; exit 1; }
