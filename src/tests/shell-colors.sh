#!/usr/bin/env bash
# Omarchy's shell colours on Qt 6.12 (#376), offline: guest/shell-colors.py on
# made-up Omarchy files (Qt 6.11 and 6.12 QtQuick types, files already patched,
# files it must leave alone) and the guest check's "shell colours" row on
# shell logs. With Qt's qml tool on PATH (qml6 or qml) the patched file is also
# run once: Omarchy's Color must win over QtQuick's.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
FIX="$R/src/guest/shell-colors.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/shell-colors.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
t() {  # want got name
  if [[ $2 == "$1" ]]; then echo "ok   $3"; else echo "FAIL $3: want '$1', got '$2'"; fail=1; fi
}
has() {  # file text name
  if grep -qF -- "$2" "$1"; then echo "ok   $3"; else echo "FAIL $3: '$2' not in ${1##*/}"; fail=1; fi
}
MARK="// omacvm #376: QtQuick's own Color (Qt 6.12) would hide Omarchy's"

# QtQuick's types: 6.11 has no Color, 6.12 exports one.
printf 'Module {\n  Component { name: "QQuickRectangle"; exports: ["QtQuick/Rectangle 2.0", "QtQuick/Rectangle 6.11"] }\n}\n' > "$T/qt611.qmltypes"
printf 'Module {\n  Component { name: "QQuickRectangle"; exports: ["QtQuick/Rectangle 2.0"] }\n  Component {\n    name: "QQuickColor"\n    exports: ["QtQuick/Color 6.12"]\n    isSingleton: true\n  }\n}\n' > "$T/qt612.qmltypes"

shell() {  # a made-up Omarchy shell and plugin clones under $T/s
  rm -rf "$T/s"; mkdir -p "$T/s/shell/Commons" "$T/s/shell/plugins/bar" "$T/s/plugins/me.bar"
  printf 'module qs.Commons\nsingleton Color 1.0 Color.qml\nsingleton Border 1.0 Border.qml\n' > "$T/s/shell/Commons/qmldir"
  # Omarchy's Color itself: imports QtQuick, uses no bare Color.
  printf 'pragma Singleton\nimport QtQuick\nQtObject {\n  id: root\n  property color foreground: "#cacccc"\n  readonly property QtObject bar: QtObject { property color text: root.foreground }\n}\n' > "$T/s/shell/Commons/Color.qml"
  # Commons' own files reach Color by the folder (no qs.Commons import).
  printf 'pragma Singleton\nimport QtQuick\nQtObject {\n  function value(k) { return Color.shellValues[k] }\n}\n' > "$T/s/shell/Commons/Border.qml"
  printf 'import Quickshell\nimport QtQuick\nimport QtQuick.Layouts\nimport qs.Commons\nItem {\n  property color fg: Color.bar.text\n  property color bg: Color . background\n}\n' > "$T/s/shell/plugins/bar/Bar.qml"
  printf 'import QtQuick\nItem { property int size: 3 }\n' > "$T/s/shell/plugins/bar/NoColor.qml"
  printf 'import QtQuick 6.11\nimport qs.Commons\nItem { property color fg: Color.foreground }\n' > "$T/s/shell/plugins/bar/Versioned.qml"
  printf 'import QtQuick\nimport qs.Commons as C\nItem { property color fg: C.Color.foreground }\n' > "$T/s/shell/plugins/bar/Qualified.qml"
  printf 'import QtQuick\nimport qs.Commons\nItem { property color a: Color.lighter(Color.foreground, 1.2) }\n' > "$T/s/shell/plugins/bar/QtColor.qml"
  printf 'import QtQuick\nItem { property color fg: myColor.text; property var c: theme.Color.x }\n' > "$T/s/shell/plugins/bar/OtherName.qml"
  printf 'import QtQuick\nimport qs.Commons\nItem { property color fg: Color.bar.text }\n' > "$T/s/plugins/me.bar/Bar.qml"
  cp "$T/s/plugins/me.bar/Bar.qml" "$T/s/plugins/me.bar/Bar.qml.before-notchbar"
  printf 'Color.bar.text\nimport QtQuick\n' > "$T/s/plugins/me.bar/notes.txt"
  # Omanotch's backup of a copy (a dot folder, no plugin for Omarchy): left as it is.
  mkdir -p "$T/s/plugins/.me.bar.before-3.1.13"; cp "$T/s/plugins/me.bar/Bar.qml" "$T/s/plugins/.me.bar.before-3.1.13/Bar.qml"
  chmod 640 "$T/s/shell/plugins/bar/Bar.qml"
}
run() { python3 "$FIX" "$@" "$T/s/shell" "$T/s/plugins"; }
patched() { grep -rlF -- "$MARK" "$T/s" | sed "s|$T/s/||" | sort | tr '\n' ' '; }

