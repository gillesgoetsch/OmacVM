"""What goes into a problem report, in the VM and on the Mac: checks,
versions, the feature table and recent OmacVM logs; nothing else (no
environment dumps, no config files, no shell history). And the personal
values the redaction must take out (report.Known).

Runs on the Mac too (macOS's python3 3.9): stdlib only."""
from __future__ import annotations

import base64
import getpass
import json
import os
import platform
import pwd
import re
import socket
import subprocess

from .report import Known

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def run(cmd: list, timeout: float = 10.0) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return ANSI.sub("", r.stdout)
    except (OSError, subprocess.TimeoutExpired):
        return ""


def tail(path: str, n: int = 40) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return ""


def full_name(user: str) -> str:
    try:
        return pwd.getpwnam(user).pw_gecos.split(",")[0]
    except KeyError:
        return ""


def check_lines(checks) -> str:
    """ok lines are counted, the others listed."""
    ok = sum(1 for c in checks if c.status == "ok")
    out = [f"{ {'fail': 'FAIL', 'warn': 'WARN'}.get(c.status, 'skip')} {c.side:3} {c.feature or '-':16} {c.name}: {c.detail}"
           f"{' (needs a person)' if c.human else ''}" for c in checks if c.status != "ok"]
    return "\n".join(out + [f"{ok} checks ok"])


# ---- in the VM ----

def vm_known(local, bridge=None, hello=None) -> Known:
    k = Known()
    user = getpass.getuser()
    k.add("user", user, full_name(user), local.env.get("OMACVM_USER", ""))
    owner = local.env.get("OMACVM_USER", "")
    if owner:
        k.add("user", full_name(owner))
    host = socket.gethostname()
    k.add("host", host, host.split(".")[0])
    try:
        with open("/etc/hostname", encoding="utf-8") as f:
            k.add("host", f.read().strip())
    except OSError:
        pass
    b64 = local.env.get("OMACVM_VM_NAME_B64", "")
    if b64:
        try:
            k.add("vm", base64.b64decode(b64).decode("utf-8", "replace"))
        except ValueError:
            pass
    k.add("home", os.path.expanduser("~"))
    try:
        with open(bridge.token_file if bridge else os.path.expanduser("~/.config/omacvm-bridge/token"), encoding="utf-8") as f:
            k.add("secret", f.read().strip())
    except (OSError, AttributeError):
        pass
    # Wi-Fi and Bluetooth names the Mac shows this VM (also known ones nearby).
    if bridge is not None:
        for path, fn in (("/state", wifi_values), ("/scan?cached=1", scan_values), ("/bluetooth", bt_values)):
            try:
                for kind, v in fn(bridge.call("GET", path, timeout=4.0)):
                    k.add(kind, v)
            except Exception:   # offline Mac: nothing more to know
                pass
    return k


def wifi_values(state: dict):
    for key in ("ssid", "bssid"):
        if state.get(key):
            yield "wifi", state[key]


def scan_values(scan: dict):
    for n in scan.get("networks", []) if isinstance(scan, dict) else []:
        if isinstance(n, dict):
            for key in ("ssid", "bssid"):
                if n.get(key):
                    yield "wifi", n[key]


def bt_values(bt: dict):
    for d in bt.get("devices", []) if isinstance(bt, dict) else []:
        if isinstance(d, dict):
            if d.get("name"):
                yield "bt", d["name"]
            if d.get("address"):
                yield "bt", d["address"]


def vm_versions(local, hello=None) -> str:
    def first(*cmds) -> str:
        for c in cmds:
            v = run(c, 5).strip().splitlines()
            if v:
                return v[0]
        return "?"
    vendor = open_text("/sys/class/dmi/id/sys_vendor") or "?"
    product = open_text("/sys/class/dmi/id/product_name")
    mem = ""
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            kb = int(f.readline().split()[1])
            mem = f"{round(kb / 1048576)} GB"
    except (OSError, ValueError, IndexError):
        pass
    lines = [f"OmacVM {local.version} in the VM ({local.vm_type or '?'})"]
    if hello is not None:
        lines.append(f"OmacVM {hello.omacvm or '?'} on the Mac · macOS {hello.macos or '?'} · {hello.chip or '?'}")
    else:
        lines.append("the Mac did not answer")
    lines += [f"{vendor} {product}".strip() + (f" · {mem} VM" if mem else ""),
              f"Omarchy {first(['omarchy-version'])} · kernel {platform.release()} · {first(['pacman', '-Q', 'mesa'])}",
              f"Python {platform.python_version()} · {textual_version(first)}"]
    return "\n".join(lines)


def textual_version(first) -> str:
    """The Textual the control centre uses: OmacVM's own copy (vendor.py),
    or pacman's from before 3.0.6."""
    try:
        from . import vendor
        for name, _ in vendor.wheels()[0]:
            if name.startswith("textual-"):
                return f"Textual {name.split('-')[1]} (OmacVM's own)"
    except Exception:
        pass
    return first(['pacman', '-Q', 'python-textual'])


