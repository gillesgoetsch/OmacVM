"""The omacvm entry in the VM: opened from the menu, the bar or the launcher
(--window), the plain-text table waits for Return, Escape or q when the
control centre cannot start (no Textual), instead of a window that closes at
once. Typed in a terminal on the desktop, it opens its own window."""
import os
import pty
import select
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))

from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402

HERE = os.path.dirname(__file__)
ENTRY = os.path.join(HERE, "..", "omacvm")


def run_in_pty(args, env, send=b"", wait=8.0, answer=b""):
    m, s = pty.openpty()
    p = subprocess.Popen([sys.executable, ENTRY] + args, stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
    os.close(s)
    out, end, sent, answered = b"", time.monotonic() + wait, False, False
    while time.monotonic() < end:
        r, _, _ = select.select([m], [], [], 0.2)
        if r:
            try:
                out += os.read(m, 65536)
            except OSError:
                break
        # Textual missing and the Mac answers: it offers to install it from there.
        if b"[Y/n]" in out and answer and not answered:
            os.write(m, answer)
            answered = True
        if b"to close." in out and send and not sent:
            os.write(m, send)
            sent = True
        if p.poll() is not None and not r:
            break
    alive = p.poll() is None
    if alive:
        p.kill()
    os.close(m)
    return out.decode("utf-8", "replace"), alive


def no_textual_env(tmp_path, mac, checks):
    stub = tmp_path / "stub"
    (stub / "textual").mkdir(parents=True)
    (stub / "textual" / "__init__.py").write_text("raise ImportError('no textual here')\n")
    env = dict(os.environ, **vm_env(str(tmp_path), mac.port, checks.path))
    for k in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "SSH_CONNECTION"):
        env.pop(k, None)
    env["PYTHONPATH"] = str(stub)
    env["TERM"] = "xterm"
    return env


def test_window_waits_for_return(tmp_path):
    mac, checks = FakeMac(), FakeChecks()
    try:
        env = no_textual_env(tmp_path, mac, checks)
        out, alive = run_in_pty(["--window"], env, wait=6.0)
        assert "Install it from the Mac now? [Y/n]" in out and "sudo" not in out and alive, out
        out, alive = run_in_pty(["--window"], env, wait=6.0, answer=b"n\n")
        assert "Press Return, Escape or q to close." in out and alive, out
        for key in (b"\n", b"\x1b", b"q"):
            out, alive = run_in_pty(["--window"], env, send=key, wait=8.0, answer=b"n\n")
            assert "Press Return, Escape or q to close." in out and not alive, (key, out)
            assert "Trackpad gestures" in out
    finally:
        mac.stop()
        checks.stop()


def test_terminal_does_not_wait(tmp_path):
    mac, checks = FakeMac(), FakeChecks()
    try:
        out, alive = run_in_pty([], no_textual_env(tmp_path, mac, checks), wait=8.0, answer=b"n\n")
        assert not alive and "Press Return" not in out and "python-textual" in out, out
    finally:
        mac.stop()
        checks.stop()


def fake_launcher(tmp_path):
    """omarchy-launch-or-focus-tui that writes down how it was called."""
    bin_ = tmp_path / "bin"
    bin_.mkdir()
    log = tmp_path / "launched"
    f = bin_ / "omarchy-launch-or-focus-tui"
    f.write_text(f"#!/bin/sh\necho \"$*\" >> {log}\n")
    f.chmod(0o755)
    return str(bin_), log


def wait_for(path, secs=3.0):
    end = time.monotonic() + secs
    while time.monotonic() < end and not path.exists():
        time.sleep(0.05)
    return path.read_text() if path.exists() else ""


def test_terminal_on_the_desktop_opens_its_own_window(tmp_path):
    """Typed in a terminal in Hyprland: the same floating window as from the
    menu or the bar (omarchy-launch-or-focus-tui omacvm --window)."""
    mac, checks = FakeMac(), FakeChecks()
    try:
        env = no_textual_env(tmp_path, mac, checks)
        bin_, log = fake_launcher(tmp_path)
        env.update(PATH=bin_ + os.pathsep + env.get("PATH", ""), WAYLAND_DISPLAY="wayland-1",
                   HYPRLAND_INSTANCE_SIGNATURE="sig")
        out, alive = run_in_pty([], env, wait=6.0)
        assert not alive and "opens in its own window" in out, out
        assert wait_for(log).strip() == "omacvm --window"
    finally:
        mac.stop()
        checks.stop()


def test_here_over_ssh_and_in_the_window_stay_put(tmp_path):
    mac, checks = FakeMac(), FakeChecks()
    try:
        base = no_textual_env(tmp_path, mac, checks)
        bin_, log = fake_launcher(tmp_path)
        base.update(PATH=bin_ + os.pathsep + base.get("PATH", ""), WAYLAND_DISPLAY="wayland-1",
                    HYPRLAND_INSTANCE_SIGNATURE="sig")
        for args, extra in ((["--here"], {}), ([], {"SSH_CONNECTION": "10.0.2.2 1 10.0.2.15 22"}),
                            (["--window"], {})):
            out, alive = run_in_pty(args, dict(base, **extra), send=b"q", wait=8.0, answer=b"n\n")
            assert "opens in its own window" not in out and "python-textual" in out, (args, out)
        time.sleep(0.3)
        assert not log.exists(), log.read_text()
    finally:
        mac.stop()
        checks.stop()
