"""Redaction: planted personal data must never survive into a report."""
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest  # noqa: E402

from omacvm_cc import report as R  # noqa: E402

TOKEN = "9f2c4e1ab7d3c8e6f0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b"
SSH_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq3Zorro0Testmann1Key2Fake3Data4Here5x zorro@zorro-mbp"


def known():
    k = R.Known()
    k.add("user", "zorro", "Zorro Testmann")
    k.add("host", "zorro-mbp", "Zorros-MacBook-Pro", "zorro-vm")
    k.add("vm", "Zorro's Omarchy")
    k.add("wifi", "ZorroNet 5G", "a4:2b:b0:11:22:33")
    k.add("bt", "Zorro's AirPods", "11:22:33:44:55:66")
    k.add("secret", TOKEN)
    k.add("home", "/home/zorro", "/Users/zorro")
    return k


FIXTURE = f"""
OK  Wi-Fi  ZorroNet 5G, -48 dBm (BSSID a4:2b:b0:11:22:33)
Oct 05 10:02:11 zorro-vm omacvm-gestures[812]: connect 10.211.55.2:47830 refused
Oct 05 10:02:12 zorro-vm omacvm-bridge-events[901]: Authorization: Bearer {TOKEN}
apply: VM 'Zorro's Omarchy' at 10.211.55.17, user zorro (Zorro Testmann)
Bluetooth: Zorro's AirPods (11:22:33:44:55:66) connected; also zorro’s airpods pro
path /home/zorro/.config/omacvm-bridge/token and /Users/zorro/Library/Logs/omacvm-bridge.log
key {SSH_KEY}
token={TOKEN[:40]} password: hunter2pass
mail zorro.testmann@example.com, ipv6 fe80::1c2b:3dff:fe4e:5f60 and 2a02:1210:abcd::42
uuid 5d3a2f53-e362-4d0f-9297-4e55da2fec76 serial "IOPlatformSerialNumber" = "C02ZK0ZZMD6R"
Zorros-MacBook-Pro.local said hi; ZORRO-MBP too; ｚｏｒｒｏ－ｍｂｐ in full width
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
-----END OPENSSH PRIVATE KEY-----
"""

PLANTED = ["zorro", "Testmann", "ZorroNet", "a4:2b:b0", "AirPods (11", "11:22:33:44:55:66", TOKEN[:16],
           "hunter2pass", "AAAAC3NzaC1lZDI1NTE5", "example.com", "10.211.55.17", "fe80::1c2b", "2a02:1210",
           "5d3a2f53", "C02ZK0ZZMD6R", "b3BlbnNzaC1rZXkt", "/home/", "/Users/"]


def test_nothing_planted_survives():
    text, counts = R.redact(FIXTURE, known())
    low = text.lower()
    for p in PLANTED:
        assert p.lower() not in low, (p, text)
    R.gate(text, known())   # must not raise
    assert counts["user"] >= 2 and counts["wifi"] >= 2 and counts["secret"] >= 2


def test_useful_parts_stay():
    text, _ = R.redact(FIXTURE, known())
    assert "<mac-parallels>:47830" in text
    assert "<ip-1>" in text
    assert "omacvm-gestures" in text
    assert "~/.config/omacvm-bridge/token" in text
    assert "10:02:11" in text   # times are not IPv6 addresses


def test_same_address_same_label():
    text, _ = R.redact("a 192.168.1.20 b 192.168.1.21 c 192.168.1.20", R.Known())
    assert text == "a <ip-1> b <ip-2> c <ip-1>"


def test_short_values_only_as_words():
    k = R.Known()
    k.add("user", "pi")
    text, _ = R.redact("pipewire runs for pi", k)
    assert text == "pipewire runs for <user>"


def test_long_paths_are_not_base64():
    p = "/usr/local/share/omacvm/bridge/guest/omacvmbridgeevents/extra/path"
    assert R.redact(p, R.Known())[0] == p


def test_gate_refuses_a_survivor():
    with pytest.raises(R.RedactionFailed):
        R.gate("hello ＺＯＲＲＯ－ＭＢＰ", known())


def test_counts_never_show_values():
    _, counts = R.redact(FIXTURE, known())
    line = R.taken_out(counts)
    assert "zorro" not in line.lower() and "user name" in line


def test_build_and_url():
    rep = R.build([("What happened", "zorro saw it"), ("Versions", "OmacVM 2.9.0"),
                   ("Logs (last 40 lines each)", "\n".join(f"line {i} at 10.211.55.{i % 200}" for i in range(400)))],
                  known(), "Gestures fail on zorro-mbp")
    assert rep.title == "Gestures fail on <host>"
    url, cut = R.issue_url(rep)
    assert cut and len(url) <= R.URL_MAX
    body = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)["body"][0]
    assert "### Versions" in body and "OmacVM 2.9.0" in body and "zorro" not in body.lower()
    assert body.count("```") % 2 == 0 or "pasted below" in body


def test_short_report_is_not_cut():
    rep = R.build([("Versions", "OmacVM 2.9.0")], R.Known(), "t")
    url, cut = R.issue_url(rep)
    assert not cut and url.startswith(R.ISSUES)


def test_ipv4_at_the_end_of_a_sentence():
    text, _ = R.redact("connect to 192.168.1.20. then peer 10.211.55.32. done (at 10.0.0.7.)", R.Known())
    assert "192.168" not in text and "10.211" not in text and "10.0.0.7" not in text, text
    assert text == "connect to <ip-1>. then peer <ip-2>. done (at <ip-3>.)"


def test_dotted_versions_are_not_addresses():
    for v in ("1.2.3.4.5", "kernel 6.12.10.1.2"):
        assert R.redact(v, R.Known())[0] == v


