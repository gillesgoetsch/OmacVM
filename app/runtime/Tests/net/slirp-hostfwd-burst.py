#!/usr/bin/env python3
"""Two connections at the same moment to a host forward of a real QEMU's
-netdev user (libslirp): both must connect and stay connected.

No guest and no CPU: -machine none. libslirp accepts a connection to a host
forward on the Mac at once and then waits for the guest, which never answers,
so a connection that works connects and stays open and quiet. One that macOS
resets before libslirp accepts it shows ECONNRESET within the settle time.

Cases (--case):
  fixed  30 rounds of 2 connections at once: none is lost.
  reset  the same on a runtime without the fix: at least one is lost (proof
         that the test sees it; without the fix about half the rounds lose one).
"""
import argparse
import select
import socket
import subprocess
import sys
import time

ROUNDS = 30
CONNECT = 2.0
SETTLE = 0.3


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_listening(port, qemu, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if qemu.poll() is not None:
            raise RuntimeError("QEMU exited %d" % qemu.returncode)
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.05)
    raise TimeoutError("the host forward never listened")


def burst(port, n=2):
    """n connections started at once; how many of them do not stay connected."""
    socks = []
    for _ in range(n):
        s = socket.socket()
        s.setblocking(False)
        s.connect_ex(("127.0.0.1", port))
        socks.append(s)
    # A socket turns writable when its connect() ends, also when it fails.
    pending, deadline = set(socks), time.monotonic() + CONNECT
    while pending and time.monotonic() < deadline:
        _, done, _ = select.select([], list(pending), [], deadline - time.monotonic())
        pending -= set(done)
    time.sleep(SETTLE)
    lost = len(pending)
    for s in socks:
        if s in pending:
            s.close()
            continue
        err = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if not err:
            try:
                if s.recv(1) == b"":
                    err = -1  # closed
            except BlockingIOError:
                pass  # open and quiet: libslirp holds it for the guest
            except OSError as e:
                err = e.errno
        lost += bool(err)
        s.close()
    return lost


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qemu", required=True)
    ap.add_argument("--case", choices=("fixed", "reset"), required=True)
    args = ap.parse_args()

    port = free_port()
    qemu = subprocess.Popen(
        [args.qemu, "-machine", "none", "-nodefaults", "-display", "none", "-monitor", "none",
         "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:%d-:22" % port],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_listening(port, qemu)
        time.sleep(SETTLE)
        # QEMU exits when its host forward cannot bind, such as when another
        # process took the port after free_port() let it go.
        if qemu.poll() is not None:
            raise RuntimeError("QEMU exited %d" % qemu.returncode)
        lost = sum(burst(port) for _ in range(ROUNDS))
    finally:
        qemu.terminate()
        try:
            qemu.wait(10)
        except subprocess.TimeoutExpired:
            qemu.kill()

    print("%d of %d connections lost (%d rounds of 2 at once)" % (lost, 2 * ROUNDS, ROUNDS))
    ok = lost == 0 if args.case == "fixed" else lost > 0
    if not ok:
        print("FAIL: expected %s" % ("no loss" if args.case == "fixed" else "a loss"), file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
