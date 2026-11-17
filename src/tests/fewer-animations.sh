#!/bin/bash
# Fewer animations (feature fewer-animations, experimental): Omarchy 4.5's own
# no-animations toggle, no VM needed. animations/guest/install.sh on, off and
# --status in a scratch home with a stand-in Omarchy 4.5 (and 4.0, which has no
# such toggle), Hyprland's reload only with a session, the feature's line and
# tags, its availability on an Omarchy below 4.5, and the record following a
# toggle switched in Omarchy's menu (features_real). Runs on macOS and Linux.
#   src/tests/fewer-animations.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-anim.XXXXXX"); trap 'rm -rf "$T"' EXIT
I=$R/src/animations/guest/install.sh

# Stand-ins: hyprctl (logs its call and the instance) and timeout (macOS has none).
mkdir -p "$T/bin" "$T/o45/default/hypr/toggles" "$T/o40/default/hypr/toggles" "$T/home" "$T/run"
cat > "$T/bin/hyprctl" <<EOF
#!/bin/bash
echo "hyprctl \$* sig=\$HYPRLAND_INSTANCE_SIGNATURE run=\$XDG_RUNTIME_DIR" >> "$T/calls"
EOF
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/bin/timeout"
chmod +x "$T/bin/hyprctl" "$T/bin/timeout"
printf '%s\n' '-- Draw nothing just for show (Omarchy 4.5)' 'hl.config({ animations = { enabled = false } })' > "$T/o45/default/hypr/toggles/no-animations.lua"
: > "$T/o40/default/hypr/toggles/window-no-gaps.lua"
FLAG=$T/home/.local/state/omarchy/toggles/hypr/no-animations.lua
run() {   # OMARCHY ACTION
  : > "$T/calls"
  PATH="$T/bin:$PATH" OMACVM_ANIM_OMARCHY=$T/$1 OMACVM_ANIM_HOME=$T/home OMACVM_ANIM_RUN=$T/run "$I" "$(id -un)" "$2"
}
calls() { wc -l < "$T/calls" | tr -d ' '; }

# ---- Omarchy 4.5, no session yet (a build) ----
expect "4.5: status off at first" off "$(run o45 --status)"
out=$(run o45 on); rc=$?
expect "4.5 on: exit 0" 0 "$rc"
expect "4.5 on: says so" "fewer animations: on (Omarchy's animations, blur and shadows off)" "$out"
expect "4.5 on: Omarchy's file, byte for byte" same "$(cmp -s "$FLAG" "$T/o45/default/hypr/toggles/no-animations.lua" && echo same)"
expect "4.5 on without a session: no reload" 0 "$(calls)"
expect "4.5: status on" on "$(run o45 --status)"

# ---- with a session: Hyprland reads its config again ----
mkdir -p "$T/run/hypr/abc_1"
expect "4.5 on again: nothing to do" "fewer animations: on" "$(run o45 on)"
expect "... and no reload" 0 "$(calls)"
out=$(run o45 off)
expect "4.5 off: says so" "fewer animations: off (Omarchy's animations back)" "$out"
expect "4.5 off: the toggle gone" gone "$([[ -e $FLAG ]] || echo gone)"
expect "4.5 off: one reload in the session's Hyprland" "hyprctl reload sig=abc_1 run=$T/run" "$(cat "$T/calls")"
expect "4.5 off again: silent, nothing done" "0 0" "$(run o45 off | wc -l | tr -d ' ') $(calls)"
run o45 on > /dev/null
expect "4.5 on with a session: one reload" 1 "$(calls)"

# ---- switched in Omarchy's menu: a copy of another Omarchy release counts ----
printf -- '-- an older copy\n' > "$FLAG"
expect "the user's own copy: on, kept as it is" "on -- an older copy" "$(run o45 on > /dev/null; run o45 --status) $(cat "$FLAG")"
run o45 off > /dev/null
expect "off takes any copy (Omarchy's toggle off does too)" gone "$([[ -e $FLAG ]] || echo gone)"
# A link at the toggle (the user's): removed, never followed.
echo keep > "$T/target"; mkdir -p "${FLAG%/*}"; ln -s "$T/target" "$FLAG"
run o45 off > /dev/null
expect "off with a link there: the link goes, its target stays" "gone keep" "$([[ -e $FLAG || -L $FLAG ]] || echo gone) $(cat "$T/target")"