def test_product_words_are_not_personal():
    k = R.Known()
    k.add("vm", "Omarchy", "Omarchy ARM", "Zorro's Omarchy")
    k.add("host", "omarchy", "alarm", "omarchy.local", "zorro-vm")
    k.add("user", "root")
    text, counts = R.redact("Omarchy 4.0.3 · /usr/share/omarchy/x · omarchy-menu · alarm clock · "
                            "VM Zorro's Omarchy on zorro-vm", k)
    assert text.startswith("Omarchy 4.0.3 · /usr/share/omarchy/x · omarchy-menu · alarm clock · "), text
    assert "Zorro" not in text and "zorro-vm" not in text
    assert counts.get("vm") == 1 and counts.get("host") == 1
    R.gate(text, k)


def test_mac_addresses_without_separators():
    text, _ = R.redact("net0 001C42EE41A6 up; macaddr=a4b2c3d4e5f6; MAC address: A4B2C3D4E5F7; "
                       "qemu 525400123456; cisco 001c.42ee.41a6", R.Known())
    for v in ("001C42EE41A6", "a4b2c3d4e5f6", "A4B2C3D4E5F7", "525400123456", "001c.42ee.41a6"):
        assert v.lower() not in text.lower(), (v, text)


def test_short_commit_hashes_stay():
    t = "OmacVM: the release (1b5c3f3a9e01) and 0123456789ab"
    assert R.redact(t, R.Known())[0] == t


def test_device_owner_names_in_every_spelling():
    # The VM's user is not the Mac owner: only the Bluetooth names know "Gilles".
    k = R.Known()
    k.add("user", "tester", "Test User")
    k.add("bt", "Gilles\u2019s AirPods Pro", "Gilles's Magic Keyboard", "Anna\u2018s iPhone", "Jo\u02bcs Mouse")
    text = ("connected: Gilles\u2019s AirPods Pro; also Gilles's AirPods Pro and Gilles's Magic Keyboard\n"
            'json "name": "Gilles\\u2019s AirPods Pro", "owner": "\\u0047illes"\n'
            "hello Gilles, Anna and Jo; GILLES\u2019S stuff\n")
    out, _ = R.redact(text, k)
    R.gate(out, k)
    for name in ("Gilles", "gilles", "Anna", "Jo\u02bcs", "Jo's"):
        assert name not in out, (name, out)
    assert "<bt-device>" in out and "<user>" in out


def test_gate_sees_escapes_and_curly_apostrophes():
    k = R.Known()
    k.add("bt", "Gilles\u2019s AirPods")
    for leak in ("Gilles\\u2019s", "GILLES", "Gilles%27s", "Gill\\u0065s"):
        with pytest.raises(R.RedactionFailed):
            R.gate(leak, k)


@pytest.mark.parametrize("line,kept", [
    ("password: 'hunter2'", "password: '<secret>'"),
    ('password: "hunter 2 with spaces"', 'password: "<secret>"'),
    ("pass='x'", "pass='<secret>'"),
    ('"password": "hunter2"', '"password": "<secret>"'),
    ("{'api_key': 'abc123'}", "{'api_key': '<secret>'}"),
    ("[wifi]\npsk = 'Zorro PSK'", "[wifi]\npsk = '<secret>'"),
    ("db_password = s3cr3t", "db_password = <secret>"),
    ("auth-token: abc", "auth-token: <secret>"),
    ("credentials: 'x y'", "credentials: '<secret>'"),
    # A command line in the journal: quotes escaped once or more.
    ('bash -c "echo {\\"passphrase\\": \\"s3cr3t pass\\"}"', 'bash -c "echo {\\"passphrase\\": \\"<secret>\\"}"'),
    ('psk = \\\\\\"Zorro PSK\\\\\\"', 'psk = \\\\\\"<secret>\\\\\\"'),
])
def test_quoted_secrets(line, kept):
    out, counts = R.redact(line, R.Known())
    assert out == kept and counts.get("secret") == 1


def test_secret_words_inside_other_words_stay():
    for line in ("keyboard: us", "passes=3", "bypass: on", "monkey: 1"):
        assert R.redact(line, R.Known())[0] == line


def test_bluez_percent_encoded_and_zero_padded():
    k = R.Known()
    k.add("wifi", "Goetsch Home")
    out, _ = R.redact("dev_30_7A_D2_32_1E_AE paired; ssid Goetsch%20Home / Goetsch+Home / Goetsch_Home; "
                      "peer 010.211.055.032 and 192.168.001.010.", k)
    R.gate(out, k)
    assert "30_7A" not in out and "Goetsch" not in out and "055" not in out and "001.010" not in out
    assert "<hw-addr>" in out and out.count("<wifi>") == 3


def test_escapes_of_control_characters_stay_escaped():
    assert R.redact("ESC \\u001b[0m", R.Known())[0] == "ESC \\u001b[0m"


def test_mac_name_gives_its_owner():
    """ComputerName "Anna's MacBook Pro": Anna is a user name, also alone."""
    k = R.Known()
    k.add("user", "tester")
    k.add("host", "Anna’s MacBook Pro", "Annas-MacBook-Pro")
    out, _ = R.redact("Anna's iPhone paired; Anna said hi; host Annas-MacBook-Pro.local", k)
    R.gate(out, k)
    assert "Anna" not in out and "Annas" not in out
    assert "MacBook" not in R.redact("Mac: Anna's MacBook Pro", k)[0].replace("<host>", "")


def test_device_owner_without_known_values():
    """The Bridge is down (or a guest's own device): the owner's name before a
    device word goes by its form alone; product and plain words stay."""
    k = R.Known()
    for line, want in [
        ("bluetoothd: Anna’s AirPods connected", "<user>'s AirPods connected"),
        ("Anna's iPhone paired", "<user>'s iPhone paired"),
        ("James' Magic Keyboard", "<user>' Magic Keyboard"),
        ("host Annas-MacBook-Pro.local", "host <user>s-MacBook-Pro.local"),
    ]:
        out, counts = R.redact(line, k)
        assert want in out and counts.get("user") == 1, out
    for line in ("Magic Keyboard connected", "Apple's Magic Mouse", "My iPhone", "Parallels-Mac", "omarchy-MacBook"):
        assert R.redact(line, k)[0] == line


