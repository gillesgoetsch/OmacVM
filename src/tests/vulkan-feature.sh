#!/bin/bash
# The vulkan feature (Vulkan, WebGPU and GPU compute in OmacVM.app) without a
# VM: its line in features.tsv, the VM folder's vulkan file that apply writes
# and removes (the app starts that VM with Venus), the guest install's Mesa
# step, and build.sh refusing it at build time.
#   src/tests/vulkan-feature.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# features.tsv: off by default, experimental, OmacVM.app only.
IFS=$'\t' read -r name def sides tags needs title _ < <(grep $'^vulkan\t' "$R/src/features.tsv")
expect "features.tsv has vulkan" vulkan "${name:-}"
expect "vulkan is off by default" off "${def:-}"
expect "vulkan is experimental and app-only" yes "$([[ ,$tags, == *,experimental,* && ,$tags, == *,app-only,* ]] && echo yes)"

# apply.sh, Mac side: the Mesa check before the record is written, then the
# vulkan block (each from its comment to its closing fi).
pre=$(awk '/^  # Vulkan without OmacVM.s Mesa in the VM is off, in the record too/ {on = 1} on {print} on && /^  fi$/ {exit}' "$R/src/cmd/apply.sh")
block=$(awk '/^  # Vulkan \(Venus\) from the VM.s next start/ {on = 1} on {print} on && /^  fi$/ {exit}' "$R/src/cmd/apply.sh")
[[ $pre == *'FV[$(feature_index vulkan)]=off'* ]] || { echo "FAIL vulkan Mesa check not found in src/cmd/apply.sh"; exit 1; }
[[ $block == *'on vulkan'* ]] || { echo "FAIL vulkan block not found in src/cmd/apply.sh"; exit 1; }
mac() {   # ON(on|off) RUNNING(yes|no) [had] -> files in the VM folder, what apply said, the record's vulkan
  # ICD=no: the VM has no OmacVM Mesa (its build failed). SSH=down: every SSH call fails (255).
  ( d=$T/vm; rm -rf "$d"; mkdir -p "$d"; [[ ${3:-} == had ]] && : > "$d/vulkan"
    FV=("$1") RUN=$2 SAID="" IP=vm
    feature_index() { echo 0; }
    on() { [[ $1 == vulkan && ${FV[0]} == on ]]; }
    app_pid_dir() { [[ $RUN == yes ]] && echo 123; }
    info() { SAID="said"; }
    gssh() { [[ ${SSH:-up} == up ]] || return 255; [[ $2 != "test -f /etc/vulkan/icd.d/omacvm_venus_icd.json" || ${ICD:-yes} == yes ]]; }
    eval "$pre"; eval "$block"
    echo "$(ls "$d" | tr '\n' ' ')$SAID${REC:+ ${FV[0]}}" )
}
expect "on, VM stopped: vulkan file, no message" "vulkan " "$(mac on no)"
expect "on, VM running: vulkan file, restart message" "vulkan said" "$(mac on yes)"
expect "on again: file kept, no message" "vulkan " "$(mac on yes had)"
expect "off: file removed" "" "$(mac off no had)"
expect "off, VM running: file removed, message" "said" "$(mac off yes had)"
expect "off, never on: nothing" "" "$(mac off yes)"
expect "on, Mesa build failed: no vulkan file, message" "said" "$(ICD=no mac on no)"
expect "on, Mesa build failed, file from before: removed, message" "said" "$(ICD=no mac on yes had)"
expect "off, no Mesa: file removed" "" "$(ICD=no mac off no had)"
expect "on, Mesa build failed: the record says off" "said off" "$(ICD=no REC=1 mac on no)"
expect "on, Mesa there: the record says on" "vulkan  on" "$(REC=1 mac on no)"
expect "on, SSH fails: the record stays on, no message" "vulkan  on" "$(SSH=down REC=1 mac on no)"

# guest/install.sh: the vulkan step of OmacVM.app's VMs.
gblock=$(awk '/^  if \[\[ \$\{F\[vulkan\]\} == on \]\]; then$/ {on = 1} on {print} on && /^  fi$/ {exit}' "$R/src/guest/install.sh")
[[ $gblock == *'venus/install.sh" --force'* ]] || { echo "FAIL vulkan step not found in src/guest/install.sh"; exit 1; }
gblock=${gblock//'${F[vulkan]}'/'$FV'}
opt=/opt/omacvm-mesa; gblock=${gblock//"$opt"/'$MESA'}
guest() {   # FEATURE(on|off) MESA(yes|no) -> how venus/install.sh was called
  ( FV=$1 MESA=$T/mesa R=/repo CALLS=""; rm -rf "$MESA"; [[ $2 == yes ]] && mkdir -p "$MESA"
    log() { :; }; not_set_up() { :; }
    /repo/app/guest/venus/install.sh() { CALLS+="$* "; }
    eval "$gblock"
    echo "${CALLS% }" )
}
expect "guest, on: Mesa built (--force)" --force "$(guest on no)"
expect "guest, on, Mesa there: install runs (it skips the build by its stamp)" --force "$(guest on yes)"
expect "guest, off, Mesa there: removed" --remove "$(guest off yes)"
expect "guest, off, no Mesa: nothing" "" "$(guest off no)"
expect "guest, not OmacVM.app: forced off" yes \
  "$(grep -qxF '[[ $TYPE == app ]] || F[vulkan]=off' "$R/src/guest/install.sh" && echo yes)"

# build.sh: on only after the build (it needs the app's vulkan file and a restart).
expect "build.sh refuses vulkan=on" yes \
  "$(grep -q '^    vulkan) \[\[ \$2 == off \]\] || usage' "$R/src/cmd/build.sh" && echo yes)"

# omacvm enable/disable: strict for what they switch, also from a terminal
# (a failed Mesa build rolls back, exit 4, instead of leaving vulkan=on).
expect "enable/disable run apply with --transaction" yes \
  "$(grep -qF 'APPLY_ARGS+=(--transaction)' <(sed -n '/^# Strict for the features it switches/,$p' "$R/src/cmd/features.sh") && echo yes)"

# The app reads the VM's vulkan file for its Venus device options.
expect "Runner.swift reads the vulkan file" yes \
  "$(grep -q 'appendingPathComponent("vulkan")' "$R/app/app/Sources/OmacVM/Runner.swift" && echo yes)"

exit $fail
