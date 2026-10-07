"""omacvm-touchid-theme (ADR 0041, addendum 3.0.2): the Omarchy theme's
colours as the VM sends them for the Mac's Touch ID panel, from the theme's
files and Hyprland, signed with the VM's key; sent once per change."""
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from fakes import SRC, FakeMac, vm_env  # noqa: E402

SENDER = os.path.join(SRC, "bridge", "guest", "omacvm-touchid-theme")
FIX = os.path.join(SRC, "bridge", "mac", "tests", "fixtures")
TOKYO = {"accent": "#7aa2f7", "background": "#1a1b26", "border": ["#7aa2f7"], "border_angle": 0.0, "error": "#f7768e",
         "foreground": "#a9b1d6", "radius": 0, "success": "#9ece6a", "muted": "#414868"}


@pytest.fixture
def vm(tmp_path):
    theme = tmp_path / "theme"
    theme.mkdir()
    shutil.copy(os.path.join(FIX, "tokyo-night-shell.toml"), theme / "shell.toml")
    shutil.copy(os.path.join(FIX, "tokyo-night-colors.toml"), theme / "colors.toml")
    hypr = tmp_path / "hyprctl"
    hypr.write_text('#!/bin/sh\ncase "$3" in\n'
                    '  decoration:rounding) cat "$(dirname "$0")/rounding" ;;\n'
                    '  general:col.active_border) cat "$(dirname "$0")/border" ;;\nesac\n')
    hypr.chmod(0o755)
    (tmp_path / "rounding").write_text('{"option": "decoration:rounding", "int": 0, "set": true }')
    (tmp_path / "border").write_text('{"option": "general:col.active_border", "gradient": "ff7aa2f7 0deg", "set": true }')
    env = dict(os.environ, OMACVM_TOUCHID_THEME_DIR=str(theme), OMACVM_TOUCHID_THEME_STATE=str(tmp_path / "sent"),
               OMACVM_TOUCHID_THEME_DELAY="0", OMACVM_HYPRCTL=str(hypr), HOME=str(tmp_path))
    return tmp_path, env


def run(env, *args):
    return subprocess.run([sys.executable, "-I", SENDER, *args], env=env, capture_output=True, text=True, timeout=30)


def printed(env):
    r = run(env, "--print")
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_tokyo_night_from_the_shell_files_and_hyprland(vm):
    assert printed(vm[1]) == TOKYO


def test_a_gradient_border_and_rounding(vm):
    tmp, env = vm
    (tmp / "border").write_text('{"option": "general:col.active_border", "gradient": "ee798186 eecacccc 45deg", "set": true }')
    (tmp / "rounding").write_text('{"option": "decoration:rounding", "int": 6, "set": true }')
    t = printed(env)
    assert t["border"] == ["#798186", "#cacccc"] and t["border_angle"] == 45.0 and t["radius"] == 6


def test_without_hyprland_the_polkit_border(vm):
    tmp, env = vm
    env["OMACVM_HYPRCTL"] = str(tmp / "nothing-here")
    t = printed(env)
    assert t["border"] == ["#7aa2f7"] and "border_angle" not in t and t["radius"] == 0


def test_colors_toml_alone(vm):
    tmp, env = vm
    (tmp / "theme" / "shell.toml").unlink()
    (tmp / "theme" / "colors.toml").write_text('mode = "dark"\nbackground = "#282828"\nforeground = "#D4BE98"\n'
                                               'accent = "#7daea3"\nred = "#ea6962"\n')
    t = printed(env)
    assert (t["background"], t["foreground"], t["accent"], t["error"]) == ("#282828", "#d4be98", "#7daea3", "#ea6962")


def test_success_and_muted_from_colors_toml(vm):
    tmp, env = vm
    text = (tmp / "theme" / "colors.toml").read_text()
    (tmp / "theme" / "colors.toml").write_text(text.replace('green = "#9ece6a"', 'green = "nope"'))
    t = printed(env)
    assert "success" not in t and t["muted"] == "#414868", "a colour it cannot read is left out (the Mac uses the text colour)"


def test_odd_values_are_left_out(vm):
    tmp, env = vm
    (tmp / "theme" / "shell.toml").unlink()
    (tmp / "theme" / "colors.toml").write_text('background = "#282828"\nforeground = "#ebdbb2"\naccent = "blue"\nred = 5\n')
    (tmp / "rounding").write_text('{"int": true}')
    t = printed(env)
    assert t["accent"] == "#ebdbb2" and t["error"] == "#ebdbb2" and t["radius"] == 0


def test_no_theme_sends_nothing(vm):
    tmp, env = vm
    env["OMACVM_TOUCHID_THEME_DIR"] = str(tmp / "none")
    r = run(env, "--print")
    assert r.returncode == 0 and r.stdout == "" and "no Omarchy theme" in r.stderr


@pytest.fixture
def mac(vm):
    tmp, env = vm
    m = FakeMac()
    env.update(vm_env(str(tmp), m.port, "/nonexistent"))
    os.symlink(os.path.join(SRC, "control"), os.path.join(env["OMACVM_SHARE"], "control"))
    yield m, env, tmp
    m.stop()


def test_sent_signed_once_per_change(mac):
    m, env, tmp = mac
    r = run(env)
    assert r.returncode == 0 and "-> the Mac" in r.stdout, r.stderr
    assert [q for q in m.requests if q[1] == "/omacvm/theme"] == [("POST", "/omacvm/theme", TOKYO)]
    assert ("/omacvm/theme", True) in m.signed
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 1, "unchanged: not sent again"
    run(env, "--force")
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 2
    (tmp / "rounding").write_text('{"int": 4}')
    run(env)
    assert m.requests[-1][2]["radius"] == 4, "a change goes out"


def test_refused_is_tried_again_next_time(mac):
    m, env, tmp = mac
    m.refuse_theme = (403, "off", "Touch ID is off for this VM")
    r = run(env)
    assert r.returncode == 0 and "not sent" in r.stderr and not (tmp / "sent").exists()
    m.refuse_theme = None
    run(env)
    assert len([q for q in m.requests if q[1] == "/omacvm/theme"]) == 2
