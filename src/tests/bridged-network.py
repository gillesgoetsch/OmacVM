#!/usr/bin/env python3
"""Guest profile/route behavior with temporary files and replaced nmcli/ip."""
import configparser
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "app/guest/omacvm-network"
NETWORK = runpy.run_path(str(SCRIPT))
LAN = "52:54:00:aa:bb:cc"


class GuestNetwork(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / "root"
        self.entries = Path(self.scratch.name) / "dmi"
        self.entries.mkdir()
        self.profiles = self.root / "etc/NetworkManager/system-connections"
        self.marker = self.root / "run/omacvm/bridged-network"
        self.net = Path(self.scratch.name) / "net"
        for name, address in (("management0", NETWORK["MANAGEMENT"]), ("lan0", LAN)):
            (self.net / name).mkdir(parents=True)
            (self.net / name / "address").write_text(address + "\n")

    def smbios(self, *strings):
        entry = self.entries / "11-0"
        entry.mkdir(exist_ok=True)
        (entry / "raw").write_bytes(bytes((11, 5, 0, 0, len(strings))) + b"\0".join(s.encode() for s in strings) + b"\0\0")

    def command(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root), "--entries", str(self.entries), *args], text=True, capture_output=True)

    def profile(self, name):
        result = configparser.ConfigParser()
        result.read(self.profiles / name)
        return result

    def test_default_is_unchanged(self):
        self.profiles.mkdir(parents=True)
        user = self.profiles / "Wired connection.nmconnection"
        user.write_text("user connection\n")
        collision = self.profiles / "omacvm-management.nmconnection"
        collision.write_text("not owned\n")
        self.assertEqual(self.command().returncode, 0)
        self.assertEqual(user.read_text(), "user connection\n")
        self.assertEqual(collision.read_text(), "not owned\n")
        self.assertFalse(self.marker.exists())

    def test_management_has_no_internet_or_dns_fallback(self):
        self.smbios("omacvm.bridged=" + LAN)
        result = self.command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker.read_text().strip(), LAN)
        management = self.profile("omacvm-management.nmconnection")
        lan = self.profile("omacvm-lan.nmconnection")
        self.assertEqual(management["ethernet"]["mac-address"], NETWORK["MANAGEMENT"])
        self.assertEqual(management["ipv4"]["method"], "manual")
        self.assertEqual(management["ipv4"]["address1"], "10.0.2.15/24")
        self.assertNotIn("gateway", management["ipv4"])
        for family in ("ipv4", "ipv6"):
            self.assertTrue(management[family].getboolean("never-default"))
            self.assertTrue(management[family].getboolean("ignore-auto-dns"))
            self.assertFalse(lan[family].getboolean("never-default"))
            self.assertFalse(lan[family].getboolean("ignore-auto-dns"))
        self.assertEqual(lan["ipv4"]["method"], "auto")
        self.assertEqual(lan["ethernet"]["mac-address"], LAN)
        for filename, _ in NETWORK["PROFILES"].values():
            self.assertEqual(stat.S_IMODE((self.profiles / filename).stat().st_mode), 0o600)
        before = {p.name: p.read_bytes() for p in self.profiles.iterdir()}
        self.assertEqual(self.command().returncode, 0)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.profiles.iterdir()})

    def test_off_waits_for_next_boot_and_removes_only_owned_profiles(self):
        self.smbios("omacvm.bridged=" + LAN)
        self.assertEqual(self.command().returncode, 0)
        user = self.profiles / "custom.nmconnection"
        user.write_text("user-owned\n")
        self.assertEqual(self.command("--off").returncode, 0)
        self.assertTrue(self.marker.exists())
        self.assertTrue((self.profiles / "omacvm-management.nmconnection").exists())
        (self.entries / "11-0/raw").unlink()
        self.assertEqual(self.command().returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertEqual([p.name for p in self.profiles.iterdir()], [user.name])
        self.assertEqual(user.read_text(), "user-owned\n")
        self.assertEqual(self.command().returncode, 0)

    def test_collision_and_malformed_marker_fail_without_overwriting(self):
        self.profiles.mkdir(parents=True)
        user = self.profiles / "omacvm-management.nmconnection"
        user.write_text("user-owned\n")
        self.smbios("omacvm.bridged=" + LAN)
        self.assertNotEqual(self.command().returncode, 0)
        self.assertEqual(user.read_text(), "user-owned\n")
        self.assertFalse(self.marker.exists())
        for marker in ("52:54:00:12:34:56", "not-a-mac", LAN + ";false"):
            self.smbios("omacvm.bridged=" + marker)
            self.assertNotEqual(self.command().returncode, 0)
            self.assertFalse(self.marker.exists())
        self.smbios("omacvm.bridged=" + LAN, "omacvm.bridged=" + LAN)
        self.assertNotEqual(self.command().returncode, 0)

    def checker(self, routes4="default via 192.0.2.1 dev lan0\n", routes6="", dns="yes",
                addresses4="2: lan0    inet 192.0.2.10/24 brd 192.0.2.255 scope global dynamic lan0\n",
                addresses6=""):
        responses = {
            ("ip", "-4", "route", "show", "default"): routes4,
            ("ip", "-6", "route", "show", "default"): routes6,
            ("ip", "-o", "-4", "address", "show", "dev", "lan0", "scope", "global"): addresses4,
            ("ip", "-o", "-6", "address", "show", "dev", "lan0", "scope", "global"): addresses6,
        }
        for kind, device in (("management", "management0"), ("lan", "lan0")):
            responses[("nmcli", "-g", "GENERAL.CON-UUID", "device", "show", device)] = NETWORK["PROFILES"][kind][1] + "\n"
        for setting in ("ipv4.never-default", "ipv4.ignore-auto-dns", "ipv6.never-default", "ipv6.ignore-auto-dns"):
            responses[("nmcli", "-g", setting, "connection", "show", "uuid", NETWORK["PROFILES"]["management"][1])] = dns + "\n"

        def output(command, **_):
            self.assertIn(tuple(command), responses, f"unexpected command: {command}")
            return responses[tuple(command)]
        return patch.object(NETWORK["subprocess"], "check_output", side_effect=output)

    def test_runtime_checks_reject_nat_fallback_and_lan_dhcp_failure(self):
        for routes4, routes6 in (("", ""), ("default via 10.0.2.2 dev management0\n", ""),
                                  ("default via 192.0.2.1 dev lan0\n", "default via fe80::2 dev management0\n")):
            with self.checker(routes4, routes6), self.assertRaises(ValueError):
                NETWORK["check"](LAN, self.net)
        with self.checker(dns="no"), self.assertRaises(ValueError):
            NETWORK["check"](LAN, self.net)

    def test_runtime_ipv6_default_rejects_tentative_and_dadfailed_addresses(self):
        for flags in ("tentative", "dadfailed", "tentative dadfailed"):
            with self.subTest(flags=flags), self.checker(
                    routes4="", routes6="default via fe80::1 dev lan0 proto ra\n", addresses4="",
                    addresses6=f"2: lan0    inet6 2001:db8::10/64 scope global dynamic {flags}\n"):
                with self.assertRaises(ValueError):
                    NETWORK["check"](LAN, self.net)

    def test_runtime_ipv6_only_is_ready_without_claiming_ipv4_dhcp(self):
        output = io.StringIO()
        with self.checker(routes4="", routes6="default via fe80::1 dev lan0 proto ra\n", addresses4="",
                          addresses6="2: lan0    inet6 2001:db8::10/64 scope global dynamic\n"), redirect_stdout(output):
            NETWORK["check"](LAN, self.net)
        self.assertIn("IPv6", output.getvalue())
        self.assertNotIn("IPv4", output.getvalue())

    def test_runtime_ipv4_default_requires_ipv4_address(self):
        with self.checker(addresses4="", addresses6="2: lan0    inet6 2001:db8::10/64 scope global dynamic\n"):
            with self.assertRaises(ValueError):
                NETWORK["check"](LAN, self.net)

    def test_runtime_ipv4_address_and_default_are_ready(self):
        output = io.StringIO()
        with self.checker(), redirect_stdout(output):
            NETWORK["check"](LAN, self.net)
        self.assertIn("IPv4", output.getvalue())
        self.assertNotIn("IPv6", output.getvalue())

    def test_runtime_ready_family_never_masks_management_default(self):
        with self.checker(routes6="default via fe80::2 dev management0\n"):
            with self.assertRaises(ValueError):
                NETWORK["check"](LAN, self.net)

    def test_runtime_dual_stack_reports_only_usable_families(self):
        for flags in ("tentative", ""):
            output = io.StringIO()
            with self.subTest(flags=flags), self.checker(
                    routes6="default via fe80::1 dev lan0 proto ra\n",
                    addresses6=f"2: lan0    inet6 2001:db8::10/64 scope global dynamic {flags}\n"), redirect_stdout(output):
                NETWORK["check"](LAN, self.net)
            self.assertIn("IPv4", output.getvalue())
            self.assertEqual("IPv6" in output.getvalue(), not flags)

    def test_live_failure_does_not_mark_configuration_ready(self):
        self.smbios("omacvm.bridged=" + LAN)
        arguments = [str(SCRIPT), "--root", str(self.root), "--entries", str(self.entries), "--sys-net", str(self.net), "--live"]
        with patch.object(sys, "argv", arguments), patch.object(NETWORK["subprocess"], "run", side_effect=subprocess.CalledProcessError(1, "nmcli")):
            with self.assertRaises(subprocess.CalledProcessError):
                NETWORK["main"]()
        self.assertFalse(self.marker.exists())

    def test_proxy_uses_private_host_not_lan_gateway(self):
        binary = Path(self.scratch.name) / "bin"
        binary.mkdir()
        ip = binary / "ip"
        ip.write_text("#!/bin/sh\nprintf 'default via 192.0.2.1 dev lan0 metric 100\\n'\n")
        ip.chmod(0o755)
        probe = binary / "probe"
        probe.write_text('#!/bin/sh\n[ "$1" = 10.0.2.2 ] && [ "$2" = 7890 ]\n')
        probe.chmod(0o755)
        record = Path(self.scratch.name) / "proxy.env"
        record.write_text("http_proxy=http://10.0.2.2:7890\n")
        env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ["PATH"],
                   OMACVM_PROXY_RECORD=str(record), OMACVM_BRIDGED_MARKER=str(self.marker),
                   OMACVM_PROXY_PROBE=str(probe), OMACVM_SYS_NET=str(self.net))
        script = SCRIPT.parents[2] / "guest/proxy-env"
        before = subprocess.run(["bash", str(script)], env=env, text=True, capture_output=True)
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertEqual(before.stdout, "")
        self.marker.parent.mkdir(parents=True)
        self.marker.write_text(LAN + "\n")
        bridged = subprocess.run(["bash", str(script)], env=env, text=True, capture_output=True)
        self.assertEqual(bridged.returncode, 0, bridged.stderr)
        self.assertIn("http_proxy=http://10.0.2.2:7890", bridged.stdout)
        self.assertNotIn("192.0.2.1", bridged.stdout)


if __name__ == "__main__":
    unittest.main()
