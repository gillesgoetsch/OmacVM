"""src/tests/e2e/guest-cc.py (the release gate's driver of the control centre)
against the real control centre in a terminal: a pty rendered by pyte
instead of tmux, the fake Mac. Its reading of the screen (rows, the cursor,
the hint, questions) and its key presses must still fit the TUI after a
change to it; a change that breaks them breaks the gate. Skipped where
Textual or pyte is not installed."""
import fcntl
import importlib.util
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import threading
import time

import pytest

pytest.importorskip("textual")
pyte = pytest.importorskip("pyte")

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, HERE)
from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
COLS, LINES = 160, 50
BASIC = ["black", "red", "green", "brown", "blue", "magenta", "cyan", "white"]
KEYS = {"space": " ", "Escape": "\x1b", "Enter": "\r", "C-c": "\x03"}


class Answer(Exception):
    pass


class Terminal:
    """The control centre in a pty; the driver's screen() and keys() on it."""

    def __init__(self, env: dict) -> None:
        self.screen = pyte.Screen(COLS, LINES)
        self.stream = pyte.ByteStream(self.screen)
        self.lock = threading.Lock()
        # The real control centre on a pty of its own (no fork of this threaded process).
        self.fd, tty = pty.openpty()
        fcntl.ioctl(tty, termios.TIOCSWINSZ, struct.pack("HHHH", LINES, COLS, 0, 0))
        self.proc = subprocess.Popen(
            [sys.executable, "-c", "from omacvm_cc.controller import Controller\n"
             "from omacvm_cc.tui import ControlCentre\nControlCentre(Controller()).run()"],
            stdin=tty, stdout=tty, stderr=tty, cwd=os.path.join(ROOT, "src", "control"), env=env, start_new_session=True)
        os.close(tty)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self) -> None:
        while True:
            try:
                r, _, _ = select.select([self.fd], [], [], 0.2)
                if r:
                    d = os.read(self.fd, 65536)
                    if not d:
                        return
                    with self.lock:
                        self.stream.feed(d)
            except OSError:
                return

    def render(self, ansi: bool = False) -> str:
        """As `tmux capture-pane -p [-e]` gives it (background colours only)."""
        with self.lock:
            if not ansi:
                return "\n".join(self.screen.display)
            out = []
            for y in range(self.screen.lines):
                row, s, last = self.screen.buffer[y], "", None
                for x in range(self.screen.columns):
                    c = row[x]
                    if c.bg != last:
                        if c.bg == "default":
                            s += "\x1b[49m"
                        elif c.bg in BASIC:
                            s += f"\x1b[{40 + BASIC.index(c.bg)}m"
                        elif c.bg.startswith("bright") and c.bg[6:] in BASIC:
                            s += f"\x1b[{100 + BASIC.index(c.bg[6:])}m"
                        else:
                            s += "\x1b[48;2;0;0;0m"
                        last = c.bg
                    s += c.data
                out.append(s)
            return "\n".join(out)

    def keys(self, *k: str, target: str = "cc", gap: float = 0.08) -> None:
        for x in k:
            os.write(self.fd, KEYS.get(x, x).encode())
            time.sleep(gap)

    def stop(self) -> None:
        self.proc.kill()
        self.proc.wait()
        os.close(self.fd)


def driver(term: Terminal):
    spec = importlib.util.spec_from_file_location("guest_cc", os.path.join(ROOT, "src", "tests", "e2e", "guest-cc.py"))
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    g.screen = lambda target="cc", ansi=False: term.render(ansi)
    g.keys = term.keys
    g.alive = lambda target="cc": True
    sys.path.insert(0, os.path.join(ROOT, "src", "control"))
    from omacvm_cc import state as S
    g.TITLES = sorted({line.split("\t")[5] for line in open(os.path.join(ROOT, "src", "features.tsv"), encoding="utf-8")
                       if not line.startswith("#") and len(line.split("\t")) >= 7}
                      | {v.title for v in vars(S).values() if type(v).__name__ == "Feature"}, key=len, reverse=True)

    def out(ok, **kw):
        kw["ok"] = ok
        raise Answer(kw)
    g.out = out
    return g


def call(fn, *args) -> dict:
    with pytest.raises(Answer) as e:
        fn(list(args))
    return e.value.args[0]