# --- Qt 6.12: the files that use Omarchy's bare Color get QtQuick 6.11 ---
shell
t "qtquick-color yes, patched 0, to patch 4, to restore 0" "$(run --qmltypes "$T/qt612.qmltypes" --status)" "6.12 status: 4 to patch"
t "" "$(patched)" "status writes nothing"
t "patched 4 files (QtQuick 6.11)" "$(run --qmltypes "$T/qt612.qmltypes")" "6.12: patched 4 files"
t "plugins/me.bar/Bar.qml plugins/me.bar/Bar.qml.before-notchbar shell/Commons/Border.qml shell/plugins/bar/Bar.qml " \
  "$(patched)" "6.12: Bar, the bar clone, its Omanotch copy, Commons' Border"
has "$T/s/shell/plugins/bar/Bar.qml" "import QtQuick 6.11 $MARK" "the import line carries the version and the mark"
has "$T/s/shell/plugins/bar/Bar.qml" "import QtQuick.Layouts" "QtQuick.Layouts stays as it was"
t "1" "$(grep -c '^import QtQuick' "$T/s/shell/Commons/Border.qml")" "one QtQuick import in Border.qml"
t "640" "$(stat -c %a "$T/s/shell/plugins/bar/Bar.qml" 2>/dev/null || stat -f %Lp "$T/s/shell/plugins/bar/Bar.qml")" "the file's mode is kept"
t "0 0 0 0 0 0" "$(for f in Commons/Color.qml plugins/bar/NoColor.qml plugins/bar/Versioned.qml plugins/bar/Qualified.qml plugins/bar/QtColor.qml plugins/bar/OtherName.qml; do grep -cF "$MARK" "$T/s/shell/$f"; done | tr '\n' ' ' | sed 's/ $//')" \
  "left alone: Color.qml, no Color, already versioned, qualified, QtQuick's Color, other names"
t "0" "$(grep -cF "$MARK" "$T/s/plugins/me.bar/notes.txt")" "not a QML file: left alone"
t "0" "$(grep -cF "$MARK" "$T/s/plugins/.me.bar.before-3.1.13/Bar.qml")" "a dot folder (Omanotch's backup of a copy): left alone"
t "nothing to do (QtQuick 6.11 already where needed)" "$(run --qmltypes "$T/qt612.qmltypes")" "6.12 again: nothing to do (idempotent)"
t "qtquick-color yes, patched 4, to patch 0, to restore 0" "$(run --qmltypes "$T/qt612.qmltypes" --status)" "6.12 status after: 4 patched"

# --- An older pin is brought to the current one (QtQuick 6.13 would still be 6.11) ---
sed -i.bak "s|^import QtQuick 6.11 $MARK|import QtQuick 6.10 $MARK|" "$T/s/shell/plugins/bar/Bar.qml" && rm -f "$T/s/shell/plugins/bar/Bar.qml.bak"
t "patched 1 file (QtQuick 6.11)" "$(run --qmltypes "$T/qt612.qmltypes")" "an older pin is brought to 6.11"

