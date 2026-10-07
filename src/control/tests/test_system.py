"""The VM's own system update (omacvm update-system, o on the Updates
screen): Omarchy's full update, never pacman -Sy, then the graphics check
before any restart. omarchy-update, checkupdates, gbm-guard and pacman are
fakes that write down how they were called."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from omacvm_cc import system  # noqa: E402
from test_entry import run_in_pty  # noqa: E402


def tool(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


@pytest.fixture
def vm(tmp_path, monkeypatch):
    """A bin with omarchy-update, pacman and checkupdates; a share with gbm-guard.
    Each writes "<name> <args>" to calls."""
    b, share, calls = tmp_path / "bin", tmp_path / "share", tmp_path / "calls"
    for name in ("omarchy-update", "pacman"):
        tool(b / name, f'echo "{name} $*" >> {calls}\nexit ${{FAKE_RC:-0}}\n')
    tool(b / "checkupdates", 'printf "mesa 1 -> 2\\nllvm-libs 22 -> 23\\nhyprland 1 -> 2\\n"\n')
    tool(share / "guest" / "gbm-guard", f'echo "gbm-guard $*" >> {calls}\n'
                                         '[ -z "$FAKE_GBM_BAD" ] && { echo "GBM opens"; exit 0; }\n'
                                         'echo "GBM does not open: no GBM device"; exit 1\n')
    monkeypatch.setenv("PATH", f"{b}{os.pathsep}/usr/bin{os.pathsep}/bin")
    monkeypatch.setenv("OMACVM_SHARE", str(share))
    monkeypatch.delenv("FAKE_RC", raising=False)
    monkeypatch.delenv("FAKE_GBM_BAD", raising=False)
    return b, share, calls


def called(calls):
    return calls.read_text().splitlines() if calls.exists() else []


def test_waiting_counts_and_skips(vm, monkeypatch):
    b, _, calls = vm
    assert system.waiting() == 3
    assert system.waiting_line(3) == "Omarchy: 3 updates waiting"
    assert system.waiting_line(1) == "Omarchy: 1 update waiting"
    tool(b / "checkupdates", "exit 2\n")   # nothing to update
    assert system.waiting() == 0 and system.waiting_line(0) == "Omarchy: up to date"
    tool(b / "checkupdates", "echo 'cannot fetch' >&2; exit 1\n")
    assert system.waiting() is None and system.waiting_line(None) == ""
    (b / "checkupdates").unlink()
    assert system.waiting() is None
    # Counting never touches the system's package lists.
    assert not any(c.startswith("pacman") for c in called(calls))


def test_update_command_is_omarchys_full_update(vm):
    b, _, _ = vm
    assert system.update_command() == ["omarchy-update", "-y"]
    (b / "omarchy-update").unlink()
    tool(b / "omarchy", "exit 0\n")
    assert system.update_command() == ["omarchy", "update", "-y"]
    (b / "omarchy").unlink()
    assert system.update_command() is None


def test_run_updates_then_checks_graphics(vm, capsys):
    _, _, calls = vm
    assert system.run(yes=True) == 0
    assert called(calls) == ["omarchy-update -y", "gbm-guard test"]
    out = capsys.readouterr().out
    assert "not the OmacVM update" in out and "GBM opens" in out and system.OK in out


def test_broken_graphics_say_do_not_restart(vm, monkeypatch, capsys):
    monkeypatch.setenv("FAKE_GBM_BAD", "1")
    assert system.run(yes=True) == 1
    out = capsys.readouterr().out
    assert "no GBM device" in out and "do not restart" in out and system.OK not in out


def test_failed_update_still_checks_graphics(vm, monkeypatch, capsys):
    _, _, calls = vm
    monkeypatch.setenv("FAKE_RC", "1")
    assert system.run(yes=True) == 1
    assert called(calls) == ["omarchy-update -y", "gbm-guard test"]
    out = capsys.readouterr().out
    assert "omarchy update stopped (exit 1)" in out and system.OK in out


def test_no_gbm_guard_is_not_ok(vm, capsys):
    _, share, _ = vm
    (share / "guest" / "gbm-guard").unlink()
    assert system.run(yes=True) == 1
    out = capsys.readouterr().out
    assert "graphics not checked" in out and system.OK not in out


def test_asks_first_without_yes(vm, monkeypatch):
    _, _, calls = vm
    monkeypatch.setattr("builtins.input", lambda _: "n")
    assert system.run() == 0 and called(calls) == []


def test_open_window_runs_update_system(vm, monkeypatch):
    b, _, calls = vm
    tool(b / "omarchy-launch-tui", f'echo "omarchy-launch-tui $*" >> {calls}\n')
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    assert not system.open_window()   # over ssh or outside Hyprland: no window
    monkeypatch.setenv("WAYLAND_DISPLAY", "wayland-1")
    monkeypatch.setenv("HYPRLAND_INSTANCE_SIGNATURE", "sig")
    assert system.open_window()
    for _ in range(60):
        if called(calls):
            break
        time.sleep(0.05)
    # The app id is org.omarchy.omacvm: the control centre's float rule.
    assert called(calls) == ["omarchy-launch-tui omacvm --window update-system --yes"]


def test_cli_update_system_in_its_window(vm):
    """omacvm --window update-system --yes: the window stays until Return.
    It needs nothing from the Mac."""
    b, share, calls = vm
    env = dict(os.environ, TERM="xterm")
    out, alive = run_in_pty(["--window", "update-system", "--yes"], env, send=b"\n", wait=8.0)
    assert system.OK in out and "Press Return" in out and not alive, out
    assert called(calls) == ["omarchy-update -y", "gbm-guard test"]
    assert "update-system" in run_in_pty(["--help"], env, wait=5.0)[0]