# ---- Omarchy 4.0 (omarchy-mac): no such toggle, nothing written ----
expect "4.0: status none" none "$(run o40 --status)"
out=$(run o40 on); rc=$?
expect "4.0 on: exit 3" 3 "$rc"
expect "4.0 on: why" "OmacVM: it needs Omarchy 4.5 (this Omarchy has no animations toggle): Move to Omarchy 4.5 in OmacVM.app" "$out"
expect "4.0 on: nothing written, no reload" "none 0" "$([[ -e $FLAG ]] && echo there || echo none) $(calls)"
expect "4.0 off: nothing to do, exit 0" "0" "$(run o40 off > /dev/null; echo $?)"
expect "usage: exit 2" 2 "$(run o45 bogus 2> /dev/null; echo $?)"

# ---- the feature: off by default, experimental, Omarchy 4.5 ----
source "$R/src/lib/features.sh"
features_load
i=$(feature_index fewer-animations)
expect "features.tsv: off by default" off "$(feature_default "$i")"
expect "features.tsv: experimental" yes "$(feature_has_tag "$i" experimental && echo yes)"
expect "features.tsv: Omarchy 4.5" yes "$(feature_has_tag "$i" omarchy-45 && echo yes)"
expect "features.tsv: the VM's side only" vm "${FSIDES[$i]}"
mkdir -p "$T/vm40" "$T/vm45"; echo "4.0.3rc4 omarchy-mac rc" > "$T/vm40/omarchy"; echo "4.5.0 aarch64 stable" > "$T/vm45/omarchy"
FEATURES_VM_DIR=$T/vm40
expect "a 4.0 VM: not available, and why" "no needs Omarchy 4.5" "$(feature_available "$i" && echo yes || echo "no ${REASON%% (*}")"
FEATURES_VM_DIR=$T/vm45
expect "a 4.5 VM: available" yes "$(feature_available "$i" && echo yes)"
FEATURES_VM_DIR=""
expect "the release part: animations/**" "fewer-animations	animations/**" "$(grep '^fewer-animations	' "$R/src/release/parts.tsv")"

# ---- the record follows Omarchy's menu (features_real, as autologin and SDDM) ----
for ((k = 0; k < ${#FN[@]}; k++)); do FV[$k]=off; done
features_real $'OMACVM_FEATURE_fewer_animations=off\nOMACVM_REAL_fewer_animations=on' ""
expect "toggled off in Omarchy's menu: the feature is on" on "${FV[$i]}"
expect "... and the drift line" "Fewer animations: on (Omarchy's animations toggle in the VM); OmacVM's record said off: fixed the record" \
  "$(features_drift_lines "fixed the record")"
features_real $'OMACVM_FEATURE_fewer_animations=on\nOMACVM_REAL_fewer_animations=off' ""
expect "toggled back on in Omarchy's menu: the feature is off" off "${FV[$i]}"
FV[$i]=on
features_real $'OMACVM_FEATURE_fewer_animations=on\nOMACVM_REAL_fewer_animations=on' ""
expect "the record right: no drift" "0 on" "${#DRIFT[@]} ${FV[$i]}"
FV[$i]=on
features_real 'OMACVM_FEATURE_fewer_animations=on' ""
expect "Omarchy 4.0 (no REAL line): the record as it is" "0 on" "${#DRIFT[@]} ${FV[$i]}"
# The probe reads the toggle only where Omarchy has it (src/lib/vm.sh).
expect "the probe: only with Omarchy's toggle" 1 \
  "$(grep -c 'if \[ -f /usr/share/omarchy/default/hypr/toggles/no-animations.lua \]; then' "$R/src/lib/vm.sh")"

(( fail == 0 )) && echo "all passed" || echo "FAILED"
exit "$fail"