@pytest.fixture
def world(tmp_path):
    mac, checks = FakeMac(), FakeChecks()
    env = dict(os.environ, **vm_env(str(tmp_path), mac.port, checks.path), TERM="xterm-256color", LANG="en_US.UTF-8")
    envf = env["OMACVM_ENV"]
    t = open(envf).read().replace("OMACVM_VM_TYPE=other", "OMACVM_VM_TYPE=app")
    open(envf, "w").write(t + "OMACVM_FEATURE_fast_network=off\nOMACVM_FEATURE_touch_id=off\n")
    mac.graphics = {"graphics": "auto", "next_start": "opengl", "this_start": "auto -> opengl"}

    def ended(j):   # the VM side of a job, as the real apply leaves it
        if j["action"] == "graphics":
            g = j["features"][0]
            mac.graphics = {"graphics": g, "next_start": "vulkan" if g == "vulkan" else "opengl", "this_start": "auto -> opengl"}
            return
        txt = open(envf).read()
        for f in j["features"]:
            k = "OMACVM_FEATURE_" + f.replace("-", "_")
            txt = re.sub(rf"^{k}=.*$", f"{k}={'on' if j['action'] == 'enable' else 'off'}", txt, flags=re.M)
        open(envf, "w").write(txt)
    mac.on_job_end = ended
    term = Terminal(env)
    g = driver(term)
    g.mac = mac
    ok, _, _ = g.watch(lambda s: "Mac linked" in s, 30)
    assert ok, term.render()
    yield g
    term.stop()
    mac.stop()
    checks.stop()


def test_rows_cursor_and_hint(world):
    g = world
    text = g.screen()
    names = [t for _, t in g.table(text)]
    assert names[:2] == ["OmacVM Bridge", "Wallpaper on the Mac"] and "Graphics" in names and "Touch ID" in names
    assert g.cursor_line(g.screen(ansi=True)) == g.table(text)[0][0], "the cursor starts on the first row"
    # The hint names its row: another row's state is not read from it.
    ok, text, _ = g.watch(lambda s: g.below_table(s).startswith("OmacVM Bridge: "), 10)
    assert ok, g.below_table(text)
    assert g.state_of("The Mac's clock", text)["on"] is None
    r = call(g.cmd_row, "The Mac's clock")
    assert r["ok"] and r["on"] == "on" and r["status"] == "works" and r["below"].startswith("The Mac's clock: "), r
    assert call(g.cmd_row, "No such row")["ok"] is False


def test_toggle_with_a_question(world):
    g = world
    r = call(g.cmd_toggle, "The Mac's clock", "off", "40")
    assert r["ok"] and r["after"]["on"] == "off" and not r["asked"], r
    r = call(g.cmd_toggle, "The Mac's clock", "on", "40")
    assert r["ok"] and r["after"]["status"] == "works", r
    r = call(g.cmd_toggle, "OmacVM Bridge", "off", "40")   # also turns off Wallpaper: asked first
    assert r["ok"] and "also turns off" in r["asked"], r
    r = call(g.cmd_toggle, "Fast network", "on", "40")
    assert r["ok"] and r["after"]["on"] == "on", r


def test_graphics_and_updates(world):
    g = world
    r = call(g.cmd_graphics, "opengl", "40")
    assert r["ok"] and r["after"]["note"].startswith("OpenGL:"), r
    r = call(g.cmd_graphics, "auto", "60")   # OpenGL -> Vulkan -> Automatic: two questions
    assert r["ok"] and len(r["steps"]) == 2 and r["after"]["note"].startswith("Automatic:"), r
    r = call(g.cmd_updates, "8")
    assert "Updates" in r["body"] and "Update checks" in r["body"], r


def test_job_limit_is_named(world):
    """The Bridge's job limit (429 rate): the control centre sends nothing more and says so in a
    note; the driver's answer names it instead of only "nothing happened" (the 3.0.5 gate)."""
    g = world
    g.mac.refuse_jobs = (429, "rate", "20 jobs in the last hour: try later")
    r = call(g.cmd_toggle, "The Mac's clock", "off", "40")
    assert not r["ok"] and "nothing happened" in r["error"], r
    assert any("try later" in t or "in the last hour" in t for t in r["trouble"]), r
