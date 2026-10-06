"""State rules: every step of the status order, dependencies, updates."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from omacvm_cc import state as S  # noqa: E402

TSV = os.path.join(os.path.dirname(__file__), "..", "..", "features.tsv")


@pytest.fixture(scope="module")
def features():
    return S.parse_features_tsv(open(TSV, encoding="utf-8").read())


def by(features, name):
    return next(f for f in features if f.name == name)


def chk(status, feature, human=False, side="vm", name="x", detail="d"):
    return S.Check(side=side, status=status, name=name, detail=detail, human=human, feature=feature)


def test_features_tsv_parses(features):
    names = [f.name for f in features]
    assert "bridge" in names and "gestures" in names
    assert by(features, "scroll-momentum").needs == "gestures"
    assert by(features, "wallpaper").needs == "bridge"
    assert "experimental" in by(features, "scroll-momentum").tags
    assert all(S.NAME_RE.match(n) for n in names)


def test_parse_env_last_wins():
    env = S.parse_env("OMACVM_FEATURE_bridge=on\nOMACVM_FEATURE_bridge=off\nnoise\n# c=1\n")
    assert env == {"OMACVM_FEATURE_bridge": "off"}


def test_desired_defaults_for_unnamed(features):
    on = S.desired(features, {"OMACVM_FEATURE_bridge": "off"})
    assert on["bridge"] is False
    assert on["gestures"] is True            # default on
    assert on["scroll-momentum"] is False    # older VMs: off
    assert on["omanotch"] is False           # notch: the Mac decides; unnamed = off


def test_parse_check_tsv():
    text = "section\tBridge\nok\tWi-Fi\tHome, -50 dBm\t\tbridge\nfail\tLocation\tnot granted\t1\tbridge\nskip\tx\ty\t\t\nweird line\n"
    c = S.parse_check_tsv(text)
    assert [x.status for x in c] == ["ok", "fail", "skip"]
    assert c[1].human and c[1].feature == "bridge"
    assert c[2].feature == ""


def test_parse_check_tsv_old_four_columns():
    c = S.parse_check_tsv("ok\tWi-Fi\tfine\t\n")
    assert c[0].feature == "" and not c[0].human


def test_parse_mac_checks_ignores_junk():
    c = S.parse_mac_checks([{"status": "fail", "name": "a", "detail": "b", "needs_human": True, "feature": "gestures"},
                            {"status": "boom"}, "x"])
    assert len(c) == 1 and c[0].side == "mac" and c[0].human


# ---- the status order, one step at a time ----

def test_busy_wins_over_everything(features):
    f = by(features, "gestures")
    job = S.Job(id="1", action="enable", features=("gestures",), state="running", step=2, of=4, text="Mac side")
    st, note = S.status_of(f, True, S.Avail(False, "no"), [chk("fail", "gestures", True)], job)
    assert st is S.Status.BUSY and note == "Mac side (2/4)"


def test_finished_job_is_not_busy(features):
    f = by(features, "gestures")
    job = S.Job(id="1", action="enable", features=("gestures",), state="done")
    assert S.status_of(f, True, None, [], job)[0] is S.Status.WORKS


def test_unavailable_before_off(features):
    st, note = S.status_of(by(features, "omanotch"), False, S.Avail(False, "needs a MacBook with a notch"), None, None)
    assert st is S.Status.UNAVAILABLE and "notch" in note


def test_off_before_unknown(features):
    assert S.status_of(by(features, "autologin"), False, None, None, None)[0] is S.Status.OFF


def test_unknown_without_checks(features):
    assert S.status_of(by(features, "bridge"), True, None, None, None)[0] is S.Status.UNKNOWN


def test_needs_person_before_failing(features):
    checks = [chk("fail", "gestures", name="gestures", detail="not connected"),
              chk("fail", "gestures", True, side="mac", detail="System Settings > Accessibility")]
    st, note = S.status_of(by(features, "gestures"), True, None, checks, None)
    assert st is S.Status.NEEDS_PERSON and note == "Mac: System Settings > Accessibility"


def test_human_skip_is_a_hint_not_a_problem(features):
    st, _ = S.status_of(by(features, "camera"), True, None, [chk("skip", "camera", True)], None)
    assert st is S.Status.WORKS


def test_failing(features):
    st, note = S.status_of(by(features, "bridge"), True, None, [chk("fail", "bridge", name="audio", detail="no answer")], None)
    assert st is S.Status.FAILING and note == "audio: no answer"


def test_works_when_checked_and_nothing_failed(features):
    assert S.status_of(by(features, "mac-clock"), True, None, [], None)[0] is S.Status.WORKS


# ---- rows ----

def test_rows_map_checks_and_local_avail(features):
    on = S.desired(features, {})
    rows = S.build_rows(features, on, vm_type="parallels",
                        checks=[chk("fail", "bridge", name="audio"), chk("fail", "", name="zram")])
    r = {x.feature.name: x for x in rows}
    assert r["bridge"].status is S.Status.FAILING
    assert r["gestures"].status is S.Status.WORKS
    assert r["battery"].status is S.Status.UNAVAILABLE and "Parallels" in r["battery"].note
    assert r["fast-network"].status is S.Status.UNAVAILABLE and "OmacVM.app" in r["fast-network"].note


def test_app_only_feature_on_the_app(features):
    on = S.desired(features, {"OMACVM_FEATURE_fast_network": "on"})
    rows = S.build_rows(features, on, vm_type="app", checks=[])
    r = {x.feature.name: x for x in rows}
    assert r["fast-network"].status is S.Status.WORKS


def test_rows_mac_avail_and_older_mac(features):
    on = S.desired(features, {"OMACVM_FEATURE_control_centre": "on"})
    rows = S.build_rows(features, on, avail={"omanotch": S.Avail(False, "needs a MacBook with a notch")},
                        checks=[], mac_features={f.name for f in features} - {"control-centre"})
    r = {x.feature.name: x for x in rows}
    assert r["omanotch"].status is S.Status.UNAVAILABLE
    assert r["control-centre"].status is S.Status.UNAVAILABLE and "older" in r["control-centre"].note


def test_update_flags_and_update_job(features):
    on = S.desired(features, {})
    installed = {"gestures": {"digest": "sha256:a"}, "bridge": {"digest": "sha256:b"}}
    offer = {"gestures": {"digest": "sha256:c", "release": "2.9.1"}, "bridge": {"digest": "sha256:b"}, "camera": {}}
    job = S.Job(id="9", action="update", features=(), state="running")
    rows = S.build_rows(features, on, checks=[], installed=installed, offer=offer, jobs=[job])
    r = {x.feature.name: x for x in rows}
    assert r["gestures"].update and r["gestures"].status is S.Status.BUSY
    assert not r["bridge"].update and r["bridge"].status is S.Status.WORKS
    assert not r["camera"].update                  # no digest offered: nothing to say
    assert S.counts(rows)["updates"] == 1


def test_part_never_installed_counts_as_changed():
    assert S.part_changed("gestures", {}, {"gestures": {"digest": "sha256:x"}})


# ---- toggles with dependencies ----

def test_toggle_on_brings_what_it_needs(features):
    on = S.desired(features, {"OMACVM_FEATURE_gestures": "off"})
    assert S.toggle_plan(features, on, "scroll-momentum") == {"scroll-momentum": True, "gestures": True}


def test_toggle_off_takes_dependents(features):
    on = S.desired(features, {"OMACVM_FEATURE_bridge": "on", "OMACVM_FEATURE_wallpaper": "on"})
    # external-brightness (on by default) needs the Bridge too.
    assert S.toggle_plan(features, on, "bridge") == {"bridge": False, "wallpaper": False, "external-brightness": False}


def test_toggle_plain(features):
    on = S.desired(features, {})
    assert S.toggle_plan(features, on, "autologin") == {"autologin": True}


def test_toggle_unknown_feature(features):
    with pytest.raises(KeyError):
        S.toggle_plan(features, {}, "rm -rf")


def test_checks_off_hides_marks_but_not_a_running_update():
    fs = S.parse_features_tsv(open(os.path.join(os.path.dirname(__file__), "..", "..", "features.tsv"), encoding="utf-8").read())
    on = {f.name: True for f in fs}
    offer = {"gestures": {"digest": "sha256:" + "c" * 64, "release": "2.9.1"}}
    installed = {"gestures": {"digest": "sha256:" + "a" * 64}}
    rows = {r.feature.name: r for r in S.build_rows(fs, on, checks=[], offer=offer, installed=installed, show_updates=False)}
    assert not rows["gestures"].update
    job = S.Job(id="1", action="update", features=(), state="running", step=5, of=6, text="the VM side")
    rows = {r.feature.name: r for r in S.build_rows(fs, on, checks=[], offer=offer, installed=installed,
                                                    jobs=[job], show_updates=False)}
    assert rows["gestures"].status is S.Status.BUSY and rows["gestures"].note == "the VM side (5/6)"
    assert not rows["gestures"].update and rows["bridge"].status is not S.Status.BUSY


def test_graphics_row_only_for_app_vms():
    st = {"graphics": {"graphics": "auto", "next_start": "vulkan", "this_start": "auto -> vulkan (macOS 27, KosmicKrisp)"}}
    assert S.graphics_row(st, "parallels") is None
    r = S.graphics_row(st, "app")
    assert r.feature.name == "graphics" and r.status is S.Status.WORKS
    assert r.note == "Automatic: OpenGL and Vulkan"


def test_graphics_row_without_the_mac():
    """No status from the Mac (not set up, not answering): not "older"."""
    assert S.graphics_row(None, "app", offline=True).note == "needs the Mac"
    assert S.graphics_row(None, "app").note == "asking the Mac"
    assert "older than 3.0.0" in S.graphics_row({"graphics": None}, "app").note


def test_graphics_row_says_next_start():
    st = {"graphics": {"graphics": "opengl", "next_start": "opengl", "this_start": "auto -> vulkan (macOS 27, KosmicKrisp)"}}
    assert S.graphics_row(st, "app").note == "OpenGL: OpenGL from the next start"


def test_graphics_row_vulkan_waiting_for_driver():
    st = {"graphics": {"graphics": "vulkan", "next_start": "opengl", "waiting_for_driver": True,
                       "summary": "Vulkan (driver not built yet: runs on OpenGL until the next apply)",
                       "this_start": "vulkan -> opengl (driver not built yet: runs on OpenGL until the next apply)"}}
    r = S.graphics_row(st, "app")
    assert r.note == "Vulkan (driver not built yet: runs on OpenGL until the next apply)"
    # A Mac whose omacvm has no summary yet still says why.
    del st["graphics"]["summary"]
    assert "driver not built yet" in S.graphics_row(st, "app").note


def test_graphics_row_vulkan_fell_back():
    why = ("Vulkan did not start on this Mac: using OpenGL (the firmware found no devices in 25 s: "
           "no boot disk, no picture; choose Vulkan again to try once more)")
    st = {"graphics": {"graphics": "vulkan", "next_start": "opengl", "waiting_for_driver": False, "summary": why,
                       "this_start": f"vulkan -> opengl ({why})"}}
    r = S.graphics_row(st, "app")
    assert r.note == why and r.status is S.Status.WORKS


def test_graphics_row_unknown_and_busy():
    assert S.graphics_row({}, "app").status is S.Status.UNKNOWN
    assert S.graphics_row({"graphics": {"graphics": "metal"}}, "app").status is S.Status.UNKNOWN
    j = S.Job(id="1", action="graphics", features=("vulkan",), state="running")
    r = S.graphics_row({"graphics": {"graphics": "auto"}}, "app", [j])
    assert r.status is S.Status.BUSY and "Vulkan" in r.note


def test_graphics_row_failing_check():
    st = {"graphics": {"graphics": "vulkan", "next_start": "vulkan", "this_start": "vulkan -> vulkan (chosen, MoltenVK)"}}
    c = chk("fail", "graphics", name="Vulkan (Venus)", detail="needed: omacvm apply")
    r = S.graphics_row(st, "app", [], [c, chk("fail", "bridge")])
    assert r.status is S.Status.FAILING and "omacvm apply" in r.note and len(r.checks) == 1


def test_next_graphics_cycles():
    assert [S.next_graphics(x) for x in ("auto", "opengl", "vulkan", "")] == ["opengl", "vulkan", "auto", "auto"]


# ---- OmacVM.app's graphics memory row ----
GM = {"measured": True, "in_use_mb": 1126, "peak_mb": 1638, "budget_mb": 49152, "pressure": "normal",
      "refused": 0, "lost": 0}


def test_gpu_memory_row_only_on_app_vms():
    assert S.gpu_memory_row(GM, "parallels") is None
    assert S.gpu_memory_row(GM, "utm") is None


def test_gpu_memory_row_numbers():
    r = S.gpu_memory_row(GM, "app")
    assert r.feature.title == "Graphics memory" and r.status is S.Status.WORKS
    assert r.note == "1.1 GB (peak 1.6 GB)"
    assert f"{r.feature.title}: {r.note}" == "Graphics memory: 1.1 GB (peak 1.6 GB)"
    assert S.gpu_memory_row(dict(GM, in_use_mb=512, peak_mb=900), "app").note == "512 MB (peak 900 MB)"
    # A peak below now (an odd file) shows now as the peak.
    assert S.gpu_memory_row(dict(GM, in_use_mb=2048, peak_mb=10), "app").note == "2.0 GB (peak 2.0 GB)"


def test_gpu_memory_row_explains_vm_vs_graphics_memory():
    r = S.gpu_memory_row(GM, "app")
    assert "VM memory is the Mac memory you gave the VM: its RAM" in r.feature.summary
    assert "Graphics memory comes on top" in r.feature.summary


@pytest.mark.parametrize("pressure", ["warn", "critical"])
def test_gpu_memory_row_warns_under_pressure(pressure):
    r = S.gpu_memory_row(dict(GM, pressure=pressure), "app")
    assert r.status is S.Status.NEEDS_PERSON
    assert r.note.startswith("1.1 GB (peak 1.6 GB); macOS is short of memory")


def test_gpu_memory_row_warns_after_refusals():
    r = S.gpu_memory_row(dict(GM, refused=3), "app")
    assert r.status is S.Status.NEEDS_PERSON and "3 refused this run" in r.note
    both = S.gpu_memory_row(dict(GM, refused=1, pressure="critical"), "app")
    assert "short of memory" in both.note and "1 refused" in both.note


def test_gpu_memory_row_unknowns():
    assert S.gpu_memory_row(None, "app").status is S.Status.UNKNOWN
    assert S.gpu_memory_row(None, "app").note == "asking the Mac"
    assert S.gpu_memory_row(None, "app", offline=True).note == "needs the Mac"
    assert "older than 3.0.0" in S.gpu_memory_row(None, "app", supported=False).note
    r = S.gpu_memory_row({"measured": False}, "app")
    assert r.status is S.Status.UNKNOWN and "not measured yet" in r.note


def test_gpu_memory_row_ignores_junk():
    r = S.gpu_memory_row({"measured": True, "in_use_mb": "9999", "peak_mb": -5, "refused": True,
                          "pressure": "panic"}, "app")
    assert r.status is S.Status.WORKS and r.note == "0 MB (peak 0 MB)"


def test_graphics_memory_check_on_one_row_only():
    # check.sh sends it with FEATURE=gpu-memory; older RCs sent FEATURE=graphics:
    # either way it is on the Graphics memory row and not on the Graphics row.
    st = {"graphics": {"graphics": "auto", "next_start": "opengl", "this_start": "opengl"}}
    for feat in ("gpu-memory", "graphics"):
        c = S.Check("mac", "fail", "graphics memory", "1 allocation(s) refused this run", False, feat)
        assert S.gpu_memory_row(GM, "app", checks=[c]).checks == (c,)
        g = S.graphics_row(st, "app", checks=[c])
        assert g.checks == () and g.status is S.Status.WORKS


def test_gpu_memory_row_carries_the_macs_check():
    c = S.Check("mac", "ok", "graphics memory", "1.1 GB now (peak 1.6 GB)", False, "")
    other = S.Check("mac", "ok", "microphone", "", False, "")
    assert S.gpu_memory_row(GM, "app", checks=[c, other]).checks == (c,)
