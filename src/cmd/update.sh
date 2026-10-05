#!/bin/bash
# omacvm update [--vm NAME [--vm-type T]] [--no-pull]: OmacVM up to date everywhere. This
# checkout (git pull, when it is a clean clone), the Mac side that is
# installed (Omanotch with it), OmacVM.app when it is installed and a newer
# one is published (not while it runs), then OmacVM in every running VM that
# has it (or only --vm NAME; a stopped one is started).
# Each VM keeps its feature choices. Stopped VMs are listed, not started. Only
# VMs OmacVM set up from this Mac (their SSH host key is remembered, or OmacVM
# built them) get the update, and with it the Bridge's token.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
VM=""; TYPE=""; PULL=1; ARGS=("$@")
while (( $# )); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --vm-type) TYPE=$2; shift 2 ;;
    --no-pull) PULL=0; shift ;;
    -h|--help) sed -n '2,10s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "omacvm update: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
export OMA_KEY=~/.ssh/omacvm

# ---------- this checkout ----------
if (( PULL )) && git -C "$R" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
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
log "OmacVM on the Mac"
"$R/src/mac/install.sh" ${args[@]+"${args[@]}"}

# ---------- OmacVM.app ----------
# The version that goes with this OmacVM, from its release (curl: no
# quarantine). Not while the app is open: it may run a VM.
if app=$(app_bundle); then
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
  "$R/src/cmd/apply.sh" --vm "$VM" ${TYPE:+--vm-type "$TYPE"} --no-mac
  exit
fi
done_any=0; stopped=(); unanswered=(); failed=()
while IFS=$'\t' read -r name type state; do
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
  "$R/src/cmd/apply.sh" --vm "$name" --vm-type "$type" --ip "$ip" --no-mac < /dev/null || failed+=("$name")
  done_any=1
done < <(vms_list)
(( done_any )) || info "no running VM with OmacVM"
if (( ${#stopped[@]} )); then
  info "not running, so not updated: $(printf '%s, ' "${stopped[@]}" | sed 's/, $//')"
  info "start one and run: omacvm update --vm NAME"
fi
(( ${#unanswered[@]} )) && info "not updated: $(printf '%s, ' "${unanswered[@]}" | sed 's/, $//'): $UTM_NO_ANSWER"
(( ${failed_app:-0} )) && failed+=("OmacVM.app")
if (( ${#failed[@]} )); then
  echo "omacvm update: failed in $(printf '%s, ' "${failed[@]}" | sed 's/, $//') (see above)" >&2
  exit 1
fi
