"""The control centre's moving parts in one place, for the TUI and the plain
text output: local files, the Mac's answers, the VM's checks, jobs, updates.
Methods that talk to the Mac or run checks block: the TUI calls them from
worker threads."""
from __future__ import annotations

import dataclasses
import os
import time

from . import state as S
from .bridge import Bridge, BridgeError, Hello
from .local import Local, guest_checks, next_start, write_attention

ACTION_FOR = {True: "enable", False: "disable"}
# With update checks off, an update is installed only from a check this recent
# (the Bridge has the same rule).
FRESH_SECONDS = 3600


def iso_age(stamp) -> float | None:
    """Seconds since an ISO time ("2026-10-05T10:41:00Z"), None if unknown."""
    if not isinstance(stamp, str) or not stamp:
        return None
    try:
        from datetime import datetime, timezone
        t = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        age = time.time() - t.timestamp()
        return age if age > -60 else None   # a time in the future: unknown
    except ValueError:
        return None


def local_time(stamp) -> str:
    """An ISO time ("2026-10-05T20:56:00Z") as this VM's local "YYYY-MM-DD HH:MM"."""
    if not isinstance(stamp, str) or not stamp:
        return "?"
    try:
        from datetime import datetime, timezone
        t = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        return t.astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return stamp[:16].replace("T", " ")


