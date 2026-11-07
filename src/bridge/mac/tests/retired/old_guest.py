#!/usr/bin/env python3
"""A VM on a retired route keeps its OmacVM 3.3: its own guest clients (byte
copies of v3.3.0's in guest-3.3.0/) against the 3.4.0 Bridge's answer on that
route's address (retired.swift, through the harness in main.swift):
  - the control centre (bridge.py) gets the move text for hello, status and
    an update job, as a refusal it shows ("The Mac: <text>"), and no job runs;
  - the bar's client (omacvm-bridge) gets the text, no data;
  - the event service (omacvm-bridge-events) opens one stream and keeps it:
    no new stream every 3 s, no log line per try, its readers get the text.
Usage: old_guest.py HARNESS   (src/bridge/mac/test-retired.sh builds it)
"""
import importlib.machinery
import importlib.util
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HARNESS = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
OLD = os.path.join(HERE, "guest-3.3.0")
TEXT = ("This VM runs on a retired route (Parallels/UTM/VMware Fusion). OmacVM 3.4.0 supports OmacVM.app only: "
        "create a new VM in OmacVM.app and copy your files.")
HOLD = float(os.environ.get("RETIRED_HOLD", "32"))   # past the old event service's 20 s silence limit

failed = 0


def check(ok, what):
    global failed
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    failed += 0 if ok else 1


tmp = tempfile.mkdtemp(prefix="rt")
procs = []


def cleanup():
    for p in procs:
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except OSError:
            pass
    for p in procs:
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
    shutil.rmtree(tmp, ignore_errors=True)


def serve():
    """A harness of its own (its own accept count), its port."""
    n = len(procs)
    port_file, log = os.path.join(tmp, f"port{n}"), os.path.join(tmp, f"accepts{n}")
    open(log, "w").close()
    procs.append(subprocess.Popen([HARNESS, "serve", token_file, port_file, log], start_new_session=True))
    for _ in range(100):
        if os.path.exists(port_file) and open(port_file).read().strip():
            return int(open(port_file).read()), log
        time.sleep(0.05)
    raise SystemExit("the harness did not start")


def accepts(log):
    return sum(1 for _ in open(log))


try:
    token_file = os.path.join(tmp, "token")
    with open(token_file, "w") as f:
        f.write(secrets.token_hex(32) + "\n")
    key_file = os.path.join(tmp, "vm-key")
    with open(key_file, "w") as f:
        f.write(secrets.token_hex(32) + "\n")
    os.environ["OMACVM_VM_KEY_FILE"] = key_file

    # ---- the control centre ----
    port, log = serve()
    url = f"http://127.0.0.1:{port}"
    loader = importlib.machinery.SourceFileLoader("old_bridge", os.path.join(OLD, "bridge.py"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    old = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = old   # its dataclasses look themselves up there
    loader.exec_module(old)
    b = old.Bridge({"OMACVM_HOST": "127.0.0.1"}, "3.3.0", token_file=token_file, url=url)
    for name, call in [("hello", b.hello), ("status", b.status), ("an update job", lambda: b.start_job("update")),
                       ("a feature job", lambda: b.start_job("enable", ["gestures"]))]:
        try:
            got = call()
            check(False, f"control centre, {name}: refused (it answered {got!r})")
        except old.BridgeError as e:
            # tui.py (3.3.0) shows a refusal as "The Mac: <message>".
            check(e.kind == "refused" and str(e) == TEXT and e.status == 410,
                  f"control centre, {name}: 'The Mac: {str(e)[:60]}...' ({e.kind}, {e.status})")

    # ---- the bar's client ----
    env = dict(os.environ, OMACVM_BRIDGE_URL=url, OMACVM_BRIDGE_TOKEN_FILE=token_file, HOME=tmp)
    r = subprocess.run([os.path.join(OLD, "omacvm-bridge"), "state"], env=env, capture_output=True, text=True, timeout=30)
    check(r.returncode != 0 and TEXT in r.stdout + r.stderr, f"omacvm-bridge state: the text, exit {r.returncode}")

    # ---- the event service and a reader ----
    port, log = serve()
    url = f"http://127.0.0.1:{port}"
    sock = os.path.join(tmp, "ev.sock")
    env = dict(env, OMACVM_BRIDGE_URL=url, OMACVM_BRIDGE_EVENTS_SOCKET=sock,
               OMACVM_BRIDGE_CLIENT=os.path.join(OLD, "omacvm-bridge"))
    ev_log = os.path.join(tmp, "events.log")
    with open(ev_log, "w") as out:
        procs.append(subprocess.Popen([sys.executable, os.path.join(OLD, "omacvm-bridge-events")], env=env, stdout=out,
                                      stderr=subprocess.STDOUT, start_new_session=True))
    for _ in range(100):
        if os.path.exists(sock):
            break
        time.sleep(0.05)
    reader_out = os.path.join(tmp, "reader.out")
    with open(reader_out, "w") as out:
        procs.append(subprocess.Popen([os.path.join(OLD, "omacvm-bridge"), "events"], env=env, stdout=out,
                                      stderr=subprocess.STDOUT, start_new_session=True))
    t0 = time.monotonic()
    time.sleep(HOLD)
    seen = open(reader_out, encoding="utf-8", errors="replace").read()
    lines = open(ev_log, encoding="utf-8", errors="replace").read().splitlines()
    n = accepts(log)
    print(f"     {HOLD:.0f} s: {n} connections to the Bridge, event service log: {lines}", flush=True)
    check(n == 2, f"event service: one proof and one stream in {time.monotonic() - t0:.0f} s, no new one every 3 s ({n} connections)")
    check(sum("connecting" in l for l in lines) == 1 and not any("no answer" in l or "silent" in l for l in lines),
          "event service: one 'connecting' line, the stream held (no 'no answer', no 'silent for 20 s')")
    check(len(lines) <= 4, f"event service: {len(lines)} log lines, no line per try")
    check(f": {TEXT}" in seen, "the bar's reader gets the text (an SSE comment)")
    check(": ping" in seen, "...and the pings that keep the stream alive")
finally:
    cleanup()

print(f"retired (3.3.0 guest clients): {'all ok' if not failed else f'{failed} failed'}")
sys.exit(1 if failed else 0)
