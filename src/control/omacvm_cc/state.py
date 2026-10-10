"""The control centre's model: features, what was chosen, checks, jobs and
updates in, one status per feature out. Pure: no files, no network, so every
rule is unit-tested (tests/test_state.py).

Status order (the first that applies wins):
  busy (a job runs) > unavailable (this Mac or VM can't) > off > needs a
  person (a failed check only a person can fix: a macOS permission, a
  setting) > failing > next start (on, but in use only from the VM's next
  start: Touch ID on OmacVM.app) > unknown (no check result yet) > works
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,31}$")

# VMs set up before a feature existed: what they were built with when their
# env does not name it (as features_read_env in src/lib/features.sh).
OFF_WHEN_UNNAMED = {"omanotch", "scroll-momentum", "autologin", "thp-kernel", "control-centre"}

# Renamed features: new name -> the old one, whose on and off are the other
# way round (as feature_old_value in src/lib/features.sh). idle-lock (on:
# Omarchy's screensaver and lock) became no-idle-lock in 3.0.1.
FLIPPED_OLD_NAMES = {"no-idle-lock": "idle-lock"}


class Status(str, Enum):
    BUSY = "busy"
    UNAVAILABLE = "unavailable"
    OFF = "off"
    UNKNOWN = "unknown"
    NEEDS_PERSON = "needs-person"
    FAILING = "failing"
    NEXT_START = "next-start"
    WORKS = "works"


@dataclass(frozen=True)
class Feature:
    name: str
    default: str            # on | off | notch | laptop
    sides: tuple[str, ...]  # mac, vm
    tags: tuple[str, ...]
    needs: str | None
    title: str
    summary: str


@dataclass(frozen=True)
class Check:
    side: str        # mac | vm
    status: str      # ok | fail | skip
    name: str
    detail: str
    human: bool
    feature: str     # "" = the Mac or the VM in general


@dataclass(frozen=True)
class Avail:
    ok: bool
    reason: str = ""


@dataclass(frozen=True)
class Job:
    id: str
    action: str
    features: tuple[str, ...]
    state: str       # queued | running | done | failed | rolled-back
    step: int = 0
    of: int = 0
    text: str = ""
    failed_part: str = ""   # the feature whose part failed (failed, rolled-back)
    mac_omacvm: str = ""    # update: the Mac's OmacVM after the job
    failed_side: str = ""   # "mac": a Mac helper did not build; "vm" or "": the VM side

    @property
    def active(self) -> bool:
        return self.state in ("queued", "running")


@dataclass(frozen=True)
class Row:
    feature: Feature
    on: bool
    status: Status
    note: str
    update: bool = False
    checks: tuple[Check, ...] = field(default=())
    detail: str = ""   # the whole story behind a short note (the details screen's "Now")


# ---- parsing ----

def parse_features_tsv(text: str) -> list[Feature]:
    """src/features.tsv: name default sides tags needs title summary."""
    out = []
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 7 or not NAME_RE.match(f[0]):
            continue
        out.append(Feature(
            name=f[0], default=f[1],
            sides=tuple(s for s in f[2].split(",") if s and s != "-"),
            tags=tuple(t for t in f[3].split(",") if t and t != "-"),
            needs=None if f[4] in ("", "-") else f[4],
            title=f[5], summary=f[6]))
    return out


def parse_env(text: str) -> dict[str, str]:
    """/etc/omacvm/env: KEY=value lines (the last one wins, as in the shell)."""
    env = {}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep and re.match(r"^[A-Z][A-Za-z0-9_]*$", k):
            env[k] = v.strip()
    return env


def env_key(name: str) -> str:
    return "OMACVM_FEATURE_" + name.replace("-", "_")


def desired(features: list[Feature], env: dict[str, str]) -> dict[str, bool]:
    """On or off per feature, as this VM was set up."""
    out = {}
    for f in features:
        v = env.get(env_key(f.name))
        old = env.get(env_key(FLIPPED_OLD_NAMES[f.name])) if f.name in FLIPPED_OLD_NAMES else None
        if v is None and old in ("on", "off"):
            v = "off" if old == "on" else "on"
        if v is None:
            v = "off" if f.name in OFF_WHEN_UNNAMED or f.default != "on" else "on"
        out[f.name] = v == "on"
    return out


def sddm_autologin_user(texts: list[str]) -> str:
    """Who SDDM logs in, from its config files in the order SDDM reads them
    (/usr/lib/sddm/sddm.conf.d, /etc/sddm.conf.d, /etc/sddm.conf): the last
    User= of an [Autologin] section; "" nobody. The same rule as
    src/guest/autologin.sh, whoever wrote the file."""
    user, section = "", False
    for text in texts:
        for line in text.splitlines():
            t = line.strip()
            if t.startswith("["):
                section = t.startswith("[Autologin]")
            elif section and t.split("=", 1)[0].strip() == "User" and "=" in t:
                user = t.split("=", 1)[1].strip()
    return user


# What a tag means, in words (never a bare tag; src/lib/features.sh says the
# same in feature_slow_hint). NOTE: short, for the table's note column.
# "slow" is about switching it on: nothing is said about it while it is on.
TAG_NOTES = {"experimental": "experimental", "slow": "a build to switch on, up to 1 h+"}
TAG_HINTS = {"experimental": "experimental: it may change or be removed",
             "slow": "a build in the VM to switch it on, then a restart: minutes to over an hour, faster with more CPUs"}
ON_SILENT = {"slow"}


def tag_note(f: Feature, on: bool = False) -> str:
    return ", ".join(TAG_NOTES[t] for t in f.tags if t in TAG_NOTES and not (on and t in ON_SILENT))


def tag_hints(f: Feature, on: bool = False) -> list[str]:
    return [TAG_HINTS[t] for t in f.tags if t in TAG_HINTS and not (on and t in ON_SILENT)]


def fixed_note(on: bool) -> str:
    """The table's note for a feature whose record the Mac just fixed."""
    return f"OmacVM's record said {'off' if on else 'on'}: fixed"


