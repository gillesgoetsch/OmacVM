#!/usr/bin/env python3
"""cc-switches.sh's text and result helpers (clip also for display-unplug.sh, whose rows
cc-switches.sh copies into its summary.tsv).

  cc-result.py clip N TEXT
      TEXT's first N characters. bash's ${s:0:N} and cut -c count bytes in the C
      locale (a run with no LANG: launchd, ssh, a detached kit), so a row's text
      could end in half a character ("─" = E2 94 80) and summary.tsv was no
      longer UTF-8 (3.4.3, 3.4.4).
  cc-result.py write OUT COMMIT VERSION OK FAIL BLOCKED SKIP SECONDS ONLY
      OUT/result.json from OUT/summary.tsv. A byte that is not UTF-8 reads as
      U+FFFD: a row's text never stops the result from being written.
"""
import json
import sys
import time


def clip(n, text):
    # sys.argv keeps bytes that are not UTF-8 as surrogates: back to bytes, then U+FFFD.
    t = text.encode("utf-8", "surrogateescape").decode("utf-8", "replace")
    return t[:n]


def write(out, commit, version, ok, fail, blocked, skip, secs, only):
    with open(out + "/summary.tsv", encoding="utf-8", errors="replace") as f:
        rows = [l.rstrip("\n").split("\t", 2) for l in f if l.strip()]
    o = {"kind": "omacvm-e2e-cc-switches", "commit": commit, "version": version, "only": only,
         "pass": int(fail) == 0 and int(blocked) == 0 and int(ok) > 0 and only == "all",
         "counts": {"ok": int(ok), "FAIL": int(fail), "BLOCKED": int(blocked), "skip": int(skip)},
         "not_ok": [r for r in rows if len(r) == 3 and r[1] in ("FAIL", "BLOCKED")],
         "seconds": int(secs), "finished": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    with open(out + "/result.json", "w", encoding="utf-8") as f:
        json.dump(o, f, indent=1)


def main(a):
    if len(a) == 3 and a[0] == "clip":
        out = clip(int(a[1]), a[2])
        sys.stdout.buffer.write(out.encode("utf-8"))
        return 0
    if len(a) == 10 and a[0] == "write":
        write(*a[1:])
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
