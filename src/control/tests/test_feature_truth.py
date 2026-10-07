"""Feature state truth: the real state of what can be switched outside OmacVM
(autologin by SDDM, the fast network by the app), the Mac's "fixed the record"
note, the words for tags (never a bare "slow"), and the WebGPU details."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from omacvm_cc import local as L  # noqa: E402
from omacvm_cc import state as S  # noqa: E402

TSV = os.path.join(os.path.dirname(__file__), "..", "..", "features.tsv")


@pytest.fixture(scope="module")
def features():
    return S.parse_features_tsv(open(TSV, encoding="utf-8").read())


def by(features, name):
    return next(f for f in features if f.name == name)


# ---- autologin as SDDM does it ----

MIGRATED = ("# omarchy-vm: the Mac is already FileVault-encrypted\n[Autologin]\nUser=gillesgoetsch\n"
            "Session=hyprland-uwsm\nRelogin=false\n")


def test_sddm_someone_elses_file_counts():
    assert S.sddm_autologin_user(["[Theme]\nCurrent=omarchy\n", MIGRATED]) == "gillesgoetsch"


def test_sddm_no_autologin():
    assert S.sddm_autologin_user(["[Theme]\nCurrent=omarchy\n", "[General]\nDisplayServer=wayland\n"]) == ""


def test_sddm_later_file_wins_and_user_outside_section_ignored():
    assert S.sddm_autologin_user([MIGRATED, "[Autologin]\nUser=\n"]) == ""
    assert S.sddm_autologin_user(["[Users]\nUser=x\n"]) == ""
    assert S.sddm_autologin_user(["[Autologin]\n  User = zorro \n"]) == "zorro"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def test_local_reads_sddm_not_only_the_env(tmp_path, monkeypatch):
    """The user's case: the env says autologin=off, a migration's own SDDM file logs them in."""
    share = tmp_path / "share"
    share.mkdir()
    (share / "features.tsv").write_text(open(TSV, encoding="utf-8").read())
    (share / "VERSION").write_text("3.0.0\n")
    env = tmp_path / "env"
    env.write_text("OMACVM_VM_TYPE=app\nOMACVM_FEATURE_autologin=off\n")
    root = tmp_path / "root"
    monkeypatch.setenv("OMACVM_SHARE", str(share))
    monkeypatch.setenv("OMACVM_ENV", str(env))
    monkeypatch.setenv("OMACVM_INSTALLED", str(tmp_path / "none.json"))
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.setenv("OMACVM_SDDM_ROOT", str(root))
    assert L.Local().on["autologin"] is False          # no SDDM at all: the env says
    write(str(root / "etc/sddm.conf.d/10-theme.conf"), "[Theme]\nCurrent=omarchy\n")
    assert L.Local().on["autologin"] is False          # SDDM, nobody logged in
    write(str(root / "etc/sddm.conf.d/20-autologin.conf"), MIGRATED)
    assert L.Local().on["autologin"] is True           # never a wrong tick
    env.write_text("OMACVM_VM_TYPE=app\nOMACVM_FEATURE_autologin=on\n")
    os.remove(str(root / "etc/sddm.conf.d/20-autologin.conf"))
    assert L.Local().on["autologin"] is False          # switched off outside OmacVM


# ---- the Mac fixed the record ----

def test_fixed_row_shows_real_state_and_note(features):
    on = {f.name: False for f in features}
    on["fast-network"] = True
    rows = S.build_rows(features, on, vm_type="app", checks=[],
                        fixed={"fast-network": "on (the app's Fast network setting); OmacVM's record said off: fixed the record"})
    r = next(r for r in rows if r.feature.name == "fast-network")
    assert r.on and r.status is S.Status.WORKS
    assert r.note == "OmacVM's record said off: fixed"


def test_fixed_note_never_hides_a_failure(features):
    on = {f.name: True for f in features}
    chk = S.Check(side="mac", status="fail", name="fast network", detail="vmnet down", human=False, feature="fast-network")
    rows = S.build_rows(features, on, vm_type="app", checks=[chk], fixed={"fast-network": "x"})
    r = next(r for r in rows if r.feature.name == "fast-network")
    assert r.status is S.Status.FAILING and "vmnet down" in r.note


def test_controller_takes_the_macs_fixed_state(features):
    from omacvm_cc.controller import Controller

    c = Controller.__new__(Controller)

    class Loc:
        pass
    c.local = Loc()
    c.local.features, c.local.vm_type = features, "app"
    c.local.on = {f.name: False for f in features}
    c.local.installed_parts = lambda: {}
    c.mac_status = {"features": [
        {"name": "fast-network", "on": True, "available": True, "reason": "", "fixed": "on (...): fixed the record"},
        {"name": "bridge", "on": True, "available": True, "reason": "", "fixed": ""}]}
    c.vm_checks, c.jobs, c.hello, c.mac_error, c.gpu_memory, c.mouse_swipe = [], {}, None, None, None, None
    c.offer = lambda: {}
    c.gpu_memory_supported = lambda: None
    rows = {r.feature.name: r for r in c.rows(with_updates=False)}
    assert rows["fast-network"].on is True                 # the Mac's fixed state
    assert rows["bridge"].on is False                      # no fix: the VM's own copy
    assert c.fixed_of("fast-network").endswith("fixed the record") and c.fixed_of("bridge") == ""


# ---- tags in words ----

def test_every_tag_shown_has_words(features):
    for f in features:
        for t in f.tags:
            if t in ("experimental", "slow"):
                assert t in S.TAG_NOTES and t in S.TAG_HINTS


def test_slow_is_never_bare(features):
    f = by(features, "thp-kernel")
    assert "slow" in f.tags
    note = S.tag_note(f)
    assert note != "slow" and "1 h+" in note
    assert "over an hour" in S.TAG_HINTS["slow"] and "CPUs" in S.TAG_HINTS["slow"]


def test_slow_says_nothing_when_on(features):
    f = by(features, "thp-kernel")
    assert S.tag_note(f, on=True) == ""
    assert S.tag_hints(f, on=True) == []
    assert S.tag_hints(f, on=False) == [S.TAG_HINTS["slow"]]
    x = by(features, "x86-apps")
    assert S.tag_note(x, on=True) == "experimental"


def test_slow_words_match_the_cli():
    lib = open(os.path.join(os.path.dirname(__file__), "..", "..", "lib", "features.sh"), encoding="utf-8").read()
    assert S.TAG_HINTS["slow"] in lib


# ---- WebGPU and GPU compute ----

def test_webgpu_details_by_macos(features):
    f = by(features, "vulkan")
    new, old, unknown = S.feature_about(f, "26.1"), S.feature_about(f, "15.6.1"), S.feature_about(f, "")
    assert "KosmicKrisp" in new and "MoltenVK" not in new and "macOS 26.1" in new
    assert "MoltenVK" in old and "macOS 15.6.1" in old and "needs macOS 26" in old
    assert "KosmicKrisp" in unknown and "MoltenVK" in unknown
    for t in (new, old, unknown):
        assert "about 3 minutes" in t and "next start" in t and "switch it on again" in t
        assert "OmacVM.app" in t


def test_other_features_have_no_extra_details(features):
    assert S.feature_about(by(features, "bridge"), "26.0") == ""
