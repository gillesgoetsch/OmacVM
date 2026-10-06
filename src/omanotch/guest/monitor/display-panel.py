#!/usr/bin/env python3
"""Keep Omanotch's hidden NOTCH output out of Omarchy's display panel.

usage: display-panel.py              (install.sh: clone the panel, patch it)
       display-panel.py --refresh    (notchcast start: rebuild a clone that
                                      an Omarchy update left behind)
       display-panel.py --remove     (uninstall.sh: back to Omarchy's panel)
       display-panel.py --patch FILE (patch one Panel.qml in place)

Omarchy's display panel lists every Hyprland output. NOTCH (the strip beside
the notch) is not a display: listed, it can be scaled or switched off there,
which breaks Omanotch. The patch leaves outputs named NOTCH* out of the list,
the count behind the "monitors" section and the bar icon.

The patched copy is the plugin omanotch.monitor in ~/.config/omarchy/plugins,
a clone of Omarchy's panel (clonedFrom omarchy.monitor, so it takes that
widget's place). It is built from Omarchy's panel and built again when that
panel changed (.source-sha256), so it follows Omarchy updates. When the patch
no longer fits Omarchy's panel, Omarchy's own panel is used again. OmacVM.app's
display panel (omacvm.monitor) carries the same patch
(src/app/guest/monitor-widget/build.py): then no clone is made.
"""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

MARK = "omarchy-notch-bar"
VERSION = 1
VERSION_LINE = f"// omarchy-notch-bar display panel patch v{VERSION}"
CLONE_ID = "omanotch.monitor"

HELPERS = f"""  // --- omarchy-notch-bar ------------------------------------------------
  {VERSION_LINE}
  // Outputs named NOTCH* are Omanotch's hidden strip beside the notch, not
  // displays: left out of the list, the count and the bar icon.
  function notchHidden(name) {{
    return String(name || "").indexOf("NOTCH") === 0
  }}
  function notchScreenCount() {{
    var n = 0
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i] && !notchHidden(Quickshell.screens[i].name)) n++
    return n
  }}
  function notchFilterJson(raw) {{
    try {{
      var list = JSON.parse(String(raw || "[]"))
      if (Array.isArray(list))
        return JSON.stringify(list.filter(function(d) {{ return !(d && notchHidden(d.name)) }}))
    }} catch (e) {{}}
    return raw
  }}
  // --- end omarchy-notch-bar --------------------------------------------
"""

# (anchor, replacement): every anchor must be found exactly once.
EDITS = [
    ("  property var displays: []\n",
     "  property var displays: []\n" + HELPERS),
    ("    var parsed = Model.parseDisplays(displaysJson)\n",
     "    var parsed = Model.parseDisplays(root.notchFilterJson(displaysJson))\n"),
    ('    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"\n',
     '    text: root.notchScreenCount() > 1 ? "󰍺" : "󰍹"\n'),
]


def patch(text):
    """Omarchy's Panel.qml with NOTCH left out. ValueError when it does not fit."""
    if VERSION_LINE in text:
        return text
    if MARK in text:
        raise ValueError("carries another version of the patch")
    for anchor, replacement in EDITS:
        if text.count(anchor) != 1:
            raise ValueError(f"no single {anchor.strip()[:50]!r}")
        text = text.replace(anchor, replacement)
    return text


def plugins_dir():
    config = os.environ.get("XDG_CONFIG_HOME") or str(pathlib.Path.home() / ".config")
    return pathlib.Path(config) / "omarchy/plugins"


def source_dir():
    omarchy = os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy"
    return pathlib.Path(omarchy) / "shell/plugins/panels/monitor"


