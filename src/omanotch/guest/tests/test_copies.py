#!/usr/bin/env python3
"""Omanotch's copies of Omarchy's bar and background follow Omarchy's updates
(guest/copies.py), offline: Omarchy's plugins are folders made from
src/tests/omarchy-shell (omarchy-mac's shell and upstream's newer one), the
shell's restart is a stand-in.

    python3 src/omanotch/guest/tests/test_copies.py
"""
import difflib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[4]
GUEST = ROOT / "src/omanotch/guest"
SHELLS = ROOT / "src/tests/omarchy-shell"
MAC, UPSTREAM = "omarchy-mac-ba546a61", "omarchy-a06ec133"
USER = "tester"
PIN = "import QtQuick 6.11 // omacvm #376: QtQuick's own Color (Qt 6.12) would hide Omarchy's"

MANIFESTS = {
    "bar": {"schemaVersion": 1, "id": "omarchy.bar", "name": "Bar", "version": "1.0.0", "author": "Omarchy",
            "description": "Status bar with widgets", "kinds": ["bar"], "entryPoints": {"bar": "Bar.qml"}},
    "background": {"schemaVersion": 1, "id": "omarchy.background", "name": "Background", "version": "1.0.0",
                   "author": "Omarchy", "description": "Desktop background renderer", "kinds": ["service"],
                   "entryPoints": {"service": "Background.qml"}},
}


