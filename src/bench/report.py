#!/usr/bin/env python3
"""The benchmark results side by side, on the Mac.

  report.py mac.jsonl parallels.jsonl utm.jsonl fusion.jsonl app.jsonl [--json out.json]

Each file is one bench.sh run, named after where it ran (the first one is the
baseline, 100%). Geekbench scores are read from their result pages in Chrome
(Geekbench's site turns away plain downloads). Prints a Markdown table with
the median of each test and its share of the baseline.
"""
import json, os, statistics, subprocess, sys, tempfile, time, urllib.request, importlib.util

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bb", os.path.join(here, "browser-bench.py"))
bb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bb)

TESTS = [  # key, label, unit
    ("geekbench-cpu-single", "Geekbench 7 CPU, single-core", ""),
    ("geekbench-cpu-multi", "Geekbench 7 CPU, multi-core", ""),
    ("speedometer", "Speedometer 3.1 (browser)", ""),
    ("motionmark", "MotionMark 1.3.1 (browser graphics)", ""),
    ("aquarium", "WebGL Aquarium, 30,000 fish (fps)", ""),
    ("basemark", "Basemark Web 3.0 (browser graphics)", ""),
    ("geekbench-gpu-Metal", "Geekbench 7 GPU, Metal (Mac only)", ""),
    ("geekbench-gpu-OpenCL", "Geekbench 7 GPU, OpenCL", ""),
    ("geekbench-gpu-Vulkan", "Geekbench 7 GPU, Vulkan (VMs only)", ""),
    ("glmark2", "glmark2 (OpenGL ES, VMs only)", ""),
]


def geekbench_scores(urls):
    """url -> [first, second] score on its page, via a visible Chrome."""
    if not urls:
        return {}
    profile = tempfile.mkdtemp()
    chrome = subprocess.Popen(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                               f"--user-data-dir={profile}", "--remote-debugging-port=9334",
                               "--no-first-run", "--no-default-browser-check", "--window-size=900,700",
                               "about:blank"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(30):
            try:
                urllib.request.urlopen("http://127.0.0.1:9334/json/version")
                break
            except OSError:
                time.sleep(1)
        tab = [t for t in json.load(urllib.request.urlopen("http://127.0.0.1:9334/json")) if t.get("type") == "page"][0]
        d = bb.DevTools(tab["webSocketDebuggerUrl"])
        d.call("Page.enable")
        out = {}
        for url in urls:
            d.call("Page.navigate", url=url)
            vals = []
            for _ in range(40):
                time.sleep(1)
                raw = d.js("Array.from(document.querySelectorAll('.score')).slice(0, 2).map(e => e.textContent.trim())") or []
                vals = [int(v) for v in raw if v.isdigit()]
                if vals:
                    break
            out[url] = vals
        return out
    finally:
        chrome.terminate()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    jout = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    if jout in args:
        args.remove(jout)
    runs = {}
    for f in args:
        name = os.path.splitext(os.path.basename(f))[0]
        runs[name] = [json.loads(l) for l in open(f) if l.strip()]
    urls = sorted({r["url"] for rs in runs.values() for r in rs if r.get("url") and r["test"].startswith("geekbench")})
    scores = geekbench_scores(urls)
    med = {}
    for name, rs in runs.items():
        vals = {}
        for r in rs:
            t, v = r["test"], r.get("value")
            if t == "geekbench-cpu":
                s = scores.get(r.get("url"), [])
                if len(s) >= 2:
                    vals.setdefault("geekbench-cpu-single", []).append(s[0])
                    vals.setdefault("geekbench-cpu-multi", []).append(s[1])
            elif t.startswith("geekbench-gpu"):
                s = scores.get(r.get("url"), [])
                if s:
                    vals.setdefault(t, []).append(s[0])
            elif isinstance(v, (int, float)):
                vals.setdefault(t, []).append(v)
            elif t == "gpu-renderer":
                med.setdefault(name, {})["renderer"] = v
                med[name]["vulkan"] = r.get("vulkan")
        m = med.setdefault(name, {})
        for t, vs in vals.items():
            m[t] = statistics.median(vs)
    base = args and os.path.splitext(os.path.basename(args[0]))[0]
    names = list(runs)
    print("| Test | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    for key, label, _ in TESTS:
        row = []
        for n in names:
            v = med.get(n, {}).get(key)
            if v is None:
                row.append("–")
                continue
            b = med.get(base, {}).get(key)
            pct = f" ({round(100 * v / b)} %)" if b and n != base else ""
            row.append(f"{v:g}{pct}")
        if any(c != "–" for c in row):
            print(f"| {label} | " + " | ".join(row) + " |")
    for n in names:
        if med.get(n, {}).get("renderer"):
            print(f"\n{n}: renderer {med[n]['renderer']}, Vulkan: {med[n].get('vulkan')}")
    if jout:
        json.dump({"baseline": base, "medians": med}, open(jout, "w"), indent=1)


if __name__ == "__main__":
    main()
