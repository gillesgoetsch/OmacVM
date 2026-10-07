#!/usr/bin/env python3
"""avsync.py: A/V offset from an avcap CSV (or clip2csv output).

Video onset: the centre's brightness crosses half way from dark to bright.
Audio onset: the first millisecond whose peak passes the threshold after at
least 300 ms of quiet. Each video onset is paired with the nearest audio
onset within +-450 ms. Offset = audio - video (positive: the sound is late).

  avsync.py FILE.csv [--json] [--skip SECONDS]
  avsync.py --selftest
"""
import json, statistics, sys


def load(path):
    v, a, info = [], [], {}
    with open(path) as f:
        for line in f:
            p = line.rstrip('\n').split(',', 2)
            if len(p) < 3:
                continue
            if p[0] == 'V':
                v.append((float(p[1]), float(p[2])))
            elif p[0] == 'A':
                a.append((float(p[1]), float(p[2])))
            elif p[0] == 'I':
                info[p[1]] = p[2]
    v.sort(); a.sort()
    return v, a, info


def video_onsets(v):
    if not v:
        return []
    lo = min(x for _, x in v); hi = max(x for _, x in v)
    if hi - lo < 40:
        return []
    mid = (lo + hi) / 2
    out, prev = [], None
    for t, x in v:
        if prev is not None and prev < mid <= x:
            out.append(t)
        prev = x
    return out


def audio_onsets(a, quiet=0.3):
    if not a:
        return []
    peak = max(x for _, x in a)
    if peak < 1e-4:
        return []
    thr = peak * 0.25
    out, last_loud = [], -1e9
    for t, x in a:
        if x >= thr:
            if t - last_loud >= quiet:
                out.append(t)
            last_loud = t
    return out


def pair(vo, ao, window=0.45):
    res, j = [], 0
    for t in vo:
        while j + 1 < len(ao) and ao[j + 1] <= t:
            j += 1
        best = None
        for k in (j - 1, j, j + 1):
            if 0 <= k < len(ao) and abs(ao[k] - t) <= window:
                if best is None or abs(ao[k] - t) < abs(best - t):
                    best = ao[k]
        if best is not None:
            res.append((t, (best - t) * 1000.0))
    return res


def pct(xs, p):
    s = sorted(xs)
    return s[min(len(s) - 1, max(0, int(round(p / 100 * (len(s) - 1)))))]


def summarize(path, skip=0.0):
    v, a, info = load(path)
    vo, ao = video_onsets(v), audio_onsets(a)
    t0 = min([t for t, _ in v[:1]] + [t for t, _ in a[:1]] or [0])
    vo = [t for t in vo if t - t0 >= skip]
    pr = pair(vo, ao)
    r = {'file': path, 'video_frames': len(v), 'video_onsets': len(vo), 'audio_onsets': len(ao), 'pairs': len(pr)}
    if pr:
        offs = [o for _, o in pr]
        r.update(median_ms=round(statistics.median(offs), 1), mean_ms=round(statistics.fmean(offs), 1),
                 p10_ms=round(pct(offs, 10), 1), p90_ms=round(pct(offs, 90), 1),
                 min_ms=round(min(offs), 1), max_ms=round(max(offs), 1),
                 sd_ms=round(statistics.pstdev(offs), 1))
        if len(pr) >= 10:  # drift: least squares slope, ms per minute
            xs = [t for t, _ in pr]; mx = statistics.fmean(xs); my = statistics.fmean(offs)
            den = sum((x - mx) ** 2 for x in xs)
            r['drift_ms_per_min'] = round(60 * sum((x - mx) * (y - my) for x, y in zip(xs, offs)) / den, 2) if den else 0.0
        n = len(offs); third = max(1, n // 3)
        r['first_third_ms'] = round(statistics.median(offs[:third]), 1)
        r['last_third_ms'] = round(statistics.median(offs[-third:]), 1)
    if v:
        ts = [t for t, _ in v]
        gaps = [b - c for b, c in zip(ts[1:], ts)]
        r['video_max_gap_ms'] = round(1000 * max(gaps), 1) if gaps else None
    r['info'] = info
    return r, pr


def selftest():
    import os, random, tempfile
    random.seed(1)
    path = tempfile.mktemp(suffix='.csv')
    with open(path, 'w') as f:
        # 60 s, 60 fps video flashes on each second; audio beep 120 ms late +-5 ms jitter, 1 ms blocks
        for i in range(60 * 60):
            t = 100 + i / 60
            f.write('V,%.6f,%.1f\n' % (t, 235 if (i % 60) < 6 else 16))
        lat = {s: 0.120 + random.uniform(-0.005, 0.005) for s in range(61)}
        for ms in range(60000):
            t = 100 + ms / 1000
            s = int(t - 100); d = (t - 100) - s - lat[s]
            f.write('A,%.6f,%.4f\n' % (t, 0.7 if 0 <= d < 0.05 else 0.001))
    r, pr = summarize(path)
    os.unlink(path)
    assert r['pairs'] >= 58, r
    assert 113 <= r['median_ms'] <= 127, r
    assert abs(r['drift_ms_per_min']) < 10, r
    print('selftest ok', r['median_ms'], r['pairs'])


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        selftest(); sys.exit(0)
    skip = 0.0
    if '--skip' in sys.argv:
        skip = float(sys.argv[sys.argv.index('--skip') + 1])
    r, pr = summarize(sys.argv[1], skip)
    if '--json' in sys.argv:
        print(json.dumps(r))
    else:
        for k, val in r.items():
            print(f'{k}: {val}')
