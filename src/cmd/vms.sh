#!/bin/bash
# omacvm vms [--json] [--app-only]: your Parallels and UTM VMs and their OmacVM
# state (asks the running ones over SSH; stopped VMs are not started).
# --app-only: only OmacVM.app's VMs (the Bridge runs this through the app, so a
# VMs folder on an external drive can be read: src/bridge/mac/control.swift).
# --json: {"omacvm", "vms": [{"name", "type", "state", "ip", "omacvm",
# "reachable", "setup", "features": {NAME: true|false}, "dir", "note"}]}; omacvm = the version in the
# VM (null: none, or stopped), reachable = OmacVM's SSH key gets in, setup =
# OmacVM set it up from this Mac (its SSH host key is remembered, or OmacVM built it);
# state "unknown": UTM runs but does not answer this terminal (not allowed to
# control UTM yet, or over SSH), with note "UTM data not readable" when UTM's
# own files were not read either (macOS guards them: lib/mac.sh utm_data);
# dir = an OmacVM.app VM's folder (null for the others: the Bridge reads its
# logs/gpu-memory for the control centre when an older app does not send it). UTM is listed only once it is used
# with OmacVM on this Mac (OMACVM_UTM=1: always).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
source "$R/src/lib/features.sh"
features_load
JSON=0; APP_ONLY=0
while (( $# )); do
  case $1 in
    --json) JSON=1 ;;
    --app-only) APP_ONLY=1 ;;
    -h|--help) sed -n '2,15s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm vms: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
export OMA_KEY=~/.ssh/omacvm
NOTCH=$(swift "$R/src/display/mac-notch.swift" 2>/dev/null || echo none)
first=1
(( JSON )) && printf '{"omacvm": %s, "vms": [' "$(json_str "$(cat "$R/src/VERSION")")"
(( JSON )) || printf '  %-24s %-10s %-8s %-15s %s\n' VM APP STATE ADDRESS OMACVM
while IFS=$'\t' read -r name type state note; do
  [[ -n $name ]] || continue
  ip=""; version=""; reach=false; feats=""; setup=false; dir=""; TYPE=""
  [[ $type == app ]] && dir=$(app_dir "$name" 2>/dev/null)
  if [[ $state == running ]]; then
    ip=$(vm_find_ip "$name" "$type" 3 2>/dev/null) || ip=""
    vm_pin "$name" "$type"
    { [[ -s $OMA_PIN ]] || vm_marked "$name" "$type"; } && setup=true
    if [[ -n $ip ]] && probe=$(vm_probe "$ip") && [[ -n $probe ]]; then
      reach=true
      version=$(sed -n 's/^OMACVM_VERSION=//p' <<<"$probe")
      if [[ -n $version ]]; then
        TYPE=$type; features_read_env "$probe"   # TYPE: the defaults of features it does not name
        # The record, and what was switched outside OmacVM as it is (omacvm features and check fix the record).
        features_read_record "$dir"; features_real "$probe" "$dir"
        for ((i = 0; i < ${#FN[@]}; i++)); do
          feats+="${feats:+, }\"${FN[$i]}\": $( [[ ${FV[$i]} == on ]] && echo true || echo false)"
        done
      fi
    fi
  fi
  if (( JSON )); then
    printf '%s\n  {"name": %s, "type": "%s", "state": "%s", "ip": %s, "omacvm": %s, "reachable": %s, "setup": %s, "features": %s, "dir": %s, "note": %s}' \
      "$( ((first)) || echo ,)" "$(json_str "$name")" "$type" "$state" "$( [[ -n $ip ]] && json_str "$ip" || echo null)" \
      "$( [[ -n $version ]] && json_str "$version" || echo null)" "$reach" "$setup" "$( [[ -n $feats ]] && echo "{$feats}" || echo null)" \
      "$( [[ -n $dir ]] && json_str "$dir" || echo null)" "$( [[ -n $note ]] && json_str "$note" || echo null)"
  else
    if [[ $state == unknown && -n $note ]]; then what="($UTM_UNREADABLE_HINT)"
    elif [[ $state == unknown ]]; then what="($UTM_NO_ANSWER)"
    elif [[ $state != running ]]; then what="(start it to see)"
    elif [[ $reach == false ]] && [[ -n $ip ]] && hostkey_changed "$ip" 2>/dev/null; then what="another SSH host key (rebuilt? omacvm apply --vm \"$name\" --reset-host-key)"
    elif [[ $reach == false ]]; then what="no SSH access (not built by OmacVM? omacvm apply --vm \"$name\" shows how)"
    elif [[ -z $version ]]; then what="not installed (omacvm apply --vm \"$name\")"
    else what=$version; fi
    printf '  %-24s %-10s %-8s %-15s %s\n' "$name" "$type" "$state" "${ip:--}" "$what"
  fi
  first=0
done < <(if (( APP_ONLY )); then app_list; else vms_list; fi)
(( JSON )) && printf '\n]}\n'
exit 0
