#!/usr/bin/env python3
"""OmacVM.app: Chrome and Brave encode WebRTC video (camera, screen sharing)
on the Mac's media engine. As root: browser-video-encode.py USER on|off|check

Chrome's VA-API encoder is off on Linux unless AcceleratedVideoEncoder and
VaapiVideoEncoder are enabled. Chrome uses only the LAST --enable-features of its
command line, and Omarchy's flags files already have one, so the features go into
the last --enable-features the browser reads (several flags may share a line), or
a new line in the user's file when there is none. Firefox (157) has no VA-API
encoder on Linux, and Arch Linux ARM builds Chromium without VA-API (its binary
does not load libva): nothing to switch there until it does (Chromium's files
stay known, so "off" and "on" take out what an earlier version added).

Safety: the user's files are read and written by a child process running as the
user (a link in ~/.config cannot make root write elsewhere); /etc files only when
they are root's own regular files. What OmacVM added is kept in a root-owned
marker (/var/lib/omacvm), checked against the known files and the two features
before anything is removed; "off" removes only that, from the last
--enable-features of that file.
check: exit 0 when the last --enable-features of every configured browser has
both features (whoever put them there)."""
import json, mmap, os, pwd, re, stat, sys

FEATURES = ("AcceleratedVideoEncoder", "VaapiVideoEncoder")
MARK = "/var/lib/omacvm/video-encode-flags.json"
SWITCH = "--enable-features="


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
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.omacvm-new"
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o644
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("".join(l + "\n" for l in lines))
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def switches(lines):
    """(line, start, end, features) of every --enable-features word, in order;
    comment lines are skipped as the launchers skip them."""
    out = []
    for i, l in enumerate(lines or []):
        if l.lstrip().startswith("#"):
            continue
        for m in re.finditer(r"\S+", l):
            if m.group().startswith(SWITCH):
                feats = [f for f in m.group()[len(SWITCH):].split(",") if f]
                out.append((i, m.start(), m.end(), feats))
    return out


def set_switch(lines, sw, feats):
    i, a, b, _ = sw
    word = SWITCH + ",".join(feats) if feats else ""
    l = lines[i][:a] + word + lines[i][b:]
    if feats or l.strip():
        lines[i] = l if feats else re.sub(r"[ \t]{2,}", " ", l).rstrip()
    else:
        del lines[i]


def add_to(path, missing):
    """As the file's owner: our features into the file's last --enable-features,
    or a new line. Returns whether the file was created."""
    lines = read_lines(path)
    created = lines is None
    lines = lines or []
    sw = switches(lines)
    if sw:
        set_switch(lines, sw[-1], sw[-1][3] + list(missing))
    else:
        lines.append(SWITCH + ",".join(missing))
    write_lines(path, lines)
    return created


def remove_from(path, feats, created):
    """As the file's owner: our features out of the file's last --enable-features
    (one each, the last one); a file OmacVM created goes when nothing is left."""
    lines = read_lines(path)
    if lines is None:
        return False
    sw = switches(lines)
    if sw:
        have = list(sw[-1][3])
        for f in feats:
            if f in have:
                del have[len(have) - 1 - have[::-1].index(f)]
        set_switch(lines, sw[-1], have)
    if created and not any(l.strip() for l in lines):
        os.remove(path)
    else:
        write_lines(path, lines)
    return True


def effective(owner, files):
    """The browser's last --enable-features: (file, features) or (None, [])."""
    last = (None, [])
    for p in files:
        sw = owner.run(p, lambda q: [s[3] for s in switches(read_lines(q))])
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


def load_mark(known):
    try:
        st = os.lstat(MARK)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
            return []
        entries = json.load(open(MARK))
    except (OSError, ValueError):
        return []
    ok = []
    for e in entries if isinstance(entries, list) else []:
        if (isinstance(e, dict) and e.get("file") in known
                and isinstance(e.get("features"), list)
                and all(f in FEATURES for f in e["features"])):
            ok.append({"file": e["file"], "features": e["features"], "created": e.get("created") is True})
    return ok


def save_mark(entries):
    os.makedirs(os.path.dirname(MARK), mode=0o755, exist_ok=True)
    tmp = MARK + ".new"
    with open(tmp, "w") as f:
        json.dump(entries, f, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, MARK)


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("on", "off", "check"):
        sys.exit("usage: browser-video-encode.py USER on|off|check")
    owner = Owner(sys.argv[1])
    files = browser_files(owner.home)
    known = {p for fs in files.values() for p in fs}
    if sys.argv[2] == "check":
        missing = [n for n, fs in files.items() if wanted(owner, n, fs)
                   and not all(f in effective(owner, fs)[1] for f in FEATURES)]
        print("missing in: " + ", ".join(missing) if missing else "on")
        sys.exit(1 if missing else 0)
    for e in load_mark(known):
        try:
            owner.run(e["file"], lambda p, e=e: remove_from(p, e["features"], e["created"]))
        except RuntimeError as err:
            print(f"browser-video-encode: {err}", file=sys.stderr)
    entries = []
    if sys.argv[2] == "on":
        for name, fs in files.items():
            try:
                if not wanted(owner, name, fs):
                    continue
                target, have = effective(owner, fs)
                missing = [f for f in FEATURES if f not in have]
                if not missing:
                    continue
                target = target or fs[-1]
                created = owner.run(target, lambda p: add_to(p, missing))
                entries.append({"file": target, "features": missing, "created": created})
            except RuntimeError as err:
                print(f"browser-video-encode: {name}: {err}", file=sys.stderr)
    save_mark(entries)


if __name__ == "__main__":
    main()
