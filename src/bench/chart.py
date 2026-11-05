#!/usr/bin/env python3
"""The benchmark charts, drawn from docs/benchmarks/chart.json (never edit the SVGs by hand).

  chart.py docs/benchmarks/chart.json docs/images/benchmarks.svg "MacBook Pro M4 Max · macOS 15.7 · Google Chrome 155"

The speed chart: one bar per test, OmacVM.app as a share of the Mac
("medians": {"mac": {...}, "app": {...}}), a dashed line at 100 % (macOS),
the share at the end of each bar. A test the app has no number for shows
the reason from "missing". "note" (a string, or a list for several lines)
goes under the chart. Tests without a Mac value are left out.

--panel power draws docs/images/power.svg from the JSON's "power" part: the
whole Mac's draw in watts per load (lower is better) and the hours on a full
battery, a bar for OmacVM.app and one for macOS, each load on its own scale.
Optional: "digits" (decimals of the watts, default 1), "loads" ({load: what
runs}, replaces the default text under a load's name), "labels" ({"app":
"OmacVM.app 3.0.3"}), "extra" ({"app": {load: "Chromium"}}, said after the
name, e.g. which decoder played the video) and "bar_width" (pixels for the
longest bar, default 420).

--panel progress draws docs/images/gpu-progress.svg from the JSON's
"gpu_progress" part: one Mac and one VM, a bar per OmacVM.app version and
test, as a multiple of the oldest version measured (= 1x), the median's
number on each bar and a thin line from the lowest to the highest run. One
scale for every test; the "highlight" version in the app's colour. A version
without a number gets an empty hatched bar with the reason from "missing".

--panel gpu [--aquarium] [--only KEY,...] draws the GPU panel of
tests/bench/final-round (summarize.py's JSON): GPU throughput first (with the
timing method from "methods"), GPU compute (vkpeak, Geekbench OpenCL and
Vulkan), glmark2 and vkmark (scores), Basemark, and Aquarium with
--aquarium; macOS = 100 %. A build without a number gets an empty hatched
bar with the reason from "missing". "placeholder": true marks the whole
chart as made-up data (for drafts), "preliminary": true as not from the
agreed quiet Mac.
"""
import json, sys
from xml.sax.saxutils import escape

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, monospace"
INK, SOFT, MUTED, BG = "#e0def4", "#908caa", "#6e6a86", "#191724"
APP = ("app", "OmacVM.app", "#ebbcba")
MACOS = ("mac", "macOS", SOFT)
TESTS = [
    ("geekbench-cpu-multi", "CPU, all cores", "Geekbench 7"),
    ("speedometer", "Web apps", "Speedometer 3.1"),
    ("aquarium", "Browser graphics", "WebGL Aquarium, 30,000 fish"),
    ("basemark", "Browser overall", "Basemark Web 3.0"),
    ("geekbench-gpu-opencl", "GPU compute", "Geekbench 7 GPU, OpenCL"),
]
DOTS = '<pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern>'


def text(x, y, s, size=12, fill=INK, font=FONT, weight=None, anchor=None, halo=False):
    w = f' font-weight="{weight}"' if weight else ""
    a = f' text-anchor="{anchor}"' if anchor else ""
    h = f' stroke="{BG}" stroke-width="4" paint-order="stroke"' if halo else ""
    return f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill}"{w}{a}{h}>{escape(s)}</text>'


def textw(s, size):
    """Rough width of s in the sans font, enough to space a legend."""
    return sum(0.28 if c in "ilt.,:;|' " else 0.68 if c.isupper() or c in "mw%" else 0.55 for c in s) * size


def monow(s, size):
    """Width of s in the monospaced font."""
    return 0.62 * size * len(s)


def legend(s, W, y, items):
    """A centred legend: (label, colour, kind) with kind bar, line (dashed), range or none (plain text)."""
    widths = [(18 if kind != "none" else 0) + textw(rl, 13) + 22 for rl, _, kind in items]
    x = (W - sum(widths) + 22) / 2
    for (rl, col, kind), w in zip(items, widths):
        if kind == "bar":
            s.append(f'<rect x="{x:.0f}" y="{y - 11}" width="12" height="12" rx="3" fill="{col}"/>')
        elif kind == "line":
            s.append(f'<line x1="{x + 6:.0f}" y1="{y - 13}" x2="{x + 6:.0f}" y2="{y + 3}" stroke="{INK}" stroke-opacity="0.6" stroke-dasharray="3 3"/>')
        elif kind == "range":
            s.append(f'<path d="M{x:.0f} {y - 8}v6M{x:.0f} {y - 5}h12M{x + 12:.0f} {y - 8}v6" stroke="{INK}" stroke-opacity="0.8" fill="none"/>')
        tx = x + (18 if kind != "none" else 0)
        s.append(text(f"{tx:.0f}", y, rl, 13, MUTED if kind == "none" else INK, weight="600" if kind == "bar" and col == APP[2] else None))
        x += w