def run(*cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def source_digest(source):
    """Omarchy's whole panel folder and this patch's version, as one hash."""
    h = hashlib.sha256(f"patch v{VERSION}\n".encode())
    for item in sorted(source.rglob("*")):
        if item.is_file():
            h.update(str(item.relative_to(source)).encode() + b"\0")
            h.update(item.read_bytes() + b"\0")
    return h.hexdigest()


def staged(clone):
    """The folder a build goes into, and the one the old clone moves to."""
    return clone.with_name(f".{clone.name}.new"), clone.with_name(f".{clone.name}.old")


def tidy(clone):
    """After a build that was cut off: the stage goes, and the old clone gets
    its place back if the new one never got there."""
    new, old = staged(clone)
    shutil.rmtree(new, ignore_errors=True)
    if old.is_dir():
        if clone.is_dir():
            shutil.rmtree(old, ignore_errors=True)
        else:
            old.rename(clone)


def build(clone, source):
    """Fill the clone from Omarchy's panel, patched. Returns what it did."""
    digest = source_digest(source)
    stamp = clone / ".source-sha256"
    if stamp.exists() and stamp.read_text().strip() == digest:
        return "already patched"
    patched = patch((source / "Panel.qml").read_text())
    new, old = staged(clone)
    shutil.rmtree(new, ignore_errors=True)
    # The whole folder, as `omarchy plugin clone` copies it.
    shutil.copytree(source, new)
    (new / "Panel.qml").write_text(patched)
    # Omarchy's manifest as a clone (what `omarchy plugin clone` writes): it
    # takes the place of omarchy.monitor in the bar.
    manifest = json.loads((source / "manifest.json").read_text())
    manifest["id"] = CLONE_ID
    manifest["name"] = "Display (Omanotch)"
    if isinstance(manifest.get("barWidget"), dict):
        manifest["barWidget"]["displayName"] = manifest["name"]
    extra = manifest.get("omarchy") if isinstance(manifest.get("omarchy"), dict) else {}
    extra.pop("clonePaths", None)
    manifest["omarchy"] = {**extra, "clonedFrom": "omarchy.monitor"}
    (new / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    (new / ".source-sha256").write_text(digest + "\n")
    # The clone is missing only between these two renames; if a build is cut
    # off there, tidy() puts the old one back.
    if clone.is_dir():
        clone.rename(old)
    new.rename(clone)
    shutil.rmtree(old, ignore_errors=True)
    return "patched"


def enabled(plugin_id):
    try:
        return any(p.get("id") == plugin_id and p.get("enabled")
                   for p in json.loads(run("omarchy-plugin-list", "--json") or "[]"))
    except (ValueError, AttributeError):
        return False


def other_clone(plugins):
    """The id of a clone of Omarchy's display panel that is not ours, or None."""
    for manifest in sorted(plugins.glob("*/manifest.json")):
        # Hidden folders are builds under way (ours, `omarchy plugin clone`'s).
        if manifest.parent.name == CLONE_ID or manifest.parent.name.startswith("."):
            continue
        try:
            data = json.loads(manifest.read_text())
        except (OSError, ValueError):
            continue
        extra = data.get("omarchy") if isinstance(data, dict) else None
        if isinstance(extra, dict) and extra.get("clonedFrom") == "omarchy.monitor":
            return data.get("id") or manifest.parent.name
    return None


def bar_back(shell_json, own=None):
    """omarchy.monitor back in the clone's place in the bar, in shell.json
    itself (no shell to ask); only the clone goes when the bar has a display
    panel already (the user's own: OWN). The file keeps its owner and mode."""
    try:
        config = json.loads(shell_json.read_text())
        layout = config["bar"]["layout"]
    except (OSError, ValueError, KeyError, TypeError):
        return
    if not isinstance(layout, dict):
        return

    def entry_id(entry):
        return entry.get("id") if isinstance(entry, dict) else entry

    sections = [v for v in layout.values() if isinstance(v, list)]
    if not any(entry_id(e) == CLONE_ID for v in sections for e in v):
        return
    stock = any(entry_id(e) in ("omarchy.monitor", own) for v in sections for e in v)
    for v in sections:
        for i in range(len(v) - 1, -1, -1):
            if entry_id(v[i]) != CLONE_ID:
                continue
            if stock:
                del v[i]
            elif isinstance(v[i], dict):
                v[i]["id"] = "omarchy.monitor"
            else:
                v[i] = "omarchy.monitor"
            stock = True
    with open(shell_json, "w") as f:
        f.write(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


def remove(clone, shell=True):
    """Back to Omarchy's panel. Disabling the clone puts omarchy.monitor in its
    place. With a display panel of the user's own, only the clone goes from
    shell.json (the shell reloads it): disabling would add omarchy.monitor
    next to theirs."""
    tidy(clone)
    if not clone.exists():
        return
    own = other_clone(clone.parent)
    if own or not (shell and run("omarchy-plugin-disable", CLONE_ID).startswith("Disabled")):
        bar_back(clone.parent.parent / "shell.json", own)
    shutil.rmtree(clone, ignore_errors=True)
    if shell:
        run("omarchy-shell", "-q", "shell", "rescanPlugins")


def main(argv):
    if len(argv) == 3 and argv[1] == "--patch":
        path = pathlib.Path(argv[2])
        path.write_text(patch(path.read_text()))
        return 0
    mode = argv[1] if len(argv) > 1 else ""
    plugins = plugins_dir()
    clone = plugins / CLONE_ID
    if mode in ("--remove", "--drop"):
        remove(clone, shell=mode == "--remove")
        return 0
    tidy(clone)
    if (plugins / "omacvm.monitor").is_dir():
        print("OmacVM.app's display panel leaves NOTCH out already")
        return 0
    other = other_clone(plugins)
    if other:
        print(f"your own display panel ({other}) is used: left alone")
        return 0
    source = source_dir()
    if not (source / "Panel.qml").is_file():
        print(f"no Omarchy display panel at {source}: left alone")
        return 0
    if mode == "--refresh" and not clone.is_dir():
        return 0
    try:
        patch((source / "Panel.qml").read_text())
    except ValueError as error:
        print(f"Omarchy's display panel changed ({error}): Omarchy's own panel is used")
        remove(clone)
        return 0
    result = build(clone, source)
    # --refresh runs at every notchcast start: no shell calls when nothing changed.
    if result == "patched" or (mode != "--refresh" and not enabled(CLONE_ID)):
        # Seconds at most: notchcast's start waits for this.
        deadline = time.monotonic() + 8
        run("omarchy-shell", "-q", "shell", "rescanPlugins", timeout=4)
        # A new plugin needs a moment before the shell knows it.
        while time.monotonic() < deadline:
            if run("omarchy-plugin-enable", CLONE_ID, timeout=2).startswith("Enabled"):
                break
            time.sleep(0.05)
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
