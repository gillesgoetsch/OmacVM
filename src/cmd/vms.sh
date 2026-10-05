#!/bin/bash
# omacvm vms [--json]: your Parallels and UTM VMs and their OmacVM state (asks
# the running ones over SSH; stopped VMs are not started).
# --json: {"omacvm", "vms": [{"name", "type", "state", "ip", "omacvm",
# "reachable", "features": {NAME: true|false}}]}; omacvm = the version in the
# VM (null: none, or stopped), reachable = OmacVM's SSH key gets in; state
# "unknown": UTM runs but does not answer this terminal (not allowed to
# control UTM yet, or over SSH).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
features_load
JSON=0
case ${1:-} in
  --json) JSON=1 ;;
  -h|--help) sed -n '2,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
  "") ;;
  *) echo "omacvm vms: unknown option $1" >&2; exit 2 ;;
esac
export OMA_KEY=~/.ssh/omacvm
NOTCH=$(swift "$R/src/display/mac-notch.swift" 2>/dev/null || echo none)
first=1
(( JSON )) && printf '{"omacvm": %s, "vms": [' "$(json_str "$(cat "$R/src/VERSION")")"
(( JSON )) || printf '  %-24s %-10s %-8s %-15s %s\n' VM APP STATE ADDRESS OMACVM
while IFS=$'\t' read -r name type state; do
  [[ -n $name ]] || continue
  ip=""; version=""; reach=false; feats=""
  if [[ $state == running ]]; then
    ip=$(vm_find_ip "$name" "$type" 3 2>/dev/null) || ip=""
    vm_pin "$name" "$type"
    if [[ -n $ip ]] && probe=$(vm_probe "$ip") && [[ -n $probe ]]; then
      reach=true
      version=$(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe")
      if [[ -n $version ]]; then
        TYPE=$type; features_read_env "$probe"   # TYPE: the defaults of features it does not name
        for ((i = 0; i < ${#FN[@]}; i++)); do
          feats+="${feats:+, }\"${FN[$i]}\": $( [[ ${FV[$i]} == on ]] && echo true || echo false)"
        done
      fi
    fi
  fi
  if (( JSON )); then
    printf '%s\n  {"name": %s, "type": "%s", "state": "%s", "ip": %s, "omacvm": %s, "reachable": %s, "features": %s}' \
      "$( ((first)) || echo ,)" "$(json_str "$name")" "$type" "$state" "$( [[ -n $ip ]] && json_str "$ip" || echo null)" \
      "$( [[ -n $version ]] && json_str "$version" || echo null)" "$reach" "$( [[ -n $feats ]] && echo "{$feats}" || echo null)"
  else
    if [[ $state == unknown ]]; then what="($UTM_NO_ANSWER)"
    elif [[ $state != running ]]; then what="(start it to see)"
    elif [[ $reach == false ]] && [[ -n $ip ]] && hostkey_changed "$ip" 2>/dev/null; then what="another SSH host key (rebuilt? omacvm apply --vm \"$name\" --reset-host-key)"
    elif [[ $reach == false ]]; then what="no SSH access (not built by OmacVM? omacvm apply --vm \"$name\" shows how)"
    elif [[ -z $version ]]; then what="not installed (omacvm apply --vm \"$name\")"
    else what=$version; fi
    printf '  %-24s %-10s %-8s %-15s %s\n' "$name" "$type" "$state" "${ip:--}" "$what"
  fi
  first=0
done < <(vms_list)
(( JSON )) && printf '\n]}\n'
exit 0
