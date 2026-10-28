#!/usr/bin/env python3
"""Chrome's and Brave's video switches in their flags files (src/app/guest/browser-video-encode.py),
both groups: encode (--enable-features=AcceleratedVideoEncoder,VaapiVideoEncoder) and decode
(--disable-features=AcceleratedVideoDecodeLinuxZeroCopyGL, 3.2.11). The files live in a temp folder;
the user's process (a fork + setuid as root) is stood in for by this one (src/tests/home-links.sh runs
the real one as root).

    python3 src/app/guest/tests/test_browser_video_flags.py
"""
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[4]
SCRIPT = ROOT / "src/app/guest/browser-video-encode.py"
ZC = "AcceleratedVideoDecodeLinuxZeroCopyGL"
DIS = "--disable-features=" + ZC
ENC = "--enable-features=AcceleratedVideoEncoder,VaapiVideoEncoder"


class FakeOwner:
    """The user's process, stood in for: every file as this process."""

    def __init__(self, home):
        self.home = home

    def run(self, path, fn):
        return fn(path)


class Flags(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.home = t / "home"
        self.etc = t / "etc"
        (self.home / ".config").mkdir(parents=True)
        self.etc.mkdir()
        self.mark = t / "var/video-encode-flags.json"
        spec = importlib.util.spec_from_file_location("bve", SCRIPT)
        self.m = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"OMACVM_VIDEO_FLAGS_MARK": str(self.mark)}):
            spec.loader.exec_module(self.m)
        home, etc = str(self.home), str(self.etc)
        self.m.browser_files = lambda h: {
            "chromium": [f"{etc}/chromium-flags.conf", f"{home}/.config/chromium-flags.conf"],
            "chrome": [f"{etc}/chrome-flags.conf", f"{home}/.config/chrome-flags.conf"],
            "brave": [f"{home}/.config/brave-flags.conf"],
        }
        self.installed = {"chrome", "brave"}
        self.m.wanted = lambda owner, name, files: name in self.installed
        self.m.Owner = lambda user: FakeOwner(home)

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        """(exit code, printed text) of browser-video-encode.py USER ARGS..."""
        out = []
        with mock.patch.object(sys, "argv", ["browser-video-encode.py", "alice", *args]), \
                mock.patch("builtins.print", lambda *a, **k: out.append(" ".join(map(str, a)))):
            try:
                self.m.main()
                code = 0
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
        return code, "\n".join(out)

    def user(self, name="chrome"):
        return self.home / ".config" / f"{name}-flags.conf"

    def read(self, p):
        return p.read_text() if p.exists() else None

    def marker(self):
        return json.loads(self.mark.read_text()) if self.mark.exists() else []

    def test_new_line_in_the_users_files(self):
        self.run_script("on", "decode")
        self.assertEqual(self.read(self.user("chrome")), DIS + "\n")
        self.assertEqual(self.read(self.user("brave")), DIS + "\n")
        self.assertIsNone(self.read(self.user("chromium")), "Chromium decodes through V4L2: not touched")
        self.assertEqual(sorted(e["switch"] for e in self.marker()), ["--disable-features="] * 2)
        self.assertEqual(self.run_script("check", "decode"), (0, "on"))

    def test_merged_into_the_last_switch_nothing_else_changes(self):
        self.user().write_text("# --disable-features=InAComment\n--ozone-platform=wayland\n"
                               "--disable-features=Foo --enable-features=Bar  --flag=x\n")
        self.run_script("on", "decode")
        self.assertEqual(self.read(self.user()), "# --disable-features=InAComment\n--ozone-platform=wayland\n"
                         "--disable-features=Foo," + ZC + " --enable-features=Bar  --flag=x\n")
        self.run_script("on", "decode")   # again (every apply): the same file
        self.assertEqual(self.read(self.user()).count(ZC), 1)

    def test_the_effective_switch_in_etc(self):
        etc = self.etc / "chrome-flags.conf"
        etc.write_text("--disable-features=Foo\n")
        self.user().write_text("--enable-features=Bar\n")
        self.run_script("on", "decode")
        self.assertEqual(self.read(etc), "--disable-features=Foo," + ZC + "\n")
        self.assertEqual(self.read(self.user()), "--enable-features=Bar\n")

    def test_the_users_own_zero_copy_is_kept(self):
        self.user().write_text("--enable-features=Bar," + ZC + "\n")
        self.run_script("on", "decode")
        self.assertEqual(self.read(self.user()), "--enable-features=Bar," + ZC + "\n")
        code, text = self.run_script("check", "decode")
        self.assertEqual(code, 0)
        self.assertIn("zero copy kept by the user's own flags: chrome", text)

    def test_zero_copy_turned_on_later_takes_ours_out(self):
        self.run_script("on", "decode")
        self.user().write_text(self.read(self.user()) + "--enable-features=" + ZC + "\n")
        self.run_script("on", "decode")
        self.assertEqual(self.read(self.user()), "--enable-features=" + ZC + "\n")

    def test_off_takes_out_only_what_was_added(self):
        self.user().write_text("--disable-features=Foo\n")
        self.run_script("on", "decode")
        self.run_script("off", "decode")
        self.assertEqual(self.read(self.user()), "--disable-features=Foo\n")
        self.assertIsNone(self.read(self.user("brave")), "a file OmacVM made goes when it is empty")
        self.assertEqual(self.marker(), [])

    def test_groups_touch_only_their_own_entries(self):
        self.run_script("on")              # encode, the default group
        self.run_script("on", "decode")
        self.assertEqual(self.read(self.user()), ENC + "\n" + DIS + "\n")
        self.run_script("off")
        self.assertEqual(self.read(self.user()), DIS + "\n")
        self.assertEqual({e["switch"] for e in self.marker()}, {"--disable-features="})
        self.run_script("on")
        self.run_script("off", "decode")
        self.assertEqual(self.read(self.user()), ENC + "\n")
        self.assertEqual(self.run_script("check")[0], 0)
        self.assertEqual(self.run_script("check", "decode"), (1, "missing in: chrome, brave"))

    def test_marker_of_an_older_version(self):
        # Up to 3.2.10 the entries had no switch: they are the encode group's.
        self.user().write_text(ENC + "\n")
        self.mark.parent.mkdir(parents=True)
        self.mark.write_text(json.dumps([{"file": str(self.user()), "created": True,
                                          "features": ["AcceleratedVideoEncoder", "VaapiVideoEncoder"]}]))
        self.run_script("on", "decode")
        self.assertEqual(self.read(self.user()), ENC + "\n" + DIS + "\n")
        self.run_script("off")
        self.assertEqual(self.read(self.user()), DIS + "\n")

    def test_marker_entries_that_name_other_features_are_ignored(self):
        self.user().write_text("--disable-features=Foo," + ZC + "\n")
        self.mark.parent.mkdir(parents=True)
        self.mark.write_text(json.dumps([{"file": str(self.user()), "switch": "--disable-features=",
                                          "features": ["Foo"], "created": False},
                                         {"file": "/etc/passwd", "switch": "--disable-features=",
                                          "features": [ZC], "created": True}]))
        self.run_script("off", "decode")
        self.assertEqual(self.read(self.user()), "--disable-features=Foo," + ZC + "\n")

    def test_a_linked_file_keeps_its_link(self):
        dots = self.home / "dotfiles"
        dots.mkdir()
        (dots / "chrome-flags.conf").write_text("--disable-features=Foo\n")
        self.user().symlink_to(dots / "chrome-flags.conf")
        self.run_script("on", "decode")
        self.assertTrue(self.user().is_symlink())
        self.assertEqual((dots / "chrome-flags.conf").read_text(), "--disable-features=Foo," + ZC + "\n")

    def test_no_browser(self):
        self.installed = set()
        self.assertEqual(self.run_script("check", "decode"), (0, "no browser"))
        self.run_script("on", "decode")
        self.assertIsNone(self.read(self.user()))

    def test_usage(self):
        self.assertNotEqual(self.run_script("on", "nonsense")[0], 0)


if __name__ == "__main__":
    unittest.main()