@pytest.mark.parametrize("line,gone", [
    ("unit omacvm-wifi@ZorroNet\\x205G.service started", "ZorroNet"),
    ("user J\\xc3\\xbcrgen logged in", "rgen"),
    ("user J\\xfcrgen (latin-1)", "rgen"),
    ('json "ZorroNet\\\\x205G"', "ZorroNet"),
])
def test_hex_escapes_decoded(line, gone):
    k = R.Known()
    k.add("wifi", "ZorroNet 5G")
    k.add("user", "Jürgen")
    out, _ = R.redact(line, k)
    R.gate(out, k)
    assert gone not in out, out


def test_hex_escapes_gate():
    k = R.Known()
    k.add("user", "Jürgen")
    with pytest.raises(R.RedactionFailed):
        R.gate("J\\xc3\\xbcrgen", k)
    assert R.redact("ESC \\x1b[0m", R.Known())[0] == "ESC \\x1b[0m"


@pytest.mark.parametrize("line,kept", [
    ("iwctl --passphrase hunter2 station wlan0 connect X", "iwctl --passphrase <secret> station wlan0 connect X"),
    ("nmcli dev wifi connect X password hunter2", "nmcli dev wifi connect X password <secret>"),
    ("nmcli con modify x wifi-sec.psk hunter2", "nmcli con modify x wifi-sec.psk <secret>"),
    ("nmcli con modify x 802-11-wireless-security.psk 'two words'", "nmcli con modify x 802-11-wireless-security.psk <secret>"),
    ("tool -password Hunter --x", "tool -password <secret> --x"),
    ("Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic <secret>"),
    ("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 used", "token <secret> used"),
    ("github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuv", "<secret>"),
    ("gho_ABCDEFGHIJKLMNOPQRSTUVWX12", "<secret>"),
])
def test_secret_as_next_argument_and_tokens(line, kept):
    out, counts = R.redact(line, R.Known())
    assert out == kept and counts.get("secret") == 1, out


def test_secret_words_in_plain_text_stay():
    for line in ("the password was wrong", "password incorrect", "Basic setup done", "Basic Configuration",
                 "--password-file /etc/x", "psk mismatch"):
        assert R.redact(line, R.Known())[0] == line


def test_mac_known_without_bridge(monkeypatch):
    """omacvm report on the Mac with the Bridge down: names from the Mac itself
    (full and first name, the Mac's name's owner, Bluetooth via system_profiler)."""
    import json
    from omacvm_cc import collect, bridge
    sp = json.dumps({"SPBluetoothDataType": [{"controller_properties": {"controller_address": "AA:BB:CC:DD:EE:FF"},
                                               "device_connected": [{"Bea’s AirPods Pro": {"device_address": "11:22:33:44:55:66"}}],
                                               "device_not_connected": [{"Living Room Speaker": {}}]}]})
    outs = {"id": "Al Testmann", "dscl": "FirstName: Al\nNo such key: LastName", "scutil": "Cleo’s MacBook Pro",
            "system_profiler": sp}

    def fake_run(cmd, timeout=10.0):
        return outs.get(cmd[0], "")
    monkeypatch.setattr(collect, "run", fake_run)

    def down(self, *a, **kw):
        raise OSError("connection refused")
    monkeypatch.setattr(bridge.Bridge, "call", down)
    k = collect.mac_known("/nonexistent/omacvm")
    text = ("Al opened it; Al Testmann; Cleo's iPad; Cleo alone; Bea alone; Bea's AirPods Pro (11:22:33:44:55:66); "
            "Living Room Speaker on; Dana's AirPods")
    out, _ = R.redact(text, k)
    R.gate(out, k)
    for name in ("Al ", "Testmann", "Cleo", "Bea", "Living Room", "11:22:33", "Dana"):
        assert name not in out, (name, out)
    assert "No such key" not in " ".join(v for _, v in k.items())


# ---- review round 4: names in other languages, the Bridge's own lines, Wi-Fi on en1 ----

BRIDGE_LOG = """\
2026-10-05 05:01:02 omacvm-bridge: bluetooth (tick): power=1 permission=allowed connected=["AirPods Pro von Dana", "iPhone de Jean-Luc", "Dana's Galaxy Buds", "Cuffie di Marco", "Koptelefoon van Jan"]
2026-10-05 05:01:03 omacvm-bridge: bluetooth (events): power=1 permission=allowed connected=[]
2026-10-05 05:01:04 omacvm-bridge: wifi (event): power=1 connected=1 ssid=Zuhause Dana ch=36/5GHz rssi=-51
2026-10-05 05:01:05 omacvm-bridge: wifi (tick): power=1 connected=1 ssid=Sunrise_5GHz_2A1B3C ch=6/2GHz rssi=-60
2026-10-05 05:01:06 omacvm-bridge: wifi (tick): power=1 connected=0 ssid=<null> ch=- rssi=<null>
2026-10-05 05:01:07 omacvm-bridge: wifi (tick): power=1 connected=1 ssid=Chez Jean-Luc ch=11/2GHz rssi=-70
2026-10-05 05:01:08 omacvm-bridge: /bluetooth/connect from 10.211.55.5: connected Casque de Jean-Luc
2026-10-05 05:01:09 omacvm-bridge: /bluetooth/disconnect from 10.211.55.5: Thuis Speaker Jan not connected
2026-10-05 05:01:10 omacvm-bridge: /bluetooth/connect from 10.211.55.5 failed: Écouteurs Zoé did not connect (is it on and in range?)
2026-10-05 05:01:11 omacvm-bridge: Wi-Fi password for Casa di Marco requested by 10.211.55.5: granted
2026-10-05 05:01:12 omacvm-bridge: control: GET /omacvm/status from 10.211.55.5 (Dana's Omarchy): 200
2026-10-05 05:01:13 omacvm-bridge: control: GET /omacvm/hello from 10.211.55.7 (-): 200
2026-10-05 05:01:14 omacvm-bridge: /bluetooth/connect from 10.211.55.5: the device did not connect (is it on and in range?)
"""


