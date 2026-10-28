#!/usr/bin/env python3
"""OmacVM.app: Chrome's and Brave's video switches in their flags files.
As root: browser-video-encode.py USER on|off|check [encode|decode]

encode (the default): Chrome and Brave encode WebRTC video (camera, screen
sharing) on the Mac's media engine. Chrome's VA-API encoder is off on Linux
unless AcceleratedVideoEncoder and VaapiVideoEncoder are enabled. Firefox (157)
has no VA-API encoder on Linux, and Arch Linux ARM builds Chromium without
VA-API (its binary does not load libva): nothing to switch there until it does
(Chromium's files stay known, so "off" and "on" take out what an earlier
version added).

decode: Chrome and Brave convert each hardware-decoded picture before they
draw it (AcceleratedVideoDecodeLinuxZeroCopyGL disabled). On Wayland with
OpenGL, Chrome otherwise draws the NV12 pictures directly ("zero copy"): it
samples Mesa's planes, rounded up to 16 rows, whole (a repeated strip below the
picture), and after a stream change at the same size it decodes into imports
of its old frames, where Mesa's virgl driver crashed its GPU process (the shim
refuses those now, and the video falls back to the CPU). Converted, every
picture gets a new frame from VA-API. Nothing is added while the user's own
last --enable-features names that feature (their choice; check says so).

Chrome uses only the LAST --enable-features and the LAST --disable-features of
its command line, and Omarchy's flags files already have an --enable-features,
so the features go into the last such switch the browser reads (several flags
may share a line), or a new line in the user's file when there is none.

Safety: the user's files are read and written by a child process running as the
user (a link in ~/.config cannot make root write elsewhere); /etc files only when
they are root's own regular files. What OmacVM added is kept in a root-owned
marker (/var/lib/omacvm), one entry per file and switch, checked against the
known files and the group's features before anything is removed (entries
without a switch are --enable-features, as before 3.2.11); "off" removes only
that, from the last such switch of that file. Each group touches only its own
entries.
check: exit 0 when the last switch of every configured browser has the group's
features (whoever put them there), or, for decode, the user enabled zero copy."""
import json, mmap, os, pwd, re, stat, sys

ENABLE, DISABLE = "--enable-features=", "--disable-features="
ZERO_COPY = "AcceleratedVideoDecodeLinuxZeroCopyGL"
GROUPS = {
    "encode": {"switch": ENABLE, "features": ("AcceleratedVideoEncoder", "VaapiVideoEncoder"),
               "browsers": ("chromium", "chrome", "brave")},
    "decode": {"switch": DISABLE, "features": (ZERO_COPY,), "browsers": ("chrome", "brave")},
}
MARK = os.environ.get("OMACVM_VIDEO_FLAGS_MARK") or "/var/lib/omacvm/video-encode-flags.json"


def browser_files(home):
    # The files each browser reads, in order; the user's own comes last. Chrome:
    # /etc/chrome-flags.conf through src/bench/install-chrome.sh's launcher,
    # ~/.config/chrome-flags.conf through it and the AUR package's. Brave: only
    # ~/.config/brave-flags.conf.
    return {
        "chromium": ["/etc/chromium-flags.conf", f"{home}/.config/chromium-flags.conf"],
        "chrome": ["/etc/chrome-flags.conf", f"{home}/.config/chrome-flags.conf"],
        "brave": [f"{home}/.config/brave-flags.conf"],
    }


