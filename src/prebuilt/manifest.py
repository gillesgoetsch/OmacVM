#!/usr/bin/env python3
"""Prebuilt image manifests.

  manifest.py write OUT.json --route R --omacvm V --omarchy V --bundle NAME
                    --unpacked KB --disk-gb N PART...
  manifest.py get MANIFEST KEY             one value (route, omacvm, omarchy, bundle,
                                           size, unpacked_kb, disk_gb, created); the
                                           manifest is checked first, exit 1 if it is bad
  manifest.py parts MANIFEST               one line per part: NAME SIZE SHA256
  manifest.py release RELEASES.json VERSION ROUTE
                                           from GitHub's release list: TAG URL IMAGE_VERSION
                                           of the newest image for ROUTE with the same
                                           major version, up to VERSION
  manifest.py local DIR VERSION ROUTE      the same from a folder: NAME IMAGE_VERSION
  manifest.py asset RELEASES.json TAG NAME the download URL of one asset
"""
import datetime
import hashlib
import json
import os
import re
import sys


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def write(a):
    out, rest = a[0], a[1:]
    opts, parts = {}, []
    i = 0
    while i < len(rest):
        if rest[i].startswith("--"):
            opts[rest[i][2:]] = rest[i + 1]
            i += 2
        else:
            parts.append(rest[i])
            i += 1
    m = {
        "format": 1,
        "route": opts["route"],
        "omacvm": opts["omacvm"],
        "omarchy": opts["omarchy"],
        "bundle": opts["bundle"],
        "unpacked_kb": int(opts["unpacked"]),
        "disk_gb": int(opts["disk-gb"]),
        "compression": "tar + zstd --long=27",
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "parts": [{"name": os.path.basename(p), "size": os.path.getsize(p), "sha256": sha256(p)} for p in sorted(parts)],
    }
    m["size"] = sum(p["size"] for p in m["parts"])
    json.dump(m, open(out, "w"), indent=2)
    print(out)


# A manifest comes from the internet (or OMACVM_PREBUILT_SOURCE): its values end
# up in bash (arithmetic, paths, the terminal). Only plain integers, safe names
# and printable text get out; anything else fails the whole manifest.
NAME = re.compile(r"[A-Za-z0-9._-]{1,64}")
ROUTE = re.compile(r"[a-z]{1,16}")
VERSION = re.compile(r"[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}")
TEXT = re.compile(r"[ -~]{1,80}")   # printable ASCII
CREATED = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
INTS = {"disk_gb": (1, 4096), "size": (1, 1 << 40), "unpacked_kb": (1, 1 << 33)}


def plain_int(m, key):
    v = m.get(key)
    lo, hi = INTS[key]
    # JSON true/false are ints in Python; strings and floats are not taken.
    if type(v) is not int or not lo <= v <= hi:
        raise ValueError("%s is not a whole number from %d to %d" % (key, lo, hi))
    return v


def checked(path):
    """The manifest with every value we use checked; ValueError if not."""
    with open(path) as f:
        m = json.load(f)
    if not isinstance(m, dict):
        raise ValueError("not a JSON object")
    out = {}
    for key, rx in (("route", ROUTE), ("omacvm", VERSION), ("omarchy", TEXT), ("bundle", NAME), ("created", CREATED)):
        v = m.get(key)
        if not isinstance(v, str) or not rx.fullmatch(v):
            raise ValueError("bad %s" % key)
        out[key] = v
    if out["bundle"] in (".", ".."):
        raise ValueError("bad bundle")
    for key in INTS:
        out[key] = plain_int(m, key)
    return out


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def pick(cands, version, route):
    """cands: (tag, published, asset name, url) -> (VERSION, cand) of the best."""
    want = re.compile(r"^omacvm-prebuilt-(\d+\.\d+\.\d+)-%s\.json$" % re.escape(route))
    mine = vtuple(version)
    best = None
    for c in cands:
        m = want.match(str(c[2]))
        if not m:
            continue
        v = vtuple(m.group(1))
        if v[0] != mine[0] or v > mine:
            continue
        key = (v, c[1])
        if best is None or key > best[0]:
            best = (key, c)
    return (".".join(map(str, best[0][0])), best[1]) if best else None


def main(a):
    if len(a) < 2:
        sys.exit(__doc__)
    cmd = a[1]
    if cmd == "write":
        write(a[2:])
    elif cmd == "get":
        try:
            m = checked(a[2])
        except (ValueError, OSError) as e:
            sys.exit("manifest.py: %s: %s" % (a[2], e))
        if a[3] not in m:
            sys.exit("manifest.py: unknown key %r" % a[3])
        print(m[a[3]])
    elif cmd == "parts":
        m = json.load(open(a[2]))
        # The names become file paths on the Mac: only our own part names.
        ok = re.compile(r"^omacvm-prebuilt-[0-9]+\.[0-9]+\.[0-9]+-(parallels|utm|fusion)\.tar\.zst\.part-[a-z]{2,4}$")
        for p in m["parts"]:
            size = p.get("size")
            if (not ok.match(str(p.get("name"))) or not re.fullmatch(r"[0-9a-f]{64}", str(p.get("sha256")))
                    or type(size) is not int or not 0 < size <= 1 << 40):
                sys.exit("manifest.py: unexpected part %r" % p.get("name"))
            print(p["name"], size, p["sha256"])
    elif cmd == "release":
        # The newest image for this route with the same major version and a
        # version up to ours (the first omacvm apply brings the guest side
        # to ours): prints TAG URL VERSION.
        rels, version, route = json.load(open(a[2])), a[3], a[4]
        # Tag and URL are printed for bash's read: no spaces or control characters.
        tag_ok = re.compile(r"prebuilt-[A-Za-z0-9._-]{1,64}")
        url_ok = re.compile(r"https://github\.com/[!-~]{1,400}")
        best = pick([(r["tag_name"], r.get("published_at") or "", x["name"], x["browser_download_url"])
                     for r in rels if not r.get("draft") and tag_ok.fullmatch(str(r.get("tag_name", "")))
                     for x in r.get("assets", []) if url_ok.fullmatch(str(x.get("browser_download_url", "")))],
                    version, route)
        if not best:
            sys.exit(1)
        print(best[1][0], best[1][3], best[0])
    elif cmd == "local":
        # the same from a folder of files: prints NAME VERSION
        names = [(None, "", n, None) for n in os.listdir(a[2])]
        best = pick(names, a[3], a[4])
        if not best:
            sys.exit(1)
        print(best[1][2], best[0])
    elif cmd == "asset":
        for r in json.load(open(a[2])):
            if r.get("tag_name") == a[3]:
                for x in r.get("assets", []):
                    if x["name"] == a[4]:
                        print(x["browser_download_url"])
                        return
        sys.exit(1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
