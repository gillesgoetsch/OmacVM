#!/bin/bash
# Offline test (no VM, no permissions) of the Mac helper's own handshake and
# choice (test-gestures.c) against the guest daemon's own run() (omacvm-gestures):
# 1. An OmacVM.app VM on its fast network (192.168.77.1) counts as the app's,
#    never UTM's, and a UTM VM never as the app's.
# 2. An app VM on the fast network as in the VM: the gateway is 192.168.77.1,
#    so it connects there and both proofs name 192.168.77.1. Then the app moves
#    it to the user network (the gateway becomes 10.0.2.2): it connects again
#    within seconds, on keepalive, and the Mac drops its old connection.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'kill ${PIDS:-} 2>/dev/null || true; rm -rf "$T"' EXIT
clang -O1 -Wall -Wno-unused-function -o "$T/test-gestures" "$HERE/test-gestures.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit
# One token, as the Mac's Bridge and the guests share it.
TOKEN=$(openssl rand -hex 24)
mkdir -p "$T/mac/Library/Application Support/omacvm-bridge" "$T/vm"
echo "$TOKEN" > "$T/mac/Library/Application Support/omacvm-bridge/token"
echo "$TOKEN" > "$T/vm/token"
# The guest daemon, loaded with stand-ins for what a Mac lacks: evdev, the VM's
# routing table (the file $T/gw), and its addresses (both Mac addresses reach
# the test's listener on 127.0.0.1). once: one run(); loop: as main() runs it.
cat > "$T/guest.py" <<'PY'
import importlib.machinery, importlib.util, itertools, socket, sys, threading, time, types
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
def loop():
    while True:
        try:
            g.run(Stub(), Stub(), Stub())
        except (OSError, ConnectionError) as err:
            print(f"guest: {err}", flush=True)
            if not isinstance(err, g.Moved): time.sleep(2)
if mode == "once":
    t = threading.Thread(target=lambda: g.run(Stub(), Stub(), Stub()), daemon=True)
    t.start(); t.join(1.5)
else:
    loop()
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
kill "$GUEST" 2>/dev/null; wait "$GUEST" 2>/dev/null || true
expect "$T/guest3" "guest: connect 10.0.2.2"
expect "$T/out2" "accepted 2"
if (( took <= 4 )); then echo "ok   connected again ${took} s after the switch"; else echo "FAIL connected again only after ${took} s" >&2; fail=1; fi
expect "$T/out2" "live App VM 127.0.0.1"         # one connection: the old one was dropped
reject "$T/out2" "live App VM 192.168.77.2"
(( fail == 0 )) || { cat "$T/out" "$T/out2" "$T/err" "$T/guest3" >&2; exit 1; }
