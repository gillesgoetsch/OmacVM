#!/usr/bin/env python3
"""The Chrome renderer string override (50-omacvm-chrome.drirc): valid XML, only Chrome's and Chromium's
programs, no "virgl" in the string, installed where Mesa reads it (no VM needed).

    python3 src/app/guest/tests/test_chrome_drirc.py
"""
import pathlib
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[4]
DRIRC = ROOT / "src/app/guest/50-omacvm-chrome.drirc"
INSTALL = ROOT / "src/app/guest/install.sh"


class ChromeDrirc(unittest.TestCase):
    def setUp(self):
        self.root = ET.parse(DRIRC).getroot()
        apps = self.root.findall("./device/application")
        self.assertEqual(len(apps), 1)
        self.app = apps[0]

    def test_virgl_device_only(self):
        self.assertEqual(self.root.tag, "driconf")
        self.assertEqual([d.get("driver") for d in self.root.findall("device")], ["virtio_gpu"])

    def test_programs(self):
        rx = re.compile(self.app.get("executable_regexp"))
        # Mesa matches the program name: Google Chrome's /opt/google/chrome/chrome, Arch's /usr/lib/chromium/chromium
        for name in ("chrome", "chromium"):
            self.assertTrue(rx.fullmatch(name), name)
        for name in ("google-chrome", "chrome_crashpad_handler", "chromium-browser", "brave", "electron", "firefox",
                     "glmark2", "Hyprland", "deqp-gles3", "xchrome", "chromex"):
            self.assertIsNone(rx.search(name), name)

    def test_renderer_string(self):
        opts = {o.get("name"): o.get("value") for o in self.app.findall("option")}
        self.assertEqual(list(opts), ["force_gl_renderer"])
        self.assertTrue(opts["force_gl_renderer"])
        self.assertNotIn("virgl", opts["force_gl_renderer"].lower())   # Skia's check (GrGLCaps)

    def test_installed_where_mesa_reads(self):
        self.assertIn("install -Dm644 50-omacvm-chrome.drirc /usr/share/drirc.d/50-omacvm-chrome.conf",
                      INSTALL.read_text())


if __name__ == "__main__":
    unittest.main()
