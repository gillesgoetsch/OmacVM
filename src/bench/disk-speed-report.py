#!/usr/bin/env python3
"""Median table of disk-speed.sh results (results.jsonl): one row per config.

    disk-speed-report.py results.jsonl [--md]
"""
import json
import statistics
import sys
from collections import defaultdict

COLS = [  # (header, test, field)
    ("seq write MB/s", "seqwrite", "write_mbs"),
    ("seq read MB/s", "seqread", "read_mbs"),
    ("4k read QD32 IOPS", "randread-qd32", "read_iops"),
    ("4k read QD1 us", "randread-qd1", "read_lat_us"),
    ("4k write QD32 IOPS", "randwrite-qd32", "write_iops"),
    ("4k write+fsync QD1 IOPS", "fsync-qd1", "write_iops"),
    ("git clone s", "real", "git_clone_s"),
    ("git checkout s", "real", "git_checkout_old_s"),
    ("pacman base s", "real", "pacman_base_s"),
    ("cold read s", "coldread", "coldread_s"),
]


def main():
    vals = defaultdict(list)
    configs = []
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line.startswith("{"):
            continue
        j = json.loads(line)
        c = j.get("config")
        if not c:
            continue
        if c not in configs:
            configs.append(c)
        for _, test, field in COLS:
            if j.get("test") == test and field in j:
                vals[(c, test, field)].append(j[field])
    md = "--md" in sys.argv
    head = ["config"] + [h for h, _, _ in COLS]
    rows = []
    for c in configs:
        row = [c]
        for _, test, field in COLS:
            v = vals.get((c, test, field), [])
            if not v:
                row.append("-")
                continue
            m = statistics.median(v)
            cell = f"{m:.0f}" if m >= 100 else f"{m:.2f}" if m < 10 else f"{m:.1f}"
            if len(v) > 1:
                cell += f" ({min(v):g}-{max(v):g}, n={len(v)})"
            row.append(cell)
        rows.append(row)
    if md:
        print("| " + " | ".join(head) + " |")
        print("|" + "---|" * len(head))
        for r in rows:
            print("| " + " | ".join(r) + " |")
    else:
        for r in [head] + rows:
            print("\t".join(r))


if __name__ == "__main__":
    main()