def open_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


# The check service (omacvm-check@) runs its probes with sudo: each run
# logs "sudo[pid]: ... COMMAND=..." and pam session lines, which can fill
# the whole excerpt. They say nothing about a problem: left out.
NOISE = re.compile(r"^\S+ (?:sudo\[\d+\]:|\S+\[\d+\]: pam_unix\(sudo(?:-i)?:session\))")


def quiet(lines: list, n: int) -> list:
    """The last n lines without the check service's sudo noise."""
    return [x for x in lines if not NOISE.match(x)][-n:]


def vm_logs(n: int = 40) -> str:
    out = []
    for scope in ("system", "user"):
        cmd = ["journalctl", "--no-pager", "-o", "short-iso", "-n", str(n * 5), "-u", "omacvm-*", "-u", "notchcast.service"]
        if scope == "user":
            cmd.insert(1, "--user")
        text = run(cmd, 10).strip()
        if text and "-- No entries --" not in text:
            # "<time> <host> <unit>[pid]: text" -> "<time> <unit>: text"
            lines = []
            for line in text.splitlines():
                p = line.split(" ", 2)
                lines.append(f"{p[0]} {p[2]}" if len(p) == 3 else line)
            lines = quiet(lines, n)
            if not lines:
                continue
            out.append(f"-- {scope} --\n" + "\n".join(lines))
    return "\n".join(out)


def vm_sections(local, rows, checks, hello=None, job_lines=None, what: str = "") -> list:
    table = "\n".join(f"{r.feature.name:16} {'on ' if r.on else 'off'} {r.status.value:13} {r.note}" for r in rows)
    sections = [("What happened", what or "_Say what you did and what you saw._"),
                ("Versions", vm_versions(local, hello)),
                ("Features", table),
                ("omacvm check", check_lines(checks) if checks is not None else "the checks did not run")]
    if job_lines:
        sections.append(("The last job", "\n".join(job_lines[-20:])))
    sections.append(("Logs (last 40 lines each)", vm_logs()))
    return sections


# ---- on the Mac ----

def mac_bt_values(text: str):
    """Bluetooth devices this Mac knows (system_profiler SPBluetoothDataType
    -json: device_connected, device_not_connected, ...): names and addresses."""
    try:
        data = json.loads(text or "{}")
    except ValueError:
        return
    for item in data.get("SPBluetoothDataType", []) if isinstance(data, dict) else []:
        for key, devs in item.items() if isinstance(item, dict) else ():
            if not key.startswith("device_") or not isinstance(devs, list):
                continue
            for d in devs:
                for name, props in d.items() if isinstance(d, dict) else ():
                    yield "bt", name
                    if isinstance(props, dict) and props.get("device_address"):
                        yield "bt", props["device_address"]


def user_names(user: str) -> list:
    """This Mac user's full name, its first word (also a short one, "Al"),
    and the first and last names the account has."""
    full = run(["id", "-F"]).strip()
    names = [full, full.split()[0] if full else ""]
    out = run(["dscl", ".", "-read", "/Users/" + user, "FirstName", "LastName"])
    for line in out.splitlines():
        # "FirstName: Anna", or the value on the next line (" Anna Maria");
        # "No such key: FirstName" when the account has none.
        if line.startswith("No such key"):
            continue
        v = line.split(":", 1)[1] if re.match(r"^(FirstName|LastName):", line) else line
        names.append(v.strip())
    return names


