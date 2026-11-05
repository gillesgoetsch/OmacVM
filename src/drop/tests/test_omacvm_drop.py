#!/usr/bin/env python3
"""Drag and drop's VM side (src/drop/guest/omacvm-drop) without a VM:
the Mac's lines checked, the uri-list's encoding, where a drop goes (the app
under the pointer through a stand-in helper, Downloads when late, locked, no
taker or no helper), Downloads never overwriting, free space.
  python3 src/drop/tests/test_omacvm_drop.py      (CI: the guest job)"""

import hashlib
import importlib.machinery
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "guest" / "omacvm-drop"
loader = importlib.machinery.SourceFileLoader("omacvm_drop", str(SRC))
spec = importlib.util.spec_from_loader("omacvm_drop", loader)
D = importlib.util.module_from_spec(spec)
loader.exec_module(D)

ID = "0123456789abcdef"


def line(items, age=10, i=ID):
    return json.dumps({"t": "drop", "id": i, "age": age, "items": [{"name": n, "bytes": b} for n, b in items]})


class Lines(unittest.TestCase):
    def test_names(self):
        for ok in ("a.txt", "a b #%?.txt", "Grüße.pdf", "x" * 255):
            self.assertTrue(D.name_ok(ok), ok)
        for bad in ("", ".", "..", "a/b", "a\nb", "a\x00b", "a\x7f", "x" * 256, "é" * 128, None, 5):
            self.assertFalse(D.name_ok(bad), repr(bad))

    def test_drop_line(self):
        d = D.parse_drop(line([("a.txt", 5), ("b c.png", 7)], age=30))
        self.assertEqual(d, {"id": ID, "age": 30, "items": [("a.txt", 5), ("b c.png", 7)]})

    def test_drop_line_refused(self):
        self.assertIsNone(D.parse_drop(line([("a", 1)], i="../../etc/x")))
        self.assertIsNone(D.parse_drop(line([("a", 1)], i="0123456789ABCDEF")))
        self.assertIsNone(D.parse_drop(line([("../a", 1)])))
        self.assertIsNone(D.parse_drop(line([])))
        self.assertIsNone(D.parse_drop(line([("f%d" % i, 1) for i in range(257)])))
        self.assertIsNone(D.parse_drop(line([("a", 1)], age=-1)))
        self.assertIsNone(D.parse_drop("not json"))
        self.assertIsNone(D.parse_drop(json.dumps({"t": "hello", "v": 1})))

    def test_uri_list_percent_encoded(self):
        u = D.uri_list(Path("/run/omacvm/drop") / ID, ["a b.txt", "50%#1?.txt", "Grüße.pdf"])
        self.assertEqual(u.split("\r\n")[:3], [
            f"file:///run/omacvm/drop/{ID}/a%20b.txt",
            f"file:///run/omacvm/drop/{ID}/50%25%231%3F.txt",
            f"file:///run/omacvm/drop/{ID}/Gr%C3%BC%C3%9Fe.pdf",
        ])
        self.assertTrue(u.endswith("\r\n"))


class Place(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.share, self.dl = t / "share", t / "Downloads"
        (self.share / ID).mkdir(parents=True)
        self.dl.mkdir()
        (self.share / ID / "a.txt").write_bytes(b"hello from the Mac")
        (self.share / ID / "b.bin").write_bytes(os.urandom(300000))
        self.helper = t / "helper"
        self.calls = t / "calls"
        D.notify = lambda text: self.notes.append(text)
        D.RUNTIME = t
        self.notes = []

    def tearDown(self):
        self.tmp.cleanup()

    def fake_helper(self, answer, rc):
        self.helper.write_text(f"#!/bin/sh\ncat \"$1\" > '{self.calls}'\necho '{answer}'\nexit {rc}\n")
        self.helper.chmod(0o755)

    def drop(self, age=10):
        return D.parse_drop(line([("a.txt", 18), ("b.bin", 300000)], age=age))

    def run_place(self, age=10, locked=False):
        return D.place(self.drop(age), 5, locked=lambda: locked, helper=str(self.helper), share=self.share, target=self.dl)

    def test_app_takes_it(self):
        self.fake_helper("app", 0)
        self.assertEqual(self.run_place(), ("app", ""))
        self.assertEqual(self.calls.read_bytes().decode(),
                         f"file://{self.share}/{ID}/a.txt\r\nfile://{self.share}/{ID}/b.bin\r\n")
        self.assertEqual(os.listdir(self.dl), [])

    def test_no_taker_downloads(self):
        self.fake_helper("none", 3)
        to, why = self.run_place()
        self.assertEqual((to, why), ("downloads", "no app took them"))
        for n in ("a.txt", "b.bin"):
            self.assertEqual(hashlib.sha256((self.dl / n).read_bytes()).hexdigest(),
                             hashlib.sha256((self.share / ID / n).read_bytes()).hexdigest())
        self.assertEqual(self.notes, ["2 files from the Mac in Downloads"])

    def test_late_downloads_without_helper(self):
        self.fake_helper("app", 0)
        to, why = self.run_place(age=1600)
        self.assertEqual(to, "downloads")
        self.assertIn("late", why)
        self.assertFalse(self.calls.exists())

    def test_locked_downloads_without_helper(self):
        self.fake_helper("app", 0)
        self.assertEqual(self.run_place(locked=True), ("downloads", "the screen is locked"))
        self.assertFalse(self.calls.exists())

    def test_no_helper(self):
        to, why = self.run_place()
        self.assertEqual(to, "downloads")
        self.assertIn("not built", why)

    def test_helper_error(self):
        self.fake_helper("error the pointer did not reach the overlay (a grab?)", 1)
        to, why = self.run_place()
        self.assertEqual(to, "downloads")
        self.assertIn("grab", why)

    def test_never_overwrites(self):
        self.fake_helper("none", 3)
        (self.dl / "a.txt").write_text("mine")
        (self.dl / "a (2).txt").write_text("mine too")
        self.run_place()
        self.assertEqual((self.dl / "a.txt").read_text(), "mine")
        self.assertEqual((self.dl / "a (2).txt").read_text(), "mine too")
        self.assertEqual((self.dl / "a (3).txt").read_bytes(), b"hello from the Mac")

    def test_missing_files_failed(self):
        self.fake_helper("app", 0)
        (self.share / ID / "b.bin").unlink()
        self.assertEqual(self.run_place()[0], "failed")

    def test_no_space_failed(self):
        self.fake_helper("none", 3)
        real = os.statvfs

        class S:
            f_bavail, f_frsize = 1, 4096
        D.os.statvfs = lambda p: S()
        try:
            to, why = self.run_place()
        finally:
            D.os.statvfs = real
        self.assertEqual(to, "failed")
        self.assertIn("free space", why)
        self.assertEqual(os.listdir(self.dl), [])

    def test_free_name(self):
        (self.dl / "x").write_text("")
        (self.dl / ".hidden").write_text("")
        self.assertEqual(D.free_name(self.dl, "x"), "x (2)")
        self.assertEqual(D.free_name(self.dl, ".hidden"), ".hidden (2)")
        self.assertEqual(D.free_name(self.dl, "new.txt"), "new.txt")


if __name__ == "__main__":
    unittest.main(verbosity=1)