def test_bridge_log_names_go_whole():
    """The Bridge is down, so nothing is known: its own lines still lose every
    device name, Wi-Fi name and VM name, in any language."""
    out, counts = R.redact(BRIDGE_LOG, R.Known())
    for gone in ("Dana", "Jean", "Luc", "Marco", "Jan", "Galaxy", "Zuhause", "Sunrise", "2A1B3C", "Chez", "Casque",
                 "Thuis", "Zoé", "Écouteurs", "Casa", "Omarchy", "Koptelefoon", "Cuffie"):
        assert gone not in out, (gone, out)
    assert "connected=[<bt-device>, <bt-device>, <bt-device>, <bt-device>, <bt-device>]" in out
    assert "connected=[]" in out
    assert "ssid=<wifi> ch=36/5GHz rssi=-51" in out and "ssid=<null> ch=-" in out
    assert "connected <bt-device>" in out and "<bt-device> not connected" in out
    assert "<bt-device> did not connect (is it on and in range?)" in out
    assert "Wi-Fi password for <wifi> requested by" in out
    assert "(<vm>): 200" in out and "(-): 200" in out
    assert "the device did not connect" in out
    assert counts["bt"] == 8 and counts["wifi"] == 4 and counts["vm"] == 1


def test_bridge_lines_known_values_too():
    """With the names known as well, nothing breaks and the gate passes."""
    k = R.Known()
    k.add("wifi", "Zuhause Dana")
    k.add("bt", "AirPods Pro von Dana")
    out, _ = R.redact(BRIDGE_LOG, k)
    R.gate(out, k)
    assert "ssid=<wifi> ch=36" in out


def test_bridge_list_without_its_end():
    out, _ = R.redact('bluetooth (tick): power=1 permission=allowed connected=["AirPods von Dana", "iPh', R.Known())
    assert "Dana" not in out and "connected=[<bt-device>]" in out


@pytest.mark.parametrize("line,gone", [
    ("AirPods von Dana verbunden", "Dana"),                    # DE
    ("AirPods Pro von Dana connected", "Dana"),
    ("Mac mini von Gilles ist bereit", "Gilles"),
    ("Apple Watch von Dana Müller", "Müller"),
    ("iPhone de Jean-Luc connecté", "Jean"),                   # FR
    ("iPhone d’Anne connecté", "Anne"),
    ("MacBook Air de Zoé", "Zoé"),
    ("AirPods di Marco connessi", "Marco"),                    # IT
    ("iPad del Marco", "Marco"),
    ("iPhone van Jan verbonden", "Jan"),                       # NL
    ("AirPods van Sanne", "Sanne"),
    ("host MacBook-Pro-von-Dana.local", "Dana"),               # host name forms
    ("host Mac-mini-von-Gilles.local", "Gilles"),
    ("host iPhone-de-Jean-Luc", "Luc"),
    ("host MacBook-Air-van-Jan", "Jan"),
    ("Dana's Galaxy Buds connected", "Dana"),                  # not Apple
    ("Dana's Headphones", "Dana"),
    ("Dana's WH-1000XM5", "Dana"),
    ("Annas iPhone", "Anna"),
])
def test_device_owner_in_other_languages(line, gone):
    out, counts = R.redact(line, R.Known())
    assert gone not in out and counts.get("user", 0) >= 1, out


@pytest.mark.parametrize("line", [
    "AirPods do not connect", "the Mac de facto", "iPhone da capo", "Magic Keyboard von Apple",
    "the guest's Mouse", "Bridge's Mac helper", "Hyprland's Mouse input", "OmacVM Gestures' Trackpad",
    "Apple's Magic Mouse", "the Mac's Bluetooth", "OmacVM's Bridge", "Omarchy's Settings", "Gestures Trackpad on",
    "Settings iPhone", "Parallels Desktop's Tools", "MacBook Pro (16-inch) M4 Max", "macOS 26's menu",
])
def test_device_owner_plain_text_stays(line):
    assert R.redact(line, R.Known())[0] == line


def test_known_mac_name_in_other_languages_gives_its_owner():
    k = R.Known()
    k.add("user", "tester")
    k.add("host", "Mac mini von Gilles", "Mac-mini-von-Gilles")
    k.add("bt", "iPhone de Jean-Luc")
    out, _ = R.redact("Gilles said hi; Jean-Luc too; host Mac-mini-von-Gilles.local", k)
    R.gate(out, k)
    assert "Gilles" not in out and "Jean-Luc" not in out


