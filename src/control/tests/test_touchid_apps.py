"""Touch ID and the apps with their own switch (ADR 0041, addendum 3.0.4):
omacvm-touchid-apps reads 1Password's "Unlock using system authentication"
and tells the person once while it is off; the control centre shows Touch ID
turned on while an OmacVM.app VM runs as "from the next start", not failing."""
import asyncio
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from fakes import SRC, FakeChecks, FakeMac, vm_env  # noqa: E402
from omacvm_cc import local as L  # noqa: E402
from omacvm_cc import state as S  # noqa: E402

APPS = os.path.join(SRC, "bridge", "guest", "omacvm-touchid-apps")
KEY = "security.authenticatedUnlock.enabled"
OFF_LINE = ("1password\toff\t1Password\tturn on Settings › Security › Unlock using system authentication "
            "to use Touch ID")


@pytest.fixture
def vm(tmp_path):
    """A VM's root and the desktop user's home, a notify-send that logs its
    arguments (exit 1 while tmp/notify-fails exists)."""
    root, home = tmp_path / "root", tmp_path / "home"
    home.mkdir()
    (root / "usr/share/polkit-1/actions").mkdir(parents=True)
    ns = tmp_path / "notify-send"
    ns.write_text('#!/bin/sh\n[ -e "$(dirname "$0")/notify-fails" ] && exit 1\n'
                  'printf "%s|" "$@" >> "$(dirname "$0")/notified"; echo >> "$(dirname "$0")/notified"\n')
    ns.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith("XDG_")}
    env.update(HOME=str(home), OMACVM_TOUCHID_APPS_ROOT=str(root), OMACVM_NOTIFY_SEND=str(ns))
    return tmp_path, env


def install_1password(tmp, how="policy"):
    p = {"policy": "usr/share/polkit-1/actions/com.1password.1Password.policy", "opt": "opt/1Password/1password",
         "desktop": "usr/share/applications/1password.desktop"}[how]
    f = tmp / "root" / p
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("x")


def settings(tmp, data):
    d = tmp / "home/.config/1Password/settings"
    d.mkdir(parents=True, exist_ok=True)
    (d / "settings.json").write_text(data if isinstance(data, str) else json.dumps(data))


def run(env, *args):
    return subprocess.run([sys.executable, "-I", APPS, *args], env=env, capture_output=True, text=True, timeout=30)


def notified(tmp):
    f = tmp / "notified"
    return f.read_text().splitlines() if f.exists() else []


def test_no_1password_no_line_no_notice(vm):
    tmp, env = vm
    r = run(env)
    assert r.returncode == 0 and r.stdout == ""
    assert run(env, "--notify").returncode == 0 and notified(tmp) == []


@pytest.mark.parametrize("how", ["policy", "opt", "desktop"])
def test_1password_installed_never_set_is_off(vm, how):
    """Its settings file holds only what was changed: none, or one without the key, is off."""
    tmp, env = vm
    install_1password(tmp, how)
    assert run(env).stdout == OFF_LINE + "\n"
    settings(tmp, {"version": 1, "appearance.interfaceDensity": "compact", "authTags": {}})
    assert run(env).stdout == OFF_LINE + "\n"


def test_signed_on_uses_touch_id(vm):
    """As in a real settings.json of 1Password 8.10.38+ (signed settings)."""
    tmp, env = vm
    install_1password(tmp)
    settings(tmp, {"version": 1, KEY: True, "security.authenticatedUnlock.requireAccountPasswordAfter": '"thirty-days"',
                   "authTags": {KEY: "VdWDgqQAcLAo+0GYG4HhQrDeTJO5HINhMobfeA/r4yY"}})
    assert run(env).stdout == "1password\ton\t1Password\tuses Touch ID\n"


def test_unsigned_on_counts_as_off(vm):
    """1Password resets an unsigned sensitive setting at its next start:
    a true written into the file by hand is not believed. A file from
    before signatures (no authTags at all) is."""
    tmp, env = vm
    install_1password(tmp)
    settings(tmp, {KEY: True, "authTags": {"appearance.interfaceDensity": "abc"}})
    assert "\toff\t" in run(env).stdout
    settings(tmp, {KEY: True})
    assert "\ton\t" in run(env).stdout
    settings(tmp, {KEY: "true", "authTags": {KEY: "abc"}})
    assert "\toff\t" in run(env).stdout