# Touch ID answers sudo and polkit. Apps that unlock through polkit ask it only
# with their own switch on (docs/features.md, ADR 0041): the checks below say
# how 1Password is set here (omacvm-touchid-apps).
TOUCH_ID_ABOUT = (
    "On OmacVM.app: from the VM's next start (shut it down, then start it again; a restart inside the VM "
    "is not enough).\n"
    "Apps with their own switch for it (each still wants its own password once after it starts):\n"
    "  1Password: Settings › Security › Unlock using system authentication\n"
    "  Bitwarden: Settings › Security › Unlock with system authentication\n"
    "  KeePassXC 2.8 (beta): Settings › Security › Enable database quick unlock (on by default)")


def feature_about(f: Feature, macos: str = "") -> str:
    """More than the summary, for the details screen ("" nothing more).
    macos: the Mac's macOS version as the Bridge says it ("" not known)."""
    if f.name == "touch-id":
        return TOUCH_ID_ABOUT
    if f.name != "vulkan":
        return ""
    major = version_tuple(macos)
    kk = ("macOS 26 or newer: Vulkan goes through KosmicKrisp, Mesa's Vulkan on Metal 4, "
          "the fuller driver (more Vulkan features, faster).")
    mvk = ("macOS 15: Vulkan goes through MoltenVK (KosmicKrisp needs macOS 26). WebGPU and OpenCL work, "
           "with fewer Vulkan features, so some WebGPU pages and compute jobs may not run; "
           "after an update to macOS 26 the VM gets KosmicKrisp by itself.")
    if major is None:
        mac = "On this Mac: " + kk + "\nOn " + mvk
    elif major[0] >= 26:
        mac = f"On this Mac (macOS {macos}): " + kk[len("macOS 26 or newer: "):]
    else:
        mac = f"On this Mac (macOS {macos}): " + mvk[len("macOS 15: "):]
    return ("Needs an OmacVM.app VM; works with every Graphics setting.\n" + mac + "\n"
            "Switching on: the VM builds OmacVM's Mesa (about 3 minutes, a 140 MB download), then "
            "WebGPU and GPU compute from the VM's next start (shut it down and start it again).\n"
            "Switching off: OpenGL only again from the next start; OmacVM's Mesa is removed. "
            "You can switch it on again at any time (the build again, about 3 minutes).")


