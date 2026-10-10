"""The control centre's screens (Textual, docs/adr/0030): features, details,
updates, report a problem. Colours come from the terminal's palette (an ANSI
theme), so Omarchy's theme applies, as in Impala and bluetui.

The first frame is drawn from local files (and the last answers, cached);
the Mac's answers and the VM's checks come in from worker threads."""
from __future__ import annotations

import os
import shutil
import subprocess
import time

from rich.markup import escape
from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, VerticalScroll
from textual.screen import ModalScreen, Screen
from textual.theme import Theme
from textual.widgets import DataTable, Static, TextArea

from . import collect, look, report, system, touchid_ready
from . import state as S
from .bridge import BridgeError
from .controller import ACTION_FOR, Controller, local_time
from .local import (drop_resume, log_tail, next_start, restart_needed, take_resume, write_restart_needed,
                    write_resume)

# Job polls (one a second) that may fail in a row before the job counts as
# lost: an update restarts the Bridge, which takes a while.
LOST_AFTER = 120
# Graphics memory (OmacVM.app VMs): looked at this often while the control
# centre is open, never while it is closed.
GPU_MEMORY_EVERY = 2.0
# A VM the Mac does not list yet (it just started, or the Bridge did), or
# one whose address the list still gives a stopped VM (a key that does not
# match, "looking"): the Mac looks at its VMs again in the background (at
# most once a minute, and a run can take a while), so ask again for 100 s.
UNKNOWN_TRIES, UNKNOWN_WAIT = 20, 5.0
# While the control centre is open: every 5 s it re-reads the VM's env (a
# change from another window or the Mac) and asks the Mac again, also after
# "no such OmacVM.app VM". Nothing runs while it is closed.
LIVE_EVERY = 5.0
# A switch the Mac refused with unknown-vm (its list caught the VM mid-job:
# nothing started) is sent once more this much later (the Bridge looks again
# at most every 5 s and waits for that look).
JOB_RETRY_AFTER = 3.0
# The end of a failure that needs the VM's whole system updated first
# (src/cmd/apply.sh why_not: pkg-add found the package list older than the
# mirrors, or refused a partial update). Trying again does not help until then.
UPDATE_FIRST = " (omarchy update first)"
# Said before Graphics -> Vulkan or its repair runs (src/cmd/graphics.sh).
VULKAN_BUILD = ("The VM builds its Vulkan driver now, a few minutes (when its packages are too old for that, "
                "after a whole system update with omarchy update, often 5-15 minutes); "
                "until it is there the VM runs on OpenGL.")

THEME = Theme(
    name="omacvm-ansi", ansi=True, dark=True,
    primary="ansi_blue", secondary="ansi_cyan", accent="ansi_magenta",
    warning="ansi_yellow", error="ansi_red", success="ansi_green",
    foreground="ansi_default", background="ansi_default", surface="ansi_default",
    panel="ansi_default", boost="ansi_default",
    variables={"ansi-background": "ansi_black", "ansi-foreground": "ansi_white",
               "input-cursor-background": "ansi_black", "input-cursor-foreground": "ansi_bright_white",
               "input-cursor-text-style": "none", "input-selection-background": "ansi_bright_blue",
               "input-selection-foreground": "ansi_black", "screen-selection-background": "ansi_bright_blue",
               "screen-selection-foreground": "ansi_black",
               "border-blurred": "ansi_bright_black", "block-cursor-foreground": "ansi_black",
               "block-cursor-background": "ansi_blue", "block-cursor-text-style": "none",
               "footer-key-foreground": "ansi_blue", "scrollbar": "ansi_bright_black",
               "scrollbar-hover": "ansi_white", "scrollbar-active": "ansi_white",
               "scrollbar-background": "ansi_default", "scrollbar-background-hover": "ansi_default",
               "scrollbar-background-active": "ansi_default", "scrollbar-corner-color": "ansi_default"},
)

CSS = """
Screen { background: ansi_default; color: ansi_default; }
.box { border: round ansi_blue; border-title-color: ansi_blue; border-title-style: bold;
       border-subtitle-color: ansi_bright_black; padding: 0 1; height: 1fr; }
.keys { height: 1; padding: 0 2; color: ansi_bright_black; }
.banner { height: auto; padding: 0 1; color: ansi_yellow; display: none; }
.banner.show { display: block; }
.hint { height: auto; min-height: 1; color: ansi_bright_black; padding: 0 1; }
DataTable { height: 1fr; background: ansi_default; scrollbar-size-vertical: 1; overflow-x: hidden; }
DataTable > .datatable--header { color: ansi_bright_black; text-style: none; background: ansi_default; }
DataTable > .datatable--cursor { background: ansi_bright_black; color: ansi_default; text-style: bold; }
DataTable:focus > .datatable--cursor { background: ansi_blue; color: ansi_black; }
DataTable > .datatable--hover { background: ansi_default; }
#body, #text { height: auto; }
TextArea { height: 1fr; background: ansi_default; border: round ansi_bright_black; }
ConfirmScreen { align: center middle; background: ansi_default 0%; }
ConfirmScreen > Vertical { width: 72; max-width: 95%; height: auto; border: round ansi_yellow;
                           border-title-color: ansi_yellow; padding: 1 2; background: ansi_default; }
"""


# OmacVM.app gives a VM 3 minutes to shut down for an update; past that it
# stops the update (nothing forced). A little longer here, then it says so.
SHUTDOWN_WAIT = 210.0

# The only place that sends the user to the Mac for an update: the Mac's
# OmacVM.app cannot be asked from this VM (another app's VM, an older Mac).
MANUAL_APP_UPDATE = ("Update OmacVM.app first: shut this VM down, open OmacVM on the Mac and click Check Now. "
                     "Then u here updates this VM.")
MANUAL_APP_UPDATE_OTHER = ("Update OmacVM.app first: open OmacVM on the Mac and click Check Now. "
                           "Then u here updates this VM.")


def app_update_error(e: BridgeError) -> str:
    """A refused app-update in plain words, with the next step."""
    if e.code in ("not-app", "old-bridge", "app-cannot-update"):
        return f"{e}. {MANUAL_APP_UPDATE}" if e.code != "old-bridge" else MANUAL_APP_UPDATE
    if e.code == "not-app-copy":
        return "this Mac has an OmacVM checkout: u updates the Mac and this VM in one go (try u again)"
    if e.kind == "offline":
        return f"{e} (the VM keeps running; u tries again)"
    return str(e)


# R after an update: the VM restarts (kernel, memory and keyboard changes).
REBOOT = ["systemctl", "reboot"]
RESTART_LINE = "Restart the VM to finish (kernel, memory and keyboard changes): R restarts it now."


def keys_line(*pairs: tuple[str, str]) -> Text:
    t = Text()
    for i, (k, what) in enumerate(pairs):
        if i:
            t.append("   ")
        t.append(k, style="bold blue")
        t.append(" " + what)
    return t


def status_cell(r: S.Row, tick: int) -> Text:
    return Text(look.glyph(r.status, tick), style=look.COLOR[r.status])