class Copies(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        self.omarchy = self.tmp / "omarchy"
        (self.home / ".config/omarchy/plugins").mkdir(parents=True)
        self.env = dict(os.environ)
        os.environ.update(HOME=str(self.home), USER=USER, OMARCHY_PATH=str(self.omarchy),
                          XDG_CONFIG_HOME=str(self.home / ".config"), XDG_STATE_HOME=str(self.home / ".local/state"),
                          XDG_RUNTIME_DIR=str(self.tmp / "run"))
        # copies.py with its patchers, as installed (~/.local/lib/omanotch).
        self.lib = self.tmp / "lib"
        for f in ("copies.py", "bar/apply-patch.py", "background/apply-patch.py"):
            (self.lib / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(GUEST / f, self.lib / f)
        self.load()
        self.restarts = 0
        self.refuse = {}     # what the stand-in shell refuses to load: copy name -> error
        self.locked = False
        self.shell("bar", MAC)
        self.shell("background", MAC)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)
        shutil.rmtree(self.tmp)

    def load(self):
        spec = importlib.util.spec_from_file_location("copies", self.lib / "copies.py")
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        m = self.m

        def restart(copies):
            self.restarts += 1
            if self.refuse == m.LATER:
                return m.LATER
            return {c.name: self.refuse[c.name] for c in copies if c.name in self.refuse}

        def run(cmd, timeout=30):
            if cmd[:1] == ["omarchy-plugin-clone"]:
                return self.clone(cmd[1]), ""
            return 1, ""
        m.print = lambda *a, **k: None   # its one line per copy
        m.restart_and_check = restart
        m.session_locked = lambda: self.locked
        m.recolor = lambda c: None
        m.run = run

    # ---- Omarchy's side ----
    def shell(self, name, which, change=None):
        """Omarchy's plugin `name` as in that shell (an update replaces it)."""
        d = self.omarchy / "shell/plugins" / name
        if d.exists():
            shutil.rmtree(d)
        shutil.copytree(SHELLS / which / "shell/plugins" / name, d)
        (d / "manifest.json").write_text(json.dumps(MANIFESTS[name], indent=2) + "\n")
        (d / "README.md").write_text(f"Omarchy's {name} ({which})\n")
        if change:
            change(d)

    def clone(self, source):
        """omarchy plugin clone: the folder, and jq's manifest."""
        name = source.split(".", 1)[1]
        target = self.plugins / f"{USER}.{name}"
        shutil.copytree(self.omarchy / "shell/plugins" / name, target)
        m = json.loads((target / "manifest.json").read_text())
        m.update(id=f"{USER}.{name}", name=f"My {m['name']}", omarchy={"clonedFrom": source})
        (target / "manifest.json").write_text(json.dumps(m, indent=2, separators=(",", ": ")) + "\n")
        return 0

    @property
    def plugins(self):
        return self.home / ".config/omarchy/plugins"

    def copy(self, name="bar"):
        return self.plugins / f"{USER}.{name}"

    def entry(self, name="bar"):
        return self.copy(name) / ("Bar.qml" if name == "bar" else "Background.qml")

    def files(self, top):
        return {str(p.relative_to(top)): p.read_bytes() for p in sorted(top.rglob("*")) if p.is_file()}

    def follow(self, install=False):
        return self.m.follow(install=install)

    def state(self, name="bar"):
        return json.loads((self.home / ".local/state/omanotch/copies" / name / "state.json").read_text())

    def check(self):
        return {name: (st, d) for st, name, d in self.m.check_lines()}

    def patched(self, name, which):
        c = next(c for c in self.m.COPIES if c.name == name)
        entry = SHELLS / which / "shell/plugins" / name / c.entry
        return self.m.patch_text(c, entry.read_bytes())

    # ---- edits ----
    def quiet_line(self, a, b):
        """A line in the middle of a long stretch both texts share."""
        al, bl = a.decode().splitlines(True), b.decode().splitlines(True)
        best = max((blk for blk in difflib.SequenceMatcher(None, al, bl, autojunk=False).get_matching_blocks()),
                   key=lambda blk: blk.size)
        self.assertGreater(best.size, 20)
        mid = best.a + best.size // 2
        # One that is there once (the edit finds it), away from the block's ends.
        return next(al[i] for i in sorted(range(best.a + 5, best.a + best.size - 5), key=lambda i: abs(i - mid))
                    if al.count(al[i]) == 1 and al[i].strip())

    def changed_line(self, a, b):
        """A line of a that b changes."""
        al, bl = a.decode().splitlines(True), b.decode().splitlines(True)
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, al, bl, autojunk=False).get_opcodes():
            if tag == "replace" and al[i1].strip():
                return al[i1]
        self.fail("no changed line")

    def edit(self, path, old, new):
        text = path.read_text()
        self.assertEqual(text.count(old), 1, old)
        path.write_text(text.replace(old, new))

    # ---- tests ----
    def test_install_makes_and_patches_both_copies(self):
        for which in (MAC, UPSTREAM):
            with self.subTest(which):
                for name in ("bar", "background"):
                    if self.copy(name).exists():
                        shutil.rmtree(self.copy(name))
                    self.shell(name, which)
                shutil.rmtree(self.home / ".local/state", ignore_errors=True)
                self.assertEqual(self.follow(install=True), 0)
                for name in ("bar", "background"):
                    self.assertEqual(self.entry(name).read_bytes(), self.patched(name, which))
                    backup = self.entry(name).with_name(self.entry(name).name + ".before-notchbar")
                    self.assertEqual(backup.read_bytes(), (SHELLS / which / "shell/plugins" / name / self.entry(name).name).read_bytes())
                    self.assertEqual(self.state(name)["result"], "current")
                    self.assertEqual(self.check()[f"{name} copy"][0], "ok")
                n = self.restarts
                self.assertEqual(self.follow(), 0)
                self.assertEqual(self.restarts, n, "nothing changed: no restart")

    def test_unchanged_copy_follows_an_update(self):
        for old, new in ((MAC, UPSTREAM), (UPSTREAM, MAC)):
            with self.subTest(f"{old} -> {new}"):
                self.reset(old)
                self.follow(install=True)
                n = self.restarts
                self.shell("bar", new)
                self.shell("background", new)
                self.assertEqual(self.follow(), 0)
                self.assertEqual(self.restarts, n + 1, "one restart for both copies")
                for name in ("bar", "background"):
                    self.assertEqual(self.entry(name).read_bytes(), self.patched(name, new))
                    self.assertEqual(self.state(name)["edits"], [])
                self.assertEqual((self.copy() / "widgets/Indicators.qml").read_bytes(),
                                 (SHELLS / new / "shell/plugins/bar/widgets/Indicators.qml").read_bytes())
                self.assertEqual((self.copy() / "README.md").read_text(), f"Omarchy's bar ({new})\n")
                self.assertEqual(json.loads((self.copy() / "manifest.json").read_text())["id"], f"{USER}.bar")

    def reset(self, which):
        for name in ("bar", "background"):
            if self.copy(name).exists():
                shutil.rmtree(self.copy(name))
            self.shell(name, which)
        shutil.rmtree(self.home / ".local/state", ignore_errors=True)

    def test_your_edits_stay_when_they_merge(self):
        self.follow(install=True)
        mine = self.quiet_line(self.patched("bar", MAC), self.patched("bar", UPSTREAM))
        self.edit(self.entry(), mine, mine + "  // mine: stays\n")
        widget = self.copy() / "widgets/Mine.qml"
        widget.write_text("Item {}\n")
        readme = self.copy() / "README.md"
        readme.write_text(readme.read_text() + "my notes\n")   # Omarchy's update leaves it as it was
        self.shell("bar", UPSTREAM, change=lambda d: (d / "README.md").write_text("Omarchy's bar (mac)\n".replace("(mac)", f"({MAC})")))
        self.assertEqual(self.follow(), 0)
        text = self.entry().read_text()
        self.assertIn("// mine: stays", text)
        # Everything else is Omarchy's new bar with the patch.
        self.assertEqual(text.replace(mine + "  // mine: stays\n", mine), self.patched("bar", UPSTREAM).decode())
        self.assertEqual(widget.read_text(), "Item {}\n")
        self.assertEqual(readme.read_text(), f"Omarchy's bar ({MAC})\nmy notes\n")
        self.assertEqual(sorted(self.state()["edits"]), ["Bar.qml", "README.md", "widgets/Mine.qml"])
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "ok")
        self.assertIn("your edits kept: Bar.qml", d)
        # The next update merges against what OmacVM wrote this time.
        self.shell("bar", MAC)
        self.assertEqual(self.follow(), 0)
        self.assertIn("// mine: stays", self.entry().read_text())

    def test_overlapping_edit_keeps_the_copy_and_says_so(self):
        self.follow(install=True)
        line = self.changed_line(self.patched("bar", MAC), self.patched("bar", UPSTREAM))
        self.edit(self.entry(), line, line.rstrip("\n") + " // mine\n")
        before = self.files(self.copy())
        n = self.restarts
        self.shell("bar", UPSTREAM)
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.files(self.copy()), before, "the copy stays exactly as it was")
        self.assertEqual(self.restarts, n)
        s = self.state()
        self.assertEqual((s["result"], s["files"]), ("conflict", ["Bar.qml"]))
        marked = (self.home / ".local/state/omanotch/copies/bar/conflict/Bar.qml").read_text()
        self.assertIn("<<<<<<< your copy", marked)
        self.assertIn(">>>>>>> Omarchy's new with OmacVM's patch", marked)
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("your edits overlap Omarchy's changes in Bar.qml", d)
        # Not tried again until something changes; the background followed.
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.files(self.copy()), before)
        self.assertFalse(self.m.needs_work())
        # Your copy taking Omarchy's change too: it merges.
        self.entry().write_text(self.entry().read_text().replace(line.rstrip("\n") + " // mine\n", line))
        self.assertTrue(self.m.needs_work())
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.state()["result"], "current")
        self.assertFalse((self.home / ".local/state/omanotch/copies/bar/conflict").exists())

    def test_a_copy_that_does_not_load_goes_back(self):
        self.follow(install=True)
        before = {n: self.files(self.copy(n)) for n in ("bar", "background")}
        self.shell("bar", UPSTREAM)
        self.shell("background", UPSTREAM)
        self.refuse = {"bar": "Bar.qml:120: TypeError: Cannot read property 'x' of undefined"}
        n = self.restarts
        self.assertEqual(self.follow(), 1)
        self.assertEqual(self.restarts, n + 2, "a restart to try, one to go back")
        self.assertEqual(self.files(self.copy("bar")), before["bar"], "every file as it was")
        self.assertNotEqual(self.files(self.copy("background")), before["background"], "the background loaded: it stays")
        self.assertEqual(self.state("bar")["result"], "rolled-back")
        self.assertFalse((self.home / ".local/state/omanotch/copies/bar/pending").exists())
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("did not load", d)
        # Not again for the same update...
        self.refuse = {}
        n = self.restarts
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.restarts, n)
        # ... but for the next one.
        self.shell("bar", UPSTREAM, change=lambda d: (d / "README.md").write_text("next\n"))
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))

    def test_a_refresh_cut_short_is_taken_back(self):
        self.follow(install=True)
        before = self.files(self.copy())
        self.shell("bar", UPSTREAM)
        c = self.m.COPIES[0]
        p = self.m.plan(c, False)
        self.m.apply(c, p["ours_raw"], p["result"], p["stock_entry"])   # then the VM went off
        self.assertNotEqual(self.files(self.copy()), before)
        self.assertTrue(self.m.needs_work())
        self.refuse = {"bar": "TypeError"}
        self.assertEqual(self.follow(), 1)
        self.assertEqual(self.files(self.copy()), before)

    def test_a_shell_that_did_not_restart_tries_again_later(self):
        """Locked between the look and the restart: Omarchy refuses the
        restart; the files go back and it is tried again (not a failure)."""
        self.follow(install=True)
        before = self.files(self.copy())
        self.shell("bar", UPSTREAM)
        self.refuse = self.m.LATER
        self.assertEqual(self.follow(), 3)
        self.assertEqual(self.files(self.copy()), before)
        self.assertEqual(self.state()["result"], "current")
        self.assertTrue(self.m.needs_work())
        self.refuse = {}
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))

    def test_shell_colors_lines_are_not_your_edits(self):
        self.follow(install=True)
        for p in [self.entry(), self.entry().with_name("Bar.qml.before-notchbar"), self.copy() / "widgets/Indicators.qml"]:
            p.write_text(re.sub(r"(?m)^import QtQuick$", PIN, p.read_text()))
        self.shell("bar", UPSTREAM)
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.state()["edits"], [])
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))

    def test_your_manifest_name_stays(self):
        self.follow(install=True)
        m = json.loads((self.copy() / "manifest.json").read_text())
        m["name"] = "Gilles' bar"
        (self.copy() / "manifest.json").write_text(json.dumps(m, indent=4))
        MANIFESTS["bar"]["version"] = "1.1.0"
        try:
            self.shell("bar", UPSTREAM)
        finally:
            MANIFESTS["bar"]["version"] = "1.0.0"
        self.assertEqual(self.follow(), 0)
        m = json.loads((self.copy() / "manifest.json").read_text())
        self.assertEqual((m["name"], m["version"], m["id"]), ("Gilles' bar", "1.1.0", f"{USER}.bar"))

    def test_a_new_patch_keeps_your_edits(self):
        self.follow(install=True)
        mine = self.quiet_line(self.patched("bar", MAC), self.patched("bar", MAC))
        self.edit(self.entry(), mine, mine + "  // mine\n")
        self.newer_patch()
        self.assertEqual(self.follow(), 0)
        text = self.entry().read_text()
        self.assertIn("  // mine\n", text)
        self.assertIn("// newer patch", text)

    def newer_patch(self):
        """OmacVM's patch changes: the bar patcher adds a line."""
        src = (self.lib / "bar/apply-patch.py").read_text()
        src = src.replace('    open(path, "w").write(text)\n    print("patched")',
                          '    text = text.replace(VERSION_LINE, VERSION_LINE + "\\n  // newer patch", 1)\n'
                          '    open(path, "w").write(text)\n    print("patched")')
        self.assertIn("// newer patch", src)
        (self.lib / "bar/apply-patch.py").write_text(src)

    def old_copy(self, which=MAC, version=None):
        """A copy as install.sh made it before 3.1.12: clone, backup, patch in place, no record."""
        self.clone("omarchy.bar")
        shutil.copy(self.entry(), self.entry().with_name("Bar.qml.before-notchbar"))
        text = self.patched("bar", which)
        if version:
            text = re.sub(rb"patch v\d+", b"patch v%d" % version, text, count=1)
        self.entry().write_bytes(text)

    @property
    def backup(self):
        return self.plugins / f".{USER}.bar.before-3.1.13"

    def test_a_copy_from_before_this_as_omacvm_made_it_gets_its_record(self):
        """Nothing to keep: no backup, no file written, no restart, no note."""
        self.old_copy()
        self.clone("omarchy.background")   # its copy as install.sh made it too
        bg = self.entry("background")
        shutil.copy(bg, bg.with_name("Background.qml.before-notchbar"))
        bg.write_bytes(self.patched("background", MAC))
        before, n = self.files(self.copy()), self.restarts
        self.assertEqual(self.follow(install=True), 0)
        self.assertEqual(self.files(self.copy()), before)
        self.assertEqual(self.restarts, n)
        self.assertFalse(self.backup.exists())
        self.assertEqual((self.state()["result"], self.state().get("backup")), ("current", None))
        self.assertEqual(self.check()["bar copy"][0], "ok")
        # From now on Omarchy's updates merge.
        self.shell("bar", UPSTREAM)
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))

    def test_a_copy_from_before_this_with_edits_is_kept_aside_and_made_new(self):
        self.old_copy()
        mine = self.quiet_line(self.patched("bar", MAC), self.patched("bar", UPSTREAM))
        self.edit(self.entry(), mine, mine + "  // mine\n")
        (self.copy() / "widgets/Mine.qml").write_text("Item {}\n")
        before = self.files(self.copy())
        self.assertEqual(self.follow(install=True), 0)
        # The whole folder as it was, hidden beside it; the copy is what OmacVM makes.
        self.assertEqual(self.files(self.backup), before)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", MAC))
        self.assertFalse((self.copy() / "widgets/Mine.qml").exists())
        s = self.state()
        self.assertEqual((s["result"], s["edits"], s["backup"]), ("current", [], str(self.backup)))
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("made new from Omarchy's bar on ", d)
        self.assertIn(f"in ~/.config/omarchy/plugins/.{USER}.bar.before-3.1.13, in case you had changed it", d)
        # Once: the next run (Update VM again) changes nothing, no second backup.
        n, copy_now = self.restarts, self.files(self.copy())
        self.assertEqual(self.follow(install=True), 0)
        self.assertEqual((self.restarts, self.files(self.copy())), (n, copy_now))
        self.assertEqual(sorted(p.name for p in self.plugins.iterdir() if p.name.startswith(".")), [self.backup.name])
        # A later Omarchy update merges, and the note stays while the backup is there.
        self.shell("bar", UPSTREAM)
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))
        self.assertEqual(self.check()["bar copy"][0], "warn")
        # Deleted, or two weeks old: no more note.
        shutil.rmtree(self.backup)
        self.assertEqual(self.check()["bar copy"][0], "ok")

    def test_the_note_goes_after_two_weeks(self):
        self.old_copy(version=1)
        self.assertEqual(self.follow(install=True), 0)
        self.assertEqual(self.check()["bar copy"][0], "warn")
        f = self.home / ".local/state/omanotch/copies/bar/state.json"
        s = json.loads(f.read_text())
        s["backup_at"] = "2026-01-01 10:00"
        f.write_text(json.dumps(s))
        self.assertEqual(self.check()["bar copy"][0], "ok")
        self.assertTrue(self.backup.exists(), "the backup itself stays")

    def test_an_older_patch_and_omarchy_are_made_new(self):
        """Made from omarchy-mac's bar with an older patch, Omarchy is upstream's now."""
        self.old_copy(version=1)
        self.shell("bar", UPSTREAM)
        old = self.files(self.copy())
        self.assertEqual(self.follow(install=True), 0)
        self.assertEqual(self.files(self.backup), old)
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))
        self.assertEqual(self.entry().with_name("Bar.qml.before-notchbar").read_bytes(),
                         (SHELLS / UPSTREAM / "shell/plugins/bar/Bar.qml").read_bytes())

    def test_a_copy_made_new_that_does_not_load_goes_back(self):
        self.old_copy(version=1)
        before = self.files(self.copy())
        self.refuse = {"bar": "TypeError"}
        self.assertEqual(self.follow(install=True), 1)
        self.assertEqual(self.files(self.copy()), before)
        self.assertFalse(self.backup.exists(), "the copy is that one again: no backup")
        self.assertEqual(self.state()["result"], "rolled-back")

    def test_a_copy_3_1_12_could_not_take_over_is_made_new(self):
        """3.1.12 left such a copy as it was ("unknown"); now it is made new."""
        self.old_copy()
        self.shell("bar", UPSTREAM)
        st = self.home / ".local/state/omanotch/copies/bar"
        st.mkdir(parents=True)
        (st / "state.json").write_text(json.dumps({"result": "unknown", "why": "made from an older Omarchy"}))
        self.assertTrue(self.m.needs_work())
        self.assertEqual(self.follow(), 0)
        self.assertTrue(self.backup.exists())
        self.assertEqual(self.entry().read_bytes(), self.patched("bar", UPSTREAM))
        self.assertEqual(self.state()["result"], "current")

    def test_a_patch_that_does_not_fit_keeps_the_copy(self):
        self.follow(install=True)
        before = self.files(self.copy())
        self.shell("bar", UPSTREAM, change=lambda d: (d / "Bar.qml").write_text(
            (d / "Bar.qml").read_text().replace('  property string home: Quickshell.env("HOME")\n', "")))
        self.assertEqual(self.follow(), 0)
        self.assertEqual(self.files(self.copy()), before)
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("OmacVM's patch does not fit", d)

    def test_locked_session_waits(self):
        self.follow(install=True)
        self.shell("bar", UPSTREAM)
        self.locked = True
        before = self.files(self.copy())
        self.assertEqual(self.follow(), 3)
        self.assertEqual(self.files(self.copy()), before)
        self.assertTrue(self.m.needs_work())
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "ok")
        self.assertIn("follows when the session is unlocked", d)

    def test_a_removed_copy(self):
        self.follow(install=True)
        shutil.rmtree(self.copy())
        self.assertEqual(self.follow(), 0)
        st, d = self.check()["bar copy"]
        self.assertEqual(st, "warn")
        self.assertIn("is gone", d)
        self.assertEqual(self.follow(install=True), 0)
        self.assertEqual(self.check()["bar copy"][0], "ok")


    def test_what_counts_as_not_loading(self):
        """The shell's log as Quickshell writes it: errors naming the copy
        count, binding loops (Omarchy's own bar has them) and other files do not."""
        where = f"/plugins/{USER}.bar/"
        log = "\n".join([
            "2026-10-13 13:59:27.799  WARN scene: QML Bar at file:///home/x/.config/omarchy/plugins/tester.bar/Bar.qml[12:1]: Binding loop detected for property \"displayCutouts\":",
            "file:///home/x/.config/omarchy/plugins/tester.bar/Bar.qml:774:3",
            "2026-10-13 13:59:27.826  WARN scene: file:///usr/share/omarchy/shell/plugins/bar/indicators/Dictation.qml[-1:-1]: No such file or directory",
            "2026-10-13 13:59:28.001  WARN scene: QML Item: Cannot read property 'x' of undefined",
            "file:///home/x/.config/omarchy/plugins/tester.bar/Bar.qml:401: TypeError",
            "2026-10-13 13:59:28.100  INFO quickshell: Configuration Loaded",
        ])
        bad = [e for e in self.m.log_entries(log) if where in e and self.m.ERROR.search(e) and "Binding loop" not in e]
        self.assertEqual(len(bad), 1)
        self.assertIn("Cannot read property", bad[0])


