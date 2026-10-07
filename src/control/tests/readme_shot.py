"""Renders the control centre for the README (docs/images/control-centre.svg):
the real Textual app against the test fakes, as an OmacVM.app VM on a
MacBook, in Omarchy's default theme (Tokyo Night).

    pip install textual==8.2.8
    python3 src/control/tests/readme_shot.py docs/images/control-centre.svg
"""
import asyncio
import io
import json
import os
import re
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

from rich.console import Console  # noqa: E402
from rich.terminal_theme import TerminalTheme  # noqa: E402

from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402

# Omarchy's Tokyo Night terminal colours.
TOKYO_NIGHT = TerminalTheme(
    (0x1a, 0x1b, 0x26), (0xa9, 0xb1, 0xd6),
    [(0x32, 0x34, 0x4a), (0xf7, 0x76, 0x8e), (0x9e, 0xce, 0x6a), (0xe0, 0xaf, 0x68),
     (0x7a, 0xa2, 0xf7), (0xad, 0x8e, 0xe6), (0x44, 0x9d, 0xab), (0x78, 0x7c, 0x99)],
    [(0x44, 0x4b, 0x6a), (0xff, 0x7a, 0x93), (0xb9, 0xf2, 0x7c), (0xff, 0x9e, 0x64),
     (0x7d, 0xa6, 0xff), (0xbb, 0x9a, 0xf7), (0x0d, 0xb9, 0xd7), (0xac, 0xb0, 0xd0)],
)

ON = ("bridge wallpaper gestures scroll-momentum omanotch mac-clock camera battery external-brightness "
      "chromium-video no-idle-lock control-centre fast-network").split()
OFF = "autologin thp-kernel vulkan".split()

CHECKS = "".join(f"ok\t{f}\tworks\t\t{f}\n" for f in ON)

# A floating window on Omarchy's desktop, instead of Rich's macOS frame.
FRAME = """<svg viewBox="0 0 {width} {height}" xmlns="http://www.w3.org/2000/svg" role="img">
<title>The OmacVM control centre in Omarchy</title>
<style>
.{unique_id}-matrix {{ font-family: "JetBrainsMono Nerd Font", "JetBrains Mono", ui-monospace, SFMono-Regular,
  Menlo, Consolas, monospace; font-size: {char_height}px; line-height: {line_height}px; }}
{styles}
</style>
<defs><clipPath id="{unique_id}-clip-terminal"><rect x="0" y="0" width="{terminal_width}" height="{terminal_height}"/></clipPath>
{lines}
</defs>
<rect width="{width}" height="{height}" rx="10" fill="#13141c"/>
<rect x="MARGIN" y="MARGIN" width="{terminal_width}" height="{terminal_height}" fill="#1a1b26" stroke="#7aa2f7" stroke-width="2"/>
<g transform="translate({terminal_x}, {terminal_y})" clip-path="url(#{unique_id}-clip-terminal)">
{backgrounds}
<g class="{unique_id}-matrix">
{matrix}
</g>
</g>
</svg>
"""
MARGIN = 28


def framed(svg: str) -> str:
    """Rich leaves 40 px on top for its title bar and 1 px around: make it an even margin."""
    m = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg)
    w, h = float(m.group(1)), float(m.group(2))
    tw, th = w - 2, h - 2 - 32   # the terminal with 8 px padding all round
    svg = svg.replace(m.group(0), f'viewBox="0 0 {tw + 2 * MARGIN:g} {th + 2 * MARGIN:g}"', 1)
    svg = re.sub(r'<rect x="MARGIN" y="MARGIN" width="[\d.]+" height="[\d.]+"',
                 f'<rect x="{MARGIN}" y="{MARGIN}" width="{tw:g}" height="{th:g}"', svg, count=1)
    svg = re.sub(r'<rect width="[\d.]+" height="[\d.]+" rx="10"',
                 f'<rect width="{tw + 2 * MARGIN:g}" height="{th + 2 * MARGIN:g}" rx="10"', svg, count=1)
    return re.sub(r'<g transform="translate\([\d.]+, [\d.]+\)"',
                  f'<g transform="translate({MARGIN + 8}, {MARGIN + 8})"', svg, count=1)


def main(out: str) -> None:
    tmp = tempfile.mkdtemp()
    mac, checks = FakeMac(version="3.0.0"), FakeChecks(CHECKS)
    mac.graphics = {"graphics": "auto", "next_start": "opengl", "this_start": "auto -> opengl (macOS 26)",
                    "driver_ready": True}
    mac.gpu_memory = {"measured": True, "in_use_mb": 1126, "peak_mb": 1638, "budget_mb": 49152,
                      "pressure": "normal", "refused": 0, "lost": 0}
    flags = "".join(f"OMACVM_FEATURE_{f.replace('-', '_')}={'on' if f in ON else 'off'}\n" for f in ON + OFF)
    env = vm_env(tmp, mac.port, checks.path, "OMACVM_VM_TYPE=app\n" + flags)
    os.environ.update(env)
    with open(os.path.join(env["OMACVM_SHARE"], "VERSION"), "w") as f:
        f.write("3.0.0\n")
    with open(env["OMACVM_INSTALLED"], "w") as f:
        json.dump({"version": "3.0.0", "parts": {}}, f)

    from omacvm_cc import look
    from omacvm_cc.controller import Controller
    from omacvm_cc.state import Status
    from omacvm_cc.tui import ControlCentre
    # Omarchy draws Nerd Font marks; a browser showing the README has no Nerd Font.
    for st, mark in {Status.WORKS: "\u2713", Status.OFF: "\u25cb", Status.FAILING: "\u2717",
                     Status.NEEDS_PERSON: "!"}.items():
        look.GLYPH[st] = (mark, look.GLYPH[st][1])

    async def go():
        a = ControlCentre(Controller())
        async with a.run_test(size=(100, 24)) as pilot:
            end = time.monotonic() + 15
            while time.monotonic() < end:
                await pilot.pause(0.1)
                r = {x.feature.name: x for x in a.rows}
                if a.c.linked and a.c.vm_checks is not None and r.get("gpu-memory") \
                        and r["gpu-memory"].status is Status.WORKS:
                    break
            await pilot.pause(0.3)
            # As App.export_screenshot, with Omarchy's colours and frame.
            console = Console(width=a.size.width, height=a.size.height, file=io.StringIO(), force_terminal=True,
                              color_system="truecolor", record=True, legacy_windows=False, safe_box=False)
            console.print(a.screen._compositor.render_update(full=True, screen_stack=a._background_screens))
            svg = framed(console.export_svg(theme=TOKYO_NIGHT, code_format=FRAME, unique_id="cc"))
        with open(out, "w", encoding="utf-8") as f:
            f.write(svg)

    try:
        asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "control-centre.svg")
