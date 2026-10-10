"""The Full screen row (OmacVM.app: notch via Omanotch or including notch,
FullPanel #339): the rules, and the row and the Omanotch row against a fake
Mac."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from omacvm_cc import state as S  # noqa: E402
from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402

FP_THIS = "fullpanel (Omanotch off for this start; notch 640.5-829.5, strip 37.0 of 1470x956 points)"


def notch(**kw):
    n = {"notch": "native", "next_start": "native", "this_start": "native", "mac_has_notch": True,
         "full_screen": True, "vm_ready": True}
    n.update(kw)
    return {"notch": n}


def test_only_app_vms_with_a_notch_or_the_setting():
    assert S.notch_row(notch(), "parallels") is None
    assert S.notch_row(notch(mac_has_notch=False), "app") is None   # a Mac mini: nothing to choose
    assert S.notch_row(notch(notch="fullpanel", mac_has_notch=False), "app") is not None   # set: say so
    assert S.notch_row({"graphics": {}}, "app") is None              # a Mac older than FullPanel
    assert S.notch_row(None, "app", offline=True) is None
    assert S.notch_row(None, "app").status is S.Status.UNKNOWN


def test_states():
    r = S.notch_row(notch(), "app")
    assert (r.on, r.status, r.note) == (False, S.Status.OFF, "notch via Omanotch")
    r = S.notch_row(notch(notch="fullpanel", next_start="fullpanel", this_start=FP_THIS), "app")
    assert (r.on, r.status, r.note) == (True, S.Status.WORKS, "incl. notch, no Omanotch")
    r = S.notch_row(notch(notch="fullpanel", next_start="fullpanel"), "app")
    assert r.status is S.Status.NEXT_START and "next start" in r.note
    r = S.notch_row(notch(notch="native", this_start=FP_THIS), "app")
    assert r.status is S.Status.NEXT_START and r.note.startswith("via Omanotch")
    for why, short in (("the app starts VMs in a window", "starts in a window"),
                       ("this Mac's built-in display has no notch now", "no notch now"),
                       ("the VM is not ready for it: Omanotch on, then Update VM or omacvm apply", "VM not ready")):
        r = S.notch_row(notch(notch="fullpanel", next_start=f"native (including notch is set, but {why})"), "app")
        assert r.status is S.Status.NEEDS_PERSON and r.note.endswith(short), r.note
        assert why in r.detail


def test_busy():
    job = S.Job(id="1", action="notch", features=("fullpanel",), state="running")
    assert S.notch_row(notch(), "app", jobs=[job]).note == "to incl. notch, no Omanotch…"


def test_notes_fit_an_80_column_row():
    with open(os.path.join(os.path.dirname(__file__), "..", "..", "features.tsv"), encoding="utf-8") as f:
        titles = [p.title for p in S.parse_features_tsv(f.read())] + [S.NOTCH_FEATURE.title]
    room = 80 - 13 - max(len(t) for t in titles) - 5
    cases = [notch(), notch(notch="fullpanel", next_start="fullpanel", this_start=FP_THIS),
             notch(notch="fullpanel", next_start="fullpanel"), notch(this_start=FP_THIS)]
    cases += [notch(notch="fullpanel", next_start=f"native (including notch is set, but {w})")
              for w in ("the app starts VMs in a window", "this Mac's built-in display has no notch now",
                        "the VM is not ready for it: Omanotch on, then Update VM or omacvm apply")]
    for st in cases:
        r = S.notch_row(st, "app")
        assert len(r.note) <= room, (r.note, len(r.note), room)
    assert len(S.OMANOTCH_FULLPANEL_NOTE) <= room


def test_the_row_reads_full_screen_within_80_columns():
    r = S.notch_row(notch(notch="fullpanel", next_start="fullpanel", this_start=FP_THIS), "app")
    assert f"{r.feature.title}: {r.note}" == "Full screen: incl. notch, no Omanotch"
    assert len(S.NOTCH_FEATURE.title) + 2 + len(r.note) <= 80
    assert "Full screen including notch" in S.NOTCH_FEATURE.summary or "Including notch" in S.NOTCH_FEATURE.summary


def test_space_switches():
    assert S.next_notch("native") == "fullpanel" and S.next_notch("fullpanel") == "native"


@pytest.fixture
def app_world(tmp_path, monkeypatch):
    mac, checks = FakeMac(), FakeChecks()
    for k, v in vm_env(str(tmp_path), mac.port, checks.path,
                       extra="OMACVM_VM_TYPE=app\nOMACVM_FEATURE_omanotch=on\n").items():
        monkeypatch.setenv(k, v)
    mac.graphics = {"graphics": "auto", "next_start": "opengl", "this_start": "auto -> opengl (macOS 15)"}
    yield mac
    mac.stop()
    checks.stop()


def test_rows_with_a_fake_mac(app_world):
    from omacvm_cc.controller import Controller
    app_world.notch_area = notch(notch="fullpanel", next_start="fullpanel", this_start=FP_THIS)["notch"]
    c = Controller()
    c.refresh_mac()
    rows = c.rows()
    names = [r.feature.name for r in rows]
    assert "notch-area" in names
    assert names.index("notch-area") == names.index("omanotch") + 1   # right after Omanotch
    na = rows[names.index("notch-area")]
    assert na.note == "incl. notch, no Omanotch"
    om = rows[names.index("omanotch")]
    if om.status in (S.Status.WORKS, S.Status.FAILING, S.Status.UNKNOWN):
        assert om.note == S.OMANOTCH_FULLPANEL_NOTE
    assert c.notch() == "fullpanel"
    # A native start: Omanotch's own note again, the row says native.
    app_world.notch_area = notch()["notch"]
    c.refresh_mac()
    rows = c.rows()
    om = next(r for r in rows if r.feature.name == "omanotch")
    assert om.note != S.OMANOTCH_FULLPANEL_NOTE
    assert next(r for r in rows if r.feature.name == "notch-area").note == "notch via Omanotch"


def test_job_body(app_world):
    from omacvm_cc.controller import Controller
    c = Controller()
    c.bridge.start_job("notch", ["fullpanel"])
    assert ("POST", "/omacvm/jobs", {"action": "notch", "notch": "fullpanel"}) in app_world.requests
