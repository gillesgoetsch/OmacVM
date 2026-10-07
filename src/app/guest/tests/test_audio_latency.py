#!/usr/bin/env python3
"""The sound delay the app tells the VM (omacvm-audio-latency), no VM needed.

    python3 src/app/guest/tests/test_audio_latency.py
"""
import importlib.machinery
import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[4]


def load():
    loader = importlib.machinery.SourceFileLoader(
        "omacvm_audio_latency", str(ROOT / "src/app/guest/omacvm-audio-latency"))
    spec = importlib.util.spec_from_loader("omacvm_audio_latency", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


lat = load()

# pactl -f json list cards, cut down: the VM's HDA card and a USB headset it was given.
CARDS = [
    {"name": "alsa_card.pci-0000_00_03.0", "ports": {
        "analog-output": {"latency_offset": "0 usec"},
        "analog-input-mic": {"latency_offset": "0 usec"}}},
    {"name": "alsa_card.usb-Generic_Headset-00", "ports": {
        "analog-output-headphones": {"latency_offset": "0 usec"}}},
]


class Parse(unittest.TestCase):
    def test_whole_ms_in_range(self):
        self.assertEqual(lat.parse_ms("163\n"), 163)
        self.assertEqual(lat.parse_ms("0"), 0)
        self.assertEqual(lat.parse_ms("1000"), 1000)

    def test_rejects_the_rest(self):
        for bad in ("", "-5", "12.5", "1001", "abc", "1e3", "\u00b2", "\u0661\u0662"):
            self.assertIsNone(lat.parse_ms(bad), bad)


class Ports(unittest.TestCase):
    def test_only_the_vm_card_outputs(self):
        self.assertEqual(lat.output_ports(CARDS), [("alsa_card.pci-0000_00_03.0", "analog-output")])

    def test_ports_as_a_list(self):
        cards = [{"name": "alsa_card.pci-0000_00_03.0", "ports": [{"name": "analog-output-speaker"}]}]
        self.assertEqual(lat.output_ports(cards), [("alsa_card.pci-0000_00_03.0", "analog-output-speaker")])

    def test_no_card(self):
        self.assertEqual(lat.output_ports([]), [])


class Apply(unittest.TestCase):
    def test_sets_microseconds_on_each_output(self):
        calls = []

        def fake(*args, capture=False):
            calls.append(args)
            return mock.Mock(returncode=0, stdout=__import__("json").dumps(CARDS))
        with mock.patch.object(lat, "pactl", fake):
            self.assertTrue(lat.apply(163, wait_s=0))
        self.assertIn(("set-port-latency-offset", "alsa_card.pci-0000_00_03.0", "analog-output", "163000"), calls)
        self.assertFalse(any("usb" in " ".join(c) for c in calls if c[0] == "set-port-latency-offset"))

    def test_takes_the_newest_kept_value(self):
        # The login unit read 286 (AirPods last time); the app sent 128 while
        # it waited for the card: 128 goes on the port.
        calls = []

        def fake(*args, capture=False):
            calls.append(args)
            return mock.Mock(returncode=0, stdout=__import__("json").dumps(CARDS))
        with mock.patch.object(lat, "pactl", fake):
            self.assertTrue(lat.apply(286, wait_s=0, latest=lambda: 128))
        self.assertIn(("set-port-latency-offset", "alsa_card.pci-0000_00_03.0", "analog-output", "128000"), calls)
        self.assertNotIn("286000", [c[-1] for c in calls])

    def test_no_pipewire_gives_up(self):
        with mock.patch.object(lat, "pactl", lambda *a, **k: mock.Mock(returncode=1, stdout="")):
            self.assertFalse(lat.apply(100, wait_s=0))


class Root(unittest.TestCase):
    def test_keeps_the_value_and_runs_each_session(self):
        with tempfile.TemporaryDirectory() as d:
            state = os.path.join(d, "lib", "audio-latency")
            run = os.path.join(d, "run")
            os.makedirs(os.path.join(run, "1000", "pulse"))
            open(os.path.join(run, "1000", "pulse", "native"), "w").close()
            os.makedirs(os.path.join(run, "1001"))          # no PipeWire: skipped
            os.makedirs(os.path.join(run, "0", "pulse"))    # root: skipped
            ran = []
            with mock.patch.object(lat, "STATE", state), mock.patch.object(lat, "RUN_USER", run), \
                    mock.patch.object(lat.os, "geteuid", lambda: 0), \
                    mock.patch.object(lat.pwd, "getpwuid", lambda uid: mock.Mock(pw_name=f"u{uid}")), \
                    mock.patch.object(lat.subprocess, "run", lambda cmd, **k: ran.append(cmd)):
                self.assertEqual(lat.main(["omacvm-audio-latency", "321"]), 0)
                self.assertEqual(lat.read_state(), 321)
            self.assertEqual(len(ran), 1)
            self.assertEqual(ran[0][:3], ["runuser", "-u", "u1000"])
            self.assertIn(f"XDG_RUNTIME_DIR={run}/1000", ran[0])
            self.assertEqual(ran[0][-1], "--apply")

    def test_bad_value_changes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            state = os.path.join(d, "audio-latency")
            with mock.patch.object(lat, "STATE", state), mock.patch.object(lat.os, "geteuid", lambda: 0):
                self.assertEqual(lat.main(["omacvm-audio-latency", "5000"]), 2)
            self.assertFalse(os.path.exists(state))

    def test_apply_without_a_value_does_nothing(self):
        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(lat, "STATE", os.path.join(d, "none")), \
                mock.patch.object(lat, "apply", lambda *a, **k: self.fail("applied")):
            self.assertEqual(lat.main(["omacvm-audio-latency", "--apply"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1, argv=[sys.argv[0]])
