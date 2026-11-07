"""Results of src/tests/e2e/move-45.sh and the release gate that reads them.

  move-45-result.py row FILE ROW BASE SECONDS     checks on stdin (NAME\\tOK\\tDETAIL) -> FILE; "kit" = the
                                                  kit move-45.sh started with (MOVE45_KIT_START)
  move-45-result.py kit                           the kit here (move-45.sh records it when it starts)
  move-45-result.py summary DIR REPO              DIR/rows/*.json -> DIR/result.json
  move-45-result.py gate RESULT M REPO            exit 0 when RESULT passes for release commit M
  move-45-result.py privsize FILE...              bytes only FILE holds (APFS clones: not shared)
  move-45-result.py digest FILE                   the content's digest, holes read as zeros, fast on a
                                                  sparse 64 GB disk (SHA-256 of the 1 MiB chunks' SHA-256s)

The gate wants every row of move-45.sh --rows passed on at least MIN_BASES
test VMs of different ages, "clean" on every base, rows from at least
MIN_MACS Macs, on each of them the last two clean moves passed (G6: two clean
moves of an aged VM in a row per Mac), and the files of move-45.sh --paths
the same in the tested commit and M. Every row ran with one kit ("kit" in
each row: move-45.sh and this file), and that kit is M's: a row run with
another kit had other checks and does not count. A row run again keeps its
earlier files (ROW-BASE-MAC-TIME.json): the newest one per row, base and Mac
counts. A row whose only failed checks are "kit timing: ..." is a RETRY (the
kit's fault landed outside the moment the row tests): not passed, not a
product failure.

A newer kit may carry rows run with an earlier one (KIT_CARRY: that kit's
hash -> the rows whose checks changed since). Those rows must run again with
the newer kit; every other row run with the earlier kit still counts. The
gate takes the table from M's own move-45-result.py.
"""
import json
import os
import subprocess
import sys
import time

KIND = "omacvm-e2e-move-45"
MIN_BASES = 3   # 4.0 VMs of different ages (prebuilt-3.0.0, prebuilt-3.0.8, a 4.0.3rc4 build)
MIN_MACS = 2    # the mini and the M1 Max
CLEAN_IN_A_ROW = 2   # G6
KIT_FILES = ("src/tests/e2e/move-45.sh", "src/tests/e2e/move-45-result.py")
TIMING = "kit timing:"   # a check that says the kit's fault missed its moment (a retry, not a result)
# Earlier kits whose rows still count, with the rows whose checks changed since (those run again with this kit).
# D15 (3.4.0): 6956a2f5685b2e78 = the kit at rc-3.4.0 02e3a4e4; kill-commit and power-loss now cut after the
# guest's half-switch marker, power-backup stops the move's whole process tree first; nothing else changed.
KIT_CARRY = {
    "6956a2f5685b2e78": ("kill-commit", "power-loss", "power-backup"),
}


def kit_hash(blobs):
    """The kit a row ran with: move-45.sh and this file (their bytes, in KIT_FILES' order)."""
    import hashlib
    h = hashlib.sha256()
    for b in blobs:
        h.update(hashlib.sha256(b).digest())
    return h.hexdigest()[:16]


def kit_here():
    d = os.path.dirname(os.path.abspath(__file__))
    return kit_hash(open(os.path.join(d, os.path.basename(f)), "rb").read() for f in KIT_FILES)


def mac_name():
    return os.uname().nodename.split(".")[0]


def row(a):
    path, name, base, secs = a[0], a[1], a[2], int(a[3])
    checks = []
    for ln in sys.stdin.read().splitlines():
        if not ln.strip():
            continue
        parts = ln.split("\t", 2) + ["", ""]
        checks.append([parts[0], parts[1] == "1", parts[2]])
    # The kit is the one the row STARTED with (move-45.sh hashes it first thing): a kit replaced while the row
    # ran (an int tree re-synced mid-queue) would otherwise label the row with checks it never ran.
    start, end = os.environ.get("MOVE45_KIT_START", ""), kit_here()
    if not start:
        checks.append(["the kit recorded when the row started", False, "no MOVE45_KIT_START (a move-45.sh before it)"])
    elif start != end:
        checks.append(["the kit the row started with is the one it ended with", False,
                       "started with %s, ends with %s: move-45.sh or move-45-result.py replaced while the row ran" % (start, end)])
    ok = bool(checks) and all(c[1] for c in checks)
    retry = not ok and all(c[1] or c[0].startswith(TIMING) for c in checks)
    o = {"row": name, "base": base, "pass": ok, "seconds": secs, "checks": checks,
         "mac": os.environ.get("MOVE45_MAC") or mac_name(), "ended": int(time.time()),
         "app_commit": os.environ.get("MOVE45_COMMIT", ""), "kit": start, "kit_end": end}
    if retry:
        o["retry"] = True
    json.dump(o, open(path, "w"), indent=1)
    print("%s %s on %s: %s (%d checks, %d s)" % ("PASS" if ok else "RETRY" if retry else "FAIL", name, base, "ok" if ok else
          "; ".join(c[0] for c in checks if not c[1])[:300], len(checks), secs))