# --- Omarchy's file changed (no longer matches): the fix drops away by itself ---
printf 'import QtQuick\nimport qs.Commons as Commons\nItem { property color fg: Commons.Color.bar.text }\n' > "$T/s/shell/plugins/bar/Bar.qml"
t "nothing to do (QtQuick 6.11 already where needed)" "$(run --qmltypes "$T/qt612.qmltypes")" "a new Omarchy file without bare Color: nothing to do"
t "0" "$(grep -cF "$MARK" "$T/s/shell/plugins/bar/Bar.qml")" "  and it stays as Omarchy shipped it"

# --- Omarchy's own files (omarchy-shell/README.md): omarchy-mac's use the bare
#     Color; upstream's from October 2026 say Commons.Color (omacom/omarchy#14553)
#     and stay as they are. A clone of an older bar, as Omanotch made it, still
#     gets the import (omacom/omarchy#14672) ---
O=$R/src/tests/omarchy-shell
rm -rf "$T/s"; mkdir -p "$T/s/plugins/me.bar"
cp -R "$O/omarchy-a06ec133/shell" "$T/s/shell"
cp "$O/omarchy-mac-ba546a61/shell/plugins/bar/Bar.qml" "$T/s/plugins/me.bar/Bar.qml"
cp "$T/s/plugins/me.bar/Bar.qml" "$T/s/plugins/me.bar/Bar.qml.before-notchbar"
python3 "$R/src/omanotch/guest/bar/apply-patch.py" "$T/s/plugins/me.bar/Bar.qml" >/dev/null
t "patched 2 files (QtQuick 6.11)" "$(run --qmltypes "$T/qt612.qmltypes")" "upstream's shell and an older bar clone: the clone"
t "plugins/me.bar/Bar.qml plugins/me.bar/Bar.qml.before-notchbar " "$(patched)" "  the clone and its Omanotch copy, nothing of upstream's"
t "" "$(diff -r "$O/omarchy-a06ec133/shell" "$T/s/shell")" "  upstream's files as they came"
t "already patched (v$(sed -n 's/^VERSION = //p' "$R/src/omanotch/guest/bar/apply-patch.py"))" \
  "$(python3 "$R/src/omanotch/guest/bar/apply-patch.py" "$T/s/plugins/me.bar/Bar.qml")" "  Omanotch's patch still sees itself in the clone"
rm -rf "$T/s/shell"; cp -R "$O/omarchy-mac-ba546a61/shell" "$T/s/shell"
t "patched 6 files (QtQuick 6.11)" "$(python3 "$FIX" --qmltypes "$T/qt612.qmltypes" "$T/s/shell")" "omarchy-mac's shell: its files with the bare Color (Ui's ToggleSwitch and PanelToolTip, the tray too)"
has "$T/s/shell/plugins/bar/Bar.qml" "import QtQuick 6.11 $MARK" "  its bar among them"

# --- Qt 6.11 (no QtQuick Color): nothing on stock files, marked lines go back ---
shell
t "nothing to do (Qt has no QtQuick Color)" "$(run --qmltypes "$T/qt611.qmltypes")" "6.11: stock files untouched"
t "" "$(patched)" "6.11: no file carries the mark"
run --qmltypes "$T/qt612.qmltypes" >/dev/null
t "restored 4 files" "$(run --qmltypes "$T/qt611.qmltypes")" "back on Qt 6.11: the 4 files restored"
t "" "$(patched)" "  no mark left"
t "1" "$(grep -cx 'import QtQuick' "$T/s/shell/plugins/bar/Bar.qml")" "  Bar.qml has the plain import again"
t "qtquick-color no, patched 0, to patch 0, to restore 0" "$(run --qmltypes "$T/qt611.qmltypes" --status)" "6.11 status"

# --- --revert on Qt 6.12 ---
run --qmltypes "$T/qt612.qmltypes" >/dev/null
t "restored 4 files" "$(run --qmltypes "$T/qt612.qmltypes" --revert)" "--revert on 6.12 restores"
t "" "$(patched)" "  no mark left"

