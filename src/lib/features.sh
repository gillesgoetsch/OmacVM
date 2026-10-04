# OmacVM's feature list (src/features.tsv) on the Mac side (sourced; macOS's
# bash 3.2, so parallel arrays instead of associative ones).
#   features_load                 FN FDEF FSIDES FTAGS FNEEDS FTITLE FSUM
#   feature_index NAME            -> index, or status 1
#   feature_has_tag INDEX TAG
#   feature_default INDEX        on|off on this Mac (NOTCH, TYPE)
#   feature_available INDEX      status 1 + REASON when this Mac or VM type cannot have it
#   features_read_env ENV_TEXT    FV (on|off per index) from a VM's /etc/omacvm/env;
#                                 defaults for what it does not name
#   features_fix                  a feature needing another one is off without it
FEATURES_TSV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/features.tsv"

features_load() {
  FN=(); FDEF=(); FSIDES=(); FTAGS=(); FNEEDS=(); FTITLE=(); FSUM=()
  local name def sides tags needs title sum
  while IFS=$'\t' read -r name def sides tags needs title sum; do
    [[ -z $name || $name == \#* ]] && continue
    FN+=("$name"); FDEF+=("$def"); FSIDES+=("$sides"); FTAGS+=("$tags")
    FNEEDS+=("$needs"); FTITLE+=("$title"); FSUM+=("$sum")
  done < "$FEATURES_TSV"
}

feature_index() {
  local i
  for ((i = 0; i < ${#FN[@]}; i++)); do [[ ${FN[$i]} == "$1" ]] && { echo "$i"; return 0; }; done
  return 1
}

feature_has_tag() { [[ ",${FTAGS[$1]}," == *",$2,"* ]]; }

# Does this Mac have a battery? yes|no (MacBooks: yes).
mac_battery() { pmset -g batt 2>/dev/null | grep -q InternalBattery && echo yes || echo no; }

# The default of feature INDEX on this Mac (NOTCH = notch|none) for a VM of
# TYPE (empty: not known yet).
feature_default() {
  case ${FDEF[$1]} in
    on) echo on ;;
    notch) [[ ${NOTCH:-none} == notch ]] && echo on || echo off ;;
    laptop) [[ ${TYPE:-} != parallels && $(mac_battery) == yes ]] && echo on || echo off ;;
    *) echo off ;;
  esac
}

# Can feature INDEX be on, on this Mac for a VM of TYPE? Status 1 and REASON if not.
feature_available() {
  REASON=""
  if feature_has_tag "$1" notch && [[ ${NOTCH:-none} != notch ]]; then REASON="needs a MacBook with a notch"; return 1; fi
  if feature_has_tag "$1" laptop && [[ $(mac_battery) != yes ]]; then REASON="needs a Mac with a battery"; return 1; fi
  if feature_has_tag "$1" not-parallels && [[ ${TYPE:-} == parallels ]]; then REASON="Parallels does it itself"; return 1; fi
  if feature_has_tag "$1" app-only && [[ -n ${TYPE:-} && $TYPE != app ]]; then REASON="OmacVM.app only"; return 1; fi
  return 0
}

features_read_env() {
  local i v
  FV=()
  for ((i = 0; i < ${#FN[@]}; i++)); do
    v=$(sed -n "s/^OMACVM_FEATURE_$(tr - _ <<<"${FN[$i]}")=//p" <<<"$1" | tail -1)
    if [[ -z $v ]]; then
      # VMs from before a feature existed: what they were built with.
      # (scroll-momentum was called glide in the experiment)
      [[ ${FN[$i]} == scroll-momentum ]] && v=$(sed -n 's/^OMACVM_FEATURE_glide=//p' <<<"$1" | tail -1)
      [[ -n $v ]] || case ${FN[$i]} in omanotch|scroll-momentum|autologin|thp-kernel|fast-network) v=off ;; *) v=$(feature_default "$i") ;; esac
    fi
    FV[$i]=$v
  done
}

features_fix() {
  local i j changed=1
  while (( changed )); do
    changed=0
    for ((i = 0; i < ${#FN[@]}; i++)); do
      [[ ${FV[$i]} == on && ${FNEEDS[$i]} != - ]] || continue
      j=$(feature_index "${FNEEDS[$i]}") || continue
      [[ ${FV[$j]} == on ]] || { FV[$i]=off; changed=1; }
    done
  done
}

# JSON string (for the --json outputs).
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}