def test_unreadable_settings_is_off(vm):
    tmp, env = vm
    install_1password(tmp)
    settings(tmp, "{not json")
    assert run(env).stdout == OFF_LINE + "\n"
    settings(tmp, "[1, 2]")
    assert run(env).stdout == OFF_LINE + "\n"


def test_notice_once_while_off_never_while_on(vm):
    tmp, env = vm
    install_1password(tmp)
    assert run(env, "--notify").returncode == 0
    assert notified(tmp) == ["-a|OmacVM|-i|1password|Touch ID|1Password: turn on Settings › Security › Unlock using "
                             "system authentication to use Touch ID.|"]
    assert (tmp / "home/.local/state/omacvm/touchid-hint-1password").exists()
    run(env, "--notify")
    assert len(notified(tmp)) == 1, "a second login says nothing"
    # Touch ID turned on again (touchid.sh clears the marks) with 1Password's switch on: nothing.
    (tmp / "home/.local/state/omacvm/touchid-hint-1password").unlink()
    settings(tmp, {KEY: True, "authTags": {KEY: "abc"}})
    run(env, "--notify")
    assert len(notified(tmp)) == 1


def test_no_notification_daemon_tries_again(vm):
    tmp, env = vm
    install_1password(tmp)
    (tmp / "notify-fails").write_text("")
    run(env, "--notify")
    assert not (tmp / "home/.local/state/omacvm/touchid-hint-1password").exists()
    (tmp / "notify-fails").unlink()
    run(env, "--notify")
    assert len(notified(tmp)) == 1


def test_xdg_config_home(vm):
    tmp, env = vm
    install_1password(tmp)
    d = tmp / "cfg/1Password/settings"
    d.mkdir(parents=True)
    (d / "settings.json").write_text(json.dumps({KEY: True}))
    assert "\ton\t" in run(dict(env, XDG_CONFIG_HOME=str(tmp / "cfg"))).stdout


def test_bad_arguments(vm):
    _, env = vm
    assert run(env, "--nope").returncode == 2


# ---- the control centre: Touch ID on, the VM not started again yet ----

@pytest.fixture
def features():
    return S.parse_features_tsv(open(os.path.join(SRC, "features.tsv"), encoding="utf-8").read())


def test_status_from_the_next_start(features):
    f = next(x for x in features if x.name == "touch-id")
    hint = S.Check("vm", "skip", "Touch ID", "on from the VM's next start: ...", True, "touch-id")
    assert S.status_of(f, True, None, [hint], None, next_start=True) == (S.Status.NEXT_START, S.NEXT_START_NOTE)
    assert S.status_of(f, True, None, None, None, next_start=True)[0] is S.Status.NEXT_START
    assert S.status_of(f, False, None, [hint], None, next_start=True)[0] is S.Status.OFF
    bad = S.Check("vm", "fail", "Touch ID", "no key in the VM", False, "touch-id")
    assert S.status_of(f, True, None, [bad], None, next_start=True)[0] is S.Status.FAILING
    assert S.status_of(f, True, None, [hint], None)[0] is S.Status.WORKS
    rows = S.build_rows(features, {"touch-id": True, "bridge": True}, vm_type="app", checks=[hint],
                        next_start={"touch-id"})
    r = next(x for x in rows if x.feature.name == "touch-id")
    assert r.status is S.Status.NEXT_START and "shut it down, then start it again" in r.note
    assert S.counts(rows)["next-start"] == 1


def test_next_start_only_for_an_app_vm_without_the_port(tmp_path, monkeypatch):
    monkeypatch.setenv("OMACVM_AUTH_PORT", str(tmp_path / "org.omacvm.auth"))
    assert L.next_start("app", {"touch-id": True}) == {"touch-id"}
    assert L.next_start("app", {"touch-id": False}) == set()
    assert L.next_start("parallels", {"touch-id": True}) == set()
    (tmp_path / "org.omacvm.auth").symlink_to("../vport1p3")   # udev's link; root's alone, never opened here
    assert L.next_start("app", {"touch-id": True}) == set()


