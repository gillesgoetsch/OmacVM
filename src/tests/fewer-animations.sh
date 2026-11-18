#!/bin/bash
# Fewer animations (feature fewer-animations, experimental): OmacVM's own
# Hyprland file that turns the border animations off, no VM needed.
# animations/guest/install.sh on, off and --status in a scratch home with a
# stand-in Omarchy 4 Lua config: the file and the line that requires it, in
# that order, the user's own lines kept byte for byte, a reload only when no
# loaded file changed, nothing at all without hyprland.lua, and the feature's
# line and tags (offered on Omarchy 4.0 and 4.5). Runs on macOS and Linux.
#   src/tests/fewer-animations.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-anim.XXXXXX"); trap 'rm -rf "$T"' EXIT
I=$R/src/animations/guest/install.sh
OURS=$R/src/animations/guest/omacvm_animations.lua

# Stand-ins: hyprctl (logs its call and the instance) and timeout (macOS has none).
mkdir -p "$T/bin" "$T/home/.config/hypr" "$T/run"
cat > "$T/bin/hyprctl" <<EOF
#!/bin/bash
echo "hyprctl \$* sig=\$HYPRLAND_INSTANCE_SIGNATURE run=\$XDG_RUNTIME_DIR" >> "$T/calls"
EOF
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/bin/timeout"
chmod +x "$T/bin/hyprctl" "$T/bin/timeout"
HY=$T/home/.config/hypr
B=$HY/hyprland.lua
FILE=$HY/omacvm_animations.lua
LINE='require("hypr.omacvm_animations")'
# The user's hyprland.lua as Omarchy 4 makes it, plus OmacVM's other lines and one of the user's own.
printf '%s\n' '-- Omarchy' 'require("hypr.looknfeel")' '-- OmacVM.app: the display follows the Mac window.' \
  'require("hypr.omacvm_app")' 'hl.config({ general = { gaps_in = 2 } })   -- mine' > "$B"
cp "$B" "$T/user.lua"
run() {   # ACTION
  : > "$T/calls"
  PATH="$T/bin:$PATH" OMACVM_ANIM_HOME=$T/home OMACVM_ANIM_RUN=$T/run "$I" "$(id -un)" "$1"
}
calls() { wc -l < "$T/calls" | tr -d ' '; }

# ---- the file says what it does: border and borderangle off, nothing else ----
expect "the file: exactly the two border leaves off" \
  'hl.animation({ leaf = "border", enabled = false }) hl.animation({ leaf = "borderangle", enabled = false })' \
  "$(grep -v '^--' "$OURS" | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')"
expect "the file: no blur, shadow or whole animations switch" 0 \
  "$(grep -v '^--' "$OURS" | grep -cE 'blur|shadow|animations *=')"

# ---- Omarchy 4 (4.0 and 4.5 alike), no session yet (a build) ----
expect "status off at first" off "$(run --status)"
out=$(run on); rc=$?
expect "on: exit 0" 0 "$rc"
expect "on: says so" "fewer animations: on (borders change colour at once)" "$out"
expect "on: OmacVM's file, byte for byte" same "$(cmp -s "$FILE" "$OURS" && echo same)"
expect "on: the user's lines first, byte for byte, then the mark and the line" same \
  "$(head -n 5 "$B" | cmp -s - "$T/user.lua" && [[ $(sed -n 7p "$B") == "$LINE" && $(wc -l < "$B" | tr -d ' ') == 7 ]] && echo same)"
expect "on without a session: no reload" 0 "$(calls)"
expect "status on" on "$(run --status)"

# ---- with a session ----
mkdir -p "$T/run/hypr/abc_1"
expect "on again: nothing to do" "fewer animations: on" "$(run on)"
expect "... nothing written, no reload, one line" "0 1" "$(calls) $(grep -cxF "$LINE" "$B")"
# A changed copy (an older OmacVM's): put back; Hyprland reloads on that write by itself.
echo '-- older' > "$FILE"
expect "a changed file: status partial" partial "$(run --status)"
out=$(run on)
expect "a changed file: written again, no extra reload" "fewer animations: on (borders change colour at once) 0" "$out $(calls)"
# The file gone but the line there (Hyprland did not load it): written, and one reload.
rm -f "$FILE"
expect "the line without the file: partial" partial "$(run --status)"
run on > /dev/null
expect "the line without the file: written, one reload in the session's Hyprland" \
  "same hyprctl reload sig=abc_1 run=$T/run" "$(cmp -s "$FILE" "$OURS" && echo same) $(cat "$T/calls")"

