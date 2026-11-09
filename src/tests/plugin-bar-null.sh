#!/bin/bash
# OmacVM's bar widgets read the bar only through a guard.
# Omarchy's bar sets a widget's `bar` from outside, and when the shell reloads
# a plugin in place (the bar copy or a widget written, rescanPlugins: Omanotch's
# first-login install, Update VM, Omarchy updates) the old bar goes before its
# widgets, so `bar` is null for a moment: an unguarded `bar.foreground` in a
# binding logged "TypeError: Cannot read property 'foreground' of null", up to
# 246 lines per reload (3.4.1 and older). Offline: every bar.<property> read in
# src/*/plugins/*/*.qml, and in OmacVM.app's display panel (omacvm.monitor,
# built here from each Omarchy shell in src/tests/omarchy-shell), must sit in a
# `bar ? ... : ...` expression (barFg / barFont / barUrgent).
#   src/tests/plugin-bar-null.sh
#   OMACVM_SRC=DIR src/tests/plugin-bar-null.sh   against another checkout (3.4.1 fails)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${OMACVM_SRC:-$R}/src" && pwd)
# OmacVM.app's display panel (omacvm.monitor) is built in the VM from
# Omarchy's own: built here from each Omarchy shell in src/tests/omarchy-shell.
# A panel that does not build is a failure, not a file left unchecked.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bf=0; shells=0
for s in "$R"/src/tests/omarchy-shell/*/; do
  shells=$((shells + 1))
  n=$(basename "$s")
  if ! python3 -I "$SRC/app/guest/monitor-widget/build.py" "$T/$n/plugins/omacvm.monitor" \
      "$s/shell/plugins/panels/monitor" 2>/dev/null; then
    echo "FAIL omacvm.monitor does not build from $n"
    bf=1
  fi
done
built=$(find "$T" -path '*/plugins/omacvm.monitor/Panel.qml' | wc -l | tr -d ' ')
if [ "$shells" -eq 0 ] || [ "$built" -ne "$shells" ]; then
  echo "FAIL omacvm.monitor built from $built of $shells Omarchy shells"
  bf=1
fi
python3 -I - "$SRC" "$T" <<'PY'
import glob
import os
import re
import sys

src = sys.argv[1]
files = sorted(glob.glob(os.path.join(src, "*", "plugins", "*", "*.qml")))
files += sorted(glob.glob(os.path.join(sys.argv[2], "*", "plugins", "omacvm.monitor", "Panel.qml")))
# Any read of a property of the widget's own `bar` (not Color.bar.*). Calls
# into the bar (bar.run(...), bar.shell.summon(...)) sit in handlers that test
# `bar` first; they are not bindings and are left out.
read = re.compile(r"(?<![\w.])(?:root\.)?bar\.(?!shell\b|run\b)(\w+)\b(?!\s*\()")
# The read is the true branch of a test of `bar` itself: "bar ? <read>", the
# "?" on the same line or the next. Stricter than QML: `bar && bar.x` or a
# read inside a nested ?: also count as unguarded; write them as bar ? x : y.
guard = re.compile(r"\b(?:root\.)?bar\s*\?[^\n:]*$|\b(?:root\.)?bar\s*\n\s*\?[^\n:]*$")
fail = 0
reads = 0
for path in files:
    text = open(path, encoding="utf-8").read()
    rel = os.path.relpath(path, os.path.dirname(src)) if path.startswith(src) else \
        "omacvm.monitor built from " + path.split(os.sep)[-4]
    for m in read.finditer(text):
        reads += 1
        if guard.search(text[max(0, m.start() - 200):m.start()]):
            continue
        line = text.count("\n", 0, m.start()) + 1
        print(f"FAIL {rel}:{line}: bar.{m.group(1)} read with no guard (null until the bar sets it)")
        fail += 1
if not files:
    print("FAIL no plugin QML found under " + src)
    sys.exit(1)
print(f"{'ok  ' if not fail else 'FAIL'} {len(files)} plugin QML files, {reads} bar reads, {fail} unguarded")
sys.exit(1 if fail else 0)
PY
r=$?
exit $(( r || bf ))
