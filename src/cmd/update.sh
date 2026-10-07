#!/bin/bash
# omacvm update [--vm NAME [--vm-type T]] [--no-pull] [--commit C] [--transaction] [--yes]: OmacVM up to date everywhere. This
# checkout (git pull, when it is a clean clone), the Mac side that is
# installed (Omanotch with it), OmacVM.app when it is installed and a newer
# one is published (not while it runs), then OmacVM in every running VM that
# has it (or only --vm NAME; a stopped one is started).
# Each VM keeps its feature choices. Stopped VMs are listed, not started. Only
# VMs OmacVM set up from this Mac (their SSH host key is remembered, or OmacVM
# built them) get the update, and with it the Bridge's token.
# --commit C (the control centre's update, the commit of a release manifest the
# Bridge verified): this checkout moves to C, only forward, instead of git pull.
# --transaction: each VM as omacvm apply --transaction (exit code 4: that VM
# failed and went back to what it had). --yes: no questions (as apply --yes).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
VM=""; TYPE=""; PULL=1; ARGS=("$@"); COMMIT=""; APPLY_ARGS=()
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --no-pull) PULL=0; shift ;;
    --commit) COMMIT=$2; shift 2
              [[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "omacvm update: --commit: 40 hex digits" >&2; exit 2; } ;;
    --transaction) APPLY_ARGS+=(--transaction); shift ;;
    --yes|-y) APPLY_ARGS+=(--yes); shift ;;
    -h|--help) sed -n '2,17s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm update: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