# ---- off: the line, then the file; the user's lines kept ----
out=$(run off)
expect "off: says so" "fewer animations: off (Omarchy's border animation back)" "$out"
expect "off: hyprland.lua as the user had it, byte for byte" same "$(cmp -s "$B" "$T/user.lua" && echo same)"
expect "off: the file gone" gone "$([[ -e $FILE ]] || echo gone)"
expect "off: no extra reload (the write to hyprland.lua reloads)" 0 "$(calls)"
expect "off again: silent, nothing done" "0 0 same" "$(run off | wc -l | tr -d ' ') $(calls) $(cmp -s "$B" "$T/user.lua" && echo same)"
expect "status off after off" off "$(run --status)"
# The file left without the line: off removes it.
cp "$OURS" "$FILE"
expect "the file without the line: partial" partial "$(run --status)"
run off > /dev/null
expect "... off removes it" gone "$([[ -e $FILE ]] || echo gone)"
# A link at the file (the user's): removed, never followed.
echo keep > "$T/target"; ln -s "$T/target" "$FILE"
run off > /dev/null
expect "off with a link there: the link goes, its target stays" "gone keep" "$([[ -e $FILE || -L $FILE ]] || echo gone) $(cat "$T/target")"
# Omarchy's own no-animations toggle is Omarchy's: never written or removed.
mkdir -p "$T/home/.local/state/omarchy/toggles/hypr"; echo '-- Omarchy' > "$T/home/.local/state/omarchy/toggles/hypr/no-animations.lua"
run on > /dev/null; run off > /dev/null
expect "Omarchy's toggle untouched by on and off" "-- Omarchy" "$(cat "$T/home/.local/state/omarchy/toggles/hypr/no-animations.lua")"

# ---- no Lua config: nothing written ----
mv "$B" "$T/away.lua"
expect "no hyprland.lua: status none" none "$(run --status)"
out=$(run on); rc=$?
expect "no hyprland.lua: on exits 3" 3 "$rc"
expect "... and says why" "OmacVM: it needs Omarchy's Lua config (~/.config/hypr/hyprland.lua, Omarchy 4): nothing done" "$out"
expect "... nothing written" "none none" "$([[ -e $FILE ]] && echo there || echo none) $([[ -e $B ]] && echo there || echo none)"
expect "no hyprland.lua: off exits 0" 0 "$(run off > /dev/null; echo $?)"
mv "$T/away.lua" "$B"
expect "usage: exit 2" 2 "$(run bogus 2> /dev/null; echo $?)"

# ---- the feature: off by default, experimental, Omarchy 4.0 and 4.5 ----
source "$R/src/lib/features.sh"
features_load
i=$(feature_index fewer-animations)
expect "features.tsv: off by default" off "$(feature_default "$i")"
expect "features.tsv: experimental" yes "$(feature_has_tag "$i" experimental && echo yes)"
expect "features.tsv: not only Omarchy 4.5" no "$(feature_has_tag "$i" omarchy-45 && echo yes || echo no)"
expect "features.tsv: the VM's side only" vm "${FSIDES[$i]}"
mkdir -p "$T/vm40" "$T/vm45"; echo "4.0.3rc4 omarchy-mac rc" > "$T/vm40/omarchy"; echo "4.5.0 aarch64 stable" > "$T/vm45/omarchy"
FEATURES_VM_DIR=$T/vm40
expect "a 4.0 VM: available" yes "$(feature_available "$i" && echo yes)"
FEATURES_VM_DIR=$T/vm45
expect "a 4.5 VM: available" yes "$(feature_available "$i" && echo yes)"
FEATURES_VM_DIR=""
expect "the release part: animations/**" "fewer-animations	animations/**" "$(grep '^fewer-animations	' "$R/src/release/parts.tsv")"
# No record fixing from Omarchy's toggle any more: the switch is OmacVM's own.
expect "no probe line for Omarchy's toggle" 0 "$(grep -c 'OMACVM_REAL_fewer_animations' "$R/src/lib/vm.sh" "$R/src/lib/features.sh" | awk -F: '{ s += $2 } END { print s }')"

(( fail == 0 )) && echo "all passed" || echo "FAILED"
exit "$fail"