# --- QtQuick's types not found: nothing changes ---
t "nothing to do (QtQuick's types not found: $T/none.qmltypes)" "$(run --qmltypes "$T/none.qmltypes")" "no QtQuick types: nothing to do"
t "" "$(patched)" "  nothing written"
t "qtquick-color unknown, patched 0, to patch 0, to restore 0" "$(run --qmltypes "$T/none.qmltypes" --status)" "  status says unknown"

# --- A file it may not write: the others still get it, exit 1 ---
shell
chmod 555 "$T/s/shell/Commons"
out=$(python3 "$FIX" --qmltypes "$T/qt612.qmltypes" "$T/s/shell" "$T/s/plugins" 2>"$T/err"); rc=$?
chmod 755 "$T/s/shell/Commons"
if (( EUID != 0 )); then
  t "1 patched 3 files (QtQuick 6.11)" "$rc $out" "a folder it may not write: exit 1, the rest patched"
  has "$T/err" "Border.qml" "  and it names the file"
fi

# --- Real QML, if Qt's tool is here: Omarchy's Color wins after the patch ---
QML=$(command -v qml6 || command -v qml || true)
if [[ -n $QML ]]; then
  rm -rf "$T/q"; mkdir -p "$T/q/Commons"
  printf 'module Commons\nsingleton Color 1.0 Color.qml\n' > "$T/q/Commons/qmldir"
  printf 'pragma Singleton\nimport QtQuick\nQtObject { property color foreground: "red" }\n' > "$T/q/Commons/Color.qml"
  printf 'import QtQuick\nimport Commons\nQtObject { Component.onCompleted: { console.warn("RESULT " + Color.foreground); Qt.quit() } }\n' > "$T/q/main.qml"
  # Before the patch, on Qt 6.12, QtQuick's Color (no foreground); after it, Omarchy's.
  before=$(QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen "$QML" -I "$T/q" "$T/q/main.qml" 2>&1 | sed -n 's/.*RESULT //p' | head -1)
  echo "     (before the patch: '$before')"
  python3 "$FIX" "$T/q/main.qml" >/dev/null
  got=$(QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen "$QML" -I "$T/q" "$T/q/main.qml" 2>&1 | sed -n 's/.*RESULT //p' | head -1)
  t "#ff0000" "$got" "real QML ($QML): Omarchy's Color.foreground after the patch"
else
  echo "skip real QML (no qml6 or qml here)"
fi

# --- The guest check's row ---
line() { printf '%s|%s|%s\n' "$1" "$3" "$4"; }
ok() { line ok ok "$1" "${2:-}"; }
bad() { line fail FAIL "$1" "${2:-}"; }
warn() { line warn WARN "$1" "${2:-}"; }
skip() { line skip skip "$1" "${2:-}"; }
eval "$(grep '^COLOR_ERRORS=' "$R/src/guest/check.sh")"
for f in shell_log shell_colors; do
  fn=$(awk -v f="$f" '$0 == f "() {" {on = 1} on {print} on && /^}$/ {exit}' "$R/src/guest/check.sh")
  [[ -n $fn ]] || { echo "FAIL check.sh has no $f"; exit 1; }
  eval "$fn"
