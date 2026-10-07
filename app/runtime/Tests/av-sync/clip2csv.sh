#!/bin/bash
# clip2csv.sh CLIP OUT.csv: decodes a clip with FFmpeg (edit lists and pre-skip applied) into avsync.py's CSV,
# to check that the clip itself is in sync.
set -euo pipefail
ffmpeg -loglevel error -i "$1" -vf "scale=64:36,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" -an -f null - |
  awk '/pts_time/{split($0,a,"pts_time:"); t=a[2]} /YAVG/{split($0,b,"="); printf "V,%s,%s\n", t, b[2]}' > "$2"
ffmpeg -loglevel error -i "$1" -vn -ac 1 -ar 48000 -f f32le - | python3 -c '
import sys, struct
d = sys.stdin.buffer.read(); n = len(d) // 4; s = struct.unpack("<%df" % n, d)
for i in range(0, n, 48):
    print("A,%.6f,%.5f" % (i / 48000, max(abs(x) for x in s[i:i+48])))' >> "$2"
