"""A fake Mac for the control centre's tests: the Bridge's /proof and
/omacvm/* requests, and the VM's check socket. Same answers as the real ones
(src/bridge/mac/control.swift, guest/check.sh --tsv)."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import shutil
import socket
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from omacvm_cc.bridge import answer_mac, request_mac  # noqa: E402

TOKEN = b"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
VM_KEY = "5a" * 32
SRC = os.path.join(os.path.dirname(__file__), "..", "..")

CHECKS_TSV = (
    "section\tThe Mac in the bar (Bridge)\n"
    "ok\tWi-Fi\tZorroNet 5G, -48 dBm\t\tbridge\n"
    "ok\tgestures\tconnected to the Mac\t\tgestures\n"
    "fail\taudio\tno answer from the Bridge\t\tcamera\n"
    "ok\tzram swap\t4G\t\t\n"
)


class FakeMac:
    def __init__(self, old: bool = False, version: str = "2.7.0") -> None:
        self.old, self.version = old, version
        self.job_end = ("done", "done")   # (state, text) a job ends with
        self.job_extra: dict = {}         # more fields of the ended job (failed_part, mac_omacvm)
        self.job_polls_to_end = 2
        self.on_job_end = None            # called once with the job when it ends (a VM side that changed)
        self.requests: list[tuple[str, str, dict]] = []
        self.jobs: dict[str, dict] = {}
        self.checks_enabled = True
        self.manifest: dict | None = None
        self.checked_at = "2026-01-05T10:41:00Z"
        self.job_polls_fail = False       # the Mac stops answering about jobs
        self.refuse_jobs: tuple | None = None   # (status, code, error) for POST /omacvm/jobs
        self.headers_seen: list = []      # every request's headers and body, as sent
        self.signed: list = []            # (path, ok) for each /omacvm/ request but hello
        self.sign_answers = True          # False: an impostor that does not have the VM's key
        self.clock_skew = 0               # the fake Mac's clock minus the real one
        self.hello_delay = 0.0
        self.unknown_for = 0              # this many status requests get 409 unknown-vm (a VM just started)
        self.down_for = 0                 # this many hello requests get no answer (the Bridge restarting)
        self.refuse_jobs_for = 0          # this many job starts get 409 unknown-vm (the list caught the VM mid-job)
        self.stale_for = 0                # this many status requests get 403 vm-key, looking (an old VM list)
        self.stale_looking = True         # False: the Mac is not looking (a key that is really wrong)
        self.nonces: set = set()
        self.graphics: dict | None = None   # an OmacVM.app VM's Graphics (omacvm graphics --json)
        self.notch_area: dict | None = None  # an OmacVM.app VM's notch area (omacvm notch --json), with graphics
        self.gpu_memory: dict | None = None  # an OmacVM.app VM's graphics memory (None: an older Mac without it)
        self.gpu_memory_at: list[float] = []  # when each gpu-memory request came
        self.mouse_swipe: dict | None = None   # {"magic_mouse", "fingers"} (None: an older Mac without it)
        self.notch = False   # a MacBook with a notch: Omanotch can go on
        self.mac_app: bool | None = None  # the Mac's omacvm is OmacVM.app's copy (None: an older Mac says nothing)
        self.app_update: tuple | None = None  # (status, body) for POST /omacvm/app-update (None: an older Mac)
        self.refuse_theme: tuple | None = None   # (status, code, error) for POST /omacvm/theme (Touch ID off: 403 off)
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            nonce = ""

            def send(self, code, obj):
                b = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                if self.nonce and fake.sign_answers:
                    self.send_header("X-OmacVM-Answer", answer_mac(VM_KEY, self.nonce, code, b))
                self.end_headers()
                self.wfile.write(b)

            def raw_body(self) -> bytes:
                n = int(self.headers.get("Content-Length") or 0)
                return self.rfile.read(n) if n else b""

            def check_auth(self, raw: bytes) -> bool:
                """As verifyControlAuth: False when it answered a refusal."""
                fake.headers_seen.append((dict(self.headers.items()), raw))
                p = self.path
                if not p.startswith("/omacvm/") or p == "/omacvm/hello":
                    return True
                f = (self.headers.get("X-OmacVM-Auth") or "").split(" ")
                ok = len(f) == 4 and f[0] == "1" and f[1].lstrip("-").isdigit() and hmac.compare_digest(
                    request_mac(VM_KEY, self.command, p, int(f[1]), f[2], self.headers.get("X-OmacVM-Proto") or "", raw), f[3])
                fake.signed.append((p, ok))
                if ok and p == "/omacvm/status" and fake.stale_for > 0:
                    fake.stale_for -= 1
                    ok = False
                if not ok:
                    a = {"error": "this VM's control centre key does not match: omacvm apply on the Mac", "code": "vm-key"}
                    if fake.stale_looking and p == "/omacvm/status":
                        a = {"error": "this VM's key does not match the VM the Mac had at this address (the Mac is "
                                      "looking at its VMs again: try in a moment)", "code": "vm-key", "looking": True}
                    self.send(403, a)   # unsigned: the Mac cannot sign with a key that does not match
                    return False
                self.nonce = f[2]
                now = int(time.time()) + fake.clock_skew
                if abs(int(f[1]) - now) > 300:
                    self.send(403, {"error": "clock", "code": "clock", "mac_time": now})
                    return False
                if f[2] in fake.nonces:
                    self.send(403, {"error": "sent before", "code": "replay"})
                    return False
                fake.nonces.add(f[2])
                return True

            def do_GET(self):
                p = self.path
                if p.startswith("/proof?nonce="):
                    n = p.split("=", 1)[1]
                    return self.send(200, {"proof": hmac.new(TOKEN, f"omacvm-bridge mac 127.0.0.1 {n}".encode(),
                                                             hashlib.sha256).hexdigest()})
                if self.headers.get("Authorization") != "Bearer " + TOKEN.decode():
                    return self.send(401, {"error": "token"})
                if not self.check_auth(b""):
                    return
                fake.requests.append(("GET", p, {}))
                if fake.old and p.startswith("/omacvm/"):
                    return self.send(404, {"error": "not found"})
                if p == "/omacvm/hello" and fake.down_for > 0:
                    fake.down_for -= 1
                    self.close_connection = True   # no answer at all: the client sees the Mac away
                    return
                if p == "/omacvm/hello":
                    time.sleep(fake.hello_delay)
                    names = [l.split("\t")[0] for l in open(os.path.join(SRC, "features.tsv"), encoding="utf-8")
                             if l.strip() and not l.startswith("#")]
                    reqs = ["hello", "status", "updates", "jobs"] + (["gpu-memory"] if fake.gpu_memory is not None else []) \
                        + (["app-update"] if fake.app_update is not None else [])
                    reqs += ["settings/mouse-swipe"] if fake.mouse_swipe is not None else []
                    return self.send(200, {"proto": 1, "proto_min": 1, "omacvm": fake.version, "features": names,
                                           "requests": reqs, "macos": "15.7.4", "chip": "Apple M4 Max"})
                if p == "/omacvm/settings/mouse-swipe" and fake.mouse_swipe is not None:
                    return self.send(200, fake.mouse_swipe)
                if p == "/omacvm/gpu-memory" and fake.gpu_memory is not None:
                    fake.gpu_memory_at.append(time.monotonic())
                    return self.send(200, fake.gpu_memory)
                if p == "/omacvm/status" and fake.unknown_for > 0:
                    fake.unknown_for -= 1
                    return self.send(409, {"error": "no running VM that OmacVM set up has this address (the Mac is "
                                                    "looking at its VMs again: try in a moment)", "code": "unknown-vm"})
                if p == "/omacvm/status" and fake.graphics is not None:
                    st = {"omacvm": fake.version, "features": [], "checks": [], "graphics": fake.graphics}
                    if fake.notch_area is not None:
                        st["notch"] = fake.notch_area
                    return self.send(200, st)
                if p == "/omacvm/status":
                    return self.send(200, {"omacvm": fake.version, "features": [
                        {"name": "omanotch", "on": False, "available": fake.notch,
                         "reason": "" if fake.notch else "needs a MacBook with a notch"}],
                        "checks": [{"status": "fail", "name": "keyboard/trackpad access", "detail":
                                    "waiting for Accessibility: System Settings > Privacy & Security", "needs_human": True,
                                    "feature": "gestures"}]})
                if p == "/omacvm/updates":
                    return self.send(200, fake.updates())
                if p.startswith("/omacvm/jobs/"):
                    if fake.job_polls_fail:
                        return self.send(503, {"error": "restarting"})
                    j = fake.jobs.get(p.rsplit("/", 1)[1])
                    if not j:
                        return self.send(404, {"error": "no such job"})
                    j["polls"] += 1
                    j["step"], j["of"], j["text"] = 2, 4, "the VM side"
                    if j["polls"] >= fake.job_polls_to_end:
                        j["state"], j["text"] = fake.job_end
                        j.update(fake.job_extra)
                        if fake.on_job_end and not j.get("ended"):
                            j["ended"] = True
                            fake.on_job_end(j)
                    return self.send(200, {k: v for k, v in j.items() if k != "polls"})
                if p in ("/state", "/scan?cached=1", "/bluetooth"):
                    return self.send(200, {"ssid": "ZorroNet 5G", "bssid": "a4:2b:b0:11:22:33",
                                           "networks": [{"ssid": "Zorro Guest"}],
                                           "devices": [{"name": "Zorro's AirPods", "address": "11:22:33:44:55:66"}]})
                self.send(404, {"error": "not found"})

            def do_POST(self):
                if self.headers.get("Authorization") != "Bearer " + TOKEN.decode():
                    return self.send(401, {"error": "token"})
                raw = self.raw_body()
                if not self.check_auth(raw):
                    return
                b = json.loads(raw or b"{}")
                fake.requests.append(("POST", self.path, b))
                if self.path == "/omacvm/jobs" and fake.refuse_jobs_for > 0:
                    fake.refuse_jobs_for -= 1
                    return self.send(409, {"code": "unknown-vm", "error": "the Mac cannot reach this VM: SSH closed the connection"})
                if self.path == "/omacvm/jobs" and fake.refuse_jobs:
                    st, code, err = fake.refuse_jobs
                    return self.send(st, {"error": err, "code": code})
                if self.path == "/omacvm/jobs":
                    jid = f"{len(fake.jobs) + 1:016x}"
                    fake.jobs[jid] = {"id": jid, "action": b["action"],
                                      "features": b.get("features", [b["graphics"]] if "graphics" in b
                                                        else [b["notch"]] if "notch" in b else []),
                                      "state": "running", "step": 1, "of": 4, "text": "the Mac side",
                                      "lines": ["==> OmacVM Bridge on the Mac"], "polls": 0}
                    return self.send(202, {k: v for k, v in fake.jobs[jid].items() if k != "polls"})
                if self.path == "/omacvm/app-update" and fake.app_update is not None:
                    return self.send(*fake.app_update)
                if self.path == "/omacvm/settings/update-checks":
                    fake.checks_enabled = bool(b["enabled"])
                    return self.send(200, fake.updates())
                if self.path == "/omacvm/settings/mouse-swipe" and fake.mouse_swipe is not None:
                    if b.get("fingers") not in (3, 4) or set(b) != {"fingers"}:
                        return self.send(400, {"error": "send {\"fingers\": 3|4}", "code": "bad-body"})
                    fake.mouse_swipe = dict(fake.mouse_swipe, fingers=b["fingers"])
                    return self.send(200, fake.mouse_swipe)
                if self.path == "/omacvm/theme":   # the Touch ID panel's colours (touchid_theme.swift)
                    if fake.refuse_theme:
                        st, code, err = fake.refuse_theme
                        return self.send(st, {"error": err, "code": code})
                    return self.send(200, {"ok": True, "dark": True})
                if self.path == "/omacvm/updates/check":
                    fake.checked_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    return self.send(200, fake.updates())
                self.send(404, {"error": "not found"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def updates(self) -> dict:
        u = {"checks_enabled": self.checks_enabled, "omacvm": self.version, "checked_at": self.checked_at,
             "ok": self.manifest is not None, "offline": False, "error": None, "manifest": self.manifest}
        if self.mac_app is not None:
            u["mac_app"] = self.mac_app
        return u

    def stop(self) -> None:
        self.server.shutdown()


class FakeChecks:
    """/run/omacvm/check.sock: answers guest/check.sh --tsv lines and closes."""

    def __init__(self, tsv: str = CHECKS_TSV) -> None:
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "check.sock")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(self.path)
        self.sock.listen(4)
        self.tsv = tsv
        self.delay = 0.0   # seconds before each answer (guest/check.sh takes about 6 s in a real VM)

        def serve():
            while True:
                try:
                    c, _ = self.sock.accept()
                except OSError:
                    return
                time.sleep(self.delay)
                c.sendall(self.tsv.encode())
                c.close()
        threading.Thread(target=serve, daemon=True).start()

    def stop(self) -> None:
        self.sock.close()


def vm_env(tmp: str, mac_port: int, check_sock: str, extra: str = "") -> dict:
    """Environment variables pointing the control centre at the fakes."""
    env_file = os.path.join(tmp, "env")
    with open(env_file, "w") as f:
        f.write("OMACVM_VM_TYPE=parallels\nOMACVM_HOST=127.0.0.1\nOMACVM_USER=zorro\n"
                "OMACVM_FEATURE_bridge=on\nOMACVM_FEATURE_wallpaper=on\nOMACVM_FEATURE_gestures=off\n"
                "OMACVM_FEATURE_scroll_momentum=off\nOMACVM_FEATURE_omanotch=off\nOMACVM_FEATURE_mac_clock=on\n"
                "OMACVM_FEATURE_camera=on\nOMACVM_FEATURE_battery=off\nOMACVM_FEATURE_no_idle_lock=off\n"
                "OMACVM_FEATURE_autologin=off\nOMACVM_FEATURE_thp_kernel=off\nOMACVM_FEATURE_control_centre=on\n" + extra)
    token = os.path.join(tmp, "token")
    with open(token, "wb") as f:
        f.write(TOKEN + b"\n")
    vm_key = os.path.join(tmp, "vm-key")
    with open(vm_key, "w") as f:
        f.write(VM_KEY + "\n")
    installed = os.path.join(tmp, "installed.json")
    with open(installed, "w") as f:
        json.dump({"version": "2.7.0", "parts": {"gestures": {"digest": "sha256:" + "a" * 64, "release": "2.7.0"},
                                                 "bridge": {"digest": "sha256:" + "b" * 64, "release": "2.7.0"}}}, f)
    # The VM's own OmacVM is pinned at 2.9.0, so a release bump of src/VERSION
    # does not change which fake manifests count as newer.
    share = os.path.join(tmp, "share")
    os.makedirs(share, exist_ok=True)
    shutil.copy(os.path.join(SRC, "features.tsv"), share)
    with open(os.path.join(share, "VERSION"), "w") as f:
        f.write("2.9.0\n")
    return {"OMACVM_SHARE": share, "OMACVM_ENV": env_file, "OMACVM_INSTALLED": installed,
            "OMACVM_CHECK_SOCKET": check_sock, "OMACVM_BRIDGE_URL": f"http://127.0.0.1:{mac_port}",
            "OMACVM_BRIDGE_TOKEN_FILE": token, "OMACVM_VM_KEY_FILE": vm_key, "XDG_CACHE_HOME": os.path.join(tmp, "cache"),
            "OMACVM_SDDM_ROOT": os.path.join(tmp, "sddm-root")}   # no SDDM there unless a test makes it
