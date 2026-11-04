#!/usr/bin/env python3
"""The VM side of src/tests/e2e/cc-switches.sh, run as root over SSH: the real
control centre (`omacvm`) in tmux as the desktop user, driven with real key
presses, read from the terminal's screen. tmux runs in the user's service
manager (systemd-run --user), as a terminal on the desktop does, so Touch ID's
PAM client sees a local session. `omacvm --here`: the same control centre as
in its own window, in this terminal. Targets are session names (Omarchy's
tmux counts windows from 1).

  guest-cc.py start [S]               the cc in a fresh tmux; waits until it says "Mac linked" (S s, 90)
  guest-cc.py screen                  the screen now
  guest-cc.py row TITLE               the cursor to TITLE's row: its hint, status and note
  guest-cc.py toggle TITLE on|off [S] space on TITLE's row (y to a question) until it says on|off, not working (S s, 900)
  guest-cc.py graphics CHOICE [S]     space on Graphics (y each time) until it is CHOICE (auto|opengl|vulkan)
  guest-cc.py updates [S]             U, c (check again): the updates screen when the check ended, then back
  guest-cc.py sudo yes|no [S]         sudo -k; sudo true in a terminal of the user: yes = in without a password,
                                      no = the password prompt (then Ctrl+C)
  guest-cc.py stop                    q, and the tmux server goes
Prints one JSON object; exit 0 when what the step expects held, 1 if not, 2 usage."""
import json
import os
import pwd
import re
import subprocess
import sys
import time

CONTROL = os.environ.get("OMACVM_CONTROL", "/usr/local/share/omacvm/control")
SOCK = "omacvm-e2e"
UNIT = "omacvm-e2e-tmux"
COLS, LINES = 160, 50


def env_file() -> dict:
    out = {}
    try:
        for line in open("/etc/omacvm/env"):
            k, _, v = line.strip().partition("=")
            if k:
                out[k] = v.strip("'\"")
    except OSError:
        pass
    return out


ENV = env_file()
USER = ENV.get("OMACVM_USER", "")
PW = pwd.getpwnam(USER) if USER else None
UID = PW.pw_uid if PW else 0
RUN = f"/run/user/{UID}"


def out(ok: bool, **kw) -> None:
    kw["ok"] = ok
    print(json.dumps(kw, indent=1, ensure_ascii=False))
    sys.exit(0 if ok else 1)


