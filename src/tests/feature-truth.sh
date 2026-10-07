#!/bin/bash
# Feature state truth without a VM: OmacVM's record of a VM's features (an
# OmacVM.app VM's features file, the VM's copy in /etc/omacvm/env) against
# what can be switched outside OmacVM (the app's Fast network button, an SDDM
# autologin file OmacVM did not write), the record fix, vm.env's FEATURES
# going once the record is there, apply-vm.sh reading the record, and the
# autologin rule being the same in the probe and in the VM.
#   src/tests/feature-truth.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source "$R/src/lib/features.sh"
source "$R/src/lib/app.sh"
features_load
fv() { local i; i=$(feature_index "$1"); echo "${FV[$i]}"; }

# ---- the user's VM on 2026-10-06: the record said off, the app and SDDM on ----
d=$T/vm; mkdir -p "$d"
REC="bridge=on wallpaper=on gestures=on scroll-momentum=on omanotch=on mac-clock=on camera=on battery=on external-brightness=on chromium-video=on idle-lock=on autologin=off thp-kernel=on control-centre=on fast-network=off vulkan=off"
echo "$REC" > "$d/features"
echo "mac=52:54:00:aa:bb:cc" > "$d/fast-network"
printf "NAME='Omarchy'\nFEATURES='bridge=on omanotch=off autologin=off fast-network=off'\nKEYBOARD='ch'\n" > "$d/vm.env"
probe="OMACVM_VERSION=3.0.0
OMACVM_FEATURE_omanotch=on
OMACVM_FEATURE_autologin=off
OMACVM_FEATURE_fast_network=off
OMACVM_REAL_autologin=on"
features_read_env "$probe"; features_read_record "$d"
expect "record: omanotch on (the features file)" on "$(fv omanotch)"
expect "record: idle-lock=on (before 3.0.1) is no-idle-lock off" off "$(fv no-idle-lock)"
features_real "$probe" "$d"
expect "real: fast network on (the app's file)" on "$(fv fast-network)"
expect "real: autologin on (SDDM)" on "$(fv autologin)"
expect "two drifts" 2 "${#DRIFT[@]}"
expect "drift line" "Fast network: on (the app's Fast network setting); OmacVM's record said off: fixed the record" \
  "$(features_drift_lines "fixed the record" | sed -n 1p)"

