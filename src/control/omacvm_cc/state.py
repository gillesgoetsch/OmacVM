"""The control centre's model: features, what was chosen, checks, jobs and
updates in, one status per feature out. Pure: no files, no network, so every
rule is unit-tested (tests/test_state.py).

Status order (the first that applies wins):
  busy (a job runs) > unavailable (this Mac or VM can't) > off > unknown
  (no check result yet) > needs a person (a failed check only a person can
  fix: a macOS permission, a setting) > failing > works
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,31}$")

# VMs set up before a feature existed: what they were built with when their
# env does not name it (as features_read_env in src/lib/features.sh).
OFF_WHEN_UNNAMED = {"omanotch", "scroll-momentum", "autologin", "thp-kernel", "control-centre"}


class Status(str, Enum):
    BUSY = "busy"
    UNAVAILABLE = "unavailable"
    OFF = "off"
    UNKNOWN = "unknown"
    NEEDS_PERSON = "needs-person"
    FAILING = "failing"
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
TAG_NOTES = {"experimental": "experimental", "slow": "about 10 min to switch on"}
TAG_HINTS = {"experimental": "experimental: it may change or be removed",
             "slow": "switching it on takes about 10 minutes: a build in the VM, then a restart"}


def tag_note(f: Feature) -> str:
    return ", ".join(TAG_NOTES[t] for t in f.tags if t in TAG_NOTES)


def fixed_note(on: bool) -> str:
    """The table's note for a feature whose record the Mac just fixed."""
    return f"OmacVM's record said {'off' if on else 'on'}: fixed"


def feature_about(f: Feature, macos: str = "") -> str:
    """More than the summary, for the details screen ("" nothing more).
    macos: the Mac's macOS version as the Bridge says it ("" not known)."""
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


def status_of(f: Feature, on: bool, avail: Avail | None, checks: list[Check] | None,
              job: Job | None) -> tuple[Status, str]:
    """One feature's status and the short note shown next to it.
    checks None: no check result yet; [] : checked, nothing about it."""
    if job is not None and job.active:
        step = f" ({job.step}/{job.of})" if job.of else ""
        return Status.BUSY, (job.text or job.action) + step
    if avail is not None and not avail.ok:
        return Status.UNAVAILABLE, avail.reason
    if not on:
        return Status.OFF, ""
    if checks is None:
        return Status.UNKNOWN, "not checked yet"
    failed = [c for c in checks if c.status == "fail"]
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
               show_updates: bool = True, fixed: dict[str, str] | None = None) -> list[Row]:
    """The features screen. mac_features: what the Mac's OmacVM knows (None:
    not known); a feature it lacks is unavailable until the Mac is updated.
    show_updates False (update checks off): no update marks, but an update
    that runs still shows on the features it changes. fixed: the features
    whose record the Mac fixed to their real state (omacvm features --json
    "fixed"); on must already say that state."""
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
        st, note = status_of(f, on.get(f.name, False), a, mine, job)
        if (fixed or {}).get(f.name) and st in (Status.WORKS, Status.OFF, Status.UNKNOWN):
            note = fixed_note(on.get(f.name, False))
        rows.append(Row(feature=f, on=on.get(f.name, False), status=st, note=note,
                        update=update and show_updates, checks=tuple(mine or ())))
    return rows


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
GRAPHICS_FEATURE = Feature(
    name="graphics", default="auto", sides=("mac",), tags=(), needs=None, title="Graphics",
    summary="OpenGL, Vulkan, or Automatic (OpenGL on every Mac in 3.0.0); from the VM's next start")


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
    note = f"{title}: {now}" if now and now == nxt else f"{title}: {nxt} from the next start"
    if g.get("waiting_for_driver") is True:
        # Vulkan chosen, no Venus driver for the Mac's pages yet: OpenGL until
        # an apply (or Space on this row while the VM runs) builds it.
        note = str(g.get("summary") or "Vulkan (driver not built yet: runs on OpenGL until the next apply)")
    elif str(g.get("summary") or "").startswith(GRAPHICS_DID_NOT_START):
        # A Vulkan start showed nothing on this Mac; the app started it on
        # OpenGL and stays there until Vulkan is chosen again (Space here).
        note = str(g["summary"])
    if any(c.status == "fail" for c in mine):
        bad = next(c for c in mine if c.status == "fail")
        return Row(GRAPHICS_FEATURE, True, Status.NEEDS_PERSON if bad.human else Status.FAILING,
                   f"{note}; {bad.name}: {bad.detail}", checks=mine)
    return Row(GRAPHICS_FEATURE, True, Status.WORKS, note, checks=mine)


def next_graphics(current: str) -> str:
    """Space on the Graphics row: Automatic -> OpenGL -> Vulkan -> Automatic."""
    i = GRAPHICS_CHOICES.index(current) if current in GRAPHICS_CHOICES else -1
    return GRAPHICS_CHOICES[(i + 1) % len(GRAPHICS_CHOICES)]


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
    warn = []
    if answer.get("pressure") in ("warn", "critical"):
        warn.append("macOS is short of memory: close apps on the Mac or in the VM")
    refused = _count(answer.get("refused"))
    if refused:
        warn.append(f"{refused} refused this run: an app that draws nothing needs a restart")
    if warn:
        return Row(GPU_MEMORY_FEATURE, True, Status.NEEDS_PERSON, "; ".join([note] + warn), checks=mine)
    return Row(GPU_MEMORY_FEATURE, True, Status.WORKS, note, checks=mine)
