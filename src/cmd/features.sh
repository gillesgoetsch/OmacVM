#!/bin/bash
# omacvm features / enable / disable: a VM's OmacVM features.
#   omacvm features [--vm NAME] [--json]     list them; in a terminal, switch them
#   omacvm features [--vm NAME] --in-vm      open the control centre on the VM's desktop
#                                            (one window; in front if it is open already)
#   (--vm-type parallels|utm|fusion|app when two apps have a VM of that name)
#   omacvm enable FEATURE... [--vm NAME] [--yes] [--transaction]
#   omacvm disable FEATURE... [--vm NAME] [--yes] [--transaction]
# Features (src/features.tsv): bridge wallpaper gestures scroll-momentum omanotch
# mac-clock camera battery external-brightness chromium-video no-idle-lock autologin thp-kernel control-centre
# fast-network vulkan x86-apps (idle-lock, its name before 3.0.1, still works the other way round:
# disable idle-lock = enable no-idle-lock). A feature that needs another one brings it
# along (enable scroll-momentum also enables gestures) or goes with it (disable bridge
# also disables wallpaper). Changes go through omacvm apply --transaction: the
# Mac side they need, then the VM; if a feature it switches does not set up,
# the VM goes back to what it had and the run ends with exit code 4, so the
# record never says on for a feature that is not there. (--transaction is
# still taken, for older callers.) A stopped VM is started.
# --json (features): {"vm", "type", "omacvm", "features": [{"name", "on",
# "default", "experimental", "available", "reason", "needs", "title", "summary",
# "fixed"}]}; reason: why this Mac or VM cannot have it ("" when available);
# on: as the VM really is (src/lib/features.sh: features_real); fixed: what
# OmacVM's record had wrong and that it was fixed ("" when it was right).
# Without --vm it starts nothing: the state of the VM it would pick if that
# one runs, else the defaults ("vm": null).
# --in-vm: the VM must run with someone logged in to its desktop, and have the
# control centre (on by default); else it says what is missing (exit 3).
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person, 4 failed and
# rolled back.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/setup.sh"
source "$R/src/lib/features.sh"
features_load
MODE=$1; shift
VM=""; TYPE=""; JSON=0; YES=0; INVM=0; WANT=(); WANTV=(); APPLY_ARGS=()
usage() { echo "omacvm $MODE: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --in-vm) INVM=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --transaction) APPLY_ARGS+=(--transaction); shift ;;
    -h|--help) sed -n '2,29s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) usage "unknown option $1 (see --help)" ;;
    *) read -r f v <<<"$(feature_alias "$1" "$( [[ $MODE == enable ]] && echo on || echo off)")"
       feature_index "$f" >/dev/null || usage "unknown feature '$1' (omacvm features lists them)"
       WANT+=("$f"); WANTV+=("$v"); shift ;;
  esac
