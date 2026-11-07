#!/usr/bin/env bash
# Omanotch's wallpaper patch (src/omanotch/guest/background/apply-patch.py):
# the wallpaper is laid out once over the NOTCH strip and the built-in display,
# so with the bar hidden the strip shows the image's rows right above the
# display's. Offline: the patch on Omarchy's own Background.qml, as
# omarchy-mac has it and as upstream Omarchy has it from October 2026
# (omarchy-shell/README.md), then its pairing helpers and canvas run in
# JavaScript (node, or macOS's osascript) on sample layouts.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
patch="$R/src/omanotch/guest/background/apply-patch.py"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

for fixture in "$R"/src/tests/omarchy-shell/*/shell/plugins/background/Background.qml; do
name=${fixture#"$R"/src/tests/omarchy-shell/}; name=${name%%/*}
echo "== $name"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# The patch applies to Omarchy's file, once.
cp "$fixture" "$out/Background.qml"
cp "$fixture" "$out/Background.qml.before-notchbar"
r=$(python3 "$patch" "$out/Background.qml") && [[ $r == patched* ]] && ok "patch applies: $r" || bad "patch: $r"
r=$(python3 "$patch" "$out/Background.qml") && [[ $r == already* ]] && ok "second run: $r" || bad "second run: $r"

# An older version is replaced from the clean backup.
sed 's|background patch v[0-9]*|background patch v1|' "$out/Background.qml" > "$out/old.qml"
cp "$out/old.qml" "$out/Background.qml"
r=$(python3 "$patch" "$out/Background.qml") && [[ $r == *"older patch"* ]] &&
  cmp -s "$out/Background.qml" <(cp "$fixture" "$out/clean.qml" && python3 "$patch" "$out/clean.qml" >/dev/null && cat "$out/clean.qml") &&
  ok "an older patch is replaced" || bad "upgrade from an older patch: $r"

# The version line alone is not a patch (#354): every piece must be there.
v=$(sed -n 's/^VERSION = //p' "$patch")
cp "$fixture" "$out/clean.qml" && python3 "$patch" "$out/clean.qml" >/dev/null
line="// omarchy-notch-bar background patch v$v"
printf '%s\n' "$line" > "$out/Background.qml"
cp "$fixture" "$out/Background.qml.before-notchbar"
r=$(python3 "$patch" "$out/Background.qml") && [[ $r == *"replacing an incomplete or older patch"* ]] &&
  cmp -s "$out/Background.qml" "$out/clean.qml" && ok "version line alone, clean backup: the whole patch" ||
  bad "version line alone with a clean backup: $r"
printf '%s\n' "$line" > "$out/Background.qml"; rm -f "$out/Background.qml.before-notchbar"
if r=$(python3 "$patch" "$out/Background.qml" 2>&1); then bad "version line alone, no backup: went on ($r)"
elif [[ $(cat "$out/Background.qml") == "$line" && $r == *re-clone* ]]; then ok "version line alone, no backup: stops, file unchanged"
else bad "version line alone, no backup: $r / $(head -c 200 "$out/Background.qml")"; fi
cp "$fixture" "$out/Background.qml.before-notchbar"
cp "$out/clean.qml" "$out/Background.qml"
r=$(python3 "$patch" "$out/Background.qml") && [[ $r == already* ]] && cmp -s "$out/Background.qml" "$out/clean.qml" &&
  ok "the whole patch stays as it is: $r" || bad "the whole patch again: $r"
# Each piece removed from a whole patch: patched again from the clean backup.
r=$(python3 - "$patch" "$out/clean.qml" "$fixture" "$out/Background.qml" <<'PY'
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("bg", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
full, stock = open(sys.argv[2]).read(), open(sys.argv[3]).read()
for piece in m.PIECES:
    # A tuple: one of these lines, by Omarchy's form.
    found = [q for q in (piece if isinstance(piece, tuple) else (piece,)) if q in full]
    if not found or any(q in stock for q in found):
        print("piece not in the patch, or already in Omarchy's file: %r" % (piece,)); sys.exit(1)
    cut = full
    for q in found:
        cut = cut.replace(q, "")
    open(sys.argv[4], "w").write(cut)
    out = subprocess.run([sys.executable, sys.argv[1], sys.argv[4]], capture_output=True, text=True)
    if out.returncode or "incomplete or older" not in out.stdout or open(sys.argv[4]).read() != full:
        print("not patched again without %r: %s %s" % (piece, out.stdout, out.stderr)); sys.exit(1)
print(len(m.PIECES))
PY
) && ok "each of the $r pieces missing: patched again from the backup" || bad "$r"

# The wallpaper is decoded at the canvas's size (strip and display together):
# by the patch on the older file, by Omarchy itself on the newer one.
if grep -q "readonly property int decodeWidth:" "$fixture"; then
  [[ $(grep -c "Math.ceil(notchCanvas.width \* screen.devicePixelRatio)\|Math.ceil(notchCanvas.height \* screen.devicePixelRatio)" "$out/clean.qml") == 2 &&
     $(grep -c "sourceSize: panel.notchImageSize" "$out/clean.qml") == 0 ]] &&
    ok "decoded at the canvas's size (Omarchy's own decode size)" || bad "decode size on the newer Background.qml"
else
  [[ $(grep -c "sourceSize: panel.notchImageSize" "$out/clean.qml") == 3 ]] &&
    ok "decoded at the canvas's size (the patch's own)" || bad "decode size on the older Background.qml"
fi

# The helpers and the canvas, as JavaScript.
qml="$out/Background.qml"
helpers=$(awk '/--- omarchy-notch-bar ---/ {on = 1} on {print} /--- end omarchy-notch-bar ---/ {exit}' "$qml")
canvas_y=$(awk '/id: notchCanvas/ {on = 1} on && /^ *y: / {sub(/^ *y: /, ""); print; exit}' "$qml")
canvas_h=$(awk '/id: notchCanvas/ {on = 1} on && /^ *height: / {sub(/^ *height: /, ""); print; exit}' "$qml")
[[ -n $helpers && -n $canvas_y && -n $canvas_h ]] || { bad "helpers or canvas not found in the patched file"; exit 1; }

cat > "$out/t.js" <<JS
var Quickshell = { screens: [] }
var root = {}
$helpers
root.notchIsStrip = notchIsStrip
root.notchPeerOf = notchPeerOf
var lines = [], failed = false
function S(name, x, y, w, h) { return { name: name, x: x, y: y, width: w, height: h } }
function peerName(s) { var p = notchPeerOf(s); return p ? p.name : "-" }
// Canvas of an output (logical px, relative to the output's top edge).
function canvas(s) {
  var peer = root.notchPeerOf(s), strip = root.notchIsStrip(s)
  var parent = { width: s.width, height: s.height }
  return { y: ($canvas_y), h: ($canvas_h), w: parent.width }
}
// Image row (0..1 of the image's height) that PreserveAspectCrop puts at
// canvas row cy.
function imageRow(c, iw, ih, cy) {
  var k = Math.max(c.w / iw, c.h / ih)
  return (cy - (c.h - ih * k) / 2) / k / ih
}
function check(name, screens, want) {
  Quickshell.screens = screens
  var got = screens.map(function (s) { return s.name + ">" + peerName(s) }).join(" ")
  if (got !== want) { failed = true; lines.push("FAIL " + name + ": want '" + want + "', got '" + got + "'"); return }
  // Strip and display: one picture, the strip's bottom row runs into the
  // display's top row, whatever the image's shape.
  var strip = screens.filter(function (s) { return notchIsStrip(s) })[0]
  var disp = strip && notchPeerOf(strip)
  if (disp) {
    var cs = canvas(strip), cd = canvas(disp)
    var sizes = [[6016, 3384], [3840, 2160], [1000, 1500], [2000, 2000]]
    for (var i = 0; i < sizes.length; i++) {
      var iw = sizes[i][0], ih = sizes[i][1]
      var a = imageRow(cs, iw, ih, strip.height - cs.y), b = imageRow(cd, iw, ih, 0 - cd.y)
      var top = imageRow(cs, iw, ih, 0 - cs.y)
      if (Math.abs(a - b) > 1e-9 || cs.w !== cd.w || cs.h !== cd.h || top < -1e-9) {
        failed = true
        lines.push("FAIL " + name + ": " + iw + "x" + ih + " strip ends at row " + a + ", display starts at " + b)
        return
      }
    }
  }
  lines.push("ok   " + name + ": " + got)
}
var V1 = S("Virtual-1", 0, 0, 1470, 923)
check("Air, OmacVM.app: NOTCH right above Virtual-1",
      [V1, S("NOTCH", 0, -33, 1470, 33)], "Virtual-1>NOTCH NOTCH>Virtual-1")
check("another VM type: NOTCH over Virtual-1's top edge",
      [V1, S("NOTCH", 0, 0, 1470, 33)], "Virtual-1>NOTCH NOTCH>Virtual-1")
check("16\" with a 6K above (user's layout), NOTCH between them",
      [S("Virtual-2", 0, 0, 3008, 1692), S("Virtual-1", 492, 1735, 2056, 1286), S("NOTCH", 492, 1692, 2056, 43)],
      "Virtual-2>- Virtual-1>NOTCH NOTCH>Virtual-1")
check("fractional scale 1.6, strip rounded down",
      [S("Virtual-1", 0, 27, 2160, 1350), S("NOTCH", 0, 0, 2160, 26)], "Virtual-1>NOTCH NOTCH>Virtual-1")
check("fractional scale 1.6, strip rounded up",
      [S("Virtual-1", 0, 26, 2160, 1350), S("NOTCH", 0, 0, 2160, 27)], "Virtual-1>NOTCH NOTCH>Virtual-1")
check("external display above, NOTCH back on Virtual-1's top edge",
      [S("Virtual-2", 0, -923, 1470, 923), V1, S("NOTCH", 0, 0, 1470, 33)], "Virtual-2>- Virtual-1>NOTCH NOTCH>Virtual-1")
check("external display beside", [V1, S("Virtual-2", 1470, 0, 1470, 923), S("NOTCH", 0, -33, 1470, 33)],
      "Virtual-1>NOTCH Virtual-2>- NOTCH>Virtual-1")
check("no NOTCH (Mac without a notch): every output alone",
      [V1, S("Virtual-2", 1470, 0, 1920, 1080)], "Virtual-1>- Virtual-2>-")
check("NOTCH with a gap above the display: alone",
      [V1, S("NOTCH", 0, -60, 1470, 33)], "Virtual-1>- NOTCH>-")
check("NOTCH narrower than the display: alone",
      [V1, S("NOTCH", 0, -33, 1200, 33)], "Virtual-1>- NOTCH>-")
lines.push(failed ? "JSFAIL" : "JSOK")
lines.join("\\n")
JS

# A theme switch's reveal: the strip and the built-in display both take part,
# whichever output's new image is decoded first (an Omarchy theme switch
# showed the display's new picture only at the end of the reveal).
reveal=$(awk '/function maybeStartReveal\(\) \{/ {on = 1} on {print} on && /^      \}$/ {exit}' "$qml")
[[ -n $reveal ]] || { bad "maybeStartReveal not found in the patched file"; exit 1; }
cat > "$out/r.js" <<JS
var Image = { Ready: 1 }, Qt = { callLater: function (f) { f() } }
var lines = [], failed = false, root
function reset() {
  root = { incomingBackground: "next.jpg", revealProgress: 0, started: false,
           startReveal: function (p) { p.maskReady = true; if (!this.started) this.started = true } }
}
function Panel(name) {
  var p = { name: name, maskReady: false, incomingFrame: { status: 0 } }
  p.panel = p
  with (p) { p.maybeStartReveal = eval("(" + $(printf '%s' "$reveal" | sed 's/^ *function maybeStartReveal/function/' | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') + ")") }
  return p
}
function ready(p) { p.incomingFrame.status = Image.Ready; p.maybeStartReveal() }
function check(name, ok) { lines.push((ok ? "ok   " : "FAIL ") + name); if (!ok) failed = true }
var orders = [["NOTCH", "Virtual-1"], ["Virtual-1", "NOTCH"]]
for (var i = 0; i < orders.length; i++) {
  reset()
  var a = Panel(orders[i][0]), b = Panel(orders[i][1])
  ready(a)
  root.revealProgress = 0.3      // the reveal runs
  ready(b)
  check("reveal: " + b.name + " ready after " + a.name + " joins it", a.maskReady && b.maskReady)
}
reset()
var late = Panel("Virtual-1")
root.revealProgress = 1          // finished: the new picture shows anyway
ready(late)
check("reveal: an output ready after the end does not start it again", !late.maskReady && !root.started)
lines.push(failed ? "JSFAIL" : "JSOK")
lines.join("\\n")
JS

if command -v node >/dev/null; then
  res=$(node -p "$(cat "$out/t.js")" 2>&1)
  res2=$(node -p "$(cat "$out/r.js")" 2>&1)
elif command -v osascript >/dev/null; then
  res=$(osascript -l JavaScript "$out/t.js" 2>&1)
  res2=$(osascript -l JavaScript "$out/r.js" 2>&1)
else
  echo "SKIP: no node and no osascript for the JavaScript part"; res="JSOK"; res2="JSOK"
fi
echo "$res" | grep -v '^JS'
echo "$res2" | grep -v '^JS'
[[ $res == *JSOK* && $res2 == *JSOK* ]] || fail=1
rm -rf "$out"
done

echo "notch-wallpaper: $([[ $fail == 0 ]] && echo all ok || echo FAILED)"
exit $fail
