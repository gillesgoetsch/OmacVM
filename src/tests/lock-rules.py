#!/usr/bin/env python3
"""src/tests/lock-rules.sh's helper: asks each Python lock rule once, with
that test's stand-ins for Omarchy's shell and pgrep on PATH. One line per
rule: NAME locked|open, and for omacvm-displays the word of
guest/session-lock.sh it reads (session_state).

    python3 src/tests/lock-rules.py SRC
"""
import importlib.machinery
import importlib.util
import inspect
import pathlib
import sys

sys.dont_write_bytecode = True   # nothing written into the checkout
SRC = pathlib.Path(sys.argv[1])


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def ask(rule):
    """The rule's answer at once: no wait for a shell that does not answer."""
    now = {"wait": 0} if "wait" in inspect.signature(rule).parameters else {}
    return "locked" if rule(**now) else "open"


copies = load("copies", SRC / "omanotch/guest/copies.py")
panel = load("display_panel", SRC / "omanotch/guest/monitor/display-panel.py")
displays = load("omacvm_displays", SRC / "app/guest/omacvm-displays")
displays.SESSION_LOCK = SRC / "guest/session-lock.sh"
print("copies.py", ask(copies.session_locked))
print("display-panel.py", ask(panel.session_locked))
print("omacvm-displays", displays.session_state())