def test_wifi_device_from_hardware_ports(monkeypatch):
    """Wi-Fi is en1 on a Mac mini, Studio or iMac (en0 is Ethernet): the
    names come from the Wi-Fi port networksetup lists, in any language."""
    from omacvm_cc import collect
    ports = ("Hardware Port: Ethernet\nDevice: en0\nEthernet Address: 11:22:33:44:55:66\n\n"
             "Hardware Port: Thunderbolt Bridge\nDevice: bridge0\nEthernet Address: N/A\n\n"
             "Hardware Port: WLAN\nDevice: en1\nEthernet Address: 11:22:33:44:55:67\n")
    calls = []

    def fake_run(cmd, timeout=10.0):
        calls.append(cmd)
        if cmd[:2] == ["networksetup", "-listallhardwareports"]:
            return ports
        if cmd[:2] == ["networksetup", "-listpreferredwirelessnetworks"]:
            if cmd[2] == "en1":
                return "Preferred networks on en1:\n\tZuhause Dana\n\tSunrise_5GHz_2A1B3C\n"
            return f"{cmd[2]} is not a Wi-Fi interface.\n** Error: Error obtaining wireless information.\n"
        return ""
    monkeypatch.setattr(collect, "run", fake_run)
    assert collect.mac_wifi_names() == ["Zuhause Dana", "Sunrise_5GHz_2A1B3C"]
    assert ["networksetup", "-listpreferredwirelessnetworks", "en0"] not in calls

    # No port called Wi-Fi/WLAN/AirPort (a language we do not know): every
    # device is asked, and only a Wi-Fi one answers with networks.
    ports2 = ports.replace("WLAN", "Réseau sans fil")
    monkeypatch.setattr(collect, "run", lambda cmd, timeout=10.0: ports2 if cmd[1] == "-listallhardwareports" else fake_run(cmd))
    assert collect.mac_wifi_names() == ["Zuhause Dana", "Sunrise_5GHz_2A1B3C"]


def test_mac_report_bridge_down_planted_names(monkeypatch):
    """omacvm report on a Mac mini (Wi-Fi on en1) with the Bridge down and
    system_profiler listing nothing: the Bridge log's names in DE/FR/IT/NL
    all go, and the report passes the gate."""
    from omacvm_cc import collect, bridge
    outs = {"id": "Gilles Tester", "dscl": "No such key: FirstName", "scutil": "Mac mini von Gilles",
            "system_profiler": "{}"}

    def fake_run(cmd, timeout=10.0):
        if cmd[:2] == ["networksetup", "-listallhardwareports"]:
            return "Hardware Port: Ethernet\nDevice: en0\n\nHardware Port: Wi-Fi\nDevice: en1\n"
        if cmd[:2] == ["networksetup", "-listpreferredwirelessnetworks"]:
            return "Preferred networks on en1:\n\tThuis van Jan\n" if cmd[2] == "en1" else "en0 is not a Wi-Fi interface.\n"
        return outs.get(cmd[0], "")
    monkeypatch.setattr(collect, "run", fake_run)

    def down(self, *a, **kw):
        raise OSError("connection refused")
    monkeypatch.setattr(bridge.Bridge, "call", down)
    k = collect.mac_known("/nonexistent/omacvm")
    log = BRIDGE_LOG + "2026-10-05 05:02:00 omacvm-bridge: wifi (tick): power=1 connected=1 ssid=Thuis van Jan ch=1/2GHz rssi=-40\n"
    rep = R.build([("Logs", log + "Gilles opened it on Mac-mini-von-Gilles.local\n")], k, "Gilles' problem")
    for gone in ("Gilles", "Dana", "Jean", "Marco", "Jan", "Zuhause", "Sunrise", "Thuis", "Chez", "Casa", "Galaxy"):
        assert gone not in rep.text + rep.title, (gone, rep.text)


def test_device_word_as_a_known_value():
    """A phone's hotspot named "iPhone" or "MacBook" among the Wi-Fi names:
    it does not break up the owner forms, and is not taken out by itself."""
    k = R.Known()
    k.add("wifi", "iPhone", "MacBook", "AirPods Pro", "iPhone 15", "Zuhause Dana")
    assert k.wifi == ["Zuhause Dana"]
    out, _ = R.redact("MacBook-Pro-von-Dana.local; iPhone-de-Jean-Luc; my iPhone; Zuhause Dana", k)
    R.gate(out, k)
    assert "Dana" not in out and "Jean" not in out and "my iPhone" in out, out


# ---- final review: names that are plain words, readable logs, more Bridge lines ----

def test_a_user_called_max_is_taken_out():
    """Max is a plain word (AirPods Max, M4 Max) and one of the most common
    first names: as the user's name it is always a known value."""
    k = R.Known()
    k.add("user", "max", "Max Muster", "Max")
    k.add("bt", "AirPods von Max", "AirPods Max")
    assert [v.casefold() for v in k.user] == ["max", "max muster", "muster"] and k.bt == []
    text = ("AirPods von Max connected; Max's iPhone; iPhone de Max; Hi Max; ssh max@10.211.55.5; "
            "Max Muster wrote; MAX in capitals; chip Apple M4 Max; AirPods Max connected; iPhone 15 Pro Max")
    out, counts = R.redact(text, k)
    R.gate(out, k)
    assert "Muster" not in out and "max@" not in out and "Hi Max" not in out and "von Max" not in out, out
    assert "<user>'s iPhone" in out and "AirPods von <user>" in out and "Hi <user>" in out
    assert "Apple M4 Max" in out and "AirPods Max connected" in out and "iPhone 15 Pro Max" in out, out


def test_full_names_with_plain_words():
    k = R.Known()
    k.add("user", "marshall", "Marshall Swift", "Ludwig van Beethoven", "user")
    names = [v.casefold() for v in k.user]
    assert "marshall" in names and "swift" not in names and "van" not in names and "user" not in names, names
    out, _ = R.redact("Marshall Swift and Marshall; Ludwig van Beethoven; Swift 6.2 builds; the user name", k)
    R.gate(out, k)
    assert "Marshall" not in out and "Ludwig" not in out and "Beethoven" not in out, out
    assert "Swift 6.2 builds" in out and "the user name" in out


def test_owner_named_like_a_plain_word_without_known_values():
    for line, gone in [("AirPods von Max verbunden", "Max"), ("Max's iPhone", "Max"), ("iPhone de Max", "Max"),
                       ("Marshall's Headphones", "Marshall")]:
        out, _ = R.redact(line, R.Known())
        assert gone not in out, out
    for line in ("AirPods Max connected", "MacBook Pro M4 Max", "Marshall Major IV connected", "max 5 retries"):
        assert R.redact(line, R.Known())[0] == line