class Controller:
    def __init__(self) -> None:
        self.local = Local()
        self.bridge = Bridge(self.local.env, self.local.version)
        self.hello: Hello | None = None
        self.mac_error: BridgeError | None = None
        c = self.local.cache
        self.mac_status: dict | None = c.get("mac_status") if isinstance(c.get("mac_status"), dict) else None
        self.vm_checks: list[S.Check] | None = None
        if isinstance(c.get("vm_checks"), str):
            self.vm_checks = S.parse_check_tsv(c["vm_checks"])
        self.checked_at: float | None = c.get("checked_at") if isinstance(c.get("checked_at"), (int, float)) else None
        self.from_cache = self.vm_checks is not None or self.mac_status is not None
        self.updates: dict | None = c.get("updates") if isinstance(c.get("updates"), dict) else None
        self.jobs: dict[str, S.Job] = {}
        self.job_lines: dict[str, list[str]] = {}
        # Graphics memory (OmacVM.app): a number of the moment, never cached.
        self.gpu_memory: dict | None = None
        self.gpu_memory_misses = 0
        # The Mac's Magic Mouse swipe ({"magic_mouse", "fingers"}), never cached:
        # the row shows only while the Mac has a Magic Mouse.
        self.mouse_swipe: dict | None = None
        self.mouse_swipe_sets = 0   # bumped around each switch: an older look is not kept
        # Features a job just switched or repaired: their checks from before
        # the job say nothing about them now, so they are left out until the
        # next look of each side (the VM's checks, the Mac's status).
        self.stale_vm: set[str] = set()
        self.stale_mac: set[str] = set()
        self.job_ends = 0   # bumped at each job's end: a look that started before it clears nothing

    # ---- the Mac ----
    @property
    def linked(self) -> bool:
        """The Mac answers and takes requests from this VM."""
        return self.hello is not None and self.mac_error is None

    def mac_looking(self) -> bool:
        """The Mac does not list this VM (yet), or its list has another VM at
        this address (it stopped, this one took its address): it is looking
        again, so ask again in a moment."""
        e = self.mac_error
        return e is not None and (e.code == "unknown-vm" or (e.looking and e.code in ("vm-key", "no-vm-key")))

    def mac_problem(self) -> str:
        """Why switching from here does not work right now ("" if it does)."""
        if self.mac_error is not None:
            return str(self.mac_error)
        if self.hello is None:
            return "still asking the Mac: a moment"
        return ""

    def refresh_mac(self) -> None:
        ends = self.job_ends
        try:
            self.hello = self.bridge.hello()
            self.mac_error = None
        except BridgeError as e:
            self.hello, self.mac_error = None, e
            return
        try:
            st = self.bridge.status()
            if not st.get("pending"):
                self.mac_status = st
                if ends == self.job_ends:
                    self.stale_mac = set()
                self.local.save_cache(mac_status=st)
        except BridgeError as e:
            self.mac_error = e
        self.refresh_mouse_swipe()

    def mouse_swipe_supported(self) -> bool:
        return self.hello is not None and "settings/mouse-swipe" in self.hello.requests

    def refresh_mouse_swipe(self) -> None:
        """The Mac's Magic Mouse swipe. The Mac away or a missed answer keeps
        the last one (the row stays, it says it needs the Mac); a Mac that
        does not list the request has none. A look that started before a
        switch ended is dropped: it may be the old value."""
        if self.hello is not None and not self.mouse_swipe_supported():
            self.mouse_swipe = None
            return
        if not self.linked:
            return
        sets = self.mouse_swipe_sets
        try:
            answer = self.bridge.mouse_swipe()
        except BridgeError:
            return
        if sets == self.mouse_swipe_sets:
            self.mouse_swipe = answer

    def set_mouse_swipe(self, fingers: int) -> None:
        self.mouse_swipe_sets += 1
        try:
            self.mouse_swipe = self.bridge.set_mouse_swipe(fingers)
        finally:
            self.mouse_swipe_sets += 1

    def gpu_memory_supported(self) -> bool | None:
        """The Mac answers gpu-memory (None: its hello is not in yet)."""
        return None if self.hello is None else "gpu-memory" in self.hello.requests

    def wants_gpu_memory(self) -> bool:
        return self.local.vm_type == "app" and self.linked and self.gpu_memory_supported() is True

    def refresh_gpu_memory(self) -> None:
        """One look at this VM's graphics memory (OmacVM.app only). A missed
        answer keeps the last numbers; three in a row drop them (the row then
        says it is asking)."""
        if not self.wants_gpu_memory():
            return
        try:
            self.gpu_memory = self.bridge.gpu_memory()
            self.gpu_memory_misses = 0
        except BridgeError:
            self.gpu_memory_misses += 1
            if self.gpu_memory_misses >= 3:
                self.gpu_memory = None

    def refresh_updates(self, check: bool = False) -> dict | None:
        try:
            self.updates = self.bridge.check_updates() if check else self.bridge.updates()
            self.local.save_cache(updates=self.updates)
        except BridgeError as e:
            if check:
                raise
            self.mac_error = self.mac_error or e
        return self.updates

    def set_update_checks(self, on: bool) -> None:
        self.updates = self.bridge.set_update_checks(on)
        self.local.save_cache(updates=self.updates)

    # ---- the VM ----
    def refresh_vm_checks(self) -> None:
        ends = self.job_ends
        checks = guest_checks()
        if checks is not None:
            self.vm_checks = checks
            if ends == self.job_ends:
                self.stale_vm = set()
            self.checked_at = time.time()
            self.from_cache = False
            self.local.save_cache(vm_checks="\n".join(
                f"{c.status}\t{c.name}\t{c.detail}\t{'1' if c.human else ''}\t{c.feature}" for c in checks),
                checked_at=self.checked_at)

    def local_stamp(self) -> tuple:
        """What the VM's env and installed parts look like on disk now (mtimes):
        another window, the Mac or a job may change them."""
        from .local import env_file, installed_file
        out = []
        for p in (env_file(), installed_file()):
            try:
                st = os.stat(p)
                out.append((st.st_mtime_ns, st.st_size))
            except OSError:
                out.append(None)
        return tuple(out)

    def reload_local(self) -> None:
        """After a job: the VM's env and installed parts changed."""
        cache = self.local.cache
        self.local = Local()
        self.local.cache = cache
        self.bridge = Bridge(self.local.env, self.local.version)

    def job_ended(self, job: S.Job) -> None:
        """A job ended: the list follows the VM's env at once. A switch or
        repair that worked was checked by the job itself; the checks from
        before it are set aside until the next look (seconds later), so its
        row does not wait for them, nor show what they said before."""
        self.reload_local()
        self.job_ends += 1
        if job.state == "done" and job.action in ("enable", "disable", "reinstall"):
            self.stale_vm |= set(job.features)
            self.stale_mac |= set(job.features)

    # ---- the model ----
    @property
    def checks_enabled(self) -> bool:
        """The Mac's update check setting (off: no update marks, no prompts)."""
        return (self.updates or {}).get("checks_enabled", True) is not False

    def manifest_fresh(self) -> bool:
        """The update information comes from a check in the last hour."""
        age = iso_age((self.updates or {}).get("checked_at"))
        return age is not None and age < FRESH_SECONDS

    def manifest(self) -> dict | None:
        m = (self.updates or {}).get("manifest")
        return m if isinstance(m, dict) else None

    def mac_version(self) -> str:
        return str((self.updates or {}).get("omacvm") or (self.hello.omacvm if self.hello else "") or "")

    def update_offered(self) -> bool:
        """The release is newer than this VM's OmacVM and not older than the
        Mac's: never a downgrade (a dev checkout, a Mac ahead of the release)."""
        m = self.manifest()
        return m is not None and S.update_offered(m.get("version"), self.local.version, self.mac_version())

    def update_plan(self) -> tuple[str, str]:
        """What u does now (state.PLANS) and the release's version."""
        m = self.manifest()
        if m is None:
            return "none", ""
        u = self.updates or {}
        app_update = self.hello is not None and "app-update" in self.hello.requests
        plan = S.update_plan(m.get("version"), self.local.version, self.mac_version(), u.get("mac_app") is True,
                             self.local.vm_type == "app", app_update)
        return plan, str(m.get("version") or "")

    def update_line(self) -> str:
        """The top line: only with update checks on, or after a check in the last hour."""
        if not (self.checks_enabled or self.manifest_fresh()):
            return ""
        return S.update_line(*self.update_plan())

    def offer(self) -> dict:
        """The release's parts, only when it is an update for this VM."""
        m = self.manifest()
        parts = m.get("parts") if m and self.update_offered() else None
        return parts if isinstance(parts, dict) else {}

    def rows(self, with_updates: bool | None = None) -> list[S.Row]:
        """The features. Update marks only while update checks are on (or
        with_updates=True: the Updates screen, the one place that shows an
        update when they are off)."""
        if with_updates is None:
            with_updates = self.checks_enabled
        avail = {}
        mac_checks = None
        on = dict(self.local.on)
        fixed: dict[str, str] = {}
        if self.mac_status:
            for f in self.mac_status.get("features") or []:
                if isinstance(f, dict) and f.get("name"):
                    avail[f["name"]] = S.Avail(bool(f.get("available", True)), str(f.get("reason") or ""))
                    # A switch just made is newer than the Mac's look from before it.
                    if f["name"] in self.stale_mac:
                        continue
                    # The Mac found the record wrong (switched outside OmacVM) and fixed it:
                    # the real state, until the VM's copy (fixed too) is read again.
                    if f.get("fixed") and isinstance(f.get("on"), bool) and f["name"] in on:
                        on[f["name"]] = f["on"]
                        fixed[f["name"]] = str(f["fixed"])
                    # Only this VM's copy was behind the record (the app's Fast network
                    # switch): the Mac's state, without a note (nothing was wrong there).
                    elif f.get("synced") is True and isinstance(f.get("on"), bool) and f["name"] in on:
                        on[f["name"]] = f["on"]
            if isinstance(self.mac_status.get("checks"), list):
                mac_checks = [c for c in S.parse_mac_checks(self.mac_status["checks"]) if c.feature not in self.stale_mac]
        vm_checks = None if self.vm_checks is None else [c for c in self.vm_checks if c.feature not in self.stale_vm]
        checks = None if vm_checks is None and mac_checks is None else (vm_checks or []) + (mac_checks or [])
        mac_features = set(self.hello.features) if self.hello and self.hello.features else None
        rows = S.build_rows(self.local.features, on, vm_type=self.local.vm_type, avail=avail,
                            checks=checks, jobs=list(self.jobs.values()), installed=self.local.installed_parts(),
                            offer=self.offer(), mac_features=mac_features, show_updates=with_updates,
                            fixed=fixed, next_start=next_start(self.local.vm_type, on))
        g = S.graphics_row(self.mac_status, self.local.vm_type, list(self.jobs.values()), checks,
                           offline=self.mac_error is not None)
        # Full screen (including notch or via Omanotch): right after Omanotch,
        # whose row says it is not needed while this start includes the notch.
        na = S.notch_row(self.mac_status, self.local.vm_type, list(self.jobs.values()),
                         offline=self.mac_error is not None)
        if S.notch_fullpanel_now(self.mac_status):
            rows = [dataclasses.replace(r, note=S.OMANOTCH_FULLPANEL_NOTE) if r.feature.name == "omanotch" and r.on
                    and r.status in (S.Status.WORKS, S.Status.FAILING, S.Status.UNKNOWN) else r for r in rows]
        if na is not None:
            at = next((i + 1 for i, r in enumerate(rows) if r.feature.name == "omanotch"), len(rows))
            rows.insert(at, na)
        m = S.gpu_memory_row(self.gpu_memory, self.local.vm_type, self.gpu_memory_supported(), checks,
                             offline=self.mac_error is not None)
        # A Mac setting: the last answer stays while the Mac is away for a moment.
        ms = S.mouse_swipe_row(self.mouse_swipe, on.get("gestures", True), offline=not self.linked)
        if ms is not None:
            # After Trackpad gestures and the features that need it.
            at = max((i + 1 for i, r in enumerate(rows) if "gestures" in (r.feature.name, r.feature.needs)), default=len(rows))
            rows.insert(at, ms)
        return rows + [r for r in (g, m) if r is not None]

    def fixed_of(self, name: str) -> str:
        """What the Mac said it fixed in this feature's record ("" nothing)."""
        for f in (self.mac_status or {}).get("features") or []:
            if isinstance(f, dict) and f.get("name") == name and f.get("fixed"):
                return str(f["fixed"])
        return ""

    def notch(self) -> str:
        """This VM's notch-mode as the Mac last said it ("" unknown)."""
        n = (self.mac_status or {}).get("notch")
        return str(n.get("notch") or "") if isinstance(n, dict) else ""

    def graphics(self) -> str:
        """This VM's Graphics setting as the Mac last said it ("" unknown)."""
        g = (self.mac_status or {}).get("graphics")
        return str(g.get("graphics") or "") if isinstance(g, dict) else ""

    # ---- jobs ----
    def _job(self, d: dict) -> S.Job:
        j = S.Job(id=str(d.get("id", "")), action=str(d.get("action", "")),
                  features=tuple(str(x) for x in d.get("features") or ()), state=str(d.get("state", "running")),
                  step=int(d.get("step") or 0), of=int(d.get("of") or 0), text=str(d.get("text", "")),
                  failed_part=str(d.get("failed_part") or ""), mac_omacvm=str(d.get("mac_omacvm") or ""),
                  failed_side=str(d.get("failed_side") or ""))
        self.jobs[j.id] = j
        self.job_lines[j.id] = [str(x) for x in d.get("lines") or []]
        return j

    def start(self, action: str, features: list[str] | tuple[str, ...] = ()) -> S.Job:
        return self._job(self.bridge.start_job(action, list(features)))

    def poll(self, job_id: str) -> S.Job:
        return self._job(self.bridge.job(job_id))

    def vm_name(self) -> str:
        """This VM's name in its app (from omacvm apply), "" if not known."""
        import base64
        try:
            return base64.b64decode(self.local.env.get("OMACVM_VM_NAME_B64", ""), validate=True).decode("utf-8")
        except ValueError:
            return ""

    def lose(self, job_id: str) -> S.Job:
        """The Mac stopped answering about a job: it ends here as failed (it
        may still finish on the Mac; the next status shows how it went)."""
        j = dataclasses.replace(self.jobs[job_id], state="failed", text="the Mac stopped answering about this job")
        self.jobs[job_id] = j
        return j

    def write_attention(self, rows: list[S.Row]) -> None:
        """For the bar item: how many features need a look, and updates."""
        problems = sum(1 for r in rows if r.status in (S.Status.FAILING, S.Status.NEEDS_PERSON))
        updates = sum(1 for r in rows if r.update) if self.checks_enabled else 0
        write_attention(problems, updates)

    def active_job(self) -> S.Job | None:
        return next((j for j in self.jobs.values() if j.active), None)
