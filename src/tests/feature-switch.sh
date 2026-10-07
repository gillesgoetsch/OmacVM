#!/bin/bash
# shellcheck disable=SC2034 # the variables apply.sh's block reads (eval)
# A feature switch runs only the parts that change, not the whole VM side
# (2026-10-06: switching WebGPU on ran all of it; Hyprland reloaded and the
# displays flickered for a while). Without a VM:
#  * lib/features.sh feature_switch_parts: which parts, or the whole run;
#  * apply.sh's choice of --only (its block, with stand-ins for SSH and the
#    digests);
#  * guest/install.sh's vulkan step keeps the driver timer in step;
#  * glide.sh reloads Hyprland only when its config changed.
#   src/tests/feature-switch.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source "$R/src/lib/features.sh"
features_load
ALL="${FN[*]}"

# ---- feature_switch_parts ----
new='{"version": "3.0.1", "parts": {"core": {"digest": "c1"}, "vulkan": {"digest": "v2"}, "gestures": {"digest": "g1"}, "bridge": {"digest": "b1"}}}'
same='{"version": "3.0.1", "parts": {"core": {"digest": "c1", "release": "3.0.0"}, "vulkan": {"digest": "v1"}, "gestures": {"digest": "g1"}, "bridge": {"digest": "b1"}}}'
parts() { local out rc; out=$(feature_switch_parts "$@"); rc=$?; echo "$rc:$out"; }
expect "switch: only the switched feature (its part changed too)" "0:vulkan" "$(parts "$same" "$new" "vulkan" "$ALL")"
expect "switch: a part this copy changed goes too, in features.tsv order" "0:gestures,vulkan" \
  "$(parts "${same/\"g1\"/\"g0\"}" "$new" "vulkan" "$ALL")"
expect "switch: a feature without a part" "0:fast-network" \
  "$(parts "${same/\"v1\"/\"v2\"}" "$new" "fast-network" "$ALL")"
expect "core differs: the whole run" "1:" "$(parts "${same/\"c1\"/\"c0\"}" "$new" "vulkan" "$ALL")"
expect "no installed.json: the whole run" "1:" "$(parts "" "$new" "vulkan" "$ALL")"
expect "installed.json not JSON: the whole run" "1:" "$(parts "garbage" "$new" "vulkan" "$ALL")"
expect "installed.json a list: the whole run" "1:" "$(parts "[1]" "$new" "vulkan" "$ALL")"
expect "parts not an object: the whole run" "1:" "$(parts '{"parts": []}' "$new" "vulkan" "$ALL")"
expect "no digests of this copy: the whole run" "1:" "$(parts "$same" "" "vulkan" "$ALL")"
expect "nothing switched, nothing changed: the whole run" "1:" \
  "$(parts "${same/\"v1\"/\"v2\"}" "$new" "" "$ALL")"
expect "an unknown name is left out" "0:vulkan" "$(parts "$same" "$new" "vulkan nosuch" "$ALL")"

