"""The VM's own system update: Omarchy and its Arch packages, apart from the
OmacVM update. Only Omarchy's full update runs, never `pacman -Sy` alone: a
partial update can put a Mesa beside an LLVM it was not built for and the VM
starts to a black screen (src/guest/pkg-add). After the update, gbm-guard
says whether the desktop's graphics still open, before any restart."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys

from .local import share

OK = "graphics OK, restart when it suits"
BROKEN = ("graphics would not start: do not restart. Fix it first: "
          "https://github.com/gillesgoetsch/omacvm/blob/main/docs/troubleshooting.md"
          "#27-all-routes-black-screen-after-an-update-or-an-omacvm-job")
WHAT = ("This updates the VM's own system (Omarchy and its Arch packages) with omarchy update. "
        "It is not the OmacVM update.")


def waiting(timeout: float = 60) -> int | None:
    """How many package updates wait. From checkupdates (pacman-contrib),
    which syncs its own copy of the package lists, so the system's stay as
    they are. None: no checkupdates here, or it failed."""
    exe = shutil.which("checkupdates")
    if not exe:
        return None
    try:
        r = subprocess.run([exe], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode == 2:   # checkupdates: nothing to update
        return 0
    if r.returncode != 0:
        return None
    return sum(1 for line in r.stdout.splitlines() if line.strip())


def waiting_line(n: int | None) -> str:
    if n is None:
        return ""
    if n == 0:
        return "Omarchy: up to date"
    return f"Omarchy: {n} update{'s' if n != 1 else ''} waiting"


def update_command() -> list[str] | None:
    """omarchy update. -y skips its reboot question at the end, so the
    graphics check comes first and says whether a restart is safe."""
    if shutil.which("omarchy-update"):
        return ["omarchy-update", "-y"]
    if shutil.which("omarchy"):
        return ["omarchy", "update", "-y"]
    return None


def graphics() -> tuple[bool | None, str]:
    """gbm-guard test: (True, line) graphics open, (False, line) they do not,
    (None, line) not checked."""
    g = os.path.join(share(), "guest", "gbm-guard")
    if not os.access(g, os.X_OK):
        return None, "graphics not checked: gbm-guard is not in this VM (omacvm apply on the Mac puts it there)"
    try:
        r = subprocess.run([g, "test"], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"graphics not checked: gbm-guard did not run ({e})"
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def open_window() -> bool:
    """The update in its own floating terminal, as the control centre opens
    (app id org.omarchy.omacvm, so the same window rule applies)."""
    if not (os.environ.get("WAYLAND_DISPLAY") and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")):
        return False
    launcher = shutil.which("omarchy-launch-tui")
    if not launcher:
        return False
    try:
        subprocess.Popen([launcher, "omacvm", "--window", "update-system", "--yes"], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return False
    return True


def run(yes: bool = False) -> int:
    """omacvm update-system: omarchy update in this terminal, then the
    graphics check. 0 when both went well."""
    cmd = update_command()
    if not cmd:
        print("omacvm update-system: no omarchy update here", file=sys.stderr)
        return 1
    print(WHAT)
    if not yes:
        try:
            a = input("Update the VM's system now? [Y/n] ").strip().lower()
        except EOFError:
            a = "n"
        if a not in ("", "y", "yes"):
            return 0
    try:
        rc = subprocess.run(cmd).returncode
    except KeyboardInterrupt:
        rc = 130
    except OSError as e:
        print(f"omacvm update-system: {e}", file=sys.stderr)
        rc = 1
    if rc:
        print(f"\nomarchy update stopped (exit {rc}).")
    # Also after a stop: it may have changed some packages already.
    print("\nChecking the graphics before any restart ...")
    ok, line = graphics()
    if line:
        print(line)
    if ok is None:
        return 1
    print(OK if ok else BROKEN)
    return 0 if ok and not rc else 1
