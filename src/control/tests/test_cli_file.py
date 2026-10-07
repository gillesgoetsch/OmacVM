"""Only the installed checkout becomes the omacvm the Bridge runs
(cli_for_bridge in src/lib/mac.sh): never another clone or worktree that
happens to run src/mac/install.sh."""
from __future__ import annotations

import os
import subprocess

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def chosen(me: str, links: list, extra: dict | None = None) -> bool:
    env = {k: v for k, v in os.environ.items() if k != "OMACVM_SET_CLI"}
    env.update(OMACVM_CLI_LINKS=" ".join(links), **(extra or {}))
    r = subprocess.run(["bash", "-c", 'source "$1/lib/mac.sh"; cli_for_bridge "$2"', "_", SRC, me], env=env)
    return r.returncode == 0


def test_only_the_linked_checkout(tmp_path):
    real = os.path.realpath(tmp_path)
    for d in ("installed", "worktree"):
        os.makedirs(f"{real}/{d}")
        open(f"{real}/{d}/omacvm", "w").close()
    os.symlink(f"{real}/installed/omacvm", f"{real}/link")
    links = [f"{real}/missing", f"{real}/link"]
    assert chosen(f"{real}/installed/omacvm", links)
    assert not chosen(f"{real}/worktree/omacvm", links)
    assert chosen(f"{real}/worktree/omacvm", links, {"OMACVM_SET_CLI": "1"})
    # No omacvm command anywhere: a clone run as ./omacvm.
    assert chosen(f"{real}/worktree/omacvm", [f"{real}/missing"])


def app_cli(tmp_path, name: str) -> str:
    """A stand-in OmacVM.app with its omacvm (Contents/Resources/omacvm/omacvm)."""
    p = f"{os.path.realpath(tmp_path)}/{name}.app/Contents/Resources/omacvm/omacvm"
    os.makedirs(os.path.dirname(p))
    open(p, "w").close()
    return p


def set_app(home: str, cli: str, test_identity: bool = False) -> str:
    env = dict(os.environ, HOME=home, OMACVM_TEST_IDENTITY="1" if test_identity else "")
    subprocess.run(["bash", "-c", 'source "$1/lib/mac.sh"; cli_file_app "$2"', "_", SRC, cli], env=env, check=True)
    folder = "omacvm-test" if test_identity else "omacvm"
    try:
        with open(f"{home}/Library/Application Support/{folder}/cli", encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def test_the_app_sets_and_follows_itself(tmp_path):
    home = str(tmp_path / "home")
    os.makedirs(home)
    a = app_cli(tmp_path, "OmacVM")
    assert set_app(home, a) == a                       # no file: the app's copy
    st = os.stat(f"{home}/Library/Application Support/omacvm/cli")
    assert st.st_mode & 0o077 == 0
    b = app_cli(tmp_path, "Moved/OmacVM")
    assert set_app(home, b) == b                       # moved or updated: follows
    os.remove(b)
    os.rmdir(os.path.dirname(b))
    assert set_app(home, a) == a                       # the old place is gone
    # The test identity writes only its own folder.
    t = app_cli(tmp_path, "OmacVM Test")
    assert set_app(home, t, test_identity=True) == t
    assert set_app(home, a) == a


def test_a_checkout_keeps_the_file(tmp_path):
    home = str(tmp_path / "home")
    sup = f"{home}/Library/Application Support/omacvm"
    os.makedirs(sup)
    co = f"{os.path.realpath(tmp_path)}/checkout/omacvm"
    os.makedirs(os.path.dirname(co))
    open(co, "w").close()
    with open(f"{sup}/cli", "w") as f:
        f.write(co + "\n")
    a = app_cli(tmp_path, "OmacVM")
    assert set_app(home, a) == co                      # a CLI install keeps its own
    os.remove(co)
    assert set_app(home, a) == a                       # unless it is gone
    # Never a path that is not an app's omacvm.
    with open(f"{sup}/cli", "w") as f:
        f.write("")
    assert set_app(home, co) == ""
