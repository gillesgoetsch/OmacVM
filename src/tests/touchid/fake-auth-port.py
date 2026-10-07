#!/usr/bin/env python3
"""A fake OmacVM.app port (org.omacvm.auth) for src/tests/touchid-client.sh:
a Unix socket that does what the app's AuthRelay does - takes the client's
lines, posts the request to the (fake) Bridge with the token as the app adds
it, and sends the answer line back - and logs the client's lines.
  fake-auth-port.py DIR SOCKET BRIDGE_PORT
DIR/token: the Bridge token; DIR/port-mode: "" (relay), "stale" (an answer
for another id first), "status0" (the Bridge did not answer), "close" (the
app hangs up at once), "noack" (an app that never answers: a virtio port
with nobody at the Mac end takes the writes); DIR/port-ops: one line per client line (op id)."""
import base64, json, os, socket, sys, threading, time

D, SOCK, BRIDGE = sys.argv[1], sys.argv[2], int(sys.argv[3])
token = open(f"{D}/token").read().strip()


def mode():
    try:
        return open(f"{D}/port-mode").read().strip()
    except OSError:
        return ""


def post(r, state):
    """The request to the fake Bridge; dropped (shutdown) when the pings stop."""
    s = socket.create_connection(("127.0.0.1", BRIDGE))
    state["sock"] = s
    body = base64.b64decode(r["body"])
    head = (f"POST /omacvm/touchid HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {token}\r\n"
            f"X-OmacVM-Auth: {r['auth']}\r\nX-OmacVM-Proto: {r.get('proto', 1)}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode()
    s.sendall(head + body)
    data = b""
    try:
        while True:
            c = s.recv(65536)
            if not c:
                break
            data += c
    except OSError:
        return None
    if state.get("dropped"):
        return None
    h, _, b = data.partition(b"\r\n\r\n")
    lines = h.decode().split("\r\n")
    if not lines[0].startswith("HTTP/1."):
        return None
    hdr = {k.lower(): v.strip() for k, _, v in (l.partition(":") for l in lines[1:])}
    b = b[:int(hdr.get("content-length", len(b)))]
    return {"status": int(lines[0].split()[1]), "answer": hdr.get("x-omacvm-answer", ""), "body": base64.b64encode(b).decode()}


def serve(c):
    m = mode()
    if m == "close":
        c.close()
        return
    buf, state, lock = b"", {}, threading.Lock()

    def send(o):
        with lock:
            try:
                c.sendall(json.dumps(o).encode() + b"\n")
            except OSError:
                pass

    def watchdog():
        while not state.get("done"):
            time.sleep(0.1)
            if time.time() - state.get("ping", time.time()) > 1.5 or state.get("cancel"):
                state["dropped"] = True
                try:
                    state["sock"].shutdown(socket.SHUT_RDWR)
                except (KeyError, OSError):
                    pass
                return

    def job(r):
        if m == "stale":
            send({"id": "0" * 32, "status": 200, "answer": "x", "body": base64.b64encode(b'{"result":"yes"}\n').decode()})
            c.sendall(b"not json\n")
        a = {"status": 0} if m == "status0" else post(r, state)
        state["done"] = True
        if a is not None and not state.get("dropped"):
            send({"id": r["id"], **a})

    while True:
        try:
            chunk = c.recv(4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            o = json.loads(line)
            with open(f"{D}/port-ops", "a") as f:
                f.write(f"{o.get('op')} {o.get('id')}\n")
            if o.get("op") == "touchid":
                state["ping"] = time.time()
                if m == "noack":
                    continue   # nobody at the Mac end: no ack, no answer
                send({"ack": True, "id": o["id"]})
                threading.Thread(target=job, args=(o,), daemon=True).start()
                threading.Thread(target=watchdog, daemon=True).start()
            elif o.get("op") == "ping":
                state["ping"] = time.time()
            elif o.get("op") == "cancel":
                state["cancel"] = True
    state["cancel"] = True
    c.close()


s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    os.unlink(SOCK)
except OSError:
    pass
s.bind(SOCK)
s.listen(4)
open(f"{D}/port-ready", "w").close()
while True:
    conn, _ = s.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
