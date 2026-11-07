"""`omacvm extra-brightness` in the VM (the Display panel runs it): OmacVM.app's
Extra brightness over this VM's control port, answered by the app itself.
A pty stands in for the port and a thread for the app (test_port.py)."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from test_port import FakeApp  # noqa: E402

ENTRY = os.path.join(os.path.dirname(__file__), "..", "omacvm")
PATH = "/omacvm/app/extra-brightness"


@pytest.fixture
def vm(tmp_path):
    share = tmp_path / "share"
    share.mkdir()
    (share / "VERSION").write_text("3.1.30\n")
    env_file = tmp_path / "env"
    env_file.write_text("OMACVM_VM_TYPE=app\nOMACVM_HOST=10.0.2.2\n")
    apps = []

    def run(answer, *args, vm_type="app", port=True):
        env_file.write_text(f"OMACVM_VM_TYPE={vm_type}\nOMACVM_HOST=10.0.2.2\n")
        env = {k: v for k, v in os.environ.items() if k != "OMACVM_BRIDGE_URL"}
        env.update(OMACVM_SHARE=str(share), OMACVM_ENV=str(env_file), HOME=str(tmp_path))
        app = None
        if port:
            app = FakeApp(answer)
            apps.append(app)
            env["OMACVM_CONTROL_PORT"] = app.path
        else:
            env["OMACVM_CONTROL_PORT"] = str(tmp_path / "no-port")
        p = subprocess.run([sys.executable, ENTRY, "extra-brightness", *args], env=env,
                           capture_output=True, text=True, timeout=20)
        return p, (app.requests if app else [])
    yield run
    for a in apps:
        a.close()


STATE = {"display": True, "safe_mode": False, "on": False, "available": True}


def test_reads_the_state(vm):
    p, reqs = vm(lambda r: (200, STATE), "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout) == STATE
    assert reqs[-1]["method"] == "GET" and reqs[-1]["path"] == PATH and reqs[-1]["body"] is None


def test_switches_it(vm):
    p, reqs = vm(lambda r: (200, dict(STATE, on=r["body"]["on"])), "on", "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout)["on"] is True
    assert reqs[-1]["method"] == "POST" and reqs[-1]["body"] == {"on": True}
    p, reqs = vm(lambda r: (200, dict(STATE, on=r["body"]["on"])), "off")
    assert p.returncode == 0 and p.stdout.strip() == "Extra brightness: off"
    assert reqs[-1]["body"] == {"on": False}


def test_text(vm):
    p, _ = vm(lambda r: (200, dict(STATE, display=False, available=False)))
    assert p.stdout.strip() == "Extra brightness: not on this Mac (it needs an XDR display)"
    p, _ = vm(lambda r: (200, dict(STATE, safe_mode=True, available=False)))
    assert p.stdout.strip() == "Extra brightness: off while GPU safe mode is on"


def test_the_app_says_no(vm):
    for status, code in [(409, "not-front"), (409, "no-display"), (409, "safe-mode"), (429, "busy")]:
        p, _ = vm(lambda r, s=status, c=code: (s, {"code": c, "error": "no"}), "on", "--json")
        assert p.returncode == 4, (status, code, p.stderr)
        assert json.loads(p.stdout)["code"] == code


def test_older_app(vm):
    # An app before 3.1.30 passes it to the Bridge, which knows no such request.
    p, _ = vm(lambda r: (404, {"code": "not-found", "error": "not found"}), "--json")
    assert p.returncode == 1 and p.stdout == ""
    # The Bridge does not answer at all.
    p, _ = vm(lambda r: (0, {"error": "OmacVM Bridge does not answer on this Mac"}))
    assert p.returncode == 1


def test_not_an_app_vm(vm):
    p, reqs = vm(lambda r: (200, STATE), "--json", vm_type="other")
    assert p.returncode == 3 and reqs == []
    p, _ = vm(None, "--json", port=False)
    assert p.returncode == 3


def test_usage(vm):
    for args in (["toggle"], ["on", "off"], ["--yes"]):
        p, reqs = vm(lambda r: (200, STATE), *args)
        assert p.returncode == 2 and reqs == []


def test_values_are_booleans(vm):
    # Whatever the answer holds, the panel gets four real booleans.
    p, _ = vm(lambda r: (200, {"display": 1, "on": "yes", "extra": [1]}), "--json")
    assert json.loads(p.stdout) == {"display": False, "safe_mode": False, "on": False, "available": False}