done
[[ $MODE == features || ${#WANT[@]} -gt 0 ]] || usage "which feature? (omacvm features lists them)"
[[ $MODE != features || ${#WANT[@]} == 0 ]] || usage "features takes no feature names (enable/disable do)"
(( ! INVM )) || [[ $MODE == features ]] || usage "--in-vm goes with omacvm features"
(( ! INVM || ! JSON )) || usage "--in-vm or --json, not both"
export OMA_KEY=~/.ssh/omacvm
# The control centre in the VM (src/control/guest/open.sh): opened in the
# desktop session of a running VM; a stopped one is not started (nobody would
# be logged in to see it).
if (( INVM )); then
  resolve_vm
  [[ -n $IP ]] || { echo "omacvm features: '$VM' is not running: start it and log in, then try again" >&2; exit 3; }
  rc=0
  out=$(gssh "$IP" "if [ -x /usr/local/share/omacvm/control/guest/open.sh ]; then /usr/local/share/omacvm/control/guest/open.sh; else echo old; exit 64; fi" < /dev/null 2>/dev/null) || rc=$?
  out=$(tail -1 <<<"$out" | tr -cd '[:print:]' | cut -c1-200)   # the VM's line, printable and short
  case $rc in
    0) echo "  '$VM': the control centre is $out." ;;
    3|5) echo "omacvm features: '$VM': $out" >&2; exit 3 ;;
    64) echo "omacvm features: '$VM' has an older OmacVM: omacvm apply --vm \"$VM\" brings it up to date (then try again)" >&2; exit 3 ;;
    255) echo "omacvm features: no SSH answer from '$VM' ($IP)" >&2; exit 1 ;;
    *) echo "omacvm features: '$VM': ${out:-it did not open}" >&2; exit 1 ;;
  esac
  exit 0
fi
NOTCH=$(swift "$R/src/display/mac-notch.swift" 2>/dev/null || echo none)
if [[ $MODE == features && -z $VM ]] && (( JSON )); then
  resolve_vm soft || { VM=""; TYPE=""; IP=""; }
  [[ -n $IP ]] || { VM=""; TYPE=""; }
else
  resolve_vm start
fi
probe=""; [[ -z $IP ]] || probe=$(vm_probe "$IP") || true
version=$(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe")
features_read_env "$probe"
DRIFT=(); FIXED=""
if [[ -z $version ]]; then   # not an OmacVM VM yet: what it would get
  for ((i = 0; i < ${#FN[@]}; i++)); do FV[$i]=$(feature_default "$i"); done
else
  # The record (an OmacVM.app VM's features file), then what was switched
  # outside OmacVM as it really is; the record is fixed to match.
  rd=""; [[ $TYPE == app && -n $VM ]] && { rd=$(app_dir "$VM" 2>/dev/null) || rd=""; }
  features_read_record "$rd"
  features_real "$probe" "$rd"
  if [[ -n ${DRIFT[*]+x} ]]; then
    features_record_fix "$IP" "$rd" && FIXED="fixed the record" || FIXED="the record could not be fixed"
  fi
fi
OLD=("${FV[@]}")
drift_of() {   # NAME -> "on (the app's Fast network setting); OmacVM's record said off: fixed the record", or nothing
  local d n v w said
  for d in ${DRIFT[@]+"${DRIFT[@]}"}; do
    IFS=$'\t' read -r n v w said <<<"$d"
    [[ $n == "$1" ]] && echo "$v ($w); OmacVM's record said $said: $FIXED"
  done
  return 0
}

available() { feature_available "$1"; }   # INDEX -> status 0 if this Mac and VM can use it; REASON otherwise

# set_on INDEX on|off, with what it needs or what needs it
set_on() {
  local i=$1 v=$2 j
  FV[$i]=$v
  if [[ $v == on && ${FNEEDS[$i]} != - ]]; then
    j=$(feature_index "${FNEEDS[$i]}") && [[ ${FV[$j]} == off ]] && set_on "$j" on
  fi
  if [[ $v == off ]]; then
    for ((j = 0; j < ${#FN[@]}; j++)); do
      [[ ${FNEEDS[$j]} == "${FN[$i]}" && ${FV[$j]} == on ]] && set_on "$j" off
    done
  fi
  return 0
}

if (( JSON )); then
  printf '{"vm": %s, "type": %s, "ip": %s, "omacvm": %s, "features": [' \
    "$( [[ -n $VM ]] && json_str "$VM" || echo null)" "$( [[ -n $TYPE ]] && json_str "$TYPE" || echo null)" "$(json_str "$IP")" \
    "$( [[ -n $version ]] && json_str "$version" || echo null)"
  for ((i = 0; i < ${#FN[@]}; i++)); do
    available "$i" && av=true || av=false
    printf '%s\n  {"name": "%s", "on": %s, "default": %s, "experimental": %s, "available": %s, "reason": %s, "needs": %s, "title": %s, "summary": %s, "fixed": %s}' \
      "$( ((i)) && echo ,)" "${FN[$i]}" "$( [[ ${FV[$i]} == on ]] && echo true || echo false)" \
      "$( [[ $(feature_default "$i") == on ]] && echo true || echo false)" \
      "$(feature_has_tag "$i" experimental && echo true || echo false)" "$av" "$(json_str "$REASON")" \
      "$( [[ ${FNEEDS[$i]} == - ]] && echo null || json_str "${FNEEDS[$i]}")" \
      "$(json_str "${FTITLE[$i]}")" "$(json_str "${FSUM[$i]}")" "$(json_str "$(drift_of "${FN[$i]}")")"
  done
  printf '\n]}\n'
  exit 0
fi

interactive=0
{ : < "$TTY"; } 2>/dev/null && [[ -t 1 ]] && interactive=1
label() {   # INDEX -> one line for the list
  local i=$1 tag="" dim="" pink="" off=""
  if [[ -t 1 ]] || (( interactive )); then dim=$'\033[2m'; pink=$'\033[35m'; off=$'\033[0m'; fi
  feature_has_tag "$i" experimental && tag=" $pink(experimental)$off"
  # Slow is about switching it on: nothing more while it is on.
  feature_has_tag "$i" slow && [[ ${OLD[$i]} != on ]] && tag=" $dim($(feature_slow_hint))$off"
  available "$i" || tag=" $dim($REASON)$off"
  # Scroll momentum acts only on a trackpad's scrolling, never a mouse's.
  [[ ${FN[$i]} == scroll-momentum && ${FV[$i]} == on ]] && tag=" $dim(trackpad only)$off$tag"
  printf '%s%s' "${FTITLE[$i]}" "$tag"
}

if [[ $MODE == features ]]; then
  if [[ -t 1 ]]; then printf '\n\033[1m%s\033[0m (%s%s)\n' "$VM" "$TYPE" "${version:+, OmacVM $version}"
  else printf '%s (%s%s)\n' "$VM" "$TYPE" "${version:+, OmacVM $version}"; fi
  [[ -n $version ]] || say "    OmacVM is not on this VM yet: these are the defaults it would get."
  while IFS= read -r l; do [[ -z $l ]] || say "    $l"; done < <(features_drift_lines "$FIXED")
  if (( ! interactive )); then
    for ((i = 0; i < ${#FN[@]}; i++)); do
      printf '  %-4s %-16s %s\n' "${FV[$i]}" "${FN[$i]}" "$(label "$i")"
    done
    echo "  Switch with: omacvm enable|disable FEATURE --vm \"$VM\""
    exit 0
  fi
  # A checklist: ↑/↓ (or k/j) move, space toggles, Return applies, q leaves.
  cur=0; n=${#FN[@]}; drawn=0
  draw() {
    (( drawn )) && printf '\033[%dA' $((n + 2)) > "$TTY"
    for ((i = 0; i < n; i++)); do
      local mark="[ ]" ptr=" "
      [[ ${FV[$i]} == on ]] && mark=$'[\033[32m✓\033[0m]'
      (( i == cur )) && ptr=$'\033[1m❯\033[0m'
      available "$i" || mark=$'\033[2m[–]\033[0m'
      printf '\r\033[K  %s %s %s\n' "$ptr" "$mark" "$(label "$i")" > "$TTY"
    done
    printf '\r\033[K    \033[2m%s\033[0m\n' "${FSUM[$cur]}" > "$TTY"
    printf '\r\033[K  ↑/↓ move · space switch · Return apply · q quit\n' > "$TTY"
    drawn=1
  }
  echo
  while :; do
    draw
    IFS= read -rsn1 k < "$TTY" || exit 1
    case $k in
      $'\033') IFS= read -rsn2 -t 1 k < "$TTY" || k=""
               case $k in '[A') (( cur > 0 )) && cur=$((cur - 1)) ;; '[B') (( cur < n - 1 )) && cur=$((cur + 1)) ;; esac ;;
      k) (( cur > 0 )) && cur=$((cur - 1)) ;;
      j) (( cur < n - 1 )) && cur=$((cur + 1)) ;;
      " ") if available "$cur"; then [[ ${FV[$cur]} == on ]] && set_on "$cur" off || set_on "$cur" on; fi ;;
      "") break ;;
      q) echo; exit 0 ;;
    esac
  done
else
  for ((w = 0; w < ${#WANT[@]}; w++)); do
    i=$(feature_index "${WANT[$w]}")
    if [[ ${WANTV[$w]} == on ]] && ! available "$i"; then usage "${FTITLE[$i]} $REASON"; fi
    set_on "$i" "${WANTV[$w]}"
  done
fi

# What changes
changes=(); summary=""
for ((i = 0; i < ${#FN[@]}; i++)); do
  [[ ${FV[$i]} == "${OLD[$i]}" ]] && continue
  changes+=(--feature "${FN[$i]}=${FV[$i]}")
  summary+="    ${FTITLE[$i]}: ${FV[$i]}"$'\n'
done
if (( ${#changes[@]} == 0 )); then
  echo "  Nothing to change on '$VM'."
  exit 0
fi
printf '\n  On %s:\n%s' "$VM" "$summary"
if (( ! YES )) && (( interactive )); then
  ask_yn "Apply?" y || exit 1
fi
# --yes: apply asks nothing either (its control centre question).
(( YES )) && APPLY_ARGS+=(--yes)
# Strict for the features it switches, also from a terminal (see the top).
[[ " ${APPLY_ARGS[*]:-} " == *" --transaction "* ]] || APPLY_ARGS+=(--transaction)
exec "$R/src/cmd/apply.sh" --vm "$VM" --vm-type "$TYPE" --ip "$IP" "${changes[@]}" ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"}