def test_known_host_and_vm_names_of_plain_words():
    """A host or VM name like "MacBook-Pro" is no one's; one called "Max" or
    "Work" is kept, as a whole word ("network" stays)."""
    k = R.Known()
    k.add("host", "MacBook-Pro", "max")
    k.add("vm", "Work", "Mac mini")
    assert k.host == ["max"] and k.vm == ["Work"]
    out, _ = R.redact("VM Work on max; network up; homework; MacBook-Pro; Mac mini", k)
    R.gate(out, k)
    assert out == "VM <vm> on <host>; network up; homework; MacBook-Pro; Mac mini", out


def test_wifi_names_only_as_whole_words():
    k = R.Known()
    k.add("wifi", "Light", "Garden", "ZorroNet 5G")
    text = ("backlight on; keyboard-light 40%; nightlight; Light connected; ssid=Garden ch=1; gardener; "
            "joined ZorroNet 5G; ZorroNet_5G")
    out, _ = R.redact(text, k)
    R.gate(out, k)
    assert out.startswith("backlight on; keyboard-light 40%; nightlight; <wifi> connected; ssid=<wifi> ch=1; gardener; ")
    assert "Zorro" not in out, out


@pytest.mark.parametrize("line", [
    "Chromium's GPU process crashed", "Firefox's WebGL is off", "Walker's Menu", "Waybar's Clock", "What's New",
    "Let's Encrypt", "There's A problem", "It's Fine", "Here's What", "Hyprlock's Fingerprint", "Docker's Network",
])
def test_contractions_and_app_names_stay(line):
    assert R.redact(line, R.Known())[0] == line


@pytest.mark.parametrize("line", [
    "virtio-gpu 0000:00:02.0: [drm] initialized", "pci 0000:00:1f.3 audio", "Using key: /etc/omacvm/key",
    "key: none", "token: (null)", "password: not set", "api_key = false", "password: ''", 'token=""',
])
def test_pci_addresses_and_empty_keys_stay(line):
    assert R.redact(line, R.Known())[0] == line


def test_ipv6_still_goes():
    out, _ = R.redact("peer fe80::1c2b:3dff:fe4e:5f60 and 2a02:1210:abcd::42 and abcd:12:34", R.Known())
    assert "fe80" not in out and "2a02" not in out and "abcd" not in out, out


BRIDGE_MORE = """\
2026-10-05 07:01:02 omacvm-bridge: audio: output=Kopfhörer von Jürgen (bluetooth) vol=0.5 muted=0 input=MacBook Pro Microphone (built-in) vol=0.8 muted=0 devices=4
2026-10-05 07:01:03 omacvm-bridge: audio: output=MacBook Pro Speakers (built-in) vol=0.5 muted=0 input=Danas Mikro (2) (usb) vol=1.0 muted=1 devices=3
2026-10-05 07:01:04 omacvm-bridge: audio: output=- input=- devices=0
2026-10-05 07:01:05 omacvm-bridge: camera: on (iPhone-Kamera von Dana)
2026-10-05 07:01:06 omacvm-bridge: camera: back: Danas Webcam
2026-10-05 07:01:07 omacvm-bridge: camera: on (FaceTime HD Camera)
2026-10-05 07:01:08 omacvm-bridge: camera: off (no VM reads it)
2026-10-05 07:01:09 omanotch: guest 3 is VM "Danas Omarchy"
2026-10-05 07:01:10 omanotch: strip serves guest 3 ("Zoés Linux"), was guest 2
2026-10-05 07:01:11 omanotch: guest 4 is VM (name not readable)
"""


def test_bridge_audio_camera_and_omanotch_lines_go_whole():
    out, counts = R.redact(BRIDGE_MORE, R.Known())
    for gone in ("Jürgen", "Kopfhörer", "Danas", "Mikro", "Dana", "Webcam", "Zoé"):
        assert gone not in out, (gone, out)
    assert "output=<audio-device> (bluetooth) vol=0.5" in out
    assert "input=MacBook Pro Microphone (built-in)" in out and "output=MacBook Pro Speakers (built-in)" in out
    assert "input=<audio-device> (usb) vol=1.0" in out and "output=- input=- devices=0" in out
    assert "camera: on (<camera>)" in out and "camera: back: <camera>" in out
    assert "camera: on (FaceTime HD Camera)" in out and "camera: off (no VM reads it)" in out
    assert 'guest 3 is VM "<vm>"' in out and 'strip serves guest 3 ("<vm>"), was guest 2' in out
    assert "guest 4 is VM (name not readable)" in out
    assert counts["audio"] == 2 and counts["camera"] == 2 and counts["vm"] == 2


def test_known_names_in_angle_brackets():
    k = R.Known()
    k.add("user", "dana", "Dana Keller")
    k.add("host", "dana-keller")
    out, _ = R.redact("From: <dana>, host <dana-keller>, <Dana Keller>; label <user> stays", k)
    R.gate(out, k)
    assert "dana" not in out.lower() and "keller" not in out.lower() and "label <user> stays" in out, out
    with pytest.raises(R.RedactionFailed):
        R.gate("hello <dana>", k)


@pytest.mark.parametrize("line,gone", [
    ("iPhone (Dana) connected", "Dana"),
    ("AirPods Pro (Dana Keller)", "Keller"),
    ("Omarchy von Dana started", "Dana"),
    ("VM Danas Omarchy", "Dana"),
    ("AirPods von Hans Peter Müller", "Müller"),
    ("Apple Watch von Anna Maria Rossi", "Rossi"),
])
def test_more_owner_forms(line, gone):
    out, counts = R.redact(line, R.Known())
    assert gone not in out and counts.get("user", 0) >= 1, out


@pytest.mark.parametrize("line", [
    "iPhone (USB) connected", "Magic Keyboard (Bluetooth)", "MacBook Pro (16-inch) M4 Max", "AirPods (2)",
    "Omarchy von Apple", "iPhone (Pro Max)",
])
def test_brackets_that_are_no_owner_stay(line):
    assert R.redact(line, R.Known())[0] == line


