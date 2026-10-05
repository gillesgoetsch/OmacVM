#!/bin/bash
# Offline test (no VM, no permissions): an OmacVM.app VM on the fast network
# comes in on UTM's address and must count as the app's, never UTM's. The
# Mac helper's own handshake and choice (test-gestures.c) against the guest
# daemon's own run() (omacvm-gestures), an app VM and a UTM VM.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'kill "${PID:-}" 2>/dev/null || true; rm -rf "$T"' EXIT
clang -O1 -Wall -Wno-unused-function -o "$T/test-gestures" "$HERE/test-gestures.c" "$HERE/scroll_ns.m" \
  -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework ApplicationServices -framework Carbon \
  -framework CoreFoundation -framework AppKit
# One token, as the Mac's Bridge and the guests share it.
TOKEN=$(openssl rand -hex 24)
mkdir -p "$T/mac/Library/Application Support/omacvm-bridge" "$T/vm"
echo "$TOKEN" > "$T/mac/Library/Application Support/omacvm-bridge/token"
echo "$TOKEN" > "$T/vm/token"
HOME=$T/mac "$T/test-gestures" "$T/port" 2 > "$T/out" 2> "$T/err" &
PID=$!
( sleep 20; kill "$PID" 2>/dev/null ) &   # a guest that never connects must not hang the test
for _ in $(seq 50); do [[ -s $T/port ]] && break; sleep 0.1; done
PORT=$(cat "$T/port")
# guest NAME TYPE: the guest daemon's handshake, as in the VM.
guest() {
  HOME=$T/vm OMACVM_GESTURES_HOST=127.0.0.1 OMACVM_GESTURES_PORT=$PORT OMACVM_VM_TYPE=$2 \
  OMACVM_VM_NAME_B64=$(printf '%s' "$1" | base64) python3 - "$HERE/../guest/omacvm-gestures" "$T/vm/token" <<'PY'
import importlib.machinery, importlib.util, itertools, sys, threading, types
# No evdev on a Mac: a stand-in (the handshake does not touch it).
n = itertools.count(1)
class Any(int):
    def __getattr__(self, name): return Any(next(n))
    def __call__(self, *a, **k): return Any(next(n))
ev = types.ModuleType("evdev")
ev.__getattr__ = lambda name: Any(next(n))
sys.modules["evdev"] = ev
loader = importlib.machinery.SourceFileLoader("g", sys.argv[1])
spec = importlib.util.spec_from_loader("g", loader)
g = importlib.util.module_from_spec(spec)
loader.exec_module(g)
g.bridge_token = lambda: open(sys.argv[2]).read().strip()   # the VM user's token file
class Stub:
    def __getattr__(self, name): return lambda *a, **k: None
t = threading.Thread(target=lambda: g.run(Stub(), Stub(), Stub()), daemon=True)
t.start(); t.join(1.5)
PY
}
guest "App VM" app > "$T/guest1" 2>&1 || true
guest "UTM VM" utm > "$T/guest2" 2>&1 || true
wait "$PID" || { cat "$T/err" "$T/guest1" "$T/guest2" >&2; exit 1; }
fail=0
expect() { if grep -qxF "$1" "$T/out"; then echo "ok   $1"; else echo "FAIL $1" >&2; fail=1; fi; }
expect "client App VM: app"
expect "client UTM VM: utm"
expect "UTM in front, title Windows: UTM VM"   # no name match: every UTM VM, never the app VM
expect "UTM in front, title UTM VM: UTM VM"
expect "app in front, title App VM: App VM"
expect "app in front, title App VM, app VM gone:"
(( fail == 0 )) || { cat "$T/out" "$T/err" >&2; exit 1; }
