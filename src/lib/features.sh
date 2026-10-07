# OmacVM's feature list (src/features.tsv) on the Mac side (sourced; macOS's
# bash 3.2, so parallel arrays instead of associative ones).
#   features_load                 FN FDEF FSIDES FTAGS FNEEDS FTITLE FSUM
#   feature_index NAME            -> index, or status 1
#   feature_alias NAME VALUE      -> "NAME VALUE" with a renamed feature's new
#                                 name (idle-lock on = no-idle-lock off)
#   feature_has_tag INDEX TAG
#   feature_default INDEX        on|off on this Mac (NOTCH, TYPE)
#   feature_available INDEX      status 1 + REASON when this Mac or VM type cannot have it
#   features_read_env ENV_TEXT    FV (on|off per index) from a VM's /etc/omacvm/env;
#                                 defaults for what it does not name
#   features_fix                  a feature needing another one is off without it
#   features_read_record DIR      FV from an OmacVM.app VM's record (DIR/features)
#   features_real PROBE [DIR]     FV as the VM really is where a feature can drift;
#                                 DRIFT: what the record had wrong
#   features_record_fix IP [DIR]  writes DRIFT into the record and the VM's copy
#   feature_switch_parts INSTALLED DIGESTS "SWITCHED" "ALL"
#                                 the parts a feature switch installs, or status 1
#
# The record of a VM's features (docs: tracks/control-centre.md, "Feature
# state truth"): an OmacVM.app VM's folder has it in its features file (the
# app reads it at each start); every VM keeps a copy in /etc/omacvm/env (the
# VM side reads it). omacvm apply writes both. vm.env's FEATURES is only the
# setup's choice for the VM's first apply, which then takes it out. Two
# features can be switched outside OmacVM, and their real state wins: the
# fast network (the app's Fast network button writes the VM's fast-network
# file) and autologin (SDDM's [Autologin] in the VM, also a file OmacVM did
# not write).
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

# Renamed features: a VM, a record or a command from before says the old name.
# idle-lock (on: Omarchy's screensaver and lock after idle) became
# no-idle-lock in 3.0.1 (on: OmacVM keeps them off), so the value flips.
# Only the new name is written.
feature_flip() { case ${1:-} in on) echo off ;; off) echo on ;; *) echo "${1:-}" ;; esac; }
feature_alias() {   # NAME [VALUE] -> "NEWNAME NEWVALUE"
  if [[ $1 == idle-lock ]]; then echo "no-idle-lock $(feature_flip "${2:-}")"; else echo "$1 ${2:-}"; fi
}
# The old name's value in TEXT (KEY=value lines or words), flipped to the new
# one ("" when TEXT does not name it either).
feature_old_value() {   # NEWNAME TEXT
  [[ $1 == no-idle-lock ]] || return 0
  local v
  v=$(tr ' \t' '\n\n' <<<"$2" | sed -n -e 's/^OMACVM_FEATURE_idle_lock=//p' -e 's/^idle-lock=//p' | tail -1)
  [[ $v == on || $v == off ]] && feature_flip "$v"
  return 0
}

feature_has_tag() { [[ ",${FTAGS[$1]}," == *",$2,"* ]]; }

# What the tag slow means, in words (the control centre says the same:
# TAG_HINTS in src/control/omacvm_cc/state.py). Shown only while it is off.
# The memory-optimized kernel: about 10 minutes with 16 CPUs, over an hour
# with 4 (an M2 MacBook Air's VM).
feature_slow_hint() { echo "a build in the VM to switch it on, then a restart: minutes to over an hour, faster with more CPUs"; }

# Does this Mac have a battery? yes|no (MacBooks: yes).
mac_battery() { pmset -g batt 2>/dev/null | grep -q InternalBattery && echo yes || echo no; }