def parse_check_tsv(text: str, side: str = "vm") -> list[Check]:
    """guest/check.sh --tsv: status name detail human feature (section lines skipped)."""
    out = []
    for line in text.splitlines():
        f = line.split("\t")
        if len(f) < 3 or f[0] not in ("ok", "fail", "skip"):
            continue
        f += [""] * (5 - len(f))
        out.append(Check(side=side, status=f[0], name=f[1], detail=f[2], human=f[3] == "1", feature=f[4]))
    return out


def parse_mac_checks(items: list[dict]) -> list[Check]:
    """The Mac's checks as the Bridge sends them (omacvm check --json --mac-only)."""
    out = []
    for c in items or []:
        if not isinstance(c, dict) or c.get("status") not in ("ok", "fail", "skip"):
            continue
        out.append(Check(side="mac", status=c["status"], name=str(c.get("name", "")),
                         detail=str(c.get("detail", "")), human=bool(c.get("needs_human")),
                         feature=str(c.get("feature", ""))))
    return out


# ---- rules ----

def local_avail(f: Feature, vm_type: str) -> Avail | None:
    """What the VM knows by itself; None: only the Mac can tell."""
    if "not-parallels" in f.tags and vm_type == "parallels":
        return Avail(False, "Parallels does it itself")
    if "app-only" in f.tags and vm_type != "app":
        return Avail(False, "OmacVM.app only")
    return None


# On, but in use only from the VM's next start (a reboot inside the VM keeps
# the same start: OmacVM.app adds Touch ID's port when it starts the VM).
NEXT_START_NOTE = "on from the VM's next start: shut it down, then start it again"


def status_of(f: Feature, on: bool, avail: Avail | None, checks: list[Check] | None,
              job: Job | None, next_start: bool = False) -> tuple[Status, str]:
    """One feature's status and the short note shown next to it.
    checks None: no check result yet; [] : checked, nothing about it.
    next_start: on, but this start of the VM does not have it yet."""
    if job is not None and job.active:
        step = f" ({job.step}/{job.of})" if job.of else ""
        return Status.BUSY, (job.text or job.action) + step
    if avail is not None and not avail.ok:
        return Status.UNAVAILABLE, avail.reason
    if not on:
        return Status.OFF, ""
    failed = [c for c in checks or [] if c.status == "fail"]
    if next_start and not failed:
        return Status.NEXT_START, NEXT_START_NOTE
    if checks is None:
        return Status.UNKNOWN, "not checked yet"
    human = [c for c in failed if c.human]
    if human:
        c = human[0]
        return Status.NEEDS_PERSON, ("Mac: " if c.side == "mac" else "") + c.detail
    if failed:
        c = failed[0]
        return Status.FAILING, f"{c.name}: {c.detail}" if c.detail else c.name
    return Status.WORKS, ""


def version_tuple(v) -> tuple | None:
    """"2.9.1" -> (2, 9, 1); None for anything else ("1.x", "?")."""
    parts = str(v or "").split(".")
    if not 1 <= len(parts) <= 4 or not all(p.isdigit() for p in parts):
        return None
    t = [int(p) for p in parts]
    return tuple(t + [0] * (4 - len(t)))


def mac_newer(vm, mac) -> bool:
    """The Mac has a newer OmacVM than this VM (a switch or repair brings all
    of it into the VM)."""
    m, v = version_tuple(mac), version_tuple(vm)
    return m is not None and (v is None or m > v)


def update_offered(release, vm, mac=None) -> bool:
    """An update is offered only forward: the release is newer than this VM's
    OmacVM (one without a version counts as older) and not older than the
    Mac's (the Mac never goes back either)."""
    r = version_tuple(release)
    if r is None:
        return False
    v = version_tuple(vm)
    if v is not None and r <= v:
        return False
    m = version_tuple(mac) if mac else None
    return m is None or r >= m


# What u does (Controller.update_plan): nothing, this VM only (the Mac is
# current), OmacVM.app first and then this VM (the app restarts the VM once),
# the app only, a Mac checkout and this VM in one job, or the app by hand.
PLANS = ("none", "vm", "app+vm", "app", "mac-checkout", "manual")


