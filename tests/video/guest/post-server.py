#!/usr/bin/env python3
"""Guest side of the video tests: serve the test page, append its POSTs to OUT as JSON lines.
Usage: post-server.py PAGE.html OUT.jsonl [PORT]"""
import http.server, json, sys, time

page, out = sys.argv[1:3]
port = int(sys.argv[3]) if len(sys.argv) > 3 else 8766


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = open(page, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        rec = json.loads(self.rfile.read(n) or b"{}")
        rec["kind"] = self.path.strip("/")
        rec["wall"] = time.time()
        with open(out, "a") as f:
            f.write(json.dumps(rec) + "\n")
        self.send_response(204)
        self.end_headers()


http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
