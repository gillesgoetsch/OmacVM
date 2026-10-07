"""The control centre's window: floated, centred, about two thirds of the
display, through a Hyprland rule for the app id every launcher gives it."""
import os
import re
import shutil
import subprocess

import pytest

HERE = os.path.dirname(__file__)
CONTROL = os.path.join(HERE, "..")
GUEST = os.path.join(CONTROL, "guest")
LAUNCH = "omarchy-launch-or-focus-tui omacvm --window"


def read(*p):
    with open(os.path.join(CONTROL, *p), encoding="utf-8") as f:
        return f.read()


def test_every_launcher_opens_the_same_app_id():
    # omarchy-launch-or-focus-tui names the window org.omarchy.<basename of the command>.
    assert f"Exec={LAUNCH}" in read("guest", "omacvm.desktop")
    assert f'run("{LAUNCH}")' in read("plugins", "omacvm.control", "BarWidget.qml")
    assert f'"action":"{LAUNCH}"' in read("guest", "install.sh")
    assert '[launcher, "omacvm", "--window"]' in read("omacvm")


def test_rule_floats_and_centres_that_app_id():
    lua = read("guest", "omacvm_cc.lua")
    assert 'class = "^org\\\\.omarchy\\\\.omacvm$"' in lua
    for rule in ("float = true", "center = true", 'size = { "(monitor_w*0.65)", "(monitor_h*0.65)" }'):
        assert rule in lua, rule
    # Lua: every rule goes through hl.window_rule with the shared match.
    assert len(re.findall(r"hl\.window_rule\(\{ match = match,", lua)) == 3


def test_install_requires_it_and_off_removes_both_lines():
    sh = read("guest", "install.sh")
    assert re.search(r"^CC_LINE='require\(\"hypr\.omacvm_cc\"\)'$", sh, re.M)
    assert 'grep -vxF -e "$CC_MARK" -e "$CC_LINE"' in sh
    assert "window_rule on" in sh and "window_rule off" in sh


@pytest.mark.skipif(not shutil.which("cmp"), reason="no cmp")
def test_on_off_round_trip(tmp_path):
    """window_rule on, again (no change), off: hyprland.lua is as it was."""
    sh = read("guest", "install.sh")
    body = sh[sh.index("HY=$H/.config/hypr"):sh.index("# Textual from pacman")]
    hy = tmp_path / ".config" / "hypr"
    hy.mkdir(parents=True)
    before = 'require("default.hypr.omarchy")\n-- mine\n'
    (hy / "hyprland.lua").write_text(before)
    user = subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
    # The guest's user has a group of the same name; a Mac user does not.
    owner = 'install() { command install -m644 "${@:$#-1:1}" "${@:$#}"; }\nchown() { :; }\n'
    script = f'set -euo pipefail\nU={user}; H={tmp_path}\n{owner}{body}\nwindow_rule on\nwindow_rule on\n' \
             f'cat "$HY/hyprland.lua" > {tmp_path}/on\nwindow_rule off\n'
    subprocess.run(["bash", "-c", script], cwd=GUEST, check=True)
    on = (tmp_path / "on").read_text()
    assert on.count('require("hypr.omacvm_cc")') == 1 and on.startswith(before), on
    assert (hy / "hyprland.lua").read_text() == before
    assert not (hy / "omacvm_cc.lua").exists()
