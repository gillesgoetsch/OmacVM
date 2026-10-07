"""App-only Macs (OmacVM.app, no checkout): Textual missing is fixed from the
Mac (a repair of the control centre), never with sudo in the VM; the app's
own omacvm runs changing commands from a copy (nothing written in the app)."""
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omacvm_cc import plain  # noqa: E402
from omacvm_cc.state import Job  # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


class FakeC:
    def __init__(self, linked=True, states=("running", "done"), fail=None):
        self.linked, self.states, self.fail, self.started = linked, list(states), fail, None

    def start(self, action, features):
        if self.fail:
            raise RuntimeError(self.fail)
        self.started = (action, list(features))
        return Job("j1", action, tuple(features), "queued")

    def poll(self, job_id):
        return Job(job_id, "reinstall", ("control-centre",), self.states.pop(0))


class TTY:
    def isatty(self):
        return True


def test_textual_fix_asks_the_mac(monkeypatch):
    monkeypatch.setattr(sys, "stdin", TTY())
    c = FakeC()
    line = plain.textual_fix(c, ask=lambda _: "", wait=0)
    assert c.started == ("reinstall", ["control-centre"])
    assert "installed" in line and "sudo" not in line
    c = FakeC(states=("failed",))
    assert "could not install" in plain.textual_fix(c, ask=lambda _: "y", wait=0)
    c = FakeC()
    assert "asks again" in plain.textual_fix(c, ask=lambda _: "n", wait=0) and c.started is None
    assert "could not install" in plain.textual_fix(FakeC(fail="busy"), ask=lambda _: "", wait=0)


def test_textual_fix_without_the_mac_or_a_terminal(monkeypatch):
    for line in (plain.textual_fix(FakeC(linked=False)),):
        assert "sudo" not in line and "Mac" in line
    monkeypatch.setattr(sys, "stdin", open(os.devnull))
    c = FakeC()
    assert "terminal" in plain.textual_fix(c) and c.started is None


def test_app_copy_runs_changes_from_a_copy(tmp_path):
    """An app's Contents/Resources/omacvm: apply etc. run from a temporary
    copy with the app's helpers and runtime; read-only commands in place."""
    res = tmp_path / "OmacVM.app" / "Contents" / "Resources" / "omacvm"
    (res / "src" / "cmd").mkdir(parents=True)
    with open(os.path.join(REPO, "omacvm")) as f:
        (res / "omacvm").write_text(f.read())
    (res / "omacvm").chmod(0o755)
    (res / "src" / "lib").mkdir()
    with open(os.path.join(REPO, "src", "lib", "identity.sh")) as f:
        (res / "src" / "lib" / "identity.sh").write_text(f.read())
    (res / "COMMIT").write_text("x\n")
    probe = '#!/bin/bash\necho "R=$(cd "$(dirname "$0")/../.." && pwd) H=$OMACVM_HELPERS CLI=$OMACVM_APP_CLI"\n'
    for c in ("apply", "vms"):
        (res / "src" / "cmd" / f"{c}.sh").write_text(probe)
        (res / "src" / "cmd" / f"{c}.sh").chmod(0o755)
    out = subprocess.run([str(res / "omacvm"), "apply"], capture_output=True, text=True, check=True).stdout
    assert f"R={res} " not in out and "R=/" in out
    assert f"CLI={res}/omacvm" in out and f"H={tmp_path}/OmacVM.app/Contents/Helpers" in out
    out = subprocess.run([str(res / "omacvm"), "vms"], capture_output=True, text=True, check=True).stdout
    assert f"R={res} " in out
    assert sorted(os.listdir(res)) == ["COMMIT", "omacvm", "src"]