# Put together here, so no token-shaped text sits in the repository.
@pytest.mark.parametrize("token", [
    "sk-" + "ant-api03-" + "Zz9fake" * 6,
    "xo" + "xb-" + "0" * 10 + "-" + "fake-not-a-token",
    "AK" + "IA" + "FAKE" * 4,
    "gl" + "pat-" + "fake" * 5,
])
def test_more_token_forms(token):
    out, counts = R.redact(f"export X={token[:4]}; using {token} now", R.Known())
    assert token not in out and "using <secret> now" in out, out


# ---- re-check after round 6: Wi-Fi neighbours, Finnish, lower-case hosts, plain-word users ----

def test_wifi_name_inside_a_neighbours_name():
    """A Wi-Fi name with a capital inside, a digit or a space goes also in a
    neighbour's name ("ZorroNet-5G"); a plain one-word name only whole."""
    k = R.Known()
    k.add("wifi", "ZorroNet", "Zorro Home", "Zorro5", "Light", "garden")
    text = ("ZorroNet-5G; ZorroNets; Zorro Home-Ext; Zorro5-ext; "
            "backlight; keyboard-light; Light-2; gardener; garden-party; Light on")
    out, _ = R.redact(text, k)
    R.gate(out, k)
    assert "Zorro" not in out, out
    assert out.endswith("backlight; keyboard-light; Light-2; gardener; garden-party; <wifi> on"), out


@pytest.mark.parametrize("line,gone", [
    ("Annan AirPods connected", "Annan"), ("Mikon iPhone", "Mikon"), ("Jussin MacBook Pro", "Jussin"),
    ("Kallen iPad", "Kallen"), ("Päivin Apple Watch", "Päivin"),
])
def test_finnish_genitive_owner(line, gone):
    out, n = R.redact(line, R.Known())
    assert gone not in out and out.startswith("<user> "), out


@pytest.mark.parametrize("line", [
    "Open iPhone Mirroring", "Golden AirPods", "Green iPhone case", "Meinen AirPods verbinden", "Mein iPhone",
    "Kitchen iPad", "Main iPhone", "Then iPhone asks", "Geen iPhone", "Ein iPhone", "Screen iPad",
])
def test_words_ending_in_n_before_a_device_stay(line):
    assert R.redact(line, R.Known())[0] == line


def test_lower_case_host_name_forms():
    # nothing known
    for line, want in [("maxs-macbook-pro.local", "<user>s-macbook-pro.local"),
                       ("annas-macbook-pro", "<user>s-macbook-pro"),
                       ("mac-mini-von-max.local", "mac-mini-von-<user>.local"),
                       ("macbook-pro-de-max", "macbook-pro-de-<user>"),
                       ("my-macbook-pro", "my-macbook-pro"), ("works-iphone", "works-iphone"),
                       ("iphone-do-not-disturb", "iphone-do-not-disturb")]:
        assert R.redact(line, R.Known())[0] == want, line
    # known host names give their owner as a user name
    for host, owner in [("Maxs-MacBook-Pro", "Max"), ("annas-macbook-pro", "anna"),
                        ("mac-mini-von-max", "max"), ("Annan-MacBook-Pro", "Annan")]:
        k = R.Known()
        k.add("host", host)
        assert owner in k.user, (host, k.user)
    k = R.Known()
    k.add("host", "Maxs-MacBook-Pro", "mac-mini-von-max")
    out, _ = R.redact("Hi Max; ssh max@10.211.55.5 from mac-mini-von-max; Maxs-MacBook-Pro; max size", k)
    R.gate(out, k)
    assert out == "Hi <user>; ssh <user>@<ip-1> from mac-mini-von-<user>; <host>; max size", out


def test_plain_word_user_only_where_it_is_a_name():
    k = R.Known()
    k.add("user", "max", "Max Muster")
    stay = "max size; set to max; max_connections=100; MAX_FPS; maximum; --max-old-space; Max-Planck"
    out, _ = R.redact(stay, k)
    R.gate(out, k)
    assert out == stay, out
    for line, want in [("user max logged in", "user <user> logged in"), ("User: max", "User: <user>"),
                       ("login=max", "login=<user>"), ("USER=max", "USER=<user>"), ("sudo -u max ls", "sudo -u <user> ls"),
                       ("uid=1000(max) gid=1000(max)", "uid=1000(<user>) gid=1000(<user>)"),
                       ("max:x:1000:1000::/home/max:/bin/bash", "<user>:x:1000:1000::~:/bin/bash"),
                       ("chown max:max /x", "chown <user>:<user> /x"), ("ssh max@omarchy", "ssh <user>@omarchy"),
                       ("max's files", "<user>'s files"), ("Hi Max,", "Hi <user>,"), ("Max Muster wrote", "<user> wrote")]:
        out, _ = R.redact(line, k)
        R.gate(out, k)
        assert out == want, (line, out)


def test_gate_still_refuses_a_plain_word_user_left_as_a_name():
    k = R.Known()
    k.add("user", "max")
    with pytest.raises(R.RedactionFailed):
        R.gate("hello Max", k)
    with pytest.raises(R.RedactionFailed):
        R.gate("ssh max@host", k)
    R.gate("max size", k)


# ---- review of a0b814b: OmacVM's own lines never keep a plain-word user ----