class Owner:
    """Runs file work as the user for files in the home directory, as root for
    root's own files in /etc; anything else is refused."""

    def __init__(self, user):
        pw = pwd.getpwnam(user)
        self.uid, self.gid, self.home = pw.pw_uid, pw.pw_gid, pw.pw_dir
        self.user = user

    def run(self, path, fn):
        if path.startswith(self.home + "/"):
            r, w = os.pipe()
            pid = os.fork()
            if pid == 0:
                try:
                    os.close(r)
                    os.initgroups(self.user, self.gid)
                    os.setgid(self.gid)
                    os.setuid(self.uid)
                    out = json.dumps(fn(path)).encode()
                    os.write(w, out)
                    os._exit(0)
                except BaseException as e:
                    os.write(w, json.dumps({"error": str(e)}).encode())
                    os._exit(1)
            os.close(w)
            data = b""
            while chunk := os.read(r, 65536):
                data += chunk
            os.close(r)
            _, status = os.waitpid(pid, 0)
            res = json.loads(data or b"null")
            if status != 0:
                raise RuntimeError(f"{path}: {res.get('error') if isinstance(res, dict) else res}")
            return res
        if path.startswith("/etc/"):
            try:
                st = os.lstat(path)
            except FileNotFoundError:
                return fn(path)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
                raise RuntimeError(f"{path}: not root's own file, left alone")
            return fn(path)
        raise RuntimeError(f"{path}: not a browser flags file")


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            return f.read().splitlines()
    except FileNotFoundError:
        return None


def write_lines(path, lines):
    # A linked flags file (dotfiles) keeps its link: write the file it points
    # to. Home files are written by the user's own process, so a link reaches
    # nothing the user could not write anyway; /etc files are never links here.
    path = os.path.realpath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.omacvm-new"
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o644
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("".join(l + "\n" for l in lines))
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def switches(lines, switch):
    """(line, start, end, features) of every SWITCH word, in order; comment
    lines are skipped as the launchers skip them."""
    out = []
    for i, l in enumerate(lines or []):
        if l.lstrip().startswith("#"):
            continue
        for m in re.finditer(r"\S+", l):
            if m.group().startswith(switch):
                feats = [f for f in m.group()[len(switch):].split(",") if f]
                out.append((i, m.start(), m.end(), feats))
    return out


def set_switch(lines, switch, sw, feats):
    i, a, b, _ = sw
    word = switch + ",".join(feats) if feats else ""
    l = lines[i][:a] + word + lines[i][b:]
    if feats or l.strip():
        lines[i] = l if feats else re.sub(r"[ \t]{2,}", " ", l).rstrip()
    else:
        del lines[i]


def add_to(path, switch, missing):
    """As the file's owner: our features into the file's last SWITCH, or a new
    line. Returns whether the file was created."""
    lines = read_lines(path)
    created = lines is None
    lines = lines or []
    sw = switches(lines, switch)
    if sw:
        set_switch(lines, switch, sw[-1], sw[-1][3] + list(missing))
    else:
        lines.append(switch + ",".join(missing))
    write_lines(path, lines)
    return created


def remove_from(path, switch, feats, created):
    """As the file's owner: our features out of the file's last SWITCH (one
    each, the last one); a file OmacVM created goes when nothing is left."""
    lines = read_lines(path)
    if lines is None:
        return False
    sw = switches(lines, switch)
    if sw:
        have = list(sw[-1][3])
        for f in feats:
            if f in have:
                del have[len(have) - 1 - have[::-1].index(f)]
        set_switch(lines, switch, sw[-1], have)
    if created and not any(l.strip() for l in lines) and not os.path.islink(path):
        os.remove(path)
    else:
        write_lines(path, lines)
    return True


def effective(owner, files, switch):
    """The browser's last SWITCH: (file, features) or (None, [])."""
    last = (None, [])
    for p in files:
        sw = owner.run(p, lambda q: [s[3] for s in switches(read_lines(q), switch)])
        if sw:
            last = (p, sw[-1])
    return last


