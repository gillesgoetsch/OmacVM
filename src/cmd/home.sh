#!/bin/bash
# omacvm without a command: asks what you want to do. No VM yet: straight to
# the setup of a new one. Without a terminal it prints the help (scripts and
# agents use the commands).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/setup.sh"
if ! { : < "$TTY"; } 2>/dev/null; then
  sed -n '2,21s/^# \{0,1\}//p' "$R/omacvm"
  exit 2
fi
export OMA_KEY=~/.ssh/omacvm
printf '\n\033[1mOmacVM %s\033[0m: Omarchy in a VM on your Mac, feeling native.\n' "$(cat "$R/src/VERSION")"

app_name() { case $1 in parallels) echo Parallels ;; utm) echo UTM ;; fusion) echo Fusion ;; app) echo OmacVM.app ;; esac; }

# The VMs, with OmacVM's state for the running ones.
NAMES=(); TYPES=(); STATES=(); KIND=()   # KIND: omacvm | plain | locked | stopped
while IFS=$'\t' read -r name type state; do
  [[ -n $name ]] || continue
  kind=stopped; v=""
  if [[ $state == running ]]; then
    kind=locked
    vm_pin "$name" "$type"
    if ip=$(vm_find_ip "$name" "$type" 3 2>/dev/null) && probe=$(vm_probe "$ip") && [[ -n $probe ]]; then
      v=$(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe")
      [[ -n $v ]] && kind=omacvm || kind=plain
    fi
  fi
  NAMES+=("$name"); TYPES+=("$type"); STATES+=("$state"); KIND+=("$kind")
  case $kind in
    omacvm) what="OmacVM $v" ;;
    plain) what="Omarchy without OmacVM" ;;
    locked) what="running, OmacVM cannot get in yet" ;;
    *) [[ $state == unknown ]] && what=$UTM_NO_ANSWER || what=${state:-stopped} ;;   # stopped, suspended, paused, ...
  esac
  printf '    %-24s %-10s %s\n' "$name" "$(app_name "$type")" "$what" > "$TTY"
done < <(vms_list)

if (( ${#NAMES[@]} == 0 )); then
  say "    No VM yet: let's build one."
  exec "$R/src/cmd/build.sh"
fi
[[ ${#NAMES[@]} -gt 0 ]] && printf '\n' > "$TTY"

choose_vm() {   # PROMPT -> sets PICK (a name) and PICKT (its app: two apps may use one name)
  local i a
  if (( ${#NAMES[@]} == 1 )); then PICK=${NAMES[0]}; PICKT=${TYPES[0]}; return; fi
  hd "$1"
  for ((i = 0; i < ${#NAMES[@]}; i++)); do printf '    %d  %-24s %s\n' $((i + 1)) "${NAMES[$i]}" "$(app_name "${TYPES[$i]}")"; done
  while :; do
    read -r -p "  Choose 1-${#NAMES[@]} [1]: " a < "$TTY" || exit 1
    a=${a:-1}
    [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= ${#NAMES[@]} )) && { PICK=${NAMES[$((a - 1))]}; PICKT=${TYPES[$((a - 1))]}; return; }
  done
}

DEF=1
for k in "${KIND[@]}"; do [[ $k == omacvm ]] && DEF=2; done
hd "What would you like to do?"
say "    1  Build a new Omarchy VM"
say "    2  Change the features of a VM (scroll momentum, gestures, Bridge, Omanotch, ...)"
say "    3  Add OmacVM to a VM, or bring it up to date"
say "    4  Update OmacVM everywhere (this checkout, the Mac, your running VMs)"
say "    5  Check a VM"
say "    6  Change the CPUs and memory of a VM"
while :; do
  read -r -p "  Choose 1-6, q quits [$DEF]: " a < "$TTY" || exit 1
  case ${a:-$DEF} in
    1) exec "$R/src/cmd/build.sh" ;;
    2) choose_vm "Which VM?"; exec "$R/src/cmd/features.sh" features --vm "$PICK" --vm-type "$PICKT" ;;
    3) choose_vm "Which VM?"; exec "$R/src/cmd/apply.sh" --vm "$PICK" --vm-type "$PICKT" ;;
    4) exec "$R/src/cmd/update.sh" ;;
    5) choose_vm "Which VM?"; exec "$R/src/cmd/check.sh" --vm "$PICK" --vm-type "$PICKT" ;;
    6) choose_vm "Which VM?"; exec "$R/src/cmd/resources.sh" --vm "$PICK" --vm-type "$PICKT" ;;
    q) exit 0 ;;
  esac
done