def mac_known(omacvm: str) -> Known:
    k = Known()
    user = getpass.getuser()
    k.add("user", user, *user_names(user))
    # The Mac's name gives its owner too ("Anna's MacBook Pro": Anna).
    for what in ("ComputerName", "LocalHostName", "HostName"):
        k.add("host", run(["scutil", "--get", what]).strip())
    host = socket.gethostname()
    k.add("host", host, host.split(".")[0])
    k.add("home", os.path.expanduser("~"))
    tok = os.path.expanduser("~/Library/Application Support/omacvm-bridge/token")
    try:
        with open(tok, encoding="utf-8") as f:
            k.add("secret", f.read().strip())
    except OSError:
        pass
    m = re.search(r'"IOPlatformSerialNumber" = "([^"]+)"', run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"]))
    if m:
        k.add("secret", m.group(1))
    try:
        vms = json.loads(run([omacvm, "vms", "--json"], 60) or "{}").get("vms", [])
        k.add("vm", *[v.get("name", "") for v in vms if isinstance(v, dict)])
    except ValueError:
        pass
    # Wi-Fi and Bluetooth names, from this Mac's Bridge (only after its proof,
    # as from a VM: on 127.0.0.1 any Mac program could listen in its place).
    from .bridge import Bridge
    b = Bridge({}, "", token_file=tok, url=os.environ.get("OMACVM_BRIDGE_URL", "http://127.0.0.1:47831"))
    for path, fn in (("/state", wifi_values), ("/scan?cached=1", scan_values), ("/bluetooth", bt_values)):
        try:
            for kind, v in fn(b.call("GET", path, timeout=4.0)):
                k.add(kind, v)
        except Exception:   # no Bridge: nothing more to know from it
            break
    # Also without the Bridge (a likely moment to report a problem): the
    # devices macOS knows. Owners nobody lists are taken out by their form
    # ("Anna's AirPods", report.device_owners).
    for kind, v in mac_bt_values(run(["system_profiler", "SPBluetoothDataType", "-json"], 20)):
        k.add(kind, v)
    k.add("wifi", *mac_wifi_names())
    return k


WIFI_PORTS = {"wi-fi", "wlan", "airport", "wifi"}


def mac_wifi_names() -> list:
    """The Wi-Fi networks this Mac remembers, from its Wi-Fi device: en0 on a
    MacBook, en1 on a Mac mini, Studio or iMac (en0 is Ethernet there). The
    device comes from networksetup's port list ("Wi-Fi", "WLAN" in German);
    with no port of those names, every device is asked and only a Wi-Fi one
    answers with networks."""
    devs, wifi = [], []
    port = ""
    for line in run(["networksetup", "-listallhardwareports"], 10).splitlines():
        if line.startswith("Hardware Port:"):
            port = line.split(":", 1)[1].strip()
        elif line.startswith("Device:"):
            dev = line.split(":", 1)[1].strip()
            if re.fullmatch(r"[a-z]+[0-9]+", dev):
                (wifi if port.casefold() in WIFI_PORTS else devs).append(dev)
    names = []
    for dev in (wifi or devs)[:12]:
        lines = run(["networksetup", "-listpreferredwirelessnetworks", dev], 10).splitlines()
        if not lines or not lines[0].startswith("Preferred networks on"):
            continue   # "en0 is not a Wi-Fi interface."
        for line in lines[1:]:
            if line.strip() and line.strip() not in names:
                names.append(line.strip())
    return names


def mac_sections(omacvm: str, root: str, vm: str = "", what: str = "", vm_type: str = "") -> list:
    ver = open_text(os.path.join(root, "src", "VERSION")) or "?"
    chip = run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
    mem = run(["sysctl", "-n", "hw.memsize"]).strip()
    mem = f"{int(mem) >> 30} GB" if mem.isdigit() else "?"
    app = run(["defaults", "read", "/Applications/OmacVM.app/Contents/Info", "CFBundleShortVersionString"]).strip()
    versions = "\n".join([f"OmacVM {ver} on the Mac" + (f" · OmacVM.app {app}" if app else ""),
                          f"macOS {platform.mac_ver()[0]} · {chip} · {mem}"])
    which = (["--vm", vm] if vm else []) + (["--vm-type", vm_type] if vm and vm_type else [])
    args = [omacvm, "check", "--json"] + which
    try:
        data = json.loads(run(args, 180) or "{}")
        lines = [f"{'ok  ' if c.get('status') == 'ok' else 'FAIL' if c.get('status') == 'fail' else 'skip'} "
                 f"{c.get('section', '')}: {c.get('name', '')}: {c.get('detail', '')}"
                 for c in data.get("checks", []) if c.get("status") != "ok"]
        ok = sum(1 for c in data.get("checks", []) if c.get("status") == "ok")
        check = "\n".join(lines + [f"{ok} checks ok"]) + f"\nVM type: {data.get('type') or '?'}"
    except ValueError:
        check = "omacvm check gave no answer"
    feats = run([omacvm, "features", "--json"] + which, 60)
    try:
        table = "\n".join(f"{f['name']:16} {'on ' if f.get('on') else 'off'} "
                          f"{'' if f.get('available') else 'unavailable: ' + str(f.get('reason', ''))}"
                          for f in json.loads(feats).get("features", []))
    except (ValueError, KeyError, TypeError):
        table = ""
    logs = []
    names = ("omacvm-bridge.log", "omacvm-gestures.log", "omanotch.log")
    if os.environ.get("OMACVM_TEST_IDENTITY") == "1":   # the test helpers' logs (src/mac/install.sh)
        names = ("omacvm-test-bridge.log", "omacvm-test-gestures.log")
    for name in names:
        t = tail(os.path.expanduser(f"~/Library/Logs/{name}"))
        if t:
            logs.append(f"-- {name} --\n{t.rstrip()}")
    return [("What happened", what or "_Say what you did and what you saw._"),
            ("Versions", versions), ("Features", table), ("omacvm check", check),
            ("Logs (last 40 lines each)", "\n".join(logs))]