def update_plan(release, vm, mac, mac_app: bool, app_vm: bool, app_update: bool) -> str:
    """mac_app: the Mac's omacvm is OmacVM.app's copy (the app updates it).
    app_vm: this VM runs in OmacVM.app. app_update: the Mac takes
    POST /omacvm/app-update (3.0.2 on). Forward only."""
    r, v, m = version_tuple(release), version_tuple(vm), version_tuple(mac)
    if r is None or (m is not None and r < m):
        return "none"   # no release, or the Mac is ahead of it
    vm_older = v is None or v < r
    mac_older = m is None or m < r
    if not mac_older:
        return "vm" if vm_older else "none"
    if not mac_app:
        return "mac-checkout"
    if app_vm and app_update:
        return "app+vm" if vm_older else "app"
    return "manual"


def update_line(plan: str, version) -> str:
    """The top line when an update is there ("" for none)."""
    who = {"vm": "this VM", "app+vm": "Mac app and this VM", "app": "Mac app",
           "mac-checkout": "the Mac and this VM", "manual": "Mac app and this VM"}.get(plan)
    return f"Update available: {version} ({who}) · u updates" if who else ""


# ---- progress while an update runs ----

# The one-key update through OmacVM.app: four steps, the first two before the
# VM shuts down, the last two after it started again ({v}: the release).
APP_STEPS = ("the Mac gets OmacVM.app {v}", "shutting down this VM",
             "OmacVM.app {v} installs and starts this VM again", "updating this VM")


def bar(fraction: float, width: int = 30) -> str:
    """A progress bar of block characters."""
    n = max(0, min(width, round(fraction * width)))
    return "█" * n + "░" * (width - n)


def latest_line(lines) -> str:
    """The last line a job wrote ("" none), without the "==> " of a step."""
    for line in reversed(list(lines or [])):
        s = str(line).strip()
        if s:
            return s[4:] if s.startswith("==> ") else s
    return ""


def job_step(job: Job) -> str:
    """ "step 3 of 9: text" for a running job ("starting" before its first step)."""
    text = job.text.strip() or "starting"
    return f"step {job.step} of {job.of}: {text}" if job.of else text


def progress_lines(title: str, job: Job | None, lines=(), *, steps: tuple[str, ...] = (),
                   at: int = 0, version: str = "", waiting: str = "") -> list[tuple[str, str]]:
    """What an update shows while it runs, as (text, style) lines: the title,
    with steps (the app path) each step marked done, now or to come; the
    job's step and a bar; the job's latest log line. at: the step now (1..);
    waiting: why the job's answers are late (the Mac restarts its Bridge)."""
    out: list[tuple[str, str]] = [(title, "bold")]
    for i, s in enumerate(steps, 1):
        mark, style = ("✓", "green") if i < at else ("›", "bold") if i == at else (" ", "bright_black")
        out.append((f"  {mark} {i} of {len(steps)}  {s.format(v=version)}", style))
    if job is not None:
        frac = job.step / job.of if job.of else 0.0
        indent = "      " if steps else "  "
        out.append((f"{indent}{bar(frac)}  {job_step(job)}", ""))
        last = waiting or latest_line(lines)
        if last and last != job.text.strip():
            out.append((f"{indent}{last}", "bright_black"))
    return out


def part_changed(name: str, installed: dict, offer: dict) -> bool:
    """An update changes this part: the offered digest is not the installed one."""
    o = (offer or {}).get(name)
    if not isinstance(o, dict) or not o.get("digest"):
        return False
    i = (installed or {}).get(name)
    return not isinstance(i, dict) or i.get("digest") != o["digest"]


