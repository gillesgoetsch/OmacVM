#!/bin/bash
# Chromium's no-AV1 extension (Chromium video, src/vdec/guest) survives an
# apply of other features. apply replaces /usr/local/share/omacvm whole, and an
# apply of only some features (a repair, a feature switch) does not install
# Chromium video again: up to 3.1.4 the extension was there, so Chromium said
# "Failed to load extension" at every start until a full apply.
#  - install.sh puts it beside chromium-flags.py (/usr/local/lib/omacvm), off
#    takes it out, nothing goes into /usr/local/share/omacvm;
#  - chromium-flags.py on: adds it, moves 3.1.4's path to the new one (in
#    place, once, also in a line it added itself), the same again changes
#    nothing; off takes out either and leaves the user's own values;
#  - check: fails when the extension is not there.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

I=$R/src/vdec/guest/install.sh
grep -q 'install -Dm644 -t "\$LIB/chromium-no-av1" no-av1/manifest.json no-av1/no-av1.js' "$I" &&
  grep -q 'rm -rf "\$LIB/chromium-no-av1"' "$I" && ! grep -q 'share/omacvm/chromium-no-av1' "$I" &&
  ok "install.sh: the extension beside chromium-flags.py, off takes it out" ||
  bad "install.sh: the extension is not in \$LIB/chromium-no-av1"
grep -q '^NO_AV1 = "/usr/local/lib/omacvm/chromium-no-av1"$' "$R/src/vdec/guest/chromium-flags.py" &&
  ok "chromium-flags.py: the path install.sh uses" || bad "chromium-flags.py: another path than install.sh's"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
python3 -I - "$R/src/vdec/guest/chromium-flags.py" "$T" <<'PY' || fail=1
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("chromium_flags", sys.argv[1])
cf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cf)
T = sys.argv[2]
OLD, NEW = cf.OLD["--load-extension="], cf.ADD["--load-extension="]
cf.USER_FILE, cf.ETC, cf.MARK = f"{T}/user.conf", f"{T}/etc.conf", f"{T}/state/mark.json"
cf.NO_AV1 = f"{T}/no-av1"
fail = 0

def t(what, cond):
    global fail
    print(("ok   " if cond else "FAIL ") + what)
    fail |= not cond

def setup(user, etc="", mark=None):
    for p in (cf.USER_FILE, cf.ETC, cf.MARK):
        if os.path.exists(p):
            os.remove(p)
    open(cf.USER_FILE, "w").write(user)
    open(cf.ETC, "w").write(etc)
    if mark is not None:
        os.makedirs(os.path.dirname(cf.MARK), exist_ok=True)
        open(cf.MARK, "w").write(json.dumps(mark))

def user():
    return open(cf.USER_FILE).read()

def mark():
    try:
        return json.load(open(cf.MARK))
    except FileNotFoundError:
        return None

omarchy = "--ozone-platform=wayland\n--enable-features=TouchpadOverscrollHistoryNavigation\n--load-extension=/a,/b\n--disable-smooth-scrolling\n"

setup(omarchy)
cf.on()
t("on: the new path in Omarchy's --load-extension", f"--load-extension=/a,/b,{NEW}\n" in user())
t("on: nothing of 3.1.4's path", OLD not in user())

# What 3.1.4 left: its path in the user's file, the extension gone.
setup(omarchy.replace("/a,/b", f"/a,/b,{OLD}").replace("Navigation\n", "Navigation,AcceleratedVideoDecoder\n"),
      mark={"--enable-features=": "added", "--load-extension=": "added"})
cf.on()
t("on after 3.1.4: its path becomes the new one, in place",
  f"--load-extension=/a,/b,{NEW}\n--disable-smooth-scrolling\n" in user() and OLD not in user())
t("on after 3.1.4: --enable-features left as it was",
  "--enable-features=TouchpadOverscrollHistoryNavigation,AcceleratedVideoDecoder\n" in user()
  and user().count("AcceleratedVideoDecoder") == 1)
before = user(); m = os.stat(cf.USER_FILE).st_mtime_ns
cf.on()
t("on again: nothing changes", user() == before and os.stat(cf.USER_FILE).st_mtime_ns == m)
t("check without the extension: fails", not cf.check())
os.makedirs(cf.NO_AV1, exist_ok=True)
open(f"{cf.NO_AV1}/manifest.json", "w").write("{}")
t("check with it: passes", cf.check())
cf.off()
t("off: the user's own values stay, ours go",
  "--load-extension=/a,/b\n" in user() and NEW not in user() and "AcceleratedVideoDecoder" not in user())
t("off: the marker goes", mark() is None)

# Both paths there (an older on, then a newer one): one entry left.
setup(omarchy.replace("/a,/b", f"/a,{OLD},/b,{NEW}"), mark={"--load-extension=": "added"})
cf.on()
t("on, both paths: the new one once, where the old one was", f"--load-extension=/a,{NEW},/b\n" in user())

# No --load-extension in the user's file: 3.1.4 added a whole line (/etc's
# list plus its path) and remembered it.
line = f"--load-extension=/etc-ext,{OLD}"
setup("--ozone-platform=wayland\n" + line + "\n", etc="--load-extension=/etc-ext\n",
      mark={"--load-extension=": "line " + line})
cf.on()
t("on, a line 3.1.4 added: the new path in it", f"--load-extension=/etc-ext,{NEW}\n" in user())
t("on, a line 3.1.4 added: the marker remembers the line as it is now",
  mark().get("--load-extension=") == f"line --load-extension=/etc-ext,{NEW}")
cf.off()
t("off: that line goes", "--load-extension" not in user())

# The video throttle (3.5.0): a line of its own when no file has
# --disable-features, else in the last one (the user's, or /etc's list copied);
# off gives back exactly what was there.
THR = cf.ADD["--disable-features="]
t("the throttle switch is OnBeginFrameThrottleVideo", THR == "OnBeginFrameThrottleVideo")
setup(omarchy)
cf.on()
t("on, no --disable-features anywhere: a line of its own", f"\n--disable-features={THR}\n" in user())
t("on: the marker remembers that line", mark().get("--disable-features=") == f"line --disable-features={THR}")
cf.off()
t("off: Omarchy's file as it was", user() == omarchy)
setup(omarchy + "--disable-features=Foo,Bar\n")
cf.on()
t("on, the user's --disable-features: ours added to it", f"--disable-features=Foo,Bar,{THR}\n" in user()
  and user().count("--disable-features") == 1)
cf.off()
t("off: the user's list as it was", user().endswith("--disable-features=Foo,Bar\n") and THR not in user())
setup(omarchy, etc="--disable-features=Etc\n")
cf.on()
t("on, /etc's --disable-features only: its list plus ours", f"--disable-features=Etc,{THR}\n" in user())
setup(omarchy + f"--disable-features={THR}\n")
cf.on()
t("on, the user has it already: not added again", user().count(THR) == 1)
cf.off()
t("off: the user's own switch stays", f"--disable-features={THR}\n" in user())

# Commented lines are the user's: left alone.
setup(f"# --load-extension={OLD}\n" + omarchy)
cf.on()
t("on: a commented line keeps 3.1.4's path", f"# --load-extension={OLD}\n" in user())
sys.exit(fail)
PY
exit $fail