# The default of feature INDEX on this Mac (NOTCH = notch|none) for a VM of
# TYPE (empty: not known yet).
feature_default() {
  if feature_has_tag "$1" app-only && [[ -n ${TYPE:-} && $TYPE != app ]]; then echo off; return; fi
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
      [[ -n $v ]] || v=$(feature_old_value "${FN[$i]}" "$1")
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

features_read_record() {
  local i v rec
  [[ -n ${1:-} && -f $1/features ]] || return 0
  rec=" $(tr '\n\t' '  ' < "$1/features") "
  for ((i = 0; i < ${#FN[@]}; i++)); do
    v=${rec#* "${FN[$i]}="}
    if [[ $v == "$rec" ]]; then   # not named: an old name, or else the VM's copy says
      v=$(feature_old_value "${FN[$i]}" "$rec")
      [[ -n $v ]] || continue
    fi
    v=${v%% *}
    [[ $v == on || $v == off ]] && FV[$i]=$v
  done
  return 0
}

# features_real PROBE [DIR]: the features that can be switched outside
# OmacVM, as they are. FV gets the real state, and DRIFT
# "name<TAB>real<TAB>where<TAB>said" for each one that the record (FV) or
# the VM's copy (PROBE's OMACVM_FEATURE_) had wrong; said: what that was.
features_real() {
  local real
  DRIFT=()
  if [[ -n ${2:-} ]]; then   # OmacVM.app: the fast-network file is the switch
    [[ -s $2/fast-network ]] && real=on || real=off
    feature_drift "$1" fast-network "$real" "the app's Fast network setting"
  fi
  real=$(sed -n 's/^OMACVM_REAL_autologin=//p' <<<"$1" | tail -1)
  [[ $real == on || $real == off ]] && feature_drift "$1" autologin "$real" "SDDM's autologin in the VM"
  return 0
}
feature_drift() {   # PROBE NAME REAL WHERE
  local i copy
  i=$(feature_index "$2") || return 0
  copy=$(sed -n "s/^OMACVM_FEATURE_$(tr - _ <<<"$2")=//p" <<<"$1" | tail -1)
  [[ ${FV[$i]} == "$3" && ( -z $copy || $copy == "$3" ) ]] && return 0
  DRIFT+=("$2"$'\t'"$3"$'\t'"$4"$'\t'"$( [[ $3 == on ]] && echo off || echo on)")
  FV[$i]=$3
}

# One line per drift, as "Autologin: on (SDDM's autologin in the VM); OmacVM's
# record said off: fixed the record" (TAIL: what came of it).
features_drift_lines() {
  local d n v w said i
  for d in ${DRIFT[@]+"${DRIFT[@]}"}; do
    IFS=$'\t' read -r n v w said <<<"$d"
    i=$(feature_index "$n") || continue
    echo "${FTITLE[$i]}: $v ($w); OmacVM's record said $said${1:+: $1}"
  done
}

# features_record_fix IP [DIR]: DRIFT into the VM's copy (/etc/omacvm/env,
# only when it has one) and, for an OmacVM.app VM, its features file. Status
# 1 when the VM's copy could not be written (the record is still fixed).
features_record_fix() {
  local d n v w kv="" i feats=""
  [[ -n ${DRIFT[*]+x} ]] || return 0
  for d in "${DRIFT[@]}"; do
    IFS=$'\t' read -r n v w _ <<<"$d"
    [[ $n =~ ^[a-z][a-z0-9-]*$ && ( $v == on || $v == off ) ]] && kv+=" $(tr - _ <<<"$n")=$v"
  done
  if [[ -n ${2:-} && -f $2/features ]]; then
    for ((i = 0; i < ${#FN[@]}; i++)); do feats+="${FN[$i]}=${FV[$i]} "; done
    app_features_write "$2" "${feats% }" || true
  fi
  [[ -n $kv ]] || return 0
  gssh "$1" "set -e; f=/etc/omacvm/env; [ -f \$f ] || exit 0
    for kv in$kv; do k=OMACVM_FEATURE_\${kv%%=*}; v=\${kv#*=}
      if grep -q \"^\$k=\" \$f; then sed \"s/^\$k=.*/\$k=\$v/\" \$f > \$f.omacvm-new; cat \$f.omacvm-new > \$f; rm -f \$f.omacvm-new
      else echo \"\$k=\$v\" >> \$f; fi
    done" < /dev/null >/dev/null 2>&1
}

# feature_switch_parts INSTALLED DIGESTS "SWITCHED..." "ALL...": the VM side
# a feature switch runs (apply.sh), as a comma list for guest/install.sh
# --only: the switched features and every feature whose part this copy has
# with another digest than the VM. INSTALLED: the VM's
# /etc/omacvm/installed.json; DIGESTS: manifest.py digests of this copy.
# Status 1 (the whole VM side runs) when the VM's core part differs or it
# does not say. Running all of it on each switch rewrote Hyprland's config
# files, reloaded Hyprland and restarted the display agent: the displays
# flickered for a while (2026-10-06, WebGPU switched on with a 6K display).
feature_switch_parts() {
  python3 -c '
import json, sys
def parts(text):
    try:
        p = json.loads(text).get("parts")
    except (ValueError, AttributeError):
        return {}
    return p if isinstance(p, dict) else {}
def digest(p, k):
    v = p.get(k)
    return v.get("digest") if isinstance(v, dict) else None
old, new = parts(sys.argv[1]), parts(sys.argv[2])
core = digest(new, "core")
if not core or digest(old, "core") != core:
    sys.exit(1)
names = sys.argv[4].split()
want = set(sys.argv[3].split()) | {k for k in names if k in new and digest(old, k) != digest(new, k)}
out = [k for k in names if k in want]
if not out:
    sys.exit(1)
print(",".join(out))
' "$@"
}

# JSON string (for the --json outputs).
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}
