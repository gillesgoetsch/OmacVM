#!/bin/bash
# Offline test (no VM, no permissions) of the Mac helper's own handshake and
# choice (test-gestures.c) against the guest daemon's own run() (omacvm-gestures):
# 1. An OmacVM.app VM on its fast network (192.168.77.1) counts as the app's,
#    never UTM's, and a UTM VM never as the app's.
# 2. An app VM on the fast network as in the VM: the gateway is 192.168.77.1,
#    so it connects there and both proofs name 192.168.77.1. Then the app moves
#    it to the user network (the gateway becomes 10.0.2.2): it connects again
#    within seconds, on keepalive, and the Mac drops its old connection.
# 3. The default gateway: the card with a link, lowest metric, the same in
#    Gestures, the Bridge client and the guest check.
# 4. The event tap is created again when another OmacVM VM (a new QEMU, whose
#    own tap sits ahead of ours) comes to the front, and when macOS invalidated
#    it; a failed re-creation keeps the old tap and is logged once (test-tap.c).
# 5. Ctrl+Option+Esc (and the old Ctrl+Option+Cmd+Esc, exact modifiers only): in the VM the display under the pointer moves out
#    with macOS's own Space shortcut as the user set it (or every display
#    with "all"), toward the Space it came from; in macOS back in; not moved
#    or the shortcut off -> a Dock swipe; still not moved, or no Spaces
#    information -> a notice in Omarchy, nothing else (never Mission
#    Control); never out of full screen, never hidden; the keyboard follows the pointer's display; pressed in
#    Mission Control (after the double press) it closes it and goes back into the VM; the posted key's
#    shape and marker (test-escape.c, a made-up world of displays and Spaces:
#    nothing posted, swiped or activated). The marker is the same in
#    Gestures, the Bridge and QEMU's patch. The guest names the combo pressed,
#    and after the old one the new one, once per VM, and the no-way-out notice (test-escape-notice.py).
# 6. Scroll momentum takes only a trackpad's scrolling (built-in or Magic
#    Trackpad, also one connected later): wheel mice, smooth-scrolling mice and
#    a Magic Mouse go to the VM app one to one (test-scroll.c, made-up events
#    and trackpad frames through the real callbacks).
# 7. A Magic Mouse in the captured VM: two fingers sideways = a workspace swipe
#    (four virtual fingers, or three with MouseSwipeFingers 3, read at each
#    swipe's start; anything else four), macOS's scroll for them dropped; one finger
#    flicked sideways = Back/Forward; a resting finger and scrolling = nothing
#    extra (test-mouse.c, made-up Magic Mouse frames through the real callback).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
# A process and what it started (the guest runs python3 in a subshell).
killtree() { local p; for p in "$@"; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done; }
trap 'killtree ${PIDS:-}; rm -rf "$T"; defaults delete org.omacvm.test.mouse-fingers >/dev/null 2>&1 || true' EXIT
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
import importlib.machinery, importlib.util, itertools, socket, sys, threading, types
n = itertools.count(1)
class Any(int):
    def __getattr__(self, name): return Any(next(n))
    def __call__(self, *a, **k): return Any(next(n))
ev = types.ModuleType("evdev")
ev.__getattr__ = lambda name: Any(next(n))
sys.modules["evdev"] = ev
src, token, gw, mode, port = sys.argv[1:6]
loader = importlib.machinery.SourceFileLoader("g", src)
spec = importlib.util.spec_from_loader("g", loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)
g.bridge_token = lambda: open(token).read().strip()   # the VM user's token file
g.default_gateway = lambda: open(gw).read().strip()
real = socket.create_connection
def connect(addr, *a, **k):
    print(f"guest: connect {addr[0]}", flush=True)
    return real(("127.0.0.1", int(port)), *a, **k)
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
if mode == "once":
    t = threading.Thread(target=lambda: g.run(Stub(), Stub(), Stub()), daemon=True)
    t.start(); t.join(1.5)
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

# 1. Which VM gets them: an app VM on the fast network's listener, a UTM VM on UTM's.
mac "$T/out" 4 1   # NET_APP_FAST, NET_UTM
guest "App VM" app "" once OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest1" 2>&1 || true
guest "UTM VM" utm "" once OMACVM_GESTURES_HOST=127.0.0.1 > "$T/guest2" 2>&1 || true
wait "$MAC" || { cat "$T/err" "$T/guest1" "$T/guest2" >&2; exit 1; }
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
# 4. The event tap after a VM app (re)starts.
clang -O1 -Wall -Wno-unused-function -o "$T/test-tap" "$HERE/test-tap.c" "$HERE/scroll_ns.m" \
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
# The guest's notice for "S esc <keys>": the old combo names the new one once per VM.
python3 "$HERE/../guest/test-escape-notice.py" "$HERE/../guest/omacvm-gestures" > "$T/notice" 2>&1 || fail=1
grep -E '^(ok|FAIL|skip) ' "$T/notice"
# 6. Which scrolling scroll momentum takes.
clang -O1 -Wall -Wno-unused-function -o "$T/test-scroll" "$HERE/test-scroll.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-scroll" > "$T/scroll" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/scroll"
# 7. The Magic Mouse's gestures (its setting in a throwaway domain, deleted after).
clang -O1 -Wall -Wno-unused-function -o "$T/test-mouse" "$HERE/test-mouse.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit -framework IOKit
"$T/test-mouse" > "$T/mouse" 2>&1 || fail=1
grep -E '^(ok|FAIL) ' "$T/mouse"
(( fail == 0 )) || { cat "$T/out" "$T/out2" "$T/err" "$T/guest3" >&2; exit 1; }
