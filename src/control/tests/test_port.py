"""OmacVM.app's control port (virtio-serial org.omacvm.control), with a pty
standing in for the port and a thread for the app: one JSON line per request
and answer, matched by id; no token or key goes over it."""
import json
import os
import select
import sys
import threading
import tty

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from omacvm_cc.bridge import Bridge, BridgeError  # noqa: E402


class FakeApp:
    def __init__(self, answer):
        self.master, self.slave = os.openpty()
        tty.setraw(self.slave)
        self.path = os.ttyname(self.slave)
        self.requests = []
        self.answer = answer
        self.stopping = False
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        buf = b""
        while not self.stopping:
            if not select.select([self.master], [], [], 0.1)[0]:
                continue
            try:
                b = os.read(self.master, 4096)
            except OSError:
                return
            buf += b
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                r = json.loads(line)
                self.requests.append(r)
                # An answer to an earlier request first: the client skips it.
                os.write(self.master, json.dumps({"id": "0000", "status": 200, "body": {"stale": True}}).encode() + b"\n")
                status, body = self.answer(r)
                os.write(self.master, json.dumps({"id": r["id"], "status": status, "body": body}).encode() + b"\n")

    def close(self):
        self.stopping = True
        self.thread.join(2)
        os.close(self.slave)
        os.close(self.master)


@pytest.fixture
def port_env(monkeypatch):
    monkeypatch.delenv("OMACVM_BRIDGE_URL", raising=False)
    apps = []

    def make(answer):
        a = FakeApp(answer)
        apps.append(a)
        monkeypatch.setenv("OMACVM_CONTROL_PORT", a.path)
        return a
    yield make
    for a in apps:
        a.close()


def test_requests_go_over_the_port(port_env):
    app = port_env(lambda r: (200, {"proto": 1, "omacvm": "2.9.0", "features": ["bridge"], "path": r["path"]}))
    b = Bridge({"OMACVM_VM_TYPE": "app"}, "2.9.0")
    assert b.port_path == app.path
    h = b.hello()
    assert h.omacvm == "2.9.0" and h.features == ("bridge",)
    a = b.call("POST", "/omacvm/jobs", {"action": "reinstall", "features": ["bridge"]})
    assert a["path"] == "/omacvm/jobs"
    r = app.requests[-1]
    assert set(r) == {"id", "method", "path", "body", "proto", "version"}
    assert r["method"] == "POST" and r["body"] == {"action": "reinstall", "features": ["bridge"]}
    assert "token" not in json.dumps(app.requests).lower()


def test_refusals_and_no_bridge(port_env):
    port_env(lambda r: (409, {"error": "a job runs", "code": "busy"}) if r["path"] == "/omacvm/jobs"
             else (0, {"error": "OmacVM Bridge does not answer on this Mac"}))
    b = Bridge({"OMACVM_VM_TYPE": "app"}, "2.9.0")
    with pytest.raises(BridgeError) as e:
        b.call("POST", "/omacvm/jobs", {"action": "update"})
    assert e.value.kind == "refused" and e.value.code == "busy"
    with pytest.raises(BridgeError) as e:
        b.status()
    assert e.value.kind == "offline" and "Bridge" in str(e.value)


def test_silent_app_times_out(monkeypatch):
    monkeypatch.delenv("OMACVM_BRIDGE_URL", raising=False)
    m, s = os.openpty()
    tty.setraw(s)
    monkeypatch.setenv("OMACVM_CONTROL_PORT", os.ttyname(s))
    try:
        b = Bridge({"OMACVM_VM_TYPE": "app"}, "2.9.0")
        with pytest.raises(BridgeError) as e:
            b.call("GET", "/omacvm/hello", timeout=0.5)
        assert e.value.kind == "offline"
    finally:
        os.close(m)
        os.close(s)


def test_other_vms_use_the_network(port_env):
    app = port_env(lambda r: (200, {}))
    assert Bridge({"OMACVM_VM_TYPE": "other"}, "2.9.0").port_path == ""
    assert Bridge({"OMACVM_VM_TYPE": "app"}, "2.9.0", url="http://127.0.0.1:1").port_path == ""
    assert Bridge({"OMACVM_VM_TYPE": "app"}, "2.9.0").port_path == app.path