def tmux(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    cmd = ["runuser", "-u", USER, "--", "env", f"TMUX_TMPDIR={RUN}", f"XDG_RUNTIME_DIR={RUN}", "tmux", "-L", SOCK, *args]
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def screen(target: str = "cc", ansi: bool = False) -> str:
    r = tmux("capture-pane", "-p", *(["-e"] if ansi else []), "-t", target)
    return r.stdout if r.returncode == 0 else ""


def keys(*k: str, target: str = "cc", gap: float = 0.08) -> None:
    for x in k:
        tmux("send-keys", "-t", target, x)
        time.sleep(gap)


def alive(target: str = "cc") -> bool:
    return tmux("has-session", "-t", target).returncode == 0


# ---- the features screen ----
def titles() -> list[str]:
    """Every row title the cc can show: features.tsv's and the Mac-only rows."""
    sys.path.insert(0, CONTROL)
    try:
        from omacvm_cc import state as S  # noqa: PLC0415
    except Exception:   # an older or broken cc: the titles from features.tsv only
        S = None
    t = []
    for p in ("/usr/local/share/omacvm/features.tsv",):
        try:
            for line in open(p):
                f = line.rstrip("\n").split("\t")
                if len(f) >= 7 and not line.startswith("#"):
                    t.append(f[5])
        except OSError:
            pass
    if S is not None:
        t += [v.title for v in vars(S).values() if type(v).__name__ == "Feature"]
    return sorted(set(t), key=len, reverse=True)


TITLES = None


def table(text: str) -> list[tuple[int, str]]:
    """(line, title) of the rows on the screen, in their order."""
    global TITLES
    if TITLES is None:
        TITLES = titles()
    lines = text.splitlines()
    head = next((i for i, l in enumerate(lines) if "FEATURE" in l), -1)
    found = {}
    for i in range(head + 1, len(lines)):
        # The row's own title comes first on its line (a note may name another feature).
        hits = []
        for t in TITLES:
            m = re.search(r"(^|\s)" + re.escape(t) + r"(\s{2,}|\s*│|\s*$)", lines[i])
            if m:
                hits.append((m.start(), -len(t), t))
        if hits:
            found[i] = min(hits)[2]
    return sorted(found.items())


def cursor_line(ansi: str) -> int:
    """The highlighted row: DataTable's cursor (ansi_blue background when focused, bright black when not)."""
    for i, l in enumerate(ansi.splitlines()):
        if re.search(r"\x1b\[(?:[0-9;]*;)?(44|104|48;5;4|48;5;12|100|48;5;8)(?:;[0-9;]*)?m", l) and "│" in l:
            return i
    return -1


def below_table(text: str) -> str:
    """The hint and the banner: what the box shows under the table, as one line."""
    lines = text.splitlines()
    rows = table(text)
    if not rows:
        return ""
    last = rows[-1][0]
    rest = []
    for l in lines[last + 1:]:
        s = l.strip().strip("│╭╮╰╯─").strip()
        if s.startswith("space ") or "on/off" in s and "repair" in s:
            break
        if s:
            rest.append(s)
    return re.sub(r"\s+", " ", " ".join(rest))


def hint_row(hint: str) -> str | None:
    """The row the hint names ("Title: summary · on, works"); None from a control centre whose
    hint gives only the summary (3.2.18 and older)."""
    global TITLES
    if TITLES is None:
        TITLES = titles()
    return next((t for t in TITLES if hint.startswith(t + ":")), None)


def hint_is(title: str, text: str) -> bool:
    """The hint under the table is title's (or names no row: an older control centre)."""
    return hint_row(below_table(text)) in (title, None)


def row_line(text: str, title: str) -> str:
    for i, t in table(text):
        if t == title:
            return text.splitlines()[i]
    return ""


def goto(title: str) -> dict:
    for _ in range(4):
        s = screen()
        rows = table(s)
        names = [t for _, t in rows]
        if title not in names:
            return {"error": f"no row '{title}' on the screen", "rows": names}
        want = names.index(title)
        cur_line = cursor_line(screen(ansi=True))
        cur = next((k for k, (i, _) in enumerate(rows) if i == cur_line), None)
        if cur == want:
            # The hint under the table follows the cursor a moment later (more on a busy Mac):
            # read on once it names this row.
            end = time.monotonic() + 10
            while not hint_is(title, screen()) and time.monotonic() < end:
                time.sleep(0.1)
            if not hint_is(title, screen()):
                return {"error": f"the hint did not name '{title}'", "rows": names, "hint": below_table(screen())}
            return {"rows": names}
        if cur is None:
            # The cursor's colour is not readable here: from the top, then trust the count.
            keys(*(["k"] * (len(rows) + 2)))
            keys(*(["j"] * want))
            time.sleep(0.3)
            if cursor_line(screen(ansi=True)) < 0:
                return {"rows": names, "cursor": "counted"}
            continue
        else:
            keys(*((["j"] * (want - cur)) if want > cur else (["k"] * (cur - want))))
        time.sleep(0.3)
    return {"error": f"the cursor did not reach '{title}'", "rows": names}


def state_of(title: str, text: str) -> dict:
    """on and status from the hint, while it is title's; the note from title's own line."""
    hint = below_table(text)
    line = row_line(text, title)
    note = line.split(title, 1)[1].strip(" │") if title in line else ""
    m = None if hint_row(hint) not in (title, None) else re.search(r"·\s+(on|off),\s+(works|needs you|failing|off|unavailable|not checked|working|from the next start)", hint)
    return {"on": m.group(1) if m else None, "status": m.group(2) if m else None, "note": note, "below": hint}


def full_tui(text: str) -> bool:
    """The Textual control centre (its table and key line), not the plain table it shows without Textual."""
    return "FEATURE" in text and ("on/off" in text or "y go" in text)


def asked(text: str) -> bool:
    return bool(re.search(r"\by\b\s+go\b", text)) and bool(re.search(r"\bn\b\s+cancel", text))


# Also the control centre's notes when it sends nothing: the Bridge's job limit (429 "N jobs in
# the last hour: try later"), "a job runs: wait for it", "still asking the Mac".
TROUBLE = re.compile(r"needs the Mac|409|429|unknown-vm|refused|rolled back|went back|failed|cannot reach|could not|error"
                     r"|try later|in the last hour|a job runs|still asking", re.I)


def watch(until, seconds: float) -> tuple[bool, str, list[str]]:
    """Polls the screen until until(text) or the time is up; keeps every line that sounds like trouble."""
    seen: list[str] = []
    end = time.monotonic() + seconds
    text = ""
    while time.monotonic() < end:
        text = screen()
        for l in text.splitlines():
            s = re.sub(r"\s+", " ", l.strip(" │╭╮╰╯─▔▁▏▕"))
            if s and TROUBLE.search(s) and s not in seen and len(seen) < 40:
                seen.append(s)
        if until(text):
            return True, text, seen
        time.sleep(1.5)
    return False, text, seen


# ---- commands ----
def cmd_start(a: list[str]) -> None:
    secs = float(a[0]) if a else 90
    if not USER or PW is None:
        out(False, error="no desktop user in /etc/omacvm/env")
    if subprocess.run(["sh", "-c", "command -v tmux"], capture_output=True).returncode != 0:
        r = subprocess.run(["/usr/local/share/omacvm/guest/pkg-add", "tmux"], capture_output=True, text=True)
        if r.returncode != 0:
            out(False, error="no tmux, and pkg-add tmux failed", detail=(r.stdout + r.stderr)[-800:])
    subprocess.run(["systemctl", "--user", "-M", f"{USER}@", "stop", UNIT], capture_output=True)
    tmux("kill-server")
    t0 = time.monotonic()
    r = subprocess.run(["systemd-run", "--user", "-M", f"{USER}@", "--collect", f"--unit={UNIT}", "-p", "Type=forking",
                        "-E", f"TMUX_TMPDIR={RUN}", "-E", "TERM=xterm-256color", "-E", "LANG=en_US.UTF-8",
                        "tmux", "-L", SOCK, "new-session", "-d", "-s", "cc", "-x", str(COLS), "-y", str(LINES),
                        "/usr/local/bin/omacvm", "--here"], capture_output=True, text=True)
    if r.returncode != 0:
        out(False, error="systemd-run tmux failed", detail=(r.stdout + r.stderr)[-800:])
    ok, text, seen = watch(lambda s: full_tui(s) and ("Mac linked" in s or "needs the Mac" in s)
                           or "[Y/n]" in s, secs)
    first = round(time.monotonic() - t0, 1)
    if "[Y/n]" in text or (text.strip() and not full_tui(text)):
        out(False, error="the control centre shows its plain table, not the full one (Textual missing?)",
            seconds=first, screen=text)
    # The Mac's checks fill the rows a little later: wait until no row says "asking the Mac".
    watch(lambda s: "asking the Mac" not in s and "checking" not in s, 30)
    # It opens with the checks it saved last time ("last checked N min ago", maybe from before a
    # switch); its own come a few seconds later: rows are read from those.
    watch(lambda s: "last checked" not in s, 90)
    text = screen()
    out(ok and "Mac linked" in text, seconds=first, linked="Mac linked" in text, rows=[t for _, t in table(text)],
        trouble=seen, screen=text)


def cmd_row(a: list[str]) -> None:
    g = goto(a[0])
    text = screen()
    out("error" not in g, **g, **state_of(a[0], text), screen=text)


def cmd_toggle(a: list[str]) -> None:
    title, want = a[0], a[1]
    secs = float(a[2]) if len(a) > 2 else 900
    g = goto(title)
    if "error" in g:
        out(False, **g, screen=screen())
    before = state_of(title, screen())
    if before["on"] == want and before["status"] not in ("working",):
        out(True, already=True, before=before, after=before, screen=screen())
    t0 = time.monotonic()
    keys("space")
    time.sleep(0.8)
    question = ""
    if asked(screen()):
        question = re.sub(r"\s+", " ", screen())[:600]
        keys("y")
    # It starts (working), then ends: the row says want and no longer working.
    started, _, seen1 = watch(lambda s: state_of(title, s)["status"] == "working" or state_of(title, s)["on"] == want, 30)
    if not started:
        out(False, error="nothing happened after Space (no job, no change in 30 s)", before=before, asked=question,
            trouble=seen1, screen=screen())
    # The control centre off closes it: nothing more to read once it quit. A question after the
    # job (e.g. "Update the VM's system first" when a job could not install packages) ends the
    # wait too: it is answered "n", so the next row finds the table, and the toggle fails with it.
    done, text, seen2 = watch(lambda s: not alive() or asked(s) or state_of(title, s)["on"] == want and state_of(title, s)["status"] not in ("working", None), secs)
    if alive() and asked(text):
        later = re.sub(r"\s+", " ", text)[:600]
        keys("n")
        time.sleep(1)
        out(False, error="the control centre asked after the job (answered n)", question=later, before=before,
            asked=question, seconds=round(time.monotonic() - t0, 1), trouble=seen1 + [x for x in seen2 if x not in seen1],
            screen=screen())
    if not alive():
        out(want == "off" and "control centre" in title, before=before, gone="the control centre quit", asked=question,
            seconds=round(time.monotonic() - t0, 1), trouble=seen1 + [x for x in seen2 if x not in seen1], screen=text)
    after = state_of(title, text)
    first = None
    if done and after["status"] in ("failing", "needs you"):
        # Right after "done" the row may still show the checks from before the job (a service that
        # the last job was stopping) until its own checks come, a few seconds: a row that stays so fails.
        first = dict(after)
        _, text, seen3 = watch(lambda s: state_of(title, s)["on"] == want and state_of(title, s)["status"] in ("works", "off"), 30)
        after = state_of(title, text)
        seen2 += [x for x in seen3 if x not in seen2]
    # "from the next start": a switch the running VM takes at its next start (Mac input, Touch ID).
    out(done and after["status"] in ("works", "off", "from the next start"), before=before, after=after, asked=question, started=started,
        seconds=round(time.monotonic() - t0, 1), first=first, trouble=seen1 + [x for x in seen2 if x not in seen1], screen=text)


def cmd_graphics(a: list[str]) -> None:
    want = {"auto": "Automatic", "opengl": "OpenGL", "vulkan": "Vulkan"}[a[0]]
    secs = float(a[1]) if len(a) > 1 else 900
    t0 = time.monotonic()
    steps, seen = [], []
    for _ in range(3):
        g = goto("Graphics")
        if "error" in g:
            out(False, **g, screen=screen())
        st = state_of("Graphics", screen())
        if st["note"].startswith(want + ":") and st["status"] != "working":
            out(True, steps=steps, after=st, seconds=round(time.monotonic() - t0, 1), trouble=seen, screen=screen())
        keys("space")
        # Graphics always asks: waited for, not a fixed 0.8 s (a busy Mac draws it later).
        if not watch(lambda s: asked(re.sub(r"\s+", " ", s)), 15)[0]:
            out(False, error="Space on Graphics asked nothing", steps=steps, screen=screen())
        keys("y")
        prev = st["note"]
        # Ended: the row's own note is a setting again ("to Vulkan…" while the job runs; the hint
        # under the table can still say the status from before, and a Space then is refused).
        ok, text, s2 = watch(lambda s: state_of("Graphics", s)["status"] not in ("working", None)
                             and state_of("Graphics", s)["note"] != prev
                             and re.match(r"(Automatic|OpenGL|Vulkan):", state_of("Graphics", s)["note"]) is not None, secs)
        seen += [x for x in s2 if x not in seen]
        steps.append({"from": prev, "to": state_of("Graphics", text)["note"], "ended": ok})
        if not ok:
            out(False, error="the Graphics job did not end", steps=steps, trouble=seen, screen=text)
    out(False, error=f"Graphics never became {want}", steps=steps, trouble=seen, screen=screen())


def cmd_updates(a: list[str]) -> None:
    secs = float(a[0]) if a else 120
    keys("U")
    # The screen is drawn once its body is (a busy Mac: later than 1 s), not after a fixed pause.
    if not watch(lambda s: "Updates" in s and "Update checks" in s, 15)[0]:
        out(False, error="U did not open the updates screen", screen=screen())
    before = screen()
    keys("c")
    time.sleep(1)
    # The check's answer: up to date, an offer (X → Y), or why not; the box says when it checked.
    ok, text, seen = watch(lambda s: s != before and "No update information yet" not in s
                           and re.search(r"Up to date|→|No connection|could not|refused|error|signature", s, re.I) is not None, secs)
    body = re.sub(r"\s+", " ", " ".join(l.strip(" │╭╮╰╯─") for l in text.splitlines()))
    keys("Escape")
    time.sleep(0.5)
    bad = re.search(r"refused|could not|failed|no signature|not signed|error|needs the Mac|No connection", body, re.I)
    out(ok and not bad, answer=("up to date" if "Up to date" in body else "offered" if "→" in body else "?"),
        body=body[:1500], trouble=seen, screen=text)


def cmd_sudo(a: list[str]) -> None:
    want = a[0]
    secs = float(a[1]) if len(a) > 1 else 60
    tmux("kill-session", "-t", "sh")
    r = tmux("new-session", "-d", "-s", "sh", "-x", "120", "-y", "20", "bash --norc --noprofile")
    if r.returncode != 0:
        out(False, error="no shell in tmux (the cc's tmux must run: start first)", detail=r.stderr)
    time.sleep(0.5)
    keys("sudo -k; sudo true && echo E2E-SUDO-IN || echo E2E-SUDO-OUT", "Enter", target="sh")
    t0 = time.monotonic()
    text = ""
    end = time.monotonic() + secs
    while time.monotonic() < end:
        text = screen("sh")
        if "E2E-SUDO-IN" in text.split("echo E2E-SUDO-OUT", 1)[-1] or re.search(r"password for", text):
            break
        time.sleep(0.5)
    took = round(time.monotonic() - t0, 1)
    prompted = bool(re.search(r"password for", text))
    got_in = "E2E-SUDO-IN" in text.split("echo E2E-SUDO-OUT", 1)[-1]
    if prompted:
        keys("C-c", target="sh")
        time.sleep(0.5)
    tmux("kill-session", "-t", "sh")
    good = got_in and not prompted if want == "yes" else prompted and not got_in
    out(good, want=want, got_in=got_in, password_prompt=prompted, seconds=took, screen=text)


def cmd_stop(_: list[str]) -> None:
    if alive():
        keys("Escape")
        time.sleep(1)
    tmux("kill-server")
    subprocess.run(["systemctl", "--user", "-M", f"{USER}@", "stop", UNIT], capture_output=True)
    out(True)


def main(argv: list[str]) -> None:
    cmds = {"start": cmd_start, "screen": None, "row": cmd_row, "toggle": cmd_toggle, "graphics": cmd_graphics,
            "updates": cmd_updates, "sudo": cmd_sudo, "stop": cmd_stop}
    if not argv or argv[0] not in cmds:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    if argv[0] == "screen":
        print(screen())
        return
    if argv[0] != "start" and argv[0] != "stop" and not alive():
        out(False, error="the control centre does not run in tmux (start first, or it quit)")
    if argv[0] in ("row", "toggle", "graphics", "updates") and not full_tui(screen()):
        out(False, error="the control centre's full screen is not up (plain table, or it quit)", screen=screen())
    cmds[argv[0]](argv[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