def has_vaapi(exe):
    """Whether a Chromium binary was built with VA-API (it then loads libva-drm)."""
    try:
        with open(exe, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
            return m.find(b"libva-drm.so") >= 0
    except (OSError, ValueError):
        return False


def wanted(owner, name, files):
    if name == "chromium":
        # Arch Linux ARM's has no VA-API today: the features would change nothing.
        return has_vaapi("/usr/lib/chromium/chromium")
    exe = {"chrome": ("google-chrome-stable", "google-chrome"), "brave": ("brave",)}[name]
    if any(os.access(os.path.join(d, e), os.X_OK)
           for d in ("/usr/local/bin", "/usr/bin") for e in exe):
        return True
    return owner.run(files[-1], os.path.exists)


def group_of(switch, feats):
    """The group whose switch and features these are, else None."""
    for name, g in GROUPS.items():
        if g["switch"] == switch and all(f in g["features"] for f in feats):
            return name
    return None


def load_mark(known):
    """The marker's entries that name a known file and one group's switch and
    features (an entry without a switch is --enable-features)."""
    try:
        st = os.lstat(MARK)
        if not stat.S_ISREG(st.st_mode) or (st.st_uid != 0 and st.st_uid != os.getuid()):
            return []
        with open(MARK) as f:
            entries = json.load(f)
    except (OSError, ValueError):
        return []
    ok = []
    for e in entries if isinstance(entries, list) else []:
        if not isinstance(e, dict) or e.get("file") not in known or not isinstance(e.get("features"), list):
            continue
        switch = e.get("switch", ENABLE)
        if group_of(switch, e["features"]):
            ok.append({"file": e["file"], "switch": switch, "features": e["features"],
                       "created": e.get("created") is True})
    return ok


def save_mark(entries):
    os.makedirs(os.path.dirname(MARK), mode=0o755, exist_ok=True)
    tmp = MARK + ".new"
    with open(tmp, "w") as f:
        json.dump(entries, f, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, MARK)


def user_wants_zero_copy(owner, fs):
    """The user's own last --enable-features names zero copy (their choice)."""
    return ZERO_COPY in effective(owner, fs, ENABLE)[1]


def main():
    args = sys.argv[1:]
    if len(args) == 2:
        args.append("encode")
    if len(args) != 3 or args[1] not in ("on", "off", "check") or args[2] not in GROUPS:
        sys.exit("usage: browser-video-encode.py USER on|off|check [encode|decode]")
    user, action, group = args
    g = GROUPS[group]
    switch, features = g["switch"], g["features"]
    owner = Owner(user)
    files = {n: fs for n, fs in browser_files(owner.home).items() if n in g["browsers"]}
    known = {p for fs in browser_files(owner.home).values() for p in fs}
    if action == "check":
        try:
            wanted_now = [n for n, fs in files.items() if wanted(owner, n, fs)]
            theirs = [n for n in wanted_now if group == "decode" and user_wants_zero_copy(owner, files[n])]
            missing = [n for n in wanted_now if n not in theirs
                       and not all(f in effective(owner, files[n], switch)[1] for f in features)]
        except RuntimeError as err:
            print(f"cannot read: {err}")
            sys.exit(1)
        if missing:
            print("missing in: " + ", ".join(missing))
        elif not wanted_now:
            print("no browser")
        else:
            print("on" + (f", zero copy kept by the user's own flags: {', '.join(theirs)}" if theirs else ""))
        sys.exit(1 if missing else 0)
    # This group's entries are taken out (and put in again with "on"); the other
    # group's stay as they are. A removal that fails stays in the marker, so the
    # next run can still take those features out.
    entries = []
    for e in load_mark(known):
        if group_of(e["switch"], e["features"]) != group:
            entries.append(e)
            continue
        try:
            owner.run(e["file"], lambda p, e=e: remove_from(p, switch, e["features"], e["created"]))
        except RuntimeError as err:
            print(f"browser-video-encode: {err}", file=sys.stderr)
            entries.append(e)
    if action == "on":
        for name, fs in files.items():
            try:
                if not wanted(owner, name, fs):
                    continue
                if group == "decode" and user_wants_zero_copy(owner, fs):
                    continue
                target, have = effective(owner, fs, switch)
                missing = [f for f in features if f not in have]
                if not missing:
                    continue
                target = target or fs[-1]
                created = owner.run(target, lambda p: add_to(p, switch, missing))
                entries.append({"file": target, "switch": switch, "features": missing, "created": created})
            except RuntimeError as err:
                print(f"browser-video-encode: {name}: {err}", file=sys.stderr)
    save_mark(entries)


if __name__ == "__main__":
    main()
