#!/usr/bin/env python3
"""Summarize a TouchProbe log (~/Library/Logs/touch-probe-<date>-<time>.tsv; #843).

Per step:
  - the mouse events the view got, split into AppKit's emulation (made inside
    the app: the event's source pid is the app's, source state 0) and real
    ones (a mouse or trackpad: state 1);
  - each touch (from the raw logger: steps B, C, F): fingers, how long, how far,
    and when it first moved 5 points;
  - the fix's actions (step F) and the clicks it made.
In step F no emulated button event should come from a touch.

    python3 analyze.py LOG
"""
import collections
import math
import re
import sys


def fields(line):
    f = line.rstrip("\n").split("\t")
    if len(f) < 9:
        return None
    try:
        t = float(f[0])
    except ValueError:
        return None
    return {"t": t, "mode": f[1], "step": f[2], "src": f[3], "what": f[4], "detail": f[8]}


def main(path):
    own_pid = None
    events = collections.defaultdict(collections.Counter)
    actions = collections.defaultdict(collections.Counter)
    touches = []
    cur = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        rows = [r for r in (fields(l) for l in fh) if r]
    for r in rows:
        m = re.search(r"cgpid=(\d+) cgstate=(\d+)", r["detail"])
        if r["src"] == "view" and m and m.group(2) == "0" and m.group(1) != "0":
            own_pid = own_pid or m.group(1)
    for r in rows:
        step, src, what, d = r["step"], r["src"], r["what"], r["detail"]
        if src == "view":
            m = re.search(r"cgpid=(\d+) cgstate=(\d+)", d)
            kind = "emulated" if m and m.group(1) == own_pid and m.group(2) == "0" else "real"
            events[step][f"{kind} {what}"] += 1
        elif src == "fix":
            actions[step][what] += 1
        elif src == "logger" and what.startswith("touches"):
            locs = [(float(x), float(y)) for x, y in re.findall(r"tloc=([-\d.]+),([-\d.]+)", d)]
            n = int(re.search(r"n=(\d+)", d).group(1))
            if what == "touchesBegan" and (cur is None or cur.get("end") is not None):
                cur = {"step": step, "t0": r["t"], "pts": [], "fingers": 0, "end": None}
                touches.append(cur)
            if cur is None:
                continue
            if locs:
                cur["pts"].append((r["t"], locs[0]))
            cur["fingers"] = max(cur["fingers"], n)
            ended = d.count("tphase=8") + d.count("tphase=16")
            if what in ("touchesEnded", "touchesCancelled") and ended >= n:
                cur["end"] = r["t"]

    steps = sorted(set(events) | set(actions) | {t["step"] for t in touches},
                   key=lambda s: (s[:1], s))
    for s in steps:
        print(f"== {s}")
        for k, v in sorted(events[s].items()):
            if not k.endswith(("mouseMoved", "mouseEntered", "mouseExited")):
                print(f"   view    {v:4d} {k}")
        for t in (t for t in touches if t["step"] == s):
            p = t["pts"]
            if not p:
                continue
            path_len = sum(math.dist(a[1], b[1]) for a, b in zip(p, p[1:]))
            first5 = next((q[0] - p[0][0] for q in p if math.dist(q[1], p[0][1]) >= 5), None)
            dur = (t["end"] or p[-1][0]) - t["t0"]
            print(f"   touch   fingers={t['fingers']} {dur:6.0f} ms  path {path_len:6.1f} pt  "
                  f"moved 5 pt at {'-' if first5 is None else f'{first5:.0f} ms'}")
        for k, v in sorted(actions[s].items()):
            if k not in ("move", "scroll", "coastStep"):
                print(f"   fix     {v:4d} {k}")
        if s.startswith("F"):
            emu = sum(v for k, v in events[s].items()
                      if k.startswith("emulated") and "Mouse" in k and "Moved" not in k)
            print(f"   check   emulated button events in a fix step: {emu} (want 0)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