def rows_of(repo):
    out = subprocess.run([os.path.join(repo, "src/tests/e2e/move-45.sh"), "--rows"], capture_output=True, text=True).stdout
    return [ln.split()[0] for ln in out.splitlines() if ln.strip()]


def summary(a):
    d, repo = a[0], a[1]
    every = []
    for f in sorted(os.listdir(os.path.join(d, "rows"))):
        if f.endswith(".json"):
            r = json.load(open(os.path.join(d, "rows", f)))
            r.setdefault("ended", int(os.path.getmtime(os.path.join(d, "rows", f))))
            r["mac"] = str(r.get("mac", "")).split(".")[0]
            every.append(r)
    every.sort(key=lambda r: r["ended"])
    # Rows of an earlier kit this one carries (KIT_CARRY) count, but not the rows whose checks changed since.
    kits_all = {r.get("kit", "") for r in every}
    main = kits_all - set(KIT_CARRY)
    carry = (kits_all & set(KIT_CARRY)) if main else set()
    stale = ["%s/%s/%s" % (r["row"], r["base"], r["mac"]) for r in every
             if r.get("kit") in carry and r["row"] in KIT_CARRY[r["kit"]]]
    every = [r for r in every if not (r.get("kit") in carry and r["row"] in KIT_CARRY[r["kit"]])]
    latest = {}
    for r in every:   # the newest run of each row, base and Mac
        latest[(r["row"], r["base"], r["mac"])] = r
    rows = list(latest.values())
    commits = sorted({r.get("app_commit", "") for r in rows})
    kits = sorted({r.get("kit", "") for r in rows})
    main_kits = sorted({r.get("kit", "") for r in rows} - carry)
    carried = {k: sorted({r["row"] for r in rows if r.get("kit") == k}) for k in sorted(carry)}
    carried = {k: v for k, v in carried.items() if v}
    want = rows_of(repo)
    bases = sorted({r["base"] for r in rows})
    macs = sorted({r["mac"] for r in rows})
    missing = [w for w in want if not any(r["row"] == w and r["pass"] for r in rows)]
    clean_missing = [b for b in bases if not any(r["row"] == "clean" and r["base"] == b and r["pass"] for r in rows)]
    failed = ["%s/%s/%s" % (r["row"], r["base"], r["mac"]) for r in rows if not r["pass"] and not r.get("retry")]
    retry = ["%s/%s/%s" % (r["row"], r["base"], r["mac"]) for r in rows if not r["pass"] and r.get("retry")]
    # G6: per Mac, its clean moves (every run, any aged base) in time order: the last two passed.
    clean_runs = {m: [r["pass"] for r in every if r["mac"] == m and r["row"] == "clean"
                      and r.get("app_commit", "") in commits] for m in macs}
    g6 = {m: len(v) >= CLEAN_IN_A_ROW and all(v[-CLEAN_IN_A_ROW:]) for m, v in clean_runs.items()}
    g6_macs = sorted(m for m, ok in g6.items() if ok)
    ok = (not missing and not clean_missing and not failed and not retry and len(bases) >= MIN_BASES
          and len(macs) >= MIN_MACS and len(g6_macs) >= MIN_MACS and len(commits) == 1 and commits[0]
          and len(main_kits) == 1 and main_kits[0])
    o = {"kind": KIND, "format": 3, "commit": commits[0] if len(commits) == 1 else "", "pass": bool(ok),
         "kit": main_kits[0] if len(main_kits) == 1 else "", "kits": kits, "carried": carried, "stale": stale,
         "rows": len(rows), "passed": sum(r["pass"] for r in rows), "failed": failed, "retry": retry,
         "missing_rows": missing, "bases": bases, "clean_missing": clean_missing, "macs": macs,
         "clean_moves": {m: "".join("P" if x else "F" for x in v) for m, v in clean_runs.items()},
         "g6_macs": g6_macs, "min_macs": MIN_MACS, "commits": commits}
    json.dump(o, open(os.path.join(d, "result.json"), "w"), indent=1)
    print(json.dumps({k: o[k] for k in ("pass", "commit", "kits", "carried", "rows", "passed", "failed", "retry", "missing_rows", "bases",
                                        "macs", "clean_moves", "g6_macs")}))
    sys.exit(0 if ok else 1)