def notes_of(data):
    n = data.get("note", [])
    return [n] if isinstance(n, str) else n


def main():
    args = sys.argv[1:]
    if args[:2] == ["--panel", "gpu"]:
        return gpu_panel(*args[2:])
    if args[:2] == ["--panel", "power"]:
        return power_panel(*args[2:])
    if args[:2] == ["--panel", "progress"]:
        return progress_panel(*args[2:])
    data = json.load(open(args[0]))
    out, subtitle = args[1], args[2] if len(args) > 2 else ""
    med = data["medians"]
    mac, app = med.get("mac", {}), med.get(APP[0], {})
    why = data.get("missing", {}).get(APP[0], {})
    tests = [t for t in TESTS if mac.get(t[0]) and (t[0] in app or t[0] in why)]
    notes = notes_of(data)

    W, left, full = 1000, 270, 560          # full = width of 100 % (the Mac)
    pitch, bar, top = 50, 20, 124
    H = top + len(tests) * pitch + 20 + 18 * len(notes)

    def share(key):
        v = app.get(key)
        return None if v is None else 100 * v / mac[key]

    desc = [f"{label} ({bench}): " + (f"{APP[1]} {round(share(key))} percent" if share(key) is not None
                                       else f"{APP[1]} {why.get(key, 'not available')}")
            for key, label, bench in tests]
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">How fast Omarchy runs in OmacVM.app, as a share of macOS itself</title>',
         f'<desc id="d">{escape(". ".join(desc))}. macOS itself is 100 percent; higher is better.</desc>',
         f'<defs>{DOTS}</defs>',
         f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>',
         text(W / 2, 38, "How fast is Omarchy in OmacVM.app?", 20, weight="600", anchor="middle"),
         text(W / 2, 60, subtitle, 13, SOFT, anchor="middle")]
    legend(s, W, 90, [(APP[1], APP[2], "bar"), ("macOS itself = 100 %", None, "line"), ("higher is better", None, "none")])

    # the Mac: one dashed line at 100 % through every row, behind the bars
    s.append(f'<line x1="{left + full}" y1="{top - 6}" x2="{left + full}" y2="{top + len(tests) * pitch - pitch + bar + 14}" stroke="{INK}" stroke-opacity="0.45" stroke-dasharray="3 3"/>')
    for i, (key, label, bench) in enumerate(tests):
        y = top + i * pitch
        s.append(text(40, y + 8, label, 15, weight="600"))
        s.append(text(40, y + 26, bench, 12, MUTED))
        p = share(key)
        if p is None:
            s.append(text(left, y + 15, "– " + why.get(key, "not available"), 12, MUTED, MONO))
            continue
        w = max(3, min(full * 1.1, full * p / 100))
        s.append(f'<rect x="{left}" y="{y}" width="{w:.1f}" height="{bar}" rx="4" fill="{APP[2]}"/>')
        num = f"{round(p)} %"
        tx = left + w + 10
        if tx - 10 < left + full < tx + monow(num, 14) + 6:  # keep the Mac's line out from behind the value
            s.append(f'<rect x="{left + w + 1:.1f}" y="{y - 2}" width="{monow(num, 14) + 16:.0f}" height="{bar + 4}" fill="{BG}"/>')
        s.append(text(f"{tx:.1f}", y + 15, num, 14, INK, MONO, "600", halo=True))
    for i, line in enumerate(notes):
        s.append(text(W / 2, H - 14 - 18 * (len(notes) - 1 - i), line, 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


GPU_TESTS = [  # key, label, benchmark, headline, the Mac's key ("" = no macOS version: absolute scores)
    ("gpu-throughput", "GPU throughput", "WebGL 2 ray march, offscreen 1080p", True, "gpu-throughput"),
    ("vkpeak-fp32", "GPU compute", "vkpeak fp32, Vulkan (macOS: MoltenVK 1.4.1)", False, "vkpeak-fp32"),
    ("geekbench-gpu-opencl", "GPU compute", "Geekbench 7 GPU, OpenCL", False, "geekbench-gpu-opencl"),
    ("geekbench-gpu-vulkan", "GPU compute", "Geekbench 7 GPU, Vulkan (macOS: Metal)", False, "geekbench-gpu-metal"),
    ("webgpu", "GPU compute", "WebGPU matmul f32 2048, Google Chrome", False, "webgpu"),
    ("glmark2", "OpenGL in the VM", "glmark2, no macOS version: score", False, ""),
    ("vkmark", "Vulkan in the VM", "vkmark, no macOS version: score", False, ""),
    ("basemark", "Browser graphics", "Basemark Web 3.0", False, "basemark"),
    ("aquarium", "Browser 3D", "WebGL Aquarium, 30,000 fish", False, "aquarium"),
]
METHOD = {"timer": "GPU time (timer query)", "wall": "wall time, long frames"}
# The final-round harness (tests/bench/final-round) names each VM by its JSON file: OmacVM.app, a second
# app build, and the other VM apps its older rounds measured. Only for --panel gpu.
GPU_ROUTES = [APP, ("app-rc2", "OmacVM.app (second build)", "#eb6f92"), ("utm", "UTM", "#c4a7e7"),
              ("fusion", "VMware Fusion", "#f6c177"), ("parallels", "Parallels", "#9ccfd8")]


def wrap(s, size, width):
    """s in at most two lines that fit width (roughly), split between words."""
    if textw(s, size) <= width:
        return [s]
    words, first = s.split(" "), ""
    while words and textw((first + " " + words[0]).strip(), size) <= width:
        first = (first + " " + words.pop(0)).strip()
    return [first, " ".join(words)] if first else [s]


def gpu_panel(*args):
    """The GPU panel: one group per test, a bar per route, macOS = 100 %.

    Rows with no macOS version (glmark2, vkmark) show each VM's score, bars
    scaled to the best VM. Aquarium only with --aquarium (optional row)."""
    aquarium = "--aquarium" in args
    args = [x for x in args if x != "--aquarium"]
    only = None
    if "--only" in args:
        i = args.index("--only")
        only = set(args[i + 1].split(","))
        del args[i:i + 2]
    src, out, subtitle = args[0], args[1], args[2] if len(args) > 2 else ""
    data = json.load(open(src))
    med, missing = data["medians"], data.get("missing", {})
    mac = med.get("mac", {})
    placeholder = data.get("placeholder", False)
    banner = ("PLACEHOLDER DATA: made-up numbers to show the layout. Not measured." if placeholder else
              "PRELIMINARY: not from the agreed quiet Mac, not the final round." if data.get("preliminary") else None)
    # A second app build (summarize.py's "app-rc2", e.g. a 3.0.0 RC with Vulkan) sits under the app, only in
    # the rows it has a number or a reason for. "labels" names the builds ("OmacVM 2.9.1").
    labels = data.get("labels", {})
    routes = [(n, labels.get(n, rl), c) for n, rl, c in GPU_ROUTES if n in med or n in missing]
    tests = []
    for key, label, bench, headline, base in GPU_TESTS:
        if key == "aquarium" and not aquarium and not (only and key in only):
            continue
        if only and key not in only:
            continue
        if base and not mac.get(base):
            continue
        if not base and not any(med.get(n, {}).get(key) for n, _, _ in routes):
            continue
        m = data.get("methods", {}).get(key, {}).get("method")
        if key == "glmark2" and data.get("glmark2_scene_seconds") not in (None, 10):   # shorter scenes than glmark2's own
            bench += f" · {data['glmark2_scene_seconds']:g} s scenes"
        tests.append((key, label, bench + (f" · {METHOD[m]}" if m in METHOD else ""), headline, base))

    def row_routes(key):
        return [r for r in routes if r[0] != "app-rc2" or key in med.get("app-rc2", {}) or key in missing.get("app-rc2", {})]

    W, left, full = 1000, 250, 560
    pitch, bar, gap, top = 22, 14, 26, 112
    H = top + sum(len(row_routes(t[0])) * pitch + gap for t in tests) + (58 if banner else 34)

    def share(name, key, base):
        v = med.get(name, {}).get(key)
        if v is None:
            return None
        if base:
            return 100 * v / mac[base]
        best = max(med.get(n, {}).get(key) or 0 for n, _, _ in row_routes(key))
        return 100 * v / best

    def why(name, key):
        return missing.get(name, {}).get(key, "not available")

    desc = []
    for key, label, bench, _, base in tests:
        parts = []
        for n, rl, _ in row_routes(key):
            v = med.get(n, {}).get(key)
            parts.append(f"{rl} {why(n, key)}" if v is None else f"{rl} {round(share(n, key, base))} percent" if base
                         else f"{rl} score {v:g}")
        desc.append(f"{label} ({bench}): " + ", ".join(parts))

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">GPU speed of Omarchy in OmacVM.app, UTM, VMware Fusion and Parallels, as a share of macOS itself</title>',
         f'<desc id="d">{banner + " " if banner else ""}{escape(". ".join(desc))}. macOS itself is 100 percent.</desc>',
         '<defs><pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern>',
         f'<pattern id="na" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="2" height="8" fill="{MUTED}" fill-opacity="0.35"/></pattern>',
         '</defs>',
         f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>',
         text(W / 2, 34, "How fast is the GPU in a VM?", 20, weight="600", anchor="middle"),
         text(W / 2, 56, subtitle, 13, SOFT, anchor="middle")]

    items = [(rl, col) for _, rl, col in routes] + [("macOS = 100 %", None)]
    widths = [18 + textw(rl, 13) + 22 for rl, _ in items]
    x = (W - sum(widths) + 22) / 2
    for (rl, col), w in zip(items, widths):
        if col:
            s.append(f'<rect x="{x:.0f}" y="69" width="12" height="12" rx="3" fill="{col}"/>')
        else:
            s.append(f'<line x1="{x + 6:.0f}" y1="67" x2="{x + 6:.0f}" y2="83" stroke="{INK}" stroke-opacity="0.6" stroke-dasharray="3 3"/>')
        s.append(text(f"{x + 18:.0f}", 80, rl, 13, weight="600" if rl == routes[0][1] else None))
        x += w

    bottom = top + sum(len(row_routes(t[0])) * pitch + gap for t in tests) - gap
    y = top
    for key, label, bench, headline, base in tests:
        rr = row_routes(key)
        group = len(rr) * pitch
        if headline:   # the headline row sits on a faint band
            s.append(f'<rect x="24" y="{y - 8}" width="{W - 48}" height="{group + 16}" rx="8" fill="{INK}" fill-opacity="0.04"/>')
        if base:   # macOS = 100 %, only where macOS has the test
            s.append(f'<line x1="{left + full}" y1="{y - 6}" x2="{left + full}" y2="{y + group + 2}" stroke="{INK}" stroke-opacity="0.45" stroke-dasharray="3 3"/>')
        lines = wrap(bench, 12, left - 50)   # the benchmark under the label, on two lines if long
        ly = y + group / 2 - 4 - 7 * (len(lines) - 1)
        s.append(text(40, ly, label, 16 if headline else 15, weight="600"))
        for j, ln in enumerate(lines):
            s.append(text(40, ly + 18 + 15 * j, ln, 12, MUTED))
        for i, (name, rl, col) in enumerate(rr):
            by = y + i * pitch + (pitch - bar) / 2
            p = share(name, key, base)
            if p is None:   # an empty bar to 100 %, hatched, with the reason
                s.append(f'<rect x="{left}" y="{by:.1f}" width="{full}" height="{bar}" rx="4" fill="url(#na)" stroke="{MUTED}" stroke-opacity="0.5" stroke-dasharray="4 3"/>')
                s.append(text(left + 10, by + 11, f"{rl}: {why(name, key)}", 11, SOFT, halo=True))
                continue
            w = max(3, min(full * 1.15, full * p / 100))
            s.append(f'<rect x="{left}" y="{by:.1f}" width="{w:.1f}" height="{bar}" rx="4" fill="{col}"/>')
            tx = left + w + 8
            if base and tx - 8 < left + full < tx + 140:  # keep the Mac's line out from behind the label
                s.append(f'<rect x="{left + w + 1:.1f}" y="{by - 3:.1f}" width="150" height="{bar + 6}" fill="{BG}"/>')
            first = name == routes[0][0]
            num = f"{round(p)} %" if base else f"{med[name][key]:g}"
            s.append(text(f"{tx:.1f}", by + 11.5, num, 13, INK, MONO, "600" if first else None, halo=True))
            lx = tx + 10 + textw(num, 13)
            if lx + textw(rl, 11) > W - 12 and w > textw(rl, 11) + 16:   # no room right of a long bar: inside its end
                s.append(text(f"{left + w - 8:.1f}", by + 11, rl, 11, BG, weight="600", anchor="end"))
            else:
                s.append(text(f"{lx:.1f}", by + 11.5, rl, 11, SOFT, halo=True))
        y += group + gap
    if banner:
        s.append(f'<rect x="24" y="{H - 44}" width="{W - 48}" height="28" rx="6" fill="#eb6f92" fill-opacity="0.15" stroke="#eb6f92"/>')
        s.append(text(W / 2, H - 25, banner, 13, "#eb6f92", weight="600", anchor="middle"))
    if placeholder:
        s.append(f'<text x="{W / 2}" y="{(top + bottom) / 2}" font-family="{FONT}" font-size="64" font-weight="700" fill="#eb6f92" fill-opacity="0.10" text-anchor="middle" transform="rotate(-12 {W / 2} {(top + bottom) / 2})">PLACEHOLDER</text>')
    if not banner:
        s.append(text(W / 2, H - 14, data.get("note", "Each VM as a share of macOS on the same Mac. Hatched: no number, with the reason."), 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


POWER_LOADS = [  # key, label, what runs
    ("idle", "Idle", "the desktop, nothing open"),
    ("light", "Reading", "Chrome scrolling a text page"),
    ("video", "YouTube 4K", "SDR, 60 fps"),
    ("cpu", "Every core busy", "all CPU cores at 100 %"),
    ("gpu", "WebGL Aquarium", "30,000 fish in Chrome; each draws its own frame rate"),
]


def power_panel(src, out, subtitle=""):
    """The power chart: watts of the whole Mac per load (lower is better) and hours on a full battery.

    A bar for OmacVM.app and one for macOS per load, each load scaled to its own larger draw."""
    data = json.load(open(src))["power"]
    watts, missing, wh = data["watts"], data.get("missing", {}), data["battery_wh"]
    labels = data.get("labels", {})  # e.g. {"app": "OmacVM.app 3.0.3"}: the build the round ran
    routes = [(n, labels.get(n, rl), c) for n, rl, c in (APP, MACOS)]
    whats, extra, digits = data.get("loads", {}), data.get("extra", {}), data.get("digits", 1)
    loads = [(k, l, whats.get(k, w)) for k, l, w in POWER_LOADS if any(k in watts.get(r[0], {}) for r in routes)]
    notes = notes_of(data)

    def fmt(v):
        return f"{v:.{digits}f} W", f"{wh / v:.1f} h"

    W, left, full = 1000, 250, data.get("bar_width", 420)
    pitch, bar, gap, top = 24, 16, 28, 128
    H = top + len(loads) * (len(routes) * pitch + gap) - gap + 28 + 18 * len(notes)

    desc = []
    for key, label, what in loads:
        parts = []
        for name, rl, _ in routes:
            v = watts.get(name, {}).get(key)
            ex = extra.get(name, {}).get(key)
            if v is None:
                parts.append(f"{rl} {missing.get(name, {}).get(key, 'not measured')}")
            else:
                w, h = fmt(v)
                parts.append(f"{rl}{f' ({ex})' if ex else ''} {w} ({h})")
        desc.append(f"{label} ({what}): " + ", ".join(parts))

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">Power draw of the whole Mac with Omarchy in OmacVM.app, and with macOS itself</title>',
         f'<desc id="d">{escape(". ".join(desc))}. Watts, lower is better; hours on a full battery.</desc>',
         f'<defs>{DOTS}</defs>',
         f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>',
         text(W / 2, 38, "How much power does the Mac draw?", 20, weight="600", anchor="middle"),
         text(W / 2, 60, subtitle, 13, SOFT, anchor="middle")]
    legend(s, W, 90, [(rl, col, "bar") for _, rl, col in routes] +
           [(f"watts, lower is better · hours on a full {wh:g} Wh battery", None, "none")])

    y = top
    for key, title, what in loads:
        group = len(routes) * pitch
        lines = wrap(what, 12, left - 60)
        ly = y + group / 2 - 4 - 7.5 * len(lines) + 7.5
        s.append(text(40, ly, title, 15, weight="600"))
        for j, ln in enumerate(lines):
            s.append(text(40, ly + 18 + 15 * j, ln, 12, MUTED))
        scale = max(watts.get(n, {}).get(key) or 0 for n, _, _ in routes)
        for i, (name, rl, col) in enumerate(routes):
            by = y + i * pitch + (pitch - bar) / 2
            v = watts.get(name, {}).get(key)
            if v is None:
                s.append(text(left, by + 12, f"– {rl}: " + missing.get(name, {}).get(key, "not measured"), 12, MUTED, MONO))
                continue
            w = max(3, full * v / scale)
            s.append(f'<rect x="{left}" y="{by:.1f}" width="{w:.1f}" height="{bar}" rx="4" fill="{col}"/>')
            wt, hours = fmt(v)
            tx = left + w + 10
            s.append(text(f"{tx:.1f}", by + 12.5, wt, 13, INK, MONO, "600" if name == APP[0] else None, halo=True))
            tx += monow(wt, 13) + 8
            s.append(text(f"{tx:.1f}", by + 12.5, hours, 12, SOFT, MONO, halo=True))
            ex = extra.get(name, {}).get(key)
            if ex:   # the legend names the bars; say only what differs (which browser, the frame rate)
                s.append(text(f"{tx + monow(hours, 12) + 10:.1f}", by + 12.5, ex, 12, SOFT, halo=True))
        y += group + gap
    for i, line in enumerate(notes):
        s.append(text(W / 2, H - 14 - 18 * (len(notes) - 1 - i), line, 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


def progress_summary(test, versions):
    """[(version, median, low, high, ratio to the base, reason)], the base being the oldest version measured."""
    import statistics
    runs, rows, base = test["runs"], [], None
    for v in versions:
        if v not in runs:
            rows.append((v, None, None, None, None, test.get("missing", {}).get(v, "not measured")))
            continue
        m = statistics.median(runs[v])
        base = base or m
        rows.append((v, m, min(runs[v]), max(runs[v]), m / base, None))
    return rows, base


def progress_num(test, v):
    """A test's number as the docs write it: 1,817 or 18.7 fps."""
    d = test.get("digits", 0)
    return f"{v:,.{d}f}" + (f" {test['unit']}" if test.get("unit") else "")


def progress_panel(src, out, subtitle=""):
    """GPU progress: the same Mac and VM, only the OmacVM.app version changes; each test against its oldest version."""
    data = json.load(open(src))["gpu_progress"]
    versions, hl, tests = data["versions"], data["highlight"], data["tests"]
    app_col, old_col = APP[2], SOFT
    summ = [(t,) + progress_summary(t, versions) for t in tests]
    top_ratio = max(hi / b for t, rows, b in summ for v, m, lo, hi, r, why in rows if m is not None)

    W, left, full = 1000, 300, 420          # full = the largest multiple (or run), 1x sits at full / top_ratio
    pitch, bar, gap, top = 22, 14, 26, 128
    one = full / top_ratio
    notes = data.get("note", [])
    notes = [notes] if isinstance(notes, str) else notes
    group = len(versions) * pitch
    body = len(tests) * (group + gap) - gap
    H = top + body + 28 + 16 * len(notes)

    def mult(r):
        return f"{r:.2f}x"

    desc = []
    for t, rows, b in summ:
        parts = []
        for v, m, lo, hi, r, why in rows:
            if m is None:
                parts.append(f"{v} {why}")
            elif len(t["runs"]) == 1:
                parts.append(f"{v} {progress_num(t, m)}, the only version measured")
            else:
                parts.append(f"{v} {mult(r)} ({progress_num(t, m)})")
        desc.append(f"{t['label']} ({t['bench']}): " + ", ".join(parts))

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">GPU speed of one Omarchy VM in each OmacVM.app release, against the oldest release measured</title>',
         f'<desc id="d">{escape(". ".join(desc))}. Each test as a multiple of its oldest version measured (1x); median of 3 runs unless noted.</desc>',
         '<defs><pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern>',
         f'<pattern id="na" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="2" height="8" fill="{MUTED}" fill-opacity="0.35"/></pattern>',
         '</defs>',
         f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>',
         text(W / 2, 34, "How much faster did the GPU get?", 20, weight="600", anchor="middle"),
         text(W / 2, 56, subtitle, 13, SOFT, anchor="middle")]

    items = [(f"OmacVM.app {hl}", app_col, "bar"), ("earlier versions", old_col, "bar"),
             (f"1x = oldest version measured", None, "line"), ("lowest to highest run", None, "range")]
    widths = [18 + textw(rl, 13) + 22 for rl, _, _ in items]
    x = (W - sum(widths) + 22) / 2
    for (rl, col, kind), w in zip(items, widths):
        if kind == "bar":
            s.append(f'<rect x="{x:.0f}" y="69" width="12" height="12" rx="3" fill="{col}"/>')
        elif kind == "line":
            s.append(f'<line x1="{x + 6:.0f}" y1="67" x2="{x + 6:.0f}" y2="83" stroke="{INK}" stroke-opacity="0.6" stroke-dasharray="3 3"/>')
        else:
            s.append(f'<path d="M{x:.0f} 72v6M{x:.0f} 75h12M{x + 12:.0f} 72v6" stroke="{INK}" stroke-opacity="0.8" fill="none"/>')
        s.append(text(f"{x + 18:.0f}", 80, rl, 13, weight="600" if kind == "bar" and col == app_col else None))
        x += w
    s.append(text(W / 2, 104, "Longer is faster · the number on each bar is the median", 13, INK, anchor="middle"))

    # 1x: one dashed line through every group, behind the bars
    s.append(f'<line x1="{left + one:.1f}" y1="{top - 6}" x2="{left + one:.1f}" y2="{top + body + 4}" stroke="{INK}" stroke-opacity="0.45" stroke-dasharray="3 3"/>')
    y = top
    for i, (t, rows, b) in enumerate(summ):
        if i == 0:   # the headline test sits on a faint band
            s.append(f'<rect x="24" y="{y - 8}" width="{W - 48}" height="{group + 16}" rx="8" fill="{INK}" fill-opacity="0.04"/>')
        lines = wrap(t["bench"], 12, left - 120)
        ly = y + group / 2 - 4 - 7.5 * (len(lines) - 1)
        s.append(text(40, ly, t["label"], 16 if i == 0 else 15, weight="600"))
        for j, ln in enumerate(lines):
            s.append(text(40, ly + 18 + 15 * j, ln, 12, MUTED))
        for k, (v, m, lo, hi, r, why) in enumerate(rows):
            by = y + k * pitch + (pitch - bar) / 2
            first = v == hl
            s.append(text(left - 12, by + 11.5, v, 12, INK if first else SOFT, MONO, "600" if first else None, anchor="end"))
            if m is None:
                s.append(f'<rect x="{left}" y="{by:.1f}" width="{one:.1f}" height="{bar}" rx="4" fill="url(#na)" stroke="{MUTED}" stroke-opacity="0.5" stroke-dasharray="4 3"/>')
                s.append(text(left + 10, by + 11, why, 11, SOFT, halo=True))
                continue
            w = max(3, one * r)
            fill = f'fill="{app_col}"' if first else f'fill="{old_col}" fill-opacity="0.55"'
            s.append(f'<rect x="{left}" y="{by:.1f}" width="{w:.1f}" height="{bar}" rx="4" {fill}/>')
            end = w
            if hi > lo:   # the runs' spread: a thin line with ticks, over the bar
                x0, x1, cy = left + one * lo / b, left + one * hi / b, by + bar / 2
                s.append(f'<path d="M{x0:.1f} {cy - 4:.1f}v8M{x0:.1f} {cy:.1f}H{x1:.1f}M{x1:.1f} {cy - 4:.1f}v8" stroke="{INK}" stroke-opacity="0.8" stroke-width="1.5" fill="none"/>')
                end = max(w, one * hi / b)
            tx = left + end + 8
            if len(t["runs"]) == 1:   # nothing to compare with: the number alone
                num = progress_num(t, m)
                s.append(text(f"{tx:.1f}", by + 11.5, num, 13, INK, MONO, "600" if first else None, halo=True))
                s.append(text(f"{tx + monow(num, 13) + 10:.1f}", by + 11.5, "the only version measured", 11, SOFT, halo=True))
                continue
            ratio = mult(r)
            s.append(text(f"{tx:.1f}", by + 11.5, ratio, 13, INK, MONO, "600" if first else None, halo=True))
            s.append(text(f"{tx + monow(ratio, 13) + 8:.1f}", by + 11.5, progress_num(t, m), 12, SOFT, MONO, halo=True))
        y += group + gap
    for i, line in enumerate(notes):
        s.append(text(W / 2, H - 14 - 16 * (len(notes) - 1 - i), line, 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


if __name__ == "__main__":
    main()
