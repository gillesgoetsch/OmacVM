#!/bin/bash
# omacvm features / enable / disable: a VM's OmacVM features.
#   omacvm features [--vm NAME] [--json]     list them; in a terminal, switch them
#   omacvm enable FEATURE... [--vm NAME] [--yes]
#   omacvm disable FEATURE... [--vm NAME] [--yes]
# Features (src/features.tsv): bridge wallpaper gestures scroll-momentum omanotch
# mac-clock camera battery idle-lock autologin thp-kernel. A feature that needs another one brings it
# along (enable scroll-momentum also enables gestures) or goes with it (disable bridge
# also disables wallpaper). Changes go through omacvm apply: the Mac side
# they need, then the VM. A stopped VM is started.
# --json (features): {"vm", "type", "omacvm", "features": [{"name", "on",
# "default", "experimental", "available", "needs", "title", "summary"}]}.
# Without --vm it starts nothing: the state of the VM it would pick if that
# one runs, else the defaults ("vm": null).
# Exit codes: 0 done, 1 failed, 2 usage, 3 needs a person.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/setup.sh"
source "$R/src/lib/features.sh"
features_load
MODE=$1; shift
VM=""; TYPE=""; JSON=0; YES=0; WANT=()
usage() { echo "omacvm $MODE: $*" >&2; exit 2; }
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) sed -n '2,13s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) usage "unknown option $1 (see --help)" ;;
    *) feature_index "$1" >/dev/null || usage "unknown feature '$1' (omacvm features lists them)"
       WANT+=("$1"); shift ;;
  esac
done
[[ $MODE == features || ${#WANT[@]} -gt 0 ]] || usage "which feature? (omacvm features lists them)"
[[ $MODE != features || ${#WANT[@]} == 0 ]] || usage "features takes no feature names (enable/disable do)"
export OMA_KEY=~/.ssh/omacvm
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
if [[ -z $version ]]; then   # not an OmacVM VM yet: what it would get
  for ((i = 0; i < ${#FN[@]}; i++)); do FV[$i]=$(feature_default "$i"); done
fi
OLD=("${FV[@]}")

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
    printf '%s\n  {"name": "%s", "on": %s, "default": %s, "experimental": %s, "available": %s, "needs": %s, "title": %s, "summary": %s}' \
      "$( ((i)) && echo ,)" "${FN[$i]}" "$( [[ ${FV[$i]} == on ]] && echo true || echo false)" \
      "$( [[ $(feature_default "$i") == on ]] && echo true || echo false)" \
      "$(feature_has_tag "$i" experimental && echo true || echo false)" "$av" \
      "$( [[ ${FNEEDS[$i]} == - ]] && echo null || json_str "${FNEEDS[$i]}")" \
      "$(json_str "${FTITLE[$i]}")" "$(json_str "${FSUM[$i]}")"
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
  feature_has_tag "$i" slow && tag=" $dim(slow to build)$off"
  available "$i" || tag=" $dim($REASON)$off"
  printf '%s%s' "${FTITLE[$i]}" "$tag"
}

if [[ $MODE == features ]]; then
  if [[ -t 1 ]]; then printf '\n\033[1m%s\033[0m (%s%s)\n' "$VM" "$TYPE" "${version:+, OmacVM $version}"
  else printf '%s (%s%s)\n' "$VM" "$TYPE" "${version:+, OmacVM $version}"; fi
  [[ -n $version ]] || say "    OmacVM is not on this VM yet: these are the defaults it would get."
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
  for f in "${WANT[@]}"; do
    i=$(feature_index "$f")
    if [[ $MODE == enable ]] && ! available "$i"; then usage "${FTITLE[$i]} $REASON"; fi
    set_on "$i" "$( [[ $MODE == enable ]] && echo on || echo off)"
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
exec "$R/src/cmd/apply.sh" --vm "$VM" --vm-type "$TYPE" --ip "$IP" "${changes[@]}"