# ---- apply.sh: when it passes --only ----
block=$(awk '/^ONLY=""$/ {on = 1} on {print} on && /^fi$/ {exit}' "$R/src/cmd/apply.sh")
[[ $block == *feature_switch_parts* ]] || { echo "FAIL the --only block not found in src/cmd/apply.sh"; exit 1; }
mkdir -p "$T/src/release"
printf '#!/bin/sh\ncat "%s/digests"\n' "$T" > "$T/src/release/manifest.py"; chmod +x "$T/src/release/manifest.py"
echo "$new" > "$T/digests"
INSTALLED=$same
gssh() { echo "$INSTALLED"; }
info() { :; }
fi_of() { feature_index "$1"; }
# run SETN... : the block with these --feature names; FV/PREV/had/now/probe/REINSTALL from the caller.
run() {
  SETN=("$@"); GI_ARGS=""
  ( R=$T IP=ip VM=vm; eval "$block"; echo "${GI_ARGS# }|$ONLY" )
}
base() {
  features_read_env ""; PREV=("${FV[@]}"); had=3.0.1; now=3.0.1; REINSTALL=()
  probe=$'OMACVM_VERSION=3.0.1\nOMACVM_GRAPHICS=opengl'; GRAPHICS=opengl
}
base; FV[$(fi_of vulkan)]=on
expect "apply: a switch on the same version: --only" "--only vulkan|vulkan" "$(run vulkan)"
base; FV[$(fi_of vulkan)]=on; INSTALLED=${same/\"g1\"/\"g0\"}
expect "apply: a switch takes the parts this copy changed" "--only gestures,vulkan|gestures,vulkan" "$(run vulkan)"
INSTALLED=$same
base; FV[$(fi_of vulkan)]=on; FV[$(fi_of autologin)]=$(feature_flip "${PREV[$(fi_of autologin)]}")
expect "apply: a drift fixed with the switch goes too" "--only autologin,vulkan|autologin,vulkan" "$(run vulkan)"
base
expect "apply: the same features again (apply-vm.sh): the whole run" "|" "$(run "${FN[@]}")"
base; FV[$(fi_of autologin)]=$(feature_flip "${PREV[$(fi_of autologin)]}")
expect "apply: only a drift, nothing switched: the whole run" "|" "$(run vulkan)"
base; FV[$(fi_of vulkan)]=on; had=3.0.0
expect "apply: another version in the VM: the whole run" "|" "$(run vulkan)"
base; FV[$(fi_of vulkan)]=on; had=""
expect "apply: no OmacVM in the VM yet: the whole run" "|" "$(run vulkan)"
base; FV[$(fi_of vulkan)]=on; probe+=$'\nOMACVM_PREBUILT_FRESH=1'
expect "apply: a fresh prebuilt VM: the whole run" "|" "$(run vulkan)"
base; FV[$(fi_of vulkan)]=on; INSTALLED=${same/\"c1\"/\"c0\"}
expect "apply: the VM's core differs: the whole run" "|" "$(run vulkan)"
INSTALLED=$same
base; FV[$(fi_of vulkan)]=on; GRAPHICS=vulkan
expect "apply: a switch while the VM's Graphics changed: the whole run" "|" "$(run vulkan)"
base; FV[$(fi_of vulkan)]=on; GRAPHICS=""; probe="OMACVM_VERSION=3.0.1"
expect "apply: a switch on a VM without Graphics (not the app's): --only" "--only vulkan|vulkan" "$(run vulkan)"
base; REINSTALL=(camera)
expect "apply: a repair stays a repair" "--only camera|camera" "$(run)"
expect "apply: without --feature: the whole run" "|" "$(base; run)"

# The rollback switches back the same parts only.
grep -q 'GI_ARGS=""; \[\[ -n $ONLY \]\] && GI_ARGS=" --only $ONLY"' "$R/src/cmd/apply.sh" &&
  echo "ok   apply: the rollback uses the same --only" || { echo "FAIL apply: the rollback ignores --only"; fail=1; }

# ---- guest/install.sh: the vulkan step keeps the driver timer in step ----
step=$(awk '/^if want vulkan && \[\[ \$TYPE == app \]\]; then$/ {on = 1} on {print} on && /^fi$/ {exit}' "$R/src/guest/install.sh")
[[ $step == *'"$R/app/guest/venus/timer.sh"'* ]] && echo "ok   vulkan step runs venus/timer.sh" ||
  { echo "FAIL the vulkan step does not run venus/timer.sh"; fail=1; }
grep -q '^venus/timer.sh' "$R/src/app/guest/install.sh" && echo "ok   app step runs venus/timer.sh" ||
  { echo "FAIL the app step does not run venus/timer.sh"; fail=1; }

# ---- glide.sh: Hyprland reloads only when its config changed ----
# Stand-ins: the user's home is $T/home, install without owners, sudo records the reload.
B=$T/bin; mkdir -p "$B" "$T/home/.config/hypr" "$T/run/hypr/sig"
printf '%s\n' '-- hyprland' > "$T/home/.config/hypr/hyprland.lua"
cat > "$B/getent" <<X
#!/bin/sh
echo "u:x:1000:1000::$T/home:/bin/bash"
X
cat > "$B/install" <<'X'
#!/bin/bash
a=(); while (( $# )); do case $1 in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/install "${a[@]}"
X
printf '#!/bin/sh\n:\n' > "$B/chown"
printf '#!/bin/sh\necho reload >> "%s/reloads"\n' "$T" > "$B/sudo"
printf '#!/bin/sh\necho 1000\n' > "$B/id"
chmod +x "$B"/*
G=$T/glide; cp -R "$R/src/gestures/guest" "$G"
sed -i.bak "s|^RUN=/run/user/\$(id -u \"\$U\")|RUN=$T/run|" "$G/glide.sh"
glide() { PATH="$B:$PATH" bash "$G/glide.sh" u "$1" >/dev/null 2>&1; echo $?; }
reloads() { [[ -f $T/reloads ]] && wc -l < "$T/reloads" | tr -d ' ' || echo 0; }
expect "glide on: runs" 0 "$(glide on)"
expect "glide on: Hyprland reloaded once" 1 "$(reloads)"
expect "glide on: hyprland.lua requires it" 1 "$(grep -cxF 'require("hypr.omacvm_glide")' "$T/home/.config/hypr/hyprland.lua")"
ino=$(ls -i "$T/home/.config/hypr/omacvm_glide.lua" | awk '{print $1}')
expect "glide on again: runs" 0 "$(glide on)"
expect "glide on again: no reload" 1 "$(reloads)"
expect "glide on again: the file is not rewritten" "$ino" "$(ls -i "$T/home/.config/hypr/omacvm_glide.lua" | awk '{print $1}')"
expect "glide on again: hyprland.lua has it once" 1 "$(grep -cxF 'require("hypr.omacvm_glide")' "$T/home/.config/hypr/hyprland.lua")"
if sed --version >/dev/null 2>&1; then   # GNU sed (the VM's): the off path's sed -i
  expect "glide off: runs" 0 "$(glide off)"
  expect "glide off: Hyprland reloaded" 2 "$(reloads)"
  expect "glide off: the line is gone" 0 "$(grep -cxF 'require("hypr.omacvm_glide")' "$T/home/.config/hypr/hyprland.lua")"
  expect "glide off again: no reload" 2 "$(glide off >/dev/null; reloads)"
else
  rm -f "$T/home/.config/hypr/omacvm_glide.lua"
  printf '%s\n' '-- hyprland' > "$T/home/.config/hypr/hyprland.lua"
  expect "glide off when off: runs" 0 "$(glide off)"
  expect "glide off when off: no reload" 1 "$(reloads)"
fi

exit $fail
