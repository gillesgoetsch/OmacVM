#!/usr/bin/env python3
"""docs/images/benchmarks.svg from a results JSON: each route as a share of the Mac.

  chart.py docs/benchmarks/chart.json docs/images/benchmarks.svg "MacBook Pro M4 Max · macOS 15.7 · Chrome 154"

The JSON is report.py's ("medians", "missing"), plus optional "unreleased":
{route: [test, ...]} for numbers from a build that is not out yet. Those bars
are striped and tagged. Tests without a Mac value are left out.
"""
import json, sys
from xml.sax.saxutils import escape

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, monospace"
INK, SOFT, MUTED, BG = "#e0def4", "#908caa", "#6e6a86", "#191724"
ROUTES = [  # report.py names (file names), label, colour; the app first
    ("app", "OmacVM.app", "#ebbcba"),
    ("utm", "UTM", "#c4a7e7"),
    ("fusion", "VMware Fusion", "#f6c177"),
    ("parallels", "Parallels", "#9ccfd8"),
]
TESTS = [
    ("geekbench-cpu-multi", "CPU, all cores", "Geekbench 7"),
    ("speedometer", "Web apps", "Speedometer 3.1"),
    ("aquarium", "Browser graphics", "WebGL Aquarium"),
    ("basemark", "Browser overall", "Basemark Web 3.0"),
    ("geekbench-gpu-opencl", "GPU compute", "Geekbench 7 GPU, OpenCL"),
]
NOTE = "Striped: not released yet (OmacVM.app with Vulkan in the VM). glmark2 and vkmark have no macOS version: see docs/benchmarks."


def text(x, y, s, size=12, fill=INK, font=FONT, weight=None, anchor=None, halo=False):
    w = f' font-weight="{weight}"' if weight else ""
    a = f' text-anchor="{anchor}"' if anchor else ""
    h = f' stroke="{BG}" stroke-width="4" paint-order="stroke"' if halo else ""
    return f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill}"{w}{a}{h}>{escape(s)}</text>'


def textw(s, size):
    """Rough width of s in the sans font, enough to space a legend."""
    return sum(0.28 if c in "ilt.,:;|' " else 0.68 if c.isupper() or c in "mw%" else 0.55 for c in s) * size


def main():
    data = json.load(open(sys.argv[1]))
    out, subtitle = sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
    med, missing = data["medians"], data.get("missing", {})
    unrel = {(r, t) for r, ts in data.get("unreleased", {}).items() for t in ts}
    mac = med.get("mac", {})
    routes = [r for r in ROUTES if r[0] in med]
    tests = [t for t in TESTS if mac.get(t[0]) and any(t[0] in med[r[0]] or t[0] in missing.get(r[0], {}) for r in routes)]

    W, left, full = 1000, 230, 620          # full = width of 100 % (the Mac)
    pitch, bar, gap, top = 15, 11, 16, 104
    group = len(routes) * pitch
    H = top + len(tests) * (group + gap) + 30

    def share(name, key):
        v = med.get(name, {}).get(key)
        return None if v is None else 100 * v / mac[key]

    desc = []
    for key, label, bench in tests:
        parts = []
        for name, rl, _ in routes:
            p = share(name, key)
            if p is None:
                parts.append(f"{rl} {missing.get(name, {}).get(key, 'not available')}")
            else:
                parts.append(f"{rl} {round(p)} percent" + (" (not released yet)" if (name, key) in unrel else ""))
        desc.append(f"{label} ({bench}): " + ", ".join(parts))

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">How fast Omarchy runs in OmacVM.app, UTM, VMware Fusion and Parallels, as a share of macOS itself</title>',
         f'<desc id="d">{escape(". ".join(desc))}. macOS itself is 100 percent.</desc>',
         '<defs><pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern>']
    for name, _, col in routes:
        s.append(f'<pattern id="hatch-{name}" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
                 f'<rect width="6" height="6" fill="{col}" fill-opacity="0.25"/><rect width="3" height="6" fill="{col}"/></pattern>')
    s.append('</defs>')
    s.append(f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>')
    s.append(text(W / 2, 34, "How fast is Omarchy in a VM?", 20, weight="600", anchor="middle"))
    s.append(text(W / 2, 56, subtitle, 13, SOFT, anchor="middle"))

    # legend, centred: the routes in chart order, then the Mac's line
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

    # the Mac: one dashed line at 100 % through every row, behind the bars
    s.append(f'<line x1="{left + full}" y1="{top - 4}" x2="{left + full}" y2="{top + len(tests) * (group + gap) - gap + 4}" stroke="{INK}" stroke-opacity="0.45" stroke-dasharray="3 3"/>')
    y = top
    for key, label, bench in tests:
        s.append(text(40, y + group / 2 - 3, label, 15, weight="600"))
        s.append(text(40, y + group / 2 + 14, bench, 12, MUTED))
        for i, (name, rl, col) in enumerate(routes):
            by = y + i * pitch
            p = share(name, key)
            if p is None:
                s.append(text(left, by + 10, f"– {rl}: " + missing.get(name, {}).get(key, "not available"), 11, MUTED, MONO))
                continue
            w = max(2, min(full * 1.1, full * p / 100))
            fill = f"url(#hatch-{name})" if (name, key) in unrel else col
            s.append(f'<rect x="{left}" y="{by + (pitch - bar) / 2:.1f}" width="{w:.1f}" height="{bar}" rx="3" fill="{fill}"/>')
            tx = left + w + 8
            if tx - 8 < left + full < tx + 40:  # keep the Mac's line out from behind the value
                s.append(f'<rect x="{left + w + 1:.1f}" y="{by}" width="52" height="{pitch}" fill="{BG}"/>')
            s.append(text(f"{tx:.1f}", by + 11, f"{round(p)} %", 12, INK, MONO, "600" if name == routes[0][0] else None, halo=True))
            if (name, key) in unrel:
                s.append(f'<rect x="{tx + 42:.1f}" y="{by + 1}" width="86" height="13" rx="6.5" fill="none" stroke="{col}" stroke-opacity="0.7"/>')
                s.append(text(f"{tx + 85:.1f}", by + 11, "not released", 10, col, anchor="middle"))
        y += group + gap
    s.append(text(W / 2, H - 14, NOTE, 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


if __name__ == "__main__":
    main()