# The fix: the features file and the VM's copy (gssh runs the command on a copy of the env here).
cat > "$T/env" <<'X'
OMACVM_VM_TYPE=app
OMACVM_FEATURE_autologin=off
OMACVM_FEATURE_fast_network=off
X
gssh() { local c=${2//\/etc\/omacvm\/env/$T/env}; bash -c "$c"; }
features_record_fix ip "$d"; rc=$?
expect "fix: status 0" 0 "$rc"
expect "fix: features file has fast-network=on" yes "$(grep -q ' fast-network=on ' <<<" $(cat "$d/features") " && echo yes)"
expect "fix: features file has autologin=on" yes "$(grep -q ' autologin=on ' <<<" $(cat "$d/features") " && echo yes)"
expect "fix: features file has the new name only" "yes no" \
  "$(grep -q ' no-idle-lock=off ' <<<" $(cat "$d/features") " && echo yes) $(grep -q ' idle-lock=' <<<" $(cat "$d/features") " && echo yes || echo no)"
expect "fix: the VM's copy, autologin" OMACVM_FEATURE_autologin=on "$(grep autologin "$T/env")"
expect "fix: the VM's copy, fast network" OMACVM_FEATURE_fast_network=on "$(grep fast_network "$T/env")"
expect "fix: the rest of the VM's copy as it was" OMACVM_VM_TYPE=app "$(head -1 "$T/env")"
expect "fix: vm.env's FEATURES gone" "" "$(grep '^FEATURES=' "$d/vm.env")"
expect "fix: the rest of vm.env kept" "NAME='Omarchy' KEYBOARD='ch'" "$(tr '\n' ' ' < "$d/vm.env" | sed 's/ $//')"

# Again: nothing left to fix.
probe2="OMACVM_VERSION=3.0.0
$(cat "$T/env")
OMACVM_REAL_autologin=on"
features_read_env "$probe2"; features_read_record "$d"; features_real "$probe2" "$d"
expect "after the fix: no drift" "" "${DRIFT[*]:-}"

# Only the VM's copy wrong (the record was fixed by hand): still a drift, so the copy is fixed too.
features_read_env "$probe"; FV[$(feature_index autologin)]=on; FV[$(feature_index fast-network)]=on
features_real "$probe" "$d"
expect "copy wrong, record right: drift" 2 "${#DRIFT[@]}"

# Switched off outside OmacVM: real off wins.
rm "$d/fast-network"
features_read_env "$probe2"; features_read_record "$d"; features_real "${probe2/OMACVM_REAL_autologin=on/OMACVM_REAL_autologin=off}" "$d"
expect "off outside OmacVM: fast network off" off "$(fv fast-network)"
expect "off outside OmacVM: autologin off" off "$(fv autologin)"
expect "off outside OmacVM: said on" "Autologin: off (SDDM's autologin in the VM); OmacVM's record said on" "$(features_drift_lines | tail -1)"

# Not an app VM, and an older VM that does not say: nothing invented.
features_read_env "OMACVM_FEATURE_autologin=off"; features_real "OMACVM_FEATURE_autologin=off" ""
expect "no real state known: no drift" "" "${DRIFT[*]:-}"
# No VM copy at all: the fix writes nothing in the VM.
echo "x" > "$T/marker"; DRIFT=($'autologin\ton\tSDDM\toff')
gssh() { echo called > "$T/marker"; }
features_record_fix ip ""
expect "fix without a features file: only the VM's copy" called "$(cat "$T/marker")"

# app_features_write: the record first, then FEATURES goes; unchanged = status 1.
d2=$T/vm2; mkdir -p "$d2"; printf "NAME='x'\nFEATURES='bridge=on'\n" > "$d2/vm.env"
app_features_write "$d2" "bridge=on"; rc=$?
expect "first write: changed" 0 "$rc"
expect "first write: FEATURES gone" "NAME='x'" "$(cat "$d2/vm.env")"
app_features_write "$d2" "bridge=on"; rc=$?
expect "same again: unchanged" 1 "$rc"

# ---- idle-lock, renamed no-idle-lock in 3.0.1 (on and off the other way round) ----
features_read_env "OMACVM_FEATURE_idle_lock=off"
expect "old name, VM's copy: idle-lock off = no-idle-lock on" on "$(fv no-idle-lock)"
features_read_env "OMACVM_FEATURE_idle_lock=on"
expect "old name, VM's copy: idle-lock on = no-idle-lock off" off "$(fv no-idle-lock)"
features_read_env ""
expect "not named: Omarchy's own screensaver and lock, as before" off "$(fv no-idle-lock)"
features_read_env $'OMACVM_FEATURE_idle_lock=off\nOMACVM_FEATURE_no_idle_lock=off'
expect "both names: the new one wins" off "$(fv no-idle-lock)"
d4=$T/vm4; mkdir -p "$d4"; echo "bridge=on idle-lock=off autologin=off" > "$d4/features"
features_read_env ""; features_read_record "$d4"
expect "old name, record: idle-lock=off = no-idle-lock on" on "$(fv no-idle-lock)"
echo "bridge=on no-idle-lock=off idle-lock=off" > "$d4/features"
features_read_env ""; features_read_record "$d4"
expect "old and new name in the record: the new one wins" off "$(fv no-idle-lock)"
expect "alias: disable idle-lock" "no-idle-lock on" "$(feature_alias idle-lock off)"
expect "alias: enable idle-lock" "no-idle-lock off" "$(feature_alias idle-lock on)"
expect "alias: other names as they are" "bridge on" "$(feature_alias bridge on)"
i=$(feature_index no-idle-lock)
expect "title" "Screensaver and lock disabled" "${FTITLE[$i]}"
expect "default: off (Omarchy's own, as before)" off "$(feature_default "$i")"
# apply.sh's set_feature and its options (its own lines, run here).
block=$(awk '/^set_feature\(\) \{/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/cmd/apply.sh")
sf() { ( SETN=(); SETV=(); eval "$block"; for a in "$@"; do set_feature "${a%%=*}" "${a#*=}"; done; echo "${SETN[*]} ${SETV[*]}" ) 2>&1; }
expect "apply: --feature idle-lock=off" "no-idle-lock on" "$(sf idle-lock=off)"
expect "apply: --feature no-idle-lock=on" "no-idle-lock on" "$(sf no-idle-lock=on)"
expect "apply: --feature idle-lock=maybe" "omacvm apply: --feature idle-lock=maybe: on or off" "$(sf idle-lock=maybe)"
# check.sh: the VM's copy from before 3.0.1 (its own line, run here).
line=$(grep '^NO_IDLE_LOCK=' "$R/src/guest/check.sh")
ck() { ( unset OMACVM_FEATURE_idle_lock OMACVM_FEATURE_no_idle_lock; eval "$1"; eval "$line"; echo "$NO_IDLE_LOCK" ); }
expect "check: idle-lock off" on "$(ck OMACVM_FEATURE_idle_lock=off)"
expect "check: nothing named" off "$(ck :)"
expect "check: no-idle-lock on" on "$(ck "OMACVM_FEATURE_no_idle_lock=on OMACVM_FEATURE_idle_lock=on")"
# guest/install.sh's --feature: the old name flipped (its own lines, run with
# a bash 5 as Arch's; macOS's own 3.2 has no associative arrays).
block=$(awk '/^    --feature\) / {on = 1} on {print} on && /shift 2 ;;$/ {exit}' "$R/src/guest/install.sh")
[[ $block == *'idle-lock'* ]] || { echo "FAIL install.sh --feature block not found"; exit 1; }
B5=""; for b in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
  [[ -x $b ]] && (( $("$b" -c 'echo ${BASH_VERSINFO[0]}') >= 4 )) && { B5=$b; break; }
done
gi() { "$B5" -c "declare -A SET=(); set -- --feature \"\$1\"; case \$1 in
$block
esac; for k in \"\${!SET[@]}\"; do echo \"\$k=\${SET[\$k]}\"; done" _ "$1"; }
if [[ -n $B5 ]]; then
  expect "guest: --feature idle-lock=off" no-idle-lock=on "$(gi idle-lock=off)"
  expect "guest: --feature idle-lock=on" no-idle-lock=off "$(gi idle-lock=on)"
  expect "guest: --feature bridge=on" bridge=on "$(gi bridge=on)"
else
  echo "skip guest --feature: no bash 4 or newer here"
fi

# ---- apply-vm.sh: the record, else the setup's choice; never the fast network ----
block=$(awk '/^feats=\$\{FEATURES:-\}$/ {on = 1} on {print} on && /^done$/ {exit}' "$R/app/scripts/apply-vm.sh")
[[ $block == *'features'* ]] || { echo "FAIL apply-vm.sh block not found"; exit 1; }
av() { ( VM_DIR=$1 FEATURES=$2; args=(); eval "$block"; echo "${args[*]}" ); }
expect "apply-vm: the setup's choice before the first apply" "--feature bridge=on --feature autologin=on" \
  "$(av "$T/none" "bridge=on autologin=on fast-network=off")"
printf 'bridge=off autologin=on fast-network=on\n' > "$d2/features"
expect "apply-vm: the record once it is there, without the fast network" "--feature bridge=off --feature autologin=on" \
  "$(av "$d2" "bridge=on autologin=off")"

# ---- apply.sh: the real state goes in, and a rollback goes back to it ----
block=$(awk '/^# OmacVM.app: the VM.s record \(its features file\) over the VM.s copy\.$/ {on = 1} on {print} on && /^fi$/ {n++} on && n == 2 {exit}' "$R/src/cmd/apply.sh")
[[ $block == *'features_real'* && $block == *'PREV['* ]] || { echo "FAIL apply.sh record block not found"; exit 1; }
d3=$T/vm3; mkdir -p "$d3"; echo "mac=52:54:00:01:02:03" > "$d3/fast-network"
echo "autologin=off fast-network=off omanotch=on" > "$d3/features"
ap() {   # PROBE -> "autologin fast-network omanotch | PREV's autologin | what it said"
  ( TYPE=app NAMED=1 VM=x had=3.0.0 SAID="" probe=$1
    app_dir() { echo "$d3"; }
    info() { SAID+="[$*]"; }
    features_read_env "$1"; PREV=("${FV[@]}")
    eval "$block"
    echo "$(fv autologin) $(fv fast-network) $(fv omanotch) | ${PREV[$(feature_index autologin)]} | $SAID" )
}
expect "apply: real state in, rollback to it, said once each" \
  "on on on | on | [Fast network: on (the app's Fast network setting); OmacVM's record said off: kept, the record follows][Autologin: on (SDDM's autologin in the VM); OmacVM's record said off: kept, the record follows]" \
  "$(ap $'OMACVM_FEATURE_autologin=off\nOMACVM_FEATURE_omanotch=off\nOMACVM_REAL_autologin=on')"
rm "$d3/fast-network"
expect "apply: nothing drifted, nothing said" "off off on | off | " \
  "$(ap $'OMACVM_FEATURE_autologin=off\nOMACVM_FEATURE_fast_network=off\nOMACVM_REAL_autologin=off')"

# ---- the autologin rule: the probe (lib/vm.sh) and the VM (guest/autologin.sh) agree ----
probe_script=$(awk '/^vm_probe\(\) \{/ {on = 1} on {print} on && /^}$/ {exit}' "$R/src/lib/vm.sh")
eval "$probe_script"
root=$T/root
gssh() { local c=$2; c=${c//\/etc\//$root/etc/}; c=${c//\/usr\/lib\//$root/usr/lib/}; c=${c//\/usr\/local\//$root/usr/local/}; bash -c "$c" 2>/dev/null; }
case_() {   # WHAT WANT(on|off) then the files as PATH=TEXT
  local what=$1 want=$2 kv; shift 2
  rm -rf "$root"; mkdir -p "$root/etc/sddm.conf.d"
  for kv in "$@"; do mkdir -p "$(dirname "$root/${kv%%=*}")"; printf '%b' "${kv#*=}" > "$root/${kv%%=*}"; done
  local p g
  p=$(vm_probe ip | sed -n 's/^OMACVM_REAL_autologin=//p')
  g=$(SDDM_ROOT=$root; source "$R/src/guest/autologin.sh"; [[ -n $(sddm_autologin_user) ]] && echo on || echo off)
  expect "autologin rule, $what: probe" "$want" "$p"
  expect "autologin rule, $what: guest" "$want" "$g"
}
case_ "a migration's own file" on "etc/sddm.conf.d/20-autologin.conf=# omarchy-vm\n[Autologin]\nUser=gillesgoetsch\nSession=hyprland-uwsm\n"
case_ "OmacVM's file" on "etc/sddm.conf.d/20-omacvm-autologin.conf=[Autologin]\nUser=zorro\n"
case_ "theme and wayland only" off "etc/sddm.conf.d/10-theme.conf=[Theme]\nCurrent=omarchy\n" "etc/sddm.conf.d/10-wayland.conf=[General]\nDisplayServer=wayland\n"
case_ "an empty User= later wins" off "etc/sddm.conf.d/20-autologin.conf=[Autologin]\nUser=x\n" "etc/sddm.conf=[Autologin]\nUser=\n"
case_ "User= in another section" off "etc/sddm.conf.d/30-x.conf=[Users]\nUser=x\n"
case_ "the system's own folder" on "usr/lib/sddm/sddm.conf.d/50-x.conf=[Autologin]\nUser=y\n"

# guest/autologin.sh: the files that are not OmacVM's own (install.sh sets them aside for off).
rm -rf "$root"; mkdir -p "$root/etc/sddm.conf.d"
printf '[Autologin]\nUser=a\n' > "$root/etc/sddm.conf.d/20-autologin.conf"
printf '[Autologin]\nUser=a\n' > "$root/etc/sddm.conf.d/20-omacvm-autologin.conf"
printf '[Theme]\nCurrent=omarchy\n' > "$root/etc/sddm.conf.d/10-theme.conf"
expect "others: only the foreign autologin file" "$root/etc/sddm.conf.d/20-autologin.conf" \
  "$(SDDM_ROOT=$root; source "$R/src/guest/autologin.sh"; sddm_autologin_others)"

# ---- words, never a bare "slow" ----
expect "slow hint in words" yes "$( [[ $(feature_slow_hint) == *"over an hour"* ]] && echo yes)"
expect "slow hint only while off" yes \
  "$(grep -qF 'feature_has_tag "$i" slow && [[ ${OLD[$i]} != on ]]' "$R/src/cmd/features.sh" && echo yes)"
grep -q 'about 10 minutes per build' "$R/src/features.tsv" && { echo "FAIL features.tsv still says about 10 minutes"; fail=1; }
grep -q '(slow to build)' "$R/src/cmd/features.sh" && { echo "FAIL features.sh still says slow to build"; fail=1; }
grep -q 'slow to build' "$R/src/lib/ui.sh" && { echo "FAIL ui.sh still says slow to build"; fail=1; }

(( fail )) && { echo "feature-truth: FAILED"; exit 1; }
echo "feature-truth: all passed"