def build_rows(features: list[Feature], on: dict[str, bool], *, vm_type: str = "",
               avail: dict[str, Avail] | None = None, checks: list[Check] | None = None,
               jobs: list[Job] | None = None, installed: dict | None = None,
               offer: dict | None = None, mac_features: set[str] | None = None,
               show_updates: bool = True, fixed: dict[str, str] | None = None,
               next_start: set[str] | None = None) -> list[Row]:
    """The features screen. mac_features: what the Mac's OmacVM knows (None:
    not known); a feature it lacks is unavailable until the Mac is updated.
    show_updates False (update checks off): no update marks, but an update
    that runs still shows on the features it changes. fixed: the features
    whose record the Mac fixed to their real state (omacvm features --json
    "fixed"); on must already say that state. next_start: the features that
    are on but in use only from the VM's next start."""
    active = [j for j in (jobs or []) if j.active]
    rows = []
    for f in features:
        a = (avail or {}).get(f.name) or local_avail(f, vm_type)
        if mac_features is not None and f.name not in mac_features and "mac" in f.sides:
            a = Avail(False, "the Mac's OmacVM is older: update it")
        update = part_changed(f.name, installed or {}, offer or {})
        # An update job is about the features it changes.
        job = next((j for j in active if f.name in j.features or (j.action == "update" and update)), None)
        mine = None if checks is None else [c for c in checks if c.feature == f.name]
        st, note = status_of(f, on.get(f.name, False), a, mine, job, f.name in (next_start or ()))
        if (fixed or {}).get(f.name) and st in (Status.WORKS, Status.OFF, Status.UNKNOWN):
            note = fixed_note(on.get(f.name, False))
        rows.append(Row(feature=f, on=on.get(f.name, False), status=st, note=note,
                        update=update and show_updates, checks=tuple(mine or ())))
    return rows


def next_start_note(name: str, turn_on: bool, vm_type: str) -> str:
    """What switching NAME means for the VM that runs now ("" when it changes
    now). The fast network (OmacVM.app) is the network of the VM's next start:
    the running VM keeps its own until then. On may need the Mac's service
    installed or updated: OmacVM asks for the password on the Mac at that
    start (a VM's job never asks for it)."""
    if name != "fast-network" or vm_type != "app":
        return ""
    text = ("From the VM's next start (shut it down, then start it again): "
            "it keeps the network it has until then.")
    if turn_on:
        text += (" If the fast network's service on the Mac needs installing or an update, "
                 "OmacVM asks for your password on the Mac at that start.")
    return text


def toggle_plan(features: list[Feature], on: dict[str, bool], name: str) -> dict[str, bool]:
    """Switching NAME: the changes it brings (as set_on in src/cmd/features.sh).
    On brings what it needs; off takes what needs it along."""
    by = {f.name: f for f in features}
    if name not in by:
        raise KeyError(name)
    want = dict(on)
    changes: dict[str, bool] = {}

    def set_on(n: str, v: bool) -> None:
        if want.get(n) == v and n != name:
            return
        want[n] = v
        changes[n] = v
        f = by[n]
        if v and f.needs and not want.get(f.needs, False):
            set_on(f.needs, True)
        if not v:
            for g in features:
                if g.needs == n and want.get(g.name, False):
                    set_on(g.name, False)

    set_on(name, not on.get(name, False))
    return changes


def counts(rows: list[Row]) -> dict[str, int]:
    out: dict[str, int] = {}
    for r in rows:
        out[r.status.value] = out.get(r.status.value, 0) + 1
    out["updates"] = sum(1 for r in rows if r.update)
    return out


# ---- OmacVM.app's Graphics setting (src/cmd/graphics.sh) ----
GRAPHICS_CHOICES = ("auto", "opengl", "vulkan")
GRAPHICS_TITLES = {"auto": "Automatic", "opengl": "OpenGL", "vulkan": "Vulkan"}
# The Mac's words when Vulkan fell back (Graphics.didNotStart, src/lib/graphics.sh).
GRAPHICS_DID_NOT_START = "Vulkan did not start on this Mac: using OpenGL"
# The row's short words, whole in an 80-column window (the Mac's summary is
# for its own window and omacvm: about 100 characters, cut off in the row on
# the Mac mini, 2026-10-08); the whole story under enter.
GRAPHICS_WAITING_NOTE = "Vulkan: OpenGL until r builds it"
GRAPHICS_WAITING_DETAIL = ("Vulkan is chosen, but this VM does not have its Vulkan driver yet, so it runs on OpenGL "
                           "until the driver is built. r builds it (a few minutes; when the VM's packages are too old "
                           "for that, after a whole system update with omarchy update, asked first).")
GRAPHICS_FELL_BACK_NOTE = "Vulkan: OpenGL now, r tries again"
GRAPHICS_FEATURE = Feature(
    name="graphics", default="auto", sides=("mac",), tags=(), needs=None, title="Graphics",
    summary="OpenGL, Vulkan, or Automatic (Vulkan on macOS 26 and newer, OpenGL before); from the VM's next start")


