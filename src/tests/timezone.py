"""Offline test of the VM's time zone agent (src/bridge/guest/omacvm-timezone):
a scratch folder stands in for / (zoneinfo, /etc/localtime, the record),
a made-up Bridge client prints the event stream, and a made-up timedatectl
moves the link. No VM, no Mac, no root.
  python3 -I timezone.py <omacvm-timezone>
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile

AGENT = sys.argv[1]
T = tempfile.mkdtemp()
os.environ["OMACVM_TZ_ROOT"] = T
ZI = f"{T}/usr/share/zoneinfo"
for z in ("UTC", "Europe/Zurich", "America/New_York", "Asia/Tokyo", "America/Argentina/Buenos_Aires"):
    os.makedirs(os.path.dirname(f"{ZI}/{z}"), exist_ok=True)
    open(f"{ZI}/{z}", "w").write("TZif")
os.makedirs(f"{T}/etc/omacvm", exist_ok=True)
user = os.environ.get("USER") or os.getlogin()
open(f"{T}/etc/omacvm/env", "w").write(f"OMACVM_USER={user}\n")
import pwd
home = T + pwd.getpwnam(user).pw_dir
os.makedirs(f"{home}/.config/omacvm-bridge", exist_ok=True)
open(f"{home}/.config/omacvm-bridge/token", "w").write("x" * 48 + "\n")

# timedatectl set-timezone ZONE, as systemd does it: the link, absolute.
CALLS = f"{T}/calls"
SET = f"{T}/set-timezone"
open(SET, "w").write(f"""#!/bin/bash
echo "$1" >> {CALLS}
[[ -f {T}/set-fails ]] && {{ echo "Access denied" >&2; exit 1; }}
ln -sfn "/usr/share/zoneinfo/$1" {T}/etc/localtime
""")
os.chmod(SET, 0o755)
os.environ["OMACVM_TZ_SET"] = SET
# The Bridge client: prints the stream in $T/stream, then ends.
CLIENT = f"{T}/client"
open(CLIENT, "w").write(f"""#!/bin/bash
[[ $1 == events ]] || exit 2
[[ -s $OMACVM_BRIDGE_TOKEN_FILE ]] || exit 3
cat {T}/stream
""")
os.chmod(CLIENT, 0o755)
os.environ["OMACVM_TZ_CLIENT"] = CLIENT

loader = importlib.machinery.SourceFileLoader("omacvm_timezone", AGENT)
spec = importlib.util.spec_from_loader("omacvm_timezone", loader)
tz = importlib.util.module_from_spec(spec)
loader.exec_module(tz)

fail = 0


def check(ok, what):
    global fail
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        fail = 1


def localtime(zone):
    if os.path.lexists(f"{T}/etc/localtime"):
        os.remove(f"{T}/etc/localtime")
    os.symlink(f"/usr/share/zoneinfo/{zone}", f"{T}/etc/localtime")


def calls():
    try:
        c = open(CALLS).read().split()
    except OSError:
        c = []
    open(CALLS, "w").close()
    return c


def stream(*zones, other=True):
    s = ""
    if other:
        s += 'event: wifi\ndata: {"power": true}\n\n'
    for z in zones:
        s += f"event: timezone\ndata: {z}\n\n"
    open(f"{T}/stream", "w").write(s)


def run(*zones, other=True):
    stream(*zones, other=other)
    f = tz.Follower()
    tz.from_bridge(f)
    return f


def state():
    return open(f"{T}/run/omacvm/timezone").read().split()


def record():
    try:
        return open(f"{T}/var/lib/omacvm/timezone").read().strip()
    except OSError:
        return None


# The rules on their own.
check(tz.decide("Europe/Zurich", "UTC", None) == ("set", "Europe/Zurich"), "decide: first run, the Mac's zone: set")
check(tz.decide("Europe/Zurich", "Europe/Zurich", None) == ("keep", None), "decide: already the Mac's: nothing")
check(tz.decide("America/New_York", "Europe/Zurich", "Europe/Zurich") == ("set", "America/New_York"),
      "decide: the Mac moved, the VM on the zone set last: set")
check(tz.decide("Europe/Zurich", "Asia/Tokyo", "Europe/Zurich") == ("by-hand", None), "decide: set by hand in the VM: kept")
check(tz.decide("Asia/Tokyo", "Asia/Tokyo", "Europe/Zurich") == ("keep", None), "decide: by hand to the Mac's: nothing (follows again)")

# 1. The VM starts (the stream opens): the Mac's zone at once, from UTC.
localtime("UTC")
run('{"zone": "Europe/Zurich", "seq": 1}')
check(calls() == ["Europe/Zurich"], "start: set to the Mac's zone")
check(tz.current_zone() == "Europe/Zurich" and record() == "Europe/Zurich", "start: the VM on it, recorded")
check(state() == ["follows", "Europe/Zurich", "Europe/Zurich"], "start: the check's state says follows")
# 2. Started again on the same zone: nothing is set.
run('{"zone": "Europe/Zurich"}')
check(calls() == [], "again on the same zone: nothing set")
# 3. The Mac's zone changes while it runs: the VM follows, every change.
run('{"zone": "Europe/Zurich"}', '{"zone": "America/New_York"}', '{"zone": "America/Argentina/Buenos_Aires"}')
check(calls() == ["America/New_York", "America/Argentina/Buenos_Aires"], "the Mac moved twice: the VM follows both")
check(record() == "America/Argentina/Buenos_Aires", "the Mac moved: recorded")
# 4. Someone sets the VM's zone by hand: kept, whatever the Mac sends.
localtime("Asia/Tokyo")
f = run('{"zone": "America/Argentina/Buenos_Aires"}', '{"zone": "Europe/Zurich"}')
check(calls() == [], "set by hand: kept, the Mac's zones not set")
check(state() == ["by-hand", "Asia/Tokyo", "Europe/Zurich"], "set by hand: the check's state says so")
check(sum("set by hand" in m for m in f.said) == 1, "set by hand: said once")
check(record() == "America/Argentina/Buenos_Aires", "set by hand: the record stays")
# 5. Set back to the Mac's zone by hand: it follows again.
localtime("Europe/Zurich")
run('{"zone": "Europe/Zurich"}', '{"zone": "America/New_York"}')
check(calls() == ["America/New_York"], "back on the Mac's zone: follows again")
# 6. Not a zone, or not one this VM has: ignored.
f = run('{"zone": "../../../etc/passwd"}', '{"zone": "Nowhere/City"}', '{"zone": 7}', '{"nozone": 1}',
        '{"zone": "Europe//Zurich"}', '{"zone": "A/B/C/D"}', '"Europe/Zurich"', 'not json')
check(calls() == [] and tz.current_zone() == "America/New_York", "bad zones: nothing set")
check(sum(m.startswith("ignored a time zone") for m in f.said) >= 5, "bad zones: said")
# 7. timedatectl refuses: the state says waiting, nothing recorded; the next zone tries again.
open(f"{T}/set-fails", "w").close()
run('{"zone": "Asia/Tokyo"}')
check(calls() == ["Asia/Tokyo"] and state()[0] == "waiting" and record() == "America/New_York", "set refused: waiting, not recorded")
os.remove(f"{T}/set-fails")
run('{"zone": "Asia/Tokyo"}')
check(calls() == ["Asia/Tokyo"] and record() == "Asia/Tokyo" and state()[0] == "follows", "set works again: follows")
# 8. Only "timezone" events count; the stream's others do nothing.
run(other=True)
check(calls() == [], "other events: nothing")
# 9. No token yet: no client run, said.
os.rename(f"{home}/.config/omacvm-bridge/token", f"{T}/token.away")
f = tz.Follower()
check(tz.from_bridge(f) is False and any("no Bridge token" in m for m in f.said), "no token: waits, says so")
os.rename(f"{T}/token.away", f"{home}/.config/omacvm-bridge/token")
# --status for omacvm check.
import subprocess
out = subprocess.run([sys.executable, "-I", AGENT, "--status"], capture_output=True, text=True, env=dict(os.environ)).stdout.split()
check(out == ["follows", "Asia/Tokyo", "Asia/Tokyo"], "--status: the state line")
# A zone set by hand after the Mac's last word: --status says so at once (no event needed).
localtime("America/New_York")
out = subprocess.run([sys.executable, "-I", AGENT, "--status"], capture_output=True, text=True, env=dict(os.environ)).stdout.split()
check(out == ["by-hand", "America/New_York", "Asia/Tokyo"], "--status: set by hand since the last zone from the Mac")

print("FAIL timezone" if fail else "ok   timezone: the VM follows the Mac's zone, one set by hand is kept")
sys.exit(fail)