def open_url(url: str) -> bool:
    opener = shutil.which("xdg-open")
    if not opener:
        return False
    subprocess.Popen([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    return True


def copy_text(text: str) -> bool:
    if shutil.which("wl-copy"):
        return subprocess.run(["wl-copy"], input=text, text=True).returncode == 0
    return False


# ---- a yes/no question ----
class ConfirmScreen(ModalScreen[bool]):
    BINDINGS = [Binding("y,enter", "yes", "yes"), Binding("n,escape,q", "no", "no")]

    def __init__(self, title: str, text: str) -> None:
        super().__init__()
        self.title_text, self.text = title, text

    def compose(self) -> ComposeResult:
        with Vertical() as v:
            v.border_title = self.title_text
            yield Static(Text(self.text))
            yield Static("")
            yield Static(keys_line(("y", "go"), ("n", "cancel")))

    def action_yes(self) -> None:
        self.dismiss(True)

    def action_no(self) -> None:
        self.dismiss(False)


# ---- 1. features ----
class FeaturesScreen(Screen):
    BINDINGS = [
        Binding("space", "toggle", "on/off"), Binding("r", "repair", "repair"), Binding("u", "update", "update"),
        Binding("enter", "details", "details", priority=True), Binding("U", "updates", "updates"),
        Binding("exclamation_mark", "report", "report"), Binding("escape,q", "app.quit", "quit"),
        Binding("R", "app.restart_vm", "restart the VM", show=False),
        Binding("j", "down", show=False), Binding("k", "up", show=False),
    ]

    # The cursor's row that went: (name, where the cursor waits, title).
    away: tuple[str, int, str] | None = None
    away_said = False

    def compose(self) -> ComposeResult:
        with Vertical(classes="box") as box:
            box.border_title = f"OmacVM {self.app.c.local.version}"
            yield DataTable(cursor_type="row", zebra_stripes=False, show_cursor=True)
            yield Static("", classes="hint", id="hint")
            yield Static("", classes="banner", id="banner")
        yield Static(keys_line(("space", "on/off"), ("r", "repair"), ("u", "update"), ("enter", "details"),
                               ("U", "updates"), ("!", "report"), ("esc", "quit")), classes="keys")

    def on_mount(self) -> None:
        t = self.query_one(DataTable)
        t.add_column(" ", key="st", width=1)
        t.add_column(" ", key="up", width=1)
        t.add_column("FEATURE", key="title")
        t.add_column("", key="note")
        self.redraw()
        t.focus()

    @property
    def table(self) -> DataTable:
        return self.query_one(DataTable)

    def selected(self) -> S.Row | None:
        rows = self.app.rows
        i = self.table.cursor_row
        return rows[i] if 0 <= i < len(rows) else None

    def redraw(self) -> None:
        app: ControlCentre = self.app  # type: ignore[assignment]
        rows = app.rows = app.c.rows()
        t = next(iter(self.query(DataTable)), None)
        if t is None or not t.columns:   # not mounted yet (on_mount draws), or closing
            return
        keep = t.cursor_row
        before = [k.value for k in t.rows]
        # The note gets what is left: borders, padding, the other columns and their cell padding.
        title_w = max(len(r.feature.title) for r in rows)
        width = max(16, self.size.width - 4 - 3 - 3 - (title_w + 2) - 3)
        # Rows come and go (Magic Mouse swipe with the mouse): new keys, new
        # table, the cursor stays on its row. If its row went, the cursor
        # waits on the row that took its place and goes back when it returns.
        names = [r.feature.name for r in rows]
        if before != names:
            gone = before[keep] if 0 <= keep < len(before) else None
            gone_title = str(t.get_cell(gone, "title")) if gone is not None else ""
            t.clear()
            for r in rows:
                t.add_row(status_cell(r, app.tick), "", r.feature.title, "", key=r.feature.name)
            if self.away is not None and self.away[0] in names and keep == self.away[1]:
                keep = names.index(self.away[0])
                self.away = None
            elif gone in names:
                keep = names.index(gone)
            elif gone is not None and self.away is None:
                keep = min(keep, len(names) - 1)
                self.away = (gone, keep, gone_title)
                self.away_said = False
        for r in rows:
            dim = r.status in (S.Status.UNAVAILABLE, S.Status.OFF)
            note = r.note or S.tag_note(r.feature, r.on)
            if len(note) > width:
                note = note[: width - 1] + "…"
            style = {S.Status.NEEDS_PERSON: "yellow", S.Status.FAILING: "red", S.Status.BUSY: "cyan",
                     S.Status.NEXT_START: "blue"}.get(r.status, "bright_black")
            t.update_cell(r.feature.name, "st", status_cell(r, app.tick))
            t.update_cell(r.feature.name, "title", Text(r.feature.title, style="bright_black" if dim else ""))
            t.update_cell(r.feature.name, "note", Text(note, style=style if (r.note or dim) else "bright_black"))
            t.update_cell(r.feature.name, "up", Text(look.UPDATE, style="magenta") if r.update else "")
        if 0 <= keep < len(rows):
            t.move_cursor(row=keep)
        self.show_banner()
        box = self.query_one(".box")
        # After an update this VM has another OmacVM: the title follows.
        box.border_title = f"OmacVM {app.c.local.version}"
        box.border_subtitle = app.subtitle()
        self.show_hint()

    def show_banner(self) -> None:
        """The banner alone (once a second while an update runs)."""
        app: ControlCentre = self.app  # type: ignore[assignment]
        text = app.banner_text(self.size.width - 4)
        self.query_one("#banner", Static).update(text)
        self.query_one("#banner").set_class(bool(text.plain), "show")

    def show_hint(self) -> None:
        r = self.selected()
        hint = ""
        if r is not None:
            on = "on" if r.on else "off"
            hint = f"{r.feature.summary}  ·  {on}, {look.WORD[r.status]}"
        self.query_one("#hint", Static).update(Text(hint, style="bright_black"))

    @on(DataTable.RowHighlighted)
    def _highlight(self) -> None:
        if self.away is not None and self.table.cursor_row != self.away[1]:
            self.away = None   # moved on: it is the user's row now
        self.show_hint()

    def row_went(self) -> bool:
        """The cursor's row went and the cursor has not moved since: say so
        once, instead of acting on the row that took its place."""
        if self.away is None or self.away_said or self.table.cursor_row != self.away[1]:
            return False
        r = self.selected()
        now = f": the cursor is on {r.feature.title} now" if r is not None else ""
        self.notify(f"{self.away[2]} went away{now}", severity="warning")
        self.away_said = True
        return True

    def action_down(self) -> None:
        self.table.action_cursor_down()

    def action_up(self) -> None:
        self.table.action_cursor_up()

    def action_toggle(self) -> None:
        r = self.selected()
        if r is not None and not self.row_went():
            self.app.toggle(r)

    def action_repair(self) -> None:
        r = self.selected()
        if r is not None and not self.row_went():
            self.app.repair(r)

    def action_update(self) -> None:
        self.app.install_update()

    def action_details(self) -> None:
        r = self.selected()
        if r is not None:
            self.app.push_screen(DetailsScreen(r.feature.name))

    def action_updates(self) -> None:
        self.app.push_screen(UpdatesScreen())

    def action_report(self) -> None:
        self.app.push_screen(ReportScreen())


# ---- 2. details ----
class DetailsScreen(Screen):
    BINDINGS = [Binding("escape,q", "app.pop_screen", "back"), Binding("space", "toggle", "on/off"),
                Binding("r", "repair", "repair"), Binding("u", "update", "update"), Binding("l", "log", "log")]

    def __init__(self, name: str) -> None:
        super().__init__()
        self.fname = name
        self.full_log = False
        self.log_lines: list[str] = []

    def compose(self) -> ComposeResult:
        with VerticalScroll(classes="box") as box:
            yield Static("", id="body")
        yield Static(keys_line(("space", "on/off"), ("r", "repair"), ("u", "update"), ("l", "log"), ("esc", "back")),
                     classes="keys")

    def on_mount(self) -> None:
        self.load_log()
        self.redraw()

    @work(thread=True, exclusive=True, group="log")
    def load_log(self) -> None:
        lines = log_tail(self.fname, 60 if self.full_log else 12)
        self.app.call_from_thread(self._set_log, lines)

    def _set_log(self, lines: list[str]) -> None:
        self.log_lines = lines
        self.redraw()

    def row(self) -> S.Row | None:
        return next((r for r in self.app.rows if r.feature.name == self.fname), None)

    def redraw(self) -> None:
        r = self.row()
        if r is None:
            return
        app: ControlCentre = self.app  # type: ignore[assignment]
        f = r.feature
        box = self.query_one(".box")
        box.border_title = f.title
        box.border_subtitle = look.WORD[r.status] if r.status in (S.Status.OFF, S.Status.UNAVAILABLE) else f"on · {look.WORD[r.status]}"
        t = Text()
        t.append(f.summary + "\n\n")
        about = S.feature_about(f, app.c.hello.macos if app.c.hello else "")
        if about:
            t.append(about + "\n\n")

        def field(k: str, v: str) -> None:
            t.append(f"{k:<9}", style="bright_black")
            t.append(v)

        field("Sides", " + ".join("Mac" if s == "mac" else "VM" for s in f.sides) or "VM")
        t.append("     ")
        field("Needs", f.needs or "–")
        t.append("     ")
        hints = S.tag_hints(f, r.on)
        t.append("\n")
        for h in hints:
            field("Note", h)
            t.append("\n")
        inst = app.c.local.installed_parts().get(f.name, {})
        offer = app.c.offer().get(f.name, {})
        version = inst.get("release") or app.c.local.version
        if r.update and offer:
            note = f": {offer['note']}" if offer.get("note") else ""
            field("Version", f"{version} ({offer.get('release', '?')} available{note})")
        else:
            field("Version", version)
        t.append("\n")
        fixed = app.c.fixed_of(f.name)
        if fixed:
            t.append("\n")
            field("Record", fixed)
            t.append("\n")
        if r.detail:
            t.append("\n")
            field("Now", r.detail)
            t.append("\n")
        elif (r.status in (S.Status.UNAVAILABLE, S.Status.BUSY, S.Status.NEXT_START)
              or f.name in ("gpu-memory", "graphics")) and r.note:
            t.append("\n")
            field("Now", r.note)
            t.append("\n")
        t.append("\nChecks\n", style="bold")
        if not r.checks:
            t.append("  " + ("off: nothing to check" if not r.on else "no check result yet" if r.status is S.Status.UNKNOWN
                             else "nothing failed") + "\n", style="bright_black")
        for c in r.checks:
            mark, style = {"ok": ("ok", "green"), "skip": ("›", "blue") if c.human else ("–", "bright_black"),
                           "fail": ("!" if c.human else "x", "yellow" if c.human else "red")}[c.status]
            t.append(f"  {mark:<3}", style=style)
            t.append(f"{'Mac' if c.side == 'mac' else 'VM':<4}", style="bright_black")
            t.append(c.name)
            if c.detail:
                # A long detail (often the step to take) on its own line, under the name.
                sep = f"\n{' ' * 9}" if len(c.name) + len(c.detail) + 11 > self.size.width - 4 else "  "
                # A step for the person (a failure, or a hint such as 1Password's own switch) stands out.
                t.append(sep + c.detail, style="" if c.status == "fail" or c.human else "bright_black")
            t.append("\n")
        t.append(f"\nLog, last {60 if self.full_log else 12} lines" + ("" if self.full_log else "  (l: more)") + "\n", style="bold")
        for line in self.log_lines or ["(nothing logged)"]:
            t.append("  " + line + "\n", style="bright_black")
        self.query_one("#body", Static).update(t)

    def action_toggle(self) -> None:
        r = self.row()
        if r is not None:
            self.app.toggle(r)

    def action_repair(self) -> None:
        r = self.row()
        if r is not None:
            self.app.repair(r)

    def action_update(self) -> None:
        self.app.install_update()

    def action_log(self) -> None:
        self.full_log = not self.full_log
        self.load_log()


# ---- 3. updates ----
class UpdatesScreen(Screen):
    BINDINGS = [Binding("escape,q", "app.pop_screen", "back"), Binding("i,u", "install", "install now"),
                Binding("c", "check", "check again"), Binding("s", "setting", "checks on/off"),
                Binding("o", "omarchy", "update Omarchy"), Binding("R", "app.restart_vm", "restart the VM", show=False)]

    def compose(self) -> ComposeResult:
        with VerticalScroll(classes="box") as box:
            box.border_title = "Updates"
            yield Static("", id="body")
        yield Static(keys_line(("i", "install now"), ("c", "check again"), ("s", "weekly checks on/off"),
                               ("o", "update Omarchy"), ("esc", "back")), classes="keys")

    def on_mount(self) -> None:
        self.redraw()
        if self.app.omarchy_waiting is None:
            self.count_omarchy()

    @work(thread=True, exclusive=True, group="omarchy")
    def count_omarchy(self) -> None:
        n = system.waiting()
        self.app.call_from_thread(self.counted, n)

    def counted(self, n: int | None) -> None:
        self.app.omarchy_waiting = n
        if self.app.is_running and self in self.app.screen_stack:   # not after esc, nor while the app closes
            self.redraw()

    def redraw(self) -> None:
        app: ControlCentre = self.app  # type: ignore[assignment]
        u = app.c.updates or {}
        m = u.get("manifest") if isinstance(u.get("manifest"), dict) else None
        box = self.query_one(".box")
        box.border_subtitle = f"checked {local_time(u['checked_at'])}" if u.get("checked_at") else "not checked yet"
        t = Text()
        # What runs now, or how the last update went (and a restart that waits).
        now = app.progress()
        if now:
            t.append_text(app.progress_text(now, self.size.width - 4))
            t.append("\n\n")
        elif app.last_result:
            t.append(app.last_result + "\n\n", style="green" if app.last_result.startswith("Updated to") else "yellow")
        elif app.restart_after:
            t.append(f"OmacVM {app.restart_after} is in. {RESTART_LINE}\n\n", style="green")
        if not app.c.linked and not u:
            t.append(f"The Mac does not answer: {app.c.mac_problem()}\n", style="yellow")
        if u.get("offline"):
            t.append("No connection at the last try: this is the result from before.\n\n", style="yellow")
        elif u.get("error") and not m:
            t.append(f"{u['error']}\n\n", style="yellow")
        all_rows = app.c.rows(with_updates=True)
        rows = [r for r in all_rows if r.update]
        if m:
            mac = app.c.mac_version() or "?"
            vm = app.c.local.version
            if not app.c.update_offered():
                # Never a downgrade: a VM or Mac ahead of the release has nothing to install.
                newer = [f"this VM has {vm}" if vm != m.get("version") else "",
                         f"the Mac has {mac}" if mac not in (m.get("version"), "?") else ""]
                ahead = ", ".join(x for x in newer if x)
                t.append(f"Up to date: OmacVM {m.get('version')} is the latest release"
                         + (f" ({ahead})" if ahead else "") + ".\n", style="green")
            else:
                who = "the Mac and this VM" if mac != m.get("version") else "this VM"
                t.append(f"OmacVM {vm} → {m.get('version')}", style="bold")
                t.append(f"  ({who})\n\n")
                inst = app.c.local.installed_parts()
                width = max((len(r.feature.title) for r in rows), default=10)
                for r in rows:
                    o = app.c.offer().get(r.feature.name, {})
                    old = inst.get(r.feature.name, {}).get("release", vm)
                    t.append(f"  {look.UPDATE} ", style="magenta")
                    t.append(f"{r.feature.title:<{width}}  {old} → {o.get('release', '?')}")
                    if o.get("note"):
                        t.append(f"   {o['note']}", style="bright_black")
                    t.append("\n")
                n = len(all_rows) - len(rows)
                t.append(f"    {n} features unchanged\n", style="bright_black")
                if any(app.c.offer().get(k, {}).get("digest") != app.c.local.installed_parts().get(k, {}).get("digest")
                       for k in ("core",)):
                    t.append("    and OmacVM's own scripts\n", style="bright_black")
            if m.get("notes_url"):
                t.append("\n  Notes  ", style="bright_black")
                t.append(m["notes_url"] + "\n")
        elif not u.get("error") and app.c.linked:
            t.append("No update information yet: c checks now.\n")
        on_ = app.c.checks_enabled
        if m and not on_ and not app.c.manifest_fresh():
            t.append("\n  Update checks are off: this result may be old. u checks and updates.\n", style="yellow")
        t.append("\n  Update checks  ", style="bright_black")
        t.append("[x] weekly" if on_ else "[ ] off", style="bold" if on_ else "yellow")
        t.append("     (off: no checks, no prompts; c still checks when you ask)\n", style="bright_black")
        # The VM's own system: Omarchy's update, apart from OmacVM's.
        t.append("\nThe VM's system", style="bold")
        t.append("  (Omarchy and its Arch packages, not OmacVM)\n")
        line = system.waiting_line(app.omarchy_waiting)
        if line:
            t.append(f"  {line}\n")
        t.append("  o runs omarchy update in its own window, then checks the graphics before a restart.\n",
                 style="bright_black")
        self.query_one("#body", Static).update(t)

    def action_install(self) -> None:
        self.app.install_update()

    def action_omarchy(self) -> None:
        app: ControlCentre = self.app  # type: ignore[assignment]
        app.push_screen(ConfirmScreen("Update Omarchy (the VM's system)",
                                      system.WHAT + "\n\nIt runs in its own window and asks for your password. "
                                      "At the end it checks the graphics and says whether a restart is safe."),
                        app.system_update_answer)

    @work(thread=True, exclusive=True, group="updates")
    def action_check(self) -> None:
        app: ControlCentre = self.app  # type: ignore[assignment]
        app.call_from_thread(app.notify, "checking for updates ...", timeout=2)
        app.call_from_thread(self.count_omarchy)
        try:
            app.c.refresh_updates(check=True)
        except BridgeError as e:
            app.call_from_thread(app.notify, str(e), severity="warning")
        app.call_from_thread(app.refresh_all)

    @work(thread=True, exclusive=True, group="updates")
    def action_setting(self) -> None:
        app: ControlCentre = self.app  # type: ignore[assignment]
        on_ = not (app.c.updates or {}).get("checks_enabled", True)
        try:
            app.c.set_update_checks(on_)
            app.call_from_thread(app.notify, "weekly update checks on" if on_ else "update checks off: no checks, no prompts")
        except BridgeError as e:
            app.call_from_thread(app.notify, str(e), severity="warning")
        app.call_from_thread(app.refresh_all)


# ---- 4. report a problem ----
class ReportScreen(Screen):
    BINDINGS = [Binding("escape", "back", "back"), Binding("o", "open", "open issue"), Binding("s", "save", "save"),
                Binding("y", "copy", "copy"), Binding("e", "edit", "edit")]

    def __init__(self) -> None:
        super().__init__()
        self.rep: report.Report | None = None
        self.known: report.Known | None = None
        self.editing = False

    def compose(self) -> ComposeResult:
        with Vertical(classes="box") as box:
            box.border_title = "Report a problem"
            yield Static("Collecting checks, versions and logs, without personal data ...", id="what")
            yield TextArea("", read_only=True, soft_wrap=True, show_line_numbers=False)
            yield Static("", id="out")
        yield Static(keys_line(("o", "open GitHub issue"), ("s", "save to file"), ("y", "copy"), ("e", "edit text"),
                               ("esc", "back")), classes="keys")

    def on_mount(self) -> None:
        self.collect()

    @work(thread=True, exclusive=True)
    def collect(self) -> None:
        app: ControlCentre = self.app  # type: ignore[assignment]
        c = app.c
        lines = next((c.job_lines[j.id] for j in reversed(list(c.jobs.values())) if j.state in ("failed", "rolled-back")), None)
        try:
            self.known = collect.vm_known(c.local, c.bridge if c.linked else None)
            sections = collect.vm_sections(c.local, app.rows, (c.vm_checks or []) + [
                ch for r in app.rows for ch in r.checks if ch.side == "mac"], c.hello, lines)
            failing = [r.feature.title for r in app.rows if r.status in (S.Status.FAILING, S.Status.NEEDS_PERSON)]
            title = f"{', '.join(failing[:2])}: " if failing else ""
            rep = report.build(sections, self.known, f"{title}problem in OmacVM {c.local.version} ({c.local.vm_type or 'VM'})")
            app.call_from_thread(self.show, rep, "")
        except report.RedactionFailed as e:
            app.call_from_thread(self.show, None, f"redaction failed ({e}): nothing is shown or sent. Please report this as a bug without logs.")

    def show(self, rep: report.Report | None, error: str) -> None:
        self.rep = rep
        what = self.query_one("#what", Static)
        if rep is None:
            what.update(Text(error, style="red"))
            return
        what.update(Text("This is everything that goes into the issue (you submit it on GitHub):", style="bright_black"))
        self.query_one(TextArea).load_text(rep.text)
        self.query_one("#out", Static).update(Text("Taken out: " + report.taken_out(rep.counts), style="bright_black"))

    def current(self) -> report.Report | None:
        """The text as shown; after an edit, checked again."""
        if self.rep is None or self.known is None:
            return None
        text = self.query_one(TextArea).text
        if text == self.rep.text:
            return self.rep
        try:
            redacted, counts = report.redact(text, self.known)
            report.gate(redacted, self.known)
        except report.RedactionFailed:
            self.app.notify("the edited text has personal data the redaction could not take out", severity="error")
            return None
        merged = dict(self.rep.counts)
        for k, v in counts.items():
            merged[k] = merged.get(k, 0) + v
        if redacted != text:
            self.query_one(TextArea).load_text(redacted)
        return report.Report(text=redacted, counts=merged, title=self.rep.title)

    def action_open(self) -> None:
        rep = self.current()
        if rep is None:
            return
        url, cut = report.issue_url(rep)
        if cut:
            copy_text(rep.text)
        if open_url(url):
            self.app.notify("the issue opens in the browser" + (": the full report is on the clipboard, paste it there" if cut else ""))
        else:
            self.app.notify("no browser (xdg-open): s saves the report", severity="warning")

    def action_save(self) -> None:
        rep = self.current()
        if rep is None:
            return
        path = os.path.expanduser(f"~/omacvm-report-{time.strftime('%Y%m%d-%H%M')}.md")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# {rep.title}\n\n{rep.text}")
        self.app.notify(f"saved: {path.replace(os.path.expanduser('~'), '~', 1)}")

    def action_copy(self) -> None:
        rep = self.current()
        if rep is not None:
            self.app.notify("copied" if copy_text(rep.text) else "no wl-copy here: s saves it", severity="information")

    def action_edit(self) -> None:
        ta = self.query_one(TextArea)
        self.editing = not self.editing
        ta.read_only = not self.editing
        if self.editing:
            ta.focus()
            self.app.notify("editing: esc ends it; the text is checked again before it goes anywhere")
        else:
            self.current()

    def action_back(self) -> None:
        if self.editing:
            self.action_edit()
        else:
            self.app.pop_screen()


# ---- the app ----
class ControlCentre(App):
    CSS = CSS
    TITLE = "OmacVM"
    ENABLE_COMMAND_PALETTE = False

    def __init__(self, c: Controller) -> None:
        super().__init__(ansi_color=True)
        self.c = c
        self.rows: list[S.Row] = c.rows()
        self.tick = 0
        self.watching: str | None = None
        self.last_result = ""   # the last job's outcome and what to do next (the banner)
        self.gpu_asking = False  # a look at graphics memory is under way
        self.mouse_swipe_sending = False   # a Magic Mouse swipe switch is under way
        self.omarchy_waiting: int | None = None   # package updates waiting (checkupdates)
        # The update through OmacVM.app: (release, step 1-4 of state.APP_STEPS), None otherwise.
        self.app_step: tuple[str, int] | None = None
        self.started_at = 0.0     # when the update or job on show started (monotonic)
        self.waiting_mac = ""     # why the job's answers are late
        self.restart_after = restart_needed()   # an update in this boot waits for a restart
        self.shutdown_asked = 0.0   # when OmacVM.app said it shuts this VM down (monotonic)

    def on_mount(self) -> None:
        self.register_theme(THEME)
        self.theme = THEME.name
        self.push_screen(FeaturesScreen())
        self.ask_mac()
        self.run_checks()
        self.set_interval(0.12, self.spin)
        self.stamp = self.c.local_stamp()
        self.set_interval(LIVE_EVERY, self.live)
        self.set_interval(GPU_MEMORY_EVERY, self.look_gpu_memory)
        self.set_interval(1.0, self.tick_progress)

    # ---- data ----
    def live(self) -> None:
        from textual.worker import WorkerState
        if any(w.group in ("mac", "job", "after-job", "live") and w.state in (WorkerState.PENDING, WorkerState.RUNNING)
               for w in self.workers):
            return   # a first look or a job is on it; it refreshes when done
        self.live_refresh()

    @work(thread=True, exclusive=True, group="live")
    def live_refresh(self) -> None:
        stamp = self.c.local_stamp()
        changed = stamp != self.stamp
        self.stamp = stamp
        if changed:
            self.c.reload_local()
        self.c.refresh_mac()
        if changed:
            self.c.refresh_vm_checks()
        self.call_from_thread(self.refresh_all)
        self.maybe_resume()

    @work(thread=True, exclusive=True, group="mac")
    def ask_mac(self) -> None:
        from textual.worker import get_current_worker
        worker = get_current_worker()
        for _ in range(UNKNOWN_TRIES):
            self.c.refresh_mac()
            if not self.c.mac_looking() or worker.is_cancelled:
                break
            self.call_from_thread(self.refresh_all)
            time.sleep(UNKNOWN_WAIT)
        if self.c.linked:
            self.c.refresh_updates()
            self.c.refresh_gpu_memory()
        self.call_from_thread(self.refresh_all)
        self.maybe_resume()

    def maybe_resume(self) -> None:
        """OmacVM.app restarted this VM for an update: this VM's part now,
        once the Mac answers (from a worker thread)."""
        if not self.c.linked:
            return
        version = take_resume()
        if version:
            self.call_from_thread(self.resume_update, version)

    def look_gpu_memory(self) -> None:
        """Every 2 s while open: one look at a time, only on OmacVM.app VMs the Mac answers for."""
        if self.gpu_asking or not self.c.wants_gpu_memory():
            return
        self.gpu_asking = True
        self.ask_gpu_memory()

    @work(thread=True, group="gpu-memory")
    def ask_gpu_memory(self) -> None:
        before = self.c.gpu_memory
        try:
            self.c.refresh_gpu_memory()
        finally:
            self.call_from_thread(self.gpu_memory_done, before != self.c.gpu_memory)

    def gpu_memory_done(self, changed: bool) -> None:
        self.gpu_asking = False
        if changed:
            self.refresh_all()

    @work(thread=True, exclusive=True, group="checks")
    def run_checks(self) -> None:
        self.c.refresh_vm_checks()
        self.call_from_thread(self.refresh_all)

    # The timers and the workers' answers find nothing to draw on once the app
    # closes: Textual takes the screens' widgets down, then the screens, while
    # the app's timers still run (q while a job runs; every test's end).
    def refresh_all(self) -> None:
        self.rows = self.c.rows()
        if self.c.vm_checks is not None and not self.c.from_cache:
            self.c.write_attention(self.rows)
        if not self.is_running:
            return
        for s in self.screen_stack:
            if hasattr(s, "redraw"):
                s.redraw()

    def spin(self) -> None:
        if not self.is_running:
            return
        if any(r.status is S.Status.BUSY for r in self.rows):
            self.tick += 1
            s = self.screen
            t = next(iter(s.query(DataTable)), None) if isinstance(s, FeaturesScreen) else None
            if t is not None:   # none while the app closes
                for r in self.rows:
                    if r.status is S.Status.BUSY:
                        t.update_cell(r.feature.name, "st", status_cell(r, self.tick))

    def tick_progress(self) -> None:
        """Once a second while an update runs: the time on it moves on."""
        if self.app_step is not None and self.app_step[1] == 2 and self.shutdown_asked \
                and time.monotonic() - self.shutdown_asked > SHUTDOWN_WAIT:
            # Still running: OmacVM.app stopped the update (the Mac asks before it forces anything).
            drop_resume()
            self.app_step, self.started_at, self.shutdown_asked = None, 0.0, 0.0
            self.last_result = ("This VM did not shut down in 3 minutes, so OmacVM.app stopped the update; nothing "
                                "changed. Close what may block the shutdown and press u again (the Mac also offers "
                                "Force Off and Update).")
            self.refresh_all()
            return
        if not self.progress() or not self.is_running:
            return
        for s in self.screen_stack:
            if isinstance(s, FeaturesScreen):
                s.show_banner()
            elif isinstance(s, UpdatesScreen):
                s.redraw()

    def progress(self) -> list[tuple[str, str]]:
        """What an update or job shows while it runs ([] nothing runs)."""
        c = self.c
        j = c.active_job()
        lines = c.job_lines.get(j.id, []) if j is not None else []
        took = ""
        if self.started_at:
            secs = int(time.monotonic() - self.started_at)
            took = f"  ·  {secs // 60}:{secs % 60:02d}"
        if self.app_step is not None:
            version, at = self.app_step
            return S.progress_lines(f"Update to OmacVM {version}{took}", j if at == len(S.APP_STEPS) else None, lines,
                                    steps=S.APP_STEPS, at=at, version=version, waiting=self.waiting_mac)
        if j is None:
            return []
        title = self.describe(j.action, list(j.features))
        if j.action == "update":
            m = c.manifest()
            title = f"Updating to OmacVM {m.get('version')}" if m and m.get("version") else "Updating OmacVM"
        return S.progress_lines(title + took, j, lines, waiting=self.waiting_mac)

    def progress_text(self, lines: list[tuple[str, str]], width: int) -> Text:
        t = Text(no_wrap=True, overflow="ellipsis")
        for i, (line, style) in enumerate(lines):
            if i:
                t.append("\n")
            if len(line) > max(20, width):
                line = line[: max(20, width) - 1] + "…"
            t.append(line, style=style or "default")
        return t

    def banner_text(self, width: int = 100) -> Text:
        """The banner on the features screen: an update's progress, else banner()."""
        now = self.progress()
        if now:
            return self.progress_text(now, width)
        b = self.banner()
        if b.startswith("Updated to"):
            return Text(b, style="green")
        return Text(b)

    def subtitle(self) -> str:
        c = self.c
        n = sum(1 for r in self.rows if r.update)
        parts = [{"parallels": "Parallels", "utm": "UTM", "fusion": "VMware Fusion", "app": "OmacVM.app"}.get(c.local.vm_type, "VM")]
        if c.linked:
            parts.append("Mac linked")
        elif c.mac_error is not None:
            parts.append({"offline": "Mac not reachable", "old": "Mac's OmacVM is older"}.get(c.mac_error.kind, "Mac refused"))
        else:
            parts.append("asking the Mac")
        if n:
            parts.append(f"{n} update{'s' if n != 1 else ''}")
        if c.checked_at:
            parts.append(("checked " if not c.from_cache else "last checked ") + look.ago(time.time() - c.checked_at))
        elif c.vm_checks is None:
            parts.append("checking")
        return " · ".join(parts)

    def banner(self) -> str:
        c = self.c
        j = c.active_job()
        if j is not None:
            # banner_text shows more: the bar, the steps, the latest line.
            return f"{self.describe(j.action, list(j.features))}: {S.job_step(j)}"
        if self.app_step is not None:
            version, at = self.app_step
            return f"Update to OmacVM {version}: {at} of {len(S.APP_STEPS)}, {S.APP_STEPS[at - 1].format(v=version)}"
        if self.last_result:
            return self.last_result
        if self.restart_after:
            return f"OmacVM {self.restart_after} is in. {RESTART_LINE}"
        if c.mac_error is None:
            return c.update_line() if c.linked else ""
        if c.mac_error.kind == "old":
            return "The Mac runs an older OmacVM: update OmacVM on the Mac to switch features from here."
        if c.mac_error.kind == "offline":
            if c.local.vm_type == "app":
                return "OmacVM.app does not answer on this VM's control port: showing this VM's side."
            return "The Mac does not answer (VM network, or OmacVM Bridge not running): showing this VM's side."
        return f"The Mac: {c.mac_error}"

    # ---- actions ----
    def notify(self, message: str, **kw) -> None:   # type: ignore[override]
        """Messages carry text from the Mac (job lines): never markup."""
        super().notify(escape(str(message)), **kw)

    def can_ask(self) -> bool:
        if self.c.active_job() is not None:
            self.notify("a job runs: wait for it", severity="warning")
            return False
        if self.c.hello is None and self.c.mac_error is None:
            self.notify("still asking the Mac: a moment", severity="warning")
            return False
        problem = self.c.mac_problem()
        if problem:
            self.notify(f"needs the Mac: {problem}", severity="warning")
            return False
        return True

    def describe(self, action: str, features: list[str]) -> str:
        titles = {f.name: f.title for f in self.c.local.features}
        names = ", ".join(titles.get(n, n) for n in features)
        if action == "graphics":
            return f"Graphics: {S.GRAPHICS_TITLES.get(features[0] if features else '', '?')}"
        if action == "notch":
            return f"Full screen: {S.NOTCH_TITLES.get(features[0] if features else '', '?')}"
        return {"update": "Update", "reinstall": f"Repair {names}", "enable": f"{names} on",
                "disable": f"{names} off"}.get(action, action)

    def on_the_mac(self, command: str) -> str:
        """An omacvm command for this VM, to run on the Mac."""
        import shlex
        name = self.c.vm_name()
        # The app too: the Mac refuses a name that is in two apps without it.
        kind = self.c.local.vm_type
        which = f" --vm-type {kind}" if kind in ("parallels", "utm", "fusion", "app") else ""
        return f"omacvm {command} --vm {shlex.quote(name) if name else 'NAME'}{which}"

    def outcome(self, what: str, action: str, job: S.Job) -> str:
        """The banner after a job that did not work: what failed, where the VM
        and the Mac are now, what to do next."""
        again = {"enable": "space tries again", "disable": "space tries again", "reinstall": "r tries again",
                 "update": "u tries again"}.get(action, "")
        titles = {f.name: f.title for f in self.c.local.features}
        part = titles.get(job.failed_part, "")
        if part.startswith("The "):
            part = "t" + part[1:]   # mid-sentence
        failed = job.text.strip().rstrip(".") if job.text and "rolled back" not in job.text else ""
        update_first = failed.endswith(UPDATE_FIRST)
        if update_first:
            failed = failed[: -len(UPDATE_FIRST)]
        head = f"{what}: {failed}." if failed else f"{what}: failed."
        vm = self.c.local.version
        if update_first and job.failed_side != "mac":
            # Trying again fails the same way until the VM's system is updated.
            if job.state == "rolled-back" and (action == "update" or (job.mac_omacvm and job.mac_omacvm != vm)):
                mac = f"OmacVM {job.mac_omacvm}" if job.mac_omacvm else "the new OmacVM"
                where = f"The Mac keeps {mac}; this VM went back to OmacVM {vm} and its features. "
            elif job.state == "rolled-back":
                where = "This VM went back to its features from before. "
            else:
                where = ""
            key = again.split(" ")[0] if again else "space"
            return (f"{head} {where}Run omarchy update in the VM first (o on Updates, U), then {key} again "
                    "(! reports the problem).")
        if job.failed_side == "mac":
            # A Mac helper did not build: its last build keeps running there.
            # Trying again from here would stop on it again; the Mac's own
            # omacvm update shows why.
            if action == "update" and job.state != "rolled-back":
                where = f"This VM has OmacVM {vm} now, as the Mac; the helper's last build keeps running on the Mac."
            else:
                where = "This VM was not changed."
            if (self.c.updates or {}).get("mac_app") is True:
                # OmacVM.app's own copy: the app updates it, never omacvm update.
                return f"{head} {where} Update OmacVM.app first: u does it from here (! reports the problem)."
            return f"{head} {where} On the Mac, omacvm update tries it again and shows why (! reports the problem)."
        mac_newer = bool(job.mac_omacvm) and job.mac_omacvm != vm
        # Turning the control centre off from inside it is no way on: it would close.
        cc = job.failed_part == "control-centre"
        if job.state == "rolled-back" and (action == "update" or mac_newer):
            # The Mac stays on its (newer) OmacVM; turning the failed part off
            # or repairing it still runs (the Bridge allows both).
            mac = f"OmacVM {job.mac_omacvm}" if job.mac_omacvm else "the new OmacVM"
            if cc:
                way = f"Later, {again} (the control centre's own part failed: is this VM online for its packages?)"
            elif action == "update":
                way = f"Turn {part} off (space) or repair it (r) to go on, or u tries again" if part else "u tries again"
            else:
                way = f"Turn {part} off (space) to go on without it, or {again}" if part else again[:1].upper() + again[1:]
            return (f"{head} The Mac keeps {mac}; this VM went back to OmacVM {vm} and its features. "
                    f"{way}; on the Mac: {self.on_the_mac('apply')}. ! reports the problem.")
        if job.state == "rolled-back":
            return f"{head} This VM went back to its features from before ({again}; ! reports the problem)."
        return f"{head} On the Mac, {self.on_the_mac('apply')} puts this VM right ({again}; ! reports the problem)."

    def toggle(self, r: S.Row, asked_again: bool = False) -> None:
        if r.feature.name == "graphics":
            self.choose_graphics()
            return
        if r.feature.name == "notch-area":
            self.choose_notch()
            return
        if r.feature.name == "gpu-memory":
            self.notify(f"Graphics memory is measured, not switched. {S.GPU_MEMORY_EXPLAINER}")
            return
        if r.feature.name == "mouse-swipe":
            self.switch_mouse_swipe()
            return
        if r.status is S.Status.UNAVAILABLE:
            self.notify(f"{r.feature.title}: {r.note}", severity="warning")
            return
        if not asked_again and self.mac_may_be_back():
            # The last look found the Mac away (its Bridge restarting, the VM
            # just started): ask it once more now, then switch, instead of a
            # press that does nothing until the next look 5 s later.
            self.ask_again_then_toggle(r)
            return
        if not self.can_ask():
            return
        plan = S.toggle_plan(self.c.local.features, self.c.local.on, r.feature.name)
        turn_on = plan[r.feature.name]
        titles = {f.name: f.title for f in self.c.local.features}
        others = [titles[n] for n in plan if n != r.feature.name]
        texts = []
        if r.feature.name == "control-centre" and not turn_on:
            texts.append("This closes the control centre and takes it out of this VM.\n"
                         "To get it back, on the Mac: omacvm enable control-centre")
        elif others:
            what = "also turns on" if turn_on else "also turns off"
            texts.append(f"{r.feature.title} {what}: {', '.join(others)}.")
        if not turn_on and self.brings_mac_version():
            texts.append(self.brings_mac_version())
        later = S.next_start_note(r.feature.name, turn_on, self.c.local.vm_type)
        if later:
            texts.append(later)
        if not texts:
            self.run_job(ACTION_FOR[turn_on], list(plan))
            return
        self.push_screen(ConfirmScreen(f"{r.feature.title}: {'on' if turn_on else 'off'}", "\n".join(texts)),
                         lambda yes: yes and self.run_job(ACTION_FOR[turn_on], list(plan)))

    def mac_may_be_back(self) -> bool:
        """The last look did not reach the Mac, or the Mac did not list (or
        reach) this VM: worth one more look before a switch says no."""
        e = self.c.mac_error
        return self.c.active_job() is None and e is not None and (e.kind == "offline" or e.code == "unknown-vm")

    @work(thread=True, exclusive=True, group="ask-again")
    def ask_again_then_toggle(self, r: S.Row) -> None:
        self.c.refresh_mac()
        self.call_from_thread(self.refresh_all)
        self.call_from_thread(self.toggle_again, r.feature.name)

    def toggle_again(self, name: str) -> None:
        """The switch after the second look, on the row as it is now."""
        row = next((x for x in self.rows if x.feature.name == name), None)
        if row is not None:
            self.toggle(row, True)

    def brings_mac_version(self) -> str:
        """On a VM older than the Mac, a switch-off or a repair brings all of
        the Mac's OmacVM in (the Bridge allows them so a failed update never
        locks the VM): said before it runs, also with update checks off."""
        mac = self.c.mac_version()
        if not S.mac_newer(self.c.local.version, mac):
            return ""
        return (f"This also brings this VM from OmacVM {self.c.local.version} to OmacVM {mac}, the Mac's: "
                "all of it goes in, your feature choices stay.")

    def switch_mouse_swipe(self) -> None:
        """Space on Magic Mouse swipe: 4 <-> 3 fingers on the Mac, from the next
        swipe. Nothing to install, so no job and no question."""
        problem = self.c.mac_problem()
        if problem:
            self.notify(f"needs the Mac: {problem}", severity="warning")
            return
        if self.mouse_swipe_sending:
            return   # the last press is still on its way; the next one goes from its answer
        self.mouse_swipe_sending = True
        self.send_mouse_swipe(S.next_fingers((self.c.mouse_swipe or {}).get("fingers")))

    @work(thread=True, group="mouse-swipe")
    def send_mouse_swipe(self, fingers: int) -> None:
        try:
            self.c.set_mouse_swipe(fingers)
            self.call_from_thread(self.notify, f"Magic Mouse swipe: {fingers} fingers, from the next swipe")
        except BridgeError as e:
            self.call_from_thread(self.notify, f"Magic Mouse swipe: {e}", severity="warning")
        finally:
            self.call_from_thread(self.mouse_swipe_sent)

    def mouse_swipe_sent(self) -> None:
        self.mouse_swipe_sending = False
        self.refresh_all()

    def choose_graphics(self) -> None:
        """Space on Graphics: the next choice, asked first (it applies at the
        VM's next start; Vulkan builds the VM's driver the first time)."""
        if not self.can_ask():
            return
        cur = self.c.graphics()
        if not cur:
            self.notify("Graphics: the Mac's OmacVM does not say this VM's setting (omacvm update on the Mac)", severity="warning")
            return
        nxt = S.next_graphics(cur)
        text = {"auto": "Automatic: Vulkan on macOS 26 and newer (KosmicKrisp), OpenGL before. With Vulkan the VM builds its Vulkan driver first, a few minutes; until it is there the VM runs on OpenGL.",
                "opengl": "OpenGL only (no Vulkan in the VM).",
                "vulkan": "OpenGL plus Vulkan on the Mac's GPU (experimental; faster Vulkan windows with OmacVM.app 3.0.1 and newer). " + VULKAN_BUILD}[nxt]
        self.push_screen(ConfirmScreen(f"Graphics: {S.GRAPHICS_TITLES[cur]} -> {S.GRAPHICS_TITLES[nxt]}",
                                       text + "\nFrom the VM's next start (shut it down, then start it again)."),
                         lambda yes: yes and self.run_job("graphics", [nxt]))

    def choose_notch(self) -> None:
        """Space on Full screen: notch via Omanotch <-> including notch, asked
        first (from the VM's next start)."""
        if not self.can_ask():
            return
        cur = self.c.notch()
        if not cur:
            self.notify("Full screen: the Mac's OmacVM does not say this VM's setting (omacvm update on the Mac)", severity="warning")
            return
        nxt = S.next_notch(cur)
        text = {"fullpanel": ("Full screen including notch, no Omanotch needed (experimental). The VM uses the "
                              "whole built-in display, including the strip beside the camera notch, and draws "
                              "its bar there itself. Omanotch is not needed for this. Needs the app to start "
                              "VMs in full screen (Start in, not Window)."),
                "native": "Full screen, notch via Omanotch: below the camera notch; Omanotch fills the strip, as before."}[nxt]
        self.push_screen(ConfirmScreen(f"Full screen: {S.NOTCH_TITLES[cur]} -> {S.NOTCH_TITLES[nxt]}",
                                       text + "\nFrom the VM's next start (shut it down, then start it again)."),
                         lambda yes: yes and self.run_job("notch", [nxt]))

    def repair(self, r: S.Row) -> None:
        if r.feature.name == "notch-area":
            self.notify("Full screen is a setting: space switches notch via Omanotch and including notch")
            return
        if r.feature.name == "mouse-swipe":
            self.notify("Magic Mouse swipe is a setting: space switches 3 and 4 fingers")
            return
        if r.feature.name == "gpu-memory":
            self.notify(f"Graphics memory is measured, not switched. {S.GPU_MEMORY_EXPLAINER}")
            return
        if r.feature.name == "graphics":
            g = self.c.graphics() if self.can_ask() else ""
            if g == "vulkan":   # its Vulkan driver again: may update the VM's system first, so asked
                self.push_screen(ConfirmScreen("Graphics: the Vulkan driver again", VULKAN_BUILD),
                                 lambda yes: yes and self.run_job("graphics", [g]))
            elif g:
                self.run_job("graphics", [g])
            return
        if not r.on:
            self.notify(f"{r.feature.title} is off: space turns it on", severity="warning")
            return
        if not self.can_ask():
            return
        name = r.feature.name   # that feature only (apply --reinstall)
        texts = []
        # A row that works: nothing to repair, so say what r would do and ask
        # (before, r there started a reinstall with no word first).
        if r.status is S.Status.WORKS:
            texts.append(f"{r.feature.title} works: nothing to repair. Install it again anyway? "
                         "Its parts go in once more (on the Mac and in this VM); this can take a minute.")
        if self.brings_mac_version():
            texts.append(self.brings_mac_version())
        if texts:
            self.push_screen(ConfirmScreen(f"Repair {r.feature.title}", "\n".join(texts)),
                             lambda yes: yes and self.run_job("reinstall", [name]))
        else:
            self.run_job("reinstall", [name])

    def install_update(self) -> None:
        """u: one key for the whole update. It checks first (when the last
        check is over an hour old), then updates what is older: this VM, or
        OmacVM.app on the Mac and then this VM (the app restarts the VM once)."""
        from textual.worker import WorkerState
        if self.app_step is not None or any(w.group == "job" and w.state in (WorkerState.PENDING, WorkerState.RUNNING)
                                            for w in self.workers):
            self.notify("an update runs: wait for it", severity="warning")
            return
        if not self.can_ask():
            return
        self.plan_update()

    @work(thread=True, exclusive=True, group="job")
    def plan_update(self) -> None:
        c = self.c
        if c.manifest() is None or not c.manifest_fresh():
            self.call_from_thread(self.notify, "checking for updates …", timeout=3)
            try:
                c.refresh_updates(check=True)
            except BridgeError as e:
                # Checked a moment ago (from here or another window): that result counts.
                if not (e.code == "rate" and c.manifest() is not None):
                    self.call_from_thread(self.notify, f"Update: {e}", severity="warning", timeout=8)
                    self.call_from_thread(self.refresh_all)
                    return
        plan, version = c.update_plan()
        self.call_from_thread(self.refresh_all)
        self.call_from_thread(self.confirm_update, plan, version)

    def confirm_update(self, plan: str, version: str) -> None:
        vm = self.c.local.version
        if plan == "none":
            if version:
                self.notify(f"Up to date: OmacVM {version} is the latest release (this VM has {vm})", timeout=6)
            else:
                self.notify("Update: the Mac has no update information yet", severity="warning")
            return
        if plan == "manual":
            text = MANUAL_APP_UPDATE if self.c.local.vm_type == "app" else MANUAL_APP_UPDATE_OTHER
            self.notify(text, severity="warning", timeout=12)
            return
        if plan in ("app", "app+vm"):
            what = "OmacVM.app on the Mac" + (" and this VM get " if plan == "app+vm" else " gets ") + version
            self.push_screen(ConfirmScreen(f"Update to OmacVM {version}",
                                           f"{what}.\nYour VM restarts once for the update: save your work.\n"
                                           "OmacVM.app shuts this VM down, updates itself and starts the VM again; "
                                           "this VM's part follows after you log in. "
                                           "If the new app does not start, the old one comes back by itself."),
                             lambda yes: yes and self.app_update(version))
            return
        n = sum(1 for r in self.c.rows(with_updates=True) if r.update)
        where = "on the Mac and in this VM" if plan == "mac-checkout" else "in this VM"
        self.push_screen(ConfirmScreen(f"OmacVM {version}",
                                       f"Install OmacVM {version} {where}"
                                       f" ({n} feature{'s' if n != 1 else ''} change)?\n"
                                       "Your feature choices stay. Some changes apply after a reboot of the VM."),
                         lambda yes: yes and self.run_job("update", []))

    @work(thread=True, exclusive=True, group="job")
    def app_update(self, version: str) -> None:
        """Asks the Mac to update OmacVM.app; it then restarts this VM. A
        marker says to do this VM's part after the restart."""
        try:
            write_resume(version)
        except OSError:
            pass
        self.last_result = ""
        self.app_step, self.started_at = (version, 1), time.monotonic()
        self.waiting_mac = "the Mac checks and downloads it (a few minutes at most); this VM keeps running"
        self.call_from_thread(self.refresh_all)
        try:
            answer = self.c.bridge.app_update()
            # Only OmacVM.app 3.0.2 on answers "restarting": an older app passes
            # the Bridge's yes on as it is, and nothing would happen.
            if answer.get("state") != "restarting":
                raise BridgeError("refused", "OmacVM.app on the Mac is too old to update itself from here",
                                  200, "old-bridge")
        except BridgeError as e:
            drop_resume()
            self.app_step, self.started_at, self.waiting_mac = None, 0.0, ""
            self.last_result = f"Update to OmacVM {version}: {app_update_error(e)}"
            self.call_from_thread(self.notify, f"Update: {app_update_error(e)}", severity="error", timeout=12)
            self.call_from_thread(self.refresh_all)
            return
        # The app shuts this VM down in a few seconds: save your work.
        wait = answer.get("shutdown_in")
        wait = f" in {wait} s" if isinstance(wait, int) and 0 < wait < 600 else " in a moment"
        self.app_step = (version, 2)
        self.shutdown_asked = time.monotonic()
        self.waiting_mac = ""
        self.last_result = (f"OmacVM.app {version} is ready: this VM shuts down{wait} and starts again "
                            "with the update; this VM's part follows after you log in.")
        self.call_from_thread(self.refresh_all)

    @work(thread=True, exclusive=True, group="job")
    def resume_update(self, version: str) -> None:
        """After OmacVM.app restarted this VM for an update: this VM's part,
        without asking again (the user confirmed before the restart)."""
        c = self.c
        try:
            c.refresh_updates()
        except BridgeError:
            pass
        plan, now = c.update_plan()
        if plan in ("vm", "mac-checkout"):
            # Steps 1-3 are done (the app is new and started this VM): 4, this VM's part.
            self.app_step, self.started_at = (now or version, len(S.APP_STEPS)), time.monotonic()
            self.call_from_thread(self.run_job, "update", [])
        elif plan in ("app", "app+vm", "manual"):
            self.app_step = None
            mac = c.mac_version()
            self.last_result = (f"OmacVM.app was not updated on the Mac{f' (it has {mac})' if mac else ''}: if the new "
                                "version did not start there, the old one came back and skips it until a later one. "
                                "This VM was not changed. OmacVM's window on the Mac says why once this VM is shut down.")
            self.call_from_thread(self.refresh_all)
        elif not now:
            # No update information from the Mac: say nothing about the result.
            self.app_step = None
            self.last_result = (f"OmacVM.app restarted this VM for the update to {version}, but the Mac sent no "
                                "update information yet: u finishes the update.")
            self.call_from_thread(self.refresh_all)
        else:
            self.app_step = None
            self.last_result = f"Updated to OmacVM {c.mac_version() or version} (the Mac app; this VM had it already)."
            self.call_from_thread(self.notify, f"Updated to OmacVM {c.mac_version() or version}", timeout=8)
            self.call_from_thread(self.refresh_all)

    @work(thread=True, exclusive=True, group="job")
    def run_job(self, action: str, features: list[str]) -> None:
        what = self.describe(action, features)
        try:
            try:
                job = self.c.start(action, features)
            except BridgeError as e:
                # Refused because the Mac's list just had this VM as not
                # reachable (a look during the last job's end): nothing started,
                # and the Mac looks again within seconds. Ask once more.
                if e.code != "unknown-vm":
                    raise
                time.sleep(JOB_RETRY_AFTER)
                self.c.refresh_mac()
                job = self.c.start(action, features)
        except BridgeError as e:
            msg = str(e)
            if e.code == "update-first":
                msg = ("the Mac has a newer OmacVM: u updates this VM first" if self.c.update_offered() else
                       f"the Mac has a newer OmacVM: on the Mac, {self.on_the_mac('apply')} brings this VM up to it")
            elif e.code == "mac-older":
                msg = "this VM has a newer OmacVM than the Mac: u updates the Mac first"
            elif e.code == "stale-update":
                msg = "update checks are off and the last result may be old: u checks and updates"
            app_path = self.app_step is not None
            self.app_step, self.started_at = None, 0.0
            self.last_result = f"{what}: {msg}" if app_path or action == "update" else ""
            self.call_from_thread(self.notify, f"{what}: {msg}", severity="error", timeout=8)
            self.call_from_thread(self.refresh_all)
            return
        self.last_result = ""
        if self.app_step is None:
            self.started_at = time.monotonic()
        self.call_from_thread(self.refresh_all)
        failures = 0
        while job.active:
            time.sleep(1)
            try:
                job = self.c.poll(job.id)
                failures = 0
                self.waiting_mac = ""
            except BridgeError:
                failures += 1       # an update may restart the Bridge: keep asking a while
                if failures > 2:
                    self.waiting_mac = f"waiting for the Mac to answer ({failures} s; its Bridge restarts during an update)"
                if failures > LOST_AFTER:
                    job = self.c.lose(job.id)
            if job.active:
                self.call_from_thread(self.refresh_all)
        # The row follows the VM's env at once (before: only after the VM's
        # checks and the Mac's status, 5-10 s after "done"); they come after.
        self.c.job_ended(job)
        self.stamp = self.c.local_stamp()
        app_path = self.app_step is not None
        self.app_step, self.started_at, self.waiting_mac = None, 0.0, ""
        lost = failures > LOST_AFTER
        if job.state == "done" and action == "update":
            # The list and the title follow at once; the checks come after.
            v = self.c.local.version
            write_restart_needed(v)
            self.restart_after = v
            who = " (the Mac app and this VM)" if app_path else ""
            self.last_result = f"Updated to OmacVM {v}{who}. {RESTART_LINE}"
            self.call_from_thread(self.notify, f"Updated to OmacVM {v}", timeout=8)
            self.call_from_thread(self.refresh_all)
        elif job.state == "done":
            self.last_result = ""
            if action == "enable" and "touch-id" in features:
                # Works at once (3.0.4), or the one restart an older app's VM needs; an app's own switch.
                self.last_result = touchid_ready.text("touch-id" in next_start(self.c.local.vm_type, {"touch-id": True}),
                                                      touchid_ready.apps_off())
                self.call_from_thread(self.notify, self.last_result, timeout=12)
            else:
                later = " (from the VM's next start)" if action in ("enable", "disable") and any(
                    S.next_start_note(f, action == "enable", self.c.local.vm_type) for f in features) else ""
                self.call_from_thread(self.notify, f"{what}: done{later}", timeout=6)
        elif lost:
            self.last_result = (f"{what}: the Mac stopped answering about it (it may still finish there; "
                                f"on the Mac, {self.on_the_mac('features')} shows how it went).")
            self.call_from_thread(self.ask_retry, action, features, self.last_result)
        else:
            self.last_result = self.outcome(what, action, job)
            self.call_from_thread(self.notify, self.last_result, severity="error", timeout=12)
            if job.text.strip().rstrip(".").endswith(UPDATE_FIRST) and job.failed_side != "mac":
                self.call_from_thread(self.offer_system_update, what)
        if action == "disable" and "control-centre" in features and job.state == "done":
            self.call_from_thread(self.exit)
            return
        self.call_from_thread(self.refresh_all)
        # Side by side, each shown as it comes in: the VM's checks (a few
        # seconds), the Mac's status with its checks, then the update list.
        self.call_from_thread(self.run_checks)
        self.call_from_thread(self.after_job)

    @work(thread=True, exclusive=True, group="after-job")
    def after_job(self) -> None:
        self.c.refresh_mac()
        self.call_from_thread(self.refresh_all)
        self.c.refresh_updates()
        self.call_from_thread(self.refresh_all)

    def action_restart_vm(self) -> None:
        """R: restart the VM after an update (asked first)."""
        if not self.restart_after:
            self.notify("Nothing waits for a restart (R restarts the VM after an update).")
            return
        if self.c.active_job() is not None:
            self.notify("a job runs: wait for it", severity="warning")
            return

        def go(yes: bool | None) -> None:
            if not yes:
                return
            try:
                subprocess.Popen(REBOOT, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
                self.notify("the VM restarts …")
            except OSError as e:
                self.notify(f"could not restart: {e} (Omarchy menu › System › Restart)", severity="error")
        self.push_screen(ConfirmScreen("Restart the VM",
                                       f"OmacVM {self.restart_after}: kernel, memory and keyboard changes apply "
                                       "after a restart.\nSave your work first. Restart now?"), go)

    def offer_system_update(self, what: str) -> None:
        """A job that needs the VM's system updated first: omarchy update in
        its own window, only on yes (as o on Updates)."""
        self.push_screen(ConfirmScreen("Update the VM's system first",
                                       f"{what}: it needs packages this VM's system is too old for. "
                                       + system.WHAT +
                                       "\n\nIt runs in its own window and asks for your password (often 5-15 "
                                       "minutes). At the end it checks the graphics and says whether a restart is "
                                       "safe. Then try again here."), self.system_update_answer)

    def system_update_answer(self, yes: bool | None) -> None:
        if not yes:
            return
        if system.open_window():
            self.notify("omarchy update opens in its own window")
        else:
            self.notify("no desktop window here: run omacvm update-system in a terminal", severity="warning")

    def ask_retry(self, action: str, features: list[str], text: str) -> None:
        self.push_screen(ConfirmScreen("Try again?", text + "\nAsk the Mac again?"),
                         lambda yes: yes and self.can_ask() and self.run_job(action, features))


def run() -> int:
    c = Controller()
    ControlCentre(c).run()
    return 0