# Omarchy's `omarchy-shell lock status` as omarchy-mac's shell answers it.
def status(locked, requested=False, sessionLocked=False, secure=False):
    return json.dumps({"locked": locked, "requested": requested, "pending": False, "sessionLocked": sessionLocked,
                       "secure": secure, "realScreens": 1, "passwordPam": True, "fingerprint": False,
                       "authenticating": False, "lastEvent": "unlocked", "lastEventAt": ""}, separators=(",", ":"))


WARN = ('\x1b[33m  WARN\x1b[0m: Detected locale "C" with character encoding "ANSI_X3.4-1968", which is not UTF-8.\n'
        'Qt depends on a UTF-8 locale, and has switched to "C.UTF-8" instead.')


class Locked(unittest.TestCase):
    """session_locked() against the shell's answers (Quickshell 0.3.2's
    isLocked stays true after the first unlock: omarchy-mac#738)."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("copies_lock", GUEST / "copies.py")
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.answers = {}
        self.m.run = lambda cmd, timeout=30: self.answers.get(tuple(cmd[1:]), (1, ""))

    def locked(self, status_answer, is_locked):
        self.answers = {("lock", "status"): status_answer, ("lock", "isLocked"): (0, is_locked)}
        return self.m.session_locked()

    def test_unlocked_after_an_unlock(self):
        self.assertFalse(self.locked((0, status(True)), "true"))

    def test_lock_screen_up_or_coming(self):
        self.assertTrue(self.locked((0, status(True, requested=True)), "true"))
        self.assertTrue(self.locked((0, status(True, sessionLocked=True)), "true"))
        self.assertTrue(self.locked((0, status(True, requested=True, sessionLocked=True, secure=True)), "true"))
        self.assertTrue(self.locked((0, status(True, secure=True)), "true"))

    def test_never_locked(self):
        self.assertFalse(self.locked((0, status(False)), "false"))

    def test_locale_warning_first(self):
        self.assertFalse(self.locked((0, WARN + "\n" + status(True)), WARN + "\ntrue"))
        self.assertTrue(self.locked((0, WARN + "\n" + status(True, requested=True)), WARN + "\ntrue"))

    def test_without_the_status_call(self):
        self.assertTrue(self.locked((1, ""), "true"))
        self.assertTrue(self.locked((1, ""), WARN + "\ntrue"))
        self.assertFalse(self.locked((1, ""), "false"))
        self.assertFalse(self.locked((0, "Function not found."), "false"))

    def test_shell_not_answering(self):
        self.answers = {}
        self.assertFalse(self.m.session_locked())


if __name__ == "__main__":
    unittest.main(verbosity=1)