def graphics_row(status: dict | None, vm_type: str, jobs: list[Job] | None = None,
                 checks: list[Check] | None = None, offline: bool = False) -> Row | None:
    """The Graphics row of an OmacVM.app VM, from the Mac's status (its
    `graphics`: omacvm graphics --json); None on the other routes. offline:
    the Mac does not answer or refused this VM (no status: not its age)."""
    if vm_type != "app":
        return None
    # "graphics memory" has its own row (older 3.0.0 RCs sent it with FEATURE=graphics).
    mine = tuple(c for c in (checks or []) if c.feature == "graphics" and c.name != "graphics memory")
    g = (status or {}).get("graphics")
    job = next((j for j in (jobs or []) if j.active and j.action == "graphics"), None)
    if job is not None:
        return Row(GRAPHICS_FEATURE, True, Status.BUSY, f"to {GRAPHICS_TITLES.get(job.features[0] if job.features else '', '?')}…",
                   checks=mine)
    if not isinstance(status, dict):
        return Row(GRAPHICS_FEATURE, True, Status.UNKNOWN, "needs the Mac" if offline else "asking the Mac", checks=mine)
    if not isinstance(g, dict) or g.get("graphics") not in GRAPHICS_CHOICES:
        return Row(GRAPHICS_FEATURE, True, Status.UNKNOWN, "the Mac's OmacVM does not say (older than 3.0.0?)", checks=mine)
    title = GRAPHICS_TITLES[g["graphics"]]
    nxt = "OpenGL and Vulkan" if g.get("next_start") == "vulkan" else "OpenGL"
    this = str(g.get("this_start") or "")
    now = "OpenGL and Vulkan" if "-> vulkan" in this else "OpenGL" if this else ""
    if now and now == nxt:
        note, detail = f"{title}: {now}", ""
    else:
        # Short in the row (OpenGL is always there); the whole of it under enter.
        note = f"{title}: {'Vulkan' if nxt != 'OpenGL' else 'OpenGL'} from next start"
        detail = f"{title}: {nxt} from the VM's next start (shut it down, then start it again)"
    if g.get("waiting_for_driver") is True:
        # Vulkan chosen, no Venus driver for the Mac's pages yet: OpenGL until
        # r on this row (or an apply) builds it.
        note, detail = GRAPHICS_WAITING_NOTE, GRAPHICS_WAITING_DETAIL
    elif str(g.get("summary") or "").startswith(GRAPHICS_DID_NOT_START):
        # A Vulkan start showed nothing on this Mac; the app started it on
        # OpenGL and stays there until Vulkan is chosen again (r here: the
        # same choice again clears the fallback, src/cmd/graphics.sh).
        note = GRAPHICS_FELL_BACK_NOTE
        detail = str(g["summary"]).replace("choose Vulkan again to try once more", "r on this row tries Vulkan again")
    if any(c.status == "fail" for c in mine):
        bad = next(c for c in mine if c.status == "fail")
        return Row(GRAPHICS_FEATURE, True, Status.NEEDS_PERSON if bad.human else Status.FAILING,
                   f"{note}; {bad.name}: {bad.detail}", checks=mine, detail=detail)
    return Row(GRAPHICS_FEATURE, True, Status.WORKS, note, checks=mine, detail=detail)


def next_graphics(current: str) -> str:
    """Space on the Graphics row: Automatic -> OpenGL -> Vulkan -> Automatic."""
    i = GRAPHICS_CHOICES.index(current) if current in GRAPHICS_CHOICES else -1
    return GRAPHICS_CHOICES[(i + 1) % len(GRAPHICS_CHOICES)]


# ---- OmacVM.app's notch area (src/cmd/notch.sh, FullPanel #339) ----
NOTCH_CHOICES = ("native", "fullpanel")
NOTCH_TITLES = {"native": "Native", "fullpanel": "FullPanel"}
# What the Omanotch row says while this start is FullPanel (its features
# keep Omanotch on; the next native start has it again).
OMANOTCH_FULLPANEL_NOTE = "not needed (notch area in use)"
NOTCH_FEATURE = Feature(
    name="notch-area", default="native", sides=("mac",), tags=("experimental",), needs=None,
    title="Notch area",
    summary=("Experimental, OmacVM.app only. Native: full screen below the camera housing, Omanotch "
             "streams the bar into the strip. FullPanel: the VM's full screen also covers the strip on "
             "the MacBook's own display and Omarchy's bar sits there, split around the notch; Omanotch "
             "is not needed then. External displays stay as they are. From the VM's next start, only "
             "with Start in full screen in the app."))


