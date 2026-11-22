#!/usr/bin/env python3
"""Scroll momentum's Chromium feature: glide-flags.py on|off HOME. Run as the
user, with this script on stdin (glide.sh: the source may be root's alone).

Chromium's field trial config (Chrome for Testing applies it, 158 measured)
turns WaylandUnscaledTouchpadScrolling on: a touchpad then scrolls 2.5 pixels
per unit of the compositor instead of 12, and the page moves a fifth of what
omacvm_glide.lua's factor for Chromium is tuned for. So "on" puts the feature
into the last --disable-features of each flags file that exists, because
Chromium keeps only its last one. A file without one gets a line with its
launcher's /etc list first, as the launcher reads /etc's file before the
user's. A marker remembers what was added, so "off" takes out only that and
never a value the user set. Files are replaced whole (a temporary file, then
a rename), so Chromium never reads half a file; a linked file stays a link
(its target is replaced), unless the user cannot write there: then the link
gives way to a file, as glide.sh's other flag does."""
import json
import os
import re
import sys
import tempfile

FEATURE = "WaylandUnscaledTouchpadScrolling"
SWITCH = "--disable-features="
TOKEN = re.compile(r"(?<!\S)" + re.escape(SWITCH) + r"(\S*)")


def files(home):
    """Each flags file of the user, with the /etc file that its launcher reads first."""
    return {f"{home}/.config/chromium-flags.conf": "/etc/chromium-flags.conf",
            f"{home}/.config/chrome-flags.conf": "/etc/chrome-flags.conf",
            f"{home}/.config/brave-flags.conf": None}


def lines(path):
    with open(path) as f:
        return f.read().splitlines()


def etc_lines(path):
    """An /etc file as the user's launcher reads it: none when it cannot."""
    try:
        return lines(path) if path else []
    except (FileNotFoundError, PermissionError):
        return []


def last(ls):
    """(line index, match) of the last --disable-features, comments skipped."""
    found = None
    for i, l in enumerate(ls):
        if not l.lstrip().startswith("#"):
            for m in TOKEN.finditer(l):
                found = (i, m)
    return found


def values(m):
    return [v for v in m.group(1).split(",") if v]


def write(path, text):
    """PATH's content replaced atomically, in the target of a link when the user
    may write there, else in place of the link. Keeps the file's mode."""
    for dest in (os.path.realpath(path), path):
        try:
            mode = 0o644 if os.path.islink(dest) else os.stat(dest).st_mode & 0o7777
        except FileNotFoundError:
            mode = 0o644
        if dest != path and os.path.exists(dest) and not os.access(dest, os.W_OK):
            continue   # a read-only target: the link gives way
        try:
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".omacvm-")
        except OSError:   # a folder the user cannot write, or a read-only mount
            if dest != path:
                continue
            raise
        try:
            with os.fdopen(fd, "w") as f:
                f.write(text)
                f.flush()
                os.fchmod(f.fileno(), mode)
                os.fsync(f.fileno())
            os.replace(tmp, dest)
            return
        except BaseException:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            raise


def write_lines(path, ls):
    write(path, "".join(l + "\n" for l in ls))


def on(home, mark_path, mark):
    for path, etc in files(home).items():
        if not os.path.isfile(path):
            continue
        ls = lines(path)
        own = last(ls)
        hit = own or last(etc_lines(etc))
        if hit and FEATURE in values(hit[1]):
            continue
        if own:
            i, m = own
            ls[i] = ls[i][:m.start()] + SWITCH + ",".join(values(m) + [FEATURE]) + ls[i][m.end():]
            mark[path] = "added"
        else:
            ls.append(SWITCH + ",".join((values(hit[1]) if hit else []) + [FEATURE]))
            mark[path] = "line " + ls[-1]
        # The marker first: a flags file changed without it would keep the feature for good.
        write(mark_path, json.dumps(mark))
        write_lines(path, ls)


def off(home, mark_path, mark):
    for path, how in mark.items():
        if path not in files(home) or not os.path.isfile(path):
            continue
        ls = lines(path)
        if how.startswith("line ") and how[5:] in ls:
            ls.remove(how[5:])
        else:
            # Added to the user's switch, or to the line it made that has another value now.
            own = last(ls)
            if not own or FEATURE not in values(own[1]):
                continue
            i, m = own
            ls[i] = ls[i][:m.start()] + SWITCH + ",".join(v for v in values(m) if v != FEATURE) + ls[i][m.end():]
        write_lines(path, ls)
    os.remove(mark_path)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("on", "off"):
        sys.exit("usage: glide-flags.py on|off HOME")
    home = sys.argv[2]
    mark_path = f"{home}/.local/state/omacvm/glide-features.json"
    try:
        with open(mark_path) as f:
            mark = json.load(f)
    except (FileNotFoundError, ValueError):
        mark = {}
    if sys.argv[1] == "on":
        on(home, mark_path, mark)
    elif mark:
        off(home, mark_path, mark)


if __name__ == "__main__":
    main()