def test_mac_ime_from_the_next_start_without_its_port(tmp_path, monkeypatch):
    # mac-ime: the app adds org.omacvm.ime only at a start with the feature on.
    monkeypatch.setenv("OMACVM_AUTH_PORT", str(tmp_path / "org.omacvm.auth"))
    monkeypatch.setenv("OMACVM_IME_PORT", str(tmp_path / "org.omacvm.ime"))
    assert L.next_start("app", {"mac-ime": True}) == {"mac-ime"}
    assert L.next_start("app", {"mac-ime": False}) == set()
    assert L.next_start("utm", {"mac-ime": True}) == set()
    (tmp_path / "org.omacvm.ime").symlink_to("../vport5p8")
    assert L.next_start("app", {"mac-ime": True, "touch-id": True}) == {"touch-id"}
    # No extra question before switching it: the row says "from the next start" after.
    assert S.next_start_note("mac-ime", True, "app") == ""


def test_drag_drop_from_the_next_start_without_its_port(tmp_path, monkeypatch):
    # drag-drop: the app adds org.omacvm.drop (and the drop share) only at a start with the feature on.
    monkeypatch.setenv("OMACVM_AUTH_PORT", str(tmp_path / "org.omacvm.auth"))
    monkeypatch.setenv("OMACVM_IME_PORT", str(tmp_path / "org.omacvm.ime"))
    monkeypatch.setenv("OMACVM_DROP_PORT", str(tmp_path / "org.omacvm.drop"))
    assert L.next_start("app", {"drag-drop": True}) == {"drag-drop"}
    assert L.next_start("app", {"drag-drop": False}) == set()
    assert L.next_start("utm", {"drag-drop": True}) == set()
    (tmp_path / "org.omacvm.drop").symlink_to("../vport6p10")
    assert L.next_start("app", {"drag-drop": True, "mac-ime": True}) == {"mac-ime"}


def test_about_lists_the_apps(features):
    t = S.feature_about(next(x for x in features if x.name == "touch-id"))
    assert "1Password: Settings › Security › Unlock using system authentication" in t
    assert "Bitwarden" in t and "KeePassXC" in t and "next start" in t


CHECKS = ("ok\tHyprland\trunning\t\t\n"
          "skip\tTouch ID\ton from the VM's next start: shut it down, then start it again\t1\ttouch-id\n"
          "ok\tTouch ID panel theme\tthe Mac's panel uses this Omarchy theme\t\ttouch-id\n"
          "skip\t1Password\tturn on Settings › Security › Unlock using system authentication to use Touch ID\t1\ttouch-id\n")


def test_control_centre_row_and_details(tmp_path, monkeypatch):
    pytest.importorskip("textual")
    mac, checks = FakeMac(), FakeChecks(CHECKS)
    extra = "OMACVM_VM_TYPE=app\nOMACVM_FEATURE_touch_id=on\n"
    for k, v in vm_env(str(tmp_path), mac.port, checks.path, extra).items():
        monkeypatch.setenv(k, v)
    monkeypatch.setenv("OMACVM_AUTH_PORT", str(tmp_path / "no-port"))
    from omacvm_cc.controller import Controller
    from omacvm_cc.tui import ControlCentre, DetailsScreen

    async def go():
        a = ControlCentre(Controller())
        async with a.run_test(size=(120, 40)) as pilot:
            for _ in range(160):
                await pilot.pause(0.05)
                if a.c.vm_checks is not None:
                    break
            r = next(x for x in a.rows if x.feature.name == "touch-id")
            assert r.status is S.Status.NEXT_START, (r.status, r.note)
            a.push_screen(DetailsScreen("touch-id"))
            await pilot.pause(0.3)
            body = str(a.screen.query_one("#body").render())
            assert "on from the VM's next start" in body
            assert "turn on Settings › Security › Unlock using system authentication" in body
            assert "Bitwarden" in body
            await pilot.press("escape")
            await pilot.press("q")
    try:
        asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()