export OMA_KEY=~/.ssh/omacvm
# Steps for the control centre's progress (one VM: its apply's three follow).
OMA_STEPS=$(( ${#COMMIT} ? 3 : 2 ))
[[ -n $VM ]] && OMA_STEPS=$((OMA_STEPS + 3))

# ---------- this checkout ----------
[[ -n $COMMIT ]] && step release "the release"
# OmacVM.app's copy (no checkout; COMMIT from build-app.sh): the app updates
# itself, and this copy with it.
if [[ ! -e $R/.git && -f $R/COMMIT ]]; then
  if [[ -n $COMMIT && $(cat "$R/COMMIT") != "$COMMIT" ]]; then
    failed_part "" "update OmacVM.app first: u in the control centre does it, or Check Now in OmacVM on the Mac" mac
    die "this Mac's OmacVM is OmacVM.app's own: update OmacVM.app first (u in the control centre, or Check Now in OmacVM on the Mac)"
  fi
elif [[ -n $COMMIT && $(git -C "$R" rev-parse HEAD) != "$COMMIT" ]]; then
  [[ -z $(git -C "$R" status --porcelain --untracked-files=no) ]] || die "this checkout has local changes: not moved to the release ($R)"
  log "OmacVM: the release (${COMMIT:0:12})"
  git -C "$R" fetch -q origin || die "git fetch failed in $R"
  git -C "$R" cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "the release's commit is not in $R's origin"
  git -C "$R" merge-base --is-ancestor HEAD "$COMMIT" || die "the release is not ahead of this checkout: not moved"
  git -C "$R" merge -q --ff-only "$COMMIT" || die "git merge failed in $R"
  exec "$R/omacvm" update --no-pull ${ARGS[@]+"${ARGS[@]}"}
elif [[ -z $COMMIT ]] && (( PULL )) && git -C "$R" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  if [[ -n $(git -C "$R" status --porcelain --untracked-files=no) ]]; then
    info "this checkout has local changes: not pulling ($R)"
  else
    before=$(git -C "$R" rev-parse HEAD)
    log "OmacVM: git pull"
    git -C "$R" pull -q --ff-only || die "git pull failed in $R"
    if [[ $(git -C "$R" rev-parse HEAD) != "$before" ]]; then
      info "$(cat "$R/src/VERSION"): $(git -C "$R" log --oneline "$before..HEAD" | wc -l | tr -d ' ') new commits"
      exec "$R/omacvm" update --no-pull ${ARGS[@]+"${ARGS[@]}"}
    fi
    info "already up to date ($(cat "$R/src/VERSION"))"
  fi
fi

# ---------- the Mac ----------
args=()
launchctl print "gui/$(id -u)/org.omacvm.bridge" >/dev/null 2>&1 || args+=(--no-bridge)
if launchctl print "gui/$(id -u)/org.omacvm.gestures" 2>/dev/null | grep -q -- --keys-only; then args+=(--keys-only)
elif ! launchctl print "gui/$(id -u)/org.omacvm.gestures" >/dev/null 2>&1; then args+=(--skip-gestures); fi
launchctl print "gui/$(id -u)/org.omacvm.clip-in" >/dev/null 2>&1 || args+=(--skip-clip)
launchctl print "gui/$(id -u)/ch.gillesgoetsch.omanotch" >/dev/null 2>&1 && args+=(--omanotch)
step mac "the Mac side"
log "OmacVM on the Mac"
# A helper that does not build keeps its last build running; the VMs still
# get this OmacVM (a VM left older than the Mac could not switch features
# until it is updated), and the run ends failed, naming the helper.
MAC_FAILED=$(mktemp -t omacvm-mac); mac_failed=()
mrc=0; OMACVM_MAC_FAILED_FILE=$MAC_FAILED "$R/src/mac/install.sh" ${args[@]+"${args[@]}"} || mrc=$?
if (( mrc == 5 )); then
  while IFS= read -r h; do [[ -n $h ]] && mac_failed+=("$h"); done < "$MAC_FAILED"
elif (( mrc )); then
  mac_failed+=("the Mac side")
fi
rm -f "$MAC_FAILED"
mac_failure() {   # the failed line for the control centre, last (it shows the last one)
  (( ${#mac_failed[@]} )) || return 0
  local what
  what="$(printf '%s, ' "${mac_failed[@]}" | sed 's/, $//') did not build on the Mac"
  [[ ${mac_failed[0]} == "the Mac side" ]] && what="the Mac side did not install"
  failed_part "$(mac_helper_feature "${mac_failed[0]}")" "$what" mac
  echo "omacvm update: $what (see above; what was installed before keeps running). omacvm update tries again" >&2
}

# ---------- OmacVM.app ----------
step app "OmacVM.app"
# The version that goes with this OmacVM, from its release (curl: no
# quarantine). Not while the app is open: it may run a VM.
# Not from OmacVM.app's own copy: the app updates itself (Check Now, or u in
# the control centre), and app_bundle may name another copy of it.
if [[ -z ${OMACVM_APP_COPY:-} ]] && app=$(app_bundle); then
  have=$(app_version "$app"); want=$(cat "$R/src/VERSION")
  if app_version_lt "$have" "$want"; then
    # awk reads to the end: an early exit would stop app_list with SIGPIPE.
    running=$(app_list | awk -F'\t' '$3 == "running" && !f { print $1; f = 1 }')
    if [[ -n $running ]]; then
      info "OmacVM.app: '$running' runs in it, not updated ($have; $want is out). Shut the VM down, then: omacvm update"
    # The app's path as it is (pgrep -f took it as a regex: "Omarchy (2).app").
    elif procs=$(ps -ax -o args= 2>/dev/null) && [[ $procs == *"$app/Contents/"* ]]; then
      info "OmacVM.app is open, not updated ($have; $want is out). Quit it, then: omacvm update"
    elif ! app_published "$want"; then
      info "OmacVM.app $have: no download for $want yet"
    else
      log "OmacVM.app $have -> $want"
      app_install "$want" "$app" >/dev/null || failed_app=1
    fi
  fi
fi

# ---------- the VMs ----------
if [[ -n $VM ]]; then
  rc=0; OMACVM_STEP_BASE=$OMA_STEP OMACVM_STEP_OF=$OMA_STEPS "$R/src/cmd/apply.sh" --vm "$VM" ${TYPE:+--vm-type "$TYPE"} --no-mac ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"} || rc=$?
  # The VM's own failure says more; with none, the Mac's.
  if (( rc == 0 && ${#mac_failed[@]} )); then mac_failure; exit 1; fi
  exit $rc
fi
done_any=0; stopped=(); unanswered=(); failed=()
while IFS=$'\t' read -r name type state _; do
  [[ -n $name ]] || continue
  if [[ $state == unknown ]]; then unanswered+=("$name"); continue; fi
  if [[ $state != running ]]; then stopped+=("$name"); continue; fi
  ip=$(vm_find_ip "$name" "$type" 3 2>/dev/null) || continue
  vm_pin "$name" "$type"
  # Not reachable with OmacVM's key (another OS, no OmacVM, or another host
  # key): say why for the last one, then go on with the other VMs.
  if ! v=$(vm_probe "$ip" | sed -n 's/^OMACVM_VERSION=//p'); then
    hostkey_changed "$ip" 2>/dev/null && info "VM '$name': another SSH host key, not updated (rebuilt? omacvm apply --vm $(printf %q "$name") --reset-host-key)"
    continue
  fi
  [[ -n $v ]] || continue
  if [[ ! -s $OMA_PIN ]] && ! vm_marked "$name" "$type"; then
    info "VM '$name' says it has OmacVM $v, but OmacVM has not set it up from this Mac yet: omacvm update --vm $(printf %q "$name")"
    continue
  fi
  log "VM '$name' (OmacVM $v)"
  "$R/src/cmd/apply.sh" --vm "$name" --vm-type "$type" --ip "$ip" --no-mac ${APPLY_ARGS[@]+"${APPLY_ARGS[@]}"} < /dev/null || failed+=("$name")
  done_any=1
done < <(vms_list)
(( done_any )) || info "no running VM with OmacVM"
if (( ${#stopped[@]} )); then
  info "not running, so not updated: $(printf '%s, ' "${stopped[@]}" | sed 's/, $//')"
  info "start one and run: omacvm update --vm NAME"
fi
(( ${#unanswered[@]} )) && info "not updated: $(printf '%s, ' "${unanswered[@]}" | sed 's/, $//'): $UTM_NO_ANSWER"
(( ${failed_app:-0} )) && failed+=("OmacVM.app")
(( ${#mac_failed[@]} )) && { mac_failure; failed+=("the Mac side"); }
if (( ${#failed[@]} )); then
  echo "omacvm update: failed in $(printf '%s, ' "${failed[@]}" | sed 's/, $//') (see above)" >&2
  exit 1
fi
