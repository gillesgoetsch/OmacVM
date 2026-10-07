#!/usr/bin/env python3
"""A source-like tree for the Mac folder benchmark: N files in dirs of 30,
512 B - 16 KB of text each, the same on every run (seeded).
   mktree.py DIR N"""
import os, random, sys

d, n = sys.argv[1], int(sys.argv[2])
r = random.Random(42)
words = [("".join(r.choice("abcdefghijklmnopqrstuvwxyz_") for _ in range(r.randint(2, 10)))) for _ in range(2000)]
for i in range(n):
    sub = os.path.join(d, "src", f"m{i // 900:03d}", f"d{(i // 30) % 30:02d}")
    os.makedirs(sub, exist_ok=True)
    size = r.randint(512, 16384)
    out, total = [], 0
    while total < size:
        line = " ".join(r.choice(words) for _ in range(r.randint(3, 12))) + "\n"
        out.append(line)
        total += len(line)
    with open(os.path.join(sub, f"f{i:05d}.c"), "w") as f:
        f.write("".join(out)[:size])
