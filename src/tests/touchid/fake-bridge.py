#!/usr/bin/env python3
"""A fake OmacVM Bridge for src/tests/touchid-client.sh: /proof and
POST /omacvm/touchid as touchid.swift answers them, with the answer chosen
by the test (DIR/mode). Checks the request's signature like the Bridge.
  fake-bridge.py DIR [PORT]   (DIR/token, DIR/key; writes DIR/port, logs DIR/requests)
PORT: 47831 as a stand-in for the Mac's Bridge inside a test VM; default any;
a path: a Unix socket, as the Bridge's relay socket for OmacVM.app (writes DIR/port "unix")."""
import hashlib, hmac, http.server, json, os, socketserver, sys, time

D = sys.argv[1]
token = open(f"{D}/token", "rb").read().strip()
key = open(f"{D}/key", "rb").read().strip()


def mac(k, text):
    return hmac.new(k, text.encode(), hashlib.sha256).hexdigest()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj, sign=None):
        data = (json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if sign:
            k, nonce = sign
            self.send_header("X-OmacVM-Answer", mac(k, "\n".join(["omacvm-touchid-answer 1", nonce, str(code), hashlib.sha256(data).hexdigest()])))
        self.end_headers()
        self.wfile.write(data)

    def mode(self):
        try:
            return open(f"{D}/mode").read().strip()
        except OSError:
            return "yes"

    def do_GET(self):
        n = self.path.partition("nonce=")[2]
        knows = token if self.mode() != "wrong-proof" else b"x" * 64
        self.send(200, {"proof": mac(knows, f"omacvm-bridge mac 127.0.0.1 {n}")})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(f"{D}/requests", "a") as f:
            f.write(json.dumps({"time": time.time(), "path": self.path, "auth": self.headers.get("Authorization", ""), "body": body.decode()}) + "\n")
        if self.headers.get("Authorization") != "Bearer " + token.decode():
            return self.send(401, {"error": "token"})
        f = (self.headers.get("X-OmacVM-Auth") or "").split(" ")
        want = mac(key, "\n".join(["omacvm-touchid-request 1", "POST", self.path, f[1] if len(f) > 1 else "",
                                   f[2] if len(f) > 2 else "", self.headers.get("X-OmacVM-Proto", ""), hashlib.sha256(body).hexdigest()]))
        if len(f) != 4 or not hmac.compare_digest(want, f[3]) or abs(time.time() - int(f[1])) > 300:
            return self.send(403, {"error": "key", "code": "vm-key"})
        nonce, m = f[2], self.mode()
        if m == "yes":
            self.send(200, {"result": "yes"}, (key, nonce))
        elif m.startswith("no-"):
            self.send(200, {"result": "no", "reason": m[3:]}, (key, nonce))
        elif m == "unsigned":
            self.send(200, {"result": "yes"})
        elif m == "other-key":
            self.send(200, {"result": "yes"}, (b"o" * 64, nonce))
        elif m == "other-nonce":
            self.send(200, {"result": "yes"}, (key, "0" * 32))
        elif m == "off":   # as touchid.swift: no key for the VM, so not signed
            self.send(403, {"error": "Touch ID is off for this VM", "code": "off"})
        elif m == "off-other":   # unsigned, another code: says nothing
            self.send(403, {"error": "x", "code": "locked"})
        elif m == "clock":
            self.send(403, {"error": "clock", "code": "clock"}, (key, nonce))
        elif m == "drip":   # a "Bridge" that never finishes its answer
            self.send_response(200)
            self.send_header("Content-Length", "100000")
            self.end_headers()
            try:
                while True:
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.3)
            except OSError:
                pass
        elif m == "hang":   # a dialog nobody answers: waits until the client goes
            while not self.rfile.read(1) == b"":
                pass
            with open(f"{D}/closed", "w") as f:
                f.write("1")


class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):   # not HTTPServer's: its getfqdn() can take seconds (CI's macOS)
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if len(sys.argv) > 2 and sys.argv[2].startswith("/"):
    try:
        os.unlink(sys.argv[2])
    except OSError:
        pass
    s = UnixServer(sys.argv[2], H)
else:
    s = Server(("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 0), H)
with open(f"{D}/port.tmp", "w") as f:
    f.write(str(s.server_address[1]) if isinstance(s.server_address, tuple) else "unix")
os.replace(f"{D}/port.tmp", f"{D}/port")
s.serve_forever()