SRC = os.path.join(os.path.dirname(__file__), "..", "..")
MSG_CALL = re.compile(r'\b(?:log|echo|bad|ok|warn|die|usage)\s+((?:"(?:[^"\\]|\\.)*"\s*)+)')
# Lines that print the user outside such a call, and the journal forms.
MORE_LINES = ['user       $U ($FULL), hostname $HOST',               # build.sh's summary
              '  "user": {"name": "$U", "full_name": "$FULL"},',      # build.sh's manifest
              '{"user": "$U"}', "user '$U'", "OWNER=\"$U\"",
              "session opened for user $U(uid=1000) by $U(uid=1000)",
              "Accepted publickey for $U from 10.0.0.9 port 52144 ssh2",
              "sudo:     $U : TTY=pts/0 ; PWD=/root ; USER=root ; COMMAND=/usr/bin/true",
              "sudo:     $U : 3 incorrect password attempts ; TTY=pts/0 ; PWD=/ ; USER=root"]


def omacvm_messages_with_user() -> list:
    """Every OmacVM message (log/echo/bad/ok/warn/die/usage) whose text
    prints the desktop user, from the scripts themselves."""
    out = []
    for d, _, files in os.walk(SRC):
        for f in files:
            if not f.endswith(".sh"):
                continue
            path = os.path.join(d, f)
            for n, line in enumerate(open(path, errors="replace"), 1):
                if line.lstrip().startswith("#"):
                    continue
                for m in MSG_CALL.finditer(line):
                    for s in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1)):
                        if re.search(r"\$\{?U\b", s) and s.strip() not in ("$U", "${U}"):
                            out.append((f"{os.path.relpath(path, SRC)}:{n}", s))
    return out


def fill(msg: str, user: str) -> str:
    msg = re.sub(r"\$\{U\}|\$U\b", user, msg)
    msg = re.sub(r"\$\{\w+:\+([^}]*)\}", r"\1", msg)   # ${had:+, OmacVM $had} as when set
    return re.sub(r"\$\{[^}]*\}|\$\([^)]*\)|\$\w+", "x", msg)


def test_every_omacvm_message_with_the_user_finds_the_known_ones():
    found = {where.split(":")[0] for where, _ in omacvm_messages_with_user()}
    for f in ("guest/check.sh", "guest/install.sh", "bridge/guest/install.sh", "cmd/apply.sh",
              "prebuilt/guest/generalize.sh", "cmd/build.sh"):
        assert f in found, found


@pytest.mark.parametrize("user", ["max", "marshall", "pro", "mesa", "work", "home"])
def test_every_omacvm_message_loses_a_plain_word_user(user):
    """A login that is a plain word ("max") still goes from every line
    OmacVM prints with it: check's "not running for max", the installers'
    "installed for max", apply's "user max", generalize's "home of max"."""
    k = R.Known()
    k.add("user", user)
    assert R.plain_user("user", k.user[0])
    msgs = [w for _, w in omacvm_messages_with_user()] + MORE_LINES
    for msg in msgs:
        line = fill(msg, user)
        rep = R.build([("omacvm check", line)], k, "Report")   # the gate passes
        body = "\n".join(rep.text.splitlines()[2:-1])   # "### heading", fence, body, fence
        want, _ = R.redact(fill(msg, "<user>"), k)
        assert body == want, (msg, body)
    with pytest.raises(R.RedactionFailed):
        R.gate("Hyprland: not running for max: log in first", Known_max())
    with pytest.raises(R.RedactionFailed):
        R.gate('{"user": "max"}', Known_max())


def Known_max() -> "R.Known":
    k = R.Known()
    k.add("user", "max")
    return k


def test_plain_word_user_places_keep_plain_text():
    k = Known_max()
    stay = "max size; set to max; max_connections=100; Apple M4 Max; AirPods Max; maxed out; max(1, 2)"
    out, _ = R.redact(stay, k)
    R.gate(out, k)
    assert out == stay, out


def test_host_owner_keeps_a_name_that_ends_in_s():
    """"Thomas-MacBook-Pro": Thomas, not only "Thoma"."""
    k = R.Known()
    k.add("host", "Thomas-MacBook-Pro")
    assert "Thomas" in k.user, k.user
    out, _ = R.redact("Thomas wrote; ssh thomas@omarchy; Thomas's iPhone", k)
    R.gate(out, k)
    assert out == "<user> wrote; ssh <user>@omarchy; <user>'s iPhone", out


def test_json_web_tokens_go():
    """The e2e check: a JWT got through whole (its middle part says {"sub":"juergen"})."""
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJqdWVyZ2VuIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    out, counts = R.redact(f"session {jwt} refreshed; OmacVM 2.9.2 stays", known())
    assert out == "session <secret> refreshed; OmacVM 2.9.2 stays", out
    assert counts["secret"] == 1


def test_sudo_working_folder_is_no_secret():
    """The e2e: sudo's PWD=/ came out as PWD=<secret> and counted as a secret
    taken out. The working folder stays (a home in it still goes)."""
    k = R.Known()
    k.add("user", "zorro")
    out, counts = R.redact("sudo[812]:    zorro : TTY=pts/0 ; PWD=/ ; USER=root ; COMMAND=/usr/bin/true", k)
    assert out == "sudo[812]:    <user> : TTY=pts/0 ; PWD=/ ; USER=root ; COMMAND=/usr/bin/true", out
    assert "secret" not in counts, counts
    out, counts = R.redact("sudo:    zorro : PWD=/home/zorro/src ; USER=root", k)
    assert out == "sudo:    <user> : PWD=~/src ; USER=root", out
    assert "secret" not in counts, counts
    # Only the shell's own PWD, and only a path.
    for line, gone in (("PWD=hunter2", "PWD=<secret>"), ("pwd=/etc/x", "pwd=<secret>"), ("db_pwd: s3cr3t!", "db_pwd: <secret>")):
        out, counts = R.redact(line, k)
        assert out == gone and counts.get("secret") == 1, (line, out, counts)


def test_a_match_left_as_it_is_is_not_counted():
    out, counts = R.redact("key: none; token: (null); Using key: /etc/ssh/ssh_host_ed25519_key", known())
    assert out == "key: none; token: (null); Using key: /etc/ssh/ssh_host_ed25519_key", out
    assert "secret" not in counts, counts
