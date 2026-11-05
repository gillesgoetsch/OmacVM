"""Results of src/tests/e2e/move-45.sh and the release gate that reads them.

  move-45-result.py row FILE ROW BASE SECONDS     checks on stdin (NAME\\tOK\\tDETAIL) -> FILE
  move-45-result.py summary DIR REPO              DIR/rows/*.json -> DIR/result.json
  move-45-result.py gate RESULT M REPO            exit 0 when RESULT passes for release commit M
  move-45-result.py privsize FILE...              bytes only FILE holds (APFS clones: not shared)

The gate wants every row of move-45.sh --rows passed on at least MIN_BASES
test VMs of different ages, "clean" on every base, on MIN_MACS Macs, and the
files of move-45.sh --paths the same in the tested commit and M.
"""
import json
import os
import subprocess
import sys

KIND = "omacvm-e2e-move-45"
MIN_BASES = 3   # 4.0 VMs of different ages (prebuilt-3.0.0, prebuilt-3.0.8, a 4.0.3rc4 build)
MIN_MACS = 1    # the gate also lists every Mac that ran rows; two are the goal (MIN_MACS_GOAL)
MIN_MACS_GOAL = 2


def row(a):
    path, name, base, secs = a[0], a[1], a[2], int(a[3])
    checks = []
    for ln in sys.stdin.read().splitlines():
        if not ln.strip():
            continue
        parts = ln.split("\t", 2) + ["", ""]
        checks.append([parts[0], parts[1] == "1", parts[2]])
    ok = bool(checks) and all(c[1] for c in checks)
    o = {"row": name, "base": base, "pass": ok, "seconds": secs, "checks": checks,
         "mac": os.uname().nodename, "app_commit": os.environ.get("MOVE45_COMMIT", "")}
    json.dump(o, open(path, "w"), indent=1)
    print("%s %s on %s: %s (%d checks, %d s)" % ("PASS" if ok else "FAIL", name, base, "ok" if ok else
          "; ".join(c[0] for c in checks if not c[1])[:300], len(checks), secs))


def rows_of(repo):
    out = subprocess.run([os.path.join(repo, "src/tests/e2e/move-45.sh"), "--rows"], capture_output=True, text=True).stdout
    return [ln.split()[0] for ln in out.splitlines() if ln.strip()]


def summary(a):
    d, repo = a[0], a[1]
    rows = []
    for f in sorted(os.listdir(os.path.join(d, "rows"))):
        if f.endswith(".json"):
            rows.append(json.load(open(os.path.join(d, "rows", f))))
    commits = sorted({r.get("app_commit", "") for r in rows})
    want = rows_of(repo)
    bases = sorted({r["base"] for r in rows})
    macs = sorted({r.get("mac", "") for r in rows})
    missing = [w for w in want if not any(r["row"] == w and r["pass"] for r in rows)]
    clean_missing = [b for b in bases if not any(r["row"] == "clean" and r["base"] == b and r["pass"] for r in rows)]
    failed = ["%s/%s" % (r["row"], r["base"]) for r in rows if not r["pass"]]
    ok = (not missing and not clean_missing and not failed and len(bases) >= MIN_BASES
          and len(macs) >= MIN_MACS and len(commits) == 1 and commits[0])
    o = {"kind": KIND, "format": 1, "commit": commits[0] if len(commits) == 1 else "", "pass": bool(ok),
         "rows": len(rows), "passed": sum(r["pass"] for r in rows), "failed": failed,
         "missing_rows": missing, "bases": bases, "clean_missing": clean_missing, "macs": macs,
         "macs_goal_met": len(macs) >= MIN_MACS_GOAL, "commits": commits}
    json.dump(o, open(os.path.join(d, "result.json"), "w"), indent=1)
    print(json.dumps({k: o[k] for k in ("pass", "commit", "rows", "passed", "failed", "missing_rows", "bases", "macs")}))
    sys.exit(0 if ok else 1)


def gate(a):
    path, m, repo = a[0], a[1], a[2]
    o = json.load(open(path))
    assert o.get("kind") == KIND, "not a move-45 result"
    assert o.get("pass") is True, "not passed: failed %s, missing %s" % (o.get("failed"), o.get("missing_rows"))
    c = o.get("commit", "")
    assert c, "no commit in the result"
    paths = subprocess.run([os.path.join(repo, "src/tests/e2e/move-45.sh"), "--paths"], capture_output=True, text=True).stdout.split()
    d = subprocess.run(["git", "-C", repo, "diff", "--name-only", c, m, "--"] + paths, capture_output=True, text=True)
    assert d.returncode == 0, "git diff %s %s failed: %s" % (c[:12], m[:12], d.stderr.strip()[:200])
    assert not d.stdout.strip(), "the move's files changed after the tested commit %s: %s" % (c[:12], " ".join(d.stdout.split()))
    print("    moves: %d rows passed on %s (%d Macs: %s), tested at %s" % (o["passed"], ", ".join(o["bases"]),
          len(o["macs"]), ", ".join(o["macs"]), c[:12]))
    if not o.get("macs_goal_met"):
        print("    moves: only %d Mac (goal %d)" % (len(o["macs"]), MIN_MACS_GOAL))


def privsize(a):
    """getattrlist ATTR_CMNEXT_PRIVATESIZE: what deleting FILE gives back on APFS."""
    import ctypes
    import ctypes.util
    import struct

    class Attrlist(ctypes.Structure):
        _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16), ("commonattr", ctypes.c_uint32),
                    ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                    ("forkattr", ctypes.c_uint32)]
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    for p in a:
        al = Attrlist(5, 0, 0, 0, 0, 0, 0x8)   # ATTR_CMNEXT_PRIVATESIZE
        buf = ctypes.create_string_buffer(64)
        if libc.getattrlist(p.encode(), ctypes.byref(al), buf, 64, 0x20 | 0x1) != 0:   # FSOPT_ATTR_CMN_EXTENDED | NOFOLLOW
            sys.exit("privsize: %s: errno %d" % (p, ctypes.get_errno()))
        print(struct.unpack_from("q", buf, 4)[0])


if __name__ == "__main__":
    cmd, rest = sys.argv[1], sys.argv[2:]
    try:
        {"row": row, "summary": summary, "gate": gate, "privsize": privsize}[cmd](rest)
    except AssertionError as e:
        print("move-45 gate: %s" % e, file=sys.stderr)
        sys.exit(1)