done
# From a shell on Qt 6.12 before the fix (#376), and lines that are no colour error.
cat > "$T/broken.log" <<'LOG'
2026-10-13 08:33:11.255  INFO: Launching config: "/usr/share/omarchy/shell/shell.qml"
2026-10-13 08:33:11.531  WARN scene: @plugins/bar/Bar.qml[72:-1]: TypeError: Cannot read property 'active' of undefined
2026-10-13 08:33:11.531  WARN scene: @plugins/bar/Bar.qml[66:3]: Unable to assign [undefined] to QColor
2026-10-13 08:33:11.531  WARN scene: @plugins/bar/Bar.qml[1124:-1]: TypeError: Cannot read property 'border' of undefined
2026-10-13 08:33:11.807  WARN scene: @Commons/Border.qml[25:-1]: TypeError: Cannot read property 'polkit.border-alpha' of undefined
2026-10-13 08:33:11.839  WARN scene: file:///usr/share/omarchy/shell/plugins/menu/Menu.qml[94:-1]: TypeError: Cannot read property 'selectedBorder' of undefined
2026-10-13 08:33:12.089  WARN qt.qpa.services: Failed to register with host portal
2026-10-13 08:33:12.100  WARN scene: file:///home/me/.config/omarchy/plugins/x/W.qml[3:-1]: TypeError: Cannot read property 'length' of undefined
LOG
printf '2026-10-13 08:41:20.100  INFO: Launching config: "/usr/share/omarchy/shell/shell.qml"\n2026-10-13 08:41:27.971  WARN qt.qpa.services: Failed to register with host portal\n' > "$T/clean.log"
QT_QUICK_TYPES=$T/qt612.qmltypes
row() { shell_colors "$@" | cut -d'|' -f1; }
t "ok" "$(row "$T/clean.log" "")" "check: a clean log is ok"
t "ok|shell colours|no colour errors since the shell started" "$(shell_colors "$T/clean.log" "")" "  with its words"
t "fail" "$(row "$T/broken.log" "")" "check: errors on Qt 6.12 without OmacVM's fix in the VM: FAIL"
has <(shell_colors "$T/broken.log" "") "5 colour errors since the shell started" "  counts the 5 colour errors (not the portal or a plugin's length)"
has <(shell_colors "$T/broken.log" "") "omacvm apply (OmacVM.app: Update VM)" "  and says how to fix it"
t "fail" "$(row "$T/broken.log" "qtquick-color yes, patched 0, to patch 54, to restore 0")" "check: errors, files to patch: FAIL"
has <(shell_colors "$T/broken.log" "qtquick-color yes, patched 0, to patch 54, to restore 0") "omacvm apply" "  apply"
has <(shell_colors "$T/broken.log" "qtquick-color yes, patched 54, to patch 0, to restore 0") "omarchy restart shell" \
  "check: errors though every file is fixed: the shell started before the fix, restart it"
t "warn" "$(row "$T/broken.log" "qtquick-color no, patched 0, to patch 0, to restore 0")" "check: colour errors on Qt 6.11: WARN (not #376)"
QT_QUICK_TYPES=$T/qt611.qmltypes
t "warn" "$(row "$T/broken.log" "")" "check: errors, no fix in the VM, Qt without QtQuick Color: WARN"
# Which log: the live quickshell's, by its pid.
RUN=$T/run; mkdir -p "$RUN/quickshell/by-id/a" "$RUN/quickshell/by-id/b" "$RUN/quickshell/by-pid"
cp "$T/broken.log" "$RUN/quickshell/by-id/a/log.log"; cp "$T/clean.log" "$RUN/quickshell/by-id/b/log.log"
ln -s "$RUN/quickshell/by-id/a" "$RUN/quickshell/by-pid/999999"
if [[ -d /proc/$$ ]]; then
  t "" "$(shell_log)" "check: no live shell, no log"
  ln -s "$RUN/quickshell/by-id/b" "$RUN/quickshell/by-pid/$$"
  t "$RUN/quickshell/by-pid/$$/log.log" "$(shell_log)" "check: the live shell's log"
else
  echo "skip shell_log (no /proc here)"
fi
# install.sh puts the script and its pacman hook in place for every route.
has "$R/src/guest/install.sh" 'install -Dm755 "$R/guest/shell-colors.py" /usr/local/lib/omacvm/shell-colors.py' "install.sh installs shell-colors.py"
has "$R/src/guest/install.sh" "Target = usr/lib/qt6/qml/QtQuick/plugins.qmltypes" "  its hook runs after Qt updates"
has "$R/src/guest/install.sh" "Target = usr/share/omarchy/shell/*" "  and after Omarchy's shell changed"

echo "shell-colors: $([[ $fail == 0 ]] && echo all ok || echo FAILED)"
exit $fail