def notch_fullpanel_now(status: dict | None) -> bool:
    """This start of the VM is a FullPanel start (the Mac's word)."""
    n = (status or {}).get("notch")
    return isinstance(n, dict) and str(n.get("this_start") or "").startswith("fullpanel")


def notch_row(status: dict | None, vm_type: str, jobs: list[Job] | None = None,
              offline: bool = False) -> Row | None:
    """The notch area row of an OmacVM.app VM on a Mac with a notch (or one
    set to FullPanel), from the Mac's status (`notch`: omacvm notch --json);
    None elsewhere. Notes stay within an 80-column window; the whole story
    under enter."""
    if vm_type != "app":
        return None
    n = (status or {}).get("notch")
    job = next((j for j in (jobs or []) if j.active and j.action == "notch"), None)
    if job is not None:
        return Row(NOTCH_FEATURE, True, Status.BUSY, f"to {NOTCH_TITLES.get(job.features[0] if job.features else '', '?')}…")
    if not isinstance(status, dict):
        return None if offline else Row(NOTCH_FEATURE, True, Status.UNKNOWN, "asking the Mac")
    if not isinstance(n, dict) or n.get("notch") not in NOTCH_CHOICES:
        return None   # a Mac older than FullPanel: no such setting
    mode = n["notch"]
    if mode == "native" and n.get("mac_has_notch") is not True:
        return None   # no notch on this Mac: nothing to choose
    this, nxt = str(n.get("this_start") or ""), str(n.get("next_start") or "")
    now_fp = this.startswith("fullpanel")
    if mode == "native":
        if now_fp:
            return Row(NOTCH_FEATURE, False, Status.NEXT_START, "Native from the VM's next start",
                       detail="This start is FullPanel; the next one is native again, with Omanotch.")
        return Row(NOTCH_FEATURE, False, Status.OFF, "Native: Omanotch fills the strip",
                   detail="Native: full screen below the camera housing; Omanotch streams the bar into the strip.")
    if now_fp:
        return Row(NOTCH_FEATURE, True, Status.WORKS, "FullPanel: the bar in the strip",
                   detail=f"This start: {this}. Omanotch is not needed while it is on.")
    if nxt == "fullpanel":
        return Row(NOTCH_FEATURE, True, Status.NEXT_START, "FullPanel from the next start",
                   detail="FullPanel from the VM's next start: shut it down, then start it again.")
    why = nxt[nxt.find("(") + 1:nxt.rfind(")")] if "(" in nxt else nxt
    short = ("needs full screen" if "full screen" in why else "no notch now" if "no notch" in why
             else "VM not ready" if "not ready" in why else "native")
    return Row(NOTCH_FEATURE, True, Status.NEEDS_PERSON, f"FullPanel set, {short}",
               detail=f"FullPanel is set, but the next start is native: {why or 'not known'}.")


def next_notch(current: str) -> str:
    """Space on the notch area row: Native <-> FullPanel."""
    return "native" if current == "fullpanel" else "fullpanel"


# ---- OmacVM.app: the VM's graphics memory on the Mac (GET /omacvm/gpu-memory) ----
# The same words as the VM's app menu (omacvm-cocoa-graphics-memory.patch).
GPU_MEMORY_EXPLAINER = (
    "VM memory is the Mac memory you gave the VM: its RAM. Graphics memory comes on top: what the VM's "
    "GPU work (its desktop and apps) uses of the Mac's memory, as it needs it.")
GPU_MEMORY_FEATURE = Feature(
    name="gpu-memory", default="on", sides=("mac",), tags=(), needs=None, title="Graphics memory",
    summary=GPU_MEMORY_EXPLAINER)


def gb(mb: int) -> str:
    """As the app menu: "512 MB", "1.6 GB"."""
    return f"{mb} MB" if mb < 1024 else f"{mb / 1024:.1f} GB"