def gate(a):
    path, m, repo = a[0], a[1], a[2]
    o = json.load(open(path))
    assert o.get("kind") == KIND, "not a move-45 result"
    assert o.get("format") == 3, "a result from an older kit (format %s): sum the rows up again" % o.get("format")
    assert o.get("pass") is True, "not passed: failed %s, missing %s" % (o.get("failed"), o.get("missing_rows"))
    macs, g6 = o.get("macs", []), o.get("g6_macs", [])
    assert len(macs) >= MIN_MACS, "rows from %d Mac(s) (%s), %d needed" % (len(macs), ", ".join(macs), MIN_MACS)
    assert len(g6) >= MIN_MACS, "two clean moves in a row on %d Mac(s) (%s), %d needed: %s" % (
        len(g6), ", ".join(g6), MIN_MACS, o.get("clean_moves"))
    c = o.get("commit", "")
    assert c, "no commit in the result"
    paths = subprocess.run([os.path.join(repo, "src/tests/e2e/move-45.sh"), "--paths"], capture_output=True, text=True).stdout.split()
    d = subprocess.run(["git", "-C", repo, "diff", "--name-only", c, m, "--"] + paths, capture_output=True, text=True)
    assert d.returncode == 0, "git diff %s %s failed: %s" % (c[:12], m[:12], d.stderr.strip()[:200])
    assert not d.stdout.strip(), "the move's files changed after the tested commit %s: %s" % (c[:12], " ".join(d.stdout.split()))
    blobs = []
    for f in KIT_FILES:
        b = subprocess.run(["git", "-C", repo, "show", "%s:%s" % (m, f)], capture_output=True)
        assert b.returncode == 0, "no %s in M %s" % (f, m[:12])
        blobs.append(b.stdout)
    assert o.get("kit") == kit_hash(blobs), "the rows ran with another kit (%s) than M's (%s): run them again with M's move-45.sh" % (
        o.get("kits") or o.get("kit"), kit_hash(blobs))
    # Rows of an earlier kit: only one M's own move-45-result.py carries, and none of the rows changed since.
    mc = carry_of(blobs[1])
    carried = o.get("carried") or {}
    for k, names in carried.items():
        assert k in mc, "rows ran with kit %s, which M's kit does not carry: %s" % (k, ", ".join(names))
        changed = sorted(set(names) & set(mc[k]))
        assert not changed, "rows of kit %s whose checks changed in M's kit: %s: run them again" % (k, ", ".join(changed))
    assert set(o.get("kits", [])) <= {o["kit"]} | set(carried), "kits %s: not M's and not carried" % o.get("kits")
    print("    moves: %d rows passed on %s (%d Macs: %s; two clean moves in a row on each), tested at %s" % (
        o["passed"], ", ".join(o["bases"]), len(macs), ", ".join(macs), c[:12]))


def carry_of(src):
    """KIT_CARRY as a kit's move-45-result.py (bytes) has it, read without running that file."""
    import ast
    for n in ast.parse(src).body:
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "KIT_CARRY" for t in n.targets):
            return {k: tuple(v) for k, v in ast.literal_eval(n.value).items()}
    return {}


def digest(a):
    """Equal for two files exactly when their bytes are equal (holes are zeros), without reading the holes."""
    import hashlib
    chunk = 1 << 20
    zero = hashlib.sha256(bytes(chunk)).digest()
    fd = os.open(a[0], os.O_RDONLY)
    try:
        size = os.fstat(fd).st_size
        extents, pos = [], 0
        while pos < size:   # the data extents (SEEK_DATA / SEEK_HOLE)
            try:
                d = os.lseek(fd, pos, os.SEEK_DATA)
            except OSError:
                break
            h = os.lseek(fd, d, os.SEEK_HOLE)
            extents.append((d, h))
            pos = h
        out = hashlib.sha256()
        e = 0
        for i in range(0, (size + chunk - 1) // chunk):
            lo, hi = i * chunk, min(size, (i + 1) * chunk)
            while e < len(extents) and extents[e][1] <= lo:
                e += 1
            if e < len(extents) and extents[e][0] < hi:
                os.lseek(fd, lo, os.SEEK_SET)
                b = os.read(fd, hi - lo)
                while len(b) < hi - lo:
                    more = os.read(fd, hi - lo - len(b))
                    if not more:
                        break
                    b += more
                out.update(hashlib.sha256(b).digest() if b != bytes(len(b)) or len(b) != chunk else zero)
            else:
                out.update(zero if hi - lo == chunk else hashlib.sha256(bytes(hi - lo)).digest())
        print(out.hexdigest())
    finally:
        os.close(fd)


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
        {"row": row, "summary": summary, "gate": gate, "privsize": privsize, "digest": digest,
         "kit": lambda a: print(kit_here())}[cmd](rest)
    except AssertionError as e:
        print("move-45 gate: %s" % e, file=sys.stderr)
        sys.exit(1)