def _count(v) -> int:
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


def gpu_memory_row(answer: dict | None, vm_type: str, supported: bool | None = True,
                   checks: list[Check] | None = None, offline: bool = False) -> Row | None:
    """The Graphics memory row of an OmacVM.app VM: now and the peak of this
    run, a warning while macOS is short of memory or after refusals. None
    on the other routes. supported: the Mac's hello lists gpu-memory (None:
    not asked yet); offline: the Mac does not answer or refused this VM."""
    if vm_type != "app":
        return None
    mine = tuple(c for c in (checks or []) if c.feature == "gpu-memory" or c.name == "graphics memory")
    if supported is False:
        return Row(GPU_MEMORY_FEATURE, True, Status.UNKNOWN, "the Mac's OmacVM does not say (older than 3.0.0?)", checks=mine)
    if not isinstance(answer, dict):
        return Row(GPU_MEMORY_FEATURE, True, Status.UNKNOWN, "needs the Mac" if offline else "asking the Mac", checks=mine)
    if answer.get("measured") is not True:
        return Row(GPU_MEMORY_FEATURE, True, Status.UNKNOWN, "not measured yet (the VM's app is older, or it just started)",
                   checks=mine)
    now = _count(answer.get("in_use_mb"))
    peak = max(_count(answer.get("peak_mb")), now)
    note = f"{gb(now)} (peak {gb(peak)})"
    # macOS's "warn" alone is no problem of the VM's: a Mac that gives a VM
    # half its memory sits there for good (a 16 GB Mac mini with an 8 GB VM,
    # 34 % free, 2026-10-08), and the app already hands the VM's cache back.
    # Something for the person only once macOS is critical or graphics
    # memory was refused or lost.
    warn = []
    if answer.get("pressure") == "critical":
        warn.append("macOS is out of memory: close apps on the Mac or in the VM")
    refused = _count(answer.get("refused"))
    if refused:
        warn.append(f"{refused} refused this run: an app that draws nothing needs a restart")
    lost = _count(answer.get("lost"))
    if lost:
        warn.append(f"{lost} lost this run: an app that went black needs a restart")
    if warn:
        return Row(GPU_MEMORY_FEATURE, True, Status.NEEDS_PERSON, "; ".join([note] + warn), checks=mine)
    if answer.get("pressure") == "warn":
        return Row(GPU_MEMORY_FEATURE, True, Status.WORKS,
                   f"{note}; macOS memory is tight, the VM gives back what it can", checks=mine)
    return Row(GPU_MEMORY_FEATURE, True, Status.WORKS, note, checks=mine)


# ---- the Mac's Magic Mouse swipe (GET/POST /omacvm/settings/mouse-swipe) ----
# The same words as OmacVM.app's row (MouseSwipeSetting.swift).
MOUSE_SWIPE_FEATURE = Feature(
    name="mouse-swipe", default="4", sides=("mac",), tags=(), needs="gestures", title="Magic Mouse swipe",
    summary="What a two-finger swipe on the mouse does in the VM: the same as this many fingers on a trackpad. "
            "Omarchy switches workspaces with 4.")


def mouse_swipe_row(answer: dict | None, gestures_on: bool = True, offline: bool = False) -> Row | None:
    """The Magic Mouse swipe row: only while the Mac has a Magic Mouse (its
    last answer says so). Gestures off: the setting stays, the row says why
    nothing swipes. offline: the Mac does not answer right now."""
    if not isinstance(answer, dict) or answer.get("magic_mouse") is not True:
        return None
    n = answer.get("fingers")
    if n not in (3, 4) or isinstance(n, bool):
        return None
    if offline:
        return Row(MOUSE_SWIPE_FEATURE, True, Status.UNKNOWN, f"{n} fingers (needs the Mac)")
    if not gestures_on:
        return Row(MOUSE_SWIPE_FEATURE, False, Status.OFF, f"{n} fingers (Trackpad gestures is off)")
    return Row(MOUSE_SWIPE_FEATURE, True, Status.WORKS, f"{n} fingers")


def next_fingers(n) -> int:
    """Space on the Magic Mouse swipe row: 4 -> 3 -> 4."""
    return 4 if n == 3 else 3
